#!/usr/bin/env bash
# tests/fm-board-audit.test.sh - behavior tests for bin/fm-board-audit.sh, the
# registered check that wakes firstmate when the board is not being driven.
#
# Every case builds a throwaway home, moves the clock with FM_BOARD_NOW, and
# asserts on the one line the check prints (or on its silence) and on whether a
# later poll still prints it.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

AUDIT_BIN="$ROOT/bin/fm-board-audit.sh"
BOARD_BIN="$ROOT/bin/fm-board.sh"

TMP_ROOT=$(fm_test_tmproot fm-board-audit-tests)
T0=$(date +%s)

HOME_DIR=

new_home() {  # <name>
  HOME_DIR="$TMP_ROOT/$1"
  mkdir -p "$HOME_DIR/state"
}

# The board is stamped at T0 unless a case moves the clock itself, so the idle
# arithmetic below never depends on how long the suite took to reach a line.
board() {
  FM_HOME="$HOME_DIR" FM_DATA_OVERRIDE="$HOME_DIR/data" FM_BOARD_NOW="${FM_BOARD_NOW:-$T0}" \
    "$BOARD_BIN" "$@"
}

# audit <seconds after T0> [<action>]
audit() {
  FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_BOARD_NOW=$((T0 + $1)) "$AUDIT_BIN" "${2:-check}"
}

add_item() {  # <title> [<next action>]
  board add "$1" --check "the $1 check passes" --state "$1 not started" --next "${2:-start $1}" \
    || fail "could not add item '$1'"
}

silent_task() {  # <id> [<kind>]
  fm_write_meta "$HOME_DIR/state/$1.meta" "kind=${2:-ship}"
}

test_a_driven_board_is_silent() {
  local out
  new_home driven
  add_item charts
  out=$(audit 60) || fail "the check failed on a fresh board"
  [ -z "$out" ] || fail "a board advanced a minute ago raised an alarm: $out"
  assert_absent "$HOME_DIR/state/.board-audit" "a clear verdict left a record behind"
  out=$(audit 60 status) || fail "status failed"
  [ "$out" = 'board audit: clear' ] || fail "status did not report a clear board: $out"
  pass "a board that advanced inside the hour is silent"
}

test_an_idle_unblocked_item_raises_the_alarm() {
  local out
  new_home idle
  add_item charts 'rerun the chart build'
  out=$(audit 3540) || fail "the check failed before the idle bound"
  [ -z "$out" ] || fail "the alarm fired before 60 minutes without an advance: $out"
  out=$(audit 3660) || fail "the check failed past the idle bound"
  assert_contains "$out" 'board audit: no item advanced in 61m while item 1 is unblocked' \
    "an unblocked item idle for 61 minutes did not raise the alarm"
  assert_contains "$out" '-> drive item 1 "charts": rerun the chart build' \
    "the alarm did not name the item to drive and its next action"
  [ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = 1 ] || fail "the alarm is not one line: $out"
  pass "an unblocked item with no advance for an hour raises one line naming the item to drive"
}

test_a_blocked_item_suppresses_the_idle_alarm() {
  local out
  new_home blocked
  add_item charts
  board block 1 'refund needs approval' --captain money || fail "block failed"
  out=$(audit 3660) || fail "the check failed on a blocked board"
  [ -z "$out" ] || fail "a board whose only item is blocked raised the idle alarm: $out"
  add_item drift 'commit the nine files'
  out=$(audit 3660) || fail "the check failed with a second open item"
  assert_contains "$out" 'while item 2 is unblocked' "the alarm did not move to the first unblocked item"
  assert_contains "$out" '-> drive item 2 "drift": commit the nine files' \
    "the alarm did not name the unblocked item behind the blocked one"
  pass "a blocked item raises no idle alarm, and the alarm names the next unblocked item instead"
}

test_an_advance_clears_the_alarm() {
  local out
  new_home advance-clears
  add_item charts
  out=$(audit 3660) || fail "the check failed past the idle bound"
  assert_contains "$out" 'no item advanced in 61m' "the alarm did not fire before the advance"
  assert_present "$HOME_DIR/state/.board-audit" "a printed alarm left no record"
  FM_BOARD_NOW=$((T0 + 3700)) board advance 1 'build rerun, range matches' || fail "advance failed"
  out=$(audit 3720) || fail "the check failed after the advance"
  [ -z "$out" ] || fail "the alarm kept firing after the item advanced: $out"
  assert_absent "$HOME_DIR/state/.board-audit" "the cleared alarm left its record behind"
  out=$(audit $((3700 + 3660))) || fail "the check failed an hour after the advance"
  assert_contains "$out" 'no item advanced in 61m' "a later idle hour did not raise a fresh alarm"
  pass "advancing a board item clears the alarm, and a later idle hour raises it again"
}

test_finishing_the_item_clears_the_alarm() {
  local out
  new_home done-clears
  add_item charts
  add_item drift
  out=$(audit 3660) || fail "the check failed past the idle bound"
  assert_contains "$out" 'while item 1 is unblocked' "the alarm did not fire before the item finished"
  FM_BOARD_NOW=$((T0 + 3700)) board 'done' 1 >/dev/null || fail "done failed"
  out=$(audit 3720) || fail "the check failed after done"
  [ -z "$out" ] || fail "the alarm kept firing after the top item finished: $out"
  pass "finishing the top item clears the alarm"
}

test_an_unchanged_alarm_repeats_only_on_the_remind_cadence() {
  local out
  new_home remind
  add_item charts
  out=$(audit 3660) || fail "the first poll failed"
  [ -n "$out" ] || fail "the first poll past the bound was silent"
  out=$(audit 3960) || fail "the second poll failed"
  [ -z "$out" ] || fail "an unchanged alarm was printed again five minutes later: $out"
  out=$(audit $((3660 + 1800))) || fail "the reminder poll failed"
  assert_contains "$out" 'no item advanced in 91m' "the alarm was not repeated after the remind interval"
  out=$(audit 3960 status) || fail "status failed"
  assert_contains "$out" 'no item advanced in 66m' "status did not print the standing verdict inside the remind window"
  pass "an unchanged alarm stays quiet between reminders while status still shows it"
}

test_a_stale_board_raises_the_alarm() {
  local out
  new_home stale
  add_item charts
  board block 1 'waiting on the data vendor' || fail "block failed"
  out=$(audit 10700) || fail "the check failed before the stale bound"
  [ -z "$out" ] || fail "a board unchanged for under three hours raised the alarm: $out"
  out=$(audit 10900) || fail "the check failed past the stale bound"
  assert_contains "$out" 'board audit: board unchanged for 18' "a board unchanged for three hours did not raise the alarm"
  assert_contains "$out" '-> every item is blocked or the board is empty' \
    "the stale alarm on a blocked board did not say what to do"
  pass "a board unchanged for more than three hours raises the alarm"
}

test_more_than_three_silent_tasks_raise_the_alarm() {
  local out
  new_home silent
  add_item charts 'rerun the chart build'
  silent_task lane-a
  silent_task lane-b
  silent_task lane-c
  out=$(audit 1000) || fail "the check failed with three silent tasks"
  [ -z "$out" ] || fail "three tasks without a status line raised the alarm: $out"
  silent_task lane-d
  out=$(audit 0) || fail "the check failed inside the grace window"
  [ -z "$out" ] || fail "tasks recorded a moment ago were counted as silent: $out"
  out=$(audit 1000) || fail "the check failed with four silent tasks"
  assert_contains "$out" 'board audit: 4 tasks have a record and no status line' \
    "four tasks without a status line did not raise the alarm"
  assert_contains "$out" 'lane-a' "the alarm did not name the silent tasks"
  assert_contains "$out" '-> drive item 1 "charts": rerun the chart build' \
    "the silent-task alarm did not name the item to drive"
  printf 'working: setup done\n' > "$HOME_DIR/state/lane-d.status"
  out=$(audit 1000) || fail "the check failed after a task reported"
  [ -z "$out" ] || fail "the alarm kept firing after a task wrote its first status line: $out"
  pass "more than three tasks with a record and no status line raise the alarm, and a first status line clears it"
}

test_secondmates_and_stopped_tasks_are_not_silent_tasks() {
  local out
  new_home silent-exempt
  add_item charts
  silent_task lane-a
  silent_task lane-b
  silent_task lane-c
  silent_task mate-one secondmate
  silent_task lane-held
  : > "$HOME_DIR/state/lane-held.stopped"
  out=$(audit 1000) || fail "the check failed"
  [ -z "$out" ] || fail "a secondmate or a task left stopped was counted as silent: $out"
  pass "a secondmate and a task the captain left stopped are not counted as silent tasks"
}

test_a_repeated_needs_decision_key_is_detected() {
  local out status
  new_home repeat
  add_item charts 'rerun the chart build'
  status="$HOME_DIR/state/lane-a.status"
  printf 'needs-decision [key=dns]: approve the DNS change\n' > "$status"
  printf 'needs-decision [key=cert]: pick the certificate\n' >> "$status"
  out=$(audit 60) || fail "the check failed with single escalations"
  [ -z "$out" ] || fail "two different keys raised once each read as a repeat: $out"
  printf 'working: still waiting\n' >> "$status"
  printf 'needs-decision [key=dns]: approve the DNS change (again)\n' >> "$status"
  out=$(audit 60) || fail "the check failed on a repeated key"
  assert_contains "$out" 'board audit: needs-decision lane-a/dns raised x2 unanswered' \
    "the same key raised twice was not detected"
  assert_not_contains "$out" 'lane-a/cert' "a key raised once was reported as a repeat"
  assert_not_contains "$out" 'defect' "a second raising was reported as a defect"
  assert_contains "$out" '-> drive item 1 "charts": rerun the chart build' \
    "the repeat alarm did not name the item to drive"
  printf 'needs-decision [key=dns]: approve the DNS change (third time)\n' >> "$status"
  out=$(audit 120) || fail "the check failed on a third raising"
  assert_contains "$out" 'defect: needs-decision lane-a/dns raised x3 unanswered' \
    "a third identical escalation was not reported as a defect"
  pass "a needs-decision key raised twice is detected, and a third raising reads as a defect"
}

test_answering_or_holding_the_decision_clears_the_repeat() {
  local out status
  new_home repeat-clears
  add_item charts
  status="$HOME_DIR/state/lane-a.status"
  printf 'needs-decision [key=dns]: approve the DNS change\n' > "$status"
  printf 'needs-decision [key=dns]: approve the DNS change (again)\n' >> "$status"
  out=$(audit 60) || fail "the check failed on a repeated key"
  assert_contains "$out" 'lane-a/dns raised x2' "the repeat was not detected before the answer"
  printf 'resolved [key=dns]: approved, change applied\n' >> "$status"
  out=$(audit 120) || fail "the check failed after the answer"
  [ -z "$out" ] || fail "an answered decision still read as a repeat: $out"
  printf 'needs-decision [key=dns]: a new DNS question\n' >> "$status"
  out=$(audit 180) || fail "the check failed after a fresh raising"
  [ -z "$out" ] || fail "one raising after an answer read as a repeat: $out"
  status="$HOME_DIR/state/lane-b.status"
  printf 'needs-decision [key=refund]: approve the refund\n' > "$status"
  printf 'needs-decision [key=refund]: approve the refund (again)\n' >> "$status"
  out=$(audit 240) || fail "the check failed on a second task's repeat"
  assert_contains "$out" 'lane-b/refund raised x2' "the second task's repeat was not detected"
  printf 'captain-held [key=refund]: held for the captain\n' >> "$status"
  out=$(audit 300) || fail "the check failed after the hold"
  [ -z "$out" ] || fail "a decision held for the captain still read as a repeat: $out"
  pass "an answer or a captain hold closes the key and clears the repeat"
}

test_a_missing_or_invalid_board_is_reported() {
  local out
  new_home no-board
  out=$(audit 60) || fail "the check failed with no board"
  assert_contains "$out" 'board audit: no board -> create data/board.md' \
    "an armed home with no board did not say so"
  mkdir -p "$HOME_DIR/data"
  printf '# Board\n\n1. charts - will look tomorrow\n' > "$HOME_DIR/data/board.md"
  out=$(audit 120) || fail "the check failed on an invalid board"
  assert_contains "$out" 'board audit: board invalid (' "a board that does not parse was not reported"
  assert_contains "$out" 'line 3' "the invalid-board alarm did not carry the bad line"
  pass "a home with no board, or a board that does not parse, is reported instead of read as clear"
}

test_arm_binds_a_shim_that_runs_the_check_and_disarm_removes_it() {
  local out
  new_home arm
  add_item charts 'rerun the chart build'
  out=$(audit 0 arm) || fail "arm failed: $out"
  assert_contains "$out" 'armed: state/board-audit.check.sh' "arm did not report the shim it wrote"
  assert_present "$HOME_DIR/state/board-audit.check.sh" "arm wrote no shim"
  assert_present "$HOME_DIR/state/board-audit.check-trust" "arm did not bind the shim"
  out=$(FM_BOARD_NOW=$((T0 + 3660)) "$HOME_DIR/state/board-audit.check.sh") \
    || fail "the armed shim failed"
  assert_contains "$out" '-> drive item 1 "charts": rerun the chart build' \
    "the armed shim did not run the check against its own home"
  assert_present "$HOME_DIR/state/.board-audit" "the armed shim's alarm left no record"
  out=$(audit 0 disarm) || fail "disarm failed"
  assert_absent "$HOME_DIR/state/board-audit.check.sh" "disarm left the shim"
  assert_absent "$HOME_DIR/state/board-audit.check-trust" "disarm left the trust binding"
  assert_absent "$HOME_DIR/state/.board-audit" "disarm left the record"
  pass "arm writes a bound shim that polls its own home, and disarm removes the shim, binding, and record"
}

test_a_driven_board_is_silent
test_an_idle_unblocked_item_raises_the_alarm
test_a_blocked_item_suppresses_the_idle_alarm
test_an_advance_clears_the_alarm
test_finishing_the_item_clears_the_alarm
test_an_unchanged_alarm_repeats_only_on_the_remind_cadence
test_a_stale_board_raises_the_alarm
test_more_than_three_silent_tasks_raise_the_alarm
test_secondmates_and_stopped_tasks_are_not_silent_tasks
test_a_repeated_needs_decision_key_is_detected
test_answering_or_holding_the_decision_clears_the_repeat
test_a_missing_or_invalid_board_is_reported
test_arm_binds_a_shim_that_runs_the_check_and_disarm_removes_it
