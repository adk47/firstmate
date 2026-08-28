#!/usr/bin/env bats
# Unit tests for the skills-all config include guard.
#
# The guard's whole value is that it fires BEFORE a deploy rather than during one, so the
# cases below are the three that matter: a missing pair, a pair placed too late (dead rule),
# and an unreadable array. Each is exercised against a constructed tree rather than asserted
# about in prose.

HYDRA_REPO="${BATS_TEST_DIRNAME}/../.."
GUARD="$HYDRA_REPO/scripts/lib/check-skills-config-includes.sh"

setup() {
  TEST_TMPDIR="$(mktemp -d)"
  mkdir -p "$TEST_TMPDIR/scripts"
  cp "$HYDRA_REPO/scripts/deploy.sh" "$TEST_TMPDIR/scripts/deploy.sh"
}
teardown() { rm -rf "$TEST_TMPDIR"; }

@test "the real repo passes its own guard" {
  run "$GUARD" "$HYDRA_REPO" "$HYDRA_REPO/scripts/deploy.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK:"* ]]
}

@test "a config dir with NO include pair fails, and the message names the fix" {
  mkdir -p "$TEST_TMPDIR/skills-all/brand-new-skill/config"
  run "$GUARD" "$TEST_TMPDIR" "$TEST_TMPDIR/scripts/deploy.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"brand-new-skill"* ]]
  # The message must be actionable: an author reading it should not have to go and work
  # out the two lines to add.
  [[ "$output" == *"--include='brand-new-skill/config/'"* ]]
}

@test "an include placed AFTER --exclude='config/' is DEAD and still fails" {
  # This is the real trap and the reason the guard checks ordering rather than presence:
  # rsync filter rules are first-match-wins, so a late include reads as protection in the
  # diff while shipping nothing.
  mkdir -p "$TEST_TMPDIR/skills-all/late-skill/config"
  perl -0pi -e "s{  --exclude='config/'}{  --exclude='config/'\n  --include='late-skill/config/'\n  --include='late-skill/config/**'}" "$TEST_TMPDIR/scripts/deploy.sh"
  grep -q "late-skill/config/" "$TEST_TMPDIR/scripts/deploy.sh"   # precondition: it IS present
  run "$GUARD" "$TEST_TMPDIR" "$TEST_TMPDIR/scripts/deploy.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"late-skill"* ]]
}

@test "an include placed BEFORE the exclude passes" {
  mkdir -p "$TEST_TMPDIR/skills-all/early-skill/config"
  perl -0pi -e "s{  --exclude='config/'}{  --include='early-skill/config/'\n  --include='early-skill/config/**'\n  --exclude='config/'}" "$TEST_TMPDIR/scripts/deploy.sh"
  run "$GUARD" "$TEST_TMPDIR" "$TEST_TMPDIR/scripts/deploy.sh"
  [ "$status" -eq 0 ]
}

@test "an unreadable array FAILS CLOSED with exit 2, not a silent pass" {
  # An empty array would make the ordering test vacuous. "I could not read the rules" is a
  # different answer from "the rules are fine", and only one of them is an answer.
  mkdir -p "$TEST_TMPDIR/skills-all/some-skill/config"
  perl -0pi -e "s/^RSYNC_EXCLUDES=\(/RSYNC_EXCLUDES_RENAMED=(/m" "$TEST_TMPDIR/scripts/deploy.sh"
  run "$GUARD" "$TEST_TMPDIR" "$TEST_TMPDIR/scripts/deploy.sh"
  [ "$status" -eq 2 ]
  [[ "$output" == *"extraction problem"* ]]
}

@test "a missing deploy.sh is exit 2, not exit 0" {
  run "$GUARD" "$TEST_TMPDIR" "$TEST_TMPDIR/scripts/does-not-exist.sh"
  [ "$status" -eq 2 ]
}

@test "sentry-issue-triage specifically — the dir that broke every deploy on 2026-08-28" {
  # Regression for the actual incident: #874 landed this config with no pair and the
  # fleet deploy failed from 4539ddb0 onward.
  [ -d "$HYDRA_REPO/skills-all/sentry-issue-triage/config" ]
  run "$GUARD" "$HYDRA_REPO" "$HYDRA_REPO/scripts/deploy.sh"
  [ "$status" -eq 0 ]
}
