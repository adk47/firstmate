#!/usr/bin/env bats
#
# refresh-dedupe-cache.sh precomputes the ~50s NocoDB dedup snapshot out-of-band
# so prep-batch reads it in <1s. WHY these cases matter (Rule 10): a cache that
# is written PARTIAL on a source outage, or overwrites a good cache with a bad
# one, would silently defeat dedupe — so the refresher must write a complete,
# fresh, well-shaped cache on success and must NOT touch the cache on failure.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  SUT="$REPO_ROOT/scripts/company-finder/refresh-dedupe-cache.sh"
  export USE_MUSO_CLI=0   # wrapper path; muso path covered by nocodb-muso-seam.bats
  export NOCODB_API_SH="$BATS_TEST_DIRNAME/stubs/nocodb-api.sh"
  export NOCODB_STUB_FIXTURES="$BATS_TEST_DIRNAME/fixtures"
  export COMPANY_TABLE_ID="mvr6nmzcv7albxt"
  export CONTACTS_TABLE_ID="m9vsbijhrr9ddeu"
  export LEDGER_TABLE_ID="ledgertable001"
  export DEDUPE_CACHE_FILE="$BATS_TEST_TMPDIR/dedupe-cache.json"
}

@test "writes a fresh, well-shaped cache covering all three sources" {
  run bash "$SUT"
  [ "$status" -eq 0 ]
  [ -f "$DEDUPE_CACHE_FILE" ]
  # generated_at_epoch is a recent integer
  gen="$(jq -r '.generated_at_epoch' "$DEDUPE_CACHE_FILE")"
  [[ "$gen" =~ ^[0-9]+$ ]]
  [ "$(( $(date +%s) - gen ))" -lt 120 ]
  # count matches the existing[] length, and existing carries all three tables
  [ "$(jq '.count == (.existing | length)' "$DEDUPE_CACHE_FILE")" = "true" ]
  [ "$(jq '.existing | length > 0' "$DEDUPE_CACHE_FILE")" = "true" ]
  [ "$(jq -r '[.existing[].table] | unique | sort | join(",")' "$DEDUPE_CACHE_FILE")" \
      = "Company Intelligence,Contacts Intelligence,Seen Ledger" ]
  # a known fixture domain is present with the dedup {domain,name,table} shape
  [ "$(jq -r '[.existing[] | select(.domain=="landr.com")] | length' "$DEDUPE_CACHE_FILE")" -ge 1 ]
}

@test "the written cache is consumable by dedupe (round-trip)" {
  run bash "$SUT"
  [ "$status" -eq 0 ]
  # A candidate matching a cached domain is dropped when dedupe reads THIS cache,
  # with live rigged to fail — proving the produced cache is a valid dedupe input.
  export NOCODB_STUB_FAIL="mvr6nmzcv7albxt"
  run bash "$REPO_ROOT/scripts/company-finder/dedupe-candidates.sh" <<<'[{"name":"Landr","domain":"landr.com"}]'
  [ "$status" -eq 0 ]
  [ "$(jq -r '.stats.new' <<<"$output")" = "0" ]
  [ "$(jq -r '.duplicates[0].reason' <<<"$output")" = "domain" ]
}

@test "fail-closed: a source outage exits 2 and does NOT overwrite the cache" {
  # Seed a known-good prior cache, then break a required source.
  printf '%s' '{"generated_at_epoch":111,"count":1,"existing":[{"domain":"prior.com","name":"Prior","table":"Seen Ledger"}]}' \
    > "$DEDUPE_CACHE_FILE"
  export NOCODB_STUB_FAIL="mvr6nmzcv7albxt"
  run bash "$SUT"
  [ "$status" -eq 2 ]
  # The prior cache is untouched (no partial overwrite, no stray tmp left behind).
  [ "$(jq -r '.existing[0].domain' "$DEDUPE_CACHE_FILE")" = "prior.com" ]
  [ "$(jq -r '.generated_at_epoch' "$DEDUPE_CACHE_FILE")" = "111" ]
  # no stray tmp file left behind
  [ -z "$(ls "$BATS_TEST_TMPDIR"/dedupe-cache.json.* 2>/dev/null)" ]
}

@test "a large snapshot (~6k rows) is written without an argv overflow" {
  # The real 3-table snapshot is ~300KB — passing EXISTING via --argjson would
  # die "jq: Argument list too long" (MAX_ARG_STRLEN 128KB), the exact trap
  # dedupe reads EXISTING via stdin to avoid. Force it: 2000 rows * 3 tables.
  export NOCODB_STUB_TOTAL_ROWS=2000
  run bash "$SUT"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.count' "$DEDUPE_CACHE_FILE")" -eq 6000 ]
  [ "$(jq '.count == (.existing | length)' "$DEDUPE_CACHE_FILE")" = "true" ]
}

@test "--help exits 0" {
  run bash "$SUT" --help
  [ "$status" -eq 0 ]
}
