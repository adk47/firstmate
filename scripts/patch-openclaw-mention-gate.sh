#!/bin/bash
# ──────────────────────────────────────────────────────────────
# Patch: OpenClaw Slack mention gate bypass for app_mention events
#
# Fixes: https://github.com/openclaw/openclaw/issues/34833
# PR:    https://github.com/openclaw/openclaw/pull/53161
#
# When requireMention: true, the mention gate incorrectly drops
# app_mention events because the text-based mention check fails
# due to dedup race conditions. This patch skips the mention gate
# when the event source is "app_mention" (Slack already confirmed
# the bot was mentioned).
#
# Apply after OpenClaw install/update on Node 8:
#   bash /opt/hydra/scripts/patch-openclaw-mention-gate.sh
#
# Remove this patch once openclaw/openclaw#53161 is merged and
# the fixed version is installed.
# ──────────────────────────────────────────────────────────────
set -euo pipefail

RUNTIME_API=$(find /usr/lib/node_modules/openclaw/dist/ -name "runtime-api-*.js" | head -1)

if [ -z "$RUNTIME_API" ]; then
    echo "ERROR: runtime-api JS file not found in /usr/lib/node_modules/openclaw/dist/"
    exit 1
fi

# Check if already patched
if grep -q 'opts.source !== "app_mention"' "$RUNTIME_API"; then
    echo "SKIP: Patch already applied to $RUNTIME_API"
    exit 0
fi

# Check the target line exists
if ! grep -q 'isRoom && shouldRequireMention && mentionGate.shouldSkip' "$RUNTIME_API"; then
    echo "ERROR: Target line not found — OpenClaw version may have changed. Manual review needed."
    exit 1
fi

# Backup
cp "$RUNTIME_API" "${RUNTIME_API}.bak"

# Apply patch
sed -i 's/if (isRoom && shouldRequireMention && mentionGate.shouldSkip) {/if (isRoom \&\& shouldRequireMention \&\& mentionGate.shouldSkip \&\& opts.source !== "app_mention") {/' "$RUNTIME_API"

# Verify
if grep -q 'opts.source !== "app_mention"' "$RUNTIME_API"; then
    echo "OK: Patch applied to $RUNTIME_API"
    echo "Restart gateway: systemctl restart openclaw-gateway"
else
    echo "ERROR: Patch failed — restoring backup"
    cp "${RUNTIME_API}.bak" "$RUNTIME_API"
    exit 1
fi
