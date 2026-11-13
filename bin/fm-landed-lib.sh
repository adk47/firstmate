#!/usr/bin/env bash
# fm-landed-lib.sh - the one owner of "has this work LANDED?".
#
# Shared by bin/fm-teardown.sh (which refuses destructive cleanup of unlanded
# work) and bin/fm-fleet-integrity-check.sh (which reports a terminal-claim lane
# whose worktree still holds work), so both apply the same rule.
#
# Work has landed when its commits are reachable from any remote-tracking
# branch (a fork counts as a remote, so upstream-contribution PRs pushed to a
# fork satisfy this), OR - when its commits are not so reachable - when its PR
# is merged and GitHub reports a PR head that contains the current local work,
# or its content is already present in the up-to-date default branch. That
# recognizes the common squash-merge-then-delete-branch flow, where the
# branch's own commits live nowhere on a remote yet the change is fully in
# main.
# The PR is resolved from a recorded pr= target when one is passed, or by
# looking up a merged PR whose head branch matches the worktree's branch,
# fetching its head via refs/pull/<n>/head when the branch itself was deleted,
# so a missing target never by itself reads as unlanded work.
# A gh lookup error falls back to the content check. Local-only projects (no
# remote) are covered by the content check against the local default branch.
# Uncommitted changes are never landed; callers own that check.
#
# Every function takes its repository/worktree as an explicit argument and none
# reads a caller's globals, so both callers can use it. Each returns non-zero
# when it cannot decide, and the callers treat "cannot prove" as "not a
# finding"/"refuse" rather than guessing.

# The default branch name of the repository at <repo-dir>. Accepts
# origin/HEAD, else main, else master; non-zero when none exists.
fm_landed_default_branch() {  # <repo-dir>
  local repo=$1 ref branch
  ref=$(git -C "$repo" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
  if [ -n "$ref" ]; then
    echo "${ref#origin/}"
    return 0
  fi
  for branch in main master; do
    if git -C "$repo" show-ref --verify --quiet "refs/heads/$branch"; then
      echo "$branch"
      return 0
    fi
  done
  return 1
}

# Resolve the PR number for a worktree branch via gh-axi. Echoes the number on a
# single match and returns 0; returns non-zero on no match or any lookup failure,
# so the caller treats it as "no PR found" (fail-safe).
fm_landed_pr_number_from_branch() {  # <worktree> <branch>
  local wt=$1 branch=$2 out n
  [ -n "$branch" ] && [ "$branch" != HEAD ] || return 1
  out=$( cd "$wt" && gh-axi pr list --state all --head "$branch" --limit 1 2>/dev/null ) || return 1
  n=$(printf '%s\n' "$out" | sed -n 's/^[[:space:]]*\([0-9][0-9]*\),.*/\1/p' | head -1)
  [ -n "$n" ] || return 1
  printf '%s' "$n"
}

fm_landed_pr_number_from_target() {  # <target>
  local target=$1 n
  case "$target" in
    '' ) return 1 ;;
    *"/pull/"*)
      n=${target##*/pull/}
      n=${n%%[!0-9]*}
      ;;
    [0-9]*)
      n=${target%%[!0-9]*}
      ;;
    *) return 1 ;;
  esac
  [ -n "$n" ] || return 1
  printf '%s' "$n"
}

fm_landed_ensure_commit_object() {  # <worktree> <target> <commit>
  local wt=$1 target=$2 commit=$3 n
  git -C "$wt" cat-file -e "$commit^{commit}" 2>/dev/null && return 0
  n=$(fm_landed_pr_number_from_target "$target") || return 1
  git -C "$wt" remote get-url origin >/dev/null 2>&1 || return 1
  git -C "$wt" fetch --quiet origin "refs/pull/$n/head" >/dev/null 2>&1 || return 1
  git -C "$wt" cat-file -e "$commit^{commit}" 2>/dev/null
}

fm_landed_patch_id_for_commit() {  # <worktree> <commit>
  local wt=$1 commit=$2
  git -C "$wt" show --pretty=medium --no-ext-diff "$commit" 2>/dev/null \
    | git patch-id --stable 2>/dev/null \
    | awk 'NR == 1 { print $1 }'
}

fm_landed_unpushed_patches_are_in_pr_head() {  # <worktree> <pr-head>
  local wt=$1 pr_head=$2 current base pr_patch_ids commit patch_id unpushed
  current=$(git -C "$wt" rev-parse --verify HEAD 2>/dev/null) || return 1
  base=$(git -C "$wt" merge-base "$current" "$pr_head" 2>/dev/null) || return 1
  pr_patch_ids=$(
    git -C "$wt" log --format=%H "$base..$pr_head" -- 2>/dev/null \
      | while IFS= read -r commit; do
          fm_landed_patch_id_for_commit "$wt" "$commit"
        done \
      | sed '/^$/d' \
      | sort -u
  ) || return 1
  [ -n "$pr_patch_ids" ] || return 1
  unpushed=$(git -C "$wt" log --format=%H HEAD --not --remotes -- 2>/dev/null) || return 1
  [ -n "$unpushed" ] || return 1
  while IFS= read -r commit; do
    [ -n "$commit" ] || continue
    patch_id=$(fm_landed_patch_id_for_commit "$wt" "$commit") || return 1
    [ -n "$patch_id" ] || return 1
    printf '%s\n' "$pr_patch_ids" | grep -qxF "$patch_id" || return 1
  done <<EOF
$unpushed
EOF
}

# Is the worktree's PR merged for local work contained in that PR? Resolves the
# PR from the recorded target first, then from the branch name, and asks GitHub
# for both the PR state and head. Echoes the resolved PR target on success.
# Returns non-zero when the PR is not merged, the current work is not contained
# in the PR head, no PR is found, or any gh error occurs - the caller then falls
# back to the content check.
fm_landed_pr_is_merged() {  # <worktree> <branch> [pr-target]
  local wt=$1 branch=$2 target=${3:-} view state remainder head resolved_url current landed=0
  if [ -z "$target" ]; then
    target=$(fm_landed_pr_number_from_branch "$wt" "$branch") || return 1
  fi
  [ -n "$target" ] || return 1
  view=$(cd "$wt" && gh pr view "$target" --json state,headRefOid,url -q '.state + "\t" + .headRefOid + "\t" + .url' 2>/dev/null) || return 1
  state=${view%%$'\t'*}
  remainder=${view#*$'\t'}
  [ "$state" != "$view" ] || return 1
  head=${remainder%%$'\t'*}
  resolved_url=${remainder#*$'\t'}
  [ "$head" != "$remainder" ] || return 1
  case "$state" in
    MERGED|merged) ;;
    *) return 1 ;;
  esac
  [ -n "$head" ] || return 1
  fm_landed_ensure_commit_object "$wt" "$target" "$head" || return 1
  current=$(git -C "$wt" rev-parse --verify HEAD 2>/dev/null) || return 1
  if git -C "$wt" merge-base --is-ancestor "$current" "$head" 2>/dev/null; then
    landed=1
  elif fm_landed_unpushed_patches_are_in_pr_head "$wt" "$head"; then
    landed=1
  fi
  [ "$landed" = 1 ] || return 1
  if [ -n "${3:-}" ]; then
    printf '%s' "$target"
  else
    [ -n "$resolved_url" ] || return 1
    printf '%s' "$resolved_url"
  fi
}

# Is the branch's content already present in the up-to-date default branch? Fetches
# first, then 3-way merges the default branch with HEAD: when HEAD introduces nothing
# the default branch does not already contain (e.g. its change landed via squash) the
# merged tree equals the default branch's tree. This isolates branch-only changes, so
# unrelated commits the default branch gained past the merge-base do not count as
# "added". Returns 0 when present, 1 when provably absent, and 2 when inconclusive
# (no default ref, an unreachable remote, or a merge conflict), so a caller that only
# reports on proof can stay silent.
fm_landed_content_in_default() {  # <worktree>
  local wt=$1 name ref default_tree merged_tree
  name=$(fm_landed_default_branch "$wt") || return 2
  if git -C "$wt" remote get-url origin >/dev/null 2>&1; then
    git -C "$wt" fetch --quiet origin "+refs/heads/$name:refs/remotes/origin/$name" >/dev/null 2>&1 || return 2
    ref="refs/remotes/origin/$name"
  elif git -C "$wt" rev-parse --quiet --verify "refs/heads/$name" >/dev/null 2>&1; then
    ref="refs/heads/$name"
  else
    return 2
  fi
  default_tree=$(git -C "$wt" rev-parse --quiet --verify "$ref^{tree}" 2>/dev/null) || return 2
  [ -n "$default_tree" ] || return 2
  merged_tree=$(git -C "$wt" merge-tree --write-tree "$ref" HEAD 2>/dev/null) || return 2
  merged_tree=$(printf '%s\n' "$merged_tree" | head -1)
  [ -n "$merged_tree" ] || return 2
  [ "$merged_tree" = "$default_tree" ] || return 1
}

# Has the worktree's committed work actually LANDED, though its commits are not
# reachable from any remote-tracking branch? True when a merged PR proves the
# current local work is contained in the PR head, OR the content is already in the
# default branch (fallback, which also covers the no-PR and gh-error paths).
# Returns 0 when landed, echoing the PR target it resolved when it resolved one;
# 1 only for work it can prove is unlanded; and 2 when it cannot prove either.
# Callers that must decide (teardown) refuse on any non-zero; callers that only
# report on proof stay silent on 2.
fm_landed_work_is_landed() {  # <worktree> <branch> [pr-target]
  local wt=$1 branch=$2 target=${3:-} pr
  if pr=$(fm_landed_pr_is_merged "$wt" "$branch" "$target"); then
    printf '%s' "$pr"
    return 0
  fi
  fm_landed_content_in_default "$wt"
}
