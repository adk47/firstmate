#!/usr/bin/env bats
# RETIRED: the patch itself is a no-op stub (upstream #95831 ships the fix in
# openclaw 2026.8.1's dist; deploy.sh/post-openclaw-update.sh no longer call
# it). This lone test asserts the stub's retirement contract instead of the
# now-deleted backport logic. Delete alongside the stub in the post-window
# cleanup PR (see docs/runbooks/UPGRADE-2026.8.1.md).
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
PATCHER="$HYDRA_REPO/scripts/patch-openclaw-codex-native-compaction.sh"

@test "retired stub exits 0 and prints RETIRED, touching nothing" {
  run "$PATCHER"
  [ "$status" -eq 0 ]
  [[ "$output" == *RETIRED* ]]
}
