#!/usr/bin/env bash
# tests/ak47-weekly-review.test.sh - the weekly review.
#
# The review reads its own logs and proposes threshold changes as a diff. The
# two things that must never happen: it writes the budget itself, and it widens
# its own authority by inventing an action class.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REVIEW="$ROOT/ak47/weekly-review.sh"

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

SANDBOX=
cleanup() { [ -n "${SANDBOX:-}" ] && rm -rf "$SANDBOX"; }
trap cleanup EXIT
SANDBOX=$(mktemp -d "${TMPDIR:-/tmp}/ak47-review-tests.XXXXXX")

export AK47_STATE=$SANDBOX/state
export AK47_CACHE=$SANDBOX/cache
export AK47_CONFIG=$SANDBOX/config
export AK47_TMP_ROOT=$SANDBOX/tmp
# The fixtures are 20 samples; the shipped floor is 168 (an hour apart for a
# week). Lowering it here keeps the rule under test without 2016 fake lines.
export AK47_REVIEW_MIN_SAMPLES=10
export FM_HOME=$SANDBOX/fmhome
mkdir -p "$AK47_STATE" "$AK47_CACHE" "$AK47_CONFIG" "$AK47_TMP_ROOT" "$FM_HOME/state"

# A samples.log with `n` lines of one metric at a fixed value.
seed_samples() {
  local key=$1 value=$2 n=${3:-20} i now
  now=$(date +%s)
  : >"$AK47_STATE/samples.log"
  # Timestamps must fall inside the review's window, so they are relative to
  # now rather than a fixed epoch.
  for ((i = 0; i < n; i++)); do
    printf '%s %s=%s\n' "$((now - (n - i) * 300))" "$key" "$value" \
      >>"$AK47_STATE/samples.log"
  done
}

# --- the report -----------------------------------------------------------------

test_refuses_without_samples() {
  : >"$AK47_STATE/samples.log"
  if "$REVIEW" --print >/dev/null 2>&1; then
    fail "the review produced a report with no samples to read"
  fi
  pass "the review refuses when there are no samples"
}

test_reports_no_changes_when_every_metric_sits_mid_band() {
  # load15 ceiling is 32. 20 is 62% of it: past the 50% lower threshold and
  # short of the 80% raise threshold, so nothing should move.
  seed_samples load15 20
  local out
  out=$("$REVIEW" --print --no-inbox 2>&1) || fail "the review failed: $out"
  case "$out" in
    *"None. Every ceiling still describes the box."*) : ;;
    *) fail "the review proposed a change for a metric sitting mid-band: $out" ;;
  esac
  pass "the review reports NO_CHANGES when every metric sits mid-band"
}

test_proposes_a_raise_when_p95_sits_near_the_ceiling() {
  # load15 ceiling 32; 30 is 94% of it, well past the 80% raise threshold.
  seed_samples load15 30
  local out
  out=$("$REVIEW" --print --no-inbox 2>&1) || fail "the review failed: $out"
  case "$out" in
    *"- load15: 32 -> "*) : ;;
    *) fail "the review did not propose raising a ceiling its p95 nearly touches: $out" ;;
  esac
  pass "the review proposes a raise when p95 sits near the ceiling"
}

test_proposes_a_lower_when_p95_sits_far_below_the_ceiling() {
  # load15 ceiling 32; 2 is 6% of it, well under the 50% lower threshold.
  seed_samples load15 2
  local out
  out=$("$REVIEW" --print --no-inbox 2>&1) || fail "the review failed: $out"
  case "$out" in
    *"- load15: 32 -> "*) : ;;
    *) fail "the review did not propose lowering a ceiling its p95 never approaches: $out" ;;
  esac
  pass "the review proposes a lower when p95 sits far below the ceiling"
}

test_emits_a_unified_diff_against_the_budget() {
  seed_samples load15 30
  local out
  out=$("$REVIEW" --print --no-inbox 2>&1) || fail "the review failed: $out"
  case "$out" in
    *"--- "*"+++ "*) : ;;
    *) fail "the review printed no unified diff header: $out" ;;
  esac
  case "$out" in
    *"@@ "*) : ;;
    *) fail "the review printed no diff hunk: $out" ;;
  esac
  pass "the review emits a unified diff against the budget"
}

test_counts_only_lines_inside_the_window() {
  seed_samples load15 20
  local old new out
  old=$(date -u -d '10 days ago' +%Y-%m-%dT%H:%M:%SZ)
  new=$(date -u -d '1 day ago' +%Y-%m-%dT%H:%M:%SZ)
  printf '%s tick mode=apply tmp_before=0 tmp_after=0 failures=1 loop_gap=10000\n' "$old" >"$AK47_STATE/devops.log"
  printf '%s tick mode=apply tmp_before=0 tmp_after=0 failures=1 loop_gap=10000\n' "$new" >>"$AK47_STATE/devops.log"
  out=$("$REVIEW" --print --no-inbox 2>&1) || fail "the review failed: $out"
  case "$out" in
    *"- tick lines in the window: 1"*) : ;;
    *) fail "the review counted tick lines outside the window: $out" ;;
  esac
  case "$out" in
    *"- runs reporting a failure: 1"*) : ;;
    *) fail "the review counted failures outside the window: $out" ;;
  esac
  case "$out" in
    *"- runs with a loop gap over 3 intervals: 1"*) : ;;
    *) fail "the review counted loop gaps outside the window: $out" ;;
  esac
  pass "the review counts only lines inside the requested window"
}

test_counts_a_loop_gap_just_over_three_intervals() {
  seed_samples load15 20
  local new out
  new=$(date -u -d '1 day ago' +%Y-%m-%dT%H:%M:%SZ)
  printf '%s tick mode=apply tmp_before=0 tmp_after=0 failures=0 loop_gap=901s\n' "$new" >"$AK47_STATE/devops.log"
  printf '%s tick mode=apply tmp_before=0 tmp_after=0 failures=0 loop_gap=900s\n' "$new" >>"$AK47_STATE/devops.log"
  out=$("$REVIEW" --print --no-inbox 2>&1) || fail "the review failed: $out"
  case "$out" in
    *"- runs with a loop gap over 3 intervals: 1"*) : ;;
    *) fail "the review did not count a 901s gap against a 900s threshold: $out" ;;
  esac
  pass "the review counts a loop gap just over three intervals"
}

test_holds_a_ceiling_that_sits_at_its_own_maximum() {
  # swap_pct p95 at 100 with a 50% ceiling used to propose 126%: a ceiling that
  # cannot be read as a percentage, from a metric that is sustained at full.
  # That is a finding about the box, never a raise.
  seed_samples swap_pct 100 20
  AK47_REVIEW_MIN_SAMPLES=10 "$REVIEW" >/dev/null 2>&1
  local diff
  diff=$(cat "$(ls "$AK47_STATE"/review-*.diff | tail -1)")
  case "$diff" in
    *"swap_pct|126"*|*"swap_pct|1"*) fail "the review proposed a percentage ceiling above 100" ;;
  esac
  case "$diff" in
    *HELD*swap_pct*) : ;;
    *) fail "the review did not say why it held the swap ceiling: $diff" ;;
  esac
  pass "a percentage at its own maximum is held, not raised past 100"
}

test_holds_a_ceiling_it_cannot_trust_to_few_samples() {
  seed_samples load15 31 3
  AK47_REVIEW_MIN_SAMPLES=100 "$REVIEW" >/dev/null 2>&1
  local diff
  diff=$(cat "$(ls "$AK47_STATE"/review-*.diff | tail -1)")
  case "$diff" in
    *CHANGE*load15*) fail "the review proposed a change from 3 samples" ;;
    *"load15: HELD"*) : ;;
    *) fail "the review did not report the thin sample count: $diff" ;;
  esac
  pass "a ceiling is not moved on fewer samples than the floor allows"
}

test_holds_a_ceiling_when_the_sampler_is_not_measuring() {
  # tmp_gb records 0 when the size walk fails. A p95 of 0 against a peak of 433
  # used to propose lowering the ceiling to 1 GB - a ceiling that would page
  # the box on every tick. An unmeasured metric is never a quiet one.
  {
    local i now
    now=$(date +%s)
    : >"$AK47_STATE/samples.log"
    for ((i = 0; i < 20; i++)); do
      printf '%s tmp_gb=%s\n' "$((now - (20 - i) * 300))" "$([ "$i" -eq 19 ] && echo 433 || echo 0)"
    done >>"$AK47_STATE/samples.log"
  }
  AK47_REVIEW_MIN_SAMPLES=10 "$REVIEW" >/dev/null 2>&1
  local diff
  diff=$(cat "$(ls "$AK47_STATE"/review-*.diff | tail -1)")
  case "$diff" in
    *"tmp_gb|1"*) fail "the review lowered a ceiling to the sampler's zero" ;;
    *"tmp_gb: HELD"*) : ;;
    *) fail "the review did not report the unmeasured metric: $diff" ;;
  esac
  pass "a metric whose sampler reported zero is held, not used to lower its ceiling"
}

test_reads_a_sample_written_by_the_tick() {
  local tick=$ROOT/ak47/tick.sh out
  cat >"$AK47_CONFIG/devops.conf" <<'CONF'
tmp_mktemp_min=0
tmp_producer_min=0
orphan_min=0
quarantine_days=7
tmp_max_entries=0
tmp_max_moves=2000
swap_pressure=0
fat_process=0
fat_process_gb=3
fat_process_min=10
interval_seconds=300
CONF
  "$tick" --apply >/dev/null 2>&1 || fail "the tick failed while producing a sample"
  out=$("$REVIEW" --print --no-inbox 2>&1) || fail "the review could not read the tick's sample: $out"
  case "$out" in
    *"load15"*) : ;;
    *) fail "the review reported no statistics for the tick's sample: $out" ;;
  esac
  pass "the review reads a sample line produced by the tick"
}

# --- what it must never do ------------------------------------------------------

test_never_writes_the_budget() {
  seed_samples load15 30
  local before after
  before=$(cksum <"$ROOT/ak47/budget.conf")
  "$REVIEW" --print --no-inbox >/dev/null 2>&1 || true
  after=$(cksum <"$ROOT/ak47/budget.conf")
  [ "$before" = "$after" ] \
    || fail "the review rewrote ak47/budget.conf; a review that edits its own thresholds is not a review"
  pass "the review never writes the budget"
}

test_never_proposes_a_new_action_class() {
  seed_samples load15 30
  local out
  out=$("$REVIEW" --print --no-inbox 2>&1) || fail "the review failed: $out"
  # The only permitted change lines are threshold moves on keys the budget
  # already carries. Anything else is the review widening its own authority.
  local line key
  while IFS= read -r line; do
    case "$line" in
      "- "*": "*" -> "*) : ;;
      *) continue ;;
    esac
    key=${line#- }
    key=${key%%:*}
    grep -q "^${key}|" "$ROOT/ak47/budget.conf" \
      || fail "the review proposed a change to '$key', which is not a budget row"
  done <<<"$out"
  pass "the review never proposes a new action class"
}

test_states_what_it_will_not_do() {
  seed_samples load15 30
  local out
  out=$("$REVIEW" --print --no-inbox 2>&1) || fail "the review failed: $out"
  case "$out" in
    *"will not"*) : ;;
    *) fail "the review does not state the limits of its own authority: $out" ;;
  esac
  pass "the review states what it will not do"
}

test_writes_a_dated_report() {
  seed_samples load15 30
  "$REVIEW" --no-inbox >/dev/null 2>&1 || fail "the review failed"
  local found
  found=$(find "$AK47_STATE" -maxdepth 1 -name 'review-*.md' -print -quit)
  [ -n "$found" ] || fail "the review wrote no dated report"
  [ -s "$found" ] || fail "the review wrote an empty report"
  pass "the review writes a dated report"
}

test_refuses_a_malformed_budget() {
  seed_samples load15 30
  local fake=$SANDBOX/fake
  mkdir -p "$fake/ak47"
  cp "$REVIEW" "$fake/ak47/weekly-review.sh"
  cp -r "$ROOT/ak47/lib" "$fake/ak47/lib"
  printf '%s\n' 'load15|notanumber|max|load|because' >"$fake/ak47/budget.conf"
  if "$fake/ak47/weekly-review.sh" --print --no-inbox >/dev/null 2>&1; then
    fail "the review accepted a budget row with a non-numeric ceiling"
  fi
  pass "the review refuses a malformed budget"
}

test_refuses_without_samples
test_reports_no_changes_when_every_metric_sits_mid_band
test_proposes_a_raise_when_p95_sits_near_the_ceiling
test_proposes_a_lower_when_p95_sits_far_below_the_ceiling
test_emits_a_unified_diff_against_the_budget
test_counts_only_lines_inside_the_window
test_counts_a_loop_gap_just_over_three_intervals
test_holds_a_ceiling_that_sits_at_its_own_maximum
test_holds_a_ceiling_it_cannot_trust_to_few_samples
test_holds_a_ceiling_when_the_sampler_is_not_measuring
test_reads_a_sample_written_by_the_tick
test_never_writes_the_budget
test_never_proposes_a_new_action_class
test_states_what_it_will_not_do
test_writes_a_dated_report
test_refuses_a_malformed_budget
