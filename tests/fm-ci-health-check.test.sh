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
PER_PAGE=30
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

# runs_fixture <home> <owner/repo> <branch> <per-page> <row>...: the
# repository's runs as the per-workflow read sees them. Each row is
# "name|id|status|conclusion|created|head", optionally a seventh field event
# (push when absent); a conclusion of "null" is written as JSON null, the way
# GitHub answers for an unfinished run. The fixture answers the workflows list
# (one active workflow per distinct name, ids 1001 upward in order of first
# appearance) and, for each workflow, its completed runs on the branch, newest
# first, at most <per-page> of them, which is exactly what the API would hand
# back for status=completed.
runs_fixture() {
  local home=$1 repo=$2 branch=$3 per_page=$4 rows id n
  shift 4
  rows=$(printf '%s\n' "$@" | jq -R -s '
    split("\n") | map(select(length > 0) | split("|"))
    | map({ name: .[0], id: (.[1] | tonumber), status: .[2],
        conclusion: (if .[3] == "null" then null else .[3] end),
        created_at: .[4], head_sha: .[5], event: (.[6] // "push") })')
  printf '%s\n' "$rows" | jq '
    [.[].name] | unique_by(.) as $u
    | { total_count: ($u | length),
        workflows: [ range(0; $u | length) as $i
          | { id: (1001 + $i), name: $u[$i], state: "active",
              path: (".github/workflows/" + ($u[$i] | gsub("[^A-Za-z0-9]"; "-")) + ".yml") } ] }' \
    > "$(fixture_path "$home" "repos/$repo/actions/workflows?per_page=100&page=1")"
  n=$(printf '%s\n' "$rows" | jq -r '[.[].name] | unique_by(.) | length')
  for id in $(seq 1001 $((1000 + n))); do
    printf '%s\n' "$rows" | jq --argjson id "$id" --argjson n "$per_page" '
      ([.[].name] | unique_by(.)) as $u
      | { workflow_runs: ([ .[] | select(.name == $u[$id - 1001] and .status == "completed") ]
          | sort_by([.created_at, .id]) | reverse | .[0:$n]) }' \
      > "$(fixture_path "$home" "repos/$repo/actions/workflows/$id/runs?branch=$branch&status=completed&per_page=$per_page")"
  done
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
    FM_CI_HEALTH_PER_PAGE="$PER_PAGE" \
    FM_CI_HEALTH_REPOS='acme/widgets:main:10' FM_CI_HEALTH_SCHEDULED=' ' "$@" "$CHECK" check 2>&1
}

classify() {  # <status> <conclusion>
  "$CHECK" classify "$1" "$2"
}

# Requirement 1 and 4: the classifier's table, through the public command.
test_classifier_reads_only_a_finished_failure_as_red() {
  local c
  for c in failure timed_out startup_failure FAILURE ' failure '; do
    [ "$(classify completed "$c")" = red ] || fail "conclusion '$c' did not read as red: $(classify completed "$c")"
  done
  [ "$(classify completed cancelled)" = cancelled ] || fail "cancelled did not read as cancelled: $(classify completed cancelled)"
  [ "$(classify completed CANCELLED)" = cancelled ] || fail "CANCELLED did not read as cancelled"

  [ "$(classify completed success)" = green ] || fail "success did not read as green"
  [ "$(classify completed skipped)" = green ] || fail "skipped did not read as green"
  for s in queued in_progress waiting requested pending completed; do
    [ "$(classify "$s" null)" = pending ] || fail "status $s with a null conclusion did not read as pending: $(classify "$s" null)"
    [ "$(classify "$s" '')" = pending ] || fail "status $s with an empty conclusion did not read as pending: $(classify "$s" '')"
  done
  for c in stale action_required banana 'not a conclusion'; do
    [ "$(classify completed "$c")" = unknown ] || fail "conclusion '$c' did not read as unknown: $(classify completed "$c")"
  done
  pass "only failure, timed_out, and startup_failure read as red; null is pending; cancelled is cancelled; anything else is unknown"
}

# Requirement 2: a run that has not answered yet is never red and is never
# chosen. The 2026-11-19 shape, every workflow's newest run queued, in
# progress, waiting, or requested, prints nothing when the workflow's last
# answer was green or it has never answered. When its last answer was red that
# answer stands, named by its own run id, until a newer run completes: a
# standing failure cannot hide behind a run that is always in progress.
test_an_in_progress_newest_run_is_pending_and_prints_nothing() {
  local home out
  home=$(make_home pending)
  queued_fixture "$home" acme/widgets 0
  runs_fixture "$home" acme/widgets main "$PER_PAGE" \
    'verify-devops-agent-tests|44632777885|in_progress|null|2026-11-19T22:53:30Z|a1ba56fdf0000' \
    'verify-devops-agent-tests|44623276585|completed|success|2026-11-19T21:53:33Z|a9d29e8800000' \
    'Verify: pin-bump PRs run CI|44619765371|queued|null|2026-11-19T21:32:21Z|7ba1f876b0000' \
    'Verify: pin-bump PRs run CI|44616463852|completed|success|2026-11-19T21:12:46Z|8da6a08bd0000' \
    'deploy|5|waiting|null|2026-11-19T21:00:00Z|aaaaaaaaa0000' \
    'lint|6|requested|null|2026-11-19T20:59:00Z|bbbbbbbbb0000'
  out=$(poll "$home" 100000)
  [ -z "$out" ] || fail "a workflow whose newest run has not answered yet was reported: $out"
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$CHECK" status)
  assert_contains "$out" "verdict=quiet" "the quiet poll was not recorded as quiet"
  # The last answer of one workflow was red: that answer pages, named by its
  # own id, never the id of the run that has not answered.
  runs_fixture "$home" acme/widgets main "$PER_PAGE" \
    'verify-devops-agent-tests|44632777885|in_progress|null|2026-11-19T22:53:30Z|a1ba56fdf0000' \
    'verify-devops-agent-tests|44623276860|completed|failure|2026-11-19T21:53:33Z|a9d29e8800000'
  out=$(poll "$home" 100900)
  assert_contains "$out" "verify-devops-agent-tests run 44623276860 conclusion=failure" "the workflow's last answer, a failure, did not page while its newest run was in progress"
  assert_not_contains "$out" "44632777885" "the in-progress run was named as red"
  pass "a run that has not answered is never red and never chosen; the workflow's last answer stands"
}

# Requirement 3: a red names its evidence, and a genuine failure on the next
# poll still pages after a quiet one.
test_a_red_names_workflow_run_id_and_conclusion_and_still_pages_after_a_pending_poll() {
  local home out
  home=$(make_home red)
  queued_fixture "$home" acme/widgets 0
  runs_fixture "$home" acme/widgets main "$PER_PAGE" \
    'verify-devops-agent-tests|44632777885|in_progress|null|2026-11-19T22:53:30Z|a1ba56fdf0000' \
    'verify-devops-agent-tests|44623276860|completed|failure|2026-11-19T21:53:33Z|a9d29e8800000'
  out=$(poll "$home" 100000)
  assert_contains "$out" "verify-devops-agent-tests run 44623276860 conclusion=failure" "the last completed answer did not page while the newest run was in progress"
  assert_not_contains "$out" "44632777885" "an in-progress run was named"
  # The newer run finished red; the next poll (one interval later) names it.
  runs_fixture "$home" acme/widgets main "$PER_PAGE" \
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
  assert_not_contains "$out" "release run 8" "a cancelled newest run was reported as red"
  assert_not_contains "$out" "44623276860" "an older run of the same workflow was reported instead of the newest"
  assert_not_contains "$out" "docs run 9" "a green workflow was reported"
  pass "a red names the workflow, run id, conclusion, head, and the confirming command; cancelled is not red; a fresh failure pages after a pending poll"
}

# Requirement 4: an unrecognised conclusion is unknown, and unknown never pages.
test_an_unrecognised_conclusion_does_not_page() {
  local home out
  home=$(make_home unknown)
  queued_fixture "$home" acme/widgets 0
  runs_fixture "$home" acme/widgets main "$PER_PAGE" \
    'verify|11|completed|exploded|2026-11-19T22:53:30Z|a1ba56fdf0000' \
    'verify|10|completed|failure|2026-11-19T21:53:33Z|a9d29e8800000' \
    'lint|12|completed|stale|2026-11-19T22:53:30Z|b1ba56fdf0000' \
    'lint|13|completed|action_required|2026-11-19T22:50:30Z|c1ba56fdf0000'
  out=$(poll "$home" 100000)
  [ -z "$out" ] || fail "an unrecognised conclusion paged: $out"
  pass "an unrecognised or stale conclusion is unknown and does not page"
}

# Firstmate's re-scope of 2026-11-19: main really was red that hour, and the
# check could not see it. `Health: smoke (every 15 min)` run 44632006730
# concluded failure at 22:48Z on a schedule event, not a push, and the poll read
# push runs only. While that failure is the workflow's newest run, every poll
# must say red, and a cancelled run elsewhere must not.
test_a_scheduled_failure_on_the_branch_keeps_paging_until_it_is_replaced() {
  local home out
  home=$(make_home smoke)
  queued_fixture "$home" acme/widgets 0
  runs_fixture "$home" acme/widgets main "$PER_PAGE" \
    'verify-devops-agent-tests|44632777885|in_progress|null|2026-11-19T22:53:30Z|a1ba56fdf0000' \
    'Health: smoke (every 15 min)|44632006730|completed|failure|2026-11-19T22:48:19Z|a9d29e8800000' \
    'Health: smoke (every 15 min)|44631000000|completed|success|2026-11-19T22:33:19Z|a9d29e8800000' \
    'Deploy: web-credits-next|44630948368|completed|failure|2026-11-19T22:41:20Z|a9d29e8800000' \
    'verify-no-plaintext-db-credentials|44630000001|completed|cancelled|2026-11-19T22:40:00Z|a9d29e8800000'
  out=$(poll "$home" 100000)
  assert_contains "$out" "Health: smoke (every 15 min) run 44632006730 conclusion=failure" "the scheduled smoke failure was not reported"
  assert_contains "$out" "Deploy: web-credits-next run 44630948368 conclusion=failure" "the dispatched deploy failure was not reported"
  assert_not_contains "$out" "44630000001" "a cancelled run was reported as red"
  assert_not_contains "$out" "44632777885" "an in-progress run was reported as red"
  # Nothing changed: the next poll says red again, with the same evidence.
  out=$(poll "$home" 100900)
  assert_contains "$out" "Health: smoke (every 15 min) run 44632006730 conclusion=failure" "a standing failure stopped paging on the next poll"
  # The next scheduled run passes: the workflow is no longer red.
  runs_fixture "$home" acme/widgets main "$PER_PAGE" \
    'Health: smoke (every 15 min)|44633000000|completed|success|2026-11-19T23:03:19Z|a9d29e8800000' \
    'Health: smoke (every 15 min)|44632006730|completed|failure|2026-11-19T22:48:19Z|a9d29e8800000'
  out=$(poll "$home" 101800)
  [ -z "$out" ] || fail "a workflow whose newest run passed was still reported: $out"
  pass "a failure started by a schedule or a dispatch pages on every poll until a newer run of that workflow replaces it"
}

# Two runs of one workflow created in the same second: the higher run id is the
# newer one, whichever order the API listed them in.
test_same_second_runs_are_ordered_by_run_id() {
  local home out
  home=$(make_home tie)
  queued_fixture "$home" acme/widgets 0
  runs_fixture "$home" acme/widgets main "$PER_PAGE" \
    'verify|3|completed|success|2026-11-19T22:53:30Z|a1ba56fdf0000' \
    'verify|2|completed|failure|2026-11-19T22:53:30Z|a1ba56fdf0000'
  out=$(poll "$home" 100000)
  [ -z "$out" ] || fail "a same-second retry that passed was reported red from the run it replaced: $out"
  runs_fixture "$home" acme/widgets main "$PER_PAGE" \
    'verify|2|completed|success|2026-11-19T22:53:30Z|a1ba56fdf0000' \
    'verify|3|completed|failure|2026-11-19T22:53:30Z|a1ba56fdf0000'
  out=$(poll "$home" 100900)
  assert_contains "$out" "verify run 3 conclusion=failure" "a same-second retry that failed was hidden by the run it replaced"
  pass "same-second runs of one workflow are ordered by run id"
}

# A pull_request or pull_request_target run is keyed to the base branch and
# describes a pull request, not the branch tip: it must never make main red, and
# it must not hide the branch's own older run either.
test_a_pull_request_context_run_never_pages() {
  local home out
  home=$(make_home pr-context)
  queued_fixture "$home" acme/widgets 0
  runs_fixture "$home" acme/widgets main "$PER_PAGE" \
    'triage|21|completed|failure|2026-11-19T22:53:30Z|a1ba56fdf0000|pull_request_target' \
    'triage|20|completed|success|2026-11-19T21:53:33Z|a9d29e8800000|push' \
    'label|22|completed|failure|2026-11-19T22:54:30Z|b1ba56fdf0000|pull_request'
  out=$(poll "$home" 100000)
  [ -z "$out" ] || fail "a pull-request-context run was reported as main red: $out"
  pass "a pull_request or pull_request_target run is never a red signal for the branch"
}

# Every other event on the branch stays eligible, so a scheduled failure is a
# red of the branch and names its evidence.
test_a_schedule_event_failure_on_the_branch_pages() {
  local home out
  home=$(make_home schedule-event)
  queued_fixture "$home" acme/widgets 0
  runs_fixture "$home" acme/widgets main "$PER_PAGE" \
    'Health: smoke (every 15 min)|44632006730|completed|failure|2026-11-19T22:48:19Z|a9d29e8800000|schedule' \
    'Health: smoke (every 15 min)|44631000000|completed|success|2026-11-19T22:33:19Z|a9d29e8800000|schedule'
  out=$(poll "$home" 100000)
  assert_contains "$out" "Health: smoke (every 15 min) run 44632006730 conclusion=failure" "a schedule-event failure on the branch did not page"
  pass "a schedule-event failure on the branch pages with its run id and conclusion"
}

# Fable's two notes on 0a0b026b (firstmate, inbox 004). First: a workflow that
# tried to start and could not is a recognised, bad answer; startup_failure is
# red and pages, never unknown.
test_a_startup_failure_is_red_and_pages() {
  local home out
  home=$(make_home startup)
  queued_fixture "$home" acme/widgets 0
  runs_fixture "$home" acme/widgets main "$PER_PAGE" \
    'deploy|31|completed|startup_failure|2026-11-19T22:53:30Z|a1ba56fdf0000' \
    'deploy|30|completed|success|2026-11-19T21:53:33Z|a9d29e8800000'
  out=$(poll "$home" 100000)
  assert_contains "$out" "deploy run 31 conclusion=startup_failure" "a startup_failure did not page as red"
  [ "$(classify completed startup_failure)" = red ] || fail "startup_failure did not classify red"
  pass "a startup_failure is a recognised bad answer: red, and it pages"
}

# Second: a red must not age off a window. A workflow that runs rarely has its
# newest completed run far behind a chatty workflow's hundreds; the read is
# per workflow, so that red is found wherever it sits, and the branch's runs
# page is never what the check relies on.
test_a_red_older_than_the_window_still_pages_while_it_is_the_workflow_newest_completed_run() {
  local home out i rows=()
  home=$(make_home window)
  queued_fixture "$home" acme/widgets 0
  for i in $(seq 1 150); do
    rows+=("chatty|$((5000 + i))|completed|success|2026-11-19T$(printf '%02d:%02d' $((i / 60)) $((i % 60))):00Z|a1ba56fdf0000")
  done
  rows+=('rare-nightly|4000|completed|failure|2026-11-18T03:00:00Z|a9d29e8800000|schedule')
  runs_fixture "$home" acme/widgets main "$PER_PAGE" "${rows[@]}"
  # The branch's newest hundred runs, had the check asked for them, hold no
  # trace of the rare workflow; the fixture answers that page too, so a check
  # that still read it would get a page with no red in it.
  printf '%s\n' "${rows[@]:0:100}" | jq -R -s '
    split("\n") | map(select(length > 0) | split("|"))
    | { workflow_runs: map({ name: .[0], id: (.[1] | tonumber), status: .[2], conclusion: .[3],
        created_at: .[4], head_sha: .[5], event: "push" }) }' \
    > "$(fixture_path "$home" 'repos/acme/widgets/actions/runs?branch=main&per_page=100')"
  out=$(poll "$home" 100000)
  assert_contains "$out" "rare-nightly run 4000 conclusion=failure" "a red beyond the branch's first hundred runs was not found"
  assert_not_contains "$out" "chatty" "the green chatty workflow was reported"
  grep -q 'actions/workflows/1002/runs?branch=main&status=completed' "$home/gh.calls" || fail "the rare workflow was not read on its own"
  grep -q 'actions/runs?branch=main' "$home/gh.calls" && fail "the check still read the branch's runs page"
  pass "a red older than any window still pages while it is its workflow's newest completed run"
}

test_queued_backlog_over_the_bar_pages_with_the_count() {
  local home out
  home=$(make_home queued)
  queued_fixture "$home" acme/widgets 11
  runs_fixture "$home" acme/widgets main "$PER_PAGE" 'verify|1|completed|success|2026-11-19T22:53:30Z|a1ba56fdf0000'
  out=$(poll "$home" 100000)
  assert_contains "$out" "acme/widgets queued=11 (>10)" "a queued backlog over the bar was not reported"
  pass "a queued backlog over the repository's bar pages with the count and the bar"
}

test_poll_is_throttled_and_stands_down_on_a_thin_rate_budget() {
  local home out calls
  home=$(make_home throttle)
  queued_fixture "$home" acme/widgets 0
  runs_fixture "$home" acme/widgets main "$PER_PAGE" 'verify|1|completed|failure|2026-11-19T22:53:30Z|a1ba56fdf0000'
  out=$(poll "$home" 100000)
  assert_contains "$out" "verify run 1 conclusion=failure" "the first poll did not page"
  calls=$(wc -l < "$home/gh.calls" | tr -d ' ')
  out=$(poll "$home" 100500)
  [ -z "$out" ] || fail "a poll inside the interval printed: $out"
  [ "$(wc -l < "$home/gh.calls" | tr -d ' ')" = "$calls" ] || fail "a poll inside the interval made API calls"
  printf '{"resources":{"core":{"remaining":100}}}\n' > "$home/api/rate_limit"
  out=$(poll "$home" 100900)
  [ -z "$out" ] || fail "a poll on a thin rate budget printed: $out"
  grep -q 'repos/acme/widgets/actions/workflows' <(tail -n +$((calls + 1)) "$home/gh.calls") && fail "a poll on a thin rate budget still read runs"
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$CHECK" status)
  assert_contains "$out" "stood down: 100 core calls remaining" "the stand-down was not recorded"
  pass "polls are throttled to the interval and stand down below the rate floor without reading runs"
}

test_an_unreadable_rate_limit_is_not_reported_as_a_stand_down() {
  local home out
  home=$(make_home rate-unreadable)
  rm -f "$home/api/rate_limit"
  out=$(poll "$home" 100000)
  [ -z "$out" ] || fail "an unreadable rate limit printed: $out"
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$CHECK" status)
  assert_contains "$out" "rate limit unreadable" "an unreadable rate limit was not recorded as such"
  case "$out" in
    *"stood down"*) fail "an unreadable rate limit was reported as a rate stand-down: $out" ;;
  esac
  pass "an unreadable rate-limit answer is recorded as unreadable, never as a rate stand-down"
}

test_an_unreadable_answer_is_silent_not_red() {
  local home out
  home=$(make_home unreadable)
  queued_fixture "$home" acme/widgets 0
  printf 'HTTP 502 bad gateway\n' > "$(fixture_path "$home" 'repos/acme/widgets/actions/workflows?per_page=100&page=1')"
  out=$(poll "$home" 100000)
  [ -z "$out" ] || fail "an unreadable runs answer printed: $out"
  rm -f "$(fixture_path "$home" 'repos/acme/widgets/actions/workflows?per_page=100&page=1')"
  out=$(poll "$home" 101000)
  [ -z "$out" ] || fail "a failed runs call printed: $out"
  pass "an unreadable or failed runs read is silent, never red"
}

test_unreadable_workflow_reads_are_counted_but_stay_silent() {
  local home out
  home=$(make_home partial-sweep)
  queued_fixture "$home" acme/widgets 0
  jq -n '{ total_count: 2,
    workflows: [ { id: 1001, name: "alpha", state: "active" },
                 { id: 1002, name: "beta", state: "active" } ] }' \
    > "$(fixture_path "$home" 'repos/acme/widgets/actions/workflows?per_page=100&page=1')"
  out=$(poll "$home" 100000)
  [ -z "$out" ] || fail "unreadable per-workflow reads printed: $out"
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$CHECK" status)
  assert_contains "$out" "2 workflow reads in acme/widgets were skipped or unreadable" "a truncated sweep was recorded as plainly quiet"
  pass "unreadable per-workflow reads are counted in the verdict and stay silent"
}

test_a_repository_skipped_at_the_poll_deadline_is_counted() {
  local home out
  home=$(make_home repo-sweep-skipped)
  queued_fixture "$home" acme/widgets 0
  cat > "$home/fakebin/gh" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$home/gh.calls"
[ "\$1" = api ] || exit 1
case "\$2" in
  rate_limit) sleep 1.5 ;;
  *status=queued*) sleep 10 ;;
esac
f="$home/api/\$(printf '%s' "\$2" | tr '/?&=' '____')"
[ -f "\$f" ] || exit 1
cat "\$f"
SH
  chmod +x "$home/fakebin/gh"
  out=$(poll "$home" 100000 FM_CHECK_TIMEOUT=6)
  [ -z "$out" ] || fail "a repository skipped at the poll deadline printed: $out"
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$CHECK" status)
  assert_contains "$out" "repository acme/widgets not read: poll budget spent" "a repository skipped at the poll deadline was recorded as plainly quiet"
  pass "a repository abandoned at the poll deadline is named in the verdict and stays silent"
}

test_a_cadence_check_skipped_at_the_poll_deadline_is_counted() {
  local home out
  home=$(make_home cadence-skipped)
  cat > "$home/fakebin/gh" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$home/gh.calls"
[ "\$1" = api ] || exit 1
case "\$2" in
  *contents*) sleep 10 ;;
esac
f="$home/api/\$(printf '%s' "\$2" | tr '/?&=' '____')"
[ -f "\$f" ] || exit 1
cat "\$f"
SH
  chmod +x "$home/fakebin/gh"
  out=$(poll "$home" 100000 FM_CHECK_TIMEOUT=6 FM_CI_HEALTH_REPOS= \
    FM_CI_HEALTH_SCHEDULED='acme/widgets:smoke.yaml:7200')
  [ -z "$out" ] || fail "a cadence read skipped at the poll deadline printed: $out"
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$CHECK" status)
  assert_contains "$out" "cadence acme/widgets/smoke.yaml not judged: poll budget spent" "a cadence read skipped at the poll deadline was recorded as plainly quiet"
  pass "a cadence check abandoned at the poll deadline is named in the verdict and stays silent"
}

# A config file is the operator interface the docs describe: a multi-value line
# and numeric lines, with their comments on their own lines.
test_an_empty_repository_list_polls_quietly_without_a_scratch_dir() {
  local home out rc tmp
  home=$(make_home empty-repos)
  tmp="$home/tmp"
  mkdir -p "$tmp"
  out=$(poll "$home" 100000 FM_CI_HEALTH_REPOS= TMPDIR="$tmp")
  rc=$?
  [ "$rc" -eq 0 ] || fail "an empty repository list exited $rc: $out"
  [ -z "$out" ] || fail "an empty repository list printed: $out"
  find "$tmp" -maxdepth 1 -name 'fm-ci-health.*' | grep -q . && fail "an empty repository list left a scratch dir behind"
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$CHECK" status)
  assert_contains "$out" "quiet" "an empty repository list was not recorded as a quiet poll"
  pass "an empty repository list polls quietly, exits zero, and leaves no scratch dir"
}

test_a_workflow_on_the_second_list_page_is_read() {
  local home out
  home=$(make_home pagination)
  queued_fixture "$home" acme/widgets 0
  jq -n '{ total_count: 101,
    workflows: [ range(0; 100) as $i
      | { id: (1001 + $i), name: ("bulk-" + ($i | tostring)), state: "active" } ] }' \
    > "$(fixture_path "$home" 'repos/acme/widgets/actions/workflows?per_page=100&page=1')"
  jq -n '{ total_count: 101,
    workflows: [ { id: 1101, name: "rare-on-page-two", state: "active" } ] }' \
    > "$(fixture_path "$home" 'repos/acme/widgets/actions/workflows?per_page=100&page=2')"
  printf '%s\n' '{"workflow_runs":[{"name":"rare-on-page-two","id":9001,"status":"completed","conclusion":"failure","head_sha":"abc12345678","created_at":"2026-11-19T22:53:30Z","event":"push"}]}' \
    > "$(fixture_path "$home" 'repos/acme/widgets/actions/workflows/1101/runs?branch=main&status=completed&per_page=30')"
  out=$(poll "$home" 100000)
  assert_contains "$out" "rare-on-page-two run 9001 conclusion=failure" "a workflow on the workflow list's second page was not read"
  pass "the workflow list is paged until a short page, so a later page's workflow is still read"
}

test_a_partial_workflow_list_is_recorded_but_stays_silent() {
  local home out
  home=$(make_home partial-list)
  queued_fixture "$home" acme/widgets 0
  jq -n '{ total_count: 200,
    workflows: [ range(0; 100) as $i
      | { id: (1001 + $i), name: ("bulk-" + ($i | tostring)), state: "active" } ] }' \
    > "$(fixture_path "$home" 'repos/acme/widgets/actions/workflows?per_page=100&page=1')"
  out=$(poll "$home" 100000)
  [ -z "$out" ] || fail "a partial workflow list printed: $out"
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$CHECK" status)
  assert_contains "$out" "workflow list read only partially: acme/widgets" "a partial workflow list was not recorded"
  pass "a workflow list cut short by an unreadable page is recorded as partial and stays silent"
}

test_a_config_file_written_as_documented_is_parsed() {  # <home>
  local home=$1
  cat > "$home/config/ci-health.env" <<'ENV'
# owner/repo:branch:queued-bar
FM_CI_HEALTH_REPOS=acme/widgets:main:10 acme/gadgets:main:10
# owner/repo:workflow-file:max-age-secs
FM_CI_HEALTH_SCHEDULED=
# polls closer together than this are skipped
FM_CI_HEALTH_INTERVAL_SECS=100
# the routing reminder appended to a wake line
FM_CI_HEALTH_TRAILER=route each red to the lane that owns it; don't hand-apply
ENV
}

test_the_documented_config_file_shape_drives_the_poll() {
  local home out
  home=$(make_home config)
  test_a_config_file_written_as_documented_is_parsed "$home"
  queued_fixture "$home" acme/widgets 0
  queued_fixture "$home" acme/gadgets 0
  runs_fixture "$home" acme/widgets main "$PER_PAGE" 'verify|1|completed|failure|2026-11-19T22:53:30Z|a1ba56fdf0000'
  runs_fixture "$home" acme/gadgets main "$PER_PAGE" 'lint|2|completed|failure|2026-11-19T22:53:30Z|b1ba56fdf0000'
  out=$(env PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_CONFIG_OVERRIDE="$home/config" FM_CI_HEALTH_NOW=100000 FM_CI_HEALTH_TOKEN_ENV=none \
    "$CHECK" check 2>&1)
  assert_contains "$out" "acme/widgets main red:" "the first configured repository was not polled"
  assert_contains "$out" "acme/gadgets main red:" "the second configured repository was not polled"
  assert_contains "$out" "route each red to the lane that owns it; don't hand-apply" "the configured trailer was not read whole"
  out=$(env PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_CONFIG_OVERRIDE="$home/config" FM_CI_HEALTH_NOW=100050 FM_CI_HEALTH_TOKEN_ENV=none \
    "$CHECK" check 2>&1)
  [ -z "$out" ] || fail "a poll inside the configured interval printed: $out"
  out=$(env PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_CONFIG_OVERRIDE="$home/config" FM_CI_HEALTH_NOW=100150 FM_CI_HEALTH_TOKEN_ENV=none \
    "$CHECK" check 2>&1)
  assert_contains "$out" "acme/widgets main red:" "the configured interval of 100s was not read"
  pass "a config file written as documented is parsed and drives the poll"
}

test_a_tilde_token_env_path_is_expanded() {
  local home out
  home=$(make_home tilde)
  cat > "$home/fakebin/gh" <<SH
#!/usr/bin/env bash
printf '%s\n' "\${GH_TOKEN:-none}" >> "$home/token.seen"
[ "\$1" = api ] || exit 1
f="$home/api/\$(printf '%s' "\$2" | tr '/?&=' '____')"
[ -f "\$f" ] || exit 1
cat "\$f"
SH
  chmod +x "$home/fakebin/gh"
  printf 'export GH_TOKEN=tok-from-file\n' > "$home/app-token.env"
  printf 'FM_CI_HEALTH_TOKEN_ENV=~/app-token.env\n' > "$home/config/ci-health.env"
  queued_fixture "$home" acme/widgets 0
  runs_fixture "$home" acme/widgets main "$PER_PAGE" 'verify|1|completed|success|2026-11-19T22:53:30Z|a1ba56fdf0000'
  out=$(env PATH="$home/fakebin:$PATH" HOME="$home" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_CONFIG_OVERRIDE="$home/config" FM_CI_HEALTH_NOW=100000 FM_CI_HEALTH_REPOS='acme/widgets:main:10' \
    FM_CI_HEALTH_SCHEDULED=' ' "$CHECK" check 2>&1)
  [ -z "$out" ] || fail "the poll printed: $out"
  assert_contains "$(cat "$home/token.seen")" "tok-from-file" "a ~/ token env path was not expanded and sourced"
  pass "a configured ~/ token env path is expanded and sourced"
}

test_a_scheduled_workflow_is_judged_only_when_it_declares_a_schedule() {
  local home out wf_plain wf_sched
  home=$(make_home cadence)
  queued_fixture "$home" acme/widgets 0
  runs_fixture "$home" acme/widgets main "$PER_PAGE" 'verify|1|completed|success|2026-11-19T22:53:30Z|a1ba56fdf0000'
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
  runs_fixture "$home" acme/widgets main "$PER_PAGE" 'verify|1|completed|failure|2026-11-19T22:53:30Z|a1ba56fdf0000'
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
test_a_scheduled_failure_on_the_branch_keeps_paging_until_it_is_replaced
test_same_second_runs_are_ordered_by_run_id
test_a_pull_request_context_run_never_pages
test_a_schedule_event_failure_on_the_branch_pages
test_a_startup_failure_is_red_and_pages
test_a_red_older_than_the_window_still_pages_while_it_is_the_workflow_newest_completed_run
test_queued_backlog_over_the_bar_pages_with_the_count
test_poll_is_throttled_and_stands_down_on_a_thin_rate_budget
test_an_unreadable_rate_limit_is_not_reported_as_a_stand_down
test_an_unreadable_answer_is_silent_not_red
test_unreadable_workflow_reads_are_counted_but_stay_silent
test_a_repository_skipped_at_the_poll_deadline_is_counted
test_a_cadence_check_skipped_at_the_poll_deadline_is_counted
test_an_empty_repository_list_polls_quietly_without_a_scratch_dir
test_a_workflow_on_the_second_list_page_is_read
test_a_partial_workflow_list_is_recorded_but_stays_silent
test_a_scheduled_workflow_is_judged_only_when_it_declares_a_schedule
test_the_documented_config_file_shape_drives_the_poll
test_a_tilde_token_env_path_is_expanded
test_classify_run_reads_one_run_live_with_its_evidence
test_status_and_arm
