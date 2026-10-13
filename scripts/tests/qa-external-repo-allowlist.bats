#!/usr/bin/env bats
# Tests for scripts/lib/qa-external-repo-allowlist.sh — the single source of
# truth for which Muso-AI repos may drive an external QA auto-review.
#
# WHY this matters (not just "the case statement works"): the external-pr-review
# workflow acts on an attacker-influenceable repository_dispatch payload with
# hydra's own adk47 / QA_ACK_PAT credentials. Anything unlisted MUST fail-closed
# BEFORE any GitHub write, so a caller holding a dispatch PAT cannot aim those
# credentials at an arbitrary repo. These tests encode that fail-closed contract.
#
# `--list` enumerates the same array a reconciler needs to walk. Because any
# flag that exits 0 is a potential fail-open hole against the attacker-
# influenceable repo payload, this file also asserts `--list` is recognized
# ONLY as an exact sole argument, and that enumeration + membership can never
# silently drift apart (parity test).
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
SCRIPT="$HYDRA_REPO/scripts/lib/qa-external-repo-allowlist.sh"
WORKFLOW="$HYDRA_REPO/.github/workflows/external-pr-review.yml"

# The onboarded repos, enumerated INDEPENDENTLY of the script under test.
# Deliberately hardcoded: deriving this from the script would make the
# acceptance test below tautological — it would still pass if a repo were
# silently dropped from the allowlist. The drift guard keeps the two in sync.
ONBOARDED_REPOS=(
  Muso-AI/ads-manager
  Muso-AI/auth
  Muso-AI/web-credits
  Muso-AI/web-credits-next
  Muso-AI/industry-data-processing
  Muso-AI/octave-ui
  Muso-AI/core-backend
  Muso-AI/muso-cli
  Muso-AI/H-DevOps
  Muso-AI/analytics-worker
  Muso-AI/platform-data-processing
  Muso-AI/platform-data-processing-v4
  Muso-AI/tests-web-e2e
  Muso-AI/muso-skills
  Muso-AI/platform-ticker
  Muso-AI/feed-service
  Muso-AI/analytics-controller
  Muso-AI/ios-app
  Muso-AI/android-app
  Muso-AI/muso-data-steward
  # 2026-09-17: same ten repos, SAME ORDER as REPOS in the script — the
  # enumeration/parity tests below compare element-by-element, so a reorder in
  # one file without the other is a failure, not a cosmetic diff.
  Muso-AI/chat-bakeoff
  Muso-AI/customer-api-mcp
  Muso-AI/devops
  Muso-AI/hydra-audit
  Muso-AI/mobile
  Muso-AI/mobile-agents
  Muso-AI/muso-docs
  Muso-AI/platform-web
  Muso-AI/render-service
  Muso-AI/website-next
  Muso-AI/digital-plaque
  Muso-AI/muso-embeds
  Muso-AI/help-web
  Muso-AI/tuwunel
  Muso-AI/matrix-dart-sdk
  Muso-AI/omni-gateway
  Muso-AI/muso-sdk
  Muso-AI/ai-chat-service
  Muso-AI/website
  Muso-AI/web-encore
  Muso-AI/core-ai
  Muso-AI/customer-api-docs
  Muso-AI/nocodb-scripts
  Muso-AI/onboarding-nick
  Muso-AI/onboarding-ihor
  Muso-AI/jenkins-shared-library
  Muso-AI/midika
  Muso-AI/openclaw-muso
  Muso-AI/openclaw-gmail
  Muso-AI/openclaw
  Muso-AI/clio-workspace
  Muso-AI/Muso-Ads
  Muso-AI/platform-import-controller
  Muso-AI/platform-data-registry
  Muso-AI/platform-crawling-worker
  Muso-AI/flutter_packages
  Muso-AI/clio-skills
  Muso-AI/terraform-module-aws-fluent-bit
  Muso-AI/terraform-module-keda
  Muso-AI/Voice
  Muso-AI/Clio-KB
  Muso-AI/ByteDance-Proposal
  Muso-AI/muso-mobile-translations
  Muso-AI/web-exploration
  Muso-AI/terraform-module-cluster-autoscaler
  Muso-AI/experiment-puppeteer
  Muso-AI/auth-demo
  Muso-AI/capture-tests
  Muso-AI/distrokids-demo
  Muso-AI/lambda-api-gw-auth-handler
  Muso-AI/terraform-module-aws-cloudwatch-agent
  Muso-AI/terraform-module-aws-lb-controller
  Muso-AI/docker-ci-tools
  Muso-AI/terraform-module-metrics-server
  Muso-AI/quality-checks
  Muso-AI/muso-messaging
)

# The mobile repos were onboarded 2026-08-19 for REVIEW ONLY, on purpose: Artem
# (Korpyc) must keep merging his own PRs whatever the bot says. Two things make
# that true and only one of them lives in this repo, so pin the one that does.
#   - here: Muso-AI/ios-app / android-app must stay OUT of .merge_gate_repos,
#     the switch that turns `qa-review` into a required check GitHub waits on
#     forever.
#   - not here: nobody adding `qa-review` to those repos' branch protection.
#     Verified absent at onboarding (neither develop nor main declares any
#     required_status_checks or required_pull_request_reviews) but not testable
#     from hydra CI -- if it is ever added, this test still passes and NO-GO
#     starts blocking merges.
# A comment saying "advisory" is not enforcement; this is.
@test "the mobile repos are onboarded for REVIEW only -- never merge-gated" {
  local policy="$HYDRA_REPO/policies/qa-approval-policy.json"
  for repo in Muso-AI/ios-app Muso-AI/android-app; do
    run jq -e --arg r "$repo" '.merge_gate_repos | index($r) == null' "$policy"
    [ "$status" -eq 0 ] || {
      echo "$repo is in .merge_gate_repos -- it was onboarded advisory-only, so a NO-GO must never hold its merge"
      return 1
    }
  done
}

@test "allowlisted repo -> exit 0" {
  run "$SCRIPT" Muso-AI/core-backend
  [ "$status" -eq 0 ]
}

@test "every onboarded repo is accepted" {
  for repo in "${ONBOARDED_REPOS[@]}"; do
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

@test "two args -> usage exit 2" {
  run "$SCRIPT" Muso-AI/core-backend Muso-AI/auth
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

# --- --list / enumeration mode -------------------------------------------

@test "enumeration (env, no args) -> exit 0, output is exactly the onboarded repos, one per line" {
  run env QA_EXTERNAL_REPO_ALLOWLIST_ENUMERATE=1 "$SCRIPT"
  [ "$status" -eq 0 ]
  expected="$(printf '%s\n' "${ONBOARDED_REPOS[@]}")"
  [ "$output" = "$expected" ]
}

@test "parity: every enumerated line, fed back as membership arg, exits 0, and counts match" {
  run env QA_EXTERNAL_REPO_ALLOWLIST_ENUMERATE=1 "$SCRIPT"
  [ "$status" -eq 0 ]
  list_count=0
  while IFS= read -r repo; do
    [ -n "$repo" ] || continue
    list_count=$((list_count + 1))
    run "$SCRIPT" "$repo"
    [ "$status" -eq 0 ] || { echo "enumeration emitted a repo the predicate rejects: $repo"; return 1; }
  done <<< "$output"
  [ "$list_count" -eq "${#ONBOARDED_REPOS[@]}" ]
}

@test "glob-shaped input Muso-AI/* -> exit 1 (proves literal compare, not glob match)" {
  run "$SCRIPT" 'Muso-AI/*'
  [ "$status" -eq 1 ]
}

@test "--lists -> refused (argv can never enumerate)" {
  run "$SCRIPT" --lists
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "-x -> not treated as enumeration" {
  run "$SCRIPT" -x
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "--list plus an extra arg -> usage exit 2, not enumeration" {
  run "$SCRIPT" --list extra
  [ "$status" -eq 2 ]
}

@test "leading-space ' --list' -> refused" {
  run "$SCRIPT" ' --list'
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "Muso-AI/a/b -> exit 1 (extra path segment rejected by format guard)" {
  run "$SCRIPT" Muso-AI/a/b
  [ "$status" -eq 1 ]
}

@test "../../etc/passwd -> exit 1" {
  run "$SCRIPT" '../../etc/passwd'
  [ "$status" -eq 1 ]
}

# --- The workflow-payload attack this env gate exists to close ---------------
# external-pr-review.yml passes the raw client_payload.repo as the SINGLE
# argument to this script and reads rc 0 as "allowed". An argv `--list` flag was
# therefore indistinguishable from a trusted enumeration call and returned 0,
# letting the ack step cross its credential gate on an unvalidated repo.

@test "ATTACK: payload '--list' as the single argument is REFUSED (rc 1), never enumeration" {
  run "$SCRIPT" -- '--list'
  [ "$status" -ne 0 ]
  run "$SCRIPT" '--list'
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "ATTACK: payload '--list' is refused EVEN IF the enumerate env var is set" {
  run env QA_EXTERNAL_REPO_ALLOWLIST_ENUMERATE=1 "$SCRIPT" '--list'
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "an argument is ALWAYS the predicate, never enumeration, whatever the env says" {
  run env QA_EXTERNAL_REPO_ALLOWLIST_ENUMERATE=1 "$SCRIPT" 'Muso-AI/not-a-real-repo'
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  run env QA_EXTERNAL_REPO_ALLOWLIST_ENUMERATE=1 "$SCRIPT" 'Muso-AI/core-backend'
  [ "$status" -eq 0 ]
}

@test "no args WITHOUT the env var -> usage exit 2, never a silent empty list" {
  run "$SCRIPT"
  [ "$status" -eq 2 ]
}
