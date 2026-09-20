#!/usr/bin/env bash
# fm-chair-status.sh - who currently sits in the firstmate chair, and where.
#
# Usage:
#   fm-chair-status.sh
#
# Prints one line and exits 0 always (this is a sensor):
#
#   chair=<pi-fable|grok|claude|codex|opencode|kimi|cursor|none> harness=<pi|grok|claude|...|none> source=<8317|8080|none> terminal=<handle|none> pid=<n|none> reason=<token>
#
# `harness` is read from state/.lock: the verified harness holding the lock as
# a live pid, decided by the fleet's single owner of that question,
# bin/fm-session-lock-lib.sh (fm_harness_process_matches), so every harness
# bin/fm-lock.sh would honour is recognised here. Its name comes from the same
# structural evidence the owner uses (exact path component, then Cursor's own
# identity via bin/fm-cursor-lib.sh); only an interpreter-launched harness
# (node/python running a harness script) is named from its argument text. A
# missing lock, a dead pid, or a pid that is not a harness is `none`.
#
# `chair` is `harness` as the sentinel's decision value: `pi` (and `pi-signed`)
# is `pi-fable`, every other harness is its own name, and a Pi chair with no
# context left is `none` (below) while `harness` and `pid` still name it so the
# actuator can end it gracefully.
#
# `source` is the Fable source a Pi chair is bound to, read from its command
# line: a `token-pool/` model is the 8317 pool, an `anthropic/` model is the
# 8080 better-ccflare gateway (the two providers bin/fm-chair-flip.sh launches
# with). Any other chair, or a Pi on neither provider, is `none`.
#
# `terminal` is the Orca terminal that hosts that chair. Orca exposes no
# pid/tty field, so the match is structural and deliberately conservative: an
# Orca terminal in this home's worktree, connected, whose `agentIdentity` equals
# the lock harness. A chair this repository launches (`pi-fable`, `grok`) must
# also carry `firstmate` in its title - the convention `bin/fm-chair-flip.sh`
# writes; a foreign chair (`claude`, `codex`, ...) was never titled by us, so
# its title is not consulted. Zero matches or more than one both yield `none`
# rather than a guess, so the actuator fails closed instead of typing into the
# wrong terminal.
#
# A Pi chair whose status-bar footer reads its context as fully consumed counts
# as `none`: a chair with no context left cannot take the helm. The footer is
# read from the rendered screen (`orca terminal read --screen`, the only surface
# that carries it). Only the footer token Pi renders, `<NN.N>%/<window>` (e.g.
# `99.2%/1.0M`), is consulted - the last such token on the screen - and 99.0 or
# more is full. Prose that merely mentions "100% context" never counts, and a
# screen with no token is not full.
#
# Read-only: never writes state, never sends input.
#
# Test seams:
#   FM_CHAIR_STATUS_LOCK         lock file path (default <home>/state/.lock)
#   FM_CHAIR_STATUS_PS_CMD       override the process reader (echoes the full
#                                command line for a pid; its first word is taken
#                                as the command name)
#   FM_CHAIR_STATUS_ORCA_CMD     override the Orca CLI; called as
#                                `terminal list --json` and
#                                `terminal read --terminal <h> --screen --json`
set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
HOME_DIR=${FM_CHAIR_HOME_DIR:-$FM_HOME}
LOCK_FILE=${FM_CHAIR_STATUS_LOCK:-$FM_HOME/state/.lock}

# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "${BASH_SOURCE[0]}"
  exit 2
}

[ $# -eq 0 ] || usage

pid_alive() {
  [ -n "${1:-}" ] && kill -0 "$1" 2>/dev/null
}

read_process() {  # <pid> -> sets PROC_COMM PROC_ARGS
  if [ -n "${FM_CHAIR_STATUS_PS_CMD:-}" ]; then
    PROC_ARGS=$("$FM_CHAIR_STATUS_PS_CMD" "$1" 2>/dev/null) || PROC_ARGS=''
    PROC_COMM=${PROC_ARGS%% *}
  else
    PROC_COMM=$(ps -o comm= -p "$1" 2>/dev/null) || PROC_COMM=''
    PROC_ARGS=$(ps -o args= -p "$1" 2>/dev/null) || PROC_ARGS=''
  fi
}

harness_name() {  # <comm> <args> -> the verified harness name, or return 1
  local name
  fm_harness_process_matches "$1" "$2" || return 1
  if [ "$FM_HARNESS_IS_CLAUDE" = 1 ]; then
    name=claude
  else
    if name=$(fm_harness_path_name "$1") || name=$(fm_harness_path_name "${2%% *}"); then
      :
    elif fm_cursor_process_matches "$1" "$2" "${2%% *}"; then
      name=cursor
    else
      name=$(printf '%s %s' "$(basename -- "$1")" "$2" | grep -oE 'codex|opencode|grok|kimi|pi-signed|pi' | head -1)
    fi
  fi
  printf '%s\n' "$name"
}

chair_source() {  # <args> -> the Fable source a pi command line is bound to
  case "$1" in
    *token-pool/*) printf '8317\n' ;;
    *anthropic/*) printf '8080\n' ;;
    *) printf 'none\n' ;;
  esac
}

PID=none
HARNESS=none
CHAIR=none
SOURCE=none
REASON=no_lock
if [ -f "$LOCK_FILE" ] && [ ! -L "$LOCK_FILE" ]; then
  LOCK_PID=$(cat -- "$LOCK_FILE" 2>/dev/null) || LOCK_PID=''
  case "$LOCK_PID" in
    ''|*[!0-9]*) REASON=unreadable_lock ;;
    *)
      if pid_alive "$LOCK_PID"; then
        read_process "$LOCK_PID"
        if H=$(harness_name "$PROC_COMM" "$PROC_ARGS"); then
          PID=$LOCK_PID
          HARNESS=$H
          case "$H" in pi|pi-signed) CHAIR=pi-fable; SOURCE=$(chair_source "$PROC_ARGS") ;; *) CHAIR=$H ;; esac
          REASON=live_harness
        else
          REASON=holder_not_harness
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

orca_cli() {  # <args...>
  "${FM_CHAIR_STATUS_ORCA_CMD:-orca}" "$@" 2>/dev/null
}

context_full() {  # <terminal> -> 0 when the last Pi footer token on screen reads >= 99.0%
  local pct
  pct=$(orca_cli terminal read --terminal "$1" --screen --json \
    | jq -r '.result.terminal.tail[]? // empty' 2>/dev/null \
    | grep -oE '[0-9]+\.[0-9]+%/[0-9.]+[kM]' | tail -n 1 | cut -d% -f1)
  [ -n "$pct" ] || return 1
  awk -v p="$pct" 'BEGIN { exit !(p + 0 >= 99.0) }'
}

TERMINAL=none
if [ "$CHAIR" != none ]; then
  TERMS_JSON=$(orca_cli terminal list --json) || TERMS_JSON=''
  if [ -n "$TERMS_JSON" ] && printf '%s' "$TERMS_JSON" | jq -e 'type == "object"' >/dev/null 2>&1; then
    case "$CHAIR" in pi-fable|grok) OURS=true ;; *) OURS=false ;; esac
    MATCHES=$(printf '%s' "$TERMS_JSON" | jq -r \
      --arg path "$HOME_DIR" --arg harness "$CHAIR" --argjson ours "$OURS" \
      '[.result.terminals[]? | select(.worktreePath == $path) | select(.connected == true)
        | select((.agentIdentity // "") == (if $harness == "pi-fable" then "pi" else $harness end))
        | select(($ours | not) or ((.title // "") | ascii_downcase | contains("firstmate")))]
       | .[].handle' 2>/dev/null) || MATCHES=''
    COUNT=$(printf '%s\n' "$MATCHES" | grep -c . 2>/dev/null || true)
    case "$COUNT" in
      1)
        TERMINAL=$MATCHES
        if [ "$CHAIR" = pi-fable ] && context_full "$TERMINAL"; then
          CHAIR=none
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

printf 'chair-status: chair=%s harness=%s source=%s terminal=%s pid=%s reason=%s\n' \
  "$CHAIR" "$HARNESS" "$SOURCE" "$TERMINAL" "$PID" "$REASON"
exit 0