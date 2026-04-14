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
