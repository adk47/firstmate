#!/usr/bin/env bash
# tests/fm-drift-check.test.sh - behavior tests for the running-chair drift
# detector (bin/fm-drift-check.sh).
#
# The detector exists because a chair running an old checkout supervises the
# fleet with instructions and scripts that no longer match the repository, and
# nothing inside that session can see it. These tests drive the real script
# against a throwaway git repository and a fake clock, so the whole contract is
# exercised without waiting a day or touching the host clock:
#   - a drift episode shorter than the page threshold is silent, and one past it
#     prints exactly one line;
#   - the line is printed once per episode, not once per poll;
#   - catching up clears the episode, so a later drift reports again;
#   - the hourly probe gate keeps a poll inside the interval silent;
#   - a code root with no origin/main never pages on a comparison it could not
#     make;
#   - an unreachable origin never turns a failed fetch into a page;
#   - the hourly probe refreshes origin/main itself, so an upstream advance is
#     seen without a bootstrap run;
#   - arm writes and registers the shim, and disarm removes every artifact.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

DRIFT="$ROOT/bin/fm-drift-check.sh"
TMP_ROOT=$(fm_test_tmproot fm-drift-check)

# A throwaway repository whose HEAD is one commit ahead of its origin/main, so
# the running chair reads as drifted. Echoes the repo path.
make_drifted_repo() {  # <name>
  local repo="$TMP_ROOT/$1/repo"
  mkdir -p "$repo" || return 1
  git -C "$repo" init -q || return 1
  git -C "$repo" config user.email drift@example.invalid || return 1
  git -C "$repo" config user.name drift-test || return 1
  printf 'one\n' > "$repo/file" || return 1
  git -C "$repo" add file || return 1
  git -C "$repo" commit -qm one || return 1
  git -C "$repo" update-ref refs/remotes/origin/main HEAD || return 1
  printf 'two\n' >> "$repo/file" || return 1
  git -C "$repo" commit -qam two || return 1
  printf '%s\n' "$repo"
}

# A throwaway repository with a local bare origin. HEAD is one commit ahead of
# origin/main, and the bare repository is the live upstream. Echoes the repo path.
make_repo_with_bare_origin() {  # <name>
  local base="$TMP_ROOT/$1" bare="$TMP_ROOT/$1/origin.git" repo="$TMP_ROOT/$1/repo"
  git init -q --bare "$bare" || return 1
  mkdir -p "$repo" || return 1
  git -C "$repo" init -q || return 1
  git -C "$repo" config user.email drift@example.invalid || return 1
  git -C "$repo" config user.name drift-test || return 1
  printf 'one\n' > "$repo/file" || return 1
  git -C "$repo" add file || return 1
  git -C "$repo" commit -qm one || return 1
  git -C "$repo" remote add origin "$bare" || return 1
  git -C "$repo" push -q origin HEAD:main || return 1
  git -C "$repo" update-ref refs/remotes/origin/main HEAD || return 1
  printf 'two\n' >> "$repo/file" || return 1
  git -C "$repo" commit -qam two || return 1
  printf '%s\n' "$repo"
}

# run_check <repo> <state> <epoch> [extra env assignments...]
run_check() {
  local repo=$1 state=$2 epoch=$3
  shift 3
  FM_ROOT_OVERRIDE="$repo" FM_HOME="$state/.." FM_STATE_OVERRIDE="$state" \
    FM_DRIFT_INTERVAL=0 FM_DRIFT_NOW="$epoch" "$@" "$DRIFT" check
}

test_short_drift_is_silent_and_a_day_pages_once() {
  local repo state out
  repo=$(make_drifted_repo short-then-long)
  state="$TMP_ROOT/short-then-long/state"
  mkdir -p "$state"
  # First poll opens the episode at t=1000000.
  out=$(run_check "$repo" "$state" 1000000)
  [ -z "$out" ] || fail "the first poll of a drift episode must be silent, got: $out"
  assert_present "$state/.drift" "the first poll did not open a drift episode record"
  # 23h later: still inside the page threshold.
  out=$(run_check "$repo" "$state" $((1000000 + 82800)))
  [ -z "$out" ] || fail "23h of drift must stay silent, got: $out"
  # 25h after the episode opened: one line.
  out=$(run_check "$repo" "$state" $((1000000 + 90000)))
  [ -n "$out" ] || fail "25h of drift must print one line"
  [ "$(printf '%s\n' "$out" | wc -l | tr -d '[:space:]')" = 1 ] \
    || fail "the drift report must be exactly one line, got: $out"
  assert_contains "$out" "firstmate drift:" "the drift line does not name itself"
  assert_contains "$out" "origin/main" "the drift line does not name the ref it compared"
  assert_contains "$out" "for 25h" "the drift line does not report how long the drift has held"
  assert_contains "$out" "behind 0, ahead 1" "the drift line does not report the direction of the drift"
  assert_contains "$out" "/updatefirstmate" "the drift line does not name the update path"
  # A later poll in the same episode must not repeat the page.
  out=$(run_check "$repo" "$state" $((1000000 + 100000)))
  [ -z "$out" ] || fail "a drift episode must page once, not once per poll, got: $out"
  pass "drift is silent under a day, pages exactly once past it, and never repeats within the episode"
}

test_catching_up_clears_the_episode_and_a_new_drift_reports_again() {
  local repo state out
  repo=$(make_drifted_repo catch-up)
  state="$TMP_ROOT/catch-up/state"
  mkdir -p "$state"
  out=$(run_check "$repo" "$state" 2000000)
  [ -z "$out" ] || fail "the first poll of a drift episode must be silent, got: $out"
  out=$(run_check "$repo" "$state" $((2000000 + 90000)))
  [ -n "$out" ] || fail "25h of drift must print one line"
  # The chair catches up: HEAD becomes origin/main.
  git -C "$repo" update-ref refs/remotes/origin/main HEAD
  out=$(run_check "$repo" "$state" $((2000000 + 100000)))
  [ -z "$out" ] || fail "a caught-up chair must be silent, got: $out"
  assert_absent "$state/.drift" "catching up did not clear the drift episode record"
  # It drifts again: a new episode, so it reports again once past the threshold.
  git -C "$repo" update-ref refs/remotes/origin/main HEAD~1
  out=$(run_check "$repo" "$state" $((2000000 + 200000)))
  [ -z "$out" ] || fail "a new drift episode must start silent, got: $out"
  out=$(run_check "$repo" "$state" $((2000000 + 200000 + 90000)))
  [ -n "$out" ] || fail "a second drift episode must report again"
  pass "catching up clears the episode, and a later drift is reported as a new episode"
}

# An advance of origin/main while the chair sits on the same HEAD is exactly the
# "chair running stale code while PRs merge" case this check exists for, so it
# must not restart the episode clock. Keying the episode on the (HEAD, origin)
# pair would reset it on every upstream merge and the page would never land.
test_origin_advance_does_not_restart_the_episode() {
  local repo state out
  repo=$(make_drifted_repo origin-advance)
  state="$TMP_ROOT/origin-advance/state"
  mkdir -p "$state"
  out=$(run_check "$repo" "$state" 6000000)
  [ -z "$out" ] || fail "the first poll of a drift episode must be silent, got: $out"
  # origin/main advances to a new commit while HEAD stays put.
  git -C "$repo" checkout -q -b upstream HEAD~1 || fail "could not create the upstream branch"
  printf 'three\n' >> "$repo/file" || fail "could not write the upstream commit"
  git -C "$repo" commit -qam three || fail "could not commit upstream"
  git -C "$repo" update-ref refs/remotes/origin/main HEAD || fail "could not advance origin/main"
  git -C "$repo" checkout -q - || fail "could not return to the chair's branch"
  # 12h in: still inside the page threshold, and the origin advance must not
  # have restarted the clock.
  out=$(run_check "$repo" "$state" $((6000000 + 43200)))
  [ -z "$out" ] || fail "12h of drift must stay silent, got: $out"
  # 25h after the episode opened: the page still lands on the original schedule.
  out=$(run_check "$repo" "$state" $((6000000 + 90000)))
  [ -n "$out" ] || fail "an origin/main advance restarted the drift episode clock"
  assert_contains "$out" "for 25h" "the drift line did not keep the original episode start"
  pass "an origin/main advance while HEAD is unchanged does not restart the drift episode"
}

test_probe_gate_keeps_a_poll_inside_the_interval_silent() {
  local repo state out
  repo=$(make_drifted_repo gate)
  state="$TMP_ROOT/gate/state"
  mkdir -p "$state"
  # A short page threshold isolates the gate: the drift is already past it, so
  # only the probe interval can keep the next poll silent.
  out=$(FM_ROOT_OVERRIDE="$repo" FM_HOME="$state/.." FM_STATE_OVERRIDE="$state" \
    FM_DRIFT_PAGE_SECS=60 FM_DRIFT_NOW=3000000 "$DRIFT" check)
  [ -z "$out" ] || fail "the first poll of a drift episode must be silent, got: $out"
  out=$(FM_ROOT_OVERRIDE="$repo" FM_HOME="$state/.." FM_STATE_OVERRIDE="$state" \
    FM_DRIFT_PAGE_SECS=60 FM_DRIFT_NOW=$((3000000 + 120)) "$DRIFT" check)
  [ -z "$out" ] || fail "a poll inside the probe interval must not probe, got: $out"
  # Once the interval has elapsed the probe runs and the page lands.
  out=$(FM_ROOT_OVERRIDE="$repo" FM_HOME="$state/.." FM_STATE_OVERRIDE="$state" \
    FM_DRIFT_PAGE_SECS=60 FM_DRIFT_NOW=$((3000000 + 3700)) "$DRIFT" check)
  [ -n "$out" ] || fail "the probe must run once its interval has elapsed"
  pass "the hourly probe gate keeps a poll inside the interval silent"
}

test_missing_origin_main_never_pages() {
  local repo state out
  repo=$(make_drifted_repo no-origin)
  state="$TMP_ROOT/no-origin/state"
  mkdir -p "$state"
  git -C "$repo" update-ref -d refs/remotes/origin/main
  out=$(run_check "$repo" "$state" 4000000)
  [ -z "$out" ] || fail "a code root with no origin/main must stay silent, got: $out"
  out=$(run_check "$repo" "$state" $((4000000 + 90000)))
  [ -z "$out" ] || fail "a code root with no origin/main must never page, got: $out"
  assert_absent "$state/.drift" "a comparison that was never made opened a drift episode"
  pass "a code root with no origin/main never pages on a comparison it could not make"
}

test_probe_refreshes_origin_main_without_a_bootstrap_run() {
  local base repo state out upstream head origin
  base="$TMP_ROOT/probe-fetch"
  repo=$(make_repo_with_bare_origin probe-fetch)
  state="$base/state"
  mkdir -p "$state"
  out=$(run_check "$repo" "$state" 7000000)
  [ -z "$out" ] || fail "the first poll of a drift episode must be silent, got: $out"
  # Upstream merges a commit after the first probe, and no bootstrap runs.
  upstream="$base/upstream"
  git clone -q -b main "$base/origin.git" "$upstream" || fail "could not clone the upstream"
  git -C "$upstream" config user.email drift@example.invalid || fail "could not configure upstream"
  git -C "$upstream" config user.name drift-test || fail "could not configure upstream"
  printf 'three\n' >> "$upstream/file" || fail "could not write the upstream commit"
  git -C "$upstream" commit -qam three || fail "could not commit upstream"
  git -C "$upstream" push -q origin main || fail "could not advance the bare origin"
  head=$(git -C "$repo" rev-parse HEAD)
  origin=$(git -C "$upstream" rev-parse HEAD)
  out=$(run_check "$repo" "$state" $((7000000 + 90000)))
  [ -n "$out" ] || fail "25h of drift after an upstream advance must print one line"
  assert_contains "$out" "firstmate drift:" "the drift line does not name itself"
  [ "$(git -C "$repo" rev-parse refs/remotes/origin/main)" = "$origin" ] \
    || fail "the hourly probe did not refresh origin/main from the live upstream"
  [ "$(git -C "$repo" rev-parse HEAD)" = "$head" ] \
    || fail "the hourly probe moved the running chair's HEAD"
  pass "the hourly probe refreshes origin/main itself and pages on the upstream advance"
}

test_unreachable_origin_fetch_is_silent() {
  local repo state out
  repo=$(make_drifted_repo unreachable-origin)
  state="$TMP_ROOT/unreachable-origin/state"
  mkdir -p "$state"
  git -C "$repo" update-ref refs/remotes/origin/main HEAD
  git -C "$repo" remote add origin "$TMP_ROOT/unreachable-origin/missing.git"
  out=$(run_check "$repo" "$state" 8000000 2>&1)
  [ -z "$out" ] || fail "a failed fetch must stay silent, got: $out"
  out=$(run_check "$repo" "$state" $((8000000 + 90000)) 2>&1)
  [ -z "$out" ] || fail "a failed fetch must never page or error, got: $out"
  assert_present "$state/.drift.beat" "the probe did not complete after a failed fetch"
  assert_absent "$state/.drift" "a failed fetch opened a drift episode"
  pass "an unreachable origin leaves the previous ref and never pages"
}

test_arm_and_disarm_manage_every_artifact() {
  local repo state out
  repo=$(make_drifted_repo arm)
  state="$TMP_ROOT/arm/state"
  mkdir -p "$state"
  out=$(FM_ROOT_OVERRIDE="$repo" FM_HOME="$state/.." FM_STATE_OVERRIDE="$state" "$DRIFT" arm) \
    || fail "arm failed: $out"
  assert_present "$state/drift.check.sh" "arm did not write the check shim"
  assert_present "$state/drift.check-trust" "arm did not bind the shim's bytes"
  assert_grep "fm-drift-check.sh" "$state/drift.check.sh" "the shim does not dispatch the drift check"
  # The shim is what the watcher runs, so it must produce the same verdict.
  out=$(FM_ROOT_OVERRIDE="$repo" FM_HOME="$state/.." FM_STATE_OVERRIDE="$state" \
    FM_DRIFT_INTERVAL=0 FM_DRIFT_NOW=5000000 "$state/drift.check.sh")
  [ -z "$out" ] || fail "the armed shim must stay silent on the first poll of an episode, got: $out"
  out=$(FM_ROOT_OVERRIDE="$repo" FM_HOME="$state/.." FM_STATE_OVERRIDE="$state" \
    FM_DRIFT_INTERVAL=0 FM_DRIFT_NOW=$((5000000 + 90000)) "$state/drift.check.sh")
  [ -n "$out" ] || fail "the armed shim must print the drift line past the threshold"
  out=$(FM_ROOT_OVERRIDE="$repo" FM_HOME="$state/.." FM_STATE_OVERRIDE="$state" "$DRIFT" disarm) \
    || fail "disarm failed: $out"
  assert_absent "$state/drift.check.sh" "disarm left the check shim behind"
  assert_absent "$state/drift.check-trust" "disarm left the trust binding behind"
  assert_absent "$state/.drift" "disarm left the drift episode record behind"
  assert_absent "$state/.drift.beat" "disarm left the probe beat behind"
  pass "arm writes and registers the shim, and disarm removes every artifact"
}

test_short_drift_is_silent_and_a_day_pages_once
test_catching_up_clears_the_episode_and_a_new_drift_reports_again
test_origin_advance_does_not_restart_the_episode
test_probe_gate_keeps_a_poll_inside_the_interval_silent
test_missing_origin_main_never_pages
test_probe_refreshes_origin_main_without_a_bootstrap_run
test_unreachable_origin_fetch_is_silent
test_arm_and_disarm_manage_every_artifact
