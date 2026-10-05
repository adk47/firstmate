#!/usr/bin/env bash
# tests/fm-watch-scan-signals.test.sh - the watcher's per-poll signal scan.
#
# These are focused units for two liveness properties of scan_signals that a
# fleet-sized poll depends on:
#   - a beat refresh paced by elapsed time across scanned files, so a long scan
#     over many multi-megabyte status logs cannot let the watcher's liveness
#     beacon age past the guard's grace, while a fast scan does not fork a
#     beacon check for every file.
#   - a single signature computation per file: scan_signals already computes the
#     reported signature to detect a change, so it hands that value to
#     fm_wake_signal_seen_current instead of forking a second
#     status_observed_signature for every file on every poll.
#
# The suite also pins the heartbeat backstop's absorbed-run behavior: an
# absorbed heartbeat must advance each task's .hb-surfaced offset past the bytes
# it just inspected, so a routine-only log is not re-folded from its last
# actionable event on every heartbeat.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

WATCH="$ROOT/bin/fm-watch.sh"
LIB="$ROOT/bin/fm-wake-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-watch-scan-signals-tests)

test_signal_seen_current_reuses_a_supplied_signature() {
  local dir state status calls out
  dir=$(make_case reuse-signature)
  state="$dir/state"
  status="$state/sample.status"
  calls="$dir/sigcalls"
  printf 'working: hi\n' > "$status"
  : > "$calls"
  out=$(CALLFILE="$calls" FM_HOME="$dir" FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    fm_wake_signal_sig() { printf "x\n" >> "$CALLFILE"; printf "r1:stub"; }
    fm_wake_signal_seen_current "$2" "$3" "r1:supplied" || true
    printf "supplied=%s\n" "$(LC_ALL=C wc -l < "$CALLFILE" | tr -d "[:space:]")"
    fm_wake_signal_seen_current "$2" "$3" || true
    printf "omitted=%s\n" "$(LC_ALL=C wc -l < "$CALLFILE" | tr -d "[:space:]")"
  ' _ "$LIB" "$state" "$status")
  grep -qx 'supplied=0' <<<"$out" \
    || fail "a supplied signature was recomputed instead of reused: $out"
  grep -qx 'omitted=1' <<<"$out" \
    || fail "an omitted signature was not computed exactly once: $out"
  pass "signal scan: a supplied reported signature is reused, not recomputed"
}

scan_signal_counts() {  # <dir> <seconds-each-beacon-check-takes>
  local dir=$1 step=$2 state
  state="$dir/state"
  printf 'working: a\n' > "$state/one.status"
  printf 'working: b\n' > "$state/two.status"
  : > "$state/three.turn-ended"
  : > "$dir/sigcalls"
  : > "$dir/beatcalls"
  SIGCALLFILE="$dir/sigcalls" BEATCALLFILE="$dir/beatcalls" STEP="$step" FM_HOME="$dir" FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    fm_wake_signal_sig() { printf "x\n" >> "$SIGCALLFILE"; printf "sig:%s" "${1##*/}"; }
    watch_beat() { printf "x\n" >> "$BEATCALLFILE"; SECONDS=$((SECONDS + STEP)); }
    SECONDS=100
    scan_signals >/dev/null
    printf "sigcalls=%s beatcalls=%s\n" \
      "$(LC_ALL=C wc -l < "$SIGCALLFILE" | tr -d "[:space:]")" \
      "$(LC_ALL=C wc -l < "$BEATCALLFILE" | tr -d "[:space:]")"
  ' _ "$WATCH"
}

test_scan_signals_paces_beacon_refresh_by_elapsed_time() {
  local out
  out=$(scan_signal_counts "$(make_case scan-signals-fast)" 0)
  grep -qx 'sigcalls=3 beatcalls=1' <<<"$out" \
    || fail "a fast scan should compute one signature per file and check the beacon once: $out"
  out=$(scan_signal_counts "$(make_case scan-signals-slow)" 2)
  grep -qx 'sigcalls=3 beatcalls=3' <<<"$out" \
    || fail "a slow scan should check the beacon as each second passes: $out"
  pass "signal scan: one signature per file and a time-paced beacon refresh"
}

test_absorbed_heartbeat_advances_surfaced_offset() {
  local dir state out status
  dir=$(make_case absorbed-heartbeat)
  state="$dir/state"
  status="$state/heartbeat-task.status"
  printf 'working: routine only\n' > "$status"
  out=$(FM_HOME="$dir" FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    heartbeat_scan_finds_actionable
    rc=$?
    mark_all_captain_relevant_surfaced
    off=$(hb_surfaced_offset heartbeat-task)
    size=$(_fm_status_file_size "$2")
    printf "rc=%s off=%s size=%s\n" "$rc" "$off" "$size"
  ' _ "$WATCH" "$status")
  size=$(LC_ALL=C wc -c < "$status" | tr -d '[:space:]')
  grep -qx "rc=1 off=${size} size=${size}" <<<"$out" \
    || fail "an absorbed heartbeat did not advance the surfaced offset to the inspected end: $out"
  pass "heartbeat backstop: an absorbed scan advances the surfaced offset"
}

test_signal_seen_current_reuses_a_supplied_signature
test_scan_signals_paces_beacon_refresh_by_elapsed_time
test_absorbed_heartbeat_advances_surfaced_offset
