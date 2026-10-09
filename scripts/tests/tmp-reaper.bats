#!/usr/bin/env bats
# Tests for scripts/tmp-reaper.sh. Hermetic: fixture tree under BATS_TEST_TMPDIR.
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
REAPER="${TMP_REAPER_SCRIPT:-$HYDRA_REPO/scripts/tmp-reaper.sh}"

# mk <name> <hours-old> [file|dir]  (mtime set on the top-level entry)
mk() {
  local path="$TMP_REAPER_ROOT/$1" kind="${3:-dir}" ts
  if [ "$kind" = dir ]; then mkdir -p "$path/repo"; echo x > "$path/repo/f"; else echo x > "$path"; fi
  ts=$(date -u -d "$2 hours ago" +%Y%m%d%H%M 2>/dev/null || date -u -v-"$2"H +%Y%m%d%H%M)
  TZ=UTC touch -t "$ts" "$path"
}

setup() {
  export TMP_REAPER_ROOT="$BATS_TEST_TMPDIR/tmp"
  mkdir -p "$TMP_REAPER_ROOT"
  : > "$BATS_TEST_TMPDIR/mounts"
  export SAFE_DELETE_MOUNTS_FILE="$BATS_TEST_TMPDIR/mounts"
}

@test "review clone idle 4h is deleted, 2h is kept" {
  mk core-backend-10192-review-lMTbi5 4
  mk core-backend-10193-review-aB3dE9 2
  run "$REAPER"
  [ "$status" -eq 0 ]
  [ ! -e "$TMP_REAPER_ROOT/core-backend-10192-review-lMTbi5" ]
  [ -d "$TMP_REAPER_ROOT/core-backend-10193-review-aB3dE9" ]
  [[ "$output" == *"deleted"*"core-backend-10192-review-lMTbi5"* ]]
  [[ "$output" == *"reclaimed_kib="* ]]
}

@test "pr-review json, qa-pr-*, qa-alerts.* follow the 3h TTL" {
  mk pr-review-123.json 4 file
  mk pr-review-124.json 1 file
  mk qa-pr-9-abc 4
  mk qa-alerts.X1y2Z3 4
  run "$REAPER"
  [ ! -e "$TMP_REAPER_ROOT/pr-review-123.json" ]
  [ -e "$TMP_REAPER_ROOT/pr-review-124.json" ]
  [ ! -e "$TMP_REAPER_ROOT/qa-pr-9-abc" ]
  [ ! -e "$TMP_REAPER_ROOT/qa-alerts.X1y2Z3" ]
}

@test "tmp.XXXXXX idle 25h is deleted, 2h is kept" {
  mk tmp.AbC123 25
  mk tmp.dEf456 2
  run "$REAPER"
  [ ! -e "$TMP_REAPER_ROOT/tmp.AbC123" ]
  [ -e "$TMP_REAPER_ROOT/tmp.dEf456" ]
}

@test "tmp.XXXXXX idle 5h is kept (24h class, not 3h)" {
  mk tmp.GhI789 5
  run "$REAPER"
  [ -e "$TMP_REAPER_ROOT/tmp.GhI789" ]
}

@test "jest_0 survives at any age" {
  mk jest_0 500
  run "$REAPER"
  [ -d "$TMP_REAPER_ROOT/jest_0" ]
}

@test "jest_0 survives even if the directory regex is widened" {
  mk jest_0 500
  TMP_REAPER_DIR_RE='.*' run "$REAPER"
  [ -d "$TMP_REAPER_ROOT/jest_0" ]
}

@test "socket dirs survive at any age" {
  mk .X11-unix 500
  mk .ICE-unix 500
  run "$REAPER"
  [ -d "$TMP_REAPER_ROOT/.X11-unix" ]
  [ -d "$TMP_REAPER_ROOT/.ICE-unix" ]
}

@test "a directory with an open file handle survives" {
  mkdir -p "$TMP_REAPER_ROOT/core-backend-1-review-OPEN01"
  exec 9> "$TMP_REAPER_ROOT/core-backend-1-review-OPEN01/held"
  mk core-backend-1-review-OPEN01 10  # age the dir after the create bumped its mtime
  run "$REAPER"
  exec 9>&-
  [ -d "$TMP_REAPER_ROOT/core-backend-1-review-OPEN01" ]
  [[ "$output" == *"skip (open handles)"* ]]
}

@test "a FILE held open survives (tmp.XXXXXX, qa-alerts.* and pr-review-*.json classes)" {
  mk tmp.AbC123 25 file
  mk qa-alerts.live 4 file
  mk pr-review-77.json 4 file
  exec 8>> "$TMP_REAPER_ROOT/tmp.AbC123"
  exec 7>> "$TMP_REAPER_ROOT/qa-alerts.live"
  exec 6>> "$TMP_REAPER_ROOT/pr-review-77.json"
  mk tmp.AbC123 25 file
  mk qa-alerts.live 4 file
  mk pr-review-77.json 4 file
  run "$REAPER"
  exec 8>&- 7>&- 6>&-
  [ -e "$TMP_REAPER_ROOT/tmp.AbC123" ]
  [ -e "$TMP_REAPER_ROOT/qa-alerts.live" ]
  [ -e "$TMP_REAPER_ROOT/pr-review-77.json" ]
  [[ "$output" == *"skipped_busy=3"* ]]
}

@test "a path matching no pattern is untouched, however old" {
  mk some-random-dir 500
  mk notes.txt 500 file
  mk core-backend-review-short 500
  mk Core-Backend-1-review-abcdef 500
  run "$REAPER"
  [ -d "$TMP_REAPER_ROOT/some-random-dir" ]
  [ -e "$TMP_REAPER_ROOT/notes.txt" ]
  [ -d "$TMP_REAPER_ROOT/core-backend-review-short" ]
  [ -d "$TMP_REAPER_ROOT/Core-Backend-1-review-abcdef" ]
}

@test "symlinks are never followed or removed" {
  mkdir -p "$BATS_TEST_TMPDIR/outside"; echo keep > "$BATS_TEST_TMPDIR/outside/f"
  ln -s "$BATS_TEST_TMPDIR/outside" "$TMP_REAPER_ROOT/core-backend-2-review-LINK01"
  run "$REAPER"
  [ -f "$BATS_TEST_TMPDIR/outside/f" ]
  [ -L "$TMP_REAPER_ROOT/core-backend-2-review-LINK01" ]
}

@test "an lsof failure fails closed: the path survives and the run exits non-zero" {
  mk core-backend-5-review-LSOF01 10
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  printf '#!/bin/sh\necho "lsof: WARNING: can'"'"'t stat() fuse" >&2\nexit 1\n' > "$BATS_TEST_TMPDIR/bin/lsof"
  chmod +x "$BATS_TEST_TMPDIR/bin/lsof"
  PATH="$BATS_TEST_TMPDIR/bin:$PATH" run "$REAPER"
  [ "$status" -ne 0 ]
  [ -d "$TMP_REAPER_ROOT/core-backend-5-review-LSOF01" ]
  [[ "$output" == *"lsof failed"* ]]
}

@test "a failed deletion makes the run exit non-zero" {
  mk core-backend-6-review-RMFAIL 10
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  printf '#!/bin/sh\nexit 1\n' > "$BATS_TEST_TMPDIR/bin/rm"
  chmod +x "$BATS_TEST_TMPDIR/bin/rm"
  PATH="$BATS_TEST_TMPDIR/bin:$PATH" run "$REAPER"
  [ "$status" -ne 0 ]
  [[ "$output" == *"could not delete"* ]]
}

@test "a mktemp failure fails closed: the path survives and the run exits non-zero" {
  mk core-backend-7-review-MKTMP1 10
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  # Fail only the reaper's own bare `mktemp`; the lib's templated calls pass, so the lib's guard can't mask a regression here.
  printf '#!/bin/sh\n[ "$#" -eq 0 ] || exec /usr/bin/mktemp "$@"\necho "mktemp: No space left on device" >&2\nexit 1\n' > "$BATS_TEST_TMPDIR/bin/mktemp"
  # lsof: reaper's `-t` probe says "no match" (rc 1); the lib's whole-system scan succeeds, so only the reaper's own mktemp guard can keep the path.
  printf '#!/bin/sh\n[ "$1" = "-t" ] && exit 1\nexit 0\n' > "$BATS_TEST_TMPDIR/bin/lsof"
  chmod +x "$BATS_TEST_TMPDIR/bin/mktemp" "$BATS_TEST_TMPDIR/bin/lsof"
  PATH="$BATS_TEST_TMPDIR/bin:$PATH" run "$REAPER"
  [ "$status" -ne 0 ]
  [ -d "$TMP_REAPER_ROOT/core-backend-7-review-MKTMP1" ]
}

@test "a mountpoint under an expired candidate keeps it (deletion goes through the safe-delete lib)" {
  mk core-backend-8-review-MOUNT1 10
  printf 'tmpfs %s/core-backend-8-review-MOUNT1/repo tmpfs rw 0 0\n' "$TMP_REAPER_ROOT" > "$SAFE_DELETE_MOUNTS_FILE"
  run "$REAPER"
  [ "$status" -ne 0 ]
  [ -f "$TMP_REAPER_ROOT/core-backend-8-review-MOUNT1/repo/f" ]
}
