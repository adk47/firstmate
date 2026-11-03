#!/usr/bin/env bash
# Behavior tests for bin/fm-outcome-check.sh: a ticket with a declared outcome is
# not Done until its probe passes, and a probe that stays red re-engages the
# owner, then asks for reassignment, then pages - each step exactly once.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-outcome-check.sh"
BRIEF="$ROOT/bin/fm-brief.sh"
TMP_ROOT=$(fm_test_tmproot fm-outcome-check)

# Portable mode read: GNU stat first, BSD stat second, so the shim's private mode
# is asserted on both platforms.
file_mode() {
  stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null
}

# One isolated home per case: a state/ and data/ pair, an armed shim nothing else
# shares, and a sender recorder so the escalation text is asserted without a live
# endpoint.
make_home() {
  local name=$1 home
  home="$TMP_ROOT/$name"
  mkdir -p "$home/state" "$home/data/task-a" "$home/config"
  write_sender "$home"
  printf '%s\n' "$home"
}

# A recorder in place of bin/fm-send.sh: every argument on one line, so a test can
# prove the delivery id, the target, and the gap text that reached the owner.
write_sender() {
  local home=$1
  cat > "$home/send.sh" <<SH
#!/usr/bin/env bash
for arg in "\$@"; do printf '%s\n' "\$arg"; done > "$home/send.log"
exit 0
SH
  chmod 0700 "$home/send.sh"
}

# A probe that fails until <home>/live exists, then succeeds. The gap it prints is
# the exact evidence the owner must be handed.
write_probe() {
  local home=$1 gap=$2
  cat > "$home/data/task-a/outcome.sh" <<SH
#!/usr/bin/env bash
if [ -f "$home/live" ]; then
  echo "live read ok"
  exit 0
fi
echo "gap: $gap"
exit 1
SH
  chmod 0755 "$home/data/task-a/outcome.sh"
}

run_check() {  # <home> [args...]
  local home=$1
  shift
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_HOME="$home" \
  FM_DATA_OVERRIDE="$home/data" \
  FM_STATE_OVERRIDE="$home/state" \
  FM_CONFIG_OVERRIDE="$home/config" \
  FM_OUTCOME_SEND_BIN="$home/send.sh" \
    "$CHECK" "$@"
}

record_field() {  # <home> <key>
  awk -F= -v k="$2" '$1 == k { sub(/^[^=]*=/, ""); print; exit }' \
    "$1/state/task-a.outcome" 2>/dev/null
}

declare_short() {  # <home> [extra declare args...]
  local home=$1
  shift
  run_check "$home" declare task-a --due 1s --cadence 1s --grace 1s "$@" >/dev/null \
    || fail "declare failed for $home"
}

# --- cases ------------------------------------------------------------------

test_declare_records_and_arms_the_timer() {
  local home shim
  home=$(make_home declare)
  write_probe "$home" merged-not-live
  declare_short "$home"

  assert_present "$home/state/task-a.outcome" "declare did not record the check"
  [ "$(record_field "$home" schema)" = fm-outcome-v1 ] || fail "record schema is wrong"
  [ "$(record_field "$home" task)" = task-a ] || fail "record task is wrong"
  [ "$(record_field "$home" probe)" = "$home/data/task-a/outcome.sh" ] \
    || fail "record did not default the probe to data/<id>/outcome.sh"
  [ "$(record_field "$home" escalation)" = 0 ] || fail "fresh record is already escalated"

  shim="$home/state/outcome-watch.check.sh"
  assert_present "$shim" "declare did not arm the outcome watch"
  assert_present "$home/state/outcome-watch.check-trust" "the armed shim is not byte-bound"
  [ "$(file_mode "$shim")" = 700 ] || fail "shim mode is not 0700"

  # Re-arming an armed home must stay armed and stay bound: the repair path.
  run_check "$home" arm >/dev/null || fail "re-arm of an armed home failed"
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    "$ROOT/bin/fm-check-register.sh" outcome-watch >/dev/null \
    || fail "re-armed shim is not bound to its bytes"
  pass "declare records the check and arms a bound timer"
}

test_run_reports_the_probe_gap_and_clears_on_green() {
  local home out status
  home=$(make_home run)
  write_probe "$home" merged-not-live
  declare_short "$home"

  status=0
  out=$(run_check "$home" run task-a 2>&1) || status=$?
  expect_code 1 "$status" "run with a red probe must exit nonzero"
  assert_contains "$out" "outcome task-a red gap=merged-not-live" "run did not name the gap"
  [ "$(record_field "$home" last_gap)" = merged-not-live ] || fail "record kept the wrong gap"
  [ "$(record_field "$home" red_since)" != "" ] || fail "record never stamped red_since"

  : > "$home/live"
  out=$(run_check "$home" run task-a 2>&1) || fail "run with a green probe must exit 0"
  assert_contains "$out" "outcome task-a green gap=none" "run did not report green"
  [ "$(record_field "$home" last_verdict)" = green ] || fail "record still reads red"
  [ "$(record_field "$home" red_since)" = "" ] || fail "red_since survived a green verdict"
  pass "run reports the probe's own gap and clears to green when the outcome is real"
}

test_missing_and_overrunning_probes_never_score_a_pass() {
  local home out status
  home=$(make_home absent)
  # Declared before its probe exists: an honest promise, recorded as missing.
  declare_short "$home"
  status=0
  out=$(run_check "$home" run task-a 2>&1) || status=$?
  expect_code 1 "$status" "a missing probe must never pass"
  assert_contains "$out" "gap=probe-missing" "missing probe was not named"

  home=$(make_home slow)
  mkdir -p "$home/data/task-a"
  cat > "$home/data/task-a/outcome.sh" <<'SH'
#!/usr/bin/env bash
sleep 5
exit 0
SH
  chmod 0755 "$home/data/task-a/outcome.sh"
  declare_short "$home"
  status=0
  out=$(FM_OUTCOME_PROBE_TIMEOUT=1 run_check "$home" run task-a 2>&1) || status=$?
  expect_code 1 "$status" "a probe that overruns its bound must never pass"
  assert_contains "$out" "gap=probe-timeout" "an overrun probe was not named as timed out"
  pass "absent and overrunning probes are recorded, never scored as green"
}

test_gate_refuses_until_the_outcome_is_proven() {
  local home out status
  home=$(make_home gate)
  write_probe "$home" merged-not-live

  # A brief that declares an outcome check with nothing recorded is not settled:
  # silence after a promise must not read as delivery.
  printf '%s\n' "# Task" "" "# Outcome check" "the hold list is live in prod" "" \
    "# Definition of done" "Delivery contract: mode=no-mistakes" > "$home/data/task-a/brief.md"
  status=0
  out=$(run_check "$home" gate task-a 2>&1) || status=$?
  expect_code 1 "$status" "a declared check with no record must refuse"
  assert_contains "$out" "no probe has ever been recorded" "gate did not name the gap"

  # A task that declared nothing proceeds: the check never widens beyond its own
  # declaration.
  printf '%s\n' "# Task" "no check here" > "$home/data/task-a/brief.md"
  out=$(run_check "$home" gate task-a 2>&1) || fail "an undeclared task must proceed"
  assert_contains "$out" "not-declared" "an undeclared task did not say so"

  declare_short "$home"
  status=0
  out=$(run_check "$home" gate task-a 2>&1) || status=$?
  expect_code 1 "$status" "a declared but unproven check must refuse"
  assert_contains "$out" "awaiting-outcome" "gate did not report awaiting-outcome"

  : > "$home/live"
  run_check "$home" run task-a >/dev/null 2>&1 || fail "the green run failed"
  out=$(run_check "$home" gate task-a 2>&1) || fail "a green probe must settle the gate"
  assert_contains "$out" "outcome task-a green" "gate did not report green"

  # Waived is a decision with a reason, and it settles the gate too.
  status=0
  out=$(run_check "$home" waive task-a 2>&1) || status=$?
  expect_code 2 "$status" "waive without a reason must be refused"
  out=$(run_check "$home" waive task-a --reason "the console has no read API yet" 2>&1) \
    || fail "waive with a reason failed"
  assert_contains "$out" "waived" "waive did not report the waiver"
  [ "$(record_field "$home" waive_reason)" = "the console has no read API yet" ] \
    || fail "the waiver reason was not recorded"
  out=$(run_check "$home" gate task-a 2>&1) || fail "a waived check must settle the gate"
  assert_contains "$out" "waived: the console has no read API yet" "gate lost the waiver reason"
  pass "the gate refuses a declared-but-unproven outcome and settles on green or a recorded waiver"
}

test_ladder_reengages_then_reassigns_then_pages_once_each() {
  local home out
  home=$(make_home ladder)
  write_probe "$home" merged-not-live
  declare_short "$home"

  # Step 1: the owner is re-engaged through the durable sender with the exact gap
  # and no wake, so a worker that fixes its own last mile never troubles firstmate.
  sleep 2
  out=$(run_check "$home" poll 2>&1) || fail "poll failed"
  [ -z "$out" ] || fail "step 1 must not print a wake, got: $out"
  [ "$(record_field "$home" escalation)" = 1 ] || fail "step 1 was not recorded"
  assert_present "$home/send.log" "step 1 never reached the owner"
  assert_contains "$(cat "$home/send.log")" "task-a" "the steer did not name the task"
  assert_contains "$(cat "$home/send.log")" "--fire-and-forget" \
    "the steer must not be re-rung by the watcher ladder"
  assert_contains "$(cat "$home/send.log")" "gap: merged-not-live" \
    "the steer did not carry the exact gap"

  # Step 2: still red after the grace, so firstmate is asked to reassign.
  sleep 2
  out=$(run_check "$home" poll 2>&1) || fail "poll failed"
  assert_contains "$out" "check: outcome-overdue task-a" "step 2 did not wake for reassignment"
  assert_contains "$out" "gap: merged-not-live" "step 2 lost the gap"
  assert_contains "$out" "reassign" "step 2 did not ask for reassignment"
  [ "$(record_field "$home" escalation)" = 2 ] || fail "step 2 was not recorded"

  # Step 3: nothing closed it, so the captain is the last resort.
  sleep 2
  out=$(run_check "$home" poll 2>&1) || fail "poll failed"
  assert_contains "$out" "check: outcome-abandoned task-a" "step 3 did not page"
  assert_contains "$out" "Page the captain" "step 3 does not read as the page"
  [ "$(record_field "$home" escalation)" = 3 ] || fail "step 3 was not recorded"

  # The ladder is spent: a further poll must not repeat any of it.
  sleep 2
  out=$(run_check "$home" poll 2>&1) || fail "poll failed"
  [ -z "$out" ] || fail "a spent ladder must stop waking, got: $out"
  [ "$(record_field "$home" escalation)" = 3 ] || fail "a spent ladder moved again"
  pass "a red probe re-engages the owner, then asks for reassignment, then pages - once each"
}

test_green_and_waived_checks_never_escalate() {
  local home out
  home=$(make_home quiet)
  write_probe "$home" merged-not-live
  : > "$home/live"
  declare_short "$home"
  sleep 2
  out=$(run_check "$home" poll 2>&1) || fail "poll failed"
  [ -z "$out" ] || fail "a green check woke firstmate: $out"
  assert_absent "$home/send.log" "a green check steered the owner"

  home=$(make_home waived)
  write_probe "$home" merged-not-live
  declare_short "$home"
  run_check "$home" waive task-a --reason "not awaited this cycle" >/dev/null \
    || fail "waive failed"
  sleep 2
  out=$(run_check "$home" poll 2>&1) || fail "poll failed"
  [ -z "$out" ] || fail "a waived check woke firstmate: $out"
  assert_absent "$home/send.log" "a waived check steered the owner"
  [ "$(record_field "$home" last_run)" = "" ] || fail "a waived check still ran its probe"
  pass "green and waived checks are never re-run into an escalation"
}

test_status_reads_a_ticket_as_awaiting_outcome() {
  local home out
  home=$(make_home status)
  write_probe "$home" merged-not-live
  declare_short "$home"
  out=$(run_check "$home" status task-a 2>&1) || fail "status failed"
  assert_contains "$out" "outcome task-a awaiting-outcome" \
    "status did not read the ticket as awaiting-outcome"
  assert_contains "$out" "escalation=0" "status did not show the ladder position"

  : > "$home/live"
  run_check "$home" run task-a >/dev/null 2>&1 || fail "the green run failed"
  out=$(run_check "$home" status task-a 2>&1) || fail "status failed"
  assert_contains "$out" "outcome task-a green" "status did not read the ticket as green"
  pass "status reads an unproven ticket as awaiting-outcome and a proven one as green"
}

# The shim the watcher dispatches is the production entry point: it must carry the
# home and run the poll, and it must be silent on a healthy home.
test_armed_shim_polls_without_noise() {
  local home out
  home=$(make_home shim)
  write_probe "$home" merged-not-live
  : > "$home/live"
  declare_short "$home"
  out=$(FM_OUTCOME_SEND_BIN="$home/send.sh" bash "$home/state/outcome-watch.check.sh" 2>&1) \
    || fail "the armed shim failed to poll"
  [ -z "$out" ] || fail "a green home's shim printed a wake: $out"
  pass "the armed shim polls the declared checks through the production entry point"
}

test_arm_refuses_a_task_id_collision() {
  local home status
  home=$(make_home collision)
  printf 'window=x\n' > "$home/state/outcome-watch.meta"
  status=0
  run_check "$home" arm > "$home/out" 2> "$home/err" || status=$?
  expect_code 1 "$status" "arming must refuse an id that is also a task id"
  assert_contains "$(cat "$home/err")" "is a task id" "the collision refusal was not stated"
  assert_absent "$home/state/outcome-watch.check.sh" "a refused arm still wrote a shim"
  pass "arming refuses to share a path with a live task id"
}

# A ship brief must declare what the outcome is, and must say so out loud when it
# declares none: silence there reads as "the PR is the outcome".
test_brief_renders_the_outcome_check_contract() {
  local home out status
  home="$TMP_ROOT/brief"
  mkdir -p "$home/data" "$home/state" "$home/config"
  FM_HOME="$home" "$BRIEF" task-b example-repo --mode no-mistakes \
    --outcome "the prod fraud hold list shows the four held accounts" >/dev/null \
    || fail "ship scaffold with --outcome failed"
  assert_grep "# Outcome check" "$home/data/task-b/brief.md" \
    "the brief has no Outcome check section"
  assert_grep "the prod fraud hold list shows the four held accounts" \
    "$home/data/task-b/brief.md" "the declaration is missing from the brief"
  assert_grep "$home/data/task-b/outcome.sh" "$home/data/task-b/brief.md" \
    "the brief does not name the probe path"
  assert_grep "fm-outcome-check.sh declare task-b" "$home/data/task-b/brief.md" \
    "the brief does not tell the worker to declare the probe"
  # The section sits inside the end contract, immediately above the Definition of
  # done, so a reader cannot finish the contract without meeting it.
  awk '/^# Outcome check$/ { oc = NR } /^# Definition of done$/ { dod = NR } END { exit !(oc && dod && oc < dod) }' \
    "$home/data/task-b/brief.md" \
    || fail "the Outcome check section is not above the Definition of done"

  FM_HOME="$home" "$BRIEF" task-c example-repo --mode direct-PR >/dev/null \
    || fail "ship scaffold without --outcome failed"
  assert_grep "No outcome check was declared" "$home/data/task-c/brief.md" \
    "an undeclared ship brief does not say so out loud"

  status=0
  out=$(FM_HOME="$home" "$BRIEF" task-d example-repo --scout --outcome "nope" 2>&1) || status=$?
  assert_contains "$out" "--outcome applies only to ship briefs" \
    "a scout brief accepted --outcome"
  pass "a ship brief declares its outcome check and says out loud when it declares none"
}

test_declare_records_and_arms_the_timer
test_run_reports_the_probe_gap_and_clears_on_green
test_missing_and_overrunning_probes_never_score_a_pass
test_gate_refuses_until_the_outcome_is_proven
test_ladder_reengages_then_reassigns_then_pages_once_each
test_green_and_waived_checks_never_escalate
test_status_reads_a_ticket_as_awaiting_outcome
test_armed_shim_polls_without_noise
test_arm_refuses_a_task_id_collision
test_brief_renders_the_outcome_check_contract
