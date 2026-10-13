#!/bin/bash
# ──────────────────────────────────────────────────────────────
# Post-OpenClaw-Update Hook
#
# Run this after ANY OpenClaw version update on Node 8:
#   bash /opt/hydra/scripts/post-openclaw-update.sh
#
# Re-applies the patches that OpenClaw updates overwrite:
# 1. Non-interrupting inactive-session deletion (runtime JS) — skipped on
#    openclaw >=2026.8 (retired-pending-reevaluation on 2.0, see
#    docs/runbooks/UPGRADE-2026.8.1.md; mirrors the same gate in deploy.sh).
# 2. a2a announce flow escapes the prepared-model-runtime generation scope
#    (MUS-6707) — runs on every runtime, including >=2026.8.
# The historical mention-gate patch is retired on current versions and is not run.
#
# Retired:
# - Codex-native automatic compaction (upstream #95831 ships it natively in
#   the 2026.8.1 dist — verified; scripts/patch-openclaw-codex-native-compaction.sh
#   is deleted, do not reintroduce)
# - Mention gate (landed natively in current OpenClaw releases)
# - Opus 4.7 adaptive-thinking allowlist (landed natively in openclaw 2026.5.5+)
# - Gmail describeMessageTool + monitor patches (plugin deleted — see PR)
# ──────────────────────────────────────────────────────────────
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HYDRA_ROOT="${SCRIPT_DIR}/.."

# shellcheck source=lib/version-compare.sh
source "$SCRIPT_DIR/lib/version-compare.sh"

echo "=== Post-OpenClaw-Update: Re-applying patches ==="

runtime_ver="$(openclaw_runtime_version)"
if [ -z "$runtime_ver" ]; then
    # An unknown runtime is NOT a pre-2026.8 runtime. Falling through to the
    # patch here would let a temporarily broken/malformed CLI on a 2.0 install
    # mutate the 2.0 dist with a patch this repo retired for exactly that
    # runtime. Refuse; apply only after positively proving a pre-2026.8 version.
    echo "ERROR: cannot determine the openclaw runtime version (\`openclaw --version\` returned nothing/unparseable)." >&2
    echo "       Refusing to apply any dist patch on an unidentified runtime. Fix the CLI, then re-run." >&2
    exit 1
elif version_at_least "2026.8" "$runtime_ver"; then
    echo "openclaw ${runtime_ver} >= 2026.8 — inactive-session-delete dist patch is"
    echo "retired-pending-reevaluation on 2.0, skipping (docs/runbooks/UPGRADE-2026.8.1.md)"
else
    # Non-interrupting inactive-session deletion (runtime JS — overwritten by update)
    if [ -f "$HYDRA_ROOT/scripts/patch-openclaw-inactive-session-delete.sh" ]; then
        OPENCLAW_DIST_DIR=/usr/lib/node_modules/openclaw/dist \
            bash "$HYDRA_ROOT/scripts/patch-openclaw-inactive-session-delete.sh"
    else
        echo "ERROR: patch-openclaw-inactive-session-delete.sh not found"
        exit 1
    fi
fi

# a2a announce flow escapes the prepared-model-runtime generation scope (MUS-6707).
# Not version-gated: it targets the 2.0 runtime the block above skips.
if [ -f "$HYDRA_ROOT/scripts/patch-openclaw-a2a-generation-scope.sh" ]; then
    OPENCLAW_DIST_DIR=/usr/lib/node_modules/openclaw/dist \
        bash "$HYDRA_ROOT/scripts/patch-openclaw-a2a-generation-scope.sh"
else
    echo "ERROR: patch-openclaw-a2a-generation-scope.sh not found"
    exit 1
fi

echo "=== Post-OpenClaw-Update: Complete ==="
echo "Restart gateways: systemctl restart openclaw-gateway-main openclaw-gateway-edge"
