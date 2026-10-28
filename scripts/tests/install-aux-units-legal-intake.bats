#!/usr/bin/env bats
# The legal@ intake script is scheduled by a 15-min cron on node-1 that SSHes
# into node-8 and runs /root/fmc1-intake/intake.py. The installer therefore
# owns that FILE (no unit, no cron change). These tests EXECUTE the installer's
# own BEGIN/END legal-intake-install block against a temp dir, via the
# LEGAL_INTAKE_DEST seam, so the real /root is never touched.
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
INSTALLER="$HYDRA_REPO/scripts/install-aux-units.sh"

_run_block() {
  {
    echo 'log() { echo "$*"; }'
    sed -n '/^# --- BEGIN legal-intake-install ---$/,/^# --- END legal-intake-install ---$/p' "$INSTALLER"
  } > "$TEST_TMPDIR/block.sh"
  [ "$(wc -l < "$TEST_TMPDIR/block.sh")" -gt 5 ]
  HYDRA_ROOT="$HYDRA_REPO" LEGAL_INTAKE_DEST="$DEST" bash "$TEST_TMPDIR/block.sh"
}

setup() {
  TEST_TMPDIR="$(mktemp -d)"; export TEST_TMPDIR
  DEST="$TEST_TMPDIR/fmc1-intake/intake.py"
  mkdir -p "$TEST_TMPDIR/fmc1-intake"
}
teardown() { rm -rf "$TEST_TMPDIR"; }

_mode() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }
_baks() { compgen -G "$DEST.pre-git-*" | wc -l | tr -d ' '; }

@test "fresh host: the file lands 0755 with content equal to the repo copy" {
  run _run_block
  [ "$status" -eq 0 ]
  [ "$(_mode "$DEST")" = "755" ]
  cmp "$HYDRA_REPO/scripts/legal-intake.py" "$DEST"
  [ "$(_baks)" -eq 0 ]
}

@test "a different pre-existing file is backed up exactly once across two installs" {
  echo "old live script" > "$DEST"
  run _run_block
  [ "$status" -eq 0 ]
  run _run_block
  [ "$status" -eq 0 ]
  [ "$(_baks)" -eq 1 ]
  [ "$(cat "$DEST".pre-git-*)" = "old live script" ]
  cmp "$HYDRA_REPO/scripts/legal-intake.py" "$DEST"
}

@test "a drifted target is overwritten, and no second backup is made" {
  echo "old live script" > "$DEST"
  run _run_block
  echo "hand edit on node-8" > "$DEST"
  run _run_block
  [ "$status" -eq 0 ]
  cmp "$HYDRA_REPO/scripts/legal-intake.py" "$DEST"
  [ "$(_baks)" -eq 1 ]
}

@test "an identical existing file makes no backup" {
  cp "$HYDRA_REPO/scripts/legal-intake.py" "$DEST"
  run _run_block
  [ "$status" -eq 0 ]
  [ "$(_baks)" -eq 0 ]
}

@test "the installer's preflight FAILS when the script is missing" {
  grep -q 'scripts/legal-intake.py" \]\] \\$' "$INSTALLER"
  grep -q 'legal-intake.py missing or not executable' "$INSTALLER"
}

@test "a missing /root/fmc1-intake dir is created instead of aborting the installer" {
  rmdir "$TEST_TMPDIR/fmc1-intake"
  run _run_block
  [ "$status" -eq 0 ]
  cmp "$HYDRA_REPO/scripts/legal-intake.py" "$DEST"
}
