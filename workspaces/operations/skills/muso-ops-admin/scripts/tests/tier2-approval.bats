#!/usr/bin/env bats
# Tests for the tier-2 approval gate and reverse-direction guard added to
# muso-admin-api.sh after incident 2026-04-29.
#
# - Tier-2 endpoints (POST /admin/profiles/merge etc.) require
#   --confirmed-by <approver in allowlist> AND --approval-msg-id <ts>.
# - Dry-run mode bypasses the gate (intended — dry-run can't mutate prod).
# - A merge whose direction is the opposite of any merge issued in the last
#   $TIER2_REVERSE_WINDOW_SECS seconds is refused: this is the call pattern
#   that destroyed prod state on 2026-04-29.

setup() {
    TEST_ROOT="$(mktemp -d)"
    export TEST_ROOT

    SCRIPT="${BATS_TEST_DIRNAME}/../muso-admin-api.sh"
    [[ -f "$SCRIPT" ]] || { echo "SCRIPT not found: $SCRIPT" >&2; return 1; }

    # Closed port so any real HTTP fails loudly. The gates we test here all
    # short-circuit before curl, so this is just a safety net.
    export MUSO_API_URL="http://127.0.0.1:1"
    export MUSO_ADMIN_EMAIL="test@example.com"
    export MUSO_ADMIN_PASSWORD="unused"

    # Test-scoped state directory so we don't write to /var/log/muso-ops.
    export MUSO_OPS_STATE_DIR="$TEST_ROOT/state"
    export RECENT_MERGES_PATH="$TEST_ROOT/state/recent-merges.jsonl"
    export TIER2_AUDIT_PATH="$TEST_ROOT/state/tier2-audit.jsonl"

    # Test-scoped config files so this test isn't coupled to whatever's in
    # the canonical config dir at the time of run.
    export TIER2_APPROVERS_PATH="$TEST_ROOT/tier2-approvers.txt"
    export TIER2_ENDPOINTS_PATH="$TEST_ROOT/tier2-endpoints.txt"
    cat > "$TIER2_APPROVERS_PATH" <<EOF
# test approvers
aaron
aaron@muso.ai
EOF
    cat > "$TIER2_ENDPOINTS_PATH" <<EOF
POST /admin/profiles/merge
POST /admin/profiles/unmerge
EOF

    # Disable credit-approve gate (irrelevant to tier-2 tests) and seed token
    # so any code path that reaches get_token is satisfied. Token cache is
    # redirected into TEST_ROOT so a crashed test doesn't leave artifacts in
    # the production scripts directory; teardown removes TEST_ROOT wholesale.
    export CV_APPROVE_GATE_DISABLED=1
    export OPS_DRY_RUN_AUDIT_PATH="$TEST_ROOT/dry-run-audit.jsonl"
    export CV_RESULTS_PATH="$TEST_ROOT/credit-results.jsonl"
    export ADMIN_TOKEN_CACHE_PATH="$TEST_ROOT/.admin-token-cache"
    printf '%s\ndummy-token\n' "$(date +%s)" > "$ADMIN_TOKEN_CACHE_PATH"
    chmod 600 "$ADMIN_TOKEN_CACHE_PATH"
}

teardown() {
    rm -rf "$TEST_ROOT"
}

# --- Tier-2 approval gate ---

@test "tier-2 merge without --confirmed-by is refused (exit 1)" {
    run bash "$SCRIPT" call POST /admin/profiles/merge '{"mergeInto":"a","profilesIds":["b"]}'
    [ "$status" -eq 1 ]
    [[ "$output" == *"MUSO_TIER2_APPROVAL_REQUIRED"* ]]
}

@test "tier-2 merge with --confirmed-by NOT in allowlist is refused" {
    run bash "$SCRIPT" --confirmed-by jan --approval-msg-id 1.2 \
        call POST /admin/profiles/merge '{"mergeInto":"a","profilesIds":["b"]}'
    [ "$status" -eq 1 ]
    [[ "$output" == *"MUSO_TIER2_APPROVAL_INVALID"* ]]
}

@test "tier-2 merge with --confirmed-by but missing --approval-msg-id is refused" {
    run bash "$SCRIPT" --confirmed-by aaron \
        call POST /admin/profiles/merge '{"mergeInto":"a","profilesIds":["b"]}'
    [ "$status" -eq 1 ]
    [[ "$output" == *"--approval-msg-id"* ]]
}

@test "tier-2 merge with valid --confirmed-by + --approval-msg-id passes the gate" {
    # No prior merges so reverse-direction guard is silent. Curl will fail
    # against the closed-port URL, but that means the gate let us through.
    # Assert on a POSITIVE signal (audit row written) rather than just
    # absence of error strings — a no-op refactor would otherwise pass.
    run bash "$SCRIPT" --confirmed-by aaron --approval-msg-id 1777474838.796239 \
        call POST /admin/profiles/merge '{"mergeInto":"a","profilesIds":["b"]}'
    [[ "$output" != *"MUSO_TIER2_APPROVAL"* ]]
    [[ "$output" != *"MUSO_MERGE_OVERLAPPING_IDS_BLOCKED"* ]]
    [ -f "$TIER2_AUDIT_PATH" ]
    grep -q '"confirmed_by":"aaron"' "$TIER2_AUDIT_PATH"
    grep -q '"approval_msg_id":"1777474838.796239"' "$TIER2_AUDIT_PATH"
}

@test "valid tier-2 call appends an entry to TIER2_AUDIT_PATH" {
    run bash "$SCRIPT" --confirmed-by aaron --approval-msg-id 1.2 \
        call POST /admin/profiles/merge '{"mergeInto":"x","profilesIds":["y"]}'
    [ -f "$TIER2_AUDIT_PATH" ]
    grep -q '"confirmed_by":"aaron"' "$TIER2_AUDIT_PATH"
    grep -q '"approval_msg_id":"1.2"' "$TIER2_AUDIT_PATH"
}

@test "dry-run bypasses the tier-2 approval gate" {
    OPS_DRY_RUN=1 run bash "$SCRIPT" \
        call POST /admin/profiles/merge '{"mergeInto":"a","profilesIds":["b"]}'
    [ "$status" -eq 0 ]
    # Synthetic 200, no MUSO_TIER2 error
    [[ "$output" == *'"http_status":200'* ]] || [[ "$output" == *'"http_status": 200'* ]]
    [[ "$output" != *"MUSO_TIER2_APPROVAL"* ]]
}

@test "non-tier-2 path is unaffected by the gate" {
    # GET /admin/profile/<id> isn't tier-2; gate must let it through.
    # Will fail on curl (closed port) but NOT with the tier-2 error.
    run bash "$SCRIPT" call GET /admin/profile/abc
    [[ "$output" != *"MUSO_TIER2_APPROVAL"* ]]
}

# --- Reverse-direction guard ---

seed_recent_merge() {
    local mergeInto="$1" profilesIds_json="$2" epoch="${3:-$(date +%s)}"
    mkdir -p "$(dirname "$RECENT_MERGES_PATH")"
    jq -n -c \
        --arg mergeInto "$mergeInto" \
        --argjson profilesIds "$profilesIds_json" \
        --argjson epoch "$epoch" \
        '{ts:"seed", epoch:$epoch, method:"POST", path:"/admin/profiles/merge", mergeInto:$mergeInto, profilesIds:$profilesIds, requester:"seed", confirmed_by:"aaron", approval_msg_id:"seed"}' \
        >> "$RECENT_MERGES_PATH"
}

@test "reverse-direction merge within window is BLOCKED" {
    seed_recent_merge "A" '["B"]'
    run bash "$SCRIPT" --confirmed-by aaron --approval-msg-id 1.2 \
        call POST /admin/profiles/merge '{"mergeInto":"B","profilesIds":["A"]}'
    [ "$status" -eq 1 ]
    [[ "$output" == *"MUSO_MERGE_OVERLAPPING_IDS_BLOCKED"* ]]
}

@test "reverse-direction merge OUTSIDE window is allowed" {
    # Seed an old entry (epoch=1, way before the cutoff)
    seed_recent_merge "A" '["B"]' 1
    run bash "$SCRIPT" --confirmed-by aaron --approval-msg-id 1.2 \
        call POST /admin/profiles/merge '{"mergeInto":"B","profilesIds":["A"]}'
    # Should NOT be blocked by the reverse-direction guard.
    [[ "$output" != *"MUSO_MERGE_OVERLAPPING_IDS_BLOCKED"* ]]
}

@test "merge with disjoint IDs from recent merges is allowed" {
    seed_recent_merge "A" '["B"]'
    run bash "$SCRIPT" --confirmed-by aaron --approval-msg-id 1.2 \
        call POST /admin/profiles/merge '{"mergeInto":"X","profilesIds":["Y"]}'
    [[ "$output" != *"MUSO_MERGE_OVERLAPPING_IDS_BLOCKED"* ]]
}

@test "guard catches new mergeInto matching prior profilesIds" {
    # prior: A -> [B, C]; new: B -> [Z] should block (B was a loser)
    seed_recent_merge "A" '["B","C"]'
    run bash "$SCRIPT" --confirmed-by aaron --approval-msg-id 1.2 \
        call POST /admin/profiles/merge '{"mergeInto":"B","profilesIds":["Z"]}'
    [ "$status" -eq 1 ]
    [[ "$output" == *"MUSO_MERGE_OVERLAPPING_IDS_BLOCKED"* ]]
}

@test "guard catches new profilesIds containing prior mergeInto" {
    # prior: A -> [B]; new: Z -> [A] should block (A was a survivor)
    seed_recent_merge "A" '["B"]'
    run bash "$SCRIPT" --confirmed-by aaron --approval-msg-id 1.2 \
        call POST /admin/profiles/merge '{"mergeInto":"Z","profilesIds":["A"]}'
    [ "$status" -eq 1 ]
    [[ "$output" == *"MUSO_MERGE_OVERLAPPING_IDS_BLOCKED"* ]]
}

@test "dry-run merge does NOT seed recent-merges (no prod mutation)" {
    OPS_DRY_RUN=1 run bash "$SCRIPT" --confirmed-by aaron --approval-msg-id 1.2 \
        call POST /admin/profiles/merge '{"mergeInto":"A","profilesIds":["B"]}'
    [ "$status" -eq 0 ]
    [ ! -f "$RECENT_MERGES_PATH" ]
}
