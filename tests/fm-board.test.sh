#!/usr/bin/env bash
# tests/fm-board.test.sh - behavior tests for bin/fm-board.sh, the board driver,
# and for the agenda line bin/fm-wake-drain.sh prints from it.
#
# Every case drives the real script against a throwaway home and asserts on its
# output, exit code, and what a later command reads back - never on the bytes of
# data/board.md itself, whose shape only the driver owns.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

BOARD_BIN="$ROOT/bin/fm-board.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"

TMP_ROOT=$(fm_test_tmproot fm-board-tests)

HOME_DIR=

new_home() {  # <name>
  HOME_DIR="$TMP_ROOT/$1"
  mkdir -p "$HOME_DIR/state"
}

board() {
  FM_HOME="$HOME_DIR" FM_DATA_OVERRIDE="$HOME_DIR/data" "$BOARD_BIN" "$@"
}

add_item() {  # <title> [<next action>]
  board add "$1" --check "the $1 check passes" --state "$1 not started" --next "${2:-start $1}" \
    || fail "could not add item '$1'"
}

test_next_names_the_first_item_with_its_action_and_check() {
  local out
  new_home next-first
  add_item charts 'rerun the chart build'
  add_item drift
  out=$(board next) || fail "next failed on a board with open items"
  [ "$out" = "1"$'\t'"charts"$'\t'"rerun the chart build"$'\t'"the charts check passes" ] \
    || fail "next did not print item 1 with its next action and check: $out"
  pass "next names the first item with its next action and acceptance check"
}

test_block_makes_next_skip_the_item() {
  local out rc=0
  new_home block-skip
  add_item charts
  add_item drift 'diff the nine files'
  board block 1 'waiting on the upstream release' || fail "block failed"
  out=$(board next) || fail "next failed with one item still open"
  assert_contains "$out" "2"$'\t'"drift"$'\t'"diff the nine files" "next did not move past the blocked item"
  board block 2 'wire transfer needs approval' --captain money || fail "captain-class block failed"
  out=$(board next 2>&1) || rc=$?
  expect_code 1 "$rc" "next on a board whose every item is blocked"
  out=$(board list) || fail "list failed"
  assert_contains "$out" "2"$'\t'"blocked"$'\t'"money" "the captain class was not recorded on the blocked item"
  board unblock 1 || fail "unblock failed"
  out=$(board next) || fail "next failed after unblock"
  assert_contains "$out" "1"$'\t'"charts" "unblock did not return the item to the agenda"
  pass "a blocked item is skipped, an all-blocked board has no next action, and unblock restores it"
}

test_done_removes_the_item_and_renumbers() {
  local out
  new_home done-renumber
  add_item charts
  add_item drift
  add_item drain
  out=$(board 'done' 1) || fail "done failed"
  assert_contains "$out" 'done: charts (check: the charts check passes)' "done did not report the finished item and its check"
  out=$(board list) || fail "list failed after done"
  assert_contains "$out" "1"$'\t'"open"$'\t'"-"$'\t'"0"$'\t'"drift" "the remaining items were not renumbered from 1"
  assert_contains "$out" "2"$'\t'"open"$'\t'"-"$'\t'"0"$'\t'"drain" "the third item did not become item 2"
  assert_not_contains "$out" 'charts' "the finished item is still on the board"
  pass "done removes the item and renumbers the rest in order"
}

test_the_board_holds_five_items_at_most() {
  local rc=0 out i
  new_home five-max
  for i in one two three four five; do add_item "$i"; done
  out=$(board add six --check c --state s --next n 2>&1) || rc=$?
  expect_code 1 "$rc" "adding a sixth item"
  assert_contains "$out" 'the board is full (5 items)' "the sixth add did not say the board is full"
  out=$(board list) || fail "list failed on a full board"
  assert_not_contains "$out" 'six' "a sixth item was written"
  board 'done' 5 >/dev/null || fail "done failed on a full board"
  board add six --check c --state s --next n --at 1 || fail "add failed after an item finished"
  out=$(board next) || fail "next failed after an insert"
  assert_contains "$out" "1"$'\t'"six" "--at 1 did not put the new item first"
  pass "a sixth item is refused until one is finished, and --at sets its place in the order"
}

test_advance_stamps_and_a_restated_item_does_not() {
  local rc=0 out
  new_home advance
  FM_BOARD_NOW=1000 add_item charts
  FM_BOARD_NOW=2000 board advance 1 'build rerun, range matches' --next 'compare the served range' \
    || fail "advance failed"
  out=$(board advanced) || fail "advanced failed"
  [ "$out" = 2000 ] || fail "advance did not stamp the board: $out"
  out=$(board next) || fail "next failed after advance"
  assert_contains "$out" 'compare the served range' "advance did not record the new next action"
  out=$(FM_BOARD_NOW=3000 board advance 1 'build rerun, range matches' 2>&1) || rc=$?
  expect_code 1 "$rc" "advancing an item to its recorded state"
  assert_contains "$out" 'a restated item has not advanced' "the unchanged advance did not say why it was refused"
  out=$(board advanced) || fail "advanced failed after a refused advance"
  [ "$out" = 2000 ] || fail "a restated item moved the advanced stamp: $out"
  FM_BOARD_NOW=4000 board block 1 'waiting on DNS' || fail "block failed"
  out=$(board advanced) || fail "advanced failed after block"
  [ "$out" = 2000 ] || fail "recording a blocker counted as an advance: $out"
  pass "advance stamps the board, and neither a restated item nor a block counts as an advance"
}

test_a_third_escalation_of_one_blocker_is_refused() {
  local rc=0 out
  new_home escalate
  add_item front-door
  out=$(board escalate 1 2>&1) || rc=$?
  expect_code 1 "$rc" "escalating an item with no recorded blocker"
  rc=0
  board block 1 'DNS change needs captain approval' --captain irreversible || fail "block failed"
  out=$(board escalate 1) || fail "the first escalation was refused"
  assert_contains "$out" 'escalation 1 of 2' "the first escalation was not counted"
  out=$(board escalate 1) || fail "the second escalation was refused"
  assert_contains "$out" 'this is the last one' "the second escalation did not say it is the last"
  out=$(board escalate 1 2>&1) || rc=$?
  expect_code 5 "$rc" "a third escalation of the same blocker"
  assert_contains "$out" 'a third raising is a defect' "the refusal did not name the defect"
  out=$(board list) || fail "list failed"
  assert_contains "$out" "1"$'\t'"blocked"$'\t'"irreversible"$'\t'"2" "the refused escalation changed the recorded count"
  board block 1 'registrar account is locked' || fail "re-block with a new reason failed"
  out=$(board escalate 1) || fail "a new blocker could not be escalated"
  assert_contains "$out" 'escalation 1 of 2' "a new blocker did not start its own count"
  pass "a recorded blocker is raised twice at most, and a different blocker starts its own count"
}

test_an_unknown_captain_class_is_refused() {
  local rc=0 out
  new_home class
  add_item charts
  out=$(board block 1 'not sure' --captain security 2>&1) || rc=$?
  expect_code 2 "$rc" "a block with an unknown captain class"
  assert_contains "$out" 'money, irreversible, production-ddl, or legal-signature' "the refusal did not name the four classes"
  out=$(board next) || fail "the refused block still blocked the item"
  for class in money irreversible production-ddl legal-signature; do
    board block 1 'held' --captain "$class" || fail "captain class $class was refused"
  done
  pass "exactly the four captain classes are accepted"
}

test_a_free_prose_board_is_invalid_and_never_rewritten() {
  local rc=0 out before after
  new_home invalid
  mkdir -p "$HOME_DIR/data"
  printf '# Board\n\n1. WEEKLY CHARTS - still serving last week, will look tomorrow\n' > "$HOME_DIR/data/board.md"
  before=$(cat "$HOME_DIR/data/board.md")
  out=$(board next 2>&1) || rc=$?
  expect_code 4 "$rc" "next on a board that is prose"
  assert_contains "$out" 'line 3' "the invalid board did not name its bad line"
  rc=0
  out=$(board add charts --check c --state s --next n 2>&1) || rc=$?
  expect_code 4 "$rc" "add on a board that is prose"
  rc=0
  out=$(board 'done' 1 2>&1) || rc=$?
  expect_code 4 "$rc" "done on a board that is prose"
  after=$(cat "$HOME_DIR/data/board.md")
  [ "$before" = "$after" ] || fail "an invalid board was rewritten"
  pass "a board that is not the exact shape is refused with its line and left untouched"
}

test_a_hand_written_board_of_the_exact_shape_is_read() {
  local out
  new_home handwritten
  mkdir -p "$HOME_DIR/data"
  cat > "$HOME_DIR/data/board.md" <<'EOF'
# Board
<!-- written by hand -->

## 1. charts
- check: served range equals this week
- state: still last week
- next: rerun the build
- blocked: waiting on the data vendor

## 2. drift
- check: zero drifted files
- state: nine files drift
- next: commit the nine files
EOF
  out=$(board next) || fail "a hand-written board of the exact shape was refused"
  assert_contains "$out" "2"$'\t'"drift"$'\t'"commit the nine files"$'\t'"zero drifted files" "the hand-written board was not read in order"
  printf '\n## 4. gap\n- check: c\n- state: s\n- next: n\n' >> "$HOME_DIR/data/board.md"
  out=$(board next 2>&1) && fail "a board whose numbering skips was accepted"
  assert_contains "$out" 'numbered 4 but is item 3' "the numbering error did not say which heading is wrong"
  pass "a hand-written board of the exact shape is read, and a numbering gap is refused"
}

test_no_board_is_reported_as_no_board() {
  local rc=0 out
  new_home absent
  out=$(board next 2>&1) || rc=$?
  expect_code 3 "$rc" "next with no board file"
  out=$(board wake-line) || fail "wake-line failed with no board"
  [ -z "$out" ] || fail "wake-line printed on a home that keeps no board: $out"
  pass "a home with no board reports exit 3 and prints no agenda line"
}

test_wake_line_names_what_the_turn_owes() {
  local out
  new_home wake-line
  add_item charts 'rerun the chart build'
  out=$(board wake-line) || fail "wake-line failed"
  assert_contains "$out" 'BOARD NEXT: item 1 "charts" - next: rerun the chart build | done when: the charts check passes' \
    "the agenda line did not name the item, its next action, and its check"
  board block 1 'refund needs approval' --captain money || fail "block failed"
  out=$(board wake-line) || fail "wake-line failed on a blocked board"
  assert_contains "$out" 'BOARD BLOCKED: all 1 items are blocked (1 waiting on the captain)' \
    "the blocked agenda line did not count the captain-class blocker"
  board 'done' 1 >/dev/null || fail "done failed"
  out=$(board wake-line) || fail "wake-line failed on an empty board"
  assert_contains "$out" 'BOARD EMPTY:' "an empty board did not say so"
  printf 'free prose\n' >> "$HOME_DIR/data/board.md"
  out=$(board wake-line) || fail "wake-line failed on an invalid board"
  assert_contains "$out" 'BOARD INVALID: data/board.md line' "an invalid board did not surface in the agenda line"
  pass "the agenda line reports the next action, an all-blocked board, an empty board, and an invalid one"
}

test_the_wake_drain_prints_the_agenda_line() {
  local dir state out
  dir=$(make_case drain-board)
  state="$dir/state"
  out="$dir/drain.out"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" 2>/dev/null || fail "drain failed on a home with no board"
  if grep -F 'BOARD' "$out" >/dev/null; then
    fail "the drain printed a board line on a home that keeps no board: $(cat "$out")"
  fi
  HOME_DIR=$dir
  add_item charts 'rerun the chart build'
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" 2>/dev/null || fail "drain failed on a home with a board"
  grep -F 'BOARD NEXT: item 1 "charts" - next: rerun the chart build' "$out" >/dev/null \
    || fail "an empty-queue drain did not print the board's next action: $(cat "$out")"
  board block 1 'waiting on DNS' || fail "block failed"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" 2>/dev/null || fail "drain failed on a blocked board"
  grep -F 'BOARD BLOCKED:' "$out" >/dev/null \
    || fail "the drain did not report the all-blocked board: $(cat "$out")"
  pass "every main wake drain prints the board's agenda line, and a home without a board prints none"
}

test_a_wake_drain_prints_the_board_line_before_its_wake_rows() {
  local dir state out board_line row_line count
  dir=$(make_case drain-board-first)
  state="$dir/state"
  HOME_DIR=$dir
  add_item charts 'rerun the chart build'
  append_wake "$state" signal task-a.status 'signal: task-a' || fail "could not append a wake row"
  out="$dir/drain.out"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" 2>/dev/null || fail "drain failed with a queued wake"
  count=$(grep -cF 'BOARD NEXT:' "$out")
  [ "$count" = 1 ] || fail "the drain printed the board line $count times, want exactly once: $(cat "$out")"
  board_line=$(grep -nF 'BOARD NEXT:' "$out" | cut -d: -f1)
  row_line=$(grep -nF "$(printf '\tsignal\ttask-a.status\t')" "$out" | cut -d: -f1)
  [ -n "$row_line" ] || fail "the drain omitted the queued wake row: $(cat "$out")"
  [ "$board_line" -lt "$row_line" ] \
    || fail "the board line came after the wake row (board $board_line, row $row_line): $(cat "$out")"
  pass "a main drain prints its one board line before its wake rows"
}

test_next_names_the_first_item_with_its_action_and_check
test_block_makes_next_skip_the_item
test_done_removes_the_item_and_renumbers
test_the_board_holds_five_items_at_most
test_advance_stamps_and_a_restated_item_does_not
test_a_third_escalation_of_one_blocker_is_refused
test_an_unknown_captain_class_is_refused
test_a_free_prose_board_is_invalid_and_never_rewritten
test_a_hand_written_board_of_the_exact_shape_is_read
test_no_board_is_reported_as_no_board
test_wake_line_names_what_the_turn_owes
test_the_wake_drain_prints_the_agenda_line
test_a_wake_drain_prints_the_board_line_before_its_wake_rows
