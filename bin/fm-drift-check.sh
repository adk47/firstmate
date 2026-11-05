#!/usr/bin/env bash
# fm-drift-check.sh - report a running firstmate whose code has drifted from
# origin/main for longer than a day.
#
# Usage:
#   fm-drift-check.sh [check]
#   fm-drift-check.sh arm
#   fm-drift-check.sh disarm
#   fm-drift-check.sh --help
#
# `check` prints one line when the running chair's HEAD has differed from
# origin/main for longer than FM_DRIFT_PAGE_SECS (default 86400) and prints
# nothing at all otherwise, so it composes with the watcher's state-check
# contract instead of needing a schedule of its own. `arm` writes
# state/drift.check.sh and binds its bytes with fm-check-register.sh, so the
# watcher dispatches it on its normal FM_CHECK_INTERVAL cadence and turns its one
# line into a `check:` wake. `disarm` removes the shim, its trust binding, the
# drift record, and the probe beat.
#
# Why this exists: a chair that keeps running an old checkout supervises the
# fleet with instructions and scripts that no longer match the repository, and
# that is invisible from inside the session - every wake, brief, and guard
# behaves exactly as the stale code says. Nothing else compares what is running
# against what the repository says should be running.
#
# What it measures, and what it deliberately does not:
#   - HEAD is the running code root's own commit (FM_ROOT), never a project
#     clone's.
#   - origin/main is the last fetched value of that ref. This check never
#     fetches: a fetch from a watcher poll would race the fleet sync that owns
#     clone refresh, and a network blip must never read as drift. Bootstrap
#     refreshes the chair's own origin/main at every session start, alongside
#     fleet sync, so the comparison is against a ref current to within one
#     session.
#   - A difference in either direction is drift: a chair behind origin/main runs
#     stale code, and a chair ahead of it runs code nobody else has.
#   - Nothing is repaired here. The line names the update path; the operator or
#     firstmate runs it.
#
# The probe is gated to once per FM_DRIFT_INTERVAL (default 3600, 0 disables the
# gate) so an hourly comparison does not re-read git on every watcher poll.
#
# Drift is an EPISODE, not a poll result: state/.drift records the first poll
# that saw this HEAD while it differed from origin/main, and the line is printed
# once per episode, when that HEAD has differed for longer than the page
# threshold. A HEAD that changes starts a new episode, so a chair that drifts,
# is updated, and drifts again is reported again. An advance of origin/main
# while HEAD is unchanged does NOT restart the clock: a chair sitting still
# while the repository moves on is exactly the drift this catches. A chair that
# catches up clears the record.
#
# Test seams: FM_DRIFT_NOW overrides the clock (epoch seconds) and
# FM_DRIFT_INTERVAL=0 disables the probe gate, so a test can drive 23h and 25h of
# drift without waiting or touching the host clock.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
RECORD="$STATE/.drift"
BEAT="$STATE/.drift.beat"
CHECK_ID=drift
REGISTER_BIN="$SCRIPT_DIR/fm-check-register.sh"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-check-lib.sh
. "$SCRIPT_DIR/fm-check-lib.sh"

usage() {
  cat <<'EOF'
Usage:
  fm-drift-check.sh [check]   report a running chair drifted from origin/main (silent when current)
  fm-drift-check.sh arm       write and register state/drift.check.sh
  fm-drift-check.sh disarm    remove the check shim, its trust binding, and the drift record
  fm-drift-check.sh --help    print this help

The comparison is read-only: this check never fetches and never moves HEAD.
See docs/configuration.md "Running-chair drift check" for the thresholds.
EOF
}

die_usage() {
  printf 'fm-drift-check: %s\n' "$1" >&2
  usage >&2
  exit 2
}

INTERVAL=${FM_DRIFT_INTERVAL:-3600}
case "$INTERVAL" in
  ''|*[!0-9]*)
    printf 'fm-drift-check: FM_DRIFT_INTERVAL must be 0 or a whole number from 60 to 86400\n' >&2
    exit 2
    ;;
esac
if [ "$INTERVAL" -ne 0 ] && { [ "$INTERVAL" -lt 60 ] || [ "$INTERVAL" -gt 86400 ]; }; then
  printf 'fm-drift-check: FM_DRIFT_INTERVAL must be 0 or a whole number from 60 to 86400\n' >&2
  exit 2
fi

PAGE_SECS=${FM_DRIFT_PAGE_SECS:-86400}
case "$PAGE_SECS" in
  ''|*[!0-9]*|0)
    printf 'fm-drift-check: FM_DRIFT_PAGE_SECS must be a whole number of seconds from 1 to 2592000\n' >&2
    exit 2
    ;;
esac
if [ "$PAGE_SECS" -gt 2592000 ]; then
  printf 'fm-drift-check: FM_DRIFT_PAGE_SECS must be a whole number of seconds from 1 to 2592000\n' >&2
  exit 2
fi

# now_epoch: the clock, with the test seam applied. A non-numeric override is
# ignored rather than trusted, so a typo can never freeze the episode clock.
now_epoch() {
  case "${FM_DRIFT_NOW:-}" in
    ''|*[!0-9]*) date +%s ;;
    *) printf '%s' "$FM_DRIFT_NOW" ;;
  esac
}

# record_field: read one key=value line from a record file, or print nothing.
record_field() {  # <file> <key>
  local file=$1 key=$2 line value=''
  [ -f "$file" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      "$key="*) value=${line#*=} ;;
    esac
  done < "$file" 2>/dev/null || true
  printf '%s' "$value"
}

write_record() {  # <head> <origin> <since> <paged>
  local tmp
  tmp="$RECORD.tmp.$$"
  {
    printf 'head=%s\n' "$1"
    printf 'origin=%s\n' "$2"
    printf 'since=%s\n' "$3"
    printf 'paged=%s\n' "$4"
  } > "$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$RECORD"
}

beat_write() {  # <epoch>
  printf '%s\n' "$1" > "$BEAT" 2>/dev/null || true
}

git_head() {
  git -C "$FM_ROOT" rev-parse --verify --quiet HEAD 2>/dev/null
}

git_origin_main() {
  git -C "$FM_ROOT" rev-parse --verify --quiet refs/remotes/origin/main 2>/dev/null
}

# drift_line: the one line this check ever prints. It names both commits, how
# long they have differed, and which direction the drift runs, because "behind"
# and "ahead" call for different actions.
drift_line() {  # <head> <origin> <age-seconds>
  local head=$1 origin=$2 age=$3 behind ahead hours
  behind=$(git -C "$FM_ROOT" rev-list --count "$head..$origin" 2>/dev/null || true)
  ahead=$(git -C "$FM_ROOT" rev-list --count "$origin..$head" 2>/dev/null || true)
  case "$behind" in ''|*[!0-9]*) behind=0 ;; esac
  case "$ahead" in ''|*[!0-9]*) ahead=0 ;; esac
  hours=$((age / 3600))
  printf 'firstmate drift: running HEAD %s has differed from origin/main %s for %sh (behind %s, ahead %s); update with /updatefirstmate\n' \
    "${head:0:7}" "${origin:0:7}" "$hours" "$behind" "$ahead"
}

action_check() {
  local now last head origin since paged age
  now=$(now_epoch)
  if [ "$INTERVAL" -ne 0 ]; then
    last=$(cat "$BEAT" 2>/dev/null || true)
    case "$last" in ''|*[!0-9]*) last=0 ;; esac
    [ $((now - last)) -ge "$INTERVAL" ] || return 0
  fi
  head=$(git_head) || head=
  origin=$(git_origin_main) || origin=
  # A code root that is not a git checkout, or one whose origin/main has never
  # been fetched, proves nothing about drift: stay silent rather than page on a
  # comparison that was never made.
  if [ -z "$head" ] || [ -z "$origin" ]; then
    beat_write "$now"
    return 0
  fi
  if [ "$head" = "$origin" ]; then
    rm -f "$RECORD"
    beat_write "$now"
    return 0
  fi
  since=$(record_field "$RECORD" since)
  paged=$(record_field "$RECORD" paged)
  if [ "$(record_field "$RECORD" head)" != "$head" ]; then
    since=$now
    paged=0
  fi
  case "$since" in ''|*[!0-9]*) since=$now; paged=0 ;; esac
  case "$paged" in 0|1) ;; *) paged=0 ;; esac
  age=$((now - since))
  if [ "$paged" = 0 ] && [ "$age" -gt "$PAGE_SECS" ]; then
    drift_line "$head" "$origin" "$age"
    paged=1
  fi
  write_record "$head" "$origin" "$since" "$paged" || true
  beat_write "$now"
  return 0
}

shim_content() {
  local home=$1
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    '# Auto-generated by fm-drift-check.sh - running-chair drift poll shim.' \
    '# The watcher validates these bytes, then dispatches the trusted check script.' \
    "export FM_HOME=$(printf '%q' "$home")" \
    "exec $(printf '%q' "$SCRIPT_DIR/fm-drift-check.sh") check"
}

action_arm() {
  local home want
  mkdir -p "$STATE" || return 1
  home=$(fm_custom_check_resolve_home "$FM_HOME") || {
    printf 'fm-drift-check: cannot resolve FM_HOME %s\n' "$FM_HOME" >&2
    return 1
  }
  want=$(shim_content "$home")
  fm_custom_check_arm "$STATE" "$CHECK_ID" .fm-drift-check \
    fm-drift-check "$REGISTER_BIN" "$home" "$want"
}

action_disarm() {
  fm_custom_check_disarm "$STATE" "$CHECK_ID" "$RECORD" "$BEAT"
}

case "${1:-check}" in
  check) action_check ;;
  arm) action_arm ;;
  disarm) action_disarm ;;
  -h|--help) usage ;;
  *) die_usage "unknown action: $1" ;;
esac
