#!/usr/bin/env bash
set -euo pipefail

# HYDRA Deploy Script
# ===================
# CD entrypoint: validate config, sync to Node 8, restart gateway, smoke test.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HYDRA_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

SSH_KEY="${SSH_KEY:-$HOME/.ssh/ovh_muso}"
NODE8_IP="${NODE8_IP:-10.0.0.8}"
NODE8_USER="${NODE8_USER:-root}"
DEPLOY_PATH="${DEPLOY_PATH:-/opt/hydra}"
NAMESPACE="${NAMESPACE:-hydra}"
SLACK_WEBHOOK="${HYDRA_SLACK_WEBHOOK:-}"
KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"

log() { echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] $*"; }
fail() { log "FATAL: $*"; notify_slack ":x: HYDRA deploy FAILED: $*"; exit 1; }

notify_slack() {
  if [[ -n "$SLACK_WEBHOOK" ]]; then
    curl -sf -X POST "$SLACK_WEBHOOK" \
      -H 'Content-Type: application/json' \
      -d "{\"channel\": \"#hydra-heartbeat\", \"text\": \"$1\"}" >/dev/null 2>&1 || true
  fi
}

# -------------------------------------------------------------------
# Step 1: Validate openclaw.json
# -------------------------------------------------------------------
log "Step 1/7: Validating openclaw.json..."
if ! python3 -m json.tool "$HYDRA_ROOT/openclaw.json" >/dev/null 2>&1; then
  fail "openclaw.json is not valid JSON"
fi
log "  openclaw.json is valid JSON."

# -------------------------------------------------------------------
# Step 2: Validate all SOUL.md files exist
# -------------------------------------------------------------------
log "Step 2/7: Validating SOUL.md files..."
AGENTS=$(python3 -c "
import json, sys
with open('$HYDRA_ROOT/openclaw.json') as f:
    config = json.load(f)
for agent in config.get('agents', []):
    print(agent.get('id', ''))
")

MISSING_SOULS=()
for agent in $AGENTS; do
  soul_path="$HYDRA_ROOT/workspaces/$agent/SOUL.md"
  if [[ ! -f "$soul_path" ]]; then
    MISSING_SOULS+=("$agent")
  fi
done

if [[ ${#MISSING_SOULS[@]} -gt 0 ]]; then
  fail "Missing SOUL.md for agents: ${MISSING_SOULS[*]}"
fi
log "  All SOUL.md files present."

# -------------------------------------------------------------------
# Step 3: Validate tool-deny-lists.yaml (denials only grow)
# -------------------------------------------------------------------
log "Step 3/7: Validating tool-deny-lists.yaml (deny lists can only grow)..."
DENY_LIST="$HYDRA_ROOT/policies/tool-deny-lists.yaml"

if [[ ! -f "$DENY_LIST" ]]; then
  fail "policies/tool-deny-lists.yaml not found"
fi

# Compare against the last committed version — removals are forbidden
if git -C "$HYDRA_ROOT" show HEAD:"policies/tool-deny-lists.yaml" >/dev/null 2>&1; then
  PREV_DENIALS=$(git -C "$HYDRA_ROOT" show HEAD:"policies/tool-deny-lists.yaml")
  # Extract all denied tools from previous version
  PREV_TOOLS=$(echo "$PREV_DENIALS" | grep -E '^\s+- ' | sed 's/^[[:space:]]*- //' | sort -u)
  CURR_TOOLS=$(grep -E '^\s+- ' "$DENY_LIST" | sed 's/^[[:space:]]*- //' | sort -u)

  # Check that no previously denied tool was removed
  REMOVED=$(comm -23 <(echo "$PREV_TOOLS") <(echo "$CURR_TOOLS"))
  if [[ -n "$REMOVED" ]]; then
    fail "Deny list SHRUNK. Removed tools: $REMOVED"
  fi
fi
log "  Deny lists validated (only growth detected)."

# -------------------------------------------------------------------
# Step 4: rsync config to Node 8
# -------------------------------------------------------------------
log "Step 4/7: Syncing config to Node 8 ($NODE8_IP)..."
rsync -azP --delete \
  -e "ssh -i $SSH_KEY -o StrictHostKeyChecking=no" \
  --exclude='.git' \
  --exclude='hydra docs/' \
  "$HYDRA_ROOT/" \
  "$NODE8_USER@$NODE8_IP:$DEPLOY_PATH/"
log "  Config synced to $NODE8_IP:$DEPLOY_PATH/"

# -------------------------------------------------------------------
# Step 5: Restart OpenClaw Gateway pod
# -------------------------------------------------------------------
log "Step 5/7: Restarting OpenClaw Gateway..."
kubectl --kubeconfig="$KUBECONFIG" -n "$NAMESPACE" rollout restart deployment/openclaw-gateway
kubectl --kubeconfig="$KUBECONFIG" -n "$NAMESPACE" rollout status deployment/openclaw-gateway --timeout=120s
log "  OpenClaw Gateway restarted successfully."

# -------------------------------------------------------------------
# Step 6: Run smoke test
# -------------------------------------------------------------------
log "Step 6/7: Running smoke test..."
if ! "$SCRIPT_DIR/smoke-test.sh"; then
  fail "Smoke test failed after deploy"
fi
log "  Smoke test passed."

# -------------------------------------------------------------------
# Step 7: Post deploy status
# -------------------------------------------------------------------
COMMIT_SHA=$(git -C "$HYDRA_ROOT" rev-parse --short HEAD 2>/dev/null || echo "unknown")
log "Step 7/7: Posting deploy status..."
notify_slack ":white_check_mark: HYDRA deployed successfully. Commit: $COMMIT_SHA"
log "Deploy complete. Commit: $COMMIT_SHA"
