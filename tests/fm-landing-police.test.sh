#!/usr/bin/env bash
# Behavior tests for bin/fm-landing-police.sh: something other than the worker
# runs each ship task's acceptance probe, records the result in the task's claim
# row, and reports a claim that is late, absent, unprobed, or tampered with.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
# shellcheck source=bin/fm-dod-lib.sh
. "$ROOT/bin/fm-dod-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-landing-police)
POLICE="$ROOT/bin/fm-landing-police.sh"

new_home() {  # <name>
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state"
  printf '%s\n' "$home"
}

ship_task() {  # <home> <task> <status-line> [<probe-body>]
  printf 'kind=ship\nmode=direct-PR\n' > "$1/state/$2.meta"
  printf '%s\n' "$3" > "$1/state/$2.status"
  if [ -n "${4:-}" ]; then
    printf '%s\n' "$4" > "$1/$2.probe"
    fm_acceptance_install "$1/state" "$2" "$1/$2.probe" >/dev/null || fail "could not install the probe for $2"
  fi
}

tick() {  # <home> <now>
  FM_HOME="$1" FM_STATE_OVERRIDE="$1/state" FM_CW_NOW="$2" "$POLICE" tick
}

row_state() {  # <home> <task>
  sed -n 's/.*"terminal_state": "\([^"]*\)".*/\1/p' "$1/state/change-watch/rows/$2-claim.json" 2>/dev/null
}

test_claim_runs_at_offsets_pages_late_and_proves() {
  local home out
  home=$(new_home offsets)
  ship_task "$home" lp-a1 'done: PR https://github.com/o/r/pull/7' "test -e $home/landed"
  out=$(tick "$home" 1000)
  [ -z "$out" ] || fail "a fresh claim inside its deadline reported something: $out"
  [ "$(row_state "$home" lp-a1)" = open ] || fail "the claim row was not registered open"
  grep -q '"pr_url": "https://github.com/o/r/pull/7"' "$home/state/change-watch/rows/lp-a1-claim.json" \
    || fail "the claim row lost the PR url from the done line"
  grep -q '"0": {"at": 1000, "exit": 1}' "$home/state/change-watch/rows/lp-a1-claim.json" \
    || fail "the probe was not run at claim time: $(cat "$home/state/change-watch/rows/lp-a1-claim.json")"
  [ -z "$(tick "$home" 1100)" ] || fail "a tick between offsets reported something"
  out=$(tick "$home" 5000)
  assert_contains "$out" "landing-police: CLAIMED DONE BUT NOT LANDED 66m lp-a1: the acceptance probe last exited 1" \
    "a claim past its deadline was not paged"
  [ -z "$(tick "$home" 5100)" ] || fail "a late claim was paged twice in one hour"
  touch "$home/landed"
  out=$(tick "$home" 22700)
  [ -z "$out" ] || fail "a claim that proved itself reported something: $out"
  [ "$(row_state "$home" lp-a1)" = proven ] || fail "the probe exiting 0 did not prove the claim"
  pass "a claim is probed at its offsets, paged once an hour while late, and proven by its probe"
}

test_absent_unprobed_and_tampered_are_reported() {
  local home out
  home=$(new_home findings)
  ship_task "$home" lp-b1 'done: shipped it' 'exit 1'
  ship_task "$home" lp-b2 'done: shipped it too'
  ship_task "$home" lp-b3 'done: shipped a third' 'exit 1'
  printf 'kind=scout\n' > "$home/state/lp-b4.meta"
  printf 'done: report written\n' > "$home/state/lp-b4.status"
  printf 'exit 0\n' >> "$home/state/acceptance/lp-b3.sh"
  out=$(tick "$home" 1000)
  assert_contains "$out" "landing-police: DONE WITHOUT ACCEPTANCE PROBE lp-b2: done: shipped it too" \
    "a ship done: with no probe was not reported"
  assert_contains "$out" "landing-police: ACCEPTANCE PROBE EDITED lp-b3" "an edited probe was not reported"
  case "$out" in *lp-b4*) fail "a scout's done: was policed as a ship claim: $out" ;; esac
  [ ! -e "$home/state/change-watch/rows/lp-b3-claim.json" ] || fail "an edited probe was claimed"
  [ -z "$(tick "$home" 1000)" ] || fail "the same findings were reported twice for the same done line"
  out=$(tick "$home" 22600)
  assert_contains "$out" "landing-police: CLAIMED DONE BUT ABSENT lp-b1" "a claim failing at +6h was not reported absent"
  [ "$(row_state "$home" lp-b1)" = absent ] || fail "the row did not read absent"
  pass "absent, unprobed, and tampered claims are reported once each, and scouts are not policed"
}

test_probe_edited_after_claim_records_125() {
  local home
  home=$(new_home tamper-after)
  ship_task "$home" lp-c1 'done: shipped' 'exit 1'
  tick "$home" 1000 >/dev/null
  printf 'exit 0\n' >> "$home/state/acceptance/lp-c1.sh"
  tick "$home" 1950 >/dev/null
  grep -q '"900": {"at": 1950, "exit": 125}' "$home/state/change-watch/rows/lp-c1-claim.json" \
    || fail "a probe edited after the claim was run instead of recorded 125: $(cat "$home/state/change-watch/rows/lp-c1-claim.json")"
  [ "$(row_state "$home" lp-c1)" = open ] || fail "an edited probe proved its claim"
  pass "a probe edited after its claim is never run and never proves it"
}

test_arm_registers_a_trusted_check() {
  local home out
  home=$(new_home arm)
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$POLICE" arm) || fail "arm failed: $out"
  assert_contains "$out" "registered: state/landing-police.check.sh" "arm did not register the check"
  [ "$(stat -c %a "$home/state/landing-police.check.sh" 2>/dev/null || stat -f %Lp "$home/state/landing-police.check.sh")" = 700 ] \
    || fail "the check is not mode 0700"
  # shellcheck source=bin/fm-pr-lib.sh
  . "$ROOT/bin/fm-pr-lib.sh"
  # shellcheck source=bin/fm-check-lib.sh
  . "$ROOT/bin/fm-check-lib.sh"
  fm_custom_check_registered "$home/state" landing-police || fail "the armed check is not trusted"
  ship_task "$home" lp-d1 'done: shipped' 'exit 0'
  out=$("$home/state/landing-police.check.sh")
  [ -z "$out" ] || fail "the armed check reported a claim that proved itself: $out"
  [ "$(row_state "$home" lp-d1)" = proven ] || fail "the armed check did not run the probe"
  pass "arm writes and registers a check that runs the police in its own home"
}

test_claim_runs_at_offsets_pages_late_and_proves
test_absent_unprobed_and_tampered_are_reported
test_probe_edited_after_claim_records_125
test_arm_registers_a_trusted_check
