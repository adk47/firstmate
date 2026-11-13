#!/usr/bin/env bash
# fm-board.sh - the board: firstmate's single ordered agenda, five items at most.
#
# The board is data/board.md. It is the one place that answers "what do I do
# next" for a firstmate turn: every item names the check that finishes it, its
# current state in one line, and the next bounded action. This script is the
# only writer and the only reader of that file's shape, so nothing downstream
# ever interprets prose: bin/fm-wake-drain.sh prints the agenda line from
# `wake-line`, and bin/fm-board-audit.sh reads `next` and `advanced`.
# The loop the board drives (when a turn must act on it, what may block an item,
# and the escalation limit) is owned by the board-loop skill.
#
# Usage:
#   fm-board.sh next                      the first item that is not blocked, as
#                                         "<n>\t<title>\t<next action>\t<check>"
#   fm-board.sh done <n>                  the acceptance check passed: remove
#                                         item <n> and renumber the rest
#   fm-board.sh block <n> <reason> [--captain <class>]
#                                         record why item <n> cannot proceed;
#                                         `next` then skips it
#   fm-board.sh unblock <n>               the blocker cleared
#   fm-board.sh advance <n> <state> [--next <action>]
#                                         item <n> moved: record its new state
#                                         and, when it changed, the next action
#   fm-board.sh escalate <n>              count one raising of item <n>'s
#                                         recorded blocker with the captain
#   fm-board.sh add <title> --check <c> --state <s> --next <a> [--at <n>]
#                                         add an item (last, or at position <n>)
#   fm-board.sh drop <n> <reason>         remove an item that will not be done
#   fm-board.sh list                      every item, one tab-separated line:
#                                         <n> <open|blocked> <class|-> <escalations>
#                                         <title> <check> <state> <next> <reason|->
#   fm-board.sh advanced                  epoch second of the last advance
#   fm-board.sh wake-line                 the one agenda line a wake digest prints
#   fm-board.sh check                     validate the file and say nothing
#   fm-board.sh show                      print the validated file
#   fm-board.sh --help
#
# THE FILE. Every line of data/board.md is machine-read, so the shape is exact:
#
#   # Board
#   <!-- any single-line comment -->
#   - advanced: <epoch second>
#
#   ## 1. <title>
#   - check: <the acceptance check that finishes the item>
#   - state: <current state, one line>
#   - next: <the next bounded action>
#   - blocked: <reason>            only while blocked
#   - class: <captain class>       only on a captain-class block
#   - escalations: <count>         only once the blocker was raised
#
# Items are numbered 1..5 in order and that order is the priority. A line of any
# other shape makes the whole board invalid, which every command reports with
# the line number instead of guessing. Values are single lines without tabs.
#
# CAPTAIN CLASSES. --captain takes exactly one of money, irreversible,
# production-ddl, legal-signature: the four reasons an item waits for the
# captain. A block without --captain is an ordinary recorded blocker (an
# external wait, a missing credential, an approval another rule requires).
#
# WHAT COUNTS AS AN ADVANCE. `done` and `advance` stamp the board's advanced
# time; `advance` refuses a state and next action identical to the recorded
# ones, because a restated item has not moved. `block`, `unblock`, `add`,
# `drop`, and `escalate` rewrite the file without stamping it.
#
# THE ESCALATION LIMIT. `escalate` requires a recorded block and counts each
# raising of it. The first two succeed; the third is refused with exit 5 and is
# not recorded, because a blocker raised twice is either solved or left blocked
# while the next item is driven.
#
# Exit codes: 0 success; 1 nothing to do or a refused change (no unblocked item,
# board full, unchanged advance); 2 usage; 3 no board file; 4 invalid board;
# 5 the escalation limit.
#
# Test seams: FM_HOME / FM_ROOT_OVERRIDE and FM_DATA_OVERRIDE select the home and
# its data directory, and FM_BOARD_NOW replaces the clock (epoch seconds).
set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
BOARD="$DATA/board.md"

# shellcheck source=bin/fm-line-cap-lib.sh
. "$SCRIPT_DIR/fm-line-cap-lib.sh"

MAX_ITEMS=5
MAX_ESCALATIONS=2
WAKE_LINE_MAX=600
US=$'\037'
TAB=$'\t'

N=0
ADV=0
BOARD_ERR=
TITLE=()
CHECK=()
STATE_LINE=()
NEXT=()
BLOCKED=()
CLASS=()
ESCALATIONS=()

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "${BASH_SOURCE[0]}"
  exit 2
}

die_usage() {
  printf 'fm-board: %s\n' "$1" >&2
  exit 2
}

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

class_valid() {
  case "$1" in
    money|irreversible|production-ddl|legal-signature) return 0 ;;
    *) return 1 ;;
  esac
}

# The one parser of the board shape. It prints one record per fact, fields
# separated by the unit separator so an empty field survives the shell read:
#   A <advanced>
#   I <n> <title> <check> <state> <next> <blocked> <class> <escalations>
#   E <line> <message>      (alone, when the file is not a valid board)
parse_board() {  # <file>
  awk -v US="$US" -v MAX="$MAX_ITEMS" '
    function fail(msg) { if (err == "") { err = msg; errline = NR } }
    function close_item() {
      if (n == 0) return
      if (f["check"] == "") fail("item " n " has no check")
      else if (f["state"] == "") fail("item " n " has no state")
      else if (f["next"] == "") fail("item " n " has no next action")
      else if (f["class"] != "" && f["blocked"] == "") fail("item " n " names a class without a blocked reason")
      else if (f["escalations"] != "" && f["blocked"] == "") fail("item " n " counts escalations without a blocked reason")
      esc = (f["escalations"] == "") ? 0 : f["escalations"] + 0
      rec[n] = "I" US n US title US f["check"] US f["state"] US f["next"] US f["blocked"] US f["class"] US esc
    }
    BEGIN { n = 0; adv = 0; advseen = 0; err = "" }
    err != "" { next }
    /\t/ { fail("a tab is not allowed"); next }
    index($0, US) { fail("a control separator is not allowed"); next }
    /^[ ]*$/ { next }
    /^<!--.*-->[ ]*$/ { next }
    /^# / { if (n > 0) fail("a title line is only allowed above the first item"); next }
    /^## [0-9]+\. / {
      close_item()
      if (err != "") next
      num = $2; sub(/\.$/, "", num)
      if (num + 0 != n + 1) { fail("item heading is numbered " num " but is item " (n + 1)); next }
      if (n + 1 > MAX) { fail("more than " MAX " items"); next }
      n++
      title = $0; sub(/^## [0-9]+\. /, "", title); sub(/[ ]+$/, "", title)
      if (title == "") { fail("item " n " has no title"); next }
      split("", f)
      next
    }
    /^- [a-z]+:( .*)?$/ {
      key = $2; sub(/:$/, "", key)
      val = $0; sub(/^- [a-z]+:[ ]*/, "", val); sub(/[ ]+$/, "", val)
      if (n == 0) {
        if (key != "advanced") { fail("field " key " is outside an item"); next }
        if (advseen) { fail("advanced is stated twice"); next }
        if (val !~ /^[0-9]+$/) { fail("advanced is not an epoch second"); next }
        adv = val; advseen = 1
        next
      }
      if (key != "check" && key != "state" && key != "next" && key != "blocked" && key != "class" && key != "escalations") {
        fail("unknown field " key); next
      }
      if (key in f) { fail("item " n " states " key " twice"); next }
      if (val == "") { fail("item " n " field " key " is empty"); next }
      if (key == "class" && val != "money" && val != "irreversible" && val != "production-ddl" && val != "legal-signature") {
        fail("item " n " class is not money, irreversible, production-ddl, or legal-signature"); next
      }
      if (key == "escalations" && val !~ /^[0-9]+$/) { fail("item " n " escalations is not a count"); next }
      f[key] = val
      next
    }
    { fail("not a board line") }
    END {
      if (err == "") close_item()
      if (err != "") { print "E" US errline US err; exit 0 }
      print "A" US adv
      for (i = 1; i <= n; i++) print rec[i]
    }
  ' "$1"
}

# Load the board into N, ADV, and the per-item arrays.
# Returns 0 loaded, 3 no board file, 4 invalid (BOARD_ERR says why).
load_board() {
  local out kind a b c d e f g h
  N=0
  ADV=0
  BOARD_ERR=
  if [ ! -e "$BOARD" ] && [ ! -L "$BOARD" ]; then
    return 3
  fi
  if [ -L "$BOARD" ] || [ ! -f "$BOARD" ] || [ ! -r "$BOARD" ]; then
    BOARD_ERR='it is not a readable regular file'
    return 4
  fi
  out=$(parse_board "$BOARD") || { BOARD_ERR='it could not be read'; return 4; }
  while IFS=$US read -r kind a b c d e f g h; do
    case "$kind" in
      E) BOARD_ERR="line $a: $b"; return 4 ;;
      A) ADV=$a ;;
      I)
        N=$a
        TITLE[N]=$b
        CHECK[N]=$c
        STATE_LINE[N]=$d
        NEXT[N]=$e
        BLOCKED[N]=$f
        CLASS[N]=$g
        ESCALATIONS[N]=$h
        ;;
    esac
  done <<EOF
$out
EOF
  return 0
}

# Load for a command that needs a valid board, exiting with the read's own code.
require_board() {
  local rc=0
  load_board || rc=$?
  case "$rc" in
    0) return 0 ;;
    3) printf 'fm-board: no board at %s; create it with fm-board.sh add\n' "$BOARD" >&2; exit 3 ;;
    *) printf 'fm-board: %s is not a valid board: %s\n' "$BOARD" "$BOARD_ERR" >&2; exit 4 ;;
  esac
}

render_board() {
  local i
  printf '%s\n\n' '# Board'
  printf '%s\n' '<!-- fm-board-v1: every line is machine-read; change it with bin/fm-board.sh -->'
  printf -- '- advanced: %s\n' "$ADV"
  i=1
  while [ "$i" -le "$N" ]; do
    printf '\n## %s. %s\n' "$i" "${TITLE[i]}"
    printf -- '- check: %s\n' "${CHECK[i]}"
    printf -- '- state: %s\n' "${STATE_LINE[i]}"
    printf -- '- next: %s\n' "${NEXT[i]}"
    if [ -n "${BLOCKED[i]}" ]; then
      printf -- '- blocked: %s\n' "${BLOCKED[i]}"
      [ -z "${CLASS[i]}" ] || printf -- '- class: %s\n' "${CLASS[i]}"
      [ "${ESCALATIONS[i]}" -eq 0 ] || printf -- '- escalations: %s\n' "${ESCALATIONS[i]}"
    fi
    i=$((i + 1))
  done
}

# Replace the board atomically, so a reader never sees a half-written agenda.
write_board() {
  local tmp
  mkdir -p "$DATA" || { printf 'fm-board: cannot create %s\n' "$DATA" >&2; exit 1; }
  tmp=$(mktemp "$DATA/.board.XXXXXX") || { printf 'fm-board: cannot write in %s\n' "$DATA" >&2; exit 1; }
  if render_board > "$tmp" && mv -f -- "$tmp" "$BOARD"; then
    return 0
  fi
  rm -f -- "$tmp"
  printf 'fm-board: could not replace %s\n' "$BOARD" >&2
  exit 1
}

# A value is one line with no tab and no control separator, trimmed and non-empty.
clean_value() {  # <label> <value> -> CLEAN
  local label=$1 value=$2
  case "$value" in
    *$'\n'*|*"$TAB"*|*"$US"*|*$'\r'*) die_usage "$label must be a single line without tabs" ;;
  esac
  value="${value#"${value%%[! ]*}"}"
  value="${value%"${value##*[! ]}"}"
  [ -n "$value" ] || die_usage "$label must not be empty"
  CLEAN=$value
}

item_number() {  # <value> -> validated against the loaded board
  case "$1" in
    ''|*[!0-9]*) die_usage "item number must be 1..$N, got '$1'" ;;
  esac
  if [ "$1" -lt 1 ] || [ "$1" -gt "$N" ]; then
    printf 'fm-board: no item %s on a board of %s\n' "$1" "$N" >&2
    exit 1
  fi
}

remove_item() {  # <n>
  local i=$1
  while [ "$i" -lt "$N" ]; do
    TITLE[i]=${TITLE[i + 1]}
    CHECK[i]=${CHECK[i + 1]}
    STATE_LINE[i]=${STATE_LINE[i + 1]}
    NEXT[i]=${NEXT[i + 1]}
    BLOCKED[i]=${BLOCKED[i + 1]}
    CLASS[i]=${CLASS[i + 1]}
    ESCALATIONS[i]=${ESCALATIONS[i + 1]}
    i=$((i + 1))
  done
  N=$((N - 1))
}

first_open() {  # -> FIRST_OPEN (0 when every item is blocked or the board is empty)
  local i=1
  FIRST_OPEN=0
  while [ "$i" -le "$N" ]; do
    if [ -z "${BLOCKED[i]}" ]; then
      FIRST_OPEN=$i
      return 0
    fi
    i=$((i + 1))
  done
  return 0
}

action_next() {
  require_board
  first_open
  if [ "$FIRST_OPEN" -eq 0 ]; then
    printf 'fm-board: no unblocked item (%s on the board)\n' "$N" >&2
    exit 1
  fi
  printf '%s\t%s\t%s\t%s\n' "$FIRST_OPEN" "${TITLE[FIRST_OPEN]}" "${NEXT[FIRST_OPEN]}" "${CHECK[FIRST_OPEN]}"
}

action_done() {
  [ "$#" -eq 1 ] || die_usage 'done takes exactly the item number'
  require_board
  item_number "$1"
  printf 'done: %s (check: %s)\n' "${TITLE[$1]}" "${CHECK[$1]}"
  remove_item "$1"
  ADV=$(now_epoch)
  write_board
}

action_drop() {
  [ "$#" -eq 2 ] || die_usage 'drop takes the item number and a reason'
  require_board
  item_number "$1"
  clean_value 'the drop reason' "$2"
  printf 'dropped: %s (%s)\n' "${TITLE[$1]}" "$CLEAN"
  remove_item "$1"
  write_board
}

action_block() {
  local n reason class=''
  [ "$#" -ge 2 ] || die_usage 'block takes the item number and a reason'
  n=$1
  reason=$2
  shift 2
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --captain)
        [ "$#" -ge 2 ] || die_usage '--captain needs a class'
        class_valid "$2" || die_usage "--captain must be money, irreversible, production-ddl, or legal-signature, got '$2'"
        class=$2
        shift 2
        ;;
      *) die_usage "unknown block argument '$1'" ;;
    esac
  done
  require_board
  item_number "$n"
  clean_value 'the block reason' "$reason"
  # A new reason is a new blocker, so its escalation count starts again.
  [ "${BLOCKED[n]}" = "$CLEAN" ] || ESCALATIONS[n]=0
  BLOCKED[n]=$CLEAN
  CLASS[n]=$class
  write_board
}

action_unblock() {
  [ "$#" -eq 1 ] || die_usage 'unblock takes exactly the item number'
  require_board
  item_number "$1"
  BLOCKED[$1]=
  CLASS[$1]=
  ESCALATIONS[$1]=0
  write_board
}

action_advance() {
  local n state next=''
  [ "$#" -ge 2 ] || die_usage 'advance takes the item number and the new state'
  n=$1
  state=$2
  shift 2
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --next)
        [ "$#" -ge 2 ] || die_usage '--next needs the next action'
        next=$2
        shift 2
        ;;
      *) die_usage "unknown advance argument '$1'" ;;
    esac
  done
  require_board
  item_number "$n"
  clean_value 'the state' "$state"
  state=$CLEAN
  if [ -n "$next" ]; then
    clean_value 'the next action' "$next"
    next=$CLEAN
  else
    next=${NEXT[n]}
  fi
  if [ "$state" = "${STATE_LINE[n]}" ] && [ "$next" = "${NEXT[n]}" ]; then
    printf 'fm-board: item %s is unchanged; a restated item has not advanced\n' "$n" >&2
    exit 1
  fi
  STATE_LINE[n]=$state
  NEXT[n]=$next
  ADV=$(now_epoch)
  write_board
}

action_escalate() {
  local n count
  [ "$#" -eq 1 ] || die_usage 'escalate takes exactly the item number'
  require_board
  n=$1
  item_number "$n"
  if [ -z "${BLOCKED[n]}" ]; then
    printf 'fm-board: item %s has no recorded blocker; record it with fm-board.sh block first\n' "$n" >&2
    exit 1
  fi
  count=${ESCALATIONS[n]}
  if [ "$count" -ge "$MAX_ESCALATIONS" ]; then
    printf 'fm-board: item %s blocker was already raised %s times; a third raising is a defect - leave it blocked and drive the next item\n' "$n" "$count" >&2
    exit 5
  fi
  count=$((count + 1))
  ESCALATIONS[n]=$count
  write_board
  if [ "$count" -ge "$MAX_ESCALATIONS" ]; then
    printf 'escalation %s of %s for item %s: this is the last one - solve it or leave it blocked and drive the next item\n' "$count" "$MAX_ESCALATIONS" "$n"
  else
    printf 'escalation %s of %s for item %s\n' "$count" "$MAX_ESCALATIONS" "$n"
  fi
}

action_add() {
  local title='' check='' state='' next='' at='' rc=0 i
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --check) [ "$#" -ge 2 ] || die_usage '--check needs a value'; check=$2; shift 2 ;;
      --state) [ "$#" -ge 2 ] || die_usage '--state needs a value'; state=$2; shift 2 ;;
      --next) [ "$#" -ge 2 ] || die_usage '--next needs a value'; next=$2; shift 2 ;;
      --at) [ "$#" -ge 2 ] || die_usage '--at needs a position'; at=$2; shift 2 ;;
      --*) die_usage "unknown add argument '$1'" ;;
      *)
        [ -z "$title" ] || die_usage 'add takes one title'
        title=$1
        shift
        ;;
    esac
  done
  clean_value 'the title' "$title"; title=$CLEAN
  clean_value '--check' "$check"; check=$CLEAN
  clean_value '--state' "$state"; state=$CLEAN
  clean_value '--next' "$next"; next=$CLEAN
  load_board || rc=$?
  case "$rc" in
    0) ;;
    3) ADV=$(now_epoch) ;;
    *) printf 'fm-board: %s is not a valid board: %s\n' "$BOARD" "$BOARD_ERR" >&2; exit 4 ;;
  esac
  if [ "$N" -ge "$MAX_ITEMS" ]; then
    printf 'fm-board: the board is full (%s items); finish or drop one before adding\n' "$MAX_ITEMS" >&2
    exit 1
  fi
  if [ -z "$at" ]; then
    at=$((N + 1))
  else
    case "$at" in ''|*[!0-9]*) die_usage "--at must be 1..$((N + 1)), got '$at'" ;; esac
    if [ "$at" -lt 1 ] || [ "$at" -gt $((N + 1)) ]; then
      die_usage "--at must be 1..$((N + 1)), got '$at'"
    fi
  fi
  i=$N
  while [ "$i" -ge "$at" ]; do
    TITLE[i + 1]=${TITLE[i]}
    CHECK[i + 1]=${CHECK[i]}
    STATE_LINE[i + 1]=${STATE_LINE[i]}
    NEXT[i + 1]=${NEXT[i]}
    BLOCKED[i + 1]=${BLOCKED[i]}
    CLASS[i + 1]=${CLASS[i]}
    ESCALATIONS[i + 1]=${ESCALATIONS[i]}
    i=$((i - 1))
  done
  N=$((N + 1))
  TITLE[at]=$title
  CHECK[at]=$check
  STATE_LINE[at]=$state
  NEXT[at]=$next
  BLOCKED[at]=
  CLASS[at]=
  ESCALATIONS[at]=0
  write_board
}

action_list() {
  local i=1 status
  require_board
  while [ "$i" -le "$N" ]; do
    status=open
    [ -z "${BLOCKED[i]}" ] || status=blocked
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$i" "$status" "${CLASS[i]:--}" "${ESCALATIONS[i]}" \
      "${TITLE[i]}" "${CHECK[i]}" "${STATE_LINE[i]}" "${NEXT[i]}" "${BLOCKED[i]:--}"
    i=$((i + 1))
  done
}

# The last advance. A board written by hand without the stamp reads as advanced
# when the file last changed, so it is never treated as infinitely old.
action_advanced() {
  require_board
  if [ "$ADV" -gt 0 ]; then
    printf '%s\n' "$ADV"
  else
    file_mtime "$BOARD" || printf '0\n'
  fi
}

# The one agenda line a wake digest prints. Silent when this home keeps no
# board, so a home that never adopted one sees no change at all.
action_wake_line() {
  local rc=0 line i captain=0
  load_board || rc=$?
  case "$rc" in
    3) return 0 ;;
    4)
      line="BOARD INVALID: data/board.md $BOARD_ERR - repair it so bin/fm-board.sh check passes; until then no agenda can be read"
      ;;
    *)
      first_open
      if [ "$N" -eq 0 ]; then
        line='BOARD EMPTY: nothing is on the agenda - add the next goals from the backlog with bin/fm-board.sh add, or confirm nothing is queued'
      elif [ "$FIRST_OPEN" -gt 0 ]; then
        line="BOARD NEXT: item $FIRST_OPEN \"${TITLE[FIRST_OPEN]}\" - next: ${NEXT[FIRST_OPEN]} | done when: ${CHECK[FIRST_OPEN]} | run it this turn unless this wake carries captain-class content"
      else
        i=1
        while [ "$i" -le "$N" ]; do
          [ -z "${CLASS[i]}" ] || captain=$((captain + 1))
          i=$((i + 1))
        done
        line="BOARD BLOCKED: all $N items are blocked ($captain waiting on the captain) - clear a blocker that is yours or add the next goal; a recorded blocker is not raised again"
      fi
      ;;
  esac
  fm_cap_line "$line" "$WAKE_LINE_MAX"
}

action_check() {
  require_board
}

action_show() {
  require_board
  cat -- "$BOARD"
}

[ "$#" -ge 1 ] || usage
ACTION=$1
shift
case "$ACTION" in
  next) [ "$#" -eq 0 ] || die_usage 'next takes no arguments'; action_next ;;
  done) action_done "$@" ;;
  drop) action_drop "$@" ;;
  block) action_block "$@" ;;
  unblock) action_unblock "$@" ;;
  advance) action_advance "$@" ;;
  escalate) action_escalate "$@" ;;
  add) action_add "$@" ;;
  list) action_list ;;
  advanced) action_advanced ;;
  wake-line) action_wake_line ;;
  check) action_check ;;
  show) action_show ;;
  -h|--help|help) usage ;;
  *) usage ;;
esac
