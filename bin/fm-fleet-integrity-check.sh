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
# worktree still exists and whose endpoint is local (a remote secondmate's
# worktree is a path on ITS host, so a local probe proves nothing for it). The
# busy-state record is a CLAIM, not a filter: a lane between turns, or one whose
# record never settled, still has a worktree and can still be dead. A lane whose
# endpoint is gone is the watchdog's business, not this check's.
# For each in-flight lane, one bounded read-only process-table read answers
# whether a live process sits in that worktree and classifies as an agent -
# bin/fm-agent-proc-lib.sh owns that rule (and the fleet-wide walk built on it),
# including why a pane's idle shell does not count and why an unclassifiable
# process is never death evidence. The table is read once for the whole fleet;
# nothing here signals a process or writes anything but its own stamp and
# record; the claim comparison adds only local `git status` reads inside each
# recorded worktree, plus - for a lane it would otherwise report - the shared
# landed-work test in bin/fm-landed-lib.sh.
# The lane's last status-log line is its CLAIM, and only a TERMINAL claim is
# compared: done or failed. A done or failed lane that still holds uncommitted
# files, or whose commits are provably not landed, is reported, because the
# claim and the worktree disagree. "Landed" is the same rule teardown uses,
# owned by bin/fm-landed-lib.sh: reachable from a remote-tracking branch, a
# merged PR whose head contains the work, or content already in the default
# branch - so a squash-merged-then-deleted branch and a local-only project
# merged into its local default branch are silent. That test is bounded and
# only run for a lane with unpushed commits and no uncommitted files; when it
# cannot prove landed or unlanded (no gh, no network, unreadable repo, the
# poll's time budget) the lane is silent, because unprovable is never a
# finding. A working claim is not compared (work in progress is expected to
# hold work), and neither is a waiting claim (parked, paused, blocked) nor a
# lane with no claim at all - no status line yet, or a trailing
# decision-closing `resolved:` that bin/fm-classify-lib.sh deliberately excludes
# from run-state - because none of those says the lane is finished with its
# worktree.
#
# WHAT IT SAYS. One line naming every dead lane, only when the dead set is
# non-empty, plus one line per lane whose terminal claim disagrees with the work
# its worktree still holds. Silence is the healthy answer and the common one. A
# lane is reported dead only on positive evidence - its worktree holds nothing
# but shells, or nothing at all - so a worktree holding a process the shared
# vocabulary cannot classify is left alone rather than reported, because a false
# dead verdict is what launches a duplicate agent onto a live worktree.
# A scan that cannot be trusted (the process table could not be read) is silent
# for the same reason: a broken probe is not evidence that the fleet is dead.
#
# SELF-THROTTLED. A stamp file keeps the scan off every watcher poll; the
# default cadence is 300s and FM_FLEET_INTEGRITY_INTERVAL overrides it. The
# required dead-lane line is computed from the one bounded process-table read
# alone and printed and recorded BEFORE any claim comparison, so an optional
# probe can never starve it. That read is bounded by bin/fm-timeout-lib.sh, and
# the throttle stamp is written only after it succeeds, so a scan that cannot
# finish is retried on the next poll instead of being suppressed for the whole
# interval. The claim comparisons then spend at most half of the watcher's
# FM_CHECK_TIMEOUT, every git read is bounded by the same owner, and a read that
# hits its bound leaves the lane silent rather than guessing.
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
# shellcheck source=bin/fm-gemini-lib.sh
. "$SCRIPT_DIR/fm-gemini-lib.sh"
# shellcheck source=bin/fm-agent-proc-lib.sh
. "$SCRIPT_DIR/fm-agent-proc-lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-landed-lib.sh
. "$SCRIPT_DIR/fm-landed-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"

CHECK_ID='fleet-integrity'
STAMP="$STATE/.fleet-integrity.last"
RECORD="$STATE/.fleet-integrity"
REGISTER_BIN="$SCRIPT_DIR/fm-check-register.sh"
MAX_LINE=1500
CHECK_TIMEOUT=${FM_CHECK_TIMEOUT:-30}
case "$CHECK_TIMEOUT" in ''|*[!0-9]*) CHECK_TIMEOUT=30 ;; esac
[ "$CHECK_TIMEOUT" -ge 1 ] || CHECK_TIMEOUT=30
# A landed test per lane is capped so one slow lane cannot eat the poll. The
# optional claim comparison is budgeted at half the watcher's own kill deadline,
# the same split bin/fm-fleet-stall-check.sh uses, and at most 15 seconds, so the
# required dead-lane line always has room.
LANDED_CAP=$((CHECK_TIMEOUT / 4))
[ "$LANDED_CAP" -ge 1 ] || LANDED_CAP=1
GIT_READ_CAP=$((CHECK_TIMEOUT / 4))
[ "$GIT_READ_CAP" -ge 1 ] || GIT_READ_CAP=1
[ "$GIT_READ_CAP" -le 3 ] || GIT_READ_CAP=3
POLL_BUDGET=$((CHECK_TIMEOUT / 2))
[ "$POLL_BUDGET" -le 15 ] || POLL_BUDGET=15
[ "$POLL_BUDGET" -ge 3 ] || POLL_BUDGET=3
SCAN_CAP=$((CHECK_TIMEOUT / 2))
[ "$SCAN_CAP" -le 15 ] || SCAN_CAP=15
[ "$SCAN_CAP" -ge 1 ] || SCAN_CAP=1

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

# lane_claim: the lane's last status-log state, or `unknown` when it has no
# readable claim. bin/fm-classify-lib.sh owns the bounded tail read and the
# verb vocabulary, so this check does not grow a second status parser.
lane_claim() {  # <id>
  local log="$STATE/$1.status" line verb
  line=$(last_status_line "$log")
  [ -n "$line" ] || { printf 'unknown'; return 0; }
  if status_is_paused "$line"; then
    printf 'paused'
    return 0
  fi
  verb=$(status_line_verb "$line")
  case "$verb" in
    working) printf 'working' ;;
    needs-decision) printf 'parked' ;;
    blocked) printf 'blocked' ;;
    done) printf 'done' ;;
    failed) printf 'failed' ;;
    *) printf 'unknown' ;;
  esac
}

# lane_worktrees: the recorded worktree, status-log claim, and recorded PR
# target of every in-flight local lane, one per line as
# "<id>\t<worktree>\t<claim>\t<pr>". In-flight means the lane has a meta record
# and its worktree still exists; the busy-state record is deliberately not a
# filter, because a lane between turns can still be dead.
# A remote secondmate is skipped: its worktree path names a directory on another
# host, so a local cwd scan proves nothing about it.
lane_worktrees() {
  local meta id wt remote claim pr harness
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] && [ ! -L "$meta" ] || continue
    id=$(basename "$meta" .meta)
    fm_pr_task_id_valid "$id" || continue
    remote=$(fm_meta_get "$meta" remote_host)
    [ -z "$remote" ] || continue
    wt=$(fm_meta_get "$meta" worktree)
    [ -n "$wt" ] && [ -d "$wt" ] || continue
    claim=$(lane_claim "$id")
    pr=$(fm_meta_get "$meta" pr)
    harness=$(fm_meta_get "$meta" harness)
    printf '%s\x1f%s\x1f%s\x1f%s\x1f%s\n' "$id" "$wt" "$claim" "$pr" "$harness"
  done
}

# lane_worktree_work: "<uncommitted-files>\t<unpushed-commits>" for a worktree.
# Local git reads only: no fetch, no network, no write. Each read is bounded by
# the repo's timeout owner so one hung repository cannot consume the poll; a
# read that hits the bound returns 1 (unknown) rather than a guess. A worktree
# that is not a git checkout, or a git read that fails outright, contributes zero.
lane_worktree_work() {  # <worktree> <seconds>
  local wt=$1 seconds=$2 dirty=0 unpushed out rc
  out=$(fm_run_timed "$seconds" git -C "$wt" status --porcelain 2>/dev/null)
  rc=$?
  [ "$rc" -ne 124 ] || return 1
  [ -z "$out" ] || dirty=$(printf '%s\n' "$out" | wc -l | tr -d ' ')
  case "$dirty" in ''|*[!0-9]*) dirty=0 ;; esac
  unpushed=$(fm_run_timed "$seconds" git -C "$wt" rev-list --count HEAD --not --remotes 2>/dev/null)
  rc=$?
  [ "$rc" -ne 124 ] || return 1
  case "$unpushed" in ''|*[!0-9]*) unpushed=0 ;; esac
  printf '%s\t%s\n' "$dirty" "$unpushed"
}

# lane_landed_verdict: 0 landed, 1 provably unlanded, 2 unprovable or out of
# time. bin/fm-landed-lib.sh owns the rule; the bound keeps a slow fetch from
# running past the poll's budget. The recorded PR target is used only when the
# lane has one, so a lane without a PR never makes this poll reach GitHub on a
# branch-name lookup.
lane_landed_verdict() {  # <worktree> <branch> <pr> <seconds>
  local wt=$1 branch=$2 pr=$3 seconds=$4
  # shellcheck disable=SC2016
  fm_run_timed "$seconds" bash -c '
    . "$1" || exit 2
    shift
    wt=$1 branch=$2 pr=$3
    if [ -n "$pr" ]; then
      fm_landed_work_is_landed "$wt" "$branch" "$pr" >/dev/null
    else
      fm_landed_content_in_default "$wt" >/dev/null
    fi
  ' fm-landed "$SCRIPT_DIR/fm-landed-lib.sh" "$wt" "$branch" "$pr"
}

action_check() {
  local now stamp interval rows ids wt id claim pr harness branch line findings extra dirty unpushed work
  local landed_rc deadline remaining seconds scan_table
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

  rows=$(lane_worktrees) || return 0
  [ -n "$rows" ] || { rm -f -- "$RECORD" 2>/dev/null; return 0; }

  # One bounded process-table read for the whole fleet. A read that cannot be
  # trusted is silent, and it does not write the stamp: a broken or slow probe
  # must be retried on the next poll, never suppressed for the whole interval.
  scan_table=$(mktemp "$STATE/.fleet-integrity.proc.XXXXXX" 2>/dev/null) || return 0
  # shellcheck disable=SC2016
  if ! fm_run_timed "$SCAN_CAP" bash -c '. "$1" || exit 2; fm_agent_proc_table > "$2"' \
    fm-agent-proc "$SCRIPT_DIR/fm-agent-proc-lib.sh" "$scan_table"; then
    rm -f -- "$scan_table" 2>/dev/null
    return 0
  fi
  printf '%s\n' "$now" > "$STAMP" 2>/dev/null || true

  # The required line first: it comes from the bounded table read alone and is
  # printed and recorded before any optional claim comparison runs, so a slow
  # landed test can never starve the intent's one dead-lane wake. A table that
  # was read but holds no recognizable agent is death only when the lane's own
  # harness is one the shared vocabulary can name.
  ids=
  while IFS=$'\x1f' read -r id wt claim pr harness; do
    [ -n "$wt" ] || continue
    FM_AGENT_PROC_TABLE=$scan_table fm_agent_proc_worktree_verdict "$wt"
    case $? in
      0) ;;
      1) fm_agent_proc_recognizes "$harness" || continue
         ids="${ids:+$ids,}$id" ;;
      *) ;;
    esac
  done <<EOF
$rows
EOF
  rm -f -- "$scan_table" 2>/dev/null
  findings=
  extra=
  if [ -n "$ids" ]; then
    line="fleet-integrity: no live agent process in the worktree of $ids - each is a dead lane still holding its worktree; read it with bin/fm-crew-state.sh <id>, then relaunch or tear it down"
    line=$(printf '%s' "$line" | cut -c1-"$MAX_LINE")
    findings=$line
    printf '%s\n' "$findings" > "$RECORD" 2>/dev/null || true
    printf '%s\n' "$findings"
  fi

  deadline=$(($(date +%s) + POLL_BUDGET))
  while IFS=$'\x1f' read -r id wt claim pr harness; do
    [ -n "$wt" ] || continue
    case "$claim" in
      done|failed) ;;
      *) continue ;;
    esac
    remaining=$((deadline - $(date +%s)))
    [ "$remaining" -ge 1 ] || continue
    seconds=$GIT_READ_CAP
    [ "$seconds" -le "$remaining" ] || seconds=$remaining
    work=$(lane_worktree_work "$wt" "$seconds") || continue
    IFS=$'\t' read -r dirty unpushed <<EOF
$work
EOF
    if [ "$dirty" -gt 0 ]; then
      line="fleet-integrity: lane $id claims $claim and its worktree $wt has $dirty uncommitted file(s) - the claim and the worktree disagree; read it with bin/fm-crew-state.sh $id, then land, relaunch, or tear it down"
    elif [ "$unpushed" -gt 0 ]; then
      remaining=$((deadline - $(date +%s)))
      [ "$remaining" -ge 1 ] || continue
      seconds=$LANDED_CAP
      [ "$seconds" -le "$remaining" ] || seconds=$remaining
      branch=$(fm_run_timed "$seconds" git -C "$wt" rev-parse --abbrev-ref HEAD 2>/dev/null) || branch=HEAD
      [ -n "$branch" ] || branch=HEAD
      landed_rc=0
      lane_landed_verdict "$wt" "$branch" "$pr" "$seconds" || landed_rc=$?
      [ "$landed_rc" -eq 1 ] || continue
      line="fleet-integrity: lane $id claims $claim and its worktree $wt has $unpushed commit(s) not on any remote and not landed - the claim and the worktree disagree; read it with bin/fm-crew-state.sh $id, then land, relaunch, or tear it down"
    else
      continue
    fi
    line=$(printf '%s' "$line" | cut -c1-"$MAX_LINE")
    extra="${extra:+$extra$'\n'}$line"
  done <<EOF
$rows
EOF

  if [ -n "$extra" ]; then
    printf '%s\n' "$extra"
    findings="${findings:+$findings$'\n'}$extra"
  fi

  [ -n "$findings" ] || { rm -f -- "$RECORD" 2>/dev/null; return 0; }

  printf '%s\n' "$findings" > "$RECORD" 2>/dev/null || true
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
