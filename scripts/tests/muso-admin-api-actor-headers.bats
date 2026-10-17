#!/usr/bin/env bats

# MUS-5303: muso-admin-api.sh forwards --confirmed-by / --approval-msg-id to the
# backend as `Approved-By` / `Request-Ref` (audit only, never a gate). Absent
# flags => the headers are absent entirely, not present-and-empty.
# Asserts on the argv the curl stub captured, for both request paths
# (call = send_request, upload) in both deployed copies.

bats_require_minimum_version 1.5.0

setup() {
    TEST_ROOT="$(mktemp -d)"
    export TEST_ROOT
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    WRAPPERS=(
        "$REPO_ROOT/skills-all/muso-ops-admin/scripts/muso-admin-api.sh"
        "$REPO_ROOT/workspaces/operations/skills/muso-ops-admin/scripts/muso-admin-api.sh"
    )

    export MUSO_API_URL="https://example.invalid"
    export MUSO_ADMIN_EMAIL="test@example.com"
    export MUSO_ADMIN_PASSWORD="unused"
    export OPS_DRY_RUN=0
    export CV_APPROVE_GATE_DISABLED=1
    export CV_RESULTS_PATH="$TEST_ROOT/results.jsonl"
    export ADMIN_TOKEN_CACHE_PATH="$TEST_ROOT/token-cache"
    export MUSO_OPS_STATE_DIR="$TEST_ROOT/state"
    export CODEX_HEALTH_LIB="$TEST_ROOT/codex-health.sh"
    export CURL_ARGS="$TEST_ROOT/curl.args"
    printf '%s\n' 'codex_health_gate() { return 0; }' > "$CODEX_HEALTH_LIB"
    printf '%s\ndummy-token\n' "$(date +%s)" > "$ADMIN_TOKEN_CACHE_PATH"
    printf 'jpeg fixture\n' > "$TEST_ROOT/avatar.jpg"
    unset CONFIRMED_BY APPROVAL_MSG_ID REQUESTER_EMAIL

    mkdir -p "$TEST_ROOT/bin"
    cat > "$TEST_ROOT/bin/curl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$CURL_ARGS"
printf '{"ok":true}\n200'
STUB
    chmod +x "$TEST_ROOT/bin/curl"
    export PATH="$TEST_ROOT/bin:$PATH"
}

teardown() {
    rm -rf "$TEST_ROOT"
}

# Run one request path ("call" or "upload") through a wrapper, extra flags first.
run_path() {
    local wrapper="$1" kind="$2"; shift 2
    rm -f "$CURL_ARGS"
    if [[ "$kind" == call ]]; then
        run bash "$wrapper" "$@" call GET /admin/ping
    else
        run bash "$wrapper" "$@" upload PUT /admin/profile/p1/image "$TEST_ROOT/avatar.jpg"
    fi
    [ "$status" -eq 0 ]
    [ -f "$CURL_ARGS" ]
}

@test "approval flags => Approved-By and Request-Ref reach curl (call + upload, both copies)" {
    local wrapper kind
    for wrapper in "${WRAPPERS[@]}"; do
        for kind in call upload; do
            run_path "$wrapper" "$kind" --confirmed-by X --approval-msg-id T
            grep -qxF 'Approved-By: X' "$CURL_ARGS"
            grep -qxF 'Request-Ref: T' "$CURL_ARGS"
        done
    done
}

@test "no approval flags => neither header is present at all" {
    local wrapper kind
    for wrapper in "${WRAPPERS[@]}"; do
        for kind in call upload; do
            run_path "$wrapper" "$kind"
            if grep -qi '^Approved-By' "$CURL_ARGS"; then false; fi
            if grep -qi '^Request-Ref' "$CURL_ARGS"; then false; fi
        done
    done
}

@test "Service and Requester are unchanged with and without the new headers" {
    local wrapper kind
    for wrapper in "${WRAPPERS[@]}"; do
        for kind in call upload; do
            run_path "$wrapper" "$kind" --requester operator@example.com
            grep -qxF 'Service: clio' "$CURL_ARGS"
            grep -qxF 'Requester: operator@example.com' "$CURL_ARGS"
            run_path "$wrapper" "$kind" --requester operator@example.com --confirmed-by X --approval-msg-id T
            grep -qxF 'Service: clio' "$CURL_ARGS"
            grep -qxF 'Requester: operator@example.com' "$CURL_ARGS"
        done
    done
}

@test "each header is independent: one flag sends only its own header" {
    local wrapper
    for wrapper in "${WRAPPERS[@]}"; do
        run_path "$wrapper" call --confirmed-by X
        grep -qxF 'Approved-By: X' "$CURL_ARGS"
        if grep -qi '^Request-Ref' "$CURL_ARGS"; then false; fi
        run_path "$wrapper" call --approval-msg-id T
        grep -qxF 'Request-Ref: T' "$CURL_ARGS"
        if grep -qi '^Approved-By' "$CURL_ARGS"; then false; fi
    done
}

# An audit header that carries no approver is worse than none: it reads as
# "approved by <blank>". Empty and whitespace-only values behave as absent.
@test "empty or whitespace-only approval flags => treated as absent, never forwarded" {
    local wrapper kind v
    for wrapper in "${WRAPPERS[@]}"; do
        for kind in call upload; do
            for v in "" " " "   " $'\t' $' \t '; do
                run_path "$wrapper" "$kind" --confirmed-by "$v" --approval-msg-id "$v"
                if grep -qi '^Approved-By' "$CURL_ARGS"; then false; fi
                if grep -qi '^Request-Ref' "$CURL_ARGS"; then false; fi
            done
        done
    done
}
