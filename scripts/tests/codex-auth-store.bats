#!/usr/bin/env bats
# Tests for the read-only Codex auth-store adapter shared by reporting and
# quota measurement. Fixtures are isolated under CAS_ROOT and contain dummy
# credentials only.
bats_require_minimum_version 1.5.0

setup() {
  LIB="${BATS_TEST_DIRNAME}/../lib/codex-auth-store.sh"
  TEST_TMPDIR="$(mktemp -d)"
  export TEST_TMPDIR
  export CAS_ROOT="$TEST_TMPDIR/root"
  mkdir -p "$CAS_ROOT/.openclaw-main/agents/main/agent" \
           "$CAS_ROOT/.openclaw-main/state"
  # shellcheck disable=SC1090
  source "$LIB"
}

teardown() { rm -rf "$TEST_TMPDIR"; }

write_legacy() {
  local path="$1"
  cat > "$path" <<'JSON'
{"profiles":{
  "openai-codex:a@example.com":{"email":"a@example.com","chatgptPlanType":"pro","access":"ACCESS-SECRET","refresh":"REFRESH-SECRET","accountId":"acct-a","expires":123},
  "anthropic:b@example.com":{"email":"b@example.com"}
}}
JSON
}

make_sqlite() {
  local store_json="${1:-}"
  local state_json="${2:-}"
  local location="${3:-state-db}"
  local db="$CAS_ROOT/.openclaw-main/state/openclaw.sqlite"
  CAS_FIXTURE_STORE="$store_json" CAS_FIXTURE_STATE="$state_json" CAS_FIXTURE_LOCATION="$location" \
    node --experimental-sqlite --no-warnings -e '
const {DatabaseSync}=require("node:sqlite");
const db=new DatabaseSync(process.argv[1]);
db.exec("CREATE TABLE config_machine_state(state_key TEXT PRIMARY KEY,value_json TEXT NOT NULL,updated_at_ms INTEGER NOT NULL)");
const put=db.prepare("INSERT INTO config_machine_state VALUES(?,?,?)");
put.run("auth.sharedStore",JSON.stringify({location:process.env.CAS_FIXTURE_LOCATION}),Date.now());
if(process.env.CAS_FIXTURE_STORE) put.run("authProfiles.store",process.env.CAS_FIXTURE_STORE,Date.now());
if(process.env.CAS_FIXTURE_STATE) put.run("authProfiles.state",process.env.CAS_FIXTURE_STATE,Date.now());
' "$db"
}

make_agent_sqlite() {
  local store_json="$1"
  local state_json="${2:-}"
  local db="$CAS_ROOT/.openclaw-main/agents/main/agent/openclaw-agent.sqlite"
  CAS_FIXTURE_STORE="$store_json" CAS_FIXTURE_STATE="$state_json" \
    node --experimental-sqlite --no-warnings -e '
const {DatabaseSync}=require("node:sqlite");
const db=new DatabaseSync(process.argv[1]);
db.exec("CREATE TABLE auth_profile_store(store_key TEXT PRIMARY KEY,store_json TEXT NOT NULL,updated_at INTEGER NOT NULL)");
db.exec("CREATE TABLE auth_profile_state(state_key TEXT PRIMARY KEY,state_json TEXT NOT NULL,updated_at INTEGER NOT NULL)");
db.prepare("INSERT INTO auth_profile_store VALUES(?,?,?)").run("primary",process.env.CAS_FIXTURE_STORE,Date.now());
if(process.env.CAS_FIXTURE_STATE) db.prepare("INSERT INTO auth_profile_state VALUES(?,?,?)").run("primary",process.env.CAS_FIXTURE_STATE,Date.now());
' "$db"
}

@test "explicit legacy store is honoured and non-Codex profiles are filtered" {
  local legacy="$TEST_TMPDIR/auth-profiles.json"
  write_legacy "$legacy"
  export CAS_LEGACY_JSON="$legacy"
  run cas_profiles_redacted main
  [ "$status" -eq 0 ]
  [ "$(jq -r '.profiles | keys | join(",")' <<<"$output")" = "openai-codex:a@example.com" ]
}

@test "redacted enumeration never emits credential fields" {
  local legacy="$TEST_TMPDIR/auth-profiles.json"
  write_legacy "$legacy"
  export CAS_LEGACY_JSON="$legacy"
  run cas_profiles_redacted main
  [ "$status" -eq 0 ]
  [[ "$output" != *"ACCESS-SECRET"* ]]
  [[ "$output" != *"REFRESH-SECRET"* ]]
  [[ "$output" != *"accountId"* ]]
}

@test "explicit missing legacy store stays isolated and never falls through to SQLite" {
  make_sqlite '{"profiles":{"openai:live@example.com":{"email":"live@example.com"}}}'
  export CAS_LEGACY_JSON="$TEST_TMPDIR/absent.json"
  run cas_profiles_redacted main
  [ "$status" -eq 0 ]
  [ "$(jq -r '.profiles | length' <<<"$output")" -eq 0 ]
}

@test "an absent explicit legacy store is not available to the quota probe" {
  export CAS_LEGACY_JSON="$TEST_TMPDIR/absent.json"
  run cas_store_available main
  [ "$status" -ne 0 ]
}

@test "explicit malformed legacy store fails loud and never falls through to SQLite" {
  make_sqlite '{"profiles":{"openai:live@example.com":{"email":"live@example.com"}}}'
  local legacy="$TEST_TMPDIR/auth-profiles.json"
  printf '%s' '{ malformed' > "$legacy"
  export CAS_LEGACY_JSON="$legacy"
  run cas_profiles_redacted main
  [ "$status" -eq 3 ]
  [ -z "$output" ]
}

@test "SQLite store translates openai ids and projects only account metadata" {
  make_sqlite \
    '{"version":1,"profiles":{"openai:a@example.com":{"provider":"openai","type":"oauth","email":"a@example.com","chatgptPlanType":"pro","access":"ACCESS-SECRET","refresh":"REFRESH-SECRET","accountId":"acct-a","expires":123},"openai:b@example.com":{"provider":"openai","type":"oauth","email":"b@example.com","chatgptPlanType":"plus"}}}' \
    '{"version":1,"lastGood":{"openai":"openai:b@example.com"}}'
  run cas_profiles_redacted main
  [ "$status" -eq 0 ]
  [ "$(jq -r '.profiles | keys | join(",")' <<<"$output")" = "openai-codex:a@example.com,openai-codex:b@example.com" ]
  [[ "$output" != *"ACCESS-SECRET"* ]]
  [[ "$output" != *"REFRESH-SECRET"* ]]
  [[ "$output" != *"accountId"* ]]
}

@test "SQLite enumeration excludes non-OAuth OpenAI profiles" {
  make_sqlite '{"profiles":{"openai:oauth@example.com":{"provider":"openai","type":"oauth","email":"oauth@example.com"},"openai:api@example.com":{"provider":"openai","type":"api_key","email":"api@example.com"}}}'
  run cas_profiles_redacted main
  [ "$status" -eq 0 ]
  [ "$(jq -r '.profiles | keys | join(",")' <<<"$output")" = "openai-codex:oauth@example.com" ]
}

@test "SQLite field lookup excludes non-OAuth OpenAI profiles" {
  make_sqlite '{"profiles":{"openai:api@example.com":{"provider":"openai","type":"api_key","access":"API-SECRET","accountId":"acct-api","expires":9999999999999}}}'
  run cas_profile_field main openai-codex:api@example.com access
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "legacy-main ownership reads the main agent SQLite store" {
  make_sqlite "" "" legacy-main
  make_agent_sqlite \
    '{"profiles":{"openai:a@example.com":{"provider":"openai","type":"oauth","email":"a@example.com","access":"ACCESS-SECRET"}}}' \
    '{"lastGood":{"openai":"openai:a@example.com"}}'
  run cas_profiles_redacted main
  [ "$status" -eq 0 ]
  [ "$(jq -r '.profiles | keys | join(",")' <<<"$output")" = "openai-codex:a@example.com" ]
  [[ "$output" != *"ACCESS-SECRET"* ]]
  run cas_active_key main
  [ "$status" -eq 0 ]
  [ "$output" = "openai-codex:a@example.com" ]
}

@test "SQLite active state is translated to the canonical namespace" {
  make_sqlite \
    '{"profiles":{"openai:a@example.com":{"email":"a@example.com"}}}' \
    '{"lastGood":{"openai":"openai:a@example.com"}}'
  run cas_active_key main
  [ "$status" -eq 0 ]
  [ "$output" = "openai-codex:a@example.com" ]
}

@test "SQLite field lookup translates the key without putting the store on disk" {
  make_sqlite '{"profiles":{"openai:a@example.com":{"provider":"openai","type":"oauth","access":"ACCESS-SECRET","accountId":"acct-a","expires":123}}}'
  run cas_profile_field main openai-codex:a@example.com accountId
  [ "$status" -eq 0 ]
  [ "$output" = "acct-a" ]
  run cas_profile_field main openai-codex:a@example.com expires
  [ "$status" -eq 0 ]
  [ "$output" = "123" ]
}

@test "malformed SQLite store fails loud" {
  make_sqlite '{ malformed'
  run cas_profiles_redacted main
  [ "$status" -eq 3 ]
  [ -z "$output" ]
}
