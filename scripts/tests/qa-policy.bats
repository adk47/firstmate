#!/usr/bin/env bats
# Tests for scripts/lib/qa-policy.sh — the fail-closed policy reader.
#
# The lib exists to stop three situations collapsing into one answer: "not a
# member", "key missing/wrong type", and "file unreadable". Every test below is
# about keeping them distinct, because the whole bug class it replaced was
# `jq -e '(.list // []) | index($r)'` quietly turning (2) and (3) into (1).
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"

setup() {
  TEST_TMPDIR="$(mktemp -d)"; export TEST_TMPDIR
  POL="$TEST_TMPDIR/policy.json"
  # shellcheck source=../lib/qa-policy.sh
  source "$HYDRA_REPO/scripts/lib/qa-policy.sh"
}
teardown() { rm -rf "$TEST_TMPDIR"; }

pol() { printf '%s' "$1" > "$POL"; }

# ── qa_policy_valid: shape ───────────────────────────────────────────────

@test "valid: a well-formed policy passes" {
  pol '{"merge_gate_repos":[],"identity":{"bot_logins":["adk47"],"app_repos":[]}}'
  run qa_policy_valid "$POL"
  [ "$status" -eq 0 ]
}

@test "valid: absent keys are allowed (callers assert what they need)" {
  pol '{}'
  run qa_policy_valid "$POL"
  [ "$status" -eq 0 ]
}

@test "valid: an unreadable file fails" {
  run qa_policy_valid "$TEST_TMPDIR/does-not-exist.json"
  [ "$status" -ne 0 ]
}

@test "valid: malformed JSON fails" {
  pol '{"merge_gate_repos": not-json'
  run qa_policy_valid "$POL"
  [ "$status" -ne 0 ]
}

@test "valid: a non-array list key fails" {
  pol '{"merge_gate_repos":{}}'
  run qa_policy_valid "$POL"
  [ "$status" -ne 0 ]
}

# ── qa_policy_valid: .identity.bot_logins element shape ──────────────────
# Every wrong shape here fails SILENTLY downstream rather than raising, which
# is why this key is validated to its elements and its siblings are not.

@test "bot_logins: an OBJECT fails (index() would match nothing, forever)" {
  pol '{"identity":{"bot_logins":{}}}'
  run qa_policy_valid "$POL"
  [ "$status" -ne 0 ]
}

@test "bot_logins: a bare STRING fails (index() degrades to a substring test)" {
  # With "adk47" as a string, login "adk4" would classify as the bot.
  pol '{"identity":{"bot_logins":"adk47"}}'
  run qa_policy_valid "$POL"
  [ "$status" -ne 0 ]
}

@test "bot_logins: non-string elements fail" {
  pol '{"identity":{"bot_logins":[123]}}'
  run qa_policy_valid "$POL"
  [ "$status" -ne 0 ]
}

@test "bot_logins: an empty-string element fails" {
  pol '{"identity":{"bot_logins":[""]}}'
  run qa_policy_valid "$POL"
  [ "$status" -ne 0 ]
}

@test "bot_logins: an EMPTY array is allowed here on purpose" {
  # Non-emptiness is a per-caller requirement, not a schema one: refusing it in
  # the shared validator would fail callers that never classify a bot.
  pol '{"identity":{"bot_logins":[]}}'
  run qa_policy_valid "$POL"
  [ "$status" -eq 0 ]
}

@test "bot_logins: absent is allowed (matches the sibling convention)" {
  pol '{"identity":{"app_repos":[]}}'
  run qa_policy_valid "$POL"
  [ "$status" -eq 0 ]
}

# ── qa_policy_has: the three distinct answers ────────────────────────────

@test "has: 0 when the value is a member" {
  pol '{"merge_gate_repos":["Muso-AI/hydra"]}'
  run qa_policy_has "$POL" '.merge_gate_repos' "Muso-AI/hydra"
  [ "$status" -eq 0 ]
}

@test "has: 1 when the array is well-formed and the value is absent" {
  pol '{"merge_gate_repos":["Muso-AI/other"]}'
  run qa_policy_has "$POL" '.merge_gate_repos' "Muso-AI/hydra"
  [ "$status" -eq 1 ]
}

@test "has: 1 for an EMPTY array — not a member, not an error" {
  pol '{"merge_gate_repos":[]}'
  run qa_policy_has "$POL" '.merge_gate_repos' "Muso-AI/hydra"
  [ "$status" -eq 1 ]
}

@test "has: 2 when the key is missing (never read as 'not a member')" {
  pol '{}'
  run qa_policy_has "$POL" '.merge_gate_repos' "Muso-AI/hydra"
  [ "$status" -eq 2 ]
}

@test "has: 2 when the key is the wrong type" {
  pol '{"merge_gate_repos":{}}'
  run qa_policy_has "$POL" '.merge_gate_repos' "Muso-AI/hydra"
  [ "$status" -eq 2 ]
}

@test "has: 2 when the file is unreadable" {
  run qa_policy_has "$TEST_TMPDIR/nope.json" '.merge_gate_repos' "Muso-AI/hydra"
  [ "$status" -eq 2 ]
}

@test "has: 2 on malformed JSON" {
  pol '{"merge_gate_repos": not-json'
  run qa_policy_has "$POL" '.merge_gate_repos' "Muso-AI/hydra"
  [ "$status" -eq 2 ]
}

@test "has: works on a NESTED path (.identity.app_repos)" {
  pol '{"identity":{"app_repos":["Muso-AI/hydra"]}}'
  run qa_policy_has "$POL" '.identity.app_repos' "Muso-AI/hydra"
  [ "$status" -eq 0 ]
}

# ── the live policy must satisfy its own validator ───────────────────────

@test "the repo's real policy passes qa_policy_valid" {
  run qa_policy_valid "$HYDRA_REPO/policies/qa-approval-policy.json"
  [ "$status" -eq 0 ]
}
