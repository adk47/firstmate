#!/usr/bin/env bats
# Tests for scripts/ads-inquiry-watchdog.sh — the ads-buying lead sweep added
# after the 2026-07 Odeholm Audio miss (an in-app-ads sales lead was filed as
# support-general, closed as answered, and forwarded to Nick instead of Aaron).
#
# PATH-shadows curl + muso so no test ever hits ClickUp or Slack for real
# (see memory/feedback_bats_must_stub_openclaw.md). Behavioural assertions
# use --dry-run; the post-path tests run against stubs that capture argv.
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
WD="$HYDRA_REPO/scripts/ads-inquiry-watchdog.sh"

# Fixed "now": 2026-07-02T00:00:00Z
NOW=1782950400
DAY=86400

setup() {
  TEST_TMPDIR="$(mktemp -d)"
  export TEST_TMPDIR
  mkdir -p "$TEST_TMPDIR/bin"

  export ADS_INQUIRY_NOW="$NOW"
  export ADS_INQUIRY_SKIP_HOST_GUARD=1
  export ADS_INQUIRY_LOCKFILE="$TEST_TMPDIR/lock"
  export CLICKUP_API_KEY="pk_test_dummy"
  # Never fall back to the real gateway env on node-8.
  export CLICKUP_ENV_FILE="$TEST_TMPDIR/clickup.env"  # absent
  export CLICKUP_FIXTURE="$TEST_TMPDIR/tasks.json"

  # Refuse real Slack: no token unless a test opts in via the env file.
  unset MUSO_SLACK_BOT_TOKEN_DEVOPS MUSO_SLACK_BOT_TOKEN_OPERATIONS
  export MUSO_SLACK_ENV_FILE="$TEST_TMPDIR/muso-slack.env"  # absent by default
  export STUB_CALLS="$TEST_TMPDIR/muso-calls"
  : > "$STUB_CALLS"
  export CURL_CALLS="$TEST_TMPDIR/curl-calls"
  : > "$CURL_CALLS"

  # curl stub: serves $CLICKUP_FIXTURE for the page-0 list GET, empty page
  # after, and records every invocation (method + URL) so tests can assert
  # the dedupe-tag POST happened (or didn't).
  cat > "$TEST_TMPDIR/bin/curl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CURL_CALLS"
url="${@: -1}"
case "$url" in
  *page=0*) cat "$CLICKUP_FIXTURE" ;;
  */tag/*)  echo '{}' ;;
  *)        echo '{"tasks":[],"last_page":true}' ;;
esac
STUB
  cat > "$TEST_TMPDIR/bin/muso" <<'STUB'
#!/usr/bin/env bash
# one log line per invocation: collapse newlines inside args
all="$*"
printf '%s\n' "${all//$'\n'/ }" >> "$STUB_CALLS"
prev=""
for a in "$@"; do
  [ "$prev" = "--text" ] && printf '%s' "$a" > "$TEST_TMPDIR/last-text"
  [ "$prev" = "--channel" ] && printf '%s' "$a" > "$TEST_TMPDIR/last-channel"
  prev="$a"
done
echo '{"channel":"C0TEST","ts":"1717171717.000100"}'
STUB
  cat > "$TEST_TMPDIR/bin/flock" <<'STUB'
#!/bin/bash
[ -x /usr/bin/flock ] && exec /usr/bin/flock "$@"
exit 0
STUB
  chmod +x "$TEST_TMPDIR/bin/curl" "$TEST_TMPDIR/bin/muso" "$TEST_TMPDIR/bin/flock"
  PATH="$TEST_TMPDIR/bin:$PATH"; export PATH
}

teardown() { rm -rf "$TEST_TMPDIR"; }

# task <id> <name> <text> <created_epoch> <tags-csv>
task_json() {
  local id="$1" name="$2" text="$3" created="$4" tags="$5"
  local tag_objs
  tag_objs=$(printf '%s' "$tags" | awk -F, '{for(i=1;i<=NF;i++){printf "%s{\"name\":\"%s\"}", (i>1?",":""), $i}}')
  printf '{"id":"%s","name":"%s","text_content":"%s","date_created":"%s","url":"https://app.clickup.com/t/%s","status":{"status":"resolved"},"tags":[%s]}' \
    "$id" "$name" "$text" "$((created * 1000))" "$id" "$tag_objs"
}

fixture() {  # joins task JSONs into a list response
  local joined; joined=$(IFS=,; printf '%s' "$*")
  printf '{"tasks":[%s],"last_page":true}' "$joined" > "$CLICKUP_FIXTURE"
}

# The watchdog posts via the OPERATIONS bot (the only bot in #cs_priority).
enable_slack() { echo 'MUSO_SLACK_BOT_TOKEN_OPERATIONS=xoxb-test' > "$MUSO_SLACK_ENV_FILE"; }

@test "fails loud when CLICKUP_API_KEY is missing" {
  unset CLICKUP_API_KEY
  run -2 "$WD" --dry-run
  [[ "$output" == *"CLICKUP_API_KEY"* ]]
}

@test "unknown arg fails loud" {
  run -2 "$WD" --bogus
  [[ "$output" == *"unknown arg"* ]]
}

@test "ads-intent ticket is detected in dry-run without posting" {
  fixture "$(task_json ads1 '[support] Odeholm Audio ad packages inquiry' 'interested in in-app advertising' $((NOW - 5*DAY)) 'hydra-action-request,action:support-general,tier-1')"
  run -0 "$WD" --dry-run
  [[ "$output" == *"ads1"* ]]
  [[ "$output" == *"1 ads-buying lead"* ]]
  [ ! -s "$STUB_CALLS" ]
  # dry-run must not add the dedupe tag either
  ! grep -q '/tag/' "$CURL_CALLS"
}

@test "keyword match works on text_content when the name is generic" {
  fixture "$(task_json ads2 '[support] General question' 'wants to buy ad space in the app' $((NOW - DAY)) 'hydra-action-request')"
  run -0 "$WD" --dry-run
  [[ "$output" == *"ads2"* ]]
}

@test "incidental 'advertise' usage is not an ads lead (869dggdzj regression)" {
  # Real false positive: a profile-update ticket saying the customer does
  # "not want to advertise their own artist music profile" must not ping.
  fixture "$(task_json fp1 'Action Request: profile-update' 'they are primarily a producer and do not want to advertise their own artist music profile there' $((NOW - DAY)) 'hydra-action-request')"
  run -0 "$WD" --dry-run
  [[ "$output" == *"0 ads-buying lead"* ]]
}

@test "'advertising with Muso' phrasing still matches" {
  fixture "$(task_json ads3 '[support] partnership question' 'we would like to advertise on Muso, what are the rates' $((NOW - DAY)) 'hydra-action-request')"
  run -0 "$WD" --dry-run
  [[ "$output" == *"ads3"* ]]
}

@test "'ad …' alternatives are word-anchored ('bad space' is not an ads lead)" {
  fixture "$(task_json fp2 '[support] layout issue' 'there is a bad space in my credits layout' $((NOW - DAY)) 'hydra-action-request')"
  run -0 "$WD" --dry-run
  [[ "$output" == *"0 ads-buying lead"* ]]
}

@test "non-ads ticket is ignored" {
  fixture "$(task_json cr1 '[support] Credit correction request' 'missing credits on album' $((NOW - DAY)) 'hydra-action-request,tier-1')"
  run -0 "$WD" --dry-run
  [[ "$output" == *"0 ads-buying lead"* ]]
}

@test "ticket without the hydra-action-request tag is ignored" {
  fixture "$(task_json oth1 'internal advertising budget planning' 'ad packages for Q3' $((NOW - DAY)) 'misc')"
  run -0 "$WD" --dry-run
  [[ "$output" == *"0 ads-buying lead"* ]]
}

@test "ticket already tagged ads-lead-pinged is skipped" {
  fixture "$(task_json dup1 '[support] ad packages inquiry' 'advertising' $((NOW - DAY)) 'hydra-action-request,ads-lead-pinged')"
  run -0 "$WD" --dry-run
  [[ "$output" == *"0 ads-buying lead"* ]]
}

@test "ticket older than the lookback window is ignored" {
  fixture "$(task_json old1 '[support] ad packages inquiry' 'advertising' $((NOW - 45*DAY)) 'hydra-action-request')"
  run -0 "$WD" --dry-run
  [[ "$output" == *"0 ads-buying lead"* ]]
}

@test "list scan includes closed tickets (ads leads get closed-as-answered)" {
  fixture "$(task_json ads1 '[support] ad packages inquiry' 'advertising' $((NOW - DAY)) 'hydra-action-request')"
  run -0 "$WD" --dry-run
  grep -q 'include_closed=true' "$CURL_CALLS"
}

@test "real path posts to #cs_priority tagging Aaron, then adds the dedupe tag" {
  enable_slack
  fixture "$(task_json ads1 '[support] Odeholm Audio ad packages inquiry' 'interested in in-feed ads' $((NOW - 5*DAY)) 'hydra-action-request,tier-1')"
  run -0 "$WD"
  grep -q 'slack send --bot operations' "$STUB_CALLS"
  first_call=$(head -1 "$STUB_CALLS")
  [[ "$first_call" == *"--channel C0BBTAVP44X"* ]]
  [[ "$first_call" == *"<@U7RP6HKUZ>"* ]]
  [[ "$first_call" == *"Odeholm Audio ad packages inquiry"* ]]
  [[ "$first_call" == *"<https://app.clickup.com/t/ads1|ads1>"* ]]
  # dedupe tag added AFTER the confirmed post
  grep -q 'task/ads1/tag/ads-lead-pinged' "$CURL_CALLS"
}

@test "conversation summary from the ticket is threaded under the ping" {
  enable_slack
  fixture "$(task_json ads1 '[support] Odeholm Audio ad packages inquiry' 'Details here. Conversation summary: James asked who to contact about buying ad space for Odeholm Audio.' $((NOW - 5*DAY)) 'hydra-action-request')"
  run -0 "$WD"
  [ "$(grep -c 'slack send' "$STUB_CALLS")" -eq 2 ]
  reply=$(sed -n '2p' "$STUB_CALLS")
  [[ "$reply" == *"--thread-ts 1717171717.000100"* ]]
  [[ "$reply" == *"James asked who to contact about buying ad space"* ]]
  # the thread reply must not re-ping Aaron
  [[ "$reply" != *"<@U7RP6HKUZ>"* ]]
}

@test "ticket without a conversation summary gets a single post, no thread reply" {
  enable_slack
  fixture "$(task_json ads1 '[support] ad packages inquiry' 'advertising, no summary line' $((NOW - DAY)) 'hydra-action-request')"
  run -0 "$WD"
  [ "$(grep -c 'slack send' "$STUB_CALLS")" -eq 1 ]
  grep -q 'task/ads1/tag/ads-lead-pinged' "$CURL_CALLS"
}

@test "dry-run prints the summary too" {
  fixture "$(task_json ads1 '[support] ad packages inquiry' 'Conversation summary: wants in-feed ads pricing.' $((NOW - DAY)) 'hydra-action-request')"
  run -0 "$WD" --dry-run
  [[ "$output" == *"wants in-feed ads pricing"* ]]
}

@test "failed Slack post exits non-zero and does NOT add the dedupe tag" {
  enable_slack
  cat > "$TEST_TMPDIR/bin/muso" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
  chmod +x "$TEST_TMPDIR/bin/muso"
  fixture "$(task_json ads1 '[support] ad packages inquiry' 'advertising' $((NOW - DAY)) 'hydra-action-request')"
  run -1 "$WD"
  ! grep -q '/tag/ads-lead-pinged' "$CURL_CALLS"
}

@test "zero matches means no Slack post even on the real path" {
  enable_slack
  fixture "$(task_json cr1 '[support] Credit correction' 'missing credits' $((NOW - DAY)) 'hydra-action-request')"
  run -0 "$WD"
  [ ! -s "$STUB_CALLS" ]
}

@test "Slack control chars in a ticket name are escaped, mention survives" {
  enable_slack
  fixture "$(task_json inj1 '[support] <!channel> advertising & <https://evil|x> inquiry' 'ad space' $((NOW - DAY)) 'hydra-action-request')"
  run -0 "$WD"
  text=$(cat "$TEST_TMPDIR/last-text")
  [[ "$text" != *"<!channel>"* ]]
  [[ "$text" == *"&lt;!channel&gt;"* ]]
  [[ "$text" == *"&amp;"* ]]
  # our own trusted content is real mrkdwn
  [[ "$text" == *"<@U7RP6HKUZ>"* ]]
  [[ "$text" == *"<https://app.clickup.com/t/inj1|inj1>"* ]]
}

@test "customer-derived summary is escaped in the thread reply too" {
  # The 'Conversation summary:' line is verbatim customer-authored text; a
  # crafted summary must not broadcast-ping via the threaded reply.
  enable_slack
  fixture "$(task_json inj2 '[support] ad packages inquiry' 'Details. Conversation summary: <!channel> buy <https://evil|ads> now' $((NOW - DAY)) 'hydra-action-request')"
  run -0 "$WD"
  reply=$(sed -n '2p' "$STUB_CALLS")
  [[ "$reply" == *"--thread-ts"* ]]
  [[ "$reply" != *"<!channel>"* ]]
  [[ "$reply" == *"&lt;!channel&gt;"* ]]
  [[ "$reply" == *"&lt;https://evil|ads&gt;"* ]]
}

# muso stub for the PRODUCTION path (cron runs USE_MUSO_CLI=1): dispatches on
# argv — clickup raw GET serves the fixture wrapped in muso's {data:…}
# envelope, clickup raw POST tag succeeds/fails per MUSO_TAG_POST_EXIT,
# slack send returns a ts.
install_muso_cli_stub() {
  cat > "$TEST_TMPDIR/bin/muso" <<'STUB'
#!/usr/bin/env bash
all="$*"
printf '%s\n' "${all//$'\n'/ }" >> "$STUB_CALLS"
case "$all" in
  *"clickup raw GET"*)  printf '{"data":'; cat "$CLICKUP_FIXTURE"; printf '}' ;;
  *"clickup raw POST"*) exit "${MUSO_TAG_POST_EXIT:-0}" ;;
  *"slack send"*)       echo '{"channel":"C0TEST","ts":"1717171717.000100"}' ;;
esac
STUB
  chmod +x "$TEST_TMPDIR/bin/muso"
}

@test "USE_MUSO_CLI=1 production path: ping + attributed tag write via muso" {
  enable_slack
  export USE_MUSO_CLI=1
  install_muso_cli_stub
  fixture "$(task_json ads1 '[support] ad packages inquiry' 'advertising packages' $((NOW - DAY)) 'hydra-action-request')"
  run -0 "$WD"
  grep -q 'clickup raw GET /list/901000600160/task' "$STUB_CALLS"
  grep -q 'slack send --bot operations' "$STUB_CALLS"
  grep -Eq 'clickup raw POST /task/ads1/tag/ads-lead-pinged --requester [^ ]+' "$STUB_CALLS"
  # no curl fallback on this path
  [ ! -s "$CURL_CALLS" ]
}

@test "USE_MUSO_CLI=1: failed dedupe-tag write fails loud (no silent re-ping loop)" {
  # Regression for the swallowed muso tag failure: empty output + jq -e '.err'
  # treated the failure as success, so the task never got tagged and Aaron was
  # re-pinged every 15 minutes with exit 0.
  enable_slack
  export USE_MUSO_CLI=1 MUSO_TAG_POST_EXIT=1
  install_muso_cli_stub
  fixture "$(task_json ads1 '[support] ad packages inquiry' 'advertising packages' $((NOW - DAY)) 'hydra-action-request')"
  run -1 "$WD"
  [[ "$output" == *"dedupe tag add FAILED"* ]]
}

@test "ClickUp API error fails loud" {
  cat > "$TEST_TMPDIR/bin/curl" <<'STUB'
#!/usr/bin/env bash
echo '{"err":"Team not authorized","ECODE":"OAUTH_027"}'
STUB
  chmod +x "$TEST_TMPDIR/bin/curl"
  run -1 "$WD" --dry-run
  [[ "$output" == *"ClickUp"* ]]
}

@test "a task with null date_created is skipped, not crashed (fail-soft)" {
  {
    printf '{"tasks":['
    printf '%s,' "$(task_json ok1 '[support] ad packages inquiry' 'advertising' $((NOW - DAY)) 'hydra-action-request')"
    printf '{"id":"bad1","name":"[support] advertising broken","text_content":"ads","date_created":null,"url":"https://app.clickup.com/t/bad1","status":{"status":"open"},"tags":[{"name":"hydra-action-request"}]}'
    printf '],"last_page":true}'
  } > "$CLICKUP_FIXTURE"
  run -0 "$WD" --dry-run
  [[ "$output" == *"ok1"* ]]
  [[ "$output" == *"1 ads-buying lead"* ]]
  [[ "$output" != *"bad1"* ]]
}
