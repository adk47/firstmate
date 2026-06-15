#!/usr/bin/env bats
#
# nocodb-api.sh's do_curl/do_multipart back off on NocoDB Cloud's per-user
# rate limiter (5 req/s, 30s block, HTTP 429 ThrottlerException). Before this,
# emit_body collapsed every HTTP >= 400 into a generic exit 3, so a 429 was
# indistinguishable from a 500/auth error and nothing could retry it — the CMO
# company-finder incident 2026-06-13 (both the dedup READS and the ledger
# WRITES fail-closed on a 429). These tests pin: a transient 429 is retried
# (reads AND writes), a sustained 429 still fails closed (exit 3), a 429 with no
# Retry-After falls back to the base wait without aborting under set -e, and a
# non-429 error still fast-fails on the first attempt.
#
# A curl stub on PATH emulates `-w '\n%{http_code}'` (prints "<body>\n<code>")
# and honors `-D <file>` (writes response headers). It arms a 429 sequence via
# a countdown file and a sticky non-429 code via FORCE_CODE — the same
# marker-file idiom as muso-caroline-weekly-review's fetch-conversations.bats.
# NOCODB_RETRY_BASE=0 keeps every test instant (no real 30s wait).

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../../.." && pwd)"
  SCRIPT="$REPO_ROOT/skills-all/muso-nocodb/scripts/nocodb-api.sh"
  TMP="$(mktemp -d)"
  mkdir -p "$TMP/bin"
  export CURL_CALLS="$TMP/curl.calls"
  export FORCE_429_COUNT="$TMP/force-429-count"
  : >"$CURL_CALLS"

  cat >"$TMP/bin/curl" <<'STUB'
#!/usr/bin/env bash
# Fake curl: emulate -w '\n%{http_code}' (body then code, no trailing newline —
# command substitution strips it anyway) and -D <file> (response headers).
hdrs=""; url=""; prev=""
for a in "$@"; do
  [[ "$prev" == "-D" ]] && hdrs="$a"
  case "$a" in http://*|https://*) url="$a" ;; esac
  prev="$a"
done
printf 'call %s\n' "$url" >>"$CURL_CALLS"

# Sticky non-429 error (e.g. 403/500): one HTTP status, never retried.
if [[ -n "${FORCE_CODE:-}" ]]; then
  [[ -n "$hdrs" ]] && printf 'HTTP/1.1 %s X\r\n\r\n' "$FORCE_CODE" >"$hdrs"
  printf '%s\n%s' '{"msg":"err"}' "$FORCE_CODE"
  exit 0
fi

# Armed 429 sequence: serve a 429 until the countdown file hits 0.
if [[ -f "$FORCE_429_COUNT" ]]; then
  n=$(cat "$FORCE_429_COUNT")
  if [[ "$n" -gt 0 ]]; then
    echo $((n - 1)) >"$FORCE_429_COUNT"
    if [[ -n "$hdrs" ]]; then
      if [[ -n "${FORCE_429_RA:-}" ]]; then
        printf 'HTTP/1.1 429 Too Many Requests\r\nRetry-After: %s\r\n\r\n' "$FORCE_429_RA" >"$hdrs"
      else
        printf 'HTTP/1.1 429 Too Many Requests\r\n\r\n' >"$hdrs"
      fi
    fi
    printf '%s\n429' '{"msg":"ThrottlerException: Too Many Requests"}'
    exit 0
  fi
fi

[[ -n "$hdrs" ]] && printf 'HTTP/1.1 200 OK\r\n\r\n' >"$hdrs"
printf '%s\n200' '{"list":[{"Id":1}],"pageInfo":{"isLastPage":true}}'
exit 0
STUB
  chmod +x "$TMP/bin/curl"

  export PATH="$TMP/bin:$PATH"
  export NOCODB_API_TOKEN=x
  export NOCODB_RETRY_BASE=0   # no real waits in CI
}

teardown() { rm -rf "$TMP"; }

calls() { grep -c '^call' "$CURL_CALLS"; }

@test "records.ls retries a transient 429 then returns the body (exit 0)" {
  echo 2 >"$FORCE_429_COUNT"   # two 429s then 200; default NOCODB_MAX_RETRIES=3
  run bash "$SCRIPT" --raw records.ls sometable
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.list[0].Id == 1'
  [ "$(calls)" -eq 3 ]
}

@test "sustained 429 fails closed (exit 3) after exhausting retries" {
  echo 99 >"$FORCE_429_COUNT"  # always 429
  run bash "$SCRIPT" --raw records.ls sometable
  [ "$status" -eq 3 ]
  [[ "$output" == *"ThrottlerException"* ]]   # body still surfaced before exit 3
  [ "$(calls)" -eq 3 ]                          # exactly NOCODB_MAX_RETRIES attempts
}

@test "a 429 with no Retry-After header falls back to base wait (no set -e abort)" {
  # FORCE_429_RA unset → the stub omits Retry-After; the grep no-matches, so this
  # regression-guards the `|| true` that keeps set -euo pipefail from aborting.
  echo 1 >"$FORCE_429_COUNT"
  run bash "$SCRIPT" --raw records.ls sometable
  [ "$status" -eq 0 ]
  [ "$(calls)" -eq 2 ]
}

@test "a 429 with a present Retry-After header is parsed and honored" {
  export FORCE_429_RA=0
  echo 1 >"$FORCE_429_COUNT"
  run bash "$SCRIPT" --raw records.ls sometable
  [ "$status" -eq 0 ]
  [ "$(calls)" -eq 2 ]
}

@test "a non-429 error (403) fast-fails exit 3 with NO retry" {
  export FORCE_CODE=403
  run bash "$SCRIPT" --raw records.ls sometable
  [ "$status" -eq 3 ]
  [ "$(calls)" -eq 1 ]
}

@test "records.create (a WRITE) retries a 429 then succeeds" {
  echo 1 >"$FORCE_429_COUNT"
  run bash "$SCRIPT" --raw records.create sometable '[{"Domain":"x.com"}]'
  [ "$status" -eq 0 ]
  [ "$(calls)" -eq 2 ]
}

@test "a clean request makes exactly one curl call (no spurious retry)" {
  run bash "$SCRIPT" --raw records.ls sometable
  [ "$status" -eq 0 ]
  [ "$(calls)" -eq 1 ]
}
