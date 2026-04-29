#!/usr/bin/env bats
bats_require_minimum_version 1.5.0
load helpers

# post-batch-summary.sh — sanctioned wrapper for posting [HEARTBEAT-BATCH]
# parent + thread to #credit-verification. Refuses to post when the run
# is not yet finished or has the in-flight (B1-only) shape. Tests use
# --dry-run-cli to validate the gate logic + payload composition without
# invoking the openclaw message CLI.

setup() {
  setup_tmp_env
  export RUN_ID="20260420-120000-deadbe"
  day="${RUN_ID:0:8}"
  RUNLOG_DIR="$OPS_RUNLOG_DIR/${day:0:4}-${day:4:2}-${day:6:2}"
  mkdir -p "$RUNLOG_DIR"
  export RUNLOG_FILE="$RUNLOG_DIR/${RUN_ID}.jsonl"
  : > "$RUNLOG_FILE"

  # Results path — render-slack-summary needs it; default points at /var
  # which the test env can't write to.
  export CV_RESULTS_PATH="$RUNLOG_DIR/${RUN_ID}.results.jsonl"
  : > "$CV_RESULTS_PATH"

  # Channel envs — set both so we can flip via dryRun in the runlog.
  export OPS_CREDIT_VERIFICATION_CHANNEL_ID="C_TESTPROD"
  export OPS_CREDIT_VERIFICATION_DRY_RUN_CHANNEL_ID="C_TESTDRY"
  export OPS_OPENCLAW_PROFILE="test"
}
teardown() { teardown_tmp_env; }

# Seed a complete runlog: run_started_queue + run_finished + N action_attempted.
# Args: queue_depth attempts dryRun(true|false)
seed_finished_runlog() {
  local qdepth="$1" attempts="$2" dry="${3:-false}"
  local ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  jq -n -c --arg rid "$RUN_ID" --arg ts "$ts" --argjson dry "$dry" \
    '{event:"run_header", run_id:$rid, ts:$ts, dryRun:$dry}' >> "$RUNLOG_FILE"
  jq -n -c --arg rid "$RUN_ID" --arg ts "$ts" --argjson qd "$qdepth" \
    '{event:"run_started_queue", run_id:$rid, ts:$ts, queue_depth_at_start:$qd}' >> "$RUNLOG_FILE"
  local i=0
  while [[ "$i" -lt "$attempts" ]]; do
    jq -n -c --arg rid "$RUN_ID" --arg ts "$ts" --arg cr "cr_$i" \
      '{event:"action_attempted", run_id:$rid, ts:$ts, action:"approve", cr_id:$cr}' >> "$RUNLOG_FILE"
    i=$((i + 1))
  done
  jq -n -c --arg rid "$RUN_ID" --arg ts "$ts" --argjson dry "$dry" --argjson f 5 --argjson a 5 \
    '{event:"run_finished", run_id:$rid, ts:$ts, dryRun:$dry, fetched:$f, approved:$a, verification_needed:0, escalated:0, skipped_idempotent:0, skipped_cap:0, errors:0, hollow:false, ungrounded:false, silent_failure_detected:false, reconciliation:{source:"results_jsonl", approved_attempted:$a, approved_landed:$a, approved_rejected_by_gate:0, approved_rejected_pre_flight:0, approved_http_error:0, verification_needed_attempted:0, verification_needed_landed:0, verification_needed_http_error:0}}' >> "$RUNLOG_FILE"
}

@test "missing RUN_ID exits 2" {
  run "$SCRIPTS_DIR/post-batch-summary.sh"
  [ "$status" -eq 2 ]
}

@test "missing OPS_RUNLOG_DIR exits 2" {
  unset OPS_RUNLOG_DIR
  run "$SCRIPTS_DIR/post-batch-summary.sh" "$RUN_ID"
  [ "$status" -eq 2 ]
}

@test "missing runlog file exits 5" {
  rm -f "$RUNLOG_FILE"
  run "$SCRIPTS_DIR/post-batch-summary.sh" "$RUN_ID"
  [ "$status" -eq 5 ]
}

@test "refuses (exit 6) when runlog has no run_finished event" {
  jq -n -c --arg rid "$RUN_ID" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{event:"run_started_queue", run_id:$rid, ts:$ts, queue_depth_at_start:13864}' >> "$RUNLOG_FILE"
  run --separate-stderr "$SCRIPTS_DIR/post-batch-summary.sh" "$RUN_ID"
  [ "$status" -eq 6 ]
  [[ "$stderr" == *"no run_finished event"* ]]
  [[ "$stderr" == *"Run compute-run-summary.sh --final first"* ]]
}

@test "refuses (exit 7) on Failure 1 shape: queue_depth>0 but no action_attempted" {
  # The exact 2026-04-28 15:13/15:26 UTC dry-run failure: agent ran B1,
  # never did B2-B5, but somehow a run_finished landed (e.g. via stale
  # autofill). Block the Slack post anyway.
  local ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  jq -n -c --arg rid "$RUN_ID" --arg ts "$ts" \
    '{event:"run_started_queue", run_id:$rid, ts:$ts, queue_depth_at_start:13864}' >> "$RUNLOG_FILE"
  jq -n -c --arg rid "$RUN_ID" --arg ts "$ts" \
    '{event:"run_finished", run_id:$rid, ts:$ts, dryRun:true, fetched:0, approved:0, verification_needed:0, escalated:0, skipped_idempotent:0, skipped_cap:0, errors:0, hollow:true, ungrounded:false, silent_failure_detected:true, reconciliation:{source:"session_jsonl_fallback"}}' >> "$RUNLOG_FILE"
  run --separate-stderr "$SCRIPTS_DIR/post-batch-summary.sh" "$RUN_ID"
  [ "$status" -eq 7 ]
  [[ "$stderr" == *"queue_depth_at_start=13864"* ]]
  [[ "$stderr" == *"action_attempted=0"* ]]
  [[ "$stderr" == *"Failure 1 shape"* ]]
}

@test "happy path (--dry-run-cli): valid runlog with attempts → composes parent + thread, picks prod channel" {
  seed_finished_runlog 100 5 false
  run --separate-stderr "$SCRIPTS_DIR/post-batch-summary.sh" "$RUN_ID" --dry-run-cli
  [ "$status" -eq 0 ]
  [[ "$output" == *"POST_BATCH_SUMMARY_OK: target=C_TESTPROD"* ]]
  [[ "$output" == *"----- PARENT -----"* ]]
  [[ "$output" == *"----- THREAD -----"* ]]
  # Parent contains "[HEARTBEAT-BATCH]" header (from render-slack-summary.sh)
  [[ "$output" == *"[HEARTBEAT-BATCH]"* ]] || [[ "$output" == *"Credit batch complete"* ]]
}

@test "dry-run runlog routes to OPS_CREDIT_VERIFICATION_DRY_RUN_CHANNEL_ID" {
  seed_finished_runlog 100 5 true
  run "$SCRIPTS_DIR/post-batch-summary.sh" "$RUN_ID" --dry-run-cli
  [ "$status" -eq 0 ]
  [[ "$output" == *"target=C_TESTDRY"* ]]
  [[ "$output" == *"dryRun=true"* ]]
}

@test "dry-run runlog without OPS_CREDIT_VERIFICATION_DRY_RUN_CHANNEL_ID exits 2" {
  seed_finished_runlog 100 5 true
  unset OPS_CREDIT_VERIFICATION_DRY_RUN_CHANNEL_ID
  run --separate-stderr "$SCRIPTS_DIR/post-batch-summary.sh" "$RUN_ID" --dry-run-cli
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"OPS_CREDIT_VERIFICATION_DRY_RUN_CHANNEL_ID"* ]]
}

@test "empty queue (queue_depth==0, attempts==0) is allowed — legitimate queue-clear shape" {
  # When the queue is genuinely empty, action_attempted is 0 BUT
  # queue_depth_at_start is also 0 — the in-flight check skips and the
  # post proceeds to render the queue-clear summary.
  seed_finished_runlog 0 0 false
  run "$SCRIPTS_DIR/post-batch-summary.sh" "$RUN_ID" --dry-run-cli
  [ "$status" -eq 0 ]
  [[ "$output" == *"POST_BATCH_SUMMARY_OK"* ]]
}

@test "openclaw parent response without message id exits 10 and does not send thread reply" {
  seed_finished_runlog 100 5 false

  local bin_dir calls
  bin_dir="$TEST_TMPDIR/bin"
  calls="$TEST_TMPDIR/openclaw.calls"
  mkdir -p "$bin_dir"
  cat > "$bin_dir/openclaw" <<'EOF'
#!/usr/bin/env bash
printf 'CALL %q\n' "$*" >> "$OPENCLAW_CALLS"
printf '{"ok":true,"message":{"text":"posted but no ts"}}\n'
EOF
  chmod +x "$bin_dir/openclaw"
  export OPENCLAW_CALLS="$calls"
  export PATH="$bin_dir:$PATH"

  run --separate-stderr "$SCRIPTS_DIR/post-batch-summary.sh" "$RUN_ID"
  [ "$status" -eq 10 ]
  [[ "$stderr" == *"couldn't extract message id/ts"* ]]
  [ "$(grep -c '^CALL ' "$calls")" -eq 1 ]
  ! grep -q -- '--reply-to' "$calls"
}
