#!/usr/bin/env bats
# publish-digest.sh — the whole Phase-3 tail in one call: main glance post +
# detail thread reply. Slack is reached only through post-digest.sh, whose
# curl is overridden via CURL; stdout must ALWAYS be a deliverable final
# message once validation passes (the announce fallback), so a Slack failure
# can never be the run's trailing tool error.
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

  # curl override for post-digest.sh: captures each posted payload as
  # posted-<n>.json; per-call response via slack-response-<n>.json, else ok.
  cat > "$TEST_TMPDIR/bin/slack-curl" <<'STUB'
#!/usr/bin/env bash
data=""
while [ "$#" -gt 0 ]; do
  case "$1" in --data-binary) shift; data="$1" ;; esac
  shift
done
n=1
while [ -f "${TEST_TMPDIR}/posted-${n}.json" ]; do n=$((n+1)); done
case "$data" in @*) cp "${data#@}" "${TEST_TMPDIR}/posted-${n}.json" ;; esac
if [ -f "${TEST_TMPDIR}/slack-response-${n}.json" ]; then
  cat "${TEST_TMPDIR}/slack-response-${n}.json"
else
  echo "{\"ok\":true,\"ts\":\"1717171717.00030${n}\"}"
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

@test "success: main + detail thread posted, one-line confirmation with main ts" {
  publish "$WORKDIR/digest-daily.json"
  [ "$status" -eq 0 ]
  [[ "$output" == *"✅ Caroline daily digest posted"* ]]
  [[ "$output" == *"1717171717.000301"* ]]
  [[ "$output" == *"Detail thread attached."* ]]
  [[ "$output" != *"P0 /"* ]]  # no digest duplication on success
  [ -f "$TEST_TMPDIR/posted-1.json" ]
  [ -f "$TEST_TMPDIR/posted-2.json" ]
  jq -e '.thread_ts == "1717171717.000301"' "$TEST_TMPDIR/posted-2.json"
  jq -e '.thread_ts == null' "$TEST_TMPDIR/posted-1.json"
}

@test "posted main payload is the lean glance; thread carries the details" {
  publish "$WORKDIR/digest-daily.json"
  [ "$status" -eq 0 ]
  jq -e '.blocks[] | select(.type == "header")' "$TEST_TMPDIR/posted-1.json" >/dev/null
  run grep -c "Good catch" "$TEST_TMPDIR/posted-1.json"
  [ "$output" = "0" ]
  run grep -c "Good catch" "$TEST_TMPDIR/posted-2.json"
  [ "$output" != "0" ]
}

@test "quiet digest (no findings/themes) posts the main message only" {
  jq '.findings = [] | .themes = [] | .severity = {"p0":0,"p1":0,"p2":0}' \
    "$WORKDIR/digest-daily.json" > "$WORKDIR/quiet.json"
  publish "$WORKDIR/quiet.json"
  [ "$status" -eq 0 ]
  [[ "$output" == *"✅ Caroline daily digest posted"* ]]
  [[ "$output" != *"Detail thread attached"* ]]
  [ -f "$TEST_TMPDIR/posted-1.json" ]
  [ ! -f "$TEST_TMPDIR/posted-2.json" ]
}

@test "thread-post failure: exit 0, loud warning in heartbeat, NO fallback dump" {
  echo '{"ok":false,"error":"invalid_blocks"}' > "$TEST_TMPDIR/slack-response-2.json"
  publish "$WORKDIR/digest-daily.json"
  [ "$status" -eq 0 ]
  [[ "$output" == *"✅ Caroline daily digest posted"* ]]
  [[ "$output" == *"⚠️ detail thread post FAILED"* ]]
  [[ "$output" == *"invalid_blocks"* ]]
  [[ "$output" != *"Plain-text fallback"* ]]
}

@test "MAIN-post failure: exit 0, loud alert + full plain-text fallback" {
  echo '{"ok":false,"error":"not_in_channel"}' > "$TEST_TMPDIR/slack-response-1.json"
  publish "$WORKDIR/digest-daily.json"
  [ "$status" -eq 0 ]
  [[ "$output" == *"🔴 Block Kit post"*"FAILED"* ]]
  [[ "$output" == *"not_in_channel"* ]]
  # the fallback digest is included so announce still delivers the review
  [[ "$output" == *"0 P0 / 0 P1 / 1 P2"* ]]
  [[ "$output" == *"Voice 5"* ]]
  [[ "$output" == *"Guard"* ]]
  # no thread attempt after a failed main post
  [ ! -f "$TEST_TMPDIR/posted-2.json" ]
}

@test "validation failure: exit non-zero, nothing posted, errors name the cause" {
  jq '.findings[0].conversation_ids = ["215474999999111"]' \
    "$WORKDIR/digest-daily.json" > "$WORKDIR/bad.json"
  publish "$WORKDIR/bad.json"
  [ "$status" -ne 0 ]
  [[ "$output" == *"hallucinated"* ]]
  [ ! -f "$TEST_TMPDIR/posted-1.json" ]
}

@test "weekly digest publishes main + thread with CAROLINE_EXPECTED_KIND=weekly" {
  export CAROLINE_EXPECTED_KIND="weekly"
  publish "$WORKDIR/digest-weekly.json"
  [ "$status" -eq 0 ]
  [[ "$output" == *"✅ Caroline weekly digest posted"* ]]
  [[ "$output" == *"Detail thread attached."* ]]
  run grep -c "KB-gap" "$TEST_TMPDIR/posted-2.json"
  [ "$output" != "0" ]
}

@test "CAROLINE_DIGEST_CHANNEL shadow override reaches both payloads and the confirmation" {
  export CAROLINE_DIGEST_CHANNEL="C0SHADOW123"
  publish "$WORKDIR/digest-daily.json"
  [ "$status" -eq 0 ]
  [[ "$output" == *"C0SHADOW123"* ]]
  jq -e '.channel == "C0SHADOW123"' "$TEST_TMPDIR/posted-1.json"
  jq -e '.channel == "C0SHADOW123"' "$TEST_TMPDIR/posted-2.json"
}
