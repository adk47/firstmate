#!/usr/bin/env bats

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  JOB='46442766-c410-4ccd-966c-4de3c06eed8d'
}

@test "enabled UVN cron is a deterministic command on the four-hour offset" {
  run jq -e --arg id "$JOB" '
    .jobs[] | select(.id == $id)
    | .enabled == true
      and .agentId == "operations"
      and .schedule == {kind:"cron", expr:"15 */4 * * *", tz:"UTC"}
      and .payload.kind == "command"
      and .payload.argv == ["python3", "/opt/hydra/scripts/uvn-under30-cron.py"]
      and .payload.cwd == "/opt/hydra"
      and .delivery.mode == "announce"
      and .delivery.channel == "slack"
      and .delivery.to == "C0APB2CMM7C"
      and (.delivery.bestEffort // false) == false
  ' "$ROOT/cron-jobs.json"
  [ "$status" -eq 0 ]
}

@test "the main unverified batch remains at minute zero" {
  run jq -e '
    .jobs[] | select(.name == "credit-verification-batch-4h")
    | .schedule.expr == "0 */4 * * *" and .enabled == true
  ' "$ROOT/cron-jobs.json"
  [ "$status" -eq 0 ]
}

@test "real credit writers share one whole-run lock" {
  run grep -n '/var/lib/hydra/credit-status-writes\.lock' \
    "$ROOT/scripts/uvn-under30-cron.py" \
    "$ROOT/workspaces/operations/skills/muso-ops-credit-verification/scripts/lobster-mvp/dispatch-cv-batch.sh"
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | wc -l)" -eq 2 ]

  run grep -nE 'flock -w .* 8' \
    "$ROOT/workspaces/operations/skills/muso-ops-credit-verification/scripts/lobster-mvp/dispatch-cv-batch.sh"
  [ "$status" -eq 0 ]

  run bash -n "$ROOT/workspaces/operations/skills/muso-ops-credit-verification/scripts/lobster-mvp/dispatch-cv-batch.sh"
  [ "$status" -eq 0 ]
}

@test "policy boundary tests pass" {
  run python3 "$ROOT/scripts/tests/test_uvn_under30_policy.py"
  [ "$status" -eq 0 ]

  run python3 "$ROOT/scripts/tests/test_uvn_under30_cron.py"
  [ "$status" -eq 0 ]
}

@test "the automation has no rejection write path" {
  run grep -nE '["]status["][[:space:]]*:[[:space:]]*["]rejected["]' \
    "$ROOT/scripts/uvn-under30-cron.py" "$ROOT/scripts/uvn_under30_policy.py"
  [ "$status" -eq 1 ]
}

@test "the service requester is allowed only through the conditional UVN approval gate" {
  run bash -c '
    source "$1"
    REQUESTER_EMAIL="uvn-popularity-cron@hydra-ops"
    UVN_POPULARITY_CRON=1
    enforce_credit_approve_gate PUT /admin/credit-requests/conditional-status \
      "{\"requestIds\":[\"11111111-1111-4111-8111-111111111111\"],\"status\":\"approved\",\"expectedStatus\":\"user_verification_needed\"}"
  ' _ "$ROOT/workspaces/operations/skills/muso-ops-admin/scripts/muso-admin-api.sh"
  [ "$status" -eq 0 ]
}
