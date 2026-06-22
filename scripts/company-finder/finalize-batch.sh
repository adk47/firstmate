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
#               re-run prep-batch.sh), 4 ledger write or Slack post failed.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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

IN="$(cat)"
if ! jq -e 'type == "object"' >/dev/null 2>&1 <<<"$IN"; then
  echo "finalize-batch: stdin must be a JSON object {batch,rejects?,date?}." >&2
  exit 1
fi
if ! jq -e '(.batch // []) | type == "array"' >/dev/null 2>&1 <<<"$IN"; then
  echo "finalize-batch: .batch must be a JSON array of companies." >&2
  exit 1
fi
BATCH="$(jq -c '.batch // []' <<<"$IN")"
REJECTS="$(jq -c '.rejects // []' <<<"$IN")"
DATE="$(jq -r '.date // empty' <<<"$IN")"
[[ -n "$DATE" ]] || DATE="$(date -u +%F)"

if [[ "$(jq 'length' <<<"$BATCH")" -eq 0 ]]; then
  echo "finalize-batch: empty batch — nothing to post (the skill's silent rule applies: NO_REPLY)." >&2
  exit 1
fi

# ── Step 1: record terminal rejects first (idempotent; fatal only on a real
# write/source failure, not on already-known skips) ─────────────────────────
REJ_OUT='{"stats":{"recorded":0}}'
if [[ "$(jq 'length' <<<"$REJECTS")" -gt 0 ]]; then
  REJ_IN="$(jq -c 'map({name, domain, reason, vertical: (.vertical // "")})' <<<"$REJECTS")"
  rc=0; REJ_OUT="$(printf '%s' "$REJ_IN" | bash "$LEDGER" record-rejects)" || rc=$?
  if [[ "$rc" -ne 0 ]]; then
    echo "finalize-batch: ledger.sh record-rejects failed (rc=$rc) — not posting." >&2
    exit "$rc"
  fi
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
  exit "$rc"
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
  || { echo "finalize-batch: no Slack token for bot '$SLACK_ACCOUNT' (MUSO_SLACK_BOT_TOKEN_<BOT> in the env / main.env)." >&2; exit 4; }

rc=0
RESP="$("$MUSO_BIN" slack send --bot "$SLACK_ACCOUNT" --channel "$CHANNEL" \
          --text "$POST_TEXT" --requester "$SLACK_REQUESTER" --json)" || rc=$?
if [[ "$rc" -ne 0 ]]; then
  echo "finalize-batch: muso slack send failed (rc=$rc) — ledger is written but the post did not land." >&2
  printf '%s' "$RESP" | head -c 300 >&2; echo >&2
  exit 4
fi
TS="$(jq -r '.ts // .message.ts // empty' <<<"$RESP" 2>/dev/null || true)"
if [[ -z "$TS" ]]; then
  echo "finalize-batch: muso slack send returned no ts: $(printf '%s' "$RESP" | head -c 200)" >&2
  exit 4
fi

jq -n --arg ts "$TS" --arg ch "$CHANNEL" \
      --argjson sug "$SUG_OUT" --argjson rej "$REJ_OUT" '
  { posted: { ts: $ts, channel: $ch },
    ledger: { suggested: ($sug.stats.recorded // 0),
              rejects_recorded: ($rej.stats.recorded // 0) } }'
