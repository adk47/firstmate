#!/usr/bin/env bats
# The SCHEDULER wiring for the Sentry issue watchdog.
#
# Why this file exists: scripts/tests/sentry-issue-watchdog.bats covers the
# watchdog's behaviour in 62 cases, and every one of them passed with the
# /etc/cron.d installer block DELETED. That is a fully tested program that never
# runs -- the most complete kind of silent failure this repo can ship, because
# the green suite is exactly what makes nobody look. QA flagged it as `test-gap`
# on scripts/install-aux-units.sh in six consecutive reviews.
#
# These assertions read the INSTALLER SOURCE rather than executing it: the real
# script writes to /etc/cron.d and /var/lib as root and is not safe to run in a
# test. That is a real limitation -- it pins that the wiring is DECLARED, not
# that it was applied on a host.
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
INSTALLER="$HYDRA_REPO/scripts/install-aux-units.sh"

# The cron stanza, isolated once so every case reads the same text.
setup() {
  BLOCK="$(awk '/^cat > \/etc\/cron\.d\/sentry-issue-watchdog/,/^SENTRYWD$/' "$INSTALLER")"
  export BLOCK
}

@test "the installer exists and is executable" {
  [ -x "$INSTALLER" ]
}

@test "a cron.d entry for the sentry watchdog is installed" {
  [ -n "$BLOCK" ]
  grep -q '/etc/cron.d/sentry-issue-watchdog' <<< "$BLOCK"
}

@test "the cron entry actually invokes the watchdog script" {
  grep -q 'scripts/sentry-issue-watchdog\.sh' <<< "$BLOCK"
}

@test "the script the cron entry names really exists and is executable" {
  # A cron line pointing at a moved or renamed file is the same outage as no
  # cron line at all, and nothing else in the suite would notice.
  [ -x "$HYDRA_REPO/scripts/sentry-issue-watchdog.sh" ]
}

@test "the schedule is every 30 minutes, matching the documented rate budget" {
  # The 3-requests-per-30-min arithmetic in the script header and the RUNBOOK is
  # only true at this cadence; */5 would be a 6x rate-limit change nobody reviewed.
  grep -qE '^\*/30 \* \* \* \* root ' <<< "$BLOCK"
}

@test "output is redirected to a log, not mailed into the void" {
  grep -q '>> /var/log/sentry-issue-watchdog.log 2>&1' <<< "$BLOCK"
}

@test "the cron file carries NO env vars — the levers are flag FILES" {
  # /etc/cron.d/sentry-issue-watchdog is regenerated wholesale on every deploy,
  # so a knob set here disappears the moment a fix-forward ships. Anything that
  # must survive belongs in a flag file. Assert on the command line only, so the
  # heredoc's own marker lines cannot mask a regression.
  # Key this on the SCRIPT NAME, not the schedule: keying it on '^*/30 ' made
  # this case collapse whenever the schedule test was already failing, so one
  # regression reported two, and the second report was noise.
  cmdline="$(grep -F 'sentry-issue-watchdog.sh' <<< "$BLOCK" || true)"
  [ -n "$cmdline" ]
  [[ "$cmdline" != *"SENTRY_WATCHDOG_"* ]]
}

@test "both state dirs are created, including the one the triage SKILL owns" {
  # /var/lib/hydra-sentry-triage belongs to the skill's ledger. Creating it here
  # means the skill's own mkdir is never the first thing to touch it, so the
  # watchdog can tell "ledger absent" from "ledger unreadable".
  grep -q 'mkdir -p /var/lib/hydra-sentry-watchdog /var/lib/hydra-sentry-triage' "$INSTALLER"
}

@test "state dirs use mkdir -p, never install -d" {
  # install -d re-chmods an EXISTING directory to 0755 even without -m, and the
  # ledger dir is shared state with the triage skill.
  run grep -n 'install -d .*hydra-sentry' "$INSTALLER"
  [ "$status" -ne 0 ]
}

@test "the installer pre-flights the watchdog as executable before wiring it" {
  grep -q 'scripts/sentry-issue-watchdog.sh.*missing or not executable' "$INSTALLER"
}
