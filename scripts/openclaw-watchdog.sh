#!/bin/bash
# ──────────────────────────────────────────────────────────────
# OpenClaw Gateway Watchdog
#
# Runs every 10 minutes via cron ON NODE-8 (local to the gateway).
# Checks journalctl for successful agent runs. If zero successes
# in the last 15 minutes, restarts openclaw-gateway and posts
# to #clio_devops via the devops bot token.
#
# Install on node-8:
#   cp scripts/openclaw-watchdog.sh /opt/hydra/scripts/openclaw-watchdog.sh
#   chmod +x /opt/hydra/scripts/openclaw-watchdog.sh
#   crontab -e:
#     */10 * * * * /opt/hydra/scripts/openclaw-watchdog.sh >> /var/log/openclaw-watchdog.log 2>&1
# ──────────────────────────────────────────────────────────────
set -euo pipefail

LOGPREFIX="[openclaw-watchdog $(date -u +%Y-%m-%dT%H:%M:%SZ)]"
OPENCLAW_CONFIG="/root/.openclaw-main/openclaw.json"
SLACK_CHANNEL="C0ADV2W76G4"  # #clio_devops
CHECK_WINDOW_MIN=15
COOLDOWN_FILE="/tmp/openclaw-watchdog-cooldown"
COOLDOWN_MIN=30  # Don't restart more than once per 30 min
GATEWAY_SERVICE="openclaw-gateway-main"  # PR 43: multi-gateway split

log() { echo "$LOGPREFIX $1"; }

# Crash loop detection: if systemd has restarted the gateway more than
# 10 times in the last 10 minutes, something is wrong with the config.
# Don't add more restarts — alert and stop.
RESTART_COUNT=$(journalctl -u $GATEWAY_SERVICE --since "10 min ago" --no-pager 2>/dev/null \
  | grep -c 'Starting openclaw-gateway' || true)
if [ "${RESTART_COUNT:-0}" -gt 10 ]; then
  log "CRASH LOOP DETECTED: ${RESTART_COUNT} restarts in 10 min — NOT restarting. Check openclaw.json for invalid config."
  slack_notify ":rotating_light: *CRASH LOOP DETECTED* — Gateway restarted ${RESTART_COUNT} times in 10 min. Likely invalid config. NOT restarting. Run \`openclaw doctor --fix\` on node-8."
  exit 0
fi

slack_notify() {
  local msg="$1"
  # Read devops bot token from openclaw config
  local token
  token=$(python3 -c "
import json
with open('${OPENCLAW_CONFIG}') as f:
    c = json.load(f)
print(c['channels']['slack']['accounts']['devops']['botToken'])
" 2>/dev/null) || true

  if [ -z "$token" ]; then
    log "WARN: Could not read devops bot token — skipping Slack notify"
    return
  fi

  curl -sf -X POST "https://slack.com/api/chat.postMessage" \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/json" \
    -d "{\"channel\":\"${SLACK_CHANNEL}\",\"text\":\"${msg}\"}" >/dev/null 2>&1 || true
}

# Grab recent logs once
RECENT_LOGS=$(journalctl -u $GATEWAY_SERVICE --since "${CHECK_WINDOW_MIN} min ago" --no-pager 2>/dev/null || true)

# Count successful agent runs in the last CHECK_WINDOW_MIN minutes
SUCCESS_COUNT=$(echo "$RECENT_LOGS" | grep -c 'run agent end.*isError=false' 2>/dev/null || true)
SUCCESS_COUNT=${SUCCESS_COUNT:-0}

# Count errors in the same window
ERROR_COUNT=$(echo "$RECENT_LOGS" | grep -c 'isError=true' 2>/dev/null || true)
ERROR_COUNT=${ERROR_COUNT:-0}

# Count messages received (agents were invoked)
MSG_COUNT=$(echo "$RECENT_LOGS" | grep -c 'run agent' 2>/dev/null || true)
MSG_COUNT=${MSG_COUNT:-0}

log "Check: ${SUCCESS_COUNT} successes, ${ERROR_COUNT} errors, ${MSG_COUNT} agent runs in last ${CHECK_WINDOW_MIN}min"

# If there are no agent runs at all, system might just be idle — don't restart
if [ "$MSG_COUNT" -eq 0 ]; then
  log "No agent activity — system idle, no action needed"
  exit 0
fi

# Check if errors are all API overloads (529 Anthropic or 429 Fireworks) — if so, don't restart, it won't help
OVERLOAD_COUNT=$(echo "$RECENT_LOGS" | grep -c 'overloaded_error\|Overloaded' 2>/dev/null || true)
OVERLOAD_COUNT=${OVERLOAD_COUNT:-0}
FIREWORKS_429=$(echo "$RECENT_LOGS" | grep -c '429.*overloaded\|rate limit reached' 2>/dev/null || true)
FIREWORKS_429=${FIREWORKS_429:-0}
TOTAL_OVERLOAD=$((OVERLOAD_COUNT + FIREWORKS_429))

if [ "$FIREWORKS_429" -gt 10 ]; then
  log "FIREWORKS 429 ALERT: ${FIREWORKS_429} rate limit errors in last ${CHECK_WINDOW_MIN}min — GLM-5 capacity issue"
  slack_notify ":warning: *Fireworks GLM-5 Rate Limit* — ${FIREWORKS_429} 429 errors in last ${CHECK_WINDOW_MIN}min. Requests failing, Anthropic fallback also broken. Consider switching to DeepSeek V3 or hybrid plan."
fi

if [ "$SUCCESS_COUNT" -eq 0 ] && [ "$MSG_COUNT" -gt 0 ] && [ "$TOTAL_OVERLOAD" -ge "$ERROR_COUNT" ] && [ "$ERROR_COUNT" -gt 0 ]; then
  log "API OVERLOADED: ${TOTAL_OVERLOAD} overload errors (Anthropic: ${OVERLOAD_COUNT}, Fireworks 429: ${FIREWORKS_429}) — NOT restarting (won't help)."
  exit 0
fi

# If there are agent runs but zero successes AND it's not just API overload, the system is stuck
if [ "$SUCCESS_COUNT" -eq 0 ] && [ "$MSG_COUNT" -gt 0 ]; then
  log "STUCK: ${MSG_COUNT} agent runs but 0 successes — checking cooldown"

  # Cooldown check — don't restart too frequently
  if [ -f "$COOLDOWN_FILE" ]; then
    LAST_RESTART=$(cat "$COOLDOWN_FILE" 2>/dev/null || echo "0")
    NOW=$(date +%s)
    ELAPSED=$(( (NOW - LAST_RESTART) / 60 ))
    if [ "$ELAPSED" -lt "$COOLDOWN_MIN" ]; then
      log "SKIP: Last restart was ${ELAPSED}min ago (cooldown: ${COOLDOWN_MIN}min)"
      exit 0
    fi
  fi

  # Capture the error pattern for the notification
  LAST_ERROR=$(journalctl -u $GATEWAY_SERVICE --since "${CHECK_WINDOW_MIN} min ago" --no-pager 2>/dev/null \
    | grep 'isError=true' | tail -1 | sed 's/.*error=/error=/' | head -c 200 || echo "unknown")

  # --- Proactive outage notice: post to ALL channels with recent activity ---
  log "Posting outage notice to active channels..."
  python3 /opt/hydra/scripts/outage-notify.py "$LAST_ERROR" 2>/dev/null || true

  log "Restarting openclaw-gateway..."
  systemctl restart $GATEWAY_SERVICE

  # Record restart time
  date +%s > "$COOLDOWN_FILE"

  # Wait for startup
  sleep 5

  # Verify it came back
  STATUS=$(systemctl is-active $GATEWAY_SERVICE 2>/dev/null || echo "unknown")

  if [ "$STATUS" = "active" ]; then
    log "Restart successful — gateway is active"

    # Wait for agents to fully initialize (Slack sockets connect)
    sleep 10

    # Scan for unanswered messages and build impact report
    AFFECTED=$(python3 /opt/hydra/scripts/scan-unanswered.py 2>/dev/null || echo "")

    NOTIFY_MSG=":warning: *OpenClaw Watchdog* — Auto-restarted gateway. ${MSG_COUNT} agent runs with 0 successes in last ${CHECK_WINDOW_MIN}min.\nLast error: \`${LAST_ERROR}\`\nStatus: back online :white_check_mark:"
    if [ -n "$AFFECTED" ]; then
      NOTIFY_MSG="${NOTIFY_MSG}\n\n:busts_in_silhouette: *Unanswered messages during outage:*\n${AFFECTED}"
    fi
    slack_notify "$NOTIFY_MSG"

    # Re-trigger unanswered requests so agents actually respond to them
    log "Re-triggering unanswered requests..."
    python3 /opt/hydra/scripts/retrigger-unanswered.py "$LAST_ERROR" 2>/dev/null || true
  else
    log "CRITICAL: Restart failed — gateway status: ${STATUS}"
    slack_notify ":rotating_light: *OpenClaw Watchdog* — CRITICAL: Auto-restart FAILED. Gateway status: ${STATUS}. Manual intervention required. @aaron"
  fi
else
  log "Healthy: ${SUCCESS_COUNT}/${MSG_COUNT} agent runs succeeded"
fi

# --- Per-agent timeout detection ---
# Check if any agent has high timeout rate (agents acking but not responding)
TIMEOUT_COUNT=$(echo "$RECENT_LOGS" | grep -c 'reason=timeout' 2>/dev/null || true)
TIMEOUT_COUNT=${TIMEOUT_COUNT:-0}
if [ "$TIMEOUT_COUNT" -gt 5 ]; then
  log "HIGH TIMEOUT RATE: ${TIMEOUT_COUNT} timeouts in last ${CHECK_WINDOW_MIN}min"
  # Identify which agents are timing out
  TIMEOUT_AGENTS=$(echo "$RECENT_LOGS" | grep 'reason=timeout' | grep -oP 'provider=\S+' | sort | uniq -c | sort -rn | head -3)
  slack_notify ":warning: *Agent Timeout Alert* — ${TIMEOUT_COUNT} timeouts in last ${CHECK_WINDOW_MIN}min. Agents may be acking but not responding.\n${TIMEOUT_AGENTS}"
fi

# --- Unanswered message scan + auto-retrigger ---
UNANSWERED=$(python3 /opt/hydra/scripts/scan-unanswered.py 2>/dev/null || echo "")
UNANSWERED_COUNT=$(echo "$UNANSWERED" | grep -c '•' 2>/dev/null || true)
UNANSWERED_COUNT=${UNANSWERED_COUNT:-0}
if [ "$UNANSWERED_COUNT" -gt 0 ]; then
  log "UNANSWERED: ${UNANSWERED_COUNT} messages waiting for agent response"
  slack_notify ":warning: *${UNANSWERED_COUNT} unanswered @mentions detected*\n${UNANSWERED}"

  # Auto-retrigger unanswered messages via chat completions API
  GW_TOKEN=$(python3 -c "import json; print(json.load(open('${OPENCLAW_CONFIG}')).get('gateway',{}).get('auth',{}).get('token',''))" 2>/dev/null || true)
  if [ -n "$GW_TOKEN" ]; then
    log "Retriggering ${UNANSWERED_COUNT} unanswered requests..."
    python3 /opt/hydra/scripts/retrigger-unanswered.py "auto-heal" 2>/dev/null || true
  fi
fi
