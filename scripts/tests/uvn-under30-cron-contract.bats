#!/usr/bin/env bats

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  JOB='46442766-c410-4ccd-966c-4de3c06eed8d'
  # The digit quantifier binds only to the numeric spellings; "-hourly" and
  # "-daily" state a cadence without a digit and must match too.
  CADENCE_SUFFIX='-([0-9]+(h|m|min)|hourly|daily)$'
}

cadence_matches() {
  # `--` is load-bearing: the pattern starts with "-", so without it grep reads
  # the pattern as an option, exits 2, and every caller reads that as "no
  # cadence found" — a guard that could never fail.
  printf '%s' "$1" | grep -qE -- "$CADENCE_SUFFIX"
}

@test "enabled UVN cron is a deterministic hourly command clear of the batch" {
  run jq -e --arg id "$JOB" '
    .jobs[] | select(.id == $id)
    | .enabled == true
      and .agentId == "operations"
      and .schedule == {kind:"cron", expr:"30 * * * *", tz:"UTC"}
      and .payload.kind == "command"
      and .payload.argv == ["python3", "/opt/hydra/scripts/uvn-under30-cron.py", "--mode", "apply", "--limit", "25"]
      and .payload.cwd == "/opt/hydra"
      and .delivery.mode == "announce"
      and .delivery.channel == "slack"
      and .delivery.to == "C0APB2CMM7C"
      and (.delivery.bestEffort // false) == false
      and (.description | contains("automation:uvn-under30"))
      and (.description | contains("recommendation does not gate enrollment"))
      and (.description | contains("PROFILE-SCOPED"))
      and (.description | contains("REVERSAL BREAKER"))
      and (.description | contains("--mode shadow"))
      and (.description | contains("Plain-English summaries"))
  ' "$ROOT/cron-jobs.json"
  [ "$status" -eq 0 ]
}

@test "the job name encodes no cadence to go stale" {
  run jq -r --arg id "$JOB" '.jobs[] | select(.id == $id) | .name' "$ROOT/cron-jobs.json"
  [ "$status" -eq 0 ]
  [ "$output" = "uvn-ticket-popularity-under30" ]

  local name="$output"

  # The schedule moved 4-hourly -> hourly and the name said "-4h" for a day.
  # A cadence stated in two places drifts; the schedule is the only authority.
  run cadence_matches "$name"
  [ "$status" -ne 0 ]
}

@test "the cadence guard catches every spelling, not just the numeric ones" {
  # This guard exists to fail a FUTURE rename. If it only catches "-4h", a
  # rename to "-hourly" reintroduces the exact drift it was written to stop
  # while the assertions above stay green, so every spelling gets a case.
  for bad in uvn-ticket-popularity-4h \
             uvn-ticket-popularity-15m \
             uvn-ticket-popularity-30min \
             uvn-ticket-popularity-hourly \
             uvn-ticket-popularity-daily; do
    run cadence_matches "$bad"
    [ "$status" -eq 0 ] || {
      echo "cadence guard missed: $bad" >&2
      return 1
    }
  done

  # ...and stays quiet on the name we actually ship, whose trailing digits are
  # a threshold rather than a cadence.
  for ok in uvn-ticket-popularity-under30 \
            credit-verification-batch; do
    run cadence_matches "$ok"
    [ "$status" -ne 0 ] || {
      echo "cadence guard false-positived on: $ok" >&2
      return 1
    }
  done
}

@test "the main unverified batch remains at minute zero" {
  # Pins the schedule only (the :30 offset of this cron depends on it). The
  # batch is DISABLED since 2026-10-11 (inverted approve rule, contained); its
  # enabled flag is owned by scripts/check-credit-approval-automation.sh.
  run jq -e '
    .jobs[] | select(.name == "credit-verification-batch-4h")
    | .schedule.expr == "0 */4 * * *"
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

@test "the cron guards its host, honours the kill switch, and defaults to shadow" {
  run grep -nF 'socket.gethostname()' "$ROOT/scripts/uvn-under30-cron.py"
  [ "$status" -eq 0 ]
  run grep -nF '/etc/hydra/uvn-under30-cron.disabled' "$ROOT/scripts/uvn-under30-cron.py"
  [ "$status" -eq 0 ]
  run grep -nF 'default="shadow"' "$ROOT/scripts/uvn-under30-cron.py"
  [ "$status" -eq 0 ]
}

@test "apply mode cannot write without the reversal breaker in front of it" {
  run grep -nF 'assert_no_reversal_streak(run_id)' "$ROOT/scripts/uvn-under30-cron.py"
  [ "$status" -eq 0 ]
  run grep -nF 'if mode == "apply":' "$ROOT/scripts/uvn-under30-cron.py"
  [ "$status" -eq 0 ]
  run grep -nF 'raise ReversalCheckUnavailable' "$ROOT/scripts/uvn-under30-cron.py"
  [ "$status" -eq 0 ]
}

@test "the cadence a ticket comment promises matches the scheduled one" {
  run jq -r --arg id "$JOB" '.jobs[] | select(.id == $id) | .schedule.expr' "$ROOT/cron-jobs.json"
  [ "$status" -eq 0 ]
  [ "$output" = "30 * * * *" ]

  run grep -nF 'RUN_CADENCE_TEXT = "every hour"' "$ROOT/scripts/uvn-under30-cron.py"
  [ "$status" -eq 0 ]

  # the promise must be interpolated, never a second hard-coded interval
  run grep -nE 're-runs every [0-9]' "$ROOT/scripts/uvn-under30-cron.py"
  [ "$status" -eq 1 ]
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
