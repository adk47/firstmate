#!/usr/bin/env bats
#
# openclaw-main.json — the Sentry MCP tools must stay denied to every agent
# except cto and qa, IN THE COMMITTED CONFIG.
#
# WHY COMMITTED AND NOT RUNTIME (2026-08-26): the original recipe applied this
# scoping with a runtime `jq` transform against the live config. That could never
# have persisted: deploy.sh's sync_profile_config preserves ONLY `.mcp.servers`,
# so `agents.list` -- and every tools.deny in it -- is overwritten from the repo
# on every deploy. The runtime scoping survived ~17 hours and was then silently
# reverted by a routine deploy. Committed config is the ONLY form of this that
# survives, which is why it lives here and why this test exists.
#
# HONESTY ABOUT WHAT THIS BUYS: tools.deny is defence in depth, NOT containment.
# Every agent holds `exec` at security:full, so /tools/invoke routes around a
# deny list, and the token sits in a config any of them can read -- verified, not
# hypothetical: the live token was found in the codex logs of operations, qa and
# clio. The real bound is the token's SCOPES. This test stops accidental and
# ordinary use by the other seven, and makes the intent explicit and reviewable.

CFG="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)/openclaw-main.json"

# WHY A WILDCARD AND NOT THE NINE IDS: `tools.deny` entries are compiled as GLOB
# patterns, not literal set membership. Verified in the running runtime
# (openclaw 2026.7.1, dist/tool-policy-match-*.js):
#
#   makeToolPolicyMatcher -> compileGlobPatterns(policy.deny) -> compileGlobPattern:
#     "*"            -> {kind:"all"}
#     no "*"         -> {kind:"exact"}
#     contains "*"   -> {kind:"regex", value:/^...replaceAll("\*",".*")...$/}
#
# So `sentry__*` compiles to /^sentry__.*$/ and covers tools that do not exist
# yet. Enumerating today's nine ids would leave a future `sentry__delete_issue`
# available to every excluded agent WITH THIS SUITE STILL GREEN -- a test that
# cannot fail on the case it exists to prevent.
#
# NOTE: docs/lessons/openclaw-and-codex.md and RUNBOOK previously asserted
# "literal Set-membership with NO glob expansion". That was wrong and is
# corrected in the same commit as this test.
SENTRY_GLOB="sentry__*"

@test "the config is valid JSON with an agents.list array" {
  run jq -e '(.agents.list | type) == "array" and (.agents.list | length) > 0' "$CFG"
  [ "$status" -eq 0 ]
}

@test "every agent except cto and qa denies sentry via the DURABLE wildcard" {
  run jq -e --arg g "$SENTRY_GLOB" '
    [ .agents.list[]
      | select(.id != "cto" and .id != "qa")
      | select(((.tools.deny // []) | index($g)) == null) ] | length == 0' "$CFG"
  [ "$status" -eq 0 ]
}

@test "the wildcard covers a tool that does not exist yet" {
  # The regression this file exists for: an enumerated list stays green while a
  # newly-added Sentry tool is wide open. Simulate the matcher openclaw uses.
  run bash -c '
    pat="$1"; probe="$2"
    case "$pat" in
      *"*"*) rx="^${pat%%\**}.*$" ;;
      *)     rx="^${pat}$" ;;
    esac
    [[ "$probe" =~ $rx ]]' _ "$SENTRY_GLOB" "sentry__delete_issue"
  [ "$status" -eq 0 ]
}

@test "no agent still carries a brittle enumerated sentry id" {
  # Belt and braces: a stray literal id alongside the glob is dead weight and a
  # hint someone re-introduced the enumeration.
  run jq -e '
    [ .agents.list[] | (.tools.deny // [])[]
      | select(startswith("sentry__")) | select(. != "sentry__*") ] | length == 0' "$CFG"
  [ "$status" -eq 0 ]
}

@test "cto and qa deny NO sentry tools (they are the intended users)" {
  run jq -e '
    [ .agents.list[]
      | select(.id == "cto" or .id == "qa")
      | (.tools.deny // []) | map(select(startswith("sentry__"))) | length ]
    | add == 0' "$CFG"
  [ "$status" -eq 0 ]
}

@test "the scoping is not vacuous: there IS more than one non-cto/qa agent" {
  # A config that lost its agents would pass the deny assertion by having
  # nothing to check. Absence must never read as compliance.
  run jq -e '[ .agents.list[] | select(.id != "cto" and .id != "qa") ] | length >= 5' "$CFG"
  [ "$status" -eq 0 ]
}

@test "pre-existing non-sentry denials are preserved" {
  # operations denied web_search/web_fetch long before this change; merging the
  # sentry ids must not have dropped them.
  run jq -e '
    .agents.list[] | select(.id == "operations") | (.tools.deny // [])
    | (index("web_search") != null) and (index("web_fetch") != null)' "$CFG"
  [ "$status" -eq 0 ]
}
