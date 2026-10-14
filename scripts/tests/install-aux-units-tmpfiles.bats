#!/usr/bin/env bats
# Gates tests/test_install_aux_units_tmpfiles.sh (the behavioural test for the
# tmpfiles-age-by-mtime block in scripts/install-aux-units.sh) through the Bats
# job's scripts/ auto-discovery, so it runs in CI without a workflow edit:
# pr-validate.yml's "Run all bats suites under scripts/ ..." step collects
# `find scripts ... -type f -name '*.bats'` (pr-validate.yml:1304).
#
# The test itself stays under tests/ because it is not a bats suite; this file
# is the registration. Hermetic: the test stubs systemd-tmpfiles and runs in its
# own mktemp -d.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
}

@test "tmpfiles /tmp age policy stays mtime-keyed (tests/test_install_aux_units_tmpfiles.sh)" {
  run bash "$REPO_ROOT/tests/test_install_aux_units_tmpfiles.sh"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}
