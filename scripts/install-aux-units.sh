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
#   openclaw-gateway-{main,edge}.service.d/override.conf
#     Drop-ins that add ExecStartPre self-heal + a restart ceiling
#     so a schema-invalid openclaw.json can't crash-loop the
#     gateway indefinitely. Added 2026-05-05 after a 30-min main-
#     gateway outage caused by an out-of-band write that added an
#     unrecognized `subagents` top-level key. Heal logic in
#     scripts/openclaw-pre-start-heal.sh; reference template in
#     scripts/aux-units/openclaw-gateway.override.conf.
#
#   openclaw-config-write-audit@<profile>.path / .service
#     Per-profile template instances (@main, @edge). Each watches
#     /root/.openclaw-<profile>/openclaw.json and runs
#     scripts/openclaw-config-write-audit.sh against that path,
#     which Slack-alerts on any writer that isn't the gateway
#     itself. Plugs the audit gap in openclaw's own config-io
#     module (out-of-band writes leave no audit-log trace — see
#     reference_openclaw_config_audit_gap.md). The singleton form
#     (pre-2026-05-12) is auto-disabled by this installer if found.
#
#   /etc/cron.d/openclaw-watchdog
#     Schedules scripts/openclaw-watchdog.sh every 2 minutes.
#     Replaces the manually-installed `crontab -e` entry that
#     previously held this. The 2-min cadence (down from 10)
#     was added in the same 2026-05-05 fix because the worst-case
#     detection lag was the dominant component of the outage's
#     ops-silent window.
#
#   hydra-release.timer / .service
#     Daily-release cron. Mon..Fri 08:00 Europe/Rome. Invokes
#     scripts/release-cron.sh, which:
#       1. cd's to a DEDICATED git checkout at /var/lib/hydra-release/
#          (NOT /opt/hydra — that's the rsync target with no .git).
#          Initialized below on first deploy, fetched + reset to
#          origin/main on every fire.
#       2. Date-gates the FIRST real fire to 2026-05-28T06:00Z
#          (Thursday 8am Rome, CEST). Before that, the script logs
#          "not yet active" and exits 0 — the gate lets the timer be
#          enabled now without auto-publishing before Aaron has had
#          a day to validate the manual v2026.5.26 cut.
#       3. Execs release.sh --no-edit.
#     SuccessExitStatus on the service whitelists exit 10 (release.sh's
#     "no commits in range — nothing to release") but NOT exit 1 (all
#     other failures, e.g. dirty tree, auth, push failed). Caught in
#     Clio's review of PR #340; pre-fix `0 1` would have masked real
#     broken-release failures as success.
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
[[ -x "$HYDRA_ROOT/scripts/release-cron.sh" ]] \
  || fail "$HYDRA_ROOT/scripts/release-cron.sh missing or not executable"

log "installing into $HYDRA_ROOT"

# Retired-unit cleanup (see file header for rationale).
# - hydra-mcp-reap.{timer,service}: replaced by per-gateway pgid handling.
# - openclaw-gateway-dev.service: dev profile retired with operations-dev workspace.
for stale in hydra-mcp-reap.timer hydra-mcp-reap.service openclaw-gateway-dev.service; do
  if [[ -f "/etc/systemd/system/$stale" ]] \
     || systemctl list-unit-files --no-pager 2>/dev/null | grep -q "^$stale"; then
    systemctl disable --now "$stale" >/dev/null 2>&1 || true
    rm -rf "/etc/systemd/system/$stale" "/etc/systemd/system/${stale}.d"
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

# ─── Intercom intake-outage watchdog ─────────────────────────
# Alerts #clio_devops (C0ADV2W76G4) via the devops bot when inbound
# Intercom conversations stop being processed — the failure that
# silently stranded ~808 customers during the April 2026 webhook
# outage (memory:project_intercom_webhook_outage_2026-04-28). Read-only
# against Intercom; posts Slack only when the processed-fraction drops
# below threshold over a window that has had time to be handled.
# Token: MUSOAI_INTERCOM_TOKEN from the env files; devops botToken from
# the openclaw config (resolved in the script). See
# scripts/intercom-intake-watchdog.py.
cat > /etc/systemd/system/intercom-intake-watchdog.service << INTAKEWDSVC
[Unit]
Description=Intercom intake-outage watchdog (alerts #clio_devops)
After=network-online.target

[Service]
Type=oneshot
EnvironmentFile=-/etc/openclaw/shared.env
EnvironmentFile=-/etc/openclaw/edge.env
ExecStart=/usr/bin/python3 $HYDRA_ROOT/scripts/intercom-intake-watchdog.py --alert
INTAKEWDSVC

cat > /etc/systemd/system/intercom-intake-watchdog.timer << INTAKEWDTMR
[Unit]
Description=Run the Intercom intake-outage watchdog every 2h

[Timer]
OnBootSec=10min
OnUnitActiveSec=2h
Unit=intercom-intake-watchdog.service

[Install]
WantedBy=timers.target
INTAKEWDTMR

systemctl daemon-reload
wd=intercom-intake-watchdog.timer
systemctl enable "$wd" >/dev/null 2>&1 || log "WARN: could not enable $wd"
systemctl start "$wd" >/dev/null 2>&1 || log "WARN: could not start $wd"
log "  $wd: $(systemctl is-active "$wd" 2>/dev/null || echo unknown)"

# ─── Close resolved-ticket conversations (steady-state sync) ──
# Silently closes Intercom conversations whose ClickUp ticket(s) are all
# resolved AND where we replied last — keeps "ticket resolved" and "chat
# closed" in sync so the open-conversation pile stops regrowing on that axis.
# Conservative + reversible: never closes a chat that has an open ticket, a
# customer waiting on us, or one that was never answered; every close is
# shadow-logged to /var/log/close-resolved-shadow.jsonl. No customer-facing
# message. See scripts/close-resolved-conversations.py.
cat > /etc/systemd/system/close-resolved-conversations.service << CLOSERESVC
[Unit]
Description=Close Intercom conversations whose ClickUp ticket is resolved
After=network-online.target

[Service]
Type=oneshot
EnvironmentFile=-/etc/openclaw/shared.env
EnvironmentFile=-/etc/openclaw/edge.env
ExecStart=/usr/bin/python3 $HYDRA_ROOT/scripts/close-resolved-conversations.py --apply
CLOSERESVC

cat > /etc/systemd/system/close-resolved-conversations.timer << CLOSERESTMR
[Unit]
Description=Daily sync — close resolved-ticket conversations

[Timer]
OnBootSec=20min
OnUnitActiveSec=24h
Unit=close-resolved-conversations.service

[Install]
WantedBy=timers.target
CLOSERESTMR

systemctl daemon-reload
cr=close-resolved-conversations.timer
systemctl enable "$cr" >/dev/null 2>&1 || log "WARN: could not enable $cr"
systemctl start "$cr" >/dev/null 2>&1 || log "WARN: could not start $cr"
log "  $cr: $(systemctl is-active "$cr" 2>/dev/null || echo unknown)"

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
for profile in main edge; do
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

# ─── Out-of-band write audit (@.path + @.service per profile) ─
# One .path + .service instance per profile, so each instance
# knows exactly which openclaw.json fired and the audit script
# doesn't have to scan both profiles (the pre-2026-05-12 singleton
# did that, producing cross-profile false-positive Slack alerts on
# every deploy — see scripts/aux-units/openclaw-config-write-audit@.path
# header).
cat > /etc/systemd/system/openclaw-config-write-audit@.service << AUDITSVC
[Unit]
Description=Audit /root/.openclaw-%i/openclaw.json writes and identify non-gateway writers
# StartLimit* are [Unit]-level directives. The pre-2026-05-15
# singleton put them under [Service] and systemd silently ignored
# them; this template gets them right. Caught in PR #288 review.
StartLimitBurst=10
StartLimitIntervalSec=60

[Service]
Type=oneshot
ExecStart=$HYDRA_ROOT/scripts/openclaw-config-write-audit.sh /root/.openclaw-%i/openclaw.json
AUDITSVC

cat > /etc/systemd/system/openclaw-config-write-audit@.path << AUDITPATH
[Unit]
Description=Watch /root/.openclaw-%i/openclaw.json for writes (out-of-band audit)

[Path]
PathChanged=/root/.openclaw-%i/openclaw.json

[Install]
WantedBy=multi-user.target
AUDITPATH

# Idempotent cleanup of the pre-2026-05-12 singleton units. If a
# deploy lands on a host that still has them, both the singleton
# and the per-profile instances would fire — doubling the audit
# work and re-introducing the cross-profile false positive.
for legacy in openclaw-config-write-audit.path openclaw-config-write-audit.service; do
  if [[ -f "/etc/systemd/system/$legacy" ]] \
     || systemctl list-unit-files --no-pager 2>/dev/null | grep -q "^$legacy"; then
    systemctl disable --now "$legacy" >/dev/null 2>&1 || true
    rm -f "/etc/systemd/system/$legacy"
    systemctl reset-failed "$legacy" >/dev/null 2>&1 || true
    log "  retired stale singleton: $legacy"
  fi
done

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

# Activate the per-profile audit watchers.
for profile in main edge; do
  unit="openclaw-config-write-audit@${profile}.path"
  systemctl enable "$unit" >/dev/null 2>&1 \
    || log "WARN: could not enable $unit"
  systemctl restart "$unit" >/dev/null 2>&1 \
    || log "WARN: could not restart $unit"
  state=$(systemctl is-active "$unit" 2>/dev/null || echo unknown)
  log "  $unit: $state"
done

# Clear any previously-tripped restart limits on the gateways so
# the new ExecStartPre gets a fresh restart budget.
for profile in main edge; do
  systemctl reset-failed "openclaw-gateway-${profile}.service" >/dev/null 2>&1 || true
done

# ─── Release checkout (dedicated git clone for the cron) ──────
# release-cron.sh operates against THIS directory, NOT /opt/hydra
# (which has no .git — RSYNC_EXCLUDES strips it). Initialize on
# first deploy via `gh repo clone` so the credential helper that
# `gh auth setup-git` configures works for subsequent git push
# of the release tag. Idempotent: skipped if the .git dir already
# exists on a re-run.
#
# Identity for annotated tag creation (release.sh: `git tag -a`).
# Without user.{name,email}, `git tag -a` errors. Local config so
# it doesn't leak into other root git operations on this host.
# Caught in Clio's review of PR #340.
RELEASE_REPO_PARENT="/var/lib/hydra-release"
RELEASE_REPO_DIR="$RELEASE_REPO_PARENT/repo"
if [[ ! -d "$RELEASE_REPO_DIR/.git" ]]; then
  log "  initializing release checkout at $RELEASE_REPO_DIR..."
  mkdir -p "$RELEASE_REPO_PARENT"
  # Configure git to use gh's credential helper for HTTPS pushes
  # (release.sh does `git push origin <tag>`). Requires `gh auth
  # login` to have happened for root previously — release.sh's
  # preflight will die loudly if not.
  if ! gh auth setup-git >/dev/null 2>&1; then
    log "  WARN: gh auth setup-git failed — release tag pushes may need credentials"
  fi
  if gh repo clone Muso-AI/hydra "$RELEASE_REPO_DIR" -- --quiet >/dev/null 2>&1; then
    git -C "$RELEASE_REPO_DIR" config user.name "Hydra Release Bot"
    git -C "$RELEASE_REPO_DIR" config user.email "releases@muso.ai"
    log "  release checkout ready at $RELEASE_REPO_DIR"
  else
    log "  WARN: release checkout clone failed — hydra-release.service will refuse to fire until repaired"
  fi
else
  log "  release checkout already present at $RELEASE_REPO_DIR (no re-clone needed)"
fi

# ─── Daily-release cron (Mon..Fri 08:00 Europe/Rome) ──────────
# Invokes scripts/release-cron.sh (which lives in /opt/hydra/scripts/
# — synced by Step 4b — but operates AGAINST $RELEASE_REPO_DIR).
# Until 2026-05-28T06:00Z the wrapper logs "not yet active" and
# exits 0; first real release is Thu 5/28.
#
# SuccessExitStatus=0 10: release.sh uses exit 10 (via
# exit_no_release()) ONLY for "no commits in range — nothing to
# release". Every other failure mode keeps exit 1, so systemd
# will mark this unit as failed and alert on real breakage. The
# pre-2026-05-26 form `SuccessExitStatus=0 1` was a foot-gun that
# masked all release.sh failures as success (Clio's PR #340 review).
cat > /etc/systemd/system/hydra-release.service << RELEASESVC
[Unit]
Description=Hydra daily release (cuts a tag + GH release off main)

[Service]
Type=oneshot
# Wrapper cd's into \$RELEASE_REPO_DIR itself; no WorkingDirectory needed.
ExecStart=$HYDRA_ROOT/scripts/release-cron.sh
# Exit 10 = "no commits to release" (release.sh's exit_no_release).
# Exit 1 = real failure (NOT whitelisted — surfaces as service failed).
SuccessExitStatus=0 10
# Keep gh + git working: HOME for gh's config, PATH for system tools.
Environment=HOME=/root
Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
RELEASESVC

cat > /etc/systemd/system/hydra-release.timer << RELEASETMR
[Unit]
Description=Cut a HYDRA release Mon..Fri at 08:00 Europe/Rome

[Timer]
# 08:00 Europe/Rome (CEST UTC+2 / CET UTC+1). systemd interprets
# the timezone qualifier and DST shifts itself.
OnCalendar=Mon..Fri *-*-* 08:00:00 Europe/Rome
# Persistent=true: if hydra was down at 08:00, fire on next boot
# (catches Tuesday-morning power blips). For releases this is the
# right tradeoff — we'd rather fire late than skip.
Persistent=true
# Avoid the thundering herd if anything else triggers at 08:00.
RandomizedDelaySec=30s
Unit=hydra-release.service

[Install]
WantedBy=timers.target
RELEASETMR

systemctl daemon-reload

tmr=hydra-release.timer
systemctl enable "$tmr" >/dev/null 2>&1 || log "WARN: could not enable $tmr"
systemctl start "$tmr" >/dev/null 2>&1 || log "WARN: could not start $tmr"
state=$(systemctl is-active "$tmr" 2>/dev/null || echo unknown)
log "  $tmr: $state (first real fire gated to 2026-05-28T06:00Z)"

# ─── Daily self-improvement audit (08:00 UTC) ─────────────────
# Was a hand-installed root crontab line (untracked, lost on node
# rebuild). Now a tracked systemd timer. The script is synced into
# /opt/hydra/scripts/ by deploy; it reads journald + the main
# openclaw config and posts a digest to #clio_devops.
cat > /etc/systemd/system/hydra-daily-audit.service << AUDITSVC
[Unit]
Description=HYDRA daily self-improvement audit (posts digest to #clio_devops)

[Service]
Type=oneshot
ExecStart=$HYDRA_ROOT/scripts/hydra-daily-audit.py
# HOME for gh's config (release/PR checks), PATH for journalctl + gh.
Environment=HOME=/root
Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
StandardOutput=append:/var/log/hydra-daily-audit.log
StandardError=append:/var/log/hydra-daily-audit.log
AUDITSVC

cat > /etc/systemd/system/hydra-daily-audit.timer << AUDITTMR
[Unit]
Description=Run the HYDRA daily audit at 08:00 UTC

[Timer]
OnCalendar=*-*-* 08:00:00 UTC
# If the box was down at 08:00, fire on next boot rather than skip a day.
Persistent=true
RandomizedDelaySec=60s
Unit=hydra-daily-audit.service

[Install]
WantedBy=timers.target
AUDITTMR

systemctl daemon-reload

# Retire the legacy hand-installed crontab line so it doesn't double-fire.
if crontab -l 2>/dev/null | grep -q "hydra-daily-audit.py"; then
  # `|| true`: when the audit line is the ONLY crontab entry, grep -v yields no
  # output and exits 1, which under `set -euo pipefail` would abort the installer
  # before the timer is enabled. An empty result is a valid "clear it" case; a real
  # `crontab -` failure still surfaces.
  ( crontab -l 2>/dev/null | grep -v "hydra-daily-audit.py" || true ) | crontab -
  log "  removed legacy hydra-daily-audit crontab line (now handled by the timer)"
fi

atmr=hydra-daily-audit.timer
systemctl enable "$atmr" >/dev/null 2>&1 || log "WARN: could not enable $atmr"
systemctl start "$atmr" >/dev/null 2>&1 || log "WARN: could not start $atmr"
astate=$(systemctl is-active "$atmr" 2>/dev/null || echo unknown)
log "  $atmr: $astate (fires daily 08:00 UTC)"

log "post-2026-05-05 hardening: drop-ins, write-audit, and 2-min watchdog cron installed."
