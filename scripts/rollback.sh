#!/usr/bin/env bash
set -euo pipefail

# HYDRA Emergency Rollback
# ========================
# Reverts gateway configs to previous version, restarts all gateways, validates.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HYDRA_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

SSH_KEY="${SSH_KEY:-$HOME/.ssh/ovh_muso}"
NODE8_IP="${NODE8_IP:-10.0.0.8}"
NODE8_USER="${NODE8_USER:-root}"
DEPLOY_PATH="${DEPLOY_PATH:-/opt/hydra}"
NAMESPACE="${NAMESPACE:-hydra}"
KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
SLACK_WEBHOOK="${HYDRA_SLACK_WEBHOOK:-}"

log() { echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] $*"; }
fail() { log "FATAL: $*"; notify_slack ":rotating_light: HYDRA ROLLBACK FAILED: $*. @aaron manual intervention required."; exit 1; }

notify_slack() {
  if [[ -n "$SLACK_WEBHOOK" ]]; then
    curl -sf -X POST "$SLACK_WEBHOOK" \
      -H 'Content-Type: application/json' \
      -d "{\"channel\": \"#hydra-heartbeat\", \"text\": \"$1\"}" >/dev/null 2>&1 || true
  fi
}

CURRENT_SHA=$(git -C "$HYDRA_ROOT" rev-parse --short HEAD 2>/dev/null || echo "unknown")
PREVIOUS_SHA=$(git -C "$HYDRA_ROOT" rev-parse --short HEAD~1 2>/dev/null || echo "unknown")

log "Starting emergency rollback: $CURRENT_SHA -> $PREVIOUS_SHA"
notify_slack ":warning: HYDRA rollback initiated. Reverting $CURRENT_SHA -> $PREVIOUS_SHA"

# -------------------------------------------------------------------
# Step 1: Revert configs to previous version
# -------------------------------------------------------------------
log "Step 1/4: Reverting configs to HEAD~1..."
for cfg in openclaw-main.json openclaw-edge.json openclaw-dev.json; do
  if git -C "$HYDRA_ROOT" show "HEAD~1:$cfg" >/dev/null 2>&1; then
    git -C "$HYDRA_ROOT" checkout HEAD~1 -- "$cfg"
    log "  Reverted $cfg"
  else
    log "  WARNING: $cfg not found in HEAD~1 — skipping"
  fi
done

# Sync reverted configs to Node 8
log "  Syncing reverted config to Node 8..."
rsync -azP \
  -e "ssh -i $SSH_KEY -o StrictHostKeyChecking=no" \
  --exclude='.git' \
  --exclude='hydra docs/' \
  "$HYDRA_ROOT/" \
  "$NODE8_USER@$NODE8_IP:$DEPLOY_PATH/"

# Sync to profile dirs
ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "$NODE8_USER@$NODE8_IP" << 'SYNC'
set -euo pipefail
for profile in main edge dev; do
  src="/opt/hydra/openclaw-${profile}.json"
  dst="/root/.openclaw/${profile}/openclaw.json"
  if [ -f "$src" ]; then
    mkdir -p "/root/.openclaw/${profile}"
    cp "$src" "$dst" && echo "  Synced ${profile} profile config" || echo "  WARNING: Failed to sync ${profile} profile config"
  else
    echo "  WARNING: $src not found — skipping ${profile}"
  fi
done
SYNC
log "  Config synced."

# -------------------------------------------------------------------
# Step 2: Restart all gateways
# -------------------------------------------------------------------
log "Step 2/4: Restarting all gateways..."
ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "$NODE8_USER@$NODE8_IP" << 'RESTART'
for svc in openclaw-gateway-main openclaw-gateway-edge openclaw-gateway-dev; do
  if systemctl is-active "$svc" &>/dev/null || systemctl is-enabled "$svc" &>/dev/null; then
    systemctl restart "$svc" && echo "  Restarted $svc" || echo "  WARNING: Failed to restart $svc"
  fi
done
RESTART
sleep 5
log "  Gateways restarted."

# -------------------------------------------------------------------
# Step 3: Run smoke test
# -------------------------------------------------------------------
log "Step 3/4: Running smoke test..."
if ! "$SCRIPT_DIR/smoke-test.sh" all; then
  fail "Smoke test FAILED after rollback. System may be in a bad state."
fi
log "  Smoke test passed."

# -------------------------------------------------------------------
# Step 4: Post rollback status
# -------------------------------------------------------------------
log "Step 4/4: Posting rollback status..."
notify_slack ":rewind: HYDRA rollback complete. Now running $PREVIOUS_SHA. Smoke test passed."
log "Rollback complete. Now running: $PREVIOUS_SHA"
