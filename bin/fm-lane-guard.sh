#!/bin/sh
# Lane guard: the copy of the work that outlives a worker's context.
#
# A lane can die with the only copy of real work sitting uncommitted in its
# worktree, and a context-exhausted worker cannot be trusted to save it or to
# stop when told. This script is the artifact that does not live in any worker's
# context: it publishes the lane's current work to a remote ref, and it reports
# the lane that has been reading tokens without ever committing.
#
# Usage: fm-lane-guard.sh <worktree> <base-sha> <budget-minutes>
#
# <lane> is the last path component of <worktree>.
#
# Permissions, and they are the only ones this script has:
#   1. No origin remote: print "REFUSE <lane>: no remote" and exit 2.
#   2. Snapshot the ENTIRE worktree, untracked files included, without touching
#      the worker's branch, index, or HEAD: build a tree through a temporary
#      index (GIT_INDEX_FILE inside a mktemp directory), commit it with
#      commit-tree -p HEAD, point refs/wip/<lane> at that commit, and push the
#      ref with push -qf. The snapshot stages the worktree the way git sees it,
#      so it carries untracked files but not paths .gitignore excludes.
#   3. If the snapshot tree equals HEAD's tree there is nothing to save, so no
#      snapshot and no push happens.
#   4. Record the lane's first-seen time in git config (lane.<lane>.seen). Trip
#      when commits ahead of <base-sha> are zero and <budget-minutes> have
#      elapsed since that first sighting: print the TRIP line and exit 3.
#   5. Otherwise exit 0 and print nothing at all. Silence is the healthy path.
#
# Constraints: POSIX sh with set -eu. Every git call goes through git -C "$wt".
# The script never cds, never checks out, stashes, or resets, and never writes
# the worker's real index or HEAD. It deletes nothing but its own scratch index
# directory, which it created. The only forced operation is the explicit
# push -qf of the wip ref.
#
# Exit: 0 healthy, 2 refused or invalid request, 3 tripped. A push that fails is
# a real error and surfaces as its own nonzero status rather than a false claim
# that the work is saved.
set -eu

usage() {
  printf 'usage: fm-lane-guard.sh <worktree> <base-sha> <budget-minutes>\n' >&2
}

if [ "$#" -ne 3 ]; then
  usage
  exit 2
fi

wt=$1
base=$2
budget=$3

case $budget in
  '' | *[!0-9]*)
    printf 'error: budget-minutes must be a non-negative integer\n' >&2
    exit 2
    ;;
esac
if [ -z "$base" ]; then
  printf 'error: base-sha is required\n' >&2
  exit 2
fi

top=$(git -C "$wt" rev-parse --show-toplevel 2>/dev/null) || {
  printf 'error: not a git worktree: %s\n' "$wt" >&2
  exit 2
}
wt=$top
lane=${wt##*/}

# Permission 1: a lane with no remote has nowhere to save work, so say so
# instead of producing a snapshot no one else can see.
if ! git -C "$wt" remote get-url origin >/dev/null 2>&1; then
  printf 'REFUSE %s: no remote\n' "$lane"
  exit 2
fi

git -C "$wt" rev-parse --verify --quiet 'HEAD^{commit}' >/dev/null || {
  printf 'error: %s has no commit to snapshot against\n' "$lane" >&2
  exit 2
}
base_sha=$(git -C "$wt" rev-parse --verify --quiet "$base^{commit}") || {
  printf 'error: base-sha is not a commit in %s: %s\n' "$lane" "$base" >&2
  exit 2
}

# Permission 2: snapshot through a scratch index. GIT_INDEX_FILE is set for both
# calls, so the worker's own index file is never opened, let alone rewritten.
idx_dir=$(mktemp -d "${TMPDIR:-/tmp}/fm-lane-guard.XXXXXXXX") || {
  printf 'error: could not create a scratch index directory\n' >&2
  exit 2
}
# The only thing this script removes is its own scratch directory.
trap 'rm -rf "$idx_dir"' EXIT INT HUP TERM
idx_file=$idx_dir/index

GIT_INDEX_FILE=$idx_file git -C "$wt" add -A
tree=$(GIT_INDEX_FILE=$idx_file git -C "$wt" write-tree)

# Permission 3: an unchanged tree is not a snapshot.
saved=0
if [ "$tree" != "$(git -C "$wt" rev-parse 'HEAD^{tree}')" ]; then
  commit=$(printf 'lane-guard: wip snapshot of %s\n' "$lane" |
    git -C "$wt" \
      -c user.name='fm-lane-guard' \
      -c user.email='fm-lane-guard@localhost' \
      commit-tree "$tree" -p HEAD)
  git -C "$wt" update-ref "refs/wip/$lane" "$commit"
  # The one forced operation: this ref is a rolling snapshot, never a
  # fast-forwardable history, so a diverged remote copy is replaced by design.
  git -C "$wt" push -qf origin "refs/wip/$lane:refs/wip/$lane"
  saved=1
fi

# Permission 4: first sighting, then the zero-commit budget.
now=$(date -u +%s)
seen=$(git -C "$wt" config --get "lane.$lane.seen" 2>/dev/null || true)
case ${seen:-} in
  '' | *[!0-9]*)
    git -C "$wt" config "lane.$lane.seen" "$now"
    seen=$now
    ;;
esac

ahead=$(git -C "$wt" rev-list --count "$base_sha..HEAD")
elapsed=$((now - seen))
# A clock that moved backwards must not turn into a trip.
if [ "$elapsed" -lt 0 ]; then
  elapsed=0
fi

if [ "$ahead" -eq 0 ] && [ "$elapsed" -ge $((budget * 60)) ]; then
  if [ "$saved" -eq 1 ]; then
    where="work saved at refs/wip/$lane"
  else
    where="nothing to save, the worktree matches HEAD"
  fi
  printf 'TRIP %s: 0 commits in %sm; %s; kill and re-brief as one commit\n' \
    "$lane" "$((elapsed / 60))" "$where"
  exit 3
fi

# Permission 5: silence.
exit 0
