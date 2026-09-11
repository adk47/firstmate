#!/usr/bin/env bats
# scripts/notify-unit-failed.sh — the OnFailure= target for hydra oneshot units
# (hydra-unit-failed@.service). journalctl, systemctl and the muso Slack CLI are
# stubbed on PATH; delivery runs through the REAL lib/deploy-notify.sh so the
# status-returning contract is what is under test. Nothing here can reach a
# real unit or Slack.
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
SCRIPT="$HYDRA_REPO/scripts/notify-unit-failed.sh"

setup() {
  TEST_TMPDIR="$(mktemp -d)"; export TEST_TMPDIR
  mkdir -p "$TEST_TMPDIR/bin"
  export PAGE_LOG="$TEST_TMPDIR/pages.log"
  export NOTIFY_UNIT_FAILED_MARKER_DIR="$TEST_TMPDIR/markers"
  export HYDRA_SELF_PAGED_DIR="$TEST_TMPDIR/self-paged"
  cat > "$TEST_TMPDIR/bin/muso" <<STUB
#!/bin/bash
if [[ "\$*" == *"slack send"* ]]; then echo "\$*" >> "$PAGE_LOG"; fi
exit "\${STUB_MUSO_RC:-0}"
STUB
  cat > "$TEST_TMPDIR/bin/journalctl" <<'STUB'
#!/bin/bash
printf 'line one for %s\nfatal: node not found\n' "$2"
STUB
  cat > "$TEST_TMPDIR/bin/systemctl" <<'STUB'
#!/bin/bash
echo "exit-code"
STUB
  chmod +x "$TEST_TMPDIR/bin/"*
  PATH="$TEST_TMPDIR/bin:$PATH"; export PATH
  # Hermeticity: CI runs on a credentialed host where the bot token is already
  # EXPORTED, and slack_load_env honours that before reading the env file — so
  # the missing-token test only covers its path if the inherited var is gone.
  unset MUSO_SLACK_BOT_TOKEN_DEVOPS
  export MUSO_BIN="$TEST_TMPDIR/bin/muso"
  export MUSO_SLACK_ENV_FILE="$TEST_TMPDIR/slack.env"
  printf 'MUSO_SLACK_BOT_TOKEN_DEVOPS=xoxb-test\n' > "$MUSO_SLACK_ENV_FILE"
}
teardown() { rm -rf "$TEST_TMPDIR"; }

@test "pages CRITICAL (real mentions) with the unit name, Result and journal tail; exits 0; no marker" {
  run "$SCRIPT" codex-edge-mirror.service
  [ "$status" -eq 0 ]
  page="$(cat "$PAGE_LOG")"
  [[ "$page" == *"<@U"* ]]
  [[ "$page" == *"systemd unit FAILED"* ]]
  [[ "$page" == *"codex-edge-mirror.service"* ]]
  [[ "$page" == *"Result=exit-code"* ]]
  [[ "$page" == *"fatal: node not found"* ]]
  [ ! -d "$NOTIFY_UNIT_FAILED_MARKER_DIR" ]
}

@test "a REJECTED Slack delivery is surfaced: exit non-zero, journal line, marker file naming the unit" {
  STUB_MUSO_RC=1 run "$SCRIPT" codex-edge-mirror.service
  [ "$status" -ne 0 ]
  [[ "$output" == *"PAGE NOT DELIVERED for codex-edge-mirror.service"* ]]
  [[ "$output" == *"UNALERTED"* ]]
  marker="$(ls "$NOTIFY_UNIT_FAILED_MARKER_DIR"/codex-edge-mirror.service.*.unpaged | head -1)"
  [ -s "$marker" ]
  [[ "$(basename "$marker")" =~ ^codex-edge-mirror\.service\.[0-9]+\.[0-9]+\.unpaged$ ]]   # one record per spool file, renamed into place
  [ "$(grep -c . "$marker")" -eq 1 ]
  [[ "$(cat "$marker")" == *"codex-edge-mirror.service"*"deploy-notify.sh exited 1"* ]]
  run ls "$NOTIFY_UNIT_FAILED_MARKER_DIR"
  [[ "$output" != *".tmp"* ]]
}

@test "a MISSING token is a failed delivery too (deploy-notify returns non-zero), not a silent 0" {
  rm -f "$MUSO_SLACK_ENV_FILE"
  run "$SCRIPT" codex-edge-mirror.service
  [ "$status" -ne 0 ]
  [ -n "$(ls "$NOTIFY_UNIT_FAILED_MARKER_DIR"/codex-edge-mirror.service.*.unpaged 2>/dev/null)" ]
  [ ! -f "$PAGE_LOG" ]
}

@test "a missing deploy-notify.sh leaves the trace and exits non-zero" {
  DEPLOY_NOTIFY_BIN="$TEST_TMPDIR/nope.sh" run "$SCRIPT" codex-edge-mirror.service
  [ "$status" -ne 0 ]
  [ -n "$(ls "$NOTIFY_UNIT_FAILED_MARKER_DIR"/codex-edge-mirror.service.*.unpaged 2>/dev/null)" ]
}

@test "no unit argument is a usage error" {
  run "$SCRIPT"
  [ "$status" -eq 2 ]
}

# ── one pager per failure (OnFailure= handler vs the script's own page) ──────

@test "self-paged: a FRESH stamp from the unit's own script → the handler skips (no second page, exit 0)" {
  mkdir -p "$HYDRA_SELF_PAGED_DIR"; date -u +%s > "$HYDRA_SELF_PAGED_DIR/codex-edge-mirror.service"
  run "$SCRIPT" codex-edge-mirror.service
  [ "$status" -eq 0 ]
  [[ "$output" == *"paged for its own failure"*"not paging it a second time"* ]]
  [ ! -f "$PAGE_LOG" ]
}

@test "self-paged: a STALE stamp (older than the window) does not suppress the handler" {
  mkdir -p "$HYDRA_SELF_PAGED_DIR"; printf '%s' "$(( $(date -u +%s) - 600 ))" > "$HYDRA_SELF_PAGED_DIR/codex-edge-mirror.service"
  run "$SCRIPT" codex-edge-mirror.service
  [ "$status" -eq 0 ]
  [[ "$(cat "$PAGE_LOG")" == *"systemd unit FAILED"* ]]
}

@test "end-to-end single page: the REAL mirror fails under --restart (pages + stamps), then the OnFailure handler runs → exactly ONE page" {
  # the real mirror, real deploy-notify, muso stubbed: a structural failure (edge store absent)
  export CODEX_AUTH_ROOT="$TEST_TMPDIR/root"; mkdir -p "$CODEX_AUTH_ROOT/.openclaw-main/state" "$CODEX_AUTH_ROOT/.openclaw-edge/state"
  cat > "$TEST_TMPDIR/bin/openclaw" <<'STUB'
#!/bin/bash
[ "$1" = "--version" ] && { echo "OpenClaw 2026.8.2 (test)"; exit 0; }; exit 0
STUB
  chmod +x "$TEST_TMPDIR/bin/openclaw"
  export CODEX_MIRROR_STATE_DIR="$TEST_TMPDIR/mirror-state" HYDRA_MAINTENANCE_FLAG="$TEST_TMPDIR/no-window"
  printf '#!/bin/bash\ndrain_restart_gateway() { return 0; }\n' > "$TEST_TMPDIR/restart-stub.sh"; export CODEX_MIRROR_RESTART_LIB="$TEST_TMPDIR/restart-stub.sh"
  run "$HYDRA_REPO/scripts/lib/codex-edge-mirror.sh" --restart
  [ "$status" -eq 2 ]
  [ "$(grep -c . "$PAGE_LOG")" -eq 1 ]
  [ -s "$HYDRA_SELF_PAGED_DIR/codex-edge-mirror.service" ]
  # systemd now runs OnFailure=hydra-unit-failed@codex-edge-mirror.service
  run "$SCRIPT" codex-edge-mirror.service
  [ "$status" -eq 0 ]
  [ "$(grep -c . "$PAGE_LOG")" -eq 1 ]
}

@test "end-to-end fallback: the REAL mirror fails under --restart with delivery AND spool both failing → no stamp → the OnFailure handler DOES page" {
  export CODEX_AUTH_ROOT="$TEST_TMPDIR/root"; mkdir -p "$CODEX_AUTH_ROOT/.openclaw-main/state" "$CODEX_AUTH_ROOT/.openclaw-edge/state"
  cat > "$TEST_TMPDIR/bin/openclaw" <<'STUB'
#!/bin/bash
[ "$1" = "--version" ] && { echo "OpenClaw 2026.8.2 (test)"; exit 0; }; exit 0
STUB
  chmod +x "$TEST_TMPDIR/bin/openclaw"
  export CODEX_MIRROR_STATE_DIR="$TEST_TMPDIR/mirror-state" HYDRA_MAINTENANCE_FLAG="$TEST_TMPDIR/no-window"
  printf '#!/bin/bash\ndrain_restart_gateway() { return 0; }\n' > "$TEST_TMPDIR/restart-stub.sh"; export CODEX_MIRROR_RESTART_LIB="$TEST_TMPDIR/restart-stub.sh"
  : > "$NOTIFY_UNIT_FAILED_MARKER_DIR"          # spool unwritable (a file in its place)
  STUB_MUSO_RC=1 run "$HYDRA_REPO/scripts/lib/codex-edge-mirror.sh" --restart   # delivery fails too
  [ "$status" -eq 2 ]
  [ ! -e "$HYDRA_SELF_PAGED_DIR/codex-edge-mirror.service" ]
  rm -f "$PAGE_LOG"; rm -f "$NOTIFY_UNIT_FAILED_MARKER_DIR"
  # systemd now runs OnFailure=hydra-unit-failed@codex-edge-mirror.service, and Slack is back
  run "$SCRIPT" codex-edge-mirror.service
  [ "$status" -eq 0 ]
  [[ "$(cat "$PAGE_LOG")" == *"systemd unit FAILED"*"codex-edge-mirror.service"* ]]
}
