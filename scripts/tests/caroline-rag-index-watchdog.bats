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
    CAROLINE_RAG_ALERT_TS_FILE="$TEST_TMPDIR/last-alert-ts" \
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

# A flipping openclaw stub: status is paused until `memory index` runs (which
# touches $marker), then healthy. Drives the full detect -> heal -> re-check
# path. STATUS_FILE is unset so capture_status calls this stub.
write_flip_stub() {
  local marker="$1"
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
}

@test "self-heal: a paused index is rebuilt SILENTLY -- no green Slack post, heal recorded" {
  command -v flock >/dev/null 2>&1 || skip "flock not available on this host"
  write_flip_stub "$TEST_TMPDIR/healed"

  run env \
    CAROLINE_RAG_SKIP_HOST_GUARD=1 \
    CAROLINE_RAG_STATE_FILE="$STATE" \
    CAROLINE_RAG_LOCKFILE="$LOCK" \
    CAROLINE_RAG_HEAL_LOG="$TEST_TMPDIR/heal-history" \
    CAROLINE_RAG_FLAP_STATE="$TEST_TMPDIR/last-flap" \
    OPENCLAW_BIN="$TEST_TMPDIR/bin/openclaw" \
    MUSO_SLACK_BOT_TOKEN_DEVOPS="xoxb-stub" \
    "$SCRIPT"
  [ "$status" -eq 0 ]
  # The index WAS rebuilt...
  grep -q "index" "$OC_CALLS"
  # ...but a successful heal stays SILENT: nothing posted, no green checkmark.
  ! grep -q "slack send" "$STUB_CALLS"
  [[ "$output" != *"white_check_mark"* ]]
  # The 6h cooldown watermark is NOT set on a silent success.
  [ ! -f "$STATE" ]
  # The heal IS recorded for flapping detection (one entry, below threshold).
  [ -f "$TEST_TMPDIR/heal-history" ]
  [ "$(awk 'END{print NR}' "$TEST_TMPDIR/heal-history")" -eq 1 ]
  [ ! -f "$TEST_TMPDIR/last-flap" ]
}

@test "failed heal: index stays unhealthy after reindex -> red page, watermark set" {
  command -v flock >/dev/null 2>&1 || skip "flock not available on this host"
  # Reindex 'runs' (rc 0) but never heals: status is always paused.
  cat > "$TEST_TMPDIR/bin/openclaw" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$OC_CALLS"
if printf '%s\n' "\$@" | grep -q index; then echo rebuilt; exit 0; fi
if printf '%s\n' "\$@" | grep -q status; then
  printf 'Embeddings: ready\nVector search: paused until memory is rebuilt\nIndex identity: index metadata is missing\nIssues:\n'
  exit 0
fi
exit 0
STUB
  chmod +x "$TEST_TMPDIR/bin/openclaw"

  # RESTART_EPOCH=1 (1970) disables the post-restart grace so the red page fires
  # deterministically; without it the script would probe real systemctl on the
  # CI host. ALERT_TS_FILE stays in TEST_TMPDIR so the resolve path never touches
  # /var/lib state.
  run env \
    CAROLINE_RAG_SKIP_HOST_GUARD=1 \
    CAROLINE_RAG_STATE_FILE="$STATE" \
    CAROLINE_RAG_LOCKFILE="$LOCK" \
    CAROLINE_RAG_HEAL_LOG="$TEST_TMPDIR/heal-history" \
    CAROLINE_RAG_FLAP_STATE="$TEST_TMPDIR/last-flap" \
    CAROLINE_RAG_ALERT_TS_FILE="$TEST_TMPDIR/last-alert-ts" \
    CAROLINE_RAG_RESTART_EPOCH=1 \
    OPENCLAW_BIN="$TEST_TMPDIR/bin/openclaw" \
    MUSO_SLACK_BOT_TOKEN_DEVOPS="xoxb-stub" \
    "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"STILL unhealthy"* ]]
  grep -q "slack send" "$STUB_CALLS"
  [ -f "$STATE" ]
  # A failed heal is NOT counted toward flapping.
  [ ! -f "$TEST_TMPDIR/heal-history" ]
}

@test "flapping: a heal that reaches the threshold pages once (red flap alert)" {
  command -v flock >/dev/null 2>&1 || skip "flock not available on this host"
  write_flip_stub "$TEST_TMPDIR/healed"
  # Two recent prior heals already on record -> this run is the 3rd (threshold).
  local now; now="$(date +%s)"
  printf '%s\n%s\n' "$((now-300))" "$((now-200))" > "$TEST_TMPDIR/heal-history"

  run env \
    CAROLINE_RAG_SKIP_HOST_GUARD=1 \
    CAROLINE_RAG_STATE_FILE="$STATE" \
    CAROLINE_RAG_LOCKFILE="$LOCK" \
    CAROLINE_RAG_HEAL_LOG="$TEST_TMPDIR/heal-history" \
    CAROLINE_RAG_FLAP_STATE="$TEST_TMPDIR/last-flap" \
    CAROLINE_RAG_FLAP_THRESHOLD=3 \
    OPENCLAW_BIN="$TEST_TMPDIR/bin/openclaw" \
    MUSO_SLACK_BOT_TOKEN_DEVOPS="xoxb-stub" \
    "$SCRIPT"
  [ "$status" -eq 0 ]
  # The log records the page; the posted Slack text names the condition.
  [[ "$output" == *"FLAPPING alert"* ]]
  grep -q "slack send" "$STUB_CALLS"
  grep -qi "flapping" "$STUB_CALLS"
  [ -f "$TEST_TMPDIR/last-flap" ]
}

@test "flapping: alert is suppressed within the flap cooldown window" {
  command -v flock >/dev/null 2>&1 || skip "flock not available on this host"
  write_flip_stub "$TEST_TMPDIR/healed"
  local now; now="$(date +%s)"
  # At threshold already, but a flap alert was posted 1h ago; cooldown 24h.
  printf '%s\n%s\n' "$((now-300))" "$((now-200))" > "$TEST_TMPDIR/heal-history"
  printf '%s\n' "$((now-3600))" > "$TEST_TMPDIR/last-flap"

  run env \
    CAROLINE_RAG_SKIP_HOST_GUARD=1 \
    CAROLINE_RAG_STATE_FILE="$STATE" \
    CAROLINE_RAG_LOCKFILE="$LOCK" \
    CAROLINE_RAG_HEAL_LOG="$TEST_TMPDIR/heal-history" \
    CAROLINE_RAG_FLAP_STATE="$TEST_TMPDIR/last-flap" \
    CAROLINE_RAG_FLAP_THRESHOLD=3 \
    CAROLINE_RAG_FLAP_COOLDOWN_SECS=86400 \
    OPENCLAW_BIN="$TEST_TMPDIR/bin/openclaw" \
    MUSO_SLACK_BOT_TOKEN_DEVOPS="xoxb-stub" \
    "$SCRIPT"
  [ "$status" -eq 0 ]
  # Healed (silently), but the flap alert is within its cooldown -> no post.
  grep -q "index" "$OC_CALLS"
  ! grep -q "slack send" "$STUB_CALLS"
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

# An openclaw stub whose index is ALWAYS paused (the heal 'runs' rc 0 but never
# grounds), driving the red-page path. `grep -q index` catches BOTH heal forms
# ('index --force' and 'status --index'); 'status --deep' (detection) does not.
write_paused_stub() {
  cat > "$TEST_TMPDIR/bin/openclaw" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$OC_CALLS"
if printf '%s\n' "\$@" | grep -q index; then echo rebuilt; exit 0; fi
if printf '%s\n' "\$@" | grep -q status; then
  printf 'Embeddings: ready\nVector search: paused until memory is rebuilt\nIndex identity: index metadata is missing\nIssues:\n'
  exit 0
fi
exit 0
STUB
  chmod +x "$TEST_TMPDIR/bin/openclaw"
}

@test "grace: red page is DEFERRED within the post-restart grace window" {
  command -v flock >/dev/null 2>&1 || skip "flock not available on this host"
  write_paused_stub
  local now; now="$(date +%s)"
  run env \
    CAROLINE_RAG_SKIP_HOST_GUARD=1 \
    CAROLINE_RAG_STATE_FILE="$STATE" \
    CAROLINE_RAG_LOCKFILE="$LOCK" \
    CAROLINE_RAG_HEAL_LOG="$TEST_TMPDIR/heal-history" \
    CAROLINE_RAG_FLAP_STATE="$TEST_TMPDIR/last-flap" \
    CAROLINE_RAG_ALERT_TS_FILE="$TEST_TMPDIR/last-alert-ts" \
    CAROLINE_RAG_GRACE_SECS=300 \
    CAROLINE_RAG_RESTART_EPOCH="$((now - 30))" \
    OPENCLAW_BIN="$TEST_TMPDIR/bin/openclaw" \
    MUSO_SLACK_BOT_TOKEN_DEVOPS="xoxb-stub" \
    "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"within post-restart grace"* ]]
  # The heal STILL ran (repair is never skipped) ...
  grep -q "index" "$OC_CALLS"
  # ... but the noisy mid-restart page is suppressed: no post, no watermark, no ts.
  ! grep -q "slack send" "$STUB_CALLS"
  [ ! -f "$STATE" ]
  [ ! -f "$TEST_TMPDIR/last-alert-ts" ]
}

@test "grace: red page FIRES when the last restart is older than the window" {
  command -v flock >/dev/null 2>&1 || skip "flock not available on this host"
  write_paused_stub
  local now; now="$(date +%s)"
  run env \
    CAROLINE_RAG_SKIP_HOST_GUARD=1 \
    CAROLINE_RAG_STATE_FILE="$STATE" \
    CAROLINE_RAG_LOCKFILE="$LOCK" \
    CAROLINE_RAG_HEAL_LOG="$TEST_TMPDIR/heal-history" \
    CAROLINE_RAG_FLAP_STATE="$TEST_TMPDIR/last-flap" \
    CAROLINE_RAG_ALERT_TS_FILE="$TEST_TMPDIR/last-alert-ts" \
    CAROLINE_RAG_GRACE_SECS=300 \
    CAROLINE_RAG_RESTART_EPOCH="$((now - 100000))" \
    OPENCLAW_BIN="$TEST_TMPDIR/bin/openclaw" \
    MUSO_SLACK_BOT_TOKEN_DEVOPS="xoxb-stub" \
    "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"STILL unhealthy"* ]]
  grep -q "slack send" "$STUB_CALLS"
  [ -f "$STATE" ]
}

@test "resolve-in-thread: a red page persists its ts; the next healthy tick replies in-thread and clears it" {
  command -v flock >/dev/null 2>&1 || skip "flock not available on this host"
  # muso stub echoes a ts on --json so the red page can capture + persist it.
  cat > "$TEST_TMPDIR/bin/muso" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_CALLS"
if printf '%s\n' "$@" | grep -q -- --json; then
  echo '{"channel":"C0ADV2W76G4","ts":"1717171717.123456"}'
fi
exit 0
STUB
  chmod +x "$TEST_TMPDIR/bin/muso"
  local ts_file="$TEST_TMPDIR/last-alert-ts"

  # Tick 1: paused, past the grace window -> red page; ts captured + persisted.
  write_paused_stub
  run env \
    CAROLINE_RAG_SKIP_HOST_GUARD=1 \
    CAROLINE_RAG_STATE_FILE="$STATE" \
    CAROLINE_RAG_LOCKFILE="$LOCK" \
    CAROLINE_RAG_HEAL_LOG="$TEST_TMPDIR/heal-history" \
    CAROLINE_RAG_FLAP_STATE="$TEST_TMPDIR/last-flap" \
    CAROLINE_RAG_ALERT_TS_FILE="$ts_file" \
    CAROLINE_RAG_RESTART_EPOCH=1 \
    OPENCLAW_BIN="$TEST_TMPDIR/bin/openclaw" \
    MUSO_SLACK_BOT_TOKEN_DEVOPS="xoxb-stub" \
    "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"STILL unhealthy"* ]]
  grep -q -- "--json" "$STUB_CALLS"
  [ -f "$ts_file" ]
  grep -q "1717171717.123456" "$ts_file"

  # Tick 2: healthy -> threaded resolve reply on the captured ts; ts file cleared.
  : > "$STUB_CALLS"
  printf '%s' "$HEALTHY" > "$STATUS"
  run env \
    CAROLINE_RAG_SKIP_HOST_GUARD=1 \
    CAROLINE_RAG_STATUS_FILE="$STATUS" \
    CAROLINE_RAG_STATE_FILE="$STATE" \
    CAROLINE_RAG_LOCKFILE="$LOCK" \
    CAROLINE_RAG_ALERT_TS_FILE="$ts_file" \
    OPENCLAW_BIN="$OPENCLAW_STUB" \
    MUSO_SLACK_BOT_TOKEN_DEVOPS="xoxb-stub" \
    "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -q "thread-ts 1717171717.123456" "$STUB_CALLS"
  grep -qi "recovered" "$STUB_CALLS"
  [ ! -f "$ts_file" ]
}

@test "main profile heals via 'memory status --index', not 'index --force'" {
  command -v flock >/dev/null 2>&1 || skip "flock not available on this host"
  write_flip_stub "$TEST_TMPDIR/healed"
  run env \
    CAROLINE_RAG_SKIP_HOST_GUARD=1 \
    CAROLINE_RAG_PROFILE=main \
    CAROLINE_RAG_AGENT=cmo \
    CAROLINE_RAG_STATE_FILE="$STATE" \
    CAROLINE_RAG_LOCKFILE="$LOCK" \
    CAROLINE_RAG_HEAL_LOG="$TEST_TMPDIR/heal-history" \
    CAROLINE_RAG_FLAP_STATE="$TEST_TMPDIR/last-flap" \
    CAROLINE_RAG_ALERT_TS_FILE="$TEST_TMPDIR/last-alert-ts" \
    CAROLINE_RAG_RESTART_EPOCH=1 \
    OPENCLAW_BIN="$TEST_TMPDIR/bin/openclaw" \
    MUSO_SLACK_BOT_TOKEN_DEVOPS="xoxb-stub" \
    "$SCRIPT"
  [ "$status" -eq 0 ]
  # main heals with 'status --index' (clears the identity-metadata pause) ...
  grep -q "memory status --index" "$OC_CALLS"
  # ... and NEVER with 'index --force'.
  ! grep -q "index --force" "$OC_CALLS"
  # A successful heal is silent.
  ! grep -q "slack send" "$STUB_CALLS"
}

@test "main: a non-canary agent whose heal FAILS still pages (not silenced by a healthy canary)" {
  command -v flock >/dev/null 2>&1 || skip "flock not available on this host"
  # Heal for cmo grounds it (touch marker); heal for cto FAILS (rc 3). Status is
  # paused until the cmo marker exists, then healthy -- so the canary re-check
  # reports ok while cto's heal has failed. Without the QA #620 fix this would
  # take the silent-success path.
  cat > "$TEST_TMPDIR/bin/openclaw" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$OC_CALLS"
args="\$*"
if [[ "\$args" == *"status --index"* || "\$args" == *"index --force"* ]]; then
  [[ "\$args" == *"--agent cto"* ]] && exit 3            # cto heal fails
  touch "$TEST_TMPDIR/healed"; echo rebuilt; exit 0       # cmo (and others) heal
fi
if [[ "\$args" == *"memory status"* ]]; then
  if [ -f "$TEST_TMPDIR/healed" ]; then printf 'Embeddings: ready\nVector store: ready\nVector search: ready\nDreaming: off\nIssues:\n'
  else printf 'Embeddings: ready\nVector search: paused until memory is rebuilt\nIndex identity: index metadata is missing\nIssues:\n'; fi
  exit 0
fi
exit 0
STUB
  chmod +x "$TEST_TMPDIR/bin/openclaw"

  run env \
    CAROLINE_RAG_SKIP_HOST_GUARD=1 \
    CAROLINE_RAG_PROFILE=main CAROLINE_RAG_AGENT=cmo \
    CAROLINE_RAG_HEAL_AGENTS='cmo cto' \
    CAROLINE_RAG_STATE_FILE="$STATE" CAROLINE_RAG_LOCKFILE="$LOCK" \
    CAROLINE_RAG_HEAL_LOG="$TEST_TMPDIR/heal-history" \
    CAROLINE_RAG_FLAP_STATE="$TEST_TMPDIR/last-flap" \
    CAROLINE_RAG_ALERT_TS_FILE="$TEST_TMPDIR/last-alert-ts" \
    CAROLINE_RAG_RESTART_EPOCH=1 \
    OPENCLAW_BIN="$TEST_TMPDIR/bin/openclaw" \
    MUSO_SLACK_BOT_TOKEN_DEVOPS="xoxb-stub" \
    "$SCRIPT"
  [ "$status" -eq 0 ]
  # cmo (canary) healed, but the failed cto heal must PAGE, not go silent.
  [[ "$output" == *"STILL unhealthy"* ]]
  grep -q "slack send" "$STUB_CALLS"
  grep -q "cto" "$STUB_CALLS"       # the page names the failed agent
  [ -f "$STATE" ]                    # cooldown watermark advanced (real page)
}

@test "main heal loops every agent in HEAL_AGENTS" {
  command -v flock >/dev/null 2>&1 || skip "flock not available on this host"
  write_flip_stub "$TEST_TMPDIR/healed"
  run env \
    CAROLINE_RAG_SKIP_HOST_GUARD=1 \
    CAROLINE_RAG_PROFILE=main \
    CAROLINE_RAG_AGENT=cmo \
    CAROLINE_RAG_HEAL_AGENTS='cmo cto finance' \
    CAROLINE_RAG_STATE_FILE="$STATE" \
    CAROLINE_RAG_LOCKFILE="$LOCK" \
    CAROLINE_RAG_HEAL_LOG="$TEST_TMPDIR/heal-history" \
    CAROLINE_RAG_FLAP_STATE="$TEST_TMPDIR/last-flap" \
    CAROLINE_RAG_ALERT_TS_FILE="$TEST_TMPDIR/last-alert-ts" \
    CAROLINE_RAG_RESTART_EPOCH=1 \
    OPENCLAW_BIN="$TEST_TMPDIR/bin/openclaw" \
    MUSO_SLACK_BOT_TOKEN_DEVOPS="xoxb-stub" \
    "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -q "status --index --agent cmo" "$OC_CALLS"
  grep -q "status --index --agent cto" "$OC_CALLS"
  grep -q "status --index --agent finance" "$OC_CALLS"
}
