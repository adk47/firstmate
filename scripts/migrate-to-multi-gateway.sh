#!/usr/bin/env bash
set -euo pipefail

# ONE-TIME MIGRATION: Single gateway → 3-profile multi-gateway
# =============================================================
# Run this ON Node 8 BEFORE merging PR #43.
# Delete this script after cutover is confirmed stable.
#
# What it does:
# 1. Creates 3 systemd service files (main, edge, dev)
# 2. Creates profile directories and copies configs
# 3. Runs openclaw --profile setup for each
# 4. Installs Intercom plugin in edge profile
# 5. Starts new gateways (coexist with old on different ports)
# 6. Updates Caddyfile for Intercom webhook → edge port
# 7. Stops and disables old gateway

HYDRA_ROOT="/opt/hydra"
OPENCLAW_BIN="/usr/bin/node /usr/lib/node_modules/openclaw/dist/index.js"

log() { echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] $*"; }
fail() { log "FATAL: $*"; exit 1; }

# -------------------------------------------------------------------
# Pre-flight checks
# -------------------------------------------------------------------
log "Pre-flight checks..."
[[ -f "$HYDRA_ROOT/openclaw-main.json" ]] || fail "openclaw-main.json not found in $HYDRA_ROOT — sync the repo first"
[[ -f "$HYDRA_ROOT/openclaw-edge.json" ]] || fail "openclaw-edge.json not found in $HYDRA_ROOT"
[[ -f "$HYDRA_ROOT/openclaw-dev.json" ]] || fail "openclaw-dev.json not found in $HYDRA_ROOT"
python3 -m json.tool "$HYDRA_ROOT/openclaw-main.json" > /dev/null || fail "openclaw-main.json is invalid JSON"
python3 -m json.tool "$HYDRA_ROOT/openclaw-edge.json" > /dev/null || fail "openclaw-edge.json is invalid JSON"
python3 -m json.tool "$HYDRA_ROOT/openclaw-dev.json" > /dev/null || fail "openclaw-dev.json is invalid JSON"
log "  All configs present and valid."

# -------------------------------------------------------------------
# Step 1: Create environment files and systemd service files
# -------------------------------------------------------------------
log "Step 1/7: Creating environment files and systemd services..."

ENV_DIR="/etc/openclaw"
mkdir -p "$ENV_DIR"

# Extract secrets from the current systemd service into per-profile env files.
# Secrets stay in 600-permissioned files, never in the unit files themselves.

# Shared env (all gateways)
cat > "$ENV_DIR/shared.env" << 'SHAREDEOF'
HOME=/root
NODE_EXTRA_CA_CERTS=/etc/ssl/certs/ca-certificates.crt
NODE_USE_SYSTEM_CA=1
OPENCLAW_SERVICE_MARKER=openclaw
OPENCLAW_SERVICE_KIND=gateway
SHAREDEOF

# Extract all env vars from the existing service file into main.env
# This captures every secret the old gateway had
grep '^Environment=' /etc/systemd/system/openclaw-gateway.service \
  | sed 's/^Environment=//' \
  > "$ENV_DIR/main.env"

# Edge env — only what CS/Intercom needs (subset of main)
grep -E '^(OPENAI_API_KEY|CLIPROXY_API_KEY|MUSOAI_INTERCOM_TOKEN)=' "$ENV_DIR/main.env" \
  > "$ENV_DIR/edge.env"

# Dev env — minimal (just API proxy access)
grep -E '^(OPENAI_API_KEY|CLIPROXY_API_KEY)=' "$ENV_DIR/main.env" \
  > "$ENV_DIR/dev.env"

# Lock down permissions — only root can read
chmod 600 "$ENV_DIR"/*.env
log "  Environment files created in $ENV_DIR/ (mode 600)"

# Main gateway service
cat > /etc/systemd/system/openclaw-gateway-main.service << MAINSVC
[Unit]
Description=OpenClaw Gateway HYDRA (main profile)
After=network-online.target docker.service

[Service]
Type=simple
User=root
EnvironmentFile=$ENV_DIR/shared.env
EnvironmentFile=$ENV_DIR/main.env
ExecStart=$OPENCLAW_BIN --profile main gateway --port 18789
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
MAINSVC

# Edge gateway service (minimal — only what CS/Intercom needs)
cat > /etc/systemd/system/openclaw-gateway-edge.service << EDGESVC
[Unit]
Description=OpenClaw Gateway HYDRA (edge profile — CS/Intercom)
After=network-online.target docker.service

[Service]
Type=simple
User=root
EnvironmentFile=$ENV_DIR/shared.env
EnvironmentFile=$ENV_DIR/edge.env
ExecStart=$OPENCLAW_BIN --profile edge gateway --port 18810
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EDGESVC

# Dev gateway service (minimal — only what dev agents need)
cat > /etc/systemd/system/openclaw-gateway-dev.service << DEVSVC
[Unit]
Description=OpenClaw Gateway HYDRA (dev profile — operations-dev)
After=network-online.target docker.service

[Service]
Type=simple
User=root
EnvironmentFile=$ENV_DIR/shared.env
EnvironmentFile=$ENV_DIR/dev.env
ExecStart=$OPENCLAW_BIN --profile dev gateway --port 18830
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
DEVSVC

systemctl daemon-reload
log "  Created 3 systemd service files (secrets in EnvironmentFile, not inline)."

# -------------------------------------------------------------------
# Step 2: Create profile directories and copy configs
# -------------------------------------------------------------------
log "Step 2/7: Setting up profile directories..."

for profile in main edge dev; do
  mkdir -p "/root/.openclaw/${profile}"
  cp "$HYDRA_ROOT/openclaw-${profile}.json" "/root/.openclaw/${profile}/openclaw.json"
  log "  ${profile}: config copied to /root/.openclaw/${profile}/openclaw.json"
done

# -------------------------------------------------------------------
# Step 3: Run openclaw --profile setup for each
# -------------------------------------------------------------------
log "Step 3/7: Running profile setup..."

for profile in main edge dev; do
  log "  Setting up ${profile} profile..."
  openclaw --profile "$profile" setup --non-interactive 2>&1 | tail -3 || log "  WARNING: ${profile} setup returned non-zero (may be OK if already set up)"
done

# -------------------------------------------------------------------
# Step 4: Install Intercom plugin in edge profile
# -------------------------------------------------------------------
log "Step 4/7: Installing Intercom plugin in edge profile..."

# Copy the plugin from the global extensions to the edge profile
INTERCOM_SRC="/root/.openclaw/extensions/intercom"
INTERCOM_DST="/root/.openclaw/edge/extensions/intercom"

if [[ -d "$INTERCOM_SRC" ]]; then
  mkdir -p "/root/.openclaw/edge/extensions"
  cp -r "$INTERCOM_SRC" "$INTERCOM_DST"
  log "  Intercom plugin copied to $INTERCOM_DST"
else
  log "  WARNING: Intercom plugin not found at $INTERCOM_SRC — trying openclaw plugin install..."
  openclaw --profile edge plugin install intercom 2>&1 | tail -5 || fail "Failed to install Intercom plugin in edge profile"
fi

# -------------------------------------------------------------------
# Step 5: Start new gateways (coexist with old)
# -------------------------------------------------------------------
log "Step 5/7: Starting new gateway services..."

for profile in main edge dev; do
  systemctl enable "openclaw-gateway-${profile}"
  systemctl start "openclaw-gateway-${profile}"
  sleep 3
  if systemctl is-active "openclaw-gateway-${profile}" &>/dev/null; then
    log "  openclaw-gateway-${profile}: RUNNING"
  else
    log "  ERROR: openclaw-gateway-${profile} failed to start"
    journalctl -u "openclaw-gateway-${profile}" --no-pager -n 10
    fail "Gateway ${profile} failed to start — aborting migration"
  fi
done

log "  All 3 new gateways running. Old gateway still active on port 18789."
log "  NOTE: main and old gateway both claim port 18789 — main may have failed to bind."
log "  This is expected. We'll stop the old gateway in step 7."

# -------------------------------------------------------------------
# Step 6: Update Caddy — route Intercom webhook to edge
# -------------------------------------------------------------------
log "Step 6/7: Updating Caddyfile..."

CADDYFILE="/etc/caddy/Caddyfile"
cp "$CADDYFILE" "${CADDYFILE}.backup-$(date +%Y%m%d)"

cat > "$CADDYFILE" << 'CADDY'
hydra.muso.ai {
    @intercom_webhook path /intercom/webhook
    handle @intercom_webhook {
        reverse_proxy localhost:18810
    }

    handle {
        basic_auth {
            ak47 $2a$14$1WcVIUzB.Vk04N5UzCruLedgH5InOGkul8cX1YHtG1VwHzLLlijRG
        }
        reverse_proxy localhost:18789
    }
}
CADDY

systemctl reload caddy
log "  Caddyfile updated — /intercom/webhook → localhost:18810"

# -------------------------------------------------------------------
# Step 7: Stop and disable old gateway
# -------------------------------------------------------------------
log "Step 7/7: Stopping old gateway..."

systemctl stop openclaw-gateway
systemctl disable openclaw-gateway
log "  openclaw-gateway stopped and disabled."

# Restart main gateway now that port 18789 is free
systemctl restart openclaw-gateway-main
sleep 5
if systemctl is-active openclaw-gateway-main &>/dev/null; then
  log "  openclaw-gateway-main restarted on port 18789: RUNNING"
else
  fail "openclaw-gateway-main failed to restart after freeing port 18789"
fi

# -------------------------------------------------------------------
# Done
# -------------------------------------------------------------------
echo ""
log "========================================="
log "MIGRATION COMPLETE"
log "========================================="
log ""
log "Active services:"
log "  openclaw-gateway-main  → port 18789 (9 core agents)"
log "  openclaw-gateway-edge  → port 18810 (support + Intercom)"
log "  openclaw-gateway-dev   → port 18830 (operations-dev)"
log ""
log "Old service: openclaw-gateway (stopped + disabled)"
log "Caddy: /intercom/webhook → localhost:18810"
log ""
log "Next: merge PR #43 and verify the first deploy succeeds."
log "Rollback: systemctl start openclaw-gateway && systemctl stop openclaw-gateway-{main,edge,dev}"
