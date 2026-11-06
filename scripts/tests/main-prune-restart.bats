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
  export DEPLOY_PATH="$TEST_TMPDIR/deploy"; mkdir -p "$DEPLOY_PATH"
  export STUB_JOBS="" STUB_PGREP_OUT=""
  export HYDRA_MAIN_PRUNE_STAMP="$TEST_TMPDIR/stampdir/main-prune-last-ok"   # never the real /var/lib/hydra

  # Stateful: a successful stop makes the service inactive until a start.
  cat > "$STUBBIN/systemctl" <<'STUB'
#!/usr/bin/env bash
echo "systemctl $*" >> "$CALLS"
case "$1" in
  is-active) if [ "$STUB_ACTIVE" = active ] && [ ! -e "$TEST_TMPDIR/stopped" ]; then echo active; exit 0; else echo inactive; exit 3; fi ;;
  show)      echo 0; exit 0 ;;
  list-jobs) printf '%s' "${STUB_JOBS:-}"; exit 0 ;;
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
  # macOS has no timeout(1): GNU timeout if installed, else a shim that just drops its options and duration
  REAL_TIMEOUT="$(command -v gtimeout || command -v timeout || true)"; export REAL_TIMEOUT
  printf '#!/usr/bin/env bash\nwhile [[ "$1" == --* ]]; do shift; done; shift; exec "$@"\n' > "$STUBBIN/timeout"
  cat > "$STUBBIN/curl" <<'STUB'
#!/usr/bin/env bash
echo "$STUB_HTTP"
STUB
  cat > "$STUBBIN/pgrep" <<'STUB'
#!/usr/bin/env bash
# STUB_PGREP_OUT answers only the rsync --server probe; the deploy/rollback probe keeps STUB_PGREP_RC
case "$*" in *"rsync --server"*) [ -z "${STUB_PGREP_OUT:-}" ] || { printf '%s\n' "$STUB_PGREP_OUT"; exit 0; }; exit 1 ;; esac
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

@test "an unwritable temp dir aborts BEFORE main is stopped, clears maintenance and pages" {
  TMPDIR="$TEST_TMPDIR/no-such-dir" _run
  [ "$status" -ne 0 ]
  [[ "$output" == *"temp config"* ]]
  [ "$(_count 'systemctl stop')" -eq 0 ]
  [ "$(_count 'systemctl start')" -eq 0 ]
  [ "$(_count '^openclaw ')" -eq 0 ]
  grep -q '^maintenance stop' "$CALLS"
}

@test "an unparseable live config aborts BEFORE main is stopped, clears maintenance and pages" {
  echo 'not json' > "$SD/openclaw.json"
  TMPDIR="$TEST_TMPDIR" _run
  [ "$status" -ne 0 ]
  [[ "$output" == *"temp config"* ]]
  [ "$(_count 'systemctl stop')" -eq 0 ]
  [ "$(_count 'systemctl start')" -eq 0 ]
  [ "$(_count '^openclaw ')" -eq 0 ]
  grep -q '^maintenance stop' "$CALLS"
  [ -z "$(ls -A "$TEST_TMPDIR" | grep '^\.main-prune-cfg' || true)" ]
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

# MUS-30705: only a PRUNE makes main fresh. Process uptime does not (5 Nov: a deploy restart at ~01:40Z made the
# old uptime floor skip the 02:30Z prune; rows kept growing and the post-start freeze went 292 s -> 1239 s).
@test "5 Nov regression: a main restarted 0h ago with NO prune stamp is still pruned" {
  export HYDRA_MAIN_MIN_UPTIME_H=4 HYDRA_MAIN_UPTIME_H=0 HYDRA_MAIN_MIN_PRUNE_AGE_H=20
  _run nightly
  [ "$status" -eq 0 ]
  [ "$(_count 'systemctl stop openclaw-gateway-main')" -eq 1 ]
  [ "$(_count '^openclaw ')" -eq 1 ]
  [ "$(_count 'systemctl start openclaw-gateway-main')" -eq 1 ]
  [ -d "$BACKUP_ROOT" ] && [ -n "$(ls -A "$BACKUP_ROOT")" ]
}

@test "prune-age skip: a prune that succeeded 2h ago skips and touches nothing" {
  export HYDRA_MAIN_MIN_PRUNE_AGE_H=20
  mkdir -p "$TEST_TMPDIR/stampdir"; echo $(( $(date +%s) - 7200 )) > "$HYDRA_MAIN_PRUNE_STAMP"
  before="$(cat "$HYDRA_MAIN_PRUNE_STAMP")"
  _run nightly
  [ "$status" -eq 0 ]
  [[ "$output" == *"last prune ok 2h ago (< 20h) - skip"* ]]
  [ "$(_count 'systemctl stop')" -eq 0 ]
  [ "$(_count '^maintenance start')" -eq 0 ]
  [ ! -e "$BACKUP_ROOT" ] || [ -z "$(ls -A "$BACKUP_ROOT")" ]
  [ "$(cat "$HYDRA_MAIN_PRUNE_STAMP")" = "$before" ]
}

@test "prune-age: a stamp older than the floor prunes" {
  export HYDRA_MAIN_MIN_PRUNE_AGE_H=20
  mkdir -p "$TEST_TMPDIR/stampdir"; echo $(( $(date +%s) - 30*3600 )) > "$HYDRA_MAIN_PRUNE_STAMP"
  _run nightly
  [ "$(_count 'systemctl start openclaw-gateway-main')" -eq 1 ]
}

@test "prune-age: a stamp that is non-numeric, empty or in the future never skips" {
  export HYDRA_MAIN_MIN_PRUNE_AGE_H=20
  mkdir -p "$TEST_TMPDIR/stampdir"
  for bad in abc "" "12abc" "-5" "$(( $(date +%s) + 86400 ))"; do
    : > "$CALLS"; printf '%s\n' "$bad" > "$HYDRA_MAIN_PRUNE_STAMP"
    _run nightly
    [ "$status" -eq 0 ]
    [ "$(_count 'systemctl stop openclaw-gateway-main')" -eq 1 ]
    [[ "$output" != *"- skip"* ]]
  done
}

@test "prune-age: a garbage HYDRA_MAIN_MIN_PRUNE_AGE_H never skips" {
  export HYDRA_MAIN_MIN_PRUNE_AGE_H=abc
  mkdir -p "$TEST_TMPDIR/stampdir"; echo "$(date +%s)" > "$HYDRA_MAIN_PRUNE_STAMP"
  _run nightly
  [ "$(_count 'systemctl stop openclaw-gateway-main')" -eq 1 ]
}

@test "stamp: a successful prune writes a fresh epoch stamp (and creates its dir)" {
  [ ! -e "$HYDRA_MAIN_PRUNE_STAMP" ]
  _run nightly
  [ "$status" -eq 0 ]
  v="$(cat "$HYDRA_MAIN_PRUNE_STAMP")"
  [[ "$v" =~ ^[0-9]+$ ]]
  [ $(( $(date +%s) - v )) -lt 120 ]
}

@test "stamp: a FAILED prune leaves the old stamp untouched, and a FAILED stop too" {
  mkdir -p "$TEST_TMPDIR/stampdir"; echo 1000 > "$HYDRA_MAIN_PRUNE_STAMP"
  echo 7 > "$TEST_TMPDIR/openclaw.rc"
  _run nightly
  [ "$(cat "$HYDRA_MAIN_PRUNE_STAMP")" = 1000 ]
  echo 0 > "$TEST_TMPDIR/openclaw.rc"; export STUB_STOP_RC=1
  _run nightly
  [ "$(cat "$HYDRA_MAIN_PRUNE_STAMP")" = 1000 ]
}

@test "stamp: a prune that fails with no prior stamp writes none" {
  echo 7 > "$TEST_TMPDIR/openclaw.rc"
  _run nightly
  [ ! -e "$HYDRA_MAIN_PRUNE_STAMP" ]
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
  # a stop timeout leaves the unit 'deactivating' with rc=1: only the rc arm can refuse the prune here
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

# ---- MUS-3742: a deploy that begins AFTER the pgrep check must block until cleanup is over
LIB="$HYDRA_REPO/scripts/lib/main-prune-lock.sh"

_slow_cleanup_openclaw() {   # cleanup that signals it started, then runs until released or killed (paths baked in: env -i)
  cat > "$STUBBIN/openclaw" <<STUB
#!/usr/bin/env bash
echo "openclaw \$*" >> "$CALLS"
echo \$\$ > "$TEST_TMPDIR/cleanup.pid"; touch "$TEST_TMPDIR/cleanup-started"
for _ in \$(seq 1 300); do [ -e "$TEST_TMPDIR/release" ] && break; sleep 0.1; done
STUB
  chmod +x "$STUBBIN/openclaw"
}
_wait_for() { local i; for i in $(seq 1 100); do [ -e "$1" ] && return 0; sleep 0.1; done; return 1; }
_deploy_acquire() {   # what deploy.sh / rollback.sh do, via the real lib
  MAIN_PRUNE_LOCK_FILE="$LOCK_FILE" MAIN_PRUNE_LOCK_WAIT_SECS="$1" bash -c "source '$LIB'; acquire_main_prune_lock"
}

@test "a deploy that starts AFTER the pgrep check blocks until cleanup is over and main is started" {
  _slow_cleanup_openclaw
  bash "$SCRIPT" nightly > "$TEST_TMPDIR/prune.out" 2>&1 3>&- & prune=$!
  _wait_for "$TEST_TMPDIR/cleanup-started"
  run _deploy_acquire 1
  [ "$status" -eq 1 ]
  ( _deploy_acquire 30 && echo "DEPLOY-ACQUIRED" >> "$CALLS" ) 3>&- & deploy=$!
  sleep 1
  [ "$(_count DEPLOY-ACQUIRED)" -eq 0 ]
  [ "$(_count 'systemctl start openclaw-gateway-main')" -eq 0 ]
  touch "$TEST_TMPDIR/release"
  wait "$prune"; wait "$deploy"
  [ "$(_count DEPLOY-ACQUIRED)" -eq 1 ]
  [ "$(grep -n 'systemctl start openclaw-gateway-main' "$CALLS" | head -1 | cut -d: -f1)" -lt "$(grep -n DEPLOY-ACQUIRED "$CALLS" | cut -d: -f1)" ]
}

@test "the prune releases the lock after start, so a deploy is not held for the stable-health wait" {
  export STUB_HTTP=000 MAX_WAIT_SECS=6          # health never stabilises: the wait loop runs ~6s
  bash "$SCRIPT" nightly > "$TEST_TMPDIR/prune.out" 2>&1 3>&- & prune=$!
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
  bash "$SCRIPT" nightly > "$TEST_TMPDIR/prune.out" 2>&1 3>&- & prune=$!
  _wait_for "$TEST_TMPDIR/cleanup-started"
  kill -TERM "$prune" "$(cat "$TEST_TMPDIR/cleanup.pid")"   # systemd's control-group kill takes the cleanup child too
  wait "$prune" && status=0 || status=$?
  [ "$status" -ne 0 ]
  [ "$(_count 'systemctl start openclaw-gateway-main')" -eq 1 ]
  [ "$(_count '^maintenance stop')" -eq 1 ]
}

@test "a cleanup that IGNORES SIGTERM is KILLed after the grace, so main is not left stopped" {
  [ -n "$REAL_TIMEOUT" ] || skip "needs GNU timeout (brew install coreutils)"
  printf '#!/usr/bin/env bash\nexec %s "$@"\n' "$REAL_TIMEOUT" > "$STUBBIN/timeout"
  cat > "$STUBBIN/openclaw" <<STUB
#!/usr/bin/env bash
trap '' TERM
for _ in \$(seq 1 300); do sleep 0.1; done
STUB
  export CLEANUP_TIMEOUT_S=1 CLEANUP_KILL_AFTER_S=1
  SECONDS=0; _run
  [ "$SECONDS" -lt 15 ]
  [ "$status" -ne 0 ]
  [[ "$output" == *"cleanup rc=137"* ]]
  [ "$(_count 'systemctl start openclaw-gateway-main')" -eq 1 ]
}

# --- round 9 (MUS-8545): remote-side deploy-mutation guard. Three signals, each paired with a must-not-skip case.
_assert_skipped_untouched() {
  [ "$status" -eq 0 ]
  [[ "$output" == *"SKIP deploy-mutation-in-flight"* ]]
  [ "$(_count 'systemctl stop')" -eq 0 ]
  [ "$(_count '^maintenance start')" -eq 0 ]
}

@test "mutation guard: a systemd job already operating a gateway skips the prune" {
  STUB_JOBS="59227591 openclaw-gateway-main.service start running" _run
  _assert_skipped_untouched
}

@test "mutation guard: an unrelated systemd job does not skip" {
  STUB_JOBS="59224459 close-resolved-conversations.service start running" _run
  [ "$status" -eq 0 ]
  [[ "$output" == *"RESULT OK"* ]]
  [ "$(_count 'systemctl stop')" -eq 1 ]
}

@test "mutation guard: a live rsync --server writing DEPLOY_PATH/ skips the prune" {
  STUB_PGREP_OUT="4242 rsync --server --delete-before -g -l . $DEPLOY_PATH/" _run
  _assert_skipped_untouched
}

@test "mutation guard: a live rsync --server writing another path does not skip" {
  STUB_PGREP_OUT="4242 rsync --server --delete-before -g -l . /opt/other/" _run
  [ "$status" -eq 0 ]
  [[ "$output" == *"RESULT OK"* ]]
  [ "$(_count 'systemctl stop')" -eq 1 ]
}

@test "mutation guard: a fresh .deploy-mutating marker skips and names its owner" {
  echo "ci-run-77" > "$DEPLOY_PATH/.deploy-mutating"
  _run
  _assert_skipped_untouched
  [[ "$output" == *"ci-run-77"* ]]
}

@test "mutation guard: a marker older than the bound does not skip" {
  echo stranded > "$DEPLOY_PATH/.deploy-mutating"
  touch -t "$(date -u -v-3H +%Y%m%d%H%M 2>/dev/null || date -u -d '3 hours ago' +%Y%m%d%H%M)" "$DEPLOY_PATH/.deploy-mutating"
  _run
  [ "$status" -eq 0 ]
  [[ "$output" == *"RESULT OK"* ]]
  [ "$(_count 'systemctl stop')" -eq 1 ]
}

@test "mutation guard: a marker that appears after the backup stops the run before main is stopped, and cleans up" {
  # signals are clear at the first check; the maintenance stub (called after it) drops the marker
  cat > "$MAINT_SH" <<'STUB'
#!/usr/bin/env bash
echo "maintenance $*" >> "$CALLS"
[ "$1" = start ] && echo racing-deploy > "$DEPLOY_PATH/.deploy-mutating"
exit 0
STUB
  mkdir -p "$TEST_TMPDIR/tmpdir"
  TMPDIR="$TEST_TMPDIR/tmpdir" _run
  [ "$status" -eq 0 ]
  [[ "$output" == *"SKIP deploy-mutation-in-flight before stop"* ]]
  [ "$(_count 'systemctl stop')" -eq 0 ]
  grep -q '^maintenance stop' "$CALLS"
  [ -z "$(ls -A "$TEST_TMPDIR/tmpdir")" ]
}
