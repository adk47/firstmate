#!/usr/bin/env bats
# Tests for scripts/lib/qa-github-app-token.sh — the GitHub App installation-token
# minter behind the QA bot identity.
#
# `curl` is PATH-stubbed so no test reaches api.github.com, but `openssl` and `jq`
# are REAL: the JWT is signed with a genuine throwaway RSA key and the signature
# is verified against its public key. Stubbing the crypto would leave the one
# part most likely to be silently wrong (RS256 over base64url) untested.
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
MINT="$HYDRA_REPO/scripts/lib/qa-github-app-token.sh"

setup() {
  TEST_TMPDIR="$(mktemp -d)"; export TEST_TMPDIR
  openssl genrsa -out "$TEST_TMPDIR/k.pem" 2048 2>/dev/null
  jq -n --arg k "$(cat "$TEST_TMPDIR/k.pem")" \
    '{app_id:"123456", installation_id:"999", private_key:$k}' > "$TEST_TMPDIR/qa-bot-app.json"

  export QA_BOT_APP_KEY="$TEST_TMPDIR/qa-bot-app.json"
  export QA_BOT_TOKEN_CACHE="$TEST_TMPDIR"
  export QA_BOT_LOCK_DIR="$TEST_TMPDIR"
  export CURL_LOG="$TEST_TMPDIR/curl.log"

  STUBBIN="$TEST_TMPDIR/bin"; mkdir -p "$STUBBIN"
  # Records every invocation (so a test can prove a cache HIT made no call) and
  # returns a token that expires CURL_EXPIRES_IN seconds from now.
  cat > "$STUBBIN/curl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CURL_LOG"
printf '%s' "$*" | grep -o 'Bearer [A-Za-z0-9_.-]*' | head -1 | sed 's/Bearer //' > "$TEST_TMPDIR/captured.jwt"
if [ -n "${CURL_FAIL:-}" ]; then printf 'boom\n500'; exit 0; fi
secs="${CURL_EXPIRES_IN:-3600}"
exp="$(date -u -d "+${secs} seconds" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
      || date -u -v+"${secs}"S +%Y-%m-%dT%H:%M:%SZ)"
printf '{"token":"ghs_TESTTOKEN","expires_at":"%s"}\n201' "$exp"
STUB
  chmod +x "$STUBBIN/curl"
  export PATH="$STUBBIN:$PATH"
}
teardown() { rm -rf "$TEST_TMPDIR"; }

b64url_decode() {
  local s="${1//-/+}"; s="${s//_//}"
  while [ $(( ${#s} % 4 )) -ne 0 ]; do s="$s="; done
  printf '%s' "$s" | openssl base64 -d -A 2>/dev/null
}

# ---------------------------------------------------------------------------
# Minting
# ---------------------------------------------------------------------------

@test "mints a token and prints ONLY the token on stdout" {
  run "$MINT" --repo Muso-AI/core-backend
  [ "$status" -eq 0 ]
  [ "$output" = "ghs_TESTTOKEN" ]
}

@test "the JWT is a real RS256 signature that verifies against the app's public key" {
  run "$MINT" --repo Muso-AI/core-backend
  [ "$status" -eq 0 ]
  jwt="$(cat "$TEST_TMPDIR/captured.jwt")"
  [ -n "$jwt" ]

  # header + claims
  [ "$(b64url_decode "${jwt%%.*}")" = '{"alg":"RS256","typ":"JWT"}' ]
  rest="${jwt#*.}"
  payload="$(b64url_decode "${rest%%.*}")"
  [ "$(printf '%s' "$payload" | jq -r .iss)" = "123456" ]
  iat="$(printf '%s' "$payload" | jq -r .iat)"
  exp="$(printf '%s' "$payload" | jq -r .exp)"
  now="$(date -u +%s)"
  # iat backdated (clock skew) and exp inside GitHub's 10-minute ceiling
  [ "$iat" -lt "$now" ]
  [ "$((exp - now))" -le 600 ]
  [ "$((exp - now))" -gt 0 ]

  # signature actually verifies
  printf '%s' "${jwt%.*}" > "$TEST_TMPDIR/si.txt"
  printf '%s' "${jwt##*.}" | tr '_-' '/+' | sed -e 's/$/==/' \
    | openssl base64 -d -A > "$TEST_TMPDIR/sig.bin" 2>/dev/null
  openssl rsa -in "$TEST_TMPDIR/k.pem" -pubout -out "$TEST_TMPDIR/pub.pem" 2>/dev/null
  run openssl dgst -sha256 -verify "$TEST_TMPDIR/pub.pem" \
    -signature "$TEST_TMPDIR/sig.bin" "$TEST_TMPDIR/si.txt"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "Verified OK"
}

@test "--repo scopes the token to that repository by name" {
  run "$MINT" --repo Muso-AI/H-DevOps
  [ "$status" -eq 0 ]
  # the request body must name the repo, so a leaked token opens only that repo
  grep -q '"repositories":\["H-DevOps"\]' "$CURL_LOG"
}

@test "no --repo → unscoped request body" {
  run "$MINT"
  [ "$status" -eq 0 ]
  ! grep -q '"repositories"' "$CURL_LOG"
}

# ---------------------------------------------------------------------------
# Caching
# ---------------------------------------------------------------------------

@test "cache file is written owner-only (0600) and is a *.json so the perms self-heal covers it" {
  run "$MINT" --repo Muso-AI/core-backend
  [ "$status" -eq 0 ]
  f="$TEST_TMPDIR/qa-bot-token-Muso-AI__core-backend.json"
  [ -f "$f" ]
  mode="$(stat -c '%a' "$f" 2>/dev/null || stat -f '%Lp' "$f")"
  [ "$mode" = "600" ]
}

@test "a fresh cached token is reused without any API call" {
  run "$MINT" --repo Muso-AI/core-backend
  [ "$status" -eq 0 ]
  calls_before="$(wc -l < "$CURL_LOG")"
  run "$MINT" --repo Muso-AI/core-backend
  [ "$status" -eq 0 ]
  [ "$output" = "ghs_TESTTOKEN" ]
  [ "$(wc -l < "$CURL_LOG")" -eq "$calls_before" ]
}

@test "a token inside the 10-minute floor is re-minted, not served stale" {
  CURL_EXPIRES_IN=300 run "$MINT" --repo Muso-AI/core-backend   # expires in 5 min
  [ "$status" -eq 0 ]
  calls_before="$(wc -l < "$CURL_LOG")"
  run "$MINT" --repo Muso-AI/core-backend
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$CURL_LOG")" -gt "$calls_before" ]
}

@test "cache is keyed per repo — one repo's token is not served for another" {
  run "$MINT" --repo Muso-AI/core-backend
  [ "$status" -eq 0 ]
  calls_before="$(wc -l < "$CURL_LOG")"
  run "$MINT" --repo Muso-AI/octave-ui
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$CURL_LOG")" -gt "$calls_before" ]
  [ -f "$TEST_TMPDIR/qa-bot-token-Muso-AI__octave-ui.json" ]
}

# ---------------------------------------------------------------------------
# Failure modes — all must fail loud and leak nothing
# ---------------------------------------------------------------------------

@test "missing key store → exit 3, nothing on stdout" {
  export QA_BOT_APP_KEY="$TEST_TMPDIR/absent.json"
  run "$MINT" --repo Muso-AI/core-backend
  [ "$status" -eq 3 ]
  [ -z "$output" ] || ! echo "$output" | grep -q 'ghs_'
}

@test "key store without app_id → exit 3" {
  jq -n --arg k "$(cat "$TEST_TMPDIR/k.pem")" '{private_key:$k}' > "$QA_BOT_APP_KEY"
  run "$MINT" --repo Muso-AI/core-backend
  [ "$status" -eq 3 ]
}

@test "key store without a private_key → exit 3" {
  jq -n '{app_id:"123456", installation_id:"999"}' > "$QA_BOT_APP_KEY"
  run "$MINT" --repo Muso-AI/core-backend
  [ "$status" -eq 3 ]
}

@test "unusable private key → exit 4 (JWT could not be signed)" {
  jq -n '{app_id:"123456", installation_id:"999", private_key:"not-a-key"}' > "$QA_BOT_APP_KEY"
  run "$MINT" --repo Muso-AI/core-backend
  [ "$status" -eq 4 ]
}

@test "non-2xx from GitHub → exit 5 and the response body is NOT echoed (it can carry a token)" {
  CURL_FAIL=1 run "$MINT" --repo Muso-AI/core-backend
  [ "$status" -eq 5 ]
  ! echo "$output" | grep -q 'ghs_'
  ! echo "$output" | grep -q 'boom'
}

@test "--repo without a value → exit 2" {
  run "$MINT" --repo
  [ "$status" -eq 2 ]
}
