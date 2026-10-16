#!/usr/bin/env bats
# Tests for OPS_DRY_RUN write short-circuit in muso-admin-api.sh (issue #145).
#
# Dry-run mode intercepts PUT/POST/PATCH/DELETE before they hit the API and
# returns a synthetic 200. GET still reaches the real server. Intercepted
# writes are appended to OPS_DRY_RUN_AUDIT_PATH as JSONL for later review.
#
# The credit-approve gate must STILL RUN in dry-run mode — dry-run is for
# proving "what would have happened"; it must not hide a gate failure.

setup() {
    TEST_ROOT="$(mktemp -d)"
    export TEST_ROOT

    SCRIPT="${BATS_TEST_DIRNAME}/../muso-admin-api.sh"
    [[ -f "$SCRIPT" ]] || { echo "SCRIPT not found: $SCRIPT" >&2; return 1; }

    # Stand-in MUSO_API_URL points at a closed port so real HTTP would fail
    # loudly. If dry-run mode is broken and we accidentally reach curl, tests
    # will see a connection error rather than silently passing.
    export MUSO_API_URL="http://127.0.0.1:1"
    export MUSO_ADMIN_EMAIL="test@example.com"
    export MUSO_ADMIN_PASSWORD="unused-in-dry-run"

    export OPS_DRY_RUN_AUDIT_PATH="$TEST_ROOT/ops-dry-run-audit.jsonl"
    # Route the credit-request results.jsonl (PR 1 truth floor) to a writable
    # tmp path so tests don't trip over the default /var/log location.
    export CV_RESULTS_PATH="$TEST_ROOT/credit-results.jsonl"
    export OPS_DRY_RUN=1

    # Pre-seed a token cache so get_token never tries to log in during any
    # real-path regressions. If dry-run intercepts correctly, this is unused.
    # Per-test cache under TEST_ROOT: a seed in the repo tree is shared by every
    # file and races under `bats --jobs` (MUS-11315).
    export ADMIN_TOKEN_CACHE_PATH="$TEST_ROOT/.admin-token-cache"
    printf '%s\ndummy-token\n' "$(date +%s)" > "$ADMIN_TOKEN_CACHE_PATH"
    chmod 600 "$ADMIN_TOKEN_CACHE_PATH"

    # Disable the credit-approve gate by default for dry-run tests so the
    # write-short-circuit behavior itself is isolated. The gate-still-fires
    # test re-enables the gate explicitly.
    export CV_APPROVE_GATE_DISABLED=1
    # The codex model-health gate runs first on real writes (e.g. the OPS_DRY_RUN-unset
    # mismatch test); it's covered by scripts/tests/muso-admin-api-codex-health.bats.
    # Point it at a healthy stub so these tests stay hermetic (prod has no bypass flag).
    export CODEX_HEALTH_LIB="$TEST_ROOT/codex-health-stub.sh"
    printf '%s\n' 'codex_health_gate() { return 0; }' > "$CODEX_HEALTH_LIB"
}

teardown() {
    rm -rf "$TEST_ROOT"
}

# --- Layer 1: write short-circuit ---

@test "PUT is blocked and returns synthetic 200 with dryRun:true" {
    run bash "$SCRIPT" call PUT /admin/credit-requests '{"requestIds":["cr_1"],"status":"approved"}'
    [ "$status" -eq 0 ]
    # wouldHaveExecuted lives at top level; body is null (see shape-compat test).
    echo "$output" | jq -e '.http_status == 200 and .dryRun == true and .wouldHaveExecuted == true' >/dev/null
}

@test "POST is blocked and returns synthetic 200" {
    run bash "$SCRIPT" call POST /admin/credits '{"foo":"bar"}'
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.http_status == 200 and .dryRun == true' >/dev/null
}

@test "PATCH is blocked and returns synthetic 200" {
    run bash "$SCRIPT" call PATCH /admin/users/u1 '{"name":"new"}'
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.http_status == 200 and .dryRun == true' >/dev/null
}

@test "DELETE is blocked and returns synthetic 200" {
    run bash "$SCRIPT" call DELETE /admin/users/u1 ''
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.http_status == 200 and .dryRun == true' >/dev/null
}

@test "GET is NOT intercepted (would reach network)" {
    # With MUSO_API_URL pointing at a closed port, a real GET must fail with
    # a curl connection error — proving the dry-run layer did NOT short-
    # circuit it. If GET were intercepted we'd see a synthetic 200 instead.
    run bash "$SCRIPT" call GET /admin/credit-requests ''
    # Explicit assertion: envelope either lacks dryRun entirely or it's false,
    # and no audit line was written. Weaker `! jq -e .dryRun==true` alone
    # would pass even if the command crashed before emitting anything.
    if echo "$output" | jq -e . >/dev/null 2>&1; then
        echo "$output" | jq -e '.dryRun != true' >/dev/null
    fi
    [ ! -s "${OPS_DRY_RUN_AUDIT_PATH:-/nonexistent}" ]
}

@test "HEAD is NOT intercepted (read-only, passthrough like GET)" {
    run bash "$SCRIPT" call HEAD /admin/credit-requests ''
    if echo "$output" | jq -e . >/dev/null 2>&1; then
        echo "$output" | jq -e '.dryRun != true' >/dev/null
    fi
    [ ! -s "${OPS_DRY_RUN_AUDIT_PATH:-/nonexistent}" ]
}

@test "unknown method (e.g. BULK) IS intercepted — fail-closed whitelist" {
    # Invert the old allow-list to a deny-list: anything that isn't a read
    # (GET/HEAD) gets intercepted when OPS_DRY_RUN=1. This closes the hole
    # where a typo or future verb would bypass dry-run.
    run bash "$SCRIPT" call BULK /admin/credit-requests '{"batch":"x"}'
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.dryRun == true' >/dev/null
    jq -e '.method == "BULK"' "$OPS_DRY_RUN_AUDIT_PATH" >/dev/null
}

@test "lower-case 'put' IS intercepted (method is case-folded for the check)" {
    run bash "$SCRIPT" call put /admin/credit-requests '{}'
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.dryRun == true' >/dev/null
}

@test "synthetic body is null, not a stand-in payload" {
    # Real API responses put the admin payload in .body (e.g. {items:[...]}).
    # The dry-run response must NOT supply a plausible-looking .body that
    # could mislead a consumer doing .body.items into thinking they got data.
    # Callers must branch on .dryRun.
    run bash "$SCRIPT" call PUT /admin/x '{}'
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.dryRun == true and .body == null' >/dev/null
}

# --- Audit JSONL ---

@test "intercepted write appends a line to OPS_DRY_RUN_AUDIT_PATH" {
    bash "$SCRIPT" call PUT /admin/credit-requests '{"requestIds":["cr_1"],"status":"approved"}' >/dev/null
    [ -f "$OPS_DRY_RUN_AUDIT_PATH" ]
    jq -e '.method == "PUT" and .path == "/admin/credit-requests"' "$OPS_DRY_RUN_AUDIT_PATH" >/dev/null
}

@test "multiple writes each append their own audit line" {
    bash "$SCRIPT" call PUT /admin/credit-requests '{"requestIds":["a"],"status":"approved"}' >/dev/null
    bash "$SCRIPT" call POST /admin/credits '{"amount":1}' >/dev/null
    bash "$SCRIPT" call DELETE /admin/users/u1 '' >/dev/null
    [ "$(wc -l < "$OPS_DRY_RUN_AUDIT_PATH")" -eq 3 ]
    # Compact jq output so this doesn't rely on pretty-print whitespace.
    [ "$(jq -s -c 'map(.method)' "$OPS_DRY_RUN_AUDIT_PATH")" = '["PUT","POST","DELETE"]' ]
}

@test "GET does NOT write an audit line" {
    # GET is expected to fail (closed port); the point is no audit trail.
    bash "$SCRIPT" call GET /admin/credit-requests '' >/dev/null 2>&1 || true
    [ ! -s "${OPS_DRY_RUN_AUDIT_PATH:-/nonexistent}" ]
}

@test "audit line captures the request body verbatim" {
    local body='{"requestIds":["cr_1","cr_2"],"status":"approved"}'
    bash "$SCRIPT" call PUT /admin/credit-requests "$body" >/dev/null
    jq -e --arg b "$body" '.body == $b' "$OPS_DRY_RUN_AUDIT_PATH" >/dev/null
}

@test "audit line captures --requester when set" {
    bash "$SCRIPT" --requester aaron@muso.ai call POST /admin/foo '{"x":1}' >/dev/null
    jq -e '.requester == "aaron@muso.ai"' "$OPS_DRY_RUN_AUDIT_PATH" >/dev/null
}

# --- OPS_DRY_RUN env var parsing ---

@test "OPS_DRY_RUN=0 means real mode (writes NOT intercepted)" {
    OPS_DRY_RUN=0 run bash "$SCRIPT" call PUT /admin/credit-requests '{"status":"approved"}'
    ! echo "$output" | jq -e '.dryRun == true' >/dev/null 2>&1
}

@test "unset OPS_DRY_RUN means real mode" {
    unset OPS_DRY_RUN
    run bash "$SCRIPT" call PUT /admin/credit-requests '{"status":"approved"}'
    ! echo "$output" | jq -e '.dryRun == true' >/dev/null 2>&1
}

@test "OPS_DRY_RUN=true (string) is accepted as truthy" {
    OPS_DRY_RUN=true run bash "$SCRIPT" call PUT /admin/x '{}'
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.dryRun == true' >/dev/null
}

@test "OPS_DRY_RUN=TRUE (uppercase) is accepted as truthy" {
    OPS_DRY_RUN=TRUE run bash "$SCRIPT" call PUT /admin/x '{}'
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.dryRun == true' >/dev/null
}

# --- Upload short-circuit ---

@test "cmd_upload is blocked in dry-run and writes audit line" {
    local tmpfile="$TEST_ROOT/upload-fixture.txt"
    printf 'hello\n' > "$tmpfile"
    run bash "$SCRIPT" upload /admin/files "$tmpfile"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.http_status == 200 and .dryRun == true' >/dev/null
    jq -e '.kind == "upload" and .path == "/admin/files"' "$OPS_DRY_RUN_AUDIT_PATH" >/dev/null
}

# --- Default audit path ---

@test "audit path defaults to /tmp/ops-dry-run-audit.jsonl when unset" {
    # The default is a fixed global path that other suites append to, so the
    # write is asserted on a per-test path (parallel-safe, MUS-11315) and the
    # shipped default is asserted on the script source.
    grep -qF 'OPS_DRY_RUN_AUDIT_PATH="${OPS_DRY_RUN_AUDIT_PATH:-/tmp/ops-dry-run-audit.jsonl}"' "$SCRIPT"
    export OPS_DRY_RUN_AUDIT_PATH="$TEST_ROOT/default-path-audit.jsonl"
    bash "$SCRIPT" call PUT /admin/x '{}' >/dev/null
    [ -f "$OPS_DRY_RUN_AUDIT_PATH" ]
    jq -e '.method == "PUT"' "$OPS_DRY_RUN_AUDIT_PATH" >/dev/null
}

# --- Gate-still-fires: dry-run does NOT bypass the credit-approve gate ---

@test "credit-approve gate STILL blocks even in dry-run mode (no evidence)" {
    # Re-enable the gate for this test. With no evidence excerpt and no
    # session log, the gate must still return a non-zero exit, proving
    # dry-run doesn't hide gate failures.
    unset CV_APPROVE_GATE_DISABLED
    run bash "$SCRIPT" call PUT /admin/credit-requests '{"requestIds":["cr_1"],"status":"approved"}'
    [ "$status" -ne 0 ]
    [[ "$output" == *"evidence-excerpt"* ]] || [[ "$output" == *"session log"* ]]
}

@test "credit-approve gate still allows human --requester to pass, then dry-run intercepts" {
    unset CV_APPROVE_GATE_DISABLED
    run bash "$SCRIPT" --requester aaron@muso.ai call PUT /admin/credit-requests '{"requestIds":["cr_1"],"status":"approved"}'
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.dryRun == true' >/dev/null
}

# --- Loud audit failure (review follow-up) ---

@test "audit write failure surfaces via stderr + dryRun_audit_failed marker" {
    # Point the audit path at a path that cannot be created (parent is a
    # regular file, not a dir). The short-circuit must still emit a
    # synthetic 200 (never block a dry-run on audit plumbing), but it
    # must SURFACE the failure: stderr warning + dryRun_audit_failed:true
    # in the response, so callers don't confuse "audit lost" with "audited".
    local blocker="$TEST_ROOT/not-a-dir"
    printf 'i am a file\n' > "$blocker"
    OPS_DRY_RUN_AUDIT_PATH="$blocker/nested/audit.jsonl" \
        run bash "$SCRIPT" call PUT /admin/x '{"k":"v"}'
    [ "$status" -eq 0 ]
    # bats' `run` merges stderr into $output; grab only the last line (the
    # JSON envelope) for the status-code check, and match the warning
    # anywhere in $output for the stderr-surface check.
    local json_line
    json_line="$(echo "$output" | tail -1)"
    echo "$json_line" | jq -e '.http_status == 200 and .dryRun == true and .dryRun_audit_failed == true and .body == null' >/dev/null
    [[ "$output" == *"audit"* ]]
    [[ "$output" == *"LOST"* ]]
}

# --- Audit line run_id propagation ---

@test "audit line includes run_id when OPS_RUN_ID is set" {
    OPS_RUN_ID=20260421-120000-abc123 \
        bash "$SCRIPT" call PUT /admin/x '{"k":"v"}' >/dev/null
    jq -e '.run_id == "20260421-120000-abc123"' "$OPS_DRY_RUN_AUDIT_PATH" >/dev/null
}

@test "audit line run_id is null when OPS_RUN_ID is unset" {
    unset OPS_RUN_ID
    bash "$SCRIPT" call PUT /admin/x '{"k":"v"}' >/dev/null
    jq -e '.run_id == null' "$OPS_DRY_RUN_AUDIT_PATH" >/dev/null
}

# Filesystem fallback (issue #152): SKILL.md B0c sets OPS_RUN_ID, but because
# each bash tool call spawns a fresh shell, the `export OPS_RUN_ID=$RUN_ID`
# there doesn't propagate to later calls. The audit line would fall back to
# null. The authoritative run_id lives in $OPS_RUNLOG_DIR/latest.txt (written
# by runlog.sh init) — read it when env is unset so the audit trail stays
# joinable to the runlog.
@test "audit line run_id falls back to OPS_RUNLOG_DIR/latest.txt basename when env unset" {
    unset OPS_RUN_ID RUN_ID
    export OPS_RUNLOG_DIR="$TEST_ROOT/runlogs"
    mkdir -p "$OPS_RUNLOG_DIR/2026-04-22"
    local expected_run_id="20260422-105638-f8108c"
    local run_log_path="$OPS_RUNLOG_DIR/2026-04-22/${expected_run_id}.jsonl"
    : > "$run_log_path"
    echo "$run_log_path" > "$OPS_RUNLOG_DIR/latest.txt"

    bash "$SCRIPT" call PUT /admin/x '{"k":"v"}' >/dev/null
    jq -e --arg rid "$expected_run_id" '.run_id == $rid' "$OPS_DRY_RUN_AUDIT_PATH" >/dev/null
}

@test "audit line prefers OPS_RUN_ID env over filesystem fallback when both set" {
    export OPS_RUN_ID="20260422-110000-env111"
    export OPS_RUNLOG_DIR="$TEST_ROOT/runlogs"
    mkdir -p "$OPS_RUNLOG_DIR/2026-04-22"
    local fs_run_id="20260422-105638-fs2222"
    local run_log_path="$OPS_RUNLOG_DIR/2026-04-22/${fs_run_id}.jsonl"
    : > "$run_log_path"
    echo "$run_log_path" > "$OPS_RUNLOG_DIR/latest.txt"

    bash "$SCRIPT" call PUT /admin/x '{"k":"v"}' >/dev/null
    jq -e '.run_id == "20260422-110000-env111"' "$OPS_DRY_RUN_AUDIT_PATH" >/dev/null
}

@test "audit line run_id stays null when env unset AND latest.txt absent" {
    unset OPS_RUN_ID RUN_ID
    export OPS_RUNLOG_DIR="$TEST_ROOT/runlogs"
    mkdir -p "$OPS_RUNLOG_DIR"
    # No latest.txt created. Fallback must be a no-op, not an error.
    bash "$SCRIPT" call PUT /admin/x '{"k":"v"}' >/dev/null
    jq -e '.run_id == null' "$OPS_DRY_RUN_AUDIT_PATH" >/dev/null
}

@test "audit line run_id stays null when latest.txt points at a malformed filename" {
    unset OPS_RUN_ID RUN_ID
    export OPS_RUNLOG_DIR="$TEST_ROOT/runlogs"
    mkdir -p "$OPS_RUNLOG_DIR"
    # Filename does not match the YYYYMMDD-HHMMSS-<hex> run_id shape; the
    # fallback must reject it rather than stuffing garbage into audit lines.
    echo "$OPS_RUNLOG_DIR/not-a-run-id.jsonl" > "$OPS_RUNLOG_DIR/latest.txt"
    bash "$SCRIPT" call PUT /admin/x '{"k":"v"}' >/dev/null
    jq -e '.run_id == null' "$OPS_DRY_RUN_AUDIT_PATH" >/dev/null
}

# --- Upload audit disambiguation ---

@test "upload audit line uses file_path, not body, so callers can distinguish from JSON writes" {
    local tmpfile="$TEST_ROOT/upload-fixture.txt"
    printf 'payload\n' > "$tmpfile"
    bash "$SCRIPT" upload /admin/files "$tmpfile" >/dev/null
    jq -e --arg p "$tmpfile" '.kind == "upload" and .file_path == $p and .body == null' "$OPS_DRY_RUN_AUDIT_PATH" >/dev/null
}

# --- Invalid OPS_DRY_RUN value warning ---

@test "unrecognized OPS_DRY_RUN value is treated as false AND warns to stderr" {
    # `OPS_DRY_RUN=enable` / `y` / `2` / `True ` (trailing space) silently
    # fell through to real mode in the original impl. That's a footgun — the
    # user thinks they're dry-running and a real write lands. Fix: warn.
    OPS_DRY_RUN=enable \
        run bash "$SCRIPT" call PUT /admin/x '{}'
    # The stderr warning is what we care about. The real call may or may not
    # succeed (closed port) — that's irrelevant to this test.
    [[ "$output" == *"OPS_DRY_RUN"* ]] && [[ "$output" == *"enable"* ]]
}

# --- Shell-injection safety for audit body ---

@test "body containing backticks and \$() is captured literally in audit" {
    # The python-via-env approach in write_dry_run_audit is the right design
    # precisely because bodies can contain shell metachars. Pin it with a
    # regression test — if a future refactor interpolates \$body into a
    # heredoc, this body would execute `whoami` and the audit would contain
    # the username instead of the literal backticks.
    local malicious='{"note":"`whoami`","x":"$(echo pwned)"}'
    bash "$SCRIPT" call PUT /admin/x "$malicious" >/dev/null
    jq -e --arg b "$malicious" '.body == $b' "$OPS_DRY_RUN_AUDIT_PATH" >/dev/null
}

# --- Credit-request results.jsonl (PR 1 truth floor) ---
#
# The results log is the authoritative source of truth for
# compute-run-summary.sh. It is written regardless of caller redirections:
# a caller that wraps us in `> /dev/null 2>&1` cannot hide the outcome.
# Logged only for writes to /admin/credit-requests* (PUT or PATCH) so
# non-credit-request traffic produces no noise.

@test "results.jsonl: PUT /admin/credit-requests dry-run intercept writes outcome=dry_run_intercept" {
    # Gate bypassed via CV_APPROVE_GATE_DISABLED (set in setup). Dry-run mode
    # on. Must produce a results.jsonl line with dry_run_intercept outcome.
    bash "$SCRIPT" call PUT /admin/credit-requests '{"requestIds":["cr_1","cr_2"],"status":"approved"}' >/dev/null
    [ -f "$CV_RESULTS_PATH" ]
    jq -e '.outcome == "dry_run_intercept" and .method == "PUT" and .path == "/admin/credit-requests" and .intended_status == "approved" and .http_status == 200' "$CV_RESULTS_PATH" >/dev/null
    # Batch PUT carries requestIds from body into the truth log so downstream
    # reconciliation can tally per-ID.
    [ "$(jq -c '.request_ids' "$CV_RESULTS_PATH")" = '["cr_1","cr_2"]' ]
}

@test "results.jsonl: PATCH /admin/credit-requests/<id> captures id in request_ids" {
    # Single-credit PATCH shape: id is in the path, not the body. Truth log
    # reconstructs request_ids=[<id>] so batched and per-credit paths feed
    # the same reconciliation surface.
    bash "$SCRIPT" call PATCH /admin/credit-requests/cr-from-path '{"status":"approved","evidence_excerpt":"in_body"}' >/dev/null
    [ -f "$CV_RESULTS_PATH" ]
    [ "$(jq -c '.request_ids' "$CV_RESULTS_PATH")" = '["cr-from-path"]' ]
    jq -e '.method == "PATCH" and .outcome == "dry_run_intercept"' "$CV_RESULTS_PATH" >/dev/null
}

@test "results.jsonl: non-credit-requests path writes NO line" {
    # Scope guard: the truth floor is for /admin/credit-requests* writes only.
    # Other admin API writes (users, credits, etc.) must NOT produce a line,
    # or compute-run-summary.sh counts would be polluted.
    bash "$SCRIPT" call POST /admin/credits '{"amount":1}' >/dev/null
    bash "$SCRIPT" call PATCH /admin/users/u1 '{"name":"x"}' >/dev/null
    [ ! -f "$CV_RESULTS_PATH" ] || [ "$(wc -l < "$CV_RESULTS_PATH")" -eq 0 ]
}

@test "results.jsonl: GET /admin/credit-requests writes NO line (reads are not writes)" {
    # GET is allowed through to the real API (would fail at closed port).
    # The truth floor only records writes — a read shouldn't produce a line.
    bash "$SCRIPT" call GET /admin/credit-requests '' >/dev/null 2>&1 || true
    [ ! -f "$CV_RESULTS_PATH" ] || [ "$(wc -l < "$CV_RESULTS_PATH")" -eq 0 ]
}

@test "results.jsonl: multiple writes append separate lines" {
    bash "$SCRIPT" call PUT /admin/credit-requests '{"requestIds":["a"],"status":"approved"}' >/dev/null
    bash "$SCRIPT" call PATCH /admin/credit-requests/b '{"status":"user_verification_needed","reason":"r"}' >/dev/null
    bash "$SCRIPT" call PATCH /admin/credit-requests/c '{"status":"user_verification_needed","reason":"r"}' >/dev/null
    [ "$(wc -l < "$CV_RESULTS_PATH")" -eq 3 ]
    # Intended status for each entry reflects the body, so UVN flags are
    # distinguishable from approves in the truth log.
    [ "$(jq -s -c 'map(.intended_status)' "$CV_RESULTS_PATH")" = '["approved","user_verification_needed","user_verification_needed"]' ]
}

@test "results.jsonl: rejected_by_gate outcome fires when gate blocks" {
    # Re-enable the gate. No EVIDENCE_EXCERPT → gate rejects at the
    # `--evidence-excerpt is required` branch. Truth log must still
    # record the rejection so downstream sees 0 approves reached the
    # intercept layer.
    unset CV_APPROVE_GATE_DISABLED
    run bash "$SCRIPT" call PUT /admin/credit-requests '{"requestIds":["cr_x"],"status":"approved"}'
    [ "$status" -ne 0 ]
    [ -f "$CV_RESULTS_PATH" ]
    jq -e '.outcome == "rejected_by_gate" and .method == "PUT" and .intended_status == "approved" and .http_status == null' "$CV_RESULTS_PATH" >/dev/null
    [ "$(jq -c '.request_ids' "$CV_RESULTS_PATH")" = '["cr_x"]' ]
}

@test "results.jsonl: rejected_by_gate fires for PATCH too (not just PUT)" {
    # Regression test for the 2026-04-22 silent-failure scenario: agent
    # synthesized PATCH calls without --evidence-excerpt. Gate rejects,
    # and the truth floor records it — no more counting iterations as
    # successes.
    unset CV_APPROVE_GATE_DISABLED
    run bash "$SCRIPT" call PATCH /admin/credit-requests/cr_from_path '{"status":"approved"}'
    [ "$status" -ne 0 ]
    jq -e '.outcome == "rejected_by_gate" and .method == "PATCH"' "$CV_RESULTS_PATH" >/dev/null
    [ "$(jq -c '.request_ids' "$CV_RESULTS_PATH")" = '["cr_from_path"]' ]
}

@test "results.jsonl: UVN flag in dry-run records dry_run_intercept (no gate applies)" {
    # UVN isn't gated (no evidence required to flag for review) but still
    # goes through the truth floor so compute-run-summary can tally
    # uvn_ok vs uvn_error separately from approves.
    unset CV_APPROVE_GATE_DISABLED
    bash "$SCRIPT" call PATCH /admin/credit-requests/cr_uvn '{"status":"user_verification_needed","reason":"high_velocity"}' >/dev/null
    jq -e '.outcome == "dry_run_intercept" and .intended_status == "user_verification_needed"' "$CV_RESULTS_PATH" >/dev/null
}

@test "results.jsonl: run_id is captured when OPS_RUN_ID is set" {
    export OPS_RUN_ID="20260422-191608-d62a7b"
    bash "$SCRIPT" call PUT /admin/credit-requests '{"requestIds":["cr_1"],"status":"approved"}' >/dev/null
    jq -e --arg r "$OPS_RUN_ID" '.run_id == $r' "$CV_RESULTS_PATH" >/dev/null
}

@test "results.jsonl: run_id falls back to OPS_RUNLOG_DIR/latest.txt basename" {
    # Same fallback as write_dry_run_audit: per-exec-call shells don't see
    # OPS_RUN_ID via export, so the filesystem is the source of truth.
    unset OPS_RUN_ID RUN_ID
    export OPS_RUNLOG_DIR="$TEST_ROOT/runlog"
    mkdir -p "$OPS_RUNLOG_DIR"
    printf '%s\n' "$OPS_RUNLOG_DIR/20260422-191608-d62a7b.jsonl" > "$OPS_RUNLOG_DIR/latest.txt"
    bash "$SCRIPT" call PUT /admin/credit-requests '{"requestIds":["cr_1"],"status":"approved"}' >/dev/null
    jq -e '.run_id == "20260422-191608-d62a7b"' "$CV_RESULTS_PATH" >/dev/null
}

@test "results.jsonl: malformed latest.txt basename → run_id stays null" {
    # Same defensive shape check as write_dry_run_audit: if latest.txt gets
    # clobbered, don't stuff garbage into the truth log.
    unset OPS_RUN_ID RUN_ID
    export OPS_RUNLOG_DIR="$TEST_ROOT/runlog"
    mkdir -p "$OPS_RUNLOG_DIR"
    printf '%s\n' "$OPS_RUNLOG_DIR/not-a-run-id.jsonl" > "$OPS_RUNLOG_DIR/latest.txt"
    bash "$SCRIPT" call PUT /admin/credit-requests '{"requestIds":["cr_1"],"status":"approved"}' >/dev/null
    jq -e '.run_id == null' "$CV_RESULTS_PATH" >/dev/null
}

@test "results.jsonl: requester is captured when --requester is set" {
    # Reconciliation needs to distinguish autonomous batches from
    # human-authorized per-credit approves (Jan/Aaron override path).
    bash "$SCRIPT" --requester jan@muso.ai call PATCH /admin/credit-requests/cr_1 '{"status":"approved"}' >/dev/null
    jq -e '.requester == "jan@muso.ai"' "$CV_RESULTS_PATH" >/dev/null
}

@test "results.jsonl: caller redirecting stdout+stderr cannot hide the line" {
    # The whole point of PR 1's design principle: truth lives on disk, not
    # in streams. A caller that does `bash muso-admin-api.sh ... > /dev/null 2>&1`
    # (which is exactly what the 2026-04-22 inline run_profile did) must
    # still leave a line in results.jsonl.
    bash "$SCRIPT" call PUT /admin/credit-requests '{"requestIds":["cr_1"],"status":"approved"}' >/dev/null 2>&1
    [ -s "$CV_RESULTS_PATH" ]
    jq -e '.outcome == "dry_run_intercept"' "$CV_RESULTS_PATH" >/dev/null
}

# --- Dry-run config-mismatch guard (R2-1) ---
#
# Prevents the 2026-04-23 09:02 UTC incident class: runlog was initialized
# with dryRun:true at B0, but a later exec shell lost OPS_DRY_RUN=1 because
# each openclaw exec tool call is a fresh shell. 12 UVN PATCHes hit the real
# admin API during what was supposed to be a dry-run (saved only by URL 404s).
# Guard refuses the write and records outcome=dry_run_config_mismatch.

seed_runlog_dryrun() {
    # args: dry_run_flag (true|false)
    local dry="$1"
    local runlog_dir="$TEST_ROOT/runlog"
    mkdir -p "$runlog_dir"
    local runlog_file="$runlog_dir/20260423-090219-testseed.jsonl"
    jq -n -c --argjson dry "$dry" '{event:"run_header", run_id:"20260423-090219-testseed", ts:"2026-04-23T09:02:19Z", dryRun:$dry}' > "$runlog_file"
    printf '%s\n' "$runlog_file" > "$runlog_dir/latest.txt"
    export OPS_RUNLOG_DIR="$runlog_dir"
}

@test "guard: runlog=dryRun + OPS_DRY_RUN unset → refuse real write, outcome=dry_run_config_mismatch" {
    # This is THE fix for the 2026-04-23 incident. If a caller forgot to
    # export OPS_DRY_RUN in its exec shell, the write must be refused —
    # not leaked to prod — with a loud error and a truth-floor line.
    seed_runlog_dryrun true
    unset OPS_DRY_RUN
    run bash "$SCRIPT" call PATCH /admin/credit-requests/cr_uvn_1 '{"status":"user_verification_needed","reason":"x"}'
    [ "$status" -ne 0 ]
    [[ "$output" == *"run_header says dryRun:true but OPS_DRY_RUN env is unset"* ]]
    [ -s "$CV_RESULTS_PATH" ]
    jq -e '.outcome == "dry_run_config_mismatch" and .method == "PATCH" and .intended_status == "user_verification_needed"' "$CV_RESULTS_PATH" >/dev/null
    [ "$(jq -c '.request_ids' "$CV_RESULTS_PATH")" = '["cr_uvn_1"]' ]
}

@test "guard: runlog=dryRun + OPS_DRY_RUN=1 → passes through to dry-run intercept" {
    # Happy dry-run path: both runlog and env agree. Write is intercepted
    # normally.
    seed_runlog_dryrun true
    export OPS_DRY_RUN=1
    run bash "$SCRIPT" call PUT /admin/credit-requests '{"requestIds":["cr_1"],"status":"approved"}'
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.dryRun == true' >/dev/null
    jq -e '.outcome == "dry_run_intercept"' "$CV_RESULTS_PATH" >/dev/null
    # The guard must NOT have fired — only the normal dry-run intercept line.
    ! jq -e 'select(.outcome == "dry_run_config_mismatch")' "$CV_RESULTS_PATH" >/dev/null 2>&1
}

@test "guard: runlog=false + OPS_DRY_RUN unset → real write path (not blocked)" {
    # Prod run where both runlog and env agree. Guard must NOT fire — the
    # real curl runs (and will fail at the closed port, but that proves
    # we reached the real-call branch).
    seed_runlog_dryrun false
    unset OPS_DRY_RUN
    run bash "$SCRIPT" call PATCH /admin/credit-requests/cr_2 '{"status":"user_verification_needed","reason":"x"}'
    # No guard fire → no dry_run_config_mismatch line.
    if [[ -f "$CV_RESULTS_PATH" ]]; then
        ! jq -e 'select(.outcome == "dry_run_config_mismatch")' "$CV_RESULTS_PATH" >/dev/null 2>&1
    fi
}

@test "guard: no runlog present (ad-hoc call outside batch) → passes through" {
    # Ad-hoc call from a human shell has no OPS_RUNLOG_DIR — guard must be
    # a no-op, not block the call. (Jan/Aaron escalation-thread overrides
    # flow through this path.)
    unset OPS_RUNLOG_DIR OPS_DRY_RUN
    run bash "$SCRIPT" call PATCH /admin/credit-requests/cr_3 '{"status":"user_verification_needed","reason":"x"}'
    # Guard did NOT fire (no runlog to check).
    if [[ -f "$CV_RESULTS_PATH" ]]; then
        ! jq -e 'select(.outcome == "dry_run_config_mismatch")' "$CV_RESULTS_PATH" >/dev/null 2>&1
    fi
}

@test "guard: only scoped to /admin/credit-requests* — other admin writes pass through" {
    # A dry-run mismatch on /admin/users or /admin/credits should NOT trip
    # this guard. The guard is the credit-verification truth-floor scope.
    seed_runlog_dryrun true
    unset OPS_DRY_RUN
    run bash "$SCRIPT" call PATCH /admin/users/u1 '{"name":"x"}'
    # No dry_run_config_mismatch line even though runlog says dry + env empty,
    # because the path isn't /admin/credit-requests*.
    if [[ -f "$CV_RESULTS_PATH" ]]; then
        ! jq -e 'select(.outcome == "dry_run_config_mismatch")' "$CV_RESULTS_PATH" >/dev/null 2>&1
    fi
}

@test "guard: GET still passes through when runlog=dryRun + env unset (reads are not writes)" {
    # GET is never a write. The guard must not fire for reads even when the
    # runlog mismatch condition is technically met.
    seed_runlog_dryrun true
    unset OPS_DRY_RUN
    run bash "$SCRIPT" call GET /admin/credit-requests ''
    # No dry_run_config_mismatch line.
    if [[ -f "$CV_RESULTS_PATH" ]]; then
        ! jq -e 'select(.outcome == "dry_run_config_mismatch")' "$CV_RESULTS_PATH" >/dev/null 2>&1
    fi
}

@test "guard: malformed latest.txt → treated as unknown, passes through" {
    # Defense-in-depth: if latest.txt is clobbered, don't lock out all writes
    # — just let them through (they'll be intercepted by the short-circuit if
    # OPS_DRY_RUN=1, or go to prod if 0). The runlog is an advisory signal,
    # not a lock.
    local runlog_dir="$TEST_ROOT/runlog"
    mkdir -p "$runlog_dir"
    printf 'garbage-not-a-path\n' > "$runlog_dir/latest.txt"
    export OPS_RUNLOG_DIR="$runlog_dir"
    unset OPS_DRY_RUN
    run bash "$SCRIPT" call PATCH /admin/credit-requests/cr_4 '{"status":"user_verification_needed","reason":"x"}'
    if [[ -f "$CV_RESULTS_PATH" ]]; then
        ! jq -e 'select(.outcome == "dry_run_config_mismatch")' "$CV_RESULTS_PATH" >/dev/null 2>&1
    fi
}
