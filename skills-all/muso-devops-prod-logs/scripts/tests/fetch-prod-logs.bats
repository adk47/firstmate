#!/usr/bin/env bats
# Tests for fetch-prod-logs.sh — the deterministic read-only prod log fetcher.
#
# kubectl is PATH-stubbed (never touches a real cluster) and records every
# invocation so the read-only guarantee ("only `logs` and `get` verbs, ever")
# is asserted mechanically, not by review.
bats_require_minimum_version 1.5.0

SKILL_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
FETCH="$SKILL_DIR/scripts/fetch-prod-logs.sh"

setup() {
  TEST_TMPDIR="$(mktemp -d)"
  export TEST_TMPDIR
  mkdir -p "$TEST_TMPDIR/bin" "$TEST_TMPDIR/config"

  export KUBECTL_STUB_CALLS="$TEST_TMPDIR/kubectl-calls.log"
  export KUBECTL_STUB_LOGFILE="$TEST_TMPDIR/fixture-logs.txt"
  export KUBECTL_STUB_PODS="fixture-pod-1"

  cat > "$TEST_TMPDIR/bin/kubectl" <<'STUB'
#!/bin/bash
echo "$*" >> "$KUBECTL_STUB_CALLS"
case "$1" in
  get)
    case "$2" in
      deploy|deployment|deployments)
        echo '{"spec":{"replicas":'"${KUBECTL_STUB_REPLICAS:-1}"',"selector":{"matchLabels":{"app":"'"$3"'"}}}}'
        ;;
      pods)
        if [[ "$*" == *"-o name"* ]]; then
          for p in $KUBECTL_STUB_PODS; do echo "pod/$p"; done
        else
          echo "NAME READY STATUS"
          for p in $KUBECTL_STUB_PODS; do echo "$p 1/1 Running"; done
        fi
        ;;
      events)
        echo "5m Normal Pulled pod/fixture-pod-1 image pulled"
        ;;
      *) echo "unexpected get resource: $2" >&2; exit 97 ;;
    esac
    ;;
  logs)
    # $4 is the pod name (logs -n NS POD ...)
    if [[ " ${KUBECTL_STUB_LOGS_FAIL_PODS:-} " == *" $4 "* ]]; then
      echo "Error from server (Forbidden): pods \"$4\" is forbidden" >&2
      exit 1
    fi
    cat "$KUBECTL_STUB_LOGFILE"
    ;;
  *) echo "unexpected kubectl verb: $1" >&2; exit 97 ;;
esac
STUB
  chmod +x "$TEST_TMPDIR/bin/kubectl"
  export KUBECTL_BIN="$TEST_TMPDIR/bin/kubectl"

  printf '%s\n' "muso-prod core-backend-api" > "$TEST_TMPDIR/config/deployments.txt"
  printf '%s\n' fatal uncaught unhandled exception error > "$TEST_TMPDIR/config/error-patterns.txt"
  export PROD_LOGS_CONFIG_DIR="$TEST_TMPDIR/config"

  cat > "$KUBECTL_STUB_LOGFILE" <<'EOF'
2026-06-09T10:00:00Z ERROR something broke password=supersecret123
2026-06-09T10:00:01Z info all good here
2026-06-09T10:00:02Z Uncaught TypeError sent token xoxb-1234567890-abcdef
EOF
}

teardown() { rm -rf "$TEST_TMPDIR"; }

@test "unknown namespace → exit 3" {
  run bash "$FETCH" -n bogus-ns -d core-backend-api
  [ "$status" -eq 3 ]
  [[ "$output" == *"not allowed"* ]]
}

@test "deployment not in allowlist → exit 4 with --any-deploy hint" {
  run bash "$FETCH" -n muso-prod -d not-listed
  [ "$status" -eq 4 ]
  [[ "$output" == *"--any-deploy"* ]]
}

@test "--any-deploy bypasses the allowlist (namespace gate still applies)" {
  run bash "$FETCH" -n muso-prod -d not-listed --any-deploy
  [ "$status" -eq 0 ]
  run bash "$FETCH" -n bogus-ns -d not-listed --any-deploy
  [ "$status" -eq 3 ]
}

@test "default pattern keeps error lines, drops info lines" {
  run bash "$FETCH" -n muso-prod -d core-backend-api
  [ "$status" -eq 0 ]
  [[ "$output" == *"ERROR something broke"* ]]
  [[ "$output" == *"Uncaught TypeError"* ]]
  [[ "$output" != *"all good here"* ]]
}

@test "--no-filter keeps every line" {
  run bash "$FETCH" -n muso-prod -d core-backend-api --no-filter
  [ "$status" -eq 0 ]
  [[ "$output" == *"all good here"* ]]
}

@test "zero matching lines → empty stdout, exit 0 (watchdog contract)" {
  run bash "$FETCH" -n muso-prod -d core-backend-api --pattern "no-such-marker"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "secrets are redacted: password= value and xoxb token never reach stdout" {
  run bash "$FETCH" -n muso-prod -d core-backend-api
  [ "$status" -eq 0 ]
  [[ "$output" != *"supersecret123"* ]]
  [[ "$output" != *"xoxb-1234567890-abcdef"* ]]
  [[ "$output" == *"[REDACTED]"* ]]
}

@test "multi-replica: each pod is fetched and lines carry the pod prefix" {
  export KUBECTL_STUB_PODS="cb-api-aaa cb-api-bbb"
  run bash "$FETCH" -n muso-prod -d core-backend-api
  [ "$status" -eq 0 ]
  [[ "$output" == *"[cb-api-aaa]"* ]]
  [[ "$output" == *"[cb-api-bbb]"* ]]
  # both pods got a logs call
  [ "$(grep -c '^logs ' "$KUBECTL_STUB_CALLS")" -eq 2 ]
}

@test "read-only guarantee: kubectl only ever sees 'logs' and 'get' verbs" {
  bash "$FETCH" -n muso-prod -d core-backend-api >/dev/null
  bash "$FETCH" -n muso-prod --events >/dev/null
  bash "$FETCH" -n muso-prod --pods >/dev/null
  run grep -cvE '^(logs|get) ' "$KUBECTL_STUB_CALLS"
  [[ "$output" == "0" ]]
}

@test "--out writes the full result to a file and prints a one-line summary" {
  run bash "$FETCH" -n muso-prod -d core-backend-api --out "$TEST_TMPDIR/result.txt"
  [ "$status" -eq 0 ]
  [[ "$output" == *"wrote"*"$TEST_TMPDIR/result.txt"* ]]
  grep -q "ERROR something broke" "$TEST_TMPDIR/result.txt"
}

@test "byte cap truncates keeping the most recent bytes" {
  for i in $(seq 1 200); do
    echo "2026-06-09T10:00:00Z ERROR filler line number $i"
  done > "$KUBECTL_STUB_LOGFILE"
  PROD_LOGS_MAX_BYTES=500 run bash "$FETCH" -n muso-prod -d core-backend-api
  [ "$status" -eq 0 ]
  [[ "$output" == *"TRUNCATED"* ]]
  [[ "$output" == *"number 200"* ]]   # tail survives
  [[ "$output" != *"number 1 "* ]]    # head is gone
}

@test "--exclude-pattern drops matching lines BEFORE the byte cap" {
  # Benign data lines that match the include pattern (a song named "fatal"
  # inside an INFO-level payload dump) must be excluded pre-cap, or their
  # bulk trips truncation and the real error drowns in mid-line fragments
  # (live finding, industry-proc-raw-v2, 2026-06-12).
  {
    for i in $(seq 1 200); do
      echo "2026-06-09T10:00:00Z INFO: Processed in 0.03 seconds, message: {\"entity_name\": \"Te Ves Fatal\", \"row\": $i}"
    done
    echo "2026-06-09T10:00:01Z FATAL: real crash"
  } > "$KUBECTL_STUB_LOGFILE"
  PROD_LOGS_MAX_BYTES=2000 run bash "$FETCH" -n muso-prod -d core-backend-api \
    --pattern fatal --exclude-pattern '^\[[^]]+\][[:space:]]+[^[:space:]]+[[:space:]]+info:[[:space:]]'
  [ "$status" -eq 0 ]
  [[ "$output" == *"FATAL: real crash"* ]]
  [[ "$output" != *"Te Ves Fatal"* ]]
  [[ "$output" != *"TRUNCATED"* ]]
}

@test "invalid --exclude-pattern (bad ERE) → fail-closed exit 2, not silent empty" {
  run bash "$FETCH" -n muso-prod -d core-backend-api --exclude-pattern '(unbalanced'
  [ "$status" -eq 2 ]
  [[ "$output" == *"invalid --exclude-pattern"* ]]
}

@test "scaled-to-zero deployment → empty stdout, exit 0 (not a fetch failure)" {
  # Autoscaled IDP fleets sit at 0 replicas between batches; that is healthy,
  # not "watchdog is blind" (which would page #prod-alerts every cooldown).
  KUBECTL_STUB_REPLICAS=0 KUBECTL_STUB_PODS="" run bash "$FETCH" -n muso-prod -d core-backend-api
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "replicas desired but no pods found → still exit 5 (real blindness)" {
  KUBECTL_STUB_REPLICAS=3 KUBECTL_STUB_PODS="" run bash "$FETCH" -n muso-prod -d core-backend-api
  [ "$status" -eq 5 ]
  [[ "$output" == *"no pods found"* ]]
}

@test "kubectl logs failure → exit 5, error on stderr (never silently empty)" {
  export KUBECTL_STUB_LOGS_FAIL_PODS="fixture-pod-1"
  run bash "$FETCH" -n muso-prod -d core-backend-api
  [ "$status" -eq 5 ]
  [[ "$output" == *"kubectl logs failed for pod fixture-pod-1"* ]]
}

@test "partial pod failure → good pod's lines still delivered, then exit 5" {
  export KUBECTL_STUB_PODS="cb-api-aaa cb-api-bbb"
  export KUBECTL_STUB_LOGS_FAIL_PODS="cb-api-bbb"
  run bash "$FETCH" -n muso-prod -d core-backend-api
  [ "$status" -eq 5 ]
  [[ "$output" == *"[cb-api-aaa]"*"ERROR something broke"* ]]
  [[ "$output" == *"kubectl logs failed for pod cb-api-bbb"* ]]
}

@test "--events works and stays namespace-gated" {
  run bash "$FETCH" -n muso-prod --events
  [ "$status" -eq 0 ]
  [[ "$output" == *"Pulled"* ]]
  run bash "$FETCH" -n bogus --events
  [ "$status" -eq 3 ]
}

@test "--list prints the allowlist rows" {
  run bash "$FETCH" --list
  [ "$status" -eq 0 ]
  [[ "$output" == *"muso-prod core-backend-api"* ]]
}

@test "missing patterns config → fail-closed exit 6" {
  rm "$TEST_TMPDIR/config/error-patterns.txt"
  run bash "$FETCH" -n muso-prod -d core-backend-api
  [ "$status" -eq 6 ]
}

@test "unknown flag → exit 2" {
  run bash "$FETCH" --bogus
  [ "$status" -eq 2 ]
}
