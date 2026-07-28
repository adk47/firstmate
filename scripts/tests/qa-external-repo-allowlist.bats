#!/usr/bin/env bats
# Tests for scripts/lib/qa-external-repo-allowlist.sh — the single source of
# truth for which Muso-AI repos may drive an external QA auto-review.
#
# WHY this matters (not just "the case statement works"): the external-pr-review
# workflow acts on an attacker-influenceable repository_dispatch payload with
# hydra's own adk47 / QA_ACK_PAT credentials. Anything unlisted MUST fail-closed
# BEFORE any GitHub write, so a caller holding a dispatch PAT cannot aim those
# credentials at an arbitrary repo. These tests encode that fail-closed contract.
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
SCRIPT="$HYDRA_REPO/scripts/lib/qa-external-repo-allowlist.sh"
WORKFLOW="$HYDRA_REPO/.github/workflows/external-pr-review.yml"

@test "allowlisted repo -> exit 0" {
  run "$SCRIPT" Muso-AI/core-backend
  [ "$status" -eq 0 ]
}

@test "every onboarded repo is accepted" {
  for repo in Muso-AI/ads-manager Muso-AI/auth Muso-AI/web-credits \
              Muso-AI/web-credits-next Muso-AI/industry-data-processing \
              Muso-AI/octave-ui Muso-AI/core-backend Muso-AI/muso-cli \
              Muso-AI/H-DevOps Muso-AI/analytics-worker \
              Muso-AI/platform-data-processing; do
    run "$SCRIPT" "$repo"
    [ "$status" -eq 0 ] || { echo "rejected onboarded repo: $repo"; return 1; }
  done
}

@test "unlisted Muso-AI repo -> exit 1, no output (fail-closed)" {
  run "$SCRIPT" Muso-AI/hydra
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "foreign owner -> exit 1 (owner is part of the match, not just the name)" {
  run "$SCRIPT" evil-org/core-backend
  [ "$status" -eq 1 ]
}

@test "path traversal / API-escape attempts are rejected" {
  for repo in "Muso-AI/core-backend/../../hydra" "Muso-AI/core-backend?x=1" \
              "Muso-AI/core-backend " " Muso-AI/core-backend" \
              "muso-ai/core-backend" "Muso-AI/"; do
    run "$SCRIPT" "$repo"
    [ "$status" -eq 1 ] || { echo "accepted hostile repo: '$repo'"; return 1; }
  done
}

@test "empty arg -> exit 1 (not accepted)" {
  run "$SCRIPT" ""
  [ "$status" -eq 1 ]
}

@test "missing arg -> usage exit 2" {
  run "$SCRIPT"
  [ "$status" -eq 2 ]
}

@test "the ack step gates on this script BEFORE any gh API call" {
  # Regression guard for the #755 review finding: the visibility-ack step used
  # to write to the target PR before the allowlist was consulted.
  ack_step="$(awk '/^      - name: Ack on target PR/,/^      - name: Checkout/' "$WORKFLOW")"
  [ -n "$ack_step" ]
  gate_line="$(echo "$ack_step" | grep -n 'qa-external-repo-allowlist.sh' | head -1 | cut -d: -f1)"
  first_gh="$(echo "$ack_step" | grep -n 'gh api' | head -1 | cut -d: -f1)"
  [ -n "$gate_line" ]
  [ -n "$first_gh" ]
  [ "$gate_line" -lt "$first_gh" ]
}

@test "the dispatch step also gates on this script (defense in depth)" {
  run grep -c 'qa-external-repo-allowlist.sh' "$WORKFLOW"
  [ "$status" -eq 0 ]
  [ "$output" -ge 2 ]
}

@test "checkout precedes the ack step so the shared allowlist is on disk" {
  checkout_line="$(grep -n '^      - name: Checkout' "$WORKFLOW" | head -1 | cut -d: -f1)"
  ack_line="$(grep -n '^      - name: Ack on target PR' "$WORKFLOW" | head -1 | cut -d: -f1)"
  [ -n "$checkout_line" ]
  [ -n "$ack_line" ]
  [ "$checkout_line" -lt "$ack_line" ]
}
