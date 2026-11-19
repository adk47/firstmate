#!/usr/bin/env bash
# tests/fm-ci-health-check.test.sh - the CI health check must call a run red
# only when its conclusion says so, stay silent on a run that has not answered
# yet, name the run it read in every red line, and treat a conclusion it does
# not recognise as unknown rather than red. The incident this pins: on
# 2026-11-19 two "main red" lines named only a workflow, and the newest run of
# each was in progress by the time anyone looked.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-ci-health-check.sh"
TMP_ROOT=$(fm_test_tmproot fm-ci-health)

# A home with a fake gh that answers `gh api <path>` from <home>/api/<path with
# / ? & = turned into _>, logs every call to <home>/gh.calls, and fails on a
# path with no fixture.
make_home() {  # <name>
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state" "$home/config" "$home/api" "$home/fakebin"
  cat > "$home/fakebin/gh" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$home/gh.calls"
[ "\$1" = api ] || exit 1
f="$home/api/\$(printf '%s' "\$2" | tr '/?&=' '____')"
[ -f "\$f" ] || exit 1
cat "\$f"
SH
  chmod +x "$home/fakebin/gh"
  printf '{"resources":{"core":{"remaining":4000}}}\n' > "$home/api/rate_limit"
  printf '%s\n' "$home"
}

fixture_path() {  # <home> <api-path>
  printf '%s/api/%s\n' "$1" "$(printf '%s' "$2" | tr '/?&=' '____')"
}

# runs_fixture <home> <owner/repo> <branch> <per-page> <row>...: the push-runs
# answer, each row "name|id|status|conclusion|created|head". A conclusion of
# "null" is written as JSON null, the way GitHub answers for an unfinished run.
runs_fixture() {
  local home=$1 repo=$2 branch=$3 per_page=$4 path
  shift 4
  path=$(fixture_path "$home" "repos/$repo/actions/runs?branch=$branch&event=push&per_page=$per_page")
  printf '%s\n' "$@" | jq -R -s '
    split("\n") | map(select(length > 0) | split("|"))
    | { workflow_runs: map({ name: .[0], id: (.[1] | tonumber), status: .[2],
        conclusion: (if .[3] == "null" then null else .[3] end),
        created_at: .[4], head_sha: .[5] }) }' > "$path"
}

queued_fixture() {  # <home> <owner/repo> <count>
  printf '{"total_count":%s}\n' "$3" > "$(fixture_path "$1" "repos/$2/actions/runs?status=queued&per_page=1")"
}

# poll <home> <now>: one check run with every network read answered by the home.
poll() {
  local home=$1 now=$2
  shift 2
  env PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_CONFIG_OVERRIDE="$home/config" FM_CI_HEALTH_NOW="$now" FM_CI_HEALTH_TOKEN_ENV=none \
    FM_CI_HEALTH_REPOS='acme/widgets:main:10' FM_CI_HEALTH_SCHEDULED=' ' "$@" "$CHECK" check 2>&1
}

classify() {  # <status> <conclusion>
  "$CHECK" classify "$1" "$2"
}

# Requirement 1 and 4: the classifier's table, through the public command.
test_classifier_reads_only_a_finished_failure_as_red() {
  local c
  for c in failure timed_out cancelled FAILURE ' failure '; do
    [ "$(classify completed "$c")" = red ] || fail "conclusion '$c' did not read as red: $(classify completed "$c")"
  done
  [ "$(classify completed success)" = green ] || fail "success did not read as green"
  [ "$(classify completed skipped)" = green ] || fail "skipped did not read as green"
  for s in queued in_progress waiting requested pending completed; do
    [ "$(classify "$s" null)" = pending ] || fail "status $s with a null conclusion did not read as pending: $(classify "$s" null)"
    [ "$(classify "$s" '')" = pending ] || fail "status $s with an empty conclusion did not read as pending: $(classify "$s" '')"
  done
  for c in stale action_required startup_failure banana 'not a conclusion'; do
    [ "$(classify completed "$c")" = unknown ] || fail "conclusion '$c' did not read as unknown: $(classify completed "$c")"
  done
  pass "only failure, timed_out, and cancelled read as red; null is pending; anything else is unknown"
}

# Requirement 2: the 2026-11-19 shape. The newest run of each workflow is in
# progress or queued, an older run of the same workflow concluded failure, and
# the check must say nothing.
test_an_in_progress_newest_run_is_pending_and_prints_nothing() {
  local home out
  home=$(make_home pending)
  queued_fixture "$home" acme/widgets 0
  runs_fixture "$home" acme/widgets main 60 \
    'verify-devops-agent-tests|44632777885|in_progress|null|2026-11-19T22:53:30Z|a1ba56fdf0000' \
    'verify-devops-agent-tests|44623276860|completed|failure|2026-11-19T21:53:33Z|a9d29e8800000' \
    'Verify: pin-bump PRs run CI|44619765371|queued|null|2026-11-19T21:32:21Z|7ba1f876b0000' \
    'Verify: pin-bump PRs run CI|44616463852|completed|failure|2026-11-19T21:12:46Z|8da6a08bd0000' \
    'deploy|5|waiting|null|2026-11-19T21:00:00Z|aaaaaaaaa0000' \
    'lint|6|requested|null|2026-11-19T20:59:00Z|bbbbbbbbb0000'
  out=$(poll "$home" 100000)
  [ -z "$out" ] || fail "a workflow whose newest run has not answered yet was reported: $out"
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$CHECK" status)
  assert_contains "$out" "verdict=quiet" "the quiet poll was not recorded as quiet"
  pass "a newest run that is queued, in progress, waiting, or requested is pending and never pages"
}

# Requirement 3: a red names its evidence, and a genuine failure on the next
# poll still pages after a quiet one.
test_a_red_names_workflow_run_id_and_conclusion_and_still_pages_after_a_pending_poll() {
  local home out
  home=$(make_home red)
  queued_fixture "$home" acme/widgets 0
  runs_fixture "$home" acme/widgets main 60 \
    'verify-devops-agent-tests|44632777885|in_progress|null|2026-11-19T22:53:30Z|a1ba56fdf0000' \
    'verify-devops-agent-tests|44623276860|completed|failure|2026-11-19T21:53:33Z|a9d29e8800000'
  out=$(poll "$home" 100000)
  [ -z "$out" ] || fail "the in-progress poll printed: $out"
  # The run finished red; the next poll (one interval later) must page.
  runs_fixture "$home" acme/widgets main 60 \
    'verify-devops-agent-tests|44632777885|completed|failure|2026-11-19T22:53:30Z|a1ba56fdf0000' \
    'verify-devops-agent-tests|44623276860|completed|failure|2026-11-19T21:53:33Z|a9d29e8800000' \
    'build|7|completed|timed_out|2026-11-19T22:00:00Z|ccccccccc0000' \
    'release|8|completed|cancelled|2026-11-19T22:01:00Z|ddddddddd0000' \
    'docs|9|completed|success|2026-11-19T22:02:00Z|eeeeeeeee0000'
  out=$(poll "$home" 100900)
  [ -n "$out" ] || fail "a newest run that concluded failure did not page"
  [ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = 1 ] || fail "the check printed more than one line:"$'\n'"$out"
  assert_contains "$out" "ci-health: acme/widgets main red:" "the line did not name the repository and branch"
  assert_contains "$out" "verify-devops-agent-tests run 44632777885 conclusion=failure" "the line did not name the workflow, run id, and conclusion"
  assert_contains "$out" "head a1ba56fdf created 2026-11-19T22:53:30Z" "the line did not carry the head and creation time"
  assert_contains "$out" "(gh run view 44632777885 --repo acme/widgets)" "the line did not carry the command that confirms it"
  assert_contains "$out" "build run 7 conclusion=timed_out" "a timed_out newest run was not red"
  assert_contains "$out" "release run 8 conclusion=cancelled" "a cancelled newest run was not red"
  assert_not_contains "$out" "44623276860" "an older run of the same workflow was reported instead of the newest"
  assert_not_contains "$out" "docs run 9" "a green workflow was reported"
  pass "a red names the workflow, run id, conclusion, head, and the confirming command, and a fresh failure pages after a pending poll"
}

# Requirement 4: an unrecognised conclusion is unknown, and unknown never pages.
test_an_unrecognised_conclusion_does_not_page() {
  local home out
  home=$(make_home unknown)
  queued_fixture "$home" acme/widgets 0
  runs_fixture "$home" acme/widgets main 60 \
    'verify|11|completed|exploded|2026-11-19T22:53:30Z|a1ba56fdf0000' \
    'verify|10|completed|failure|2026-11-19T21:53:33Z|a9d29e8800000' \
    'lint|12|completed|stale|2026-11-19T22:53:30Z|b1ba56fdf0000' \
    'lint|13|completed|action_required|2026-11-19T22:50:30Z|c1ba56fdf0000'
  out=$(poll "$home" 100000)
  [ -z "$out" ] || fail "an unrecognised conclusion paged: $out"
  pass "an unrecognised or stale conclusion is unknown and does not page"
}

test_queued_backlog_over_the_bar_pages_with_the_count() {
  local home out
  home=$(make_home queued)
  queued_fixture "$home" acme/widgets 11
  runs_fixture "$home" acme/widgets main 60 'verify|1|completed|success|2026-11-19T22:53:30Z|a1ba56fdf0000'
  out=$(poll "$home" 100000)
  assert_contains "$out" "acme/widgets queued=11 (>10)" "a queued backlog over the bar was not reported"
  pass "a queued backlog over the repository's bar pages with the count and the bar"
}

test_poll_is_throttled_and_stands_down_on_a_thin_rate_budget() {
  local home out calls
  home=$(make_home throttle)
  queued_fixture "$home" acme/widgets 0
  runs_fixture "$home" acme/widgets main 60 'verify|1|completed|failure|2026-11-19T22:53:30Z|a1ba56fdf0000'
  out=$(poll "$home" 100000)
  assert_contains "$out" "verify run 1 conclusion=failure" "the first poll did not page"
  calls=$(wc -l < "$home/gh.calls" | tr -d ' ')
  out=$(poll "$home" 100500)
  [ -z "$out" ] || fail "a poll inside the interval printed: $out"
  [ "$(wc -l < "$home/gh.calls" | tr -d ' ')" = "$calls" ] || fail "a poll inside the interval made API calls"
  printf '{"resources":{"core":{"remaining":100}}}\n' > "$home/api/rate_limit"
  out=$(poll "$home" 100900)
  [ -z "$out" ] || fail "a poll on a thin rate budget printed: $out"
  grep -q 'repos/acme/widgets/actions/runs?branch' <(tail -n +$((calls + 1)) "$home/gh.calls") && fail "a poll on a thin rate budget still read runs"
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$CHECK" status)
  assert_contains "$out" "stood down: 100 core calls remaining" "the stand-down was not recorded"
  pass "polls are throttled to the interval and stand down below the rate floor without reading runs"
}

test_an_unreadable_answer_is_silent_not_red() {
  local home out
  home=$(make_home unreadable)
  queued_fixture "$home" acme/widgets 0
  printf 'HTTP 502 bad gateway\n' > "$(fixture_path "$home" 'repos/acme/widgets/actions/runs?branch=main&event=push&per_page=60')"
  out=$(poll "$home" 100000)
  [ -z "$out" ] || fail "an unreadable runs answer printed: $out"
  rm -f "$(fixture_path "$home" 'repos/acme/widgets/actions/runs?branch=main&event=push&per_page=60')"
  out=$(poll "$home" 101000)
  [ -z "$out" ] || fail "a failed runs call printed: $out"
  pass "an unreadable or failed runs read is silent, never red"
}

test_a_scheduled_workflow_is_judged_only_when_it_declares_a_schedule() {
  local home out wf_plain wf_sched
  home=$(make_home cadence)
  queued_fixture "$home" acme/widgets 0
  runs_fixture "$home" acme/widgets main 60 'verify|1|completed|success|2026-11-19T22:53:30Z|a1ba56fdf0000'
  wf_plain=$(printf 'on:\n  push:\n    branches: [main]\n' | base64 | tr -d '\n')
  wf_sched=$(printf 'on:\n  schedule:\n    - cron: "0 * * * *"\n' | base64 | tr -d '\n')
  printf '{"content":"%s"}\n' "$wf_plain" > "$(fixture_path "$home" 'repos/acme/widgets/contents/.github/workflows/reconcile.yaml')"
  printf '{"workflow_runs":[{"updated_at":"2026-11-19T00:00:00Z"}]}\n' > "$(fixture_path "$home" 'repos/acme/widgets/actions/workflows/reconcile.yaml/runs?status=success&per_page=1')"
  # One day after the last success, read through the same date parser the check uses.
  day_after=$(date -u -d 2026-11-20T00:00:00Z +%s 2>/dev/null || date -u -j -f '%Y-%m-%dT%H:%M:%SZ' 2026-11-20T00:00:00Z +%s)
  out=$(poll "$home" "$day_after" FM_CI_HEALTH_SCHEDULED='acme/widgets:reconcile.yaml:7200')
  [ -z "$out" ] || fail "an idle push-only workflow was reported as late: $out"
  printf '{"content":"%s"}\n' "$wf_sched" > "$(fixture_path "$home" 'repos/acme/widgets/contents/.github/workflows/reconcile.yaml')"
  out=$(poll "$home" "$((day_after + 900))" FM_CI_HEALTH_SCHEDULED='acme/widgets:reconcile.yaml:7200')
  assert_contains "$out" "acme/widgets reconcile.yaml last success 2026-11-19T00:00:00Z (24h ago, allowed 2h)" "a scheduled workflow past its allowance was not reported"
  pass "a cadence miss is judged only when the workflow declares a schedule"
}

test_classify_run_reads_one_run_live_with_its_evidence() {
  local home out
  home=$(make_home live)
  printf '{"id":44632777885,"name":"verify-devops-agent-tests","status":"in_progress","conclusion":null,"head_sha":"a1ba56fdf0000","created_at":"2026-11-19T22:53:30Z"}\n' \
    > "$(fixture_path "$home" 'repos/acme/widgets/actions/runs/44632777885')"
  printf '{"id":44616463852,"name":"Verify: pin-bump PRs run CI","status":"completed","conclusion":"failure","head_sha":"8da6a08bd0000","created_at":"2026-11-19T21:12:46Z"}\n' \
    > "$(fixture_path "$home" 'repos/acme/widgets/actions/runs/44616463852')"
  out=$(env PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_CI_HEALTH_TOKEN_ENV=none "$CHECK" classify-run acme/widgets 44632777885)
  assert_contains "$out" "pending: verify-devops-agent-tests run 44632777885 conclusion=null status=in_progress" "an in-progress run did not read as pending with its evidence"
  out=$(env PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_CI_HEALTH_TOKEN_ENV=none "$CHECK" classify-run acme/widgets 44616463852)
  assert_contains "$out" "red: Verify: pin-bump PRs run CI run 44616463852 conclusion=failure status=completed head 8da6a08bd" "a finished failure did not read as red with its evidence"
  out=$(env PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_CI_HEALTH_TOKEN_ENV=none "$CHECK" classify-run acme/widgets 1 2>&1) && fail "an unreadable run did not fail"
  assert_contains "$out" "unreadable: run 1" "an unreadable run was not named"
  pass "classify-run prints the class and the same evidence a wake line carries"
}

test_status_and_arm() {
  local home out
  home=$(make_home arm)
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$CHECK" status)
  assert_contains "$out" "no poll recorded yet" "status before any poll did not say so"
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$CHECK" arm >/dev/null || fail "arm failed"
  assert_present "$home/state/ci-health.check.sh" "arm wrote no shim"
  assert_present "$home/state/ci-health.check-trust" "arm bound no trust record"
  [ "$(stat -c %a "$home/state/ci-health.check.sh" 2>/dev/null || stat -f %Lp "$home/state/ci-health.check.sh")" = 700 ] || fail "the shim is not mode 0700"
  queued_fixture "$home" acme/widgets 0
  runs_fixture "$home" acme/widgets main 60 'verify|1|completed|failure|2026-11-19T22:53:30Z|a1ba56fdf0000'
  # The armed shim runs the tracked check against the home it was armed in.
  out=$(env PATH="$home/fakebin:$PATH" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" \
    FM_CI_HEALTH_NOW=100000 FM_CI_HEALTH_TOKEN_ENV=none FM_CI_HEALTH_REPOS='acme/widgets:main:10' \
    FM_CI_HEALTH_SCHEDULED=' ' "$home/state/ci-health.check.sh" 2>&1)
  assert_contains "$out" "verify run 1 conclusion=failure" "the armed shim did not run the poll"
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$CHECK" disarm >/dev/null || fail "disarm failed"
  assert_absent "$home/state/ci-health.check.sh" "disarm left the shim"
  assert_absent "$home/state/ci-health.check-trust" "disarm left the trust record"
  assert_absent "$home/state/.ci-health.last" "disarm left the throttle stamp"
  assert_absent "$home/state/.ci-health.verdict" "disarm left the verdict record"
  pass "status reports the last poll, and arm and disarm manage the registered shim"
}

test_classifier_reads_only_a_finished_failure_as_red
test_an_in_progress_newest_run_is_pending_and_prints_nothing
test_a_red_names_workflow_run_id_and_conclusion_and_still_pages_after_a_pending_poll
test_an_unrecognised_conclusion_does_not_page
test_queued_backlog_over_the_bar_pages_with_the_count
test_poll_is_throttled_and_stands_down_on_a_thin_rate_budget
test_an_unreadable_answer_is_silent_not_red
test_a_scheduled_workflow_is_judged_only_when_it_declares_a_schedule
test_classify_run_reads_one_run_live_with_its_evidence
test_status_and_arm
