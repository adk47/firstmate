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

# The output becomes a commit-status description: one line, <=140 chars
# (qa-review-status.sh cuts at 137 + "..."). So the seen values go BEFORE the
# prose and only the raw gh text, which is last, is ever cut.
err="$(printf '%s' "$err" | tr '\n\r' '  ')"

seen=""
if [ -n "${QA_GH_RATELIMIT_REMAINING:-}" ]; then
  seen="[remaining=${QA_GH_RATELIMIT_REMAINING:0:8}"
  reset="${QA_GH_RATELIMIT_RESET:-}"
  if [[ "$reset" =~ ^[0-9]+$ ]]; then
    seen+=", resets $(date -u -d "@${reset}" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
      || date -u -r "${reset}" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "@${reset}")"
  elif [ -n "$reset" ]; then
    seen+=", reset=${reset:0:12}"
  fi
  seen+="] "
fi

shopt -s nocasematch
if [[ "$err" == *"secondary rate limit"* || "$err" == *"abuse detection"* ]]; then
  out="CANNOT REVIEW: ${seen}GitHub secondary rate limit (burst), HTTP 403; quota may be full, retry in minutes"
elif [[ "$err" == *"rate limit exceeded"* ]]; then
  out="CANNOT REVIEW: ${seen}GitHub primary rate limit (hourly quota) exhausted, HTTP 403"
else
  out="CANNOT REVIEW: ${seen}GitHub HTTP 403, permission or resource error, not throttling: ${err}"
fi
echo "${out:0:140}"
