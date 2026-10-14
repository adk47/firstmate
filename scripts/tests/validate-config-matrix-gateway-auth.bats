#!/usr/bin/env bats
# Tests for the gateway.auth.mode invariant in scripts/validate-config-matrix.sh
# (check #0b).
#
# What this pins: the gateways listen on 0.0.0.0 (bind:"lan") on purpose -- the
# in-cluster Intercom path needs 10.0.0.8 -- so token auth is the only thing
# between the pod network and the Control UI's RPC layer. The reason is stated
# once, next to the gate in the script; not restated here.
#
# Each case writes a throwaway fixture under mktemp -d and runs the real script
# against it via args. Modeled on validate-config-matrix-fallback.bats.
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
SCRIPT="$HYDRA_REPO/scripts/validate-config-matrix.sh"

setup() {
  TEST_TMPDIR="$(mktemp -d)"; export TEST_TMPDIR
  PROFILE="$TEST_TMPDIR/openclaw-test.json"
}

teardown() { rm -rf "$TEST_TMPDIR"; }

# Minimal profile that passes every other check; ONLY the gateway block varies.
# $1 = JSON value for the `gateway` key, or "OMIT" for no gateway key.
write_gw_profile() {
  local gw_block=""
  [[ "$1" != "OMIT" ]] && gw_block=", \"gateway\": $1"
  cat > "$PROFILE" <<JSON
{
  "agents": {
    "defaults": { "thinkingDefault": "medium",
      "model": { "primary": "openai/gpt-5.5",
        "fallbacks": ["openrouter/openai/gpt-5.4-mini","openrouter/anthropic/claude-4.6-sonnet-20260217"] } },
    "list": [
      { "id": "x", "thinkingDefault": "medium",
        "model": { "primary": "openai/gpt-5.5", "fallbacks": ["openrouter/anthropic/claude-4.6-sonnet-20260217"] } }
    ]
  }$gw_block
}
JSON
}

@test "check0b: gateway.auth.mode=token PASSES" {
  write_gw_profile '{"bind":"lan","auth":{"mode":"token"}}'
  run "$SCRIPT" "$PROFILE"
  [ "$status" -eq 0 ]
}

@test "check0b: gateway.auth.mode=none FAILS" {
  write_gw_profile '{"bind":"lan","auth":{"mode":"none"}}'
  run --separate-stderr "$SCRIPT" "$PROFILE"
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"gateway.auth.mode must not be none/absent (was: none)"* ]]
}

@test "check0b: gateway.auth.mode key absent FAILS" {
  write_gw_profile '{"bind":"lan","auth":{}}'
  run --separate-stderr "$SCRIPT" "$PROFILE"
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"(was: MISSING)"* ]]
}

@test "check0b: no gateway block at all FAILS" {
  write_gw_profile 'OMIT'
  run --separate-stderr "$SCRIPT" "$PROFILE"
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"(was: MISSING)"* ]]
}

@test "check0b: bind=lan is NOT gated (it is the required mode)" {
  write_gw_profile '{"bind":"lan","auth":{"mode":"token"}}'
  run "$SCRIPT" "$PROFILE"
  [ "$status" -eq 0 ]
}

@test "check0b: real profiles pass at HEAD" {
  cd "$HYDRA_REPO"
  run "$SCRIPT" openclaw-main.json openclaw-edge.json
  [ "$status" -eq 0 ]
}
