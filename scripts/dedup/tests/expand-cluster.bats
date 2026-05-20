#!/usr/bin/env bats

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  EXP="$REPO_ROOT/scripts/dedup/lib/expand-cluster.sh"
}

@test "cluster of 3 ids emits 3 unordered pairs" {
  run bash "$EXP" "a b c"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | wc -l | tr -d ' ')" -eq 3 ]
  echo "$output" | grep -q "^a b$"
  echo "$output" | grep -q "^a c$"
  echo "$output" | grep -q "^b c$"
}

@test "duplicate inputs are collapsed before pairing" {
  run bash "$EXP" "a b a"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | wc -l | tr -d ' ')" -eq 1 ]
  echo "$output" | grep -q "^a b$"
}
