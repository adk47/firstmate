#!/usr/bin/env bats
# Tests for scripts/qa-review-clone.sh — a PR checkout for QA test runs that
# borrows objects from a shared bare mirror and always deletes itself (MUS-5587).
# No network: QA_GH_SH is a stub that clones from a local ORIGIN.
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
SCRIPT="$HYDRA_REPO/scripts/qa-review-clone.sh"
SWEEPER="$HYDRA_REPO/scripts/sweep-workspace-clones.sh"

setup() {
  T="$(mktemp -d)"; export T
  export QA_REVIEW_TMP_ROOT="$T/tmp" QA_REVIEW_MIRROR_ROOT="$T/mirrors"
  export ORIGIN="$T/origin"
  git init -q -b main "$ORIGIN"
  git -C "$ORIGIN" config user.email t@t.t; git -C "$ORIGIN" config user.name t
  echo base > "$ORIGIN/f"; git -C "$ORIGIN" add f; git -C "$ORIGIN" commit -qm base
  git -C "$ORIGIN" checkout -qb pr-branch
  echo head > "$ORIGIN/f"; git -C "$ORIGIN" commit -qam head
  git -C "$ORIGIN" update-ref refs/pull/7/head HEAD
  git -C "$ORIGIN" checkout -q main
  # Stub: `repo clone R DIR -- ARGS` clones ORIGIN; `pr checkout N` detaches onto the PR head.
  cat > "$T/gh.sh" <<'STUB'
#!/bin/bash
[ "$1" = "--repo" ] && shift 2
echo "$*" >> "$T/gh.log"
if [ "$1 $2" = "repo clone" ]; then
  dir="$4"; shift 5   # repo clone R DIR --
  [ -n "${STUB_CLONE_FAIL:-}" ] && exit 1
  exec git clone "$@" "file://$ORIGIN" "$dir"
elif [ "$1 $2" = "pr checkout" ]; then
  git fetch -q origin "refs/pull/$3/head" && git checkout -q --detach FETCH_HEAD
fi
STUB
  chmod +x "$T/gh.sh"; export QA_GH_SH="$T/gh.sh"
}
teardown() { rm -rf "$T"; }

review_dirs() { find "$QA_REVIEW_TMP_ROOT" -mindepth 1 -maxdepth 1 -type d 2>/dev/null; }

@test "checks out the PR head in cwd, then removes the directory" {
  run "$SCRIPT" o/proj 7 -- bash -c 'cat f; echo "$PWD" > "$T/pwd"'
  [ "$status" -eq 0 ]
  [ "$output" = "head" ]
  [ -z "$(review_dirs)" ]
}

@test "directory is gone after a failing command, and its exit code is kept" {
  run "$SCRIPT" o/proj 7 -- bash -c 'exit 3'
  [ "$status" -eq 3 ]
  [ -z "$(review_dirs)" ]
}

@test "directory is gone after SIGTERM" {
  "$SCRIPT" o/proj 7 -- bash -c 'touch "$T/started"; sleep 30' &
  pid=$!
  for _ in $(seq 100); do [ -e "$T/started" ] && break; sleep 0.1; done
  [ -e "$T/started" ]
  [ -n "$(review_dirs)" ]
  kill -TERM "$pid"
  rc=0; wait "$pid" || rc=$?
  [ "$rc" -eq 143 ]
  [ -z "$(review_dirs)" ]
}

@test "SIGTERM also stops grandchildren of the command, not just its shell" {
  "$SCRIPT" o/proj 7 -- bash -c 'sleep 61 & echo $! > "$T/gc"; touch "$T/started"; wait' &
  pid=$!
  for _ in $(seq 100); do [ -e "$T/started" ] && break; sleep 0.1; done
  [ -e "$T/started" ]
  gc="$(cat "$T/gc")"
  kill -0 "$gc"
  kill -TERM "$pid"
  wait "$pid" || true
  for _ in $(seq 50); do kill -0 "$gc" 2>/dev/null || break; sleep 0.1; done
  ! kill -0 "$gc" 2>/dev/null
}

@test "same repo name under two owners gets two mirrors, never shared" {
  "$SCRIPT" a/proj 7 -- true
  "$SCRIPT" b/proj 7 -- true
  [ -d "$QA_REVIEW_MIRROR_ROOT/a__proj.git" ]
  [ -d "$QA_REVIEW_MIRROR_ROOT/b__proj.git" ]
  [ "$(grep -c '^repo clone' "$T/gh.log")" -eq 2 ]
}

@test "directory name matches the sweeper's qa-tmp pattern" {
  "$SCRIPT" o/proj 7 -- bash -c 'basename "$QA_REVIEW_CLONE_DIR" > "$T/name"'
  re="$(grep -o "QA_REVIEW_NAME_RE='[^']*'" "$SWEEPER" | sed "s/^[^']*'//; s/'\$//")"
  [ -n "$re" ]
  [[ "$(cat "$T/name")" =~ $re ]]
}

@test "review clone borrows objects from the mirror (alternates), and the mirror survives cleanup" {
  "$SCRIPT" o/proj 7 -- bash -c 'cat .git/objects/info/alternates > "$T/alt"'
  [ "$(cat "$T/alt")" = "$(cd "$QA_REVIEW_MIRROR_ROOT/o__proj.git/objects" && pwd -P)" ]
  [ -d "$QA_REVIEW_MIRROR_ROOT/o__proj.git/objects" ]
  # a second review reuses the mirror: only one `repo clone` ever ran
  "$SCRIPT" o/proj 7 -- true
  [ "$(grep -c '^repo clone' "$T/gh.log")" -eq 1 ]
}

@test "falls back to a blobless shallow clone when the mirror cannot be created" {
  # first clone attempt (the mirror, --bare) fails; the fallback one must not
  cat > "$T/gh2.sh" <<'STUB'
#!/bin/bash
case "$*" in *--bare*) exit 1 ;; esac
exec "$QA_REAL_GH" "$@"
STUB
  chmod +x "$T/gh2.sh"; export QA_REAL_GH="$T/gh.sh" QA_GH_SH="$T/gh2.sh"
  run "$SCRIPT" o/proj 7 -- cat f
  [ "$status" -eq 0 ]
  [[ "$output" == *"falling back"* ]]
  [[ "$output" == *"head" ]]
  grep -q -- '--filter=blob:none --depth=50' "$T/gh.log"
  [ -z "$(review_dirs)" ]
}

@test "fails loudly and still cleans up when no checkout is possible" {
  STUB_CLONE_FAIL=1 run "$SCRIPT" o/proj 7 -- true
  [ "$status" -eq 1 ]
  [[ "$output" == *"could not check out"* ]]
  [ -z "$(review_dirs)" ]
}

@test "concurrent reviews share one mirror and all succeed" {
  command -v flock >/dev/null || skip "flock not installed"
  pids=""
  for _ in 1 2 3; do "$SCRIPT" o/proj 7 -- true & pids="$pids $!"; done
  for p in $pids; do wait "$p"; done
  [ "$(grep -c '^repo clone' "$T/gh.log")" -eq 1 ]
  [ -z "$(review_dirs)" ]
}

@test "rejects malformed repo and pr arguments" {
  run "$SCRIPT" 'bad repo' 7 -- true; [ "$status" -eq 2 ]
  run "$SCRIPT" o/proj x7 -- true;    [ "$status" -eq 2 ]
  run "$SCRIPT" o/proj 7 true;        [ "$status" -eq 2 ]
}
