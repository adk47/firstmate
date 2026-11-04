#!/usr/bin/env bats
# Tests for the model-ref catalog invariant in scripts/validate-config-matrix.sh
# (check #9, MUS-8564).
#
# Background: an agent model ref that is NOT declared in its own profile's
# models.providers.<provider>.models[].id does not refuse at runtime — openclaw
# synthesizes a model with default metadata (text-only, 200k context), so an
# image sent to a fallback is silently mis-handled (MUS-8506 Row D). QA's
# mutation on hydra#1176 (edge -> undeclared openai/gpt-7-sol) exited 0.
#
# Each case jq-edits a COPY of a real tracked profile into a mktemp dir and
# passes that path as argv, so the case exercises the real catalog and no
# tracked profile is touched. Negatives are written as `run …; [ status -ne 0 ]`
# plus a message assertion: a bare `! cmd` in a @test never fails (SC2314) and
# hydra's shellcheck CI does not lint .bats.
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
SCRIPT="$HYDRA_REPO/scripts/validate-config-matrix.sh"

setup() {
  TEST_TMPDIR="$(mktemp -d)"; export TEST_TMPDIR
  PROFILE="$TEST_TMPDIR/openclaw-edge.json"
}

teardown() { rm -rf "$TEST_TMPDIR"; }

# $1 = real profile name, $2 = jq filter applied to a copy at $PROFILE
mutate() {
  jq "$2" "$HYDRA_REPO/$1" > "$PROFILE"
}

@test "model-refs: unmodified openclaw-main.json and openclaw-edge.json pass" {
  cd "$HYDRA_REPO"
  run ./scripts/validate-config-matrix.sh openclaw-main.json openclaw-edge.json
  [ "$status" -eq 0 ]
  [[ "$output" == *"all checks passed"* ]]
}

@test "model-refs: codex/ imageModel with an undeclared id FAILS (Row D class)" {
  mutate openclaw-edge.json '.agents.defaults.imageModel.primary = "codex/gpt-9-nope"'
  run "$SCRIPT" "$PROFILE"
  [ "$status" -eq 1 ]
  [[ "$output" == *"agents.defaults.imageModel.primary"* ]]
  [[ "$output" == *"codex/gpt-9-nope"* ]]
  [[ "$output" == *"not declared"* ]]
}

@test "model-refs: unknown runtime prefix FAILS" {
  mutate openclaw-edge.json '.agents.defaults.imageModel.primary = "nosuchruntime/gpt-5.6-sol"'
  run "$SCRIPT" "$PROFILE"
  [ "$status" -eq 1 ]
  [[ "$output" == *"unknown model-ref prefix \"nosuchruntime\""* ]]
  [[ "$output" == *"nosuchruntime/gpt-5.6-sol"* ]]
}

@test "model-refs: openai/<declared id> as an agent text model.primary passes" {
  mutate openclaw-edge.json '.agents.list[0].model.primary = "openai/gpt-5.6-sol"'
  run "$SCRIPT" "$PROFILE"
  [ "$status" -eq 0 ]
}

@test "model-refs: openrouter/<vendor>/<model> splits on the FIRST slash only" {
  # Two vendor-slashed entries so the split is exercised twice. Since the
  # fleet-wide single-fallback rule (check 6b, captain 2026-11-03) refuses a
  # two-entry list, this asserts the MODEL-REF verdict: neither ref is reported
  # as undeclared, and the refusal names the chain rule instead.
  mutate openclaw-edge.json '.agents.list[0].model.fallbacks = ["openrouter/openai/gpt-6-luna","openrouter/google/gemini-3.5-flash"]'
  run "$SCRIPT" "$PROFILE"
  [ "$status" -eq 1 ]
  [[ "$output" != *"not declared"* ]]
  [[ "$output" != *"unknown model-ref prefix"* ]]
  [[ "$output" == *"not the one uniform chain"* ]]
}

@test "model-refs: two providers claiming agentRuntime.id codex is ambiguous and FAILS" {
  mutate openclaw-edge.json '.models.providers.openrouter.agentRuntime = {"id": "codex"}'
  run "$SCRIPT" "$PROFILE"
  [ "$status" -eq 1 ]
  [[ "$output" == *"ambiguous runtime prefix \"codex\" matches 2 providers"* ]]
}

@test "model-refs: removing the openai agentRuntime.id makes codex/ refs FAIL" {
  mutate openclaw-edge.json 'del(.models.providers.openai.agentRuntime)'
  run "$SCRIPT" "$PROFILE"
  [ "$status" -eq 1 ]
  [[ "$output" == *"unknown model-ref prefix \"codex\""* ]]
}

@test "model-refs: agents.list[] model.primary -> undeclared openai/gpt-7-sol FAILS (QA M4)" {
  mutate openclaw-edge.json '.agents.list[0].model.primary = "openai/gpt-7-sol"'
  run "$SCRIPT" "$PROFILE"
  [ "$status" -eq 1 ]
  [[ "$output" == *"agents.list[support].model.primary"* ]]
  [[ "$output" == *"openai/gpt-7-sol"* ]]
  [[ "$output" == *"$PROFILE"* ]]
}

@test "model-refs: a model.fallbacks entry -> openrouter/openai/does-not-exist FAILS" {
  mutate openclaw-edge.json '.agents.list[0].model.fallbacks[1] = "openrouter/openai/does-not-exist"'
  run "$SCRIPT" "$PROFILE"
  [ "$status" -eq 1 ]
  [[ "$output" == *"agents.list[support].model.fallbacks[1]"* ]]
  [[ "$output" == *"openrouter/openai/does-not-exist"* ]]
}

@test "model-refs: agents.defaults.model.fallbacks and agents.list[].imageModel are covered" {
  mutate openclaw-edge.json '.agents.defaults.model.fallbacks[0] = "openai/gpt-7-sol" | .agents.list[0].imageModel = {"primary":"codex/gpt-9-nope"}'
  run "$SCRIPT" "$PROFILE"
  [ "$status" -eq 1 ]
  [[ "$output" == *"agents.defaults.model.fallbacks[0]"* ]]
  [[ "$output" == *"agents.list[support].imageModel.primary"* ]]
}

@test "model-refs: a ref with no provider prefix FAILS" {
  mutate openclaw-edge.json '.agents.list[0].model.primary = "gpt-6-sol"'
  run "$SCRIPT" "$PROFILE"
  [ "$status" -eq 1 ]
  [[ "$output" == *"malformed model ref"* ]]
}

# Check 8 accepts a keyed .agents.entries{} profile shape, so check 9 must walk
# it too: a profile migrated list -> entries must not walk around the gate
# (bot NO-GO on hydra#1182). This jq turns a copy of the real profile into that shape.
to_entries_shape='.agents.entries = (.agents.list | map({(.id): del(.id)}) | add) | del(.agents.list)'

@test "model-refs: agents.entries{} unmodified profile passes" {
  mutate openclaw-edge.json "$to_entries_shape"
  run "$SCRIPT" "$PROFILE"
  [ "$status" -eq 0 ]
}

@test "model-refs: agents.entries{} model.primary -> undeclared openai/gpt-7-sol FAILS" {
  mutate openclaw-edge.json "$to_entries_shape | .agents.entries.support.model.primary = \"openai/gpt-7-sol\""
  run "$SCRIPT" "$PROFILE"
  [ "$status" -eq 1 ]
  [[ "$output" == *"agents.entries[support].model.primary"* ]]
  [[ "$output" == *"openai/gpt-7-sol"* ]]
}

@test "model-refs: agents.entries{} fallbacks and imageModel are covered" {
  mutate openclaw-edge.json "$to_entries_shape | .agents.entries.support.model.fallbacks[1] = \"openrouter/openai/does-not-exist\" | .agents.entries.support.imageModel = {\"primary\":\"codex/gpt-9-nope\"}"
  run "$SCRIPT" "$PROFILE"
  [ "$status" -eq 1 ]
  [[ "$output" == *"agents.entries[support].model.fallbacks[1]"* ]]
  [[ "$output" == *"agents.entries[support].imageModel.primary"* ]]
}

# imageModel must carry the runtime prefix (codex/), not the raw provider key
# (openai/), even when the id IS declared: openai/<id> as an imageModel sends
# image input down the HTTP media-understanding route and TypeErrors
# (docs/lessons/openclaw-and-codex.md:617). Bot NO-GO on hydra#1182.
@test "model-refs: DECLARED openai/ imageModel.primary FAILS (runtime prefix required)" {
  mutate openclaw-edge.json '.agents.defaults.imageModel.primary = "openai/gpt-5.6-sol"'
  run "$SCRIPT" "$PROFILE"
  [ "$status" -eq 1 ]
  [[ "$output" == *"agents.defaults.imageModel.primary = openai/gpt-5.6-sol"* ]]
  [[ "$output" == *"runtime prefix \"codex/\""* ]]
}

@test "model-refs: DECLARED openai/ imageModel fallback and per-agent imageModel FAIL" {
  mutate openclaw-edge.json '.agents.defaults.imageModel.fallbacks[0] = "openai/gpt-6-sol" | .agents.list[0].imageModel = {"primary":"openai/gpt-5.6-sol"}'
  run "$SCRIPT" "$PROFILE"
  [ "$status" -eq 1 ]
  [[ "$output" == *"agents.defaults.imageModel.fallbacks[0] = openai/gpt-6-sol"* ]]
  [[ "$output" == *"imageModel.primary = openai/gpt-5.6-sol"* ]]
}

@test "model-refs: DECLARED openai/ imageModel in STRING form FAILS (defaults and per-agent)" {
  mutate openclaw-edge.json '.agents.defaults.imageModel = "openai/gpt-5.6-sol"'
  run "$SCRIPT" "$PROFILE"
  [ "$status" -eq 1 ]
  [[ "$output" == *"agents.defaults.imageModel = openai/gpt-5.6-sol"* ]]
  [[ "$output" == *"runtime prefix \"codex/\""* ]]
  mutate openclaw-edge.json '.agents.list[0].imageModel = "openai/gpt-5.6-sol"'
  run "$SCRIPT" "$PROFILE"
  [ "$status" -eq 1 ]
  [[ "$output" == *"imageModel = openai/gpt-5.6-sol"* ]]
  [[ "$output" == *"runtime prefix \"codex/\""* ]]
}

@test "model-refs: DECLARED codex/ imageModel still passes (legal form)" {
  mutate openclaw-edge.json '.agents.defaults.imageModel.primary = "codex/gpt-6-sol"'
  run "$SCRIPT" "$PROFILE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"all checks passed"* ]]
}

@test "model-refs: openai/ is still fine for text model refs (rule is imageModel-only)" {
  # A text model.primary is the surface this rule is about: `openai/` stays legal
  # there. The fallback LIST is now pinned by check 6b, so mutating a fallback
  # entry would test the chain rule instead of this one.
  mutate openclaw-edge.json '.agents.list[0].model.primary = "openai/gpt-5.6-sol"'
  run "$SCRIPT" "$PROFILE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"all checks passed"* ]]
}

# imageModel provider-key prefix: refuse when the provider declares agentRuntime.id
# (use the runtime prefix), else refuse when it declares no baseUrl (nothing to
# route an image over), else accept. The arms are a conjunction, never an "or".
@test "model-refs: DECLARED openai/ imageModel FAILS when the provider declares neither agentRuntime.id nor baseUrl" {
  mutate openclaw-edge.json 'del(.models.providers.openai.agentRuntime) | .agents.defaults.imageModel.primary = "openai/gpt-5.6-sol"'
  run "$SCRIPT" "$PROFILE"
  [ "$status" -eq 1 ]
  [[ "$output" == *"agents.defaults.imageModel.primary = openai/gpt-5.6-sol"* ]]
  [[ "$output" == *"neither agentRuntime.id nor baseUrl"* ]]
}

@test "model-refs: openrouter/ imageModel fallback (baseUrl, no agentRuntime) passes" {
  mutate openclaw-edge.json '.models.providers.openrouter.baseUrl |= (. // "https://openrouter.ai/api/v1") | .agents.defaults.imageModel.fallbacks = ["openrouter/google/gemini-3.5-flash"]'
  run "$SCRIPT" "$PROFILE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"all checks passed"* ]]
}

@test "model-refs: provider declaring BOTH baseUrl and agentRuntime.id FAILS with the runtime-prefix message" {
  mutate openclaw-edge.json '.models.providers.openai.baseUrl = "https://example.invalid/v1" | .agents.defaults.imageModel.primary = "openai/gpt-5.6-sol"'
  run "$SCRIPT" "$PROFILE"
  [ "$status" -eq 1 ]
  [[ "$output" == *"runtime prefix \"codex/\""* ]]
}
