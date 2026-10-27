#!/usr/bin/env bats
# bats-slot.bats — the host-wide CI slot that caps concurrent bats suites per box.
#
# WHY (2026-10-27, Fable ruling on #1403). A workflow `concurrency` group cannot express
# "at most one suite per HOST"; a constant group also throws away the per-ref
# supersede-cancellation the workflow needs. The cap that matches the resource is a host
# flock around the bats step. These cases EXECUTE the shipped script (not a grep of it):
# serialization, the loud timeout, exit-code passthrough, and lock release.

setup() {
  repo_root="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  slot="$repo_root/scripts/bats-slot.sh"
  work=$(mktemp -d)
  lock="$work/test.lock"
}
teardown() { rm -rf "$work"; }

@test "the script refuses to run with no command" {
  run "$slot" --lock "$lock" --
  [ "$status" -ne 0 ]
  [[ "$output" == *"no command given"* ]]
}

@test "a rejected --timeout is refused (never an unbounded wait by typo)" {
  run "$slot" --lock "$lock" --timeout abc -- true
  [ "$status" -ne 0 ]
  [[ "$output" == *"must be an integer"* ]]
}

@test "single holder: a second caller WAITS, and runs only after the first releases" {
  # first holds the slot for ~1.2 s and writes its markers
  "$slot" --lock "$lock" -- bash -c "echo first-start >> '$work/order'; sleep 1.2; echo first-end >> '$work/order'" &
  first=$!
  sleep 0.4                                    # let it take the lock
  "$slot" --lock "$lock" -- bash -c "echo second-start >> '$work/order'" 
  wait "$first"
  mapfile -t seq < "$work/order"
  echo "order: ${seq[*]}"
  [ "${seq[0]}" = "first-start" ]
  [ "${seq[1]}" = "first-end" ]
  [ "${seq[2]}" = "second-start" ]
}

@test "timeout is LOUD and non-zero — never a silent skip" {
  "$slot" --lock "$lock" -- sleep 3 &
  holder=$!
  sleep 0.3
  run "$slot" --lock "$lock" --timeout 1 -- true
  wait "$holder"
  [ "$status" -ne 0 ]
  [[ "$output" == *"::error::"* ]]
  [[ "$output" == *"UNSLOTTED"* ]]
}

@test "the command's exit code is passed through (a red suite stays red)" {
  run "$slot" --lock "$lock" -- bash -c 'exit 7'
  [ "$status" -eq 7 ]
}

@test "the slot is released when the command fails, so the next caller is not starved" {
  run "$slot" --lock "$lock" -- bash -c 'exit 1'
  [ "$status" -eq 1 ]
  run "$slot" --lock "$lock" --timeout 5 -- true
  [ "$status" -eq 0 ]
}
