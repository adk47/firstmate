#!/usr/bin/env bash
# NIGHTLY churn support-state refresh (firstmate spec churn-risk-signal-prevent-p1
# items 1 and 2). Builds the store the risk file and every consumer read:
#
#   1. --paying              every user in /var/lib/credit-trust/paying-users.json
#                            (who is waiting on US right now: the PREVENT signal)
#   2. --churned-since 30d   everyone who cancelled in the last 30 days, so a
#                            churned-with-issue user stays paid-priority for the
#                            30 d R4 asks for, and the Monday line has a window
#   3. risk.py               publish /var/lib/hydra/churn/risk.json from the store
#
# Read-only against Intercom, the core replica, the ledger and proof stores. The
# only writes are the churn store and risk.json.
#
# The kill switch (/etc/hydra/churn-risk.disabled) deliberately does NOT stop this:
# consumers stop overriding their order and the alert stops paging, but the record
# of who was waiting keeps building, so turning the switch back off never loses
# history. A stale paying sweep is refused by risk.py (fail-closed), which is what
# keeps a stale file from silently reordering anybody.
#
#   CHURN_DRY_RUN=1       read everything, write nothing
#   CHURN_LIMIT=200       canary: cap BOTH sweeps' user set
set -uo pipefail
HYDRA_ROOT="${HYDRA_ROOT:-/opt/hydra}"
POLICY="${CHURN_RISK_POLICY:-$HYDRA_ROOT/policies/churn-risk.json}"
# the policy owns every path this run touches, the lock included: a separate override
# would put the lock somewhere the store is not
STATE_ROOT="$(python3 -c 'import json,sys;print((json.load(open(sys.argv[1])).get("store") or {}).get("dir") or "/var/lib/hydra/churn")' "$POLICY" 2>/dev/null || echo /var/lib/hydra/churn)"
DRY_RUN="${CHURN_DRY_RUN:-0}"
LIMIT="${CHURN_LIMIT:-0}"
MAIN_ENV="${MAIN_ENV:-/etc/openclaw/main.env}"

install -d -m 700 "$STATE_ROOT"
LOCK="$STATE_ROOT/nightly.lock"
exec 9>"$LOCK"
# a sweep that is still running from last night is a real condition (Intercom
# budget, a slow replica): skip rather than stack two writers on one store
flock -n 9 || { echo "$(date -u +%FT%TZ) another nightly sweep holds $LOCK"; exit 0; }

log() { echo "$(date -u +%FT%TZ) $*"; }
[ -r "$POLICY" ] || { log "FATAL policy missing: $POLICY"; exit 1; }
# shellcheck source=/dev/null
[ -r "$MAIN_ENV" ] && { set -a; . "$MAIN_ENV"; set +a; }

ARGS=(--policy "$POLICY")
[ "$DRY_RUN" = "1" ] && ARGS+=(--dry-run)
[ "$LIMIT" != "0" ] && ARGS+=(--limit "$LIMIT")

FAILED=0
log "paying sweep start"
if ! python3 "$HYDRA_ROOT/scripts/churn/support_state.py" --paying "${ARGS[@]}"; then
  log "paying sweep FAILED"
  FAILED=1
fi
log "churned sweep start (30d)"
if ! python3 "$HYDRA_ROOT/scripts/churn/support_state.py" --churned-since 30d "${ARGS[@]}"; then
  log "churned sweep FAILED"
  FAILED=1
fi
# A failed sweep means risk.py must not publish AT ALL. Its own guard only refuses a
# run that is older than thresholds.risk_max_age_hours, and yesterday's successful run
# is ~24h old inside that window: publishing it again would stamp yesterday's rows as
# fresh and keep consumers trusting a state that today's run could not confirm (QA #1771).
# Returning nonzero after publishing does not undo the file, so skip the call.
#
# A LIMITED run is the other way to publish a wrong file: CHURN_LIMIT is the canary
# knob, and its sweep records a finished run over a slice of the paying set. A risk
# file built from that slice says "nobody else is waiting on us", which drops the
# fleet's sort override for everyone the canary did not look at. Never publish it.
if [ "$LIMIT" != "0" ]; then
  log "canary run (CHURN_LIMIT=$LIMIT): risk.json NOT published; a partial sweep must not replace the fleet's file"
elif [ "$FAILED" != "0" ]; then
  log "a sweep FAILED: risk.json NOT published; yesterday's rows must not be restamped as fresh"
elif [ "$DRY_RUN" = "1" ]; then
  python3 "$HYDRA_ROOT/scripts/churn/risk.py" --policy "$POLICY" --dry-run
else
  python3 "$HYDRA_ROOT/scripts/churn/risk.py" --policy "$POLICY" || { log "risk.json build FAILED"; FAILED=1; }
fi
log "done (failed=$FAILED)"
exit "$FAILED"
