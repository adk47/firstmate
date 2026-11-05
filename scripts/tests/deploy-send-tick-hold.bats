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
