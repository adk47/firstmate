#!/usr/bin/env bash
set -euo pipefail

# HYDRA Smoke Test
# ================
# Post-deploy validation for multi-gateway setup.

NAMESPACE="${NAMESPACE:-hydra}"
KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
AGENT_TIMEOUT=30
CLIPROXYAPI_PORT=8317
FAILURES=0
TARGET="${1:-all}"

# Validate target (supports comma-separated: main,edge)
IFS=',' read -ra TARGET_PARTS <<< "$TARGET"
for t in "${TARGET_PARTS[@]}"; do
  case "$t" in
    main|edge|dev|all) ;;
    *) echo "Error: invalid target '$t'. Must be main|edge|dev|all"; exit 1 ;;
  esac
done

log() { echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] $*"; }
fail_check() { log "FAIL: $*"; FAILURES=$((FAILURES + 1)); }
pass_check() { log "PASS: $*"; }
needs_target() { [[ "$TARGET" == "all" || ",$TARGET," == *",$1,"* ]]; }

# -------------------------------------------------------------------
# Main gateway checks
# -------------------------------------------------------------------
if needs_target "main"; then
  log "Checking main gateway (port 18789)..."
  EXPECTED_MAIN=9
  MAIN_AGENTS=(clio ceo cmo cto qa finance operations devops design)

  AGENT_OUTPUT=$(openclaw --profile main agents list --bindings 2>&1) || true
  AGENT_COUNT=$(echo "$AGENT_OUTPUT" | grep -c 'BOUND' || echo 0)

  if [[ "$AGENT_COUNT" -eq "$EXPECTED_MAIN" ]]; then
    pass_check "Main: $AGENT_COUNT/$EXPECTED_MAIN agents bound"
  else
    fail_check "Main: Expected $EXPECTED_MAIN agents, got $AGENT_COUNT"
    echo "$AGENT_OUTPUT"
  fi

  for agent_id in "${MAIN_AGENTS[@]}"; do
    START=$(date +%s)
    RESPONSE=$(timeout "$AGENT_TIMEOUT" openclaw --profile main agent ping "$agent_id" 2>&1) || RESPONSE="TIMEOUT"
    ELAPSED=$(( $(date +%s) - START ))
    if echo "$RESPONSE" | grep -qi 'pong\|alive\|ok'; then
      pass_check "Main: Agent '$agent_id' responded in ${ELAPSED}s"
    else
      fail_check "Main: Agent '$agent_id' did not respond within ${AGENT_TIMEOUT}s"
    fi
  done

  # Cross-agent mesh test: Clio -> CTO sessions_send ping
  log "  Testing cross-agent mesh (Clio -> CTO)..."
  MESH_RESPONSE=$(timeout "$AGENT_TIMEOUT" openclaw --profile main agent send clio "ping cto via sessions_send and report back" 2>&1) || MESH_RESPONSE="TIMEOUT"
  if echo "$MESH_RESPONSE" | grep -qi 'cto\|responded\|pong\|acknowledged'; then
    pass_check "Main: Cross-agent mesh (Clio -> CTO) working"
  else
    fail_check "Main: Cross-agent mesh test failed"
  fi

  CHANNEL_OUTPUT=$(openclaw --profile main channels status --probe 2>&1) || true
  UNHEALTHY=$(echo "$CHANNEL_OUTPUT" | grep -cv 'HEALTHY' || echo 0)
  UNHEALTHY=$((UNHEALTHY > 0 ? UNHEALTHY - 1 : 0))
  if [[ "$UNHEALTHY" -eq 0 ]]; then
    pass_check "Main: All channels healthy"
  else
    fail_check "Main: $UNHEALTHY unhealthy channels"
    echo "$CHANNEL_OUTPUT"
  fi

  # Cron loading gate — guards against the silent path-drift outage class
  # that took down all the cron jobs for 19 hours on 2026-04-07. The
  # repo file at /opt/hydra/cron-jobs.json is the source of truth; the
  # gateway must report the same job count via `cron status --json`. If
  # the deploy script ever writes to a path the gateway doesn't read
  # again, this check fails the deploy instead of silently shipping
  # zero crons.
  #
  # Both sides explicitly resolved to a SCALAR COUNT to avoid the
  # "compare integer to JSON array" footgun. The repo file's `.jobs`
  # is an array (so we use `.jobs | length`). The CLI's `.jobs` happens
  # to be a number today (verified live: openclaw cron status --json
  # returns {"jobs": 12, ...}), but to be future-proof against the CLI
  # ever switching shape, we handle both with `if type == array then
  # length else . end`.
  if [ ! -f /opt/hydra/cron-jobs.json ]; then
    fail_check "Main: /opt/hydra/cron-jobs.json missing — repo file did not deploy"
  else
    EXPECTED_CRONS=$(jq '.jobs | length' /opt/hydra/cron-jobs.json 2>/dev/null || echo "?")
    LOADED_RAW=$(openclaw --profile main cron status --json 2>&1) || LOADED_RAW=""
    if [ -z "$LOADED_RAW" ]; then
      fail_check "Main: openclaw cron status --json returned nothing (gateway not running?)"
    else
      LOADED_CRONS=$(echo "$LOADED_RAW" | jq 'if (.jobs | type) == "array" then (.jobs | length) else .jobs end' 2>/dev/null || echo "?")
      if [[ "$EXPECTED_CRONS" == "?" || "$LOADED_CRONS" == "?" ]]; then
        fail_check "Main: cron count check failed (expected=$EXPECTED_CRONS loaded=$LOADED_CRONS) — could not parse JSON. Raw output: $LOADED_RAW"
      elif [[ "$LOADED_CRONS" == "$EXPECTED_CRONS" ]]; then
        pass_check "Main: cron scheduler loaded $LOADED_CRONS jobs (matches repo)"
      else
        fail_check "Main: cron count mismatch — repo has $EXPECTED_CRONS, gateway loaded $LOADED_CRONS (was the cron file written to the wrong path?)"
      fi
    fi
  fi
fi

# -------------------------------------------------------------------
# Edge gateway checks
# -------------------------------------------------------------------
if needs_target "edge"; then
  log "Checking edge gateway (port 18810)..."

  AGENT_OUTPUT=$(openclaw --profile edge agents list --bindings 2>&1) || true
  AGENT_COUNT=$(echo "$AGENT_OUTPUT" | grep -c 'BOUND' || echo 0)

  if [[ "$AGENT_COUNT" -eq 1 ]]; then
    pass_check "Edge: 1/1 agents bound"
  else
    fail_check "Edge: Expected 1 agent, got $AGENT_COUNT"
    echo "$AGENT_OUTPUT"
  fi

  START=$(date +%s)
  RESPONSE=$(timeout "$AGENT_TIMEOUT" openclaw --profile edge agent ping "support" 2>&1) || RESPONSE="TIMEOUT"
  ELAPSED=$(( $(date +%s) - START ))
  if echo "$RESPONSE" | grep -qi 'pong\|alive\|ok'; then
    pass_check "Edge: Agent 'support' responded in ${ELAPSED}s"
  else
    fail_check "Edge: Agent 'support' did not respond within ${AGENT_TIMEOUT}s"
  fi

  CHANNEL_OUTPUT=$(openclaw --profile edge channels status --probe 2>&1) || true
  UNHEALTHY=$(echo "$CHANNEL_OUTPUT" | grep -cv 'HEALTHY' || echo 0)
  UNHEALTHY=$((UNHEALTHY > 0 ? UNHEALTHY - 1 : 0))
  if [[ "$UNHEALTHY" -eq 0 ]]; then
    pass_check "Edge: All channels healthy"
  else
    fail_check "Edge: $UNHEALTHY unhealthy channels"
    echo "$CHANNEL_OUTPUT"
  fi
fi

# -------------------------------------------------------------------
# Dev gateway checks
# -------------------------------------------------------------------
if needs_target "dev"; then
  log "Checking dev gateway (port 18830)..."

  AGENT_OUTPUT=$(openclaw --profile dev agents list --bindings 2>&1) || true
  AGENT_COUNT=$(echo "$AGENT_OUTPUT" | grep -c 'BOUND' || echo 0)

  if [[ "$AGENT_COUNT" -eq 1 ]]; then
    pass_check "Dev: 1/1 agents bound"
  else
    fail_check "Dev: Expected 1 agent, got $AGENT_COUNT"
    echo "$AGENT_OUTPUT"
  fi

  START=$(date +%s)
  RESPONSE=$(timeout "$AGENT_TIMEOUT" openclaw --profile dev agent ping "operations-dev" 2>&1) || RESPONSE="TIMEOUT"
  ELAPSED=$(( $(date +%s) - START ))
  if echo "$RESPONSE" | grep -qi 'pong\|alive\|ok'; then
    pass_check "Dev: Agent 'operations-dev' responded in ${ELAPSED}s"
  else
    fail_check "Dev: Agent 'operations-dev' did not respond within ${AGENT_TIMEOUT}s"
  fi

  CHANNEL_OUTPUT=$(openclaw --profile dev channels status --probe 2>&1) || true
  UNHEALTHY=$(echo "$CHANNEL_OUTPUT" | grep -cv 'HEALTHY' || echo 0)
  UNHEALTHY=$((UNHEALTHY > 0 ? UNHEALTHY - 1 : 0))
  if [[ "$UNHEALTHY" -eq 0 ]]; then
    pass_check "Dev: All channels healthy"
  else
    fail_check "Dev: $UNHEALTHY unhealthy channels"
    echo "$CHANNEL_OUTPUT"
  fi
fi

# -------------------------------------------------------------------
# CLIProxyAPI health check (optional — only if Anthropic fallback is active)
# -------------------------------------------------------------------
log "Checking CLIProxyAPI /health..."
HEALTH_RESPONSE=$(curl -sf "http://127.0.0.1:${CLIPROXYAPI_PORT:-8317}/health" 2>&1) || HEALTH_RESPONSE="UNREACHABLE"
if echo "$HEALTH_RESPONSE" | grep -qi 'ok\|healthy'; then
  pass_check "CLIProxyAPI /health returned OK"
else
  # Non-fatal: CLIProxyAPI is only needed for Anthropic fallback
  log "  WARN: CLIProxyAPI not reachable (non-fatal — Fireworks is primary)"
fi

# -------------------------------------------------------------------
# Results
# -------------------------------------------------------------------
echo ""
log "========================================="
if [[ "$FAILURES" -eq 0 ]]; then
  log "SMOKE TEST PASSED (target: $TARGET, all checks green)"
  exit 0
else
  log "SMOKE TEST FAILED (target: $TARGET, $FAILURES check(s) failed)"
  exit 1
fi
