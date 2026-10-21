#!/usr/bin/env bats
# Tests for scripts/lib/attribute-deletions.sh — the PR-gate half of the
# MUS-1374 deletion design (MUS-1390, child 5). The `Deploy pre-flight` CI job
# dry-runs rsync --delete against the LIVE /opt/hydra tree, so it used to fail
# on any deletion, including stray node-8 state no PR author can influence.
# It now blocks only on deletions the PR's own diff causes and warns on the
# rest; deploy.sh Step 4a (deletion-gate.sh) stays the authoritative blocker.
#
# The fixture is a REAL git repo (main + a PR branch), so the git diff the lib
# runs is the one CI runs — never a hand-written path list.
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
LIB="$HYDRA_REPO/scripts/lib/attribute-deletions.sh"

setup() {
  # shellcheck disable=SC1090
  source "$LIB"
  REPO="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$REPO/dir"
  export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
  git -C "$REPO" init -q -b main
  echo a >"$REPO/removed.txt"
  echo b >"$REPO/dir/inner.txt"
  echo c >"$REPO/renamed-away.sh"
  echo d >"$REPO/kept.txt"
  git -C "$REPO" add -A
  git -C "$REPO" commit -q -m base
  git -C "$REPO" checkout -q -b pr
}

pr_removes() { git -C "$REPO" rm -q "$@" && git -C "$REPO" commit -q -m pr; }

@test "deletion in the PR's own removed set: blocking verdict (rc 1), error annotation" {
  pr_removes removed.txt
  run attribute_deletions "*deleting   removed.txt" "$REPO" main
  [ "$status" -eq 1 ]
  [[ "$output" == *"::error::"* ]]
  [[ "$output" == *"PR: removed.txt"* ]]
}

@test "unrelated server state: warning verdict, rc 0, owner named, delta mode keeps the paths" {
  pr_removes removed.txt
  run attribute_deletions "*deleting   payout-report.csv" "$REPO" main
  [ "$status" -eq 0 ]
  [[ "$output" == *"::warning::"* ]]
  [[ "$output" != *"::error::"* ]]
  [[ "$output" == *"OTHER: payout-report.csv"* ]]
  [[ "$output" == *"Nick"* ]]
  # MUS-8090: a merge-triggered deploy is delta mode — it never reaches Step 4a
  # and never deletes a path outside its delta. The warning must say so, and
  # must not send the author to an RSYNC_EXCLUDES entry for a path delta mode
  # already leaves alone (an exclude would suppress legitimate transfers).
  [[ "$output" == *"delta"* && "$output" == *"will not delete"* ]]
  [[ "$output" == *"HYDRA_FULL_SYNC=1"* ]]
  [[ "$output" != *"NOT safe to deploy"* ]]
  [[ "$output" != *"halts the real deploy on ANY"* ]]
  [[ "$output" != *"add an --exclude line"* ]]
  [[ "$output" == *"(a) Real data"* && "$output" == *"(b) Runtime state"* && "$output" == *"(c) Actual garbage"* ]]
}

@test "mixed blob: blocking, both listed, only the attributed one is marked PR" {
  pr_removes removed.txt
  run attribute_deletions "$(printf '*deleting   removed.txt\n*deleting   stray.log')" "$REPO" main
  [ "$status" -eq 1 ]
  [[ "$output" == *"PR: removed.txt"* ]]
  [[ "$output" == *"OTHER: stray.log"* ]]
  [[ "$output" != *"PR: stray.log"* ]]
  [[ "$output" != *"OTHER: removed.txt"* ]]
}

@test "empty blob: rc 0, no warning, no error" {
  pr_removes removed.txt
  run attribute_deletions "" "$REPO" main
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "real rename: the OLD path (what rsync deletes) is attributed to the PR" {
  git -C "$REPO" mv renamed-away.sh renamed-to.sh
  git -C "$REPO" commit -q -m rename
  # sanity: git really sees a rename, so this is not a delete+add by accident
  [[ "$(git -C "$REPO" diff -M --name-status main...HEAD)" == R*renamed-away.sh*renamed-to.sh ]]
  run attribute_deletions "*deleting   renamed-away.sh" "$REPO" main
  [ "$status" -eq 1 ]
  [[ "$output" == *"PR: renamed-away.sh"* ]]
}

@test "directory the PR emptied is attributed; a sibling dir it did not touch is not" {
  pr_removes dir/inner.txt
  run attribute_deletions "$(printf '*deleting   dir/\n*deleting   other/')" "$REPO" main
  [ "$status" -eq 1 ]
  [[ "$output" == *"PR: dir/"* ]]
  [[ "$output" == *"OTHER: other/"* ]]
}

@test "a file the PR keeps is never attributed, even with a PR that removes others" {
  pr_removes removed.txt
  run attribute_deletions "*deleting   kept.txt" "$REPO" main
  [ "$status" -eq 0 ]
  [[ "$output" == *"OTHER: kept.txt"* ]]
}

@test "fails closed (rc 2, error) when git cannot compute the PR diff" {
  run attribute_deletions "*deleting   removed.txt" "$REPO" no-such-ref
  [ "$status" -eq 2 ]
  [[ "$output" == *"::error::"* ]]
}

@test "large removed set under pipefail: early-matching path is still attributed to the PR (no SIGPIPE misattribution)" {
  # >64 KB of removed paths so a writer piped into `grep -q` is still writing
  # when grep exits on the first (sorted) match. CI runs under
  # `set -euo pipefail`, where that 141 would flip the verdict to OTHER.
  mkdir -p "$REPO/big"
  local i
  for i in $(seq 1 3000); do : >"$REPO/big/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-$i.txt"; done
  git -C "$REPO" add -A && git -C "$REPO" commit -q -m big && git -C "$REPO" branch -f main HEAD
  git -C "$REPO" rm -q -r big && git -C "$REPO" commit -q -m pr
  local first="big/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-1.txt"
  run bash -c 'set -euo pipefail; source "$1"; attribute_deletions "$2" "$3" main' _ "$LIB" "*deleting   $first" "$REPO"
  [ "$status" -eq 1 ]
  [[ "$output" == *"PR: $first"* ]]
  [[ "$output" != *"OTHER:"* ]]
}

# --- exclude removal (bot NO-GO on #1184): a PR that removes or narrows an
# RSYNC_EXCLUDES entry exposes matching server-only files to rsync --delete.
# Git shows no removed path, so path attribution alone calls it OTHER.

# Fixture: base deploy.sh excludes state/ ; $1 is the exclude line the PR
# version keeps ("" = the PR deletes it). DEST holds server-only state/db.
exclude_fixture() {
  local pr_line="$1" i
  mkdir -p "$REPO/scripts"
  {
    echo "RSYNC_EXCLUDES=("
    for i in $(seq 1 3); do echo "  --exclude='pad$i/'"; done
    echo "  --exclude='state/'"
    echo ")"
  } >"$REPO/scripts/deploy.sh"
  git -C "$REPO" add -A && git -C "$REPO" commit -q -m base-excludes && git -C "$REPO" branch -f main HEAD
  if [ -z "$pr_line" ]; then
    grep -v "state/" "$REPO/scripts/deploy.sh" >"$REPO/scripts/deploy.sh.new"
    mv "$REPO/scripts/deploy.sh.new" "$REPO/scripts/deploy.sh"
  fi
  git -C "$REPO" commit -q -am pr-excludes || true
  DEST="$BATS_TEST_TMPDIR/dest"
  mkdir -p "$DEST/state" "$DEST/stray"
  echo x >"$DEST/state/db"
  echo y >"$DEST/stray/log"
}

# What the CI step does: PR-excludes dry-run, then the base-excludes dry-run.
pr_deletions() {
  local ex
  ex=$(sed -n '/^RSYNC_EXCLUDES=(/,/^)$/p' "$REPO/scripts/deploy.sh")
  local RSYNC_EXCLUDES=()
  eval "$ex"
  (cd "$REPO" && rsync -an --delete --itemize-changes "${RSYNC_EXCLUDES[@]}" ./ "$DEST/" | grep '^\*deleting' || true)
}

@test "PR removes an RSYNC_EXCLUDES entry while a matching server-only file exists: blocking (rc 1)" {
  exclude_fixture ""
  local del base
  del=$(pr_deletions)
  [[ "$del" == *"state/"* ]]   # sanity: removing the exclude really exposes state/
  base=$(base_exclude_deletions "$REPO" "$DEST" main)
  run attribute_deletions "$del" "$REPO" main "$base"
  [ "$status" -eq 1 ]
  [[ "$output" == *"::error::"* ]]
  [[ "$output" == *"PR: state/"* ]]
  [[ "$output" == *"OTHER: stray/"* ]]
}

@test "same fixture with the exclude intact: state/ is not exposed, stray server state only warns (rc 0)" {
  exclude_fixture "keep"
  local del base
  del=$(pr_deletions)
  [[ "$del" != *"state/"* ]]
  base=$(base_exclude_deletions "$REPO" "$DEST" main)
  run attribute_deletions "$del" "$REPO" main "$base"
  [ "$status" -eq 0 ]
  [[ "$output" == *"::warning::"* && "$output" != *"::error::"* ]]
  [[ "$output" == *"OTHER: stray/"* ]]
}

@test "baseline given but empty: every residual deletion is newly exposed by the PR" {
  exclude_fixture ""
  run attribute_deletions "*deleting   stray/" "$REPO" main ""
  [ "$status" -eq 1 ]
  [[ "$output" == *"PR: stray/"* ]]
}

@test "base_exclude_deletions fails closed (rc 2) when the base deploy.sh array cannot be read" {
  exclude_fixture "keep"
  run base_exclude_deletions "$REPO" "$DEST" no-such-ref
  [ "$status" -eq 2 ]
  [[ "$output" == *"::error::"* ]]
}

# --- add/type collision (bot NO-GO #2 on #1184): a PR that ADDS a file where the
# server holds a directory (or a file where the PR adds a directory) makes rsync
# delete the server's entry. Git shows no removed path and the baseline (same
# source tree or base tree) proposes the same deletion, so only the PR's added
# set can attribute it.

@test "PR adds a file where the server holds a directory: the directory's deletions are the PR's (rc 1)" {
  echo n >"$REPO/collide"
  git -C "$REPO" add -A && git -C "$REPO" commit -q -m add-collide
  run attribute_deletions "*deleting   collide/keep.txt
*deleting   collide/" "$REPO" main ""$'\n'"*deleting   collide/keep.txt"$'\n'"*deleting   collide/"
  [ "$status" -eq 1 ]
  [[ "$output" == *"PR: collide/keep.txt"* ]]
  [[ "$output" == *"PR: collide/"* ]]
}

@test "PR adds a file under a path where the server holds a file: that file's deletion is the PR's (rc 1)" {
  mkdir "$REPO/blocker" && echo n >"$REPO/blocker/inner"
  git -C "$REPO" add -A && git -C "$REPO" commit -q -m add-dir
  run attribute_deletions "*deleting   blocker" "$REPO" main "*deleting   blocker"
  [ "$status" -eq 1 ]
  [[ "$output" == *"PR: blocker"* ]]
}

@test "unrelated server state next to an added file still only warns (rc 0)" {
  echo n >"$REPO/collide"
  git -C "$REPO" add -A && git -C "$REPO" commit -q -m add-collide
  run attribute_deletions "*deleting   collider/x" "$REPO" main "*deleting   collider/x"
  [ "$status" -eq 0 ]
  [[ "$output" == *"OTHER: collider/x"* ]]
}

# rsync prints `*deleting` + exactly 3 spaces + the path verbatim. A filename's
# own leading whitespace is part of the path and must survive parsing, or git's
# removed path (" leading.txt") never matches the parsed one ("leading.txt").
@test "PR removes a file with a leading space: attributed to the PR, not parsed as unrelated (rc 1)" {
  git -C "$REPO" checkout -q main
  echo l >"$REPO/ leading.txt"
  git -C "$REPO" add -A && git -C "$REPO" commit -q -m add-leading
  git -C "$REPO" checkout -q pr && git -C "$REPO" merge -q main
  git -C "$REPO" rm -q " leading.txt" && git -C "$REPO" commit -q -m pr
  run attribute_deletions "*deleting    leading.txt" "$REPO" main
  [ "$status" -eq 1 ]
  [[ "$output" == *"PR:  leading.txt"* ]]
}

@test "leading-space path newly exposed by an exclude removal: baseline strips only the fixed delimiter (rc 0 when baseline has it)" {
  git -C "$REPO" checkout -q main
  echo l >"$REPO/ leading.txt"
  git -C "$REPO" add -A && git -C "$REPO" commit -q -m add-leading
  git -C "$REPO" checkout -q pr && git -C "$REPO" merge -q main
  run attribute_deletions "*deleting    leading.txt" "$REPO" main "*deleting    leading.txt"
  [ "$status" -eq 0 ]
  [[ "$output" == *"OTHER:  leading.txt"* ]]
  run attribute_deletions "*deleting    leading.txt" "$REPO" main ""
  [ "$status" -eq 1 ]
}
