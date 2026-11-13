#!/usr/bin/env bash
# fm-leave-stopped.sh - record that the captain ordered a task left stopped, so
# its dead endpoint never re-alarms.
#
# Usage:
#   fm-leave-stopped.sh <task-id> mark --reason "<captain's words>"
#   fm-leave-stopped.sh <task-id> mark --exit --reason "<captain's words>"
#   fm-leave-stopped.sh <task-id> mark --force-silence --reason "<captain's words>"
#   fm-leave-stopped.sh <task-id> clear
#   fm-leave-stopped.sh --help
#
# WHY. A worker that died (a trust prompt it could not answer, a crash to the
# shell) leaves a stable idle pane behind. The watcher reports that once, as it
# should, and then keeps re-reading the same unchanged pane; bounded or not,
# every later report is a repeat of a decision the captain already made when
# the order was "leave it stopped". This marker is that decision, durable and
# readable by the watcher, so the repeat never happens and nothing about the
# worker is touched to achieve it.
#
# WHAT IT DOES. `mark` writes state/<task-id>.stopped atomically:
#   schema=fm-leave-stopped.v1
#   at=<UTC timestamp>
#   reason=<text, one line>
# `clear` removes it.
# `mark --exit` first stops the task's agent through bin/fm-control.sh's `exit`
# verb, which preserves the endpoint, the worktree, and every uncommitted
# change, and writes the marker only once the agent is gone. If the agent
# cannot be stopped, nothing is marked.
#
# WHAT THE MARKER MEANS DOWNSTREAM.
#   - bin/fm-watch.sh skips the task's endpoint in its pane path entirely: no
#     capture, no stale classification, no wedge timer, no steering-inbox ring,
#     no declared-wait recheck, in normal and away mode alike. Its status log is
#     still read by the signal path, because a line the task appends is a real
#     state change.
#   - Nothing else changes: the record, worktree, endpoint, and backlog item
#     stay exactly as they were. This is not teardown, not exit, not a hold.
#     bin/fm-teardown.sh removes the marker with the rest of the task's state.
#
# WHAT IT REFUSES.
#   - A task id that is not an exact state/<id>.meta record in this home.
#   - The supervision branch actor (bin/fm-lease-lib.sh's role partition):
#     this is the captain's call relayed by main, never a branch judgment.
#   - A `--reason` that is empty or spans lines.
#   - `mark` on a task whose worktree still holds a live agent process
#     (bin/fm-agent-proc-lib.sh), exit 1. The marker stops the WATCHING, not
#     the agent: marking a running agent leaves it working with nobody
#     supervising it, which is the opposite of "left stopped". Stop it with
#     `mark --exit`, or pass `mark --force-silence` to silence a running agent
#     on purpose; that still warns and names the process.
#     Only a process that was found refuses. A process table that cannot be
#     read is no evidence either way and does not block the captain's order.
# A working reading with no agent process does not refuse `mark`: a dead or
# dropped-to-shell terminal can keep a stale busy footer that
# bin/fm-crew-state.sh still reads as working, and that is exactly the endpoint
# the captain ordered left alone. `mark` records the marker anyway and prints a
# warning naming the current reading.
#
# Without `--exit` it never relaunches, interrupts, exits, trusts, or otherwise
# drives the worker. It never touches a project, and no form of it removes a
# task record, a worktree, or an endpoint.
#
# Environment: FM_LEAVE_STOPPED_CONTROL_BIN (the control plane `--exit` calls,
# default bin/fm-control.sh), FM_LEAVE_STOPPED_EXIT_WAIT (seconds to wait for
# the agent process to leave the worktree after a successful exit, default 10),
# FM_AGENT_PROC_TABLE (bin/fm-agent-proc-lib.sh).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

usage() {
  sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# The live-agent read behind mark's refusal.
# shellcheck source=bin/fm-agent-proc-lib.sh
. "$SCRIPT_DIR/fm-agent-proc-lib.sh"
# shellcheck source=bin/fm-lease-lib.sh
. "$SCRIPT_DIR/fm-lease-lib.sh"
# The authoritative current-state read behind the working warning
# (crew_absorb_class; FM_CREW_STATE_BIN is its documented seam).
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"

die() { echo "error: $*" >&2; exit 2; }

ID=${1:-}
VERB=${2:-}
[ -n "$ID" ] && [ -n "$VERB" ] || { usage >&2; exit 2; }
fm_task_id_creation_valid "$ID" || die "'$ID' is not a valid task id"
case "$ID" in
  fm-*) [ ! -f "$STATE/${ID#fm-}.meta" ] || die "'$ID' is a window label, not a task id; pass the exact task id '${ID#fm-}'" ;;
esac
[ -d "$STATE" ] && [ ! -L "$STATE" ] || die "state directory '$STATE' is unavailable"
META="$STATE/$ID.meta"
MARKER="$STATE/$ID.stopped"

REASON=
EXIT_AGENT=0
FORCE_SILENCE=0
shift 2
while [ "$#" -gt 0 ]; do
  case "$1" in
    --exit)
      [ "$VERB" = mark ] || die "--exit applies to 'mark' only"
      EXIT_AGENT=1
      shift
      ;;
    --force-silence)
      [ "$VERB" = mark ] || die "--force-silence applies to 'mark' only"
      FORCE_SILENCE=1
      shift
      ;;
    --reason)
      [ "$VERB" = mark ] || die "--reason applies to 'mark' only"
      [ "$#" -ge 2 ] || die "--reason requires a value"
      REASON=$2
      shift 2
      ;;
    --reason=*)
      [ "$VERB" = mark ] || die "--reason applies to 'mark' only"
      REASON=${1#--reason=}
      shift
      ;;
    *) die "unknown argument '$1'" ;;
  esac
done

case "$VERB" in
  mark|clear) ;;
  *) die "unknown verb '$VERB' (expected mark or clear)" ;;
esac

[ -f "$META" ] || die "no task '$ID' in $STATE (fm-leave-stopped resolves an exact task id only)"

case "$VERB" in
  clear)
    fm_lease_forbid_branch "leave-stopped clear (fm-leave-stopped)"
    if [ ! -e "$MARKER" ]; then
      echo "not marked: task $ID was not left stopped (nothing to clear)"
      exit 0
    fi
    rm -f -- "$MARKER" || die "could not remove state/$ID.stopped"
    echo "cleared: task $ID is supervised again (state/$ID.stopped removed)"
    exit 0
    ;;
esac

# --- mark -------------------------------------------------------------------
fm_lease_forbid_branch "leave-stopped mark (fm-leave-stopped)"
[ -n "$REASON" ] || die "mark requires --reason \"<the captain's words>\""
case "$REASON" in
  *$'\n'*|*$'\r'*) die "--reason must be a single line" ;;
esac

[ "$EXIT_AGENT" = 0 ] || [ "$FORCE_SILENCE" = 0 ] || die "--exit and --force-silence are opposite orders; pass one"

# The agent processes in the task's worktree: "<name> pid <pid>" for each,
# comma-joined, or nothing when none was found or the table could not be read.
live_agents() {
  local wt rows
  wt=$(fm_meta_get "$META" worktree)
  [ -n "$wt" ] || return 0
  rows=$(fm_agent_proc_in_worktree "$wt" 2>/dev/null) || return 0
  printf '%s\n' "$rows" | awk -F '\t' 'NF >= 2 { printf "%s%s pid %s", sep, $2, $1; sep = ", " }'
}

AGENTS=$(live_agents)
if [ "$EXIT_AGENT" = 1 ]; then
  CONTROL_BIN=${FM_LEAVE_STOPPED_CONTROL_BIN:-$SCRIPT_DIR/fm-control.sh}
  if ! FM_HOME="$FM_HOME" "$CONTROL_BIN" "$ID" exit; then
    echo "error: task $ID was not marked - its agent could not be stopped${AGENTS:+ ($AGENTS still in its worktree)}; nothing was changed. Resolve the refusal above, or pass --force-silence to silence it while it runs" >&2
    exit 1
  fi
  waited=0
  exit_wait=${FM_LEAVE_STOPPED_EXIT_WAIT:-10}
  case "$exit_wait" in ''|*[!0-9]*) exit_wait=10 ;; esac
  AGENTS=$(live_agents)
  while [ -n "$AGENTS" ] && [ "$waited" -lt "$exit_wait" ]; do
    sleep 1
    waited=$((waited + 1))
    AGENTS=$(live_agents)
  done
  if [ -n "$AGENTS" ]; then
    echo "error: task $ID was not marked - the exit was reported complete but an agent is still in its worktree ($AGENTS); nothing was marked" >&2
    exit 1
  fi
elif [ -n "$AGENTS" ]; then
  if [ "$FORCE_SILENCE" = 0 ]; then
    echo "error: task $ID was not marked - its worktree still holds a live agent ($AGENTS). The marker only stops the watching, so that agent would keep running unsupervised. Stop it and mark with 'fm-leave-stopped.sh $ID mark --exit --reason ...', or silence it while it runs with '--force-silence'" >&2
    exit 1
  fi
  echo "warning: task $ID still has a live agent ($AGENTS); silencing it on --force-silence - the agent keeps running and nothing will watch it until 'fm-leave-stopped.sh $ID clear'" >&2
elif [ "$(crew_absorb_class "$ID")" = working ]; then
  current=$("$FM_CREW_STATE_BIN" "$ID" 2>/dev/null) || true
  echo "warning: task $ID currently reads as working ($current); recording the captain's order anyway - the marker only silences the watcher and never stops, kills, or relaunches the worker" >&2
fi

tmp=$(mktemp "$STATE/.$ID.stopped.XXXXXX") || die "could not create the marker"
{
  printf 'schema=fm-leave-stopped.v1\n'
  printf 'at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf 'reason=%s\n' "$REASON"
} > "$tmp" || { rm -f "$tmp"; die "could not write the marker"; }
mv -f "$tmp" "$MARKER" || { rm -f "$tmp"; die "could not publish state/$ID.stopped"; }
echo "marked: task $ID is left stopped on the captain's order (state/$ID.stopped); its endpoint will not re-alarm until 'fm-leave-stopped.sh $ID clear'"
