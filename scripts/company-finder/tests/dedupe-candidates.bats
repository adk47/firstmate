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
  export USE_MUSO_CLI=0   # pin the legacy wrapper path; the muso path is covered by nocodb-muso-seam.bats
  export NOCODB_API_SH="$BATS_TEST_DIRNAME/stubs/nocodb-api.sh"
  export NOCODB_STUB_FIXTURES="$BATS_TEST_DIRNAME/fixtures"
  # Keep table ids aligned with the stub's case labels (also the script defaults).
  export COMPANY_TABLE_ID="mvr6nmzcv7albxt"
  export CONTACTS_TABLE_ID="m9vsbijhrr9ddeu"
  export LEDGER_TABLE_ID="ledgertable001"
  # Point the dedupe cache at a per-test path that does not exist, so every test
  # deterministically takes the LIVE (stubbed) path unless it writes a cache.
  export DEDUPE_CACHE_FILE="$BATS_TEST_TMPDIR/dedupe-cache-absent.json"
}

# write_cache <age_seconds> <existing_json> — stamp a cache file aged N seconds.
write_cache() {
  local now; now="$(date +%s)"
  jq -n --argjson t "$(( now - $1 ))" --argjson ex "$2" \
    '{generated_at_epoch: $t, count: ($ex | length), existing: $ex}' > "$DEDUPE_CACHE_FILE"
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

@test "a previously-suggested/rejected company in the Seen Ledger is dropped" {
  # The ledger is what stops rejected companies from resurfacing across days —
  # 26/60 of the 2026-06-10 batch were exactly these.
  run_dedupe '[{"name":"DeadCorp","domain":"https://www.deadcorp.example/"}]'
  [ "$status" -eq 0 ]
  [ "$(jq -r '.stats.new' <<<"$output")" = "0" ]
  [ "$(jq -r '.duplicates[0].reason' <<<"$output")" = "domain" ]
  [ "$(jq -r '.duplicates[0].matched_against.table' <<<"$output")" = "Seen Ledger" ]
}

@test "the Seen Ledger is a REQUIRED source — unavailable means exit 2, not silent skip" {
  export NOCODB_STUB_FAIL="$LEDGER_TABLE_ID"
  run_dedupe '[{"name":"Soundtrap","domain":"soundtrap.com"}]'
  [ "$status" -eq 2 ]
  [[ "$output" == *"DEDUP_SOURCE_UNAVAILABLE: Seen Ledger"* ]]
}

@test "an unset LEDGER_TABLE_ID with no ledger table fails as required-source-unavailable (exit 2 + marker)" {
  # Exit 2 with the DEDUP marker puts the table-missing case in the SAME
  # fail-closed bucket the cron doctrine already instructs for — not an
  # unexplained exit 1 the agent has no instruction for.
  unset LEDGER_TABLE_ID
  run_dedupe '[{"name":"Soundtrap","domain":"soundtrap.com"}]'
  [ "$status" -eq 2 ]
  [[ "$output" == *"DEDUP_SOURCE_UNAVAILABLE: Seen Ledger"* ]]
  [[ "$output" == *"LEDGER_TABLE_ID"* ]]
}

@test "an unset LEDGER_TABLE_ID auto-discovers the ledger by title once the table exists" {
  # Auto-discovery is what makes setup-ledger-table.sh the ONLY operator
  # step post-merge — no pin commit, no redeploy.
  mkdir -p "$BATS_TEST_TMPDIR/fixtures"
  cp "$NOCODB_STUB_FIXTURES"/*.json "$BATS_TEST_TMPDIR/fixtures/"
  cat >"$BATS_TEST_TMPDIR/fixtures/tables.json" <<'EOF'
{ "list": [ { "id": "ledgertable001", "title": "Company Seen Ledger" } ] }
EOF
  export NOCODB_STUB_FIXTURES="$BATS_TEST_TMPDIR/fixtures"
  unset LEDGER_TABLE_ID
  run_dedupe '[{"name":"DeadCorp","domain":"deadcorp.example"}]'
  [ "$status" -eq 0 ]
  [ "$(jq -r '.duplicates[0].matched_against.table' <<<"$output")" = "Seen Ledger" ]
}

@test "a domain with hostname-invalid characters is treated as no-domain, not matched dirty" {
  # norm_domain maps anything outside [a-z0-9.-] to "" — those values would
  # otherwise break NocoDB where-grammar and the verify xargs fan-out
  # downstream. The candidate still passes through (by name) for human eyes.
  run_dedupe '[{"name":"Multi Domain Co","domain":"landr.com, landr.io"}]'
  [ "$status" -eq 0 ]
  [ "$(jq -r '.stats.new' <<<"$output")" = "1" ]
}

@test "within-batch domain duplicate: first occurrence wins, second is dropped as reason=batch" {
  # Per-category subagents are blind to each other; the same company can
  # arrive from two categories in one union batch.
  run_dedupe '[
    {"name":"Soundtrap","domain":"soundtrap.com"},
    {"name":"Soundtrap AB","domain":"https://www.soundtrap.com/"}
  ]'
  [ "$status" -eq 0 ]
  [ "$(jq -r '.new | length' <<<"$output")" = "1" ]
  [ "$(jq -r '.new[0].name' <<<"$output")" = "Soundtrap" ]
  [ "$(jq -r '.duplicates[0].reason' <<<"$output")" = "batch" ]
  [ "$(jq -r '.duplicates[0].matched_against.table' <<<"$output")" = "(this batch)" ]
  [ "$(jq -r '.duplicates[0].matched_against.name' <<<"$output")" = "Soundtrap" ]
}

@test "within-batch name duplicate under a different domain is dropped as reason=batch" {
  run_dedupe '[
    {"name":"Soundtrap","domain":"soundtrap.com"},
    {"name":"Soundtrap","domain":"soundtrap.io"}
  ]'
  [ "$status" -eq 0 ]
  [ "$(jq -r '.new | length' <<<"$output")" = "1" ]
  [ "$(jq -r '.duplicates[0].reason' <<<"$output")" = "batch" ]
  [ "$(jq -r '.stats.dropped' <<<"$output")" = "1" ]
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

@test "a large existing snapshot (~6k rows) classifies without an argv overflow" {
  # The full 3-table snapshot is thousands of rows (~300KB live). A single argv
  # string is capped at MAX_ARG_STRLEN (128KB), so passing EXISTING via
  # --argjson dies "jq: Argument list too long" the moment the read completes —
  # which is exactly what the NocoDB throttling fix made reachable (2026-06-13).
  # The stub serves NOCODB_STUB_TOTAL_ROWS rows per table; 2000*3 = 6000 rows
  # overflows the old argv path and must now go through stdin.
  export NOCODB_STUB_TOTAL_ROWS=2000
  run_dedupe '[{"name":"Soundtrap","domain":"soundtrap.com"}]'
  [ "$status" -eq 0 ]
  [ "$(jq -r '.stats.checked' <<<"$output")" = "1" ]
  [ "$(jq -r '.stats.new' <<<"$output")" = "1" ]
}

# ── Dedupe cache (out-of-band snapshot) ─────────────────────────────────────
# WHY (Rule 10): the cache is a FAST PRE-FILTER that lets prep-batch skip the
# ~50s live 3-table fetch. A fresh cache MUST be used verbatim; a stale/malformed
# one MUST fall back to a live snapshot. Correctness is unaffected either way
# because ledger.sh suggest (finalize) re-checks all sources live — but if the
# cache were trusted when stale, or ignored when fresh, prep-batch would either
# leak a known dup into the batch or pay the ~50s cost it exists to avoid.

@test "a FRESH cache is used and the live sources are never touched" {
  # Cache holds a company absent from the fixtures; live is rigged to FAIL. Using
  # the cache drops the candidate and succeeds with no live fetch; a fallback to
  # live would exit 2.
  write_cache 60 '[{"domain":"cachedco.com","name":"CachedCo","table":"Company Intelligence"}]'
  export NOCODB_STUB_FAIL="mvr6nmzcv7albxt"
  run_dedupe '[{"name":"CachedCo","domain":"https://www.CachedCo.com/"},{"name":"BrandNew","domain":"brandnew.example"}]'
  [ "$status" -eq 0 ]
  [ "$(jq -r '.duplicates[0].reason' <<<"$output")" = "domain" ]
  [ "$(jq -r '.duplicates[0].matched_against.table' <<<"$output")" = "Company Intelligence" ]
  [ "$(jq -r '.stats.new' <<<"$output")" = "1" ]
}

@test "a STALE cache is ignored — falls back to the live snapshot" {
  export DEDUPE_CACHE_TTL_SECONDS=1800
  write_cache 4000 '[{"domain":"staleco.com","name":"StaleCo","table":"Company Intelligence"}]'
  run_dedupe '[{"name":"StaleCo","domain":"staleco.com"},{"name":"Landr","domain":"landr.com"}]'
  [ "$status" -eq 0 ]
  # landr.com is in the LIVE fixtures → dropped (proves the live snapshot was read)
  [ "$(jq -r '[.duplicates[].domain] | index("landr.com") != null' <<<"$output")" = "true" ]
  # staleco.com is ONLY in the stale cache → survives (proves the cache was ignored)
  [ "$(jq -r '[.new[].domain] | index("staleco.com") != null' <<<"$output")" = "true" ]
}

@test "a MALFORMED cache falls back to the live snapshot" {
  printf 'not json at all' > "$DEDUPE_CACHE_FILE"
  run_dedupe '[{"name":"Landr","domain":"landr.com"}]'
  [ "$status" -eq 0 ]
  [ "$(jq -r '.duplicates[0].reason' <<<"$output")" = "domain" ]
}

@test "a FRESH but wrong-TYPE cache (.existing not an array) falls back to live" {
  # Valid JSON, in-TTL, but .existing is an object — must NOT be trusted (a
  # non-array .existing would abort dedupe's map() instead of falling back).
  jq -n --argjson t "$(date +%s)" '{generated_at_epoch: $t, existing: {}}' > "$DEDUPE_CACHE_FILE"
  run_dedupe '[{"name":"Landr","domain":"landr.com"}]'
  [ "$status" -eq 0 ]
  # landr.com is in the LIVE fixtures → dropped, proving the live snapshot was used
  [ "$(jq -r '.duplicates[0].reason' <<<"$output")" = "domain" ]
}

@test "a FRESH array cache with non-object rows falls back to live" {
  # .existing is an array but its elements aren't objects ([1]) — dedupe's
  # map(. + {…}) would abort; must be treated as a cache-miss instead.
  jq -n --argjson t "$(date +%s)" '{generated_at_epoch: $t, existing: [1]}' > "$DEDUPE_CACHE_FILE"
  run_dedupe '[{"name":"Landr","domain":"landr.com"}]'
  [ "$status" -eq 0 ]
  [ "$(jq -r '.duplicates[0].reason' <<<"$output")" = "domain" ]
}
