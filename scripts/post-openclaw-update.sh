#!/bin/bash
# ──────────────────────────────────────────────────────────────
# Post-OpenClaw-Update Hook
#
# Run this after ANY OpenClaw version update on Node 8:
#   bash /opt/hydra/scripts/post-openclaw-update.sh
#
# Re-applies the patches that OpenClaw updates overwrite:
# 1. Mention gate fix (runtime JS)
#
# Tracked upstream:
# - Mention gate: https://github.com/openclaw/openclaw/pull/53161
#
# Retired:
# - Opus 4.7 adaptive-thinking allowlist (landed natively in openclaw 2026.5.5+)
# - Gmail describeMessageTool + monitor patches (plugin deleted — see PR)
# ──────────────────────────────────────────────────────────────
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HYDRA_ROOT="${SCRIPT_DIR}/.."

echo "=== Post-OpenClaw-Update: Re-applying patches ==="

# 1. Mention gate patch (runtime JS — overwritten by openclaw update)
if [ -f "$HYDRA_ROOT/scripts/patch-openclaw-mention-gate.sh" ]; then
    bash "$HYDRA_ROOT/scripts/patch-openclaw-mention-gate.sh"
else
    echo "WARNING: patch-openclaw-mention-gate.sh not found"
fi

echo "=== Post-OpenClaw-Update: Complete ==="
echo "Restart gateway: systemctl restart openclaw-gateway-main"
