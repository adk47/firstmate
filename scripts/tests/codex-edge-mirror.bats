#!/usr/bin/env bats
# Tests for scripts/lib/codex-edge-mirror.sh — main→edge mirror of the openclaw
# 2.0 shared codex auth cell (config_machine_state / authProfiles.store).
#
# Fixtures are REAL node:sqlite databases with the LIVE pragma schema verified on
# node-8 (2026-09-11, openclaw 2026.8.2):
#   config_machine_state(state_key TEXT PK, value_json TEXT, updated_at_ms INTEGER)
# `openclaw --version` is stubbed on PATH (feedback_bats_must_stub_openclaw), the
# drain-restart library is stubbed via CODEX_MIRROR_RESTART_LIB, and the pager via
# CODEX_MIRROR_PAGE_FN — so no test can touch a live gateway or Slack.
#
# Every guard below has a matching mutation in the PR's "Proof artefacts": the
# guard was removed and the named test went RED.
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
SCRIPT="$HYDRA_REPO/scripts/lib/codex-edge-mirror.sh"
SENTINEL="SYNC-MANAGED-NO-REFRESH-TOKEN"

setup() {
  TEST_TMPDIR="$(mktemp -d)"
  export TEST_TMPDIR
  export CODEX_AUTH_ROOT="$TEST_TMPDIR/root"
  mkdir -p "$CODEX_AUTH_ROOT/.openclaw-main/state" "$CODEX_AUTH_ROOT/.openclaw-edge/state" "$TEST_TMPDIR/bin"

  cat > "$TEST_TMPDIR/bin/openclaw" <<'STUB'
#!/bin/bash
if [ "$1" = "--version" ]; then echo "OpenClaw ${FAKE_OPENCLAW_VERSION:-2026.8.2} (test)"; exit 0; fi
echo "test stub: unexpected openclaw call ($*)" >&2
exit 99
STUB
  chmod +x "$TEST_TMPDIR/bin/openclaw"
  PATH="$TEST_TMPDIR/bin:$PATH"; export PATH

  # drain-restart stub: records the call, exits STUB_RESTART_RC
  export RESTART_LOG="$TEST_TMPDIR/restart.log"
  cat > "$TEST_TMPDIR/gateway-restart-stub.sh" <<'LIB'
drain_restart_gateway() { echo "$1 $2" >> "$RESTART_LOG"; return "${STUB_RESTART_RC:-0}"; }
LIB
  export CODEX_MIRROR_RESTART_LIB="$TEST_TMPDIR/gateway-restart-stub.sh"

  export PAGE_LOG="$TEST_TMPDIR/page.log"
  _stub_page() { echo "$1" >> "$PAGE_LOG"; return "${STUB_PAGE_RC:-0}"; }
  export -f _stub_page
  export CODEX_MIRROR_PAGE_FN=_stub_page
  export CODEX_MIRROR_STATE_DIR="$TEST_TMPDIR/state"
  export NOTIFY_UNIT_FAILED_MARKER_DIR="$TEST_TMPDIR/unit-failed-unpaged"
  export HYDRA_SELF_PAGED_DIR="$TEST_TMPDIR/self-paged"
  export CODEX_MIRROR_MIN_TOKEN_MIN=60
  export HYDRA_MAINTENANCE_FLAG="$TEST_TMPDIR/maintenance-flag"

  # a nominal canonical main cell with the same three accounts as node-8
  seed_main_default
}

teardown() { rm -rf "$TEST_TMPDIR"; }

db_of() { printf '%s' "$CODEX_AUTH_ROOT/.openclaw-$1/state/openclaw.sqlite"; }

# jwt <accountId> [exp-epoch-s] [extra-suffix] — an unsigned JWT carrying the
# claim the runtime decodes the ChatGPT account id from.
jwt() {
  local acct="$1" exp="${2:-4102444800}" suffix="${3:-}"
  local hdr payload
  hdr="$(printf '{"alg":"RS256","typ":"JWT"}' | base64 | tr '+/' '-_' | tr -d '=\n')"
  payload="$(printf '{"https://api.openai.com/auth":{"chatgpt_account_id":"%s","chatgpt_plan_type":"pro"},"exp":%s,"x":"%s"}' "$acct" "$exp" "$suffix" | base64 | tr '+/' '-_' | tr -d '=\n')"
  printf '%s.%s.sig%s' "$hdr" "$payload" "$suffix"
}

# create_db <profile> [notable] — a state DB with the live schema (no rows), or
# an empty DB with NO config_machine_state table at all.
create_db() {
  local mode="${2:-table}"
  node --experimental-sqlite --no-warnings -e '
    const {DatabaseSync}=require("node:sqlite");
    const db=new DatabaseSync(process.argv[1]);
    if (process.argv[2] === "table") db.exec("CREATE TABLE config_machine_state (state_key TEXT NOT NULL PRIMARY KEY, value_json TEXT NOT NULL, updated_at_ms INTEGER NOT NULL)");
    db.prepare("create table if not exists other_table (k TEXT)").run();
  ' "$(db_of "$1")" "$mode"
}

# set_row <profile> <state_key> <json> [updated_at_ms]
set_row() {
  node --experimental-sqlite --no-warnings -e '
    const {DatabaseSync}=require("node:sqlite");
    const db=new DatabaseSync(process.argv[1]);
    db.prepare("insert into config_machine_state values (?,?,?) on conflict(state_key) do update set value_json=excluded.value_json, updated_at_ms=excluded.updated_at_ms").run(process.argv[2], process.argv[3], Number(process.argv[4]||1));
  ' "$(db_of "$1")" "$2" "$3" "${4:-1}"
}

# profile_json <email> <accountId> <refresh> [access] [extra-json-fields]
profile_json() {
  local email="$1" acct="$2" refresh="$3" access="${4:-}" extra="${5:-}"
  [ -n "$access" ] || access="$(jwt "$acct")"
  printf '{"type":"oauth","provider":"openai","email":"%s","access":"%s","refresh":"%s","idToken":"id-%s","accountId":"%s","chatgptPlanType":"pro","expires":4102444800000%s}' \
    "$email" "$access" "$refresh" "$email" "$acct" "$extra"
}

seed_main_default() {
  create_db main
  set_row main authProfiles.store "{\"version\":1,\"profiles\":{
    \"openai:aaron@muso.ai\":$(profile_json aaron@muso.ai acct-muso REAL-REFRESH-MUSO),
    \"openai:aarondkaufman@gmail.com\":$(profile_json aarondkaufman@gmail.com acct-gmail REAL-REFRESH-GMAIL),
    \"openai:aaronkaufman@me.com\":$(profile_json aaronkaufman@me.com acct-me REAL-REFRESH-ME)}}" 1000
  set_row main authProfiles.state '{"version":1,"lastGood":{"openai":"openai:aaron@muso.ai"}}' 1000
}

read_row() {  # read_row <profile> <state_key> → value_json or ""
  node --experimental-sqlite --no-warnings -e '
    const {DatabaseSync}=require("node:sqlite");
    try { const db=new DatabaseSync(process.argv[1],{readOnly:true});
      const r=db.prepare("select value_json from config_machine_state where state_key=?").get(process.argv[2]);
      process.stdout.write(r ? r.value_json : ""); } catch (e) {}
  ' "$(db_of "$1")" "$2"
}
row_updated_at() {
  node --experimental-sqlite --no-warnings -e '
    const {DatabaseSync}=require("node:sqlite");
    const db=new DatabaseSync(process.argv[1],{readOnly:true});
    const r=db.prepare("select updated_at_ms from config_machine_state where state_key=?").get(process.argv[2]);
    process.stdout.write(r ? String(r.updated_at_ms) : "");
  ' "$(db_of "$1")" "$2"
}
edge_field() { read_row edge authProfiles.store | jq -r --arg id "$1" --arg f "$2" '.profiles[$id][$f] // "<absent>"'; }
edge_profile_count() { read_row edge authProfiles.store | jq -r '.profiles | length'; }
main_store_sha() { read_row main authProfiles.store | shasum -a 256 | cut -d' ' -f1; }

run_mirror() { run "$SCRIPT" "$@"; }

# assert_no_bytes <needle> <file> — a bare `! grep` under bats/set -e is a
# NO-OP (the negation never fails the test); this helper actually fails.
assert_no_bytes() {
  [ -f "$2" ] || return 0
  if grep -aqF -- "$1" "$2"; then echo "LEAK: '$1' found in $2" >&2; return 1; fi
  return 0
}

# ── runtime gate ─────────────────────────────────────────────────────────────

@test "gate: pre-2026.8 runtime is not applicable (exit 0) and writes nothing" {
  create_db edge
  FAKE_OPENCLAW_VERSION="2026.7.1" run_mirror
  [ "$status" -eq 0 ]
  [[ "$output" == *"not applicable on 2026.7.1"* ]]
  [ -z "$(read_row edge authProfiles.store)" ]
}

@test "gate: unknown runtime version fails CLOSED (exit 2) and writes nothing" {
  create_db edge
  FAKE_OPENCLAW_VERSION="garbage" run_mirror
  [ "$status" -eq 2 ]
  [[ "$output" == *"UNEVALUATED"* ]]
  [ -z "$(read_row edge authProfiles.store)" ]
}

@test "gate: --restart outside ensure mode and source==target are argument errors" {
  run_mirror --check --restart
  [ "$status" -eq 2 ]
  CODEX_MIRROR_TARGET=main run_mirror
  [ "$status" -eq 2 ]
  [[ "$output" == *"cannot mirror itself"* ]]
}

# ── ensure ───────────────────────────────────────────────────────────────────

@test "ensure: absent edge row → row created with every openai:* profile, sentinel refresh, access+accountId together" {
  create_db edge
  run_mirror
  [ "$status" -eq 0 ]
  [ "$(edge_profile_count)" = "3" ]
  for id in openai:aaron@muso.ai openai:aarondkaufman@gmail.com openai:aaronkaufman@me.com; do
    [[ "$output" == *"WRITTEN	$id	added"* ]]
    [ "$(edge_field "$id" refresh)" = "$SENTINEL" ]
    [ "$(edge_field "$id" type)" = "oauth" ]
    [ "$(edge_field "$id" provider)" = "openai" ]
    [ "$(edge_field "$id" chatgptPlanType)" = "pro" ]
    [ "$(edge_field "$id" expires)" = "4102444800000" ]
  done
  [ "$(edge_field openai:aaron@muso.ai access)" = "$(jwt acct-muso)" ]
  [ "$(edge_field openai:aaron@muso.ai accountId)" = "acct-muso" ]
  [ "$(edge_field openai:aaron@muso.ai email)" = "aaron@muso.ai" ]
  [ "$(edge_field openai:aaron@muso.ai idToken)" = "id-aaron@muso.ai" ]
  # summary line is the machine channel
  [[ "$output" == *"SUMMARY	-	written=3 unchanged=0 pruned=0 refused=0 failed=0"* ]]
}

@test "ensure: NO real refresh token reaches the edge sqlite file (raw byte scan) and main is untouched" {
  create_db edge
  before="$(main_store_sha)"
  run_mirror
  [ "$status" -eq 0 ]
  for tok in REAL-REFRESH-MUSO REAL-REFRESH-GMAIL REAL-REFRESH-ME; do
    assert_no_bytes "$tok" "$(db_of edge)"
    assert_no_bytes "$tok" "$(db_of edge)-wal"
  done
  [ "$(main_store_sha)" = "$before" ]
  [ "$(row_updated_at main authProfiles.store)" = "1000" ]
}

@test "ensure: bumps updated_at_ms on write and leaves other rows (authProfiles.state, unrelated keys) alone" {
  create_db edge
  set_row edge auth.sharedStore '{"location":"state-db"}' 777
  set_row edge authProfiles.state '{"version":1,"usageStats":{}}' 778
  run_mirror
  [ "$status" -eq 0 ]
  now_ms="$(date +%s)000"
  ts="$(row_updated_at edge authProfiles.store)"
  [ "$ts" -gt $((now_ms - 60000)) ]
  [ "$(read_row edge auth.sharedStore)" = '{"location":"state-db"}' ]
  [ "$(row_updated_at edge auth.sharedStore)" = "777" ]
  [ "$(read_row edge authProfiles.state)" = '{"version":1,"usageStats":{}}' ]
  [ "$(row_updated_at edge authProfiles.state)" = "778" ]
}

@test "ensure: idempotent — a second run writes nothing and does not touch updated_at_ms" {
  create_db edge
  run_mirror
  [ "$status" -eq 0 ]
  ts="$(row_updated_at edge authProfiles.store)"
  run_mirror
  [ "$status" -eq 0 ]
  [[ "$output" == *"written=0 unchanged=3 pruned=0 refused=0 failed=0"* ]]
  [[ "$output" == *"nothing changed, no restart needed"* ]]
  [ "$(row_updated_at edge authProfiles.store)" = "$ts" ]
}

@test "ensure: a rotated access token on main is re-mirrored (stale edge profile replaced)" {
  create_db edge
  run_mirror
  [ "$status" -eq 0 ]
  new_access="$(jwt acct-muso 4102444800 rotated)"
  set_row main authProfiles.store "{\"version\":1,\"profiles\":{
    \"openai:aaron@muso.ai\":$(profile_json aaron@muso.ai acct-muso REAL-REFRESH-MUSO-2 "$new_access"),
    \"openai:aarondkaufman@gmail.com\":$(profile_json aarondkaufman@gmail.com acct-gmail REAL-REFRESH-GMAIL),
    \"openai:aaronkaufman@me.com\":$(profile_json aaronkaufman@me.com acct-me REAL-REFRESH-ME)}}" 2000
  ts_before="$(row_updated_at edge authProfiles.store)"
  sleep 1
  run_mirror
  [ "$status" -eq 0 ]
  [ "$(row_updated_at edge authProfiles.store)" -gt "$ts_before" ]
  [[ "$output" == *"WRITTEN	openai:aaron@muso.ai	replaced"* ]]
  [[ "$output" == *"written=1 unchanged=2"* ]]
  [ "$(edge_field openai:aaron@muso.ai access)" = "$new_access" ]
  assert_no_bytes "REAL-REFRESH-MUSO-2" "$(db_of edge)"
  assert_no_bytes "REAL-REFRESH-MUSO-2" "$(db_of edge)-wal"
}

@test "ensure: non-openai profile keys on edge are preserved untouched" {
  create_db edge
  set_row edge authProfiles.store '{"version":1,"profiles":{"anthropic:x@y":{"type":"api_key","key":"k"}}}' 5
  run_mirror
  [ "$status" -eq 0 ]
  [ "$(edge_profile_count)" = "4" ]
  [ "$(edge_field anthropic:x@y key)" = "k" ]
}

@test "ensure: prunes a stale sentinel-bearing openai:* profile on edge that main no longer has" {
  create_db edge
  set_row edge authProfiles.store "{\"version\":1,\"profiles\":{\"openai:gone@muso.ai\":$(profile_json gone@muso.ai acct-gone "$SENTINEL")}}" 5
  run_mirror
  [ "$status" -eq 0 ]
  [[ "$output" == *"PRUNED	openai:gone@muso.ai"* ]]
  [ "$(edge_field openai:gone@muso.ai access)" = "<absent>" ]
  [ "$(edge_profile_count)" = "3" ]
}

# ── refusals (single-refresher invariant + runtime-throw guard) ──────────────

@test "refuse: an edge profile holding a REAL refresh token is never overwritten (exit 1, others still mirrored)" {
  create_db edge
  set_row edge authProfiles.store "{\"version\":1,\"profiles\":{\"openai:aaron@muso.ai\":$(profile_json aaron@muso.ai acct-muso EDGE-OWN-REAL-REFRESH "$(jwt acct-muso 1 edgeown)")}}" 5
  run_mirror
  [ "$status" -eq 1 ]
  [[ "$output" == *"REFUSED	openai:aaron@muso.ai	target holds a REAL refresh token"* ]]
  [ "$(edge_field openai:aaron@muso.ai refresh)" = "EDGE-OWN-REAL-REFRESH" ]
  [ "$(edge_field openai:aaron@muso.ai access)" = "$(jwt acct-muso 1 edgeown)" ]
  [ "$(edge_field openai:aarondkaufman@gmail.com refresh)" = "$SENTINEL" ]
  [[ "$output" == *"written=2 unchanged=0 pruned=0 refused=1 failed=0"* ]]
}

@test "refuse: an extra edge openai:* profile with a REAL refresh token is not pruned (exit 1)" {
  create_db edge
  set_row edge authProfiles.store "{\"version\":1,\"profiles\":{\"openai:other@muso.ai\":$(profile_json other@muso.ai acct-other OTHER-REAL-REFRESH)}}" 5
  run_mirror
  [ "$status" -eq 1 ]
  [[ "$output" == *"REFUSED	openai:other@muso.ai	extra profile on target holds a REAL refresh token"* ]]
  [ "$(edge_field openai:other@muso.ai refresh)" = "OTHER-REAL-REFRESH" ]
  [ "$(edge_profile_count)" = "4" ]
}

@test "refuse: source stored accountId ≠ access-token claim (the runtime would THROW) — that profile is skipped" {
  create_db edge
  set_row main authProfiles.store "{\"version\":1,\"profiles\":{
    \"openai:aaron@muso.ai\":$(profile_json aaron@muso.ai acct-muso REAL-REFRESH-MUSO "$(jwt acct-SOMEONE-ELSE)"),
    \"openai:aarondkaufman@gmail.com\":$(profile_json aarondkaufman@gmail.com acct-gmail REAL-REFRESH-GMAIL)}}" 2000
  run_mirror
  [ "$status" -eq 1 ]
  [[ "$output" == *"REFUSED	openai:aaron@muso.ai	stored accountId acct-muso != token claim acct-SOMEONE-ELSE"* ]]
  [ "$(edge_field openai:aaron@muso.ai access)" = "<absent>" ]
  [ "$(edge_field openai:aarondkaufman@gmail.com accountId)" = "acct-gmail" ]
}

@test "refuse: source access token without a decodable account claim is skipped" {
  create_db edge
  set_row main authProfiles.store "{\"version\":1,\"profiles\":{
    \"openai:aaron@muso.ai\":$(profile_json aaron@muso.ai acct-muso REAL-REFRESH-MUSO "opaque-not-a-jwt")}}" 2000
  run_mirror
  [ "$status" -eq 1 ]
  [[ "$output" == *"REFUSED	openai:aaron@muso.ai	access token carries no decodable chatgpt_account_id claim"* ]]
  [ -z "$(read_row edge authProfiles.store)" ]
}

@test "refuse: a source whose refresh slot is a sentinel is a derived store — never mirror a mirror" {
  create_db edge
  set_row main authProfiles.store "{\"version\":1,\"profiles\":{
    \"openai:aaron@muso.ai\":$(profile_json aaron@muso.ai acct-muso "$SENTINEL")}}" 2000
  run_mirror
  [ "$status" -eq 1 ]
  [[ "$output" == *"REFUSED	openai:aaron@muso.ai	source refresh is a SENTINEL"* ]]
  [ -z "$(read_row edge authProfiles.store)" ]
}

@test "refuse: source profile missing accountId/expires/access is skipped, not mirrored partially" {
  create_db edge
  set_row main authProfiles.store "{\"version\":1,\"profiles\":{
    \"openai:aaron@muso.ai\":{\"type\":\"oauth\",\"provider\":\"openai\",\"access\":\"$(jwt acct-muso)\",\"refresh\":\"REAL-REFRESH-MUSO\"}}}" 2000
  run_mirror
  [ "$status" -eq 1 ]
  [[ "$output" == *"REFUSED	openai:aaron@muso.ai	accountId missing; expires missing"* ]]
  [ -z "$(read_row edge authProfiles.store)" ]
}

# ── TOCTOU: the refusal must hold INSIDE the transaction (QA finding, #935) ──
# CODEX_MIRROR_TEST_HOOK_BEFORE_TXN runs a shell command right before BEGIN
# IMMEDIATE, i.e. AFTER the pre-transaction snapshot was checked. The hook plays
# a concurrent writer (runtime / device login / operator) that commits a REAL
# refresh token for the profile the mirror is about to replace or prune.

# inject_real_refresh <profile-id> — echo the hook COMMAND: a read-modify-write
# of ONLY that profile in edge's cell, giving it a real refresh token and its own
# access token. The JS lives in a FILE and the command is plain POSIX single
# quoting, because the production seam runs it via Node's execSync default
# /bin/sh — on CI that is dash, and a Bash `printf %q` rendering of multiline
# JS ($'…') is passed to node literally there (QA finding on #935, round 2).
inject_real_refresh() {
  cat > "$TEST_TMPDIR/inject-real-refresh.js" <<'JS'
const {DatabaseSync}=require("node:sqlite");
const [dbPath,id,access]=process.argv.slice(2);
const db=new DatabaseSync(dbPath);
db.exec("pragma busy_timeout=5000");
const r=db.prepare("select value_json from config_machine_state where state_key=?").get("authProfiles.store");
const j=r?JSON.parse(r.value_json):{version:1,profiles:{}};
j.profiles[id]={type:"oauth",provider:"openai",email:"x",access,refresh:"CONCURRENT-REAL-REFRESH",accountId:"acct-concurrent",expires:5};
db.prepare("insert into config_machine_state values (?,?,?) on conflict(state_key) do update set value_json=excluded.value_json, updated_at_ms=excluded.updated_at_ms").run("authProfiles.store",JSON.stringify(j),4242);
JS
  printf "node --experimental-sqlite --no-warnings '%s' '%s' '%s' '%s'" \
    "$TEST_TMPDIR/inject-real-refresh.js" "$(db_of edge)" "$1" "$(jwt acct-concurrent 1 concurrent)"
}
edge_profile_json() { read_row edge authProfiles.store | jq -c --arg id "$1" '.profiles[$id]'; }

@test "toctou: a REAL refresh token committed between the pre-check and the replace transaction is refused, row byte-identical" {
  create_db edge
  run_mirror
  [ "$status" -eq 0 ]
  new_access="$(jwt acct-muso 4102444800 rotated)"
  set_row main authProfiles.store "{\"version\":1,\"profiles\":{
    \"openai:aaron@muso.ai\":$(profile_json aaron@muso.ai acct-muso REAL-REFRESH-MUSO "$new_access"),
    \"openai:aarondkaufman@gmail.com\":$(profile_json aarondkaufman@gmail.com acct-gmail REAL-REFRESH-GMAIL),
    \"openai:aaronkaufman@me.com\":$(profile_json aaronkaufman@me.com acct-me REAL-REFRESH-ME)}}" 2000
  export CODEX_MIRROR_TEST_HOOK_BEFORE_TXN="$(inject_real_refresh openai:aaron@muso.ai)"
  run_mirror
  [ "$status" -eq 1 ]
  [[ "$output" == *"REFUSED	openai:aaron@muso.ai	target gained a REAL refresh token before the replace transaction"* ]]
  [[ "$output" != *"WRITTEN	openai:aaron@muso.ai"* ]]
  expected="$(jq -cn --arg a "$(jwt acct-concurrent 1 concurrent)" '{type:"oauth",provider:"openai",email:"x",access:$a,refresh:"CONCURRENT-REAL-REFRESH",accountId:"acct-concurrent",expires:5}')"
  [ "$(edge_profile_json openai:aaron@muso.ai)" = "$expected" ]
  [ "$(row_updated_at edge authProfiles.store)" = "4242" ]
  [[ "$output" == *"written=0 unchanged=2 pruned=0 refused=1 failed=0"* ]]
}

@test "toctou: a REAL refresh token committed before the prune transaction is not pruned, row byte-identical" {
  create_db edge
  run_mirror
  [ "$status" -eq 0 ]
  set_row edge authProfiles.store "$(read_row edge authProfiles.store | jq -c --arg s "$SENTINEL" --arg a "$(jwt acct-gone)" '.profiles["openai:gone@muso.ai"]={type:"oauth",provider:"openai",access:$a,refresh:$s,accountId:"acct-gone",expires:5}')" 7
  export CODEX_MIRROR_TEST_HOOK_BEFORE_TXN="$(inject_real_refresh openai:gone@muso.ai)"
  run_mirror
  [ "$status" -eq 1 ]
  [[ "$output" == *"REFUSED	openai:gone@muso.ai	target gained a REAL refresh token before the prune transaction"* ]]
  [[ "$output" != *"PRUNED"* ]]
  [ "$(edge_field openai:gone@muso.ai refresh)" = "CONCURRENT-REAL-REFRESH" ]
  [ "$(row_updated_at edge authProfiles.store)" = "4242" ]
  [ "$(edge_profile_count)" = "4" ]
}

# inject_independent_after_commit <profile-id> — hook body: if that profile
# ALREADY carries the mirror sentinel (i.e. its transaction has committed),
# replace its refresh with a real token that is NOT one of main's. Fires before
# every later transaction, so it lands between profile A's commit and B's.
inject_independent_after_commit() {
  cat > "$TEST_TMPDIR/inject-independent.js" <<'JS'
const {DatabaseSync}=require("node:sqlite");
const [dbPath,id]=process.argv.slice(2);
const db=new DatabaseSync(dbPath);
db.exec("pragma busy_timeout=5000");
const r=db.prepare("select value_json from config_machine_state where state_key=?").get("authProfiles.store");
if(!r) process.exit(0);
const j=JSON.parse(r.value_json);
const p=j.profiles[id];
if(!p || p.refresh!=="SYNC-MANAGED-NO-REFRESH-TOKEN") process.exit(0);
p.refresh="INDEPENDENT-REAL-REFRESH-NOT-IN-MAIN";
db.prepare("update config_machine_state set value_json=?, updated_at_ms=? where state_key=?").run(JSON.stringify(j),777,"authProfiles.store");
JS
  printf "node --experimental-sqlite --no-warnings '%s' '%s' '%s'" "$TEST_TMPDIR/inject-independent.js" "$(db_of edge)" "$1"
}

@test "toctou: an INDEPENDENT real refresh token written into an already-committed profile, before a later transaction, fails the run (no success, no restart)" {
  create_db edge
  # first profile in main's map is openai:aaron@muso.ai — it commits first
  export CODEX_MIRROR_TEST_HOOK_BEFORE_TXN="$(inject_independent_after_commit openai:aaron@muso.ai)"
  run_mirror --restart
  [ "$status" -eq 1 ]
  [[ "$output" == *"WRITTEN	openai:aaron@muso.ai	added"* ]]
  [[ "$output" == *"FAILED	openai:aaron@muso.ai	target profile holds a REAL refresh token after the mirror ran"* ]]
  [ "$(edge_field openai:aaron@muso.ai refresh)" = "INDEPENDENT-REAL-REFRESH-NOT-IN-MAIN" ]
  [ ! -f "$RESTART_LOG" ]
  [[ "$(cat "$PAGE_LOG")" == *"codex edge mirror INCOMPLETE"* ]]
  [[ "$output" == *"failed=1"* ]]
}

# rewrite_after_commit <profile-id> <mode: delete|stale|extra> — hook body:
# once <profile-id> carries the mirror sentinel (its transaction committed),
# delete it / restore an older access token into it / add an extra sentinel
# profile — the "another writer restored an older cell" shape.
rewrite_after_commit() {
  cat > "$TEST_TMPDIR/rewrite-after-commit.js" <<'JS'
const {DatabaseSync}=require("node:sqlite");
const [dbPath,id,mode]=process.argv.slice(2);
const db=new DatabaseSync(dbPath);
db.exec("pragma busy_timeout=5000");
const r=db.prepare("select value_json from config_machine_state where state_key=?").get("authProfiles.store");
if(!r) process.exit(0);
const j=JSON.parse(r.value_json);
const p=j.profiles[id];
if(!p || p.refresh!=="SYNC-MANAGED-NO-REFRESH-TOKEN" || j.profiles["openai:extra@muso.ai"]) process.exit(0);
const sent=(k)=>j.profiles[k]&&j.profiles[k].refresh==="SYNC-MANAGED-NO-REFRESH-TOKEN";
const allThree=sent("openai:aaron@muso.ai")&&sent("openai:aarondkaufman@gmail.com")&&sent("openai:aaronkaufman@me.com");
if(mode==="delete") delete j.profiles[id];
else if(mode==="stale") p.access="hdr.stale.sig";
else if(mode==="extra") j.profiles["openai:extra@muso.ai"]={type:"oauth",provider:"openai",access:"x",refresh:"SYNC-MANAGED-NO-REFRESH-TOKEN",accountId:"acct-x",expires:1};
else if(mode==="extra-late"){ if(!allThree) process.exit(0); j.profiles["openai:extra@muso.ai"]={type:"oauth",provider:"openai",access:"x",refresh:"SYNC-MANAGED-NO-REFRESH-TOKEN",accountId:"acct-x",expires:1}; }
db.prepare("update config_machine_state set value_json=?, updated_at_ms=? where state_key=?").run(JSON.stringify(j),888,"authProfiles.store");
JS
  printf "node --experimental-sqlite --no-warnings '%s' '%s' '%s' '%s'" "$TEST_TMPDIR/rewrite-after-commit.js" "$(db_of edge)" "$1" "$2"
}

@test "toctou: profile A DELETED by a concurrent writer after its commit, before B's transaction → final validation fails the run (no restart)" {
  create_db edge
  export CODEX_MIRROR_TEST_HOOK_BEFORE_TXN="$(rewrite_after_commit openai:aaron@muso.ai delete)"
  run_mirror --restart
  [ "$status" -eq 1 ]
  [[ "$output" == *"WRITTEN	openai:aaron@muso.ai	added"* ]]
  [[ "$output" == *"FAILED	openai:aaron@muso.ai	target profile MISSING after the mirror ran"* ]]
  [ ! -f "$RESTART_LOG" ]
  [[ "$(cat "$PAGE_LOG")" == *"codex edge mirror INCOMPLETE"* ]]
}

@test "toctou: profile A rewritten STALE by a concurrent writer after its commit → final validation fails the run (no restart)" {
  create_db edge
  export CODEX_MIRROR_TEST_HOOK_BEFORE_TXN="$(rewrite_after_commit openai:aaron@muso.ai stale)"
  run_mirror --restart
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAILED	openai:aaron@muso.ai	target profile DRIFTED from the source-derived value"* ]]
  [ "$(edge_field openai:aaron@muso.ai access)" = "hdr.stale.sig" ]
  [ ! -f "$RESTART_LOG" ]
}

@test "toctou: a sentinel-bearing extra profile appearing mid-run is PRUNED by the post-loop pass (re-read cell), run stays clean" {
  create_db edge
  export CODEX_MIRROR_TEST_HOOK_BEFORE_TXN="$(rewrite_after_commit openai:aaron@muso.ai extra)"
  run_mirror --restart
  [ "$status" -eq 0 ]
  [[ "$output" == *"PRUNED	openai:extra@muso.ai"* ]]
  [ "$(edge_field openai:extra@muso.ai access)" = "<absent>" ]
  [ "$(edge_profile_count)" = "3" ]
  [ -f "$RESTART_LOG" ]
}

@test "toctou: an extra openai:* profile appearing AFTER the prune pass enumerated (during a prune transaction) → final key-set validation fails the run (no restart)" {
  create_db edge
  # a stale sentinel extra guarantees a prune transaction AFTER the three profile commits;
  # the hook fires before it, once all three mirrored profiles are present, and adds a new extra
  set_row edge authProfiles.store "{\"version\":1,\"profiles\":{\"openai:gone@muso.ai\":$(profile_json gone@muso.ai acct-gone "$SENTINEL")}}" 5
  export CODEX_MIRROR_TEST_HOOK_BEFORE_TXN="$(rewrite_after_commit openai:aaron@muso.ai extra-late)"
  run_mirror --restart
  [ "$status" -eq 1 ]
  [[ "$output" == *"PRUNED	openai:gone@muso.ai"* ]]
  [[ "$output" == *"FAILED	openai:extra@muso.ai	extra openai:* profile on target after the mirror ran"* ]]
  [ ! -f "$RESTART_LOG" ]
  [[ "$(cat "$PAGE_LOG")" == *"codex edge mirror INCOMPLETE"* ]]
}

# rotate_source <once|always> — hook body: rotate openai:aaron@muso.ai's access
# token in MAIN's cell (the SOURCE) before a target transaction — a canonical
# refresh landing mid-run. `once` rotates on the first firing only; `always`
# rotates on every firing (a source that keeps moving).
rotate_source() {
  cat > "$TEST_TMPDIR/rotate-source.js" <<'JS'
const {DatabaseSync}=require("node:sqlite");
const [dbPath,mode,hdr]=process.argv.slice(2);
const db=new DatabaseSync(dbPath); db.exec("pragma busy_timeout=5000");
const r=db.prepare("select value_json from config_machine_state where state_key=?").get("authProfiles.store");
const j=JSON.parse(r.value_json); const p=j.profiles["openai:aaron@muso.ai"];
const n=(p.rotations||0);
if(mode==="once" && n>=1) process.exit(0);
p.rotations=n+1;
p.access=hdr+"."+Buffer.from(JSON.stringify({"https://api.openai.com/auth":{chatgpt_account_id:"acct-muso"},rot:n+1})).toString("base64url")+".sig";
db.prepare("update config_machine_state set value_json=?, updated_at_ms=? where state_key=?").run(JSON.stringify(j),9000+n,"authProfiles.store");
JS
  printf "node --experimental-sqlite --no-warnings '%s' '%s' '%s' '%s'" "$TEST_TMPDIR/rotate-source.js" "$(db_of main)" "$1" "$(printf '{"alg":"RS256"}' | base64 | tr '+/' '-_' | tr -d '=\n')"
}
main_field() { read_row main authProfiles.store | jq -r --arg id "$1" --arg f "$2" '.profiles[$id][$f] // "<absent>"'; }

@test "source race: main rotates aaron's access token mid-run → the run re-converges once and edge ends on the NEW token (restart allowed)" {
  create_db edge
  export CODEX_MIRROR_TEST_HOOK_BEFORE_TXN="$(rotate_source once)"
  run_mirror --restart
  [ "$status" -eq 0 ]
  [[ "$output" == *"SOURCE_CHANGED	-	source cell changed during the run"* ]]
  [ "$(main_field openai:aaron@muso.ai rotations)" = "1" ]                       # the source DID rotate mid-run
  [ "$(edge_field openai:aaron@muso.ai access)" = "$(main_field openai:aaron@muso.ai access)" ]   # edge holds the NEW token
  [ "$(edge_field openai:aaron@muso.ai access)" != "$(jwt acct-muso)" ]           # not the snapshot's old one
  [ -f "$RESTART_LOG" ]
  run_mirror --check
  [ "$status" -eq 0 ]
}

@test "source race: a source that keeps rotating during the retry → FAILED, no restart (the next run converges)" {
  create_db edge
  export CODEX_MIRROR_TEST_HOOK_BEFORE_TXN="$(rotate_source always)"
  run_mirror --restart
  [ "$status" -eq 1 ]
  [[ "$output" == *"SOURCE_CHANGED"* ]]
  [[ "$output" == *"FAILED	-	source cell changed AGAIN during the retry"* ]]
  [ ! -f "$RESTART_LOG" ]
  [[ "$(cat "$PAGE_LOG")" == *"codex edge mirror INCOMPLETE"* ]]
}

# ── freshness: ONE predicate for ensure, dry-run and check ─────────────────
# margin = 60min (CODEX_MIRROR_MIN_TOKEN_MIN; the quota probe skips accounts
# expiring inside the same CODEX_PROBE_MIN_TOKEN_MIN). Edge cannot refresh a
# mirrored token, so an expired or nearly-expired one is dead on arrival.
seed_main_expiring() {  # <expires-ms> [jwt-exp-epoch-s]
  set_row main authProfiles.store "{\"version\":1,\"profiles\":{
    \"openai:aaron@muso.ai\":$(profile_json aaron@muso.ai acct-muso REAL-REFRESH-MUSO "$(jwt acct-muso "${2:-4102444800}")" ",\"expires\":$1" | sed 's/"expires":4102444800000,//'),
    \"openai:aarondkaufman@gmail.com\":$(profile_json aarondkaufman@gmail.com acct-gmail REAL-REFRESH-GMAIL)}}" 2000
}

@test "freshness: an EXPIRED source token is REFUSED (never mirrored), run INCOMPLETE, no restart; --check flags it" {
  create_db edge
  seed_main_expiring "$(( ($(date +%s) - 60) * 1000 ))"
  run_mirror --restart
  [ "$status" -eq 1 ]
  [[ "$output" == *"REFUSED	openai:aaron@muso.ai	access token EXPIRED at"* ]]
  [ "$(edge_field openai:aaron@muso.ai access)" = "<absent>" ]
  [ "$(edge_field openai:aarondkaufman@gmail.com refresh)" = "$SENTINEL" ]
  [ ! -f "$RESTART_LOG" ]
  [[ "$(cat "$PAGE_LOG")" == *"codex edge mirror INCOMPLETE"* ]]
  run_mirror --check
  [ "$status" -eq 1 ]
  [[ "$output" == *"CHECK_FAIL	openai:aaron@muso.ai	source profile unusable: access token EXPIRED"* ]]
}

@test "freshness: a token INSIDE the 60min margin (expires in 30min) is REFUSED; JUST OUTSIDE (61min) is mirrored" {
  create_db edge
  seed_main_expiring "$(( ($(date +%s) + 1800) * 1000 ))"
  run_mirror
  [ "$status" -eq 1 ]
  [[ "$output" == *"REFUSED	openai:aaron@muso.ai	access token expires at"*"inside the 60min freshness margin"* ]]
  [ "$(edge_field openai:aaron@muso.ai access)" = "<absent>" ]
  seed_main_expiring "$(( ($(date +%s) + 3660) * 1000 ))"
  run_mirror
  [ "$status" -eq 0 ]
  [[ "$output" == *"WRITTEN	openai:aaron@muso.ai	added"* ]]
  run_mirror --check
  [ "$status" -eq 0 ]
}

@test "freshness: a JWT exp inside the margin is REFUSED even when the stored expires disagrees" {
  create_db edge
  seed_main_expiring 4102444800000 "$(( $(date +%s) + 600 ))"
  run_mirror
  [ "$status" -eq 1 ]
  [[ "$output" == *"REFUSED	openai:aaron@muso.ai	access token JWT exp"*"inside the 60min freshness margin"* ]]
  [ "$(edge_field openai:aaron@muso.ai access)" = "<absent>" ]
}

@test "freshness: an already-mirrored profile that has since EXPIRED is not UNCHANGED/CHECK_OK — it is refused and flagged" {
  create_db edge
  run_mirror
  [ "$status" -eq 0 ]
  # main and edge both still hold that profile; time moves past its expiry (rewrite both cells' expires into the past)
  for prof in main edge; do
    node --experimental-sqlite --no-warnings -e '
      const {DatabaseSync}=require("node:sqlite");const db=new DatabaseSync(process.argv[1]);
      const r=db.prepare("select value_json from config_machine_state where state_key=?").get("authProfiles.store");
      const j=JSON.parse(r.value_json); j.profiles["openai:aaron@muso.ai"].expires=Date.now()-1000;
      db.prepare("update config_machine_state set value_json=? where state_key=?").run(JSON.stringify(j),"authProfiles.store");' "$(db_of "$prof")"
  done
  run_mirror --check
  [ "$status" -eq 1 ]
  [[ "$output" == *"CHECK_FAIL	openai:aaron@muso.ai	source profile unusable: access token EXPIRED"* ]]
  run_mirror
  [ "$status" -eq 1 ]
  [[ "$output" == *"REFUSED	openai:aaron@muso.ai	access token EXPIRED"* ]]
  [[ "$output" != *"UNCHANGED	openai:aaron@muso.ai"* ]]
}

# ── one pager per failure: the systemd run stamps self-paged for hydra-unit-failed@ ──

@test "self-paged: a failure under --restart writes the self-paged stamp for codex-edge-mirror.service; plain ensure does not" {
  run_mirror --restart
  [ "$status" -eq 2 ]
  [ -s "$HYDRA_SELF_PAGED_DIR/codex-edge-mirror.service" ]
  [ ! -e "$HYDRA_SELF_PAGED_DIR/openclaw-gateway-edge.service" ]   # keyed by OUR unit, not the gateway we restart
  rm -rf "$HYDRA_SELF_PAGED_DIR" "$CODEX_MIRROR_STATE_DIR"
  run_mirror
  [ "$status" -eq 2 ]
  [ ! -d "$HYDRA_SELF_PAGED_DIR" ]
}

# ── structural (exit 2, never a write) ───────────────────────────────────────

@test "structural: edge state DB without config_machine_state is un-migrated — refuse to create the table (exit 2)" {
  create_db edge notable
  run_mirror
  [ "$status" -eq 2 ]
  [[ "$output" == *"has no config_machine_state table"* ]]
  [[ "$output" == *"UNEVALUATED"* ]]
  run node --experimental-sqlite --no-warnings -e 'const {DatabaseSync}=require("node:sqlite");const db=new DatabaseSync(process.argv[1]);db.prepare("select 1 from config_machine_state").get()' "$(db_of edge)"
  [ "$status" -ne 0 ]
  [[ "$output" == *"no such table"* ]]
}

@test "structural: missing edge state DB / missing main row / missing main DB are exit 2, nothing written" {
  run_mirror
  [ "$status" -eq 2 ]
  [[ "$output" == *"target store not found"* ]]
  create_db edge
  node --experimental-sqlite --no-warnings -e 'const {DatabaseSync}=require("node:sqlite");new DatabaseSync(process.argv[1]).prepare("delete from config_machine_state where state_key=?").run("authProfiles.store")' "$(db_of main)"
  run_mirror
  [ "$status" -eq 2 ]
  [[ "$output" == *"has no authProfiles.store row"* ]]
  [ -z "$(read_row edge authProfiles.store)" ]
  rm -f "$(db_of main)"
  run_mirror
  [ "$status" -eq 2 ]
  [[ "$output" == *"source store not found"* ]]
  [ -z "$(read_row edge authProfiles.store)" ]
}

# ── --dry-run ────────────────────────────────────────────────────────────────

@test "dry-run: prints the per-profile plan (value-free) and writes NOTHING" {
  create_db edge
  run_mirror --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"PLAN	openai:aaron@muso.ai	would add: access_len="*"accountId=acct-muso expires=2100-01-01"*"plan=pro idToken=yes refresh=sentinel"* ]]
  [[ "$output" == *"PLAN	openai:aarondkaufman@gmail.com	would add"* ]]
  [[ "$output" == *"PLAN	openai:aaronkaufman@me.com	would add"* ]]
  [[ "$output" == *"written=3 unchanged=0"* ]]
  [[ "$output" != *"$(jwt acct-muso)"* ]]
  [[ "$output" != *"REAL-REFRESH"* ]]
  [ -z "$(read_row edge authProfiles.store)" ]
}

@test "dry-run: reports refusals with the exit code ensure would return, still writing nothing" {
  create_db edge
  set_row edge authProfiles.store "{\"version\":1,\"profiles\":{\"openai:aaron@muso.ai\":$(profile_json aaron@muso.ai acct-muso EDGE-OWN-REAL-REFRESH)}}" 5
  run_mirror --dry-run
  [ "$status" -eq 1 ]
  [[ "$output" == *"REFUSED	openai:aaron@muso.ai"* ]]
  [[ "$output" == *"PLAN	openai:aarondkaufman@gmail.com	would add"* ]]
  [ "$(edge_profile_count)" = "1" ]
  [ "$(row_updated_at edge authProfiles.store)" = "5" ]
}

# ── --check ──────────────────────────────────────────────────────────────────

@test "check: clean after ensure (exit 0) and value-free" {
  create_db edge
  run_mirror
  run_mirror --check
  [ "$status" -eq 0 ]
  [[ "$output" == *"CHECK_OK	openai:aaron@muso.ai"* ]]
  [[ "$output" == *"clean (ok=3 fail=0)"* ]]
  [[ "$output" != *"REAL-REFRESH"* ]]
}

@test "check: absent edge row is drift (exit 1), naming every missing profile" {
  create_db edge
  run_mirror --check
  [ "$status" -eq 1 ]
  [[ "$output" == *"CHECK_FAIL	openai:aaron@muso.ai	target authProfiles.store row ABSENT"* ]]
  [[ "$output" == *"DRIFT DETECTED (ok=0 fail=3)"* ]]
}

@test "check: stale access token on edge is drift" {
  create_db edge
  run_mirror
  set_row main authProfiles.store "{\"version\":1,\"profiles\":{
    \"openai:aaron@muso.ai\":$(profile_json aaron@muso.ai acct-muso REAL-REFRESH-MUSO "$(jwt acct-muso 4102444800 rotated)"),
    \"openai:aarondkaufman@gmail.com\":$(profile_json aarondkaufman@gmail.com acct-gmail REAL-REFRESH-GMAIL),
    \"openai:aaronkaufman@me.com\":$(profile_json aaronkaufman@me.com acct-me REAL-REFRESH-ME)}}" 2000
  run_mirror --check
  [ "$status" -eq 1 ]
  [[ "$output" == *"CHECK_FAIL	openai:aaron@muso.ai	access STALE (differs from source)"* ]]
  [[ "$output" == *"ok=2 fail=1"* ]]
}

@test "check: a mirrored profile whose stored accountId ≠ its token claim is drift (runtime would THROW)" {
  create_db edge
  run_mirror
  # corrupt edge's stored accountId only — the token claim still says acct-muso
  node --experimental-sqlite --no-warnings -e '
    const {DatabaseSync}=require("node:sqlite");const db=new DatabaseSync(process.argv[1]);
    const r=db.prepare("select value_json from config_machine_state where state_key=?").get("authProfiles.store");
    const j=JSON.parse(r.value_json); j.profiles["openai:aaron@muso.ai"].accountId="acct-WRONG";
    db.prepare("update config_machine_state set value_json=? where state_key=?").run(JSON.stringify(j),"authProfiles.store");' "$(db_of edge)"
  run_mirror --check
  [ "$status" -eq 1 ]
  [[ "$output" == *"CHECK_FAIL	openai:aaron@muso.ai	"*"stored accountId acct-WRONG != token claim acct-muso (runtime would THROW)"* ]]
}

@test "check: a non-token field changed on edge (type→api_key, plan, idToken, an extra field) is drift — exact mirror equality" {
  create_db edge
  run_mirror
  _mutate_edge_field() {  # <id> <js-assignment on p>
    node --experimental-sqlite --no-warnings -e '
      const {DatabaseSync}=require("node:sqlite");const db=new DatabaseSync(process.argv[1]);
      const r=db.prepare("select value_json from config_machine_state where state_key=?").get("authProfiles.store");
      const j=JSON.parse(r.value_json); const p=j.profiles[process.argv[2]]; eval(process.argv[3]);
      db.prepare("update config_machine_state set value_json=? where state_key=?").run(JSON.stringify(j),"authProfiles.store");' "$(db_of edge)" "$1" "$2"
  }
  _mutate_edge_field openai:aaron@muso.ai 'p.type="api_key"'
  run_mirror --check
  [ "$status" -eq 1 ]
  [[ "$output" == *"CHECK_FAIL	openai:aaron@muso.ai	profile differs from the source-derived value (fields: type)"* ]]
  run_mirror; [ "$status" -eq 0 ]   # ensure converges it back
  _mutate_edge_field openai:aaron@muso.ai 'p.chatgptPlanType="free"; p.idToken="other"; p.injected="x"'
  run_mirror --check
  [ "$status" -eq 1 ]
  [[ "$output" == *"(fields: chatgptPlanType,idToken,injected)"* ]]
  run_mirror --check
  run_mirror; run_mirror --check
  [ "$status" -eq 0 ]
}

@test "check: a REAL refresh token in edge's refresh slot is fan-out drift" {
  create_db edge
  set_row edge authProfiles.store "{\"version\":1,\"profiles\":{
    \"openai:aaron@muso.ai\":$(profile_json aaron@muso.ai acct-muso REAL-REFRESH-MUSO),
    \"openai:aarondkaufman@gmail.com\":$(profile_json aarondkaufman@gmail.com acct-gmail "$SENTINEL"),
    \"openai:aaronkaufman@me.com\":$(profile_json aaronkaufman@me.com acct-me "$SENTINEL")}}" 5
  run_mirror --check
  [ "$status" -eq 1 ]
  [[ "$output" == *"CHECK_FAIL	openai:aaron@muso.ai	refresh slot holds a REAL token (fan-out)"* ]]
  [[ "$output" == *"CHECK_FAIL	\$.profiles.openai:aaron@muso.ai.refresh	REAL source refresh token present in target cell"* ]]
}

@test "check: an extra openai:* profile on edge is drift; a non-openai key is not" {
  create_db edge
  run_mirror
  node --experimental-sqlite --no-warnings -e '
    const {DatabaseSync}=require("node:sqlite");const db=new DatabaseSync(process.argv[1]);
    const r=db.prepare("select value_json from config_machine_state where state_key=?").get("authProfiles.store");
    const j=JSON.parse(r.value_json); j.profiles["openai:extra@muso.ai"]={type:"oauth",access:"x",refresh:"SYNC-MANAGED-NO-REFRESH-TOKEN"}; j.profiles["anthropic:k"]={type:"api_key"};
    db.prepare("update config_machine_state set value_json=? where state_key=?").run(JSON.stringify(j),"authProfiles.store");' "$(db_of edge)"
  run_mirror --check
  [ "$status" -eq 1 ]
  [[ "$output" == *"CHECK_FAIL	openai:extra@muso.ai	extra openai:* profile on target"* ]]
  [[ "$output" != *"anthropic:k"* ]]
  [[ "$output" == *"ok=3 fail=1"* ]]
}

@test "check: unreadable/absent stores are UNEVALUATED (exit 2), never clean" {
  run_mirror --check
  [ "$status" -eq 2 ]
  create_db edge notable
  run_mirror --check
  [ "$status" -eq 2 ]
}

# ── --restart ────────────────────────────────────────────────────────────────

@test "restart: drain-restarts the target gateway ONLY when a profile was written" {
  create_db edge
  run_mirror --restart
  [ "$status" -eq 0 ]
  [ "$(cat "$RESTART_LOG")" = "openclaw-gateway-edge.service edge" ]
  [[ "$output" == *"openclaw-gateway-edge.service restarted"* ]]
  run_mirror --restart
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$RESTART_LOG")" -eq 1 ]
  [[ "$output" == *"nothing changed, no restart needed"* ]]
}

@test "restart: a failed gateway restart is exit 6 and pages (cell converged, gateway stale)" {
  create_db edge
  STUB_RESTART_RC=1 run_mirror --restart
  [ "$status" -eq 6 ]
  [[ "$output" == *"restart FAILED"* ]]
  [[ "$(cat "$PAGE_LOG")" == *"restart FAILED"* ]]
  [ "$(edge_profile_count)" = "3" ]
}

@test "restart: a missing restart library after a write is exit 6 and pages" {
  create_db edge
  CODEX_MIRROR_RESTART_LIB="$TEST_TMPDIR/nope.sh" run_mirror --restart
  [ "$status" -eq 6 ]
  [[ "$(cat "$PAGE_LOG")" == *"was NOT restarted"* ]]
}

@test "page: an INCOMPLETE run pages in EVERY mode — plain ensure (pre-start path) and --restart alike; --check never" {
  create_db edge
  set_row edge authProfiles.store "{\"version\":1,\"profiles\":{\"openai:aaron@muso.ai\":$(profile_json aaron@muso.ai acct-muso EDGE-OWN-REAL-REFRESH)}}" 5
  run_mirror
  [ "$status" -eq 1 ]
  [[ "$(cat "$PAGE_LOG")" == *"codex edge mirror INCOMPLETE"*"mode ensure, restart=0"* ]]
  rm -f "$PAGE_LOG" "$CODEX_MIRROR_STATE_DIR/codex-edge-mirror.page-cooldown"
  run_mirror --restart
  [ "$status" -eq 1 ]
  [[ "$(cat "$PAGE_LOG")" == *"codex edge mirror INCOMPLETE"*"restart=1"* ]]
  rm -f "$PAGE_LOG" "$CODEX_MIRROR_STATE_DIR/codex-edge-mirror.page-cooldown"
  run_mirror --check
  [ "$status" -eq 1 ]
  [ ! -f "$PAGE_LOG" ]
}

@test "restart: stands down inside an open maintenance window BEFORE writing (never converged-but-unloaded)" {
  create_db edge
  printf '{"reason":"cutover","expires_epoch":%s}' "$(( $(date +%s) + 3600 ))" > "$HYDRA_MAINTENANCE_FLAG"
  run_mirror --restart
  [ "$status" -eq 0 ]
  [[ "$output" == *"maintenance window open (cutover) — standing down"* ]]
  [ -z "$(read_row edge authProfiles.store)" ]
  [ ! -f "$RESTART_LOG" ]
  # an EXPIRED window does not suppress the mirror
  printf '{"reason":"old","expires_epoch":%s}' "$(( $(date +%s) - 10 ))" > "$HYDRA_MAINTENANCE_FLAG"
  run_mirror --restart
  [ "$status" -eq 0 ]
  [ "$(edge_profile_count)" = "3" ]
}

# ── timer-path structural failures must PAGE (QA finding, #935 round 3) ──────
# ExecStartPre swallows the exit code on purpose and a failed oneshot timer is
# only a red unit; every exit-2 path on --restart pages, naming profile+store.

assert_structural_page() {   # <expected-substring>
  [[ "$(cat "$PAGE_LOG")" == *"codex edge mirror could NOT run"* ]]
  [[ "$(cat "$PAGE_LOG")" == *"profile \`edge\`"* ]]
  [[ "$(cat "$PAGE_LOG")" == *"$1"* ]]
}

@test "page: --restart with the edge state DB ABSENT → exit 2 + page naming the store" {
  run_mirror --restart
  [ "$status" -eq 2 ]
  assert_structural_page "target store not found: $(db_of edge)"
  [ ! -f "$RESTART_LOG" ]
}

@test "page: --restart with config_machine_state ABSENT on edge → exit 2 + page, table never created" {
  create_db edge notable
  run_mirror --restart
  [ "$status" -eq 2 ]
  assert_structural_page "has no config_machine_state table"
  run node --experimental-sqlite --no-warnings -e 'const {DatabaseSync}=require("node:sqlite");new DatabaseSync(process.argv[1]).prepare("select 1 from config_machine_state").get()' "$(db_of edge)"
  [ "$status" -ne 0 ]
}

@test "page: --restart with an UNREADABLE edge store (not a database) → exit 2 + page" {
  printf 'this is not sqlite' > "$(db_of edge)"
  run_mirror --restart
  [ "$status" -eq 2 ]
  assert_structural_page "file is not a database"
}

@test "page: --restart with garbage value_json in edge's row → exit 2 + page, row untouched" {
  create_db edge
  set_row edge authProfiles.store '{not json' 9
  run_mirror --restart
  [ "$status" -eq 2 ]
  assert_structural_page "target authProfiles.store: value_json is not JSON"
  [ "$(read_row edge authProfiles.store)" = '{not json' ]
  [ "$(row_updated_at edge authProfiles.store)" = "9" ]
}

@test "page: --restart with the SOURCE row absent / unknown runtime → exit 2 + page" {
  create_db edge
  node --experimental-sqlite --no-warnings -e 'const {DatabaseSync}=require("node:sqlite");new DatabaseSync(process.argv[1]).prepare("delete from config_machine_state where state_key=?").run("authProfiles.store")' "$(db_of main)"
  run_mirror --restart
  [ "$status" -eq 2 ]
  assert_structural_page "has no authProfiles.store row"
  rm -f "$PAGE_LOG" "$CODEX_MIRROR_STATE_DIR/codex-edge-mirror.page-cooldown"
  FAKE_OPENCLAW_VERSION="garbage" run_mirror --restart
  [ "$status" -eq 2 ]
  assert_structural_page "cannot determine the openclaw runtime version"
}

@test "page: the same structural failures WITHOUT --restart (pre-start path) page too; --check stays quiet" {
  run_mirror
  [ "$status" -eq 2 ]
  assert_structural_page "target store not found: $(db_of edge)"
  [[ "$(cat "$PAGE_LOG")" == *"mode ensure"* ]]
  rm -f "$PAGE_LOG" "$CODEX_MIRROR_STATE_DIR/codex-edge-mirror.page-cooldown"
  create_db edge notable
  run_mirror --check
  [ "$status" -eq 2 ]
  [ ! -f "$PAGE_LOG" ]
}

@test "page: deduped — a second failure inside the cooldown does not re-page; after the cooldown it does" {
  run_mirror
  [ "$status" -eq 2 ]
  [ "$(grep -c . "$PAGE_LOG")" -eq 1 ]
  run_mirror
  [ "$status" -eq 2 ]
  [[ "$output" == *"page suppressed: last page"* ]]
  [ "$(grep -c . "$PAGE_LOG")" -eq 1 ]
  printf '%s' "$(( $(date -u +%s) - 3601 ))" > "$CODEX_MIRROR_STATE_DIR/codex-edge-mirror.page-cooldown"
  run_mirror
  [ "$status" -eq 2 ]
  [ "$(grep -c . "$PAGE_LOG")" -eq 2 ]
}

@test "page outcome matrix (1/3): DELIVERED page → cooldown stamp + self-paged stamp" {
  run_mirror --restart
  [ "$status" -eq 2 ]
  [ "$(grep -c . "$PAGE_LOG")" -eq 1 ]
  [ -s "$CODEX_MIRROR_STATE_DIR/codex-edge-mirror.page-cooldown" ]
  [ -s "$HYDRA_SELF_PAGED_DIR/codex-edge-mirror.service" ]
  [ ! -d "$NOTIFY_UNIT_FAILED_MARKER_DIR" ]
}

@test "page outcome matrix (2/3): page FAILED + durably SPOOLED → self-paged stamp, NO cooldown (next run tries again)" {
  STUB_PAGE_RC=1 run_mirror --restart
  [ "$status" -eq 2 ]
  [[ "$output" == *"page NOT delivered — durable marker"* ]]
  marker="$(ls "$NOTIFY_UNIT_FAILED_MARKER_DIR"/codex-edge-mirror@edge.*.unpaged | head -1)"
  [ -s "$marker" ]
  [[ "$(basename "$marker")" =~ ^codex-edge-mirror@edge\.[0-9]+\.[0-9]+\.unpaged$ ]]   # one record per file
  [ "$(grep -c . "$marker")" -eq 1 ]
  grep -q "target store not found" "$marker"
  [ -s "$HYDRA_SELF_PAGED_DIR/codex-edge-mirror.service" ]
  [ ! -e "$CODEX_MIRROR_STATE_DIR/codex-edge-mirror.page-cooldown" ]
  STUB_PAGE_RC=1 run_mirror --restart
  [[ "$output" != *"page suppressed"* ]]
  [ "$(grep -c . "$PAGE_LOG")" -eq 2 ]
}

@test "page outcome matrix (3/3): page FAILED + spool FAILED → NO stamp, NO cooldown (handler + next run stay armed)" {
  : > "$NOTIFY_UNIT_FAILED_MARKER_DIR"          # a FILE where the spool dir should be: the marker cannot be written
  STUB_PAGE_RC=1 run_mirror --restart
  [ "$status" -eq 2 ]
  [[ "$output" == *"page NOT delivered AND the marker could not be written"*"no stamp, no cooldown"* ]]
  [ ! -e "$CODEX_MIRROR_STATE_DIR/codex-edge-mirror.page-cooldown" ]
  [ ! -e "$HYDRA_SELF_PAGED_DIR/codex-edge-mirror.service" ]
  STUB_PAGE_RC=1 run_mirror --restart
  [[ "$output" != *"page suppressed"* ]]
  [ "$(grep -c . "$PAGE_LOG")" -eq 2 ]
  run_mirror --restart                            # delivery back → stamps return
  [ -s "$CODEX_MIRROR_STATE_DIR/codex-edge-mirror.page-cooldown" ]
  [ -s "$HYDRA_SELF_PAGED_DIR/codex-edge-mirror.service" ]
}

@test "restart: plain ensure ignores the maintenance flag (the gateway is starting anyway on the ExecStartPre path)" {
  create_db edge
  printf '{"reason":"cutover","expires_epoch":%s}' "$(( $(date +%s) + 3600 ))" > "$HYDRA_MAINTENANCE_FLAG"
  run_mirror
  [ "$status" -eq 0 ]
  [ "$(edge_profile_count)" = "3" ]
}
