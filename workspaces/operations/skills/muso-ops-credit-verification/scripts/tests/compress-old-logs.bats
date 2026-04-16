#!/usr/bin/env bats
load helpers

setup() {
  setup_tmp_env
  export OPS_RUNLOG_DIR="$TEST_TMPDIR/credit-batch-runs"
  mkdir -p "$OPS_RUNLOG_DIR"
}
teardown() { teardown_tmp_env; }

@test "leaves directories younger than 30 days alone" {
  DIR="$OPS_RUNLOG_DIR/$(date -u -v-10d +%Y-%m-%d 2>/dev/null || date -u -d '10 days ago' +%Y-%m-%d)"
  mkdir -p "$DIR"
  echo '{}' > "$DIR/run.jsonl"
  run "$SCRIPTS_DIR/compress-old-logs.sh"
  [ "$status" -eq 0 ]
  [ -d "$DIR" ]
  [ ! -f "$DIR.tar.gz" ]
}

@test "compresses directories older than 30 days to tar.gz (never deletes originals)" {
  OLD=$(date -u -v-40d +%Y-%m-%d 2>/dev/null || date -u -d '40 days ago' +%Y-%m-%d)
  DIR="$OPS_RUNLOG_DIR/$OLD"
  mkdir -p "$DIR"
  echo '{"event":"run_started"}' > "$DIR/run-a.jsonl"
  echo '{"event":"run_finished"}' > "$DIR/run-b.jsonl"

  run "$SCRIPTS_DIR/compress-old-logs.sh"
  [ "$status" -eq 0 ]
  [ -f "$OPS_RUNLOG_DIR/$OLD.tar.gz" ]
  # Per audit policy: DO NOT DELETE. Original dir must still exist.
  [ -d "$DIR" ]
}

@test "mixed state: archives fresh-old day even when another old day is already archived" {
  # Day-40 already has its archive; day-35 is freshly old. Both should end up
  # archived after one run. Catches regressions where a `&&` chain or early
  # `continue` would let one day's existing archive short-circuit the loop.
  OLD_ARCHIVED=$(date -u -v-40d +%Y-%m-%d 2>/dev/null || date -u -d '40 days ago' +%Y-%m-%d)
  OLD_FRESH=$(date -u -v-35d +%Y-%m-%d 2>/dev/null || date -u -d '35 days ago' +%Y-%m-%d)
  mkdir -p "$OPS_RUNLOG_DIR/$OLD_ARCHIVED" "$OPS_RUNLOG_DIR/$OLD_FRESH"
  echo '{}' > "$OPS_RUNLOG_DIR/$OLD_ARCHIVED/r.jsonl"
  echo '{}' > "$OPS_RUNLOG_DIR/$OLD_FRESH/r.jsonl"
  # Pre-seed the older day's archive
  tar -czf "$OPS_RUNLOG_DIR/$OLD_ARCHIVED.tar.gz" -C "$OPS_RUNLOG_DIR" "$OLD_ARCHIVED"

  run "$SCRIPTS_DIR/compress-old-logs.sh"
  [ "$status" -eq 0 ]
  [ -f "$OPS_RUNLOG_DIR/$OLD_ARCHIVED.tar.gz" ]
  [ -f "$OPS_RUNLOG_DIR/$OLD_FRESH.tar.gz" ]
}

@test "tar failure cleans up partial archive and continues to next day" {
  # Day-A is on a path tar can't write (we make the archive parent unwritable
  # by making the archive itself a directory tar can't overwrite). Day-B
  # should still get archived after Day-A fails.
  OLD_A=$(date -u -v-40d +%Y-%m-%d 2>/dev/null || date -u -d '40 days ago' +%Y-%m-%d)
  OLD_B=$(date -u -v-35d +%Y-%m-%d 2>/dev/null || date -u -d '35 days ago' +%Y-%m-%d)
  mkdir -p "$OPS_RUNLOG_DIR/$OLD_A" "$OPS_RUNLOG_DIR/$OLD_B"
  echo '{}' > "$OPS_RUNLOG_DIR/$OLD_A/r.jsonl"
  echo '{}' > "$OPS_RUNLOG_DIR/$OLD_B/r.jsonl"
  # Force tar to fail on day A by making the source dir unreadable mid-archive
  chmod 000 "$OPS_RUNLOG_DIR/$OLD_A"

  run "$SCRIPTS_DIR/compress-old-logs.sh"

  # Restore perms so teardown can clean up
  chmod 755 "$OPS_RUNLOG_DIR/$OLD_A"

  # Script should have exited 0 (continue-on-error) and processed day B
  [ "$status" -eq 0 ]
  # No partial archive for the failed day
  [ ! -f "$OPS_RUNLOG_DIR/$OLD_A.tar.gz" ]
  # Day B was still archived
  [ -f "$OPS_RUNLOG_DIR/$OLD_B.tar.gz" ]
  # stderr mentions the failure
  [[ "$stderr" == *"failed to archive"* ]] || [[ "$output" == *"failed to archive"* ]]
}

@test "is idempotent: running twice does not re-archive" {
  OLD=$(date -u -v-40d +%Y-%m-%d 2>/dev/null || date -u -d '40 days ago' +%Y-%m-%d)
  DIR="$OPS_RUNLOG_DIR/$OLD"
  mkdir -p "$DIR"
  echo '{}' > "$DIR/run.jsonl"
  "$SCRIPTS_DIR/compress-old-logs.sh"
  FIRST_MTIME=$(stat -f %m "$OPS_RUNLOG_DIR/$OLD.tar.gz" 2>/dev/null || stat -c %Y "$OPS_RUNLOG_DIR/$OLD.tar.gz")
  sleep 1
  "$SCRIPTS_DIR/compress-old-logs.sh"
  SECOND_MTIME=$(stat -f %m "$OPS_RUNLOG_DIR/$OLD.tar.gz" 2>/dev/null || stat -c %Y "$OPS_RUNLOG_DIR/$OLD.tar.gz")
  [ "$FIRST_MTIME" = "$SECOND_MTIME" ]
}
