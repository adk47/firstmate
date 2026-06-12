#!/usr/bin/env bats
# post-digest.sh — chat.postMessage as the operations bot via `muso slack send`.
# muso is PATH-stubbed (NEVER touches Slack; cf. the unstubbed-test
# 9-real-alerts incident) and the token read is pointed at a fixture env file
# so the real /etc/openclaw/main.env is never sourced.
load helpers

setup() {
  setup_skill_tmp
  export STUB_CALLS="$TEST_TMPDIR/slack-calls"
  : > "$STUB_CALLS"

  # Fixture token env file — post-digest.sh must never read the real one.
  unset MUSO_SLACK_BOT_TOKEN_OPERATIONS MUSO_SLACK_BOT_TOKEN_DEVOPS
  export MUSO_SLACK_ENV_FILE="$TEST_TMPDIR/muso-slack.env"
  echo 'MUSO_SLACK_BOT_TOKEN_OPERATIONS=xoxb-test' > "$MUSO_SLACK_ENV_FILE"

  export STUBBIN="$TEST_TMPDIR/bin"
  # muso stub — records argv, captures the --blocks-file content NOW
  # (post-digest.sh deletes its temp blocks file on exit), succeeds with a
  # {"channel","ts"} JSON body. touch $TEST_TMPDIR/muso-fail to simulate a
  # delivery failure (the CLI's exit code IS the delivery status; it decodes
  # Slack's HTTP-200 ok:false trap itself, so failure = plain exit 1).
  cat > "$STUBBIN/muso" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_CALLS"
prev=""
for a in "$@"; do
  [ "$prev" = "--blocks-file" ] && cp "$a" "$TEST_TMPDIR/last-blocks" 2>/dev/null
  prev="$a"
done
if [ -f "$TEST_TMPDIR/muso-fail" ]; then
  echo "slack send failed: not_in_channel" >&2
  exit 1
fi
echo '{"channel":"C0TEST","ts":"1717171717.000100"}'
STUB
  chmod +x "$STUBBIN/muso"

  echo '{"channel":"C0ANM0PN9L5","text":"headline","blocks":[{"type":"divider"}]}' \
    > "$TEST_TMPDIR/payload.json"
}
teardown() { teardown_skill_tmp; }

@test "happy path: sends via muso slack send, prints ts, exit 0" {
  run "$SCRIPTS_DIR/post-digest.sh" "$TEST_TMPDIR/payload.json"
  [ "$status" -eq 0 ]
  [ "$output" = "1717171717.000100" ]
  grep -q '^slack send ' "$STUB_CALLS"
}

@test "payload maps onto --bot/--channel/--text/--json argv" {
  run "$SCRIPTS_DIR/post-digest.sh" "$TEST_TMPDIR/payload.json"
  [ "$status" -eq 0 ]
  call="$(cat "$STUB_CALLS")"
  [[ "$call" == *"--bot operations"* ]]
  [[ "$call" == *"--channel C0ANM0PN9L5"* ]]
  [[ "$call" == *"--text headline"* ]]
  [[ "$call" == *"--json"* ]]
}

@test "blocks file passed to muso equals the payload's .blocks array" {
  run "$SCRIPTS_DIR/post-digest.sh" "$TEST_TMPDIR/payload.json"
  [ "$status" -eq 0 ]
  jq -e --slurpfile sent "$TEST_TMPDIR/last-blocks" '.blocks == $sent[0]' \
    "$TEST_TMPDIR/payload.json"
}

@test "muso failure (e.g. not_in_channel decoded by the CLI) exits 1" {
  : > "$TEST_TMPDIR/muso-fail"
  run "$SCRIPTS_DIR/post-digest.sh" "$TEST_TMPDIR/payload.json"
  [ "$status" -eq 1 ]
}

@test "missing token (empty env file) exits 1 with NO muso call" {
  : > "$MUSO_SLACK_ENV_FILE"
  run "$SCRIPTS_DIR/post-digest.sh" "$TEST_TMPDIR/payload.json"
  [ "$status" -eq 1 ]
  [ ! -s "$STUB_CALLS" ]
}

@test "payload without blocks is a usage error, NO muso call" {
  echo '{"channel":"C0ANM0PN9L5","text":"plain"}' > "$TEST_TMPDIR/payload.json"
  run "$SCRIPTS_DIR/post-digest.sh" "$TEST_TMPDIR/payload.json"
  [ "$status" -eq 2 ]
  [ ! -s "$STUB_CALLS" ]
}

@test "missing payload file is a usage error" {
  run "$SCRIPTS_DIR/post-digest.sh" "$TEST_TMPDIR/nope.json"
  [ "$status" -eq 2 ]
}

@test "thread_ts arg becomes --thread-ts on the muso call" {
  run "$SCRIPTS_DIR/post-digest.sh" "$TEST_TMPDIR/payload.json" "1717171717.000200"
  [ "$status" -eq 0 ]
  grep -q -- '--thread-ts 1717171717.000200' "$STUB_CALLS"
  # the original payload file is untouched
  run grep -c "thread_ts" "$TEST_TMPDIR/payload.json"
  [ "$output" = "0" ]
}

@test "without thread_ts no --thread-ts flag is sent" {
  run "$SCRIPTS_DIR/post-digest.sh" "$TEST_TMPDIR/payload.json"
  [ "$status" -eq 0 ]
  ! grep -q -- '--thread-ts' "$STUB_CALLS"
}

@test "SLACK_ACCOUNT override selects a different bot and token var" {
  echo 'MUSO_SLACK_BOT_TOKEN_DEVOPS=xoxb-test-devops' > "$MUSO_SLACK_ENV_FILE"
  SLACK_ACCOUNT=devops run "$SCRIPTS_DIR/post-digest.sh" "$TEST_TMPDIR/payload.json"
  [ "$status" -eq 0 ]
  grep -q -- '--bot devops' "$STUB_CALLS"
}
