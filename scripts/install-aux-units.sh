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
#   /etc/cron.d/cron-health-watchdog
#     Schedules scripts/cron-health-watchdog.sh every 5 minutes to
#     alert #clio_devops on any errored cron run (the missing
#     failure-notification layer behind the 2026-06 silent
#     b2b-reply-scanner breakage).
#
#   /etc/cron.d/fallback-swallow-watchdog
#     Schedules scripts/fallback-swallow-watchdog.sh every 5 minutes
#     to alert #clio_devops when an agent turn ends in an empty
#     completion surfaced as an error — the residual of openclaw's
#     empty-completion-swallows-fallback flaw (2026-06-08 @CMO
#     incident, PR #450) that the chain-reshape CI gate can't reach.
#
#   /etc/cron.d/prod-log-alert-watchdog
#     Schedules scripts/prod-log-alert-watchdog.sh every 5 minutes
#     to post NEW prod error-log lines (kubectl read-only, redacted,
#     fingerprint-deduped) to #prod-alerts C0BA8QMV3ME (Serhii's
#     prod-log-visibility ask, 2026-06-09).
#
#   /etc/cron.d/caroline-rag-index-watchdog
#     Schedules scripts/caroline-rag-index-watchdog.sh every 10 minutes
#     to self-heal + alert #clio_devops when Caroline's memory_search
#     (RAG) vector index is paused / missing / not ready. openclaw
#     pauses the index on every runtime version bump (memory-index-
#     pause-after-upgrade); a paused index returns nothing and the
#     mandatory pre-retrieval RAG hook then answers ungrounded. Forces
#     a rebuild on detection (6h re-page cooldown).
#
#   clickup-sla-digest.timer / .service
#     Daily 08:00 America/New_York. Posts overdue / due-today /
#     due-tomorrow open ClickUp support tickets (SLA due dates set
#     at creation by the support-tools/intercom plugins) to
#     #cs_chats via scripts/clickup-sla-digest.sh. Silent when all
#     buckets are empty.
#
#   close-merged-tickets.timer / .service
#     Daily 07:00 UTC. Runs scripts/dedup/sweeps/close-merged-tickets.sh
#     --apply to close ClickUp profile-merge tickets whose merge already
#     executed (per action_log over Trino). Caroline files these tickets
#     but never merges — Ops executes the tier-2 merge later, and without
#     a schedule the closed-out tickets piled up on the action-request
#     board (Jan, 2026-06-15). The default customer-reply audit keeps it
#     safe: only tickets where the customer was told post-merge are
#     closed; the rest stay open for notify-merged-customers.py.
#
#   /etc/cron.d/stale-ticket-watchdog
#     Schedules scripts/stale-ticket-watchdog.sh daily to post a
#     digest of overdue hydra-action-request ClickUp tickets to
#     #cs_chats C0ANM0PN9L5 (Sandy Vee incident, 2026-05/06: claim
#     tickets sat unworked for weeks while the support agent kept
#     re-promising the SLA).
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
[[ -x "$HYDRA_ROOT/scripts/codex-keepalive.sh" ]] \
  || fail "$HYDRA_ROOT/scripts/codex-keepalive.sh missing or not executable"
[[ -x "$HYDRA_ROOT/scripts/codex-token-refresh.sh" ]] \
  || fail "$HYDRA_ROOT/scripts/codex-token-refresh.sh missing or not executable"
[[ -x "$HYDRA_ROOT/scripts/lib/codex-oauth-refresh.sh" ]] \
  || fail "$HYDRA_ROOT/scripts/lib/codex-oauth-refresh.sh missing or not executable"
[[ -x "$HYDRA_ROOT/scripts/cron-health-watchdog.sh" ]] \
  || fail "$HYDRA_ROOT/scripts/cron-health-watchdog.sh missing or not executable"
[[ -x "$HYDRA_ROOT/scripts/fallback-swallow-watchdog.sh" ]] \
  || fail "$HYDRA_ROOT/scripts/fallback-swallow-watchdog.sh missing or not executable"
[[ -x "$HYDRA_ROOT/scripts/merge-landing-watchdog.sh" ]] \
  || fail "$HYDRA_ROOT/scripts/merge-landing-watchdog.sh missing or not executable"
[[ -x "$HYDRA_ROOT/scripts/prod-log-alert-watchdog.sh" ]] \
  || fail "$HYDRA_ROOT/scripts/prod-log-alert-watchdog.sh missing or not executable"
[[ -x "$HYDRA_ROOT/scripts/clickup-sla-digest.sh" ]] \
  || fail "$HYDRA_ROOT/scripts/clickup-sla-digest.sh missing or not executable"
[[ -x "$HYDRA_ROOT/scripts/stale-ticket-watchdog.sh" ]] \
  || fail "$HYDRA_ROOT/scripts/stale-ticket-watchdog.sh missing or not executable"
[[ -x "$HYDRA_ROOT/scripts/caroline-rag-index-watchdog.sh" ]] \
  || fail "$HYDRA_ROOT/scripts/caroline-rag-index-watchdog.sh missing or not executable"
[[ -x "$HYDRA_ROOT/scripts/openclaw-edge-reindex-on-start.sh" ]] \
  || fail "$HYDRA_ROOT/scripts/openclaw-edge-reindex-on-start.sh missing or not executable"
[[ -f "$HYDRA_ROOT/scripts/overdue-verification-notifier.py" ]] \
  || fail "$HYDRA_ROOT/scripts/overdue-verification-notifier.py missing"
[[ -f "$HYDRA_ROOT/scripts/resolve-notify.py" ]] \
  || fail "$HYDRA_ROOT/scripts/resolve-notify.py missing"
[[ -f "$HYDRA_ROOT/scripts/resolution-matcher.py" ]] \
  || fail "$HYDRA_ROOT/scripts/resolution-matcher.py missing"
[[ -f "$HYDRA_ROOT/scripts/caroline-behavior-digest.py" ]] \
  || fail "$HYDRA_ROOT/scripts/caroline-behavior-digest.py missing"
[[ -x "$HYDRA_ROOT/scripts/release-cron.sh" ]] \
  || fail "$HYDRA_ROOT/scripts/release-cron.sh missing or not executable"
[[ -x "$HYDRA_ROOT/scripts/weekly-cleanup.sh" ]] \
  || fail "$HYDRA_ROOT/scripts/weekly-cleanup.sh missing or not executable"
[[ -x "$HYDRA_ROOT/scripts/dedup/sweeps/close-merged-tickets.sh" ]] \
  || fail "$HYDRA_ROOT/scripts/dedup/sweeps/close-merged-tickets.sh missing or not executable"

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

# ─── Retire the keyword Intercom data-complaint watchdog (replaced 2026-06-25) ──
# The every-10m KEYWORD watchdog (coarse data-noun + complaint-signal buckets)
# produced false "systemic" pages — three unrelated credit gripes grouped as one
# cluster. It is superseded by the AI-clustered `systemic-data-issue-report-daily`
# cron (cron-jobs.json → operations agent → report-systemic-data-issues skill →
# scripts/intercom-data-complaint-watchdog.py --gather / --report), which groups
# by the actual underlying issue. Stop, disable, and remove the old systemd units
# so the two paths can't double-page Aaron. Idempotent: a no-op once removed.
for u in intercom-data-complaint-watchdog.timer intercom-data-complaint-watchdog.service; do
    systemctl disable --now "$u" >/dev/null 2>&1 || true
    rm -f "/etc/systemd/system/$u"
done
systemctl daemon-reload
log "  intercom-data-complaint-watchdog: retired (replaced by systemic-data-issue-report-daily cron)"

# ─── Close resolved-ticket conversations (steady-state sync) ──
# Silently closes Intercom conversations whose ClickUp ticket(s) are all
# resolved AND where we replied last — keeps "ticket resolved" and "chat
# closed" in sync so the open-conversation pile stops regrowing on that axis.
# Conservative + reversible: never closes a chat that has an open ticket, a
# customer waiting on us, or one that was never answered; every close is
# shadow-logged to /var/log/close-resolved-shadow.jsonl. No customer-facing
# message. --notify posts a per-run summary (counts + clickable ClickUp +
# Intercom links) to #cs_chats as the operations bot, but ONLY on runs that
# closed >=1 (no daily noise). See scripts/close-resolved-conversations.py.
cat > /etc/systemd/system/close-resolved-conversations.service << CLOSERESVC
[Unit]
Description=Close Intercom conversations whose ClickUp ticket is resolved
After=network-online.target

[Service]
Type=oneshot
EnvironmentFile=-/etc/openclaw/shared.env
EnvironmentFile=-/etc/openclaw/edge.env
ExecStart=/usr/bin/python3 $HYDRA_ROOT/scripts/close-resolved-conversations.py --apply --notify
CLOSERESVC

cat > /etc/systemd/system/close-resolved-conversations.timer << CLOSERESTMR
[Unit]
Description=Daily sync — close resolved-ticket conversations

[Timer]
OnBootSec=20min
# Every 6h (was 24h): so close follows the resolve-notify "your request is done"
# message within a window instead of up to a day later. The close is unchanged
# (conservative: only we-spoke-last + resolved; shadow-logged; reversible).
OnUnitActiveSec=6h
Unit=close-resolved-conversations.service

[Install]
WantedBy=timers.target
CLOSERESTMR

systemctl daemon-reload
cr=close-resolved-conversations.timer
systemctl enable "$cr" >/dev/null 2>&1 || log "WARN: could not enable $cr"
systemctl start "$cr" >/dev/null 2>&1 || log "WARN: could not start $cr"
log "  $cr: $(systemctl is-active "$cr" 2>/dev/null || echo unknown)"

# ─── Proactive overdue-verification customer notifier (09:00 UTC) ──
# Sends ONE in-app Intercom note to a customer when their verification
# ticket has passed SLA but nobody has worked it — the #1 weekly-digest
# escalation ("delayed verification follow-ups"). Safety-first: seeds
# silently on the first run (sends nothing for the existing backlog),
# per-run cap, fresh pre-send conversation re-check (email cross-match +
# human-reply/handoff suppression), per-conversation dedupe, and a
# wiped-state circuit breaker. SENDING IS LIVE (`--apply` on ExecStart
# below): enabled after 9 days of inert dry-runs showed candidates=0 every
# cycle (steady-state, sentinel-only state), with the #581 blank-email
# fail-closed fix as its prerequisite. State persists across runs in
# /var/lib (idempotency + cold-start seed); the dir is provisioned here,
# idempotently. See scripts/overdue-verification-notifier.py.
install -d -m 755 /var/lib/overdue-verification-notifier
cat > /etc/systemd/system/overdue-verification-notifier.service << OVNOTIFYSVC
[Unit]
Description=Proactively notify customers of overdue verification tickets
After=network-online.target

[Service]
Type=oneshot
EnvironmentFile=-/etc/openclaw/shared.env
EnvironmentFile=-/etc/openclaw/edge.env
ExecStart=/usr/bin/python3 $HYDRA_ROOT/scripts/overdue-verification-notifier.py --apply
OVNOTIFYSVC

cat > /etc/systemd/system/overdue-verification-notifier.timer << OVNOTIFYTMR
[Unit]
Description=Daily — proactively notify customers of overdue verification tickets

[Timer]
OnCalendar=*-*-* 09:00:00 UTC
Persistent=true
RandomizedDelaySec=120
Unit=overdue-verification-notifier.service

[Install]
WantedBy=timers.target
OVNOTIFYTMR

systemctl daemon-reload
ovn=overdue-verification-notifier.timer
systemctl enable "$ovn" >/dev/null 2>&1 || log "WARN: could not enable $ovn"
systemctl start "$ovn" >/dev/null 2>&1 || log "WARN: could not start $ovn"
log "  $ovn: $(systemctl is-active "$ovn" 2>/dev/null || echo unknown)"

# ─── Proactive resolution notifier (every 6h) ─────────────────
# The close-the-loop counterpart of the overdue notifier: sends ONE in-app
# Intercom "your request is sorted" note to a customer when their verification
# ticket flips RESOLVED — today close-resolved-conversations.py closes the chat
# SILENTLY, so a finished request just goes quiet. The notify makes us
# "we spoke last", which is exactly close-resolved's gate, so the close batch
# (above) then closes the conversation. Same safety-first design as the overdue
# notifier: cold-start seeds silently (no backlog blast), per-conversation
# dedupe, fresh pre-send conversation re-check (email cross-match + human-reply/
# closed/handoff suppression; a customer who spoke last is NOT suppressed here),
# per-run cap, and a wiped-state circuit breaker. SENDING IS LIVE (`--apply`
# on ExecStart below). It seeds silently on its first run -- sending 0 --
# whether that first run is the last inert fire or the first --apply fire (the
# cold-start seed write is not --apply-gated); every later run is bounded by the
# wiped-state breaker (<=MAX, else abort+page) + per-message email/dedupe/
# suppression gates, and surfaced by caroline-behavior-digest.py. See
# scripts/resolve-notify.py.
install -d -m 755 /var/lib/resolve-notify
cat > /etc/systemd/system/resolve-notify.service << RESNOTIFYSVC
[Unit]
Description=Proactively notify customers when their request is resolved
After=network-online.target

[Service]
Type=oneshot
EnvironmentFile=-/etc/openclaw/shared.env
EnvironmentFile=-/etc/openclaw/edge.env
ExecStart=/usr/bin/python3 $HYDRA_ROOT/scripts/resolve-notify.py --apply
RESNOTIFYSVC

cat > /etc/systemd/system/resolve-notify.timer << RESNOTIFYTMR
[Unit]
Description=Every 6h — notify customers their request is resolved

[Timer]
OnCalendar=*-*-* 02,08,14,20:00:00 UTC
Persistent=true
RandomizedDelaySec=120
Unit=resolve-notify.service

[Install]
WantedBy=timers.target
RESNOTIFYTMR

systemctl daemon-reload
rn=resolve-notify.timer
systemctl enable "$rn" >/dev/null 2>&1 || log "WARN: could not enable $rn"
systemctl start "$rn" >/dev/null 2>&1 || log "WARN: could not start $rn"
log "  $rn: $(systemctl is-active "$rn" 2>/dev/null || echo unknown)"

# ─── Resolution matcher (daily 12:00 UTC) ─────────────────────
# The RESOLUTION counterpart to the systemic-data-issue REPORT: that report pages
# Aaron daily with the symptom ("N users hit the same data problem") but nothing
# then watches for the fix or tells those users it landed. This closes that loop.
# It reads the clusters the report paged (the append-only feed
# intercom-data-complaint-watchdog.py writes on --report), and for each member
# BACKTESTS their cited entity against action_log: did an admin DATA-FIX route
# touch that exact id AFTER they reported? If so it tells the customer (Caroline
# voice, soft "please verify" note), closes the conversation, flips any linked
# ClickUp ticket, and rolls up to Aaron what his fixes closed (route + who
# shipped it + when). Generalizes close-merged-tickets.sh from the single merge
# route to the set of data-fix routes. SENDING IS LIVE (`--apply` below) per
# Aaron's "go live immediately"; the SAME safety rails as the notifiers keep that
# safe: COLD START — the first --apply fire seeds every open member and sends 0
# (a one-run anti-blast seed; the seed write IS --apply-gated, so a manual dry-run
# previews to stdout but writes no state and never seeds), then a wiped-state
# circuit breaker (<=MAX else abort+page), per-conversation dedupe, a fresh
# pre-send conversation re-check (email cross-match + closed/snoozed/human-
# assignee/human-reply/social-tag suppression), a per-run cap, and a reversible
# shadow log. Runs at 12:00 UTC, after the 06:00 Europe/Rome report has refreshed
# the feed. MUSO_BIN is absolute because systemd's unit PATH does not reliably
# include /usr/local/bin (the backtest queries action_log over Trino via the muso
# CLI). See scripts/resolution-matcher.py.
install -d -m 755 /var/lib/resolution-matcher
cat > /etc/systemd/system/resolution-matcher.service << RESMATCHSVC
[Unit]
Description=Match shipped fixes to systemic-issue tickets, notify customers, close
After=network-online.target

[Service]
Type=oneshot
Environment=MUSO_BIN=/usr/local/bin/muso
EnvironmentFile=-/etc/openclaw/shared.env
EnvironmentFile=-/etc/openclaw/edge.env
ExecStart=/usr/bin/python3 $HYDRA_ROOT/scripts/resolution-matcher.py --apply
RESMATCHSVC

cat > /etc/systemd/system/resolution-matcher.timer << RESMATCHTMR
[Unit]
Description=Daily — close the loop on systemic data issues once their fix ships

[Timer]
OnCalendar=*-*-* 12:00:00 UTC
Persistent=true
RandomizedDelaySec=120
Unit=resolution-matcher.service

[Install]
WantedBy=timers.target
RESMATCHTMR

systemctl daemon-reload
rm_t=resolution-matcher.timer
systemctl enable "$rm_t" >/dev/null 2>&1 || log "WARN: could not enable $rm_t"
systemctl start "$rm_t" >/dev/null 2>&1 || log "WARN: could not start $rm_t"
log "  $rm_t: $(systemctl is-active "$rm_t" 2>/dev/null || echo unknown)"

# ─── Caroline autonomous-behavior digest (daily 16:00 UTC) ────
# Read-only daily digest of Caroline's autonomous self-serve activity so we can
# SEE how she behaves with users and iterate: per-verb outcomes (success vs
# route_to_human vs backend-refused) from the muso-cli capability audit
# (/var/log/muso-ops/tier2-audit.jsonl), the top refusal reasons, reopen-after-
# "done" rate (re-queries Intercom for a customer reply after the resolve-notify
# note), and an ops-relief headline (auto-closes + notifies, week-over-week).
# A CRITICAL safety anomaly (authorized-without-terminal, apply-rate ceiling,
# muso-cli decision-vocab drift) ALSO pages #clio_devops with an @-mention. It
# only READS telemetry + GETs Intercom and WRITES only its own trend state, so
# it is LIVE from day one (no --apply gating like the notifiers). 16:00 UTC is
# off the 08:00 digest cluster so a full EU+US business day is captured.
# See scripts/caroline-behavior-digest.py.
install -d -m 755 /var/lib/caroline-behavior-digest
cat > /etc/systemd/system/caroline-behavior-digest.service << CARODIGESTSVC
[Unit]
Description=Caroline autonomous-behavior daily digest (#cs_chats; pages #clio_devops on a critical anomaly)
After=network-online.target

[Service]
Type=oneshot
EnvironmentFile=-/etc/openclaw/shared.env
EnvironmentFile=-/etc/openclaw/edge.env
ExecStart=/usr/bin/python3 $HYDRA_ROOT/scripts/caroline-behavior-digest.py --post
CARODIGESTSVC

cat > /etc/systemd/system/caroline-behavior-digest.timer << CARODIGESTTMR
[Unit]
Description=Daily — Caroline autonomous-behavior digest at 16:00 UTC

[Timer]
OnCalendar=*-*-* 16:00:00 UTC
Persistent=true
RandomizedDelaySec=120
Unit=caroline-behavior-digest.service

[Install]
WantedBy=timers.target
CARODIGESTTMR

systemctl daemon-reload
cbd=caroline-behavior-digest.timer
systemctl enable "$cbd" >/dev/null 2>&1 || log "WARN: could not enable $cbd"
systemctl start "$cbd" >/dev/null 2>&1 || log "WARN: could not start $cbd"
log "  $cbd: $(systemctl is-active "$cbd" 2>/dev/null || echo unknown)"

# ─── Daily ClickUp SLA digest (08:00 America/New_York) ────────
# Posts overdue / due-today / due-tomorrow open support tickets to
# #cs_chats. Deterministic bash (no LLM, fires even with the gateway
# down). CLICKUP_API_KEY comes from the same env files the
# close-resolved-conversations unit uses; the Slack token is pulled
# from main.env by slack-notify.sh itself.
cat > /etc/systemd/system/clickup-sla-digest.service << SLADIGESTSVC
[Unit]
Description=Daily SLA digest — overdue/today/tomorrow ClickUp tickets to #cs_chats
After=network-online.target

[Service]
Type=oneshot
# muso-cli unification (PR #547): route the read-only ClickUp digest through the
# gated muso clickup provider. MUSO_BIN is absolute because systemd's unit PATH
# does not reliably include /usr/local/bin. Read-only — proven byte-identical to
# the curl path on live data (node-8, 2026-06-17). Revert by removing these two
# lines + re-running install-aux-units.sh.
Environment=USE_MUSO_CLI=1
Environment=MUSO_BIN=/usr/local/bin/muso
EnvironmentFile=-/etc/openclaw/shared.env
EnvironmentFile=-/etc/openclaw/edge.env
ExecStart=$HYDRA_ROOT/scripts/clickup-sla-digest.sh
SLADIGESTSVC

cat > /etc/systemd/system/clickup-sla-digest.timer << SLADIGESTTMR
[Unit]
Description=Daily ClickUp SLA digest at 08:00 America/New_York

[Timer]
# systemd interprets the timezone qualifier and DST shifts itself.
OnCalendar=*-*-* 08:00:00 America/New_York
# If node-8 was down at 08:00, fire on next boot rather than skip the day.
Persistent=true
RandomizedDelaySec=30s
Unit=clickup-sla-digest.service

[Install]
WantedBy=timers.target
SLADIGESTTMR

systemctl daemon-reload
sla=clickup-sla-digest.timer
systemctl enable "$sla" >/dev/null 2>&1 || log "WARN: could not enable $sla"
systemctl start "$sla" >/dev/null 2>&1 || log "WARN: could not start $sla"
log "  $sla: $(systemctl is-active "$sla" 2>/dev/null || echo unknown)"

# ─── Close already-merged ClickUp profile-merge tickets, daily ─
# Caroline files profile-merge tickets but NEVER merges; Operations executes
# the tier-2 merge later, and the ticket only closes when someone runs
# close-merged-tickets.sh by hand. With no schedule, executed merges left
# their tickets open and the action-request board grew a stale merge backlog
# (Jan, 2026-06-15). This timer runs the sweep daily so tickets whose merge
# is already in action_log auto-close. Safe to automate: --apply keeps the
# default customer-reply audit ON, so it only closes tickets where the
# customer got an admin reply AFTER the merge; everything else is left open
# under needs_human_reply for the notify-merged-customers.py workflow.
# Tokens (CLICKUP_API_KEY, MUSOAI_INTERCOM_TOKEN) come from the same env files
# the SLA-digest unit uses. MUSO_BIN is pinned because the sweep queries the
# action_log over Trino via the muso CLI (the other scheduled Trino job uses
# trino-query.sh, not muso). 07:00 UTC is before the 08:30 stale-ticket and
# America/New_York SLA digests, so those reflect the freshly-closed state.
cat > /etc/systemd/system/close-merged-tickets.service << CLOSEMERGEDSVC
[Unit]
Description=Close ClickUp profile-merge tickets whose merge already executed
After=network-online.target

[Service]
Type=oneshot
Environment=MUSO_BIN=/usr/local/bin/muso
# muso-cli unification (PR #547): route the ClickUp leg (status PUT + comment
# POST) through the gated muso clickup provider. WRITE path — gained --requester
# attribution + a fail-closed audit. Revert by dropping this line + re-running.
Environment=USE_MUSO_CLI=1
EnvironmentFile=-/etc/openclaw/shared.env
EnvironmentFile=-/etc/openclaw/edge.env
ExecStart=$HYDRA_ROOT/scripts/dedup/sweeps/close-merged-tickets.sh --apply
CLOSEMERGEDSVC

cat > /etc/systemd/system/close-merged-tickets.timer << CLOSEMERGEDTMR
[Unit]
Description=Daily sweep — close ClickUp tickets whose profile-merge already executed

[Timer]
OnCalendar=*-*-* 07:00:00 UTC
# If node-8 was down at 07:00, fire on next boot rather than skip the day.
Persistent=true
RandomizedDelaySec=30s
Unit=close-merged-tickets.service

[Install]
WantedBy=timers.target
CLOSEMERGEDTMR

systemctl daemon-reload
cm=close-merged-tickets.timer
systemctl enable "$cm" >/dev/null 2>&1 || log "WARN: could not enable $cm"
systemctl start "$cm" >/dev/null 2>&1 || log "WARN: could not start $cm"
log "  $cm: $(systemctl is-active "$cm" 2>/dev/null || echo unknown)"

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
  # EDGE ONLY: after every start, fire the (non-blocking) on-start reindex so a
  # restart-paused memory_search index is rebuilt within seconds instead of
  # waiting up to 10 min for the cron watchdog (root cause: every edge restart
  # pauses the index; see openclaw-edge-reindex-on-start.sh header). Fired here,
  # not via Wants=, because ExecStartPost runs on EVERY start including
  # Restart=always crash/OOM auto-restarts, whereas a Wants= companion is not
  # re-pulled on an internal auto-restart. --no-block keeps the gateway's path
  # to `active` instant (deploy.sh restart_gateway polls is-active for 30s and
  # must not be delayed by a 30-300s re-embed); leading `-` makes a
  # missing/failed trigger non-fatal to gateway start. main has no memory_search
  # consumer, so it gets no hook.
  reindex_hook=""
  if [ "$profile" = "edge" ]; then
    reindex_hook="ExecStartPost=-/usr/bin/systemctl start --no-block openclaw-edge-reindex.service"
  fi
  cat > "$drop_dir/override.conf" << GATEWAYDROP
# MANAGED BY scripts/install-aux-units.sh — DO NOT EDIT BY HAND.
# Reference template: scripts/aux-units/openclaw-gateway.override.conf
[Service]
ExecStartPre=$HYDRA_ROOT/scripts/openclaw-pre-start-heal.sh ${profile}
${reindex_hook}
[Unit]
StartLimitBurst=5
StartLimitIntervalSec=120
GATEWAYDROP
  log "  installed drop-in for openclaw-gateway-${profile}.service"
done

# ─── On-start reindex oneshot (edge/support only) ─────────────
# Triggered by the edge gateway drop-in's ExecStartPost (above) on every edge
# start. Type=oneshot; NOT enabled/[Install]ed — it is started imperatively by
# the gateway, never on its own. After= (not Requires=/BindsTo=) so it is a
# best-effort healer: if the gateway is down the readiness poll times out and it
# exits harmlessly. TimeoutStartSec (900s) budgets the worst case: readiness
# poll (~75s: 60s deadline + one 15s timeout-bounded probe) + up to three
# time-boxed `memory status` captures (<=60s each) + a force-reindex and one
# race retry (<=300s each). StartLimit bounds a crash-restart storm from
# re-embedding unboundedly. Picked up by the `systemctl daemon-reload` later in
# this script (before Step 6's edge restart in the same deploy).
cat > /etc/systemd/system/openclaw-edge-reindex.service << REINDEXUNIT
[Unit]
Description=Reindex Caroline RAG vector index after every edge gateway start
After=openclaw-gateway-edge.service
StartLimitBurst=6
StartLimitIntervalSec=600

[Service]
Type=oneshot
TimeoutStartSec=900
ExecStart=$HYDRA_ROOT/scripts/openclaw-edge-reindex-on-start.sh
REINDEXUNIT
log "  installed openclaw-edge-reindex.service (edge on-start reindex)"

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

# ─── Codex OAuth keepalive at 15-min cadence ──────────────────
# PROACTIVE complement to the watchdog: openclaw-watchdog.sh pages REACTIVELY
# (journal 401 signature, after the fleet is already on the mini fallback);
# codex-keepalive.sh reads the token's own expiry via `openclaw models status`
# and pages BEFORE the cliff (it is the safety net for the twice-weekly
# codex-token-refresh timer). 15 min is plenty — the lapse cadence is ~days, and
# the periodic check is a cheap local `models status` read (no network). Sets an
# explicit PATH (cron's default is /usr/bin:/bin) so `openclaw`/`jq`/`timeout`
# resolve even if they live in /usr/local/bin — the keepalive fails Slack-silently
# if they don't. Same ownership rule: edit here + re-run install-aux-units.sh.
cat > /etc/cron.d/codex-keepalive << CODEXKEEPALIVE
# MANAGED BY scripts/install-aux-units.sh — DO NOT EDIT BY HAND.
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
*/15 * * * * root $HYDRA_ROOT/scripts/codex-keepalive.sh >> /var/log/codex-keepalive.log 2>&1
CODEXKEEPALIVE
chmod 644 /etc/cron.d/codex-keepalive

# ─── Cron-failure watchdog at 5-min cadence ───────────────────
# Alerts #clio_devops the moment any openclaw cron run errors, so a
# broken job can't rot silently in cron/runs/*.jsonl (the 2026-06
# b2b-reply-scanner stacked 17 failures over ~3 days unnoticed).
# 5 min is plenty: cron failures aren't latency-sensitive the way the
# gateway-crash watchdog is, and the per-job watermark dedupe means a
# persistent failure pages once, not every tick. Same ownership rule:
# edit here + re-run install-aux-units.sh, never edit the file on node-8.
cat > /etc/cron.d/cron-health-watchdog << CRONHEALTH
# MANAGED BY scripts/install-aux-units.sh — DO NOT EDIT BY HAND.
*/5 * * * * root $HYDRA_ROOT/scripts/cron-health-watchdog.sh >> /var/log/cron-health-watchdog.log 2>&1
CRONHEALTH
chmod 644 /etc/cron.d/cron-health-watchdog

# Fallback-swallow watchdog: alerts #clio_devops when an agent turn ends in an
# empty completion surfaced as an error — the residual of openclaw's
# empty-completion-swallows-fallback flaw (PR #450) that the chain-reshape CI
# gate (validate-config-matrix.sh check #6) can't reach (non-GPT-5 primary that
# empties, the last model emptying, or a chain that slips the gate). 5 min: not
# latency-sensitive, and the per-runId watermark dedupe means each swallow pages
# once. Same ownership rule: edit here + re-run install-aux-units.sh.
cat > /etc/cron.d/fallback-swallow-watchdog << SWALLOWWD
# MANAGED BY scripts/install-aux-units.sh — DO NOT EDIT BY HAND.
*/5 * * * * root $HYDRA_ROOT/scripts/fallback-swallow-watchdog.sh >> /var/log/fallback-swallow-watchdog.log 2>&1
SWALLOWWD
chmod 644 /etc/cron.d/fallback-swallow-watchdog

# ─── Merge-landing watchdog at 30-min cadence ─────────────────
# Alerts #clio_devops when an admin profile-merge returned HTTP 200 (logged to
# recent-merges.jsonl) but never LANDED in the catalog — the loser is still an
# active, unmerged profile hours later. Root cause: mergeProfiles.js only
# enqueues an async ingestion job, and industry-data-processing common/process.py
# deletes the SQS message on ANY worker exception (no DLQ, no retry), so a merge
# whose apply throws vanishes silently. This bit the 2026-06-08/09 Jan ↔ Ops
# threads (two pairs 200'd 4× over days, never merged). 30 min (not 5): the async
# fold legitimately takes minutes–hours and the script's MIN_AGE_HOURS already
# filters the in-flight window, so a tighter cadence adds Trino load without
# catching anything sooner. Per survivor:loser dedupe → a stuck merge pages once.
# Same ownership rule: edit here + re-run install-aux-units.sh.
cat > /etc/cron.d/merge-landing-watchdog << MERGELANDINGWD
# MANAGED BY scripts/install-aux-units.sh — DO NOT EDIT BY HAND.
*/30 * * * * root $HYDRA_ROOT/scripts/merge-landing-watchdog.sh >> /var/log/merge-landing-watchdog.log 2>&1
MERGELANDINGWD
chmod 644 /etc/cron.d/merge-landing-watchdog

# ─── Prod-log alert watchdog at 5-min cadence ─────────────────
# Posts NEW prod error-log lines (kubectl, read-only, redacted) to
# #prod-alerts (C0BA8QMV3ME) so engineers see prod errors without asking the
# devops agent (Serhii's ask, 2026-06-09). 5 min with a 6-min log window:
# the overlap means no gap between ticks, and the per-fingerprint cooldown
# (6h) means a persistent error pages once, not every tick. Same ownership
# rule: edit here + re-run install-aux-units.sh, never edit on node-8.
cat > /etc/cron.d/prod-log-alert-watchdog << PRODLOGWD
# MANAGED BY scripts/install-aux-units.sh — DO NOT EDIT BY HAND.
*/5 * * * * root $HYDRA_ROOT/scripts/prod-log-alert-watchdog.sh >> /var/log/prod-log-alert-watchdog.log 2>&1
PRODLOGWD
chmod 644 /etc/cron.d/prod-log-alert-watchdog

# ─── Stale-ticket watchdog, daily ─────────────────────────────
# Posts a digest of overdue hydra-action-request ClickUp tickets to
# #cs_chats (C0ANM0PN9L5). Daily at 08:30 UTC — overdue tickets aren't
# latency-sensitive and the digest is stateless (it re-lists whatever is
# overdue NOW), so a workday-morning daily nag is the right cadence.
# Same ownership rule: edit here + re-run install-aux-units.sh.
cat > /etc/cron.d/stale-ticket-watchdog << STALETICKETWD
# MANAGED BY scripts/install-aux-units.sh — DO NOT EDIT BY HAND.
# muso-cli unification (PR #547): route the read-only watchdog through the gated
# muso clickup provider. Env is inline (cron's PATH is minimal, so MUSO_BIN must
# be absolute). Read-only. Revert by dropping the two VAR=val + re-running install.
30 8 * * * root USE_MUSO_CLI=1 MUSO_BIN=/usr/local/bin/muso $HYDRA_ROOT/scripts/stale-ticket-watchdog.sh >> /var/log/stale-ticket-watchdog.log 2>&1
STALETICKETWD
chmod 644 /etc/cron.d/stale-ticket-watchdog

# ─── Caroline RAG index watchdog at 10-min cadence ────────────
# Self-heals + alerts when Caroline's memory_search (RAG) vector index is
# paused / its identity is missing / the vector store is not ready. openclaw
# pauses the index on every runtime version bump (memory-index-pause-after-
# upgrade), and a paused index returns NOTHING from retrieval, so the mandatory
# pre-retrieval RAG hook (plugins/intercom) answers ungrounded -- a silent,
# customer-facing failure. deploy.sh force-rebuilds the index on every deploy;
# this watchdog catches the BETWEEN-deploy pauses (out-of-band openclaw auto-
# update, manual gateway restart). 10 min bounds that silent window while the
# steady-state cost is one cheap status read per tick (the expensive reindex
# fires only when actually broken). The 6h cooldown means a persistent failure
# pages once per window, not every tick. Same ownership rule: edit here +
# re-run install-aux-units.sh, never edit the file on node-8.
cat > /etc/cron.d/caroline-rag-index-watchdog << CAROLINERAGWD
# MANAGED BY scripts/install-aux-units.sh -- DO NOT EDIT BY HAND.
# PATH so cron finds jq/flock/mktemp/timeout (cron's default is a bare
# /usr/bin:/bin; muso lives in /usr/local/bin). See muso-cli-contract-gotchas.
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
*/10 * * * * root $HYDRA_ROOT/scripts/caroline-rag-index-watchdog.sh >> /var/log/caroline-rag-index-watchdog.log 2>&1
CAROLINERAGWD
chmod 644 /etc/cron.d/caroline-rag-index-watchdog

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

# ─── Weekly server cleanup (Mon 04:30 UTC) ────────────────────
# Reclaims the junk systemd-tmpfiles misses: /tmp depth-1 entries
# whose MTIME (not atime/ctime — scanners refresh those, which is
# how 19GB of dead PR-review clones survived the daily
# `D /tmp ... 30d` tmpfiles rule) is >14d; hot-patch *.bak*/*.orig
# >30d under /opt/hydra + /root/hydra-hotpatch-backups; apt
# autoremove/autoclean. Posts a Block Kit summary to #clio_devops
# on every run. Exit 1 = structural refusal (surfaces as a failed
# unit); per-file delete errors stay exit 0 and report via Slack.
cat > /etc/systemd/system/hydra-weekly-cleanup.service << CLEANUPSVC
[Unit]
Description=HYDRA weekly server cleanup (/tmp mtime>14d, .bak/.orig>30d, apt)

[Service]
Type=oneshot
ExecStart=$HYDRA_ROOT/scripts/weekly-cleanup.sh
Environment=HOME=/root
Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
# Disk-bound housekeeping: keep it polite to the gateways.
Nice=10
IOSchedulingClass=idle
StandardOutput=append:/var/log/hydra-weekly-cleanup.log
StandardError=append:/var/log/hydra-weekly-cleanup.log
CLEANUPSVC

cat > /etc/systemd/system/hydra-weekly-cleanup.timer << CLEANUPTMR
[Unit]
Description=Run the HYDRA weekly cleanup Monday 04:30 UTC

[Timer]
OnCalendar=Mon *-*-* 04:30:00 UTC
# If the box was down Monday morning, fire on next boot rather than
# skip a week (same tradeoff as hydra-release.timer).
Persistent=true
# Spread away from anything else pinned to the same minute.
RandomizedDelaySec=20min
Unit=hydra-weekly-cleanup.service

[Install]
WantedBy=timers.target
CLEANUPTMR

systemctl daemon-reload

ctmr=hydra-weekly-cleanup.timer
systemctl enable "$ctmr" >/dev/null 2>&1 || log "WARN: could not enable $ctmr"
systemctl start "$ctmr" >/dev/null 2>&1 || log "WARN: could not start $ctmr"
cstate=$(systemctl is-active "$ctmr" 2>/dev/null || echo unknown)
log "  $ctmr: $cstate (fires Mon 04:30 UTC)"

# ─── Twice-weekly codex OAuth token refresh (Sun+Wed 04:00 UTC) ──
# The DURABLE fix for the recurring ~10-day codex token lapse. hydra keeps the
# bundled `openai` plugin DISABLED to dodge #90925, but that plugin owns the
# refresh-on-use machinery — so nothing auto-refreshes codex and it lapses every
# ~10 days (openclaw#57399, wontfix). This job refreshes the token out-of-band
# (codex-oauth-refresh.sh) and restarts the gateways to load it (they only read
# the token at startup). Token life is ~10d; TWICE weekly (Sun+Wed, ~every 3.5d)
# keeps the steady-state trough at ~6.5d and survives a single missed run (a
# weekly cadence would let one missed Sunday lapse the token by Wednesday).
# codex-keepalive.sh (every 15m) is the safety net if refreshes keep failing.
# Same ownership rule: edit here + re-run install.
cat > /etc/systemd/system/codex-token-refresh.service << CODEXREFRESHSVC
[Unit]
Description=HYDRA codex OAuth token refresh (+ gateway reload)

[Service]
Type=oneshot
# Generous start timeout: the script blocks on `systemctl restart` of both
# gateways; gateway starts are quick, but don't let a slow one kill the oneshot.
TimeoutStartSec=300
ExecStart=$HYDRA_ROOT/scripts/codex-token-refresh.sh
Environment=HOME=/root
Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
StandardOutput=append:/var/log/codex-token-refresh.log
StandardError=append:/var/log/codex-token-refresh.log
CODEXREFRESHSVC

cat > /etc/systemd/system/codex-token-refresh.timer << CODEXREFRESHTMR
[Unit]
Description=Run the HYDRA codex OAuth token refresh twice weekly (Sun+Wed 04:00 UTC)

[Timer]
OnCalendar=Sun,Wed *-*-* 04:00:00 UTC
# If the box was down at the scheduled time, fire on next boot rather than skip
# and risk a lapse (same tradeoff as hydra-release.timer).
Persistent=true
RandomizedDelaySec=10min
Unit=codex-token-refresh.service

[Install]
WantedBy=timers.target
CODEXREFRESHTMR

systemctl daemon-reload

rtmr=codex-token-refresh.timer
systemctl enable "$rtmr" >/dev/null 2>&1 || log "WARN: could not enable $rtmr"
systemctl start "$rtmr" >/dev/null 2>&1 || log "WARN: could not start $rtmr"
rstate=$(systemctl is-active "$rtmr" 2>/dev/null || echo unknown)
log "  $rtmr: $rstate (fires Sun+Wed 04:00 UTC)"

# ─── journald cap + hydra log rotation (one-time config) ──────
# journald had NO retention config and had grown to 3.9G (audit
# 2026-06-10). Cap the persistent journal at 2G; vacuum only when
# the drop-in is first installed or changes, so idempotent re-runs
# are no-ops.
JOURNALD_DROPIN=/etc/systemd/journald.conf.d/50-hydra-cap.conf
mkdir -p /etc/systemd/journald.conf.d
desired=$'[Journal]\nSystemMaxUse=2G'
if [[ ! -f "$JOURNALD_DROPIN" ]] || [[ "$(cat "$JOURNALD_DROPIN")" != "$desired" ]]; then
  printf '%s\n' "$desired" > "$JOURNALD_DROPIN"
  systemctl restart systemd-journald >/dev/null 2>&1 || log "WARN: journald restart failed"
  journalctl --vacuum-size=2G >/dev/null 2>&1 || log "WARN: journal vacuum failed"
  log "  journald capped at SystemMaxUse=2G (drop-in installed + vacuumed)"
fi

# logrotate for the /etc/cron.d watchdog logs and the timer logs
# above — none of these rotated before (openclaw-watchdog.log et al
# grow unbounded). copytruncate: the writers are >>/append: redirects
# reopened per tick/run, no postrotate signaling exists for them.
cat > /etc/logrotate.d/hydra << 'HYDRALOGROTATE'
# MANAGED BY scripts/install-aux-units.sh — DO NOT EDIT BY HAND.
/var/log/*-watchdog.log /var/log/codex-keepalive.log /var/log/codex-token-refresh.log /var/log/hydra-daily-audit.log /var/log/hydra-weekly-cleanup.log {
    weekly
    rotate 4
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
}
HYDRALOGROTATE
chmod 644 /etc/logrotate.d/hydra
log "  logrotate config installed at /etc/logrotate.d/hydra"

log "post-2026-05-05 hardening: drop-ins, write-audit, and 2-min watchdog cron installed."
