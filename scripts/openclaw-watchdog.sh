#!/bin/bash
# ──────────────────────────────────────────────────────────────
# OpenClaw Gateway Watchdog
#
# Runs every 2 minutes via cron ON NODE-8 (local to the gateway).
# Checks journalctl for successful agent runs and validates each
# gateway profile's config. Restarts openclaw-gateway if there
# are agent runs but zero successes (and it's not just upstream
# rate limiting), and posts to #clio_devops via the devops bot
# token on any anomaly.
#
# Cadence dropped from 10 min → 2 min after the 2026-05-05
# main-gateway crash-loop outage: the worst-case detection lag
# was the dominant component of the ~30 min ops-silent window.
# Validating 3 profiles + counting journal hits is ~100ms total.
#
# Install on node-8: managed by scripts/install-aux-units.sh
# (writes /etc/cron.d/openclaw-watchdog idempotently). Manual
# crontab installs are no longer the source of truth.
# ──────────────────────────────────────────────────────────────
set -euo pipefail

LOGPREFIX="[openclaw-watchdog $(date -u +%Y-%m-%dT%H:%M:%SZ)]"
OPENCLAW_CONFIG="/root/.openclaw-main/openclaw.json"
CHECK_WINDOW_MIN=15
COOLDOWN_FILE="/tmp/openclaw-watchdog-cooldown"
COOLDOWN_MIN=30  # Don't restart more than once per 30 min
GATEWAY_SERVICE="openclaw-gateway-main"  # PR 43: multi-gateway split

# Source the shared Slack helper. Both this watchdog and the new
# openclaw-pre-start-heal.sh need to post to the same #clio_devops
# channel using the devops bot token from the main-profile config.
# Locating sibling lib via this script's own directory rather than
# a hard /opt/hydra path keeps the script working when invoked from
# a worktree (laptop test) or a deploy mirror.
_WATCHDOG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC2034  # consumed by lib/slack-notify.sh via :- default
SLACK_NOTIFY_CONFIG="$OPENCLAW_CONFIG"
export SLACK_NOTIFY_CONFIG
# shellcheck source=lib/slack-notify.sh
source "$_WATCHDOG_DIR/lib/slack-notify.sh"

# Expected systemd log line that indicates a (re)start.
# systemd logs PAST TENSE ("Started ..."), NOT "Starting ...".
# If you change this regex, the inline self-test below fails loudly.
# Fixture captured from journalctl on node-8, 2026-04-07 (incident
# day: an 80-min crash loop went undetected because the previous
# version of this regex was 'Starting openclaw-gateway' which never
# matched anything systemd actually emits).
readonly RESTART_LOG_REGEX='Started openclaw-gateway-main\.service'
readonly RESTART_LOG_FIXTURE='Apr 07 20:51:14 ovh-node-8 systemd[1]: Started openclaw-gateway-main.service - OpenClaw Gateway HYDRA (main profile).'

log() { echo "$LOGPREFIX $1"; }

# slack_notify is provided by lib/slack-notify.sh sourced above.
# It silently no-ops if the devops bot token can't be read (e.g., the
# main-profile config is itself broken — the exact case the new
# pre-start-heal flow handles).

# ──────────────────────────────────────────────────────────────
# Inline self-test — runs on EVERY invocation (cost: ~1ms).
# Guards against the bug class that silently broke this watchdog
# for months: a regex that never matched real systemd output.
# Three independent tripwires together:
#   1. fixture grep (catches regex drift vs real systemd format)
#   2. function-defined check (catches the slack_notify ordering bug)
#   3. variable-set check (catches GATEWAY_SERVICE wipeouts)
# ──────────────────────────────────────────────────────────────
_watchdog_self_test() {
  local failed=0

  # Assert 1: the restart regex matches the known-good systemd fixture.
  if ! echo "$RESTART_LOG_FIXTURE" | grep -qE "$RESTART_LOG_REGEX"; then
    echo "$LOGPREFIX SELF-TEST FAIL: RESTART_LOG_REGEX does not match RESTART_LOG_FIXTURE" >&2
    echo "  regex:   $RESTART_LOG_REGEX" >&2
    echo "  fixture: $RESTART_LOG_FIXTURE" >&2
    failed=1
  fi

  # Assert 2: slack_notify is defined before any caller references it.
  if ! declare -F slack_notify >/dev/null; then
    echo "$LOGPREFIX SELF-TEST FAIL: slack_notify function not defined" >&2
    failed=1
  fi

  # Assert 3: GATEWAY_SERVICE is a non-empty identifier.
  if [[ -z "${GATEWAY_SERVICE:-}" ]]; then
    echo "$LOGPREFIX SELF-TEST FAIL: GATEWAY_SERVICE is empty" >&2
    failed=1
  fi

  return $failed
}

# --self-test mode: explicit invocation by smoke-test.sh and humans
# verifying a fix. Exits 0 on pass, 1 on fail. No side effects.
if [[ "${1:-}" == "--self-test" ]]; then
  if _watchdog_self_test; then
    echo "$LOGPREFIX SELF-TEST PASS"
    exit 0
  else
    exit 1
  fi
fi

# Implicit self-test on every cron run. If this fails in production,
# abort BEFORE we can silently misbehave — loud failure beats quiet
# safety-net rot. Best-effort Slack alert (slack_notify is defined
# above this point).
if ! _watchdog_self_test; then
  echo "$LOGPREFIX ABORTING: self-test failed — watchdog is misconfigured." >&2
  slack_notify ":rotating_light: *Watchdog self-test FAILED* on node-8 — watchdog aborted. Fix openclaw-watchdog.sh regex/function order." || true
  exit 1
fi

# Schema validity check (all profiles). Today's outage (2026-05-05) was a
# crash-loop on main caused by an out-of-band write that added schema-
# invalid keys (`subagents`, `agents.llm.idleTimeoutSeconds`, etc.). The
# crash-loop detector below catches restarts but only after journal entries
# accumulate; a fresh schema-invalid config that takes the gateway down
# during a quiet hour produces no agent activity → idle path → silent rot.
# Validate every cron tick instead. The crash-loop alert below has no
# cooldown either, so we match that pattern: alert every 10 min while
# broken (operator can ack/silence in Slack).
for profile in main edge; do
  PROFILE_VALID=$(openclaw --profile "$profile" config validate 2>&1 || true)
  if ! echo "$PROFILE_VALID" | grep -q "Config valid"; then
    log "INVALID CONFIG on profile=${profile}: ${PROFILE_VALID}"
    slack_notify ":rotating_light: *${profile} profile config INVALID* on node-8 — gateway will not start (or will crash-loop). Run \`openclaw --profile ${profile} config validate\` and fix.\n\`\`\`${PROFILE_VALID}\`\`\`"
  fi
done

# Crash loop detection: if systemd has restarted the gateway more than
# 10 times in the last 10 minutes, something is wrong with the config.
# Don't add more restarts — alert and stop.
RESTART_COUNT=$(journalctl -u "$GATEWAY_SERVICE" --since "10 min ago" --no-pager 2>/dev/null \
  | grep -cE "$RESTART_LOG_REGEX" || true)
if [ "${RESTART_COUNT:-0}" -gt 10 ]; then
  log "CRASH LOOP DETECTED: ${RESTART_COUNT} restarts in 10 min — NOT restarting. Check openclaw.json for invalid config."
  slack_notify ":rotating_light: *CRASH LOOP DETECTED* — Gateway restarted ${RESTART_COUNT} times in 10 min. Likely invalid config. NOT restarting. Run \`openclaw doctor --fix\` on node-8."
  exit 0
fi

# Grab recent logs once
RECENT_LOGS=$(journalctl -u "$GATEWAY_SERVICE" --since "${CHECK_WINDOW_MIN} min ago" --no-pager 2>/dev/null || true)

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

# Check if errors are all upstream overloads (Anthropic 529 / OpenRouter 429) — if so,
# don't restart, it won't help.
OVERLOAD_COUNT=$(echo "$RECENT_LOGS" | grep -c 'overloaded_error\|Overloaded\|429.*overloaded\|rate limit reached' 2>/dev/null || true)
OVERLOAD_COUNT=${OVERLOAD_COUNT:-0}

if [ "$SUCCESS_COUNT" -eq 0 ] && [ "$MSG_COUNT" -gt 0 ] && [ "$OVERLOAD_COUNT" -ge "$ERROR_COUNT" ] && [ "$ERROR_COUNT" -gt 0 ]; then
  log "API OVERLOADED: ${OVERLOAD_COUNT} upstream overload errors — NOT restarting (won't help)."
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
  LAST_ERROR=$(journalctl -u "$GATEWAY_SERVICE" --since "${CHECK_WINDOW_MIN} min ago" --no-pager 2>/dev/null \
    | grep 'isError=true' | tail -1 | sed 's/.*error=/error=/' | head -c 200 || echo "unknown")

  # --- Proactive outage notice: post to ALL channels with recent activity ---
  log "Posting outage notice to active channels..."
  python3 /opt/hydra/scripts/outage-notify.py "$LAST_ERROR" 2>/dev/null || true

  log "Restarting openclaw-gateway..."
  systemctl restart "$GATEWAY_SERVICE"

  # Record restart time
  date +%s > "$COOLDOWN_FILE"

  # Wait for startup
  sleep 5

  # Verify it came back
  STATUS=$(systemctl is-active "$GATEWAY_SERVICE" 2>/dev/null || echo "unknown")

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

# --- Edge gateway (support/intercom) health check ---
EDGE_STATUS=$(systemctl is-active openclaw-gateway-edge 2>/dev/null || echo "unknown")
if [ "$EDGE_STATUS" != "active" ]; then
  log "EDGE GATEWAY DOWN: status=${EDGE_STATUS} — attempting restart"

  # Check if it's a config issue (don't restart if config is invalid)
  EDGE_VALID=$(openclaw --profile edge config validate 2>&1 || true)
  if echo "$EDGE_VALID" | grep -q "Config valid"; then
    systemctl restart openclaw-gateway-edge
    sleep 15
    EDGE_NEW=$(systemctl is-active openclaw-gateway-edge 2>/dev/null || echo "unknown")
    if [ "$EDGE_NEW" = "active" ]; then
      log "Edge gateway recovered"
      slack_notify ":white_check_mark: *Edge Gateway* (support/intercom) recovered — auto-restarted by watchdog."
    else
      log "Edge gateway restart FAILED"
      slack_notify ":rotating_light: *Edge Gateway* (support/intercom) DOWN — auto-restart failed. Config may be invalid. Check \`openclaw --profile edge doctor\`."
    fi
  else
    log "Edge config INVALID — not restarting: ${EDGE_VALID}"
    slack_notify ":rotating_light: *Edge Gateway* config invalid — cannot restart. Fix via PR.\n\`${EDGE_VALID}\`"
  fi
fi
