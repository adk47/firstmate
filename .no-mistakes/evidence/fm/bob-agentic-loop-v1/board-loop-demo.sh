#!/usr/bin/env bash
# End-to-end demonstration of the board loop the way a firstmate turn meets it:
# the agenda line, the wake drain that prints it first, the audit check that
# wakes firstmate when the agenda is not driven, and the escalation/repeat
# defects the loop exists to stop.
#
# Usage: board-loop-demo.sh <repo-root>
set -u

REPO=${1:?usage: board-loop-demo.sh <repo-root>}
BOARD="$REPO/bin/fm-board.sh"
AUDIT="$REPO/bin/fm-board-audit.sh"
DRAIN="$REPO/bin/fm-wake-drain.sh"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
FM_ROOT_OVERRIDE="$WORK/no-git"
export FM_ROOT_OVERRIDE
T0=$(date +%s)

new_home() {
  HOME_DIR="$WORK/$1"
  mkdir -p "$HOME_DIR/state"
}

board() {
  FM_HOME="$HOME_DIR" FM_DATA_OVERRIDE="$HOME_DIR/data" FM_BOARD_NOW="${FM_BOARD_NOW:-$T0}" \
    "$BOARD" "$@"
}

audit() {  # <seconds after T0> [<action>]
  FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_BOARD_NOW=$((T0 + $1)) "$AUDIT" "${2:-check}"
}

drain() {  # <label>
  local out
  out=$(FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" "$DRAIN" 2>"$WORK/drain.err")
  printf '$ bin/fm-wake-drain.sh   # %s\n%s\n' "$1" "$out"
  sed 's/^/  stderr: /' "$WORK/drain.err"
}

append_wake() {
  FM_STATE_OVERRIDE="$HOME_DIR/state" bash -c '
    . "$1"; fm_wake_append "$2" "$3" "$4"
  ' _ "$REPO/bin/fm-wake-lib.sh" "$1" "$2" "$3"
}

step() { printf '\n### %s\n' "$*"; }

step 'A home with no board is unchanged: no agenda line, nothing else moved'
new_home no-board
printf '$ bin/fm-board.sh wake-line\n'
out=$(board wake-line); printf '%s\n' "${out:-<no output>}"
drain 'no board, empty queue'

step 'The agenda records the goal, its check, its state, and the next bounded action'
new_home loop
board add 'restore weekly chart freshness' \
  --check 'served range equals this week' \
  --state 'still serving last week' \
  --next 'rerun the chart build with the new window' || exit 1
board add 'land the nine drift files' \
  --check 'zero drifted files remain' \
  --state 'nine files drift' \
  --next 'commit the nine files in reviewable batches' || exit 1
printf '$ bin/fm-board.sh next\n'; board next
printf '$ bin/fm-board.sh wake-line\n'; board wake-line

step 'A busy main drain puts the agenda line ahead of its wake rows'
append_wake signal task-a.status 'signal: task-a'
drain 'one queued wake'

step 'An hour with an unblocked item and no advance wakes firstmate with the item to drive'
printf '$ bin/fm-board-audit.sh check   # +61m, unchanged board\n'
out=$(audit 3660); printf '%s\n' "$out"
printf '$ bin/fm-board-audit.sh check   # +62m, same state\n'
out=$(audit 3720); printf '%s\n' "${out:-<silent: one reminder per cadence>}"

step 'The armed check shim is what the watcher polls, and it carries the same line'
printf '$ bin/fm-board-audit.sh arm\n'; audit 0 arm
printf '$ state/board-audit.check.sh   # +92m, past the 30m reminder cadence\n'
out=$(FM_BOARD_NOW=$((T0 + 5520)) "$HOME_DIR/state/board-audit.check.sh"); printf '%s\n' "$out"
printf 'record: %s\n' "$(cat "$HOME_DIR/state/.board-audit" 2>/dev/null)"

step 'Driving the item clears the alarm instead of reporting the same state again'
printf '$ bin/fm-board.sh advance 1 "build rerun, served range equals this week" --next "watch the next scheduled build"\n'
board advance 1 'build rerun, served range equals this week' --next 'watch the next scheduled build'
printf '$ bin/fm-board-audit.sh check   # +93m, after the advance\n'
out=$(audit 5580); printf '%s\n' "${out:-<silent>}"
printf '$ bin/fm-board.sh next\n'; board next

step 'A blocker is raised to the captain at most twice, then it is a defect'
printf '$ bin/fm-board.sh block 2 "refund needs captain approval" --captain money\n'
board block 2 'refund needs captain approval' --captain money
for n in 1 2 3; do
  printf '$ bin/fm-board.sh escalate 2   # raising %s\n' "$n"
  board escalate 2; printf '  exit=%s\n' "$?"
done
printf '$ bin/fm-board.sh next   # the blocked item no longer stops the agenda\n'
board next

step 'The same needs-decision key raised again in timestamp-first and indented lines is a defect'
printf '2026-09-11T02:09Z needs-decision [key=dns]: approve the DNS change\n' > "$HOME_DIR/state/lane-a.status"
printf ' needs-decision [key=dns]: approve the DNS change (again)\n' >> "$HOME_DIR/state/lane-a.status"
printf '$ bin/fm-board-audit.sh check   # +94m\n'
out=$(audit 5640); printf '%s\n' "$out"

step 'Disarming leaves the home without the check shim or its record'
audit 0 disarm
