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

# Edge Codex (Caroline) silent-degradation watch. Runs on EVERY tick,
# independent of the success/idle/restart logic below (Caroline can be busy
# and failing while main is idle). Caroline = the support agent on edge,
# primary openai/gpt-5.5 via the Codex agentRuntime, with an
# openrouter/sonnet text fallback AND an agents.defaults.imageModel vision
# pin. Those fallbacks mean a Codex auth failure does NOT take her down —
# she SILENTLY degrades (text -> sonnet, the gpt-5.5 upgrade lost) and, on
# vision exhaustion, loses image understanding. None of that surfaces in the
# config-validate counters above. Codex auth on edge does NOT log
# reason=auth; it logs the literal OAuth string and the image/pdf
# "All image models failed" summary — see scripts/lib/codex-health.sh.
# shellcheck source=lib/codex-health.sh
source "$_WATCHDOG_DIR/lib/codex-health.sh"

EDGE_AUTH_PROFILES="/root/.openclaw-edge/agents/support/agent/auth-profiles.json"
CODEX_COOLDOWN_MIN=60  # token rotation is ~10-day; hourly re-alert is plenty

# _codex_cooldown_ok <stampfile> <minutes> — true if last alert older than N min.
_codex_cooldown_ok() {
  local f="$1" mins="$2" last now
  [ -f "$f" ] || return 0
  last=$(cat "$f" 2>/dev/null || echo 0)
  now=$(date +%s)
  [ "$(( (now - last) / 60 ))" -ge "$mins" ]
}

EDGE_LOGS=$(journalctl -u openclaw-gateway-edge --since "${CHECK_WINDOW_MIN} min ago" --no-pager 2>/dev/null || true)
CODEX_AUTHFAIL=$(printf '%s\n' "$EDGE_LOGS" | codex_count_auth_invalidated)
CODEX_VISIONFAIL=$(printf '%s\n' "$EDGE_LOGS" | codex_count_vision_failures)

if [ "${CODEX_AUTHFAIL:-0}" -gt 0 ] && _codex_cooldown_ok /tmp/openclaw-watchdog-codex-auth-cooldown "$CODEX_COOLDOWN_MIN"; then
  log "EDGE CODEX AUTH DEAD: ${CODEX_AUTHFAIL} 'token invalidated' lines in last ${CHECK_WINDOW_MIN}min"
  slack_notify ":rotating_light: *Edge Codex auth FAILING* (Caroline/support) — ${CODEX_AUTHFAIL}x 'authentication token has been invalidated' in last ${CHECK_WINDOW_MIN}min. She has silently degraded to the sonnet text fallback (replies still work; gpt-5.5 upgrade lost) — this is the #356 shape. The edge auth symlink self-heals on \`systemctl restart openclaw-gateway-edge\` (ExecStartPre re-points it at a fresh main codex token via ensure-codex-auth). If it keeps firing after a restart, the main codex token is itself stale → re-auth codex on main."
  date +%s > /tmp/openclaw-watchdog-codex-auth-cooldown
fi

if [ "${CODEX_VISIONFAIL:-0}" -gt 0 ] && _codex_cooldown_ok /tmp/openclaw-watchdog-codex-vision-cooldown "$CODEX_COOLDOWN_MIN"; then
  log "EDGE VISION DOWN: ${CODEX_VISIONFAIL} 'All image models failed' lines in last ${CHECK_WINDOW_MIN}min"
  slack_notify ":rotating_light: *Edge vision DOWN* (Caroline/support) — ${CODEX_VISIONFAIL}x 'All image models failed' in last ${CHECK_WINDOW_MIN}min. Customers sending screenshots/PDFs get no image understanding. imageModel is codex/gpt-5.5 → openrouter gemini → haiku, so this means codex AND both OpenRouter fallbacks failed — check OPENROUTER_API_KEY, codex auth, and \`openclaw --profile edge config validate\`."
  date +%s > /tmp/openclaw-watchdog-codex-vision-cooldown
fi

# Symlink-integrity tripwire: edge auth durability rests on
# auth-profiles.json being a symlink to main's canonical codex token. A deploy
# clobbering it (regular file), a dangling link, or a missing store all silently
# re-introduce #356 — alert before it bites. (We do NOT alert on token expiry:
# the codex access token is ~9h-lived + refresh-on-use, so its `expires` carries
# no human-re-auth signal — a real auth death is caught by the
# `authentication token has been invalidated` tripwire above. See codex-health.sh.)
CODEX_SYMLINK_STATUS=$(codex_edge_auth_symlink_status "$EDGE_AUTH_PROFILES")
if [ "$CODEX_SYMLINK_STATUS" != "ok" ] && _codex_cooldown_ok /tmp/openclaw-watchdog-codex-symlink-cooldown "$CODEX_COOLDOWN_MIN"; then
  log "EDGE CODEX AUTH SYMLINK status=${CODEX_SYMLINK_STATUS}"
  slack_notify ":warning: *Edge Codex auth store* (Caroline/support) symlink status: \`${CODEX_SYMLINK_STATUS}\` (expected \`ok\`). not-symlink=a deploy clobbered it; dangling=main source moved; missing=never provisioned. \`systemctl restart openclaw-gateway-edge\` re-runs ensure-codex-auth (ExecStartPre) to re-point it at main's canonical codex token."
  date +%s > /tmp/openclaw-watchdog-codex-symlink-cooldown
fi

# ── Cross-process Codex refresh-race watch (main + edge) ──────────────────────
# 2026-06-08 outage: main AND edge both refresh the ONE shared codex token, but
# openclaw's refresh lock is per-state-dir, so the two processes raced at the
# 5-min pre-expiry margin → one rotated the single-use token, the loser POSTed
# the spent one → `refresh_token_reused` → the WHOLE codex fleet fell back to
# openrouter/openai/gpt-5.4-mini for 3.5h with NO alert (the auth tripwire above
# keys on a different string AND reads only the edge journal; today's 401s were
# on main, and a codex→openrouter fallback completes isError=false so the generic
# counters below never trip). Scan BOTH gateway journals for the refresh-race
# signature, and verify the lock-dir convergence that PREVENTS it is still live.
MAIN_CODEX_LOGS=$(journalctl -u openclaw-gateway-main --since "${CHECK_WINDOW_MIN} min ago" --no-pager 2>/dev/null || true)
CODEX_REFRESH_RACE=$(printf '%s\n%s\n' "$MAIN_CODEX_LOGS" "$EDGE_LOGS" | codex_count_refresh_reused)

if [ "${CODEX_REFRESH_RACE:-0}" -gt 0 ] && _codex_cooldown_ok /tmp/openclaw-watchdog-codex-refresh-cooldown "$CODEX_COOLDOWN_MIN"; then
  log "CODEX REFRESH RACE: ${CODEX_REFRESH_RACE} refresh_token_reused/auth_permanent lines (main+edge) in last ${CHECK_WINDOW_MIN}min"
  slack_notify ":rotating_light: *Codex refresh-token race* — ${CODEX_REFRESH_RACE}x \`refresh_token_reused\`/\`auth_permanent\` across main+edge in last ${CHECK_WINDOW_MIN}min. The ENTIRE codex fleet (gpt-5.5) has degraded to \`openrouter/openai/gpt-5.4-mini\`. The single-use refresh token is spent → this needs *interactive re-auth*: \`openclaw --profile main models auth login --provider openai-codex --device-code\` for BOTH accounts (aaron@muso.ai, aaronkaufman@me.com), then \`systemctl restart openclaw-gateway-main openclaw-gateway-edge\`. Prevention is the lock-dir convergence (ensure-codex-refresh-lock-shared.sh) — see the tripwire below."
  date +%s > /tmp/openclaw-watchdog-codex-refresh-cooldown
fi

# Convergence tripwire: if the two processes' refresh-lock dirs are no longer ONE
# shared physical dir, the race can recur on the next (~daily) refresh — alert
# BEFORE it bites. --check is read-only: exit 1 = not converged (CONV_OUT names
# the offenders). Guarded under `if !` so set -e never fires on the exit 1.
if [ -x "$_WATCHDOG_DIR/lib/ensure-codex-refresh-lock-shared.sh" ]; then
  if ! CONV_OUT=$("$_WATCHDOG_DIR/lib/ensure-codex-refresh-lock-shared.sh" --check 2>&1) \
     && _codex_cooldown_ok /tmp/openclaw-watchdog-codex-lockconv-cooldown "$CODEX_COOLDOWN_MIN"; then
    log "CODEX REFRESH-LOCK NOT CONVERGED: ${CONV_OUT}"
    slack_notify ":warning: *Codex refresh-lock convergence broke* on node-8 — the main & edge gateways' \`locks/oauth-refresh/\` are no longer one shared dir, so a concurrent codex refresh can race again (the 2026-06-08 \`refresh_token_reused\` outage). \`systemctl restart openclaw-gateway-edge\` re-runs the ExecStartPre healer to reconverge, or run \`scripts/lib/ensure-codex-refresh-lock-shared.sh\` on node-8.\n\`\`\`${CONV_OUT}\`\`\`"
    date +%s > /tmp/openclaw-watchdog-codex-lockconv-cooldown
  fi
fi

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
