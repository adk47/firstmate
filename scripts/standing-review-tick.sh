#!/usr/bin/env bash
# standing-review-tick.sh - one scheduled pass of the standing review (scripts/standing_review/review.py).
#
# Cadence: every 2 hours (the timer in docs/standing-review.md). One pass is at most ONE reviewer call on the
# subscription token pool, and no call at all when nothing merged and no plan changed since the last pass.
#
# Runs on the box that can reach the reviewer model (ak47), NOT on node-8, which has no route to it.
#
# It reads the default branch from ITS OWN bare mirror under the state directory, so it never fetches into,
# locks, or otherwise touches a checkout or worktree that a lane is working in. The fetch below is the only
# write this script makes, and it lands in that mirror.
#
# Silent unless something is broken:
#   exit 0   pass complete, nothing to say (stdout empty)
#   exit 10  a defect was paged (the page is on stdout, or went to STANDING_REVIEW_PAGE_CMD)
#   exit 3   the reviewer did not answer: UNMEASURED, never "clean"
#   exit 2   the pass could not run (fetch failed, state unreadable, a page could not be delivered)
#
# Environment:
#   HYDRA_STANDING_REVIEW_STATE   state directory (default ~/.local/state/hydra-standing-review)
#   STANDING_REVIEW_REMOTE        repository to mirror (default: this checkout's origin URL)
#   STANDING_REVIEW_BRANCH        branch to review (default main)
#   STANDING_REVIEW_PAGE_CMD      command that receives each page on stdin (default: print the page)
#   STANDING_REVIEW_DOC_GLOBS     colon-separated globs of plans outside the repository to rotate through
#   STANDING_REVIEW_REVIEWER_CMD  a stand-in reviewer (<cmd> <prompt file> -> the answer); tests use it
# Kill switch: an existing "$STATE/disabled" file skips the pass (exit 0, one line on stderr).
set -euo pipefail

here=$(cd "$(dirname "$(realpath "${BASH_SOURCE[0]}")")" && pwd)
root=$(dirname "$here")
state=${HYDRA_STANDING_REVIEW_STATE:-${XDG_STATE_HOME:-$HOME/.local/state}/hydra-standing-review}
branch=${STANDING_REVIEW_BRANCH:-main}
mirror=$state/mirror.git

if [[ -e $state/disabled ]]; then
  echo "standing-review: disabled by $state/disabled" >&2
  exit 0
fi

remote=${STANDING_REVIEW_REMOTE:-$(git -C "$root" config --get remote.origin.url || true)}
if [[ -z $remote ]]; then
  echo "standing-review: the pass could not run: no remote (set STANDING_REVIEW_REMOTE)" >&2
  exit 2
fi

mkdir -p "$state"
export GIT_TERMINAL_PROMPT=0
if [[ ! -d $mirror ]]; then
  # into a scratch name first: a clone killed half-way must not be mistaken for the mirror next tick
  rm -rf "$mirror.partial"
  if ! git clone --quiet --bare --single-branch --branch "$branch" "$remote" "$mirror.partial" >&2; then
    echo "standing-review: the pass could not run: clone of $remote failed" >&2
    exit 2
  fi
  mv "$mirror.partial" "$mirror"
elif ! git -C "$mirror" fetch --quiet --prune "$remote" "+refs/heads/$branch:refs/heads/$branch" >&2; then
  # a stale mirror would review nothing new and say nothing: that is a failure, not a quiet pass
  echo "standing-review: the pass could not run: fetch of $remote failed" >&2
  exit 2
fi

args=(run --repo "$mirror" --ref "$branch" --state "$state")
if [[ -n ${STANDING_REVIEW_PAGE_CMD:-} ]]; then
  args+=(--page-cmd "$STANDING_REVIEW_PAGE_CMD")
fi
if [[ -n ${STANDING_REVIEW_REVIEWER_CMD:-} ]]; then
  args+=(--reviewer-cmd "$STANDING_REVIEW_REVIEWER_CMD")
fi
if [[ -n ${STANDING_REVIEW_DOC_GLOBS:-} ]]; then
  IFS=: read -r -a globs <<<"$STANDING_REVIEW_DOC_GLOBS"
  for g in "${globs[@]}"; do
    [[ -n $g ]] && args+=(--doc-glob "$g")
  done
fi

exec python3 -I "$here/standing_review/review.py" "${args[@]}"
