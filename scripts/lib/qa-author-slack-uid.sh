#!/usr/bin/env bash
set -euo pipefail

# qa-author-slack-uid.sh — map a GitHub login to the Slack UID the QA auto-review
# bot should DM (and hand to qa-pr-approve.sh as the requester).
# ===========================================================================
# Used by .github/workflows/external-pr-review.yml to resolve the PR author of a
# non-hydra repo (e.g. Muso-AI/ads-manager) before dispatching a review. There is
# no other GitHub-login -> Slack-UID source in this repo, so this is the one map.
#
# FAIL-CLOSED: an unknown login exits 1 with no output. The caller MUST treat a
# non-zero exit as "skip this PR" — we never dispatch a review we can't DM the
# author about (a silent DM-to-nobody is worse than no review).
#
# Adding a developer = one `case` line below. The UIDs match the approve
# allowlist in scripts/qa-pr-approve.sh (ALLOWED_UIDS); only authors that are
# ALSO in that allowlist will get an auto-approval — others degrade to
# review-only, which the skill handles gracefully.
#
# Usage:   qa-author-slack-uid.sh <github-login>
# Output:  the Slack UID on stdout (exit 0), or nothing (exit 1) if unknown.

die() { echo "qa-author-slack-uid: $2" >&2; exit "$1"; }

[ "$#" -eq 1 ] || die 2 "usage: qa-author-slack-uid.sh <github-login>"
login="$1"

case "$login" in
  nsollazzo) echo "U0AL36NADEY" ;;  # Nick
  liflovs)   echo "U03TYGJF1N3" ;;  # Serhii
  adk47)     echo "U7RP6HKUZ"   ;;  # Aaron (authors web-credits-next PRs; the bot
                                    # can't self-approve, so those degrade to review-only)
  azure-kirin) echo "U03LP8YHLPK" ;;  # Mariia (octave-ui; authors web-credits-next PRs)
  # Add more as repos/authors come into scope, e.g.:
  #   <gh-login>) echo "<slack-uid>" ;;  # map a new GH author to their Slack UID
  *) exit 1 ;;                        # unknown -> fail-closed (caller skips)
esac
