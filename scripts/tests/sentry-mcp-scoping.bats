#!/usr/bin/env bats
#
# openclaw-main.json — NO agent may carry a `sentry__*` deny, IN THE COMMITTED
# CONFIG. This file used to assert the exact OPPOSITE; the inversion is the
# 2026-09-10 incident, kept here rather than deleted because the reversed
# assertion is the thing a future reader is most likely to re-add.
#
# WHY IT INVERTED: on openclaw >= 2026.8 the codex harness declares
# `conversationToolPolicySupport:"exact"`, and `sentry__*` fails
# `isKnownCoreToolId`, so the deny makes
# `toolPolicyRestrictsHarnessNativeTools()` mark the agent's policy RESTRICTED
# and `shouldEnableCodexAppServerNativeToolSurface()` returns false on its first
# line — silently stripping the agent's entire codex native tool surface (web
# search, shell, image generation, browser, skill search, memories). The
# 2026.8.2 cutover did exactly that to six main agents; Scout told a user its web
# research provider was unavailable. The mechanism is documented ONCE, in
# scripts/validate-config-matrix.sh check #8 and docs/lessons/openclaw-and-codex.md.
#
# There is also no config-level way to scope an MCP server to a subset of agents
# (`canonicalizeConfiguredMcpServer` accepts no agent field), so the choice is
# "every agent sees sentry" or "nobody does". The server is registered UNSCOPED.
#
# WHAT THAT COST, honestly: nothing that was ever containment. Every agent holds
# `exec` at security:full, so /tools/invoke routed around the deny list anyway,
# and the token sits in a config any of them can read -- verified, not
# hypothetical: the live token was found in the codex logs of operations, qa and
# clio. The real bound is, and always was, the token's SCOPES.
#
# WHY COMMITTED AND NOT RUNTIME (2026-08-26): deploy.sh's sync_profile_config
# preserves ONLY `.mcp.servers`, so `agents.list` -- and every tools.deny in it
# -- is overwritten from the repo on every deploy. A runtime-applied deny
# survived ~17 hours and was then silently reverted by a routine deploy. The
# committed config is the only durable form, which is why the assertion lives
# here and reads the repo file.

CFG="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)/openclaw-main.json"


@test "the config is valid JSON with an agents.list array" {
  run jq -e '(.agents.list | type) == "array" and (.agents.list | length) > 0' "$CFG"
  [ "$status" -eq 0 ]
}

@test "NO agent carries a sentry deny — it is a codex native-surface kill switch" {
  # The 2026-09-10 inversion. Any sentry entry, wildcard or literal, restricts
  # that agent's codex harness and silently drops its whole native tool surface.
  run jq -e '
    [ .agents.list[]
      | select(((.tools.deny // []) | map(select(startswith("sentry__"))) | length) > 0)
      | .id ] | length == 0' "$CFG"
  [ "$status" -eq 0 ]
}

@test "the GLOBAL tools policy carries no sentry deny either" {
  # A global deny restricts every agent at once — the same kill switch, fleet-wide.
  run jq -e '
    [ (.tools.deny // [])[] | select(startswith("sentry__")) ] | length == 0' "$CFG"
  [ "$status" -eq 0 ]
}

@test "the assertion is not vacuous: the fleet still has its agents" {
  # A config that lost its agents would pass the deny assertion by having
  # nothing to check. Absence must never read as compliance.
  run jq -e '(.agents.list | length) >= 5' "$CFG"
  [ "$status" -eq 0 ]
}

@test "pre-existing non-sentry denials are preserved" {
  # operations denied web_search/web_fetch long before the sentry work, and must
  # still deny them after the sentry ids were stripped out. `web_fetch` is in
  # CODEX_TOOL_POLICY_SAFE_DENY_NAMES; `web_search` is NOT, and is a deliberate
  # exception in validate-config-matrix.sh check #8 (credit verification must
  # not free-text search) -- so operations stays harness-restricted on purpose.
  run jq -e '
    .agents.list[] | select(.id == "operations") | (.tools.deny // [])
    | (index("web_search") != null) and (index("web_fetch") != null)' "$CFG"
  [ "$status" -eq 0 ]
}

@test "the sentry MCP registration is DISABLED in the committed healer" {
  # PR #929 removed the sentry__* denies to restore native web search, which on
  # its own would expose the write-capable sentry__update_issue to all nine
  # agents. The equivalent restriction is the healer's kill switch: with it off,
  # no agent can reach any sentry tool, so the write surface is unchanged (zero
  # before, zero after). This pins that the committed default really is OFF —
  # the repo config cannot express it (`.mcp` is absent there,
  # sync-profile-config.sh preserves the live `.mcp.servers`, and the healer
  # re-registers on every main start), so this constant IS the control.
  # Re-enabling is a deliberate one-line PR carrying Aaron's decision.
  local healer="$(dirname "$CFG")/scripts/lib/ensure-sentry-mcp.sh"
  [ -r "$healer" ]
  run grep -E '^ESM_ENABLED=' "$healer"
  [ "$status" -eq 0 ]
  [[ "$output" == *':-0}'* ]]
}
