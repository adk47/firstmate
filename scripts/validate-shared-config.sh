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
# OpenRouter remains the fallback inference path across all profiles.
compare_path "models.providers.openrouter.baseUrl" "OpenRouter base URL"
compare_path "models.providers.openrouter.apiKey" "OpenRouter API key"
compare_path "models.providers.openrouter.auth" "OpenRouter auth mode"
# Codex (ChatGPT Pro OAuth) is the primary path for openai/gpt-* model refs.
# Drift between main and edge on these blocks would mean one profile reaches
# OpenAI direct and the other does not — silent provider asymmetry.
compare_path "models.providers.openai" "OpenAI (Codex) provider block"
compare_path "auth.order.openai" "OpenAI auth profile ordering"
compare_path "plugins.entries.codex" "Codex harness plugin enable"

# Explicit agentRuntime pin assertion: this MUST be {id: "codex"} on both profiles.
# Without it, openclaw auto-mode silently falls back to direct OpenAI Platform API
# via OPENAI_API_KEY env, making qa-pilot smoke meaningless (passes via fallback).
# See openclaw bug #81326 + docs.openclaw.ai/concepts/agent-runtimes.
for prof in main edge; do
  pin=$(jq -r '.models.providers.openai.agentRuntime.id // "MISSING"' "openclaw-${prof}.json" 2>/dev/null)
  if [ "$pin" != "codex" ]; then
    fail "openclaw-${prof}.json: models.providers.openai.agentRuntime.id must be \"codex\" (got: $pin)"
  else
    pass "openclaw-${prof}.json: agentRuntime pinned to codex"
  fi
done
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

# --- Caroline RAG safety invariants (added 2026-05-14) ---
# See PR B: feat/caroline-rag-enablement
# Layer 2 (search-tools-only) ships with bundled memory-core. memory-lancedb and
# active-memory are unsafe for our multi-agent gateway today (lancedb claims
# global memory slot, breaking per-agent isolation; active-memory has open
# upstream regressions #77864 / #79026 / #72015 / #79611 as of 2026-05).

caroline_check() {
  local label="$1" expected="$2" actual="$3"
  if [ "$actual" = "$expected" ]; then
    pass "$label = $expected"
  else
    fail "$label expected $expected, got $actual"
  fi
}

# 1. memory-lancedb must NEVER be in plugins.allow (would claim global slot,
#    break per-agent isolation across support / main / ops / cron).
lancedb_present=$(python3 -c "
import json
with open('$EDGE') as f:
    c = json.load(f)
allow = c.get('plugins', {}).get('allow', [])
print('true' if 'memory-lancedb' in allow else 'false')
")
caroline_check "edge.plugins.allow.memory-lancedb-absent" "false" "$lancedb_present"

# 2. active-memory must NEVER be in plugins.allow until upstream regressions
#    are resolved (see openclaw issues #77864, #79026, #72015, #79611).
am_present=$(python3 -c "
import json
with open('$EDGE') as f:
    c = json.load(f)
allow = c.get('plugins', {}).get('allow', [])
print('true' if 'active-memory' in allow else 'false')
")
caroline_check "edge.plugins.allow.active-memory-absent" "false" "$am_present"

# 3. memory-core dreaming must remain disabled (upstream issues #63921 PII,
#    #65374 cross-agent contamination, #65550 runaway loop, #66947 daily-file
#    pollution).
dreaming_enabled=$(python3 -c "
import json
with open('$EDGE') as f:
    c = json.load(f)
try:
    v = c['plugins']['entries']['memory-core']['config']['dreaming']['enabled']
    print('true' if v is True else 'false')
except KeyError:
    print('false')
")
caroline_check "edge.memory-core.dreaming.enabled" "false" "$dreaming_enabled"

# 4. support agent memorySearch.extraPaths must be exactly ["reference"] (no
#    sessions/, tickets/, api-logs/, or any other dir that could leak customer
#    transcripts into the indexed corpus).
extra_paths=$(python3 -c "
import json
with open('$EDGE') as f:
    c = json.load(f)
support = next((a for a in c.get('agents', {}).get('list', []) if a.get('id') == 'support'), {})
paths = support.get('memorySearch', {}).get('extraPaths', [])
print(json.dumps(paths))
")
caroline_check "edge.support.memorySearch.extraPaths" '["reference"]' "$extra_paths"

# 5. Session scope must remain per-channel-peer for per-conversation isolation.
dmscope=$(python3 -c "
import json
with open('$EDGE') as f:
    c = json.load(f)
print(json.dumps(c.get('session', {}).get('dmScope', '')))
")
caroline_check "edge.session.dmScope" '"per-channel-peer"' "$dmscope"

# --- Parity checks on MAIN ---
# Profile-level memory safety invariants (memory-lancedb / active-memory /
# dreaming) must hold on main as well as edge — main runs the other 9 agents
# and the same memory plugin gotchas apply. (The support-specific memorySearch
# check is edge-only since support no longer lives on main.)

# 6. memory-lancedb absent from main plugins.allow.
main_lancedb=$(python3 -c "
import json
with open('$MAIN') as f:
    c = json.load(f)
allow = c.get('plugins', {}).get('allow', [])
print('true' if 'memory-lancedb' in allow else 'false')
")
caroline_check "main.plugins.allow.memory-lancedb-absent" "false" "$main_lancedb"

# 7. active-memory absent from main plugins.allow.
main_am=$(python3 -c "
import json
with open('$MAIN') as f:
    c = json.load(f)
allow = c.get('plugins', {}).get('allow', [])
print('true' if 'active-memory' in allow else 'false')
")
caroline_check "main.plugins.allow.active-memory-absent" "false" "$main_am"

# 8. memory-core dreaming disabled on main.
main_dreaming=$(python3 -c "
import json
with open('$MAIN') as f:
    c = json.load(f)
try:
    v = c['plugins']['entries']['memory-core']['config']['dreaming']['enabled']
    print('true' if v is True else 'false')
except KeyError:
    print('false')
")
caroline_check "main.memory-core.dreaming.enabled" "false" "$main_dreaming"

# (Removed: main.support.memorySearch.extraPaths check — support agent
# was removed from main and consolidated onto edge. Edge's check #4 above
# still enforces the invariant; there is no longer a main/support to drift.)

# 10. main session dmScope must match edge (per-conversation isolation).
main_dmscope=$(python3 -c "
import json
with open('$MAIN') as f:
    c = json.load(f)
print(json.dumps(c.get('session', {}).get('dmScope', '')))
")
caroline_check "main.session.dmScope" '"per-channel-peer"' "$main_dmscope"

echo ""
if [[ "$FAILURES" -eq 0 ]]; then
  echo "All shared settings match."
  exit 0
else
  echo "FAILED: $FAILURES shared setting(s) have drifted. Deploy blocked."
  exit 1
fi
