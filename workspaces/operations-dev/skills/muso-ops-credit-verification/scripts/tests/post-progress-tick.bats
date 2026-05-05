#!/usr/bin/env bats
bats_require_minimum_version 1.5.0
load helpers

setup() {
  setup_tmp_env
  export RUN_ID="20260504-130000-bbb222"
  day="${RUN_ID:0:8}"
  RUNLOG_DIR="$OPS_RUNLOG_DIR/${day:0:4}-${day:4:2}-${day:6:2}"
  mkdir -p "$RUNLOG_DIR"
  export RUNLOG_FILE="$RUNLOG_DIR/${RUN_ID}.jsonl"
  : > "$RUNLOG_FILE"
  jq -n -c --arg rid "$RUN_ID" '{event:"run_started", run_id:$rid, ts:"2026-05-04T13:00:00Z", phase:"0"}' >> "$RUNLOG_FILE"
  # Seed 3 fetched profiles
  for pid in pid-A pid-B pid-C; do
    jq -n -c --arg rid "$RUN_ID" --arg pid "$pid" --arg cr "cr-$pid" \
      '{event:"profile_group_fetched", run_id:$rid, ts:"2026-05-04T13:00:01Z", profile_id:$pid, count:1, cr_ids:[$cr]}' >> "$RUNLOG_FILE"
  done

  export OPS_PARENT_MSG_TS="1777890000.111111"
  export OPS_CREDIT_VERIFICATION_CHANNEL_ID="C_TESTPROD"
  export OPS_CREDIT_VERIFICATION_DRY_RUN_CHANNEL_ID="C_TESTDRY"
  export OPS_OPENCLAW_PROFILE="test"
  # Disable throttle by default for deterministic tests; specific test
  # exercises throttle by setting low value.
  export CV_PROGRESS_TICK_THROTTLE_SECONDS=0
}
teardown() { teardown_tmp_env; }

# Helper: write a verdict event so a profile becomes "decisioned"
seed_decision() {
  local pid="$1"
  jq -n -c --arg rid "$RUN_ID" --arg pid "$pid" --arg cr "cr-$pid" \
    '{event:"verdict", run_id:$rid, ts:"2026-05-04T13:00:10Z", profile_id:$pid, cr_id:$cr, reason:"approve: spotify confirmed"}' >> "$RUNLOG_FILE"
}

@test "missing args / env exit 2" {
  run "$SCRIPTS_DIR/post-progress-tick.sh"; [ "$status" -eq 2 ]
  run "$SCRIPTS_DIR/post-progress-tick.sh" "$RUN_ID"; [ "$status" -eq 2 ]
  unset OPS_PARENT_MSG_TS
  run "$SCRIPTS_DIR/post-progress-tick.sh" "$RUN_ID" pid-A; [ "$status" -eq 2 ]
}

@test "missing runlog exits 5" {
  rm -f "$RUNLOG_FILE"
  run "$SCRIPTS_DIR/post-progress-tick.sh" "$RUN_ID" pid-A; [ "$status" -eq 5 ]
}

@test "refuses tick for profile with no decision events yet (exit 2)" {
  # No seed_decision calls — pid-A is fetched but not decisioned
  run "$SCRIPTS_DIR/post-progress-tick.sh" --dry-run-cli "$RUN_ID" pid-A
  [ "$status" -eq 2 ]
  [[ "$output" == *"no decision events yet"* ]]
}

@test "--dry-run-cli posts tick with cumulative counts and writes progress event" {
  seed_decision pid-A
  run "$SCRIPTS_DIR/post-progress-tick.sh" --dry-run-cli "$RUN_ID" pid-A "Alice Adams"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Alice Adams"* ]]
  [[ "$output" == *"1/3"* ]]    # 1 of 3 fetched profiles processed
  jq -se 'any(.[]; .event=="progress" and .processed==1 and .total==3 and .credited_name=="Alice Adams")' < "$RUNLOG_FILE"
}

@test "cumulative count tracks across multiple profiles" {
  seed_decision pid-A; seed_decision pid-B
  run "$SCRIPTS_DIR/post-progress-tick.sh" --dry-run-cli "$RUN_ID" pid-B
  [ "$status" -eq 0 ]
  [[ "$output" == *"2/3"* ]]
}

@test "happy path posts via openclaw with --reply-to" {
  seed_decision pid-A
  local bin_dir calls
  bin_dir="$TEST_TMPDIR/bin"
  calls="$TEST_TMPDIR/openclaw.calls"
  mkdir -p "$bin_dir"
  cat > "$bin_dir/openclaw" <<'EOF'
#!/usr/bin/env bash
printf 'CALL %q\n' "$*" >> "$OPENCLAW_CALLS"
printf '{"messageId":"1777890050.999999"}\n'
EOF
  chmod +x "$bin_dir/openclaw"
  export OPENCLAW_CALLS="$calls"
  export PATH="$bin_dir:$PATH"

  run --separate-stderr "$SCRIPTS_DIR/post-progress-tick.sh" "$RUN_ID" pid-A "Alice"
  [ "$status" -eq 0 ]
  [ "$(grep -c '^CALL ' "$calls")" -eq 1 ]
  LC_ALL=C grep -q 'reply-to' "$calls"
  LC_ALL=C grep -q '1777890000.111111' "$calls"
  jq -se 'any(.[]; .event=="progress" and .tick_msg_ts=="1777890050.999999")' < "$RUNLOG_FILE"
}

@test "throttle: second tick within window writes progress_throttled, no openclaw call" {
  seed_decision pid-A
  seed_decision pid-B
  # First tick lands a real progress event (mock openclaw)
  local bin_dir calls
  bin_dir="$TEST_TMPDIR/bin"
  calls="$TEST_TMPDIR/openclaw.calls"
  mkdir -p "$bin_dir"
  cat > "$bin_dir/openclaw" <<'EOF'
#!/usr/bin/env bash
printf 'CALL %q\n' "$*" >> "$OPENCLAW_CALLS"
printf '{"messageId":"1777890050.111111"}\n'
EOF
  chmod +x "$bin_dir/openclaw"
  export OPENCLAW_CALLS="$calls"
  export PATH="$bin_dir:$PATH"
  # Throttle = 60s — guaranteed to skip second tick
  export CV_PROGRESS_TICK_THROTTLE_SECONDS=60

  run --separate-stderr "$SCRIPTS_DIR/post-progress-tick.sh" "$RUN_ID" pid-A "Alice"
  [ "$status" -eq 0 ]
  [ "$(grep -c '^CALL ' "$calls")" -eq 1 ]

  # Second tick should be throttled (no new openclaw call)
  run --separate-stderr "$SCRIPTS_DIR/post-progress-tick.sh" "$RUN_ID" pid-B "Bob"
  [ "$status" -eq 0 ]
  [[ "$output" == *"THROTTLED"* ]]
  [ "$(grep -c '^CALL ' "$calls")" -eq 1 ]
  jq -se 'any(.[]; .event=="progress_throttled" and .profile_id=="pid-B")' < "$RUNLOG_FILE"
}

@test "throttle: --force bypasses the throttle and posts" {
  seed_decision pid-A
  seed_decision pid-B
  local bin_dir calls
  bin_dir="$TEST_TMPDIR/bin"
  calls="$TEST_TMPDIR/openclaw.calls"
  mkdir -p "$bin_dir"
  cat > "$bin_dir/openclaw" <<'EOF'
#!/usr/bin/env bash
printf 'CALL %q\n' "$*" >> "$OPENCLAW_CALLS"
printf '{"messageId":"x"}\n'
EOF
  chmod +x "$bin_dir/openclaw"
  export OPENCLAW_CALLS="$calls"
  export PATH="$bin_dir:$PATH"
  export CV_PROGRESS_TICK_THROTTLE_SECONDS=60

  run --separate-stderr "$SCRIPTS_DIR/post-progress-tick.sh" "$RUN_ID" pid-A
  [ "$status" -eq 0 ]
  run --separate-stderr "$SCRIPTS_DIR/post-progress-tick.sh" --force "$RUN_ID" pid-B
  [ "$status" -eq 0 ]
  [ "$(grep -c '^CALL ' "$calls")" -eq 2 ]
}

@test "OPS_DRY_RUN=1 routes to dry-run channel" {
  seed_decision pid-A
  local bin_dir calls
  bin_dir="$TEST_TMPDIR/bin"
  calls="$TEST_TMPDIR/openclaw.calls"
  mkdir -p "$bin_dir"
  cat > "$bin_dir/openclaw" <<'EOF'
#!/usr/bin/env bash
printf 'CALL %q\n' "$*" >> "$OPENCLAW_CALLS"
printf '{"messageId":"x"}\n'
EOF
  chmod +x "$bin_dir/openclaw"
  export OPENCLAW_CALLS="$calls"
  export PATH="$bin_dir:$PATH"

  run --separate-stderr env OPS_DRY_RUN=1 "$SCRIPTS_DIR/post-progress-tick.sh" "$RUN_ID" pid-A
  [ "$status" -eq 0 ]
  LC_ALL=C grep -q 'C_TESTDRY' "$calls"
  ! LC_ALL=C grep -q 'C_TESTPROD' "$calls"
}
