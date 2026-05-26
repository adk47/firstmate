#!/usr/bin/env bats
# Tests for scripts/release-cron.sh — the systemd-invoked release wrapper.
# Validates:
#   - date-gate behaviour before/after $RELEASE_CRON_ACTIVATION_UTC
#   - refusal when the dedicated release checkout is missing
#   - fetch + reset + invoke happy path against a stub release.sh
#   - exit-10 propagation from release.sh's "no commits in range"
#
# PATH-shadows release.sh inside the test repo so we never invoke
# the real one (which would try to fetch the real origin, push tags,
# call gh, etc.). Per feedback_bats_must_stub_openclaw.md — never
# let a bats test reach production surfaces.
bats_require_minimum_version 1.5.0

REPO_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
CRON_SH="$REPO_ROOT/scripts/release-cron.sh"

setup() {
  TEST_TMPDIR="$(mktemp -d)"
  export TEST_TMPDIR

  # Build a fake release checkout. release-cron.sh will cd here,
  # `git fetch`, and exec ./scripts/release.sh — all of which we
  # stub or point at local fixtures.
  export RELEASE_REPO_DIR="$TEST_TMPDIR/repo"
  mkdir -p "$RELEASE_REPO_DIR/scripts"

  # Initialize a fake origin (bare) and the release checkout.
  ORIGIN_BARE="$TEST_TMPDIR/origin.git"
  git init -q --bare "$ORIGIN_BARE"

  cd "$RELEASE_REPO_DIR"
  git init -q
  git checkout -q -b main
  git -c user.email=t@t -c user.name=t commit -q --allow-empty -m "initial"
  git remote add origin "$ORIGIN_BARE"
  git push -q origin main

  # Stub release.sh: takes an EXIT_CODE env to simulate different
  # outcomes (0 = success, 10 = nothing-to-release, 1 = real failure).
  cat > "$RELEASE_REPO_DIR/scripts/release.sh" <<'STUB'
#!/bin/bash
echo "RELEASE_SH_INVOKED args=$* exit=${STUB_EXIT_CODE:-0}"
exit "${STUB_EXIT_CODE:-0}"
STUB
  chmod +x "$RELEASE_REPO_DIR/scripts/release.sh"
  # Commit the stub so `git reset --hard origin/main` doesn't wipe it.
  cd "$RELEASE_REPO_DIR"
  git add scripts/release.sh
  git -c user.email=t@t -c user.name=t commit -q -m "stub release.sh"
  git push -q origin main
}

teardown() {
  rm -rf "$TEST_TMPDIR"
}

@test "gate-not-yet: future activation → exit 0, release.sh NOT invoked" {
  export RELEASE_CRON_ACTIVATION_UTC="2099-01-01T00:00:00Z"
  run "$CRON_SH"
  [ "$status" -eq 0 ]
  [[ "$output" == *"not yet active"* ]]
  [[ "$output" != *"RELEASE_SH_INVOKED"* ]]
}

@test "gate-cleared happy path: release.sh runs and exit 0 propagates" {
  export RELEASE_CRON_ACTIVATION_UTC="1970-01-02T00:00:00Z"
  export STUB_EXIT_CODE=0
  run "$CRON_SH"
  [ "$status" -eq 0 ]
  [[ "$output" == *"gate cleared"* ]]
  [[ "$output" == *"checkout at"* ]]
  [[ "$output" == *"RELEASE_SH_INVOKED args=--no-edit"* ]]
}

@test "gate-cleared: exit 10 (no commits) propagates as 10" {
  export RELEASE_CRON_ACTIVATION_UTC="1970-01-02T00:00:00Z"
  export STUB_EXIT_CODE=10
  run "$CRON_SH"
  [ "$status" -eq 10 ]
  [[ "$output" == *"RELEASE_SH_INVOKED"* ]]
}

@test "gate-cleared: exit 1 (real failure) propagates as 1, NOT swallowed" {
  export RELEASE_CRON_ACTIVATION_UTC="1970-01-02T00:00:00Z"
  export STUB_EXIT_CODE=1
  run "$CRON_SH"
  [ "$status" -eq 1 ]
  [[ "$output" == *"RELEASE_SH_INVOKED"* ]]
}

@test "missing release checkout: dies loudly with installer hint" {
  export RELEASE_CRON_ACTIVATION_UTC="1970-01-02T00:00:00Z"
  export RELEASE_REPO_DIR="$TEST_TMPDIR/does-not-exist"
  run "$CRON_SH"
  [ "$status" -eq 1 ]
  [[ "$output" == *"not a git checkout"* ]]
  [[ "$output" == *"install-aux-units.sh"* ]]
}

@test "unparseable activation timestamp → exit 1 with parse error" {
  export RELEASE_CRON_ACTIVATION_UTC="not-a-timestamp"
  run "$CRON_SH"
  [ "$status" -eq 1 ]
  [[ "$output" == *"could not parse activation timestamp"* ]]
}

@test "fetch + reset wipes manual edits before invoking release.sh" {
  export RELEASE_CRON_ACTIVATION_UTC="1970-01-02T00:00:00Z"
  # Modify a tracked file in the local checkout
  echo "manual-edit-that-should-be-wiped" >> "$RELEASE_REPO_DIR/scripts/release.sh"
  run "$CRON_SH"
  [ "$status" -eq 0 ]
  # Check the file was reset back to the pristine stub
  ! grep -q "manual-edit-that-should-be-wiped" "$RELEASE_REPO_DIR/scripts/release.sh"
}
