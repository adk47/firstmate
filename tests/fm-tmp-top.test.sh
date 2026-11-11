#!/usr/bin/env bash
# Behavior tests for bin/fm-tmp-top - the bounded /tmp inspection helper.
#
# fm-tmp-top exists so operators never per-item-fork over a huge directory. It
# must report a total, the top entries by size, and an entry count in one pass,
# and it must refuse a non-directory target instead of producing empty sections.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_TOP="$ROOT/bin/fm-tmp-top"
assert_present "$TMP_TOP" "bin/fm-tmp-top is missing"
[ -x "$TMP_TOP" ] || fail "bin/fm-tmp-top must be executable"

TMP_ROOT=$(fm_test_tmproot fm-tmp-top)

test_reports_three_sections_and_entries() {
  local fixture out top_section count expected
  fixture="$TMP_ROOT/scan-target"
  mkdir -p "$fixture/beta"
  dd if=/dev/zero of="$fixture/beta/payload" bs=1M count=2 status=none
  : > "$fixture/alpha"
  : > "$fixture/gamma"

  out=$("$TMP_TOP" "$fixture" 2>&1) || fail "fm-tmp-top failed on a directory: $out"

  assert_contains "$out" "== $fixture total" "total section missing"
  assert_contains "$out" "== top 20 by size" "top-20 section missing"
  assert_contains "$out" "== entry count" "entry-count section missing"

  top_section=$(printf '%s\n' "$out" | sed -n '/== top 20 by size/,/== entry count/p')
  assert_contains "$top_section" "beta" "top-20 section must include the largest entry"

  expected=3
  count=$(printf '%s\n' "$out" | awk '/== entry count/{getline; print; exit}')
  [ "$count" = "$expected" ] \
    || fail "entry count: expected $expected, got '$count'"
  pass "fm-tmp-top reports total, top entries, and entry count for a directory"
}

test_rejects_non_directory() {
  local file out status
  file="$TMP_ROOT/not-a-dir"
  : > "$file"

  set +e
  out=$("$TMP_TOP" "$file" 2>&1)
  status=$?
  set -e

  expect_code 2 "$status" "fm-tmp-top on a regular file"
  assert_contains "$out" "not a directory: $file" "non-directory error message missing"
  assert_not_contains "$out" "== entry count" "non-directory target must not print sections"
  pass "fm-tmp-top rejects a non-directory target with exit 2"
}

test_reports_three_sections_and_entries
test_rejects_non_directory
