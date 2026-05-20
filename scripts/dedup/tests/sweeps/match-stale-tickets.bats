#!/usr/bin/env bats

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../../.." && pwd)"
  MATCH="$REPO_ROOT/scripts/dedup/sweeps/match-stale-tickets.sh"
  TMP=$(mktemp -d)
}

teardown() {
  rm -rf "$TMP"
}

@test "ticket matches when customer_profile_id is the survivor of a recorded merge" {
  cat > "$TMP/merges.jsonl" <<EOF
{"mergeInto":"aaaa","profilesIds":["bbbb"],"at":"2026-05-15T16:00Z"}
EOF
  cat > "$TMP/tickets.jsonl" <<EOF
{"task_id":"T1","customer_profile_id":"aaaa"}
EOF
  run bash "$MATCH" "$TMP/merges.jsonl" "$TMP/tickets.jsonl"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.task_id')" = "T1" ]
  [ "$(echo "$output" | jq -r '.matched_by')" = "survivor" ]
  [ "$(echo "$output" | jq -r '.merge_at')" = "2026-05-15T16:00Z" ]
}

@test "ticket matches when customer_profile_id is a loser of a recorded merge" {
  cat > "$TMP/merges.jsonl" <<EOF
{"mergeInto":"aaaa","profilesIds":["bbbb","cccc"],"at":"2026-05-10T10:00Z"}
EOF
  cat > "$TMP/tickets.jsonl" <<EOF
{"task_id":"T2","customer_profile_id":"cccc"}
EOF
  run bash "$MATCH" "$TMP/merges.jsonl" "$TMP/tickets.jsonl"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.task_id')" = "T2" ]
  [ "$(echo "$output" | jq -r '.matched_by')" = "loser" ]
}

@test "ticket with no matching merge emits nothing" {
  cat > "$TMP/merges.jsonl" <<EOF
{"mergeInto":"aaaa","profilesIds":["bbbb"],"at":"2026-05-15T16:00Z"}
EOF
  cat > "$TMP/tickets.jsonl" <<EOF
{"task_id":"T3","customer_profile_id":"zzzz"}
EOF
  run bash "$MATCH" "$TMP/merges.jsonl" "$TMP/tickets.jsonl"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "multiple tickets emit one line each for matches only" {
  cat > "$TMP/merges.jsonl" <<EOF
{"mergeInto":"aaaa","profilesIds":["bbbb"],"at":"2026-05-15T16:00Z"}
{"mergeInto":"dddd","profilesIds":["eeee"],"at":"2026-05-10T10:00Z"}
EOF
  cat > "$TMP/tickets.jsonl" <<EOF
{"task_id":"T_HIT_A","customer_profile_id":"aaaa"}
{"task_id":"T_MISS","customer_profile_id":"zzzz"}
{"task_id":"T_HIT_LOSER","customer_profile_id":"eeee"}
EOF
  run bash "$MATCH" "$TMP/merges.jsonl" "$TMP/tickets.jsonl"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | wc -l | tr -d ' ')" -eq 2 ]
  echo "$output" | grep -q T_HIT_A
  echo "$output" | grep -q T_HIT_LOSER
  ! echo "$output" | grep -q T_MISS
}
