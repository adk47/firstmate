#!/usr/bin/env bats
# Tests for the web_search-provider invariant in
# scripts/validate-config-matrix.sh (check #7), added in
# feat/websearch-codex-provider-main.
#
# Background: openclaw's gateway web_search tool resolves a MANAGED provider.
# codex-NATIVE search folds into the model's turn and does NOT feed that tool.
# The key-free "codex" managed provider never wins auto-detection, so it must be
# named explicitly — enabling openaiCodex without a provider is exactly the
# 2026-06-30 #607 regression (native works on codex turns, managed tool
# hard-fails on non-codex turns, fleet-wide). check #7 enforces: if
# tools.web.search.enabled, a provider must be set and allowlisted; "codex" is
# key-free (allowlist is sufficient); a keyed provider additionally needs a
# plugins.entries block + apiKey.
#
# Each case writes a throwaway fixture under mktemp -d and runs the real script
# against it via args, so no real config is touched. Modeled on
# scripts/tests/validate-config-matrix-fallback.bats.
bats_require_minimum_version 1.5.0

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
  "agents": {
    "defaults": { "thinkingDefault": "medium",
      "model": { "primary": "openai/gpt-5.5",
        "fallbacks": ["openrouter/openai/gpt-5.4-mini","openrouter/anthropic/claude-4.6-sonnet-20260217"] } },
    "list": [
      { "id": "x", "thinkingDefault": "medium",
        "model": { "primary": "openai/gpt-5.5", "fallbacks": ["openrouter/anthropic/claude-4.6-sonnet-20260217"] },
        "imageModel": { "primary": "codex/gpt-5.5", "fallbacks": ["openrouter/anthropic/claude-haiku-4.5"] } }
    ]
  },
  "plugins": $plugins_json,
  "tools": { "exec": { "security": "full" }$web_block }
}
JSON
}

@test "check7: key-free codex provider, allowlisted, no entry/apiKey PASSES" {
  # The exact shipped shape — regression test for our own fix. The held Perplexity
  # branch's check would have wrongly failed this (it required an apiKey).
  write_ws_profile '{"enabled":true,"provider":"codex","openaiCodex":{"enabled":true,"mode":"live"}}' \
    '{"allow":["codex","slack"]}'
  run "$SCRIPT" "$PROFILE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"all checks passed"* ]]
}

@test "check7: search enabled but provider UNSET fails (the #607 shape)" {
  write_ws_profile '{"enabled":true,"openaiCodex":{"enabled":true,"mode":"live"}}' \
    '{"allow":["codex"]}'
  run "$SCRIPT" "$PROFILE"
  [ "$status" -eq 1 ]
  [[ "$output" == *"provider unset"* ]]
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
