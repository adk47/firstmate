#!/usr/bin/env bash
# tests/fm-classify-fold-bounded.test.sh - bounded-cost proof for the
# cursor-backed open-decisions fold (bin/fm-classify-lib.sh's
# status_open_decisions_incremental).
#
# A long-lived monitoring lane legitimately produces a multi-megabyte
# append-only status log. The fold that derives its still-open decisions must
# therefore be bounded by the bytes appended since its last call, never by the
# log's total lifetime size - otherwise a per-poll or per-drain fold grows
# without bound and wedges supervision (the 2026-09 incident: a beacon that went
# stale for 729s while the fold was still grinding, and drains that took 11-14
# minutes).
#
# This test builds a synthetic ~5 MB log with 3,000 open and 3,000 resolved
# keyed transitions, runs the fold cold once, appends one small increment, and
# asserts the SECOND run reads exactly that increment and completes under a
# stated bound. It also bounds the cold run so a regression to per-line command
# substitution fails instead of hanging the suite. It drives the real public
# fold and its documented read-probe seam, never the fold's source text.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

# shellcheck source=bin/fm-classify-lib.sh
. "$ROOT/bin/fm-classify-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-classify-fold-bounded-tests)

# Wall-clock bounds. The warm (appended-bytes-only) run must be far cheaper than
# a whole-log rescan; 10s is generous on a loaded CI box while still failing a
# 5 MB re-read. The cold run may read the whole synthetic log once, so it gets a
# looser bound whose only job is to fail a pathological regression loudly rather
# than hang the suite.
FOLD_WARM_BOUND_SECS=${FOLD_WARM_BOUND_SECS:-10}
FOLD_COLD_BOUND_SECS=${FOLD_COLD_BOUND_SECS:-180}
SYNTHETIC_TARGET_BYTES=${SYNTHETIC_TARGET_BYTES:-5000000}
SYNTHETIC_KEYS=${SYNTHETIC_KEYS:-3000}

now_secs() { perl -MTime::HiRes=time -e 'printf "%.3f", time'; }

under_bound() {  # <elapsed> <bound> <message>
  perl -e 'exit(($ARGV[0] < $ARGV[1]) ? 0 : 1)' -- "$1" "$2" || fail "$3"
}

# The byte count the read-probe recorded for <file> on its MOST RECENT fold call.
last_probe_bytes() {  # <probe-file> <status-file>
  grep -F "$(printf '%s\t' "$2")" "$1" 2>/dev/null | tail -1 | cut -f2
}

file_bytes() { LC_ALL=C wc -c < "$1" | tr -d '[:space:]'; }

# Build a synthetic status log of roughly <target-bytes> bytes carrying <keys>
# open-then-resolved keyed transitions plus routine filler. Every key ends
# resolved, so a correct fold leaves an EMPTY open set after the cold run.
build_synthetic_log() {  # <file> <keys> <target-bytes>
  local file=$1 keys=$2 target=$3
  awk -v keys="$keys" -v target="$target" '
    BEGIN {
      for (i = 0; i < keys; i++) {
        printf "needs-decision [key=k%05d]: synthetic decision %05d needs an answer\n", i, i
        printf "resolved [key=k%05d]: synthetic decision %05d was answered\n", i, i
      }
      pad = "working: routine lane progress padding line for realistic status log width"
      per = length(pad) + 1
      have = 0
      for (i = 0; i < keys; i++) have += length(sprintf("needs-decision [key=k%05d]: synthetic decision %05d needs an answer", i, i)) + 1 \
                                          + length(sprintf("resolved [key=k%05d]: synthetic decision %05d was answered", i, i)) + 1
      n = int((target - have) / per) + 1
      for (j = 0; j < n; j++) print pad
    }
  ' > "$file"
}

test_incremental_fold_reads_only_appended_bytes_under_a_stated_bound() {
  local dir state probe status out size appended elapsed bytes open

  dir=$(make_case fold-bounded)
  state="$dir/state"
  probe="$dir/probe.tsv"
  status="$state/lane.status"
  : > "$probe"

  build_synthetic_log "$status" "$SYNTHETIC_KEYS" "$SYNTHETIC_TARGET_BYTES"
  size=$(file_bytes "$status")
  [ "$size" -ge 4000000 ] \
    || fail "test setup error: synthetic log is only $size bytes, not the intended multi-megabyte shape"

  # Cold run: no cursor exists, so the fold may read the whole log once. It must
  # still finish inside the cold bound, and it must genuinely have read the log.
  elapsed=$(now_secs)
  open=$(FM_OPEN_DECISIONS_READ_PROBE="$probe" status_open_decisions_incremental "$status") || {
    fail "the cold fold over the synthetic log failed"
  }
  elapsed=$(perl -MTime::HiRes=time -e 'printf "%.3f", time - $ARGV[0]' "$elapsed")
  under_bound "$elapsed" "$FOLD_COLD_BOUND_SECS" \
    "the cold fold over a $size-byte log took ${elapsed}s, over the ${FOLD_COLD_BOUND_SECS}s bound"
  bytes=$(last_probe_bytes "$probe" "$status")
  [ -n "$bytes" ] && [ "$bytes" -ge 4000000 ] \
    || fail "the cold fold recorded a $bytes-byte read, not the whole $size-byte log"
  [ -z "$open" ] \
    || fail "every synthetic key was resolved, but the cold fold left an open set: $open"

  # The second run has a warm cursor and one small append. It must read ONLY that
  # append, finish inside the warm bound, and surface exactly the new decision.
  appended=$(printf 'needs-decision [key=zzz-late]: one late decision after the cold fold\n' \
    | tee -a "$status" | LC_ALL=C wc -c | tr -d '[:space:]')
  elapsed=$(now_secs)
  open=$(FM_OPEN_DECISIONS_READ_PROBE="$probe" status_open_decisions_incremental "$status") || {
    fail "the warm incremental fold failed"
  }
  elapsed=$(perl -MTime::HiRes=time -e 'printf "%.3f", time - $ARGV[0]' "$elapsed")
  under_bound "$elapsed" "$FOLD_WARM_BOUND_SECS" \
    "the warm fold took ${elapsed}s, over the ${FOLD_WARM_BOUND_SECS}s bound"
  bytes=$(last_probe_bytes "$probe" "$status")
  [ "$bytes" = "$appended" ] \
    || fail "the warm fold read $bytes bytes instead of only the $appended-byte append"
  case "$open" in
    *"zzz-late"*"needs-decision"*) ;;
    *) fail "the warm fold did not surface the appended decision: $open" ;;
  esac
  case "$open" in
    *"k00000"*) fail "the warm fold resurrected a key resolved before the cursor" ;;
  esac

  pass "the cursor-backed fold reads only appended bytes, under a stated bound, and never re-reads the log's lifetime"
}

test_incremental_fold_reads_only_appended_bytes_under_a_stated_bound
