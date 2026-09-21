#!/usr/bin/env bash
# fm-chair-flip.sh - deterministic actuator that moves the firstmate chair
# between Pi+Fable (the token pool) and Grok. No model call anywhere: a plain
# script decides and acts, because a model with no tokens cannot perform prose.
#
# Usage:
#   fm-chair-flip.sh to-pi-fable [--force]
#   fm-chair-flip.sh to-grok
#   fm-chair-flip.sh --help
#
# `--force` re-seats a chair that is already pi-fable even though its bound
# source does not read red (source unknown/none, or its pool merely
# unmeasured); without it such a call is a no-op that says why, the same rule
# the sentinel applies. A forced re-seat still writes the handoff first.
#
# Order of operations (fixed, and the handoff file always comes first):
#
#   0. Refuse when the chair status line is unreadable (no `chair=` field): a
#      successor is never launched blind on top of whatever holds the lock.
#   1. Refuse unless the target is reachable. `to-grok` requires SuperGrok above
#      its safety floor; `to-pi-fable` requires a green Fable source in
#      `fm-chair-runway.sh` and launches Pi against that source only: the 8317
#      token pool (`token-pool/claude-fable-5-1`) when it is green, otherwise
#      the 8080 better-ccflare gateway (the `anthropic` provider with
#      ANTHROPIC_BASE_URL=http://127.0.0.1:8080). A target reading `unknown` is
#      never flipped toward, and Pi is never pointed at a source that is not
#      green. A chair already at the target is a no-op, except a Pi chair whose
#      bound source (`source=` in the status line) reads red: it is re-seated
#      on the green source, handoff first, under the same hysteresis. Any other
#      already-pi-fable chair is re-seated only with --force.
#   2. Refuse within the hysteresis window: at most one attempt per
#      FM_CHAIR_HYSTERESIS_SECS (default 1800) is recorded in
#      state/.chair-flip-at.
#   3. Refuse when Orca cannot be reached (`orca terminal list --json` must
#      answer, the same call whose failure `fm-chair-status.sh` reports as
#      reason=orca_unavailable): the incumbent is never ended when the
#      successor could not be launched.
#   4. Write data/handoff-<from>-to-<to>.md: timestamp, the sensor line, the
#      chosen source, the status-log path of every task in flight with the last
#      20 lines of each, and pointers to data/MEMORY-INDEX.md, data/captain.md
#      and data/learnings.md. This is what carries memory across the flip.
#   5. Record the attempt timestamp, then end the current chair: send its
#      harness's own exit command (`/quit` for Pi, `/exit` for Grok and Claude;
#      bin/fm-control-lib.sh fm_control_exit_command owns that fact) to its
#      Orca terminal whenever one is known, wait up to
#      FM_CHAIR_EXIT_WAIT_SECS (default 60) for the harness pid to die, then
#      SIGTERM that exact pid. The pid is the one `fm-chair-status.sh` identified
#      as a live harness (its `pid=` field), never the raw contents of
#      state/.lock: a stale lock whose pid was recycled by an unrelated process
#      is `pid=none` and nothing is signalled. When no terminal is known the
#      graceful step is skipped and the log line says so. Never pkill -f, never
#      a second chair on top of a first. The stamp goes first so a flip that
#      acted and then failed verification is still bounded by the hysteresis
#      window.
#   6. Launch the successor in a NEW Orca terminal in this home, titled
#      `π - firstmate` or `grok - firstmate`, with the one-line first prompt
#      naming the handoff file passed as the harness's positional argument (the
#      same shape bin/fm-spawn.sh uses), so nothing is typed into a shell that
#      may still be initialising.
#   7. Verify within FM_CHAIR_VERIFY_SECS (default 120) that state/.lock is held
#      by a live harness pid other than the incumbent's and that
#      state/.last-watcher-beat was written at or after the moment the
#      successor's terminal was created, i.e. after the incumbent had already
#      exited (the beat file is shared and the incumbent's watcher keeps
#      touching it every poll until then, so any earlier reference would be
#      satisfied by the predecessor). On success record state/.chair-source
#      for the new lock pid. Print the exact failure and exit nonzero
#      otherwise.
#
# Output carries `source=<8317|8080|grok>` so the caller can log which tank
# the successor was launched on, and a verified flip records
# state/.chair-source (`pid=<lock pid> source=<8317|8080|grok>
# launched_at=<epoch>`) so `fm-chair-status.sh` can name the chair's tank
# afterwards (Pi hides its command line, so nothing else carries it).
#
# FM_CHAIR_FLIP_DRY_RUN=1 prints every command it would run and still writes the
# handoff file, then touches nothing else.
#
# Test seams:
#   FM_CHAIR_FLIP_DRY_RUN      1 = print commands, act on nothing
#   FM_CHAIR_FLIP_HOME         home directory (default $FM_HOME)
#   FM_CHAIR_FLIP_ORCA_CMD     Orca CLI (default: orca)
#   FM_CHAIR_FLIP_SENSOR_CMD   override the sensor (bin/fm-chair-runway.sh)
#   FM_CHAIR_FLIP_STATUS_CMD   override the chair status (bin/fm-chair-status.sh)
#   FM_CHAIR_FLIP_SLEEP_CMD    sleep (default: sleep)
#   FM_CHAIR_HYSTERESIS_SECS   minimum seconds between flips
#   FM_CHAIR_EXIT_WAIT_SECS    seconds to wait for the incumbent to release the lock
#   FM_CHAIR_VERIFY_SECS       seconds to wait for the successor lock
set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
HOME_DIR=${FM_CHAIR_FLIP_HOME:-$FM_HOME}
ABS_HOME=$(cd -- "$HOME_DIR" 2>/dev/null && pwd -P) || ABS_HOME=$HOME_DIR
STATE_DIR=$ABS_HOME/state
DATA_DIR=$ABS_HOME/data
ORCA=${FM_CHAIR_FLIP_ORCA_CMD:-orca}
SLEEP_CMD=${FM_CHAIR_FLIP_SLEEP_CMD:-sleep}
DRY_RUN=${FM_CHAIR_FLIP_DRY_RUN:-0}
HYSTERESIS_SECS=${FM_CHAIR_HYSTERESIS_SECS:-1800}
EXIT_WAIT_SECS=${FM_CHAIR_EXIT_WAIT_SECS:-60}
VERIFY_SECS=${FM_CHAIR_VERIFY_SECS:-120}
FLIP_STAMP=$STATE_DIR/.chair-flip-at

# shellcheck source=bin/fm-control-lib.sh
. "$SCRIPT_DIR/fm-control-lib.sh"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "${BASH_SOURCE[0]}"
  exit 2
}

TO=${1:-}
FORCE=0
case "$TO" in
  to-pi-fable|to-grok) ;;
  -h|--help|help|'') usage ;;
  *) usage ;;
esac
shift
for arg in "$@"; do
  case "$arg" in
    --force) [ "$TO" = to-pi-fable ] || usage; FORCE=1 ;;
    *) usage ;;
  esac
done

log() { printf '%s\n' "$*"; }

run() {  # <command...>: silent when live, printed when dry
  if [ "$DRY_RUN" = 1 ]; then
    log "DRY-RUN: $*"
  else
    "$@" >/dev/null 2>&1
  fi
}

run_capture() {  # <command...> -> stdout
  if [ "$DRY_RUN" = 1 ]; then
    log "DRY-RUN(capture): $*" >&2
    return 0
  fi
  "$@"
}

# --- sensor and chair -------------------------------------------------------

sensor_line() {
  if [ -n "${FM_CHAIR_FLIP_SENSOR_CMD:-}" ]; then
    "$FM_CHAIR_FLIP_SENSOR_CMD" 2>/dev/null
  else
    FM_HOME="$ABS_HOME" "$SCRIPT_DIR/fm-chair-runway.sh" 2>/dev/null
  fi
}

chair_line() {
  if [ -n "${FM_CHAIR_FLIP_STATUS_CMD:-}" ]; then
    "$FM_CHAIR_FLIP_STATUS_CMD" 2>/dev/null
  else
    FM_HOME="$ABS_HOME" "$SCRIPT_DIR/fm-chair-status.sh" 2>/dev/null
  fi
}

extract_field() {  # <line> <key>
  printf '%s\n' "$1" | sed -n "s/.*[[:space:]]$2=\([^ ]*\).*/\1/p" | head -1
}

SENSOR=$(sensor_line)
STATUS=$(chair_line)
CHAIR=$(extract_field "$STATUS" chair)
TERMINAL=$(extract_field "$STATUS" terminal)
INCUMBENT_PID=$(extract_field "$STATUS" pid)
case "$INCUMBENT_PID" in ''|*[!0-9]*) INCUMBENT_PID=none ;; esac
INCUMBENT_HARNESS=$(extract_field "$STATUS" harness)
CHAIR_SOURCE=$(extract_field "$STATUS" source)
EXIT_CMD=$(fm_control_exit_command "${INCUMBENT_HARNESS:-none}") || EXIT_CMD=''

if [ -z "$CHAIR" ]; then
  log "chair-flip: refuse: chair status unreadable ($STATUS); a second chair is never launched blind"
  exit 1
fi

FABLE=$(extract_field "$SENSOR" fable)
POOL8317=$(extract_field "$SENSOR" pool8317)
CCFLARE=$(extract_field "$SENSOR" ccflare)
GROK_STATE=$(extract_field "$SENSOR" grok)

# The successor is launched on one concrete green source, never on the OR:
# 8317 when it is green, else 8080 when it is green. Fable green with neither
# pool green is a contradiction in the sensor line and is refused as unreadable.
case "$TO" in
  to-pi-fable)
    TARGET_CHAIR=pi-fable; TARGET_STATE=$FABLE; TARGET_NAME=Fable
    TITLE='π - firstmate'
    if [ "$POOL8317" = green ]; then
      SOURCE=8317
      LAUNCH='pi --model token-pool/claude-fable-5-1 --thinking high'
    elif [ "$CCFLARE" = green ]; then
      SOURCE=8080
      LAUNCH='ANTHROPIC_BASE_URL=http://127.0.0.1:8080 pi --model anthropic/claude-fable-5-1 --thinking high'
    else
      SOURCE=none
      LAUNCH=''
    fi
    ;;
  to-grok)
    TARGET_CHAIR=grok; TARGET_STATE=$GROK_STATE; TARGET_NAME=SuperGrok
    TITLE='grok - firstmate'
    SOURCE=grok
    LAUNCH='grok --always-approve'
    ;;
esac

# FROM is the chair we are leaving, not the target's name: a handoff file is
# named for the direction actually taken. A chair already at the target is a
# no-op, except a Pi chair whose bound Fable source reads RED: that chair is
# re-seated on the source that is green. Any other already-pi-fable chair
# (source unknown or none, or its pool merely unmeasured) is left alone unless
# --force asks for the re-seat, the same rule the sentinel applies.
FROM=$CHAIR

if [ "$CHAIR" = "$TARGET_CHAIR" ]; then
  case "$TARGET_CHAIR:$CHAIR_SOURCE" in
    pi-fable:8317) BOUND_STATE=$POOL8317 ;;
    pi-fable:8080) BOUND_STATE=$CCFLARE ;;
    pi-fable:*) BOUND_STATE=$CHAIR_SOURCE ;;
    *) log "chair-flip: no-op (chair is already $TARGET_CHAIR)"; exit 0 ;;
  esac
  if [ "$BOUND_STATE" = red ]; then
    log "chair-flip: re-seat: chair is pi-fable on source $CHAIR_SOURCE, which reads red (pool8317=$POOL8317 ccflare=$CCFLARE)"
  elif [ "$FORCE" = 1 ]; then
    log "chair-flip: re-seat (--force): chair is pi-fable on source $CHAIR_SOURCE, bound state $BOUND_STATE (pool8317=$POOL8317 ccflare=$CCFLARE)"
  else
    log "chair-flip: no-op (chair is already pi-fable on source $CHAIR_SOURCE, bound state $BOUND_STATE, not red; pass --force to re-seat anyway)"
    exit 0
  fi
fi

# Reachability: never flip toward unknown or red.
case "$TARGET_STATE" in
  green) ;;
  unknown) log "chair-flip: refuse to-flip toward $TARGET_NAME: source is unknown ($SENSOR)"; exit 1 ;;
  red) log "chair-flip: refuse to-flip toward $TARGET_NAME: source is red ($SENSOR)"; exit 1 ;;
  *) log "chair-flip: refuse to-flip toward $TARGET_NAME: source unreadable ($SENSOR)"; exit 1 ;;
esac
if [ "$SOURCE" = none ]; then
  log "chair-flip: refuse to-flip toward $TARGET_NAME: no green Fable source to launch on ($SENSOR)"
  exit 1
fi

# Hysteresis.
NOW=$(date +%s)
if [ -f "$FLIP_STAMP" ]; then
  LAST=$(cat -- "$FLIP_STAMP" 2>/dev/null) || LAST=''
  case "$LAST" in
    ''|*[!0-9]*) : ;;
    *)
      if [ $((NOW - LAST)) -lt "$HYSTERESIS_SECS" ]; then
        log "chair-flip: refuse within hysteresis window ($((NOW - LAST))s < ${HYSTERESIS_SECS}s)"
        exit 1
      fi
      ;;
  esac
fi

# Never end the incumbent when the successor could not be launched: Orca must
# answer now, not merely be on PATH.
if [ "$DRY_RUN" != 1 ] && ! "$ORCA" terminal list --json 2>/dev/null | jq -e 'type == "object"' >/dev/null 2>&1; then
  log "chair-flip: refuse: Orca CLI '$ORCA' not found or not answering; the successor could not be launched (status: $STATUS)"
  exit 1
fi

log "chair-flip: target=$TARGET_CHAIR source=$SOURCE"

# --- handoff file -----------------------------------------------------------

write_handoff() {
  local out="$DATA_DIR/handoff-${FROM}-to-${TO#to-}.md" line task
  mkdir -p "$DATA_DIR" 2>/dev/null || true
  {
    printf '# Handoff: %s chair to %s\n\n' "$FROM" "${TO#to-}"
    printf 'Written %s by bin/fm-chair-flip.sh.\n\n' "$(date -u +%FT%TZ)"
    printf '## Sensor\n\n%s\n\n' "$SENSOR"
    printf '## Chair now\n\n%s\n\n' "$STATUS"
    printf '## Successor\n\nsource=%s\nlaunch=%s\n\n' "$SOURCE" "$LAUNCH"
    cat <<'MEMEOF'
## Memories (read these first)

1. data/MEMORY-INDEX.md
2. data/captain.md
3. data/learnings.md
4. ~/.llm-wiki (house source of truth)

## Work in flight

MEMEOF
    local n=0
    for task in "$STATE_DIR"/*.status; do
      [ -f "$task" ] || continue
      n=$((n + 1))
      printf '### %s\n\n' "$(basename "$task")"
      printf 'path: %s\n\n' "$task"
      printf '```\n'
      tail -n 20 "$task" 2>/dev/null || true
      printf '```\n\n'
    done
    [ "$n" -gt 0 ] || printf '(none)\n\n'
    printf '## Inbox\n\n'
    for line in "$STATE_DIR"/*.inbox/*.msg; do
      [ -f "$line" ] || continue
      printf -- '- %s\n' "$line"
    done
  } > "$out"
  printf '%s\n' "$out"
}

if [ "$DRY_RUN" = 1 ]; then
  log "DRY-RUN: would write handoff $DATA_DIR/handoff-${FROM}-to-${TO#to-}.md"
  HANDOFF=$DATA_DIR/handoff-${FROM}-to-${TO#to-}.md
  OUT=$(write_handoff)
  HANDOFF=$OUT
else
  HANDOFF=$(write_handoff) || { log "chair-flip: could not write handoff file"; exit 1; }
fi
log "chair-flip: handoff written: $HANDOFF"

# --- end the incumbent ------------------------------------------------------

harness_pid_alive() {  # <pid|none>
  [ "$1" != none ] && kill -0 "$1" 2>/dev/null
}

if [ "$DRY_RUN" != 1 ]; then
  mkdir -p "$STATE_DIR" 2>/dev/null || true
  printf '%s\n' "$NOW" > "$FLIP_STAMP"
fi

if [ -n "$TERMINAL" ] && [ "$TERMINAL" != none ] && [ -n "$EXIT_CMD" ]; then
  run "$ORCA" terminal send --terminal "$TERMINAL" --text "$EXIT_CMD" --enter --json || true
elif harness_pid_alive "$INCUMBENT_PID"; then
  log "chair-flip: no terminal or exit command known for incumbent $INCUMBENT_HARNESS pid $INCUMBENT_PID (status: $STATUS); no graceful exit, waiting ${EXIT_WAIT_SECS}s then SIGTERM"
fi

waited=0
while [ "$DRY_RUN" != 1 ] && [ "$waited" -lt "$EXIT_WAIT_SECS" ] && harness_pid_alive "$INCUMBENT_PID"; do
  "$SLEEP_CMD" 2
  waited=$((waited + 2))
done

if [ "$DRY_RUN" != 1 ] && harness_pid_alive "$INCUMBENT_PID"; then
  log "chair-flip: incumbent pid $INCUMBENT_PID still alive after ${EXIT_WAIT_SECS}s; SIGTERM"
  run kill -TERM "$INCUMBENT_PID" || true
  waited=0
  while [ "$waited" -lt 20 ] && harness_pid_alive "$INCUMBENT_PID"; do
    "$SLEEP_CMD" 2
    waited=$((waited + 2))
  done
fi

if [ "$DRY_RUN" != 1 ]; then
  PID_NOW=$(extract_field "$(chair_line)" pid)
  case "$PID_NOW" in ''|*[!0-9]*) PID_NOW=none ;; esac
  if harness_pid_alive "$PID_NOW"; then
    log "chair-flip: refuse to launch a second chair; harness pid $PID_NOW still holds the lock"
    exit 1
  fi
fi

# --- launch the successor ---------------------------------------------------

sh_quote() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }

PROMPT=$(printf 'Take the helm: run bin/fm-session-start.sh, then read %s and continue supervising the fleet.' "$HANDOFF")
LAUNCH_CMD="$LAUNCH $(sh_quote "$PROMPT")"

if [ "$DRY_RUN" = 1 ]; then
  log "DRY-RUN: $ORCA terminal create --worktree path:$ABS_HOME --title '$TITLE' --command $(sh_quote "$LAUNCH_CMD") --json"
else
  LAUNCH_AT=$(date +%s)
  CREATE_JSON=$(run_capture "$ORCA" terminal create --worktree "path:$ABS_HOME" --title "$TITLE" --command "$LAUNCH_CMD" --json 2>/dev/null) || CREATE_JSON=''
  NEW_TERMINAL=$(printf '%s' "$CREATE_JSON" | jq -r '.result.terminal.handle // .result.handle // empty' 2>/dev/null) || NEW_TERMINAL=''
  [ -n "$NEW_TERMINAL" ] || { log "chair-flip: terminal create did not return a handle"; exit 1; }
  log "chair-flip: successor launched in terminal $NEW_TERMINAL"
fi

# --- verify -----------------------------------------------------------------

if [ "$DRY_RUN" = 1 ]; then
  log "chair-flip: flipped to $TO (verification skipped)"
else
  ok=0
  waited=0
  while [ "$waited" -lt "$VERIFY_SECS" ]; do
    V_STATUS=$(chair_line)
    V_CHAIR=$(extract_field "$V_STATUS" chair)
    V_PID=$(extract_field "$V_STATUS" pid)
    case "$V_PID" in ''|*[!0-9]*) V_PID=none ;; esac
    if [ "$V_CHAIR" = none ] || [ "$V_PID" = none ] || [ "$V_PID" = "$INCUMBENT_PID" ]; then
      "$SLEEP_CMD" 5
      waited=$((waited + 5))
      continue
    fi
    BEAT=$STATE_DIR/.last-watcher-beat
    # GNU stat accepts -f too (filesystem status), so pick the syntax by OS
    # instead of falling through on exit status.
    if [ "$(uname 2>/dev/null)" = Darwin ]; then
      BEAT_AT=$(stat -f %m "$BEAT" 2>/dev/null) || BEAT_AT=0
    else
      BEAT_AT=$(stat -c %Y "$BEAT" 2>/dev/null) || BEAT_AT=0
    fi
    if [ "$BEAT_AT" -ge "$LAUNCH_AT" ]; then
      ok=1
      printf 'pid=%s source=%s launched_at=%s\n' "$V_PID" "$SOURCE" "$LAUNCH_AT" > "$STATE_DIR/.chair-source"
      break
    fi
    "$SLEEP_CMD" 5
    waited=$((waited + 5))
  done
  if [ "$ok" != 1 ]; then
    log "chair-flip: verification failed after ${VERIFY_SECS}s: status=$(chair_line) beat_at=${BEAT_AT:-none} launched_at=$LAUNCH_AT (want a live harness pid other than $INCUMBENT_PID and a watcher beat written after the successor was launched)"
    exit 1
  fi
fi

log "chair-flip: flipped $FROM -> $TO source=$SOURCE"
exit 0