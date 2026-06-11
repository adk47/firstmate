#!/usr/bin/env bats
# publish-digest.sh — the whole Phase-3 tail in one call. Slack is reached only
# through post-digest.sh, whose curl is overridden via CURL; stdout must ALWAYS
# be a deliverable final message once validation passes (the announce fallback),
# so a Slack failure can never be the run's trailing tool error.
load helpers

setup() {
  setup_skill_tmp
  setup_digest_fixtures
  export CV_TOOL_CTX_CONVERSATION_ID="unavailable"
  export CAROLINE_EXPECTED_KIND="daily"

  export SLACK_NOTIFY_CONFIG="$TEST_TMPDIR/openclaw.json"
  cat > "$SLACK_NOTIFY_CONFIG" <<'JSON'
{"channels":{"slack":{"accounts":{"operations":{"botToken":"xoxb-test-ops"}}}}}
JSON

  # curl override for post-digest.sh: success unless a response fixture says otherwise
  cat > "$TEST_TMPDIR/bin/slack-curl" <<'STUB'
#!/usr/bin/env bash
data=""
while [ "$#" -gt 0 ]; do
  case "$1" in --data-binary) shift; data="$1" ;; esac
  shift
done
printf '%s\n' "$data" > "${TEST_TMPDIR}/last-data-arg"
# Copy the payload NOW — publish-digest.sh deletes its tmp dir on exit.
case "$data" in @*) cp "${data#@}" "${TEST_TMPDIR}/last-payload.json" ;; esac
if [ -f "${TEST_TMPDIR}/slack-response.json" ]; then
  cat "${TEST_TMPDIR}/slack-response.json"
else
  echo '{"ok":true,"ts":"1717171717.000300"}'
fi
STUB
  chmod +x "$TEST_TMPDIR/bin/slack-curl"
  export CURL="$TEST_TMPDIR/bin/slack-curl"
}
teardown() { teardown_skill_tmp; }

publish() {  # $1 = digest file
  run "$SCRIPTS_DIR/publish-digest.sh" "$1" \
    "$WORKDIR/conversations.jsonl" "$WORKDIR/audit.jsonl"
}

@test "success: exit 0 and a one-line confirmation with the message ts" {
  publish "$WORKDIR/digest-daily.json"
  [ "$status" -eq 0 ]
  [[ "$output" == *"✅ Caroline daily digest posted"* ]]
  [[ "$output" == *"1717171717.000300"* ]]
  [[ "$output" != *"P0 /"* ]]  # no digest duplication on success
}

@test "posted payload was the rendered Block Kit body" {
  publish "$WORKDIR/digest-daily.json"
  [ "$status" -eq 0 ]
  jq -e '.blocks | length > 3' "$TEST_TMPDIR/last-payload.json"
  jq -e '.channel == "C0ANM0PN9L5"' "$TEST_TMPDIR/last-payload.json"
}

@test "Slack post failure: exit 0, loud alert + full plain-text fallback" {
  echo '{"ok":false,"error":"invalid_blocks"}' > "$TEST_TMPDIR/slack-response.json"
  publish "$WORKDIR/digest-daily.json"
  [ "$status" -eq 0 ]
  [[ "$output" == *"🔴 Block Kit post"*"FAILED"* ]]
  [[ "$output" == *"invalid_blocks"* ]]
  # the fallback digest is included so announce still delivers the review
  [[ "$output" == *"0 P0 / 0 P1 / 1 P2"* ]]
  [[ "$output" == *"Voice 5"* ]]
  [[ "$output" == *"Guard"* ]]
}

@test "validation failure: exit non-zero, nothing posted, errors name the cause" {
  jq '.findings[0].conversation_ids = ["215474999999111"]' \
    "$WORKDIR/digest-daily.json" > "$WORKDIR/bad.json"
  publish "$WORKDIR/bad.json"
  [ "$status" -ne 0 ]
  [[ "$output" == *"hallucinated"* ]]
  [ ! -f "$TEST_TMPDIR/last-data-arg" ]
}

@test "weekly digest publishes with CAROLINE_EXPECTED_KIND=weekly" {
  export CAROLINE_EXPECTED_KIND="weekly"
  publish "$WORKDIR/digest-weekly.json"
  [ "$status" -eq 0 ]
  [[ "$output" == *"✅ Caroline weekly digest posted"* ]]
}

@test "CAROLINE_DIGEST_CHANNEL shadow override reaches the payload and the confirmation" {
  export CAROLINE_DIGEST_CHANNEL="C0SHADOW123"
  publish "$WORKDIR/digest-daily.json"
  [ "$status" -eq 0 ]
  [[ "$output" == *"C0SHADOW123"* ]]
}
