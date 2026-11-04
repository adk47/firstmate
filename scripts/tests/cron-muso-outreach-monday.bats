#!/usr/bin/env bats
# Tests for cron-muso-outreach-monday.sh: the Monday cron must load
# NOCODB_API_TOKEN from the openclaw env files before it calls the worker.
# Live gap (MUS-27591): the cron exported only GOG_KEYRING_PASSWORD, so every
# NocoDB-keyed draft raised at lookup and ended SEND_FAILED_RETRIED.
#
# Hermetic: temp OPENCLAW_ENV_DIR, temp GOG password file, temp lockfile and
# a stub worker that reports only whether the token is SET (never its value).
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
SCRIPT="$HYDRA_REPO/scripts/cron-muso-outreach-monday.sh"

setup() {
  ENVDIR="$BATS_TEST_TMPDIR/env"
  mkdir -p "$ENVDIR"
  echo "pw" > "$BATS_TEST_TMPDIR/gogpw"
  cat > "$BATS_TEST_TMPDIR/worker.sh" <<'W'
#!/bin/bash
if [[ -n "${NOCODB_API_TOKEN:-}" ]]; then echo "STUB token=set"; else echo "STUB token=unset"; fi
W
  chmod +x "$BATS_TEST_TMPDIR/worker.sh"
  export OPENCLAW_ENV_DIR="$ENVDIR"
  export GOG_PW_FILE="$BATS_TEST_TMPDIR/gogpw"
  export MUSO_OUTREACH_WORKER="$BATS_TEST_TMPDIR/worker.sh"
  export LOCKFILE="$BATS_TEST_TMPDIR/lock"
  unset NOCODB_API_TOKEN
}

@test "token only in main.env reaches the worker" {
  echo "FOO=bar" > "$ENVDIR/shared.env"
  echo "NOCODB_API_TOKEN=s3cret-value" > "$ENVDIR/main.env"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"STUB token=set"* ]]
  [[ "$output" != *"s3cret-value"* ]]
}

@test "no token anywhere: exit 2, FATAL line, worker never runs" {
  echo "FOO=bar" > "$ENVDIR/shared.env"
  echo "BAZ=1" > "$ENVDIR/main.env"
  run bash "$SCRIPT"
  [ "$status" -eq 2 ]
  [[ "$output" == *"FATAL: NOCODB_API_TOKEN empty after loading $ENVDIR/{shared,main}.env"* ]]
  [[ "$output" != *"STUB"* ]]
}

@test "shared.env missing, main.env has the token: still OK" {
  echo "NOCODB_API_TOKEN=abc" > "$ENVDIR/main.env"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"STUB token=set"* ]]
}

@test "token check runs before the GOG check" {
  rm -f "$GOG_PW_FILE"
  run bash "$SCRIPT"
  [ "$status" -eq 2 ]
  [[ "$output" == *"NOCODB_API_TOKEN empty"* ]]
}

@test "lib returns 2 instead of exiting the sourcing shell" {
  run bash -c ". '$HYDRA_REPO/scripts/lib/muso-outreach-env.sh'; muso_outreach_load_env; echo \"rc=\$?\""
  [[ "$output" == *"rc=2"* ]]
}
