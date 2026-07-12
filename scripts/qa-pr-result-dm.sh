#!/usr/bin/env bash
set -euo pipefail

# qa-pr-result-dm.sh — send a QA auto-review result to the PR author and copy
# the same verdict into the all-review QA feed.
#
# Usage:
#   qa-pr-result-dm.sh <repo> <pr> <author-slack-uid> <text> [author-thread-ts]
#
# Env overrides:
#   QA_THREAD_STATE_DIR  per-PR thread-root store (default: /var/lib/hydra-qa/pr-threads)
#   QA_SLACK_DM          path to qa-slack-dm.sh (default: sibling of this script)
#   QA_REVIEW_FEED_UIDS  optional comma/space-separated Slack UIDs copied on every
#                        result (default: Aaron, U7RP6HKUZ). Use empty to disable.

QA_THREAD_STATE_DIR="${QA_THREAD_STATE_DIR:-/var/lib/hydra-qa/pr-threads}"
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
QA_SLACK_DM="${QA_SLACK_DM:-$SELF_DIR/qa-slack-dm.sh}"
QA_REVIEW_FEED_UIDS="${QA_REVIEW_FEED_UIDS-U7RP6HKUZ}"

die() { echo "qa-pr-result-dm: $2" >&2; exit "$1"; }

[ "$#" -ge 4 ] && [ "$#" -le 5 ] \
  || die 2 "usage: qa-pr-result-dm.sh <repo> <pr> <author-slack-uid> <text> [author-thread-ts]"
repo="$1"
pr="$2"
author_uid="$3"
text="$4"
author_thread_ts="${5:-}"

[ -n "$repo" ] || die 2 "repo is empty."
[[ "$pr" =~ ^[0-9]+$ ]] || die 2 "pr must be numeric, got '$pr'."
[ -n "$author_uid" ] || die 2 "author-slack-uid is empty."
[ -n "$text" ] || die 2 "text is empty."

safe_repo="${repo//\//__}"
mkdir -p "$QA_THREAD_STATE_DIR" 2>/dev/null || true

post_to_user() {  # post_to_user <slack_uid> <text> [thread_ts]
  bash "$QA_SLACK_DM" "$1" "$2" "${3:-}" 2>/dev/null || true
}

feed_state_file() {  # feed_state_file <slack_uid>
  printf '%s/%s-pr-%s-uid-%s.ts\n' "$QA_THREAD_STATE_DIR" "$safe_repo" "$pr" "$1"
}

# Author delivery is the primary contract. If it fails, surface that exit so the
# caller can still decide how to report it; feed fan-out remains best-effort.
author_ts="$(post_to_user "$author_uid" "$text" "$author_thread_ts")"
[ -n "$author_ts" ] || die 1 "author result DM failed."

if [ -n "$QA_REVIEW_FEED_UIDS" ]; then
  # shellcheck disable=SC2206
  feed_uids=( ${QA_REVIEW_FEED_UIDS//,/ } )
  for feed_uid in "${feed_uids[@]}"; do
    [ -n "$feed_uid" ] || continue
    [ "$feed_uid" != "$author_uid" ] || continue
    feed_state="$(feed_state_file "$feed_uid")"
    feed_root=""
    [ -f "$feed_state" ] && feed_root="$(cat "$feed_state" 2>/dev/null || true)"
    if [ -n "$feed_root" ]; then
      if [ -z "$(post_to_user "$feed_uid" "$text" "$feed_root")" ]; then
        feed_new_root="$(post_to_user "$feed_uid" "$text")"
        [ -n "$feed_new_root" ] && printf '%s\n' "$feed_new_root" > "$feed_state" 2>/dev/null || true
      fi
    else
      feed_new_root="$(post_to_user "$feed_uid" "$text")"
      [ -n "$feed_new_root" ] && printf '%s\n' "$feed_new_root" > "$feed_state" 2>/dev/null || true
    fi
  done
fi

printf '%s\n' "$author_ts"
