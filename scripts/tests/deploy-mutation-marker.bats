#!/usr/bin/env bats
# Tests for scripts/lib/deploy-mutation-marker.sh: the atomic, owner-aware
# claim of <deploy-path>/.deploy-mutating (QA Critical on PR #948 round 3:
# a plain write let the node-8 scheduled deploy overwrite a laptop deploy's
# live marker and then roll back underneath it).

setup() {
  LIB="${BATS_TEST_DIRNAME}/../lib/deploy-mutation-marker.sh"
  # shellcheck source=../lib/deploy-mutation-marker.sh
  source "$LIB"
  DIR="$BATS_TEST_TMPDIR/deploy"; mkdir -p "$DIR"
  MARKER="$DIR/.deploy-mutating"
}

@test "fresh claim creates the marker holding our token" {
  run claim_mutation_marker "$MARKER" gha-1-1
  [ "$status" -eq 0 ]
  [ "$(cat "$MARKER")" = "gha-1-1" ]
}

@test "re-claim by the SAME owner is idempotent (rc 0, token unchanged)" {
  claim_mutation_marker "$MARKER" gha-1-1
  run claim_mutation_marker "$MARKER" gha-1-1
  [ "$status" -eq 0 ]
  [ "$(cat "$MARKER")" = "gha-1-1" ]
}

@test "a marker held by ANOTHER owner is refused (rc 2) and NOT overwritten" {
  claim_mutation_marker "$MARKER" manual-laptop-4242
  run claim_mutation_marker "$MARKER" gha-1-1
  [ "$status" -eq 2 ]
  [[ "$output" == *"held by another deploy"* ]]
  [ "$(cat "$MARKER")" = "manual-laptop-4242" ]
}

@test "takeover with the observed dead owner's token replaces the marker and says so" {
  claim_mutation_marker "$MARKER" manual-laptop-4242
  run claim_mutation_marker "$MARKER" gha-1-1 manual-laptop-4242
  [ "$status" -eq 0 ]
  [[ "$output" == *"TAKEOVER"* ]]
  [ "$(cat "$MARKER")" = "gha-1-1" ]
  [ ! -e "$MARKER.takeover.d" ]
}

@test "takeover with a bare 1 is refused and names the owner to pass" {
  claim_mutation_marker "$MARKER" manual-laptop-4242
  run claim_mutation_marker "$MARKER" gha-1-1 1
  [ "$status" -eq 2 ]
  [[ "$output" == *"manual-laptop-4242"* ]]
  [ "$(cat "$MARKER")" = "manual-laptop-4242" ]
}

@test "takeover naming the WRONG owner is refused (CAS miss), marker untouched" {
  claim_mutation_marker "$MARKER" manual-laptop-4242
  run claim_mutation_marker "$MARKER" gha-1-1 manual-laptop-9999
  [ "$status" -eq 2 ]
  [ "$(cat "$MARKER")" = "manual-laptop-4242" ]
}

@test "usage: missing token -> rc 3, nothing created" {
  run claim_mutation_marker "$MARKER"
  [ "$status" -eq 3 ]
  [ ! -e "$MARKER" ]
}

@test "missing parent directory -> rc 1 (non-collision failure)" {
  run claim_mutation_marker "$DIR/nope/.deploy-mutating" gha-1-1
  [ "$status" -eq 1 ]
}

@test "unreadable existing marker -> rc 4, refused (reader stubbed on PATH; CI runs as root)" {
  claim_mutation_marker "$MARKER" manual-laptop-4242
  stub="$BATS_TEST_TMPDIR/stub"; mkdir -p "$stub"
  printf '#!/bin/sh\nexit 1\n' > "$stub/head"; chmod +x "$stub/head"
  run env PATH="$stub:$PATH" bash "$LIB" claim "$MARKER" gha-1-1
  [ "$status" -eq 4 ]
  [ "$(cat "$MARKER")" = "manual-laptop-4242" ]
}

@test "executable entry point (the ssh path): bash -s -- claim works and refuses a foreign owner" {
  run bash -s -- claim "$MARKER" gha-9-1 < "$LIB"
  [ "$status" -eq 0 ]
  [ "$(cat "$MARKER")" = "gha-9-1" ]
  run bash -s -- claim "$MARKER" gha-9-2 < "$LIB"
  [ "$status" -eq 2 ]
  [ "$(cat "$MARKER")" = "gha-9-1" ]
}

@test "RACE: 20 concurrent claims with distinct tokens -> exactly one wins and the marker holds the winner's token" {
  out="$BATS_TEST_TMPDIR/rc"; mkdir -p "$out"
  # Wait on THESE pids, never a bare `wait`. bats implements BATS_TEST_TIMEOUT with a
  # background watchdog process in this shell, so a bare `wait` blocks on the watchdog
  # too and the case runs until the timeout fires (600s here; reproduced 2026-11-08 —
  # the file passes in 1.4s without BATS_TEST_TIMEOUT and hangs with it).
  pids=()
  for i in $(seq 1 20); do
    # bats runs with errexit, which the subshell inherits: capture the status
    # with `|| rc=$?` or every LOSER aborts before it can record its rc.
    ( rc=0; claim_mutation_marker "$MARKER" "gha-race-$i" >/dev/null 2>&1 || rc=$?; echo "$rc" > "$out/$i" ) &
    pids+=("$!")
  done
  wait "${pids[@]}" || true   # asserts on files, not the child's status
  winners=0; winner_token=""
  for i in $(seq 1 20); do
    if [ "$(cat "$out/$i")" = "0" ]; then winners=$((winners+1)); winner_token="gha-race-$i"; fi
  done
  [ "$winners" -eq 1 ]
  [ "$(cat "$MARKER")" = "$winner_token" ]
  losers=$(grep -lx 2 "$out"/* | wc -l | tr -d ' ')
  [ "$losers" -eq 19 ]
}

@test "clear: absent marker -> rc 0" {
  run clear_mutation_marker "$MARKER"
  [ "$status" -eq 0 ]
}

@test "clear: present marker -> removed, rc 0" {
  claim_mutation_marker "$MARKER" gha-1-1
  run clear_mutation_marker "$MARKER"
  [ "$status" -eq 0 ]
  [ ! -e "$MARKER" ]
}

@test "clear: a marker rm cannot remove -> rc 1 and says STILL PRESENT (never silent)" {
  # rm -f cannot remove a non-empty directory; that stands in for a transient
  # ssh/rm failure without needing root-proof permission tricks.
  mkdir -p "$MARKER/keep"; : > "$MARKER/keep/x"
  run clear_mutation_marker "$MARKER"
  [ "$status" -eq 1 ]
  [[ "$output" == *"STILL PRESENT"* ]]
}

@test "clear via the ssh entry point (bash -s -- clear)" {
  claim_mutation_marker "$MARKER" gha-1-1
  run bash -s -- clear "$MARKER" < "$LIB"
  [ "$status" -eq 0 ]
  [ ! -e "$MARKER" ]
}

@test "RACE: 20 concurrent TAKEOVERS of one stale marker -> exactly one wins, the rest are refused (QA Important round 5 on PR #948)" {
  claim_mutation_marker "$MARKER" manual-dead-owner-1
  out="$BATS_TEST_TMPDIR/rc-takeover"; mkdir -p "$out"
  # Explicit pids, not a bare `wait` — see the note in the RACE case above.
  pids=()
  for i in $(seq 1 20); do
    ( rc=0; claim_mutation_marker "$MARKER" "gha-take-$i" manual-dead-owner-1 >/dev/null 2>&1 || rc=$?; echo "$rc" > "$out/$i" ) &
    pids+=("$!")
  done
  wait "${pids[@]}" || true   # asserts on files, not the child's status
  winners=0; winner_token=""
  for i in $(seq 1 20); do
    if [ "$(cat "$out/$i")" = "0" ]; then winners=$((winners+1)); winner_token="gha-take-$i"; fi
  done
  [ "$winners" -eq 1 ]
  [ "$(cat "$MARKER")" = "$winner_token" ]
  [ "$(grep -lx 2 "$out"/* | wc -l | tr -d ' ')" -eq 19 ]
}
