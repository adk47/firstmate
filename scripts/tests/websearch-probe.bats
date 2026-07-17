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
