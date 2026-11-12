#!/usr/bin/env bats
# deploy-send-tick-hold.sh — the send-window guard that keeps a deploy out of a tick.
# Lesson behind it: a deploy that starts 9 minutes before the tick is still syncing when it fires;
# the deploy's apply lock only protects an apply that has ALREADY started.

setup() {
  LIB="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/lib/deploy-send-tick-hold.sh"
  TMP="$(mktemp -d)"
  LOCK="$TMP/tick.lock"
  : > "$LOCK"
}

teardown() { rm -rf "$TMP"; }

run_hold() { run bash "$LIB" --lock "$LOCK" "$@"; }

@test "eleven minutes before a tick is a GO" {
  # cadence 7200: 00:00Z + 7080s = 01:58Z, i.e. 120s before the 02:00Z boundary.
  run_hold --now 1762300000 --cadence 7200 --hold-min 10 || true
  base=$(( 1762300000 / 7200 * 7200 ))
  GO_AT=$(( base + 7200 - 660 ))          # 11 minutes before the boundary
  run_hold --now "$GO_AT" --cadence 7200 --hold-min 10
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "ten minutes before a tick is a WAIT, and it says how long" {
  base=$(( 1762300000 / 7200 * 7200 ))
  AT=$(( base + 7200 - 600 ))             # exactly 10 minutes (the boundary is inclusive)
  run_hold --now "$AT" --cadence 7200 --hold-min 10
  [ "$status" -eq 3 ]
  secs="${output%% *}"
  [ "$secs" -eq 660 ]                     # 600 to the boundary + 60 to see the tick start
  [[ "$output" == *"next-tick-in-600s"* ]]
}

@test "exactly on the boundary is a WAIT, not a GO" {
  base=$(( 1762300000 / 7200 * 7200 ))
  run_hold --now "$(( base + 7200 ))" --cadence 7200 --hold-min 10
  [ "$status" -eq 3 ]
}

@test "one minute before a tick is a WAIT (the 04:00Z deploy that met the 04:03Z round)" {
  base=$(( 1762300000 / 7200 * 7200 ))
  run_hold --now "$(( base + 7200 - 60 ))" --cadence 7200 --hold-min 10
  [ "$status" -eq 3 ]
}

@test "a tick holding its flock is a WAIT even mid-window" {
  base=$(( 1762300000 / 7200 * 7200 ))
  MID=$(( base + 3600 ))                  # an hour before the boundary: normally a GO
  run_hold --now "$MID" --cadence 7200 --hold-min 10
  [ "$status" -eq 0 ]
  # now take the flock, the way a running tick does
  ( flock -x 8; sleep 5 ) 8>>"$LOCK" &
  holder=$!
  sleep 0.5
  run_hold --now "$MID" --cadence 7200 --hold-min 10
  [ "$status" -eq 3 ]
  [[ "$output" == *"tick-in-flight"* ]]
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
}

@test "a boundary 9 minutes past with a DELAYED tick is a WAIT (QA #1783 finding 1: the 04:01 deploy, the 04:03 round)" {
  base=$(( 1762300000 / 7200 * 7200 ))
  BOUNDARY=$(( base + 7200 ))
  # The lock file exists (ticks have run before) but its mtime is from the PREVIOUS round: this boundary's tick has
  # not opened it yet. At 04:01 the next boundary is 7140s away, so the pre-boundary check says GO - the old code
  # shipped the deploy and the rsync overlapped the 04:03 audience/ledger read. The file's mtime is the evidence
  # a delayed tick leaves; no evidence means wait out the window and re-check.
  touch -d @$(( BOUNDARY - 7200 + 30 )) "$LOCK"
  run_hold --now "$(( BOUNDARY + 60 ))" --cadence 7200 --hold-min 10
  [ "$status" -eq 3 ]
  [[ "$output" == *"tick-not-yet-started-for-this-boundary"* ]]
  [ "${output%% *}" -eq 600 ]             # 540s left of the window + 60s, so the wait is bounded
  # Past the window we cannot tell a quiet cron from a slow one, and a deploy that never runs is its own failure:
  # the caller's budget decides. 30 minutes after the boundary is a GO.
  run_hold --now "$(( BOUNDARY + 1800 ))" --cadence 7200 --hold-min 10
  [ "$status" -eq 0 ]
  # And once the delayed tick HAS started inside this window (the flock file touched after the boundary), the same
  # instant as the first case is a GO: the boundary's tick ran, and its flock is not held.
  touch -d @$(( BOUNDARY + 120 )) "$LOCK"
  run_hold --now "$(( BOUNDARY + 130 ))" --cadence 7200 --hold-min 10
  [ "$status" -eq 0 ]
}

@test "an absent lock file is a GO (no tick has ever run) and is never created" {
  rm -f "$LOCK"
  base=$(( 1762300000 / 7200 * 7200 ))
  run_hold --now "$(( base + 3600 ))" --cadence 7200 --hold-min 10
  [ "$status" -eq 0 ]
  [ ! -e "$LOCK" ]
}

@test "a nonsense argument is an error, never a silent GO" {
  run_hold --now "soon" --cadence 7200 --hold-min 10
  [ "$status" -eq 2 ]
  run_hold --now 1762300000 --cadence 0 --hold-min 10
  [ "$status" -eq 2 ]
  run_hold --now 1762300000 --cadence 7200 --hold-min ""
  [ "$status" -eq 2 ]
  run bash "$LIB" --nope
  [ "$status" -eq 2 ]
}

# ── The wait that happens BEFORE the locks (deploy-send-tick-wait.sh, 2026-11-12) ──────────
# Four scheduled deploys in five nights died in their first second on "7200 tick-in-flight ... would
# exceed 900s": a held flock was reported as a whole cadence and compared to the budget before one
# sleep. These cases pin the three things the fix must not lose: a tick in flight is STILL a wait,
# a budget that runs out is STILL a refusal, and the gate under the apply lock still does not wait.

WAIT_LIB() { echo "$(dirname "$LIB")/deploy-send-tick-wait.sh"; }
mid_window() { echo $(( 1762300000 / 7200 * 7200 + 3600 )); }   # an hour from either boundary: a GO but for the lock
hold_lock() { ( flock -x 8; sleep "$1" ) 8>>"$LOCK" & HOLDER=$!; sleep 0.5; }
drop_lock() { kill "$HOLDER" 2>/dev/null || true; wait "$HOLDER" 2>/dev/null || true; }

@test "--poll changes the seconds of a tick in flight, never the verdict" {
  hold_lock 5
  run_hold --now "$(mid_window)" --cadence 7200 --hold-min 10
  [ "$status" -eq 3 ]
  [ "$output" = "7200 tick-in-flight" ]          # the gate under the locks: a whole cadence, so it refuses at once
  run_hold --now "$(mid_window)" --cadence 7200 --hold-min 10 --poll 60
  [ "$status" -eq 3 ]                            # still a WAIT - a poll is not a GO
  [ "$output" = "60 tick-in-flight" ]
  drop_lock
}

@test "--poll is an error when it is empty, zero or not a number (never 'no poll', never a GO)" {
  for bad in "" 0 soon -5; do
    run_hold --now "$(mid_window)" --cadence 7200 --hold-min 10 --poll "$bad"
    [ "$status" -eq 2 ]
  done
}

@test "the wait outlasts a tick in flight and then says clear (the nightly deploy that used to die in 1s)" {
  hold_lock 2
  start=$SECONDS
  run bash "$(WAIT_LIB)" --lock "$LOCK" --now "$(mid_window)" --cadence 7200 --hold-min 10 --poll 1 --max 30
  drop_lock
  [ "$status" -eq 0 ]
  [[ "$output" == *"tick-in-flight"* ]]          # it saw the tick ...
  [[ "$output" == *"clear after"* ]]             # ... and waited for it rather than walking past it
  [ $(( SECONDS - start )) -ge 1 ]
}

@test "a tick that outlasts the budget is a REFUSAL, not a GO, and the lock is never taken over" {
  hold_lock 8
  run bash "$(WAIT_LIB)" --lock "$LOCK" --now "$(mid_window)" --cadence 7200 --hold-min 10 --poll 1 --max 2
  [ "$status" -eq 1 ]
  [[ "$output" == *"would exceed the 2s budget"* ]]
  # the tick's flock is still the tick's: a second taker is still refused
  run flock -n -x "$LOCK" true
  [ "$status" -ne 0 ]
  drop_lock
}

@test "the wait is a GO with nothing to wait for, and says nothing" {
  run bash "$(WAIT_LIB)" --lock "$LOCK" --now "$(mid_window)" --cadence 7200 --hold-min 10 --max 900
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "the wait refuses a window it cannot outlast instead of sleeping into it" {
  # ten minutes before a boundary the guard asks for 660s; a 300s budget cannot cover it. No sleep happens.
  base=$(( 1762300000 / 7200 * 7200 ))
  start=$SECONDS
  run bash "$(WAIT_LIB)" --lock "$LOCK" --now "$(( base + 7200 - 600 ))" --cadence 7200 --hold-min 10 --max 300
  [ "$status" -eq 1 ]
  [[ "$output" == *"next-tick-in-600s"* ]]
  [ $(( SECONDS - start )) -lt 5 ]
}

@test "the wait is an error, never a clear, on a bad argument, a zero poll or a guard that cannot decide" {
  run bash "$(WAIT_LIB)" --lock "$LOCK" --now "$(mid_window)"                 # no --max
  [ "$status" -eq 2 ]
  run bash "$(WAIT_LIB)" --lock "$LOCK" --now "$(mid_window)" --max 900 --poll 0
  [ "$status" -eq 2 ]
  run bash "$(WAIT_LIB)" --lock "$LOCK" --now "$(mid_window)" --max 900 --cadence 0   # the guard exits 2
  [ "$status" -eq 2 ]
  [[ "$output" == *"cannot decide"* ]]
  run bash "$(WAIT_LIB)" --max 900 --nope
  [ "$status" -eq 2 ]
}

@test "deploy.sh waits BEFORE it takes the apply lock, and the gate under the locks does not poll" {
  DEPLOY="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/deploy.sh"
  wait_line=$(grep -n 'lib/deploy-send-tick-wait.sh' "$DEPLOY" | head -1 | cut -d: -f1)
  lock_line=$(grep -n '^DEPLOY_APPLY_LOCK_FILE=' "$DEPLOY" | head -1 | cut -d: -f1)
  gate_line=$(grep -n 'lib/deploy-send-tick-hold.sh' "$DEPLOY" | head -1 | cut -d: -f1)
  [ -n "$wait_line" ] && [ -n "$lock_line" ] && [ -n "$gate_line" ]
  # A wait under the apply lock would defer the very tick it is waiting for (spec-deploy-lock-deferral-m1).
  [ "$wait_line" -lt "$lock_line" ]
  [ "$lock_line" -lt "$gate_line" ]
  # The gate stays impatient: no --poll on its call, so a tick in flight there is an immediate refusal.
  # (Counted, not `! grep`: bash exempts a negated command from errexit, so `! ...` here could never fail the test.)
  gate_call="$(sed -n "${gate_line},$(( gate_line + 1 ))p" "$DEPLOY")"
  [[ "$gate_call" == *'--hold-min'* ]]            # we are reading the whole call, both lines of it
  polls="$(grep -c -- '--poll' <<<"$gate_call" || true)"
  [ "$polls" -eq 0 ]
  # and a refused wait is fatal, not a note in the log
  grep -A8 'lib/deploy-send-tick-wait.sh' "$DEPLOY" | grep -q '1) fail "deploy refused'
}

@test "the scheduled deploy does not start inside a send tick's hold window (it did, at 04:00Z, for four nights)" {
  WF="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)/.github/workflows/deploy.yml"
  crons="$(grep -E "^[[:space:]]*- cron: '" "$WF" | sed -E "s/.*cron: '([^']*)'.*/\1/")"
  [ "$(grep -c . <<<"$crons")" -eq 1 ]            # one schedule; a second one needs its own look
  read -r minute hour dom mon dow <<<"$crons"
  [[ "$minute" =~ ^[0-9]+$ ]] && [[ "$hour" =~ ^[0-9]+$ ]]   # a fixed time of day, or this check cannot speak for it
  day=$(( 1762300000 / 86400 * 86400 ))
  # GitHub starts a scheduled run late (04:04Z was typical); every minute of the first ten must be a GO.
  for late in 0 1 4 10; do
    run_hold --now "$(( day + hour * 3600 + minute * 60 + late * 60 ))" --cadence 7200 --hold-min 10
    [ "$status" -eq 0 ]
  done
}
