#!/usr/bin/env bats
# The SCHEDULER wiring for the ClickUp TO DO dedupe sweeper.
#
# Why this file exists: tests/test_clickup_todo_dedupe.py covers the sweeper's
# behaviour in 49 cases, and every one of them passes with the systemd block in
# scripts/install-aux-units.sh DELETED. That is a fully tested program that
# never runs -- and a green suite is exactly what stops anyone from looking. QA
# flagged `test-gap` on scripts/install-aux-units.sh for this change. Same
# rationale, and same shape, as install-aux-units-sentry.bats.
#
# These assertions read the INSTALLER SOURCE rather than executing it: the real
# script writes to /etc/systemd/system and runs systemctl as root, which is not
# safe in a test. That is a real limitation -- it pins that the wiring is
# DECLARED, not that it was applied on a host.
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
INSTALLER="$HYDRA_REPO/scripts/install-aux-units.sh"

setup() {
  SVC="$(awk '/^cat > \/etc\/systemd\/system\/clickup-todo-dedupe\.service/,/^CUDEDUPESVC$/' "$INSTALLER")"
  TMR="$(awk '/^cat > \/etc\/systemd\/system\/clickup-todo-dedupe\.timer/,/^CUDEDUPETMR$/' "$INSTALLER")"
  export SVC TMR
}

@test "the installer exists and is executable" {
  [ -x "$INSTALLER" ]
}

@test "a service unit for the dedupe sweeper is installed" {
  [ -n "$SVC" ]
  grep -q '/etc/systemd/system/clickup-todo-dedupe.service' <<< "$SVC"
}

@test "a timer unit for the dedupe sweeper is installed" {
  [ -n "$TMR" ]
  grep -q '/etc/systemd/system/clickup-todo-dedupe.timer' <<< "$TMR"
}

@test "ExecStart actually invokes the sweeper script" {
  grep -q 'scripts/clickup-todo-dedupe\.py' <<< "$SVC"
}

@test "the script ExecStart names really exists and is executable" {
  # An ExecStart pointing at a moved or renamed file is the same outage as no
  # unit at all, and systemd only tells you at fire time.
  [ -x "$HYDRA_REPO/scripts/clickup-todo-dedupe.py" ]
}

@test "the shared library the sweeper imports really exists" {
  [ -f "$HYDRA_REPO/scripts/lib/intercom_link.py" ]
}

@test "the timer fires hourly" {
  grep -q 'OnCalendar=hourly' <<< "$TMR"
}

@test "the timer is Persistent so a reboot does not silently skip a window" {
  grep -q 'Persistent=true' <<< "$TMR"
}

@test "the timer drives the matching service unit" {
  grep -q 'Unit=clickup-todo-dedupe.service' <<< "$TMR"
}

@test "the service sets an explicit TimeoutStartSec" {
  # node-8 SIGTERMs any Type=oneshot unit that omits it, which kills the sweep
  # mid-run -- after the writes but possibly before the read-back.
  grep -qE 'TimeoutStartSec=[0-9]+' <<< "$SVC"
}

@test "the service is Type=oneshot" {
  grep -q 'Type=oneshot' <<< "$SVC"
}

@test "the service loads the env file that carries the ClickUp key" {
  # CLICKUP_API_KEY lives in main.env on node-8; without it the sweeper exits
  # before scanning and the timer looks healthy while doing nothing.
  grep -q 'EnvironmentFile=-/etc/openclaw/main.env' <<< "$SVC"
}

@test "the timer is enabled and started, not merely written to disk" {
  grep -q 'systemctl enable "\$cud"' "$INSTALLER"
  grep -q 'systemctl start "\$cud"' "$INSTALLER"
}

@test "daemon-reload runs so systemd actually picks the units up" {
  grep -q 'systemctl daemon-reload' "$INSTALLER"
}

@test "the installer pre-flights the sweeper and its library before wiring them" {
  grep -q 'scripts/clickup-todo-dedupe.py missing' "$INSTALLER"
  grep -q 'scripts/lib/intercom_link.py missing' "$INSTALLER"
}

@test "ExecStart passes no --dry-run: the unit must actually write" {
  # Shipping the timer in dry-run would be a sweeper that reports forever and
  # never moves a ticket -- silent, and indistinguishable from a clean board.
  ! grep -q -- '--dry-run' <<< "$SVC"
}
