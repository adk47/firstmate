#!/usr/bin/env bats
# Tests for scripts/lib/codex-reauth.sh — device-code re-auth for a revoked
# codex session (the 2026-07-27 class). Hermetic: the codex binary is a STUB
# that writes a canned auth.json, codex-auth-sync.sh is stubbed, and everything
# operates on a throwaway store. NEVER performs a real login and never touches
# live auth (see feedback_bats_must_stub_openclaw + the 2026-07-14 incident
# where a suite fanned fixture tokens into the live fleet).
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
SCRIPT="$HYDRA_REPO/scripts/lib/codex-reauth.sh"

# Build a signed-looking JWT (header.payload.sig) with the given JSON payload.
# Signature is never verified — only the payload claims are read.
_jwt() {
  python3 -c '
import base64, json, sys
def b64(o): return base64.urlsafe_b64encode(json.dumps(o).encode()).decode().rstrip("=")
print(b64({"alg":"RS256"}) + "." + b64(json.loads(sys.argv[1])) + ".sig")
' "$1"
}

setup() {
  TEST_TMPDIR="$(mktemp -d)"
  export TEST_TMPDIR
  mkdir -p "$TEST_TMPDIR/bin"

  export CODEX_AUTH_STORE="$TEST_TMPDIR/auth-profiles.json"
  export CODEX_AUTH_BACKUP_DIR="$TEST_TMPDIR/backups"
  # Basename must start with "codex-reauth" — the script refuses anything else,
  # because it rm -rf's this path as root.
  export CODEX_REAUTH_SCRATCH="$TEST_TMPDIR/codex-reauth-scratch"
  # Pin the active-account state file at an absent sandbox path so live node-8
  # state cannot leak into the non-active-account warning assertions.
  export CODEX_ACTIVE_ACCOUNT_FILE="$TEST_TMPDIR/absent-active-account"

  cat > "$CODEX_AUTH_STORE" <<'JSON'
{"profiles":{
  "openai-codex:existing@x.com":{"type":"oauth","provider":"openai-codex","email":"existing@x.com","access":"OLD","refresh":"OLD_REFRESH","accountId":"acc-x","chatgptPlanType":"pro","expires":1000}
}}
JSON

  # exp far in the future so the derived `expires` is unambiguous.
  ACCESS_JWT="$(_jwt '{"exp":2000000000}')"
  ID_JWT_PROFILE_NS="$(_jwt '{"https://api.openai.com/profile":{"email":"new@x.com"},"https://api.openai.com/auth":{"chatgpt_plan_type":"pro"}}')"
  ID_JWT_TOPLEVEL="$(_jwt '{"email":"top@x.com","https://api.openai.com/auth":{"chatgpt_plan_type":"plus"}}')"
  export ACCESS_JWT ID_JWT_PROFILE_NS ID_JWT_TOPLEVEL

  # codex binary stub: writes $CODEX_HOME/auth.json from $STUB_AUTH_JSON.
  export STUB_AUTH_JSON="$TEST_TMPDIR/stub-auth.json"
  cat > "$TEST_TMPDIR/bin/codex" <<'STUB'
#!/usr/bin/env bash
[ "$1" = "--version" ] && { echo "codex-cli 0.0.0-stub"; exit 0; }
# The script proves the binary supports the flow before asking a human to stand
# at a browser; a stub that cannot answer this would fail that preflight.
if [ "$1" = "login" ] && [ "${2:-}" = "--help" ]; then
  [ "${STUB_NO_DEVICE_AUTH:-0}" = "1" ] && { echo "Usage: codex login [OPTIONS]"; exit 0; }
  echo "Usage: codex login [OPTIONS]"; echo "      --device-auth"; exit 0
fi
if [ "$1" = "login" ]; then
  [ "${STUB_LOGIN_FAILS:-0}" = "1" ] && { echo "device auth timed out"; exit 1; }
  mkdir -p "$CODEX_HOME"
  cp "$STUB_AUTH_JSON" "$CODEX_HOME/auth.json"
  echo "Successfully logged in"
  exit 0
fi
exit 0
STUB
  chmod +x "$TEST_TMPDIR/bin/codex"
  export CODEX_BIN="$TEST_TMPDIR/bin/codex"

  # codex-auth-sync stub — records that it ran instead of touching real stores.
  export SYNC_MARKER="$TEST_TMPDIR/sync-ran"
  mkdir -p "$TEST_TMPDIR/lib"
  cat > "$TEST_TMPDIR/lib/codex-auth-sync.sh" <<STUB
#!/usr/bin/env bash
echo ran > "$SYNC_MARKER"
exit \${STUB_SYNC_EXIT:-0}
STUB
  chmod +x "$TEST_TMPDIR/lib/codex-auth-sync.sh"

  _write_scratch_json() {
    cat > "$STUB_AUTH_JSON" <<JSON
{"auth_mode":"${1:-chatgpt}","tokens":{"access_token":"$ACCESS_JWT","refresh_token":"REAL_REFRESH_TOKEN_VALUE","id_token":"${2:-$ID_JWT_PROFILE_NS}","account_id":"acct-new"}}
JSON
  }
  # (called directly from test bodies in this shell — no export needed)
}

teardown() { rm -rf "$TEST_TMPDIR"; }

# Restart-path runner: stubs the drain-restart lib, journalctl and openclaw so
# the post-restart VERIFICATION branch can be exercised hermetically. Never
# touches a real gateway.
_run_reauth_restart() {
  cp "$SCRIPT" "$TEST_TMPDIR/lib/codex-reauth.sh"
  chmod +x "$TEST_TMPDIR/lib/codex-reauth.sh"
  cp "$HYDRA_REPO/scripts/lib/codex-active-account.sh" "$TEST_TMPDIR/lib/"
  # Real codex-health.sh: the verification branch calls its codex_count_*
  # helpers, so stubbing them would test nothing.
  cp "$HYDRA_REPO/scripts/lib/codex-health.sh" "$TEST_TMPDIR/lib/"
  cat > "$TEST_TMPDIR/lib/gateway-restart.sh" <<'STUB'
drain_restart_gateway() { return "${STUB_RESTART_RC:-0}"; }
STUB
  cat > "$TEST_TMPDIR/bin/journalctl" <<STUB
#!/usr/bin/env bash
cat "$TEST_TMPDIR/state-journal" 2>/dev/null
exit 0
STUB
  chmod +x "$TEST_TMPDIR/bin/journalctl"
  cat > "$TEST_TMPDIR/bin/openclaw" <<'STUB'
#!/usr/bin/env bash
[ "${STUB_TURN_FAILS:-0}" = "1" ] && { echo "turn failed"; exit 1; }
echo pong
exit 0
STUB
  chmod +x "$TEST_TMPDIR/bin/openclaw"
  PATH="$TEST_TMPDIR/bin:$PATH" run "$TEST_TMPDIR/lib/codex-reauth.sh" "$@"
}

# Run the script with its lib dir shimmed so the sync stub is picked up.
_run_reauth() {
  cp "$SCRIPT" "$TEST_TMPDIR/lib/codex-reauth.sh"
  chmod +x "$TEST_TMPDIR/lib/codex-reauth.sh"
  # The script sources its siblings from its own dir — provide the real
  # active-account resolver so the non-active-account guard is exercised for
  # real rather than silently skipped by a failed source.
  cp "$HYDRA_REPO/scripts/lib/codex-active-account.sh" "$TEST_TMPDIR/lib/"
  cp "$HYDRA_REPO/scripts/lib/gateway-restart.sh" "$TEST_TMPDIR/lib/"
  # Real codex-health.sh — the restart path preflights its helpers, and a
  # dry-run legitimately reports that the real run would crash without them.
  cp "$HYDRA_REPO/scripts/lib/codex-health.sh" "$TEST_TMPDIR/lib/"
  run "$TEST_TMPDIR/lib/codex-reauth.sh" "$@"
}

# Guard against the failure mode this suite nearly shipped with: several tests
# assert a NON-zero exit, so a script that dies early for an unrelated reason
# (a missing sibling lib, a bad preflight) makes them pass for the wrong reason.
# Assert the happy path really is exit 0 before trusting any negative case.
@test "harness sanity: the happy path exits 0 (negative tests are not vacuous)" {
  _write_scratch_json
  _run_reauth --no-restart
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "dry-run mints nothing and leaves canonical untouched" {
  before="$(cat "$CODEX_AUTH_STORE")"
  _run_reauth --dry-run
  [ "$status" -eq 0 ]
  [ "$(cat "$CODEX_AUTH_STORE")" = "$before" ]
  [ ! -e "$CODEX_REAUTH_SCRATCH/auth.json" ]
  [ ! -e "$SYNC_MARKER" ]
}

@test "merges a fresh credential into canonical under the openai-codex: prefix" {
  # The prefix is load-bearing: codex-auth-sync.sh selects on it, and an
  # `openai:`-keyed profile is silently ignored (2026-07-27, 23min invisible).
  _write_scratch_json chatgpt "$ID_JWT_PROFILE_NS"
  _run_reauth --no-restart
  [ "$status" -eq 0 ]
  run jq -e '.profiles["openai-codex:new@x.com"].access != null' "$CODEX_AUTH_STORE"
  [ "$status" -eq 0 ]
  run jq -r '.profiles["openai-codex:new@x.com"].provider' "$CODEX_AUTH_STORE"
  [ "$output" = "openai-codex" ]
  run jq -r '.profiles["openai-codex:new@x.com"].expires' "$CODEX_AUTH_STORE"
  [ "$output" = "2000000000000" ]   # exp claim * 1000
}

@test "reads the email from a TOP-LEVEL claim (google-oauth2 login path)" {
  # Observed 2026-07-27: a Google-federated login carries `email` at the top
  # level with NO profile namespace. Reading only the namespace made the merge
  # abort mid-incident.
  _write_scratch_json chatgpt "$ID_JWT_TOPLEVEL"
  _run_reauth --no-restart
  [ "$status" -eq 0 ]
  run jq -e '.profiles["openai-codex:top@x.com"] != null' "$CODEX_AUTH_STORE"
  [ "$status" -eq 0 ]
}

@test "preserves pre-existing profiles (re-auth is additive)" {
  _write_scratch_json
  _run_reauth --no-restart
  [ "$status" -eq 0 ]
  run jq -e '.profiles["openai-codex:existing@x.com"].access == "OLD"' "$CODEX_AUTH_STORE"
  [ "$status" -eq 0 ]
}

@test "SHREDS the scratch credential (single-refresher invariant)" {
  # The scratch CODEX_HOME holds a REAL refresh token. Leaving it creates a
  # second holder of a single-use rotating chain — the 2026-05-29 / 06-08
  # fleet-death topology.
  _write_scratch_json
  _run_reauth --no-restart
  [ "$status" -eq 0 ]
  [ ! -e "$CODEX_REAUTH_SCRATCH" ]
  # The token must survive ONLY in canonical. `$STUB_AUTH_JSON` is this test's
  # own source fixture (it stands in for what the codex CLI would mint) and
  # backups legitimately snapshot canonical, so both are excluded.
  run bash -c "grep -rl 'REAL_REFRESH_TOKEN_VALUE' '$TEST_TMPDIR' --exclude-dir=backups 2>/dev/null | grep -v '^$STUB_AUTH_JSON\$' || true"
  [ "$output" = "$CODEX_AUTH_STORE" ]
}

@test "backs canonical up before writing" {
  _write_scratch_json
  _run_reauth --no-restart
  [ "$status" -eq 0 ]
  run bash -c "ls '$CODEX_AUTH_BACKUP_DIR'/auth-profiles-prereauth-*.json 2>/dev/null | wc -l"
  [ "$output" -ge 1 ]
}

@test "an apikey-mode credential is REFUSED (would 401 the whole fleet)" {
  _write_scratch_json apikey
  _run_reauth --no-restart
  [ "$status" -ne 0 ]
  run jq -e '.profiles | length == 1' "$CODEX_AUTH_STORE"
  [ "$status" -eq 0 ]
}

@test "a failed/abandoned login leaves canonical UNTOUCHED" {
  before="$(cat "$CODEX_AUTH_STORE")"
  export STUB_LOGIN_FAILS=1
  _write_scratch_json
  _run_reauth --no-restart
  [ "$status" -ne 0 ]
  [ "$(cat "$CODEX_AUTH_STORE")" = "$before" ]
  [ ! -e "$SYNC_MARKER" ]
}

@test "fans out via codex-auth-sync.sh after a successful merge" {
  _write_scratch_json
  _run_reauth --no-restart
  [ "$status" -eq 0 ]
  [ -e "$SYNC_MARKER" ]
}

@test "a sync FAILURE is fatal (derived stores would silently ride a stale token)" {
  _write_scratch_json
  export STUB_SYNC_EXIT=1
  _run_reauth --no-restart
  [ "$status" -ne 0 ]
}

@test "WARNS when the re-authed account is not the ACTIVE one" {
  # Re-authing a non-active account fixes nothing on its own — the fleet keeps
  # using whatever codex-active-account.sh resolves. Silence here would let an
  # operator believe the outage is over while it continues.
  echo "openai-codex:existing@x.com" > "$TEST_TMPDIR/active-account"
  export CODEX_ACTIVE_ACCOUNT_FILE="$TEST_TMPDIR/active-account"
  _write_scratch_json chatgpt "$ID_JWT_PROFILE_NS"
  _run_reauth --no-restart
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARNING"* ]]
  [[ "$output" == *"codex-account-rotate.sh --to new@x.com"* ]]
}

@test "REFUSES a codex CLI without --device-auth instead of promising a code" {
  # A codex bump could rename the flag or ship an older CLI in a stale vendor
  # tree. Discovering that AFTER telling an operator "a code is coming" wastes
  # the one window where the account owner is actually at a browser.
  export STUB_NO_DEVICE_AUTH=1
  _write_scratch_json
  _run_reauth --no-restart
  [ "$status" -eq 2 ]
  [[ "$output" == *"does not support"* ]]
}

# ── scratch-path safety (runs as root, rm -rf's this path) ────────────────────

@test "REFUSES a scratch path whose basename is not ours (typo protection)" {
  # CODEX_REAUTH_SCRATCH=/root would otherwise be rm -rf'd as root.
  export CODEX_REAUTH_SCRATCH="$TEST_TMPDIR/important-operator-state"
  mkdir -p "$CODEX_REAUTH_SCRATCH"; echo keepme > "$CODEX_REAUTH_SCRATCH/data"
  _write_scratch_json
  _run_reauth --no-restart
  [ "$status" -eq 2 ]
  [[ "$output" == *"basename must start with"* ]]
  [ -f "$CODEX_REAUTH_SCRATCH/data" ]   # untouched
}

@test "REFUSES a relative scratch path" {
  export CODEX_REAUTH_SCRATCH="codex-reauth-relative"
  _write_scratch_json
  _run_reauth --no-restart
  [ "$status" -eq 2 ]
  [[ "$output" == *"absolute path"* ]]
}

@test "REFUSES a symlinked scratch dir (cleanup would shred the target)" {
  mkdir -p "$TEST_TMPDIR/real-target"; echo keepme > "$TEST_TMPDIR/real-target/data"
  ln -s "$TEST_TMPDIR/real-target" "$TEST_TMPDIR/codex-reauth-link"
  export CODEX_REAUTH_SCRATCH="$TEST_TMPDIR/codex-reauth-link"
  _write_scratch_json
  _run_reauth --no-restart
  [ "$status" -eq 2 ]
  [[ "$output" == *"symlink"* ]]
  [ -f "$TEST_TMPDIR/real-target/data" ]   # target untouched
}

# ── post-restart verification must never report an unproven rescue as success ──
# An earlier revision set REAUTH_DEGRADED in every failure branch and then still
# ran `exit 0`, so a failed recovery looked successful to any caller.

@test "clean post-restart journal + successful turn -> exit 0" {
  _write_scratch_json
  : > "$TEST_TMPDIR/state-journal"
  echo "Jul 28 12:00 node[1]: [agent] run ended with stopReason=stop" > "$TEST_TMPDIR/state-journal"
  _run_reauth_restart
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"verified"* ]]
}

@test "openrouter-served turn AFTER the restart boundary -> exit 1" {
  _write_scratch_json
  echo 'Jul 28 12:00 node[1]: [model-fallback/decision] decision=candidate_succeeded requested=openai/gpt-5.6-sol candidate=openrouter/openai/gpt-5.6-luna' > "$TEST_TMPDIR/state-journal"
  _run_reauth_restart
  [ "$status" -eq 1 ]
  [[ "$output" == *"DEGRADED"* ]]
}

@test "verification turn that cannot complete -> exit 1 (not a footnote)" {
  _write_scratch_json
  echo "Jul 28 12:00 node[1]: unrelated chatter" > "$TEST_TMPDIR/state-journal"
  export STUB_TURN_FAILS=1
  _run_reauth_restart
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAILED to complete"* ]]
}

@test "empty post-restart journal -> UNVERIFIABLE -> exit 1" {
  _write_scratch_json
  : > "$TEST_TMPDIR/state-journal"
  _run_reauth_restart
  [ "$status" -eq 1 ]
  [[ "$output" == *"UNVERIFIABLE"* ]]
}

@test "verification disabled -> exit 1 (skipped must not read as success)" {
  _write_scratch_json
  echo "Jul 28 12:00 node[1]: unrelated chatter" > "$TEST_TMPDIR/state-journal"
  export CODEX_REAUTH_VERIFY=0
  _run_reauth_restart
  [ "$status" -eq 1 ]
  [[ "$output" == *"SKIPPED"* ]]
}

@test "a FAILED gateway restart -> exit 1" {
  _write_scratch_json
  : > "$TEST_TMPDIR/state-journal"
  export STUB_RESTART_RC=1
  _run_reauth_restart
  [ "$status" -eq 1 ]
  [[ "$output" == *"restart FAILED"* ]]
}
