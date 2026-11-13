#!/usr/bin/env bash
# tests/fm-leave-stopped.test.sh - the durable "leave it stopped" marker
# (bin/fm-leave-stopped.sh): mark and clear through the executable; the
# refusals that keep it the captain's call (exact task id, main actor only, a
# one-line reason); and the warning, not refusal, on a working reading such as a
# dead Grok terminal's stale busy footer; the refusal of a task whose agent is
# still running, with --force-silence and --exit as the two ways forward (a
# fake process table and a stand-in control plane). The watcher's own silence for a
# marked task is proven in tests/fm-watch-triage.test.sh
# (test_left_stopped_task_pane_never_realarms), and teardown's removal of the
# marker in tests/fm-teardown.test.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LEAVE="$ROOT/bin/fm-leave-stopped.sh"
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

test_mark_clear_round_trip() {
  local home out status marker
  home=$(make_home round-trip drawer)
  marker="$home/state/drawer.stopped"

  out=$(leave "$home" drawer mark --reason "captain: leave the AI drawer worker stopped" 2>&1); status=$?
  expect_code 0 "$status" "mark on a dead task must succeed: $out"
  [ -f "$marker" ] || fail "mark did not write state/drawer.stopped"
  grep -Fxq 'schema=fm-leave-stopped.v1' "$marker" || fail "marker lacks its schema line: $(cat "$marker")"
  grep -Eq '^at=[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' "$marker" || fail "marker lacks a UTC timestamp: $(cat "$marker")"
  grep -Fxq 'reason=captain: leave the AI drawer worker stopped' "$marker" || fail "marker lacks the captain's reason: $(cat "$marker")"
  case "$out" in *"state/drawer.stopped"*) ;; *) fail "mark did not name the marker it wrote: $out" ;; esac
  case "$out" in *warning*) fail "mark on a non-working task warned: $out" ;; esac
  [ -z "$(find "$home/state" -name '.drawer.stopped.*' 2>/dev/null)" ] || fail "mark left its temp file behind"

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
  [ ! -e "$marker" ] || fail "an idempotent clear created a marker"
  pass "mark writes the schema, timestamp, and reason; re-mark replaces it; clear removes it idempotently"
}

test_mark_on_a_stale_working_footer_warns_and_records() {
  local home out status reading marker
  home=$(make_home grok-footer drawer)
  marker="$home/state/drawer.stopped"
  # A Grok worker that dropped to a shell with its last busy footer still on
  # screen keeps reading as working through its pane.
  reading='state: working · source: pane · busy'
  out=$(FM_FAKE_CREW_STATE="$reading" leave "$home" drawer mark --reason "captain: leave the AI drawer worker stopped" 2>&1); status=$?
  expect_code 0 "$status" "mark on a stale working footer must succeed: $out"
  [ -f "$marker" ] || fail "mark on a stale working footer did not write the marker"
  grep -Fxq 'reason=captain: leave the AI drawer worker stopped' "$marker" || fail "marker lacks the captain's reason: $(cat "$marker")"
  case "$out" in
    *warning*"reads as working"*"$reading"*) ;;
    *) fail "mark did not warn with the current reading: $out" ;;
  esac
  grep -Fxq 'harness=pi' "$home/state/drawer.meta" || fail "mark disturbed the task record"

  # A run-step working reading is likewise recorded with the warning.
  out=$(FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)' \
    leave "$home" drawer mark --reason "leave it" 2>&1); status=$?
  expect_code 0 "$status" "mark on a run-step working reading must succeed: $out"
  case "$out" in *warning*"source: run-step"*) ;; *) fail "run-step reading was not named in the warning: $out" ;; esac
  grep -Fxq 'reason=leave it' "$marker" || fail "the run-step mark did not record its reason: $(cat "$marker")"
  pass "mark records the captain's order on a working reading and warns with that reading"
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
  out=$(leave "$home" drawer show 2>&1); status=$?
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
  pass "mark and clear refuse an unrecorded or path-shaped id, an unknown verb, a missing or multi-line reason, and the branch actor"
}

# A home whose task has a worktree and a process table the test controls.
# FM_FAKE_CONTROL picks what the stand-in for bin/fm-control.sh does:
#   stop  remove the agent from the process table and succeed (the default)
#   lie   succeed and leave the agent running
#   fail  refuse, as the control plane does for an endpoint it cannot verify
make_live_home() {  # <name> <task-id>
  local home
  home=$(make_home "$1" "$2")
  mkdir -p "$home/wt"
  printf 'worktree=%s\n' "$home/wt" >> "$home/state/$2.meta"
  printf '1\tbash\t/\tbash\n' > "$home/procs"
  cat > "$home/fakebin/fm-control.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_FAKE_CONTROL_LOG"
case "${FM_FAKE_CONTROL:-stop}" in
  fail) echo "error: exit refused - endpoint could not be verified" >&2; exit 5 ;;
  lie) exit 0 ;;
esac
grep -v "$(printf '\tpi\t')" "$FM_AGENT_PROC_TABLE" > "$FM_AGENT_PROC_TABLE.next"
mv -f "$FM_AGENT_PROC_TABLE.next" "$FM_AGENT_PROC_TABLE"
SH
  chmod +x "$home/fakebin/fm-control.sh"
  : > "$home/control-log"
  printf '%s\n' "$home"
}

agent_running() {  # <home>
  printf '4242\tpi\t%s\tpi\n' "$1/wt" >> "$1/procs"
}

leave_live() {  # <home> <args...>
  local home=$1
  shift
  FM_AGENT_PROC_TABLE="$home/procs" FM_LEAVE_STOPPED_CONTROL_BIN="$home/fakebin/fm-control.sh" \
    FM_FAKE_CONTROL_LOG="$home/control-log" FM_LEAVE_STOPPED_EXIT_WAIT=0 leave "$home" "$@"
}

test_mark_refuses_a_running_agent_unless_forced() {
  local home out status marker
  home=$(make_live_home running drawer)
  marker="$home/state/drawer.stopped"
  agent_running "$home"

  # The marker stops the watching, not the agent: marking a running agent
  # would leave it working with nobody supervising it.
  out=$(leave_live "$home" drawer mark --reason "captain: leave it" 2>&1); status=$?
  expect_code 1 "$status" "mark on a task with a live agent must refuse: $out"
  [ ! -e "$marker" ] || fail "a refused mark still wrote the marker"
  case "$out" in *"pi pid 4242"*) ;; *) fail "the refusal did not name the running agent: $out" ;; esac
  case "$out" in *"--exit"*"--force-silence"*) ;; *) fail "the refusal did not name both ways forward: $out" ;; esac
  [ ! -s "$home/control-log" ] || fail "a plain mark drove the agent: $(cat "$home/control-log")"
  grep -q "$(printf '\tpi\t')" "$home/procs" || fail "a refused mark touched the agent"

  # --force-silence is the deliberate version of the old behaviour.
  out=$(leave_live "$home" drawer mark --force-silence --reason "captain: silence it, it may finish" 2>&1); status=$?
  expect_code 0 "$status" "mark --force-silence must succeed: $out"
  [ -f "$marker" ] || fail "mark --force-silence did not write the marker"
  case "$out" in *warning*"pi pid 4242"*"keeps running"*) ;; *) fail "--force-silence did not warn that the agent keeps running: $out" ;; esac
  [ ! -s "$home/control-log" ] || fail "--force-silence drove the agent"
  leave_live "$home" drawer clear >/dev/null 2>&1 || fail "clear failed"

  # No agent in the worktree: nothing to refuse, nothing to warn about.
  home=$(make_live_home stopped drawer)
  out=$(leave_live "$home" drawer mark --reason "captain: leave it" 2>&1); status=$?
  expect_code 0 "$status" "mark on a stopped task must succeed: $out"
  [ -f "$home/state/drawer.stopped" ] || fail "mark on a stopped task did not write the marker"
  case "$out" in *warning*|*error*) fail "mark on a stopped task complained: $out" ;; esac

  # A process table that cannot be read is no evidence, so it does not block
  # the captain's order.
  home=$(make_live_home unreadable drawer)
  rm -f "$home/procs"
  out=$(leave_live "$home" drawer mark --reason "captain: leave it" 2>&1); status=$?
  expect_code 0 "$status" "an unreadable process table must not block mark: $out"
  [ -f "$home/state/drawer.stopped" ] || fail "mark with an unreadable process table did not write the marker"

  out=$(leave_live "$home" drawer mark --exit --force-silence --reason r 2>&1); status=$?
  expect_code 2 "$status" "--exit with --force-silence is a usage error"
  out=$(leave_live "$home" drawer clear --exit 2>&1); status=$?
  expect_code 2 "$status" "--exit on clear is a usage error"
  out=$(leave_live "$home" drawer clear --force-silence 2>&1); status=$?
  expect_code 2 "$status" "--force-silence on clear is a usage error"
  pass "mark refuses a task whose agent is still running, names it, and silences it only on --force-silence"
}

test_mark_exit_stops_the_agent_before_marking() {
  local home out status marker
  home=$(make_live_home exit-ok drawer)
  marker="$home/state/drawer.stopped"
  agent_running "$home"

  out=$(leave_live "$home" drawer mark --exit --reason "captain: stop it and leave it" 2>&1); status=$?
  expect_code 0 "$status" "mark --exit must succeed: $out"
  [ "$(cat "$home/control-log")" = 'drawer exit' ] || fail "mark --exit did not ask the control plane to exit exactly this task: $(cat "$home/control-log")"
  [ -f "$marker" ] || fail "mark --exit did not write the marker"
  grep -Fxq 'reason=captain: stop it and leave it' "$marker" || fail "mark --exit lost the reason"
  ! grep -q "$(printf '\tpi\t')" "$home/procs" || fail "the agent is still running after mark --exit"
  [ -d "$home/wt" ] && [ -f "$home/state/drawer.meta" ] || fail "mark --exit removed the worktree or the task record"

  # The control plane refuses (an endpoint it cannot verify): nothing is marked.
  home=$(make_live_home exit-refused drawer)
  agent_running "$home"
  out=$(FM_FAKE_CONTROL=fail leave_live "$home" drawer mark --exit --reason r 2>&1); status=$?
  expect_code 1 "$status" "a refused exit must fail mark --exit: $out"
  [ ! -e "$home/state/drawer.stopped" ] || fail "a task whose agent could not be stopped was marked stopped"
  case "$out" in *"endpoint could not be verified"*) ;; *) fail "the control plane's own refusal was swallowed: $out" ;; esac
  case "$out" in *"was not marked"*"pi pid 4242"*) ;; *) fail "the failure did not say the agent is still there: $out" ;; esac

  # The exit is reported complete but the process is still there: not marked.
  home=$(make_live_home exit-lied drawer)
  agent_running "$home"
  out=$(FM_FAKE_CONTROL=lie leave_live "$home" drawer mark --exit --reason r 2>&1); status=$?
  expect_code 1 "$status" "an exit that left the agent running must fail mark --exit: $out"
  [ ! -e "$home/state/drawer.stopped" ] || fail "a task with a surviving agent was marked stopped"
  case "$out" in *"still in its worktree (pi pid 4242)"*) ;; *) fail "the failure did not name the surviving agent: $out" ;; esac

  # Already stopped: exit is idempotent and the marker is written.
  home=$(make_live_home exit-idle drawer)
  out=$(leave_live "$home" drawer mark --exit --reason r 2>&1); status=$?
  expect_code 0 "$status" "mark --exit on a stopped task must succeed: $out"
  [ -f "$home/state/drawer.stopped" ] || fail "mark --exit on a stopped task did not write the marker"
  pass "mark --exit stops the agent through the control plane and marks only once it is gone"
}

test_mark_clear_round_trip
test_mark_on_a_stale_working_footer_warns_and_records
test_refusals_keep_it_the_captains_call
test_mark_refuses_a_running_agent_unless_forced
test_mark_exit_stops_the_agent_before_marking
