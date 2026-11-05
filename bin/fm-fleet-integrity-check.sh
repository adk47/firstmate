#!/usr/bin/env bash
# fm-fleet-integrity-check.sh - the registered watcher check that notices a
# lane whose agent process is gone while its worktree and records remain.
#
# Usage:
#   fm-fleet-integrity-check.sh [check]   run the poll (silent unless it should wake)
#   fm-fleet-integrity-check.sh status    print the last recorded verdict (no scan)
#   fm-fleet-integrity-check.sh arm       write state/fleet-integrity.check.sh and bind it
#   fm-fleet-integrity-check.sh disarm    remove the shim, its trust binding, and the record
#   fm-fleet-integrity-check.sh --help    print this help
#
# WHY THIS EXISTS. On 2026-11-05 the default tmux server was lost and the fleet
# lost roughly 27 lanes. The same fleet was then counted as 11 dead, then 15,
# then 27 in three successive reads - wrong in both directions - because the
# liveness read trusted a state/<id>.busy-state record that never settles when
# an agent is hard-killed, so dead lanes kept reporting "working". Only checking
# each lane against a live process got the truth. bin/fm-crew-state.sh now
# corroborates a record-sourced busy verdict per lane; this check is the
# fleet-wide backstop that notices the whole dead set on its own, without a
# firstmate turn and without anyone asking.
#
# WHAT IT READS. Every IN-FLIGHT lane: a state/<id>.meta whose recorded
# worktree still exists, whose endpoint is local (a remote secondmate's worktree
# is a path on ITS host, so a local probe proves nothing for it), and whose
# state/<id>.busy-state record reads `busy` - the lane is claiming to be working
# right now. That is the defect class exactly: a lane that says it is working
# while its agent process is gone. A lane whose record reads idle, or that has
# no record at all, is not claiming anything and is left alone; a lane whose
# endpoint is gone is the watchdog's business, not this check's.
# For each in-flight lane, one bounded read-only `lsof -a -d cwd` scan answers
# whether a live process sits in that worktree and classifies as an agent -
# bin/fm-lane-liveness-lib.sh owns that rule, including why a pane's idle shell
# does not count. The scan is matched only against the recorded worktree paths;
# nothing here walks a worktree's file tree, signals a process, or writes
# anything but its own stamp and record.
#
# WHAT IT SAYS. One line, only when the dead set is non-empty, naming every dead
# lane. Silence is the healthy answer and the common one. A lane is reported
# dead only on positive evidence - its worktree holds nothing but shells, or
# nothing at all - so a worktree holding a process the shared vocabulary cannot
# classify is left alone rather than reported, because a false dead verdict is
# what launches a duplicate agent onto a live worktree. A scan that cannot be
# trusted (no lsof, or lsof failed) is silent for the same reason: a broken
# probe is not evidence that the fleet is dead.
#
# SELF-THROTTLED. A stamp file keeps the scan off every watcher poll; the
# default cadence is 300s and FM_FLEET_INTEGRITY_INTERVAL overrides it. The
# whole poll is one lsof scan plus one `ps` per matching process, well inside
# the watcher's FM_CHECK_TIMEOUT.
set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-check-lib.sh
. "$SCRIPT_DIR/fm-check-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-busy-lib.sh
. "$SCRIPT_DIR/fm-busy-lib.sh"
# shellcheck source=bin/fm-lane-liveness-lib.sh
. "$SCRIPT_DIR/fm-lane-liveness-lib.sh"

CHECK_ID='fleet-integrity'
STAMP="$STATE/.fleet-integrity.last"
RECORD="$STATE/.fleet-integrity"
REGISTER_BIN="$SCRIPT_DIR/fm-check-register.sh"
MAX_LINE=1500

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "${BASH_SOURCE[0]}"
  exit 2
}

now_epoch() {
  case "${FM_FLEET_INTEGRITY_NOW:-}" in
    ''|*[!0-9]*) date +%s ;;
    *) printf '%s\n' "$FM_FLEET_INTEGRITY_NOW" ;;
  esac
}

interval_secs() {
  local v=${FM_FLEET_INTEGRITY_INTERVAL:-300}
  case "$v" in ''|*[!0-9]*) v=300 ;; esac
  [ "$v" -ge 1 ] || v=300
  printf '%s\n' "$v"
}

# lane_worktrees: the recorded worktree of every in-flight local lane, one per
# line as "<id>\t<worktree>". In-flight means the lane's own busy-state record
# reads `busy` - it is claiming to be working - and its worktree still exists.
# A remote secondmate is skipped: its worktree path names a directory on another
# host, so a local cwd scan proves nothing about it.
lane_worktrees() {
  local meta id wt remote record
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] && [ ! -L "$meta" ] || continue
    id=$(basename "$meta" .meta)
    fm_pr_task_id_valid "$id" || continue
    remote=$(fm_meta_get "$meta" remote_host)
    [ -z "$remote" ] || continue
    wt=$(fm_meta_get "$meta" worktree)
    [ -n "$wt" ] && [ -d "$wt" ] || continue
    record=$(fm_busy_record_read "$STATE" "$id" 2>/dev/null) || continue
    [ "${record%% *}" = busy ] || continue
    printf '%s\t%s\n' "$id" "$wt"
  done
}

action_check() {
  local now stamp interval rows dead ids wt id line
  now=$(now_epoch)
  interval=$(interval_secs)
  if [ -f "$STAMP" ] && [ ! -L "$STAMP" ]; then
    stamp=$(cat "$STAMP" 2>/dev/null) || stamp=
    case "$stamp" in
      ''|*[!0-9]*) stamp=0 ;;
    esac
    [ $((now - stamp)) -ge "$interval" ] || return 0
  fi
  mkdir -p "$STATE" 2>/dev/null || return 0
  printf '%s\n' "$now" > "$STAMP" 2>/dev/null || true

  rows=$(lane_worktrees) || return 0
  [ -n "$rows" ] || return 0

  local -a worktrees=()
  while IFS=$'\t' read -r id wt; do
    [ -n "$wt" ] || continue
    worktrees+=("$wt")
  done <<EOF
$rows
EOF
  [ "${#worktrees[@]}" -gt 0 ] || return 0

  # One scan for the whole fleet. A scan that cannot be trusted is silent: a
  # broken probe is not evidence that every lane is dead.
  dead=$(fm_lane_dead_worktrees "${worktrees[@]}") || return 0
  [ -n "$dead" ] || { rm -f -- "$RECORD" 2>/dev/null; return 0; }

  ids=
  while IFS=$'\t' read -r id wt; do
    [ -n "$wt" ] || continue
    if printf '%s\n' "$dead" | grep -Fqx -- "$wt"; then
      ids="${ids:+$ids,}$id"
    fi
  done <<EOF
$rows
EOF
  [ -n "$ids" ] || return 0

  line="fleet-integrity: no live agent process in the worktree of $ids - each is a dead lane still holding its worktree; read it with bin/fm-crew-state.sh <id>, then relaunch or tear it down"
  line=$(printf '%s' "$line" | cut -c1-"$MAX_LINE")
  printf '%s\n' "$line" > "$RECORD" 2>/dev/null || true
  printf '%s\n' "$line"
}

action_status() {
  if [ -f "$RECORD" ] && [ ! -L "$RECORD" ]; then
    cat "$RECORD"
  else
    printf 'fleet-integrity: no dead lane recorded\n'
  fi
}

shim_content() {
  local home=$1
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    '# Auto-generated by fm-fleet-integrity-check.sh - fleet integrity poll shim.' \
    '# The watcher validates these bytes, then dispatches the trusted check script.' \
    "export FM_HOME=$(printf '%q' "$home")" \
    "exec $(printf '%q' "$SCRIPT_DIR/fm-fleet-integrity-check.sh") check"
}

action_arm() {
  local want home
  mkdir -p "$STATE" || return 1
  home=$(fm_custom_check_resolve_home "$FM_HOME") || {
    printf 'fm-fleet-integrity-check: cannot resolve FM_HOME %s\n' "$FM_HOME" >&2
    return 1
  }
  want=$(shim_content "$home")
  fm_custom_check_arm "$STATE" "$CHECK_ID" .fm-fleet-integrity-check \
    fm-fleet-integrity-check "$REGISTER_BIN" "$home" "$want"
}

action_disarm() {
  fm_custom_check_disarm "$STATE" "$CHECK_ID" "$RECORD" "$STAMP"
}

case "${1:-check}" in
  check) action_check ;;
  status) action_status ;;
  arm) action_arm ;;
  disarm) action_disarm ;;
  -h|--help|help) usage ;;
  *) usage ;;
esac
