#!/usr/bin/env bats

# MUSO_ADMIN_IDENTITY: an automation logs in with its own admin credentials,
# parsed (never sourced) from $MUSO_ADMIN_IDENTITY_DIR/<identity>.env, with a
# token cache of its own, and with no fallback to the shared credentials.
# curl is PATH-shadowed and records every call; nothing touches the network.

bats_require_minimum_version 1.5.0

setup() {
    TEST_ROOT="$(mktemp -d)"
    export TEST_ROOT
    SCRIPT="${BATS_TEST_DIRNAME}/../muso-admin-api.sh"

    export MUSO_API_URL="https://example.invalid"
    export MUSO_ADMIN_EMAIL="shared@example.com"
    export MUSO_ADMIN_PASSWORD="shared-password"
    export OPS_DRY_RUN=0
    export CV_APPROVE_GATE_DISABLED=1
    export CV_RESULTS_PATH="$TEST_ROOT/results.jsonl"
    export ADMIN_TOKEN_CACHE_PATH="$TEST_ROOT/token-cache"
    export MUSO_OPS_STATE_DIR="$TEST_ROOT/state"
    export CODEX_HEALTH_LIB="$TEST_ROOT/codex-health.sh"
    export MUSO_ADMIN_IDENTITY_DIR="$TEST_ROOT/identities"
    printf '%s\n' 'codex_health_gate() { return 0; }' > "$CODEX_HEALTH_LIB"
    printf '%s\nshared-token\n' "$(date +%s)" > "$ADMIN_TOKEN_CACHE_PATH"
    mkdir -p "$MUSO_ADMIN_IDENTITY_DIR" "$TEST_ROOT/bin"
    unset CREDIT_TRUST_DECIDE UVN_POPULARITY_CRON REQUESTER_EMAIL MUSO_ADMIN_IDENTITY

    export CURL_LOG="$TEST_ROOT/curl.log"
    cat > "$TEST_ROOT/bin/curl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CURL_LOG"
if [[ "$*" == *"/admin/user/login"* ]]; then
    printf '{"token":"identity-token"}'
    exit 0
fi
printf '{"ok":true,"data":{"items":[]}}\n200'
STUB
    chmod +x "$TEST_ROOT/bin/curl"
    export PATH="$TEST_ROOT/bin:$PATH"
}

teardown() {
    rm -rf "$TEST_ROOT"
}

get_as() {
    run --separate-stderr env MUSO_ADMIN_IDENTITY="$1" bash "$SCRIPT" call GET /admin/credit-requests
}

@test "an identity logs in with its own parsed credentials and token cache" {
    cat > "$MUSO_ADMIN_IDENTITY_DIR/credit-decider.env" <<EOF
# credit-trust-decide
MUSO_ADMIN_EMAIL=decider@example.com
MUSO_ADMIN_PASSWORD="\$(touch $TEST_ROOT/pwned)"
EOF
    get_as credit-decider
    [ "$status" -eq 0 ]
    [ ! -e "$TEST_ROOT/pwned" ]
    grep -q '/admin/user/login' "$CURL_LOG"
    grep -q 'decider@example.com' "$CURL_LOG"
    ! grep -q 'shared@example.com' "$CURL_LOG"
    grep -q 'Bearer identity-token' "$CURL_LOG"
    [ "$(tail -1 "$ADMIN_TOKEN_CACHE_PATH.credit-decider")" = "identity-token" ]
    [ "$(tail -1 "$ADMIN_TOKEN_CACHE_PATH")" = "shared-token" ]
}

@test "without an identity the shared credentials and cache are used" {
    run --separate-stderr bash "$SCRIPT" call GET /admin/credit-requests
    [ "$status" -eq 0 ]
    ! grep -q '/admin/user/login' "$CURL_LOG"
    grep -q 'Bearer shared-token' "$CURL_LOG"
}

@test "an unknown identity, a missing file or an incomplete file fails before any request" {
    get_as main
    [ "$status" -ne 0 ]
    [[ "$stderr" == *"not a known automation identity"* ]]

    get_as uvn-cron
    [ "$status" -ne 0 ]
    [[ "$stderr" == *"no fallback"* ]]

    printf 'MUSO_ADMIN_EMAIL=uvn@example.com\n' > "$MUSO_ADMIN_IDENTITY_DIR/uvn-cron.env"
    get_as uvn-cron
    [ "$status" -ne 0 ]

    printf 'MUSO_ADMIN_EMAIL=uvn@example.com\nnot a key value line\n' > "$MUSO_ADMIN_IDENTITY_DIR/uvn-cron.env"
    get_as uvn-cron
    [ "$status" -ne 0 ]

    [ ! -e "$CURL_LOG" ]
}

@test "default identity dir is the one H-DevOps provisions (/etc/openclaw/agents)" {
    # Regression (2026-10-17): the shipped default pointed at a directory nothing
    # provisions, so both automations failed closed on their first live tick.
    # Read the resolved default from the sourced script (source-safe guard), so the
    # result does not depend on whether the real files exist on this host.
    run --separate-stderr env -u MUSO_ADMIN_IDENTITY_DIR bash -c '. "$1" >/dev/null 2>&1; printf "%s" "$MUSO_ADMIN_IDENTITY_DIR"' _ "$SCRIPT"
    [ "$status" -eq 0 ]
    [ "$output" = "/etc/openclaw/agents" ]
    # The override still wins.
    run --separate-stderr env MUSO_ADMIN_IDENTITY_DIR=/tmp/elsewhere bash -c '. "$1" >/dev/null 2>&1; printf "%s" "$MUSO_ADMIN_IDENTITY_DIR"' _ "$SCRIPT"
    [ "$output" = "/tmp/elsewhere" ]
}
