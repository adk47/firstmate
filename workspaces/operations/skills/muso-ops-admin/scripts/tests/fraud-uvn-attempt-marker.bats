#!/usr/bin/env bats

SCRIPT="$BATS_TEST_DIRNAME/../muso-admin-api.sh"
CR_ID="11111111-1111-4111-8111-111111111111"

setup() {
  TEST_TMPDIR="$(mktemp -d)"
  export TEST_TMPDIR CR_ID
  export CV_FRAUD_ATTEMPT_PATH="$TEST_TMPDIR/fraud-uvn-attempts.jsonl"
}

teardown() {
  rm -rf "$TEST_TMPDIR"
}

setup_e2e_env() {
  export MUSO_API_URL="https://example.invalid/api/v3"
  export MUSO_ADMIN_EMAIL="test@example.invalid"
  export MUSO_ADMIN_PASSWORD="test-password"
  export ADMIN_TOKEN_CACHE_PATH="$TEST_TMPDIR/admin-token-cache"
  export CV_RESULTS_PATH="$TEST_TMPDIR/results.jsonl"
  export MUSO_OPS_STATE_DIR="$TEST_TMPDIR/muso-ops"
  export OPS_RUNLOG_DIR="$TEST_TMPDIR/runlogs"
  export CODEX_HEALTH_LIB="$TEST_TMPDIR/codex-health.sh"
  export E2E_CURL_CALLS="$TEST_TMPDIR/curl.calls"
  mkdir -p "$TEST_TMPDIR/bin" "$OPS_RUNLOG_DIR"
  printf '%s\ndummy-token\n' "$(date +%s)" > "$ADMIN_TOKEN_CACHE_PATH"
  printf '%s\n' 'codex_health_gate() { return 0; }' > "$CODEX_HEALTH_LIB"
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'jq -e --arg id "$CR_ID" '\''(.outcome == "attempt_started") and (.request_ids == [$id])'\'' "$CV_FRAUD_ATTEMPT_PATH" >/dev/null || exit 91' \
    'printf "called\n" >> "$E2E_CURL_CALLS"' \
    'printf '\''{"data":{"updatedIds":[]}}\n200\n'\''' \
    > "$TEST_TMPDIR/bin/curl"
  chmod +x "$TEST_TMPDIR/bin/curl"
}

@test "fraud UVN target IDs are persisted before the caller can write" {
  run bash -c '
    source "$1"
    OPS_FLAG_REASON=fraud_multifactor
    record_fraud_uvn_attempt PUT /admin/credit-requests \
      "{\"requestIds\":[\"$2\"],\"status\":\"user_verification_needed\"}"
  ' _ "$SCRIPT" "$CR_ID"
  [ "$status" -eq 0 ]
  jq -e --arg id "$CR_ID" '
    .outcome == "attempt_started"
      and .flag_reason == "fraud_multifactor"
      and .intended_status == "user_verification_needed"
      and .request_ids == [$id]
  ' "$CV_FRAUD_ATTEMPT_PATH"
}

@test "non-fraud and dry-run-style calls do not create a marker" {
  run bash -c '
    source "$1"
    OPS_FLAG_REASON=name_mismatch
    record_fraud_uvn_attempt PUT /admin/credit-requests \
      "{\"requestIds\":[\"$2\"],\"status\":\"user_verification_needed\"}"
  ' _ "$SCRIPT" "$CR_ID"
  [ "$status" -eq 0 ]
  [ ! -e "$CV_FRAUD_ATTEMPT_PATH" ]
}

@test "marker failure refuses the fraud write path" {
  export CV_FRAUD_ATTEMPT_PATH="/dev/null/fraud-uvn-attempts.jsonl"
  run bash -c '
    source "$1"
    OPS_FLAG_REASON=fraud_multifactor
    record_fraud_uvn_attempt PUT /admin/credit-requests \
      "{\"requestIds\":[\"$2\"],\"status\":\"user_verification_needed\"}"
  ' _ "$SCRIPT" "$CR_ID"
  [ "$status" -ne 0 ]
  [[ "$output" == *"refusing API write"* ]]
}

@test "sync failure refuses the fraud write path" {
  mkdir -p "$TEST_TMPDIR/bin"
  printf '%s\n' '#!/usr/bin/env bash' 'exit 1' > "$TEST_TMPDIR/bin/python3"
  chmod +x "$TEST_TMPDIR/bin/python3"
  run env PATH="$TEST_TMPDIR/bin:$PATH" bash -c '
    source "$1"
    OPS_FLAG_REASON=fraud_multifactor
    record_fraud_uvn_attempt PUT /admin/credit-requests \
      "{\"requestIds\":[\"$2\"],\"status\":\"user_verification_needed\"}"
  ' _ "$SCRIPT" "$CR_ID"
  [ "$status" -ne 0 ]
  [[ "$output" == *"fsync failed"* ]]
}

@test "real call entrypoint persists the marker before curl" {
  setup_e2e_env
  run env PATH="$TEST_TMPDIR/bin:$PATH" OPS_FLAG_REASON=fraud_multifactor \
    bash "$SCRIPT" --requester aaron@muso.ai call PUT /admin/credit-requests \
    "{\"requestIds\":[\"$CR_ID\"],\"status\":\"user_verification_needed\"}"

  [ "$status" -eq 0 ]
  [ "$(wc -l < "$E2E_CURL_CALLS")" -eq 1 ]
  jq -e --arg id "$CR_ID" '.request_ids == [$id]' "$CV_FRAUD_ATTEMPT_PATH"
}

@test "real call entrypoint refuses curl when marker sync fails" {
  setup_e2e_env
  printf '%s\n' '#!/usr/bin/env bash' 'exit 1' > "$TEST_TMPDIR/bin/python3"
  chmod +x "$TEST_TMPDIR/bin/python3"
  run env PATH="$TEST_TMPDIR/bin:$PATH" OPS_FLAG_REASON=fraud_multifactor \
    bash "$SCRIPT" --requester aaron@muso.ai call PUT /admin/credit-requests \
    "{\"requestIds\":[\"$CR_ID\"],\"status\":\"user_verification_needed\"}"

  [ "$status" -ne 0 ]
  [[ "$output" == *"fsync failed"* ]]
  [ ! -e "$E2E_CURL_CALLS" ]
}
