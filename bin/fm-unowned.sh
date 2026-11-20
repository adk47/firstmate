#!/usr/bin/env bash
# fm-unowned.sh - the alarm for work that exists only as a note.
#
# WHY. A backlog item, a status note, or a "next" line that names a fix is not
# work. Work is a task with a live lane, a branch, and a landing artifact.
# Measured 2026-11-18: the Longhorn alert fix was written, reported
# "before=9 after=0" in a done line, and then sat OPEN and RED for two days
# while the alerts kept firing. Meanwhile five fixes were filed as backlog
# items with no lane at all, and nothing noticed.
#
# WHAT IT DOES. Reads this home's backlog and task records and reports, one
# line each:
#   UNOWNED <item> <why>    an in-flight backlog item with no task record at all
#   NO-LANE <item> <why>    a task record's latest status says working but its endpoint is dead
#   STALE-DONE <task> <why> a task record's latest status says done/landed but its PR is still open
# Prints nothing and exits 0 when everything that claims to be in flight is
# actually owned; exits 1 when it printed at least one line; exits 2 when it
# could not read the backlog at all (and says why on stderr).
#
# A queued item is the queue, not an alarm: nothing claims to be building it
# yet, so it is not reported here. A held item is the captain's, and a hold
# with a date is a date gate, so neither is reported either; a held item also
# still lists as in_flight, so the held ids are subtracted before reporting.
#
# It never writes, kills, or dispatches. It is a read: firstmate acts on what
# it prints. Each probe degrades to silence rather than to a false alarm: a
# backlog listing the tool refuses, or whose rows disagree with its own count,
# is reported on stderr and exit 2, an endpoint whose state cannot be read is
# skipped, and a PR the forge cannot answer for is skipped.
#
# Usage: bin/fm-unowned.sh
#   FM_HOME            the home to read (default: this script's repo root)
#   FM_UNOWNED_TIMEOUT seconds allowed per endpoint-state and PR-state read (default 20)
set -uo pipefail
FM_HOME="${FM_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
export FM_HOME
# shellcheck source=bin/fm-classify-lib.sh
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-classify-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-timeout-lib.sh"
STATE="$FM_HOME/state"
BACKLOG="$FM_HOME/data/backlog.md"
TIMEOUT="${FM_UNOWNED_TIMEOUT:-20}"
[ -f "$BACKLOG" ] || { echo "fm-unowned: no backlog at $BACKLOG" >&2; exit 2; }
command -v tasks-axi >/dev/null 2>&1 || { echo "fm-unowned: tasks-axi not on PATH" >&2; exit 2; }

fail=0

# One backlog state as a list of ids. tasks-axi prints a TOON table whose rows
# are `  <id>,<state>,...`; the id is the first field, and the id charset is the
# one the backlog library and wake lib already accept. A listing the tool
# refuses, or whose rows disagree with its stated count, is a read failure, not
# an empty state.
backlog_ids() {  # <state>
  local out count rows
  out=$(tasks-axi list --file "$BACKLOG" --state "$1" 2>&1) || {
    echo "fm-unowned: tasks-axi list --state $1 failed: $out" >&2
    return 1
  }
  count=$(printf '%s\n' "$out" | LC_ALL=C awk '/^count: [0-9]+$/ { print $2; exit }')
  case "$count" in
    ''|*[!0-9]*)
      echo "fm-unowned: tasks-axi list --state $1 printed no usable count: $out" >&2
      return 1
      ;;
  esac
  rows=$(printf '%s\n' "$out" | LC_ALL=C awk -F, '/^  [A-Za-z0-9._-]+,/ { id = $1; sub(/^ +/, "", id); print id }')
  if [ "$(printf '%s' "$rows" | LC_ALL=C awk 'END { print NR }')" -ne "$count" ]; then
    echo "fm-unowned: tasks-axi list --state $1 printed rows that disagree with count $count: $out" >&2
    return 1
  fi
  [ -z "$rows" ] || printf '%s\n' "$rows"
}

# The line a task's latest claim is graded from: its last status line, looking
# behind a trailing run of decisions-sweep closes to the claim they closed.
claimed_status_line() {  # <status-file>
  local f=$1 last line
  last=$(last_status_line "$f")
  status_line_is_sweep_close "$last" || { printf '%s\n' "$last"; return 0; }
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in *[![:space:]]*) ;; *) continue ;; esac
    status_line_is_sweep_close "$line" && continue
    last=$line
  done <<EOF
$(tail -n "${FM_STATUS_SWEEP_LOOKBACK_LINES:-400}" "$f" 2>/dev/null)
EOF
  printf '%s\n' "$last"
}

# 1. Items the backlog says are in flight with no task record behind them. A
#    held item also lists as in_flight, and the captain owns it, so it is not a
#    missing lane.
in_flight=$(backlog_ids in_flight) || exit 2
held=$(backlog_ids held) || exit 2
held_ids=" $(printf '%s\n' "$held" | tr '\n' ' ') "
while IFS= read -r id; do
  [ -n "$id" ] || continue
  case "$held_ids" in *" $id "*) continue ;; esac
  [ -f "$STATE/$id.meta" ] && continue
  echo "UNOWNED $id backlog says in flight but no task record exists: nothing is building this and nothing will report on it"
  fail=1
done <<< "$in_flight"

# 2. Task records whose endpoint is dead while their latest status still
#    claims work under way. A task the captain ordered left stopped is not a
#    missing lane.
for m in "$STATE"/*.meta; do
  [ -f "$m" ] || continue
  id="$(basename "$m" .meta)"
  [ -f "$STATE/$id.stopped" ] && continue
  last="$(claimed_status_line "$STATE/$id.status")"
  status_line_verb_core "$last"
  verb=$_FM_STATUS_VERB
  [ "$verb" = working ] || continue
  st="$(fm_run_timed "$TIMEOUT" "$FM_HOME/bin/fm-crew-state.sh" "$id" 2>/dev/null | head -1)"
  case "$st" in
    *dead*) echo "NO-LANE $id its latest status says '$verb' but the endpoint is dead"; fail=1 ;;
  esac
done

# 3. done/landed claims whose PR is still open. The canonical record is the
#    task's own `pr=` meta field; the status log's last URL is the fallback. A
#    forge that cannot answer, including one that does not answer in time, is
#    skipped.
for m in "$STATE"/*.meta; do
  [ -f "$m" ] || continue
  id="$(basename "$m" .meta)"
  last="$(claimed_status_line "$STATE/$id.status")"
  status_line_verb_core "$last"
  case "$_FM_STATUS_VERB" in
    done|landed) ;;
    *) continue ;;
  esac
  url="$(sed -n 's/^pr=\([^[:space:]]*\).*/\1/p' "$m" 2>/dev/null | tail -1)"
  [ -n "$url" ] || url="$(grep -oE 'https://github.com/[^ )]+/pull/[0-9]+' "$STATE/$id.status" 2>/dev/null | tail -1)"
  printf '%s' "$url" | grep -qE '^https://github\.com/[^/]+/[^/]+/pull/[0-9]+$' || continue
  repo="$(printf '%s' "$url" | sed -E 's#https://github.com/([^/]+/[^/]+)/pull/.*#\1#')"
  num="$(printf '%s' "$url" | grep -oE '[0-9]+$')"
  pr_state="$(fm_run_timed "$TIMEOUT" gh pr view "$num" --repo "$repo" --json state --jq .state 2>/dev/null)"
  [ "$pr_state" = "OPEN" ] && { echo "STALE-DONE $id claims done but $url is still OPEN"; fail=1; }
done

exit "$fail"
