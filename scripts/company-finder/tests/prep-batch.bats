#!/usr/bin/env bats
#
# prep-batch.sh chains the two deterministic gates (dedupe → verify) into ONE
# call so the agent can't run discovery and then skip dedupe (the 2026-06 leak).
# These tests pin: survivors = alive ++ blocked, dead/dups land in rejects, and
# a fail-closed exit from EITHER sub-script propagates — never a silent partial.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  SUT="$REPO_ROOT/scripts/company-finder/prep-batch.sh"
  STUB="$BATS_TEST_TMPDIR"

  # dedupe stub: passes input through as .new + one fixed duplicate.
  # DEDUPE_RC>0 simulates DEDUP_SOURCE_UNAVAILABLE.
  cat > "$STUB/dedupe.sh" <<'EOF'
#!/usr/bin/env bash
[ "${DEDUPE_RC:-0}" -ne 0 ] && { echo "DEDUP_SOURCE_UNAVAILABLE: x" >&2; exit "$DEDUPE_RC"; }
IN="$(cat)"
jq -n --argjson c "$IN" '{new:$c,
  duplicates:[{name:"DupCo",domain:"dup.com",reason:"domain"}],
  name_flags:[], stats:{checked:($c|length),new:($c|length),dropped:1}}'
EOF
  # verify stub: first survivor alive, the rest blocked; VERIFY_DEAD=1 adds a
  # dead row; VERIFY_RC>0 simulates VERIFY_NETWORK_SUSPECT.
  cat > "$STUB/verify.sh" <<'EOF'
#!/usr/bin/env bash
[ "${VERIFY_RC:-0}" -ne 0 ] && { echo "VERIFY_NETWORK_SUSPECT" >&2; exit "$VERIFY_RC"; }
IN="$(cat)"
dead='[]'
[ "${VERIFY_DEAD:-0}" = "1" ] && dead='[{"name":"DeadCo","domain":"dead.com","verification":"dead","reason":"connect_failed"}]'
jq -n --argjson c "$IN" --argjson dead "$dead" '{
  alive:[$c[0]+{verification:"alive",http_code:"200"}],
  blocked:($c[1:]|map(.+{verification:"blocked",http_code:"403"})),
  dead:$dead,
  stats:{checked:($c|length),alive:1,blocked:(($c|length)-1),dead:($dead|length)}}'
EOF
  chmod +x "$STUB/dedupe.sh" "$STUB/verify.sh"
  export DEDUPE_SH="$STUB/dedupe.sh"
  export VERIFY_SH="$STUB/verify.sh"
  # Single-flight lock dir — never touch /var/lib in tests.
  export CF_LOCK_DIR="$BATS_TEST_TMPDIR/locks"
}

@test "--help exits 0" {
  run bash "$SUT" --help
  [ "$status" -eq 0 ]
}

@test "non-array stdin exits 1" {
  run bash "$SUT" <<<'{"not":"an array"}'
  [ "$status" -eq 1 ]
}

@test "happy: survivors = alive + blocked; duplicates land in rejects" {
  run bash "$SUT" <<<'[{"name":"A","domain":"a.com"},{"name":"B","domain":"b.com"}]'
  [ "$status" -eq 0 ]
  [ "$(jq '.survivors | length' <<<"$output")" -eq 2 ]
  [ "$(jq '.rejects.duplicates | length' <<<"$output")" -eq 1 ]
  [ "$(jq '.stats.blocked' <<<"$output")" -eq 1 ]
  [ "$(jq '.stats.survivors' <<<"$output")" -eq 2 ]
}

@test "dead candidates are dropped to rejects, never survivors" {
  VERIFY_DEAD=1 run bash "$SUT" <<<'[{"name":"A","domain":"a.com"}]'
  [ "$status" -eq 0 ]
  [ "$(jq '.rejects.dead | length' <<<"$output")" -eq 1 ]
  [ "$(jq '[.survivors[] | select(.verification=="dead")] | length' <<<"$output")" -eq 0 ]
}

@test "dedupe source unavailable (exit 2) propagates as exit 2 — no batch" {
  DEDUPE_RC=2 run bash "$SUT" <<<'[{"name":"A","domain":"a.com"}]'
  [ "$status" -eq 2 ]
  [[ "$output" == *"PARTIAL/UNSAFE"* ]]
}

@test "verify network-suspect (its exit 2) remaps to exit 3" {
  VERIFY_RC=2 run bash "$SUT" <<<'[{"name":"A","domain":"a.com"}]'
  [ "$status" -eq 3 ]
}

# ── single-flight lock (2026-07-22 storm) ───────────────────────────────────

@test "single-flight lock: a concurrent invocation exits 5, ALREADY_RUNNING" {
  mkdir -p "$CF_LOCK_DIR"
  exec 9>"$CF_LOCK_DIR/prep-batch.sh.lock"
  flock -n 9

  run bash "$SUT" <<<'[{"name":"A","domain":"a.com"}]'
  [ "$status" -eq 5 ]
  [[ "$output" == *'"error":"ALREADY_RUNNING"'* ]]

  flock -u 9
  exec 9>&-
}

# ── machine-readable error envelope ─────────────────────────────────────────

@test "error envelope: dedupe source unavailable emits DEDUP_SOURCE_UNAVAILABLE, exit 2 unchanged" {
  DEDUPE_RC=2 run bash "$SUT" <<<'[{"name":"A","domain":"a.com"}]'
  [ "$status" -eq 2 ]
  [[ "$output" == *'"error":"DEDUP_SOURCE_UNAVAILABLE"'* ]]
  [[ "$output" == *'"exit":2'* ]]
}
