#!/usr/bin/env bash
# spawn-investigation.sh — observability wrapper around the agent's `agent()` call.
#
# This script does NOT spawn subagents itself (openclaw spawn is an in-agent
# tool call, not a shell command). It runs in TWO phases the agent invokes
# around its own agent() call:
#
#   1. Pre-spawn: writes a `subagent_started` runlog event with the profile +
#      prompt + out_file context. Use to know which spawn intents we have.
#
#   2. Post-spawn (after agent() completion announce): reads the
#      $INVESTIGATION_OUT_FILE the child should have written and emits one of:
#         - subagent_completed_ok            (file exists, valid JSON, has verdict)
#         - subagent_completed_invalid_json  (file exists, JSON parse fails)
#         - subagent_completed_missing_json  (file does not exist)
#         - subagent_completed_invalid_shape (JSON valid but missing verdict / cr_ids)
#
# Why this exists: the 2026-05-01 13:56 dry-run had 0 visibility into why
# subagents failed. We saw 117 prompts built but only 2 spawn calls, and the
# 6 child sessions that did exist were from earlier runs. With these events,
# the runlog directly answers: how many spawned, how many returned valid
# JSON, how many returned nothing.
#
# Usage:
#   spawn-investigation.sh started --run-id <id> --profile-id <pid> --prompt-path <path> --out-file <path>
#   spawn-investigation.sh completed --run-id <id> --profile-id <pid> --out-file <path>
#
# Exit codes:
#   0 = event written
#   2 = invalid args / env
#   3 = (completed only) child JSON missing / invalid (event still written)

set -euo pipefail

PHASE=""
RUN_ID=""
PROFILE_ID=""
PROMPT_PATH=""
OUT_FILE=""
SKILL_DIR_DEFAULT="$(cd "$(dirname "$0")/.." && pwd)"
SKILL_DIR="${SKILL_DIR:-$SKILL_DIR_DEFAULT}"

if [[ $# -lt 1 ]]; then
  echo "ERROR: phase required (started|completed)" >&2
  exit 2
fi

PHASE="$1"; shift

while [[ $# -gt 0 ]]; do
  case "$1" in
    --run-id)      RUN_ID="$2"; shift 2 ;;
    --profile-id)  PROFILE_ID="$2"; shift 2 ;;
    --prompt-path) PROMPT_PATH="$2"; shift 2 ;;
    --out-file)    OUT_FILE="$2"; shift 2 ;;
    *) echo "ERROR: unknown arg: $1" >&2; exit 2 ;;
  esac
done

[[ -n "$RUN_ID"     ]] || { echo "ERROR: --run-id required"     >&2; exit 2; }
[[ -n "$PROFILE_ID" ]] || { echo "ERROR: --profile-id required" >&2; exit 2; }
[[ -n "${OPS_RUNLOG_DIR:-}" ]] || { echo "ERROR: OPS_RUNLOG_DIR not set" >&2; exit 2; }

RUNLOG="$SKILL_DIR/scripts/runlog.sh"
[[ -x "$RUNLOG" ]] || RUNLOG="$(dirname "$0")/runlog.sh"

case "$PHASE" in
  started)
    [[ -n "$PROMPT_PATH" ]] || { echo "ERROR: --prompt-path required for started" >&2; exit 2; }
    [[ -n "$OUT_FILE"    ]] || { echo "ERROR: --out-file required for started" >&2; exit 2; }
    payload=$(jq -n -c \
      --arg pid "$PROFILE_ID" \
      --arg pp  "$PROMPT_PATH" \
      --arg of  "$OUT_FILE" \
      '{profile_id:$pid, prompt_path:$pp, out_file:$of}')
    bash "$RUNLOG" event "$RUN_ID" subagent_started "$payload"
    ;;

  completed)
    [[ -n "$OUT_FILE" ]] || { echo "ERROR: --out-file required for completed" >&2; exit 2; }
    state="ok"
    detail=""
    if [[ ! -f "$OUT_FILE" ]]; then
      state="missing_json"
      detail="file not found at $OUT_FILE"
    elif ! jq empty "$OUT_FILE" >/dev/null 2>&1; then
      state="invalid_json"
      detail="jq parse failed"
    else
      verdict=$(jq -r '.verdict // empty' "$OUT_FILE" 2>/dev/null)
      if [[ -z "$verdict" ]]; then
        state="invalid_shape"
        detail="JSON parsed but no .verdict field"
      fi
    fi

    event_name="subagent_completed_${state}"
    payload=$(jq -n -c \
      --arg pid "$PROFILE_ID" \
      --arg of  "$OUT_FILE" \
      --arg st  "$state" \
      --arg dt  "$detail" \
      --arg vd  "${verdict:-}" \
      --argjson sz "$([[ -f "$OUT_FILE" ]] && wc -c < "$OUT_FILE" || echo 0)" \
      '{profile_id:$pid, out_file:$of, state:$st, detail:$dt, verdict:$vd, file_size:$sz}')
    # Disable the runlog gate just for these meta-events — they describe
    # the spawn outcome, not a per-credit decision; they don't claim
    # browser evidence either way.
    CV_DISABLE_VERDICT_GATE=1 bash "$RUNLOG" event "$RUN_ID" "$event_name" "$payload"

    case "$state" in
      ok)            exit 0 ;;
      invalid_shape) exit 3 ;;
      invalid_json)  exit 3 ;;
      missing_json)  exit 3 ;;
    esac
    ;;

  *)
    echo "ERROR: unknown phase: $PHASE (expected started|completed)" >&2
    exit 2
    ;;
esac
