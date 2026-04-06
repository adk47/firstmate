#!/usr/bin/env bash
set -euo pipefail

# HYDRA Deploy Script
# ===================
# CD entrypoint: validate config, sync to Node 8, restart gateway, smoke test.
# Supports targeted deployment: --target main|edge|dev|all

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HYDRA_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

DEPLOY_PATH="${DEPLOY_PATH:-/opt/hydra}"

# Detect if we're running on Node 8 (the HYDRA host)
if hostname | grep -q 'node-8\|ovh-node-8' || [ -d "/opt/hydra/workspaces" ]; then
  HYDRA_LOCAL=true
else
  HYDRA_LOCAL=false
fi

SSH_KEY="${SSH_KEY:-$HOME/.ssh/ovh_muso}"
NODE8_IP="${NODE8_IP:-10.0.0.8}"
NODE8_USER="${NODE8_USER:-root}"
NAMESPACE="${NAMESPACE:-hydra}"
SLACK_WEBHOOK="${HYDRA_SLACK_WEBHOOK:-}"
KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"

# Parse --target flag
TARGET="all"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --target)
      [[ -z "${2:-}" ]] && { echo "Error: --target requires a value (main|edge|dev|all)"; exit 1; }
      TARGET="$2"; shift 2 ;;
    main|edge|dev|all) TARGET="$1"; shift ;;
    *) echo "Usage: deploy.sh [--target main|edge|dev|all]"; exit 1 ;;
  esac
done

# Validate target value (supports comma-separated: main,edge)
IFS=',' read -ra TARGET_PARTS <<< "$TARGET"
for t in "${TARGET_PARTS[@]}"; do
  case "$t" in
    main|edge|dev|all) ;;
    *) echo "Error: invalid target '$t'. Must be main|edge|dev|all"; exit 1 ;;
  esac
done

log() { echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] $*"; }
fail() { log "FATAL: $*"; notify_slack ":x: HYDRA deploy FAILED ($TARGET): $*"; exit 1; }
needs_target() { [[ "$TARGET" == "all" || ",$TARGET," == *",$1,"* ]]; }

notify_slack() {
  if [[ -n "$SLACK_WEBHOOK" ]]; then
    curl -sf -X POST "$SLACK_WEBHOOK" \
      -H 'Content-Type: application/json' \
      -d "{\"channel\": \"#hydra-heartbeat\", \"text\": \"$1\"}" >/dev/null 2>&1 || true
  fi
}

log "Deploy target: $TARGET"

# -------------------------------------------------------------------
# Step 1: Validate config files
# -------------------------------------------------------------------
log "Step 1/9: Validating config files..."

if needs_target "main"; then
  python3 -m json.tool "$HYDRA_ROOT/openclaw-main.json" >/dev/null 2>&1 || fail "openclaw-main.json is not valid JSON"
  log "  openclaw-main.json is valid JSON."
fi
if needs_target "edge"; then
  python3 -m json.tool "$HYDRA_ROOT/openclaw-edge.json" >/dev/null 2>&1 || fail "openclaw-edge.json is not valid JSON"
  log "  openclaw-edge.json is valid JSON."
fi
if needs_target "dev"; then
  python3 -m json.tool "$HYDRA_ROOT/openclaw-dev.json" >/dev/null 2>&1 || fail "openclaw-dev.json is not valid JSON"
  log "  openclaw-dev.json is valid JSON."
fi

# Run drift check when deploying all or multiple profiles
if [[ "$TARGET" == "all" ]] || [[ "$TARGET" == *","* ]]; then
  "$SCRIPT_DIR/validate-shared-config.sh" || fail "Shared config drift detected"
fi

# -------------------------------------------------------------------
# Step 2: Validate SOUL.md files
# -------------------------------------------------------------------
log "Step 2/9: Validating SOUL.md files..."
validate_souls() {
  local config="$1"
  local label="$2"
  local agents
  agents=$(python3 -c "
import json, os
with open('$config') as f:
    c = json.load(f)
defaults_ws = c.get('agents', {}).get('defaults', {}).get('workspace', '')
for a in c.get('agents', {}).get('list', []):
    ws = a.get('workspace', defaults_ws)
    print(a['id'] + ':' + os.path.basename(ws))
")
  local missing=()
  for entry in $agents; do
    local agent_id="${entry%%:*}"
    local ws_dir="${entry##*:}"
    [[ -z "$ws_dir" ]] && ws_dir="$agent_id"
    if [[ ! -f "$HYDRA_ROOT/workspaces/$ws_dir/SOUL.md" ]]; then
      missing+=("$agent_id")
    fi
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    fail "Missing SOUL.md for $label agents: ${missing[*]}"
  fi
}

if needs_target "main"; then validate_souls "$HYDRA_ROOT/openclaw-main.json" "main"; fi
if needs_target "edge"; then validate_souls "$HYDRA_ROOT/openclaw-edge.json" "edge"; fi
if needs_target "dev"; then validate_souls "$HYDRA_ROOT/openclaw-dev.json" "dev"; fi
log "  All SOUL.md files present."

# -------------------------------------------------------------------
# Step 3: Validate tool-deny-lists.yaml
# -------------------------------------------------------------------
log "Step 3/9: Validating tool-deny-lists.yaml (deny lists can only grow)..."
DENY_LIST="$HYDRA_ROOT/policies/tool-deny-lists.yaml"

if [[ ! -f "$DENY_LIST" ]]; then
  fail "policies/tool-deny-lists.yaml not found"
fi

if git -C "$HYDRA_ROOT" show HEAD:"policies/tool-deny-lists.yaml" >/dev/null 2>&1; then
  PREV_TOOLS=$(git -C "$HYDRA_ROOT" show HEAD:"policies/tool-deny-lists.yaml" | grep -E '^\s+- ' | sed 's/^[[:space:]]*- //' | sort -u)
  CURR_TOOLS=$(grep -E '^\s+- ' "$DENY_LIST" | sed 's/^[[:space:]]*- //' | sort -u)
  REMOVED=$(comm -23 <(echo "$PREV_TOOLS") <(echo "$CURR_TOOLS"))
  if [[ -n "$REMOVED" ]]; then
    fail "Deny list SHRUNK. Removed tools: $REMOVED"
  fi
fi
log "  Deny lists validated (only growth detected)."

# -------------------------------------------------------------------
# Step 4: rsync repo to Node 8
# -------------------------------------------------------------------
if $HYDRA_LOCAL; then
  log "Step 4/9: Local sync (running on Node 8)..."
  rsync -a --delete \
    --exclude='.git' \
    --exclude='hydra docs/' \
    "$HYDRA_ROOT/" \
    "$DEPLOY_PATH/"
  log "  Config synced locally to $DEPLOY_PATH/"
else
  log "Step 4/9: Remote sync to Node 8 ($NODE8_IP)..."
  rsync -azP --delete \
    -e "ssh -i $SSH_KEY -o StrictHostKeyChecking=no" \
    --exclude='.git' \
    --exclude='hydra docs/' \
    "$HYDRA_ROOT/" \
    "$NODE8_USER@$NODE8_IP:$DEPLOY_PATH/"
  log "  Config synced to $NODE8_IP:$DEPLOY_PATH/"
fi

# Sync per-profile configs to profile state dirs
log "  Syncing profile configs..."
if [ "$TARGET" = "main" ] || [ "$TARGET" = "all" ]; then
  mkdir -p /root/.openclaw-main
  cp "$DEPLOY_PATH/openclaw-main.json" /root/.openclaw-main/openclaw.json
  cp "$DEPLOY_PATH/openclaw-main.json" /root/.openclaw/openclaw.json
  log "  Synced main profile config (+ default openclaw.json)"
fi
if [ "$TARGET" = "edge" ] || [ "$TARGET" = "all" ]; then
  mkdir -p /root/.openclaw-edge
  cp "$DEPLOY_PATH/openclaw-edge.json" /root/.openclaw-edge/openclaw.json
  log "  Synced edge profile config"
fi
if [ "$TARGET" = "dev" ] || [ "$TARGET" = "all" ]; then
  mkdir -p /root/.openclaw-dev
  cp "$DEPLOY_PATH/openclaw-dev.json" /root/.openclaw-dev/openclaw.json
  log "  Synced dev profile config"
fi

# -------------------------------------------------------------------
# Step 5: Post-sync setup on Node 8
# -------------------------------------------------------------------
log "Step 5/9: Running post-sync setup..."

run_on_node8() {
  if $HYDRA_LOCAL; then
    bash -c "$1"
  else
    ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "$NODE8_USER@$NODE8_IP" "$1"
  fi
}

# Post-sync inline (runs locally on node-8 or via SSH)
bash << 'POSTSYNC'
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

# Ensure GOG_KEYRING_PASSWORD is set for gog CLI
if ! grep -q "GOG_KEYRING_PASSWORD" /root/.bashrc 2>/dev/null; then
  GOG_PW=$(kubectl get secret -n hydra hydra-service-tokens -o jsonpath='{.data.GOG_KEYRING_PASSWORD}' 2>/dev/null | base64 -d)
  if [ -n "$GOG_PW" ]; then
    echo "export GOG_KEYRING_PASSWORD='${GOG_PW}'" >> /root/.bashrc
    echo "  GOG keyring password set in .bashrc"
  fi
fi

# Note: mention gate patch (patch-openclaw-mention-gate.sh) removed — no longer needed on OpenClaw 2026.4.2+

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

# Use local embeddings for memory search on main profile
python3 -c "
import json
cfg = '/root/.openclaw/main/openclaw.json'
with open(cfg) as f:
    c = json.load(f)
defaults = c.setdefault('agents', {}).setdefault('defaults', {})
defaults['memorySearch'] = {'enabled': True, 'provider': 'local'}
c.get('models', {}).get('providers', {}).pop('openai', None)
with open(cfg, 'w') as f:
    json.dump(c, f, indent=2)
print('  Memory search: local embeddings (no OpenAI)')
"

# Patch Gmail plugin (main profile only)
GMAIL_CHANNEL="/root/.openclaw/extensions/openclaw-gmail/src/channel.ts"
if [ -f "$GMAIL_CHANNEL" ]; then
  if ! grep -q "describeMessageTool" "$GMAIL_CHANNEL"; then
    sed -i 's/listActions: () => \["send"\],/listActions: () => ["send"],\n    describeMessageTool: () => ({ actions: ["send"], capabilities: ["send"] }),/' "$GMAIL_CHANNEL"
    echo "  Patched Gmail plugin describeMessageTool"
  fi
fi

GMAIL_MONITOR="/root/.openclaw/extensions/openclaw-gmail/src/monitor.ts"
if [ -f "$GMAIL_MONITOR" ]; then
  if grep -q 'account.backend !== "api" && !(await GogGmailClient.checkExists())' "$GMAIL_MONITOR" && ! grep -q "PATCHED" "$GMAIL_MONITOR"; then
    sed -i 's|if (account.backend !== "api" && !(await GogGmailClient.checkExists())) {|if (false \&\& account.backend !== "api" \&\& !(await GogGmailClient.checkExists())) { // PATCHED: skip gog check|' "$GMAIL_MONITOR"
    echo "  Patched Gmail monitor gog CLI check"
  fi
  if grep -q "^  await ensureQuarantineLabel(client, log);" "$GMAIL_MONITOR"; then
    sed -i '/^  await ensureQuarantineLabel(client, log);/c\  try { await ensureQuarantineLabel(client, log); } catch (e) { log.warn(`Quarantine label setup failed: ${String(e)}`); }' "$GMAIL_MONITOR"
    sed -i '/^  await pruneGmailSessions(account, log);/c\  try { await pruneGmailSessions(account, log); } catch (e) { log.warn(`Prune failed: ${String(e)}`); }' "$GMAIL_MONITOR"
    echo "  Patched Gmail monitor init resilience"
  fi
fi
POSTSYNC

log "  Post-sync setup complete."

# -------------------------------------------------------------------
# Step 6: Restart targeted gateway(s)
# -------------------------------------------------------------------
log "Step 6/9: Restarting OpenClaw Gateway ($TARGET)..."
restart_gateway() {
  local service="$1"
  if $HYDRA_LOCAL; then
    systemctl restart "$service" && sleep 10 && systemctl is-active --quiet "$service" \
      || fail "Failed to restart $service"
  else
    ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "$NODE8_USER@$NODE8_IP" \
      "systemctl restart $service && sleep 10 && systemctl is-active --quiet $service" \
      || fail "Failed to restart $service"
  fi
  log "  $service restarted successfully."
}

if needs_target "main"; then restart_gateway "openclaw-gateway-main"; fi
if needs_target "edge"; then restart_gateway "openclaw-gateway-edge"; fi
if needs_target "dev"; then restart_gateway "openclaw-gateway-dev"; fi

# -------------------------------------------------------------------
# Step 7: Run smoke test
# -------------------------------------------------------------------
log "Step 7/9: Running smoke test..."
if ! "$SCRIPT_DIR/smoke-test.sh" "$TARGET"; then
  fail "Smoke test failed after deploy"
fi
log "  Smoke test passed."

# -------------------------------------------------------------------
# Step 8: Verify AWS access (main only)
# -------------------------------------------------------------------
if needs_target "main"; then
  log "Step 8/9: Verifying AWS access..."
  if $HYDRA_LOCAL; then
    aws sts get-caller-identity --region us-west-2 2>/dev/null | head -1 \
      && log "  AWS access verified." \
      || log "  WARNING: AWS access check failed (non-fatal)."
  else
    ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "$NODE8_USER@$NODE8_IP" \
      "aws sts get-caller-identity --region us-west-2 2>/dev/null | head -1" \
      && log "  AWS access verified." \
      || log "  WARNING: AWS access check failed (non-fatal)."
  fi
else
  log "Step 8/9: Skipping AWS check (not targeting main)."
fi

# -------------------------------------------------------------------
# Step 9: Post deploy status
# -------------------------------------------------------------------
COMMIT_SHA=$(git -C "$HYDRA_ROOT" rev-parse --short HEAD 2>/dev/null || echo "unknown")
log "Step 9/9: Posting deploy status..."
notify_slack ":white_check_mark: HYDRA deployed successfully (target: $TARGET). Commit: $COMMIT_SHA"
log "Deploy complete. Target: $TARGET. Commit: $COMMIT_SHA"
