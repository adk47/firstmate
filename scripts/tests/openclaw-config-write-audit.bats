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

# Put $WATCHED under a profile-named parent dir so the audit script's
# gateway-startup glob (*/.openclaw-<profile>/openclaw.json) matches.
# Used by the gateway-startup-suppression tests below.
setup_profile_watched() {
  local profile="$1"
  local dir="$TEST_TMPDIR/.openclaw-${profile}"
  mkdir -p "$dir"
  WATCHED="$dir/openclaw.json"
  printf '{}\n' > "$WATCHED"
  export WATCHED
  WATCHED_REAL=$(realpath "$WATCHED")
  WATCHED_SHA=$(sha256sum "$WATCHED" | awk '{print $1}')
  export WATCHED_REAL WATCHED_SHA
}

# PATH-shadow systemctl so the audit script's
# `systemctl show -p ActiveEnterTimestamp --value …` call returns a
# scripted value. Pass an ISO timestamp (or empty string for "no value")
# to control what the script sees.
stub_systemctl() {
  local ts="$1"
  mkdir -p "$TEST_TMPDIR/bin"
  cat > "$TEST_TMPDIR/bin/systemctl" <<STUB
#!/bin/bash
# Test stub. Only handles 'show -p ActiveEnterTimestamp --value <unit>'.
if [ "\$1" = "show" ] && [ "\$2" = "-p" ] && [ "\$3" = "ActiveEnterTimestamp" ] && [ "\$4" = "--value" ]; then
  printf '%s\n' "$ts"
  exit 0
fi
exit 0
STUB
  chmod +x "$TEST_TMPDIR/bin/systemctl"
  PATH="$TEST_TMPDIR/bin:$PATH"
  export PATH
}

# PATH-shadow journalctl so the audit script's config-io self-persist check
# (`journalctl -u openclaw-gateway-<profile>.service --since '30 sec ago' …`)
# returns scripted output instead of querying the live gateway journal on
# node-8 (which would make these tests flaky). Pass the desired stdout, or ""
# for "no reload activity in window". Same stub also intercepts the SSH-
# correlation journalctl call — benign: its output is grep-filtered for SSH
# session lines, which scripted reload text never matches.
stub_journalctl() {
  local out="$1"
  mkdir -p "$TEST_TMPDIR/bin"
  cat > "$TEST_TMPDIR/bin/journalctl" <<STUB
#!/bin/bash
printf '%s\n' "$out"
exit 0
STUB
  chmod +x "$TEST_TMPDIR/bin/journalctl"
  PATH="$TEST_TMPDIR/bin:$PATH"
  export PATH
}

# Portable timestamp generator: returns an ISO string `<secs_ago>`
# seconds before now, in the format systemd's ActiveEnterTimestamp
# uses. Uses python3 because BSD `date` (macOS) and GNU `date`
# (Linux) disagree on relative-time syntax.
iso_seconds_ago() {
  local secs_ago="$1"
  python3 -c "import time; t=time.gmtime(time.time()-$secs_ago); print(time.strftime('%a %Y-%m-%d %H:%M:%S UTC', t))"
}

# The audit script parses the systemd timestamp via GNU `date -d`,
# which doesn't exist on BSD/macOS. The suppression-positive test
# below needs that parse to succeed, so skip it off-Linux. CI
# (Linux) still runs it. The suppression-bounded test and the
# case-glob-miss test both *expect* the alert path, which is
# exactly what happens when `date -d` is missing — those run
# everywhere.
require_linux() {
  [[ "$(uname -s)" == "Linux" ]] || skip "requires GNU date -d (Linux)"
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
  if grep -q '\[legit\]' "$OPENCLAW_AUDIT_LOG"; then echo "stale legit-log entry (>120s) was wrongly treated as legit" >&2; false; fi
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
  if grep -q '\[legit\]' "$OPENCLAW_AUDIT_LOG"; then echo "sha256 mismatch (hostile write) was wrongly treated as legit" >&2; false; fi
  [ -f "$TEST_TMPDIR/slack.calls" ]
}

@test "no legit log file at all → existing behavior (alert fires)" {
  rm -f "$OPENCLAW_LEGIT_LOG"

  run run_audit
  [ "$status" -eq 0 ]
  if grep -q '\[legit\]' "$OPENCLAW_AUDIT_LOG"; then echo "missing legit log was wrongly treated as legit" >&2; false; fi
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

# ─── Gateway-startup suppression (Change 2 / 2026-05-12) ───────────
# After the legit-log lookup fails, the audit script checks whether
# the gateway service for the profile encoded in $WATCHED entered
# active state in the last 15s. If so, the write is openclaw's own
# config-io re-persist on startup and is silenced.

@test "gateway entered active state <15s ago → no alert, [legit] gateway-startup log line" {
  require_linux
  setup_profile_watched main
  ts=$(iso_seconds_ago 5)
  stub_systemctl "$ts"

  run run_audit
  [ "$status" -eq 0 ]
  grep -q '\[legit\] openclaw-gateway-main entered active state' "$OPENCLAW_AUDIT_LOG"
  [ ! -f "$TEST_TMPDIR/slack.calls" ]
}

@test "gateway entered active state >15s ago → alert fires (suppression bounded)" {
  setup_profile_watched edge
  ts=$(iso_seconds_ago 60)
  stub_systemctl "$ts"
  stub_journalctl ""  # no reload activity → don't let the self-persist branch interfere

  run run_audit
  [ "$status" -eq 0 ]
  if grep -q '\[legit\]' "$OPENCLAW_AUDIT_LOG"; then echo "startup suppression window (>15s) wrongly silenced the alert" >&2; false; fi
  [ -f "$TEST_TMPDIR/slack.calls" ]
  grep -q 'Out-of-band write' "$TEST_TMPDIR/slack.calls"
}

@test "systemctl returns empty ActiveEnterTimestamp → alert fires (no spurious silencing)" {
  setup_profile_watched main
  stub_systemctl ""
  stub_journalctl ""  # no reload activity → don't let the self-persist branch interfere

  run run_audit
  [ "$status" -eq 0 ]
  if grep -q '\[legit\]' "$OPENCLAW_AUDIT_LOG"; then echo "empty ActiveEnterTimestamp wrongly silenced the alert" >&2; false; fi
  [ -f "$TEST_TMPDIR/slack.calls" ]
}

@test "watched path not under .openclaw-<profile>/ → gateway-startup branch is skipped (alert fires)" {
  # WATCHED stays at $TEST_TMPDIR/openclaw.json (no profile prefix).
  # The case-glob in the audit script must not match, so the
  # gateway-startup branch must not silence the write even with a
  # fresh systemctl stub.
  ts=$(iso_seconds_ago 5)
  stub_systemctl "$ts"

  run run_audit
  [ "$status" -eq 0 ]
  if grep -q '\[legit\]' "$OPENCLAW_AUDIT_LOG"; then echo "watched path outside .openclaw-<profile>/ wrongly matched the gateway-startup branch" >&2; false; fi
  [ -f "$TEST_TMPDIR/slack.calls" ]
}

# ─── config-io self-persist suppression (gateway accepted reload/restart) ───
# After the startup-suppression window misses, the audit script asks the
# gateway journal whether openclaw ACCEPTED a config change in the last 30s.
# An accept line (hot-reload-applied / requires-restart / SIGUSR1) means the
# write was openclaw's own config-io persist of a CLI/runtime change → silence.
# A reject line ("config reload skipped (invalid config)") is the 2026-05-05
# crash class → MUST still alert. No accept line → still alert. stub_systemctl
# "" keeps the prior (startup) branch from firing so we exercise this one.

@test "gateway logged 'config hot reload applied' in window → no alert, [legit] self-persist" {
  setup_profile_watched main
  stub_systemctl ""
  stub_journalctl "2026-06-05T14:06:03.868+00:00 [reload] config hot reload applied (agents.list)"

  run run_audit
  [ "$status" -eq 0 ]
  grep -q '\[legit\] openclaw config-io self-persist' "$OPENCLAW_AUDIT_LOG"
  [ ! -f "$TEST_TMPDIR/slack.calls" ]
}

@test "gateway logged 'config change requires gateway restart' in window → no alert, [legit] self-persist" {
  setup_profile_watched main
  stub_systemctl ""
  stub_journalctl "2026-06-05T14:06:03.967+00:00 [reload] config change requires gateway restart (plugins.installs)"

  run run_audit
  [ "$status" -eq 0 ]
  grep -q '\[legit\] openclaw config-io self-persist' "$OPENCLAW_AUDIT_LOG"
  [ ! -f "$TEST_TMPDIR/slack.calls" ]
}

@test "gateway logged 'received SIGUSR1; restarting' in window → no alert, [legit] self-persist" {
  setup_profile_watched edge
  stub_systemctl ""
  stub_journalctl "2026-06-05T14:06:03.969+00:00 [gateway] received SIGUSR1; restarting"

  run run_audit
  [ "$status" -eq 0 ]
  grep -q '\[legit\] openclaw config-io self-persist' "$OPENCLAW_AUDIT_LOG"
  [ ! -f "$TEST_TMPDIR/slack.calls" ]
}

@test "gateway logged 'config reload skipped (invalid config)' in window → alert fires (crash class not masked)" {
  setup_profile_watched main
  stub_systemctl ""
  stub_journalctl "2026-06-05T14:06:03.900+00:00 [reload] config reload skipped (invalid config): subagents: Unrecognized key"

  run run_audit
  [ "$status" -eq 0 ]
  if grep -q '\[legit\]' "$OPENCLAW_AUDIT_LOG"; then echo "a rejected (invalid config) reload was wrongly treated as legit self-persist" >&2; false; fi
  [ -f "$TEST_TMPDIR/slack.calls" ]
  grep -q 'Out-of-band write' "$TEST_TMPDIR/slack.calls"
}

@test "both reject and accept lines in window → alert fires (fail toward alerting)" {
  setup_profile_watched main
  stub_systemctl ""
  stub_journalctl "$(printf '%s\n%s\n' \
    '[reload] config hot reload applied (agents.list)' \
    '[reload] config reload skipped (invalid config): subagents: Unrecognized key')"

  run run_audit
  [ "$status" -eq 0 ]
  if grep -q '\[legit\]' "$OPENCLAW_AUDIT_LOG"; then echo "reject+accept in the same window was wrongly treated as legit self-persist" >&2; false; fi
  [ -f "$TEST_TMPDIR/slack.calls" ]
}

@test "only 'config change detected' (no accept) in window → alert fires (external write not masked)" {
  setup_profile_watched main
  stub_systemctl ""
  stub_journalctl "2026-06-05T14:06:03.868+00:00 [reload] config change detected (agents.list)"

  run run_audit
  [ "$status" -eq 0 ]
  if grep -q '\[legit\]' "$OPENCLAW_AUDIT_LOG"; then echo "a bare config-change-detected line with no accept was wrongly treated as legit" >&2; false; fi
  [ -f "$TEST_TMPDIR/slack.calls" ]
  grep -q 'Out-of-band write' "$TEST_TMPDIR/slack.calls"
}

@test "empty gateway journal in window → alert fires (no spurious silencing)" {
  setup_profile_watched main
  stub_systemctl ""
  stub_journalctl ""

  run run_audit
  [ "$status" -eq 0 ]
  if grep -q '\[legit\]' "$OPENCLAW_AUDIT_LOG"; then echo "empty gateway journal wrongly silenced the alert" >&2; false; fi
  [ -f "$TEST_TMPDIR/slack.calls" ]
}
