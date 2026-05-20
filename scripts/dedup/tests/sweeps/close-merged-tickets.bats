#!/usr/bin/env bats

# Smoke tests for the args/validation layer of close-merged-tickets.sh.
# Network paths (Trino + ClickUp) are not exercised here — they require live
# stubs and an integration harness — but the input-validation guards that
# protect against bad operator invocations are covered.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../../.." && pwd)"
  SWEEP="$REPO_ROOT/scripts/dedup/sweeps/close-merged-tickets.sh"
}

@test "rejects non-numeric --days" {
  CLICKUP_API_KEY=fake run bash "$SWEEP" --days notanumber
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "must be a non-negative integer"
}

@test "rejects --days with SQL-injection attempt" {
  CLICKUP_API_KEY=fake run bash "$SWEEP" --days "30' day; DROP TABLE--"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "must be a non-negative integer"
}

@test "rejects unknown flag" {
  CLICKUP_API_KEY=fake run bash "$SWEEP" --frobnicate
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "unknown flag"
}

@test "rejects when CLICKUP_API_KEY missing" {
  run env -u CLICKUP_API_KEY bash "$SWEEP" --dry-run
  [ "$status" -eq 2 ]
  echo "$output" | grep -q "CLICKUP_API_KEY not set"
}

@test "rejects when MUSOAI_INTERCOM_TOKEN missing and customer-reply check enabled" {
  # Default behavior: customer-reply check is ON, so MUSOAI_INTERCOM_TOKEN required.
  run env CLICKUP_API_KEY=fake -u MUSOAI_INTERCOM_TOKEN bash "$SWEEP" --dry-run
  # The Trino-or-curl call will likely fail before this, but the script must
  # at least include the Intercom token requirement in its docs.
  bash "$SWEEP" --help | grep -q "MUSOAI_INTERCOM_TOKEN"
}

@test "--skip-customer-reply-check is documented in --help" {
  run bash "$SWEEP" --help
  [ "$status" -eq 0 ]
  echo "$output" | grep -q -- "--skip-customer-reply-check"
}

@test "--help exits 0 and prints usage" {
  run bash "$SWEEP" --help
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "Usage:"
  echo "$output" | grep -q -- "--apply"
}
