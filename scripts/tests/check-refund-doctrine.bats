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
  cp "$HYDRA_REPO/skills-all/muso-refund-investigation/SKILL.md" "$TEST_TMPDIR/INVESTIGATION.md"
  export OPS_SOUL_FILE="$TEST_TMPDIR/SOUL.md"
  export REFUND_SKILL_FILE="$TEST_TMPDIR/SKILL.md"
  export STRIPE_GATE_FILE="$TEST_TMPDIR/muso-stripe-write.sh"
  export REFUND_INVESTIGATION_FILE="$TEST_TMPDIR/INVESTIGATION.md"
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

# --- No-double-concession anchors (2026-09-09 duplicate-concession audit) -----
#
# One strip-to-RED case per require() anchor, plus inject-to-RED cases for the two
# forbid() anchors. The forbid cases are the ones that matter most: the text they ban
# reads like sensible refund advice, which is exactly why it survived for years.

@test "fails if the never-both rule is removed from the investigation skill" {
  strip "$REFUND_INVESTIGATION_FILE" "NEVER both a cash refund and a credit balance"
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"the never-both rule"* ]]
}

@test "fails if the zero-first ordering is removed from the investigation skill" {
  strip "$REFUND_INVESTIGATION_FILE" "zero the credit balance BEFORE the cash refund"
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"the zero-first ordering"* ]]
}

@test "fails if the corrected two-concession worked example is removed" {
  strip "$REFUND_INVESTIGATION_FILE" "two** concessions"
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"corrected worked example"* ]]
}

@test "fails if the credit-provenance read is removed from the investigation skill" {
  strip "$REFUND_INVESTIGATION_FILE" "/balance_transactions"
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"credit-provenance read"* ]]
}

@test "FORBID: fails if the old dangerous worked example is restored" {
  printf '%s\n' '- ✅ Correct refund: $106.73 (the credit balance)' >> "$REFUND_INVESTIGATION_FILE"
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"old dangerous worked example"* ]]
  [[ "$output" == *"must NO LONGER contain"* ]]
}

@test "FORBID: fails if the old 'refund the credit balance' instruction is restored" {
  printf '%s\n' '- refund the credit balance, not the original charge' >> "$REFUND_SKILL_FILE"
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"old 'refund the credit balance' instruction"* ]]
}

@test "fails if the credit-balance disposition step is removed from the processor skill" {
  strip "$REFUND_SKILL_FILE" "Credit-balance disposition"
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"credit-balance disposition step"* ]]
}

@test "fails if safety rail 8 is removed from the processor skill" {
  strip "$REFUND_SKILL_FILE" "No cash refund on top of a live credit"
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"safety rail 8"* ]]
}

@test "fails if the POST-REFUND-CREDIT-LIVE clause is removed from the processor skill" {
  strip "$REFUND_SKILL_FILE" "POST-REFUND-CREDIT-LIVE"
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"post-write did-happen clause"* ]]
}

@test "fails if the credit wall is removed from SOUL" {
  strip "$OPS_SOUL_FILE" "Credit wall"
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"the credit wall"* ]]
}

@test "fails if the no-double-concession gate function is removed from the money gate" {
  strip "$STRIPE_GATE_FILE" "enforce_no_double_concession_gate"
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"no-double-concession gate function"* ]]
}

@test "fails if the live-credit predicate call is removed from the money gate" {
  strip "$STRIPE_GATE_FILE" "customer_live_proration_credit"
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"live-credit predicate call"* ]]
}

@test "fails if keep-credit token parsing is removed from the money gate" {
  strip "$STRIPE_GATE_FILE" "--keep-credit-confirmed-by"
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"keep-credit token parsing"* ]]
}

# --- QA round 4, Important: forbid must survive Markdown line wrapping -------
#
# `grep -qF` matches within a single line. The banned instruction is prose, so an
# ordinary re-wrap splits it across two lines and the forbid silently passes
# while the dangerous text renders exactly as before — a gate that fails OPEN.

@test "FORBID catches the dangerous worked example split across a line wrap" {
  printf '%s\n' '- ✅ Correct refund: $106.73' '  (the credit balance)' >> "$REFUND_INVESTIGATION_FILE"
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"old dangerous worked example"* ]]
}

@test "FORBID catches the old credit-balance instruction split across a line wrap" {
  printf '%s\n' '- refund the credit balance,' '  not the original charge' >> "$REFUND_SKILL_FILE"
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"old 'refund the credit balance' instruction"* ]]
}

@test "REQUIRE still matches an anchor that is itself line-wrapped" {
  # The same normalization must not make require() fail on wrapped prose, or a
  # harmless re-flow turns into a red CI run and someone 'fixes' it by deleting
  # the anchor.
  python3 - "$REFUND_INVESTIGATION_FILE" <<'PY'
import sys,re
p=sys.argv[1]; s=open(p).read()
s=s.replace("**NEVER both a cash refund and a credit balance for the same unused period.**",
            "**NEVER both a cash refund and a\ncredit balance for the same unused period.**")
open(p,'w').write(s)
PY
  run "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "FORBID catches a restored 'verify the balance is 0' in the processor skill" {
  printf '%s\n' 'then verify the balance is 0 and report.' >> "$REFUND_SKILL_FILE"
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"verify the balance is 0"* ]]
}
