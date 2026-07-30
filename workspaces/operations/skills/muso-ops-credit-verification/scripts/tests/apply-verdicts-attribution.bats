#!/usr/bin/env bats
bats_require_minimum_version 1.5.0
load helpers

# Covers apply-verdicts.sh PER-ROW attribution.
#
# The behaviour under test replaced a chunk-level inference that read only the
# HTTP status: a 200 marked EVERY id in the chunk landed — including rows the
# backend had explicitly reported in skippedIds — and any non-2xx marked every
# id refused, including rows that really did persist. That is how the
# 2026-07-23 sweeps reported rows as applied that had never moved.
#
# The backend now answers 409 when it refuses part of a batch, carrying the same
# per-row report as a 200. Both must be attributed row by row; anything else
# must refuse the whole chunk rather than infer success.

APPLY="$SCRIPTS_DIR/lobster-mvp/apply-verdicts.sh"

setup() {
  setup_tmp_env
  export OPS_LOBSTER_APPLY_LOG="$TEST_TMPDIR/lobster-apply.jsonl"
  export ADMIN_API_SH="$TEST_TMPDIR/muso-admin-api.sh"
  export CV_APPLY_CHUNK_SIZE=50
}

teardown() {
  teardown_tmp_env
}

# Stub the admin API with a fixed response envelope, exactly as
# muso-admin-api.sh emits it: {"http_status": <code>, "body": <parsed json>}.
stub_api() {
  cat > "$ADMIN_API_SH" <<STUB
#!/usr/bin/env bash
cat <<'RESP'
$1
RESP
exit 0
STUB
  chmod +x "$ADMIN_API_SH"
}

# Three would_approve rows, written to a file the runs read as stdin.
input_three() {
  jq -nc '{would_approve: [{cr_id:"cr-1"},{cr_id:"cr-2"},{cr_id:"cr-3"}], would_uvn: []}' \
    > "$TEST_TMPDIR/input.json"
}

# Run apply-verdicts in real-apply mode against the fixture.
run_apply() {
  input_three
  run bash -c "bash '$APPLY' false < '$TEST_TMPDIR/input.json'"
}

@test "200: only the ids the backend says moved are counted landed" {
  # cr-2 lost a race, cr-3 was an illegal transition. The old code counted all
  # three as landed because the status was 200.
  stub_api '{"http_status":200,"body":{"result":"ok","code":200,"data":{
    "updated":1,"updatedIds":["cr-1"],
    "skippedIds":["cr-2","cr-3"],
    "skipped":[{"id":"cr-2","reason":"lost_race"},{"id":"cr-3","reason":"illegal_transition"}],
    "failedIds":[]}}}'

  run_apply
  [ "$status" -eq 0 ]

  landed=$(echo "$output" | jq -c '.apply.landed_ids')
  [ "$landed" = '["cr-1"]' ]
  [ "$(echo "$output" | jq '.apply.landed')" -eq 1 ]
  [ "$(echo "$output" | jq '.apply.refused')" -eq 2 ]
}

@test "200: each refused row carries the backend's own reason" {
  stub_api '{"http_status":200,"body":{"result":"ok","code":200,"data":{
    "updated":1,"updatedIds":["cr-1"],
    "skippedIds":["cr-2","cr-3"],
    "skipped":[{"id":"cr-2","reason":"lost_race"},{"id":"cr-3","reason":"illegal_transition"}],
    "failedIds":[]}}}'

  run_apply
  [ "$status" -eq 0 ]

  # illegal_transition is the one that matters operationally: it is what a
  # refused approved → user_verification_needed looks like.
  reason=$(echo "$output" | jq -r '.apply.refused_ids[] | select(.cr_id=="cr-3") | .reason')
  [ "$reason" = "illegal_transition" ]
  reason2=$(echo "$output" | jq -r '.apply.refused_ids[] | select(.cr_id=="cr-2") | .reason')
  [ "$reason2" = "lost_race" ]
}

@test "409 is a PARTIAL SUCCESS: its updatedIds are still landed" {
  # The refusal answer. Its report is spread across .body by the error handler
  # rather than nested under .body.data. Counting the whole chunk as refused
  # here would re-attempt two rows that already persisted.
  stub_api '{"http_status":409,"body":{"result":"error","code":409,
    "message":"credit request status change refused for 1 of 3",
    "updated":2,"updatedIds":["cr-1","cr-2"],
    "skippedIds":["cr-3"],
    "skipped":[{"id":"cr-3","reason":"seed_refused"}],
    "failedIds":["cr-3"]}}'

  run_apply
  [ "$status" -eq 0 ]

  [ "$(echo "$output" | jq -c '.apply.landed_ids')" = '["cr-1","cr-2"]' ]
  [ "$(echo "$output" | jq '.apply.landed')" -eq 2 ]
  [ "$(echo "$output" | jq '.apply.refused')" -eq 1 ]
  reason=$(echo "$output" | jq -r '.apply.refused_ids[0].reason')
  [ "$reason" = "seed_refused" ]
}

@test "a 200 whose body has no updatedIds refuses the WHOLE chunk" {
  # Fail closed. The write may have landed, but we cannot say for which rows,
  # so success is never inferred from a missing field.
  stub_api '{"http_status":200,"body":{"result":"ok","code":200,"data":{"something":"else"}}}'

  run_apply
  [ "$status" -eq 0 ]

  [ "$(echo "$output" | jq '.apply.landed')" -eq 0 ]
  [ "$(echo "$output" | jq '.apply.refused')" -eq 3 ]
  reason=$(echo "$output" | jq -r '.apply.refused_ids[0].reason')
  [ "$reason" = "unattributable_response_http_200" ]
}

@test "a non-JSON body refuses the whole chunk instead of crashing" {
  stub_api 'this is not json at all'

  run_apply
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq '.apply.landed')" -eq 0 ]
  [ "$(echo "$output" | jq '.apply.refused')" -eq 3 ]
}

@test "a 500 still refuses the whole chunk, tagged by status" {
  stub_api '{"http_status":500,"body":{"result":"error","code":500,"message":"boom"}}'

  run_apply
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq '.apply.landed')" -eq 0 ]
  [ "$(echo "$output" | jq -r '.apply.refused_ids[0].reason')" = "http_500" ]
}

@test "every targeted id is accounted for exactly once" {
  # landed + refused must equal what was attempted, or the truth floor is
  # under-reporting silently.
  stub_api '{"http_status":409,"body":{"result":"error","code":409,
    "updated":1,"updatedIds":["cr-2"],
    "skippedIds":["cr-1","cr-3"],
    "skipped":[{"id":"cr-1","reason":"seed_refused"},{"id":"cr-3","reason":"not_found"}],
    "failedIds":["cr-1"]}}'

  run_apply
  [ "$status" -eq 0 ]

  total=$(echo "$output" | jq '.apply.landed + .apply.refused')
  [ "$total" -eq 3 ]
  all=$(echo "$output" | jq -c '[(.apply.landed_ids[]), (.apply.refused_ids[].cr_id)] | sort')
  [ "$all" = '["cr-1","cr-2","cr-3"]' ]
}

@test "chunking: rows are attributed within their own chunk, not across the batch" {
  # Two chunks of 2 and 1. The stub answers identically for both, so the
  # second chunk must not inherit the first chunk's updatedIds.
  export CV_APPLY_CHUNK_SIZE=2
  stub_api '{"http_status":200,"body":{"result":"ok","code":200,"data":{
    "updated":1,"updatedIds":["cr-1"],
    "skippedIds":["cr-2"],
    "skipped":[{"id":"cr-2","reason":"lost_race"}],
    "failedIds":[]}}}'

  run_apply
  [ "$status" -eq 0 ]

  # Chunk 1 = [cr-1, cr-2] → cr-1 lands. Chunk 2 = [cr-3] → the report names
  # cr-1, which is not in this chunk, so nothing lands and cr-3 is refused.
  [ "$(echo "$output" | jq -c '.apply.landed_ids')" = '["cr-1"]' ]
  [ "$(echo "$output" | jq '.apply.refused')" -eq 2 ]
  all=$(echo "$output" | jq -c '[(.apply.landed_ids[]), (.apply.refused_ids[].cr_id)] | sort')
  [ "$all" = '["cr-1","cr-2","cr-3"]' ]
}

@test "dry-run intercept is still refused, not attributed" {
  stub_api '{"http_status":200,"dryRun":true,"body":null,"wouldHaveExecuted":true}'

  run_apply
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq '.apply.landed')" -eq 0 ]
  [ "$(echo "$output" | jq -r '.apply.refused_ids[0].reason')" = "dry_run_intercepted" ]
}
