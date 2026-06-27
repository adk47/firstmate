#!/usr/bin/env bats
# Tests for scripts/caroline-rag-index-watchdog.sh -- self-heals + alerts when
# Caroline's memory_search (RAG) vector index is paused / its identity is
# missing / the vector store is not ready (openclaw pauses the index on every
# runtime version bump; a paused index silently returns nothing).
#
# Hermeticity (CI bats run on the live host -- see memory
# hydra-ci-bats-live-host-hermeticity): openclaw AND muso are PATH-stubbed and
# OPENCLAW_BIN is forced to a stub, so the suite can never invoke the real
# gateway or page #clio_devops. Detection cases use CAROLINE_RAG_STATUS_FILE
# fixtures + --check / --dry-run, which never acquire the flock and mutate
# nothing. Modeled on scripts/tests/fallback-swallow-watchdog.bats.
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
SCRIPT="$HYDRA_REPO/scripts/caroline-rag-index-watchdog.sh"

HEALTHY=$'Embeddings: ready\nVector store: ready\nVector search: ready\nDreaming: off\nIssues:\n'
PAUSED=$'Embeddings: ready\nVector search: paused until memory is rebuilt\nIndex identity: index metadata is missing\nIssues:\n'
ISSUES=$'Embeddings: ready\nVector store: ready\nVector search: ready\nDreaming: off\nIssues:\n  - embedding provider returned 401\n'

setup() {
  TEST_TMPDIR="$(mktemp -d)"; export TEST_TMPDIR
  STATUS="$TEST_TMPDIR/status.txt"
  STATE="$TEST_TMPDIR/last-alert"
  LOCK="$TEST_TMPDIR/lock"
  export OC_CALLS="$TEST_TMPDIR/openclaw-calls"; : > "$OC_CALLS"
  export STUB_CALLS="$TEST_TMPDIR/muso-calls"; : > "$STUB_CALLS"

  # Never touch the real Slack token source or binary.
  unset MUSO_SLACK_BOT_TOKEN_DEVOPS
  export MUSO_SLACK_ENV_FILE="$TEST_TMPDIR/muso-slack.env"  # absent -> no token

  mkdir -p "$TEST_TMPDIR/bin"
  cat > "$TEST_TMPDIR/bin/muso" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_CALLS"
exit 0
STUB
  # Default openclaw stub: records its args; answers any `status` call healthy
  # so a stray invocation in an unrelated test can't blow up.
  cat > "$TEST_TMPDIR/bin/openclaw" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$OC_CALLS"
if printf '%s\n' "$@" | grep -q status; then
  printf 'Embeddings: ready\nVector store: ready\nVector search: ready\nDreaming: off\nIssues:\n'
fi
exit 0
STUB
  chmod +x "$TEST_TMPDIR/bin/muso" "$TEST_TMPDIR/bin/openclaw"
  export OPENCLAW_STUB="$TEST_TMPDIR/bin/openclaw"
  PATH="$TEST_TMPDIR/bin:$PATH"; export PATH
}
teardown() { rm -rf "$TEST_TMPDIR"; }

run_wd() {
  run env \
    CAROLINE_RAG_SKIP_HOST_GUARD=1 \
    CAROLINE_RAG_STATUS_FILE="$STATUS" \
    CAROLINE_RAG_STATE_FILE="$STATE" \
    CAROLINE_RAG_LOCKFILE="$LOCK" \
    OPENCLAW_BIN="$OPENCLAW_STUB" \
    "$SCRIPT" "$@"
}

@test "--check on a healthy index exits 0" {
  printf '%s' "$HEALTHY" > "$STATUS"
  run_wd --check
  [ "$status" -eq 0 ]
  [[ "$output" == *"healthy"* ]]
}

@test "--check on a paused index exits 1 and names every problem" {
  printf '%s' "$PAUSED" > "$STATUS"
  run_wd --check
  [ "$status" -eq 1 ]
  [[ "$output" == *"vector search paused"* ]]
  [[ "$output" == *"index identity missing"* ]]
  [[ "$output" == *"vector store not ready"* ]]
}

@test "--check flags a non-empty Issues: block" {
  printf '%s' "$ISSUES" > "$STATUS"
  run_wd --check
  [ "$status" -eq 1 ]
  [[ "$output" == *"memory status reports issues"* ]]
}

@test "--dry-run on a paused index would reindex but mutates nothing" {
  printf '%s' "$PAUSED" > "$STATUS"
  run_wd --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"would run"* ]]
  [[ "$output" == *"memory index --force"* ]]
  # No reindex actually ran, and no watermark was written.
  ! grep -q "index" "$OC_CALLS"
  [ ! -f "$STATE" ]
}

@test "--dry-run with auto-heal disabled would alert-only, never reindex" {
  printf '%s' "$PAUSED" > "$STATUS"
  CAROLINE_RAG_NO_HEAL=1 run_wd --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"auto-heal disabled"* ]]
  ! grep -q "index" "$OC_CALLS"
}

@test "self-heal: a paused index is rebuilt, the alert fires, watermark is set" {
  command -v flock >/dev/null 2>&1 || skip "flock not available on this host"
  # A flipping openclaw stub: status is paused until `memory index` runs (which
  # touches a marker), then healthy. Drives the full detect -> heal -> re-check
  # -> post path. STATUS_FILE is unset so capture_status calls this stub.
  local marker="$TEST_TMPDIR/healed"
  cat > "$TEST_TMPDIR/bin/openclaw" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$OC_CALLS"
if printf '%s\n' "\$@" | grep -q index; then touch "$marker"; echo rebuilt; exit 0; fi
if printf '%s\n' "\$@" | grep -q status; then
  if [ -f "$marker" ]; then printf 'Embeddings: ready\nVector store: ready\nVector search: ready\nDreaming: off\nIssues:\n';
  else printf 'Embeddings: ready\nVector search: paused until memory is rebuilt\nIndex identity: index metadata is missing\nIssues:\n'; fi
  exit 0
fi
exit 0
STUB
  chmod +x "$TEST_TMPDIR/bin/openclaw"

  run env \
    CAROLINE_RAG_SKIP_HOST_GUARD=1 \
    CAROLINE_RAG_STATE_FILE="$STATE" \
    CAROLINE_RAG_LOCKFILE="$LOCK" \
    OPENCLAW_BIN="$TEST_TMPDIR/bin/openclaw" \
    MUSO_SLACK_BOT_TOKEN_DEVOPS="xoxb-stub" \
    "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"self-healed"* ]]
  # A reindex was actually attempted, the alert was posted via the muso stub,
  # and the cooldown watermark was written.
  grep -q "index" "$OC_CALLS"
  grep -q "slack send" "$STUB_CALLS"
  [ -f "$STATE" ]
}

@test "a healthy index clears any stale cooldown watermark" {
  command -v flock >/dev/null 2>&1 || skip "flock not available on this host"
  printf '%s' "$HEALTHY" > "$STATUS"
  printf '%s\n' 1700000000 > "$STATE"
  run_wd
  [ "$status" -eq 0 ]
  [[ "$output" == *"healthy"* ]]
  [ ! -f "$STATE" ]
}
