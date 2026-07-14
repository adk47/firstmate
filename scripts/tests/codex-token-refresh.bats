#!/usr/bin/env bats
# Tests for scripts/codex-token-refresh.sh — the twice-weekly-timer wrapper that
# refreshes the codex OAuth token and restarts the gateways ONLY on success.
# Hermetic: stubs the refresh helper (success/fail switchable) and systemctl,
# recording whether a restart was issued.
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
SCRIPT="$HYDRA_REPO/scripts/codex-token-refresh.sh"

setup() {
  TEST_TMPDIR="$(mktemp -d)"; export TEST_TMPDIR
  mkdir -p "$TEST_TMPDIR/bin"
  export RESTART_LOG="$TEST_TMPDIR/restart.log"

  # Stub refresh helper: exit code from $REFRESH_RC (default 0 = success).
  cat > "$TEST_TMPDIR/refresh.sh" <<STUB
#!/bin/bash
echo "stub refresh ran"
exit \${REFRESH_RC:-0}
STUB
  chmod +x "$TEST_TMPDIR/refresh.sh"
  export CODEX_REFRESH_BIN="$TEST_TMPDIR/refresh.sh"

  # Stub systemctl: record restart invocations. `show` must answer with a PID —
  # the drain lib fails closed (skips the safe request) without a verified
  # pre-request MainPID.
  cat > "$TEST_TMPDIR/bin/systemctl" <<STUB
#!/bin/bash
echo "\$*" >> "$RESTART_LOG"
[ "\$1" = "show" ] && echo 111
exit 0
STUB
  chmod +x "$TEST_TMPDIR/bin/systemctl"
  export SYSTEMCTL_BIN="$TEST_TMPDIR/bin/systemctl"
  export CODEX_GATEWAY_SERVICES="gw-main gw-edge"

  # Stub openclaw (the drain-aware restart lib's safe-restart request). MUST be
  # stubbed — tests can run on node-8 where a real openclaw would otherwise
  # receive a real restart request. Default rc=1 = "gateway unreachable", so
  # these tests exercise the wiring via the hard-restart fallback; drain
  # semantics themselves are covered by gateway-restart.bats.
  export OPENCLAW_LOG="$TEST_TMPDIR/openclaw.log"
  cat > "$TEST_TMPDIR/bin/openclaw" <<'STUB'
#!/bin/bash
echo "$*" >> "$OPENCLAW_LOG"
exit "${OPENCLAW_RC:-1}"
STUB
  chmod +x "$TEST_TMPDIR/bin/openclaw"
  export OPENCLAW_BIN="$TEST_TMPDIR/bin/openclaw"

  # Fast lib loops.
  export GATEWAY_HARD_POLL_TRIES=1 GATEWAY_HARD_POLL_SECS=0
  export GATEWAY_DRAIN_DEADLINE_SECS=1 GATEWAY_DRAIN_POLL_SECS=1

  # Capture fallback pages via the lib's notify seam (a recorder executable —
  # the seam accepts any command name). Also stub MUSO_BIN so the real
  # slack-notify path can never post from a test box.
  export NOTIFY_LOG="$TEST_TMPDIR/notify.log"
  cat > "$TEST_TMPDIR/bin/notify-recorder" <<'STUB'
#!/bin/bash
echo "$1" >> "$NOTIFY_LOG"
STUB
  chmod +x "$TEST_TMPDIR/bin/notify-recorder"
  export GATEWAY_FALLBACK_NOTIFY_FN="$TEST_TMPDIR/bin/notify-recorder"
  export MUSO_BIN=/bin/true
}
teardown() { rm -rf "$TEST_TMPDIR"; }

@test "refresh success → drain requested, then restarts BOTH gateways, exit 0" {
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ -s "$RESTART_LOG" ]
  # Per-service drain-aware restarts (profile derived from the unit name).
  grep -q "restart gw-main" "$RESTART_LOG"
  grep -q "restart gw-edge" "$RESTART_LOG"
  # The safe-restart request was attempted before the fallback.
  grep -q -- "--profile main gateway restart --safe --json" "$OPENCLAW_LOG"
  grep -q -- "--profile edge gateway restart --safe --json" "$OPENCLAW_LOG"
  # Every hard fallback pages (per-service) — a broken safe path here exits 0,
  # so the page is the ONLY out-of-band signal.
  grep -q "safe-restart request FAILED for gw-main" "$NOTIFY_LOG"
  grep -q "safe-restart request FAILED for gw-edge" "$NOTIFY_LOG"
}

@test "refresh failure → does NOT restart, propagates non-zero exit" {
  export REFRESH_RC=1
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [ ! -s "$RESTART_LOG" ]
  [[ "$output" == *"NOT restarting"* ]]
}

@test "missing refresh helper → FATAL, exit 2, no restart" {
  export CODEX_REFRESH_BIN="$TEST_TMPDIR/does-not-exist.sh"
  run "$SCRIPT"
  [ "$status" -eq 2 ]
  [ ! -s "$RESTART_LOG" ]
}

@test "refresh OK but restart fails → fail loud (exit 1), token already persisted" {
  # systemctl stub that fails the restart.
  cat > "$TEST_TMPDIR/bin/systemctl" <<STUB
#!/bin/bash
echo "\$*" >> "$RESTART_LOG"
exit 1
STUB
  chmod +x "$TEST_TMPDIR/bin/systemctl"
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"gateway restart FAILED"* ]]
}
