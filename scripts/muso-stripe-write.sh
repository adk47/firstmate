#!/usr/bin/env bash
# muso-stripe-write.sh — gate Stripe WRITE commands on codex model health.
#
# WHY THIS EXISTS
# The operations agent can autonomously run `stripe refunds create` (moves money).
# It CANNOT perceive when it has been degraded onto a weak fallback model: openclaw's
# `Model Fallback:` banner is built only on the delivery path and is never injected into
# the agent's prompt (see memory reference_agent_cannot_see_own_fallback_state). On
# 2026-06-08 a codex refresh-token race dropped the fleet to openrouter/openai/gpt-5.4-mini
# and that weak model fabricated a fake refund-approval bureaucracy. Wiring the refund skill
# means a future degraded turn could instead execute a *real* but ill-judged refund.
#
# This wrapper is the mechanical guard the SOUL doctrine alone cannot be: before running a
# Stripe write it scans the live gateway journal for the codex auth_permanent / refresh-race
# signature and REFUSES the write while degraded, telling the agent to defer to a human.
# It is FAIL-CLOSED: if model health cannot be verified, it refuses (this is a money path).
#
# Usage:
#   muso-stripe-write.sh refunds create -d "charge=ch_XXX" -d "reason=requested_by_customer" --confirm
# i.e. exactly the args you would pass to `stripe`, minus the leading `stripe`.
#
# Env overrides (mainly for tests):
#   OPENCLAW_GATEWAY_UNIT   systemd unit to scan (default: openclaw-gateway-main)
#   CODEX_HEALTH_WINDOW_MIN journal look-back in minutes (default: 5)
#   STRIPE_BIN              stripe binary (default: stripe)
#   CODEX_HEALTH_LIB        path to codex-health.sh (default: <script-dir>/lib/codex-health.sh)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CODEX_HEALTH_LIB="${CODEX_HEALTH_LIB:-$SCRIPT_DIR/lib/codex-health.sh}"
GATEWAY_UNIT="${OPENCLAW_GATEWAY_UNIT:-openclaw-gateway-main}"
WINDOW_MIN="${CODEX_HEALTH_WINDOW_MIN:-5}"
STRIPE_BIN="${STRIPE_BIN:-stripe}"

# shellcheck source=lib/codex-health.sh
if [ ! -r "$CODEX_HEALTH_LIB" ]; then
  echo "REFUSED (muso-stripe-write): cannot read codex-health lib at $CODEX_HEALTH_LIB" >&2
  exit 3
fi
# shellcheck disable=SC1090
source "$CODEX_HEALTH_LIB"

refuse() {
  echo "REFUSED (muso-stripe-write): $1" >&2
  echo "Did NOT execute the Stripe write. Defer to a human: @-mention Nick (U0AL36NADEY) so he can run it, or retry once codex model health is confirmed." >&2
  exit 3
}

if [ "$#" -eq 0 ]; then
  echo "usage: muso-stripe-write.sh <stripe args...>  (e.g. refunds create -d charge=ch_X --confirm)" >&2
  exit 2
fi

# Live model-health probe. Reading the journal requires the gateway-user privileges the
# agent's exec context has (gateway runs as root). If the read FAILS we cannot confirm
# health → fail closed. An empty-but-readable window is treated as healthy-quiet.
if ! journal="$(journalctl -u "$GATEWAY_UNIT" --since "${WINDOW_MIN} min ago" --no-pager 2>/dev/null)"; then
  refuse "cannot read journald for $GATEWAY_UNIT — codex model health unverifiable"
fi

reused="$(printf '%s\n' "$journal" | codex_count_refresh_reused)"
invalidated="$(printf '%s\n' "$journal" | codex_count_auth_invalidated)"

if [ "${reused:-0}" -gt 0 ] || [ "${invalidated:-0}" -gt 0 ]; then
  refuse "codex is DEGRADED in the last ${WINDOW_MIN}min (refresh-race/auth_permanent=${reused}, auth-invalidated=${invalidated}). A weak fallback model must not move money."
fi

# Healthy → run the real Stripe write.
exec "$STRIPE_BIN" "$@"
