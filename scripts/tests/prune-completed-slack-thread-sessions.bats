#!/usr/bin/env bats

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  SUT="$REPO_ROOT/scripts/prune-completed-slack-thread-sessions.sh"
  OPENCLAW_STUB="$BATS_TEST_TMPDIR/openclaw"
  export OPENCLAW_BIN="$OPENCLAW_STUB"
  export OPENCLAW_STUB_LOG="$BATS_TEST_TMPDIR/delete-calls.jsonl"
  export SESSION_THREAD_NOW_MS=2000000000000
  export SESSION_THREAD_RETENTION_DAYS=14
  export SESSION_THREAD_MAX_DELETES=100

  export FAKE_OPENCLAW_VERSION="${FAKE_OPENCLAW_VERSION:-2026.7.1}"

  cat > "$OPENCLAW_STUB" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail

if [[ " $* " == *" --version "* || "${*: -1}" == "--version" ]]; then
  echo "openclaw ${FAKE_OPENCLAW_VERSION:-2026.7.1}"
  exit 0
fi

if [[ " $* " == *" sessions --all-agents --json --limit all "* ]]; then
  # openclaw >= 2026.8 prints a config-migration notice to stderr on every call.
  [[ -n "${OPENCLAW_STUB_STDERR:-}" ]] && printf '%s\n' "$OPENCLAW_STUB_STDERR" >&2
  [[ -n "${OPENCLAW_STUB_LIST_RC:-}" ]] && exit "$OPENCLAW_STUB_LIST_RC"
  [[ "${OPENCLAW_HOME:-}" == "/root" ]] || { echo 'OpenClaw home was not pinned' >&2; exit 98; }
  [[ -z "${OPENCLAW_STATE_DIR:-}${OPENCLAW_CONFIG_PATH:-}${OPENCLAW_PROFILE:-}${OPENCLAW_GATEWAY_URL:-}${OPENCLAW_GATEWAY_PORT:-}${OPENCLAW_GATEWAY_TOKEN:-}${OPENCLAW_GATEWAY_PASSWORD:-}" ]] \
    || { echo 'inherited OpenClaw selector leaked into stub' >&2; exit 98; }
  # A payload big enough to close the error path's pipe cannot travel in the
  # environment: Linux caps a single execve entry at MAX_ARG_STRLEN (128KB), so
  # exporting one silently turns every later `run` into E2BIG. Large fixtures come
  # from a file instead.
  if [[ -n "${OPENCLAW_STUB_SESSIONS_FILE:-}" ]]; then
    cat "$OPENCLAW_STUB_SESSIONS_FILE"
  else
    printf '%s\n' "$OPENCLAW_STUB_SESSIONS"
  fi
  exit 0
fi

if [[ " $* " == *" gateway call sessions.delete "* ]]; then
  params=''
  while (($#)); do
    if [[ "$1" == "--params" ]]; then
      params="$2"
      break
    fi
    shift
  done
  printf '%s\n' "$params" >> "$OPENCLAW_STUB_LOG"
  # 2026.8's real sessions.delete rejects the 7.1-era requireInactive param
  # outright — mirror that here so a regression that re-adds it on >= 2026.8
  # fails this same delete instead of silently succeeding.
  if [[ "$(printf '%s\n%s\n' "2026.8" "${FAKE_OPENCLAW_VERSION:-2026.7.1}" | sort -V | head -1)" == "2026.8" ]] \
    && jq -e 'has("requireInactive")' >/dev/null 2>&1 <<<"$params"; then
    echo "invalid sessions.delete params: at root: unexpected property 'requireInactive'" >&2
    exit 1
  fi
  if [[ "$(jq -r '.expectedSessionId' <<<"$params")" == "race" ]]; then
    echo 'Session changed before deletion. Retry.' >&2
    exit 1
  fi
  if [[ "$(jq -r '.expectedSessionId' <<<"$params")" == "broken" ]]; then
    echo 'gateway unavailable' >&2
    exit 1
  fi
  # A TRANSIENT transport timeout, copied from the real 2026-09-17 incident
  # payload. Distinct from 'broken' (an unclassifiable failure) on purpose:
  # only this shape is tolerated, and the two must not converge.
  # A transport error that is NOT a timeout. Structurally close to the
  # tolerated shape on purpose: it shares `gateway_transport_error` and only
  # differs in `kind`, which is exactly the case an alternation let through.
  if [[ "$(jq -r '.expectedSessionId' <<<"$params")" == "gwprotocol" ]]; then
    printf '%s\n' '{"ok":false,"error":{"type":"gateway_transport_error","kind":"protocol","message":"malformed response"}}' >&2
    exit 1
  fi
  if [[ "$(jq -r '.expectedSessionId' <<<"$params")" == "gwtimeout" ]]; then
    printf '%s\n' '{"ok":false,"error":{"type":"gateway_transport_error","kind":"timeout","message":"gateway timeout after 30000ms","timeoutMs":30000}}' >&2
    exit 1
  fi
  printf '%s\n' '{"ok":true,"deleted":true}'
  exit 0
fi

echo "unexpected openclaw argv: $*" >&2
exit 99
STUB
  chmod +x "$OPENCLAW_STUB"

  export OPENCLAW_STUB_SESSIONS='{
    "sessions": [
      {"key":"agent:scout:slack:channel:c1:thread:1900000000.000001","agentId":"scout","sessionId":"old-done","updatedAt":1990000000000,"status":"done"},
      {"key":"agent:ops:slack:channel:g2:thread:1900000000.000002","agentId":"ops","sessionId":"old-failed","updatedAt":1990000000001,"status":"failed"},
      {"key":"agent:scout:slack:channel:c1:thread:1999900000.000003","agentId":"scout","sessionId":"fresh","updatedAt":1999900000000,"status":"done"},
      {"key":"agent:scout:slack:channel:c1:thread:1900000000.000004","agentId":"scout","sessionId":"running","updatedAt":1990000000002,"status":"running"},
      {"key":"agent:scout:slack:channel:c1","agentId":"scout","sessionId":"channel-root","updatedAt":1990000000003,"status":"done"},
      {"key":"agent:scout:cron:86adfcce","agentId":"scout","sessionId":"cron","updatedAt":1990000000004,"status":"done"},
      {"key":"agent:scout:slack:direct:u1:thread:1900000000.000005","agentId":"scout","sessionId":"dm-thread","updatedAt":1990000000005,"status":"done"},
      {"key":"agent:scout:slack:channel:u1:thread:1900000000.000006","agentId":"scout","sessionId":"dm-as-channel","updatedAt":1990000000006,"status":"done"},
      {"key":"agent:scout:slack:group:g1:thread:1900000000.000007","agentId":"scout","sessionId":"mpim","updatedAt":1990000000006,"status":"done"},
      {"key":"agent:scout:slack:channel:c1:thread:1900000000.000009","agentId":"scout","updatedAt":1990000000007,"status":"done"}
    ]
  }'
}

@test "dry-run selects only old terminal Slack channel threads" {
  run bash "$SUT" --profile main

  [ "$status" -eq 0 ]
  [ "$(jq -r '.mode' <<<"$output")" = "dry-run" ]
  [ "$(jq -r '.eligible' <<<"$output")" -eq 2 ]
  [ "$(jq -r '.selected' <<<"$output")" -eq 2 ]
  [ ! -e "$OPENCLAW_STUB_LOG" ]
  [[ "$output" != *"86adfcce"* ]]
  [[ "$output" != *"channel-root"* ]]
  [[ "$output" != *"mpim"* ]]
}

@test "apply deletes through the gateway with optimistic concurrency guards" {
  run bash "$SUT" --profile main --apply

  [ "$status" -eq 0 ]
  [ "$(jq -r '.deleted' <<<"$output")" -eq 2 ]
  [ "$(wc -l < "$OPENCLAW_STUB_LOG")" -eq 2 ]
  jq -e 'select(.agentId == "scout" and .expectedSessionId == "old-done" and .expectedSessionUpdatedAt == 1990000000000 and .requireInactive == true and .deleteTranscript == true)' \
    "$OPENCLAW_STUB_LOG" >/dev/null
  jq -e 'select(.agentId == "ops" and .expectedSessionId == "old-failed" and .expectedSessionUpdatedAt == 1990000000001 and .deleteTranscript == true)' \
    "$OPENCLAW_STUB_LOG" >/dev/null
}

@test "a session changed before deletion is a safe race, not a failed sweep" {
  export OPENCLAW_STUB_SESSIONS='{"sessions":[
    {"key":"agent:scout:slack:channel:c1:thread:1900000000.000006","agentId":"scout","sessionId":"race","updatedAt":1990000000000,"status":"done"}
  ]}'

  run bash "$SUT" --profile main --apply

  [ "$status" -eq 0 ]
  [ "$(jq -r '.raced' <<<"$output")" -eq 1 ]
  [ "$(jq -r '.failed' <<<"$output")" -eq 0 ]
}

@test "an unexpected gateway failure fails loud after printing the summary" {
  export OPENCLAW_STUB_SESSIONS='{"sessions":[
    {"key":"agent:scout:slack:channel:c1:thread:1900000000.000007","agentId":"scout","sessionId":"broken","updatedAt":1990000000000,"status":"killed"},
    {"key":"agent:scout:slack:channel:c1:thread:1900000000.000008","agentId":"scout","sessionId":"would-starve","updatedAt":1990000000001,"status":"done"}
  ]}'

  run bash "$SUT" --profile main --apply

  [ "$status" -eq 1 ]
  [ "$(jq -r '.failed' <<<"$output")" -eq 1 ]
  [ "$(jq -r '.selected' <<<"$output")" -eq 2 ]
  [ "$(wc -l < "$OPENCLAW_STUB_LOG")" -eq 1 ]
}

@test "the per-run cap bounds gateway mutations" {
  export SESSION_THREAD_MAX_DELETES=1

  run bash "$SUT" --profile main --apply

  [ "$status" -eq 0 ]
  [ "$(jq -r '.eligible' <<<"$output")" -eq 2 ]
  [ "$(jq -r '.selected' <<<"$output")" -eq 1 ]
  [ "$(wc -l < "$OPENCLAW_STUB_LOG")" -eq 1 ]
}

@test "overflowing retention inputs fail before any deletion" {
  export SESSION_THREAD_RETENTION_DAYS=9223372036854775807

  run bash "$SUT" --profile main --apply

  [ "$status" -eq 2 ]
  [[ "$output" == *"1..3650"* ]]
  [ ! -e "$OPENCLAW_STUB_LOG" ]
}

@test "timed-out threads are terminal and eligible" {
  export OPENCLAW_STUB_SESSIONS='{"sessions":[
    {"key":"agent:scout:slack:channel:c1:thread:1900000000.000008","agentId":"scout","sessionId":"timeout","updatedAt":1990000000000,"status":"timeout"}
  ]}'

  run bash "$SUT" --profile main --apply

  [ "$status" -eq 0 ]
  [ "$(jq -r '.deleted' <<<"$output")" -eq 1 ]
}

@test "a legacy row without sessionId is excluded rather than weakly deleted" {
  export OPENCLAW_STUB_SESSIONS='{"sessions":[
    {"key":"agent:scout:slack:channel:c1:thread:1900000000.000010","agentId":"scout","updatedAt":1990000000000,"status":"done"}
  ]}'

  run bash "$SUT" --profile main --apply

  [ "$status" -eq 0 ]
  [ "$(jq -r '.eligible' <<<"$output")" -eq 0 ]
  [ ! -e "$OPENCLAW_STUB_LOG" ]
}

@test "explicit profile selection ignores inherited OpenClaw profile state" {
  export OPENCLAW_STATE_DIR=/wrong/state
  export OPENCLAW_CONFIG_PATH=/wrong/config.json
  export OPENCLAW_PROFILE=wrong
  export OPENCLAW_HOME=/wrong/home
  export OPENCLAW_GATEWAY_URL=ws://wrong.invalid
  export OPENCLAW_GATEWAY_PORT=1
  export OPENCLAW_GATEWAY_TOKEN=wrong
  export OPENCLAW_GATEWAY_PASSWORD=wrong

  run bash "$SUT" --profile edge

  [ "$status" -eq 0 ]
  [ "$(jq -r '.profile' <<<"$output")" = "edge" ]
}

@test "installer schedules main and edge as independent template instances" {
  grep -Fq 'hydra-session-thread-retention@.service' "$REPO_ROOT/scripts/install-aux-units.sh"
  grep -Fq 'ExecStart=$HYDRA_ROOT/scripts/prune-completed-slack-thread-sessions.sh --profile %i --apply' \
    "$REPO_ROOT/scripts/install-aux-units.sh"
  grep -Fq 'for profile in main edge; do' "$REPO_ROOT/scripts/install-aux-units.sh"
  grep -Fq 'TimeoutStartSec=60min' "$REPO_ROOT/scripts/install-aux-units.sh"
  grep -Fq '|| fail "could not enable $retention_tmr"' "$REPO_ROOT/scripts/install-aux-units.sh"
  grep -Fq '|| fail "could not start $retention_tmr"' "$REPO_ROOT/scripts/install-aux-units.sh"
  grep -Fq '$retention_tmr is not active' "$REPO_ROOT/scripts/install-aux-units.sh"
  ! grep -Fq 'hydra-session-thread-retention.service' "$REPO_ROOT/scripts/install-aux-units.sh"
}

# ── openclaw >= 2026.8: requireInactive is retired ───────────────────────────
# Staging-verified 2026-08-31 (Gate E) against a live 2026.8.1 gateway:
# sessions.delete REJECTS requireInactive outright
# (INVALID_REQUEST: "unexpected property 'requireInactive'"). The stub above
# reproduces that exact rejection for ANY payload carrying the key once
# FAKE_OPENCLAW_VERSION is >= 2026.8, so this is a real regression trap: if
# the param is ever re-added to the 2026.8+ branch, this delete fails and
# `deleted` drops below 1 / `failed` rises above 0.

@test "2026.8+: apply omits requireInactive and still deletes" {
  export FAKE_OPENCLAW_VERSION=2026.8.1
  export OPENCLAW_STUB_SESSIONS='{"sessions":[
    {"key":"agent:scout:slack:channel:c1:thread:1900000000.000001","agentId":"scout","sessionId":"old-done","updatedAt":1990000000000,"status":"done"}
  ]}'

  run bash "$SUT" --profile main --apply

  [ "$status" -eq 0 ]
  [ "$(jq -r '.deleted' <<<"$output")" -eq 1 ]
  [ "$(jq -r '.failed' <<<"$output")" -eq 0 ]
  [ "$(wc -l < "$OPENCLAW_STUB_LOG")" -eq 1 ]
  jq -e 'select(.agentId == "scout" and .expectedSessionId == "old-done" and .expectedSessionUpdatedAt == 1990000000000 and .deleteTranscript == true and (has("requireInactive") | not))' \
    "$OPENCLAW_STUB_LOG" >/dev/null
}

@test "below 2026.8: apply still sends requireInactive unchanged" {
  export FAKE_OPENCLAW_VERSION=2026.7.1
  export OPENCLAW_STUB_SESSIONS='{"sessions":[
    {"key":"agent:scout:slack:channel:c1:thread:1900000000.000001","agentId":"scout","sessionId":"old-done","updatedAt":1990000000000,"status":"done"}
  ]}'

  run bash "$SUT" --profile main --apply

  [ "$status" -eq 0 ]
  [ "$(jq -r '.deleted' <<<"$output")" -eq 1 ]
  jq -e 'select(.requireInactive == true)' "$OPENCLAW_STUB_LOG" >/dev/null
}

@test "2026.8+: a session that cannot safely stop before deletion is a race, not a failure" {
  export FAKE_OPENCLAW_VERSION=2026.8.1
  export OPENCLAW_STUB_SESSIONS='{"sessions":[
    {"key":"agent:scout:slack:channel:c1:thread:1900000000.000006","agentId":"scout","sessionId":"race","updatedAt":1990000000000,"status":"done"}
  ]}'
  # The generic stub only special-cases expectedSessionId "race" for the
  # pre-existing "changed before deletion" message; override it here to
  # exercise the new "could not safely stop" alternation instead.
  cat > "$OPENCLAW_STUB" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
if [[ " $* " == *" --version "* ]]; then
  echo "openclaw ${FAKE_OPENCLAW_VERSION:-2026.7.1}"
  exit 0
fi
if [[ " $* " == *" sessions --all-agents --json --limit all "* ]]; then
  printf '%s\n' "$OPENCLAW_STUB_SESSIONS"
  exit 0
fi
if [[ " $* " == *" gateway call sessions.delete "* ]]; then
  echo "Session agent:scout:slack:channel:c1:thread:1900000000.000006 could not safely stop before deletion: active work in progress. Retry after active work or worker recovery finishes." >&2
  exit 1
fi
echo "unexpected openclaw argv: $*" >&2
exit 99
STUB
  chmod +x "$OPENCLAW_STUB"

  run bash "$SUT" --profile main --apply

  [ "$status" -eq 0 ]
  [ "$(jq -r '.raced' <<<"$output")" -eq 1 ]
  [ "$(jq -r '.failed' <<<"$output")" -eq 0 ]
}

# ── QA bot finding (PR #897, 2026-08-31): an unparseable runtime version must
# abort loudly BEFORE any gateway mutation, never silently fall back to the
# pre-2026.8 requireInactive payload shape — that shape fails every delete on
# an actual 2.0 gateway (silent pruning outage). FAKE_OPENCLAW_VERSION's own
# `${:-default}` can't express "produced nothing", so this overrides the stub.
@test "unparseable runtime version: aborts loudly before any gateway mutation" {
  cat > "$OPENCLAW_STUB" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
if [[ " $* " == *" --version "* || "${*: -1}" == "--version" ]]; then
  echo ""
  exit 0
fi
echo "unexpected openclaw argv (should never be reached): $*" >&2
exit 99
STUB
  chmod +x "$OPENCLAW_STUB"

  run bash "$SUT" --profile main --apply
  [ "$status" -ne 0 ]
  [[ "$output" == *"could not determine openclaw runtime version"* ]]
  [ ! -e "$OPENCLAW_STUB_LOG" ]
}

# QA bot finding (PR #897 round 2): emptiness alone was checked, but any
# NON-empty garbage token (e.g. a mangled "OpenClaw 2026.invalid" whose
# second awk field is "2026.invalid") passed straight through into
# version_at_least, which selected a payload shape from an unspecified
# sort -V comparison instead of refusing to guess.
@test "garbage (non-version-shaped) runtime version: aborts loudly before any gateway mutation" {
  cat > "$OPENCLAW_STUB" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
if [[ " $* " == *" --version "* || "${*: -1}" == "--version" ]]; then
  echo "OpenClaw 2026.invalid"
  exit 0
fi
echo "unexpected openclaw argv (should never be reached): $*" >&2
exit 99
STUB
  chmod +x "$OPENCLAW_STUB"

  run bash "$SUT" --profile main --apply
  [ "$status" -ne 0 ]
  [[ "$output" == *"could not determine openclaw runtime version"* ]]
  [ ! -e "$OPENCLAW_STUB_LOG" ]
}

# Regression: openclaw >= 2026.8 prints "Config (...): Moved agents.list to keyed
# agents.entries." to stderr on EVERY CLI call while the on-disk config still uses the
# old shape. The list capture used `2>&1`, so those prose lines were prepended to the
# JSON, `.sessions | type == "array"` failed, and the sweep pruned NOTHING from the
# 2026.8.2 cutover onward while reporting only a broken pipe.
@test "a config-migration notice on stderr does not corrupt the session list" {
  export OPENCLAW_STUB_STDERR="Config (/root/.openclaw-main/openclaw.json): Moved agents.list to keyed agents.entries.
Config (/root/.openclaw-main/openclaw.json): Removed retired agents.entries.*.default markers."

  run bash "$SUT" --profile main

  [ "$status" -eq 0 ]
  [ "$(jq -r '.mode' <<<"$output")" = "dry-run" ]
  [ "$(jq -r '.eligible' <<<"$output")" -eq 2 ]
}

# The error path itself used `printf '%s' "$json" | head -c 500`. Under `set -euo
# pipefail` head closes the pipe at 500 bytes, printf takes SIGPIPE (141), and pipefail
# promoted that to the script's status — so a genuine list failure aborted with a bare
# "write error: Broken pipe" and the SESSION_LIST_FAILED diagnostic never printed.
# The payload here is deliberately longer than 500 bytes to close that pipe.
@test "a failing session list reports SESSION_LIST_FAILED instead of dying on a broken pipe" {
  # The payload MUST exceed the 64KB pipe buffer or printf completes before head
  # exits and no SIGPIPE is raised — at 4KB this test passed against the very bug it
  # exists to catch. Production saw 1.7MB.
  #
  # It is delivered through a FILE, not the environment. An earlier revision
  # exported 200KB here, which exceeds Linux's per-entry MAX_ARG_STRLEN (32 pages
  # = 131072 bytes): execve then fails E2BIG for every subsequent `run` in this
  # file and the whole suite reds out before it can test the fix. A file has no
  # such ceiling, so the payload can stay comfortably above the pipe buffer.
  export OPENCLAW_STUB_SESSIONS_FILE="$BATS_TEST_TMPDIR/big-sessions.json"
  head -c 200000 < /dev/zero | tr '\0' 'x' > "$OPENCLAW_STUB_SESSIONS_FILE"

  run bash "$SUT" --profile main

  [ "$status" -eq 1 ]
  [[ "$output" != *"Broken pipe"* ]]
  [ "$(jq -r '.error' <<<"$output")" = "SESSION_LIST_FAILED" ]
  [ "$(jq -r '.detail' <<<"$output" | wc -c)" -le 520 ]
}

# A real failure must keep its diagnostic even though stderr is no longer folded in.
@test "SESSION_LIST_FAILED carries the CLI stderr for diagnosis" {
  export OPENCLAW_STUB_STDERR="boom: gateway unreachable"
  export OPENCLAW_STUB_LIST_RC=3

  run bash "$SUT" --profile main

  [ "$status" -eq 1 ]
  [ "$(jq -r '.error' <<<"$output")" = "SESSION_LIST_FAILED" ]
  [[ "$(jq -r '.stderr' <<<"$output")" == *"gateway unreachable"* ]]
}


# ── transient gateway failure must not page (2026-09-17 incident) ──────────
# The gateway saturated during a deploy; one sessions.delete hit
# `gateway timeout after 30000ms` AFTER 5 successful deletions, and this unit
# exited 1 and paged with nothing for a human to do -- while the same
# saturation was already paging through the deploy rollback. The failed
# session stays ELIGIBLE, so the next 6h run retries it and nothing is lost.

@test "a transient gateway timeout AFTER progress does not page" {
  export OPENCLAW_STUB_SESSIONS='{"sessions":[
    {"key":"agent:scout:slack:channel:c1:thread:1900000000.000101","agentId":"scout","sessionId":"old-done","updatedAt":1990000000000,"status":"done"},
    {"key":"agent:scout:slack:channel:c1:thread:1900000000.000102","agentId":"scout","sessionId":"gwtimeout","updatedAt":1990000000001,"status":"done"}
  ]}'

  run bash "$SUT" --profile main --apply

  [ "$status" -eq 0 ]                                   # no page
  [ "$(jq -r '.deleted' <<<"$output")" -eq 1 ]          # progress was real
  [ "$(jq -r '.failed'  <<<"$output")" -eq 1 ]          # and still RECORDED
  echo "$output" | grep -q 'TRANSIENT gateway failure'
  echo "$output" | grep -q 'next run retries'
}

@test "a transient timeout with ZERO progress still pages" {
  # No progress means the sweep accomplished nothing; that is a real problem
  # even though the error itself is transient-shaped.
  export OPENCLAW_STUB_SESSIONS='{"sessions":[
    {"key":"agent:scout:slack:channel:c1:thread:1900000000.000103","agentId":"scout","sessionId":"gwtimeout","updatedAt":1990000000000,"status":"done"}
  ]}'

  run bash "$SUT" --profile main --apply

  [ "$status" -eq 1 ]
  [ "$(jq -r '.deleted' <<<"$output")" -eq 0 ]
  [ "$(jq -r '.failed'  <<<"$output")" -eq 1 ]
}

@test "an UNCLASSIFIABLE failure after progress still pages — fail closed" {
  # The scope guard. The tolerance covers exactly one recognised shape; any
  # other failure must keep paging even when deletions succeeded first,
  # because "could not classify" must never become "assumed fine".
  export OPENCLAW_STUB_SESSIONS='{"sessions":[
    {"key":"agent:scout:slack:channel:c1:thread:1900000000.000104","agentId":"scout","sessionId":"old-done","updatedAt":1990000000000,"status":"done"},
    {"key":"agent:scout:slack:channel:c1:thread:1900000000.000105","agentId":"scout","sessionId":"broken","updatedAt":1990000000001,"status":"done"}
  ]}'

  run bash "$SUT" --profile main --apply

  [ "$status" -eq 1 ]
  [ "$(jq -r '.deleted' <<<"$output")" -eq 1 ]
  echo "$output" | grep -qv 'TRANSIENT gateway failure'
}

@test "a clean run still exits 0 and reports no failures" {
  # Guards the ordinary path against the new branching.
  run bash "$SUT" --profile main --apply
  [ "$status" -eq 0 ]
  [ "$(jq -r '.failed' <<<"$output")" -eq 0 ]
}

@test "a NON-timeout gateway_transport_error after progress still pages" {
  # QA finding on #979: the first cut matched `gateway_transport_error` OR the
  # timeout message, so a `kind:"protocol"` failure — a malformed response,
  # not self-healing — suppressed the page after one successful deletion.
  # Only an actual timeout is tolerated.
  export OPENCLAW_STUB_SESSIONS='{"sessions":[
    {"key":"agent:scout:slack:channel:c1:thread:1900000000.000106","agentId":"scout","sessionId":"old-done","updatedAt":1990000000000,"status":"done"},
    {"key":"agent:scout:slack:channel:c1:thread:1900000000.000107","agentId":"scout","sessionId":"gwprotocol","updatedAt":1990000000001,"status":"done"}
  ]}'

  run bash "$SUT" --profile main --apply

  [ "$status" -eq 1 ]                                   # must still page
  [ "$(jq -r '.deleted' <<<"$output")" -eq 1 ]           # despite progress
  [ "$(jq -r '.failed'  <<<"$output")" -eq 1 ]
  echo "$output" | grep -qv 'TRANSIENT gateway failure'
}
