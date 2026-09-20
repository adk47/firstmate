#!/usr/bin/env bash
# fm-chair-status.sh - who currently sits in the firstmate chair, and where.
#
# Usage:
#   fm-chair-status.sh [--json]
#
# Prints one line and exits 0 always (this is a sensor):
#
#   chair=<grok|pi-fable|claude|none> terminal=<handle|none> pid=<n|none> tty=<t|none> reason=<token>
#
# `chair` is read from state/.lock: a live harness pid whose command line is
# `grok ...` is `grok`, `pi ...` is `pi-fable`, `claude ...` is `claude`.
# A missing lock, a dead pid, or a pid that is not a harness is `none`.
#
# `terminal` is the Orca terminal that hosts that chair. Orca exposes no
# pid/tty field, so the match is structural and deliberately conservative: an
# Orca terminal in this home's worktree, connected, whose `agentIdentity` equals
# the lock harness, and whose title contains `firstmate` - the title convention
# `bin/fm-chair-flip.sh` writes when it launches a chair. Zero matches or more
# than one both yield `none` rather than a guess, so the actuator fails closed
# instead of typing into the wrong terminal.
#
# A Pi chair whose footer reads its context as fully consumed counts as `none`:
# a chair with no context left cannot take the helm.
#
# Read-only: never writes state, never sends input.
#
# Test seams:
#   FM_CHAIR_STATUS_LOCK         lock file path (default <home>/state/.lock)
#   FM_CHAIR_STATUS_PS_CMD       override the command-line reader (echoes the cmdline for a pid)
#   FM_CHAIR_STATUS_ORCA_CMD     override the Orca terminal enumerator (echoes JSON)
#   FM_CHAIR_STATUS_TERMINAL     pin the terminal handle (skips enumeration)
set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
HOME_DIR=${FM_CHAIR_HOME_DIR:-$FM_HOME}
LOCK_FILE=${FM_CHAIR_STATUS_LOCK:-$FM_HOME/state/.lock}

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "${BASH_SOURCE[0]}"
  exit 2
}

JSON=0
for arg in "$@"; do
  case "$arg" in
    --json) JSON=1 ;;
    -h|--help|help) usage ;;
    *) usage ;;
  esac
done

pid_alive() {
  [ -n "${1:-}" ] && kill -0 "$1" 2>/dev/null
}

read_cmdline() {  # <pid>
  if [ -n "${FM_CHAIR_STATUS_PS_CMD:-}" ]; then
    "$FM_CHAIR_STATUS_PS_CMD" "$1" 2>/dev/null
  else
    ps -o command= -p "$1" 2>/dev/null
  fi
}

classify_harness() {  # <cmdline>
  # The harness is argv[0], not any substring of the arguments: a `pi` chair
  # launched with `--model token-pool/claude-fable-5-1` must classify as
  # pi-fable, and a bare shell is never a chair.
  local first=${1%% *}
  first=${first##*/}
  case "$first" in
    grok*) printf 'grok\n' ;;
    claude*) printf 'claude\n' ;;
    pi) printf 'pi-fable\n' ;;
    *) printf 'none\n' ;;
  esac
}

PID=none
CHAIR=none
TTY=none
REASON=no_lock
if [ -f "$LOCK_FILE" ] && [ ! -L "$LOCK_FILE" ]; then
  LOCK_PID=$(cat -- "$LOCK_FILE" 2>/dev/null) || LOCK_PID=''
  case "$LOCK_PID" in
    ''|*[!0-9]*) REASON=unreadable_lock ;;
    *)
      if pid_alive "$LOCK_PID"; then
        CMD=$(read_cmdline "$LOCK_PID") || CMD=''
        H=$(classify_harness "$CMD")
        if [ "$H" = none ]; then
          REASON=holder_not_harness
        else
          PID=$LOCK_PID
          CHAIR=$H
          REASON=live_harness
          if [ -n "${FM_CHAIR_STATUS_TTY_CMD:-}" ]; then
            TTY=$("$FM_CHAIR_STATUS_TTY_CMD" "$LOCK_PID" 2>/dev/null) || TTY=none
          else
            TTY=$(ps -o tty= -p "$LOCK_PID" 2>/dev/null | tr -d ' ') || TTY=none
          fi
          [ -n "$TTY" ] || TTY=none
        fi
      else
        REASON=stale_lock
      fi
      ;;
  esac
else
  REASON=no_lock
fi

# --- Orca terminal ----------------------------------------------------------

enumerate_orca_terminals() {
  if [ -n "${FM_CHAIR_STATUS_ORCA_CMD:-}" ]; then
    "$FM_CHAIR_STATUS_ORCA_CMD" 2>/dev/null
  else
    orca terminal list --json 2>/dev/null
  fi
}

TERMINAL=none
FULL=0
if [ "$CHAIR" != none ]; then
  if [ -n "${FM_CHAIR_STATUS_TERMINAL:-}" ]; then
    TERMINAL=$FM_CHAIR_STATUS_TERMINAL
  else
    TERMS_JSON=$(enumerate_orca_terminals) || TERMS_JSON=''
    if [ -n "$TERMS_JSON" ] && printf '%s' "$TERMS_JSON" | jq -e 'type == "object"' >/dev/null 2>&1; then
      MATCHES=$(printf '%s' "$TERMS_JSON" | jq -r \
        --arg path "$HOME_DIR" --arg harness "$CHAIR" \
        '[.result.terminals[]? | select(.worktreePath == $path) | select(.connected == true)
          | select((.agentIdentity // "") == (if $harness == "pi-fable" then "pi" else $harness end))
          | select((.title // "") | ascii_downcase | contains("firstmate"))]
         | .[] | [.handle, .preview] | @tsv' 2>/dev/null) || MATCHES=''
      COUNT=$(printf '%s\n' "$MATCHES" | grep -c . 2>/dev/null || true)
      case "$COUNT" in
        1)
          TERMINAL=$(printf '%s\n' "$MATCHES" | cut -f1)
          PREVIEW=$(printf '%s\n' "$MATCHES" | cut -f2-)
          # A Pi footer that reads its context as fully consumed means no chair.
          if [ "$CHAIR" = pi-fable ] && printf '%s' "$PREVIEW" \
            | grep -Eq '100%[[:space:]]*context|context[^0-9]{0,6}100%'; then
            FULL=1
            REASON=context_full
          fi
          ;;
        0) TERMINAL=none; [ "$REASON" = live_harness ] && REASON=no_terminal_match ;;
        *) TERMINAL=none; REASON=ambiguous_terminal ;;
      esac
    else
      TERMINAL=none
      [ "$REASON" = live_harness ] && REASON=orca_unavailable
    fi
  fi
fi

if [ "$FULL" = 1 ]; then
  CHAIR=none
fi

if [ "$JSON" = 1 ]; then
  jq -cn --arg chair "$CHAIR" --arg terminal "$TERMINAL" --arg pid "$PID" \
    --arg tty "$TTY" --arg reason "$REASON" \
    '{chair:$chair,terminal:$terminal,pid:$pid,tty:$tty,reason:$reason}'
else
  printf 'chair-status: chair=%s terminal=%s pid=%s tty=%s reason=%s\n' \
    "$CHAIR" "$TERMINAL" "$PID" "$TTY" "$REASON"
fi
exit 0