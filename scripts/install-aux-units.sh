#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────
# install-aux-units.sh
#
# Idempotently install the auxiliary systemd units that sit
# alongside the three openclaw-gateway-* services:
#
#   hydra-peer-labels.timer / .service
#     Reconciles agent:<id>:main session labels every 5 min so
#     sessions.resolve({ label: "@Role" }) keeps working for
#     agent-to-agent messaging. Also runs on boot.
#
#   hydra-mcp-reap.timer / .service
#     Kills orphaned `mcp-remote` subprocesses older than 30 min
#     that are parented to an openclaw-gateway-* unit. Mitigates
#     an upstream bundle-mcp leak (216 procs / 14.77 GB observed
#     on 2026-04-24).
#
# Safe to run on every deploy. Does NOT touch the three gateway
# service units — those are owned by migrate-to-multi-gateway.sh.
#
# Usage: sudo scripts/install-aux-units.sh [HYDRA_ROOT]
#        (HYDRA_ROOT defaults to /opt/hydra)
# ──────────────────────────────────────────────────────────────
set -euo pipefail

HYDRA_ROOT="${1:-/opt/hydra}"

log() { echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] install-aux-units: $*"; }
fail() { log "FATAL: $*"; exit 1; }

[[ $EUID -eq 0 ]] || fail "must run as root (systemd unit writes require it)"
[[ -x "$HYDRA_ROOT/scripts/provision-peer-labels.sh" ]] \
  || fail "$HYDRA_ROOT/scripts/provision-peer-labels.sh missing or not executable"
[[ -x "$HYDRA_ROOT/scripts/reap-mcp-remote-zombies.sh" ]] \
  || fail "$HYDRA_ROOT/scripts/reap-mcp-remote-zombies.sh missing or not executable"

log "installing into $HYDRA_ROOT"

# Peer-label reconciler (all profiles).
cat > /etc/systemd/system/hydra-peer-labels.service << PEERLABELSVC
[Unit]
Description=Hydra peer-label reconciler (all profiles)

[Service]
Type=oneshot
ExecStart=$HYDRA_ROOT/scripts/provision-peer-labels.sh main
ExecStart=$HYDRA_ROOT/scripts/provision-peer-labels.sh edge
ExecStart=$HYDRA_ROOT/scripts/provision-peer-labels.sh dev
PEERLABELSVC

cat > /etc/systemd/system/hydra-peer-labels.timer << PEERLABELTMR
[Unit]
Description=Reconcile peer-message labels every 5 minutes

[Timer]
OnBootSec=2min
OnUnitActiveSec=5min
Unit=hydra-peer-labels.service

[Install]
WantedBy=timers.target
PEERLABELTMR

# MCP-remote zombie reaper.
cat > /etc/systemd/system/hydra-mcp-reap.service << MCPREAPSVC
[Unit]
Description=Hydra MCP-remote zombie reaper

[Service]
Type=oneshot
ExecStart=$HYDRA_ROOT/scripts/reap-mcp-remote-zombies.sh 30
MCPREAPSVC

cat > /etc/systemd/system/hydra-mcp-reap.timer << MCPREAPTMR
[Unit]
Description=Reap orphan mcp-remote processes every 15 minutes

[Timer]
OnBootSec=5min
OnUnitActiveSec=15min
Unit=hydra-mcp-reap.service

[Install]
WantedBy=timers.target
MCPREAPTMR

systemctl daemon-reload

for tmr in hydra-peer-labels.timer hydra-mcp-reap.timer; do
  systemctl enable "$tmr" >/dev/null 2>&1 || log "WARN: could not enable $tmr"
  systemctl start "$tmr" >/dev/null 2>&1 || log "WARN: could not start $tmr"
  state=$(systemctl is-active "$tmr" 2>/dev/null || echo unknown)
  log "  $tmr: $state"
done

log "done. Next fires:"
systemctl list-timers hydra-peer-labels.timer hydra-mcp-reap.timer --no-pager 2>/dev/null \
  | head -4 || true
