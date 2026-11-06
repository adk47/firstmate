#!/usr/bin/env bash
# fm-decider-route.sh - route a worker's open needs-decision keys by
# standing-order class to the persistent Decider seat, and keep the captain's own
# class (a) decisions out of the seat's hands.
#
# Usage:
#   fm-decider-route.sh sweep      route new standing-order keys (the check's entry point)
#   fm-decider-route.sh status     print every open decision with its class and route
#   fm-decider-route.sh answer <task> <key> <ruling...>
#                                  record a seat ruling and close the key (wraps
#                                  bin/fm-send.sh <task> --resolve-key <key>)
#   fm-decider-route.sh arm        write state/decider-route.check.sh and bind it
#   fm-decider-route.sh disarm     remove the shim, its trust binding, and stop routing
#   fm-decider-route.sh --help
#
# What this owns. bob-architecture.md section 2 item 6 / section 8 row 5: a
# worker's `needs-decision [key=<key>]: <summary>` line is a decision. If the key
# matches a standing-order class (bin/fm-decider-lib.sh owns the vocabulary and
# the classifier), the decision is delivered to the Decider seat's steering inbox
# instead of waiting for the supervisor's own turn; the seat answers with
# bin/fm-send.sh <task> --resolve-key <key> '<ruling>' so the answer closes the
# captain-facing ledger at answer time. Only class (a) - money, a legal
# signature, the captain's own logins or clicks, anything irreversible - stays
# with the supervisor and the captain. An unclassified key also stays with the
# supervisor: an unmatched key is never handed to a worker.
#
# SAFETY. This script never decides anything, never writes a status log, and
# never touches a project. It appends to the fleet's own routing ledger and sends
# an inbox record; the seat's answer goes through fm-send's normal guarded
# --resolve-key path. A class (a) key is never routed, and bin/fm-decider-route.sh
# answer refuses to record a seat ruling for one.
#
# Cost. A sweep does not re-fold the fleet: it reads the cursor-backed
# open-decision fold bin/fm-classify-lib.sh already maintains for the wake drain
# (scan_open_decisions_incremental), which returns the COMPLETE open set on every
# call and folds only bytes appended since its own last call. Sharing that cursor
# is safe and cheap: the persisted open set is carried forward by design, so a
# second consumer only advances the same cursor and can never lose a decision.
# A fresh home (no cursors yet) pays one full fold, which is why `arm` primes it
# in the operator's own turn instead of inside a bounded watcher check.
#
# Exit status: 0 for every completed action, including "nothing to route" and a
# clean refusal-by-configuration (no seat configured). Nonzero is reserved for a
# broken invocation, an unreadable home, or a failed --resolve-key close, which
# fm-send itself reports.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME=${FM_HOME:-}
STATE=${FM_STATE_OVERRIDE:-${FM_HOME:+$FM_HOME/state}}

# shellcheck source=bin/fm-decider-lib.sh
. "$SCRIPT_DIR/fm-decider-lib.sh"
# fm-check-lib.sh's shim guard uses fm-pr-lib.sh's private-file helpers, and the
# register step it drives is bin/fm-check-register.sh's own entry point.
# shellcheck source=bin/fm-pr-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-check-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-check-lib.sh"
# shellcheck source=bin/fm-line-cap-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-line-cap-lib.sh"

CHECK_ID='decider-route'
SHIM_PREFIX='.fm-decider-route'
# How long a sweep may spend reading the fleet's open set before it gives up and
# prints one diagnostic instead of running past the watcher's own check bound.
SCAN_TIMEOUT=${FM_DECIDER_SCAN_TIMEOUT:-20}
case "$SCAN_TIMEOUT" in ''|*[!0-9]*|0) SCAN_TIMEOUT=20 ;; esac
# A sweep holds this lock so two concurrent drains cannot ask the seat twice for
# the same key. A lock older than this is treated as abandoned (a killed sweep
# would otherwise stop routing until someone noticed).
LOCK_STALE_SECS=600
LOCK_HELD=0
# A ruling request is a steer, not a log dump: cap the quoted question.
NOTE_CAP=700

usage() {
  cat <<'USAGE'
Usage:
  fm-decider-route.sh sweep      route standing-order decisions to the Decider seat
  fm-decider-route.sh status     list open decisions, their class, and their route
  fm-decider-route.sh answer <task> <key> <ruling...>
                                 record a seat ruling and close the key
  fm-decider-route.sh arm        install and bind the sweep check
  fm-decider-route.sh disarm     remove the sweep check and stop routing
  fm-decider-route.sh --help

The seat is configured by the first non-empty, non-comment line of
config/decider-task (or FM_DECIDER_TASK). With no seat configured nothing is
routed and every decision stays with the supervisor.
docs/decider-worker.md owns the seat's charter, its standing orders, and how to
seat it.
USAGE
}

die() {
  printf 'fm-decider-route: %s\n' "$*" >&2
  exit 2
}

require_home() {
  [ -n "${FM_HOME:-}" ] || die 'FM_HOME is not set; this script needs an explicit firstmate home'
  [ -d "$FM_HOME" ] || die "FM_HOME '$FM_HOME' is not a directory"
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || die "state dir '$STATE' is missing"
}

# --- sweeps ----------------------------------------------------------------

# The fleet's complete open-decision set, one "<task>\t<key>\t<verb>\t<note>"
# line per still-open decision. Bounded: a fold that cannot finish inside
# SCAN_TIMEOUT leaves the routing for the next sweep and reports once, rather
# than being killed mid-write by the watcher's own check bound.
scan_open_set() {
  # The child script is single-quoted on purpose: it runs in the bounded child.
  # shellcheck disable=SC2016
  fm_run_timed "$SCAN_TIMEOUT" bash -c '
    set -u
    . "$1" || exit 1
    scan_open_decisions_incremental "$2"
  ' _ "$SCRIPT_DIR/fm-classify-lib.sh" "$STATE"
}

# Run the scan and stash its output in OPEN_SET, returning 1 when it could not
# finish within its bound.
OPEN_SET=
scan_or_report() {
  local rc
  OPEN_SET=$(scan_open_set)
  rc=$?
  [ "$rc" -eq 0 ] || return 1
  return 0
}

# Classify every open needs-decision row and emit the ledger router's input:
# "<task>\t<key>\t<class>\t<note>". Blocked keys are not decisions the seat
# rules on (a blocked worker needs its owner, not a ruling), and the seat's own
# decisions are its own business, so both are skipped here.
classify_open_rows() {  # <seat>
  local seat=$1 task key verb note
  [ -n "$OPEN_SET" ] || return 0
  while IFS=$'\t' read -r task key verb note; do
    [ -n "$task" ] || continue
    [ "$verb" = needs-decision ] || continue
    [ "$task" != "$seat" ] || continue
    note=$(printf '%s' "$note" | tr '\t\n' '  ')
    fm_decider_classify_core "$key" "$note"
    printf '%s\t%s\t%s\t%s\n' "$task" "$key" "$_FM_DECIDER_CLASS" "$note"
  done <<EOF
$OPEN_SET
EOF
}

# Fold the ledger against this sweep's classified rows and emit the actions the
# caller must take, one tab-separated line each:
#   O <first_seen> <task> <key> <class> <epoch>   record a new episode
#   A <first_seen> <task> <key> <class> <epoch> <note>   ask the seat
#   C <first_seen> <task> <key> <class> <epoch>   record a close
#   E <first_seen> <task> <key> <class> <epoch>   the ruling window expired
# <first_seen> is the episode identity, so a key that closes and reopens gets a
# fresh ruling clock. Pure read of the ledger; the caller does the writing.
plan_actions() {  # <ledger> <classified-rows-file> <now>
  local ledger=$1 rows=$2 now=$3
  # Dispatch on FILENAME, never on FNR==NR: an empty ledger (a home that has not
  # routed anything yet) would otherwise make the FIRST data row look like a
  # ledger row and hide every decision in a brand-new home.
  awk -F'\t' -v OFS='\t' -v now="$now" -v led="$ledger" \
    -v stand="$FM_DECIDER_STANDING_ORDERS" \
    -v window="$(fm_decider_ruling_window)" '
    function want_ask(cls,   i, n, parts) {
      n = split(stand, parts, " ")
      for (i = 1; i <= n; i++) if (parts[i] == cls) return 1
      return 0
    }
    FILENAME == led {
      kind = $1
      if (kind == "O") {
        id = $3 SUBSEP $4
        if (open[id] != 1) {
          open[id] = 1
          first[id] = $2
          klass[id] = $5
          asked[id] = 0
          ruled[id] = 0
          escalated[id] = 0
        }
      } else if (kind == "C") {
        open[$3 SUBSEP $4] = 0
      } else if (kind == "A") {
        asked[$3 SUBSEP $4] = $6
      } else if (kind == "R") {
        ruled[$3 SUBSEP $4] = $6
      } else if (kind == "E") {
        escalated[$3 SUBSEP $4] = $6
      }
      next
    }
    {
      task = $1
      key = $2
      cls = $3
      note = $4
      id = task SUBSEP key
      seen[id] = 1
      if (open[id] != 1) {
        printf "O\t%s\t%s\t%s\t%s\t%s\n", now, task, key, cls, now
        open[id] = 1
        first[id] = now
        klass[id] = cls
        asked[id] = 0
        ruled[id] = 0
        escalated[id] = 0
      }
      if (want_ask(cls) && !asked[id] && !ruled[id]) {
        printf "A\t%s\t%s\t%s\t%s\t%s\t%s\n", first[id], task, key, cls, now, note
      }
    }
    END {
      for (id in open) {
        if (open[id] != 1 || (id in seen)) continue
        split(id, parts, SUBSEP)
        printf "C\t%s\t%s\t%s\t%s\t%s\n", first[id], parts[1], parts[2], klass[id], now
      }
      for (id in open) {
        if (open[id] != 1) continue
        if (asked[id] <= 0 || ruled[id] > 0 || escalated[id] > 0) continue
        if (now - asked[id] < window) continue
        split(id, parts, SUBSEP)
        printf "E\t%s\t%s\t%s\t%s\t%s\n", first[id], parts[1], parts[2], klass[id], now
      }
    }
  ' "$ledger" "$rows"
}

# The inbox record the seat reads. It states the one answer contract the seat
# must use, because a ruling that does not go through --resolve-key leaves the
# captain-facing ledger open and defeats the whole point of the seat.
ruling_request_text() {  # <task> <key> <class> <note>
  local task=$1 key=$2 class=$3 note=$4
  fm_cap_line_var "$note" "$NOTE_CAP"
  printf 'decider ruling requested\n'
  printf 'task: %s\n' "$task"
  printf 'key: %s\n' "$key"
  printf 'class: %s (standing order - yours to rule on)\n' "$class"
  printf 'question: %s\n' "$FM_LINE_CAP_LINE"
  printf '\n'
  printf 'Answer it with the decision, and close the ledger in the same send:\n'
  printf "  bin/fm-decider-route.sh answer %s %s '<your ruling>'\n" "$task" "$key"
  printf '(that wraps: bin/fm-send.sh %s --resolve-key %s '"'"'<your ruling>'"'"')\n' "$task" "$key"
  printf '\n'
  printf 'Never rule on money, a legal signature, the captain'"'"'s own logins or clicks, or anything irreversible.\n'
  printf 'If this question is really one of those, do not answer it: append\n'
  printf '  note: %s [key=%s] needs the captain - <one line why>\n' "$task" "$key"
  printf 'to your own status file and leave the key open.\n'
}

# Ask the seat for one ruling. Delivery is the durable inbox record; a failed
# send leaves the episode unasked so the next sweep retries instead of the
# decision silently losing its owner.
ask_seat() {  # <seat> <task> <key> <class> <note>
  local seat=$1 task=$2 key=$3 class=$4 note=$5 text
  text=$(ruling_request_text "$task" "$key" "$class" "$note")
  if ! FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-send.sh" "$seat" "$text" >/dev/null 2>&1; then
    return 1
  fi
  return 0
}

acquire_lock() {
  local lock="$STATE/.$CHECK_ID.lock"
  mkdir "$lock" 2>/dev/null && { LOCK_HELD=1; return 0; }
  # Abandoned lock (a sweep killed before its trap ran) is reclaimed by age.
  if find "$lock" -maxdepth 0 -mmin +$((LOCK_STALE_SECS / 60)) >/dev/null 2>&1; then
    rmdir "$lock" 2>/dev/null || true
  fi
  mkdir "$lock" 2>/dev/null || return 1
  LOCK_HELD=1
  return 0
}

release_lock() {
  [ "${LOCK_HELD:-0}" = 1 ] || return 0
  LOCK_HELD=0
  rmdir "$STATE/.$CHECK_ID.lock" 2>/dev/null || true
}

action_sweep() {
  local seat rows ledger now actions wake='' kind first task key class epoch note
  local failures=''
  require_home
  seat=$(fm_decider_task_id)
  if [ -n "$FM_DECIDER_TASK_ERROR" ]; then
    printf 'decider-route: %s; no standing-order decision is being routed\n' "$FM_DECIDER_TASK_ERROR"
    return 0
  fi
  if [ -z "$seat" ]; then
    # Armed but unconfigured is a real routing outage; unarmed is simply off.
    if [ -f "$STATE/$CHECK_ID.check.sh" ]; then
      printf 'decider-route: the check is armed but no Decider seat is configured in %s; nothing is being routed\n' \
        "$(fm_decider_task_config_path)"
    fi
    return 0
  fi
  if [ ! -f "$STATE/$seat.meta" ]; then
    printf 'decider-route: the configured Decider seat %s has no task record in this home; standing-order decisions are not being routed\n' "$seat"
    return 0
  fi
  if ! acquire_lock; then
    # Another sweep is mid-flight; it will route whatever is open.
    return 0
  fi
  trap release_lock EXIT HUP INT TERM
  ledger=$(fm_decider_ledger_path "$STATE")
  mkdir -p "$STATE"
  : >> "$ledger" || { release_lock; trap - EXIT HUP INT TERM; return 1; }
  if ! scan_or_report; then
    release_lock
    trap - EXIT HUP INT TERM
    printf 'decider-route: the fleet open-decision read did not finish within %ss; routing is deferred to the next sweep\n' "$SCAN_TIMEOUT"
    return 0
  fi
  now=$(fm_decider_now)
  rows="$STATE/.$CHECK_ID.rows.$$"
  classify_open_rows "$seat" > "$rows" || { rm -f -- "$rows"; release_lock; trap - EXIT HUP INT TERM; return 1; }
  actions=$(plan_actions "$ledger" "$rows" "$now")
  rm -f -- "$rows"

  while IFS=$'\t' read -r kind first task key class epoch note; do
    [ -n "$kind" ] || continue
    case "$kind" in
      O)
        fm_decider_ledger_append "$ledger" O "$first" "$task" "$key" "$class" "$epoch"
        ;;
      C)
        fm_decider_ledger_append "$ledger" C "$first" "$task" "$key" "$class" "$epoch"
        ;;
      E)
        fm_decider_ledger_append "$ledger" E "$first" "$task" "$key" "$class" "$epoch"
        wake="${wake:+$wake; }$task [key=$key] has waited for a ruling from the Decider seat past the window"
        ;;
      A)
        if ask_seat "$seat" "$task" "$key" "$class" "$note"; then
          fm_decider_ledger_append "$ledger" A "$first" "$task" "$key" "$class" "$epoch"
        else
          failures="${failures}${failures:+ }$task/$key"
        fi
        ;;
    esac
  done <<EOF
$actions
EOF
  if [ -n "$failures" ]; then
    wake="${wake:+$wake; }could not deliver a ruling request to the Decider seat $seat for: $failures"
  fi
  release_lock
  trap - EXIT HUP INT TERM
  [ -z "$wake" ] || fm_cap_line "decider-route:${wake}" 900
  return 0
}

# --- status ----------------------------------------------------------------

action_status() {
  local captain_only=0 seat task key verb note class route shown=0
  case "${1:-}" in
    --captain|--captain-only) captain_only=1 ;;
    '') ;;
    *) usage >&2; exit 2 ;;
  esac
  require_home
  seat=$(fm_decider_task_id)
  [ -z "$FM_DECIDER_TASK_ERROR" ] || printf 'decider-route: %s\n' "$FM_DECIDER_TASK_ERROR"
  if ! scan_or_report; then
    printf 'decider-route: the fleet open-decision read did not finish within %ss; nothing to report\n' "$SCAN_TIMEOUT"
    return 0
  fi
  printf 'OPEN DECISIONS BY CLASS (seat: %s)\n' "${seat:-none configured}"
  while IFS=$'\t' read -r task key verb note; do
    [ -n "$task" ] || continue
    [ "$verb" = needs-decision ] || continue
    fm_decider_classify_core "$key" "$note"
    class=$_FM_DECIDER_CLASS
    if fm_decider_is_standing_order "$class"; then route='to the Decider seat'; else route='stays with the captain'; fi
    if [ "$captain_only" = 1 ] && [ "$route" = 'to the Decider seat' ]; then continue; fi
    printf '%s [key=%s] class=%s -> %s\n' "$task" "$key" "$class" "$route"
    shown=$((shown + 1))
  done <<EOF
$OPEN_SET
EOF
  [ "$shown" -gt 0 ] || printf 'none open\n'
  return 0
}

# --- answer ----------------------------------------------------------------

# The episode <task>/<key> currently open in the ledger, as
# "<first_seen>\t<class>", or nothing when the ledger has no open episode.
open_episode() {  # <ledger> <task> <key>
  local ledger=$1 want_task=$2 want_key=$3
  [ -f "$ledger" ] || return 0
  awk -F'\t' -v task="$want_task" -v key="$want_key" '
    $3 == task && $4 == key {
      if ($1 == "O") { open = 1; first = $2; klass = $5 }
      else if ($1 == "C") { open = 0 }
    }
    END { if (open == 1) printf "%s\t%s\n", first, klass }
  ' "$ledger"
}

action_answer() {
  local task=${1:-} key=${2:-} ledger episode first class
  [ -n "$task" ] && [ -n "$key" ] || { usage >&2; exit 2; }
  shift 2
  [ "$#" -gt 0 ] || die 'answer needs a ruling message'
  require_home
  ledger=$(fm_decider_ledger_path "$STATE")
  episode=$(open_episode "$ledger" "$task" "$key")
  if [ -z "$episode" ]; then
    printf 'fm-decider-route: %s [key=%s] is not an episode this home routed; answer it with bin/fm-send.sh --resolve-key if it is real\n' \
      "$task" "$key" >&2
    exit 3
  fi
  first=${episode%%	*}
  class=${episode#*	}
  if [ "$class" = "$FM_DECIDER_CLASS_CAPTAIN" ]; then
    printf 'fm-decider-route: %s [key=%s] was classified class (a) and is the captain'"'"'s to answer; the seat must not rule on it (note: %s)\n' \
      "$task" "$key" 'needs the captain' >&2
    exit 3
  fi
  FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-send.sh" "$task" --resolve-key "$key" "$*" || return $?
  fm_decider_ledger_append "$ledger" R "$first" "$task" "$key" "$class" "$(fm_decider_now)"
  printf 'ruled: %s [key=%s] closed\n' "$task" "$key"
  return 0
}

# --- arming ----------------------------------------------------------------

arm_shim_content() {  # <home>
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    '# Auto-generated by fm-decider-route.sh - standing-order routing poll shim.' \
    '# The watcher validates these bytes, then dispatches the trusted check script.' \
    "export FM_HOME=$(printf '%q' "$1")" \
    "exec $(printf '%q' "$SCRIPT_DIR/fm-decider-route.sh") sweep"
}

action_arm() {
  local seat home want
  require_home
  seat=$(fm_decider_task_id)
  [ -z "$FM_DECIDER_TASK_ERROR" ] || die "$FM_DECIDER_TASK_ERROR"
  [ -n "$seat" ] || die "no Decider seat configured; write its task id to $(fm_decider_task_config_path)"
  [ -f "$STATE/$seat.meta" ] \
    || die "no task record for the Decider seat $seat; seat it first (docs/decider-worker.md)"
  home=$(fm_custom_check_resolve_home "$FM_HOME") || die "cannot resolve FM_HOME $FM_HOME"
  want=$(arm_shim_content "$home")
  # Prime the shared open-decision fold here, in the operator's turn: the first
  # read of a home's status logs folds their whole history, which must never
  # happen inside a bounded watcher check.
  printf 'priming the fleet open-decision read...\n'
  scan_open_set >/dev/null || printf 'note: the open-decision read did not finish; the first sweep will retry it\n'
  fm_custom_check_arm "$STATE" "$CHECK_ID" "$SHIM_PREFIX" "$CHECK_ID" \
    "$SCRIPT_DIR/fm-check-register.sh" "$home" "$want" || return 1
  printf 'seat: %s (configured in %s)\n' "$seat" "$(fm_decider_task_config_path)"
  printf 'disarm: bin/fm-decider-route.sh disarm\n'
  return 0
}

action_disarm() {
  local ledger
  require_home
  # The routing ledger stays behind on purpose: it is the record the measurement
  # counts, and re-arming must not erase the rulings already made.
  fm_custom_check_disarm "$STATE" "$CHECK_ID"
  ledger=$(fm_decider_ledger_path "$STATE")
  [ ! -f "$ledger" ] \
    || printf 'kept: %s (routing ledger used by bin/fm-decider-metrics.sh)\n' "${ledger#"$FM_HOME"/}"
  return 0
}

case "${1:-sweep}" in
  sweep|check) shift || true; action_sweep "$@" ;;
  status) shift || true; action_status "$@" ;;
  answer) shift || true; action_answer "$@" ;;
  arm) shift || true; action_arm "$@" ;;
  disarm) shift || true; action_disarm "$@" ;;
  -h|--help|help) usage ;;
  *) usage >&2; exit 2 ;;
esac
