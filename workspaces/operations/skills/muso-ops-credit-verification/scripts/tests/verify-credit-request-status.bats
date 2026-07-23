#!/usr/bin/env bats
bats_require_minimum_version 1.5.0
load helpers

# Tests for verify-credit-request-status.sh — the Trino readback that closes
# the "PUT /admin/credit-requests returns 200 even when zero rows
# transitioned" gap (backend transition allowlist silently skips rows).
#
# Stubbing strategy: TRINO_QUERY_SH points at a fake that emits canned
# quoted-CSV (id,status per row, no header) matching trino-query.sh's real
# output shape. No network, no kubectl, no real trino.

WRAPPER="$SCRIPTS_DIR/verify-credit-request-status.sh"
ID1="11111111-1111-1111-1111-111111111111"
ID2="22222222-2222-2222-2222-222222222222"
ID3="33333333-3333-3333-3333-333333333333"

setup() {
    setup_tmp_env
    [[ -x "$WRAPPER" ]] || { echo "WRAPPER missing or not executable: $WRAPPER" >&2; return 1; }

    export CV_RESULTS_PATH="$TEST_TMPDIR/results.jsonl"

    # All-matched stub: ID1 and ID2 both come back user_verification_needed.
    TRINO_ALL_MATCHED="$TEST_TMPDIR/trino-all-matched.sh"
    cat > "$TRINO_ALL_MATCHED" <<STUB
#!/usr/bin/env bash
cat >/dev/null
printf '"%s","user_verification_needed"\n' "$ID1"
printf '"%s","user_verification_needed"\n' "$ID2"
STUB
    chmod +x "$TRINO_ALL_MATCHED"
    export TRINO_ALL_MATCHED

    # One-mismatch stub: ID1 verification_needed, ID2 still "unverified".
    TRINO_ONE_MISMATCH="$TEST_TMPDIR/trino-one-mismatch.sh"
    cat > "$TRINO_ONE_MISMATCH" <<STUB
#!/usr/bin/env bash
cat >/dev/null
printf '"%s","user_verification_needed"\n' "$ID1"
printf '"%s","unverified"\n' "$ID2"
STUB
    chmod +x "$TRINO_ONE_MISMATCH"
    export TRINO_ONE_MISMATCH

    # Missing-row stub: only ID1 comes back at all; ID2 absent entirely.
    TRINO_MISSING_ROW="$TEST_TMPDIR/trino-missing-row.sh"
    cat > "$TRINO_MISSING_ROW" <<STUB
#!/usr/bin/env bash
cat >/dev/null
printf '"%s","user_verification_needed"\n' "$ID1"
STUB
    chmod +x "$TRINO_MISSING_ROW"
    export TRINO_MISSING_ROW

    # Failing stub: trino-query.sh exits non-zero (e.g. cluster error).
    TRINO_FAIL="$TEST_TMPDIR/trino-fail.sh"
    cat > "$TRINO_FAIL" <<'STUB'
#!/usr/bin/env bash
cat >/dev/null
echo "Query failed: connection refused" >&2
exit 2
STUB
    chmod +x "$TRINO_FAIL"
    export TRINO_FAIL

    # Empty-output stub: rc=0 but zero bytes on stdout.
    TRINO_EMPTY="$TEST_TMPDIR/trino-empty.sh"
    cat > "$TRINO_EMPTY" <<'STUB'
#!/usr/bin/env bash
cat >/dev/null
exit 0
STUB
    chmod +x "$TRINO_EMPTY"
    export TRINO_EMPTY

    # Invocation logger — asserts the stub was (not) called.
    export TRINO_CALL_LOG="$TEST_TMPDIR/trino-calls.log"
    TRINO_LOGGING_ALL_MATCHED="$TEST_TMPDIR/trino-logging-all-matched.sh"
    cat > "$TRINO_LOGGING_ALL_MATCHED" <<STUB
#!/usr/bin/env bash
echo "called" >> "$TRINO_CALL_LOG"
cat >/dev/null
printf '"%s","user_verification_needed"\n' "$ID1"
STUB
    chmod +x "$TRINO_LOGGING_ALL_MATCHED"
    export TRINO_LOGGING_ALL_MATCHED
}

teardown() { teardown_tmp_env; }

# --- Happy path ---

@test "all ids matched -> exit 0, correct JSON" {
    run --separate-stderr env TRINO_QUERY_SH="$TRINO_ALL_MATCHED" \
        bash "$WRAPPER" --expected user_verification_needed --ids "$ID1,$ID2"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.expected == "user_verification_needed" and .matched == 2 and .mismatched == []' >/dev/null
}

# --- Mismatch classification ---

@test "one mismatched status -> exit 1, mismatched entry carries actual" {
    run --separate-stderr env TRINO_QUERY_SH="$TRINO_ONE_MISMATCH" \
        bash "$WRAPPER" --expected user_verification_needed --ids "$ID1,$ID2"
    [ "$status" -eq 1 ]
    echo "$output" | jq -e '.matched == 1' >/dev/null
    echo "$output" | jq -e --arg id "$ID2" '.mismatched == [{id:$id, actual:"unverified"}]' >/dev/null
}

@test "id missing from CSV -> exit 1, actual missing" {
    run --separate-stderr env TRINO_QUERY_SH="$TRINO_MISSING_ROW" \
        bash "$WRAPPER" --expected user_verification_needed --ids "$ID1,$ID2"
    [ "$status" -eq 1 ]
    echo "$output" | jq -e '.matched == 1' >/dev/null
    echo "$output" | jq -e --arg id "$ID2" '.mismatched == [{id:$id, actual:"missing"}]' >/dev/null
}

# --- Unverifiable paths ---

@test "trino exits non-zero -> exit 3 + banner on stderr" {
    run --separate-stderr env TRINO_QUERY_SH="$TRINO_FAIL" \
        bash "$WRAPPER" --expected user_verification_needed --ids "$ID1"
    [ "$status" -eq 3 ]
    [[ "$stderr" == *"UNVERIFIABLE"* ]]
    [[ "$stderr" == *"Do NOT treat this write as"* ]]
}

@test "empty output with ids requested -> exit 3" {
    run --separate-stderr env TRINO_QUERY_SH="$TRINO_EMPTY" \
        bash "$WRAPPER" --expected user_verification_needed --ids "$ID1"
    [ "$status" -eq 3 ]
    [[ "$stderr" == *"UNVERIFIABLE"* ]]
}

# --- Validation ---

@test "invalid uuid -> exit 2, trino stub NOT invoked" {
    run --separate-stderr env TRINO_QUERY_SH="$TRINO_LOGGING_ALL_MATCHED" \
        bash "$WRAPPER" --expected user_verification_needed --ids "not-a-uuid"
    [ "$status" -eq 2 ]
    [[ "$stderr" == *"non-UUID entry"* ]]
    [ ! -f "$TRINO_CALL_LOG" ]
}

@test "missing --expected -> exit 2" {
    run bash "$WRAPPER" --ids "$ID1"
    [ "$status" -eq 2 ]
    [[ "$output" == *"--expected is required"* ]]
}

@test "invalid --expected enum -> exit 2" {
    run bash "$WRAPPER" --expected bogus_status --ids "$ID1"
    [ "$status" -eq 2 ]
    [[ "$output" == *"not a valid status enum value"* ]]
}

@test "missing --ids -> exit 2" {
    run bash "$WRAPPER" --expected user_verification_needed
    [ "$status" -eq 2 ]
    [[ "$output" == *"--ids is required"* ]]
}

@test "unknown argument -> exit 2" {
    run bash "$WRAPPER" --expected user_verification_needed --ids "$ID1" --bogus foo
    [ "$status" -eq 2 ]
    [[ "$output" == *"unknown argument"* ]]
}

# --- Truth-floor results.jsonl ---

@test "results-jsonl row written on matched outcome" {
    run --separate-stderr env TRINO_QUERY_SH="$TRINO_ALL_MATCHED" \
        bash "$WRAPPER" --expected user_verification_needed --ids "$ID1,$ID2"
    [ "$status" -eq 0 ]
    [ -f "$CV_RESULTS_PATH" ]
    row=$(tail -n1 "$CV_RESULTS_PATH")
    echo "$row" | jq -e '.outcome == "readback_ok" and .matched == 2 and .method == "READBACK" and .intended_status == "user_verification_needed"' >/dev/null
}

@test "results-jsonl row written on mismatch outcome" {
    run --separate-stderr env TRINO_QUERY_SH="$TRINO_ONE_MISMATCH" \
        bash "$WRAPPER" --expected user_verification_needed --ids "$ID1,$ID2"
    [ "$status" -eq 1 ]
    row=$(tail -n1 "$CV_RESULTS_PATH")
    echo "$row" | jq -e '.outcome == "readback_mismatch" and .matched == 1' >/dev/null
}

@test "results-jsonl row written on unverifiable outcome" {
    run --separate-stderr env TRINO_QUERY_SH="$TRINO_FAIL" \
        bash "$WRAPPER" --expected user_verification_needed --ids "$ID1"
    [ "$status" -eq 3 ]
    row=$(tail -n1 "$CV_RESULTS_PATH")
    echo "$row" | jq -e '.outcome == "readback_unverifiable"' >/dev/null
}

@test "--results-line 0 writes nothing" {
    run --separate-stderr env TRINO_QUERY_SH="$TRINO_ALL_MATCHED" \
        bash "$WRAPPER" --expected user_verification_needed --ids "$ID1,$ID2" --results-line 0
    [ "$status" -eq 0 ]
    [ ! -f "$CV_RESULTS_PATH" ]
}
