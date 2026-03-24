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
# Step 5: Post-sync setup on Node 8
# -------------------------------------------------------------------
log "Step 5/9: Running post-sync setup on Node 8..."

ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "$NODE8_USER@$NODE8_IP" << 'POSTSYNC'
set -euo pipefail

# AWS credentials (from K8s secret or pre-configured)
if [ ! -f ~/.aws/credentials ]; then
  echo "  Setting up AWS credentials..."
  mkdir -p ~/.aws
  AWS_KEY=$(kubectl get secret -n hydra aws-hydra-readonly -o jsonpath='{.data.AWS_ACCESS_KEY_ID}' 2>/dev/null | base64 -d)
  AWS_SECRET=$(kubectl get secret -n hydra aws-hydra-readonly -o jsonpath='{.data.AWS_SECRET_ACCESS_KEY}' 2>/dev/null | base64 -d)
  AWS_ROLE=$(kubectl get secret -n hydra aws-hydra-readonly -o jsonpath='{.data.AWS_ROLE_ARN}' 2>/dev/null | base64 -d)
  if [ -n "$AWS_KEY" ]; then
    cat > ~/.aws/credentials << CEOF
[plaque]
aws_access_key_id = ${AWS_KEY}
aws_secret_access_key = ${AWS_SECRET}
CEOF
    cat > ~/.aws/config << CEOF
[default]
region = us-west-2
role_arn = ${AWS_ROLE}
source_profile = plaque

[profile plaque]
region = us-west-2
CEOF
    chmod 600 ~/.aws/credentials
    echo "  AWS credentials configured."
  else
    echo "  WARNING: aws-hydra-readonly secret not found — skipping AWS setup."
  fi
fi

# Apply OpenClaw mention gate patch (until upstream PR #53161 is merged)
if [ -f /opt/hydra/scripts/patch-openclaw-mention-gate.sh ]; then
  bash /opt/hydra/scripts/patch-openclaw-mention-gate.sh
fi

# Sync cron jobs from repo (preserve live state)
if [ -f /opt/hydra/cron-jobs.json ]; then
  LIVE_CRON="/root/.openclaw/cron/jobs.json"
  if [ -f "$LIVE_CRON" ]; then
    python3 -c "
import json
with open('/opt/hydra/cron-jobs.json') as f:
    repo = json.load(f)
with open('$LIVE_CRON') as f:
    live = json.load(f)
live_states = {j['name']: j.get('state', {}) for j in live.get('jobs', [])}
for j in repo.get('jobs', []):
    if j['name'] in live_states:
        j['state'] = live_states[j['name']]
with open('$LIVE_CRON', 'w') as f:
    json.dump(repo, f, indent=2)
print(f'  Synced {len(repo.get(\"jobs\", []))} cron jobs (preserved live state)')
"
  else
    cp /opt/hydra/cron-jobs.json "$LIVE_CRON"
    echo "  Deployed cron jobs (fresh install)"
  fi
fi

# Use local embeddings for memory search (no OpenAI dependency)
python3 -c "
import json
cfg = '/root/.openclaw/openclaw.json'
with open(cfg) as f:
    c = json.load(f)
defaults = c.setdefault('agents', {}).setdefault('defaults', {})
defaults['memorySearch'] = {'enabled': True, 'provider': 'local'}
# Remove OpenAI provider if present
c.get('models', {}).get('providers', {}).pop('openai', None)
with open(cfg, 'w') as f:
    json.dump(c, f, indent=2)
print('  Memory search: local embeddings (no OpenAI)')
"

# Patch Gmail plugin describeMessageTool (until plugin is updated for 2026.3.22+)
GMAIL_CHANNEL="/root/.openclaw/extensions/openclaw-gmail/src/channel.ts"
if [ -f "$GMAIL_CHANNEL" ]; then
  if ! grep -q "describeMessageTool" "$GMAIL_CHANNEL"; then
    sed -i 's/listActions: () => \["send"\],/listActions: () => ["send"],\n    describeMessageTool: () => ({ actions: ["send"], capabilities: ["send"] }),/' "$GMAIL_CHANNEL"
    echo "  Patched Gmail plugin describeMessageTool"
  fi
fi
POSTSYNC

log "  Post-sync setup complete."

# -------------------------------------------------------------------
# Step 6: Restart OpenClaw Gateway
# -------------------------------------------------------------------
log "Step 6/9: Restarting OpenClaw Gateway..."
ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "$NODE8_USER@$NODE8_IP" \
  "systemctl restart openclaw-gateway && sleep 5 && systemctl is-active openclaw-gateway" \
  || kubectl --kubeconfig="$KUBECONFIG" -n "$NAMESPACE" rollout restart deployment/openclaw-gateway 2>/dev/null \
  || fail "Failed to restart OpenClaw Gateway"
log "  OpenClaw Gateway restarted successfully."

# -------------------------------------------------------------------
# Step 7: Run smoke test
# -------------------------------------------------------------------
log "Step 7/9: Running smoke test..."
if ! "$SCRIPT_DIR/smoke-test.sh"; then
  fail "Smoke test failed after deploy"
fi
log "  Smoke test passed."

# -------------------------------------------------------------------
# Step 8: Verify AWS access
# -------------------------------------------------------------------
log "Step 8/9: Verifying AWS access..."
ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "$NODE8_USER@$NODE8_IP" \
  "aws sts get-caller-identity --region us-west-2 2>/dev/null | head -1" \
  && log "  AWS access verified." \
  || log "  WARNING: AWS access check failed (non-fatal)."

# -------------------------------------------------------------------
# Step 9: Post deploy status
# -------------------------------------------------------------------
COMMIT_SHA=$(git -C "$HYDRA_ROOT" rev-parse --short HEAD 2>/dev/null || echo "unknown")
log "Step 9/9: Posting deploy status..."
notify_slack ":white_check_mark: HYDRA deployed successfully. Commit: $COMMIT_SHA"
log "Deploy complete. Commit: $COMMIT_SHA"
