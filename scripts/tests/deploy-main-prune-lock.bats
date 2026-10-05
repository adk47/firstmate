#!/usr/bin/env bats
# deploy.sh takes the main prune/restart lock before its first node-8 mutation (MUS-3742, MUS-3814). It cannot
# be executed here, so this lifts its REAL lock block (deploy-marker-takeover.bats pattern) and runs it against
# the real lib, plus static ordering assertions (deploy-muso-pin-ordering.bats pattern).
DEPLOY="${BATS_TEST_DIRNAME}/../deploy.sh"
LIB="${BATS_TEST_DIRNAME}/../lib/main-prune-lock.sh"

setup() {
  TEST_TMPDIR="$(mktemp -d)"; export TEST_TMPDIR
  export MAIN_PRUNE_LOCK_FILE="$TEST_TMPDIR/lock"
  {
    echo 'log() { echo "$*"; }'
    echo 'fail() { echo "FATAL: $*"; exit 1; }'
    echo "source '$LIB'"
    echo 'HYDRA_LOCAL=${HYDRA_LOCAL:-true}'
    awk '/^# Serialise with scripts\/main-prune-restart.sh BEFORE the first node-8 mutation/ { on = 1 }
         /^log "Claiming the mutation marker/ { on = 0 }
         on' "$DEPLOY"
    echo 'echo REACHED-MARKER-CLAIM'
  } > "$TEST_TMPDIR/block.sh"
  grep -q 'acquire_main_prune_lock' "$TEST_TMPDIR/block.sh"
}
# One process holds the lock (exec): kill $! releases it and leaves no orphan holding bats' fds.
_hold_lock() { bash -c 'exec 8>"$1"; flock -n 8 && exec sleep "$2"' _ "$1" "$2" >/dev/null 2>&1 3>&- & }

teardown() { rm -rf "$TEST_TMPDIR"; }

line_of() {
  local n; n=$(grep -nE "$1" "$DEPLOY" | head -1 | cut -d: -f1)
  [ -n "$n" ] || { echo "anchor not found in deploy.sh: $1" >&2; return 1; }
  echo "$n"
}

@test "the lock is taken BEFORE the mutation marker is claimed and before any sync" {
  lock=$(line_of '^  acquire_main_prune_lock \|\| lock_rc=\$\?')
  claim=$(line_of '^  claim_mutation_marker "\$DEPLOY_PATH/.deploy-mutating"')
  rsync_step=$(line_of 'Step 4b/8: (Local sync|Remote sync)')
  [ "$lock" -lt "$claim" ]
  [ "$lock" -lt "$rsync_step" ]
}

@test "free lock: the block passes and the deploy reaches the marker claim" {
  run bash "$TEST_TMPDIR/block.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"REACHED-MARKER-CLAIM"* ]]
}

@test "a prune holding the lock: the deploy waits, times out, FAILS before the marker claim" {
  _hold_lock "$MAIN_PRUNE_LOCK_FILE" 30; holder=$!
  sleep 1
  MAIN_PRUNE_LOCK_WAIT_SECS=1 run bash "$TEST_TMPDIR/block.sh"
  kill "$holder" 2>/dev/null || true
  [ "$status" -ne 0 ]
  [[ "$output" == *"FATAL"*"still holds"* ]]
  [[ "$output" != *"REACHED-MARKER-CLAIM"* ]]
}

@test "an unopenable lock file fails the deploy before the marker claim" {
  MAIN_PRUNE_LOCK_FILE=/dev/null/nope.lock run bash "$TEST_TMPDIR/block.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"FATAL"*"cannot open"* ]]
  [[ "$output" != *"REACHED-MARKER-CLAIM"* ]]
}

@test "ssh-mode deploy does not pretend: no lock taken, it says so and continues" {
  HYDRA_LOCAL=false run bash "$TEST_TMPDIR/block.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"NOT taken"* ]]
  [[ "$output" == *"REACHED-MARKER-CLAIM"* ]]
}
