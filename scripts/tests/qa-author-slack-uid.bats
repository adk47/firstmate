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

@test "known login: adk47 -> Aaron" {
  run "$SCRIPT" adk47
  [ "$status" -eq 0 ]
  [ "$output" = "U7RP6HKUZ" ]
}

@test "known login: azure-kirin -> Mariia" {
  run "$SCRIPT" azure-kirin
  [ "$status" -eq 0 ]
  [ "$output" = "U03LP8YHLPK" ]
}

@test "known login: Korpyc -> Artem" {
  run "$SCRIPT" Korpyc
  [ "$status" -eq 0 ]
  [ "$output" = "U02N2NP3H7F" ]
}

@test "unknown login -> exit 1, no output (fail-closed)" {
  run "$SCRIPT" some-random-dev
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

# Fail-closed is the right default, but it makes an untested arm indistinguishable
# from a missing one: a typo'd login silently degrades that author's PRs to
# review-only with nobody notified, and no test goes red. Both `azure-kirin` and
# `Korpyc` shipped unmapped-by-test for exactly that reason. This asserts every
# mapping arm in the script has a positive case above, so the next login added
# cannot repeat it.
@test "every mapping in the script has a positive test case" {
  local arms tested missing=""
  # Case arms look like:  <login>) echo "<UID>" ;;   — skip the `*)` fallback.
  arms="$(grep -oE '^[[:space:]]*[A-Za-z0-9_-]+\)[[:space:]]*echo' "$SCRIPT" \
          | sed -E 's/^[[:space:]]*([A-Za-z0-9_-]+)\).*/\1/' | sort -u)"
  [ -n "$arms" ]
  tested="$(grep -oE '^[[:space:]]*run "\$SCRIPT" [A-Za-z0-9_-]+' "$BATS_TEST_FILENAME" \
            | awk '{print $NF}' | sort -u)"
  for a in $arms; do
    printf '%s\n' "$tested" | grep -qx -- "$a" || missing="$missing $a"
  done
  [ -z "$missing" ] || { echo "mapping(s) with no positive test:$missing" >&2; return 1; }
}

@test "missing arg -> usage exit 2" {
  run "$SCRIPT"
  [ "$status" -eq 2 ]
}
