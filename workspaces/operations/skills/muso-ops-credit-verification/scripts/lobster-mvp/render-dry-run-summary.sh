#!/usr/bin/env bash
# render-dry-run-summary.sh — MVP Lobster step: post Slack thread reply
# summarizing what the pipeline WOULD have done.
#
# Stdin: verdict-engine.sh output (queue_depth, fetch_size, counts, partitioned credits)
# Stdout: the summary text we posted (so Lobster's step output captures it)
# Side effect: posts a Slack message via `openclaw message send`.
#   - THREAD_TS set                              → post as thread reply
#   - THREAD_TS empty + POST_PARENT_TO_CHANNEL=1 → post as top-level parent in $TARGET_CHANNEL
#   - THREAD_TS empty + POST_PARENT_TO_CHANNEL=0 → stdout only (direct-CLI / bats test mode)
#
# Env:
#   THREAD_TS              optional — thread to reply in. Empty = no thread context.
#   POST_PARENT_TO_CHANNEL optional — "1" enables top-level parent posting when
#                          THREAD_TS is empty. Set by the pipeline's summary step
#                          (verify-credit-batch-mvp.lobster) so cron-fired runs
#                          announce themselves without depending on the agent's
#                          final-reply being relayed (hydra#305). Default "0".
#   TARGET_CHANNEL         optional — default C0APB2CMM7C (#credit-verification).
#                          Caller can override for testing.
#   OPENCLAW_BIN           optional — explicit path to openclaw binary.
#   OPENCLAW_CLI_PATH      optional — openclaw's own path env (server.js:9325).
#                          Used as fallback for OPENCLAW_BIN. NOTE: do not use
#                          OPENCLAW_CLI here — openclaw sets that to "1" as a
#                          marker (openclaw-exec-env.js + entry.js:117), so
#                          reading it as a path would silently resolve to "1"
#                          in any subprocess where the marker leaks.
#   OPENCLAW_PROFILE       optional — default "main".

set -euo pipefail

INPUT=$(cat)

TARGET_CHANNEL="${TARGET_CHANNEL:-C0APB2CMM7C}"
THREAD_TS="${THREAD_TS:-}"
POST_PARENT_TO_CHANNEL="${POST_PARENT_TO_CHANNEL:-0}"
OPENCLAW_BIN="${OPENCLAW_BIN:-${OPENCLAW_CLI_PATH:-openclaw}}"
OPENCLAW_PROFILE="${OPENCLAW_PROFILE:-main}"
# Fraud-detector mode (fraud-detection-spec.md). The pipeline `fraud` step
# carries this env through; we read it ONLY to label the section: in shadow
# mode verdicts are unchanged, so the header must say so. Default off.
CV_FRAUD_MODE="${CV_FRAUD_MODE:-off}"
# Per-run id minted by dispatch-cv-batch.sh and threaded through pipeline env.
# muso-admin-api.sh names the truth-floor results file with the same id, so
# the Slack summary can point at THIS run's artifacts (before 2026-06-11 the
# results writer fell back to the stale runlog latest.txt from the retired
# non-lobster path). Empty for direct/manual pipeline invocations.
OPS_RUN_ID="${OPS_RUN_ID:-}"

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

# Selector-level note from the fetch step (e.g. fetch-by-credit.sh's
# "status_is_approved_not_unverified"). Extracted once here, rendered by
# BOTH the compact no-op branch and the full-block branch below — without
# it the user just sees "Sampled: 0" with no explanation.
SELECTOR_NOTE=$(echo "$INPUT" | jq -r '.selector.note // empty')

# --- no-op compaction ------------------------------------------------------
# 2026-07-22: a mis-routed UVN ask dispatched the batch ~30 times, every
# run "Sampled: 0 of 500" — and every run posted the FULL block (bucket
# counts, policy line, audit tail) to Slack. When nothing was sampled and
# nothing landed or was refused, all that furniture is noise: render a
# compact one-liner instead. Posting behavior (thread/parent/stdout) is
# unchanged — a human who asked still gets a reply, just a short one.
# Anything sampled, landed, refused, or fraud-flagged keeps the full
# block (a compacted summary that hides real writes would be a
# truth-floor regression; with total=0 the would_* arrays are empty, so
# the fraud and muso-unavailable sections are vacuously absent anyway).
if [[ "$TOTAL" == "0" \
      && "$APPLY_APPROVE_LANDED" == "0" && "$APPLY_APPROVE_REFUSED" == "0" \
      && "$APPLY_UVN_LANDED" == "0" && "$APPLY_UVN_REFUSED" == "0" ]]; then
  if [[ "$DRY_APPLY" == "false" ]]; then
    NOOP_PREFIX=":white_check_mark: Credit-verification no-op"
  else
    NOOP_PREFIX=":test_tube: Credit-verification DRY-RUN no-op"
  fi
  TEXT="$NOOP_PREFIX — 0 unverified credits matched the selector (queue depth: $QUEUE_DEPTH)${OPS_RUN_ID:+ | run_id: ${OPS_RUN_ID}}"

  # The selector note is the one thing a 0-sample summary MUST keep — it
  # explains the zero.
  if [[ -n "$SELECTOR_NOTE" ]]; then
    TEXT+=$'\n_Note: '"$SELECTOR_NOTE"'_'
  fi
else

# Mode-dependent labels. Internal JSON field names (would_*) stay
# constant; only Slack-visible text changes.
if [[ "$DRY_APPLY" == "false" ]]; then
  MODE_LINE=":rocket: *Lobster credit-verification — admin API writes executed*"
  APPROVE_LABEL="approved"
  UVN_LABEL="user_verification_needed"
  APPROVE_LIST_HEADER="approved cr_ids (first 10):"
  TAIL_LINE="_Apply outcomes: approved.landed=$APPLY_APPROVE_LANDED (refused=$APPLY_APPROVE_REFUSED), uvn.landed=$APPLY_UVN_LANDED (refused=$APPLY_UVN_REFUSED). Per-cr_id audit at \`/var/log/openclaw/lobster-apply.jsonl\`._"
  if [[ -n "$OPS_RUN_ID" ]]; then
    # Same UTC-date derivation as muso-admin-api.sh write_credit_request_result
    # (a batch crossing UTC midnight between apply and summary can point at
    # yesterday's dir — accepted, the run_id still finds the file via glob).
    TAIL_LINE+=$'\n'"_Per-run truth floor: \`/var/log/openclaw/credit-batch-runs/$(date -u +%Y-%m-%d)/${OPS_RUN_ID}.results.jsonl\`._"
  fi
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
Pipeline: lobster.verify-credit-batch (signal-first)${OPS_RUN_ID:+ | run_id: ${OPS_RUN_ID}}

*Bucket counts:*
  :white_check_mark: $APPROVE_LABEL : $WOULD_APPROVE
  :no_entry: $UVN_LABEL : $WOULD_UVN

_Backend-signal policy: approve_owning_track=100 AND total_risk_percent<80 (backtested 99.34% precision over 90 days). Everything not auto-approved is moved to user_verification_needed for human review._
$TAIL_LINE
EOF
)

# Surface the selector-level note (extracted once, top of file).
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

# --- Fraud line (multi-factor batch detector, fraud-detection-spec.md) -------
# Source of fraud-flagged credits in the in-pipeline JSON, robust to whether
# the Phase-2 verdict-engine still exposes a top-level signal_fraud array or
# only folds the credits into would_uvn carrying their `_fraud` object:
#   1. top-level .signal_fraud[] (score-fraud / shadow output, if it survives)
#   2. else would_uvn[] entries with ._fraud.over == true (enforce, folded)
# Each entry's reason rides on _signal.reason or _fraud.reason. We render a
# COMPACT line (count + first few ids + factors), not the full list — the
# authoritative per-credit list is the post-hoc render-slack-summary.sh.
FRAUD_COUNT=$(echo "$INPUT" | jq -r '
  ((.signal_fraud // []) +
   ((.would_uvn // []) | map(select((._fraud.over // false) == true))))
  | map(.cr_id) | unique | length
')
FRAUD_COUNT="${FRAUD_COUNT:-0}"

if (( FRAUD_COUNT > 0 )); then
  # Shadow mode does NOT change verdicts — make that explicit in the header so
  # nobody reads a shadow run as if the credits were actually routed to UVN.
  if [[ "$CV_FRAUD_MODE" == "shadow" ]]; then
    FRAUD_HEADER=":rotating_light: *SUSPECTED FRAUD (SHADOW — not enforced): ${FRAUD_COUNT} credit(s) would be flagged*"
  else
    FRAUD_HEADER=":rotating_light: *SUSPECTED FRAUD: ${FRAUD_COUNT} credit(s) flagged → user_verification_needed*"
  fi
  TEXT+=$'\n\n'"$FRAUD_HEADER"

  # Compact id + factor list, clamped to first 5 inside jq (avoid head SIGPIPE).
  FRAUD_LINES=$(echo "$INPUT" | jq -r '
    ((.signal_fraud // []) +
     ((.would_uvn // []) | map(select((._fraud.over // false) == true))))
    | unique_by(.cr_id) | .[0:5][]
    | (._signal.reason // ._fraud.reason // "") as $r
    | ($r | if startswith("fraud:") then (.[6:] | sub("=[^=]*$";"") | gsub("\\+";", ")) else . end) as $factors
    | "\(.cr_id)\t\($factors)"
  ')
  while IFS=$'\t' read -r id factors; do
    [[ -z "$id" ]] && continue
    if [[ -n "$factors" ]]; then
      TEXT+=$'\n  • `'"$id"$'` — '"$factors"
    else
      TEXT+=$'\n  • `'"$id"$'`'
    fi
  done <<< "$FRAUD_LINES"
  if (( FRAUD_COUNT > 5 )); then
    TEXT+=$'\n  … +'"$((FRAUD_COUNT - 5))"$' more'
  fi

fi

# Loud one-line notice when the muso-only Trino factor was unavailable this
# run (fail-soft path). Computed across ALL annotated credits — NOT just the
# fraud-flagged ones — and appended even when nothing crossed the threshold:
# a degraded run that flags zero credits must be distinguishable from a fully
# scored clean batch (the fail-soft visibility contract in
# fraud-detection-spec.md). In off mode no credit carries _fraud, so the
# any() is vacuously false and the line never renders.
MUSO_UNAVAIL=$(echo "$INPUT" | jq -r '
  [ ((.would_approve // []) + (.would_uvn // []) + (.signal_fraud // []))[]
    | ._fraud.muso_only_available ]
  | any(. == false)
')
if [[ "$MUSO_UNAVAIL" == "true" ]]; then
  # The reason string now rides in-band on _fraud.muso_only_reason (carried
  # from fraud-muso-only-lookup.sh's fail-soft wrapper through score-fraud-
  # signals.sh — see fraud-issue-scorer-followups.md §1), so it can be
  # surfaced HERE instead of only on the fraud scorer's stderr, which no
  # operator reads (the 2026-08-01 escalation could not find the reason
  # anywhere). Same credit shared with the availability check above; every
  # credit in a run carries the same run-wide reason, so the first non-null
  # one suffices.
  MUSO_REASON=$(echo "$INPUT" | jq -r '
    [ ((.would_approve // []) + (.would_uvn // []) + (.signal_fraud // []))[]
      | ._fraud.muso_only_reason // empty ] | first // empty
  ')
  if [[ -n "$MUSO_REASON" ]]; then
    TEXT+=$'\n\n:warning: muso-only Trino signal was UNAVAILABLE this run — fraud scores computed WITHOUT it (fail-soft). Reason: '"$MUSO_REASON"
  else
    # Defensive fallback: an older score-fraud-signals.sh build (predating
    # the reason field) or a wrapper without it. No "see runlog": the
    # lobster path writes no runlog jsonl.
    TEXT+=$'\n\n:warning: muso-only Trino signal was UNAVAILABLE this run — fraud scores computed WITHOUT it (fail-soft; failure reason on the fraud scorer stderr in this run'"'"'s transcript).'
  fi
fi

fi # end no-op-compaction else (full-block path)

# Always echo the summary text to stdout so Lobster's step output captures it.
printf '%s\n' "$TEXT"

# Post to Slack. Two modes:
#   - THREAD_TS set                              → thread reply (@-mention path)
#   - THREAD_TS empty + POST_PARENT_TO_CHANNEL=1 → top-level parent (cron path; hydra#305)
# Otherwise (THREAD_TS empty, no opt-in) → stdout only, used by bats/CLI.
post_mode=""
if [[ -n "$THREAD_TS" ]]; then
  post_mode="thread"
elif [[ "$POST_PARENT_TO_CHANNEL" == "1" ]]; then
  post_mode="parent"
fi

if [[ -n "$post_mode" ]]; then
  if ! command -v "$OPENCLAW_BIN" >/dev/null 2>&1; then
    echo "WARN: openclaw binary not found ($OPENCLAW_BIN); skipping Slack post" >&2
  else
    set +e
    if [[ "$post_mode" == "thread" ]]; then
      "$OPENCLAW_BIN" --profile "$OPENCLAW_PROFILE" message send \
        --account operations \
        --channel slack \
        --target "$TARGET_CHANNEL" \
        --reply-to "$THREAD_TS" \
        --message "$TEXT" \
        >/dev/null
    else
      "$OPENCLAW_BIN" --profile "$OPENCLAW_PROFILE" message send \
        --account operations \
        --channel slack \
        --target "$TARGET_CHANNEL" \
        --message "$TEXT" \
        >/dev/null
    fi
    RC=$?
    set -e
    if [[ $RC -ne 0 ]]; then
      echo "WARN: slack post failed rc=$RC mode=$post_mode" >&2
    fi
  fi
fi
