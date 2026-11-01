#!/usr/bin/env bats
# Tests for the codex-harness native-tool-surface invariant in
# scripts/validate-config-matrix.sh (check #8).
#
# What these pin: on openclaw >= 2026.8 a tool policy that denies a name outside
# the closed CODEX_TOOL_POLICY_SAFE_DENY_NAMES list -- or narrows `allow` -- makes
# openclaw mark the agent's codex harness RESTRICTED, which silently strips its
# entire native tool surface (web search, shell, image generation, browser, skill
# search, memories). That is the 2026-09-10 incident: the 2026.8.2 cutover turned
# hydra's long-standing `tools.deny: ["sentry__*"]` into a capability kill switch
# and Scout told a user its web research provider was unavailable mid-task.
#
# The mechanism (which dist function decides what, and why a managed provider is
# NOT the fix) is documented ONCE, next to the gate itself, in
# scripts/validate-config-matrix.sh check #8 and docs/lessons/openclaw-and-codex.md.
# Deliberately not restated here: two copies of a mechanism that must be
# re-verified together on every openclaw/codex bump will drift, and the copy a
# reader of the gate finds is the one in the script.
#
# Each case writes a throwaway fixture under mktemp -d and runs the real script
# against it via args, so no real config is touched. Modeled on
# scripts/tests/validate-config-matrix-websearch.bats.
bats_require_minimum_version 1.5.0
load fixtures/declare-model-catalog

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
SCRIPT="$HYDRA_REPO/scripts/validate-config-matrix.sh"

setup() {
  TEST_TMPDIR="$(mktemp -d)"; export TEST_TMPDIR
  PROFILE="$TEST_TMPDIR/openclaw-test.json"
}

teardown() { rm -rf "$TEST_TMPDIR"; }

# The global tools block every fixture gets unless a case overrides it. Hoisted
# to a constant because the inline `${4:-{ "exec": ... }}` form does NOT work --
# bash mis-matches the braces and emits a trailing `}}`.
DEFAULT_GLOBAL_TOOLS='{ "exec": { "security": "full" } }'

# Build a minimal-but-valid profile (passes checks 1-3, 6 and 7) whose ONLY
# variable is the agent's tools policy, so a failure can only come from check #8.
# $1 = JSON value for the agent's `tools` key, or "OMIT" for no tools key.
# $2 (optional) = agent id (default "x").
# $3 (optional) = fixture basename (default "openclaw-test.json") -- the exception
#                 allowlist is keyed on it, so the name is load-bearing.
# $4 (optional) = JSON value for the GLOBAL tools key.
write_policy_profile() {
  local tools_json="$1"
  local agent_id="${2:-x}"
  local basename_override="${3:-openclaw-test.json}"
  local global_tools="${4:-$DEFAULT_GLOBAL_TOOLS}"
  PROFILE="$TEST_TMPDIR/$basename_override"
  local agent_tools=""
  if [[ "$tools_json" != "OMIT" ]]; then
    agent_tools=", \"tools\": $tools_json"
  fi
  cat > "$PROFILE" <<JSON
{
  "gateway": { "auth": { "mode": "token" } },
  "agents": {
    "defaults": { "thinkingDefault": "medium",
      "model": { "primary": "openai/gpt-5.6-sol",
        "fallbacks": ["openrouter/openai/gpt-5.6-luna","openrouter/anthropic/claude-haiku-4.5"] } },
    "list": [
      { "id": "$agent_id", "thinkingDefault": "medium",
        "model": { "primary": "openai/gpt-5.6-sol",
          "fallbacks": ["openrouter/anthropic/claude-haiku-4.5"] }$agent_tools }
    ]
  },
  "plugins": { "allow": ["codex"] },
  "tools": $global_tools
}
JSON
  declare_model_catalog
}

# Append `scout` with its REAL deny (read from the repo's openclaw-main.json, so this
# cannot drift) to the current fixture. Any openclaw-main.json fixture needs it once
# scout carries excepted denies: without scout those exception rows are judged
# STALE, which is the gate working, not the case under test.
# $1 (optional) = jq filter applied to scout's deny array (default: unchanged).
add_scout_agent() {
  local deny
  deny=$(jq -c --argjson d "$(jq -c '.agents.list[] | select(.id=="scout") | .tools.deny' "$HYDRA_REPO/openclaw-main.json")" \
    -n "\$d | ${1:-.}")
  jq --argjson deny "$deny" '.agents.list += [{"id":"scout","thinkingDefault":"medium",
      "model":{"primary":"openai/gpt-5.6-sol","fallbacks":["openrouter/anthropic/claude-haiku-4.5"]},
      "tools":{"deny":$deny}}]' "$PROFILE" > "$PROFILE.tmp" && mv "$PROFILE.tmp" "$PROFILE"
}

# Same fixture, converted to the keyed `.agents.entries{}` form the >=2026.8
# doctor understands. DERIVED from write_policy_profile rather than hand-written,
# so the two shapes are provably the same config -- which is what the
# "treated identically" tests actually mean to assert. Takes the same args.
write_entries_profile() {
  write_policy_profile "$@"
  jq '.agents.entries = (.agents.list | map({ key: .id, value: del(.id) }) | from_entries)
      | del(.agents.list)' "$PROFILE" > "$PROFILE.tmp" && mv "$PROFILE.tmp" "$PROFILE"
  # Prove the conversion actually happened. Every entries-shape assertion below
  # is shape-AGNOSTIC (the same deny fails in either shape), so a silently
  # un-converted fixture would leave those cases green while testing the `list`
  # branch — a test passing for the wrong reason, about the exact branch it was
  # added to cover.
  jq -e '(.agents.entries | type) == "object" and (.agents.entries | length) > 0
         and (has("agents") and (.agents | has("list") | not))' "$PROFILE" >/dev/null
}

@test "check8: no tools policy at all PASSES" {
  write_policy_profile 'OMIT'
  run "$SCRIPT" "$PROFILE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"all checks passed"* ]]
}

@test "check8: empty deny array PASSES" {
  write_policy_profile '{"deny":[]}'
  run "$SCRIPT" "$PROFILE"
  [ "$status" -eq 0 ]
}

@test "check8: deny of a SAFE core tool (web_fetch) PASSES" {
  # web_fetch is in CODEX_TOOL_POLICY_SAFE_DENY_NAMES — denying it does not
  # restrict the harness.
  write_policy_profile '{"deny":["web_fetch"]}'
  run "$SCRIPT" "$PROFILE"
  [ "$status" -eq 0 ]
}

@test "check8: deny of every safe name at once PASSES" {
  write_policy_profile '{"deny":["web_fetch","x_search","memory_search","memory_get","dashboard","canvas","show_widget","message","heartbeat_respond","automations","gateway","skill_workshop","image_generate","music_generate","video_generate","tts"]}'
  run "$SCRIPT" "$PROFILE"
  [ "$status" -eq 0 ]
}

@test "check8: sentry__* deny FAILS (the 2026-09-10 incident shape)" {
  write_policy_profile '{"deny":["sentry__*"]}'
  run "$SCRIPT" "$PROFILE"
  [ "$status" -eq 1 ]
  [[ "$output" == *"RESTRICT the codex harness"* ]]
  [[ "$output" == *'deny "sentry__*"'* ]]
}

@test "check8: a bare MCP tool id (no glob) also FAILS" {
  # isKnownCoreToolId() is false for any MCP tool, glob or not — dropping the
  # wildcard is not a workaround.
  write_policy_profile '{"deny":["sentry__update_issue"]}'
  run "$SCRIPT" "$PROFILE"
  [ "$status" -eq 1 ]
  [[ "$output" == *'deny "sentry__update_issue"'* ]]
}

@test "check8: web_search deny FAILS — it is NOT in the safe list despite being a core tool" {
  # The trap that makes this gate worth having: web_fetch is safe, web_search is
  # not. They look interchangeable and are not.
  write_policy_profile '{"deny":["web_search"]}'
  run "$SCRIPT" "$PROFILE"
  [ "$status" -eq 1 ]
  [[ "$output" == *'deny "web_search"'* ]]
}

@test "check8: exec deny FAILS on an un-excepted agent" {
  write_policy_profile '{"deny":["exec"]}'
  run "$SCRIPT" "$PROFILE"
  [ "$status" -eq 1 ]
  [[ "$output" == *'deny "exec"'* ]]
}

@test "check8: a mixed deny reports ONLY the unsafe entries" {
  write_policy_profile '{"deny":["web_fetch","sentry__*","tts"]}'
  run "$SCRIPT" "$PROFILE"
  [ "$status" -eq 1 ]
  [[ "$output" == *'deny "sentry__*"'* ]]
  [[ "$output" != *'deny "web_fetch"'* ]]
  [[ "$output" != *'deny "tts"'* ]]
}

@test "check8: narrowing allow-list (no wildcard) FAILS" {
  # toolPolicyRestrictsTools({allow}) short-circuits before the safe-deny branch
  # is ever reached, so allow is not an escape hatch from a deny.
  write_policy_profile '{"allow":["exec","web_search"]}'
  run "$SCRIPT" "$PROFILE"
  [ "$status" -eq 1 ]
  [[ "$output" == *"narrowing allow-list"* ]]
}

@test "check8: allow:[\"*\"] PASSES" {
  write_policy_profile '{"allow":["*"]}'
  run "$SCRIPT" "$PROFILE"
  [ "$status" -eq 0 ]
}

@test "check8: empty allow array PASSES" {
  write_policy_profile '{"allow":[]}'
  run "$SCRIPT" "$PROFILE"
  [ "$status" -eq 0 ]
}

@test "check8: a GLOBAL tools.deny FAILS — it restricts every agent at once" {
  write_policy_profile 'OMIT' 'x' 'openclaw-test.json' \
    '{ "exec": { "security": "full" }, "deny": ["sentry__*"] }'
  run "$SCRIPT" "$PROFILE"
  [ "$status" -eq 1 ]
  [[ "$output" == *"<global>"* ]]
}

# Captain 2026-10-28 12:1xZ / 12:3xZ: support denies exec + the 14 verification/merge plugin tools.
SUPPORT_DENY='["exec","credits_verify","credit_verification_check","profiles_claim_self","profiles_consolidate","profile_claim_status","profile_credits_status","dedupe_check","remove_credits","credit_status_lookup","document_intake","merge_request_intake","credit_trust_handoff","merge_intake","proof_on_file"]'

@test "check8: documented exception (edge:support: exec + the 14 verification/merge tools) PASSES" {
  write_policy_profile "{\"deny\":$SUPPORT_DENY}" 'support' 'openclaw-edge.json'
  run "$SCRIPT" "$PROFILE"
  [ "$status" -eq 0 ]
}

@test "check8: support dropping a verification/merge deny is a STALE exception (red build, never a silent re-open)" {
  write_policy_profile '{"deny":["exec"]}' 'support' 'openclaw-edge.json'
  run "$SCRIPT" "$PROFILE"
  [ "$status" -eq 1 ]
  [[ "$output" == *'STALE EXCEPTION "openclaw-edge.json:support:dedupe_check"'* ]]
}

@test "check8: documented exception (main:operations:web_search) PASSES" {
  write_policy_profile '{"deny":["web_fetch","web_search"]}' 'operations' 'openclaw-main.json'
  add_scout_agent
  run "$SCRIPT" "$PROFILE"
  [ "$status" -eq 0 ]
}

@test "check8: documented exception (main:scout shell lockdown, exec-lever 2026-11-01) PASSES" {
  write_policy_profile '{"deny":["web_fetch","web_search"]}' 'operations' 'openclaw-main.json'
  add_scout_agent
  jq -e '.agents.list[] | select(.id=="scout") | .tools.deny | index("lobster")' "$PROFILE" >/dev/null
  run "$SCRIPT" "$PROFILE"
  [ "$status" -eq 0 ]
}

@test "check8: scout dropping lobster leaves a STALE exception (red build, never a silent re-open)" {
  write_policy_profile '{"deny":["web_fetch","web_search"]}' 'operations' 'openclaw-main.json'
  add_scout_agent 'map(select(. != "lobster"))'
  run "$SCRIPT" "$PROFILE"
  [ "$status" -eq 1 ]
  [[ "$output" == *'STALE EXCEPTION "openclaw-main.json:scout:lobster"'* ]]
}

@test "check8: exception is scoped to its AGENT — same deny elsewhere still FAILS" {
  write_policy_profile '{"deny":["exec"]}' 'scout' 'openclaw-edge.json'
  run "$SCRIPT" "$PROFILE"
  [ "$status" -eq 1 ]
  [[ "$output" == *'deny "exec"'* ]]
}

@test "check8: exception is scoped to its CONFIG — same agent+deny in the other profile FAILS" {
  write_policy_profile '{"deny":["exec"]}' 'support' 'openclaw-main.json'
  run "$SCRIPT" "$PROFILE"
  [ "$status" -eq 1 ]
  [[ "$output" == *'deny "exec"'* ]]
}

@test "check8: exception is scoped to its TOOL — excepted agent denying something else FAILS" {
  write_policy_profile '{"deny":["exec","sentry__*"]}' 'support' 'openclaw-edge.json'
  run "$SCRIPT" "$PROFILE"
  [ "$status" -eq 1 ]
  [[ "$output" == *'deny "sentry__*"'* ]]
  [[ "$output" != *'deny "exec"'* ]]
}

@test "check8: a STALE exception FAILS — the excepted agent no longer carries the deny" {
  # Borrowed from .skill-workspace-divergence.txt: an exception that outlives its
  # deny is a standing pre-authorisation for a re-add nobody reviews. `operations`
  # is excepted for web_search in openclaw-main.json; drop that deny and the
  # exception must be reported, not silently kept.
  write_policy_profile '{"deny":["web_fetch"]}' 'operations' 'openclaw-main.json'
  run "$SCRIPT" "$PROFILE"
  [ "$status" -eq 1 ]
  [[ "$output" == *"STALE EXCEPTION"* ]]
  [[ "$output" == *"operations no longer denies"* ]]
}

@test "check8: an exception for the OTHER config is not judged stale here" {
  # openclaw-edge.json:support:exec must not be reported while validating a
  # main-profile fixture — it is not applicable to this file, not stale.
  write_policy_profile '{"deny":["web_fetch","web_search"]}' 'operations' 'openclaw-main.json'
  add_scout_agent
  run "$SCRIPT" "$PROFILE"
  [ "$status" -eq 0 ]
  [[ "$output" != *"support"* ]]
}

@test "check8: agents.entries{} shape is checked too — unsafe deny FAILS" {
  # The >=2026.8 doctor rewrites live configs from list[] to entries{}. A gate
  # that only reads .agents.list finds zero agents here and passes silently.
  write_entries_profile '{"deny":["sentry__*"]}'
  run "$SCRIPT" "$PROFILE"
  [ "$status" -eq 1 ]
  [[ "$output" == *'deny "sentry__*"'* ]]
}

@test "check8: agents.entries{} shape with a safe deny PASSES" {
  write_entries_profile '{"deny":["web_fetch"]}'
  run "$SCRIPT" "$PROFILE"
  [ "$status" -eq 0 ]
}

@test "check8: NEITHER agents shape present FAILS LOUD (never reported clean)" {
  # A config the gate cannot parse is a finding, not a clean bill of health.
  cat > "$PROFILE" <<'JSON'
{
  "agents": { "defaults": { "thinkingDefault": "medium",
    "model": { "primary": "openai/gpt-5.6-sol",
      "fallbacks": ["openrouter/openai/gpt-5.6-luna","openrouter/anthropic/claude-haiku-4.5"] } } },
  "plugins": { "allow": ["codex"] },
  "tools": { "exec": { "security": "full" } }
}
JSON
  declare_model_catalog
  run "$SCRIPT" "$PROFILE"
  [ "$status" -eq 1 ]
  [[ "$output" == *"neither .agents.list[] nor .agents.entries{}"* ]]
}

@test "check8: an agents.defaults.tools deny FAILS — it reaches every agent" {
  # openclaw resolves agent keys as
  # `resolveAgentConfig(cfg, id)?.<key> ?? cfg.agents.defaults.<key>`, so a deny
  # parked in defaults restricts every agent carrying no `tools` of its own. A
  # gate reading only `.tools` and `.agents.list[].tools` reports "all checks
  # passed" on it — the same silent zero-coverage this check exists to prevent.
  write_policy_profile 'OMIT'
  jq '.agents.defaults.tools = {"deny":["sentry__*"]}' "$PROFILE" > "$PROFILE.tmp"
  mv "$PROFILE.tmp" "$PROFILE"
  run "$SCRIPT" "$PROFILE"
  [ "$status" -eq 1 ]
  [[ "$output" == *"<agents.defaults>"* ]]
  [[ "$output" == *'deny "sentry__*"'* ]]
}

@test "check8: a SAFE deny in agents.defaults still PASSES" {
  write_policy_profile 'OMIT'
  jq '.agents.defaults.tools = {"deny":["web_fetch"]}' "$PROFILE" > "$PROFILE.tmp"
  mv "$PROFILE.tmp" "$PROFILE"
  run "$SCRIPT" "$PROFILE"
  [ "$status" -eq 0 ]
}

@test "check8: a GLOBAL tools.byProvider deny FAILS (QA #929 finding 1 repro)" {
  # openclaw resolves tools.byProvider.<provider> as globalProviderPolicy, which
  # sits in the SAME explicitPolicies list a direct deny does — so it restricts
  # the codex harness identically, while a gate reading only .tools.deny returns
  # success. Reproduced on the real config 2026-09-11: "all checks passed", exit 0.
  write_policy_profile 'OMIT' 'x' 'openclaw-test.json' \
    '{ "exec": { "security": "full" }, "byProvider": { "openai": { "deny": ["sentry__*"] } } }'
  run "$SCRIPT" "$PROFILE"
  [ "$status" -eq 1 ]
  [[ "$output" == *"byProvider.openai"* ]]
  [[ "$output" == *'deny "sentry__*"'* ]]
}

@test "check8: a PER-AGENT tools.byProvider deny FAILS" {
  write_policy_profile '{"byProvider":{"openai":{"deny":["sentry__*"]}}}' 'scout'
  run "$SCRIPT" "$PROFILE"
  [ "$status" -eq 1 ]
  [[ "$output" == *"scout @"* ]]
  [[ "$output" == *"byProvider.openai"* ]]
}

@test "check8: an agents.defaults tools.byProvider deny FAILS" {
  write_policy_profile 'OMIT'
  jq '.agents.defaults.tools = {"byProvider":{"openai":{"deny":["sentry__*"]}}}' "$PROFILE" > "$PROFILE.tmp"
  mv "$PROFILE.tmp" "$PROFILE"
  run "$SCRIPT" "$PROFILE"
  [ "$status" -eq 1 ]
  [[ "$output" == *"<agents.defaults> @"* ]]
  [[ "$output" == *"byProvider.openai"* ]]
}

@test "check8: a narrowing allow via byProvider FAILS" {
  write_policy_profile 'OMIT' 'x' 'openclaw-test.json' \
    '{ "exec": { "security": "full" }, "byProvider": { "openai": { "allow": ["exec"] } } }'
  run "$SCRIPT" "$PROFILE"
  [ "$status" -eq 1 ]
  [[ "$output" == *"narrowing allow-list"* ]]
}

@test "check8: a SAFE deny via byProvider PASSES" {
  write_policy_profile 'OMIT' 'x' 'openclaw-test.json' \
    '{ "exec": { "security": "full" }, "byProvider": { "openai": { "deny": ["web_fetch"] } } }'
  run "$SCRIPT" "$PROFILE"
  [ "$status" -eq 0 ]
}

@test "check8: byProvider across MULTIPLE providers each get evaluated" {
  write_policy_profile 'OMIT' 'x' 'openclaw-test.json' \
    '{ "exec": { "security": "full" }, "byProvider": { "openai": { "deny": ["web_fetch"] }, "openrouter": { "deny": ["sentry__*"] } } }'
  run "$SCRIPT" "$PROFILE"
  [ "$status" -eq 1 ]
  [[ "$output" == *"byProvider.openrouter"* ]]
  [[ "$output" != *"byProvider.openai"* ]]
}

@test "check8: an EMPTY agents.list[] FAILS LOUD (zero agents is zero evidence)" {
  # A parseable shape holding no agents evaluates nothing. Reporting that as
  # clean is the same false green as reading the wrong shape entirely.
  write_policy_profile 'OMIT'
  jq '.agents.list = []' "$PROFILE" > "$PROFILE.tmp"; mv "$PROFILE.tmp" "$PROFILE"
  run "$SCRIPT" "$PROFILE"
  [ "$status" -eq 1 ]
  [[ "$output" == *"ZERO agents"* ]]
}

@test "check8: an EMPTY agents.entries{} FAILS LOUD too" {
  write_policy_profile 'OMIT'
  jq '.agents.entries = {} | del(.agents.list)' "$PROFILE" > "$PROFILE.tmp"
  mv "$PROFILE.tmp" "$PROFILE"
  run "$SCRIPT" "$PROFILE"
  [ "$status" -eq 1 ]
  [[ "$output" == *"ZERO agents"* ]]
}

# ──────────────────────────────────────────────────────────────
# One case per CONFIG-EXPRESSIBLE member of explicitPolicies
# (dist/selection-Bge6N4vD.js:746-758). Round 1 covered only globalPolicy /
# agentPolicy, round 2 added the *ProviderPolicy pair, and review immediately
# found senderPolicy next with groupPolicy behind it. check #8 no longer
# enumerates keys — it walks every object under a `tools` path carrying a
# deny/allow — so these cases pin the holders we know about AND the walk that
# makes future ones free.
# ──────────────────────────────────────────────────────────────

@test "check8: senderPolicy — GLOBAL tools.toolsBySender deny FAILS (QA v3 finding 2)" {
  write_policy_profile 'OMIT' 'x' 'openclaw-test.json' \
    '{ "exec": { "security": "full" }, "toolsBySender": { "*": { "deny": ["sentry__*"] } } }'
  run "$SCRIPT" "$PROFILE"
  [ "$status" -eq 1 ]
  [[ "$output" == *"toolsBySender"* ]]
}

@test "check8: senderPolicy — PER-AGENT tools.toolsBySender deny FAILS" {
  write_policy_profile '{"toolsBySender":{"*":{"deny":["sentry__*"]}}}' 'scout'
  run "$SCRIPT" "$PROFILE"
  [ "$status" -eq 1 ]
  [[ "$output" == *"scout @"* ]]
  [[ "$output" == *"toolsBySender"* ]]
}

@test "check8: senderPolicy — a narrowing allow via toolsBySender FAILS" {
  write_policy_profile 'OMIT' 'x' 'openclaw-test.json' \
    '{ "exec": { "security": "full" }, "toolsBySender": { "*": { "allow": ["exec"] } } }'
  run "$SCRIPT" "$PROFILE"
  [ "$status" -eq 1 ]
  [[ "$output" == *"narrowing allow-list"* ]]
}

@test "check8: senderPolicy — a SAFE deny via toolsBySender PASSES" {
  write_policy_profile 'OMIT' 'x' 'openclaw-test.json' \
    '{ "exec": { "security": "full" }, "toolsBySender": { "*": { "deny": ["web_fetch"] } } }'
  run "$SCRIPT" "$PROFILE"
  [ "$status" -eq 0 ]
}

@test "check8: groupPolicy — a channel group tools deny FAILS" {
  write_policy_profile 'OMIT'
  jq '.channels = {"slack":{"accounts":{"main":{"groups":{"G1":{"tools":{"deny":["sentry__*"]}}}}}}}' \
    "$PROFILE" > "$PROFILE.tmp" && mv "$PROFILE.tmp" "$PROFILE"
  run "$SCRIPT" "$PROFILE"
  [ "$status" -eq 1 ]
  [[ "$output" == *"channels.slack.accounts.main.groups.G1.tools"* ]]
}

@test "check8: the walk reports the JSON PATH, so a reviewer can find the holder" {
  write_policy_profile '{"deny":["sentry__*"]}' 'scout'
  run "$SCRIPT" "$PROFILE"
  [ "$status" -eq 1 ]
  [[ "$output" == *"@ agents.list."*".tools"* ]]
}

@test "check8: plugins.allow is NOT a tool policy and must not be flagged" {
  # A naive "any object with deny/allow" walk flags plugins.allow (the plugin
  # allowlist). The `tools`-segment scope is what keeps it out; without that
  # scope every config in the repo fails this gate.
  write_policy_profile 'OMIT'
  jq '.plugins = {"allow":["codex"],"entries":{}}' "$PROFILE" > "$PROFILE.tmp" && mv "$PROFILE.tmp" "$PROFILE"
  run "$SCRIPT" "$PROFILE"
  [ "$status" -eq 0 ]
}

@test "check8: an UNKNOWN future tools subtree is covered for free by the walk" {
  # The point of the generic walk: a holder openclaw has not shipped yet, or one
  # this repo has never seen, is caught without another review round.
  write_policy_profile 'OMIT' 'x' 'openclaw-test.json' \
    '{ "exec": { "security": "full" }, "someFutureScope": { "k": { "deny": ["sentry__*"] } } }'
  run "$SCRIPT" "$PROFILE"
  [ "$status" -eq 1 ]
  [[ "$output" == *"someFutureScope"* ]]
}
