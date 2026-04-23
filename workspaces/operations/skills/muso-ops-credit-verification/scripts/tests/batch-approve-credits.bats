#!/usr/bin/env bats
bats_require_minimum_version 1.5.0
# Tests for batch-approve-credits.sh — the sanctioned wrapper that replaces
# agent-synthesized approve loops. Root-cause context: the 2026-04-22 19:15
# UTC silent failure where inline bash with body-only evidence + redirected
# stderr + iteration counting produced 0 real approvals while Slack reported
# full success. This wrapper narrows the surface so that the three failure
# modes cannot co-exist with a successful invocation.

setup() {
    TEST_ROOT="$(mktemp -d)"
    export TEST_ROOT

    WRAPPER="${BATS_TEST_DIRNAME}/../batch-approve-credits.sh"
    [[ -x "$WRAPPER" ]] || { echo "WRAPPER missing or not executable: $WRAPPER" >&2; return 1; }

    # Fake muso-admin-api.sh. Behavior is controlled by env vars read at the
    # top of each test, so we can simulate: success+dryrun, success+HTTP 200,
    # gate-rejection-exit-1, HTTP 500, connection refused. The stub writes
    # its invocation args to $ADMIN_LOG so assertions can inspect the exact
    # shape the wrapper sent.
    ADMIN_LOG="$TEST_ROOT/admin-invocations.log"
    export ADMIN_LOG

    ADMIN_API_SH="$TEST_ROOT/fake-muso-admin-api.sh"
    cat > "$ADMIN_API_SH" <<'STUB'
#!/usr/bin/env bash
# Stub muso-admin-api.sh. Logs each invocation and the full body arg on
# separate lines so tests can grep for the literal JSON without worrying
# about shell quoting. Behavior (exit code + stdout) is chosen via STUB_MODE.
{
    printf 'ARGS:'
    # One arg per line after the ARGS header. Args with spaces are preserved
    # as single tokens because `for a in "$@"` iterates once per arg.
    for a in "$@"; do printf '\n  %s' "$a"; done
    printf '\n'
    # The body is the last positional arg for `call <METHOD> <path> <body>`.
    # Emit it separately so tests can do literal `grep '"requestIds":...'`.
    if [[ $# -ge 1 ]]; then
        printf 'LAST_ARG: %s\n' "${!#}"
    fi
} >> "${ADMIN_LOG:-/dev/null}"

case "${STUB_MODE:-success_dryrun}" in
    success_dryrun)
        printf '%s\n' '{"http_status":200,"dryRun":true,"body":null,"wouldHaveExecuted":true}'
        exit 0
        ;;
    success_200)
        printf '%s\n' '{"http_status":200,"body":{"ok":true}}'
        exit 0
        ;;
    rejected_by_gate)
        echo "credit_approve_gate: --evidence-excerpt is required for autonomous approves." >&2
        exit 1
        ;;
    http_500)
        printf '%s\n' '{"http_status":500,"body":{"error":"boom"}}'
        exit 0
        ;;
    connection_refused)
        echo "curl: (7) Failed to connect" >&2
        exit 7
        ;;
    *)
        echo "stub: unknown STUB_MODE=${STUB_MODE}" >&2
        exit 99
        ;;
esac
STUB
    chmod +x "$ADMIN_API_SH"
    export ADMIN_API_SH
}

teardown() {
    rm -rf "$TEST_ROOT"
}

# --- Arg validation (exit 2, no API call) ---

@test "missing --evidence-excerpt → exit 2, no API call attempted" {
    run bash "$WRAPPER" --profile-id p1 --ids "cr_1,cr_2"
    [ "$status" -eq 2 ]
    [[ "$output" == *"--evidence-excerpt is required"* ]]
    [ ! -f "$ADMIN_LOG" ]
}

@test "empty --evidence-excerpt → exit 2, no API call" {
    run bash "$WRAPPER" --profile-id p1 --evidence-excerpt "" --ids "cr_1"
    [ "$status" -eq 2 ]
    [[ "$output" == *"--evidence-excerpt is required"* ]]
    [ ! -f "$ADMIN_LOG" ]
}

@test "--evidence-excerpt shorter than min → exit 2" {
    # Default floor is 8; pass 5 chars.
    run bash "$WRAPPER" --profile-id p1 --evidence-excerpt "short" --ids "cr_1"
    [ "$status" -eq 2 ]
    [[ "$output" == *">=8"* ]] || [[ "$output" == *">="* ]]
    [ ! -f "$ADMIN_LOG" ]
}

@test "--evidence-excerpt longer than max → exit 2" {
    local long_excerpt
    long_excerpt=$(printf 'x%.0s' {1..250})
    run bash "$WRAPPER" --profile-id p1 --evidence-excerpt "$long_excerpt" --ids "cr_1"
    [ "$status" -eq 2 ]
    [[ "$output" == *"<=200"* ]] || [[ "$output" == *"<="* ]]
    [ ! -f "$ADMIN_LOG" ]
}

@test "missing --profile-id → exit 2" {
    run bash "$WRAPPER" --evidence-excerpt "Jose Roig engineer" --ids "cr_1"
    [ "$status" -eq 2 ]
    [[ "$output" == *"--profile-id is required"* ]]
    [ ! -f "$ADMIN_LOG" ]
}

@test "missing --ids → exit 2" {
    run bash "$WRAPPER" --profile-id p1 --evidence-excerpt "Jose Roig engineer"
    [ "$status" -eq 2 ]
    [[ "$output" == *"--ids is required"* ]]
    [ ! -f "$ADMIN_LOG" ]
}

@test "empty --ids → exit 2" {
    run bash "$WRAPPER" --profile-id p1 --evidence-excerpt "Jose Roig engineer" --ids ""
    [ "$status" -eq 2 ]
    [[ "$output" == *"--ids is required"* ]]
    [ ! -f "$ADMIN_LOG" ]
}

@test "--ids with empty entry (trailing comma, double comma) → exit 2" {
    # Forbid silent "approve to empty path". Backend would 404 and we'd
    # potentially double-charge the gate. Fail fast locally.
    run bash "$WRAPPER" --profile-id p1 --evidence-excerpt "Jose Roig engineer" --ids "cr_1,,cr_2"
    [ "$status" -eq 2 ]
    [[ "$output" == *"empty entry"* ]]
    [ ! -f "$ADMIN_LOG" ]
}

@test "--requester is refused → exit 2 with explicit human-override guidance" {
    run bash "$WRAPPER" --requester aaron@muso.ai --profile-id p1 --evidence-excerpt "Jose Roig engineer" --ids "cr_1"
    [ "$status" -eq 2 ]
    [[ "$output" == *"--requester is forbidden"* ]]
    [[ "$output" == *"autonomous batches only"* ]] || [[ "$output" == *"human-authorized"* ]]
    [ ! -f "$ADMIN_LOG" ]
}

@test "unknown argument → exit 2" {
    run bash "$WRAPPER" --profile-id p1 --evidence-excerpt "Jose Roig engineer" --ids "cr_1" --unknown-flag foo
    [ "$status" -eq 2 ]
    [[ "$output" == *"unknown argument"* ]]
}

# --- Successful invocations ---

@test "happy path (dry-run response) → exit 0 with outcome=dry_run_intercept" {
    STUB_MODE=success_dryrun \
        run bash "$WRAPPER" --profile-id p1 --evidence-excerpt "Jose Roig engineer" --ids "cr_1,cr_2,cr_3"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.profile_id == "p1" and .requested == 3 and .outcome == "dry_run_intercept" and .http_status == 200' >/dev/null
}

@test "happy path (real 200) → exit 0 with outcome=ok" {
    STUB_MODE=success_200 \
        run bash "$WRAPPER" --profile-id p1 --evidence-excerpt "Jose Roig engineer" --ids "cr_1"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.outcome == "ok" and .http_status == 200' >/dev/null
}

@test "happy path: --evidence-excerpt is passed to admin script as a CLI flag (not body field)" {
    # This is THE regression pin. The 2026-04-22 silent failure put evidence
    # in the JSON body. Confirm the wrapper passes it as the --evidence-excerpt
    # global option, which is the only form the gate reads.
    STUB_MODE=success_dryrun bash "$WRAPPER" --profile-id p1 --evidence-excerpt "Jose Roig engineer at Sony" --ids "cr_1,cr_2" >/dev/null
    grep -qF -- '--evidence-excerpt' "$ADMIN_LOG"
    grep -qF 'Jose Roig engineer at Sony' "$ADMIN_LOG"
}

@test "happy path: PUT /admin/credit-requests is used (batch verb), not per-id PATCH" {
    # Batch PUT means one gate check + one HTTP call for N credits — strictly
    # cheaper and eliminates per-id loops that obscure partial failures.
    STUB_MODE=success_dryrun bash "$WRAPPER" --profile-id p1 --evidence-excerpt "Jose Roig engineer" --ids "cr_1,cr_2,cr_3,cr_4" >/dev/null
    grep -qF 'PUT' "$ADMIN_LOG"
    grep -qF '/admin/credit-requests' "$ADMIN_LOG"
    # No PATCHes for this single invocation — batch PUT covers all.
    ! grep -qF 'PATCH' "$ADMIN_LOG"
    # One invocation only (one ARGS header line).
    [ "$(grep -c '^ARGS:' "$ADMIN_LOG")" -eq 1 ]
}

@test "happy path: request body contains requestIds from --ids and status=approved" {
    STUB_MODE=success_dryrun bash "$WRAPPER" --profile-id p1 --evidence-excerpt "Jose Roig engineer" --ids "cr_1,cr_2" >/dev/null
    # The body is on the LAST_ARG: line. Parse it as JSON and validate.
    body_line=$(grep '^LAST_ARG:' "$ADMIN_LOG" | sed 's/^LAST_ARG: //')
    echo "$body_line" | jq -e '.requestIds == ["cr_1","cr_2"] and .status == "approved"' >/dev/null
}

@test "happy path: trims surrounding whitespace from ids" {
    # Defensive — a caller that passes "cr_1, cr_2 ,cr_3" shouldn't accidentally
    # send " cr_2 " as an id. Trim to make the behaviour predictable.
    STUB_MODE=success_dryrun bash "$WRAPPER" --profile-id p1 --evidence-excerpt "Jose Roig engineer" --ids "cr_1, cr_2 ,cr_3" >/dev/null
    body_line=$(grep '^LAST_ARG:' "$ADMIN_LOG" | sed 's/^LAST_ARG: //')
    echo "$body_line" | jq -e '.requestIds == ["cr_1","cr_2","cr_3"]' >/dev/null
}

# --- Failure paths (exit 1, API call was attempted) ---

@test "gate rejection → exit 1, outcome=rejected_by_gate, stderr surfaces reason" {
    # The gate emits its reason on stderr. The wrapper MUST NOT swallow it —
    # that's how 2026-04-22 went silent. `run` captures stdout only; use
    # --separate-stderr to capture both.
    STUB_MODE=rejected_by_gate run --separate-stderr bash "$WRAPPER" \
        --profile-id p1 --evidence-excerpt "Jose Roig engineer" --ids "cr_1"
    [ "$status" -eq 1 ]
    [[ "$stderr" == *"--evidence-excerpt is required for autonomous approves"* ]]
    # stdout summary still emitted even on failure — reconciliation wants it.
    echo "$output" | jq -e '.outcome == "rejected_by_gate"' >/dev/null
}

@test "HTTP 500 response → exit 1, outcome=http_error" {
    STUB_MODE=http_500 run bash "$WRAPPER" --profile-id p1 --evidence-excerpt "Jose Roig engineer" --ids "cr_1"
    [ "$status" -eq 1 ]
    echo "$output" | jq -e '.outcome == "http_error" and .http_status == 500' >/dev/null
}

@test "connection refused (curl non-zero exit) → exit 1, stderr surfaces curl error" {
    # When the admin script itself exits non-zero for reasons other than
    # the gate (e.g. curl 7), the wrapper can only tell it failed. It
    # classifies as rejected_by_gate in the summary (the wrapper can't
    # introspect WHY rc!=0) but the stderr from the admin script must
    # reach the agent transcript so the real cause is visible.
    STUB_MODE=connection_refused run --separate-stderr bash "$WRAPPER" \
        --profile-id p1 --evidence-excerpt "Jose Roig engineer" --ids "cr_1"
    [ "$status" -eq 1 ]
    [[ "$stderr" == *"Failed to connect"* ]]
}

# --- The regression invariant ---

@test "CORE INVARIANT: caller redirecting stdout+stderr does NOT produce exit 0 on failure" {
    # The EXACT failure shape from 2026-04-22: run wrapper under > /dev/null 2>&1.
    # The exit code must still reflect reality so `run_profile`-style loops
    # that silence output can NO LONGER claim success.
    export STUB_MODE=rejected_by_gate
    rc=0
    bash "$WRAPPER" --profile-id p1 --evidence-excerpt "Jose Roig engineer" --ids "cr_1" >/dev/null 2>&1 || rc=$?
    [ "$rc" -ne 0 ]
}

@test "admin script absent → exit 2 (plumbing failure surfaces, no bogus success)" {
    ADMIN_API_SH=/nonexistent/muso-admin-api.sh \
        run bash "$WRAPPER" --profile-id p1 --evidence-excerpt "Jose Roig engineer" --ids "cr_1"
    [ "$status" -eq 2 ]
    [[ "$output" == *"muso-admin-api.sh not found"* ]]
}
