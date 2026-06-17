#!/usr/bin/env bats
#
# migrate-normalize-domains.sh brings stored Domain values up to the same
# normal form the dedup/write scripts use. These tests pin the safety
# properties: dry-run never writes, collisions are NEVER auto-merged (CRM
# data would be lost), and --check is a usable drift auditor.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  SUT="$REPO_ROOT/scripts/company-finder/migrate-normalize-domains.sh"
  export USE_MUSO_CLI=0   # pin the legacy wrapper path; the muso path is covered by nocodb-muso-seam.bats
  export NOCODB_API_SH="$BATS_TEST_DIRNAME/stubs/nocodb-api.sh"
  export NOCODB_STUB_FIXTURES="$BATS_TEST_DIRNAME/fixtures"
  export NOCODB_STUB_LOG="$BATS_TEST_TMPDIR/stub.log"
  # dirtytable001.json: full URL, "(updated)" annotation, a collision pair
  # (landr.com + https://landr.com/), an empty domain, one clean row.
  DIRTY_TABLE="dirtytable001"
}

log_lines() { wc -l <"$NOCODB_STUB_LOG" 2>/dev/null || echo 0; }

@test "dry-run reports changes, collisions and skipped rows — and writes NOTHING" {
  run bash "$SUT" --table "$DIRTY_TABLE"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.stats.rows' <<<"$output")" = "6" ]
  # imbschool (URL) + apogee (annotation) change; the landr pair is a
  # collision (excluded from changes); clean.example and the empty row don't.
  [ "$(jq -r '.stats.changes' <<<"$output")" = "2" ]
  [ "$(jq -r '[.changes[].to] | sort | join(",")' <<<"$output")" = "apogeedigital.com,imbschool.eu" ]
  [ "$(jq -r '.stats.collisions' <<<"$output")" = "1" ]
  [ "$(jq -r '.collisions[0].domain' <<<"$output")" = "landr.com" ]
  [ "$(jq -r '.collisions[0].rows | length' <<<"$output")" = "2" ]
  [ "$(jq -r '.skipped_empty' <<<"$output")" = "1" ]
  [ "$(log_lines)" -eq 0 ]
}

@test "dry-run preserves the original value in 'from' so nothing is silently lost" {
  run bash "$SUT" --table "$DIRTY_TABLE"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.changes[] | select(.to == "apogeedigital.com") | .from' <<<"$output")" = "apogeedigital.com (updated)" ]
}

@test "--apply updates ONLY the changed, non-collision rows" {
  run bash "$SUT" --table "$DIRTY_TABLE" --apply
  [ "$status" -eq 0 ]
  [ "$(log_lines)" -eq 1 ]
  patch=$(sed "s/^records.update $DIRTY_TABLE //" "$NOCODB_STUB_LOG")
  [ "$(jq 'length' <<<"$patch")" = "2" ]
  [ "$(jq -r 'map(.Domain) | sort | join(",")' <<<"$patch")" = "apogeedigital.com,imbschool.eu" ]
  # the collision pair (Ids 3,4) and the empty/clean rows are untouched
  [ "$(jq -r 'map(.Id) | sort | join(",")' <<<"$patch")" = "1,2" ]
}

@test "--check exits 1 on a dirty table (drift auditor)" {
  run bash "$SUT" --table "$DIRTY_TABLE" --check
  [ "$status" -eq 1 ]
}

@test "--check exits 0 on a clean table" {
  cat >"$BATS_TEST_TMPDIR/cleantable001.json" <<'EOF'
{ "list": [ { "Id": 1, "Domain": "clean.example", "Company Name": "Clean" } ],
  "pageInfo": { "isLastPage": true } }
EOF
  export NOCODB_STUB_FIXTURES="$BATS_TEST_TMPDIR"
  run bash "$SUT" --table "cleantable001" --check
  [ "$status" -eq 0 ]
}

@test "source unavailable exits 2" {
  export NOCODB_STUB_FAIL="$DIRTY_TABLE"
  run bash "$SUT" --table "$DIRTY_TABLE"
  [ "$status" -eq 2 ]
  [[ "$output" == *"MIGRATION_SOURCE_UNAVAILABLE"* ]]
}

@test "unknown flag is a usage error" {
  run bash "$SUT" --frobnicate
  [ "$status" -eq 1 ]
}
