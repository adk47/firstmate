#!/usr/bin/env bash
# End-to-end product scenario for the 2026-11-14 Orca incident, driven through
# the watchdog's real CLI with its documented test seams (fake backend binaries
# and fixture endpoint state). Prints a transcript a reviewer can read.
set -u
REPO=/home/aaron/.no-mistakes/worktrees/72295860b10d/01M7EHBJFQVMAE8QPDM6JKTNV7
cd "$REPO" || exit 1
# Load the test harness helpers only (up to start_clock), never the test list.
. tests/lib.sh
eval "$(sed -n '17,245p' tests/fm-watchdog-worker.test.sh)"

hr() { printf '\n===== %s =====\n' "$*"; }

hr "SCENARIO A: ten Orca lanes with dead endpoints (control relaunch structurally refuses)"
home=$(make_home evidence-refused); fake_tools "$home"
CONTROL_OVERRIDE="$home/fakebin/fake-control-refuses"
now=$(start_clock)
for i in $(seq 1 10); do worker "$home" "lane$i" dead ship pi orca; done
for step in 0 1 2 3 4 5; do
  out=$(tick "$home" "$((now + step * 60))")
  printf 'pass %s: control relaunch attempts=%s  wakes=%s  rel="%s"\n' \
    "$step" "$(counter "$home" '^control .* relaunch')" \
    "$(wakes "$home" | wc -l | tr -d ' ')" \
    "$(jq -r '.tasks.lane1.refusal' "$home/state/.watchdog-worker.json" 2>/dev/null)"
  [ "$step" = 0 ] && printf '%s\n' "$out" | grep 'watchdog:' | head -4
done
printf '\nAfter six 5-minute passes in one hour:\n'
printf '  total control relaunch attempts for all ten lanes: %s (was: 3 per lane per hour = 30)\n' \
  "$(counter "$home" '^control .* relaunch')"
printf '  "cannot relaunch" firstmate wakes: %s (one per lane, not one per pass)\n' \
  "$(wakes "$home" | grep -c 'cannot relaunch')"
printf '  "hourly relaunch budget" pages: %s (a refusal spends no budget)\n' \
  "$(wakes "$home" | grep -c 'hourly relaunch budget')"
printf '  persisted relaunch budget entries for lane1: %s\n' \
  "$(jq -r '.tasks.lane1.relaunches | length' "$home/state/.watchdog-worker.json")"
printf '  sample wake: %s\n' "$(wakes "$home" | grep 'cannot relaunch' | head -1)"

hr "SCENARIO B: an Orca terminal Orca itself reports gone is replaced with a new terminal in the recorded worktree"
home=$(make_home evidence-spawn); fake_tools "$home"
worker "$home" caroline-monitor-and-fixloop-k2 missing ship pi orca
now=$(start_clock)
out=$(tick "$home" "$now")
printf '%s\n' "$out" | grep 'watchdog:'
printf '  control relaunch attempts: %s\n' "$(counter "$home" '^control .* relaunch')"
printf '  fm-spawn --relaunch calls: %s\n' "$(counter "$home" '^spawn caroline-monitor-and-fixloop-k2 --relaunch')"
printf '  firstmate wakes: %s\n' "$(wakes "$home" | wc -l | tr -d ' ')"
printf '  carry-over note delivered to the replacement:\n'
sed -n '1,3p' "$home/steers" | sed 's/^/    /'

hr "SCENARIO C: an unread steering inbox whose relaunch keeps failing (timeout) is charged to the hourly budget, then escalates once"
home=$(make_home evidence-inbox); fake_tools "$home"
CONTROL_OVERRIDE="$home/fakebin/fake-control-refuses"
: > "$home/units/control-transient"
worker "$home" w1 alive
pane "$home" w1 idle 'waiting'
steer "$home" w1 5500
now=$(start_clock)
for step in 0 1 2 3 4 5; do
  tick "$home" "$now" >/dev/null
  printf 'pass %s: attempts=%s  charged=%s  inbox pages=%s\n' \
    "$step" "$(counter "$home" '^control w1 relaunch')" \
    "$(jq -r '.tasks.w1.relaunches | length' "$home/state/.watchdog-worker.json")" \
    "$(wakes "$home" | grep -c 'hourly relaunch budget')"
done
printf '  sample wake: %s\n' "$(wakes "$home" | grep 'hourly relaunch budget')"
printf '  inbox rung claimed (istage, should stay 0): %s\n' \
  "$(jq -r '.tasks.w1.istage' "$home/state/.watchdog-worker.json")"
