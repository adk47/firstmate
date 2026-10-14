#!/usr/bin/env bats
# Tests for check-ops-skill-doctrine.sh: the gate that stops the #1047 regression class
# (silent deletion of @Ops skill safety clauses) from going green. These are the committed
# negative controls: the happy path alone cannot tell a working gate from one that lost its
# `fail=1` or its final non-zero exit.
#
# Hermetic: runs the gate against temp COPIES of the six skill files via its *_FILE env
# overrides, so a test never edits the tracked sources.
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
SCRIPT="$HYDRA_REPO/scripts/check-ops-skill-doctrine.sh"
CDR="workspaces/operations/skills/customer-data-resolution"
SRR="workspaces/operations/skills/subscription-refund-reconciliation"

setup() {
  TEST_TMPDIR="$(mktemp -d)"
  cp "$HYDRA_REPO/$CDR/SKILL.md" "$TEST_TMPDIR/cdr.md"
  cp "$HYDRA_REPO/$CDR/references/credit-cleanup.md" "$TEST_TMPDIR/cleanup.md"
  cp "$HYDRA_REPO/$CDR/references/customer-updates.md" "$TEST_TMPDIR/updates.md"
  cp "$HYDRA_REPO/$CDR/references/intake-cases.md" "$TEST_TMPDIR/intake.md"
  cp "$HYDRA_REPO/$SRR/SKILL.md" "$TEST_TMPDIR/refund.md"
  cp "$HYDRA_REPO/$SRR/references/customer-communication.md" "$TEST_TMPDIR/comm.md"
  export CDR_SKILL_FILE="$TEST_TMPDIR/cdr.md"
  export CREDIT_CLEANUP_FILE="$TEST_TMPDIR/cleanup.md"
  export CUSTOMER_UPDATES_FILE="$TEST_TMPDIR/updates.md"
  export INTAKE_CASES_FILE="$TEST_TMPDIR/intake.md"
  export REFUND_RECONCILIATION_SKILL_FILE="$TEST_TMPDIR/refund.md"
  export CUSTOMER_COMMUNICATION_FILE="$TEST_TMPDIR/comm.md"
}

teardown() { rm -rf "$TEST_TMPDIR"; }

@test "passes on the real doctrine surface" {
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK:"* ]]
}

@test "every anchor, removed alone, fails the gate and is named in the output" {
  # copy-name | expected label fragment | exact raw text to delete (one anchor at a time)
  local rows=(
    'cdr.md|removal/unlink/merge/delete separation rule|Keep removal, raw unlinking, merge, and deletion separate'
    'cdr.md|profile-merge entity/label separation|separate entity types and labels'
    'cdr.md|merge inventory exclusion|excluding unrelated, group, or mixed-credit profiles'
    'cdr.md|merge-scope pointer|Merge-scope anchor: `references/credit-cleanup.md`'
    'cdr.md|album-role manifest detail|compare roles and `addedBy`'
    'cdr.md|step-7 customer-update pointer|invoice PDFs, streaming-unavailable questions'
    'cdr.md|login identity pointer|identity rule: `references/intake-cases.md`'
    'cleanup.md|merge-scope narrowing|merge only the customer-confirmed duplicate and remove only the exact misassigned rows'
    'cleanup.md|broaden-into-a-merge prohibition|Do not broaden the resolution into a merge'
    'updates.md|invoice-PDF proof bar|require HTTP 200 plus a `%PDF-` signature'
    'updates.md|no-reuse-expired-URL rule|never reuse the expired URL'
    'updates.md|streaming-unavailable misattribution check|first ask whether the credits are actually misattributed'
    'intake.md|stated-email-is-a-clue-only rule|treat a stated email as a lookup clue only'
    'intake.md|zero-credits-is-not-proof-of-loss rule|zero credits is not proof of loss'
    'refund.md|customer-facing pointer|Customer-facing bar: `references/customer-communication.md`'
    'comm.md|no-change-claim bar|only when no write succeeded'
    'comm.md|don'"'"'t-tell-customer-nothing-changed rule|do not tell the customer nothing changed'
  )
  local row name label text before
  for row in "${rows[@]}"; do
    name="${row%%|*}"; row="${row#*|}"
    label="${row%%|*}"; text="${row#*|}"
    before="$(cat "$TEST_TMPDIR/$name")"
    # Guard against a vacuous mutation: the text must be in the file as typed here.
    [[ "$before" == *"$text"* ]] || { echo "anchor text not in $name: $text"; return 1; }
    printf '%s\n' "${before//"$text"/}" > "$TEST_TMPDIR/$name"
    run "$SCRIPT"
    printf '%s\n' "$before" > "$TEST_TMPDIR/$name"
    [ "$status" -eq 1 ] || { echo "removing '$label' exited $status, expected 1"; return 1; }
    [[ "$output" == *"$label"* ]] || { echo "removing '$label' did not name it: $output"; return 1; }
  done
  # All 17 restored: back to green.
  run "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "re-wrapping an anchored paragraph does not fail the gate (no fail-open on reflow)" {
  sed -i.bak 's/Keep removal, raw unlinking,/Keep removal,\
raw unlinking,/' "$TEST_TMPDIR/cdr.md"
  # Explicit branch: a bare `! cmp` is exempt from set -e and would pass on a no-op sed.
  if cmp -s "$TEST_TMPDIR/cdr.md" "$HYDRA_REPO/$CDR/SKILL.md"; then false; fi
  run "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "deleting the whole Profile-merge safety rule (the #1047 regression) fails the gate" {
  grep -vF 'separate entity types and labels' "$TEST_TMPDIR/cdr.md" > "$TEST_TMPDIR/cdr.tmp"
  mv "$TEST_TMPDIR/cdr.tmp" "$TEST_TMPDIR/cdr.md"
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL:"* ]]
}

@test "a missing input file exits 2, not 0" {
  export CDR_SKILL_FILE="$TEST_TMPDIR/does-not-exist.md"
  run "$SCRIPT"
  [ "$status" -eq 2 ]
}
