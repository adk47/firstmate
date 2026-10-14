#!/usr/bin/env bats
# Outcome ledger for tier-2 destructive writes (MUS-10535). destructive-ops.jsonl
# is written BEFORE the call as a blast-radius counter and never says whether the
# DELETE worked. destructive-ops-results.jsonl is the post-call companion: one
# row per recorded attempt, keyed back by the (epoch, path) pair.
# curl is PATH-shadowed; nothing touches the network.

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
    export CV_RESULTS_PATH="$TEST_ROOT/credit-results.jsonl"
    export ADMIN_TOKEN_CACHE_PATH="$TEST_ROOT/token-cache"
    export MUSO_OPS_STATE_DIR="$TEST_ROOT/state"
    export BULK_DESTRUCTIVE_PATH="$TEST_ROOT/state/destructive-ops.jsonl"
    export BULK_DESTRUCTIVE_AUDIT_PATH="$TEST_ROOT/state/bulk-destructive-audit.jsonl"
    export BULK_DESTRUCTIVE_RESULTS_PATH="$TEST_ROOT/state/destructive-ops-results.jsonl"
    export BULK_DESTRUCTIVE_THRESHOLD=50
    export BULK_DESTRUCTIVE_EXCLUDE_PATH="$TEST_ROOT/exclude.txt"
    : > "$BULK_DESTRUCTIVE_EXCLUDE_PATH"
    export TIER2_ENDPOINTS_PATH="$TEST_ROOT/tier2-endpoints.txt"
    : > "$TIER2_ENDPOINTS_PATH"
    export CODEX_HEALTH_LIB="$TEST_ROOT/codex-health.sh"
    printf '%s\n' 'codex_health_gate() { return 0; }' > "$CODEX_HEALTH_LIB"
    printf '%s\ndummy-token\n' "$(date +%s)" > "$ADMIN_TOKEN_CACHE_PATH"

    mkdir -p "$TEST_ROOT/bin"
    cat > "$TEST_ROOT/bin/curl" <<'STUB'
#!/usr/bin/env bash
case "${CURL_STUB_MODE:-ok}" in
    http_500) printf '{"error":"server"}\n500' ;;
    transport) printf '\n000'; exit 7 ;;
    *) printf '{"ok":true}\n200' ;;
esac
STUB
    chmod +x "$TEST_ROOT/bin/curl"
    export PATH="$TEST_ROOT/bin:$PATH"
}

teardown() {
    rm -rf "$TEST_ROOT"
}

del() {
    run --separate-stderr env CURL_STUB_MODE="$1" bash "$SCRIPT" --requester jan@muso.ai call DELETE "${2:-/admin/track/abc}"
}

@test "200 DELETE writes one outcome=ok row keyed to the counter row" {
    del ok
    [ "$status" -eq 0 ]
    [ "$(wc -l < "$BULK_DESTRUCTIVE_RESULTS_PATH")" -eq 1 ]
    jq -e '.outcome == "ok" and .http_status == 200 and .method == "DELETE"
           and .path == "/admin/track/abc" and .requester == "jan@muso.ai" and (.ts | length > 0)' \
        "$BULK_DESTRUCTIVE_RESULTS_PATH" >/dev/null
    # correlation: the (epoch, path) pair equals the pre-call row's
    [ "$(jq -c '[.epoch,.path]' "$BULK_DESTRUCTIVE_PATH")" = "$(jq -c '[.epoch,.path]' "$BULK_DESTRUCTIVE_RESULTS_PATH")" ]
}

@test "500 DELETE writes outcome=http_error with status 500" {
    del http_500
    jq -e '.outcome == "http_error" and .http_status == 500' "$BULK_DESTRUCTIVE_RESULTS_PATH" >/dev/null
}

@test "curl transport failure writes outcome=transport_error with null status" {
    del transport
    [ "$(wc -l < "$BULK_DESTRUCTIVE_RESULTS_PATH")" -eq 1 ]
    jq -e '.outcome == "transport_error" and .http_status == null' "$BULK_DESTRUCTIVE_RESULTS_PATH" >/dev/null
}

@test "13-Oct trio: two ok and one failure are distinguishable without a prod read" {
    del ok /admin/track/a
    del ok /admin/track/b
    del http_500 /admin/track/c
    [ "$(jq -s '[.[]|select(.outcome=="ok")]|length' "$BULK_DESTRUCTIVE_RESULTS_PATH")" -eq 2 ]
    [ "$(jq -s '[.[]|select(.outcome!="ok")]|length' "$BULK_DESTRUCTIVE_RESULTS_PATH")" -eq 1 ]
    [ "$(wc -l < "$BULK_DESTRUCTIVE_PATH")" -eq 3 ]
}

@test "unwritable results path warns on stderr and still returns the API response" {
    mkdir -p "$TEST_ROOT/state"
    mkdir "$BULK_DESTRUCTIVE_RESULTS_PATH"   # a directory: append must fail
    del ok
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"MUSO_DESTRUCTIVE_OUTCOME_UNWRITABLE"* ]]
    printf '%s' "$output" | jq -e '.http_status == 200' >/dev/null
}

@test "counter file rows are byte-identical in shape (no outcome fields leak in)" {
    del ok
    jq -e 'keys == ["epoch","method","path","requester","ts"]' "$BULK_DESTRUCTIVE_PATH" >/dev/null
}

@test "excluded (non-counted) DELETE gets no outcome row" {
    echo '/admin/profile/*/cache' > "$BULK_DESTRUCTIVE_EXCLUDE_PATH"
    del ok /admin/profile/p1/cache
    [ ! -e "$BULK_DESTRUCTIVE_RESULTS_PATH" ]
}

@test "GET writes no outcome row" {
    run --separate-stderr env bash "$SCRIPT" call GET /admin/track/abc
    [ ! -e "$BULK_DESTRUCTIVE_RESULTS_PATH" ]
}
