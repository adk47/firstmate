#!/usr/bin/env bats
# Tests for enforce_credit_reject_gate() in the WORKSPACE muso-admin-api.sh —
# the rank-1 shadow the operations agent actually executes.
#
# Incident 2026-07-22: the Ops agent autonomously rejected 28 UVN credit
# requests during Jan's ClickUp sweep. core-backend's transition matrix has no
# rejected→user_verification_needed path (only rejected→approved), so the
# mistake was irreversible. Rejection is therefore never autonomous — it needs
# --confirmed-by <tier-2 approver> + --approval-msg-id.
#
# The canonical copy is covered by scripts/tests/muso-admin-api-reject-gate.bats
# (which also exercises the cmd_call wiring); this suite pins the same
# function-level contract onto the diverged workspace script.

setup() {
    TEST_ROOT="$(mktemp -d)"
    export TEST_ROOT

    SCRIPT="${BATS_TEST_DIRNAME}/../muso-admin-api.sh"
    [[ -f "$SCRIPT" ]] || { echo "SCRIPT not found: $SCRIPT" >&2; return 1; }

    # Hermetic env: keep state/audit writes in the tmpdir; sandbox the runlog
    # dir so host state can't leak in (same rationale as the approve-gate suite).
    export MUSO_OPS_STATE_DIR="$TEST_ROOT/state"
    export OPS_RUNLOG_DIR="$TEST_ROOT/runlogs"
    mkdir -p "$OPS_RUNLOG_DIR"
    unset CONFIRMED_BY APPROVAL_MSG_ID REQUESTER_EMAIL OPS_DRY_RUN CREDIT_REJECT_AUDIT_PATH

    # SCRIPT_DIR derives from $0, which under `source` is the bats binary —
    # pin the approver allowlist to a fixture (same as tier2-approval.bats).
    export TIER2_APPROVERS_PATH="$TEST_ROOT/tier2-approvers.txt"
    cat > "$TIER2_APPROVERS_PATH" <<EOF
aaron
aaron@muso.ai
jan
jan@muso.ai
nick
nick@muso.ai
EOF

    REJECT_BODY='{"requestIds":["cr_1"],"status":"rejected"}'
    # Evasion bodies: parse to status:"rejected" via the backend's JSON.parse but
    # slip a line-oriented literal grep. Backslash spliced from a var so no literal
    # \u escape lives in this source (tools would decode it). Gate must catch both.
    local bs='\'
    REJECT_BODY_UESC='{"requestIds":["cr_1"],"status":"'"${bs}"'u0072ejected"}'
    REJECT_BODY_NL=$'{"requestIds":["cr_1"],\n"status":\n"rejected"}'
}

teardown() {
    rm -rf "$TEST_ROOT"
}

source_gate() {
    # shellcheck disable=SC1090
    source "$SCRIPT"
}

@test "block: PUT collection status=rejected with no confirmation" {
    source_gate
    run enforce_credit_reject_gate PUT /admin/credit-requests "$REJECT_BODY"
    [ "$status" -ne 0 ]
    [[ "$output" == *"MUSO_CREDIT_REJECT_APPROVAL_REQUIRED"* ]]
    [[ "$output" == *"user_verification_needed"* ]]
}

@test "block: requester identity does not bypass" {
    source_gate
    REQUESTER_EMAIL="jan@muso.ai" run enforce_credit_reject_gate PUT /admin/credit-requests "$REJECT_BODY"
    [ "$status" -ne 0 ]
    [[ "$output" == *"MUSO_CREDIT_REJECT_APPROVAL_REQUIRED"* ]]
}

@test "block: non-approver --confirmed-by" {
    source_gate
    CONFIRMED_BY="serhii" APPROVAL_MSG_ID="1.2" \
        run enforce_credit_reject_gate PUT /admin/credit-requests "$REJECT_BODY"
    [ "$status" -ne 0 ]
    [[ "$output" == *"MUSO_CREDIT_REJECT_APPROVAL_INVALID"* ]]
}

@test "block: missing --approval-msg-id" {
    source_gate
    CONFIRMED_BY="jan" run enforce_credit_reject_gate PUT /admin/credit-requests "$REJECT_BODY"
    [ "$status" -ne 0 ]
    [[ "$output" == *"--approval-msg-id"* ]]
}

@test "block: PATCH single-credit reject is gated" {
    source_gate
    run enforce_credit_reject_gate PATCH /admin/credit-requests/cr_1 '{"status":"rejected"}'
    [ "$status" -ne 0 ]
    [[ "$output" == *"MUSO_CREDIT_REJECT_APPROVAL_REQUIRED"* ]]
}

# Evasion regression (structural detection, not literal grep): a body that
# JSON-parses to status:"rejected" but dodges a line-oriented byte grep must
# still be gated — else an evasive agent performs the one-way reject unaudited.
@test "block: inter-token NEWLINE body status=rejected is still gated" {
    source_gate
    run grep -q '"status"[[:space:]]*:[[:space:]]*"rejected"' <<< "$REJECT_BODY_NL"
    [ "$status" -ne 0 ]
    run enforce_credit_reject_gate PUT /admin/credit-requests "$REJECT_BODY_NL"
    [ "$status" -ne 0 ]
    [[ "$output" == *"MUSO_CREDIT_REJECT_APPROVAL_REQUIRED"* ]]
}

@test "block: \\uXXXX-escaped 'rejected' body is still gated (jq decodes it like the backend)" {
    source_gate
    run grep -q '"status"[[:space:]]*:[[:space:]]*"rejected"' <<< "$REJECT_BODY_UESC"
    [ "$status" -ne 0 ]
    [ "$(printf '%s' "$REJECT_BODY_UESC" | jq -r '.status')" = "rejected" ]
    run enforce_credit_reject_gate PUT /admin/credit-requests "$REJECT_BODY_UESC"
    [ "$status" -ne 0 ]
    [[ "$output" == *"MUSO_CREDIT_REJECT_APPROVAL_REQUIRED"* ]]
}

@test "block: no env off-switch (CREDIT_REJECT_GATE_DISABLED=1 ignored)" {
    source_gate
    CREDIT_REJECT_GATE_DISABLED=1 run enforce_credit_reject_gate PUT /admin/credit-requests "$REJECT_BODY"
    [ "$status" -ne 0 ]
    [[ "$output" == *"MUSO_CREDIT_REJECT_APPROVAL_REQUIRED"* ]]
}

@test "block: audit path unwritable refuses even with valid approval (fail-closed)" {
    source_gate
    # Parent is a regular FILE, so mkdir -p hits ENOTDIR and fails for ANY uid —
    # unlike /nonexistent-dir, which root (the self-hosted CI runner) can create.
    touch "$TEST_ROOT/not-a-dir"
    CREDIT_REJECT_AUDIT_PATH="$TEST_ROOT/not-a-dir/sub/credit-reject-audit.jsonl" \
        CONFIRMED_BY="jan" APPROVAL_MSG_ID="1777474838.796239" \
        run enforce_credit_reject_gate PUT /admin/credit-requests "$REJECT_BODY"
    [ "$status" -ne 0 ]
    [[ "$output" == *"MUSO_CREDIT_REJECT_AUDIT_UNWRITABLE"* ]]
}

@test "allow: jan + approval-msg-id passes and writes audit row" {
    source_gate
    CONFIRMED_BY="jan" APPROVAL_MSG_ID="1777474838.796239" \
        run enforce_credit_reject_gate PUT /admin/credit-requests "$REJECT_BODY"
    [ "$status" -eq 0 ]
    audit="$MUSO_OPS_STATE_DIR/credit-reject-audit.jsonl"
    grep -q '"confirmed_by":"jan"' "$audit"
    grep -q '"approval_msg_id":"1777474838.796239"' "$audit"
}

@test "passthrough: user_verification_needed and approved statuses" {
    source_gate
    run enforce_credit_reject_gate PUT /admin/credit-requests '{"requestIds":["cr_1"],"status":"user_verification_needed"}'
    [ "$status" -eq 0 ]
    run enforce_credit_reject_gate PUT /admin/credit-requests '{"requestIds":["cr_1"],"status":"approved"}'
    [ "$status" -eq 0 ]
}

@test "passthrough: claim rejection endpoint untouched" {
    source_gate
    run enforce_credit_reject_gate POST /admin/claiming/cl_1/reject ''
    [ "$status" -eq 0 ]
}
