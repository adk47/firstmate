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
#   openclaw-gateway-{main,edge,dev}.service.d/override.conf
#     Drop-ins that add ExecStartPre self-heal + a restart ceiling
#     so a schema-invalid openclaw.json can't crash-loop the
#     gateway indefinitely. Added 2026-05-05 after a 30-min main-
#     gateway outage caused by an out-of-band write that added an
#     unrecognized `subagents` top-level key. Heal logic in
#     scripts/openclaw-pre-start-heal.sh; reference template in
#     scripts/aux-units/openclaw-gateway.override.conf.
#
#   openclaw-config-write-audit.path / .service
#     Watches /root/.openclaw-{main,edge,dev}/openclaw.json for
#     writes and runs scripts/openclaw-config-write-audit.sh,
#     which Slack-alerts on any writer that isn't the gateway
#     itself. Plugs the audit gap in openclaw's own config-io
#     module (out-of-band writes leave no audit-log trace — see
#     reference_openclaw_config_audit_gap.md).
#
#   /etc/cron.d/openclaw-watchdog
#     Schedules scripts/openclaw-watchdog.sh every 2 minutes.
#     Replaces the manually-installed `crontab -e` entry that
#     previously held this. The 2-min cadence (down from 10)
#     was added in the same 2026-05-05 fix because the worst-case
#     detection lag was the dominant component of the outage's
#     ops-silent window.
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
# Safe to run on every deploy. The gateway *base* unit files are
# owned by migrate-to-multi-gateway.sh; this script only manages
# drop-ins (.service.d/override.conf) which systemd layers on top,
# so a re-run of the migration script does not stomp on what we
# install here.
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
[[ -x "$HYDRA_ROOT/scripts/openclaw-pre-start-heal.sh" ]] \
  || fail "$HYDRA_ROOT/scripts/openclaw-pre-start-heal.sh missing or not executable"
[[ -x "$HYDRA_ROOT/scripts/openclaw-config-write-audit.sh" ]] \
  || fail "$HYDRA_ROOT/scripts/openclaw-config-write-audit.sh missing or not executable"
[[ -x "$HYDRA_ROOT/scripts/openclaw-watchdog.sh" ]] \
  || fail "$HYDRA_ROOT/scripts/openclaw-watchdog.sh missing or not executable"

log "installing into $HYDRA_ROOT"

# Retired-unit cleanup (see file header for rationale).
for stale in hydra-mcp-reap.timer hydra-mcp-reap.service; do
  if [[ -f "/etc/systemd/system/$stale" ]] \
     || systemctl list-unit-files --no-pager 2>/dev/null | grep -q "^$stale"; then
    systemctl disable --now "$stale" >/dev/null 2>&1 || true
    rm -f "/etc/systemd/system/$stale"
    systemctl reset-failed "$stale" >/dev/null 2>&1 || true
    log "  retired stale unit: $stale"
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

# ─── Gateway pre-start self-heal drop-ins ─────────────────────
# One drop-in per profile, hard-coded with the profile name (the
# base units are not systemd templates so %i is unavailable). The
# drop-in adds ExecStartPre=…/openclaw-pre-start-heal.sh <profile>
# and StartLimitBurst/IntervalSec to break crash-loops cleanly.
# A re-run of migrate-to-multi-gateway.sh recreates the base unit
# but does NOT touch the .service.d/ directory, so the drop-in
# survives. We daemon-reload + reset-failed at the end so a
# previously-tripped restart limit doesn't stick around after
# the heal infrastructure is in place.
for profile in main edge dev; do
  drop_dir="/etc/systemd/system/openclaw-gateway-${profile}.service.d"
  mkdir -p "$drop_dir"
  cat > "$drop_dir/override.conf" << GATEWAYDROP
# MANAGED BY scripts/install-aux-units.sh — DO NOT EDIT BY HAND.
# Reference template: scripts/aux-units/openclaw-gateway.override.conf
[Service]
ExecStartPre=$HYDRA_ROOT/scripts/openclaw-pre-start-heal.sh ${profile}

[Unit]
StartLimitBurst=5
StartLimitIntervalSec=120
GATEWAYDROP
  log "  installed drop-in for openclaw-gateway-${profile}.service"
done

# ─── Out-of-band write audit (.path + .service) ───────────────
# Watches the three live openclaw.json files. On any write event
# (including atomic-rename), runs the audit logger which captures
# the writer and Slack-alerts when it isn't the gateway itself.
cat > /etc/systemd/system/openclaw-config-write-audit.service << AUDITSVC
[Unit]
Description=Audit openclaw.json writes and identify non-gateway writers

[Service]
Type=oneshot
ExecStart=$HYDRA_ROOT/scripts/openclaw-config-write-audit.sh
StartLimitBurst=10
StartLimitIntervalSec=60
AUDITSVC

cat > /etc/systemd/system/openclaw-config-write-audit.path << AUDITPATH
[Unit]
Description=Watch openclaw.json files for writes (out-of-band audit)

[Path]
PathChanged=/root/.openclaw-main/openclaw.json
PathChanged=/root/.openclaw-edge/openclaw.json
PathChanged=/root/.openclaw-dev/openclaw.json

[Install]
WantedBy=multi-user.target
AUDITPATH

# ─── Watchdog cron at 2-min cadence ───────────────────────────
# Owned by /etc/cron.d/openclaw-watchdog rather than a per-user
# crontab so the schedule is reproducible from this script. If
# you need to change the cadence, edit it here and re-run
# install-aux-units.sh — do not edit /etc/cron.d/openclaw-watchdog
# directly on node-8 (it'll be overwritten on the next deploy).
cat > /etc/cron.d/openclaw-watchdog << CRONWATCHDOG
# MANAGED BY scripts/install-aux-units.sh — DO NOT EDIT BY HAND.
# 2-min cadence dropped from 10 min after the 2026-05-05 outage:
# detection-lag was the dominant component of the silent window.
*/2 * * * * root $HYDRA_ROOT/scripts/openclaw-watchdog.sh >> /var/log/openclaw-watchdog.log 2>&1
CRONWATCHDOG
chmod 644 /etc/cron.d/openclaw-watchdog

# Drop the legacy per-user crontab line if it's still installed.
# Idempotent: removes the line if present, no-op otherwise.
if crontab -l 2>/dev/null | grep -q openclaw-watchdog.sh; then
  crontab -l 2>/dev/null | grep -v openclaw-watchdog.sh | crontab -
  log "  removed legacy openclaw-watchdog entry from root's user crontab"
fi

systemctl daemon-reload

# Activate the audit watcher.
systemctl enable openclaw-config-write-audit.path >/dev/null 2>&1 \
  || log "WARN: could not enable openclaw-config-write-audit.path"
systemctl restart openclaw-config-write-audit.path >/dev/null 2>&1 \
  || log "WARN: could not restart openclaw-config-write-audit.path"
audit_state=$(systemctl is-active openclaw-config-write-audit.path 2>/dev/null || echo unknown)
log "  openclaw-config-write-audit.path: $audit_state"

# Clear any previously-tripped restart limits on the gateways so
# the new ExecStartPre gets a fresh restart budget.
for profile in main edge dev; do
  systemctl reset-failed "openclaw-gateway-${profile}.service" >/dev/null 2>&1 || true
done

log "post-2026-05-05 hardening: drop-ins, write-audit, and 2-min watchdog cron installed."
