#!/usr/bin/env bash
# fm-task-inbox-lib.sh - the per-task steering inbox: durable records plus a
# constant doorbell.
#
# ONE owner of the steering-inbox contract: the record format, sequence
# allocation, the idempotent re-enqueue dedup, the handled/ acknowledgement,
# the self-describing doorbell line, and the watcher's re-ring ladder policy.
# bin/fm-send.sh writes and rings locally, the host-local remote steer leg
# (bin/fm-remote-secondmate-control.sh cmd_send) writes idempotently and rings
# on the remote host, bin/fm-watch.sh polls and re-rings, and the brief
# scaffold (bin/fm-brief.sh) tells the worker how to read and acknowledge;
# none of them restates the format.
#
# Design (captain-adopted, data/fm-send-reliability-reframe-s1/report.md): the
# payload moves to the filesystem, which is reliable; the terminal carries only
# a short constant doorbell line, which does not need to be reliable because
# ringing it again is free. A duplicated doorbell is a no-op by construction
# (the worker finds the inbox empty or already handled), a swallowed doorbell
# is detected by the absence of the worker's acknowledgement and re-rung on a
# bounded schedule, and a worker that never acknowledges surfaces through the
# ordinary stale wake into stuck-crewmate-recovery.
#
# Layout under <state-dir>:
#   <task>.inbox/NNN.msg       one durable steer, numeric sequence, atomic rename
#   <task>.inbox/handled/      the worker's `mv` here IS the acknowledgement
#   <task>.inbox/.seq.lock     serializes sequence allocation across writers
#                              (the session and the away daemon)
#   <task>.inbox/.ring-state   watcher re-ring ladder: "<msg>\t<count>\t<epoch>"
#   <task>.inbox/.escalated    oldest-message name already surfaced as stale,
#                              so later polls suppress another escalation
#   <task>.inbox/.overdue      oldest-message name already surfaced as overdue
#                              (the liveness signal below), so it is surfaced
#                              once per message, not every poll
#
# Record format (fm_task_inbox_write / fm_task_inbox_body):
#   schema=fm-task-inbox.v1
#   at=<utc timestamp>
#   delivery=fire-and-forget   present only when the re-ring ladder must ignore it
#   coalesce=<key>             present only on a coalescing record (below)
#   --
#   <exact message text; newlines are legal; a marked secondmate request keeps
#    its from-firstmate marker and corr token verbatim in this body>
#
# Sequence numbers are never reused within a task: allocation scans both the
# inbox root and handled/, so a message is processed at most once per worker
# lifetime even if every doorbell is duplicated. Concurrent writers serialize
# on .seq.lock; the worst racing outcome is ordering, never loss.
#
# Coalescing (fm_task_inbox_write_coalesced): a periodic idempotent
# instruction - a scheduled lane tick - must not pile up behind a worker that
# has not drained it, because N unhandled copies carry no more information
# than one. A coalescing write records coalesce=<key> and then deletes every
# OTHER unhandled record that carries the same key or whose exact body equals
# the new one (the second rule also drains copies queued before the sender
# marked them). The new record is written first, so at least one copy is
# always present, and it takes a fresh sequence number, so it orders after
# every instruction already queued. Handled records are never touched, a
# fire-and-forget record is never replaced by body match, and a worker that
# loses a race to the deletion only finds its mv target gone. Replacing the
# re-ring ladder's current oldest record must not restart that ladder: the
# record that becomes oldest inherits the superseded one's mtime and its
# .ring-state/.escalated/.overdue bookkeeping, so a worker that never drains
# its ticks still escalates, and is not surfaced as overdue again per tick.
#
# Re-ring ladder (fm_task_inbox_due_action): an unhandled message older than
# FM_TASK_INBOX_GRACE_SECS is due one delivery attempt per grace period; an
# attempt may ring or be skipped to protect proven pending composer text. After
# FM_TASK_INBOX_RING_MAX attempts without an acknowledgement it escalates. The
# caller owns the busy check (a busy pane just waits - the record is durable and
# the worker reaches a turn boundary) and the wake emission; this library owns
# only the schedule. If attempt bookkeeping cannot be persisted while the record
# remains unhandled, the caller surfaces that failure instead of retrying
# silently; a concurrently removed inbox is a quiet no-op. Escalation
# deliberately queues the wake before writing the
# deduplication marker: normal polls surface a message once, while a crash or
# marker failure may produce a rare duplicate rather than silently lose a wake.
#
# Overdue liveness signal (fm_task_inbox_overdue): the ladder above escalates
# ONCE, on an idle pane, and then hands the message to recovery - so a worker
# that reads busy, or whose single escalation was not acted on, can sit for
# days with an unread instruction while the doorbell keeps ringing (three
# lanes did, 2026-10-26). Independently of the ladder, an escalation-tracked
# record left unacknowledged for longer than FM_TASK_INBOX_OVERDUE_SECS -
# twice the expected acknowledgement cadence FM_TASK_INBOX_CADENCE_SECS by
# default - is overdue whatever the pane shows, and the watcher surfaces it as
# one stale wake naming the record, its age, and the recovery (a fresh task
# id through stuck-crewmate-recovery). The .overdue marker makes it once per
# message; the acknowledgement clears it with the rest of the bookkeeping.
#
# fm_task_inbox_ring requires bin/fm-backend.sh's dispatch (sourced below); the
# other helpers are dependency-light. Sourced by bin/fm-send.sh, bin/fm-watch.sh,
# and tests. No side effects on source beyond its sourced libraries.
#
# Tunables (env):
#   FM_TASK_INBOX_GRACE_SECS   default 90; delivery-attempt grace and spacing
#   FM_TASK_INBOX_RING_MAX     default 3; delivery attempts before escalation
#   FM_TASK_INBOX_LOCK_WAIT_SECS  default 15; bounded wait for the sequence and
#                              metadata locks before a send is refused
#   FM_TASK_INBOX_CADENCE_SECS  default 3600; how long a worker is expected to
#                              take to acknowledge an instruction
#   FM_TASK_INBOX_OVERDUE_SECS  default 2x the cadence; age past which an
#                              unacknowledged instruction is surfaced as overdue

_FM_TASK_INBOX_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Both dependencies are canonical lint roots in their own right. Keep them as
# analysis boundaries here so ShellCheck's external-source traversal does not
# recursively duplicate the full backend graph for every inbox consumer.
# shellcheck source=/dev/null
. "$_FM_TASK_INBOX_LIB_DIR/fm-wake-lib.sh"
# shellcheck source=/dev/null
. "$_FM_TASK_INBOX_LIB_DIR/fm-backend.sh"

FM_TASK_INBOX_SCHEMA='fm-task-inbox.v1'
FM_TASK_INBOX_GRACE_DEFAULT=90
FM_TASK_INBOX_RING_MAX_DEFAULT=3
FM_TASK_INBOX_LOCK_WAIT_DEFAULT=15
FM_TASK_INBOX_CADENCE_DEFAULT=3600

fm_task_inbox_cadence_secs() {
  local c=${FM_TASK_INBOX_CADENCE_SECS:-$FM_TASK_INBOX_CADENCE_DEFAULT}
  case "$c" in ''|*[!0-9]*|0) c=$FM_TASK_INBOX_CADENCE_DEFAULT ;; esac
  printf '%s' "$c"
}

fm_task_inbox_overdue_secs() {
  local o=${FM_TASK_INBOX_OVERDUE_SECS:-}
  case "$o" in ''|*[!0-9]*|0) o=$(( $(fm_task_inbox_cadence_secs) * 2 )) ;; esac
  printf '%s' "$o"
}

fm_task_inbox_grace_secs() {
  local g=${FM_TASK_INBOX_GRACE_SECS:-$FM_TASK_INBOX_GRACE_DEFAULT}
  case "$g" in ''|*[!0-9]*) g=$FM_TASK_INBOX_GRACE_DEFAULT ;; esac
  printf '%s' "$g"
}

fm_task_inbox_ring_max() {
  local m=${FM_TASK_INBOX_RING_MAX:-$FM_TASK_INBOX_RING_MAX_DEFAULT}
  case "$m" in ''|*[!0-9]*) m=$FM_TASK_INBOX_RING_MAX_DEFAULT ;; esac
  printf '%s' "$m"
}

fm_task_inbox_dir() {  # <state-dir> <task-id>
  printf '%s/%s.inbox' "$1" "$2"
}

fm_task_inbox_handled_dir() {  # <state-dir> <task-id>
  printf '%s/%s.inbox/handled' "$1" "$2"
}

# Numeric sequence of one record basename, or fail for a non-record name.
fm_task_inbox_seq_of() {  # <basename>
  local n=${1%.msg}
  [ "$n" != "$1" ] || return 1
  case "$n" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s' "$((10#$n))"
}

# Next unused sequence, scanning the inbox root AND handled/ so an
# acknowledged sequence is never reissued. Caller must hold .seq.lock.
fm_task_inbox_next_seq() {  # <inbox-dir>
  local dir=$1 max=0 d f n
  for d in "$dir" "$dir/handled"; do
    for f in "$d"/*.msg; do
      [ -e "$f" ] || continue
      n=$(fm_task_inbox_seq_of "${f##*/}") || continue
      [ "$n" -le "$max" ] || max=$n
    done
  done
  printf '%03d' "$((max + 1))"
}

# Bounded acquire for the sequence lock and the task metadata lock that
# fm-send and the remote steer leg take around final delivery validation.
# A holder that died is reclaimed by fm_lock_try_acquire; a holder whose pid
# was recycled by an unrelated live process is reaped by fm_lock_reap_stale
# (bin/fm-wake-lib.sh) once its record is old enough. Either reclaim prints
# one stderr line naming the lock and the gone holder, so a recovered send
# leaves evidence instead of silently stealing.
# While a verified live holder keeps the lock, the wait re-reads its pid with
# shell builtins instead of re-running the claim: each claim attempt forks a
# dozen processes, and on a loaded host contending writers spent the whole
# bounded wait in those forks (slowing the holder too) and refused sends that
# a cheaper wait would have delivered.
_fm_task_inbox_lock_live_holder() {  # <lock-path> <own-pid>
  local pid
  [ -e "$1/pid" ] || return 1
  IFS= read -r pid < "$1/pid" 2>/dev/null || return 1
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  [ "$pid" != "$2" ] || return 1
  fm_pid_alive "$pid"
}

fm_task_inbox_lock_acquire() {  # <lock-path>
  local lock=$1 wait=${FM_TASK_INBOX_LOCK_WAIT_SECS:-$FM_TASK_INBOX_LOCK_WAIT_DEFAULT}
  local deadline probe reaped reap_tried=0 self=
  case "$wait" in ''|*[!0-9]*) wait=$FM_TASK_INBOX_LOCK_WAIT_DEFAULT ;; esac
  probe=$(mktemp "${lock%/*}/.lock-probe.XXXXXX") || return 1
  rm -f "$probe" || return 1
  if [ ! -e "$lock" ] && [ ! -L "$lock" ]; then
    fm_lock_try_create "$lock" && return 0
  fi
  fm_current_pid self || self=
  deadline=$(( SECONDS + wait ))
  while :; do
    if [ "$reap_tried" -eq 1 ] && _fm_task_inbox_lock_live_holder "$lock" "$self"; then
      [ "$SECONDS" -lt "$deadline" ] || return 1
      sleep 0.05
      continue
    fi
    fm_lock_try_acquire "$lock" && break
    # One reuse probe per acquisition: a record's age cannot cross the reap
    # threshold meaningfully inside this short wait, and probing every spin
    # would tax the very contention it waits out.
    if [ "$reap_tried" -eq 0 ]; then
      reap_tried=1
      if [ -n "${FM_LOCK_HELD_PID:-}" ] && reaped=$(fm_lock_reap_stale "$lock"); then
        echo "fm-task-inbox: reclaimed stale lock: $reaped" >&2
        continue
      fi
    fi
    [ "$SECONDS" -lt "$deadline" ] || return 1
    sleep 0.1
  done
  if [ -n "${FM_LOCK_RECOVERED_PID:-}" ]; then
    echo "fm-task-inbox: reclaimed stale lock: $lock from dead holder pid=$FM_LOCK_RECOVERED_PID" >&2
  fi
  return 0
}

# Write one record into the next sequence slot: temp-write, then atomic
# rename. Prints the record path. Caller must hold .seq.lock.
_fm_task_inbox_write_record_locked() {  # <inbox-dir> <text> [delivery-mode] [coalesce-key]
  local dir=$1 text=$2 delivery_mode=${3:-} coalesce=${4:-} seq tmp rec status=0
  seq=$(fm_task_inbox_next_seq "$dir")
  rec="$dir/$seq.msg"
  tmp=$(mktemp "$dir/.staging.XXXXXX") || return 1
  {
    printf 'schema=%s\n' "$FM_TASK_INBOX_SCHEMA"
    printf 'at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    [ "$delivery_mode" != fire-and-forget ] || printf 'delivery=fire-and-forget\n'
    [ -z "$coalesce" ] || printf 'coalesce=%s\n' "$coalesce"
    printf -- '--\n'
    printf '%s' "$text"
  } > "$tmp" && mv "$tmp" "$rec" || status=1
  [ "$status" -eq 0 ] || { rm -f "$tmp"; return 1; }
  printf '%s' "$rec"
}

# Durably enqueue one steer: temp-write, then atomic rename into the next
# sequence slot. Prints the record path. Fails without a partial record.
fm_task_inbox_write() {  # <state-dir> <task-id> <text> [delivery-mode]
  local state=$1 task=$2 text=$3 delivery_mode=${4:-} dir lock rec status=0
  dir=$(fm_task_inbox_dir "$state" "$task")
  mkdir -p "$dir/handled" || return 1
  lock="$dir/.seq.lock"
  fm_task_inbox_lock_acquire "$lock" || return 1
  rec=$(_fm_task_inbox_write_record_locked "$dir" "$text" "$delivery_mode") || status=1
  fm_lock_release "$lock"
  [ "$status" -eq 0 ] || return 1
  printf '%s' "$rec"
}

# Durably enqueue one steer at most once: when a record with the exact same
# body already exists - unhandled or already acknowledged in handled/ - no new
# record is written and the existing record's path is printed instead.
# This is the enqueue primitive for a transport that can fail with completion
# unknown (the remote steer leg over ssh): the caller's safe recovery is to run
# the same enqueue again, and this dedup is what makes the re-run land on the
# same record instead of a duplicate the worker would act on twice. Two
# distinct logical requests never collapse in practice because a marked
# secondmate request embeds a per-request correlation token in its body. The
# local plane keeps plain fm_task_inbox_write: its outcome is synchronous, so
# a repeated identical local steer is a deliberate new instruction.
fm_task_inbox_write_idempotent() {  # <state-dir> <task-id> <text> [delivery-mode]
  local state=$1 task=$2 text=$3 delivery_mode=${4:-} dir lock want have f rec='' status=0
  dir=$(fm_task_inbox_dir "$state" "$task")
  mkdir -p "$dir/handled" || return 1
  lock="$dir/.seq.lock"
  fm_task_inbox_lock_acquire "$lock" || return 1
  if want=$(mktemp "$dir/.dedup.XXXXXX") && have=$(mktemp "$dir/.dedup.XXXXXX"); then
    if printf '%s' "$text" > "$want"; then
      for f in "$dir"/*.msg "$dir/handled"/*.msg; do
        if [ ! -e "$f" ]; then
          case "$f" in
            "$dir"/*.msg)
              f="$dir/handled/${f##*/}"
              [ -e "$f" ] || continue
              ;;
            *) continue ;;
          esac
        fi
        if [ "$delivery_mode" = fire-and-forget ]; then
          fm_task_inbox_is_fire_and_forget "$f" || continue
        elif fm_task_inbox_is_fire_and_forget "$f"; then
          continue
        fi
        if ! fm_task_inbox_body "$f" > "$have" 2>/dev/null; then
          case "$f" in
            "$dir"/*.msg)
              f="$dir/handled/${f##*/}"
              fm_task_inbox_body "$f" > "$have" 2>/dev/null || continue
              ;;
            *) continue ;;
          esac
        fi
        cmp -s "$want" "$have" || continue
        [ ! -e "$dir/handled/${f##*/}" ] || f="$dir/handled/${f##*/}"
        rec=$f
        break
      done
    else
      status=1
    fi
    rm -f "$want" "$have"
  else
    rm -f "${want:-}" 2>/dev/null || true
    status=1
  fi
  if [ "$status" -eq 0 ] && [ -z "$rec" ]; then
    rec=$(_fm_task_inbox_write_record_locked "$dir" "$text" "$delivery_mode") || status=1
  fi
  fm_lock_release "$lock"
  [ "$status" -eq 0 ] || return 1
  printf '%s' "$rec"
}

# The coalesce key a record carries, or fail when it carries none.
fm_task_inbox_coalesce_key() {  # <record-path>
  [ -f "$1" ] || return 1
  awk '
    $0 == "--" { exit }
    index($0, "coalesce=") == 1 { key = substr($0, 10) }
    END { if (key == "") exit 1; print key }
  ' "$1"
}

# Enqueue one coalescing record, then retire every other unhandled record it
# supersedes (see "Coalescing" above). Prints the new record path on stdout
# and, when it superseded any, one count line on stderr.
fm_task_inbox_write_coalesced() {  # <state-dir> <task-id> <text> <coalesce-key>
  local state=$1 task=$2 text=$3 key=$4 dir lock rec want have f status=0 removed=0
  local oldest='' ref='' heir ladder rec_base count last superseded_oldest=0
  case "$key" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
  dir=$(fm_task_inbox_dir "$state" "$task")
  mkdir -p "$dir/handled" || return 1
  lock="$dir/.seq.lock"
  fm_task_inbox_lock_acquire "$lock" || return 1
  rec=$(_fm_task_inbox_write_record_locked "$dir" "$text" "" "$key") || status=1
  if [ "$status" -eq 0 ] && want=$(mktemp "$dir/.dedup.XXXXXX") \
    && have=$(mktemp "$dir/.dedup.XXXXXX"); then
    printf '%s' "$text" > "$want"
    oldest=$(fm_task_inbox_oldest_unhandled "$state" "$task") || oldest=
    if [ -n "$oldest" ] && [ "$oldest" != "$rec" ] && ref=$(mktemp "$dir/.dedup.XXXXXX"); then
      touch -r "$oldest" "$ref" 2>/dev/null || { rm -f "$ref"; ref=; }
    fi
    for f in "$dir"/*.msg; do
      [ -f "$f" ] && [ "$f" != "$rec" ] || continue
      if [ "$(fm_task_inbox_coalesce_key "$f" 2>/dev/null)" != "$key" ]; then
        fm_task_inbox_is_fire_and_forget "$f" && continue
        fm_task_inbox_body "$f" > "$have" 2>/dev/null || continue
        cmp -s "$want" "$have" || continue
      fi
      if rm "$f" 2>/dev/null; then
        removed=$((removed + 1))
        [ "$f" != "$oldest" ] || superseded_oldest=1
      fi
    done
    if [ -n "$ref" ] && [ "$superseded_oldest" -eq 1 ] \
      && heir=$(fm_task_inbox_oldest_unhandled "$state" "$task"); then
      touch -c -r "$ref" "$heir" 2>/dev/null || true
      ladder=$(cat "$dir/.ring-state" 2>/dev/null || true)
      IFS=$'\t' read -r rec_base count last <<EOF
$ladder
EOF
      if [ "$rec_base" = "${oldest##*/}" ]; then
        printf '%s\t%s\t%s\n' "${heir##*/}" "$count" "$last" > "$dir/.ring-state" 2>/dev/null || true
      fi
      if [ "$(cat "$dir/.escalated" 2>/dev/null || true)" = "${oldest##*/}" ]; then
        printf '%s\n' "${heir##*/}" > "$dir/.escalated" 2>/dev/null || true
      fi
      if [ "$(cat "$dir/.overdue" 2>/dev/null || true)" = "${oldest##*/}" ]; then
        printf '%s\n' "${heir##*/}" > "$dir/.overdue" 2>/dev/null || true
      fi
    fi
    rm -f "$want" "$have" ${ref:+"$ref"}
  else
    rm -f "${want:-}" 2>/dev/null || true
  fi
  fm_lock_release "$lock"
  [ "$status" -eq 0 ] || return 1
  [ "$removed" -eq 0 ] \
    || echo "fm-task-inbox: coalesced $removed superseded unhandled record(s) into ${rec##*/}" >&2
  printf '%s' "$rec"
}

# The exact enqueued text back out of a record.
fm_task_inbox_body() {  # <record-path>
  local line
  [ -f "$1" ] || return 1
  while IFS= read -r line; do
    if [ "$line" = -- ]; then
      cat
      return 0
    fi
  done < "$1"
  return 1
}

# The constant self-describing doorbell line for the inbox containing a record.
# Self-describing on purpose: a worker whose brief predates the inbox contract
# still receives the complete instruction in the line itself.
fm_task_inbox_doorbell_line() {  # <record-path>
  local dir=${1%/*} abs
  abs=$(cd "$dir" 2>/dev/null && pwd) || abs=$dir
  printf 'Firstmate instruction waiting: list %s/*.msg and, in numeric order, read and act on each, then mv each handled file to %s/handled/.' \
    "$abs" "$abs"
}

# Ring the doorbell, best-effort: one advisory composer pre-check, then the
# backend's submit machinery with a minimal retry budget, verdict discarded.
# Returns 0 rang, 1 skipped because the composer PROVENLY holds pending text
# (the watcher re-rings later), 2 the backend send failed. No return value is
# delivery proof; the acknowledgement move is the only delivery signal.
# The skip is deliberately narrow: only an exact `pending` verdict defers,
# because there our Enter could submit someone's real half-typed content.
# `pending-unproven` and `unknown` still ring - the worst outcome is a garbled
# CONSTANT line the worker recovers semantically, while skipping on ambiguous
# verdicts would starve a harness whose idle screen the classifier cannot
# positively identify (that classifier is advisory here by design).
fm_task_inbox_ring() {  # <backend> <target> <record-path> [expected-label]
  local backend=$1 target=$2 rec=$3 label=${4:-} line cstate verdict
  line=$(fm_task_inbox_doorbell_line "$rec")
  cstate=$(fm_backend_composer_state "$backend" "$target" "$label" 2>/dev/null) || cstate=unknown
  case "$cstate" in
    pending) return 1 ;;
  esac
  if ! verdict=$(fm_backend_send_text_submit "$backend" "$target" "$line" 1 0.4 0.3 "$label" 2>/dev/null); then
    return 2
  fi
  # The verdict is read only to report a failed keystroke; every other value
  # (empty, pending, unknown, ...) is deliberately ignored, never proof.
  [ "$verdict" != send-failed ] || return 2
  return 0
}

fm_task_inbox_is_fire_and_forget() {  # <record-path>
  local rec=$1
  if [ ! -f "$rec" ]; then
    rec="${rec%/*}/handled/${rec##*/}"
    [ -f "$rec" ] || return 1
  fi
  awk '
    $0 == "--" { exit }
    $0 == "delivery=fire-and-forget" { found=1 }
    END { exit(found ? 0 : 1) }
  ' "$rec"
}

# Oldest escalation-tracked unhandled record, or fail when none is due.
fm_task_inbox_oldest_unhandled() {  # <state-dir> <task-id>
  local dir best='' best_n=0 f n
  dir=$(fm_task_inbox_dir "$1" "$2")
  for f in "$dir"/*.msg; do
    [ -e "$f" ] || continue
    fm_task_inbox_is_fire_and_forget "$f" && continue
    n=$(fm_task_inbox_seq_of "${f##*/}") || continue
    if [ -z "$best" ] || [ "$n" -lt "$best_n" ]; then
      best=$f
      best_n=$n
    fi
  done
  [ -n "$best" ] || return 1
  printf '%s' "$best"
}

# The re-ring ladder decision for one task. Prints exactly one of:
#   quiet                     nothing due (healthy, within grace or spacing,
#                             or already escalated for the current oldest)
#   ring <record-path>        one doorbell re-ring is due
#   escalate <record-path> <count>   attempt budget spent; surface as stale
# An empty inbox also resets the ladder bookkeeping so the next message starts
# a fresh ladder.
fm_task_inbox_due_action() {  # <state-dir> <task-id>
  local dir oldest base now grace max ladder rec_base count last
  dir=$(fm_task_inbox_dir "$1" "$2")
  if ! oldest=$(fm_task_inbox_oldest_unhandled "$1" "$2"); then
    rm -f "$dir/.ring-state" "$dir/.escalated" "$dir/.overdue" 2>/dev/null || true
    printf 'quiet'
    return 0
  fi
  base=${oldest##*/}
  grace=$(fm_task_inbox_grace_secs)
  if [ "$(fm_path_age "$oldest")" -lt "$grace" ]; then
    printf 'quiet'
    return 0
  fi
  count=0
  last=0
  ladder=$(cat "$dir/.ring-state" 2>/dev/null || true)
  IFS=$'\t' read -r rec_base count last <<EOF
$ladder
EOF
  if [ "$rec_base" != "$base" ]; then
    # A different (or first) oldest message: the previous ladder is stale.
    count=0
    last=0
    rm -f "$dir/.escalated" 2>/dev/null || true
  fi
  case "$count" in ''|*[!0-9]*) count=0 ;; esac
  case "$last" in ''|*[!0-9]*) last=0 ;; esac
  if [ "$(cat "$dir/.escalated" 2>/dev/null || true)" = "$base" ]; then
    printf 'quiet'
    return 0
  fi
  max=$(fm_task_inbox_ring_max)
  if [ "$count" -ge "$max" ]; then
    printf 'escalate %s %s' "$oldest" "$count"
    return 0
  fi
  now=$(date +%s)
  if [ "$((now - last))" -lt "$grace" ]; then
    printf 'quiet'
    return 0
  fi
  printf 'ring %s' "$oldest"
}

# Advance the ladder after a delivery attempt. A failed ring or a composer-
# protected skip still consumes budget so neither a dead pane nor permanently
# blocked composer can retry silently forever. A concurrently removed inbox is
# a successful no-op; otherwise failure means the caller must surface the
# unwritable ladder while the record remains unhandled.
fm_task_inbox_record_ring() {  # <state-dir> <task-id> <record-path>
  local dir base ladder rec_base count last
  dir=$(fm_task_inbox_dir "$1" "$2")
  base=${3##*/}
  count=0
  ladder=$(cat "$dir/.ring-state" 2>/dev/null || true)
  IFS=$'\t' read -r rec_base count last <<EOF
$ladder
EOF
  [ "$rec_base" = "$base" ] || count=0
  case "$count" in ''|*[!0-9]*) count=0 ;; esac
  [ -d "$dir" ] || return 0
  if ! { printf '%s\t%s\t%s\n' "$base" "$((count + 1))" "$(date +%s)" > "$dir/.ring-state"; } 2>/dev/null; then
    [ -d "$dir" ] || return 0
    return 1
  fi
}

# The overdue liveness decision for one task, independent of the ring ladder
# and of the pane. Prints `<record-path> <age-secs>` and returns 0 when the
# oldest escalation-tracked unhandled record has gone unacknowledged for
# longer than fm_task_inbox_overdue_secs and has not been surfaced as overdue
# yet; returns 1 otherwise (no record, not yet overdue, or already surfaced).
# A marker naming a different record is stale bookkeeping from an earlier
# message and does not suppress the current one.
fm_task_inbox_overdue() {  # <state-dir> <task-id>
  local dir oldest age
  dir=$(fm_task_inbox_dir "$1" "$2")
  oldest=$(fm_task_inbox_oldest_unhandled "$1" "$2") || return 1
  age=$(fm_path_age "$oldest")
  [ "$age" -ge "$(fm_task_inbox_overdue_secs)" ] || return 1
  [ "$(cat "$dir/.overdue" 2>/dev/null || true)" != "${oldest##*/}" ] || return 1
  printf '%s %s' "$oldest" "$age"
}

# Mark the current oldest as surfaced overdue after its stale wake is durably
# queued, with the same wake-before-marker ordering as escalation.
fm_task_inbox_record_overdue() {  # <state-dir> <task-id> <record-path>
  local dir
  dir=$(fm_task_inbox_dir "$1" "$2")
  [ -d "$dir" ] || return 0
  if ! { printf '%s\n' "${3##*/}" > "$dir/.overdue"; } 2>/dev/null; then
    [ -d "$dir" ] || return 0
    return 1
  fi
}

# Mark the current oldest as escalated after its stale wake is durably queued,
# suppressing another wake on later polls. Wake-before-marker ordering favors
# at-least-once recovery: a crash or marker failure can cause a rare duplicate;
# stuck-crewmate-recovery owns the message from here.
fm_task_inbox_record_escalated() {  # <state-dir> <task-id> <record-path>
  local dir
  dir=$(fm_task_inbox_dir "$1" "$2")
  [ -d "$dir" ] || return 0
  if ! { printf '%s\n' "${3##*/}" > "$dir/.escalated"; } 2>/dev/null; then
    [ -d "$dir" ] || return 0
    return 1
  fi
}
