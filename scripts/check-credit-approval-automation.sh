#!/usr/bin/env bash
# check-credit-approval-automation.sh — CI guard: no automation may approve Muso
# credit requests unless it is registered AND explicitly approved.
#
# WHY (2026-10-11). The credit-verification-batch-4h cron approved validator-
# DECLINED credit requests every 4 hours for months, using an inverted signal.
# After it was disabled live on node-8, the next deploy would have re-enabled it,
# because deploy.sh re-imports cron-jobs.json (enabled:true) into the cron store.
# The fix has two parts: the repo now says enabled:false, and this guard keeps it
# that way. It fails if:
#
#   1. a cron in cron-jobs.json runs a credit-approving entrypoint but is not
#      listed in the cron_names of a policies/credit-approval-automation.json
#      entry ("unregistered credit-approving cron");
#   2. a registered cron is enabled while its entry has approved != true, or ANY
#      entry has approved == true without a non-empty approved_by AND
#      approval_ref (checked even with the cron off: the Slack trigger and the
#      dispatcher read the same flag);
#   3. the registry is missing, unparseable, or drops an entrypoint from the
#      built-in floor below. Deleting a registry line must not make a known
#      approver invisible.
#
# Detection is a fixed-substring match on each job's payload text: the argv
# joined with spaces, plus the agent-turn message for agentTurn payloads.
#
# Usage: check-credit-approval-automation.sh
# Env:   CRON_JOBS_FILE  (default <repo>/cron-jobs.json)
#        CREDIT_APPROVAL_REGISTRY (default <repo>/policies/credit-approval-automation.json)
# Exit:  0 clean, 1 violation, 2 missing or unreadable input.
set -euo pipefail

ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
CRON_FILE="${CRON_JOBS_FILE:-$ROOT/cron-jobs.json}"
REGISTRY="${CREDIT_APPROVAL_REGISTRY:-$ROOT/policies/credit-approval-automation.json}"

# Entrypoints known to be able to approve credit requests. The registry must
# cover every one of them. Add here when a new approver is written.
FLOOR_ENTRYPOINTS=(
  "dispatch-cv-batch.sh"
  "credit-verification-batch-cron.sh"
  "verify-credit-batch-mvp.lobster"
  "uvn-under30-cron.py"
  "credit-review.py decide"
  "credit-review.py score-approve"
)
# Approve-capable helpers that must never be called from a cron at all. They
# are agent/manual tools; scheduling one is always a violation.
NEVER_SCHEDULED=(
  "credit-fable-execute.py"
  "apply-verdicts.sh"
  "batch-approve-credits.sh"
  "batch-verify-profile.sh"
)

for f in "$CRON_FILE" "$REGISTRY"; do
  [ -r "$f" ] || { echo "check-credit-approval-automation: missing $f" >&2; exit 2; }
done
jq -e 'type == "object" or type == "array"' "$CRON_FILE" >/dev/null 2>&1 \
  || { echo "check-credit-approval-automation: $CRON_FILE is not JSON" >&2; exit 2; }
jq -e '.automations | type == "object"' "$REGISTRY" >/dev/null 2>&1 \
  || { echo "check-credit-approval-automation: $REGISTRY has no .automations object" >&2; exit 2; }

fail=0
violation() { echo "VIOLATION: $*" >&2; fail=1; }

# 3. Floor coverage.
for ep in "${FLOOR_ENTRYPOINTS[@]}"; do
  if ! jq -e --arg ep "$ep" '[.automations[].entrypoints[]?] | index($ep) != null' "$REGISTRY" >/dev/null; then
    violation "registry does not list known credit-approving entrypoint '$ep' (policies/credit-approval-automation.json)"
  fi
done

# 2b. Every approved entry must say who approved it and where, whether or not a
#     cron runs it: the @Ops Slack trigger reaches real apply with the cron off
#     (QA finding on hydra#1138).
while IFS= read -r key; do
  [ -n "$key" ] || continue
  violation "automation '$key' has approved == true but approved_by / approval_ref is empty. An approval must say who approved it and where"
done < <(jq -r '.automations | to_entries[]
  | select(.value.approved == true)
  | select(((.value.approved_by // "") | tostring | length == 0) or ((.value.approval_ref // "") | tostring | length == 0))
  | .key' "$REGISTRY")

# One row per cron job: name <TAB> enabled <TAB> payload text (tabs/newlines flattened).
jobs_tsv=$(jq -r '
  (if type == "array" then . else (.jobs // []) end)[]
  | [ (.name // .id // "<unnamed>"),
      # NOT `.enabled // true`: jq `//` treats false as absent, so a disabled
      # job would read as enabled.
      (if .enabled == false then "false" else "true" end),
      ([ (.payload.argv // [] | join(" ")),
         (.payload.message // ""),
         (.payload.text // "") ] | join(" ") | gsub("[\t\n\r]"; " ")) ]
  | @tsv' "$CRON_FILE")

matched=0
while IFS=$'\t' read -r name enabled text; do
  [ -n "$name" ] || continue

  for ep in "${NEVER_SCHEDULED[@]}"; do
    if [[ "$text" == *"$ep"* ]]; then
      violation "cron '$name' calls '$ep', an approve-capable helper that must never be scheduled"
    fi
  done

  # Which registry entries' entrypoints does this job reference?
  hits=$(jq -r --arg text "$text" '
    .automations | to_entries[]
    | select([.value.entrypoints[]? as $e | $text | contains($e)] | any)
    | .key' "$REGISTRY")
  # Also catch a floor entrypoint that the registry lost (reported above) so the
  # cron itself is named too.
  floor_hit=0
  for ep in "${FLOOR_ENTRYPOINTS[@]}"; do
    [[ "$text" == *"$ep"* ]] && floor_hit=1
  done
  if [ -z "$hits" ]; then
    if (( floor_hit )); then
      violation "cron '$name' runs a credit-approving entrypoint that no registry entry covers"
    fi
    continue
  fi
  matched=$((matched + 1))

  while IFS= read -r key; do
    [ -n "$key" ] || continue
    if ! jq -e --arg k "$key" --arg n "$name" '.automations[$k].cron_names // [] | index($n) != null' "$REGISTRY" >/dev/null; then
      violation "cron '$name' runs credit-approving automation '$key' but is not in its cron_names (unregistered credit-approving cron)"
      continue
    fi
    if [ "$enabled" = "true" ]; then
      if ! jq -e --arg k "$key" '.automations[$k].approved == true' "$REGISTRY" >/dev/null; then
        violation "cron '$name' is ENABLED but automation '$key' has approved != true. Set \"enabled\": false in cron-jobs.json, or record the captain's approval in policies/credit-approval-automation.json"
      fi
    fi
  done <<< "$hits"
done <<< "$jobs_tsv"

if (( fail )); then
  echo "check-credit-approval-automation: FAILED (see VIOLATION lines above)" >&2
  exit 1
fi
echo "OK: credit-approval automation registry covers ${matched} cron(s); no unapproved credit-approving cron is enabled"
