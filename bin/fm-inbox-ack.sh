#!/usr/bin/env bash
# fm-inbox-ack.sh - acknowledge firstmate steering records the safe way.
#
# bin/fm-task-inbox-lib.sh owns the steering-inbox contract: the record format,
# the sequence allocation, the acknowledgement (a record leaving the inbox root
# into handled/), and the watcher's re-ring ladder. This script is only the
# blessed way for a worker to perform that acknowledgement, and it exists
# because hand-rolled handling loses instructions: a worker's own `rm`, its
# `mv *.msg handled/` sweep, or a tidy-up glob inside the inbox can destroy a
# record it never read. Acknowledge with this command instead of touching the
# inbox by hand.
#
# What it does for each record, in order:
#   1. Refuses a name that is not a sequence, so a typo cannot touch anything.
#   2. Reports a record that is already acknowledged instead of failing, so a
#      re-run after a lost reply is harmless.
#   3. Moves the record into handled/ - the acknowledgement itself.
#   4. Retires the record's hidden second link, which is what lets the watcher
#      tell a genuine acknowledgement from a record a worker deleted.
#
# It never deletes an unread record and never touches a record it was not given.
#
# Usage:
#   fm-inbox-ack.sh <state-dir> <task-id> <record>...
#     <state-dir>  the home's state directory, usually $FM_HOME/state
#     <task-id>    the task whose inbox you are acknowledging
#     <record>     a record path, or its bare sequence ("035" or "035.msg")
#
# Exits nonzero, having acknowledged nothing further, when a named record is in
# neither the inbox nor handled/.
set -u

usage() {
  sed -n '/^# Usage:/,/^# Exits/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
}

die() { printf 'fm-inbox-ack: %s\n' "$*" >&2; exit 1; }

[ "$#" -ge 3 ] || { usage; exit 2; }
STATE=$1
TASK=$2
shift 2

case "$STATE" in ''|*/) STATE=${STATE%/} ;; esac
[ -n "$STATE" ] || { usage; exit 2; }
case "$TASK" in ''|*/*|.|..) die "not a task id: $TASK" ;; esac
[ -d "$STATE" ] || die "no state directory at $STATE"

INBOX="$STATE/$TASK.inbox"
[ -d "$INBOX" ] || die "no inbox at $INBOX"
HANDLED="$INBOX/handled"
SHADOW="$INBOX/.unhandled"
mkdir -p "$HANDLED" || die "could not create $HANDLED"

acked=0
for arg in "$@"; do
  base=${arg##*/}
  base=${base%.msg}
  case "$base" in
    ''|*[!0-9]*) die "not a record sequence: $arg (expected a number such as 035)" ;;
  esac
  src="$INBOX/$base.msg"
  if [ ! -f "$src" ]; then
    if [ -f "$HANDLED/$base.msg" ]; then
      printf 'already acknowledged: %s\n' "$HANDLED/$base.msg"
      rm -f "$SHADOW/$base" 2>/dev/null || true
      acked=$((acked + 1))
      continue
    fi
    die "no record $base.msg in $INBOX (never delivered, or already acknowledged)"
  fi
  mv -f "$src" "$HANDLED/$base.msg" || die "could not move $src into $HANDLED"
  rm -f "$SHADOW/$base" 2>/dev/null || true
  printf 'acknowledged: %s\n' "$HANDLED/$base.msg"
  acked=$((acked + 1))
done
[ "$acked" -gt 0 ] || die "nothing to acknowledge"
