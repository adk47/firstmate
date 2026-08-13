#!/usr/bin/env bats
bats_require_minimum_version 1.5.0
load helpers

# End-to-end per-row attribution: muso-admin-api.sh (the wrapper that issues
# the PUT) → .results.jsonl (the truth floor) → compute-run-summary.sh (the
# canonical reconciliation the Slack summary and the silent-failure invariant
# are built from).
#
# apply-verdicts.sh already reads the backend's per-row report. The ledger did
# not: every non-2xx was `http_error` for the WHOLE requestIds array and every
# 2xx was `ok` for the whole array. Because compute-run-summary.sh sums
# `request_ids | length` per outcome, a partially successful 409 reconciled as
# "zero landed, everything failed" — the same operator-facing mis-attribution
# this change exists to eliminate, and enough to trip
# run_finished_silent_failure on a run that really did move rows.
#
# Hermetic: `curl` is stubbed on PATH (helpers' $TEST_TMPDIR/bin), so no
# network and no real admin API.

ADMIN_API="$BATS_TEST_DIRNAME/../../../muso-ops-admin/scripts/muso-admin-api.sh"

ID_A="aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa"
ID_B="bbbbbbbb-2222-4222-8222-bbbbbbbbbbbb"
ID_C="cccccccc-3333-4333-8333-cccccccccccc"

setup() {
  setup_tmp_env
  export RUN_ID="20260731-140000-abc123"
  export OPS_RUN_ID="$RUN_ID"
  export PARENT_MSG_TS="1776691677.022189"
  day="${RUN_ID:0:8}"
  RUNLOG_DIR="$OPS_RUNLOG_DIR/${day:0:4}-${day:4:2}-${day:6:2}"
  mkdir -p "$RUNLOG_DIR"
  export RUNLOG_FILE="$RUNLOG_DIR/${RUN_ID}.jsonl"
  : > "$RUNLOG_FILE"
  export OPS_BATCH_TERMINAL=1

  export SESSION_LOG="$TEST_TMPDIR/session.jsonl"
  : > "$SESSION_LOG"
  export CV_SESSION_LOG_OVERRIDE="$SESSION_LOG"

  export CV_RESULTS_PATH="$TEST_TMPDIR/credit-results.jsonl"

  # muso-admin-api.sh environment: authenticated-looking, never reaching a
  # network. CV_APPROVE_GATE_DISABLED mirrors what apply-verdicts.sh sets for
  # approve writes; the gate is not what these tests exercise.
  export MUSO_API_URL="https://example.invalid/api/v3"
  export MUSO_ADMIN_EMAIL="test@example.invalid"
  export MUSO_ADMIN_PASSWORD="test-password"
  export ADMIN_TOKEN_CACHE_PATH="$TEST_TMPDIR/admin-token-cache"
  export MUSO_OPS_STATE_DIR="$TEST_TMPDIR/muso-ops"
  export CODEX_HEALTH_LIB="$TEST_TMPDIR/codex-health.sh"
  export CV_APPROVE_GATE_DISABLED=1
  export OPS_DRY_RUN=0
  printf '%s\ndummy-token\n' "$(date +%s)" > "$ADMIN_TOKEN_CACHE_PATH"
  printf '%s\n' 'codex_health_gate() { return 0; }' > "$CODEX_HEALTH_LIB"
}

teardown() { teardown_tmp_env; }

# Stub curl with a fixed (body, status) pair. muso-admin-api.sh reads the body
# from every line but the last and the status from the last line.
stub_curl() {
  local body="$1" code="$2"
  printf '%s' "$body" > "$TEST_TMPDIR/curl.body"
  printf '%s' "$code" > "$TEST_TMPDIR/curl.code"
  mkdir -p "$TEST_TMPDIR/bin"
  cat > "$TEST_TMPDIR/bin/curl" <<'STUB'
#!/usr/bin/env bash
cat "$TEST_TMPDIR/curl.body"
printf '\n'
cat "$TEST_TMPDIR/curl.code"
printf '\n'
STUB
  chmod +x "$TEST_TMPDIR/bin/curl"
}

put_bulk() {
  # args: status ids-json-array
  local intended="$1" ids="$2"
  run bash "$ADMIN_API" call PUT /admin/credit-requests \
    "$(jq -nc --argjson ids "$ids" --arg st "$intended" '{requestIds:$ids, status:$st}')"
}

rows_for() {
  # args: outcome  → prints the request_ids arrays of matching ledger rows
  jq -c --arg o "$1" 'select(.outcome == $o) | .request_ids' "$CV_RESULTS_PATH"
}

summarize() {
  run "$SCRIPTS_DIR/compute-run-summary.sh" "$RUN_ID" "$PARENT_MSG_TS"
}

# ---------------------------------------------------------------------------
# 409 — partial success. The blocking case: updatedIds really persisted.
# ---------------------------------------------------------------------------

@test "409 partial: ledger records the updated ids as ok and only the rest as http_error" {
  stub_curl "{\"updatedIds\":[\"$ID_A\"],\"skipped\":[{\"id\":\"$ID_B\",\"reason\":\"illegal_transition\"}]}" 409
  put_bulk user_verification_needed "[\"$ID_A\",\"$ID_B\",\"$ID_C\"]"
  [ "$status" -eq 0 ]

  [ "$(rows_for ok)" = "[\"$ID_A\"]" ]
  [ "$(rows_for http_error)" = "[\"$ID_B\",\"$ID_C\"]" ]
}

@test "409 partial: canonical summary reconciles 1 landed / 2 failed, not 0 landed" {
  stub_curl "{\"updatedIds\":[\"$ID_A\"],\"skipped\":[{\"id\":\"$ID_B\",\"reason\":\"lost_race\"}]}" 409
  put_bulk user_verification_needed "[\"$ID_A\",\"$ID_B\",\"$ID_C\"]"
  [ "$status" -eq 0 ]

  summarize
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.reconciliation.source == "results_jsonl"'
  echo "$output" | jq -e '.reconciliation.verification_needed_attempted == 3'
  echo "$output" | jq -e '.reconciliation.verification_needed_landed == 1'
  echo "$output" | jq -e '.reconciliation.verification_needed_http_error == 2'
  # The whole point: a run that really moved a row is not reported as a
  # silent failure.
  echo "$output" | jq -e '.silent_failure_detected == false'
}

@test "409 partial: every attempted id is accounted for exactly once" {
  stub_curl "{\"updatedIds\":[\"$ID_A\",\"$ID_C\"]}" 409
  put_bulk approved "[\"$ID_A\",\"$ID_B\",\"$ID_C\"]"
  [ "$status" -eq 0 ]

  summarize
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '
    .reconciliation
    | (.approved_landed + .approved_http_error + .approved_unattributable)
      == .approved_attempted'
  echo "$output" | jq -e '.reconciliation.approved_landed == 2'
}

# ---------------------------------------------------------------------------
# 200 — the backend still names rows it refused.
# ---------------------------------------------------------------------------

@test "200 with a refused row: only the updated ids count as landed" {
  stub_curl "{\"data\":{\"updatedIds\":[\"$ID_A\",\"$ID_B\"],\"skipped\":[{\"id\":\"$ID_C\",\"reason\":\"not_found\"}]}}" 200
  put_bulk approved "[\"$ID_A\",\"$ID_B\",\"$ID_C\"]"
  [ "$status" -eq 0 ]

  [ "$(rows_for ok)" = "[\"$ID_A\",\"$ID_B\"]" ]
  [ "$(rows_for http_error)" = "[\"$ID_C\"]" ]

  summarize
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.reconciliation.approved_landed == 2'
  echo "$output" | jq -e '.reconciliation.approved_http_error == 1'
}

@test "200 with every id updated: whole array lands, no refused row" {
  stub_curl "{\"data\":{\"updatedIds\":[\"$ID_A\",\"$ID_B\"]}}" 200
  put_bulk approved "[\"$ID_A\",\"$ID_B\"]"
  [ "$status" -eq 0 ]

  [ "$(rows_for ok)" = "[\"$ID_A\",\"$ID_B\"]" ]
  [ -z "$(rows_for http_error)" ]
}

# ---------------------------------------------------------------------------
# Unattributable — never infer success from a missing field.
# ---------------------------------------------------------------------------

@test "200 without updatedIds is unattributable, not landed" {
  stub_curl '{"data":{"message":"ok"}}' 200
  put_bulk approved "[\"$ID_A\",\"$ID_B\"]"
  [ "$status" -eq 0 ]

  [ -z "$(rows_for ok)" ]
  [ "$(rows_for unattributable_response)" = "[\"$ID_A\",\"$ID_B\"]" ]

  summarize
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.reconciliation.approved_attempted == 2'
  echo "$output" | jq -e '.reconciliation.approved_landed == 0'
  echo "$output" | jq -e '.reconciliation.approved_unattributable == 2'
  # Attempted rows that cannot be attributed must surface loudly, not pass
  # as a clean run.
  echo "$output" | jq -e '.silent_failure_detected == true'
}

@test "200 with a non-JSON body is unattributable, not landed" {
  stub_curl '<html>gateway</html>' 200
  put_bulk approved "[\"$ID_A\"]"
  [ "$status" -eq 0 ]

  [ -z "$(rows_for ok)" ]
  [ "$(rows_for unattributable_response)" = "[\"$ID_A\"]" ]
}

# ---------------------------------------------------------------------------
# Unchanged behaviour — a status carrying no row report still classifies the
# whole array, exactly as before.
# ---------------------------------------------------------------------------

@test "500 still refuses the whole array as http_error" {
  stub_curl '{"error":"boom"}' 500
  put_bulk approved "[\"$ID_A\",\"$ID_B\"]"

  [ "$(rows_for http_error)" = "[\"$ID_A\",\"$ID_B\"]" ]
  [ -z "$(rows_for ok)" ]
  [ -z "$(rows_for unattributable_response)" ]
}

@test "single-row PATCH is untouched by per-row attribution" {
  stub_curl '{"data":{"ok":true}}' 200
  run bash "$ADMIN_API" call PATCH "/admin/credit-requests/$ID_A" \
    '{"status":"approved"}'
  [ "$status" -eq 0 ]

  [ "$(rows_for ok)" = "[\"$ID_A\"]" ]
  [ -z "$(rows_for unattributable_response)" ]
}
