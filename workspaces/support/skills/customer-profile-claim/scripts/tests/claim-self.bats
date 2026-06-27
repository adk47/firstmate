#!/usr/bin/env bats
# Tests for claim-self.sh – the thin bash boundary in front of
# `muso profiles claim-self`. muso is PATH-stubbed to emit canned stdout/stderr
# and a canned exit code, so no real binary or network is touched.

setup() {
  TEST_TMP="$(mktemp -d -t claimself-bats.XXXXXX)"
  STUB_DIR="$TEST_TMP/bin"
  mkdir -p "$STUB_DIR"

  cat > "$STUB_DIR/muso" <<'STUBEOF'
#!/usr/bin/env bash
[[ -n "${MUSO_STUB_STDOUT:-}" ]] && printf '%s\n' "$MUSO_STUB_STDOUT"
[[ -n "${MUSO_STUB_STDERR:-}" ]] && printf '%s\n' "$MUSO_STUB_STDERR" >&2
exit "${MUSO_STUB_RC:-0}"
STUBEOF
  chmod +x "$STUB_DIR/muso"

  export PATH="$STUB_DIR:$PATH"
  export PROFILE_CLAIM_AUDIT_LOG="$TEST_TMP/audit.jsonl"
  export MUSO_REQUESTER="caroline@muso.ai"
  export MUSO_ADMIN_EMAIL="admin@muso.ai"
  unset OPS_DRY_RUN

  SCRIPT="$BATS_TEST_DIRNAME/../claim-self.sh"
  CLAIM_ID="clm_abc123"
  ACTOR="owner@example.com"
  CONV="98765"
}

teardown() { rm -rf "$TEST_TMP"; }

jget() { printf '%s' "$output" | jq -r "$1"; }

@test "syntax-checks via bash -n" {
  run bash -n "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "missing --claim-id" {
  run bash "$SCRIPT" --actor-identity "$ACTOR"
  [ "$status" -eq 0 ]
  [ "$(jget .error)" = "missing_arg" ]
}

@test "missing --actor-identity" {
  run bash "$SCRIPT" --claim-id "$CLAIM_ID"
  [ "$status" -eq 0 ]
  [ "$(jget .error)" = "missing_arg" ]
}

@test "invalid actor email refuses" {
  run bash "$SCRIPT" --claim-id "$CLAIM_ID" --actor-identity "not-an-email"
  [ "$status" -eq 0 ]
  [ "$(jget .error)" = "invalid_actor_identity" ]
}

@test "invalid claim id refuses" {
  run bash "$SCRIPT" --claim-id "bad id with spaces" --actor-identity "$ACTOR"
  [ "$status" -eq 0 ]
  [ "$(jget .error)" = "invalid_claim_id" ]
}

@test "OPS_DRY_RUN=1 trapdoor refuses" {
  OPS_DRY_RUN=1 run bash "$SCRIPT" --claim-id "$CLAIM_ID" --actor-identity "$ACTOR"
  [ "$status" -eq 0 ]
  [ "$(jget .error)" = "ops_dry_run_set" ]
}

@test "unwritable audit log fails closed" {
  PROFILE_CLAIM_AUDIT_LOG="/proc/cannot/write/here.jsonl" run bash "$SCRIPT" --claim-id "$CLAIM_ID" --actor-identity "$ACTOR"
  [ "$status" -eq 0 ]
  [ "$(jget .error)" = "audit_unwritable" ]
}

@test "missing requester fails closed" {
  unset MUSO_REQUESTER MUSO_ADMIN_EMAIL
  MUSO_REQUESTER="" MUSO_ADMIN_EMAIL="" run bash "$SCRIPT" --claim-id "$CLAIM_ID" --actor-identity "$ACTOR"
  [ "$status" -eq 0 ]
  [ "$(jget .error)" = "no_requester" ]
}

@test "dry-run surfaces muso's dryRunResult envelope (note + body preview)" {
  # muso --dry-run --json emits the gate's dryRunResult envelope, NOT a result
  # struct – the wrapper must report status:dry_run + the note/body preview.
  MUSO_STUB_STDOUT='{"dryRun":true,"method":"POST","url":"https://x/admin/claiming/clm_abc123/verify","body":{},"note":"claim clm_abc123 will be verified"}' \
    run bash "$SCRIPT" --claim-id "$CLAIM_ID" --actor-identity "$ACTOR" --intercom-conv-id "$CONV"
  [ "$status" -eq 0 ]
  [ "$(jget .ok)" = "true" ]
  [ "$(jget .mode)" = "dry-run" ]
  [ "$(jget .status)" = "dry_run" ]
  [ "$(jget .note)" = "claim clm_abc123 will be verified" ]
  grep -q '"status":"dry_run"' "$PROFILE_CLAIM_AUDIT_LOG"
}

@test "apply happy path returns applied" {
  MUSO_STUB_STDOUT='{"status":"applied","claimId":"clm_abc123","profileId":"p-1"}' \
    run bash "$SCRIPT" --claim-id "$CLAIM_ID" --actor-identity "$ACTOR" --intercom-conv-id "$CONV" --apply
  [ "$status" -eq 0 ]
  [ "$(jget .ok)" = "true" ]
  [ "$(jget .mode)" = "apply" ]
  [ "$(jget .status)" = "applied" ]
}

@test "muso exit 5 maps to route_to_human" {
  MUSO_STUB_RC=5 MUSO_STUB_STDERR='refusing: claim belongs to a different workspace' \
    run bash "$SCRIPT" --claim-id "$CLAIM_ID" --actor-identity "$ACTOR" --apply
  [ "$status" -eq 0 ]
  [ "$(jget .ok)" = "false" ]
  [ "$(jget .error)" = "route_to_human" ]
  grep -q '"status":"refused_route_to_human"' "$PROFILE_CLAIM_AUDIT_LOG"
}

@test "muso non-zero (non-5) maps to muso_failed" {
  MUSO_STUB_RC=1 MUSO_STUB_STDERR='boom' \
    run bash "$SCRIPT" --claim-id "$CLAIM_ID" --actor-identity "$ACTOR" --apply
  [ "$status" -eq 0 ]
  [ "$(jget .ok)" = "false" ]
  [ "$(jget .error)" = "muso_failed" ]
  [ "$(jget .exit_code)" = "1" ]
}
