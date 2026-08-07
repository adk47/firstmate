#!/bin/bash
# ──────────────────────────────────────────────────────────────
# Post-OpenClaw-Update Hook
#
# Run this after ANY OpenClaw version update on Node 8:
#   bash /opt/hydra/scripts/post-openclaw-update.sh
#
# Re-applies the patches that OpenClaw updates overwrite:
# 1. Codex-native automatic compaction fix (runtime JS)
# The historical mention-gate patch is retired on current versions and is not run.
#
# Retired:
# - Mention gate (landed natively in current OpenClaw releases)
# - Opus 4.7 adaptive-thinking allowlist (landed natively in openclaw 2026.5.5+)
# - Gmail describeMessageTool + monitor patches (plugin deleted — see PR)
# ──────────────────────────────────────────────────────────────
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HYDRA_ROOT="${SCRIPT_DIR}/.."

echo "=== Post-OpenClaw-Update: Re-applying patches ==="

# 1. Codex-native automatic compaction patch (runtime JS — overwritten by update)
if [ -f "$HYDRA_ROOT/scripts/patch-openclaw-codex-native-compaction.sh" ]; then
    OPENCLAW_DIST_DIR=/usr/lib/node_modules/openclaw/dist \
        bash "$HYDRA_ROOT/scripts/patch-openclaw-codex-native-compaction.sh"
else
    echo "ERROR: patch-openclaw-codex-native-compaction.sh not found"
    exit 1
fi

echo "=== Post-OpenClaw-Update: Complete ==="
echo "Restart gateways: systemctl restart openclaw-gateway-main openclaw-gateway-edge"
