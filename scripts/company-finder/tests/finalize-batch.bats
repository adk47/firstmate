#!/usr/bin/env bats
#
# finalize-batch.sh is the ENFORCEMENT point: it records rejects + writes the
# batch to the Seen Ledger, and ONLY on a successful ledger write does it post
# to #company-finder. These tests pin the gate: a ledger failure (esp. a
# LEDGER_COLLISION = dedupe skipped/raced) posts NOTHING, and the post only
# happens after the ledger write — so a batch in the channel proves dedupe ran.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  SUT="$REPO_ROOT/scripts/company-finder/finalize-batch.sh"
  STUB="$BATS_TEST_TMPDIR"

  # ledger stub: record-rejects + suggest succeed unless REJECTS_RC/SUGGEST_RC set.
  cat > "$STUB/ledger.sh" <<'EOF'
#!/usr/bin/env bash
cmd="$1"; IN="$(cat)"
: > "$LEDGER_CALLED_MARKER"
case "$cmd" in
  record-rejects)
    [ "${REJECTS_RC:-0}" -ne 0 ] && { echo "LEDGER_WRITE_FAILED" >&2; exit "$REJECTS_RC"; }
    jq -n --argjson c "$IN" '{recorded:[],skipped_existing:[],skipped_invalid:[],
      stats:{recorded:($c|length),skipped_existing:0,skipped_invalid:0}}' ;;
  suggest)
    [ "${SUGGEST_RC:-0}" -ne 0 ] && { echo "LEDGER_COLLISION: x" >&2; exit "$SUGGEST_RC"; }
    jq -n --argjson c "$IN" '{recorded:($c|map({domain,name,id:1})),stats:{recorded:($c|length)}}' ;;
  *) echo "unexpected: $cmd" >&2; exit 99 ;;
esac
EOF
  # slack lib stub: slack_load_env succeeds unless SLACK_LOAD_RC set.
  printf 'slack_load_env() { [ "${SLACK_LOAD_RC:-0}" -eq 0 ]; }\n' > "$STUB/slack-notify.sh"
  # muso stub: records that it was called (proves a post happened), echoes a ts,
  # captures the --text it received. MUSO_RC>0 simulates a send failure.
  cat > "$STUB/muso" <<'EOF'
#!/usr/bin/env bash
: > "$MUSO_CALLED_MARKER"
while [ $# -gt 0 ]; do [ "$1" = "--text" ] && printf '%s' "$2" > "$POST_OUT"; shift; done
[ "${MUSO_RC:-0}" -ne 0 ] && { echo "slack send failed" >&2; exit "$MUSO_RC"; }
echo '{"ts":"1782140000.1"}'
EOF
  chmod +x "$STUB/ledger.sh" "$STUB/muso"
  export LEDGER_SH="$STUB/ledger.sh"
  export SLACK_NOTIFY_SH="$STUB/slack-notify.sh"
  export MUSO_BIN="$STUB/muso"
  export SLACK_ACCOUNT="scout"
  export MUSO_CALLED_MARKER="$BATS_TEST_TMPDIR/muso_called"
  export LEDGER_CALLED_MARKER="$BATS_TEST_TMPDIR/ledger_called"
  export POST_OUT="$BATS_TEST_TMPDIR/post.txt"

  # Single-flight lock dir — never touch /var/lib in tests.
  export CF_LOCK_DIR="$BATS_TEST_TMPDIR/locks"

  # finalize-batch.sh itself now prefetches the three dedupe-source tables
  # (Step 0) before delegating to the (stubbed) ledger.sh — pin the legacy
  # nocodb-api.sh wrapper path at the fixtures shared with ledger.bats. None
  # of the fixture domains collide with alpha.com/dead.com below.
  export USE_MUSO_CLI=0
  export NOCODB_API_SH="$REPO_ROOT/scripts/company-finder/tests/stubs/nocodb-api.sh"
  export NOCODB_STUB_FIXTURES="$REPO_ROOT/scripts/company-finder/tests/fixtures"
  export COMPANY_TABLE_ID="mvr6nmzcv7albxt"
  export CONTACTS_TABLE_ID="m9vsbijhrr9ddeu"
  export LEDGER_TABLE_ID="ledgertable001"
  export NOCODB_PAGE_SLEEP=0

  BATCH='{"batch":[{"name":"Alpha","domain":"alpha.com","vertical":"Plugins","tier":"2","why":"fits","spend_signal":"NAMM"}],"rejects":[{"name":"Dead","domain":"dead.com","reason":"DEAD"}],"date":"2026-06-22"}'
}

@test "--help exits 0" {
  run bash "$SUT" --help
  [ "$status" -eq 0 ]
}

@test "empty batch exits 1 (NO_REPLY, nothing to post)" {
  run bash "$SUT" <<<'{"batch":[]}'
  [ "$status" -eq 1 ]
  [ ! -f "$MUSO_CALLED_MARKER" ]
}

@test "non-object stdin exits 1" {
  run bash "$SUT" <<<'[]'
  [ "$status" -eq 1 ]
}

@test "oversized rendered payload fails before any ledger mutation" {
  OVERSIZED="$(jq -nc '{batch:[{name:"Alpha",domain:"alpha.com",vertical:"Plugins",why:("x" * 40000)}]}')"
  run bash "$SUT" <<<"$OVERSIZED"
  [ "$status" -eq 1 ]
  [[ "$output" == *'"error":"PAYLOAD_TOO_LARGE"'* ]]
  [ ! -f "$LEDGER_CALLED_MARKER" ]
  [ ! -f "$MUSO_CALLED_MARKER" ]
}

@test "happy path: ledger then post; returns ts + ledger counts" {
  run bash "$SUT" <<<"$BATCH"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.posted.ts' <<<"$output")" = "1782140000.1" ]
  [ "$(jq -r '.posted.channel' <<<"$output")" = "C0ARS7XMY93" ]
  [ "$(jq -r '.ledger.suggested' <<<"$output")" = "1" ]
  [ "$(jq -r '.ledger.rejects_recorded' <<<"$output")" = "1" ]
  [ -f "$MUSO_CALLED_MARKER" ]
}

@test "GATE: ledger suggest LEDGER_COLLISION (exit 3) posts NOTHING and exits 3" {
  SUGGEST_RC=3 run bash "$SUT" <<<"$BATCH"
  [ "$status" -eq 3 ]
  [ ! -f "$MUSO_CALLED_MARKER" ]
  [[ "$output" == *"LEDGER_COLLISION"* ]]
}

@test "record-rejects failure aborts before suggest + post" {
  REJECTS_RC=4 run bash "$SUT" <<<"$BATCH"
  [ "$status" -eq 4 ]
  [ ! -f "$MUSO_CALLED_MARKER" ]
}

@test "slack send failure → exit 4 (ledger written, post did not land)" {
  MUSO_RC=1 run bash "$SUT" <<<"$BATCH"
  [ "$status" -eq 4 ]
}

@test "posted text carries the company, its tier, and the rejects footer" {
  run bash "$SUT" <<<"$BATCH"
  [ "$status" -eq 0 ]
  grep -q "Alpha" "$POST_OUT"
  grep -q "Tier 2" "$POST_OUT"
  grep -q "Rejected considerations: Dead DEAD" "$POST_OUT"
}

@test "companies in one vertical are numbered 1, 2, … (not all '1.')" {
  MULTI='{"batch":[{"name":"Alpha","domain":"a.com","vertical":"Plugins","why":"w"},{"name":"Beta","domain":"b.com","vertical":"Plugins","why":"w"}],"date":"2026-06-22"}'
  run bash "$SUT" <<<"$MULTI"
  [ "$status" -eq 0 ]
  grep -q "1. \*Alpha\*" "$POST_OUT"
  grep -q "2. \*Beta\*" "$POST_OUT"
}

@test "malformed .batch (non-array) is a clean usage exit 1, posts nothing" {
  run bash "$SUT" <<<'{"batch":"oops"}'
  [ "$status" -eq 1 ]
  [ ! -f "$MUSO_CALLED_MARKER" ]
}

# ── single-flight lock (2026-07-22 storm: concurrent finalize retries
# stacked ~13 processes against NocoDB) ─────────────────────────────────────

@test "single-flight lock: a concurrent invocation exits 5, ALREADY_RUNNING, posts nothing" {
  mkdir -p "$CF_LOCK_DIR"
  exec 9>"$CF_LOCK_DIR/finalize-batch.sh.lock"
  flock -n 9

  run bash "$SUT" <<<"$BATCH"
  [ "$status" -eq 5 ]
  [[ "$output" == *'"error":"ALREADY_RUNNING"'* ]]
  [ ! -f "$MUSO_CALLED_MARKER" ]

  flock -u 9
  exec 9>&-
}

# ── machine-readable error envelope (a stderr-only marker is invisible to
# the codex exec cell that invokes this script) ─────────────────────────────

@test "error envelope: empty batch emits EMPTY_BATCH on stdout, exit 1 unchanged" {
  run bash "$SUT" <<<'{"batch":[]}'
  [ "$status" -eq 1 ]
  [[ "$output" == *'"error":"EMPTY_BATCH"'* ]]
  [[ "$output" == *'"exit":1'* ]]
}

@test "error envelope: LEDGER_COLLISION emits marker on stdout, exit 3 unchanged" {
  SUGGEST_RC=3 run bash "$SUT" <<<"$BATCH"
  [ "$status" -eq 3 ]
  [[ "$output" == *'"error":"LEDGER_COLLISION"'* ]]
  [[ "$output" == *'"exit":3'* ]]
}

# ── shared snapshot (97s -> ~50s: 6 sequential live table snapshots
# collapsed to 3, reused across record-rejects + suggest) ───────────────────
# These use the REAL ledger.sh (not the ledger.sh stub above) against the
# nocodb-api.sh stub, so the snapshot-sharing plumbing between
# finalize-batch.sh and ledger.sh is exercised end-to-end.

@test "snapshot sharing: a full run (batch + rejects) fetches each table exactly once" {
  export LEDGER_SH="$REPO_ROOT/scripts/company-finder/ledger.sh"
  export NOCODB_STUB_READ_LOG="$BATS_TEST_TMPDIR/reads.log"
  run bash "$SUT" <<<"$BATCH"
  [ "$status" -eq 0 ]
  [ "$(grep -c "^records.ls $LEDGER_TABLE_ID " "$NOCODB_STUB_READ_LOG")" -eq 1 ]
  [ "$(grep -c "^records.ls $COMPANY_TABLE_ID " "$NOCODB_STUB_READ_LOG")" -eq 1 ]
  [ "$(grep -c "^records.ls $CONTACTS_TABLE_ID " "$NOCODB_STUB_READ_LOG")" -eq 1 ]
}

@test "snapshot sharing: a domain in both .batch and .rejects still fails closed (LEDGER_COLLISION)" {
  export LEDGER_SH="$REPO_ROOT/scripts/company-finder/ledger.sh"
  DUPE='{"batch":[{"name":"DupeCo","domain":"dupe.example","vertical":"Plugins","why":"w"}],
         "rejects":[{"name":"DupeCo","domain":"dupe.example","reason":"DEAD"}],
         "date":"2026-06-22"}'
  run bash "$SUT" <<<"$DUPE"
  [ "$status" -eq 3 ]
  [[ "$output" == *"LEDGER_COLLISION"* ]]
  [[ "$output" == *'"error":"LEDGER_COLLISION"'* ]]
  [ ! -f "$MUSO_CALLED_MARKER" ]
}
