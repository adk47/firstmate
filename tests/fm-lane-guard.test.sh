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

# guard <worktree> <base> <budget> [committer-date]: run the guard, printing
# "<rc>\n<stdout>". A committer-date forces a distinct snapshot commit when a
# case needs to distinguish a real repush from a second-identical one.
guard() {
  local out rc
  if [ "$#" -ge 4 ]; then
    out=$(GIT_COMMITTER_DATE=$4 "$GUARD" "$1" "$2" "$3" 2>&1)
  else
    out=$("$GUARD" "$1" "$2" "$3" 2>&1)
  fi
  rc=$?
  printf '%s\n%s\n' "$rc" "$out"
}

rc_of() { printf '%s\n' "$1" | head -1; }
out_of() { printf '%s\n' "$1" | tail -n +2; }

# remote_file <ref> <path>: the bytes of <path> in <ref> as stored on the origin.
remote_file() {
  git -C "$LANE_REMOTE" show "$1:$2"
}

# remote_has_path <ref> <path>: whether <ref> on the origin carries <path>.
remote_has_path() {
  git -C "$LANE_REMOTE" cat-file -e "$1:$2" >/dev/null 2>&1
}

# assert_no_remote_ref <ref> <msg>: the origin must not carry <ref> at all, read
# through git rather than by looking for a loose ref file (refs may be packed).
assert_no_remote_ref() {
  ! git -C "$LANE_REMOTE" rev-parse --verify --quiet "$1" >/dev/null || fail "$2"
}

test_leading_zero_budget_is_rejected() {
  local r
  case_lane octal
  printf 'still uncommitted\n' > "$LANE_WT/only-copy.txt"

  # 010 must not be read by the shell as octal 8; it is an invalid request.
  r=$(guard "$LANE_WT" HEAD 010)
  expect_code 2 "$(rc_of "$r")" "a budget with a leading zero must be rejected"
  assert_no_remote_ref refs/wip/octal "a rejected budget still published a wip ref"
  pass "a leading-zero budget is rejected instead of parsed as octal"
}

test_unchanged_dirty_tree_is_not_repushed() {
  local r pushes count
  case_lane idle
  pushes=$LANE_ROOT/pushes.log
  : > "$pushes"
  mkdir -p "$LANE_REMOTE/hooks"
  printf '#!/bin/sh\nprintf "push\\n" >> "%s"\ncat >/dev/null\n' "$pushes" \
    > "$LANE_REMOTE/hooks/pre-receive"
  chmod +x "$LANE_REMOTE/hooks/pre-receive"
  printf 'the only copy of the work\n' > "$LANE_WT/only-copy.txt"

  r=$(guard "$LANE_WT" HEAD 30 '2020-01-01T00:00:00Z')
  expect_code 0 "$(rc_of "$r")" "the first snapshot of a dirty tree must be silent"
  [ "$(remote_file refs/wip/idle only-copy.txt)" = "the only copy of the work" ] ||
    fail "the first snapshot did not reach the origin"

  # The worker wrote nothing new, so the already-published snapshot is still the
  # current one and the guard must not build and force-push it again. The
  # pre-receive hook counts pushes that actually reached the origin, and the
  # second committer date guarantees a repush would be a visible new commit
  # rather than a second-identical one git reports as up to date.
  r=$(guard "$LANE_WT" HEAD 30 '2020-01-02T00:00:00Z')
  expect_code 0 "$(rc_of "$r")" "a repeat run on an unchanged dirty tree must be silent"
  count=$(wc -l < "$pushes")
  count=$(printf '%s' "$count" | tr -d '[:space:]')
  [ "$count" = 1 ] || fail "the unchanged tree was pushed $count times, not once"
  [ "$(remote_file refs/wip/idle only-copy.txt)" = "the only copy of the work" ] ||
    fail "the unchanged snapshot no longer carries the work"
  pass "an unchanged dirty tree is not re-snapshotted or re-pushed"
}

test_credentials_are_never_published() {
  local r path
  case_lane creds
  printf 'deploy key\n' > "$LANE_WT/deploy.pem"
  printf 'private key\n' > "$LANE_WT/id_rsa"
  printf 'TOKEN=secret\n' > "$LANE_WT/.env"
  printf 'staged key\n' > "$LANE_WT/staged.pem"
  printf 'staged credential\n' > "$LANE_WT/Secrets.json"
  printf 'module.exports = 1\n' > "$LANE_WT/notes.js"

  r=$(guard "$LANE_WT" HEAD 30)
  expect_code 0 "$(rc_of "$r")" "a lane whose publishable work is ordinary source must be silent"
  [ "$(remote_file refs/wip/creds notes.js)" = "module.exports = 1" ] ||
    fail "the ordinary source file did not reach the pushed snapshot"
  for path in deploy.pem id_rsa .env staged.pem Secrets.json; do
    ! remote_has_path refs/wip/creds "$path" ||
      fail "credential-shaped $path was published to the origin"
  done
  pass "credential-shaped untracked files stay out of the pushed snapshot"
}

test_oversized_untracked_file_refuses() {
  local r
  case_lane huge
  dd if=/dev/zero bs=1024 count=1200 2>/dev/null | tr '\0' 'a' > "$LANE_WT/big.py"

  r=$(guard "$LANE_WT" HEAD 30)
  expect_code 2 "$(rc_of "$r")" "an oversized publishable file must refuse"
  assert_contains "$(out_of "$r")" "huge" "the refusal did not name the lane"
  assert_contains "$(out_of "$r")" "1 MiB publish cap" \
    "the refusal did not give the size-cap reason"
  assert_no_remote_ref refs/wip/huge "an oversized lane still published a remote wip ref"
  ! git -C "$LANE_WT" rev-parse --verify --quiet refs/wip/huge >/dev/null ||
    fail "an oversized lane still created a local wip ref"
  pass "an oversized publishable file refuses and publishes nothing"
}

test_oversized_trip_still_reports_without_claiming_saved() {
  local r
  case_lane hugetrip
  dd if=/dev/zero bs=1024 count=1200 2>/dev/null | tr '\0' 'a' > "$LANE_WT/big.py"
  git -C "$LANE_WT" config "lane.hugetrip.seen" "$(($(date -u +%s) - 600))"

  r=$(guard "$LANE_WT" HEAD 5)
  expect_code 3 "$(rc_of "$r")" "a refused snapshot with a spent budget must still trip"
  assert_contains "$(out_of "$r")" "TRIP hugetrip: 0 commits in" \
    "the refusal suppressed the zero-commit trip report"
  assert_contains "$(out_of "$r")" "work NOT saved" \
    "a refused snapshot claimed the work was saved"
  assert_not_contains "$(out_of "$r")" "work saved at" \
    "a refused snapshot still claimed work saved at the wip ref"
  assert_no_remote_ref refs/wip/hugetrip "a refused trip still published a wip ref"
  pass "a refused snapshot still trips and says the work was not saved"
}

test_only_credentials_publish_nothing() {
  local r
  case_lane secrets-only
  mkdir -p "$LANE_WT/secrets"
  printf 'TOKEN=secret\n' > "$LANE_WT/.env"
  printf 'private key\n' > "$LANE_WT/id_ed25519"
  printf 'db password\n' > "$LANE_WT/secrets/db.md"

  r=$(guard "$LANE_WT" HEAD 30)
  expect_code 0 "$(rc_of "$r")" "a lane with only credential-shaped files must be healthy"
  [ -z "$(out_of "$r")" ] || fail "the healthy path printed: '$(out_of "$r")'"
  assert_no_remote_ref refs/wip/secrets-only \
    "a lane with only credential-shaped files still published a wip ref"
  ! git -C "$LANE_WT" rev-parse --verify --quiet refs/wip/secrets-only >/dev/null ||
    fail "a lane with only credential-shaped files still created a local wip ref"
  pass "a lane with nothing publishable publishes nothing and is silent"
}

test_failed_push_still_reports_the_trip() {
  local r
  case_lane unpushable
  printf 'the only copy of the work\n' > "$LANE_WT/only-copy.txt"
  git -C "$LANE_WT" remote set-url origin "$LANE_ROOT/missing.git"

  r=$(guard "$LANE_WT" HEAD 0)
  expect_code 1 "$(rc_of "$r")" "a failed push must surface as its own nonzero status"
  assert_contains "$(out_of "$r")" "TRIP unpushable: 0 commits in" \
    "a failed push suppressed the zero-commit trip report"
  assert_contains "$(out_of "$r")" "work NOT saved" \
    "a failed push was reported as saved work"
  pass "a failed push still reports the trip and never claims the work is saved"
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

test_tracked_changes_and_deletions_are_saved() {
  local r expected
  case_lane tracked
  printf 'delete me\n' > "$LANE_WT/remove-me.txt"
  git -C "$LANE_WT" add remove-me.txt
  git -C "$LANE_WT" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    commit -qm 'a tracked file to delete'
  rm "$LANE_WT/remove-me.txt"
  printf '# tracked\n\nedited in the lane\n' > "$LANE_WT/README.md"
  expected=$(printf '# tracked\n\nedited in the lane')

  r=$(guard "$LANE_WT" HEAD 30)
  expect_code 0 "$(rc_of "$r")" "a lane changing tracked files must be silent"
  [ "$(remote_file refs/wip/tracked README.md)" = "$expected" ] ||
    fail "the tracked modification did not reach the pushed snapshot"
  ! remote_has_path refs/wip/tracked remove-me.txt ||
    fail "the tracked deletion still carries the deleted file"
  pass "tracked modifications and deletions reach the pushed snapshot"
}

test_staged_uncommitted_file_is_published() {
  local r
  case_lane staged
  printf 'staged work, never committed\n' > "$LANE_WT/staged.py"
  printf 'staged credential\n' > "$LANE_WT/staged.pem"
  git -C "$LANE_WT" add staged.py staged.pem

  r=$(guard "$LANE_WT" HEAD 0)
  expect_code 3 "$(rc_of "$r")" "a staged zero-commit lane at its budget must trip"
  assert_contains "$(out_of "$r")" "TRIP staged: 0 commits in" \
    "the staged-work lane did not trip"
  [ "$(remote_file refs/wip/staged staged.py)" = "staged work, never committed" ] ||
    fail "the staged-but-uncommitted file did not reach the pushed snapshot"
  ! remote_has_path refs/wip/staged staged.pem ||
    fail "the staged credential-shaped file was published"
  assert_contains "$(git -C "$LANE_WT" diff --cached --name-only)" "staged.py" \
    "the guard changed the worker's staged index"
  pass "a staged-but-uncommitted file is published, credentials excluded"
}

test_excluded_untracked_work_is_not_claimed_saved() {
  local r
  case_lane excluded
  printf 'FROM scratch\n' > "$LANE_WT/Dockerfile"
  git -C "$LANE_WT" config "lane.excluded.seen" "$(($(date -u +%s) - 600))"

  r=$(guard "$LANE_WT" HEAD 5)
  expect_code 3 "$(rc_of "$r")" "an excluded-work lane at its budget must trip"
  assert_contains "$(out_of "$r")" "TRIP excluded: 0 commits in" \
    "the excluded-work lane did not trip"
  assert_contains "$(out_of "$r")" "work NOT saved" \
    "the trip claimed excluded untracked work was saved"
  assert_not_contains "$(out_of "$r")" "matches HEAD" \
    "the trip claimed the worktree matches HEAD despite excluded work"
  assert_not_contains "$(out_of "$r")" "work saved at" \
    "the trip claimed a snapshot it never published"
  assert_no_remote_ref refs/wip/excluded "an excluded-work lane still published a wip ref"
  pass "excluded untracked work trips without claiming it was saved"
}

test_vanished_candidate_is_skipped() {
  local r real_git
  case_lane vanished
  real_git=$(command -v git)
  mkdir -p "$LANE_ROOT/bin"
  cat > "$LANE_ROOT/bin/git" <<EOF
#!/bin/sh
if [ "\$1" = "-C" ] && [ "\$3" = "add" ] && [ "\$4" = "--" ] && [ "\$5" = "first.py" ]; then
  rm -f "$LANE_WT/second.py"
fi
exec "$real_git" "\$@"
EOF
  chmod +x "$LANE_ROOT/bin/git"
  printf 'first file\n' > "$LANE_WT/first.py"
  printf 'second file\n' > "$LANE_WT/second.py"

  r=$(PATH="$LANE_ROOT/bin:$PATH" "$GUARD" "$LANE_WT" HEAD 30 2>&1)
  expect_code 0 "$?" "a candidate vanishing before staging must not abort the guard"
  [ "$(remote_file refs/wip/vanished first.py)" = "first file" ] ||
    fail "the surviving candidate did not reach the pushed snapshot"
  ! remote_has_path refs/wip/vanished second.py ||
    fail "the vanished candidate still reached the pushed snapshot"
  pass "a candidate that vanishes before staging is skipped"
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
  # Recoverable, not merely present: the snapshot hangs off the lane's HEAD, so a
  # re-brief can diff it, and the origin carries no branch of that name.
  [ "$(git -C "$LANE_REMOTE" rev-parse 'refs/wip/trip^')" = "$(git -C "$LANE_WT" rev-parse HEAD)" ] ||
    fail "the trip's wip snapshot is not parented on the lane's HEAD"
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
test_tracked_changes_and_deletions_are_saved
test_staged_uncommitted_file_is_published
test_excluded_untracked_work_is_not_claimed_saved
test_vanished_candidate_is_skipped
test_zero_commit_budget_trips
test_budget_elapsed_trips_after_the_first_sighting
test_fresh_first_sighting_does_not_trip
test_commits_ahead_never_trip
test_leading_zero_budget_is_rejected
test_unchanged_dirty_tree_is_not_repushed
test_credentials_are_never_published
test_oversized_untracked_file_refuses
test_oversized_trip_still_reports_without_claiming_saved
test_only_credentials_publish_nothing
test_failed_push_still_reports_the_trip

echo "all fm-lane-guard tests passed"
