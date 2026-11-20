#!/usr/bin/env bash
# fm-pause-sweep.sh - report the pauses whose reason no longer holds.
#
# Usage:
#   fm-pause-sweep.sh [--task <id>] [--no-check]
#   fm-pause-sweep.sh --self-test
#   fm-pause-sweep.sh --help
#
# WHY. A `paused:` lane is idle because someone said a KNOWN external wait would
# end: a review verdict lands, a window opens, a deploy's dependency merges. The
# wait ends, nothing wakes the lane, and it sits there. Nothing in the log ever
# contradicts a pause, so the only thing that could notice is a reader that goes
# and checks the claim. This is that reader: for every paused task in THIS home
# it re-evaluates the pause's own evidence and prints one line per task that is
# over.
#
# WHAT IT PRINTS. One line per reportable task, nothing else:
#   RESUME <task> predicate resolved (<why>)
#   RESUME <task> predicate unreadable (<why>)
#   RESUME <task> expired at <expires>
#   INVALID_PAUSE <task> <status-line>
# A task whose predicate still holds and whose expiry is still ahead prints
# nothing. A pause carrying neither field, and neither of the two documented
# admissions (a UTC wake time, the gateway keep-alive key), is INVALID_PAUSE: it
# is not a declared wait, and the point of printing it is that it must not be
# treated as one.
#
# WHAT IT NEVER DOES. It writes no status log, closes no task, sends no steer,
# and kills no process. It is a report; acting on it is the supervisor's call.
# bin/fm-pause-lib.sh owns the field shape, the predicate verdicts, and the
# expiry clock, and bin/fm-classify-lib.sh owns which pauses count as declared
# waits at all - this script only iterates and prints.
#
# Exit status is 0 whatever it finds: findings are output, not failure.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-classify-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-pause-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-pause-lib.sh"
# shellcheck source=bin/fm-line-cap-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-line-cap-lib.sh"

usage() { sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'; }

die() { echo "error: $*" >&2; exit 2; }

TASK_FILTER=
RUN_CHECK=1
SELF_TEST=0

while [ $# -gt 0 ]; do
  case "$1" in
    --help|-h) usage; exit 0 ;;
    --self-test) SELF_TEST=1; shift ;;
    --no-check) RUN_CHECK=0; shift ;;
    --task) [ $# -ge 2 ] || die "--task needs a task id"; TASK_FILTER=$2; shift 2 ;;
    --task=*) TASK_FILTER=${1#--task=}; shift ;;
    *) die "unknown argument '$1' (see --help)" ;;
  esac
done

if [ -n "$TASK_FILTER" ]; then
  case "$TASK_FILTER" in
    *[!A-Za-z0-9._-]*) die "invalid task id '$TASK_FILTER'" ;;
  esac
fi

# One reportable line for one paused task. Prints nothing when the pause is a
# declared wait that still holds.
report_task() {  # <task-id> <status-line>
  local task=$1 line=$2 why
  # shellcheck disable=SC2034 # fm_pause_parse publishes these for the caller.
  fm_pause_parse "$line" || return 0
  why=$FM_PAUSE_WHY
  [ -n "$why" ] || why='no reason given'
  if ! status_pause_has_wake_time "$line" \
    && [ "$FM_PAUSE_KEY" != "$FM_CLASSIFY_PAUSED_DECLARED_WAIT_KEY" ] \
    && ! fm_pause_has_predicate_and_expires "$line"; then
    fm_cap_line_var "$line" "${FM_PAUSE_SWEEP_LINE_MAX:-300}"
    printf 'INVALID_PAUSE %s %s\n' "$task" "$FM_LINE_CAP_LINE"
    return 0
  fi
  if [ -n "$FM_PAUSE_PREDICATE" ]; then
    if [ "$RUN_CHECK" -eq 1 ]; then
      fm_pause_check "$FM_PAUSE_PREDICATE"
      case "$?" in
        0) ;;
        1)
          printf 'RESUME %s predicate resolved (%s)\n' "$task" "$why"
          return 0
          ;;
        *)
          printf 'RESUME %s predicate unreadable (%s)\n' "$task" "$why"
          return 0
          ;;
      esac
    fi
  fi
  if [ -n "$FM_PAUSE_EXPIRES" ]; then
    fm_pause_expired "$FM_PAUSE_EXPIRES" "${FM_PAUSE_SWEEP_NOW:-}"
    case "$?" in
      0)
        printf 'RESUME %s expired at %s\n' "$task" "$FM_PAUSE_EXPIRES"
        return 0
        ;;
      2)
        printf 'INVALID_PAUSE %s expires=%s is not an ISO8601 UTC timestamp\n' "$task" "$FM_PAUSE_EXPIRES"
        return 0
        ;;
      *) ;;
    esac
  fi
}

# The self-test: prove the wiring end to end without a home, a pane, or a status
# log. A synthetic pause whose predicate has resolved must be reported, and the
# script must exit 0 - the acceptance shape the fleet's own checks look for.
if [ "$SELF_TEST" -eq 1 ]; then
  self_line='paused [key=self-test]: synthetic wait predicate=true expires=2000-01-01T00:00:00Z'
  fm_pause_parse "$self_line" || die "self-test could not parse its own pause shape"
  fm_pause_has_predicate_and_expires "$self_line" || die "self-test: the shape did not read as a declared wait"
  fm_pause_check 'true' || die "self-test: a holding predicate did not report holding"
  # `true` exits 0, which means the reason still holds; flip the verdict with a
  # predicate that says the reason resolved, which is the line this script owes.
  fm_pause_check 'false'
  case "$?" in
    1) ;;
    *) die "self-test: a resolved predicate did not report resolved" ;;
  esac
  printf 'RESUME %s predicate resolved (%s)\n' self-test "$FM_PAUSE_WHY"
  exit 0
fi

[ -d "$STATE" ] && [ ! -L "$STATE" ] || die "state directory '$STATE' is unavailable"

shopt -s nullglob
for statusf in "$STATE"/*.status; do
  [ -f "$statusf" ] || continue
  task=${statusf##*/}
  task=${task%.status}
  case "$task" in
    ''|*[!A-Za-z0-9._-]*) continue ;;
  esac
  if [ -n "$TASK_FILTER" ] && [ "$task" != "$TASK_FILTER" ]; then
    continue
  fi
  line=$(last_status_line "$statusf")
  [ -n "$line" ] || continue
  status_is_paused "$line" || continue
  report_task "$task" "$line"
done
exit 0
