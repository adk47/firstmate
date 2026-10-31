#!/usr/bin/env bats
# Tests for check-credit-approval-automation.sh: the CI guard that no hydra cron
# may approve Muso credit requests unless it is registered in
# policies/credit-approval-automation.json AND that entry is approved, with
# approved_by + approval_ref filled in.
#
# Hermetic: every test runs the guard against temp COPIES (or synthetic files)
# through CRON_JOBS_FILE / CREDIT_APPROVAL_REGISTRY, never the tracked sources.
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
SCRIPT="$HYDRA_REPO/scripts/check-credit-approval-automation.sh"

setup() {
  TEST_TMPDIR="$(mktemp -d)"
  cp "$HYDRA_REPO/cron-jobs.json" "$TEST_TMPDIR/cron.json"
  cp "$HYDRA_REPO/policies/credit-approval-automation.json" "$TEST_TMPDIR/registry.json"
  export CRON_JOBS_FILE="$TEST_TMPDIR/cron.json"
  export CREDIT_APPROVAL_REGISTRY="$TEST_TMPDIR/registry.json"
}

teardown() { rm -rf "$TEST_TMPDIR"; }

# jq_edit <file> <filter> — rewrite a JSON file in place.
jq_edit() {
  jq "$2" "$1" > "$1.tmp" && mv "$1.tmp" "$1"
}

@test "passes on the real repo files" {
  unset CRON_JOBS_FILE CREDIT_APPROVAL_REGISTRY
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK:"* ]]
}

@test "the repo keeps credit-verification-batch-4h disabled and unapproved" {
  run jq -r '.jobs[] | select(.name == "credit-verification-batch-4h") | .enabled' "$HYDRA_REPO/cron-jobs.json"
  [ "$output" = "false" ]
  run jq -r '.automations["credit-verification-batch"].approved' "$HYDRA_REPO/policies/credit-approval-automation.json"
  [ "$output" = "false" ]
}

@test "FAILS when the batch cron is re-enabled without approval (the redeploy hole)" {
  jq_edit "$CRON_JOBS_FILE" '(.jobs[] | select(.name == "credit-verification-batch-4h") | .enabled) = true'
  run --separate-stderr "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"credit-verification-batch-4h"*"ENABLED"* ]]
}

@test "a job with no enabled key counts as enabled (runtime default)" {
  jq_edit "$CRON_JOBS_FILE" '(.jobs[] | select(.name == "credit-verification-batch-4h")) |= del(.enabled)'
  run --separate-stderr "$SCRIPT"
  [ "$status" -eq 1 ]
}

@test "passes when the batch cron is enabled AND approved with who + where" {
  jq_edit "$CRON_JOBS_FILE" '(.jobs[] | select(.name == "credit-verification-batch-4h") | .enabled) = true'
  jq_edit "$CREDIT_APPROVAL_REGISTRY" '.automations["credit-verification-batch"] += {approved:true, approved_by:"captain", approval_ref:"slack ts 123"}'
  run "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "FAILS when approved but approved_by or approval_ref is empty" {
  jq_edit "$CRON_JOBS_FILE" '(.jobs[] | select(.name == "credit-verification-batch-4h") | .enabled) = true'
  jq_edit "$CREDIT_APPROVAL_REGISTRY" '.automations["credit-verification-batch"] += {approved:true, approved_by:"captain", approval_ref:null}'
  run --separate-stderr "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"approved_by / approval_ref is empty"* ]]
}

@test "FAILS when approved without who/where EVEN WITH THE CRON DISABLED (Slack-trigger path)" {
  # QA finding on hydra#1138: approved=true with null metadata and the cron off
  # used to pass CI, yet dispatch-cv-batch.sh reads the same flag for @Ops runs.
  jq_edit "$CREDIT_APPROVAL_REGISTRY" '.automations["credit-verification-batch"] += {approved:true, approved_by:null, approval_ref:null}'
  run jq -r '.jobs[] | select(.name == "credit-verification-batch-4h") | .enabled' "$CRON_JOBS_FILE"
  [ "$output" = "false" ]
  run --separate-stderr "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"credit-verification-batch"*"approved_by / approval_ref is empty"* ]]
}

@test "FAILS on an unregistered cron that runs a credit-approving entrypoint" {
  jq_edit "$CRON_JOBS_FILE" '.jobs += [{"id":"x","name":"sneaky-approver","enabled":false,
    "payload":{"kind":"command","argv":["bash","/opt/hydra/workspaces/operations/skills/muso-ops-credit-verification/scripts/lobster-mvp/dispatch-cv-batch.sh","10"]}}]'
  run --separate-stderr "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"sneaky-approver"*"unregistered"* ]]
}

@test "FAILS on an agent-turn cron whose message tells it to run the dispatcher" {
  jq_edit "$CRON_JOBS_FILE" '.jobs += [{"id":"y","name":"agent-approver","enabled":true,
    "payload":{"kind":"agentTurn","message":"exec bash dispatch-cv-batch.sh 500"}}]'
  run --separate-stderr "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"agent-approver"* ]]
}

@test "FAILS when any cron schedules an approve-capable helper" {
  jq_edit "$CRON_JOBS_FILE" '.jobs += [{"id":"z","name":"helper-cron","enabled":false,
    "payload":{"kind":"command","argv":["bash","/opt/hydra/x/batch-approve-credits.sh"]}}]'
  run --separate-stderr "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"helper-cron"*"must never be scheduled"* ]]
}

@test "FAILS when the registry drops a known approver entrypoint" {
  jq_edit "$CREDIT_APPROVAL_REGISTRY" 'del(.automations["uvn-under30"])'
  run --separate-stderr "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"uvn-under30-cron.py"* ]]
}

@test "FAILS when uvn-under30 is flipped to unapproved while its cron is enabled" {
  # The fixture states "enabled" itself: the tracked cron may be switched off (captain order 2026-10-26).
  jq_edit "$CRON_JOBS_FILE" '(.jobs[] | select(.name == "uvn-ticket-popularity-under30") | .enabled) = true'
  jq_edit "$CREDIT_APPROVAL_REGISTRY" '.automations["uvn-under30"].approved = false'
  run --separate-stderr "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"uvn-ticket-popularity-under30"* ]]
}

@test "exit 2 on a missing or malformed input" {
  CREDIT_APPROVAL_REGISTRY="$TEST_TMPDIR/nope.json" run "$SCRIPT"
  [ "$status" -eq 2 ]
  printf 'not json' > "$TEST_TMPDIR/bad.json"
  CREDIT_APPROVAL_REGISTRY="$TEST_TMPDIR/bad.json" run "$SCRIPT"
  [ "$status" -eq 2 ]
}

# Fable [key=switch-on-plan] item 3: credit-trust-decide is JUDGE-ONLY - its writer is approved:false, and its cron
# may run enabled only as `decide --mode judge` (decider rows only) with the judge-only approval recorded.
@test "the repo keeps the credit-trust-decide writer unapproved with a recorded judge-only approval" {
  run jq -r '.automations["credit-trust-decide"] | "\(.approved) \(.judge_only.allowed) \(.judge_only.approved_by != null)"' "$HYDRA_REPO/policies/credit-approval-automation.json"
  [ "$output" = "false true true" ]
}

@test "passes when the decide cron is enabled as exactly '--mode judge' (judge-only)" {
  jq_edit "$CRON_JOBS_FILE" '(.jobs[] | select(.name == "credit-trust-decide-15m") | .enabled) = true'
  run "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "FAILS when the enabled decide cron could write: a second --mode, --mode=apply, apply, or a message" {
  for argv in '["python3","/opt/hydra/scripts/credit-review.py","decide","--mode","judge","--mode","apply"]' \
              '["python3","/opt/hydra/scripts/credit-review.py","decide","--mode=apply","--mode","judge"]' \
              '["python3","/opt/hydra/scripts/credit-review.py","decide","--mode","apply"]' \
              '["python3","/opt/hydra/scripts/credit-review.py","decide"]' \
              '["bash","-c","python3 /opt/hydra/scripts/credit-review.py decide --mode apply; # /opt/hydra/scripts/credit-review.py","decide","--mode","judge"]' \
              '["python3","/tmp/credit-review.py","decide","--mode","judge"]' \
              '["python3","/opt/hydra/scripts/credit-review.py","decide","--mode","judge","--extra"]' \
              '["/opt/hydra/scripts/credit-review.py","decide","--mode","judge"]'; do
    cp "$HYDRA_REPO/cron-jobs.json" "$CRON_JOBS_FILE"
    jq_edit "$CRON_JOBS_FILE" "(.jobs[] | select(.name == \"credit-trust-decide-15m\")) |= (.enabled = true | .payload.argv = $argv)"
    run --separate-stderr "$SCRIPT"
    [ "$status" -eq 1 ]
    [[ "$stderr" == *"credit-trust-decide-15m"*"ENABLED"* ]]
  done
  cp "$HYDRA_REPO/cron-jobs.json" "$CRON_JOBS_FILE"
  jq_edit "$CRON_JOBS_FILE" '(.jobs[] | select(.name == "credit-trust-decide-15m")) |= (.enabled = true | .payload.message = "also approve")'
  run --separate-stderr "$SCRIPT"
  [ "$status" -eq 1 ]
}

@test "FAILS when a judge-only cron runs without the recorded judge-only approval" {
  jq_edit "$CRON_JOBS_FILE" '(.jobs[] | select(.name == "credit-trust-decide-15m") | .enabled) = true'
  for f in 'del(.automations["credit-trust-decide"].judge_only)' \
           '.automations["credit-trust-decide"].judge_only.allowed = false' \
           '.automations["credit-trust-decide"].judge_only.approval_ref = ""' \
           'del(.automations["credit-trust-decide"].judge_only.argv)' \
           '.automations["credit-trust-decide"].judge_only.argv = ["python3","/opt/hydra/scripts/credit-review.py","decide","--mode","apply"]'; do
    cp "$HYDRA_REPO/policies/credit-approval-automation.json" "$CREDIT_APPROVAL_REGISTRY"
    jq_edit "$CREDIT_APPROVAL_REGISTRY" "$f"
    run --separate-stderr "$SCRIPT"
    [ "$status" -eq 1 ]
  done
}
