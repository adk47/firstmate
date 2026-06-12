#!/usr/bin/env bats
# Tests for scripts/qa-slack-dm.sh — DM a Slack user as the QA bot.
# PATH-stubs `muso` so the suite NEVER touches the real Slack API (memory: bats
# must stub network calls — an unstubbed test once fired 9 real Slack alerts).
# The token read is pointed at a fixture env file via MUSO_SLACK_ENV_FILE.
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
SCRIPT="$HYDRA_REPO/scripts/qa-slack-dm.sh"

setup() {
  TEST_TMPDIR="$(mktemp -d)"; export TEST_TMPDIR
  export STUB_CALLS="$TEST_TMPDIR/muso-calls"
  : > "$STUB_CALLS"

  # Fixture env file holding a fake qa bot token at the path the script reads.
  # Make sure nothing leaks in from the real environment.
  unset MUSO_SLACK_BOT_TOKEN_QA MUSO_SLACK_BOT_TOKEN_DEVOPS
  export MUSO_SLACK_ENV_FILE="$TEST_TMPDIR/muso-slack.env"
  echo 'MUSO_SLACK_BOT_TOKEN_QA=xoxb-test-qa' > "$MUSO_SLACK_ENV_FILE"

  # Stub muso: record argv, capture --text, emit the --json success body.
  STUBBIN="$TEST_TMPDIR/bin"; mkdir -p "$STUBBIN"
  cat > "$STUBBIN/muso" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_CALLS"
prev=""
for a in "$@"; do
  [ "$prev" = "--text" ] && printf '%s' "$a" > "$TEST_TMPDIR/last-text"
  prev="$a"
done
echo '{"channel":"D0TESTDM","ts":"1717171717.000100"}'
STUB
  chmod +x "$STUBBIN/muso"
  export PATH="$STUBBIN:$PATH"
}
teardown() { rm -rf "$TEST_TMPDIR"; }

@test "happy path: sends DM via muso slack dm as the qa bot, prints ts" {
  run "$SCRIPT" U0AL36NADEY "hello there"
  [ "$status" -eq 0 ]
  [ "$output" = "1717171717.000100" ]
  grep -q -- 'slack dm --bot qa --user U0AL36NADEY' "$STUB_CALLS"
  grep -q -- '--requester' "$STUB_CALLS"
  grep -q 'hello there' "$TEST_TMPDIR/last-text"
}

@test "missing text -> usage exit 2, no muso call" {
  run "$SCRIPT" U0AL36NADEY
  [ "$status" -eq 2 ]
  [ ! -s "$STUB_CALLS" ]
}

@test "empty user id -> usage exit 2" {
  run "$SCRIPT" "" "hi"
  [ "$status" -eq 2 ]
}

@test "no token in env file -> exit 1, no muso call" {
  : > "$MUSO_SLACK_ENV_FILE"
  run "$SCRIPT" U0AL36NADEY "hi"
  [ "$status" -eq 1 ]
  [ ! -s "$STUB_CALLS" ]
}

@test "muso failure (Slack rejected the send) -> exit 1, empty ts" {
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "$STUB_CALLS"\nexit 1\n' > "$TEST_TMPDIR/bin/muso"
  chmod +x "$TEST_TMPDIR/bin/muso"
  run "$SCRIPT" U0AL36NADEY "hi"
  [ "$status" -eq 1 ]
}

@test "thread_ts is forwarded to muso slack dm" {
  run "$SCRIPT" U0AL36NADEY "reply text" "1717171717.000100"
  [ "$status" -eq 0 ]
  grep -q -- '--thread-ts 1717171717.000100' "$STUB_CALLS"
}
