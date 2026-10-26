#!/usr/bin/env bash
# tests/fm-leave-stopped.test.sh - the durable "leave it stopped" marker
# (bin/fm-leave-stopped.sh): mark, clear, and show through the executable; the
# refusals that keep it the captain's call (exact task id, main actor only, a
# working task is not stopped, a one-line reason); the relaunch refusal
# bin/fm-control.sh owes while the marker stands. The watcher's own silence for a
# marked task is proven in tests/fm-watch-triage.test.sh
# (test_left_stopped_task_pane_never_realarms), and teardown's removal of the
# marker in tests/fm-teardown.test.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LEAVE="$ROOT/bin/fm-leave-stopped.sh"
CONTROL="$ROOT/bin/fm-control.sh"
TMP_ROOT=$(fm_test_tmproot fm-leave-stopped)

# A home with one recorded task and a hermetic fm-crew-state.sh whose verdict
# FM_FAKE_CREW_STATE sets (the same seam bin/fm-classify-lib.sh documents).
make_home() {  # <name> <task-id>
  local name=$1 id=$2 home
  home="$TMP_ROOT/$name"
  mkdir -p "$home/state" "$home/data" "$home/config" "$home/fakebin"
  printf 'window=test:fm-%s\nkind=ship\nproject=%s/projects/p\nharness=pi\n' "$id" "$home" > "$home/state/$id.meta"
  cat > "$home/fakebin/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${FM_FAKE_CREW_STATE:-state: unknown · source: none · no current-state source available}"
SH
  chmod +x "$home/fakebin/fm-crew-state.sh"
  printf '%s\n' "$home"
}

leave() {  # <home> <args...>
  local home=$1
  shift
  FM_HOME="$home" FM_CREW_STATE_BIN="$home/fakebin/fm-crew-state.sh" "$LEAVE" "$@"
}

test_mark_show_clear_round_trip() {
  local home out status marker
  home=$(make_home round-trip drawer)
  marker="$home/state/drawer.stopped"

  out=$(leave "$home" drawer show 2>&1); status=$?
  expect_code 1 "$status" "show on an unmarked task must exit 1"
  case "$out" in *"not marked"*) ;; *) fail "show on an unmarked task did not say so: $out" ;; esac
  [ ! -e "$marker" ] || fail "show created a marker"

  out=$(leave "$home" drawer mark --reason "captain: leave the AI drawer worker stopped" 2>&1); status=$?
  expect_code 0 "$status" "mark on a dead task must succeed: $out"
  [ -f "$marker" ] || fail "mark did not write state/drawer.stopped"
  grep -Fxq 'schema=fm-leave-stopped.v1' "$marker" || fail "marker lacks its schema line: $(cat "$marker")"
  grep -Eq '^at=[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' "$marker" || fail "marker lacks a UTC timestamp: $(cat "$marker")"
  grep -Fxq 'reason=captain: leave the AI drawer worker stopped' "$marker" || fail "marker lacks the captain's reason: $(cat "$marker")"
  case "$out" in *"state/drawer.stopped"*) ;; *) fail "mark did not name the marker it wrote: $out" ;; esac
  [ -z "$(find "$home/state" -name '.drawer.stopped.*' 2>/dev/null)" ] || fail "mark left its temp file behind"

  out=$(leave "$home" drawer show 2>&1); status=$?
  expect_code 0 "$status" "show on a marked task must exit 0: $out"
  case "$out" in *"reason=captain: leave the AI drawer worker stopped"*) ;; *) fail "show did not print the marker: $out" ;; esac

  # Re-marking replaces the reason rather than refusing: the captain may restate.
  out=$(leave "$home" drawer mark --reason="still leave it" 2>&1); status=$?
  expect_code 0 "$status" "re-mark must succeed: $out"
  grep -Fxq 'reason=still leave it' "$marker" || fail "re-mark did not replace the reason: $(cat "$marker")"

  out=$(leave "$home" drawer clear 2>&1); status=$?
  expect_code 0 "$status" "clear must succeed: $out"
  [ ! -e "$marker" ] || fail "clear left the marker behind"
  out=$(leave "$home" drawer clear 2>&1); status=$?
  expect_code 0 "$status" "clear on an unmarked task is idempotent: $out"
  case "$out" in *"nothing to clear"*) ;; *) fail "idempotent clear did not say so: $out" ;; esac
  pass "mark writes the schema, timestamp, and reason; show reads it back; clear removes it idempotently"
}

test_mark_refuses_a_working_task_and_touches_nothing() {
  local home out status
  home=$(make_home working drawer)
  out=$(FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)' \
    leave "$home" drawer mark --reason "leave it" 2>&1); status=$?
  expect_code 2 "$status" "mark on a working task must refuse"
  case "$out" in *"reads as working"*"fm-control.sh drawer exit"*) ;; *) fail "the working refusal did not explain itself or name the stop command: $out" ;; esac
  [ ! -e "$home/state/drawer.stopped" ] || fail "a refused mark still wrote the marker"

  # A busy pane is the other positive-evidence source; a stopped, paused, or
  # unreadable verdict is not evidence of work and is accepted.
  out=$(FM_FAKE_CREW_STATE='state: working · source: pane · busy' leave "$home" drawer mark --reason "leave it" 2>&1); status=$?
  expect_code 2 "$status" "mark on a busy-pane task must refuse: $out"
  out=$(FM_FAKE_CREW_STATE='state: paused · source: status-log · waiting' leave "$home" drawer mark --reason "leave it" 2>&1); status=$?
  expect_code 0 "$status" "mark on a paused task must be accepted: $out"
  pass "mark refuses a task with positive evidence of work and accepts every other verdict"
}

test_refusals_keep_it_the_captains_call() {
  local home out status
  home=$(make_home refusals drawer)

  out=$(leave "$home" drawer mark 2>&1); status=$?
  expect_code 2 "$status" "mark without --reason must refuse"
  case "$out" in *"requires --reason"*) ;; *) fail "missing-reason refusal was not explained: $out" ;; esac

  out=$(leave "$home" drawer mark --reason "$(printf 'two\nlines')" 2>&1); status=$?
  expect_code 2 "$status" "a multi-line reason must refuse"
  [ ! -e "$home/state/drawer.stopped" ] || fail "a refused multi-line reason still wrote the marker"

  out=$(leave "$home" nope mark --reason r 2>&1); status=$?
  expect_code 2 "$status" "an unrecorded task id must refuse"
  case "$out" in *"no task 'nope'"*) ;; *) fail "unknown-task refusal was not explained: $out" ;; esac
  [ ! -e "$home/state/nope.stopped" ] || fail "an unrecorded task got a marker"

  out=$(leave "$home" fm-drawer mark --reason r 2>&1); status=$?
  expect_code 2 "$status" "a window label must refuse"
  case "$out" in *"window label"*"'drawer'"*) ;; *) fail "window-label refusal did not point at the task id: $out" ;; esac

  out=$(leave "$home" "../drawer" mark --reason r 2>&1); status=$?
  expect_code 2 "$status" "a path-shaped id must refuse"
  out=$(leave "$home" drawer park 2>&1); status=$?
  expect_code 2 "$status" "an unknown verb must refuse"
  out=$(leave "$home" drawer clear --reason r 2>&1); status=$?
  expect_code 2 "$status" "--reason on clear must refuse"

  # The supervision branch never records the captain's order; main does.
  out=$(FM_SUPERVISION_ACTOR=branch leave "$home" drawer mark --reason r 2>&1); status=$?
  expect_code 6 "$status" "the branch actor must be refused on mark"
  case "$out" in *"supervision branch never performs this action"*) ;; *) fail "branch refusal was not the role-partition message: $out" ;; esac
  [ ! -e "$home/state/drawer.stopped" ] || fail "the branch actor wrote the marker"
  leave "$home" drawer mark --reason r >/dev/null 2>&1 || fail "main could not mark after the branch refusal"
  out=$(FM_SUPERVISION_ACTOR=branch leave "$home" drawer clear 2>&1); status=$?
  expect_code 6 "$status" "the branch actor must be refused on clear"
  [ -e "$home/state/drawer.stopped" ] || fail "the branch actor cleared the marker"
  out=$(FM_SUPERVISION_ACTOR=branch leave "$home" drawer show 2>&1); status=$?
  expect_code 0 "$status" "the branch may read the marker: $out"
  pass "mark and clear refuse an unrecorded or path-shaped id, a missing or multi-line reason, and the branch actor, while show stays readable"
}

test_control_relaunch_is_refused_while_the_marker_stands() {
  local home out status
  home=$(make_home control drawer)
  leave "$home" drawer mark --reason "captain: leave it stopped" >/dev/null 2>&1 || fail "could not mark"
  out=$(FM_HOME="$home" "$CONTROL" drawer relaunch --note "progress" 2>&1); status=$?
  [ "$status" -ne 0 ] || fail "relaunch succeeded on a task left stopped: $out"
  case "$out" in
    *"left stopped on the captain's order"*"captain: leave it stopped"*"fm-leave-stopped.sh drawer clear"*) ;;
    *) fail "relaunch refusal did not name the order, its reason, and the clear command: $out" ;;
  esac
  [ -f "$home/state/drawer.meta" ] || fail "the refused relaunch disturbed the task record"
  grep -Fxq 'harness=pi' "$home/state/drawer.meta" || fail "the refused relaunch rewrote the task record"
  [ -e "$home/state/drawer.stopped" ] || fail "the refused relaunch removed the marker"

  # Once the order is lifted, relaunch gets past this gate (and on to its
  # ordinary endpoint validation, which this bare record fails for other reasons).
  leave "$home" drawer clear >/dev/null 2>&1 || fail "could not clear"
  out=$(FM_HOME="$home" "$CONTROL" drawer relaunch --note "progress" 2>&1) || true
  case "$out" in *"left stopped"*) fail "relaunch still cited the lifted order: $out" ;; esac
  pass "fm-control refuses relaunch while a task is left stopped, naming the order and the clear command, and stops citing it once cleared"
}

test_mark_show_clear_round_trip
test_mark_refuses_a_working_task_and_touches_nothing
test_refusals_keep_it_the_captains_call
test_control_relaunch_is_refused_while_the_marker_stands
