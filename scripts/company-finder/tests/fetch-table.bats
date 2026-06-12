#!/usr/bin/env bats
#
# fetch_table is the read side of every dedupe decision: if it silently
# returns a partial snapshot, dedupe passes duplicates downstream (the
# 2026-06-12 CMO incident: NocoDB Cloud clamps --limit to 100, the script
# asked for 1000, treated the clamped short page as the last page, and
# deduped against ~5% of Company Intelligence). These tests pin that a
# server-side clamp below PAGE_LIMIT can never truncate the snapshot.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  export NOCODB_API_SH="$BATS_TEST_DIRNAME/stubs/nocodb-api.sh"
  export NOCODB_STUB_FIXTURES="$BATS_TEST_DIRNAME/fixtures"
}

# Source common.sh and run fetch_table in a clean subshell so PAGE_LIMIT
# defaulting at source-time is exercised per-test.
fetch() { # <totalRows> [env VAR=VAL ...]
  local total="$1"; shift
  env NOCODB_STUB_TOTAL_ROWS="$total" "$@" bash -c '
    set -euo pipefail
    source "$0"
    fetch_table sometable "Some Table" "Id" SRC_UNAVAILABLE
  ' "$REPO_ROOT/scripts/company-finder/lib/common.sh"
}

@test "server clamp below PAGE_LIMIT still yields the FULL table (the CMO bug)" {
  run fetch 250 PAGE_LIMIT=1000 NOCODB_STUB_CLAMP=100
  [ "$status" -eq 0 ]
  [ "$(jq 'length' <<<"$output")" = "250" ]
  # No row lost or duplicated across page boundaries.
  [ "$(jq 'map(.Id) | unique | length' <<<"$output")" = "250" ]
}

@test "default PAGE_LIMIT fetches a >100-row table completely" {
  run fetch 250
  [ "$status" -eq 0 ]
  [ "$(jq 'length' <<<"$output")" = "250" ]
}

@test "row count an exact multiple of the page size terminates (no extra page hang)" {
  run fetch 200 PAGE_LIMIT=100
  [ "$status" -eq 0 ]
  [ "$(jq 'length' <<<"$output")" = "200" ]
}

@test "empty table returns []" {
  run fetch 0
  [ "$status" -eq 0 ]
  [ "$(jq -c '.' <<<"$output")" = "[]" ]
}

@test "unavailable source still exits 2 with the caller's marker" {
  run env NOCODB_STUB_FAIL=sometable bash -c '
    set -euo pipefail
    source "$0"
    fetch_table sometable "Some Table" "Id" SRC_UNAVAILABLE
  ' "$REPO_ROOT/scripts/company-finder/lib/common.sh"
  [ "$status" -eq 2 ]
  [[ "$output" == *"SRC_UNAVAILABLE: Some Table (sometable)"* ]]
}
