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
  if echo "$output" | grep -q T_MISS; then echo "unexpected match: T_MISS" >&2; return 1; fi
}

# 2026-10-26 (profile-merge-ops-m1): a ticket that NAMES its duplicates is done only when
# every named duplicate was merged away; a merge that merely touched the customer's
# profile must not close it.
@test "ticket naming duplicates matches only when every duplicate is a merged loser" {
  printf '%s\n' \
    '{"mergeInto":"aaaa","profilesIds":["bbbb"],"at":"2026-10-26 21:50:00.000000 UTC"}' \
    '{"mergeInto":"aaaa","profilesIds":["cccc"],"at":"2026-10-26 21:55:00.000000 UTC"}' > "$TMP/merges.jsonl"
  printf '%s\n' \
    '{"task_id":"T_ALL","customer_profile_id":"aaaa","dup_ids":["bbbb","CCCC"]}' \
    '{"task_id":"T_PART","customer_profile_id":"aaaa","dup_ids":["bbbb","dddd"]}' > "$TMP/tickets.jsonl"
  run bash "$MATCH" "$TMP/merges.jsonl" "$TMP/tickets.jsonl"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | wc -l | tr -d ' ')" = "1" ]
  [ "$(echo "$output" | jq -r '.task_id')" = "T_ALL" ]
  [ "$(echo "$output" | jq -r '.matched_by')" = "duplicates" ]
  [ "$(echo "$output" | jq -r '.merge_at')" = "2026-10-26 21:55:00.000000 UTC" ]
}

@test "a merge into the customer's profile does not close a ticket whose named duplicate still stands" {
  printf '%s\n' '{"mergeInto":"aaaa","profilesIds":["zzzz"],"at":"2026-10-22 17:47:27 UTC"}' > "$TMP/merges.jsonl"
  printf '%s\n' '{"task_id":"T_OPEN","customer_profile_id":"aaaa","dup_ids":["bbbb"]}' > "$TMP/tickets.jsonl"
  run bash "$MATCH" "$TMP/merges.jsonl" "$TMP/tickets.jsonl"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "an empty dup_ids list keeps the survivor/loser rule" {
  printf '%s\n' '{"mergeInto":"aaaa","profilesIds":["bbbb"],"at":"2026-10-26 21:50:00 UTC"}' > "$TMP/merges.jsonl"
  printf '%s\n' '{"task_id":"T_LEGACY","customer_profile_id":"aaaa","dup_ids":[]}' > "$TMP/tickets.jsonl"
  run bash "$MATCH" "$TMP/merges.jsonl" "$TMP/tickets.jsonl"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.matched_by')" = "survivor" ]
}

@test "thousands of ledger rows do not overflow the argument list" {
  for i in $(seq 1 5000); do
    printf '{"mergeInto":"s%05d","profilesIds":["l%05d-aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"],"at":"2026-10-26 21:50:00 UTC"}\n' "$i" "$i"
  done > "$TMP/merges.jsonl"
  printf '%s\n' '{"task_id":"T_BIG","customer_profile_id":"s04999","dup_ids":["l04999-aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"]}' > "$TMP/tickets.jsonl"
  run bash "$MATCH" "$TMP/merges.jsonl" "$TMP/tickets.jsonl"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.task_id')" = "T_BIG" ]
}

# Fable/QA review of #1375: a named duplicate counts only if it was merged INTO the
# profile the customer asked to keep (or a verified chain reaching it).
@test "a duplicate merged into an unrelated profile does not close the ticket" {
  printf '%s\n' '{"mergeInto":"stranger","profilesIds":["dup1"],"at":"2026-10-26 21:50:00 UTC"}' > "$TMP/merges.jsonl"
  printf '%s\n' '{"task_id":"T_STRANGER","customer_profile_id":"cust","dup_ids":["dup1"]}' > "$TMP/tickets.jsonl"
  run bash "$MATCH" "$TMP/merges.jsonl" "$TMP/tickets.jsonl"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "keep_id, not customer_profile_id, is the required destination when the ticket names one" {
  printf '%s\n' '{"mergeInto":"cust","profilesIds":["dup1"],"at":"2026-10-26 21:50:00 UTC"}' > "$TMP/merges.jsonl"
  printf '%s\n' '{"task_id":"T_KEEP","customer_profile_id":"cust","keep_id":"main","dup_ids":["dup1"]}' > "$TMP/tickets.jsonl"
  run bash "$MATCH" "$TMP/merges.jsonl" "$TMP/tickets.jsonl"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "a verified chain that reaches the kept profile counts, as does a kept profile merged forward" {
  printf '%s\n' \
    '{"mergeInto":"mid","profilesIds":["dup1"],"at":"2026-10-20 10:00:00 UTC"}' \
    '{"mergeInto":"main","profilesIds":["mid"],"at":"2026-10-21 10:00:00 UTC"}' \
    '{"mergeInto":"main2","profilesIds":["main"],"at":"2026-10-22 10:00:00 UTC"}' \
    '{"mergeInto":"main2","profilesIds":["dup2"],"at":"2026-10-23 10:00:00 UTC"}' > "$TMP/merges.jsonl"
  printf '%s\n' '{"task_id":"T_CHAIN","customer_profile_id":"main","dup_ids":["dup1","dup2","main"]}' > "$TMP/tickets.jsonl"
  run bash "$MATCH" "$TMP/merges.jsonl" "$TMP/tickets.jsonl"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.task_id')" = "T_CHAIN" ]
  [ "$(echo "$output" | jq -r '.merge_at')" = "2026-10-23 10:00:00 UTC" ]
}

@test "a merge cycle in the ledger cannot hang the matcher" {
  printf '%s\n' \
    '{"mergeInto":"b","profilesIds":["a"],"at":"2026-10-20 10:00:00 UTC"}' \
    '{"mergeInto":"a","profilesIds":["b"],"at":"2026-10-21 10:00:00 UTC"}' > "$TMP/merges.jsonl"
  printf '%s\n' '{"task_id":"T_CYCLE","customer_profile_id":"keep","dup_ids":["a"]}' > "$TMP/tickets.jsonl"
  run timeout 20 bash "$MATCH" "$TMP/merges.jsonl" "$TMP/tickets.jsonl"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "an unreadable or conflicting keep_id holds the ticket on both rules" {
  printf '%s\n' '{"mergeInto":"cust","profilesIds":["dup1"],"at":"2026-10-26 21:50:00 UTC"}' > "$TMP/merges.jsonl"
  printf '%s\n' \
    '{"task_id":"T_U_DUPS","customer_profile_id":"cust","keep_id":"unreadable:https://muso.ai/artist/x","dup_ids":["dup1"]}' \
    '{"task_id":"T_U_LEGACY","customer_profile_id":"cust","keep_id":"unreadable:https://muso.ai/artist/x","dup_ids":[]}' \
    '{"task_id":"T_C_DUPS","customer_profile_id":"cust","keep_id":"conflicting:cust,other","dup_ids":["dup1"]}' > "$TMP/tickets.jsonl"
  run bash "$MATCH" "$TMP/merges.jsonl" "$TMP/tickets.jsonl"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
