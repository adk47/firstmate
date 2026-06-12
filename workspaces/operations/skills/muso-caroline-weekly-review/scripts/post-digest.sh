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
#     blocks). Posted verbatim, except [thread_ts] (when given) is injected
#     as the payload's thread_ts so the message lands as a thread reply —
#     same threading contract as scripts/qa-slack-dm.sh.
#     On success prints the message ts on stdout.
#
# Token comes from the gateway config (channels.slack.accounts.<account>
# .botToken), same pattern as scripts/qa-slack-dm.sh. Slack returns HTTP 200
# with {"ok":false} for not_in_channel / invalid_auth / invalid_blocks, so the
# ok flag is parsed — curl exit status alone is NOT delivery proof.
#
# NOT best-effort: a failed post exits non-zero so the caller
# (publish-digest.sh) can fall back to the plain-text announce path loudly.
#
# Env overrides (mainly for tests):
#   SLACK_ACCOUNT        bot account whose token to use (default: operations)
#   SLACK_NOTIFY_CONFIG  gateway config path (default: /root/.openclaw-main/openclaw.json)
#   CURL                 curl binary (default: curl)
# Exit codes: 0 ok | 2 usage | 1 slack/api failure.

SLACK_ACCOUNT="${SLACK_ACCOUNT:-operations}"
SLACK_NOTIFY_CONFIG="${SLACK_NOTIFY_CONFIG:-/root/.openclaw-main/openclaw.json}"
CURL="${CURL:-curl}"

die() { echo "post-digest: $2" >&2; exit "$1"; }

PAYLOAD="${1:?usage: post-digest.sh <payload.json> [thread_ts]}"
THREAD_TS="${2:-}"
[ -f "$PAYLOAD" ] || die 2 "payload file not found: $PAYLOAD"
jq -e '(.channel | type == "string") and (.blocks | type == "array" and length > 0)' \
  "$PAYLOAD" >/dev/null 2>&1 \
  || die 2 "payload must be a chat.postMessage body with .channel and non-empty .blocks (from render-digest.py --blocks-main/--blocks-thread)"

if [ -n "$THREAD_TS" ]; then
  threaded="$(mktemp)"
  trap 'rm -f "$threaded"' EXIT
  jq --arg ts "$THREAD_TS" '. + {thread_ts: $ts}' "$PAYLOAD" > "$threaded" \
    || die 2 "could not inject thread_ts into payload"
  PAYLOAD="$threaded"
fi

token="$(python3 -c "
import json,sys
with open('${SLACK_NOTIFY_CONFIG}') as f:
    c = json.load(f)
print(c['channels']['slack']['accounts']['${SLACK_ACCOUNT}']['botToken'])
" 2>/dev/null || true)"
[ -n "$token" ] || die 1 "could not read ${SLACK_ACCOUNT} bot token from ${SLACK_NOTIFY_CONFIG}."

resp="$("$CURL" -sf -X POST "https://slack.com/api/chat.postMessage" \
  -H "Authorization: Bearer ${token}" \
  -H "Content-Type: application/json; charset=utf-8" \
  --data-binary @"$PAYLOAD" 2>/dev/null || true)"

ts="$(printf '%s' "$resp" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('ts','') if d.get('ok') else '')" 2>/dev/null || true)"
[ -n "$ts" ] || die 1 "chat.postMessage failed: $(printf '%s' "$resp" | head -c 200)"

printf '%s\n' "$ts"
