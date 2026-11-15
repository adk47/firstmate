#!/usr/bin/env bash
# End-to-end demonstration of the watchdog backlog pass with a held item.
set -u
REPO=/home/aaron/.no-mistakes/worktrees/72295860b10d/01M7EZC93JKDGVF17SARE43GVE
. "$REPO/tests/lib.sh"
# The test file sources lib.sh relative to itself; give it a harmless stand-in
# so we can reuse its fixtures without re-running the whole suite.
: > /tmp/lib.sh
sed -n '1,1313p' "$REPO/tests/fm-watchdog-worker.test.sh" > /tmp/fm-held-orphan-fixtures.sh
. /tmp/fm-held-orphan-fixtures.sh

# A base-commit copy of the watchdog, with every sibling bin/ helper symlinked
# from the repo, so the same scenario can be run before and after the fix.
rm -rf /tmp/fm-base
mkdir -p /tmp/fm-base/bin
for f in "$REPO"/bin/*; do ln -s "$f" "/tmp/fm-base/bin/$(basename "$f")"; done
rm /tmp/fm-base/bin/fm-watchdog-worker.sh
git -C "$REPO" show ded7c6daec66017f89d0dbfd8fe50ebb558f9e73:bin/fm-watchdog-worker.sh > /tmp/fm-base/bin/fm-watchdog-worker.sh
chmod +x /tmp/fm-base/bin/fm-watchdog-worker.sh

run_scenario() {  # <label> <check>
  local label=$1 check=$2 home now out
  CHECK=$check
  home=$(make_home "held-orphan-$label")
  fake_tools "$home"
  worker "$home" w1 alive
  pane "$home" w1 idle 'fine'
  # ghost-lane is genuinely unservable; parked-lane is held by the captain.
  backlog_bin_split "$home" w1 ghost-lane parked-lane -- parked-lane
  now=$(start_clock)
  echo "=== $label: pass 1, parked-lane is held, ghost-lane is not ==="
  out=$(tick "$home" "$now" FM_WATCHDOG_BACKLOG=on FM_WATCHDOG_BACKLOG_BIN="$home/fakebin/tasks-axi")
  printf '%s\n' "$out"
  echo '--- wakes queued ---'
  wakes "$home"
  echo
  echo "=== $label: pass 2, captain releases parked-lane ==="
  backlog_bin_split "$home" w1 ghost-lane parked-lane --
  out=$(tick "$home" "$((now + 300))" FM_WATCHDOG_BACKLOG=on FM_WATCHDOG_BACKLOG_BIN="$home/fakebin/tasks-axi")
  printf '%s\n' "$out"
  echo '--- wakes queued ---'
  wakes "$home"
  echo
}

run_scenario before-fix /tmp/fm-base/bin/fm-watchdog-worker.sh
run_scenario after-fix "$REPO/bin/fm-watchdog-worker.sh"
