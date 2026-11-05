#!/usr/bin/env bash
# HOURLY cancel-with-open-issue page (firstmate spec churn-risk-signal-prevent-p1 item 4).
#
# A paying user who had an open support issue and cancelled (or asked to cancel) is
# the "we lost them on support" case the captain asked us to stop: 16.3% of 60-day
# paying churn carried an unhandled support state. This tick pages the ops channel
# with the issue class, its age, list MRR and the lane that owns it, and writes the
# same row into that lane's intake with a `churned:<date>` tag so it stays
# paid-priority for 30 days (R4).
#
# It NEVER contacts the customer. It pages, and it writes the intake row; the lane
# that owns the issue decides what to say, under that lane's own copy locks.
#
#   HYDRA_ROOT=/opt/hydra            the deployed tree
#   CHURN_DRY_RUN=1                  build and print, post nothing, record nothing
#   SLACK_CHANNEL                    override the policy's channel
#   KILL_SWITCH=/etc/hydra/churn-risk.disabled
#
# Kill switch: the file stops the page (the nightly store keeps building, and the
# consumers' sort override stops too - risk_reader.py checks the same path).
set -uo pipefail
HYDRA_ROOT="${HYDRA_ROOT:-/opt/hydra}"
POLICY="${CHURN_RISK_POLICY:-$HYDRA_ROOT/policies/churn-risk.json}"
KILL_SWITCH="${KILL_SWITCH:-/etc/hydra/churn-risk.disabled}"
DRY_RUN="${CHURN_DRY_RUN:-0}"
MAIN_ENV="${MAIN_ENV:-/etc/openclaw/main.env}"

[ -r "$POLICY" ] || { echo "FATAL policy missing: $POLICY" >&2; exit 1; }
# ONE authority for every path this run touches (lock, payloads, store, watermark): the
# policy. A second override here would relocate the lock while the classifier kept
# writing production state, so a "canary tree" bought 30 days of real dedup silence.
STATE_ROOT="$(python3 -c 'import json,sys;print((json.load(open(sys.argv[1])).get("store") or {}).get("dir") or "/var/lib/hydra/churn")' "$POLICY" 2>/dev/null || echo /var/lib/hydra/churn)}"
install -d -m 700 "$STATE_ROOT"
LOCK="$STATE_ROOT/cancel-alert.lock"
exec 9>"$LOCK"
flock -n 9 || { echo "$(date -u +%FT%TZ) another cancel-alert run holds $LOCK"; exit 0; }

log() { echo "$(date -u +%FT%TZ) $*"; }

[ -e "$KILL_SWITCH" ] && { log "kill switch present ($KILL_SWITCH): no page, store keeps building"; exit 0; }

# shellcheck source=/dev/null
[ -r "$MAIN_ENV" ] && { set -a; . "$MAIN_ENV"; set +a; }
# shellcheck source=/dev/null
. "$HYDRA_ROOT/scripts/lib/slack-notify.sh"
SLACK_CHANNEL="${SLACK_CHANNEL:-$(python3 -c 'import json,sys;print((json.load(open(sys.argv[1])).get("slack") or {}).get("channel") or "C0ADV2W76G4")' "$POLICY" 2>/dev/null || echo C0ADV2W76G4)}"
export SLACK_CHANNEL

RUN="$STATE_ROOT/cancel-alert.$RANDOM.json"
PAYLOADS="$STATE_ROOT/cancel-alert.payloads.$$"
install -d -m 700 "$PAYLOADS"
trap 'rm -rf "$RUN" "$PAYLOADS"' EXIT

if ! python3 "$HYDRA_ROOT/scripts/churn/cancel_alert.py" --policy "$POLICY" --alerts > "$RUN" 2> "$STATE_ROOT/cancel-alert.err"; then
  log "FATAL cancel_alert.py failed: $(tail -3 "$STATE_ROOT/cancel-alert.err" | tr '\n' ' ')"
  exit 1
fi
N="$(python3 -c 'import json,sys;print(len(json.load(open(sys.argv[1])).get("alerts") or []))' "$RUN")"
UNCLASSIFIED="$(python3 -c 'import json,sys;print(len(json.load(open(sys.argv[1])).get("unclassified") or []))' "$RUN")"
log "alerts=$N unclassified=$UNCLASSIFIED watermark=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("watermark"))' "$RUN")"

# A candidate nobody could classify is not "no open issue". Its event is still ahead of
# the watermark commit wrote (the classifier stops the watermark at it), so it is read
# again next hour; this run must still say so rather than look like a quiet hour.
degraded() {
  [ "$UNCLASSIFIED" = "0" ] && return 0
  log "UNCLASSIFIED $UNCLASSIFIED canceller(s) could not be classified: watermark held before them, retried next hour"
  return 1
}

if [ "$N" = "0" ]; then
  # still commit: the watermark advances over cancels that had no open issue, so a
  # quiet hour is cheap and tomorrow does not re-scan tonight. A commit that cannot
  # be written is a FAILED tick, not a quiet one: the next hour re-scans the same
  # cancels, and reporting success here would hide that.
  if [ "$DRY_RUN" != "1" ]; then
    if ! python3 "$HYDRA_ROOT/scripts/churn/cancel_alert.py" --policy "$POLICY" --commit "$RUN" >/dev/null; then
      log "FATAL commit failed: watermark and sent ledger not written; the next tick re-scans"
      exit 1
    fi
    degraded || exit 1
  fi
  exit 0
fi

if [ "$DRY_RUN" = "1" ]; then
  python3 -c 'import json,sys
for a in json.load(open(sys.argv[1]))["alerts"]:
    print("DRY:", a["text"], "| lane", a["lane"], "| tag", a["tag"])' "$RUN"
  log "dry run: posted nothing, recorded nothing"
  exit 0
fi

# Every alert must become a payload before anything is posted: a builder that wrote
# nothing (unwritable state dir) would otherwise leave FAILED at 0 and commit a
# watermark over pages nobody sent.
if ! python3 - "$RUN" "$PAYLOADS" "$SLACK_CHANNEL" <<'PY'
import json, os, sys
run, out_dir, channel = sys.argv[1], sys.argv[2], sys.argv[3]
for i, alert in enumerate(json.load(open(run)).get("alerts") or []):
    text = alert.get("text") or ""
    if not text:
        continue
    path = os.path.join(out_dir, f"alert-{i}.json")
    with open(path, "w", encoding="utf-8") as fh:
        json.dump({"channel": channel, "text": text}, fh)
PY
then
  log "FATAL could not build the $N alert payloads; leaving the watermark and sent ledger untouched"
  exit 1
fi

set -- "$PAYLOADS"/alert-*.json
[ -e "$1" ] || set --
if [ "$#" != "$N" ]; then
  log "FATAL built $# of $N alert payloads; leaving the watermark and sent ledger untouched"
  exit 1
fi

FAILED=0
# slack_notify is best-effort by contract and always returns 0, so the commit below
# must branch on the status-returning helper: an undelivered page has to retry
# next hour, not buy 30 days of dedup silence.
for PAYLOAD in "$@"; do
  if ! slack_notify_payload_file_status "$PAYLOAD"; then
    log "post FAILED (will retry next hour): $(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["text"])' "$PAYLOAD")"
    FAILED=1
  fi
done

if [ "$FAILED" != "0" ]; then
  # do NOT commit: an unposted page must be retried, and the watermark must not
  # advance past an alert nobody saw
  log "one or more posts failed; leaving the watermark and sent ledger untouched"
  exit 1
fi

# The posts are already out, so a commit that cannot be written is not a lost page -
# it is a page that will be sent AGAIN next hour (no watermark, no sent ledger). That
# duplicate is the honest outcome; reporting this tick as committed is not.
if ! python3 "$HYDRA_ROOT/scripts/churn/cancel_alert.py" --policy "$POLICY" --commit "$RUN"; then
  log "FATAL commit failed after delivery: watermark and sent ledger not written; the next tick re-pages"
  exit 1
fi
log "committed: watermark advanced, intake rows written"
degraded || exit 1
