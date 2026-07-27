#!/usr/bin/env bats
# Trigger-contract tests for enforce_credit_approve_gate() in the CANONICAL
# muso-admin-api.sh (skills-all copy).
#
# Scope is deliberately narrow: does the gate FIRE on an approve body, and stay
# out of the way otherwise? Every "block" case stops at the evidence-excerpt
# refusal, which happens before any session-log scan — so this suite needs no
# browser-evidence scaffolding. The full evidence machinery (Tier-1 browser
# quorum, web_fetch contamination, Tier-0 receipts, api-evidence mode) is
# covered against the workspace copy in
# workspaces/operations/skills/muso-ops-admin/scripts/tests/enforce-credit-approve-gate.bats.
#
# Why the trigger deserves its own pins: a miss `return 0`s past the ENTIRE
# evidence requirement (fail-open — an autonomous approve with no grounding),
# so a body that core-backend's JSON.parse reads as status:"approved" must be
# detected even when a line-oriented literal grep would not match it.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  SCRIPT="${ADMIN_API_SCRIPT:-$REPO_ROOT/skills-all/muso-ops-admin/scripts/muso-admin-api.sh}"
  [[ -f "$SCRIPT" ]] || { echo "SCRIPT not found: $SCRIPT" >&2; return 1; }

  # Hermetic env: no network (the refuse paths return long before get_token),
  # no host state, no inherited identity/evidence that could bypass the gate.
  export MUSO_OPS_STATE_DIR="$BATS_TEST_TMPDIR/state"
  export OPS_RUNLOG_DIR="$BATS_TEST_TMPDIR/runlogs"
  mkdir -p "$OPS_RUNLOG_DIR"
  export MUSO_API_URL="http://127.0.0.1:0/none"
  export MUSO_ADMIN_EMAIL="test@example.com"
  export MUSO_ADMIN_PASSWORD="x"
  unset REQUESTER_EMAIL CV_APPROVE_GATE_DISABLED EVIDENCE_EXCERPT \
        CV_SESSION_LOG_OVERRIDE CV_SESSION_RUN_STARTED_TS OPS_DRY_RUN
  export CV_EVIDENCE_EXCERPT_MIN=8
  export CV_EVIDENCE_EXCERPT_MAX=200

  APPROVE_BODY='{"requestIds":["cr_1"],"status":"approved"}'
  # Evasion bodies: both parse to status:"approved" via JSON.parse but slip a
  # line-oriented literal grep. The backslash is spliced from a var so no
  # literal \u escape lives in this source (tools would decode it).
  local bs='\'
  APPROVE_BODY_UESC='{"requestIds":["cr_1"],"status":"'"${bs}"'u0061pproved"}'
  APPROVE_BODY_NL=$'{"requestIds":["cr_1"],\n"status":\n"approved"}'
}

source_gate() {
  # shellcheck disable=SC1090
  source "$SCRIPT"
}

# ── Gate fires on an approve ─────────────────────────────────────────────────

@test "block: PUT collection status=approved requires evidence-excerpt" {
  source_gate
  run enforce_credit_approve_gate PUT /admin/credit-requests "$APPROVE_BODY"
  [ "$status" -ne 0 ]
  [[ "$output" == *"--evidence-excerpt is required"* ]]
}

@test "block: PATCH single-credit status=approved is gated (verb parity)" {
  source_gate
  run enforce_credit_approve_gate PATCH /admin/credit-requests/cr_1 '{"status":"approved"}'
  [ "$status" -ne 0 ]
  [[ "$output" == *"--evidence-excerpt is required"* ]]
}

@test "block: lower-case method 'put' still gated (case-normalized)" {
  source_gate
  run enforce_credit_approve_gate put /admin/credit-requests "$APPROVE_BODY"
  [ "$status" -ne 0 ]
  [[ "$output" == *"--evidence-excerpt is required"* ]]
}

# ── Evasion regressions (structural detection, not literal grep) ─────────────

@test "block: inter-token NEWLINE body status=approved is still gated" {
  source_gate
  # sanity: the old literal grep MISSES this body (non-zero = no match)
  run grep -q '"status"[[:space:]]*:[[:space:]]*"approved"' <<< "$APPROVE_BODY_NL"
  [ "$status" -ne 0 ]
  run enforce_credit_approve_gate PUT /admin/credit-requests "$APPROVE_BODY_NL"
  [ "$status" -ne 0 ]
  [[ "$output" == *"--evidence-excerpt is required"* ]]
}

@test "block: \\uXXXX-escaped 'approved' body is still gated (jq decodes it like the backend)" {
  source_gate
  # sanity: raw bytes dodge the literal grep, but jq decodes to approved
  run grep -q '"status"[[:space:]]*:[[:space:]]*"approved"' <<< "$APPROVE_BODY_UESC"
  [ "$status" -ne 0 ]
  [ "$(printf '%s' "$APPROVE_BODY_UESC" | jq -r '.status')" = "approved" ]
  run enforce_credit_approve_gate PUT /admin/credit-requests "$APPROVE_BODY_UESC"
  [ "$status" -ne 0 ]
  [[ "$output" == *"--evidence-excerpt is required"* ]]
}

# ── Gate stays out of the way otherwise ──────────────────────────────────────

@test "passthrough: status=user_verification_needed (not this gate's territory)" {
  source_gate
  run enforce_credit_approve_gate PUT /admin/credit-requests '{"requestIds":["cr_1"],"status":"user_verification_needed"}'
  [ "$status" -eq 0 ]
}

@test "passthrough: status=rejected (reject gate's territory)" {
  source_gate
  run enforce_credit_approve_gate PUT /admin/credit-requests '{"requestIds":["cr_1"],"status":"rejected"}'
  [ "$status" -eq 0 ]
}

@test "passthrough: GET reads never gated" {
  source_gate
  run enforce_credit_approve_gate GET "/admin/credit-requests?status=approved" ''
  [ "$status" -eq 0 ]
}

@test "passthrough: a non-credit-requests path with an approved body" {
  source_gate
  run enforce_credit_approve_gate PUT /admin/profile/p_1 "$APPROVE_BODY"
  [ "$status" -eq 0 ]
}

@test "passthrough: empty body (no status at all)" {
  source_gate
  run enforce_credit_approve_gate PUT /admin/credit-requests ''
  [ "$status" -eq 0 ]
}

# ── Human override still works through the new detection ────────────────────

@test "allow: --requester jan@muso.ai bypasses the gate (per-credit human verification)" {
  source_gate
  REQUESTER_EMAIL="jan@muso.ai" run enforce_credit_approve_gate PUT /admin/credit-requests "$APPROVE_BODY"
  [ "$status" -eq 0 ]
}
