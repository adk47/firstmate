#!/usr/bin/env bats
# Tests for enforce_credit_reject_gate() in muso-admin-api.sh (canonical copy).
#
# Incident 2026-07-22: during Jan's UVN/ClickUp sweep the Ops agent autonomously
# REJECTED 28 credit requests. Jan's correction ("move them back to verification
# needed") was impossible: core-backend's updateStatus.js allows the
# user_verification_needed transition ONLY from `unverified` — the only exit
# from `rejected` is `approved`. Rejection is a one-way door, so it is never
# autonomous: it requires --confirmed-by <tier-2 approver> + --approval-msg-id,
# exactly like the bulk-destructive gate.
#
# The workspace copy (rank-1 shadow the operations agent actually runs) is
# covered by the sibling suite
# workspaces/operations/skills/muso-ops-admin/scripts/tests/enforce-credit-reject-gate.bats.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  SCRIPT="${ADMIN_API_SCRIPT:-$REPO_ROOT/skills-all/muso-ops-admin/scripts/muso-admin-api.sh}"
  [[ -f "$SCRIPT" ]] || { echo "SCRIPT not found: $SCRIPT" >&2; return 1; }

  # Hermetic env: state/audit writes stay inside the test tmpdir; dummy API
  # env satisfies check_env without any network (dry-run short-circuits
  # before curl; the refuse paths return before get_token).
  export MUSO_OPS_STATE_DIR="$BATS_TEST_TMPDIR/state"
  export OPS_DRY_RUN_AUDIT_PATH="$BATS_TEST_TMPDIR/dry-run-audit.jsonl"
  export MUSO_API_URL="http://127.0.0.1:0/none"
  export MUSO_ADMIN_EMAIL="test@example.com"
  export MUSO_ADMIN_PASSWORD="x"
  unset CONFIRMED_BY APPROVAL_MSG_ID REQUESTER_EMAIL OPS_DRY_RUN CREDIT_REJECT_AUDIT_PATH

  # SCRIPT_DIR derives from $0, which under `source` is the bats binary — pin
  # the approver allowlist to a fixture (same pattern as tier2-approval.bats).
  export TIER2_APPROVERS_PATH="$BATS_TEST_TMPDIR/tier2-approvers.txt"
  cat > "$TIER2_APPROVERS_PATH" <<EOF
aaron
aaron@muso.ai
jan
jan@muso.ai
nick
nick@muso.ai
EOF

  REJECT_BODY='{"requestIds":["cr_1"],"status":"rejected"}'
  # Evasion bodies: both parse to status:"rejected" via core-backend's JSON.parse
  # but slip a line-oriented literal grep — the gate must detect them structurally.
  # The backslash is spliced from a var so no literal \u escape lives in this
  # source (which round-trips through tools that would decode it); jq sees the
  # decoded "rejected", a raw-byte grep does not.
  local bs='\'
  REJECT_BODY_UESC='{"requestIds":["cr_1"],"status":"'"${bs}"'u0072ejected"}'
  REJECT_BODY_NL=$'{"requestIds":["cr_1"],\n"status":\n"rejected"}'
}

source_gate() {
  # shellcheck disable=SC1090
  source "$SCRIPT"
}

# ── Function-level: refuse paths ─────────────────────────────────────────────

@test "block: PUT collection status=rejected with no confirmation" {
  source_gate
  run enforce_credit_reject_gate PUT /admin/credit-requests "$REJECT_BODY"
  [ "$status" -ne 0 ]
  [[ "$output" == *"MUSO_CREDIT_REJECT_APPROVAL_REQUIRED"* ]]
  # The error must teach the recovery path: keep in UVN + escalate to Jan,
  # and say WHY (rejection is one-way).
  [[ "$output" == *"user_verification_needed"* ]]
  [[ "$output" == *"one-way"* ]]
}

@test "block: --requester jan@muso.ai does NOT bypass (requester is auto-stamped, not evidence)" {
  source_gate
  REQUESTER_EMAIL="jan@muso.ai" run enforce_credit_reject_gate PUT /admin/credit-requests "$REJECT_BODY"
  [ "$status" -ne 0 ]
  [[ "$output" == *"MUSO_CREDIT_REJECT_APPROVAL_REQUIRED"* ]]
}

@test "block: --confirmed-by outside approver allowlist" {
  source_gate
  CONFIRMED_BY="serhii" APPROVAL_MSG_ID="1777474838.796239" \
    run enforce_credit_reject_gate PUT /admin/credit-requests "$REJECT_BODY"
  [ "$status" -ne 0 ]
  [[ "$output" == *"MUSO_CREDIT_REJECT_APPROVAL_INVALID"* ]]
}

@test "block: --confirmed-by jan without --approval-msg-id" {
  source_gate
  CONFIRMED_BY="jan" run enforce_credit_reject_gate PUT /admin/credit-requests "$REJECT_BODY"
  [ "$status" -ne 0 ]
  [[ "$output" == *"--approval-msg-id"* ]]
}

@test "block: PATCH /admin/credit-requests/<id> status=rejected is gated (parity with approve gate)" {
  source_gate
  run enforce_credit_reject_gate PATCH /admin/credit-requests/cr_1 '{"status":"rejected"}'
  [ "$status" -ne 0 ]
  [[ "$output" == *"MUSO_CREDIT_REJECT_APPROVAL_REQUIRED"* ]]
}

@test "block: profileId-shaped bulk body status=rejected is gated (matches on status, not id shape)" {
  source_gate
  run enforce_credit_reject_gate PUT /admin/credit-requests '{"profileId":"p_1","status":"rejected"}'
  [ "$status" -ne 0 ]
  [[ "$output" == *"MUSO_CREDIT_REJECT_APPROVAL_REQUIRED"* ]]
}

@test "block: lower-case method 'put' still gated (case-normalized)" {
  source_gate
  run enforce_credit_reject_gate put /admin/credit-requests "$REJECT_BODY"
  [ "$status" -ne 0 ]
  [[ "$output" == *"MUSO_CREDIT_REJECT_APPROVAL_REQUIRED"* ]]
}

# Evasion regression (structural detection, not literal grep). A body that
# JSON-parses to status:"rejected" but dodges a line-oriented byte grep must
# still be gated — else an evasive agent performs the one-way reject unaudited.
@test "block: inter-token NEWLINE body status=rejected is still gated" {
  source_gate
  # sanity: this body dodges the old literal grep (status != 0 means no match)
  run grep -q '"status"[[:space:]]*:[[:space:]]*"rejected"' <<< "$REJECT_BODY_NL"
  [ "$status" -ne 0 ]
  run enforce_credit_reject_gate PUT /admin/credit-requests "$REJECT_BODY_NL"
  [ "$status" -ne 0 ]
  [[ "$output" == *"MUSO_CREDIT_REJECT_APPROVAL_REQUIRED"* ]]
}

@test "block: \\uXXXX-escaped 'rejected' body is still gated (jq decodes it like the backend)" {
  source_gate
  # sanity: raw bytes dodge the literal grep (no match), but jq decodes to rejected
  run grep -q '"status"[[:space:]]*:[[:space:]]*"rejected"' <<< "$REJECT_BODY_UESC"
  [ "$status" -ne 0 ]
  [ "$(printf '%s' "$REJECT_BODY_UESC" | jq -r '.status')" = "rejected" ]
  run enforce_credit_reject_gate PUT /admin/credit-requests "$REJECT_BODY_UESC"
  [ "$status" -ne 0 ]
  [[ "$output" == *"MUSO_CREDIT_REJECT_APPROVAL_REQUIRED"* ]]
}

# Regression guard: no caller-settable escape hatch. The actor this gate
# restrains sets per-command env when invoking the tool, so an env off-switch
# would make the guard optional for exactly that actor (same doctrine as
# CODEX_HEALTH_GATE_DISABLED).
@test "block: CREDIT_REJECT_GATE_DISABLED=1 does NOT bypass" {
  source_gate
  CREDIT_REJECT_GATE_DISABLED=1 run enforce_credit_reject_gate PUT /admin/credit-requests "$REJECT_BODY"
  [ "$status" -ne 0 ]
  # pin WHY it refused — the off-switch must be inert, not merely erroring
  [[ "$output" == *"MUSO_CREDIT_REJECT_APPROVAL_REQUIRED"* ]]
}

@test "block: audit path unwritable refuses even with valid approval (fail-closed)" {
  source_gate
  CREDIT_REJECT_AUDIT_PATH="/nonexistent-dir/no/credit-reject-audit.jsonl" \
    CONFIRMED_BY="jan" APPROVAL_MSG_ID="1777474838.796239" \
    run enforce_credit_reject_gate PUT /admin/credit-requests "$REJECT_BODY"
  [ "$status" -ne 0 ]
  [[ "$output" == *"MUSO_CREDIT_REJECT_AUDIT_UNWRITABLE"* ]]
}

# ── Function-level: allow + passthrough paths ────────────────────────────────

@test "allow: --confirmed-by jan + --approval-msg-id passes and writes audit row" {
  source_gate
  CONFIRMED_BY="jan" APPROVAL_MSG_ID="1777474838.796239" \
    run enforce_credit_reject_gate PUT /admin/credit-requests "$REJECT_BODY"
  [ "$status" -eq 0 ]
  audit="$MUSO_OPS_STATE_DIR/credit-reject-audit.jsonl"
  [ -f "$audit" ]
  grep -q '"confirmed_by":"jan"' "$audit"
  grep -q '"approval_msg_id":"1777474838.796239"' "$audit"
}

@test "allow: aaron@muso.ai and nick are also valid approvers" {
  source_gate
  CONFIRMED_BY="aaron@muso.ai" APPROVAL_MSG_ID="1.2" \
    run enforce_credit_reject_gate PUT /admin/credit-requests "$REJECT_BODY"
  [ "$status" -eq 0 ]
  CONFIRMED_BY="nick" APPROVAL_MSG_ID="1.3" \
    run enforce_credit_reject_gate PATCH /admin/credit-requests/cr_1 '{"status":"rejected"}'
  [ "$status" -eq 0 ]
}

@test "passthrough: status=user_verification_needed (the sanctioned alternative)" {
  source_gate
  run enforce_credit_reject_gate PUT /admin/credit-requests '{"requestIds":["cr_1"],"status":"user_verification_needed"}'
  [ "$status" -eq 0 ]
}

@test "passthrough: status=approved (approve gate's territory, not this gate's)" {
  source_gate
  run enforce_credit_reject_gate PUT /admin/credit-requests '{"requestIds":["cr_1"],"status":"approved"}'
  [ "$status" -eq 0 ]
}

@test "passthrough: claim rejection endpoint untouched (POST /admin/claiming/:id/reject)" {
  source_gate
  run enforce_credit_reject_gate POST /admin/claiming/cl_1/reject '{"status":"rejected"}'
  [ "$status" -eq 0 ]
}

@test "passthrough: GET reads never gated" {
  source_gate
  run enforce_credit_reject_gate GET "/admin/credit-requests?status=rejected" ''
  [ "$status" -eq 0 ]
}

# ── CLI-level: gate is wired into cmd_call (dry-run: no network, no journalctl) ──

@test "CLI: dry-run reject without confirmation is REFUSED (gate fires before dry-run short-circuit)" {
  OPS_DRY_RUN=1 run bash "$SCRIPT" call PUT /admin/credit-requests "$REJECT_BODY"
  [ "$status" -ne 0 ]
  [[ "$output" == *"MUSO_CREDIT_REJECT_APPROVAL_REQUIRED"* ]]
  [[ "$output" != *'"dryRun":true'* ]]
}

@test "CLI: dry-run reject WITH --confirmed-by jan + --approval-msg-id passes the gate" {
  OPS_DRY_RUN=1 run bash "$SCRIPT" --confirmed-by jan --approval-msg-id 1777474838.796239 \
    call PUT /admin/credit-requests "$REJECT_BODY"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"dryRun":true'* ]]
}
