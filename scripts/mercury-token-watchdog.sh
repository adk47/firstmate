#!/bin/bash
# ──────────────────────────────────────────────────────────────
# Mercury Token Watchdog
#
# Pages #clio_devops when the Finance agent's read-only Mercury Bank API token
# stops authenticating. Detection lives in scripts/lib/ensure-mercury-token.sh
# (pure 0/1/2 detector); this script owns the host guard, the alert cooldown,
# and the Slack post — the same split as ensure-session-budget-headroom.sh +
# cron-health-watchdog.sh.
#
# Born from the 2026-08-03 escalation: the token had been revoked since roughly
# 2026-06-10 and nobody noticed for ~8 weeks. There is no CIB cron and was no
# health check, so a dead banking credential was invisible until Liza asked for
# a forecast and got a wall. Finance had itself reported the 401 three weeks
# earlier, on 07-13, with no follow-through. Full rationale in the detector.
#
# Deliberately a deterministic system-cron bash watchdog — NOT an openclaw cron
# — so it fires even when the gateway is down and never routes a boolean
# credential-health question through an LLM turn. (CLAUDE.md's extension tree
# node 3 reads "wall-clock schedule -> openclaw cron", but every one of the 11
# sibling watchdogs is a cron.d entry, and openclaw crons have twice been
# silently mass-killed by session-budget reapers — a watchdog must not die from
# the class of failure it exists to detect.)
#
# Runs daily via /etc/cron.d/mercury-token-watchdog ON NODE-8 (installed
# idempotently by scripts/install-aux-units.sh). Daily, not the 2/5/15-min
# watchdog tier: a revoked credential stays revoked until a human acts, and
# each tick costs one authenticated call to a bank API.
#
# NOT maintenance-flag guarded — a business/external-credential condition, not
# fleet health. Listed with that reason in
# scripts/tests/fixtures/maintenance-guard-exempt.txt (enforced by
# scripts/tests/maintenance-guard-drift.bats).
#
# Flags:
#   --dry-run   report the verdict, do NOT post and do NOT touch the cooldown.
#
# Env knobs (mainly for tests):
#   MERCURY_TOKEN_CHECK          detector path (default ../lib/ensure-mercury-token.sh)
#   MERCURY_ALERT_STATE          last-successful-page stamp
#   MERCURY_ALERT_INTERVAL       seconds between pages (default 20h)
#   MERCURY_CHANNEL              Slack channel (default C0ADV2W76G4 #clio_devops)
#   MERCURY_SKIP_HOST_GUARD      1 = skip the ovh-node-8 guard (tests)
# ──────────────────────────────────────────────────────────────
set -uo pipefail

_WD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CHECK="${MERCURY_TOKEN_CHECK:-$_WD_DIR/lib/ensure-mercury-token.sh}"
ALERT_STATE="${MERCURY_ALERT_STATE:-/var/lib/hydra/mercury-token-last-alert}"
# 20h rather than 24h so a daily tick is never suppressed by the interval
# landing exactly on the cadence. At the shipped daily cadence this limiter is
# effectively inert BY DESIGN — it is not defending against cron jitter (vixie
# cron on this UTC box has none). What it actually guards is a manual re-run
# and a future cadence change to something sub-daily; keeping it means moving
# to hourly is a one-line cron edit rather than a pager incident.
ALERT_INTERVAL="${MERCURY_ALERT_INTERVAL:-72000}"
SKIP_HOST_GUARD="${MERCURY_SKIP_HOST_GUARD:-0}"
# Consecutive detector rc=2 results before we page that health is UNKNOWN. One
# unknown is a blip; a run of them is silence, and silence is the failure mode
# that let the last revocation sit for eight weeks.
UNKNOWN_STATE="${MERCURY_UNKNOWN_STATE:-/var/lib/hydra/mercury-token-unknown-streak}"
UNKNOWN_THRESHOLD="${MERCURY_UNKNOWN_THRESHOLD:-3}"
# Separate cooldown for the UNKNOWN page — see page_once().
UNKNOWN_ALERT_STATE="${MERCURY_UNKNOWN_ALERT_STATE:-/var/lib/hydra/mercury-token-unknown-last-alert}"

# slack-notify.sh reads this; export before sourcing so its `:=` default
# doesn't override us.
export SLACK_CHANNEL="${MERCURY_CHANNEL:-C0ADV2W76G4}"  # #clio_devops

LOGPREFIX="[mercury-token-watchdog $(date -u +%Y-%m-%dT%H:%M:%SZ)]"
log() { echo "$LOGPREFIX $*"; }

DRY_RUN=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    *) echo "$LOGPREFIX unknown arg: $arg" >&2; exit 2 ;;
  esac
done

# The host guard runs BEFORE the detector, not after: the probe makes a live
# authenticated call to a bank API, and a dev box that merely has the repo
# checked out must never do that.
if [ "$SKIP_HOST_GUARD" != "1" ] && [ "$(hostname)" != "ovh-node-8" ]; then
  log "not on ovh-node-8 — refusing to run (set MERCURY_SKIP_HOST_GUARD=1 to override)"
  exit 0
fi

# Everything that is not a credential verdict is normalised to rc=2 BEFORE the
# dispatch below, so it flows through the same consecutive-unknown escalation.
# A missing/unexecutable detector, a bad shebang (126/127) or a kill (137/143)
# used to `exit 0` with nothing but a cron-log line — unbounded silence, the
# exact failure shape the rc=2 streak counter was added to end. A broken checker
# is "nobody knows whether the bank token works", same as a broken network.
out=""; rc=0
if [ ! -x "$CHECK" ]; then
  rc=2; out="detector missing or not executable: $CHECK"
else
  # `|| rc=$?` is required even without set -e: we need the guard's exit code,
  # and 1 is its designed answer, not a failure of this script.
  out="$("$CHECK" --check 2>&1)" || rc=$?
  # Strip the detector's own "[ensure-mercury-token <ts>] LEVEL: " stamp. This
  # script re-labels with its own prefix and severity, so passing the detector's
  # line through verbatim double-stamps every cron-log entry AND the Slack page
  # body — observed in the first production fire:
  #   [mercury-token-watchdog …] VIOLATION: [ensure-mercury-token …] VIOLATION: token REJECTED…
  # Applied per line: the detector may emit more than one.
  out="$(printf '%s' "$out" | sed -E 's/^\[ensure-mercury-token [^]]*\] (VIOLATION|WARN|clean): ?//')"
  case "$rc" in
    0|1|2) ;;
    *) out="detector returned unexpected rc=${rc} (contract is 0/1/2): ${out:-<no output>}"; rc=2 ;;
  esac
fi

# shellcheck source=lib/slack-notify.sh
source "$_WD_DIR/lib/slack-notify.sh"

# page_once <stamp-file> <slack-text> — post, rate limited, advancing the
# cooldown ONLY on a confirmed delivery. The stamp is a PARAMETER so the two
# pageable conditions rate-limit independently: sharing one produced an inverted
# escalation ladder, where "health UNKNOWN" paged and then swallowed the
# definitive "token is REVOKED" page for the next 20h — silence exactly when the
# answer had arrived.
page_once() {
  local stamp="$1" text="$2" now last payload
  now="$(date -u +%s)"
  # Braces so the redirection failure on a missing stamp is swallowed too —
  # bash applies `< file` BEFORE `2>/dev/null`, so without them the first-ever
  # run prints "No such file or directory" into the cron log.
  last="$( { tr -dc '0-9' < "$stamp"; } 2>/dev/null || echo 0)"
  [ -n "$last" ] || last=0

  if [ $((now - last)) -lt "$ALERT_INTERVAL" ]; then
    log "page suppressed (last delivered $((now - last))s ago, interval ${ALERT_INTERVAL}s)"
    return 0
  fi

  payload="$(mktemp)"
  # mktemp is 0600 and the body carries no credential, but an unhandled signal
  # between here and the send would otherwise orphan it in /tmp.
  trap 'rm -f "$payload"' RETURN
  jq -n --arg c "$SLACK_CHANNEL" --arg t "$text" '{channel:$c, text:$t}' > "$payload"

  # Status-aware post: the best-effort slack_notify_critical returns 0
  # unconditionally, so using it here would let a FAILED post mark the incident
  # "already paged" and go quiet for the whole window — the exact hazard
  # slack-notify.sh documents this variant for.
  if slack_notify_payload_file_status "$payload"; then
    log "paged ${SLACK_CHANNEL}"
    mkdir -p "$(dirname "$stamp")" 2>/dev/null || true
    printf '%s' "$now" > "$stamp" 2>/dev/null || true
  else
    log "WARNING: Slack post FAILED — cooldown NOT advanced, will retry next tick"
  fi
}

REMEDIATION="mint a fresh *read-only* token in the Mercury dashboard (Settings → API tokens), then on node-8:
\`\`\`
read -rsp 'Mercury token: ' T; echo
printf 'MERCURY_API_KEY=%s\\n' \"\$T\" | install -m 600 /dev/stdin /opt/hydra/secrets/mercury.env
unset T
bash /opt/hydra/scripts/lib/ensure-mercury-token.sh --check   # expect exit 0
\`\`\`
(\`read -rs\` keeps it off the screen and out of shell history — do NOT paste it into a heredoc.)"

# rc is guaranteed 0/1/2 by the normalisation above. Only rc=1 is a statement
# about the credential — everything else must never tell Nick and Aaron to go
# mint a bank token.
case "$rc" in
  0)
    log "clean: Mercury token authenticates"
    # Clear both stamps so a later re-revocation pages immediately instead of
    # being suppressed by state from the previous outage. Inert at the daily
    # cadence, load-bearing the moment anyone moves this to hourly.
    rm -f "$ALERT_STATE" "$UNKNOWN_STATE" "$UNKNOWN_ALERT_STATE" 2>/dev/null || true
    exit 0
    ;;
  1)
    rm -f "$UNKNOWN_STATE" 2>/dev/null || true   # a verdict resets the streak
    ;;
  2)
    # A SINGLE unknown is transient by construction — log, never page. But a RUN
    # of them means nobody knows whether the bank credential works, indefinitely
    # and silently, which is precisely the 8-week failure this watchdog exists
    # to end. Escalate once the streak crosses the threshold.
    streak="$( { tr -dc '0-9' < "$UNKNOWN_STATE"; } 2>/dev/null || echo 0)"
    [ -n "$streak" ] || streak=0
    streak=$((streak + 1))
    # The streak MUST actually persist, or the counter is a no-op: an
    # unwritable /var/lib/hydra makes every tick re-read 0, record 1, and never
    # reach the threshold — silent forever, which is the failure this counter
    # exists to end. `|| true` here would hide exactly that. Verified: with an
    # unpersistable path, 5 consecutive ticks produced streak=1 five times and
    # zero pages.
    persisted=1
    if [ "$DRY_RUN" -eq 0 ]; then
      { mkdir -p "$(dirname "$UNKNOWN_STATE")" 2>/dev/null \
          && printf '%s' "$streak" > "$UNKNOWN_STATE" 2>/dev/null; } || persisted=0
    fi
    log "WARN: detector could not evaluate (consecutive unknowns: ${streak}): $out"

    if [ "$persisted" -eq 0 ]; then
      # Cannot count, so cannot wait for a streak. Escalate on this tick rather
      # than stay silent — an unwritable state dir is itself an incident, and
      # the honest report is "health unknown AND we can't track it".
      log "ERROR: cannot persist the unknown streak to ${UNKNOWN_STATE} — escalating now rather than counting to a threshold we can never reach"
      out="${out} [state persistence FAILED: ${UNKNOWN_STATE} is unwritable, so consecutive failures cannot be counted]"
    elif [ "$streak" -lt "$UNKNOWN_THRESHOLD" ]; then
      exit 0
    else
      log "ESCALATING: ${streak} consecutive unknown results"
    fi
    if [ "$DRY_RUN" -eq 1 ]; then
      log "DRY-RUN: would page ${SLACK_CHANNEL} (cooldown ${ALERT_STATE} untouched)"
      exit 0
    fi
    page_once "$UNKNOWN_ALERT_STATE" "<@${SLACK_UID_NICK}> <@${SLACK_UID_AARON}> :grey_question: *Mercury token health UNKNOWN for ${streak} consecutive checks* — the probe itself keeps failing, so nobody knows whether the bank credential works.

\`${out}\`

That is the silent state this watchdog exists to prevent, so it pages rather than staying quiet. Check node-8 network/DNS egress to api.mercury.com and that curl is present, then $REMEDIATION"
    exit 0
    ;;
  *)
    log "BUG: rc=${rc} survived normalisation — refusing to page on an unknown state"
    exit 0
    ;;
esac

log "VIOLATION: $out"

if [ "$DRY_RUN" -eq 1 ]; then
  # NOTE: unlike stuck-lane/prod-log-alert (whose --dry-run advances their
  # per-incident watermarks for a faithful rehearsal), this one leaves the
  # cooldown alone on purpose. Advancing it here would suppress the next REAL
  # page for the whole window — a rehearsal must not be able to silence the alarm.
  log "DRY-RUN: would page ${SLACK_CHANNEL} (cooldown ${ALERT_STATE} untouched)"
  exit 0
fi

page_once "$ALERT_STATE" "<@${SLACK_UID_NICK}> <@${SLACK_UID_AARON}> :bank: *Mercury API token is dead* — Finance cannot read the bank side (CIB report, cash forecasts).

\`${out}\`

This needs a human: $REMEDIATION

Revoked twice already (Token A ~2026-05-01, Token B ~2026-06-10). Next page in $((ALERT_INTERVAL / 3600))h if still broken."
exit 0
