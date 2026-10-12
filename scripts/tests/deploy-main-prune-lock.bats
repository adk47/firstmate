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

# ssh mode: the lock must be held ON node-8 (MUS-3742 bot finding, 12 Oct). _ssh_block builds deploy.sh's REAL lock
# block with HYDRA_LOCAL=false and a fake `ssh` (given as $1, a function body) so the real remote flock + FIFO hold run.
_ssh_block() {
  {
    echo 'log() { echo "$*"; }'
    echo 'fail() { echo "FATAL: $*"; exit 1; }'
    echo "source '$LIB'"
    echo 'SSH_KEY=k; SSH_OPTS=(-o X=y); NODE8_USER=u; NODE8_IP=h; HYDRA_LOCAL=false'
    echo "ssh() { $1; }"
    awk '/^# Serialise with scripts\/main-prune-restart.sh BEFORE the first node-8 mutation/ { on = 1 }
         /^log "Claiming the mutation marker/ { on = 0 }
         on' "$DEPLOY"
    echo "$2"
    echo 'echo REACHED-MARKER-CLAIM'
  } > "$TEST_TMPDIR/ssh-block.sh"
}
# The fake ssh runs the remote command (its last argument) in a local bash.
FAKE_SSH_OK='bash -c "${!#}"'

@test "ssh-mode deploy takes the lock ON the far side and still holds it while the deploy runs" {
  _ssh_block "$FAKE_SSH_OK" 'exec 8>"$MAIN_PRUNE_LOCK_FILE"; if flock -n 8; then echo PRUNE-COULD-LOCK; else echo PRUNE-EXCLUDED; fi'
  run bash "$TEST_TMPDIR/ssh-block.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ON node-8"* ]]
  [[ "$output" == *"PRUNE-EXCLUDED"* ]]
  [[ "$output" != *"PRUNE-COULD-LOCK"* ]]
  [[ "$output" == *"REACHED-MARKER-CLAIM"* ]]
}

@test "ssh-mode deploy: a prune holding the lock on node-8 FAILS the deploy before the marker claim" {
  _hold_lock "$MAIN_PRUNE_LOCK_FILE" 30; holder=$!
  sleep 1
  _ssh_block "$FAKE_SSH_OK" ''
  MAIN_PRUNE_LOCK_WAIT_SECS=1 run bash "$TEST_TMPDIR/ssh-block.sh"
  kill "$holder" 2>/dev/null || true
  [ "$status" -ne 0 ]
  [[ "$output" == *"FATAL"*"could not take"* ]]
  [[ "$output" != *"REACHED-MARKER-CLAIM"* ]]
}

@test "ssh-mode deploy: an unreachable node-8 FAILS closed, not open" {
  _ssh_block 'echo "ssh: connection refused" >&2; return 255' ''
  run bash "$TEST_TMPDIR/ssh-block.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"FATAL"*"could not take"* ]]
  [[ "$output" != *"REACHED-MARKER-CLAIM"* ]]
}

@test "ssh-mode lock is released once the deploy process exits (the far-side lock cannot leak)" {
  _ssh_block "$FAKE_SSH_OK" ''
  run bash "$TEST_TMPDIR/ssh-block.sh"
  [ "$status" -eq 0 ]
  sleep 1
  run flock -n "$MAIN_PRUNE_LOCK_FILE" true
  [ "$status" -eq 0 ]
}
