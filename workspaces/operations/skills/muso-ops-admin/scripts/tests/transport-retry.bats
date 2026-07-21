#!/usr/bin/env bats

# Real-mode transport handling for muso-admin-api.sh. curl is PATH-shadowed;
# these tests never touch the network or production API.

bats_require_minimum_version 1.5.0

setup() {
    TEST_ROOT="$(mktemp -d)"
    export TEST_ROOT
    SCRIPT="${BATS_TEST_DIRNAME}/../muso-admin-api.sh"

    export MUSO_API_URL="https://example.invalid"
    export MUSO_ADMIN_EMAIL="test@example.com"
    export MUSO_ADMIN_PASSWORD="unused"
    export OPS_DRY_RUN=0
    export CV_APPROVE_GATE_DISABLED=1
    export CV_RESULTS_PATH="$TEST_ROOT/results.jsonl"
    export ADMIN_TOKEN_CACHE_PATH="$TEST_ROOT/token-cache"
    export MUSO_OPS_STATE_DIR="$TEST_ROOT/state"
    export CODEX_HEALTH_LIB="$TEST_ROOT/codex-health.sh"
    printf '%s\n' 'codex_health_gate() { return 0; }' > "$CODEX_HEALTH_LIB"
    printf '%s\ndummy-token\n' "$(date +%s)" > "$ADMIN_TOKEN_CACHE_PATH"

    mkdir -p "$TEST_ROOT/bin"
    export CURL_CALLS="$TEST_ROOT/curl.calls"
    cat > "$TEST_ROOT/bin/curl" <<'STUB'
#!/usr/bin/env bash
calls=0
[[ -f "$CURL_CALLS" ]] && calls=$(wc -l < "$CURL_CALLS")
printf 'call\n' >> "$CURL_CALLS"
case "${CURL_STUB_MODE:-ok}" in
    transient_dns)
        if (( calls == 0 )); then
            printf '\n000'
            exit 6
        fi
        printf '{"ok":true}\n200'
        ;;
    persistent_dns)
        printf '\n000'
        exit 6
        ;;
    timeout)
        printf '\n000'
        exit 28
        ;;
    http_500)
        printf '{"error":"server"}\n500'
        ;;
    login_transient_dns)
        if (( calls == 0 )); then
            exit 6
        elif (( calls == 1 )); then
            printf '{"token":"fresh-token"}'
        else
            printf '{"ok":true}\n200'
        fi
        ;;
    login_persistent_dns)
        exit 6
        ;;
    *)
        printf '{"ok":true}\n200'
        ;;
esac
STUB
    chmod +x "$TEST_ROOT/bin/curl"
    export PATH="$TEST_ROOT/bin:$PATH"
}

teardown() {
    rm -rf "$TEST_ROOT"
}

call_credit_update() {
    run --separate-stderr env \
        CURL_STUB_MODE="$1" \
        MUSO_ADMIN_PRECONNECT_RETRIES="${2:-1}" \
        MUSO_ADMIN_RETRY_DELAY_SECONDS=0 \
        bash "$SCRIPT" call PUT /admin/credit-requests \
        '{"requestIds":["cr_1"],"status":"approved"}'
}

@test "opt-in retry recovers one DNS failure and writes one terminal ok result" {
    call_credit_update transient_dns 1
    [ "$status" -eq 0 ]
    printf '%s' "$output" | jq -e '
        .http_status == 200
        and .transport_attempts == 2
        and .transport_retry_exits == [6]
    ' >/dev/null
    [ "$(wc -l < "$CURL_CALLS")" -eq 2 ]
    [ "$(wc -l < "$CV_RESULTS_PATH")" -eq 1 ]
    jq -e '
        .outcome == "ok"
        and .transport_attempts == 2
        and .transport_retry_exits == [6]
    ' "$CV_RESULTS_PATH" >/dev/null
}

@test "retry policy rejects values above one before curl runs" {
    call_credit_update transient_dns 2
    [ "$status" -eq 2 ]
    [[ "$stderr" == *"MUSO_ADMIN_PRECONNECT_RETRIES must be 0 or 1"* ]]
    [ ! -e "$CURL_CALLS" ]
    [ ! -e "$CV_RESULTS_PATH" ]
}

@test "persistent DNS failure is structured and recorded as transport_error" {
    call_credit_update persistent_dns 1
    [ "$status" -eq 6 ]
    printf '%s' "$output" | jq -e '
        .http_status == null
        and .transport_error.curl_exit == 6
        and .transport_error.attempts == 2
        and .transport_error.retry_exits == [6]
    ' >/dev/null
    [ "$(wc -l < "$CURL_CALLS")" -eq 2 ]
    [ "$(wc -l < "$CV_RESULTS_PATH")" -eq 1 ]
    jq -e '
        .outcome == "transport_error"
        and .http_status == null
        and .error == "curl_exit_6"
        and .transport_attempts == 2
        and .transport_retry_exits == [6]
    ' "$CV_RESULTS_PATH" >/dev/null
}

@test "ambiguous timeout is classified as transport_error but is not retried" {
    call_credit_update timeout 1
    [ "$status" -eq 28 ]
    printf '%s' "$output" | jq -e '
        .transport_error.curl_exit == 28
        and .transport_error.attempts == 1
        and .transport_error.retry_exits == []
    ' >/dev/null
    [ "$(wc -l < "$CURL_CALLS")" -eq 1 ]
}

@test "HTTP 500 is not retried and remains an http_error" {
    call_credit_update http_500 1
    [ "$status" -eq 0 ]
    printf '%s' "$output" | jq -e '
        .http_status == 500
        and .transport_attempts == 1
        and .transport_retry_exits == []
        and (has("transport_error") | not)
    ' >/dev/null
    [ "$(wc -l < "$CURL_CALLS")" -eq 1 ]
    jq -e '.outcome == "http_error" and .http_status == 500' "$CV_RESULTS_PATH" >/dev/null
}

@test "missing token cache retries transient login DNS before the credit PUT" {
    rm -f "$ADMIN_TOKEN_CACHE_PATH"
    call_credit_update login_transient_dns 1
    [ "$status" -eq 0 ]
    printf '%s' "$output" | jq -e '.http_status == 200' >/dev/null
    [ "$(wc -l < "$CURL_CALLS")" -eq 3 ]
    [ "$(wc -l < "$CV_RESULTS_PATH")" -eq 1 ]
    jq -e '.outcome == "ok"' "$CV_RESULTS_PATH" >/dev/null
}

@test "persistent login DNS is a structured transport failure with no credit PUT" {
    rm -f "$ADMIN_TOKEN_CACHE_PATH"
    call_credit_update login_persistent_dns 1
    [ "$status" -eq 6 ]
    printf '%s' "$output" | jq -e '
        .http_status == null
        and .transport_error.stage == "login"
        and .transport_error.curl_exit == 6
        and .transport_error.attempts == 2
        and .transport_error.retry_exits == [6]
    ' >/dev/null
    [ "$(wc -l < "$CURL_CALLS")" -eq 2 ]
    [ "$(wc -l < "$CV_RESULTS_PATH")" -eq 1 ]
    jq -e '
        .outcome == "transport_error"
        and .error == "login_curl_exit_6"
        and .transport_attempts == 2
        and .transport_retry_exits == [6]
    ' "$CV_RESULTS_PATH" >/dev/null
}
