#!/usr/bin/env bash
# notify-unit-failed.sh <unit> — OnFailure= target for hydra oneshot units
# (hydra-unit-failed@.service, installed by install-aux-units.sh).
#
# A failed timer-driven oneshot is otherwise only a red unit in `systemctl
# list-units --failed` that nobody watches. Units that can page for themselves
# do (codex-edge-mirror.sh --restart pages on every structural exit); this
# covers what never reaches the script: ExecStart missing or not executable,
# the interpreter absent, or systemd killing the run at TimeoutStartSec.
#
# Delivery goes through lib/deploy-notify.sh, which RETURNS the real Slack
# status. slack_notify/slack_notify_critical deliberately swallow the send's
# exit code (docs/lessons: "slack_notify discards both streams and returns 0"),
# so a rejected post (invalid_auth, bot removed from the channel, CLI failure)
# would have exited 0 here with no page and no trace — the original failed
# timer silently unalerted (QA finding on #935, round 5). On a failed delivery
# this script exits NON-ZERO and leaves two observable traces: a journal line
# and a marker file under NOTIFY_UNIT_FAILED_MARKER_DIR (default
# /var/lib/hydra/unit-failed-unpaged/) named after the unit. systemd ignores an
# OnFailure unit's exit code, which is exactly why the marker exists.
#
# Env: NOTIFY_UNIT_FAILED_LINES (journal tail, default 12),
#      NOTIFY_UNIT_FAILED_MARKER_DIR, DEPLOY_NOTIFY_BIN (tests).
set -uo pipefail
umask 077

UNIT="${1:-}"
[ -n "$UNIT" ] || { echo "usage: $0 <unit>" >&2; exit 2; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NOTIFY_BIN="${DEPLOY_NOTIFY_BIN:-$SCRIPT_DIR/lib/deploy-notify.sh}"
MARKER_DIR="${NOTIFY_UNIT_FAILED_MARKER_DIR:-/var/lib/hydra/unit-failed-unpaged}"
SELF_PAGED_DIR="${HYDRA_SELF_PAGED_DIR:-/var/lib/hydra/self-paged}"
SELF_PAGED_MAX_AGE="${NOTIFY_UNIT_FAILED_SELF_PAGED_MAX_AGE:-120}"
LOGPREFIX="[notify-unit-failed $(date -u +%Y-%m-%dT%H:%M:%SZ)]"
log() { echo "$LOGPREFIX $*" >&2; }

# leave_trace <reason> — journal line + ONE spool file per record (temp name,
# then rename into place): the watchdog claims whole files by rename, and no
# producer ever holds an fd on a file it can claim — there is no shared append
# surface to race on. Never fails the caller.
leave_trace() {
  local now spool tmp
  log "PAGE NOT DELIVERED for $UNIT: $1 — the failed unit is UNALERTED"
  mkdir -p "$MARKER_DIR" 2>/dev/null || true
  now="$(date -u +%s)"; spool="$MARKER_DIR/${UNIT}.${now}.$$.unpaged"; tmp="$spool.tmp"
  if printf '%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$UNIT" "$1" > "$tmp" 2>/dev/null && mv -f "$tmp" "$spool" 2>/dev/null; then
    log "durable marker $spool left for cron-health-watchdog"
  else
    rm -f "$tmp" 2>/dev/null
    log "could not write marker under $MARKER_DIR"
  fi
}

# One pager per failure: a unit whose script paged for its own failure just
# now (it stamps $SELF_PAGED_DIR/<unit> under its systemd run — see
# codex-edge-mirror.sh page_failure) must not be paged again by this generic
# OnFailure= handler; that would also bypass the script's own cooldown.
_self_paged_age() {
  local f="$SELF_PAGED_DIR/$UNIT" ts now
  [ -r "$f" ] || return 1
  ts="$(cat "$f" 2>/dev/null)"; case "$ts" in (*[!0-9]*|"") return 1 ;; esac
  now="$(date -u +%s)"
  [ $((now - ts)) -ge 0 ] && [ $((now - ts)) -le "$SELF_PAGED_MAX_AGE" ] || return 1
  printf '%s' $((now - ts))
}
if age="$(_self_paged_age)"; then
  log "$UNIT paged for its own failure ${age}s ago (self-paged stamp) — not paging it a second time"
  exit 0
fi

tail_lines="$(journalctl -u "$UNIT" -n "${NOTIFY_UNIT_FAILED_LINES:-12}" --no-pager -o cat 2>/dev/null | tr '`' "'" | tail -c 1500)"
result="$(systemctl show -p Result --value "$UNIT" 2>/dev/null || true)"
msg="*systemd unit FAILED* on node-8: \`${UNIT}\` (Result=${result:-unknown}). The unit's own pager did not run, so treat this as unhandled. Last journal lines:
\`\`\`
${tail_lines:-<no journal output>}
\`\`\`
\`systemctl status ${UNIT}\` for the rest."

# deploy-notify.sh is invoked through bash (it is not +x in the repo; the deploy
# workflow calls it the same way).
if [ ! -r "$NOTIFY_BIN" ]; then
  leave_trace "$NOTIFY_BIN missing or unreadable"
  exit 1
fi
rc=0
bash "$NOTIFY_BIN" critical "$msg" || rc=$?
if [ "$rc" -ne 0 ]; then
  leave_trace "deploy-notify.sh exited $rc (Slack rejected or the CLI failed)"
  exit 1
fi
log "paged #clio_devops for $UNIT"
exit 0
