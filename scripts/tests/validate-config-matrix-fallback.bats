#!/usr/bin/env bats
# Tests for the empty-completion fallback-safety invariant in
# scripts/validate-config-matrix.sh (check #6) and the updated cron fallback
# pin (check #5), added in fix/fallback-empty-cascade.
#
# Background: openclaw only treats an empty/0-token completion as a
# failure-that-cascades for GPT-5-family models (isGpt5ModelId gate). A non-GPT-5
# model in a NON-FINAL fallback position that returns an empty completion is
# scored candidate_succeeded and silently stops the chain (2026-06-08 @CMO
# incident, PR #450). The gate enforces: every fallback entry except the last
# must match openclaw's GPT-5 id pattern (^|[/:])gpt-5([.-]|$).
#
# Each case writes a throwaway fixture under mktemp -d and runs the real script
# against it via args, so no real config is touched. Modeled on
# scripts/tests/codex-auth-fanout.bats (sandbox + `run` + status/output asserts).
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
SCRIPT="$HYDRA_REPO/scripts/validate-config-matrix.sh"

setup() {
  TEST_TMPDIR="$(mktemp -d)"; export TEST_TMPDIR
  PROFILE="$TEST_TMPDIR/openclaw-test.json"
  CRON="$TEST_TMPDIR/cron-jobs.json"
}

teardown() { rm -rf "$TEST_TMPDIR"; }

# Build a minimal-but-valid profile (passes checks 1-3) with the given agent
# model.fallbacks JSON array. $1 = fallbacks json, $2 (optional) = imageModel
# fallbacks json (defaults to a safe single-entry chain).
write_profile() {
  local agent_fb="$1"
  local image_fb="${2:-[\"openrouter/anthropic/claude-haiku-4.5\"]}"
  cat > "$PROFILE" <<JSON
{
  "agents": {
    "defaults": {
      "thinkingDefault": "medium",
      "model": { "primary": "openai/gpt-5.5",
        "fallbacks": ["openrouter/openai/gpt-5.4-mini","openrouter/anthropic/claude-4.6-sonnet-20260217"] }
    },
    "list": [
      { "id": "x", "thinkingDefault": "medium",
        "model": { "primary": "openai/gpt-5.5", "fallbacks": $agent_fb },
        "imageModel": { "primary": "codex/gpt-5.5", "fallbacks": $image_fb } }
    ]
  }
}
JSON
}

write_cron() {
  local fb="$1"
  local model="${2:-openai/gpt-6-sol}"
  cat > "$CRON" <<JSON
{ "version": 1, "jobs": [
  { "id": "a", "name": "test-job", "payload": { "kind": "agentTurn",
    "thinking": "low", "model": "$model", "fallbacks": $fb } } ] }
JSON
}

@test "check6: gpt-5.4-mini mid-fallback passes" {
  write_profile '["openrouter/openai/gpt-5.4-mini","openrouter/anthropic/claude-4.6-sonnet-20260217"]'
  run "$SCRIPT" "$PROFILE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"all checks passed"* ]]
}

@test "check6: non-GPT-5 (gemini) mid-fallback FAILS" {
  write_profile '["openrouter/google/gemini-3.5-flash","openrouter/anthropic/claude-4.6-sonnet-20260217"]'
  run "$SCRIPT" "$PROFILE"
  [ "$status" -eq 1 ]
  [[ "$output" == *"non-final fallback position"* ]]
  [[ "$output" == *"gemini-3.5-flash"* ]]
}

@test "check6: non-GPT-5 (haiku) mid-fallback FAILS" {
  write_profile '["openrouter/anthropic/claude-haiku-4.5","openrouter/openai/gpt-5.4-mini"]'
  run "$SCRIPT" "$PROFILE"
  [ "$status" -eq 1 ]
  [[ "$output" == *"non-final fallback position"* ]]
}

@test "check6: non-GPT-5 only in LAST position passes (sonnet last)" {
  write_profile '["openrouter/openai/gpt-5.4-mini","openrouter/anthropic/claude-4.6-sonnet-20260217"]'
  run "$SCRIPT" "$PROFILE"
  [ "$status" -eq 0 ]
}

@test "check6: single-entry fallback (non-gpt5) passes (nothing to swallow)" {
  write_profile '["openrouter/anthropic/claude-4.6-sonnet-20260217"]'
  run "$SCRIPT" "$PROFILE"
  [ "$status" -eq 0 ]
}

@test "check6: imageModel is OUT OF SCOPE — non-gpt5 mid imageModel passes" {
  # agent model chain is safe; imageModel has a non-gpt5 mid entry → must NOT fail.
  write_profile \
    '["openrouter/openai/gpt-5.4-mini","openrouter/anthropic/claude-4.6-sonnet-20260217"]' \
    '["openrouter/google/gemini-3.5-flash","openrouter/anthropic/claude-haiku-4.5"]'
  run "$SCRIPT" "$PROFILE"
  [ "$status" -eq 0 ]
}

@test "check5: cron with gpt-6-luna first fallback passes" {
  write_cron '["openrouter/openai/gpt-6-luna","openrouter/anthropic/claude-haiku-5.5"]'
  run "$SCRIPT" "$CRON"
  [ "$status" -eq 0 ]
}

@test "check5: cron with old gemini first fallback now FAILS" {
  write_cron '["openrouter/google/gemini-3.5-flash","openrouter/anthropic/claude-haiku-5.5"]'
  run "$SCRIPT" "$CRON"
  [ "$status" -eq 1 ]
  [[ "$output" == *"gpt-6-luna"* ]]
}

@test "check5: cron still on old gpt-5.5/mini/sonnet chain now FAILS" {
  write_cron '["openrouter/openai/gpt-5.4-mini","openrouter/anthropic/claude-4.6-sonnet-20260217"]' \
    "openai/gpt-5.5"
  run "$SCRIPT" "$CRON"
  [ "$status" -eq 1 ]
  [[ "$output" == *"must be on openai/gpt-6-sol"* ]]
}

@test "check6: gpt-6-luna mid-fallback passes (classifier has no model-id gate on the pinned build)" {
  write_profile '["openrouter/openai/gpt-6-luna","openrouter/anthropic/claude-haiku-5.5"]'
  run "$SCRIPT" "$PROFILE"
  [ "$status" -eq 0 ]
}

@test "check6: gpt-7 mid-fallback still FAILS (only gpt-5/gpt-6 families are accepted)" {
  write_profile '["openrouter/openai/gpt-7-luna","openrouter/anthropic/claude-haiku-5.5"]'
  run "$SCRIPT" "$PROFILE"
  [ "$status" -eq 1 ]
}
