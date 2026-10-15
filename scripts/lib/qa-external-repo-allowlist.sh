#!/usr/bin/env bash
set -euo pipefail

# qa-external-repo-allowlist.sh — the ONE list of Muso-AI repos allowed to drive
# an external QA auto-review in hydra.
# ===========================================================================
# Used by .github/workflows/external-pr-review.yml in BOTH places that act on an
# (attacker-influenced) repository_dispatch payload:
#   1. the visibility-ack step, which WRITES to the target PR with the runner's
#      adk47 / QA_ACK_PAT credentials, and
#   2. the validate + dispatch step, which drives the review itself.
# They must gate on the same list from the same file: an ack that ran ahead of
# the allowlist would let any caller holding a dispatch PAT aim hydra's
# credentials at an arbitrary Muso-AI repo, even though the review is refused
# a step later.
#
# FAIL-CLOSED: an unlisted repo exits 1 with no output. Callers MUST treat a
# non-zero exit as "refuse" (dispatch step) or "skip" (ack step).
#
# Also enumerates the same REPOS array (one owner/repo per line, exit 0) for a
# reconciler that needs to walk the whole set instead of testing one repo. This
# is the ONE list — duplicating it elsewhere is forbidden, so enumeration reads
# the same array the predicate loop below matches against; the parity is
# structural, not maintained by hand.
#
# ENUMERATION IS ENV-GATED, NOT A FLAG, AND THAT IS LOAD-BEARING.
# .github/workflows/external-pr-review.yml passes the raw, attacker-influenceable
# `client_payload.repo` into this script as its single argument, and every caller
# reads rc 0 as "allowed". An argv flag cannot be made safe here: a payload of
# the literal string `--list` produces argv IDENTICAL to a trusted enumeration
# call, so "exact, sole argument" distinguishes nothing. That branch returned 0,
# which let the ack step cross its credential gate and attempt a GitHub API write
# on an unvalidated repo. So enumeration now requires
# QA_EXTERNAL_REPO_ALLOWLIST_ENUMERATE=1 **and zero arguments** — a payload is
# always an argument, so it can never reach the enumeration path regardless of
# ambient environment, and any invocation WITH an argument is always and only the
# fail-closed predicate.
#
# The format guard stays as defense in depth: every argument must match
# ^Muso-AI/[A-Za-z0-9._-]+$ before it is compared against the array, so traversal,
# foreign owners, and flag-shaped input are refused before membership is tested.
#
# Adding a repo = one array line below, plus a Slack-UID mapping for its
# authors in scripts/lib/qa-author-slack-uid.sh (that map is fail-closed too).
#
# Usage:   qa-external-repo-allowlist.sh <owner/repo>
#          QA_EXTERNAL_REPO_ALLOWLIST_ENUMERATE=1 qa-external-repo-allowlist.sh
# Exit:    0 = allowed (or enumeration, with output), 1 = not allowed (no
#          output), 2 = usage error.

die() { echo "qa-external-repo-allowlist: $2" >&2; exit "$1"; }

REPOS=(
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
  # 2026-09-17: ten active repos onboarded in one pass — each got its own
  # .github/workflows/qa-autoreview-trigger.yml in the same rollout, so a PR there
  # now fires external-qa-review instead of being silently unreviewed. Only the
  # first three had a trigger before (platform-data-processing-v4, tests-web-e2e,
  # muso-skills) — they were already listed here and are deliberately NOT repeated.
  # Authors without a Slack-UID mapping in scripts/lib/qa-author-slack-uid.sh
  # still fail-closed to "skip" (omamchich, ihor-shchuruk as of this date), so
  # those PRs are onboarded-but-unreviewed until their UIDs land.
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
  # 2026-09-17 (same rollout): the plaque worker found Muso-AI/digital-plaque
  # missing from this fail-closed list while its own qa-autoreview-trigger was
  # being added in Muso-AI/digital-plaque#151 — a trigger whose dispatches this
  # list would otherwise refuse. muso-data-steward needs no line here: it is
  # already listed above.
  Muso-AI/digital-plaque
  # 2026-09-17 (captain: 'just add qa to all repos'): the remaining 44
  # non-archived, non-empty repos that lacked the trigger — the long tail
  # beyond the active set above. Each got its own qa-autoreview-trigger.yml
  # in the same widening pass. Listed here so their dispatches are accepted
  # rather than refused one step into hydra. Note: 17 of these have GitHub
  # Actions disabled repo-wide and will not run until it is enabled, and all
  # but ai-chat-service/website/web-encore are org-PAT-only (see the org
  # DEVOPS_DISPATCH_PAT 401).
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
  # 2026-10-09: private monorepo of the Klaviyo/Knock/Amplitude stack swap (created
  # 2026-10-06, after #972's all-repos pass). Authors (adk47) are already mapped.
  Muso-AI/muso-messaging
  Muso-AI/muso-backend
  # Add more as repos come into scope, e.g.:
  #   Muso-AI/<repo>
)

# Enumeration: env-gated AND argument-free. A workflow payload is always passed
# as an argument, so it can never reach this branch even if the env var were
# somehow set in the runner -- the arg-count check below is what makes that true.
if [ "$#" -eq 0 ]; then
  [ "${QA_EXTERNAL_REPO_ALLOWLIST_ENUMERATE:-}" = "1" ] \
    || die 2 "usage: qa-external-repo-allowlist.sh <owner/repo>  (enumeration needs QA_EXTERNAL_REPO_ALLOWLIST_ENUMERATE=1 and no arguments)"
  printf '%s\n' "${REPOS[@]}"
  exit 0
fi

# Any invocation WITH an argument is always and only the fail-closed predicate,
# whatever the environment says.
[ "$#" -eq 1 ] || die 2 "usage: qa-external-repo-allowlist.sh <owner/repo>"

# Refuse anything not shaped like a Muso-AI repo BEFORE the membership loop --
# this is what keeps every other input (including path traversal, foreign
# owners, or a payload crafted to look like a flag) from ever reaching the
# array comparison below.
[[ "$1" =~ ^Muso-AI/[A-Za-z0-9._-]+$ ]] || exit 1

for r in "${REPOS[@]}"; do
  [ "$1" = "$r" ] && exit 0
done
exit 1  # unlisted -> fail-closed (caller refuses / skips)
