#!/usr/bin/env bats
# Tests for scripts/qa-slack-dm.sh — DM a Slack user as the QA bot.
# PATH-stubs `curl` so the suite NEVER touches the real Slack API (memory: bats
# must stub network calls — an unstubbed test once fired 9 real Slack alerts).
# The token read is pointed at a fixture config via SLACK_NOTIFY_CONFIG.
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
SCRIPT="$HYDRA_REPO/scripts/qa-slack-dm.sh"

setup() {
  TEST_TMPDIR="$(mktemp -d)"; export TEST_TMPDIR
  export STUB_CALLS="$TEST_TMPDIR/curl-calls"
  : > "$STUB_CALLS"

  # Fixture config holding a fake qa bot token at the path the script reads.
  export SLACK_NOTIFY_CONFIG="$TEST_TMPDIR/openclaw.json"
  cat > "$SLACK_NOTIFY_CONFIG" <<'JSON'
{"channels":{"slack":{"accounts":{"qa":{"botToken":"xoxb-test-qa"}}}}}
JSON

  # Stub curl: conversations.open -> {ok,channel.id}; chat.postMessage -> {ok,ts}.
  STUBBIN="$TEST_TMPDIR/bin"; mkdir -p "$STUBBIN"
  cat > "$STUBBIN/curl" <<'STUB'
#!/usr/bin/env bash
url=""
for a in "$@"; do case "$a" in https://*) url="$a";; esac; done
echo "$url" >> "$STUB_CALLS"
case "$url" in
  *conversations.open*) echo '{"ok":true,"channel":{"id":"D0TESTDM"}}' ;;
  *chat.postMessage*)   echo '{"ok":true,"ts":"1717171717.000100"}' ;;
  *) echo '{"ok":false,"error":"unexpected"}' ;;
esac
STUB
  chmod +x "$STUBBIN/curl"
  export PATH="$STUBBIN:$PATH"
  export CURL="curl"
}
teardown() { rm -rf "$TEST_TMPDIR"; }

@test "happy path: opens DM, posts message, prints ts" {
  run "$SCRIPT" U0AL36NADEY "hello there"
  [ "$status" -eq 0 ]
  [ "$output" = "1717171717.000100" ]
  grep -q 'conversations.open' "$STUB_CALLS"
  grep -q 'chat.postMessage' "$STUB_CALLS"
}

@test "missing text -> usage exit 2, no API call" {
  run "$SCRIPT" U0AL36NADEY
  [ "$status" -eq 2 ]
  [ ! -s "$STUB_CALLS" ]
}

@test "empty user id -> usage exit 2" {
  run "$SCRIPT" "" "hi"
  [ "$status" -eq 2 ]
}

@test "no token in config -> exit 1, no API call" {
  echo '{"channels":{"slack":{"accounts":{}}}}' > "$SLACK_NOTIFY_CONFIG"
  run "$SCRIPT" U0AL36NADEY "hi"
  [ "$status" -eq 1 ]
  [ ! -s "$STUB_CALLS" ]
}

@test "thread_ts is forwarded to chat.postMessage payload" {
  # Capture the payload by upgrading the stub to echo --data-binary contents.
  cat > "$TEST_TMPDIR/bin/curl" <<'STUB'
#!/usr/bin/env bash
url=""; payload=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    https://*) url="$1" ;;
    --data-binary) shift; payload="$1" ;;
  esac
  shift
done
case "$url" in
  *conversations.open*) echo '{"ok":true,"channel":{"id":"D0TESTDM"}}' ;;
  *chat.postMessage*) echo "$payload" > "$TEST_TMPDIR/last-payload"; echo '{"ok":true,"ts":"1.2"}' ;;
esac
STUB
  chmod +x "$TEST_TMPDIR/bin/curl"
  run "$SCRIPT" U0AL36NADEY "reply text" "1717171717.000100"
  [ "$status" -eq 0 ]
  grep -q '"thread_ts": "1717171717.000100"' "$TEST_TMPDIR/last-payload"
}
