#!/usr/bin/env bats
# Tests for scripts/lib/jev.sh, the TypeSafe System One ("Jev") client.
# Hermetic: a fake `curl` shadowed onto PATH (mode selected via
# JEV_FAKE_MODE, exported before `run` per the no-env-prefix-on-run rule),
# throwaway state/shadow dirs, no network, no real API key.
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
JEV="$HYDRA_REPO/scripts/lib/jev.sh"
FIXTURE_OK="$HYDRA_REPO/scripts/tests/fixtures/jev/answers-ok.json"

setup() {
  TEST_TMPDIR="$(mktemp -d)"
  export TEST_TMPDIR
  mkdir -p "$TEST_TMPDIR/bin" "$TEST_TMPDIR/shadow" "$TEST_TMPDIR/data"
  export PATH="$TEST_TMPDIR/bin:$PATH"

  export STATE_FILE="$TEST_TMPDIR/data/state.json"
  export QUESTIONS_FILE="$TEST_TMPDIR/data/questions.json"
  echo '{"foo":"bar"}' > "$STATE_FILE"
  echo '{"q1":{"type":"noul","instructions":"is it a bar?"}}' > "$QUESTIONS_FILE"

  export JEV_SHADOW_DIR="$TEST_TMPDIR/shadow"
  export TYPESAFE_API_KEY="test-key-do-not-print"
  export OPENROUTER_API_KEY="test-or-key-do-not-print"
  export JEV_ENV_FILE="$TEST_TMPDIR/no-such-jev.env"
  export CURL_MARKER="$TEST_TMPDIR/curl-was-called"
  export CURL_URL_FILE="$TEST_TMPDIR/curl-url"
  export CURL_HDR_FILE="$TEST_TMPDIR/curl-auth-header"
  export CURL_MAXTIME_FILE="$TEST_TMPDIR/curl-max-time"
  export CURL_CONNECT_TIMEOUT_FILE="$TEST_TMPDIR/curl-connect-timeout"

  # Fake curl: reads JEV_FAKE_MODE, finds the -o target and -w %{http_code}
  # args, writes the fixture (or an error body) to the -o file, and echoes
  # the http status on stdout (mirroring curl -w behavior with -o set). It
  # also captures the request URL (the final positional arg), the
  # contents of the -H @<file> bearer-token header file, and the values
  # passed to --max-time / --connect-timeout, so tests can assert which
  # endpoint/key/timeouts were used without ever printing the key into test
  # output.
  cat > "$TEST_TMPDIR/bin/curl" <<STUB
#!/bin/bash
: > "$CURL_MARKER"
out=""
args=("\$@")
for ((i=0; i<\${#args[@]}; i++)); do
  if [ "\${args[i]}" = "-o" ]; then
    out="\${args[i+1]}"
  fi
  if [ "\${args[i]}" = "-H" ]; then
    hval="\${args[i+1]}"
    if [ "\${hval:0:1}" = "@" ]; then
      cp "\${hval:1}" "$CURL_HDR_FILE"
    fi
  fi
  if [ "\${args[i]}" = "--max-time" ]; then
    printf '%s' "\${args[i+1]}" > "$CURL_MAXTIME_FILE"
  fi
  if [ "\${args[i]}" = "--connect-timeout" ]; then
    printf '%s' "\${args[i+1]}" > "$CURL_CONNECT_TIMEOUT_FILE"
  fi
done
printf '%s' "\${args[\${#args[@]}-1]}" > "$CURL_URL_FILE"
case "\${JEV_FAKE_MODE:-ok}" in
  ok)
    cat "$FIXTURE_OK" > "\$out"
    echo "200"
    exit 0
    ;;
  timeout)
    exit 28
    ;;
  http500)
    echo '{"error":"internal"}' > "\$out"
    echo "500"
    exit 0
    ;;
  malformed)
    echo '{"nope":1}' > "\$out"
    echo "200"
    exit 0
    ;;
esac
STUB
  chmod +x "$TEST_TMPDIR/bin/curl"
}

teardown() {
  rm -rf "$TEST_TMPDIR"
}

@test "ok: rc 0, answers object on stdout, clean shadow line" {
  export JEV_FAKE_MODE="ok"
  run "$JEV" --surface refund-gate --item-id conv-1 \
    --state-file "$STATE_FILE" --questions-file "$QUESTIONS_FILE" \
    --actual "true" --timeout-ms 200
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.is_refund_eligible.noul == 0.97' >/dev/null

  shadow_file="$JEV_SHADOW_DIR/refund-gate.jsonl"
  [ -f "$shadow_file" ]
  [ "$(wc -l < "$shadow_file" | tr -d '[:space:]')" -eq 1 ]

  line="$(cat "$shadow_file")"
  echo "$line" | jq -e '.rc == 0' >/dev/null
  echo "$line" | jq -e '.http == 200' >/dev/null
  echo "$line" | jq -e '.surface == "refund-gate"' >/dev/null
  echo "$line" | jq -e '.item_id == "conv-1"' >/dev/null
  echo "$line" | jq -e '.actual == "true"' >/dev/null
  echo "$line" | jq -e '(.latency_ms | type) == "number"' >/dev/null
  echo "$line" | jq -e '.answers.is_refund_eligible.noul == 0.97' >/dev/null

  # No secret or state content anywhere in the shadow file.
  # `! cmd` on a non-final line is exempt from set -e and bats reads only the
  # last command, so each forbidden value gets an explicit fail branch.
  for forbidden in "test-key-do-not-print" "foo" "bar"; do
    if grep -q "$forbidden" "$shadow_file"; then
      echo "shadow file leaks: $forbidden" >&2
      false
    fi
  done
}

@test "timeout: rc 2, shadow line records rc 2 with null answers" {
  export JEV_FAKE_MODE="timeout"
  run "$JEV" --surface refund-gate --item-id conv-2 \
    --state-file "$STATE_FILE" --questions-file "$QUESTIONS_FILE" \
    --timeout-ms 200
  [ "$status" -eq 2 ]

  shadow_file="$JEV_SHADOW_DIR/refund-gate.jsonl"
  [ -f "$shadow_file" ]
  line="$(cat "$shadow_file")"
  echo "$line" | jq -e '.rc == 2' >/dev/null
  echo "$line" | jq -e '.answers == null' >/dev/null
}

@test "http500: rc 2" {
  export JEV_FAKE_MODE="http500"
  run "$JEV" --surface refund-gate --item-id conv-3 \
    --state-file "$STATE_FILE" --questions-file "$QUESTIONS_FILE" \
    --timeout-ms 200
  [ "$status" -eq 2 ]
}

@test "malformed: rc 3" {
  export JEV_FAKE_MODE="malformed"
  run "$JEV" --surface refund-gate --item-id conv-4 \
    --state-file "$STATE_FILE" --questions-file "$QUESTIONS_FILE" \
    --timeout-ms 200
  [ "$status" -eq 3 ]
}

@test "oversize state: rc 4, curl never called" {
  export JEV_FAKE_MODE="ok"
  run "$JEV" --surface refund-gate --item-id conv-5 \
    --state-file "$STATE_FILE" --questions-file "$QUESTIONS_FILE" \
    --max-state-bytes 3 --timeout-ms 200
  [ "$status" -eq 4 ]
  [ ! -f "$CURL_MARKER" ]
  # A pre-request failure is still one shadow row (rc 4, answers null), so a
  # caller that keeps hitting the cap shows up in the report as rc≠0, never
  # as silence.
  local line; line="$(tail -1 "$JEV_SHADOW_DIR/refund-gate.jsonl")"
  echo "$line" | jq -e '.rc == 4 and .answers == null and .http == null and .item_id == "conv-5"' >/dev/null
  if grep -q "foo" "$JEV_SHADOW_DIR/refund-gate.jsonl"; then false; fi
}

@test "missing key: rc 5" {
  # Explicit typesafe provider so unsetting TYPESAFE_API_KEY is the key
  # actually consulted (default provider is openrouter, which reads
  # OPENROUTER_API_KEY instead — see the provider tests below).
  export JEV_PROVIDER=typesafe
  unset TYPESAFE_API_KEY
  run "$JEV" --surface refund-gate --item-id conv-6 \
    --state-file "$STATE_FILE" --questions-file "$QUESTIONS_FILE" \
    --timeout-ms 200
  [ "$status" -eq 5 ]
  local line; line="$(tail -1 "$JEV_SHADOW_DIR/refund-gate.jsonl")"
  echo "$line" | jq -e '.rc == 5 and .answers == null and .item_id == "conv-6"' >/dev/null
}

@test "--no-shadow: no shadow file written" {
  export JEV_FAKE_MODE="ok"
  run "$JEV" --surface refund-gate --item-id conv-7 \
    --state-file "$STATE_FILE" --questions-file "$QUESTIONS_FILE" \
    --no-shadow --timeout-ms 200
  [ "$status" -eq 0 ]
  [ ! -f "$JEV_SHADOW_DIR/refund-gate.jsonl" ]
}

@test "unwritable shadow dir: rc 0 and a WARN on stderr" {
  export JEV_FAKE_MODE="ok"
  # A regular file where a directory component belongs makes mkdir -p fail
  # even as root (CI bats runs as ROOT, so chmod-based permission denial
  # doesn't hold -- see docs/lessons/working-in-hydra.md).
  : > "$TEST_TMPDIR/not-a-dir"
  export JEV_SHADOW_DIR="$TEST_TMPDIR/not-a-dir/shadow"
  run "$JEV" --surface refund-gate --item-id conv-8 \
    --state-file "$STATE_FILE" --questions-file "$QUESTIONS_FILE" \
    --timeout-ms 200
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARN"* ]]
}

@test "--actual as a JSON object is stored as an object keyed by question id" {
  export JEV_FAKE_MODE=ok
  run "$JEV" --surface s --item-id o1 --state-file "$STATE_FILE" --questions-file "$QUESTIONS_FILE" \
    --actual '{"q1":"true","q2":"billing"}'
  [ "$status" -eq 0 ]
  run jq -r '.actual | type' "$JEV_SHADOW_DIR/s.jsonl"
  [ "$output" = "object" ]
  run jq -r '.actual.q2' "$JEV_SHADOW_DIR/s.jsonl"
  [ "$output" = "billing" ]
}

@test "--actual as a plain string is stored as a string" {
  export JEV_FAKE_MODE=ok
  run "$JEV" --surface s --item-id s1 --state-file "$STATE_FILE" --questions-file "$QUESTIONS_FILE" --actual true
  [ "$status" -eq 0 ]
  run jq -r '.actual | type' "$JEV_SHADOW_DIR/s.jsonl"
  [ "$output" = "string" ]
}

@test "unreadable state path: rc 5 and a shadow row with null hashes" {
  export JEV_FAKE_MODE=ok
  run "$JEV" --surface refund-gate --item-id conv-9 \
    --state-file "$TEST_TMPDIR/data/does-not-exist.json" --questions-file "$QUESTIONS_FILE" \
    --timeout-ms 200
  [ "$status" -eq 5 ]
  [ ! -f "$CURL_MARKER" ]
  local line; line="$(tail -1 "$JEV_SHADOW_DIR/refund-gate.jsonl")"
  echo "$line" | jq -e '.rc == 5 and .answers == null and .state_sha256 == null and .item_id == "conv-9"' >/dev/null
  # the questions file WAS readable but is hashed only after both checks pass
  echo "$line" | jq -e '.questions_sha256 == null' >/dev/null
}

@test "JEV_MODEL and JEV_TIMEOUT_MS env are honored, CLI flags win" {
  export JEV_FAKE_MODE=timeout   # requested model is what the shadow row carries on failure
  export JEV_MODEL="jev-env-model"
  export JEV_TIMEOUT_MS="100"
  run "$JEV" --surface s --item-id e1 --state-file "$STATE_FILE" --questions-file "$QUESTIONS_FILE"
  [ "$status" -eq 2 ]
  run jq -r 'select(.item_id=="e1") | .model' "$JEV_SHADOW_DIR/s.jsonl"
  [ "$output" = "jev-env-model" ]
  run "$JEV" --surface s --item-id e2 --state-file "$STATE_FILE" --questions-file "$QUESTIONS_FILE" --model jev-cli-model
  [ "$status" -eq 2 ]
  run jq -r 'select(.item_id=="e2") | .model' "$JEV_SHADOW_DIR/s.jsonl"
  [ "$output" = "jev-cli-model" ]
}

@test "--timeout-ms 1500: curl gets fractional --max-time 1.500, --connect-timeout capped to the same 1.500 budget" {
  export JEV_FAKE_MODE=ok
  run "$JEV" --surface s --item-id tm1 --state-file "$STATE_FILE" --questions-file "$QUESTIONS_FILE" \
    --timeout-ms 1500
  [ "$status" -eq 0 ]
  run cat "$CURL_MAXTIME_FILE"
  [ "$output" = "1.500" ]
  run cat "$CURL_CONNECT_TIMEOUT_FILE"
  [ "$output" = "1.500" ]
}

@test "--timeout-ms 200: curl gets --max-time 0.200 and a matching --connect-timeout 0.200" {
  export JEV_FAKE_MODE=ok
  run "$JEV" --surface s --item-id tm2 --state-file "$STATE_FILE" --questions-file "$QUESTIONS_FILE" \
    --timeout-ms 200
  [ "$status" -eq 0 ]
  run cat "$CURL_MAXTIME_FILE"
  [ "$output" = "0.200" ]
  run cat "$CURL_CONNECT_TIMEOUT_FILE"
  [ "$output" = "0.200" ]
}

@test "JEV_TIMEOUT_MS=1000: curl gets --max-time 1.000 and --connect-timeout 1.000" {
  export JEV_FAKE_MODE=ok
  export JEV_TIMEOUT_MS=1000
  run "$JEV" --surface s --item-id tm3 --state-file "$STATE_FILE" --questions-file "$QUESTIONS_FILE"
  [ "$status" -eq 0 ]
  run cat "$CURL_MAXTIME_FILE"
  [ "$output" = "1.000" ]
  run cat "$CURL_CONNECT_TIMEOUT_FILE"
  [ "$output" = "1.000" ]
}

@test "--timeout-ms 5000: curl gets --max-time 5.000, --connect-timeout stays at the 2s default" {
  export JEV_FAKE_MODE=ok
  run "$JEV" --surface s --item-id tm4 --state-file "$STATE_FILE" --questions-file "$QUESTIONS_FILE" \
    --timeout-ms 5000
  [ "$status" -eq 0 ]
  run cat "$CURL_MAXTIME_FILE"
  [ "$output" = "5.000" ]
  run cat "$CURL_CONNECT_TIMEOUT_FILE"
  [ "$output" = "2" ]
}

@test "JEV_TIMEOUT_MS=abc: rc 5 with a shadow row, curl never called" {
  export JEV_FAKE_MODE=ok
  export JEV_TIMEOUT_MS=abc
  run "$JEV" --surface s --item-id k1 --state-file "$STATE_FILE" --questions-file "$QUESTIONS_FILE"
  [ "$status" -eq 5 ]
  [ ! -f "$CURL_MARKER" ]
  run jq -r 'select(.item_id=="k1") | .rc' "$JEV_SHADOW_DIR/s.jsonl"
  [ "$output" = "5" ]
}

@test "--max-state-bytes abc: rc 5, the cap is never silently bypassed" {
  export JEV_FAKE_MODE=ok
  run "$JEV" --surface s --item-id k2 --state-file "$STATE_FILE" --questions-file "$QUESTIONS_FILE" --max-state-bytes abc
  [ "$status" -eq 5 ]
  [ ! -f "$CURL_MARKER" ]
  run jq -r 'select(.item_id=="k2") | .rc' "$JEV_SHADOW_DIR/s.jsonl"
  [ "$output" = "5" ]
}

@test "default provider is openrouter: decisions URL, ~typesafe/jev-latest model, OpenRouter key, provider in shadow" {
  # ok mode: assert URL/key, which the fixture response can't clobber.
  export JEV_FAKE_MODE=ok
  run "$JEV" --surface s --item-id or1 --state-file "$STATE_FILE" --questions-file "$QUESTIONS_FILE"
  [ "$status" -eq 0 ]
  [ "$(cat "$CURL_URL_FILE")" = "https://openrouter.ai/api/alpha/decisions" ]
  grep -q "Bearer $OPENROUTER_API_KEY" "$CURL_HDR_FILE"
  run jq -r 'select(.item_id=="or1") | .provider' "$JEV_SHADOW_DIR/s.jsonl"
  [ "$output" = "openrouter" ]

  # timeout mode: the shadow row's model is the *requested* model (a
  # success response's own .model field would otherwise mask the default —
  # same reasoning as the existing "JEV_MODEL env honored" test).
  export JEV_FAKE_MODE=timeout
  run "$JEV" --surface s --item-id or1b --state-file "$STATE_FILE" --questions-file "$QUESTIONS_FILE" --timeout-ms 200
  [ "$status" -eq 2 ]
  run jq -r 'select(.item_id=="or1b") | .model' "$JEV_SHADOW_DIR/s.jsonl"
  [ "$output" = "~typesafe/jev-latest" ]
}

@test "JEV_PROVIDER=typesafe: TypeSafe URL, jev-latest model, TypeSafe key, provider in shadow" {
  export JEV_PROVIDER=typesafe
  export JEV_FAKE_MODE=ok
  run "$JEV" --surface s --item-id ts1 --state-file "$STATE_FILE" --questions-file "$QUESTIONS_FILE"
  [ "$status" -eq 0 ]
  [ "$(cat "$CURL_URL_FILE")" = "https://api.typesafe.ai/v1/systemone" ]
  grep -q "Bearer $TYPESAFE_API_KEY" "$CURL_HDR_FILE"
  run jq -r 'select(.item_id=="ts1") | .provider' "$JEV_SHADOW_DIR/s.jsonl"
  [ "$output" = "typesafe" ]

  export JEV_FAKE_MODE=timeout
  run "$JEV" --surface s --item-id ts1b --state-file "$STATE_FILE" --questions-file "$QUESTIONS_FILE" --timeout-ms 200
  [ "$status" -eq 2 ]
  run jq -r 'select(.item_id=="ts1b") | .model' "$JEV_SHADOW_DIR/s.jsonl"
  [ "$output" = "jev-latest" ]
}

@test "explicit JEV_MODEL and --model still win under the default openrouter provider" {
  export JEV_FAKE_MODE=timeout
  export JEV_MODEL="typesafe/jev-1.13"
  run "$JEV" --surface s --item-id or2 --state-file "$STATE_FILE" --questions-file "$QUESTIONS_FILE" --timeout-ms 200
  [ "$status" -eq 2 ]
  run jq -r 'select(.item_id=="or2") | .model' "$JEV_SHADOW_DIR/s.jsonl"
  [ "$output" = "typesafe/jev-1.13" ]

  unset JEV_MODEL
  run "$JEV" --surface s --item-id or3 --state-file "$STATE_FILE" --questions-file "$QUESTIONS_FILE" --timeout-ms 200 --model jev-cli-override
  [ "$status" -eq 2 ]
  run jq -r 'select(.item_id=="or3") | .model' "$JEV_SHADOW_DIR/s.jsonl"
  [ "$output" = "jev-cli-override" ]
}

@test "JEV_PROVIDER=nope: rc 5, a shadow row, curl never called" {
  export JEV_FAKE_MODE=ok
  export JEV_PROVIDER=nope
  run "$JEV" --surface s --item-id bad1 --state-file "$STATE_FILE" --questions-file "$QUESTIONS_FILE"
  [ "$status" -eq 5 ]
  [ ! -f "$CURL_MARKER" ]
  run jq -r 'select(.item_id=="bad1") | .rc' "$JEV_SHADOW_DIR/s.jsonl"
  [ "$output" = "5" ]
}

@test "openrouter with only TYPESAFE_API_KEY set: rc 5, message names OPENROUTER_API_KEY" {
  export JEV_FAKE_MODE=ok
  unset OPENROUTER_API_KEY
  run "$JEV" --surface s --item-id nokey1 --state-file "$STATE_FILE" --questions-file "$QUESTIONS_FILE"
  [ "$status" -eq 5 ]
  [ ! -f "$CURL_MARKER" ]
  [[ "$output" == *"OPENROUTER_API_KEY"* ]]
  run jq -r 'select(.item_id=="nokey1") | .rc' "$JEV_SHADOW_DIR/s.jsonl"
  [ "$output" = "5" ]
}

@test "--surface path traversal: rc 5, nothing written outside the shadow dir" {
  export JEV_FAKE_MODE=ok
  run "$JEV" --surface ../escape --item-id esc1 \
    --state-file "$STATE_FILE" --questions-file "$QUESTIONS_FILE" \
    --timeout-ms 200
  [ "$status" -eq 5 ]
  [ ! -f "$CURL_MARKER" ]
  run find "$TEST_TMPDIR" -name 'escape.jsonl'
  [ -z "$output" ]
  [ ! -f "$TEST_TMPDIR/escape.jsonl" ]
}

@test "--surface with whitespace: rc 5" {
  export JEV_FAKE_MODE=ok
  run "$JEV" --surface 'a b' --item-id ws1 \
    --state-file "$STATE_FILE" --questions-file "$QUESTIONS_FILE" \
    --timeout-ms 200
  [ "$status" -eq 5 ]
  [ ! -f "$CURL_MARKER" ]
}

@test "--surface with a leading dot: rc 5" {
  export JEV_FAKE_MODE=ok
  run "$JEV" --surface .hidden --item-id dot1 \
    --state-file "$STATE_FILE" --questions-file "$QUESTIONS_FILE" \
    --timeout-ms 200
  [ "$status" -eq 5 ]
  [ ! -f "$CURL_MARKER" ]
}

@test "--surface with dots/underscores/dashes is still valid" {
  export JEV_FAKE_MODE=ok
  run "$JEV" --surface 'refund-gate.v2_x' --item-id valid1 \
    --state-file "$STATE_FILE" --questions-file "$QUESTIONS_FILE" \
    --timeout-ms 200
  [ "$status" -eq 0 ]
  [ -f "$JEV_SHADOW_DIR/refund-gate.v2_x.jsonl" ]
}

@test "--item-id with a newline: rc 5, no shadow row" {
  export JEV_FAKE_MODE=ok
  run "$JEV" --surface refund-gate --item-id "$(printf 'a\nb')" \
    --state-file "$STATE_FILE" --questions-file "$QUESTIONS_FILE" \
    --timeout-ms 200
  [ "$status" -eq 5 ]
  [ ! -f "$CURL_MARKER" ]
  [ ! -f "$JEV_SHADOW_DIR/refund-gate.jsonl" ]
}
