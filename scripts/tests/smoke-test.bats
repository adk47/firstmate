#!/usr/bin/env bats
# smoke-test.sh — the Step-7 web_search dispatcher branch.
#
# Why this file exists: qa-review 2026-11-04 (PR #1745, finding 1) showed the scoped-verdict matrix was tested but the
# DISPATCHER was not, and the two disagreed. With no deny-free reference agent, `scout=unavailable` fell through the
# no-reference branch's `case` to the generic "inconclusive, not treating as a break" WARN — so a config regression
# that REMOVED the reference was missed whenever scout happened to report provider-unavailable. A pure-function test
# cannot catch that: the bug was in which branch ran, not in what the function returned.
#
# The function is extracted from the script rather than sourced, because smoke-test.sh runs its checks at file scope
# (sourcing it would execute the whole smoke test against the live host).

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  TMP="$BATS_TEST_TMPDIR"
  # extract check_web_search() { ... } up to the first column-0 closing brace
  awk '/^check_web_search\(\) \{/{f=1} f{print} f&&/^\}$/{exit}' "$ROOT/scripts/smoke-test.sh" > "$TMP/fn.sh"
  [ -s "$TMP/fn.sh" ]
  FAILURES=0; WARNINGS=0
  # the dispatcher only runs when the profile's config says web search is enabled; point it at a fixture
  mkdir -p "$TMP/cfg"
  echo '{"tools":{"web":{"search":{"enabled":true}}}}' > "$TMP/cfg/openclaw-main.json"
  export SMOKE_OPENCLAW_CFG_DIR="$TMP/cfg"
  log() { :; }
  fail_check() { FAILURES=$((FAILURES + 1)); }
  pass_check() { :; }
  warn_check() { WARNINGS=$((WARNINGS + 1)); }
  page_websearch_unavailable() { :; }
  # the scoped verdict is the real one: the dispatcher must be tested against the shipped classifier
  # shellcheck source=/dev/null
  . "$ROOT/scripts/lib/websearch-probe.sh"
  # shellcheck source=/dev/null
  . "$TMP/fn.sh"
}

@test "no deny-free reference + scout provider-UNAVAILABLE fails closed (qa #1745 finding 1)" {
  websearch_reference_agent() { echo ""; }
  websearch_probe_attempt() { printf 'VERDICT=unavailable\nDETAIL=disabled or no provider is available\n'; }
  websearch_agent_restriction() { echo ""; }
  check_web_search main
  [ "$FAILURES" -eq 1 ]
  [ "$WARNINGS" -eq 0 ]
}

@test "no deny-free reference + scout PASS still passes (the branch is not blanket-fail)" {
  websearch_reference_agent() { echo ""; }
  websearch_probe_attempt() { printf 'VERDICT=pass\nDETAIL=web_search_end seen\n'; }
  websearch_agent_restriction() { echo ""; }
  check_web_search main
  [ "$FAILURES" -eq 0 ]
}

@test "reference INCONCLUSIVE + scout provider-UNAVAILABLE warns and pages (b1's cell, today's deploy)" {
  websearch_reference_agent() { echo "qa"; }
  websearch_probe_attempt() {
    case "$3" in
      qa)    printf 'VERDICT=inconclusive\nDETAIL=no confirmed tool call\n' ;;
      scout) printf 'VERDICT=unavailable\nDETAIL=disabled or no provider is available\n' ;;
    esac
  }
  websearch_agent_restriction() { echo ""; }
  check_web_search main
  [ "$FAILURES" -eq 0 ]
  [ "$WARNINGS" -eq 1 ]
}

@test "reference PASS + scout provider-UNAVAILABLE warns (provider-side, not a global outage)" {
  websearch_reference_agent() { echo "qa"; }
  websearch_probe_attempt() {
    case "$3" in
      qa)    printf 'VERDICT=pass\nDETAIL=web_search_end seen\n' ;;
      scout) printf 'VERDICT=unavailable\nDETAIL=disabled or no provider is available\n' ;;
    esac
  }
  websearch_agent_restriction() { echo ""; }
  check_web_search main
  [ "$FAILURES" -eq 0 ]
  [ "$WARNINGS" -eq 1 ]
}

@test "reference INCONCLUSIVE + scout real FAIL still fails closed (unchanged)" {
  websearch_reference_agent() { echo "qa"; }
  websearch_probe_attempt() {
    case "$3" in
      qa)    printf 'VERDICT=inconclusive\nDETAIL=no confirmed tool call\n' ;;
      scout) printf 'VERDICT=fail\nDETAIL=web_search tool errored\n' ;;
    esac
  }
  websearch_agent_restriction() { echo ""; }
  check_web_search main
  [ "$FAILURES" -eq 1 ]
}

@test "a policy refusal with NO attributable restriction is a hard fail (unchanged)" {
  websearch_reference_agent() { echo "qa"; }
  websearch_probe_attempt() {
    case "$3" in
      qa)    printf 'VERDICT=pass\nDETAIL=web_search_end seen\n' ;;
      scout) printf 'VERDICT=fail\nDETAIL=not allowed by tool policy\n' ;;
    esac
  }
  websearch_agent_restriction() { echo ""; }
  check_web_search main
  [ "$FAILURES" -eq 1 ]
}

@test "a policy refusal WITH a named restriction warns - the restriction is the explanation" {
  # The classifier still calls a policy refusal `fail` (it is a config regression, never softened); the SCOPED verdict
  # downgrades it only because a named per-agent restriction explains it and the deny-free reference proved search
  # works. That is the per-agent-policy path, and it is deliberately not the same as an unattributable failure.
  websearch_reference_agent() { echo "qa"; }
  websearch_probe_attempt() {
    case "$3" in
      qa)    printf 'VERDICT=pass\nDETAIL=web_search_end seen\n' ;;
      scout) printf 'VERDICT=fail\nDETAIL=not allowed by tool policy\n' ;;
    esac
  }
  websearch_agent_restriction() { echo "tools.deny"; }
  check_web_search main
  [ "$FAILURES" -eq 0 ]
  [ "$WARNINGS" -eq 1 ]
}
