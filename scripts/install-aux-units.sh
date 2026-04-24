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
# Also cleans up the retired `hydra-mcp-reap.{timer,service}` if
# present on the host. That unit reaped orphan `mcp-remote`
# subprocesses but sent SIGTERM to the gateway's own process group
# (mcp-remote children inherited the gateway's pgid), taking the
# gateway down every 15 min once orphans crossed 30m etime.
# The root cause — bundle-mcp shelling out to `npx mcp-remote` —
# is fixed by configuring remote MCP servers with the native
# `transport: "streamable-http"` shape. With no mcp-remote in the
# config, there's nothing to reap. See lint-openclaw-config.sh
# for the regression guard.
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

log "installing into $HYDRA_ROOT"

# ── Retired unit cleanup ──────────────────────────────────────
# hydra-mcp-reap was removed after the native streamable-http
# migration made it unnecessary (and it was actively harmful —
# see file header). Disable + remove if still installed.
for stale in hydra-mcp-reap.timer hydra-mcp-reap.service; do
  if [[ -f "/etc/systemd/system/$stale" ]] \
     || systemctl list-unit-files --no-pager 2>/dev/null | grep -q "^$stale"; then
    log "  retiring stale unit: $stale"
    systemctl disable --now "$stale" >/dev/null 2>&1 || true
    rm -f "/etc/systemd/system/$stale"
    systemctl reset-failed "$stale" >/dev/null 2>&1 || true
  fi
done

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

systemctl daemon-reload

tmr=hydra-peer-labels.timer
systemctl enable "$tmr" >/dev/null 2>&1 || log "WARN: could not enable $tmr"
systemctl start "$tmr" >/dev/null 2>&1 || log "WARN: could not start $tmr"
state=$(systemctl is-active "$tmr" 2>/dev/null || echo unknown)
log "  $tmr: $state"

log "done. Next fires:"
systemctl list-timers "$tmr" --no-pager 2>/dev/null | head -4 || true
