#!/usr/bin/env bash
# Tests for bin/fm-sentry-watch.sh, the firstmate-owned Sentry watch.
#
# These cases pin the two failures the watch exists to prevent. First, the
# 2026-09-22 CORE-BACKEND-11N miss: a fatal onboarding issue reached ten events
# with few users and never paged, because the only watch paged NEW issues only at
# users>=3. test_sensitive_route_pages_at_one_user reproduces it. Second, the
# silent deletion of that same watch: polling stopped and nothing alarmed.
# test_missing_beat_is_dark and test_wake_drain_reports_a_deleted_check pin the
# check-side and drain-side halves of the DARK wake.
#
# Every case drives the real script through its fixture seams and asserts on the
# one line it prints, so no case touches the Sentry API, GitHub, or the network.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SW="$ROOT/bin/fm-sentry-watch.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"
TMP_ROOT=$(fm_test_tmproot fm-sentry-watch)

make_home() {  # <name>
  local name=$1 home
  home="$TMP_ROOT/$name"
  mkdir -p "$home/state" "$home/config" "$home/fix"
  printf '%s\n' "$home"
}

write_projects() {  # <home> <slug>...
  local home=$1
  shift
  python3 - "$home/fix/projects.json" "$@" <<'PY'
import json, sys
json.dump([{"slug": slug} for slug in sys.argv[2:]], open(sys.argv[1], "w"))
PY
}

write_issues() {  # <home> <slug>  (JSON on stdin)
  local home=$1 slug=$2
  cat > "$home/fix/issues-$slug.json"
}

write_rail() {  # <home>  (JSON on stdin)
  local home=$1
  cat > "$home/fix/rail.json"
}

write_config() {  # <home>  (JSON on stdin)
  local home=$1
  cat > "$home/config/sentry-watch.json"
}

# mark_armed runs the real arm, so the registration the poll checks is genuine,
# then pins the beat to the case's frozen clock.
mark_armed() {  # <home> [<beat>]
  local home=$1 beat=${2:-$(date +%s)}
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" \
    "$SW" arm >/dev/null || fail "could not arm the fixture home"
  printf '%s\n' "$beat" > "$home/state/.sentry-watch.beat"
}

poll() {  # <home> <now>
  local home=$1 now=$2
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SENTRY_WATCH_FIXTURES="$home/fix" FM_SENTRY_WATCH_NOW="$now" \
    "$SW" poll 2>/dev/null
}

# prime_baseline runs one empty poll so the next poll is not a first poll. The
# first poll records the estate and wakes nobody by design, so every rule case
# needs a baseline behind it.
prime_baseline() {  # <home> <now>
  local home=$1 now=$2
  write_projects "$home" core-backend
  printf '[]\n' > "$home/fix/issues-core-backend.json"
  printf '[]\n' > "$home/fix/rail.json"
  mark_armed "$home" "$now"
  poll "$home" "$now" >/dev/null
}

test_first_poll_records_the_estate_and_wakes_nobody() {
  local home out
  home=$(make_home baseline)
  write_projects "$home" core-backend
  write_issues "$home" core-backend <<'JSON'
[{"shortId":"CORE-BACKEND-AAA","title":"TypeError: boom","culprit":"/api/v4/onboarding/name","userCount":1,"count":2,"level":"fatal","substatus":"new","permalink":"https://x/1/"}]
JSON
  printf '[]\n' > "$home/fix/rail.json"
  mark_armed "$home" 1000
  out=$(poll "$home" 1000)
  [ -z "$out" ] || fail "the first poll woke on the estate it was recording: $out"
  assert_grep 'CORE-BACKEND-AAA' "$home/state/sentry-watch.baseline.json" \
    "the first poll did not record the issue"
  pass "the first poll records the estate and wakes nobody"
}

test_sensitive_route_pages_at_one_user() {
  local home out
  home=$(make_home sensitive)
  prime_baseline "$home" 1000
  write_issues "$home" core-backend <<'JSON'
[{"shortId":"CORE-BACKEND-EEE","title":"TypeError: null name","culprit":"/api/v4/onboarding/name","userCount":1,"count":2,"level":"fatal","substatus":"new","permalink":"https://x/5/"}]
JSON
  out=$(poll "$home" 1300)
  assert_contains "$out" "P1 CORE-BACKEND-EEE" "a one-user fatal on a sensitive route did not page"
  assert_contains "$out" "rule=sensitive users>=1" "the sensitive-route rule was not named"
  assert_contains "$out" "permalink=https://x/5/" "the wake line lost the issue permalink"
  pass "a single-user fatal on a sensitive route pages"
}

test_nonsensitive_route_pages_at_three_users() {
  local home out
  home=$(make_home nonsensitive)
  prime_baseline "$home" 1000
  write_issues "$home" core-backend <<'JSON'
[{"shortId":"CORE-BACKEND-FFF","title":"TypeError: boom","culprit":"/api/v4/feed/profile/9/follows","userCount":2,"count":4,"level":"error","substatus":"new","permalink":"https://x/6/"}]
JSON
  out=$(poll "$home" 1300)
  [ -z "$out" ] || fail "a two-user non-sensitive error paged: $out"

  home=$(make_home nonsensitive-three)
  prime_baseline "$home" 1000
  write_issues "$home" core-backend <<'JSON'
[{"shortId":"CORE-BACKEND-FFF","title":"TypeError: boom","culprit":"/api/v4/feed/profile/9/follows","userCount":3,"count":4,"level":"error","substatus":"new","permalink":"https://x/6/"}]
JSON
  out=$(poll "$home" 1300)
  assert_contains "$out" "P1 CORE-BACKEND-FFF" "a three-user error elsewhere did not page"
  assert_contains "$out" "rule=users>=3" "the elsewhere rule was not named"
  pass "a non-sensitive route needs three users"
}

test_burst_pages_regardless_of_users() {
  local home out
  home=$(make_home burst)
  prime_baseline "$home" 1000
  write_issues "$home" core-backend <<'JSON'
[{"shortId":"CORE-BACKEND-DDD","title":"OOMKilled","culprit":"/api/v4/x","userCount":0,"count":5,"level":"fatal","substatus":"ongoing","permalink":"https://x/4/"}]
JSON
  poll "$home" 1300 >/dev/null
  write_issues "$home" core-backend <<'JSON'
[{"shortId":"CORE-BACKEND-DDD","title":"OOMKilled","culprit":"/api/v4/x","userCount":1,"count":20,"level":"fatal","substatus":"ongoing","permalink":"https://x/4/"}]
JSON
  out=$(poll "$home" 1600)
  assert_contains "$out" "P0 CORE-BACKEND-DDD" "a burst did not page as P0"
  assert_contains "$out" "rule=burst>=10" "the burst rule was not named"
  pass "a burst pages as P0 regardless of users"
}

test_transport_burst_still_pages() {
  local home out
  home=$(make_home transport-burst)
  prime_baseline "$home" 1000
  # CORE-BACKEND-VD on 2026-09-22 was literally "socket hang up": a transport
  # signature must never be able to hide the request-reset cascade it describes.
  write_issues "$home" core-backend <<'JSON'
[{"shortId":"CORE-BACKEND-VD","title":"Error: socket hang up","culprit":"/api/v4/feed/profile/2/activities","userCount":1,"count":30,"level":"error","substatus":"new","permalink":"https://x/9/"}]
JSON
  out=$(poll "$home" 1300)
  assert_contains "$out" "P0 CORE-BACKEND-VD" "a transport burst was silenced"
  assert_contains "$out" "rule=burst>=10" "the transport burst did not name the burst rule"
  pass "a transport signature never hides a burst"
}

test_regression_pages_when_a_resolved_issue_refires() {
  local home out
  home=$(make_home regression)
  prime_baseline "$home" 1000
  write_issues "$home" core-backend <<'JSON'
[{"shortId":"CORE-BACKEND-GGG","title":"TypeError: came back","culprit":"/api/v4/chat/matrix-token-me","userCount":1,"count":1,"level":"error","substatus":"new","permalink":"https://x/7/"}]
JSON
  poll "$home" 1300 >/dev/null
  write_issues "$home" core-backend <<'JSON'
[{"shortId":"CORE-BACKEND-GGG","title":"TypeError: came back","culprit":"/api/v4/chat/matrix-token-me","userCount":2,"count":1,"level":"error","substatus":"regressed","permalink":"https://x/7/"}]
JSON
  out=$(poll "$home" 1600)
  assert_contains "$out" "REGRESSION CORE-BACKEND-GGG" "a regressed issue did not page"
  assert_contains "$out" "rule=regressed" "the regression rule was not named"
  pass "a resolved issue that re-fires pages as a regression"
}

test_noise_stays_silent() {
  local home out
  home=$(make_home noise)
  prime_baseline "$home" 1000
  write_issues "$home" core-backend <<'JSON'
[{"shortId":"CORE-BACKEND-HHH","title":"TypeError: Failed to fetch","culprit":"/api/v4/onboarding/name","userCount":4,"count":12,"level":"error","substatus":"new","permalink":"https://x/8/"}]
JSON
  out=$(poll "$home" 1300)
  [ -z "$out" ] || fail "a noise signature paged: $out"
  pass "a noise signature stays silent even on a sensitive route"
}

test_page_any_delta_pages_on_a_single_event() {
  local home out
  home=$(make_home page-any)
  prime_baseline "$home" 1000
  write_issues "$home" core-backend <<'JSON'
[{"shortId":"CORE-BACKEND-11N","title":"TypeError: null","culprit":"/api/v4/user","userCount":1,"count":10,"level":"error","substatus":"ongoing","permalink":"https://x/11/"}]
JSON
  poll "$home" 1300 >/dev/null
  write_issues "$home" core-backend <<'JSON'
[{"shortId":"CORE-BACKEND-11N","title":"TypeError: null","culprit":"/api/v4/user","userCount":1,"count":11,"level":"error","substatus":"ongoing","permalink":"https://x/11/"}]
JSON
  out=$(poll "$home" 1600)
  assert_contains "$out" "PAGE-NOW CORE-BACKEND-11N" "a page-any-delta issue did not page on one event"
  assert_contains "$out" "rule=page-any-delta" "the page-any-delta rule was not named"
  pass "a page-any-delta id pages on a single new event"
}

test_api_error_is_could_not_determine_not_silence() {
  local home out
  home=$(make_home api-error)
  write_projects "$home" core-backend android
  printf '[]\n' > "$home/fix/issues-core-backend.json"
  printf '[]\n' > "$home/fix/rail.json"
  mark_armed "$home" 1000
  poll "$home" 1000 >/dev/null
  # The android fixture is deliberately absent: one unreadable project must be
  # reported, and must not stop the readable one from being polled.
  out=$(poll "$home" 1300)
  assert_contains "$out" "could-not-determine android" "an unreadable project was not reported"
  pass "an unreadable project is could-not-determine, never silence"
}

test_missing_beat_is_dark() {
  local home out
  home=$(make_home dark)
  prime_baseline "$home" 1000
  rm -f "$home/state/.sentry-watch.beat"
  out=$(poll "$home" 1300)
  assert_contains "$out" "DARK no beat recorded" "a missing beat did not emit a DARK wake"
  pass "a missing beat emits a DARK wake"

  home=$(make_home dark-stale)
  prime_baseline "$home" 1000
  printf '1000\n' > "$home/state/.sentry-watch.beat"
  out=$(poll "$home" 5000)
  assert_contains "$out" "DARK beat" "a stale beat did not emit a DARK wake"
  pass "a beat older than three cadences emits a DARK wake"
}

test_rail_only_detection() {
  local home out
  home=$(make_home rail-only)
  prime_baseline "$home" 1000
  write_rail "$home" <<'JSON'
[{"url":"https://github.com/Muso-AI/core-backend/pull/9999","headRefName":"cto/sentry-core-backend-zzz-20260922-000000","body":"Fixes CORE-BACKEND-ZZZ"}]
JSON
  out=$(poll "$home" 1300)
  assert_contains "$out" "RAIL-ONLY CORE-BACKEND-ZZZ" "a rail fix the watch never surfaced was not reported"
  assert_contains "$out" "https://github.com/Muso-AI/core-backend/pull/9999" "the rail-only wake lost the PR URL"
  out=$(poll "$home" 1600)
  assert_not_contains "$out" "RAIL-ONLY" "the same rail-only finding reported twice"
  pass "a rail fix the watch never surfaced is reported once with its PR URL"
}

test_rail_only_is_suppressed_when_the_watch_surfaced_it() {
  local home out
  home=$(make_home rail-surfaced)
  prime_baseline "$home" 1000
  write_issues "$home" core-backend <<'JSON'
[{"shortId":"CORE-BACKEND-ZZZ","title":"TypeError: null","culprit":"/api/v4/onboarding/name","userCount":1,"count":1,"level":"fatal","substatus":"new","permalink":"https://x/z/"}]
JSON
  write_rail "$home" <<'JSON'
[{"url":"https://github.com/Muso-AI/core-backend/pull/9999","headRefName":"cto/sentry-core-backend-zzz-20260922-000000","body":"Fixes CORE-BACKEND-ZZZ"}]
JSON
  out=$(poll "$home" 1300)
  assert_contains "$out" "P1 CORE-BACKEND-ZZZ" "the watch did not surface the issue itself"
  assert_not_contains "$out" "RAIL-ONLY" "an issue the watch surfaced was still called a rail-only disagreement"
  pass "the rail cross-check never calls a surfaced fix a silent disagreement"
}

test_projects_lists_every_project_with_its_effective_state() {
  local home out
  home=$(make_home projects)
  write_projects "$home" core-backend flutter android
  write_config "$home" <<'JSON'
{"denylist":["flutter"]}
JSON
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SENTRY_WATCH_FIXTURES="$home/fix" "$SW" projects 2>/dev/null)
  assert_contains "$out" "core-backend	enabled" "an API project was not listed as enabled"
  assert_contains "$out" "flutter	disabled" "a denylisted project was not disabled"
  assert_contains "$out" "android	enabled" "an allowlist-free project was not enabled"
  pass "projects lists every API project with its effective state"
}

test_migrate_imports_the_retired_baselines() {
  local home out
  home=$(make_home migrate)
  cat > "$home/state/sentry-backend-watch-b1.last.json" <<'JSON'
{"CORE-BACKEND-OLD":{"users":7,"title":"old","culprit":"/api/v4/x","count":12,"level":"error","ts":1000}}
JSON
  cat > "$home/state/sentry-mobile-s1.last.json" <<'JSON'
{"APPLE-IOS-OLD":{"users":2,"title":"ios old","permalink":"https://x/","ts":900}}
JSON
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SENTRY_WATCH_NOW=1000 "$SW" migrate 2>/dev/null)
  assert_contains "$out" "imported 2 issues" "migrate did not import both retired baselines"
  assert_grep 'CORE-BACKEND-OLD' "$home/state/sentry-watch.baseline.json" "the backend baseline was not imported"
  assert_grep 'APPLE-IOS-OLD' "$home/state/sentry-watch.baseline.json" "the mobile baseline was not imported"
  pass "migrate imports both retired per-lane baselines"
}

test_arm_refuses_an_id_that_is_also_a_task() {
  local home status
  home=$(make_home arm-task-id)
  printf 'window=sentry-watch\n' > "$home/state/sentry-watch.meta"
  status=0
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" \
    "$SW" arm >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "arm accepted a check id that is also a task id"
  assert_absent "$home/state/sentry-watch.check.sh" \
    "arm wrote the watch at a path a task's own PR poll would also write"
  pass "arm refuses an id that is also a live task"
}

test_arm_registers_and_disarm_removes() {
  local home status
  home=$(make_home arm)
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" \
    "$SW" arm >/dev/null || fail "arm failed"
  assert_present "$home/state/sentry-watch.check.sh" "arm did not write the check shim"
  assert_present "$home/state/sentry-watch.check-trust" "arm did not bind the check bytes"
  assert_present "$home/state/.sentry-watch.beat" "arm did not seed the beat"
  assert_present "$home/state/.sentry-watch.armed" "arm did not write the armed marker"
  assert_grep 'fm-custom-check-v1' "$home/state/sentry-watch.check-trust" \
    "the trust binding has the wrong schema"
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" \
    "$SW" arm >/dev/null || fail "arming twice failed"

  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" \
    "$SW" disarm >/dev/null || fail "disarm failed"
  assert_absent "$home/state/sentry-watch.check.sh" "disarm left the check shim behind"
  assert_absent "$home/state/sentry-watch.check-trust" "disarm left the trust binding behind"
  assert_absent "$home/state/.sentry-watch.beat" "disarm left the beat behind"
  assert_absent "$home/state/.sentry-watch.armed" "disarm left the armed marker behind"
  pass "arm registers a trusted check and disarm removes every trace"
}

test_a_task_pr_poll_cannot_touch_the_watch() {
  local home status
  home=$(make_home pr-poll-separation)
  mark_armed "$home" 1000
  cp "$home/state/sentry-watch.check.sh" "$home/watch.shim.before"
  cp "$home/state/sentry-watch.check-trust" "$home/watch.trust.before"
  # The 2026-09-22 incident: a task's own PR poll writes state/<task>.check.sh,
  # so a check named after its task is overwritten when that task's PR is armed
  # and deleted when the poll retires. This watch's path is not task-derived, and
  # this case proves a real PR poll for another task leaves it byte-identical.
  cat > "$home/state/sample-task.meta" <<EOF
window=sample-task
endpoint_task_id=sample-task
worktree=$home
project=$home
harness=pi
kind=ship
mode=no-mistakes
yolo=off
EOF
  status=0
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" \
    "$ROOT/bin/fm-pr-check.sh" sample-task https://github.com/Muso-AI/core-backend/pull/12345 \
    >/dev/null 2>&1 || status=$?
  expect_code 0 "$status" "the task PR poll was not armed"
  assert_present "$home/state/sample-task.check.sh" "the task PR poll did not write its own check"
  cmp -s "$home/watch.shim.before" "$home/state/sentry-watch.check.sh" \
    || fail "the task PR poll overwrote the Sentry watch shim"
  cmp -s "$home/watch.trust.before" "$home/state/sentry-watch.check-trust" \
    || fail "the task PR poll overwrote the Sentry watch trust binding"
  pass "a task PR poll writes its own check and leaves the Sentry watch untouched"
}

test_an_overwritten_check_is_dark() {
  local home out
  home=$(make_home overwritten)
  prime_baseline "$home" 1000
  # A PR poll that landed on the watch's path leaves both files present but the
  # trust binding no longer covers the shim's bytes. Presence alone must not read
  # as healthy, so the poll has to catch the mismatch.
  printf '#!/usr/bin/env bash\n# a task PR poll wrote this\nexit 0\n' \
    > "$home/state/sentry-watch.check.sh"
  out=$(poll "$home" 1300)
  assert_contains "$out" "DARK the trust binding does not cover the current check bytes" \
    "an in-place overwrite of the check was not caught as DARK"
  pass "an overwritten check is caught by its trust binding, not read as healthy"
}

test_wake_drain_reports_a_deleted_check() {
  local home out
  home=$(make_home drain-dark)
  mkdir -p "$home/data"
  cat > "$home/state/.sentry-watch.armed" <<EOF
schema=fm-sentry-watch-armed-v1
cadence=300
shim=$home/state/sentry-watch.check.sh
trust=$home/state/sentry-watch.check-trust
beat=$home/state/.sentry-watch.beat
EOF
  out=$(FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" \
    "$DRAIN" 2>/dev/null)
  assert_contains "$out" "SENTRY WATCH DARK" "a deleted Sentry check did not surface on the drain"
  assert_contains "$out" "re-arm it with bin/fm-sentry-watch.sh arm" \
    "the DARK line did not name the re-arm command"

  : > "$home/state/sentry-watch.check.sh"
  : > "$home/state/sentry-watch.check-trust"
  printf '%s\n' "$(date +%s)" > "$home/state/.sentry-watch.beat"
  out=$(FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" \
    "$DRAIN" 2>/dev/null)
  assert_not_contains "$out" "SENTRY WATCH DARK" "a healthy watch still reported DARK on the drain"
  pass "the drain surfaces a deleted Sentry check and stays silent while it is healthy"
}

test_status_reports_the_liveness_verdict() {
  local home out
  home=$(make_home status)
  prime_baseline "$home" 1000
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SENTRY_WATCH_NOW=1300 "$SW" status 2>/dev/null)
  assert_contains "$out" "live: OK" "a healthy watch did not report itself live"
  rm -f "$home/state/.sentry-watch.beat"
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SENTRY_WATCH_NOW=1300 "$SW" status 2>/dev/null)
  assert_contains "$out" "DARK" "status hid a missing beat"
  pass "status reports the liveness verdict"
}

test_first_poll_records_the_estate_and_wakes_nobody
test_sensitive_route_pages_at_one_user
test_nonsensitive_route_pages_at_three_users
test_burst_pages_regardless_of_users
test_transport_burst_still_pages
test_regression_pages_when_a_resolved_issue_refires
test_noise_stays_silent
test_page_any_delta_pages_on_a_single_event
test_api_error_is_could_not_determine_not_silence
test_missing_beat_is_dark
test_rail_only_detection
test_rail_only_is_suppressed_when_the_watch_surfaced_it
test_projects_lists_every_project_with_its_effective_state
test_migrate_imports_the_retired_baselines
test_a_task_pr_poll_cannot_touch_the_watch
test_an_overwritten_check_is_dark
test_arm_refuses_an_id_that_is_also_a_task
test_arm_registers_and_disarm_removes
test_wake_drain_reports_a_deleted_check
test_status_reports_the_liveness_verdict
