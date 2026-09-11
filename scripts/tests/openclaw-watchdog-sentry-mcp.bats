#!/usr/bin/env bats
#
# scripts/openclaw-watchdog.sh — the Sentry-MCP drift branch.
#
# WHY THIS SUITE EXISTS (QA finding on PR #870): the watchdog's exit-2 path
# gained a `slack_notify_critical` call, but nothing tested it. A later refactor
# could delete or bypass that page while the healer unit tests and the whole
# Bats suite stayed green — recreating the exact failure this branch was added
# to close: Sentry unavailable indefinitely with nobody told.
#
# "We could not check" is a THIRD state. It must be as loud as a known failure,
# because it can persist forever and looks identical to healthy from the outside.
#
# The block is EXTRACTED FROM THE REAL SCRIPT at run time rather than copied
# here, so deleting the notification in openclaw-watchdog.sh turns these red
# instead of leaving a stale copy passing. Same idiom as the sentry-triage
# ledger suites.
bats_require_minimum_version 1.5.0

WATCHDOG="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)/scripts/openclaw-watchdog.sh"

setup() {
  TMP="$BATS_TEST_TMPDIR/c"; mkdir -p "$TMP/lib"
  export _WATCHDOG_DIR="$TMP"
  export CALLS="$TMP/calls.log"; : > "$CALLS"

  # Extract the real block. Anchored on the section banner and its closing `fi`
  # so a rename of the section is a loud extraction failure, not a silent skip.
  BLOCK="$TMP/block.sh"
  awk '/^# ── Sentry MCP registration drift/,/^fi$/' "$WATCHDOG" > "$BLOCK"
  [ -s "$BLOCK" ] || { echo "extraction produced nothing — did the section banner change?" >&2; return 1; }
  grep -q 'ensure-sentry-mcp.sh' "$BLOCK" || { echo "extracted block does not reference the healer" >&2; return 1; }
}

# stub healer with a fixed --check exit code
mk_healer() {
  cat > "$TMP/lib/ensure-sentry-mcp.sh" <<STUB
#!/usr/bin/env bash
if [ "\${1:-}" = "--check" ]; then echo "stub check output"; exit $1; fi
echo "stub heal"; exit ${2:-0}
STUB
  chmod +x "$TMP/lib/ensure-sentry-mcp.sh"
}

run_block() {
  run bash -c '
    log() { printf "LOG %s\n" "$*" >> "$CALLS"; }
    slack_notify() { printf "NOTIFY %s\n" "$*" >> "$CALLS"; }
    slack_notify_critical() { printf "CRITICAL %s\n" "$*" >> "$CALLS"; }
    . "$1"' _ "$TMP/block.sh"
}

@test "clean (--check 0): no page, no heal" {
  mk_healer 0
  run_block
  [ ! -s "$CALLS" ]
}

@test "drift (--check 1) that heals: notifies, does NOT page critical" {
  mk_healer 1 0
  run_block
  grep -q '^NOTIFY .*had vanished' "$CALLS"
  run grep -q '^CRITICAL' "$CALLS"
  [ "$status" -ne 0 ]
}

@test "drift (--check 1) that CANNOT heal: pages critical" {
  mk_healer 1 2
  run_block
  grep -q '^CRITICAL .*could not be restored' "$CALLS"
}

@test "THE REGRESSION: unverifiable (--check 2) PAGES, it does not merely log" {
  # Before the fix this branch only logged, so an unreadable config could leave
  # Sentry dead forever with nothing said. A log line is not an alert.
  mk_healer 2
  run_block
  grep -q '^LOG .*UNVERIFIABLE' "$CALLS"
  grep -q '^CRITICAL .*UNVERIFIABLE' "$CALLS"
}

@test "unverifiable page names the exit code and the usual causes" {
  mk_healer 2
  run_block
  line=$(grep '^CRITICAL' "$CALLS")
  [[ "$line" == *"exit 2"* ]]
  [[ "$line" == *"sentry.env"* ]]
}

@test "an unexpected exit code is treated as unverifiable, not as clean" {
  # Fail closed: only 0 means healthy. Anything unrecognised must be loud.
  mk_healer 7
  run_block
  grep -q '^CRITICAL' "$CALLS"
}

@test "an absent healer PAGES — an absent enforcement mechanism is the alarm" {
  # This test previously asserted the opposite ("a no-op, never a false alarm"),
  # which encoded the bug: deleting the healer silently disabled the drift alarm
  # forever, and the missing registration it exists to catch would then persist
  # with no heal and no page. A guard that vanishes quietly is worse than no
  # guard, because the dashboard still looks green.
  rm -f "$TMP/lib/ensure-sentry-mcp.sh"
  run_block
  grep -q '^CRITICAL .*healer is MISSING' "$CALLS"
}

@test "a healer that lost its executable bit also pages" {
  chmod -x "$TMP/lib/ensure-sentry-mcp.sh" 2>/dev/null || true
  run_block
  grep -q '^CRITICAL .*healer is MISSING' "$CALLS"
}

# ──────────────────────────────────────────────────────────────
# Disabled mode (PR #929). The healer's ESM_ENABLED constant defaults to OFF,
# so `--check` returns 3 when the server is still registered, and healing
# REMOVES it. Reusing rc=1 here would make the watchdog heal by deleting while
# its Slack copy says "re-registered" — QA #929 v3 finding 1.
# ──────────────────────────────────────────────────────────────

@test "disabled-but-present (--check 3) that heals: notifies REMOVED, not re-registered" {
  mk_healer 3 0
  run_block
  grep -q '^NOTIFY' "$CALLS"
  run grep '^NOTIFY' "$CALLS"
  [[ "$output" == *"REMOVED"* ]]
  [[ "$output" != *"re-registered"* ]]
  [[ "$output" != *"had vanished"* ]]
}

@test "disabled-but-present (--check 3) names the constant so the fix is findable" {
  mk_healer 3 0
  run_block
  run grep '^NOTIFY' "$CALLS"
  [[ "$output" == *"ESM_ENABLED"* ]]
}

@test "disabled-but-present (--check 3) that CANNOT heal: pages critical" {
  mk_healer 3 1
  run_block
  grep -q '^CRITICAL' "$CALLS"
  run grep '^CRITICAL' "$CALLS"
  [[ "$output" == *"could NOT be removed"* ]]
}

@test "rc=3 is NOT treated as the rc=1 re-register path" {
  # The whole point of the separate code: if 3 ever falls through to the rc=1
  # branch, the operator is told the opposite of what happened.
  mk_healer 3 0
  run_block
  run cat "$CALLS"
  [[ "$output" != *"re-registered it from"* ]]
}
