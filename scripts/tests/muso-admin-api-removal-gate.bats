#!/usr/bin/env bats
# Removal gate in muso-admin-api.sh (both live copies).
#
# The gate refuses the three removal routes (whole-track tombstone, a credit
# removed from a profile, the profile soft-delete) whatever the requester or the
# approval flags. It matches the PATH, and the path is concatenated straight into
# the request URL, so any spelling that reaches the same route but slips the
# match is a live bypass: curl resolves dot-segments and Express routes
# case-insensitively, so /ADMIN/profile/<id>, /admin/profile/./<id>,
# /admin/profile/x/../<id> and /admin/profile/<id>// all hit the soft-delete
# handler. These cases pin the canonical spellings AND the evasions, and pin that
# the sub-resources that are NOT the soft-delete still pass.
bats_require_minimum_version 1.5.0

REPO_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"

setup() {
  export MUSO_OPS_STATE_DIR="$BATS_TEST_TMPDIR/state"
  export OPS_RUNLOG_DIR="$BATS_TEST_TMPDIR/runlogs"
  mkdir -p "$OPS_RUNLOG_DIR"
  export MUSO_API_URL="http://127.0.0.1:0/none"
  export MUSO_ADMIN_EMAIL="test@example.com"
  export MUSO_ADMIN_PASSWORD="x"
  unset OPS_DRY_RUN
}

# for_each_copy FN ARGS... — run FN against the canonical copy, then the
# workspace copy (the operations agent executes that one). Each copy gets its own
# subshell: sourcing a copy turns on its set -euo pipefail, and a negative case
# (FN returning 1) would otherwise abort the loop before the second copy ran.
for_each_copy() {
  local rel st rc=0
  for rel in "skills-all/muso-ops-admin/scripts/muso-admin-api.sh" \
             "workspaces/operations/skills/muso-ops-admin/scripts/muso-admin-api.sh"; do
    st=0
    # shellcheck disable=SC1090
    ( source "$REPO_ROOT/$rel"; "$@" ) || st=$?
    [[ "$st" -eq 0 ]] || rc="$st"
  done
  return "$rc"
}

@test "for_each_copy visits both live copies, including on a failing case" {
  local marker="$BATS_TEST_TMPDIR/visited"
  : > "$marker"
  visit_copy() { printf '%s\n' x >> "$marker"; return 1; }
  run for_each_copy visit_copy
  [ "$status" -eq 1 ]
  [ "$(wc -l < "$marker")" -eq 2 ]
}

@test "the canonical soft-delete spelling is a removal" {
  run for_each_copy is_removal_endpoint DELETE /admin/profile/p1
  [ "$status" -eq 0 ]
}

@test "an upper-cased path is still the soft-delete (Express routes case-insensitively)" {
  run for_each_copy is_removal_endpoint DELETE /ADMIN/profile/p1
  [ "$status" -eq 0 ]
  run for_each_copy is_removal_endpoint DELETE /Admin/Profile/p1
  [ "$status" -eq 0 ]
}

@test "repeated slashes and dot-segments are still the soft-delete" {
  run for_each_copy is_removal_endpoint DELETE /admin/profile/p1//
  [ "$status" -eq 0 ]
  run for_each_copy is_removal_endpoint DELETE /admin//profile//p1
  [ "$status" -eq 0 ]
  run for_each_copy is_removal_endpoint DELETE /admin/profile/./p1
  [ "$status" -eq 0 ]
  run for_each_copy is_removal_endpoint DELETE /admin/profile/x/../p1
  [ "$status" -eq 0 ]
  run for_each_copy is_removal_endpoint DELETE /admin/profile/p1/
  [ "$status" -eq 0 ]
}

@test "the track and credit removal routes are removals in every spelling" {
  run for_each_copy is_removal_endpoint DELETE /admin/track/t1
  [ "$status" -eq 0 ]
  run for_each_copy is_removal_endpoint DELETE /ADMIN/track/t1
  [ "$status" -eq 0 ]
  run for_each_copy is_removal_endpoint DELETE /admin/track/t1/profile/p1/credits
  [ "$status" -eq 0 ]
  run for_each_copy is_removal_endpoint DELETE /admin/track/./t1/profile/p1/credits
  [ "$status" -eq 0 ]
}

@test "the cache purge and the credits/member sub-resources are NOT the soft-delete" {
  run for_each_copy is_removal_endpoint DELETE /admin/profile/p1/cache
  [ "$status" -eq 1 ]
  run for_each_copy is_removal_endpoint DELETE /admin/profile/p1/credits
  [ "$status" -eq 1 ]
  run for_each_copy is_removal_endpoint DELETE /admin/profile/p1/member
  [ "$status" -eq 1 ]
}

@test "the configured base path is part of the route the request lands on" {
  export MUSO_API_URL="https://api.muso.ai/api/v3"
  run for_each_copy is_removal_endpoint DELETE /admin/profile/p1
  [ "$status" -eq 0 ]
  run for_each_copy is_removal_endpoint DELETE /api/v3/admin/profile/p1
  [ "$status" -eq 0 ]
  # cmd_call sends "${MUSO_API_URL}${path}"; curl resolves the dot segments, so
  # this spelling reaches the live soft-delete handler.
  run for_each_copy is_removal_endpoint DELETE /../../api/v3/admin/profile/p1
  [ "$status" -eq 0 ]
  run for_each_copy is_removal_endpoint DELETE /../../api/v3/admin/track/t1
  [ "$status" -eq 0 ]
  run for_each_copy is_removal_endpoint DELETE /../../api/v3/admin/track/t1/profile/p1/credits
  [ "$status" -eq 0 ]
  run for_each_copy is_removal_endpoint DELETE /admin/profile/p1/cache
  [ "$status" -eq 1 ]
  run for_each_copy is_removal_endpoint DELETE /admin/profiles/merge
  [ "$status" -eq 1 ]
  run for_each_copy is_removal_endpoint DELETE /admin/profile-x
  [ "$status" -eq 1 ]
}

@test "reads and other methods are not removals" {
  run for_each_copy is_removal_endpoint GET /admin/profile/p1
  [ "$status" -eq 1 ]
  run for_each_copy is_removal_endpoint POST /admin/profile/p1
  [ "$status" -eq 1 ]
  run for_each_copy is_removal_endpoint PATCH /admin/profile/p1
  [ "$status" -eq 1 ]
}

@test "enforce_removal_gate refuses an evasive spelling with the removal wording" {
  run --separate-stderr for_each_copy enforce_removal_gate DELETE /ADMIN/profile/p1
  [ "$status" -ne 0 ]
  [[ "$stderr" == *"MUSO_REMOVAL_NO_SELF_APPROVE"* ]]
  run --separate-stderr for_each_copy enforce_removal_gate DELETE /admin/profile/./p1
  [ "$status" -ne 0 ]
  [[ "$stderr" == *"MUSO_REMOVAL_NO_SELF_APPROVE"* ]]
}

@test "enforce_removal_gate lets the cache purge through" {
  run for_each_copy enforce_removal_gate DELETE /admin/profile/p1/cache
  [ "$status" -eq 0 ]
}
