#!/usr/bin/env bats
#
# The daily GDPR hide-batch timer, pinned as WIRING.
#
# WHY: the brief's step 3 is "daily hide batch PR generated from PASS rows", and until this timer existed
# `gdpr-pipeline.py hide-batch --open-prs` was a manual command - so a PASS row waited on somebody remembering to
# run it. Prose in a doc is not enforcement; this suite fails if the unit, the timer, the pager row or the
# no-`--include-legal` scope drifts.
#
# It reads the INSTALLER, not the live host: the units are heredocs in scripts/install-aux-units.sh, so the
# assertions are about what the next deploy will write.

INSTALLER="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)/scripts/install-aux-units.sh"

@test "the hide-batch service exists and runs the batch with --open-prs" {
  grep -q 'cat > /etc/systemd/system/gdpr-hide-batch.service' "$INSTALLER"
  grep -q 'gdpr-pipeline.py hide-batch --open-prs' "$INSTALLER"
}

@test "the hide-batch service is a oneshot with a bounded runtime" {
  # A oneshot that can hang holds the run lock and starves the hourly tick.
  awk '/cat > \/etc\/systemd\/system\/gdpr-hide-batch.service/,/^GDPRHIDESVC$/' "$INSTALLER" \
    | grep -q '^Type=oneshot$'
  awk '/cat > \/etc\/systemd\/system\/gdpr-hide-batch.service/,/^GDPRHIDESVC$/' "$INSTALLER" \
    | grep -q '^TimeoutStartSec='
}

@test "the hide-batch service carries HOME=/root so gh api finds root's config" {
  # The batch reads both hide lists through `gh api`; without HOME it cannot resolve them and the run fails.
  awk '/cat > \/etc\/systemd\/system\/gdpr-hide-batch.service/,/^GDPRHIDESVC$/' "$INSTALLER" \
    | grep -q '^Environment=HOME=/root$'
}

@test "the timer is daily, persistent, and enabled" {
  awk '/cat > \/etc\/systemd\/system\/gdpr-hide-batch.timer/,/^GDPRHIDETMR$/' "$INSTALLER" \
    | grep -q '^OnCalendar='
  awk '/cat > \/etc\/systemd\/system\/gdpr-hide-batch.timer/,/^GDPRHIDETMR$/' "$INSTALLER" \
    | grep -q '^Persistent=true$'
  grep -q 'systemctl enable "\$ht"' "$INSTALLER"
}

@test "the routine batch does NOT fold in legal_threat rows" {
  # --include-legal is a separate captain call ("legal threat, hide first"). Folding it into the daily batch would
  # hide pages on a rule nobody re-approved here.
  ! grep -q 'hide-batch --open-prs --include-legal' "$INSTALLER"
}

@test "a failing daily batch pages instead of sitting in systemctl --failed" {
  awk '/^AUX_ONFAILURE_UNITS=\(/,/^\)$/' "$INSTALLER" | grep -qx '  gdpr-hide-batch.service'
}

@test "the batch is killable by the same switch as every other writing run" {
  # The CLI checks /etc/hydra/gdpr-pipeline.disabled for every writing run, and --open-prs counts as one.
  grep -q 'KILL' "$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)/scripts/gdpr-pipeline.py"
  grep -q 'getattr(a, "open_prs", False)' "$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)/scripts/gdpr-pipeline.py"
}
