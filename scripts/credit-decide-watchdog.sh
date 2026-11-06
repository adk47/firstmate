#!/usr/bin/env bash
# [key=doc-approval-doctrine] The delivery half of the doc-verified T0/T1 class's two alerts.
#
# The python half (scripts/credit-decide-watchdog.py) evaluates and prints either NO_REPLY
# or one Slack line per firing alert. This wrapper is the only thing that POSTS.
#
# Why a wrapper instead of posting from python: every other hydra watchdog delivers through
# scripts/lib/slack-notify.sh, which is where the channel, the bot token and the real
# <@UID> mention handling live. Keeping delivery here means the alert text can never be
# posted by a path that skips mention resolution (a literal @name pings nobody).
#
# NO_REPLY (or empty) is silent by design: a healthy class, a DORMANT class and an
# unreadable store all print nothing to stdout, and the numbers go to stderr/the cron log.
#
# A watchdog that cannot run PAGES that fact. Silence must never be ambiguous between
# "nothing to say" and "the watcher is dead".
#
# env:
#   CREDIT_DECIDE_WATCHDOG_NOTIFY=never   dry run: print the line, post nothing
#   SLACK_CHANNEL / the slack-notify default channel apply as usual
set -uo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PY="${PYTHON_BIN:-python3}"
WATCHDOG="$HERE/credit-decide-watchdog.py"
NOTIFY="$HERE/lib/slack-notify.sh"

post() {  # post <text>
    local text="$1"
    if [ "${CREDIT_DECIDE_WATCHDOG_NOTIFY:-}" = "never" ]; then
        printf '%s\n' "$text"
        return 0
    fi
    if [ ! -r "$NOTIFY" ]; then
        printf 'credit-decide-watchdog: %s is missing, cannot post: %s\n' "$NOTIFY" "$text" >&2
        return 1
    fi
    # shellcheck disable=SC1090
    . "$NOTIFY"
    slack_notify_critical "$text"
}

# A planned fleet maintenance window stops the scheduled jobs on purpose, so "0 approvals in 6h"
# is the window talking, not a stalled decider - and paging through it is how a p3 alert becomes
# wallpaper. The python half checks this too; checking here as well means a window costs no python
# start and no ledger read.
# shellcheck source=lib/maintenance-flag.sh
source "$HERE/lib/maintenance-flag.sh"
if maintenance_active; then
    printf 'credit-decide-watchdog: maintenance: %s - skipping\n' "$(maintenance_reason)" >&2
    exit 0
fi

err="$(mktemp "${TMPDIR:-/var/tmp}/credit-decide-watchdog.XXXXXX")"
trap 'rm -f "$err"' EXIT
out="$("$PY" "$WATCHDOG" "$@" 2>"$err")"
rc=$?
if [ -s "$err" ]; then
    sed 's/^/credit-decide-watchdog: /' "$err" >&2
fi
if [ "$rc" -ne 0 ]; then
    post ":rotating_light: the doc-verified T0/T1 watchdog is NOT running (exit $rc): nothing is watched for a stalled class. \`python3 scripts/credit-decide-watchdog.py --json\` on node-8."
    exit "$rc"
fi
case "$out" in
    ""|NO_REPLY) exit 0 ;;
esac
post "$out"
