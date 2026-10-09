#!/usr/bin/env bats
# scripts/provision-peer-labels.sh -> wait_for_gateway()
#
# The warm-up budget is wall-clock, not a probe count. A probe that never
# answers runs its full --timeout before it fails, so counting probes lets the
# real wait run several times the number the ERROR line reports. These tests
# run the REAL script against a stub gateway CLI that always fails after 2s,
# the way a timed-out probe does.
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
SCRIPT="$HYDRA_REPO/scripts/provision-peer-labels.sh"

setup() {
  TEST_TMPDIR="$(mktemp -d)"; export TEST_TMPDIR
  # The script hardcodes /root/.openclaw-<profile> and sources lib/ next to
  # itself. Copy both, and point only the home directory at the temp tree.
  mkdir -p "$TEST_TMPDIR/home" "$TEST_TMPDIR/scripts"
  cp -R "$HYDRA_REPO/scripts/lib" "$TEST_TMPDIR/scripts/lib"
  sed "s|^OPENCLAW_HOME=.*|OPENCLAW_HOME=\"$TEST_TMPDIR/home\"|" \
    "$SCRIPT" > "$TEST_TMPDIR/scripts/provision-peer-labels.sh"
  chmod +x "$TEST_TMPDIR/scripts/provision-peer-labels.sh"
  echo '{"gateway":{"auth":{"token":"t"}}}' > "$TEST_TMPDIR/home/openclaw.json"

  # Stub gateway CLI: every health probe times out after 2s and fails.
  # Each attempt appends a line so the probe count is observable.
  PROBES="$TEST_TMPDIR/probes"; export PROBES
  : > "$PROBES"
  cat > "$TEST_TMPDIR/openclaw-stub" <<'STUB'
#!/usr/bin/env bash
echo probe >> "$PROBES"
sleep 2
exit 1
STUB
  chmod +x "$TEST_TMPDIR/openclaw-stub"
  export OPENCLAW_BIN="$TEST_TMPDIR/openclaw-stub"
  export HYDRA_MAINTENANCE_FLAG="$TEST_TMPDIR/no-such-flag"
}

teardown() {
  rm -rf "$TEST_TMPDIR"
}

@test "default budget is 180s and overridable via PEER_LABELS_WAIT_SECS" {
  # Assert the literal default: a 180s run is too slow for a unit test.
  run grep -n 'PEER_LABELS_WAIT_SECS="${PEER_LABELS_WAIT_SECS:-180}"' "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "timeout ERROR names the overridden budget, not a hardcoded 30s" {
  run env PEER_LABELS_WAIT_SECS=3 "$TEST_TMPDIR/scripts/provision-peer-labels.sh" main
  [ "$status" -eq 1 ]
  [[ "$output" == *"did not respond within 3s"* ]]
  [[ "$output" != *"within 30s"* ]]
}

@test "budget is wall-clock: a slow probe cannot stretch the wait past the budget" {
  # Budget 3s with 2s probes. A probe-count loop would make 3 probes and run
  # about 9s. A wall-clock deadline stops after about 3s, plus one probe.
  start=$SECONDS
  run env PEER_LABELS_WAIT_SECS=3 "$TEST_TMPDIR/scripts/provision-peer-labels.sh" main
  elapsed=$(( SECONDS - start ))
  [ "$status" -eq 1 ]
  [ "$elapsed" -le 6 ]
}

@test "a non-numeric budget fails loudly before any probe is sent" {
  run env PEER_LABELS_WAIT_SECS=abc "$TEST_TMPDIR/scripts/provision-peer-labels.sh" main
  [ "$status" -eq 2 ]
  [[ "$output" == *"PEER_LABELS_WAIT_SECS must be a positive integer"* ]]
  [ "$(wc -l < "$PROBES" | tr -d ' ')" -eq 0 ]
}
