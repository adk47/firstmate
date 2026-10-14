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
#   hydra-main-prune-restart.timer / .service
#     Nightly 02:30 UTC: scripts/main-prune-restart.sh prunes main's sessions idle >24h offline (backed up,
#     fail-open) and restarts main (MUS-1295). Retires the hand-placed /usr/local/sbin bridge.
#
#   hydra-session-thread-retention@{main,edge}.timer / .service
#     Every 6h, removes terminal Slack channel thread sessions older
#     than 14d through each gateway's native sessions.delete lifecycle API.
#     This bounds the protected session footprint without touching channel
#     roots, DMs, active work, or the disposable :cron: keys whose survival
#     is the reason this maintenance exists.
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
#   /etc/cron.d/refund-credit-overlap-watchdog
#     Schedules scripts/refund-credit-overlap-watchdog.sh daily to page
#     #clio_devops when a customer holds BOTH a cash refund and a live
#     customer-balance credit. This is the ONLY layer that sees the human
#     Stripe-dashboard path, where all 223 cases in the 2026-09-09 audit
#     came from; the money gate covers only the agent/CLI path.
#
#   /etc/cron.d/cron-health-watchdog
#     Schedules scripts/cron-health-watchdog.sh every 5 minutes to
#     alert #clio_devops on any errored cron run (the missing
#     failure-notification layer behind the 2026-06 silent
#     b2b-reply-scanner breakage).
#
#   /etc/cron.d/agent-soul-delivery-guard
#     Schedules scripts/check-agent-soul-delivery.sh --alert every 15
#     minutes: pages #clio_devops when a live agent's newest codex session
#     had no AGENT_SOUL / <available_skills> / cron-mode text in the
#     developer message the model saw (MUS-6600 recurrence guard, MUS-6635).
#
#   /etc/cron.d/fallback-swallow-watchdog
#     Schedules scripts/fallback-swallow-watchdog.sh every 5 minutes
#     to alert #clio_devops when an agent turn ends in an empty
#     completion surfaced as an error — the residual of openclaw's
#     empty-completion-swallows-fallback flaw (2026-06-08 @CMO
#     incident, PR #450) that the chain-reshape CI gate can't reach.
#
#   /etc/cron.d/stuck-lane-watchdog
#     Schedules scripts/stuck-lane-watchdog.sh every 2 minutes. TWO detectors:
#       EDGE journal — an abort that did not release the lane
#         (action=abort_embedded_run … released=0), the moment Caroline's
#         generated reply is discarded (upstream openclaw #97538). Ops backstop
#         to the in-plugin dispatch-timeout page; fires from journald even if
#         the plugin path is down.
#       LIVE lane state — polls each profile's `diagnostics.lanes` and alerts on
#         a lane with work QUEUED and NOTHING ACTIVE across several consecutive
#         ticks. Reads current gateway state, NOT the journal: the
#         `lane wait exceeded` line is emitted as a queued task STARTS, so it is
#         a recovery record and cannot prove a lane is stuck now. Detection
#         only — a restart is the only known clearer and restarts are
#         customer-visible, so that stays a human decision.
#     Both always run; a capture failure in one does not silence the other.
#
#   /etc/cron.d/prod-log-alert-watchdog
#     Schedules scripts/prod-log-alert-watchdog.sh every 5 minutes
#     to post NEW prod error-log lines (kubectl read-only, redacted,
#     fingerprint-deduped) to #prod-alerts C0BA8QMV3ME (Serhii's
#     prod-log-visibility ask, 2026-06-09). Since 2026-08-05 it runs
#     the v2 path by default: persistence gate + 15-min digest +
#     severity classifier, with only P0 paging a human. Also creates
#     /var/lib/prod-log-alert for the fingerprint + incident state.
#
#   /etc/cron.d/sentry-issue-watchdog
#     Schedules scripts/sentry-issue-watchdog.sh every 30 minutes to
#     poll Sentry for NEW unresolved issues in the code-owning
#     projects (core-backend, credits-web-next, muso-auth -- flutter
#     is deliberately never queried) and post one digest to
#     #sentry-alerts. Dispatching the cto agent to triage one of them
#     is OFF by default (SENTRY_WATCHDOG_DISPATCH=0 in the script) --
#     autonomy is opted into in exactly one place, so turning it on is
#     a one-line reviewable diff. Also creates
#     /var/lib/hydra-sentry-watchdog (its own dispatch state) and
#     /var/lib/hydra-sentry-triage (the triage skill's ledger, created
#     here so the skill's mkdir is never the first thing to touch it).
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
#   /etc/cron.d/mercury-token-watchdog
#     Schedules scripts/mercury-token-watchdog.sh daily to page
#     #clio_devops when the Finance agent's read-only Mercury Bank API
#     token is revoked. Twice in four months the token died silently
#     (Token A ~2026-05-01, Token B ~2026-06-10) and the second death went
#     unnoticed for ~8 weeks — there is no CIB cron and was no health
#     check, so a dead banking credential was invisible until Liza asked
#     for a forecast on 2026-08-03 and got a wall.
#
#   /etc/cron.d/ads-inquiry-watchdog
#     Schedules scripts/ads-inquiry-watchdog.sh every 15 min to ping
#     Aaron in #cs_priority (C0BBTAVP44X) when a support ticket is an
#     ads-buying lead (Odeholm Audio miss, 2026-07: an in-app-ads
#     sales lead was closed-as-answered and forwarded to Nick by
#     email; Aaron, who owns ads, never saw it).
#
#   /etc/systemd/system/intercom-rights-holder-watchdog.{service,timer}
#     Runs scripts/intercom-rights-holder-watchdog.py every 10 min (oneshot).
#     Pages #cs_priority (operations bot) when an inbound Intercom
#     conversation is from a rights-holder or marked urgent and has gone
#     unhandled (Sony/natori correction misfiled onto another customer's
#     ticket, MUS-6566). A systemd unit, not cron.d: the Intercom token comes
#     from EnvironmentFile (a 644 cron.d line would expose it) and the
#     service is in AUX_ONFAILURE_UNITS so a failing run pages.
#
#   /etc/tmpfiles.d/tmp.conf
#     /tmp age policy keyed on mtime only (`D /tmp 1777 root root mM:24h`),
#     installed verbatim from scripts/aux-units/tmp.conf. Codifies the
#     2026-08-26 node-8 hand-edit that ended the disk-pressure alerts: the
#     stock newest-of(atime,mtime,ctime) age test was permanently defeated by
#     a nightly read-walk refreshing atime, so 7d/30d policies reclaimed 0
#     bytes while /tmp grew to ~200 GB (H-DevOps devops-agent route #285).
#     Hard-guarded: the source must carry the mM: prefix, or install fails.
#
#   cto-nightly-driver.timer / .service
#     Every 30 min. Runs scripts/cto-nightly-driver.sh, the deterministic
#     overnight supervisor for the nightly CTO issue-fixer's currently-open
#     PR (tracked in /var/lib/hydra-cto-nightly/current.json). Pure gh/jq/
#     bash: posts a threaded "ready for merge" note when CI + review + merge
#     state all settle green, dispatches a single bounded cto FIX-PASS turn
#     when there's an actual, mechanically detected delta (unresolved
#     finding, QA no-go, redded CI, or a dead QA dispatch it recovers by
#     rerunning PR Validation), and pauses the loop after
#     CTO_NIGHTLY_MAX_FIX_TURNS rounds. Never dispatches the agent without a
#     delta.
#
#   hydra-release-watch.timer / .service
#     The LIVE release path. Every 5 min, scripts/release-watch.sh asks
#     each ENABLED repo whether a confirmed PROD release has landed that
#     was not announced yet. Detection reads an authoritative PER-SHA
#     record, never an inference:
#       - web-credits-next / auth: H-DevOps posts an `H-DevOps / deploy`
#         commit STATUS on the app repo's own commit, which names the sha
#         directly. (auth is enabled=0 until its upstream writes one.)
#       - hydra: a completed, successful deploy.yml run on main.
#     An earlier revision correlated H-DevOps' `auto: bump ... post-deploy`
#     commits instead; that was removed because a bump proves a rollout
#     happened but never names a sha. See CLAUDE.md ## Releases.
#     It pins the sha that actually shipped (main may have moved since),
#     cuts a CalVer tag + GitHub release via release.sh --at, and posts a
#     Block Kit message to #releases. The plain-language highlights come
#     from a TOOL-LESS direct HTTP model call -- never an agent turn, since
#     commit subjects are untrusted input and an agent runtime has exec --
#     and if it fails the release is still announced with the deterministic
#     conventional-commit rendering.
#     Fails CLOSED when RELEASES_SLACK_CHANNEL is unset
#     (/etc/hydra/releases.env) rather than cutting tags nobody sees.
#     State: /var/lib/hydra-release/{repos,announced,highlights}.
#
#   support-changelog-sync.timer / .service
#     Daily render of Caroline's shipped-work feed into her RAG-indexed
#     reference/ directory -- the only auto-updating path into her
#     knowledge, since she has no Slack bindings and no exec. A render
#     with NEW lines is staged under /var/lib and announced; only
#     `--promote` publishes it, so review blocks publication rather
#     than trailing it.
#
#   sync-platform-llms.timer / .service
#     Daily refresh of Caroline's platform.muso.ai API + pricing feed
#     into the same RAG-indexed reference/ directory, fetched from the
#     PUBLIC https://platform.muso.ai/llms-full.txt. No staging gate,
#     unlike the feed above: that one publishes model output over
#     author-controlled PR titles, this one copies first-party pricing
#     copy Muso already serves publicly. Fail-closed on a bad fetch, and
#     it re-runs the CI blocklist because the file it writes is
#     rsync-excluded and so invisible to pr-validate.yml.
#
#   hydra-release.timer / .service   [INSTALLED, DISABLED]
#     The SUPERSEDED daily cut, kept installed so reverting to a daily
#     cadence is one `systemctl enable --now` away. Do not run it
#     alongside the watcher — both would tag the same day.
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
#   hydra-tmp-reaper.timer / .service
#     Hourly. Runs scripts/tmp-reaper.sh: deletes the known /tmp scratch
#     patterns (review clones, qa-pr-*, pr-review-*.json, tmp.XXXXXX) after a
#     3h/24h idle TTL, only when lsof shows no open handles. Everything else
#     is left to the tmpfiles 24h catch-all. jest_0 is never touched.
#   hydra-codex-home-prune.timer / .service
#     Daily 05:45 UTC. scripts/codex-home-prune.sh --apply: ages out codex
#     rollout jsonl and logs_*.sqlite rows past CODEX_SESSION_TTL_DAYS (14).
#
#   hydra-jev-shadow-prune.timer / .service
#     Daily. Runs scripts/jev-shadow-prune.sh, which drops shadow rows
#     older than JEV_SHADOW_RETENTION_DAYS (default 30) from every
#     $JEV_SHADOW_DIR/*.jsonl -- the row's `state` field (added so a
#     misclassification can be replayed against Jev directly) is customer
#     text, so it should not accumulate unbounded on disk.
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

# Runtime-aware install gate: on openclaw >= 2026.8 the codex-token-refresh
# timer below must NOT be installed (see its own block for why). Resolve
# once, here, so both the (non-)install and the active-teardown share one
# answer. Unknown/unparseable runtime FAILS LOUD rather than guessing: a
# false "pre-2026.8" guess on an actual 2.0 box would (re)install/re-enable
# this timer alongside the native in-process refresher, reproducing the
# 2026-06-08 refresh_token_reused fleet-kill. This runs from deploy/operator
# context, where a hard failure is visible and correct — unlike a background
# guard, there is no "unevaluated" state to fall back to here.
# shellcheck source=lib/version-compare.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/version-compare.sh"
AUX_RUNTIME_VER="$(openclaw_runtime_version)"
[ -n "$AUX_RUNTIME_VER" ] \
  || fail "could not determine openclaw runtime version (\`openclaw --version\` returned nothing/unparseable) — refusing to guess whether codex-token-refresh.timer belongs on this host (2026-06-08 refresh_token_reused class)"
AUX_RUNTIME_IS_2026_8_PLUS=0
if version_at_least "2026.8" "$AUX_RUNTIME_VER"; then
  AUX_RUNTIME_IS_2026_8_PLUS=1
fi

[[ $EUID -eq 0 ]] || fail "must run as root (systemd unit writes require it)"
[[ -x "$HYDRA_ROOT/scripts/provision-peer-labels.sh" ]] \
  || fail "$HYDRA_ROOT/scripts/provision-peer-labels.sh missing or not executable"
[[ -x "$HYDRA_ROOT/scripts/openclaw-pre-start-heal.sh" ]] \
  || fail "$HYDRA_ROOT/scripts/openclaw-pre-start-heal.sh missing or not executable"
[[ -x "$HYDRA_ROOT/scripts/openclaw-config-write-audit.sh" ]] \
  || fail "$HYDRA_ROOT/scripts/openclaw-config-write-audit.sh missing or not executable"
[[ -x "$HYDRA_ROOT/scripts/openclaw-watchdog.sh" ]] \
  || fail "$HYDRA_ROOT/scripts/openclaw-watchdog.sh missing or not executable"
[[ -x "$HYDRA_ROOT/scripts/dr-ai-healer.sh" ]] \
  || fail "$HYDRA_ROOT/scripts/dr-ai-healer.sh missing or not executable (watchdog DR escalation would silently no-op)"
# DR state dir (strike files, healer lock/cooldown/log): root-owned 0700 so
# the predictable paths inside can't be pre-created as symlinks by a local
# user (the healer + watchdog also verify this before every write).
install -d -m 700 /var/lib/hydra-dr
[[ -x "$HYDRA_ROOT/scripts/codex-keepalive.sh" ]] \
  || fail "$HYDRA_ROOT/scripts/codex-keepalive.sh missing or not executable"
[[ -x "$HYDRA_ROOT/scripts/codex-token-refresh.sh" ]] \
  || fail "$HYDRA_ROOT/scripts/codex-token-refresh.sh missing or not executable"
[[ -x "$HYDRA_ROOT/scripts/company-finder/refresh-dedupe-cache.sh" ]] \
  || fail "$HYDRA_ROOT/scripts/company-finder/refresh-dedupe-cache.sh missing or not executable"
[[ -x "$HYDRA_ROOT/scripts/lib/codex-oauth-refresh.sh" ]] \
  || fail "$HYDRA_ROOT/scripts/lib/codex-oauth-refresh.sh missing or not executable"
[[ -x "$HYDRA_ROOT/scripts/cron-health-watchdog.sh" ]] \
  || fail "$HYDRA_ROOT/scripts/cron-health-watchdog.sh missing or not executable"
[[ -x "$HYDRA_ROOT/scripts/check-agent-soul-delivery.sh" ]] \
  || fail "$HYDRA_ROOT/scripts/check-agent-soul-delivery.sh missing or not executable"
[[ -x "$HYDRA_ROOT/scripts/fallback-swallow-watchdog.sh" ]] \
  || fail "$HYDRA_ROOT/scripts/fallback-swallow-watchdog.sh missing or not executable"
[[ -x "$HYDRA_ROOT/scripts/merge-landing-watchdog.sh" ]] \
  || fail "$HYDRA_ROOT/scripts/merge-landing-watchdog.sh missing or not executable"
[[ -x "$HYDRA_ROOT/scripts/prod-log-alert-watchdog.sh" ]] \
  || fail "$HYDRA_ROOT/scripts/prod-log-alert-watchdog.sh missing or not executable"
[[ -x "$HYDRA_ROOT/scripts/sentry-issue-watchdog.sh" ]] \
  || fail "$HYDRA_ROOT/scripts/sentry-issue-watchdog.sh missing or not executable"
[[ -x "$HYDRA_ROOT/scripts/clickup-sla-digest.sh" ]] \
  || fail "$HYDRA_ROOT/scripts/clickup-sla-digest.sh missing or not executable"
[[ -x "$HYDRA_ROOT/scripts/stale-ticket-watchdog.sh" ]] \
  || fail "$HYDRA_ROOT/scripts/stale-ticket-watchdog.sh missing or not executable"
[[ -x "$HYDRA_ROOT/scripts/ads-inquiry-watchdog.sh" ]] \
  || fail "$HYDRA_ROOT/scripts/ads-inquiry-watchdog.sh missing or not executable"
[[ -x "$HYDRA_ROOT/scripts/intercom-rights-holder-watchdog.py" ]] \
  || fail "$HYDRA_ROOT/scripts/intercom-rights-holder-watchdog.py missing or not executable"
[[ -x "$HYDRA_ROOT/scripts/mercury-token-watchdog.sh" ]] \
  || fail "$HYDRA_ROOT/scripts/mercury-token-watchdog.sh missing or not executable"
[[ -x "$HYDRA_ROOT/scripts/lib/ensure-mercury-token.sh" ]] \
  || fail "$HYDRA_ROOT/scripts/lib/ensure-mercury-token.sh missing or not executable"
[[ -x "$HYDRA_ROOT/scripts/caroline-rag-index-watchdog.sh" ]] \
  || fail "$HYDRA_ROOT/scripts/caroline-rag-index-watchdog.sh missing or not executable"
[[ -x "$HYDRA_ROOT/scripts/openclaw-edge-reindex-on-start.sh" ]] \
  || fail "$HYDRA_ROOT/scripts/openclaw-edge-reindex-on-start.sh missing or not executable"
[[ -x "$HYDRA_ROOT/scripts/stuck-lane-watchdog.sh" ]] \
  || fail "$HYDRA_ROOT/scripts/stuck-lane-watchdog.sh missing or not executable"
[[ -x "$HYDRA_ROOT/scripts/qa-review-reconcile.sh" ]] \
  || fail "$HYDRA_ROOT/scripts/qa-review-reconcile.sh missing or not executable"
[[ -x "$HYDRA_ROOT/scripts/qa-approval-retry.sh" ]] \
  || fail "$HYDRA_ROOT/scripts/qa-approval-retry.sh missing or not executable"
[[ -f "$HYDRA_ROOT/scripts/overdue-verification-notifier.py" ]] \
  || fail "$HYDRA_ROOT/scripts/overdue-verification-notifier.py missing"
[[ -f "$HYDRA_ROOT/scripts/resolve-notify.py" ]] \
  || fail "$HYDRA_ROOT/scripts/resolve-notify.py missing"
[[ -f "$HYDRA_ROOT/scripts/resolution-matcher.py" ]] \
  || fail "$HYDRA_ROOT/scripts/resolution-matcher.py missing"
[[ -f "$HYDRA_ROOT/scripts/caroline-behavior-digest.py" ]] \
  || fail "$HYDRA_ROOT/scripts/caroline-behavior-digest.py missing"
[[ -f "$HYDRA_ROOT/scripts/support-changelog-sync.sh" ]] \
  || fail "$HYDRA_ROOT/scripts/support-changelog-sync.sh missing"
[[ -f "$HYDRA_ROOT/scripts/sync-platform-llms.sh" ]] \
  || fail "$HYDRA_ROOT/scripts/sync-platform-llms.sh missing"
[[ -f "$HYDRA_ROOT/scripts/sync-app-pricing.sh" ]] \
  || fail "$HYDRA_ROOT/scripts/sync-app-pricing.sh missing"
[[ -f "$HYDRA_ROOT/scripts/cs-needs-human-digest.py" ]] \
  || fail "$HYDRA_ROOT/scripts/cs-needs-human-digest.py missing"
[[ -f "$HYDRA_ROOT/scripts/cs-sla-report.py" ]] \
  || fail "$HYDRA_ROOT/scripts/cs-sla-report.py missing"
[[ -f "$HYDRA_ROOT/scripts/close-duplicate-conversations.py" ]] \
  || fail "$HYDRA_ROOT/scripts/close-duplicate-conversations.py missing"
[[ -f "$HYDRA_ROOT/scripts/clickup-todo-dedupe.py" ]] \
  || fail "$HYDRA_ROOT/scripts/clickup-todo-dedupe.py missing"
[[ -f "$HYDRA_ROOT/scripts/lib/intercom_link.py" ]] \
  || fail "$HYDRA_ROOT/scripts/lib/intercom_link.py missing (clickup-todo-dedupe imports it)"
[[ -f "$HYDRA_ROOT/scripts/cs-selfserve-backlog.py" ]] \
  || fail "$HYDRA_ROOT/scripts/cs-selfserve-backlog.py missing"
[[ -f "$HYDRA_ROOT/scripts/cs-ops-drain-candidates.py" ]] \
  || fail "$HYDRA_ROOT/scripts/cs-ops-drain-candidates.py missing"
[[ -x "$HYDRA_ROOT/scripts/release-cron.sh" ]] \
  || fail "$HYDRA_ROOT/scripts/release-cron.sh missing or not executable"
[[ -x "$HYDRA_ROOT/scripts/clean-my-linux.sh" ]] \
  || fail "$HYDRA_ROOT/scripts/clean-my-linux.sh missing or not executable"
[[ -x "$HYDRA_ROOT/scripts/dedup/sweeps/close-merged-tickets.sh" ]] \
  || fail "$HYDRA_ROOT/scripts/dedup/sweeps/close-merged-tickets.sh missing or not executable"
[[ -x "$HYDRA_ROOT/scripts/cto-nightly-driver.sh" ]] \
  || fail "$HYDRA_ROOT/scripts/cto-nightly-driver.sh missing or not executable"

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

# ─── Protected Slack-thread retention ────────────────────────
[[ -x "$HYDRA_ROOT/scripts/prune-completed-slack-thread-sessions.sh" ]] \
  || fail "$HYDRA_ROOT/scripts/prune-completed-slack-thread-sessions.sh missing or not executable"

cat > /etc/systemd/system/hydra-session-thread-retention@.service << RETENTIONSVC
[Unit]
Description=Bound completed protected Slack-thread sessions through the %i gateway API
After=network-online.target openclaw-gateway-%i.service
Wants=network-online.target

[Service]
Type=oneshot
Environment=SESSION_THREAD_RETENTION_DAYS=14
Environment=SESSION_THREAD_MAX_DELETES=100
ExecStart=$HYDRA_ROOT/scripts/prune-completed-slack-thread-sessions.sh --profile %i --apply
# At most 100 gateway calls x 30s, plus listing and summary overhead.
TimeoutStartSec=60min
RETENTIONSVC

cat > /etc/systemd/system/hydra-session-thread-retention@.timer << RETENTIONTMR
[Unit]
Description=Prune completed protected Slack-thread sessions for %i every 6 hours

[Timer]
OnBootSec=20min
OnUnitActiveSec=6h
RandomizedDelaySec=15min
Persistent=true
Unit=hydra-session-thread-retention@%i.service

[Install]
WantedBy=timers.target
RETENTIONTMR

systemctl daemon-reload
for profile in main edge; do
  retention_tmr="hydra-session-thread-retention@${profile}.timer"
  systemctl enable "$retention_tmr" >/dev/null 2>&1 || fail "could not enable $retention_tmr"
  systemctl start "$retention_tmr" >/dev/null 2>&1 || fail "could not start $retention_tmr"
  retention_state="$(systemctl is-active "$retention_tmr" 2>/dev/null || true)"
  [[ "$retention_state" == "active" ]] || fail "$retention_tmr is not active (state: ${retention_state:-unknown})"
  log "  $retention_tmr: $retention_state"
done

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

# ─── Intercom rights-holder / urgent inbound watchdog (MUS-6566) ───────────
# Live tick = no flag (--dry-run is the only mode switch). Token:
# MUSOAI_INTERCOM_TOKEN from the env files; the Slack token is resolved inside
# the script. No secret is written into the unit. See
# scripts/intercom-rights-holder-watchdog.py.
cat > /etc/systemd/system/intercom-rights-holder-watchdog.service << RIGHTSHOLDERWDSVC
[Unit]
Description=Intercom rights-holder / urgent inbound watchdog (alerts #cs_priority)
After=network-online.target

[Service]
Type=oneshot
EnvironmentFile=-/etc/openclaw/shared.env
EnvironmentFile=-/etc/openclaw/edge.env
ExecStart=/usr/bin/python3 $HYDRA_ROOT/scripts/intercom-rights-holder-watchdog.py
RIGHTSHOLDERWDSVC

cat > /etc/systemd/system/intercom-rights-holder-watchdog.timer << RIGHTSHOLDERWDTMR
[Unit]
Description=Run the Intercom rights-holder / urgent watchdog every 10 min

[Timer]
OnBootSec=10min
OnUnitActiveSec=10min
Unit=intercom-rights-holder-watchdog.service

[Install]
WantedBy=timers.target
RIGHTSHOLDERWDTMR

systemctl daemon-reload
wd=intercom-rights-holder-watchdog.timer
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

# ─── Enable sysstat for system diagnostics ────────────────────────────────
# On 2026-09-28 the main gateway froze for 18 minutes with zero per-second
# CPU or swap records because /etc/default/sysstat had ENABLED="false".
# This section idempotently enables sysstat and sets retention to 28 days
# (covering a full week-on-week comparison for incident diagnosis).
# On Ubuntu/Debian: ENABLED lives in /etc/default/sysstat, HISTORY in /etc/sysstat/sysstat
ETC_DEFAULT_SYSSTAT="/etc/default/sysstat"
ETC_SYSSTAT_SYSSTAT="/etc/sysstat/sysstat"

if [[ -f "$ETC_DEFAULT_SYSSTAT" ]] && grep -q '^ENABLED="false"' "$ETC_DEFAULT_SYSSTAT"; then
  sed -i.bak 's/^ENABLED="false"/ENABLED="true"/' "$ETC_DEFAULT_SYSSTAT"
  rm -f "$ETC_DEFAULT_SYSSTAT.bak"
fi

if [[ -f "$ETC_SYSSTAT_SYSSTAT" ]]; then
  if ! grep -q '^HISTORY=28$' "$ETC_SYSSTAT_SYSSTAT"; then
    if grep -q '^HISTORY=' "$ETC_SYSSTAT_SYSSTAT"; then
      sed -i.bak 's/^HISTORY=.*/HISTORY=28/' "$ETC_SYSSTAT_SYSSTAT"
      rm -f "$ETC_SYSSTAT_SYSSTAT.bak"
    else
      echo "HISTORY=28" >> "$ETC_SYSSTAT_SYSSTAT"
    fi
    log "  sysstat: set retention to 28 days"
  fi
fi

systemctl enable --now sysstat >/dev/null 2>&1 && log "  sysstat: enabled" || log "WARN: could not enable sysstat"

# ─── Close customer-complete conversations (steady-state sync) ──
# Silently closes Intercom conversations whose linked ClickUp tickets are all
# customer-complete AND where we replied last — keeps "request done" and "chat
# closed" in sync so the open-conversation pile stops regrowing on that axis.
# Conservative + reversible: never closes a chat that has an open ticket, a
# customer waiting on us, or one that was never answered; every close is
# shadow-logged to /var/log/close-resolved-shadow.jsonl. No customer-facing
# message. --notify posts a per-run summary (counts + clickable ClickUp +
# Intercom links) to #cs_chats as the operations bot, but ONLY on runs that
# closed >=1 (no daily noise). See scripts/close-resolved-conversations.py.
cat > /etc/systemd/system/close-resolved-conversations.service << CLOSERESVC
[Unit]
Description=Close Intercom conversations whose ClickUp ticket is customer-complete
# Starting the closer also runs resolve-notify first. This guarantees a newly-
# resolved bulk is persisted before the closer reads its held-ticket snapshot.
Requires=resolve-notify.service
After=network-online.target resolve-notify.service

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
# ticket becomes customer-complete (resolved + customer-outcome:complete) — today
# close-resolved-conversations.py closes the chat
# SILENTLY, so a finished request just goes quiet. The notify makes us
# "we spoke last", which is exactly close-resolved's gate, so the close batch
# (above) then closes the conversation. Same safety-first design as the overdue
# notifier: cold-start seeds silently (no backlog blast), per-conversation
# dedupe, fresh pre-send conversation re-check (email cross-match + human-reply/
# closed/handoff suppression; a customer who spoke last is NOT suppressed here),
# per-run cap, and an integrity-checked bulk guard. SENDING IS LIVE (`--apply`
# on ExecStart below). It seeds silently on its first run -- sending 0 --
# whether that first run is the last inert fire or the first --apply fire (the
# cold-start seed write is not --apply-gated); every later run is bounded by the
# held bulk snapshot (<=MAX per drain) + per-message email/dedupe/suppression
# gates, and surfaced by caroline-behavior-digest.py. See
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
# Runs with the same state-path environment as ExecStart. It never calls an API;
# after the one legacy upgrade it only verifies v2 state and exits cleanly.
ExecStartPre=/usr/bin/python3 $HYDRA_ROOT/scripts/resolve-notify.py --migrate-legacy-state
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

# ─── CS needs-human ranked digest (daily 13:30 UTC) ───────────
# Phase 0.3 of docs/plans/autonomous-cs-machine.md: a READ-ONLY daily digest
# for Jan of open Intercom conversations NOT already owned by any of the
# sweepers above (close-resolved-conversations / resolve-notify /
# resolution-matcher / overdue-verification-notifier), bucketed into
# needs-human / needs-customer-input / dup-candidate and ranked
# oldest-waiting-first, posted once to #cs_chats. It NEVER closes, snoozes,
# tags, or replies to a conversation — its only side effect is that one
# Slack post (`--post`; a bare run without it is a dry-run that prints to
# stdout and posts nothing). Runs at 13:30 UTC, after resolution-matcher's
# 12:00 UTC run has had a chance to claim its conversations first, so the
# de-confliction read sees resolution-matcher's same-day state. See
# scripts/cs-needs-human-digest.py.
cat > /etc/systemd/system/cs-needs-human-digest.service << CSDIGESTSVC
[Unit]
Description=CS needs-human ranked digest (#cs_chats; read-only on Intercom)
After=network-online.target

[Service]
Type=oneshot
EnvironmentFile=-/etc/openclaw/shared.env
EnvironmentFile=-/etc/openclaw/edge.env
Environment=CS_DIGEST_AGING_HOURS=20
# Jan Roland Delmo (Head of Operations) — docs/lessons/muso-domain.md:431.
Environment=CS_DIGEST_AGING_MENTION_UID=U038BM16T7W
ExecStart=/usr/bin/python3 $HYDRA_ROOT/scripts/cs-needs-human-digest.py --post
CSDIGESTSVC

cat > /etc/systemd/system/cs-needs-human-digest.timer << CSDIGESTTMR
[Unit]
Description=Daily — CS needs-human ranked digest at 13:30 UTC

[Timer]
OnCalendar=*-*-* 13:30:00 UTC
Persistent=true
RandomizedDelaySec=120
Unit=cs-needs-human-digest.service

[Install]
WantedBy=timers.target
CSDIGESTTMR

systemctl daemon-reload
cnhd=cs-needs-human-digest.timer
systemctl enable "$cnhd" >/dev/null 2>&1 || log "WARN: could not enable $cnhd"
systemctl start "$cnhd" >/dev/null 2>&1 || log "WARN: could not start $cnhd"
log "  $cnhd: $(systemctl is-active "$cnhd" 2>/dev/null || echo unknown)"

# ─── CS self-serve backlog ranker (daily 02:30 UTC collect, monthly 09:00 UTC post) ───
# Phase 3 of docs/plans/autonomous-cs-machine.md: a READ-ONLY monthly report
# ranking which MISSING customer self-serve feature would remove the most
# human-touch support tickets, swept from the edge session trajectory JSONL
# (reaper keeps only ~5 days on disk, so a DAILY collect accumulates history
# into a durable rollup at /var/lib/cs-selfserve-backlog/monthly.json; a
# MONTHLY post renders the previous UTC month and posts once to #cs_chats).
# It never writes to Intercom/ClickUp/muso - its only side effects are its
# own rollup state and that one Slack post. See scripts/cs-selfserve-backlog.py.
install -d -m 755 /var/lib/cs-selfserve-backlog
cat > /etc/systemd/system/cs-selfserve-backlog-collect.service << CSBACKLOGCOLLECTSVC
[Unit]
Description=CS self-serve backlog - daily trajectory sweep into the durable rollup
After=network-online.target

[Service]
Type=oneshot
EnvironmentFile=-/etc/openclaw/shared.env
EnvironmentFile=-/etc/openclaw/edge.env
ExecStart=/usr/bin/python3 $HYDRA_ROOT/scripts/cs-selfserve-backlog.py --collect
CSBACKLOGCOLLECTSVC

cat > /etc/systemd/system/cs-selfserve-backlog-collect.timer << CSBACKLOGCOLLECTTMR
[Unit]
Description=Daily - CS self-serve backlog trajectory sweep at 02:30 UTC

[Timer]
OnCalendar=*-*-* 02:30:00 UTC
Persistent=true
RandomizedDelaySec=120
Unit=cs-selfserve-backlog-collect.service

[Install]
WantedBy=timers.target
CSBACKLOGCOLLECTTMR

cat > /etc/systemd/system/cs-selfserve-backlog.service << CSBACKLOGPOSTSVC
[Unit]
Description=CS self-serve backlog - monthly ranked report to #cs_chats
After=network-online.target

[Service]
Type=oneshot
EnvironmentFile=-/etc/openclaw/shared.env
EnvironmentFile=-/etc/openclaw/edge.env
ExecStart=/usr/bin/python3 $HYDRA_ROOT/scripts/cs-selfserve-backlog.py --post
CSBACKLOGPOSTSVC

cat > /etc/systemd/system/cs-selfserve-backlog.timer << CSBACKLOGPOSTTMR
[Unit]
Description=Monthly - CS self-serve backlog ranked report, 1st at 09:00 UTC

[Timer]
OnCalendar=*-*-01 09:00:00 UTC
Persistent=true
RandomizedDelaySec=120
Unit=cs-selfserve-backlog.service

[Install]
WantedBy=timers.target
CSBACKLOGPOSTTMR

systemctl daemon-reload
for csbt in cs-selfserve-backlog-collect.timer cs-selfserve-backlog.timer; do
  systemctl enable "$csbt" >/dev/null 2>&1 || log "WARN: could not enable $csbt"
  systemctl start "$csbt" >/dev/null 2>&1 || log "WARN: could not start $csbt"
  log "  $csbt: $(systemctl is-active "$csbt" 2>/dev/null || echo unknown)"
done

# ─── CS needs-human digest — delta runs (07:30 + 19:30 UTC) ───────────
# WS2 (docs/plans autonomous-cs-machine follow-on): the same digest script,
# invoked with --delta so only needs-human items never surfaced before, or
# items newly crossing the CS_DIGEST_AGING_HOURS threshold, get posted — the
# 13:30 UTC run above stays the full daily view. See scripts/
# cs-needs-human-digest.py's --delta flag and CS_DIGEST_STATE.
cat > /etc/systemd/system/cs-needs-human-digest-delta.service << CSDIGESTDELTASVC
[Unit]
Description=CS needs-human digest — delta run (#cs_chats; read-only on Intercom)
After=network-online.target

[Service]
Type=oneshot
EnvironmentFile=-/etc/openclaw/shared.env
EnvironmentFile=-/etc/openclaw/edge.env
Environment=CS_DIGEST_AGING_HOURS=20
# Jan Roland Delmo (Head of Operations) — docs/lessons/muso-domain.md:431.
Environment=CS_DIGEST_AGING_MENTION_UID=U038BM16T7W
ExecStart=/usr/bin/python3 $HYDRA_ROOT/scripts/cs-needs-human-digest.py --post --delta
CSDIGESTDELTASVC

cat > /etc/systemd/system/cs-needs-human-digest-delta.timer << CSDIGESTDELTATMR
[Unit]
Description=Twice daily — CS needs-human digest delta run at 07:30 + 19:30 UTC

[Timer]
OnCalendar=*-*-* 07:30:00 UTC
OnCalendar=*-*-* 19:30:00 UTC
Persistent=true
RandomizedDelaySec=120
Unit=cs-needs-human-digest-delta.service

[Install]
WantedBy=timers.target
CSDIGESTDELTATMR

systemctl daemon-reload
cnhdd=cs-needs-human-digest-delta.timer
systemctl enable "$cnhdd" >/dev/null 2>&1 || log "WARN: could not enable $cnhdd"
systemctl start "$cnhdd" >/dev/null 2>&1 || log "WARN: could not start $cnhdd"
log "  $cnhdd: $(systemctl is-active "$cnhdd" 2>/dev/null || echo unknown)"

# ─── CS weekly SLA report (Mon 08:30 UTC) ───────────
# WS1 (docs/plans autonomous-cs-machine follow-on): the SLA denominator — a
# READ-ONLY weekly report of first-response time distribution, the >24h
# residue snapshot, reopen rate, and unverified-credit queue depth, posted
# once to #cs_chats. See scripts/cs-sla-report.py.
cat > /etc/systemd/system/cs-sla-report.service << CSSLASVC
[Unit]
Description=CS weekly SLA report (#cs_chats; read-only on Intercom)
After=network-online.target

[Service]
Type=oneshot
EnvironmentFile=-/etc/openclaw/shared.env
EnvironmentFile=-/etc/openclaw/edge.env
# The unverified-credit queue-depth metric needs the muso CLI; neither sourced
# env file exports it, so pin the deployed path explicitly (cs-sla-report.py
# also resolves it deterministically from PATH/-/usr/local/bin/muso, but pinning
# keeps the telemetry intent visible in the unit). This Environment= follows the
# EnvironmentFile= lines, so it takes precedence; if the path ever moves, change
# it here.
Environment=MUSO_CLI_BIN=/usr/local/bin/muso
ExecStart=/usr/bin/python3 $HYDRA_ROOT/scripts/cs-sla-report.py --post
CSSLASVC

cat > /etc/systemd/system/cs-sla-report.timer << CSSLATMR
[Unit]
Description=Weekly — CS SLA report Mon 08:30 UTC

[Timer]
OnCalendar=Mon *-*-* 08:30:00 UTC
Persistent=true
RandomizedDelaySec=120
Unit=cs-sla-report.service

[Install]
WantedBy=timers.target
CSSLATMR

systemctl daemon-reload
cslar=cs-sla-report.timer
systemctl enable "$cslar" >/dev/null 2>&1 || log "WARN: could not enable $cslar"
systemctl start "$cslar" >/dev/null 2>&1 || log "WARN: could not start $cslar"
log "  $cslar: $(systemctl is-active "$cslar" 2>/dev/null || echo unknown)"

# ─── Close duplicate conversations (SHADOW MODE — daily 10:00 UTC) ────
# Phase 1 of docs/plans/autonomous-cs-machine.md: a deterministic sweeper
# that identifies strictly-safe DUPLICATE Intercom conversations (same
# customer, >=2 open inbound threads, resolved via the fast-path author
# email only) and would auto-close the older member of each safe pair,
# keeping the newest. THIS UNIT SHIPS SHADOW-MODE ONLY: ExecStart does NOT
# pass --apply, so no conversation is ever closed by this timer — it only
# posts "would close X -> kept Y (tier A/B)" candidate pairs to #cs_chats
# via --notify-candidates for Jan to review. The --apply --limit flip is a
# separate, later, explicitly-gated PR (Jan + Nick + Aaron sign-off on the
# Tier-B pointer text). See scripts/close-duplicate-conversations.py.
cat > /etc/systemd/system/close-duplicate-conversations.service << CLOSEDUPSVC
[Unit]
Description=Shadow-mode duplicate-conversation close sweeper (dry-run only)
After=network-online.target

[Service]
Type=oneshot
EnvironmentFile=-/etc/openclaw/shared.env
EnvironmentFile=-/etc/openclaw/edge.env
ExecStart=/usr/bin/python3 $HYDRA_ROOT/scripts/close-duplicate-conversations.py --notify-candidates
CLOSEDUPSVC

cat > /etc/systemd/system/close-duplicate-conversations.timer << CLOSEDUPTMR
[Unit]
Description=Daily — duplicate-conversation close sweeper (shadow mode) at 10:00 UTC

[Timer]
OnCalendar=*-*-* 10:00:00 UTC
Persistent=true
RandomizedDelaySec=120
Unit=close-duplicate-conversations.service

[Install]
WantedBy=timers.target
CLOSEDUPTMR

systemctl daemon-reload
cdup=close-duplicate-conversations.timer
systemctl enable "$cdup" >/dev/null 2>&1 || log "WARN: could not enable $cdup"
systemctl start "$cdup" >/dev/null 2>&1 || log "WARN: could not start $cdup"
log "  $cdup: $(systemctl is-active "$cdup" 2>/dev/null || echo unknown)"

# ─── ClickUp TO DO dedupe (hourly) ────
# Replaces the manual "@Ops find duplicate TO DO tickets by Conversation link"
# request Jan was filing 2-3x/day. It does NOT implement that literal rule:
# sharing an Intercom conversation is not a duplicate signal (7/7 of the pairs
# the hand-run moved were different action types, i.e. distinct customer
# requests; 29 real asks ended up buried in Waiting against 4 true duplicates).
# It moves only what is provably redundant — Tier A: same conversation AND same
# action type (create_ticket's own dedupe key, so a hit means its dedupe was
# escaped); Tier B: a bare intercom-auto-handoff escalation on a conversation
# that already has a real action ticket. Everything else that merely shares a
# conversation is reported to #cs_chats and left in TO DO.
# Writes go through the audited batch helper, each move carries an audit
# comment and is read back, and a run wanting more than --max-moves aborts with
# zero writes and pages #clio_devops. See scripts/clickup-todo-dedupe.py.
# ROLLBACK: reverting the repo files alone leaves the installed timer
# running on node-8 against a script that may no longer exist. A rollback
# of this surface MUST also run:
#   systemctl disable --now clickup-todo-dedupe.timer
cat > /etc/systemd/system/clickup-todo-dedupe.service << CUDEDUPESVC
[Unit]
Description=Hourly ClickUp TO DO dedupe (same-conversation + same-action, and redundant auto-handoffs)
After=network-online.target

[Service]
Type=oneshot
# node-8 SIGTERMs any Type=oneshot unit with no explicit start timeout.
TimeoutStartSec=600
EnvironmentFile=-/etc/openclaw/shared.env
EnvironmentFile=-/etc/openclaw/main.env
ExecStart=/usr/bin/python3 $HYDRA_ROOT/scripts/clickup-todo-dedupe.py
CUDEDUPESVC

cat > /etc/systemd/system/clickup-todo-dedupe.timer << CUDEDUPETMR
[Unit]
Description=Hourly — ClickUp TO DO duplicate sweep

[Timer]
OnCalendar=hourly
Persistent=true
RandomizedDelaySec=180
Unit=clickup-todo-dedupe.service

[Install]
WantedBy=timers.target
CUDEDUPETMR

systemctl daemon-reload
cud=clickup-todo-dedupe.timer
systemctl enable "$cud" >/dev/null 2>&1 || log "WARN: could not enable $cud"
systemctl start "$cud" >/dev/null 2>&1 || log "WARN: could not start $cud"
log "  $cud: $(systemctl is-active "$cud" 2>/dev/null || echo unknown)"

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
# Route reconciliation looks up each routed credit's CURRENT status through the
# sanctioned READ-ONLY muso-read wrapper (no new credential; MUSO_ADMIN_EMAIL/
# PASSWORD come from edge.env above). Pin the rsync-target repo copy — NOT a
# per-profile managed-skills path, which deploy.sh can rm -rf if the skill's
# profile classification changes. MUSO_BIN is pinned like every other
# muso-invoking unit here: systemd's unit PATH does not reliably include
# /usr/local/bin. If either pin is wrong the digest shows routed credits as
# "unresolved" (visible + safe), never crashes. Confirm on node-8:
#   bash /opt/hydra/skills-all/muso-read/scripts/muso-read.sh api GET '/admin/credit-requests?profilesIds=<uuid>&status=approved&limit=1' --json
Environment=MUSO_BIN=/usr/local/bin/muso
Environment="CAROLINE_DIGEST_MUSO_READ=bash $HYDRA_ROOT/skills-all/muso-read/scripts/muso-read.sh"
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

# ─── Caroline shipped-work feed (daily 05:30 UTC) ─────────────────────────
# Renders customer-visible product changes into
# workspaces/support/reference/recent-changes.md, the ONLY directory Caroline's
# RAG index covers (openclaw-edge.json: support.memorySearch.extraPaths=["reference"]).
# She runs on openclaw-edge with no Slack bindings and no exec, so #releases can
# never reach her; a file in that directory is the only delivery path there is.
#
# Safe to run unattended because PUBLICATION IS GATED, not the run. A render
# carrying new lines is STAGED to /var/lib/hydra-support-changelog/pending.md --
# outside reference/, so outside Caroline's RAG index -- and announced in Slack.
# Nothing reaches her until a human runs `--promote`, which re-runs the leak gate
# over the staged body before installing.
#
# That gate exists because the leak filter is shape-based: it catches every
# identifier-shaped leak, but a novel lowercase codename carrying no code shape
# can survive it (QA review on PR #904), and a vocabulary filter cannot close it
# -- measured, a KB-seeded one rejected 24 of 42 legitimate lines, and codenames
# are ordinary words anyway ("redwood", "mint", "encore"). Reporting what was
# published after installing it does not help either; the line is already
# retrievable by then. So review blocks publication.
#
# A render whose lines are all already live installs directly: nothing new to
# review, so the rolling window cannot manufacture busywork.
#   /opt/hydra/scripts/support-changelog-sync.sh --dry-run   # also prints what the gate refused
#   /opt/hydra/scripts/support-changelog-sync.sh --promote   # the human gate
# The file it writes is rsync-excluded in deploy.sh; without that exclude every
# deploy would delete it AND red the Step 4a pre-flight.
# Staging dir for renders awaiting promotion. mkdir -p, never `install -d`:
# install -d re-chmods an EXISTING directory even without -m.
mkdir -p /var/lib/hydra-support-changelog
cat > /etc/systemd/system/support-changelog-sync.service << CHANGELOGSVC
[Unit]
Description=Render Caroline's shipped-work feed into her RAG-indexed reference/
After=network-online.target

[Service]
Type=oneshot
# Up to five model calls (one per ISO week in the window) at 90s each, PLUS the
# rollout-boundary scan: one commit-status API call per candidate commit, which
# measured ~62s per repo for a 250-commit window on node-8, so ~2min of gh
# traffic before any model call. node-8 SIGTERMs a Type=oneshot that outruns the
# 90s default, which would leave the feed silently stale, so budget it
# explicitly and leave headroom above the ~10min worst case.
TimeoutStartSec=1800
EnvironmentFile=-/etc/openclaw/shared.env
EnvironmentFile=-/etc/openclaw/edge.env
Environment=HOME=/root
Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
# Review notices go to #cs_chats; the channel default lives in the script, not
# here, because --promote is run by hand and inherits no unit environment.
ExecStart=$HYDRA_ROOT/scripts/support-changelog-sync.sh
CHANGELOGSVC

cat > /etc/systemd/system/support-changelog-sync.timer << CHANGELOGTMR
[Unit]
Description=Daily — refresh Caroline's shipped-work feed at 05:30 UTC

[Timer]
# Ahead of the 06:00 Rome digests so the feed is current for the working day.
OnCalendar=*-*-* 05:30:00 UTC
Persistent=true
RandomizedDelaySec=300
Unit=support-changelog-sync.service

[Install]
WantedBy=timers.target
CHANGELOGTMR

systemctl daemon-reload
scs=support-changelog-sync.timer
systemctl enable "$scs" >/dev/null 2>&1 || log "WARN: could not enable $scs"
systemctl start "$scs" >/dev/null 2>&1 || log "WARN: could not start $scs"
log "  $scs: $(systemctl is-active "$scs" 2>/dev/null || echo unknown)"

# ─── Caroline platform.muso.ai API feed (daily 05:45 UTC) ─────────────────
# Renders workspaces/support/reference/platform-api.md from the PUBLIC
# https://platform.muso.ai/llms-full.txt -- the page the platform team already
# publishes for machine readers, whose figures come from the pricing module
# rather than being typed by hand.
#
# Unlike the shipped-work feed above there is NO staging and NO promote gate,
# and that difference is deliberate. That feed passes author-controlled PR
# titles through a language model, so its output has never been read by anyone.
# This one copies first-party pricing copy that Muso already serves to the open
# internet -- a human reviewed it when they shipped the page, and gating it again
# would only guarantee Caroline's copy is older than the customer's.
#
# The run is still fail-closed: a failed, empty, truncated or unrecognisable
# fetch leaves the previous file byte-for-byte intact. It also re-runs the CI
# blocklist (shared from lib/cs-reference-blocklist.sh) because this file is
# rsync-excluded and never committed, so pr-validate.yml structurally cannot see
# it. A content change posts a Slack notice -- unreviewed publication is the
# accepted trade-off here, so it must at least be visible.
#   /opt/hydra/scripts/sync-platform-llms.sh --dry-run   # render, write nothing
#   /opt/hydra/scripts/sync-platform-llms.sh --check     # is the live file current?
# The file it writes is rsync-excluded in deploy.sh; without that exclude every
# deploy would delete it AND red the Step 4a pre-flight.
cat > /etc/systemd/system/sync-platform-llms.service << PLATLLMSSVC
[Unit]
Description=Refresh Caroline's platform.muso.ai API + pricing feed
After=network-online.target
# No OnFailure= here on purpose: this unit is a row in AUX_ONFAILURE_UNITS
# below, and wire_unit_failure_paging inserts the directive. The script pages
# #cs_chats itself on every refusal it can SEE; the table covers the failures it
# cannot -- ExecStart missing after a bad deploy, killed by TimeoutStartSec --
# which would otherwise freeze her Platform pricing silently.

[Service]
Type=oneshot
# One curl plus local validation; seconds in practice. Set explicitly anyway --
# node-8 SIGTERMs any Type=oneshot that outruns the 90s default, and a silent
# kill here would freeze Caroline's pricing without failing anything.
TimeoutStartSec=180
EnvironmentFile=-/etc/openclaw/shared.env
EnvironmentFile=-/etc/openclaw/edge.env
Environment=HOME=/root
Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
ExecStart=$HYDRA_ROOT/scripts/sync-platform-llms.sh
PLATLLMSSVC

cat > /etc/systemd/system/sync-platform-llms.timer << PLATLLMSTMR
[Unit]
Description=Daily — refresh Caroline's platform.muso.ai feed at 05:45 UTC

[Timer]
# 15 min after the shipped-work feed's 05:30 UTC tick, so the two daily writers
# into reference/ do not land on top of each other, and early enough that both
# are settled before the working day starts.
OnCalendar=*-*-* 05:45:00 UTC
Persistent=true
RandomizedDelaySec=300
Unit=sync-platform-llms.service

[Install]
WantedBy=timers.target
PLATLLMSTMR

systemctl daemon-reload
spl=sync-platform-llms.timer
systemctl enable "$spl" >/dev/null 2>&1 || log "WARN: could not enable $spl"
systemctl start "$spl" >/dev/null 2>&1 || log "WARN: could not start $spl"
log "  $spl: $(systemctl is-active "$spl" 2>/dev/null || echo unknown)"

# Seed the feed immediately on first install. Without this the file does not
# exist until the first timer tick, and Caroline's SOUL catalog would advertise
# a reference file that retrieval cannot find. Best-effort: a fetch failure here
# must not fail the whole aux-unit install.
if [[ ! -f /opt/hydra/workspaces/support/reference/platform-api.md ]]; then
  "$HYDRA_ROOT/scripts/sync-platform-llms.sh" >/dev/null 2>&1 \
    && log "  platform-api.md: seeded" \
    || log "  WARN: platform-api.md seed failed; timer will retry at 05:45 UTC"
fi

# ─── Caroline Muso-app plan pricing feed (daily 05:50 UTC) ────────────────
# Renders workspaces/support/reference/app-pricing.md from the PUBLIC anonymous
# https://api.muso.ai/api/w/v3/subscription/public-plans, which core-backend serves
# straight from WEB_SUBSCRIPTION_PLANS_INFO -- the one module that owns these numbers.
#
# It replaces a hand-written table whose failure was not staleness but CADENCE
# CONFLATION: it showed the ANNUAL roster bracket divided by 12 under a heading that
# read monthly, so a customer on monthly billing was quoted ~25% under what they
# would pay. The renderer emits monthly and annual as separate labelled tables and
# has no code path that can blend them.
#
# Fail-closed and paging, like the platform feed: a bad fetch, malformed JSON, a
# non-ok envelope, a coupon-discounted payload, a missing cadence or a missing seats
# bracket all leave the previous file byte-for-byte intact and page #cs_chats.
#   /opt/hydra/scripts/sync-app-pricing.sh --dry-run   # render, write nothing
#   /opt/hydra/scripts/sync-app-pricing.sh --check     # is the live file current?
# The file it writes is rsync-excluded in deploy.sh. OnFailure comes from the
# AUX_ONFAILURE_UNITS table, not a hardcoded directive.
cat > /etc/systemd/system/sync-app-pricing.service << APPPRICESVC
[Unit]
Description=Refresh Caroline's Muso-app plan pricing feed
After=network-online.target

[Service]
Type=oneshot
# One curl plus jq; seconds in practice. Set explicitly anyway -- node-8 SIGTERMs any
# Type=oneshot that outruns the 90s default, and a silent kill here freezes her plan
# prices without failing anything.
TimeoutStartSec=180
EnvironmentFile=-/etc/openclaw/shared.env
EnvironmentFile=-/etc/openclaw/edge.env
Environment=HOME=/root
Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
ExecStart=$HYDRA_ROOT/scripts/sync-app-pricing.sh
APPPRICESVC

cat > /etc/systemd/system/sync-app-pricing.timer << APPPRICETMR
[Unit]
Description=Daily — refresh Caroline's Muso-app plan pricing at 05:50 UTC

[Timer]
# Just after the platform feed, still well before the working day in Europe/Rome.
OnCalendar=*-*-* 05:50:00 UTC
Persistent=true
RandomizedDelaySec=300
Unit=sync-app-pricing.service

[Install]
WantedBy=timers.target
APPPRICETMR

systemctl daemon-reload
sap=sync-app-pricing.timer
systemctl enable "$sap" >/dev/null 2>&1 || log "WARN: could not enable $sap"
systemctl start "$sap" >/dev/null 2>&1 || log "WARN: could not start $sap"
log "  $sap: $(systemctl is-active "$sap" 2>/dev/null || echo unknown)"

if [[ ! -f /opt/hydra/workspaces/support/reference/app-pricing.md ]]; then
  "$HYDRA_ROOT/scripts/sync-app-pricing.sh" >/dev/null 2>&1 \
    && log "  app-pricing.md: seeded" \
    || log "  WARN: app-pricing.md seed failed; timer will retry at 05:50 UTC"
fi

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

# ─── Nightly CTO issue-fixer overnight driver, every 30 min ───
# Deterministic gh/jq/bash supervisor for the ONE open "nightly PR" the cto
# agent's overnight OPEN turn is tracking (state at
# /var/lib/hydra-cto-nightly/current.json). Ticks every 30 min: clears state
# on PR close/merge, posts a final "ready for merge" note once CI + review +
# mergeable state all settle green, and dispatches a single bounded cto
# FIX-PASS one-shot only when there's an actual delta to act on (never a bare
# LLM poll). See scripts/cto-nightly-driver.sh for the full tick logic.
install -d -m 755 /var/lib/hydra-cto-nightly
cat > /etc/systemd/system/cto-nightly-driver.service << CTONIGHTLYSVC
[Unit]
Description=Nightly CTO issue-fixer overnight driver (supervises the open nightly PR)
After=network-online.target

[Service]
Type=oneshot
# main.env, NOT edge.env: this driver dispatches to the MAIN gateway's cto
# agent (openclaw --profile main cron add) — carrying edge's
# OPENCLAW_STATE_DIR would aim any profile-blind resolver path at the wrong
# profile (see the state-dir pin doctrine in CLAUDE.md).
EnvironmentFile=-/etc/openclaw/shared.env
EnvironmentFile=-/etc/openclaw/main.env
ExecStart=$HYDRA_ROOT/scripts/cto-nightly-driver.sh
CTONIGHTLYSVC

cat > /etc/systemd/system/cto-nightly-driver.timer << CTONIGHTLYTMR
[Unit]
Description=Every 30 min — supervise the nightly CTO issue-fixer's open PR

[Timer]
OnBootSec=5min
OnUnitActiveSec=30min
Unit=cto-nightly-driver.service

[Install]
WantedBy=timers.target
CTONIGHTLYTMR

systemctl daemon-reload
ctn=cto-nightly-driver.timer
# RETIRED 2026-07-21 (token-cost cut, Nick): the nightly CTO issue-fixer is
# permanently disabled — its seeder cron (cto-nightly-issue-fixer) is off in
# cron-jobs.json and stays off across the 2026-07-24 #720 revert. This driver
# only supervises a seeded PR (no seed ⇒ scripts/cto-nightly-driver.sh exits 0),
# so leaving the timer running is harmless, but we DISABLE it here rather than
# enable so a re-run of this installer does not re-arm the 30-min tick. The unit
# files are still written above, so reviving it later is a one-liner:
#   systemctl enable --now cto-nightly-driver.timer
if systemctl disable --now "$ctn" >/dev/null 2>&1; then
  log "  $ctn: disabled (nightly CTO issue-fixer retired)"
else
  # Non-fatal (never abort the installer on this), but NEVER silently claim
  # success: a masked failure would leave the 30-min token-burning timer armed
  # while the deploy reports it retired. Report the real state so it's caught.
  log "  WARN: could not disable $ctn — timer may still be armed; verify with 'systemctl is-enabled $ctn' and disable manually"
fi

# ─── Gateway pre-start self-heal drop-ins ─────────────────────
# One drop-in per profile, hard-coded with the profile name (the
# base units are not systemd templates so %i is unavailable). The
# drop-in adds ExecStartPre=…/openclaw-pre-start-heal.sh <profile>,
# StartLimitBurst/IntervalSec to break crash-loops cleanly, and a
# raised node heap cap (NODE_OPTIONS).
# A re-run of migrate-to-multi-gateway.sh recreates the base unit
# but does NOT touch the .service.d/ directory, so the drop-in
# survives. We daemon-reload + reset-failed at the end so a
# previously-tripped restart limit doesn't stick around after
# the heal infrastructure is in place.
HEAP_SNAPSHOT_DIR=/var/lib/hydra/heap-snapshots
cat > /etc/tmpfiles.d/hydra-heap-snapshots.conf << HEAPTMPFILES
# MANAGED BY scripts/install-aux-units.sh — DO NOT EDIT BY HAND.
# Gateway near-OOM heap snapshots are several GB each; keep 3 days by mtime
# (not atime/ctime, so reading a snapshot during incident investigation does not reset the timer).
d ${HEAP_SNAPSHOT_DIR} 0700 root root m:3d
HEAPTMPFILES
systemd-tmpfiles --create /etc/tmpfiles.d/hydra-heap-snapshots.conf
DIAG_DIR=/var/lib/hydra/diag
cat > /etc/tmpfiles.d/hydra-gateway-diag.conf << DIAGTMPFILES
# MANAGED BY scripts/install-aux-units.sh — DO NOT EDIT BY HAND.
# MUS-2652 temporary: main gateway diagnostics-timeline JSONL; keep 3 days.
d ${DIAG_DIR} 0700 root root 3d
DIAGTMPFILES
systemd-tmpfiles --create /etc/tmpfiles.d/hydra-gateway-diag.conf
# tmpfiles ages by mtime, and openclaw appends to this ONE fixed file, so every
# append refreshes mtime and the 3d age never fires while main is active. Rotate
# it for real. copytruncate: the writer holds the fd open, no reopen signal.
cat > /etc/logrotate.d/hydra-gateway-diag << 'DIAGLOGROTATE'
# MANAGED BY scripts/install-aux-units.sh — DO NOT EDIT BY HAND.
/var/lib/hydra/diag/main-timeline.jsonl {
    daily
    maxsize 200M
    rotate 3
    compress
    missingok
    notifempty
    copytruncate
}
DIAGLOGROTATE
chmod 644 /etc/logrotate.d/hydra-gateway-diag
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
  # EDGE ONLY, same conditional: MemoryLow=6G protects edge (Caroline) from
  # reclaim when main / Paperclip put the box under memory pressure (Aaron's go
  # 9 Oct via Nick, MUS-5057 W3). Soft protection only; MemoryMax stays infinity.
  # Both edge-only lines share one variable so main's drop-in stays
  # byte-identical (a second bare ${...} line would add a blank line to main).
  edge_only=""
  if [ "$profile" = "edge" ]; then
    edge_only="ExecStartPost=-/usr/bin/systemctl start --no-block openclaw-edge-reindex.service
MemoryLow=6G"
  fi
  # MAIN ONLY, TEMPORARY (MUS-2652 / MUS-1295): openclaw's own startup trace +
  # diagnostics timeline, to name the 20-28 min post-start freeze (main thread
  # at 100% CPU). Journal gets per-span "startup trace:" lines; the JSONL at
  # ${DIAG_DIR} carries the span active at each event-loop stall. =timeline, NOT
  # =1: =1 is the wildcard and enables all nine flags incl. brave.http and
  # telegram.http (provider HTTP traffic in the journal). Edge never gets these.
  # Remove: delete trace_env + the tmpfiles conf above, re-run this installer.
  trace_env=""
  if [ "$profile" = "main" ]; then
    trace_env="Environment=\"OPENCLAW_GATEWAY_STARTUP_TRACE=1\"
Environment=\"OPENCLAW_GATEWAY_RESTART_TRACE=1\"
Environment=\"OPENCLAW_DIAGNOSTICS=timeline\"
Environment=\"OPENCLAW_DIAGNOSTICS_EVENT_LOOP=1\"
Environment=\"OPENCLAW_DIAGNOSTICS_TIMELINE_PATH=${DIAG_DIR}/main-timeline.jsonl\""
  fi
  # Heap cap: node's default (~4 GB) is below main's normal working set. Its
  # heap swings 1-3.6 GB all day, and every spike past the cap is a V8
  # "heap out of memory" SIGABRT plus a ~10 min post-restart freeze: 8 crashes
  # 2026-09-17..23, two on 09-23 three hours apart. Not a steady leak (heap is
  # back to ~2 GB within 30 min of a restart), so a higher ceiling is the fix.
  # Snapshots were disabled (cost: ~2.5 min GC pause + 6-6.8 GB per crash).
  # tmpfiles ages out any lingering snapshots from prior crashes after 3d.
  cat > "$drop_dir/override.conf" << GATEWAYDROP
# MANAGED BY scripts/install-aux-units.sh — DO NOT EDIT BY HAND.
# Reference template: scripts/aux-units/openclaw-gateway.override.conf
[Service]
Environment="NODE_OPTIONS=--max-old-space-size=8192 --diagnostic-dir=${HEAP_SNAPSHOT_DIR}"
${trace_env}
ExecStartPre=$HYDRA_ROOT/scripts/openclaw-pre-start-heal.sh ${profile}
${edge_only}
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
# BOTH profiles: edge is the one that CANNOT self-heal. Its auth cell carries
# SYNC-MANAGED-NO-REFRESH-TOKEN in the refresh slot by design, so it depends
# entirely on codex-edge-mirror.timer copying main's rotated access token. If
# that mirror stalls, edge silently rides to expiry and Caroline drops to paid
# OpenRouter — which is exactly what happened 2026-09-11..16, when the mirror
# was merged but undeployed and edge sat on tokens expiring 09-20 while main
# had already rotated to 09-26. The keepalive's per-profile loop only READS an
# expiry and pages; all three actuators (usage-cap, revocation, proactive
# rotate) run ONCE outside it, so adding a profile cannot double-rotate.
# Verified live: `CODEX_KEEPALIVE_PROFILES="main edge"` reports
# "edge: codex token healthy (13903m remaining)" alongside main's identical
# figure — the mirrored value, which is precisely the signal we want watched.
# codex-keepalive.sh reads the token's own expiry from the canonical auth store
# (auth-profiles.json — NOT the CLI; 7.x `models status --json` has no expiry
# data) and pages BEFORE the cliff (it is the safety net for the twice-weekly
# codex-token-refresh timer). 15 min is plenty — the lapse cadence is ~days, and
# the periodic check is a cheap local file read (no network). Sets an
# explicit PATH (cron's default is /usr/bin:/bin) so `jq` resolves even if it
# lives in /usr/local/bin — the keepalive fails Slack-silently
# if it doesn't. Same ownership rule: edit here + re-run install-aux-units.sh.
cat > /etc/cron.d/codex-keepalive << CODEXKEEPALIVE
# MANAGED BY scripts/install-aux-units.sh — DO NOT EDIT BY HAND.
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
*/15 * * * * root CODEX_KEEPALIVE_PROFILES="main edge" $HYDRA_ROOT/scripts/codex-keepalive.sh >> /var/log/codex-keepalive.log 2>&1
CODEXKEEPALIVE
chmod 644 /etc/cron.d/codex-keepalive

# ─── Codex per-account quota measurement at 20-min cadence ────
# codex-quota-refresh.sh probes EACH codex account's real quota via the
# vendored `codex app-server` JSON-RPC method account/rateLimits/read and
# persists it to /var/lib/hydra/codex-usage/<key>.measure.tsv.
#
# WHY (incident 2026-08-05/06): standby quota was never measured, only
# inferred from the fleet-freshest rollout — which carries no account identity
# on 7.x. The inference put the SAME subscription's numbers under three
# different accounts (two archives shared a reset epoch to the second) and
# produced a page claiming "every alternate account is known-capped" while two
# Pro subscriptions sat at 4% and 0%.
#
# 20 min is deliberate: the probe is a network round-trip per account, the
# thing it measures moves on the scale of hours, and codex-keepalive.sh (15
# min) must never find a measurement older than its freshness floor. flock
# keeps a slow probe from stacking. Explicit PATH for the same reason as the
# keepalive block above (cron's default omits /usr/local/bin, and jq must
# resolve or the collector degrades to silence).
mkdir -p /etc/hydra
# tmpfs scratch root for the probe — an access token written here never
# reaches a disk block or a backup, and a reboot clears it regardless.
install -d -m 700 /run/hydra 2>/dev/null || { mkdir -p /run/hydra; chmod 700 /run/hydra; }
cat > /etc/cron.d/codex-quota-refresh << CODEXQUOTA
# MANAGED BY scripts/install-aux-units.sh — DO NOT EDIT BY HAND.
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
*/20 * * * * root flock -n /run/lock/codex-quota-refresh.lock $HYDRA_ROOT/scripts/codex-quota-refresh.sh >> /var/log/codex-quota-refresh.log 2>&1
CODEXQUOTA
chmod 644 /etc/cron.d/codex-quota-refresh

# Seed the active-account ledger once, so cq_ledger_account_at can attribute
# rollout snapshots from the moment this ships rather than only after the first
# rotation. Append-only; never truncate an existing ledger.
CODEX_LEDGER=/var/lib/hydra/codex-usage/active-account.log
if [ ! -s "$CODEX_LEDGER" ]; then
  mkdir -p "$(dirname "$CODEX_LEDGER")"
  _seed_acct="$(head -n1 /var/lib/hydra/codex-active-account 2>/dev/null | tr -d '[:space:]')"
  [ -n "$_seed_acct" ] || _seed_acct="openai-codex:aaron@muso.ai"
  printf '%s\t%s\t%s\n' "$(date +%s)" "$_seed_acct" "ledger seeded by install-aux-units.sh" >> "$CODEX_LEDGER"
  chmod 600 "$CODEX_LEDGER"
  log "  codex active-account ledger seeded with $_seed_acct"
fi

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

# ─── Refund + credit-balance overlap watchdog, daily ──────────
# Pages #clio_devops when a cash refund and a live customer-balance concession
# credit exist for the same customer — one unused period paid for twice.
#
# DAILY, not 5-minutely, on purpose. This is a finance-reconciliation signal,
# not a liveness one: nothing is on fire while a duplicate credit sits there,
# and the 2026-09-09 audit's oldest case had been sitting since 2022. A tight
# cadence would just re-read Stripe 288x a day for a class that changes a
# handful of times a month.
#
# It is DETECT-ONLY and never moves money — remediation is
# scripts/remediate-refund-credit-overlap.sh, which is dry-run by default and
# requires an allowlisted approver, because zeroing a real customer's balance
# is a human decision. Same ownership rule: edit here + re-run
# install-aux-units.sh, never edit the file on node-8.
cat > /etc/cron.d/refund-credit-overlap-watchdog << REFUNDOVERLAP
# MANAGED BY scripts/install-aux-units.sh — DO NOT EDIT BY HAND.
17 7 * * * root $HYDRA_ROOT/scripts/refund-credit-overlap-watchdog.sh >> /var/log/refund-credit-overlap-watchdog.log 2>&1
REFUNDOVERLAP
chmod 644 /etc/cron.d/refund-credit-overlap-watchdog

# Agent SOUL-delivery guard (MUS-6635): MUS-6600 left every gpt-6 agent
# soul-less for ~3h behind a green "answers PONG" check. Reads the model-visible
# developer message of each live agent's newest session; pages #clio_devops on a
# missing AGENT_SOUL / <available_skills> / cron-mode marker. 15 min: sessions
# are the signal, not a deploy event (a deploy-time assertion would see no
# post-restart session); identical failures re-page at most every 6h. Same
# ownership rule: edit here + re-run install-aux-units.sh.
cat > /etc/cron.d/agent-soul-delivery-guard << SOULGUARD
# MANAGED BY scripts/install-aux-units.sh — DO NOT EDIT BY HAND.
*/15 * * * * root $HYDRA_ROOT/scripts/check-agent-soul-delivery.sh --alert >> /var/log/agent-soul-delivery-guard.log 2>&1
SOULGUARD
chmod 644 /etc/cron.d/agent-soul-delivery-guard

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

# Stuck-lane watchdog: alerts #clio_devops when the EDGE gateway force-aborts a
# wedged agent run WITHOUT releasing the lane (action=abort_embedded_run …
# released=0) — the moment Caroline's generated reply is silently discarded
# (upstream openclaw #97538, no released fix). This is the OUT-OF-PROCESS ops
# backstop to the in-plugin dispatch-timeout page (which handles CUSTOMER pickup
# to #cs-escalations); it fires from journald even if the plugin path is broken
# or mid-deploy. 2 min: matches openclaw-watchdog's edge scan cadence; per-conv
# 6h-cooldown dedupe means one wedge pages once. Same ownership rule: edit here +
# re-run install-aux-units.sh.
cat > /etc/cron.d/stuck-lane-watchdog << STUCKLANEWD
# MANAGED BY scripts/install-aux-units.sh — DO NOT EDIT BY HAND.
*/2 * * * * root $HYDRA_ROOT/scripts/stuck-lane-watchdog.sh >> /var/log/stuck-lane-watchdog.log 2>&1
STUCKLANEWD
chmod 644 /etc/cron.d/stuck-lane-watchdog

# ─── Merge-landing watchdog at 30-min cadence ─────────────────
# Alerts #clio_devops when an admin profile-merge returned HTTP 200 (logged to
# recent-merges.jsonl) but never LANDED in the catalog — the loser is still an
# active, unmerged profile hours later. Root cause: mergeProfiles.js only
# enqueues an async ingestion job; the worker can exhaust retries before the
# catalog mutation lands. This bit the 2026-06-08/09 Jan ↔ Ops
# threads (two pairs 200'd 4× over days, never merged). 30 min (not 5): the async
# fold legitimately takes minutes–hours and the script's MIN_AGE_HOURS already
# filters the in-flight window, so a tighter cadence adds admin API load without
# catching anything sooner. Per survivor:loser dedupe → a stuck merge pages once.
# Same ownership rule: edit here + re-run install-aux-units.sh.
cat > /etc/cron.d/merge-landing-watchdog << MERGELANDINGWD
# MANAGED BY scripts/install-aux-units.sh — DO NOT EDIT BY HAND.
*/30 * * * * root $HYDRA_ROOT/scripts/merge-landing-watchdog.sh >> /var/log/merge-landing-watchdog.log 2>&1
MERGELANDINGWD
chmod 644 /etc/cron.d/merge-landing-watchdog

# ─── muso CLI state-dir pin for ALL login/SSH contexts ────────
# The gateways get MUSO_STATE_DIR=/var/log/muso-ops from their env files, but
# an ad-hoc root SSH shell has no pin, so the CLI falls back to its XDG state
# dir and merge audit lines land in /root/.local/state/muso — invisible to the
# merge-landing watchdog's primary feed AND to the CLI's own cross-process
# merge-overlap guard (split-brain found 2026-07-24). /etc/environment is read
# by PAM for every session type, including non-interactive `ssh host cmd`.
# Idempotent: replace-or-append the single line.
if grep -q '^MUSO_STATE_DIR=' /etc/environment 2>/dev/null; then
  sed -i 's|^MUSO_STATE_DIR=.*|MUSO_STATE_DIR=/var/log/muso-ops|' /etc/environment
else
  # guard: a pre-existing file without a trailing newline would glue our line
  # onto its last var (and hide it from the grep above on the next run)
  [ -s /etc/environment ] && [ -n "$(tail -c1 /etc/environment)" ] && echo >> /etc/environment
  echo 'MUSO_STATE_DIR=/var/log/muso-ops' >> /etc/environment
fi

# ─── Prod-log alert watchdog at 5-min cadence ─────────────────
# Posts NEW prod error-log lines (kubectl, read-only, redacted) to
# #prod-alerts (C0BA8QMV3ME) so engineers see prod errors without asking the
# devops agent (Serhii's ask, 2026-06-09). 5 min with a 6-min log window:
# the overlap means no gap between ticks, and the per-fingerprint cooldown
# (6h) means a persistent error pages once, not every tick. Same ownership
# rule: edit here + re-run install-aux-units.sh, never edit on node-8.
#
# Since 2026-08-05 the script defaults to the v2 path: an error must PERSIST
# (~5 min of log-line time) or match a fast-path pattern before it posts,
# eligible incidents roll up into one digest every 15 min, and only a P0 pages
# a human. No env var is set here on purpose — the default lives in ONE place
# (the script), so there is no cron-vs-script disagreement to debug at 3am.
#
# DO NOT wire a rollback through this file: the `cat >` below rewrites it
# wholesale on every deploy, so an env var added here vanishes the moment a
# fix-forward ships — mid-incident, silently. The rollback lever is the
# deploy-proof flag file /etc/hydra/prod-log-alert-v1.enabled; see the RUNBOOK.
#
# /var/lib/prod-log-alert holds both the v1 fingerprint map (seen.json) and the
# v2 incident ledger (incidents.json). `mkdir -p`, not `install -d`: install -d
# re-chmods an EXISTING dir to 0755 even without -m.
mkdir -p /var/lib/prod-log-alert
# /etc/hydra is where the operator-facing switch FILES live (this watchdog's v1
# rollback flag, the classifier kill switch, dr-ai-healer.disabled). Nothing
# created it before, so `touch /etc/hydra/...` failed on a clean box — a lever
# you only discover is missing while trying to pull it is not a lever.
mkdir -p /etc/hydra
cat > /etc/cron.d/prod-log-alert-watchdog << PRODLOGWD
# MANAGED BY scripts/install-aux-units.sh — DO NOT EDIT BY HAND.
*/5 * * * * root $HYDRA_ROOT/scripts/prod-log-alert-watchdog.sh >> /var/log/prod-log-alert-watchdog.log 2>&1
PRODLOGWD
chmod 644 /etc/cron.d/prod-log-alert-watchdog

# ─── Sentry issue watchdog, every 30 min ──────────────────────
# Polls Sentry for new unresolved issues in the code-owning projects and posts
# ONE digest to #sentry-alerts. Cadence is deliberately slow: detection latency
# was never the bottleneck (CORE-BACKEND-K9 sat unresolved from 2025-03-19),
# triage was. 3 requests / 30 min = 144/day, against a measured Sentry burst
# limit of 5 per ~1s window.
#
# Same rule as the prod-log block above: set NO env vars here. This file is
# regenerated wholesale on every deploy, so a knob added here disappears the
# moment a fix-forward ships. The deploy-proof levers are the flag files
# /etc/hydra/sentry-issue-watchdog.{disabled,no-dispatch}; see the RUNBOOK.
#
# TWO state dirs, and the second one is not ours: /var/lib/hydra-sentry-triage
# belongs to the sentry-issue-triage SKILL (its seen.jsonl ledger and .lock).
# Creating it here means the skill's own `mkdir -p` is never the first thing to
# touch it, so the watchdog can treat "ledger absent" as "nothing triaged yet"
# and "ledger unreadable" as an error -- two different states that a
# first-run-creates-it race would otherwise blur.
# `mkdir -p`, not `install -d`: install -d re-chmods an EXISTING dir to 0755
# even without -m, and the ledger dir is shared state.
mkdir -p /var/lib/hydra-sentry-watchdog /var/lib/hydra-sentry-triage
cat > /etc/cron.d/sentry-issue-watchdog << SENTRYWD
# MANAGED BY scripts/install-aux-units.sh — DO NOT EDIT BY HAND.
*/30 * * * * root $HYDRA_ROOT/scripts/sentry-issue-watchdog.sh >> /var/log/sentry-issue-watchdog.log 2>&1
SENTRYWD
chmod 644 /etc/cron.d/sentry-issue-watchdog

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

# ─── Mercury token watchdog, daily ────────────────────────────
# Pages #clio_devops (C0ADV2W76G4) when the Finance agent's read-only Mercury
# Bank API token stops authenticating. Detect-only by design: replacing the
# token needs a human in the Mercury dashboard, so there is nothing to
# self-heal — same posture as ensure-session-budget-headroom.sh.
#
# Daily at 08:45 UTC, just after the stale-ticket digest. A revoked banking
# credential is not latency-sensitive to the minute (it stays broken until a
# human acts) and each tick costs one authenticated call to a bank API — a
# 5-minute cadence would buy nothing and spend 288 of them a day. The script's
# own 20h rate limit keeps a persistently-dead token to one page per day
# instead of a daily nag that everyone learns to scroll past.
# Same ownership rule: edit here + re-run install-aux-units.sh.
# The cooldown stamps live here. `mkdir -p`, NOT `install -d`: this dir
# pre-exists and is shared with codex-active-account / codex-usage / the QA
# host-identity kill switch, and `install -d` re-chmods an EXISTING directory to
# 0755 even with no -m (verified on node-8, coreutils 9.4: a 0700 dir came back
# 0755). mkdir -p leaves an existing dir's mode alone, so this can never widen
# someone else's state dir.
mkdir -p /var/lib/hydra
cat > /etc/cron.d/mercury-token-watchdog << MERCURYTOKENWD
# MANAGED BY scripts/install-aux-units.sh — DO NOT EDIT BY HAND.
# The detector reads the token from /opt/hydra/secrets/mercury.env (0600, kept
# out of the workspace tree so agent sweeps and the hydra-audit snapshot can't
# pick it up) and never prints it. MUSO_BIN is absolute: cron's PATH is minimal
# and slack-notify.sh needs it to page.
45 8 * * * root MUSO_BIN=/usr/local/bin/muso $HYDRA_ROOT/scripts/mercury-token-watchdog.sh >> /var/log/mercury-token-watchdog.log 2>&1
MERCURYTOKENWD
chmod 644 /etc/cron.d/mercury-token-watchdog

# ─── Ads-inquiry watchdog every 15 min ────────────────────────
# Pings Aaron in #cs_priority (C0BBTAVP44X) when a hydra-action-request
# ticket is an ads-BUYING lead (customer wants to advertise with Muso).
# 15-min cadence: sales leads are latency-sensitive in a way overdue
# digests aren't; the `ads-lead-pinged` ClickUp tag dedupes across ticks.
# Same ownership rule: edit here + re-run install-aux-units.sh.
cat > /etc/cron.d/ads-inquiry-watchdog << ADSINQUIRYWD
# MANAGED BY scripts/install-aux-units.sh — DO NOT EDIT BY HAND.
# Routed through the gated muso clickup provider like the sibling ClickUp
# watchdogs (cron PATH is minimal, so MUSO_BIN must be absolute). The dedupe
# tag write carries --requester attribution via clickup-muso.sh.
*/15 * * * * root USE_MUSO_CLI=1 MUSO_BIN=/usr/local/bin/muso $HYDRA_ROOT/scripts/ads-inquiry-watchdog.sh >> /var/log/ads-inquiry-watchdog.log 2>&1
ADSINQUIRYWD
chmod 644 /etc/cron.d/ads-inquiry-watchdog

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
# edge/support: heals via 'index --force'.
*/10 * * * * root $HYDRA_ROOT/scripts/caroline-rag-index-watchdog.sh >> /var/log/caroline-rag-index-watchdog.log 2>&1
# main: same watchdog, staggered 5 min so the two heavy heals don't collide on
# the embedding provider, with DISTINCT lock/state/heal/flap/ts files so the two
# instances never clobber each other's watermark or serialize on one flock.
# Detects on the cmo canary, heals the whole reference-bearing set; HEAL_CMD
# auto-derives to 'status --index' from PROFILE=main. CAROLINE_RAG_HEAL_AGENTS
# below must stay IN LOCKSTEP with the deploy-time reset loop in scripts/deploy.sh.
5-59/10 * * * * root CAROLINE_RAG_PROFILE=main CAROLINE_RAG_AGENT=cmo CAROLINE_RAG_HEAL_AGENTS='cmo cto finance ceo operations devops' CAROLINE_RAG_LOCKFILE=/var/run/caroline-rag-index-watchdog-main.lock CAROLINE_RAG_STATE_FILE=/var/lib/caroline-rag-index-watchdog/last-alert-main CAROLINE_RAG_HEAL_LOG=/var/lib/caroline-rag-index-watchdog/heal-history-main CAROLINE_RAG_FLAP_STATE=/var/lib/caroline-rag-index-watchdog/last-flap-alert-main CAROLINE_RAG_ALERT_TS_FILE=/var/lib/caroline-rag-index-watchdog/last-alert-ts-main $HYDRA_ROOT/scripts/caroline-rag-index-watchdog.sh >> /var/log/caroline-rag-index-watchdog-main.log 2>&1
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

# The daily cut is SUPERSEDED by hydra-release-watch.timer, which cuts a
# release per confirmed prod deploy instead of once a weekday morning.
# The unit files stay installed on purpose: reverting to the daily cadence
# is then `systemctl enable --now hydra-release.timer` plus flipping the
# repo's `cadence` field in scripts/lib/release-repos.sh, with nothing to
# reinstall. Leaving BOTH enabled would double-cut every morning.
# Fail CLOSED, and VERIFY rather than assume. The previous form swallowed a
# failed disable and logged success regardless, so a timer that stayed
# enabled would run alongside the watcher and both would cut a tag for the
# same day. Tags cannot be un-cut, so this aborts before the watcher is
# installed rather than leaving two release paths armed.
ensure_superseded_timer_off() {
  local tmr="$1" reason="${2:-superseded and must not run}" en act
  systemctl disable --now "$tmr" >/dev/null 2>&1 || true
  # `|| true` is REQUIRED on the capture, not sloppiness: `is-enabled` exits
  # non-zero for the expected "disabled" answer, and set -e would abort here.
  # It does mean a systemd/D-Bus error is indistinguishable from an answer,
  # so the DECISION below must not be a blacklist. It once was, rejecting
  # only "enabled"/"active" -- which let an empty string (query failed) read
  # as safe and arm the watcher next to a live daily timer.
  en="$(systemctl is-enabled "$tmr" 2>/dev/null || true)"
  act="$(systemctl is-active "$tmr" 2>/dev/null || true)"
  # An empty answer is AMBIGUOUS: the unit may not exist (safe -- nothing can
  # fire), or the query itself may have failed (unknown). Resolve which,
  # rather than assuming. Assuming "safe" is precisely the bug this guard had.
  if [[ -z "$en" ]] && ! systemctl cat "$tmr" >/dev/null 2>&1; then
    log "  $tmr: not installed — nothing to supersede"
    return 0
  fi
  # Past that, accept ONLY states that positively prove the timer cannot
  # fire. Anything else -- an unknown state, or the empty string left by a
  # failed query on a unit that DOES exist -- is indeterminate, and
  # indeterminate fails CLOSED. Tags cannot be un-cut, so refusing to
  # install is always cheaper than double-cutting a release.
  case "$en" in
    disabled|masked|masked-runtime|static|indirect|not-found) ;;
    *) fail "$tmr: cannot confirm it is disabled (is-enabled returned '${en:-<query failed>}'). ${reason}. Resolve it by hand, then re-run." ;;
  esac
  case "$act" in
    inactive|failed|deactivating|unknown|not-found) ;;
    *) fail "$tmr: cannot confirm it is stopped (is-active returned '${act:-<query failed>}'). ${reason}. Resolve it by hand, then re-run." ;;
  esac
  log "  $tmr: disabled (enabled=$en active=$act) — ${reason}"
}

ensure_superseded_timer_off hydra-release.timer "superseded by hydra-release-watch.timer: both would cut a release for the same day"

# ─── Per-deploy release watcher (every 5 min) ─────────────────
# Detects confirmed PROD releases across the ENABLED repos (hydra and
# web-credits-next today; auth once its upstream posts a rollout status),
# cuts a CalVer tag + GitHub release for each, and announces them in
# #releases. Detection is pure gh/git/jq against a per-sha commit status;
# the highlights come from a tool-less direct HTTP model call, and a failed
# call degrades to the deterministic rendering rather than skipping the
# announcement.
cat > /etc/systemd/system/hydra-release-watch.service << RELWATCHSVC
[Unit]
Description=Hydra release watcher (announces confirmed prod releases in #releases)

[Service]
Type=oneshot
ExecStart=$HYDRA_ROOT/scripts/release-watch.sh
# The channel id lives here, NOT in the unit: it is environment, and the
# script fails closed without it rather than cutting tags nobody sees.
# The leading '-' keeps the unit valid before the file exists.
EnvironmentFile=-/etc/hydra/releases.env
# node-8 SIGTERMs any Type=oneshot that does not set this, at the 90s
# default. A tick can legitimately run for minutes: up to three repos,
# each waiting on a highlights turn, plus clone/fetch on a cold checkout.
TimeoutStartSec=1800
# HOME for gh's config, PATH for git/gh/jq/openclaw/muso.
Environment=HOME=/root
Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
StandardOutput=append:/var/log/hydra-release-watch.log
StandardError=append:/var/log/hydra-release-watch.log
RELWATCHSVC

cat > /etc/systemd/system/hydra-release-watch.timer << RELWATCHTMR
[Unit]
Description=Check for confirmed prod releases every 5 minutes

[Timer]
OnBootSec=5min
OnUnitActiveSec=5min
# NOT Persistent: a missed tick is harmless because detection is
# state-based, not time-based. The next tick sees the same unannounced
# release and handles it. Catching up on missed fires would only produce
# a burst of redundant runs after downtime.
Persistent=false
RandomizedDelaySec=30s
Unit=hydra-release-watch.service

[Install]
WantedBy=timers.target
RELWATCHTMR

systemctl daemon-reload

# The watcher fails closed without a channel id, so enabling the timer
# before /etc/hydra/releases.env exists is safe: every tick exits non-zero
# with the reason, and nothing is tagged.
if [ ! -r /etc/hydra/releases.env ]; then
  log "  NOTE: /etc/hydra/releases.env absent — release-watch will refuse to run until"
  log "        it carries RELEASES_SLACK_CHANNEL=<#releases channel id>."
fi

# Fail CLOSED. This is now the LIVE release path, so a timer that silently
# fails to arm means every production release afterwards goes unannounced
# with nothing but a log warning to say so. The best-effort form was
# inherited from units where a missed tick is recoverable; this one is not.
ensure_timer_armed() {
  local tmr="$1" en act
  systemctl enable "$tmr" >/dev/null 2>&1 || true
  systemctl start "$tmr"  >/dev/null 2>&1 || true
  en="$(systemctl is-enabled "$tmr" 2>/dev/null || true)"
  act="$(systemctl is-active "$tmr" 2>/dev/null || true)"
  if [[ "$en" != "enabled" || "$act" != "active" ]]; then
    fail "$tmr did not arm (enabled=$en active=$act). This is the live release path: leaving it unarmed means every prod release goes unannounced. Fix the unit, then re-run."
  fi
  log "  $tmr: enabled=$en active=$act"
}

ensure_timer_armed hydra-release-watch.timer

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
# Runs clean-my-linux.sh, the orchestrator that orders and gates the
# reaping rules (tmp-reaper, workspace clones, codex home, hot-patch
# *.bak/*.orig >30d, apt autoremove/autoclean) under per-run caps.
# Posts a Block Kit summary to #clio_devops on every run. Exit 1 =
# structural refusal (surfaces as a failed unit); per-file delete errors
# stay exit 0 and report via Slack.
# clean-my-linux.sh defaults to a dry-run, so the unit passes --apply
# explicitly; its cadence/rename is MUS-6056's.
cat > /etc/systemd/system/hydra-weekly-cleanup.service << CLEANUPSVC
[Unit]
Description=HYDRA weekly server cleanup (clean-my-linux orchestrator)

[Service]
Type=oneshot
ExecStart=$HYDRA_ROOT/scripts/clean-my-linux.sh --apply
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

# ─── Jev shadow-row retention (daily 05:15 UTC) ──────────────────
# Every Jev shadow row now carries the raw `state` object next to
# state_sha256 (scripts/lib/jev.sh, plugins/intercom's jev-shadow-log.ts,
# format-digest.sh) so a misclassification can be replayed against Jev
# directly -- but that's customer text, so it must not accumulate on disk
# unbounded. scripts/jev-shadow-prune.sh drops rows older than
# JEV_SHADOW_RETENTION_DAYS (default 30) from every $JEV_SHADOW_DIR/*.jsonl,
# atomically and under the same per-file flock the writers use. A single
# global unit (not per-profile): the shadow dir is shared, not gateway-scoped.
[[ -x "$HYDRA_ROOT/scripts/jev-shadow-prune.sh" ]] \
  || fail "$HYDRA_ROOT/scripts/jev-shadow-prune.sh missing or not executable"

cat > /etc/systemd/system/hydra-jev-shadow-prune.service << JEVPRUNESVC
[Unit]
Description=Prune Jev shadow rows older than the retention window

[Service]
Type=oneshot
ExecStart=$HYDRA_ROOT/scripts/jev-shadow-prune.sh
Environment=HOME=/root
Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
# A handful of small *.jsonl rewrites under flock; generous headroom over the
# default 90s oneshot SIGTERM so a large/contended shadow dir never gets cut
# off mid-run.
TimeoutStartSec=10min
StandardOutput=append:/var/log/hydra-jev-shadow-prune.log
StandardError=append:/var/log/hydra-jev-shadow-prune.log
JEVPRUNESVC

cat > /etc/systemd/system/hydra-jev-shadow-prune.timer << JEVPRUNETMR
[Unit]
Description=Run the Jev shadow-row prune daily at 05:15 UTC

[Timer]
OnCalendar=*-*-* 05:15:00 UTC
Persistent=true
RandomizedDelaySec=10min
Unit=hydra-jev-shadow-prune.service

[Install]
WantedBy=timers.target
JEVPRUNETMR

systemctl daemon-reload

jptmr=hydra-jev-shadow-prune.timer
systemctl enable "$jptmr" >/dev/null 2>&1 || fail "could not enable $jptmr"
systemctl start "$jptmr" >/dev/null 2>&1 || fail "could not start $jptmr"
jpstate="$(systemctl is-active "$jptmr" 2>/dev/null || true)"
[[ "$jpstate" == "active" ]] || fail "$jptmr is not active (state: ${jpstate:-unknown})"
log "  $jptmr: $jpstate (fires daily 05:15 UTC)"

# ─── /tmp scratch reaper (hourly) ────────────────────────────────
# systemd-tmpfiles has no open-handle check and its floor is 24h; on 2026-10-08
# only 32 of 6,055 /tmp entries were >1d old while / went 85% -> 93% in 26h.
# scripts/tmp-reaper.sh reaps the known scratch patterns within hours, skipping
# anything with an open handle. Allow-list and TTLs live in the script.
[[ -x "$HYDRA_ROOT/scripts/tmp-reaper.sh" ]] \
  || fail "$HYDRA_ROOT/scripts/tmp-reaper.sh missing or not executable"

cat > /etc/systemd/system/hydra-tmp-reaper.service << TMPREAPERSVC
[Unit]
Description=Reap idle /tmp scratch (review clones, qa-pr-*, tmp.XXXXXX) with no open handles

[Service]
Type=oneshot
ExecStart=$HYDRA_ROOT/scripts/tmp-reaper.sh
Environment=HOME=/root
Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
# lsof +D over multi-GB clones is slow; headroom over the 90s oneshot default.
TimeoutStartSec=30min
StandardOutput=append:/var/log/hydra-tmp-reaper.log
StandardError=append:/var/log/hydra-tmp-reaper.log
TMPREAPERSVC

cat > /etc/systemd/system/hydra-tmp-reaper.timer << TMPREAPERTMR
[Unit]
Description=Run the /tmp scratch reaper hourly

[Timer]
OnCalendar=hourly
Persistent=true
RandomizedDelaySec=5min
Unit=hydra-tmp-reaper.service

[Install]
WantedBy=timers.target
TMPREAPERTMR

systemctl daemon-reload

trtmr=hydra-tmp-reaper.timer
systemctl enable "$trtmr" >/dev/null 2>&1 || fail "could not enable $trtmr"
systemctl start "$trtmr" >/dev/null 2>&1 || fail "could not start $trtmr"
trstate="$(systemctl is-active "$trtmr" 2>/dev/null || true)"
[[ "$trstate" == "active" ]] || fail "$trtmr is not active (state: ${trstate:-unknown})"
log "  $trtmr: $trstate (fires hourly)"

# ─── Main gateway session prune + restart (nightly 02:30 UTC) ────
# MUS-1295: see scripts/main-prune-restart.sh. Replaces the hand-placed bridge (/usr/local/sbin/
# hydra-main-{prune-restart,nightly-reset}.sh via the TRANSIENT hydra-main-nightly-reset.timer). Both fire at
# 02:30 UTC, so the bridge is retired BEFORE the managed timer is armed: no double prune+restart.
[[ -x "$HYDRA_ROOT/scripts/main-prune-restart.sh" ]] \
  || fail "$HYDRA_ROOT/scripts/main-prune-restart.sh missing or not executable"

# Never kill a legacy prune/restart mid-flight (it has stopped main and has no exit trap): stop only the TIMER,
# wait for any running legacy service/script, and if it never finishes fail the install with nothing removed
# or armed, so the next deploy retries.
AUX_BRIDGE_WAIT_SECS="${AUX_BRIDGE_WAIT_SECS:-900}"
legacy_bridge_running() {
  [[ "$(systemctl is-active hydra-main-nightly-reset.service 2>/dev/null || true)" =~ ^(active|activating|deactivating)$ ]] \
    || pgrep -f '/usr/local/sbin/hydra-main-(prune-restart|nightly-reset)\.sh' >/dev/null 2>&1
}
retire_main_prune_bridge() {
  local f waited=0
  systemctl stop hydra-main-nightly-reset.timer >/dev/null 2>&1 || true
  while legacy_bridge_running; do
    if (( waited >= AUX_BRIDGE_WAIT_SECS )); then
      fail "legacy main prune/restart bridge still running after ${AUX_BRIDGE_WAIT_SECS}s; refusing to kill it mid-flight (main may be stopped). Re-run install-aux-units.sh once it finishes."
    fi
    (( waited == 0 )) && log "  legacy main prune/restart bridge is running; waiting for it to finish (max ${AUX_BRIDGE_WAIT_SECS}s)"
    sleep 5; waited=$((waited + 5))
  done
  systemctl reset-failed hydra-main-nightly-reset.timer hydra-main-nightly-reset.service >/dev/null 2>&1 || true
  for f in /usr/local/sbin/hydra-main-prune-restart.sh /usr/local/sbin/hydra-main-nightly-reset.sh; do
    if [[ -e "$f" ]]; then rm -f "$f"; log "  retired hand-placed bridge: $f"; fi
  done
  rm -f /usr/local/sbin/hydra-main-nightly-reset.sh.bak-*
}
retire_main_prune_bridge

cat > /etc/systemd/system/hydra-main-prune-restart.service << MAINPRUNESVC
[Unit]
Description=Prune main-gateway sessions idle >24h offline, then restart openclaw-gateway-main

[Service]
Type=oneshot
ExecStart=$HYDRA_ROOT/scripts/main-prune-restart.sh nightly
Environment=HOME=/root
Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
Environment=HYDRA_MAIN_PRUNE_AFTER=24h
# Skip when main restarted recently (already fresh).
Environment=HYDRA_MAIN_MIN_UPTIME_H=4
Environment=MAINT_SH=$HYDRA_ROOT/scripts/hydra-maintenance.sh
# Backup + stop + prune (<=20 min) + start + health wait (<=45 min); a kill mid-run would leave main stopped.
TimeoutStartSec=90min
# No Restart=: a failed run must never re-run itself (never loops).
StandardOutput=append:/var/log/hydra-main-prune-restart.log
StandardError=append:/var/log/hydra-main-prune-restart.log
MAINPRUNESVC

cat > /etc/systemd/system/hydra-main-prune-restart.timer << MAINPRUNETMR
[Unit]
Description=Prune main-gateway sessions and restart main nightly at 02:30 UTC

[Timer]
OnCalendar=*-*-* 02:30:00 UTC
# No Persistent=: a missed night must not become a boot-time restart.
Unit=hydra-main-prune-restart.service

[Install]
WantedBy=timers.target
MAINPRUNETMR

systemctl daemon-reload

mpt=hydra-main-prune-restart.timer
systemctl enable "$mpt" >/dev/null 2>&1 || fail "could not enable $mpt"
systemctl start "$mpt" >/dev/null 2>&1 || fail "could not start $mpt"
mpstate="$(systemctl is-active "$mpt" 2>/dev/null || true)"
[[ "$mpstate" == "active" ]] || fail "$mpt is not active (state: ${mpstate:-unknown})"
log "  $mpt: $mpstate (fires nightly 02:30 UTC)"

# ─── codex-home retention (daily 05:45 UTC) ──────────────────────
# The codex binary writes sessions/**/rollout-*.jsonl and logs_*.sqlite under
# every agent's codex-home and has no retention knob (72 GiB across 35 agents
# on 8 Oct, MUS-5584). scripts/codex-home-prune.sh deletes rollout files and
# log rows older than CODEX_SESSION_TTL_DAYS (default 14); VACUUM only below
# 80% disk. One global unit: the glob spans every profile.
[[ -x "$HYDRA_ROOT/scripts/codex-home-prune.sh" ]] \
  || fail "$HYDRA_ROOT/scripts/codex-home-prune.sh missing or not executable"

cat > /etc/systemd/system/hydra-codex-home-prune.service << CHPRUNESVC
[Unit]
Description=Prune codex-home session files and log rows older than the retention window

[Service]
Type=oneshot
ExecStart=$HYDRA_ROOT/scripts/codex-home-prune.sh --apply
Environment=HOME=/root
Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
Nice=10
IOSchedulingClass=idle
# ~60k file deletes plus 35 sqlite DELETE/checkpoint passes on the first run.
TimeoutStartSec=30min
StandardOutput=append:/var/log/hydra-codex-home-prune.log
StandardError=append:/var/log/hydra-codex-home-prune.log
CHPRUNESVC

cat > /etc/systemd/system/hydra-codex-home-prune.timer << CHPRUNETMR
[Unit]
Description=Run the codex-home prune daily at 05:45 UTC

[Timer]
OnCalendar=*-*-* 05:45:00 UTC
Persistent=true
RandomizedDelaySec=10min
Unit=hydra-codex-home-prune.service

[Install]
WantedBy=timers.target
CHPRUNETMR

systemctl daemon-reload

chptmr=hydra-codex-home-prune.timer
systemctl enable "$chptmr" >/dev/null 2>&1 || fail "could not enable $chptmr"
systemctl start "$chptmr" >/dev/null 2>&1 || fail "could not start $chptmr"
chpstate="$(systemctl is-active "$chptmr" 2>/dev/null || true)"
[[ "$chpstate" == "active" ]] || fail "$chptmr is not active (state: ${chpstate:-unknown})"
log "  $chptmr: $chpstate (fires daily 05:45 UTC)"

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
#
# openclaw >= 2026.8: do NOT install this timer. Native in-process auto-refresh
# is the sole refresher there (see scripts/lib/codex-oauth-refresh.sh's own
# >= 2026.8 --break-glass gate) — a second, out-of-band refresher racing it
# reproduces the 2026-06-08 refresh_token_reused incident. If this unit
# survives from a prior 7.x-era install, actively tear it down instead.
if [ "$AUX_RUNTIME_IS_2026_8_PLUS" -eq 0 ]; then
  cat > /etc/systemd/system/codex-token-refresh.service << CODEXREFRESHSVC
[Unit]
Description=HYDRA codex OAuth token refresh (+ gateway reload)

[Service]
Type=oneshot
# The gateways restart serially. Each can spend 35s timing out a safe request,
# 390s draining, 180s in systemd's stop/start budgets, then 30s confirming the
# hard fallback. Thirty minutes leaves margin for OAuth refresh/sync as well.
TimeoutStartSec=1800
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
else
  # CORRECTION (2026-09-11): this branch used to claim native in-process
  # auto-refresh is the sole refresher on >= 2026.8. That is FALSE on this box.
  # The bundled `openai` plugin owns the refresh-on-use machinery and hydra
  # keeps it DISABLED to dodge #90925; a disabled plugin still OWNS provider
  # `openai`, so the refresh path resolves to `configured-unavailable` and
  # throws before any builtin fallback. Measured 2026-09-11: no ENABLED plugin
  # owns provider openai, codex declares providers=[], no codex timer armed,
  # and the earliest access token expired 2026-09-20T12:56:09Z. Retiring the
  # old timer on that premise left the fleet with NO refresher for 24h.
  # codex-canonical-refresh.timer below restores the contract against 2.0's
  # SQLite cell. The OLD unit stays off: it targets the pre-8.1 JSON store,
  # which doctor archived.
  log "  codex-token-refresh.timer: NOT installed — runtime ${AUX_RUNTIME_VER} >= 2026.8 (it targets the pre-8.1 JSON store, which no longer exists); superseded by codex-canonical-refresh.timer"
  ensure_superseded_timer_off codex-token-refresh.timer "runtime ${AUX_RUNTIME_VER} >= 2026.8: it refreshes the pre-8.1 JSON store that doctor archived; codex-canonical-refresh.timer refreshes the SQLite cell instead"

  [[ -x "$HYDRA_ROOT/scripts/codex-canonical-refresh.sh" ]] \
    || fail "$HYDRA_ROOT/scripts/codex-canonical-refresh.sh missing or not executable"

  cat > /etc/systemd/system/codex-canonical-refresh.service << CANONREFRESHSVC
[Unit]
Description=HYDRA codex OAuth canonical refresh (2.0 SQLite cell) + conditional drain restart

[Service]
Type=oneshot
# Same budget as the retired codex-token-refresh.service: the gateways restart
# serially and each can spend 35s on a safe-restart request, 390s draining,
# 180s in systemd's stop/start budgets and 30s confirming the hard fallback.
TimeoutStartSec=1800
ExecStart=$HYDRA_ROOT/scripts/codex-canonical-refresh.sh
Environment=HOME=/root
Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
StandardOutput=append:/var/log/codex-canonical-refresh.log
StandardError=append:/var/log/codex-canonical-refresh.log
CANONREFRESHSVC

  cat > /etc/systemd/system/codex-canonical-refresh.timer << CANONREFRESHTMR
[Unit]
Description=Refresh the HYDRA codex OAuth chain twice weekly (Sun+Wed 04:00 UTC)

[Timer]
# Sun+Wed matches the retired timer. Access tokens live 10 days (measured: JWT
# iat->exp = 864000s), so twice weekly gives ~3 attempts before an expiry while
# halving the restart count versus daily. 04:00 UTC is the night-side minimum
# of the 7-day Intercom dispatch histogram (04Z = 5 dispatches; 01Z/06Z = 30).
OnCalendar=Sun,Wed *-*-* 04:00:00 UTC
# If the box was down at the scheduled time, fire on next boot rather than skip
# and risk a lapse (same tradeoff as the retired unit).
Persistent=true
RandomizedDelaySec=10min
Unit=codex-canonical-refresh.service

[Install]
WantedBy=timers.target
CANONREFRESHTMR

  systemctl daemon-reload

  ctmr=codex-canonical-refresh.timer
  systemctl enable "$ctmr" >/dev/null 2>&1 || log "WARN: could not enable $ctmr"
  systemctl start "$ctmr" >/dev/null 2>&1 || log "WARN: could not start $ctmr"
  cstate=$(systemctl is-active "$ctmr" 2>/dev/null || echo unknown)
  log "  $ctmr: $cstate (fires Sun+Wed 04:00 UTC; refresh + restart only if something rotated)"

  # ─── codex edge auth-cell mirror (timer, >= 2026.8 only) ───
  # On 2.0 each PROFILE reads its own shared auth cell and edge's came out of
  # the 2026-09-10 migration EMPTY (Caroline on paid openrouter). The mirror
  # copies main's per-account ACCESS credentials into edge's cell with a
  # sentinel refresh slot — never a refresh token (single-refresher
  # invariant). Primary path is openclaw-pre-start-heal.sh edge (every edge
  # start re-mirrors); this daily tick is the belt for a missed pre-start.
  # 04:30 UTC = 30 min AFTER the Sun+Wed 04:00 canonical refresher, so a
  # freshly rotated access token is mirrored the same morning. It restarts
  # edge ONLY when it actually changed the cell (drain-aware, same helper as
  # deploy.sh), and stands down inside a maintenance window.
  [[ -x "$HYDRA_ROOT/scripts/lib/codex-edge-mirror.sh" ]] \
    || fail "$HYDRA_ROOT/scripts/lib/codex-edge-mirror.sh missing or not executable"
  # AUX_SYSTEMD_UNIT_DIR: test seam so scripts/tests/install-aux-units-codex-mirror.bats
  # can assert the GENERATED units; production always writes /etc/systemd/system.
  AUX_UNIT_DIR="${AUX_SYSTEMD_UNIT_DIR:-/etc/systemd/system}"

  # Failures that never reach the script's own pager (ExecStart missing, killed
  # by TimeoutStartSec, node absent) page through the OnFailure template unit.
  [[ -x "$HYDRA_ROOT/scripts/notify-unit-failed.sh" ]] \
    || fail "$HYDRA_ROOT/scripts/notify-unit-failed.sh missing or not executable"
  cat > "$AUX_UNIT_DIR"/hydra-unit-failed@.service << UNITFAILEDSVC
[Unit]
Description=HYDRA page #clio_devops that unit %i failed (OnFailure= target)

[Service]
Type=oneshot
TimeoutStartSec=60
ExecStart=$HYDRA_ROOT/scripts/notify-unit-failed.sh %i
Environment=HOME=/root
Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
UNITFAILEDSVC

  cat > "$AUX_UNIT_DIR"/codex-edge-mirror.service << EDGEMIRRORSVC
[Unit]
Description=HYDRA codex auth-cell mirror main→edge (2.0 SQLite cell) + conditional drain restart
OnFailure=hydra-unit-failed@%n.service

[Service]
Type=oneshot
# The edge gateway restart (only when the cell changed) can spend 35s on a
# safe-restart request, 390s draining, 180s in systemd's stop/start budgets
# and 30s confirming the hard fallback; the mirror itself is sub-second.
TimeoutStartSec=900
ExecStart=$HYDRA_ROOT/scripts/lib/codex-edge-mirror.sh --restart
Environment=HOME=/root
Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
StandardOutput=append:/var/log/codex-edge-mirror.log
StandardError=append:/var/log/codex-edge-mirror.log
EDGEMIRRORSVC

  cat > "$AUX_UNIT_DIR"/codex-edge-mirror.timer << EDGEMIRRORTMR
[Unit]
Description=Mirror main's codex auth cell into edge daily (04:30 UTC, after the 04:00 refresher)

[Timer]
OnCalendar=*-*-* 04:30:00 UTC
# A missed tick (box down) fires on next boot rather than skipping a day.
Persistent=true
RandomizedDelaySec=5min
Unit=codex-edge-mirror.service

[Install]
WantedBy=timers.target
EDGEMIRRORTMR

  systemctl daemon-reload

  mtmr=codex-edge-mirror.timer
  systemctl enable "$mtmr" >/dev/null 2>&1 || log "WARN: could not enable $mtmr"
  systemctl start "$mtmr" >/dev/null 2>&1 || log "WARN: could not start $mtmr"
  mstate=$(systemctl is-active "$mtmr" 2>/dev/null || echo unknown)
  log "  $mtmr: $mstate (fires daily 04:30 UTC; restarts edge only if the cell changed)"
fi

# ─── company-finder dedupe-cache refresh (timer) ──────────────
# Precompute the ~50s NocoDB dedup snapshot out-of-band so prep-batch.sh
# (dedupe-candidates.sh) reads it in <1s and finishes inside Scout's codex 10s
# exec cell. Correctness is unchanged — ledger.sh suggest (finalize-batch)
# re-checks all three sources LIVE, so a stale cache can only trigger a
# LEDGER_COLLISION re-run, never a duplicate post.
install -d -m 755 /var/lib/hydra-company-finder

cat > /etc/systemd/system/hydra-company-finder-cache-refresh.service << CFCACHESVC
[Unit]
Description=HYDRA company-finder dedupe-cache refresh (NocoDB 3-source snapshot)

[Service]
Type=oneshot
TimeoutStartSec=300
# muso NocoDB auth lives in the gateway env files (the canonical env source).
ExecStart=/usr/bin/bash -lc 'set -a; . /etc/openclaw/shared.env; . /etc/openclaw/main.env; set +a; exec $HYDRA_ROOT/scripts/company-finder/refresh-dedupe-cache.sh'
Environment=HOME=/root
Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
StandardOutput=append:/var/log/company-finder-cache-refresh.log
StandardError=append:/var/log/company-finder-cache-refresh.log
CFCACHESVC

cat > /etc/systemd/system/hydra-company-finder-cache-refresh.timer << CFCACHETMR
[Unit]
Description=Refresh the HYDRA company-finder dedupe cache every 15 minutes

[Timer]
OnCalendar=*:0/15
Persistent=true
RandomizedDelaySec=90
Unit=hydra-company-finder-cache-refresh.service

[Install]
WantedBy=timers.target
CFCACHETMR

systemctl daemon-reload

cftmr=hydra-company-finder-cache-refresh.timer
systemctl enable "$cftmr" >/dev/null 2>&1 || log "WARN: could not enable $cftmr"
systemctl start "$cftmr" >/dev/null 2>&1 || log "WARN: could not start $cftmr"
cfstate=$(systemctl is-active "$cftmr" 2>/dev/null || echo unknown)
log "  $cftmr: $cfstate (fires every 15 min)"
# Warm the cache now (non-blocking) so the first prep-batch after a deploy is fast.
systemctl start --no-block hydra-company-finder-cache-refresh.service >/dev/null 2>&1 \
  || log "WARN: could not warm company-finder dedupe cache"

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
/var/log/*-watchdog.log /var/log/codex-keepalive.log /var/log/codex-quota-refresh.log /var/log/codex-token-refresh.log /var/log/company-finder-cache-refresh.log /var/log/hydra-daily-audit.log /var/log/hydra-weekly-cleanup.log /var/log/hydra-jev-shadow-prune.log /var/log/hydra-tmp-reaper.log /var/log/hydra-main-prune-restart.log /var/log/qa-review-reconcile.log /var/log/qa-approval-retry.log /var/log/agent-soul-delivery-guard.log {
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

# -------------------------------------------------------------------
# CTO push-audit guard (PR #582 / QA finding)
# -------------------------------------------------------------------
# Arm a directory-scoped pre-push hook so every clone under
# /opt/hydra/workspaces/repos/ refuses a push that lacks a recent CTO audit
# row — independent of which skill (cto-codex-coding / fix / ship) created the
# clone or runs the push. Installing it HERE (out-of-band, at deploy time, as
# root with HOME=/root) is what makes it airtight: a per-clone install inside
# cto-codex-coding can't cover a clone the bypassed standalone fix/ship path
# never armed. Idempotent; runs every deploy. Fails open (push just stays
# unguarded) if misconfigured — never blocks a deploy.
if [[ -x "$HYDRA_ROOT/scripts/lib/setup-cto-clone-hooks.sh" ]]; then
  if CTO_GUARD_SRC="$HYDRA_ROOT/scripts/lib/cto-push-audit-guard.sh" \
     CTO_HOOKS_DIR="$HYDRA_ROOT/scripts/lib/cto-git-hooks" \
     CTO_HOOKS_GITCONFIG="$HYDRA_ROOT/.cto-clone-hooks.gitconfig" \
     "$HYDRA_ROOT/scripts/lib/setup-cto-clone-hooks.sh" >/dev/null; then
    log "  CTO clone push-audit guard armed (directory-scoped pre-push hooksPath)"
  else
    log "  WARN: setup-cto-clone-hooks.sh failed — CTO push-audit guard may not be active"
  fi
fi

# ─── QA auto-review reconciler, every 15 min ───────────────────
# Recovers reviews the one-shot-cron dispatch lane silently loses: a
# dispatch arms a one-shot openclaw cron to run qa-dispatch-pr-review.sh; a
# gateway restart between arm and fire kills it; openclaw never re-arms a
# past-due one-shot; a later sweep deletes the never-fired row with no
# trace. Confirmed real losses: muso-skills#2 (18h) and
# core-backend#9243 (15 days). A systemd timer (not another openclaw cron)
# is deliberately load-bearing here — it must survive exactly the failure
# mode it's reconciling (a gateway restart), so it cannot itself be gateway
# state. See scripts/qa-review-reconcile.sh's header for the full
# mechanism-decision rationale and env knobs.
cat > /etc/systemd/system/qa-review-reconcile.service << QARECONCILESVC
[Unit]
Description=QA auto-review reconciler (recovers PRs the one-shot-cron dispatch lane lost)
After=network-online.target

[Service]
Type=oneshot
# 17 gh pr list calls plus a commits/<sha> lookup per in-scope PR, plus two
# more calls per in-scope PR — real --dry-run ticks against the live org ran
# minutes, not seconds. Without this the default DefaultTimeoutStartSec=90s
# SIGTERMs the tick before its single end-of-run state write, discarding
# every attempts/last_attempt_epoch recorded that tick (state is written
# ONCE, after all repo loops complete) — the cooldown never engages and the
# same candidates re-dispatch every 15 minutes forever.
TimeoutStartSec=1800
ExecStart=$HYDRA_ROOT/scripts/qa-review-reconcile.sh
Environment=HOME=/root
Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
StandardOutput=append:/var/log/qa-review-reconcile.log
StandardError=append:/var/log/qa-review-reconcile.log
QARECONCILESVC

cat > /etc/systemd/system/qa-review-reconcile.timer << QARECONCILETMR
[Unit]
Description=Every 15 min — reconcile lost QA auto-review dispatches

[Timer]
OnBootSec=10min
OnUnitActiveSec=15min
RandomizedDelaySec=60s
Unit=qa-review-reconcile.service

[Install]
WantedBy=timers.target
QARECONCILETMR

systemctl daemon-reload

qarc=qa-review-reconcile.timer
systemctl enable "$qarc" >/dev/null 2>&1 || log "WARN: could not enable $qarc"
systemctl start "$qarc" >/dev/null 2>&1 || log "WARN: could not start $qarc"
log "  $qarc: $(systemctl is-active "$qarc" 2>/dev/null || echo unknown)"

# ─── /tmp age policy keyed on mtime (/etc/tmpfiles.d/tmp.conf) ─────
# --- BEGIN tmpfiles-age-by-mtime ---
# Installed VERBATIM from scripts/aux-units/tmp.conf (no substitutions, so
# the template is the source of truth, unlike the heredoc units above).
# WHY (2026-08-11 -> 2026-08-26, node-8 disk pressure): systemd-tmpfiles ages
# an entry by newest-of(atime,btime,ctime,mtime); / is relatime and a nightly
# ~19:15Z read-walk of /tmp refreshed atime on every entry, so the stock `D
# /tmp ... 30d` (and a hand-tightened 7d) matured 0 entries while /tmp grew
# to ~200 GB. The `mM:` age-by prefix restricts the test to mtime. This was a
# hand-edit on node-8 until 2026-09-05; codified so a rebuild keeps it.
#
# Invariant guard: the source MUST carry the mM: prefix. Regressing to a
# plain age silently re-creates the 0-bytes-reclaimed failure while looking
# correctly configured, so the installer refuses to ship it.
#
# `systemd-tmpfiles --create <file>` parse-validates the installed file (it
# creates missing dirs from D lines, never removes anything). On a parse
# failure the previous file is restored (or the new one removed, which
# un-masks the stock 30d policy) and the installer fails loudly.
# TMPFILES_D is overridable ONLY so tests can run this block against a temp
# dir; production always uses /etc/tmpfiles.d.
TMPFILES_D="${TMPFILES_D:-/etc/tmpfiles.d}"
tmpconf_src="$HYDRA_ROOT/scripts/aux-units/tmp.conf"
tmpconf_dst="$TMPFILES_D/tmp.conf"
[[ -f "$tmpconf_src" ]] || fail "$tmpconf_src missing (tmpfiles /tmp age policy)"
grep -Eq '^D /tmp 1777 root root mM:[0-9]+[smhdw]?$' "$tmpconf_src" \
  || fail "$tmpconf_src must declare 'D /tmp 1777 root root mM:<age>' (mtime-keyed age; see block comment)"
mkdir -p "$TMPFILES_D"
if cmp -s "$tmpconf_src" "$tmpconf_dst"; then
  log "  tmpfiles tmp.conf: up to date ($(grep '^D /tmp' "$tmpconf_dst"))"
else
  tmpconf_prev=""
  if [[ -f "$tmpconf_dst" ]]; then
    tmpconf_prev="$(mktemp)"
    cp -p "$tmpconf_dst" "$tmpconf_prev"
    # Keep the FIRST pre-managed copy for the rollback documented in the
    # template; later re-installs never overwrite it. tmpfiles.d only reads
    # *.conf, so the sidecar is inert.
    [[ -f "$tmpconf_dst.pre-managed" ]] || cp -p "$tmpconf_dst" "$tmpconf_dst.pre-managed"
  fi
  install -m 644 "$tmpconf_src" "$tmpconf_dst"
  if systemd-tmpfiles --create "$tmpconf_dst"; then
    log "  tmpfiles tmp.conf: installed ($(grep '^D /tmp' "$tmpconf_dst"))"
  else
    if [[ -n "$tmpconf_prev" ]]; then
      install -m 644 "$tmpconf_prev" "$tmpconf_dst"
      log "  tmpfiles tmp.conf: parse FAILED, previous file restored"
    else
      rm -f "$tmpconf_dst"
      log "  tmpfiles tmp.conf: parse FAILED, new file removed (stock policy un-masked)"
    fi
    if [[ -n "$tmpconf_prev" ]]; then rm -f "$tmpconf_prev"; fi
    fail "systemd-tmpfiles rejected $tmpconf_src"
  fi
  if [[ -n "$tmpconf_prev" ]]; then rm -f "$tmpconf_prev"; fi
fi
# --- END tmpfiles-age-by-mtime ---

# ─── QA approval retry, every 10 min ───────────────────────────────
# Sibling of the reconciler above, for the OTHER half of the bot. The
# reconciler recovers a review that never happened; this recovers an APPROVAL
# that was withheld and never re-asked. The dispatch producer fires on
# `pull_request` (push time, parallel with CI), so the review routinely lands
# while checks are still running; Guard 8 of qa-pr-approve.sh correctly
# refuses on PENDING, the skill is told not to retry, and nothing ever asks
# again. Measured: Mariia's 12 most recent web-credits-next PRs carried a GO
# verdict and ZERO approvals despite her scoped grant being live since
# 2026-08-13. See scripts/qa-approval-retry.sh's header.
#
# 10 min (vs the reconciler's 15) because this rides out a CI window rather
# than a lost dispatch — the sooner it re-asks after checks go green, the
# smaller the gap between "mergeable" and "marked mergeable".
cat > /etc/systemd/system/qa-approval-retry.service << QAAPPROVERETRYSVC
[Unit]
Description=QA approval retry (re-asks for approvals withheld while CI was still pending)
After=network-online.target

[Service]
Type=oneshot
# NOTE: no backticks below — this heredoc is UNQUOTED so that \$HYDRA_ROOT
# expands, which also makes backticks command-substitute AS ROOT at install
# time (pr(1) is real coreutils, so 'pr list' actually ran and silently ate
# the words from this comment).
# One "pr list" per allowlisted repo plus a reviews read per open PR, against
# the live org — the same order of magnitude as the reconciler, which measured
# in minutes. systemd's DefaultTimeoutStartSec=90s would SIGTERM the tick
# mid-sweep; this script holds no state, so a truncated tick loses only the
# remaining repos (not accumulated counters), but a partial sweep still means
# some PRs are never re-asked that tick.
TimeoutStartSec=1800
ExecStart=$HYDRA_ROOT/scripts/qa-approval-retry.sh
Environment=HOME=/root
Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
StandardOutput=append:/var/log/qa-approval-retry.log
StandardError=append:/var/log/qa-approval-retry.log
QAAPPROVERETRYSVC

cat > /etc/systemd/system/qa-approval-retry.timer << QAAPPROVERETRYTMR
[Unit]
Description=Every 10 min — re-ask for QA approvals withheld by the CI race

[Timer]
OnBootSec=12min
OnUnitActiveSec=10min
RandomizedDelaySec=60s
Unit=qa-approval-retry.service

[Install]
WantedBy=timers.target
QAAPPROVERETRYTMR

systemctl daemon-reload

qart=qa-approval-retry.timer
systemctl enable "$qart" >/dev/null 2>&1 || log "WARN: could not enable $qart"
systemctl start "$qart" >/dev/null 2>&1 || log "WARN: could not start $qart"
log "  $qart: $(systemctl is-active "$qart" 2>/dev/null || echo unknown)"

# ─── OnFailure paging for every timer-driven oneshot ──────────────────────────
# hydra-unit-failed@.service (written above) is the generic pager for a failing
# oneshot: without it a failed timer run is only a red line in
# `systemctl --failed` that nobody reads. Until now exactly ONE unit referenced
# it (codex-edge-mirror.service), which is why five units failed unnoticed for
# 6-9 days: hydra-release-watch since 2026-09-07 (every 5 min),
# hydra-session-thread-retention@{main,edge} and cs-selfserve-backlog-collect
# since the 2.0 cutover, and clickup-sla-digest daily.
#
# A TABLE, not a glob over /etc/systemd/system: that directory also holds units
# this script never wrote (system units, other installers), and silently
# attaching our pager to those is not ours to do. Adding a unit here is one row,
# the same shape as scripts/lib/release-repos.sh.
#
# SAFE TO WIRE ONLY BECAUSE notify-unit-failed.sh NOW HAS A PER-UNIT COOLDOWN
# (24h default). Wiring hydra-release-watch without it would page ~288x/day,
# the alert-storm failure mode this repo has already lived through once.
# Do not widen this table without checking that cooldown is still in place.
#
# hydra-unit-failed@.service is deliberately absent: pointing the pager's
# OnFailure= at itself is an infinite loop.
AUX_ONFAILURE_UNITS=(
  caroline-behavior-digest.service
  clickup-sla-digest.service
  clickup-todo-dedupe.service
  close-duplicate-conversations.service
  close-merged-tickets.service
  close-resolved-conversations.service
  codex-canonical-refresh.service
  codex-token-refresh.service
  cs-needs-human-digest-delta.service
  cs-needs-human-digest.service
  cs-selfserve-backlog-collect.service
  cs-selfserve-backlog.service
  cs-sla-report.service
  cto-nightly-driver.service
  hydra-company-finder-cache-refresh.service
  hydra-codex-home-prune.service
  hydra-daily-audit.service
  hydra-jev-shadow-prune.service
  hydra-main-prune-restart.service
  hydra-peer-labels.service
  hydra-release-watch.service
  hydra-release.service
  hydra-tmp-reaper.service
  hydra-session-thread-retention@.service
  hydra-weekly-cleanup.service
  intercom-intake-watchdog.service
  intercom-rights-holder-watchdog.service
  overdue-verification-notifier.service
  qa-approval-retry.service
  qa-review-reconcile.service
  resolution-matcher.service
  resolve-notify.service
  support-changelog-sync.service
  sync-app-pricing.service
  sync-platform-llms.service
)

# wire_unit_failure_paging — idempotent: inserts OnFailure= into the [Unit]
# section of each table entry that does not already carry one. Runs LAST so it
# sees the final bytes of every unit this script wrote.
#
# `%n` is the full unit name, so for the ONE template in the table it expands
# to e.g. hydra-session-thread-retention@main.service and the pager receives
# that exact name as %i -- which is what it feeds to journalctl/systemctl.
# `systemd-analyze verify` accepts the template form (rc=0).
wire_unit_failure_paging() {
  local dir="${AUX_SYSTEMD_UNIT_DIR:-/etc/systemd/system}"
  local unit path wired=0 skipped=0 absent=0 present_ours=0 broken=0
  for unit in "${AUX_ONFAILURE_UNITS[@]}"; do
    path="$dir/$unit"
    # A unit gated behind a runtime check may legitimately not be installed.
    if [ ! -f "$path" ]; then absent=$((absent + 1)); continue; fi
    if grep -q '^OnFailure=' "$path"; then
      skipped=$((skipped + 1))
      # Does it carry OUR pager? Then systemd must be holding a definition that
      # includes it — and on a retry after a failed reload, it is not.
      grep -q '^OnFailure=hydra-unit-failed@' "$path" && present_ours=$((present_ours + 1))
      continue
    fi
    if ! grep -q '^\[Unit\]' "$path"; then
      log "WARN: $unit has no [Unit] section — not wiring OnFailure paging"
      broken=$((broken + 1))
      continue
    fi
    # Insert directly after the FIRST [Unit] header: order inside a section
    # does not matter to systemd, and this needs no knowledge of the other
    # keys. awk rather than `sed -i '0,/re/s//../'` because that address form
    # is GNU-only, and rewrite-then-rename so a failure mid-write cannot leave
    # a truncated unit file behind.
    if awk 'BEGIN { done = 0 }
            { print }
            /^\[Unit\]$/ && !done { print "OnFailure=hydra-unit-failed@%n.service"; done = 1 }' \
         "$path" > "$path.hydra-tmp" && [ -s "$path.hydra-tmp" ] \
         && mv -f "$path.hydra-tmp" "$path"; then
      wired=$((wired + 1))
    else
      rm -f "$path.hydra-tmp"
      log "WARN: could not wire OnFailure paging into $unit"
      broken=$((broken + 1))
    fi
  done
  log "  OnFailure paging: wired $wired, already present $skipped, not installed $absent"
  # daemon-reload is what makes the rewritten files LIVE, so its failure cannot
  # be discarded. QA finding on this PR: with an unconditional `return 0` the
  # files gain OnFailure= while systemd keeps the OLD loaded definitions, so
  # every unit this change exists to cover carries a pager on disk and none in
  # reality — the precise silent failure the pager was added to remove.
  #
  # Propagating is enough to be seen: this function is the installer's LAST
  # command and the script has no `set -e`, so its status becomes the script's
  # exit status, and deploy.sh:3034 already turns that into `fail`. A deploy
  # that could not load the new units should stop rather than report success.
  # Reload whenever any managed unit CARRIES the directive — not only when this
  # run wrote it. QA finding on this PR: gating on `wired > 0` makes the fix
  # self-defeating on retry. A failed first reload leaves the FILES mutated and
  # systemd stale; on the next deploy every affected file already has
  # OnFailure=, so wired = 0, the reload is skipped, and the installer returns
  # SUCCESS — permanently. One transient failure would leave every timer-driven
  # unit pagerless forever while each later deploy confirmed success, which is
  # worse than the discarded exit status this replaced: it looks self-healing
  # and never is.
  #
  # daemon-reload is idempotent and this installer already calls it 31 other
  # times, so reloading on every run that manages a pager costs nothing. Do not
  # reintroduce a "skip when unchanged" optimisation here, and do not put one in
  # the shared helper that will route all 32 sites — it propagates this latch.
  local reload_rc=0
  if [ "$((wired + present_ours))" -gt 0 ]; then
    systemctl daemon-reload || reload_rc=$?
    if [ "$reload_rc" -ne 0 ]; then
      log "FATAL: $wired unit(s) newly wired and $present_ours already carrying OnFailure paging, but 'systemctl daemon-reload' exited $reload_rc — systemd is STILL RUNNING THE OLD DEFINITIONS, so those units have no pager despite the files on disk saying they do. The next run will retry the reload."
      return "$reload_rc"
    fi
  fi
  # A per-unit failure must FAIL the run, after the units that did succeed have
  # been written and reloaded. QA finding on this PR: logging WARN and returning
  # 0 means one read-only path or I/O error leaves that unit permanently without
  # the pager while every later deploy reports success — the silent-gap shape
  # this whole change exists to remove, reintroduced one level up. Counted are a
  # failed rewrite and a unit with no [Unit] section; a unit that is simply not
  # installed is legitimate and is NOT counted.
  if [ "$broken" -gt 0 ]; then
    log "FATAL: $broken managed unit(s) could not be given OnFailure paging (see the WARNs above) — those units will fail silently; the units that did succeed are wired and loaded"
    return 1
  fi
  return 0
}

wire_unit_failure_paging
