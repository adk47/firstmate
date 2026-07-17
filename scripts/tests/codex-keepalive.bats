#!/usr/bin/env bats
# Tests for scripts/codex-keepalive.sh — the PROACTIVE codex OAuth expiry
# safety-net pager (pages BEFORE the token lapses; the watchdog only fires AFTER
# the 401 storm; the twice-weekly codex-token-refresh timer does the actual refresh).
# Hermetic: reads a throwaway canonical auth store (openclaw 2026.7.x stripped
# all expiry data from `models status --json`, so the keepalive reads the store
# file we own directly), PATH-shadows `muso` (records would-be Slack pages) and
# `ssh` (see memory/feedback_bats_must_stub_openclaw.md).
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
SCRIPT="$HYDRA_REPO/scripts/codex-keepalive.sh"

setup() {
  TEST_TMPDIR="$(mktemp -d)"
  export TEST_TMPDIR
  # Hermeticity: a real maintenance window (/run/hydra-maintenance) must not
  # disarm this pager during CI (it runs on the live node-8 host). Pin the flag
  # at an absent throwaway path so maintenance_active() reads inactive.
  export HYDRA_MAINTENANCE_FLAG="$TEST_TMPDIR/no-maintenance-window"
  mkdir -p "$TEST_TMPDIR/bin" "$TEST_TMPDIR/state"
  export PAGE_LOG="$TEST_TMPDIR/pages.log"

  # Throwaway canonical store root: the keepalive reads
  # <root>/.openclaw-<profile>/agents/main/agent/auth-profiles.json.
  export CODEX_KEEPALIVE_STORE_ROOT="$TEST_TMPDIR/root"
  STORE_DIR="$TEST_TMPDIR/root/.openclaw-main/agents/main/agent"
  mkdir -p "$STORE_DIR"

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

# Write a canonical store whose soonest codex expiry is N minutes from now.
_set_remaining_min() {
  local exp_a exp_b
  exp_a=$(( ( $(date +%s) + $1 * 60 ) * 1000 ))
  exp_b=$(( exp_a + 86400000 ))   # second profile expires later; min() must win
  cat > "$STORE_DIR/auth-profiles.json" <<JSON
{"profiles":{
  "openai-codex:a@x.com":{"type":"oauth","provider":"openai-codex","access":"A","refresh":"R","expires":$exp_a},
  "openai-codex:b@x.com":{"type":"oauth","provider":"openai-codex","access":"B","refresh":"R","expires":$exp_b}
}}
JSON
}

@test "healthy token (well above warn window) → no page, logs healthy" {
  _set_remaining_min 10080   # 7 days, default WARN_MIN=2880 (2 days)
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
  _set_remaining_min -200   # expired 200 min ago
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ALREADY EXPIRED"* ]]
  [ ! -s "$PAGE_LOG" ]
}

@test "min() across profiles: the SOONEST expiry wins even when listed LAST" {
  # Both aaron accounts stay logged in, so the store carries >1 openai-codex
  # profile; the pager must key on the SOONEST-lapsing one. A regression from
  # min() to first()/.[0] would read the healthy first profile and never page
  # while the second account silently lapsed. Fixture deliberately lists the
  # HEALTHY profile first and the SOON one second so first-vs-min diverge.
  local exp_healthy exp_soon
  exp_healthy=$(( ( $(date +%s) + 10080 * 60 ) * 1000 ))   # 7 days (first)
  exp_soon=$(( ( $(date +%s) + 60 * 60 ) * 1000 ))         # 60 min (last, sooner)
  cat > "$STORE_DIR/auth-profiles.json" <<JSON
{"profiles":{
  "openai-codex:healthy@x.com":{"type":"oauth","provider":"openai-codex","access":"A","refresh":"R","expires":$exp_healthy},
  "openai-codex:soon@x.com":{"type":"oauth","provider":"openai-codex","access":"B","refresh":"R","expires":$exp_soon}
}}
JSON
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"EXPIRING"* ]]   # min() → 60m → pages; first() → 7d → would log healthy
  [ -s "$PAGE_LOG" ]
}

@test "no openai-codex profile in the store → BLIND page (was a silent skip pre-2026.7.1)" {
  # Regression: after the 7.1 upgrade the keepalive logged "no openai-codex auth
  # profile found — skipping" every 15 min for hours while the fleet 401'd —
  # fail-open. Blindness on this box is always breakage and must page.
  printf %s '{"profiles":{"anthropic:tok":{"type":"oauth","expires":99}}}' \
    > "$STORE_DIR/auth-profiles.json"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"BLIND"* ]]
  [ -s "$PAGE_LOG" ]
  grep -q "BLIND" "$PAGE_LOG"
}

@test "canonical store missing/unreadable → BLIND page" {
  # No auth-profiles.json written at all.
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"BLIND"* ]]
  [ -s "$PAGE_LOG" ]
  grep -q "BLIND" "$PAGE_LOG"   # the page that fired is the BLIND page, not some other alert
}

@test "blind page respects its own cooldown (no 15-min page storm)" {
  date +%s > "$TEST_TMPDIR/state/codex-keepalive-main-blind-cooldown"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"within cooldown"* ]]
  [ ! -s "$PAGE_LOG" ]
}

@test "cooldown: a second expiring run within cooldown does not re-page" {
  _set_remaining_min 60
  date +%s > "$TEST_TMPDIR/state/codex-keepalive-main-cooldown"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"within cooldown"* ]]
  [ ! -s "$PAGE_LOG" ]
}
