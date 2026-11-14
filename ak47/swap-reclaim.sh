#!/usr/bin/env bash
# ak47/swap-reclaim.sh - the slow half of swap pressure, kept out of the tick.
#
# `swapoff -a` on a full 32 GB swap takes tens of minutes: it has to find a home
# in RAM for every swapped page. That is far longer than the tick's own start
# timeout, so the tick cannot do it inline - it starts this unit and exits. This
# script owns the operation end to end: bounded swapoff, swap back on whatever
# happened, one line in swap.log, and a finding when it could not finish.
#
# Safety:
#   - swap is restored whatever swapoff did, including on failure, because a box
#     left with no swap is worse than a box with a full one
#   - the swapoff itself is bounded so a wedged device cannot pin this unit
#     forever; an interrupted swapoff leaves swap enabled, never off
#   - it never touches processes, containers, units or the fleet: swap pages are
#     the only thing that moves
set -u

ROOT=${AK47_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}
# shellcheck source=lib/common.sh
. "$ROOT/lib/common.sh"

budget=$AK47_SWAPOFF_BUDGET

if ! swap_privileged; then
  ak47_log "$AK47_STATE/swap.log" "$(ak47_epoch) swap-reclaim skipped: no privilege to stop and start swap; see the sudoers rule in ak47/README.md"
  exit 3
fi

before=$(ak47_swap_pct)
rc=0
swap_reclaim || rc=$?
after=$(ak47_swap_pct)
ak47_log "$AK47_STATE/swap.log" "$(ak47_epoch) swap-reclaim before=${before}% after=${after}% reclaimed_gb=${AK47_SWAP_RECLAIMED:-0} budget=${budget}s rc=${rc}"

if [ "$rc" -ne 0 ]; then
  # A reclaim that could not finish is a finding, not a silent retry: the tick
  # will start this unit again next time, and a line nobody reads is worse than
  # one that says what happened.
  INBOX_CLASS=${AK47_INBOX_CLASS:-health}
  "$FM_HOME/bin/fm-inbox.sh" note --source "$INBOX_CLASS" \
    "ak47 swap reclaim did not finish within ${budget}s (swap ${before}% -> ${after}%); swap is back on, and the next tick will try again" \
    >/dev/null 2>&1 || ak47_log "$AK47_STATE/findings.log" "$(ak47_epoch) DELIVERY-FAILED swap-reclaim-failed"
fi

exit "$rc"
