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
  export POST_OUT="$BATS_TEST_TMPDIR/post.txt"

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
