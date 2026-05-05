#!/usr/bin/env bats
bats_require_minimum_version 1.5.0
load helpers

setup() {
  setup_tmp_env
  export RUN_ID="20260504-130000-aaa111"
  day="${RUN_ID:0:8}"
  RUNLOG_DIR="$OPS_RUNLOG_DIR/${day:0:4}-${day:4:2}-${day:6:2}"
  mkdir -p "$RUNLOG_DIR"
  export RUNLOG_FILE="$RUNLOG_DIR/${RUN_ID}.jsonl"
  : > "$RUNLOG_FILE"
  jq -n -c --arg rid "$RUN_ID" '{event:"run_started", run_id:$rid, ts:"2026-05-04T13:00:00Z", phase:"0"}' >> "$RUNLOG_FILE"

  # A realistic queue.json shape (mirrors what fetch-queue.sh emits, with
  # items already enriched with credited_name).
  export OPS_QUEUE_JSON_PATH="$TEST_TMPDIR/queue.json"
  # Fixture mirrors the live admin-API shape that fetch-queue.sh passes
  # through: items use camelCase `profileId` and the credited name is
  # nested at `.profile.name` (verified against live API 2026-05-01).
  cat > "$OPS_QUEUE_JSON_PATH" <<'EOF'
{
  "queue_depth": 13864,
  "fetch_size": 5,
  "items": [
    {"profileId": "pid-A", "profile": {"name": "Alice Adams"}, "id": "cr1"},
    {"profileId": "pid-A", "profile": {"name": "Alice Adams"}, "id": "cr2"},
    {"profileId": "pid-B", "profile": {"name": "Bob Brown"},   "id": "cr3"},
    {"profileId": "pid-C", "profile": {"name": "Carol Cole"},  "id": "cr4"},
    {"profileId": "pid-D", "profile": {"name": "Dan Davis"},   "id": "cr5"}
  ]
}
EOF

  export OPS_PARENT_MSG_TS="1777890000.111111"
  export OPS_CREDIT_VERIFICATION_CHANNEL_ID="C_TESTPROD"
  export OPS_CREDIT_VERIFICATION_DRY_RUN_CHANNEL_ID="C_TESTDRY"
  export OPS_OPENCLAW_PROFILE="test"
}
teardown() { teardown_tmp_env; }

@test "missing RUN_ID exits 2" {
  run "$SCRIPTS_DIR/post-batch-announce.sh"
  [ "$status" -eq 2 ]
}

@test "missing parent thread ts exits 2" {
  unset OPS_PARENT_MSG_TS
  run "$SCRIPTS_DIR/post-batch-announce.sh" "$RUN_ID"
  [ "$status" -eq 2 ]
  [[ "$output" == *"parent thread ts is required"* ]]
}

@test "missing queue file exits 2" {
  rm -f "$OPS_QUEUE_JSON_PATH"
  run "$SCRIPTS_DIR/post-batch-announce.sh" "$RUN_ID"
  [ "$status" -eq 2 ]
  [[ "$output" == *"queue JSON not found"* ]]
}

@test "missing runlog file exits 5" {
  rm -f "$RUNLOG_FILE"
  run "$SCRIPTS_DIR/post-batch-announce.sh" "$RUN_ID"
  [ "$status" -eq 5 ]
}

@test "--dry-run-cli composes the announce body and writes batch_announced event" {
  run "$SCRIPTS_DIR/post-batch-announce.sh" --dry-run-cli "$RUN_ID"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Starting credit verification batch"* ]]
  [[ "$output" == *"13864"* ]]                    # queue depth
  [[ "$output" == *"5 credits across 4 profile"* ]] # 5 items / 4 distinct profiles
  [[ "$output" == *"Alice Adams"* ]]              # name list rendered
  [[ "$output" == *"$RUN_ID"* ]]
  # batch_announced event lands
  grep -q '"event":"batch_announced"' "$RUNLOG_FILE"
  jq -se 'any(.[]; .event == "batch_announced" and .queue_depth == 13864 and .profile_count == 4)' < "$RUNLOG_FILE"
}

@test "happy path posts via openclaw with --reply-to and writes batch_announced with msg ts" {
  local bin_dir calls
  bin_dir="$TEST_TMPDIR/bin"
  calls="$TEST_TMPDIR/openclaw.calls"
  mkdir -p "$bin_dir"
  cat > "$bin_dir/openclaw" <<'EOF'
#!/usr/bin/env bash
printf 'CALL %q\n' "$*" >> "$OPENCLAW_CALLS"
printf '{"ok":true,"messageId":"1777890050.222222","ts":"1777890050.222222"}\n'
EOF
  chmod +x "$bin_dir/openclaw"
  export OPENCLAW_CALLS="$calls"
  export PATH="$bin_dir:$PATH"

  run --separate-stderr "$SCRIPTS_DIR/post-batch-announce.sh" "$RUN_ID"
  [ "$status" -eq 0 ]
  [ "$(grep -c '^CALL ' "$calls")" -eq 1 ]
  LC_ALL=C grep -q 'reply-to' "$calls"
  LC_ALL=C grep -q "$OPS_PARENT_MSG_TS" "$calls"
  jq -se 'any(.[]; .event == "batch_announced" and .announce_msg_ts == "1777890050.222222" and .parent_msg_ts == "1777890000.111111")' < "$RUNLOG_FILE"
}

@test "tolerates openclaw 'Config warnings:' prelude — extracts msg ts and writes script_warning" {
  local bin_dir calls
  bin_dir="$TEST_TMPDIR/bin"
  calls="$TEST_TMPDIR/openclaw.calls"
  mkdir -p "$bin_dir"
  cat > "$bin_dir/openclaw" <<'EOF'
#!/usr/bin/env bash
printf 'CALL %q\n' "$*" >> "$OPENCLAW_CALLS"
cat <<'STDOUT'
Config warnings:
- plugins.entries.intercom: missing channelConfigs
{"ok":true,"messageId":"1777890050.333333"}
STDOUT
EOF
  chmod +x "$bin_dir/openclaw"
  export OPENCLAW_CALLS="$calls"
  export PATH="$bin_dir:$PATH"

  run --separate-stderr "$SCRIPTS_DIR/post-batch-announce.sh" "$RUN_ID"
  [ "$status" -eq 0 ]
  jq -se 'any(.[]; .event == "batch_announced" and .announce_msg_ts == "1777890050.333333")' < "$RUNLOG_FILE"
  grep -q '"event":"script_warning"' "$RUNLOG_FILE"
}

@test "OPS_DRY_RUN=1 routes to dry-run channel" {
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

  run --separate-stderr env OPS_DRY_RUN=1 "$SCRIPTS_DIR/post-batch-announce.sh" "$RUN_ID"
  [ "$status" -eq 0 ]
  LC_ALL=C grep -q 'C_TESTDRY' "$calls"
  ! LC_ALL=C grep -q 'C_TESTPROD' "$calls"
}

@test "OPS_DRY_RUN=1 without dry-run channel id exits 2" {
  unset OPS_CREDIT_VERIFICATION_DRY_RUN_CHANNEL_ID
  run env OPS_DRY_RUN=1 "$SCRIPTS_DIR/post-batch-announce.sh" "$RUN_ID"
  [ "$status" -eq 2 ]
}

@test "idempotency: second invocation for same run_id does NOT post or duplicate batch_announced" {
  local bin_dir calls
  bin_dir="$TEST_TMPDIR/bin"
  calls="$TEST_TMPDIR/openclaw.calls"
  mkdir -p "$bin_dir"
  cat > "$bin_dir/openclaw" <<'EOF'
#!/usr/bin/env bash
printf 'CALL %q\n' "$*" >> "$OPENCLAW_CALLS"
printf '{"messageId":"1777890050.first"}\n'
EOF
  chmod +x "$bin_dir/openclaw"
  export OPENCLAW_CALLS="$calls"
  export PATH="$bin_dir:$PATH"

  # First call posts and writes batch_announced
  run --separate-stderr "$SCRIPTS_DIR/post-batch-announce.sh" "$RUN_ID"
  [ "$status" -eq 0 ]
  [ "$(grep -c '^CALL ' "$calls")" -eq 1 ]

  # Second call detects prior announce and skips — no new openclaw call,
  # writes batch_announce_skipped instead of batch_announced
  run --separate-stderr "$SCRIPTS_DIR/post-batch-announce.sh" "$RUN_ID"
  [ "$status" -eq 0 ]
  [[ "$output" == *"POST_BATCH_ANNOUNCE_SKIPPED"* ]]
  [ "$(grep -c '^CALL ' "$calls")" -eq 1 ]

  # Runlog has exactly one batch_announced and exactly one batch_announce_skipped
  [ "$(jq -s '[.[] | select(.event=="batch_announced")] | length' < "$RUNLOG_FILE")" = "1" ]
  [ "$(jq -s '[.[] | select(.event=="batch_announce_skipped")] | length' < "$RUNLOG_FILE")" = "1" ]
  jq -se 'any(.[]; .event=="batch_announce_skipped" and .prior_announce_msg_ts=="1777890050.first")' < "$RUNLOG_FILE"
}

@test "name list truncates after 6 entries with overflow indicator" {
  cat > "$OPS_QUEUE_JSON_PATH" <<'EOF'
{
  "queue_depth": 100,
  "fetch_size": 8,
  "items": [
    {"profileId":"p1","profile":{"name":"One"},"id":"c1"},
    {"profileId":"p2","profile":{"name":"Two"},"id":"c2"},
    {"profileId":"p3","profile":{"name":"Three"},"id":"c3"},
    {"profileId":"p4","profile":{"name":"Four"},"id":"c4"},
    {"profileId":"p5","profile":{"name":"Five"},"id":"c5"},
    {"profileId":"p6","profile":{"name":"Six"},"id":"c6"},
    {"profileId":"p7","profile":{"name":"Seven"},"id":"c7"},
    {"profileId":"p8","profile":{"name":"Eight"},"id":"c8"}
  ]
}
EOF
  run "$SCRIPTS_DIR/post-batch-announce.sh" --dry-run-cli "$RUN_ID"
  [ "$status" -eq 0 ]
  [[ "$output" == *"and 2 more"* ]]
}
