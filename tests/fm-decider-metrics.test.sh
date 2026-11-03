#!/usr/bin/env bash
# tests/fm-decider-metrics.test.sh - the Decider seat's definition of done.
#
# The seat exists to close most worker decisions without a captain or supervisor
# turn, so its own measure has to be honest: only a ruling the seat recorded
# through bin/fm-decider-route.sh answer counts, only inside the ruling window,
# and a decision closed some other way is disclosed rather than counted as a win.
# These cases pin the fold over state/decider-ledger.tsv:
#   1. A pass at or above 80% of routed decisions ruled inside the window.
#   2. A fail below it, with the exact fraction in the verdict line.
#   3. Insufficient and absent data are neither a pass nor a fail.
#   4. Episodes closed without a ruling, and rulings recorded without a routing
#      request, never inflate the headline.
#   5. The reporting window, the ruling window, and malformed input.
#   6. The JSON view carries the same numbers for a dashboard.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

METRICS="$ROOT/bin/fm-decider-metrics.sh"
TMP_ROOT=$(fm_test_tmproot fm-decider-metrics)
TMP_ROOT=$(cd "$TMP_ROOT" && pwd)

# A fixed clock and window keep every fraction exact and every case fast.
NOW=1700000000
WINDOW=7200

setup_home() {  # <name> -> echoes the home dir
  local name=$1 home
  home="$TMP_ROOT/$name"
  mkdir -p "$home/state"
  printf '%s' "$home"
}

run_metrics() {  # <home> [env...] -- [args...]
  local home=$1
  shift
  local envs=()
  while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do
    envs+=("$1")
    shift
  done
  shift
  env FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DECIDER_NOW="$NOW" FM_DECIDER_RULING_WINDOW="$WINDOW" \
    ${envs[@]+"${envs[@]}"} \
    "$METRICS" "$@"
}

ep() {  # <home> <kind> <first_seen> <task> <key> <class> <epoch>
  local home=$1
  shift
  mkdir -p "$home/state"
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$@" >> "$home/state/decider-ledger.tsv"
}

# One routed episode: opened, asked, and (when given) ruled.
routed_episode() {  # <home> <task> <key> <class> <first_seen> <offset|-> <ruling_offset|->
  local home=$1 task=$2 key=$3 class=$4 first=$5 asked=$6 ruled=$7
  ep "$home" O "$first" "$task" "$key" "$class" "$first"
  [ "$asked" = - ] || ep "$home" A "$first" "$task" "$key" "$class" "$((first + asked))"
  [ "$ruled" = - ] || ep "$home" R "$first" "$task" "$key" "$class" "$((first + ruled))"
}

test_pass_verdict() {
  local home out
  home=$(setup_home pass)
  # Five of six routed decisions ruled inside the window is 83%.
  routed_episode "$home" t1 k1 additive-ddl "$((NOW - 1000))" 10 20
  routed_episode "$home" t2 k2 additive-ddl "$((NOW - 1000))" 10 30
  routed_episode "$home" t3 k3 merge-on-go "$((NOW - 1000))" 10 40
  routed_episode "$home" t4 k4 merge-on-go "$((NOW - 1000))" 10 50
  routed_episode "$home" t5 k5 reversible-hide "$((NOW - 1000))" 10 60
  routed_episode "$home" t6 k6 reversible-hide "$((NOW - 1000))" 10 9000
  out=$(run_metrics "$home" -- --days 7)
  assert_contains "$out" 'routed to the seat:       6' "the report should count six routed decisions"
  assert_contains "$out" 'ruled inside the window:  5' "the report should count five inside the window"
  assert_contains "$out" '(83%) pass' "83% of routed decisions inside the window must pass"
  pass "decider metrics: 80% of routed decisions ruled inside the window passes"
}

test_fail_verdict() {
  local home out
  home=$(setup_home fail)
  routed_episode "$home" t1 k1 additive-ddl "$((NOW - 1000))" 10 20
  routed_episode "$home" t2 k2 additive-ddl "$((NOW - 1000))" 10 9000
  routed_episode "$home" t3 k3 additive-ddl "$((NOW - 1000))" 10 9500
  routed_episode "$home" t4 k4 additive-ddl "$((NOW - 1000))" 10 9600
  routed_episode "$home" t5 k5 additive-ddl "$((NOW - 1000))" 10 9700
  out=$(run_metrics "$home" -- --days 7)
  assert_contains "$out" '(20%) fail' "one of five inside the window is a fail"
  pass "decider metrics: a rate below the definition of done fails loudly"
}

test_the_same_key_in_two_tasks_is_two_episodes() {
  local home out
  home=$(setup_home shared-key)
  # Two workers may raise the same decision key in the same week; each episode
  # has its own clock and its own ruling.
  routed_episode "$home" t1 same-key additive-ddl "$((NOW - 1000))" 10 20
  routed_episode "$home" t2 same-key additive-ddl "$((NOW - 1000))" 10 30
  out=$(run_metrics "$home" -- --days 7)
  assert_contains "$out" 'episodes opened:          2' "the same key in two tasks is two episodes"
  assert_contains "$out" 'routed to the seat:       2' "both episodes were asked about"
  assert_contains "$out" 'ruled inside the window:  2' "both rulings belong to their own episode"
  pass "decider metrics: an episode is one task's key, not a key alone"
}

test_insufficient_and_absent_data() {
  local home out
  home=$(setup_home thin)
  routed_episode "$home" t1 k1 additive-ddl "$((NOW - 1000))" 10 20
  out=$(run_metrics "$home" -- --days 7)
  assert_contains "$out" 'insufficient data' "a tiny sample cannot pass or fail the definition"
  assert_not_contains "$out" ') pass' "a tiny sample must not read as a pass"
  assert_not_contains "$out" ') fail' "a tiny sample must not read as a fail"
  home=$(setup_home empty)
  out=$(run_metrics "$home" -- --days 7)
  assert_contains "$out" 'nothing routed yet' "an unused seat reports no data"
  pass "decider metrics: insufficient and absent data are neither pass nor fail"
}

test_closed_without_ruling_is_not_a_win() {
  local home out
  home=$(setup_home closed)
  # Six routed episodes, five of them closed without the seat ever ruling.
  routed_episode "$home" t1 k1 additive-ddl "$((NOW - 1000))" 10 20
  routed_episode "$home" t2 k2 additive-ddl "$((NOW - 1000))" 10 -
  routed_episode "$home" t3 k3 additive-ddl "$((NOW - 1000))" 10 -
  routed_episode "$home" t4 k4 additive-ddl "$((NOW - 1000))" 10 -
  routed_episode "$home" t5 k5 additive-ddl "$((NOW - 1000))" 10 -
  routed_episode "$home" t6 k6 additive-ddl "$((NOW - 1000))" 10 -
  ep "$home" C "$((NOW - 1000))" t2 k2 additive-ddl "$((NOW - 900))"
  ep "$home" C "$((NOW - 1000))" t3 k3 additive-ddl "$((NOW - 900))"
  ep "$home" C "$((NOW - 1000))" t4 k4 additive-ddl "$((NOW - 900))"
  ep "$home" C "$((NOW - 1000))" t5 k5 additive-ddl "$((NOW - 900))"
  ep "$home" C "$((NOW - 1000))" t6 k6 additive-ddl "$((NOW - 900))"
  out=$(run_metrics "$home" -- --days 7)
  assert_contains "$out" 'ruled inside the window:  1' "only the recorded ruling counts"
  assert_contains "$out" 'closed without a ruling:  5' "the other five are disclosed"
  assert_contains "$out" '(16%) fail' "a quiet log must never read as a fast decider"
  pass "decider metrics: a decision closed without a ruling is disclosed, never counted"
}

test_ruling_without_a_request_is_disclosed_only() {
  local home out
  home=$(setup_home unasked)
  routed_episode "$home" t1 k1 additive-ddl "$((NOW - 1000))" 10 20
  # An episode the sweep never asked about, ruled anyway.
  ep "$home" O "$((NOW - 500))" t2 k2 captain "$((NOW - 500))"
  ep "$home" R "$((NOW - 500))" t2 k2 captain "$((NOW - 400))"
  out=$(run_metrics "$home" -- --days 7)
  assert_contains "$out" 'routed to the seat:       1' "an unasked episode is not a routed one"
  assert_contains "$out" 'ruled without a routing request: 1' "the anomaly must be visible"
  pass "decider metrics: a ruling on an unasked episode is disclosed, never counted"
}

test_reporting_window() {
  local home out
  home=$(setup_home window)
  routed_episode "$home" t1 k1 additive-ddl "$((NOW - 1000))" 10 20
  routed_episode "$home" t2 k2 additive-ddl "$((NOW - 40 * 86400))" 10 20
  out=$(run_metrics "$home" -- --days 7)
  assert_contains "$out" 'episodes opened:          1' "an episode outside the reporting window is excluded"
  out=$(run_metrics "$home" -- --days 60)
  assert_contains "$out" 'episodes opened:          2' "a wider reporting window includes the older episode"
  pass "decider metrics: --days bounds which episodes the report counts"
}

test_ruling_window_is_configurable() {
  local home out
  home=$(setup_home window-config)
  routed_episode "$home" t1 k1 additive-ddl "$((NOW - 1000))" 10 100
  out=$(run_metrics "$home" -- --days 7)
  assert_contains "$out" 'ruled inside the window:  1' "a fast ruling counts inside a two hour window"
  out=$(run_metrics "$home" FM_DECIDER_RULING_WINDOW=60 -- --days 7)
  assert_contains "$out" 'ruled inside the window:  0' "the same ruling falls outside a one minute window"
  pass "decider metrics: the ruling window is the one the definition of done uses"
}

test_json_view() {
  local home json want
  home=$(setup_home json)
  routed_episode "$home" t1 k1 additive-ddl "$((NOW - 1000))" 10 20
  json=$(run_metrics "$home" -- --days 7 --json)
  case "$json" in
    '{'*'}') ;;
    *) fail "the JSON view should be one object: $json" ;;
  esac
  for want in '"routed":1' '"ruled":1' '"ruled_within":1' '"dod_threshold":80' '"dod_verdict":"insufficient data"' '"class":"additive-ddl"'; do
    assert_contains "$json" "$want" "the JSON view should carry $want"
  done
  pass "decider metrics: the JSON view carries the same numbers for a dashboard"
}

test_malformed_input_is_refused() {
  local home out rc
  home=$(setup_home bad-args)
  set +e
  out=$(run_metrics "$home" -- --days 0 2>&1)
  rc=$?
  set -e
  expect_code 2 "$rc" "a zero-day window is not a window"
  assert_contains "$out" 'must be a positive whole number of days' "the refusal should name the problem"
  set +e
  out=$(env -u FM_HOME "$METRICS" report 2>&1)
  rc=$?
  set -e
  expect_code 2 "$rc" "reporting needs an explicit home"
  assert_contains "$out" 'FM_HOME is not set' "the refusal should name the missing home"
  pass "decider metrics: malformed input is refused rather than reported as data"
}

test_pass_verdict
test_fail_verdict
test_the_same_key_in_two_tasks_is_two_episodes
test_insufficient_and_absent_data
test_closed_without_ruling_is_not_a_win
test_ruling_without_a_request_is_disclosed_only
test_reporting_window
test_ruling_window_is_configurable
test_json_view
test_malformed_input_is_refused
