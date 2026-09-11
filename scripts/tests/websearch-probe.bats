#!/usr/bin/env bats
# Tests for scripts/lib/websearch-probe.sh — the post-restart web_search
# probe helpers used by scripts/smoke-test.sh's check_web_search (see
# #695/#701 incident: PR #695's tools.web.search.provider:"codex" broke
# web_search fleet-wide and silently, because nothing probed it post-deploy).
#
# PR #704 QA review found two bugs in an earlier inline version of this
# check:
#   FINDING 1 — `response=$(...) || response="TIMEOUT"` clobbered the real
#     output on ANY nonzero exit, so a Reconnecting break that also made the
#     agent process exit non-zero never matched the break regex.
#   FINDING 2 — a PASS was granted on model text alone ("SEARCH_STATUS: ok"),
#     which the model can produce from training data without ever calling
#     web_search.
# These bats cases exercise websearch_probe_attempt end-to-end (PATH-stubbed
# openclaw + a fixture rollout dir) to prove both are fixed:
#   (a) real result: stub replies ok AND the fixture rollout gains a
#       web_search_end event → pass
#   (b) model-only: stub replies "SEARCH_STATUS: ok" but the rollout gains
#       NO web_search_end event → inconclusive (NOT pass, NOT fail)
#   (c) break: stub exits non-zero and emits Reconnecting → fail (regardless
#       of exit code)
#
# PATH-shadows `openclaw` per repo convention (see
# memory/feedback_bats_must_stub_openclaw.md) — nothing here calls the real
# CLI or a live gateway.
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
LIB="$HYDRA_REPO/scripts/lib/websearch-probe.sh"

setup() {
  TEST_TMPDIR="$(mktemp -d)"
  export TEST_TMPDIR

  mkdir -p "$TEST_TMPDIR/bin" "$TEST_TMPDIR/rollouts"
  export WEBSEARCH_PROBE_ROLLOUT_GLOB="$TEST_TMPDIR/rollouts/rollout-*.jsonl"

  # shellcheck disable=SC1090
  source "$LIB"
}

teardown() { rm -rf "$TEST_TMPDIR"; }

# _stub_openclaw <exit_code> <output> <rollout_action> — writes a PATH stub
# for `openclaw` that prints $output and exits $exit_code. rollout_action is
# "append" (simulate a real web_search_end event being written during the
# turn) or "none" (simulate the model replying without ever calling the
# tool) or "skip" (don't touch the rollout fixture at all — used for the
# break case, where no rollout activity is expected either way).
_stub_openclaw() {
  local exit_code="$1" output="$2" rollout_action="$3"
  cat > "$TEST_TMPDIR/bin/openclaw" <<STUB
#!/usr/bin/env bash
STUB
  if [ "$rollout_action" = "append" ]; then
    cat >> "$TEST_TMPDIR/bin/openclaw" <<STUB
echo '{"type":"web_search_end"}' >> "$TEST_TMPDIR/rollouts/rollout-during.jsonl"
STUB
  fi
  cat >> "$TEST_TMPDIR/bin/openclaw" <<STUB
printf '%s\n' "$output"
exit $exit_code
STUB
  chmod +x "$TEST_TMPDIR/bin/openclaw"
  PATH="$TEST_TMPDIR/bin:$PATH"
  export PATH
}

@test "websearch_probe_attempt: real result — rollout gains web_search_end -> pass" {
  _stub_openclaw 0 "SEARCH_STATUS: ok" append
  run websearch_probe_attempt main "probe prompt"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx 'VERDICT=pass'
  echo "$output" | grep -q '^DETAIL=.*web_search_end'
}

@test "websearch_probe_attempt: model-only reply, no rollout evidence -> inconclusive (not pass, not fail)" {
  _stub_openclaw 0 "SEARCH_STATUS: ok" none
  run websearch_probe_attempt main "probe prompt"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx 'VERDICT=inconclusive'
}

@test "websearch_probe_attempt: break signature with NONZERO exit still fails (FINDING 1 — no clobber)" {
  _stub_openclaw 1 "[tools] web_search failed: Reconnecting... 2/5" none
  run websearch_probe_attempt main "probe prompt"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx 'VERDICT=fail'
  echo "$output" | grep -qi '^DETAIL=.*Reconnecting'
}

@test "websearch_probe_attempt: break signature with EXIT ZERO also fails (break wins regardless of rc)" {
  _stub_openclaw 0 "web_search provider reconnection failed" none
  run websearch_probe_attempt main "probe prompt"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx 'VERDICT=fail'
}

@test "websearch_probe_attempt: NO rollout files survives set -euo pipefail (FINDING 3 — no ls-abort)" {
  # The 'run' cases above mask this: 'run' disables set -e, so the pre-fix
  # `ls -t` on an unmatched glob (no prior rollout) never aborted. smoke-test.sh
  # runs under `set -euo pipefail`, so replicate it and call DIRECTLY — with the
  # bug the internal baseline_path=$(...) substitution aborts here; with the fix
  # it completes inconclusive (model text, no rollout evidence).
  _stub_openclaw 0 "SEARCH_STATUS: ok" none
  rm -f "$TEST_TMPDIR"/rollouts/*.jsonl 2>/dev/null || true
  set -euo pipefail
  out="$(websearch_probe_attempt main "probe prompt")"
  printf '%s\n' "$out" | grep -qx 'VERDICT=inconclusive'
}

# ── unit coverage for the pure helpers (no openclaw stub needed) ──────────

@test "_websearch_probe_verdict: break signature wins even when real_call_ran=1" {
  run _websearch_probe_verdict "Reconnecting... 2/5" 1
  [ "$status" -eq 0 ]
  [ "$output" = "fail" ]
}

@test "_websearch_probe_verdict: real_call_ran=1 with clean text -> pass" {
  run _websearch_probe_verdict "SEARCH_STATUS: ok" 1
  [ "$status" -eq 0 ]
  [ "$output" = "pass" ]
}

@test "_websearch_probe_verdict: real_call_ran=0 with clean text -> inconclusive (model text alone is not proof)" {
  run _websearch_probe_verdict "SEARCH_STATUS: ok" 0
  [ "$status" -eq 0 ]
  [ "$output" = "inconclusive" ]
}

@test "_websearch_rollout_hits: 0 for a missing path (no rollout history yet)" {
  run _websearch_rollout_hits "$TEST_TMPDIR/rollouts/does-not-exist.jsonl"
  [ "$status" -eq 0 ]
  [ "$output" = "0" ]
}

@test "_websearch_real_call_ran: brand-new rollout file with a hit counts as a real call" {
  run _websearch_real_call_ran main "" 0
  [ "$status" -eq 0 ]
  [ "$output" = "0" ]
  echo '{"type":"web_search_end"}' > "$TEST_TMPDIR/rollouts/rollout-fresh.jsonl"
  run _websearch_real_call_ran main "" 0
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
}

# ──────────────────────────────────────────────────────────────
# Deny-aware scoping (item i, 2026-09-11). The GLOBAL verdict comes from a
# deny-free reference agent and stays a hard FAIL; a scout-ONLY failure
# degrades to WARN naming the policy. The rollout-event standard is unchanged:
# a pass still requires a real web_search_end, never reply text.
# ──────────────────────────────────────────────────────────────

mk_cfg() {
  export WEBSEARCH_PROBE_CONFIG="$TEST_TMPDIR/cfg.json"
  printf '%s\n' "$1" > "$WEBSEARCH_PROBE_CONFIG"
}

@test "reference agent: prefers qa when it is deny-free" {
  mk_cfg '{"agents":{"list":[{"id":"scout","tools":{"deny":["sentry__*"]}},{"id":"qa"},{"id":"cto"}]}}'
  [ "$(websearch_reference_agent main)" = "qa" ]
}

@test "reference agent: falls back to cto when qa is restricted" {
  mk_cfg '{"agents":{"list":[{"id":"qa","tools":{"deny":["sentry__*"]}},{"id":"cto"}]}}'
  [ "$(websearch_reference_agent main)" = "cto" ]
}

@test "reference agent: falls back to ANY deny-free agent when qa and cto are both restricted" {
  mk_cfg '{"agents":{"list":[{"id":"qa","tools":{"deny":["sentry__*"]}},{"id":"cto","tools":{"deny":["sentry__*"]}},{"id":"ceo"}]}}'
  [ "$(websearch_reference_agent main)" = "ceo" ]
}

@test "reference agent: EMPTY when every agent is restricted (caller must fail closed)" {
  mk_cfg '{"agents":{"list":[{"id":"qa","tools":{"deny":["sentry__*"]}},{"id":"cto","tools":{"deny":["sentry__*"]}}]}}'
  [ -z "$(websearch_reference_agent main)" ]
}

@test "reference agent: a SAFE deny does not disqualify an agent" {
  mk_cfg '{"agents":{"list":[{"id":"qa","tools":{"deny":["web_fetch"]}},{"id":"cto"}]}}'
  [ "$(websearch_reference_agent main)" = "qa" ]
}

@test "restriction: names the agent policy path that causes it" {
  mk_cfg '{"agents":{"list":[{"id":"scout","tools":{"deny":["sentry__*"]}}]}}'
  run websearch_agent_restriction main scout
  [[ "$output" == *"agents.list[id=scout].tools.deny"* ]]
  [[ "$output" == *"sentry__*"* ]]
}

@test "restriction: sees a byProvider deny too" {
  mk_cfg '{"agents":{"list":[{"id":"scout","tools":{"byProvider":{"openai":{"deny":["sentry__*"]}}}}]}}'
  run websearch_agent_restriction main scout
  [[ "$output" == *"byProvider.openai"* ]]
}

@test "restriction: empty for a deny-free agent" {
  mk_cfg '{"agents":{"list":[{"id":"scout"}]}}'
  [ -z "$(websearch_agent_restriction main scout)" ]
}

@test "restriction: a narrowing allow counts" {
  mk_cfg '{"agents":{"list":[{"id":"scout","tools":{"allow":["exec"]}}]}}'
  run websearch_agent_restriction main scout
  [[ "$output" == *".allow"* ]]
}

@test "the rollout-event standard is unchanged: reply text alone is never a pass" {
  # Guards the one thing item i must NOT relax.
  [ "$(_websearch_probe_verdict 'SEARCH_STATUS: ok' 0)" = "inconclusive" ]
  [ "$(_websearch_probe_verdict 'SEARCH_STATUS: ok' 1)" = "pass" ]
}

@test "the probe targets the agent it is given, not a hardcoded scout" {
  # setup() exports WEBSEARCH_PROBE_ROLLOUT_GLOB, which deliberately overrides the
  # per-agent path; unset it to assert the DEFAULT construction.
  unset WEBSEARCH_PROBE_ROLLOUT_GLOB
  run _websearch_rollout_glob main qa
  [[ "$output" == *"/agents/qa/agent/codex-home/"* ]]
  run _websearch_rollout_glob main scout
  [[ "$output" == *"/agents/scout/agent/codex-home/"* ]]
}

@test "restriction: sees a toolsBySender deny (holder parity with check #8)" {
  # A detector that knows fewer holders than the gate reports "no policy explains
  # it" for a real restriction, which turns an attributable WARN back into a
  # false hard FAIL — the exact failure this change exists to remove.
  mk_cfg '{"agents":{"list":[{"id":"scout","tools":{"toolsBySender":{"*":{"deny":["sentry__*"]}}}}]}}'
  run websearch_agent_restriction main scout
  [[ "$output" == *"toolsBySender"* ]]
  [[ "$output" == *"agents.list[id=scout]"* ]]
}

@test "restriction: sees a GLOBAL tools deny that reaches every agent" {
  mk_cfg '{"tools":{"deny":["sentry__*"]},"agents":{"list":[{"id":"scout"}]}}'
  run websearch_agent_restriction main scout
  [[ "$output" == *"tools.deny"* ]]
}

@test "restriction: sees an agents.defaults deny" {
  mk_cfg '{"agents":{"defaults":{"tools":{"deny":["sentry__*"]}},"list":[{"id":"scout"}]}}'
  run websearch_agent_restriction main scout
  [[ "$output" == *"agents.defaults.tools.deny"* ]]
}

@test "restriction: does NOT claim ANOTHER agent's policy" {
  # Misattributing qa's deny to scout would name the wrong cause in the WARN.
  mk_cfg '{"agents":{"list":[{"id":"qa","tools":{"deny":["sentry__*"]}},{"id":"scout"}]}}'
  [ -z "$(websearch_agent_restriction main scout)" ]
}

@test "restriction: does NOT claim a channel-group policy (not statically attributable)" {
  # Group policies are session-scoped — they depend on which group the turn
  # arrives in. Claiming one would be a guess; unattributed means the caller
  # fails closed, which is the safe direction.
  mk_cfg '{"agents":{"list":[{"id":"scout"}]},"channels":{"slack":{"accounts":{"main":{"groups":{"G1":{"tools":{"deny":["sentry__*"]}}}}}}}}'
  [ -z "$(websearch_agent_restriction main scout)" ]
}

# ──────────────────────────────────────────────────────────────
# EXHAUSTIVE (ref, scout, restriction) MATRIX — every cell asserted.
#
# QA #933 round 2 found (inconclusive, fail, restriction) returning WARN: Step 7
# would let a deploy proceed with NO deny-free agent having produced any
# web_search_end evidence. It was the one combination the earlier ad-hoc cases
# did not cover. Enumerating the whole space is the fix for the CLASS — a cell
# cannot be missed if every cell is named.
#
# ref: pass | fail | inconclusive | "" (no deny-free agent exists)
# scout: pass | fail | inconclusive
# restriction: "" (none attributable) | named
#
# RULES: a failed deny-free reference is a global outage (fail, always). WARN
# requires ref == pass — POSITIVE evidence — AND a named restriction. Every other
# broken-scout cell fails closed. With scout not broken, only a passing reference
# yields pass; anything else is inconclusive.
# ──────────────────────────────────────────────────────────────

assert_verdict() { # <ref> <scout> <restriction> <expected>
  local got; got="$(websearch_scoped_verdict "$1" "$2" "$3")"
  if [ "$got" != "$4" ]; then
    echo "($1, $2, '$3') => $got, expected $4" >&2
    return 1
  fi
}

@test "matrix: ref=fail is a global outage in EVERY cell" {
  for sc in pass fail inconclusive; do
    assert_verdict fail "$sc" ""      fail
    assert_verdict fail "$sc" "named" fail
  done
}

@test "matrix: ref=pass, scout=fail — WARN only with a named restriction" {
  assert_verdict pass fail "named" warn
  assert_verdict pass fail ""      fail
}

@test "matrix: ref=pass, scout not broken => pass" {
  for sc in pass inconclusive; do
    assert_verdict pass "$sc" ""      pass
    assert_verdict pass "$sc" "named" pass
  done
}

@test "matrix: ref=inconclusive NEVER yields WARN (QA #933 round 2)" {
  # The reported hole. An unproven reference is not evidence the fleet is fine,
  # so a broken scout must not be downgraded on it however well-named the policy.
  assert_verdict inconclusive fail "named" fail
  assert_verdict inconclusive fail ""      fail
}

@test "matrix: ref=inconclusive, scout not broken => inconclusive" {
  for sc in pass inconclusive; do
    assert_verdict inconclusive "$sc" ""      inconclusive
    assert_verdict inconclusive "$sc" "named" inconclusive
  done
}

@test "matrix: no reference agent at all NEVER yields WARN" {
  assert_verdict "" fail "named" fail
  assert_verdict "" fail ""      fail
}

@test "matrix: no reference agent, scout not broken => inconclusive" {
  for sc in pass inconclusive; do
    assert_verdict "" "$sc" ""      inconclusive
    assert_verdict "" "$sc" "named" inconclusive
  done
}

@test "matrix: WARN is reachable from EXACTLY ONE of the 24 cells" {
  # Guards against a future loosening that quietly widens the deploy-proceeds
  # path: count every cell and assert exactly one warn.
  local warns=0 total=0 v
  for r in pass fail inconclusive ""; do
    for sc in pass fail inconclusive; do
      for rest in "" "named"; do
        v="$(websearch_scoped_verdict "$r" "$sc" "$rest")"
        total=$((total + 1))
        [ "$v" = "warn" ] && warns=$((warns + 1))
      done
    done
  done
  [ "$total" -eq 24 ]
  [ "$warns" -eq 1 ]
}

@test "defaults: a restrictive agents.defaults is SHADOWED by an agent-level tools:{} (QA #933 r3)" {
  # openclaw resolves agent keys with NULLISH coalescing:
  #   resolveAgentConfig(cfg, agentId)?.tools ?? cfg.agents.defaults.tools
  # so a PRESENT but deny-free agent tools:{} shadows a restrictive default.
  # Treating defaults as unconditional would reject qa as a reference and turn a
  # per-agent restriction into a hard deploy block.
  mk_cfg '{"agents":{"defaults":{"tools":{"deny":["sentry__*"]}},"list":[{"id":"qa","tools":{}},{"id":"scout"}]}}'
  [ -z "$(websearch_agent_restriction main qa)" ]
  [ "$(websearch_reference_agent main)" = "qa" ]
}

@test "defaults: the INVERSE — no agent-level tools means defaults DO apply" {
  mk_cfg '{"agents":{"defaults":{"tools":{"deny":["sentry__*"]}},"list":[{"id":"qa"},{"id":"scout"}]}}'
  run websearch_agent_restriction main qa
  [[ "$output" == *"agents.defaults.tools.deny"* ]]
  [ -z "$(websearch_reference_agent main)" ]
}

@test "defaults: an agent-level tools with its OWN unsafe deny is still restricted" {
  # Shadowing the default must not make a genuinely restrictive agent look clean.
  mk_cfg '{"agents":{"defaults":{"tools":{}},"list":[{"id":"qa","tools":{"deny":["sentry__*"]}},{"id":"cto"}]}}'
  run websearch_agent_restriction main qa
  [[ "$output" == *"sentry__*"* ]]
  [ "$(websearch_reference_agent main)" = "cto" ]
}
