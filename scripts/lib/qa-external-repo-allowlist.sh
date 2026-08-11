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
# Adding a repo = one `case` line below, plus a Slack-UID mapping for its
# authors in scripts/lib/qa-author-slack-uid.sh (that map is fail-closed too).
#
# Usage:   qa-external-repo-allowlist.sh <owner/repo>
# Exit:    0 = allowed, 1 = not allowed (no output), 2 = usage error.

die() { echo "qa-external-repo-allowlist: $2" >&2; exit "$1"; }

[ "$#" -eq 1 ] || die 2 "usage: qa-external-repo-allowlist.sh <owner/repo>"

case "$1" in
  Muso-AI/ads-manager) ;;
  Muso-AI/auth) ;;
  Muso-AI/web-credits) ;;
  Muso-AI/web-credits-next) ;;
  Muso-AI/industry-data-processing) ;;
  Muso-AI/octave-ui) ;;
  Muso-AI/core-backend) ;;
  Muso-AI/muso-cli) ;;
  Muso-AI/H-DevOps) ;;
  Muso-AI/analytics-worker) ;;
  Muso-AI/platform-data-processing) ;;
  Muso-AI/tests-web-e2e) ;;
  Muso-AI/feed-service) ;;
  Muso-AI/analytics-controller) ;;
  # Add more as repos come into scope, e.g.:
  #   Muso-AI/<repo>) ;;
  *) exit 1 ;;  # unlisted -> fail-closed (caller refuses / skips)
esac
