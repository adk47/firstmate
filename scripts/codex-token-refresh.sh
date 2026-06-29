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
SYSTEMCTL_BIN="${SYSTEMCTL_BIN:-systemctl}"
GATEWAY_SERVICES="${CODEX_GATEWAY_SERVICES:-openclaw-gateway-main.service openclaw-gateway-edge.service}"

if [ ! -x "$REFRESH_BIN" ]; then
  log "FATAL: refresh helper not executable: $REFRESH_BIN"
  exit 2
fi

log "running scheduled codex OAuth refresh"
if "$REFRESH_BIN"; then
  log "refresh OK — restarting gateways to load the new token: $GATEWAY_SERVICES"
  # shellcheck disable=SC2086
  if "$SYSTEMCTL_BIN" restart $GATEWAY_SERVICES; then
    log "gateways restarted"
  else
    # Token is refreshed + persisted; only the reload failed. Fail loud (the unit
    # goes failed) so it's visible; openclaw-watchdog also alerts on a down gateway.
    log "WARN: gateway restart FAILED after a successful refresh — token is fresh but not loaded; the new token takes effect on the next successful (re)start. openclaw-watchdog will alert on a down gateway."
    exit 1
  fi
else
  rc=$?
  log "refresh FAILED (rc=$rc) — NOT restarting (store untouched; codex-oauth-refresh.sh already paged). The 15-min keepalive will keep paging until re-auth."
  exit "$rc"
fi
