#!/usr/bin/env bash
# fm-lock-reap.sh - sweep this home's per-task lock leftovers whose holder is
# provably gone.
#
# Usage: fm-lock-reap.sh [--min-age <secs>]
#
# Scope: the task metadata locks (state/.meta-<id>.lock), their takeover locks
# (.meta-<id>.lock.steal), and every steering-inbox sequence lock
# (state/<id>.inbox/.seq.lock and its .steal). Other locks keep their own
# recovery owners; in particular the watcher, session, and wake-queue locks
# are never touched here.
#
# A lock is removed only when bin/fm-wake-lib.sh's fm_lock_reap_stale proves
# it: its pid record is at least --min-age seconds old (default
# FM_STALE_LOCK_REAP_SECS, 60) and its pid is dead or now names a process that
# started after the record was written. Every uncertainty keeps the lock.
# A holder killed while holding one of these locks (a timed-out reconcile, a
# killed fm-send) otherwise strands it until someone next contends, and every
# contender before that pays a takeover or a refused send.
#
# Output: one "[<timestamp>] lock-reap: reaped ..." line per removal on stdout,
# nothing when there was nothing to reap; the watcher appends it to its triage
# log on a FM_LOCK_REAP_INTERVAL cadence (bin/fm-watch.sh). Exit 0 unless the
# arguments are invalid.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

MIN_AGE=
while [ $# -gt 0 ]; do
  case "$1" in
    --min-age)
      [ $# -ge 2 ] || { echo "fm-lock-reap: --min-age requires seconds" >&2; exit 2; }
      MIN_AGE=$2
      shift 2
      ;;
    -h|--help)
      sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "fm-lock-reap: unknown argument: $1" >&2
      exit 2
      ;;
  esac
done
[ -n "$MIN_AGE" ] || MIN_AGE=$(fm_stale_lock_reap_secs)
case "$MIN_AGE" in ''|*[!0-9]*) echo "fm-lock-reap: --min-age must be whole seconds" >&2; exit 2 ;; esac

reap_log() {
  printf '[%s] lock-reap: %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$1"
}

for lock in "$STATE"/.meta-*.lock "$STATE"/.meta-*.lock.steal \
  "$STATE"/*.inbox/.seq.lock "$STATE"/*.inbox/.seq.lock.steal; do
  [ -e "$lock" ] || [ -L "$lock" ] || continue
  if line=$(fm_lock_reap_stale "$lock" "$MIN_AGE"); then
    reap_log "$line"
  fi
done
exit 0
