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

# ── fable-decider (L12 executor; captain 2026-10-28 21:3xZ, approval_ref captain-1028-213x) ──────────────
# The one agent path past this gate. It must take exactly one shape and refuse every near miss.
fd_setup() {
    export CREDIT_APPROVAL_REGISTRY="$TEST_ROOT/registry.json"
    printf '%s' '{"automations":{"fable-decider":{"approved":true,"approved_by":"captain","approval_ref":"captain-1028-213x"}}}' \
        > "$CREDIT_APPROVAL_REGISTRY"
    export FABLE_DECIDER_KILL_FILE="$TEST_ROOT/fable-decider.disabled"
    FD_PATH=/admin/credit-requests/conditional-status
    FD_BODY='{"requestIds":["11111111-1111-4111-8111-111111111111","22222222-2222-4222-8222-222222222222"],"status":"rejected","expectedStatus":"unverified"}'
}

fd_run() {  # fd_run <path> <body> [extra env assignments...]
    # REQUESTER_EMAIL is reset when the wrapper is sourced (it comes from --requester), so the test sets it
    # after sourcing from FD_REQUESTER.
    local p="$1" b="$2"; shift 2
    # The boundary verifier (python, Trino + account gate) is stubbed by default: FD_VERIFY=ok|refuse; FD_VERIFY=real
    # runs the real one. The stub is defined AFTER sourcing, which a real caller cannot do (an exported
    # BASH_FUNC_ import is overwritten by the wrapper's own definition at source time).
    env FABLE_DECIDER=1 FD_REQUESTER=fable-decider@hydra-ops FABLE_RULING_ID=u10k-3 \
        FABLE_DECIDER_RUN_ID=run1 FABLE_DECIDER_TRAY="$TEST_ROOT/tray.json" FD_VERIFY=ok "$@" \
        FD_P="$p" FD_B="$b" bash -c 'set --; source "$0"; REQUESTER_EMAIL="$FD_REQUESTER"
            case "$FD_VERIFY" in
                ok) fable_decider_verify_batch() { echo "$1" > "$TEST_ROOT/verified-body"; return 0; } ;;
                refuse) fable_decider_verify_batch() { return 3; } ;;
            esac
            enforce_credit_reject_gate PUT "$FD_P" "$FD_B"' "$SCRIPT"
}

@test "fable-decider: the registered close shape passes and is audited with the ruling id" {
    fd_setup
    run fd_run "$FD_PATH" "$FD_BODY"
    [ "$status" -eq 0 ]
    audit="$MUSO_OPS_STATE_DIR/credit-reject-audit.jsonl"
    grep -q '"confirmed_by":"fable-decider"' "$audit"
    grep -q '"approval_msg_id":"u10k-3"' "$audit"
    grep -q '"rows":2' "$audit"
}

@test "fable-decider: user_verification_needed is a closable expected status" {
    fd_setup
    run fd_run "$FD_PATH" '{"requestIds":["11111111-1111-4111-8111-111111111111"],"status":"rejected","expectedStatus":"user_verification_needed"}'
    [ "$status" -eq 0 ]
}

@test "fable-decider: never from approved (no take-back) and never without expectedStatus" {
    fd_setup
    run fd_run "$FD_PATH" '{"requestIds":["11111111-1111-4111-8111-111111111111"],"status":"rejected","expectedStatus":"approved"}'
    [ "$status" -ne 0 ]
    run fd_run "$FD_PATH" '{"requestIds":["11111111-1111-4111-8111-111111111111"],"status":"rejected"}'
    [ "$status" -ne 0 ]
}

@test "fable-decider: only the conditional route" {
    fd_setup
    run fd_run /admin/credit-requests "$FD_BODY"
    [ "$status" -ne 0 ]
    [[ "$output" == *"MUSO_CREDIT_REJECT_APPROVAL_REQUIRED"* ]]
}

@test "fable-decider: kill file refuses" {
    fd_setup
    touch "$FABLE_DECIDER_KILL_FILE"
    run fd_run "$FD_PATH" "$FD_BODY"
    [ "$status" -ne 0 ]
    [[ "$output" == *"kill file"* ]]
}

@test "fable-decider: registry not approved refuses" {
    fd_setup
    printf '%s' '{"automations":{"fable-decider":{"approved":false,"approved_by":"captain","approval_ref":"x"}}}' > "$CREDIT_APPROVAL_REGISTRY"
    run fd_run "$FD_PATH" "$FD_BODY"
    [ "$status" -ne 0 ]
}

@test "fable-decider: missing ruling id, wrong requester or flag off refuses" {
    fd_setup
    run fd_run "$FD_PATH" "$FD_BODY" FABLE_RULING_ID=
    [ "$status" -ne 0 ]
    run fd_run "$FD_PATH" "$FD_BODY" FD_REQUESTER=credit-trust-decide@hydra-ops
    [ "$status" -ne 0 ]
    run fd_run "$FD_PATH" "$FD_BODY" FABLE_DECIDER=0
    [ "$status" -ne 0 ]
}

@test "fable-decider: more than 100 ids, duplicates or extra keys refuse" {
    fd_setup
    many=$(python3 -c 'import json,uuid;print(json.dumps({"requestIds":[str(uuid.uuid4()) for _ in range(101)],"status":"rejected","expectedStatus":"unverified"}))')
    run fd_run "$FD_PATH" "$many"
    [ "$status" -ne 0 ]
    run fd_run "$FD_PATH" '{"requestIds":["11111111-1111-4111-8111-111111111111","11111111-1111-4111-8111-111111111111"],"status":"rejected","expectedStatus":"unverified"}'
    [ "$status" -ne 0 ]
    run fd_run "$FD_PATH" '{"requestIds":["11111111-1111-4111-8111-111111111111"],"status":"rejected","expectedStatus":"unverified","notify":false}'
    [ "$status" -ne 0 ]
}

@test "fable-decider: the boundary re-check runs on every close and its refusal refuses" {
    fd_setup
    run fd_run "$FD_PATH" "$FD_BODY"
    [ "$status" -eq 0 ]
    grep -q '"rejected"' "$TEST_ROOT/verified-body"
    run fd_run "$FD_PATH" "$FD_BODY" FD_VERIFY=refuse
    [ "$status" -ne 0 ]
}

@test "fable-decider: missing run id or tray refuses before the verifier" {
    fd_setup
    run fd_run "$FD_PATH" "$FD_BODY" FABLE_DECIDER_RUN_ID=
    [ "$status" -ne 0 ]
    run fd_run "$FD_PATH" "$FD_BODY" FABLE_DECIDER_TRAY=
    [ "$status" -ne 0 ]
}

@test "fable-decider: a direct caller with the flags but no executor run is refused by the REAL verifier" {
    # QA #1475 Critical: env flags alone must not close anything. No tray / no reservation from this run.
    fd_setup
    command -v python3 >/dev/null || skip "python3 not available"
    run fd_run "$FD_PATH" "$FD_BODY" FD_VERIFY=real
    [ "$status" -ne 0 ]
    # refused by verify_batch itself (not an argv/parse error, which would also refuse every genuine close)
    [[ "$output" == *"fable_decider boundary: tray unusable"* ]]
}

@test "fable-decider: grants no tier-2 approver status (merges / bulk deletes stay human)" {
    fd_setup
    source_gate
    run is_tier2_approver fable-decider
    [ "$status" -ne 0 ]
}
