#!/usr/bin/env bats
# Tests for scripts/muso-stack-read.sh, the read-only reader of our own analytics /
# email / notification stack (stack-swap lane 8: agents off Amplitude/Klaviyo/Knock).
#
# Hermetic: PATH-shadows kubectl and curl. The stubs record argv (and curl's stdin)
# so the tests can prove the read-only flags are always sent and the router
# credential never reaches argv.
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
S="$HYDRA_REPO/scripts/muso-stack-read.sh"

setup() {
  TEST_TMPDIR="$(mktemp -d)"
  export TEST_TMPDIR
  mkdir -p "$TEST_TMPDIR/bin"
  export KUBECTL_CALLS="$TEST_TMPDIR/kubectl-calls" CURL_CALLS="$TEST_TMPDIR/curl-calls" CURL_STDIN="$TEST_TMPDIR/curl-stdin"
  : > "$KUBECTL_CALLS"; : > "$CURL_CALLS"; : > "$CURL_STDIN"
  export STUB_RECOVERY="t" STUB_HTTP="200" STUB_SECRET=""
  unset MUSOAI_EVENT_ROUTER_QUERY

  cat > "$TEST_TMPDIR/bin/kubectl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$KUBECTL_CALLS"
case "$*" in
  *"get pods"*clickhouse*)   echo -n "chi-product-analytics-product-0-0-0" ;;
  *"get pods"*role=replica*) echo -n "messaging-pg-pgha-x-0" ;;
  *"get secret"*)            [ -n "$STUB_SECRET" ] && printf '%s' "$STUB_SECRET" | base64 ;;
  *"pg_is_in_recovery"*)     echo "$STUB_RECOVERY" ;;
  *port-forward*)            echo "Forwarding from 127.0.0.1:41234 -> 8081"; exec sleep 30 ;;
  *exec*)                    echo "ok-row" ;;
esac
STUB
  cat > "$TEST_TMPDIR/bin/curl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CURL_CALLS"
cat >> "$CURL_STDIN"
out=""
while [ $# -gt 0 ]; do [ "$1" = "-o" ] && out="$2"; shift; done
[ -n "$out" ] && echo '{"data":{}}' > "$out"
printf '%s' "$STUB_HTTP"
STUB
  chmod +x "$TEST_TMPDIR/bin/kubectl" "$TEST_TMPDIR/bin/curl"
  export PATH="$TEST_TMPDIR/bin:$PATH"
}

teardown() { rm -rf "$TEST_TMPDIR"; }

# ── statement guard ──────────────────────────────────────────────────────────
@test "ch refuses a write statement before calling kubectl" {
  run "$S" ch "INSERT INTO messaging.email_events VALUES (1)"
  [ "$status" -eq 2 ]
  [[ "$output" == *"only one read statement"* ]]
  [ ! -s "$KUBECTL_CALLS" ]
}

@test "ch refuses ';' chaining a second statement" {
  run "$S" ch "SELECT 1; DROP TABLE product_events.events"
  [ "$status" -eq 2 ]
  [[ "$output" == *"one statement per call"* ]]
  [ ! -s "$KUBECTL_CALLS" ]
}

@test "ch allows a trailing ';' and leading comments" {
  run "$S" ch "-- who logged in
/* note */ SELECT count() FROM product_events.events;"
  [ "$status" -eq 0 ]
}

@test "ch always runs clickhouse-client with readonly=1 and fail-closed limits" {
  run "$S" ch "SELECT 1"
  [ "$status" -eq 0 ]
  grep -q -- "clickhouse-client --readonly=1 --max_execution_time=60 --max_result_rows=100000 --result_overflow_mode=throw" "$KUBECTL_CALLS"
}

@test "ch prints nothing when the query fails mid-stream (no partial answer)" {
  cat > "$TEST_TMPDIR/bin/kubectl" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *"get pods"*) echo -n "chi-product-analytics-product-0-0-0" ;;
  *exec*) printf 'number\n1\n2\n'; echo "Code: 396. TOO_MANY_ROWS_OR_BYTES" >&2; exit 140 ;;
esac
STUB
  run --separate-stderr "$S" ch "SELECT number FROM numbers(100001)"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [[ "$stderr" == *"nothing printed"* ]]
}

@test "pg refuses an unknown database" {
  run "$S" pg send "SELECT 1"
  [ "$status" -eq 2 ]
  [[ "$output" == *"notify, preferences or listmonk"* ]]
}

@test "pg refuses a write statement" {
  run "$S" pg preferences "UPDATE prefs.contacts SET email = ''"
  [ "$status" -eq 2 ]
  [ ! -s "$KUBECTL_CALLS" ]
}

@test "pg refuses when the chosen pod is not a hot standby" {
  STUB_RECOVERY="f" run "$S" pg notify "SELECT 1"
  [ "$status" -eq 3 ]
  [[ "$output" == *"not a hot standby"* ]]
  if grep -q "default_transaction_read_only" "$KUBECTL_CALLS"; then false; fi
}

@test "pg reads the replica with a read-only transaction" {
  run "$S" pg notify "SELECT count(*) FROM notify.feed_items"
  [ "$status" -eq 0 ]
  grep -q "role=replica" "$KUBECTL_CALLS"
  grep -q "SET default_transaction_read_only = on" "$KUBECTL_CALLS"
}

# ── router ───────────────────────────────────────────────────────────────────
@test "router refuses an endpoint that is not rebuilt" {
  run "$S" router "/api/2/funnels?e=x"
  [ "$status" -eq 2 ]
  [ ! -s "$KUBECTL_CALLS" ]
}

@test "router refuses an unencoded JSON / shell-ish query" {
  run "$S" router '/api/2/users?x=$(id)'
  [ "$status" -eq 2 ]
}

@test "router fails closed with no credential" {
  run "$S" router "/api/2/realtime"
  [ "$status" -eq 3 ]
  [[ "$output" == *"no router query credential"* ]]
  [ ! -s "$CURL_CALLS" ]
}

@test "router credential goes over stdin, never argv" {
  MUSOAI_EVENT_ROUTER_QUERY="hydra:s3cr3t-value" run "$S" router "/api/2/usersearch?user=123"
  [ "$status" -eq 0 ]
  # Negative asserts must be terminal (bats does not fail on a bare negated grep).
  if grep -q "s3cr3t-value" "$CURL_CALLS"; then false; fi
  if grep -q "s3cr3t-value" "$KUBECTL_CALLS"; then false; fi
  grep -q 'user = "hydra:s3cr3t-value"' "$CURL_STDIN"
  grep -q "http://127.0.0.1:41234/api/2/usersearch?user=123" "$CURL_CALLS"
  if [[ "$output" == *"s3cr3t-value"* ]]; then false; fi
}

@test "router falls back to the hydra-namespace Secret" {
  STUB_SECRET="hydra:from-secret" run "$S" router "/api/2/realtime"
  [ "$status" -eq 0 ]
  grep -q "get secret hydra-event-router-query" "$KUBECTL_CALLS"
  grep -q 'user = "hydra:from-secret"' "$CURL_STDIN"
}

@test "router maps 401 to exit 3 with a credential hint" {
  MUSOAI_EVENT_ROUTER_QUERY="hydra:x" STUB_HTTP=401 run "$S" router "/api/2/realtime"
  [ "$status" -eq 3 ]
  [[ "$output" == *"401"* ]]
}

@test "usage on no args" {
  run "$S"
  [ "$status" -eq 2 ]
}
