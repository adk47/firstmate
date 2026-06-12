#!/usr/bin/env bats
# post-digest.sh — chat.postMessage as the operations bot. curl is PATH-stubbed
# (NEVER touches Slack; cf. the unstubbed-test 9-real-alerts incident) and the
# token read is pointed at a fixture config. Pattern: scripts/tests/qa-slack-dm.bats.
load helpers

setup() {
  setup_skill_tmp
  export STUB_CALLS="$TEST_TMPDIR/slack-calls"
  : > "$STUB_CALLS"

  export SLACK_NOTIFY_CONFIG="$TEST_TMPDIR/openclaw.json"
  cat > "$SLACK_NOTIFY_CONFIG" <<'JSON'
{"channels":{"slack":{"accounts":{"operations":{"botToken":"xoxb-test-ops"}}}}}
JSON

  # Replace the generic helpers curl stub with a Slack-shaped one that records
  # the URL and the --data-binary payload reference.
  cat > "$TEST_TMPDIR/bin/curl" <<'STUB'
#!/usr/bin/env bash
url=""; data=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    https://*) url="$1" ;;
    --data-binary) shift; data="$1" ;;
  esac
  shift
done
echo "$url" >> "$STUB_CALLS"
printf '%s\n' "$data" > "${TEST_TMPDIR}/last-data-arg"
# Capture the posted body NOW — post-digest.sh deletes its thread_ts temp copy on exit.
case "$data" in @*) cp "${data#@}" "${TEST_TMPDIR}/last-payload.json" ;; esac
if [ -f "${TEST_TMPDIR}/slack-response.json" ]; then
  cat "${TEST_TMPDIR}/slack-response.json"
else
  echo '{"ok":true,"ts":"1717171717.000200"}'
fi
STUB
  chmod +x "$TEST_TMPDIR/bin/curl"
  export CURL="curl"

  echo '{"channel":"C0ANM0PN9L5","text":"headline","blocks":[{"type":"divider"}]}' \
    > "$TEST_TMPDIR/payload.json"
}
teardown() { teardown_skill_tmp; }

@test "happy path: posts payload, prints ts, exit 0" {
  run "$SCRIPTS_DIR/post-digest.sh" "$TEST_TMPDIR/payload.json"
  [ "$status" -eq 0 ]
  [ "$output" = "1717171717.000200" ]
  grep -q 'chat.postMessage' "$STUB_CALLS"
}

@test "payload file is passed verbatim via --data-binary @file" {
  run "$SCRIPTS_DIR/post-digest.sh" "$TEST_TMPDIR/payload.json"
  [ "$status" -eq 0 ]
  [ "$(cat "$TEST_TMPDIR/last-data-arg")" = "@$TEST_TMPDIR/payload.json" ]
}

@test "HTTP 200 with ok:false (not_in_channel) exits non-zero with the error" {
  echo '{"ok":false,"error":"not_in_channel"}' > "$TEST_TMPDIR/slack-response.json"
  run "$SCRIPTS_DIR/post-digest.sh" "$TEST_TMPDIR/payload.json"
  [ "$status" -eq 1 ]
  [[ "$output" == *"not_in_channel"* ]]
}

@test "missing token in config exits 1 with NO API call" {
  echo '{"channels":{"slack":{"accounts":{}}}}' > "$SLACK_NOTIFY_CONFIG"
  run "$SCRIPTS_DIR/post-digest.sh" "$TEST_TMPDIR/payload.json"
  [ "$status" -eq 1 ]
  [ ! -s "$STUB_CALLS" ]
}

@test "payload without blocks is a usage error, NO API call" {
  echo '{"channel":"C0ANM0PN9L5","text":"plain"}' > "$TEST_TMPDIR/payload.json"
  run "$SCRIPTS_DIR/post-digest.sh" "$TEST_TMPDIR/payload.json"
  [ "$status" -eq 2 ]
  [ ! -s "$STUB_CALLS" ]
}

@test "missing payload file is a usage error" {
  run "$SCRIPTS_DIR/post-digest.sh" "$TEST_TMPDIR/nope.json"
  [ "$status" -eq 2 ]
}

@test "thread_ts arg is injected into the posted payload" {
  run "$SCRIPTS_DIR/post-digest.sh" "$TEST_TMPDIR/payload.json" "1717171717.000200"
  [ "$status" -eq 0 ]
  jq -e '.thread_ts == "1717171717.000200"' "$TEST_TMPDIR/last-payload.json"
  jq -e '.channel == "C0ANM0PN9L5"' "$TEST_TMPDIR/last-payload.json"
  # the original payload file is untouched
  run grep -c "thread_ts" "$TEST_TMPDIR/payload.json"
  [ "$output" = "0" ]
}

@test "without thread_ts the payload file is posted as-is" {
  run "$SCRIPTS_DIR/post-digest.sh" "$TEST_TMPDIR/payload.json"
  [ "$status" -eq 0 ]
  [ "$(cat "$TEST_TMPDIR/last-data-arg")" = "@$TEST_TMPDIR/payload.json" ]
}

@test "SLACK_ACCOUNT override reads a different account token" {
  cat > "$SLACK_NOTIFY_CONFIG" <<'JSON'
{"channels":{"slack":{"accounts":{"devops":{"botToken":"xoxb-test-devops"}}}}}
JSON
  SLACK_ACCOUNT=devops run "$SCRIPTS_DIR/post-digest.sh" "$TEST_TMPDIR/payload.json"
  [ "$status" -eq 0 ]
}
