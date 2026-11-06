#!/usr/bin/env bats
# The SCHEDULE of the ClickUp scanner timers, so no two start in the same minute.
#
# Why this file exists: on 29 Oct 2026 three ClickUp scanners started inside the
# same three minutes on one shared 100 requests/min token, and all three got 429.
# Each timer's own test file passes whatever the minute is, so nothing pinned the
# spread. This file pins it. The minute map is in MUS-22605 (CTO design, point 4).
#
# Like its siblings, this reads the INSTALLER SOURCE: the real script writes to
# /etc/systemd/system and runs systemctl as root. It pins that the schedule is
# DECLARED, not that it was applied on a host.
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
INSTALLER="$HYDRA_REPO/scripts/install-aux-units.sh"

# Prints the body of one timer heredoc, from its `cat >` line to its closing tag.
timer_unit() {
  awk -v unit="$1" '
    index($0, "cat > /etc/systemd/system/" unit " << ") == 1 { tag = $NF; on = 1; next }
    $0 == tag { on = 0 }
    on
  ' "$INSTALLER"
}

@test "each ClickUp scanner timer has its staggered OnCalendar" {
  while read -r unit expected; do
    got="$(timer_unit "$unit" | grep '^OnCalendar=' | cut -d= -f2-)"
    [ "$got" = "$expected" ] || { echo "$unit: got '$got', want '$expected'"; false; }
  done <<'MAP'
close-resolved-conversations.timer *-*-* 02,08,14,20:25:00 UTC
overdue-verification-notifier.timer *-*-* 09:12:00 UTC
resolve-notify.timer *-*-* 02,08,14,20:25:00 UTC
merge-outcome-notify.timer *:05/15
resolution-matcher.timer *-*-* 12:14:00 UTC
clickup-todo-dedupe.timer *-*-* *:40:00
clickup-drain-profile-claim.timer *-*-* *:35:00
clickup-sla-digest.timer *-*-* 08:10:00 America/New_York
close-merged-tickets.timer *-*-* 07:12:00 UTC
MAP
}

@test "the closer has no OnUnitActiveSec, so it cannot drift off the resolve-notify tick" {
  ! grep -q '^OnUnitActiveSec=' <<< "$(timer_unit close-resolved-conversations.timer)"
}

@test "resolve-notify has no RandomizedDelaySec, so it fires on the closer's tick" {
  ! grep -q '^RandomizedDelaySec=' <<< "$(timer_unit resolve-notify.timer)"
}
