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
# lines it prints, so no case touches the Sentry API, GitHub, or the network.
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
  # A ramp on the second read is exactly what the burst rule exists to catch.
  write_issues "$home" core-backend <<'JSON'
[{"shortId":"CORE-BACKEND-DDD","title":"OOMKilled","culprit":"/api/v4/x","userCount":1,"count":20,"level":"fatal","substatus":"ongoing","permalink":"https://x/4/"}]
JSON
  out=$(poll "$home" 1600)
  assert_contains "$out" "P0 CORE-BACKEND-DDD" "a burst did not page as P0"
  assert_contains "$out" "rule=burst>=10" "the burst rule was not named"
  pass "a burst pages as P0 regardless of users"
}

test_new_issue_ramp_pages_on_its_second_read() {
  local home out
  home=$(make_home ramp)
  prime_baseline "$home" 1000
  # The 11N shape on a non-sensitive route: few users, rising events. Five
  # events at first read is below every first-read rule; thirty-five more in
  # the next window must page, and the storm must not re-page every window.
  write_issues "$home" core-backend <<'JSON'
[{"shortId":"CORE-BACKEND-RMP","title":"TypeError: ramp","culprit":"/api/v4/feed/profile/3/activities","userCount":1,"count":5,"level":"error","substatus":"new","firstSeen":"1970-01-01T00:18:00Z","permalink":"https://x/rmp/"}]
JSON
  out=$(poll "$home" 1300)
  [ -z "$out" ] || fail "five events at first read paged: $out"
  write_issues "$home" core-backend <<'JSON'
[{"shortId":"CORE-BACKEND-RMP","title":"TypeError: ramp","culprit":"/api/v4/feed/profile/3/activities","userCount":2,"count":40,"level":"error","substatus":"ongoing","firstSeen":"1970-01-01T00:18:00Z","permalink":"https://x/rmp/"}]
JSON
  out=$(poll "$home" 1600)
  assert_contains "$out" "P0 CORE-BACKEND-RMP" "a ramp on the second read did not page"
  assert_contains "$out" "rule=burst>=10/window" "the burst rule was not named"
  write_issues "$home" core-backend <<'JSON'
[{"shortId":"CORE-BACKEND-RMP","title":"TypeError: ramp","culprit":"/api/v4/feed/profile/3/activities","userCount":2,"count":80,"level":"error","substatus":"ongoing","firstSeen":"1970-01-01T00:18:00Z","permalink":"https://x/rmp/"}]
JSON
  out=$(poll "$home" 1900)
  assert_not_contains "$out" "P0 CORE-BACKEND-RMP" "a sustained storm re-paged on the next window"
  pass "a new issue's ramp pages on its second read and a sustained storm pages once"
}

test_burst_is_a_window_rate_not_a_gap_total() {
  local home out
  home=$(make_home gap-total)
  # The arming-day shape: a chronic issue imported from the retired check at
  # count=100, read again four hours later at count=115. Fifteen events over
  # four hours is a trickle, not a burst, and an imported entry has no rate
  # until this watch has read it twice.
  cat > "$home/state/sentry-backend-watch-b1.last.json" <<'JSON'
{"CORE-BACKEND-CHR":{"users":4,"title":"TypeError: chronic","culprit":"/api/v4/feed/x","count":100,"level":"error","rate":9.0,"ts":1000}}
JSON
  write_projects "$home" core-backend
  write_issues "$home" core-backend <<'JSON'
[{"shortId":"CORE-BACKEND-CHR","title":"TypeError: chronic","culprit":"/api/v4/feed/x","userCount":4,"count":115,"level":"error","substatus":"ongoing","permalink":"https://x/chr/"}]
JSON
  printf '[]\n' > "$home/fix/rail.json"
  mark_armed "$home" 15400
  out=$(poll "$home" 15400)
  [ -z "$out" ] || fail "a chronic trickle over a four-hour gap paged: $out"
  write_issues "$home" core-backend <<'JSON'
[{"shortId":"CORE-BACKEND-CHR","title":"TypeError: chronic","culprit":"/api/v4/feed/x","userCount":4,"count":116,"level":"error","substatus":"ongoing","permalink":"https://x/chr/"}]
JSON
  out=$(poll "$home" 15700)
  [ -z "$out" ] || fail "one event in a window paged: $out"
  # A quiet window records a rate of zero. Fifteen events that then arrive
  # over a four-hour read gap (a DARK period, a starved rotation) are a raw
  # delta of fifteen but a window rate under four per hour: not a burst.
  write_issues "$home" core-backend <<'JSON'
[{"shortId":"CORE-BACKEND-CHR","title":"TypeError: chronic","culprit":"/api/v4/feed/x","userCount":4,"count":116,"level":"error","substatus":"ongoing","permalink":"https://x/chr/"}]
JSON
  poll "$home" 16000 >/dev/null
  write_issues "$home" core-backend <<'JSON'
[{"shortId":"CORE-BACKEND-CHR","title":"TypeError: chronic","culprit":"/api/v4/feed/x","userCount":4,"count":131,"level":"error","substatus":"ongoing","permalink":"https://x/chr/"}]
JSON
  out=$(poll "$home" 30400)
  assert_not_contains "$out" "P0 CORE-BACKEND-CHR" "fifteen events spread over a four-hour gap paged as a burst"
  # The same fifteen inside one five-minute window after a quiet one page.
  poll "$home" 30700 >/dev/null
  write_issues "$home" core-backend <<'JSON'
[{"shortId":"CORE-BACKEND-CHR","title":"TypeError: chronic","culprit":"/api/v4/feed/x","userCount":4,"count":146,"level":"error","substatus":"ongoing","permalink":"https://x/chr/"}]
JSON
  out=$(poll "$home" 31000)
  assert_contains "$out" "P0 CORE-BACKEND-CHR" "fifteen events in one window after a quiet one did not page"
  assert_contains "$out" "rule=burst>=10/window" "the burst rule was not named as a window rate"
  pass "a burst is a window rate against the prior rate, never a gap total"
}

test_transport_burst_still_pages() {
  local home out
  home=$(make_home transport-burst)
  prime_baseline "$home" 1000
  # CORE-BACKEND-VD on 2026-09-22 was literally "socket hang up": a transport
  # signature must never be able to hide the request-reset cascade it describes.
  write_issues "$home" core-backend <<'JSON'
[{"shortId":"CORE-BACKEND-VD","title":"Error: socket hang up","culprit":"/api/v4/feed/profile/2/activities","userCount":1,"count":30,"level":"error","substatus":"new","firstSeen":"1970-01-01T00:20:00Z","permalink":"https://x/9/"}]
JSON
  out=$(poll "$home" 1300)
  assert_contains "$out" "P0 CORE-BACKEND-VD" "a transport burst was silenced"
  assert_contains "$out" "rule=burst>=25" "the transport burst did not name the raised burst floor"
  pass "a transport signature never hides a burst"
}

test_transport_pages_only_through_the_raised_burst_floor() {
  local home out
  home=$(make_home transport-users)
  prime_baseline "$home" 1000
  # A transport reset at thirty users is client churn until it bursts: neither
  # the users-based P0 nor the P1 rule may fire on it.
  write_issues "$home" core-backend <<'JSON'
[{"shortId":"CORE-BACKEND-RST","title":"Error: read ECONNRESET","culprit":"/api/v4/onboarding/name","userCount":30,"count":12,"level":"error","substatus":"new","firstSeen":"1970-01-01T00:20:00Z","permalink":"https://x/rst/"}]
JSON
  out=$(poll "$home" 1300)
  [ -z "$out" ] || fail "a transport issue paged on users or below the raised burst floor: $out"
  write_issues "$home" core-backend <<'JSON'
[{"shortId":"CORE-BACKEND-RST","title":"Error: read ECONNRESET","culprit":"/api/v4/onboarding/name","userCount":52,"count":12,"level":"error","substatus":"new","firstSeen":"1970-01-01T00:20:00Z","permalink":"https://x/rst/"}]
JSON
  out=$(poll "$home" 1600)
  [ -z "$out" ] || fail "a seen transport issue paged on crossing a user tier: $out"
  write_issues "$home" core-backend <<'JSON'
[{"shortId":"CORE-BACKEND-RST","title":"Error: read ECONNRESET","culprit":"/api/v4/onboarding/name","userCount":52,"count":44,"level":"error","substatus":"new","firstSeen":"1970-01-01T00:20:00Z","permalink":"https://x/rst/"}]
JSON
  out=$(poll "$home" 1900)
  assert_contains "$out" "P0 CORE-BACKEND-RST" "a transport burst above the raised floor did not page"
  assert_contains "$out" "rule=burst>=25" "the transport burst did not name the raised floor"
  pass "a transport signature pages only through the burst rule at its raised floor"
}

test_burst_window_runs_from_the_last_real_read() {
  local home out beat
  home=$(make_home last-read)
  prime_baseline "$home" 1000
  # Poll B skips core-backend (unreadable) and must neither advance the beat
  # nor shorten the project's window; poll C then sees a burst that began
  # between A and B.
  rm -f "$home/fix/issues-core-backend.json"
  out=$(poll "$home" 1300)
  assert_contains "$out" "could-not-determine core-backend" "the skipped project was not reported"
  beat=$(cat "$home/state/.sentry-watch.beat")
  [ "$beat" = 1000 ] || fail "a poll that read nothing advanced the beat to $beat"
  write_issues "$home" core-backend <<'JSON'
[{"shortId":"CORE-BACKEND-WIN","title":"TypeError: feed","culprit":"/api/v4/feed/profile/2/activities","userCount":2,"count":50,"level":"error","substatus":"new","firstSeen":"1970-01-01T00:18:40Z","permalink":"https://x/win/"}]
JSON
  out=$(poll "$home" 1600)
  assert_contains "$out" "P0 CORE-BACKEND-WIN" "a burst that began after the last real read did not page"
  assert_contains "$out" "rule=burst>=10" "the burst rule was not named"
  assert_contains "$out" "recovered core-backend" "the project reading again was not reported"
  beat=$(cat "$home/state/.sentry-watch.beat")
  [ "$beat" = 1600 ] || fail "a poll that read a project did not advance the beat (got $beat)"
  pass "the burst window and the beat derive from the last real read"
}

test_new_issue_burst_needs_events_inside_the_poll_window() {
  local home out
  home=$(make_home lifetime-count)
  prime_baseline "$home" 1000
  # A chronic weekly job that fell out of the baseline returns with a lifetime
  # count of 40 but first appeared long before this window: not a burst.
  write_issues "$home" core-backend <<'JSON'
[{"shortId":"CORE-BACKEND-OLD","title":"TypeError: weekly job","culprit":"/api/v4/feed/rebuild","userCount":1,"count":40,"level":"error","substatus":"ongoing","firstSeen":"1969-12-01T00:00:00Z","permalink":"https://x/old/"}]
JSON
  out=$(poll "$home" 1300)
  [ -z "$out" ] || fail "a lifetime count outside the poll window paged as a burst: $out"
  pass "a new issue is a burst only on events inside the poll window"
}

test_seen_p0_pages_once_per_user_tier() {
  local home out
  home=$(make_home p0-tier)
  prime_baseline "$home" 1000
  write_issues "$home" core-backend <<'JSON'
[{"shortId":"CORE-BACKEND-Q0","title":"TypeError: chronic","culprit":"PUT /api/v4/user","userCount":30,"count":10,"level":"error","substatus":"ongoing","permalink":"https://x/q0/"}]
JSON
  out=$(poll "$home" 1300)
  assert_contains "$out" "P0 CORE-BACKEND-Q0" "a new issue at the first user tier did not page"
  write_issues "$home" core-backend <<'JSON'
[{"shortId":"CORE-BACKEND-Q0","title":"TypeError: chronic","culprit":"PUT /api/v4/user","userCount":33,"count":12,"level":"error","substatus":"ongoing","permalink":"https://x/q0/"}]
JSON
  out=$(poll "$home" 1600)
  [ -z "$out" ] || fail "a chronic P0 re-paged inside the same user tier: $out"
  write_issues "$home" core-backend <<'JSON'
[{"shortId":"CORE-BACKEND-Q0","title":"TypeError: chronic","culprit":"PUT /api/v4/user","userCount":52,"count":14,"level":"error","substatus":"ongoing","permalink":"https://x/q0/"}]
JSON
  out=$(poll "$home" 1900)
  assert_contains "$out" "P0 CORE-BACKEND-Q0" "crossing the next user tier did not page"
  assert_contains "$out" "rule=users>=50" "the new tier was not named"
  write_issues "$home" core-backend <<'JSON'
[{"shortId":"CORE-BACKEND-Q0","title":"TypeError: chronic","culprit":"PUT /api/v4/user","userCount":55,"count":15,"level":"error","substatus":"ongoing","permalink":"https://x/q0/"}]
JSON
  out=$(poll "$home" 2200)
  [ -z "$out" ] || fail "a chronic P0 re-paged after its tier page: $out"
  pass "a seen P0 pages once per user tier, never every poll"
}

test_critical_signature_pages_at_any_user_count() {
  local home out
  home=$(make_home critical)
  write_projects "$home" core-backend apple-ios
  printf '[]\n' > "$home/fix/issues-core-backend.json"
  printf '[]\n' > "$home/fix/issues-apple-ios.json"
  printf '[]\n' > "$home/fix/rail.json"
  mark_armed "$home" 1000
  poll "$home" 1000 >/dev/null
  # APPLE-IOS-AC on 2026-09-19: a one-user fatal app hang with no sensitive
  # token anywhere in its title or culprit. The retired mobile scout paged it.
  write_issues "$home" apple-ios <<'JSON'
[{"shortId":"APPLE-IOS-AC","title":"Fatal App Hang Fully Blocked","culprit":"MusoModalSheetTrackingModifier","userCount":1,"count":1,"level":"fatal","substatus":"new","permalink":"https://x/ac/"}]
JSON
  write_issues "$home" core-backend <<'JSON'
[{"shortId":"CORE-BACKEND-OOM","title":"OOMKilled","culprit":"/api/v4/x","userCount":0,"count":5,"level":"fatal","substatus":"ongoing","permalink":"https://x/oom/"}]
JSON
  out=$(poll "$home" 1300)
  assert_contains "$out" "CRASH APPLE-IOS-AC" "a one-user fatal app hang did not page"
  assert_contains "$out" "rule=crash-signature" "the crash rule was not named"
  assert_contains "$out" "CRITICAL CORE-BACKEND-OOM" "a new OOMKilled issue did not page"
  assert_contains "$out" "rule=critical-signature" "the critical rule was not named"
  # A seen crash follows the ordinary seen-issue rules, and a seen critical
  # issue is throttled to once per surfaced window: neither pages on one more
  # event five minutes later.
  write_issues "$home" apple-ios <<'JSON'
[{"shortId":"APPLE-IOS-AC","title":"Fatal App Hang Fully Blocked","culprit":"MusoModalSheetTrackingModifier","userCount":2,"count":3,"level":"fatal","substatus":"ongoing","permalink":"https://x/ac/"}]
JSON
  write_issues "$home" core-backend <<'JSON'
[{"shortId":"CORE-BACKEND-OOM","title":"OOMKilled","culprit":"/api/v4/x","userCount":0,"count":6,"level":"fatal","substatus":"ongoing","permalink":"https://x/oom/"}]
JSON
  out=$(poll "$home" 1600)
  [ -z "$out" ] || fail "a seen crash or critical issue re-paged inside its surfaced window: $out"
  write_issues "$home" core-backend <<'JSON'
[{"shortId":"CORE-BACKEND-OOM","title":"OOMKilled","culprit":"/api/v4/x","userCount":30,"count":7,"level":"fatal","substatus":"ongoing","permalink":"https://x/oom/"}]
JSON
  out=$(poll "$home" 1900)
  assert_contains "$out" "CRITICAL CORE-BACKEND-OOM" "a critical issue crossing a user tier did not page"
  assert_contains "$out" "delta=1" "the critical re-page did not carry its delta"
  write_issues "$home" core-backend <<'JSON'
[{"shortId":"CORE-BACKEND-OOM","title":"OOMKilled","culprit":"/api/v4/x","userCount":31,"count":8,"level":"fatal","substatus":"ongoing","permalink":"https://x/oom/"}]
JSON
  out=$(poll "$home" 2200)
  assert_not_contains "$out" "CRITICAL CORE-BACKEND-OOM" "a critical issue re-paged inside its surfaced window"
  out=$(poll "$home" 5500)
  assert_not_contains "$out" "CRITICAL CORE-BACKEND-OOM" "a critical issue with no new event paged when its window rolled"
  write_issues "$home" core-backend <<'JSON'
[{"shortId":"CORE-BACKEND-OOM","title":"OOMKilled","culprit":"/api/v4/x","userCount":31,"count":9,"level":"fatal","substatus":"ongoing","permalink":"https://x/oom/"}]
JSON
  out=$(poll "$home" 5800)
  assert_contains "$out" "CRITICAL CORE-BACKEND-OOM" "a critical issue with a new event did not page after its window rolled"
  pass "crash pages a new issue once; critical pages once per surfaced window or tier"
}

test_every_finding_pages_on_its_own_line() {
  local home out i lines
  home=$(make_home many)
  prime_baseline "$home" 1000
  python3 - "$home/fix/issues-core-backend.json" <<'PY'
import json, sys
rows = [{
    "shortId": "CORE-BACKEND-M%02d" % i,
    "title": "TypeError: null name %d " % i + "x" * 150,
    "culprit": "/api/v4/onboarding/name/%d/" % i + "y" * 150,
    "userCount": 1, "count": 2, "level": "fatal", "substatus": "new",
    "permalink": "https://sentry.io/organizations/musoai/issues/%d/" % (1000 + i),
} for i in range(12)]
json.dump(rows, open(sys.argv[1], "w"))
PY
  out=$(poll "$home" 1300)
  for i in 00 01 02 03 04 05 06 07 08 09 10 11; do
    assert_contains "$out" "P1 CORE-BACKEND-M$i" "finding CORE-BACKEND-M$i was dropped"
  done
  lines=$(printf '%s\n' "$out" | grep -c 'sentry-watch: P1 ')
  [ "$lines" -eq 12 ] || fail "expected 12 finding lines, got $lines"
  out=$(poll "$home" 1600)
  assert_not_contains "$out" "P1 CORE-BACKEND-M" "a finding that already paged paged again"
  pass "every finding pages on its own line and none is dropped by a cap"
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
  write_config "$home" <<'JSON'
{"page_any_delta":["CORE-BACKEND-11N"]}
JSON
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
  printf '[]\n' > "$home/fix/issues-android.json"
  printf '[]\n' > "$home/fix/rail.json"
  mark_armed "$home" 1000
  poll "$home" 1000 >/dev/null
  # The android fixture is removed: one unreadable project must be reported,
  # and must not stop the readable one from being polled.
  rm -f "$home/fix/issues-android.json"
  write_issues "$home" core-backend <<'JSON'
[{"shortId":"CORE-BACKEND-EEE","title":"TypeError: null name","culprit":"/api/v4/onboarding/name","userCount":1,"count":2,"level":"fatal","substatus":"new","permalink":"https://x/5/"}]
JSON
  out=$(poll "$home" 1300)
  assert_contains "$out" "could-not-determine android" "an unreadable project was not reported"
  assert_contains "$out" "P1 CORE-BACKEND-EEE" "an unreadable project stopped the readable one"
  # Reported on the transition only: the same condition is silent on the next
  # poll, reminded once an hour while it persists, and reported once it clears.
  out=$(poll "$home" 1600)
  assert_not_contains "$out" "could-not-determine android" "a persistent condition paged on every poll"
  out=$(poll "$home" 5000)
  assert_contains "$out" "could-not-determine android" "the hourly reminder did not fire"
  assert_contains "$out" "persisting 3700s" "the reminder did not say how long the condition has held"
  out=$(poll "$home" 5300)
  assert_not_contains "$out" "could-not-determine android" "the reminder repeated before an hour passed"
  printf '[]\n' > "$home/fix/issues-android.json"
  out=$(poll "$home" 5600)
  assert_contains "$out" "recovered android" "the condition clearing was not reported"
  out=$(poll "$home" 5900)
  [ -z "$out" ] || fail "a recovered condition kept printing: $out"
  # A failed project enumeration is the same kind of condition.
  rm -f "$home/fix/projects.json"
  out=$(poll "$home" 6200)
  assert_contains "$out" "could-not-determine projects" "a failed project enumeration was not reported"
  out=$(poll "$home" 6500)
  assert_not_contains "$out" "could-not-determine projects" "a persistent enumeration failure paged on every poll"
  pass "an unreadable project is could-not-determine on its transitions, never silence and never every poll"
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

# The rail is read every sixth poll; the arming poll is the first read, so five
# quiet polls bring the counter to the next one.
advance_to_rail_poll() {  # <home> <first-now>  (five polls, 300s apart)
  local home=$1 t=$2 i
  for i in 0 1 2 3 4; do
    poll "$home" $((t + 300 * i)) >/dev/null
  done
}

test_rail_only_detection() {
  local home out i
  home=$(make_home rail-only)
  prime_baseline "$home" 1000
  advance_to_rail_poll "$home" 1300
  write_rail "$home" <<'JSON'
[{"url":"https://github.com/Muso-AI/core-backend/pull/9999","headRefName":"cto/sentry-core-backend-zzz-20260922-000000","body":"Fixes CORE-BACKEND-ZZZ"}]
JSON
  out=$(poll "$home" 2800)
  assert_contains "$out" "RAIL-ONLY CORE-BACKEND-ZZZ" "a rail fix the watch never surfaced was not reported"
  assert_contains "$out" "https://github.com/Muso-AI/core-backend/pull/9999" "the rail-only wake lost the PR URL"
  for i in 3100 3400 3700 4000 4300 4600; do
    out=$(poll "$home" "$i")
    assert_not_contains "$out" "RAIL-ONLY" "the same rail-only finding reported twice (poll at $i)"
  done
  pass "a rail fix the watch never surfaced is reported once with its PR URL"
}

test_rail_runs_on_its_own_cadence() {
  local home out i
  home=$(make_home rail-cadence)
  prime_baseline "$home" 1000
  write_rail "$home" <<'JSON'
[{"url":"https://github.com/Muso-AI/core-backend/pull/9999","headRefName":"cto/sentry-core-backend-zzz-20260922-000000","body":"Fixes CORE-BACKEND-ZZZ"}]
JSON
  # The arming poll seeded the rail; with the default cadence the next rail
  # read is the sixth poll after it, not the next one.
  for i in 1300 1600 1900 2200 2500; do
    out=$(poll "$home" "$i")
    assert_not_contains "$out" "RAIL-ONLY" "the rail was read on an off-cadence poll at $i"
  done
  out=$(poll "$home" 2800)
  assert_contains "$out" "RAIL-ONLY CORE-BACKEND-ZZZ" "the rail was not read on its cadence poll"
  pass "the rail cross-check runs every sixth poll"
}

test_rail_only_is_suppressed_when_the_watch_surfaced_it() {
  local home out
  home=$(make_home rail-surfaced)
  prime_baseline "$home" 1000
  advance_to_rail_poll "$home" 1300
  write_issues "$home" core-backend <<'JSON'
[{"shortId":"CORE-BACKEND-ZZZ","title":"TypeError: null","culprit":"/api/v4/onboarding/name","userCount":1,"count":1,"level":"fatal","substatus":"new","permalink":"https://x/z/"}]
JSON
  write_rail "$home" <<'JSON'
[{"url":"https://github.com/Muso-AI/core-backend/pull/9999","headRefName":"cto/sentry-core-backend-zzz-20260922-000000","body":"Fixes CORE-BACKEND-ZZZ"}]
JSON
  out=$(poll "$home" 2800)
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
  assert_contains "$out" "android	enabled" "a second API project was not enabled"
  pass "projects lists every API project with its effective state"
}

test_legacy_import_baselines_only_the_projects_it_covered() {
  local home out
  home=$(make_home legacy-per-project)
  cat > "$home/state/sentry-backend-watch-b1.last.json" <<'JSON'
{"CORE-BACKEND-OLD":{"users":7,"title":"TypeError: old","culprit":"/api/v4/onboarding/name","count":12,"level":"fatal","ts":1000}}
JSON
  write_projects "$home" core-backend industry-api
  write_issues "$home" core-backend <<'JSON'
[{"shortId":"CORE-BACKEND-OLD","title":"TypeError: old","culprit":"/api/v4/onboarding/name","userCount":7,"count":12,"level":"fatal","substatus":"ongoing","permalink":"https://x/old/"},
 {"shortId":"CORE-BACKEND-NEW","title":"TypeError: new","culprit":"/api/v4/onboarding/name","userCount":1,"count":2,"level":"fatal","substatus":"new","permalink":"https://x/new/"}]
JSON
  write_issues "$home" industry-api <<'JSON'
[{"shortId":"INDUSTRY-API-AAA","title":"TypeError: backlog","culprit":"/api/v1/auth/login","userCount":1,"count":2,"level":"fatal","substatus":"ongoing","permalink":"https://x/aaa/"}]
JSON
  printf '[]\n' > "$home/fix/rail.json"
  mark_armed "$home" 1000
  # The arming poll: the legacy-covered project classifies at once and only its
  # unknown issue pages; the uncovered project records its estate silently.
  out=$(poll "$home" 1000)
  assert_contains "$out" "P1 CORE-BACKEND-NEW" "an unknown issue on a legacy-covered project did not page"
  assert_not_contains "$out" "CORE-BACKEND-OLD" "an imported legacy issue re-paged"
  assert_not_contains "$out" "INDUSTRY-API-AAA" "the arming poll announced the backlog of a project the legacy baseline never covered"
  write_issues "$home" industry-api <<'JSON'
[{"shortId":"INDUSTRY-API-AAA","title":"TypeError: backlog","culprit":"/api/v1/auth/login","userCount":1,"count":2,"level":"fatal","substatus":"ongoing","permalink":"https://x/aaa/"},
 {"shortId":"INDUSTRY-API-BBB","title":"TypeError: fresh","culprit":"/api/v1/auth/login","userCount":1,"count":1,"level":"fatal","substatus":"new","permalink":"https://x/bbb/"}]
JSON
  out=$(poll "$home" 1300)
  assert_contains "$out" "P1 INDUSTRY-API-BBB" "a new issue on the second read of a project did not page"
  assert_not_contains "$out" "INDUSTRY-API-AAA" "an issue recorded on the project's first read re-paged"
  pass "the baseline is per project: legacy-covered projects classify, uncovered ones record first"
}

test_fetch_order_rotates_so_no_project_starves() {
  local home out i
  home=$(make_home rotation)
  write_config "$home" <<'JSON'
{"rail":{"enabled":false}}
JSON
  write_projects "$home" alpha bravo charlie delta
  for i in alpha bravo charlie delta; do
    printf '{"sleep":1.2,"issues":[]}\n' > "$home/fix/issues-$i.json"
  done
  printf '[]\n' > "$home/fix/rail.json"
  mark_armed "$home" 1000
  # A 2s budget lets exactly one 1.2s project read per poll; rotation must
  # hand each poll to the next project, and a project unread for three polls
  # is reported on that transition, then recovered when its turn comes.
  out=$(FM_SENTRY_WATCH_BUDGET_SECS=2 poll "$home" 1000)
  python3 - "$home/state/sentry-watch.baseline.json" alpha <<'PY'
import json, sys
last_read = json.load(open(sys.argv[1]))["last_read"]
assert sorted(last_read) == sys.argv[2:], "read set after poll: %s" % sorted(last_read)
PY
  [ -z "$out" ] || fail "one unread poll was already reported: $out"
  out=$(FM_SENTRY_WATCH_BUDGET_SECS=2 poll "$home" 1300)
  python3 - "$home/state/sentry-watch.baseline.json" alpha bravo <<'PY'
import json, sys
last_read = json.load(open(sys.argv[1]))["last_read"]
assert sorted(last_read) == sys.argv[2:], "read set after poll: %s" % sorted(last_read)
assert last_read["alpha"] == 1000 and last_read["bravo"] == 1300, last_read
PY
  [ -z "$out" ] || fail "two unread polls were already reported: $out"
  out=$(FM_SENTRY_WATCH_BUDGET_SECS=2 poll "$home" 1600)
  python3 - "$home/state/sentry-watch.baseline.json" alpha bravo charlie <<'PY'
import json, sys
last_read = json.load(open(sys.argv[1]))["last_read"]
assert sorted(last_read) == sys.argv[2:], "read set after poll: %s" % sorted(last_read)
PY
  assert_contains "$out" "could-not-determine delta: unread for 3 consecutive polls" \
    "a project unread for three polls was not reported"
  assert_not_contains "$out" "could-not-determine charlie" "a project read this poll was reported unread"
  out=$(FM_SENTRY_WATCH_BUDGET_SECS=2 poll "$home" 1900)
  assert_contains "$out" "recovered delta" "the starved project's turn did not clear its condition"
  python3 - "$home/state/sentry-watch.baseline.json" <<'PY'
import json, sys
last_read = json.load(open(sys.argv[1]))["last_read"]
assert last_read["delta"] == 1900, last_read
PY
  pass "the fetch order rotates so every project is read within a bounded number of polls"
}

test_budget_skip_never_closes_an_open_condition() {
  local home out
  home=$(make_home skip-keeps-condition)
  write_config "$home" <<'JSON'
{"rail":{"enabled":false}}
JSON
  write_projects "$home" alpha bravo charlie
  printf '{"sleep":1.2,"issues":[]}\n' > "$home/fix/issues-bravo.json"
  printf '{"sleep":1.2,"issues":[]}\n' > "$home/fix/issues-charlie.json"
  printf '[]\n' > "$home/fix/rail.json"
  mark_armed "$home" 1000
  # alpha is unreadable, and the 2s budget reads one slow project per poll, so
  # the rotation leaves alpha skipped on every other poll. A skipped project
  # must keep its open condition: only a real successful read may close it.
  out=$(FM_SENTRY_WATCH_BUDGET_SECS=2 poll "$home" 1000)
  assert_contains "$out" "could-not-determine alpha" "the unreadable project was not reported"
  out=$(FM_SENTRY_WATCH_BUDGET_SECS=2 poll "$home" 1300)
  assert_not_contains "$out" "recovered alpha" "a budget skip closed the condition of a project it never read"
  out=$(FM_SENTRY_WATCH_BUDGET_SECS=2 poll "$home" 1600)
  assert_not_contains "$out" "could-not-determine alpha" "a still-open condition was reported as a new transition"
  printf '[]\n' > "$home/fix/issues-alpha.json"
  out=$(FM_SENTRY_WATCH_BUDGET_SECS=2 poll "$home" 1900)
  assert_not_contains "$out" "recovered alpha" "a budget skip closed the condition before the project was read"
  out=$(FM_SENTRY_WATCH_BUDGET_SECS=2 poll "$home" 2200)
  assert_contains "$out" "recovered alpha" "a successful read did not close the condition"
  pass "a budget skip never closes an open condition; only a successful read does"
}

test_departed_project_is_removed_from_watch_not_recovered() {
  local home out
  home=$(make_home departed)
  write_projects "$home" core-backend flutter
  printf '[]\n' > "$home/fix/issues-core-backend.json"
  printf '[]\n' > "$home/fix/rail.json"
  mark_armed "$home" 1000
  out=$(poll "$home" 1000)
  assert_contains "$out" "could-not-determine flutter" "the unreadable project was not reported"
  # The natural reason to denylist a project is that it is unreadable; the
  # poll after the edit must say it left the watch, never that it recovered.
  write_config "$home" <<'JSON'
{"denylist":["flutter"]}
JSON
  out=$(poll "$home" 1300)
  assert_contains "$out" "removed from watch flutter" "a denylisted project was not reported as removed"
  assert_not_contains "$out" "recovered flutter" "a denylisted project was reported as recovered"
  out=$(poll "$home" 1600)
  [ -z "$out" ] || fail "a removed project kept printing: $out"
  pass "a project that leaves the enumerated set is removed from watch, never recovered"
}

test_healthy_project_leaving_the_org_is_removed_from_watch() {
  local home out
  home=$(make_home departed-healthy)
  write_projects "$home" core-backend feed-service
  printf '[]\n' > "$home/fix/issues-core-backend.json"
  printf '[]\n' > "$home/fix/issues-feed-service.json"
  printf '[]\n' > "$home/fix/rail.json"
  mark_armed "$home" 1000
  out=$(poll "$home" 1000)
  [ -z "$out" ] || fail "two healthy projects printed on the arming poll: $out"
  # The token's scope narrows or the project is deleted: the next enumeration
  # simply lacks the slug, and losing coverage of a live app must not be silent.
  write_projects "$home" core-backend
  out=$(poll "$home" 1300)
  assert_contains "$out" "removed from watch feed-service" "a healthy project leaving the org was dropped silently"
  assert_not_contains "$out" "recovered" "a departed project was reported as recovered"
  out=$(poll "$home" 1600)
  [ -z "$out" ] || fail "a removed project kept printing: $out"
  pass "a healthy project that leaves the enumerated set is reported once as removed"
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
test_new_issue_ramp_pages_on_its_second_read
test_burst_is_a_window_rate_not_a_gap_total
test_transport_burst_still_pages
test_transport_pages_only_through_the_raised_burst_floor
test_burst_window_runs_from_the_last_real_read
test_new_issue_burst_needs_events_inside_the_poll_window
test_seen_p0_pages_once_per_user_tier
test_critical_signature_pages_at_any_user_count
test_every_finding_pages_on_its_own_line
test_regression_pages_when_a_resolved_issue_refires
test_noise_stays_silent
test_page_any_delta_pages_on_a_single_event
test_api_error_is_could_not_determine_not_silence
test_missing_beat_is_dark
test_rail_only_detection
test_rail_runs_on_its_own_cadence
test_rail_only_is_suppressed_when_the_watch_surfaced_it
test_projects_lists_every_project_with_its_effective_state
test_legacy_import_baselines_only_the_projects_it_covered
test_fetch_order_rotates_so_no_project_starves
test_budget_skip_never_closes_an_open_condition
test_departed_project_is_removed_from_watch_not_recovered
test_healthy_project_leaving_the_org_is_removed_from_watch
test_migrate_imports_the_retired_baselines
test_a_task_pr_poll_cannot_touch_the_watch
test_an_overwritten_check_is_dark
test_arm_refuses_an_id_that_is_also_a_task
test_arm_registers_and_disarm_removes
test_wake_drain_reports_a_deleted_check
test_status_reports_the_liveness_verdict
