#!/usr/bin/env bats
#
# scripts/openclaw-watchdog.sh — the /dev/null char-device page (MUS-6775).
#
# The block is EXTRACTED FROM THE REAL SCRIPT (same idiom as
# openclaw-watchdog-sentry-mcp.bats) so deleting the page turns this red.
# It PAGES and never repairs. DEVNULL_PATH is the test seam; the real
# /dev/null is never touched.
bats_require_minimum_version 1.5.0

WATCHDOG="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)/scripts/openclaw-watchdog.sh"

setup() {
  TMP="$BATS_TEST_TMPDIR/c"; mkdir -p "$TMP"
  export CALLS="$TMP/calls.log"; : > "$CALLS"
  export WATCHDOG_STATE_DIR="$TMP"
  BLOCK="$TMP/block.sh"
  awk '/^# ── \/dev\/null char-device guard/,/^fi$/' "$WATCHDOG" > "$BLOCK"
  [ -s "$BLOCK" ] || { echo "extraction produced nothing — did the section banner change?" >&2; return 1; }
  grep -q 'char device' "$BLOCK" || { echo "extracted block lacks the alert text" >&2; return 1; }
}

run_block() {
  run bash -c '
    log() { printf "LOG %s\n" "$*" >> "$CALLS"; }
    slack_notify() { printf "NOTIFY %s\n" "$*" >> "$CALLS"; }
    slack_notify_critical() { printf "CRITICAL %s\n" "$*" >> "$CALLS"; }
    CODEX_COOLDOWN_MIN=60
    _sane_epoch() { printf "%s" "$1"; }
    _codex_cooldown_ok() {
      local f="$1" mins="$2" last now
      [ -f "$f" ] || return 0
      last=$(cat "$f"); now=$(date +%s)
      [ "$(( (now - last) / 60 ))" -ge "$mins" ]
    }
    . "$1"' _ "$BLOCK"
}

@test "char device present: no alert" {
  DEVNULL_PATH=/dev/zero run_block
  [ ! -s "$CALLS" ]
}

@test "regular file: exactly one critical alert naming char device" {
  touch "$TMP/null"
  DEVNULL_PATH="$TMP/null" run_block
  [ "$(grep -c '^CRITICAL' "$CALLS")" -eq 1 ]
  grep -q '^CRITICAL .*char device' "$CALLS"
  grep -q 'MUS-6760' "$CALLS"
}

@test "absent path: exactly one critical alert" {
  DEVNULL_PATH="$TMP/missing" run_block
  [ "$(grep -c '^CRITICAL' "$CALLS")" -eq 1 ]
  grep -q '^CRITICAL .*char device' "$CALLS"
}

@test "cooldown: a second tick inside the window does not page again" {
  touch "$TMP/null"
  DEVNULL_PATH="$TMP/null" run_block
  DEVNULL_PATH="$TMP/null" run_block
  [ "$(grep -c '^CRITICAL' "$CALLS")" -eq 1 ]
}

@test "never repairs: the regular file is left as is" {
  touch "$TMP/null"
  DEVNULL_PATH="$TMP/null" run_block
  [ -f "$TMP/null" ] && [ ! -c "$TMP/null" ]
}
