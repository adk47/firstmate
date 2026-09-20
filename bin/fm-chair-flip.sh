#!/usr/bin/env bash
# fm-chair-flip.sh - deterministic actuator that moves the firstmate chair
# between Pi+Fable (the token pool) and Grok. No model call anywhere: a plain
# script decides and acts, because a model with no tokens cannot perform prose.
#
# Usage:
#   fm-chair-flip.sh to-pi-fable
#   fm-chair-flip.sh to-grok
#   fm-chair-flip.sh --help
#
# Order of operations (fixed, and the handoff file always comes first):
#
#   1. Refuse unless the target is reachable. `to-grok` requires SuperGrok above
#      its safety floor; `to-pi-fable` requires a green Fable source in
#      `fm-chair-runway.sh` and launches Pi against that source only: the 8317
#      token pool (`token-pool/claude-fable-5-1`) when it is green, otherwise
#      the 8080 better-ccflare gateway (the `anthropic` provider with
#      ANTHROPIC_BASE_URL=http://127.0.0.1:8080). A target reading `unknown` is
#      never flipped toward, and Pi is never pointed at a source that is not
#      green.
#   2. Refuse within the hysteresis window: at most one attempt per
#      FM_CHAIR_HYSTERESIS_SECS (default 1800) is recorded in
#      state/.chair-flip-at.
#   3. Refuse when the Orca CLI cannot be found: the incumbent is never ended
#      when the successor could not be launched.
#   4. Write data/handoff-<from>-to-<to>.md: timestamp, the sensor line, the
#      chosen source, the status-log path of every task in flight with the last
#      20 lines of each, and pointers to data/MEMORY-INDEX.md, data/captain.md
#      and data/learnings.md. This is what carries memory across the flip.
#   5. Record the attempt timestamp, then end the current chair: send `/exit`
#      to its Orca terminal whenever one is known, wait up to
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
#      by a live harness pid and state/.last-watcher-beat is under
#      FM_CHAIR_BEAT_MAX_SECS (default 300). Print the exact failure and exit
#      nonzero otherwise.
#
# Output carries `source=<8317|8080|supergrok>` so the caller can log which
# tank the successor was launched on.
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
BEAT_MAX_SECS=${FM_CHAIR_BEAT_MAX_SECS:-300}
FLIP_STAMP=$STATE_DIR/.chair-flip-at

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "${BASH_SOURCE[0]}"
  exit 2
}

TO=${1:-}
case "$TO" in
  to-pi-fable|to-grok) ;;
  -h|--help|help|'') usage ;;
  *) usage ;;
esac

log() { printf '%s\n' "$*"; }

run() {  # <command...>
  if [ "$DRY_RUN" = 1 ]; then
    log "DRY-RUN: $*"
  else
    "$@"
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
    SOURCE=supergrok
    LAUNCH='grok --permission-mode bypassPermissions'
    ;;
esac

# FROM is the chair we are leaving, not the target's name: a handoff file is
# named for the direction actually taken, and a chair already at the target is a
# no-op.
FROM=$CHAIR

if [ "$CHAIR" = "$TARGET_CHAIR" ]; then
  log "chair-flip: no-op (chair is already $TARGET_CHAIR)"
  exit 0
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

# Never end the incumbent when the successor could not be launched.
if [ "$DRY_RUN" != 1 ] && ! command -v "$ORCA" >/dev/null 2>&1; then
  log "chair-flip: refuse: Orca CLI '$ORCA' not found on PATH; the successor could not be launched"
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
      printf '- %s\n' "$line"
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

if [ -n "$TERMINAL" ] && [ "$TERMINAL" != none ]; then
  run "$ORCA" terminal send --terminal "$TERMINAL" --text '/exit' --enter --json >/dev/null 2>&1 || true
elif harness_pid_alive "$INCUMBENT_PID"; then
  log "chair-flip: no terminal known for incumbent pid $INCUMBENT_PID (status: $STATUS); no /exit, waiting ${EXIT_WAIT_SECS}s then SIGTERM"
fi

waited=0
while [ "$DRY_RUN" != 1 ] && [ "$waited" -lt "$EXIT_WAIT_SECS" ] && harness_pid_alive "$INCUMBENT_PID"; do
  "$SLEEP_CMD" 2
  waited=$((waited + 2))
done

if [ "$DRY_RUN" != 1 ] && harness_pid_alive "$INCUMBENT_PID"; then
  log "chair-flip: incumbent pid $INCUMBENT_PID still alive after ${EXIT_WAIT_SECS}s; SIGTERM"
  run kill -TERM "$INCUMBENT_PID" >/dev/null 2>&1 || true
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
    if [ "$V_CHAIR" = "$FROM" ] || [ "$V_CHAIR" = none ]; then
      "$SLEEP_CMD" 5
      waited=$((waited + 5))
      continue
    fi
    BEAT=$STATE_DIR/.last-watcher-beat
    if [ -f "$BEAT" ]; then
      AGE=$(( $(date +%s) - $(stat -f %m "$BEAT" 2>/dev/null || stat -c %Y "$BEAT" 2>/dev/null || echo 0) ))
    else
      AGE=999999
    fi
    if [ "$AGE" -lt "$BEAT_MAX_SECS" ]; then
      ok=1
      break
    fi
    "$SLEEP_CMD" 5
    waited=$((waited + 5))
  done
  if [ "$ok" != 1 ]; then
    log "chair-flip: verification failed after ${VERIFY_SECS}s: chair=$(extract_field "$(chair_line)" chair) beat_age=${AGE:-unknown}s (want chair!=none and beat<${BEAT_MAX_SECS}s)"
    exit 1
  fi
fi

log "chair-flip: flipped $FROM -> $TO source=$SOURCE"
exit 0