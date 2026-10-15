#!/usr/bin/env bash
set -euo pipefail

# qa-gh-error-class.sh — classify a failed `gh` call that blocked a QA review and
# print the one-line CANNOT REVIEW reason (MUS-11176).
# ===========================================================================
# The skill used to hard-code "GitHub API rate limit blocked the review bundle"
# for every 403. That sentence is only true for a PRIMARY quota 403; a secondary
# (burst) limit or a plain permission 403 leaves the quota full, so the next
# reader went hunting for an empty bucket that was not empty.
#
# Usage:  qa-gh-error-class.sh "<gh error text>"     (or the text on stdin)
# Optional env, when the caller read them: QA_GH_RATELIMIT_REMAINING,
#   QA_GH_RATELIMIT_RESET (epoch seconds) — printed so no reader has to re-derive.
# Exit: 0 classified (a 403), reason on stdout | 1 not a 403, no output (the
#   caller keeps its own wording).
# The output always starts with `CANNOT REVIEW: ` — scripts/qa-review-status.sh
# keys its no-clobber-a-standing-GO rule on exactly that prefix.

err="${1-}"
[ -n "$err" ] || { [ -t 0 ] || err="$(cat)"; }

[[ "$err" == *"HTTP 403"* ]] || exit 1

seen=""
if [ -n "${QA_GH_RATELIMIT_REMAINING:-}" ]; then
  seen=" (x-ratelimit-remaining=${QA_GH_RATELIMIT_REMAINING}"
  if [ -n "${QA_GH_RATELIMIT_RESET:-}" ]; then
    seen+=", window resets $(date -u -d "@${QA_GH_RATELIMIT_RESET}" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
      || date -u -r "${QA_GH_RATELIMIT_RESET}" +%Y-%m-%dT%H:%M:%SZ)"
  fi
  seen+=")"
fi

shopt -s nocasematch
if [[ "$err" == *"secondary rate limit"* ]]; then
  echo "CANNOT REVIEW: GitHub secondary rate limit (burst) blocked the review bundle, HTTP 403 — the hourly quota is not necessarily empty; retry after a few minutes${seen}"
elif [[ "$err" == *"rate limit exceeded"* ]]; then
  echo "CANNOT REVIEW: GitHub primary rate limit (hourly quota) is exhausted, HTTP 403${seen}"
else
  echo "CANNOT REVIEW: GitHub returned HTTP 403 (a permission or resource error, not throttling) —${err:0:160}${seen}"
fi
