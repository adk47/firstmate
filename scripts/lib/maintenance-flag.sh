#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────
# maintenance-flag.sh — sourced guard: is a planned maintenance window active?
#
# WHY: the fleet's autonomic self-healing fights planned maintenance. When the
# gateways are stopped for a window (openclaw bump, state surgery, Node upgrade),
# openclaw-watchdog.sh restarts them mid-archive, codex-token-refresh restarts
# them to load a token, and the alert-only watchdogs page the whole fleet's
# alarms for a fleet that is DOWN ON PURPOSE. Before this flag the operator had
# to hand-move ~10 cron files and stop timers per window (and got it wrong twice
# on the 2026-07 7.1 window — the corrupted first state archive was a direct
# consequence). Now every autonomic fleet-health watchdog sources this and stands
# down while a window is open.
#
# The single flag file is written by scripts/hydra-maintenance.sh (start/stop).
#
# FAIL-SAFE BY CONSTRUCTION — the readers, not a background job, enforce the TTL:
#   - absent flag              -> NOT active (normal operation)
#   - unreadable / malformed   -> NOT active (a broken flag never disarms the fleet)
#   - missing/non-numeric expiry-> NOT active
#   - expired (now >= expires) -> NOT active  (a forgotten `stop` re-arms ALL
#                                 protection automatically once the TTL passes)
# So there is no state in which a bad or stale flag leaves the fleet permanently
# unguarded; the worst case is a bounded blind window the operator asked for. And
# /run is tmpfs, so a reboot clears the flag too. Modeled on the fail-open shape
# of lib/edge-restart-gate.sh: pure logic, no side effects at source time, and
# nothing here may trip `set -e` in the sourcing watchdog.
#
# Usage (in a watchdog, right after it sources lib/slack-notify.sh):
#   source "$_WATCHDOG_DIR/lib/maintenance-flag.sh"
#   if maintenance_active; then
#     echo "$LOGPREFIX maintenance: $(maintenance_reason) - skipping"; exit 0
#   fi
#
# Env knobs:
#   HYDRA_MAINTENANCE_FLAG   flag file path (default /run/hydra-maintenance).
#                            Env-overridable exactly like every *_LOCKFILE in the
#                            fleet so the bats suites point it at a throwaway path.
# ──────────────────────────────────────────────────────────────

: "${HYDRA_MAINTENANCE_FLAG:=/run/hydra-maintenance}"

# maintenance_active: return 0 iff a maintenance window is currently active
# (flag present, valid JSON, numeric expires_epoch, and now < expires_epoch).
# Every failure path returns 1 (NOT active) — see the FAIL-SAFE note above.
maintenance_active() {
  local flag="${HYDRA_MAINTENANCE_FLAG:-/run/hydra-maintenance}"
  [ -f "$flag" ] || return 1
  local exp now
  exp=$(jq -r '.expires_epoch // empty' "$flag" 2>/dev/null) || return 1
  case "$exp" in
    ''|*[!0-9]*) return 1 ;;   # empty or non-integer expiry -> malformed -> not active
  esac
  now=$(date -u +%s 2>/dev/null) || return 1
  [ "$now" -lt "$exp" ]        # unexpired -> 0 (active); expired -> 1 (armed)
}

# maintenance_reason: echo the window's reason for a skip log line. Empty on any
# error (never fails the caller).
maintenance_reason() {
  local flag="${HYDRA_MAINTENANCE_FLAG:-/run/hydra-maintenance}"
  [ -f "$flag" ] || return 0
  jq -r '.reason // empty' "$flag" 2>/dev/null || true
}
