#!/usr/bin/env bash
set -euo pipefail

# qa-slack-dm.sh — DM a Slack user as the QA bot (the "QA APP" identity).
# ===========================================================================
# Used by the muso-github-code-review skill's auto mode to talk to the PR author
# in a DM: an opening "reviewing PR #N …" message, then a threaded result.
# Sends via `muso slack dm` (the gated CLI, issue #5 PR1): conversations.open +
# chat.postMessage, per-bot token from MUSO_SLACK_BOT_TOKEN_<BOT>, Slack's
# HTTP-200 ok:false trap decoded by the CLI, every send audited.
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
#   SLACK_ACCOUNT          bot identity to send as (default: qa)
#   MUSO_BIN               muso binary (default: muso)
#   MUSO_SLACK_ENV_FILE    env file with MUSO_SLACK_BOT_TOKEN_<BOT> vars
#                          (default: /etc/openclaw/main.env — agent sessions
#                          don't always carry main.env; lib/slack-notify.sh
#                          pulls the slack vars in)
#   SLACK_NOTIFY_REQUESTER audit attribution (default: qa-slack-dm@hydra-ops)
# Exit codes: 0 ok | 2 usage | 1 slack/api failure.

SLACK_ACCOUNT="${SLACK_ACCOUNT:-qa}"

die() { echo "qa-slack-dm: $2" >&2; exit "$1"; }

[ "$#" -ge 2 ] || die 2 "usage: qa-slack-dm.sh <slack-user-id> <text> [thread_ts]"
user_id="$1"
text="$2"
thread_ts="${3:-}"
[ -n "$user_id" ] || die 2 "slack-user-id is empty."
[ -n "$text" ]    || die 2 "text is empty."

# muso reads MUSO_SLACK_BOT_TOKEN_<BOT> from the environment; the lib pulls in
# exactly the slack vars from main.env when the session doesn't carry them.
# shellcheck source=lib/slack-notify.sh
source "$(dirname "$0")/lib/slack-notify.sh"
slack_load_env "$SLACK_ACCOUNT" \
  || die 1 "no Slack token for bot '${SLACK_ACCOUNT}' in the environment or ${MUSO_SLACK_ENV_FILE}."

args=(slack dm --bot "$SLACK_ACCOUNT" --user "$user_id" --text "$text" \
  --requester "${SLACK_NOTIFY_REQUESTER:-qa-slack-dm@hydra-ops}" --json)
[ -n "$thread_ts" ] && args+=(--thread-ts "$thread_ts")

# muso exits non-zero on any failure (conversations.open, ok:false, auth) with
# the reason on stderr — keep it visible; --json puts {"channel","ts"} on stdout.
resp="$("$MUSO_BIN" "${args[@]}")" || die 1 "muso slack dm failed for user ${user_id} (see stderr above)"
ts="$(printf '%s' "$resp" | jq -r '.ts // empty' 2>/dev/null || true)"
[ -n "$ts" ] || die 1 "muso slack dm returned no ts: $(printf '%s' "$resp" | head -c 200)"

printf '%s\n' "$ts"
