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

_slack_read_token() {
  python3 -c "
import json
with open('${SLACK_NOTIFY_CONFIG}') as f:
    c = json.load(f)
print(c['channels']['slack']['accounts']['devops']['botToken'])
" 2>/dev/null || true
}

slack_notify() {
  local msg="$1"
  local token
  token=$(_slack_read_token)

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

# _slack_post_payload <path-to-json>  (internal)
# POSTs the exact JSON payload at <path> via chat.postMessage and RETURNS the
# real delivery status: 0 only when Slack confirms the message was posted;
# non-zero when the payload is unreadable, the token is missing, curl/HTTP
# fails, OR Slack replies HTTP 200 with `{"ok":false}`. That last case matters:
# the Slack Web API returns 200 + ok:false for application-level failures
# (invalid_auth, not_in_channel, missing scope...), so `curl -f` (which only
# fails on HTTP >=400) is NOT sufficient proof of delivery — we must parse
# `.ok`. Public wrappers below pick best-effort vs status-aware.
_slack_post_payload() {
  local payload_file="$1"
  [ -r "$payload_file" ] || return 1
  local token
  token=$(_slack_read_token)
  [ -z "$token" ] && return 1

  local resp
  resp=$(curl -sf -X POST "https://slack.com/api/chat.postMessage" \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/json; charset=utf-8" \
    --data-binary "@${payload_file}" 2>/dev/null) || return 1

  # Confirm ok:true. A non-JSON / empty body or ok:false is a delivery failure.
  printf '%s' "$resp" | python3 -c 'import json,sys
try:
    sys.exit(0 if json.load(sys.stdin).get("ok") is True else 1)
except Exception:
    sys.exit(1)'
}

# slack_notify_payload_file <path-to-json>
# Posts the exact JSON payload at <path> via chat.postMessage. Caller is
# responsible for the payload shape — typically {channel, text, blocks}.
# Use this for Block Kit messages: build the JSON in Python (apostrophes
# in commit subjects will break naive bash heredocs — see the 2026-05-07
# api-evidence.sh apostrophe-in-heredoc burn).
#
# Best-effort: never fails the caller (preserves the historical contract that
# failing to post an alert shouldn't abort a script that's already mid-recovery).
slack_notify_payload_file() {
  _slack_post_payload "$1" || true
  return 0
}

# slack_notify_payload_file_status <path-to-json>
# Same POST, but RETURNS delivery status (0 only on a confirmed post). Use when
# the caller must NOT advance dedupe / idempotency state for an alert that was
# never actually delivered (e.g. a watchdog that would otherwise mark an
# incident "already paged" and never retry it).
slack_notify_payload_file_status() {
  _slack_post_payload "$1"
}
