#!/usr/bin/env bash
# finalize-batch.sh — the ledger + post gate for the company finder.
#
# This is the ENFORCEMENT point: it records terminal rejects, writes the batch
# to the Seen Ledger (Status=suggested), and ONLY on a successful ledger write
# formats and POSTS the batch to #company-finder itself. The post lives inside
# this script, downstream of the ledger write, so dedupe+ledger come FREE with
# the post — making the CORRECT path the EASY path. That removes the incentive
# behind the 2026-06 failure (batches posted with exec=0, no dedupe, duplicates
# compounding because nothing was ever ledgered).
#
# NOTE — this is convention-deep, not guard-deep. Nothing physically stops a
# determined agent from calling `muso slack send --channel <company-finder>`
# directly; there is no slack-boundary guard on that channel (yet). Hand-posting
# is forbidden by the skill + SOUL doctrine, and the post being a script output
# makes the right thing the path of least resistance. The hard guard (a
# ledger-write token the channel boundary requires) is the follow-up if doctrine
# slips. It mirrors ledger.sh's "single sanctioned write path" intent.
#
# INPUT (stdin): JSON object
#   { "batch":   [ { name, domain, vertical, tier?, website?, linkedin?, hq?,
#                    size?, why?, spend_signal?, first_touch?, evidence?,
#                    flags?:[ "site bot-walled, eyeball it", … ] }, … ],
#     "rejects": [ { name, domain, reason, vertical? }, … ],  # terminal rejects
#     "date":    "YYYY-MM-DD"  # optional, defaults to today (UTC)
#   }
#   `batch` is the final selected top-N (post dedupe+verify, with LinkedIn
#   evidence + tier). `rejects` are the mechanical terminal rejects (DEAD /
#   NO_LINKEDIN / IN_GHL / SUBSIDIARY) — never score-cuts.
#
# OUTPUT (stdout): JSON
#   { "posted": { ts, channel }, "ledger": { suggested, rejects_recorded } }
#
# Exit codes: 0 ok, 1 usage/input error, 2 ledger source unavailable,
#             3 LEDGER_COLLISION (dedupe was skipped/raced — NOTHING posted,
#               re-run prep-batch.sh), 4 ledger write or Slack post failed,
#             5 ALREADY_RUNNING (single-flight lock held — see below).
#
# On every non-zero exit, in addition to the stderr message, ONE line of JSON
# is printed to stdout: {"error":<MARKER>,"exit":<code>,"detail":<short>} (via
# lib/common.sh's fail_json) — the 2026-07-22 storm below is also why: a
# stderr-only marker is invisible to a codex exec cell.
#
# SINGLE-FLIGHT LOCK (2026-07-22 storm): a live run measured 97s (six
# sequential ~16s NocoDB snapshots — see the snapshot-sharing note at Step 0
# below); Scout's codex exec cell yields at 90s, so finalize "returned no
# JSON" and Scout fail-closed, then retried — stacking ~13 concurrent
# finalize processes against NocoDB, whose 429 backoff made each one slower
# still. acquire_singleflight_lock makes a concurrent retry an instant
# ALREADY_RUNNING no-op instead of another slow process joining the pile-up.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# Sub-script + slack-lib paths are env-overridable for hermetic tests.
LEDGER="${LEDGER_SH:-$SCRIPT_DIR/ledger.sh}"
SLACK_NOTIFY_SH="${SLACK_NOTIFY_SH:-$SCRIPT_DIR/../lib/slack-notify.sh}"
MUSO_BIN="${MUSO_BIN:-muso}"
SLACK_ACCOUNT="${SLACK_ACCOUNT:-scout}"
CHANNEL="${COMPANY_FINDER_CHANNEL:-C0ARS7XMY93}"
SLACK_REQUESTER="${SLACK_NOTIFY_REQUESTER:-company-finder@hydra-ops}"

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  awk 'NR > 1 && /^set -euo pipefail/ {exit} NR > 1' "$0"
  exit 0
fi

acquire_singleflight_lock "finalize-batch.sh"

IN="$(cat)"
if ! jq -e 'type == "object"' >/dev/null 2>&1 <<<"$IN"; then
  echo "finalize-batch: stdin must be a JSON object {batch,rejects?,date?}." >&2
  fail_json 1 USAGE "stdin must be a JSON object {batch,rejects?,date?}"
fi
if ! jq -e '(.batch // []) | type == "array"' >/dev/null 2>&1 <<<"$IN"; then
  echo "finalize-batch: .batch must be a JSON array of companies." >&2
  fail_json 1 USAGE ".batch must be a JSON array of companies"
fi
BATCH="$(jq -c '.batch // []' <<<"$IN")"
REJECTS="$(jq -c '.rejects // []' <<<"$IN")"
DATE="$(jq -r '.date // empty' <<<"$IN")"
[[ -n "$DATE" ]] || DATE="$(date -u +%F)"

if [[ "$(jq 'length' <<<"$BATCH")" -eq 0 ]]; then
  echo "finalize-batch: empty batch — nothing to post (the skill's silent rule applies: NO_REPLY)." >&2
  fail_json 1 EMPTY_BATCH "empty batch — nothing to post"
fi

# ── Step 0: prefetch the three ledger.sh dedupe sources ONCE, shared by BOTH
# downstream ledger.sh calls (record-rejects + suggest) via LEDGER_SNAPSHOT_DIR
# — collapses 6 sequential ~16s NocoDB snapshots to 3 (97s -> ~50s). The
# snapshot is taken milliseconds before Step 1, so it is AT LEAST as fresh as
# the two live fetches it replaces (those were ~50s apart under the old code).
# record-rejects writes new ledger rows between this prefetch and Step 2's
# suggest — those rows are folded back into the snapshot after Step 1 (see
# below) so suggest's collision check still sees them, exactly as a live
# fetch would have. ─────────────────────────────────────────────────────────
SNAP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/cf-finalize-snapshot.XXXXXX")"
trap 'rm -rf "$SNAP_DIR"' EXIT
locate_nocodb_api || fail_json 2 LEDGER_SOURCE_UNAVAILABLE "could not locate nocodb-api.sh"
resolve_ledger_table_id "LEDGER_SOURCE_UNAVAILABLE" \
  || fail_json 2 LEDGER_SOURCE_UNAVAILABLE "could not resolve Seen Ledger table id"
fetch_table "$LEDGER_TABLE_ID" "Seen Ledger" "Id,Domain,Company Name,Status" "LEDGER_SOURCE_UNAVAILABLE" \
  > "$SNAP_DIR/$LEDGER_TABLE_ID.json" \
  || fail_json 2 LEDGER_SOURCE_UNAVAILABLE "prefetch of Seen Ledger failed"
fetch_table "$COMPANY_TABLE_ID" "Company Intelligence" "Id,Domain,Company Name,Status" "LEDGER_SOURCE_UNAVAILABLE" \
  > "$SNAP_DIR/$COMPANY_TABLE_ID.json" \
  || fail_json 2 LEDGER_SOURCE_UNAVAILABLE "prefetch of Company Intelligence failed"
fetch_table "$CONTACTS_TABLE_ID" "Contacts Intelligence" "Id,Domain,Company Name,Status" "LEDGER_SOURCE_UNAVAILABLE" \
  > "$SNAP_DIR/$CONTACTS_TABLE_ID.json" \
  || fail_json 2 LEDGER_SOURCE_UNAVAILABLE "prefetch of Contacts Intelligence failed"
export LEDGER_SNAPSHOT_DIR="$SNAP_DIR"

# ── Step 1: record terminal rejects first (idempotent; fatal only on a real
# write/source failure, not on already-known skips) ─────────────────────────
REJ_OUT='{"stats":{"recorded":0}}'
if [[ "$(jq 'length' <<<"$REJECTS")" -gt 0 ]]; then
  REJ_IN="$(jq -c 'map({name, domain, reason, vertical: (.vertical // "")})' <<<"$REJECTS")"
  rc=0; REJ_OUT="$(printf '%s' "$REJ_IN" | bash "$LEDGER" record-rejects)" || rc=$?
  if [[ "$rc" -ne 0 ]]; then
    echo "finalize-batch: ledger.sh record-rejects failed (rc=$rc) — not posting." >&2
    case "$rc" in
      1) fail_json 1 USAGE "ledger.sh record-rejects: usage error" ;;
      2) fail_json 2 LEDGER_SOURCE_UNAVAILABLE "ledger.sh record-rejects: source unavailable" ;;
      4) fail_json 4 LEDGER_WRITE_OR_POST_FAILED "ledger.sh record-rejects: write failed" ;;
      *) fail_json "$rc" LEDGER_WRITE_OR_POST_FAILED "ledger.sh record-rejects: unexpected rc=$rc" ;;
    esac
  fi
fi

# Fold record-rejects' newly-written rows into the shared snapshot BEFORE
# suggest's collision check runs. Without this, a domain rejected in Step 1
# (e.g. present in both .batch and .rejects for the same run) would not show
# up as a collision in Step 2 — the snapshot was taken before Step 1 ran, so
# it would otherwise be stale in exactly this one respect. .recorded (not
# skipped_existing) is the newly-written set; skipped_existing was already in
# the snapshot when it was taken.
NEW_REJECT_ROWS="$(jq -c '[.recorded[]? | {Id: null, Domain: .domain, "Company Name": .name, Status: "rejected"}]' <<<"$REJ_OUT")"
if [[ "$(jq 'length' <<<"$NEW_REJECT_ROWS")" -gt 0 ]]; then
  jq -c --slurpfile new <(printf '%s' "$NEW_REJECT_ROWS") '. + $new[0]' \
    "$SNAP_DIR/$LEDGER_TABLE_ID.json" > "$SNAP_DIR/$LEDGER_TABLE_ID.json.tmp"
  mv "$SNAP_DIR/$LEDGER_TABLE_ID.json.tmp" "$SNAP_DIR/$LEDGER_TABLE_ID.json"
fi

# ── Step 2: ledger.sh suggest — THE GATE. A non-zero here (esp. exit 3
# LEDGER_COLLISION) means dedupe was skipped or raced: post NOTHING. ──────────
SUGGEST_IN="$(jq -c 'map({name, domain, vertical: (.vertical // ""),
                          why: (.why // ""), evidence: (.evidence // "")})' <<<"$BATCH")"
rc=0; SUG_OUT="$(printf '%s' "$SUGGEST_IN" | bash "$LEDGER" suggest)" || rc=$?
if [[ "$rc" -ne 0 ]]; then
  echo "finalize-batch: ledger.sh suggest failed (rc=$rc) — NOT posting." >&2
  if [[ "$rc" -eq 3 ]]; then
    echo "  LEDGER_COLLISION = a company was already in the ledger/CRM: dedupe was skipped or raced." >&2
    echo "  Re-run prep-batch.sh on the union and only finalize its survivors." >&2
  fi
  case "$rc" in
    1) fail_json 1 USAGE "ledger.sh suggest: usage error" ;;
    2) fail_json 2 LEDGER_SOURCE_UNAVAILABLE "ledger.sh suggest: source unavailable" ;;
    3) fail_json 3 LEDGER_COLLISION "dedupe was skipped or raced — re-run prep-batch.sh" ;;
    4) fail_json 4 LEDGER_WRITE_OR_POST_FAILED "ledger.sh suggest: write failed" ;;
    *) fail_json "$rc" LEDGER_WRITE_OR_POST_FAILED "ledger.sh suggest: unexpected rc=$rc" ;;
  esac
fi

# ── Step 3: ledger is written — ONLY NOW format + post ──────────────────────
POST_TEXT="$(jq -rn --argjson batch "$BATCH" --argjson rejects "$REJECTS" --arg date "$DATE" '
  def line($label; $v): if ($v // "") != "" then "\n     \($label): \($v)" else "" end;
  def company($i):
    "  \($i + 1). *\(.name)* (`\(.domain)`)"
    + (if (.tier // "") != "" then " — Tier \(.tier)" else "" end)
    + line("Website"; .website) + line("LinkedIn"; .linkedin)
    + (if ((.hq // "") != "") or ((.size // "") != "")
       then "\n     HQ: \(.hq // "—") | Size: \(.size // "—")" else "" end)
    + line("Why"; .why) + line("Spend signal"; .spend_signal)
    + line("First touch"; .first_touch)
    + ((.flags // []) | map("\n     ⚠ " + .) | join(""));
  ($batch | length) as $n
  | "*New Company Batch, \($date)* (\($n) parent companies)\n"
  + ( [ $batch | group_by(.vertical // "Uncategorized")[]
        | "\n" + ((.[0].vertical // "Uncategorized") + ":")
          + "\n" + ( [ to_entries[] | .key as $k | (.value | company($k)) ] | join("\n") ) ]
      | join("\n") )
  + ( if ($rejects | length) > 0
      then "\n\nRejected considerations: "
           + ( [ $rejects[] | "\(.name) \(.reason)" ] | join(" · ") )
      else "" end )')"

# shellcheck source=../lib/slack-notify.sh
source "$SLACK_NOTIFY_SH"
slack_load_env "$SLACK_ACCOUNT" \
  || { echo "finalize-batch: no Slack token for bot '$SLACK_ACCOUNT' (MUSO_SLACK_BOT_TOKEN_<BOT> in the env / main.env)." >&2; fail_json 4 LEDGER_WRITE_OR_POST_FAILED "no Slack token for bot '$SLACK_ACCOUNT'"; }

rc=0
RESP="$("$MUSO_BIN" slack send --bot "$SLACK_ACCOUNT" --channel "$CHANNEL" \
          --text "$POST_TEXT" --requester "$SLACK_REQUESTER" --json)" || rc=$?
if [[ "$rc" -ne 0 ]]; then
  echo "finalize-batch: muso slack send failed (rc=$rc) — ledger is written but the post did not land." >&2
  printf '%s' "$RESP" | head -c 300 >&2; echo >&2
  fail_json 4 LEDGER_WRITE_OR_POST_FAILED "muso slack send failed rc=$rc"
fi
TS="$(jq -r '.ts // .message.ts // empty' <<<"$RESP" 2>/dev/null || true)"
if [[ -z "$TS" ]]; then
  echo "finalize-batch: muso slack send returned no ts: $(printf '%s' "$RESP" | head -c 200)" >&2
  fail_json 4 LEDGER_WRITE_OR_POST_FAILED "muso slack send returned no ts"
fi

jq -n --arg ts "$TS" --arg ch "$CHANNEL" \
      --argjson sug "$SUG_OUT" --argjson rej "$REJ_OUT" '
  { posted: { ts: $ts, channel: $ch },
    ledger: { suggested: ($sug.stats.recorded // 0),
              rejects_recorded: ($rej.stats.recorded // 0) } }'
