#!/usr/bin/env bats
#
# scripts/assert-host-devnull.sh — fail loud when /dev/null is not a char device.
#
# WHY: on 2026-10-09 node-8's /dev/null became a regular root-owned file and
# PR Validation showed 5 unrelated-looking bats failures for hours. The script
# takes the path as $1 so this suite exercises both outcomes WITHOUT touching
# the real device. /dev/zero is the "real char device" stand-in (portable).

SCRIPT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)/scripts/assert-host-devnull.sh"

@test "regular file: exits 1 with a column-0 ::error:: line" {
  touch "$BATS_TEST_TMPDIR/null"
  run bash "$SCRIPT" "$BATS_TEST_TMPDIR/null"
  [ "$status" -eq 1 ]
  [[ "$output" == *"::error::"* ]]
  [[ "$output" == *"is not a char device"* ]]
  printf '%s\n' "$output" | grep -q '^::error::node-8 '
  # an existing file must never be reported as absent (ls -ld line is the forensics)
  [[ "$output" != *"absent"* ]]
  [[ "$output" == *"$BATS_TEST_TMPDIR/null"* ]]
}

@test "real char device (/dev/zero): exits 0" {
  run bash "$SCRIPT" /dev/zero
  [ "$status" -eq 0 ]
}

@test "missing path: exits 1 (deleted /dev/null is loud too)" {
  run bash "$SCRIPT" "$BATS_TEST_TMPDIR/does-not-exist"
  [ "$status" -eq 1 ]
  [[ "$output" == *"::error::"* ]]
  [[ "$output" == *"absent"* ]]
}

@test "never repairs: the regular file is still a regular file afterwards" {
  touch "$BATS_TEST_TMPDIR/null"
  run bash "$SCRIPT" "$BATS_TEST_TMPDIR/null"
  [ -f "$BATS_TEST_TMPDIR/null" ]
  [ ! -c "$BATS_TEST_TMPDIR/null" ]
}
