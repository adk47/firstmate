#!/usr/bin/env bash
set -euo pipefail

# post-digest.sh — post the Block Kit digest payload as the OPERATIONS bot
# (the "Ops" Slack app, the same identity that posts the close-resolved summary
# to #cs_chats — see scripts/close-resolved-conversations.py).
# ===========================================================================
# Usage:
#   post-digest.sh <payload.json> [thread_ts]
#     <payload.json> is a complete chat.postMessage body produced by
#     render-digest.py --blocks-main / --blocks-thread (channel + text +
#     blocks). [thread_ts] (when given) makes the message land as a thread
#     reply — same threading contract as scripts/qa-slack-dm.sh.
#     On success prints the message ts on stdout.
#
# Sends via `muso slack send` (the gated CLI, issue #5 PR1): the payload's
# channel/text/blocks map onto --channel/--text/--blocks-file, the bot token
# comes from MUSO_SLACK_BOT_TOKEN_<BOT> in the environment, and the CLI
# decodes Slack's HTTP-200 {"ok":false} trap (not_in_channel / invalid_auth /
# invalid_blocks all exit non-zero) — its exit code IS delivery proof.
#
# NOT best-effort: a failed post exits non-zero so the caller
# (publish-digest.sh) can fall back to the plain-text announce path loudly.
#
# Env overrides (mainly for tests):
#   SLACK_ACCOUNT          bot identity to send as (default: operations)
#   MUSO_BIN               muso binary (default: muso)
#   MUSO_SLACK_ENV_FILE    env file with MUSO_SLACK_BOT_TOKEN_<BOT> vars
#                          (default: /etc/openclaw/main.env)
#   SLACK_NOTIFY_REQUESTER audit attribution (default: post-digest@hydra-ops)
# Exit codes: 0 ok | 2 usage | 1 slack/api failure.

SLACK_ACCOUNT="${SLACK_ACCOUNT:-operations}"
MUSO_BIN="${MUSO_BIN:-muso}"
MUSO_SLACK_ENV_FILE="${MUSO_SLACK_ENV_FILE:-/etc/openclaw/main.env}"

die() { echo "post-digest: $2" >&2; exit "$1"; }

PAYLOAD="${1:?usage: post-digest.sh <payload.json> [thread_ts]}"
THREAD_TS="${2:-}"
[ -f "$PAYLOAD" ] || die 2 "payload file not found: $PAYLOAD"
jq -e '(.channel | type == "string") and (.blocks | type == "array" and length > 0)' \
  "$PAYLOAD" >/dev/null 2>&1 \
  || die 2 "payload must be a chat.postMessage body with .channel and non-empty .blocks (from render-digest.py --blocks-main/--blocks-thread)"

bot_var="MUSO_SLACK_BOT_TOKEN_$(printf '%s' "$SLACK_ACCOUNT" | tr '[:lower:]' '[:upper:]')"
if [ -z "${!bot_var:-}" ] && [ -r "$MUSO_SLACK_ENV_FILE" ]; then
  eval "$(grep -E '^MUSO_SLACK_[A-Z_]+=' "$MUSO_SLACK_ENV_FILE" | sed 's/^/export /')" 2>/dev/null || true
fi
[ -n "${!bot_var:-}" ] || die 1 "no ${bot_var} in the environment or ${MUSO_SLACK_ENV_FILE}."

channel="$(jq -r '.channel' "$PAYLOAD")"
text="$(jq -r '.text // empty' "$PAYLOAD")"

blocks_file="$(mktemp)"
trap 'rm -f "$blocks_file"' EXIT
jq '.blocks' "$PAYLOAD" > "$blocks_file" || die 2 "could not extract .blocks from payload"

args=(slack send --bot "$SLACK_ACCOUNT" --channel "$channel" \
  --blocks-file "$blocks_file" \
  --requester "${SLACK_NOTIFY_REQUESTER:-post-digest@hydra-ops}" --json)
[ -n "$text" ] && args+=(--text "$text")
[ -n "$THREAD_TS" ] && args+=(--thread-ts "$THREAD_TS")

# Fail-loud: keep muso's stderr (the decoded Slack error) visible to the
# caller's logs; stdout carries {"channel","ts"} on success.
resp="$("$MUSO_BIN" "${args[@]}")" || die 1 "muso slack send failed (see stderr above)"
ts="$(printf '%s' "$resp" | jq -r '.ts // empty' 2>/dev/null || true)"
[ -n "$ts" ] || die 1 "muso slack send returned no ts: $(printf '%s' "$resp" | head -c 200)"

printf '%s\n' "$ts"
