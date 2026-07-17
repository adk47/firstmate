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
# ${PROFILES[@]+...} guard: PROFILES may be empty (e.g. cron-jobs.json passed
# alone) and bash 3.2 errors on "${empty[@]}" under `set -u`.
for cfg in ${PROFILES[@]+"${PROFILES[@]}"}; do
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

  # 6. Empty-completion fallback safety: in every agent model.fallbacks chain,
  #    every entry EXCEPT the last must be a GPT-5-family model. openclaw only
  #    treats an empty/0-token completion as a failure-that-cascades for GPT-5
  #    models (isGpt5ModelId gate in result-fallback-classifier); a non-GPT-5
  #    model in a non-final position that returns an empty completion is scored
  #    candidate_succeeded and silently STOPS the chain instead of advancing to
  #    the stronger model behind it (2026-06-08 @CMO incident, PR #450).
  #    GPT-5 id pattern matches openclaw's: (^|[/:])gpt-5([.-]|$), so
  #    openrouter/openai/gpt-5.4-mini and openai/gpt-5.5 qualify; gemini / haiku
  #    / sonnet / opus do not. Scope: agent text `model` chains only — NOT
  #    imageModel (separate path; gpt-5.4-mini is not an image model). A non-GPT-5
  #    *primary* (e.g. cmo on opus-4.7 by choice) keeps an unavoidable
  #    empty-swallow residual that the cron-health watchdog covers; this gate
  #    enforces only the fallback positions.
  bad=$(jq -r '
    ( [ {id: "agents.defaults", fb: (.agents.defaults.model.fallbacks // [])} ]
      + [ (.agents.list // [])[] | {id: .id, fb: (.model.fallbacks // [])} ] )
    | .[]
    | .id as $id | .fb as $fb | ($fb | length) as $n
    | select($n > 1)
    | range(0; $n - 1) as $i
    | $fb[$i] as $m
    | select(($m | test("(^|[/:])gpt-5([.-]|$)"; "i")) | not)
    | $id + " fallback[" + ($i | tostring) + "]=" + $m
  ' "$cfg")
  if [[ -n "$bad" ]]; then
    while IFS= read -r line; do
      echo "ERROR: $cfg non-GPT-5 model in a non-final fallback position (empty completions will NOT cascade — openclaw isGpt5ModelId gate): $line" >&2
    done <<< "$bad"
    fail=1
  fi

  # 7. web_search must have a well-formed backend that does not self-disable. On
  #    openclaw 7.1, native codex search (tools.web.search.openaiCodex.enabled — the
  #    codex model calling OpenAI's own search in-thread, key-free via the ChatGPT
  #    OAuth the fleet already runs) and a MANAGED provider (tools.web.search.provider)
  #    are MUTUALLY EXCLUSIVE: setting a provider flips every codex thread OFF native
  #    onto a bounded managed worker. In hydra that worker has no auth (empty
  #    CODEX_HOME, placeholder OPENAI_API_KEY) so it fails "Reconnecting..." — setting
  #    provider:"codex" on this native-search fleet DISABLED web_search fleet-wide
  #    (incident 2026-07-17, PR #695). So the invariants are:
  #      - reject BOTH openaiCodex.enabled and provider set at once (self-disabling);
  #      - reject enabled-with-no-backend (neither native nor a provider);
  #      - native-only (openaiCodex.enabled, NO provider) is the SUPPORTED shape → ok;
  #      - a managed provider (native off) must be a recognized id ($KNOWN, since a
  #        static check can't read the live plugin registry — catches typos like
  #        "codxe" that resolve zero candidates), allowlisted, not entry-disabled,
  #        and — unless it is the key-free "codex" — carry a plugins.entries block +
  #        apiKey.
  #    Extend $KNOWN when adopting a new provider. NOTE: this deliberately leaves the
  #    #607 gap open — a non-codex fallback turn has no search — which is the accepted
  #    status quo until upstream fixes the managed bounded-turn auth path.
  ws_err=$(jq -r '
    if (.tools.web.search.enabled // false) != true then empty
    else
      (.tools.web.search.provider // "") as $p
      | ((.tools.web.search.openaiCodex.enabled // false) == true) as $native
      | (.plugins.allow // []) as $allow
      | (.plugins.entries // {}) as $entries
      | (["codex","perplexity"]) as $known
      | if   $native and $p != ""         then "tools.web.search sets BOTH openaiCodex.enabled and provider:\"" + $p + "\" — mutually exclusive on openclaw 7.1: a managed provider DISABLES native in-thread codex search (incident 2026-07-17, #695). Use native (drop provider) OR managed (drop openaiCodex.enabled), not both."
        elif (($native | not) and $p == "") then "tools.web.search.enabled but has no backend — set openaiCodex.enabled:true (native, key-free codex OAuth) or a managed provider"
        elif $p == ""                     then empty
        elif ($known | index($p)) == null then "provider \"" + $p + "\" is not a recognized web-search provider id (known: " + ($known | join(", ")) + ") — a typo or invented id resolves zero candidates at runtime"
        elif ($allow | index($p)) == null then "provider \"" + $p + "\" is not in plugins.allow (closed allowlist)"
        elif $entries[$p].enabled == false then "provider \"" + $p + "\" entry is disabled (plugins.entries[\"" + $p + "\"].enabled=false — the plugin will not register)"
        elif $p == "codex"                then empty
        elif $entries[$p] == null         then "provider \"" + $p + "\" has no plugins.entries[\"" + $p + "\"] block"
        elif ($entries[$p].config.webSearch.apiKey // $entries[$p].config.apiKey // .tools.web.search.apiKey // null) == null then "provider \"" + $p + "\" has no apiKey credential (config.webSearch.apiKey / config.apiKey / tools.web.search.apiKey all absent)"
        else empty end
    end
  ' "$cfg")
  if [[ -n "$ws_err" ]]; then
    echo "ERROR: $cfg web_search misconfigured: $ws_err" >&2
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

    # 5. Every cron payload must run on codex (openai/gpt-5.6-sol) with the full
    #    intended fallback chain: gpt-5.6-luna first (GPT-5-family hop — same
    #    brain via the OpenRouter api-key route when codex OAuth is down), then
    #    claude-haiku as the last-resort non-OpenAI backstop. Pins the 2026-06
    #    cutover that moved all crons off Opus/Haiku onto codex, plus the
    #    2026-06-08 fix that swapped the cheap first hop gemini-3.5-flash →
    #    gpt-5-family (then mini, now luna).
    #    Rationale for the swap: openclaw only treats an empty/0-token completion
    #    as a failure-that-cascades for GPT-5-family models (isGpt5ModelId gate
    #    in result-fallback-classifier). A non-GPT-5 first hop (gemini) that
    #    returns an empty completion counts as candidate_succeeded and STOPS the
    #    chain — never reaching the sonnet backstop (the 2026-06-08 @CMO incident,
    #    PR #450). gpt-5.6-luna is GPT-5-family so its empties cascade.
    #    A future cron with any other primary silently re-introduces OpenRouter
    #    Opus spend, a non-GPT-5 first fallback re-introduces the swallow bug,
    #    and dropping the haiku second fallback removes the non-OpenAI backstop
    #    the money-touching crons rely on when OpenAI is down entirely.
    REQUIRED_CRON_MODEL="openai/gpt-5.6-sol"
    REQUIRED_CRON_FALLBACK1="openrouter/openai/gpt-5.6-luna"
    REQUIRED_CRON_FALLBACK2="openrouter/anthropic/claude-haiku-4.5"
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
        echo "ERROR: $CRON cron job must be on $REQUIRED_CRON_MODEL with fallbacks [$REQUIRED_CRON_FALLBACK1, $REQUIRED_CRON_FALLBACK2] (gpt-5.6-luna GPT-5 hop first, haiku backstop): $line" >&2
      done <<< "$bad"
      fail=1
    fi
  fi
fi

if (( fail == 0 )); then
  echo "validate-config-matrix: all checks passed"
fi
exit $fail
