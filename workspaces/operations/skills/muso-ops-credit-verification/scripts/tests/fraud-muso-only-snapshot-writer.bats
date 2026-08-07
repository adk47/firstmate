#!/usr/bin/env bats
bats_require_minimum_version 1.5.0
load helpers

# Tests for lib/fraud-muso-only-snapshot-writer.sh — the daily cron that
# materializes the muso-only fraud signal for ALL qualifying profiles so
# fraud-muso-only-lookup.sh can read a file instead of calling Trino in-loop.
#
# Regression anchor (the reason this file exists): the writer originally
# serialized its output with `jq -n --argjson data "$MAP"`. That map holds one
# entry per qualifying profile — unbounded — and Linux caps a SINGLE argv
# element at ~128KB (MAX_ARG_STRLEN), so past a few thousand profiles the exec
# fails with "Argument list too long" (E2BIG). The writer would then die before
# writing its first snapshot and every batch would keep falling back to the
# live Trino query this whole feature exists to remove — a failure that only
# appears at production scale and is invisible to a handful-of-rows test.
# score-fraud-signals.sh carries the same lesson from the 2026-06-10 shadow
# batch. "large map is written correctly" below is the test that discriminates.
#
# Stubbing strategy: TRINO_QUERY_SH points at a fake that consumes the SQL on
# stdin and emits saved-query-shaped CSV. No cluster, no network.

WRITER="$SCRIPTS_DIR/lib/fraud-muso-only-snapshot-writer.sh"
P1="11111111-1111-1111-1111-111111111111"
P2="22222222-2222-2222-2222-222222222222"

setup() {
  setup_tmp_env
  [[ -f "$WRITER" ]] || { echo "WRITER missing: $WRITER" >&2; return 1; }

  export SNAP="$TEST_TMPDIR/snapshot.json"

  # Healthy stub: two saved-query-shaped rows.
  export TRINO_OK="$TEST_TMPDIR/trino-ok.sh"
  cat > "$TRINO_OK" <<STUB
#!/usr/bin/env bash
cat >/dev/null
printf '"%s","80.5"\n' "$P1"
printf '"%s","12.25"\n' "$P2"
exit 0
STUB
  chmod +x "$TRINO_OK"

  # Failing stub: rc=1 with a Trino-shaped diagnostic on stderr.
  export TRINO_FAIL="$TEST_TMPDIR/trino-fail.sh"
  cat > "$TRINO_FAIL" <<'STUB'
#!/usr/bin/env bash
cat >/dev/null
echo "Column 'profile_id' cannot be resolved" >&2
exit 1
STUB
  chmod +x "$TRINO_FAIL"
}

teardown() { teardown_tmp_env; }

# Count leftover mktemp fragments beside the snapshot target.
count_temp_fragments() {
  find "$TEST_TMPDIR" -maxdepth 1 -name 'snapshot.json.*' | wc -l | tr -d '[:space:]'
}

@test "happy path: writes {generated_at,data} with every returned profile" {
  run --separate-stderr env CV_FRAUD_MUSO_SNAPSHOT_FILE="$SNAP" TRINO_QUERY_SH="$TRINO_OK" "$WRITER"
  [ "$status" -eq 0 ]
  [ -f "$SNAP" ]
  [ "$(jq -r '.data | length' "$SNAP")" = "2" ]
  [ "$(jq -r --arg p "$P1" '.data[$p]' "$SNAP")" = "80.5" ]
  [ "$(jq -r --arg p "$P2" '.data[$p]' "$SNAP")" = "12.25" ]
  # generated_at must be the ISO8601-Z shape fraud-muso-only-lookup.sh parses.
  [[ "$(jq -r '.generated_at' "$SNAP")" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]
}

@test "large map (>1MB, well past the ~128KB argv cap) is written correctly" {
  # THE E2BIG regression test. 30k profiles ≈ 1.3MB of map JSON: past Linux's
  # ~128KB per-argv-element cap AND past macOS's ~1MB total-args cap, so this
  # discriminates on either platform rather than only on the Linux CI runner.
  # Against the old `--argjson data "$MAP"` writer this fails with
  # "Argument list too long"; against the stdin-streaming writer it passes.
  local big="$TEST_TMPDIR/trino-big.sh"
  cat > "$big" <<'STUB'
#!/usr/bin/env bash
cat >/dev/null
awk 'BEGIN { for (i = 1; i <= 30000; i++) printf "\"%08d-0000-0000-0000-000000000000\",\"50.5\"\n", i }'
exit 0
STUB
  chmod +x "$big"

  run --separate-stderr env CV_FRAUD_MUSO_SNAPSHOT_FILE="$SNAP" TRINO_QUERY_SH="$big" "$WRITER"
  [ "$status" -eq 0 ]
  [[ "$stderr" != *"Argument list too long"* ]]
  [ "$(jq -r '.data | length' "$SNAP")" = "30000" ]
  [ "$(jq -r '.data["00000001-0000-0000-0000-000000000000"]' "$SNAP")" = "50.5" ]
  [ "$(jq -r '.data["00030000-0000-0000-0000-000000000000"]' "$SNAP")" = "50.5" ]
  # Guard the guard: if this payload ever stops clearing the argv cap the test
  # silently stops discriminating, so assert the size it is meant to exceed.
  [ "$(wc -c < "$SNAP")" -gt 1048576 ]
}

@test "trino failure leaves an existing snapshot untouched and exits non-zero" {
  printf '{"generated_at":"2026-01-01T00:00:00Z","data":{"%s":1.5}}\n' "$P1" > "$SNAP"
  run --separate-stderr env CV_FRAUD_MUSO_SNAPSHOT_FILE="$SNAP" TRINO_QUERY_SH="$TRINO_FAIL" "$WRITER"
  [ "$status" -ne 0 ]
  [[ "$stderr" == *"leaving existing snapshot"* ]]
  # The last good snapshot must survive — a failed refresh must never degrade
  # the reader to "no data", only to "older data".
  [ "$(jq -r --arg p "$P1" '.data[$p]' "$SNAP")" = "1.5" ]
}

@test "non-empty trino output that parses to zero rows is rejected as an error page" {
  printf '{"generated_at":"2026-01-01T00:00:00Z","data":{"%s":1.5}}\n' "$P1" > "$SNAP"
  local html="$TEST_TMPDIR/trino-html.sh"
  cat > "$html" <<'STUB'
#!/usr/bin/env bash
cat >/dev/null
echo "<html><body>502 Bad Gateway</body></html>"
exit 0
STUB
  chmod +x "$html"

  run --separate-stderr env CV_FRAUD_MUSO_SNAPSHOT_FILE="$SNAP" TRINO_QUERY_SH="$html" "$WRITER"
  [ "$status" -ne 0 ]
  # 1 non-blank row, 0 valid — the all-invalid end of the same guard.
  [[ "$stderr" == *"refusing to write an incomplete snapshot"* ]]
  [[ "$stderr" == *"only 0 of 1 non-blank"* ]]
  [ "$(jq -r --arg p "$P1" '.data[$p]' "$SNAP")" = "1.5" ]
}

# ── empty results: legitimate on a first run, anomalous over existing data ──
# An empty snapshot is NOT "unknown" to the reader — it is available:true with
# no entries, i.e. every queried profile reads as clean and the muso_only
# factor is suppressed for up to 36h. So "rc=0 with no rows" has to be split:
# a first run may publish it, a refresh over real data may not.

setup_empty_stub() {
  EMPTY_STUB="$TEST_TMPDIR/trino-empty.sh"
  cat > "$EMPTY_STUB" <<'STUB'
#!/usr/bin/env bash
cat >/dev/null
exit 0
STUB
  chmod +x "$EMPTY_STUB"
}

@test "first run with an empty result writes an empty snapshot" {
  # No prior file: rc=0 with no rows is a real "nothing qualifies" answer and
  # must be published, or the feature could never bootstrap.
  setup_empty_stub
  [ ! -e "$SNAP" ]
  run --separate-stderr env CV_FRAUD_MUSO_SNAPSHOT_FILE="$SNAP" TRINO_QUERY_SH="$EMPTY_STUB" "$WRITER"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.data | length' "$SNAP")" = "0" ]
}

@test "an empty result does NOT overwrite a snapshot that holds data" {
  # The dangerous direction: an upstream matview briefly empty, or a truncated
  # result, would otherwise publish a confident "all clean" over real data.
  setup_empty_stub
  printf '{"generated_at":"2026-01-01T00:00:00Z","data":{"%s":1.5}}\n' "$P1" > "$SNAP"
  run --separate-stderr env CV_FRAUD_MUSO_SNAPSHOT_FILE="$SNAP" TRINO_QUERY_SH="$EMPTY_STUB" "$WRITER"
  [ "$status" -ne 0 ]
  [[ "$stderr" == *"refusing to overwrite it with an empty snapshot"* ]]
  [ "$(jq -r --arg p "$P1" '.data[$p]' "$SNAP")" = "1.5" ]
  [ "$(jq -r '.generated_at' "$SNAP")" = "2026-01-01T00:00:00Z" ]
}

@test "an empty result does NOT overwrite an UNPARSEABLE prior snapshot" {
  # Subtle half: the reader treats a malformed snapshot as a MISS and falls
  # back to live Trino (safe). Replacing it with {} would flip that to
  # "all clean" (unsafe), so corruption must not be upgraded into confidence.
  setup_empty_stub
  printf 'not json at all' > "$SNAP"
  run --separate-stderr env CV_FRAUD_MUSO_SNAPSHOT_FILE="$SNAP" TRINO_QUERY_SH="$EMPTY_STUB" "$WRITER"
  [ "$status" -ne 0 ]
  [[ "$stderr" == *"refusing to overwrite it with an empty snapshot"* ]]
  [ "$(cat "$SNAP")" = "not json at all" ]
}

@test "an empty result MAY overwrite a prior snapshot that is itself empty" {
  # Stability partner: the guard must not wedge the writer permanently once a
  # legitimate empty snapshot exists — re-publishing empty over empty is a no-op.
  setup_empty_stub
  printf '{"generated_at":"2026-01-01T00:00:00Z","data":{}}\n' > "$SNAP"
  run --separate-stderr env CV_FRAUD_MUSO_SNAPSHOT_FILE="$SNAP" TRINO_QUERY_SH="$EMPTY_STUB" "$WRITER"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.data | length' "$SNAP")" = "0" ]
  # And the timestamp advanced, so the reader sees a fresh (not stale) snapshot.
  [ "$(jq -r '.generated_at' "$SNAP")" != "2026-01-01T00:00:00Z" ]
}

@test "no temp files are left behind on the success or trino-failure paths" {
  # The writer mktemps beside the target; a run must not litter the state dir
  # with .XXXXXX fragments a reader could later trip over.
  #
  # Scope, stated honestly: the trino-failure branch below exits BEFORE the
  # mktemp, so it proves only that nothing is created early — it does not
  # exercise the EXIT trap that cleans up a temp file after a mid-write jq
  # crash. That path needs jq to die between mktemp and mv, which nothing here
  # can drive (MAP is already validated as JSON by then), so the trap is
  # defensive and deliberately uncovered rather than silently claimed.
  run env CV_FRAUD_MUSO_SNAPSHOT_FILE="$SNAP" TRINO_QUERY_SH="$TRINO_OK" "$WRITER"
  [ "$status" -eq 0 ]
  [ "$(count_temp_fragments)" = "0" ]

  run env CV_FRAUD_MUSO_SNAPSHOT_FILE="$SNAP" TRINO_QUERY_SH="$TRINO_FAIL" "$WRITER"
  [ "$status" -ne 0 ]
  [ "$(count_temp_fragments)" = "0" ]
}

@test "snapshot is written atomically (reader never sees a partial file)" {
  # The write goes to a mktemp sibling then mv -f, so the target either holds
  # the previous snapshot or the complete new one — never a truncated write.
  run --separate-stderr env CV_FRAUD_MUSO_SNAPSHOT_FILE="$SNAP" TRINO_QUERY_SH="$TRINO_OK" "$WRITER"
  [ "$status" -eq 0 ]
  # Parses as a whole: a partial write would fail jq outright.
  run jq -e '(.generated_at | type) == "string" and (.data | type) == "object"' "$SNAP"
  [ "$status" -eq 0 ]
}

# ───────────── all-or-nothing parsing: a PARTIAL result is the dangerous case ─────────────
# Dropping only the bad rows leaves MAP_LEN > 0, so the writer overwrites the
# good snapshot and exits 0 — and the dropped profiles are merely ABSENT, which
# fraud-muso-only-lookup.sh documents as "looked up, this profile clean".
# One malformed row would therefore SUPPRESS the muso_only fraud factor for
# that profile for up to 36h, on a successful run with nothing in the log.
# The all-invalid error-page test above does not reach this path.

# Seed a known-good prior snapshot and assert it survives untouched.
assert_prior_snapshot_intact() {
  [ "$(jq -r --arg p "$P1" '.data[$p]' "$SNAP")" = "1.5" ]
  [ "$(jq -r '.generated_at' "$SNAP")" = "2026-01-01T00:00:00Z" ]
}
seed_prior_snapshot() {
  printf '{"generated_at":"2026-01-01T00:00:00Z","data":{"%s":1.5}}\n' "$P1" > "$SNAP"
}

@test "one malformed row among valid ones rejects the WHOLE batch" {
  seed_prior_snapshot
  local mixed="$TEST_TMPDIR/trino-mixed.sh"
  cat > "$mixed" <<STUB
#!/usr/bin/env bash
cat >/dev/null
printf '"%s","80.5"\n' "$P1"
printf '"%s","not-a-number"\n' "$P2"
exit 0
STUB
  chmod +x "$mixed"

  run --separate-stderr env CV_FRAUD_MUSO_SNAPSHOT_FILE="$SNAP" TRINO_QUERY_SH="$mixed" "$WRITER"
  [ "$status" -ne 0 ]
  [[ "$stderr" == *"refusing to write an incomplete snapshot"* ]]
  [[ "$stderr" == *"only 1 of 2 non-blank"* ]]
  assert_prior_snapshot_intact
}

@test "an out-of-range percentage rejects the whole batch" {
  seed_prior_snapshot
  local oor="$TEST_TMPDIR/trino-oor.sh"
  cat > "$oor" <<STUB
#!/usr/bin/env bash
cat >/dev/null
printf '"%s","80.5"\n' "$P1"
printf '"%s","101"\n' "$P2"
exit 0
STUB
  chmod +x "$oor"

  run --separate-stderr env CV_FRAUD_MUSO_SNAPSHOT_FILE="$SNAP" TRINO_QUERY_SH="$oor" "$WRITER"
  [ "$status" -ne 0 ]
  [[ "$stderr" == *"refusing to write an incomplete snapshot"* ]]
  assert_prior_snapshot_intact
}

@test "a non-UUID key rejects the whole batch" {
  seed_prior_snapshot
  local baduuid="$TEST_TMPDIR/trino-baduuid.sh"
  cat > "$baduuid" <<STUB
#!/usr/bin/env bash
cat >/dev/null
printf '"%s","80.5"\n' "$P1"
printf '"not-a-uuid","42.0"\n'
exit 0
STUB
  chmod +x "$baduuid"

  run --separate-stderr env CV_FRAUD_MUSO_SNAPSHOT_FILE="$SNAP" TRINO_QUERY_SH="$baduuid" "$WRITER"
  [ "$status" -ne 0 ]
  [[ "$stderr" == *"refusing to write an incomplete snapshot"* ]]
  assert_prior_snapshot_intact
}

@test "blank and whitespace-only lines are not counted as failed rows" {
  # Stability partner for the strictness above: `test(\"\\S\")` defines
  # non-blank, so trailing newlines and stray blank lines must NOT trip the
  # all-or-nothing guard and cost us a whole daily refresh.
  local blanks="$TEST_TMPDIR/trino-blanks.sh"
  cat > "$blanks" <<STUB
#!/usr/bin/env bash
cat >/dev/null
printf '"%s","80.5"\n' "$P1"
printf '\n'
printf '   \n'
printf '"%s","12.25"\n' "$P2"
printf '\n'
exit 0
STUB
  chmod +x "$blanks"

  run --separate-stderr env CV_FRAUD_MUSO_SNAPSHOT_FILE="$SNAP" TRINO_QUERY_SH="$blanks" "$WRITER"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.data | length' "$SNAP")" = "2" ]
  [ "$(jq -r --arg p "$P2" '.data[$p]' "$SNAP")" = "12.25" ]
}

@test "boundary percentages 0 and 100 are accepted by the writer" {
  local bounds="$TEST_TMPDIR/trino-bounds.sh"
  cat > "$bounds" <<STUB
#!/usr/bin/env bash
cat >/dev/null
printf '"%s","0"\n' "$P1"
printf '"%s","100"\n' "$P2"
exit 0
STUB
  chmod +x "$bounds"

  run --separate-stderr env CV_FRAUD_MUSO_SNAPSHOT_FILE="$SNAP" TRINO_QUERY_SH="$bounds" "$WRITER"
  [ "$status" -eq 0 ]
  [ "$(jq -r --arg p "$P1" '.data[$p]' "$SNAP")" = "0" ]
  [ "$(jq -r --arg p "$P2" '.data[$p]' "$SNAP")" = "100" ]
}
