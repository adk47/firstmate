#!/usr/bin/env bats

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  SCORER="$REPO_ROOT/scripts/dedup/lib/score-pair.sh"
  FIX="$REPO_ROOT/scripts/dedup/tests/fixtures"
}

@test "same_raw_id alone produces hard_dupe with one hard signal" {
  run bash "$SCORER" "$FIX/same_spotify_raw_id_only.a.json" "$FIX/same_spotify_raw_id_only.b.json"
  [ "$status" -eq 0 ]
  verdict=$(echo "$output" | jq -r '.verdict')
  [ "$verdict" = "hard_dupe" ]
  hard_count=$(echo "$output" | jq '.hard_signals | length')
  [ "$hard_count" -eq 1 ]
  signal_type=$(echo "$output" | jq -r '.hard_signals[0].type')
  [ "$signal_type" = "same_raw_id" ]
  signal_source=$(echo "$output" | jq -r '.hard_signals[0].source')
  [ "$signal_source" = "spotify" ]
  signal_value=$(echo "$output" | jq -r '.hard_signals[0].value')
  [ "$signal_value" = "abc123" ]
}

@test "same_ipi alone produces hard_dupe with one hard signal" {
  run bash "$SCORER" "$FIX/same_ipi_only.a.json" "$FIX/same_ipi_only.b.json"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.verdict')" = "hard_dupe" ]
  [ "$(echo "$output" | jq '.hard_signals | length')" -eq 1 ]
  [ "$(echo "$output" | jq -r '.hard_signals[0].type')" = "same_ipi" ]
  [ "$(echo "$output" | jq -r '.hard_signals[0].value')" = "00123456789" ]
}

@test "both raw_id and ipi match produces both hard signals" {
  run bash "$SCORER" "$FIX/same_raw_id_and_ipi.a.json" "$FIX/same_raw_id_and_ipi.b.json"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.verdict')" = "hard_dupe" ]
  [ "$(echo "$output" | jq '.hard_signals | length')" -eq 2 ]
}

@test "name match without raw_id/ipi overlap is no_match" {
  run bash "$SCORER" "$FIX/name_only_match.a.json" "$FIX/name_only_match.b.json"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.verdict')" = "no_match" ]
  [ "$(echo "$output" | jq '.hard_signals | length')" -eq 0 ]
}

@test "shared ISRC at credit level is NOT a hard signal" {
  run bash "$SCORER" "$FIX/shared_isrc_only.a.json" "$FIX/shared_isrc_only.b.json"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.verdict')" = "no_match" ]
}

@test "empty external ids on both sides produce no_match" {
  run bash "$SCORER" "$FIX/empty_external_ids.a.json" "$FIX/empty_external_ids.b.json"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.verdict')" = "no_match" ]
}

@test "both claimed by different users surfaces claim_state correctly" {
  tmp_b="$BATS_TMPDIR/both_claimed_diff.b.json"
  jq '.claim = {user_id: "user_y", status: "processed"} | .id = "bbbb-bbbb"' \
    "$FIX/same_raw_id_and_ipi.b.json" > "$tmp_b"
  run bash "$SCORER" "$FIX/same_raw_id_and_ipi.a.json" "$tmp_b"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.verdict')" = "hard_dupe" ]
  [ "$(echo "$output" | jq -r '.soft_signals.claim_state')" = "both_claimed_different_users" ]
}

@test "one claimed one unclaimed surfaces a_claimed_b_unclaimed" {
  run bash "$SCORER" "$FIX/same_raw_id_and_ipi.a.json" "$FIX/same_raw_id_and_ipi.b.json"
  [ "$(echo "$output" | jq -r '.soft_signals.claim_state')" = "a_claimed_b_unclaimed" ]
}

@test "both unclaimed surfaces both_unclaimed" {
  run bash "$SCORER" "$FIX/empty_external_ids.a.json" "$FIX/empty_external_ids.b.json"
  [ "$(echo "$output" | jq -r '.soft_signals.claim_state')" = "both_unclaimed" ]
}

@test "soft signals computed correctly for known fixture" {
  run bash "$SCORER" "$FIX/same_raw_id_and_ipi.a.json" "$FIX/same_raw_id_and_ipi.b.json"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.soft_signals.popularity_delta')" -eq 38 ]
  [ "$(echo "$output" | jq -r '.soft_signals.credit_count_delta')" -eq 31 ]
  [ "$(echo "$output" | jq -r '.soft_signals.country_match')" = "true" ]
  [ "$(echo "$output" | jq -r '.soft_signals.name_levenshtein')" -gt 0 ]
}

@test "alias overlap counts shared known_as_names" {
  tmp_a="$BATS_TMPDIR/alias_a.json"
  tmp_b="$BATS_TMPDIR/alias_b.json"
  jq '.known_as_names = ["AZ", "Zain"]' "$FIX/same_ipi_only.a.json" > "$tmp_a"
  jq '.known_as_names = ["Zain", "AZ", "X"]' "$FIX/same_ipi_only.b.json" > "$tmp_b"
  run bash "$SCORER" "$tmp_a" "$tmp_b"
  [ "$(echo "$output" | jq -r '.soft_signals.alias_overlap')" -eq 2 ]
}

@test "candidate_dupe fires on near-empty-duplicate pattern (zero shared tracks)" {
  # Real-world case 2026-05-19: ticket 869dbq3gc Ilija Stajic.
  # Customer's claimed main profile has many credits; auto-created duplicate
  # has very few; they share NO tracks because the duplicate is a stub. Name
  # is identical modulo diacritic. Must fire candidate_dupe without needing
  # SHARED_TRACK_COUNT >= 3.
  tmp_a="$BATS_TMPDIR/near_empty_a.json"
  tmp_b="$BATS_TMPDIR/near_empty_b.json"
  jq '.name = "Ilija Stajic" | .credit_count = 69 | .id = "main-a"' \
    "$FIX/candidate_dupe.a.json" > "$tmp_a"
  jq '.name = "Ilija Stajic" | .credit_count = 1 | .id = "stub-b" | .claim = {user_id: null, status: null}' \
    "$FIX/candidate_dupe.b.json" > "$tmp_b"
  SHARED_TRACK_COUNT=0 run bash "$SCORER" "$tmp_a" "$tmp_b"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.verdict')" = "candidate_dupe" ]
  [ "$(echo "$output" | jq -r '.soft_signals.shared_track_ids_count')" = "0" ]
}

@test "candidate_dupe does NOT fire when both profiles are near-empty (random John Smith case)" {
  # Guard against the false positive: two unclaimed profiles with the same
  # name and both 0-2 credits could be two different people, not a dupe.
  tmp_a="$BATS_TMPDIR/both_empty_a.json"
  tmp_b="$BATS_TMPDIR/both_empty_b.json"
  jq '.name = "John Smith" | .credit_count = 1' \
    "$FIX/candidate_dupe.a.json" > "$tmp_a"
  jq '.name = "John Smith" | .credit_count = 2 | .claim = {user_id: null, status: null}' \
    "$FIX/candidate_dupe.b.json" > "$tmp_b"
  SHARED_TRACK_COUNT=0 run bash "$SCORER" "$tmp_a" "$tmp_b"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.verdict')" = "no_match" ]
}

@test "candidate_dupe fires on close name + shared_tracks >= 3 + safe claim" {
  SHARED_TRACK_COUNT=5 run bash "$SCORER" "$FIX/candidate_dupe.a.json" "$FIX/candidate_dupe.b.json"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.verdict')" = "candidate_dupe" ]
  [ "$(echo "$output" | jq '.hard_signals | length')" -eq 0 ]
  [ "$(echo "$output" | jq -r '.soft_signals.shared_track_ids_count')" = "5" ]
  [ "$(echo "$output" | jq -r '.soft_signals.name_levenshtein')" -le 2 ]
}

@test "candidate_dupe does NOT fire when shared_tracks < 3" {
  SHARED_TRACK_COUNT=2 run bash "$SCORER" "$FIX/candidate_dupe.a.json" "$FIX/candidate_dupe.b.json"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.verdict')" = "no_match" ]
}

@test "candidate_dupe does NOT fire when name distance > 2" {
  tmp_b="$BATS_TMPDIR/cand_far_b.json"
  jq '.name = "John Smith"' "$FIX/candidate_dupe.b.json" > "$tmp_b"
  SHARED_TRACK_COUNT=10 run bash "$SCORER" "$FIX/candidate_dupe.a.json" "$tmp_b"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.verdict')" = "no_match" ]
}

@test "candidate_dupe does NOT fire when both profiles claimed by different users" {
  tmp_a="$BATS_TMPDIR/cand_claim_a.json"
  jq '.claim = {user_id: "bob", status: "processed"}' "$FIX/candidate_dupe.a.json" > "$tmp_a"
  SHARED_TRACK_COUNT=10 run bash "$SCORER" "$tmp_a" "$FIX/candidate_dupe.b.json"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.verdict')" = "no_match" ]
  [ "$(echo "$output" | jq -r '.soft_signals.claim_state')" = "both_claimed_different_users" ]
}

@test "hard_dupe wins over candidate_dupe even when soft conditions met" {
  SHARED_TRACK_COUNT=10 run bash "$SCORER" "$FIX/same_raw_id_and_ipi.a.json" "$FIX/same_raw_id_and_ipi.b.json"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.verdict')" = "hard_dupe" ]
}

@test "shared_track_ids_count defaults to 0 when SHARED_TRACK_COUNT unset" {
  unset SHARED_TRACK_COUNT
  run bash "$SCORER" "$FIX/candidate_dupe.a.json" "$FIX/candidate_dupe.b.json"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.soft_signals.shared_track_ids_count')" = "0" ]
  [ "$(echo "$output" | jq -r '.verdict')" = "no_match" ]
}

@test "shared_track_ids_count rejects non-numeric input" {
  SHARED_TRACK_COUNT="garbage" run bash "$SCORER" "$FIX/candidate_dupe.a.json" "$FIX/candidate_dupe.b.json"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.soft_signals.shared_track_ids_count')" = "0" ]
}
