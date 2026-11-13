#!/usr/bin/env bash
# fm-board-audit.sh - the loop driver: wake firstmate when the board is not being driven.
#
# Usage:
#   fm-board-audit.sh [check]   poll once; silent unless firstmate should wake
#   fm-board-audit.sh status    print the current verdict, record nothing
#   fm-board-audit.sh arm       write state/board-audit.check.sh and bind it
#   fm-board-audit.sh disarm    remove the shim, its trust binding, and the record
#   fm-board-audit.sh --help
#
# The board (data/board.md, owned by bin/fm-board.sh) is firstmate's agenda.
# This registered check is the backstop for a firstmate that answers
# notifications and stops: it prints ONE line naming the item to drive when any
# condition below holds, and nothing when none does. What firstmate owes on that
# wake is owned by the board-loop skill.
#
# CONDITIONS.
#   no board      this home armed the check and data/board.md does not exist.
#   invalid       data/board.md does not parse (bin/fm-board.sh check says why).
#   stale         the board file has not changed for FM_BOARD_STALE_SECS
#                 (default 10800, three hours).
#   idle          the first unblocked item exists and no item advanced for
#                 FM_BOARD_IDLE_SECS (default 3600). A board whose every item is
#                 blocked never raises this one: there is no action to run.
#   silent tasks  more than FM_BOARD_SILENT_MAX (default 3) tasks have a
#                 state/<id>.meta and no status line. A secondmate, a task the
#                 captain ordered left stopped, and a record younger than
#                 FM_BOARD_SILENT_GRACE_SECS (default 900) are not counted.
#   repeat        a still-open `needs-decision` key was raised twice in one
#                 status log without an answer; three or more reads as a defect.
#                 A `resolved` line or a verified captain hold closes the key and
#                 clears it (bin/fm-classify-lib.sh status_repeat_escalations).
#
# THE LINE. "board audit: <condition>; <condition> -> <what to do>". When an
# unblocked item exists the directive names it and its next action, whichever
# condition fired. Durations are in whole minutes.
#
# REPEATING. The line is printed when the set of conditions changes and again
# every FM_BOARD_REMIND_SECS (default 1800) while it holds; an unchanged verdict
# inside that window is silent. state/.board-audit holds the last printed
# verdict and is removed as soon as no condition holds, so a board item
# advancing clears the alarm on the next poll without a recovery line.
#
# Test seams: FM_HOME / FM_ROOT_OVERRIDE, FM_STATE_OVERRIDE, and FM_DATA_OVERRIDE
# select the home; FM_BOARD_NOW replaces the clock (epoch seconds).
set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
export FM_HOME
export FM_DATA_OVERRIDE="$DATA"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-check-lib.sh
. "$SCRIPT_DIR/fm-check-lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-line-cap-lib.sh
. "$SCRIPT_DIR/fm-line-cap-lib.sh"

CHECK_ID='board-audit'
RECORD="$STATE/.board-audit"
BOARD="$DATA/board.md"
BOARD_BIN="$SCRIPT_DIR/fm-board.sh"
REGISTER_BIN="$SCRIPT_DIR/fm-check-register.sh"
MAX_LINE=1500
MAX_NAMED=5
TAB=$'\t'

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "${BASH_SOURCE[0]}"
  exit 2
}

setting() {  # <value> <default> -> a positive whole number
  case "$1" in
    ''|*[!0-9]*) printf '%s\n' "$2" ;;
    *) printf '%s\n' "$1" ;;
  esac
}

STALE_SECS=$(setting "${FM_BOARD_STALE_SECS:-}" 10800)
IDLE_SECS=$(setting "${FM_BOARD_IDLE_SECS:-}" 3600)
SILENT_MAX=$(setting "${FM_BOARD_SILENT_MAX:-}" 3)
SILENT_GRACE_SECS=$(setting "${FM_BOARD_SILENT_GRACE_SECS:-}" 900)
REMIND_SECS=$(setting "${FM_BOARD_REMIND_SECS:-}" 1800)

now_epoch() {
  case "${FM_BOARD_NOW:-}" in
    ''|*[!0-9]*) date +%s ;;
    *) printf '%s\n' "$FM_BOARD_NOW" ;;
  esac
}

file_mtime() {
  if [ "$(uname -s 2>/dev/null || true)" = Darwin ]; then
    stat -f %m "$1" 2>/dev/null
  else
    stat -c %Y "$1" 2>/dev/null
  fi
}

CONDITIONS=
SIGNATURE=
VERDICT=

add_condition() {  # <text> <signature-part>
  if [ -n "$CONDITIONS" ]; then
    CONDITIONS="$CONDITIONS; $1"
    SIGNATURE="$SIGNATURE|$2"
  else
    CONDITIONS=$1
    SIGNATURE=$2
  fi
}

# Tasks with a record and no status line. Sets SILENT_COUNT and SILENT_NAMES.
count_silent_tasks() {  # <now>
  local now=$1 meta id mtime
  SILENT_COUNT=0
  SILENT_NAMES=
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] && [ ! -L "$meta" ] || continue
    id=$(basename "$meta" .meta)
    [ ! -s "$STATE/$id.status" ] || continue
    [ ! -e "$STATE/$id.stopped" ] || continue
    ! grep -q '^kind=secondmate$' "$meta" 2>/dev/null || continue
    mtime=$(file_mtime "$meta") || continue
    case "$mtime" in ''|*[!0-9]*) continue ;; esac
    [ $((now - mtime)) -ge "$SILENT_GRACE_SECS" ] || continue
    SILENT_COUNT=$((SILENT_COUNT + 1))
    if [ "$SILENT_COUNT" -le "$MAX_NAMED" ]; then
      SILENT_NAMES="${SILENT_NAMES:+$SILENT_NAMES }$id"
    fi
  done
}

# Still-open needs-decision keys raised again without an answer, one condition each.
add_repeat_conditions() {
  local status id raised key count
  for status in "$STATE"/*.status; do
    [ -f "$status" ] && [ ! -L "$status" ] || continue
    raised=$(grep -c '^needs-decision' "$status" 2>/dev/null) || raised=0
    case "$raised" in ''|*[!0-9]*) raised=0 ;; esac
    [ "$raised" -ge 2 ] || continue
    id=$(basename "$status" .status)
    while IFS=$TAB read -r key count; do
      [ -n "$key" ] || continue
      if [ "$count" -ge 3 ]; then
        add_condition "defect: needs-decision $id/$key raised x$count unanswered" "repeat:$id/$key:defect"
      else
        add_condition "needs-decision $id/$key raised x$count unanswered (answer it or hold it, then move on)" "repeat:$id/$key:2"
      fi
    done <<EOF
$(status_repeat_escalations "$status")
EOF
  done
}

# Evaluate every condition. Sets VERDICT (the line, empty when clear) and SIGNATURE.
evaluate() {
  local now rc=0 next_out item='' title='' next='' check='' mtime advanced directive
  now=$(now_epoch)
  CONDITIONS=
  SIGNATURE=
  VERDICT=
  next_out=$("$BOARD_BIN" next 2>/dev/null) || rc=$?
  case "$rc" in
    0)
      IFS=$TAB read -r item title next check <<EOF
$next_out
EOF
      directive="drive item $item \"$title\": $next"
      ;;
    1) directive='every item is blocked or the board is empty: clear a blocker that is yours or add the next goal with bin/fm-board.sh add' ;;
    3)
      add_condition 'no board' 'board:absent'
      directive='create data/board.md with bin/fm-board.sh add'
      ;;
    *)
      add_condition "board invalid ($("$BOARD_BIN" check 2>&1 | sed 's/^fm-board: //'))" 'board:invalid'
      directive='repair data/board.md until bin/fm-board.sh check passes'
      ;;
  esac
  : "$check"
  if [ "$rc" -eq 0 ] || [ "$rc" -eq 1 ]; then
    mtime=$(file_mtime "$BOARD") || mtime=
    case "$mtime" in
      ''|*[!0-9]*) ;;
      *)
        if [ $((now - mtime)) -ge "$STALE_SECS" ]; then
          add_condition "board unchanged for $(((now - mtime) / 60))m" 'board:stale'
        fi
        ;;
    esac
  fi
  if [ "$rc" -eq 0 ]; then
    advanced=$("$BOARD_BIN" advanced 2>/dev/null) || advanced=
    case "$advanced" in
      ''|*[!0-9]*) ;;
      *)
        if [ $((now - advanced)) -ge "$IDLE_SECS" ]; then
          add_condition "no item advanced in $(((now - advanced) / 60))m while item $item is unblocked" "idle:$item:$title"
        fi
        ;;
    esac
  fi
  count_silent_tasks "$now"
  if [ "$SILENT_COUNT" -gt "$SILENT_MAX" ]; then
    add_condition "$SILENT_COUNT tasks have a record and no status line ($SILENT_NAMES)" "silent:$SILENT_NAMES"
  fi
  add_repeat_conditions
  [ -n "$CONDITIONS" ] || return 0
  fm_cap_line_var "board audit: $CONDITIONS -> $directive" "$MAX_LINE"
  VERDICT=$FM_LINE_CAP_LINE
}

record_write() {  # <epoch> <signature>
  local tmp
  tmp=$(mktemp "$STATE/.board-audit.XXXXXX") || return 1
  if printf '%s\n%s\n' "$1" "$2" > "$tmp" && mv -f -- "$tmp" "$RECORD"; then
    return 0
  fi
  rm -f -- "$tmp"
  return 1
}

action_check() {
  local now last_epoch='' last_signature=''
  [ -d "$STATE" ] || return 0
  evaluate
  if [ -z "$VERDICT" ]; then
    rm -f -- "$RECORD"
    return 0
  fi
  now=$(now_epoch)
  if [ -f "$RECORD" ] && [ ! -L "$RECORD" ]; then
    { IFS= read -r last_epoch; IFS= read -r last_signature; } < "$RECORD" || true
  fi
  case "$last_epoch" in ''|*[!0-9]*) last_epoch=0 ;; esac
  if [ "$SIGNATURE" = "$last_signature" ] && [ $((now - last_epoch)) -lt "$REMIND_SECS" ]; then
    return 0
  fi
  printf '%s\n' "$VERDICT"
  record_write "$now" "$SIGNATURE" || true
}

action_status() {
  evaluate
  if [ -n "$VERDICT" ]; then
    printf '%s\n' "$VERDICT"
  else
    printf 'board audit: clear\n'
  fi
}

# The home is embedded already resolved, because the watcher runs the shim from
# its own working directory.
shim_content() {
  local home=$1
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    '# Auto-generated by fm-board-audit.sh - board loop driver poll shim.' \
    '# The watcher validates these bytes, then dispatches the trusted check script.' \
    "export FM_HOME=$(printf '%q' "$home")" \
    "exec $(printf '%q' "$SCRIPT_DIR/fm-board-audit.sh") check"
}

action_arm() {
  local want home
  mkdir -p "$STATE" || return 1
  home=$(fm_custom_check_resolve_home "$FM_HOME") || {
    printf 'fm-board-audit: cannot resolve FM_HOME %s\n' "$FM_HOME" >&2
    return 1
  }
  want=$(shim_content "$home")
  fm_custom_check_arm "$STATE" "$CHECK_ID" .fm-board-audit \
    fm-board-audit "$REGISTER_BIN" "$home" "$want"
}

action_disarm() {
  fm_custom_check_disarm "$STATE" "$CHECK_ID" "$RECORD"
}

case "${1:-check}" in
  check) action_check ;;
  status) action_status ;;
  arm) action_arm ;;
  disarm) action_disarm ;;
  -h|--help|help) usage ;;
  *) usage ;;
esac
