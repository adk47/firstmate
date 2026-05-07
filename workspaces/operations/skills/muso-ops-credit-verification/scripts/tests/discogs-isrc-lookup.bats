#!/usr/bin/env bats
bats_require_minimum_version 1.5.0
load helpers
# Tests for discogs-isrc-lookup.sh — Phase C of credit-verification redesign.
#
# Stubbing: we shadow `curl` via the DISCOGS_CURL env var (the script honors
# it). Each test writes a small bash script that emulates curl's exit code,
# body, and HTTP code. This keeps tests hermetic — no live Discogs traffic —
# and lets us drive every branch (HIT, MISS, 401, 503, network error,
# role-synonym, case insensitivity, multi-role-same-artist).
#
# The script makes TWO sequential curl calls when search hits: first
# `database/search?q=<isrc>` then `releases/<id>`. Stubs read STUB_SEARCH_BODY
# / STUB_DETAIL_BODY and pick which to emit based on the URL substring.
#
# PATH-shadow `openclaw` per feedback_bats_must_stub_openclaw — even though
# this script never calls openclaw, the suite-wide convention keeps test
# tools off the live Slack workspace if anything in setup() ever shells out.

setup() {
  setup_tmp_env
  SCRIPT="$SCRIPTS_DIR/discogs-isrc-lookup.sh"
  [[ -x "$SCRIPT" ]] || { echo "discogs-isrc-lookup.sh missing or not executable: $SCRIPT" >&2; return 1; }

  STUB_DIR="$TEST_TMPDIR/stub"
  mkdir -p "$STUB_DIR"
  STUB_CURL="$STUB_DIR/curl"

  # Skip the 1.1s rate-limit sleep — tests don't want it.
  cat > "$STUB_DIR/sleep" <<'NOSLEEP'
#!/usr/bin/env bash
exit 0
NOSLEEP
  chmod +x "$STUB_DIR/sleep"

  # Defense-in-depth: PATH-shadow openclaw so any accidental shell-out stays
  # local (per feedback_bats_must_stub_openclaw — Clio's PR #245 fired alerts
  # to prod #credit-verification on 2026-05-06).
  cat > "$STUB_DIR/openclaw" <<'OPENCLAW_STUB'
#!/usr/bin/env bash
echo "openclaw stub — discogs test should not need this" >&2
exit 1
OPENCLAW_STUB
  chmod +x "$STUB_DIR/openclaw"

  export PATH="$STUB_DIR:$PATH"
  export DISCOGS_TOKEN="test-token-xxxxxxxxxxxxxxxxxxxx"
  export STUB_SEARCH_BODY="$TEST_TMPDIR/search.json"
  export STUB_SEARCH_CODE="$TEST_TMPDIR/search.code"
  export STUB_DETAIL_BODY="$TEST_TMPDIR/detail.json"
  export STUB_DETAIL_CODE="$TEST_TMPDIR/detail.code"
  export STUB_SEARCH_EXIT="$TEST_TMPDIR/search.exit"

  # Default exit codes / HTTP codes = success.
  printf '0' > "$STUB_SEARCH_EXIT"
  printf '200' > "$STUB_SEARCH_CODE"
  printf '200' > "$STUB_DETAIL_CODE"

  cat > "$STUB_CURL" <<'STUB'
#!/usr/bin/env bash
# Stub curl. Discogs invocation matches the MB shape:
#   curl --max-time 15 -sS -A <ua> -H 'Authorization: Discogs token=...' \
#        -H 'Accept: ...' -o <body_file> -w '%{http_code}' <url>

body_file=""
url=""
prev=""
for arg in "$@"; do
  if [[ "$prev" == "-o" ]]; then body_file="$arg"; fi
  url="$arg"
  prev="$arg"
done

if [[ "$url" == *"/database/search"* ]]; then
  exit_code=$(cat "${STUB_SEARCH_EXIT:-/dev/null}" 2>/dev/null || echo 0)
  if [[ "$exit_code" != "0" ]]; then
    echo "curl: stubbed network failure" >&2
    exit "$exit_code"
  fi
  body=$(cat "$STUB_SEARCH_BODY" 2>/dev/null || echo '{}')
  code=$(cat "$STUB_SEARCH_CODE" 2>/dev/null || echo 200)
elif [[ "$url" == *"/releases/"* ]]; then
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
  export DISCOGS_CURL="$STUB_CURL"
}

teardown() { teardown_tmp_env; }

# ---------- helpers ---------------------------------------------------------

write_search_hit() {
  local rid="$1"
  cat > "$STUB_SEARCH_BODY" <<EOF
{"pagination":{"items":1},"results":[{"id":$rid,"type":"release","title":"Some Artist - Some Release"}]}
EOF
}

write_search_miss() {
  printf '%s' '{"pagination":{"items":0},"results":[]}' > "$STUB_SEARCH_BODY"
}

# ---------- HIT with rich credits ------------------------------------------

@test "HIT: rich credits — name_match + role_match true, excerpt populated" {
  write_search_hit 1234567
  cat > "$STUB_DETAIL_BODY" <<'JSON'
{
  "id":1234567,
  "title":"Yellow Submarine",
  "artists":[{"name":"The Beatles"}],
  "year":1969,
  "labels":[{"name":"Apple Records"}],
  "extraartists":[
    {"name":"Bram Fidder","role":"Mastered By"},
    {"name":"George Martin","role":"Producer"}
  ],
  "tracklist":[
    {"position":"A1","title":"Yellow Submarine","extraartists":[]}
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
  echo "$output" | jq -e '.evidence_excerpt | test("Discogs"; "i")'
  echo "$output" | jq -e '.error == null'
}

# ---------- HIT but credit not present -------------------------------------

@test "HIT but no matching personnel — found=true, name_match=false" {
  write_search_hit 9999999
  cat > "$STUB_DETAIL_BODY" <<'JSON'
{
  "id":9999999,
  "title":"Lonely Track",
  "artists":[{"name":"Other Artist"}],
  "year":2020,
  "labels":[{"name":"Some Label"}],
  "extraartists":[],
  "tracklist":[]
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

@test "MISS: pagination.items=0 → found=false, exit 1" {
  write_search_miss
  run bash "$SCRIPT" "USXX9999999" --credited-name "Anyone"
  [ "$status" -eq 1 ]
  echo "$output" | jq -e '.found == false'
  echo "$output" | jq -e '.release == null'
  echo "$output" | jq -e '.error == null'
}

# ---------- AUTH FAILURE ---------------------------------------------------

@test "HTTP 401 on search → exit 2 with auth error" {
  write_search_miss
  printf '401' > "$STUB_SEARCH_CODE"
  run bash "$SCRIPT" "USXX0040100" --credited-name "X"
  [ "$status" -eq 2 ]
  echo "$output" | jq -e '.found == false'
  echo "$output" | jq -e '.error | test("auth")'
}

# ---------- RATE LIMIT -----------------------------------------------------

@test "HTTP 429 on search → exit 2 with rate-limit error" {
  write_search_miss
  printf '429' > "$STUB_SEARCH_CODE"
  run bash "$SCRIPT" "USXX0042900" --credited-name "X"
  [ "$status" -eq 2 ]
  echo "$output" | jq -e '.error | test("429")'
}

# ---------- NETWORK ERROR --------------------------------------------------

@test "curl non-zero exit → exit 2 with error" {
  write_search_miss
  printf '7' > "$STUB_SEARCH_EXIT"
  run --separate-stderr bash "$SCRIPT" "USXX0007777" --credited-name "X"
  [ "$status" -eq 2 ]
  echo "$output" | jq -e '.error | test("curl exit 7")'
}

# ---------- ROLE SYNONYM ---------------------------------------------------

@test "Discogs role 'Mixed By' matches claimed role 'Mixing' (synonym)" {
  write_search_hit 3333333
  cat > "$STUB_DETAIL_BODY" <<'JSON'
{
  "id":3333333,
  "title":"Mixed Track",
  "artists":[{"name":"Some Artist"}],
  "year":2021,
  "labels":[{"name":"Indie"}],
  "extraartists":[
    {"name":"Bram Fidder","role":"Mixed By"}
  ],
  "tracklist":[]
}
JSON
  run bash "$SCRIPT" "USXX3333333" --credited-name "Bram Fidder" --role "Mixing"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.name_match == true'
  echo "$output" | jq -e '.role_match == true'
}

# ---------- TRACK-LEVEL CREDITS ------------------------------------------

@test "tracklist[].extraartists is searched alongside release-level credits" {
  write_search_hit 4444444
  cat > "$STUB_DETAIL_BODY" <<'JSON'
{
  "id":4444444,
  "title":"Album X",
  "artists":[{"name":"Main Artist"}],
  "year":2022,
  "labels":[{"name":"Label X"}],
  "extraartists":[],
  "tracklist":[
    {"position":"A1","title":"Track 1","extraartists":[
      {"name":"Bram Fidder","role":"Producer"}
    ]}
  ]
}
JSON
  run bash "$SCRIPT" "USXX4444444" --credited-name "Bram Fidder" --role "Producer"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.name_match == true'
  echo "$output" | jq -e '.role_match == true'
}

# ---------- MULTI-ROLE SAME-PERSON ----------------------------------------

@test "same person credited in two roles — gate finds the right one" {
  # Spec: matched_name slot first, then full scan. If the agent claims
  # 'Mastering' but the person is credited as both 'Mastered By' and
  # 'Producer', the gate should still flip role_match=true even if the
  # 'Producer' row is encountered first.
  write_search_hit 5555555
  cat > "$STUB_DETAIL_BODY" <<'JSON'
{
  "id":5555555,
  "title":"Multi-Role Album",
  "artists":[{"name":"Main"}],
  "year":2023,
  "labels":[{"name":"Lab"}],
  "extraartists":[
    {"name":"Bram Fidder","role":"Producer"},
    {"name":"Bram Fidder","role":"Mastered By"}
  ],
  "tracklist":[]
}
JSON
  run bash "$SCRIPT" "USXX5555555" --credited-name "Bram Fidder" --role "Mastering"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.name_match == true'
  echo "$output" | jq -e '.role_match == true'
}

# ---------- CASE INSENSITIVE NAME ------------------------------------------

@test "credited_name 'BRAM FIDDER' matches credit 'Bram Fidder' (case insensitive)" {
  write_search_hit 6666666
  cat > "$STUB_DETAIL_BODY" <<'JSON'
{
  "id":6666666,
  "title":"Case Track",
  "artists":[{"name":"Other"}],
  "year":2024,
  "labels":[{"name":"L"}],
  "extraartists":[
    {"name":"Bram Fidder","role":"Producer"}
  ],
  "tracklist":[]
}
JSON
  run bash "$SCRIPT" "USXX6666666" --credited-name "BRAM FIDDER" --role "Producer"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.name_match == true'
  echo "$output" | jq -e '.role_match == true'
}

# ---------- CREDS MISSING --------------------------------------------------

@test "DISCOGS_TOKEN unset → exit 4 with creds error" {
  unset DISCOGS_TOKEN
  run bash "$SCRIPT" "USXX0000004"
  [ "$status" -eq 4 ]
  echo "$output" | jq -e '.error | test("DISCOGS_TOKEN")'
}

# ---------- USAGE ERROR ----------------------------------------------------

@test "missing ISRC arg → exit 3" {
  run --separate-stderr bash "$SCRIPT"
  [ "$status" -eq 3 ]
  [[ "$stderr" == *"ISRC"* ]]
}
