#!/usr/bin/env bash
set -euo pipefail

# HYDRA Smoke Test
# ================
# Post-deploy validation: verify all agents, channels, and services are healthy.

NAMESPACE="${NAMESPACE:-hydra}"
KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
EXPECTED_AGENTS=9
AGENT_TIMEOUT=30
CLIPROXYAPI_PORT=8317
FAILURES=0

log() { echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] $*"; }
warn() { log "WARN: $*"; }
fail_check() { log "FAIL: $*"; FAILURES=$((FAILURES + 1)); }
pass_check() { log "PASS: $*"; }

# -------------------------------------------------------------------
# Check 1: Verify agent count
# -------------------------------------------------------------------
log "Check 1/5: Verifying agent bindings..."
AGENT_OUTPUT=$(openclaw agents list --bindings 2>&1) || true
AGENT_COUNT=$(echo "$AGENT_OUTPUT" | grep -c 'BOUND' || echo 0)

if [[ "$AGENT_COUNT" -eq "$EXPECTED_AGENTS" ]]; then
  pass_check "$AGENT_COUNT/$EXPECTED_AGENTS agents bound"
else
  fail_check "Expected $EXPECTED_AGENTS agents, got $AGENT_COUNT"
  echo "$AGENT_OUTPUT"
fi

# -------------------------------------------------------------------
# Check 2: Verify all channels healthy
# -------------------------------------------------------------------
log "Check 2/5: Verifying channel health..."
CHANNEL_OUTPUT=$(openclaw channels status --probe 2>&1) || true
UNHEALTHY=$(echo "$CHANNEL_OUTPUT" | grep -cv 'HEALTHY' || echo 0)
# Subtract header line
UNHEALTHY=$((UNHEALTHY > 0 ? UNHEALTHY - 1 : 0))

if [[ "$UNHEALTHY" -eq 0 ]]; then
  pass_check "All channels healthy"
else
  fail_check "$UNHEALTHY unhealthy channels detected"
  echo "$CHANNEL_OUTPUT"
fi

# -------------------------------------------------------------------
# Check 3: Ping each agent (verify response within timeout)
# -------------------------------------------------------------------
log "Check 3/5: Pinging agents (timeout: ${AGENT_TIMEOUT}s each)..."
AGENT_IDS=(coordinator ceo cmo cto qa finance operations devops design)

for agent_id in "${AGENT_IDS[@]}"; do
  START=$(date +%s)
  RESPONSE=$(timeout "$AGENT_TIMEOUT" openclaw agent ping "$agent_id" 2>&1) || RESPONSE="TIMEOUT"
  ELAPSED=$(( $(date +%s) - START ))

  if echo "$RESPONSE" | grep -qi 'pong\|alive\|ok'; then
    pass_check "Agent '$agent_id' responded in ${ELAPSED}s"
  else
    fail_check "Agent '$agent_id' did not respond within ${AGENT_TIMEOUT}s"
  fi
done

# -------------------------------------------------------------------
# Check 4: CLIProxyAPI health check
# -------------------------------------------------------------------
log "Check 4/5: Checking CLIProxyAPI /health..."

# Get the gateway pod to port-forward or exec into
GATEWAY_POD=$(kubectl --kubeconfig="$KUBECONFIG" -n "$NAMESPACE" \
  get pod -l app=openclaw-gateway -o jsonpath='{.items[0].metadata.name}' 2>/dev/null) || GATEWAY_POD=""

if [[ -n "$GATEWAY_POD" ]]; then
  HEALTH_RESPONSE=$(kubectl --kubeconfig="$KUBECONFIG" -n "$NAMESPACE" \
    exec "$GATEWAY_POD" -c cliproxyapi -- \
    curl -sf "http://127.0.0.1:${CLIPROXYAPI_PORT}/health" 2>&1) || HEALTH_RESPONSE="UNREACHABLE"

  if echo "$HEALTH_RESPONSE" | grep -qi 'ok\|healthy'; then
    pass_check "CLIProxyAPI /health returned OK"
  else
    fail_check "CLIProxyAPI /health check failed: $HEALTH_RESPONSE"
  fi
else
  fail_check "Cannot find openclaw-gateway pod for CLIProxyAPI health check"
fi

# -------------------------------------------------------------------
# Check 5: eDiscovery cron exists
# -------------------------------------------------------------------
log "Check 5/5: Checking eDiscovery CronJob..."
CRON_EXISTS=$(kubectl --kubeconfig="$KUBECONFIG" -n "$NAMESPACE" \
  get cronjob ediscovery-archive -o name 2>/dev/null) || CRON_EXISTS=""

if [[ -n "$CRON_EXISTS" ]]; then
  pass_check "eDiscovery CronJob exists"
else
  fail_check "eDiscovery CronJob 'ediscovery-archive' not found in namespace $NAMESPACE"
fi

# -------------------------------------------------------------------
# Results
# -------------------------------------------------------------------
echo ""
log "========================================="
if [[ "$FAILURES" -eq 0 ]]; then
  log "SMOKE TEST PASSED (all checks green)"
  exit 0
else
  log "SMOKE TEST FAILED ($FAILURES check(s) failed)"
  exit 1
fi
