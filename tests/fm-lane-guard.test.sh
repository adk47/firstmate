#!/usr/bin/env bash
# tests/fm-lane-guard.test.sh - the lane guard (bin/fm-lane-guard.sh).
#
# Every case builds a real repo with a bare origin and a linked worktree, because
# the guard's whole job is what reaches a remote ref from a worktree the worker
# never commits in. Each case also asserts the worker's own branch, status, and
# HEAD are untouched: the snapshot must never look like the worker did anything.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-lane-guard)
GUARD=$ROOT/bin/fm-lane-guard.sh

# case_lane <name>: build $TMP_ROOT/<name> holding repo/ (with a bare origin at
# repo.origin.git) and a linked worktree named <name>, so the guard's <lane> is
# always the case name. Echoes nothing; sets LANE_ROOT, LANE_WT, LANE_REMOTE.
case_lane() {
  local name=$1
  LANE_ROOT=$TMP_ROOT/$name
  LANE_WT=$LANE_ROOT/$name
  LANE_REMOTE=$LANE_ROOT/repo.origin.git
  mkdir -p "$LANE_ROOT"
  fm_git_worktree "$LANE_ROOT/repo" "$LANE_WT" "fm/$name"
}

# guard <worktree> <base> <budget>: run the guard, printing "<rc>\n<stdout>".
guard() {
  local out rc
  out=$("$GUARD" "$1" "$2" "$3" 2>/dev/null)
  rc=$?
  printf '%s\n%s\n' "$rc" "$out"
}

rc_of() { printf '%s\n' "$1" | head -1; }
out_of() { printf '%s\n' "$1" | tail -n +2; }

# remote_file <ref> <path>: the bytes of <path> in <ref> as stored on the origin.
remote_file() {
  git -C "$LANE_REMOTE" show "$1:$2"
}

# assert_no_remote_ref <ref> <msg>: the origin must not carry <ref> at all, read
# through git rather than by looking for a loose ref file (refs may be packed).
assert_no_remote_ref() {
  ! git -C "$LANE_REMOTE" rev-parse --verify --quiet "$1" >/dev/null || fail "$2"
}

test_no_remote_refuses() {
  local r
  mkdir -p "$TMP_ROOT/no-remote"
  fm_git_init_commit "$TMP_ROOT/no-remote/wt"
  r=$(guard "$TMP_ROOT/no-remote/wt" HEAD 30)
  expect_code 2 "$(rc_of "$r")" "a lane with no origin remote must refuse"
  assert_contains "$(out_of "$r")" "REFUSE wt: no remote" \
    "the refusal did not name the lane and the missing remote"
  pass "a worktree with no origin remote refuses with exit 2"
}

test_clean_tree_is_silent() {
  local r
  case_lane clean
  r=$(guard "$LANE_WT" HEAD 30)
  expect_code 0 "$(rc_of "$r")" "a clean tree with budget left must be silent"
  [ -z "$(out_of "$r")" ] || fail "the healthy path printed: '$(out_of "$r")'"
  assert_no_remote_ref refs/wip/clean "a clean tree still published a wip ref"
  assert_no_remote_ref refs/heads/wip/clean "a clean tree published a wip branch"
  # Nothing was written against the lane either.
  ! git -C "$LANE_WT" rev-parse --verify --quiet refs/wip/clean >/dev/null ||
    fail "a clean tree still created a local wip ref"
  pass "a clean tree writes no snapshot and prints nothing"
}

test_untracked_file_reaches_the_remote() {
  local r head_before
  case_lane untracked
  head_before=$(git -C "$LANE_WT" rev-parse HEAD)
  printf 'the only copy of the work\n' > "$LANE_WT/only-copy.txt"

  r=$(guard "$LANE_WT" HEAD 30)
  expect_code 0 "$(rc_of "$r")" "an untracked-only lane inside its budget must be silent"
  [ -z "$(out_of "$r")" ] || fail "the healthy path printed: '$(out_of "$r")'"

  [ "$(remote_file refs/wip/untracked only-copy.txt)" = "the only copy of the work" ] ||
    fail "the untracked file did not reach refs/wip/untracked on the origin"
  [ "$(git -C "$LANE_REMOTE" rev-parse 'refs/wip/untracked^')" = "$head_before" ] ||
    fail "the wip snapshot is not parented on the lane's HEAD"

  # The worker's branch, index, and status are exactly as it left them.
  [ "$(git -C "$LANE_WT" rev-parse HEAD)" = "$head_before" ] ||
    fail "the guard moved the worker's HEAD"
  assert_absent "$LANE_WT/.git/index.lock" "the guard left an index lock behind"
  [ -z "$(git -C "$LANE_WT" diff --cached --name-only)" ] ||
    fail "the guard staged the worker's real index"
  assert_contains "$(git -C "$LANE_WT" status --porcelain)" "?? only-copy.txt" \
    "the untracked file is no longer untracked in the worker's worktree"
  pass "an untracked file reaches the remote wip ref without touching the worker"
}

test_zero_commit_budget_trips() {
  local r
  case_lane trip
  printf 'the only copy of the work\n' > "$LANE_WT/only-copy.txt"

  r=$(guard "$LANE_WT" HEAD 0)
  expect_code 3 "$(rc_of "$r")" "zero commits past a spent budget must trip"
  assert_contains "$(out_of "$r")" "TRIP trip: 0 commits in" \
    "the trip did not report the zero-commit lane"
  assert_contains "$(out_of "$r")" "work saved at refs/wip/trip" \
    "the trip did not report where the work was saved"
  assert_contains "$(out_of "$r")" "kill and re-brief as one commit" \
    "the trip did not carry the instruction"
  [ "$(remote_file refs/wip/trip only-copy.txt)" = "the only copy of the work" ] ||
    fail "the trip reported saved work that is not on the origin"
  pass "a zero-commit lane at its budget trips with exit 3 and real saved work"
}

test_budget_elapsed_trips_after_the_first_sighting() {
  local r
  case_lane elapsed
  printf 'still uncommitted\n' > "$LANE_WT/only-copy.txt"
  # First sighting is old: the lane has already read its budget without committing.
  git -C "$LANE_WT" config "lane.elapsed.seen" "$(($(date -u +%s) - 600))"

  r=$(guard "$LANE_WT" HEAD 5)
  expect_code 3 "$(rc_of "$r")" "a lane 10 minutes past a 5-minute budget must trip"
  assert_contains "$(out_of "$r")" "0 commits in 10m" \
    "the trip did not report the elapsed minutes since the first sighting"
  pass "the trip counts from the recorded first sighting, not from this run"
}

test_fresh_first_sighting_does_not_trip() {
  local r
  case_lane fresh
  printf 'just started\n' > "$LANE_WT/only-copy.txt"

  r=$(guard "$LANE_WT" HEAD 5)
  expect_code 0 "$(rc_of "$r")" "a freshly sighted lane must not trip"
  [ -z "$(out_of "$r")" ] || fail "the healthy path printed: '$(out_of "$r")'"
  local seen now
  seen=$(git -C "$LANE_WT" config --get lane.fresh.seen)
  now=$(date -u +%s)
  case $seen in
    '' | *[!0-9]*) fail "the first sighting was not recorded in git config (got '$seen')" ;;
  esac
  # The recorded sighting is this run's, not some stale value from elsewhere.
  [ "$seen" -ge $((now - 60)) ] && [ "$seen" -le "$now" ] ||
    fail "the first sighting '$seen' is not within this run (now $now)"
  [ "$(remote_file refs/wip/fresh only-copy.txt)" = "just started" ] ||
    fail "the fresh lane's work was not published"
  pass "a lane is measured from its recorded first sighting"
}

test_commits_ahead_never_trip() {
  local r base
  case_lane ahead
  base=$(git -C "$LANE_WT" rev-parse HEAD)
  printf 'committed work\n' > "$LANE_WT/committed.txt"
  git -C "$LANE_WT" add committed.txt
  git -C "$LANE_WT" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    commit -qm 'a commit'

  # A spent budget must not matter once the lane has committed past its base.
  git -C "$LANE_WT" config "lane.ahead.seen" "$(($(date -u +%s) - 600))"
  r=$(guard "$LANE_WT" "$base" 5)
  expect_code 0 "$(rc_of "$r")" "a lane with commits ahead of its base must not trip"
  [ -z "$(out_of "$r")" ] || fail "the healthy path printed: '$(out_of "$r")'"
  pass "a lane that committed past its base never trips"
}

test_no_remote_refuses
test_clean_tree_is_silent
test_untracked_file_reaches_the_remote
test_zero_commit_budget_trips
test_budget_elapsed_trips_after_the_first_sighting
test_fresh_first_sighting_does_not_trip
test_commits_ahead_never_trip

echo "all fm-lane-guard tests passed"
