#!/bin/bash
# ──────────────────────────────────────────────────────────────
# Cron Health Watchdog
#
# Notifies #clio_devops the moment ANY openclaw cron run errors,
# so broken jobs stop rotting silently in cron/runs/*.jsonl. This
# is the missing piece behind the 2026-06 incident where the CMO
# b2b-reply-scanner stacked 17 straight preflight failures over
# ~3 days before anyone noticed (the model-allowlist drift fixed
# in the same PR). OpenClaw records every run outcome to JSONL but
# has no native failure alerting — this watchdog is that layer.
#
# Detection model: scan every cron/runs/<jobId>.jsonl, look at the
# "finished" records (status == ok|error). Alert on EVERY errored
# run we have not alerted on before (per-job high-water mark in a
# state file). One consolidated Slack post per invocation lists all
# new failures. First time a job is ever seen we seed its watermark
# WITHOUT alerting, so installing this never pages for the entire
# historical backlog.
#
# Runs every ~5 min via /etc/cron.d/cron-health-watchdog ON NODE-8
# (installed idempotently by scripts/install-aux-units.sh). Must run
# as root — reads /root/.openclaw-main/cron/ and the devops bot token.
#
# Flags:
#   --dry-run   compute + print the alert block to stdout, do NOT
#               post to Slack. State IS still advanced, so a dry-run
#               is a faithful rehearsal of the dedupe behaviour; point
#               CRON_HEALTH_STATE_FILE at a throwaway path to rehearse
#               without consuming real watermarks.
#
# Env knobs (mainly for tests — defaults target the live main profile):
#   CRON_HEALTH_RUNS_DIR        cron run JSONL dir
#   CRON_HEALTH_JOBS_FILE       cron jobs.json (id -> name/agent map)
#   CRON_HEALTH_STATE_FILE      per-job watermark store
#   CRON_HEALTH_SLACK_CHANNEL   target channel (default #clio_devops)
#   CRON_HEALTH_LOCKFILE        single-run lock
#   CRON_HEALTH_SKIP_HOST_GUARD 1 = skip the ovh-node-8 guard (tests)
# ──────────────────────────────────────────────────────────────
set -euo pipefail

LOGPREFIX="[cron-health-watchdog $(date -u +%Y-%m-%dT%H:%M:%SZ)]"
CRON_RUNS_DIR="${CRON_HEALTH_RUNS_DIR:-/root/.openclaw-main/cron/runs}"
CRON_JOBS_FILE="${CRON_HEALTH_JOBS_FILE:-/root/.openclaw-main/cron/jobs.json}"
# openclaw 2026.6.x moved cron run logs OUT of cron/runs/<job>.jsonl and into the
# SQLite `cron_run_logs` table (its `entry_json` column is the same per-run
# record the JSONL lines held). The on-disk runs dir is FROZEN on 6.x, so
# reading it = blind to every failure. Production reads the DB below; the legacy
# JSONL dir stays as the test-injection + pre-6.x fallback, used only when no DB
# is configured. NOTE: `-` (not `:-`) so tests can force the JSONL path with
# CRON_HEALTH_RUNS_DB="" — an explicitly-empty value must win over this default.
CRON_RUNS_DB="${CRON_HEALTH_RUNS_DB-/root/.openclaw-main/state/openclaw.sqlite}"
CRON_STORE_KEY="${CRON_HEALTH_STORE_KEY:-/root/.openclaw-main/cron/jobs.json}"
STATE_FILE="${CRON_HEALTH_STATE_FILE:-/var/lib/cron-health-watchdog/seen.json}"
LOCKFILE="${CRON_HEALTH_LOCKFILE:-/var/run/cron-health-watchdog.lock}"
SKIP_HOST_GUARD="${CRON_HEALTH_SKIP_HOST_GUARD:-0}"
ERROR_PREVIEW_CHARS=300
# Only page once a job has this many CONSECUTIVE error runs with no intervening
# healthy run. A single error bracketed by ok runs is a recovered/transient blip
# (the openclaw outcome resolver flags a whole run "error" on any recovered tool
# error — e.g. a cron agent that guessed a bad flag, self-corrected, and finished
# fine). The incident this watchdog exists for was a SUSTAINED failure (17 straight
# runs over ~3 days), so a streak threshold catches real breakage while killing the
# recovered-blip false alarms. Set to 1 to restore alert-on-every-error.
MIN_STREAK="${CRON_HEALTH_MIN_STREAK:-2}"
# Restart-interrupt and the openclaw-7.1 cron-session claim race are RETRYABLE
# infra churn (openclaw re-dispatches the run), not job-logic failures — see
# is_transient() below. They are excluded from the MIN_STREAK hard-failure
# streak so a deploy storm stops false-paging. This is the fail-loud backstop:
# a job stuck in transient limbo for this many CONSECUTIVE fires with no
# recovery is a genuine wedge and pages a distinct "stuck" bullet. Default 8 is
# well above a normal heavy-deploy day (the 2026-07-15 storm peaked at ~5), so
# routine churn stays quiet while a permanently wedged session still surfaces.
# NOTE: this is a run COUNT, not wall-clock, so its lead time scales with each
# job's cadence — a deliberately conservative backstop, not a precise SLA.
TRANSIENT_STUCK_STREAK="${CRON_HEALTH_TRANSIENT_STUCK_STREAK:-8}"
DRY_RUN=0

# slack-notify.sh reads this (target channel).
# Export before sourcing so its `:=` default doesn't override us.
export SLACK_CHANNEL="${CRON_HEALTH_SLACK_CHANNEL:-C0ADV2W76G4}"  # #clio_devops

log() { echo "$LOGPREFIX $1"; }

# ──────────────────────────────────────────────────────────────
# Parse flags
# ──────────────────────────────────────────────────────────────
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    *) echo "unknown flag: $arg" >&2; exit 2 ;;
  esac
done

# Locate the sibling Slack helper relative to THIS script so the
# watchdog works from /opt/hydra, a worktree, or a deploy mirror.
_WATCHDOG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/slack-notify.sh
source "$_WATCHDOG_DIR/lib/slack-notify.sh"

# Stand down during a planned maintenance window (scripts/hydra-maintenance.sh):
# stopping the gateways for a window makes their crons error, which would page
# this alarm for the whole window. Fail-safe: an absent/expired/malformed flag
# reads as "not in maintenance".
# shellcheck source=lib/maintenance-flag.sh
source "$_WATCHDOG_DIR/lib/maintenance-flag.sh"
if maintenance_active; then
  echo "$LOGPREFIX maintenance: $(maintenance_reason) - skipping"
  exit 0
fi

command -v python3 >/dev/null 2>&1 || { log "ERROR: python3 required but not on PATH"; exit 2; }

# ──────────────────────────────────────────────────────────────
# Session-budget headroom — catch the wedge BEFORE it eats the cron surface.
#
# The failure below is invisible to scan_failures until it has already happened:
# once an agent's sessions dir crosses session.maintenance.maxDiskBytes,
# openclaw's reaper deletes that agent's cron SESSION entries and every fire
# claim-errors. On 2026-07-27 that killed all 8 `operations` crons for ~25h.
# scan_failures does eventually page ("stuck: N consecutive restart/claim
# failures") but only per-job, only after N fires, and it cannot say WHY.
# This check names the cause and fires on the capacity signal beforehand.
#
# Deliberately rate-limited to one page per SESSION_BUDGET_ALERT_INTERVAL: this
# is a slow-moving capacity signal and the watchdog ticks every 5 minutes, so an
# undeduped page would post ~288 times a day and train everyone to ignore it.
# See scripts/lib/ensure-session-budget-headroom.sh.
# ──────────────────────────────────────────────────────────────
# ──────────────────────────────────────────────────────────────
# Single-run lock — taken HERE, before ANY block that touches shared state
# (the session-budget stamp, the unit-failure spool, the cron-failure
# watermarks and their pages), so one lock guards the whole run. It used to
# be taken only just before scan_failures, which let two overlapping ticks
# interleave on the spool: tick B's startup recovery renamed back the claim
# tick A was mid-delivering, then B claimed and posted the same record while
# A's cleanup found nothing — duplicate Critical pages (QA finding on #935,
# round 13). Dry-run mutates nothing and takes no lock.
# ──────────────────────────────────────────────────────────────
if [ "$DRY_RUN" -eq 0 ]; then
  exec 9>"$LOCKFILE"
  flock -n 9 || { log "SKIP: another cron-health-watchdog run holds $LOCKFILE"; exit 0; }
fi

SESSION_BUDGET_CHECK="${CRON_HEALTH_SESSION_BUDGET_CHECK:-$_WATCHDOG_DIR/lib/ensure-session-budget-headroom.sh}"
SESSION_BUDGET_ALERT_STATE="${CRON_HEALTH_SESSION_BUDGET_STATE:-/var/lib/cron-health-watchdog/session-budget-last-alert}"
SESSION_BUDGET_ALERT_INTERVAL="${CRON_HEALTH_SESSION_BUDGET_INTERVAL:-21600}"  # 6h

if [ -x "$SESSION_BUDGET_CHECK" ]; then
  _sb_out=""; _sb_rc=0
  # `|| _sb_rc=$?` is required: this script runs under `set -e` and the guard
  # exits 1 by design on every finding.
  _sb_out="$("$SESSION_BUDGET_CHECK" --check 2>&1)" || _sb_rc=$?
  if [ "$_sb_rc" -eq 1 ]; then
    _sb_now="$(date -u +%s)"
    _sb_last="$(cat "$SESSION_BUDGET_ALERT_STATE" 2>/dev/null || echo 0)"
    case "$_sb_last" in (*[!0-9]*|"") _sb_last=0 ;; esac
    if [ "$DRY_RUN" -eq 1 ]; then
      log "DRY-RUN: session budget headroom violation (would page ${SLACK_CHANNEL}):"
      printf '%s\n' "$_sb_out"
    elif [ $((_sb_now - _sb_last)) -ge "$SESSION_BUDGET_ALERT_INTERVAL" ]; then
      log "Posting session-budget headroom alert to ${SLACK_CHANNEL}."
      printf '%s\n' "$_sb_out"
      # Name BOTH caps and defer to the finding for which one is binding. Naming
      # only maxDiskBytes here is what misdirected issue #829: main/scout was
      # wedged by the ENTRY reaper while sitting at 17.6% of its disk budget, and
      # the responder followed this text to a lever that changed nothing.
      slack_notify_critical ":warning: *Session budget headroom* — an agent is at/over one of \`session.maintenance\`'s two per-agent caps (\`maxDiskBytes\` or \`maxEntries\`). Either reaper deletes cron session entries and wedges that agent's whole cron surface.\\n\\n\`\`\`$_sb_out\`\`\`\\n\\nFix: raise the cap the finding above actually names — \`maxEntries\` for a protected-entry finding, \`maxDiskBytes\`/\`highWaterBytes\` for a bytes finding; raising the one that is not binding changes nothing. Land it in \`openclaw-main.json\`/\`openclaw-edge.json\`, apply live with \`openclaw --profile <p> config set\`, then RESTART the gateway (the running daemon caches the budget). Never \`openclaw doctor --fix\`."
      mkdir -p "$(dirname "$SESSION_BUDGET_ALERT_STATE")" 2>/dev/null || true
      printf '%s' "$_sb_now" > "$SESSION_BUDGET_ALERT_STATE" 2>/dev/null || true
    else
      log "session budget headroom violation (page suppressed, last $((_sb_now - _sb_last))s ago)"
    fi
  elif [ "$_sb_rc" -eq 2 ]; then
    # Read error, not an all-clear. Log loudly but don't page — an unreachable
    # gateway already pages via the cron-failure path below.
    log "WARN: session budget headroom check could not evaluate: $_sb_out"
  fi
fi

# ──────────────────────────────────────────────────────────────
# Agent exec posture (guardrails-1101 gap 2 / H1): policies/agent-exec-policy.json + the RULES in
# scripts/check-agent-exec-policy.py.
#
# deploy.sh checks the posture twice per deploy (pre-sync repo, post-sync --live), but a deploy can be days apart and
# MOST of the ways this goes wrong are silent: a non-ops agent's dated `full` exception PASSES its expiry date with
# no deploy to notice it, and a hot edit or a hand-reverted live file restores a root shell until someone looks. The
# expiry case is the one that needs a clock rather than a deploy, so this tick is that clock.
#
# Deduped to ONE page per 24h PER FINDING: the watchdog ticks every 5 min, and a posture that nobody has fixed would
# otherwise post 288 times a day and train everyone to ignore the very alert that matters. The stamp carries the
# findings' identity (sha) alongside the timestamp, so an UNCHANGED violation is quiet while a NEW one pages at once,
# and a clean tick clears the stamp so recovery re-arms it.
#
# Nothing here may fail SILENT, which is why the two states a naive version of this block gets wrong both page:
#   - the CHECKER itself is missing (partial sync, moved file, host edit): that is rc=3 and it pages. Absence of the
#     checker is not a reason to skip the alarm, it IS the alarm — the file that catches a restored root shell would
#     then never run again while this tick looked healthy forever;
#   - the page could not be DELIVERED: the dedupe stamp is written ONLY after Slack confirms the post, so a failed
#     delivery retries on the next tick instead of buying 24h of silence with a page nobody received. That is why this
#     uses slack_notify_payload_file_status (real status) and not slack_notify_critical (best-effort, always 0).
# Exit 2 (config or registry unreadable) is likewise NOT a pass and NOT a plain violation — it pages, with its own
# wording, because "cannot evaluate the shell posture" is exactly the state an attacker-supplied config would create.
# CRON_HEALTH_EXEC_POLICY_CHECK="" is the explicit off switch (tests use it); there is no implicit skip.
# See docs/lessons/working-in-hydra.md and AGENTS.md "Agent shell (exec) posture".
# ──────────────────────────────────────────────────────────────
EXEC_POLICY_CHECK="${CRON_HEALTH_EXEC_POLICY_CHECK-$_WATCHDOG_DIR/check-agent-exec-policy.py}"   # `-`, not `:-`: "" must be expressible
EXEC_POLICY_ALERT_STATE="${CRON_HEALTH_EXEC_POLICY_STATE:-/var/lib/cron-health-watchdog/exec-policy-last-alert}"
EXEC_POLICY_ALERT_INTERVAL="${CRON_HEALTH_EXEC_POLICY_INTERVAL:-86400}"  # 24h

if [ -n "$EXEC_POLICY_CHECK" ]; then
  _ep_out=""; _ep_rc=0
  if [ ! -f "$EXEC_POLICY_CHECK" ]; then
    _ep_rc=3
    _ep_out="MISSING CHECKER: ${EXEC_POLICY_CHECK} is not on this host, so this tick cannot evaluate the shell posture"
  else
    _ep_out="$(python3 "$EXEC_POLICY_CHECK" --live 2>&1)" || _ep_rc=$?
  fi
  if [ "$_ep_rc" -ne 0 ]; then
    case "$_ep_rc" in
      (3) _ep_head=":rotating_light: *Agent exec posture: CANNOT EVALUATE (checker MISSING)* — \`scripts/check-agent-exec-policy.py\` is not on node-8 at the path this tick runs. Deploys and this clock are the only things that catch a restored root shell, so a missing checker means the posture has been UNVERIFIED since that file went away. Nothing about that is benign.\n\n\`\`\`$_ep_out\`\`\`\n\nRestore it from the repo (\`ls -l /opt/hydra/scripts/check-agent-exec-policy.py\`) and re-deploy, then run \`python3 /opt/hydra/scripts/check-agent-exec-policy.py --live\` by hand and confirm it is clean. Posture rules: \`AGENTS.md\` §\"Agent shell (exec) posture\"." ;;
      (2) _ep_head=":rotating_light: *Agent exec posture: CANNOT EVALUATE* — \`scripts/check-agent-exec-policy.py --live\` exited 2, meaning a config or the registry could not be read. That is not an all-clear: an unreadable \`openclaw-{main,edge}.json\` is exactly the state a bad edit leaves behind, so the fleet's shell posture is UNKNOWN right now.\n\n\`\`\`$_ep_out\`\`\`\n\nCheck \`/opt/hydra/openclaw-main.json\`, \`/root/.openclaw-main/openclaw.json\` and \`policies/agent-exec-policy.json\` are readable valid JSON, then run \`python3 /opt/hydra/scripts/check-agent-exec-policy.py --live\` by hand." ;;
      (*) _ep_head=":no_entry: *Agent exec posture violated* — \`scripts/check-agent-exec-policy.py --live\` found a node-8 shell posture the repo does not declare, or an exception that has run out. Every main agent with \`tools.exec security=full\` runs as ROOT on node-8, so this is the H1 surface: a prompt-injected Slack thread, fetched page or PR body becomes \`curl ... | sh\`.\n\n\`\`\`$_ep_out\`\`\`\n\nFix the finding it names: \`deny\` the agent (\`tools.deny: [\"exec\",\"process\",\"lobster\",\"nodes\",\"computer\",\"terminal\"]\` in \`openclaw-{main,edge}.json\`, plus its row in \`policies/agent-exec-policy.json\`), or RENEW its dated \`full\` exception with a new ruling. Land it as a PR — CI re-checks the same rules — and never restore a posture on the live file by hand, which is what this check exists to catch. Posture rules: \`AGENTS.md\` §\"Agent shell (exec) posture\"." ;;
    esac
    _ep_now="$(date -u +%s)"
    # Dedupe by FINDING IDENTITY, not only by the clock. The stamp records "<epoch> <sha of the findings that were
    # actually delivered>": the same finding inside the interval stays quiet, but a DIFFERENT one pages immediately.
    # Otherwise one alert at 01:00 buys silence until 01:00 tomorrow for every other posture failure in between — a
    # restored root shell is not "the thing we already told you about". A clean tick clears the stamp outright (see
    # the else branch below), so recovery re-arms the alarm.
    _ep_sig="$(printf '%s\nrc=%s' "$_ep_out" "$_ep_rc" | sha256sum | cut -c1-16)"
    _ep_last=0; _ep_last_sig=""
    if [ -r "$EXEC_POLICY_ALERT_STATE" ]; then read -r _ep_last _ep_last_sig < "$EXEC_POLICY_ALERT_STATE" || true; fi
    case "$_ep_last" in (*[!0-9]*|"") _ep_last=0 ;; esac
    _ep_last_sig="${_ep_last_sig:-}"
    if [ "$DRY_RUN" -eq 1 ]; then
      log "DRY-RUN: agent exec posture rc=${_ep_rc} (would page ${SLACK_CHANNEL}):"
      printf '%s\n' "$_ep_out"
    elif [ $((_ep_now - _ep_last)) -ge "$EXEC_POLICY_ALERT_INTERVAL" ] || [ "$_ep_sig" != "$_ep_last_sig" ]; then
      _ep_send_rc=1; _ep_payload=""
      _ep_payload="$(mktemp 2>/dev/null)" && {
        if jq -n --arg c "$SLACK_CHANNEL" \
             --arg n "<@${SLACK_UID_NICK}> <@${SLACK_UID_AARON}>" \
             --arg h "$_ep_head" \
             '{channel:$c, text:($n + " " + $h)}' > "$_ep_payload" 2>/dev/null; then
          _ep_send_rc=0
          slack_notify_payload_file_status "$_ep_payload" || _ep_send_rc=$?
        else
          log "WARN: could not build the agent exec posture page"
        fi
        rm -f "$_ep_payload"
      }
      if [ "$_ep_send_rc" -eq 0 ]; then
        log "Posted agent exec posture alert to ${SLACK_CHANNEL} (rc=${_ep_rc})."
        printf '%s\n' "$_ep_out"
        mkdir -p "$(dirname "$EXEC_POLICY_ALERT_STATE")" 2>/dev/null || true
        printf '%s %s' "$_ep_now" "$_ep_sig" > "$EXEC_POLICY_ALERT_STATE" 2>/dev/null || true
      else
        # NO STAMP: the next tick tries again. A security page nobody received must never buy silence.
        log "agent exec posture page delivery FAILED (send rc=${_ep_send_rc}, posture rc=${_ep_rc}) — NOT stamped, retried next tick"
        printf '%s\n' "$_ep_out"
      fi
    else
      log "agent exec posture violation UNCHANGED and already paged $((_ep_now - _ep_last))s ago (rc=${_ep_rc}) — suppressed"
    fi
  else
    # CLEAN tick: drop the dedupe stamp, so a posture regression that appears after recovery pages immediately
    # instead of inheriting the previous alert's 24h window.
    if [ -e "$EXEC_POLICY_ALERT_STATE" ]; then
      rm -f "$EXEC_POLICY_ALERT_STATE" 2>/dev/null || true
      log "agent exec posture clean: cleared the dedupe stamp (a later regression pages immediately)"
    fi
  fi
fi

# ──────────────────────────────────────────────────────────────
# Unpaged unit-failure spool (scripts/notify-unit-failed.sh, codex-edge-mirror.sh)
# hydra-unit-failed@.service is the OnFailure= target for timer-driven oneshots
# (codex-edge-mirror.service first) and the mirror pages for itself. When a
# page delivery fails, the producer writes ONE record per file into this spool
# (<unit>.<epoch>.<pid>.unpaged, temp name then rename). A marker nothing
# reads is an unobservable failure, so this tick consumes the spool:
#   - recover: any *.claim.* left by a tick that died mid-delivery is renamed
#     back to its *.unpaged name (atomic, no data copied) before scanning;
#   - claim: every *.unpaged is renamed to *.claim.<pid> BEFORE it is read —
#     a producer never holds an fd on a claimable file (it writes a temp name
#     and renames), so nothing can be appended into a claimed inode;
#   - page CRITICAL once per unit (record count, newest age, last reason)
#     through the STATUS-returning payload path; on confirmed delivery the
#     claims are deleted, otherwise every claim is renamed back and retried
#     next tick. A claim is never dropped unless delivered or provably back.
# ──────────────────────────────────────────────────────────────
UNIT_FAILED_MARKER_DIR="${CRON_HEALTH_UNIT_FAILED_MARKER_DIR:-/var/lib/hydra/unit-failed-unpaged}"

_uf_mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo 0; }
# <unit>.<epoch>.<pid>.unpaged[.claim.<pid>]  →  <unit>
_uf_unit_of() { local n; n="$(basename "$1")"; n="${n%%.unpaged*}"; printf '%s\n' "$n" | sed -E 's/\.[0-9]+\.[0-9]+$//'; }

if [ -d "$UNIT_FAILED_MARKER_DIR" ]; then
  for _uf_orphan in "$UNIT_FAILED_MARKER_DIR"/*.unpaged.claim.*; do
    [ -f "$_uf_orphan" ] || continue
    if [ "$DRY_RUN" -eq 1 ]; then log "DRY-RUN: orphaned unit-failure claim $(basename "$_uf_orphan") — would restore"; continue; fi
    if mv -f "$_uf_orphan" "${_uf_orphan%%.claim.*}" 2>/dev/null; then
      log "restored orphaned unit-failure claim $(basename "$_uf_orphan")"
    else
      log "WARN: could not restore orphaned claim $_uf_orphan — kept for the next tick"
    fi
  done

  # Claim everything present NOW; files spooled after this point belong to
  # the next tick.
  _uf_claims=()
  for _uf_spool in "$UNIT_FAILED_MARKER_DIR"/*.unpaged; do
    [ -f "$_uf_spool" ] || continue
    if [ "$DRY_RUN" -eq 1 ]; then
      log "DRY-RUN: unpaged unit failure $(_uf_unit_of "$_uf_spool") (record $(( $(date -u +%s) - $(_uf_mtime "$_uf_spool") ))s old) — would page ${SLACK_CHANNEL}"
      continue
    fi
    if mv -f "$_uf_spool" "$_uf_spool.claim.$$" 2>/dev/null; then _uf_claims+=("$_uf_spool.claim.$$"); fi   # else: another tick claimed it
  done

  # Group the claims by unit and page once per unit.
  _uf_units="$(for _c in "${_uf_claims[@]+"${_uf_claims[@]}"}"; do _uf_unit_of "$_c"; done | sort -u)"
  for _uf_unit in $_uf_units; do
    _uf_mine=(); _uf_newest=""; _uf_count=0
    for _c in "${_uf_claims[@]}"; do
      [ "$(_uf_unit_of "$_c")" = "$_uf_unit" ] || continue
      _uf_mine+=("$_c"); _uf_count=$((_uf_count + 1))
      if [ -z "$_uf_newest" ] || [ "$(_uf_mtime "$_c")" -ge "$(_uf_mtime "$_uf_newest")" ]; then _uf_newest="$_c"; fi
    done
    _uf_age=$(( $(date -u +%s) - $(_uf_mtime "$_uf_newest") )); [ "$_uf_age" -ge 0 ] || _uf_age=0
    _uf_last="$(cut -f3- "$_uf_newest" 2>/dev/null | head -n1 | tr '`' "'" | cut -c1-300)"
    _uf_rc=1
    _uf_payload="$(mktemp 2>/dev/null)" && {
      if jq -n --arg c "$SLACK_CHANNEL" \
        --arg t ":rotating_light: <@${SLACK_UID_NICK}> <@${SLACK_UID_AARON}> *systemd unit FAILED and its page was NOT delivered* on node-8: \`${_uf_unit}\` — its notifier could not reach Slack (${_uf_count} record(s), newest ${_uf_age}s old; last reason: ${_uf_last:-unknown}). The unit has been failed and unalerted since then. \`systemctl status ${_uf_unit}\`; spool: \`${UNIT_FAILED_MARKER_DIR}\` (records cleared by this watchdog once you see this)." \
        '{channel:$c, text:$t}' > "$_uf_payload" 2>/dev/null; then
        _uf_rc=0; slack_notify_payload_file_status "$_uf_payload" || _uf_rc=$?
      else
        log "WARN: could not build the unit-failure page for ${_uf_unit}"
      fi
      rm -f "$_uf_payload"
    }
    if [ "$_uf_rc" -eq 0 ]; then
      rm -f "${_uf_mine[@]}"
      log "Paged unpaged unit failure ${_uf_unit} (${_uf_count} record(s), newest ${_uf_age}s old) — claimed records cleared."
    else
      _uf_back=0
      for _c in "${_uf_mine[@]}"; do
        if mv -f "$_c" "${_c%%.claim.*}" 2>/dev/null; then _uf_back=$((_uf_back + 1)); else log "WARN: could not restore claim $_c — kept for startup recovery"; fi
      done
      log "unpaged unit failure ${_uf_unit}: page delivery FAILED again (rc=${_uf_rc}) — ${_uf_back}/${_uf_count} record(s) re-queued for the next tick"
    fi
  done
fi

# ──────────────────────────────────────────────────────────────
# scan_failures — the pure detection core.
#   $1 runs_dir  $2 jobs_file  $3 state_file  $4 payload_out  $5 persist(0|1)
# Writes a Slack-ready JSON payload to $payload_out (only if there are
# new failures), advances the per-job watermarks in $state_file (when
# persist=1), and prints the human-readable alert block to stdout.
# Exit 0 always (best-effort); stdout empty == nothing new to report.
# ──────────────────────────────────────────────────────────────
scan_failures() {
  RUNS_DIR="$1" JOBS_FILE="$2" STATE_FILE="$3" PAYLOAD_OUT="$4" PERSIST="$5" \
  RUNS_DB="${RUNS_DB-$CRON_RUNS_DB}" STORE_KEY="${STORE_KEY-$CRON_STORE_KEY}" \
  SLACK_CHANNEL="$SLACK_CHANNEL" PREVIEW="$ERROR_PREVIEW_CHARS" \
  MIN_STREAK="$MIN_STREAK" TRANSIENT_STUCK_STREAK="$TRANSIENT_STUCK_STREAK" \
  python3 - <<'PYEOF'
import json, os, glob, sqlite3
from datetime import datetime, timezone

runs_dir   = os.environ["RUNS_DIR"]
jobs_file  = os.environ["JOBS_FILE"]
state_file = os.environ["STATE_FILE"]
payload_out= os.environ["PAYLOAD_OUT"]
persist    = os.environ.get("PERSIST", "1") == "1"
channel    = os.environ["SLACK_CHANNEL"]
preview    = int(os.environ.get("PREVIEW", "300"))
min_streak = max(1, int(os.environ.get("MIN_STREAK", "2")))
transient_stuck_streak = max(1, int(os.environ.get("TRANSIENT_STUCK_STREAK", "8")))
runs_db    = os.environ.get("RUNS_DB", "").strip()
store_key  = os.environ.get("STORE_KEY", "").strip()

def is_failure(rec):
    """A run is a hard failure only if it errored AND never reached its target.
    A run that errored but still delivered is treated as healthy — it never
    alerts and it breaks a consecutive-error streak. There are TWO delivery
    paths, either of which means the agent got its output out:

      1. openclaw's auto-delivery announced the turn output
         (delivered:true / deliveryStatus 'delivered').
      2. the agent posted to Slack itself via the `message` tool. openclaw
         does NOT credit that as the cron delivery, so the record keeps
         delivered:false / deliveryStatus:'not-delivered'; and under the codex
         runtime a trailing-or-earlier non-fatal tool error (a failed
         `stripe`/`git`/`jq` step) overwrites error/summary and flips the run
         to status:error even though the report was already posted. The tell
         is a non-empty delivery.messageToolSentTo — openclaw records a target
         there ONLY after a successful message-tool send (collectToolTelemetry
         bails on `if (params.isError) return` before populating it), so a
         non-empty array proves a message reached the channel with a receipt.

    Without path 2 every codex cron that self-posts its report
    (e.g. daily-dispute-handler) false-pages: verified 2026-06-08 — the dispute
    report reached #finance_muso (Slack ts 1780934615.350849) while the run
    record read status:error / delivered:false (error string was the earlier
    failed `stripe subscriptions list` step)."""
    if rec.get("status") != "error":
        return False
    if rec.get("delivered") is True or rec.get("deliveryStatus") == "delivered":
        return False
    sent = (rec.get("delivery") or {}).get("messageToolSentTo")
    if isinstance(sent, list) and sent:
        return False
    return True

def is_transient(rec):
    """A RETRYABLE infra condition openclaw itself re-dispatches — NOT a
    job-logic failure. Three signatures, all retryable interruptions openclaw
    re-dispatches (mostly gateway-restart collateral; (2) can also be an
    overlapping same-agent cron with no restart, see below):

      1. 'cron: job interrupted by gateway restart' — a deploy/restart
         hard-killed a run caught BETWEEN turns. openclaw re-runs it
         (wakeMode:now on restart, or the next schedule). Benign (seen since April).
      2. 'CronSessionLifecycleClaimError: Session "…" changed while starting
         work. Retry.' — openclaw 2026.7.1's optimistic-concurrency guard on
         isolated cron session state (run-session-state.ts): a run could not
         claim the session's lifecycle revision because a concurrent writer
         (a gateway restart rehydrating sessions, or an overlapping same-agent
         cron) bumped it. The 'Retry.' is the runtime's own verdict; the run
         drops and recovers on the next fire.
      3. 'AbortError: agent run aborted' — the SAME restart interruption as (1),
         but for a LONG cron caught MID-agent-turn: the gateway drain aborts the
         in-flight run instead of skipping a between-turns one. Observed only
         ~15s before a restart's 'Started' (2026-07-15, scout's web_search job);
         distinct from a genuine 'job execution timed out', which stays visible.

    These are excluded from the MIN_STREAK hard-failure streak so deploy-restart
    churn stops false-paging. They are NOT treated as healthy (that would reset
    a real streak and let an infra blip mask a genuine fault) — they're skipped,
    and a job STUCK in this limbo across TRANSIENT_STUCK_STREAK consecutive
    fires still pages a distinct 'stuck' bullet (the fail-loud backstop)."""
    if rec.get("status") != "error":
        return False
    # Match the ERROR field ONLY — all signatures are runtime-emitted there,
    # never into an agent-authored `summary` (often LLM prose that could
    # coincidentally contain these words → a real job-logic failure would then
    # be silently suppressed). The class name is the robust tell; the full
    # '…Retry.' verdict is a fallback if a future runtime drops the prefix.
    text = str(rec.get("error") or "")
    return ("interrupted by gateway restart" in text
            or "CronSessionLifecycleClaimError" in text
            or "changed while starting work. Retry." in text
            or "agent run aborted" in text)

def load_runs():
    """Return ({job_id: [record, ...]}, source_error_or_None).

    openclaw 2026.6.x persists cron run logs in the SQLite `cron_run_logs`
    table; its `entry_json` column is the SAME per-run record the legacy
    cron/runs/<job>.jsonl lines held, so the detector below is unchanged.
    Production reads the DB. The on-disk JSONL dir is the pre-6.x / unit-test
    fallback, used only when no DB is configured (RUNS_DB empty) or the DB file
    is absent. A DB that exists but has LOST the cron_run_logs table returns a
    source_error so we page (blind) instead of silently reporting OK on a
    frozen/relocated store — the exact silent-rot this watchdog guards against.
    """
    if runs_db and os.path.exists(runs_db):
        try:
            con = sqlite3.connect("file:%s?mode=ro" % runs_db, uri=True)
            try:
                cur = con.cursor()
                if cur.execute("SELECT name FROM sqlite_master "
                               "WHERE type='table' AND name='cron_run_logs'").fetchone() is None:
                    return {}, ("cron_run_logs table missing in %s — openclaw cron-store "
                                "schema changed; this watchdog can no longer read run logs" % runs_db)
                if store_key:
                    rows = cur.execute("SELECT job_id, entry_json FROM cron_run_logs "
                                       "WHERE store_key = ?", (store_key,))
                else:
                    rows = cur.execute("SELECT job_id, entry_json FROM cron_run_logs")
                by_job = {}
                for job_id, entry in rows:
                    if not entry:
                        continue
                    try:
                        rec = json.loads(entry)
                    except Exception:
                        continue  # skip a garbled row, don't abort the scan
                    by_job.setdefault(job_id, []).append(rec)
                return by_job, None
            finally:
                con.close()
        except Exception as e:
            return {}, "cron_run_logs read failed (%s): %s" % (runs_db, e)
    # Legacy / test fallback: per-job JSONL files.
    by_job = {}
    for path in sorted(glob.glob(os.path.join(runs_dir, "*.jsonl"))):
        job_id = os.path.basename(path)[:-len(".jsonl")]
        recs = []
        try:
            with open(path) as f:
                for line in f:
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        recs.append(json.loads(line))
                    except Exception:
                        continue  # skip a half-written/garbled line
        except Exception:
            continue
        if recs:
            by_job[job_id] = recs
    return by_job, None

# job id -> (name, agent)
names = {}
try:
    with open(jobs_file) as f:
        for j in json.load(f).get("jobs", []):
            names[j.get("id")] = (j.get("name", "<unknown>"), j.get("agentId", "<unknown>"))
except Exception:
    pass

# previous per-job high-water marks
try:
    with open(state_file) as f:
        state = json.load(f)
    if not isinstance(state, dict):
        state = {}
except Exception:
    state = {}

new_state = dict(state)

def _persist():
    if not persist:
        return
    d = os.path.dirname(state_file)
    if d:
        os.makedirs(d, exist_ok=True)
    tmp = state_file + ".tmp"
    with open(tmp, "w") as f:
        json.dump(new_state, f, indent=2)
    os.replace(tmp, state_file)

def _emit(text):
    # Build the exact Slack payload in Python — error strings contain quotes,
    # backticks and backslashes (e.g. failed `trino-query.sh \"SELECT ...\"`)
    # that would shatter a naive bash JSON interpolation. slack-notify.sh's
    # slack_notify_payload_file posts this verbatim.
    with open(payload_out, "w") as f:
        json.dump({"channel": channel, "text": text}, f)
    print(text)

runs_by_job, source_error = load_runs()

# Blind guard: the production run-log source (SQLite cron_run_logs) is
# unreadable. A monitor that reports OK forever while blind is the precise
# silent-rot this watchdog exists to prevent — so PAGE, once per episode
# (sentinel in the state file), not every tick.
if source_error:
    already = state.get("__source_error__")
    new_state["__source_error__"] = source_error
    _persist()
    if already != source_error:
        _emit(":rotating_light: *cron-health-watchdog is BLIND* — it cannot read cron "
              "run logs, so cron failures will go UNDETECTED until this is fixed.\n• " + source_error)
    raise SystemExit(0)

# Source healthy — clear any stale blind sentinel so a future episode re-pages.
new_state.pop("__source_error__", None)

alerts = []  # (name, agent, ts_ms, err)

def _fmt_err(r):
    err = r.get("error") or r.get("summary") or "unknown error"
    err = " ".join(str(err).split())  # collapse newlines/runs of space to one line
    if len(err) > preview:
        err = err[:preview] + "…"
    return err

for job_id, recs in sorted(runs_by_job.items()):
    finished = [r for r in recs
                if r.get("status") in ("ok", "error") and isinstance(r.get("ts"), (int, float))]
    if not finished:
        continue
    finished.sort(key=lambda r: r["ts"])  # streak detection needs chronological order
    max_ts = max(r["ts"] for r in finished)
    prev = state.get(job_id)
    if prev is None:
        # First time we've ever seen this job: seed the watermark and do
        # NOT alert on the historical backlog (avoids a page-storm on install).
        new_state[job_id] = max_ts
        continue
    name, agent = names.get(job_id, (job_id, "<unknown>"))
    # Walk runs chronologically tracking TWO streaks. A healthy run (ok, or
    # errored-but-delivered) resets both to 0. Classification is three-way:
    #   • hard failure (is_failure, not transient) → build `streak`; alert once
    #     it is BOTH newer than the watermark AND the Nth-or-later consecutive
    #     failure (suppresses lone recovered blips, pages a sustained outage).
    #   • transient (is_transient: restart-interrupt / 7.1 claim race) → build
    #     `transient_streak` ONLY. It does NOT grow the hard streak (deploy churn
    #     must not page) and does NOT reset it (a real→transient→real sequence
    #     must still page — an infra blip can't mask a genuine fault). Fail-loud
    #     backstop: a job stuck in transient limbo for `transient_stuck_streak`
    #     consecutive fires with no recovery pages a distinct 'stuck' bullet.
    #   • real failure resets `transient_streak` (the job ran and failed for a
    #     real reason — no longer stuck in claim/restart limbo).
    streak = 0
    transient_streak = 0
    for r in finished:
        if not is_failure(r):
            streak = 0
            transient_streak = 0
        elif is_transient(r):
            transient_streak += 1
            if r["ts"] > prev and transient_streak >= transient_stuck_streak:
                alerts.append((name, agent, r["ts"],
                               "stuck: %d consecutive restart/claim failures, not recovering — %s"
                               % (transient_streak, _fmt_err(r))))
        else:
            streak += 1
            transient_streak = 0
            if r["ts"] > prev and streak >= min_streak:
                alerts.append((name, agent, r["ts"], _fmt_err(r)))
    new_state[job_id] = max(prev, max_ts)

_persist()

if not alerts:
    raise SystemExit(0)

alerts.sort(key=lambda a: a[2])
lines = [f":rotating_light: *Cron failure(s) detected — {len(alerts)}*"]
for name, agent, ts_ms, err in alerts:
    ts_iso = datetime.fromtimestamp(ts_ms / 1000, tz=timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    lines.append(f"• *{name}* ({agent}) at {ts_iso}: {err}")
_emit("\n".join(lines))
PYEOF
}

# ──────────────────────────────────────────────────────────────
# Inline self-test — runs on EVERY invocation (cost ~30ms).
# Guards the failure that would make THIS watchdog itself rot
# silently: a detector that no longer detects. Mirrors the
# openclaw-watchdog self-test discipline (a regex that silently
# stopped matching went unnoticed for months). Uses throwaway temp
# paths — never touches real state or Slack.
# ──────────────────────────────────────────────────────────────
_self_test() {
  local td out
  td="$(mktemp -d "${TMPDIR:-/tmp}/cron-health-watchdog.XXXXXX")"
  trap 'rm -rf "$td"' RETURN
  mkdir -p "$td/runs"
  # Eight jobs, all pre-seeded watermark at ts=100 (transient cases documented
  # inline in their own block below).
  #
  # selftest-job: ok@150, then a two-error streak (error@190, error@200).
  # Exercises the streak threshold of 2: error@190 is a lone failure (preceded
  # by the ok@150) so it must be SUPPRESSED, while error@200 completes a 2-run
  # streak so it must FIRE.
  #
  # delivered-job: two errors (error@190, error@200), each carrying a non-empty
  # delivery.messageToolSentTo — the agent posted to Slack via the message tool
  # but the run still records status:error / delivered:false (the codex
  # self-post false-fail). is_failure() must treat BOTH as healthy, so this job
  # contributes 0 bullets and its name must NOT appear in the output. If the
  # message-tool branch ever regresses these two stack a 2-streak and fire,
  # tripping the bullet-count assertion below.
  printf '%s\n' '{"status":"ok","ts":150}' '{"status":"error","ts":190,"error":"first"}' '{"status":"error","ts":200,"error":"boom `q` \"x\""}' \
    > "$td/runs/selftest-job.jsonl"
  printf '%s\n' \
    '{"status":"error","ts":190,"error":"⚠️ 🛠️ `git status` failed","delivery":{"messageToolSentTo":[{"channel":"message"}]}}' \
    '{"status":"error","ts":200,"error":"⚠️ 🛠️ `stripe ...` failed","delivery":{"messageToolSentTo":[{"channel":"message"}]}}' \
    > "$td/runs/delivered-job.jsonl"
  # ── Transient-signature cases (restart-interrupt + 7.1 claim race) ──────
  # RETRYABLE infra churn openclaw re-dispatches (is_transient): EXCLUDED from
  # the hard-failure streak so a deploy storm stops false-paging, but NOT
  # treated as healthy (an infra blip must not reset a real streak).
  # TRANSIENT_STUCK_STREAK is pinned to 3 in the scan call below.
  #
  # restart-job: two back-to-back 'interrupted by gateway restart' errors —
  #   transient_streak peaks at 2 (< stuck threshold 3) → 0 bullets.
  # claim-job: a lone 7.1 CronSessionLifecycleClaimError blip → 0 bullets.
  # mixed-job: real@190, restart@195, real@200 — the transient run must NOT
  #   reset the hard streak, so real@200 still completes a 2-streak → 1 bullet.
  # stuck-job: three consecutive transient errors — hits the stuck threshold at
  #   the 3rd → exactly 1 distinct 'stuck' bullet (the fail-loud backstop).
  # nonconsec-job: transient×2, real, transient×2, ok, transient — the real AND
  #   the ok each RESET transient_streak, so it never reaches 3-in-a-row → 0
  #   bullets. Guards BOTH resets: dropping either lets the count climb across
  #   the interruption and fire a FALSE 'stuck' page (mutation-tested — without
  #   a reset the total flips to 4 and the count assertion below trips).
  # abort-job: two 'AbortError: agent run aborted' errors — the restart signature
  #   a LONG cron emits when drained mid-agent-turn → transient → 0 bullets.
  printf '%s\n' \
    '{"status":"error","ts":190,"error":"cron: job interrupted by gateway restart"}' \
    '{"status":"error","ts":200,"error":"cron: job interrupted by gateway restart"}' \
    > "$td/runs/restart-job.jsonl"
  printf '%s\n' \
    '{"status":"error","ts":200,"error":"CronSessionLifecycleClaimError: Session changed while starting work. Retry."}' \
    > "$td/runs/claim-job.jsonl"
  printf '%s\n' \
    '{"status":"error","ts":190,"error":"real boom"}' \
    '{"status":"error","ts":195,"error":"cron: job interrupted by gateway restart"}' \
    '{"status":"error","ts":200,"error":"real crash"}' \
    > "$td/runs/mixed-job.jsonl"
  printf '%s\n' \
    '{"status":"error","ts":190,"error":"cron: job interrupted by gateway restart"}' \
    '{"status":"error","ts":195,"error":"CronSessionLifecycleClaimError: Session changed while starting work. Retry."}' \
    '{"status":"error","ts":200,"error":"cron: job interrupted by gateway restart"}' \
    > "$td/runs/stuck-job.jsonl"
  printf '%s\n' \
    '{"status":"error","ts":190,"error":"cron: job interrupted by gateway restart"}' \
    '{"status":"error","ts":192,"error":"cron: job interrupted by gateway restart"}' \
    '{"status":"error","ts":194,"error":"real boom"}' \
    '{"status":"error","ts":196,"error":"cron: job interrupted by gateway restart"}' \
    '{"status":"error","ts":198,"error":"cron: job interrupted by gateway restart"}' \
    '{"status":"ok","ts":200}' \
    '{"status":"error","ts":202,"error":"cron: job interrupted by gateway restart"}' \
    > "$td/runs/nonconsec-job.jsonl"
  printf '%s\n' \
    '{"status":"error","ts":190,"error":"AbortError: agent run aborted"}' \
    '{"status":"error","ts":200,"error":"AbortError: agent run aborted"}' \
    > "$td/runs/abort-job.jsonl"
  printf '%s\n' '{"jobs":[{"id":"selftest-job","name":"selftest","agentId":"qa"},{"id":"delivered-job","name":"deliveredpost","agentId":"qa"},{"id":"restart-job","name":"restartblip","agentId":"qa"},{"id":"claim-job","name":"claimblip","agentId":"qa"},{"id":"mixed-job","name":"mixedreal","agentId":"qa"},{"id":"stuck-job","name":"stuckjob","agentId":"qa"},{"id":"nonconsec-job","name":"nonconsec","agentId":"qa"},{"id":"abort-job","name":"abortblip","agentId":"qa"}]}' > "$td/jobs.json"
  printf '%s\n' '{"selftest-job":100,"delivered-job":100,"restart-job":100,"claim-job":100,"mixed-job":100,"stuck-job":100,"nonconsec-job":100,"abort-job":100}' > "$td/state.json"
  # Pin MIN_STREAK=2 and TRANSIENT_STUCK_STREAK=3 so the self-test is
  # deterministic regardless of the operator's CRON_HEALTH_* overrides — it
  # verifies detector HEALTH (fires on a real streak, suppresses a lone error,
  # skips transient churn, still catches a real streak interleaved with a
  # transient, and pages a genuinely stuck job), not the live thresholds.
  out="$(RUNS_DB="" MIN_STREAK=2 TRANSIENT_STUCK_STREAK=3 scan_failures "$td/runs" "$td/jobs.json" "$td/state.json" "$td/payload.json" 0 2>/dev/null || true)"
  if ! printf '%s' "$out" | grep -q "selftest"; then
    echo "$LOGPREFIX SELF-TEST FAIL: detector did not flag the injected error streak" >&2
    return 1
  fi
  # Exactly THREE bullets must fire: selftest error@200 (real 2-streak),
  # mixedreal error@200 (real streak survives an interleaved transient), and
  # stuckjob error@200 (transient_stuck backstop at the 3rd transient). The
  # ok/lone-error blips, the delivered-job, and the pure restart/claim
  # transients (restartblip, claimblip) must ALL be filtered out.
  local bullets
  bullets="$(printf '%s\n' "$out" | grep -c '^• ' || true)"
  if [ "$bullets" != "3" ]; then
    echo "$LOGPREFIX SELF-TEST FAIL: expected 3 alert bullets, got $bullets" >&2
    return 1
  fi
  # The message-tool-delivered job must be suppressed entirely — its name must
  # never reach the alert block (guards the delivery.messageToolSentTo branch).
  if printf '%s' "$out" | grep -q "deliveredpost"; then
    echo "$LOGPREFIX SELF-TEST FAIL: message-tool-delivered run was flagged as a failure" >&2
    return 1
  fi
  # Transient infra churn below the stuck threshold must NOT page — the whole
  # point of is_transient() (restart interrupt / mid-turn abort / 7.1 claim race).
  if printf '%s' "$out" | grep -qE "restartblip|claimblip|abortblip"; then
    echo "$LOGPREFIX SELF-TEST FAIL: a transient restart/abort/claim blip was paged as a hard failure" >&2
    return 1
  fi
  # A transient run BROKEN by a real/healthy run must not accumulate toward the
  # stuck backstop — nonconsec resets transient_streak twice and must stay
  # silent (guards BOTH resets; a dropped reset also trips the count!=3 above).
  if printf '%s' "$out" | grep -q "nonconsec"; then
    echo "$LOGPREFIX SELF-TEST FAIL: a non-consecutive transient sequence fired the stuck backstop" >&2
    return 1
  fi
  # A real failure interleaved with a transient must STILL page — a transient
  # run must not reset the hard-failure streak.
  if ! printf '%s' "$out" | grep -q "mixedreal"; then
    echo "$LOGPREFIX SELF-TEST FAIL: a transient run masked a real failure streak" >&2
    return 1
  fi
  # A job STUCK in transient limbo past the threshold must page a distinct
  # 'stuck' bullet (fail-loud backstop) — never silently swallowed.
  if ! printf '%s' "$out" | grep -q "stuck: 3 consecutive"; then
    echo "$LOGPREFIX SELF-TEST FAIL: a job wedged in transient-error limbo did not fire the stuck backstop" >&2
    return 1
  fi

  # ── 6.x SQLite source path ──────────────────────────────────────────────
  # The cases above exercise the JSONL fallback (RUNS_DB=""). This one guards the
  # PRODUCTION reader: build a throwaway cron_run_logs table and verify a 2-error
  # streak surfaces THROUGH it, AND that a transient restart run is excluded
  # there too. A future cron-store relocation that silently froze this watchdog
  # would fail HERE instead of rotting unnoticed.
  local db sout
  db="$td/runs.sqlite"
  python3 - "$db" <<'PYDB'
import sqlite3, json, sys
con = sqlite3.connect(sys.argv[1])
con.execute("CREATE TABLE cron_run_logs (store_key TEXT, job_id TEXT, seq INTEGER, entry_json TEXT)")
sk = "/selftest/jobs.json"
for jid, seq, rec in [
    ("selftest-job", 1, {"status": "error", "ts": 190, "error": "first"}),
    ("selftest-job", 2, {"status": "error", "ts": 200, "error": "boom"}),
    ("restart-job", 1, {"status": "error", "ts": 190, "error": "cron: job interrupted by gateway restart"}),
    ("restart-job", 2, {"status": "error", "ts": 200, "error": "cron: job interrupted by gateway restart"}),
]:
    con.execute("INSERT INTO cron_run_logs (store_key, job_id, seq, entry_json) VALUES (?,?,?,?)",
                (sk, jid, seq, json.dumps(rec)))
con.commit(); con.close()
PYDB
  sout="$(RUNS_DB="$db" STORE_KEY="/selftest/jobs.json" MIN_STREAK=2 TRANSIENT_STUCK_STREAK=3 \
    scan_failures "$td/runs" "$td/jobs.json" "$td/state.json" "$td/payload-sql.json" 0 2>/dev/null || true)"
  if ! printf '%s' "$sout" | grep -q "selftest"; then
    echo "$LOGPREFIX SELF-TEST FAIL: SQLite cron_run_logs reader did not surface the injected streak" >&2
    return 1
  fi
  if printf '%s' "$sout" | grep -q "restartblip"; then
    echo "$LOGPREFIX SELF-TEST FAIL: SQLite reader paged a transient restart blip as a hard failure" >&2
    return 1
  fi
  return 0
}

if ! _self_test; then
  log "ABORT: self-test failed — refusing to run with a broken detector"
  exit 3
fi

# ──────────────────────────────────────────────────────────────
# Host guard: wrong node → no-op (prevents an orphaned cron from
# firing after a host migration). Skippable for tests.
# ──────────────────────────────────────────────────────────────
if [ "$SKIP_HOST_GUARD" != "1" ] && ! hostname | grep -q '^ovh-node-8$'; then
  log "SKIP: hostname is not ovh-node-8 ($(hostname)) — script is node-8-specific"
  exit 0
fi

# Run-log source presence. On 6.x the source is the SQLite cron_run_logs table
# (CRON_RUNS_DB); the legacy cron/runs/*.jsonl dir is the pre-6.x/test fallback.
# Skip only when the ACTIVE source is entirely absent — a present-but-broken DB
# (table relocated/missing) is handled as a loud BLIND alert in scan_failures,
# NOT a silent skip.
if [ -n "$CRON_RUNS_DB" ]; then
  if [ ! -f "$CRON_RUNS_DB" ] && [ ! -d "$CRON_RUNS_DIR" ]; then
    log "SKIP: no cron run-log source (DB $CRON_RUNS_DB and runs dir $CRON_RUNS_DIR both absent)"
    exit 0
  fi
elif [ ! -d "$CRON_RUNS_DIR" ]; then
  log "SKIP: cron runs dir not found: $CRON_RUNS_DIR (no DB configured)"
  exit 0
fi

# (single-run lock: taken at the TOP of the script — see "Single-run lock".)

PAYLOAD_FILE="$(mktemp)"
trap 'rm -f "$PAYLOAD_FILE"' EXIT

alert_block="$(scan_failures "$CRON_RUNS_DIR" "$CRON_JOBS_FILE" "$STATE_FILE" "$PAYLOAD_FILE" 1 || true)"

if [ -z "$alert_block" ]; then
  log "OK: no new cron failures."
  exit 0
fi

if [ "$DRY_RUN" -eq 1 ]; then
  log "DRY-RUN: would post the following to ${SLACK_CHANNEL}:"
  printf '%s\n' "$alert_block"
  exit 0
fi

log "Posting cron-failure alert to ${SLACK_CHANNEL}."
printf '%s\n' "$alert_block"
slack_notify_payload_file "$PAYLOAD_FILE"
