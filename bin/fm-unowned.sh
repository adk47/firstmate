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
#   NO-LANE <item> <why>    a task record says work is under way but its endpoint is dead
#   STALE-DONE <task> <why> a task says done/landed but its PR is still open
# Prints nothing and exits 0 when everything that claims to be in flight is
# actually owned; exits 1 when it printed at least one line; exits 2 when it
# could not read the backlog at all (and says why on stderr).
#
# A queued item is the queue, not an alarm: nothing claims to be building it
# yet, so it is not reported here. A held item is the captain's, and a hold
# with a date is a date gate, so neither is reported either.
#
# It never writes, kills, or dispatches. It is a read: firstmate acts on what
# it prints. Each probe degrades to silence rather than to a false alarm: a
# backlog listing the tool refuses is reported on stderr and exit 2, an
# endpoint whose state cannot be read is skipped, and a PR the forge cannot
# answer for is skipped.
#
# Usage: bin/fm-unowned.sh
#   FM_HOME            the home to read (default: this script's repo root)
#   FM_UNOWNED_TIMEOUT seconds allowed per endpoint-state read (default 20)
set -uo pipefail
FM_HOME="${FM_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
export FM_HOME
STATE="$FM_HOME/state"
BACKLOG="$FM_HOME/data/backlog.md"
TIMEOUT="${FM_UNOWNED_TIMEOUT:-20}"
[ -f "$BACKLOG" ] || { echo "fm-unowned: no backlog at $BACKLOG" >&2; exit 2; }
command -v tasks-axi >/dev/null 2>&1 || { echo "fm-unowned: tasks-axi not on PATH" >&2; exit 2; }

fail=0

# One backlog state as a list of ids. tasks-axi prints a TOON table whose rows
# are `  <id>,<state>,...`; the id is the first field. A listing the tool
# refuses is a read failure, not an empty state.
backlog_ids() {  # <state>
  local out
  out=$(tasks-axi list --file "$BACKLOG" --state "$1" 2>&1) || {
    echo "fm-unowned: tasks-axi list --state $1 failed: $out" >&2
    return 1
  }
  printf '%s\n' "$out" | sed -n 's/^  \([a-z0-9][a-z0-9-]*\),.*/\1/p'
}

# 1. Items the backlog says are in flight with no task record behind them.
in_flight=$(backlog_ids in_flight) || exit 2
while IFS= read -r id; do
  [ -n "$id" ] || continue
  [ -f "$STATE/$id.meta" ] && continue
  echo "UNOWNED $id backlog says in flight but no task record exists: nothing is building this and nothing will report on it"
  fail=1
done <<< "$in_flight"

# 2. Task records whose endpoint is dead while their status still claims work
#    under way. A task the captain ordered left stopped is not a missing lane.
for m in "$STATE"/*.meta; do
  [ -f "$m" ] || continue
  id="$(basename "$m" .meta)"
  [ -f "$STATE/$id.stopped" ] && continue
  last="$(grep -E '^(working|spawned)' "$STATE/$id.status" 2>/dev/null | tail -1)"
  [ -n "$last" ] || continue
  st="$(timeout "$TIMEOUT" "$FM_HOME/bin/fm-crew-state.sh" "$id" 2>/dev/null | head -1)"
  case "$st" in
    *dead*|*"no window"*) echo "NO-LANE $id its status says '${last%%:*}' but the endpoint is dead"; fail=1 ;;
  esac
done

# 3. done/landed claims whose PR is still open. The URL is the last one the
#    task's own status log recorded; a forge that cannot answer is skipped.
for m in "$STATE"/*.meta; do
  [ -f "$m" ] || continue
  id="$(basename "$m" .meta)"
  grep -qE '^(done|landed)' "$STATE/$id.status" 2>/dev/null || continue
  url="$(grep -oE 'https://github.com/[^ )]+/pull/[0-9]+' "$STATE/$id.status" 2>/dev/null | tail -1)"
  [ -n "$url" ] || continue
  repo="$(printf '%s' "$url" | sed -E 's#https://github.com/([^/]+/[^/]+)/pull/.*#\1#')"
  num="$(printf '%s' "$url" | grep -oE '[0-9]+$')"
  pr_state="$(gh pr view "$num" --repo "$repo" --json state --jq .state 2>/dev/null)"
  [ "$pr_state" = "OPEN" ] && { echo "STALE-DONE $id claims done but $url is still OPEN"; fail=1; }
done

exit "$fail"
