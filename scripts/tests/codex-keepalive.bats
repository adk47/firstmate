#!/usr/bin/env bats
# Tests for scripts/codex-keepalive.sh — the PROACTIVE codex OAuth expiry
# safety-net pager (pages BEFORE the token lapses; the watchdog only fires AFTER
# the 401 storm; the twice-weekly codex-token-refresh timer does the actual refresh).
# Hermetic: PATH-shadows `openclaw` (emits a canned `models status --json`) and
# `muso` (records would-be Slack pages), and shadows `ssh`
# (see memory/feedback_bats_must_stub_openclaw.md).
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
SCRIPT="$HYDRA_REPO/scripts/codex-keepalive.sh"

setup() {
  TEST_TMPDIR="$(mktemp -d)"
  export TEST_TMPDIR
  mkdir -p "$TEST_TMPDIR/bin" "$TEST_TMPDIR/state"
  export STUB_DIR="$TEST_TMPDIR/state"
  export PAGE_LOG="$TEST_TMPDIR/pages.log"

  # openclaw stub: `models status --json` emits a codex profile whose
  # remainingMs is read from $STUB_DIR/remaining.
  cat > "$TEST_TMPDIR/bin/openclaw" <<'STUB'
#!/bin/bash
if [[ "$*" == *"models status"* ]]; then
  rem="$(cat "$STUB_DIR/remaining" 2>/dev/null || echo 999999999)"
  if [ "${STUB_NO_CODEX:-0}" = "1" ]; then
    echo '{"providers":[{"label":"anthropic:tok (x)","remainingMs":'"$rem"'}]}'
  else
    echo '{"providers":[{"label":"openai-codex:aaron@muso.ai (aaron@muso.ai)","expiresAt":1,"remainingMs":'"$rem"'}]}'
  fi
  exit 0
fi
exit 0
STUB
  chmod +x "$TEST_TMPDIR/bin/openclaw"

  # muso stub: record `slack send` calls so tests can assert a page fired.
  cat > "$TEST_TMPDIR/bin/muso" <<STUB
#!/bin/bash
if [[ "\$*" == *"slack send"* ]]; then echo "\$*" >> "$PAGE_LOG"; fi
exit 0
STUB
  chmod +x "$TEST_TMPDIR/bin/muso"

  cat > "$TEST_TMPDIR/bin/ssh" <<'STUB'
#!/bin/bash
echo "test stub: ssh call refused ($*)" >&2
exit 99
STUB
  chmod +x "$TEST_TMPDIR/bin/ssh"

  PATH="$TEST_TMPDIR/bin:$PATH"
  export PATH

  export MUSO_BIN="$TEST_TMPDIR/bin/muso"
  export MUSO_SLACK_BOT_TOKEN_DEVOPS="xoxb-test"
  export MUSO_SLACK_ENV_FILE=/dev/null
  export KEEPALIVE_STATE_DIR="$TEST_TMPDIR/state"
  export CODEX_KEEPALIVE_COOLDOWN_MIN=60
}

teardown() { rm -rf "$TEST_TMPDIR"; }

_set_remaining_min() { echo "$(( $1 * 60000 ))" > "$STUB_DIR/remaining"; }

@test "healthy token (well above warn window) → no page, logs healthy" {
  _set_remaining_min 10080   # 7 days, default WARN_MIN=4320 (3 days)
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"healthy"* ]]
  [ ! -s "$PAGE_LOG" ]
}

@test "expiring token (< warn window) → pages #clio_devops pre-emptively" {
  _set_remaining_min 60
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"EXPIRING"* ]]
  [ -s "$PAGE_LOG" ]
  grep -q "slack send" "$PAGE_LOG"
}

@test "steady-state trough (3 days, above the 2-day warn) → no false page" {
  # The whole point of WARN_MIN=2880: the twice-weekly refresh keeps the token at
  # ~6.5d, and even a single missed run only dips to ~3d — which must NOT page.
  _set_remaining_min 4320   # 3 days
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"healthy"* ]]
  [ ! -s "$PAGE_LOG" ]
}

@test "page text points at the refresh helper, not the broken device-code login" {
  _set_remaining_min 60
  run "$SCRIPT"
  grep -q "codex-oauth-refresh.sh" "$PAGE_LOG"
  ! grep -q "auth login --provider openai-codex" "$PAGE_LOG"
}

@test "already-expired token → NO page (reactive watchdog owns it)" {
  echo "-12000000" > "$STUB_DIR/remaining"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ALREADY EXPIRED"* ]]
  [ ! -s "$PAGE_LOG" ]
}

@test "no openai-codex profile configured → skip, no page" {
  export STUB_NO_CODEX=1
  _set_remaining_min 60
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"no openai-codex auth profile"* ]]
  [ ! -s "$PAGE_LOG" ]
}

@test "cooldown: a second expiring run within cooldown does not re-page" {
  _set_remaining_min 60
  date +%s > "$STUB_DIR/codex-keepalive-main-cooldown"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"within cooldown"* ]]
  [ ! -s "$PAGE_LOG" ]
}
