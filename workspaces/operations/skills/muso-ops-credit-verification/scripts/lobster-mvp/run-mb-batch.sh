#!/usr/bin/env bash
# run-mb-batch.sh — Lobster step: MusicBrainz lookup ONLY for the
# signal_review bucket from score-backend-signals.sh.
#
# Stdin: score-backend-signals.sh output {queue_depth, fetch_size, counts,
#                                          signal_approve, signal_review, signal_uvn}
# Stdout: {queue_depth, fetch_size,
#          signal_approve: [...passed through],
#          signal_review_results: [...with MB outcomes...],
#          signal_uvn: [...passed through]}
#
# Calls musicbrainz-isrc-lookup.sh once per signal_review item in serial.
# The lookup script self-sleeps 1.1s between its two internal API calls,
# so per-credit time is already ~1.1s. We do NOT add an outer sleep
# (a previous version double-throttled; backtest 2026-05-15 confirmed MB
# is happy with the script's self-rate-limiting).
#
# Non-zero exits from the MB script are NOT fatal: code 1 ("ISRC unknown to
# MusicBrainz") and code 2 ("network error") are recorded as {found:false}
# and the batch continues. Only structural failures abort.

set -euo pipefail

MB_LOOKUP="${MB_LOOKUP:-/opt/hydra/workspaces/operations/skills/muso-ops-credit-verification/scripts/musicbrainz-isrc-lookup.sh}"

if [[ ! -x "$MB_LOOKUP" ]]; then
  echo "ERROR: MB lookup script not found or not executable at $MB_LOOKUP" >&2
  exit 2
fi

# Buffer stdin (score-backend-signals output).
INPUT=$(cat)

QUEUE_DEPTH=$(echo "$INPUT" | jq -r '.queue_depth // 0')
FETCH_SIZE=$(echo "$INPUT" | jq -r '.fetch_size // 0')

# We only iterate signal_review here. signal_approve and signal_uvn are
# passed through unchanged — they don't need MB.
# score-backend-signals.sh already normalized to {cr_id, profile_id, isrc,
# credited_name, role, _signal:{bucket,reason,...}} per item.
PREPARED=$(echo "$INPUT" | jq -c '.signal_review // []')

# Iterate. No outer sleep — musicbrainz-isrc-lookup.sh self-rate-limits.
RESULTS_TMP=$(mktemp)
trap 'rm -f "$RESULTS_TMP"' EXIT
echo "[]" > "$RESULTS_TMP"

N=$(echo "$PREPARED" | jq 'length')
i=0
while [[ "$i" -lt "$N" ]]; do
  ITEM=$(echo "$PREPARED" | jq -c ".[$i]")
  CR_ID=$(echo "$ITEM" | jq -r '.cr_id')
  ISRC=$(echo "$ITEM" | jq -r '.isrc // ""')
  CREDITED_NAME=$(echo "$ITEM" | jq -r '.credited_name')
  ROLE=$(echo "$ITEM" | jq -r '.role')

  if [[ -z "$ISRC" || "$ISRC" == "null" ]]; then
    # No ISRC → cannot look up. Record skip and continue.
    LOOKUP=$(jq -nc \
      --arg cr_id "$CR_ID" \
      --arg credited_name "$CREDITED_NAME" \
      --arg role "$ROLE" \
      '{cr_id:$cr_id, isrc:null, credited_name:$credited_name, role:$role,
        name_match:false, role_match:false, found:false, error:"no_isrc"}')
  else
    set +e
    MB_OUT=$("$MB_LOOKUP" "$ISRC" --credited-name "$CREDITED_NAME" --role "$ROLE" 2>/dev/null)
    MB_RC=$?
    set -e
    if [[ $MB_RC -eq 0 || $MB_RC -eq 1 ]]; then
      # 0=found, 1=ISRC unknown — both produce structured JSON.
      LOOKUP=$(echo "$MB_OUT" | jq -c --arg cr_id "$CR_ID" '{
        cr_id:$cr_id,
        isrc:.isrc,
        credited_name:(.credited_name // ""),
        role:(.role // ""),
        name_match:.name_match,
        role_match:.role_match,
        found:.found,
        error:.error}')
    else
      # 2=network, 3=usage, other=unexpected. Record and continue.
      LOOKUP=$(jq -nc \
        --arg cr_id "$CR_ID" \
        --arg isrc "$ISRC" \
        --arg credited_name "$CREDITED_NAME" \
        --arg role "$ROLE" \
        --argjson rc "$MB_RC" \
        '{cr_id:$cr_id, isrc:$isrc, credited_name:$credited_name, role:$role,
          name_match:false, role_match:false, found:false,
          error:("mb_lookup_exit_" + ($rc|tostring))}')
    fi
  fi

  jq -c --argjson new "$LOOKUP" '. + [$new]' "$RESULTS_TMP" > "${RESULTS_TMP}.next"
  mv "${RESULTS_TMP}.next" "$RESULTS_TMP"

  i=$((i + 1))
  # No outer sleep — musicbrainz-isrc-lookup.sh's internal 1.1s between its
  # two API calls already paces us at ≤1 req/sec aggregate.
done

REVIEW_RESULTS=$(cat "$RESULTS_TMP")

# Pass through signal_approve and signal_uvn unchanged; emit review results
# alongside. verdict-engine.sh consumes all three.
jq -nc \
  --argjson queue_depth "$QUEUE_DEPTH" \
  --argjson fetch_size "$FETCH_SIZE" \
  --argjson signal_approve "$(echo "$INPUT" | jq -c '.signal_approve // []')" \
  --argjson signal_review_results "$REVIEW_RESULTS" \
  --argjson signal_uvn "$(echo "$INPUT" | jq -c '.signal_uvn // []')" \
  '{queue_depth:$queue_depth,
    fetch_size:$fetch_size,
    signal_approve:$signal_approve,
    signal_review_results:$signal_review_results,
    signal_uvn:$signal_uvn}'
