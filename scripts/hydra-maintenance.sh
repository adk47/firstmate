#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────
# hydra-maintenance.sh — open/close a planned maintenance window for the fleet.
#
# WHY: stopping the gateways for a window used to mean hand-moving ~10 cron files
# and stopping timers, because the autonomic watchdogs (openclaw-watchdog,
# codex-{keepalive,token-refresh}, peer-labels, stuck-lane, cron-health,
# fallback-swallow, rag-index) restart the fleet or page the fleet's alarms the
# moment it goes down. This one command drops a single flag file that every
# fleet-health watchdog honors (via lib/maintenance-flag.sh), so a window is
# `start` … do the work … `stop` instead of the cron-file shuffle.
#
# FAIL-SAFE: the flag carries a TTL enforced by the READERS — an expired flag is
# ignored, so a forgotten `stop` re-arms all protection automatically once the
# TTL passes. /run is tmpfs, so a reboot clears it too. This command NEVER stops
# a service itself (the operator still stops gateways explicitly) and never
# touches systemd Restart=always (crash-recovery is wanted mid-window). It only
# suppresses the autonomic watchdogs' restart/page actions.
#
# Business/prod watchdogs (prod-log-alert, ads-inquiry, merge-landing,
# stale-ticket, the systemic data-complaint pipeline) deliberately do NOT honor
# the flag: a fleet window must not blind you to a real Muso prod incident or a
# sales lead. See scripts/tests/fixtures/maintenance-guard-exempt.txt.
#
# Usage:
#   hydra-maintenance start "<reason>" [--ttl 2h] [--operator <who>]
#   hydra-maintenance stop
#   hydra-maintenance status
#   hydra-maintenance is-active        # no output; exit 0 iff a window is active
#
# start/stop post a one-liner to #clio_devops (best-effort) so a window is always
# visible to humans. The local flag file is the source of truth; a failed Slack
# post never blocks the flag write.
#
# Env knobs:
#   HYDRA_MAINTENANCE_FLAG          flag path (default /run/hydra-maintenance)
#   HYDRA_MAINTENANCE_DEFAULT_TTL   default --ttl (default 2h)
# ──────────────────────────────────────────────────────────────
set -euo pipefail

_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/maintenance-flag.sh
source "$_DIR/lib/maintenance-flag.sh"
# Best-effort Slack (never fails the caller; the flag write is the source of truth).
if [ -r "$_DIR/lib/slack-notify.sh" ]; then
  # shellcheck source=lib/slack-notify.sh
  source "$_DIR/lib/slack-notify.sh"
fi

: "${HYDRA_MAINTENANCE_FLAG:=/run/hydra-maintenance}"
DEFAULT_TTL="${HYDRA_MAINTENANCE_DEFAULT_TTL:-2h}"
PROG="$(basename "$0")"

log()    { echo "[$PROG] $*"; }
die()    { echo "[$PROG] error: $1" >&2; exit "${2:-2}"; }
notify() { declare -F slack_notify >/dev/null && slack_notify "$1" || true; }

usage() {
  cat <<EOF
Usage: $PROG <start|stop|status|is-active> ...
  start "<reason>" [--ttl 2h] [--operator <who>]   open a window (write flag, post #clio_devops)
  stop                                             close the window (remove flag, post)
  status                                           human-readable window state
  is-active                                        exit 0 iff a window is active (no output)

--ttl is <int>[smhd] (default $DEFAULT_TTL). The flag self-expires: readers ignore an
expired flag, so a forgotten 'stop' re-arms all protection after the TTL, and /run is
tmpfs so a reboot clears it. Fail-safe by construction.
EOF
}

# parse_ttl "<2h>" -> seconds on stdout; exits 2 on an invalid value (missing vs
# invalid: a MISSING --ttl uses the default; an INVALID one fails loud).
parse_ttl() {
  local t="$1" n unit mag secs
  [[ "$t" =~ ^([0-9]+)([smhd])$ ]] || die "invalid --ttl '$t' (want <int>[smhd], e.g. 2h, 90m, 30s)" 2
  n="${BASH_REMATCH[1]}"; unit="${BASH_REMATCH[2]}"
  # Bound the magnitude as a STRING, BEFORE any arithmetic. A value that exceeds
  # int64 would (a) wrap in $((...)) to a small positive that slips past the cap
  # checks below (e.g. 18446744073709551617 -> 1, a phantom 1s window) and (b) also
  # wrap in a numeric compare — so the guard must be lexical. Strip leading zeros
  # for the true magnitude; the max valid TTL is 86400s (the 24h cap = 5 digits),
  # so anything longer is out of range by construction.
  mag="$n"; while [ "${mag:0:1}" = "0" ] && [ "${#mag}" -gt 1 ]; do mag="${mag:1}"; done
  [ "${#mag}" -le 5 ] || die "--ttl exceeds the 24h cap (got '$t'); re-issue 'start' to extend" 2
  # 10# forces base-10 so a zero-padded value isn't parsed as octal ($((010))==8,
  # $((08)) errors). mag is leading-zero-stripped and <= 99999, so <= 99999*86400
  # never overflows.
  case "$unit" in
    s) secs=$(( 10#$mag )) ;;
    m) secs=$(( 10#$mag * 60 )) ;;
    h) secs=$(( 10#$mag * 3600 )) ;;
    d) secs=$(( 10#$mag * 86400 )) ;;
  esac
  # Reject a zero TTL (e.g. `0h`): cmd_start would otherwise announce a window that
  # maintenance_active() reads as ALREADY EXPIRED (expires == started), silently
  # leaving every watchdog armed during the very operation this protects.
  [ "$secs" -gt 0 ] || die "--ttl must be greater than zero (got '$t')" 2
  [ "$secs" -le 86400 ] || die "--ttl exceeds the 24h cap (got '$t'); re-issue 'start' to extend" 2
  echo "$secs"
}

# iso_from_epoch <epoch> -> ISO-8601 UTC. Portable across GNU (node-8) and BSD.
iso_from_epoch() {
  date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ
}

cmd_start() {
  local reason="" ttl="$DEFAULT_TTL" operator=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --ttl)         ttl="${2:?--ttl needs a value}"; shift 2 ;;
      --ttl=*)       ttl="${1#*=}"; shift ;;
      --operator)    operator="${2:?--operator needs a value}"; shift 2 ;;
      --operator=*)  operator="${1#*=}"; shift ;;
      -*)            die "unknown flag: $1" 2 ;;
      *)             if [ -z "$reason" ]; then reason="$1"; else die "unexpected extra argument: $1" 2; fi; shift ;;
    esac
  done
  [ -n "$reason" ] || die "start requires a reason, e.g. $PROG start \"openclaw 7.1 upgrade\" --ttl 2h" 2

  local ttl_secs started_epoch expires_epoch started_at expires_at
  ttl_secs="$(parse_ttl "$ttl")"        # exits 2 on an invalid --ttl
  operator="${operator:-${SUDO_USER:-${USER:-unknown}}@hydra-ops}"
  started_epoch="$(date -u +%s)"
  expires_epoch=$(( started_epoch + ttl_secs ))
  started_at="$(iso_from_epoch "$started_epoch")"
  expires_at="$(iso_from_epoch "$expires_epoch")"

  # Atomic write: jq -n into a temp beside the flag, then mv (same dir/fs).
  local tmp
  tmp="$(mktemp "${HYDRA_MAINTENANCE_FLAG}.XXXXXX")" || die "cannot create temp flag near $HYDRA_MAINTENANCE_FLAG" 2
  jq -n \
    --arg reason "$reason" --arg operator "$operator" \
    --arg started_at "$started_at" --argjson started_epoch "$started_epoch" \
    --argjson ttl_seconds "$ttl_secs" \
    --arg expires_at "$expires_at" --argjson expires_epoch "$expires_epoch" \
    '{reason:$reason, operator:$operator, started_at:$started_at, started_epoch:$started_epoch,
      ttl_seconds:$ttl_seconds, expires_at:$expires_at, expires_epoch:$expires_epoch}' \
    > "$tmp" || { rm -f "$tmp"; die "failed to render flag JSON" 2; }
  mv "$tmp" "$HYDRA_MAINTENANCE_FLAG"

  log "maintenance window OPEN - reason: $reason - operator: $operator - expires: $expires_at (ttl $ttl)"
  notify ":construction: hydra maintenance window OPEN - *${reason}* - by ${operator}, expires ${expires_at} (ttl ${ttl}). Fleet-health watchdogs stand down until then."
}

cmd_stop() {
  if [ -f "$HYDRA_MAINTENANCE_FLAG" ]; then
    local reason; reason="$(maintenance_reason)"
    rm -f "$HYDRA_MAINTENANCE_FLAG"
    log "maintenance window CLOSED - reason: ${reason:-<none>}"
    notify ":white_check_mark: hydra maintenance window CLOSED - *${reason:-<none>}*. Fleet-health watchdogs re-armed."
  else
    log "no maintenance flag at $HYDRA_MAINTENANCE_FLAG (nothing to stop)"
  fi
}

cmd_status() {
  if [ ! -f "$HYDRA_MAINTENANCE_FLAG" ]; then
    log "no maintenance window (flag absent: $HYDRA_MAINTENANCE_FLAG)"
    return 0
  fi
  local reason operator expires_at
  reason="$(jq -r '.reason // "?"' "$HYDRA_MAINTENANCE_FLAG" 2>/dev/null || echo '?')"
  operator="$(jq -r '.operator // "?"' "$HYDRA_MAINTENANCE_FLAG" 2>/dev/null || echo '?')"
  expires_at="$(jq -r '.expires_at // "?"' "$HYDRA_MAINTENANCE_FLAG" 2>/dev/null || echo '?')"
  if maintenance_active; then
    local expires_epoch now remain
    expires_epoch="$(jq -r '.expires_epoch // 0' "$HYDRA_MAINTENANCE_FLAG" 2>/dev/null || echo 0)"
    now="$(date -u +%s)"
    remain=$(( expires_epoch - now ))
    log "ACTIVE - reason: $reason - operator: $operator - expires: $expires_at (~$(( remain / 60 ))m ${remain}s remaining)"
  else
    log "EXPIRED/malformed - reason: $reason - expires: $expires_at - flag present but NOT honored (watchdogs armed). Run '$PROG stop' to clear."
  fi
}

[ $# -ge 1 ] || { usage >&2; exit 2; }
sub="$1"; shift
case "$sub" in
  start)          cmd_start "$@" ;;
  stop)           cmd_stop "$@" ;;
  status)         cmd_status "$@" ;;
  is-active)      if maintenance_active; then exit 0; else exit 1; fi ;;
  -h|--help|help) usage ;;
  *)              echo "[$PROG] error: unknown subcommand: $sub" >&2; usage >&2; exit 2 ;;
esac
