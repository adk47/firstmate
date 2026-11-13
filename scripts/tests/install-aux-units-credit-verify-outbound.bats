#!/usr/bin/env bats
# The SCHEDULE of the credit-verify outbound tick, as the installer writes it.
#
# /etc/cron.d/credit-verify-outbound is written by scripts/install-aux-units.sh on every deploy, so
# the installer's heredoc IS the schedule: on 2026-11-13 the host was set to hourly by hand twice
# and two deploys (~02:25Z, ~02:42Z) put `0 */2 * * *` back, because that is what this file said.
# Nothing tested the line, so a schedule change could only be made, and unmade, by hand.
#
# The real installer needs root and writes /etc, so the heredoc is read out of the script (the same
# way install-aux-units-claim-list-build.bats reads its units) and the emitted cron file is parsed
# into its fields.
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
INSTALLER="$HYDRA_REPO/scripts/install-aux-units.sh"
OPEN='cat > /etc/cron.d/credit-verify-outbound << CRONCVOUTBOUND'
CLOSE='CRONCVOUTBOUND'

cron_body() {
  awk -v start="$OPEN" -v stop="$CLOSE" '
    $0 == start { on = 1; next }
    $0 == stop { on = 0 }
    on { print }
  ' "$INSTALLER"
}

# The job lines: everything in the heredoc that is not a comment, blank, or a VAR=value line.
job_lines() { cron_body | grep -vE '^[[:space:]]*(#|$)|^[A-Za-z_][A-Za-z0-9_]*=' || true; }

@test "the outbound tick is one job, and it runs hourly on the hour" {
  jobs="$(job_lines)"
  [ "$(grep -c . <<<"$jobs")" -eq 1 ]             # a second line would be a second schedule
  read -r minute hour dom mon dow rest <<<"$jobs"
  [ "$minute $hour $dom $mon $dow" = '0 * * * *' ]
}
