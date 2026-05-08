#!/usr/bin/env bats
# Tests for scripts/openclaw-config-write-audit.sh's legit-writes-log
# suppression path. These tests MUST PATH-shadow slack_notify and any
# `openclaw` calls — without the shadow, a CI run on hydra (where the
# real bot token is reachable) posts directly to #clio_devops. See
# memory/feedback_bats_must_stub_openclaw.md and the 2026-05-06
# PR #245 incident.
bats_require_minimum_version 1.5.0

REPO_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
AUDIT_SRC="$REPO_ROOT/scripts/openclaw-config-write-audit.sh"
ANNOUNCE_SRC="$REPO_ROOT/scripts/lib/announce-legit-write.sh"

setup() {
  TEST_TMPDIR="$(mktemp -d)"
  export TEST_TMPDIR

  # Build a sandboxed scripts/ that mirrors the on-disk layout so the
  # audit script's `SCRIPT_DIR/lib/slack-notify.sh` source resolves
  # to OUR stub. The stub records every call to a file the test reads.
  mkdir -p "$TEST_TMPDIR/scripts/lib"
  cp "$AUDIT_SRC" "$TEST_TMPDIR/scripts/openclaw-config-write-audit.sh"
  chmod +x "$TEST_TMPDIR/scripts/openclaw-config-write-audit.sh"

  cat > "$TEST_TMPDIR/scripts/lib/slack-notify.sh" <<STUB
#!/bin/bash
# Test stub. Records calls instead of hitting Slack.
slack_notify() {
  printf 'SLACK_NOTIFY %s\n' "\$*" >> "$TEST_TMPDIR/slack.calls"
}
STUB

  # Override the hardcoded log paths.
  export OPENCLAW_AUDIT_LOG="$TEST_TMPDIR/audit.log"
  export OPENCLAW_LEGIT_LOG="$TEST_TMPDIR/legit.log"

  # Watched file: empty file the audit script will sha256.
  WATCHED="$TEST_TMPDIR/openclaw.json"
  printf '{}\n' > "$WATCHED"
  export WATCHED
  WATCHED_REAL=$(realpath "$WATCHED")
  WATCHED_SHA=$(sha256sum "$WATCHED" | awk '{print $1}')
  export WATCHED_REAL WATCHED_SHA
}

teardown() {
  rm -rf "$TEST_TMPDIR"
}

run_audit() {
  # The audit script normally infers SCRIPT_DIR from BASH_SOURCE; by
  # invoking the sandboxed copy, the SLACK source resolves to our stub.
  "$TEST_TMPDIR/scripts/openclaw-config-write-audit.sh" "$WATCHED"
}

@test "fresh hash-matching legit entry → no alert, [legit] log line, exit 0" {
  now=$(date -u +%s)
  printf '%s 2026-05-08T13:40:04Z deploy.sh pid=999 ppid=1 sha256=%s %s\n' \
    "$now" "$WATCHED_SHA" "$WATCHED_REAL" >> "$OPENCLAW_LEGIT_LOG"

  run run_audit
  [ "$status" -eq 0 ]
  grep -q '\[legit\] in-band atomic-rename write' "$OPENCLAW_AUDIT_LOG"
  [ ! -f "$TEST_TMPDIR/slack.calls" ]
}

@test "legit entry older than 120s → alert fires (no suppression)" {
  old=$(( $(date -u +%s) - 200 ))
  printf '%s 2026-05-08T13:36:44Z deploy.sh pid=999 ppid=1 sha256=%s %s\n' \
    "$old" "$WATCHED_SHA" "$WATCHED_REAL" >> "$OPENCLAW_LEGIT_LOG"

  run run_audit
  [ "$status" -eq 0 ]
  ! grep -q '\[legit\]' "$OPENCLAW_AUDIT_LOG"
  [ -f "$TEST_TMPDIR/slack.calls" ]
  grep -q 'Out-of-band write' "$TEST_TMPDIR/slack.calls"
}

@test "legit entry with mismatching sha256 → alert fires (hostile-write defense)" {
  now=$(date -u +%s)
  printf '%s 2026-05-08T13:40:04Z deploy.sh pid=999 ppid=1 sha256=%s %s\n' \
    "$now" "0000000000000000000000000000000000000000000000000000000000000000" \
    "$WATCHED_REAL" >> "$OPENCLAW_LEGIT_LOG"

  run run_audit
  [ "$status" -eq 0 ]
  ! grep -q '\[legit\]' "$OPENCLAW_AUDIT_LOG"
  [ -f "$TEST_TMPDIR/slack.calls" ]
}

@test "no legit log file at all → existing behavior (alert fires)" {
  rm -f "$OPENCLAW_LEGIT_LOG"

  run run_audit
  [ "$status" -eq 0 ]
  ! grep -q '\[legit\]' "$OPENCLAW_AUDIT_LOG"
  [ -f "$TEST_TMPDIR/slack.calls" ]
}

@test "OPENCLAW_LEGIT_LOG unset under set -u → script still runs (regression for self-ref default)" {
  # The audit script runs under `set -euo pipefail`. A self-referential
  # default like LEGIT_LOG="${OPENCLAW_LEGIT_LOG:-"$LEGIT_LOG"}" would
  # die with "LEGIT_LOG: unbound variable" before reaching any logic.
  # Production never sets OPENCLAW_LEGIT_LOG; this test asserts the
  # default resolves cleanly. Caught by Clio's review of PR #265.
  unset OPENCLAW_LEGIT_LOG
  # Point the audit log somewhere writable so we can inspect it.
  # The legit-log default (/var/log/openclaw-legitimate-writes.log)
  # likely doesn't exist in the test sandbox; the script must tolerate
  # that and fall through to the alert path without dying.
  run "$TEST_TMPDIR/scripts/openclaw-config-write-audit.sh" "$WATCHED"
  [ "$status" -eq 0 ]
  # No "unbound variable" anywhere in stderr.
  ! echo "$output" | grep -q 'unbound variable'
}

@test "announce-legit-write.sh appends a well-formed line" {
  run env OPENCLAW_LEGIT_LOG="$OPENCLAW_LEGIT_LOG" \
    "$ANNOUNCE_SRC" deploy.sh "$WATCHED"
  [ "$status" -eq 0 ]
  [ -f "$OPENCLAW_LEGIT_LOG" ]
  line=$(tail -1 "$OPENCLAW_LEGIT_LOG")
  # Format: <epoch> <iso> <writer> pid=<n> ppid=<n> sha256=<hex> <path>
  echo "$line" | grep -qE '^[0-9]+ [0-9T:Z-]+ deploy\.sh pid=[0-9]+ ppid=[0-9?]+ sha256=[a-f0-9]+ '"$WATCHED_REAL"'$'
}

@test "announce-legit-write.sh: ANNOUNCE_SHA env wins over on-disk sha" {
  run env OPENCLAW_LEGIT_LOG="$OPENCLAW_LEGIT_LOG" ANNOUNCE_SHA=deadbeef \
    "$ANNOUNCE_SRC" deploy.sh "$WATCHED"
  [ "$status" -eq 0 ]
  grep -q 'sha256=deadbeef ' "$OPENCLAW_LEGIT_LOG"
}
