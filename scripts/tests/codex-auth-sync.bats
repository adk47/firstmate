#!/usr/bin/env bats
# Tests for scripts/lib/codex-auth-sync.sh — the openclaw 2026.7.x successor to
# the JSON-symlink credential fabric. On 7.x the runtime reads codex auth from
# (a) the hardcoded inheritance base agents/main/agent/openclaw-agent.sqlite
# (auth_profile_store row 'primary') and (b) each agent's codex-home/auth.json
# (the native codex app-server's own store — the thing that actually
# authenticates the model call). The canonical source of truth stays OUR
# agents/main/agent/auth-profiles.json (written by codex-oauth-refresh.sh);
# this script fans the ACCESS token out to (a)+(b) and enforces the
# single-refresher invariant: the REAL refresh token must exist NOWHERE but
# the canonical JSON (fan-out of a single-use rotating refresh token =
# mutual-invalidation storm; incidents 2026-05-29 / 2026-06-08 / the
# doctor-fix fan-out observed on the 2026-07-14 staging validation).
#
# Sandboxed via CODEX_AUTH_ROOT under mktemp -d; PATH-shadows `openclaw` (per
# memory/feedback_bats_must_stub_openclaw.md) so the runtime-version gate is
# testable and no real gateway is ever consulted. Uses the real `node` +
# node:sqlite (the same engine the script itself uses).
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
SCRIPT="$HYDRA_REPO/scripts/lib/codex-auth-sync.sh"

REAL_ACCESS="real-access-token-abc123"
REAL_REFRESH="REAL-REFRESH-TOKEN-MUST-NEVER-FAN-OUT"

setup() {
  TEST_TMPDIR="$(mktemp -d)"; export TEST_TMPDIR
  ROOT="$TEST_TMPDIR/root"; export ROOT

  # Fake fleet mirroring /root/.openclaw-<profile>/agents/<agent>/agent/.
  CANON_DIR="$ROOT/.openclaw-main/agents/main/agent"
  CLIO_DIR="$ROOT/.openclaw-main/agents/clio/agent"
  EDGE_MAIN_DIR="$ROOT/.openclaw-edge/agents/main/agent"
  CAROLINE_DIR="$ROOT/.openclaw-edge/agents/caroline/agent"
  export CANON_DIR CLIO_DIR EDGE_MAIN_DIR CAROLINE_DIR
  mkdir -p "$CANON_DIR" "$CLIO_DIR/codex-home" "$EDGE_MAIN_DIR" "$CAROLINE_DIR/codex-home"

  cat > "$CANON_DIR/auth-profiles.json" <<JSON
{
  "version": 1,
  "profiles": {
    "openai-codex:aaron@muso.ai": {
      "type": "oauth",
      "provider": "openai-codex",
      "email": "aaron@muso.ai",
      "access": "$REAL_ACCESS",
      "refresh": "$REAL_REFRESH",
      "accountId": "acct-1111",
      "chatgptPlanType": "pro",
      "expires": 1790000000000
    },
    "openai-codex:aaronkaufman@me.com": {
      "type": "oauth",
      "provider": "openai-codex",
      "email": "aaronkaufman@me.com",
      "access": "second-access-token",
      "refresh": "SECOND-REAL-REFRESH",
      "accountId": "acct-2222",
      "chatgptPlanType": "pro",
      "expires": 1790000000000
    }
  }
}
JSON

  # openclaw stub: reports a 7.x runtime by default (version gate open).
  mkdir -p "$TEST_TMPDIR/bin"
  cat > "$TEST_TMPDIR/bin/openclaw" <<'STUB'
#!/bin/bash
[ -n "${FAKE_OPENCLAW_BROKEN:-}" ] && exit 1
if [ "$1" = "--version" ]; then echo "OpenClaw ${FAKE_OPENCLAW_VERSION:-2026.7.1} (test)"; exit 0; fi
echo "test stub: unexpected openclaw call ($*)" >&2
exit 99
STUB
  chmod +x "$TEST_TMPDIR/bin/openclaw"
  PATH="$TEST_TMPDIR/bin:$PATH"; export PATH
}

teardown() { rm -rf "$TEST_TMPDIR"; }

run_sync() { run env CODEX_AUTH_ROOT="$ROOT" "$SCRIPT" "$@"; }

# sqlite helper: print the store_json of the primary row (empty if none).
store_json() { # $1 = agent dir
  node --experimental-sqlite -e '
    const {DatabaseSync}=require("node:sqlite");
    try {
      const db=new DatabaseSync(process.argv[1]+"/openclaw-agent.sqlite",{readOnly:true});
      const r=db.prepare("select store_json from auth_profile_store where store_key=?").get("primary");
      process.stdout.write(r ? r.store_json : "");
    } catch (e) { /* absent DB => empty */ }
  ' "$1" 2>/dev/null
}

seed_agent_row() { # $1 = agent dir — simulate the doctor --fix fan-out
  mkdir -p "$1"
  node --experimental-sqlite -e '
    const {DatabaseSync}=require("node:sqlite");
    const db=new DatabaseSync(process.argv[1]+"/openclaw-agent.sqlite");
    db.exec("CREATE TABLE IF NOT EXISTS auth_profile_store (store_key TEXT NOT NULL PRIMARY KEY, store_json TEXT NOT NULL, updated_at INTEGER NOT NULL)");
    db.exec("CREATE TABLE IF NOT EXISTS auth_profile_state (state_key TEXT NOT NULL PRIMARY KEY, state_json TEXT NOT NULL, updated_at INTEGER NOT NULL)");
    db.prepare("insert or replace into auth_profile_store values (?,?,?)")
      .run("primary", JSON.stringify({version:1,profiles:{"openai:aaron@muso.ai":{type:"oauth",provider:"openai",access:"copied",refresh:"copied-refresh"}}}), 1);
  ' "$1" 2>/dev/null
}

# ── ensure mode ──────────────────────────────────────────────────────────────

@test "ensure: seeds main sqlite row per profile from canonical (openai:* keys, access synced)" {
  run_sync
  [ "$status" -eq 0 ]
  for dir in "$CANON_DIR" "$EDGE_MAIN_DIR"; do
    json="$(store_json "$dir")"
    [ -n "$json" ]
    echo "$json" | jq -e '.profiles["openai:aaron@muso.ai"].access == "'"$REAL_ACCESS"'"'
    echo "$json" | jq -e '.profiles["openai:aaron@muso.ai"].provider == "openai"'
    echo "$json" | jq -e '.profiles["openai:aaronkaufman@me.com"].access == "second-access-token"'
  done
}

@test "ensure: the real refresh token appears NOWHERE outside canonical JSON" {
  run_sync
  [ "$status" -eq 0 ]
  # Not in either sqlite store...
  for dir in "$CANON_DIR" "$EDGE_MAIN_DIR"; do
    json="$(store_json "$dir")"
    [[ "$json" != *"$REAL_REFRESH"* ]]
    [[ "$json" != *"SECOND-REAL-REFRESH"* ]]
  done
  # ...and not in any codex-home/auth.json.
  ! grep -rF "$REAL_REFRESH" "$ROOT" --include=auth.json
}

@test "ensure: writes chatgpt-mode codex-home/auth.json for every agent dir" {
  run_sync
  [ "$status" -eq 0 ]
  for dir in "$CANON_DIR" "$CLIO_DIR" "$EDGE_MAIN_DIR" "$CAROLINE_DIR"; do
    f="$dir/codex-home/auth.json"
    [ -f "$f" ]
    jq -e '.auth_mode == "chatgpt"' "$f"
    jq -e '.OPENAI_API_KEY == null' "$f"
    jq -e '.tokens.access_token == "'"$REAL_ACCESS"'"' "$f"
    jq -e '.tokens.account_id == "acct-1111"' "$f"
    # refresh_token present structurally but NEVER the real one
    jq -e '.tokens.refresh_token | test("^SYNC-MANAGED")' "$f"
  done
}

@test "ensure: deletes per-agent auth_profile_store rows (doctor fan-out cleanup)" {
  seed_agent_row "$CLIO_DIR"
  seed_agent_row "$CAROLINE_DIR"
  run_sync
  [ "$status" -eq 0 ]
  [ -z "$(store_json "$CLIO_DIR")" ]
  [ -z "$(store_json "$CAROLINE_DIR")" ]
  # main rows stay
  [ -n "$(store_json "$CANON_DIR")" ]
}

@test "ensure: idempotent — second run exits 0 and state stays correct" {
  run_sync
  [ "$status" -eq 0 ]
  first="$(store_json "$CANON_DIR")"
  run_sync
  [ "$status" -eq 0 ]
  second="$(store_json "$CANON_DIR")"
  [ "$(echo "$first" | jq -S .)" = "$(echo "$second" | jq -S .)" ]
}

@test "ensure: auth.json is mode 0600 (token-bearing file)" {
  run_sync
  [ "$status" -eq 0 ]
  # GNU stat first (-c); BSD stat (-f %Lp) as fallback. The reverse order is a
  # trap: GNU `stat -f` is FILESYSTEM status and exits 0 with garbage output,
  # so a BSD-first chain never falls through on Linux CI.
  perms="$(stat -c %a "$CLIO_DIR/codex-home/auth.json" 2>/dev/null || stat -f %Lp "$CLIO_DIR/codex-home/auth.json")"
  [ "$perms" = "600" ]
}

# ── version gate ─────────────────────────────────────────────────────────────

@test "ensure: no-op on a pre-2026.7 runtime (6.1 semantics unchanged)" {
  export FAKE_OPENCLAW_VERSION=2026.6.1
  run_sync
  [ "$status" -eq 0 ]
  [[ "$output" == *"runtime 2026.6.1 < 2026.7"* ]]
  [ -z "$(store_json "$CANON_DIR")" ]
  [ ! -f "$CLIO_DIR/codex-home/auth.json" ]
}

@test "ensure: no-op when the runtime version is UNDETECTABLE (fail closed, never apply 7.x semantics blind)" {
  export FAKE_OPENCLAW_BROKEN=1
  run_sync
  [ "$status" -eq 0 ]
  [[ "$output" == *"cannot determine"* ]]
  [ -z "$(store_json "$CANON_DIR")" ]
  [ ! -f "$CLIO_DIR/codex-home/auth.json" ]
}

@test "ensure: --force bypasses the version gate" {
  export FAKE_OPENCLAW_VERSION=2026.6.1
  run_sync --force
  [ "$status" -eq 0 ]
  [ -n "$(store_json "$CANON_DIR")" ]
}

# ── --check mode ─────────────────────────────────────────────────────────────

@test "check: clean immediately after ensure" {
  run_sync
  [ "$status" -eq 0 ]
  run_sync --check
  [ "$status" -eq 0 ]
}

@test "check: flags apikey-mode auth.json (the day-one 401 shape)" {
  run_sync
  printf '{"auth_mode":"apikey","OPENAI_API_KEY":"sk-hydra-placeholder"}\n' > "$CLIO_DIR/codex-home/auth.json"
  run_sync --check
  [ "$status" -eq 1 ]
  [[ "$output" == *clio* ]]
}

@test "check: flags stale access token in auth.json" {
  run_sync
  node -e '
    const fs=require("fs"); const p=process.argv[1];
    const j=JSON.parse(fs.readFileSync(p,"utf8"));
    j.tokens.access_token="stale-old-access";
    fs.writeFileSync(p, JSON.stringify(j));
  ' "$CAROLINE_DIR/codex-home/auth.json"
  run_sync --check
  [ "$status" -eq 1 ]
  [[ "$output" == *caroline* ]]
}

@test "check: flags per-agent auth_profile_store rows (fan-out reintroduced)" {
  run_sync
  seed_agent_row "$CLIO_DIR"
  run_sync --check
  [ "$status" -eq 1 ]
  [[ "$output" == *clio* ]]
}

@test "check: flags a REAL refresh token that leaked into a sqlite store" {
  run_sync
  node --experimental-sqlite -e '
    const {DatabaseSync}=require("node:sqlite");
    const db=new DatabaseSync(process.argv[1]+"/openclaw-agent.sqlite");
    const r=db.prepare("select store_json from auth_profile_store where store_key=?").get("primary");
    const j=JSON.parse(r.store_json);
    j.profiles["openai:aaron@muso.ai"].refresh=process.argv[2];
    db.prepare("update auth_profile_store set store_json=? where store_key=?").run(JSON.stringify(j),"primary");
  ' "$CANON_DIR" "$REAL_REFRESH" 2>/dev/null
  run_sync --check
  [ "$status" -eq 1 ]
  [[ "$output" == *"refresh token"* ]]
}

@test "ensure: a refresh token under an ALTERNATE key name never reaches derived stores (whitelist)" {
  # A future re-auth/shape change could store the single-use token under
  # refresh_token instead of refresh — the whitelist must drop it anyway.
  node -e '
    const fs=require("fs"); const p=process.argv[1];
    const j=JSON.parse(fs.readFileSync(p,"utf8"));
    j.profiles["openai-codex:aaron@muso.ai"].refresh_token="ALT-KEY-REAL-REFRESH-TOKEN";
    fs.writeFileSync(p, JSON.stringify(j));
  ' "$CANON_DIR/auth-profiles.json"
  run_sync
  [ "$status" -eq 0 ]
  [[ "$(store_json "$CANON_DIR")" != *"ALT-KEY-REAL-REFRESH-TOKEN"* ]]
  ! grep -rF "ALT-KEY-REAL-REFRESH-TOKEN" "$ROOT" --include=auth.json
}

@test "check: flags a refresh token leaked into auth_profile_state (raw sqlite byte scan)" {
  run_sync
  [ "$status" -eq 0 ]
  seed_agent_row "$CLIO_DIR"   # create the DB with both tables
  run_sync                     # clears the rows again
  [ "$status" -eq 0 ]
  node --experimental-sqlite -e '
    const {DatabaseSync}=require("node:sqlite");
    const db=new DatabaseSync(process.argv[1]+"/openclaw-agent.sqlite");
    db.prepare("insert or replace into auth_profile_state values (?,?,?)")
      .run("primary", JSON.stringify({leaked:process.argv[2]}), 1);
    db.exec("pragma wal_checkpoint(TRUNCATE)");
  ' "$CLIO_DIR" "$REAL_REFRESH" 2>/dev/null
  run_sync --check
  [ "$status" -eq 1 ]
  [[ "$output" == *"leaked"* ]]
}

@test "check: an UNREADABLE per-agent sqlite is an offender, not silently clean" {
  run_sync
  [ "$status" -eq 0 ]
  printf 'this is not a sqlite database' > "$CLIO_DIR/openclaw-agent.sqlite"
  run_sync --check
  [ "$status" -eq 1 ]
  [[ "$output" == *"UNREADABLE"* ]]
}

@test "ensure: exits 1 when a surface fails to converge (refresh hook must page)" {
  run_sync
  [ "$status" -eq 0 ]
  printf 'this is not a sqlite database' > "$CLIO_DIR/openclaw-agent.sqlite"
  run_sync
  [ "$status" -eq 1 ]
  [[ "$output" == *"INCOMPLETE"* ]]
}

@test "check: missing canonical store is an error (exit 2)" {
  rm "$CANON_DIR/auth-profiles.json"
  run_sync --check
  [ "$status" -eq 2 ]
}

@test "ensure: missing canonical store is an error (exit 2), nothing written" {
  rm "$CANON_DIR/auth-profiles.json"
  run_sync
  [ "$status" -eq 2 ]
  [ ! -f "$CLIO_DIR/codex-home/auth.json" ]
}

@test "ensure: rewrites an auth.json that has current access but a REAL refresh token (fast-path must not skip it)" {
  run_sync
  [ "$status" -eq 0 ]
  node -e '
    const fs=require("fs"); const p=process.argv[1];
    const j=JSON.parse(fs.readFileSync(p,"utf8"));
    j.tokens.refresh_token=process.argv[2];   // bad migration left the real token
    fs.writeFileSync(p, JSON.stringify(j));
  ' "$CLIO_DIR/codex-home/auth.json" "$REAL_REFRESH"
  run_sync
  [ "$status" -eq 0 ]
  jq -e '.tokens.refresh_token == "SYNC-MANAGED-NO-REFRESH-TOKEN"' "$CLIO_DIR/codex-home/auth.json"
  run_sync --check
  [ "$status" -eq 0 ]
}

@test "ensure: converges a token leaked ONLY into auth_profile_state (empty primary row)" {
  run_sync
  [ "$status" -eq 0 ]
  seed_agent_row "$CLIO_DIR"          # create DB with both tables
  node --experimental-sqlite -e '
    const {DatabaseSync}=require("node:sqlite");
    const db=new DatabaseSync(process.argv[1]+"/openclaw-agent.sqlite");
    db.exec("delete from auth_profile_store");   // primary row EMPTY
    db.prepare("insert or replace into auth_profile_state values (?,?,?)")
      .run("primary", JSON.stringify({leaked:process.argv[2]}), 1);
    db.exec("pragma wal_checkpoint(TRUNCATE)");
  ' "$CLIO_DIR" "$REAL_REFRESH" 2>/dev/null
  run_sync
  [ "$status" -eq 0 ]
  run_sync --check
  [ "$status" -eq 0 ]
}

@test "ensure: converges a real refresh token leaked into the MAIN agent auth_profile_state (VACUUM alone cannot)" {
  run_sync
  [ "$status" -eq 0 ]
  # The main agent's DB now holds the seeded store row. Inject the real refresh
  # token into a LIVE auth_profile_state row — the doctor-fix / native-refresh
  # leak that upsert leaves untouched (it rewrites only auth_profile_store) and
  # that VACUUM cannot reclaim because the row is live, not dead.
  node --experimental-sqlite -e '
    const {DatabaseSync}=require("node:sqlite");
    const db=new DatabaseSync(process.argv[1]+"/openclaw-agent.sqlite");
    db.exec("CREATE TABLE IF NOT EXISTS auth_profile_state (state_key TEXT NOT NULL PRIMARY KEY, state_json TEXT NOT NULL, updated_at INTEGER NOT NULL)");
    db.prepare("insert or replace into auth_profile_state values (?,?,?)")
      .run("primary", JSON.stringify({leaked:process.argv[2]}), 1);
    db.exec("pragma wal_checkpoint(TRUNCATE)");
  ' "$CANON_DIR" "$REAL_REFRESH" 2>/dev/null
  run_sync --check
  [ "$status" -eq 1 ]           # leak is detected
  run_sync                      # ensure must actually converge it, not loop forever
  [ "$status" -eq 0 ]
  run_sync --check
  [ "$status" -eq 0 ]           # converged — --check no longer flags it
}
