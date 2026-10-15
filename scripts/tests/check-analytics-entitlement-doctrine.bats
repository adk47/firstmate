#!/usr/bin/env bats
# Tests for check-analytics-entitlement-doctrine.sh: the mechanical backstop that keeps the
# analytics entitlement doctrine (profile_analytics_status gates access to figures on
# analytics.entitled) from silently regressing out of workspaces/support/SOUL.md.
#
# Hermetic: runs the guard against temp COPIES of the checked-out SOUL.md via the
# SUPPORT_SOUL_FILE env override, so a test never edits the tracked source and never depends on
# a remote branch.
#
# Every mutation test goes through mutate_expect_fail, which first proves the guard is green on the
# untouched copy, then proves the target substring is present, removes it, and only then asserts
# the TARGETED failure label. A mutation that changes nothing fails the test instead of passing.
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
SCRIPT="$HYDRA_REPO/scripts/check-analytics-entitlement-doctrine.sh"

setup() {
  TEST_TMPDIR="$(mktemp -d)"
  cp "$HYDRA_REPO/workspaces/support/SOUL.md" "$TEST_TMPDIR/SOUL.md"
  export SUPPORT_SOUL_FILE="$TEST_TMPDIR/SOUL.md"
}

teardown() { rm -rf "$TEST_TMPDIR"; }

# replace_once <file> <old> <new> — replaces EVERY occurrence (an anchor repeated elsewhere would
# mask a single-occurrence edit); fails (status 1) if <old> is not present verbatim.
replace_once() {
  python3 - "$1" "$2" "$3" <<'PY'
import sys
p, old, new = sys.argv[1:4]
s = open(p, encoding="utf-8").read()
if old not in s:
    sys.exit(1)
open(p, "w", encoding="utf-8").write(s.replace(old, new))
PY
}

# mutate_expect_fail <substring> <label> [replacement]
# Pre-condition: guard is green on the untouched copy and <substring> is present.
# Then replace it (default: delete) and require exit 1 with the targeted FAIL label.
mutate_expect_fail() {
  local sub="$1" label="$2" repl="${3:-}"
  run "$SCRIPT"
  [ "$status" -eq 0 ] || { echo "precondition: guard not green before mutation: $output" >&2; return 1; }
  cp "$SUPPORT_SOUL_FILE" "$SUPPORT_SOUL_FILE.orig"
  replace_once "$SUPPORT_SOUL_FILE" "$sub" "$repl" || { echo "precondition: substring not present in SOUL.md: $sub" >&2; return 1; }
  ! cmp -s "$SUPPORT_SOUL_FILE" "$SUPPORT_SOUL_FILE.orig" || { echo "mutation changed nothing" >&2; return 1; }
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL: "*": $label"* ]] || { echo "expected FAIL label '$label', got: $output" >&2; return 1; }
}

@test "passes on the checked-out doctrine" {
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK:"* ]]
}

@test "harness: a mutation whose target substring is absent fails the test, not the guard" {
  run mutate_expect_fail "this text is not in SOUL.md" "the analytics figures prohibition"
  [ "$status" -ne 0 ]
}

@test "fails if the analytics figures prohibition is removed" {
  mutate_expect_fail "NEVER state, quote, summarise, reformat or screenshot stream or analytics figures" \
    "the analytics figures prohibition"
}

@test "fails if the unless-entitled condition is removed" {
  mutate_expect_fail "unless the customer is entitled to them" "the allow-list condition"
}

@test "fails if the is-not-true deny clause is removed" {
  mutate_expect_fail 'if `analytics.entitled` is not `true`, Caroline states no figures' "the deny-list protection"
}

@test "fails if the allow-list is rewritten as a deny-list (not true -> false)" {
  mutate_expect_fail 'is not `true`' "the deny-list protection" 'is `false`'
}

@test "fails if the reformatting evasion clause is removed" {
  mutate_expect_fail "Reformatting figures you should not have given is still giving them" \
    "the reformatting evasion clause"
}

@test "fails if the plan+seat concept sentence is removed" {
  mutate_expect_fail "analytics need an active Pro or Business plan with a seat" "the allow-list concept"
}

@test "fails if the plan+seat clause is removed from the refusal copy" {
  mutate_expect_fail "active Pro or Business plan with a seat" "the allow-list: active Pro or Business plan"
}

@test "fails if the refusal copy opener is removed" {
  mutate_expect_fail "Stream and analytics figures come with Pro" "the refusal copy"
}

@test "fails if the complete refusal copy is altered" {
  mutate_expect_fail "Stream and analytics figures come with Pro – on an active Pro or Business plan with a seat" \
    "the complete refusal copy with pro+seat requirement"
}

@test "fails if the profile_analytics_status read is renamed away" {
  mutate_expect_fail "profile_analytics_status" "the profile_analytics_status field" "profile_status"
}

@test "fails if the analytics.entitled field name is changed" {
  mutate_expect_fail "analytics.entitled" "the analytics.entitled boolean" "analytics.allowed"
}

@test "fails if the fresh-status-on-this-turn instruction is deleted" {
  mutate_expect_fail 'you need a fresh `profile_analytics_status` saying `analytics.entitled` is `true` on THIS turn' \
    "the fresh status check on this turn"
}

@test "fails if the per-reply entitlement lead sentence is deleted" {
  mutate_expect_fail "Entitlement is per reply, not per thread" "the per-reply entitlement rule"
}

@test "fails if the customer-supplied figure rule is deleted" {
  mutate_expect_fail "A figure the customer gave you is still a figure you may not repeat" \
    "the customer-supplied figure rule"
}

@test "fails if the data-fix confirmation rule is deleted" {
  mutate_expect_fail "After a data fix: confirm that the fix landed, never the number" \
    "the data-fix confirmation rule"
}

@test "exits 2 (script error) when the doctrine file is missing" {
  rm -f "$TEST_TMPDIR/SOUL.md"
  run "$SCRIPT"
  [ "$status" -eq 2 ]
}

@test "robustness: an anchor re-wrapped across lines still matches" {
  replace_once "$SUPPORT_SOUL_FILE" \
    "NEVER state, quote, summarise, reformat or screenshot" \
    $'NEVER state, quote, summarise,\nreformat or screenshot'
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK:"* ]]
}
