#!/usr/bin/env bash
# fm-thread-deliver.sh - thread subscriptions: an event reaches the task that
# owns the thread, without a firstmate turn.
#
# WHY: firstmate is a router that also executed. A PR's QA finding, a NO-GO, or
# a lane's "need firstmate: steer <lane>" line landed in a status log that
# firstmate reads days later (24 PRs sat with unanswered QA findings for a
# median 116 h), and firstmate relayed the steer to the lane by hand. This
# script removes the middleman for both: an event is written straight into the
# owning worker's own steering inbox, and firstmate is told only when that
# worker is gone, because that is the one case it must still relay.
#
# A THREAD is the durable grouping of events about one thing: a PR URL, a lane's
# own status log, a Sentry issue, a Slack conversation. A SUBSCRIPTION is a task
# that owns that thread and must see its events. Thread ids are filesystem-safe
# slugs, so a caller may pass a raw PR URL and have it canonicalized here.
#
# CONTRACT (this header is the one owner of the state formats).
#   - Subscriptions: $STATE/threads/<thread-id>.subs, one row per subscriber:
#       <task-id>\t<role>\t<added-utc>
#     Blank lines and lines starting with # are ignored. A task appears at most
#     once per thread; add is idempotent. Rows are appended (atomic for one
#     short write), never rewritten except by `remove`, which rewrites the file
#     without that task. A missing .subs file means no subscribers.
#   - Thread ids: lowercase, and only [a-z0-9._-] after the first character.
#     A PR/MR URL becomes pr-<host>-<project-path>-<number> with "/" and other
#     separators collapsed to "-", so github.com/Muso-AI/hydra/pull/1472 is
#     pr-github.com-muso-ai-hydra-1472 and a lane's thread is lane-<task-id>.
#     Canonicalization is idempotent: re-canonicalizing a canonical id is a
#     no-op, which is what makes a caller's raw URL and an existing id agree.
#   - Delivery ledger: $STATE/threads/deliveries.log, append-only, one row per
#     delivery attempt:
#       <epoch>\t<thread-id>\t<kind>\t<target>\t<outcome>
#     outcome is delivery (the fired record landed), delivery-unfired (the
#     installed fm-send has no fired delivery for a crew task, so it landed as
#     an ordinary steer), copy (handed to firstmate because the owner is gone),
#     or failed (nothing was delivered; the caller retries).
#     This ledger is also what the 7-day measurement reads
#     (bin/fm-thread-wake-measure.sh), so append it for every attempt.
#   - Lane cursor: $STATE/threads/.lane-cursor/<source-task> holds one decimal
#     byte offset: how much of that task's status log this script has already
#     examined for steer lines. A cursor larger than the file (a replaced log)
#     resets to 0. A task seen for the first time starts at end-of-file, so
#     installing this never re-delivers a log's history; --backfill opts in to
#     it deliberately. Delivery ids are derived from the source line's offset,
#     so a re-scanned line collapses onto the record already present instead of
#     becoming a second instruction.
#
# DELIVERY reuses the existing steering-inbox transport, not a new one:
#   fm-send.sh <task> --fire-and-forget <16-hex-id> <text>
# The fired delivery is what keeps a thread event off the watcher's re-ring
# ladder, so an event never climbs into a firstmate escalation
# (bin/fm-task-inbox-lib.sh owns the record format and the ladder). The family
# of fm-send that predates fired delivery to an ordinary crew task needs no
# second code path: the fired attempt is simply retried as an ordinary steer and
# the ledger records delivery-unfired.
#
# A LANE STEER is the one event class with a status-log source. A line matching
#   need[s] firstmate: steer <lane>: <text>
# anywhere in a line of state/<task>.status, written by the watcher's poll
# (bin/fm-watch.sh) so no firstmate turn is involved, is delivered to that
# lane's own inbox as one lane-<lane> thread event, and the lane is subscribed
# to its own thread so later events about it reach the same place. Firstmate
# gets a durable copy only when the lane is gone: no metadata here, or an
# endpoint the backend reports dead or missing. A recorded but merely
# unresponsive lane keeps its place in the log and is retried on the next scan.
#
# Usage:
#   fm-thread-deliver.sh add <thread> <task> [--role <role>]
#   fm-thread-deliver.sh remove <thread> <task>
#   fm-thread-deliver.sh list [<thread>]
#   fm-thread-deliver.sh deliver <thread> [--from <task>] [--kind <label>]
#                                       [--stdin] [<text>...]
#   fm-thread-deliver.sh pr-event <pr-url|mr-url> [--from <task>]
#                                       [--kind <label>] [--stdin] [<text>...]
#   fm-thread-deliver.sh lane-scan [--dry-run] [--backfill] [<status-file>...]
#   fm-thread-deliver.sh retire <task>
#   fm-thread-deliver.sh thread-id <pr-url|raw-id>
#   fm-thread-deliver.sh --help
#
# Exit status: 0 when every delivery was confirmed (including "no subscribers"),
# 1 when any delivery failed or the request was invalid. `deliver` prints one
# summary line on stdout; the watcher discards it.
#
# Environment:
#   FM_HOME, FM_STATE_OVERRIDE, FM_ROOT_OVERRIDE  operational home and state.
#   FM_THREAD_SCAN_MAX_BYTES  default 1048576; per-file span cap for lane-scan,
#                             truncated at a line boundary so no line is split.
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SELF_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
THREADS="$STATE/threads"
LEDGER="$THREADS/deliveries.log"
CURSORS="$THREADS/.lane-cursor"
SEND="$FM_ROOT/bin/fm-send.sh"
SCAN_MAX_BYTES_DEFAULT=1048576

# shellcheck source=bin/fm-pr-lib.sh
. "$FM_ROOT/bin/fm-pr-lib.sh"

die() { printf 'fm-thread-deliver: %s\n' "$*" >&2; exit 1; }

usage() { sed -n '/^# Usage:/,/^# Environment:/p' "${BASH_SOURCE[0]}" | sed -e 's/^# \{0,1\}//' -e '$d'; }

# --- identity ---------------------------------------------------------------

# Canonical thread id: lowercase, path-safe, idempotent. A raw PR/MR URL is
# parsed by the shared forge identity owner so this script never re-derives
# GitHub/GitLab URL shapes of its own.
fm_thread_canonical_id() {  # <raw>
  local raw=${1:-} slug
  case "$raw" in
    https://*)
      fm_pr_url_parse "$raw" || return 1
      raw="pr-${FM_PR_HOST}-${FM_PR_PATH}-${FM_PR_NUMBER}"
      ;;
  esac
  slug=$(printf '%s' "$raw" | LC_ALL=C tr '[:upper:]' '[:lower:]' \
    | LC_ALL=C sed -e 's/[^a-z0-9._-][^a-z0-9._-]*/-/g' \
        -e 's/^-*//' -e 's/-*$//')
  [ -n "$slug" ] || return 1
  case "$slug" in
    .*|*[!a-z0-9._-]*) return 1 ;;
  esac
  printf '%s' "$slug"
}

fm_thread_task_valid() {  # <task-id>
  case "${1:-}" in
    ''|.*|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
}

fm_thread_role_valid() {  # <role>
  case "${1:-}" in
    ''|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
}

fm_thread_subs_path() {  # <thread-id>
  printf '%s/%s.subs' "$THREADS" "$1"
}

# Subscriber task ids of one thread, one per line, in recorded order, deduped.
fm_thread_subscribers() {  # <thread-id>
  local file
  file=$(fm_thread_subs_path "$1")
  [ -f "$file" ] || return 0
  LC_ALL=C awk -F '\t' '
    /^[[:space:]]*#/ { next }
    NF >= 1 && $1 != "" && !seen[$1]++ { print $1 }
  ' "$file"
}

fm_thread_sha16() {  # <text>
  local h
  if command -v shasum >/dev/null 2>&1; then
    h=$(printf '%s' "$1" | shasum -a 256 | awk '{print $1}')
  elif command -v sha256sum >/dev/null 2>&1; then
    h=$(printf '%s' "$1" | sha256sum | awk '{print $1}')
  else
    printf 'fm-thread-deliver: shasum or sha256sum is required\n' >&2
    return 1
  fi
  printf '%s' "${h:0:16}"
}

fm_thread_delivery_id() {  # <thread-id> <task> <kind> <idempotence-key>
  fm_thread_sha16 "thread:$1|to:$2|kind:$3|key:$4"
}

# --- ledger -----------------------------------------------------------------

fm_thread_record() {  # <thread-id> <kind> <target> <outcome>
  mkdir -p "$THREADS"
  printf '%s\t%s\t%s\t%s\t%s\n' "$(date +%s)" "$1" "$2" "$3" "$4" >> "$LEDGER"
}

# --- wake fallback ----------------------------------------------------------

# Firstmate's own copy. A thread event reaches firstmate only when the owner is
# gone, and it arrives as an ordinary durable check wake naming the lane, the
# thread, and the event's first line, so the relay it used to do by hand is one
# queued row instead of a status-log line discovered later.
fm_thread_firstmate_copy() {  # <thread-id> <lane> <text>
  local thread=$1 lane=$2 text=$3 teaser key
  # shellcheck source=/dev/null
  FM_ROOT_OVERRIDE="$FM_ROOT" FM_HOME="$FM_HOME" STATE="$STATE" . "$FM_ROOT/bin/fm-wake-lib.sh"
  teaser=$(printf '%s' "$text" | LC_ALL=C tr '\t\r\n' '   ')
  [ "${#teaser}" -le 240 ] || teaser="${teaser:0:240}..."
  key="thread-steer:$lane"
  fm_wake_append check "$key" "check: thread-steer $thread: $lane is gone - $teaser"
}

# --- delivery ---------------------------------------------------------------

# Deliver one thread event to one subscriber. Prints the outcome word.
# The fired delivery id is derived from the caller's idempotence key, so the
# same event re-attempted collapses onto the record already present.
fm_thread_send() {  # <task> <thread-id> <kind> <text> <idempotence-key>
  local task=$1 thread=$2 kind=$3 text=$4 idem=$5 id err rc
  id=$(fm_thread_delivery_id "$thread" "$task" "$kind" "$idem") || return 1
  err="$STATE/.thread-send.err"
  if FM_ROOT_OVERRIDE="$FM_ROOT" FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" \
    "$SEND" "$task" --fire-and-forget "$id" "$text" >/dev/null 2>"$err"; then
    rm -f -- "$err"
    printf 'delivery'
    return 0
  fi
  # An installed fm-send without fired delivery to an ordinary crew task refuses
  # the flag before writing anything, so nothing is duplicated by retrying the
  # same event as an ordinary steer. Every other failure (an unreachable
  # endpoint, an unwritable inbox) fails here too and is reported as failed.
  if FM_ROOT_OVERRIDE="$FM_ROOT" FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" \
    "$SEND" "$task" "$text" >/dev/null 2>>"$err"; then
    rc=0
  else
    rc=1
  fi
  if [ "$rc" -eq 0 ]; then
    printf 'delivery-unfired'
    rm -f -- "$err"
    return 0
  fi
  printf 'fm-thread-deliver: delivery to %s failed: %s\n' "$task" \
    "$(tr '\n' ' ' < "$err" 2>/dev/null | cut -c1-400)" >&2
  rm -f -- "$err"
  printf 'failed'
  return 1
}

# --- subcommands ------------------------------------------------------------

cmd_add() {
  local thread task role=member added file
  [ "$#" -ge 2 ] || die "add needs <thread> <task>"
  thread=$(fm_thread_canonical_id "$1") || die "invalid thread id: $1"
  task=$2
  fm_thread_task_valid "$task" || die "invalid task id: $task"
  shift 2
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --role) [ "$#" -ge 2 ] || die "--role needs a value"; role=$2; shift 2 ;;
      --role=*) role=${1#--role=}; shift ;;
      *) die "unexpected argument: $1" ;;
    esac
  done
  fm_thread_role_valid "$role" || die "invalid role: $role"
  mkdir -p "$THREADS"
  file=$(fm_thread_subs_path "$thread")
  if [ -f "$file" ] && fm_thread_subscribers "$thread" | LC_ALL=C grep -qxF -- "$task"; then
    return 0
  fi
  added=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  printf '%s\t%s\t%s\n' "$task" "$role" "$added" >> "$file" \
    || die "could not record the subscription"
  printf 'added: %s %s %s\n' "$thread" "$task" "$role"
}

cmd_remove() {
  local thread task file tmp
  [ "$#" -eq 2 ] || die "remove needs <thread> <task>"
  thread=$(fm_thread_canonical_id "$1") || die "invalid thread id: $1"
  task=$2
  fm_thread_task_valid "$task" || die "invalid task id: $task"
  file=$(fm_thread_subs_path "$thread")
  [ -f "$file" ] || return 0
  tmp=$(mktemp "$THREADS/.subs.XXXXXX") || die "could not stage the subscription file"
  if ! LC_ALL=C awk -F '\t' -v task="$task" '$1 != task' "$file" > "$tmp"; then
    rm -f -- "$tmp"
    die "could not rewrite the subscription file"
  fi
  mv -f -- "$tmp" "$file" || { rm -f -- "$tmp"; die "could not replace the subscription file"; }
  printf 'removed: %s %s\n' "$thread" "$task"
}

cmd_list() {
  local thread file rows
  if [ "$#" -eq 0 ]; then
    [ -d "$THREADS" ] || return 0
    for file in "$THREADS"/*.subs; do
      [ -e "$file" ] || continue
      thread=$(basename "$file" .subs)
      rows=$(LC_ALL=C awk -F '\t' -v t="$thread" '
        /^[[:space:]]*#/ { next }
        NF >= 1 && $1 != "" { printf "%s\t%s\t%s\t%s\n", t, $1, ($2 == "" ? "member" : $2), $3 }
      ' "$file")
      [ -z "$rows" ] || printf '%s\n' "$rows"
    done
    return 0
  fi
  thread=$(fm_thread_canonical_id "$1") || die "invalid thread id: $1"
  file=$(fm_thread_subs_path "$thread")
  [ -f "$file" ] || return 0
  LC_ALL=C awk -F '\t' -v t="$thread" '
    /^[[:space:]]*#/ { next }
    NF >= 1 && $1 != "" { printf "%s\t%s\t%s\t%s\n", t, $1, ($2 == "" ? "member" : $2), $3 }
  ' "$file"
}

# Shared body for `deliver` and `pr-event`: resolve the thread from the first
# argument, read the event body, fan it out to every subscriber but the origin.
cmd_deliver_like() {  # <raw-thread-or-url> [--from <task>] [--kind <label>] [--stdin] [<text>...]
  local raw=${1:-} thread from='' kind=event text='' delivered=0 failed=0 skipped=0
  local task outcome
  [ -n "$raw" ] || die "an event needs a thread"
  shift
  thread=$(fm_thread_canonical_id "$raw") || die "invalid thread id: $raw"
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --from) [ "$#" -ge 2 ] || die "--from needs a task id"; from=$2; shift 2 ;;
      --from=*) from=${1#--from=}; shift ;;
      --kind) [ "$#" -ge 2 ] || die "--kind needs a value"; kind=$2; shift 2 ;;
      --kind=*) kind=${1#--kind=}; shift ;;
      --stdin) text=$(cat); shift ;;
      *) text="$text${text:+ }$1"; shift ;;
    esac
  done
  [ -n "${text//[[:space:]]/}" ] || die "refusing an empty thread event"
  if [ -n "$from" ]; then
    fm_thread_task_valid "$from" || die "invalid --from task id: $from"
  fi
  # A thread event is content-addressed: the same event re-sent (a producer
  # re-running against the same event) collapses onto the record already
  # present, while a genuinely different event reads differently and lands.
  idem=$(fm_thread_sha16 "$text") || die "could not derive a delivery id"
  while IFS= read -r task; do
    [ -n "$task" ] || continue
    if [ -n "$from" ] && [ "$task" = "$from" ]; then
      skipped=$((skipped + 1))
      continue
    fi
    outcome=$(fm_thread_send "$task" "$thread" "$kind" "$text" "$idem") \
      || failed=$((failed + 1))
    fm_thread_record "$thread" "$kind" "$task" "$outcome"
    [ "$outcome" = failed ] || delivered=$((delivered + 1))
  done <<EOF
$(fm_thread_subscribers "$thread")
EOF
  printf 'fm-thread-deliver: %s: %s delivered, %s failed, %s skipped\n' \
    "$thread" "$delivered" "$failed" "$skipped"
  [ "$failed" -eq 0 ]
}

# --- lane steer -------------------------------------------------------------

# Byte length of a file, portably.
fm_thread_file_size() {  # <file>
  wc -c < "$1" | LC_ALL=C tr -d '[:space:]'
}

# Read the cursor for one source task, or print nothing when there is none.
fm_thread_cursor_read() {  # <source-task>
  local path="$CURSORS/$1" value
  [ -f "$path" ] || return 0
  IFS= read -r value < "$path" || return 0
  case "$value" in ''|*[!0-9]*) return 0 ;; esac
  printf '%s' "$value"
}

fm_thread_cursor_write() {  # <source-task> <offset>
  local path="$CURSORS/$1" tmp
  mkdir -p "$CURSORS"
  tmp=$(mktemp "$CURSORS/.cursor.XXXXXX") || return 1
  if ! printf '%s\n' "$2" > "$tmp"; then
    rm -f -- "$tmp"
    return 1
  fi
  if ! mv -f -- "$tmp" "$path"; then
    rm -f -- "$tmp"
    return 1
  fi
  return 0
}

# Backend liveness verdict for a recorded lane, using the shared recovery-grade
# classifier (bin/fm-backend.sh's fm_backend_agent_alive). Prints
# gone|alive|dead|unknown. `gone` means this home has no metadata for the lane at
# all, so nothing can ever pick the instruction up. An unverified or ambiguous
# backend stays unknown, never dead, because only a confident verdict may settle
# a steer: an unknown lane keeps its line and is retried on the next scan.
# One forked subshell keeps the backend graph out of every other subcommand.
fm_thread_lane_state() {  # <task> <state>
  local meta="$2/$1.meta"
  [ -f "$meta" ] || { printf 'gone'; return 0; }
  FM_ROOT_OVERRIDE="$FM_ROOT" FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$2" \
    bash -c '
      . "$1/bin/fm-backend.sh" || exit 3
      backend=$(fm_backend_of_meta "$2") || exit 3
      target=$(fm_backend_target_of_meta "$2") || exit 3
      if [ -z "$backend" ] || [ -z "$target" ]; then
        printf unknown
        exit 0
      fi
      fm_backend_agent_alive "$backend" "$target"
    ' _ "$FM_ROOT" "$meta" 2>/dev/null || printf 'unknown'
}

# Inspect one status log's new bytes for steer lines and deliver each one.
# Advances the cursor only past lines it has settled: a delivered steer, a
# steer handed to firstmate because its lane is gone, or a self-directed line.
# A recorded lane whose send failed for an inconclusive reason leaves the
# cursor at that line so the next scan retries it.
cmd_lane_scan_one() {  # <status-file> <dry-run 0|1> <backfill 0|1>
  local file=$1 dry=$2 backfill=$3 task size offset raw span cap consumed scan new_offset trimmed
  local line_pos lane text thread state outcome
  task=$(basename "$file"); task=${task%.status}
  fm_thread_task_valid "$task" || return 0
  size=$(fm_thread_file_size "$file")
  offset=$(fm_thread_cursor_read "$task")
  if [ -z "$offset" ]; then
    if [ "$backfill" = 1 ]; then
      offset=0
    elif [ "$dry" = 1 ]; then
      # A dry run never writes a cursor, so it must report what a real scan
      # would do on a file this script has not seen yet: start at end-of-file
      # rather than replay the log's history.
      offset=$size
    else
      fm_thread_cursor_write "$task" "$size" || true
      return 0
    fi
  fi
  [ "$offset" -le "$size" ] || offset=0
  [ "$offset" -lt "$size" ] || return 0
  cap=${FM_THREAD_SCAN_MAX_BYTES:-$SCAN_MAX_BYTES_DEFAULT}
  case "$cap" in ''|*[!0-9]*) cap=$SCAN_MAX_BYTES_DEFAULT ;; esac
  consumed=$(( size - offset ))
  [ "$consumed" -le "$cap" ] || consumed=$cap
  # FMSENTINEL keeps the span byte-exact: a command substitution would strip
  # trailing newlines, and the sentinel lets one awk pass measure how many bytes
  # end on a complete line. Only complete lines are ever consumed, so a status
  # write caught mid-line is examined on the next scan instead of being parsed
  # as a truncated half, and a capped span never strands a line across scans.
  # Every trim below is a pattern removal, never a character-count substring:
  # a multi-byte status log must be cut on byte boundaries.
  raw=$( { tail -c "+$(( offset + 1 ))" "$file" | head -c "$consumed"; printf 'FMSENTINEL'; } ) || return 1
  scan=$(printf '%s' "$raw" | LC_ALL=C awk '
    { if (NR > 1) pos += prev + 1; prev = length($0) }
    END { print pos + 0 }
  ')
  case "$scan" in ''|*[!0-9]*) scan=0 ;; esac
  [ "$scan" -gt 0 ] || return 0
  span=${raw%FMSENTINEL}
  case "$raw" in
    *$'\n'FMSENTINEL) ;;
    *)
      trimmed=${span%$'\n'*}
      if [ "$trimmed" = "$span" ]; then span=; else span=$trimmed; fi
      ;;
  esac
  new_offset=$(( offset + scan ))
  while IFS=$'\t' read -r line_pos lane text; do
    [ -n "${lane:-}" ] || continue
    [ "$lane" != "$task" ] || continue
    thread=$(fm_thread_canonical_id "lane-$lane") || continue
    if [ "$dry" = 1 ]; then
      printf 'would deliver: %s -> %s (%s)\n' "$task@$(( offset + line_pos ))" "$thread" "${text:0:80}"
      continue
    fi
    state=$(fm_thread_lane_state "$lane" "$STATE")
    if [ "$state" = gone ]; then
      fm_thread_firstmate_copy "$thread" "$lane" "$text"
      fm_thread_record "$thread" steer firstmate copy
      printf 'fm-thread-deliver: %s: lane %s is gone; the steer is queued for firstmate\n' \
        "$task" "$lane" >&2
      continue
    fi
    if ! fm_thread_subscribers "$thread" | LC_ALL=C grep -qxF -- "$lane"; then
      cmd_add "$thread" "$lane" --role lane >/dev/null || die "could not subscribe $lane to $thread"
    fi
    if outcome=$(fm_thread_send "$lane" "$thread" steer "$text" "$task:$(( offset + line_pos ))") ; then
      fm_thread_record "$thread" steer "$lane" "$outcome"
    else
      fm_thread_record "$thread" steer "$lane" failed
      if [ "$state" = dead ]; then
        fm_thread_firstmate_copy "$thread" "$lane" "$text"
        fm_thread_record "$thread" steer firstmate copy
        continue
      fi
      # Inconclusive: leave the cursor at this line and stop, so the next scan
      # retries the same line under the same idempotent delivery id.
      new_offset=$(( offset + line_pos ))
      break
    fi
  done <<EOF
$(printf '%s' "$span" | LC_ALL=C awk '
  {
    if (match($0, /needs? firstmate: steer[ \t]+[A-Za-z0-9][A-Za-z0-9._-]*:/)) {
      head = substr($0, RSTART, RLENGTH)
      lane = head
      sub(/^needs? firstmate: steer[ \t]+/, "", lane)
      sub(/[ \t]*:$/, "", lane)
      text = substr($0, RSTART + RLENGTH)
      sub(/^[ \t]+/, "", text)
      sub(/[ \t]+$/, "", text)
      if (text != "") printf "%d\t%s\t%s\n", pos, lane, text
    }
    pos += length($0) + 1
  }')
EOF
  fm_thread_cursor_write "$task" "$new_offset" || return 1
  return 0
}

cmd_lane_scan() {
  local dry=0 backfill=0 file rc=0
  local -a files=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --dry-run) dry=1; shift ;;
      --backfill) backfill=1; shift ;;
      --) shift; while [ "$#" -gt 0 ]; do files+=("$1"); shift; done ;;
      *) files+=("$1"); shift ;;
    esac
  done
  if [ "${#files[@]}" -eq 0 ]; then
    for file in "$STATE"/*.status; do
      [ -e "$file" ] || continue
      files+=("$file")
    done
  fi
  for file in "${files[@]+"${files[@]}"}"; do
    case "$file" in *.status) ;; *) continue ;; esac
    [ -f "$file" ] || continue
    cmd_lane_scan_one "$file" "$dry" "$backfill" || rc=1
  done
  return "$rc"
}

# --- retirement -------------------------------------------------------------

cmd_retire() {
  [ "$#" -eq 1 ] || die "retire needs <task>"
  local task=$1 file thread
  fm_thread_task_valid "$task" || die "invalid task id: $task"
  rm -f -- "$CURSORS/$task"
  [ -d "$THREADS" ] || return 0
  for file in "$THREADS"/*.subs; do
    [ -e "$file" ] || continue
    LC_ALL=C grep -qF -- "$task" "$file" 2>/dev/null || continue
    thread=$(basename "$file" .subs)
    cmd_remove "$thread" "$task" >/dev/null
  done
  return 0
}

# --- dispatch ---------------------------------------------------------------

case "${1:-}" in
  add)
    shift
    cmd_add "$@"
    ;;
  remove)
    shift
    cmd_remove "$@"
    ;;
  list)
    shift
    cmd_list "$@"
    ;;
  deliver)
    shift
    cmd_deliver_like "$@"
    ;;
  pr-event)
    shift
    cmd_deliver_like "$@"
    ;;
  lane-scan)
    shift
    cmd_lane_scan "$@"
    ;;
  retire)
    shift
    cmd_retire "$@"
    ;;
  thread-id)
    shift
    [ "$#" -eq 1 ] || die "thread-id needs exactly one argument"
    fm_thread_canonical_id "$1" || die "invalid thread id: $1"
    ;;
  --help|-h|help)
    usage
    ;;
  *)
    usage >&2
    exit 1
    ;;
esac
