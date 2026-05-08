#!/usr/bin/env bats
bats_require_minimum_version 1.5.0
load helpers
# Tests for spotify-track-lookup.sh — Tier-1 deterministic helper for
# performer-class credit verification via the Spotify Web API.
#
# Stubbing strategy: PATH-shadow `curl` with a stub that dispatches by URL:
#   * `accounts.spotify.com/api/token` → token endpoint
#   * `api.spotify.com/v1/tracks/`     → track endpoint
# Each fixture (body + http_code + optional curl exit) is written to a
# file the stub reads at call time, so each @test can drive every branch.
#
# A call counter file (STUB_TOKEN_CALLS) lets us assert that the cached-
# token test reuses the cache instead of round-tripping /api/token.

setup() {
  setup_tmp_env
  SCRIPT="$SCRIPTS_DIR/spotify-track-lookup.sh"
  [[ -x "$SCRIPT" ]] || { echo "spotify-track-lookup.sh missing or not executable: $SCRIPT" >&2; return 1; }

  STUB_DIR="$TEST_TMPDIR/stub"
  mkdir -p "$STUB_DIR"
  STUB_CURL="$STUB_DIR/curl"
  export PATH="$STUB_DIR:$PATH"

  # Fresh token cache per test.
  export SPOTIFY_TOKEN_CACHE="$TEST_TMPDIR/.spotify-token-cache"

  # Default creds — tests for missing-creds will unset.
  export SPOTIFY_CLIENT_ID="test_client_id"
  export SPOTIFY_CLIENT_SECRET="test_client_secret"

  # Fixture files
  export STUB_TOKEN_BODY="$TEST_TMPDIR/token.json"
  export STUB_TOKEN_CODE="$TEST_TMPDIR/token.code"
  export STUB_TRACK_BODY="$TEST_TMPDIR/track.json"
  export STUB_TRACK_CODE="$TEST_TMPDIR/track.code"
  export STUB_TOKEN_CALLS="$TEST_TMPDIR/token.calls"
  export STUB_TRACK_CALLS="$TEST_TMPDIR/track.calls"

  printf '200' > "$STUB_TOKEN_CODE"
  printf '200' > "$STUB_TRACK_CODE"
  printf '0' > "$STUB_TOKEN_CALLS"
  printf '0' > "$STUB_TRACK_CALLS"
  # Default token body — 1h TTL.
  printf '%s' '{"access_token":"stub-tok-aaa","expires_in":3600,"token_type":"Bearer"}' > "$STUB_TOKEN_BODY"

  cat > "$STUB_CURL" <<'STUB'
#!/usr/bin/env bash
# Stub curl. Token POST and Track GET have different shapes — dispatch on URL.
body_file=""
url=""
prev=""
for arg in "$@"; do
  if [[ "$prev" == "-o" ]]; then body_file="$arg"; fi
  url="$arg"   # the URL is the trailing positional
  prev="$arg"
done

bump() {
  local f="$1" n
  n=$(cat "$f" 2>/dev/null || echo 0)
  echo $((n + 1)) > "$f"
}

if [[ "$url" == *"accounts.spotify.com/api/token"* ]]; then
  bump "$STUB_TOKEN_CALLS"
  body=$(cat "$STUB_TOKEN_BODY" 2>/dev/null || echo '{}')
  code=$(cat "$STUB_TOKEN_CODE" 2>/dev/null || echo 200)
elif [[ "$url" == *"api.spotify.com/v1/tracks/"* ]]; then
  bump "$STUB_TRACK_CALLS"
  body=$(cat "$STUB_TRACK_BODY" 2>/dev/null || echo '{}')
  code=$(cat "$STUB_TRACK_CODE" 2>/dev/null || echo 200)
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

write_track_hit() {
  cat > "$STUB_TRACK_BODY" <<'JSON'
{
  "name":"Yellow Submarine",
  "artists":[
    {"id":"3WrFJ7ztbogyGnTHbHJFl2","name":"The Beatles"}
  ],
  "external_ids":{"isrc":"GBAYE6600573"},
  "album":{"name":"Revolver","label":"Parlophone"},
  "popularity":72
}
JSON
}

# ---------- HIT performer-role match ---------------------------------------

@test "HIT performer role — name_match + role_match true, excerpt with (Spotify) tag" {
  write_track_hit
  run bash "$SCRIPT" "abc123trackid" --credited-name "The Beatles" --role "Recording Artist" --track-title "Yellow Submarine"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.found == true'
  echo "$output" | jq -e '.name_match == true'
  echo "$output" | jq -e '.role_match == true'
  echo "$output" | jq -e '.track.isrc == "GBAYE6600573"'
  echo "$output" | jq -e '.track.label == "Parlophone"'
  echo "$output" | jq -e '.evidence_excerpt | type == "string"'
  echo "$output" | jq -e '.evidence_excerpt | length >= 8 and length <= 200'
  echo "$output" | jq -e '.evidence_excerpt | test("\\(Spotify\\)")'
  echo "$output" | jq -e '.evidence_excerpt | test("Beatles"; "i")'
  echo "$output" | jq -e '.error == null'
}

# ---------- HIT but role is Mastering (Spotify can't confirm) --------------

@test "HIT but claimed role is Mastering — name_match=true, role_match=false" {
  write_track_hit
  run bash "$SCRIPT" "abc123trackid" --credited-name "The Beatles" --role "Mastering"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.name_match == true'
  echo "$output" | jq -e '.role_match == false'
  # Excerpt still emitted (name matched).
  echo "$output" | jq -e '.evidence_excerpt | type == "string"'
}

# ---------- HIT but credited name not in artists[] -------------------------

@test "HIT but credited name not in artists[] — name_match=false" {
  write_track_hit
  run bash "$SCRIPT" "abc123trackid" --credited-name "Some Random Producer" --role "Recording Artist"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.found == true'
  echo "$output" | jq -e '.name_match == false'
  echo "$output" | jq -e '.role_match == false'
  echo "$output" | jq -e '.evidence_excerpt == null'
}

# ---------- MISS — 404 ------------------------------------------------------

@test "MISS: track 404 → exit 1, found=false" {
  printf '404' > "$STUB_TRACK_CODE"
  printf '%s' '{"error":{"status":404,"message":"non existing id"}}' > "$STUB_TRACK_BODY"
  run bash "$SCRIPT" "doesnotexist" --credited-name "Anyone"
  [ "$status" -eq 1 ]
  echo "$output" | jq -e '.found == false'
  echo "$output" | jq -e '.track == null'
  echo "$output" | jq -e '.error == null'
}

# ---------- AUTH FAILURE — token endpoint 401 ------------------------------

@test "AUTH FAILURE: token endpoint 401 → exit 2, error mentions HTTP code" {
  printf '401' > "$STUB_TOKEN_CODE"
  printf '%s' '{"error":"invalid_client"}' > "$STUB_TOKEN_BODY"
  write_track_hit
  run bash "$SCRIPT" "abc123trackid" --credited-name "The Beatles"
  [ "$status" -eq 2 ]
  echo "$output" | jq -e '.found == false'
  echo "$output" | jq -e '.error | test("401")'
}

# ---------- MISSING CREDS ---------------------------------------------------

@test "MISSING CREDS: SPOTIFY_CLIENT_ID unset → exit 4" {
  unset SPOTIFY_CLIENT_ID
  run bash "$SCRIPT" "abc123trackid" --credited-name "The Beatles"
  [ "$status" -eq 4 ]
  echo "$output" | jq -e '.error | test("SPOTIFY_CLIENT_ID")'
  echo "$output" | jq -e '.found == false'
}

# ---------- CACHED TOKEN — second call reuses cache ------------------------

@test "CACHED TOKEN: second call reuses cache (no second /api/token hit)" {
  write_track_hit
  run bash "$SCRIPT" "abc123trackid" --credited-name "The Beatles" --role "Performer"
  [ "$status" -eq 0 ]
  # First call should have hit the token endpoint exactly once.
  [ "$(cat "$STUB_TOKEN_CALLS")" = "1" ]
  [ "$(cat "$STUB_TRACK_CALLS")" = "1" ]

  # Second invocation — cache file exists with future expires_at.
  run bash "$SCRIPT" "abc123trackid" --credited-name "The Beatles" --role "Performer"
  [ "$status" -eq 0 ]
  [ "$(cat "$STUB_TOKEN_CALLS")" = "1" ]   # NOT incremented
  [ "$(cat "$STUB_TRACK_CALLS")" = "2" ]
}

# ---------- EXPIRED TOKEN — re-auths ---------------------------------------

@test "EXPIRED TOKEN: cache expires_at in the past → re-auths" {
  # Pre-seed cache with already-expired token.
  printf '%s' '{"access_token":"old-stale-tok","expires_at":1}' > "$SPOTIFY_TOKEN_CACHE"
  write_track_hit
  run bash "$SCRIPT" "abc123trackid" --credited-name "The Beatles" --role "Recording Artist"
  [ "$status" -eq 0 ]
  # Token endpoint MUST have been hit because cached token was expired.
  [ "$(cat "$STUB_TOKEN_CALLS")" = "1" ]
  # Cache file should now have a future expires_at.
  jq -e '.expires_at > now' "$SPOTIFY_TOKEN_CACHE"
  jq -e '.access_token == "stub-tok-aaa"' "$SPOTIFY_TOKEN_CACHE"
}

# ---------- USAGE ERROR ----------------------------------------------------

@test "missing track ID → exit 3" {
  run --separate-stderr bash "$SCRIPT"
  [ "$status" -eq 3 ]
  [[ "$stderr" == *"track_id"* || "$stderr" == *"track id"* || "$stderr" == *"argument"* ]]
}
