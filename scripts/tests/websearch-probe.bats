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
# 2026-09-11 (codex 0.151.0 under @openclaw/codex 2026.8.2) added three more
# cases, all verified live on node-8 against scout:
#   (d) shape: codex 0.151.0 no longer writes the legacy
#       `{"type":"event_msg","payload":{"type":"web_search_end"}}` line — a
#       real native search is persisted as
#       `{"type":"event_msg","payload":{"type":"item_completed","item":
#       {"type":"Extension","kind":"web.search","results":[...]}}}`. A
#       substring grep for `web_search_end` read 0 for 28h while 17 real
#       searches ran, so the smoke probe could never PASS on 0.151.0.
#   (e) prose: the literal text `"type":"web_search_end"` also occurs INSIDE
#       message payloads (the review bot quotes PR bodies that discuss this
#       very event), so hits are counted by JSON structure, never substring.
#   (f) echo: the hosted search backend summarises results with the recent
#       conversation as input; in scout's persistent `main` session that
#       history carried a prior real outage, and the backend parroted
#       "SEARCH_STATUS: error: web_search is disabled or no provider is
#       available" over 29 real results. So (1) the probe runs in a FRESH
#       --session-id, and (2) positive rollout evidence outranks a break
#       signature in the model text.
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

# Rollout lines in the exact shapes codex writes (verified on node-8):
LEGACY_HIT='{"timestamp":"2026-09-10T12:08:36.000Z","type":"event_msg","payload":{"type":"web_search_end","call_id":"c1","query":"q"}}'
EXTENSION_HIT='{"timestamp":"2026-09-11T16:49:36.000Z","type":"event_msg","payload":{"type":"item_completed","thread_id":"t","turn_id":"u","item":{"type":"Extension","kind":"web.search","id":"exec-1","query":"q","action":{"type":"search","query":"q"},"results":[{"type":"text_result","url":"https://musicbrainz.org/"}]}}}'
# The review bot's rollouts quote PR prose that contains the literal event
# name inside a message string — this line must count as ZERO hits.
PROSE_LINE='{"timestamp":"2026-09-11T10:00:00.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"proof = a \"type\":\"web_search_end\" event in the rollout"}]}}'

# _stub_openclaw <exit_code> <output> <rollout_action> — writes a PATH stub
# for `openclaw` that prints $output and exits $exit_code, and records its
# argv in $TEST_TMPDIR/openclaw.args. rollout_action is "append" (simulate a
# real legacy web_search_end event being written during the turn),
# "append-extension" (the codex 0.151.0 item_completed/Extension shape),
# "append-prose" (a message that merely TALKS about the event) or "none"
# (simulate the model replying without ever calling the tool).
_stub_openclaw() {
  local exit_code="$1" output="$2" rollout_action="$3"
  cat > "$TEST_TMPDIR/bin/openclaw" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$@" > "$TEST_TMPDIR/openclaw.args"
STUB
  case "$rollout_action" in
    append) printf 'echo %q >> %q\n' "$LEGACY_HIT" "$TEST_TMPDIR/rollouts/rollout-during.jsonl" >> "$TEST_TMPDIR/bin/openclaw" ;;
    append-extension) printf 'echo %q >> %q\n' "$EXTENSION_HIT" "$TEST_TMPDIR/rollouts/rollout-during.jsonl" >> "$TEST_TMPDIR/bin/openclaw" ;;
    append-prose) printf 'echo %q >> %q\n' "$PROSE_LINE" "$TEST_TMPDIR/rollouts/rollout-during.jsonl" >> "$TEST_TMPDIR/bin/openclaw" ;;
  esac
  cat >> "$TEST_TMPDIR/bin/openclaw" <<STUB
printf '%s\n' "$output"
exit $exit_code
STUB
  chmod +x "$TEST_TMPDIR/bin/openclaw"
  PATH="$TEST_TMPDIR/bin:$PATH"
  export PATH
}

@test "websearch_probe_attempt: real result — rollout gains a legacy web_search_end event -> pass" {
  _stub_openclaw 0 "SEARCH_STATUS: ok" append
  run websearch_probe_attempt main "probe prompt"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx 'VERDICT=pass'
  echo "$output" | grep -q '^DETAIL=.*rollout'
}

@test "websearch_probe_attempt: real result on codex 0.151.0 — rollout gains an item_completed Extension web.search item -> pass" {
  _stub_openclaw 0 "SEARCH_STATUS: ok" append-extension
  run websearch_probe_attempt main "probe prompt"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx 'VERDICT=pass'
}

@test "websearch_probe_attempt: prose that merely mentions web_search_end is NOT evidence -> inconclusive" {
  _stub_openclaw 0 "SEARCH_STATUS: ok" append-prose
  run websearch_probe_attempt main "probe prompt"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx 'VERDICT=inconclusive'
}

@test "websearch_probe_attempt: contaminated echo — backend parrots the break text but the rollout carries a real search -> pass" {
  _stub_openclaw 0 "SEARCH_STATUS: error: web_search is disabled or no provider is available." append-extension
  run websearch_probe_attempt main "probe prompt"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx 'VERDICT=pass'
}

@test "websearch_probe_attempt: runs the given agent in a FRESH --session-id, never its persistent main session" {
  _stub_openclaw 0 "SEARCH_STATUS: ok" none
  run websearch_probe_attempt main "probe prompt" qa
  [ "$status" -eq 0 ]
  grep -qx -- '--session-id' "$TEST_TMPDIR/openclaw.args"
  grep -q '^websearch-probe-[0-9]' "$TEST_TMPDIR/openclaw.args"
  grep -qx -- '--agent' "$TEST_TMPDIR/openclaw.args"
  grep -qx -- 'qa' "$TEST_TMPDIR/openclaw.args"
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

@test "_websearch_probe_verdict: real_call_ran=1 outranks a break signature in the text (the text can be a contaminated echo)" {
  run _websearch_probe_verdict "SEARCH_STATUS: error: web_search is disabled or no provider is available." 1
  [ "$status" -eq 0 ]
  [ "$output" = "pass" ]
}

@test "_websearch_probe_verdict: break signature with real_call_ran=0 -> fail" {
  run _websearch_probe_verdict "Reconnecting... 2/5" 0
  [ "$status" -eq 0 ]
  [ "$output" = "fail" ]
  run _websearch_probe_verdict "web_search is disabled or no provider is available." 0
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

@test "_websearch_rollout_hits: counts BOTH persisted shapes by JSON structure, never by substring" {
  f="$TEST_TMPDIR/rollouts/rollout-shapes.jsonl"
  printf '%s\n' "$LEGACY_HIT" "$EXTENSION_HIT" "$PROSE_LINE" > "$f"
  # a top-level {"type":"web_search_end"} is NOT a rollout event shape codex writes
  echo '{"type":"web_search_end"}' >> "$f"
  # an Extension item of another kind is not a search
  echo '{"type":"event_msg","payload":{"type":"item_completed","item":{"type":"Extension","kind":"image.generate"}}}' >> "$f"
  # a malformed line must not abort the count
  echo 'not json {' >> "$f"
  run _websearch_rollout_hits "$f"
  [ "$status" -eq 0 ]
  [ "$output" = "2" ]
}

@test "_websearch_rollout_hits: fails LOUD (nonzero + stderr) when jq is unavailable instead of reading 0" {
  mkdir -p "$TEST_TMPDIR/minbin"
  for t in wc cat; do ln -s "$(command -v $t)" "$TEST_TMPDIR/minbin/$t"; done
  printf '%s\n' "$EXTENSION_HIT" > "$TEST_TMPDIR/rollouts/rollout-x.jsonl"
  run env PATH="$TEST_TMPDIR/minbin" "$BASH" -c "source '$LIB'; _websearch_rollout_hits '$TEST_TMPDIR/rollouts/rollout-x.jsonl'"
  [ "$status" -ne 0 ]
  echo "$output" | grep -qi 'jq'
}

# _stub_no_jq_env — a PATH with everything the probe needs EXCEPT jq, plus a
# PATH-stubbed openclaw that replies ok and writes a real 0.151.0 search
# event (so the ONLY reason not to pass is the missing counter).
_stub_no_jq_env() {
  mkdir -p "$TEST_TMPDIR/nojq"
  for t in wc cat ls head grep sed tr date timeout; do ln -sf "$(command -v $t)" "$TEST_TMPDIR/nojq/$t"; done
  printf '#!/bin/sh\necho %s >> %s\necho "SEARCH_STATUS: ok"\n' "'$EXTENSION_HIT'" "'$TEST_TMPDIR/rollouts/rollout-during.jsonl'" > "$TEST_TMPDIR/nojq/openclaw"
  chmod +x "$TEST_TMPDIR/nojq/openclaw"
}

@test "websearch_probe_attempt: jq missing on the host is a BLOCKING fail at the dispatcher boundary, never inconclusive (QA #937)" {
  # The counter's nonzero return was discarded by the command substitutions in
  # websearch_probe_attempt, so Step 7 retried, warned, and let the deploy
  # proceed while nothing could be measured. The boundary contract is the
  # VERDICT line: it must read fail, and name the cause.
  _stub_no_jq_env
  printf '%s\n' "$LEGACY_HIT" > "$TEST_TMPDIR/rollouts/rollout-baseline.jsonl"
  run env PATH="$TEST_TMPDIR/nojq" WEBSEARCH_PROBE_ROLLOUT_GLOB="$WEBSEARCH_PROBE_ROLLOUT_GLOB" "$BASH" -c "source '$LIB'; websearch_probe_attempt main 'probe prompt' scout"
  echo "$output" | grep -qx 'VERDICT=fail'
  echo "$output" | grep -qi '^DETAIL=.*jq'
}

@test "websearch_probe_attempt: jq missing with NO prior rollout is still a blocking fail (guard runs before the empty-path shortcut)" {
  _stub_no_jq_env
  rm -f "$TEST_TMPDIR"/rollouts/*.jsonl
  run env PATH="$TEST_TMPDIR/nojq" WEBSEARCH_PROBE_ROLLOUT_GLOB="$WEBSEARCH_PROBE_ROLLOUT_GLOB" "$BASH" -c "source '$LIB'; websearch_probe_attempt main 'probe prompt' scout"
  echo "$output" | grep -qx 'VERDICT=fail'
  echo "$output" | grep -qi '^DETAIL=.*jq'
}

@test "smoke-shaped call: result=\$(websearch_probe_attempt) under set -euo pipefail carries VERDICT=fail when jq is missing" {
  # Exactly how scripts/smoke-test.sh consumes the probe: a plain assignment
  # under errexit, then sed on the VERDICT line. The verdict must survive that
  # boundary as a blocking value the dispatcher turns into fail_check.
  _stub_no_jq_env
  printf '%s\n' "$LEGACY_HIT" > "$TEST_TMPDIR/rollouts/rollout-baseline.jsonl"
  run env PATH="$TEST_TMPDIR/nojq" WEBSEARCH_PROBE_ROLLOUT_GLOB="$WEBSEARCH_PROBE_ROLLOUT_GLOB" "$BASH" -c "set -euo pipefail; source '$LIB'; result=\"\$(websearch_probe_attempt main 'probe prompt' scout)\"; printf '%s\n' \"\$result\" | sed -n 's/^VERDICT=//p'"
  [ "$status" -eq 0 ]
  [ "$output" = "fail" ]
}

@test "websearch_probe_attempt: jq missing fails closed BEFORE spending an agent turn (openclaw is never invoked)" {
  # Isolates the baseline guard from the after-count guard: with only the
  # latter, the probe would still run the turn and only then fail.
  _stub_no_jq_env
  printf '%s\n' "$LEGACY_HIT" > "$TEST_TMPDIR/rollouts/rollout-baseline.jsonl"
  run env PATH="$TEST_TMPDIR/nojq" WEBSEARCH_PROBE_ROLLOUT_GLOB="$WEBSEARCH_PROBE_ROLLOUT_GLOB" "$BASH" -c "source '$LIB'; websearch_probe_attempt main 'probe prompt' scout"
  echo "$output" | grep -qx 'VERDICT=fail'
  [ ! -e "$TEST_TMPDIR/rollouts/rollout-during.jsonl" ]
}

@test "_websearch_rollout_hits: jq missing with an EMPTY path is nonzero (guard precedes the empty-path shortcut)" {
  mkdir -p "$TEST_TMPDIR/minbin"
  for t in wc cat; do ln -sf "$(command -v $t)" "$TEST_TMPDIR/minbin/$t"; done
  run env PATH="$TEST_TMPDIR/minbin" "$BASH" -c "source '$LIB'; _websearch_rollout_hits ''"
  [ "$status" -ne 0 ]
  [ "$output" != "0" ]
}

@test "websearch_probe_attempt: a counter that breaks MID-probe (baseline ok, after-count fails) is a blocking fail, not a 0-hit inconclusive" {
  # Isolates the after-count guard: jq works on the baseline file but errors on
  # the rollout written during the turn (the jq-fail-open class — any counter
  # error must surface as a blocking verdict, never be read as "0 real calls").
  mkdir -p "$TEST_TMPDIR/jqbin"
  cat > "$TEST_TMPDIR/jqbin/jq" <<JQ
#!/usr/bin/env bash
for a in "\$@"; do case "\$a" in *rollout-during*) echo "jq: error: simulated parse failure" >&2; exit 5;; esac; done
exec "$(command -v jq)" "\$@"
JQ
  chmod +x "$TEST_TMPDIR/jqbin/jq"
  _stub_openclaw 0 "SEARCH_STATUS: ok" append-extension
  printf '%s\n' "$LEGACY_HIT" > "$TEST_TMPDIR/rollouts/rollout-baseline.jsonl"
  export PATH="$TEST_TMPDIR/jqbin:$PATH"
  run websearch_probe_attempt main "probe prompt" scout
  echo "$output" | grep -qx 'VERDICT=fail'
  echo "$output" | grep -q '^DETAIL=.*simulated parse failure'
}

@test "_websearch_real_call_ran: a counter failure propagates as nonzero instead of echoing 0" {
  _stub_no_jq_env
  printf '%s\n' "$EXTENSION_HIT" > "$TEST_TMPDIR/rollouts/rollout-fresh.jsonl"
  run env PATH="$TEST_TMPDIR/nojq" WEBSEARCH_PROBE_ROLLOUT_GLOB="$WEBSEARCH_PROBE_ROLLOUT_GLOB" "$BASH" -c "source '$LIB'; _websearch_real_call_ran main scout '' 0"
  [ "$status" -ne 0 ]
  [ "$output" != "0" ]
  [ "$output" != "1" ]
}

@test "_websearch_real_call_ran: brand-new rollout file with a hit counts as a real call" {
  run _websearch_real_call_ran main scout "" 0
  [ "$status" -eq 0 ]
  [ "$output" = "0" ]
  printf '%s\n' "$EXTENSION_HIT" > "$TEST_TMPDIR/rollouts/rollout-fresh.jsonl"
  run _websearch_real_call_ran main scout "" 0
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
}

# ──────────────────────────────────────────────────────────────
# Deny-aware scoping (item i, 2026-09-11). The GLOBAL verdict comes from a
# deny-free reference agent and stays a hard FAIL; a scout-ONLY failure
# degrades to WARN naming the policy. The rollout-event standard is unchanged:
# a pass still requires a real search event in the rollout, never reply text.
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
