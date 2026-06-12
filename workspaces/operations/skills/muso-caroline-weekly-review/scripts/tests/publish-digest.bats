#!/usr/bin/env bats
# publish-digest.sh — the whole Phase-3 tail in one call: main glance post +
# detail thread reply. Slack is reached only through post-digest.sh, whose
# `muso slack send` call is PATH-stubbed (never touches Slack, never reads the
# real /etc/openclaw/main.env); stdout must ALWAYS be a deliverable final
# message once validation passes (the announce fallback), so a Slack failure
# can never be the run's trailing tool error.
load helpers

setup() {
  setup_skill_tmp
  setup_digest_fixtures
  export CV_TOOL_CTX_CONVERSATION_ID="unavailable"
  export CAROLINE_EXPECTED_KIND="daily"

  # Fixture token env file for post-digest.sh's token check.
  unset MUSO_SLACK_BOT_TOKEN_OPERATIONS
  export MUSO_SLACK_ENV_FILE="$TEST_TMPDIR/muso-slack.env"
  echo 'MUSO_SLACK_BOT_TOKEN_OPERATIONS=xoxb-test' > "$MUSO_SLACK_ENV_FILE"

  # muso stub for post-digest.sh: call <n> records argv as posted-<n>.args and
  # the --blocks-file content as posted-<n>.blocks (captured NOW — post-digest
  # deletes its temp file on exit). Create muso-fail-<n> with an error message
  # to make call <n> fail (exit 1 + message on stderr — the CLI decodes
  # Slack's ok:false trap itself, its exit code IS delivery status).
  cat > "$TEST_TMPDIR/bin/muso" <<'STUB'
#!/usr/bin/env bash
n=1
while [ -f "${TEST_TMPDIR}/posted-${n}.args" ]; do n=$((n+1)); done
printf '%s\n' "$*" > "${TEST_TMPDIR}/posted-${n}.args"
prev=""
for a in "$@"; do
  [ "$prev" = "--blocks-file" ] && cp "$a" "${TEST_TMPDIR}/posted-${n}.blocks" 2>/dev/null
  prev="$a"
done
if [ -f "${TEST_TMPDIR}/muso-fail-${n}" ]; then
  cat "${TEST_TMPDIR}/muso-fail-${n}" >&2
  exit 1
fi
echo "{\"channel\":\"C0TEST\",\"ts\":\"1717171717.00030${n}\"}"
STUB
  chmod +x "$TEST_TMPDIR/bin/muso"
}
teardown() { teardown_skill_tmp; }

publish() {  # $1 = digest file
  run "$SCRIPTS_DIR/publish-digest.sh" "$1" \
    "$WORKDIR/conversations.jsonl" "$WORKDIR/audit.jsonl"
}

@test "success: main + detail thread posted, one-line confirmation with main ts" {
  publish "$WORKDIR/digest-daily.json"
  [ "$status" -eq 0 ]
  [[ "$output" == *"✅ Caroline daily digest posted"* ]]
  [[ "$output" == *"1717171717.000301"* ]]
  [[ "$output" == *"Detail thread attached."* ]]
  [[ "$output" != *"P0 /"* ]]  # no digest duplication on success
  [ -f "$TEST_TMPDIR/posted-1.args" ]
  [ -f "$TEST_TMPDIR/posted-2.args" ]
  grep -q -- '--thread-ts 1717171717.000301' "$TEST_TMPDIR/posted-2.args"
  ! grep -q -- '--thread-ts' "$TEST_TMPDIR/posted-1.args"
}

@test "posted main payload is the lean glance; thread carries the details" {
  publish "$WORKDIR/digest-daily.json"
  [ "$status" -eq 0 ]
  jq -e '.[] | select(.type == "header")' "$TEST_TMPDIR/posted-1.blocks" >/dev/null
  run grep -c "Good catch" "$TEST_TMPDIR/posted-1.blocks"
  [ "$output" = "0" ]
  run grep -c "Good catch" "$TEST_TMPDIR/posted-2.blocks"
  [ "$output" != "0" ]
}

@test "quiet digest (no findings/themes) posts the main message only" {
  jq '.findings = [] | .themes = [] | .severity = {"p0":0,"p1":0,"p2":0}' \
    "$WORKDIR/digest-daily.json" > "$WORKDIR/quiet.json"
  publish "$WORKDIR/quiet.json"
  [ "$status" -eq 0 ]
  [[ "$output" == *"✅ Caroline daily digest posted"* ]]
  [[ "$output" != *"Detail thread attached"* ]]
  [ -f "$TEST_TMPDIR/posted-1.args" ]
  [ ! -f "$TEST_TMPDIR/posted-2.args" ]
}

@test "thread-post failure: exit 0, loud warning in heartbeat, NO fallback dump" {
  echo 'slack send failed: invalid_blocks' > "$TEST_TMPDIR/muso-fail-2"
  publish "$WORKDIR/digest-daily.json"
  [ "$status" -eq 0 ]
  [[ "$output" == *"✅ Caroline daily digest posted"* ]]
  [[ "$output" == *"⚠️ detail thread post FAILED"* ]]
  [[ "$output" == *"invalid_blocks"* ]]
  [[ "$output" != *"Plain-text fallback"* ]]
}

@test "MAIN-post failure: exit 0, loud alert + full plain-text fallback" {
  echo 'slack send failed: not_in_channel' > "$TEST_TMPDIR/muso-fail-1"
  publish "$WORKDIR/digest-daily.json"
  [ "$status" -eq 0 ]
  [[ "$output" == *"🔴 Block Kit post"*"FAILED"* ]]
  [[ "$output" == *"not_in_channel"* ]]
  # the fallback digest is included so announce still delivers the review
  [[ "$output" == *"0 P0 / 0 P1 / 1 P2"* ]]
  [[ "$output" == *"Voice 5"* ]]
  [[ "$output" == *"Guard"* ]]
  # no thread attempt after a failed main post
  [ ! -f "$TEST_TMPDIR/posted-2.args" ]
}

@test "validation failure: exit non-zero, nothing posted, errors name the cause" {
  jq '.findings[0].conversation_ids = ["215474999999111"]' \
    "$WORKDIR/digest-daily.json" > "$WORKDIR/bad.json"
  publish "$WORKDIR/bad.json"
  [ "$status" -ne 0 ]
  [[ "$output" == *"hallucinated"* ]]
  [ ! -f "$TEST_TMPDIR/posted-1.args" ]
}

@test "weekly digest publishes main + thread with CAROLINE_EXPECTED_KIND=weekly" {
  export CAROLINE_EXPECTED_KIND="weekly"
  publish "$WORKDIR/digest-weekly.json"
  [ "$status" -eq 0 ]
  [[ "$output" == *"✅ Caroline weekly digest posted"* ]]
  [[ "$output" == *"Detail thread attached."* ]]
  run grep -c "KB-gap" "$TEST_TMPDIR/posted-2.blocks"
  [ "$output" != "0" ]
}

@test "CAROLINE_DIGEST_CHANNEL shadow override reaches both payloads and the confirmation" {
  export CAROLINE_DIGEST_CHANNEL="C0SHADOW123"
  publish "$WORKDIR/digest-daily.json"
  [ "$status" -eq 0 ]
  [[ "$output" == *"C0SHADOW123"* ]]
  grep -q -- '--channel C0SHADOW123' "$TEST_TMPDIR/posted-1.args"
  grep -q -- '--channel C0SHADOW123' "$TEST_TMPDIR/posted-2.args"
}
