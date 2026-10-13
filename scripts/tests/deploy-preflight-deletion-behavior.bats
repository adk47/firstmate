#!/usr/bin/env bats
# Behavioural proof for deploy.sh preflight_drift_check() Step 4a (MUS-6123).
# deploy.sh runs preflight_drift_check at source time, so it cannot be sourced;
# this suite carves the function out of deploy.sh, and runs it against a real
# `rsync -rcn --delete` between two temp dirs (HYDRA_LOCAL=true path), with a
# synthetic git repo as HYDRA_ROOT so the real classify-deletions.sh runs.
#
# The money case: a root-level payout-report.csv on the server and not in the
# repo used to hit the log-and-continue branch and be deleted with no backup.
bats_require_minimum_version 1.5.0
HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"

setup() {
  TMP="$(mktemp -d)"
  REPO="$TMP/repo"; SRV="$TMP/srv"
  mkdir -p "$REPO/workspaces/ops" "$SRV"
  git -C "$REPO" init -q
  git -C "$REPO" config user.email t@t; git -C "$REPO" config user.name t
  echo soul > "$REPO/workspaces/ops/SOUL.md"
  git -C "$REPO" add -A; git -C "$REPO" commit -qm seed
  cp -R "$REPO/workspaces" "$SRV/workspaces"
  # carve the function out of deploy.sh
  awk '/^preflight_drift_check\(\) \{/{p=1} p{print} p&&/^\}$/{exit}' \
    "$HYDRA_REPO/scripts/deploy.sh" > "$TMP/fn.sh"
  [ -s "$TMP/fn.sh" ]
  cat > "$TMP/run.sh" <<RUN
set -uo pipefail
SCRIPT_DIR="$HYDRA_REPO/scripts"
HYDRA_ROOT="$REPO"; DEPLOY_PATH="$SRV"; HYDRA_LOCAL=true
RSYNC_EXCLUDES=(--exclude=.git)
log() { echo "LOG: \$*"; }
fail() { echo "FAIL: \$*"; exit 1; }
source "$TMP/fn.sh"
preflight_drift_check
echo "REACHED-CLEAN"
RUN
}
teardown() { rm -rf "$TMP"; }

@test "root-level payout-report.csv only on server HALTS pre-flight" {
  echo "payout" > "$SRV/payout-report.csv"
  run bash "$TMP/run.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"payout-report.csv"* ]]
  [[ "$output" == *"refusing to delete server state"* ]]
  [[ "$output" != *"REACHED-CLEAN"* ]]
}

@test "HYDRA_FORCE=1 is the only override for a root-level deletion" {
  echo "payout" > "$SRV/payout-report.csv"
  HYDRA_FORCE=1 run bash "$TMP/run.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"REACHED-CLEAN"* ]]
}

@test "never-tracked workspaces/<ws>/<dir>/ is still auto-excluded and does NOT halt" {
  mkdir -p "$SRV/workspaces/ops/clients"
  echo x > "$SRV/workspaces/ops/clients/a.txt"
  run bash "$TMP/run.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Auto-excluding"* ]]
  [[ "$output" == *"REACHED-CLEAN"* ]]
}

@test "auto-excluded workspace churn does not mask a root-level deletion beside it" {
  mkdir -p "$SRV/workspaces/ops/clients"; echo x > "$SRV/workspaces/ops/clients/a.txt"
  echo "payout" > "$SRV/payout-report.csv"
  run bash "$TMP/run.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"payout-report.csv"* ]]
  [[ "$output" != *"  workspaces/ops/clients"* ]]
}

@test "clean tree reaches Pre-flight clean" {
  run bash "$TMP/run.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Pre-flight clean."* ]]
}
