#!/usr/bin/env bash
# fm-fable-runway-alert.sh - the Fable-runway check's outward-facing actions.
#
# Usage:
#   fm-fable-runway-alert.sh handoff-no-grant <monitor-line>
#       open a failover episode: the pool was read and no grant on the fleet's
#       proxy is live
#   fm-fable-runway-alert.sh handoff <monitor-line>
#       open a failover episode: the pool was read and holds no Fable capacity
#   fm-fable-runway-alert.sh handoff-unreachable <monitor-line> <minutes>
#       open a failover episode: the pool has been unreadable that long
#   fm-fable-runway-alert.sh resolve                    close the open episode
#   fm-fable-runway-alert.sh needs-auth <names> <line>  an account wants a login
#   fm-fable-runway-alert.sh --help                     print this help
#
# The check itself only reports. Everything that leaves the process lives here,
# so the one place that writes state, runs a CLI, or posts a banner is the one
# place to audit - and so the two notifications the monitor can raise share a
# single notifier rather than carrying a copy each.
#
# The two `handoff` verbs are the zero-token failover action. When the
# supervisor seat has to move to Grok, waiting for a firstmate model turn to
# notice is exactly the wait that cannot be afforded: the runway that would
# have paid for that turn is the one that just ran out. So this is plain bash,
# it never asks a model anything, and it does three things once per episode.
#
# The verbs exist because they are different claims and the note and the banner
# must not confuse them. `handoff-no-grant` and `handoff` are observations - the
# pool answered, and either no grant on the fleet's proxy is live or the grants
# are there with every Fable week spent. `handoff-unreachable` is the absence of
# an observation - nobody could read the pool for that many minutes while the
# supervisor's own runway was RED - and it says exactly that. None may ever be
# worded as another: a gateway blip reported as an empty pool sends the captain
# to look for accounts that were there the whole time. Each does:
#
#   1. writes a durable handoff note under state/, carrying the monitor line,
#      the UTC time, the reason tokens, and a pointer to the runbook;
#   2. rings the Grok supervisor terminal's doorbell through the orca CLI,
#      carrying that note's path;
#   3. posts a macOS notification naming the runway and the note.
#
# An episode is one marker file. It is written after the note exists, and it is
# removed by `resolve` on the first poll whose condition no longer holds, so a
# sustained RED rings once rather than on every poll, and a RED that comes back
# after a recovery rings again.
#
# Every step is best-effort and bounded: a missing orca, a missing osascript, an
# unconfigured terminal handle, or a hung either of them costs its own step and
# nothing else. The note is written first because it is the step that needs no
# other program to be installed, and it is the one the captain reads.
#
# The Grok terminal handle is never hard-coded: it is read from
# config/fable-runway.env (gitignored, per-home) as
# FM_FABLE_RUNWAY_GROK_TERMINAL. With no handle configured the doorbell is
# skipped and the note and the notification still happen.
#
# Test seams: FM_STATE_OVERRIDE selects the state directory and
# FM_FABLE_RUNWAY_NOW freezes the clock. orca and osascript are resolved from
# PATH, so a test shadows them rather than redirecting them by name.
set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"

MARKER="$STATE/.fable-runway-handoff"
CONFIG="$FM_HOME/config/fable-runway.env"
RUNBOOK=docs/runbooks/supervisor-failover-grok.md
CALL_SECS=5

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "${BASH_SOURCE[0]}"
  exit 2
}

now_epoch() {
  case "${FM_FABLE_RUNWAY_NOW:-}" in
    ''|*[!0-9]*) date +%s ;;
    *) printf '%s\n' "$FM_FABLE_RUNWAY_NOW" ;;
  esac
}

# field <name> <line>: print the first `<name>=<token>` value, or nothing.
field() {
  printf '%s\n' "$2" | sed -n "s/.* $1=\\([^ ]*\\).*/\\1/p" | head -n 1
}

# The handle is configuration, not code, so the file is parsed rather than
# sourced: a per-home config file must not be able to run anything.
config_get() {
  local key=$1 line val
  [ -f "$CONFIG" ] && [ ! -L "$CONFIG" ] || return 0
  line=$(grep -E "^[[:space:]]*(export[[:space:]]+)?${key}=" "$CONFIG" 2>/dev/null | tail -n 1) || return 0
  [ -n "$line" ] || return 0
  val=${line#*=}
  val=${val#"${val%%[![:space:]]*}"}
  val=${val%"${val##*[![:space:]]}"}
  case "$val" in
    \"*\") val=${val#\"}; val=${val%\"} ;;
    \'*\') val=${val#\'}; val=${val%\'} ;;
  esac
  printf '%s' "$val"
}

# Post a macOS Notification Center banner, the same way the wedge alarm does:
# OS-level, so it survives whatever happened to the terminal pane, and with both
# strings passed as argv items so no account name can break the AppleScript.
notify() {
  local title=$1 message=$2
  command -v osascript >/dev/null 2>&1 || return 1
  fm_run_timed "$CALL_SECS" osascript \
    -e 'on run argv' \
    -e 'display notification (item 1 of argv) with title (item 2 of argv) sound name "Basso"' \
    -e 'end run' "$message" "$title" >/dev/null 2>&1
}

write_note() {
  local path=$1 line=$2 now=$3 summary=$4 stamp
  stamp=$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null) || stamp=unknown
  {
    printf '# Fable runway handoff\n\n'
    printf -- '- condition: %s\n' "$summary"
    printf -- '- utc: %s\n' "$stamp"
    printf -- '- epoch: %s\n' "$now"
    printf -- '- fable_reason: %s\n' "$(field fable_reason "$line")"
    printf -- '- pool_reason: %s\n' "$(field pool_reason "$line")"
    printf -- '- runbook: %s\n\n' "$RUNBOOK"
    printf '%s\n' "$line"
  } > "$path"
}

ring_doorbell() {
  local note=$1 summary=$2 handle text
  handle=$(config_get FM_FABLE_RUNWAY_GROK_TERMINAL)
  [ -n "$handle" ] || return 0
  command -v orca >/dev/null 2>&1 || return 0
  text="fable-runway RED: $summary Take the supervisor seat per $RUNBOOK - handoff note: $note"
  fm_run_timed "$CALL_SECS" orca terminal send \
    --terminal "$handle" --text "$text" --enter >/dev/null 2>&1 || return 0
}

open_episode() {
  local summary=$1 line=$2 now note
  [ -n "$line" ] || return 0
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || return 0
  [ -e "$MARKER" ] && return 0
  now=$(now_epoch)
  note="$STATE/fable-runway-handoff-$now.md"
  write_note "$note" "$line" "$now" "$summary" || return 0
  : > "$MARKER" 2>/dev/null || true
  ring_doorbell "$note" "$summary"
  notify 'firstmate: Fable runway RED' "$summary Handoff note: $note" || true
  return 0
}

action_resolve() {
  rm -f -- "$MARKER" 2>/dev/null
  return 0
}

action_needs_auth() {
  local names=$1 line=${2-}
  [ -n "$names" ] && [ "$names" != none ] || return 0
  notify 'firstmate: account needs a login' \
    "No proxy holds a live grant: $names ($(field pool_state "$line"))" || true
  return 0
}

case "${1-}" in
  handoff-no-grant) open_episode 'No live grant on the fleet'"'"'s proxy.' "${2-}" ;;
  handoff) open_episode 'No Fable-capable account left.' "${2-}" ;;
  handoff-unreachable)
    open_episode "Pool unreachable for ${3-0} minutes, supervisor runway unmeasurable." "${2-}"
    ;;
  resolve) action_resolve ;;
  needs-auth) action_needs_auth "${2-}" "${3-}" ;;
  -h|--help|help) usage ;;
  *) usage ;;
esac
