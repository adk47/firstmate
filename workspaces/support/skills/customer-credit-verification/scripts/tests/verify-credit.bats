#!/usr/bin/env bats
# Tests for verify-credit.sh – the thin bash boundary in front of
# `muso credits verify` (an APPROVAL-tier PUT). muso is PATH-stubbed to emit
# canned stdout/stderr and a canned exit code, so no real binary or network is
# touched.

setup() {
  TEST_TMP="$(mktemp -d -t verifycredit-bats.XXXXXX)"
  STUB_DIR="$TEST_TMP/bin"
  mkdir -p "$STUB_DIR"

  cat > "$STUB_DIR/muso" <<'STUBEOF'
#!/usr/bin/env bash
# Record argv so a test can assert the muso command line.
printf '%s\n' "$@" > "${MUSO_STUB_ARGV_FILE:-/dev/null}"
[[ -n "${MUSO_STUB_STDOUT:-}" ]] && printf '%s\n' "$MUSO_STUB_STDOUT"
[[ -n "${MUSO_STUB_STDERR:-}" ]] && printf '%s\n' "$MUSO_STUB_STDERR" >&2
exit "${MUSO_STUB_RC:-0}"
STUBEOF
  chmod +x "$STUB_DIR/muso"

  export PATH="$STUB_DIR:$PATH"
  export CREDIT_VERIFY_AUDIT_LOG="$TEST_TMP/audit.jsonl"
  export MUSO_STUB_ARGV_FILE="$TEST_TMP/argv.txt"
  export MUSO_REQUESTER="caroline@muso.ai"
  export MUSO_ADMIN_EMAIL="admin@muso.ai"
  export MUSO_CAPABILITY_APPROVER="cap-approver"
  unset OPS_DRY_RUN

  SCRIPT="$BATS_TEST_DIRNAME/../verify-credit.sh"
  PROFILE="11111111-1111-1111-1111-111111111111"
  REQUEST="cr_abc123"
  ACTOR="owner@example.com"
  CONV="98765"
}

teardown() { rm -rf "$TEST_TMP"; }

jget() { printf '%s' "$output" | jq -r "$1"; }

@test "syntax-checks via bash -n" {
  run bash -n "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "missing --profile" {
  run bash "$SCRIPT" --request-id "$REQUEST" --actor-identity "$ACTOR"
  [ "$status" -eq 0 ]
  [ "$(jget .error)" = "missing_arg" ]
}

@test "missing --request-id" {
  run bash "$SCRIPT" --profile "$PROFILE" --actor-identity "$ACTOR"
  [ "$status" -eq 0 ]
  [ "$(jget .error)" = "missing_arg" ]
}

@test "missing --actor-identity" {
  run bash "$SCRIPT" --profile "$PROFILE" --request-id "$REQUEST"
  [ "$status" -eq 0 ]
  [ "$(jget .error)" = "missing_arg" ]
}

@test "missing --intercom-conv-id (required: it is the approval-ref)" {
  run bash "$SCRIPT" --profile "$PROFILE" --request-id "$REQUEST" --actor-identity "$ACTOR"
  [ "$status" -eq 0 ]
  [ "$(jget .error)" = "missing_arg" ]
}

@test "invalid profile id refuses" {
  run bash "$SCRIPT" --profile "not-a-uuid" --request-id "$REQUEST" --actor-identity "$ACTOR" --intercom-conv-id "$CONV"
  [ "$status" -eq 0 ]
  [ "$(jget .error)" = "invalid_profile_id" ]
}

@test "invalid request id refuses" {
  run bash "$SCRIPT" --profile "$PROFILE" --request-id "bad id with spaces" --actor-identity "$ACTOR" --intercom-conv-id "$CONV"
  [ "$status" -eq 0 ]
  [ "$(jget .error)" = "invalid_request_id" ]
}

@test "invalid actor email refuses" {
  run bash "$SCRIPT" --profile "$PROFILE" --request-id "$REQUEST" --actor-identity "not-an-email" --intercom-conv-id "$CONV"
  [ "$status" -eq 0 ]
  [ "$(jget .error)" = "invalid_actor_identity" ]
}

@test "OPS_DRY_RUN=1 trapdoor refuses" {
  OPS_DRY_RUN=1 run bash "$SCRIPT" --profile "$PROFILE" --request-id "$REQUEST" --actor-identity "$ACTOR" --intercom-conv-id "$CONV"
  [ "$status" -eq 0 ]
  [ "$(jget .error)" = "ops_dry_run_set" ]
}

@test "unwritable audit log fails closed" {
  CREDIT_VERIFY_AUDIT_LOG="/proc/cannot/write/here.jsonl" run bash "$SCRIPT" --profile "$PROFILE" --request-id "$REQUEST" --actor-identity "$ACTOR" --intercom-conv-id "$CONV"
  [ "$status" -eq 0 ]
  [ "$(jget .error)" = "audit_unwritable" ]
}

@test "missing requester fails closed" {
  MUSO_REQUESTER="" MUSO_ADMIN_EMAIL="" run bash "$SCRIPT" --profile "$PROFILE" --request-id "$REQUEST" --actor-identity "$ACTOR" --intercom-conv-id "$CONV"
  [ "$status" -eq 0 ]
  [ "$(jget .error)" = "no_requester" ]
}

@test "missing MUSO_CAPABILITY_APPROVER fails closed with no_approver" {
  MUSO_CAPABILITY_APPROVER="" run bash "$SCRIPT" --profile "$PROFILE" --request-id "$REQUEST" --actor-identity "$ACTOR" --intercom-conv-id "$CONV"
  [ "$status" -eq 0 ]
  [ "$(jget .error)" = "no_approver" ]
  grep -q '"status":"refused_no_approver"' "$CREDIT_VERIFY_AUDIT_LOG"
}

@test "dry-run surfaces muso's dryRunResult envelope and passes --dry-run" {
  # muso --dry-run --json emits the dryRunResult envelope, NOT a result struct.
  MUSO_STUB_STDOUT='{"dryRun":true,"method":"PUT","url":"https://x/admin/credit-requests","body":{"status":"approved"},"note":"credit request cr_abc123 will be approved"}' \
    run bash "$SCRIPT" --profile "$PROFILE" --request-id "$REQUEST" --actor-identity "$ACTOR" --intercom-conv-id "$CONV"
  [ "$status" -eq 0 ]
  [ "$(jget .ok)" = "true" ]
  [ "$(jget .mode)" = "dry-run" ]
  [ "$(jget .status)" = "dry_run" ]
  [ "$(jget .note)" = "credit request cr_abc123 will be approved" ]
  grep -q -- '--dry-run' "$MUSO_STUB_ARGV_FILE"
  grep -q '"status":"dry_run"' "$CREDIT_VERIFY_AUDIT_LOG"
}

@test "apply happy path returns applied and omits --dry-run" {
  MUSO_STUB_STDOUT='{"status":"applied","requestId":"cr_abc123","profileId":"11111111-1111-1111-1111-111111111111"}' \
    run bash "$SCRIPT" --profile "$PROFILE" --request-id "$REQUEST" --actor-identity "$ACTOR" --intercom-conv-id "$CONV" --apply
  [ "$status" -eq 0 ]
  [ "$(jget .ok)" = "true" ]
  [ "$(jget .mode)" = "apply" ]
  [ "$(jget .status)" = "applied" ]
  ! grep -q -- '--dry-run' "$MUSO_STUB_ARGV_FILE"
}

@test "muso argv carries the approval-tier flags (--yes --confirmed-by --approval-ref)" {
  MUSO_STUB_STDOUT='{"status":"applied"}' \
    run bash "$SCRIPT" --profile "$PROFILE" --request-id "$REQUEST" --actor-identity "$ACTOR" --intercom-conv-id "$CONV" --apply
  argv="$(cat "$MUSO_STUB_ARGV_FILE")"
  printf '%s' "$argv" | grep -qx 'credits'
  printf '%s' "$argv" | grep -qx 'verify'
  printf '%s' "$argv" | grep -qx -- '--actor-identity'
  printf '%s' "$argv" | grep -qx 'owner@example.com'
  printf '%s' "$argv" | grep -qx -- '--request-id'
  # APPROVAL-tier: the PUT requires these (creditsVerifyLong in muso-cli)
  printf '%s' "$argv" | grep -qx -- '--yes'
  printf '%s' "$argv" | grep -qx -- '--confirmed-by'
  printf '%s' "$argv" | grep -qx 'cap-approver'
  printf '%s' "$argv" | grep -qx -- '--approval-ref'
  printf '%s' "$argv" | grep -qx '98765'
}

@test "muso exit 5 maps to route_to_human" {
  MUSO_STUB_RC=5 MUSO_STUB_STDERR='refusing: request belongs to a different profile' \
    run bash "$SCRIPT" --profile "$PROFILE" --request-id "$REQUEST" --actor-identity "$ACTOR" --intercom-conv-id "$CONV" --apply
  [ "$status" -eq 0 ]
  [ "$(jget .ok)" = "false" ]
  [ "$(jget .error)" = "route_to_human" ]
  grep -q '"status":"refused_route_to_human"' "$CREDIT_VERIFY_AUDIT_LOG"
}

@test "muso non-zero (non-5) maps to muso_failed" {
  MUSO_STUB_RC=1 MUSO_STUB_STDERR='boom' \
    run bash "$SCRIPT" --profile "$PROFILE" --request-id "$REQUEST" --actor-identity "$ACTOR" --intercom-conv-id "$CONV" --apply
  [ "$status" -eq 0 ]
  [ "$(jget .ok)" = "false" ]
  [ "$(jget .error)" = "muso_failed" ]
  [ "$(jget .exit_code)" = "1" ]
}
