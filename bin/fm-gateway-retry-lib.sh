#!/usr/bin/env bash
# fm-gateway-retry-lib.sh - the single owner of the transient inference-gateway
# stall contract: what counts as a retryable gateway failure, the durable stall
# record's format, the bounded retry ladder, and the continue instruction a
# stalled agent is re-rung with.
#
# WHY THIS EXISTS. Firstmate agents run against an inference gateway that pools
# accounts. When no pooled account is routable the gateway answers 503 and the
# harness ends the turn with an API error, leaving the agent idle at its prompt
# with its work unfinished. Nothing in the harness resumes it: the recovery is
# to send the agent a message telling it to continue, which is exactly what the
# steering inbox already does. This library holds the decision of WHEN that is
# the right thing to do, and the watcher (bin/fm-watch.sh) is the one actor
# that makes it, for every crewmate and scout.
#
# WHY NOT A BLOCKING HOOK. Claude Code ends an API-error turn through
# StopFailure, never Stop, and StopFailure is executed OUTSIDE the REPL loop
# (executeStopFailureHooks awaits the hook runner and discards its result), so a
# StopFailure hook cannot block the stop or force a continuation the way the
# turn-end guard does on Stop. Verified live on 2.1.266; see
# docs/verification/gateway-keepalive.md. Detection is therefore done from the
# RENDERED PANE by an actor outside the session, which is also the only signal
# that keeps saying "still stalled" for as long as the stall lasts.
#
# CLASSIFICATION reads the pane's tail. A turn-ending API error renders in the
# few lines immediately above the harness's prompt and footer, so the transient
# match is bounded to the last FM_GATEWAY_TAIL_LINES non-blank lines of whatever
# the caller captured - the same bounded footer window bin/fm-watch.sh's busy
# match uses, and for the same reason: an agent that recovered and went idle
# again with the old error still in its scrollback must not be re-rung, and an
# agent that merely printed this repository's own sources must not be either.
# Only the harness's rendered "API Error: <5xx>" shape matches, never a bare
# word such as "overloaded".
#
# A DENY list runs first, over the WHOLE supplied text, and wins outright. It
# exists because the non-retryable failures are the expensive mistakes:
# re-ringing an agent whose prompt is too long, whose credential expired, or
# which hit a usage limit burns the budget without any chance of progress, and
# one of those failures ("Prompt is too long - automatic compaction failed: API
# Error: 503 ...") literally contains a 503 in its text. The deny patterns and
# the transient patterns below were both taken from a census of the real
# transcripts this fleet produced, not from guesses.
#
# BUDGET. A stall record is bounded twice, because either bound alone is
# insufficient: an attempt count stops a fast loop, and a wall-clock horizon
# stops a slow one that would otherwise re-ring for hours across a genuine
# outage. Exhausting either bound is not an error - it is the point at which
# "the gateway is briefly out of accounts" becomes "the gateway is down", which
# is the one thing the captain wants surfaced.
#
# A RECORD MUST NOT OUTLIVE THE STALL IT RECORDS. The pane exit above only fires
# on a poll that finds the agent idle, and an agent that recovered and then ran a
# long turn is never observed idle while it does so - it would carry a half-spent
# ladder and a stale horizon anchor into the next, unrelated stall and have that
# one declared an outage on first sight. Busy alone cannot be the second exit
# either: the ladder's own continue makes the pane busy from the moment it is
# submitted until the turn ends, so a retry that dies on another 503 reads busy
# for its whole short duration, and clearing there would wipe the attempt count
# mid-ladder and no genuine outage could ever be declared. The part that cannot
# be the ladder's own retry is DURATION - a busy stretch longer than
# FM_GATEWAY_BUSY_CLEAR_POLLS of the caller's poll periods is a turn that
# actually ran, which is the recovery the pane exit would have seen.
#
# Tunables (env):
#   FM_GATEWAY_RETRY_MAX        default 8; re-ring attempts before the budget is spent
#   FM_GATEWAY_RETRY_HORIZON    default 2700; seconds from first stall before the budget is spent
#   FM_GATEWAY_RETRY_BACKOFF    default "30 60 120 300"; per-attempt wait, last value repeats
#   FM_GATEWAY_TAIL_LINES       default 10; non-blank pane lines above the footer the transient match reads
#   FM_GATEWAY_BUSY_CLEAR_POLLS default 2; consecutive busy polls a record survives before it is dropped
#
# No side effects on source. Dependency-light: pure shell plus date.

FM_GATEWAY_RETRY_MAX_DEFAULT=8
FM_GATEWAY_RETRY_HORIZON_DEFAULT=2700
FM_GATEWAY_RETRY_BACKOFF_DEFAULT='30 60 120 300'
FM_GATEWAY_TAIL_LINES_DEFAULT=10
FM_GATEWAY_BUSY_CLEAR_POLLS_DEFAULT=2

# The exact instruction a stalled agent is re-rung with. It deliberately names
# the cause and asks for continuation rather than restatement, so the agent picks
# up the step the gateway interrupted instead of re-planning the whole task.
# shellcheck disable=SC2034 # Read by fm-watch.sh, not this lib.
FM_GATEWAY_CONTINUE_TEXT='The inference gateway returned a temporary error and ended your last turn before it finished. This is firstmate keep-alive, not a new instruction: continue exactly where you left off, redo only the step the error interrupted, and do not restart the task or re-report work you already completed.'

fm_gateway_retry_max() {
  local m=${FM_GATEWAY_RETRY_MAX:-$FM_GATEWAY_RETRY_MAX_DEFAULT}
  case "$m" in ''|*[!0-9]*) m=$FM_GATEWAY_RETRY_MAX_DEFAULT ;; esac
  printf '%s' "$m"
}

fm_gateway_retry_horizon() {
  local h=${FM_GATEWAY_RETRY_HORIZON:-$FM_GATEWAY_RETRY_HORIZON_DEFAULT}
  case "$h" in ''|*[!0-9]*) h=$FM_GATEWAY_RETRY_HORIZON_DEFAULT ;; esac
  printf '%s' "$h"
}

# Consecutive busy polls a stall record survives. Longer than this is a turn
# that ran, not the ladder's own retry dying on the next error, so the record is
# dropped. Owned here with the other bounds; the watcher reads it rather than
# carrying a second copy of the number.
fm_gateway_busy_clear_polls() {
  local n=${FM_GATEWAY_BUSY_CLEAR_POLLS:-$FM_GATEWAY_BUSY_CLEAR_POLLS_DEFAULT}
  case "$n" in ''|*[!0-9]*|0) n=$FM_GATEWAY_BUSY_CLEAR_POLLS_DEFAULT ;; esac
  printf '%s' "$n"
}

fm_gateway_tail_lines() {
  local n=${FM_GATEWAY_TAIL_LINES:-$FM_GATEWAY_TAIL_LINES_DEFAULT}
  case "$n" in ''|*[!0-9]*|0) n=$FM_GATEWAY_TAIL_LINES_DEFAULT ;; esac
  printf '%s' "$n"
}

# Seconds to wait before delivery attempt <n> (1-based). The configured ladder's
# last value repeats for every attempt past its length, so a longer budget does
# not need a longer ladder.
fm_gateway_backoff_secs() {  # <attempt>
  local n=${1:-1} ladder i=0 v last=''
  case "$n" in ''|*[!0-9]*) n=1 ;; esac
  [ "$n" -ge 1 ] || n=1
  ladder=${FM_GATEWAY_RETRY_BACKOFF:-$FM_GATEWAY_RETRY_BACKOFF_DEFAULT}
  for v in $ladder; do
    case "$v" in ''|*[!0-9]*) continue ;; esac
    i=$(( i + 1 ))
    last=$v
    [ "$i" -eq "$n" ] || continue
    printf '%s' "$v"
    return 0
  done
  if [ -n "$last" ]; then
    printf '%s' "$last"
    return 0
  fi
  printf '30'
}

# --- classification ----------------------------------------------------------

# 0 when the text names a failure that must NEVER be retried. Checked before any
# transient match, over the whole supplied text, and beats it, because these
# strings can carry a transient code inside a non-transient failure.
fm_gateway_text_is_permanent() {  # <text>
  local t
  t=$(printf '%s' "${1-}" | tr '[:upper:]' '[:lower:]')
  case "$t" in
    *'prompt is too long'*) return 0 ;;
    *'autocompact is thrashing'*) return 0 ;;
    *'hit your limit'*) return 0 ;;
    *'usage limit'*) return 0 ;;
    *'login expired'*) return 0 ;;
    *'please run /login'*) return 0 ;;
    *'safeguards flagged'*) return 0 ;;
    *'may not exist or you may not have access'*) return 0 ;;
    *'rate limited'*) return 0 ;;
    *'rate_limit'*) return 0 ;;
    *'invalid_request'*) return 0 ;;
    *'api error: 4'*) return 0 ;;
  esac
  return 1
}

# 0 when the rendered pane tail shows a transient gateway failure worth
# re-ringing for. The deny list is consulted over the whole text; the transient
# match reads only the last FM_GATEWAY_TAIL_LINES non-blank lines, which is where
# a turn-ending API error renders, immediately above the prompt and footer.
fm_gateway_text_is_transient() {  # <pane-text>
  local text=${1-} t
  [ -n "$text" ] || return 1
  fm_gateway_text_is_permanent "$text" && return 1
  t=$(printf '%s\n' "$text" | grep -v '^[[:space:]]*$' | tail -n "$(fm_gateway_tail_lines)" \
    | tr '[:upper:]' '[:lower:]')
  case "$t" in
    *'api error: 500'*|*'api error: 502'*|*'api error: 503'*|*'api error: 504'*|*'api error: 529'*) return 0 ;;
  esac
  return 1
}

# --- durable stall record ----------------------------------------------------
#
# One record per stalled agent, at <state>/<scope>.gateway-stall:
#   v1 first=<epoch> attempts=<n> last=<epoch> notified=<0|1>
# <scope> is the task id for a crewmate or scout, and the reserved id below for
# the primary session, which has no task record of its own. Removing the file is
# always safe: it only costs the current stall its accumulated budget.
#
# `first` anchors the wall-clock horizon and never moves while the stall is
# open. `last` anchors the BACKOFF and moves only when an attempt is charged, so
# re-noting the same stall on every poll cannot keep pushing the next attempt
# out of reach - the bug that would turn this ladder into a permanent silent
# absorb. Opening the record seeds `last` from `first`, so the first attempt
# still waits out its own backoff instead of firing the instant a stall is seen.

fm_gateway_record_path() {  # <state-dir> <scope>
  printf '%s/%s.gateway-stall' "$1" "$2"
}

_fm_gateway_field() {  # <record-path> <field> <default>
  local rec=$1 field=$2 def=$3 line v
  line=$(cat "$rec" 2>/dev/null) || { printf '%s' "$def"; return 0; }
  case "$line" in v1\ *) : ;; *) printf '%s' "$def"; return 0 ;; esac
  for v in $line; do
    case "$v" in
      "$field"=*)
        v=${v#*=}
        [ -n "$v" ] || v=$def
        printf '%s' "$v"
        return 0
        ;;
    esac
  done
  printf '%s' "$def"
}

fm_gateway_attempts() {  # <state-dir> <scope>
  local n
  n=$(_fm_gateway_field "$(fm_gateway_record_path "$1" "$2")" attempts 0)
  case "$n" in ''|*[!0-9]*) n=0 ;; esac
  printf '%s' "$n"
}

fm_gateway_first_seen() {  # <state-dir> <scope>; empty when there is no record
  local v
  v=$(_fm_gateway_field "$(fm_gateway_record_path "$1" "$2")" first '')
  case "$v" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s' "$v"
}

fm_gateway_last_seen() {  # <state-dir> <scope>; empty when there is no record
  local v
  v=$(_fm_gateway_field "$(fm_gateway_record_path "$1" "$2")" last '')
  case "$v" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s' "$v"
}

fm_gateway_notified() {  # <state-dir> <scope>; 0 when the spent budget was already reported
  [ "$(_fm_gateway_field "$(fm_gateway_record_path "$1" "$2")" notified 0)" = 1 ]
}

_fm_gateway_write() {  # <state-dir> <scope> <first> <attempts> <last> <notified>
  local state=$1 scope=$2 rec tmp
  rec=$(fm_gateway_record_path "$state" "$scope")
  [ -d "$state" ] || mkdir -p "$state" 2>/dev/null || return 1
  tmp="$rec.tmp.$$"
  printf 'v1 first=%s attempts=%s last=%s notified=%s\n' \
    "$3" "$4" "$5" "$6" > "$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$rec" 2>/dev/null || { rm -f "$tmp"; return 1; }
  return 0
}

# Open a stall record for a scope that has none. Deliberately a NO-OP for a
# record that is already open: every detector calls this on every sighting, and
# advancing the ladder's anchors here would restart the backoff on each poll and
# the horizon would never be reached.
fm_gateway_note_stall() {  # <state-dir> <scope>
  local state=$1 scope=$2 now
  fm_gateway_stall_open "$state" "$scope" && return 0
  now=$(date +%s)
  _fm_gateway_write "$state" "$scope" "$now" 0 "$now" 0
}

# Charge one re-ring attempt against the budget. Fails when the record cannot be
# updated, so a caller that cannot persist the charge does not deliver an
# uncounted re-ring.
fm_gateway_record_attempt() {  # <state-dir> <scope>
  local state=$1 scope=$2 first attempts notified
  first=$(fm_gateway_first_seen "$state" "$scope") || first=$(date +%s)
  attempts=$(( $(fm_gateway_attempts "$state" "$scope") + 1 ))
  notified=0
  fm_gateway_notified "$state" "$scope" && notified=1
  _fm_gateway_write "$state" "$scope" "$first" "$attempts" "$(date +%s)" "$notified"
}

# Mark the spent budget as reported, so the declared wait is announced once
# rather than on every later poll of the same stall.
fm_gateway_mark_notified() {  # <state-dir> <scope>
  local state=$1 scope=$2 first attempts
  first=$(fm_gateway_first_seen "$state" "$scope") || first=$(date +%s)
  attempts=$(fm_gateway_attempts "$state" "$scope")
  _fm_gateway_write "$state" "$scope" "$first" "$attempts" "$(date +%s)" 1
}

fm_gateway_clear() {  # <state-dir> <scope>
  rm -f "$(fm_gateway_record_path "$1" "$2")" 2>/dev/null || true
}

# THE exit from the ladder: an agent that has demonstrably resumed drops its
# record, closing any declared wait that record opened. Both exits go through
# here so a record can never be dropped while the wait it declared is left
# standing on the agent's status log. 1 when there was no record to drop, so a
# caller can report only a real transition.
fm_gateway_clear_recovered() {  # <state-dir> <scope>
  fm_gateway_stall_open "$1" "$2" || return 1
  _fm_gateway_close_declared_wait "$1" "$2"
  fm_gateway_clear "$1" "$2"
  return 0
}

fm_gateway_stall_open() {  # <state-dir> <scope>
  fm_gateway_first_seen "$1" "$2" >/dev/null 2>&1
}

# Seconds since this stall was first recorded, or 0 when there is no record.
fm_gateway_stall_age() {  # <state-dir> <scope>
  local first
  if first=$(fm_gateway_first_seen "$1" "$2"); then
    printf '%s' "$(( $(date +%s) - first ))"
    return 0
  fi
  printf '0'
}

# THE entry and exit decision for the re-ring ladder, shared by the watcher and
# the primary keep-alive agent so an agent cannot be in the ladder for one and
# out of it for the other. <pane-text> is the rendered tail the caller already
# read. The pane is the only detector: a tail showing the transient error opens
# or keeps the record, and a tail that no longer shows it is a recovered agent,
# whose record is dropped rather than re-ringing an agent that is already
# working again.
fm_gateway_stalled_now() {  # <state-dir> <scope> <pane-text>
  local state=$1 scope=$2 pane=${3-}
  if fm_gateway_text_is_transient "$pane"; then
    fm_gateway_note_stall "$state" "$scope" || return 1
    return 0
  fi
  fm_gateway_clear_recovered "$state" "$scope" || true
  return 1
}

# 0 when this stall has used up either bound and must stop being re-rung.
fm_gateway_budget_spent() {  # <state-dir> <scope>
  local state=$1 scope=$2 attempts age
  attempts=$(fm_gateway_attempts "$state" "$scope")
  [ "$attempts" -lt "$(fm_gateway_retry_max)" ] || return 0
  age=$(fm_gateway_stall_age "$state" "$scope")
  [ "$age" -lt "$(fm_gateway_retry_horizon)" ] || return 0
  return 1
}

# 0 when the next re-ring attempt's backoff has elapsed since the last one.
# The first attempt still waits out its backoff measured from the first
# sighting, so a stall is never re-rung the instant it is seen.
fm_gateway_attempt_due() {  # <state-dir> <scope>
  local state=$1 scope=$2 attempts wait_secs anchor
  attempts=$(fm_gateway_attempts "$state" "$scope")
  wait_secs=$(fm_gateway_backoff_secs "$(( attempts + 1 ))")
  anchor=$(fm_gateway_last_seen "$state" "$scope") || return 1
  [ "$(( $(date +%s) - anchor ))" -ge "$wait_secs" ]
}

# The status line a spent budget declares: an external wait firstmate should
# leave alone on its long cadence, not a wedge to escalate. The key makes the
# declaration closeable by the same recorded-answer path every other declared
# wait uses.
fm_gateway_paused_status_line() {  # <state-dir> <scope>
  printf 'paused [key=gateway-503]: inference gateway still returning transient errors after %s continue attempts over %ss; waiting for account pool capacity' \
    "$(fm_gateway_attempts "$1" "$2")" "$(fm_gateway_stall_age "$1" "$2")"
}

# The close for the line above, so a declared wait ends the way every other
# keyed phase ends rather than outliving the condition it declared.
fm_gateway_resolved_status_line() {  # <state-dir> <scope>
  printf 'resolved [key=gateway-503]: the pane stopped showing the transient gateway error after %ss; the agent is working again' \
    "$(fm_gateway_stall_age "$1" "$2")"
}

# Close the declared wait at the one transition that proves it is over: a
# record that declared it being dropped because its pane recovered. Only a
# record marked notified ever opened a phase, and only a scope with a status
# log has one to close, so a scope without one is left alone.
_fm_gateway_close_declared_wait() {  # <state-dir> <scope>
  local state=$1 scope=$2 status
  status="$state/$scope.status"
  [ -f "$status" ] || return 0
  fm_gateway_notified "$state" "$scope" || return 0
  printf '%s\n' "$(fm_gateway_resolved_status_line "$state" "$scope")" >> "$status" 2>/dev/null || true
}
