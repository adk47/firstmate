#!/usr/bin/env bats
load helpers

setup() {
  setup_tmp_env
  export OPS_RUNLOG_DIR="$TEST_TMPDIR/credit-batch-runs"
  mkdir -p "$OPS_RUNLOG_DIR"
}
teardown() { teardown_tmp_env; }

@test "init creates run_id and writes latest.txt pointer" {
  RUN_ID=$("$SCRIPTS_DIR/runlog.sh" init)
  [[ "$RUN_ID" =~ ^[0-9]{8}-[0-9]{6}-[a-f0-9]{6}$ ]]
  TODAY=$(date -u +%Y-%m-%d)
  LOG_FILE="$OPS_RUNLOG_DIR/$TODAY/$RUN_ID.jsonl"
  [ -f "$LOG_FILE" ]
  [ "$(cat $OPS_RUNLOG_DIR/latest.txt)" = "$LOG_FILE" ]
}

@test "event appends a JSON line with ts and run_id" {
  RUN_ID=$("$SCRIPTS_DIR/runlog.sh" init)
  "$SCRIPTS_DIR/runlog.sh" event "$RUN_ID" run_started \
    '{"phase":"0","fetch_size":10,"approval_cap_limit":500}'
  TODAY=$(date -u +%Y-%m-%d)
  LOG_FILE="$OPS_RUNLOG_DIR/$TODAY/$RUN_ID.jsonl"
  # Line has event, run_id, ts, and fields
  jq -e '.event == "run_started" and .run_id != null and .ts != null and .phase == "0" and .fetch_size == 10' \
    < "$LOG_FILE"
}

@test "event preserves multiple appends in order" {
  RUN_ID=$("$SCRIPTS_DIR/runlog.sh" init)
  "$SCRIPTS_DIR/runlog.sh" event "$RUN_ID" credit_fetched '{"cr_id":"cr_1"}'
  "$SCRIPTS_DIR/runlog.sh" event "$RUN_ID" credit_fetched '{"cr_id":"cr_2"}'
  "$SCRIPTS_DIR/runlog.sh" event "$RUN_ID" credit_fetched '{"cr_id":"cr_3"}'
  TODAY=$(date -u +%Y-%m-%d)
  LOG_FILE="$OPS_RUNLOG_DIR/$TODAY/$RUN_ID.jsonl"
  # `wc -l` output differs on BSD (padded) vs GNU (unpadded); normalize with awk.
  [ "$(awk 'END{print NR}' "$LOG_FILE")" = "3" ]
  [ "$(jq -r '.cr_id' < $LOG_FILE | head -1)" = "cr_1" ]
  [ "$(jq -r '.cr_id' < $LOG_FILE | tail -1)" = "cr_3" ]
}

@test "fails with exit 2 when OPS_RUNLOG_DIR unset" {
  unset OPS_RUNLOG_DIR
  run "$SCRIPTS_DIR/runlog.sh" init
  [ "$status" -eq 2 ]
}

@test "event rejects invalid JSON payload (exit 3)" {
  RUN_ID=$("$SCRIPTS_DIR/runlog.sh" init)
  run "$SCRIPTS_DIR/runlog.sh" event "$RUN_ID" test_event 'not json {'
  [ "$status" -eq 3 ]
}

@test "init returns distinct run_ids when called rapidly in same second" {
  # Two `init` calls in the same UTC second must not collide on the run_id.
  # Run IDs share the YYYYMMDD-HHMMSS prefix; the 6-hex suffix disambiguates.
  # If a future change drops the suffix (or shrinks it too small), this catches it.
  RUN_A=$("$SCRIPTS_DIR/runlog.sh" init)
  RUN_B=$("$SCRIPTS_DIR/runlog.sh" init)
  RUN_C=$("$SCRIPTS_DIR/runlog.sh" init)
  [ "$RUN_A" != "$RUN_B" ]
  [ "$RUN_B" != "$RUN_C" ]
  [ "$RUN_A" != "$RUN_C" ]
}

# ---- preflight_browser_unavailable gate ----
# Once preflight fails, SKILL.md B0d requires the turn to exit. The 2026-04-20
# 13:19 UTC manual run (2bfea8) bypassed this by logging
# preflight_browser_unavailable and then writing run_started phase="manual"
# to continue. This gate makes that mechanically impossible.

@test "event after preflight_browser_unavailable is refused (exit 20)" {
  RUN_ID=$("$SCRIPTS_DIR/runlog.sh" init)
  "$SCRIPTS_DIR/runlog.sh" event "$RUN_ID" preflight_browser_unavailable \
    '{"probe_url":"x","error":"timeout"}'
  run "$SCRIPTS_DIR/runlog.sh" event "$RUN_ID" run_started \
    '{"phase":"manual"}'
  [ "$status" -eq 20 ]
  # Error message identifies the gate so future readers can find it.
  [[ "$output" == *"preflight_browser_unavailable"* ]]
}

@test "gate blocks ANY subsequent event, not just run_started" {
  RUN_ID=$("$SCRIPTS_DIR/runlog.sh" init)
  "$SCRIPTS_DIR/runlog.sh" event "$RUN_ID" preflight_browser_unavailable \
    '{"probe_url":"x","error":"timeout"}'
  for ev in credit_fetched verdict action_attempted action_result escalation_posted run_finished; do
    run "$SCRIPTS_DIR/runlog.sh" event "$RUN_ID" "$ev" '{"cr_id":"x"}'
    [ "$status" -eq 20 ]
  done
}

@test "gate does not affect OTHER runs" {
  # Only the run with preflight_browser_unavailable is frozen; a different
  # run (different RUN_ID, different file) is unaffected.
  RUN_A=$("$SCRIPTS_DIR/runlog.sh" init)
  RUN_B=$("$SCRIPTS_DIR/runlog.sh" init)
  "$SCRIPTS_DIR/runlog.sh" event "$RUN_A" preflight_browser_unavailable \
    '{"probe_url":"x","error":"timeout"}'
  # RUN_B must still accept events.
  "$SCRIPTS_DIR/runlog.sh" event "$RUN_B" run_started '{"phase":"0"}'
  TODAY=$(date -u +%Y-%m-%d)
  LOG_B="$OPS_RUNLOG_DIR/$TODAY/$RUN_B.jsonl"
  jq -e 'select(.event=="run_started")' < "$LOG_B"
}

@test "writing preflight_browser_unavailable itself is allowed" {
  # The gate must not refuse the FIRST preflight_browser_unavailable —
  # otherwise preflight-verify.sh couldn't log the failure it detected.
  RUN_ID=$("$SCRIPTS_DIR/runlog.sh" init)
  "$SCRIPTS_DIR/runlog.sh" event "$RUN_ID" run_started '{"phase":"0"}'
  run "$SCRIPTS_DIR/runlog.sh" event "$RUN_ID" preflight_browser_unavailable \
    '{"probe_url":"x","error":"timeout"}'
  [ "$status" -eq 0 ]
}

@test "duplicate preflight_browser_unavailable is refused (already frozen)" {
  RUN_ID=$("$SCRIPTS_DIR/runlog.sh" init)
  "$SCRIPTS_DIR/runlog.sh" event "$RUN_ID" preflight_browser_unavailable \
    '{"probe_url":"x","error":"timeout"}'
  run "$SCRIPTS_DIR/runlog.sh" event "$RUN_ID" preflight_browser_unavailable \
    '{"probe_url":"x","error":"retry"}'
  [ "$status" -eq 20 ]
}

@test "events before preflight_browser_unavailable remain writable normally" {
  # Sanity: the gate is state-dependent, not blanket. run_started logged
  # BEFORE the failure must not poison unrelated events on other runs.
  RUN_ID=$("$SCRIPTS_DIR/runlog.sh" init)
  "$SCRIPTS_DIR/runlog.sh" event "$RUN_ID" run_started '{"phase":"0"}'
  "$SCRIPTS_DIR/runlog.sh" event "$RUN_ID" credit_fetched '{"cr_id":"cr_1"}'
  TODAY=$(date -u +%Y-%m-%d)
  LOG_FILE="$OPS_RUNLOG_DIR/$TODAY/$RUN_ID.jsonl"
  [ "$(awk 'END{print NR}' "$LOG_FILE")" = "2" ]
}
