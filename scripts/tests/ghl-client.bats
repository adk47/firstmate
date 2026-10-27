#!/usr/bin/env bats
# Tests for scripts/ghl.sh — the canonical GHL client (MUS-20329 / MUS-20380).
#
# CURL_BIN is STUBBED: it records argv and stdin per call and answers with a
# canned code and body, so nothing here touches the live GHL API or a real key.
# What the suite pins: the User-Agent that beats Cloudflare's 1010 block, the
# bearer travelling on stdin only, the exit-code map, and --all paging.
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
GHL="$HYDRA_REPO/scripts/ghl.sh"
FAKEKEY="fakekey-0123456789-SENTINEL"
WBKEY="winbackkey-9876543210-SENTINEL"

setup() {
  T="$(mktemp -d)"; export T
  export CURL_BIN="$T/curl"
  export GHL_API_KEY="$FAKEKEY"
  export GHL_WINBACK_API_KEY="$WBKEY"
  cat > "$CURL_BIN" <<'STUB'
#!/usr/bin/env bash
n=$(( $(cat "$T/n" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$T/n"
printf '%s\n' "$@" > "$T/argv.$n"
cat > "$T/stdin.$n"
[ -f "$T/rc" ] && exit "$(cat "$T/rc")"
out=""; prev=""
for a in "$@"; do [ "$prev" = -o ] && out="$a"; prev="$a"; done
code=200; [ -f "$T/code" ] && code="$(cat "$T/code")"; [ -f "$T/code.$n" ] && code="$(cat "$T/code.$n")"
body='{"ok":true}'; [ -f "$T/body" ] && body="$(cat "$T/body")"; [ -f "$T/body.$n" ] && body="$(cat "$T/body.$n")"
printf '%s' "$body" > "$out"
printf '%s' "$code"
STUB
  chmod +x "$CURL_BIN"
}
teardown() { rm -rf "$T"; }

# items <count> <key> -> {"<key>":[{"id":1},...]}
items() { jq -cn --argjson n "$1" --arg k "$2" '{($k): [range($n)|{id:.}]}'; }

@test "1: sends the browser-safe User-Agent and the Version header" {
  run "$GHL" GET /opportunities/search limit=1
  [ "$status" -eq 0 ]
  grep -qxF 'User-Agent: muso-hydra-ghl/1.0 (+ops@muso.ai)' "$T/argv.1"
  grep -qxF 'Version: 2021-07-28' "$T/argv.1"
  grep -qxF 'Accept: application/json' "$T/argv.1"
}

@test "1b: key=value args are URL-encoded into the query string" {
  run "$GHL" GET /contacts/ 'query=a b&c' limit=1
  [ "$status" -eq 0 ]
  grep -qF 'https://services.leadconnectorhq.com/contacts/?query=a%20b%26c&limit=1' "$T/argv.1"
}

@test "2: the key is on stdin and absent from argv, stdout and stderr, on every path" {
  run --separate-stderr "$GHL" GET /x
  [ "$status" -eq 0 ]
  grep -qF "Authorization: Bearer $FAKEKEY" "$T/stdin.1"
  grep -qxF -e '-H' "$T/argv.1"; grep -qxF -e '@-' "$T/argv.1"
  ! grep -qF "$FAKEKEY" "$T/argv.1"
  [[ "$output" != *"$FAKEKEY"* ]]; [[ "$stderr" != *"$FAKEKEY"* ]]
  # failure paths, including a server that echoes the key back in its body
  for c in 401 403 500; do
    rm -f "$T/n"; echo "$c" > "$T/code"; printf 'echo %s' "$FAKEKEY" > "$T/body"
    run --separate-stderr "$GHL" GET /x
    [ "$status" -ne 0 ]
    [[ "$output" != *"$FAKEKEY"* ]]; [[ "$stderr" != *"$FAKEKEY"* ]]
    ! grep -qF "$FAKEKEY" "$T/argv.1"
  done
  rm -f "$T/n" "$T/code" "$T/body"; echo 7 > "$T/rc"
  run --separate-stderr "$GHL" GET /x
  [ "$status" -eq 2 ]; [[ "$stderr" != *"$FAKEKEY"* ]]; ! grep -qF "$FAKEKEY" "$T/argv.1"
}

@test "3: default account reads GHL_API_KEY, --account winback reads GHL_WINBACK_API_KEY" {
  run "$GHL" GET /x
  grep -qF "Bearer $FAKEKEY" "$T/stdin.1"
  rm -f "$T/n"
  run "$GHL" --account winback GET /x
  [ "$status" -eq 0 ]
  grep -qF "Bearer $WBKEY" "$T/stdin.1"
  ! grep -qF "$FAKEKEY" "$T/stdin.1"
}

@test "4: unset or empty key exits 3 naming the var and /etc/openclaw/main.env, with no curl call" {
  unset GHL_API_KEY
  run --separate-stderr "$GHL" GET /x
  [ "$status" -eq 3 ]
  [[ "$stderr" == *"GHL_API_KEY is unset in this process"* ]]
  [[ "$stderr" == *"/etc/openclaw/main.env"* ]]
  [ ! -f "$T/n" ]
  export GHL_WINBACK_API_KEY=""
  run --separate-stderr "$GHL" --account winback GET /x
  [ "$status" -eq 3 ]; [[ "$stderr" == *"GHL_WINBACK_API_KEY"* ]]
}

@test "5: status codes map to the documented exit codes" {
  check() { # <http code> <body> <expected exit>
    rm -f "$T/n" "$T/rc"; echo "$1" > "$T/code"; printf '%s' "$2" > "$T/body"
    run --separate-stderr "$GHL" GET /x
    [ "$status" -eq "$3" ] || { echo "code $1 -> $status (want $3): $stderr"; return 1; }
  }
  check 401 '{"msg":"nope"}' 10
  [[ "$stderr" == *"GHL_API_KEY"* ]]
  check 403 'error code: 1010' 11
  [[ "$stderr" == *"1010"* ]]; [[ "$stderr" == *"HTTP 403"* ]]
  check 403 '{"error":"browser_signature_banned"}' 11
  check 403 '{"message":"Forbidden resource"}' 12
  check 500 'boom' 1
  [[ "$stderr" == *"HTTP 500"* ]]
  rm -f "$T/n"; echo 7 > "$T/rc"
  run "$GHL" GET /x
  [ "$status" -eq 2 ]
}

@test "5b: error excerpt is capped at 300 bytes of body" {
  echo 500 > "$T/code"; head -c 2000 /dev/zero | tr '\0' 'Z' > "$T/body"
  run --separate-stderr "$GHL" GET /x
  [ "$status" -eq 1 ]
  z="${stderr//[!Z]/}"
  [ "${#z}" -eq 300 ]
}

@test "6: --all pages with page=N and joins the arrays (100 + 3 -> 103, pages 2, two calls)" {
  items 100 opportunities > "$T/body.1"; items 3 opportunities > "$T/body.2"
  run "$GHL" --all GET /opportunities/search location_id=L
  [ "$status" -eq 0 ]
  [ "$(jq '.opportunities|length' <<<"$output")" -eq 103 ]
  [ "$(jq '.pages' <<<"$output")" -eq 2 ]
  [ "$(cat "$T/n")" -eq 2 ]
  grep -qF 'page=1' "$T/argv.1"; grep -qF 'limit=100' "$T/argv.1"; grep -qF 'location_id=L' "$T/argv.1"
  grep -qF 'page=2' "$T/argv.2"
}

@test "6d: --all survives a combined page set far above one argv string (~128 KiB)" {
  # 100 records x ~11 KiB = ~1.1 MiB: over one argv string on Linux (128 KiB) and over macOS ARG_MAX.
  big() { jq -cn --argjson n "$1" '{opportunities: [range($n)|{id:., note:("x" * 11000)}]}'; }
  big 100 > "$T/body.1"; big 3 > "$T/body.2"
  run "$GHL" --all GET /opportunities/search location_id=L
  [ "$status" -eq 0 ]
  [ "$(jq '.opportunities|length' <<<"$output")" -eq 103 ]
  [ "$(jq '.pages' <<<"$output")" -eq 2 ]
}

@test "6b: --all stops after one call when the first page is short, and honours a given limit" {
  items 3 contacts > "$T/body"
  run "$GHL" --all GET /contacts/ limit=20
  [ "$status" -eq 0 ]
  [ "$(jq -c '[(.contacts|length), .pages]' <<<"$output")" = "[3,1]" ]
  [ "$(cat "$T/n")" -eq 1 ]
  grep -qF 'limit=20' "$T/argv.1"
}

@test "6c: --all hits the 50-page cap with exit 4 and a failed page keeps its own code" {
  items 100 opportunities > "$T/body"
  run --separate-stderr "$GHL" --all GET /opportunities/search
  [ "$status" -eq 4 ]
  [ "$(cat "$T/n")" -eq 50 ]
  [[ "$stderr" == *"page cap"* ]]
  rm -f "$T/n" "$T/body"; items 100 opportunities > "$T/body.1"; echo 403 > "$T/code.2"; echo 'error code: 1010' > "$T/body.2"
  run "$GHL" --all GET /opportunities/search
  [ "$status" -eq 11 ]
}

@test "7: --all with POST exits 2 and says to use GET page=N" {
  run --separate-stderr "$GHL" --all POST /opportunities/search
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"POST search caps at 100, use GET page=N"* ]]
  [ ! -f "$T/n" ]
}

@test "8: --data-file sends a JSON body; a missing file is a usage error" {
  echo '{"a":1}' > "$T/payload.json"
  run "$GHL" --data-file "$T/payload.json" POST /contacts/
  [ "$status" -eq 0 ]
  grep -qxF 'Content-Type: application/json' "$T/argv.1"
  grep -qxF "@$T/payload.json" "$T/argv.1"
  run "$GHL" --data-file "$T/nope.json" POST /contacts/
  [ "$status" -eq 2 ]
}

@test "9: bad usage exits 2" {
  run "$GHL" GET
  [ "$status" -eq 2 ]
  run "$GHL" --account nobody GET /x
  [ "$status" -eq 2 ]
  run "$GHL" GET x
  [ "$status" -eq 2 ]
}
