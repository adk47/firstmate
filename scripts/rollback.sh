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

# -------------------------------------------------------------------
# HYDRA_LOCAL detection (mirrors scripts/deploy.sh)
# -------------------------------------------------------------------
# When running on node-8 itself (either via SSH from a laptop or
# inside the GH Actions self-hosted runner which IS node-8), we skip
# all SSH and rsync-over-SSH paths and operate on /opt/hydra/ directly.
# Before this fix, rollback.sh tried to SSH to root@10.0.0.8 with
# ~/.ssh/ovh_muso — that key doesn't exist on the runner, so the
# rollback path was dead.
if hostname | grep -q 'node-8\|ovh-node-8' || [ -d "/opt/hydra/workspaces" ]; then
  HYDRA_LOCAL=true
else
  HYDRA_LOCAL=false
fi
NAMESPACE="${NAMESPACE:-hydra}"
KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
# See deploy.sh for the env var precedence rationale.
SLACK_WEBHOOK="${SLACK_WEBHOOK:-${HYDRA_SLACK_WEBHOOK:-}}"

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
for cfg in openclaw-main.json openclaw-edge.json; do
  if git -C "$HYDRA_ROOT" show "HEAD~1:$cfg" >/dev/null 2>&1; then
    git -C "$HYDRA_ROOT" checkout HEAD~1 -- "$cfg"
    log "  Reverted $cfg"
  else
    log "  WARNING: $cfg not found in HEAD~1 — skipping"
  fi
done

# Sync reverted configs to Node 8
#
# Excludes mirror scripts/deploy.sh's RSYNC_EXCLUDES — without these
# the rollback rsync would silently overwrite live agent state
# (workspaces/*/MEMORY.md, HEARTBEAT.md, IDENTITY.md, memory/, api-logs/,
# backups/, reports/) with repo seeds. Pre-2026-04-08 this rsync was
# inside a dead SSH path (the GH Actions runner had no SSH key) so the
# bug never fired. After porting HYDRA_LOCAL detection, the rsync
# actually runs on every rollback — it MUST share the deploy excludes.
#
# ⚠ DRIFT WARNING: this array is a copy of deploy.sh's RSYNC_EXCLUDES.
# The pre-commit hook Check 2 enforces deploy.sh's list matches the
# required_excludes declaration, but it does NOT check that this copy
# stays in sync. If you add a new exclude to deploy.sh's RSYNC_EXCLUDES,
# add it here too. Keeping the two lists verbatim identical is the
# stated invariant. A follow-up task may extend the pre-commit hook to
# verify this automatically, per Clio's PR #68 review observation.
ROLLBACK_EXCLUDES=(
  --exclude='.git'
  --exclude='hydra docs/'
  --exclude='secrets/'
  --exclude='.deployed-sha'
  --exclude='workspaces/*/memory/'
  --exclude='workspaces/*/api-logs/'
  --exclude='workspaces/*/MEMORY.md'
  --exclude='workspaces/*/backups/'
  --exclude='workspaces/*/reports/'
  --exclude='workspaces/*/.openclaw/'
  --exclude='workspaces/*/IDENTITY.md'
  --exclude='workspaces/*/HEARTBEAT.md'
  --exclude='audit/'
  --exclude='audit-local-backup/'
  --exclude='config/'
  --exclude='plugins/*/node_modules/'
  --exclude='plugins/*/package-lock.json'
)
log "  Syncing reverted config to Node 8..."
if $HYDRA_LOCAL; then
  rsync -a \
    "${ROLLBACK_EXCLUDES[@]}" \
    "$HYDRA_ROOT/" \
    "$DEPLOY_PATH/"
else
  rsync -azP \
    -e "ssh -i $SSH_KEY -o StrictHostKeyChecking=no" \
    "${ROLLBACK_EXCLUDES[@]}" \
    "$HYDRA_ROOT/" \
    "$NODE8_USER@$NODE8_IP:$DEPLOY_PATH/"
fi

# Sync to profile dirs
if $HYDRA_LOCAL; then
  set +e
  for profile in main edge; do
    src="/opt/hydra/openclaw-${profile}.json"
    dst="/root/.openclaw/${profile}/openclaw.json"
    if [ -f "$src" ]; then
      mkdir -p "/root/.openclaw/${profile}"
      cp "$src" "$dst" && echo "  Synced ${profile} profile config" || echo "  WARNING: Failed to sync ${profile} profile config"
    else
      echo "  WARNING: $src not found — skipping ${profile}"
    fi
  done
  set -e
else
  ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "$NODE8_USER@$NODE8_IP" << 'SYNC'
set -euo pipefail
for profile in main edge; do
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
fi
log "  Config synced."

# -------------------------------------------------------------------
# Step 2: Restart all gateways
# -------------------------------------------------------------------
log "Step 2/4: Restarting all gateways..."
if $HYDRA_LOCAL; then
  for svc in openclaw-gateway-main openclaw-gateway-edge; do
    if systemctl is-active "$svc" &>/dev/null || systemctl is-enabled "$svc" &>/dev/null; then
      systemctl restart "$svc" && echo "  Restarted $svc" || echo "  WARNING: Failed to restart $svc"
    fi
  done
else
  ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "$NODE8_USER@$NODE8_IP" << 'RESTART'
for svc in openclaw-gateway-main openclaw-gateway-edge; do
  if systemctl is-active "$svc" &>/dev/null || systemctl is-enabled "$svc" &>/dev/null; then
    systemctl restart "$svc" && echo "  Restarted $svc" || echo "  WARNING: Failed to restart $svc"
  fi
done
RESTART
fi
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
