#!/usr/bin/env bash
# muso-prewrite-hook.sh — muso CLI pre-write hook: live model-health gate.
#
# The muso CLI (skills-all/muso-cli) execs this before EVERY admin-API
# write (POST/PUT/PATCH/DELETE; reads never reach the hook) with args:
# <METHOD> <PATH> <ENV>. Wired via /root/.config/muso/config.json
# ("prewrite_hook"), which deploy.sh renders on every deploy.
#   Exit 0   → the write proceeds.
#   Exit !=0 → muso refuses the write (its exit 5) and surfaces this
#              script's stderr as the reason.
#
# It runs the SAME live codex-health probe as scripts/muso-stripe-write.sh
# and skills-all/muso-ops-admin/scripts/muso-admin-api.sh (incident
# 2026-06-08: a silently-degraded fallback model must not perform
# state-changing writes). FAIL-CLOSED like the money path: an unreadable
# lib and an unverifiable journal both refuse; an empty-but-readable
# window is healthy-quiet. Deliberately NO caller-settable bypass — the
# degraded model this guards against must not be able to disable it. That
# is why, unlike muso-stripe-write.sh, the lib path / unit / window are
# HARDCODED rather than env knobs: an env knob would let the caller point
# the probe at a stub lib or a quiet unit and pass while degraded. Tests
# stub `journalctl` on PATH instead — the lib invokes it by name for
# exactly that reason.
set -euo pipefail

# Slack sends are the alerting path, not admin-API writes: the codex-health
# gate below guards state-changing core/stripe writes, and blocking Slack
# during a codex outage would suppress the very page about that outage
# (muso sets MUSO_HOOK_PROVIDER so one hook can branch per backend).
if [ "${MUSO_HOOK_PROVIDER:-}" = "slack" ]; then
  exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CODEX_HEALTH_LIB="$SCRIPT_DIR/lib/codex-health.sh"
GATEWAY_UNIT="openclaw-gateway-main"
WINDOW_MIN="5"

if [ ! -r "$CODEX_HEALTH_LIB" ]; then
  echo "REFUSED (muso-prewrite-hook): cannot read codex-health lib at $CODEX_HEALTH_LIB" >&2
  exit 3
fi
# shellcheck disable=SC1090
source "$CODEX_HEALTH_LIB"

# The <METHOD> <PATH> <ENV> args are informational only: muso already
# exempts reads, and the health verdict does not depend on the endpoint.
if ! reason="$(codex_health_gate "$GATEWAY_UNIT" "$WINDOW_MIN" 2>&1)"; then
  echo "REFUSED (muso-prewrite-hook): ${reason:-codex health gate returned non-zero}" >&2
  echo "Model health is degraded or unverifiable — admin writes are blocked. Retry once codex health is confirmed, or defer to a human." >&2
  exit 3
fi
exit 0
