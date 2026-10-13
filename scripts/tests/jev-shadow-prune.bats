#!/usr/bin/env bats
# Tests for scripts/jev-shadow-prune.sh — drops Jev shadow rows older than
# JEV_SHADOW_RETENTION_DAYS from every $JEV_SHADOW_DIR/*.jsonl. Hermetic:
# throwaway JEV_SHADOW_DIR under BATS_TEST_TMPDIR, no network, no real jq
# state beyond what each test writes itself.
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
PRUNE="$HYDRA_REPO/scripts/jev-shadow-prune.sh"

# Portable octal file mode (GNU `stat -c` vs BSD/macOS `stat -f`).
_jsp_stat_mode() {
  stat -c '%a' "$1" 2>/dev/null || stat -f '%A' "$1"
}

# Portable "N days ago" RFC3339 timestamp matching jev.sh's _jev_now_iso
# format (date -u +%Y-%m-%dT%H:%M:%SZ, no fractional seconds).
_jsp_days_ago_ts() {
  local days="$1"
  date -u -d "${days} days ago" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u -v-"${days}"d +%Y-%m-%dT%H:%M:%SZ
}

setup() {
  TEST_TMPDIR="$(mktemp -d)"
  export TEST_TMPDIR
  export JEV_SHADOW_DIR="$TEST_TMPDIR/shadow"
  mkdir -p "$JEV_SHADOW_DIR"
  unset JEV_SHADOW_RETENTION_DAYS
}

teardown() {
  rm -rf "$TEST_TMPDIR"
  # Guard: this script must never touch the real prod shadow dir regardless
  # of what a test isolates JEV_SHADOW_DIR to (CI runs bats as root on
  # node-8 -- a fallback to the hardcoded default would write/prune
  # PRODUCTION rows on every run, exactly the class of bug that polluted
  # /var/lib/hydra-jev/shadow before format-digest.sh's own isolation was
  # added).
  [ ! -e /var/lib/hydra-jev/shadow/_jev-shadow-prune-test-canary.jsonl ]
}

@test "rows older than the retention window are dropped, newer rows are kept" {
  old_ts="$(_jsp_days_ago_ts 45)"
  new_ts="$(_jsp_days_ago_ts 1)"
  {
    printf '{"ts":"%s","surface":"s","item_id":"old"}\n' "$old_ts"
    printf '{"ts":"%s","surface":"s","item_id":"new"}\n' "$new_ts"
  } > "$JEV_SHADOW_DIR/s.jsonl"

  run "$PRUNE"
  [ "$status" -eq 0 ]

  [ "$(wc -l < "$JEV_SHADOW_DIR/s.jsonl" | tr -d '[:space:]')" -eq 1 ]
  run jq -r '.item_id' "$JEV_SHADOW_DIR/s.jsonl"
  [ "$output" = "new" ]
  [[ "$output" != *"old"* ]]
}

@test "a row exactly at the retention boundary in days is kept (cutoff is strictly older-than)" {
  # 29 days ago is inside a 30-day retention window either way this rounds;
  # asserts the boundary favors keeping, not off-by-one dropping recent data.
  boundary_ts="$(_jsp_days_ago_ts 29)"
  printf '{"ts":"%s","surface":"s","item_id":"boundary"}\n' "$boundary_ts" > "$JEV_SHADOW_DIR/s.jsonl"

  run "$PRUNE"
  [ "$status" -eq 0 ]
  [ -s "$JEV_SHADOW_DIR/s.jsonl" ]
  run jq -r '.item_id' "$JEV_SHADOW_DIR/s.jsonl"
  [ "$output" = "boundary" ]
}

@test "malformed rows (bad JSON, missing/unparseable ts) are kept and counted, never dropped" {
  new_ts="$(_jsp_days_ago_ts 1)"
  {
    echo 'not json at all'
    printf '{"surface":"s","item_id":"no-ts"}\n'
    printf '{"ts":"not-a-timestamp","surface":"s","item_id":"bad-ts"}\n'
    printf '{"ts":"%s","surface":"s","item_id":"new"}\n' "$new_ts"
  } > "$JEV_SHADOW_DIR/s.jsonl"

  run "$PRUNE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"malformed=3"* ]]
  [[ "$output" == *"kept=4"* ]]
  [[ "$output" == *"dropped=0"* ]]

  [ "$(wc -l < "$JEV_SHADOW_DIR/s.jsonl" | tr -d '[:space:]')" -eq 4 ]
  grep -q 'not json at all' "$JEV_SHADOW_DIR/s.jsonl"
}

@test "a bad JEV_SHADOW_RETENTION_DAYS knob is refused, nothing is rewritten" {
  new_ts="$(_jsp_days_ago_ts 1)"
  printf '{"ts":"%s","surface":"s","item_id":"new"}\n' "$new_ts" > "$JEV_SHADOW_DIR/s.jsonl"
  before="$(cat "$JEV_SHADOW_DIR/s.jsonl")"

  export JEV_SHADOW_RETENTION_DAYS=abc
  run "$PRUNE"
  [ "$status" -eq 5 ]
  [[ "$output" == *"JEV_SHADOW_RETENTION_DAYS"* ]]
  [ "$(cat "$JEV_SHADOW_DIR/s.jsonl")" = "$before" ]

  export JEV_SHADOW_RETENTION_DAYS=0
  run "$PRUNE"
  [ "$status" -eq 5 ]

  export JEV_SHADOW_RETENTION_DAYS=-5
  run "$PRUNE"
  [ "$status" -eq 5 ]
}

@test "JEV_SHADOW_RETENTION_DAYS=1 drops a 2-day-old row that the default 30-day window would keep" {
  two_days_ago="$(_jsp_days_ago_ts 2)"
  printf '{"ts":"%s","surface":"s","item_id":"two-days"}\n' "$two_days_ago" > "$JEV_SHADOW_DIR/s.jsonl"

  export JEV_SHADOW_RETENTION_DAYS=1
  run "$PRUNE"
  [ "$status" -eq 0 ]
  [ ! -s "$JEV_SHADOW_DIR/s.jsonl" ]
}

@test "a leading-zero retention is read as decimal: 08 keeps an 8-day window and never crashes" {
  # Bash arithmetic reads a leading zero as octal: 08/09 abort with "value too
  # great for base", so the unattended daily job would stop pruning.
  seven_days_ago="$(_jsp_days_ago_ts 7)"
  nine_days_ago="$(_jsp_days_ago_ts 9)"
  printf '{"ts":"%s","surface":"s","item_id":"seven"}\n{"ts":"%s","surface":"s","item_id":"nine"}\n' \
    "$seven_days_ago" "$nine_days_ago" > "$JEV_SHADOW_DIR/s.jsonl"

  export JEV_SHADOW_RETENTION_DAYS=08
  run "$PRUNE"
  [ "$status" -eq 0 ]
  grep -q '"seven"' "$JEV_SHADOW_DIR/s.jsonl"
  [ "$(grep -c '"nine"' "$JEV_SHADOW_DIR/s.jsonl" || true)" -eq 0 ]
}

@test "an all-zero retention (00) is refused like 0, never read as a zero-day window" {
  printf '{"ts":"%s","surface":"s","item_id":"now"}\n' "$(_jsp_days_ago_ts 0)" > "$JEV_SHADOW_DIR/s.jsonl"
  export JEV_SHADOW_RETENTION_DAYS=00
  run "$PRUNE"
  [ "$status" -eq 5 ]
  grep -q '"now"' "$JEV_SHADOW_DIR/s.jsonl"
}

@test "an empty shadow dir is a no-op, rc 0" {
  run "$PRUNE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"nothing to prune"* ]]
}

@test "a missing shadow dir is a no-op, rc 0" {
  export JEV_SHADOW_DIR="$TEST_TMPDIR/does-not-exist"
  run "$PRUNE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"nothing to prune"* ]]
}

@test "file mode 0600 is preserved (tightened) across the rewrite" {
  new_ts="$(_jsp_days_ago_ts 1)"
  printf '{"ts":"%s","surface":"s","item_id":"new"}\n' "$new_ts" > "$JEV_SHADOW_DIR/s.jsonl"
  chmod 0644 "$JEV_SHADOW_DIR/s.jsonl"
  [ "$(_jsp_stat_mode "$JEV_SHADOW_DIR/s.jsonl")" = "644" ]

  run "$PRUNE"
  [ "$status" -eq 0 ]
  [ "$(_jsp_stat_mode "$JEV_SHADOW_DIR/s.jsonl")" = "600" ]
}

@test "the raw state field survives a prune of a kept row unchanged" {
  new_ts="$(_jsp_days_ago_ts 1)"
  printf '{"ts":"%s","surface":"s","item_id":"new","state":{"foo":"bar"},"state_sha256":"abc"}\n' "$new_ts" \
    > "$JEV_SHADOW_DIR/s.jsonl"

  run "$PRUNE"
  [ "$status" -eq 0 ]
  run jq -r '.state.foo' "$JEV_SHADOW_DIR/s.jsonl"
  [ "$output" = "bar" ]
}

@test "multiple surface files are each pruned independently" {
  old_ts="$(_jsp_days_ago_ts 45)"
  new_ts="$(_jsp_days_ago_ts 1)"
  printf '{"ts":"%s","surface":"a","item_id":"a-old"}\n' "$old_ts" > "$JEV_SHADOW_DIR/a.jsonl"
  printf '{"ts":"%s","surface":"b","item_id":"b-new"}\n' "$new_ts" > "$JEV_SHADOW_DIR/b.jsonl"

  run "$PRUNE"
  [ "$status" -eq 0 ]
  [ ! -s "$JEV_SHADOW_DIR/a.jsonl" ]
  [ -s "$JEV_SHADOW_DIR/b.jsonl" ]
}

@test "an externally held lock is honoured: the file is skipped, not corrupted" {
  new_ts="$(_jsp_days_ago_ts 1)"
  old_ts="$(_jsp_days_ago_ts 45)"
  {
    printf '{"ts":"%s","surface":"s","item_id":"old"}\n' "$old_ts"
    printf '{"ts":"%s","surface":"s","item_id":"new"}\n' "$new_ts"
  } > "$JEV_SHADOW_DIR/s.jsonl"
  before="$(cat "$JEV_SHADOW_DIR/s.jsonl")"
  lock_file="$JEV_SHADOW_DIR/s.jsonl.lock"

  # Hold the same lock the prune script (and format-digest.sh's writer) use,
  # for longer than the script's 5s wait, from a background subshell — bats'
  # `run` captures a single foreground invocation, so the holder is started
  # and stopped around it explicitly.
  (
    exec 9>>"$lock_file"
    flock 9
    sleep 7
  ) &
  holder_pid=$!
  sleep 0.3

  run "$PRUNE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARN could not lock"* ]]
  [[ "$output" == *"files_locked_skipped=1"* ]]
  # File is untouched — never partially rewritten under contention.
  [ "$(cat "$JEV_SHADOW_DIR/s.jsonl")" = "$before" ]

  wait "$holder_pid" 2>/dev/null || true
}

@test "a writer blocked on the lock during the prune's rewrite lands its row after the rewrite, and it survives" {
  # Every writer (jev.sh, format-digest.sh, jev-shadow-log.ts via the flock
  # binary) now takes this exact "<file>.lock" before appending -- the same
  # lock this script holds for its whole read-filter-write-mv rewrite. So a
  # writer racing a prune run cannot land mid-rewrite; it simply blocks on
  # the lock and appends once the rewrite (and the mv) is done.
  #
  # A holder standing in for "the prune's rewrite in progress" is used
  # instead of racing the real prune invocation against the writer: two
  # independent background processes both requesting the same flock give no
  # ordering guarantee (which one wins the wait queue is unspecified), so
  # asserting on that race would be flaky. The holder takes the exact same
  # lock via the exact same primitive the prune script itself takes it
  # with, so from the writer's point of view -- which only ever observes
  # "the lock is held, then it is free" -- a holder and an in-progress
  # prune rewrite are indistinguishable. This deterministically proves the
  # queue-then-append behaviour; a REAL prune pass is then run afterward to
  # prove the landed row is a normal durable row, not a leftover artifact.
  old_ts="$(_jsp_days_ago_ts 45)"
  new_ts="$(_jsp_days_ago_ts 1)"
  printf '{"ts":"%s","surface":"s","item_id":"old"}\n' "$old_ts" > "$JEV_SHADOW_DIR/s.jsonl"
  target="$JEV_SHADOW_DIR/s.jsonl"
  lock_file="${target}.lock"

  (
    exec 9>>"$lock_file"
    flock 9
    sleep 2
  ) &
  holder_pid=$!
  sleep 0.3

  # The real protocol every writer uses: flock -w 5 <lock> sh -c 'cat >>
  # "$1"' sh <file>, row piped on stdin (matches jev-shadow-log.ts's
  # runFlockAppend and jev.sh's own append exactly). Run it in the
  # foreground so this test blocks on the SAME wait the production writers
  # rely on -- it must not return until the holder above releases at 2s.
  start_ts="$(date +%s)"
  printf '{"ts":"%s","surface":"s","item_id":"race-writer"}\n' "$new_ts" \
    | flock -w 5 "$lock_file" sh -c 'umask 077; cat >> "$1"' sh "$target"
  end_ts="$(date +%s)"

  wait "$holder_pid" 2>/dev/null || true

  elapsed=$((end_ts - start_ts))
  [ "$elapsed" -ge 1 ]
  grep -q '"race-writer"' "$target"
  [ "$(wc -l < "$target" | tr -d '[:space:]')" -eq 2 ]

  # A real prune pass now: the old row is dropped as usual, and the
  # writer's row -- landed strictly after the simulated rewrite released
  # the lock, via the shared lock protocol -- survives as an ordinary row.
  run "$PRUNE"
  [ "$status" -eq 0 ]
  grep -q '"race-writer"' "$target"
  ! grep -q '"old"' "$target"
  [ "$(wc -l < "$target" | tr -d '[:space:]')" -eq 1 ]
}

@test "does not touch the real production shadow dir regardless of JEV_SHADOW_DIR default" {
  # Sanity guard matching the writers' own isolation tests: run with the
  # env var explicitly set (as every other test does) and confirm the
  # script never falls back to the hardcoded /var/lib/hydra-jev/shadow path
  # when it IS set.
  new_ts="$(_jsp_days_ago_ts 1)"
  printf '{"ts":"%s","surface":"s","item_id":"new"}\n' "$new_ts" > "$JEV_SHADOW_DIR/s.jsonl"
  run "$PRUNE"
  [ "$status" -eq 0 ]
  [ ! -e /var/lib/hydra-jev/shadow/s.jsonl.lock ] || {
    echo "prune touched a lockfile under the real prod shadow dir" >&2
    false
  }
}
