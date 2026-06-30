#!/usr/bin/env bats
# Tests for the misplaced-flag guard in muso-admin-api.sh cmd_call (incident
# 2026-06-30). Global flags (--requester / --confirmed-by / --approval-msg-id /
# --profile-audit-id) must precede the `call` subcommand. Left AFTER the path
# they land as the positional JSON body; the API then 400s on a body-parse
# failure that core-backend masks behind a generic "Unavailable service" — read
# at the time as a phantom service outage. The guard refuses such a body (one
# that starts with "--", which a real JSON body never does) BEFORE any HTTP
# call, dry-run short-circuit, or gate, and exits non-zero with guidance.

setup() {
    TEST_ROOT="$(mktemp -d)"; export TEST_ROOT
    SCRIPT="${BATS_TEST_DIRNAME}/../muso-admin-api.sh"
    [[ -f "$SCRIPT" ]] || { echo "SCRIPT not found: $SCRIPT" >&2; return 1; }

    # Closed port: if the guard ever failed to fire and we reached curl, a real
    # request would error loudly rather than silently "passing".
    export MUSO_API_URL="http://127.0.0.1:1"
    export MUSO_ADMIN_EMAIL="test@example.com"
    export MUSO_ADMIN_PASSWORD="unused"
    export OPS_DRY_RUN_AUDIT_PATH="$TEST_ROOT/audit.jsonl"
    export CV_RESULTS_PATH="$TEST_ROOT/results.jsonl"
    export CV_APPROVE_GATE_DISABLED=1
    export CODEX_HEALTH_LIB="$TEST_ROOT/codex-health-stub.sh"
    printf '%s\n' 'codex_health_gate() { return 0; }' > "$CODEX_HEALTH_LIB"

    local script_dir
    script_dir="$(cd "$(dirname "$SCRIPT")" && pwd)"
    printf '%s\ndummy-token\n' "$(date +%s)" > "$script_dir/.admin-token-cache"
    chmod 600 "$script_dir/.admin-token-cache"
    TOKEN_CACHE_SEED="$script_dir/.admin-token-cache"
}

teardown() {
    rm -rf "$TEST_ROOT"
    rm -f "${TOKEN_CACHE_SEED:-}"
}

@test "guard: --requester misplaced after path (as body) is refused, exit !=0" {
    run bash "$SCRIPT" call DELETE /admin/track/t1/profile/p1/credits --requester ops@muso.ai
    [ "$status" -ne 0 ]
    [[ "$output" == *"misplaced flag"* ]]
    [[ "$output" == *"--requester"* ]]
    # Did NOT produce a synthetic dry-run 200 (it failed loud before the API).
    ! echo "$output" | jq -e '.dryRun == true' >/dev/null 2>&1
    # No audit line written — the malformed call never reached the write path.
    [ ! -s "${OPS_DRY_RUN_AUDIT_PATH:-/nonexistent}" ]
}

@test "guard: fires even in dry-run mode (never a synthetic 200 for a malformed body)" {
    OPS_DRY_RUN=1 run bash "$SCRIPT" call DELETE /admin/profile/p1/credits --requester ops@muso.ai
    [ "$status" -ne 0 ]
    [[ "$output" == *"misplaced flag"* ]]
    ! echo "$output" | jq -e '.dryRun == true' >/dev/null 2>&1
}

@test "guard: --confirmed-by misplaced as body is also refused" {
    run bash "$SCRIPT" call POST /admin/track/t1/profile/p1/credits --confirmed-by aaron
    [ "$status" -ne 0 ]
    [[ "$output" == *"misplaced flag"* ]]
}

@test "guard: error message points at the correct order" {
    run bash "$SCRIPT" call DELETE /admin/track/t1/profile/p1/credits --requester ops@muso.ai
    [[ "$output" == *"Global flags go BEFORE the command"* ]]
    [[ "$output" == *"call DELETE"* ]]
}

@test "no false positive: a normal JSON body is NOT treated as a flag (dry-run intercept works)" {
    OPS_DRY_RUN=1 run bash "$SCRIPT" call POST /admin/track/t1/profile/p1/credits '{"role":"producer"}'
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.dryRun == true' >/dev/null
}

@test "no false positive: empty body is fine (DELETE with no body, dry-run intercept)" {
    OPS_DRY_RUN=1 run bash "$SCRIPT" call DELETE /admin/track/t1/profile/p1/credits ''
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.dryRun == true' >/dev/null
}

@test "no false positive: correct order (--requester BEFORE call) passes the guard" {
    OPS_DRY_RUN=1 run bash "$SCRIPT" --requester ops@muso.ai call DELETE /admin/track/t1/profile/p1/credits
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.dryRun == true' >/dev/null
}
