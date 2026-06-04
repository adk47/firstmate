#!/usr/bin/env bash
set -euo pipefail

# qa-pr-merged-dm.sh — when a QA-reviewed PR is merged, post a one-line "PR #N
# merged" closure reply into that PR's existing QA review thread, so the DM
# thread the QA bot opened during review doesn't just go silent after merge.
# ===========================================================================
# Background: scripts/qa-pr-thread-dm.sh opens (and re-uses) ONE canonical Slack
# DM thread per PR during auto-review, recording the thread-root ts at
# $QA_THREAD_STATE_DIR/<safe_repo>-pr-<pr>.ts. This helper is the post-merge
# bookend: it reads that same root ts and threads a closure note under it.
#
# The presence of the state file IS the precise "QA reviewed this PR" signal —
# if there is no thread root for the PR, QA never opened a thread, so there is
# nothing to close and we no-op. (The merge-trigger workflow already scope-guards
# author/base; this is the "was it actually reviewed" half.)
#
# Best-effort by design: a post-merge note is cosmetic. A Slack hiccup (or a
# missing thread) must NEVER fail the merge-trigger workflow, so the only
# non-zero exit is a usage error. It wraps scripts/qa-slack-dm.sh (same Slack
# Web API + qa-account-token path the opener uses).
#
# Usage:
#   qa-pr-merged-dm.sh <repo> <pr> <slack-uid>
#     - <repo> is owner/name (e.g. Muso-AI/hydra); <pr> numeric; <slack-uid> the author
#
# Env overrides (mainly for tests):
#   QA_THREAD_STATE_DIR  per-PR thread-root store (default: /var/lib/hydra-qa/pr-threads)
#                        — the same store qa-pr-thread-dm.sh writes.
#   QA_SLACK_DM          path to qa-slack-dm.sh (default: sibling of this script)
# Exit codes: 0 ok / no-op / best-effort skip | 2 usage.

QA_THREAD_STATE_DIR="${QA_THREAD_STATE_DIR:-/var/lib/hydra-qa/pr-threads}"
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
QA_SLACK_DM="${QA_SLACK_DM:-$SELF_DIR/qa-slack-dm.sh}"

die() { echo "qa-pr-merged-dm: $2" >&2; exit "$1"; }

[ "$#" -eq 3 ] || die 2 "usage: qa-pr-merged-dm.sh <repo> <pr> <slack-uid>"
repo="$1"
pr="$2"
uid="$3"
[ -n "$repo" ] || die 2 "repo is empty."
[[ "$pr" =~ ^[0-9]+$ ]] || die 2 "pr must be numeric, got '$pr'."
[ -n "$uid" ] || die 2 "slack-uid is empty."

# Per-PR thread-root file. Sanitize slashes so Muso-AI/hydra -> Muso-AI__hydra,
# identical to qa-pr-thread-dm.sh so we read the exact file the opener wrote.
safe_repo="${repo//\//__}"
state_file="$QA_THREAD_STATE_DIR/${safe_repo}-pr-${pr}.ts"

root_ts=""
[ -f "$state_file" ] && root_ts="$(cat "$state_file" 2>/dev/null || true)"

# No thread root -> QA never opened a review thread for this PR. Nothing to close.
if [ -z "$root_ts" ]; then
  echo "qa-pr-merged-dm: no QA review thread for ${repo}#${pr}; nothing to close." >&2
  exit 0
fi

text="Muso QA Bot here -- PR #${pr} (${repo}) was just merged. Closing out this review thread."

# Thread the closure under the recorded root. Best-effort: swallow a Slack hiccup
# so a cosmetic note never sinks the merge workflow.
if [ -z "$(bash "$QA_SLACK_DM" "$uid" "$text" "$root_ts" 2>/dev/null || true)" ]; then
  echo "qa-pr-merged-dm: slack send failed for ${repo}#${pr} (best-effort, ignoring)." >&2
fi
exit 0
