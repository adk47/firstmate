#!/usr/bin/env bats
# Tests for scripts/fallback-swallow-watchdog.sh — alerts #clio_devops when an
# agent turn ends in an empty completion (payloads=0) surfaced as an error, the
# symptom of openclaw's empty-completion-swallows-fallback flaw (PR #450).
#
# Each case feeds a captured journal fixture via FALLBACK_SWALLOW_JOURNAL_FILE
# and runs in --dry-run so nothing posts to Slack. Belt-and-braces: muso is
# PATH-stubbed and MUSO_SLACK_ENV_FILE points at a fixture so the suite can
# never read the real main.env or page #clio_devops. SKIP_HOST_GUARD bypasses
# the ovh-node-8 guard. Modeled on scripts/tests/cron-health-watchdog.bats.
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
SCRIPT="$HYDRA_REPO/scripts/fallback-swallow-watchdog.sh"

EMPTY_LINE='2026-06-08T11:46:48.365+00:00 [agent/embedded] incomplete turn detected: runId=RUN-empty sessionId=sess-empty stopReason=stop payloads=0 — surfacing error to user'
NONEMPTY_LINE='2026-06-08T12:00:00.000+00:00 [agent/embedded] incomplete turn detected: runId=RUN-full sessionId=sess-x stopReason=stop payloads=4 — surfacing error to user'

setup() {
  TEST_TMPDIR="$(mktemp -d)"; export TEST_TMPDIR
  # Hermeticity: a real maintenance window (/run/hydra-maintenance) must not
  # disarm this watchdog during CI (it runs on the live node-8 host). Pin the
  # flag at an absent throwaway path so maintenance_active() reads inactive.
  export HYDRA_MAINTENANCE_FLAG="$TEST_TMPDIR/no-maintenance-window"
  JNL="$TEST_TMPDIR/journal.txt"
  STATE="$TEST_TMPDIR/state.json"

  # Never touch the real Slack token source or binary.
  unset MUSO_SLACK_BOT_TOKEN_DEVOPS
  export MUSO_SLACK_ENV_FILE="$TEST_TMPDIR/muso-slack.env"  # absent → no token
  export STUB_CALLS="$TEST_TMPDIR/muso-calls"
  : > "$STUB_CALLS"
  mkdir -p "$TEST_TMPDIR/bin"
  cat > "$TEST_TMPDIR/bin/muso" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_CALLS"
echo '{"channel":"C0TEST","ts":"1717171717.000100"}'
STUB
  chmod +x "$TEST_TMPDIR/bin/muso"
  PATH="$TEST_TMPDIR/bin:$PATH"; export PATH
}
teardown() { rm -rf "$TEST_TMPDIR"; }

run_wd() {
  run env \
    FALLBACK_SWALLOW_SKIP_HOST_GUARD=1 \
    FALLBACK_SWALLOW_JOURNAL_FILE="$JNL" \
    FALLBACK_SWALLOW_STATE_FILE="$STATE" \
    FALLBACK_SWALLOW_AGENT_ROOTS="$TEST_TMPDIR/agents" \
    "$SCRIPT" --dry-run
}

@test "empty completion (payloads=0) with seeded state fires an alert" {
  printf '%s\n' "$EMPTY_LINE" > "$JNL"
  printf '%s\n' '{"RUN-old":"2026-06-01T00:00:00Z"}' > "$STATE"
  run_wd
  [ "$status" -eq 0 ]
  [[ "$output" == *"Empty-completion fallback swallow"* ]]
  [[ "$output" == *"RUN-empty"* ]]
}

@test "non-empty incomplete turn (payloads>0) does NOT alert" {
  printf '%s\n' "$NONEMPTY_LINE" > "$JNL"
  printf '%s\n' '{"RUN-old":"2026-06-01T00:00:00Z"}' > "$STATE"
  run_wd
  [ "$status" -eq 0 ]
  [[ "$output" == *"no new empty-completion fallback swallows"* ]]
}

@test "first-ever run (no state file) seeds without alerting" {
  printf '%s\n' "$EMPTY_LINE" > "$JNL"
  [ ! -f "$STATE" ]
  run_wd
  [ "$status" -eq 0 ]
  [[ "$output" == *"no new empty-completion fallback swallows"* ]]
  # watermark now records the runId so a later run won't backfill-page
  grep -q "RUN-empty" "$STATE"
}

@test "already-seen runId does not re-alert" {
  printf '%s\n' "$EMPTY_LINE" > "$JNL"
  printf '%s\n' '{"RUN-empty":"2026-06-08T11:46:48Z"}' > "$STATE"
  run_wd
  [ "$status" -eq 0 ]
  [[ "$output" == *"no new empty-completion fallback swallows"* ]]
}

@test "resolves agent name from sessionId" {
  printf '%s\n' "$EMPTY_LINE" > "$JNL"
  printf '%s\n' '{"RUN-old":"x"}' > "$STATE"
  mkdir -p "$TEST_TMPDIR/agents/cmo/sessions"
  : > "$TEST_TMPDIR/agents/cmo/sessions/sess-empty-topic-1.jsonl"
  run_wd
  [ "$status" -eq 0 ]
  [[ "$output" == *"*cmo*"* ]]
}
