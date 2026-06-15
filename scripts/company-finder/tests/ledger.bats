#!/usr/bin/env bats
#
# ledger.sh is the ONLY sanctioned write path for the Company Seen Ledger and
# Company Intelligence. These tests pin the two properties that make it the
# de-facto unique constraint (NocoDB Cloud has none): every write is
# normalized, and a collision fails the WHOLE batch atomically — because a
# collision means dedupe was skipped or raced, and papering over it is how
# duplicates ship.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  SUT="$REPO_ROOT/scripts/company-finder/ledger.sh"
  export NOCODB_API_SH="$BATS_TEST_DIRNAME/stubs/nocodb-api.sh"
  export NOCODB_STUB_FIXTURES="$BATS_TEST_DIRNAME/fixtures"
  export NOCODB_STUB_LOG="$BATS_TEST_TMPDIR/stub.log"
  export COMPANY_TABLE_ID="mvr6nmzcv7albxt"
  export CONTACTS_TABLE_ID="m9vsbijhrr9ddeu"
  export LEDGER_TABLE_ID="ledgertable001"
  export TODAY="2026-06-11"
}

log_lines() { wc -l <"$NOCODB_STUB_LOG" 2>/dev/null || echo 0; }

# ── suggest ──────────────────────────────────────────────────────────────────

@test "suggest writes the NORMALIZED domain, suggested status and date" {
  run bash "$SUT" suggest <<<'[{"name":"Foo Co","domain":"https://www.Foo.com/","vertical":"Music Education"}]'
  [ "$status" -eq 0 ]
  [ "$(jq -r '.stats.recorded' <<<"$output")" = "1" ]
  [ "$(jq -r '.recorded[0].domain' <<<"$output")" = "foo.com" ]
  grep -q "records.create ledgertable001" "$NOCODB_STUB_LOG"
  created=$(grep "records.create" "$NOCODB_STUB_LOG" | sed 's/^records.create ledgertable001 //')
  [ "$(jq -r '.[0].Domain' <<<"$created")" = "foo.com" ]
  [ "$(jq -r '.[0].Status' <<<"$created")" = "suggested" ]
  [ "$(jq -r '.[0]["Suggested At"]' <<<"$created")" = "2026-06-11" ]
  [ "$(jq -r '.[0].Vertical' <<<"$created")" = "Music Education" ]
}

@test "suggest collision with a Seen Ledger row fails atomically — nothing written" {
  run bash "$SUT" suggest <<<'[
    {"name":"Brand New","domain":"brandnew.example"},
    {"name":"DeadCorp","domain":"https://deadcorp.example"}
  ]'
  [ "$status" -eq 3 ]
  [[ "$output" == *"LEDGER_COLLISION: deadcorp.example (in Seen Ledger)"* ]]
  [ "$(log_lines)" -eq 0 ]
}

@test "suggest collision with a Company Intelligence row fails atomically" {
  run bash "$SUT" suggest <<<'[{"name":"LANDR","domain":"https://www.landr.com/"}]'
  [ "$status" -eq 3 ]
  [[ "$output" == *"LEDGER_COLLISION: landr.com (in Company Intelligence)"* ]]
  [ "$(log_lines)" -eq 0 ]
}

@test "suggest collision with a Contacts Intelligence row fails atomically" {
  # Contacts is a dedupe source; omitting it here would let a contacts-only
  # domain be suggested and later approved into a cross-table duplicate.
  run bash "$SUT" suggest <<<'[{"name":"Splice","domain":"https://splice.com/"}]'
  [ "$status" -eq 3 ]
  [[ "$output" == *"LEDGER_COLLISION: splice.com (in Contacts Intelligence)"* ]]
  [ "$(log_lines)" -eq 0 ]
}

@test "suggest rejects a domain with hostname-invalid characters (would break downstream lookups)" {
  run bash "$SUT" suggest <<<'[{"name":"Multi","domain":"landr.com, landr.io"}]'
  [ "$status" -eq 1 ]
  [[ "$output" == *"empty/invalid domain"* ]]
  [ "$(log_lines)" -eq 0 ]
}

@test "suggest rejects input-internal duplicate domains (dedupe was skipped)" {
  run bash "$SUT" suggest <<<'[
    {"name":"Foo","domain":"foo.example"},
    {"name":"Foo Inc","domain":"https://foo.example/"}
  ]'
  [ "$status" -eq 1 ]
  [[ "$output" == *"input-internal duplicate"* ]]
  [ "$(log_lines)" -eq 0 ]
}

@test "suggest rejects an empty/invalid domain" {
  run bash "$SUT" suggest <<<'[{"name":"NoDomain","domain":""}]'
  [ "$status" -eq 1 ]
  [[ "$output" == *"empty/invalid domain"* ]]
}

@test "suggest with an empty array is a no-op success" {
  run bash "$SUT" suggest <<<'[]'
  [ "$status" -eq 0 ]
  [ "$(jq -r '.stats.recorded' <<<"$output")" = "0" ]
  [ "$(log_lines)" -eq 0 ]
}

@test "suggest with the ledger source unavailable exits 2 (never writes blind)" {
  export NOCODB_STUB_FAIL="$LEDGER_TABLE_ID"
  run bash "$SUT" suggest <<<'[{"name":"Foo","domain":"foo.example"}]'
  [ "$status" -eq 2 ]
  [[ "$output" == *"LEDGER_SOURCE_UNAVAILABLE: Seen Ledger"* ]]
  [ "$(log_lines)" -eq 0 ]
}

# ── record-rejects ───────────────────────────────────────────────────────────

@test "record-rejects writes rejected rows with reason and both date stamps" {
  run bash "$SUT" record-rejects <<<'[{"name":"Dead Co","domain":"https://www.deadsite.example/","reason":"DEAD","vertical":"Music Education"}]'
  [ "$status" -eq 0 ]
  [ "$(jq -r '.stats.recorded' <<<"$output")" = "1" ]
  created=$(grep "records.create ledgertable001" "$NOCODB_STUB_LOG" | sed 's/^records.create ledgertable001 //')
  [ "$(jq -r '.[0].Domain' <<<"$created")" = "deadsite.example" ]
  [ "$(jq -r '.[0].Status' <<<"$created")" = "rejected" ]
  [ "$(jq -r '.[0]["Reject Reason"]' <<<"$created")" = "DEAD" ]
  [ "$(jq -r '.[0]["Decided At"]' <<<"$created")" = "2026-06-11" ]
}

@test "record-rejects SKIPS already-known domains instead of failing (idempotent)" {
  # deadcorp.example is already rejected in the ledger fixture; landr.com is
  # in Company Intelligence. Neither blocks recording the genuinely-new one.
  run bash "$SUT" record-rejects <<<'[
    {"name":"DeadCorp","domain":"deadcorp.example","reason":"DEAD"},
    {"name":"LANDR","domain":"landr.com","reason":"IN_GHL"},
    {"name":"Fresh Dead","domain":"freshdead.example","reason":"NO_LINKEDIN"}
  ]'
  [ "$status" -eq 0 ]
  [ "$(jq -r '.stats.recorded' <<<"$output")" = "1" ]
  [ "$(jq -r '.stats.skipped_existing' <<<"$output")" = "2" ]
  created=$(grep "records.create ledgertable001" "$NOCODB_STUB_LOG" | sed 's/^records.create ledgertable001 //')
  [ "$(jq 'length' <<<"$created")" = "1" ]
  [ "$(jq -r '.[0].Domain' <<<"$created")" = "freshdead.example" ]
}

@test "record-rejects reports invalid domains as skipped, not a crash" {
  run bash "$SUT" record-rejects <<<'[{"name":"Garbage","domain":"landr.com, landr.io","reason":"DEAD"}]'
  [ "$status" -eq 0 ]
  [ "$(jq -r '.stats.skipped_invalid' <<<"$output")" = "1" ]
  [ "$(jq -r '.stats.recorded' <<<"$output")" = "0" ]
  [ "$(log_lines)" -eq 0 ]
}

@test "record-rejects requires a reason on every row" {
  run bash "$SUT" record-rejects <<<'[{"name":"NoWhy","domain":"nowhy.example"}]'
  [ "$status" -eq 1 ]
  [[ "$output" == *"without a reason"* ]]
  [ "$(log_lines)" -eq 0 ]
}

# ── reject ───────────────────────────────────────────────────────────────────

@test "reject flips the row to rejected with reason and Decided At" {
  run bash "$SUT" reject "https://www.pendingco.example/" "no LinkedIn page"
  [ "$status" -eq 0 ]
  grep -q "records.update ledgertable001" "$NOCODB_STUB_LOG"
  patch=$(grep "records.update" "$NOCODB_STUB_LOG" | sed 's/^records.update ledgertable001 //')
  [ "$(jq -r '.[0].Id' <<<"$patch")" = "22" ]
  [ "$(jq -r '.[0].Status' <<<"$patch")" = "rejected" ]
  [ "$(jq -r '.[0]["Reject Reason"]' <<<"$patch")" = "no LinkedIn page" ]
  [ "$(jq -r '.[0]["Decided At"]' <<<"$patch")" = "2026-06-11" ]
}

@test "reject of a domain not in the ledger exits 3 LEDGER_ROW_NOT_FOUND" {
  run bash "$SUT" reject "nosuchco.example" "dead"
  [ "$status" -eq 3 ]
  [[ "$output" == *"LEDGER_ROW_NOT_FOUND: nosuchco.example"* ]]
}

@test "reject without a reason is a usage error" {
  run bash "$SUT" reject "pendingco.example"
  [ "$status" -eq 1 ]
}

# ── approve ──────────────────────────────────────────────────────────────────

@test "approve creates the Company Intelligence row THEN flips the ledger row" {
  run bash "$SUT" approve "pendingco.example" --industry "Music Education"
  [ "$status" -eq 0 ]
  [ "$(log_lines)" -eq 2 ]
  ci=$(sed -n '1p' "$NOCODB_STUB_LOG")
  [[ "$ci" == "records.create mvr6nmzcv7albxt "* ]]
  ci_body="${ci#records.create mvr6nmzcv7albxt }"
  [ "$(jq -r '.Domain' <<<"$ci_body")" = "pendingco.example" ]
  [ "$(jq -r '."Company Name"' <<<"$ci_body")" = "PendingCo" ]
  [ "$(jq -r '.Status' <<<"$ci_body")" = "Needs Enrichment" ]
  [ "$(jq -r '.Industry' <<<"$ci_body")" = "Music Education" ]
  flip=$(sed -n '2p' "$NOCODB_STUB_LOG")
  [[ "$flip" == "records.update ledgertable001 "* ]]
  [ "$(jq -r '.[0].Status' <<<"${flip#records.update ledgertable001 }")" = "approved" ]
}

@test "approve retry after a half-completed run flips only (CI row already there, ledger still suggested)" {
  # Fixture state: pendingco.example is 'suggested' in the ledger. Simulate the
  # CI row already existing by approving a domain that IS in company.json AND
  # in the ledger as suggested — use a custom fixture pair via the generic stub.
  cat >"$BATS_TEST_TMPDIR/halfdone-ledger.json" <<'EOF'
{ "list": [ { "Id": 31, "Domain": "landr.com", "Company Name": "LANDR", "Status": "suggested" } ],
  "pageInfo": { "isLastPage": true } }
EOF
  mkdir -p "$BATS_TEST_TMPDIR/fixtures"
  cp "$NOCODB_STUB_FIXTURES/company.json" "$BATS_TEST_TMPDIR/fixtures/company.json"
  cp "$NOCODB_STUB_FIXTURES/contacts.json" "$BATS_TEST_TMPDIR/fixtures/contacts.json"
  cp "$BATS_TEST_TMPDIR/halfdone-ledger.json" "$BATS_TEST_TMPDIR/fixtures/ledger.json"
  export NOCODB_STUB_FIXTURES="$BATS_TEST_TMPDIR/fixtures"

  run bash "$SUT" approve "landr.com"
  [ "$status" -eq 0 ]
  [ "$(log_lines)" -eq 1 ]
  flip=$(sed -n '1p' "$NOCODB_STUB_LOG")
  [[ "$flip" == "records.update ledgertable001 "* ]]
  [ "$(jq -r '.[0].Id' <<<"${flip#records.update ledgertable001 }")" = "31" ]
  [ "$(jq -r '.[0].Status' <<<"${flip#records.update ledgertable001 }")" = "approved" ]
}

@test "approve re-checks Contacts Intelligence at insert time (suggest-to-approve race)" {
  # A domain can land in Contacts AFTER suggest but BEFORE the (human-gated)
  # approve — inserting it into Company Intelligence anyway would recreate
  # the cross-table duplicate class this script exists to prevent.
  mkdir -p "$BATS_TEST_TMPDIR/fixtures"
  cp "$NOCODB_STUB_FIXTURES"/*.json "$BATS_TEST_TMPDIR/fixtures/"
  cat >"$BATS_TEST_TMPDIR/fixtures/contacts.json" <<'EOF'
{ "list": [ { "Id": 11, "Domain": "splice.com", "Company Name": "Splice" },
            { "Id": 12, "Domain": "https://www.pendingco.example/", "Company Name": "PendingCo Contact" } ],
  "pageInfo": { "isLastPage": true } }
EOF
  export NOCODB_STUB_FIXTURES="$BATS_TEST_TMPDIR/fixtures"

  run bash "$SUT" approve "pendingco.example"
  [ "$status" -eq 3 ]
  [[ "$output" == *"LEDGER_COLLISION: pendingco.example (in Contacts Intelligence)"* ]]
  [ "$(log_lines)" -eq 0 ]
}

@test "approve when CI has the domain and the ledger row is NOT suggested is a collision" {
  cat >"$BATS_TEST_TMPDIR/approved-ledger.json" <<'EOF'
{ "list": [ { "Id": 31, "Domain": "landr.com", "Company Name": "LANDR", "Status": "approved" } ],
  "pageInfo": { "isLastPage": true } }
EOF
  mkdir -p "$BATS_TEST_TMPDIR/fixtures"
  cp "$NOCODB_STUB_FIXTURES/company.json" "$BATS_TEST_TMPDIR/fixtures/company.json"
  cp "$NOCODB_STUB_FIXTURES/contacts.json" "$BATS_TEST_TMPDIR/fixtures/contacts.json"
  cp "$BATS_TEST_TMPDIR/approved-ledger.json" "$BATS_TEST_TMPDIR/fixtures/ledger.json"
  export NOCODB_STUB_FIXTURES="$BATS_TEST_TMPDIR/fixtures"

  run bash "$SUT" approve "landr.com"
  [ "$status" -eq 3 ]
  [[ "$output" == *"LEDGER_COLLISION: landr.com (in Company Intelligence)"* ]]
  [ "$(log_lines)" -eq 0 ]
}

# ── guard rails ──────────────────────────────────────────────────────────────

@test "an unset LEDGER_TABLE_ID fails as a required-source-unavailable (exit 2 + marker)" {
  unset LEDGER_TABLE_ID
  run bash "$SUT" suggest <<<'[{"name":"Foo","domain":"foo.example"}]'
  [ "$status" -eq 2 ]
  [[ "$output" == *"LEDGER_SOURCE_UNAVAILABLE: Seen Ledger"* ]]
  [[ "$output" == *"LEDGER_TABLE_ID"* ]]
}

@test "approve with --industry missing its value is a loud usage error" {
  run bash "$SUT" approve "pendingco.example" --industry
  [ "$status" -eq 1 ]
  [[ "$output" == *"--industry needs a value"* ]]
  [ "$(log_lines)" -eq 0 ]
}

@test "non-array stdin to suggest is rejected" {
  run bash "$SUT" suggest <<<'{"not":"an array"}'
  [ "$status" -eq 1 ]
}

# ── large snapshot / argv overflow (the jq E2BIG class) ───────────────────────
#
# Rule 10 — WHY: every suggest/record-rejects prechecks the FULL Seen Ledger +
# Company Intelligence + Contacts Intelligence snapshot. Those three are handed
# to jq SEPARATELY (one arg per table); a single argv string is capped at
# MAX_ARG_STRLEN (128KB). When one table (Contacts Intelligence, in prod) grew
# past that cap the precheck died "jq: Argument list too long" (exit 126) and
# EVERY ledger write failed closed — the outage that took the daily
# company-finder cron down on 2026-06-13. Snapshots must go off argv
# (slurpfile/stdin), never --argjson.
#
# This needs a higher row count than the dedupe twin: dedupe overflows on a
# single COMBINED arg, ledger must push ONE table past 128KB on its own. The
# stub serves NOCODB_STUB_TOTAL_ROWS synthetic rows per table; at ~50B/mapped
# row, 4000 rows ≈ 200KB/arg — comfortably over the cap, and would NOT have
# tripped at dedupe's 2000 (~100KB).

@test "suggest survives a snapshot too large for argv (was: jq Argument list too long)" {
  export NOCODB_STUB_TOTAL_ROWS=4000
  export NOCODB_PAGE_SLEEP=0   # local stub — don't pace the 40 pages/table fetch
  run bash "$SUT" suggest <<<'[{"name":"Bigsnap","domain":"bigsnap.example"}]'
  [[ "$output" != *"Argument list too long"* ]]
  [ "$status" -eq 0 ]
  [ "$(jq -r '.stats.recorded' <<<"$output")" = "1" ]
  [ "$(jq -r '.recorded[0].domain' <<<"$output")" = "bigsnap.example" ]
  grep -q "records.create ledgertable001" "$NOCODB_STUB_LOG"
}

@test "record-rejects survives a snapshot too large for argv (was: jq Argument list too long)" {
  export NOCODB_STUB_TOTAL_ROWS=4000
  export NOCODB_PAGE_SLEEP=0   # local stub — don't pace the 40 pages/table fetch
  run bash "$SUT" record-rejects <<<'[{"name":"Bigsnap","domain":"bigsnap.example","reason":"DEAD"}]'
  [[ "$output" != *"Argument list too long"* ]]
  [ "$status" -eq 0 ]
  [ "$(jq -r '.stats.recorded' <<<"$output")" = "1" ]
  [ "$(jq -r '.recorded[0].domain' <<<"$output")" = "bigsnap.example" ]
}
