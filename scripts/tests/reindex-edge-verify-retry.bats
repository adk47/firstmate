#!/usr/bin/env bats
# Tests scripts/lib/reindex-edge-verify-retry.sh :: reindex_edge_verify_retry --
# force-reindex, then verify + retry-once the documented busy-gateway re-pause
# race. openclaw is OPENCLAW_BIN-stubbed and the settle sleep is disabled, so the
# suite never touches the real gateway. 0 = index grounded, non-zero = still paused.
bats_require_minimum_version 1.5.0

setup() {
  HYDRA_REPO="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  TEST_TMPDIR="$(mktemp -d)"; export TEST_TMPDIR
  export OC_CALLS="$TEST_TMPDIR/oc-calls"; : > "$OC_CALLS"
  export CNT="$TEST_TMPDIR/index-count"
  mkdir -p "$TEST_TMPDIR/bin"
  export OPENCLAW_BIN="$TEST_TMPDIR/bin/openclaw"
  export REINDEX_SETTLE_SECS=0
  # shellcheck source=/dev/null
  source "$HYDRA_REPO/scripts/lib/reindex-edge-verify-retry.sh"
}
teardown() { rm -rf "$TEST_TMPDIR"; }

# write_stub HEAL_AFTER [index_fail] [status_fail]
#   `memory index` records the call, bumps a counter, and (if index_fail) exits 1.
#   `memory status` (unless status_fail -> exits 1) reports HEALTHY once the counter
#   reaches HEAL_AFTER, else PAUSED. (Match on single-word discriminators:
#   `printf '%s\n' "$@"` puts each arg on its own line, so two-word phrases never match.)
write_stub() {
  local heal_after="$1" index_fail="${2:-}" status_fail="${3:-}"
  cat > "$OPENCLAW_BIN" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$OC_CALLS"
if printf '%s\n' "\$@" | grep -q index; then
  n=\$(( \$(cat "$CNT" 2>/dev/null || echo 0) + 1 )); echo "\$n" > "$CNT"
  [ -n "$index_fail" ] && exit 1
  exit 0
fi
if printf '%s\n' "\$@" | grep -q status; then
  [ -n "$status_fail" ] && exit 1
  n=\$(cat "$CNT" 2>/dev/null || echo 0)
  if [ "\$n" -ge "$heal_after" ]; then printf 'Vector store: ready\nSemantic vectors: ready\nEmbeddings: ready\n';
  else printf 'Vector search: paused until memory is rebuilt\nIndex identity: index metadata is missing\n'; fi
  exit 0
fi
exit 0
STUB
  chmod +x "$OPENCLAW_BIN"
}

index_calls() { grep -c "memory index" "$OC_CALLS"; }

@test "grounds on the first force -> returns 0, one reindex" {
  write_stub 1
  run reindex_edge_verify_retry edge support
  [ "$status" -eq 0 ]
  [ "$(index_calls)" -eq 1 ]
  [[ "$output" == *"grounded"* ]]
}

@test "first force races, retry grounds it -> returns 0, two reindexes" {
  write_stub 2
  run reindex_edge_verify_retry edge support
  [ "$status" -eq 0 ]
  [ "$(index_calls)" -eq 2 ]
  [[ "$output" == *"retrying once"* ]]
  [[ "$output" == *"grounded"* ]]
}

@test "both attempts race (still paused) -> returns 1, two reindexes" {
  write_stub 999
  run reindex_edge_verify_retry edge support
  [ "$status" -eq 1 ]
  [ "$(index_calls)" -eq 2 ]
  [[ "$output" == *"NOT confirmed grounded"* ]]
}

@test "reindex command fails and stays paused -> returns 1" {
  write_stub 999 fail
  run reindex_edge_verify_retry edge support
  [ "$status" -eq 1 ]
  [ "$(index_calls)" -eq 2 ]
}

@test "status probe fails/hangs -> NOT grounded, returns 1 (no false success)" {
  # index reindex succeeds, but every `memory status` probe fails (exit 1) ->
  # the verifier must NOT read that as grounded.
  write_stub 1 "" fail
  run reindex_edge_verify_retry edge support
  [ "$status" -eq 1 ]
  [[ "$output" == *"NOT confirmed grounded"* ]]
}

@test "reindex fails but stale index looks healthy -> returns 1 (KB not re-embedded)" {
  # `memory index` fails every time; `memory status` reports healthy. Success must
  # require a SUCCESSFUL force, else the shipped KB was never re-embedded.
  write_stub 1 fail
  run reindex_edge_verify_retry edge support
  [ "$status" -eq 1 ]
  [ "$(index_calls)" -eq 2 ]
}
