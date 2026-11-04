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
set -uo pipefail
HYDRA_ROOT="${HYDRA_ROOT:-/opt/hydra}"
MODE="${MODE:-dry-run}"
MAIN_ENV="${MAIN_ENV:-/etc/openclaw/main.env}"
STATE_ROOT="${STATE_ROOT:-/var/lib/hydra/credit-review}"
LOCK="$STATE_ROOT/claim-status-daily.lock"
install -d -m 700 "$STATE_ROOT"
exec 9>"$LOCK"; flock -n 9 || { echo "$(date -u +%FT%TZ) another claim-status-daily run holds $LOCK; exit"; exit 0; }
case "$MODE" in apply|dry-run) ;; *) echo "$(date -u +%FT%TZ) MODE must be apply or dry-run (got '$MODE')"; exit 2 ;; esac
# The Intercom token and the warm-up settings live in main.env on node-8 (secrets; not in the repo).
set -a
# shellcheck source=/dev/null
. "$MAIN_ENV" || { echo "$(date -u +%FT%TZ) $MAIN_ENV unreadable: nothing sent (fail closed)"; exit 1; }
set +a
echo "== $(date -u +%FT%TZ) claim-status-daily MODE=$MODE"
python3 "$HYDRA_ROOT/scripts/credit-review.py" claim-status-daily --mode "$MODE"
rc=$?
echo "== $(date -u +%FT%TZ) done rc=$rc"
exit "$rc"
