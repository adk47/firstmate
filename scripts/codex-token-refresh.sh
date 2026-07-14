#!/bin/bash
# ──────────────────────────────────────────────────────────────
# codex-token-refresh.sh — scheduled codex OAuth keepalive (the DURABLE fix).
#
# Entry point for the twice-weekly (Sun+Wed) `codex-token-refresh` systemd timer (installed by
# scripts/install-aux-units.sh). Refreshes the codex ChatGPT-OAuth token
# out-of-band via scripts/lib/codex-oauth-refresh.sh, then — ONLY if the refresh
# succeeded — restarts both gateways so they load the fresh token (the gateway
# caches the token at startup and never re-reads the store; the native
# refresh-on-use machinery lives in the deliberately-disabled `openai` plugin).
#
# The codex token lasts ~10 days; twice-weekly runs (Sun+Wed, ~every 3.5d) keep it
# well above expiry (steady-state trough ~6.5d) and survive a single missed run,
# with one brief, predictable, quiet-hour restart each. If the refresh FAILS (e.g. the single-
# use refresh token chain is dead → invalid_grant), codex-oauth-refresh.sh leaves
# the store untouched, pages #clio_devops, and exits non-zero — so we do NOT
# restart (which would only reload the same expiring token), and the every-15-min
# codex-keepalive.sh safety net keeps paging until a human re-auths.
#
# Idempotent and safe to run any time (refreshing early just rotates + re-extends
# the token; this process is the SOLE codex refresher, so there is no race).
# ──────────────────────────────────────────────────────────────
set -euo pipefail

LOGPREFIX="[codex-token-refresh $(date -u +%Y-%m-%dT%H:%M:%SZ)]"
log() { echo "$LOGPREFIX $1"; }

_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REFRESH_BIN="${CODEX_REFRESH_BIN:-$_DIR/lib/codex-oauth-refresh.sh}"
GATEWAY_SERVICES="${CODEX_GATEWAY_SERVICES:-openclaw-gateway-main.service openclaw-gateway-edge.service}"

# Drain-aware restart: even at 04:00 UTC an agent can be mid-turn (crons,
# late-night Intercom); drain first, hard-restart fallback guarantees the
# fresh token still gets loaded (the gateway only reads it at startup).
# shellcheck source=lib/gateway-restart.sh
source "$_DIR/lib/gateway-restart.sh"

# Fallbacks must be LOUD here too: this timer exits 0 after a successful hard
# fallback, so without a page a broken safe path would be visible only in
# journald. Same best-effort pattern as lib/codex-oauth-refresh.sh (slack-notify
# is absent in the bats sandbox; _page degrades to a no-op there unless the
# test injects its own notifier via GATEWAY_FALLBACK_NOTIFY_FN).
if [ -r "$_DIR/lib/slack-notify.sh" ]; then
  # shellcheck source=lib/slack-notify.sh
  source "$_DIR/lib/slack-notify.sh"
fi
_page() { declare -F slack_notify >/dev/null && slack_notify "[codex-token-refresh] $1" || true; }
export GATEWAY_FALLBACK_NOTIFY_FN="${GATEWAY_FALLBACK_NOTIFY_FN:-_page}"

if [ ! -x "$REFRESH_BIN" ]; then
  log "FATAL: refresh helper not executable: $REFRESH_BIN"
  exit 2
fi

log "running scheduled codex OAuth refresh"
if "$REFRESH_BIN"; then
  log "refresh OK — drain-restarting gateways to load the new token: $GATEWAY_SERVICES"
  restart_failed=0
  for service in $GATEWAY_SERVICES; do
    # Profile = last dash-segment of the unit name (main/edge), sans .service.
    profile="${service##*-}"; profile="${profile%.service}"
    if drain_restart_gateway "$service" "$profile"; then
      log "$service restarted"
    else
      restart_failed=1
    fi
  done
  if [ "$restart_failed" -ne 0 ]; then
    # Token is refreshed + persisted; only the reload failed. Fail loud (the unit
    # goes failed) so it's visible; openclaw-watchdog also alerts on a down gateway.
    log "WARN: gateway restart FAILED after a successful refresh — token is fresh but not loaded; the new token takes effect on the next successful (re)start. openclaw-watchdog will alert on a down gateway."
    exit 1
  fi
  log "gateways restarted"
else
  rc=$?
  log "refresh FAILED (rc=$rc) — NOT restarting (store untouched; codex-oauth-refresh.sh already paged). The 15-min keepalive will keep paging until re-auth."
  exit "$rc"
fi
