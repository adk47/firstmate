#!/usr/bin/env bats
# The SCHEDULER wiring for the Intercom rights-holder / urgent watchdog
# (scripts/intercom-rights-holder-watchdog.py, MUS-6589; wired by MUS-6593).
#
# It is a systemd oneshot service + timer, NOT an /etc/cron.d entry: cron.d
# blocks pass env inline and are chmod 644 (a token there is world-readable),
# and wire_unit_failure_paging() only covers systemd units, so a failing
# cron.d watchdog would page nobody.
#
# These assertions read the INSTALLER SOURCE rather than executing it: the real
# script writes to /etc/systemd/system as root and is not safe to run in a
# test. That is a real limitation -- it pins that the wiring is DECLARED, not
# that it was applied on a host.
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
INSTALLER="$HYDRA_REPO/scripts/install-aux-units.sh"
SCRIPT="scripts/intercom-rights-holder-watchdog.py"

setup() {
  SVC="$(awk '/^cat > \/etc\/systemd\/system\/intercom-rights-holder-watchdog\.service/,/^RIGHTSHOLDERWDSVC$/' "$INSTALLER")"
  TMR="$(awk '/^cat > \/etc\/systemd\/system\/intercom-rights-holder-watchdog\.timer/,/^RIGHTSHOLDERWDTMR$/' "$INSTALLER")"
  export SVC TMR
}

@test "the .service and .timer blocks are present and non-empty" {
  [ -n "$SVC" ]
  [ -n "$TMR" ]
}

@test "ExecStart runs the watchdog script as a oneshot" {
  grep -q '^Type=oneshot$' <<< "$SVC"
  grep -qE "^ExecStart=/usr/bin/python3 \\\$HYDRA_ROOT/$SCRIPT\$" <<< "$SVC"
}

@test "the script ExecStart names really exists and is executable" {
  # A unit pointing at a renamed script is the same outage as no unit.
  [ -x "$HYDRA_REPO/$SCRIPT" ]
}

@test "both env files are loaded (optional, secret-safe path)" {
  grep -q '^EnvironmentFile=-/etc/openclaw/shared.env$' <<< "$SVC"
  grep -q '^EnvironmentFile=-/etc/openclaw/edge.env$' <<< "$SVC"
}

@test "SECURITY: no secret literal appears in the unit blocks" {
  run grep -E 'MUSOAI_INTERCOM_TOKEN=|xoxb-|SLACK_BOT_TOKEN' <<< "$SVC
$TMR"
  [ "$status" -eq 1 ]
}

@test "cadence is every 10 minutes" {
  grep -q '^OnUnitActiveSec=10min$' <<< "$TMR"
  grep -q '^Unit=intercom-rights-holder-watchdog.service$' <<< "$TMR"
}

@test "the preflight requires the script to be executable" {
  grep -qF "[[ -x \"\$HYDRA_ROOT/$SCRIPT\" ]]" "$INSTALLER"
}

@test "the service is registered for OnFailure paging" {
  awk '/^AUX_ONFAILURE_UNITS=\(/,/^\)/' "$INSTALLER" \
    | grep -qx '  intercom-rights-holder-watchdog.service'
}

@test "idempotency: each unit is declared exactly once" {
  [ "$(grep -c '^cat > /etc/systemd/system/intercom-rights-holder-watchdog\.service' "$INSTALLER")" -eq 1 ]
  [ "$(grep -c '^cat > /etc/systemd/system/intercom-rights-holder-watchdog\.timer' "$INSTALLER")" -eq 1 ]
  [ "$(awk '/^AUX_ONFAILURE_UNITS=\(/,/^\)/' "$INSTALLER" | grep -c 'intercom-rights-holder-watchdog\.service')" -eq 1 ]
}

@test "no cron.d entry is added for it" {
  run grep -n 'cron.d/intercom-rights-holder' "$INSTALLER"
  [ "$status" -eq 1 ]
}
