#!/usr/bin/env bats
# Tests for scripts/qa-pr-merged-dm.sh — posts the one-line "PR #N merged" closure
# reply into the PR's existing QA review thread when a QA-reviewed PR is merged.
# Stubs qa-slack-dm.sh via QA_SLACK_DM and points the per-PR thread store at a temp
# dir, so the suite NEVER touches the real Slack API (memory: bats must stub network
# calls — an unstubbed test once fired 9 real Slack alerts).
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
SCRIPT="$HYDRA_REPO/scripts/qa-pr-merged-dm.sh"

setup() {
  TEST_TMPDIR="$(mktemp -d)"; export TEST_TMPDIR
  export QA_THREAD_STATE_DIR="$TEST_TMPDIR/state"
  export STUB_TEXT="$TEST_TMPDIR/sent-text"     # every <text> the stub received
  export STUB_THREAD="$TEST_TMPDIR/sent-thread" # every <thread_ts> (blank if none)
  export STUB_TS="${STUB_TS:-1717171717.000100}"
  : > "$STUB_TEXT"
  : > "$STUB_THREAD"

  # Default stub: log args, echo a fixed ts (success). Individual tests override it.
  STUBBIN="$TEST_TMPDIR/bin"; mkdir -p "$STUBBIN"
  export QA_SLACK_DM="$STUBBIN/qa-slack-dm.sh"
  cat > "$QA_SLACK_DM" <<'STUB'
#!/usr/bin/env bash
# $1=uid  $2=text  $3=thread_ts (may be empty)
printf '%s\n' "$2" >> "$STUB_TEXT"
printf '%s\n' "${3:-}" >> "$STUB_THREAD"
printf '%s\n' "$STUB_TS"
STUB
  chmod +x "$QA_SLACK_DM"

  STATE_FILE="$QA_THREAD_STATE_DIR/Muso-AI__hydra-pr-123.ts"
}
teardown() { rm -rf "$TEST_TMPDIR"; }

@test "thread exists: posts the closure threaded under the recorded root" {
  mkdir -p "$QA_THREAD_STATE_DIR"
  echo "1111111111.000001" > "$STATE_FILE"   # the QA review thread root
  run "$SCRIPT" Muso-AI/hydra 123 U0AL36NADEY
  [ "$status" -eq 0 ]
  # Sent exactly once, threaded under the root (not top-level).
  [ "$(cat "$STUB_THREAD")" = "1111111111.000001" ]
  grep -q -- 'PR #123 (Muso-AI/hydra) was just merged' "$STUB_TEXT"
  # The state file is left intact (the thread may still be referenced elsewhere).
  [ "$(cat "$STATE_FILE")" = "1111111111.000001" ]
}

@test "no QA thread for this PR: no-op, nothing sent, exit 0" {
  # No state file written -> QA never reviewed this PR.
  run "$SCRIPT" Muso-AI/hydra 123 U0AL36NADEY
  [ "$status" -eq 0 ]
  [ ! -s "$STUB_TEXT" ]
  [ ! -s "$STUB_THREAD" ]
}

@test "slack hiccup is best-effort: thread exists but send fails -> still exit 0" {
  mkdir -p "$QA_THREAD_STATE_DIR"
  echo "1111111111.000001" > "$STATE_FILE"
  cat > "$QA_SLACK_DM" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$2" >> "$STUB_TEXT"
exit 1
STUB
  chmod +x "$QA_SLACK_DM"
  run "$SCRIPT" Muso-AI/hydra 123 U0AL36NADEY
  # A Slack failure on a cosmetic post-merge note must never fail the merge workflow.
  [ "$status" -eq 0 ]
  # It still attempted the post.
  grep -q -- 'PR #123 (Muso-AI/hydra) was just merged' "$STUB_TEXT"
}

@test "repo slug with slash is sanitized to the same state-file name as the opener" {
  mkdir -p "$QA_THREAD_STATE_DIR"
  echo "2222222222.000002" > "$QA_THREAD_STATE_DIR/Muso-AI__hydra-pr-999.ts"
  run "$SCRIPT" Muso-AI/hydra 999 U0AL36NADEY
  [ "$status" -eq 0 ]
  [ "$(cat "$STUB_THREAD")" = "2222222222.000002" ]
}

@test "missing args -> usage exit 2, nothing sent" {
  run "$SCRIPT" Muso-AI/hydra 123
  [ "$status" -eq 2 ]
  [ ! -s "$STUB_TEXT" ]
}

@test "non-numeric pr -> usage exit 2, nothing sent" {
  run "$SCRIPT" Muso-AI/hydra not-a-number U0AL36NADEY
  [ "$status" -eq 2 ]
  [ ! -s "$STUB_TEXT" ]
}
