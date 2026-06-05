#!/usr/bin/env bats
# Tests for scripts/qa-pr-thread-dm.sh — sends the QA auto-review opening DM into
# the PR's ONE canonical Slack thread (so re-reviews don't spawn a new top-level
# message). Stubs qa-slack-dm.sh via QA_SLACK_DM and points the per-PR thread store
# at a temp dir, so the suite NEVER touches the real Slack API (memory: bats must
# stub network calls — an unstubbed test once fired 9 real Slack alerts).
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
SCRIPT="$HYDRA_REPO/scripts/qa-pr-thread-dm.sh"

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

  # gh stub: the script fetches the PR title best-effort for a scannable link.
  # Keep it off the network and deterministic — print a fixed title regardless of
  # args. The title-fetch-failure test overrides this to exit 1.
  export GH="$STUBBIN/gh"
  cat > "$GH" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "Guard reasoning leak"
STUB
  chmod +x "$GH"

  STATE_FILE="$QA_THREAD_STATE_DIR/Muso-AI__hydra-pr-123.ts"
}
teardown() { rm -rf "$TEST_TMPDIR"; }

@test "first review: posts top-level, records root, prints ts" {
  run "$SCRIPT" Muso-AI/hydra 123 U0AL36NADEY
  [ "$status" -eq 0 ]
  [ "$output" = "1717171717.000100" ]
  # No thread_ts on the first send (top-level).
  [ "$(cat "$STUB_THREAD")" = "" ]
  # First-review wording with the clickable titled link (repo-prefixed), not the
  # re-review variant, and no longer carrying the redundant bot name.
  grep -q -- 'hydra#123: Guard reasoning leak' "$STUB_TEXT"
  grep -q -- 'https://github.com/Muso-AI/hydra/pull/123' "$STUB_TEXT"
  grep -q -- "I'll update this thread" "$STUB_TEXT"
  ! grep -q -- 're-reviewing' "$STUB_TEXT"
  ! grep -q -- 'Muso QA Bot' "$STUB_TEXT"
  # The thread root is persisted for next time.
  [ "$(cat "$STATE_FILE")" = "1717171717.000100" ]
}

@test "re-review: threads under the recorded root and returns the root, not the reply ts" {
  mkdir -p "$QA_THREAD_STATE_DIR"
  echo "1111111111.000001" > "$STATE_FILE"   # pre-existing root from a prior run
  STUB_TS="2222222222.000002"                # the stub returns the *reply* ts
  run env STUB_TS="$STUB_TS" "$SCRIPT" Muso-AI/hydra 123 U0AL36NADEY
  [ "$status" -eq 0 ]
  # Returns the ROOT, so the caller's result reply lands in the same thread.
  [ "$output" = "1111111111.000001" ]
  # The send was threaded under the root.
  [ "$(cat "$STUB_THREAD")" = "1111111111.000001" ]
  # Re-review wording with the clickable titled link (repo-prefixed).
  grep -q -- 're-reviewing' "$STUB_TEXT"
  grep -q -- 'hydra#123: Guard reasoning leak' "$STUB_TEXT"
  grep -q -- 'https://github.com/Muso-AI/hydra/pull/123' "$STUB_TEXT"
  # Root is unchanged (still the original).
  [ "$(cat "$STATE_FILE")" = "1111111111.000001" ]
}

@test "title fetch fails: best-effort -> title-less link, message still posts" {
  # gh unavailable / errors. The opening note must still go out, degraded to the
  # number-only label (never worse than the pre-title behavior).
  cat > "$GH" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
  chmod +x "$GH"
  run "$SCRIPT" Muso-AI/hydra 123 U0AL36NADEY
  [ "$status" -eq 0 ]
  [ "$output" = "1717171717.000100" ]
  # Falls back to the title-less link (repo-prefixed), not a broken/empty one.
  grep -q -- '<https://github.com/Muso-AI/hydra/pull/123|hydra#123>' "$STUB_TEXT"
  ! grep -q -- 'Guard reasoning leak' "$STUB_TEXT"
  [ "$(cat "$STATE_FILE")" = "1717171717.000100" ]
}

@test "stale root: threaded send fails -> falls back to top-level and re-anchors" {
  mkdir -p "$QA_THREAD_STATE_DIR"
  echo "1111111111.000001" > "$STATE_FILE"
  # Stub: fail when a thread_ts is given (root deleted), succeed top-level.
  cat > "$QA_SLACK_DM" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$2" >> "$STUB_TEXT"
printf '%s\n' "${3:-}" >> "$STUB_THREAD"
if [ -n "${3:-}" ]; then exit 1; fi
printf '%s\n' "3333333333.000003"
STUB
  chmod +x "$QA_SLACK_DM"
  run "$SCRIPT" Muso-AI/hydra 123 U0AL36NADEY
  [ "$status" -eq 0 ]
  [ "$output" = "3333333333.000003" ]
  # Tried the stale root first, then a top-level fallback (blank thread_ts).
  [ "$(sed -n 1p "$STUB_THREAD")" = "1111111111.000001" ]
  [ "$(sed -n 2p "$STUB_THREAD")" = "" ]
  # State re-anchored on the new top-level message.
  [ "$(cat "$STATE_FILE")" = "3333333333.000003" ]
}

@test "total slack failure: exit 1, no state written" {
  cat > "$QA_SLACK_DM" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
  chmod +x "$QA_SLACK_DM"
  run "$SCRIPT" Muso-AI/hydra 123 U0AL36NADEY
  [ "$status" -eq 1 ]
  [ ! -f "$STATE_FILE" ]
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
