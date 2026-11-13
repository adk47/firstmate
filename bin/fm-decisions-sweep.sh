#!/usr/bin/env bash
# fm-decisions-sweep.sh - close the open decision records nobody is waiting on.
#
# Usage:
#   fm-decisions-sweep.sh [--dry-run] [--task <id>] [--reason <name>[,<name>...]] [--no-forge]
#   fm-decisions-sweep.sh --apply [--task <id>] [--reason <name>[,<name>...]] [--no-forge]
#   fm-decisions-sweep.sh --help
#
# WHY. A `needs-decision`, `blocked`, or time-less `paused` status line stays an
# open decision record until a `resolved` line carrying its key lands
# (bin/fm-classify-lib.sh owns that fold). A task that finished, shipped, or
# died without writing that line leaves its record open forever, and every wake
# drain then prints it under OPEN DECISIONS. Enough of them and the handful that
# really wait on someone are buried. This sweep finds the records that outlived
# their task and closes them, so what remains open is what is actually open.
#
# WHAT IT READS. Every state/<id>.status in THIS home, one fold per file. It
# never looks at another home, a pane, or a transcript.
#
# WHEN A RECORD IS STALE. Its task's status log has not been written for 48
# hours, and the first of these holds, in this order:
#   last-line-done      the task's newest status line is `done`
#   last-line-resolved  the task's newest status line is `resolved`
#   pr-merged           the task's recorded PR (meta `pr=`) is merged
#   pr-closed           the task's recorded PR is closed without merging
#   no-process-48h      no agent process runs in the task's worktree
#   no-record-48h       the status log has no task record (no state/<id>.meta),
#                       so no process can be attributed to it
# "No agent process" is bin/fm-agent-proc-lib.sh's `dead` and nothing weaker: a
# process table that could not be read, or a harness it cannot name, is not
# evidence of absence. A merged PR is read from the merge outcome this home
# already recorded (bin/fm-pr-lib.sh), else from the forge with `gh`; a GitLab
# merge request, a missing `gh`, or `--no-forge` leaves the PR state unknown,
# which is never a reason to close.
#
# WHY THE 48 HOURS COME FIRST. None of those reasons is about the record
# itself. A standing lane writes `done` after every item, records the PR of its
# latest item, and writes `resolved` for one key while a dozen unrelated asks
# stay open under others, so on a log still being written each reason is true
# of records that are very much waiting on someone. What makes a reason
# evidence is that the task then went quiet. The quiet period therefore gates
# every reason, for a dead task as much as a live one: a lane whose agent just
# crashed keeps its asks until it has been silent for two days.
#
# The age clock is the status log's modification time, which is the age of its
# NEWEST line. Every open record in the log is at least that old, so the clock
# can only err toward leaving a record alone.
#
# WHAT IT NEVER TOUCHES.
#   protected  a task whose log was written in the last 48 hours. This is
#              checked before any reason.
#   held       a record a person or another mechanism still owns:
#                secondmate       the task is a secondmate; its holds are routed
#                                 work, and an idle secondmate is healthy
#                reserved-key     the key belongs to a namespace only its owner
#                                 may close (pending-reply-*)
#                captain-call     the task, the key, or the legacy
#                                 <task>-decision-<key> id is an open captain
#                                 call in the backlog (fm-captain-hold.sh open-ids)
#                backlog-unread   the backlog could not be read, so a captain
#                                 call cannot be ruled out
#                leased           the other supervision actor holds the task
#                                 (bin/fm-lease-lib.sh)
#                changed          the log was written while the sweep ran
#   kept       quiet for 48 hours but no reason holds: an agent is still in the
#              worktree (agent-alive) or its absence could not be established
#              (liveness-unknown). The record stays open and is not listed
#              unless `--task` names its task.
#
# A stale record is not thereby a worthless one. The sweep cannot read whether
# an ask still matters; it reads only that its task stopped. Read the dry run's
# notes before applying, and use `--reason` to apply the reasons you checked.
#
# WHAT --apply DOES. For each stale record it appends
#   resolved [key=<key>]: auto-closed by sweep (<reason>)
# to that task's status log through the same append the answer path uses
# (bin/fm-wake-lib.sh), so the line does not wake this session about its own
# write, then re-reads the fold and reports `failed` if the key is still open.
# That one line is everything it writes. It never deletes or rewrites a status
# line, a task record, a worktree, or an endpoint, and it never touches the
# backlog. A sweep close is reversible by hand: the original line is still in
# the log, and re-appending it reopens the record.
# bin/fm-crew-state.sh looks through a sweep close to the `done` or `failed`
# line behind it, so closing a finished task's records does not change what
# that task reads as.
#
# `--dry-run` is the default and writes nothing. `--reason` limits either mode
# to the named reasons. `--task` limits it to one status log.
#
# OUTPUT. One TAB-separated row per record, then the counts:
#   <close|closed|held|protected|kept|failed>\t<task>\t<key>\t<reason>\t<note>
#   count\t<verdict>\t<reason>\t<n>
#   summary\t<dry-run|apply>\tclose=<n>\theld=<n>\tprotected=<n>\tkept=<n>\tfailed=<n>
# `close` is a dry-run row a matching --apply would write; `closed` is written.
# Exit 0 on a completed sweep, 1 when any record failed to close, 2 on usage.
#
# Environment: FM_DECISIONS_SWEEP_STALE_SECS (default 172800, the 48 hours),
# FM_DECISIONS_SWEEP_NOW (epoch seconds, test seam for the clock),
# FM_DECISIONS_SWEEP_HOLD_BIN (the captain-call reader, default
# bin/fm-captain-hold.sh), FM_DECISIONS_SWEEP_PR_TIMEOUT (seconds per forge
# read, default 15), FM_AGENT_PROC_TABLE (bin/fm-agent-proc-lib.sh).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

usage() {
  sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'
}

die() { echo "error: $*" >&2; exit 2; }

MODE=dry-run
ONLY_TASK=
ONLY_REASONS=
FORGE=1
while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --dry-run) MODE=dry-run; shift ;;
    --apply) MODE=apply; shift ;;
    --no-forge) FORGE=0; shift ;;
    --task) [ "$#" -ge 2 ] || die "--task requires a task id"; ONLY_TASK=$2; shift 2 ;;
    --task=*) ONLY_TASK=${1#--task=}; shift ;;
    --reason) [ "$#" -ge 2 ] || die "--reason requires a value"; ONLY_REASONS=$2; shift 2 ;;
    --reason=*) ONLY_REASONS=${1#--reason=}; shift ;;
    *) die "unknown argument '$1'" ;;
  esac
done

REASONS='last-line-done last-line-resolved pr-merged pr-closed no-process-48h no-record-48h'
if [ -n "$ONLY_REASONS" ]; then
  for _r in $(printf '%s' "$ONLY_REASONS" | tr ',' ' '); do
    case " $REASONS " in
      *" $_r "*) ;;
      *) die "unknown reason '$_r' (expected one of: $REASONS)" ;;
    esac
  done
  ONLY_REASONS=" $(printf '%s' "$ONLY_REASONS" | tr ',' ' ') "
fi
case "$ONLY_TASK" in
  '') ;;
  *[!A-Za-z0-9._-]*) die "'$ONLY_TASK' is not a valid task id" ;;
esac
[ -d "$STATE" ] && [ ! -L "$STATE" ] || die "state directory '$STATE' is unavailable"

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-line-cap-lib.sh
. "$SCRIPT_DIR/fm-line-cap-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-agent-proc-lib.sh
. "$SCRIPT_DIR/fm-agent-proc-lib.sh"
# shellcheck source=bin/fm-lease-lib.sh
. "$SCRIPT_DIR/fm-lease-lib.sh"
# The sweep rewrites decision records main and the branch both read; like the
# other record-wide mutations it is main's alone.
[ "$MODE" != apply ] || fm_lease_forbid_branch "decision sweep (fm-decisions-sweep --apply)"

STALE_SECS=${FM_DECISIONS_SWEEP_STALE_SECS:-172800}
case "$STALE_SECS" in ''|*[!0-9]*) die "FM_DECISIONS_SWEEP_STALE_SECS must be a number of seconds" ;; esac
NOW=${FM_DECISIONS_SWEEP_NOW:-$(date +%s)}
case "$NOW" in ''|*[!0-9]*) die "FM_DECISIONS_SWEEP_NOW must be epoch seconds" ;; esac
PR_TIMEOUT=${FM_DECISIONS_SWEEP_PR_TIMEOUT:-15}
HOLD_BIN=${FM_DECISIONS_SWEEP_HOLD_BIN:-$SCRIPT_DIR/fm-captain-hold.sh}
RESOLVE_VERB=${FM_CLASSIFY_RESOLVE_VERB:-$FM_CLASSIFY_RESOLVE_VERB_DEFAULT}

SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/fm-decisions-sweep.XXXXXX") || die "could not create a scratch directory"
trap 'rm -rf "$SCRATCH"' EXIT
ROWS="$SCRATCH/rows"
: > "$ROWS"

# One process table for the whole sweep: every task is judged against the same
# instant, and the fleet is read once rather than once per task. A table that
# cannot be read is left unreadable, which bin/fm-agent-proc-lib.sh reports as
# no evidence, so no task reads dead on a failed read.
if [ -z "${FM_AGENT_PROC_TABLE:-}" ]; then
  if fm_agent_proc_table > "$SCRATCH/procs" 2>/dev/null; then
    FM_AGENT_PROC_TABLE="$SCRATCH/procs"
  else
    FM_AGENT_PROC_TABLE="$SCRATCH/procs-unreadable"
  fi
  export FM_AGENT_PROC_TABLE
fi

row() {  # <verdict> <task> <key> <reason> <note>
  local note
  note=$(printf '%s' "$5" | tr '\t\r\n' '   ' | LC_ALL=C tr -d '\000-\037\177')
  fm_cap_line_var "$note" 160
  printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$FM_LINE_CAP_LINE" | tee -a "$ROWS"
}

# --- captain calls ----------------------------------------------------------
# Read once, on the first record that has a reason to close. CAPTAIN_IDS is a
# newline-wrapped set; CAPTAIN_READ is 1 read, 0 not yet, 2 could not be read.
CAPTAIN_READ=0
CAPTAIN_IDS=$'\n'
read_captain_calls() {
  local out
  [ "$CAPTAIN_READ" = 0 ] || return 0
  if out=$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" "$HOLD_BIN" open-ids 2>/dev/null); then
    CAPTAIN_READ=1
    CAPTAIN_IDS=$'\n'"$out"$'\n'
  else
    CAPTAIN_READ=2
  fi
}

# Why <task>'s <key> record must be left to its owner, or nothing when the
# sweep may close it.
record_hold() {  # <task> <key>
  local task=$1 key=$2 probe id
  probe="$FM_CLASSIFY_SWEEP_CLOSE_NOTE_PREFIX"
  if ! _fm_decision_key_transition_allowed "$key" "$probe"; then
    printf 'reserved-key'
    return 0
  fi
  read_captain_calls
  if [ "$CAPTAIN_READ" != 1 ]; then
    printf 'backlog-unread'
    return 0
  fi
  for id in "$task" "$key" "$task-decision-$key"; do
    case "$CAPTAIN_IDS" in
      *$'\n'"$id"$'\n'*) printf 'captain-call'; return 0 ;;
    esac
  done
  return 0
}

# --- recorded PR ------------------------------------------------------------
# merged | closed | open | unknown for the task's recorded PR.
pr_state() {  # <task> <pr-url>
  local task=$1 url=$2 state
  fm_pr_url_parse "$url" || { printf 'unknown'; return 0; }
  if fm_pr_poll_merge_already_notified "$STATE" "$task" \
    "$FM_PR_PROVIDER" "$FM_PR_HOST" "$FM_PR_PATH" "$FM_PR_NUMBER" 2>/dev/null; then
    printf 'merged'
    return 0
  fi
  if [ "$FORGE" != 1 ] || [ "$FM_PR_PROVIDER" != github ] || ! command -v gh >/dev/null 2>&1; then
    printf 'unknown'
    return 0
  fi
  state=$(fm_run_timed "$PR_TIMEOUT" gh pr view "$FM_PR_URL" --json state -q .state 2>/dev/null) || state=
  case "$state" in
    MERGED) printf 'merged' ;;
    CLOSED) printf 'closed' ;;
    OPEN) printf 'open' ;;
    *) printf 'unknown' ;;
  esac
}

reason_wanted() {  # <reason>
  [ -z "$ONLY_REASONS" ] && return 0
  case "$ONLY_REASONS" in *" $1 "*) return 0 ;; *) return 1 ;; esac
}

# One row per "<key>\t<reason>\t<note>" line of <closes>, under one verdict.
rows_for_closes() {  # <verdict> <task> <reason-or-empty> <closes>
  local key reason note
  while IFS=$'\t' read -r key reason note; do
    [ -n "$key" ] || continue
    row "$1" "$2" "$key" "${3:-$reason}" "$note"
  done <<EOF
$4
EOF
}

# Append the close for each "<key>\t<reason>\t<note>" line of <closes>, then
# confirm against a fresh fold. A subshell, so a lease refusal (which exits)
# ends this task's attempt only; the caller reports it from the exit status.
apply_task() (  # <task> <status-file> <size-at-fold> <closes>
  task=$1 file=$2 folded_size=$3 closes=$4
  trap 'fm_lease_guard_release 2>/dev/null || true' EXIT
  fm_lease_guard "$task" "decision sweep (fm-decisions-sweep)" 2>/dev/null || exit "$FM_LEASE_REFUSE_EXIT"
  if [ "$(_fm_status_file_size "$file" 2>/dev/null)" != "$folded_size" ]; then
    rows_for_closes held "$task" changed "$closes"
    exit 0
  fi
  written=''
  while IFS=$'\t' read -r key reason note; do
    [ -n "$key" ] || continue
    fm_cap_line_var "$RESOLVE_VERB [key=$key]: $FM_CLASSIFY_SWEEP_CLOSE_NOTE_PREFIX$reason)"
    rc=0
    fm_wake_status_append_self_announced "$STATE" "$file" "$FM_LINE_CAP_LINE" || rc=$?
    if [ "$rc" -eq 2 ]; then
      row failed "$task" "$key" "$reason" "the close line could not be appended"
      continue
    fi
    written="$written$key"$'\t'"$reason"$'\t'"$note"$'\n'
  done <<EOF
$closes
EOF
  still=$(status_open_decisions "$file")
  while IFS=$'\t' read -r key reason note; do
    [ -n "$key" ] || continue
    if _fm_open_set_has "$still" "$key"; then
      row failed "$task" "$key" "$reason" "still open after the close line (reopened concurrently, or the fold refused it)"
    else
      row closed "$task" "$key" "$reason" "$note"
    fi
  done <<EOF
$written
EOF
  exit 0
)

sweep_task() {  # <status-file>
  local file=$1 task open meta last verb mtime age size
  local kind='' pr='' wt='' harness='' backend='' target='' live=unrecorded
  local reason='' why='' key dverb note hold closes='' rc
  task=${file##*/}
  task=${task%.status}
  case "$task" in ''|*[!A-Za-z0-9._-]*) return 0 ;; esac
  [ -z "$ONLY_TASK" ] || [ "$task" = "$ONLY_TASK" ] || return 0
  [ -f "$file" ] && [ -r "$file" ] && [ ! -L "$file" ] || return 0
  size=$(_fm_status_file_size "$file" 2>/dev/null) || size=
  open=$(status_open_decisions "$file")
  [ -n "$open" ] || return 0

  meta="$STATE/$task.meta"
  last=$(last_status_line_behind_sweep "$file")
  verb=$(status_line_verb "$last")
  mtime=$(_fm_status_file_mtime "$file")
  case "$mtime" in ''|*[!0-9]*) mtime=$NOW ;; esac
  age=$((NOW - mtime))

  if [ -f "$meta" ] && [ ! -L "$meta" ]; then
    kind=$(fm_meta_get "$meta" kind)
    pr=$(fm_meta_get "$meta" pr)
    wt=$(fm_meta_get "$meta" worktree)
    harness=$(fm_meta_get "$meta" harness)
    backend=$(fm_backend_of_meta "$meta")
    target=$(fm_backend_target_of_meta "$meta")
    if [ "$kind" = secondmate ] || [ -n "$(fm_meta_get "$meta" remote_host)" ]; then
      live=secondmate
    else
      fm_agent_liveness "$wt" "$harness" "$backend" "$target"
      live=$FM_AGENT_LIVE
    fi
  fi

  # The order below is the contract in the header: never-touch first, then the
  # first reason that holds.
  if [ "$live" = secondmate ]; then
    why=held:secondmate
  elif [ "$age" -lt "$STALE_SECS" ]; then
    why=protected:recent
  elif [ "$verb" = "done" ]; then
    reason="last-line-done"
  elif [ "$verb" = "$RESOLVE_VERB" ]; then
    reason="last-line-resolved"
  else
    if [ -n "$pr" ]; then
      case "$(pr_state "$task" "$pr")" in
        merged) reason="pr-merged" ;;
        closed) reason="pr-closed" ;;
      esac
    fi
    if [ -z "$reason" ]; then
      case "$live" in
        dead) reason="no-process-48h" ;;
        unrecorded) reason="no-record-48h" ;;
      esac
    fi
    if [ -z "$reason" ]; then
      case "$live" in
        alive) why=kept:agent-alive ;;
        *) why=kept:liveness-unknown ;;
      esac
    fi
  fi
  if [ -n "$reason" ] && ! reason_wanted "$reason"; then
    why=kept:reason-not-selected
    reason=
  fi

  while IFS=$'\t' read -r key dverb note; do
    [ -n "$key" ] || continue
    note="$dverb: $note"
    if [ -n "$why" ]; then
      case "$why" in
        kept:*)
          if [ -n "$ONLY_TASK" ]; then
            row kept "$task" "$key" "${why#kept:}" "$note"
          else
            printf 'kept\t%s\n' "${why#kept:}" >> "$SCRATCH/kept"
          fi
          ;;
        *) row "${why%%:*}" "$task" "$key" "${why#*:}" "$note" ;;
      esac
      continue
    fi
    hold=$(record_hold "$task" "$key")
    if [ -n "$hold" ]; then
      row held "$task" "$key" "$hold" "$note"
    elif [ "$MODE" = apply ]; then
      closes="$closes$key"$'\t'"$reason"$'\t'"$note"$'\n'
    else
      row close "$task" "$key" "$reason" "$note"
    fi
  done <<EOF
$open
EOF
  [ -n "$closes" ] || return 0
  rc=0
  apply_task "$task" "$file" "$size" "$closes" || rc=$?
  [ "$rc" -eq 0 ] || rows_for_closes held "$task" leased "$closes"
}

for f in "$STATE"/*.status; do
  [ -e "$f" ] || continue
  sweep_task "$f"
done

# Kept records are counted without a row each: they are the open set, which
# the wake drain already prints.
: >> "$SCRATCH/kept"
{ cut -f1,4 "$ROWS"; cat "$SCRATCH/kept"; } | awk -F '\t' -v mode="$MODE" '
  { n[$1 "\t" $2]++; t[$1]++ }
  END {
    split("close closed held protected kept failed", order, " ")
    for (i = 1; i <= 6; i++) {
      for (k in n) {
        split(k, p, "\t")
        if (p[1] == order[i]) printf "count\t%s\t%d\n", k, n[k]
      }
    }
    closed = (mode == "apply") ? t["closed"] : t["close"]
    printf "summary\t%s\tclose=%d\theld=%d\tprotected=%d\tkept=%d\tfailed=%d\n", mode, closed, t["held"], t["protected"], t["kept"], t["failed"]
  }
'

if grep -q '^failed'$'\t' "$ROWS" 2>/dev/null; then
  exit 1
fi
exit 0
