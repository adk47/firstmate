#!/usr/bin/env bats
# Tests for scripts/prod-log-alert-watchdog.sh — the deterministic prod-log
# error alerter posting to #prod-alerts (C0BA8QMV3ME).
#
# PATH-shadows muso (a real Slack send during a test must never page
# #prod-alerts) and replaces fetch-prod-logs.sh with a fixture-emitting stub
# via PROD_LOG_FETCH_BIN — kubectl is never touched. Secret redaction is NOT
# asserted here because it lives in fetch-prod-logs.sh (every real watchdog
# line passes through it); see fetch-prod-logs.bats.
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
WD="$HYDRA_REPO/scripts/prod-log-alert-watchdog.sh"

setup() {
  TEST_TMPDIR="$(mktemp -d)"
  export TEST_TMPDIR
  mkdir -p "$TEST_TMPDIR/bin" "$TEST_TMPDIR/config" "$TEST_TMPDIR/fixtures"

  # muso stub: record argv, capture --text; WD_MUSO_FAIL=1 makes it exit 1 —
  # the CLI decodes Slack's HTTP-200 ok:false trap itself, so a non-zero exit
  # IS the "not delivered" signal (scripts no longer parse a response body).
  unset MUSO_SLACK_BOT_TOKEN_DEVOPS
  export MUSO_SLACK_ENV_FILE="$TEST_TMPDIR/muso-slack.env"
  echo 'MUSO_SLACK_BOT_TOKEN_DEVOPS=xoxb-test' > "$MUSO_SLACK_ENV_FILE"
  export STUB_CALLS="$TEST_TMPDIR/muso-calls"
  : > "$STUB_CALLS"
  cat > "$TEST_TMPDIR/bin/muso" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_CALLS"
[ "${WD_MUSO_FAIL:-0}" = "1" ] && exit 1
prev=""
for a in "$@"; do
  [ "$prev" = "--text" ] && printf '%s' "$a" > "$WD_TEST_CAPTURE"
  prev="$a"
done
echo '{"channel":"C0TEST","ts":"1717171717.000100"}'
STUB
  # flock shim: macOS has no flock(1); use the real one when present (Linux CI).
  cat > "$TEST_TMPDIR/bin/flock" <<'STUB'
#!/bin/bash
[ -x /usr/bin/flock ] && exec /usr/bin/flock "$@"
exit 0
STUB
  chmod +x "$TEST_TMPDIR/bin/muso" "$TEST_TMPDIR/bin/flock"
  PATH="$TEST_TMPDIR/bin:$PATH"; export PATH
  export WD_TEST_CAPTURE="$TEST_TMPDIR/last-text"

  # fetch stub: watchdog invokes `fetch-prod-logs.sh -n NS -d DEP ...`;
  # emit the fixture file for that ns/dep if present.
  cat > "$TEST_TMPDIR/bin/fetch-stub.sh" <<'STUB'
#!/bin/bash
ns="$2"; dep="$4"
if [ "${FETCH_STUB_EXIT:-0}" != "0" ]; then
  echo "ERROR: kubectl get deploy failed: connection refused" >&2
  exit "$FETCH_STUB_EXIT"
fi
f="$FETCH_STUB_DIR/${ns}__${dep}"
[ -f "$f" ] && cat "$f"
exit 0
STUB
  chmod +x "$TEST_TMPDIR/bin/fetch-stub.sh"
  export FETCH_STUB_DIR="$TEST_TMPDIR/fixtures"

  printf '%s\n' "muso-prod core-backend-api" "muso-prod core-backend-worker" \
    > "$TEST_TMPDIR/config/deployments.txt"
  printf '%s\n' fatal uncaught unhandled exception \
    > "$TEST_TMPDIR/config/alert-patterns.txt"

  export PROD_LOG_FETCH_BIN="$TEST_TMPDIR/bin/fetch-stub.sh"
  export PROD_LOG_ALERT_CONFIG_DIR="$TEST_TMPDIR/config"
  export PROD_LOG_ALERT_STATE_FILE="$TEST_TMPDIR/state.json"
  export PROD_LOG_ALERT_LOCKFILE="$TEST_TMPDIR/wd.lock"
  export PROD_LOG_ALERT_SKIP_HOST_GUARD=1
}

teardown() { rm -rf "$TEST_TMPDIR"; }

# Helper: write a fixture log for ns/dep from stdin.
fixture() { cat > "$FETCH_STUB_DIR/$1__$2"; }

@test "clean prod → no post, exit 0" {
  run bash "$WD"
  [ "$status" -eq 0 ]
  [[ "$output" == *"no new prod log errors"* ]]
  [ ! -f "$WD_TEST_CAPTURE" ]
}

@test "fresh error → one consolidated post to C0BA8QMV3ME as devops bot" {
  fixture muso-prod core-backend-api <<'EOF'
[cb-api-aaa] 2026-06-09T10:00:00Z Uncaught TypeError: boom at handler.js:42
EOF
  run bash "$WD"
  [ "$status" -eq 0 ]
  [ "$(grep -c 'slack send' "$STUB_CALLS")" -eq 1 ]
  grep -q -- '--bot devops' "$STUB_CALLS"
  grep -q -- '--channel C0BA8QMV3ME' "$STUB_CALLS"
  grep -q -- '--requester' "$STUB_CALLS"
  [ -f "$WD_TEST_CAPTURE" ]
  grep -q 'core-backend-api' "$WD_TEST_CAPTURE"
  grep -q 'Uncaught TypeError' "$WD_TEST_CAPTURE"
}

@test "dedupe: the same error does not re-post on the next tick" {
  fixture muso-prod core-backend-api <<'EOF'
[cb-api-aaa] 2026-06-09T10:00:00Z Uncaught TypeError: boom at handler.js:42
EOF
  bash "$WD" >/dev/null
  rm -f "$WD_TEST_CAPTURE"
  # next tick: same logical line, different pod/timestamp/ids
  fixture muso-prod core-backend-api <<'EOF'
[cb-api-bbb] 2026-06-09T10:05:00Z Uncaught TypeError: boom at handler.js:42
EOF
  run bash "$WD"
  [ "$status" -eq 0 ]
  [[ "$output" == *"no new prod log errors"* ]]
  [ ! -f "$WD_TEST_CAPTURE" ]
}

@test "cooldown expiry → the same error re-alerts" {
  fixture muso-prod core-backend-api <<'EOF'
[cb-api-aaa] 2026-06-09T10:00:00Z Uncaught TypeError: boom
EOF
  bash "$WD" >/dev/null
  rm -f "$WD_TEST_CAPTURE"
  # age every fingerprint past the 6h cooldown
  python3 -c "
import json
p = '$PROD_LOG_ALERT_STATE_FILE'
s = json.load(open(p))
json.dump({k: v - 25200 for k, v in s.items()}, open(p, 'w'))
"
  run bash "$WD"
  [ "$status" -eq 0 ]
  [ -f "$WD_TEST_CAPTURE" ]
}

@test "failed Slack delivery → state NOT advanced, retries next tick" {
  fixture muso-prod core-backend-api <<'EOF'
[cb-api-aaa] 2026-06-09T10:00:00Z fatal: db connection lost
EOF
  WD_MUSO_FAIL=1 run bash "$WD"
  [ "$status" -eq 0 ]
  [[ "$output" == *"state not advanced"* ]]
  rm -f "$WD_TEST_CAPTURE"
  # delivery works now → the SAME error must post (it was never delivered)
  run bash "$WD"
  [ "$status" -eq 0 ]
  [ -f "$WD_TEST_CAPTURE" ]
}

@test "dry-run: prints the block, never calls muso, still advances state" {
  fixture muso-prod core-backend-api <<'EOF'
[cb-api-aaa] 2026-06-09T10:00:00Z unhandled promise rejection: x
EOF
  run bash "$WD" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"DRY-RUN"* ]]
  [[ "$output" == *"unhandled promise rejection"* ]]
  [ ! -f "$WD_TEST_CAPTURE" ]
  run bash "$WD" --dry-run
  [[ "$output" == *"no new prod log errors"* ]]
}

@test "near-identical lines collapse to one bullet with a count" {
  fixture muso-prod core-backend-api <<'EOF'
[cb-api-aaa] 2026-06-09T10:00:00Z Uncaught TypeError: boom req=111
[cb-api-aaa] 2026-06-09T10:00:01Z Uncaught TypeError: boom req=222
[cb-api-bbb] 2026-06-09T10:00:02Z Uncaught TypeError: boom req=333
EOF
  run bash "$WD" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"(x3)"* ]]
  bullets="$(printf '%s\n' "$output" | grep -c '^• ' || true)"
  [ "$bullets" -eq 1 ]
}

@test "errors on two deployments → one post, both grouped" {
  fixture muso-prod core-backend-api <<'EOF'
[a] 2026-06-09T10:00:00Z fatal: one
EOF
  fixture muso-prod core-backend-worker <<'EOF'
[b] 2026-06-09T10:00:00Z exception: two
EOF
  run bash "$WD" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"2 deployment(s)"* ]]
  [[ "$output" == *"muso-prod/core-backend-api"* ]]
  [[ "$output" == *"muso-prod/core-backend-worker"* ]]
}

@test "fetch failure → alerts that the watchdog is blind to that deployment" {
  FETCH_STUB_EXIT=5 run bash "$WD" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"log fetch FAILED"* ]]
  [[ "$output" == *"core-backend-api"* ]]
}

@test "fetch-failure alerts are cooldown-deduped too" {
  FETCH_STUB_EXIT=5 bash "$WD" --dry-run >/dev/null
  FETCH_STUB_EXIT=5 run bash "$WD" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"no new prod log errors"* ]]
}

@test "Slack control chars in log lines are escaped (no <!channel> injection)" {
  fixture muso-prod core-backend-api <<'EOF'
[cb-api-aaa] 2026-06-09T10:00:00Z fatal: user payload <!channel> <@U123> <https://evil.example|click>
EOF
  run bash "$WD"
  [ "$status" -eq 0 ]
  [ -f "$WD_TEST_CAPTURE" ]
  run python3 -c "
t = open('$WD_TEST_CAPTURE').read()
print('<!channel>' not in t and '<@U123>' not in t and '<https://evil.example' not in t)
print('&lt;!channel&gt;' in t)
"
  [[ "$output" == *"True"*"True"* ]]
}

@test "exclude patterns drop known-benign noise before fingerprinting" {
  printf '%s\n' '[[:space:]]debug:[[:space:]]' > "$TEST_TMPDIR/config/alert-exclude-patterns.txt"
  fixture muso-prod core-backend-api <<'EOF'
[cb-api-aaa] 2026-06-09T10:00:00Z debug: Executing SQL with EXCEPTION WHEN clause
[cb-api-aaa] 2026-06-09T10:00:01Z fatal: real breakage
EOF
  run bash "$WD" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"real breakage"* ]]
  [[ "$output" != *"Executing SQL"* ]]
}

@test "missing exclude file → no exclusion, alerts still fire" {
  rm -f "$TEST_TMPDIR/config/alert-exclude-patterns.txt"
  fixture muso-prod core-backend-api <<'EOF'
[cb-api-aaa] 2026-06-09T10:00:00Z fatal: still alerts
EOF
  run bash "$WD" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"still alerts"* ]]
}

@test "missing alert-patterns config → fail-closed exit 2" {
  rm "$TEST_TMPDIR/config/alert-patterns.txt"
  run bash "$WD" --dry-run
  [ "$status" -eq 2 ]
}

@test "unknown flag → exit 2" {
  run bash "$WD" --bogus
  [ "$status" -eq 2 ]
}
