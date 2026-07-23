#!/usr/bin/env bats
#
# category-saturation.sh is a READ-ONLY report over the same two sources
# dedupe already trusts (Seen Ledger + Company Intelligence). These tests pin
# the aggregation math (per-category counts must be exact — a McLaren-facing
# "is this category mined out?" call is worthless if the numbers are off) and
# the fail-closed source-unavailable path (mirrors prep-batch.sh/
# finalize-batch.sh's fail_json envelope).

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  SUT="$REPO_ROOT/scripts/company-finder/category-saturation.sh"
  export USE_MUSO_CLI=0   # pin the legacy wrapper path; the muso path is covered by nocodb-muso-seam.bats
  export NOCODB_API_SH="$BATS_TEST_DIRNAME/stubs/nocodb-api.sh"
  export COMPANY_TABLE_ID="mvr6nmzcv7albxt"
  export LEDGER_TABLE_ID="ledgertable001"

  # ── Enriched fixtures (Vertical/Status/Industry) ──────────────────────────
  # The repo-committed company.json/ledger.json fixtures (shared with
  # dedupe-candidates.bats etc.) carry no Vertical/Industry data. Rather than
  # edit those shared fixtures (risking the other suites) or fight the stub's
  # tid-keyed case statement (which hardcodes company.json/ledger.json for
  # COMPANY_TABLE_ID/LEDGER_TABLE_ID regardless of the id's value), point
  # NOCODB_STUB_FIXTURES at a private per-test copy and overwrite just those
  # two files there — least invasive, zero risk to other suites.
  mkdir -p "$BATS_TEST_TMPDIR/fixtures"
  cp "$BATS_TEST_DIRNAME"/fixtures/*.json "$BATS_TEST_TMPDIR/fixtures/" 2>/dev/null || true
  export NOCODB_STUB_FIXTURES="$BATS_TEST_TMPDIR/fixtures"

  cat >"$NOCODB_STUB_FIXTURES/ledger.json" <<'EOF'
{ "list": [
  { "Vertical": "Music Education", "Status": "rejected" },
  { "Vertical": "Music Education", "Status": "rejected" },
  { "Vertical": "music education  ", "Status": "suggested" },
  { "Vertical": "Live Event", "Status": "approved" },
  { "Vertical": "  Live Event", "Status": "rejected" },
  { "Vertical": "", "Status": "suggested" },
  { "Vertical": "Audio Software", "Status": "approved" }
], "pageInfo": { "isLastPage": true } }
EOF
  cat >"$NOCODB_STUB_FIXTURES/company.json" <<'EOF'
{ "list": [
  { "Industry": "Music Education" },
  { "Industry": "MUSIC EDUCATION" },
  { "Industry": "Live Event" },
  { "Industry": "" },
  { "Industry": "New Category" }
], "pageInfo": { "isLastPage": true } }
EOF
}

cat_row() { # <json> <category> -> the category object, or "null"
  jq -c --arg c "$2" '.categories[] | select(.category == $c)' <<<"$1"
}

@test "--json: exact per-category counts and totals from known fixtures" {
  run bash "$SUT" --json
  [ "$status" -eq 0 ]
  [ "$(jq -r '.totals.companies_in_crm' <<<"$output")" = "5" ]
  [ "$(jq -r '.totals.ledger_rows' <<<"$output")" = "7" ]

  edu="$(cat_row "$output" "music education")"
  [ "$(jq -r '.in_crm' <<<"$edu")" = "2" ]
  [ "$(jq -r '.ever_suggested' <<<"$edu")" = "3" ]
  [ "$(jq -r '.rejected' <<<"$edu")" = "2" ]
  [ "$(jq -r '.approved' <<<"$edu")" = "0" ]
  [ "$(jq -r '.pending' <<<"$edu")" = "1" ]

  live="$(cat_row "$output" "live event")"
  [ "$(jq -r '.in_crm' <<<"$live")" = "1" ]
  [ "$(jq -r '.ever_suggested' <<<"$live")" = "2" ]
  [ "$(jq -r '.rejected' <<<"$live")" = "1" ]
  [ "$(jq -r '.approved' <<<"$live")" = "1" ]
  [ "$(jq -r '.pending' <<<"$live")" = "0" ]

  # a category only ever suggested (never in CRM) still surfaces, in_crm=0
  audio="$(cat_row "$output" "audio software")"
  [ "$(jq -r '.in_crm' <<<"$audio")" = "0" ]
  [ "$(jq -r '.ever_suggested' <<<"$audio")" = "1" ]
  [ "$(jq -r '.approved' <<<"$audio")" = "1" ]

  # a category only in the CRM (never suggested) still surfaces, ledger counts=0
  newcat="$(cat_row "$output" "new category")"
  [ "$(jq -r '.in_crm' <<<"$newcat")" = "1" ]
  [ "$(jq -r '.ever_suggested' <<<"$newcat")" = "0" ]
}

@test "case/whitespace category-name variants merge into one bucket" {
  run bash "$SUT" --json
  [ "$status" -eq 0 ]
  # "Music Education" / "music education  " (ledger) and "Music Education" /
  # "MUSIC EDUCATION" (CRM) must collapse to ONE row, not four.
  [ "$(jq -r '[.categories[] | select(.category == "music education")] | length' <<<"$output")" = "1" ]
  # "Live Event" / "  Live Event" (leading-space variant) likewise merge.
  [ "$(jq -r '[.categories[] | select(.category == "live event")] | length' <<<"$output")" = "1" ]
}

@test "empty category buckets as (uncategorized)" {
  run bash "$SUT" --json
  [ "$status" -eq 0 ]
  uncat="$(cat_row "$output" "(uncategorized)")"
  [ "$(jq -r '.in_crm' <<<"$uncat")" = "1" ]
  [ "$(jq -r '.ever_suggested' <<<"$uncat")" = "1" ]
  [ "$(jq -r '.pending' <<<"$uncat")" = "1" ]
}

@test "default (human table) output includes the category names and a totals footer" {
  run bash "$SUT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"music education"* ]]
  [[ "$output" == *"live event"* ]]
  [[ "$output" == *"total companies in CRM: 5"* ]]
  [[ "$output" == *"total ledger rows: 7"* ]]
}

@test "ledger source unavailable -> exit 2 + SATURATION_SOURCE_UNAVAILABLE envelope on stdout" {
  export NOCODB_STUB_FAIL="$LEDGER_TABLE_ID"
  run bash "$SUT" --json
  [ "$status" -eq 2 ]
  [[ "$output" == *"SATURATION_SOURCE_UNAVAILABLE"* ]]
  [[ "$output" == *'"error":"SATURATION_SOURCE_UNAVAILABLE"'* ]]
  [[ "$output" == *'"exit":2'* ]]
}

@test "Company Intelligence source unavailable -> exit 2 + envelope" {
  export NOCODB_STUB_FAIL="$COMPANY_TABLE_ID"
  run bash "$SUT" --json
  [ "$status" -eq 2 ]
  [[ "$output" == *"SATURATION_SOURCE_UNAVAILABLE"* ]]
}

@test "--help exits 0" {
  run bash "$SUT" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"category-saturation.sh"* ]]
}
