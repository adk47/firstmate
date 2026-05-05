#!/bin/bash
# ──────────────────────────────────────────────────────────────
# slack-notify.sh — sourced helper for posting Slack messages
# from hydra ops scripts using the devops bot token stored
# inside openclaw's main-profile config.
#
# Usage:
#   source /opt/hydra/scripts/lib/slack-notify.sh
#   slack_notify "your message here"
#
# Env knobs:
#   SLACK_CHANNEL          # Slack channel ID to post into.
#                          # Defaults to C0ADV2W76G4 (#clio_devops).
#   SLACK_NOTIFY_CONFIG    # Path to openclaw config that holds the
#                          # devops bot token. Defaults to the main
#                          # profile path because openclaw-watchdog
#                          # historically read from there; callers
#                          # in other profiles can override.
#
# Why a sourced lib instead of a separate executable: callers want
# slack_notify to be silent on transient failures (Slack is the alert
# channel — failing to alert about an alert shouldn't itself fail the
# script that's already mid-recovery). Sourcing keeps `|| true`
# semantics the same as the previous inline copy in openclaw-watchdog.sh.
# ──────────────────────────────────────────────────────────────

: "${SLACK_CHANNEL:=C0ADV2W76G4}"
: "${SLACK_NOTIFY_CONFIG:=/root/.openclaw-main/openclaw.json}"

slack_notify() {
  local msg="$1"
  local token
  token=$(python3 -c "
import json
with open('${SLACK_NOTIFY_CONFIG}') as f:
    c = json.load(f)
print(c['channels']['slack']['accounts']['devops']['botToken'])
" 2>/dev/null) || true

  if [ -z "$token" ]; then
    # Best-effort: don't fail the caller. Pre-start-heal in particular
    # may be running BECAUSE the config is malformed, in which case the
    # token read above raises — which is fine, we just can't notify.
    return 0
  fi

  curl -sf -X POST "https://slack.com/api/chat.postMessage" \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/json" \
    -d "{\"channel\":\"${SLACK_CHANNEL}\",\"text\":\"${msg}\"}" >/dev/null 2>&1 || true
}
