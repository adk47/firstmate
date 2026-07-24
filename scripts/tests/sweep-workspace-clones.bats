#!/usr/bin/env bats
# Tests for scripts/sweep-workspace-clones.sh — the weekly sweeper for stale
# agent git clones under workspaces/repos/ (TTL 14d) and workspaces/*/tmp/
# (TTL 7d). Deletion requires clean + fully-pushed + past-TTL + not on the
# keep-list; everything else lands in a fail-closed held lane.
#
# Hermetic: every root is a mktemp sandbox; muso/ssh are PATH-shadowed so a
# real Slack send fails loudly; git fixtures are local bare "origins" so no
# network is touched.
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
SWEEP="$HYDRA_REPO/scripts/sweep-workspace-clones.sh"

setup() {
  # pwd -P: canonicalize so the sweeper's realpath root-guard holds on macOS,
  # where mktemp lives under the /var -> /private/var symlink.
  TEST_TMPDIR="$(cd "$(mktemp -d)" && pwd -P)"
  export TEST_TMPDIR
  mkdir -p "$TEST_TMPDIR/bin" "$TEST_TMPDIR/repos" "$TEST_TMPDIR/ws/cto/tmp" \
    "$TEST_TMPDIR/origins"

  unset MUSO_SLACK_BOT_TOKEN_DEVOPS
  export MUSO_SLACK_ENV_FILE="$TEST_TMPDIR/muso-slack.env"  # absent → no token → no send
  export STUB_CALLS="$TEST_TMPDIR/muso-calls"
  : > "$STUB_CALLS"
  cat > "$TEST_TMPDIR/bin/ssh" <<'STUB'
#!/bin/bash
echo "test stub: ssh refused ($*)" >&2; exit 99
STUB
  cat > "$TEST_TMPDIR/bin/muso" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_CALLS"
echo '{"channel":"C0TEST","ts":"1717171717.000100"}'
STUB
  cat > "$TEST_TMPDIR/bin/flock" <<'STUB'
#!/bin/bash
[ -x /usr/bin/flock ] && exec /usr/bin/flock "$@"
exit 0
STUB
  chmod +x "$TEST_TMPDIR/bin/ssh" "$TEST_TMPDIR/bin/muso" "$TEST_TMPDIR/bin/flock"
  PATH="$TEST_TMPDIR/bin:$PATH"; export PATH

  export SWEEP_REPOS_ROOT="$TEST_TMPDIR/repos"
  export SWEEP_WS_ROOT="$TEST_TMPDIR/ws"
  export SWEEP_REPOS_TTL_DAYS=14
  export SWEEP_TMP_TTL_DAYS=7
  export SWEEP_KEEP_LIST="core-backend hydra"
  export SWEEP_LOCKFILE="$TEST_TMPDIR/sweep.lock"
  export SWEEP_SKIP_HOST_GUARD=1
  # An unreadable mount table is fail-closed (holds everything), and macOS
  # has no /proc/self/mounts — pin an empty table for determinism.
  : > "$TEST_TMPDIR/mounts-empty"
  export SWEEP_MOUNTS_FILE="$TEST_TMPDIR/mounts-empty"

  export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t \
    GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
}

teardown() { /bin/rm -rf "$TEST_TMPDIR"; hash -r; }

# N days ago as a touch -t stamp (GNU date, falling back to BSD for local runs).
past_stamp() {
  date -d "$1 days ago" +%Y%m%d%H%M 2>/dev/null || date -v -"$1"d +%Y%m%d%H%M
}

# retro-age a single path without following symlinks.
age_path() { touch -h -t "$(past_stamp "$1")" -- "$2"; }

# retro-age every file in a tree EXCEPT .git internals, plus the dir itself.
age_tree() {
  local days="$1" d="$2" stamp
  stamp="$(past_stamp "$days")"
  find "$d" -path "$d/.git" -prune -o -print0 2>/dev/null \
    | xargs -0 touch -h -t "$stamp" --
  touch -h -t "$stamp" -- "$d"
}

# mkclone <path> : clean clone of a fresh bare origin, one pushed commit.
# Origin name derives from the FULL path: two same-basename clones (test 16)
# must not share an origin, or the second push only succeeds when both commits
# land in the same second (identical SHA) — a timing flake otherwise.
mkclone() {
  local d="$1" name origin
  name="${d//\//_}"
  origin="$TEST_TMPDIR/origins/$name.git"
  git init -q --bare "$origin"
  # Pin the bare HEAD: the system default branch name varies (main vs
  # master), and a clone of an origin whose HEAD dangles checks out nothing.
  git -C "$origin" symbolic-ref HEAD refs/heads/main
  git init -q -b main "$d"
  ( cd "$d" && echo hello > f.txt && git add f.txt && git commit -qm init \
      && git remote add origin "$origin" && git push -q -u origin main )
}

@test "clean pushed clone past TTL is deleted on --apply" {
  mkclone "$TEST_TMPDIR/repos/one-off-20260601"
  age_tree 20 "$TEST_TMPDIR/repos/one-off-20260601"
  run "$SWEEP" --apply
  [ "$status" -eq 0 ]
  [ ! -d "$TEST_TMPDIR/repos/one-off-20260601" ]
  [[ "$output" == *"deleted"* ]]
}

@test "dry-run (default) reports the candidate but deletes nothing and posts no Slack" {
  mkclone "$TEST_TMPDIR/repos/one-off-20260601"
  age_tree 20 "$TEST_TMPDIR/repos/one-off-20260601"
  run "$SWEEP"
  [ "$status" -eq 0 ]
  [ -d "$TEST_TMPDIR/repos/one-off-20260601" ]
  [[ "$output" == *"DRY-RUN"* ]]
  [ ! -s "$STUB_CALLS" ]
}

@test "fresh worktree file inside an old clone keeps it (active rail)" {
  mkclone "$TEST_TMPDIR/repos/busy"
  age_tree 20 "$TEST_TMPDIR/repos/busy"
  touch "$TEST_TMPDIR/repos/busy/f.txt"
  run "$SWEEP" --apply
  [ "$status" -eq 0 ]
  [ -d "$TEST_TMPDIR/repos/busy" ]
}

@test "fresh .git-internal mtime alone does NOT keep an otherwise old clone" {
  mkclone "$TEST_TMPDIR/repos/fetched-not-used"
  age_tree 20 "$TEST_TMPDIR/repos/fetched-not-used"
  touch "$TEST_TMPDIR/repos/fetched-not-used/.git/FETCH_HEAD"
  run "$SWEEP" --apply
  [ "$status" -eq 0 ]
  [ ! -d "$TEST_TMPDIR/repos/fetched-not-used" ]
}

@test "dirty clone past TTL is held, never deleted" {
  mkclone "$TEST_TMPDIR/repos/dirty"
  echo change >> "$TEST_TMPDIR/repos/dirty/f.txt"
  age_tree 20 "$TEST_TMPDIR/repos/dirty"
  run "$SWEEP" --apply
  [ "$status" -eq 0 ]
  [ -d "$TEST_TMPDIR/repos/dirty" ]
  [[ "$output" == *"held"* ]]
}

@test "unpushed commit on a detached HEAD is held" {
  mkclone "$TEST_TMPDIR/repos/detached"
  ( cd "$TEST_TMPDIR/repos/detached" && git checkout -q --detach \
      && echo x > d.txt && git add d.txt && git commit -qm detached-work )
  age_tree 20 "$TEST_TMPDIR/repos/detached"
  run "$SWEEP" --apply
  [ "$status" -eq 0 ]
  [ -d "$TEST_TMPDIR/repos/detached" ]
}

@test "stash-only work is held" {
  mkclone "$TEST_TMPDIR/repos/stashed"
  ( cd "$TEST_TMPDIR/repos/stashed" && echo x >> f.txt && git stash -q )
  age_tree 20 "$TEST_TMPDIR/repos/stashed"
  run "$SWEEP" --apply
  [ "$status" -eq 0 ]
  [ -d "$TEST_TMPDIR/repos/stashed" ]
}

@test "commit reachable only from a tag is held" {
  mkclone "$TEST_TMPDIR/repos/tagged"
  ( cd "$TEST_TMPDIR/repos/tagged" && echo x > t.txt && git add t.txt \
      && git commit -qm tag-work && git tag keepme \
      && git reset -q --hard HEAD~1 )
  age_tree 20 "$TEST_TMPDIR/repos/tagged"
  run "$SWEEP" --apply
  [ "$status" -eq 0 ]
  [ -d "$TEST_TMPDIR/repos/tagged" ]
}

@test "repo with no remotes is held" {
  git init -q -b main "$TEST_TMPDIR/repos/scratch"
  ( cd "$TEST_TMPDIR/repos/scratch" && echo x > f && git add f && git commit -qm x )
  age_tree 20 "$TEST_TMPDIR/repos/scratch"
  run "$SWEEP" --apply
  [ "$status" -eq 0 ]
  [ -d "$TEST_TMPDIR/repos/scratch" ]
  [[ "$output" == *"no-remote"* ]]
}

@test ".git-file (linked worktree) candidate is held" {
  mkdir -p "$TEST_TMPDIR/repos/wt"
  echo "gitdir: /somewhere/else" > "$TEST_TMPDIR/repos/wt/.git"
  age_tree 20 "$TEST_TMPDIR/repos/wt"
  run "$SWEEP" --apply
  [ "$status" -eq 0 ]
  [ -d "$TEST_TMPDIR/repos/wt" ]
}

@test "nested inner repo holds the outer candidate" {
  mkclone "$TEST_TMPDIR/repos/outer"
  mkclone "$TEST_TMPDIR/repos/outer/vendor-inner"
  age_tree 20 "$TEST_TMPDIR/repos/outer"
  run "$SWEEP" --apply
  [ "$status" -eq 0 ]
  [ -d "$TEST_TMPDIR/repos/outer" ]
}

@test "broken repo (git probe fails) is held" {
  mkclone "$TEST_TMPDIR/repos/broken"
  rm -f "$TEST_TMPDIR/repos/broken/.git/HEAD"
  age_tree 20 "$TEST_TMPDIR/repos/broken"
  run "$SWEEP" --apply
  [ "$status" -eq 0 ]
  [ -d "$TEST_TMPDIR/repos/broken" ]
}

@test "keep-list match is exact: core-backend kept, core-backend-scratch swept" {
  mkclone "$TEST_TMPDIR/repos/core-backend"
  mkclone "$TEST_TMPDIR/repos/core-backend-scratch"
  age_tree 20 "$TEST_TMPDIR/repos/core-backend"
  age_tree 20 "$TEST_TMPDIR/repos/core-backend-scratch"
  run "$SWEEP" --apply
  [ "$status" -eq 0 ]
  [ -d "$TEST_TMPDIR/repos/core-backend" ]
  [ ! -d "$TEST_TMPDIR/repos/core-backend-scratch" ]
}

@test "symlinked candidate is never followed or deleted through" {
  mkdir -p "$TEST_TMPDIR/real-target"
  echo data > "$TEST_TMPDIR/real-target/precious"
  ln -s "$TEST_TMPDIR/real-target" "$TEST_TMPDIR/repos/linky"
  age_path 20 "$TEST_TMPDIR/repos/linky"
  run "$SWEEP" --apply
  [ "$status" -eq 0 ]
  [ -f "$TEST_TMPDIR/real-target/precious" ]
}

@test "old non-git junk dir is deleted, fresh one kept" {
  mkdir -p "$TEST_TMPDIR/ws/cto/tmp/old-junk" "$TEST_TMPDIR/ws/cto/tmp/new-junk"
  echo x > "$TEST_TMPDIR/ws/cto/tmp/old-junk/f"
  echo x > "$TEST_TMPDIR/ws/cto/tmp/new-junk/f"
  age_tree 10 "$TEST_TMPDIR/ws/cto/tmp/old-junk"
  run "$SWEEP" --apply
  [ "$status" -eq 0 ]
  [ ! -d "$TEST_TMPDIR/ws/cto/tmp/old-junk" ]
  [ -d "$TEST_TMPDIR/ws/cto/tmp/new-junk" ]
}

@test "tmp lane uses the shorter TTL: 8d clone swept from tmp, kept in repos" {
  mkclone "$TEST_TMPDIR/ws/cto/tmp/eight-days"
  mkclone "$TEST_TMPDIR/repos/eight-days"
  age_tree 8 "$TEST_TMPDIR/ws/cto/tmp/eight-days"
  age_tree 8 "$TEST_TMPDIR/repos/eight-days"
  run "$SWEEP" --apply
  [ "$status" -eq 0 ]
  [ ! -d "$TEST_TMPDIR/ws/cto/tmp/eight-days" ]
  [ -d "$TEST_TMPDIR/repos/eight-days" ]
}

@test "dotted .tmp workspace dirs are swept too" {
  mkdir -p "$TEST_TMPDIR/ws/coordinator/.tmp"
  mkclone "$TEST_TMPDIR/ws/coordinator/.tmp/pr-scratch"
  age_tree 10 "$TEST_TMPDIR/ws/coordinator/.tmp/pr-scratch"
  run "$SWEEP" --apply
  [ "$status" -eq 0 ]
  [ ! -d "$TEST_TMPDIR/ws/coordinator/.tmp/pr-scratch" ]
}

@test "in-progress git operation (index.lock) holds the clone at pre-rm recheck" {
  mkclone "$TEST_TMPDIR/repos/mid-op"
  age_tree 20 "$TEST_TMPDIR/repos/mid-op"
  touch "$TEST_TMPDIR/repos/mid-op/.git/index.lock"
  age_path 20 "$TEST_TMPDIR/repos/mid-op/.git/index.lock"
  run "$SWEEP" --apply
  [ "$status" -eq 0 ]
  [ -d "$TEST_TMPDIR/repos/mid-op" ]
}

@test "a local branch name with no remote counterpart is held (even at a pushed tip)" {
  mkclone "$TEST_TMPDIR/repos/named-branch"
  ( cd "$TEST_TMPDIR/repos/named-branch" && git branch release-candidate )
  age_tree 20 "$TEST_TMPDIR/repos/named-branch"
  run "$SWEEP" --apply
  [ "$status" -eq 0 ]
  [ -d "$TEST_TMPDIR/repos/named-branch" ]
  [[ "$output" == *"local-branch"* ]]
}

@test "a local-only tag on a pushed commit is held" {
  mkclone "$TEST_TMPDIR/repos/local-tag"
  ( cd "$TEST_TMPDIR/repos/local-tag" && git tag -a keepsake -m "annotated, never pushed" )
  age_tree 20 "$TEST_TMPDIR/repos/local-tag"
  run "$SWEEP" --apply
  [ "$status" -eq 0 ]
  [ -d "$TEST_TMPDIR/repos/local-tag" ]
  [[ "$output" == *"local-tag"* ]]
}

@test "same-name branch at a different sha than the remote ref is held" {
  mkclone "$TEST_TMPDIR/repos/moved-branch"
  ( cd "$TEST_TMPDIR/repos/moved-branch" \
      && git branch release \
      && echo more > g.txt && git add g.txt && git commit -qm second \
      && git push -q origin main && git push -q origin main:release )
  # local release stays at the first commit (reachable via origin/main),
  # while origin/release now points at the second — pointer would be lost.
  age_tree 20 "$TEST_TMPDIR/repos/moved-branch"
  run "$SWEEP" --apply
  [ "$status" -eq 0 ]
  [ -d "$TEST_TMPDIR/repos/moved-branch" ]
  [[ "$output" == *"local-branch"* ]]
}

@test "a branch deleted server-side after the last fetch is held (stale tracking ref is not proof)" {
  mkclone "$TEST_TMPDIR/repos/gone-upstream"
  ( cd "$TEST_TMPDIR/repos/gone-upstream" && git branch release && git push -q origin release )
  git -C "$(ls -d "$TEST_TMPDIR"/origins/*gone-upstream.git)" update-ref -d refs/heads/release
  age_tree 20 "$TEST_TMPDIR/repos/gone-upstream"
  run "$SWEEP" --apply
  [ "$status" -eq 0 ]
  [ -d "$TEST_TMPDIR/repos/gone-upstream" ]
  [[ "$output" == *"local-branch"* ]]
}

@test "an unreachable remote holds the clone (live check fails closed)" {
  mkclone "$TEST_TMPDIR/repos/offline"
  ( cd "$TEST_TMPDIR/repos/offline" && git remote set-url origin "$TEST_TMPDIR/nonexistent-origin.git" )
  age_tree 20 "$TEST_TMPDIR/repos/offline"
  run "$SWEEP" --apply
  [ "$status" -eq 0 ]
  [ -d "$TEST_TMPDIR/repos/offline" ]
  [[ "$output" == *"probe-fail"* ]]
}

@test "a force-pushed-away branch is held even when cached refs vouch for the tip" {
  mkclone "$TEST_TMPDIR/repos/forced"
  # Rewrite origin/main to an unrelated history from a helper clone: the
  # candidate's cached origin/main still equals its local tip, but the live
  # server no longer contains that commit.
  git clone -q -b main "$(ls -d "$TEST_TMPDIR"/origins/*forced.git)" "$TEST_TMPDIR/aux-forced"
  ( cd "$TEST_TMPDIR/aux-forced" && git checkout -q --orphan rewrite \
      && git rm -qrf . && echo other > o.txt && git add o.txt \
      && git commit -qm unrelated && git push -qf origin rewrite:main )
  age_tree 20 "$TEST_TMPDIR/repos/forced"
  run "$SWEEP" --apply
  [ "$status" -eq 0 ]
  [ -d "$TEST_TMPDIR/repos/forced" ]
  [[ "$output" == *"local-branch"* ]]
}

@test "a fast-forwarded live branch does not hold a stale clone (coverage preserved)" {
  mkclone "$TEST_TMPDIR/repos/behind"
  git clone -q -b main "$(ls -d "$TEST_TMPDIR"/origins/*behind.git)" "$TEST_TMPDIR/aux-behind"
  ( cd "$TEST_TMPDIR/aux-behind" && echo more > m.txt && git add m.txt \
      && git commit -qm advance && git push -q origin main )
  age_tree 20 "$TEST_TMPDIR/repos/behind"
  run "$SWEEP" --apply
  [ "$status" -eq 0 ]
  [ ! -d "$TEST_TMPDIR/repos/behind" ]
}

@test "a candidate that IS a mountpoint is held (exact mount match)" {
  mkdir -p "$TEST_TMPDIR/ws/cto/tmp/mounted"
  echo x > "$TEST_TMPDIR/ws/cto/tmp/mounted/f"
  age_tree 10 "$TEST_TMPDIR/ws/cto/tmp/mounted"
  printf 'dev %s ext4 rw 0 0\n' "$TEST_TMPDIR/ws/cto/tmp/mounted" > "$TEST_TMPDIR/mounts"
  SWEEP_MOUNTS_FILE="$TEST_TMPDIR/mounts" run "$SWEEP" --apply
  [ "$status" -eq 0 ]
  [ -d "$TEST_TMPDIR/ws/cto/tmp/mounted" ]
  [[ "$output" == *"mount"* ]]
}

@test "an octal-escaped mount path (spaces) still registers as a hazard" {
  mkdir -p "$TEST_TMPDIR/ws/cto/tmp/old clone"
  echo x > "$TEST_TMPDIR/ws/cto/tmp/old clone/f"
  age_tree 10 "$TEST_TMPDIR/ws/cto/tmp/old clone"
  p="$TEST_TMPDIR/ws/cto/tmp/old clone"
  printf 'dev %s ext4 rw 0 0\n' "${p// /\\040}" > "$TEST_TMPDIR/mounts-escaped"
  SWEEP_MOUNTS_FILE="$TEST_TMPDIR/mounts-escaped" run "$SWEEP" --apply
  [ "$status" -eq 0 ]
  [ -d "$TEST_TMPDIR/ws/cto/tmp/old clone" ]
  [[ "$output" == *"mount"* ]]
}

@test "an unreadable mount table holds candidates (never assumes no-hazard)" {
  mkdir -p "$TEST_TMPDIR/ws/cto/tmp/junky"
  echo x > "$TEST_TMPDIR/ws/cto/tmp/junky/f"
  age_tree 10 "$TEST_TMPDIR/ws/cto/tmp/junky"
  SWEEP_MOUNTS_FILE="$TEST_TMPDIR/does-not-exist" run "$SWEEP" --apply
  [ "$status" -eq 0 ]
  [ -d "$TEST_TMPDIR/ws/cto/tmp/junky" ]
  [[ "$output" == *"mount"* ]]
}

@test "a detached-HEAD commit created mid-sweep holds the clone at the removal gate" {
  mkclone "$TEST_TMPDIR/repos/raced-detached"
  age_tree 20 "$TEST_TMPDIR/repos/raced-detached"
  REAL_GIT="$(command -v git)"
  export REAL_GIT INJECT_TARGET="$TEST_TMPDIR/repos/raced-detached" INJECT_COUNT="$TEST_TMPDIR/inject-count-d"
  cat > "$TEST_TMPDIR/bin/git" <<'STUB'
#!/usr/bin/env bash
if [[ "$*" == *"status --porcelain"* && "$*" == *"$INJECT_TARGET"* ]]; then
  n=$(cat "$INJECT_COUNT" 2>/dev/null || echo 0); n=$((n+1)); echo "$n" > "$INJECT_COUNT"
  if [ "$n" -eq 2 ]; then
    "$REAL_GIT" -C "$INJECT_TARGET" checkout -q --detach
    "$REAL_GIT" -C "$INJECT_TARGET" commit -q --allow-empty -m raced-detached-work
  fi
fi
exec "$REAL_GIT" "$@"
STUB
  chmod +x "$TEST_TMPDIR/bin/git"
  run "$SWEEP" --apply
  rm -f "$TEST_TMPDIR/bin/git"; hash -r
  [ "$status" -eq 0 ]
  [ -d "$TEST_TMPDIR/repos/raced-detached" ]
  [[ "$output" == *"between audit and removal"* ]]
}

@test "tag name matching is exact: local v1 is not satisfied by remote v10" {
  mkclone "$TEST_TMPDIR/repos/tagname"
  ( cd "$TEST_TMPDIR/repos/tagname" && git tag v10 && git push -q origin v10 && git tag v1 )
  age_tree 20 "$TEST_TMPDIR/repos/tagname"
  run "$SWEEP" --apply
  [ "$status" -eq 0 ]
  [ -d "$TEST_TMPDIR/repos/tagname" ]
  [[ "$output" == *"local-tag"* ]]
  [[ "$output" == *"'v1'"* ]]
}

@test "same-name tag at a different object on origin is held" {
  mkclone "$TEST_TMPDIR/repos/tagobj"
  ( cd "$TEST_TMPDIR/repos/tagobj" && git tag -a v1 -m "local annotated" )
  # origin gets a LIGHTWEIGHT v1 at the same commit: same name, different object.
  git -C "$(ls -d "$TEST_TMPDIR"/origins/*tagobj.git)" tag v1 main
  age_tree 20 "$TEST_TMPDIR/repos/tagobj"
  run "$SWEEP" --apply
  [ "$status" -eq 0 ]
  [ -d "$TEST_TMPDIR/repos/tagobj" ]
  [[ "$output" == *"local-tag"* ]]
}

@test "tags that exist on origin do not hold the clone" {
  mkclone "$TEST_TMPDIR/repos/pushed-tag"
  ( cd "$TEST_TMPDIR/repos/pushed-tag" && git tag v1 && git push -q origin v1 )
  age_tree 20 "$TEST_TMPDIR/repos/pushed-tag"
  run "$SWEEP" --apply
  [ "$status" -eq 0 ]
  [ ! -d "$TEST_TMPDIR/repos/pushed-tag" ]
}

@test "a tmp root that is itself a clone is skipped whole (worktree files survive)" {
  mkdir -p "$TEST_TMPDIR/ws/rogue"
  mkclone "$TEST_TMPDIR/ws/rogue/tmp"
  age_tree 30 "$TEST_TMPDIR/ws/rogue/tmp"
  run "$SWEEP" --apply
  [ "$status" -eq 0 ]
  [ -d "$TEST_TMPDIR/ws/rogue/tmp/.git" ]
  [ -f "$TEST_TMPDIR/ws/rogue/tmp/f.txt" ]
  [[ "$output" == *"clone-root"* ]]
}

@test "a symlinked workspace dir cannot pull an external tree into the sweep" {
  mkdir -p "$TEST_TMPDIR/external/tmp"
  mkclone "$TEST_TMPDIR/external/tmp/victim"
  age_tree 30 "$TEST_TMPDIR/external/tmp/victim"
  ln -s "$TEST_TMPDIR/external" "$TEST_TMPDIR/ws/evil"
  run "$SWEEP" --apply
  [ "$status" -eq 0 ]
  [ -d "$TEST_TMPDIR/external/tmp/victim" ]
}

@test "non-numeric TTL env fails loud with exit 2" {
  SWEEP_REPOS_TTL_DAYS="14d" run "$SWEEP" --apply
  [ "$status" -eq 2 ]
  [[ "$output" == *"REPOS_TTL_DAYS"* ]]
}

@test "a ref created mid-sweep (after the first audit) holds the clone at the removal gate" {
  mkclone "$TEST_TMPDIR/repos/raced"
  age_tree 20 "$TEST_TMPDIR/repos/raced"
  # git wrapper seam: on the SECOND `status --porcelain` for this clone (the
  # TOCTOU re-audit), first create a tag — simulating a concurrent writer
  # landing git-only state between the first audit and the removal gate.
  REAL_GIT="$(command -v git)"
  export REAL_GIT INJECT_TARGET="$TEST_TMPDIR/repos/raced" INJECT_COUNT="$TEST_TMPDIR/inject-count"
  cat > "$TEST_TMPDIR/bin/git" <<'STUB'
#!/usr/bin/env bash
if [[ "$*" == *"status --porcelain"* && "$*" == *"$INJECT_TARGET"* ]]; then
  n=$(cat "$INJECT_COUNT" 2>/dev/null || echo 0); n=$((n+1)); echo "$n" > "$INJECT_COUNT"
  if [ "$n" -eq 2 ]; then
    "$REAL_GIT" -C "$INJECT_TARGET" tag injected-mid-sweep
  fi
fi
exec "$REAL_GIT" "$@"
STUB
  chmod +x "$TEST_TMPDIR/bin/git"
  run "$SWEEP" --apply
  rm -f "$TEST_TMPDIR/bin/git"; hash -r
  [ "$status" -eq 0 ]
  [ -d "$TEST_TMPDIR/repos/raced" ]
  [[ "$output" == *"between audit and removal"* ]]
}

@test "structural refusal: SWEEP_REPOS_ROOT=// exits 1 (no slash-form bypass)" {
  SWEEP_REPOS_ROOT="//" run "$SWEEP" --apply
  [ "$status" -eq 1 ]
  [[ "$output" == *"FATAL"* ]]
}

@test "a nested clone inside a non-git junk dir is held, not junk-deleted" {
  mkdir -p "$TEST_TMPDIR/ws/cto/tmp/build"
  mkclone "$TEST_TMPDIR/ws/cto/tmp/build/checkout"
  echo unique-dirty-work >> "$TEST_TMPDIR/ws/cto/tmp/build/checkout/f.txt"
  age_tree 10 "$TEST_TMPDIR/ws/cto/tmp/build"
  run "$SWEEP" --apply
  [ "$status" -eq 0 ]
  [ -f "$TEST_TMPDIR/ws/cto/tmp/build/checkout/f.txt" ]
  [[ "$output" == *"nested"* ]]
}

@test "git-only state created during the size scan holds the clone (du before final audit)" {
  mkclone "$TEST_TMPDIR/repos/raced-du"
  age_tree 20 "$TEST_TMPDIR/repos/raced-du"
  REAL_DU="$(command -v du)"
  REAL_GIT="$(command -v git)"
  export REAL_DU REAL_GIT INJECT_TARGET="$TEST_TMPDIR/repos/raced-du"
  cat > "$TEST_TMPDIR/bin/du" <<'STUB'
#!/usr/bin/env bash
if [[ "$*" == *"$INJECT_TARGET"* && ! -e "$INJECT_TARGET/.git/refs/tags/du-race" ]]; then
  "$REAL_GIT" -C "$INJECT_TARGET" tag du-race
fi
exec "$REAL_DU" "$@"
STUB
  chmod +x "$TEST_TMPDIR/bin/du"
  run "$SWEEP" --apply
  rm -f "$TEST_TMPDIR/bin/du"; hash -r
  [ "$status" -eq 0 ]
  [ -d "$TEST_TMPDIR/repos/raced-du" ]
  [[ "$output" == *"between audit and removal"* ]]
}

@test "structural refusal: symlinked repos root exits 1" {
  rmdir "$TEST_TMPDIR/repos" 2>/dev/null || /bin/rm -rf "$TEST_TMPDIR/repos"
  mkdir -p "$TEST_TMPDIR/elsewhere"
  ln -s "$TEST_TMPDIR/elsewhere" "$TEST_TMPDIR/repos"
  run "$SWEEP" --apply
  [ "$status" -eq 1 ]
}

@test "apply run with a Slack token posts exactly one summary" {
  echo 'MUSO_SLACK_BOT_TOKEN_DEVOPS=xoxb-test' > "$MUSO_SLACK_ENV_FILE"
  mkclone "$TEST_TMPDIR/repos/gone-20260601"
  age_tree 20 "$TEST_TMPDIR/repos/gone-20260601"
  run "$SWEEP" --apply
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$STUB_CALLS" | tr -d ' ')" -eq 1 ]
}

@test "unknown flag exits 2" {
  run "$SWEEP" --frobnicate
  [ "$status" -eq 2 ]
}
