#!/usr/bin/env bash
set -euo pipefail

# qa-slack-dm.sh — DM a Slack user as the QA bot (the "QA APP" identity).
# ===========================================================================
# Used by the muso-github-code-review skill's auto mode to talk to the PR author
# in a DM: an opening "reviewing PR #N …" message, then a threaded result. Posts
# via the Slack Web API using the QA account bot token from the gateway config
# (same token-from-config pattern as scripts/lib/slack-notify.sh). api.slack.com
# is in the egress allowlist for every agent except support.
#
# Usage:
#   qa-slack-dm.sh <slack-user-id> <text> [thread_ts]
#     - opens (or reuses) the DM channel with the user, posts <text>
#     - if [thread_ts] is given, posts as a threaded reply under it
#     - on success prints the message ts on stdout (use it to thread the reply)
#
# Best-effort by design: a Slack hiccup must never sink a review. Callers should
# treat a non-zero exit / empty ts as "notification skipped", not "review failed".
#
# Env overrides (mainly for tests):
#   SLACK_ACCOUNT        bot account whose token to use (default: qa)
#   SLACK_NOTIFY_CONFIG  gateway config path (default: /root/.openclaw-main/openclaw.json)
#   CURL                 curl binary (default: curl)
# Exit codes: 0 ok | 2 usage | 1 slack/api failure.

SLACK_ACCOUNT="${SLACK_ACCOUNT:-qa}"
SLACK_NOTIFY_CONFIG="${SLACK_NOTIFY_CONFIG:-/root/.openclaw-main/openclaw.json}"
CURL="${CURL:-curl}"

die() { echo "qa-slack-dm: $2" >&2; exit "$1"; }

[ "$#" -ge 2 ] || die 2 "usage: qa-slack-dm.sh <slack-user-id> <text> [thread_ts]"
user_id="$1"
text="$2"
thread_ts="${3:-}"
[ -n "$user_id" ] || die 2 "slack-user-id is empty."
[ -n "$text" ]    || die 2 "text is empty."

token="$(python3 -c "
import json,sys
with open('${SLACK_NOTIFY_CONFIG}') as f:
    c = json.load(f)
print(c['channels']['slack']['accounts']['${SLACK_ACCOUNT}']['botToken'])
" 2>/dev/null || true)"
[ -n "$token" ] || die 1 "could not read ${SLACK_ACCOUNT} bot token from ${SLACK_NOTIFY_CONFIG}."

# Resolve the DM channel id for the user (idempotent — returns the existing IM).
dm_channel="$("$CURL" -sf -X POST "https://api.slack.com/api/conversations.open" \
  -H "Authorization: Bearer ${token}" \
  -H "Content-Type: application/json; charset=utf-8" \
  -d "{\"users\":\"${user_id}\"}" 2>/dev/null \
  | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('channel',{}).get('id','') if d.get('ok') else '')" 2>/dev/null || true)"
[ -n "$dm_channel" ] || die 1 "conversations.open failed for user ${user_id} (bot may lack im:write or user not found)."

# Build the message payload in python so apostrophes/newlines in <text> can't
# break a bash heredoc (cf. the 2026-05-07 api-evidence.sh apostrophe burn).
payload="$(python3 -c "
import json,sys
msg = {'channel': sys.argv[1], 'text': sys.argv[2]}
if sys.argv[3]:
    msg['thread_ts'] = sys.argv[3]
print(json.dumps(msg))
" "$dm_channel" "$text" "$thread_ts")"

resp="$("$CURL" -sf -X POST "https://api.slack.com/api/chat.postMessage" \
  -H "Authorization: Bearer ${token}" \
  -H "Content-Type: application/json; charset=utf-8" \
  --data-binary "$payload" 2>/dev/null || true)"

ts="$(printf '%s' "$resp" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('ts','') if d.get('ok') else '')" 2>/dev/null || true)"
[ -n "$ts" ] || die 1 "chat.postMessage failed: $(printf '%s' "$resp" | head -c 200)"

printf '%s\n' "$ts"
