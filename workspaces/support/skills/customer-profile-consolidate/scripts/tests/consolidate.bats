#!/usr/bin/env bats
# Tests for consolidate.sh – the thin bash boundary in front of the APPROVAL-tier
# `muso profiles consolidate`. muso is PATH-stubbed to record argv and emit
# canned stdout/stderr + exit code, so no real binary or network is touched.

setup() {
  TEST_TMP="$(mktemp -d -t consolidate-bats.XXXXXX)"
  STUB_DIR="$TEST_TMP/bin"
  mkdir -p "$STUB_DIR"

  cat > "$STUB_DIR/muso" <<'STUBEOF'
#!/usr/bin/env bash
# Record argv (one token per line) so a test can assert the muso command line.
printf '%s\n' "$@" > "${MUSO_STUB_ARGV_FILE:-/dev/null}"
[[ -n "${MUSO_STUB_STDOUT:-}" ]] && printf '%s\n' "$MUSO_STUB_STDOUT"
[[ -n "${MUSO_STUB_STDERR:-}" ]] && printf '%s\n' "$MUSO_STUB_STDERR" >&2
exit "${MUSO_STUB_RC:-0}"
STUBEOF
  chmod +x "$STUB_DIR/muso"

  export PATH="$STUB_DIR:$PATH"
  export PROFILE_CONSOLIDATE_AUDIT_LOG="$TEST_TMP/audit.jsonl"
  export MUSO_STUB_ARGV_FILE="$TEST_TMP/argv.txt"
  export MUSO_REQUESTER="caroline@muso.ai"
  export MUSO_ADMIN_EMAIL="admin@muso.ai"
  export MUSO_CAPABILITY_APPROVER="ops-approver@muso.ai"
  unset OPS_DRY_RUN

  SCRIPT="$BATS_TEST_DIRNAME/../consolidate.sh"
  SURVIVOR="11111111-1111-1111-1111-111111111111"
  DUP1="22222222-2222-2222-2222-222222222222"
  DUP2="33333333-3333-3333-3333-333333333333"
  ACTOR="owner@example.com"
  CONV="98765"
}

teardown() { rm -rf "$TEST_TMP"; }

jget() { printf '%s' "$output" | jq -r "$1"; }

@test "syntax-checks via bash -n" {
  run bash -n "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "missing --into" {
  run bash "$SCRIPT" --from "$DUP1" --actor-identity "$ACTOR" --intercom-conv-id "$CONV"
  [ "$status" -eq 0 ]
  [ "$(jget .error)" = "missing_arg" ]
}

@test "missing --from" {
  run bash "$SCRIPT" --into "$SURVIVOR" --actor-identity "$ACTOR" --intercom-conv-id "$CONV"
  [ "$status" -eq 0 ]
  [ "$(jget .error)" = "missing_arg" ]
}

@test "missing --actor-identity" {
  run bash "$SCRIPT" --into "$SURVIVOR" --from "$DUP1" --intercom-conv-id "$CONV"
  [ "$status" -eq 0 ]
  [ "$(jget .error)" = "missing_arg" ]
}

@test "missing --intercom-conv-id (the approval-ref) refuses" {
  run bash "$SCRIPT" --into "$SURVIVOR" --from "$DUP1" --actor-identity "$ACTOR"
  [ "$status" -eq 0 ]
  [ "$(jget .error)" = "missing_arg" ]
}

@test "invalid survivor id refuses" {
  run bash "$SCRIPT" --into "not-a-uuid" --from "$DUP1" --actor-identity "$ACTOR" --intercom-conv-id "$CONV"
  [ "$status" -eq 0 ]
  [ "$(jget .error)" = "invalid_survivor_id" ]
}

@test "invalid dup id refuses" {
  run bash "$SCRIPT" --into "$SURVIVOR" --from "$DUP1" --from "not-a-uuid" --actor-identity "$ACTOR" --intercom-conv-id "$CONV"
  [ "$status" -eq 0 ]
  [ "$(jget .error)" = "invalid_dup_id" ]
}

@test "invalid actor email refuses" {
  run bash "$SCRIPT" --into "$SURVIVOR" --from "$DUP1" --actor-identity "not-an-email" --intercom-conv-id "$CONV"
  [ "$status" -eq 0 ]
  [ "$(jget .error)" = "invalid_actor_identity" ]
}

@test "OPS_DRY_RUN=1 trapdoor refuses" {
  OPS_DRY_RUN=1 run bash "$SCRIPT" --into "$SURVIVOR" --from "$DUP1" --actor-identity "$ACTOR" --intercom-conv-id "$CONV"
  [ "$status" -eq 0 ]
  [ "$(jget .error)" = "ops_dry_run_set" ]
}

@test "unwritable audit log fails closed" {
  PROFILE_CONSOLIDATE_AUDIT_LOG="/proc/cannot/write/here.jsonl" run bash "$SCRIPT" --into "$SURVIVOR" --from "$DUP1" --actor-identity "$ACTOR" --intercom-conv-id "$CONV"
  [ "$status" -eq 0 ]
  [ "$(jget .error)" = "audit_unwritable" ]
}

@test "missing requester fails closed" {
  unset MUSO_REQUESTER MUSO_ADMIN_EMAIL
  MUSO_REQUESTER="" MUSO_ADMIN_EMAIL="" run bash "$SCRIPT" --into "$SURVIVOR" --from "$DUP1" --actor-identity "$ACTOR" --intercom-conv-id "$CONV"
  [ "$status" -eq 0 ]
  [ "$(jget .error)" = "no_requester" ]
}

@test "missing MUSO_CAPABILITY_APPROVER fails closed with no_approver" {
  unset MUSO_CAPABILITY_APPROVER
  MUSO_CAPABILITY_APPROVER="" run bash "$SCRIPT" --into "$SURVIVOR" --from "$DUP1" --actor-identity "$ACTOR" --intercom-conv-id "$CONV"
  [ "$status" -eq 0 ]
  [ "$(jget .error)" = "no_approver" ]
  grep -q '"status":"refused_no_approver"' "$PROFILE_CONSOLIDATE_AUDIT_LOG"
}

@test "dry-run surfaces muso's dryRunResult envelope (note + body preview) and passes --dry-run" {
  # muso --dry-run --json emits the gate's dryRunResult envelope, NOT a result
  # struct – the wrapper reports status:dry_run + the note and body preview.
  MUSO_STUB_STDOUT='{"dryRun":true,"method":"POST","url":"https://x/admin/profiles/merge","body":{"mergeInto":"11111111-1111-1111-1111-111111111111","profilesIds":["22222222-2222-2222-2222-222222222222"]},"note":"22222222-2222-2222-2222-222222222222 will be folded INTO 11111111-1111-1111-1111-111111111111"}' \
    run bash "$SCRIPT" --into "$SURVIVOR" --from "$DUP1" --actor-identity "$ACTOR" --intercom-conv-id "$CONV"
  [ "$status" -eq 0 ]
  [ "$(jget .ok)" = "true" ]
  [ "$(jget .mode)" = "dry-run" ]
  [ "$(jget .status)" = "dry_run" ]
  [ "$(jget '.preview.mergeInto')" = "11111111-1111-1111-1111-111111111111" ]
  grep -q -- '--dry-run' "$MUSO_STUB_ARGV_FILE"
  grep -q '"status":"dry_run"' "$PROFILE_CONSOLIDATE_AUDIT_LOG"
}

@test "apply happy path returns applied and omits --dry-run" {
  MUSO_STUB_STDOUT='{"status":"applied","survivor":"11111111-1111-1111-1111-111111111111"}' \
    run bash "$SCRIPT" --into "$SURVIVOR" --from "$DUP1" --actor-identity "$ACTOR" --intercom-conv-id "$CONV" --apply
  [ "$status" -eq 0 ]
  [ "$(jget .ok)" = "true" ]
  [ "$(jget .mode)" = "apply" ]
  [ "$(jget .status)" = "applied" ]
  ! grep -q -- '--dry-run' "$MUSO_STUB_ARGV_FILE"
}

@test "muso argv carries approval-tier flags (--yes --confirmed-by --approval-ref) and repeated --from" {
  MUSO_STUB_STDOUT='{"status":"applied"}' \
    run bash "$SCRIPT" --into "$SURVIVOR" --from "$DUP1" --from "$DUP2" --actor-identity "$ACTOR" --intercom-conv-id "$CONV" --apply
  argv="$(cat "$MUSO_STUB_ARGV_FILE")"
  printf '%s' "$argv" | grep -qx 'profiles'
  printf '%s' "$argv" | grep -qx 'consolidate'
  printf '%s' "$argv" | grep -qx -- '--into'
  printf '%s' "$argv" | grep -qx '11111111-1111-1111-1111-111111111111'
  # both duplicates passed as repeated --from args
  printf '%s' "$argv" | grep -qx '22222222-2222-2222-2222-222222222222'
  printf '%s' "$argv" | grep -qx '33333333-3333-3333-3333-333333333333'
  [ "$(grep -cx -- '--from' "$MUSO_STUB_ARGV_FILE")" -eq 2 ]
  # approval-tier flags present
  printf '%s' "$argv" | grep -qx -- '--yes'
  printf '%s' "$argv" | grep -qx -- '--confirmed-by'
  printf '%s' "$argv" | grep -qx 'ops-approver@muso.ai'
  printf '%s' "$argv" | grep -qx -- '--approval-ref'
  printf '%s' "$argv" | grep -qx '98765'
}

@test "muso exit 5 maps to route_to_human" {
  MUSO_STUB_RC=5 MUSO_STUB_STDERR='refusing: survivor owned by a different workspace' \
    run bash "$SCRIPT" --into "$SURVIVOR" --from "$DUP1" --actor-identity "$ACTOR" --intercom-conv-id "$CONV" --apply
  [ "$status" -eq 0 ]
  [ "$(jget .ok)" = "false" ]
  [ "$(jget .error)" = "route_to_human" ]
  grep -q '"status":"refused_route_to_human"' "$PROFILE_CONSOLIDATE_AUDIT_LOG"
}

@test "muso non-zero (non-5) maps to muso_failed" {
  MUSO_STUB_RC=1 MUSO_STUB_STDERR='boom' \
    run bash "$SCRIPT" --into "$SURVIVOR" --from "$DUP1" --actor-identity "$ACTOR" --intercom-conv-id "$CONV" --apply
  [ "$status" -eq 0 ]
  [ "$(jget .ok)" = "false" ]
  [ "$(jget .error)" = "muso_failed" ]
  [ "$(jget .exit_code)" = "1" ]
}
