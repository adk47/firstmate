#!/usr/bin/env bats
# The SCHEDULER wiring for the `action:profile-claim` drainer.
#
# Why this file exists: tests/test_clickup_drain_profile_claim.py covers the
# drainer's behaviour (the ladder, the caps, the read-back, the revert) and every
# one of those cases passes with the systemd block in scripts/install-aux-units.sh
# DELETED. That is a fully tested program that never runs, and a green suite is
# exactly what stops anyone from looking. Same shape as
# install-aux-units-clickup-dedupe.bats.
#
# These assertions read the INSTALLER SOURCE rather than executing it: the real
# script writes to /etc/systemd/system and runs systemctl as root, which is not
# safe in a test. That pins that the wiring is DECLARED, not that it was applied
# on a host.
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
INSTALLER="$HYDRA_REPO/scripts/install-aux-units.sh"
DRAINER="$HYDRA_REPO/scripts/clickup_drain/profile_claim.py"

setup() {
  SVC="$(awk '/^cat > \/etc\/systemd\/system\/clickup-drain-profile-claim\.service/,/^CDRAINPCSVC$/' "$INSTALLER")"
  TMR="$(awk '/^cat > \/etc\/systemd\/system\/clickup-drain-profile-claim\.timer/,/^CDRAINPCTMR$/' "$INSTALLER")"
  export SVC TMR
}

@test "the installer exists and is executable" {
  [ -x "$INSTALLER" ]
}

@test "the drainer exists and is executable, and so do the rules it imports" {
  [ -x "$DRAINER" ]
  [ -f "$HYDRA_REPO/scripts/claim_verify/decline_rules.py" ]
  [ -f "$HYDRA_REPO/scripts/credit_review/claim_executor.py" ]
}

@test "the installer pre-flights the drainer before writing any unit" {
  grep -q 'clickup_drain/profile_claim\.py missing' "$INSTALLER"
}

@test "a service unit for the drainer is installed" {
  [ -n "$SVC" ]
  grep -q '/etc/systemd/system/clickup-drain-profile-claim.service' <<< "$SVC"
}

@test "a timer unit for the drainer is installed" {
  [ -n "$TMR" ]
  grep -q '/etc/systemd/system/clickup-drain-profile-claim.timer' <<< "$TMR"
}

@test "ExecStart runs the drainer with --apply and a hard write cap" {
  grep -q 'scripts/clickup_drain/profile_claim\.py --apply --max-writes 100' <<< "$SVC"
}

@test "the service gets the board token from the gateway env files" {
  grep -q 'EnvironmentFile=-/etc/openclaw/main.env' <<< "$SVC"
}

@test "the service has an explicit oneshot timeout (node-8 SIGTERMs otherwise)" {
  grep -q '^TimeoutStartSec=' <<< "$SVC"
}

@test "the timer is hourly at :35 and cannot drift into the :40 dedupe sweep" {
  grep -q '^OnCalendar=\*-\*-\* \*:35:00$' <<< "$TMR"
  # :35 + 60s bounded = :36 at the latest; the dedupe sweep starts at :40, on
  # the same board and the same 100 req/min token.
  grep -q '^RandomizedDelaySec=60$' <<< "$TMR"
}

@test "the timer is enabled and started by the installer" {
  grep -q 'cdp=clickup-drain-profile-claim.timer' "$INSTALLER"
  grep -q 'systemctl enable "\$cdp"' "$INSTALLER"
}

@test "the block documents the kill file and the rollback that bypasses the deploy" {
  grep -q '/etc/hydra/clickup-drain-profile-claim.disabled' "$INSTALLER"
  grep -q 'systemctl disable --now clickup-drain-profile-claim.timer' "$INSTALLER"
  grep -q -- '--revert' "$INSTALLER"
}
