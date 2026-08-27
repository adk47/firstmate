#!/usr/bin/env bats
#
# Both writers of a live openclaw config must take the SAME lock across their
# whole read -> transform -> announce -> rename cycle.
#
# THE RACE THIS PINS (QA finding on PR #870): preserving `.mcp.servers` is a
# read-modify-write. deploy/rollback's sync_profile_config reads the live file,
# builds a merged temp file, then renames. If the Sentry healer (watchdog tick or
# ExecStartPre) renames its own result in between, the sync's rename overwrites
# it with a snapshot taken BEFORE it existed. The healer has already logged
# "HEALED" and exited 0, so the registration disappears microseconds after a
# success line. Atomic rename makes each write indivisible; it does NOT make
# read-then-write serialisable.
#
# These tests do not rely on timing luck: the competing writer is a real held
# flock, so "did it wait?" is deterministic.
bats_require_minimum_version 1.5.0

REPO="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
LIB="$REPO/scripts/lib/sync-profile-config.sh"
HEALER="$REPO/scripts/lib/ensure-sentry-mcp.sh"

setup() {
  TMP="$BATS_TEST_TMPDIR/c"; mkdir -p "$TMP"
  CFG="$TMP/openclaw.json"
  SRC="$TMP/repo-openclaw.json"
  printf '%s\n' '{"profile":"main","agents":{"list":[{"id":"cto"}]}}' > "$SRC"
  printf '%s\n' '{"profile":"stale","agents":{"list":[{"id":"cto"}]},"mcp":{"servers":{"sentry":{"url":"https://mcp.sentry.dev/mcp","headers":{"Authorization":"Sentry-Bearer tok"}}}}}' > "$CFG"
  export ENSURE_SENTRY_MCP_CFG="$CFG"
  export ENSURE_SENTRY_MCP_SECRETS="$TMP/sentry.env"
  printf 'SENTRY_API_TOKEN=sntryu_tok\n' > "$ENSURE_SENTRY_MCP_SECRETS"; chmod 600 "$ENSURE_SENTRY_MCP_SECRETS"
  export ENSURE_SENTRY_MCP_ANNOUNCE="$TMP/noop.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$TMP/noop.sh"; chmod +x "$TMP/noop.sh"
  export SPC_ANNOUNCE_HELPER="$TMP/noop.sh"
}

lockpath() { printf '%s.writers.lock' "$CFG"; }

@test "both writers agree on the lock path (a coincidence is not a lock)" {
  # shellcheck source=/dev/null
  source "$LIB"
  from_lib="$(spc_config_lock_path "$CFG")"
  # the healer resolves the same helper, whether sourced from the lib or its fallback
  from_healer="$(ENSURE_SENTRY_MCP_CFG="$CFG" bash -c '
      source "$1" 2>/dev/null
      if ! declare -F spc_config_lock_path >/dev/null; then
        spc_config_lock_path() { printf "%s.writers.lock" "$1"; }
      fi
      spc_config_lock_path "$2"' _ "$LIB" "$CFG")"
  [ "$from_lib" = "$from_healer" ]
  # and it must NOT be the config's own inode — that lock would follow the file
  # we are about to replace by rename
  [ "$from_lib" != "$CFG" ]
}

@test "sync_profile_config REFUSES rather than writing while another writer holds the lock" {
  # shellcheck source=/dev/null
  source "$LIB"
  before="$(sha256sum "$CFG" | cut -d' ' -f1)"
  exec 8>"$(lockpath)"; flock 8            # a competing writer holds it
  run env SPC_LOCK_WAIT=1 bash -c 'source "$1"; sync_profile_config "$2" "$3" test' _ "$LIB" "$SRC" "$CFG"
  exec 8>&-
  [ "$status" -ne 0 ]
  [[ "$output" == *"timed out"* ]]
  # the whole point: it did NOT fall through and write unlocked
  [ "$(sha256sum "$CFG" | cut -d' ' -f1)" = "$before" ]
}

@test "the healer REFUSES rather than writing while another writer holds the lock" {
  printf '%s\n' '{"agents":{"list":[{"id":"cto"}]}}' > "$CFG"   # sentry absent => it wants to heal
  before="$(sha256sum "$CFG" | cut -d' ' -f1)"
  exec 8>"$(lockpath)"; flock 8
  run env ENSURE_SENTRY_MCP_LOCK_WAIT=1 "$HEALER"
  exec 8>&-
  [ "$status" -ne 0 ]
  [ "$(sha256sum "$CFG" | cut -d' ' -f1)" = "$before" ]
}

@test "INTERLEAVING: a heal that lands mid-sync is not silently discarded" {
  # The real race, made deterministic. Hold the lock (standing in for a sync that
  # has read but not yet renamed), start the healer, and prove it BLOCKS instead
  # of racing to a rename that the other writer would clobber.
  printf '%s\n' '{"agents":{"list":[{"id":"cto"}]}}' > "$CFG"
  exec 8>"$(lockpath)"; flock 8

  # 8>&- is load-bearing: without it the background child INHERITS fd 8 (the very
  # descriptor holding the lock, since flock is tied to the open file
  # description, not the fd number). The healer would then block against its own
  # inherited handle, time out, and never write -- a harness artefact that looks
  # exactly like a broken lock.
  ENSURE_SENTRY_MCP_LOCK_WAIT=30 "$HEALER" >"$TMP/heal.out" 2>&1 8>&- &
  healer_pid=$!
  sleep 2
  # while the lock is held it must NOT have written
  run jq -r '.mcp.servers.sentry // "ABSENT"' "$CFG"
  [ "$output" = "ABSENT" ]
  kill -0 "$healer_pid"                     # still alive, i.e. waiting not failed

  exec 8>&-                                 # the other writer finishes

  # Poll for completion rather than `wait`: under bats the background job is not
  # always a child of the shell running the test body, so `wait` returns 2
  # ("not a child") and would fail the test for a harness reason, not a real one.
  for _ in $(seq 1 60); do
    kill -0 "$healer_pid" 2>/dev/null || break
    sleep 1
  done
  run kill -0 "$healer_pid"
  [ "$status" -ne 0 ]                       # it finished

  # now, and only now, the heal lands
  run jq -r '.mcp.servers.sentry.url' "$CFG"
  [ "$output" = "https://mcp.sentry.dev/mcp" ]
}

@test "serialised writers both complete and leave valid JSON" {
  printf '%s\n' '{"agents":{"list":[{"id":"cto"}]}}' > "$CFG"
  ( ENSURE_SENTRY_MCP_LOCK_WAIT=30 "$HEALER" >/dev/null 2>&1 8>&- ) &
  ( SPC_LOCK_WAIT=30 bash -c 'source "$1"; sync_profile_config "$2" "$3" test' _ "$LIB" "$SRC" "$CFG" >/dev/null 2>&1 ) &
  wait
  run jq -e . "$CFG"
  [ "$status" -eq 0 ]
  # repo content won either way; the file is never torn
  run jq -r '.profile' "$CFG"
  [ "$output" = "main" ]
}
