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
  Muso-AI/tests-web-e2e
  Muso-AI/muso-skills
  Muso-AI/platform-ticker
  Muso-AI/feed-service
  Muso-AI/analytics-controller
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
