#!/usr/bin/env bats
# Tests scripts/openclaw-edge-reindex-on-start.sh -- the ExecStartPost heal-on-boot
# healer that rebuilds Caroline's memory_search index after every edge gateway
# start (openclaw 2026.6.1 pauses the index on every restart). openclaw is
# OPENCLAW_BIN-stubbed and the host guard is skipped, so the suite never touches
# the real gateway. Modeled on scripts/tests/caroline-rag-index-watchdog.bats.
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
SCRIPT="$HYDRA_REPO/scripts/openclaw-edge-reindex-on-start.sh"

HEALTHY=$'Embeddings: ready\nVector store: ready\nVector search: ready\nDreaming: off\nIssues:\n'

setup() {
  TEST_TMPDIR="$(mktemp -d)"; export TEST_TMPDIR
  STATUS="$TEST_TMPDIR/status.txt"
  LOCK="$TEST_TMPDIR/lock"
  export OC_CALLS="$TEST_TMPDIR/openclaw-calls"; : > "$OC_CALLS"
  mkdir -p "$TEST_TMPDIR/bin"
  export OPENCLAW_STUB="$TEST_TMPDIR/bin/openclaw"
}
teardown() { rm -rf "$TEST_TMPDIR"; }

# A flipping stub: agents always report bound; status is paused until `memory
# index` runs (touches $marker), then healthy. Drives readiness -> paused ->
# reindex -> recheck-ok. Used with STATUS_FILE unset so capture_status calls it.
write_flip_stub() {
  local marker="$1"
  # NOTE: `printf '%s\n' "$@"` prints each arg on its own line, so match on
  # single-word discriminators (agents / index / status), never two-word phrases.
  cat > "$OPENCLAW_STUB" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$OC_CALLS"
if printf '%s\n' "\$@" | grep -q agents; then echo "- support"; exit 0; fi
if printf '%s\n' "\$@" | grep -q index; then touch "$marker"; echo rebuilt; exit 0; fi
if printf '%s\n' "\$@" | grep -q status; then
  if [ -f "$marker" ]; then printf 'Embeddings: ready\nVector store: ready\nVector search: ready\nDreaming: off\nIssues:\n';
  else printf 'Embeddings: ready\nVector search: paused until memory is rebuilt\nIndex identity: index metadata is missing\nIssues:\n'; fi
  exit 0
fi
exit 0
STUB
  chmod +x "$OPENCLAW_STUB"
}

run_healer() {
  run env \
    CAROLINE_RAG_SKIP_HOST_GUARD=1 \
    REINDEX_SKIP_READY=1 \
    CAROLINE_RAG_LOCKFILE="$LOCK" \
    OPENCLAW_BIN="$OPENCLAW_STUB" \
    "$@" \
    "$SCRIPT"
}

@test "healthy index after start -> no reindex, nothing to heal" {
  command -v flock >/dev/null 2>&1 || skip "flock not available"
  printf '%s' "$HEALTHY" > "$STATUS"
  # A stub that would ANSWER a status call healthy too (belt + braces).
  cat > "$OPENCLAW_STUB" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$OC_CALLS"
printf 'Embeddings: ready\nVector store: ready\nVector search: ready\nDreaming: off\nIssues:\n'
exit 0
STUB
  chmod +x "$OPENCLAW_STUB"
  run_healer CAROLINE_RAG_STATUS_FILE="$STATUS"
  [ "$status" -eq 0 ]
  [[ "$output" == *"nothing to heal"* ]]
  ! grep -q "memory index" "$OC_CALLS"
}

@test "paused index after start -> reindex, recheck ok, grounded" {
  command -v flock >/dev/null 2>&1 || skip "flock not available"
  write_flip_stub "$TEST_TMPDIR/healed"
  run_healer
  [ "$status" -eq 0 ]
  grep -q "memory index" "$OC_CALLS"
  [[ "$output" == *"grounded"* ]]
}

@test "reindex command fails -> WARN, exits 0, leaves it for the watchdog" {
  command -v flock >/dev/null 2>&1 || skip "flock not available"
  cat > "$OPENCLAW_STUB" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$OC_CALLS"
if printf '%s\n' "$@" | grep -q agents; then echo "- support"; exit 0; fi
if printf '%s\n' "$@" | grep -q index; then echo "boom" >&2; exit 1; fi
if printf '%s\n' "$@" | grep -q status; then
  printf 'Embeddings: ready\nVector search: paused until memory is rebuilt\nIndex identity: index metadata is missing\nIssues:\n'
fi
exit 0
STUB
  chmod +x "$OPENCLAW_STUB"
  run_healer
  [ "$status" -eq 0 ]
  [[ "$output" == *"reindex FAILED"* ]]
}

@test "still paused after reindex -> retries once, then WARNs" {
  command -v flock >/dev/null 2>&1 || skip "flock not available"
  # memory index 'runs' (rc 0) but never heals: status is always paused.
  cat > "$OPENCLAW_STUB" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$OC_CALLS"
if printf '%s\n' "$@" | grep -q agents; then echo "- support"; exit 0; fi
if printf '%s\n' "$@" | grep -q index; then echo rebuilt; exit 0; fi
if printf '%s\n' "$@" | grep -q status; then
  printf 'Embeddings: ready\nVector search: paused until memory is rebuilt\nIndex identity: index metadata is missing\nIssues:\n'
fi
exit 0
STUB
  chmod +x "$OPENCLAW_STUB"
  run_healer
  [ "$status" -eq 0 ]
  [[ "$output" == *"retrying reindex once"* ]]
  [[ "$output" == *"STILL paused"* ]]
  # Two reindex attempts (initial + one retry).
  [ "$(grep -c "memory index" "$OC_CALLS")" -eq 2 ]
}

@test "host guard: not ovh-node-8 and no fixture -> SKIP, no openclaw calls" {
  # Hermetic: CI bats run ON ovh-node-8 (where the guard correctly does NOT
  # skip), so stub `hostname` to a non-node-8 name rather than relying on the
  # runner's real hostname. SKIP_HOST_GUARD unset + no STATUS_FILE -> guard engages.
  cat > "$TEST_TMPDIR/bin/hostname" <<'HN'
#!/usr/bin/env bash
echo "ci-runner-not-node8"
HN
  chmod +x "$TEST_TMPDIR/bin/hostname"
  run env \
    PATH="$TEST_TMPDIR/bin:$PATH" \
    REINDEX_SKIP_READY=1 \
    CAROLINE_RAG_LOCKFILE="$LOCK" \
    OPENCLAW_BIN="$OPENCLAW_STUB" \
    "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"SKIP"* ]]
  [ ! -s "$OC_CALLS" ]
}

@test "shared lock held by a concurrent run -> SKIP, no reindex" {
  command -v flock >/dev/null 2>&1 || skip "flock not available"
  write_flip_stub "$TEST_TMPDIR/healed"
  # Hold the shared lock, then run the healer: it must skip (flock -n fails).
  exec 8>"$LOCK"
  flock -n 8
  run_healer
  exec 8>&-
  [ "$status" -eq 0 ]
  [[ "$output" == *"lock held"* ]]
  ! grep -q "memory index" "$OC_CALLS"
}
