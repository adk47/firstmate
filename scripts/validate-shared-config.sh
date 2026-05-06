#!/usr/bin/env bash
set -euo pipefail

# Validate shared settings match across all gateway configs.
# This is a HARD FAIL-GATE in CI — drift = blocked deploy.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HYDRA_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

MAIN="$HYDRA_ROOT/openclaw-main.json"
EDGE="$HYDRA_ROOT/openclaw-edge.json"
FAILURES=0

fail() { echo "DRIFT: $*"; FAILURES=$((FAILURES + 1)); }
pass() { echo "OK: $*"; }

# Compare a JSON path across both gateway configs
compare_path() {
  local path="$1"
  local label="$2"
  local main_val edge_val

  extract() {
    python3 -c "
import json
with open('$1') as f:
    c = json.load(f)
keys = '$path'.split('.')
v = c
for k in keys:
    v = v.get(k, {})
print(json.dumps(v, sort_keys=True))
" 2>/dev/null
  }

  main_val=$(extract "$MAIN")
  edge_val=$(extract "$EDGE")

  # Catch missing paths (extract returns {} for nonexistent keys)
  if [[ "$main_val" == "{}" ]]; then
    fail "$label missing from main config"
    return
  fi

  if [[ "$main_val" == "$edge_val" ]]; then
    pass "$label"
  else
    fail "$label differs between configs"
    echo "  main: $main_val"
    echo "  edge: $edge_val"
  fi
}

echo "Validating shared config across main and edge..."
echo ""

# Shared settings that MUST match
# OpenRouter is the sole inference path across all profiles.
compare_path "models.providers.openrouter.baseUrl" "OpenRouter base URL"
compare_path "models.providers.openrouter.apiKey" "OpenRouter API key"
compare_path "models.providers.openrouter.auth" "OpenRouter auth mode"
compare_path "messages.queue" "Message queue config"
compare_path "messages.ackReaction" "Message ack reaction"
compare_path "messages.ackReactionScope" "Message ack reaction scope"
compare_path "gateway.auth" "Gateway auth config"
compare_path "gateway.trustedProxies" "Trusted proxies"
compare_path "gateway.controlUi.allowedOrigins" "Control UI allowed origins"
compare_path "tools.exec" "Tools exec security config"
# Bootstrap truncation guardrail (hydra issue #165). All three profiles
# must share the same cap + warning level; a silent drop to the openclaw
# default (12000 / "once") would reintroduce the original bug.
compare_path "agents.defaults.bootstrapMaxChars" "Bootstrap per-file cap"
compare_path "agents.defaults.bootstrapTotalMaxChars" "Bootstrap total cap"
compare_path "agents.defaults.bootstrapPromptTruncationWarning" "Bootstrap truncation warning mode"

echo ""
if [[ "$FAILURES" -eq 0 ]]; then
  echo "All shared settings match."
  exit 0
else
  echo "FAILED: $FAILURES shared setting(s) have drifted. Deploy blocked."
  exit 1
fi
