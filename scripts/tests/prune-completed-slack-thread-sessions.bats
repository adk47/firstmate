#!/usr/bin/env bats

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  SUT="$REPO_ROOT/scripts/prune-completed-slack-thread-sessions.sh"
  OPENCLAW_STUB="$BATS_TEST_TMPDIR/openclaw"
  export OPENCLAW_BIN="$OPENCLAW_STUB"
  export OPENCLAW_STUB_LOG="$BATS_TEST_TMPDIR/delete-calls.jsonl"
  export SESSION_THREAD_NOW_MS=2000000000000
  export SESSION_THREAD_RETENTION_DAYS=14
  export SESSION_THREAD_MAX_DELETES=100

  cat > "$OPENCLAW_STUB" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail

if [[ " $* " == *" sessions --all-agents --json --limit all "* ]]; then
  [[ "${OPENCLAW_HOME:-}" == "/root" ]] || { echo 'OpenClaw home was not pinned' >&2; exit 98; }
  [[ -z "${OPENCLAW_STATE_DIR:-}${OPENCLAW_CONFIG_PATH:-}${OPENCLAW_PROFILE:-}${OPENCLAW_GATEWAY_URL:-}${OPENCLAW_GATEWAY_PORT:-}${OPENCLAW_GATEWAY_TOKEN:-}${OPENCLAW_GATEWAY_PASSWORD:-}" ]] \
    || { echo 'inherited OpenClaw selector leaked into stub' >&2; exit 98; }
  printf '%s\n' "$OPENCLAW_STUB_SESSIONS"
  exit 0
fi

if [[ " $* " == *" gateway call sessions.delete "* ]]; then
  params=''
  while (($#)); do
    if [[ "$1" == "--params" ]]; then
      params="$2"
      break
    fi
    shift
  done
  printf '%s\n' "$params" >> "$OPENCLAW_STUB_LOG"
  if [[ "$(jq -r '.expectedSessionId' <<<"$params")" == "race" ]]; then
    echo 'Session changed before deletion. Retry.' >&2
    exit 1
  fi
  if [[ "$(jq -r '.expectedSessionId' <<<"$params")" == "broken" ]]; then
    echo 'gateway unavailable' >&2
    exit 1
  fi
  printf '%s\n' '{"ok":true,"deleted":true}'
  exit 0
fi

echo "unexpected openclaw argv: $*" >&2
exit 99
STUB
  chmod +x "$OPENCLAW_STUB"

  export OPENCLAW_STUB_SESSIONS='{
    "sessions": [
      {"key":"agent:scout:slack:channel:c1:thread:1900000000.000001","agentId":"scout","sessionId":"old-done","updatedAt":1990000000000,"status":"done"},
      {"key":"agent:ops:slack:channel:g2:thread:1900000000.000002","agentId":"ops","sessionId":"old-failed","updatedAt":1990000000001,"status":"failed"},
      {"key":"agent:scout:slack:channel:c1:thread:1999900000.000003","agentId":"scout","sessionId":"fresh","updatedAt":1999900000000,"status":"done"},
      {"key":"agent:scout:slack:channel:c1:thread:1900000000.000004","agentId":"scout","sessionId":"running","updatedAt":1990000000002,"status":"running"},
      {"key":"agent:scout:slack:channel:c1","agentId":"scout","sessionId":"channel-root","updatedAt":1990000000003,"status":"done"},
      {"key":"agent:scout:cron:86adfcce","agentId":"scout","sessionId":"cron","updatedAt":1990000000004,"status":"done"},
      {"key":"agent:scout:slack:direct:u1:thread:1900000000.000005","agentId":"scout","sessionId":"dm-thread","updatedAt":1990000000005,"status":"done"},
      {"key":"agent:scout:slack:channel:u1:thread:1900000000.000006","agentId":"scout","sessionId":"dm-as-channel","updatedAt":1990000000006,"status":"done"},
      {"key":"agent:scout:slack:group:g1:thread:1900000000.000007","agentId":"scout","sessionId":"mpim","updatedAt":1990000000006,"status":"done"},
      {"key":"agent:scout:slack:channel:c1:thread:1900000000.000009","agentId":"scout","updatedAt":1990000000007,"status":"done"}
    ]
  }'
}

@test "dry-run selects only old terminal Slack channel threads" {
  run bash "$SUT" --profile main

  [ "$status" -eq 0 ]
  [ "$(jq -r '.mode' <<<"$output")" = "dry-run" ]
  [ "$(jq -r '.eligible' <<<"$output")" -eq 2 ]
  [ "$(jq -r '.selected' <<<"$output")" -eq 2 ]
  [ ! -e "$OPENCLAW_STUB_LOG" ]
  [[ "$output" != *"86adfcce"* ]]
  [[ "$output" != *"channel-root"* ]]
  [[ "$output" != *"mpim"* ]]
}

@test "apply deletes through the gateway with optimistic concurrency guards" {
  run bash "$SUT" --profile main --apply

  [ "$status" -eq 0 ]
  [ "$(jq -r '.deleted' <<<"$output")" -eq 2 ]
  [ "$(wc -l < "$OPENCLAW_STUB_LOG")" -eq 2 ]
  jq -e 'select(.agentId == "scout" and .expectedSessionId == "old-done" and .expectedSessionUpdatedAt == 1990000000000 and .requireInactive == true and .deleteTranscript == true)' \
    "$OPENCLAW_STUB_LOG" >/dev/null
  jq -e 'select(.agentId == "ops" and .expectedSessionId == "old-failed" and .expectedSessionUpdatedAt == 1990000000001 and .deleteTranscript == true)' \
    "$OPENCLAW_STUB_LOG" >/dev/null
}

@test "a session changed before deletion is a safe race, not a failed sweep" {
  export OPENCLAW_STUB_SESSIONS='{"sessions":[
    {"key":"agent:scout:slack:channel:c1:thread:1900000000.000006","agentId":"scout","sessionId":"race","updatedAt":1990000000000,"status":"done"}
  ]}'

  run bash "$SUT" --profile main --apply

  [ "$status" -eq 0 ]
  [ "$(jq -r '.raced' <<<"$output")" -eq 1 ]
  [ "$(jq -r '.failed' <<<"$output")" -eq 0 ]
}

@test "an unexpected gateway failure fails loud after printing the summary" {
  export OPENCLAW_STUB_SESSIONS='{"sessions":[
    {"key":"agent:scout:slack:channel:c1:thread:1900000000.000007","agentId":"scout","sessionId":"broken","updatedAt":1990000000000,"status":"killed"},
    {"key":"agent:scout:slack:channel:c1:thread:1900000000.000008","agentId":"scout","sessionId":"would-starve","updatedAt":1990000000001,"status":"done"}
  ]}'

  run bash "$SUT" --profile main --apply

  [ "$status" -eq 1 ]
  [ "$(jq -r '.failed' <<<"$output")" -eq 1 ]
  [ "$(jq -r '.selected' <<<"$output")" -eq 2 ]
  [ "$(wc -l < "$OPENCLAW_STUB_LOG")" -eq 1 ]
}

@test "the per-run cap bounds gateway mutations" {
  export SESSION_THREAD_MAX_DELETES=1

  run bash "$SUT" --profile main --apply

  [ "$status" -eq 0 ]
  [ "$(jq -r '.eligible' <<<"$output")" -eq 2 ]
  [ "$(jq -r '.selected' <<<"$output")" -eq 1 ]
  [ "$(wc -l < "$OPENCLAW_STUB_LOG")" -eq 1 ]
}

@test "overflowing retention inputs fail before any deletion" {
  export SESSION_THREAD_RETENTION_DAYS=9223372036854775807

  run bash "$SUT" --profile main --apply

  [ "$status" -eq 2 ]
  [[ "$output" == *"1..3650"* ]]
  [ ! -e "$OPENCLAW_STUB_LOG" ]
}

@test "timed-out threads are terminal and eligible" {
  export OPENCLAW_STUB_SESSIONS='{"sessions":[
    {"key":"agent:scout:slack:channel:c1:thread:1900000000.000008","agentId":"scout","sessionId":"timeout","updatedAt":1990000000000,"status":"timeout"}
  ]}'

  run bash "$SUT" --profile main --apply

  [ "$status" -eq 0 ]
  [ "$(jq -r '.deleted' <<<"$output")" -eq 1 ]
}

@test "a legacy row without sessionId is excluded rather than weakly deleted" {
  export OPENCLAW_STUB_SESSIONS='{"sessions":[
    {"key":"agent:scout:slack:channel:c1:thread:1900000000.000010","agentId":"scout","updatedAt":1990000000000,"status":"done"}
  ]}'

  run bash "$SUT" --profile main --apply

  [ "$status" -eq 0 ]
  [ "$(jq -r '.eligible' <<<"$output")" -eq 0 ]
  [ ! -e "$OPENCLAW_STUB_LOG" ]
}

@test "explicit profile selection ignores inherited OpenClaw profile state" {
  export OPENCLAW_STATE_DIR=/wrong/state
  export OPENCLAW_CONFIG_PATH=/wrong/config.json
  export OPENCLAW_PROFILE=wrong
  export OPENCLAW_HOME=/wrong/home
  export OPENCLAW_GATEWAY_URL=ws://wrong.invalid
  export OPENCLAW_GATEWAY_PORT=1
  export OPENCLAW_GATEWAY_TOKEN=wrong
  export OPENCLAW_GATEWAY_PASSWORD=wrong

  run bash "$SUT" --profile edge

  [ "$status" -eq 0 ]
  [ "$(jq -r '.profile' <<<"$output")" = "edge" ]
}

@test "installer schedules main and edge as independent template instances" {
  grep -Fq 'hydra-session-thread-retention@.service' "$REPO_ROOT/scripts/install-aux-units.sh"
  grep -Fq 'ExecStart=$HYDRA_ROOT/scripts/prune-completed-slack-thread-sessions.sh --profile %i --apply' \
    "$REPO_ROOT/scripts/install-aux-units.sh"
  grep -Fq 'for profile in main edge; do' "$REPO_ROOT/scripts/install-aux-units.sh"
  grep -Fq 'TimeoutStartSec=60min' "$REPO_ROOT/scripts/install-aux-units.sh"
  grep -Fq '|| fail "could not enable $retention_tmr"' "$REPO_ROOT/scripts/install-aux-units.sh"
  grep -Fq '|| fail "could not start $retention_tmr"' "$REPO_ROOT/scripts/install-aux-units.sh"
  grep -Fq '$retention_tmr is not active' "$REPO_ROOT/scripts/install-aux-units.sh"
  ! grep -Fq 'hydra-session-thread-retention.service' "$REPO_ROOT/scripts/install-aux-units.sh"
}
