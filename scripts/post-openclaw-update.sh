#!/bin/bash
# ──────────────────────────────────────────────────────────────
# Post-OpenClaw-Update Hook
#
# Run this after ANY OpenClaw version update on Node 8:
#   bash /opt/hydra/scripts/post-openclaw-update.sh
#
# Re-applies all patches that OpenClaw updates overwrite:
# 1. Mention gate fix (runtime JS)
# 2. Opus 4.7 adaptive-thinking allowlist (bundled adapter JS)
# 3. Gmail plugin describeMessageTool (plugin TS)
# 4. Gmail monitor initialization resilience (plugin TS)
#
# These patches are tracked upstream:
# - Mention gate: https://github.com/openclaw/openclaw/pull/53161
# - Opus 4.7 thinking: https://github.com/openclaw/openclaw/issues/67888, #68078
# - Gmail plugin: https://github.com/mcinteerj/openclaw-gmail/issues/4
#
# Remove individual patches as upstream fixes are merged.
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

# 2. Opus 4.7 adaptive-thinking allowlist (openclaw#67888, #68078)
if [ -f "$HYDRA_ROOT/scripts/patch-openclaw-opus-4-7-thinking.sh" ]; then
    bash "$HYDRA_ROOT/scripts/patch-openclaw-opus-4-7-thinking.sh"
else
    echo "WARNING: patch-openclaw-opus-4-7-thinking.sh not found"
fi

# 3. Gmail plugin describeMessageTool
GMAIL_CHANNEL="/root/.openclaw/extensions/openclaw-gmail/src/channel.ts"
if [ -f "$GMAIL_CHANNEL" ]; then
    if ! grep -q "describeMessageTool" "$GMAIL_CHANNEL"; then
        sed -i 's/listActions: () => \["send"\],/listActions: () => ["send"],\n    describeMessageTool: () => ({ actions: ["send"], capabilities: ["send"] }),/' "$GMAIL_CHANNEL"
        echo "OK: Patched Gmail describeMessageTool"
    else
        echo "SKIP: Gmail describeMessageTool already patched"
    fi
fi

# 4. Gmail monitor — bypass gog CLI check (API backend doesn't need it)
GMAIL_MONITOR="/root/.openclaw/extensions/openclaw-gmail/src/monitor.ts"
if [ -f "$GMAIL_MONITOR" ]; then
    if grep -q 'account.backend !== "api" && !(await GogGmailClient.checkExists())' "$GMAIL_MONITOR" && ! grep -q "PATCHED" "$GMAIL_MONITOR"; then
        sed -i 's|if (account.backend !== "api" && !(await GogGmailClient.checkExists())) {|if (false \&\& account.backend !== "api" \&\& !(await GogGmailClient.checkExists())) { // PATCHED: skip gog check|' "$GMAIL_MONITOR"
        echo "OK: Patched Gmail monitor gog CLI check"
    else
        echo "SKIP: Gmail monitor gog check already patched"
    fi
    # Also wrap init calls in try/catch
    if grep -q "^  await ensureQuarantineLabel(client, log);" "$GMAIL_MONITOR"; then
        sed -i '/^  await ensureQuarantineLabel(client, log);/c\  try { await ensureQuarantineLabel(client, log); } catch (e) { log.warn(`Quarantine label setup failed: ${String(e)}`); }' "$GMAIL_MONITOR"
        sed -i '/^  await pruneGmailSessions(account, log);/c\  try { await pruneGmailSessions(account, log); } catch (e) { log.warn(`Prune failed: ${String(e)}`); }' "$GMAIL_MONITOR"
        echo "OK: Patched Gmail monitor initialization resilience"
    fi
fi

echo "=== Post-OpenClaw-Update: Complete ==="
echo "Restart gateway: systemctl restart openclaw-gateway-main"
