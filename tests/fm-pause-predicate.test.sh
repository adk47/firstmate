#!/usr/bin/env bash
# tests/fm-pause-predicate.test.sh - behavior tests for the machine-checkable
# pause declaration (bin/fm-pause-lib.sh) and the sweep that reports the pauses
# whose reason no longer holds (bin/fm-pause-sweep.sh).
#
# A `paused:` lane is idle on the strength of a claim nobody can check: the
# reason resolved two days ago and the pause looks exactly like one that clears
# in a minute. These tests pin the contract that fixes it - a pause carries its
# own predicate and expiry, a pause without them is not a declared wait, and a
# reader can settle the claim without waking the lane.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SWEEP="$ROOT/bin/fm-pause-sweep.sh"

# The libraries are the units under test here; sourcing them directly is the
# public interface (bin/fm-pause-sweep.sh sources the same two files).
# shellcheck source=bin/fm-classify-lib.sh
. "$ROOT/bin/fm-classify-lib.sh"
# shellcheck source=bin/fm-pause-lib.sh
. "$ROOT/bin/fm-pause-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-pause-predicate-tests)

VALID_LINE='paused [key=pr-77]: waiting for the review verdict predicate=grep -q APPROVED plan.txt expires=2026-03-01T00:00:00Z'

test_record_and_parse_round_trip() {
  local dir statusf
  dir="$TMP_ROOT/round-trip"
  mkdir -p "$dir"
  statusf="$dir/lane.status"
  : > "$statusf"

  fm_pause_record "$statusf" lane1 'waiting for the review verdict' \
    'grep -q APPROVED plan.txt && echo pending' '2026-03-01T00:00:00Z' \
    || fail "fm_pause_record refused a well-formed pause"

  local line
  line=$(tail -1 "$statusf")
  assert_contains "$line" 'paused [key=lane1]: waiting for the review verdict' \
    "the recorded line does not carry the verb, key, and reason"
  assert_contains "$line" 'predicate=grep -q APPROVED plan.txt && echo pending' \
    "the recorded line does not carry the predicate verbatim"
  assert_contains "$line" 'expires=2026-03-01T00:00:00Z' \
    "the recorded line does not carry the expiry"

  fm_pause_parse "$line" || fail "fm_pause_parse rejected a line this library wrote"
  [ "$FM_PAUSE_KEY" = lane1 ] || fail "parsed key was '$FM_PAUSE_KEY', not 'lane1'"
  [ "$FM_PAUSE_WHY" = 'waiting for the review verdict' ] \
    || fail "parsed reason was '$FM_PAUSE_WHY'"
  [ "$FM_PAUSE_PREDICATE" = 'grep -q APPROVED plan.txt && echo pending' ] \
    || fail "parsed predicate was '$FM_PAUSE_PREDICATE'"
  [ "$FM_PAUSE_EXPIRES" = '2026-03-01T00:00:00Z' ] \
    || fail "parsed expiry was '$FM_PAUSE_EXPIRES'"
  pass "a recorded pause reads back as the same key, reason, predicate, and expiry"
}

test_parse_ignores_lines_that_are_not_pauses() {
  local statusf line
  statusf="$TMP_ROOT/not-a-pause.status"
  printf 'blocked [key=x]: predicate=true expires=2030-01-01T00:00:00Z\n' > "$statusf"
  line=$(tail -1 "$statusf")
  if fm_pause_parse "$line"; then
    fail "fm_pause_parse accepted a blocked line as a pause"
  fi
  [ -z "$FM_PAUSE_PREDICATE" ] || fail "a refused line still published a predicate"
  pass "a non-pause line is refused and publishes no fields"
}

# A refusal is exit 2 with nothing written. Local because the shared helper only
# compares codes it was handed, and each case here owes the same expectation.
refused() {  # <label> <command...>
  local label=$1 rc
  shift
  "$@" >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq 2 ] || fail "$label: expected refusal (exit 2), got $rc"
}

test_record_refuses_an_unreadable_record() {
  local dir statusf
  dir="$TMP_ROOT/refusals"
  mkdir -p "$dir"
  statusf="$dir/lane.status"
  : > "$statusf"

  refused "a key the fold could never match" fm_pause_record "$statusf" 'bad key' why 'true' '2026-03-01T00:00:00Z'
  refused "an expiry that is not a timestamp" fm_pause_record "$statusf" lane why 'true' 'next tuesday'
  refused "an empty predicate" fm_pause_record "$statusf" lane why '' '2026-03-01T00:00:00Z'
  refused "an empty reason" fm_pause_record "$statusf" lane '' 'true' '2026-03-01T00:00:00Z'
  refused "a missing status directory" fm_pause_record "$dir/absent/lane.status" lane why 'true' '2026-03-01T00:00:00Z'

  [ ! -s "$statusf" ] || fail "a refused record was still written: $(cat "$statusf")"
  pass "a pause the reader could not read back is refused and nothing is written"
}

test_the_default_bound_is_a_real_bound() {
  [ "$FM_PAUSE_CHECK_TIMEOUT_SECS_DEFAULT" = 60 ] \
    || fail "the pause predicate bound is $FM_PAUSE_CHECK_TIMEOUT_SECS_DEFAULT, not 60 seconds"
  pass "the documented 60 second predicate bound is the one in force"
}

test_check_verdicts() {
  local start elapsed
  if ! fm_pause_check 'true'; then
    fail "a holding predicate (exit 0) was not reported as holding"
  fi

  fm_pause_check 'exit 1'
  case "$?" in
    1) ;;
    *) fail "a resolved predicate (exit 1) was not reported as resolved" ;;
  esac

  fm_pause_check 'exit 7'
  case "$?" in
    2) ;;
    *) fail "a predicate exiting 7 was not reported as unreadable" ;;
  esac

  fm_pause_check 'definitely-not-a-command' 2>/dev/null
  case "$?" in
    2) ;;
    *) fail "a predicate naming a missing command was not reported as unreadable" ;;
  esac

  fm_pause_check ''
  case "$?" in
    2) ;;
    *) fail "an empty predicate was not reported as unreadable" ;;
  esac

  # A hung predicate must never wedge a tick: the bound answers, and its
  # convention for "the bound was hit" is never mistaken for "still holding".
  start=$(date +%s)
  fm_pause_check 'sleep 30' 1
  case "$?" in
    2) ;;
    *) fail "a predicate that outlived its bound was not reported as unreadable" ;;
  esac
  elapsed=$(( $(date +%s) - start ))
  [ "$elapsed" -lt 15 ] || fail "a hung predicate ran ${elapsed}s past its 1s bound"
  pass "holding, resolved, unreadable, and bound-hit predicates each report their own verdict"
}

test_expiry_clock() {
  if ! fm_pause_expired '2020-01-01T00:00:00Z'; then
    fail "an expiry in the past was not reported as passed"
  fi

  fm_pause_expired '2099-01-01T00:00:00Z'
  case "$?" in
    1) ;;
    *) fail "an expiry in the future was reported as passed" ;;
  esac

  fm_pause_expired 'not-a-timestamp'
  case "$?" in
    2) ;;
    *) fail "an unreadable expiry was not reported as unreadable" ;;
  esac

  if ! fm_pause_expired '2026-03-01T00:00:00Z' 1772323200; then
    fail "an expiry at the given instant was not reported as passed"
  fi
  pass "the expiry clock reports passed, ahead, and unreadable expiries"
}

test_a_predicate_pause_is_a_declared_wait() {
  local statusf open
  statusf="$TMP_ROOT/declared-wait.status"
  printf '%s\n' "$VALID_LINE" > "$statusf"
  open=$(status_open_decisions "$statusf")
  if [ -n "$open" ]; then
    fail "a pause carrying its own predicate and expiry still opened a decision: $open"
  fi
  pass "a pause carrying predicate= and expires= is a declared wait, not an open decision"
}

test_a_pause_without_evidence_is_still_not_a_declared_wait() {
  local statusf open
  statusf="$TMP_ROOT/evidence-less.status"
  printf 'paused [key=winback]: waiting for the next send window\n' > "$statusf"
  open=$(status_open_decisions "$statusf")
  case "$open" in
    *winback*blocked*paused\ without\ a\ wake\ time*) ;;
    *) fail "a bare pause stopped being surfaced as blocked: $open" ;;
  esac

  # Half a declaration is not a declaration: the predicate without an expiry can
  # answer 0 forever, which is the silent sleep this contract exists to end.
  printf 'paused [key=winback]: waiting predicate=true\n' > "$statusf"
  open=$(status_open_decisions "$statusf")
  case "$open" in
    *winback*blocked*) ;;
    *) fail "a pause with a predicate but no expiry was treated as a declared wait: $open" ;;
  esac

  # The two documented admissions keep their shape and need no fields.
  printf 'paused [key=vendor]: rate-limit reset until 05:30Z\n' > "$statusf"
  [ -z "$(status_open_decisions "$statusf")" ] \
    || fail "a pause naming its UTC wake time stopped being a declared wait"
  printf 'paused [key=gateway-503]: gateway still returning transient errors\n' > "$statusf"
  [ -z "$(status_open_decisions "$statusf")" ] \
    || fail "the documented gateway keep-alive stopped being a declared wait"
  pass "a pause with no predicate and no documented admission is still surfaced as blocked"
}

# The watcher labels an absorbed declared wait with the pause's OWN deadline
# (`declared wait until HH:MMZ (Nm remaining)`), which is why the label is a pure
# function of the line and a wall-clock epoch rather than prose assembled at the
# call site. Both the clock and its absence are pinned here: a future wait counts
# down, a stale one reads as due, and a pause naming no time yields no label at
# all so no countdown is ever invented.
test_wait_label_names_the_pauses_own_deadline() {
  local label now
  now=$(date -u -d "$(date -u +%Y-%m-%d) 05:00:00" +%s) \
    || fail "date(1) could not express today's 05:00Z"
  label=$(status_pause_wait_label 'paused [key=vendor]: rate-limit reset until 05:30Z' "$now") \
    || fail "a pause naming its wake time produced no label"
  [ "$label" = '05:30Z (30m remaining)' ] \
    || fail "a wait 30 minutes out was labelled '$label'"

  now=$(( now + 31 * 60 ))
  label=$(status_pause_wait_label 'paused [key=vendor]: rate-limit reset until 05:30Z' "$now") \
    || fail "a pause whose wake time passed produced no label"
  [ "$label" = '05:30Z (due now)' ] \
    || fail "a wake time already behind us was labelled '$label'"

  now=$(date -u -d '2029-12-31 23:00:00' +%s) || fail "date(1) could not express 2029-12-31T23:00Z"
  label=$(status_pause_wait_label 'paused [key=release]: until 2030-01-01T00:00Z' "$now") \
    || fail "a paused line with a dated wake time produced no label"
  [ "$label" = '00:00Z (60m remaining)' ] \
    || fail "a dated wake time was labelled '$label'"

  label=$(status_pause_wait_label 'paused [key=winback]: waiting for the next send window' "$now")
  [ -z "$label" ] || fail "a pause naming no wake time was given the label '$label'"
  if status_pause_wait_label 'paused [key=winback]: waiting for the next send window' "$now" >/dev/null; then
    fail "a pause naming no wake time reported a label status"
  fi
  pass "the wait label names the pause's own deadline, reads a passed one as due, and invents nothing without one"
}

# A sweep case: <name> <task> <status-content>, then run the sweep over it.
sweep_case() {  # <name> <task> <line> [<extra-line>...]
  local name=$1 task=$2 line=$3 dir
  shift 3
  dir="$TMP_ROOT/$name"
  mkdir -p "$dir/state"
  printf '%s\n' "$line" > "$dir/state/$task.status"
  while [ $# -gt 0 ]; do
    printf '%s\n' "$1" >> "$dir/state/$task.status"
    shift
  done
  printf '%s\n' "$dir"
}

test_sweep_reports_a_resolved_pause() {
  local dir out
  dir=$(sweep_case resolved sweep-lane \
    'paused [key=pr-77]: waiting for the review verdict predicate=exit 1 expires=2099-01-01T00:00:00Z')
  out=$(FM_STATE_OVERRIDE="$dir/state" "$SWEEP") || fail "the sweep failed on a resolved pause"
  assert_contains "$out" 'RESUME sweep-lane predicate resolved (waiting for the review verdict)' \
    "the sweep did not report the resolved pause with its task and reason"
  pass "the sweep reports a pause whose predicate says the reason resolved"
}

test_sweep_reports_an_unreadable_predicate() {
  local dir out
  dir=$(sweep_case unreadable sweep-lane \
    'paused [key=pr-77]: waiting on the forge predicate=exit 9 expires=2099-01-01T00:00:00Z')
  out=$(FM_STATE_OVERRIDE="$dir/state" "$SWEEP") || fail "the sweep failed on an unreadable predicate"
  assert_contains "$out" 'RESUME sweep-lane predicate unreadable (waiting on the forge)' \
    "a predicate that could not be read was not reported as a resume"
  pass "the sweep treats an unreadable predicate as a finished pause and says so"
}

test_sweep_reports_an_expired_pause() {
  local dir out
  dir=$(sweep_case expired sweep-lane \
    'paused [key=pr-77]: waiting forever predicate=exit 0 expires=2020-01-01T00:00:00Z')
  out=$(FM_STATE_OVERRIDE="$dir/state" "$SWEEP") || fail "the sweep failed on an expired pause"
  assert_contains "$out" 'RESUME sweep-lane expired at 2020-01-01T00:00:00Z' \
    "a pause past its expiry was not reported"
  pass "the sweep reports a pause whose expiry passed even while its predicate holds"
}

test_sweep_reports_an_invalid_pause() {
  local dir out
  dir=$(sweep_case invalid sweep-lane \
    'paused [key=winback]: waiting for the next send window')
  out=$(FM_STATE_OVERRIDE="$dir/state" "$SWEEP") || fail "the sweep failed on an invalid pause"
  assert_contains "$out" 'INVALID_PAUSE sweep-lane paused [key=winback]: waiting for the next send window' \
    "a pause with no predicate, no expiry, and no documented admission was not refused"
  pass "the sweep names a pause that is not a declared wait as INVALID_PAUSE"
}

test_sweep_leaves_a_holding_pause_alone() {
  local dir out
  dir=$(sweep_case holding sweep-lane \
    'paused [key=pr-77]: waiting for the review verdict predicate=exit 0 expires=2099-01-01T00:00:00Z')
  out=$(FM_STATE_OVERRIDE="$dir/state" "$SWEEP") || fail "the sweep failed on a holding pause"
  [ -z "$out" ] || fail "a pause that still holds was reported: $out"
  pass "a pause whose predicate still holds and whose expiry is ahead is left alone"
}

test_sweep_ignores_unpaused_tasks_and_writes_nothing() {
  local dir out before after
  dir=$(sweep_case writes-nothing working-lane 'working: building the fix')
  printf '%s\n' \
    'paused [key=pr-77]: waiting for the review verdict predicate=exit 1 expires=2099-01-01T00:00:00Z' \
    >> "$dir/state/resolved-lane.status"
  before=$(cat "$dir/state/resolved-lane.status")
  out=$(FM_STATE_OVERRIDE="$dir/state" "$SWEEP") || fail "the sweep failed"
  assert_contains "$out" 'RESUME resolved-lane' "the sweep missed the paused lane"
  assert_not_contains "$out" 'working-lane' "the sweep reported a task that is not paused"
  after=$(cat "$dir/state/resolved-lane.status")
  [ "$before" = "$after" ] || fail "the sweep rewrote a status log it must only read"
  local f count=0
  for f in "$dir/state"/*; do
    count=$((count + 1))
    case "$f" in
      *.status) ;;
      *) fail "the sweep left non-status state beside the logs: ${f##*/}" ;;
    esac
  done
  [ "$count" -eq 2 ] || fail "the sweep left $count entries in the state directory, not 2"
  pass "the sweep reads and reports, never writing a status log or a side state file"
}

test_sweep_self_test() {
  local out
  out=$("$SWEEP" --self-test) || fail "the sweep self-test did not exit 0"
  assert_contains "$out" 'RESUME ' "the self-test did not print a RESUME line"
  pass "the sweep self-test prints a synthetic resume line and exits 0"
}

test_record_and_parse_round_trip
test_parse_ignores_lines_that_are_not_pauses
test_record_refuses_an_unreadable_record
test_the_default_bound_is_a_real_bound
test_check_verdicts
test_expiry_clock
test_a_predicate_pause_is_a_declared_wait
test_wait_label_names_the_pauses_own_deadline
test_a_pause_without_evidence_is_still_not_a_declared_wait
test_sweep_reports_a_resolved_pause
test_sweep_reports_an_unreadable_predicate
test_sweep_reports_an_expired_pause
test_sweep_reports_an_invalid_pause
test_sweep_leaves_a_holding_pause_alone
test_sweep_ignores_unpaused_tasks_and_writes_nothing
test_sweep_self_test
