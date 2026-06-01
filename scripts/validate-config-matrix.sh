#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────
# validate-config-matrix.sh
#
# Pin the workload-driven model + thinking matrix invariants
# established in PR #220 so they cannot silently regress.
#
# Each check encodes a rule that, if broken, has historically
# caused a production incident:
#
#   - Agent missing thinkingDefault, or thinkingDefault == "off":
#     2026-04-28 ops batch ran a bash for-loop with thinkingLevel
#     "off" → BORDERLINE-flag for every credit ID, zero browser
#     calls.
#
#   - Claude 4.x model declared reasoning:false in the project
#     registry while upstream pi-ai catalog says reasoning:true:
#     resolveThinkingDefaultForModel returns "off" for any agent
#     without an explicit thinkingDefault → re-creates the 04-28
#     incident shape.
#
#   - agents.defaults.thinkingDefault unset on a profile:
#     a future agent added without per-agent thinkingDefault
#     inherits runtime "off" → same as above.
#
# Usage:  validate-config-matrix.sh [config.json ...]
#         (no args → checks openclaw-main.json, openclaw-edge.json,
#          cron-jobs.json from CWD)
# Exit:   0 clean, 1 invariant violated, 2 arg/dependency error
# ──────────────────────────────────────────────────────────────
set -euo pipefail

if ! command -v jq >/dev/null 2>&1; then
  echo "validate-config-matrix: jq is required but not on PATH" >&2
  exit 2
fi

PROFILES=()
CRON=""
if (( $# == 0 )); then
  PROFILES=(openclaw-main.json openclaw-edge.json)
  CRON="cron-jobs.json"
else
  for f in "$@"; do
    case "$f" in
      *cron-jobs.json) CRON="$f" ;;
      *openclaw-*.json) PROFILES+=("$f") ;;
      *)
        echo "validate-config-matrix: unrecognised file (expected openclaw-*.json or cron-jobs.json): $f" >&2
        exit 2 ;;
    esac
  done
fi

# Allowed thinking enum (must match openclaw schema's ThinkLevel).
ALLOWED_LEVELS='["off","minimal","low","medium","high","xhigh","adaptive"]'
# Stricter set for thinkingDefault on agents — never silently "off".
AGENT_THINKING_LEVELS='["minimal","low","medium","high","xhigh","adaptive"]'

fail=0
for cfg in "${PROFILES[@]}"; do
  if [[ ! -f "$cfg" ]]; then
    echo "validate-config-matrix: skip (not found): $cfg" >&2
    continue
  fi
  if ! jq empty "$cfg" >/dev/null 2>&1; then
    echo "ERROR: $cfg is not valid JSON" >&2
    fail=1
    continue
  fi

  # 1. Every agent in agents.list[] has thinkingDefault, none "off".
  bad=$(jq -r --argjson allowed "$AGENT_THINKING_LEVELS" '
    .agents.list // []
    | .[]
    | (.thinkingDefault // "MISSING") as $t
    | select(($allowed | index($t)) == null)
    | .id + " (thinkingDefault=" + ($t | tostring) + ")"
  ' "$cfg")
  if [[ -n "$bad" ]]; then
    while IFS= read -r line; do
      echo "ERROR: $cfg agent missing/invalid thinkingDefault: $line" >&2
    done <<< "$bad"
    fail=1
  fi

  # 2. agents.defaults.thinkingDefault must be set (not "off").
  defv=$(jq -r '.agents.defaults.thinkingDefault // "MISSING"' "$cfg")
  if [[ "$defv" == "MISSING" || "$defv" == "off" ]]; then
    echo "ERROR: $cfg agents.defaults.thinkingDefault must be set (was: $defv) — prevents silent runtime fallback to off for any future agent without an explicit thinkingDefault" >&2
    fail=1
  fi
  if ! jq -en --argjson allowed "$ALLOWED_LEVELS" --arg v "$defv" \
       '$allowed | index($v) != null' >/dev/null 2>&1; then
    echo "ERROR: $cfg agents.defaults.thinkingDefault not in allowed set: $defv" >&2
    fail=1
  fi

  # 3. Claude 4.x models with reasoning declared must have reasoning=true.
  #    (Upstream pi-ai catalog declares true; project must agree to keep
  #    resolveThinkingDefaultForModel from returning "off".)
  #    Models live under the openrouter provider as anthropic/claude-* now.
  bad=$(jq -r '
    .models.providers.openrouter.models // []
    | .[]
    | select(
        ((.id // "") | test("^anthropic/claude-(opus|sonnet|haiku|4\\.[567])"))
        and (.reasoning != true)
      )
    | "  - " + (.id // "<no-id>") + " (reasoning=" + ((.reasoning // "missing") | tostring) + ")"
  ' "$cfg")
  if [[ -n "$bad" ]]; then
    echo "ERROR: $cfg has Claude 4.x models with reasoning != true (must match upstream pi-ai catalog):" >&2
    echo "$bad" >&2
    fail=1
  fi
done

# 4. Cron payload thinking values must be in the allowed enum.
if [[ -n "$CRON" && -f "$CRON" ]]; then
  if ! jq empty "$CRON" >/dev/null 2>&1; then
    echo "ERROR: $CRON is not valid JSON" >&2
    fail=1
  else
    bad=$(jq -r --argjson allowed "$ALLOWED_LEVELS" '
      .jobs // []
      | .[]
      | .payload.thinking as $t
      | select($t != null and ($allowed | index($t)) == null)
      | .name + " (thinking=" + ($t | tostring) + ")"
    ' "$CRON")
    if [[ -n "$bad" ]]; then
      while IFS= read -r line; do
        echo "ERROR: $CRON cron job has invalid thinking value: $line" >&2
      done <<< "$bad"
      fail=1
    fi

    # 5. Every cron payload must run on codex (openai/gpt-5.5) with the full
    #    intended fallback chain: gemini-3.5-flash first, then claude-sonnet as
    #    the last-resort backstop. Pins the 2026-06 cutover that moved all crons
    #    off Opus/Haiku onto codex+gemini→sonnet: a future cron with any other
    #    primary silently re-introduces OpenRouter Opus spend, a non-gemini
    #    first fallback drops the intended cheap fallback hop, and dropping the
    #    sonnet second fallback removes the quality backstop the money-touching
    #    crons (credit-verification, dispute-handler) rely on — all while still
    #    passing CI if we only checked the primary + first fallback.
    REQUIRED_CRON_MODEL="openai/gpt-5.5"
    REQUIRED_CRON_FALLBACK1="openrouter/google/gemini-3.5-flash"
    REQUIRED_CRON_FALLBACK2="openrouter/anthropic/claude-4.6-sonnet-20260217"
    bad=$(jq -r --arg m "$REQUIRED_CRON_MODEL" --arg fb1 "$REQUIRED_CRON_FALLBACK1" --arg fb2 "$REQUIRED_CRON_FALLBACK2" '
      .jobs // []
      | .[]
      | (.payload.model // "MISSING") as $model
      | (.payload.fallbacks[0] // "MISSING") as $f1
      | (.payload.fallbacks[1] // "MISSING") as $f2
      | select($model != $m or $f1 != $fb1 or $f2 != $fb2)
      | .name + " (model=" + ($model | tostring) + ", fallbacks=[" + ($f1 | tostring) + ", " + ($f2 | tostring) + "])"
    ' "$CRON")
    if [[ -n "$bad" ]]; then
      while IFS= read -r line; do
        echo "ERROR: $CRON cron job must be on $REQUIRED_CRON_MODEL with fallbacks [$REQUIRED_CRON_FALLBACK1, $REQUIRED_CRON_FALLBACK2] (gemini-flash first, sonnet backstop): $line" >&2
      done <<< "$bad"
      fail=1
    fi
  fi
fi

if (( fail == 0 )); then
  echo "validate-config-matrix: all checks passed"
fi
exit $fail
