#!/usr/bin/env bash
# fm-pause-lib.sh - the single owner of the machine-checkable pause declaration.
#
# Sourced, never executed.
#
# WHY. A `paused:` status line declares a deliberate external wait: the lane is
# idle on purpose, so a supervisor must not nag it. That is a claim, and a bare
# pause carries no evidence for it. A pause whose reason resolved two days ago
# reads exactly like a pause that will clear in a minute, and nothing in the log
# ever contradicts the claim, so the lane sleeps until a person notices. This
# library adds the durable shape that makes the claim checkable, and the readers
# that decide whether it still holds.
#
# THE DECLARED SHAPE. A pause carries its own evidence on the same status line:
#
#   paused [key=<decision-key>]: <why> predicate=<shell command> expires=<ISO8601 UTC>
#
# Field rules:
#   predicate=  A shell command, run by fm_pause_check under a hard bound. Exit 0
#               means the pause's reason still holds, 1 means it resolved, and
#               anything else - a nonzero other than 1, a missing command, the
#               bound being hit - means the predicate could not be read.
#               It is the last field before expires=, so it may contain spaces,
#               quoting, pipes, and any other text except `expires=`.
#   expires=    One whitespace-delimited ISO8601 UTC timestamp, the wall clock
#               after which the pause is over whatever the predicate says. A
#               predicate that starts answering 0 forever therefore still cannot
#               park a lane silently.
#   key=        The same decision key the status fold already reads off the same
#               line (bin/fm-classify-lib.sh owns that shape), so a predicate
#               pause opens and closes like every other keyed line.
#
# TWO EXISTING ADMISSIONS KEEP THEIR SHAPE and need no field of their own: a
# pause naming a UTC wake time (`until HH:MMZ`) and firstmate's own gateway
# keep-alive (`[key=gateway-503]`, docs/gateway-keepalive.md). Every other pause
# must carry predicate= AND expires= to be a declared wait at all.
#
# WHO DOES WHAT. bin/fm-classify-lib.sh owns the composed declared-wait rule - it
# already owns the pause verb, the wake-time shape, and the gateway exception -
# and calls fm_pause_has_predicate_and_expires here for this third admission, so
# the field shape is defined in exactly one place. This library owns the fields,
# the writer (fm_pause_record), the three readers (fm_pause_parse,
# fm_pause_check, fm_pause_expired), and the expiry clock. bin/fm-pause-sweep.sh
# reports the pauses whose reason resolved or whose expiry passed; nothing here
# writes a status log except the caller's own fm_pause_record call, and nothing
# here stops a lane.

# The predicate must be the last field before expires=; these are the two markers
# every reader looks for. Builtins-only, because the per-line fold calls the
# admission test below on a status log of ordinary width.
FM_PAUSE_PREDICATE_RE='predicate=[^[:space:]]'
FM_PAUSE_EXPIRES_RE='expires=[0-9][0-9][0-9][0-9]-'

# The hard bound on one predicate run. A predicate is a shell command a crew
# wrote by hand, so it can block on anything; a tick that waits on it would wedge
# supervision itself. Long enough for a genuine probe, short enough that a hung
# one costs one poll and not the turn.
FM_PAUSE_CHECK_TIMEOUT_SECS_DEFAULT=60

# fm_run_timed, the shared hard bound. bin/fm-timeout-lib.sh owns bounded
# execution for this repo, so nothing here re-derives the mechanism selection.
# Sourced lazily (a caller that already loaded it pays nothing) and with the same
# nounset restore fm-classify-lib.sh uses, because that library declares `set -u`
# for its own hygiene and a sourced sibling must not impose it on THIS library's
# consumers.
if ! declare -F fm_run_timed >/dev/null 2>&1; then
  _FM_PAUSE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd 2>/dev/null)" || _FM_PAUSE_LIB_DIR=.
  case $- in *u*) _fm_pause_nounset=on ;; *) _fm_pause_nounset=off ;; esac
  # shellcheck source=bin/fm-timeout-lib.sh
  # shellcheck disable=SC1091
  . "$_FM_PAUSE_LIB_DIR/fm-timeout-lib.sh"
  [ "$_fm_pause_nounset" = on ] || set +u
  unset _fm_pause_nounset
fi

# Builtins-only trim: _FM_PAUSE_TRIM carries the text without leading or
# trailing spaces.
_fm_pause_trim() {  # <text>
  local s=$1
  s=${s#"${s%%[![:space:]]*}"}
  s=${s%"${s##*[![:space:]]}"}
  _FM_PAUSE_TRIM=$s
}

# 0 when the line (or note) carries both fields of the predicate admission.
# Builtins only, so the status fold stays fork-free.
fm_pause_has_predicate_and_expires() {  # <status-line-or-note>
  [[ "$1" =~ $FM_PAUSE_PREDICATE_RE ]] && [[ "$1" =~ $FM_PAUSE_EXPIRES_RE ]]
}

# 0 when the line's leading verb is the pause verb. Classifier owns the verb, so
# this defers to status_is_paused (bin/fm-classify-lib.sh) whenever that library
# is loaded, which is every real reader; the literal fallback below is the same
# default FM_CLASSIFY_PAUSED_VERB_DEFAULT declares, for a standalone caller.
fm_pause_line_is_pause() {  # <status-line>
  local line=$1 verb
  if declare -F status_is_paused >/dev/null 2>&1; then
    status_is_paused "$line"
    return
  fi
  verb=${line%%:*}
  # The bracketed decision key sits between the verb and the colon; the fallback
  # strips it so `paused [key=x]: ...` reads as the pause verb, matching what the
  # classifier's own verb read answers.
  case "$verb" in
    *"[key="*"]") verb=${verb%%"[key="*} ;;
  esac
  _fm_pause_trim "$verb"
  verb=$_FM_PAUSE_TRIM
  [ -n "$verb" ] && [ "$verb" = "${FM_CLASSIFY_PAUSED_VERB:-paused}" ]
}

# Read the three fields off a pause status line. Sets FM_PAUSE_KEY, FM_PAUSE_WHY,
# FM_PAUSE_PREDICATE, and FM_PAUSE_EXPIRES; returns 1 (leaving them empty) when
# the line is not a pause line. This is a read: a field the line does not carry
# comes back empty, and it never validates a predicate it has not been asked to
# run.
fm_pause_parse() {  # <status-line>
  local line=$1 head note rest
  FM_PAUSE_KEY=
  FM_PAUSE_WHY=
  FM_PAUSE_PREDICATE=
  FM_PAUSE_EXPIRES=
  fm_pause_line_is_pause "$line" || return 1
  # key= is the bracketed token before the first colon, the same position the
  # fold reads; prose after the colon cannot smuggle one in.
  head=${line%%:*}
  case "$head" in
    *"[key="*"]"*)
      rest=${head##*"[key="}
      FM_PAUSE_KEY=${rest%%"]"*}
      ;;
  esac
  note=${line#*:}
  case "$note" in
    *"predicate="*)
      # The predicate is everything after the LAST predicate= marker, held to the
      # last expires= inside it, so a command containing spaces survives intact.
      rest=${note##*predicate=}
      case "$rest" in
        *"expires="*)
          FM_PAUSE_PREDICATE=${rest%expires=*}
          FM_PAUSE_EXPIRES=${rest##*expires=}
          FM_PAUSE_EXPIRES=${FM_PAUSE_EXPIRES%%[[:space:]]*}
          ;;
        *)
          FM_PAUSE_PREDICATE=$rest
          ;;
      esac
      _fm_pause_trim "$FM_PAUSE_PREDICATE"
      FM_PAUSE_PREDICATE=$_FM_PAUSE_TRIM
      ;;
  esac
  # The human-readable reason is the note text before the predicate field.
  case "$note" in
    *"predicate="*) FM_PAUSE_WHY=${note%%predicate=*} ;;
    *) FM_PAUSE_WHY=$note ;;
  esac
  _fm_pause_trim "$FM_PAUSE_WHY"
  FM_PAUSE_WHY=$_FM_PAUSE_TRIM
  return 0
}

# Epoch seconds for one ISO8601 UTC timestamp. Same two-step parse for both
# date(1) dialects that bin/fm-change-watch.sh cw_iso_to_epoch uses: BSD answers
# -j -f, GNU answers -d, and either failure falls through. Returns 1 when neither
# reads it.
fm_pause_expires_epoch() {  # <iso8601>
  local iso=$1 out
  [ -n "$iso" ] || return 1
  iso=${iso% UTC}
  iso=${iso% utc}
  if out=$(date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$iso" +%s 2>/dev/null); then
    printf '%s\n' "$out"
    return 0
  fi
  if out=$(date -u -d "$iso" +%s 2>/dev/null); then
    printf '%s\n' "$out"
    return 0
  fi
  return 1
}

# 0 when the expiry is behind us, 1 when it is still ahead, 2 when it cannot be
# read (an unreadable expiry is reported by the schema, not silently forgiven).
fm_pause_expired() {  # <iso8601> [<now-epoch>]
  local iso=$1 now=${2:-} epoch
  case "$now" in
    '') now=$(date -u +%s) ;;
    *[!0-9]*) return 2 ;;
  esac
  epoch=$(fm_pause_expires_epoch "$iso") || return 2
  [ "$now" -ge "$epoch" ]
}

# Evaluate one predicate under the hard bound.
#   0  the reason still holds - the lane may keep sleeping
#   1  the reason resolved - the pause is over
#   2  the predicate could not be read - treated as resolved, and reported
# An unreadable predicate is deliberately NOT a keep-sleeping answer: a pause
# whose evidence cannot be evaluated is the failure this contract exists to end.
fm_pause_check() {  # <predicate> [<timeout-seconds>]
  local predicate=$1 secs=${2:-${FM_PAUSE_CHECK_TIMEOUT_SECS:-$FM_PAUSE_CHECK_TIMEOUT_SECS_DEFAULT}}
  case "$predicate" in
    *[![:space:]]*) ;;
    *) return 2 ;;
  esac
  case "$secs" in
    ''|*[!0-9]*) secs=$FM_PAUSE_CHECK_TIMEOUT_SECS_DEFAULT ;;
  esac
  # bin/fm-timeout-lib.sh documents that a non-positive bound is not a bound, so
  # the caller rejects it rather than disabling the deadline.
  [ "$secs" -gt 0 ] 2>/dev/null || secs=$FM_PAUSE_CHECK_TIMEOUT_SECS_DEFAULT
  fm_run_timed "$secs" bash -c "$predicate"
  case "$?" in
    0) return 0 ;;
    1) return 1 ;;
    *) return 2 ;;
  esac
}

# Append the declared pause to a status log, refusing a record that would not
# read back as the same three fields. The log is append-only and this library
# never rewrites one; the read-back check is what keeps a predicate containing
# `expires=` from silently declaring a different expiry.
#   0  the line was appended
#   2  the record was refused (nothing written)
fm_pause_record() {  # <status-file> <key> <why> <predicate> <expires>
  local statusf=$1 key=$2 why=$3 predicate=$4 expires=$5 line
  [ -n "$statusf" ] || return 2
  case "$key" in
    ''|*[!A-Za-z0-9._-]*) return 2 ;;
  esac
  case "$why" in
    *[![:space:]]*) ;;
    *) return 2 ;;
  esac
  case "$predicate" in
    *[![:space:]]*) ;;
    *) return 2 ;;
  esac
  case "$expires" in
    *[[:space:]]*) return 2 ;;
  esac
  fm_pause_expires_epoch "$expires" >/dev/null || return 2
  line="paused [key=${key}]: ${why} predicate=${predicate} expires=${expires}"
  fm_pause_parse "$line" || return 2
  [ "$FM_PAUSE_KEY" = "$key" ] || return 2
  [ "$FM_PAUSE_PREDICATE" = "$predicate" ] || return 2
  [ "$FM_PAUSE_EXPIRES" = "$expires" ] || return 2
  case "$statusf" in
    */*) [ -d "${statusf%/*}" ] || return 2 ;;
    *) [ -d . ] || return 2 ;;
  esac
  printf '%s\n' "$line" >> "$statusf"
}
