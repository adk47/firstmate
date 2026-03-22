#!/usr/bin/env bash
set -euo pipefail

# HYDRA Emergency Rollback
# ========================
# Reverts openclaw.json to previous version, restarts gateway, validates.

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
# Step 1: Stop OpenClaw Gateway
# -------------------------------------------------------------------
log "Step 1/5: Scaling down OpenClaw Gateway..."
kubectl --kubeconfig="$KUBECONFIG" -n "$NAMESPACE" scale deployment/openclaw-gateway --replicas=0
kubectl --kubeconfig="$KUBECONFIG" -n "$NAMESPACE" rollout status deployment/openclaw-gateway --timeout=60s || true
log "  Gateway scaled to 0."

# -------------------------------------------------------------------
# Step 2: Revert openclaw.json to previous version
# -------------------------------------------------------------------
log "Step 2/5: Reverting openclaw.json to HEAD~1..."
git -C "$HYDRA_ROOT" checkout HEAD~1 -- openclaw.json
log "  openclaw.json reverted."

# Sync reverted config to Node 8
log "  Syncing reverted config to Node 8..."
rsync -azP \
  -e "ssh -i $SSH_KEY -o StrictHostKeyChecking=no" \
  --exclude='.git' \
  --exclude='hydra docs/' \
  "$HYDRA_ROOT/" \
  "$NODE8_USER@$NODE8_IP:$DEPLOY_PATH/"
log "  Config synced."

# -------------------------------------------------------------------
# Step 3: Restart Gateway
# -------------------------------------------------------------------
log "Step 3/5: Restarting OpenClaw Gateway..."
kubectl --kubeconfig="$KUBECONFIG" -n "$NAMESPACE" scale deployment/openclaw-gateway --replicas=1
kubectl --kubeconfig="$KUBECONFIG" -n "$NAMESPACE" rollout status deployment/openclaw-gateway --timeout=120s
log "  Gateway restarted."

# -------------------------------------------------------------------
# Step 4: Run smoke test
# -------------------------------------------------------------------
log "Step 4/5: Running smoke test..."
if ! "$SCRIPT_DIR/smoke-test.sh"; then
  fail "Smoke test FAILED after rollback. System may be in a bad state."
fi
log "  Smoke test passed."

# -------------------------------------------------------------------
# Step 5: Post rollback status
# -------------------------------------------------------------------
log "Step 5/5: Posting rollback status..."
notify_slack ":rewind: HYDRA rollback complete. Now running $PREVIOUS_SHA. Smoke test passed."
log "Rollback complete. Now running: $PREVIOUS_SHA"
