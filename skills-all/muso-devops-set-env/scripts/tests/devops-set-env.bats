#!/usr/bin/env bats
# Tests for devops-set-env.sh gates. Backend is the `stub` (a flat KEY=VALUE
# file) so nothing touches prod. Every gate is exercised in isolation with
# fail-closed config paths pointed at a tmp fixture dir.

setup() {
    TEST_ROOT="$(mktemp -d)"
    export TEST_ROOT
    SCRIPT="${BATS_TEST_DIRNAME}/../devops-set-env.sh"
    [[ -f "$SCRIPT" ]] || { echo "SCRIPT not found: $SCRIPT" >&2; return 1; }

    # Fixtures (override the skill's real config).
    export PROTECTED_KEYS_PATH="$TEST_ROOT/protected.txt"
    export TARGET_ALLOWLIST_PATH="$TEST_ROOT/targets.txt"
    export ENVSET_REQUESTERS_PATH="$TEST_ROOT/requesters.txt"
    export BLOCKLIST_OVERRIDE_APPROVERS_PATH="$TEST_ROOT/override-approvers.txt"
    printf '%s\n' '*SECRET*' '*PASSWORD*' '*_KEY' 'DB_*' '*_URL' > "$PROTECTED_KEYS_PATH"
    printf '%s\n' 'core-backend' 'industry-data-processing' > "$TARGET_ALLOWLIST_PATH"
    printf '%s\n' 'aaron@muso.ai' 'nick' > "$ENVSET_REQUESTERS_PATH"
    printf '%s\n' 'nick' 'nick@muso.ai' > "$BLOCKLIST_OVERRIDE_APPROVERS_PATH"

    # State + audit + backend → all under tmp.
    export DEVOPS_ENVSET_STATE_DIR="$TEST_ROOT/state"
    export RATE_PATH="$TEST_ROOT/state/rate.jsonl"
    export AUDIT_PATH="$TEST_ROOT/state/audit.jsonl"
    export DEVOPS_ENVSET_BACKEND="stub"
    export DEVOPS_ENVSET_STUB_STORE="$TEST_ROOT/store.env"
}

teardown() { rm -rf "$TEST_ROOT"; }

set_cmd() { # convenience: bash SCRIPT --requester nick set ...
    bash "$SCRIPT" --requester nick set "$@"
}

# --- Requester gate ---

@test "unauthorized requester is refused (exit 3)" {
    run bash "$SCRIPT" --requester serhii@muso.ai set --target core-backend --key LOG_LEVEL --value debug
    [ "$status" -eq 3 ]
    [[ "$output" == *DEVOPS_ENVSET_REQUESTER_DENIED* ]]
}

@test "missing requester allowlist fails closed (exit 3)" {
    rm -f "$ENVSET_REQUESTERS_PATH"
    run set_cmd --target core-backend --key LOG_LEVEL --value debug
    [ "$status" -eq 3 ]
    [[ "$output" == *DEVOPS_ENVSET_CONFIG_MISSING* ]]
}

@test "authorized requester via slack-id resolution is accepted" {
    run bash "$SCRIPT" --requester U7RP6HKUZ set --target core-backend --key LOG_LEVEL --value debug
    [ "$status" -eq 0 ]
}

# --- Blocklist gate ---

@test "secret-shaped key (PASSWORD) is blocked (exit 4)" {
    run set_cmd --target core-backend --key DB_PASSWORD --value hunter2
    [ "$status" -eq 4 ]
    [[ "$output" == *DEVOPS_ENVSET_KEY_BLOCKED* ]]
}

@test "key ending _KEY is blocked (exit 4)" {
    run set_cmd --target core-backend --key STRIPE_API_KEY --value sk_live_x
    [ "$status" -eq 4 ]
}

@test "URL key is conservatively blocked (exit 4)" {
    run set_cmd --target core-backend --key WEBHOOK_URL --value http://evil
    [ "$status" -eq 4 ]
}

@test "missing blocklist treats every key as protected (fail closed, exit 4)" {
    rm -f "$PROTECTED_KEYS_PATH"
    run set_cmd --target core-backend --key LOG_LEVEL --value debug
    [ "$status" -eq 4 ]
    [[ "$output" == *DEVOPS_ENVSET_CONFIG_MISSING* ]]
}

@test "non-secret key passes the blocklist" {
    run set_cmd --target core-backend --key LOG_LEVEL --value debug
    [ "$status" -eq 0 ]
}

# --- Blocklist green-light (override) ---

@test "blocklisted key with valid green-light proceeds (exit 0)" {
    run set_cmd --target core-backend --key DB_PASSWORD --value hunter2 \
        --confirmed-by nick --approval-msg-id 1777.42
    [ "$status" -eq 0 ]
    grep -q '^DB_PASSWORD=hunter2$' "$DEVOPS_ENVSET_STUB_STORE"
}

@test "green-light is audited with blocklist_override:true and approver" {
    run set_cmd --target core-backend --key DB_PASSWORD --value hunter2 \
        --confirmed-by nick --approval-msg-id 1777.42
    [ "$status" -eq 0 ]
    run jq -r 'select(.key=="DB_PASSWORD") | "\(.blocklist_override)/\(.confirmed_by)/\(.approval_msg_id)"' "$AUDIT_PATH"
    [[ "$output" == *"true/nick/1777.42"* ]]
}

@test "green-light redacts the secret value in the audit log" {
    printf 'DB_PASSWORD=old_secret\n' > "$DEVOPS_ENVSET_STUB_STORE"
    run set_cmd --target core-backend --key DB_PASSWORD --value new_secret \
        --confirmed-by nick --approval-msg-id 1777.42
    [ "$status" -eq 0 ]
    # The secret reaches the backend (stub) but is NEVER persisted to the audit
    # JSONL — both prev and new are replaced by the redaction marker.
    run jq -r 'select(.key=="DB_PASSWORD") | "\(.prev_value)/\(.new_value)"' "$AUDIT_PATH"
    [[ "$output" == "[REDACTED:secret-shaped]/[REDACTED:secret-shaped]" ]]
    ! grep -q 'old_secret' "$AUDIT_PATH"
    ! grep -q 'new_secret' "$AUDIT_PATH"
}

@test "green-light rollback hint does not echo the secret value" {
    printf 'DB_PASSWORD=old_secret\n' > "$DEVOPS_ENVSET_STUB_STORE"
    run set_cmd --target core-backend --key DB_PASSWORD --value new_secret \
        --confirmed-by nick --approval-msg-id 1777.42
    [ "$status" -eq 0 ]
    [[ "$output" != *old_secret* ]]
    [[ "$output" == *"secret-management path"* ]]
}

@test "blocklisted key without --approval-msg-id is refused (exit 4)" {
    run set_cmd --target core-backend --key DB_PASSWORD --value x --confirmed-by nick
    [ "$status" -eq 4 ]
    [[ "$output" == *DEVOPS_ENVSET_OVERRIDE_REQUIRED* ]]
}

@test "green-light from non-approver is refused (exit 4)" {
    run set_cmd --target core-backend --key DB_PASSWORD --value x \
        --confirmed-by serhii@muso.ai --approval-msg-id 1777.42
    [ "$status" -eq 4 ]
    [[ "$output" == *DEVOPS_ENVSET_OVERRIDE_INVALID* ]]
}

@test "missing override-approver file refuses every green-light (fail closed)" {
    rm -f "$BLOCKLIST_OVERRIDE_APPROVERS_PATH"
    run set_cmd --target core-backend --key DB_PASSWORD --value x \
        --confirmed-by nick --approval-msg-id 1777.42
    [ "$status" -eq 4 ]
    [[ "$output" == *DEVOPS_ENVSET_OVERRIDE_INVALID* ]]
}

@test "dry-run still requires a green-light for a blocklisted key (exit 4)" {
    export OPS_DRY_RUN=1
    run set_cmd --target core-backend --key DB_PASSWORD --value x
    [ "$status" -eq 4 ]
    [[ "$output" == *DEVOPS_ENVSET_KEY_BLOCKED* ]]
}

# --- Target gate ---

@test "target not on allowlist is refused (exit 5)" {
    run set_cmd --target some-random-svc --key LOG_LEVEL --value debug
    [ "$status" -eq 5 ]
    [[ "$output" == *DEVOPS_ENVSET_TARGET_DENIED* ]]
}

@test "missing target allowlist fails closed (exit 5)" {
    rm -f "$TARGET_ALLOWLIST_PATH"
    run set_cmd --target core-backend --key LOG_LEVEL --value debug
    [ "$status" -eq 5 ]
}

# --- Happy path + audit + rollback capture ---

@test "happy path writes to backend and prints rollback hint" {
    run set_cmd --target core-backend --key LOG_LEVEL --value debug --reason "test"
    [ "$status" -eq 0 ]
    [[ "$output" == *"✅ set LOG_LEVEL"* ]]
    [[ "$output" == *"↩ rollback"* ]]
    grep -q '^LOG_LEVEL=debug$' "$DEVOPS_ENVSET_STUB_STORE"
}

@test "audit line records prev value for rollback" {
    printf 'LOG_LEVEL=info\n' > "$DEVOPS_ENVSET_STUB_STORE"
    run set_cmd --target core-backend --key LOG_LEVEL --value debug --reason "bump"
    [ "$status" -eq 0 ]
    run jq -r 'select(.key=="LOG_LEVEL") | "\(.prev_value)->\(.new_value)"' "$AUDIT_PATH"
    [[ "$output" == *"info->debug"* ]]
}

@test "rollback hint shell-escapes a prior value with metacharacters" {
    # A non-secret key whose existing value contains a single quote: the printed
    # rollback must be shell-escaped (printf %q), not wrapped in raw '...' that
    # the embedded quote would break.
    printf "LOG_LEVEL=de'bug\n" > "$DEVOPS_ENVSET_STUB_STORE"
    run set_cmd --target core-backend --key LOG_LEVEL --value info
    [ "$status" -eq 0 ]
    local expected; expected="$(printf '%q' "de'bug")"
    [[ "$output" == *"--value ${expected} "* ]]
    [[ "$output" != *"--value 'de'bug'"* ]]
}

@test "audit unwritable fails closed (exit 7), no backend write" {
    export AUDIT_PATH="/proc/cannot/write/here.jsonl"
    run set_cmd --target core-backend --key LOG_LEVEL --value debug
    [ "$status" -eq 7 ]
    [[ "$output" == *DEVOPS_ENVSET_AUDIT_UNWRITABLE* ]]
    [ ! -f "$DEVOPS_ENVSET_STUB_STORE" ]
}

# --- Dry-run ---

@test "dry-run performs no backend write but audits" {
    export OPS_DRY_RUN=1
    run set_cmd --target core-backend --key LOG_LEVEL --value debug
    [ "$status" -eq 0 ]
    [[ "$output" == *'"dryRun":true'* ]]
    [ ! -f "$DEVOPS_ENVSET_STUB_STORE" ]
    run jq -r 'select(.key=="LOG_LEVEL") | .dry_run' "$AUDIT_PATH"
    [[ "$output" == *"true"* ]]
}

@test "repeated dry-runs do not consume the rate budget" {
    export OPS_DRY_RUN=1 ENVSET_THRESHOLD=2
    set_cmd --target core-backend --key A_FLAG --value 1
    set_cmd --target core-backend --key B_FLAG --value 1
    set_cmd --target core-backend --key C_FLAG --value 1
    # A preview must NOT write the rate counter.
    [ ! -f "$RATE_PATH" ]
    # ...so a subsequent REAL set still has full budget (not forced to approval).
    unset OPS_DRY_RUN
    run set_cmd --target core-backend --key D_FLAG --value 1
    [ "$status" -eq 0 ]
}

@test "dry-run faithfully reports a would-be rate block (exit 6)" {
    export ENVSET_THRESHOLD=2
    set_cmd --target core-backend --key A_FLAG --value 1
    set_cmd --target core-backend --key B_FLAG --value 1
    # The next set would be rate-capped; the dry-run preflight must say so,
    # not print a misleading "wouldHaveExecuted:true".
    export OPS_DRY_RUN=1
    run set_cmd --target core-backend --key C_FLAG --value 1
    [ "$status" -eq 6 ]
    [[ "$output" == *DEVOPS_ENVSET_RATE_APPROVAL_REQUIRED* ]]
}

# --- Rate gate ---

@test "rate cap trips after threshold without ack (exit 6)" {
    export ENVSET_THRESHOLD=2
    set_cmd --target core-backend --key A_FLAG --value 1
    set_cmd --target core-backend --key B_FLAG --value 1
    run set_cmd --target core-backend --key C_FLAG --value 1
    [ "$status" -eq 6 ]
    [[ "$output" == *DEVOPS_ENVSET_RATE_APPROVAL_REQUIRED* ]]
}

@test "rate cap passes with valid ack from approver" {
    export ENVSET_THRESHOLD=2
    set_cmd --target core-backend --key A_FLAG --value 1
    set_cmd --target core-backend --key B_FLAG --value 1
    run set_cmd --target core-backend --key C_FLAG --value 1 --confirmed-by aaron@muso.ai --approval-msg-id 1777.001
    [ "$status" -eq 0 ]
}

@test "rate cap ack from non-approver is rejected" {
    export ENVSET_THRESHOLD=2
    set_cmd --target core-backend --key A_FLAG --value 1
    set_cmd --target core-backend --key B_FLAG --value 1
    run set_cmd --target core-backend --key C_FLAG --value 1 --confirmed-by serhii@muso.ai --approval-msg-id 1777.001
    [ "$status" -eq 6 ]
    [[ "$output" == *DEVOPS_ENVSET_RATE_APPROVAL_INVALID* ]]
}

# --- Backend fail-closed ---

@test "real kubectl backend is fail-closed until Phase-0 (exit 8)" {
    export DEVOPS_ENVSET_BACKEND="kubectl"
    run set_cmd --target core-backend --key LOG_LEVEL --value debug
    [ "$status" -eq 8 ]
    [[ "$output" == *DEVOPS_ENVSET_BACKEND_NOT_PINNED* ]]
}

@test "unset backend refuses (exit 8)" {
    unset DEVOPS_ENVSET_BACKEND
    run set_cmd --target core-backend --key LOG_LEVEL --value debug
    [ "$status" -eq 8 ]
    [[ "$output" == *DEVOPS_ENVSET_BACKEND_UNSET* ]]
}

# --- Input validation ---

@test "invalid env key shape is rejected" {
    run set_cmd --target core-backend --key "bad-key!" --value x
    [ "$status" -ne 0 ]
    [[ "$output" == *"invalid env key"* ]]
}

@test "missing --value is rejected" {
    run set_cmd --target core-backend --key LOG_LEVEL
    [ "$status" -ne 0 ]
    [[ "$output" == *"requires --value"* ]]
}
