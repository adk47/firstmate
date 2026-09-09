#!/usr/bin/env bash
# Record and read the PRIMARY firstmate session's own terminal endpoint.
#
# WHY THIS EXISTS. Every other endpoint firstmate supervises is written into
# state/<id>.meta by the spawn that created it. The primary session is not
# spawned by firstmate, so its own pane is discovered from the environment the
# session inherits (bin/fm-supervisor-target-lib.sh) - which works for anything
# started FROM that pane, and not at all for the keep-alive agent
# (bin/fm-keepalive-agent.sh), which launchd starts with none of it.
#
# This writes what the session itself can prove about its endpoint into
# state/.primary-endpoint, so the out-of-session supervisor can read the CURRENT
# pane rather than guess one. The record is refreshed by the primary's own
# StopFailure hook, so a firstmate relaunched into a different pane re-points
# the supervisor without a reinstall.
#
# Record format, one line:
#   v1 backend=<backend> target=<target> pid=<session-pid> ts=<epoch>
#
# It NEVER guesses. When the environment proves no endpoint, `record` writes
# nothing and fails; the installer's explicit --backend/--target is then the
# only way the supervisor gets one, and the supervisor refuses to act rather
# than send keys into a pane nobody proved is firstmate's.
#
# Usage:
#   fm-keepalive-endpoint.sh record [--state <dir>] [--backend <b>] [--target <t>]
#   fm-keepalive-endpoint.sh read   [--state <dir>] [--field backend|target|pid|ts]
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"

# shellcheck source=bin/fm-supervisor-target-lib.sh
. "$SCRIPT_DIR/fm-supervisor-target-lib.sh"

usage() {
  sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

CMD=${1:-}
[ "$#" -eq 0 ] || shift
STATE_DIR=''
WANT_BACKEND=''
WANT_TARGET=''
FIELD=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --state) STATE_DIR=${2:-}; shift 2 || exit 2 ;;
    --backend) WANT_BACKEND=${2:-}; shift 2 || exit 2 ;;
    --target) WANT_TARGET=${2:-}; shift 2 || exit 2 ;;
    --field) FIELD=${2:-}; shift 2 || exit 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown argument '$1'" >&2; exit 2 ;;
  esac
done

if [ -z "$STATE_DIR" ]; then
  FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
  STATE_DIR="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
fi
RECORD="$STATE_DIR/.primary-endpoint"

# Resolve this process's own terminal endpoint from the environment it
# inherited. tmux and herdr come from the shared discovery owner; cmux and orca
# expose their own identifiers, and are read here rather than added to that
# owner because the away daemon it serves has no verified primitives for either
# (bin/fm-supervise-daemon.sh's FM_SUPERVISOR_SUPPORTED_BACKENDS) and must not
# start resolving panes it cannot drive.
detect_endpoint() {  # prints "<backend>\t<target>", or fails
  if [ -n "${TMUX_PANE:-}" ]; then
    printf '%s\t%s' tmux "$TMUX_PANE"
    return 0
  fi
  if [ "${HERDR_ENV:-}" = "1" ] && [ -n "${HERDR_PANE_ID:-}" ]; then
    printf '%s\t%s:%s' herdr "${HERDR_SESSION:-default}" "$HERDR_PANE_ID"
    return 0
  fi
  if [ -n "${CMUX_TERMINAL_ID:-}" ]; then
    printf '%s\t%s' cmux "$CMUX_TERMINAL_ID"
    return 0
  fi
  if [ -n "${ORCA_TERMINAL_ID:-}" ]; then
    printf '%s\t%s' orca "$ORCA_TERMINAL_ID"
    return 0
  fi
  return 1
}

record_field() {  # <field>
  local line v
  line=$(cat "$RECORD" 2>/dev/null) || return 1
  case "$line" in v1\ *) : ;; *) return 1 ;; esac
  for v in $line; do
    case "$v" in
      "$1"=*) printf '%s' "${v#*=}"; return 0 ;;
    esac
  done
  return 1
}

case "$CMD" in
  record)
    backend=$WANT_BACKEND
    target=$WANT_TARGET
    if [ -z "$backend" ] || [ -z "$target" ]; then
      if detected=$(detect_endpoint); then
        [ -n "$backend" ] || backend=${detected%%$'\t'*}
        [ -n "$target" ] || target=${detected#*$'\t'}
      fi
    fi
    if [ -z "$backend" ] || [ -z "$target" ]; then
      echo "error: this session's own terminal endpoint could not be proved from the environment; pass --backend and --target explicitly" >&2
      exit 1
    fi
    mkdir -p "$STATE_DIR" || exit 1
    tmp="$RECORD.tmp.$$"
    printf 'v1 backend=%s target=%s pid=%s ts=%s\n' \
      "$backend" "$target" "${PPID:-0}" "$(date +%s)" > "$tmp" || { rm -f "$tmp"; exit 1; }
    mv -f "$tmp" "$RECORD" || { rm -f "$tmp"; exit 1; }
    printf '%s %s\n' "$backend" "$target"
    ;;
  read)
    if [ -n "$FIELD" ]; then
      record_field "$FIELD" || exit 1
      printf '\n'
      exit 0
    fi
    cat "$RECORD" 2>/dev/null || exit 1
    ;;
  ''|-h|--help)
    usage
    [ -n "$CMD" ] || exit 2
    ;;
  *)
    echo "error: unknown command '$CMD'" >&2
    exit 2
    ;;
esac
