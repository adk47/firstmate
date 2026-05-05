#!/usr/bin/env bats
bats_require_minimum_version 1.5.0
# Tests for batch-flag-credits.sh — the sanctioned wrapper for UVN flagging.
#
# 2026-04-27 endpoint correction: the wrapper used to issue per-id
# `PATCH /admin/credit-requests/<id>` in a loop, but core-backend never
# registered that route — every PATCH returned HTTP 404 ("Cannot PATCH
# /api/v3/admin/credit-requests/<id>"). The 2026-04-27 15:42 UTC real run
# was the post-mortem (25/25 errored). The wrapper now uses the same
# batch endpoint as approves: one `PUT /admin/credit-requests` with
# `{requestIds:[...],status:"user_verification_needed"}`. The backend
# `updateStatus` handler accepts every CreditRequests.STATUSES value.

setup() {
    TEST_ROOT="$(mktemp -d)"
    export TEST_ROOT

    WRAPPER="${BATS_TEST_DIRNAME}/../batch-flag-credits.sh"
    [[ -x "$WRAPPER" ]] || { echo "WRAPPER missing or not executable: $WRAPPER" >&2; return 1; }

    ADMIN_LOG="$TEST_ROOT/admin-invocations.log"
    export ADMIN_LOG

    # Fake admin script. Single STUB_MODE selects behavior — there is no
    # per-id override anymore because the wrapper makes one batch call,
    # not N per-id calls. Logs invocation args + body for assertions.
    ADMIN_API_SH="$TEST_ROOT/fake-muso-admin-api.sh"
    cat > "$ADMIN_API_SH" <<'STUB'
#!/usr/bin/env bash
{
    printf 'ARGS:'
    for a in "$@"; do printf '\n  %s' "$a"; done
    printf '\n'
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
    http_500)
        printf '%s\n' '{"http_status":500,"body":{"error":"boom"}}'
        exit 0
        ;;
    http_404_patch_legacy)
        # Captures the exact 2026-04-27 prod failure shape — the bug we
        # fixed by switching to PUT. This stub mode exists so a future
        # regression that revives PATCH would trip a test, not prod.
        printf '%s\n' '{"http_status":404,"body":"Cannot PATCH /api/v3/admin/credit-requests/<id>"}'
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

# --- Arg validation ---

@test "missing --profile-id → exit 2" {
    run bash "$WRAPPER" --reason high_velocity --ids "cr_1" --flag-reason name_mismatch
    [ "$status" -eq 2 ]
    [[ "$output" == *"--profile-id is required"* ]]
    [ ! -f "$ADMIN_LOG" ]
}

@test "missing --reason → exit 2 (caller discipline; never UVN reasonless)" {
    run bash "$WRAPPER" --profile-id p1 --ids "cr_1" --flag-reason name_mismatch
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
    run bash "$WRAPPER" --profile-id p1 --reason high_velocity --ids "cr_1,,cr_2" --flag-reason name_mismatch
    [ "$status" -eq 2 ]
    [[ "$output" == *"empty entry"* ]]
    [ ! -f "$ADMIN_LOG" ]
}

@test "--requester is refused → exit 2" {
    run bash "$WRAPPER" --requester aaron@muso.ai --profile-id p1 --reason high_velocity --ids "cr_1" --flag-reason name_mismatch
    [ "$status" -eq 2 ]
    [[ "$output" == *"--requester is forbidden"* ]]
    [ ! -f "$ADMIN_LOG" ]
}

@test "unknown argument → exit 2" {
    run bash "$WRAPPER" --profile-id p1 --reason r --ids "cr_1" --unknown foo
    [ "$status" -eq 2 ]
    [[ "$output" == *"unknown argument"* ]]
}

@test "missing --flag-reason → exit 2" {
    run bash "$WRAPPER" --profile-id p1 --reason r --ids "cr_1"
    [ "$status" -eq 2 ]
    [[ "$output" == *"--flag-reason is required"* ]]
}

@test "invalid --flag-reason value → exit 2" {
    run bash "$WRAPPER" --profile-id p1 --reason r --ids "cr_1" --flag-reason looks_off
    [ "$status" -eq 2 ]
    [[ "$output" == *"not a valid enum value"* ]]
}

@test "--flag-reason exported as OPS_FLAG_REASON for admin-api truth-floor write" {
    # The wrapper must export OPS_FLAG_REASON before invoking admin-api so
    # write_credit_request_result can include the categorical signal in the
    # .results.jsonl row. Stub admin captures env via printenv.
    cat > "$ADMIN_API_SH" <<'STUB'
#!/usr/bin/env bash
echo "ENV_OPS_FLAG_REASON=${OPS_FLAG_REASON:-UNSET}" >> "${ADMIN_LOG:-/dev/null}"
printf '%s\n' '{"http_status":200,"dryRun":true,"body":null}'
STUB
    chmod +x "$ADMIN_API_SH"
    run bash "$WRAPPER" --profile-id p1 --reason r --ids "cr_1" --flag-reason name_mismatch
    [ "$status" -eq 0 ]
    grep -qF 'ENV_OPS_FLAG_REASON=name_mismatch' "$ADMIN_LOG"
}

# --- Endpoint shape (the 2026-04-27 fix) ---

@test "ENDPOINT INVARIANT: uses PUT /admin/credit-requests with batch body" {
    STUB_MODE=success_dryrun bash "$WRAPPER" --profile-id p1 --reason high_velocity --ids "cr_1,cr_2,cr_3" --flag-reason name_mismatch >/dev/null
    # Single invocation (NOT N per-id calls)
    [ "$(grep -c '^ARGS:' "$ADMIN_LOG")" -eq 1 ]
    # PUT not PATCH; collection path not /<id>
    grep -qF 'PUT' "$ADMIN_LOG"
    ! grep -qF 'PATCH' "$ADMIN_LOG"
    grep -qF '/admin/credit-requests' "$ADMIN_LOG"
    ! grep -qF '/admin/credit-requests/cr_' "$ADMIN_LOG"
    # Body shape: requestIds array + status, no reason field.
    body=$(grep '^LAST_ARG:' "$ADMIN_LOG" | sed 's/^LAST_ARG: //' | head -1)
    echo "$body" | jq -e '.status == "user_verification_needed"' >/dev/null
    echo "$body" | jq -e '.requestIds == ["cr_1","cr_2","cr_3"]' >/dev/null
    # Backend updateStatus does not consume `reason` — must NOT be in body.
    echo "$body" | jq -e 'has("reason") | not' >/dev/null
}

@test "ENDPOINT INVARIANT: trims whitespace from --ids before serializing" {
    STUB_MODE=success_dryrun bash "$WRAPPER" --profile-id p1 --reason r --ids " cr_1 , cr_2 ,cr_3 " --flag-reason name_mismatch >/dev/null
    body=$(grep '^LAST_ARG:' "$ADMIN_LOG" | sed 's/^LAST_ARG: //' | head -1)
    echo "$body" | jq -e '.requestIds == ["cr_1","cr_2","cr_3"]' >/dev/null
}

@test "REGRESSION GUARD: PATCH /admin/credit-requests/<id> would 404 (legacy bug shape)" {
    # If a future change resurrects per-id PATCH, the legacy stub mode
    # returns the exact 404 the real backend produces. Wrapper must treat
    # it as http_error (not "ok") and exit 1. This test exists to lock the
    # 2026-04-27 incident shape into CI.
    STUB_MODE=http_404_patch_legacy run --separate-stderr bash "$WRAPPER" --profile-id p1 --reason r --ids "cr_1" --flag-reason name_mismatch
    [ "$status" -eq 1 ]
    echo "$output" | jq -e '.outcome == "http_error" and .http_status == 404' >/dev/null
}

# --- Successful paths ---

@test "happy path (dry-run) → exit 0, outcome=dry_run_intercept" {
    STUB_MODE=success_dryrun run --separate-stderr bash "$WRAPPER" --profile-id p1 --reason high_velocity --ids "cr_1,cr_2,cr_3" --flag-reason name_mismatch
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.profile_id == "p1" and .requested == 3 and .outcome == "dry_run_intercept" and .http_status == 200' >/dev/null
}

@test "happy path (real 200) → exit 0, outcome=ok, no --evidence-excerpt flag" {
    STUB_MODE=success_200 run --separate-stderr bash "$WRAPPER" --profile-id p1 --reason high_velocity --ids "cr_1,cr_2" --flag-reason name_mismatch
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.outcome == "ok" and .http_status == 200 and .requested == 2' >/dev/null
    # UVN is ungated — wrapper must NOT pass --evidence-excerpt.
    ! grep -qF -- '--evidence-excerpt' "$ADMIN_LOG"
}

@test "reason is forwarded to stderr (audit grep), NOT to API body" {
    STUB_MODE=success_dryrun run --separate-stderr bash "$WRAPPER" --profile-id p1 --reason high_velocity --ids "cr_1" --flag-reason name_mismatch
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"reason=\"high_velocity\""* ]]
    [[ "$stderr" == *"profile=p1"* ]]
    body=$(grep '^LAST_ARG:' "$ADMIN_LOG" | sed 's/^LAST_ARG: //' | head -1)
    echo "$body" | jq -e 'has("reason") | not' >/dev/null
}

# --- Failure paths ---

@test "HTTP 500 from updateStatus → exit 1, outcome=http_error" {
    STUB_MODE=http_500 run --separate-stderr bash "$WRAPPER" --profile-id p1 --reason high_velocity --ids "cr_1,cr_2" --flag-reason name_mismatch
    [ "$status" -eq 1 ]
    echo "$output" | jq -e '.outcome == "http_error" and .http_status == 500 and .requested == 2' >/dev/null
}

@test "connection refused (curl 7) → exit 1, stderr surfaces" {
    STUB_MODE=connection_refused run --separate-stderr bash "$WRAPPER" --profile-id p1 --reason high_velocity --ids "cr_1,cr_2,cr_3" --flag-reason name_mismatch
    [ "$status" -eq 1 ]
    echo "$output" | jq -e '.outcome == "http_error"' >/dev/null
    [[ "$stderr" == *"Failed to connect"* ]]
}

# --- Silent-failure regression invariant ---

@test "CORE INVARIANT: redirecting stdout+stderr does NOT produce exit 0 on failure" {
    # The exact failure shape from 2026-04-22's inline flag_uvn loop:
    # stderr swallowed, exit code ignored. Wrapper must propagate non-zero
    # even when its outputs are redirected.
    rc=0
    STUB_MODE=http_500 bash "$WRAPPER" --profile-id p1 --reason r --ids "cr_1" >/dev/null 2>&1 || rc=$?
    [ "$rc" -ne 0 ]
}

@test "admin script absent → exit 2 (plumbing failure surfaces)" {
    ADMIN_API_SH=/nonexistent/muso-admin-api.sh \
        run bash "$WRAPPER" --profile-id p1 --reason r --ids "cr_1" --flag-reason name_mismatch
    [ "$status" -eq 2 ]
    [[ "$output" == *"muso-admin-api.sh not found"* ]]
}
