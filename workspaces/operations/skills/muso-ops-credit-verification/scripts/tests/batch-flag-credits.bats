#!/usr/bin/env bats
bats_require_minimum_version 1.5.0
# Tests for batch-flag-credits.sh — the sanctioned wrapper for UVN flagging.
# Symmetric with batch-approve-credits.sh: same arg-validation discipline,
# same refusal of --requester, same truth-floor reliance. The key structural
# difference is that flag batches iterate PATCH per-id (the API has no
# batch UVN endpoint), so we assert per-id exit-code tallying.

setup() {
    TEST_ROOT="$(mktemp -d)"
    export TEST_ROOT

    WRAPPER="${BATS_TEST_DIRNAME}/../batch-flag-credits.sh"
    [[ -x "$WRAPPER" ]] || { echo "WRAPPER missing or not executable: $WRAPPER" >&2; return 1; }

    ADMIN_LOG="$TEST_ROOT/admin-invocations.log"
    export ADMIN_LOG

    # Fake admin script with per-call behavior. STUB_MODE can be a global
    # default; STUB_MODE_<id> overrides for a specific id so we can simulate
    # a partial failure (2 succeed, 1 fails) and assert the tally.
    ADMIN_API_SH="$TEST_ROOT/fake-muso-admin-api.sh"
    cat > "$ADMIN_API_SH" <<'STUB'
#!/usr/bin/env bash
# Log the invocation for later assertions.
{
    printf 'ARGS:'
    for a in "$@"; do printf '\n  %s' "$a"; done
    printf '\n'
    if [[ $# -ge 1 ]]; then
        printf 'LAST_ARG: %s\n' "${!#}"
    fi
} >> "${ADMIN_LOG:-/dev/null}"

# Extract id from the PATCH path: /admin/credit-requests/<id>.
id_from_path=""
for a in "$@"; do
    if [[ "$a" == /admin/credit-requests/* ]]; then
        id_from_path="${a#/admin/credit-requests/}"
    fi
done

# Per-id override (e.g. STUB_MODE_cr_2=http_500). Fallback to the global
# STUB_MODE. Uses indirect expansion so the lookup matches exactly.
mode_var="STUB_MODE_${id_from_path}"
mode="${!mode_var:-${STUB_MODE:-success_dryrun}}"

case "$mode" in
    success_dryrun)
        printf '%s\n' '{"http_status":200,"dryRun":true,"body":null,"wouldHaveExecuted":true}'
        exit 0
        ;;
    success_200)
        printf '%s\n' '{"http_status":200,"body":{"ok":true}}'
        exit 0
        ;;
    http_500)
        printf '%s\n' '{"http_status":500,"body":{"error":"boom"}}'
        exit 0
        ;;
    connection_refused)
        echo "curl: (7) Failed to connect to ${id_from_path}" >&2
        exit 7
        ;;
    *)
        echo "stub: unknown mode=${mode}" >&2
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

# --- Arg validation ---

@test "missing --profile-id → exit 2" {
    run bash "$WRAPPER" --reason high_velocity --ids "cr_1"
    [ "$status" -eq 2 ]
    [[ "$output" == *"--profile-id is required"* ]]
    [ ! -f "$ADMIN_LOG" ]
}

@test "missing --reason → exit 2" {
    run bash "$WRAPPER" --profile-id p1 --ids "cr_1"
    [ "$status" -eq 2 ]
    [[ "$output" == *"--reason is required"* ]]
    [ ! -f "$ADMIN_LOG" ]
}

@test "missing --ids → exit 2" {
    run bash "$WRAPPER" --profile-id p1 --reason high_velocity
    [ "$status" -eq 2 ]
    [[ "$output" == *"--ids is required"* ]]
    [ ! -f "$ADMIN_LOG" ]
}

@test "empty --ids entry → exit 2" {
    run bash "$WRAPPER" --profile-id p1 --reason high_velocity --ids "cr_1,,cr_2"
    [ "$status" -eq 2 ]
    [[ "$output" == *"empty entry"* ]]
    [ ! -f "$ADMIN_LOG" ]
}

@test "--requester is refused → exit 2" {
    run bash "$WRAPPER" --requester aaron@muso.ai --profile-id p1 --reason high_velocity --ids "cr_1"
    [ "$status" -eq 2 ]
    [[ "$output" == *"--requester is forbidden"* ]]
    [ ! -f "$ADMIN_LOG" ]
}

@test "unknown argument → exit 2" {
    run bash "$WRAPPER" --profile-id p1 --reason r --ids "cr_1" --unknown foo
    [ "$status" -eq 2 ]
    [[ "$output" == *"unknown argument"* ]]
}

# --- Successful paths ---

@test "happy path (dry-run) → exit 0, each id gets its own PATCH" {
    STUB_MODE=success_dryrun run bash "$WRAPPER" --profile-id p1 --reason high_velocity --ids "cr_1,cr_2,cr_3"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.requested == 3 and .succeeded == 3 and .failed == 0 and .outcome == "ok" and .failed_ids == []' >/dev/null
    # Three ARGS headers → three invocations.
    [ "$(grep -c '^ARGS:' "$ADMIN_LOG")" -eq 3 ]
    # Each invocation targets /admin/credit-requests/<id>.
    grep -qF '/admin/credit-requests/cr_1' "$ADMIN_LOG"
    grep -qF '/admin/credit-requests/cr_2' "$ADMIN_LOG"
    grep -qF '/admin/credit-requests/cr_3' "$ADMIN_LOG"
    # Body is user_verification_needed with the reason.
    body_lines=$(grep '^LAST_ARG:' "$ADMIN_LOG" | sed 's/^LAST_ARG: //')
    for line in $body_lines; do : ; done  # no-op, just counting
    # Parse each body line and assert shape.
    while IFS= read -r line; do
        echo "$line" | jq -e '.status == "user_verification_needed" and .reason == "high_velocity"' >/dev/null
    done < <(grep '^LAST_ARG:' "$ADMIN_LOG" | sed 's/^LAST_ARG: //')
}

@test "happy path (real 200): no --evidence-excerpt flag in invocation (UVN is ungated)" {
    STUB_MODE=success_200 bash "$WRAPPER" --profile-id p1 --reason high_velocity --ids "cr_1" >/dev/null
    # UVN does NOT need evidence, so the wrapper must NOT pass the flag.
    # If it did, a future gate that also enforces for UVN would block batches.
    ! grep -qF -- '--evidence-excerpt' "$ADMIN_LOG"
}

# --- Partial failure (the core exit-code discipline) ---

@test "partial failure: 2 of 3 succeed → exit 1 with failed_ids list" {
    # Simulate: cr_1 ok, cr_2 http_500, cr_3 ok. Must still PATCH all three
    # (never terminate on first failure) so reconciliation sees the full
    # attempted batch. Exit is 1 because there was at least one failure.
    export STUB_MODE=success_dryrun
    export STUB_MODE_cr_2=http_500
    run bash "$WRAPPER" --profile-id p1 --reason high_velocity --ids "cr_1,cr_2,cr_3"
    [ "$status" -eq 1 ]
    echo "$output" | jq -e '.requested == 3 and .succeeded == 2 and .failed == 1 and .failed_ids == ["cr_2"] and .outcome == "partial_failure"' >/dev/null
    # Prove we still attempted all three — loop did not short-circuit.
    [ "$(grep -c '^ARGS:' "$ADMIN_LOG")" -eq 3 ]
}

@test "all fail (HTTP 500 on every id) → exit 1, failed == requested" {
    export STUB_MODE=http_500
    run bash "$WRAPPER" --profile-id p1 --reason high_velocity --ids "cr_1,cr_2"
    [ "$status" -eq 1 ]
    echo "$output" | jq -e '.requested == 2 and .succeeded == 0 and .failed == 2 and (.failed_ids | sort) == ["cr_1","cr_2"]' >/dev/null
}

@test "connection refused on one id → that id counted as failed, stderr surfaces" {
    # Non-zero admin-api rc (curl 7) must be counted as a failure, not a
    # success. This is the direct analog of the approve wrapper's silent-
    # failure regression pin, for UVN.
    export STUB_MODE=success_dryrun
    export STUB_MODE_cr_2=connection_refused
    run --separate-stderr bash "$WRAPPER" --profile-id p1 --reason high_velocity --ids "cr_1,cr_2,cr_3"
    [ "$status" -eq 1 ]
    echo "$output" | jq -e '.failed == 1 and .failed_ids == ["cr_2"]' >/dev/null
    [[ "$stderr" == *"Failed to connect to cr_2"* ]]
}

# --- Regression invariant ---

@test "CORE INVARIANT: redirecting stdout+stderr does NOT produce exit 0 on failure" {
    # The exact failure shape from 2026-04-22's inline flag_uvn loop.
    export STUB_MODE=http_500
    rc=0
    bash "$WRAPPER" --profile-id p1 --reason high_velocity --ids "cr_1" >/dev/null 2>&1 || rc=$?
    [ "$rc" -ne 0 ]
}

@test "admin script absent → exit 2 (plumbing failure surfaces)" {
    ADMIN_API_SH=/nonexistent/muso-admin-api.sh \
        run bash "$WRAPPER" --profile-id p1 --reason r --ids "cr_1"
    [ "$status" -eq 2 ]
    [[ "$output" == *"muso-admin-api.sh not found"* ]]
}
