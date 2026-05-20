#!/usr/bin/env bats

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  NORM="$REPO_ROOT/scripts/dedup/lib/normalize-profile.sh"
  FIX="$REPO_ROOT/scripts/dedup/tests/fixtures"
}

@test "normalize: wrapped admin API response maps to canonical fields" {
  run bash "$NORM" "$FIX/admin_api_profile_response.json"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.id')" = "d9840461-d027-42ed-8252-77fadbf35153" ]
  [ "$(echo "$output" | jq -r '.name')" = "Ali Zain" ]
  [ "$(echo "$output" | jq -r '.legal_name')" = "Ali Zain Hussain" ]
  [ "$(echo "$output" | jq -r '.credit_count')" = "38" ]
  [ "$(echo "$output" | jq -r '.ipis | length')" = "1" ]
  [ "$(echo "$output" | jq -r '.ipis[0]')" = "123456789" ]
  [ "$(echo "$output" | jq -r '.raw_ids | length')" = "2" ]
  [ "$(echo "$output" | jq -r '.raw_ids[0]')" = "spotify:abc123" ]
  [ "$(echo "$output" | jq -r '.raw_ids[1]')" = "tidal:xyz" ]
  [ "$(echo "$output" | jq -r '.claim.status')" = "processed" ]
}
