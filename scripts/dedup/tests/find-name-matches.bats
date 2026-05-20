#!/usr/bin/env bats

# find-name-matches.sh: given a name string, return Muso profile UUIDs that
# match (case-insensitive) in matvw_catalog_profile. Exit 4 if Trino fails.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  NM="$REPO_ROOT/scripts/dedup/lib/find-name-matches.sh"
  TMP=$(mktemp -d)
}

teardown() {
  rm -rf "$TMP"
}

make_trino_stub_ok() {
  # Stub that responds based on what the SQL string actually contains, so
  # tests can assert on case-folding, quote-escaping, and limit-passing
  # without poking at stderr (the production script captures stderr into a
  # tempfile, so it never reaches the test harness's `run` output).
  cat > "$TMP/trino-stub.sh" <<'EOF'
#!/usr/bin/env bash
sql="${1:-}"
if echo "$sql" | grep -q "lower(name) = 'ali zain'"; then
  echo '"09a8ad7f-00a5-44b1-9f06-d698bc8c79b7","Ali Zain","0"'
  echo '"d9840461-d027-42ed-8252-77fadbf35153","Ali Zain","39"'
  echo '"a43f3621-c295-4723-821b-d17007d63b41","ALI ZAIN","1"'
  exit 0
fi
if echo "$sql" | grep -q "lower(name) = 'o''reilly'"; then
  echo '"oreilly-uuid","O'"'"'Reilly","2"'
  exit 0
fi
# Echo back a row indicating what filter was applied (used by limit tests).
limit=$(echo "$sql" | grep -o 'LIMIT [0-9]*' | head -1)
echo "\"saw-limit-$limit\",\"X\",\"0\""
EOF
  chmod +x "$TMP/trino-stub.sh"
}

make_trino_stub_empty() {
  cat > "$TMP/trino-stub.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$TMP/trino-stub.sh"
}

make_trino_stub_fail() {
  cat > "$TMP/trino-stub.sh" <<'EOF'
#!/usr/bin/env bash
echo "stub: forced trino failure" >&2
exit 1
EOF
  chmod +x "$TMP/trino-stub.sh"
}

@test "find-name-matches emits one UUID per match line" {
  make_trino_stub_ok
  TRINO_QUERY="$TMP/trino-stub.sh" run bash "$NM" "Ali Zain"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "^09a8ad7f-00a5-44b1-9f06-d698bc8c79b7$"
  echo "$output" | grep -q "^d9840461-d027-42ed-8252-77fadbf35153$"
  echo "$output" | grep -q "^a43f3621-c295-4723-821b-d17007d63b41$"
  [ "$(echo "$output" | wc -l | tr -d ' ')" -eq 3 ]
}

@test "find-name-matches lowercases the search term for case-insensitive match" {
  make_trino_stub_ok
  # Pass UPPER-CASE input. If the script normalizes correctly, the stub sees
  # lower(name) = 'ali zain' and returns the canned Ali Zain rows. If it
  # forgot to lowercase, the stub falls through to the limit-debug row.
  TRINO_QUERY="$TMP/trino-stub.sh" run bash "$NM" "ALI ZAIN"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "^d9840461-d027-42ed-8252-77fadbf35153$"
  ! echo "$output" | grep -q "saw-limit"
}

@test "find-name-matches refuses empty name" {
  make_trino_stub_ok
  TRINO_QUERY="$TMP/trino-stub.sh" run bash "$NM" ""
  [ "$status" -ne 0 ]
  echo "$output" | grep -qi "name.*required\|empty"
}

@test "find-name-matches escapes single-quote in name to prevent SQL injection" {
  make_trino_stub_ok
  # Stub recognizes the doubled-quote form 'o''reilly' only. If the script
  # forgot to escape, the SQL would be malformed and the stub fallthrough row
  # would be returned instead.
  TRINO_QUERY="$TMP/trino-stub.sh" run bash "$NM" "O'Reilly"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "^oreilly-uuid$"
}

@test "find-name-matches exits 4 when Trino fails" {
  make_trino_stub_fail
  TRINO_QUERY="$TMP/trino-stub.sh" run bash "$NM" "Ali Zain"
  [ "$status" -eq 4 ]
  echo "$output" | grep -qi "trino.*fail\|trino.*error"
}

@test "find-name-matches exits 0 with empty stdout on no matches" {
  make_trino_stub_empty
  TRINO_QUERY="$TMP/trino-stub.sh" run bash "$NM" "Nonexistent Artist 99999"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "find-name-matches respects --limit flag" {
  make_trino_stub_ok
  # Use a name that hits the stub's fallthrough so we can read back the
  # LIMIT value the script asked for.
  TRINO_QUERY="$TMP/trino-stub.sh" run bash "$NM" "Unrecognized Name" --limit 5
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "^saw-limit-LIMIT 5$"
}

@test "find-name-matches rejects non-numeric --limit" {
  make_trino_stub_ok
  TRINO_QUERY="$TMP/trino-stub.sh" run bash "$NM" "Ali Zain" --limit abc
  [ "$status" -ne 0 ]
  echo "$output" | grep -qi "limit.*number\|integer"
}
