#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────
# provision-peer-labels.sh
#
# Populate `label` on each agent's `:main` session so peer
# messaging via `sessions.resolve({ label: "@Role" })` works.
#
# WHY: AGENTS.md tells agents to reach each other with @Clio,
# @CTO, @Finance, @Ops, etc. The gateway's sessions.resolve
# filters sessions by row.label === parsedLabel.label. Sessions
# start with label=null, so label-based resolution always
# returns "No session found with label: @X" and peer messages
# never deliver. We saw 21 consecutive failures in 24h on
# openclaw-gateway-main, 0 successes (2026-04-24).
#
# This script:
#   1. Ensures agent:<id>:main exists for each configured peer
#      (creates via sessions.create RPC if missing).
#   2. Writes label into sessions.json directly (idempotent).
#
# Runs as ExecStartPost after each gateway restart AND via a
# systemd timer every 5 minutes to reconcile any new sessions
# created between restarts.
#
# Usage: provision-peer-labels.sh [profile]   # default: main
# ──────────────────────────────────────────────────────────────
set -euo pipefail

PROFILE="${1:-main}"
OPENCLAW_HOME="/root/.openclaw-${PROFILE}"
OPENCLAW_JSON="${OPENCLAW_HOME}/openclaw.json"
OPENCLAW_BIN="${OPENCLAW_BIN:-/usr/bin/openclaw}"

# Port + label map by profile. Only main hosts the 10-agent roster.
# Edge has an isolated single-agent workflow (support) and does not need
# peer resolution.
case "$PROFILE" in
  main)
    GATEWAY_URL="ws://127.0.0.1:18789/"
    declare -A PEERS=(
      [clio]="@Clio"
      [ceo]="@CEO"
      [cmo]="@CMO"
      [cto]="@CTO"
      [qa]="@QA"
      [finance]="@Finance"
      [operations]="@Ops"
      [devops]="@DevOps"
      [scout]="@Scout"
      [support]="@CS"
    )
    ;;
  edge)
    GATEWAY_URL="ws://127.0.0.1:18810/"
    declare -A PEERS=( [support]="@CS" )
    ;;
  *)
    echo "ERROR: unknown profile '$PROFILE' (expected main/edge)" >&2
    exit 2
    ;;
esac

ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
log() { echo "[$(ts)] provision-peer-labels[$PROFILE]: $*"; }

# Stand down during a planned maintenance window (scripts/hydra-maintenance.sh):
# the 5-min timer would otherwise hammer a deliberately-stopped gateway with
# health/sessions RPCs (and can leave the openclaw CLI holding a gateway open).
# Fail-safe: an absent/expired/malformed flag reads as "not in maintenance".
_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/maintenance-flag.sh
source "$_DIR/lib/maintenance-flag.sh"
if maintenance_active; then
  log "maintenance: $(maintenance_reason) - skipping"
  exit 0
fi

if [[ ! -f "$OPENCLAW_JSON" ]]; then
  log "ERROR: $OPENCLAW_JSON not found — gateway not provisioned?"
  exit 1
fi

# Extract gateway token from openclaw.json. Needed to authenticate
# sessions.create RPCs when a peer's :main session is missing.
TOKEN=$(jq -er '.gateway.auth.token // empty' "$OPENCLAW_JSON") || {
  log "ERROR: could not read .gateway.auth.token from $OPENCLAW_JSON"
  exit 1
}

# Wait up to 30s for the gateway to respond to health probes.
# ExecStartPost fires immediately after ExecStart returns, but the
# WebSocket server may still be binding. Without this wait the
# sessions.create calls below race against startup and fail.
wait_for_gateway() {
  local attempt=0
  while (( attempt < 30 )); do
    if "$OPENCLAW_BIN" --profile "$PROFILE" gateway call health \
        --token "$TOKEN" --url "$GATEWAY_URL" --timeout 2000 --json \
        > /dev/null 2>&1; then
      return 0
    fi
    sleep 1
    attempt=$((attempt + 1))
  done
  log "ERROR: gateway at $GATEWAY_URL did not respond within 30s"
  return 1
}

wait_for_gateway || exit 1

# Phase 1: bootstrap any missing :main sessions via gateway RPC.
# Phase 2 (JSON patch) assumes the file + key already exist.
for agent in "${!PEERS[@]}"; do
  key="agent:${agent}:main"
  sessions_json="${OPENCLAW_HOME}/agents/${agent}/sessions/sessions.json"
  if [[ -f "$sessions_json" ]] && jq -e --arg k "$key" 'has($k)' "$sessions_json" >/dev/null 2>&1; then
    continue
  fi
  # Missing — ask the gateway to create it. The gateway writes the
  # file in the canonical location and we'll patch the label next.
  create_result=$("$OPENCLAW_BIN" --profile "$PROFILE" gateway call sessions.create \
    --params "{\"key\":\"${key}\",\"agentId\":\"${agent}\"}" \
    --token "$TOKEN" --url "$GATEWAY_URL" --timeout 5000 --json 2>&1 || true)
  if echo "$create_result" | jq -e '.ok == true' >/dev/null 2>&1; then
    log "bootstrapped ${key}"
  else
    log "WARN: could not bootstrap ${key}: $(echo "$create_result" | head -c 200)"
  fi
done

# Phase 2: write label directly into sessions.json. We patch the file
# instead of calling sessions.patch RPC because (a) it's a single
# atomic jq operation per file, (b) it works even if the gateway is
# momentarily unreachable, and (c) the store loader re-reads on
# demand so the change takes effect on the next sessions.resolve
# call without any reload signal.
patched=0
skipped=0
for agent in "${!PEERS[@]}"; do
  key="agent:${agent}:main"
  label="${PEERS[$agent]}"
  sessions_json="${OPENCLAW_HOME}/agents/${agent}/sessions/sessions.json"
  if [[ ! -f "$sessions_json" ]]; then
    skipped=$((skipped + 1))
    continue
  fi
  if ! jq -e --arg k "$key" 'has($k)' "$sessions_json" >/dev/null 2>&1; then
    skipped=$((skipped + 1))
    continue
  fi
  # Skip write if already correct — keeps mtime stable.
  current=$(jq -r --arg k "$key" '.[$k].label // ""' "$sessions_json")
  if [[ "$current" == "$label" ]]; then
    continue
  fi
  tmp=$(mktemp)
  jq --arg k "$key" --arg lbl "$label" '.[$k].label = $lbl' \
    "$sessions_json" > "$tmp"
  mv "$tmp" "$sessions_json"
  patched=$((patched + 1))
  log "patched ${key} -> ${label}"
done

log "done: ${patched} patched, ${skipped} skipped"
