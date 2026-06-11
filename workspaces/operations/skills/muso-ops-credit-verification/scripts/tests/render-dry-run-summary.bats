#!/usr/bin/env bats
bats_require_minimum_version 1.5.0
load helpers

# Covers render-dry-run-summary.sh (the Lobster pipeline's final step).
# Three post modes:
#   - THREAD_TS set                              → thread reply via --reply-to
#   - THREAD_TS empty + POST_PARENT_TO_CHANNEL=1 → top-level parent in TARGET_CHANNEL (cron path, hydra#305)
#   - THREAD_TS empty + POST_PARENT_TO_CHANNEL=0 → stdout only (bats / direct-CLI mode)

RENDER="$SCRIPTS_DIR/lobster-mvp/render-dry-run-summary.sh"

setup() {
  setup_tmp_env
  # helpers.bash exports PATH so openclaw is a stub that appends each
  # invocation's argv to $TEST_TMPDIR/openclaw.calls.
  export OPENCLAW_CALLS_FILE="$TEST_TMPDIR/openclaw.calls"
  export FIXTURE="$TEST_TMPDIR/fixture.json"
  # Realistic apply-verdicts.sh output for a real-apply run that landed
  # everything (refused counts zero). Three would_approve entries for the
  # "first 10" cr_id list rendering.
  cat > "$FIXTURE" <<'EOF'
{
  "queue_depth": 13864,
  "fetch_size": 500,
  "counts": { "total": 500, "would_approve": 169, "would_uvn": 331 },
  "apply": {
    "dry_run": false,
    "approve": { "landed": 169, "refused": 0 },
    "uvn":     { "landed": 331, "refused": 0 }
  },
  "would_approve": [
    {"cr_id": "cr-A"}, {"cr_id": "cr-B"}, {"cr_id": "cr-C"}
  ],
  "would_uvn": []
}
EOF
  export FIXTURE_DRY="$TEST_TMPDIR/fixture.dry.json"
  cat > "$FIXTURE_DRY" <<'EOF'
{
  "queue_depth": 100,
  "fetch_size": 50,
  "counts": { "total": 50, "would_approve": 10, "would_uvn": 40 },
  "apply": { "dry_run": true },
  "would_approve": [{"cr_id": "cr-X"}],
  "would_uvn": []
}
EOF
}
teardown() { teardown_tmp_env; }

calls() { grep -c '^CALL ' "$OPENCLAW_CALLS_FILE" 2>/dev/null || echo 0; }

@test "stdout-only when THREAD_TS empty and POST_PARENT_TO_CHANNEL=0" {
  run --separate-stderr env -u THREAD_TS POST_PARENT_TO_CHANNEL=0 bash -c "'$RENDER' < '$FIXTURE'"
  [ "$status" -eq 0 ]
  [[ "$output" == *":rocket:"* ]]
  [[ "$output" == *"Sampled: 500 of 500"* ]]
  [[ "$output" == *"approved : 169"* ]]
  [[ "$output" == *"user_verification_needed : 331"* ]]
  [ "$(calls)" -eq 0 ]
}

@test "thread reply when THREAD_TS set (POST_PARENT_TO_CHANNEL ignored)" {
  run --separate-stderr env THREAD_TS='1777890000.111111' POST_PARENT_TO_CHANNEL=1 TARGET_CHANNEL=C_TEST bash -c "'$RENDER' < '$FIXTURE'"
  [ "$status" -eq 0 ]
  [ "$(calls)" -eq 1 ]
  LC_ALL=C grep -q -- '--reply-to' "$OPENCLAW_CALLS_FILE"
  LC_ALL=C grep -q '1777890000.111111' "$OPENCLAW_CALLS_FILE"
  LC_ALL=C grep -q 'C_TEST' "$OPENCLAW_CALLS_FILE"
}

@test "top-level parent post when THREAD_TS empty + POST_PARENT_TO_CHANNEL=1 (cron path)" {
  run --separate-stderr env -u THREAD_TS POST_PARENT_TO_CHANNEL=1 TARGET_CHANNEL=C_TEST bash -c "'$RENDER' < '$FIXTURE'"
  [ "$status" -eq 0 ]
  [ "$(calls)" -eq 1 ]
  # Same rich summary on stdout (check BEFORE any other `run`, which clobbers $output).
  [[ "$output" == *":rocket:"* ]]
  [[ "$output" == *"approved : 169"* ]]
  [[ "$output" == *"approved cr_ids (first 10):"* ]]
  [[ "$output" == *"cr-A"* ]]
  # Parent post: target channel present, NO --reply-to flag.
  LC_ALL=C grep -q 'C_TEST' "$OPENCLAW_CALLS_FILE"
  run grep -q -- '--reply-to' "$OPENCLAW_CALLS_FILE"
  [ "$status" -ne 0 ]
}

@test "parent post still works with dry-run apply (label differs, behavior same)" {
  run --separate-stderr env -u THREAD_TS POST_PARENT_TO_CHANNEL=1 TARGET_CHANNEL=C_TEST bash -c "'$RENDER' < '$FIXTURE_DRY'"
  [ "$status" -eq 0 ]
  [ "$(calls)" -eq 1 ]
  # Content asserts before subsequent `run` (which clobbers $output).
  [[ "$output" == *":test_tube:"* ]]
  [[ "$output" == *"would_approve : 10"* ]]
  run grep -q -- '--reply-to' "$OPENCLAW_CALLS_FILE"
  [ "$status" -ne 0 ]
}

@test "selector.note renders in parent-post body" {
  local fixture_note="$TEST_TMPDIR/fixture.note.json"
  jq '. + {selector: {note: "status_is_approved_not_unverified"}}' "$FIXTURE" > "$fixture_note"
  run --separate-stderr env -u THREAD_TS POST_PARENT_TO_CHANNEL=1 TARGET_CHANNEL=C_TEST bash -c "'$RENDER' < '$fixture_note'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"status_is_approved_not_unverified"* ]]
  [ "$(calls)" -eq 1 ]
}

@test "OPENCLAW_CLI=1 marker (openclaw runtime) does not poison OPENCLAW_BIN — regression for PR #306 review" {
  # openclaw runtime sets OPENCLAW_CLI=1 process-wide on the gateway
  # (openclaw-exec-env.js + entry.js:117 ensureOpenClawExecMarkerOnProcess).
  # In Lobster step subprocesses the marker doesn't currently propagate
  # (env-probe verified 2026-05-21), but in any context where it does
  # leak (e.g., direct agent exec) the old `OPENCLAW_BIN="${OPENCLAW_CLI:-openclaw}"`
  # resolved to literal "1" and silently no-op'd the Slack post.
  # This test simulates the leak and asserts the new fallback chain
  # (OPENCLAW_BIN > OPENCLAW_CLI_PATH > "openclaw") still finds the stub.
  run --separate-stderr env -u THREAD_TS POST_PARENT_TO_CHANNEL=1 TARGET_CHANNEL=C_TEST OPENCLAW_CLI=1 bash -c "'$RENDER' < '$FIXTURE'"
  [ "$status" -eq 0 ]
  [ "$(calls)" -eq 1 ]
  # No "binary not found" WARN on stderr.
  run grep -q 'openclaw binary not found' <<<"$stderr"
  [ "$status" -ne 0 ]
}

@test "POST_PARENT_TO_CHANNEL=1 with empty THREAD_TS still skips post if openclaw missing" {
  # Wipe PATH so the stub openclaw is no longer found; should warn-and-skip,
  # not fail. (Mirrors the existing safety branch in the script.)
  run --separate-stderr env -u THREAD_TS POST_PARENT_TO_CHANNEL=1 TARGET_CHANNEL=C_TEST PATH=/usr/bin:/bin bash -c "'$RENDER' < '$FIXTURE'"
  [ "$status" -eq 0 ]
  # Body still on stdout.
  [[ "$output" == *":rocket:"* ]]
}

# ── run-id propagation (2026-06-11: stale-OPS_RUN_ID / dead-runlog-pointer fix) ──
# The lobster pipeline threads OPS_RUN_ID (minted by dispatch-cv-batch.sh)
# into every step. The summary must surface it and point at the PER-RUN truth
# floor (.results.jsonl), which muso-admin-api.sh names with the same id —
# before this fix it fell back to the stale runlog latest.txt from 2026-05-16.

@test "OPS_RUN_ID renders in header and real-apply tail names the per-run results file" {
  run --separate-stderr env -u THREAD_TS POST_PARENT_TO_CHANNEL=0 OPS_RUN_ID=lobster-test-123 bash -c "'$RENDER' < '$FIXTURE'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"run_id: lobster-test-123"* ]]
  # Same UTC-date derivation as muso-admin-api.sh write_credit_request_result.
  [[ "$output" == *"/var/log/openclaw/credit-batch-runs/$(date -u +%Y-%m-%d)/lobster-test-123.results.jsonl"* ]]
}

@test "no OPS_RUN_ID → no run_id token; tail keeps the shared audit-log pointer" {
  run --separate-stderr env -u THREAD_TS -u OPS_RUN_ID POST_PARENT_TO_CHANNEL=0 bash -c "'$RENDER' < '$FIXTURE'"
  [ "$status" -eq 0 ]
  [[ "$output" != *"run_id:"* ]]
  [[ "$output" == *"/var/log/openclaw/lobster-apply.jsonl"* ]]
}

@test "fraud-unavailable warning points at scorer stderr, not a dead runlog" {
  local fixture_fraud="$TEST_TMPDIR/fixture.fraud.json"
  jq '.would_uvn = [{"cr_id":"cr-U","_fraud":{"muso_only_available":false}}]' "$FIXTURE" > "$fixture_fraud"
  run --separate-stderr env -u THREAD_TS POST_PARENT_TO_CHANNEL=0 bash -c "'$RENDER' < '$fixture_fraud'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"muso-only Trino signal was UNAVAILABLE"* ]]
  # "see runlog" pointed at a file the lobster path never writes.
  [[ "$output" != *"see runlog"* ]]
  [[ "$output" == *"scorer stderr"* ]]
}
