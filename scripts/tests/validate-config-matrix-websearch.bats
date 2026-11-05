#!/usr/bin/env bats
# Tests for the web_search backend invariant in
# scripts/validate-config-matrix.sh (check #7).
#
# Background: on openclaw 7.1, native codex search (tools.web.search.openaiCodex.
# enabled) and a managed provider (tools.web.search.provider) are MUTUALLY
# EXCLUSIVE — setting a provider disables native, and in hydra the managed codex
# worker can't authenticate, so it fails "Reconnecting..." (this is what broke
# web_search fleet-wide in #695, 2026-07-17). check #7 enforces: reject both set
# at once; reject enabled-with-no-backend; native-only (openaiCodex.enabled, NO
# provider) is the supported shape and passes; a managed provider (native off)
# must be a recognized id, allowlisted, not entry-disabled, and — unless key-free
# "codex" — carry a plugins.entries block + apiKey.
#
# Each case writes a throwaway fixture under mktemp -d and runs the real script
# against it via args, so no real config is touched. Modeled on
# scripts/tests/validate-config-matrix-fallback.bats.
bats_require_minimum_version 1.5.0
load fixtures/declare-model-catalog

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
SCRIPT="$HYDRA_REPO/scripts/validate-config-matrix.sh"

setup() {
  TEST_TMPDIR="$(mktemp -d)"; export TEST_TMPDIR
  PROFILE="$TEST_TMPDIR/openclaw-test.json"
}

teardown() { rm -rf "$TEST_TMPDIR"; }

# Build a minimal-but-valid profile (passes checks 1-3 and 6) with a
# configurable tools.web.search block and plugins block, so only check #7 can
# vary. $1 = JSON value for .tools.web.search, or the literal "OMIT" to leave
# tools.web absent (edge-shaped). $2 (optional) = JSON value for .plugins
# (default: allow just "codex").
write_ws_profile() {
  local search_json="$1"
  # NB: don't inline braces in a ${2:-default} — bash's first `}` closes the
  # expansion early and leaves a stray literal `}` (breaks the JSON). Default
  # in a separate step.
  local plugins_json="${2:-}"
  [[ -z "$plugins_json" ]] && plugins_json='{"allow":["codex"]}'
  local web_block=""
  if [[ "$search_json" != "OMIT" ]]; then
    web_block=", \"web\": { \"search\": $search_json }"
  fi
  cat > "$PROFILE" <<JSON
{
  "gateway": { "auth": { "mode": "token" } },
  "agents": {
    "defaults": { "thinkingDefault": "medium",
      "model": { "primary": "openai/gpt-5.5",
        "fallbacks": ["openrouter/deepseek/deepseek-v4.1-flash-1017"] } },
    "list": [
      { "id": "x", "thinkingDefault": "medium",
        "model": { "primary": "openai/gpt-5.5", "fallbacks": ["openrouter/deepseek/deepseek-v4.1-flash-1017"] },
        "imageModel": { "primary": "codex/gpt-5.5", "fallbacks": ["openrouter/anthropic/claude-haiku-4.5"] } }
    ]
  },
  "plugins": $plugins_json,
  "tools": { "exec": { "security": "full" }$web_block }
}
JSON
  declare_model_catalog
}

@test "check7: native-only (openaiCodex.enabled, NO provider) PASSES" {
  # The supported/shipped shape after #695 was reverted. Native key-free codex
  # search on the ChatGPT OAuth; no managed provider.
  write_ws_profile '{"enabled":true,"openaiCodex":{"enabled":true,"mode":"live"}}' \
    '{"allow":["codex","slack"]}'
  run "$SCRIPT" "$PROFILE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"all checks passed"* ]]
}

@test "check7: openaiCodex.enabled AND provider set FAILS (mutual exclusion — the #695 shape)" {
  # Setting a provider disables native on 7.1; the #695 config that broke
  # web_search fleet-wide. Must be rejected.
  write_ws_profile '{"enabled":true,"provider":"codex","openaiCodex":{"enabled":true,"mode":"live"}}' \
    '{"allow":["codex","slack"]}'
  run "$SCRIPT" "$PROFILE"
  [ "$status" -eq 1 ]
  [[ "$output" == *"mutually exclusive"* ]]
}

@test "check7: enabled with NO backend (no native, no provider) FAILS" {
  write_ws_profile '{"enabled":true}' '{"allow":["codex"]}'
  run "$SCRIPT" "$PROFILE"
  [ "$status" -eq 1 ]
  [[ "$output" == *"no backend"* ]]
}

@test "check7: codex provider NOT in plugins.allow fails" {
  write_ws_profile '{"enabled":true,"provider":"codex"}' \
    '{"allow":["slack","intercom"]}'
  run "$SCRIPT" "$PROFILE"
  [ "$status" -eq 1 ]
  [[ "$output" == *"not in plugins.allow"* ]]
}

@test "check7: keyed provider allowlisted but NO entry block fails" {
  write_ws_profile '{"enabled":true,"provider":"perplexity"}' \
    '{"allow":["perplexity"]}'
  run "$SCRIPT" "$PROFILE"
  [ "$status" -eq 1 ]
  [[ "$output" == *"has no plugins.entries"* ]]
}

@test "check7: keyed provider with entry but NO apiKey fails" {
  write_ws_profile '{"enabled":true,"provider":"perplexity"}' \
    '{"allow":["perplexity"],"entries":{"perplexity":{"enabled":true,"config":{}}}}'
  run "$SCRIPT" "$PROFILE"
  [ "$status" -eq 1 ]
  [[ "$output" == *"has no apiKey"* ]]
}

@test "check7: keyed provider with entry + apiKey PASSES (keyed path preserved)" {
  write_ws_profile '{"enabled":true,"provider":"perplexity"}' \
    '{"allow":["perplexity"],"entries":{"perplexity":{"config":{"webSearch":{"apiKey":{"source":"file","id":"/OPENROUTER_API_KEY"}}}}}}'
  run "$SCRIPT" "$PROFILE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"all checks passed"* ]]
}

@test "check7: codex provider with a DISABLED entry fails" {
  # allowlisted + key-free, but plugins.entries.codex.enabled:false → the plugin
  # never registers, so managed web_search stays unavailable. Must be rejected
  # despite codex being key-free.
  write_ws_profile '{"enabled":true,"provider":"codex"}' \
    '{"allow":["codex"],"entries":{"codex":{"enabled":false}}}'
  run "$SCRIPT" "$PROFILE"
  [ "$status" -eq 1 ]
  [[ "$output" == *"entry is disabled"* ]]
}

@test "check7: keyed provider with apiKey but DISABLED entry fails" {
  write_ws_profile '{"enabled":true,"provider":"perplexity"}' \
    '{"allow":["perplexity"],"entries":{"perplexity":{"enabled":false,"config":{"webSearch":{"apiKey":{"source":"file","id":"/OPENROUTER_API_KEY"}}}}}}'
  run "$SCRIPT" "$PROFILE"
  [ "$status" -eq 1 ]
  [[ "$output" == *"entry is disabled"* ]]
}

@test "check7: unknown/typo provider id fails even fully wired" {
  # provider:"codxe" (typo of codex) with a matching allow + entry + apiKey would
  # pass a shape-only check, but openclaw resolves only registered ids → zero
  # candidates = the #607 silent failure. The $KNOWN allowlist must reject it.
  write_ws_profile '{"enabled":true,"provider":"codxe"}' \
    '{"allow":["codxe"],"entries":{"codxe":{"config":{"webSearch":{"apiKey":{"source":"file","id":"/OPENROUTER_API_KEY"}}}}}}'
  run "$SCRIPT" "$PROFILE"
  [ "$status" -eq 1 ]
  [[ "$output" == *"not a recognized web-search provider"* ]]
}

@test "check7: search disabled PASSES (no provider required)" {
  write_ws_profile '{"enabled":false}' '{"allow":["codex"]}'
  run "$SCRIPT" "$PROFILE"
  [ "$status" -eq 0 ]
}

@test "check7: tools.web absent PASSES (edge-shaped no-op)" {
  write_ws_profile 'OMIT' '{"allow":["codex"]}'
  run "$SCRIPT" "$PROFILE"
  [ "$status" -eq 0 ]
}
