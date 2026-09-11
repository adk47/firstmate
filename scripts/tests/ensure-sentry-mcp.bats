#!/usr/bin/env bats
#
# scripts/lib/ensure-sentry-mcp.sh — converge the runtime Sentry MCP entry.
#
# WHY THIS HEALER EXISTS (2026-08-26): the registration is runtime-only because
# it carries a token that is never committed. A failed deploy attempt fired
# rollback.sh, which restored profile configs with a plain `cp`, and the
# registration was destroyed 17h after it was made with no alert. rollback.sh is
# fixed, but this healer is the layer that makes the CAUSE irrelevant.
#
# The two behaviours most worth pinning:
#   * a header of "Sentry-Bearer " with NO token must count as DRIFT, not as
#     registered. That config looks healthy and 401s on every call -- the exact
#     trap the original registration recipe hit.
#   * every failure path must leave the LIVE config untouched.
bats_require_minimum_version 1.5.0

HEALER="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)/scripts/lib/ensure-sentry-mcp.sh"

setup() {
  TMP="$BATS_TEST_TMPDIR/c"; mkdir -p "$TMP"
  export ENSURE_SENTRY_MCP_CFG="$TMP/openclaw.json"
  export ENSURE_SENTRY_MCP_SECRETS="$TMP/sentry.env"
  export ENSURE_SENTRY_MCP_ANNOUNCE="$TMP/announce.sh"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "$TMP_ANNOUNCE_LOG"\nexit 0\n' > "$TMP/announce.sh"
  chmod +x "$TMP/announce.sh"
  export TMP_ANNOUNCE_LOG="$TMP/announce.log"

  cfg_without_sentry
  secrets_ok
  # The healer's ESM_ENABLED constant now DEFAULTS TO DISABLED (PR #929: the
  # sentry MCP is switched off until Aaron rules on fleet-wide
  # sentry__update_issue access). Every test below this line exercises the
  # REGISTRATION path, so it must opt in explicitly; the disabled-branch tests
  # at the end of this file override it back to 0. Exported in setup rather
  # than prefixed onto `run` — a `VAR=x run ...` prefix is not reliably
  # delivered to the process under test.
  export ENSURE_SENTRY_MCP_ENABLED=1
}

cfg_without_sentry() {
  printf '%s\n' '{"agents":{"list":[{"id":"cto"},{"id":"qa"}]},"plugins":{"installs":[]}}' \
    > "$ENSURE_SENTRY_MCP_CFG"
}
cfg_with() { printf '%s\n' "$1" > "$ENSURE_SENTRY_MCP_CFG"; }
secrets_ok() {
  printf 'SENTRY_API_TOKEN=sntryu_realtoken123\n' > "$ENSURE_SENTRY_MCP_SECRETS"
  chmod 600 "$ENSURE_SENTRY_MCP_SECRETS"
}
authz() { jq -r '.mcp.servers.sentry.headers.Authorization // "ABSENT"' "$ENSURE_SENTRY_MCP_CFG"; }

# ── converge ──────────────────────────────────────────────────────────────

@test "registers sentry when it is missing" {
  run "$HEALER"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.mcp.servers.sentry.url' "$ENSURE_SENTRY_MCP_CFG")" = "https://mcp.sentry.dev/mcp" ]
  [ "$(authz)" = "Sentry-Bearer sntryu_realtoken123" ]
  [ "$(jq -r '.mcp.servers.sentry.transport' "$ENSURE_SENTRY_MCP_CFG")" = "streamable-http" ]
}

@test "converging preserves the rest of the config" {
  run "$HEALER"
  [ "$(jq -r '.agents.list | length' "$ENSURE_SENTRY_MCP_CFG")" -eq 2 ]
  [ "$(jq -r '.agents.list[0].id' "$ENSURE_SENTRY_MCP_CFG")" = "cto" ]
}

@test "already-correct config is a no-op and does not rewrite" {
  run "$HEALER"
  before="$(sha256sum "$ENSURE_SENTRY_MCP_CFG" | cut -d' ' -f1)"
  run "$HEALER"
  [ "$status" -eq 0 ]
  [ "$(sha256sum "$ENSURE_SENTRY_MCP_CFG" | cut -d' ' -f1)" = "$before" ]
}

@test "converge SAYS SO when it finds nothing to fix, so a clean run is provable" {
  # Direction first: a healthy converge must leave EVIDENCE, not be silent.
  # openclaw-pre-start-heal.sh calls the healer without --check, and while that
  # path was silent on success "the healer ran and was fine" and "the healer
  # never ran" produced identical logs -- the exact state you want to assert
  # after an incident was the one that left no trace.
  run "$HEALER"                     # first pass registers it (logs HEALED)
  [ "$status" -eq 0 ]
  [[ "$output" == *"HEALED"* ]]
  run "$HEALER"                     # second pass has nothing to do
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK: sentry MCP registered, well-formed and current."* ]]
}

@test "an EMPTY token in an existing header counts as drift and is repaired" {
  # This config looks registered and 401s on every call.
  cfg_with '{"agents":{"list":[{"id":"cto"}]},"mcp":{"servers":{"sentry":{"url":"https://mcp.sentry.dev/mcp","transport":"streamable-http","headers":{"Authorization":"Sentry-Bearer "}}}}}'
  run "$HEALER" --check
  [ "$status" -eq 1 ]
  run "$HEALER"
  [ "$status" -eq 0 ]
  [ "$(authz)" = "Sentry-Bearer sntryu_realtoken123" ]
}

@test "a wrong url counts as drift and is repaired" {
  cfg_with '{"agents":{"list":[{"id":"cto"}]},"mcp":{"servers":{"sentry":{"url":"https://evil.example/mcp","transport":"streamable-http","headers":{"Authorization":"Sentry-Bearer x"}}}}}'
  run "$HEALER"
  [ "$(jq -r '.mcp.servers.sentry.url' "$ENSURE_SENTRY_MCP_CFG")" = "https://mcp.sentry.dev/mcp" ]
}

@test "the write is announced, or the audit watcher pages on a legitimate write" {
  run "$HEALER"
  grep -q 'ensure-sentry-mcp' "$TMP_ANNOUNCE_LOG"
}

# ── --check ───────────────────────────────────────────────────────────────

@test "--check reports clean when registered" {
  run "$HEALER"
  run "$HEALER" --check
  [ "$status" -eq 0 ]
}

@test "--check reports drift when missing, and changes nothing" {
  before="$(sha256sum "$ENSURE_SENTRY_MCP_CFG" | cut -d' ' -f1)"
  run "$HEALER" --check
  [ "$status" -eq 1 ]
  [ "$(sha256sum "$ENSURE_SENTRY_MCP_CFG" | cut -d' ' -f1)" = "$before" ]
}

@test "--check on an unreadable config is UNKNOWN (2), never clean" {
  rm -f "$ENSURE_SENTRY_MCP_CFG"
  run "$HEALER" --check
  [ "$status" -eq 2 ]
}

@test "--check on invalid JSON is UNKNOWN (2), never clean" {
  printf 'not json\n' > "$ENSURE_SENTRY_MCP_CFG"
  run "$HEALER" --check
  [ "$status" -eq 2 ]
}

@test "a MISSING transport is drift, not OK" {
  # url + current token but no transport = an entry openclaw cannot use. Without
  # this, --check exits 0 and both repair paths skip it.
  cfg_with '{"agents":{"list":[{"id":"cto"}]},"mcp":{"servers":{"sentry":{"url":"https://mcp.sentry.dev/mcp","headers":{"Authorization":"Sentry-Bearer sntryu_realtoken123"}}}}}'
  run "$HEALER" --check
  [ "$status" -eq 1 ]
}

@test "a WRONG transport is drift, not OK" {
  # stdio/mcp-remote is exactly what this repo's lint rejects; it must never
  # read as healthy.
  cfg_with '{"agents":{"list":[{"id":"cto"}]},"mcp":{"servers":{"sentry":{"url":"https://mcp.sentry.dev/mcp","transport":"stdio","headers":{"Authorization":"Sentry-Bearer sntryu_realtoken123"}}}}}'
  run "$HEALER" --check
  [ "$status" -eq 1 ]
  run "$HEALER"
  [ "$(jq -r '.mcp.servers.sentry.transport' "$ENSURE_SENTRY_MCP_CFG")" = "streamable-http" ]
}

# ── currency: well-formed is not the same as current ──────────────────────

@test "THE ROTATION TRAP: a stale token is DRIFT, not OK" {
  # Checking only "url right, token non-empty" lets a revoked credential survive
  # forever: --check says OK, the watchdog says OK, every Sentry call 401s, and
  # nothing points at the cause. The token really was rotated on 2026-08-26.
  cfg_with '{"agents":{"list":[{"id":"cto"}]},"mcp":{"servers":{"sentry":{"url":"https://mcp.sentry.dev/mcp","transport":"streamable-http","headers":{"Authorization":"Sentry-Bearer sntryu_REVOKED_OLD"}}}}}'
  run "$HEALER" --check
  [ "$status" -eq 1 ]
  [[ "$output" == *"does not match"* ]]
}

@test "a stale token is repaired to the current one" {
  cfg_with '{"agents":{"list":[{"id":"cto"}]},"mcp":{"servers":{"sentry":{"url":"https://mcp.sentry.dev/mcp","transport":"streamable-http","headers":{"Authorization":"Sentry-Bearer sntryu_REVOKED_OLD"}}}}}'
  run "$HEALER"
  [ "$status" -eq 0 ]
  [ "$(authz)" = "Sentry-Bearer sntryu_realtoken123" ]
}

@test "neither the live nor the expected token is ever printed" {
  cfg_with '{"agents":{"list":[{"id":"cto"}]},"mcp":{"servers":{"sentry":{"url":"https://mcp.sentry.dev/mcp","transport":"streamable-http","headers":{"Authorization":"Sentry-Bearer sntryu_REVOKED_OLD"}}}}}'
  run "$HEALER" --check
  [[ "$output" != *"sntryu_REVOKED_OLD"* ]]
  [[ "$output" != *"sntryu_realtoken123"* ]]
}

@test "a matching token reports OK and says it is current" {
  run "$HEALER"
  run "$HEALER" --check
  [ "$status" -eq 0 ]
  [[ "$output" == *"current"* ]]
}

@test "--check is UNVERIFIABLE (2) when the source of truth cannot be read" {
  # The entry looks fine but currency cannot be proven. That is the third state:
  # not clean, not a known failure. It must not silently pass.
  run "$HEALER"
  rm -f "$ENSURE_SENTRY_MCP_SECRETS"
  run "$HEALER" --check
  [ "$status" -eq 2 ]
  [[ "$output" == *"UNVERIFIABLE"* ]]
}

# ── fail-closed ───────────────────────────────────────────────────────────

@test "an absent secrets file cannot heal and leaves the config untouched" {
  rm -f "$ENSURE_SENTRY_MCP_SECRETS"
  before="$(sha256sum "$ENSURE_SENTRY_MCP_CFG" | cut -d' ' -f1)"
  run "$HEALER"
  [ "$status" -eq 2 ]
  [[ "$output" == *"CANNOT HEAL"* ]]
  [ "$(sha256sum "$ENSURE_SENTRY_MCP_CFG" | cut -d' ' -f1)" = "$before" ]
}

@test "a world-readable secrets file is REFUSED, not propagated" {
  chmod 644 "$ENSURE_SENTRY_MCP_SECRETS"
  run "$HEALER"
  [ "$status" -eq 2 ]
  [[ "$output" == *"REFUSING"* ]]
  [ "$(jq -r '.mcp.servers.sentry // "ABSENT"' "$ENSURE_SENTRY_MCP_CFG")" = "ABSENT" ]
}

@test "a secrets file with no token value cannot heal" {
  printf 'SOMETHING_ELSE=1\n' > "$ENSURE_SENTRY_MCP_SECRETS"
  chmod 600 "$ENSURE_SENTRY_MCP_SECRETS"
  run "$HEALER"
  [ "$status" -eq 2 ]
  [ "$(jq -r '.mcp.servers.sentry // "ABSENT"' "$ENSURE_SENTRY_MCP_CFG")" = "ABSENT" ]
}

@test "invalid JSON is left for pre-start-heal, never overwritten" {
  printf 'not json\n' > "$ENSURE_SENTRY_MCP_CFG"
  run "$HEALER"
  [ "$status" -eq 2 ]
  [ "$(cat "$ENSURE_SENTRY_MCP_CFG")" = "not json" ]
}

@test "a failed announce aborts before the rename" {
  printf '#!/usr/bin/env bash\nexit 1\n' > "$TMP/announce.sh"; chmod +x "$TMP/announce.sh"
  before="$(sha256sum "$ENSURE_SENTRY_MCP_CFG" | cut -d' ' -f1)"
  run "$HEALER"
  [ "$status" -eq 2 ]
  [ "$(sha256sum "$ENSURE_SENTRY_MCP_CFG" | cut -d' ' -f1)" = "$before" ]
}

@test "no temp files are left behind on a failure path" {
  rm -f "$ENSURE_SENTRY_MCP_SECRETS"
  run "$HEALER"
  run bash -c "ls $TMP/tmp.* 2>/dev/null | wc -l"
  [ "$output" -eq 0 ]
}

@test "the token never appears in the healer's own output" {
  run "$HEALER"
  [[ "$output" != *"sntryu_realtoken123"* ]]
}

# ──────────────────────────────────────────────────────────────
# The kill switch (PR #929). ESM_ENABLED=0 makes the healer STRIP the entry
# instead of registering it — the only place a PR can control the registration,
# because `.mcp` is absent from the repo configs, sync-profile-config.sh
# preserves the live `.mcp.servers` across deploys, and this healer re-registers
# on every main start (openclaw-pre-start-heal.sh:124).
# ──────────────────────────────────────────────────────────────

cfg_with_sentry_and_other() {
  cfg_with '{"agents":{"list":[{"id":"cto"},{"id":"qa"}]},"mcp":{"servers":{"sentry":{"transport":"streamable-http","url":"https://mcp.sentry.dev/mcp","headers":{"Authorization":"Sentry-Bearer sntryu_realtoken123"}},"othersrv":{"transport":"streamable-http","url":"https://example.invalid/mcp"}}}}'
}

@test "disabled: STRIPS the sentry entry" {
  export ENSURE_SENTRY_MCP_ENABLED=0
  cfg_with_sentry_and_other
  run bash -c ". '$HEALER'; ensure_sentry_mcp_main converge"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.mcp.servers.sentry // "ABSENT"' "$ENSURE_SENTRY_MCP_CFG")" = "ABSENT" ]
  [[ "$output" == *"DISABLED: removed sentry MCP"* ]]
}

@test "disabled: leaves OTHER mcp servers untouched" {
  export ENSURE_SENTRY_MCP_ENABLED=0
  cfg_with_sentry_and_other
  run bash -c ". '$HEALER'; ensure_sentry_mcp_main converge"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.mcp.servers.othersrv.url' "$ENSURE_SENTRY_MCP_CFG")" = "https://example.invalid/mcp" ]
  [ "$(jq -r '.mcp.servers | keys | length' "$ENSURE_SENTRY_MCP_CFG")" -eq 1 ]
}

@test "disabled: preserves the rest of the config" {
  export ENSURE_SENTRY_MCP_ENABLED=0
  cfg_with_sentry_and_other
  run bash -c ". '$HEALER'; ensure_sentry_mcp_main converge"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.agents.list | length' "$ENSURE_SENTRY_MCP_CFG")" -eq 2 ]
}

@test "disabled: is IDEMPOTENT — a second run writes nothing at all" {
  export ENSURE_SENTRY_MCP_ENABLED=0
  cfg_with_sentry_and_other
  run bash -c ". '$HEALER'; ensure_sentry_mcp_main converge"
  [ "$status" -eq 0 ]
  local before; before="$(sha256sum "$ENSURE_SENTRY_MCP_CFG" | cut -d' ' -f1)"
  : > "$TMP_ANNOUNCE_LOG"
  run bash -c ". '$HEALER'; ensure_sentry_mcp_main converge"
  [ "$status" -eq 0 ]
  [ "$(sha256sum "$ENSURE_SENTRY_MCP_CFG" | cut -d' ' -f1)" = "$before" ]
  [[ "$output" == *"already absent"* ]]
  # no announce on a no-op: an unannounced-write page is only avoided by not writing
  [ ! -s "$TMP_ANNOUNCE_LOG" ]
}

@test "disabled: ANNOUNCES the strip before renaming" {
  export ENSURE_SENTRY_MCP_ENABLED=0
  cfg_with_sentry_and_other
  run bash -c ". '$HEALER'; ensure_sentry_mcp_main converge"
  [ "$status" -eq 0 ]
  grep -q "ensure-sentry-mcp" "$TMP_ANNOUNCE_LOG"
}

@test "disabled: --check REPORTS a still-registered server as a violation" {
  export ENSURE_SENTRY_MCP_ENABLED=0
  cfg_with_sentry_and_other
  run bash -c ". '$HEALER'; ensure_sentry_mcp_main --check"
  # 3, not 1: the watchdog's rc=1 branch re-registers and says so. Disabled mode
  # heals by REMOVING, so it needs its own code or the Slack copy is backwards.
  [ "$status" -eq 3 ]
  [[ "$output" == *"VIOLATION"* ]]
  # --check must not mutate
  [ "$(jq -r '.mcp.servers.sentry.url' "$ENSURE_SENTRY_MCP_CFG")" = "https://mcp.sentry.dev/mcp" ]
}

@test "disabled: --check is clean once the entry is gone" {
  export ENSURE_SENTRY_MCP_ENABLED=0
  cfg_without_sentry
  run bash -c ". '$HEALER'; ensure_sentry_mcp_main --check"
  [ "$status" -eq 0 ]
}

@test "enabled: still registers, and still preserves other servers" {
  export ENSURE_SENTRY_MCP_ENABLED=1
  cfg_with '{"agents":{"list":[{"id":"cto"}]},"mcp":{"servers":{"othersrv":{"transport":"streamable-http","url":"https://example.invalid/mcp"}}}}'
  run bash -c ". '$HEALER'; ensure_sentry_mcp_main converge"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.mcp.servers.sentry.url' "$ENSURE_SENTRY_MCP_CFG")" = "https://mcp.sentry.dev/mcp" ]
  [ "$(jq -r '.mcp.servers.othersrv.url' "$ENSURE_SENTRY_MCP_CFG")" = "https://example.invalid/mcp" ]
}

@test "the DEFAULT is disabled — an unset ENSURE_SENTRY_MCP_ENABLED strips the entry" {
  # This pins the constant's default value, which is the entire point of the
  # switch: the PR alone must be the control, so re-enabling has to be a visible
  # one-line change and not an environment accident. Without this case, flipping
  # ESM_ENABLED's default back to 1 passes the whole suite (verified by
  # mutation, 2026-09-11).
  unset ENSURE_SENTRY_MCP_ENABLED
  cfg_with_sentry_and_other
  run bash -c ". '$HEALER'; ensure_sentry_mcp_main converge"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.mcp.servers.sentry // "ABSENT"' "$ENSURE_SENTRY_MCP_CFG")" = "ABSENT" ]
  [[ "$output" == *"DISABLED: removed sentry MCP"* ]]
}

@test "disabled: REFUSES to install a rendered config that fails validation" {
  # The pre-rename validation is the last thing standing between a bad transform
  # and an irreversible rename of the LIVE gateway config. Exercised here via the
  # agents.list clause: a config whose agents.list is not an array is valid JSON,
  # so it reaches validation, and the healer must refuse and leave the original
  # byte-identical rather than install it.
  export ENSURE_SENTRY_MCP_ENABLED=0
  cfg_with '{"agents":{"list":{"not":"an-array"}},"mcp":{"servers":{"sentry":{"transport":"streamable-http","url":"https://mcp.sentry.dev/mcp","headers":{"Authorization":"Sentry-Bearer sntryu_realtoken123"}}}}}'
  local before; before="$(sha256sum "$ENSURE_SENTRY_MCP_CFG" | cut -d' ' -f1)"
  run bash -c ". '$HEALER'; ensure_sentry_mcp_main converge"
  [ "$status" -ne 0 ]
  [[ "$output" == *"failed validation"* ]]
  [[ "$output" == *"live config untouched"* ]]
  [ "$(sha256sum "$ENSURE_SENTRY_MCP_CFG" | cut -d' ' -f1)" = "$before" ]
}
