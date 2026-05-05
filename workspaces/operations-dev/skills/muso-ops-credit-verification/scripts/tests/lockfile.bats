#!/usr/bin/env bats
load helpers

setup() { setup_tmp_env; }
teardown() { teardown_tmp_env; }

@test "acquire succeeds when no lockfile exists" {
  run "$SCRIPTS_DIR/lockfile.sh" acquire
  [ "$status" -eq 0 ]
  [ -f "$OPS_BATCH_LOCK_PATH" ]
  # Contents: pid:hostname:workspace
  grep -q "^[0-9]\+:.\+:.\+$" "$OPS_BATCH_LOCK_PATH"
}

@test "acquire fails silently (exit 10) when live PID holds lock" {
  # Seed lock with this process's PID (always alive during the test)
  mkdir -p "$(dirname "$OPS_BATCH_LOCK_PATH")"
  echo "$$:test-host:operations-dev" > "$OPS_BATCH_LOCK_PATH"
  run "$SCRIPTS_DIR/lockfile.sh" acquire
  [ "$status" -eq 10 ]  # 10 = lock held by live process
}

@test "acquire steals lock when PID is dead (non-existent)" {
  mkdir -p "$(dirname "$OPS_BATCH_LOCK_PATH")"
  echo "99999999:old-host:operations-dev" > "$OPS_BATCH_LOCK_PATH"
  run "$SCRIPTS_DIR/lockfile.sh" acquire
  [ "$status" -eq 0 ]
  # Lock should now contain a new (non-99999999) PID — the stealing process's own $$.
  # (Not bats's $$: `run` forks a subshell, so the script writes its own PID, which
  # differs from the test body's $$.)
  ! grep -q "^99999999:" "$OPS_BATCH_LOCK_PATH"
  grep -q "^[0-9]\+:.\+:.\+$" "$OPS_BATCH_LOCK_PATH"
}

@test "acquire treats mtime >= 3h30m as stale regardless of PID" {
  mkdir -p "$(dirname "$OPS_BATCH_LOCK_PATH")"
  echo "$$:test-host:operations-dev" > "$OPS_BATCH_LOCK_PATH"
  # Backdate the file to 4 hours ago — one full cron cycle, well above the
  # 3h30m stale threshold.
  touch -t "$(past_touch_stamp 14400)" "$OPS_BATCH_LOCK_PATH"
  run "$SCRIPTS_DIR/lockfile.sh" acquire
  [ "$status" -eq 0 ]
}

@test "acquire honors live lock whose mtime is fresher than 3h30m" {
  mkdir -p "$(dirname "$OPS_BATCH_LOCK_PATH")"
  echo "$$:test-host:operations-dev" > "$OPS_BATCH_LOCK_PATH"
  # Backdate to 3 hours ago — below the 3h30m stale threshold. Live PID + fresh
  # mtime must refuse to steal (exit 10). Guards against regression if
  # STALE_SECONDS is ever tightened further.
  touch -t "$(past_touch_stamp 10800)" "$OPS_BATCH_LOCK_PATH"
  run "$SCRIPTS_DIR/lockfile.sh" acquire
  [ "$status" -eq 10 ]
}

@test "release removes the lockfile" {
  "$SCRIPTS_DIR/lockfile.sh" acquire
  [ -f "$OPS_BATCH_LOCK_PATH" ]
  run "$SCRIPTS_DIR/lockfile.sh" release
  [ "$status" -eq 0 ]
  [ ! -f "$OPS_BATCH_LOCK_PATH" ]
}

# --- Auto-fill run_finished fallback (issue #152, Gap 3) ---
# Release is the last supervised action of a batch turn; if the bot skipped
# SKILL.md B6 (the explicit compute-run-summary.sh invocation), the runlog
# lacks a run_finished event and the Slack summary was agent-fabricated.
# Release must invoke compute-run-summary.sh as a mechanical fallback. All
# of these are fail-OPEN — lockfile removal must never depend on
# compute-run-summary's behavior.

seed_runlog_without_run_finished() {
  # Creates a runlog with just a run_header event and wires latest.txt.
  # Returns the run_id on stdout.
  local day ts short run_id dir log
  day=$(date -u +%Y%m%d)
  ts=$(date -u +%H%M%S)
  short="f8108c"
  run_id="${day}-${ts}-${short}"
  dir="$OPS_RUNLOG_DIR/${day:0:4}-${day:4:2}-${day:6:2}"
  mkdir -p "$dir"
  log="$dir/${run_id}.jsonl"
  jq -n -c --arg rid "$run_id" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      '{event:"run_header", run_id:$rid, ts:$ts, dryRun:false}' > "$log"
  echo "$log" > "$OPS_RUNLOG_DIR/latest.txt"
  echo "$run_id"
}

@test "release --final invokes compute-run-summary.sh when runlog lacks run_finished AND is quiescent" {
  "$SCRIPTS_DIR/lockfile.sh" acquire
  local run_id
  run_id=$(seed_runlog_without_run_finished)
  # Backdate the runlog past the 120s quiescence window so the autofill
  # is allowed to fire. Without this, the quiescence guard would skip
  # autofill (correct behavior — see Failure 2 fix).
  local day="${run_id:0:8}"
  local log="$OPS_RUNLOG_DIR/${day:0:4}-${day:4:2}-${day:6:2}/${run_id}.jsonl"
  touch -t "$(past_touch_stamp 300)" "$log"

  run "$SCRIPTS_DIR/lockfile.sh" release --final
  # Fail-OPEN: release always succeeds; lockfile is always removed.
  [ "$status" -eq 0 ]
  [ ! -f "$OPS_BATCH_LOCK_PATH" ]
  # But the fallback-invocation marker must be on stderr (merged into $output
  # by bats `run`), proving compute-run-summary was attempted.
  [[ "$output" == *"no run_finished event"* ]]
  [[ "$output" == *"compute-run-summary.sh"* ]]
}

@test "release WITHOUT --final does NOT invoke compute-run-summary even when runlog lacks run_finished (Failure 2 fix)" {
  # 2026-04-28 15:35:00 UTC: when gpt-5.5 split B0+B1 and B2+ across two
  # exec calls, the trap-on-EXIT in exec 1 fired release, which previously
  # autofilled run_finished_hollow 53s before B2 actually ran. Now release
  # (without --final) skips the autofill — only an explicit terminal
  # release writes run_finished.
  "$SCRIPTS_DIR/lockfile.sh" acquire
  seed_runlog_without_run_finished >/dev/null

  run "$SCRIPTS_DIR/lockfile.sh" release
  [ "$status" -eq 0 ]
  [ ! -f "$OPS_BATCH_LOCK_PATH" ]
  # The fallback-invocation marker MUST NOT appear.
  [[ "$output" != *"no run_finished event"* ]]
  [[ "$output" != *"invoking compute-run-summary"* ]]
}

@test "release --final WITH fresh runlog (mtime <120s) skips autofill (quiescence guard)" {
  # Even with --final, decline the autofill if the runlog was just
  # written. A truly-terminal release with a fresh run_started_queue is
  # almost certainly NOT terminal — likely a retry or a misconfigured
  # caller. Skip cleanly; the next compute-run-summary call (with --final)
  # handles it.
  "$SCRIPTS_DIR/lockfile.sh" acquire
  seed_runlog_without_run_finished >/dev/null

  run "$SCRIPTS_DIR/lockfile.sh" release --final
  [ "$status" -eq 0 ]
  [[ "$output" == *"quiescence window"* ]]
  [[ "$output" != *"invoking compute-run-summary"* ]]
}

@test "release --final via OPS_BATCH_TERMINAL=1 env opt-in works the same as the flag" {
  "$SCRIPTS_DIR/lockfile.sh" acquire
  local run_id
  run_id=$(seed_runlog_without_run_finished)
  local day="${run_id:0:8}"
  local log="$OPS_RUNLOG_DIR/${day:0:4}-${day:4:2}-${day:6:2}/${run_id}.jsonl"
  touch -t "$(past_touch_stamp 300)" "$log"

  run env OPS_BATCH_TERMINAL=1 "$SCRIPTS_DIR/lockfile.sh" release
  [ "$status" -eq 0 ]
  [[ "$output" == *"invoking compute-run-summary"* ]]
}

@test "release does NOT invoke compute-run-summary when runlog already has run_finished" {
  "$SCRIPTS_DIR/lockfile.sh" acquire
  local run_id
  run_id=$(seed_runlog_without_run_finished)
  local day="${run_id:0:8}"
  local log="$OPS_RUNLOG_DIR/${day:0:4}-${day:4:2}-${day:6:2}/${run_id}.jsonl"
  # Append a run_finished event so the fallback short-circuits.
  jq -n -c --arg rid "$run_id" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      '{event:"run_finished", run_id:$rid, ts:$ts, approved:0, fetched:0}' >> "$log"

  run "$SCRIPTS_DIR/lockfile.sh" release
  [ "$status" -eq 0 ]
  [ ! -f "$OPS_BATCH_LOCK_PATH" ]
  # The fallback marker must NOT appear — compute-run-summary was skipped.
  [[ "$output" != *"no run_finished event"* ]]
}

@test "release treats run_finished_hollow as sufficient (no fallback invocation)" {
  # Hollow and ungrounded are authoritative forensic events that compute-run-
  # summary.sh itself writes alongside run_finished. Any of the three means
  # the helper already ran for this run.
  "$SCRIPTS_DIR/lockfile.sh" acquire
  local run_id
  run_id=$(seed_runlog_without_run_finished)
  local day="${run_id:0:8}"
  local log="$OPS_RUNLOG_DIR/${day:0:4}-${day:4:2}-${day:6:2}/${run_id}.jsonl"
  jq -n -c --arg rid "$run_id" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      '{event:"run_finished_hollow", run_id:$rid, ts:$ts}' >> "$log"

  run "$SCRIPTS_DIR/lockfile.sh" release
  [ "$status" -eq 0 ]
  [[ "$output" != *"no run_finished event"* ]]
}

@test "release skips fallback when OPS_RUNLOG_DIR is unset (backwards compat)" {
  "$SCRIPTS_DIR/lockfile.sh" acquire
  unset OPS_RUNLOG_DIR
  run "$SCRIPTS_DIR/lockfile.sh" release
  [ "$status" -eq 0 ]
  [ ! -f "$OPS_BATCH_LOCK_PATH" ]
  [[ "$output" != *"no run_finished event"* ]]
}

@test "release skips fallback when latest.txt is absent" {
  "$SCRIPTS_DIR/lockfile.sh" acquire
  # OPS_RUNLOG_DIR is set by setup_tmp_env, but no latest.txt exists yet.
  run "$SCRIPTS_DIR/lockfile.sh" release
  [ "$status" -eq 0 ]
  [ ! -f "$OPS_BATCH_LOCK_PATH" ]
  [[ "$output" != *"no run_finished event"* ]]
}

@test "release skips fallback when latest.txt points at a malformed filename" {
  "$SCRIPTS_DIR/lockfile.sh" acquire
  # Filename doesn't match the YYYYMMDD-HHMMSS-<hex> run_id shape; the
  # fallback must reject it rather than feeding garbage to compute-run-summary.
  echo "$OPS_RUNLOG_DIR/not-a-run-id.jsonl" > "$OPS_RUNLOG_DIR/latest.txt"
  run "$SCRIPTS_DIR/lockfile.sh" release
  [ "$status" -eq 0 ]
  [ ! -f "$OPS_BATCH_LOCK_PATH" ]
  [[ "$output" != *"no run_finished event"* ]]
}

@test "release still succeeds (lockfile removed) when compute-run-summary fails" {
  # compute-run-summary.sh exits non-zero when it can't find a session log
  # (exit 3). Fail-OPEN: lockfile removal must still happen, with a
  # diagnostic on stderr.
  "$SCRIPTS_DIR/lockfile.sh" acquire
  seed_runlog_without_run_finished >/dev/null
  # No session log exists in the test tmpdir, so compute-run-summary will
  # bail out with exit 3.

  run "$SCRIPTS_DIR/lockfile.sh" release
  [ "$status" -eq 0 ]
  [ ! -f "$OPS_BATCH_LOCK_PATH" ]
}

@test "acquire fails with exit 2 when OPS_BATCH_LOCK_PATH is unset" {
  unset OPS_BATCH_LOCK_PATH
  run "$SCRIPTS_DIR/lockfile.sh" acquire
  [ "$status" -eq 2 ]
}

@test "acquire records explicit caller PID when passed as arg" {
  # The helper script's $$ dies the moment it returns. Caller passes its own
  # $$ so the lock records a long-lived PID that future kill -0 checks against.
  run "$SCRIPTS_DIR/lockfile.sh" acquire 12345
  [ "$status" -eq 0 ]
  grep -q "^12345:" "$OPS_BATCH_LOCK_PATH"
}

@test "acquire rejects non-numeric caller PID with exit 2" {
  run "$SCRIPTS_DIR/lockfile.sh" acquire not-a-pid
  [ "$status" -eq 2 ]
}

@test "acquire steals lock when lockfile is malformed (no parseable PID)" {
  mkdir -p "$(dirname "$OPS_BATCH_LOCK_PATH")"
  echo "garbage with no colon" > "$OPS_BATCH_LOCK_PATH"
  run "$SCRIPTS_DIR/lockfile.sh" acquire 99999
  [ "$status" -eq 0 ]
  grep -q "^99999:" "$OPS_BATCH_LOCK_PATH"
}

# --- R4-3: renderer-missing forensic event on release -----------------------
#
# 2026-04-23 14:20 UTC regression: agent posted 15+ hand-composed Slack
# messages instead of the parent+thread from render-slack-summary.sh. R2-5's
# prose rule didn't prevent it; add mechanical detection at release so grep
# of recent runlogs surfaces the regression and (future R5) a monitor can
# alert on it.

seed_runlog_with_run_finished() {
  # args: approved_attempted verification_needed_attempted [fetched]
  # Sets up OPS_RUNLOG_DIR + latest.txt pointing at a runlog with a
  # run_finished event. Returns the run_id on stdout.
  local approved="$1" uvn="$2" fetched="${3:-500}"
  local day ts short run_id dir log
  day=$(date -u +%Y%m%d)
  ts=$(date -u +%H%M%S)
  short="abcdef"
  run_id="${day}-${ts}-${short}"
  dir="$OPS_RUNLOG_DIR/${day:0:4}-${day:4:2}-${day:6:2}"
  mkdir -p "$dir"
  log="$dir/${run_id}.jsonl"
  jq -n -c --arg rid "$run_id" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      --argjson f "$fetched" --argjson a "$approved" --argjson v "$uvn" \
      '{event:"run_header", run_id:$rid, ts:$ts, dryRun:true}' > "$log"
  jq -n -c --arg rid "$run_id" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      --argjson f "$fetched" --argjson a "$approved" --argjson v "$uvn" \
      '{event:"run_finished", run_id:$rid, ts:$ts,
        fetched:$f, approved:$a, verification_needed:$v,
        reconciliation:{approved_attempted:$a, verification_needed_attempted:$v}}' >> "$log"
  echo "$log" > "$OPS_RUNLOG_DIR/latest.txt"
  echo "$run_id"
}

seed_session_with_renderer_post() {
  # Create a session log containing a message(action=send) with the
  # canonical renderer header. R4-3 detection should treat this as a
  # proper render-slack-summary post and NOT emit the missing event.
  local sess="$TEST_TMPDIR/session.jsonl"
  jq -n -c '{message:{role:"assistant", content:[{type:"toolCall", id:"msg1", name:"message",
              arguments:{action:"send", channelId:"C0APB2CMM7C",
                         text:"[DRY RUN] Credit batch complete — 2026-04-23 14:20 UTC\nFetched: 500 | Approved: 250 | → verification_needed: 167\nRun ID: test"}}]}}' > "$sess"
  echo "$sess"
}

seed_session_with_freeform_posts() {
  # Agent posted hand-composed content — every text field fails the
  # canonical-header regex. R4-3 should emit the forensic event.
  local sess="$TEST_TMPDIR/session.jsonl"
  jq -n -c '{message:{role:"assistant", content:[{type:"toolCall", id:"m1", name:"message",
              arguments:{action:"send", text:"I have completed the batch analysis. Let me explain what happened..."}}]}}' > "$sess"
  jq -n -c '{message:{role:"assistant", content:[{type:"toolCall", id:"m2", name:"message",
              arguments:{action:"send", text:"Summary: 44 profiles classified, 5 to UVN..."}}]}}' >> "$sess"
  echo "$sess"
}

@test "R4-3: release emits run_finished_renderer_missing when no renderer post found" {
  "$SCRIPTS_DIR/lockfile.sh" acquire
  run_id=$(seed_runlog_with_run_finished 200 50)
  export CV_SESSION_LOG_OVERRIDE=$(seed_session_with_freeform_posts)

  run "$SCRIPTS_DIR/lockfile.sh" release
  [ "$status" -eq 0 ]
  [ ! -f "$OPS_BATCH_LOCK_PATH" ]
  # stderr (merged into $output) notes the detection.
  [[ "$output" == *"run_finished_renderer_missing"* ]]
  # Event lands in the runlog.
  local day="${run_id:0:8}"
  local logfile="$OPS_RUNLOG_DIR/${day:0:4}-${day:4:2}-${day:6:2}/${run_id}.jsonl"
  jq -e 'select(.event == "run_finished_renderer_missing")' < "$logfile"
  jq -e 'select(.event == "run_finished_renderer_missing") | .approved_attempted == 200' < "$logfile"
  jq -e 'select(.event == "run_finished_renderer_missing") | .verification_needed_attempted == 50' < "$logfile"
}

@test "R4-3: release does NOT emit event when renderer post is present" {
  "$SCRIPTS_DIR/lockfile.sh" acquire
  run_id=$(seed_runlog_with_run_finished 200 50)
  export CV_SESSION_LOG_OVERRIDE=$(seed_session_with_renderer_post)

  run "$SCRIPTS_DIR/lockfile.sh" release
  [ "$status" -eq 0 ]
  local day="${run_id:0:8}"
  local logfile="$OPS_RUNLOG_DIR/${day:0:4}-${day:4:2}-${day:6:2}/${run_id}.jsonl"
  run jq -e 'select(.event == "run_finished_renderer_missing")' < "$logfile"
  [ "$status" -ne 0 ]  # jq -e exits non-zero when no match
}

@test "R4-3: release does NOT emit event when attempts == 0 (nothing to summarise)" {
  # Hollow batch: preflight ok but no credits processed. The B5 queue-clear
  # message is legitimate; renderer output isn't required. Don't noise the
  # runlog with false positives.
  "$SCRIPTS_DIR/lockfile.sh" acquire
  run_id=$(seed_runlog_with_run_finished 0 0)
  export CV_SESSION_LOG_OVERRIDE=$(seed_session_with_freeform_posts)

  run "$SCRIPTS_DIR/lockfile.sh" release
  [ "$status" -eq 0 ]
  local day="${run_id:0:8}"
  local logfile="$OPS_RUNLOG_DIR/${day:0:4}-${day:4:2}-${day:6:2}/${run_id}.jsonl"
  run jq -e 'select(.event == "run_finished_renderer_missing")' < "$logfile"
  [ "$status" -ne 0 ]
}

@test "R4-3: release does NOT emit event when runlog has no run_finished (autofill path)" {
  # Pre-fallback: if compute-run-summary didn't even produce a run_finished
  # event, the release is already abnormal and the autofill stderr is
  # enough signal. Don't stack two events for the same pathology.
  "$SCRIPTS_DIR/lockfile.sh" acquire
  local day=$(date -u +%Y%m%d) ts=$(date -u +%H%M%S) short="123abc"
  local run_id="${day}-${ts}-${short}"
  local dir="$OPS_RUNLOG_DIR/${day:0:4}-${day:4:2}-${day:6:2}"
  mkdir -p "$dir"
  local logfile="$dir/${run_id}.jsonl"
  jq -n -c --arg rid "$run_id" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      '{event:"run_header", run_id:$rid, ts:$ts, dryRun:true}' > "$logfile"
  echo "$logfile" > "$OPS_RUNLOG_DIR/latest.txt"
  export CV_SESSION_LOG_OVERRIDE=$(seed_session_with_freeform_posts)

  run "$SCRIPTS_DIR/lockfile.sh" release
  [ "$status" -eq 0 ]
  # No renderer_missing event should be written (no run_finished precondition).
  run jq -e 'select(.event == "run_finished_renderer_missing")' < "$logfile"
  [ "$status" -ne 0 ]
}

@test "R4-3: release is idempotent — second release does not double-emit" {
  "$SCRIPTS_DIR/lockfile.sh" acquire
  run_id=$(seed_runlog_with_run_finished 200 50)
  export CV_SESSION_LOG_OVERRIDE=$(seed_session_with_freeform_posts)

  # First release emits the event.
  "$SCRIPTS_DIR/lockfile.sh" release
  # Re-acquire and release again — event must not be written twice.
  "$SCRIPTS_DIR/lockfile.sh" acquire
  "$SCRIPTS_DIR/lockfile.sh" release

  local day="${run_id:0:8}"
  local logfile="$OPS_RUNLOG_DIR/${day:0:4}-${day:4:2}-${day:6:2}/${run_id}.jsonl"
  local count
  count=$(grep -c '"event":"run_finished_renderer_missing"' "$logfile" || echo 0)
  [ "$count" -eq 1 ]
}

@test "R4-3: event detection handles run_finished_silent_failure as the finishing event too" {
  # When R1's silent-failure invariant fires, compute-run-summary writes
  # run_finished AND run_finished_silent_failure. The missing-renderer
  # check must still evaluate the attempts from run_finished and emit if
  # no renderer post was found.
  "$SCRIPTS_DIR/lockfile.sh" acquire
  run_id=$(seed_runlog_with_run_finished 100 0)
  # Append an additional silent-failure event.
  local day="${run_id:0:8}"
  local logfile="$OPS_RUNLOG_DIR/${day:0:4}-${day:4:2}-${day:6:2}/${run_id}.jsonl"
  jq -n -c --arg rid "$run_id" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      '{event:"run_finished_silent_failure", run_id:$rid, ts:$ts}' >> "$logfile"
  export CV_SESSION_LOG_OVERRIDE=$(seed_session_with_freeform_posts)

  run "$SCRIPTS_DIR/lockfile.sh" release
  [ "$status" -eq 0 ]
  jq -e 'select(.event == "run_finished_renderer_missing")' < "$logfile"
}
