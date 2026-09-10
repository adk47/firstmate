#!/usr/bin/env bash
# Out-of-session keep-alive supervisor for the PRIMARY firstmate session.
#
# One bounded pass, designed to be run every few minutes by launchd
# (bin/fm-keepalive-install.sh installs the job). It is the supervisor of the
# supervisor: everything else in firstmate that notices trouble runs INSIDE the
# primary session or inside a process the primary session started, so a primary
# that is itself stalled at its prompt has nobody to notice. This runs from
# launchd, outside all of it.
#
# It does exactly three things, in this order, and stops at the first one that
# applies:
#
#   1. GATEWAY STALL. The primary's pane is idle showing a transient
#      inference-gateway error. Re-ring it with a continue line, on the same
#      bounded ladder crewmates get (bin/fm-gateway-retry-lib.sh owns entry,
#      backoff, and both bounds). Gated on the pane being IDLE by the same
#      rendered busy predicate every other pane reader uses
#      (bin/fm-composer-lib.sh, fm_busy_lines_match), so a primary the captain
#      already nudged and that is mid-turn is never typed into.
#   2. LAPSED SUPERVISION. The primary is alive but its watcher beacon is stale
#      past grace and no auto-arm claim is in progress, so the fleet is running
#      unsupervised. Re-ring the primary with the home's own repair line
#      (bin/fm-supervision-instructions.sh --repair-line owns its wording), so
#      the session performs the repair its protocol prescribes rather than this
#      agent second-guessing it.
#   3. SESSION GONE. The home's session lock names no live owner. Report it.
#
# WHAT IT WILL NOT DO. It never relaunches firstmate, never interrupts, never
# sends a key that is not part of a doorbell submit, never touches another
# home, and never acts on a pane it cannot prove is this home's primary. Those
# boundaries are not caution for its own sake: this process runs unattended with
# no session lock and no captain watching, so anything it does wrong it does
# repeatedly and invisibly. Reporting a dead session and letting a human restart
# it is the correct outcome for the one case where guessing would be worst.
#
# Idempotent and single-flight: overlapping launchd firings are serialized by a
# lock, and every action it can take is bounded by a durable budget that
# survives its own restart.
#
# Usage: fm-keepalive-agent.sh [--home <dir>] [--dry-run] [--verbose]
#   --home     the firstmate home to supervise; defaults to FM_HOME, then the
#              repository root this script lives in
#   --dry-run  classify and log, deliver nothing
#   --verbose  also write the log line to stderr
#
# Exit status is always 0 unless its own arguments are wrong: launchd treats a
# non-zero exit as a failed job and this agent must not accumulate failures for
# conditions it is designed to observe.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"

HOME_DIR=''
DRY_RUN=0
VERBOSE=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --home) HOME_DIR=${2:-}; shift 2 || exit 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --verbose) VERBOSE=1; shift ;;
    -h|--help) sed -n '2,45p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "error: unknown argument '$1'" >&2; exit 2 ;;
  esac
done

[ -n "$HOME_DIR" ] || HOME_DIR="${FM_HOME:-$FM_ROOT}"
if [ ! -d "$HOME_DIR" ]; then
  echo "error: firstmate home '$HOME_DIR' does not exist" >&2
  exit 2
fi
FM_HOME=$HOME_DIR
export FM_HOME
STATE="${FM_STATE_OVERRIDE:-$HOME_DIR/state}"
LOG="$STATE/.keepalive-agent.log"
LOCK="$STATE/.keepalive-agent.lock"
GRACE=${FM_GUARD_GRACE:-300}

# shellcheck source=bin/fm-gateway-retry-lib.sh
. "$SCRIPT_DIR/fm-gateway-retry-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-composer-lib.sh
. "$SCRIPT_DIR/fm-composer-lib.sh"
# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"

log() {  # <message>
  local line
  line="$(date '+%Y-%m-%dT%H:%M:%S%z') $*"
  [ -d "$STATE" ] || return 0
  printf '%s\n' "$line" >> "$LOG" 2>/dev/null || true
  # Keep the log bounded: this runs every few minutes forever.
  if [ "$(wc -l < "$LOG" 2>/dev/null || echo 0)" -gt 2000 ]; then
    tail -n 500 "$LOG" > "$LOG.trim" 2>/dev/null && mv -f "$LOG.trim" "$LOG" 2>/dev/null || true
  fi
  [ "$VERBOSE" -eq 0 ] || printf '%s\n' "$line" >&2
}

# Single-flight. launchd will happily start a second copy while the first is
# still polling a slow terminal, and two copies would double-charge the retry
# budget on the same stall.
if ! mkdir "$LOCK" 2>/dev/null; then
  if [ -f "$LOCK/pid" ] && kill -0 "$(cat "$LOCK/pid" 2>/dev/null || echo 0)" 2>/dev/null; then
    exit 0
  fi
  # A lock with no live owner is debris from a killed pass.
  rm -rf "$LOCK" 2>/dev/null || true
  mkdir "$LOCK" 2>/dev/null || exit 0
fi
printf '%s' "$$" > "$LOCK/pid" 2>/dev/null || true
trap 'rm -rf "$LOCK" 2>/dev/null || true' EXIT INT TERM

# --- what this home's primary session is ------------------------------------

endpoint_field() {  # <field>
  "$SCRIPT_DIR/fm-keepalive-endpoint.sh" read --state "$STATE" --field "$1" 2>/dev/null | tr -d '\n'
}

BACKEND=$(endpoint_field backend)
TARGET=$(endpoint_field target)
HARNESS=$(endpoint_field harness)
[ "$HARNESS" != unknown ] || HARNESS=''
if [ -z "$BACKEND" ] || [ -z "$TARGET" ]; then
  log "inert: no recorded primary endpoint for $HOME_DIR (the main home's session start records it; a secondmate home runs bin/fm-keepalive-install.sh from its primary pane, or passes --backend/--target)"
  exit 0
fi

# The session lock's owner is what makes this home's primary a real thing rather
# than a remembered pane id. state/.lock holds the BARE pid bin/fm-lock.sh wrote,
# and liveness is the shared harness predicate every sibling reader uses, so a
# reused pid that is no longer a harness is not a live session. A home whose
# session ended is REPORTED rather than re-rung: sending a continue line into a
# pane that is now a plain shell would type firstmate's words at a prompt.
LOCK_PID=$(cat "$STATE/.lock" 2>/dev/null || true)
case "$LOCK_PID" in ''|*[!0-9]*) LOCK_PID='' ;; esac
SESSION_LIVE=0
if [ -n "$LOCK_PID" ] && fm_harness_pid_alive "$LOCK_PID"; then
  SESSION_LIVE=1
fi

# --- 1. gateway stall --------------------------------------------------------

PANE=$(fm_backend_capture "$BACKEND" "$TARGET" 40 2>/dev/null) || PANE=''
if [ -z "$PANE" ]; then
  log "inert: could not read the primary pane ($BACKEND $TARGET)"
  exit 0
fi

# The same busy verdict bin/fm-watch.sh gates on: a backend's native semantic
# state when it has one, else the recorded harness's busy signature over the
# footer area of the capture already read. A busy primary is mid-turn - most
# likely because the captain or a previous pass already nudged it - and nothing
# may be typed into it, so step 1 stands down without classifying or charging.
pane_is_busy() {
  [ "$(fm_backend_busy_state "$BACKEND" "$TARGET" 2>/dev/null)" = busy ] && return 0
  printf '%s' "$PANE" | grep -v '^[[:space:]]*$' | tail -12 | fm_busy_lines_match "$HARNESS"
}

if ! pane_is_busy && fm_gateway_stalled_now "$STATE" "$FM_GATEWAY_PRIMARY_SCOPE" "$PANE"; then
  if [ "$SESSION_LIVE" -eq 0 ]; then
    log "gateway stall seen but this home's session lock names no live owner; not re-ringing a pane that may no longer be firstmate"
    exit 0
  fi
  if fm_gateway_budget_spent "$STATE" "$FM_GATEWAY_PRIMARY_SCOPE"; then
    if ! fm_gateway_notified "$STATE" "$FM_GATEWAY_PRIMARY_SCOPE"; then
      log "OUTAGE: the inference gateway has kept the primary stalled through $(fm_gateway_attempts "$STATE" "$FM_GATEWAY_PRIMARY_SCOPE") continue attempts over $(fm_gateway_stall_age "$STATE" "$FM_GATEWAY_PRIMARY_SCOPE")s; no longer re-ringing"
      fm_gateway_mark_notified "$STATE" "$FM_GATEWAY_PRIMARY_SCOPE" || true
    fi
    exit 0
  fi
  if ! fm_gateway_attempt_due "$STATE" "$FM_GATEWAY_PRIMARY_SCOPE"; then
    exit 0
  fi
  if [ "$DRY_RUN" -eq 1 ]; then
    log "dry-run: would send the primary a gateway keep-alive continue line"
    exit 0
  fi
  # Charge before delivering, for the same reason the watcher does: an uncounted
  # send is the one failure an unattended bounded loop cannot absorb.
  fm_gateway_record_attempt "$STATE" "$FM_GATEWAY_PRIMARY_SCOPE" || {
    log "refused: the gateway keep-alive attempt could not be recorded, so it was not sent"
    exit 0
  }
  if fm_backend_send_text_submit "$BACKEND" "$TARGET" "$FM_GATEWAY_CONTINUE_TEXT" 1 0.4 0.3 >/dev/null 2>&1; then
    log "sent the primary a gateway keep-alive continue line (attempt $(fm_gateway_attempts "$STATE" "$FM_GATEWAY_PRIMARY_SCOPE"))"
  else
    log "the gateway keep-alive continue line could not be delivered to $BACKEND $TARGET (attempt $(fm_gateway_attempts "$STATE" "$FM_GATEWAY_PRIMARY_SCOPE") still charged)"
  fi
  exit 0
fi

# --- 2. session gone ---------------------------------------------------------

if [ "$SESSION_LIVE" -eq 0 ]; then
  NOTICE="$STATE/.keepalive-session-gone"
  if [ ! -e "$NOTICE" ] || [ "$(( $(date +%s) - $(stat -f %m "$NOTICE" 2>/dev/null || stat -c %Y "$NOTICE" 2>/dev/null || echo 0) ))" -ge 3600 ]; then
    log "ATTENTION: this home's firstmate session is not running (no live owner on $STATE/.lock); start it in $BACKEND $TARGET"
    : > "$NOTICE" 2>/dev/null || true
  fi
  exit 0
fi
rm -f "$STATE/.keepalive-session-gone" 2>/dev/null || true

# --- 3. lapsed supervision ---------------------------------------------------

# Only a home that actually has something to supervise can have LAPSED
# supervision. An idle home with no work and no relay poll is correctly quiet,
# and nagging it would be this agent inventing work.
NEEDS_SUPERVISION=0
for f in "$STATE"/*.meta; do
  [ -e "$f" ] || continue
  NEEDS_SUPERVISION=1
  break
done
[ "$NEEDS_SUPERVISION" -eq 1 ] || [ ! -e "$STATE/x-watch.check.sh" ] || NEEDS_SUPERVISION=1
if [ "$NEEDS_SUPERVISION" -eq 0 ]; then
  exit 0
fi

# Away mode hands supervision to its own daemon, which owns the watcher's
# lifecycle and legitimately leaves gaps between cycles. Standing down there is
# the same deference the turn-end guard applies.
[ ! -e "$STATE/.afk" ] || exit 0

BEACON="$STATE/.last-watcher-beat"
BEACON_AGE=999999
if [ -e "$BEACON" ]; then
  BEACON_MTIME=$(stat -f %m "$BEACON" 2>/dev/null || stat -c %Y "$BEACON" 2>/dev/null || echo '')
  case "$BEACON_MTIME" in
    ''|*[!0-9]*) : ;;
    *) BEACON_AGE=$(( $(date +%s) - BEACON_MTIME )) ;;
  esac
fi
[ "$BEACON_AGE" -ge "$GRACE" ] || exit 0

# An auto-arm in progress is exactly the healthy transition this would otherwise
# misread, so give it a whole grace period of its own before nagging.
AUTOARM_EPOCH="$STATE/.claude-autoarm-epoch"
if [ -e "$AUTOARM_EPOCH" ]; then
  EPOCH_MTIME=$(stat -f %m "$AUTOARM_EPOCH" 2>/dev/null || stat -c %Y "$AUTOARM_EPOCH" 2>/dev/null || echo '')
  case "$EPOCH_MTIME" in
    ''|*[!0-9]*) : ;;
    *) [ "$(( $(date +%s) - EPOCH_MTIME ))" -ge "$GRACE" ] || exit 0 ;;
  esac
fi

# Bounded nag, one per stale episode plus a slow repeat, so a home whose
# supervision genuinely cannot be repaired does not get a message every few
# minutes forever.
NAG="$STATE/.keepalive-supervision-nagged"
NAG_AGE=999999
if [ -e "$NAG" ]; then
  NAG_MTIME=$(stat -f %m "$NAG" 2>/dev/null || stat -c %Y "$NAG" 2>/dev/null || echo '')
  case "$NAG_MTIME" in
    ''|*[!0-9]*) : ;;
    *) NAG_AGE=$(( $(date +%s) - NAG_MTIME )) ;;
  esac
fi
[ "$NAG_AGE" -ge "$(( GRACE * 4 ))" ] || exit 0

REPAIR=$("$SCRIPT_DIR/fm-supervision-instructions.sh" --repair-line 2>/dev/null | head -1)
[ -n "$REPAIR" ] || REPAIR='re-establish fleet supervision using the protocol from your session-start instructions.'
MSG="Firstmate keep-alive: fleet supervision has been down for ${BEACON_AGE}s with work in flight. $REPAIR"
if [ "$DRY_RUN" -eq 1 ]; then
  log "dry-run: would send the primary a supervision repair line (beacon ${BEACON_AGE}s stale)"
  exit 0
fi
: > "$NAG" 2>/dev/null || true
if fm_backend_send_text_submit "$BACKEND" "$TARGET" "$MSG" 1 0.4 0.3 >/dev/null 2>&1; then
  log "sent the primary a supervision repair line (beacon ${BEACON_AGE}s stale)"
else
  log "the supervision repair line could not be delivered to $BACKEND $TARGET (beacon ${BEACON_AGE}s stale)"
fi
exit 0
