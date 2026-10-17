#!/usr/bin/env bash
# tests/fm-wake-drain-fleet-cost.test.sh - the wake drain's status sections
# must not pay a process per status log per section. The incident this pins: a
# 135-log home spent five minutes per drain, almost all of it kernel time,
# because every section re-ran `stat` (and `cat`, `dirname`, `basename`) for
# every log, so session start timed out in its wake-queue stage. The real drain
# runs over crafted logs with a counting `stat` shim on PATH; the per-pass stat
# cache in fm-classify-lib.sh is also exercised directly so its answers stay
# byte-identical to the per-call readers it stands in for.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

DRAIN="$ROOT/bin/fm-wake-drain.sh"

TMP_ROOT=$(fm_test_tmproot fm-wake-drain-fleet-cost-tests)

# A PATH directory whose `stat` counts its own invocations, then runs the real
# one. The drain itself is the only caller under that PATH.
make_counting_stat() {  # <dir> <counter-file>
  local dir=$1 counter=$2 real
  real=$(command -v stat)
  mkdir -p "$dir"
  cat > "$dir/stat" <<SH
#!/bin/sh
printf 'x\n' >> "$counter"
exec "$real" "\$@"
SH
  chmod +x "$dir/stat"
}

test_drain_stat_calls_do_not_scale_with_status_logs() {
  local dir state out counter fakebin n=40 i calls
  dir=$(make_case fleet-stat-cost)
  state="$dir/state"
  out="$dir/drain.out"
  counter="$dir/stat.count"
  fakebin="$dir/fakebin"
  i=1
  while [ "$i" -le "$n" ]; do
    printf 'working: lane %s started\n' "$i" > "$state/lane$i.status"
    i=$((i + 1))
  done
  # Prime every presentation cursor so the counted drain reads a fleet of
  # established logs, each with one fresh line, like a long-lived home.
  FM_STATE_OVERRIDE="$state" "$DRAIN" > /dev/null 2>&1 || fail "priming drain failed"
  i=1
  while [ "$i" -le "$n" ]; do
    printf 'note: lane %s answered\n' "$i" >> "$state/lane$i.status"
    i=$((i + 1))
  done
  make_counting_stat "$fakebin" "$counter"
  : > "$counter"
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" 2>&1 \
    || fail "counted drain failed: $(cat "$out")"
  grep -F 'lane17 note: lane 17 answered' "$out" >/dev/null \
    || fail "the counted drain did not surface the unread note: $(cat "$out")"
  calls=$(grep -c . "$counter")
  # Before the per-pass cache this was several stat processes per log (one per
  # section question); now the status sections cost a batched stat per pass.
  [ "$calls" -lt "$n" ] \
    || fail "drain ran $calls stat processes over $n status logs; per-log stat forks are back"
  pass "a drain over $n status logs runs $calls stat processes, not one per log per section"
}

test_stat_cache_matches_per_call_readers() {
  local dir state f got want
  dir=$(make_case stat-cache-parity)
  state="$dir/state"
  printf 'working: plain\n' > "$state/plain.status"
  printf 'working: a name with spaces\n' > "$state/with space.status"
  : > "$state/empty.status"
  (
    # shellcheck source=bin/fm-classify-lib.sh
    . "$ROOT/bin/fm-classify-lib.sh"
    for f in "$state"/*.status; do
      want="$(_fm_status_file_size "$f")|$(_fm_status_file_mtime "$f")|$(_fm_open_decisions_file_ident "$f")"
      fm_status_stat_cache_load "$state"
      got="$(_fm_status_file_size "$f")|$(_fm_status_file_mtime "$f")|$(_fm_open_decisions_file_ident "$f")"
      [ "$got" = "$want" ] || { printf 'mismatch for %s: %s != %s\n' "$f" "$got" "$want"; exit 1; }
      _fm_status_size_into "$f" got
      [ "$got" = "${want%%|*}" ] || { printf 'size_into mismatch for %s\n' "$f"; exit 1; }
      fm_status_stat_cache_clear
    done
  ) || fail "the per-pass stat cache disagreed with the per-call readers"
  pass "the per-pass stat cache answers exactly what the per-call readers answer"
}

test_stat_cache_is_a_snapshot_until_reloaded() {
  local dir state f
  dir=$(make_case stat-cache-snapshot)
  state="$dir/state"
  f="$state/lane.status"
  printf 'working: first\n' > "$f"
  (
    # shellcheck source=bin/fm-classify-lib.sh
    . "$ROOT/bin/fm-classify-lib.sh"
    fm_status_stat_cache_load "$state"
    [ "$FM_STATUS_STAT_CACHE_LOADED" = 1 ] || { echo "a cache-capable bash did not load the cache"; exit 1; }
    before=$(_fm_status_file_size "$f")
    before_ident=$(_fm_open_decisions_file_ident "$f")
    printf 'working: appended\n' >> "$f"
    [ "$(_fm_status_file_size "$f")" = "$before" ] || { echo "a loaded pass changed its answer without a reload"; exit 1; }
    # A replaced log (new inode) must read as a different identity once the
    # caller reloads, which is what the drain's commit-time reload relies on.
    mv "$f" "$f.old"
    printf 'working: replacement\n' > "$f"
    fm_status_stat_cache_load "$state"
    [ "$(_fm_status_file_size "$f")" != "$before" ] || { echo "a reload did not see the new size"; exit 1; }
    [ "$(_fm_open_decisions_file_ident "$f")" != "$before_ident" ] \
      || { echo "a reload did not see the replaced identity"; exit 1; }
    fm_status_stat_cache_clear
    [ "$FM_STATUS_STAT_CACHE_LOADED" = 0 ] || { echo "clear left the cache loaded"; exit 1; }
    # A path outside the loaded pass keeps its per-call read.
    fm_status_stat_cache_load "$state"
    printf 'working: late\n' > "$state/late.status"
    [ "$(_fm_status_file_size "$state/late.status")" = 14 ] || { echo "an uncached path did not fall back"; exit 1; }
  ) || fail "the per-pass stat cache snapshot contract broke"
  pass "the per-pass stat cache is a snapshot until reloaded, and falls back for unknown paths"
}

test_drain_stat_calls_do_not_scale_with_status_logs
test_stat_cache_matches_per_call_readers
test_stat_cache_is_a_snapshot_until_reloaded
