#!/usr/bin/env bash
# deep-research.sh — run a cited research query through a Perplexity reasoning /
# deep-research model over OpenRouter and return a markdown report with sources.
#
# Backend for the muso-deep-research skill (Scout agent). Perplexity Sonar models
# do NOT support tool/function calling, so they can't be an agent's brain — but
# they're the strongest search-grounded research engines, so we expose them here
# as a callable TOOL the agent invokes and then verifies/frames.
#
# Tiers (pick at most one):
#   default       perplexity/sonar-reasoning-pro — chain-of-thought over live
#                 search; fast + cheap (~$2/$8 per 1M). The right default for
#                 most "deep" asks.
#   --deepsearch  perplexity/sonar-deep-research, falling back to
#   (=--exhaustive) openai/o4-mini-deep-research — runs many searches and writes a
#                 comprehensive report; slow + pricey. (Sonar deep research is the
#                 more accurate + cheaper of the two, so it goes first.) Reserve
#                 for big landscape / competitor-teardown asks.
#   --x           x-ai/grok-4.3 with OpenRouter native web+X search scoped to
#                 x.com (fallback x-ai/grok-4.1-fast) — real-time X posts / sentiment.
#
# Usage:
#   deep-research.sh [options] "your research question"
#   echo "your research question" | deep-research.sh [options]
#
# Options:
#   --deepsearch             deep-research tier: perplexity/sonar-deep-research,
#                            fallback openai/o4-mini-deep-research (alias: --exhaustive)
#   --x                      search x.com via x-ai/grok-4.3 (OpenRouter native X search)
#   --model <id>             override the OpenRouter model (default: perplexity/sonar-reasoning-pro)
#   --fallback <id>          fallback model on primary failure (default: perplexity/sonar-pro)
#   --reasoning-effort <e>   low|medium|high (default: medium)
#   --max-time <seconds>     curl timeout (default: 600)
#   --json                   print the raw OpenRouter JSON response instead of a report
#   -h, --help               print this help and exit 0
#
# Secrets:
#   OPENROUTER_API_KEY in the environment, OR readable from the hydra-secrets
#   store ($HYDRA_SECRETS_FILE, default /opt/hydra/secrets/llm-provider-keys.json,
#   top-level key OPENROUTER_API_KEY). Fails loud if neither is available.
#
# Exit codes:
#   0  success
#   2  usage error (no question)
#   3  missing OPENROUTER_API_KEY
#   4  both primary and fallback model calls failed / empty completion

set -euo pipefail

OPENROUTER_BASE="${OPENROUTER_BASE:-https://openrouter.ai/api/v1}"
MODEL="perplexity/sonar-reasoning-pro"
FALLBACK="perplexity/sonar-pro"
REASONING_EFFORT="medium"
MAX_TIME="600"
RAW_JSON=0
EXHAUSTIVE=0
X_MODE=0
MODEL_SET=0
FALLBACK_SET=0

# Print the leading comment block (line 2 until the first non-comment line) as
# help — robust to header length changes.
usage() {
  awk 'NR==1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
}

# --- arg parse -------------------------------------------------------------
QUESTION=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --exhaustive|--deepsearch) EXHAUSTIVE=1; shift ;;
    --x) X_MODE=1; shift ;;
    --model) MODEL="${2:?--model needs a value}"; MODEL_SET=1; shift 2 ;;
    --fallback) FALLBACK="${2:?--fallback needs a value}"; FALLBACK_SET=1; shift 2 ;;
    --reasoning-effort) REASONING_EFFORT="${2:?--reasoning-effort needs a value}"; shift 2 ;;
    --max-time) MAX_TIME="${2:?--max-time needs a value}"; shift 2 ;;
    --json) RAW_JSON=1; shift ;;
    --) shift; QUESTION="${QUESTION}${QUESTION:+ }$*"; break ;;
    -*) echo "ERROR: unknown option: $1" >&2; exit 2 ;;
    *) QUESTION="${QUESTION}${QUESTION:+ }$1"; shift ;;
  esac
done

# --x (Grok X-search) and --deepsearch/--exhaustive (Perplexity deep research) are
# different engines — refuse to combine them rather than silently picking one.
if [[ "$X_MODE" -eq 1 && "$EXHAUSTIVE" -eq 1 ]]; then
  echo "ERROR: --x and --deepsearch/--exhaustive are mutually exclusive." >&2
  exit 2
fi

# Each tier sets the model + fallback, but an explicit --model/--fallback always
# wins (regardless of flag order). Sonar deep research is more accurate + cheaper
# than o4-mini deep research, so it leads the deepsearch chain.
if [[ "$EXHAUSTIVE" -eq 1 ]]; then
  [[ "$MODEL_SET" -eq 1 ]] || MODEL="perplexity/sonar-deep-research"
  [[ "$FALLBACK_SET" -eq 1 ]] || FALLBACK="openai/o4-mini-deep-research"
elif [[ "$X_MODE" -eq 1 ]]; then
  [[ "$MODEL_SET" -eq 1 ]] || MODEL="x-ai/grok-4.3"
  [[ "$FALLBACK_SET" -eq 1 ]] || FALLBACK="x-ai/grok-4.1-fast"
fi

# Question can also come from stdin (piped).
if [[ -z "$QUESTION" && ! -t 0 ]]; then
  QUESTION="$(cat)"
fi
QUESTION="${QUESTION#"${QUESTION%%[![:space:]]*}"}"   # ltrim
QUESTION="${QUESTION%"${QUESTION##*[![:space:]]}"}"   # rtrim

if [[ -z "$QUESTION" ]]; then
  echo "ERROR: no research question given. See --help." >&2
  exit 2
fi

# --- resolve the API key ---------------------------------------------------
if [[ -z "${OPENROUTER_API_KEY:-}" ]]; then
  secrets_file="${HYDRA_SECRETS_FILE:-/opt/hydra/secrets/llm-provider-keys.json}"
  if [[ -r "$secrets_file" ]]; then
    OPENROUTER_API_KEY="$(jq -r '.OPENROUTER_API_KEY // empty' "$secrets_file" 2>/dev/null || true)"
  fi
fi
if [[ -z "${OPENROUTER_API_KEY:-}" ]]; then
  echo "ERROR: OPENROUTER_API_KEY not set and not found in the hydra-secrets store." >&2
  echo "       Set OPENROUTER_API_KEY in the environment." >&2
  exit 3
fi

# --- call OpenRouter -------------------------------------------------------
# call_model <model> -> writes response body to $RESP_FILE, echoes HTTP code.
RESP_FILE="$(mktemp)"
BODY_FILE="$(mktemp)"
cleanup() { rm -f "$RESP_FILE" "$BODY_FILE"; }
trap cleanup EXIT

call_model() {
  local model="$1"
  # reasoning_effort is only meaningful for the reasoning / deep-research models;
  # sending it to a plain search model (e.g. the sonar-pro fallback) can 400, so
  # only include it when the model supports it.
  local extra='{}'
  case "$model" in
    *reasoning*|*deep-research*) extra="$(jq -n --arg e "$REASONING_EFFORT" '{reasoning_effort: $e}')" ;;
  esac
  # X mode: attach OpenRouter's native web-search server tool, scoped to x.com so
  # Grok searches X posts. For Grok 4+ engine=native covers web + X search.
  local tools='{}'
  if [[ "$X_MODE" -eq 1 ]]; then
    tools="$(jq -n '{tools: [{type: "openrouter:web_search", parameters: {engine: "native", allowed_domains: ["x.com"]}}]}')"
  fi
  jq -n \
    --arg model "$model" \
    --arg content "$QUESTION" \
    --argjson extra "$extra" \
    --argjson tools "$tools" \
    '{model: $model, messages: [{role: "user", content: $content}]} + $extra + $tools' \
    > "$BODY_FILE"
  curl -sS -o "$RESP_FILE" -w '%{http_code}' --max-time "$MAX_TIME" \
    -X POST "$OPENROUTER_BASE/chat/completions" \
    -H "Authorization: Bearer $OPENROUTER_API_KEY" \
    -H "Content-Type: application/json" \
    -H "X-Title: muso-deep-research" \
    -d @"$BODY_FILE"
}

# response_content -> the assistant text, or empty if absent.
response_content() {
  jq -r '.choices[0].message.content // empty' "$RESP_FILE" 2>/dev/null || true
}

succeeded() {
  local code="$1"
  [[ "$code" =~ ^2[0-9][0-9]$ ]] && [[ -n "$(response_content)" ]]
}

code="$(call_model "$MODEL" || true)"
used_model="$MODEL"
if ! succeeded "$code"; then
  echo "WARN: primary model '$MODEL' failed (http=$code); retrying with fallback '$FALLBACK'." >&2
  code="$(call_model "$FALLBACK" || true)"
  used_model="$FALLBACK"
fi

if ! succeeded "$code"; then
  echo "ERROR: deep research failed on both '$MODEL' and '$FALLBACK' (last http=$code)." >&2
  echo "       Last response body:" >&2
  head -c 2000 "$RESP_FILE" >&2 || true
  echo >&2
  exit 4
fi

# --- emit ------------------------------------------------------------------
if [[ "$RAW_JSON" -eq 1 ]]; then
  cat "$RESP_FILE"
  exit 0
fi

content="$(response_content)"

# Citations: Perplexity-over-OpenRouter returns sources either as a top-level
# `.citations` array of URLs, or as per-message annotations. Collect whichever
# is present.
sources=()
while IFS= read -r _src_line; do
  [[ -n "$_src_line" ]] && sources+=("$_src_line")
done < <(
  jq -r '
    ( .citations // [] )
    + ( [ .choices[0].message.annotations[]? | (.url_citation.url // .url // empty) ] )
    | map(select(. != null and . != ""))
    | unique
    | .[]
  ' "$RESP_FILE" 2>/dev/null || true
)

printf '%s\n' "$content"
if [[ "${#sources[@]}" -gt 0 ]]; then
  printf '\n## Sources\n'
  i=1
  for url in "${sources[@]}"; do
    printf '%d. %s\n' "$i" "$url"
    i=$((i + 1))
  done
fi
printf '\n_(deep research via %s)_\n' "$used_model"
