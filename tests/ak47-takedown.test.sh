#!/usr/bin/env bash
# tests/ak47-takedown.test.sh - the once-off big-entry take-down.
#
# The takedown exists to move gigabytes, and it is the one path in this system
# that touches entries the producer table does not enumerate. So the tests are
# about what it refuses, and about the fact that acting is a rename with a
# printed revert rather than a delete.
#
# Hermetic: AK47_TMP_ROOT, AK47_STATE, AK47_CACHE, AK47_CONFIG and FM_HOME all
# point inside one mktemp root.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TD="$ROOT/ak47/tmp-takedown.sh"

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

SANDBOX=
cleanup() {
  [ -n "${HOLDER_PID:-}" ] && kill "$HOLDER_PID" 2>/dev/null
  [ -n "${SANDBOX:-}" ] && rm -rf "$SANDBOX"
}
trap cleanup EXIT
SANDBOX=$(mktemp -d "${TMPDIR:-/tmp}/ak47-td-tests.XXXXXX")

export AK47_STATE=$SANDBOX/state
export AK47_CACHE=$SANDBOX/cache
export AK47_CONFIG=$SANDBOX/config
export AK47_TMP_ROOT=$SANDBOX/tmp
export FM_HOME=$SANDBOX/fmhome
mkdir -p "$AK47_STATE" "$AK47_CACHE" "$AK47_CONFIG" "$AK47_TMP_ROOT" \
  "$FM_HOME/state" "$FM_HOME/bin"

# A directory big enough to rank, old enough to pass the age gate.
junk() {  # junk <name> [age] [kib]
  local name=$1 age=${2:-'3 days ago'} kib=${3:-2000}
  mkdir -p "$AK47_TMP_ROOT/$name"
  head -c $(( kib * 1024 )) /dev/zero >"$AK47_TMP_ROOT/$name/blob" 2>/dev/null
  touch -d "$age" "$AK47_TMP_ROOT/$name"
}

reset_tree() {
  rm -rf "$AK47_TMP_ROOT" "$AK47_STATE"
  mkdir -p "$AK47_TMP_ROOT" "$AK47_STATE"
}

test_moves_an_old_unheld_entry_into_quarantine_with_a_revert() {
  reset_tree
  junk old-junk
  local out
  out=$("$TD" --apply --top 5 2>&1) || fail "takedown exited non-zero: $out"
  [ -e "$AK47_TMP_ROOT/old-junk" ] && fail "the old entry was left in place"
  case "$out" in
    *revert=*) : ;;
    *) fail "the takedown did not print a revert for what it moved: $out" ;;
  esac
  local q
  q=$(find "$AK47_STATE/quarantine" -maxdepth 2 -mindepth 2 -name old-junk | head -1)
  [ -n "$q" ] || fail "the entry was not moved into the dated quarantine directory"
  [ -f "$q/blob" ] || fail "the quarantined entry lost its contents"
  pass "an old unheld entry is quarantined, not deleted, and its revert is printed"
}

test_refuses_a_directory_a_live_process_is_sitting_in() {
  reset_tree
  junk held-dir
  ( cd "$AK47_TMP_ROOT/held-dir" && sleep 30 ) &
  HOLDER_PID=$!
  sleep 0.5
  local out
  out=$("$TD" --apply --top 5 2>&1) || fail "takedown exited non-zero: $out"
  kill "$HOLDER_PID" 2>/dev/null; wait "$HOLDER_PID" 2>/dev/null; HOLDER_PID=
  [ -d "$AK47_TMP_ROOT/held-dir" ] || fail "the takedown moved a directory a live process was sitting in"
  case "$out" in
    *"leaving alone"*) : ;;
    *) fail "the refusal was not reported: $out" ;;
  esac
  pass "a directory a live process is sitting in is never moved"
}

test_refuses_a_young_entry() {
  reset_tree
  junk young-dir '10 minutes ago'
  "$TD" --apply --top 5 >/dev/null 2>&1 || fail "takedown exited non-zero"
  [ -d "$AK47_TMP_ROOT/young-dir" ] || fail "the takedown moved an entry younger than its idle gate"
  pass "age alone never qualifies an entry: a young one is left alone"
}

test_refuses_a_live_task_scratch_root() {
  reset_tree
  junk fm-livetask
  : >"$FM_HOME/state/livetask.meta"
  "$TD" --apply --top 5 >/dev/null 2>&1 || fail "takedown exited non-zero"
  [ -d "$AK47_TMP_ROOT/fm-livetask" ] || fail "the takedown moved a live task's scratch root"
  pass "a live task's scratch root is never moved, however old it looks"
}

test_refuses_every_protected_path() {
  reset_tree
  local n
  for n in ak47-keep orcad-x cli-proxy-token fm-move; do junk "$n"; done
  "$TD" --apply --top 10 >/dev/null 2>&1 || fail "takedown exited non-zero"
  for n in ak47-keep orcad-x cli-proxy-token fm-move; do
    [ -e "$AK47_TMP_ROOT/$n" ] || fail "the takedown moved the protected path $n"
  done
  pass "every protected pattern is refused even when it is the biggest entry"
}

test_the_per_run_bound_is_honoured() {
  reset_tree
  local i
  for i in 1 2 3 4 5 6; do junk "junk-$i"; done
  AK47_TAKEDOWN_MAX=2 "$TD" --apply --top 10 >/dev/null 2>&1 || fail "takedown exited non-zero"
  local moved
  moved=$(find "$AK47_STATE/quarantine" -maxdepth 2 -mindepth 2 2>/dev/null | wc -l)
  [ "$moved" -eq 2 ] || fail "the per-run bound was $moved entries, expected 2"
  pass "one run moves at most AK47_TAKEDOWN_MAX entries"
}

test_a_hanging_size_walk_is_bounded() {
  reset_tree
  junk big-entry
  local stub=$SANDBOX/bin start elapsed
  mkdir -p "$stub"
  printf '#!/bin/sh\nsleep 30\n' >"$stub/du"
  chmod +x "$stub/du"
  start=$SECONDS
  PATH="$stub:$PATH" AK47_DU_BUDGET=2 "$TD" --dry-run --top 5 >/dev/null 2>&1
  elapsed=$((SECONDS - start))
  [ "$elapsed" -le 8 ] \
    || fail "the size ranking ignored its configured budget (took ${elapsed}s)"
  [ -d "$AK47_TMP_ROOT/big-entry" ] || fail "a bounded dry run still moved an entry"
  pass "a hanging size walk is bounded and does not stall the take-down"
}

test_an_empty_root_is_not_a_failure() {
  reset_tree
  "$TD" --dry-run --top 5 >/dev/null 2>&1 \
    || fail "an empty root was reported as a failure to build a safe set"
  pass "an empty root is a completed run, not a ranking failure"
}

test_a_dry_run_moves_nothing() {
  reset_tree
  junk dry-run-victim
  "$TD" --dry-run --top 5 >/dev/null 2>&1 || fail "takedown exited non-zero"
  [ -d "$AK47_TMP_ROOT/dry-run-victim" ] || fail "a dry run moved an entry"
  [ ! -d "$AK47_STATE/quarantine" ] || fail "a dry run created a quarantine directory"
  pass "a dry run reports what it would move and moves nothing"
}

test_moves_an_old_unheld_entry_into_quarantine_with_a_revert
test_refuses_a_directory_a_live_process_is_sitting_in
test_refuses_a_young_entry
test_refuses_a_live_task_scratch_root
test_refuses_every_protected_path
test_the_per_run_bound_is_honoured
test_a_hanging_size_walk_is_bounded
test_an_empty_root_is_not_a_failure
test_a_dry_run_moves_nothing
