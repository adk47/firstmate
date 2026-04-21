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
