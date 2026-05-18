#!/usr/bin/env bash
# render-dry-run-summary.sh — MVP Lobster step: post Slack thread reply
# summarizing what the pipeline WOULD have done.
#
# Stdin: verdict-engine.sh output (queue_depth, fetch_size, counts, partitioned credits)
# Stdout: the summary text we posted (so Lobster's step output captures it)
# Side effect: posts a Slack message via `openclaw message send` if THREAD_TS
#              is set and non-empty. Otherwise just emits to stdout (test mode).
#
# Env:
#   THREAD_TS            optional — thread to reply in. Empty = stdout only.
#   TARGET_CHANNEL       optional — default C0APB2CMM7C (#credit-verification).
#                        Caller can override for testing.
#   OPENCLAW_CLI         optional — path to openclaw binary. Default: openclaw.
#   OPENCLAW_PROFILE     optional — default "main".

set -euo pipefail

INPUT=$(cat)

TARGET_CHANNEL="${TARGET_CHANNEL:-C0APB2CMM7C}"
THREAD_TS="${THREAD_TS:-}"
OPENCLAW_BIN="${OPENCLAW_CLI:-openclaw}"
OPENCLAW_PROFILE="${OPENCLAW_PROFILE:-main}"

QUEUE_DEPTH=$(echo "$INPUT" | jq -r '.queue_depth')
FETCH_SIZE=$(echo "$INPUT" | jq -r '.fetch_size')
TOTAL=$(echo "$INPUT" | jq -r '.counts.total')
WOULD_APPROVE=$(echo "$INPUT" | jq -r '.counts.would_approve')
WOULD_UVN=$(echo "$INPUT" | jq -r '.counts.would_uvn')

# apply.* is present iff apply-verdicts.sh ran (dry_run flag included).
# Test for explicit boolean false (the REAL signal). Anything else — null,
# missing, true, "true" — is treated as dry-run (safe default).
DRY_APPLY=$(echo "$INPUT" | jq -r '.apply.dry_run | tostring')
APPLY_APPROVE_LANDED=$(echo "$INPUT"  | jq -r '.apply.approve.landed  // 0')
APPLY_APPROVE_REFUSED=$(echo "$INPUT" | jq -r '.apply.approve.refused // 0')
APPLY_UVN_LANDED=$(echo "$INPUT"      | jq -r '.apply.uvn.landed      // 0')
APPLY_UVN_REFUSED=$(echo "$INPUT"     | jq -r '.apply.uvn.refused     // 0')

# Mode-dependent labels. Internal JSON field names (would_*) stay
# constant; only Slack-visible text changes.
if [[ "$DRY_APPLY" == "false" ]]; then
  MODE_LINE=":rocket: *Lobster credit-verification — admin API writes executed*"
  APPROVE_LABEL="approved"
  UVN_LABEL="user_verification_needed"
  APPROVE_LIST_HEADER="approved cr_ids (first 10):"
  TAIL_LINE="_Apply outcomes: approved.landed=$APPLY_APPROVE_LANDED (refused=$APPLY_APPROVE_REFUSED), uvn.landed=$APPLY_UVN_LANDED (refused=$APPLY_UVN_REFUSED). Per-cr_id audit at \`/var/log/openclaw/lobster-apply.jsonl\`._"
else
  MODE_LINE=":test_tube: *Lobster credit-verification DRY-RUN — would-have verdicts only*"
  APPROVE_LABEL="would_approve"
  UVN_LABEL="would_uvn"
  APPROVE_LIST_HEADER="would_approve cr_ids (first 10):"
  TAIL_LINE="_No admin API writes happened. This is a Lobster-driven sample only._"
fi

# Build the summary text. Plain Slack markdown.
TEXT=$(cat <<EOF
$MODE_LINE
Queue depth (live): $QUEUE_DEPTH | Sampled: $TOTAL of $FETCH_SIZE
Pipeline: lobster.verify-credit-batch (signal-first)

*Bucket counts:*
  :white_check_mark: $APPROVE_LABEL : $WOULD_APPROVE
  :no_entry: $UVN_LABEL : $WOULD_UVN

_Backend-signal policy: approve_owning_track=100 AND total_risk_percent<80 (backtested 99.34% precision over 90 days). Everything not auto-approved is moved to user_verification_needed for human review._
$TAIL_LINE
EOF
)

# Surface any selector-level note from the fetch step. fetch-by-credit.sh
# emits one when the credit isn't `status=unverified` anymore (e.g.
# "status_is_approved_not_unverified"); without this rendering the user
# just sees "Sampled: 0" with no explanation.
SELECTOR_NOTE=$(echo "$INPUT" | jq -r '.selector.note // empty')
if [[ -n "$SELECTOR_NOTE" ]]; then
  TEXT+=$'\n\n_Note: '"$SELECTOR_NOTE"'_'
fi

# If we have any approve entries, list their cr_ids (clamped).
# Do the clamp INSIDE jq, not via `| head -10`: piping to head closes the
# pipe early and jq gets SIGPIPE → exit 141 under set -o pipefail, which
# aborts the script BEFORE the Slack post. Verified live 2026-05-18 when
# a real-apply run landed 136 approvals but the user saw no thread reply.
APPROVE_IDS=$(echo "$INPUT" | jq -r '(.would_approve // []) | .[0:10] | .[].cr_id // empty')
if [[ -n "$APPROVE_IDS" ]]; then
  TEXT+=$'\n\n*'"$APPROVE_LIST_HEADER"'*'
  while IFS= read -r id; do
    [[ -z "$id" ]] && continue
    TEXT+=$'\n  • `'"$id"$'`'
  done <<< "$APPROVE_IDS"
fi

# Always echo the summary text to stdout so Lobster's step output captures it.
printf '%s\n' "$TEXT"

# If THREAD_TS is set, post via openclaw message send.
if [[ -n "$THREAD_TS" ]]; then
  if ! command -v "$OPENCLAW_BIN" >/dev/null 2>&1; then
    echo "WARN: openclaw binary not found ($OPENCLAW_BIN); skipping Slack post" >&2
  else
    set +e
    "$OPENCLAW_BIN" --profile "$OPENCLAW_PROFILE" message send \
      --account operations \
      --channel slack \
      --target "$TARGET_CHANNEL" \
      --reply-to "$THREAD_TS" \
      --message "$TEXT" \
      >/dev/null
    RC=$?
    set -e
    if [[ $RC -ne 0 ]]; then
      echo "WARN: slack post failed rc=$RC" >&2
    fi
  fi
fi
