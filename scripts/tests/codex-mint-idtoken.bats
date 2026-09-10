#!/usr/bin/env bats
# Tests for scripts/lib/codex-mint-idtoken.sh — the openclaw 2026.8.1 post-doctor
# ID-token mint (docs/runbooks/UPGRADE-2026.8.1.md Phase 4). It performs exactly
# one live grant_type=refresh_token POST against auth.openai.com, so a real HTTPS
# round trip is impractical to stub hermetically here (unlike codex-oauth-refresh.sh,
# which has a --dry-run mode). These tests instead cover the PURE, pre-network
# parts that gate every invocation regardless of network reachability:
#   - the runtime version gate (openclaw stub, per feedback_bats_must_stub_openclaw)
#   - profile-id derivation from the active-account state file
#   - sentinel-refresh-token refusal (a DERIVED store must never be POSTed against)
#   - missing-store / missing-profile / missing-refresh-token structural refusals
# All of these fail BEFORE the script ever reaches its fetch() call, so no network
# stub is needed; a real node:sqlite fixture is built per test (the same engine the
# script itself uses — mirrors codex-auth-sync.bats).
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
SCRIPT="$HYDRA_REPO/scripts/lib/codex-mint-idtoken.sh"

setup() {
  TEST_TMPDIR="$(mktemp -d)"
  export TEST_TMPDIR
  STATE_DIR="$TEST_TMPDIR/openclaw-main"
  export STATE_DIR
  mkdir -p "$STATE_DIR/state" "$TEST_TMPDIR/bin"

  # openclaw stub: reports a 2026.8.1 runtime by default (version gate open).
  cat > "$TEST_TMPDIR/bin/openclaw" <<'STUB'
#!/bin/bash
if [ "$1" = "--version" ]; then echo "OpenClaw ${FAKE_OPENCLAW_VERSION:-2026.8.1} (test)"; exit 0; fi
echo "test stub: unexpected openclaw call ($*)" >&2
exit 99
STUB
  chmod +x "$TEST_TMPDIR/bin/openclaw"
  PATH="$TEST_TMPDIR/bin:$PATH"; export PATH

  export CODEX_ACTIVE_ACCOUNT_FILE="$TEST_TMPDIR/active-account"
  # An unreachable token URL: any test that gets far enough to POST (none of the
  # refusal cases below do) would fail fast on connection refused rather than hang.
  export CODEX_OAUTH_TOKEN_URL="http://127.0.0.1:1/unreachable"
}

teardown() {
  # the loopback token server is a background job: kill it here too, so a
  # failing assertion can never leave it holding bats'"'"' output pipe open (hang)
  [ -n "${TOKEN_SERVER_PID:-}" ] && kill "$TOKEN_SERVER_PID" 2>/dev/null || true
  rm -rf "$TEST_TMPDIR"
}

# seed_store <profile-id> <refresh-token> [access] — build a real sqlite
# fixture at $STATE_DIR/state/openclaw.sqlite matching the 2.0 shared-auth
# cell shape (config_machine_state, row authProfiles.store).
seed_store() {
  local profile="$1" refresh="$2" access="${3:-old-access}"
  node --experimental-sqlite -e '
    const {DatabaseSync}=require("node:sqlite");
    const db=new DatabaseSync(process.argv[1]);
    db.exec("CREATE TABLE config_machine_state (state_key TEXT NOT NULL PRIMARY KEY, value_json TEXT NOT NULL, updated_at INTEGER NOT NULL)");
    const profiles = {};
    profiles[process.argv[2]] = {type:"oauth", provider:"openai", email:"test@example.com", access:process.argv[4], refresh:process.argv[3], accountId:"acct-1", chatgptPlanType:"pro", expires:1000};
    db.prepare("insert into config_machine_state values (?,?,?)").run("authProfiles.store", JSON.stringify({version:1, profiles}), 1);
  ' "$STATE_DIR/state/openclaw.sqlite" "$profile" "$refresh" "$access" 2>/dev/null
}

store_json() {
  node --experimental-sqlite -e '
    const {DatabaseSync}=require("node:sqlite");
    try {
      const db=new DatabaseSync(process.argv[1],{readOnly:true});
      const r=db.prepare("select value_json from config_machine_state where state_key=?").get("authProfiles.store");
      process.stdout.write(r ? r.value_json : "");
    } catch (e) { /* absent DB => empty */ }
  ' "$STATE_DIR/state/openclaw.sqlite" 2>/dev/null
}

run_mint() { run "$SCRIPT" --state-dir "$STATE_DIR" "$@"; }

# ── runtime gate ─────────────────────────────────────────────────────────────

@test "refuses on a pre-2026.8 runtime without touching the store" {
  seed_store "openai:aaron@muso.ai" "real-refresh-token"
  export FAKE_OPENCLAW_VERSION="2026.7.1"
  run_mint
  [ "$status" -eq 2 ]
  [[ "$output" == *"needs >= 2026.8"* ]]
  [[ "$(store_json)" == *"real-refresh-token"* ]]
}

@test "refuses on an unparseable/missing openclaw version (fails CLOSED)" {
  seed_store "openai:aaron@muso.ai" "real-refresh-token"
  cat > "$TEST_TMPDIR/bin/openclaw" <<'STUB'
#!/bin/bash
exit 1
STUB
  chmod +x "$TEST_TMPDIR/bin/openclaw"
  run_mint
  [ "$status" -eq 2 ]
  [[ "$output" == *"needs >= 2026.8"* ]]
}

# ── profile-id derivation ────────────────────────────────────────────────────

@test "derives profile-id from the active-account file, prepending openai:" {
  seed_store "openai:aaron@muso.ai" "SYNC-MANAGED-NO-REFRESH-TOKEN"
  echo "aaron@muso.ai" > "$CODEX_ACTIVE_ACCOUNT_FILE"
  run_mint
  [[ "$output" == *"profile-id: openai:aaron@muso.ai"* ]]
}

@test "strips an existing openai-codex: prefix from the active-account file" {
  seed_store "openai:aaron@muso.ai" "SYNC-MANAGED-NO-REFRESH-TOKEN"
  echo "openai-codex:aaron@muso.ai" > "$CODEX_ACTIVE_ACCOUNT_FILE"
  run_mint
  [[ "$output" == *"profile-id: openai:aaron@muso.ai"* ]]
}

@test "strips an existing openai: prefix from the active-account file (no double-prefix)" {
  seed_store "openai:aaron@muso.ai" "SYNC-MANAGED-NO-REFRESH-TOKEN"
  echo "openai:aaron@muso.ai" > "$CODEX_ACTIVE_ACCOUNT_FILE"
  run_mint
  [[ "$output" == *"profile-id: openai:aaron@muso.ai"* ]]
  [[ "$output" != *"openai:openai:"* ]]
}

@test "an explicit --profile-id overrides the active-account file" {
  seed_store "openai:other@example.com" "SYNC-MANAGED-NO-REFRESH-TOKEN"
  echo "aaron@muso.ai" > "$CODEX_ACTIVE_ACCOUNT_FILE"
  run "$SCRIPT" --state-dir "$STATE_DIR" --profile-id "openai:other@example.com"
  [[ "$output" == *"profile-id: openai:other@example.com"* ]]
}

@test "refuses when no --profile-id given and the active-account file is missing" {
  seed_store "openai:aaron@muso.ai" "real-refresh-token"
  run_mint
  [ "$status" -eq 2 ]
  [[ "$output" == *"missing/empty"* ]]
}

# ── sentinel refusal ─────────────────────────────────────────────────────────

@test "refuses a SYNC-MANAGED sentinel refresh token, store untouched" {
  seed_store "openai:aaron@muso.ai" "SYNC-MANAGED-NO-REFRESH-TOKEN"
  echo "aaron@muso.ai" > "$CODEX_ACTIVE_ACCOUNT_FILE"
  run_mint
  [ "$status" -eq 1 ]
  [[ "$output" == *"sentinel refresh token"* ]]
  [[ "$(store_json)" == *"SYNC-MANAGED-NO-REFRESH-TOKEN"* ]]
}

@test "refuses a STAGING- sentinel refresh token" {
  seed_store "openai:aaron@muso.ai" "STAGING-fake-refresh"
  echo "aaron@muso.ai" > "$CODEX_ACTIVE_ACCOUNT_FILE"
  run_mint
  [ "$status" -eq 1 ]
  [[ "$output" == *"sentinel refresh token"* ]]
}

# ── structural refusals ──────────────────────────────────────────────────────

@test "refuses when the sqlite store file does not exist" {
  echo "aaron@muso.ai" > "$CODEX_ACTIVE_ACCOUNT_FILE"
  run_mint
  [ "$status" -eq 2 ]
  [[ "$output" == *"sqlite store not found"* ]]
}

@test "refuses when the profile is not present in authProfiles.store" {
  seed_store "openai:someone-else@example.com" "real-refresh-token"
  echo "aaron@muso.ai" > "$CODEX_ACTIVE_ACCOUNT_FILE"
  run_mint
  [ "$status" -eq 1 ]
  [[ "$output" == *"not found in authProfiles.store"* ]]
}

@test "refuses when the profile has no refresh token" {
  node --experimental-sqlite -e '
    const {DatabaseSync}=require("node:sqlite");
    const db=new DatabaseSync(process.argv[1]);
    db.exec("CREATE TABLE config_machine_state (state_key TEXT NOT NULL PRIMARY KEY, value_json TEXT NOT NULL, updated_at INTEGER NOT NULL)");
    db.prepare("insert into config_machine_state values (?,?,?)").run("authProfiles.store", JSON.stringify({version:1, profiles:{"openai:aaron@muso.ai":{type:"oauth",provider:"openai",access:"old-access"}}}), 1);
  ' "$STATE_DIR/state/openclaw.sqlite" 2>/dev/null
  echo "aaron@muso.ai" > "$CODEX_ACTIVE_ACCOUNT_FILE"
  run_mint
  [ "$status" -eq 1 ]
  [[ "$output" == *"has no refresh token"* ]]
}

# ── the network hop, hermetically (QA finding, PR #899) ──────────────────────
# A loopback HTTP server plays auth.openai.com so the ROTATED-token handling can
# be tested: once the endpoint answers, the old refresh token is spent and the
# only usable copy is the response. The script must persist it to a 0600
# recovery file BEFORE the store write and remove that file only after COMMIT.

start_token_server() {
  # $1 = JSON body to answer every POST with
  local body="$1"
  node -e '
    const http=require("http"); const body=process.argv[1]; const portFile=process.argv[2];
    const srv=http.createServer((req,res)=>{ let d=""; req.on("data",c=>d+=c); req.on("end",()=>{ res.writeHead(200,{"content-type":"application/json"}); res.end(body); }); });
    srv.listen(0,"127.0.0.1",()=>{ require("fs").writeFileSync(portFile, String(srv.address().port)); });
  ' "$body" "$TEST_TMPDIR/port" &
  TOKEN_SERVER_PID=$!
  for _ in $(seq 1 50); do [ -s "$TEST_TMPDIR/port" ] && break; sleep 0.1; done
  [ -s "$TEST_TMPDIR/port" ] || { echo "token server did not start" >&2; return 1; }
  export CODEX_OAUTH_TOKEN_URL="http://127.0.0.1:$(cat "$TEST_TMPDIR/port")/token"
  export CODEX_MINT_RECOVERY_DIR="$TEST_TMPDIR/recovery"; mkdir -p "$CODEX_MINT_RECOVERY_DIR"
}
stop_token_server() { [ -n "${TOKEN_SERVER_PID:-}" ] && kill "$TOKEN_SERVER_PID" 2>/dev/null || true; }

GOOD_RESPONSE='{"access_token":"new-access-AAA","refresh_token":"new-refresh-ROTATED","expires_in":3600,"id_token":"new-id-token-III"}'

@test "success: store gets access+refresh+idToken and the recovery file is REMOVED after commit" {
  seed_store "openai:aaron@muso.ai" "old-refresh-SPENT"
  start_token_server "$GOOD_RESPONSE"
  run_mint --profile-id "openai:aaron@muso.ai"
  stop_token_server
  [ "$status" -eq 0 ]
  [[ "$(store_json)" == *'"refresh":"new-refresh-ROTATED"'* ]]
  [[ "$(store_json)" == *'"idToken":"new-id-token-III"'* ]]
  [[ "$(store_json)" != *"old-refresh-SPENT"* ]]
  # no recovery copy of a token the store now holds
  [ -z "$(ls -A "$CODEX_MINT_RECOVERY_DIR")" ]
  # and the token values never reached stdout/stderr
  [[ "$output" != *"new-refresh-ROTATED"* ]]
  [[ "$output" != *"new-access-AAA"* ]]
}

@test "store-write failure AFTER rotation: exit 1, rotated token preserved in a 0600 recovery file, store untouched, no re-run advice" {
  seed_store "openai:aaron@muso.ai" "old-refresh-SPENT"
  # inject a write failure that does not depend on file permissions (CI runs as root)
  node --experimental-sqlite -e '
    const {DatabaseSync}=require("node:sqlite"); const db=new DatabaseSync(process.argv[1]);
    db.exec("CREATE TRIGGER block_write BEFORE UPDATE ON config_machine_state BEGIN SELECT RAISE(ABORT, \"injected store failure\"); END");
  ' "$STATE_DIR/state/openclaw.sqlite" 2>/dev/null
  start_token_server "$GOOD_RESPONSE"
  run_mint --profile-id "openai:aaron@muso.ai"
  stop_token_server
  [ "$status" -eq 1 ]
  [[ "$output" == *"store write failed"* ]]
  [[ "$output" == *"ROTATED refresh token is preserved"* ]]
  [[ "$output" == *"Do NOT re-run the mint"* ]]
  # the store still holds the (now spent) old token — nothing half-written
  [[ "$(store_json)" == *"old-refresh-SPENT"* ]]
  # exactly one recovery file, mode 0600, carrying the rotated token
  rec=$(ls "$CODEX_MINT_RECOVERY_DIR"/codex-mint-recovery.*.json)
  [ -f "$rec" ]
  [ "$(stat -c %a "$rec")" = "600" ]
  grep -q '"refresh_token":"new-refresh-ROTATED"' "$rec"
  grep -q '"id_token":"new-id-token-III"' "$rec"
  # the token values still never reached stdout/stderr
  [[ "$output" != *"new-refresh-ROTATED"* ]]
}

# ── concurrency (QA round 4) ─────────────────────────────────────────────────
# Two mints for DIFFERENT profiles at the same time: without a cross-process
# lock both snapshot the same cell, both rotate, and the last whole-cell UPDATE
# discards the other's fresh credentials (both exit 0). A delayed token server
# forces the two processes to overlap.

seed_store_two() { # two profiles, same shape as seed_store
  node --experimental-sqlite -e '
    const {DatabaseSync}=require("node:sqlite");
    const db=new DatabaseSync(process.argv[1]);
    db.exec("CREATE TABLE config_machine_state (state_key TEXT NOT NULL PRIMARY KEY, value_json TEXT NOT NULL, updated_at INTEGER NOT NULL)");
    const mk=(e,r)=>({type:"oauth", provider:"openai", email:e, access:"old-access", refresh:r, accountId:"a", chatgptPlanType:"pro", expires:1000});
    const profiles={"openai:one@x.com":mk("one@x.com","old-ONE"), "openai:two@x.com":mk("two@x.com","old-TWO")};
    db.prepare("insert into config_machine_state values (?,?,?)").run("authProfiles.store", JSON.stringify({version:1, profiles}), 1);
  ' "$STATE_DIR/state/openclaw.sqlite" 2>/dev/null
}

start_barrier_token_server() {
  # Deterministic overlap: a request is answered when a SECOND request has
  # arrived (both mints have read the cell by then) or after 1.5s, whichever is
  # first — so a correctly locked mint (whose second process waits on the lock
  # and never reaches the server early) still gets its answer. Each answer
  # carries a unique rotated token. Request timestamps are logged for evidence.
  node -e '
    const http=require("http"), fs=require("fs"); const portFile=process.argv[1], logFile=process.argv[2];
    let n=0; const pending=[];
    const flush=()=>{ while(pending.length){ const {res,id}=pending.shift(); res.writeHead(200,{"content-type":"application/json"});
      res.end(JSON.stringify({access_token:"acc-"+id, refresh_token:"ROTATED-"+id, expires_in:3600, id_token:"idt-"+id})); } };
    http.createServer((req,res)=>{ let d=""; req.on("data",c=>d+=c); req.on("end",()=>{ n++; const id=n;
      fs.appendFileSync(logFile, "req"+id+" "+Date.now()+"\n"); pending.push({res,id});
      if(pending.length>=2) flush(); else setTimeout(flush,1500); }); })
    .listen(0,"127.0.0.1",function(){ fs.writeFileSync(portFile, String(this.address().port)); });
  ' "$TEST_TMPDIR/port" "$TEST_TMPDIR/server.log" &
  TOKEN_SERVER_PID=$!
  for _ in $(seq 1 50); do [ -s "$TEST_TMPDIR/port" ] && break; sleep 0.1; done
  export CODEX_OAUTH_TOKEN_URL="http://127.0.0.1:$(cat "$TEST_TMPDIR/port")/token"
  export CODEX_MINT_RECOVERY_DIR="$TEST_TMPDIR/recovery"; mkdir -p "$CODEX_MINT_RECOVERY_DIR"
}

@test "two concurrent mints for different profiles: BOTH rotated tokens survive (flock serializes the whole cell)" {
  seed_store_two
  start_barrier_token_server
  # two independent shells, launched back to back (a subshell each so bats job
  # control cannot serialize them)
  ( exec timeout -k 5 60 "$SCRIPT" --state-dir "$STATE_DIR" --profile-id "openai:one@x.com" ) > "$TEST_TMPDIR/out1" 2>&1 &
  p1=$!
  ( exec timeout -k 5 60 "$SCRIPT" --state-dir "$STATE_DIR" --profile-id "openai:two@x.com" ) > "$TEST_TMPDIR/out2" 2>&1 &
  p2=$!
  wait "$p1"; rc1=$?; wait "$p2"; rc2=$?
  stop_token_server
  cat "$TEST_TMPDIR/server.log"
  [ "$rc1" -eq 0 ] && [ "$rc2" -eq 0 ]
  final="$(store_json)"
  # neither old token remains, and each profile carries ITS OWN rotated token
  [[ "$final" != *"old-ONE"* ]] && [[ "$final" != *"old-TWO"* ]]
  one=$(printf '%s' "$final" | jq -r '.profiles["openai:one@x.com"].refresh'); two=$(printf '%s' "$final" | jq -r '.profiles["openai:two@x.com"].refresh')
  [[ "$one" == ROTATED-* ]] && [[ "$two" == ROTATED-* ]] && [ "$one" != "$two" ]
  [ -z "$(ls -A "$CODEX_MINT_RECOVERY_DIR")" ]
  # evidence the lock serialized the network hops: the two requests are >= 1s apart
  # (without the lock both arrive within milliseconds and the barrier releases both at once)
  t1=$(awk 'NR==1{print $2}' "$TEST_TMPDIR/server.log"); t2=$(awk 'NR==2{print $2}' "$TEST_TMPDIR/server.log")
  [ -n "$t1" ] && [ -n "$t2" ] && [ $(( t2 - t1 )) -ge 1000 ]
}
