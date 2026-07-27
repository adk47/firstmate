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
  # Same dependency-injection role for the live-handle scan: an empty proc
  # tree means "no process holds anything open". Pointing at the REAL /proc
  # would make every test depend on whatever else is running on the box.
  mkdir -p "$TEST_TMPDIR/proc-empty"
  export SWEEP_PROC_DIR="$TEST_TMPDIR/proc-empty"

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

@test "a detached HEAD whose backing branch was deleted server-side is held" {
  mkclone "$TEST_TMPDIR/repos/detached-orphan"
  ( cd "$TEST_TMPDIR/repos/detached-orphan" \
      && git checkout -q -b feature && echo work > w.txt && git add w.txt \
      && git commit -qm feature-work && git push -q -u origin feature \
      && git checkout -q --detach feature && git branch -q -D feature )
  # Server deletes the branch: only the detached HEAD and a stale cached
  # origin/feature still know commit A.
  git -C "$(ls -d "$TEST_TMPDIR"/origins/*detached-orphan.git)" update-ref -d refs/heads/feature
  age_tree 20 "$TEST_TMPDIR/repos/detached-orphan"
  run "$SWEEP" --apply
  [ "$status" -eq 0 ]
  [ -d "$TEST_TMPDIR/repos/detached-orphan" ]
  [[ "$output" == *"not reachable from live origin"* ]]
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
  [[ "$output" == *"not reachable from live origin"* ]]
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
  # A concurrent writer lands an unpushed detached commit while the audit is
  # running; later checks in that same audit must still catch it.
  mkclone "$TEST_TMPDIR/repos/raced-detached"
  age_tree 20 "$TEST_TMPDIR/repos/raced-detached"
  REAL_GIT="$(command -v git)"
  export REAL_GIT INJECT_BASE="raced-detached" INJECT_MARK="$TEST_TMPDIR/mark-detached"
cat > "$TEST_TMPDIR/bin/git" <<'STUB'
#!/usr/bin/env bash
# The candidate is quarantined BEFORE the audit now, so `-C` points at the
# private name. Match the BASENAME (which survives the rename) and act on the
# path git was actually handed.
if [[ "$*" == *"status --porcelain"* ]]; then
  t=""; prev=""
  for a in "$@"; do [ "$prev" = "-C" ] && t="$a"; prev="$a"; done
  if [ -n "$t" ] && [ "$(basename "$t")" = "$INJECT_BASE" ] && [ ! -e "$INJECT_MARK" ]; then
    : > "$INJECT_MARK"
    "$REAL_GIT" -C "$t" checkout -q --detach
    "$REAL_GIT" -C "$t" commit -q --allow-empty -m raced-detached-work
  fi
fi
exec "$REAL_GIT" "$@"
STUB
  chmod +x "$TEST_TMPDIR/bin/git"
  run "$SWEEP" --apply
  rm -f "$TEST_TMPDIR/bin/git"; hash -r
  [ "$status" -eq 0 ]
  [ -e "$TEST_TMPDIR/mark-detached" ]          # the injection actually fired
  [ -d "$TEST_TMPDIR/repos/raced-detached" ]
  [[ "$output" == *"commits not on any remote"* ]]
  [[ "$output" == *"restored from quarantine"* ]]
}

@test "a mount path with a literal backslash still registers (no awk -v mangling)" {
  mkdir -p "$TEST_TMPDIR/ws/cto/tmp/"'old\040clone'
  echo x > "$TEST_TMPDIR/ws/cto/tmp/"'old\040clone/f'
  age_tree 10 "$TEST_TMPDIR/ws/cto/tmp/"'old\040clone'
  # Kernel encoding: the literal backslash becomes \134 in the mounts table.
  printf 'dev %s/ws/cto/tmp/old\\134040clone ext4 rw 0 0\n' "$TEST_TMPDIR" \
    > "$TEST_TMPDIR/mounts-backslash"
  SWEEP_MOUNTS_FILE="$TEST_TMPDIR/mounts-backslash" run "$SWEEP" --apply
  [ "$status" -eq 0 ]
  [ -d "$TEST_TMPDIR/ws/cto/tmp/"'old\040clone' ]
  [[ "$output" == *"mount"* ]]
}

@test "a nested repo appearing during the junk-lane size scan holds the dir" {
  mkdir -p "$TEST_TMPDIR/ws/cto/tmp/big-junk"
  echo x > "$TEST_TMPDIR/ws/cto/tmp/big-junk/f"
  age_tree 10 "$TEST_TMPDIR/ws/cto/tmp/big-junk"
  REAL_DU="$(command -v du)"
  export REAL_DU INJECT_JUNK="$TEST_TMPDIR/ws/cto/tmp/big-junk"
  cat > "$TEST_TMPDIR/bin/du" <<'STUB'
#!/usr/bin/env bash
if [[ "$*" == *"$INJECT_JUNK"* && ! -d "$INJECT_JUNK/late/.git" ]]; then
  mkdir -p "$INJECT_JUNK/late/.git"
fi
exec "$REAL_DU" "$@"
STUB
  chmod +x "$TEST_TMPDIR/bin/du"
  run "$SWEEP" --apply
  rm -f "$TEST_TMPDIR/bin/du"; hash -r
  [ "$status" -eq 0 ]
  [ -d "$TEST_TMPDIR/ws/cto/tmp/big-junk" ]
  [[ "$output" == *"during size scan"* ]]
}

@test "a stale sweep-live ref from a killed prior run is not trusted as live proof" {
  mkclone "$TEST_TMPDIR/repos/stale-ns"
  ( cd "$TEST_TMPDIR/repos/stale-ns" \
      && git checkout -q -b feature && echo work > w.txt && git add w.txt \
      && git commit -qm feature-work && git push -q -u origin feature \
      && git checkout -q --detach feature && git branch -q -D feature \
      && git update-ref refs/sweep-live/heads/ghost HEAD )
  git -C "$(ls -d "$TEST_TMPDIR"/origins/*stale-ns.git)" update-ref -d refs/heads/feature
  age_tree 20 "$TEST_TMPDIR/repos/stale-ns"
  run "$SWEEP" --apply
  [ "$status" -eq 0 ]
  [ -d "$TEST_TMPDIR/repos/stale-ns" ]
  [[ "$output" == *"not reachable from live origin"* ]]
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
  # git-only state (a local tag) landed by a concurrent writer during the
  # audit: clean status, no worktree write, so only the ref-parity check sees it.
  mkclone "$TEST_TMPDIR/repos/raced"
  age_tree 20 "$TEST_TMPDIR/repos/raced"
  REAL_GIT="$(command -v git)"
  export REAL_GIT INJECT_BASE="raced" INJECT_MARK="$TEST_TMPDIR/mark-raced"
cat > "$TEST_TMPDIR/bin/git" <<'STUB'
#!/usr/bin/env bash
# The candidate is quarantined BEFORE the audit now, so `-C` points at the
# private name. Match the BASENAME (which survives the rename) and act on the
# path git was actually handed.
if [[ "$*" == *"status --porcelain"* ]]; then
  t=""; prev=""
  for a in "$@"; do [ "$prev" = "-C" ] && t="$a"; prev="$a"; done
  if [ -n "$t" ] && [ "$(basename "$t")" = "$INJECT_BASE" ] && [ ! -e "$INJECT_MARK" ]; then
    : > "$INJECT_MARK"
    "$REAL_GIT" -C "$t" tag injected-mid-sweep
  fi
fi
exec "$REAL_GIT" "$@"
STUB
  chmod +x "$TEST_TMPDIR/bin/git"
  run "$SWEEP" --apply
  rm -f "$TEST_TMPDIR/bin/git"; hash -r
  [ "$status" -eq 0 ]
  [ -e "$TEST_TMPDIR/mark-raced" ]
  [ -d "$TEST_TMPDIR/repos/raced" ]
  [[ "$output" == *"local-tag"* ]]
  [[ "$output" == *"restored from quarantine"* ]]
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

@test "a clean detached checkout during the size scan holds the clone" {
  # du now runs on the QUARANTINED path and BEFORE the audit, so a checkout
  # landing during it must be caught by the audit that follows.
  mkclone "$TEST_TMPDIR/repos/raced-checkout"
  ( cd "$TEST_TMPDIR/repos/raced-checkout" && echo two > f2.txt && git add f2.txt \
      && git commit -qm second && git push -q origin main )
  age_tree 20 "$TEST_TMPDIR/repos/raced-checkout"
  REAL_DU="$(command -v du)"
  REAL_GIT="$(command -v git)"
  export REAL_DU REAL_GIT INJECT_BASE="raced-checkout" INJECT_MARK="$TEST_TMPDIR/mark-co"
  cat > "$TEST_TMPDIR/bin/du" <<'STUB'
#!/usr/bin/env bash
t="${@: -1}"
if [ -d "$t" ] && [ "$(basename "$t")" = "$INJECT_BASE" ] && [ ! -e "$INJECT_MARK" ]; then
  : > "$INJECT_MARK"
  "$REAL_GIT" -C "$t" checkout -q --detach HEAD~1
fi
exec "$REAL_DU" "$@"
STUB
  chmod +x "$TEST_TMPDIR/bin/du"
  run "$SWEEP" --apply
  rm -f "$TEST_TMPDIR/bin/du"; hash -r
  [ "$status" -eq 0 ]
  [ -e "$TEST_TMPDIR/mark-co" ]                 # the injection actually fired
  [ -d "$TEST_TMPDIR/repos/raced-checkout" ]
  [[ "$output" == *"restored from quarantine"* ]]
}

@test "git-only state created during the size scan holds the clone (du before final audit)" {
  # A tag created while du runs: clean status, no worktree write. Only the
  # ref-parity check in the following audit can see it.
  mkclone "$TEST_TMPDIR/repos/raced-du"
  age_tree 20 "$TEST_TMPDIR/repos/raced-du"
  REAL_DU="$(command -v du)"
  REAL_GIT="$(command -v git)"
  export REAL_DU REAL_GIT INJECT_BASE="raced-du" INJECT_MARK="$TEST_TMPDIR/mark-du"
  cat > "$TEST_TMPDIR/bin/du" <<'STUB'
#!/usr/bin/env bash
t="${@: -1}"
if [ -d "$t" ] && [ "$(basename "$t")" = "$INJECT_BASE" ] && [ ! -e "$INJECT_MARK" ]; then
  : > "$INJECT_MARK"
  "$REAL_GIT" -C "$t" tag du-race
fi
exec "$REAL_DU" "$@"
STUB
  chmod +x "$TEST_TMPDIR/bin/du"
  run "$SWEEP" --apply
  rm -f "$TEST_TMPDIR/bin/du"; hash -r
  [ "$status" -eq 0 ]
  [ -e "$TEST_TMPDIR/mark-du" ]
  [ -d "$TEST_TMPDIR/repos/raced-du" ]
  [[ "$output" == *"local-tag"* ]]
  [[ "$output" == *"restored from quarantine"* ]]
}

@test "a stale symlink swapped for a directory during the du seam is never rm -rf'd" {
  # Classified on the symlink lane (unlink-only, no freshness/nested/mount
  # guards), then swapped for a directory while `du` runs: the removal must
  # refuse the type transition rather than recurse into the new tree.
  ln -s "$TEST_TMPDIR/origins" "$TEST_TMPDIR/ws/cto/tmp/stale-link"
  age_path 10 "$TEST_TMPDIR/ws/cto/tmp/stale-link"
  REAL_DU="$(command -v du)"
  export REAL_DU INJECT_LINK="$TEST_TMPDIR/ws/cto/tmp/stale-link"
  cat > "$TEST_TMPDIR/bin/du" <<'STUB'
#!/usr/bin/env bash
if [[ "$*" == *"$INJECT_LINK"* && -L "$INJECT_LINK" ]]; then
  /bin/rm -f "$INJECT_LINK"
  mkdir -p "$INJECT_LINK/fresh-work"
  echo unique > "$INJECT_LINK/fresh-work/data.txt"
fi
exec "$REAL_DU" "$@"
STUB
  chmod +x "$TEST_TMPDIR/bin/du"
  run "$SWEEP" --apply
  rm -f "$TEST_TMPDIR/bin/du"; hash -r
  [ "$status" -eq 0 ]
  [ -f "$TEST_TMPDIR/ws/cto/tmp/stale-link/fresh-work/data.txt" ]
  [[ "$output" == *"became a directory between classification and removal"* ]]
}

@test "a stale file replaced by a FRESH file during the du seam is not deleted (same type, new inode)" {
  # Type parity is not identity: the entry lane must refuse a same-type
  # replacement, not just a symlink→directory transition. This case is
  # sharpest on the Linux CI runner, where ext4 hands the replacement the
  # just-freed inode number — device:inode alone compares EQUAL there, and
  # only the ctime in the identity snapshot catches it.
  echo stale > "$TEST_TMPDIR/ws/cto/tmp/scratch.log"
  age_path 10 "$TEST_TMPDIR/ws/cto/tmp/scratch.log"
  REAL_DU="$(command -v du)"
  export REAL_DU INJECT_FILE="$TEST_TMPDIR/ws/cto/tmp/scratch.log"
  cat > "$TEST_TMPDIR/bin/du" <<'STUB'
#!/usr/bin/env bash
if [[ "$*" == *"$INJECT_FILE"* ]] && ! grep -q brand-new "$INJECT_FILE" 2>/dev/null; then
  /bin/rm -f "$INJECT_FILE"
  echo brand-new > "$INJECT_FILE"
fi
exec "$REAL_DU" "$@"
STUB
  chmod +x "$TEST_TMPDIR/bin/du"
  run "$SWEEP" --apply
  rm -f "$TEST_TMPDIR/bin/du"; hash -r
  [ "$status" -eq 0 ]
  [ -f "$TEST_TMPDIR/ws/cto/tmp/scratch.log" ]
  grep -q brand-new "$TEST_TMPDIR/ws/cto/tmp/scratch.log"
  [[ "$output" == *"identity changed between classification and removal"* ]]
}

@test "a junk dir replaced by a DIFFERENT directory during the du seam is not rm -rf'd" {
  # Directory→directory swap: same type, and the replacement is retro-aged so
  # the post-du freshness rail cannot be what saves it — only the identity
  # snapshot can.
  mkdir -p "$TEST_TMPDIR/ws/cto/tmp/big-junk"
  echo x > "$TEST_TMPDIR/ws/cto/tmp/big-junk/f"
  age_tree 10 "$TEST_TMPDIR/ws/cto/tmp/big-junk"
  REAL_DU="$(command -v du)"
  export REAL_DU INJECT_DIR="$TEST_TMPDIR/ws/cto/tmp/big-junk" \
    OLD_STAMP="$(past_stamp 10)" SWAP_AWAY="$TEST_TMPDIR/swapped-away"
  cat > "$TEST_TMPDIR/bin/du" <<'STUB'
#!/usr/bin/env bash
if [[ "$*" == *"$INJECT_DIR"* && ! -e "$INJECT_DIR/replacement.txt" ]]; then
  mv "$INJECT_DIR" "$SWAP_AWAY"
  mkdir -p "$INJECT_DIR"
  echo unique-work > "$INJECT_DIR/replacement.txt"
  touch -h -t "$OLD_STAMP" -- "$INJECT_DIR/replacement.txt" "$INJECT_DIR"
fi
exec "$REAL_DU" "$@"
STUB
  chmod +x "$TEST_TMPDIR/bin/du"
  run "$SWEEP" --apply
  rm -f "$TEST_TMPDIR/bin/du"; hash -r
  [ "$status" -eq 0 ]
  [ -f "$TEST_TMPDIR/ws/cto/tmp/big-junk/replacement.txt" ]
  [[ "$output" == *"identity changed between classification and removal"* ]]
}

@test "a replacement preserving size AND mtime across the seam is still refused (ctime)" {
  # The hardest same-type replacement: identical size, identical mtime, and on
  # ext4 quite possibly the recycled inode. Only ctime — which no userspace
  # API can set — separates the objects.
  printf 'stale\n' > "$TEST_TMPDIR/ws/cto/tmp/keepme.log"
  age_path 10 "$TEST_TMPDIR/ws/cto/tmp/keepme.log"
  REAL_DU="$(command -v du)"
  export REAL_DU INJECT_FILE="$TEST_TMPDIR/ws/cto/tmp/keepme.log" \
    OLD_STAMP="$(past_stamp 10)" MARKER="$TEST_TMPDIR/swapped"
  cat > "$TEST_TMPDIR/bin/du" <<'STUB'
#!/usr/bin/env bash
if [[ "$*" == *"$INJECT_FILE"* && ! -e "$MARKER" ]]; then
  : > "$MARKER"
  /bin/rm -f "$INJECT_FILE"
  printf 'fresh\n' > "$INJECT_FILE"          # same 6 bytes as 'stale\n'
  touch -h -t "$OLD_STAMP" -- "$INJECT_FILE" # same mtime
fi
exec "$REAL_DU" "$@"
STUB
  chmod +x "$TEST_TMPDIR/bin/du"
  run "$SWEEP" --apply
  rm -f "$TEST_TMPDIR/bin/du"; hash -r
  [ "$status" -eq 0 ]
  [ -f "$TEST_TMPDIR/ws/cto/tmp/keepme.log" ]
  grep -q fresh "$TEST_TMPDIR/ws/cto/tmp/keepme.log"
  [[ "$output" == *"identity changed between classification and removal"* ]]
}

@test "a swap that lands after the final stat is caught post-quarantine and restored" {
  # Injects the replacement into the rename seam itself — the window no
  # amount of stat'ing can close. The quarantined object must fail the
  # re-audit and be restored to its original name, untouched.
  mkdir -p "$TEST_TMPDIR/ws/cto/tmp/racy-junk"
  echo original > "$TEST_TMPDIR/ws/cto/tmp/racy-junk/f"
  age_tree 10 "$TEST_TMPDIR/ws/cto/tmp/racy-junk"
  REAL_MV="$(command -v mv)"
  export REAL_MV INJECT_DIR="$TEST_TMPDIR/ws/cto/tmp/racy-junk" \
    MV_MARKER="$TEST_TMPDIR/mv-swapped"
  cat > "$TEST_TMPDIR/bin/mv" <<'STUB'
#!/usr/bin/env bash
# Quarantine move for the target: do the real rename, then substitute a
# DIFFERENT object under the quarantine name — simulating a writer that won
# the race between the final stat and the rename.
if [[ "$*" == *"$INJECT_DIR"* && "$*" == *".sweep-quarantine."* && ! -e "$MV_MARKER" ]]; then
  : > "$MV_MARKER"
  "$REAL_MV" "$@"
  q="${@: -1}"
  "$REAL_MV" "$q" "$q.displaced"
  mkdir -p "$q"
  echo impostor > "$q/f"
  exit 0
fi
exec "$REAL_MV" "$@"
STUB
  chmod +x "$TEST_TMPDIR/bin/mv"
  run "$SWEEP" --apply
  rm -f "$TEST_TMPDIR/bin/mv"; hash -r
  [ "$status" -eq 0 ]
  # Restored to the original name, and the impostor was never rm -rf'd.
  [ -d "$TEST_TMPDIR/ws/cto/tmp/racy-junk" ]
  grep -q impostor "$TEST_TMPDIR/ws/cto/tmp/racy-junk/f"
  [[ "$output" == *"restored from quarantine"* ]]
}

@test "a write through a surviving handle after quarantine holds the clone (root entry unchanged)" {
  # rename(2) does not disturb an open fd or a process cwd'd inside the tree.
  # Overwriting an ALREADY-TRACKED file changes that file, never the root
  # directory entry — so the root's device/inode/mtime/size still matches and
  # only the full policy re-audit can catch it.
  mkclone "$TEST_TMPDIR/repos/handle-race"
  age_tree 20 "$TEST_TMPDIR/repos/handle-race"
  REAL_MV="$(command -v mv)"
  export REAL_MV INJECT_TARGET="$TEST_TMPDIR/repos/handle-race" \
    ROOT_ID_FILE="$TEST_TMPDIR/root-id" MV_MARKER="$TEST_TMPDIR/handle-marker"
  cat > "$TEST_TMPDIR/bin/mv" <<'STUB'
#!/usr/bin/env bash
if [[ "$*" == *"$INJECT_TARGET"* && "$*" == *".sweep-quarantine."* && ! -e "$MV_MARKER" ]]; then
  : > "$MV_MARKER"
  "$REAL_MV" "$@"
  q="${@: -1}"
  before="$(stat -f '%d|%i|%Fm|%z' -- "$q" 2>/dev/null || stat -c '%d|%i|%y|%s' -- "$q")"
  printf 'unique work from a surviving handle\n' > "$q/f.txt"   # EXISTING tracked file
  after="$(stat -f '%d|%i|%Fm|%z' -- "$q" 2>/dev/null || stat -c '%d|%i|%y|%s' -- "$q")"
  # Prove the premise: the root entry is byte-identical across the write.
  [ "$before" = "$after" ] && echo "ROOT_ENTRY_UNCHANGED" > "$ROOT_ID_FILE"
  exit 0
fi
exec "$REAL_MV" "$@"
STUB
  chmod +x "$TEST_TMPDIR/bin/mv"
  run "$SWEEP" --apply
  rm -f "$TEST_TMPDIR/bin/mv"; hash -r
  [ "$status" -eq 0 ]
  # The premise must actually have held, or the test proves nothing.
  grep -q ROOT_ENTRY_UNCHANGED "$TEST_TMPDIR/root-id"
  # Restored, and the unique work survived.
  [ -d "$TEST_TMPDIR/repos/handle-race" ]
  grep -q "unique work from a surviving handle" "$TEST_TMPDIR/repos/handle-race/f.txt"
  [[ "$output" == *"restored from quarantine"* ]]
  # Caught by the single policy audit running on the quarantined object —
  # the write made the worktree dirty, which the root-entry check cannot see.
  [[ "$output" == *"dirty path(s)"* ]]
}

@test "a FILE occupying the quarantine namespace is never clobbered by a live quarantine" {
  # Under a recurring (PID-derived) quarantine name this file could be the
  # rename destination and be silently overwritten. The target is now a
  # mktemp -d sibling, so held debris cannot be a destination.
  printf 'irreplaceable\n' > "$TEST_TMPDIR/ws/cto/tmp/.sweep-quarantine.4242.victim"
  age_path 30 "$TEST_TMPDIR/ws/cto/tmp/.sweep-quarantine.4242.victim"
  mkdir -p "$TEST_TMPDIR/ws/cto/tmp/victim"
  echo junk > "$TEST_TMPDIR/ws/cto/tmp/victim/f"
  age_tree 10 "$TEST_TMPDIR/ws/cto/tmp/victim"
  run "$SWEEP" --apply
  [ "$status" -eq 0 ]
  # Debris untouched, byte for byte.
  grep -qx irreplaceable "$TEST_TMPDIR/ws/cto/tmp/.sweep-quarantine.4242.victim"
  # ...and the real candidate still swept normally.
  [ ! -d "$TEST_TMPDIR/ws/cto/tmp/victim" ]
  [[ "$output" == *"quarantine leftover from an interrupted run"* ]]
}

@test "a DIRECTORY occupying the quarantine namespace is never nested into" {
  # The directory case is the nastier half: `mv src existing_dir/` moves src
  # INSIDE it rather than failing, which would strand the candidate and break
  # restore. Assert the debris keeps exactly its original single entry.
  mkdir -p "$TEST_TMPDIR/ws/cto/tmp/.sweep-quarantine.4242.held/inner"
  echo precious > "$TEST_TMPDIR/ws/cto/tmp/.sweep-quarantine.4242.held/inner/data"
  age_tree 30 "$TEST_TMPDIR/ws/cto/tmp/.sweep-quarantine.4242.held"
  mkdir -p "$TEST_TMPDIR/ws/cto/tmp/held"
  echo junk > "$TEST_TMPDIR/ws/cto/tmp/held/f"
  age_tree 10 "$TEST_TMPDIR/ws/cto/tmp/held"
  run "$SWEEP" --apply
  [ "$status" -eq 0 ]
  grep -qx precious "$TEST_TMPDIR/ws/cto/tmp/.sweep-quarantine.4242.held/inner/data"
  # Nothing was nested inside the debris directory.
  [ "$(ls -A "$TEST_TMPDIR/ws/cto/tmp/.sweep-quarantine.4242.held" | wc -l | tr -d ' ')" = "1" ]
  [ ! -d "$TEST_TMPDIR/ws/cto/tmp/held" ]
  [[ "$output" == *"quarantine leftover from an interrupted run"* ]]
}

@test "quarantine leaves no directory behind on a successful sweep" {
  mkclone "$TEST_TMPDIR/repos/tidy"
  age_tree 20 "$TEST_TMPDIR/repos/tidy"
  run "$SWEEP" --apply
  [ "$status" -eq 0 ]
  [ ! -d "$TEST_TMPDIR/repos/tidy" ]
  [ -z "$(find "$TEST_TMPDIR/repos" -maxdepth 1 -name '.sweep-quarantine.*' -print -quit)" ]
}

@test "a repos root that IS a mountpoint is refused before enumeration" {
  # The per-candidate guard only sees mounts at or under a CHILD, and
  # --one-file-system cannot help when every child is already inside the
  # root's own filesystem.
  mkclone "$TEST_TMPDIR/repos/inside-a-mount"
  age_tree 20 "$TEST_TMPDIR/repos/inside-a-mount"
  printf 'tmpfs %s tmpfs rw 0 0\n' "$TEST_TMPDIR/repos" > "$TEST_TMPDIR/mounts-root"
  SWEEP_MOUNTS_FILE="$TEST_TMPDIR/mounts-root" run "$SWEEP" --apply
  [ "$status" -eq 1 ]
  [ -d "$TEST_TMPDIR/repos/inside-a-mount" ]
  [[ "$output" == *"is itself a mountpoint"* ]]
}

@test "a tmp root that IS a mountpoint is held whole, other lanes still sweep" {
  mkdir -p "$TEST_TMPDIR/ws/cto/tmp/old-junk"
  echo x > "$TEST_TMPDIR/ws/cto/tmp/old-junk/f"
  age_tree 10 "$TEST_TMPDIR/ws/cto/tmp/old-junk"
  mkclone "$TEST_TMPDIR/repos/sweepable"
  age_tree 20 "$TEST_TMPDIR/repos/sweepable"
  printf 'tmpfs %s tmpfs rw 0 0\n' "$TEST_TMPDIR/ws/cto/tmp" > "$TEST_TMPDIR/mounts-tmproot"
  SWEEP_MOUNTS_FILE="$TEST_TMPDIR/mounts-tmproot" run "$SWEEP" --apply
  [ "$status" -eq 0 ]
  # The mounted tmp root is untouched...
  [ -d "$TEST_TMPDIR/ws/cto/tmp/old-junk" ]
  [[ "$output" == *"tmp root is itself a mountpoint"* ]]
  # ...while the unmounted repos lane still swept normally.
  [ ! -d "$TEST_TMPDIR/repos/sweepable" ]
}

@test "a failing depth-1 root enumeration is a structural failure, not a clean sweep" {
  # find in a process substitution discards its status; a partial scan must
  # never be reported as a completed sweep.
  mkclone "$TEST_TMPDIR/repos/unscanned"
  age_tree 20 "$TEST_TMPDIR/repos/unscanned"
  REAL_FIND="$(command -v find)"
  export REAL_FIND INJECT_ROOT="$TEST_TMPDIR/repos"
  cat > "$TEST_TMPDIR/bin/find" <<'STUB'
#!/usr/bin/env bash
if [[ "$*" == *"-mindepth 1"* && "$*" == *"-maxdepth 1"* && "$*" == *"$INJECT_ROOT"* ]]; then
  echo "find: $INJECT_ROOT: Input/output error" >&2; exit 1
fi
exec "$REAL_FIND" "$@"
STUB
  chmod +x "$TEST_TMPDIR/bin/find"
  run "$SWEEP" --apply
  rm -f "$TEST_TMPDIR/bin/find"; hash -r
  [ "$status" -eq 1 ]
  [ -d "$TEST_TMPDIR/repos/unscanned" ]
  [[ "$output" == *"could not enumerate"* ]]
  # The summary still had to be emitted before the failure surfaced.
  [[ "$output" == *"swept_clones="* ]]
}

@test "a live process holding the clone open blocks deletion (real /proc, real handle)" {
  # The window the quarantine alone cannot close: a process that already had a
  # descriptor or cwd inside keeps writing through it. Uses the REAL /proc and
  # a REAL background process — the whole point is that the handle survives the
  # rename, which a static fixture cannot express.
  [ -d /proc ] || skip "requires /proc (Linux); production and CI are node-8"
  unset SWEEP_PROC_DIR
  mkclone "$TEST_TMPDIR/repos/held-open"
  age_tree 20 "$TEST_TMPDIR/repos/held-open"
  # cwd inside the clone; /proc/<pid>/cwd follows the quarantine rename.
  ( cd "$TEST_TMPDIR/repos/held-open" && exec sleep 60 ) &
  local holder=$!
  # Wait for the kernel to publish the cwd before sweeping.
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    [ "$(readlink "/proc/$holder/cwd" 2>/dev/null)" = "$TEST_TMPDIR/repos/held-open" ] && break
    sleep 0.2
  done
  [ "$(readlink "/proc/$holder/cwd" 2>/dev/null)" = "$TEST_TMPDIR/repos/held-open" ]
  run "$SWEEP" --apply
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
  [ "$status" -eq 0 ]
  [ -d "$TEST_TMPDIR/repos/held-open" ]
  [ -f "$TEST_TMPDIR/repos/held-open/f.txt" ]
  [[ "$output" == *"live process holds the tree open"* ]]
  [[ "$output" == *"restored from quarantine"* ]]
}

@test "an unreadable proc tree holds candidates (cannot prove absence of writers)" {
  mkclone "$TEST_TMPDIR/repos/noproc"
  age_tree 20 "$TEST_TMPDIR/repos/noproc"
  SWEEP_PROC_DIR="$TEST_TMPDIR/proc-does-not-exist" run "$SWEEP" --apply
  [ "$status" -eq 0 ]
  [ -d "$TEST_TMPDIR/repos/noproc" ]
  [[ "$output" == *"live process holds the tree open"* ]]
}

@test "a failing proc enumeration holds candidates (no fail-open fallback)" {
  # The scan must never authorize deletion off a partial enumeration. A find
  # that errors for a reason OTHER than a process vanishing is a hazard.
  # This exercises the GNU find path, which is the one production uses; BSD
  # find takes the readlink fallback and never reaches the stub.
  find . -maxdepth 0 -ignore_readdir_race -printf '' >/dev/null 2>&1 \
    || skip "requires GNU find (the production path); CI is node-8"
  mkclone "$TEST_TMPDIR/repos/procfail"
  age_tree 20 "$TEST_TMPDIR/repos/procfail"
  REAL_FIND="$(command -v find)"
  export REAL_FIND
  cat > "$TEST_TMPDIR/bin/find" <<'STUB'
#!/usr/bin/env bash
# Fail ONLY the proc scan; every other find (root enumeration, nested-repo
# probes) must still work or the test would pass for the wrong reason.
if [[ "$*" == *"$SWEEP_PROC_DIR"* ]]; then
  echo "find: $SWEEP_PROC_DIR: Permission denied" >&2; exit 1
fi
exec "$REAL_FIND" "$@"
STUB
  chmod +x "$TEST_TMPDIR/bin/find"
  run "$SWEEP" --apply
  rm -f "$TEST_TMPDIR/bin/find"; hash -r
  [ "$status" -eq 0 ]
  [ -d "$TEST_TMPDIR/repos/procfail" ]
  [[ "$output" == *"live process holds the tree open"* ]]
}

@test "a stale ref from ANOTHER remote does not vouch for a local branch" {
  # local release@A, cached upstream/release@A, live origin/release@B with A
  # an ancestor of B. Commit A survives via origin, but NO live remote carries
  # the NAME release at A — deleting the clone would lose that pointer.
  mkclone "$TEST_TMPDIR/repos/multi-remote"
  local c="$TEST_TMPDIR/repos/multi-remote"
  local origin; origin="$(ls -d "$TEST_TMPDIR"/origins/*multi-remote.git)"
  ( cd "$c" && git checkout -q -b release && echo a > a.txt && git add a.txt \
      && git commit -qm commit-A )
  # A second remote that still carries release@A.
  git init -q --bare "$TEST_TMPDIR/origins/upstream.git"
  ( cd "$c" && git remote add upstream "$TEST_TMPDIR/origins/upstream.git" \
      && git push -q upstream release )
  # origin gets release@B, a DESCENDANT of A, pushed from a separate clone so
  # our clone never caches refs/remotes/origin/release.
  git clone -q "$origin" "$TEST_TMPDIR/pusher"
  ( cd "$TEST_TMPDIR/pusher" && git fetch -q "$TEST_TMPDIR/origins/upstream.git" release \
      && git checkout -q -B release FETCH_HEAD && echo b > b.txt && git add b.txt \
      && git commit -qm commit-B && git push -q origin release )
  age_tree 20 "$c"
  run "$SWEEP" --apply
  [ "$status" -eq 0 ]
  [ -d "$c" ]
  [[ "$output" == *"local-branch"* ]]
  [[ "$output" == *"'release'"* ]]
}

@test "quarantine debris from an interrupted run is held, never swept" {
  # The prefix has already destroyed the keep-list basename match, so debris
  # must never be re-swept as an ordinary candidate.
  mkclone "$TEST_TMPDIR/repos/.sweep-quarantine.999.hydra"
  age_tree 30 "$TEST_TMPDIR/repos/.sweep-quarantine.999.hydra"
  run "$SWEEP" --apply
  [ "$status" -eq 0 ]
  [ -d "$TEST_TMPDIR/repos/.sweep-quarantine.999.hydra" ]
  [[ "$output" == *"quarantine leftover from an interrupted run"* ]]
}

@test "a failing nested-repo scan in the clone lane holds the candidate (fail closed)" {
  # The clone lane's `find -mindepth 2 -name .git` probe must not treat a
  # scan ERROR as "no inner repo" — an unproven absence can never authorize
  # a recursive delete.
  mkclone "$TEST_TMPDIR/repos/scanfail"
  age_tree 20 "$TEST_TMPDIR/repos/scanfail"
  REAL_FIND="$(command -v find)"
  export REAL_FIND INJECT_TARGET="$TEST_TMPDIR/repos/scanfail"
  cat > "$TEST_TMPDIR/bin/find" <<'STUB'
#!/usr/bin/env bash
if [[ "$*" == *"-mindepth 2"* && "$*" == *"$INJECT_TARGET"* ]]; then
  echo "find: $INJECT_TARGET: Input/output error" >&2; exit 1
fi
exec "$REAL_FIND" "$@"
STUB
  chmod +x "$TEST_TMPDIR/bin/find"
  run "$SWEEP" --apply
  rm -f "$TEST_TMPDIR/bin/find"; hash -r
  [ "$status" -eq 0 ]
  [ -d "$TEST_TMPDIR/repos/scanfail" ]
  [[ "$output" == *"nested-repo scan failed"* ]]
}

@test "structural refusal: out-of-scope roots are rejected in host-guarded mode" {
  # The production topology is fixed; only the explicit test override permits
  # sandbox roots. Pretend to be node-8 so the host guard passes and the
  # topology check is the thing under test.
  cat > "$TEST_TMPDIR/bin/hostname" <<'STUB'
#!/bin/bash
echo ovh-node-8
STUB
  chmod +x "$TEST_TMPDIR/bin/hostname"
  unset SWEEP_SKIP_HOST_GUARD
  run "$SWEEP" --apply
  rm -f "$TEST_TMPDIR/bin/hostname"; hash -r
  [ "$status" -eq 1 ]
  [[ "$output" == *"out-of-scope roots"* ]]
  [ -d "$TEST_TMPDIR/repos" ]
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
