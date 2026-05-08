#!/usr/bin/env bats
bats_require_minimum_version 1.5.0
load helpers
# Tests for musicbrainz-isrc-lookup.sh — Phase C of credit-verification redesign.
#
# Stubbing: we shadow `curl` via the MB_CURL env var (the script honors it).
# Each test writes a small bash script that emulates curl's exit code, body,
# and the trailing `\n__HTTP_CODE__:<code>` sentinel. This keeps tests
# hermetic — no live MusicBrainz traffic — and lets us drive every branch
# (HIT, MISS, 503, network error, role-synonym, case insensitivity).
#
# The script makes TWO sequential curl calls when the search hits. Stubs
# read STUB_FILE_1 / STUB_FILE_2 and pick which to emit based on the
# substring shape of the URL: `?query=isrc:` for #1, `/recording/<mbid>?` for #2.

setup() {
  setup_tmp_env
  SCRIPT="$SCRIPTS_DIR/musicbrainz-isrc-lookup.sh"
  [[ -x "$SCRIPT" ]] || { echo "musicbrainz-isrc-lookup.sh missing or not executable: $SCRIPT" >&2; return 1; }

  STUB_DIR="$TEST_TMPDIR/stub"
  mkdir -p "$STUB_DIR"
  STUB_CURL="$STUB_DIR/curl"

  # Skip the 1.1s rate-limit sleep inside the script — tests don't want it.
  # We do it by PATH-shadowing `sleep` with a no-op too.
  cat > "$STUB_DIR/sleep" <<'NOSLEEP'
#!/usr/bin/env bash
exit 0
NOSLEEP
  chmod +x "$STUB_DIR/sleep"

  export PATH="$STUB_DIR:$PATH"
  export STUB_SEARCH_BODY="$TEST_TMPDIR/search.json"
  export STUB_SEARCH_CODE="$TEST_TMPDIR/search.code"
  export STUB_DETAIL_BODY="$TEST_TMPDIR/detail.json"
  export STUB_DETAIL_CODE="$TEST_TMPDIR/detail.code"
  export STUB_SEARCH_EXIT="$TEST_TMPDIR/search.exit"

  # Default exit codes for both calls = 0 (success). Tests override per-case.
  printf '0' > "$STUB_SEARCH_EXIT"
  printf '200' > "$STUB_SEARCH_CODE"
  printf '200' > "$STUB_DETAIL_CODE"

  # Write the curl stub. It reads the fixture files at call time so each
  # @test can write fixtures BEFORE running and the stub picks them up.
  cat > "$STUB_CURL" <<'STUB'
#!/usr/bin/env bash
# Stub curl. The script invokes us as:
#   curl --max-time 15 -sS -A <ua> -H 'Accept: ...' -o <body_file> -w '%{http_code}' <url>
# We must:
#   1. Pick the right fixture (search vs detail) based on URL shape.
#   2. Write body to the path after `-o`.
#   3. Print the http_code (no newline) on stdout.
#   4. Optionally exit non-zero to simulate network failure.

body_file=""
url=""
prev=""
for arg in "$@"; do
  if [[ "$prev" == "-o" ]]; then body_file="$arg"; fi
  url="$arg"   # last arg ends up being the URL
  prev="$arg"
done

if [[ "$url" == *"?query=isrc:"* ]]; then
  exit_code=$(cat "${STUB_SEARCH_EXIT:-/dev/null}" 2>/dev/null || echo 0)
  if [[ "$exit_code" != "0" ]]; then
    echo "curl: stubbed network failure" >&2
    exit "$exit_code"
  fi
  body=$(cat "$STUB_SEARCH_BODY" 2>/dev/null || echo '{}')
  code=$(cat "$STUB_SEARCH_CODE" 2>/dev/null || echo 200)
elif [[ "$url" == *"/recording/"* ]]; then
  body=$(cat "$STUB_DETAIL_BODY" 2>/dev/null || echo '{}')
  code=$(cat "$STUB_DETAIL_CODE" 2>/dev/null || echo 200)
else
  body='{}'
  code=200
fi

if [[ -n "$body_file" ]]; then
  printf '%s' "$body" > "$body_file"
fi
printf '%s' "$code"
STUB
  chmod +x "$STUB_CURL"
}

teardown() { teardown_tmp_env; }

# ---------- helpers ---------------------------------------------------------

# Write the search response (count + first recording id).
write_search_hit() {
  local mbid="$1"
  cat > "$STUB_SEARCH_BODY" <<EOF
{"count":1,"recordings":[{"id":"$mbid","title":"Some Track"}]}
EOF
}

write_search_miss() {
  printf '%s' '{"count":0,"recordings":[]}' > "$STUB_SEARCH_BODY"
}

# ---------- HIT with rich relations ----------------------------------------

@test "HIT: rich relations — name_match + role_match true, excerpt populated" {
  write_search_hit "11111111-2222-3333-4444-555555555555"
  cat > "$STUB_DETAIL_BODY" <<'JSON'
{
  "id":"11111111-2222-3333-4444-555555555555",
  "title":"Yellow Submarine",
  "artist-credit":[{"name":"The Beatles","artist":{"name":"The Beatles"}}],
  "relations":[
    {"type":"mastering","artist":{"name":"Bram Fidder"}},
    {"type":"producer","artist":{"name":"George Martin"}}
  ]
}
JSON
  run bash "$SCRIPT" "USXX1234567" --credited-name "Bram Fidder" --role "Mastering" --track-title "Yellow Submarine"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.found == true'
  echo "$output" | jq -e '.name_match == true'
  echo "$output" | jq -e '.role_match == true'
  echo "$output" | jq -e '.evidence_excerpt | type == "string"'
  echo "$output" | jq -e '.evidence_excerpt | length >= 8 and length <= 200'
  echo "$output" | jq -e '.evidence_excerpt | test("Bram Fidder"; "i")'
  echo "$output" | jq -e '.error == null'
}

# ---------- HIT but no personnel -------------------------------------------

@test "HIT but no personnel — found=true, name_match=false" {
  write_search_hit "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
  cat > "$STUB_DETAIL_BODY" <<'JSON'
{
  "id":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
  "title":"Lonely Track",
  "artist-credit":[{"name":"Other Artist","artist":{"name":"Other Artist"}}],
  "relations":[]
}
JSON
  run bash "$SCRIPT" "USXX0000001" --credited-name "Bram Fidder" --role "Mastering"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.found == true'
  echo "$output" | jq -e '.name_match == false'
  echo "$output" | jq -e '.role_match == false'
  echo "$output" | jq -e '.evidence_excerpt == null'
}

# ---------- MISS — ISRC unknown --------------------------------------------

@test "MISS: count=0 → found=false, exit 1" {
  write_search_miss
  run bash "$SCRIPT" "USXX9999999" --credited-name "Anyone"
  [ "$status" -eq 1 ]
  echo "$output" | jq -e '.found == false'
  echo "$output" | jq -e '.recordings == []'
  echo "$output" | jq -e '.error == null'
}

# ---------- HTTP 503 --------------------------------------------------------

@test "HTTP 503 on search → exit 2 with error in JSON" {
  write_search_miss
  printf '503' > "$STUB_SEARCH_CODE"
  run bash "$SCRIPT" "USXX5030000" --credited-name "X"
  [ "$status" -eq 2 ]
  echo "$output" | jq -e '.found == false'
  echo "$output" | jq -e '.error | test("503")'
}

# ---------- NETWORK ERROR ---------------------------------------------------

@test "curl non-zero exit → exit 2 with error" {
  write_search_miss
  printf '7' > "$STUB_SEARCH_EXIT"
  # --separate-stderr: the curl stub writes a diagnostic to stderr that
  # would otherwise pollute $output and break the jq parse below.
  run --separate-stderr bash "$SCRIPT" "USXX0007777" --credited-name "X"
  [ "$status" -eq 2 ]
  echo "$output" | jq -e '.error | test("curl exit 7")'
}

# ---------- NAME MATCH BUT WRONG ROLE --------------------------------------

@test "name appears as Producer but claimed role is Mastering → role_match=false" {
  write_search_hit "11111111-2222-3333-4444-555555555555"
  cat > "$STUB_DETAIL_BODY" <<'JSON'
{
  "id":"11111111-2222-3333-4444-555555555555",
  "title":"Some Track",
  "artist-credit":[{"name":"Producer Person","artist":{"name":"Producer Person"}}],
  "relations":[
    {"type":"producer","artist":{"name":"Bram Fidder"}}
  ]
}
JSON
  run bash "$SCRIPT" "USXX2222222" --credited-name "Bram Fidder" --role "Mastering"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.name_match == true'
  echo "$output" | jq -e '.role_match == false'
  # Excerpt still emitted because name matched.
  echo "$output" | jq -e '.evidence_excerpt | type == "string"'
}

# ---------- ROLE SYNONYM ----------------------------------------------------

@test "relation type 'mixed by' matches claimed role 'Mixing' (synonym)" {
  write_search_hit "33333333-4444-5555-6666-777777777777"
  cat > "$STUB_DETAIL_BODY" <<'JSON'
{
  "id":"33333333-4444-5555-6666-777777777777",
  "title":"Mixed Track",
  "artist-credit":[{"name":"Some Artist","artist":{"name":"Some Artist"}}],
  "relations":[
    {"type":"mixed by","artist":{"name":"Bram Fidder"}}
  ]
}
JSON
  run bash "$SCRIPT" "USXX3333333" --credited-name "Bram Fidder" --role "Mixing"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.name_match == true'
  echo "$output" | jq -e '.role_match == true'
}

# ---------- CASE INSENSITIVE NAME ------------------------------------------

@test "credited_name 'BRAM FIDDER' matches relation 'Bram Fidder' (case insensitive)" {
  write_search_hit "44444444-5555-6666-7777-888888888888"
  cat > "$STUB_DETAIL_BODY" <<'JSON'
{
  "id":"44444444-5555-6666-7777-888888888888",
  "title":"Case Track",
  "artist-credit":[{"name":"Other","artist":{"name":"Other"}}],
  "relations":[
    {"type":"producer","artist":{"name":"Bram Fidder"}}
  ]
}
JSON
  run bash "$SCRIPT" "USXX4444444" --credited-name "BRAM FIDDER" --role "Producer"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.name_match == true'
  echo "$output" | jq -e '.role_match == true'
}

# ---------- USAGE ERROR ----------------------------------------------------

@test "missing ISRC arg → exit 3" {
  run --separate-stderr bash "$SCRIPT"
  [ "$status" -eq 3 ]
  [[ "$stderr" == *"ISRC"* ]]
}
