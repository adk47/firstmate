#!/usr/bin/env bash
# Claude StopFailure detector for a transient inference-gateway stall.
#
# Registered as a StopFailure command hook in two places, both anchored to
# absolute paths so the hook never depends on the process working directory:
#
#   - every claude crewmate and scout, in the task worktree's
#     .claude/settings.local.json written by bin/fm-spawn.sh, with --task;
#   - the primary firstmate session, in the tracked .claude/settings.json,
#     with --primary.
#
# WHAT IT DOES. Claude Code ends an API-error turn through StopFailure, which
# carries a typed `error` kind and the rendered `last_assistant_message`. When
# those name the transient gateway class (bin/fm-gateway-retry-lib.sh owns that
# decision), this records a durable stall so the actor that CAN re-ring the
# agent - the watcher for a task, the keep-alive agent for the primary - finds
# it immediately instead of waiting to infer the same thing from a rendered
# pane. Any other turn failure clears the record, because the session provably
# reached a different outcome and the previous stall is over.
#
# WHAT IT DELIBERATELY DOES NOT DO. It does not block, continue, or resume the
# turn, and it never exits 2. Claude Code executes StopFailure hooks OUTSIDE the
# REPL loop and discards their result, so a StopFailure hook has no continuation
# channel at all - unlike the Stop hooks that bin/fm-turnend-guard.sh and
# bin/fm-claude-stop-autoarm.sh use. Verified live on 2.1.266; the evidence and
# the exact payload are in docs/verification/gateway-keepalive.md. It also never
# sleeps: the backoff belongs to the re-ring ladder, and a hook that slept would
# hold the harness's own failure path open for the length of that wait.
#
# It is silent on every path and always exits 0. Unreadable input, a missing
# jq, an unrecognised payload, or an unwritable state directory all leave the
# stall to be detected from the pane instead, which is the whole reason that
# second detector exists.
#
# Usage: fm-gateway-stall-hook.sh --task <id> --state <dir>
#        fm-gateway-stall-hook.sh --primary
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"

# shellcheck source=bin/fm-gateway-retry-lib.sh
. "$SCRIPT_DIR/fm-gateway-retry-lib.sh"
# shellcheck source=bin/fm-hook-host-lib.sh
. "$SCRIPT_DIR/fm-hook-host-lib.sh"

SCOPE=''
STATE_DIR=''
IS_PRIMARY=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --task) SCOPE=${2:-}; shift 2 || exit 0 ;;
    --state) STATE_DIR=${2:-}; shift 2 || exit 0 ;;
    --primary) IS_PRIMARY=1; SCOPE=$FM_GATEWAY_PRIMARY_SCOPE; shift ;;
    *) shift ;;
  esac
done

[ -n "$SCOPE" ] || exit 0

if [ -z "$STATE_DIR" ]; then
  FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
  STATE_DIR="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
fi
[ -d "$STATE_DIR" ] || exit 0

PAYLOAD=$(cat 2>/dev/null || true)
[ -n "$PAYLOAD" ] || exit 0

# Cursor and Grok load the tracked Claude settings too. Neither has a StopFailure
# event of its own, but standing down on a foreign host keeps this entry
# consistent with every other tracked Claude-shaped hook (docs/turnend-guard.md
# "Harness integrations") and stops a future build from delivering a payload this
# classifier would read with Claude's field names.
fm_hook_payload_is_foreign_host "$PAYLOAD" && exit 0
[ -z "${GROK_AGENT:-}${GROK_HOOK_EVENT:-}" ] || exit 0

command -v jq >/dev/null 2>&1 || exit 0

EVENT=$(printf '%s' "$PAYLOAD" | jq -r '.hook_event_name // empty' 2>/dev/null) || exit 0
[ "$EVENT" = StopFailure ] || exit 0

KIND=$(printf '%s' "$PAYLOAD" | jq -r '.error // empty' 2>/dev/null) || KIND=''
TEXT=$(printf '%s' "$PAYLOAD" | jq -r '[.last_assistant_message // empty, .error_details // empty] | join(" ")' 2>/dev/null) || TEXT=''

if fm_gateway_is_transient "$KIND" "$TEXT"; then
  # The primary has no recorded endpoint of its own, and the keep-alive agent
  # runs from launchd with none of the pane environment this hook inherits from
  # the session it belongs to. Refreshing the record here is what keeps that
  # agent pointed at the CURRENT primary pane across a relaunch into a new one.
  if [ "$IS_PRIMARY" -eq 1 ] && [ -x "$SCRIPT_DIR/fm-keepalive-endpoint.sh" ]; then
    "$SCRIPT_DIR/fm-keepalive-endpoint.sh" record --state "$STATE_DIR" >/dev/null 2>&1 || true
  fi
  fm_gateway_note_stall "$STATE_DIR" "$SCOPE" "${KIND:-unknown}" >/dev/null 2>&1 || true
  exit 0
fi

# A turn that failed for any other reason is proof this session is past the
# stall the record described, so the accumulated budget must not carry over into
# an unrelated later one.
fm_gateway_clear "$STATE_DIR" "$SCOPE"
exit 0
