#!/usr/bin/env bash
# The ONE writer of /etc/cron.d/hydra-churn-risk (firstmate churn-risk-signal-prevent-p1).
#
# install-aux-units.sh calls this instead of carrying a heredoc, so the cron file has a
# single author and the test suite can EXECUTE it against a temp root and assert what it
# installed instead of grepping the installer's source text (firstmate 2026-11-04:
# "run the installer into a temp root, assert the installed results, no source-text
# greps"). A commented-out or duplicated heredoc in the installer can no longer pass.
#
#   CRON_DIR    where the cron.d file goes      (default /etc/cron.d)
#   STATE_DIR   the churn store + logs          (default /var/lib/hydra/churn)
#   HYDRA_ROOT  the deployed repo               (default /opt/hydra)
#
# The schedule, and why it is this schedule:
#   04:15Z daily      support-state sweep: --paying (who is waiting on us now) and
#                     --churned-since 30d (R4's 30-day paid priority), then one
#                     risk.json publish. After the nightly batch window, before the
#                     morning queue drain.
#   :20 hourly        a paying user who cancelled (or asked to cancel) with an open
#                     issue pages ops and writes the lane intake row tagged
#                     `churned:<date>`. :20 keeps it clear of the credit ticks.
#   Monday 08:00Z     the churned-with-open-issue line for the week.
#
# /etc/hydra/churn-risk.disabled stops the page and the consumers' sort override; the
# sweep keeps building the store, so turning the switch back off loses no history.
set -euo pipefail

CRON_DIR="${CRON_DIR:-/etc/cron.d}"
STATE_DIR="${STATE_DIR:-/var/lib/hydra/churn}"
HYDRA_ROOT="${HYDRA_ROOT:-/opt/hydra}"

log() { echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] install-churn-cron: $*"; }

[[ -d "$CRON_DIR" ]] || { log "FATAL cron dir missing: $CRON_DIR"; exit 1; }
install -d -m 700 "$STATE_DIR"

cat > "$CRON_DIR/hydra-churn-risk" << CRONCHURN
# MANAGED BY scripts/install-aux-units.sh — DO NOT EDIT BY HAND.
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
15 4 * * * root $HYDRA_ROOT/scripts/churn/nightly.sh >> $STATE_DIR/nightly.log 2>&1
20 * * * * root $HYDRA_ROOT/scripts/churn/cancel_with_open_issue.sh >> $STATE_DIR/alert.log 2>&1
0 8 * * 1 root $HYDRA_ROOT/scripts/churn/weekly_line.sh >> $STATE_DIR/weekly.log 2>&1
CRONCHURN
chmod 644 "$CRON_DIR/hydra-churn-risk"
log "installed $CRON_DIR/hydra-churn-risk (state $STATE_DIR, root $HYDRA_ROOT)"
