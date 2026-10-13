#!/usr/bin/env bats
# describe-creative.sh: one image URL in, a factual description on stdout.
# Failure must be silent on stdout (empty + non-zero) so the screening caller
# can say "creative could not be described" instead of inventing text.
# Hermetic: `curl` is a stub on PATH; OpenRouter is never called.

bats_require_minimum_version 1.5.0

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  SCRIPT="$REPO_ROOT/scripts/lib/describe-creative.sh"
  STUB_DIR="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$STUB_DIR"
  export CURL_LOG="$BATS_TEST_TMPDIR/curl.log"
  export CURL_HDR_LOG="$BATS_TEST_TMPDIR/curl-hdr.log"
  : >"$CURL_LOG"
  : >"$CURL_HDR_LOG"

  cat >"$STUB_DIR/curl" <<'STUB'
#!/bin/bash
# Stub: records argv; serves an image for the fetch call, STUB_API_BODY for the API call.
out="" mode=image prev=""
for a in "$@"; do
  [ "$prev" = "-o" ] && out="$a"
  case "$a" in *openrouter.ai*) mode=api ;; esac
  prev="$a"
done
printf '%s\n' "$*" >>"$CURL_LOG"
# Header files (-H @file) are what really goes on the wire; log their contents separately.
[ "$mode" = api ] && for a in "$@"; do case "$a" in @*) cat "${a#@}" >>"$CURL_HDR_LOG" ;; esac; done
[ -n "${STUB_CURL_EXIT:-}" ] && [ "$mode" = "${STUB_CURL_EXIT_MODE:-api}" ] && exit "$STUB_CURL_EXIT"
if [ "$mode" = image ]; then
  head -c "${STUB_IMG_BYTES:-100}" /dev/zero >"$out"
  printf '%s' "${STUB_IMG_CODE:-200} ${STUB_IMG_TYPE:-image/png}"
else
  printf '%s' "${STUB_API_BODY:-}" >"$out"
  printf '%s' "${STUB_API_CODE:-200}"
fi
STUB
  chmod +x "$STUB_DIR/curl"
  export PATH="$STUB_DIR:$PATH"

  export JEV_ENV_FILE="$BATS_TEST_TMPDIR/jev.env"
  echo 'OPENROUTER_API_KEY=sk-test-key' >"$JEV_ENV_FILE"
  unset OPENROUTER_API_KEY DESCRIBE_CREATIVE_MODEL DESCRIBE_CREATIVE_MAX_CHARS \
        DESCRIBE_CREATIVE_MAX_BYTES DESCRIBE_CREATIVE_TIMEOUT DESCRIBE_CREATIVE_ALLOWED_HOSTS
  export DESCRIBE_CREATIVE_ALLOWED_HOSTS='cdn.example.com,example.com'
  export STUB_API_BODY='{"choices":[{"finish_reason":"stop","message":{"content":"A red banner reading SALE 50% OFF beside a smiling person."}}]}'
}

# bats `run` merges streams unless --separate-stderr is used.
run_split() { run --separate-stderr bash "$SCRIPT" "$@"; }

@test "happy path: prints the description and nothing else, exit 0" {
  run_split https://example.com/ad.png
  [ "$status" -eq 0 ]
  [ "$output" = "A red banner reading SALE 50% OFF beside a smiling person." ]
}

@test "missing key: empty stdout, non-zero, warning on stderr, no network" {
  echo '# nothing' >"$JEV_ENV_FILE"
  run_split https://example.com/ad.png
  [ "$status" -ne 0 ]
  [ -z "$output" ]
  [[ "$stderr" == *OPENROUTER_API_KEY* ]]
  [ ! -s "$CURL_LOG" ]
}

@test "zero-ish numeric knobs (00) are rejected, not read as 'no limit'" {
  export DESCRIBE_CREATIVE_TIMEOUT=00
  run_split https://example.com/ad.png
  [ "$status" -ne 0 ]
  [ -z "$output" ]
  [ ! -s "$CURL_LOG" ]
}

@test "no url argument: non-zero, empty stdout" {
  run_split
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "API non-2xx: empty stdout, non-zero, warning on stderr" {
  export STUB_API_CODE=500
  run_split https://example.com/ad.png
  [ "$status" -ne 0 ]
  [ -z "$output" ]
  [[ "$stderr" == *WARN* ]]
}

@test "API timeout (curl exit 28): empty stdout, non-zero" {
  export STUB_CURL_EXIT=28
  run_split https://example.com/ad.png
  [ "$status" -ne 0 ]
  [ -z "$output" ]
  [[ "$stderr" == *WARN* ]]
}

@test "image fetch non-2xx: empty stdout, non-zero, API never called" {
  export STUB_IMG_CODE=404
  run_split https://example.com/ad.png
  [ "$status" -ne 0 ]
  [ -z "$output" ]
  if grep -q openrouter.ai "$CURL_LOG"; then false; fi
}

@test "oversized image: empty stdout, non-zero, API never called" {
  export DESCRIBE_CREATIVE_MAX_BYTES=50 STUB_IMG_BYTES=100
  run_split https://example.com/ad.png
  [ "$status" -ne 0 ]
  [ -z "$output" ]
  if grep -q openrouter.ai "$CURL_LOG"; then false; fi
  # the download itself is bounded by curl, not only checked afterwards
  grep -q -- '--max-filesize 50' "$CURL_LOG"
}

@test "non-image content type: refused before the API call" {
  export STUB_IMG_TYPE=text/html
  run_split https://example.com/ad.png
  [ "$status" -ne 0 ]
  [ -z "$output" ]
  if grep -q openrouter.ai "$CURL_LOG"; then false; fi
}

@test "truncated completion (finish_reason=length) is never returned as partial" {
  export STUB_API_BODY='{"choices":[{"finish_reason":"length","message":{"content":"A red ban"}}]}'
  run_split https://example.com/ad.png
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "empty or malformed completion: empty stdout, non-zero" {
  export STUB_API_BODY='{"choices":[{"finish_reason":"stop","message":{"content":"  "}}]}'
  run_split https://example.com/ad.png
  [ "$status" -ne 0 ]
  [ -z "$output" ]
  export STUB_API_BODY='not json'
  run_split https://example.com/ad.png
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "description is length-capped" {
  export DESCRIBE_CREATIVE_MAX_CHARS=10
  run_split https://example.com/ad.png
  [ "$status" -eq 0 ]
  [ "${#output}" -eq 10 ]
}

@test "request: attribution headers, bearer key from env file, default model, describe-not-judge prompt" {
  run_split https://example.com/ad.png
  [ "$status" -eq 0 ]
  grep -q 'https://openrouter.ai/api/v1/chat/completions' "$CURL_LOG"
  grep -q 'HTTP-Referer: https://muso.ai' "$CURL_LOG"
  grep -q 'X-Title:' "$CURL_LOG"
  # the key reaches the API as a bearer header, but never via argv (visible in ps)
  grep -qx 'Authorization: Bearer sk-test-key' "$CURL_HDR_LOG"
  if grep -q 'sk-test-key' "$CURL_LOG"; then false; fi
}

@test "request body: image_url part, openai/gpt-5-mini default, model overridable, prompt forbids a verdict" {
  cat >"$STUB_DIR/curl" <<'STUB'
#!/bin/bash
prev="" body=""
for a in "$@"; do
  [ "$prev" = "-o" ] && out="$a"
  [ "$prev" = "-d" ] || [ "$prev" = "--data-binary" ] && body="${a#@}"
  case "$a" in *openrouter.ai*) api=1 ;; esac
  prev="$a"
done
if [ -n "${api:-}" ]; then
  cp "$body" "$CAPTURE"
  printf '%s' '{"choices":[{"finish_reason":"stop","message":{"content":"ok"}}]}' >"$out"
  printf 200
else
  head -c 10 /dev/zero >"$out"; printf '200 image/jpeg'
fi
STUB
  export CAPTURE="$BATS_TEST_TMPDIR/body.json"
  run_split https://example.com/ad.png
  [ "$status" -eq 0 ]
  [ "$(jq -r .model "$CAPTURE")" = "openai/gpt-5-mini" ]
  [[ "$(jq -r '.messages[0].content[] | select(.type=="image_url") | .image_url.url' "$CAPTURE")" == data:image/jpeg\;base64,* ]]
  jq -r '.messages[].content | if type=="string" then . else (.[]|select(.type=="text")|.text) end' "$CAPTURE" | grep -qi 'do not.*\(recommend\|approve\|judge\)'

  DESCRIBE_CREATIVE_MODEL=openai/other run_split https://example.com/ad.png
  [ "$(jq -r .model "$CAPTURE")" = "openai/other" ]
}

# ── SSRF boundary: only allowlisted https hosts are ever fetched ─────────────
# Each case must fail with empty stdout and never reach curl at all.

assert_refused_before_network() {
  [ "$status" -ne 0 ]
  [ -z "$output" ]
  [ ! -s "$CURL_LOG" ]
}

@test "ssrf: host not on the allowlist is refused without any request" {
  run_split https://evil.example.org/ad.png
  assert_refused_before_network
  [[ "$stderr" == *WARN* ]]
}

@test "ssrf: allowlist unset fails closed" {
  unset DESCRIBE_CREATIVE_ALLOWED_HOSTS
  run_split https://example.com/ad.png
  assert_refused_before_network
}

@test "ssrf: allowlist may come from the jev env file" {
  unset DESCRIBE_CREATIVE_ALLOWED_HOSTS
  echo 'DESCRIBE_CREATIVE_ALLOWED_HOSTS=example.com' >>"$JEV_ENV_FILE"
  run_split https://example.com/ad.png
  [ "$status" -eq 0 ]
}

@test "ssrf: plain http is refused even for an allowlisted host" {
  run_split http://example.com/ad.png
  assert_refused_before_network
}

@test "ssrf: loopback, metadata and private IP literals are refused" {
  local u
  for u in https://127.0.0.1/a.png https://169.254.169.254/latest/meta-data https://10.0.0.5/a.png https://localhost/a.png 'https://[::1]/a.png'; do
    run_split "$u"
    assert_refused_before_network
  done
}

@test "ssrf: userinfo / port / backslash tricks cannot smuggle a different host" {
  local u
  for u in 'https://example.com@evil.example.org/a.png' 'https://example.com:8443/a.png' 'https://evil.example.org\@example.com/a.png' 'https://example.com.evil.example.org/a.png' 'https://example.com%2f@evil.example.org/a.png'; do
    run_split "$u"
    assert_refused_before_network
  done
}

@test "ssrf: host match is case-insensitive and exact" {
  run_split https://CDN.Example.COM/ad.png
  [ "$status" -eq 0 ]
}

@test "ssrf: redirects are never followed (a 3xx fails, no -L, https-only protocol)" {
  export STUB_IMG_CODE=302
  run_split https://example.com/ad.png
  [ "$status" -ne 0 ]
  [ -z "$output" ]
  if grep -qE -- '(^| )(-L|--location)( |$)' "$CURL_LOG"; then false; fi
  grep -q -- '--proto =https' "$CURL_LOG"
  if grep -q openrouter.ai "$CURL_LOG"; then false; fi
}

@test "ssrf: an empty allowlist entry never matches an empty host (https:///<ip>/ is routed by curl)" {
  local list
  for list in 'example.com,,cdn.example.com' ',example.com' 'example.com,'; do
    DESCRIBE_CREATIVE_ALLOWED_HOSTS="$list" run_split 'https:///169.254.169.254/latest/meta-data'
    assert_refused_before_network
  done
}
