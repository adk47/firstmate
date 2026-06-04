#!/usr/bin/env bash
set -euo pipefail

# qa-pr-thread-dm.sh — send the opening "reviewing PR #N" DM for a QA auto-review
# into that PR's ONE canonical Slack thread, so re-reviews don't spawn a new
# top-level message each time.
# ===========================================================================
# Background: each push re-dispatches a fresh, isolated review session
# (scripts/qa-dispatch-pr-review.sh). Those sessions share no state, so without
# a durable per-PR anchor every run started a brand-new top-level DM. This helper
# remembers the first review's message ts per PR and threads later runs under it.
#
# It wraps scripts/qa-slack-dm.sh (which does the actual Slack Web API call and
# already supports a [thread_ts] arg). The first review of a PR posts top-level
# and records the returned ts as the thread root; every later review replies under
# that root. The root ts is printed on stdout so the caller can thread its result
# reply under it too (same contract the skill already uses for $ts).
#
# Usage:
#   qa-pr-thread-dm.sh <repo> <pr> <slack-uid>
#     - <repo> is owner/name (e.g. Muso-AI/hydra); <pr> numeric; <slack-uid> the author
#     - prints the canonical thread-root ts on stdout (use it to thread the result)
#
# Best-effort by design (mirrors qa-slack-dm.sh): a Slack hiccup must never sink a
# review. On total send failure it prints nothing and exits 1; the caller treats an
# empty ts as "notification skipped" and continues. The state file is only written
# after a real successful post, and persistence failures are non-fatal (they just
# degrade to the old per-run behavior, never worse).
#
# Env overrides (mainly for tests):
#   QA_THREAD_STATE_DIR  per-PR thread-root store (default: /var/lib/hydra-qa/pr-threads)
#                        — lives outside /opt/hydra so deploys don't wipe it.
#   QA_SLACK_DM          path to qa-slack-dm.sh (default: sibling of this script)
#   GH                   GitHub CLI binary, for the best-effort PR-title lookup (default: gh)
# Exit codes: 0 ok | 2 usage | 1 slack send failure (nothing delivered).

QA_THREAD_STATE_DIR="${QA_THREAD_STATE_DIR:-/var/lib/hydra-qa/pr-threads}"
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
QA_SLACK_DM="${QA_SLACK_DM:-$SELF_DIR/qa-slack-dm.sh}"
GH="${GH:-gh}"

die() { echo "qa-pr-thread-dm: $2" >&2; exit "$1"; }

[ "$#" -eq 3 ] || die 2 "usage: qa-pr-thread-dm.sh <repo> <pr> <slack-uid>"
repo="$1"
pr="$2"
uid="$3"
[ -n "$repo" ] || die 2 "repo is empty."
[[ "$pr" =~ ^[0-9]+$ ]] || die 2 "pr must be numeric, got '$pr'."
[ -n "$uid" ] || die 2 "slack-uid is empty."

# Per-PR thread-root file. Sanitize slashes so Muso-AI/hydra -> Muso-AI__hydra.
safe_repo="${repo//\//__}"
state_file="$QA_THREAD_STATE_DIR/${safe_repo}-pr-${pr}.ts"
mkdir -p "$QA_THREAD_STATE_DIR" 2>/dev/null || true

root_ts=""
[ -f "$state_file" ] && root_ts="$(cat "$state_file" 2>/dev/null || true)"

# Best-effort PR title so the note is scannable at a glance. A gh hiccup
# (network/auth/missing PR) must never block the DM -> fall back to no title.
# Strip <>| and newlines so the title can't break the Slack <url|label> link.
pr_url="https://github.com/${repo}/pull/${pr}"
title="$("$GH" pr view "$pr" --repo "$repo" --json title --jq .title 2>/dev/null || true)"
title="$(printf '%s' "$title" | tr -d '<>|\n\r')"
if [ -n "$title" ]; then
  link="<${pr_url}|#${pr}: ${title}>"
else
  link="<${pr_url}|PR #${pr}>"
fi

# Opening note — reads as a follow-up once a thread root already exists.
if [ -n "$root_ts" ]; then
  text="🔄 *Muso QA Bot* — re-reviewing ${link} after a new push. Updated review going to GitHub; I'll follow up here."
else
  text="🔍 *Muso QA Bot* — reviewing ${link} now. Full review going to GitHub; I'll update this thread."
fi

# Post via qa-slack-dm.sh. Echoes the message ts on success, empty on failure
# (best-effort: a non-zero exit must not abort us here).
post() {  # post <text> [thread_ts]
  bash "$QA_SLACK_DM" "$uid" "$1" "${2:-}" 2>/dev/null || true
}

if [ -n "$root_ts" ]; then
  # Re-review: reply under the existing thread root. Discard the reply's own ts —
  # the result reply must thread under root_ts, not under this child message.
  if [ -z "$(post "$text" "$root_ts")" ]; then
    # Root is stale/deleted (or a transient error). Re-anchor: post a fresh
    # top-level note and make it the new root so future runs thread under it.
    new_root="$(post "$text")"
    [ -n "$new_root" ] || die 1 "slack send failed (re-review + fallback)."
    printf '%s\n' "$new_root" > "$state_file" 2>/dev/null || true
    root_ts="$new_root"
  fi
else
  # First review of this PR: the top-level message becomes the canonical root.
  ts="$(post "$text")"
  [ -n "$ts" ] || die 1 "slack send failed (first review)."
  printf '%s\n' "$ts" > "$state_file" 2>/dev/null || true
  root_ts="$ts"
fi

# Hand the caller the thread root so its result reply lands in the same thread.
printf '%s\n' "$root_ts"
