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

  # Stub systemctl: record restart invocations.
  cat > "$TEST_TMPDIR/bin/systemctl" <<STUB
#!/bin/bash
echo "\$*" >> "$RESTART_LOG"
exit 0
STUB
  chmod +x "$TEST_TMPDIR/bin/systemctl"
  export SYSTEMCTL_BIN="$TEST_TMPDIR/bin/systemctl"
  export CODEX_GATEWAY_SERVICES="gw-main gw-edge"
}
teardown() { rm -rf "$TEST_TMPDIR"; }

@test "refresh success → restarts the gateways, exit 0" {
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ -s "$RESTART_LOG" ]
  grep -q "restart gw-main gw-edge" "$RESTART_LOG"
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
