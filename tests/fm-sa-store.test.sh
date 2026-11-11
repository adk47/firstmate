#!/usr/bin/env bash
# Behavior tests for the SA store suite (sa/tests/test_store.py).
#
# The suite is Python unittest; this wrapper is what bin/fm-test-run.sh and CI
# execute, so it proves the suite actually ran and passed instead of trusting an
# empty discovery.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

test_suite_runs_and_passes() {
  local out rc
  set +e
  out=$(cd "$ROOT" && python3 -m unittest discover -s sa/tests -t sa/tests -v 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "sa store suite failed: $out"
  printf '%s\n' "$out" | grep -Eq '^Ran [1-9][0-9]* tests? in ' \
    || fail "sa store suite discovered no tests: $out"
  pass "sa store suite runs and passes"
}

test_selftest_proves_identical_replay() {
  local home out rc
  home=$(fm_test_tmproot fm-sa-store)/home
  mkdir -p "$home"
  set +e
  out=$(cd "$ROOT" && SA_HOME="$home" sa/bin/sa-store selftest 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "sa-store selftest failed: $out"
  printf '%s\n' "$out" | grep -Eq '^PASS$' || fail "sa-store selftest did not print PASS: $out"
  [ "$(printf '%s\n' "$out" | grep -c '^state [AB] sha256: [0-9a-f]\{64\}$')" = 2 ] \
    || fail "sa-store selftest did not print both 64-hex state hashes: $out"
  pass "sa-store selftest prints both state hashes and passes"
}

test_suite_runs_and_passes
test_selftest_proves_identical_replay
