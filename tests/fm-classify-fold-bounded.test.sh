#!/usr/bin/env bash
# tests/fm-classify-fold-bounded.test.sh - bounded-cost proof for status-log
# processing (bin/fm-classify-lib.sh).
#
# A long-lived monitoring lane legitimately produces a multi-megabyte
# append-only status log. Two properties must hold or supervision wedges (the
# 2026-09 incident: a liveness beacon stale for 729s while a fold was still
# grinding, and drains that took 11-14 minutes):
#
#   1. the cursor-backed open-decisions fold reads only the bytes appended since
#      its last call, never the log's total lifetime size; and
#   2. the span classifier reads only the appended span, never re-reading the
#      whole log to re-derive a keyed decision's live opening.
#
# Property 2 is the deterministic regression signal for this fix: at the base
# commit the span classifier re-read the whole log (and its prefix) whenever the
# span carried a keyed line, which the span read-probe observes directly, with no
# wall-clock dependence. These tests drive the real public functions and their
# documented test-only read-probe seams, never the functions' source text.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

# shellcheck source=bin/fm-classify-lib.sh
. "$ROOT/bin/fm-classify-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-classify-fold-bounded-tests)

# Generous wall-clock bounds whose only job is to fail a pathological regression
# loudly rather than hang the suite. The deterministic assertions below are the
# real proof; these never decide pass/fail on a loaded box.
FOLD_WARM_BOUND_SECS=${FOLD_WARM_BOUND_SECS:-30}
FOLD_COLD_BOUND_SECS=${FOLD_COLD_BOUND_SECS:-180}
SYNTHETIC_TARGET_BYTES=${SYNTHETIC_TARGET_BYTES:-3000000}
SYNTHETIC_KEYS=${SYNTHETIC_KEYS:-3000}

now_secs() { perl -MTime::HiRes=time -e 'printf "%.3f", time'; }

under_bound() {  # <elapsed> <bound> <message>
  perl -e 'exit(($ARGV[0] < $ARGV[1]) ? 0 : 1)' -- "$1" "$2" || fail "$3"
}

# Sum of the byte lengths a read-probe recorded for <file> across all calls.
probe_bytes_for() {  # <probe-file> <status-file>
  awk -F '\t' -v f="$2" '$1 == f { s += $2 } END { print s + 0 }' "$1"
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

# Build a multi-megabyte log of routine lines only, so a span classifier that
# re-reads the whole log to find a keyed line pays the full size while the fixture
# stays fast to fold at the base commit. The lines are long on purpose: the byte
# volume is what the classifier must not re-read, and folding a few hundred long
# lines is cheap, so the base-failure check does not itself take minutes.
build_routine_log() {  # <file> <target-bytes>
  local file=$1 target=$2
  awk -v target="$target" '
    BEGIN {
      unit = ""
      for (i = 0; i < 100; i++) unit = unit "routine-lane-progress-padding-"
      per = length(unit) + 1
      n = int(target / per) + 1
      for (j = 0; j < n; j++) printf "working: %s%06d\n", unit, j
    }
  ' > "$file"
}

test_incremental_fold_reads_only_appended_bytes() {
  local dir state probe status out size appended elapsed bytes open

  dir=$(make_case fold-bounded)
  state="$dir/state"
  probe="$dir/probe.tsv"
  status="$state/lane.status"
  : > "$probe"

  build_synthetic_log "$status" "$SYNTHETIC_KEYS" "$SYNTHETIC_TARGET_BYTES"
  size=$(file_bytes "$status")
  [ "$size" -ge 2000000 ] \
    || fail "test setup error: synthetic log is only $size bytes, not the intended multi-megabyte shape"

  # Cold run: no cursor exists, so the fold reads the whole log once. It must
  # finish inside the cold bound and must genuinely have read the log.
  elapsed=$(now_secs)
  open=$(FM_OPEN_DECISIONS_READ_PROBE="$probe" status_open_decisions_incremental "$status") || {
    fail "the cold fold over the synthetic log failed"
  }
  elapsed=$(perl -MTime::HiRes=time -e 'printf "%.3f", time - $ARGV[0]' "$elapsed")
  under_bound "$elapsed" "$FOLD_COLD_BOUND_SECS" \
    "the cold fold over a $size-byte log took ${elapsed}s, over the ${FOLD_COLD_BOUND_SECS}s bound"
  bytes=$(awk -F '\t' -v f="$status" '$1 == f { print $2 }' "$probe" | tail -1)
  [ -n "$bytes" ] && [ "$bytes" -ge 2000000 ] \
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
  bytes=$(awk -F '\t' -v f="$status" '$1 == f { print $2 }' "$probe" | tail -1)
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

# The deterministic regression signal: with a warm start offset, classifying a
# span that carries one appended keyed line must read only that appended span. At
# the base commit the same call re-read the whole multi-megabyte log (and its
# prefix) to re-derive the keyed decision's live opening, so the span read-probe
# would report the whole log rather than the append.
test_span_classifier_reads_only_the_appended_span() {
  local dir state probe status size appended read_bytes event span_rc

  dir=$(make_case span-bounded)
  state="$dir/state"
  probe="$dir/probe.tsv"
  status="$state/lane.status"
  : > "$probe"

  build_routine_log "$status" "$SYNTHETIC_TARGET_BYTES"
  size=$(file_bytes "$status")
  [ "$size" -ge 2000000 ] \
    || fail "test setup error: routine log is only $size bytes, not the intended multi-megabyte shape"

  # A warm start at the current end has nothing to classify and reads nothing.
  FM_STATUS_SPAN_READ_PROBE="$probe" status_span_first_actionable_record "$status" "$size" >/dev/null 2>&1
  [ "$(probe_bytes_for "$probe" "$status")" -eq 0 ] \
    || fail "an already-classified end offset still read the log"

  # Append ONE keyed decision and classify from the warm offset.
  appended=$(printf 'needs-decision [key=late-span]: one keyed decision appended to a large log\n' \
    | tee -a "$status" | LC_ALL=C wc -c | tr -d '[:space:]')
  event=$(FM_STATUS_SPAN_READ_PROBE="$probe" status_span_first_actionable_record "$status" "$size")
  span_rc=$?
  [ "$span_rc" -eq 0 ] || fail "the appended keyed decision was not classified actionable"
  case "$event" in
    *"needs-decision [key=late-span]"*) ;;
    *) fail "the span classifier did not report the appended decision: $event" ;;
  esac
  read_bytes=$(probe_bytes_for "$probe" "$status")
  [ "$read_bytes" = "$appended" ] \
    || fail "the span classifier read $read_bytes bytes for a $appended-byte append (at base it re-read all $size bytes)"
  [ "$read_bytes" -lt "$size" ] \
    || fail "test setup error: the append ($read_bytes) is not smaller than the log ($size)"

  pass "a warm span classification reads only the appended span, never the whole log"
}

# The rewritten span-origin logic must follow the same open/close rule the
# whole-file fold does: a key opened and then resolved inside one span is not
# actionable, and a same-key reopening supersedes its earlier opening.
test_span_origins_follow_open_reopen_and_resolve() {
  local dir state status event rc

  dir=$(make_case span-origins)
  state="$dir/state"
  status="$state/lane.status"

  # Opened then resolved in the same span: nothing is live, so nothing surfaces.
  printf 'needs-decision [key=a]: pick one\nresolved [key=a]: went with one\n' > "$status"
  rc=0
  status_span_first_actionable_record "$status" 0 >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 1 ] \
    || fail "a decision opened and resolved in one span did not fold to not-actionable (rc=$rc)"

  # Reopened with a new note: only the live (last) opening surfaces.
  printf 'needs-decision [key=c]: version one\nneeds-decision [key=c]: version two\n' > "$status"
  event=$(status_span_first_actionable_record "$status" 0) || fail "the reopened decision did not classify actionable"
  case "$event" in
    *"version two"*) ;;
    *) fail "the reopened decision did not report its live opening: $event" ;;
  esac
  case "$event" in
    *"version one"*) fail "the superseded opening of a reopened key was reported: $event" ;;
  esac

  # A key opened in the prefix stays resolved for a later span that opens a
  # different key: only the new key surfaces.
  printf 'needs-decision [key=d]: prefix decision\nresolved [key=d]: prefix resolved\n' > "$status"
  prefix_size=$(file_bytes "$status")
  printf 'needs-decision [key=e]: later decision\n' >> "$status"
  event=$(status_span_first_actionable_record "$status" "$prefix_size") \
    || fail "the later key was not classified actionable"
  case "$event" in
    *"key=e"*"later decision"*) ;;
    *) fail "the later key's live opening was not reported: $event" ;;
  esac
  case "$event" in
    *"key=d"*) fail "a key resolved before the span was reported from it: $event" ;;
  esac

  pass "span origins honour open-then-resolve, same-key reopening, and prefix state"
}

test_incremental_fold_reads_only_appended_bytes
test_span_classifier_reads_only_the_appended_span
test_span_origins_follow_open_reopen_and_resolve
