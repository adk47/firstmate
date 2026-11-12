#!/usr/bin/env bash
# Daily: Caroline's resolution rate and the count of customers still waiting, posted to #clio_devops.
#
# The measurement is scripts/support-resolution-daily.py (READ-ONLY on Intercom and on the safety ledger; see its
# header for what "resolved" and "still waiting" mean). This wrapper only runs it and posts what it printed:
#   rc 0  the day's line is posted as it stands;
#   rc 3  UNMEASURED: the line says so and is posted, and no rate is ever made up for the day;
#   else  the run failed: one line says so.
# The unit exits with the measurement's own code, so a day with no number is a failed unit (OnFailure pages
# #clio_devops), never a quiet one. A low rate never fails the unit: it is a daily number, not an alarm.
# Systemd: support-resolution-daily.{service,timer} (scripts/install-aux-units.sh). Doc: docs/support/resolution-daily.md.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NO_POST=0
[ "${1:-}" = "--no-post" ] && { NO_POST=1; shift; }

out="$(python3 "$HERE/support-resolution-daily.py" "$@" 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] && [ "$rc" -ne 3 ]; then
  out="Caroline resolution daily: the run FAILED (rc=$rc), so there is no number for this day. $(printf '%s' "$out" | tail -n 1 | head -c 300)"
fi
printf '%s\n' "$out"

if [ "$NO_POST" -eq 0 ]; then
  # shellcheck source=scripts/lib/slack-notify.sh
  source "$HERE/lib/slack-notify.sh"
  slack_notify "$out"
fi
exit "$rc"
