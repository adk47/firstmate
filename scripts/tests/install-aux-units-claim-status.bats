#!/usr/bin/env bats
# The scheduler wiring for the durable claim-status wave (claim-lane-resume-c2, firstmate 040/042):
# /etc/cron.d/hydra-claim-status, rendered from the installer's own heredoc into a temp dir.
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
INSTALLER="$HYDRA_REPO/scripts/install-aux-units.sh"

setup() { TEST_TMPDIR="$(mktemp -d)"; }
teardown() { rm -rf "$TEST_TMPDIR"; }

_render() { # the `cat > /etc/cron.d/hydra-claim-status << TAG` block, written into $TEST_TMPDIR
  local snippet="$TEST_TMPDIR/render.sh"
  awk -v dest="$TEST_TMPDIR/" '
    !on && index($0, "cat > /etc/cron.d/hydra-claim-status") == 1 && $(NF-1) == "<<" {
      tag = $NF; on = 1; print "cat > " dest "hydra-claim-status << " tag; next
    }
    on { print; if ($0 == tag) on = 0 }
  ' "$INSTALLER" > "$snippet"
  HYDRA_ROOT="/opt/hydra" bash "$snippet"
}

@test "hydra-claim-status: one daily DRY-RUN audit at 01:15Z through the repo wrapper - the sends come from the signed list" {
  _render
  f="$TEST_TMPDIR/hydra-claim-status"
  [ -s "$f" ]
  run grep -cE '^[^#].* root ' "$f"
  [ "$output" = "1" ]
  # G7 follow-up (Fable driver 11-03 20:2xZ): ONE SENDER PER FAMILY - the wave audits, the signed list sends.
  grep -qx '15 1 \* \* \* root MODE=dry-run /opt/hydra/scripts/claim-status-daily.sh >> /var/lib/hydra/credit-review/claim-status-daily.log 2>&1' "$f"
  ! grep -q 'MODE=apply' "$f"
  grep -q 'MANAGED BY scripts/install-aux-units.sh' "$f"
}

@test "the wrapper states the one-sender rule in its own header, not only in the installer" {
  grep -q 'ONE SENDER PER FAMILY' "$HYDRA_REPO/scripts/claim-status-daily.sh"
  grep -q 'MODE=dry-run' "$HYDRA_REPO/scripts/claim-status-daily.sh"
  grep -q '#1634' "$HYDRA_REPO/scripts/claim-status-daily.sh"
}

@test "the wrapper the cron runs is in the repo, executable, and names both stop switches" {
  [ -x "$HYDRA_REPO/scripts/claim-status-daily.sh" ]
  grep -q '/etc/hydra/claim-status-daily.disabled' "$HYDRA_REPO/scripts/claim-status-daily.sh"
  grep -q '/etc/hydra/credit-ops-notes.disabled' "$HYDRA_REPO/scripts/claim-status-daily.sh"
  grep -q 'chmod 644 /etc/cron.d/hydra-claim-status' "$INSTALLER"
}

@test "the wrapper refuses an unknown MODE before reading secrets" {
  run env MODE=send STATE_ROOT="$TEST_TMPDIR/s" MAIN_ENV=/nonexistent bash "$HYDRA_REPO/scripts/claim-status-daily.sh"
  [ "$status" -eq 2 ]
  [[ "$output" == *"MODE must be apply or dry-run"* ]]
}

@test "the wrapper fails closed when main.env is unreadable (nothing runs)" {
  run env MODE=dry-run STATE_ROOT="$TEST_TMPDIR/s" MAIN_ENV="$TEST_TMPDIR/missing.env" HYDRA_ROOT="$TEST_TMPDIR/nohydra" bash "$HYDRA_REPO/scripts/claim-status-daily.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"unreadable: nothing sent"* ]]
}
