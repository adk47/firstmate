#!/usr/bin/env bats
# Tests for check-refund-doctrine.sh: the mechanical backstop that keeps the @Ops refund
# honesty + interactive-override doctrine (ask-then-confirm soft-wall gate, attributable
# override token, fabrication ban) and the money-path gate from silently regressing out of
# workspaces/operations/SOUL.md, skills-all/muso-refund-processor/SKILL.md, and
# scripts/muso-stripe-write.sh.
#
# Hermetic: runs the guard against temp COPIES of the real files via the
# OPS_SOUL_FILE / REFUND_SKILL_FILE / STRIPE_GATE_FILE env overrides, so a test never edits
# the tracked sources.
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
SCRIPT="$HYDRA_REPO/scripts/check-refund-doctrine.sh"

setup() {
  TEST_TMPDIR="$(mktemp -d)"
  cp "$HYDRA_REPO/workspaces/operations/SOUL.md" "$TEST_TMPDIR/SOUL.md"
  cp "$HYDRA_REPO/skills-all/muso-refund-processor/SKILL.md" "$TEST_TMPDIR/SKILL.md"
  cp "$HYDRA_REPO/scripts/muso-stripe-write.sh" "$TEST_TMPDIR/muso-stripe-write.sh"
  export OPS_SOUL_FILE="$TEST_TMPDIR/SOUL.md"
  export REFUND_SKILL_FILE="$TEST_TMPDIR/SKILL.md"
  export STRIPE_GATE_FILE="$TEST_TMPDIR/muso-stripe-write.sh"
}

teardown() { rm -rf "$TEST_TMPDIR"; }

# strip <file> <fixed-substring> — drop every line containing the substring.
strip() {
  grep -vF -- "$2" "$1" > "$1.tmp"
  mv "$1.tmp" "$1"
}

@test "passes on the real (patched) doctrine surface" {
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK:"* ]]
}

@test "fails if the 'holding for Aaron approval' fabrication ban is removed from SOUL" {
  strip "$TEST_TMPDIR/SOUL.md" "holding for Aaron approval"
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL:"* ]]
}

@test "fails if the interactive ask-then-await gate is removed from SOUL" {
  strip "$TEST_TMPDIR/SOUL.md" "wait for their reply"
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL:"* ]]
}

@test "fails if the override token convention is removed from SOUL" {
  strip "$TEST_TMPDIR/SOUL.md" "--override-confirmed-by"
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL:"* ]]
}

@test "fails if the override execution path is removed from the refund skill" {
  strip "$TEST_TMPDIR/SKILL.md" "If OVERRIDE-confirmed"
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL:"* ]]
}

@test "fails if the never-on-a-fabricated-confirmation rule is removed from the skill" {
  strip "$TEST_TMPDIR/SKILL.md" "fabricated confirmation"
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL:"* ]]
}

@test "fails if the money-gate override function is removed from muso-stripe-write.sh" {
  strip "$TEST_TMPDIR/muso-stripe-write.sh" "enforce_refund_one_time_gate"
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL:"* ]]
}

@test "exits 2 (script error) when a doctrine file is missing" {
  rm -f "$TEST_TMPDIR/SOUL.md"
  run "$SCRIPT"
  [ "$status" -eq 2 ]
}
