#!/usr/bin/env bash
# prep-batch.sh — the deterministic dedupe + liveness gate for the company
# finder. ONE call that chains the two existing deterministic scripts so the
# agent can't run discovery and then skip dedupe (the 2026-06 leak: 44-66%
# duplicates, "what happens when dedupe is left to prompt rules").
#
#   discovery (LLM) → prep-batch.sh → [LLM: LinkedIn evidence + tier + select]
#                     → finalize-batch.sh
#
# It runs dedupe-candidates.sh (snapshot Company/Contacts/Seen-Ledger, normalize,
# set-match) then verify-candidates.sh (website liveness) on the survivors, and
# returns the alive-new survivors plus the categorized rejects in one object.
#
# INPUT  (stdin): the raw candidate UNION JSON array from discovery, e.g.
#   [{"name":"AudioShake","domain":"https://www.audioshake.ai/","vertical":"…","why":"…"}, ...]
#   Extra keys per candidate are preserved through to the survivors.
#
# OUTPUT (stdout): JSON
#   { "survivors": [ <alive + blocked candidates, each carrying .verification> ],
#     "rejects":   { "duplicates":[…], "dead":[…], "name_flags":[…] },
#     "stats":     { checked, deduped_new, duplicates, alive, blocked, dead, survivors } }
#
# `survivors` = alive ++ blocked. Blocked (bot-walled) sites are KEPT but carry
# verification:"blocked" so the post can flag them "⚠ eyeball it" — they are not
# dead. `name_flags` are NEW companies with a partial name overlap, surfaced for
# human eyes, never dropped.
#
# FAIL-CLOSED (never ship a silently-degraded batch):
#   2  a required dedupe source was unreachable (DEDUP_SOURCE_UNAVAILABLE)
#   3  liveness could not be trusted — our egress looked dead (VERIFY_NETWORK_SUSPECT)
# In both cases the caller marks the batch PARTIAL/UNSAFE instead of posting.
#
# Exit codes: 0 ok, 1 usage/input error, 2 dedupe source unavailable,
#             3 verify network suspect, 5 ALREADY_RUNNING (single-flight lock
#             held — see acquire_singleflight_lock in lib/common.sh).
#
# On every non-zero exit, in addition to the stderr message, ONE line of JSON
# is printed to stdout: {"error":<MARKER>,"exit":<code>,"detail":<short>} (via
# lib/common.sh's fail_json) — a stderr-only marker is invisible to the codex
# exec cell that invokes this script (2026-07-22 finding).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# Sub-script paths are env-overridable for hermetic tests (mirrors the
# NOCODB_API_SH override the underlying scripts already use).
DEDUPE="${DEDUPE_SH:-$SCRIPT_DIR/dedupe-candidates.sh}"
VERIFY="${VERIFY_SH:-$SCRIPT_DIR/verify-candidates.sh}"

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  awk 'NR > 1 && /^set -euo pipefail/ {exit} NR > 1' "$0"
  exit 0
fi

acquire_singleflight_lock "prep-batch.sh"

# Same stdin contract as the sibling scripts: empty/whitespace → [] (a valid
# "discovery found nothing" path), non-array → loud exit 1.
UNION="$(read_candidates_stdin)" || fail_json 1 USAGE "stdin must be a JSON array of candidates"

# ── Step 1: deterministic dedupe (exit 2 = DEDUP_SOURCE_UNAVAILABLE) ─────────
# NB: capture the real exit code with `|| rc=$?`, NOT `if ! cmd; then rc=$?`
# (the `!` resets $? to 0, silently swallowing the fail-closed code).
rc=0; DEDUPED="$(printf '%s' "$UNION" | bash "$DEDUPE")" || rc=$?
if [[ "$rc" -ne 0 ]]; then
  echo "prep-batch: dedupe-candidates.sh failed (rc=$rc) — batch PARTIAL/UNSAFE, do not post." >&2
  case "$rc" in
    1) fail_json 1 USAGE "dedupe-candidates.sh: usage error" ;;
    2) fail_json 2 DEDUP_SOURCE_UNAVAILABLE "dedupe-candidates.sh: source unavailable" ;;
    *) fail_json "$rc" DEDUP_SOURCE_UNAVAILABLE "dedupe-candidates.sh: unexpected rc=$rc" ;;
  esac
fi
NEW="$(jq -c '.new // []' <<<"$DEDUPED")"

# ── Step 2: deterministic liveness on the survivors (exit 2 = network suspect)
rc=0; VERIFIED="$(printf '%s' "$NEW" | bash "$VERIFY")" || rc=$?
if [[ "$rc" -ne 0 ]]; then
  echo "prep-batch: verify-candidates.sh failed (rc=$rc) — batch PARTIAL/UNSAFE, do not post." >&2
  # remap the verify network-suspect code (its 2) to 3 so the caller can tell
  # a dedupe-source outage apart from an egress problem.
  case "$rc" in
    1) fail_json 1 USAGE "verify-candidates.sh: input error" ;;
    2) fail_json 3 VERIFY_NETWORK_SUSPECT "verify-candidates.sh: our egress looked dead" ;;
    *) fail_json "$rc" VERIFY_NETWORK_SUSPECT "verify-candidates.sh: unexpected rc=$rc" ;;
  esac
fi

# ── Compose: survivors (alive ++ blocked) + categorized rejects ─────────────
jq -n --argjson d "$DEDUPED" --argjson v "$VERIFIED" '
  (($v.alive // []) + ($v.blocked // [])) as $survivors
  | { survivors: $survivors,
      rejects: {
        duplicates: ($d.duplicates // []),
        dead:       ($v.dead // []),
        name_flags: ($d.name_flags // [])
      },
      stats: {
        checked:     ($d.stats.checked // 0),
        deduped_new: ($d.stats.new // 0),
        duplicates:  ($d.stats.dropped // 0),
        alive:       ($v.stats.alive // 0),
        blocked:     ($v.stats.blocked // 0),
        dead:        ($v.stats.dead // 0),
        survivors:   ($survivors | length)
      } }'
