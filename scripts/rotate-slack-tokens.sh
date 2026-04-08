#!/usr/bin/env bash
set -euo pipefail

# HYDRA Slack Token Rotation
# ==========================
# 90-day rotation for all 9 Slack app bot tokens.
# Stores new tokens in Vault, triggers ESO refresh, restarts gateway.

NAMESPACE="${NAMESPACE:-hydra}"
KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
VAULT_ADDR="${VAULT_ADDR:-https://vault.vault.svc.cluster.local:8200}"
VAULT_SECRET_PATH="${VAULT_SECRET_PATH:-secret/muso-prod/hydra-slack-tokens}"
SLACK_WEBHOOK="${HYDRA_SLACK_WEBHOOK:-}"

# Agent IDs must match Slack app names
AGENTS=(coordinator ceo cmo cto qa finance operations devops design)

log() { echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] $*"; }
fail() { log "FATAL: $*"; exit 1; }

notify_slack() {
  if [[ -n "$SLACK_WEBHOOK" ]]; then
    curl -sf -X POST "$SLACK_WEBHOOK" \
      -H 'Content-Type: application/json' \
      -d "{\"channel\": \"#hydra-heartbeat\", \"text\": \"$1\"}" >/dev/null 2>&1 || true
  fi
}

# Verify Vault is reachable and authenticated
vault status >/dev/null 2>&1 || fail "Vault is not reachable or not authenticated. Set VAULT_TOKEN."

log "Starting Slack token rotation for ${#AGENTS[@]} agents..."

# -------------------------------------------------------------------
# Step 1: Rotate each Slack app bot token
# -------------------------------------------------------------------
VAULT_PAYLOAD="{}"
ROTATION_ERRORS=0

for agent in "${AGENTS[@]}"; do
  log "  Rotating token for: hydra-$agent..."

  # Use Slack API to rotate the bot token
  # The app config token (SLACK_CONFIG_TOKEN) must be set in the environment
  SLACK_CONFIG_TOKEN="${SLACK_CONFIG_TOKEN:-}"
  if [[ -z "$SLACK_CONFIG_TOKEN" ]]; then
    fail "SLACK_CONFIG_TOKEN is not set. Required for token rotation."
  fi

  # Rotate via Slack tooling API
  ROTATE_RESPONSE=$(curl -sf -X POST "https://slack.com/api/apps.auth.external.rotate" \
    -H "Authorization: Bearer $SLACK_CONFIG_TOKEN" \
    -H "Content-Type: application/json" \
    -d "{\"app_id\": \"$(vault kv get -field="app_id_${agent}" "$VAULT_SECRET_PATH")\"}" 2>&1) || {
    log "  ERROR: Failed to rotate token for hydra-$agent"
    ROTATION_ERRORS=$((ROTATION_ERRORS + 1))
    continue
  }

  # Extract new token from response
  NEW_TOKEN=$(echo "$ROTATE_RESPONSE" | python3 -c "
import json, sys
data = json.load(sys.stdin)
if data.get('ok'):
    print(data.get('token', ''))
else:
    print('')
    sys.exit(1)
" 2>/dev/null) || {
    log "  ERROR: Slack API returned error for hydra-$agent"
    ROTATION_ERRORS=$((ROTATION_ERRORS + 1))
    continue
  }

  if [[ -z "$NEW_TOKEN" ]]; then
    log "  ERROR: Empty token returned for hydra-$agent"
    ROTATION_ERRORS=$((ROTATION_ERRORS + 1))
    continue
  fi

  # Build Vault payload
  VAULT_PAYLOAD=$(echo "$VAULT_PAYLOAD" | python3 -c "
import json, sys
data = json.load(sys.stdin)
data['bot_token_${agent}'] = '${NEW_TOKEN}'
print(json.dumps(data))
")

  log "  Token rotated for hydra-$agent."
done

if [[ "$ROTATION_ERRORS" -gt 0 ]]; then
  fail "$ROTATION_ERRORS token rotation(s) failed. Aborting before Vault write."
fi

# -------------------------------------------------------------------
# Step 2: Store new tokens in Vault
# -------------------------------------------------------------------
log "Storing rotated tokens in Vault at $VAULT_SECRET_PATH..."
echo "$VAULT_PAYLOAD" | vault kv put "$VAULT_SECRET_PATH" -
log "  Tokens stored in Vault."

# -------------------------------------------------------------------
# Step 3: Trigger ESO refresh
# -------------------------------------------------------------------
log "Triggering ExternalSecret refresh..."
kubectl --kubeconfig="$KUBECONFIG" -n "$NAMESPACE" \
  annotate externalsecret hydra-slack-tokens \
  force-sync="$(date +%s)" --overwrite
log "  ESO refresh triggered."

# Wait for the secret to be updated
log "  Waiting for ExternalSecret to sync..."
for _ in $(seq 1 30); do
  STATUS=$(kubectl --kubeconfig="$KUBECONFIG" -n "$NAMESPACE" \
    get externalsecret hydra-slack-tokens -o jsonpath='{.status.conditions[0].reason}' 2>/dev/null) || STATUS="Unknown"
  if [[ "$STATUS" == "SecretSynced" ]]; then
    break
  fi
  sleep 2
done

if [[ "$STATUS" != "SecretSynced" ]]; then
  fail "ExternalSecret did not sync within 60s. Status: $STATUS"
fi
log "  ExternalSecret synced."

# -------------------------------------------------------------------
# Step 4: Restart Gateway pod
# -------------------------------------------------------------------
log "Restarting OpenClaw Gateway to pick up new tokens..."
kubectl --kubeconfig="$KUBECONFIG" -n "$NAMESPACE" rollout restart deployment/openclaw-gateway
kubectl --kubeconfig="$KUBECONFIG" -n "$NAMESPACE" rollout status deployment/openclaw-gateway --timeout=120s
log "  Gateway restarted."

# -------------------------------------------------------------------
# Step 5: Verify all 9 channels reconnect
# -------------------------------------------------------------------
log "Verifying channel reconnection..."
sleep 10  # Allow Socket Mode connections to establish

CONNECTED=0
for agent in "${AGENTS[@]}"; do
  CHANNEL_STATUS=$(openclaw channels status --agent "$agent" 2>&1) || CHANNEL_STATUS=""
  if echo "$CHANNEL_STATUS" | grep -qi 'HEALTHY\|CONNECTED'; then
    CONNECTED=$((CONNECTED + 1))
    log "  hydra-$agent: connected"
  else
    log "  hydra-$agent: NOT connected"
  fi
done

if [[ "$CONNECTED" -eq "${#AGENTS[@]}" ]]; then
  log "All ${#AGENTS[@]} channels reconnected successfully."
  notify_slack ":key: Slack token rotation complete. All ${#AGENTS[@]} agents reconnected."
else
  MISSING=$((${#AGENTS[@]} - CONNECTED))
  fail "$MISSING agent(s) failed to reconnect after token rotation."
fi

log "Slack token rotation complete."
