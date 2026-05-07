#!/usr/bin/env bats
bats_require_minimum_version 1.5.0
load helpers

# post-batch-summary.sh — sanctioned wrapper for posting [HEARTBEAT-BATCH]
# parent + thread to #credit-verification. Refuses to post when the run
# is not yet finished, has the in-flight (B1-only) shape, or fails the
# browser-evidence audit. Tests use --dry-run-cli to validate the gate logic
# + payload composition without invoking the openclaw message CLI.

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

  # Browser evidence audit fixture path.
  export SESSION_LOG="$TEST_TMPDIR/session.jsonl"
  : > "$SESSION_LOG"

  # Channel envs — set both so we can flip via dryRun in the runlog.
  export OPS_CREDIT_VERIFICATION_CHANNEL_ID="C_TESTPROD"
  export OPS_CREDIT_VERIFICATION_DRY_RUN_CHANNEL_ID="C_TESTDRY"
  export OPS_OPENCLAW_PROFILE="test"
}
teardown() { teardown_tmp_env; }

seed_browser_ok() {
  local id="$1" url="$2" text="${3:-snapshot ok}"
  jq -n -c --arg id "$id" --arg url "$url" \
    '{timestamp:"2026-04-20T12:00:10Z", message:{role:"assistant", content:[{type:"toolCall", id:$id, name:"browser", arguments:{url:$url}}]}}' >> "$SESSION_LOG"
  jq -n -c --arg id "$id" --arg text "$text" \
    '{timestamp:"2026-04-20T12:00:11Z", message:{role:"toolResult", toolCallId:$id, isError:false, content:[{type:"text", text:$text}]}}' >> "$SESSION_LOG"
}

# Seed a complete runlog: run_started_queue + run_finished + N action_attempted.
# Args: queue_depth attempts dryRun(true|false)
#
# Each profile gets a profile_group_fetched event with claim metadata
# (Drezar / Yellow Submarine / songwriter) and a matching Tier-1 browser
# load. The audit's per-profile attribution requires this — the muso.ai
# anchor was dropped 2026-05-04.
seed_finished_runlog() {
  local qdepth="$1" attempts="$2" dry="${3:-false}"
  local ts
  ts="2026-04-20T12:00:00Z"
  jq -n -c --arg rid "$RUN_ID" --arg ts "$ts" --argjson dry "$dry" \
    '{event:"run_header", run_id:$rid, ts:$ts, dryRun:$dry}' >> "$RUNLOG_FILE"
  jq -n -c --arg rid "$RUN_ID" --arg ts "$ts" --argjson qd "$qdepth" \
    '{event:"run_started", run_id:$rid, ts:$ts, phase:"0"}' >> "$RUNLOG_FILE"
  jq -n -c --arg rid "$RUN_ID" --arg ts "$ts" --argjson qd "$qdepth" \
    '{event:"run_started_queue", run_id:$rid, ts:$ts, queue_depth_at_start:$qd}' >> "$RUNLOG_FILE"
  jq -n -c --arg rid "$RUN_ID" --arg ts "$ts" \
    '{event:"batch_announced", run_id:$rid, ts:$ts, queue_depth:13864, fetch_size:5, profile_count:5, parent_msg_ts:"1.1"}' >> "$RUNLOG_FILE"
  local i=0
  while [[ "$i" -lt "$attempts" ]]; do
    pid=$(printf '11111111-1111-1111-1111-%012d' "$i")
    jq -n -c --arg rid "$RUN_ID" --arg ts "$ts" --arg cr "cr_$i" --arg pid "$pid" \
      '{event:"profile_group_fetched", run_id:$rid, ts:$ts, profile_id:$pid, credited_name:"Drezar", track_title:"Yellow Submarine", role:"songwriter", count:1, cr_ids:[$cr]}' >> "$RUNLOG_FILE"
    jq -n -c --arg rid "$RUN_ID" --arg ts "$ts" --arg cr "cr_$i" --arg pid "$pid" \
      '{event:"action_attempted", run_id:$rid, ts:$ts, action:"approve", cr_id:$cr, profile_id:$pid}' >> "$RUNLOG_FILE"
    seed_browser_ok "profile_$i" "https://musicbrainz.org/artist/$pid" "Drezar credited as songwriter on Yellow Submarine"
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
  jq -n -c --arg rid "$RUN_ID" --arg ts "2026-04-20T12:00:00Z" \
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
  ts="2026-04-20T12:00:00Z"
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
  run --separate-stderr env CV_SESSION_LOG_OVERRIDE="$SESSION_LOG" "$SCRIPTS_DIR/post-batch-summary.sh" "$RUN_ID" --dry-run-cli
  [ "$status" -eq 0 ]
  [[ "$output" == *"POST_BATCH_SUMMARY_OK: target=C_TESTPROD"* ]]
  [[ "$output" == *"----- PARENT -----"* ]]
  [[ "$output" == *"----- THREAD -----"* ]]
  # Parent contains "[HEARTBEAT-BATCH]" header (from render-slack-summary.sh)
  [[ "$output" == *"[HEARTBEAT-BATCH]"* ]] || [[ "$output" == *"Credit batch complete"* ]]
}

@test "dry-run runlog routes to OPS_CREDIT_VERIFICATION_DRY_RUN_CHANNEL_ID" {
  seed_finished_runlog 100 5 true
  run env CV_SESSION_LOG_OVERRIDE="$SESSION_LOG" "$SCRIPTS_DIR/post-batch-summary.sh" "$RUN_ID" --dry-run-cli
  [ "$status" -eq 0 ]
  [[ "$output" == *"target=C_TESTDRY"* ]]
  [[ "$output" == *"dryRun=true"* ]]
}

@test "dry-run runlog without OPS_CREDIT_VERIFICATION_DRY_RUN_CHANNEL_ID exits 2" {
  seed_finished_runlog 100 5 true
  unset OPS_CREDIT_VERIFICATION_DRY_RUN_CHANNEL_ID
  run --separate-stderr env CV_SESSION_LOG_OVERRIDE="$SESSION_LOG" "$SCRIPTS_DIR/post-batch-summary.sh" "$RUN_ID" --dry-run-cli
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"OPS_CREDIT_VERIFICATION_DRY_RUN_CHANNEL_ID"* ]]
}

@test "empty queue (queue_depth==0, attempts==0) is allowed — legitimate queue-clear shape" {
  # When the queue is genuinely empty, action_attempted is 0 BUT
  # queue_depth_at_start is also 0 — the in-flight check skips and the
  # post proceeds to render the queue-clear summary.
  seed_finished_runlog 0 0 false
  run env CV_SESSION_LOG_OVERRIDE=/nonexistent/path "$SCRIPTS_DIR/post-batch-summary.sh" "$RUN_ID" --dry-run-cli
  [ "$status" -eq 0 ]
  [[ "$output" == *"POST_BATCH_SUMMARY_OK"* ]]
}

@test "refuses (exit 11) when browser evidence audit finds rewritten runlog shape" {
  export RUN_ID="20260504-080455-6e3532"
  day="${RUN_ID:0:8}"
  RUNLOG_DIR="$OPS_RUNLOG_DIR/${day:0:4}-${day:4:2}-${day:6:2}"
  mkdir -p "$RUNLOG_DIR"
  export RUNLOG_FILE="$RUNLOG_DIR/${RUN_ID}.jsonl"
  : > "$RUNLOG_FILE"
  : > "$SESSION_LOG"

  jq -n -c --arg rid "$RUN_ID" '{event:"run_started", run_id:$rid, ts:"2026-05-04T08:05:00Z", phase:"0"}' >> "$RUNLOG_FILE"
  jq -n -c --arg rid "$RUN_ID" '{event:"run_started_queue", run_id:$rid, ts:"2026-05-04T08:05:00Z", queue_depth_at_start:50}' >> "$RUNLOG_FILE"
  seed_browser_ok c1 "https://muso.ai/profile/36b8d0e3-fc80-46a9-a19a-a74c0ebefbd0"
  seed_browser_ok c2 "https://musicbrainz.org/track/4UibJ9fYMrKtaKb7UbC9s3" "Sign up. No credit card needed."

  for n in $(seq 1 50); do
    pid=$(printf '00000000-0000-0000-0000-%012d' "$n")
    jq -n -c --arg rid "$RUN_ID" --arg pid "$pid" --arg cr "cr_$n" \
      '{event:"escalation_posted", run_id:$rid, ts:"2026-05-04T08:05:00Z", profile_id:$pid, cr_id:$cr, reason:"tier1_unreachable"}' >> "$RUNLOG_FILE"
    jq -n -c --arg rid "$RUN_ID" --arg pid "$pid" --arg cr "cr_$n" \
      '{event:"action_attempted", run_id:$rid, ts:"2026-05-04T08:05:00Z", profile_id:$pid, action:"escalate", cr_ids:[$cr], reason:"tier1_unreachable"}' >> "$RUNLOG_FILE"
  done
  jq -n -c --arg rid "$RUN_ID" \
    '{event:"run_finished", run_id:$rid, ts:"2026-05-04T08:05:00Z", fetched:50, approved:0, verification_needed:0, escalated:50, skipped_idempotent:0, skipped_cap:0}' >> "$RUNLOG_FILE"

  run env CV_SESSION_LOG_OVERRIDE="$SESSION_LOG" "$SCRIPTS_DIR/post-batch-summary.sh" "$RUN_ID" --dry-run-cli
  [ "$status" -eq 11 ]
  [[ "$output" == *"browser evidence audit failed"* ]]
  [[ "$output" == *"Slack summary suppressed"* ]]
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

  run --separate-stderr env CV_SESSION_LOG_OVERRIDE="$SESSION_LOG" "$SCRIPTS_DIR/post-batch-summary.sh" "$RUN_ID"
  [ "$status" -eq 10 ]
  [[ "$stderr" == *"couldn't extract message id/ts"* ]]
  [ "$(grep -c '^CALL ' "$calls")" -eq 1 ]
  ! grep -q -- '--reply-to' "$calls"
}

@test "tolerates openclaw 'Config warnings:' stdout prelude — extracts msgId, posts thread, writes script_warning event" {
  # 2026-05-04 run 20260504-124537-3fd64c: openclaw CLI emitted multi-line
  # 'Config warnings:' prelude before the JSON object. Old jq invocation
  # choked on the prelude → rc=10 even though the parent post succeeded.
  # This regression test mocks the same shape and asserts the script
  # extracts 1777890999.123456 and posts the thread reply.
  seed_finished_runlog 100 5 false

  local bin_dir calls
  bin_dir="$TEST_TMPDIR/bin"
  calls="$TEST_TMPDIR/openclaw.calls"
  mkdir -p "$bin_dir"
  cat > "$bin_dir/openclaw" <<'EOF'
#!/usr/bin/env bash
printf 'CALL %q\n' "$*" >> "$OPENCLAW_CALLS"
cat <<'STDOUT'
Config warnings:
- plugins.entries.intercom: plugin intercom: channel plugin manifest declares intercom without channelConfigs metadata
- plugins.entries.openclaw-gmail: plugin openclaw-gmail: channel plugin manifest declares openclaw-gmail without channelConfigs metadata
{"ok":true,"messageId":"1777890999.123456","ts":"1777890999.123456"}
STDOUT
EOF
  chmod +x "$bin_dir/openclaw"
  export OPENCLAW_CALLS="$calls"
  export PATH="$bin_dir:$PATH"

  run --separate-stderr env CV_SESSION_LOG_OVERRIDE="$SESSION_LOG" "$SCRIPTS_DIR/post-batch-summary.sh" "$RUN_ID"
  [ "$status" -eq 0 ]
  # Two openclaw calls: parent + thread (thread requires successful id extraction)
  [ "$(grep -c '^CALL ' "$calls")" -eq 2 ]
  # Force C locale on grep — the calls file contains multibyte UTF-8 (Slack
  # message body has em-dash and Unicode arrows) which can confuse pattern
  # matching under some locales.
  LC_ALL=C grep -q 'reply-to' "$calls"
  LC_ALL=C grep -q '1777890999.123456' "$calls"
  # script_warning event landed in runlog so the upstream issue is observable
  grep -q '"event":"script_warning"' "$RUNLOG_FILE"
  grep -q '"source":"openclaw_cli_config_warnings"' "$RUNLOG_FILE"
}

@test "no script_warning event when openclaw stdout has no warnings prelude" {
  seed_finished_runlog 100 5 false

  local bin_dir calls
  bin_dir="$TEST_TMPDIR/bin"
  calls="$TEST_TMPDIR/openclaw.calls"
  mkdir -p "$bin_dir"
  cat > "$bin_dir/openclaw" <<'EOF'
#!/usr/bin/env bash
printf 'CALL %q\n' "$*" >> "$OPENCLAW_CALLS"
printf '{"ok":true,"messageId":"1777890999.999999","ts":"1777890999.999999"}\n'
EOF
  chmod +x "$bin_dir/openclaw"
  export OPENCLAW_CALLS="$calls"
  export PATH="$bin_dir:$PATH"

  run --separate-stderr env CV_SESSION_LOG_OVERRIDE="$SESSION_LOG" "$SCRIPTS_DIR/post-batch-summary.sh" "$RUN_ID"
  [ "$status" -eq 0 ]
  ! grep -q '"event":"script_warning"' "$RUNLOG_FILE"
}

@test "writes summary_posted_canonical event after both sends succeed (lockfile R4-3 short-circuit)" {
  # Direct success marker for lockfile.sh's renderer-missing detector. Added
  # 2026-05-07 to replace the broken session-log heuristic that fired on
  # every healthy batch because the canonical path went through the
  # openclaw CLI (no MCP message toolCall to find).
  seed_finished_runlog 100 5 false

  local bin_dir calls
  bin_dir="$TEST_TMPDIR/bin"
  calls="$TEST_TMPDIR/openclaw.calls"
  mkdir -p "$bin_dir"
  cat > "$bin_dir/openclaw" <<'EOF'
#!/usr/bin/env bash
printf 'CALL %q\n' "$*" >> "$OPENCLAW_CALLS"
printf '{"ok":true,"messageId":"1788000000.111111","ts":"1788000000.111111"}\n'
EOF
  chmod +x "$bin_dir/openclaw"
  export OPENCLAW_CALLS="$calls"
  export PATH="$bin_dir:$PATH"

  run env CV_SESSION_LOG_OVERRIDE="$SESSION_LOG" "$SCRIPTS_DIR/post-batch-summary.sh" "$RUN_ID"
  [ "$status" -eq 0 ]
  # Marker event landed with the parent message id, channel, and dry_run flag.
  jq -e 'select(.event == "summary_posted_canonical")' < "$RUNLOG_FILE"
  jq -e 'select(.event == "summary_posted_canonical") | .parent_msg_id == "1788000000.111111"' < "$RUNLOG_FILE"
  jq -e 'select(.event == "summary_posted_canonical") | .channel == "C_TESTPROD"' < "$RUNLOG_FILE"
  jq -e 'select(.event == "summary_posted_canonical") | .dry_run == false' < "$RUNLOG_FILE"
  jq -e 'select(.event == "summary_posted_canonical") | .script == "post-batch-summary.sh"' < "$RUNLOG_FILE"
}

@test "summary_posted_canonical records dry_run=true when runlog dryRun=true" {
  seed_finished_runlog 100 5 true

  local bin_dir calls
  bin_dir="$TEST_TMPDIR/bin"
  calls="$TEST_TMPDIR/openclaw.calls"
  mkdir -p "$bin_dir"
  cat > "$bin_dir/openclaw" <<'EOF'
#!/usr/bin/env bash
printf 'CALL %q\n' "$*" >> "$OPENCLAW_CALLS"
printf '{"ok":true,"messageId":"1788000001.222222","ts":"1788000001.222222"}\n'
EOF
  chmod +x "$bin_dir/openclaw"
  export OPENCLAW_CALLS="$calls"
  export PATH="$bin_dir:$PATH"

  run env CV_SESSION_LOG_OVERRIDE="$SESSION_LOG" "$SCRIPTS_DIR/post-batch-summary.sh" "$RUN_ID"
  [ "$status" -eq 0 ]
  jq -e 'select(.event == "summary_posted_canonical") | .dry_run == true' < "$RUNLOG_FILE"
  jq -e 'select(.event == "summary_posted_canonical") | .channel == "C_TESTDRY"' < "$RUNLOG_FILE"
}

@test "no summary_posted_canonical event when parent send fails" {
  # Negative test: if the openclaw send errors out, the script must NOT
  # write the success marker. Otherwise the lockfile detector would
  # short-circuit on a half-completed run.
  seed_finished_runlog 100 5 false

  local bin_dir calls
  bin_dir="$TEST_TMPDIR/bin"
  calls="$TEST_TMPDIR/openclaw.calls"
  mkdir -p "$bin_dir"
  cat > "$bin_dir/openclaw" <<'EOF'
#!/usr/bin/env bash
printf 'CALL %q\n' "$*" >> "$OPENCLAW_CALLS"
echo "ERROR: simulated openclaw failure" >&2
exit 1
EOF
  chmod +x "$bin_dir/openclaw"
  export OPENCLAW_CALLS="$calls"
  export PATH="$bin_dir:$PATH"

  run env CV_SESSION_LOG_OVERRIDE="$SESSION_LOG" "$SCRIPTS_DIR/post-batch-summary.sh" "$RUN_ID"
  [ "$status" -eq 10 ]
  ! grep -q '"event":"summary_posted_canonical"' "$RUNLOG_FILE"
}
