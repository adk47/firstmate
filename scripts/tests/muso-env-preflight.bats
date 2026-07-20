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

run_check() {
  run bash -c 'source "$1"; muso_main_env_missing "$2"' _ "$LIB" "$ENV_FILE"
}

@test "systemd quoting and last duplicate assignment produce a valid environment" {
  write_complete_env

  run_check

  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "an empty final assignment is reported as missing" {
  write_complete_env
  printf '%s\n' 'MUSO_DEV_ADMIN_PASSWORD=' >> "$ENV_FILE"

  run_check

  [ "$status" -eq 0 ]
  [ "$output" = 'MUSO_DEV_ADMIN_PASSWORD' ]
}

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
