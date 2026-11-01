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
         /^# -- end of the deploy locks: everything below runs under them/ { on = 0 }
         on' "$DEPLOY"
    echo 'echo REACHED-MARKER-CLAIM'
  } > "$TEST_TMPDIR/block.sh"
  grep -q 'acquire_main_prune_lock' "$TEST_TMPDIR/block.sh"
}
# One process holds the lock (exec): kill $! releases it and leaves no orphan holding bats' fds.
_hold_lock() { bash -c 'exec 8>"$1"; flock -n 8 && exec sleep "$2"' _ "$1" "$2" >/dev/null 2>&1 3>&- & }

teardown() {
  # a failing run must not orphan the heartbeat child (it is also bounded to ~60s)
  [ -n "${HB_PIDFILE:-}" ] && [ -s "$HB_PIDFILE" ] && kill -9 "$(cat "$HB_PIDFILE")" 2>/dev/null || true
  rm -rf "$TEST_TMPDIR"
}

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
         /^# -- end of the deploy locks: everything below runs under them/ { on = 0 }
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

# Bot finding (12 Oct): the remote lock lives only as long as the ssh holding it. If that dies after acquisition (link
# drop) the prune can take the lock while the deploy keeps mutating, so the caller must be aborted, not left running.
# Two sleeps: the watcher now stops the in-flight foreground child (the first sleep) before it TERMs the parent, so the
# script moves on to the second one; the parent's TERM must land there.
@test "ssh-mode deploy: the ssh holder dying AFTER the lock was taken aborts the deploy (fail closed)" {
  _ssh_block "$FAKE_SSH_OK" 'kill -9 "$MAIN_PRUNE_LOCK_REMOTE_PID"; sleep 10; sleep 10; echo SURVIVED-LOCK-LOSS'
  MAIN_PRUNE_LOCK_WATCH_SECS=0.2 run bash "$TEST_TMPDIR/ssh-block.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"holding the main prune lock"*"died"* ]]
  [[ "$output" != *"SURVIVED-LOCK-LOSS"* ]]
}

@test "ssh-mode deploy: a healthy holder is not mistaken for a lost lock" {
  _ssh_block "$FAKE_SSH_OK" 'sleep 1.5; main_prune_lock_lost && echo LOST || echo STILL-HELD'
  MAIN_PRUNE_LOCK_WATCH_SECS=0.2 run bash "$TEST_TMPDIR/ssh-block.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"STILL-HELD"* ]]
}

# Bot finding (13 Oct, lib/main-prune-lock.sh:60): TERMing only the parent leaves a foreground child (rsync, ssh) running
# and mutating node-8 while the prune takes the freed lock. The child here is a real unbounded-in-practice loop (60s
# cap only so a failing test cannot orphan it) that heartbeats; it must be dead the moment `run` returns and silent after.
@test "ssh-mode deploy: lock loss stops the in-flight foreground child tree, flag first, before the parent exits" {
  HB="$TEST_TMPDIR/hb"; HB_PIDFILE="$TEST_TMPDIR/child.pid"; ORD="$TEST_TMPDIR/order"
  _ssh_block "$FAKE_SSH_OK" "( until [ -s $HB_PIDFILE ]; do sleep 0.1; done; sleep 0.3; kill -9 \"\$MAIN_PRUNE_LOCK_REMOTE_PID\" ) >/dev/null 2>&1 &
LOST=\"\$MAIN_PRUNE_LOCK_LOST_FILE\" bash -c 'trap \"[ -e \\\"\\\$LOST\\\" ] && echo flag-first >$ORD; exit 143\" TERM; echo \$\$ >$HB_PIDFILE; for i in \$(seq 300); do echo tick >>$HB; sleep 0.2; done' >/dev/null 2>&1
sleep 10; echo SURVIVED-LOCK-LOSS"
  MAIN_PRUNE_LOCK_WATCH_SECS=0.2 run bash "$TEST_TMPDIR/ssh-block.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"holding the main prune lock"*"died"* ]]
  [[ "$output" != *"SURVIVED-LOCK-LOSS"* ]]
  [ -s "$HB_PIDFILE" ]
  if kill -0 "$(cat "$HB_PIDFILE")" 2>/dev/null; then false; fi
  n=$(wc -l <"$HB"); sleep 1
  [ "$(wc -l <"$HB")" -eq "$n" ]
  [ "$(cat "$ORD")" = flag-first ]
}

# QA finding (13 Oct): killing the child before the parent leaves a window in which an errexit-suppressed step (`|| true`)
# starts the NEXT foreground child, which nothing stops. The parent is frozen first, so the second child never ticks.
@test "ssh-mode deploy: lock loss does not let an errexit-suppressed step start a successor child" {
  HB="$TEST_TMPDIR/hb"; HB2="$TEST_TMPDIR/hb2"; HB_PIDFILE="$TEST_TMPDIR/child.pid"
  _ssh_block "$FAKE_SSH_OK" "( until [ -s $HB_PIDFILE ]; do sleep 0.1; done; sleep 0.3; kill -9 \"\$MAIN_PRUNE_LOCK_REMOTE_PID\" ) >/dev/null 2>&1 &
bash -c 'echo \$\$ >$HB_PIDFILE; for i in \$(seq 300); do echo tick >>$HB; sleep 0.2; done' >/dev/null 2>&1 || true
bash -c 'for i in \$(seq 300); do echo tick >>$HB2; sleep 0.2; done' >/dev/null 2>&1 || true
echo SURVIVED-LOCK-LOSS"
  MAIN_PRUNE_LOCK_WATCH_SECS=0.2 run bash "$TEST_TMPDIR/ssh-block.sh"
  [ "$status" -ne 0 ]
  [[ "$output" != *"SURVIVED-LOCK-LOSS"* ]]
  sleep 1
  [ ! -s "$HB2" ]
  pkill -f "$HB2" 2>/dev/null || true
}

# cron_store_heal_trap (deploy.sh EXIT backstop, MUS-8719): when the node-8 lock was LOST, a prune may own it with main
# stopped for offline SQLite cleanup, so the emergency start must run ONLY under that lock (flock -n -E 99). While we
# still hold the lock a second flock would be refused by ourselves, so the start stays bare. The REAL trap function is
# lifted out of deploy.sh; run_on_node8 records the command string and really executes it so the real flock decides.
_heal_trap() {
  local lost="$1"
  [ -n "$MAIN_PRUNE_LOCK_FILE" ]
  {
    echo 'log() { echo "$*"; }'
    echo 'notify_slack() { echo "SLACK: $*"; }'
    echo "source '$LIB'"
    echo "run_on_node8() { printf '%s\n' \"\$1\" >>\"$TEST_TMPDIR/node8.cmds\"; bash -c \"\$1\"; }"
    printf '%s\n' "printf '#!/bin/sh\necho \"\$*\" >>\"$TEST_TMPDIR/systemctl.argv\"\n' >\"$TEST_TMPDIR/systemctl\"; chmod +x \"$TEST_TMPDIR/systemctl\""
    echo "SYSTEMCTL_BIN='$TEST_TMPDIR/systemctl'"
    echo 'CRON_HEAL_STOPPED=openclaw-gateway-main'
    [ "$lost" = lost ] && echo "MAIN_PRUNE_LOCK_LOST_FILE='$TEST_TMPDIR/lost'; : >\"\$MAIN_PRUNE_LOCK_LOST_FILE\""
    awk '/^  cron_store_heal_trap\(\) \{/ { on = 1 } on { print } on && /^  \}$/ { exit }' "$DEPLOY"
    echo 'cron_store_heal_trap'
  } > "$TEST_TMPDIR/heal.sh"
  grep -q 'cron_store_heal_trap()' "$TEST_TMPDIR/heal.sh"
}

@test "heal trap, lock lost and free: main is started UNDER the prune lock (flock -n -E 99)" {
  _heal_trap lost
  run bash "$TEST_TMPDIR/heal.sh"
  [ "$status" -eq 0 ]
  grep -q 'flock -n -E 99' "$TEST_TMPDIR/node8.cmds"
  [ "$(cat "$TEST_TMPDIR/systemctl.argv")" = "start openclaw-gateway-main" ]
  if grep -qv 'flock' "$TEST_TMPDIR/node8.cmds"; then false; fi
}

@test "heal trap, lock lost and a prune holds it: NOT started, the prune restarts main" {
  _heal_trap lost
  _hold_lock "$MAIN_PRUNE_LOCK_FILE" 30; holder=$!
  sleep 1
  run bash "$TEST_TMPDIR/heal.sh"
  kill "$holder" 2>/dev/null || true
  [ "$status" -eq 0 ]
  grep -q 'flock -n -E 99' "$TEST_TMPDIR/node8.cmds"
  [ ! -e "$TEST_TMPDIR/systemctl.argv" ]
  [[ "$output" == *"a prune holds"* ]]
}

@test "heal trap, holder alive: the start is BARE systemctl, not flock-wrapped (our own holder would refuse it)" {
  _heal_trap held
  run bash "$TEST_TMPDIR/heal.sh"
  [ "$status" -eq 0 ]
  [ "$(wc -l <"$TEST_TMPDIR/node8.cmds")" -eq 1 ]
  if grep -q 'flock' "$TEST_TMPDIR/node8.cmds"; then false; fi
  grep -q "systemctl start openclaw-gateway-main" "$TEST_TMPDIR/node8.cmds"
  [ "$(cat "$TEST_TMPDIR/systemctl.argv")" = "start openclaw-gateway-main" ]
}

# Fable [key=signed-on-sha] / QA #1604: the deploy ALSO holds the credit-message apply lock EXCLUSIVELY with the prune
# lock, for its whole run - an apply in flight (holding it shared) refuses the deploy before the marker claim, and no
# apply can take it while the deploy runs.
_hold_shared() { bash -c 'exec 8>>"$1"; flock -n -s 8 && exec sleep "$2"' _ "$1" "$2" >/dev/null 2>&1 3>&- & }

@test "apply lock: deploy.sh names verify_notify's apply lock, and sets it before the lock block it lifts" {
  py="$(python3 -c "import sys; sys.path.insert(0, '$BATS_TEST_DIRNAME/..'); from credit_review import verify_notify as v; print(v.APPLY_LOCK_PATH)" 2>/dev/null | tail -1)"
  [ -n "$py" ]
  grep -qx "DEPLOY_APPLY_LOCK_FILE=\"/var/lib/hydra/credit-review/apply.lock\"" "$DEPLOY"
  set_at=$(line_of '^DEPLOY_APPLY_LOCK_FILE=')
  lock=$(line_of '^  acquire_main_prune_lock \|\| lock_rc=\$\?')
  [ "$set_at" -lt "$lock" ]
  if grep -q 'DEPLOY_APPLY_LOCK_FILE' "$BATS_TEST_DIRNAME/../rollback.sh"; then false; fi   # rollback is not gated
}

@test "apply lock (local): an apply in flight refuses the deploy before the marker claim; a free one is held exclusively for the run" {
  export DEPLOY_APPLY_LOCK_FILE="$TEST_TMPDIR/cr/apply.lock"
  mkdir -p "$TEST_TMPDIR/cr"
  _hold_shared "$DEPLOY_APPLY_LOCK_FILE" 30; holder=$!
  sleep 1
  run bash "$TEST_TMPDIR/block.sh"
  kill "$holder" 2>/dev/null || true
  [ "$status" -ne 0 ]
  [[ "$output" == *"FATAL: deploy refused: a credit-message apply is in flight on node-8"* ]]
  [[ "$output" != *"REACHED-MARKER-CLAIM"* ]]
  # free: held for the run - an apply's shared non-blocking take fails while the deploy is past the lock block
  rm -rf "$TEST_TMPDIR/cr"     # a missing directory is created, never skipped
  { cat "$TEST_TMPDIR/block.sh"; echo 'exec 8>>"$DEPLOY_APPLY_LOCK_FILE"; if flock -n -s 8; then echo APPLY-COULD-START; else echo APPLY-EXCLUDED; fi'; } > "$TEST_TMPDIR/block2.sh"
  run bash "$TEST_TMPDIR/block2.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"REACHED-MARKER-CLAIM"* ]]
  [[ "$output" == *"APPLY-EXCLUDED"* ]]
}

@test "apply lock (ssh mode): an apply in flight on node-8 refuses the deploy; a free one is held on the far side for the run" {
  export DEPLOY_APPLY_LOCK_FILE="$TEST_TMPDIR/cr/apply.lock"
  mkdir -p "$TEST_TMPDIR/cr"
  _hold_shared "$DEPLOY_APPLY_LOCK_FILE" 30; holder=$!
  sleep 1
  _ssh_block "$FAKE_SSH_OK" ''
  run bash "$TEST_TMPDIR/ssh-block.sh"
  kill "$holder" 2>/dev/null || true
  [ "$status" -ne 0 ]
  [[ "$output" == *"FATAL: deploy refused: a credit-message apply is in flight on node-8"* ]]
  [[ "$output" != *"REACHED-MARKER-CLAIM"* ]]
  _ssh_block "$FAKE_SSH_OK" 'exec 7>>"$DEPLOY_APPLY_LOCK_FILE"; if flock -n -s 7; then echo APPLY-COULD-START; else echo APPLY-EXCLUDED; fi'
  run bash "$TEST_TMPDIR/ssh-block.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"APPLY-EXCLUDED"* ]]
  [[ "$output" == *"REACHED-MARKER-CLAIM"* ]]
}

@test "apply lock (QA #1604): the deploy locks are taken BEFORE Step 4a.5 (the muso CLI pin, the first node-8 write) and after the --report-only exit" {
  locks=$(line_of '^DEPLOY_APPLY_LOCK_FILE=')
  prune=$(line_of '^  acquire_main_prune_lock \|\| lock_rc=\$\?')
  endl=$(line_of '^# -- end of the deploy locks')
  pin=$(line_of '^  log "Step 4a.5/8: Pinning muso CLI')
  ro=$(line_of '^if \[\[ "\$REPORT_ONLY" == "1" \]\]; then')
  sync=$(line_of 'Step 4b/8')
  [ "$ro" -lt "$locks" ] && [ "$locks" -lt "$prune" ] && [ "$prune" -lt "$endl" ] && [ "$endl" -lt "$pin" ] && [ "$pin" -lt "$sync" ]
}
