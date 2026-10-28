#!/usr/bin/env bash
# bats-slot.sh — run a command inside a HOST-WIDE slot, so N CI jobs on one box cannot
# each spawn a full bats suite at the same time.
#
# WHY (2026-10-27, Fable ruling on hydra #1403). hydra's PR Validation runs
# `bats --jobs 8` (now 4) per job on `[self-hosted, hydra]`, and node-8 hosts several
# hydra-labelled runner services. A workflow-level `concurrency` group cannot express
# "at most one suite per HOST" (GitHub has no such scope, and a constant group throws
# away the per-ref supersede-cancellation we need). The cap that matches the resource
# is therefore on the host: an exclusive flock. Five overlapping validations measured
# run queue 15 -> 68, load 13 -> 39, 344k ctx switches/s, 10 % idle, CPU-pressure PSI
# 26 -> 52 % on a 24-core box that ALSO runs the production openclaw gateway, and the
# timing-sensitive watchdog suites then failed on a DIFFERENT unrelated test each
# attempt.
#
# CONTRACT
#   * At most ONE holder per lock path (per host). Everyone else waits.
#   * Waiting is bounded: on timeout this exits non-zero with an ::error:: line —
#     never silently skipping the suite and never running unslotted. An unslotted run
#     is exactly the failure this replaces.
#   * The lock is released when the command exits, including on SIGTERM/SIGINT, because
#     the fd is closed by the shell on exit.
#
# Usage: bats-slot.sh [--lock PATH] [--timeout SECS] -- <command> [args...]
set -uo pipefail

LOCK=${BATS_SLOT_LOCK:-/var/lock/hydra-bats.lock}
TIMEOUT=${BATS_SLOT_TIMEOUT:-2700}
while [ $# -gt 0 ]; do
  case "$1" in
    --lock)    LOCK=${2:?--lock needs a path}; shift 2 ;;
    --timeout) TIMEOUT=${2:?--timeout needs seconds}; shift 2 ;;
    --)        shift; break ;;
    *)         break ;;
  esac
done
[ $# -gt 0 ] || { echo "::error::bats-slot.sh: no command given" >&2; exit 2; }
case "$TIMEOUT" in ''|*[!0-9]*) echo "::error::bats-slot.sh: --timeout must be an integer" >&2; exit 2 ;; esac

mkdir -p "$(dirname "$LOCK")" 2>/dev/null || true
# The lock FILE is not removed: unlinking a flock'd path lets a second process create a
# fresh inode and take the "same" lock concurrently. It is a rendezvous, not state.
exec 9>"$LOCK" || { echo "::error::bats-slot.sh: cannot open lock $LOCK" >&2; exit 2; }

start=$SECONDS
if ! flock -w "$TIMEOUT" 9; then
  echo "::error::bats-slot.sh: could not acquire $LOCK within ${TIMEOUT}s — another CI suite is still running on this host. Refusing to run UNSLOTTED: overlapping suites are what made the watchdog tests flake on 2026-10-27 (load 39, CPU pressure 52 %, 10 % idle)." >&2
  exit 1
fi
waited=$((SECONDS - start))
[ "$waited" -gt 5 ] && echo "bats-slot.sh: acquired $LOCK after ${waited}s"

"$@"
rc=$?
echo "bats-slot.sh: released $LOCK (command rc=$rc)"
exit "$rc"
