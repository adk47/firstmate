#!/usr/bin/env bats
bats_require_minimum_version 1.5.0
load helpers

# Tests for lib/fraud-muso-only-lookup.sh — the fail-soft batched Trino lookup
# behind the muso_only fraud factor.
#
# Regression anchor (2026-06-11): the rp CTE referenced `profile_id` directly
# on matvw_catalog_profile, but that table's ID column is `_id` (`profile_id`
# came from the saved query's dropped `mp` claiming CTE, joined
# ON profile_id=_id). Live Trino rejected the query on EVERY production run
# ("Column 'profile_id' cannot be resolved") and the helper fail-softed to
# available:false — the fraud scorer ran without the muso_only factor since
# shadow went live. The stubbed-CSV tests never caught it because no test
# asserted on the GENERATED SQL. These do.
#
# Stubbing strategy: TRINO_QUERY_SH points at a fake that dumps the SQL it
# receives on stdin to $TEST_TMPDIR/sql.txt, so tests can assert on the query
# text without a cluster. No network, no kubectl.

LOOKUP="$SCRIPTS_DIR/lib/fraud-muso-only-lookup.sh"
P1="11111111-1111-1111-1111-111111111111"
P2="22222222-2222-2222-2222-222222222222"

setup() {
  setup_tmp_env
  [[ -f "$LOOKUP" ]] || { echo "LOOKUP missing: $LOOKUP" >&2; return 1; }

  export SQL_DUMP="$TEST_TMPDIR/sql.txt"

  # Healthy stub: capture SQL, emit one saved-query-shaped CSV row for P1.
  # 80.5, not 80.0: jq 1.6 re-serializes 80.0 as "80" while 1.7 keeps "80.0",
  # so a trailing-.0 value makes the happy-path assertion jq-version-dependent.
  export TRINO_OK="$TEST_TMPDIR/trino-ok.sh"
  cat > "$TRINO_OK" <<STUB
#!/usr/bin/env bash
cat > "$SQL_DUMP"
printf '"%s","80.5"\n' "$P1"
exit 0
STUB
  chmod +x "$TRINO_OK"

  # Healthy-empty stub: capture SQL, zero rows (the COMMON clean case).
  export TRINO_EMPTY="$TEST_TMPDIR/trino-empty.sh"
  cat > "$TRINO_EMPTY" <<STUB
#!/usr/bin/env bash
cat > "$SQL_DUMP"
exit 0
STUB
  chmod +x "$TRINO_EMPTY"

  # Failing stub: the live failure shape — rc=1 with the error on stderr.
  export TRINO_FAIL="$TEST_TMPDIR/trino-fail.sh"
  cat > "$TRINO_FAIL" <<'STUB'
#!/usr/bin/env bash
cat >/dev/null
echo "Query 20260611_040201 failed: line 7:9: Column 'profile_id' cannot be resolved" >&2
exit 1
STUB
  chmod +x "$TRINO_FAIL"
}
teardown() { teardown_tmp_env; }

# ────────────────── generated SQL (the 2026-06-11 regression) ──────────────────

@test "SQL: rp CTE filters matvw_catalog_profile on _id, not profile_id" {
  run --separate-stderr env TRINO_QUERY_SH="$TRINO_OK" "$LOOKUP" "$P1,$P2"
  [ "$status" -eq 0 ]
  [[ -s "$SQL_DUMP" ]]
  # "and _id in" — anchored so it can't substring-match the buggy
  # "and profile_id in" form.
  grep -q "and _id in ('$P1','$P2')" "$SQL_DUMP"
  # The buggy form must never come back: a bare profile_id IN-filter against
  # matvw_catalog_profile (where the column is _id). `run !` (bats >=1.5), not
  # bare `! grep`: bash ignores a failed `!`-negated command unless it is the
  # test's last line, so the bare form silently stops guarding if another
  # assertion is ever appended below it.
  run ! grep -qE "and profile_id in \(" "$SQL_DUMP"
}

@test "SQL: rp CTE aliases _id as profile_id for the downstream joins" {
  run --separate-stderr env TRINO_QUERY_SH="$TRINO_OK" "$LOOKUP" "$P1"
  [ "$status" -eq 0 ]
  grep -q "_id as profile_id" "$SQL_DUMP"
}

# ────────────────────────── output contract guards ──────────────────────────

@test "happy path: CSV row parses into available:true data map" {
  run --separate-stderr env TRINO_QUERY_SH="$TRINO_OK" "$LOOKUP" "$P1"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.available')" = "true" ]
  [ "$(printf '%s' "$output" | jq -r --arg p "$P1" '.data[$p]')" = "80.5" ]
}

@test "healthy zero-row result stays available:true with empty data" {
  run --separate-stderr env TRINO_QUERY_SH="$TRINO_EMPTY" "$LOOKUP" "$P1"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -c '.')" = '{"available":true,"data":{}}' ]
}

@test "trino failure: available:false, exit 0, and trino's own stderr is surfaced" {
  run --separate-stderr env TRINO_QUERY_SH="$TRINO_FAIL" "$LOOKUP" "$P1"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.available')" = "false" ]
  # The fail-soft diagnostic must carry the underlying trino error, not just
  # "exited rc=1" — swallowing it is how the column bug stayed invisible.
  [[ "$stderr" == *"UNAVAILABLE this run"* ]]
  [[ "$stderr" == *"Column 'profile_id' cannot be resolved"* ]]
}
