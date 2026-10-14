#!/usr/bin/env bats
# Tests for scripts/size-capped-evict.sh. Hermetic: fixture tree under BATS_TEST_TMPDIR.
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
RULE="${SIZE_CAPPED_SCRIPT:-$HYDRA_REPO/scripts/size-capped-evict.sh}"

# mk <child> <hours-old> <kib>  (a dir child of the container, mtime set on the child)
mk() {
  local path="$SIZE_CAP_ROOT/$1" ts
  mkdir -p "$path"
  dd if=/dev/zero of="$path/blob" bs=1024 count="$3" 2>/dev/null
  ts=$(date -u -d "$2 hours ago" +%Y%m%d%H%M 2>/dev/null || date -u -v-"$2"H +%Y%m%d%H%M)
  TZ=UTC touch -t "$ts" "$path"
}

setup() {
  export SIZE_CAP_ROOT="$BATS_TEST_TMPDIR/jest_0"
  mkdir -p "$SIZE_CAP_ROOT"
  : > "$BATS_TEST_TMPDIR/mounts"
  export SAFE_DELETE_MOUNTS_FILE="$BATS_TEST_TMPDIR/mounts"
  export SIZE_CAP_APPLY=1
}

@test "evicts oldest children first until under the cap" {
  mk old 30 100; mk mid 20 100; mk new 10 100
  SIZE_CAP_KIB=220 run "$RULE"
  [ "$status" -eq 0 ]
  [ ! -e "$SIZE_CAP_ROOT/old" ]
  [ -d "$SIZE_CAP_ROOT/mid" ]
  [ -d "$SIZE_CAP_ROOT/new" ]
  [[ "$output" == *"evicted="*"1"* ]]
}

@test "under the cap deletes nothing" {
  mk old 30 100
  SIZE_CAP_KIB=100000 run "$RULE"
  [ "$status" -eq 0 ]
  [ -d "$SIZE_CAP_ROOT/old" ]
}

@test "the container itself survives a cap of 0 (jest_0 is live; only children go)" {
  mk old 30 100; mk older 40 100
  SIZE_CAP_KIB=0 SIZE_CAP_MIN_AGE_MIN=0 run "$RULE"
  [ "$status" -eq 0 ]
  [ -d "$SIZE_CAP_ROOT" ]
  [ ! -e "$SIZE_CAP_ROOT/old" ]
  [ ! -e "$SIZE_CAP_ROOT/older" ]
}

@test "child younger than the min age survives even over the cap" {
  mk old 30 100; mk fresh 0 100
  SIZE_CAP_KIB=0 run "$RULE"
  [ ! -e "$SIZE_CAP_ROOT/old" ]
  [ -d "$SIZE_CAP_ROOT/fresh" ]
}

@test "child with an open handle survives and is counted as skipped" {
  command -v lsof >/dev/null || skip "lsof missing"
  mk held 30 100; mk free 20 100
  sleep 30 < "$SIZE_CAP_ROOT/held/blob" & pid=$!
  SIZE_CAP_KIB=0 run "$RULE"
  kill "$pid" 2>/dev/null || true
  [ -d "$SIZE_CAP_ROOT/held" ]
  [ ! -e "$SIZE_CAP_ROOT/free" ]
  [[ "$output" == *"skipped_open=1"* ]]
}

@test "dry-run (default) deletes nothing and reports what it would free" {
  mk old 30 100
  unset SIZE_CAP_APPLY
  SIZE_CAP_KIB=0 run "$RULE"
  [ "$status" -eq 0 ]
  [ -d "$SIZE_CAP_ROOT/old" ]
  [[ "$output" == *"dry_run=1"* ]]
  [[ "$output" == *"would evict"*"old"* ]]
}

@test "refuses a symlinked container, / and /tmp" {
  mk old 30 100
  ln -s "$SIZE_CAP_ROOT" "$BATS_TEST_TMPDIR/link"
  SIZE_CAP_ROOT="$BATS_TEST_TMPDIR/link" SIZE_CAP_KIB=0 run "$RULE"
  [ "$status" -eq 2 ]
  [ -d "$SIZE_CAP_ROOT/old" ]
  SIZE_CAP_ROOT=/ run "$RULE"; [ "$status" -eq 2 ]
  SIZE_CAP_ROOT=/tmp run "$RULE"; [ "$status" -eq 2 ]
}

@test "a missing container is a clean no-op" {
  rm -rf "$SIZE_CAP_ROOT"
  run "$RULE"
  [ "$status" -eq 0 ]
}

@test "non-numeric SIZE_CAP_KIB is refused (exit 2), nothing evicted" {
  mk old 30 100
  SIZE_CAP_KIB=5G run "$RULE"
  [ "$status" -eq 2 ]
  [ -d "$SIZE_CAP_ROOT/old" ]
}

@test "non-numeric SIZE_CAP_MIN_AGE_MIN is refused (exit 2), fresh child survives" {
  mk fresh 0 100
  SIZE_CAP_MIN_AGE_MIN=1h SIZE_CAP_KIB=0 run "$RULE"
  [ "$status" -eq 2 ]
  [ -d "$SIZE_CAP_ROOT/fresh" ]
}

@test "a failing du on one child still emits the summary and evicts later children" {
  mk old 30 100; mk mid 20 100
  mkdir -p "$BATS_TEST_TMPDIR/shim"
  real_du="$(command -v du)"
  cat > "$BATS_TEST_TMPDIR/shim/du" <<SH
#!/bin/bash
case "\$*" in *"/old"*) exit 1 ;; esac
exec "$real_du" "\$@"
SH
  chmod +x "$BATS_TEST_TMPDIR/shim/du"
  PATH="$BATS_TEST_TMPDIR/shim:$PATH" SIZE_CAP_KIB=0 SIZE_CAP_MIN_AGE_MIN=0 run "$RULE"
  [[ "$output" == *"size-capped: done"* ]]
  [ ! -e "$SIZE_CAP_ROOT/mid" ]
}
