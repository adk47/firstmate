#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
LIB="$HYDRA_REPO/scripts/lib/muso-env-preflight.sh"

setup() {
  TEST_TMPDIR="$(mktemp -d)"
  ENV_FILE="$TEST_TMPDIR/main.env"
}

teardown() {
  rm -rf "$TEST_TMPDIR"
}

write_complete_env() {
  printf '%s\n' \
    "MUSO_ADMIN_EMAIL='legacy admin@muso.ai'" \
    'MUSO_ADMIN_PASSWORD="legacy password"' \
    'MUSO_PROD_ADMIN_EMAIL=prod@muso.ai' \
    'MUSO_PROD_ADMIN_PASSWORD="prod password"' \
    'MUSO_DEV_ADMIN_EMAIL=dev@muso.ai' \
    'MUSO_DEV_ADMIN_PASSWORD="dev password"' \
    'MUSO_ENV=dev' \
    'MUSO_ENV=prod' \
    'MUSO_NONINTERACTIVE=0' \
    'MUSO_NONINTERACTIVE=1' \
    'MUSO_STATE_DIR=/tmp/wrong' \
    'MUSO_STATE_DIR=/var/log/muso-ops' > "$ENV_FILE"
}

# Cases tagged `host-systemd` drive the REAL systemd-run (that is what they test: systemd's
# EnvironmentFile parsing, not a shell imitation of it), so they need a host whose PID 1 is
# systemd. PR Validation runs them ONLY in its node-8 job (`bats --filter-tags host-systemd`)
# and excludes them from the in-cluster ARC shards, whose pods have no systemd
# (2026-10-27, PR CI off node-8). Every other case here stubs systemd-run and runs anywhere.
run_check() {
  run bash -c 'source "$1"; muso_main_env_missing "$2"' _ "$LIB" "$ENV_FILE"
}

# bats test_tags=host-systemd
@test "systemd quoting and last duplicate assignment produce a valid environment" {
  write_complete_env

  run_check

  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# bats test_tags=host-systemd
@test "an empty final assignment is reported as missing" {
  write_complete_env
  printf '%s\n' 'MUSO_DEV_ADMIN_PASSWORD=' >> "$ENV_FILE"

  run_check

  [ "$status" -eq 0 ]
  [ "$output" = 'MUSO_DEV_ADMIN_PASSWORD' ]
}

# bats test_tags=host-systemd
@test "invalid runtime values are reported with their required values" {
  write_complete_env
  printf '%s\n' \
    'MUSO_ENV=dev' \
    'MUSO_NONINTERACTIVE=' \
    'MUSO_STATE_DIR=/tmp/muso' >> "$ENV_FILE"

  run_check

  [ "$status" -eq 0 ]
  [ "$output" = $'MUSO_ENV=prod\nMUSO_NONINTERACTIVE=1\nMUSO_STATE_DIR=/var/log/muso-ops' ]
}

@test "systemd-run failure is preserved for the deploy warning path" {
  write_complete_env
  printf '%s\n' '#!/usr/bin/env bash' 'exit 42' > "$TEST_TMPDIR/systemd-run-fail"
  chmod +x "$TEST_TMPDIR/systemd-run-fail"

  run env MUSO_SYSTEMD_RUN_BIN="$TEST_TMPDIR/systemd-run-fail" \
    bash -c 'source "$1"; muso_main_env_missing "$2"' _ "$LIB" "$ENV_FILE"

  [ "$status" -eq 42 ]
}

# bats test_tags=host-systemd
@test "report: complete env produces no output lines" {
  write_complete_env

  run bash -c 'source "$1"; muso_main_env_report "$2"' _ "$LIB" "$ENV_FILE"

  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# bats test_tags=host-systemd
@test "report: missing vars produce actionable WARN lines" {
  write_complete_env
  printf '%s\n' 'MUSO_DEV_ADMIN_PASSWORD=' >> "$ENV_FILE"

  run bash -c 'source "$1"; muso_main_env_report "$2"' _ "$LIB" "$ENV_FILE"

  [ "$status" -eq 0 ]
  [[ "$output" == *"WARN: $ENV_FILE is missing: MUSO_DEV_ADMIN_PASSWORD"* ]]
  [[ "$output" == *"WARN: ops agent admin API"* ]]
}

@test "report: systemd-run unavailable is informational, not a missing-var claim" {
  write_complete_env
  printf '%s\n' '#!/usr/bin/env bash' 'exit 42' > "$TEST_TMPDIR/systemd-run-fail"
  chmod +x "$TEST_TMPDIR/systemd-run-fail"

  run env MUSO_SYSTEMD_RUN_BIN="$TEST_TMPDIR/systemd-run-fail" \
    bash -c 'source "$1"; muso_main_env_report "$2"' _ "$LIB" "$ENV_FILE"

  [ "$status" -eq 0 ]
  [ "$output" = "INFO: skipped main.env validation (env check could not run in this context)" ]
  [[ "$output" != *"WARN"* ]]
  [[ "$output" != *"is missing"* ]]
}

@test "report: survives export -f into a child shell (the deploy.sh POSTSYNC boundary)" {
  # deploy.sh sources the lib in the PARENT shell but calls muso_main_env_report
  # inside a `bash << 'POSTSYNC'` CHILD process. Without exporting the function
  # (and its dependency) the call command-not-founds in the child and the check
  # silently no-ops. Simulate the exact pattern: source in a parent, export -f,
  # then invoke inside a nested child bash.
  write_complete_env
  printf '%s\n' '#!/usr/bin/env bash' 'exit 42' > "$TEST_TMPDIR/systemd-run-fail"
  chmod +x "$TEST_TMPDIR/systemd-run-fail"

  run env MUSO_SYSTEMD_RUN_BIN="$TEST_TMPDIR/systemd-run-fail" bash -c '
    source "$1"
    export -f muso_main_env_report muso_main_env_missing
    bash -c "muso_main_env_report \"\$1\"" _ "$2"
  ' _ "$LIB" "$ENV_FILE"

  [ "$status" -eq 0 ]
  [ "$output" = "INFO: skipped main.env validation (env check could not run in this context)" ]
}

@test "deploy.sh exports muso_main_env_report + muso_main_env_missing into POSTSYNC" {
  # Regression guard: the main.env validation runs inside deploy.sh's POSTSYNC
  # child shell, so both functions MUST appear on an `export -f` line before the
  # heredoc, or the call command-not-founds and validation silently no-ops.
  local exports
  exports="$(grep '^export -f ' "$HYDRA_REPO/scripts/deploy.sh")"
  [[ "$exports" == *muso_main_env_report* ]]
  [[ "$exports" == *muso_main_env_missing* ]]
}
