#!/usr/bin/env bash
# dispatch-cv-batch.sh — agent-callable wrapper around the Lobster MVP
# pipeline. Solves a real problem: the `lobster` tool's gateway schema
# advertises `flowId` and `flowExpectedRevision` as optional parameters
# (because the same tool handles both run + resume actions). Schema-driven
# agents fill those fields in, then Lobster's run action handler throws
# "run action does not accept flowId or flowExpectedRevision".
#
# By going through `exec` (which has a stable `command: string` schema)
# instead of the `lobster` tool directly, the agent has no field to
# populate beyond the command itself.
#
# Usage:
#   dispatch-cv-batch.sh [<batch_size>] [<thread_ts>] [<apply_mode>] [<selector_kind>] [<selector_id>]
#
# Args:
#   batch_size       1..500. Missing → safe default 500. Non-integer → exit 2.
#   thread_ts        Slack thread timestamp for the reply; "" if none
#   apply_mode       Missing → safe default "real". Must be in
#                    {real|REAL|dry|DRY|false|FALSE|true|TRUE} or exit 2.
#   selector_kind    "queue" (default) | "profile" | "credit"
#   selector_id      UUID for profile/credit modes; empty for queue
#
# Stdout: the Lobster pipeline's final-step output (the Slack summary text)
# Exit: 0 on success, non-zero on dispatch failure (HTTP/auth/etc.)

set -euo pipefail

# --- args ------------------------------------------------------------------

BATCH_SIZE_RAW="${1:-}"
THREAD_TS="${2:-}"
APPLY_MODE_RAW="${3:-}"
SELECTOR_KIND="${4:-queue}" # "queue" | "profile" | "credit"
SELECTOR_ID="${5:-}"

# Validate batch_size. Empty → safe default 500. Non-numeric → fail loud.
# Previously, garbage like `--help` silently became BATCH_SIZE=500 and
# APPLY_MODE=real, firing a 500-credit real apply on any typo. Verified
# live 2026-05-18 when a diagnostic probe `dispatch-cv-batch.sh --help`
# unintentionally landed 500 admin-API writes (PR #290 post-merge).
if [[ -z "$BATCH_SIZE_RAW" ]]; then
  BATCH_SIZE=500
elif [[ "$BATCH_SIZE_RAW" =~ ^[0-9]+$ ]]; then
  BATCH_SIZE="$BATCH_SIZE_RAW"
else
  echo "ERROR: batch_size must be a non-negative integer (got: '$BATCH_SIZE_RAW')" >&2
  echo "Usage: dispatch-cv-batch.sh [<batch_size>] [<thread_ts>] [<apply_mode>] [<selector_kind>] [<selector_id>]" >&2
  exit 2
fi
if (( BATCH_SIZE < 1 )); then
  BATCH_SIZE=1
elif (( BATCH_SIZE > 500 )); then
  BATCH_SIZE=500
fi

# Validate apply_mode. Empty → safe default real. Anything else must be
# one of the known tokens. Unknown tokens (typos, --help, etc.) MUST
# fail loud — silently routing to "real" or "dry" is a footgun either way.
case "$APPLY_MODE_RAW" in
  ""|real|REAL|false|FALSE) DRY_RUN_STR="false" ;;
  dry|DRY|true|TRUE)        DRY_RUN_STR="true"  ;;
  *)
    echo "ERROR: apply_mode must be 'real' or 'dry' (got: '$APPLY_MODE_RAW')" >&2
    echo "Usage: dispatch-cv-batch.sh [<batch_size>] [<thread_ts>] [<apply_mode>] [<selector_kind>] [<selector_id>]" >&2
    exit 2
    ;;
esac

# Validate selector. Profile/credit modes REQUIRE a UUID; queue mode ignores ID.
case "$SELECTOR_KIND" in
  queue)
    SELECTOR_ID=""
    ;;
  profile|credit)
    UUID_RE='^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
    if [[ ! "$SELECTOR_ID" =~ $UUID_RE ]]; then
      echo "ERROR: selector_kind=$SELECTOR_KIND requires UUID selector_id (got: '$SELECTOR_ID')" >&2
      exit 2
    fi
    ;;
  *)
    echo "ERROR: selector_kind must be queue|profile|credit (got: '$SELECTOR_KIND')" >&2
    exit 2
    ;;
esac

# --- gateway auth ----------------------------------------------------------

CONFIG_PATH="${OPENCLAW_CONFIG_PATH:-/root/.openclaw-main/openclaw.json}"
GATEWAY_PORT="${OPENCLAW_GATEWAY_PORT:-18789}"
PIPELINE_PATH="/opt/hydra/workspaces/operations/skills/muso-ops-credit-verification/pipelines/verify-credit-batch-mvp.lobster"

if [[ ! -r "$CONFIG_PATH" ]]; then
  echo "ERROR: openclaw config not readable at $CONFIG_PATH" >&2
  exit 2
fi

TOK=$(jq -r '.gateway.auth.token // empty' "$CONFIG_PATH")
if [[ -z "$TOK" ]]; then
  echo "ERROR: gateway.auth.token missing from $CONFIG_PATH" >&2
  exit 3
fi

if [[ ! -r "$PIPELINE_PATH" ]]; then
  echo "ERROR: pipeline file missing at $PIPELINE_PATH" >&2
  exit 4
fi

# --- build payload --------------------------------------------------------

# argsJson is a STRING containing JSON (Lobster forwards it into the
# pipeline's args: block). The outer payload is JSON-with-nested-string.
ARGS_JSON=$(jq -nc \
  --argjson bs "$BATCH_SIZE" \
  --arg tts "$THREAD_TS" \
  --arg dry "$DRY_RUN_STR" \
  --arg skind "$SELECTOR_KIND" \
  --arg sid "$SELECTOR_ID" \
  '{batch_size:$bs, thread_ts:$tts, dry_run:$dry, selector_kind:$skind, selector_id:$sid}')

PAYLOAD=$(jq -nc \
  --arg pipeline "$PIPELINE_PATH" \
  --arg argsJson "$ARGS_JSON" \
  '{tool:"lobster", action:"run",
    args:{pipeline:$pipeline, argsJson:$argsJson, timeoutMs:700000}}')

# --- invoke ----------------------------------------------------------------

RESPONSE=$(curl -sS -X POST "http://127.0.0.1:${GATEWAY_PORT}/tools/invoke" \
  -H "Authorization: Bearer $TOK" \
  -H "Content-Type: application/json" \
  -d "$PAYLOAD")

OK=$(echo "$RESPONSE" | jq -r '.ok // false')
if [[ "$OK" != "true" ]]; then
  echo "ERROR: lobster invocation failed:" >&2
  echo "$RESPONSE" | jq . >&2
  # If we have a thread_ts, post a graceful failure message so the user
  # isn't left with a silent timeout. Otherwise just exit with the error
  # going to caller's stderr.
  if [[ -n "$THREAD_TS" ]]; then
    ERR_TYPE=$(echo "$RESPONSE" | jq -r '.error.type // "unknown"')
    ERR_MSG=$(echo "$RESPONSE" | jq -r '.error.message // "no error detail"')
    FAIL_TEXT=":x: *Lobster credit-verification failed*
batch_size=$BATCH_SIZE | error.type=\`$ERR_TYPE\`
\`\`\`
${ERR_MSG}
\`\`\`
No credits were processed."
    OPENCLAW_BIN="${OPENCLAW_CLI:-openclaw}"
    OPENCLAW_PROFILE="${OPENCLAW_PROFILE:-main}"
    TARGET_CHANNEL="${TARGET_CHANNEL:-C0APB2CMM7C}"
    if command -v "$OPENCLAW_BIN" >/dev/null 2>&1; then
      "$OPENCLAW_BIN" --profile "$OPENCLAW_PROFILE" message send \
        --account operations \
        --channel slack \
        --target "$TARGET_CHANNEL" \
        --reply-to "$THREAD_TS" \
        --message "$FAIL_TEXT" >/dev/null 2>&1 || true
    fi
  fi
  exit 5
fi

# Pipeline's last step (summary) emits the Slack-ready text on its stdout.
# Lobster's .result.details.output is an array of per-step stdouts. The
# render-dry-run-summary.sh step already posts to Slack itself when
# thread_ts is non-empty; we surface the text here so the agent can read
# it (e.g. for logging) without re-posting.
echo "$RESPONSE" | jq -r '.result.details.output[-1] // .result.details.output // empty'
