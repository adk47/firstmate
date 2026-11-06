#!/usr/bin/env bats
# The SCHEDULER wiring for the ClickUp data-deletion drainer.
#
# Why this file exists: tests/test_clickup_drain_data_deletion.py covers the
# drainer's behaviour in 45 cases, and every one of them passes with the systemd
# block in scripts/install-aux-units.sh DELETED. That is a fully tested program
# that never runs -- and a green suite is exactly what stops anyone looking. QA
# flagged `test-gap` on this installer for the dedupe sweeper for the same reason;
# same shape as install-aux-units-clickup-dedupe.bats.
#
# These assertions read the INSTALLER SOURCE rather than executing it: the real
# script writes to /etc/systemd/system and runs systemctl as root, which is not
# safe in a test. That is a real limitation -- it pins that the wiring is
# DECLARED, not that it was applied on a host.
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
INSTALLER="$HYDRA_REPO/scripts/install-aux-units.sh"

setup() {
  SVC="$(awk '/^cat > \/etc\/systemd\/system\/clickup-drain-data-deletion\.service/,/^CDDDDELETIONSVC$/' "$INSTALLER")"
  TMR="$(awk '/^cat > \/etc\/systemd\/system\/clickup-drain-data-deletion\.timer/,/^CDDDDELETIONTMR$/' "$INSTALLER")"
  export SVC TMR
}

@test "the installer exists and is executable" {
  [ -x "$INSTALLER" ]
}

@test "a service unit for the data-deletion drainer is installed" {
  [ -n "$SVC" ]
  grep -q '/etc/systemd/system/clickup-drain-data-deletion.service' <<< "$SVC"
}

@test "a timer unit for the data-deletion drainer is installed" {
  [ -n "$TMR" ]
  grep -q '/etc/systemd/system/clickup-drain-data-deletion.timer' <<< "$TMR"
}

@test "ExecStart actually invokes the drainer module" {
  grep -q 'scripts/clickup_drain/data_deletion\.py' <<< "$SVC"
}

@test "the script ExecStart names really exists and is executable" {
  # An ExecStart pointing at a moved or renamed file is the same outage as no
  # unit at all, and systemd only tells you at fire time.
  [ -x "$HYDRA_REPO/scripts/clickup_drain/data_deletion.py" ]
}

@test "the shared libraries the drainer imports really exist" {
  [ -f "$HYDRA_REPO/scripts/lib/clickup_client.py" ]
  [ -f "$HYDRA_REPO/scripts/lib/customer_outcome.py" ]
}

@test "the timer fires at :25 past every hour, clear of the other ClickUp scanners" {
  grep -qF 'OnCalendar=*-*-* *:25:00' <<< "$TMR"
}

@test "the timer is Persistent so a reboot does not silently skip a window" {
  grep -q 'Persistent=true' <<< "$TMR"
}

@test "the timer drives the matching service unit" {
  grep -q 'Unit=clickup-drain-data-deletion.service' <<< "$TMR"
}

@test "the service sets an explicit TimeoutStartSec" {
  # node-8 SIGTERMs any Type=oneshot unit that omits it, which kills the run
  # mid-pass -- after the writes but possibly before the read-back.
  grep -qE 'TimeoutStartSec=[0-9]+' <<< "$SVC"
}

@test "the service is Type=oneshot" {
  grep -q 'Type=oneshot' <<< "$SVC"
}

@test "the service loads the env files that carry the ClickUp and Slack keys" {
  # CLICKUP_API_KEY lives in main.env on node-8; without it the drainer exits
  # before scanning and the timer looks healthy while doing nothing.
  grep -q 'EnvironmentFile=-/etc/openclaw/main.env' <<< "$SVC"
  grep -q 'EnvironmentFile=-/etc/openclaw/shared.env' <<< "$SVC"
}

@test "the timer is enabled and started, not merely written to disk" {
  grep -q 'systemctl enable "\$cdd"' "$INSTALLER"
  grep -q 'systemctl start "\$cdd"' "$INSTALLER"
}

@test "daemon-reload runs so systemd actually picks the units up" {
  grep -q 'systemctl daemon-reload' "$INSTALLER"
}

@test "the installer pre-flights the drainer and its libraries before wiring them" {
  grep -q 'scripts/clickup_drain/data_deletion.py missing' "$INSTALLER"
  grep -q 'scripts/lib/clickup_client.py missing' "$INSTALLER"
  grep -q 'scripts/lib/customer_outcome.py missing' "$INSTALLER"
}

@test "ExecStart passes --apply: the unit must actually write" {
  # Shipping the timer in dry-run would be a drainer that reports forever and
  # never closes a ticket -- silent, and indistinguishable from a clean board.
  grep -q -- '--apply' <<< "$SVC"
  ! grep -q -- '--dry-run' <<< "$SVC"
}

@test "the state + ledger directory is created root-only" {
  grep -q 'install -d -m 700 /var/lib/hydra/clickup-drain' "$INSTALLER"
}

@test "a failing run pages: the unit is in the OnFailure list" {
  grep -q 'clickup-drain-data-deletion.service' "$INSTALLER"
  awk '/^AUX_ONFAILURE_UNITS=\(/,/^\)/' "$INSTALLER" | grep -qx '  clickup-drain-data-deletion.service'
}

@test "the kill switch does not page: exit 4 is a success at the unit boundary" {
  # The unit is in AUX_ONFAILURE_UNITS, so a non-zero exit pages. Exit 4 is the
  # kill file being present -- the switch working. Without SuccessExitStatus=4
  # every disabled hourly run pages the alert the switch exists to silence.
  grep -qE '^SuccessExitStatus=0 4$' <<< "$SVC"
}

@test "a genuine failure still pages: only 0 and 4 are whitelisted" {
  # 2 (a read failed), 5 (a write failed), 6 (an incomplete revert) and 7 (the
  # report did not go out) must all still fail the unit.
  ! grep -qE '^SuccessExitStatus=.*\b(2|5|6|7)\b' <<< "$SVC"
}

@test "the rollback command is written down next to the units" {
  grep -q 'systemctl disable --now clickup-drain-data-deletion.timer' "$INSTALLER"
}

@test "the runbook the comment points at exists" {
  [ -f "$HYDRA_REPO/docs/runbooks/clickup-drain-data-deletion.md" ]
}
