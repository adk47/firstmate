#!/usr/bin/env bash
# tests/fm-lock-reap.test.sh - the stale per-task lock sweep
# (bin/fm-lock-reap.sh over bin/fm-wake-lib.sh's fm_lock_reap_stale).
#
# Pins, with real processes:
#   1. A metadata lock whose recorded pid is dead and older than the minimum
#      age is reaped and logged; one younger than the minimum age is kept.
#   2. A lock whose pid now names a live process that STARTED AFTER the
#      record was written (pid reuse) is reaped as reused, while a live
#      holder that predates its record is never touched - the two cases are
#      driven apart by the record mtime alone, so the divergence is asserted.
#   3. Steering-inbox sequence locks are swept too, and a lock outside the
#      sweep's scope (the watcher lock) is never touched even when its holder
#      is dead.
#   4. The watcher runs the sweep on its own cadence and records reaps in its
#      triage log without waking firstmate.
#   5. A holder owned by another user (kill -0 answers EPERM) is alive, never
#      reaped as dead; pid 1 is that process for any non-root test run.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

REAP="$ROOT/bin/fm-lock-reap.sh"
TMP_ROOT=$(fm_test_tmproot fm-lock-reap)
TMP_ROOT=$(cd "$TMP_ROOT" && pwd)

dead_pid() {
  local p
  sh -c 'exit 0' & p=$!
  wait "$p" 2>/dev/null
  printf '%s\n' "$p"
}

# make_lock <lock> <pid> [record-mtime]: a symlink lock + owner record exactly
# as fm_lock_try_create lays it out.
make_lock() {
  local lock=$1 pid=$2 when=${3:-} owner
  owner=$(mktemp -d "$lock.owner.XXXXXX")
  printf '%s\n' "$pid" > "$owner/pid"
  [ -z "$when" ] || touch -t "$when" "$owner/pid" "$owner"
  ln -s "$owner" "$lock"
}

run_reap() {  # <state> [args...]
  local state=$1
  shift
  FM_HOME="${state%/state}" FM_STATE_OVERRIDE="$state" "$REAP" "$@"
}

test_dead_holder_reaped_after_min_age() {
  local state out old young
  state="$TMP_ROOT/dead/state"; mkdir -p "$state"
  old=$(dead_pid); young=$(dead_pid)
  make_lock "$state/.meta-old.lock" "$old" 202001010000
  make_lock "$state/.meta-young.lock" "$young"
  out=$(run_reap "$state" --min-age 60)
  [ ! -e "$state/.meta-old.lock" ] && [ ! -L "$state/.meta-old.lock" ] \
    || fail "a dead holder's aged metadata lock was not reaped"
  [ -z "$(find "$state" -maxdepth 1 -name '.meta-old.lock.owner.*')" ] \
    || fail "reaping left the dead holder's owner directory behind"
  assert_contains "$out" "reaped $state/.meta-old.lock pid=$old reason=dead" \
    "the reap should be logged with the gone pid and reason"
  [ -L "$state/.meta-young.lock" ] || fail "a dead holder's lock younger than --min-age must be kept"
  pass "lock-reap: an aged dead-holder metadata lock is reaped and logged; a young one is kept"
}

test_reused_pid_reaped_live_holder_kept() {
  local state out live
  state="$TMP_ROOT/reuse/state"; mkdir -p "$state"
  sleep 60 & live=$!
  # Same live pid, two records: one written long before the process started
  # (cannot be its holder), one written after it started (could be).
  make_lock "$state/.meta-reused.lock" "$live" 202001010000
  sleep 2
  make_lock "$state/.meta-held.lock" "$live"
  out=$(run_reap "$state" --min-age 0)
  kill -0 "$live" 2>/dev/null || fail "fixture process died; the divergence would be vacuous"
  [ ! -L "$state/.meta-reused.lock" ] || fail "a lock whose pid was recycled by a younger process was kept"
  assert_contains "$out" "reason=reused" "pid reuse should be named in the log"
  [ -L "$state/.meta-held.lock" ] || fail "a live holder that predates its record must never be reaped"
  kill "$live" 2>/dev/null; wait "$live" 2>/dev/null
  pass "lock-reap: a recycled pid is reaped as reused while a genuine live holder is kept"
}

test_inbox_swept_watch_lock_untouched() {
  local state out dead watch_owner
  state="$TMP_ROOT/scope/state"; mkdir -p "$state/t1.inbox/handled"
  dead=$(dead_pid)
  make_lock "$state/t1.inbox/.seq.lock" "$dead" 202001010000
  make_lock "$state/.watch.lock" "$dead" 202001010000
  watch_owner=$(readlink "$state/.watch.lock")
  out=$(run_reap "$state" --min-age 60)
  [ ! -L "$state/t1.inbox/.seq.lock" ] || fail "a stale inbox sequence lock was not reaped"
  assert_contains "$out" "reaped $state/t1.inbox/.seq.lock pid=$dead reason=dead" \
    "the inbox lock reap should be logged"
  [ -L "$state/.watch.lock" ] && [ -d "$watch_owner" ] \
    || fail "the watcher lock is outside the sweep's scope and must be untouched"
  pass "lock-reap: inbox sequence locks are swept; the watcher lock is never touched"
}

test_other_users_live_holder_is_kept() {
  local state out
  if [ "$(id -u)" = 0 ]; then
    pass "lock-reap: skip other-user holder case (running as root, kill -0 1 cannot answer EPERM)"
    return 0
  fi
  kill -0 1 2>/dev/null && fail "fixture assumption broken: kill -0 1 succeeded for a non-root user"
  state="$TMP_ROOT/eperm/state"; mkdir -p "$state"
  make_lock "$state/.meta-foreign.lock" 1
  out=$(run_reap "$state" --min-age 0)
  [ -L "$state/.meta-foreign.lock" ] \
    || fail "a lock held by another user's live process was reaped as dead: $out"
  pass "lock-reap: a holder owned by another user (EPERM) is alive and its lock is kept"
}

test_watcher_runs_sweep_quietly() {
  local state fakebin out dead pid i
  state="$TMP_ROOT/watcher/state"; mkdir -p "$state"
  fakebin="$TMP_ROOT/watcher/fakebin"; mkdir -p "$fakebin"
  dead=$(dead_pid)
  make_lock "$state/.meta-stranded.lock" "$dead" 202001010000
  out="$TMP_ROOT/watcher/watch.out"
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_HOME="${state%/state}" \
    FM_POLL=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_HOME_SUMMARY_INTERVAL=999999 \
    "$ROOT/bin/fm-watch.sh" > "$out" 2>/dev/null &
  pid=$!
  i=0
  while [ "$i" -lt 150 ]; do
    grep -q "lock-reap: reaped $state/.meta-stranded.lock" "$state/.watch-triage.log" 2>/dev/null && break
    sleep 0.1
    i=$((i + 1))
  done
  kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
  grep -q "lock-reap: reaped $state/.meta-stranded.lock" "$state/.watch-triage.log" 2>/dev/null \
    || fail "the watcher did not run the stale-lock sweep into its triage log"
  [ ! -L "$state/.meta-stranded.lock" ] || fail "the watcher sweep left the stranded lock"
  [ ! -s "$out" ] || fail "a lock sweep must not wake firstmate:"$'\n'"$(cat "$out")"
  pass "lock-reap: the watcher sweeps stranded locks on its cadence without waking firstmate"
}

test_dead_holder_reaped_after_min_age
test_reused_pid_reaped_live_holder_kept
test_inbox_swept_watch_lock_untouched
test_other_users_live_holder_is_kept
test_watcher_runs_sweep_quietly
