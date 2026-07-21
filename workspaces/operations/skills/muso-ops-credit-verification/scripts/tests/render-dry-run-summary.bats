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

@test "real apply reports transport failures separately from refusals" {
  local fixture_transport="$TEST_TMPDIR/fixture.transport.json"
  jq '.apply.approve += {transport_failed: 1}
      | .apply.uvn += {transport_failed: 2}' "$FIXTURE" > "$fixture_transport"
  run --separate-stderr env -u THREAD_TS POST_PARENT_TO_CHANNEL=0 bash -c "'$RENDER' < '$fixture_transport'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"approved.landed=169 (refused=0, transport_failed=1)"* ]]
  [[ "$output" == *"uvn.landed=331 (refused=0, transport_failed=2)"* ]]
  [[ "$output" == *"3 credit write(s) have unconfirmed delivery after the safe retry policy"* ]]
  [[ "$output" == *"Reconcile current credit state before retrying"* ]]
  [[ "$output" != *"did not land"* ]]
}

@test "fraud-unavailable warning points at scorer stderr, not a dead runlog" {
  local fixture_fraud="$TEST_TMPDIR/fixture.fraud.json"
  jq '.would_uvn = [{"cr_id":"cr-U","_fraud":{"muso_only_available":false}}]' "$FIXTURE" > "$fixture_fraud"
  run --separate-stderr env -u THREAD_TS POST_PARENT_TO_CHANNEL=0 bash -c "'$RENDER' < '$fixture_fraud'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"muso-only Trino signal was UNAVAILABLE"* ]]
  # "see runlog" pointed at a file the lobster path never writes.
  [[ "$output" != *"see runlog"* ]]
  # No muso_only_reason on this fixture (pre-fraud-issue-scorer-followups.md
  # §1 shape) → the defensive "scorer stderr" fallback still applies.
  [[ "$output" == *"scorer stderr"* ]]
}

@test "fraud-unavailable warning surfaces the carried muso_only_reason instead of pointing at stderr" {
  local fixture_fraud="$TEST_TMPDIR/fixture.fraud-reason.json"
  jq '.would_uvn = [{"cr_id":"cr-U","_fraud":{"muso_only_available":false,"muso_only_reason":"trino-query.sh exited rc=1; trino stderr: trino exploded"}}]' "$FIXTURE" > "$fixture_fraud"
  run --separate-stderr env -u THREAD_TS POST_PARENT_TO_CHANNEL=0 bash -c "'$RENDER' < '$fixture_fraud'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"muso-only Trino signal was UNAVAILABLE"* ]]
  [[ "$output" == *"Reason: trino-query.sh exited rc=1; trino stderr: trino exploded"* ]]
  # The reason reached the summary — no need to point the operator at a
  # transcript they may not have.
  [[ "$output" != *"scorer stderr"* ]]
}

# ── no-op compaction (2026-07-22: 30× "Sampled: 0 of 500" full-block spam) ──
# When a run samples nothing and lands/refuses nothing, the full :rocket:
# block (bucket counts, policy line, audit-tail) is pure noise. Render a
# compact one-liner instead. The full block must still render whenever
# anything was sampled, landed, refused, or fraud-flagged — a compacted
# summary that hides real writes would be a truth-floor regression.

noop_fixture() {
  # apply ran (real mode) but the selector matched nothing.
  cat > "$1" <<'EOF'
{
  "queue_depth": 0,
  "fetch_size": 500,
  "counts": { "total": 0, "would_approve": 0, "would_uvn": 0 },
  "apply": {
    "dry_run": false,
    "approve": { "landed": 0, "refused": 0 },
    "uvn":     { "landed": 0, "refused": 0 }
  },
  "would_approve": [],
  "would_uvn": []
}
EOF
}

@test "no-op real run renders compact one-liner, not the full block" {
  local f="$TEST_TMPDIR/fixture.noop.json"
  noop_fixture "$f"
  run --separate-stderr env -u THREAD_TS POST_PARENT_TO_CHANNEL=0 OPS_RUN_ID=lobster-noop-1 bash -c "'$RENDER' < '$f'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"no-op"* ]]
  [[ "$output" == *"0 unverified credits matched"* ]]
  [[ "$output" == *"run_id: lobster-noop-1"* ]]
  # Full-block furniture must be gone.
  [[ "$output" != *":rocket:"* ]]
  [[ "$output" != *"Bucket counts"* ]]
  [[ "$output" != *"Backend-signal policy"* ]]
  [[ "$output" != *"Apply outcomes"* ]]
}

@test "no-op dry run renders compact one-liner with dry marker" {
  local f="$TEST_TMPDIR/fixture.noop.dry.json"
  noop_fixture "$f"
  jq '.apply = {dry_run: true}' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
  run --separate-stderr env -u THREAD_TS POST_PARENT_TO_CHANNEL=0 bash -c "'$RENDER' < '$f'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"no-op"* ]]
  [[ "$output" == *"DRY-RUN"* ]]
  [[ "$output" != *":rocket:"* ]]
  [[ "$output" != *"Bucket counts"* ]]
}

@test "no-op compact line still carries selector.note and still posts in thread mode" {
  local f="$TEST_TMPDIR/fixture.noop.note.json"
  noop_fixture "$f"
  jq '. + {selector: {note: "status_is_approved_not_unverified"}}' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
  run --separate-stderr env THREAD_TS='1777890000.222222' TARGET_CHANNEL=C_TEST bash -c "'$RENDER' < '$f'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"status_is_approved_not_unverified"* ]]
  # Posting behavior unchanged: thread mode still posts (a human asked).
  [ "$(calls)" -eq 1 ]
  LC_ALL=C grep -q -- '--reply-to' "$OPENCLAW_CALLS_FILE"
}

@test "refused-only run (0 landed, >0 refused) still renders the FULL block" {
  local f="$TEST_TMPDIR/fixture.refused.json"
  noop_fixture "$f"
  jq '.counts.total = 3 | .counts.would_approve = 3 | .apply.approve.refused = 3' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
  run --separate-stderr env -u THREAD_TS POST_PARENT_TO_CHANNEL=0 bash -c "'$RENDER' < '$f'"
  [ "$status" -eq 0 ]
  [[ "$output" == *":rocket:"* ]]
  [[ "$output" == *"Apply outcomes"* ]]
  [[ "$output" != *"no-op —"* ]]
}
