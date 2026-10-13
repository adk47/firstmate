#!/usr/bin/env bats
# Tests for scripts/lib/deletion-gate.sh — the inverted Step 4a deletion
# gate (MUS-1386, child 1 of MUS-1374). Today's guard only halts a pending
# `rsync --delete` when the deletion matches `workspaces/|skills-all/`;
# everything else (root-level money/customer artifacts included) takes the
# `else` branch in deploy.sh and is deleted with only a log line, no
# backup. The design inverts that default: ANY pending deletion halts.
# This suite exercises the seam function in isolation; the wiring into
# deploy.sh (MUS-1387, child 2) is covered by
# scripts/tests/deploy-preflight-deletion-wiring.bats.
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
LIB="$HYDRA_REPO/scripts/lib/deletion-gate.sh"

setup() {
  # shellcheck disable=SC1090
  source "$LIB"
}

@test "empty deletions blob: rc 0, no briefing" {
  run pending_deletion_briefing ""
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "root-level money artifact halts (rc 1) and names the path" {
  run pending_deletion_briefing "*deleting payout-report-2026-08.csv"
  [ "$status" -eq 1 ]
  [[ "$output" == *"payout-report-2026-08.csv"* ]]
}

@test "root-level customer artifact halts (rc 1) and names the path" {
  run pending_deletion_briefing "*deleting intercom-attachment-4821.png"
  [ "$status" -eq 1 ]
  [[ "$output" == *"intercom-attachment-4821.png"* ]]
}

@test "depth-3 never-tracked workspace file halts (rc 1) and names the path" {
  run pending_deletion_briefing "*deleting workspaces/ops/runtime.log"
  [ "$status" -eq 1 ]
  [[ "$output" == *"workspaces/ops/runtime.log"* ]]
}

@test "skills-all deletion still halts (rc 1) — no regression on the class that already halted" {
  run pending_deletion_briefing "*deleting skills-all/foo/SKILL.md"
  [ "$status" -eq 1 ]
  [[ "$output" == *"skills-all/foo/SKILL.md"* ]]
}

@test "halting briefing carries all four remedy strings" {
  run pending_deletion_briefing "*deleting payout-report-2026-08.csv"
  [ "$status" -eq 1 ]

  # (a) the literal --exclude= line to paste into RSYNC_EXCLUDES, built
  # from the offending path.
  [[ "$output" == *"--exclude=/payout-report-2026-08.csv"* ]]

  # (b) the matching .githooks/pre-commit required_excludes entry.
  [[ "$output" == *'"/payout-report-2026-08.csv"'* ]]

  # (c) no remedy may point at a root scratch/ directory: RSYNC_EXCLUDES has
  # no such entry, so following it re-halts the next deploy.
  [[ "$output" != *"scratch/"* ]]

  # (d) the scripts/sync-from-server.sh pull command.
  [[ "$output" == *"scripts/sync-from-server.sh"* ]]
}

@test "remedy (a) does not offer sync-from-server.sh for a never-tracked path; by-hand capture is given" {
  run pending_deletion_briefing $'*deleting workspaces/ops/runtime.log\n*deleting payout-report.csv'
  [ "$status" -eq 1 ]
  # sync-from-server.sh pulls git-TRACKED files only (validate_only_paths exits 1
  # on an untracked --only path; audit/ is NEVER_PULL). A pending deletion is
  # untracked by construction, so no remedy line may present it as the pull.
  local line
  while IFS= read -r line; do
    [[ "$line" == *"scripts/sync-from-server.sh"* ]] || continue
    # no bare bulk pull of a target (the 125 GB / clobber hazard)
    if [[ "$line" == *"--apply"* && "$line" != *"--only"* && "$line" != *"audit --apply"* ]]; then
      echo "bulk-pull remedy: $line"; return 1
    fi
  done <<< "$output"
  # the briefing says plainly that a never-tracked path is NOT pulled by the script
  [[ "$output" == *"NOT pulled by it"* ]]
  # and gives the by-hand capture: scp, review for secrets, git add <path>
  [[ "$output" == *"scp -i"* ]]
  [[ "$output" == *"no secrets/tokens"* ]]
  [[ "$output" == *"git add <path>"* ]]
  # --only is named only as the already-tracked-file case
  [[ "$output" == *"already-tracked file only"* ]]
  [[ "$output" == *"NEVER bulk-pull"* ]]
}
