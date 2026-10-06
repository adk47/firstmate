#!/usr/bin/env bats
# scripts/main-prune-restart.sh (MUS-1295): runs the REAL script against stubbed systemctl/openclaw/curl/pgrep
# and a temp state dir with real sqlite files. Contract: FAIL-OPEN (a prune that cannot run degrades to a plain
# start, never a dead gateway, never a loop) and one run at a time with deploy/rollback.
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
SCRIPT="${MPR_SCRIPT:-$HYDRA_REPO/scripts/main-prune-restart.sh}"

setup() {
  TEST_TMPDIR="$(mktemp -d)"; export TEST_TMPDIR
  STUBBIN="$TEST_TMPDIR/bin"; mkdir -p "$STUBBIN"
  mkdir -p "$TEST_TMPDIR/log"
  export CALLS="$TEST_TMPDIR/calls.log"; : > "$CALLS"
  export SD="$TEST_TMPDIR/state"
  mkdir -p "$SD/agents/qa/agent" "$SD/state"
  for db in "$SD/agents/qa/agent/openclaw-agent.sqlite" "$SD/state/openclaw.sqlite"; do
    python3 -c "
import sqlite3,sys
c=sqlite3.connect(sys.argv[1]); c.execute('create table session_nodes(id integer)')
c.executemany('insert into session_nodes values (?)',[(i,) for i in range(5)]); c.commit()" "$db"
  done
  echo '{"session":{"maintenance":{"mode":"enforce","pruneAfter":"14d"}}}' > "$SD/openclaw.json"

  export BACKUP_ROOT="$TEST_TMPDIR/backups" LOG_DIR="$TEST_TMPDIR/log"
  export MAINT_SH="$STUBBIN/hydra-maintenance.sh"
  export STABLE_SECS=0 MAX_WAIT_SECS=5 POLL_SECS=0
  export STUB_ACTIVE=active STUB_PGREP_RC=1 STUB_HTTP=200
  export LOCK_FILE="$TEST_TMPDIR/prune.lock"
  export STUB_START_RC=0 HYDRA_PRUNE_PATH="$STUBBIN:$PATH"

  # Stateful: a successful stop makes the service inactive until a start.
  cat > "$STUBBIN/systemctl" <<'STUB'
#!/usr/bin/env bash
echo "systemctl $*" >> "$CALLS"
case "$1" in
  is-active) if [ "$STUB_ACTIVE" = active ] && [ ! -e "$TEST_TMPDIR/stopped" ]; then echo active; exit 0; else echo inactive; exit 3; fi ;;
  show)      echo 0; exit 0 ;;
  stop)      if [ "${STUB_STOP_RC:-0}" -eq 0 ] || [ -n "${STUB_STOP_DEACTIVATES:-}" ]; then touch "$TEST_TMPDIR/stopped"; fi; exit "${STUB_STOP_RC:-0}" ;;
  start)     [ "${STUB_START_RC:-0}" -eq 0 ] && rm -f "$TEST_TMPDIR/stopped"; exit "${STUB_START_RC:-0}" ;;
esac
exit 0
STUB
  # The script runs openclaw under `env -i`, so the stub cannot see $CALLS or STUB_*: bake the paths in.
  echo 0 > "$TEST_TMPDIR/openclaw.rc"
  cat > "$STUBBIN/openclaw" <<STUB
#!/usr/bin/env bash
echo "openclaw \$* cfg_prune=\$(python3 -c "import json,os;print(json.load(open(os.environ['OPENCLAW_CONFIG_PATH']))['session']['maintenance']['pruneAfter'])")" >> "$CALLS"
exit "\$(cat "$TEST_TMPDIR/openclaw.rc")"
STUB
  printf '#!/usr/bin/env bash\nshift; exec "$@"\n' > "$STUBBIN/timeout"   # macOS has no timeout(1)
  cat > "$STUBBIN/curl" <<'STUB'
#!/usr/bin/env bash
echo "$STUB_HTTP"
STUB
  cat > "$STUBBIN/pgrep" <<'STUB'
#!/usr/bin/env bash
exit "$STUB_PGREP_RC"
STUB
  cat > "$MAINT_SH" <<'STUB'
#!/usr/bin/env bash
echo "maintenance $*" >> "$CALLS"
STUB
  chmod +x "$STUBBIN"/*
  PATH="$STUBBIN:$PATH"; export PATH
}
teardown() { rm -rf "$TEST_TMPDIR"; }

# One process holds the lock (exec): kill $! releases it and leaves no orphan holding bats' fds.
_hold_lock() { bash -c 'exec 8>"$1"; flock -n 8 && exec sleep "$2"' _ "$1" "$2" >/dev/null 2>&1 3>&- & }

_run() { run bash "$SCRIPT" "${1:-test}"; }
_count() { grep -c "$1" "$CALLS" || true; }

@test "happy path: backup, stop, prune at 24h on a temp config, start, stable" {
  _run
  [ "$status" -eq 0 ]
  [[ "$output" == *"RESULT OK"* ]]
  grep -q '^maintenance start' "$CALLS"
  grep -q '^maintenance stop' "$CALLS"
  [ "$(grep -n 'systemctl stop' "$CALLS" | cut -d: -f1)" -lt "$(grep -n '^openclaw' "$CALLS" | cut -d: -f1)" ]
  [ "$(grep -n '^openclaw' "$CALLS" | cut -d: -f1)" -lt "$(grep -n 'systemctl start openclaw-gateway-main' "$CALLS" | cut -d: -f1)" ]
  grep -q 'openclaw sessions cleanup --all-agents --enforce --json cfg_prune=24h' "$CALLS"
  grep -q '"pruneAfter": *"14d"' "$SD/openclaw.json"
  b="$(ls -d "$BACKUP_ROOT"/*/ | head -1)"
  [ -s "${b}agents/qa/agent/openclaw-agent.sqlite" ]
  [ -s "${b}state/openclaw.sqlite" ]
}

@test "FAIL-OPEN: a failing prune still starts main, exactly once, and reports it" {
  echo 7 > "$TEST_TMPDIR/openclaw.rc"
  _run
  [ "$(_count 'systemctl start openclaw-gateway-main')" -eq 1 ]
  [ "$(_count 'systemctl stop openclaw-gateway-main')" -eq 1 ]
  [ "$(_count '^openclaw ')" -eq 1 ]   # never retried: no loop
  [[ "$output" == *"cleanup rc=7"* ]]
  [[ "$output" == *"RESULT OK"* ]]
  grep -q '^maintenance stop' "$CALLS"
}

@test "a failed backup aborts BEFORE main is touched" {
  export BACKUP_ROOT="/dev/null/nope"
  _run
  [ "$status" -ne 0 ]
  [ "$(_count 'systemctl stop')" -eq 0 ]
  [ "$(_count '^openclaw ')" -eq 0 ]
  grep -q '^maintenance stop' "$CALLS"
}

@test "never loops when health never stabilises: no second restart, main left running" {
  export STUB_HTTP=000
  _run
  [[ "$output" == *"NOT STABLE"* ]]
  [ "$(_count 'systemctl start openclaw-gateway-main')" -eq 1 ]
  [ "$(_count 'systemctl restart')" -eq 0 ]
}

@test "skips (touching nothing) while a deploy/rollback runs, and when main is not active" {
  export STUB_PGREP_RC=0
  _run
  export STUB_PGREP_RC=1 STUB_ACTIVE=inactive
  _run; [ "$status" -eq 0 ]
  [ "$(_count 'systemctl stop')" -eq 0 ]
}

@test "keeps only the 2 newest backups" {
  for t in 20260101T000000Z 20260102T000000Z 20260103T000000Z; do
    mkdir -p "$BACKUP_ROOT/$t"; sleep 1
  done
  _run
  [ "$(ls -1d "$BACKUP_ROOT"/*/ | wc -l | tr -d ' ')" -eq 2 ]
}

@test "nightly mode: a main younger than the uptime floor is skipped, an older one is pruned" {
  export HYDRA_MAIN_MIN_UPTIME_H=4 HYDRA_MAIN_UPTIME_H=1
  _run nightly
  [[ "$output" == *"already fresh"* ]]
  [ "$(_count 'systemctl stop')" -eq 0 ]
  export HYDRA_MAIN_UPTIME_H=9
  _run nightly
  [ "$(_count 'systemctl start openclaw-gateway-main')" -eq 1 ]
}

@test "a FAILED stop never prunes the live store, and the unit fails so it pages" {
  export STUB_STOP_RC=1
  _run
  [ "$status" -ne 0 ]
  [ "$(_count '^openclaw ')" -eq 0 ]
  [[ "$output" == *"NOT pruning a live store"* ]]
  grep -q '^maintenance stop' "$CALLS"
}

@test "a stop that returns 0 but leaves main ACTIVE never prunes either" {
  sed -i.bak 's|^  stop) .*|  stop)      exit 0 ;;|' "$STUBBIN/systemctl"
  _run
  [ "$status" -ne 0 ]
  [ "$(_count '^openclaw ')" -eq 0 ]
}

@test "a FAILED start fails the unit (pager), is not retried, and clears maintenance" {
  export STUB_START_RC=1
  _run
  [ "$status" -ne 0 ]
  [ "$(_count 'systemctl start openclaw-gateway-main')" -eq 1 ]
  [[ "$output" == *"systemctl start failed"* ]]
  grep -q '^maintenance stop' "$CALLS"
}

@test "main never reaching stable health fails the unit, without a second restart" {
  export STUB_HTTP=000
  _run
  [ "$status" -ne 0 ]
  [ "$(_count 'systemctl restart')" -eq 0 ]
  grep -q '^maintenance stop' "$CALLS"
}

@test "a failing PRUNE still starts main once, but fails the unit so OnFailure pages" {
  echo 7 > "$TEST_TMPDIR/openclaw.rc"
  _run
  [ "$status" -ne 0 ]
  [ "$(_count 'systemctl start openclaw-gateway-main')" -eq 1 ]
  [ "$(_count '^openclaw ')" -eq 1 ]
  [[ "$output" == *"RESULT OK"* ]]
}

@test "stop that exits NON-ZERO (timeout) while the unit already reads inactive still never prunes" {
  # systemctl stop timing out can leave the unit 'deactivating' (is-active != active) with rc=1 while the
  # gateway is still flushing SQLite. The rc arm alone must refuse the prune (is-active cannot catch this).
  export STUB_STOP_RC=1 STUB_STOP_DEACTIVATES=1
  _run
  [ "$status" -ne 0 ]
  [ "$(_count '^openclaw ')" -eq 0 ]
  [[ "$output" == *"NOT pruning a live store"* ]]
}

@test "the skipped-prune path logs no bogus 'prune failed' WARN or shell error" {
  export STUB_STOP_RC=1
  _run
  [[ "$output" != *"WARN prune failed"* ]]
  [[ "$output" != *"integer expected"* ]]
}

@test "a second invocation while one holds the lock skips: no stop, no prune, no backup" {
  _hold_lock "$LOCK_FILE" 30; holder=$!
  sleep 1
  _run manual
  kill "$holder" 2>/dev/null || true
  [ "$status" -eq 0 ]
  [[ "$output" == *"holds"*"skip"* ]]
  [ "$(_count 'systemctl stop')" -eq 0 ]
  [ "$(_count '^openclaw ')" -eq 0 ]
  [ ! -d "$BACKUP_ROOT" ]
}

@test "an unopenable lock aborts before any change, and pages" {
  export LOCK_FILE="/dev/null/nope.lock"
  _run
  [ "$status" -ne 0 ]
  [ "$(_count 'systemctl stop')" -eq 0 ]
}

# ---- deploy/rollback <-> prune exclusion (MUS-3742): a deploy that begins AFTER the pgrep check must block
# until cleanup is over (the prune holds the lock through `systemctl start`).
LIB="$HYDRA_REPO/scripts/lib/main-prune-lock.sh"

_slow_cleanup_openclaw() {   # cleanup that signals it started, then runs until released (paths baked in: env -i)
  cat > "$STUBBIN/openclaw" <<STUB
#!/usr/bin/env bash
echo "openclaw \$*" >> "$CALLS"
touch "$TEST_TMPDIR/cleanup-started"
while [ ! -e "$TEST_TMPDIR/release" ]; do sleep 0.1; done
STUB
  chmod +x "$STUBBIN/openclaw"
}
_wait_for() { local i; for i in $(seq 1 100); do [ -e "$1" ] && return 0; sleep 0.1; done; return 1; }
_deploy_acquire() {   # what deploy.sh / rollback.sh do, via the real lib
  MAIN_PRUNE_LOCK_FILE="$LOCK_FILE" MAIN_PRUNE_LOCK_WAIT_SECS="$1" bash -c "source '$LIB'; acquire_main_prune_lock"
}

@test "a deploy that starts AFTER the pgrep check blocks until cleanup is over and main is started" {
  _slow_cleanup_openclaw
  bash "$SCRIPT" nightly > "$TEST_TMPDIR/prune.out" 2>&1 & prune=$!
  _wait_for "$TEST_TMPDIR/cleanup-started"
  # mid-cleanup: a bounded deploy wait must TIME OUT (rc 1), not slip through
  run _deploy_acquire 1
  [ "$status" -eq 1 ]
  ( _deploy_acquire 30 && echo "DEPLOY-ACQUIRED" >> "$CALLS" ) & deploy=$!
  sleep 1
  [ "$(_count DEPLOY-ACQUIRED)" -eq 0 ]
  [ "$(_count 'systemctl start openclaw-gateway-main')" -eq 0 ]
  touch "$TEST_TMPDIR/release"
  wait "$prune"; wait "$deploy"
  [ "$(_count DEPLOY-ACQUIRED)" -eq 1 ]
  # the order is the point: the prune started main BEFORE the deploy got the lock
  [ "$(grep -n 'systemctl start openclaw-gateway-main' "$CALLS" | head -1 | cut -d: -f1)" -lt "$(grep -n DEPLOY-ACQUIRED "$CALLS" | cut -d: -f1)" ]
}

@test "the prune releases the lock after start, so a deploy is not held for the stable-health wait" {
  export STUB_HTTP=000 MAX_WAIT_SECS=6          # health never stabilises: the wait loop runs ~6s
  bash "$SCRIPT" nightly > "$TEST_TMPDIR/prune.out" 2>&1 & prune=$!
  for i in $(seq 1 100); do [ "$(_count 'systemctl start openclaw-gateway-main')" -ge 1 ] && break; sleep 0.1; done
  run _deploy_acquire 2                          # still inside the prune's health wait
  [ "$status" -eq 0 ]
  wait "$prune" || true
}

@test "the lock path is one literal shared by the lib, the prune, deploy.sh and rollback.sh" {
  [ "$(grep -c '/run/lock/hydra-main-prune-restart.lock' "$LIB")" -eq 1 ]
  [ "$(grep -c '/run/lock/hydra-main-prune-restart.lock' "$SCRIPT")" -ge 1 ]
  grep -q 'source "$SCRIPT_DIR/lib/main-prune-lock.sh"' "$HYDRA_REPO/scripts/deploy.sh"
  grep -q 'source "$SCRIPT_DIR/lib/main-prune-lock.sh"' "$HYDRA_REPO/scripts/rollback.sh"
}

@test "no deploy/rollback path backgrounds a child that could inherit the lock fd" {
  [ "$(grep -cE '(^|[[:space:];|])(nohup|setsid|disown|coproc)([[:space:]]|$)' \
      "$HYDRA_REPO/scripts/deploy.sh" "$HYDRA_REPO/scripts/rollback.sh" \
      "$HYDRA_REPO/scripts/lib/gateway-restart.sh" "$HYDRA_REPO/scripts/lib/deploy-mutation-marker.sh" | awk -F: '{s+=$2} END{print s+0}')" -eq 0 ]
}

@test "a SIGTERM mid-cleanup starts main exactly once, clears maintenance, and exits non-zero" {
  _slow_cleanup_openclaw
  bash "$SCRIPT" nightly > "$TEST_TMPDIR/prune.out" 2>&1 & prune=$!
  _wait_for "$TEST_TMPDIR/cleanup-started"
  kill -TERM "$prune"
  touch "$TEST_TMPDIR/release"   # under systemd the cleanup child dies of the SIGTERM too
  wait "$prune" && status=0 || status=$?
  [ "$status" -ne 0 ]
  [ "$(_count 'systemctl start openclaw-gateway-main')" -eq 1 ]
  [ "$(_count '^maintenance stop')" -eq 1 ]
}
