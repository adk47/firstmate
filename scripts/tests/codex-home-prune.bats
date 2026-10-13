#!/usr/bin/env bats
# Tests for scripts/codex-home-prune.sh — ages out codex-home rollout jsonl
# files and logs_*.sqlite rows. Hermetic: fake codex-home under BATS_TEST_TMPDIR,
# a fake `df` on PATH, no network, nothing under /root is touched.
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
PRUNE="$HYDRA_REPO/scripts/codex-home-prune.sh"

# Portable "N days ago" touch -t stamp (GNU date vs BSD date).
_chp_stamp() {
  date -d "$1 days ago" +%Y%m%d%H%M.%S 2>/dev/null || date -v-"$1"d +%Y%m%d%H%M.%S
}

_chp_rollout() { # <file> <days-old> [bytes]
  mkdir -p "$(dirname "$1")"
  head -c "${3:-1000}" /dev/zero | tr '\0' 'x' > "$1"
  touch -t "$(_chp_stamp "$2")" "$1"
}

_chp_db() { # <db> : 3 old + 2 new rows, big bodies so VACUUM visibly shrinks the file
  local db="$1" now old new
  now="$(date +%s)"; old=$((now - 30 * 86400)); new=$((now - 86400))
  sqlite3 "$db" "PRAGMA journal_mode=WAL;
    CREATE TABLE logs(id INTEGER PRIMARY KEY, ts INTEGER, ts_nanos INTEGER, level TEXT,
      target TEXT, feedback_log_body TEXT, estimated_bytes INTEGER);" >/dev/null
  local i
  for i in 1 2 3; do
    sqlite3 "$db" "INSERT INTO logs(ts,ts_nanos,level,target,feedback_log_body,estimated_bytes)
      VALUES($old,0,'INFO','t','SECRET-TOKEN-old'||hex(zeroblob(100000)),200000);"
  done
  for i in 1 2; do
    sqlite3 "$db" "INSERT INTO logs(ts,ts_nanos,level,target,feedback_log_body,estimated_bytes)
      VALUES($new,0,'INFO','t','SECRET-TOKEN-new',16);"
  done
  sqlite3 "$db" "PRAGMA wal_checkpoint(TRUNCATE);" >/dev/null
}

_chp_fake_df() { # <used-pct> [blocks-kb, default 1000000]
  mkdir -p "$TEST_TMPDIR/bin"
  cat > "$TEST_TMPDIR/bin/df" <<DF
#!/bin/sh
echo "Filesystem 1024-blocks Used Available Capacity Mounted on"
echo "/dev/fake ${2:-1000000} $(( ${2:-1000000} * $1 / 100 )) $(( ${2:-1000000} * (100 - $1) / 100 )) $1% /"
DF
  chmod +x "$TEST_TMPDIR/bin/df"
}

setup() {
  TEST_TMPDIR="$(mktemp -d)"
  export TEST_TMPDIR
  export CODEX_HOME_GLOB="$TEST_TMPDIR/.openclaw-main/agents/*/agent/codex-home"
  CH="$TEST_TMPDIR/.openclaw-main/agents/qa/agent/codex-home"
  mkdir -p "$CH/sessions/2026/09"
  unset CODEX_SESSION_TTL_DAYS CODEX_VACUUM_MAX_USED_PCT
  export CODEX_PRUNE_BUSY_MS=200
  _chp_fake_df 50
  export PATH="$TEST_TMPDIR/bin:$PATH"
}

teardown() { rm -rf "$TEST_TMPDIR"; }

@test "apply: old rollout jsonl deleted, new kept" {
  _chp_rollout "$CH/sessions/2026/09/rollout-old.jsonl" 20
  _chp_rollout "$CH/sessions/2026/09/rollout-new.jsonl" 2
  run "$PRUNE" --apply
  [ "$status" -eq 0 ]
  [ ! -e "$CH/sessions/2026/09/rollout-old.jsonl" ]
  [ -e "$CH/sessions/2026/09/rollout-new.jsonl" ]
}

@test "apply: only rollout-*.jsonl is touched, however old" {
  _chp_rollout "$CH/sessions/notes.txt" 90
  run "$PRUNE" --apply
  [ "$status" -eq 0 ]
  [ -e "$CH/sessions/notes.txt" ]
}

@test "TTL is configurable: a 10-day-old file goes at TTL=7, stays at the default 14" {
  _chp_rollout "$CH/sessions/rollout-ten.jsonl" 10
  run "$PRUNE" --apply
  [ -e "$CH/sessions/rollout-ten.jsonl" ]
  CODEX_SESSION_TTL_DAYS=7 run "$PRUNE" --apply
  [ ! -e "$CH/sessions/rollout-ten.jsonl" ]
}

@test "apply: rows older than the cutoff are gone, newer rows intact" {
  _chp_db "$CH/logs_2.sqlite"
  run "$PRUNE" --apply
  [ "$status" -eq 0 ]
  [ "$(sqlite3 "$CH/logs_2.sqlite" 'select count(*) from logs where ts < strftime("%s","now")-14*86400')" -eq 0 ]
  [ "$(sqlite3 "$CH/logs_2.sqlite" 'select count(*) from logs')" -eq 2 ]
}

@test "VACUUM is skipped (with a logged reason) when df reports >= 80% used" {
  _chp_db "$CH/logs_2.sqlite"
  _chp_fake_df 85
  before="$(wc -c < "$CH/logs_2.sqlite")"
  run "$PRUNE" --apply
  [ "$status" -eq 0 ]
  [[ "$output" == *"VACUUM skipped"* ]]
  [ "$(wc -c < "$CH/logs_2.sqlite")" -eq "$before" ]
}

@test "VACUUM is skipped when pct is under 80 but free bytes are below 2x the DB size" {
  _chp_db "$CH/logs_2.sqlite"
  _chp_fake_df 79 1000   # 1000 KB fs, 21% free = 210 KB, far under 2x the DB
  before="$(wc -c < "$CH/logs_2.sqlite")"
  run "$PRUNE" --apply
  [ "$status" -eq 0 ]
  [[ "$output" == *"VACUUM skipped"*"2x DB size"* ]]
  [ "$(wc -c < "$CH/logs_2.sqlite")" -eq "$before" ]
}

@test "a non-numeric df Available column skips VACUUM but still visits every home" {
  CH2="$TEST_TMPDIR/.openclaw-main/agents/zz/agent/codex-home"
  mkdir -p "$CH2/sessions"
  _chp_db "$CH/logs_2.sqlite"
  _chp_db "$CH2/logs_2.sqlite"
  cat > "$TEST_TMPDIR/bin/df" <<'DF'
#!/bin/sh
echo "Filesystem 1024-blocks Used Available Capacity Mounted on"
echo "/dev/fake 100 1 - 1% /"
DF
  chmod +x "$TEST_TMPDIR/bin/df"
  before="$(wc -c < "$CH/logs_2.sqlite")"
  run "$PRUNE" --apply
  [ "$status" -eq 0 ]
  [[ "$output" == *"VACUUM skipped"* ]]
  [[ "$output" != *"arithmetic"* ]]
  [[ "$output" == *"/qa sessions_files="* ]]
  [[ "$output" == *"/zz sessions_files="* ]]
  [ "$(wc -c < "$CH/logs_2.sqlite")" -eq "$before" ]
}

@test "VACUUM runs when df reports below 80% used" {
  _chp_db "$CH/logs_2.sqlite"
  _chp_fake_df 79
  before="$(wc -c < "$CH/logs_2.sqlite")"
  run "$PRUNE" --apply
  [ "$status" -eq 0 ]
  [[ "$output" != *"VACUUM skipped"* ]]
  [ "$(wc -c < "$CH/logs_2.sqlite")" -lt "$before" ]
}

@test "dry-run is the default: deletes nothing, reports a non-zero would-free total per agent" {
  _chp_rollout "$CH/sessions/rollout-old.jsonl" 20 5000
  _chp_db "$CH/logs_2.sqlite"
  before="$(sqlite3 "$CH/logs_2.sqlite" 'select count(*) from logs')"
  run "$PRUNE"
  [ "$status" -eq 0 ]
  [ -e "$CH/sessions/rollout-old.jsonl" ]
  [ "$(sqlite3 "$CH/logs_2.sqlite" 'select count(*) from logs')" -eq "$before" ]
  [[ "$output" == *"dry-run"* ]]
  [[ "$output" == *"agent=.openclaw-main/qa"* ]]
  [[ "$output" =~ would_free_bytes=([0-9]+) ]]
  [ "${BASH_REMATCH[1]}" -gt 5000 ]
}

@test "explicit --dry-run behaves like the default" {
  _chp_rollout "$CH/sessions/rollout-old.jsonl" 20
  run "$PRUNE" --dry-run
  [ "$status" -eq 0 ]
  [ -e "$CH/sessions/rollout-old.jsonl" ]
}

@test "never prints row contents (the logs hold a live token)" {
  _chp_db "$CH/logs_2.sqlite"
  run "$PRUNE" --apply
  [[ "$output" != *"SECRET-TOKEN"* ]]
  run "$PRUNE"
  [[ "$output" != *"SECRET-TOKEN"* ]]
}

@test "a non-lock checkpoint failure is a failure, not a benign locked skip" {
  _chp_db "$CH/logs_2.sqlite"
  real="$(command -v sqlite3)"
  cat > "$TEST_TMPDIR/bin/sqlite3" <<SQ
#!/bin/sh
case "\$*" in *wal_checkpoint*) echo "Error: disk I/O error"; exit 1 ;; esac
exec "$real" "\$@"
SQ
  chmod +x "$TEST_TMPDIR/bin/sqlite3"
  run "$PRUNE" --apply
  [ "$status" -eq 1 ]
  [[ "$output" == *"checkpoint failed"* ]]
  [[ "$output" != *"locked by codex"* ]]
}

@test "a DB locked by codex is a logged skip with exit 0, rows untouched" {
  _chp_db "$CH/logs_2.sqlite"
  _chp_rollout "$CH/sessions/rollout-old.jsonl" 20
  ( printf 'BEGIN IMMEDIATE;\n'; sleep 6 ) | sqlite3 "$CH/logs_2.sqlite" >/dev/null 2>&1 &
  holder=$!
  sleep 1
  run "$PRUNE" --apply
  kill "$holder" 2>/dev/null || true
  [ "$status" -eq 0 ]
  [[ "$output" == *"locked"* ]]
  [ "$(sqlite3 "$CH/logs_2.sqlite" 'select count(*) from logs')" -eq 5 ]
  # the file side still ran
  [ ! -e "$CH/sessions/rollout-old.jsonl" ]
}

@test "bad TTL is refused with exit 5" {
  CODEX_SESSION_TTL_DAYS=0 run "$PRUNE"
  [ "$status" -eq 5 ]
  CODEX_SESSION_TTL_DAYS=abc run "$PRUNE"
  [ "$status" -eq 5 ]
}

@test "unknown argument is refused with exit 2" {
  run "$PRUNE" --yolo
  [ "$status" -eq 2 ]
}

@test "no codex-home dirs matched is a clean no-op" {
  CODEX_HOME_GLOB="$TEST_TMPDIR/nothing/*/codex-home" run "$PRUNE" --apply
  [ "$status" -eq 0 ]
}

@test "idle DB with no -wal/-shm sidecars is still pruned (Linux clean close)" {
  _chp_db "$CH/logs_2.sqlite"
  rm -f "$CH/logs_2.sqlite-wal" "$CH/logs_2.sqlite-shm"
  run "$PRUNE" --apply
  [ "$status" -eq 0 ]
  [[ "$output" != *"unreadable"* ]]
  [ "$(sqlite3 "$CH/logs_2.sqlite" 'select count(*) from logs')" -eq 2 ]
}

@test "dry-run on an idle DB with no sidecars still counts the would-free rows" {
  _chp_db "$CH/logs_2.sqlite"
  rm -f "$CH/logs_2.sqlite-wal" "$CH/logs_2.sqlite-shm"
  run "$PRUNE" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" != *"unreadable"* ]]
  [[ "$output" == *"log_rows=3"* ]]
}

@test "one failed rm does not starve the next agent" {
  [ "$(id -u)" -ne 0 ] || skip "root ignores directory permissions"
  CH2="$TEST_TMPDIR/.openclaw-main/agents/zz/agent/codex-home"
  _chp_rollout "$CH/sessions/ro/rollout-1.jsonl" 20
  _chp_rollout "$CH2/sessions/rollout-2.jsonl" 20
  chmod 555 "$CH/sessions/ro"
  run "$PRUNE" --apply
  chmod 755 "$CH/sessions/ro"
  [ "$status" -eq 1 ]
  [[ "$output" == *"rm failed"* ]]
  [[ "$output" == *"done."* ]]
  [ ! -e "$CH2/sessions/rollout-2.jsonl" ]
}

@test "the installer pages on failure of the prune unit" {
  grep -qx '  hydra-codex-home-prune.service' "$HYDRA_REPO/scripts/install-aux-units.sh"
}

@test "a sessions traversal error is a failure, not a silent clean run" {
  [ "$(id -u)" -ne 0 ] || skip "root ignores directory permissions"
  _chp_rollout "$CH/sessions/locked/rollout-1.jsonl" 20
  chmod 000 "$CH/sessions/locked"
  run "$PRUNE" --apply
  chmod 755 "$CH/sessions/locked"
  [ "$status" -eq 1 ]
  [[ "$output" == *"traversal failed"* ]]
  [[ "$output" == *"done."* ]]
}
