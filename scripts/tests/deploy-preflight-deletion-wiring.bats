#!/usr/bin/env bats
# scripts/deploy.sh preflight_drift_check(): Step 4a's deletion block used to
# take a lenient path for any deletion NOT under workspaces/|skills-all/ --
# logging "sync will delete N file(s)" and letting the deploy proceed with no
# backup (root-level money/customer artifacts included -- see the 28 Sep
# strays documented in scripts/lib/deletion-gate.sh). MUS-1387 (MUS-1374
# child 2) removes that lenient branch entirely: every remaining deletion
# (already post-classifier) routes through scripts/lib/deletion-gate.sh's
# pending_deletion_briefing(), which halts unless HYDRA_FORCE=1.
#
# This suite asserts on the static shape of deploy.sh, the same style as
# deploy-plugin-install-flags.bats. The behavior is exercised for real in
# deploy-preflight-deletion-behavior.bats, which carves the function out of
# deploy.sh and runs it against a real rsync.
bats_require_minimum_version 1.5.0
HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
DEPLOY_SH="$HYDRA_REPO/scripts/deploy.sh"

@test "deploy.sh sources the deletion-gate lib" {
  grep -qF 'source "$SCRIPT_DIR/lib/deletion-gate.sh"' "$DEPLOY_SH"
}

@test "deploy.sh no longer classifies deletions by a workspaces/skills-all grep" {
  n=$(grep -cE "grep -E 'workspaces/\|skills-all/'" "$DEPLOY_SH" || true)
  [ "$n" -eq 0 ]
}

@test "deploy.sh has no log-and-continue branch for non-suspicious deletions" {
  n=$(grep -c 'sync will delete' "$DEPLOY_SH" || true)
  [ "$n" -eq 0 ]
}

@test "deploy.sh routes every remaining deletion through pending_deletion_briefing" {
  grep -qF 'pending_deletion_briefing "$deletions"' "$DEPLOY_SH"
}

# The call alone is not the contract: the gate returns 1 to mean "halt", so
# deploy.sh must branch on the NEGATED status. Dropping the `!` leaves the
# call in place, keeps every grep above green, and silently restores the
# log-and-continue bug this card exists to remove.
@test "deploy.sh acts on the gate's refusal, not merely calls it" {
  grep -qF 'if ! briefing=$(pending_deletion_briefing "$deletions")' "$DEPLOY_SH"
}

# `fail` is what aborts the deploy; `log` with the same words would read
# identically in the transcript and delete the files anyway. Assert the verb.
@test "deploy.sh keeps the HYDRA_FORCE override on a halted deletion" {
  n=$(grep -c 'fail "refusing to delete server state (override: HYDRA_FORCE=1)"' "$DEPLOY_SH")
  [ "$n" -eq 1 ]
}
