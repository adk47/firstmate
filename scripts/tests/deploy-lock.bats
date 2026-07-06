#!/usr/bin/env bats
# Regression tests for scripts/lib/deploy-lock.sh — the per-host deploy lock
# with stale-PID recovery.
#
# The bug this guards against (incident 2026-07-01): the inline version in
# deploy.sh did `mkdir_err=$(mkdir "$LOCK_DIR" 2>&1); mkdir_rc=$?`, and under
# `set -euo pipefail` the failing assignment (EEXIST when a lock dir already
# exists) tripped `set -e` and exited BEFORE the stale-PID recovery could run —
# so one orphaned lock wedged every deploy for ~18h. The
# "does not abort under set -e" test below is the precise guard.

setup() {
  TEST_ROOT="$(mktemp -d)"
  LOCK="$TEST_ROOT/deploy.lock.d"
  LIB="${BATS_TEST_DIRNAME}/../lib/deploy-lock.sh"
  # shellcheck source=../lib/deploy-lock.sh
  source "$LIB"
}
teardown() { rm -rf "$TEST_ROOT"; }

# Write a reliably-dead PID into the lock's pid file (spawn + reap).
seed_stale_lock() {
  mkdir -p "$LOCK"
  local dead
  sleep 0 & dead=$!
  wait "$dead" 2>/dev/null || true
  echo "$dead" > "$LOCK/pid"
}

@test "fresh acquire on a new dir succeeds and writes our pid" {
  run acquire_deploy_lock "$LOCK"
  [ "$status" -eq 0 ]
  [ -f "$LOCK/pid" ]
  [ "$(cat "$LOCK/pid")" = "$$" ]
}

@test "acquire does NOT abort under set -e when a stale lock exists (the regression)" {
  seed_stale_lock
  # Run the acquire in a real `set -euo pipefail` shell. With the old inline
  # code this exited at the mkdir before recovery, so COMPLETED never printed.
  run bash -c "set -euo pipefail; source '$LIB'; acquire_deploy_lock '$LOCK'; echo COMPLETED rc=\$?"
  [ "$status" -eq 0 ]
  [[ "$output" == *"stale deploy lock found"* ]]
  [[ "$output" == *"COMPLETED rc=0"* ]]
}

@test "stale lock (dead holder pid) is recovered, not refused" {
  seed_stale_lock
  run acquire_deploy_lock "$LOCK"
  [ "$status" -eq 0 ]
  [[ "$output" == *"stale deploy lock found"* ]]
  [[ "$output" == *"clearing"* ]]
  [ "$(cat "$LOCK/pid")" = "$$" ]
}

@test "corrupt / non-numeric pid is treated as dead and recovered" {
  mkdir -p "$LOCK"
  echo "not-a-pid" > "$LOCK/pid"
  run acquire_deploy_lock "$LOCK"
  [ "$status" -eq 0 ]
  [[ "$output" == *"stale deploy lock found"* ]]
}

@test "live holder pid is refused (rc 2), lock untouched" {
  mkdir -p "$LOCK"
  echo "$$" > "$LOCK/pid"   # our own pid — definitely alive
  run acquire_deploy_lock "$LOCK"
  [ "$status" -eq 2 ]
  [[ "$output" == *"another deploy is already running"* ]]
  [ "$(cat "$LOCK/pid")" = "$$" ]   # not overwritten
}

@test "lock dir with no pid file is refused (rc 4), not cleared" {
  mkdir -p "$LOCK"   # no pid file
  run acquire_deploy_lock "$LOCK"
  [ "$status" -eq 4 ]
  [[ "$output" == *"no pid file"* ]]
  [ -d "$LOCK" ]     # must NOT have been removed
}

@test "release removes the lock dir and is idempotent" {
  mkdir -p "$LOCK"; echo "$$" > "$LOCK/pid"
  release_deploy_lock "$LOCK"
  [ ! -d "$LOCK" ]
  run release_deploy_lock "$LOCK"   # second call: no error
  [ "$status" -eq 0 ]
}
