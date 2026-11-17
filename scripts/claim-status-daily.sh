#!/usr/bin/env bash
# claim-status-daily.sh — the durable claim-status wave on node-8 (claim-lane-resume-c2, firstmate 040/042;
# captain 2026-10-27 20:1xZ: "make this a durable process that does not rely on my computer; do this all on
# OVH"). Installed as /etc/cron.d/hydra-claim-status by scripts/install-aux-units.sh (shipped by deploy).
#
# AUDIT ONLY - AND THAT IS THE SCOPE, NOT A GAP LEFT UNSTATED (QA on #1406 @396a700a): this wave delivers
# nothing. The delivery wiring is the daily signed rebuild (#1634) plus credit-verify-outbound's claim family;
# until that PR is merged, a qualifying pending claimant gets no note from here, and that is deliberate - one
# sender per family, and the only sender is the signed list. The run.log line is labelled AUDIT so its counts
# can never be read as sends.
# ONE SENDER PER FAMILY. The cron line runs MODE=dry-run: every run BUILDS the audience from live reads (core
# replica via Trino + the catalog via `muso api`): ONLY holds and organizations WITH a bindable page (WS2 lead,
# firstmate 042; module docstring of scripts/credit_review/claim_status_list.py), audits it per segment, and
# sends NOTHING. The audience is ONE definition - this module's reads (facts, bound_surfaces; #1634's builder
# uses the same ones over the deployed decider's dry-run lines) - and the claim-status SENDS come only from the
# daily signed rebuild's list, through credit-verify-outbound's claim family, signed on the deployed head
# (#1590). MODE=apply still exists for a human one-off with a wired code and is never what cron runs: a second
# 01:15Z apply would be a second sender for one family, publishing sends whose audience and policy predate the
# head - the discipline this lane upheld all night (Fable driver, 11-03 20:2xZ).
# When it does send (a human apply), it sends the approved claim-status
# note (Fable ruling 3, wording D) paid first, then free, through Caroline's gate:
#   - one note per claim ever, one message per user per UTC day (all campaigns), the 7-day core-marker
#     deferral (core_notice_within_7d), the support@ hold, a replica re-check of each claim;
#   - at most CLAIM_STATUS_DAILY_MAX (400) a day; the p2 health guard after each segment (bounce > 2%,
#     any spam complaint, unsub > 1%, or unreadable -> stop). The health guard is a SEND-time read and runs only
#     on a human apply: on the cron path (dry-run) the send-time guard is credit-verify-outbound's own
#     (health_check.py over the run + the zero-read verdict + both kill switches). That lane's claim family is
#     where a bounce/complaint stop now has to bite; this wave can see the same numbers in its audit line only;
#   - one count line per run in /var/lib/hydra/credit-review/run.log ("claim-status-daily {...}").
# Kill switches (either stops the run before anything is built or sent):
#   touch /etc/hydra/claim-status-daily.disabled      (this wave only)
#   touch /etc/hydra/credit-ops-notes.disabled        (every status note)
# MODE=dry-run (the cron) builds the list and renders nothing live; the run.log line is an audit of "would send".
# Exit codes: 0 clean, 1 a list that could not be built / a segment failed or the health guard stopped,
# 2 bad MODE, and 3 CATALOG_UNREADABLE - the catalog answered for at most half the pending profiles, so the
# wave is a FAILED run and must page, never a clean run that told nobody (r3 on hydra #1406).
# EVERY NON-ZERO EXIT PAGES (c2 follow-up, Fable driver 11-04 08:4xZ). "must page" was a claim about a code
# path, not a delivery: cron keeps no exit code, so a night that failed to build - or built a list from half
# an unreachable catalog - left a log line nobody reads and looked exactly like a clean night. Delivery goes
# through scripts/lib/deploy-notify.sh, which RETURNS Slack's own status (slack_notify swallows it and returns
# 0, so a rejected post would otherwise be a silent non-page). A page that cannot be delivered is written as
# PAGE NOT DELIVERED plus the reason, and the run's own exit code is never changed by it: rc is the operating
# signal, the page is the human one. There is no cooldown because the cadence is once a day - a standing
# failure is one page a day, which is the actionable rate (notify-unit-failed.sh's 24h argument).
set -uo pipefail
HYDRA_ROOT="${HYDRA_ROOT:-/opt/hydra}"
MODE="${MODE:-dry-run}"
MAIN_ENV="${MAIN_ENV:-/etc/openclaw/main.env}"
STATE_ROOT="${STATE_ROOT:-/var/lib/hydra/credit-review}"
LOCK="$STATE_ROOT/claim-status-daily.lock"
# _page <rc> <why> - one page per failed run; never changes the run's exit code (see the header).
_page() {
  local rc="$1" why="$2"
  local notifier="${CLAIM_STATUS_NOTIFY_BIN:-$HYDRA_ROOT/scripts/lib/deploy-notify.sh}"
  local msg
  msg="claim-status-daily MODE=$MODE FAILED rc=$rc on $(hostname -s 2>/dev/null || echo node): $why"
  local out
  if [ ! -r "$notifier" ]; then
    echo "$(date -u +%FT%TZ) PAGE NOT SENT (no notifier at $notifier); rc=$rc stands"
    return 0
  fi
  if out="$(bash "$notifier" critical "$msg" 2>&1)"; then
    echo "$(date -u +%FT%TZ) paged critical: rc=$rc"
  else
    echo "$(date -u +%FT%TZ) PAGE NOT DELIVERED: $(printf '%s' "$out" | tail -2 | tr '\n' ' ' | cut -c1-300); rc=$rc stands"
  fi
}

# The lock comes AFTER the pager, and every way it can FAIL pages. r5 on #1741 (QA's Important): with the lock path
# unopenable - a directory, a read-only state root - the redirect printed "Is a directory", flock said "Bad file
# descriptor", and the script reported "another claim-status-daily run holds it" and exited 0: the audit did not run,
# and the one signal said a peer hold it while the truth was a standing condition needing a human. A state reported
# as healthy because the code could not reach the line that reports. A lock that is genuinely HELD stays silent and
# exits 0 below - that one is benign and self-clearing, and it must not page.
if ! install -d -m 700 "$STATE_ROOT"; then
  echo "$(date -u +%FT%TZ) cannot create the state root $STATE_ROOT: nothing was built or sent"
  _page 1 "cannot create the state root $STATE_ROOT (the lock and the run log live there)"
  exit 1
fi
if ! exec 9>"$LOCK"; then
  echo "$(date -u +%FT%TZ) cannot open the lock $LOCK: nothing was built or sent"
  _page 1 "cannot open the lock $LOCK: unopenable, so no run can start until it is fixed"
  exit 1
fi
flock -n 9 || { echo "$(date -u +%FT%TZ) another claim-status-daily run holds $LOCK; exit"; exit 0; }
case "$MODE" in
  apply|dry-run) ;;
  # A misconfigured cron is a standstill - the wave will not run again until someone reads this - which is exactly
  # the case a page is for (r5 on #1741: exit 2 paged nobody because it preceded the pager). It is paged as rc=2
  # with the bad value named, so the fix is one edit away instead of one investigation away.
  *) echo "$(date -u +%FT%TZ) MODE must be apply or dry-run (got '$MODE')"
     _page 2 "MODE='$MODE': the cron will not run the wave until this is corrected"
     exit 2 ;;
esac
# The Intercom token lives in main.env on node-8 (secrets; not in the repo). The warm-up settings do NOT: main.env
# carries no warm/ceiling/cap/limit key (83 keys, read 2026-11-16). The ceiling is WARMUP_CEILINGS in H-DevOps
# k8s/prod/messaging/78-send-gateway.yaml (notify 3,000, allocated credit 2,500 / claim 500), enforced by the gateway's
# route_ceiling gate - which defers a send to the next UTC midnight when it fires, so the ceiling a run actually meets is
# read from its `route_ceiling` answer, never inferred from a file.
set -a
# shellcheck source=/dev/null
. "$MAIN_ENV" || { echo "$(date -u +%FT%TZ) $MAIN_ENV unreadable: nothing sent (fail closed)"; _page 1 "$MAIN_ENV unreadable: nothing was built and nothing was sent"; exit 1; }
set +a
echo "== $(date -u +%FT%TZ) claim-status-daily MODE=$MODE"
python3 "$HYDRA_ROOT/scripts/credit-review.py" claim-status-daily --mode "$MODE"
rc=$?
echo "== $(date -u +%FT%TZ) done rc=$rc"
if [ "$rc" -ne 0 ]; then
  _page "$rc" "$(tail -1 "$STATE_ROOT/run.log" 2>/dev/null | cut -c1-400)"
fi
exit "$rc"
