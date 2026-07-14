#!/usr/bin/env bats
# Tests for scripts/lib/gateway-restart.sh — the drain-aware gateway restart lib.
#
# Contract under test (see the lib header for the full rationale):
#   drain_restart_gateway <service> <profile>
#     1. captures the pre-request MainPID
#     2. requests `openclaw --profile <p> gateway restart --safe --json`
#        (bounded by `timeout`; rc 0 and rc 124 both mean "request in flight")
#     3. polls until MainPID changes (gateway self-restarted via SIGUSR1
#        exit(0) + systemd Restart=always)
#     4. on ANY safe-path failure falls back LOUDLY to `systemctl restart`
#        (today's behavior — deploys must always converge)
#
# Hermetic per repo doctrine: openclaw + systemctl are stubbed via the lib's
# env seams (OPENCLAW_BIN / SYSTEMCTL_BIN); nothing touches real services.
# The systemctl stub serves scripted MainPID answers from a pop-queue file so
# tests can simulate "PID changes on Nth poll".
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"

setup() {
  TEST_TMPDIR="$(mktemp -d)"; export TEST_TMPDIR
  mkdir -p "$TEST_TMPDIR/bin"
  export SYSCTL_LOG="$TEST_TMPDIR/systemctl.log"
  export OPENCLAW_LOG="$TEST_TMPDIR/openclaw.log"
  export PID_SEQ_FILE="$TEST_TMPDIR/pid-seq"

  # Stub openclaw: records argv, emits a realistic --json payload, exit code
  # and stall duration switchable per test.
  cat > "$TEST_TMPDIR/bin/openclaw" <<'STUB'
#!/bin/bash
echo "$*" >> "$OPENCLAW_LOG"
sleep "${OPENCLAW_STALL:-0}"
echo '{"ok":true,"result":"deferred","message":"safe restart requested"}'
exit "${OPENCLAW_RC:-0}"
STUB
  chmod +x "$TEST_TMPDIR/bin/openclaw"
  export OPENCLAW_BIN="$TEST_TMPDIR/bin/openclaw"

  # Stub systemctl: records every invocation; `show -p MainPID` pops the next
  # line off PID_SEQ_FILE (repeating the last line once the queue drains) so a
  # test scripts the PID's evolution across polls; is-active / is-failed /
  # restart exit codes come from env.
  cat > "$TEST_TMPDIR/bin/systemctl" <<'STUB'
#!/bin/bash
echo "$*" >> "$SYSCTL_LOG"
case "$1" in
  show)
    pid="$(head -n1 "$PID_SEQ_FILE")"
    if [ "$(wc -l < "$PID_SEQ_FILE")" -gt 1 ]; then
      tail -n +2 "$PID_SEQ_FILE" > "$PID_SEQ_FILE.tmp" && mv "$PID_SEQ_FILE.tmp" "$PID_SEQ_FILE"
    fi
    echo "$pid"
    ;;
  is-active)     exit "${IS_ACTIVE_RC:-0}" ;;
  is-failed)     exit "${IS_FAILED_RC:-1}" ;;
  restart)       exit "${RESTART_RC:-0}" ;;
  reset-failed)  exit 0 ;;
esac
exit 0
STUB
  chmod +x "$TEST_TMPDIR/bin/systemctl"
  export SYSTEMCTL_BIN="$TEST_TMPDIR/bin/systemctl"

  # Fast loops for tests.
  export GATEWAY_DRAIN_DEADLINE_SECS=2
  export GATEWAY_DRAIN_POLL_SECS=1
  export GATEWAY_SAFE_REQUEST_TIMEOUT_SECS=1
  export GATEWAY_HARD_POLL_TRIES=2
  export GATEWAY_HARD_POLL_SECS=1
  unset HYDRA_HARD_RESTART OPENCLAW_RC OPENCLAW_STALL IS_ACTIVE_RC IS_FAILED_RC RESTART_RC

  # shellcheck source=../lib/gateway-restart.sh
  source "$HYDRA_REPO/scripts/lib/gateway-restart.sh"
}
teardown() { rm -rf "$TEST_TMPDIR"; }

pid_seq() { printf '%s\n' "$@" > "$PID_SEQ_FILE"; }
# grep -c prints the count even on zero matches (rc 1) — swallow only the rc.
restarts_recorded() {
  if [ -f "$SYSCTL_LOG" ]; then grep -c '^restart ' "$SYSCTL_LOG" || true; else echo 0; fi
}

@test "happy path: safe request accepted, PID changes on 2nd poll → no hard restart" {
  pid_seq 111 111 222   # capture, poll1 (unchanged), poll2 (new)
  run drain_restart_gateway gw-main main
  [ "$status" -eq 0 ]
  [ "$(restarts_recorded)" -eq 0 ]
  grep -q -- "--profile main gateway restart --safe --json" "$OPENCLAW_LOG"
}

@test "instant-restart race: PID already new on first poll → success" {
  pid_seq 111 222
  run drain_restart_gateway gw-main main
  [ "$status" -eq 0 ]
  [ "$(restarts_recorded)" -eq 0 ]
}

@test "blocking CLI killed by timeout (rc 124) → still polls, no fallback" {
  export OPENCLAW_STALL=3   # > GATEWAY_SAFE_REQUEST_TIMEOUT_SECS=1 → rc 124
  pid_seq 111 222
  run drain_restart_gateway gw-main main
  [ "$status" -eq 0 ]
  [ "$(restarts_recorded)" -eq 0 ]
}

@test "gateway unreachable (CLI rc 1) → immediate hard-restart fallback" {
  export OPENCLAW_RC=1
  pid_seq 111 222
  run drain_restart_gateway gw-main main
  [ "$status" -eq 0 ]
  [ "$(restarts_recorded)" -eq 1 ]
  [[ "$output" == *"falling back"* ]]
}

@test "drain deadline expiry (PID never changes) → WARN + hard-restart fallback" {
  pid_seq 111   # repeats forever
  run drain_restart_gateway gw-main main
  [ "$status" -eq 0 ]
  [ "$(restarts_recorded)" -eq 1 ]
  [[ "$output" == *"WARN"* ]]
}

@test "fallback hard restart itself fails → nonzero" {
  export OPENCLAW_RC=1 RESTART_RC=1
  pid_seq 111
  run drain_restart_gateway gw-main main
  [ "$status" -ne 0 ]
}

@test "fallback restart ok but service never active → nonzero (bounded poll)" {
  export OPENCLAW_RC=1 IS_ACTIVE_RC=3
  pid_seq 111
  run drain_restart_gateway gw-main main
  [ "$status" -ne 0 ]
}

@test "HYDRA_HARD_RESTART=1 → zero openclaw calls, straight systemctl restart" {
  export HYDRA_HARD_RESTART=1
  pid_seq 111
  run drain_restart_gateway gw-main main
  [ "$status" -eq 0 ]
  [ ! -s "$OPENCLAW_LOG" ]
  [ "$(restarts_recorded)" -eq 1 ]
}

@test "is-failed mid-poll (StartLimitBurst trip) → reset-failed + fallback" {
  export IS_FAILED_RC=0
  pid_seq 111 111
  run drain_restart_gateway gw-main main
  [ "$status" -eq 0 ]
  grep -q '^reset-failed ' "$SYSCTL_LOG"
  [ "$(restarts_recorded)" -eq 1 ]
}

@test "fallback pages via GATEWAY_FALLBACK_NOTIFY_FN; happy drain and HARD hatch do not" {
  NOTIFY_LOG="$TEST_TMPDIR/notify.log"; export NOTIFY_LOG
  record_notify() { echo "$1" >> "$NOTIFY_LOG"; }
  export GATEWAY_FALLBACK_NOTIFY_FN=record_notify

  # Happy drain → no page.
  pid_seq 111 222
  run drain_restart_gateway gw-main main
  [ "$status" -eq 0 ]
  [ ! -s "$NOTIFY_LOG" ]

  # Request failure → fallback → page.
  export OPENCLAW_RC=1
  pid_seq 111
  run drain_restart_gateway gw-main main
  [ "$status" -eq 0 ]
  grep -q "safe-restart request FAILED for gw-main" "$NOTIFY_LOG"

  # Explicit hard hatch → intentional, no page.
  : > "$NOTIFY_LOG"
  export HYDRA_HARD_RESTART=1 OPENCLAW_RC=0
  pid_seq 111
  drain_restart_gateway gw-main main
  [ ! -s "$NOTIFY_LOG" ]
}

@test "empty pre-request PID fails CLOSED: no drain request, hard restart + page" {
  NOTIFY_LOG="$TEST_TMPDIR/notify.log"; export NOTIFY_LOG
  record_notify() { echo "$1" >> "$NOTIFY_LOG"; }
  export GATEWAY_FALLBACK_NOTIFY_FN=record_notify
  # Empty MainPID at capture time (transient ssh/systemctl failure). The old
  # gateway (pid 111) keeps running — before the fix, `pid != ""` made await
  # report the STILL-RUNNING old process as a successful restart.
  pid_seq "" 111 111
  run drain_restart_gateway gw-main main
  [ "$status" -eq 0 ]
  [ ! -s "$OPENCLAW_LOG" ]                 # no unverifiable safe request issued
  [ "$(restarts_recorded)" -eq 1 ]         # hard restart, not false drain success
  grep -q "could not capture a pre-request MainPID" "$NOTIFY_LOG"
}

@test "await_gateway_restart fails closed on empty/zero old_pid (no poll-loop false positive)" {
  pid_seq 111 111
  run await_gateway_restart gw-main ""
  [ "$status" -eq 1 ]
  [[ "$output" == *"failing closed"* ]]
  run await_gateway_restart gw-main 0
  [ "$status" -eq 1 ]
}

@test "exec seam: every command routes through GATEWAY_EXEC_FN as ONE remotable string" {
  EXEC_RECORD="$TEST_TMPDIR/exec.log"; export EXEC_RECORD
  record_exec() { echo "$1" >> "$EXEC_RECORD"; bash -c "$1"; }
  export GATEWAY_EXEC_FN=record_exec
  pid_seq 111 222
  run drain_restart_gateway gw-main main
  [ "$status" -eq 0 ]
  # The safe-restart request must be a single string (ssh-remotable), carrying
  # the timeout guard and the full openclaw invocation.
  grep -qE "^timeout --kill-after=5 1 .*openclaw --profile main gateway restart --safe --json$" "$EXEC_RECORD"
  # Probes route through the seam too (the old deploy.sh bug polled locally in ssh mode).
  grep -q "show -p MainPID --value gw-main" "$EXEC_RECORD"
}
