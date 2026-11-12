#!/usr/bin/env bash
# gdpr-dsar-clock-check.sh - the GDPR statutory clock as a firstmate alarm.
#
# A request inside 7 days of its statutory date, or past it, or two days old with no first message from us, wakes
# FIRSTMATE and is named. It never waits for a person to notice a channel. Contract of a firstmate registered check:
# one line on stdout means "wake firstmate", silence means "nothing to do".
#
# It prints one line when
#   - the set of requests the clock names has changed since the last line (a request entered the window, passed
#     its date, or was answered), or
#   - the UTC day has changed and that set is still not empty (a standing breach is repeated daily, not every sweep), or
#   - the clock could not be read, or is not deployed on the host yet. An unread clock is not a clear one, so that
#     is a line too (once a day).
# and nothing when the clock names no request.
#
# The clock itself is node-8's: `gdpr-pipeline.py dsar clock --line` (scripts/gdpr_pipeline/dsar.py clock_rows).
# This script only carries it to firstmate: node-8 has no route into the firstmate box, so the read is a pull.
# `--read-by firstmate` leaves a mark on the host each time the clock is read, and `gdpr-dsar-clock.timer` there
# (scripts/install-aux-units.sh) pages when requests are named and that mark is more than 26 h old
# (dsar.clock_unread): a check that was never registered, or stopped, is loud on the other side.
#
# REGISTERED by this repository, not by hand: `scripts/gdpr-dsar-clock-register.sh` puts this file into a firstmate
# home and binds it to its bytes (the watcher refuses a check that is not), `--check` says whether a home has THESE
# bytes, `--unregister` retires it. Registered before the deploy, it says "not deployed" once a day until the clock
# is on the host. Every read carries this file's own sha256 (`--reader-sha`), so the host can tell a check that is
# reading from the check that is deployed, and pages when they differ: a registration that went stale is loud too.
#
# ONE ssh round trip, inside the watcher's 30 s per-check limit (FM_CHECK_TIMEOUT): a check the watcher kills prints
# nothing, and nothing reads as "clear". 97 is this script's own code for "the clock is not on the host".
set -u

HOST="${GDPR_CLOCK_HOST:-root@40.160.32.80}"
ROOT="${GDPR_CLOCK_ROOT:-/opt/hydra}"
# The watcher runs a private copy of the registered bytes, so this is the sha256 the trust record names.
SELF=$(sha256sum "$0" 2>/dev/null | cut -d' ' -f1)
CLOCK="${GDPR_CLOCK_REMOTE:-python3 $ROOT/scripts/gdpr-pipeline.py dsar clock --line --read-by firstmate --reader-sha ${SELF:-unknown}}"
STAMP_DIR="${GDPR_CLOCK_STATE:-${XDG_STATE_HOME:-$HOME/.local/state}/gdpr-dsar-clock}"
STAMP="$STAMP_DIR/last"
NOT_DEPLOYED=97

# shellcheck disable=SC2029  # expanded here on purpose: the remote runs the command this side composed
line=$(ssh -o BatchMode=yes -o ConnectTimeout=8 -o ServerAliveInterval=5 -o ServerAliveCountMax=3 "$HOST" \
  "test -f $ROOT/scripts/gdpr_pipeline/dsar.py || exit $NOT_DEPLOYED; $CLOCK" 2>/dev/null)
rc=$?
if [ "$rc" -eq "$NOT_DEPLOYED" ]; then
  line="GDPR clock: not deployed on ${HOST#*@} yet, so no statutory date is being watched for firstmate. It starts when this repo's deploy lands there"
elif [ "$rc" -ne 0 ]; then
  line="GDPR clock: could not be read from ${HOST#*@} (rc $rc). An unread clock is not a clear one: run '$CLOCK' there"
fi
line=$(printf '%s' "$line" | head -n 1)

mkdir -p "$STAMP_DIR" 2>/dev/null || true
if [ -z "$line" ]; then
  rm -f "$STAMP"
  exit 0
fi

# The day counts in the line ("12 d past") roll over at each request's own time of day, so the key drops them: it is
# the UTC day plus the counts and the request numbers named.
key="$(date -u +%F) $(printf '%s' "$line" | sed -E 's/ \([^)]*\)//g')"
if [ -f "$STAMP" ] && [ "$(cat "$STAMP" 2>/dev/null)" = "$key" ]; then
  exit 0
fi
printf '%s\n' "$line"
printf '%s' "$key" > "$STAMP" 2>/dev/null || true
exit 0
