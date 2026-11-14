#!/usr/bin/env bats
# Tests for the profile soft-delete half of the removal gate.
#
# Incident 2026-11-04: the operations bot ran `DELETE /admin/profile/<id>` 21
# times in 14 days on Jan's word. It reached core every time because that path
# was in NEITHER `config/tier2-endpoints.txt` NOR the removal refusal list, so a
# god-mode `--requester` self-approved it with no second key and no inverse —
# and it tombstones the profile AND every served credit on it (Gene Flores:
# 431 served credits -> 0). Legal hold 1350 means the data is never destroyed.
#
# "Hide" is not this endpoint. Hiding is the reversible hide-list PR that
# scripts/gdpr-pipeline.py prepares (H-DevOps HIDDEN_ENTITY_IDS + PDP
# LEGAL_HIDDEN_ENTITY_IDS), merged by a named human, undone by removing the id
# from both lists. AGENTS.md standing rule: "The pipeline only PREPARES the
# reversible hide PRs ... Never DELETE /api/v3/admin/profile".
#
# So: `DELETE /admin/profile/<id>` is a REMOVAL. It is refused for every
# requester, with or without --confirmed-by / --approval-msg-id, before any
# request goes out. Sub-resources stay untouched:
#   - `/admin/profile/<id>/cache` is the CDN purge (hide read-back uses it),
#   - `/admin/profile/<id>/credits` and `<id>/member` are separate documented endpoints.
#
# This is the CANONICAL copy's suite (skills-all/muso-ops-admin/scripts/). The
# workspace copy's matching cases live in workspaces/operations/skills/
# muso-ops-admin/scripts/tests/tier2-endpoint-matching.bats; both copies carry
# identical gate logic (check-admin-api-gate-parity.sh enforces that).

setup() {
    TEST_ROOT="$(mktemp -d)"
    export TEST_ROOT

    SCRIPT="${BATS_TEST_DIRNAME}/../muso-admin-api.sh"
    [[ -f "$SCRIPT" ]] || { echo "SCRIPT not found: $SCRIPT" >&2; return 1; }

    # Closed port so any real HTTP fails loudly. Every REFUSED case short-circuits
    # before curl; the pass-through cases fall through to curl (which fails) — so
    # those assertions are about the ABSENCE of the removal refusal and the
    # ABSENCE of the path in the request, not about an HTTP result.
    export MUSO_API_URL="http://127.0.0.1:1"
    export MUSO_ADMIN_EMAIL="test@example.com"
    export MUSO_ADMIN_PASSWORD="unused"

    export MUSO_OPS_STATE_DIR="$TEST_ROOT/state"
    export RECENT_MERGES_PATH="$TEST_ROOT/state/recent-merges.jsonl"
    export TIER2_AUDIT_PATH="$TEST_ROOT/state/tier2-audit.jsonl"
    export BULK_DESTRUCTIVE_PATH="$TEST_ROOT/state/destructive-ops.jsonl"
    export BULK_DESTRUCTIVE_AUDIT_PATH="$TEST_ROOT/state/bulk-destructive-audit.jsonl"
    export BULK_DESTRUCTIVE_THRESHOLD=3
    export BULK_DESTRUCTIVE_WINDOW_SECS=900

    export TIER2_APPROVERS_PATH="$TEST_ROOT/tier2-approvers.txt"
    export TIER2_ENDPOINTS_PATH="$TEST_ROOT/tier2-endpoints.txt"
    export BULK_DESTRUCTIVE_EXCLUDE_PATH="$TEST_ROOT/bulk-destructive-exclude.txt"
    cat > "$TIER2_APPROVERS_PATH" <<EOF
aaron
aaron@muso.ai
EOF
    # Deliberately does NOT list DELETE /admin/profile/:id — the refusal must
    # hold by its own logic, not because the endpoint happens to be tier-2.
    cat > "$TIER2_ENDPOINTS_PATH" <<EOF
POST /admin/profiles/merge
EOF
    cat > "$BULK_DESTRUCTIVE_EXCLUDE_PATH" <<EOF
/admin/profile/*/cache
EOF

    export CV_APPROVE_GATE_DISABLED=1
    export CODEX_HEALTH_LIB="$TEST_ROOT/codex-health-stub.sh"
    printf '%s\n' 'codex_health_gate() { return 0; }' > "$CODEX_HEALTH_LIB"
    export OPS_DRY_RUN_AUDIT_PATH="$TEST_ROOT/dry-run-audit.jsonl"
    export ADMIN_TOKEN_CACHE_PATH="$TEST_ROOT/.admin-token-cache"
    printf '%s\ndummy-token\n' "$(date +%s)" > "$ADMIN_TOKEN_CACHE_PATH"
    chmod 600 "$ADMIN_TOKEN_CACHE_PATH"
}

teardown() {
    rm -rf "$TEST_ROOT"
}

# --- The refusal ---

@test "a bare profile DELETE is refused (removal gate, no request sent)" {
    run bash "$SCRIPT" call DELETE /admin/profile/0d898512-1111-2222-3333-444455556666
    [ "$status" -eq 1 ]
    [[ "$output" == *"MUSO_REMOVAL_NO_SELF_APPROVE"* ]]
    # Refused BEFORE the request: the closed-port URL never appears.
    [[ "$output" != *"127.0.0.1"* ]]
}

@test "the refusal names the reversible hide path, not a retry route" {
    run bash "$SCRIPT" call DELETE /admin/profile/p1
    [ "$status" -eq 1 ]
    [[ "$output" == *"ops_intake/hide.py"* ]]
    [[ "$output" == *"reversible hide-list PR"* ]]
}

@test "even a god-mode requester WITH --approval-msg-id cannot self-approve a profile DELETE" {
    run bash "$SCRIPT" --requester jan@muso.ai --approval-msg-id 1793704998.000001 \
        call DELETE /admin/profile/p1
    [ "$status" -eq 1 ]
    [[ "$output" == *"MUSO_REMOVAL_NO_SELF_APPROVE"* ]]
    # No self-approve audit row is written for a refused write.
    if [ -f "$TIER2_AUDIT_PATH" ]; then
        ! grep -q '"bypass":"god_mode_self_approve"' "$TIER2_AUDIT_PATH"
    fi
}

@test "a second human's --confirmed-by does not release a profile DELETE either" {
    run bash "$SCRIPT" --confirmed-by aaron --approval-msg-id 1793704998.000002 \
        call DELETE /admin/profile/p1
    [ "$status" -eq 1 ]
    [[ "$output" == *"MUSO_REMOVAL_NO_SELF_APPROVE"* ]]
}

@test "a trailing slash does not evade the profile refusal" {
    run bash "$SCRIPT" call DELETE /admin/profile/p1/
    [ "$status" -eq 1 ]
    [[ "$output" == *"MUSO_REMOVAL_NO_SELF_APPROVE"* ]]
}

@test "a query string does not evade the profile refusal" {
    run bash "$SCRIPT" call DELETE '/admin/profile/p1?force=true'
    [ "$status" -eq 1 ]
    [[ "$output" == *"MUSO_REMOVAL_NO_SELF_APPROVE"* ]]
}

@test "lowercase method does not evade the profile refusal" {
    run bash "$SCRIPT" call delete /admin/profile/p1
    [ "$status" -eq 1 ]
    [[ "$output" == *"MUSO_REMOVAL_NO_SELF_APPROVE"* ]]
}

# --- Dry-run still shows the call (the removal gate self-skips) ---

@test "dry-run of a profile DELETE is not refused (it writes nothing)" {
    run bash "$SCRIPT" --dry-run call DELETE /admin/profile/p1
    [[ "$output" != *"MUSO_REMOVAL_NO_SELF_APPROVE"* ]]
}

# --- Non-regression: sub-resources are NOT the soft-delete ---

@test "the profile CACHE purge is not a removal (hide read-back needs it)" {
    run bash "$SCRIPT" call DELETE /admin/profile/p1/cache
    [[ "$output" != *"MUSO_REMOVAL_NO_SELF_APPROVE"* ]]
}

@test "the per-profile credits endpoint is not the soft-delete (its own gate applies)" {
    run bash "$SCRIPT" call DELETE /admin/profile/p1/credits
    [[ "$output" != *"MUSO_REMOVAL_NO_SELF_APPROVE"* ]]
}

@test "the per-profile member endpoint is not the soft-delete" {
    run bash "$SCRIPT" call DELETE /admin/profile/p1/member
    [[ "$output" != *"MUSO_REMOVAL_NO_SELF_APPROVE"* ]]
}

@test "a path that merely shares the /admin/profile prefix is not a removal" {
    run bash "$SCRIPT" call DELETE /admin/profiles/p1
    [[ "$output" != *"MUSO_REMOVAL_NO_SELF_APPROVE"* ]]
}
