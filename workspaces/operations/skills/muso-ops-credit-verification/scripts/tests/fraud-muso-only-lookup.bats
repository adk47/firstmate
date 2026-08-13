#!/usr/bin/env bats
bats_require_minimum_version 1.5.0
load helpers

# Tests for lib/fraud-muso-only-lookup.sh — the fail-soft batched Trino lookup
# behind the muso_only fraud factor.
#
# Regression anchor (2026-06-11): the rp CTE referenced `profile_id` directly
# on matvw_catalog_profile, but that table's ID column is `_id` (`profile_id`
# came from the saved query's dropped `mp` claiming CTE, joined
# ON profile_id=_id). Live Trino rejected the query on EVERY production run
# ("Column 'profile_id' cannot be resolved") and the helper fail-softed to
# available:false — the fraud scorer ran without the muso_only factor since
# shadow went live. The stubbed-CSV tests never caught it because no test
# asserted on the GENERATED SQL. These do.
#
# Stubbing strategy: TRINO_QUERY_SH points at a fake that dumps the SQL it
# receives on stdin to $TEST_TMPDIR/sql.txt, so tests can assert on the query
# text without a cluster. No network, no kubectl.

LOOKUP="$SCRIPTS_DIR/lib/fraud-muso-only-lookup.sh"
P1="11111111-1111-1111-1111-111111111111"
P2="22222222-2222-2222-2222-222222222222"

setup() {
  setup_tmp_env
  [[ -f "$LOOKUP" ]] || { echo "LOOKUP missing: $LOOKUP" >&2; return 1; }

  export SQL_DUMP="$TEST_TMPDIR/sql.txt"

  # Healthy stub: capture SQL, emit one saved-query-shaped CSV row for P1.
  # 80.5, not 80.0: jq 1.6 re-serializes 80.0 as "80" while 1.7 keeps "80.0",
  # so a trailing-.0 value makes the happy-path assertion jq-version-dependent.
  export TRINO_OK="$TEST_TMPDIR/trino-ok.sh"
  cat > "$TRINO_OK" <<STUB
#!/usr/bin/env bash
cat > "$SQL_DUMP"
printf '"%s","80.5"\n' "$P1"
exit 0
STUB
  chmod +x "$TRINO_OK"

  # Healthy-empty stub: capture SQL, zero rows (the COMMON clean case).
  export TRINO_EMPTY="$TEST_TMPDIR/trino-empty.sh"
  cat > "$TRINO_EMPTY" <<STUB
#!/usr/bin/env bash
cat > "$SQL_DUMP"
exit 0
STUB
  chmod +x "$TRINO_EMPTY"

  # Failing stub: the live failure shape — rc=1 with the error on stderr.
  export TRINO_FAIL="$TEST_TMPDIR/trino-fail.sh"
  cat > "$TRINO_FAIL" <<'STUB'
#!/usr/bin/env bash
cat >/dev/null
echo "Query 20260611_040201 failed: line 7:9: Column 'profile_id' cannot be resolved" >&2
exit 1
STUB
  chmod +x "$TRINO_FAIL"
}
teardown() { teardown_tmp_env; }

# ────────────────── generated SQL (the 2026-06-11 regression) ──────────────────

@test "SQL: rp CTE filters matvw_catalog_profile on _id, not profile_id" {
  run --separate-stderr env TRINO_QUERY_SH="$TRINO_OK" "$LOOKUP" "$P1,$P2"
  [ "$status" -eq 0 ]
  [[ -s "$SQL_DUMP" ]]
  # "and _id in" — anchored so it can't substring-match the buggy
  # "and profile_id in" form.
  grep -q "and _id in ('$P1','$P2')" "$SQL_DUMP"
  # The buggy form must never come back: a bare profile_id IN-filter against
  # matvw_catalog_profile (where the column is _id). `run !` (bats >=1.5), not
  # bare `! grep`: bash ignores a failed `!`-negated command unless it is the
  # test's last line, so the bare form silently stops guarding if another
  # assertion is ever appended below it.
  run ! grep -qE "and profile_id in \(" "$SQL_DUMP"
}

@test "SQL: rp CTE aliases _id as profile_id for the downstream joins" {
  run --separate-stderr env TRINO_QUERY_SH="$TRINO_OK" "$LOOKUP" "$P1"
  [ "$status" -eq 0 ]
  grep -q "_id as profile_id" "$SQL_DUMP"
}

# ────────────────────────── output contract guards ──────────────────────────

@test "happy path: CSV row parses into available:true data map" {
  run --separate-stderr env TRINO_QUERY_SH="$TRINO_OK" "$LOOKUP" "$P1"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.available')" = "true" ]
  [ "$(printf '%s' "$output" | jq -r --arg p "$P1" '.data[$p]')" = "80.5" ]
}

@test "healthy zero-row result stays available:true with empty data" {
  run --separate-stderr env TRINO_QUERY_SH="$TRINO_EMPTY" "$LOOKUP" "$P1"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -c '.')" = '{"available":true,"data":{}}' ]
}

@test "trino failure: available:false, exit 0, and trino's own stderr is surfaced" {
  run --separate-stderr env TRINO_QUERY_SH="$TRINO_FAIL" "$LOOKUP" "$P1"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.available')" = "false" ]
  # The fail-soft diagnostic must carry the underlying trino error, not just
  # "exited rc=1" — swallowing it is how the column bug stayed invisible.
  [[ "$stderr" == *"UNAVAILABLE this run"* ]]
  [[ "$stderr" == *"Column 'profile_id' cannot be resolved"* ]]
  # The reason now also rides IN-BAND on stdout (fraud-issue-scorer-
  # followups.md §1 item 3) — a consumer that never sees stderr (the run
  # summary) must still be able to surface WHY.
  reason=$(printf '%s' "$output" | jq -r '.reason')
  [[ "$reason" == *"Column 'profile_id' cannot be resolved"* ]]
}

# ───────────────────── daily snapshot: hit / miss / stale / malformed ─────────────────────
# fraud-muso-only-snapshot-writer.sh's daily cron materializes
# {generated_at, data:{profileId:pct}} to CV_FRAUD_MUSO_SNAPSHOT_FILE. The
# lookup helper reads it FIRST, falling back to live Trino on any miss —
# fraud-issue-scorer-followups.md §1.

write_snapshot() {
  # write_snapshot <path> <generated_at> <profile_id> <pct>
  jq -n --arg ts "$2" --arg p "$3" --argjson pct "$4" \
    '{generated_at:$ts, data:{($p):$pct}}' > "$1"
}

@test "snapshot hit: fresh snapshot is served, NO live Trino call" {
  local snap="$TEST_TMPDIR/snapshot.json"
  write_snapshot "$snap" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$P1" 42.5
  # TRINO_QUERY_SH points at a stub that would FAIL the test if invoked
  # (writes a sentinel file the SQL_DUMP-based assertion below checks for).
  local sentinel="$TEST_TMPDIR/trino-was-called"
  local trino_sentinel="$TEST_TMPDIR/trino-sentinel.sh"
  cat > "$trino_sentinel" <<STUB
#!/usr/bin/env bash
touch "$sentinel"
cat >/dev/null
exit 1
STUB
  chmod +x "$trino_sentinel"

  run --separate-stderr env CV_FRAUD_MUSO_SNAPSHOT_FILE="$snap" TRINO_QUERY_SH="$trino_sentinel" "$LOOKUP" "$P1"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -c '.')" = '{"available":true,"data":{"'"$P1"'":42.5}}' ]
  [[ "$stderr" == *"serving from snapshot"* ]]
  [[ ! -e "$sentinel" ]]
}

@test "snapshot hit: only requested profile IDs are returned from a larger snapshot" {
  local snap="$TEST_TMPDIR/snapshot.json"
  jq -n --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg p1 "$P1" --arg p2 "$P2" \
    '{generated_at:$ts, data:{($p1):10.0,($p2):90.0,"33333333-3333-3333-3333-333333333333":50.0}}' > "$snap"
  run --separate-stderr env CV_FRAUD_MUSO_SNAPSHOT_FILE="$snap" "$LOOKUP" "$P1"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -c '.')" = '{"available":true,"data":{"'"$P1"'":10.0}}' ]
}

@test "snapshot miss (no file) ⇒ falls back to live Trino" {
  run --separate-stderr env CV_FRAUD_MUSO_SNAPSHOT_FILE="$TEST_TMPDIR/does-not-exist.json" TRINO_QUERY_SH="$TRINO_OK" "$LOOKUP" "$P1"
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"no snapshot at"* ]]
  [ "$(printf '%s' "$output" | jq -r '.available')" = "true" ]
  [ "$(printf '%s' "$output" | jq -r --arg p "$P1" '.data[$p]')" = "80.5" ]
}

@test "stale snapshot ⇒ falls back to live Trino" {
  local snap="$TEST_TMPDIR/snapshot.json"
  write_snapshot "$snap" "$(past_touch_stamp_iso 200000)" "$P1" 42.5
  run --separate-stderr env CV_FRAUD_MUSO_SNAPSHOT_FILE="$snap" TRINO_QUERY_SH="$TRINO_OK" "$LOOKUP" "$P1"
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"is stale"* ]]
  [ "$(printf '%s' "$output" | jq -r '.available')" = "true" ]
  # Live stub's value (80.5), not the stale snapshot's (42.5).
  [ "$(printf '%s' "$output" | jq -r --arg p "$P1" '.data[$p]')" = "80.5" ]
}

@test "malformed snapshot ⇒ treated as a MISS (falls back to live), never as 'all clean'" {
  local snap="$TEST_TMPDIR/snapshot.json"
  # Missing the {generated_at,data} shape entirely.
  printf '{"unexpected":"shape"}' > "$snap"
  run --separate-stderr env CV_FRAUD_MUSO_SNAPSHOT_FILE="$snap" TRINO_QUERY_SH="$TRINO_OK" "$LOOKUP" "$P1"
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"is malformed"* ]]
  # Must reach the live stub's data, NOT silently report available:true/data:{}
  # as if the malformed snapshot were a genuine healthy-empty result.
  [ "$(printf '%s' "$output" | jq -r '.available')" = "true" ]
  [ "$(printf '%s' "$output" | jq -r --arg p "$P1" '.data[$p]')" = "80.5" ]
}

@test "malformed snapshot (not valid JSON at all) ⇒ treated as a MISS" {
  local snap="$TEST_TMPDIR/snapshot.json"
  printf 'not json' > "$snap"
  run --separate-stderr env CV_FRAUD_MUSO_SNAPSHOT_FILE="$snap" TRINO_QUERY_SH="$TRINO_OK" "$LOOKUP" "$P1"
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"is malformed"* ]]
  [ "$(printf '%s' "$output" | jq -r '.available')" = "true" ]
}

# ─────────── snapshot: future-dated timestamps and max-age validation ───────────
# A future generated_at makes AGE_HOURS negative, which always satisfies the
# `<= MAX_AGE` test — so without an explicit guard a clock jump or a
# hand-edited/restored snapshot would be trusted FOREVER (until its timestamp
# arrived), even while every later writer run failed. Each rejection test below
# is paired with a stability test proving the guard did not simply reject
# everything nearby.

@test "future-dated snapshot beyond the skew ⇒ MISS, falls back to live Trino" {
  local snap="$TEST_TMPDIR/snapshot.json"
  # 2h ahead. Under the old `AGE_HOURS <= 36` test this scored -2h and was
  # served as if fresh; it must now be rejected.
  write_snapshot "$snap" "$(future_stamp_iso 7200)" "$P1" 42.5
  run --separate-stderr env CV_FRAUD_MUSO_SNAPSHOT_FILE="$snap" TRINO_QUERY_SH="$TRINO_OK" "$LOOKUP" "$P1"
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"dated in the future"* ]]
  # The live stub's 80.5 — NOT the future-dated snapshot's 42.5.
  [ "$(printf '%s' "$output" | jq -r --arg p "$P1" '.data[$p]')" = "80.5" ]
}

@test "snapshot within the future-skew allowance is still SERVED" {
  local snap="$TEST_TMPDIR/snapshot.json"
  # 60s ahead: inside the 300s allowance, so a writer/reader second-boundary
  # race must NOT cost us the snapshot. This is the stability half of the pair
  # above — without it, "reject the future" could silently mean "reject ~now".
  write_snapshot "$snap" "$(future_stamp_iso 60)" "$P1" 42.5
  run --separate-stderr env CV_FRAUD_MUSO_SNAPSHOT_FILE="$snap" TRINO_QUERY_SH="$TRINO_OK" "$LOOKUP" "$P1"
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"serving from snapshot"* ]]
  [ "$(printf '%s' "$output" | jq -r --arg p "$P1" '.data[$p]')" = "42.5" ]
}

@test "non-integer max-age override ⇒ warns and applies the 36h default (fresh snapshot still served)" {
  local snap="$TEST_TMPDIR/snapshot.json"
  write_snapshot "$snap" "$(past_touch_stamp_iso 3600)" "$P1" 42.5
  # Bash arithmetic reads "36h" as a variable name ⇒ 0, which would make this
  # 1h-old snapshot "stale" and quietly disable the feature entirely.
  run --separate-stderr env CV_FRAUD_MUSO_SNAPSHOT_FILE="$snap" \
    CV_FRAUD_MUSO_SNAPSHOT_MAX_AGE_HOURS="36h" TRINO_QUERY_SH="$TRINO_OK" "$LOOKUP" "$P1"
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"is not a non-negative integer"* ]]
  [[ "$stderr" == *"serving from snapshot"* ]]
  [ "$(printf '%s' "$output" | jq -r --arg p "$P1" '.data[$p]')" = "42.5" ]
}

@test "non-integer max-age override still enforces staleness (default, not infinity)" {
  local snap="$TEST_TMPDIR/snapshot.json"
  # Discrimination pair for the test above: falling back to the default must
  # mean 36h, not "trust anything".
  write_snapshot "$snap" "$(past_touch_stamp_iso 200000)" "$P1" 42.5
  run --separate-stderr env CV_FRAUD_MUSO_SNAPSHOT_FILE="$snap" \
    CV_FRAUD_MUSO_SNAPSHOT_MAX_AGE_HOURS="36h" TRINO_QUERY_SH="$TRINO_OK" "$LOOKUP" "$P1"
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"is stale"* ]]
  [ "$(printf '%s' "$output" | jq -r --arg p "$P1" '.data[$p]')" = "80.5" ]
}

@test "negative max-age override is rejected (would otherwise stale-out every snapshot)" {
  local snap="$TEST_TMPDIR/snapshot.json"
  write_snapshot "$snap" "$(past_touch_stamp_iso 3600)" "$P1" 42.5
  run --separate-stderr env CV_FRAUD_MUSO_SNAPSHOT_FILE="$snap" \
    CV_FRAUD_MUSO_SNAPSHOT_MAX_AGE_HOURS="-1" TRINO_QUERY_SH="$TRINO_OK" "$LOOKUP" "$P1"
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"is not a non-negative integer"* ]]
  [[ "$stderr" == *"serving from snapshot"* ]]
}

@test "snapshot projection keeps a legitimate 0.0 percentage (jq // would drop it)" {
  # 0.0 is a real answer — "this profile has no muso-only popularity at all" —
  # and is exactly the value a `//`-style default silently swallows, since jq
  # treats 0 as falsy. Dropping it would degrade a scored-clean profile into
  # "no data" and quietly change the scorer's input.
  local snap="$TEST_TMPDIR/snapshot.json"
  write_snapshot "$snap" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$P1" 0
  run --separate-stderr env CV_FRAUD_MUSO_SNAPSHOT_FILE="$snap" TRINO_QUERY_SH="$TRINO_OK" "$LOOKUP" "$P1"
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"serving from snapshot"* ]]
  [ "$(printf '%s' "$output" | jq -r --arg p "$P1" '.data | has($p)')" = "true" ]
  [ "$(printf '%s' "$output" | jq -r --arg p "$P1" '.data[$p]')" = "0" ]
}

@test "snapshot projection omits requested IDs the snapshot does not carry" {
  # Absent ≠ zero: a profile with no snapshot row must simply not appear, the
  # same as the live path's behavior for a profile with no catalog rows.
  local snap="$TEST_TMPDIR/snapshot.json"
  write_snapshot "$snap" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$P1" 42.5
  run --separate-stderr env CV_FRAUD_MUSO_SNAPSHOT_FILE="$snap" TRINO_QUERY_SH="$TRINO_OK" "$LOOKUP" "$P1" "$P2"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.data | length')" = "1" ]
  [ "$(printf '%s' "$output" | jq -r --arg p "$P2" '.data | has($p)')" = "false" ]
}

# ───────────── snapshot: non-numeric values INVERT the signal, not just degrade it ─────────────
# jq's total ordering sorts all strings ABOVE all numbers, so `"x" > 50` is
# true. score-fraud-signals.sh:281 fires the muso_only factor on
# `($muso_pct != null) and ($muso_pct > $musoPct)` — both arms of which a
# string satisfies. So a corrupt snapshot value does not merely lose the
# signal, it ADDS a fraud factor and can tip credits into the fraud bucket.
# The whole snapshot must therefore be rejected, not partially trusted.

@test "jq really does sort strings above numbers (the premise of the tests below)" {
  # Pin the language behavior the guard exists for: if a future jq ever made
  # this comparison false or an error, the guard's rationale changes and
  # whoever reads these tests should be told by a failure, not by silence.
  [ "$(jq -n '"not-a-number" > 50')" = "true" ]
}

@test "snapshot with a non-numeric value ⇒ MISS, never served as available:true" {
  local snap="$TEST_TMPDIR/snapshot.json"
  jq -n --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg p "$P1" \
    '{generated_at:$ts, data:{($p):"not-a-number"}}' > "$snap"
  run --separate-stderr env CV_FRAUD_MUSO_SNAPSHOT_FILE="$snap" TRINO_QUERY_SH="$TRINO_OK" "$LOOKUP" "$P1"
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"is malformed"* ]]
  # Must reach live Trino's 80.5 — and must NOT carry the string through.
  [ "$(printf '%s' "$output" | jq -r --arg p "$P1" '.data[$p]')" = "80.5" ]
  [ "$(printf '%s' "$output" | jq -r --arg p "$P1" '.data[$p] | type')" = "number" ]
}

@test "one corrupt value invalidates the WHOLE snapshot, not just its own entry" {
  # Partial trust would leave the operator with a half-live/half-snapshot
  # result and no signal that the file is corrupt. A snapshot we cannot trust
  # in one place is not trusted anywhere.
  local snap="$TEST_TMPDIR/snapshot.json"
  jq -n --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg p1 "$P1" --arg p2 "$P2" \
    '{generated_at:$ts, data:{($p1):42.5, ($p2):"corrupt"}}' > "$snap"
  # P1's own value is perfectly good, but the snapshot is still rejected.
  run --separate-stderr env CV_FRAUD_MUSO_SNAPSHOT_FILE="$snap" TRINO_QUERY_SH="$TRINO_OK" "$LOOKUP" "$P1"
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"is malformed"* ]]
  [ "$(printf '%s' "$output" | jq -r --arg p "$P1" '.data[$p]')" = "80.5" ]
}

@test "null and boolean snapshot values are rejected too, not just strings" {
  # `null` is the sharp one: the projection's `!= null` filter would silently
  # drop it, so without the type check it reads as "profile absent" rather
  # than "file corrupt" — a quiet wrong answer instead of a loud fallback.
  for bad in 'null' 'true' '[]' '{}'; do
    local snap="$TEST_TMPDIR/snapshot-$RANDOM.json"
    jq -n --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg p "$P1" --argjson v "$bad" \
      '{generated_at:$ts, data:{($p):$v}}' > "$snap"
    run --separate-stderr env CV_FRAUD_MUSO_SNAPSHOT_FILE="$snap" TRINO_QUERY_SH="$TRINO_OK" "$LOOKUP" "$P1"
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"is malformed"* ]] || { echo "value $bad was NOT rejected" >&2; return 1; }
  done
}

@test "an all-numeric snapshot is still served (the guard rejects corruption, not everything)" {
  # Stability partner: integers, floats, zero and negatives must all survive.
  local snap="$TEST_TMPDIR/snapshot.json"
  jq -n --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg p1 "$P1" --arg p2 "$P2" \
    '{generated_at:$ts, data:{($p1):0, ($p2):100}}' > "$snap"
  run --separate-stderr env CV_FRAUD_MUSO_SNAPSHOT_FILE="$snap" TRINO_QUERY_SH="$TRINO_OK" "$LOOKUP" "$P1" "$P2"
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"serving from snapshot"* ]]
  [ "$(printf '%s' "$output" | jq -r --arg p "$P1" '.data[$p]')" = "0" ]
  [ "$(printf '%s' "$output" | jq -r --arg p "$P2" '.data[$p]')" = "100" ]
}

# ───────────── snapshot: the 0..100 range is an invariant, not a style rule ─────────────
# The writer's percentage is mathematically bounded — its numerator
# `sum(if(is_muso_only, track_popularity, 0))` is a subset-sum of its
# denominator `sum(track_popularity)`, kept positive by `having sum(...) > N`.
# So an out-of-range number is corruption exactly like a string, and it fails
# the same two ways: 101 fabricates a factor (`101 > 50`), -1 suppresses a
# real one. Header line 41 documents the range; these enforce it.

@test "out-of-range snapshot values are rejected (101 fabricates, -1 suppresses)" {
  for bad in 101 -1 1000000; do
    local snap="$TEST_TMPDIR/snapshot-oor-$bad.json"
    jq -n --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg p "$P1" --argjson v "$bad" \
      '{generated_at:$ts, data:{($p):$v}}' > "$snap"
    run --separate-stderr env CV_FRAUD_MUSO_SNAPSHOT_FILE="$snap" TRINO_QUERY_SH="$TRINO_OK" "$LOOKUP" "$P1"
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"is malformed"* ]] || { echo "value $bad was NOT rejected" >&2; return 1; }
    # And the live value is what reaches the scorer, not the corrupt one.
    [ "$(printf '%s' "$output" | jq -r --arg p "$P1" '.data[$p]')" = "80.5" ]
  done
}

@test "a literal Infinity is rejected — jq coerces it to a FINITE 1.797e308" {
  # Only the range test catches this one: jq parses `Infinity` in input JSON
  # as the largest finite double, so `type == "number"` passes. (`nan` is
  # coerced to null instead and is caught by the type test.)
  local snap="$TEST_TMPDIR/snapshot-inf.json"
  printf '{"generated_at":"%s","data":{"%s":Infinity}}' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$P1" > "$snap"
  run --separate-stderr env CV_FRAUD_MUSO_SNAPSHOT_FILE="$snap" TRINO_QUERY_SH="$TRINO_OK" "$LOOKUP" "$P1"
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"is malformed"* ]]
  [ "$(printf '%s' "$output" | jq -r --arg p "$P1" '.data[$p]')" = "80.5" ]
}

@test "the 0 and 100 boundaries are INSIDE the range and still served" {
  # Boundary partner for the rejection tests: the bound is inclusive, so a
  # profile at exactly 0% or exactly 100% muso-only must not be thrown away.
  local snap="$TEST_TMPDIR/snapshot-bounds.json"
  jq -n --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg p1 "$P1" --arg p2 "$P2" \
    '{generated_at:$ts, data:{($p1):0, ($p2):100}}' > "$snap"
  run --separate-stderr env CV_FRAUD_MUSO_SNAPSHOT_FILE="$snap" TRINO_QUERY_SH="$TRINO_OK" "$LOOKUP" "$P1" "$P2"
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"serving from snapshot"* ]]
  [ "$(printf '%s' "$output" | jq -r --arg p "$P1" '.data[$p]')" = "0" ]
  [ "$(printf '%s' "$output" | jq -r --arg p "$P2" '.data[$p]')" = "100" ]
}
