#!/usr/bin/env bash
# MONDAY 08:00Z weekly line for the churn-with-open-issue signal (firstmate spec
# churn-risk-signal-prevent-p1 item 5). Reads the store the 04:15Z churned sweep
# just refreshed; posts one line; never contacts a customer.
#
#   CHURN_DRY_RUN=1     print the line, post nothing
#   KILL_SWITCH         same file as the alert: stops the consumer override and both posts
set -uo pipefail
HYDRA_ROOT="${HYDRA_ROOT:-/opt/hydra}"
POLICY="${CHURN_RISK_POLICY:-$HYDRA_ROOT/policies/churn-risk.json}"
KILL_SWITCH="${KILL_SWITCH:-/etc/hydra/churn-risk.disabled}"
DRY_RUN="${CHURN_DRY_RUN:-0}"
MAIN_ENV="${MAIN_ENV:-/etc/openclaw/main.env}"

log() { echo "$(date -u +%FT%TZ) $*"; }
[ -e "$KILL_SWITCH" ] && { log "kill switch present ($KILL_SWITCH): no weekly line"; exit 0; }
[ -r "$POLICY" ] || { log "FATAL policy missing: $POLICY"; exit 1; }

# shellcheck source=/dev/null
[ -r "$MAIN_ENV" ] && { set -a; . "$MAIN_ENV"; set +a; }
# shellcheck source=/dev/null
. "$HYDRA_ROOT/scripts/lib/slack-notify.sh"
SLACK_CHANNEL="${SLACK_CHANNEL:-$(python3 -c 'import json,sys;print((json.load(open(sys.argv[1])).get("slack") or {}).get("channel") or "C0ADV2W76G4")' "$POLICY" 2>/dev/null || echo C0ADV2W76G4)}"
export SLACK_CHANNEL

# The stderr file lives in the policy's store dir, like every other path this run
# touches: a canary policy on a host without the production directory must not fail
# before the line is even rendered.
STATE_ROOT="$(python3 -c 'import json,sys;print((json.load(open(sys.argv[1])).get("store") or {}).get("dir") or "/var/lib/hydra/churn")' "$POLICY" 2>/dev/null || echo /var/lib/hydra/churn)"
install -d -m 700 "$STATE_ROOT"
ERR="$STATE_ROOT/weekly-line.err"
if ! LINE="$(python3 "$HYDRA_ROOT/scripts/churn/weekly_line.py" --policy "$POLICY" 2>"$ERR")"; then
  log "FATAL weekly_line.py failed: $(tail -3 "$ERR" | tr '\n' ' ')"
  exit 1
fi
# the line undercounts a stale or partial sweep: say so in the cron log, not only in
# a state file nobody reads
[ -s "$ERR" ] && log "warning: $(tr '\n' ' ' < "$ERR")"
[ -n "$LINE" ] || { log "FATAL weekly line rendered empty"; exit 1; }
if [ "$DRY_RUN" = "1" ]; then
  echo "DRY: $LINE"
  exit 0
fi
# slack_notify is best-effort and always returns 0; this branch needs the real
# delivery status, so a failed post is reported as failed.
PAYLOAD="$(mktemp)"
trap 'rm -f "$PAYLOAD"' EXIT
jq -n --arg channel "$SLACK_CHANNEL" --arg text "$LINE" '{channel: $channel, text: $text}' > "$PAYLOAD"
slack_notify_payload_file_status "$PAYLOAD" || { log "post FAILED: $LINE"; exit 1; }
log "posted: $LINE"
