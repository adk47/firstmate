#!/usr/bin/env bats
# Tests for scripts/lib/qa-author-slack-uid.sh — the GitHub-login -> Slack-UID
# map the external-pr-review workflow uses to decide who to DM (and hand to
# qa-pr-approve.sh as the requester). Unknown logins MUST fail-closed so the
# caller skips the PR rather than DM nobody.
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
SCRIPT="$HYDRA_REPO/scripts/lib/qa-author-slack-uid.sh"

@test "known login: nsollazzo -> Nick" {
  run "$SCRIPT" nsollazzo
  [ "$status" -eq 0 ]
  [ "$output" = "U0AL36NADEY" ]
}

@test "known login: liflovs -> Serhii" {
  run "$SCRIPT" liflovs
  [ "$status" -eq 0 ]
  [ "$output" = "U03TYGJF1N3" ]
}

@test "unknown login -> exit 1, no output (fail-closed)" {
  run "$SCRIPT" some-random-dev
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "missing arg -> usage exit 2" {
  run "$SCRIPT"
  [ "$status" -eq 2 ]
}
