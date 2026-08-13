#!/usr/bin/env bash
#
# deploy-notify.sh <success|critical> <message>
#
# Deploy/rollback notifier that REPORTS ITS OWN DELIVERY STATUS.
#
# Why this exists instead of calling slack_notify directly: slack_notify is
# deliberately best-effort — `slack_load_env ... || return 0` means a MISSING
# token returns success, and the send itself ends in `|| true`. So a caller
# writing `slack_notify "$msg" || warn` can never warn: not when the token is
# absent, not when Slack rejects the post (invalid_auth, not_in_channel). The
# deploy pipeline needs the opposite contract — an unnoticed page is how a
# fleet-wide deploy outage went unseen on 2026-08-06.
#
# slack_notify_payload_file_status IS status-returning (0 only on a post Slack
# confirmed; the muso CLI decodes Slack's HTTP-200 {"ok":false} trap), so this
# wrapper builds the payload and propagates that status.
#
# Exit: 0 only when Slack confirmed the post. Non-zero on missing token,
#       missing library, malformed payload, or a rejected delivery.
set -uo pipefail

MODE="${1:-}"
MSG="${2:-}"

case "$MODE" in
  success|critical) ;;
  *) echo "deploy-notify: usage: deploy-notify.sh <success|critical> <message>" >&2; exit 2 ;;
esac
[ -n "$MSG" ] || { echo "deploy-notify: empty message" >&2; exit 2; }

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="${DEPLOY_NOTIFY_LIB:-$SELF_DIR/slack-notify.sh}"

if [ ! -r "$LIB" ]; then
  echo "deploy-notify: cannot read $LIB" >&2
  exit 1
fi
# shellcheck source=/dev/null
. "$LIB" || { echo "deploy-notify: failed to source $LIB" >&2; exit 1; }

if ! command -v slack_notify_payload_file_status >/dev/null 2>&1; then
  echo "deploy-notify: slack_notify_payload_file_status unavailable in $LIB" >&2
  exit 1
fi

# Real <@UID> mentions for a page. A literal "@name" renders as plain text and
# pings nobody (CLAUDE.md); the UIDs come from the sourced library so there is
# one definition of who is on call.
TEXT="$MSG"
if [ "$MODE" = "critical" ]; then
  TEXT="<@${SLACK_UID_NICK}> <@${SLACK_UID_AARON}> $MSG"
fi

PAYLOAD="$(mktemp -t deploy-notify-XXXXXX)" || { echo "deploy-notify: mktemp failed" >&2; exit 1; }
trap 'rm -f "$PAYLOAD"' EXIT

if ! jq -n --arg c "${SLACK_CHANNEL}" --arg t "$TEXT" \
      '{channel:$c, text:$t}' > "$PAYLOAD" 2>/dev/null; then
  echo "deploy-notify: could not build payload" >&2
  exit 1
fi

slack_notify_payload_file_status "$PAYLOAD"
