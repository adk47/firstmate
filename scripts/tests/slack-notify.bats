#!/usr/bin/env bats
# Tests for scripts/lib/slack-notify.sh — the shared muso-slack send lib.
# PATH-stubs `muso` so the suite NEVER touches the real Slack API (memory: bats
# must stub network calls — an unstubbed test once fired 9 real Slack alerts).
# Token reads are pointed at a fixture env file via MUSO_SLACK_ENV_FILE.
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
LIB="$HYDRA_REPO/scripts/lib/slack-notify.sh"

setup() {
  TEST_TMPDIR="$(mktemp -d)"; export TEST_TMPDIR
  export STUB_CALLS="$TEST_TMPDIR/muso-calls"
  : > "$STUB_CALLS"

  # Fixture env file at the path the lib reads; nothing leaks in from the
  # real environment.
  unset MUSO_SLACK_BOT_TOKEN_DEVOPS MUSO_SLACK_BOT_TOKEN_QA MUSO_STATE_DIR
  export MUSO_SLACK_ENV_FILE="$TEST_TMPDIR/muso-slack.env"
  {
    echo 'MUSO_SLACK_BOT_TOKEN_DEVOPS=xoxb-test-devops'
    echo 'MUSO_SLACK_BOT_TOKEN_QA=xoxb-test-qa'
    echo "MUSO_STATE_DIR=$TEST_TMPDIR/muso-state"
  } > "$MUSO_SLACK_ENV_FILE"

  # Stub muso: record argv, capture --text and --blocks-file content.
  STUBBIN="$TEST_TMPDIR/bin"; mkdir -p "$STUBBIN"
  cat > "$STUBBIN/muso" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_CALLS"
prev=""
for a in "$@"; do
  [ "$prev" = "--text" ] && printf '%s' "$a" > "$TEST_TMPDIR/last-text"
  [ "$prev" = "--blocks-file" ] && cat "$a" > "$TEST_TMPDIR/last-blocks"
  prev="$a"
done
exit 0
STUB
  chmod +x "$STUBBIN/muso"
  export PATH="$STUBBIN:$PATH"
}
teardown() { rm -rf "$TEST_TMPDIR"; }

# Run a snippet in a fresh bash that sources the lib first.
with_lib() { bash -c "source '$LIB'; $1"; }

@test "slack_notify translates literal \\n into real newlines (old JSON-decode contract)" {
  run with_lib 'slack_notify "line1\nline2"'
  [ "$status" -eq 0 ]
  expected=$'line1\nline2'
  [ "$(cat "$TEST_TMPDIR/last-text")" = "$expected" ]
}

@test "slack_load_env loads the requested bot's token from the env file" {
  run with_lib 'slack_load_env qa && [ -n "$MUSO_SLACK_BOT_TOKEN_QA" ] && echo loaded'
  [ "$status" -eq 0 ]
  [ "$output" = "loaded" ]
}

@test "slack_load_env fails for a bot with no token line" {
  run with_lib 'slack_load_env nosuchbot'
  [ "$status" -ne 0 ]
}

@test "slack_load_env exports MUSO_STATE_DIR alongside the tokens (shared audit trail)" {
  run with_lib "slack_load_env devops && printf '%s' \"\$MUSO_STATE_DIR\""
  [ "$status" -eq 0 ]
  [ "$output" = "$TEST_TMPDIR/muso-state" ]
}

@test "payload without .channel is refused — dedupe state must not advance" {
  payload="$TEST_TMPDIR/payload.json"
  echo '{"text":"no channel here"}' > "$payload"
  run with_lib "slack_notify_payload_file_status '$payload'"
  [ "$status" -ne 0 ]
  [ ! -s "$STUB_CALLS" ]
}

@test "payload with unfurl_links:false maps onto --no-unfurl" {
  payload="$TEST_TMPDIR/payload.json"
  echo '{"channel":"C0TEST","text":"t","unfurl_links":false,"unfurl_media":false}' > "$payload"
  run with_lib "slack_notify_payload_file_status '$payload'"
  [ "$status" -eq 0 ]
  grep -q -- '--no-unfurl' "$STUB_CALLS"
}

@test "payload without unfurl fields does not pass --no-unfurl" {
  payload="$TEST_TMPDIR/payload.json"
  echo '{"channel":"C0TEST","text":"t"}' > "$payload"
  run with_lib "slack_notify_payload_file_status '$payload'"
  [ "$status" -eq 0 ]
  ! grep -q -- '--no-unfurl' "$STUB_CALLS"
}

@test "payload blocks land in --blocks-file content" {
  payload="$TEST_TMPDIR/payload.json"
  echo '{"channel":"C0TEST","blocks":[{"type":"divider"}]}' > "$payload"
  run with_lib "slack_notify_payload_file_status '$payload'"
  [ "$status" -eq 0 ]
  grep -q '"type": *"divider"' "$TEST_TMPDIR/last-blocks"
}

@test "slack_notify_critical prepends real Nick + Aaron user-ID mentions" {
  # A literal "@name" in a bot message renders as plain text and pings nobody
  # (the watchdog's old '@aaron' suffix) — only <@UID> actually pings.
  run with_lib 'slack_notify_critical "gateway down"'
  [ "$status" -eq 0 ]
  [ "$(cat "$TEST_TMPDIR/last-text")" = "<@U0AL36NADEY> <@U7RP6HKUZ> gateway down" ]
}

@test "slack_notify_critical keeps slack_notify's literal-\\n translation contract" {
  run with_lib 'slack_notify_critical "line1\nline2"'
  [ "$status" -eq 0 ]
  expected=$'<@U0AL36NADEY> <@U7RP6HKUZ> line1\nline2'
  [ "$(cat "$TEST_TMPDIR/last-text")" = "$expected" ]
}

@test "slack_notify_critical stays best-effort when muso fails" {
  printf '#!/usr/bin/env bash\nexit 1\n' > "$STUBBIN/muso"
  chmod +x "$STUBBIN/muso"
  run with_lib 'slack_notify_critical "x" && echo survived'
  [ "$status" -eq 0 ]
  [[ "$output" == *survived* ]]
}

@test "slack prewrite hook provider branch: MUSO_HOOK_PROVIDER=slack exits 0 without probing" {
  # The hook must not run the codex-health gate for slack sends — a codex
  # outage must not suppress the alert about itself. No journalctl stub on
  # PATH here, so reaching the gate would fail loudly.
  MUSO_HOOK_PROVIDER=slack run "$HYDRA_REPO/scripts/muso-prewrite-hook.sh" POST /chat.postMessage prod
  [ "$status" -eq 0 ]
}

# ── bats fence (hydra#1195): no test run may reach real Slack ──────────

@test "fence belt 1: under bats the live env file is never read" {
  export SLACK_NOTIFY_LIVE_ENV_FILE="$MUSO_SLACK_ENV_FILE"
  run with_lib 'slack_load_env devops'
  [ "$status" -eq 1 ]
}

@test "fence belt 2: slack_notify refuses the installed muso, returns 0, sends nothing" {
  export SLACK_NOTIFY_INSTALLED_MUSO="$STUBBIN/muso"
  run with_lib 'slack_notify hi; echo rc=$?'
  [ "$status" -eq 0 ]
  [[ "$output" == *"rc=0"* ]]
  [[ "$output" == *"refusing to exec installed"* ]]
  [ ! -s "$STUB_CALLS" ]
}

@test "fence belt 2: payload posters refuse with rc 1, sends nothing" {
  export SLACK_NOTIFY_INSTALLED_MUSO="$STUBBIN/muso"
  echo '{"channel":"C1","text":"x"}' > "$TEST_TMPDIR/p.json"
  run with_lib "slack_notify_payload_file_status '$TEST_TMPDIR/p.json'"
  [ "$status" -eq 1 ]
  run with_lib "slack_notify_payload_file_ts '$TEST_TMPDIR/p.json'"
  [ "$status" -eq 1 ]
  [ ! -s "$STUB_CALLS" ]
}
