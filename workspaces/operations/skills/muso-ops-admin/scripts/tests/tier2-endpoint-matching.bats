#!/usr/bin/env bats
# Tests for is_tier2_endpoint path matching after the gate-gap hardening that
# added the doctrine-only "AARON ONLY" destructive endpoints to the tier-2
# allowlist (DELETE /admin/user/:id, DELETE /admin/track/:trackId,
# POST /admin/subscription).
#
# The matcher must:
#   - gate a ":param" entry against EXACTLY ONE path segment
#     (DELETE /admin/user/:id  gates  /admin/user/123)
#   - NOT over-match sub-resources
#     (DELETE /admin/user/:id  does NOT gate  /admin/user/123/image, and
#      DELETE /admin/track/:trackId does NOT gate the credit-removal endpoint
#      /admin/track/<id>/profile/<pid>/credits — over-gating there would break
#      Caroline's remove_credits / ops credit corrections)
#   - keep param-less entries (the 4 merge endpoints) as exact matches
#   - leave reads (GET) untouched
#
# Mirrors the hermetic setup of tier2-approval.bats (closed-port URL, stubbed
# codex-health, test-scoped config + state).

setup() {
    TEST_ROOT="$(mktemp -d)"
    export TEST_ROOT

    SCRIPT="${BATS_TEST_DIRNAME}/../muso-admin-api.sh"
    [[ -f "$SCRIPT" ]] || { echo "SCRIPT not found: $SCRIPT" >&2; return 1; }

    # Closed port so any real HTTP fails loudly. The gate under test
    # short-circuits before curl on the gated cases; the un-gated cases fall
    # through to curl (which fails) — that failure is the signal they were
    # NOT tier-2 refused.
    export MUSO_API_URL="http://127.0.0.1:1"
    export MUSO_ADMIN_EMAIL="test@example.com"
    export MUSO_ADMIN_PASSWORD="unused"

    export MUSO_OPS_STATE_DIR="$TEST_ROOT/state"
    export RECENT_MERGES_PATH="$TEST_ROOT/state/recent-merges.jsonl"
    export TIER2_AUDIT_PATH="$TEST_ROOT/state/tier2-audit.jsonl"

    export TIER2_APPROVERS_PATH="$TEST_ROOT/tier2-approvers.txt"
    export TIER2_ENDPOINTS_PATH="$TEST_ROOT/tier2-endpoints.txt"
    cat > "$TIER2_APPROVERS_PATH" <<EOF
aaron
aaron@muso.ai
EOF
    # One param-less entry (exact-match regression) + the three newly-gated
    # parameterized destructive endpoints.
    cat > "$TIER2_ENDPOINTS_PATH" <<EOF
POST /admin/profiles/merge
DELETE /admin/user/:id
DELETE /admin/track/:trackId
POST /admin/subscription
EOF
    # God-mode allowlist (workspace copy has one; jan + nick + aaron).
    export TIER2_GODMODE_PATH="$TEST_ROOT/tier2-godmode-allowlist.txt"
    cat > "$TIER2_GODMODE_PATH" <<EOF
aaron
aaron@muso.ai
jan
jan@muso.ai
nick
nick@muso.ai
EOF

    export CV_APPROVE_GATE_DISABLED=1
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

# --- Newly-gated destructive endpoints fire the gate ---

@test "DELETE /admin/user/<id> is now tier-2 gated (refused without --confirmed-by)" {
    run bash "$SCRIPT" call DELETE /admin/user/123
    [ "$status" -eq 1 ]
    [[ "$output" == *"MUSO_TIER2_APPROVAL_REQUIRED"* ]]
}

@test "DELETE /admin/track/<id> is refused (the removal gate runs before the tier-2 gate)" {
    run bash "$SCRIPT" call DELETE /admin/track/t1
    [ "$status" -eq 1 ]
    [[ "$output" == *"MUSO_REMOVAL_NO_SELF_APPROVE"* ]]
}

@test "POST /admin/subscription (VIP create) is now tier-2 gated" {
    run bash "$SCRIPT" call POST /admin/subscription '{"userId":"u1","plan":"pro"}'
    [ "$status" -eq 1 ]
    [[ "$output" == *"MUSO_TIER2_APPROVAL_REQUIRED"* ]]
}

@test "user-delete passes the gate with a valid approver + msg-id (audit row written)" {
    run bash "$SCRIPT" --confirmed-by aaron --approval-msg-id 1777474838.796239 \
        call DELETE /admin/user/123
    [[ "$output" != *"MUSO_TIER2_APPROVAL"* ]]
    [ -f "$TIER2_AUDIT_PATH" ]
    grep -q '"confirmed_by":"aaron"' "$TIER2_AUDIT_PATH"
    grep -q '"path":"/admin/user/123"' "$TIER2_AUDIT_PATH"
}

# --- Non-regression: sub-resources must NOT be gated ---

@test "DELETE /admin/user/<id>/image (sub-resource) is NOT tier-2 gated" {
    run bash "$SCRIPT" call DELETE /admin/user/123/image
    [[ "$output" != *"MUSO_TIER2_APPROVAL"* ]]
}

@test "DELETE /admin/track/<id>/profile/<pid>/credits (remove_credits path) is NOT tier-2 gated (the removal gate refuses it instead)" {
    run bash "$SCRIPT" call DELETE /admin/track/t1/profile/p1/credits
    [[ "$output" != *"MUSO_TIER2_APPROVAL"* ]]
    [[ "$output" == *"MUSO_REMOVAL_NO_SELF_APPROVE"* ]]
}

@test "DELETE /admin/track/<id>/analytics-sources (sub-resource) is NOT tier-2 gated" {
    run bash "$SCRIPT" call DELETE /admin/track/t1/analytics-sources '{"x":1}'
    [[ "$output" != *"MUSO_TIER2_APPROVAL"* ]]
}

@test "GET /admin/user/<id> (read) is NOT tier-2 gated" {
    run bash "$SCRIPT" call GET /admin/user/123
    [[ "$output" != *"MUSO_TIER2_APPROVAL"* ]]
}

@test "query string on a gated path does not evade the gate" {
    run bash "$SCRIPT" call DELETE '/admin/user/123?foo=bar'
    [ "$status" -eq 1 ]
    [[ "$output" == *"MUSO_TIER2_APPROVAL_REQUIRED"* ]]
}

# --- Regression: existing param-less merge entry still exact-matches ---

@test "existing param-less merge endpoint stays gated (exact match preserved)" {
    run bash "$SCRIPT" call POST /admin/profiles/merge '{"mergeInto":"a","profilesIds":["b"]}'
    [ "$status" -eq 1 ]
    [[ "$output" == *"MUSO_TIER2_APPROVAL_REQUIRED"* ]]
}

@test "a path that merely shares a prefix with a merge endpoint is NOT gated" {
    # /admin/profiles/mergeable is not /admin/profiles/merge — exact match only.
    run bash "$SCRIPT" call POST /admin/profiles/mergeable '{}'
    [[ "$output" != *"MUSO_TIER2_APPROVAL"* ]]
}

# --- God-mode policy on the high-blast-radius endpoints (policy 2026-06-15) ---
# God-mode admins (jan/nick/aaron) KEEP access to user-delete / track-delete /
# subscription-create, but — unlike other tier-2 writes — may NOT self-approve
# these off a bare auto-stamped --requester: an explicit --approval-msg-id is
# required, so the ops agent can't silently execute one.

@test "god-mode admin is REFUSED on user-delete WITHOUT --approval-msg-id" {
    run bash "$SCRIPT" --requester jan@muso.ai call DELETE /admin/user/123
    [ "$status" -eq 1 ]
    [[ "$output" == *"MUSO_TIER2_GODMODE_APPROVAL_MSG_REQUIRED"* ]]
}

@test "god-mode admin PASSES user-delete WITH --approval-msg-id (audited as god-mode self-approve, real msg id)" {
    run bash "$SCRIPT" --requester jan@muso.ai --approval-msg-id 1777474838.796239 \
        call DELETE /admin/user/123
    [[ "$output" != *"MUSO_TIER2_GODMODE_APPROVAL_MSG_REQUIRED"* ]]
    [[ "$output" != *"MUSO_TIER2_APPROVAL"* ]]
    [ -f "$TIER2_AUDIT_PATH" ]
    grep -q '"bypass":"god_mode_self_approve"' "$TIER2_AUDIT_PATH"
    grep -q '"approval_msg_id":"1777474838.796239"' "$TIER2_AUDIT_PATH"
}

@test "god-mode admin still self-approves a NON-nuclear tier-2 write (merge) WITHOUT --approval-msg-id" {
    run bash "$SCRIPT" --requester jan@muso.ai \
        call POST /admin/profiles/merge '{"mergeInto":"a","profilesIds":["b"]}'
    [[ "$output" != *"MUSO_TIER2_GODMODE_APPROVAL_MSG_REQUIRED"* ]]
    [[ "$output" != *"MUSO_TIER2_APPROVAL"* ]]
    grep -q '"bypass":"god_mode_self_approve"' "$TIER2_AUDIT_PATH"
}

@test "god-mode admin is REFUSED on subscription-create WITHOUT --approval-msg-id" {
    run bash "$SCRIPT" --requester nick@muso.ai call POST /admin/subscription '{"userId":"u1"}'
    [ "$status" -eq 1 ]
    [[ "$output" == *"MUSO_TIER2_GODMODE_APPROVAL_MSG_REQUIRED"* ]]
}

# --- Removals never self-approve (firstmate 122, incident 2026-10-20 14:05Z) ---
@test "god-mode admin is REFUSED on a whole-track DELETE even WITH --approval-msg-id (removal)" {
    run bash "$SCRIPT" --requester jan@muso.ai --approval-msg-id 1792504998.731149 \
        call DELETE /admin/track/2631b04d-3dc2-40dd-8a69-b1cad202d9d3
    [ "$status" -eq 1 ]
    [[ "$output" == *"MUSO_REMOVAL_NO_SELF_APPROVE"* ]]
    [[ "$output" == *"no track hide/unlist"* ]]
    if [ -f "$TIER2_AUDIT_PATH" ]; then
        if grep -q '"bypass":"god_mode_self_approve"' "$TIER2_AUDIT_PATH"; then false; fi
    fi
}

@test "god-mode user-delete with --approval-msg-id is unchanged (not a removal)" {
    run bash "$SCRIPT" --requester jan@muso.ai --approval-msg-id 1777474838.796239 call DELETE /admin/user/123
    [[ "$output" != *"MUSO_REMOVAL_NO_SELF_APPROVE"* ]]
}

# QA #1299 @a3bc2731: below the bulk threshold (0 prior DELETEs) a god-mode credit removal used
# to reach core. The removal gate now refuses it before any gate, any audit row and any request.
@test "removal gate: a god-mode credit removal BELOW the bulk threshold is refused before any request" {
    run bash "$SCRIPT" --requester jan@muso.ai --approval-msg-id 1792504998.731149 \
        call DELETE /admin/track/t1/profile/p1/credits
    [ "$status" -eq 1 ]
    [[ "$output" == *"MUSO_REMOVAL_NO_SELF_APPROVE"* ]]
    [[ "$output" != *"127.0.0.1"* ]]
    if [ -f "$TIER2_AUDIT_PATH" ]; then
        if grep -q '"bypass":"god_mode_self_approve"' "$TIER2_AUDIT_PATH"; then false; fi
    fi
}

@test "removal gate: any requester, with or without --confirmed-by, is refused for both removal routes" {
    for path in /admin/track/t1 /admin/track/t1/profile/p1/credits /admin/track/t1/profile/p1/credits/; do
        run bash "$SCRIPT" --requester someone@muso.ai --confirmed-by aaron --approval-msg-id 1777474838.796239 \
            call DELETE "$path"
        [ "$status" -eq 1 ]
        [[ "$output" == *"MUSO_REMOVAL_NO_SELF_APPROVE"* ]]
    done
}

@test "removal gate: dry-run still shows the call; other track DELETEs are untouched" {
    run env OPS_DRY_RUN=1 bash "$SCRIPT" call DELETE /admin/track/t1/profile/p1/credits
    [[ "$output" != *"MUSO_REMOVAL_NO_SELF_APPROVE"* ]]
    run bash "$SCRIPT" call DELETE /admin/track/t1/analytics-sources '{"x":1}'
    [[ "$output" != *"MUSO_REMOVAL_NO_SELF_APPROVE"* ]]
}
