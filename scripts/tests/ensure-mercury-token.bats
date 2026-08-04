#!/usr/bin/env bats
# Tests for scripts/lib/ensure-mercury-token.sh — the PURE DETECTOR for the
# Finance Mercury Bank API token, which has now been revoked twice (Token A
# ~2026-05-01, Token B ~2026-06-10) with the second death going unnoticed for
# ~8 weeks. Paging/cooldown live in scripts/mercury-token-watchdog.sh and are
# covered by mercury-token-watchdog.bats.
#
# Everything runs against a throwaway MERCURY_ENV_FILE and a stubbed curl —
# never the real /opt/hydra/secrets/mercury.env, never a real call to
# api.mercury.com. CI runs bats as ROOT, so no test may depend on being
# unprivileged.
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
LIB="$HYDRA_REPO/scripts/lib/ensure-mercury-token.sh"

# The literal the leak tests assert never appears. Distinctive on purpose.
FAKE_TOKEN='secret-token:mercury_production_rma_NEVERLOGTHIS0000'

setup() {
  TEST_TMPDIR="$(mktemp -d)"; export TEST_TMPDIR
  export MERCURY_ENV_FILE="$TEST_TMPDIR/mercury.env"
  export MERCURY_API="https://api.mercury.test/api/v1"
  export CURL_BIN="$TEST_TMPDIR/bin/curl"
  mkdir -p "$TEST_TMPDIR/bin"
  printf '# Mercury Bank API — RESTRICTED ACCESS\nMERCURY_API_KEY=%s\n' \
    "$FAKE_TOKEN" > "$MERCURY_ENV_FILE"
  # Default to a healthy 200 so cases about credential PARSING aren't silently
  # answered by the curl-not-found branch (which precedes the file read).
  # Cases about a specific status override it.
  stub_curl 200
}
teardown() { rm -rf "$TEST_TMPDIR"; }

# stub_curl <http_code> — a curl that records BOTH its argv and its stdin, then
# prints the code, mimicking `-w '%{http_code}'`. An empty argument simulates a
# transport failure, where curl writes nothing to stdout.
#
# Recording argv is the point: the whole reason this credential goes over stdin
# is that `ps` on node-8 is readable by every agent. A stub that only captured
# stdin let "put the token in argv TOO" pass green — the invariant the file is
# named for was undefended.
stub_curl() {
  cat > "$CURL_BIN" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" > "\$TEST_TMPDIR/curl-argv"
cat > "\$TEST_TMPDIR/curl-stdin"
printf '%s' '$1'
EOF
  chmod +x "$CURL_BIN"
}

argv() { cat "$TEST_TMPDIR/curl-argv" 2>/dev/null || true; }

# refute_argv <grep-args...> — fail the test if the pattern appears in curl's
# recorded argv. A bare `! grep ...` CANNOT be used here: bats runs test bodies
# under set -e, and set -e explicitly ignores a command negated by `!`, so such
# an assertion is a no-op unless it happens to be the test's last line. Routing
# through `run` + an un-negated `[` makes the failure real wherever it sits.
refute_argv() {
  run grep -q "$@" "$TEST_TMPDIR/curl-argv"
  [ "$status" -ne 0 ]
}

# ── the three verdicts ────────────────────────────────────────────────────────

@test "HTTP 200 → exit 0 (token works)" {
  run "$LIB" --check
  [ "$status" -eq 0 ]
  [[ "$output" == *"clean"* ]]
}

@test "HTTP 401 → exit 1 (the live incident signature)" {
  stub_curl 401
  run "$LIB" --check
  [ "$status" -eq 1 ]
  [[ "$output" == *"VIOLATION"* ]]
  [[ "$output" == *"REJECTED"* ]]
}

@test "HTTP 403 → exit 1" {
  stub_curl 403
  run "$LIB" --check
  [ "$status" -eq 1 ]
  [[ "$output" == *"VIOLATION"* ]]
}

# The pair to the 401 test: a server-side fault must NOT be reported as a
# revoked token, and must NOT be reported as clean either.
@test "HTTP 500 → exit 2 (cannot evaluate, not a false clean, not a violation)" {
  stub_curl 500
  run "$LIB" --check
  [ "$status" -eq 2 ]
  [[ "$output" == *"cannot evaluate"* ]]
  [[ "$output" != *"VIOLATION"* ]]
}

@test "curl transport failure (no output) → exit 2, not 0" {
  stub_curl ''
  run "$LIB" --check
  [ "$status" -eq 2 ]
  [[ "$output" == *"cannot evaluate"* ]]
}

@test "curl missing entirely → exit 2 (the checker is broken, not the token)" {
  export CURL_BIN="$TEST_TMPDIR/bin/definitely-not-curl"
  run "$LIB" --check
  [ "$status" -eq 2 ]
  [[ "$output" == *"curl not found"* ]]
}

# The anti-hole test: deleting the credential must be a pageable violation, not
# a silent "inconclusive". This is the case that distinguishes 1 from 2.
@test "credential file absent → exit 1, NOT 2 (rm must not be a silent no-page)" {
  rm -f "$MERCURY_ENV_FILE"
  run "$LIB" --check
  [ "$status" -eq 1 ]
  [[ "$output" == *"no credential"* ]]
}

@test "file present but no MERCURY_API_KEY → exit 1" {
  printf '# comment only\n' > "$MERCURY_ENV_FILE"
  run "$LIB" --check
  [ "$status" -eq 1 ]
  [[ "$output" == *"no MERCURY_API_KEY"* ]]
}

# ── the token must never escape ───────────────────────────────────────────────

@test "the token NEVER appears in output, on success or failure" {
  stub_curl 200
  run "$LIB" --check
  [[ "$output" != *"NEVERLOGTHIS"* ]]
  stub_curl 401
  run "$LIB" --check
  [[ "$output" != *"NEVERLOGTHIS"* ]]
  stub_curl 500
  run "$LIB" --check
  [[ "$output" != *"NEVERLOGTHIS"* ]]
}

# `ps` on node-8 is readable by every agent, and this credential reaching other
# agents is the exact leak this work exists to close — so it must go over stdin,
# never argv.
@test "token reaches curl via stdin, never via argv" {
  run "$LIB" --check
  [ "$status" -eq 0 ]
  # The stdin half...
  [[ "$(cat "$TEST_TMPDIR/curl-stdin")" == "Authorization: Bearer $FAKE_TOKEN" ]]
  # ...AND the half that actually enforces the security claim. Asserting only
  # the first passes just as happily when the token is ALSO in argv, which is
  # precisely the `ps`-visible leak this design exists to prevent.
  [ -s "$TEST_TMPDIR/curl-argv" ]
  # `refute <pattern>` and not a bare `! grep`: bats runs test bodies under
  # set -e, which IGNORES a command negated by `!`, so a mid-test `! grep`
  # is silently skipped and only the LAST line of a test can ever fail it.
  refute_argv -F -- "$FAKE_TOKEN"
  refute_argv -iF -- "authorization"
}

# A bank bearer must not be routable over plaintext, through a proxy, or
# forwarded to another host by a redirect. MERCURY_API is env-overridable and
# curl honours http_proxy, so these flags are the only thing making that
# structural — and without an argv assertion, deleting them was invisible.
@test "the probe forces TLS, bypasses proxies, and never follows redirects" {
  run "$LIB" --check
  [ "$status" -eq 0 ]
  grep -qx -- '--proto' "$TEST_TMPDIR/curl-argv"
  grep -qx -- '=https'  "$TEST_TMPDIR/curl-argv"
  grep -qx -- '--noproxy' "$TEST_TMPDIR/curl-argv"
  # -L would forward the Authorization header to a redirect target.
  refute_argv -x -- '-L'
  refute_argv -x -- '--location'
}

# ── credential parsing ────────────────────────────────────────────────────────

@test "quoted + CRLF + export-prefixed value parses to the bare token" {
  printf 'export MERCURY_API_KEY="%s"\r\n' "$FAKE_TOKEN" > "$MERCURY_ENV_FILE"
  run "$LIB" --check
  [ "$status" -eq 0 ]
  [[ "$(cat "$TEST_TMPDIR/curl-stdin")" == "Authorization: Bearer $FAKE_TOKEN" ]]
}

@test "single-quoted and trailing-whitespace values parse to the bare token" {
  printf "MERCURY_API_KEY='%s'   \n" "$FAKE_TOKEN" > "$MERCURY_ENV_FILE"
  run "$LIB" --check
  [ "$status" -eq 0 ]
  [[ "$(cat "$TEST_TMPDIR/curl-stdin")" == "Authorization: Bearer $FAKE_TOKEN" ]]
}

# The real consumer does `set -a; . mercury.env`, which is LAST-wins. A parser
# that silently picked one would either probe a stale token forever or report a
# false clean on a token nobody uses — so two assignments must be refused, not
# resolved.
@test "two MERCURY_API_KEY assignments → exit 1, refuses rather than guessing" {
  { printf 'MERCURY_API_KEY=OLD_DEAD_TOKEN\n'
    printf 'MERCURY_API_KEY=NEW_LIVE_TOKEN\n'; } > "$MERCURY_ENV_FILE"
  run "$LIB" --check
  [ "$status" -eq 1 ]
  [[ "$output" == *"2 MERCURY_API_KEY assignments"* ]]
  [ ! -e "$TEST_TMPDIR/curl-stdin" ]   # refused before probing either one
}

@test "one assignment plus a commented-out one is NOT ambiguous" {
  { printf '# MERCURY_API_KEY=OLD_DEAD_TOKEN\n'
    printf 'MERCURY_API_KEY=%s\n' "$FAKE_TOKEN"; } > "$MERCURY_ENV_FILE"
  run "$LIB" --check
  [ "$status" -eq 0 ]
  [[ "$(cat "$TEST_TMPDIR/curl-stdin")" == "Authorization: Bearer $FAKE_TOKEN" ]]
}

# bash strips a trailing ` # comment` when the file is sourced, so the detector
# must too — otherwise an annotated rotation date turns into part of the bearer
# token and every probe 401s as a phantom revocation.
@test "an inline trailing comment is not swallowed into the token" {
  printf 'MERCURY_API_KEY=%s   # rotated 2026-08-04\n' "$FAKE_TOKEN" > "$MERCURY_ENV_FILE"
  run "$LIB" --check
  [ "$status" -eq 0 ]
  [[ "$(cat "$TEST_TMPDIR/curl-stdin")" == "Authorization: Bearer $FAKE_TOKEN" ]]
}

# The secret store is data, not shell — a would-be command substitution in the
# file must be passed through verbatim, never executed.
@test "the env file is never sourced: shell metacharacters are not evaluated" {
  printf 'MERCURY_API_KEY=$(touch %s/PWNED)\n' "$TEST_TMPDIR" > "$MERCURY_ENV_FILE"
  run "$LIB" --check
  [ ! -e "$TEST_TMPDIR/PWNED" ]
}

# ── argument handling ─────────────────────────────────────────────────────────

@test "no argument behaves as --check (read-only)" {
  stub_curl 401
  run "$LIB"
  [ "$status" -eq 1 ]
  [[ "$output" == *"VIOLATION"* ]]
}

@test "unknown argument → exit 2, does not silently probe" {
  run "$LIB" --bogus
  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown arg"* ]]
  [ ! -e "$TEST_TMPDIR/curl-stdin" ]
}
