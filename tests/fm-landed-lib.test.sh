#!/usr/bin/env bash
# Behavior tests for bin/fm-landed-lib.sh - the ONE owner of "has this work
# LANDED?", shared by bin/fm-teardown.sh (which refuses to discard unlanded
# work) and bin/fm-fleet-integrity-check.sh (which reports a terminal-claim lane
# whose worktree still holds work).
#
# Both directions are pinned: work the squash/delete-branch and local-only flows
# landed is accepted, work that exists nowhere and is not in the default branch
# is refused, and a repo the check cannot read is undecidable rather than
# unlanded - so a caller that only acts on proof stays silent.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-landed-lib.sh
. "$ROOT/bin/fm-landed-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-landed-lib)

git_id() {  # <dir> <git args...>
  local dir=$1
  shift
  git -C "$dir" -c user.name=fm -c user.email=fm@example.invalid "$@"
}

# A repo with its default branch main holding one commit.
init_main_repo() {  # <dir>
  mkdir -p "$1" || return 1
  git -C "$1" init -q || return 1
  git -C "$1" symbolic-ref HEAD refs/heads/main || return 1
  git_id "$1" commit -q --allow-empty -m base || return 1
}

# A bare origin plus a seeded clone whose main is pushed, then a lane clone with
# a feature branch holding one commit that was never pushed.
make_lane_with_unsent_commit() {  # <case-dir>
  local d=$1
  mkdir -p "$d" || return 1
  git init -q --bare "$d/remote.git" || return 1
  init_main_repo "$d/seed" || return 1
  git -C "$d/seed" remote add origin "$d/remote.git" || return 1
  git -C "$d/seed" push -q -u origin main || return 1
  git -C "$d/remote.git" symbolic-ref HEAD refs/heads/main || return 1
  git clone -q "$d/remote.git" "$d/lane" || return 1
  git -C "$d/lane" checkout -q -b feat || return 1
  printf 'feature\n' >"$d/lane/feature.txt" || return 1
  git -C "$d/lane" add feature.txt || return 1
  git_id "$d/lane" commit -q -m "feature work" || return 1
}

# --- landed: squash-merged then head branch deleted -------------------------

test_squash_merged_and_deleted_is_landed() {
  local d rc
  d="$TMP_ROOT/squash"
  make_lane_with_unsent_commit "$d" || fail "could not build the squash fixture"
  # The same net change lands on origin/main as one squash commit, so the lane's
  # own commit exists nowhere on a remote.
  printf 'feature\n' >"$d/seed/feature.txt" || fail "could not write the squash content"
  git -C "$d/seed" add feature.txt || fail "could not stage the squash content"
  git_id "$d/seed" commit -q -m "squash feature" || fail "could not commit the squash"
  git -C "$d/seed" push -q origin main || fail "could not push the squash"
  rc=0
  fm_landed_content_in_default "$d/lane" || rc=$?
  [ "$rc" -eq 0 ] || fail "squash-merged-then-deleted work must read landed, got rc=$rc"
  pass "squash-merged work whose head branch is gone reads landed"
}

# --- landed: local-only project merged into its local default branch --------

test_local_only_merged_into_local_default_is_landed() {
  local d rc
  d="$TMP_ROOT/local-only"
  init_main_repo "$d" || fail "could not build the local-only fixture"
  git -C "$d" checkout -q -b feat || fail "could not create the local branch"
  printf 'feature\n' >"$d/feature.txt" || fail "could not write the local feature"
  git -C "$d" add feature.txt || fail "could not stage the local feature"
  git_id "$d" commit -q -m "feature work" || fail "could not commit the local feature"
  git -C "$d" checkout -q main || fail "could not return to main"
  git_id "$d" merge -q --no-ff -m "merge feature" feat || fail "could not merge the local feature"
  rc=0
  fm_landed_content_in_default "$d" || rc=$?
  [ "$rc" -eq 0 ] || fail "work merged into the local default branch must read landed, got rc=$rc"
  pass "local-only work merged into the local default branch reads landed"
}

# --- refused: commits exist nowhere and are not in the default branch ------

test_genuinely_unlanded_is_refused() {
  local d rc
  d="$TMP_ROOT/unlanded"
  init_main_repo "$d" || fail "could not build the unlanded fixture"
  git -C "$d" checkout -q -b feat || fail "could not create the unlanded branch"
  printf 'only here\n' >"$d/lost.txt" || fail "could not write the unlanded file"
  git -C "$d" add lost.txt || fail "could not stage the unlanded file"
  git_id "$d" commit -q -m "unlanded work" || fail "could not commit the unlanded work"
  rc=0
  fm_landed_content_in_default "$d" || rc=$?
  [ "$rc" -eq 1 ] || fail "work that exists nowhere and is not in the default branch must read unlanded, got rc=$rc"
  pass "genuinely unlanded work reads unlanded"
}

# --- undecidable: the repo's remote cannot be read -------------------------

test_unreadable_remote_is_undecidable() {
  local d rc
  d="$TMP_ROOT/unprovable"
  init_main_repo "$d" || fail "could not build the unprovable fixture"
  git -C "$d" checkout -q -b feat || fail "could not create the unprovable branch"
  git_id "$d" commit -q --allow-empty -m "work on an unreachable repo" || fail "could not commit the unprovable work"
  git -C "$d" remote add origin "$d/does-not-exist.git" || fail "could not add the dead remote"
  rc=0
  fm_landed_content_in_default "$d" || rc=$?
  [ "$rc" -eq 2 ] || fail "a repo whose remote cannot be read must read undecidable, got rc=$rc"
  pass "an unreadable remote reads undecidable, never unlanded"
}

# --- merged PR: the recorded target proves the work landed ----------------

test_merged_pr_containing_the_work_is_landed() {
  local d fakebin head rc out
  d="$TMP_ROOT/merged-pr"
  init_main_repo "$d" || fail "could not build the merged-PR fixture"
  git -C "$d" checkout -q -b feat || fail "could not create the merged-PR branch"
  git_id "$d" commit -q --allow-empty -m "feature work" || fail "could not commit the merged-PR work"
  head=$(git -C "$d" rev-parse HEAD) || fail "could not read the fixture head"
  fakebin="$d/fakebin"
  mkdir -p "$fakebin" || fail "could not create the fake bin"
  cat >"$fakebin/gh" <<SH
#!/usr/bin/env bash
printf 'MERGED\\t%s\\t%s\\n' "$head" "https://github.com/acme/widgets/pull/7"
SH
  chmod +x "$fakebin/gh" || fail "could not install the fake gh"
  rc=0
  out=$(PATH="$fakebin:$PATH" fm_landed_work_is_landed "$d" feat "https://github.com/acme/widgets/pull/7") || rc=$?
  [ "$rc" -eq 0 ] || fail "a merged PR whose head contains the work must read landed, got rc=$rc"
  [ "$out" = "https://github.com/acme/widgets/pull/7" ] || fail "the landed verdict must echo the resolved PR target, got '$out'"
  pass "a merged PR whose head contains the work reads landed"
}

test_squash_merged_and_deleted_is_landed
test_local_only_merged_into_local_default_is_landed
test_genuinely_unlanded_is_refused
test_unreadable_remote_is_undecidable
test_merged_pr_containing_the_work_is_landed

echo "all fm-landed-lib tests passed"
