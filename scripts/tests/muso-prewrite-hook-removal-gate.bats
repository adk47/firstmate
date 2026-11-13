#!/usr/bin/env bats
# muso-prewrite-hook.sh removal gate (2026-11-04).
#
# The hook is the ONE surface every `muso` CLI write passes through (wired as
# prewrite_hook in /root/.config/muso/config.json, rendered by deploy.sh). On
# 2026-11-04 the operations bot ran `muso ... api DELETE /admin/profile/<id>` 21
# times in 14 days off Jan's word — the workspace skill that told it to had never
# been reviewed as policy, and the hook let every one through. That endpoint
# tombstones the profile AND every served credit on it (Gene Flores: 431 served
# credits -> 0); there is no inverse and legal hold 1350 means the data is never
# destroyed.
#
# So the hook refuses, exactly like muso-admin-api.sh's removal gate
# (MUSO_REMOVAL_NO_SELF_APPROVE), and says the profile hide request belongs on the
# GDPR register for identity verification and a person-approved takedown.
#
# The hook has no env knobs by design, so tests run a COPY whose hardcoded state
# path points into the test dir, next to a healthy codex-health stub.
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
REAL_HOOK="$HYDRA_REPO/scripts/muso-prewrite-hook.sh"

setup() {
  TEST_TMPDIR="$(mktemp -d)"
  mkdir -p "$TEST_TMPDIR/scripts/lib"
  sed "s#^CLAIM_VERIFY_LAST=.*#CLAIM_VERIFY_LAST=\"$TEST_TMPDIR/claim-verify.last\"#" "$REAL_HOOK" > "$TEST_TMPDIR/scripts/muso-prewrite-hook.sh"
  chmod +x "$TEST_TMPDIR/scripts/muso-prewrite-hook.sh"
  printf '%s\n' 'codex_health_gate() { return 0; }' > "$TEST_TMPDIR/scripts/lib/codex-health.sh"
  HOOK="$TEST_TMPDIR/scripts/muso-prewrite-hook.sh"
  unset MUSO_HOOK_PROVIDER
}

teardown() { rm -rf "$TEST_TMPDIR"; }

@test "a profile DELETE is refused with the removal wording and names the hide path" {
  run --separate-stderr "$HOOK" DELETE /admin/profile/0d898512-1111-2222-3333-444455556666 prod
  [ "$status" -eq 3 ]
  [[ "$stderr" == *"MUSO_REMOVAL_NO_SELF_APPROVE"* ]]
  [[ "$stderr" == *"Profile hides are not available to the agent"* ]]
  [[ "$stderr" == *"GDPR register"* ]]
}

@test "the refusal holds for lowercase methods, trailing slashes and query strings" {
  for p in /admin/profile/p1 /admin/profile/p1/ '/admin/profile/p1?force=true'; do
    run --separate-stderr "$HOOK" DELETE "$p" prod
    [ "$status" -eq 3 ]
    [[ "$stderr" == *"MUSO_REMOVAL_NO_SELF_APPROVE"* ]]
  done
  run --separate-stderr "$HOOK" delete /admin/profile/p1 prod
  [ "$status" -eq 3 ]
}

@test "case, repeated-slash and dot-segment spellings cannot evade the gate" {
  for p in /ADMIN/profile/p1 /Admin/Profile/p1 /admin/profile/p1// /admin//profile//p1 \
           /admin/profile/./p1 /admin/profile/x/../p1 /api/v3/ADMIN/profile/./p1; do
    run --separate-stderr "$HOOK" DELETE "$p" prod
    [ "$status" -eq 3 ]
    [[ "$stderr" == *"MUSO_REMOVAL_NO_SELF_APPROVE"* ]]
  done
  run "$HOOK" DELETE /ADMIN/profile/p1/cache prod
  [ "$status" -eq 0 ]
}

@test "a version-prefixed path cannot evade the gate" {
  for p in /api/v3/admin/profile/p1 /api/v3/admin/track/t1 /api/v3/admin/track/t1/profile/p1/credits; do
    run --separate-stderr "$HOOK" DELETE "$p" prod
    [ "$status" -eq 3 ]
    [[ "$stderr" == *"MUSO_REMOVAL_NO_SELF_APPROVE"* ]]
  done
  run "$HOOK" DELETE /api/v3/admin/profile/p1/cache prod
  [ "$status" -eq 0 ]
}

@test "the track and credit removal routes are refused by the same gate (no regression)" {
  run --separate-stderr "$HOOK" DELETE /admin/track/t1 prod
  [ "$status" -eq 3 ]
  [[ "$stderr" == *"MUSO_REMOVAL_NO_SELF_APPROVE"* ]]
  run --separate-stderr "$HOOK" DELETE /admin/track/t1/profile/p1/credits prod
  [ "$status" -eq 3 ]
  [[ "$stderr" == *"MUSO_REMOVAL_NO_SELF_APPROVE"* ]]
}

@test "the profile CACHE purge still passes (the hide read-back needs it)" {
  run "$HOOK" DELETE /admin/profile/p1/cache prod
  [ "$status" -eq 0 ]
}

@test "the credits and member sub-resources are not the soft-delete" {
  run "$HOOK" DELETE /admin/profile/p1/credits prod
  [ "$status" -eq 0 ]
  run "$HOOK" DELETE /admin/profile/p1/member prod
  [ "$status" -eq 0 ]
}

@test "reads and other writes are untouched" {
  run "$HOOK" GET /admin/profile/p1 prod
  [ "$status" -eq 0 ]
  run "$HOOK" POST /admin/profiles/merge prod
  [ "$status" -eq 0 ]
}

@test "the removal gate runs BEFORE the slack-provider exemption (a removal is never exempt)" {
  MUSO_HOOK_PROVIDER=slack run --separate-stderr "$HOOK" DELETE /admin/profile/p1 prod
  [ "$status" -eq 3 ]
  [[ "$stderr" == *"MUSO_REMOVAL_NO_SELF_APPROVE"* ]]
}

@test "the removal gate runs BEFORE the codex-health gate (a degraded model cannot be the excuse)" {
  printf '%s\n' 'codex_health_gate() { return 1; }' > "$TEST_TMPDIR/scripts/lib/codex-health.sh"
  run --separate-stderr "$HOOK" DELETE /admin/profile/p1 prod
  [ "$status" -eq 3 ]
  [[ "$stderr" == *"MUSO_REMOVAL_NO_SELF_APPROVE"* ]]
  [[ "$stderr" != *"codex health"* ]]
}
