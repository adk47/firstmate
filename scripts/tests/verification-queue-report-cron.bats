#!/usr/bin/env bats
# The SCHEDULER wiring for scripts/verification-queue-report.py — the captain's
# every-30-minutes DM of open credits and profile claims.
#
# scripts/tests/test_verification_queue_report.py covers the measurement (buckets,
# partition invariant, arrows) and every one of its cases passes with the cron.d
# block in scripts/install-aux-units.sh deleted: a tested program that never runs,
# which is the exact failure this file exists to catch. Same shape as
# install-aux-units-merge-outcome-notify.bats: the installer writes to /etc/cron.d
# as root, so the heredoc is extracted and asserted here — this pins that the
# wiring is DECLARED, not that it was applied on a host.
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
INSTALLER="$HYDRA_REPO/scripts/install-aux-units.sh"
SCRIPT="$HYDRA_REPO/scripts/verification-queue-report.py"

setup() {
  CRON="$(awk '
    index($0, "cat > /etc/cron.d/verification-queue-report") == 1 { on = 1; next }
    $0 == "VERIFQUEUERPT" { on = 0 }
    on { print }
  ' "$INSTALLER")"
  export CRON
}

@test "a cron.d entry for the report is declared" {
  [ -n "$CRON" ]
  grep -qx '# MANAGED BY scripts/install-aux-units.sh — DO NOT EDIT BY HAND.' <<< "$CRON"
}

@test "it fires every 30 minutes" {
  run grep -E '^\*/30 \* \* \* \* root ' <<< "$CRON"
  [ "$status" -eq 0 ]
}

@test "it runs the report with --post (a measurement that never posts is useless)" {
  grep -q 'scripts/verification-queue-report.py --post' <<< "$CRON"
}

@test "a 5-minute light tick runs the backlog sentinel and never the report" {
  run grep -E '^\*/5 \* \* \* \* root .*verification-queue-report.py --light --post' <<< "$CRON"
  [ "$status" -eq 0 ]
  # a light tick without --post would measure a breach and tell nobody
  grep -q -- '--light --post' <<< "$CRON"
}

@test "the light tick has its own lock (it must not block the 30-minute report)" {
  grep -q 'verification-queue-report-light.lock' <<< "$CRON"
  run grep -c 'flock -n /run/lock/verification-queue-report.lock' <<< "$CRON"
  [ "$output" -eq 1 ]
}

@test "the sentinel state dir is created under /var/lib" {
  run grep -F 'mkdir -p /var/lib/hydra/verification-queue-report /var/lib/hydra/backlog-sentinel' "$INSTALLER"
  [ "$status" -eq 0 ]
}

@test "the script documents both kill switches" {
  run python3 "$SCRIPT" --help
  [ "$status" -eq 0 ]
  grep -q 'backlog-sentinel.disabled' <<< "$output"
}

@test "an overlapping run cannot double-post into the captain's DM" {
  # A 35s runtime on a 30-min cadence does not need a lock in the happy path; the lock
  # is for a manual run, a deploy retry or a slow replica day, where two runs would
  # otherwise both see "no marker" and post twice.
  grep -q 'flock -n /run/lock/verification-queue-report.lock' <<< "$CRON"
}

@test "cron's PATH can find kubectl (the trino wrapper shells out to it)" {
  run grep -E '^PATH=.*/usr/local/bin' <<< "$CRON"
  [ "$status" -eq 0 ]
}

@test "the script is executable, loads, and documents its kill switch" {
  [ -x "$SCRIPT" ]
  run python3 "$SCRIPT" --help
  [ "$status" -eq 0 ]
  grep -q 'Kill switch' <<< "$output"
}

@test "the bucket classifier passes its own fixtures" {
  run python3 "$SCRIPT" --selftest
  [ "$status" -eq 0 ]
  [ "$output" = "selftest ok" ]
}

@test "the installer guards the script's executable bit before writing the cron" {
  run grep -F '[[ -x "$HYDRA_ROOT/scripts/verification-queue-report.py" ]]' "$INSTALLER"
  [ "$status" -eq 0 ]
}

@test "the arrows state dir is created by the installer under /var/lib (not /opt/hydra)" {
  # /opt/hydra is rsynced --delete on every deploy; state written there vanishes.
  run grep -F 'mkdir -p /var/lib/hydra/verification-queue-report' "$INSTALLER"
  [ "$status" -eq 0 ]
}
