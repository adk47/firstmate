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
  # 3h30m stale threshold. NOTE: no -u on the date call; touch -t interprets
  # its arg as local time and stat returns epoch seconds, so matching local
  # on both sides keeps the age arithmetic honest.
  touch -t "$(date -v-4H +%Y%m%d%H%M)" "$OPS_BATCH_LOCK_PATH" 2>/dev/null || \
    touch -d "4 hours ago" "$OPS_BATCH_LOCK_PATH"
  run "$SCRIPTS_DIR/lockfile.sh" acquire
  [ "$status" -eq 0 ]
}

@test "acquire honors live lock whose mtime is fresher than 3h30m" {
  mkdir -p "$(dirname "$OPS_BATCH_LOCK_PATH")"
  echo "$$:test-host:operations-dev" > "$OPS_BATCH_LOCK_PATH"
  # Backdate to 3 hours ago — below the 3h30m stale threshold. Live PID + fresh
  # mtime must refuse to steal (exit 10). Guards against regression if
  # STALE_SECONDS is ever tightened further.
  touch -t "$(date -v-3H +%Y%m%d%H%M)" "$OPS_BATCH_LOCK_PATH" 2>/dev/null || \
    touch -d "3 hours ago" "$OPS_BATCH_LOCK_PATH"
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

@test "release invokes compute-run-summary.sh when runlog lacks run_finished" {
  "$SCRIPTS_DIR/lockfile.sh" acquire
  seed_runlog_without_run_finished >/dev/null

  run "$SCRIPTS_DIR/lockfile.sh" release
  # Fail-OPEN: release always succeeds; lockfile is always removed.
  [ "$status" -eq 0 ]
  [ ! -f "$OPS_BATCH_LOCK_PATH" ]
  # But the fallback-invocation marker must be on stderr (merged into $output
  # by bats `run`), proving compute-run-summary was attempted.
  [[ "$output" == *"no run_finished event"* ]]
  [[ "$output" == *"compute-run-summary.sh"* ]]
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
