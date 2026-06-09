#!/usr/bin/env bats
#
# Encodes WHY each rule matters (Rule 10): the Company Finder must present only
# companies genuinely absent from NocoDB. These cases pin the two failure modes
# that leaked duplicates at 44-66% (2026-06-08/09): brittle exact-domain
# matching and skipped per-candidate checks. The dedup is now one deterministic,
# format-robust call.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  SUT="$REPO_ROOT/scripts/company-finder/dedupe-candidates.sh"
  export NOCODB_API_SH="$BATS_TEST_DIRNAME/stubs/nocodb-api.sh"
  export NOCODB_STUB_FIXTURES="$BATS_TEST_DIRNAME/fixtures"
  # Keep table ids aligned with the stub's case labels (also the script defaults).
  export COMPANY_TABLE_ID="mvr6nmzcv7albxt"
  export CONTACTS_TABLE_ID="m9vsbijhrr9ddeu"
}

run_dedupe() { run bash "$SUT" <<<"$1"; }

@test "exact-domain match is dropped" {
  run_dedupe '[{"name":"Landr","domain":"landr.com"}]'
  [ "$status" -eq 0 ]
  [ "$(jq -r '.stats.new' <<<"$output")" = "0" ]
  [ "$(jq -r '.duplicates[0].reason' <<<"$output")" = "domain" ]
}

@test "format-variant domain (scheme/www/case/slash) is dropped — the core regression" {
  run_dedupe '[{"name":"AudioShake","domain":"https://www.AudioShake.ai/"}]'
  [ "$status" -eq 0 ]
  [ "$(jq -r '.stats.new' <<<"$output")" = "0" ]
  [ "$(jq -r '.duplicates[0].reason' <<<"$output")" = "domain" ]
  [ "$(jq -r '.duplicates[0].matched_against.table' <<<"$output")" = "Company Intelligence" ]
}

@test "dirty stored domain with a trailing annotation still matches a clean candidate" {
  # Real NocoDB data contains values like "apogeedigital.com (updated)" — the old
  # exact (Domain,eq,...) check could never match these; normalization must.
  run_dedupe '[{"name":"Apogee","domain":"https://apogeedigital.com"}]'
  [ "$status" -eq 0 ]
  [ "$(jq -r '.stats.new' <<<"$output")" = "0" ]
  [ "$(jq -r '.duplicates[0].reason' <<<"$output")" = "domain" ]
}

@test "same company under a different domain is caught by normalized name" {
  run_dedupe '[{"name":"iZotope","domain":"izotope.io"}]'
  [ "$status" -eq 0 ]
  [ "$(jq -r '.stats.new' <<<"$output")" = "0" ]
  [ "$(jq -r '.duplicates[0].reason' <<<"$output")" = "name" ]
}

@test "a hit only in the Contacts table is still dropped" {
  run_dedupe '[{"name":"Splice","domain":"splice.com"}]'
  [ "$status" -eq 0 ]
  [ "$(jq -r '.duplicates[0].reason' <<<"$output")" = "domain" ]
  [ "$(jq -r '.duplicates[0].matched_against.table' <<<"$output")" = "Contacts Intelligence" ]
}

@test "genuinely-new company passes through with no name flag" {
  run_dedupe '[{"name":"Soundtrap","domain":"soundtrap.com","industry":"Music Software"}]'
  [ "$status" -eq 0 ]
  [ "$(jq -r '.stats.new' <<<"$output")" = "1" ]
  [ "$(jq -r '.new[0].domain' <<<"$output")" = "soundtrap.com" ]
  # extra candidate fields are preserved
  [ "$(jq -r '.new[0].industry' <<<"$output")" = "Music Software" ]
  [ "$(jq -r '.name_flags | length' <<<"$output")" = "0" ]
}

@test "partial-name near-miss is FLAGGED, not dropped (no false suppression)" {
  run_dedupe '[{"name":"Universal Production Music","domain":"upm.example"}]'
  [ "$status" -eq 0 ]
  [ "$(jq -r '.stats.new' <<<"$output")" = "1" ]
  [ "$(jq -r '.name_flags | length' <<<"$output")" = "1" ]
  [ "$(jq -r '.name_flags[0].possible_match.name' <<<"$output")" = "Universal Music Group" ]
}

@test "mixed batch: only the genuinely-new company survives" {
  run_dedupe '[
    {"name":"AudioShake","domain":"https://audioshake.ai"},
    {"name":"Landr","domain":"landr.com"},
    {"name":"Soundtrap","domain":"soundtrap.com"}
  ]'
  [ "$status" -eq 0 ]
  [ "$(jq -r '.stats.checked' <<<"$output")" = "3" ]
  [ "$(jq -r '.stats.dropped' <<<"$output")" = "2" ]
  [ "$(jq -r '.new | length' <<<"$output")" = "1" ]
  [ "$(jq -r '.new[0].name' <<<"$output")" = "Soundtrap" ]
}

@test "empty input yields an empty, well-formed result" {
  run_dedupe '[]'
  [ "$status" -eq 0 ]
  [ "$(jq -r '.stats.checked' <<<"$output")" = "0" ]
  [ "$(jq -r '.new | length' <<<"$output")" = "0" ]
}

@test "a required source unavailable after retry exits non-zero with a named marker" {
  export NOCODB_STUB_FAIL="mvr6nmzcv7albxt"
  run_dedupe '[{"name":"Soundtrap","domain":"soundtrap.com"}]'
  [ "$status" -eq 2 ]
  [[ "$output" == *"DEDUP_SOURCE_UNAVAILABLE: Company Intelligence"* ]]
}

@test "non-array stdin is rejected" {
  run bash "$SUT" <<<'{"not":"an array"}'
  [ "$status" -eq 1 ]
}
