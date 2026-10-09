#!/usr/bin/env bats
# Tests for scripts/check-mktemp-traps.sh — fails on a `mktemp -d` in scripts/**
# that has no cleanup trap naming its variable and no `mktemp-ok:` reason
# (MUS-5645: 450 anonymous /tmp/tmp.* dirs on node-8).
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
GUARD="$HYDRA_REPO/scripts/check-mktemp-traps.sh"

setup() {
  TEST_TMPDIR="$(mktemp -d "${TMPDIR:-/tmp}/mktemp-trap-guard.XXXXXX")"
  mkdir -p "$TEST_TMPDIR/scripts"
}
teardown() { rm -rf "$TEST_TMPDIR"; }

run_guard() { MKTEMP_GUARD_ROOT="$TEST_TMPDIR" run "$GUARD"; }

@test "repo scripts/** is clean" {
  run "$GUARD"
  [ "$status" -eq 0 ]
}

@test "bare untrapped mktemp -d fails" {
  printf '#!/bin/bash\nwork="$(mktemp -d)"\necho hi\n' > "$TEST_TMPDIR/scripts/leaky.sh"
  run_guard
  [ "$status" -eq 1 ]
  [[ "$output" == *"leaky.sh:2"* ]]
}

@test "EXIT trap naming the variable passes" {
  printf '#!/bin/bash\nwork="$(mktemp -d)"\ntrap '"'"'rm -rf "$work"'"'"' EXIT\n' > "$TEST_TMPDIR/scripts/ok.sh"
  run_guard
  [ "$status" -eq 0 ]
}

@test "trap handler function that removes the variable passes" {
  printf '#!/bin/bash\nwork="$(mktemp -d)"\nbye() { rm -rf "$work"; }\ntrap bye EXIT\n' > "$TEST_TMPDIR/scripts/fn.sh"
  run_guard
  [ "$status" -eq 0 ]
}

@test "rm without any trap fails" {
  printf '#!/bin/bash\nwork="$(mktemp -d)"\nrm -rf "$work"\n' > "$TEST_TMPDIR/scripts/norap.sh"
  run_guard
  [ "$status" -eq 1 ]
}

@test "mktemp-ok comment on the previous line passes" {
  printf '#!/bin/bash\n# mktemp-ok: persists for the next run\nwork="$(mktemp -d)"\n' > "$TEST_TMPDIR/scripts/persist.sh"
  run_guard
  [ "$status" -eq 0 ]
}

@test "mktemp -d inside a comment is ignored" {
  printf '#!/bin/bash\n# uses mktemp -d (mode 700)\n' > "$TEST_TMPDIR/scripts/c.sh"
  run_guard
  [ "$status" -eq 0 ]
}

@test "scripts/tests fixtures are out of scope" {
  mkdir -p "$TEST_TMPDIR/scripts/tests"
  printf 'TEST_TMPDIR="$(mktemp -d)"\n' > "$TEST_TMPDIR/scripts/tests/x.bats"
  run_guard
  [ "$status" -eq 0 ]
}

@test "trapped handler that does not remove the variable fails even with an inline rm" {
  printf '#!/bin/bash\nwork="$(mktemp -d)"\ncleanup() { :; }\ntrap cleanup EXIT\nrm -rf "$work"\n' > "$TEST_TMPDIR/scripts/emptyhandler.sh"
  run_guard
  [ "$status" -eq 1 ]
  [[ "$output" == *"emptyhandler.sh:2"* ]]
}

@test "multi-line trapped handler that removes the variable passes" {
  printf '#!/bin/bash\nwork="$(mktemp -d)"\ncleanup() {\n  rm -rf "$work"\n}\ntrap cleanup EXIT\n' > "$TEST_TMPDIR/scripts/ml.sh"
  run_guard
  [ "$status" -eq 0 ]
}

@test "direct trap that only mentions the variable without rm fails" {
  printf '#!/bin/bash\nwork="$(mktemp -d)"\ntrap '"'"'echo "$work" >/dev/null'"'"' EXIT\n' > "$TEST_TMPDIR/scripts/echotrap.sh"
  run_guard
  [ "$status" -eq 1 ]
  [[ "$output" == *"echotrap.sh:2"* ]]
}

@test "direct trap on ERR only (never fires on success) fails" {
  printf '#!/bin/bash\nwork="$(mktemp -d)"\ntrap '"'"'rm -rf "$work"'"'"' ERR\n' > "$TEST_TMPDIR/scripts/errtrap.sh"
  run_guard
  [ "$status" -eq 1 ]
  [[ "$output" == *"errtrap.sh:2"* ]]
}

@test "handler trapped on ERR only fails" {
  printf '#!/bin/bash\nwork="$(mktemp -d)"\ncleanup() { rm -rf "$work"; }\ntrap cleanup ERR\n' > "$TEST_TMPDIR/scripts/errfn.sh"
  run_guard
  [ "$status" -eq 1 ]
  [[ "$output" == *"errfn.sh:2"* ]]
}
