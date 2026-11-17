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
  export HYDRA_DEPLOY_WINDOW_FLAG="$TEST_TMPDIR/no-such-window"
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

@test "inside a deploy window it stands down: exit 0, logged, no gateway RPC" {
  jq -n --argjson e "$(( $(date -u +%s) + 600 ))" '{reason:"deploy gateway warm-up",expires_epoch:$e}' > "$HYDRA_DEPLOY_WINDOW_FLAG"
  run env PEER_LABELS_WAIT_SECS=3 "$TEST_TMPDIR/scripts/provision-peer-labels.sh" main
  [ "$status" -eq 0 ]
  [[ "$output" == *"deploy window: deploy gateway warm-up - skipping"* ]]
  [ "$(wc -l < "$PROBES" | tr -d ' ')" -eq 0 ]
}

@test "outside the window (absent or expired) the gateway is still probed" {
  # An always-on window would be a silent monitoring outage.
  run env PEER_LABELS_WAIT_SECS=3 "$TEST_TMPDIR/scripts/provision-peer-labels.sh" main
  [ "$status" -eq 1 ]
  [ "$(wc -l < "$PROBES" | tr -d ' ')" -ge 1 ]
  : > "$PROBES"
  jq -n --argjson e "$(( $(date -u +%s) - 60 ))" '{reason:"old",expires_epoch:$e}' > "$HYDRA_DEPLOY_WINDOW_FLAG"
  run env PEER_LABELS_WAIT_SECS=3 "$TEST_TMPDIR/scripts/provision-peer-labels.sh" main
  [ "$status" -eq 1 ]
  [ "$(wc -l < "$PROBES" | tr -d ' ')" -ge 1 ]
}

# A gateway that answers health and records every sessions.create it is sent.
answering_gateway() {
  CALLS="$TEST_TMPDIR/calls"; export CALLS
  : > "$CALLS"
  cat > "$TEST_TMPDIR/openclaw-stub" <<'STUB'
#!/usr/bin/env bash
case " $* " in
  *" sessions.create "*) echo "create $*" >> "$CALLS"; echo '{"ok":true}' ;;
esac
exit 0
STUB
  chmod +x "$TEST_TMPDIR/openclaw-stub"
}

@test "main's peer map names only agents openclaw-main.json configures (support is edge-only since #352)" {
  # Every peer under main must be a main agent, or each 5-min tick sends main a
  # sessions.create it answers with: Unknown agent id "<peer>".
  peers=$(awk '/^  main\)/{m=1;next} m&&/^    \)/{exit} m&&match($0,/\[[a-z]+\]/){print substr($0,RSTART+1,RLENGTH-2)}' "$SCRIPT" | sort)
  agents=$(jq -r '.agents.list[].id' "$HYDRA_REPO/openclaw-main.json" | sort)
  [ -n "$peers" ]
  extra=$(comm -23 <(echo "$peers") <(echo "$agents"))
  [ -z "$extra" ] || { echo "peers main does not configure: $extra"; false; }
}

@test "a peer the profile's agents.list does not name gets no sessions.create" {
  answering_gateway
  # A main roster without cto: the script must skip it, never ask the gateway to create it.
  jq -n '{gateway:{auth:{token:"t"}},agents:{list:[{id:"clio"},{id:"ceo"},{id:"cmo"},{id:"qa"},{id:"finance"},{id:"operations"},{id:"devops"},{id:"scout"}]}}' \
    > "$TEST_TMPDIR/home/openclaw.json"
  run env PEER_LABELS_WAIT_SECS=3 "$TEST_TMPDIR/scripts/provision-peer-labels.sh" main
  [ "$status" -eq 0 ]
  [[ "$output" == *"skip cto: not in agents.list"* ]]
  # A bare `! grep` that is not the last command never fails a Bats test (bash ignores `set -e`
  # on a negated pipeline), so the absence is asserted as a count (QA on #2143).
  [ "$(grep -c '"agentId":"cto"' "$CALLS")" -eq 0 ]
  grep -q '"agentId":"clio"' "$CALLS"
  [ "$(grep -c 'sessions.create' "$CALLS")" -eq 8 ]
}

@test "an unreadable agents.list keeps the whole peer map" {
  answering_gateway
  run env PEER_LABELS_WAIT_SECS=3 "$TEST_TMPDIR/scripts/provision-peer-labels.sh" main
  [ "$status" -eq 0 ]
  [[ "$output" != *"skip "* ]]
  [ "$(grep -c 'sessions.create' "$CALLS")" -eq 9 ]
}
