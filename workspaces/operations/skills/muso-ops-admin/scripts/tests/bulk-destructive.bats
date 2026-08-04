#!/usr/bin/env bats
# Tests for the bulk destructive-operation gate added to muso-admin-api.sh
# after incident 2026-05-26 (the ops agent autonomously issued ~285 DELETE
# /admin/track/:id/analytics-sources calls in one run, wiping the only Spotify
# link on 10 tracks).
#
# Gate contract:
# - Counts DELETE calls within the last BULK_DESTRUCTIVE_WINDOW_SECS (window-
#   only, NOT per-run). Once BULK_DESTRUCTIVE_THRESHOLD is reached, every
#   further destructive DELETE is refused unless --confirmed-by <approver> AND
#   --approval-msg-id <ts> are supplied.
# - God-mode / requester identity does NOT bypass this gate (regression test
#   for the incident: the agent auto-stamps --requester with whoever's
#   in-thread).
# - A deny-list (config/bulk-destructive-exclude.txt) exempts harmless DELETEs
#   (e.g. profile cache). A MISSING exclude file means EVERYTHING counts.
# - Dry-run self-skips the gate and records nothing.

setup() {
    TEST_ROOT="$(mktemp -d)"
    export TEST_ROOT

    SCRIPT="${BATS_TEST_DIRNAME}/../muso-admin-api.sh"
    [[ -f "$SCRIPT" ]] || { echo "SCRIPT not found: $SCRIPT" >&2; return 1; }

    # Closed port so any real HTTP fails loudly. The gate short-circuits before
    # curl on every BLOCKED case; PASS cases fall through to curl (which fails),
    # so we assert on positive signals (audit row) not on the HTTP result.
    export MUSO_API_URL="http://127.0.0.1:1"
    export MUSO_ADMIN_EMAIL="test@example.com"
    export MUSO_ADMIN_PASSWORD="unused"

    # Test-scoped state so we never write to /var/log/muso-ops.
    export MUSO_OPS_STATE_DIR="$TEST_ROOT/state"
    export RECENT_MERGES_PATH="$TEST_ROOT/state/recent-merges.jsonl"
    export TIER2_AUDIT_PATH="$TEST_ROOT/state/tier2-audit.jsonl"
    export BULK_DESTRUCTIVE_PATH="$TEST_ROOT/state/destructive-ops.jsonl"
    export BULK_DESTRUCTIVE_AUDIT_PATH="$TEST_ROOT/state/bulk-destructive-audit.jsonl"
    export BULK_DESTRUCTIVE_THRESHOLD=3
    export BULK_DESTRUCTIVE_WINDOW_SECS=900

    # Test-scoped config so we aren't coupled to the canonical config dir.
    export TIER2_APPROVERS_PATH="$TEST_ROOT/tier2-approvers.txt"
    export TIER2_ENDPOINTS_PATH="$TEST_ROOT/tier2-endpoints.txt"
    export TIER2_GODMODE_PATH="$TEST_ROOT/tier2-godmode-allowlist.txt"
    export BULK_DESTRUCTIVE_EXCLUDE_PATH="$TEST_ROOT/bulk-destructive-exclude.txt"
    cat > "$TIER2_APPROVERS_PATH" <<EOF
# test approvers
aaron
aaron@muso.ai
EOF
    cat > "$TIER2_ENDPOINTS_PATH" <<EOF
POST /admin/profiles/merge
POST /admin/profiles/unmerge
EOF
    # Seed god-mode WITH the requesters we test below — the whole point of
    # case "god-mode does NOT bypass" is that being on this list does not help.
    cat > "$TIER2_GODMODE_PATH" <<EOF
aaron@muso.ai
jan@muso.ai
nick@muso.ai
EOF
    cat > "$BULK_DESTRUCTIVE_EXCLUDE_PATH" <<EOF
/admin/profile/*/cache
EOF

    # Disable the credit-approve gate (irrelevant here) and seed a token so any
    # PASS path that reaches get_token is satisfied.
    export CV_APPROVE_GATE_DISABLED=1
    # The codex model-health gate runs first on every write; it's covered by
    # scripts/tests/muso-admin-api-codex-health.bats. Point it at a healthy stub
    # so these downstream-gate tests stay hermetic (production has no bypass flag).
    export CODEX_HEALTH_LIB="$TEST_ROOT/codex-health-stub.sh"
    printf '%s\n' 'codex_health_gate() { return 0; }' > "$CODEX_HEALTH_LIB"
    export OPS_DRY_RUN_AUDIT_PATH="$TEST_ROOT/dry-run-audit.jsonl"
    export CV_RESULTS_PATH="$TEST_ROOT/credit-results.jsonl"
    export ADMIN_TOKEN_CACHE_PATH="$TEST_ROOT/.admin-token-cache"
    printf '%s\ndummy-token\n' "$(date +%s)" > "$ADMIN_TOKEN_CACHE_PATH"
    chmod 600 "$ADMIN_TOKEN_CACHE_PATH"
}

teardown() {
    rm -rf "$TEST_ROOT"
}

# Append N destructive-DELETE records to the rolling counter at a given epoch
# (default: now). Mirrors record_destructive_op's on-disk shape.
seed_destructive_ops() {
    local n="$1" epoch="${2:-$(date +%s)}" i
    mkdir -p "$(dirname "$BULK_DESTRUCTIVE_PATH")"
    for (( i = 0; i < n; i++ )); do
        jq -n -c --argjson epoch "$epoch" \
            '{ts:"seed", epoch:$epoch, method:"DELETE", path:"/admin/track/seed/analytics-sources", requester:"seed"}' \
            >> "$BULK_DESTRUCTIVE_PATH"
    done
}

# --- Under / at threshold ---

@test "destructive DELETE under threshold passes the gate" {
    seed_destructive_ops 2   # threshold is 3
    run bash "$SCRIPT" call DELETE /admin/track/abc/analytics-sources '{"linkId":"L1"}'
    [[ "$output" != *"MUSO_BULK_DESTRUCTIVE"* ]]
}

@test "destructive DELETE AT threshold without --confirmed-by is BLOCKED" {
    seed_destructive_ops 3
    run bash "$SCRIPT" call DELETE /admin/track/abc/analytics-sources '{"linkId":"L1"}'
    [ "$status" -eq 1 ]
    [[ "$output" == *"MUSO_BULK_DESTRUCTIVE_APPROVAL_REQUIRED"* ]]
}

# The refusal message is the text the agent actually reads at the moment it is
# blocked, so it outranks any SKILL.md prose. It previously said "each call past
# the threshold needs genuine approval ... hand it to a human to run", which
# contradicted the enumerated-requester rule and is exactly what made the agent
# page a human on delete 11.

@test "refusal message tells the agent an enumerated requester's own message IS the decision" {
    seed_destructive_ops 3
    run bash "$SCRIPT" call DELETE /admin/track/abc/analytics-sources '{"linkId":"L1"}'
    [ "$status" -eq 1 ]
    [[ "$output" == *"enumerated the exact targets"* ]]
    [[ "$output" == *"their own request message IS that decision"* ]]
    [[ "$output" == *"should not page anyone"* ]]
}

@test "refusal message no longer carries the contradictory hand-it-to-a-human guidance" {
    seed_destructive_ops 3
    run bash "$SCRIPT" call DELETE /admin/track/abc/analytics-sources '{"linkId":"L1"}'
    [ "$status" -eq 1 ]
    [[ "$output" != *"hand it to a human to run"* ]]
    [[ "$output" != *"Each call past the threshold needs genuine approval"* ]]
}

@test "refusal message still scopes the decision to the enumerated set only" {
    seed_destructive_ops 3
    run bash "$SCRIPT" call DELETE /admin/track/abc/analytics-sources '{"linkId":"L1"}'
    [ "$status" -eq 1 ]
    [[ "$output" == *"ONLY that set"* ]]
    [[ "$output" == *"a different set of rows is"* ]]
}

@test "AT threshold with --confirmed-by NOT in allowlist is rejected" {
    seed_destructive_ops 3
    run bash "$SCRIPT" --confirmed-by jan --approval-msg-id 1.2 \
        call DELETE /admin/track/abc/analytics-sources '{"linkId":"L1"}'
    [ "$status" -eq 1 ]
    [[ "$output" == *"MUSO_BULK_DESTRUCTIVE_APPROVAL_INVALID"* ]]
}

@test "AT threshold with approver but missing --approval-msg-id is refused" {
    seed_destructive_ops 3
    run bash "$SCRIPT" --confirmed-by aaron \
        call DELETE /admin/track/abc/analytics-sources '{"linkId":"L1"}'
    [ "$status" -eq 1 ]
    [[ "$output" == *"--approval-msg-id"* ]]
}

@test "AT threshold with valid approver + msg-id passes AND audits" {
    seed_destructive_ops 3
    run bash "$SCRIPT" --confirmed-by aaron --approval-msg-id 1779999999.001 \
        call DELETE /admin/track/abc/analytics-sources '{"linkId":"L1"}'
    [[ "$output" != *"MUSO_BULK_DESTRUCTIVE_APPROVAL"* ]]
    [ -f "$BULK_DESTRUCTIVE_AUDIT_PATH" ]
    grep -q '"confirmed_by":"aaron"' "$BULK_DESTRUCTIVE_AUDIT_PATH"
    grep -q '"approval_msg_id":"1779999999.001"' "$BULK_DESTRUCTIVE_AUDIT_PATH"
    grep -q '"count_at_trip":3' "$BULK_DESTRUCTIVE_AUDIT_PATH"
}

# --- God-mode / requester identity does NOT bypass (incident regression) ---

@test "god-mode requester (jan) does NOT bypass the bulk gate" {
    seed_destructive_ops 3
    run bash "$SCRIPT" --requester jan@muso.ai \
        call DELETE /admin/track/abc/analytics-sources '{"linkId":"L1"}'
    [ "$status" -eq 1 ]
    [[ "$output" == *"MUSO_BULK_DESTRUCTIVE_APPROVAL_REQUIRED"* ]]
}

@test "god-mode requester (aaron) does NOT bypass the bulk gate" {
    seed_destructive_ops 3
    run bash "$SCRIPT" --requester aaron@muso.ai \
        call DELETE /admin/track/abc/analytics-sources '{"linkId":"L1"}'
    [ "$status" -eq 1 ]
    [[ "$output" == *"MUSO_BULK_DESTRUCTIVE_APPROVAL_REQUIRED"* ]]
}

# --- Scope: exclusions, non-DELETE, window ---

@test "excluded path (profile cache) does not count toward the budget" {
    seed_destructive_ops 3
    run bash "$SCRIPT" call DELETE /admin/profile/123/cache
    [[ "$output" != *"MUSO_BULK_DESTRUCTIVE"* ]]
}

@test "non-DELETE verb is never gated even at threshold" {
    seed_destructive_ops 3
    run bash "$SCRIPT" call PATCH /admin/track/abc/analytics-sources \
        '{"linkId":"L1"}'
    [[ "$output" != *"MUSO_BULK_DESTRUCTIVE"* ]]
}

@test "records outside the window do not count" {
    seed_destructive_ops 3 1   # epoch=1, far before the cutoff
    run bash "$SCRIPT" call DELETE /admin/track/abc/analytics-sources '{"linkId":"L1"}'
    [[ "$output" != *"MUSO_BULK_DESTRUCTIVE"* ]]
}

@test "MISSING exclude file makes everything count (fail-safe-wide)" {
    rm -f "$BULK_DESTRUCTIVE_EXCLUDE_PATH"
    seed_destructive_ops 3
    # With no exclude file, even the normally-exempt cache delete counts.
    run bash "$SCRIPT" call DELETE /admin/profile/123/cache
    [ "$status" -eq 1 ]
    [[ "$output" == *"MUSO_BULK_DESTRUCTIVE_APPROVAL_REQUIRED"* ]]
}

# --- Dry-run ---

@test "dry-run self-skips the gate and records nothing" {
    # No seeding: prove dry-run neither enforces nor writes the counter.
    OPS_DRY_RUN=1 run bash "$SCRIPT" \
        call DELETE /admin/track/abc/analytics-sources '{"linkId":"L1"}'
    [ "$status" -eq 0 ]
    [[ "$output" == *'"http_status":200'* ]] || [[ "$output" == *'"http_status": 200'* ]]
    [[ "$output" != *"MUSO_BULK_DESTRUCTIVE"* ]]
    [ ! -f "$BULK_DESTRUCTIVE_PATH" ]
}

# --- Fail-closed counter persistence (QA, PR #390) ---

@test "counter that cannot be persisted FAILS CLOSED (DELETE refused)" {
    # Put a regular file where the counter's parent dir would go, so
    # record_destructive_op's mkdir -p fails and it cannot write.
    : > "$TEST_ROOT/blocker"
    export BULK_DESTRUCTIVE_PATH="$TEST_ROOT/blocker/destructive-ops.jsonl"
    # Under threshold (no seeding), this would normally pass — but an unwritable
    # counter must NOT silently disable the gate. Refuse instead.
    run bash "$SCRIPT" call DELETE /admin/track/abc/analytics-sources '{"linkId":"L1"}'
    [ "$status" -eq 1 ]
    [[ "$output" == *"MUSO_BULK_DESTRUCTIVE_COUNTER_UNWRITABLE"* ]]
}

@test "passing destructive DELETE records the ATTEMPT (not gated on a 2xx)" {
    # No seeding (count 0, under threshold). The gate persists this attempt
    # up-front, BEFORE the API call — so the counter advances even though the
    # closed-port curl then fails. Recording attempts (not just successes) is
    # what lets the gate fail closed on an unwritable counter.
    [ ! -f "$BULK_DESTRUCTIVE_PATH" ]
    run bash "$SCRIPT" call DELETE /admin/track/abc/analytics-sources '{"linkId":"L1"}'
    [[ "$output" != *"MUSO_BULK_DESTRUCTIVE"* ]]
    [ -f "$BULK_DESTRUCTIVE_PATH" ]
    [ "$(grep -c '"method":"DELETE"' "$BULK_DESTRUCTIVE_PATH")" -eq 1 ]
}
