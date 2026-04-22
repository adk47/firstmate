#!/bin/bash
# ──────────────────────────────────────────────────────────────
# Patch: OpenClaw adaptive-thinking allowlist — add Opus 4.7
#
# Fixes:
#   - https://github.com/openclaw/openclaw/issues/67888
#   - https://github.com/openclaw/openclaw/issues/68078
#
# Problem (on openclaw@2026.4.15):
#   supportsAdaptiveThinking() only recognizes opus-4-6 / sonnet-4-6
#   as adaptive-thinking models. For anthropic/claude-opus-4-7 the
#   adapter falls through to the legacy
#     thinking: { type: "enabled", budget_tokens: N }
#   shape which Opus 4.7 no longer accepts. Every first-turn
#   request returns:
#     400 "thinking.type.enabled" is not supported for this model.
#     Use "thinking.type.adaptive" and "output_config.effort".
#   The in-process retry-with-thinking-off path eventually replies,
#   but the errored initial attempt trips the watchdog
#   (scripts/openclaw-watchdog.sh) which restarts the gateway and
#   re-triggers the user's @mention via retrigger-unanswered.py —
#   producing duplicate replies.
#
# Two files contain the allowlist:
#   1. openclaw's bundled adapter:
#      /usr/lib/node_modules/openclaw/dist/anthropic-vertex-stream-*.js
#      (direct-Anthropic transport, despite the "vertex" filename)
#   2. @mariozechner/pi-ai (used by the embedded agent runner):
#      /usr/lib/node_modules/openclaw/node_modules/@mariozechner/pi-ai/dist/providers/anthropic.js
#
# Apply after every `npm upgrade openclaw` on node-8:
#   bash /opt/hydra/scripts/post-openclaw-update.sh
#
# Remove this script once BOTH openclaw and pi-ai ship releases
# that include opus-4-7 in supportsAdaptiveThinking() natively.
# ──────────────────────────────────────────────────────────────
set -euo pipefail

run_patch() {
    local file="$1"
    shift
    # Remaining args: before1 after1 before2 after2 (all literal strings; multi-line OK)
    python3 - "$file" "$@" <<'PY'
import sys, pathlib
path, b1, a1, b2, a2 = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5]
p = pathlib.Path(path)
src = p.read_text()

# Idempotency: if opus-4-7 already appears near either allowlist site, skip.
if 'opus-4-7' in src:
    print(f"SKIP: {path} already contains opus-4-7")
    sys.exit(0)

if src.count(b1) != 1:
    sys.exit(f"ERROR: BEFORE_1 occurrence in {path} = {src.count(b1)} (expected 1). Version may have changed.")
if src.count(b2) != 1:
    sys.exit(f"ERROR: BEFORE_2 occurrence in {path} = {src.count(b2)} (expected 1). Version may have changed.")

backup = path + ".bak"
pathlib.Path(backup).write_text(src)

new_src = src.replace(b1, a1).replace(b2, a2)
if 'opus-4-7' not in new_src:
    sys.exit(f"ERROR: replacement did not land in {path}")
p.write_text(new_src)
print(f"OK: Patched {path} (backup: {backup})")
PY
}

# ───── File 1: openclaw bundled adapter (single-line BEFORE) ─────
OC_FILE=$(find /usr/lib/node_modules/openclaw/dist/ -name "anthropic-vertex-stream-*.js" | head -1)
if [ -z "$OC_FILE" ]; then
    echo "ERROR: anthropic-vertex-stream-*.js not found"
    exit 1
fi

OC_BEFORE_1='return modelId.includes("opus-4-6") || modelId.includes("opus-4.6") || modelId.includes("sonnet-4-6") || modelId.includes("sonnet-4.6");'
OC_AFTER_1='return modelId.includes("opus-4-6") || modelId.includes("opus-4.6") || modelId.includes("opus-4-7") || modelId.includes("opus-4.7") || modelId.includes("sonnet-4-6") || modelId.includes("sonnet-4.6");'
OC_BEFORE_2='case "xhigh": return modelId.includes("opus-4-6") || modelId.includes("opus-4.6") ? "max" : "high";'
OC_AFTER_2='case "xhigh": return modelId.includes("opus-4-6") || modelId.includes("opus-4.6") || modelId.includes("opus-4-7") || modelId.includes("opus-4.7") ? "max" : "high";'

run_patch "$OC_FILE" "$OC_BEFORE_1" "$OC_AFTER_1" "$OC_BEFORE_2" "$OC_AFTER_2"

# ───── File 2: pi-ai provider (multi-line BEFORE) ─────
PIAI_FILE="/usr/lib/node_modules/openclaw/node_modules/@mariozechner/pi-ai/dist/providers/anthropic.js"
if [ ! -f "$PIAI_FILE" ]; then
    echo "ERROR: pi-ai anthropic.js not found at $PIAI_FILE"
    exit 1
fi

PIAI_BEFORE_1='return (modelId.includes("opus-4-6") ||
        modelId.includes("opus-4.6") ||
        modelId.includes("sonnet-4-6") ||
        modelId.includes("sonnet-4.6"));'
PIAI_AFTER_1='return (modelId.includes("opus-4-6") ||
        modelId.includes("opus-4.6") ||
        modelId.includes("opus-4-7") ||
        modelId.includes("opus-4.7") ||
        modelId.includes("sonnet-4-6") ||
        modelId.includes("sonnet-4.6"));'
PIAI_BEFORE_2='return modelId.includes("opus-4-6") || modelId.includes("opus-4.6") ? "max" : "high";'
PIAI_AFTER_2='return modelId.includes("opus-4-6") || modelId.includes("opus-4.6") || modelId.includes("opus-4-7") || modelId.includes("opus-4.7") ? "max" : "high";'

run_patch "$PIAI_FILE" "$PIAI_BEFORE_1" "$PIAI_AFTER_1" "$PIAI_BEFORE_2" "$PIAI_AFTER_2"

echo "=== Patch complete. Restart gateway: systemctl restart openclaw-gateway-main ==="
