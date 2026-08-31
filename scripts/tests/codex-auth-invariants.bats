#!/usr/bin/env bats
# Tests for scripts/lib/codex-auth-invariants.sh — the read-only checker for
# the openclaw >= 2026.8 shared codex auth-profile store
# (config_machine_state / auth_profile_store). PATH-shadows ssh so an
# accidental remote call fails loudly (feedback_bats_must_stub_openclaw).
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
SCRIPT="$HYDRA_REPO/scripts/lib/codex-auth-invariants.sh"

# _stub_openclaw_version <version> — stub `openclaw --version` to report a
# given runtime version. Only --version is used by this checker.
_stub_openclaw_version() {
  cat > "$TEST_TMPDIR/bin/openclaw" <<STUB
#!/bin/bash
[ "\$1" = "--version" ] && echo "openclaw $1"
STUB
  chmod +x "$TEST_TMPDIR/bin/openclaw"
}

# _seed_shared_store <profile> <profiles-json>
# <profiles-json> is a jq-compatible JSON object literal for .profiles.
_seed_shared_store() {
  local profile="$1" profiles_json="$2"
  local dir="$INV_ROOT/.openclaw-$profile/state"
  mkdir -p "$dir"
  rm -f "$dir/openclaw.sqlite"
  node --experimental-sqlite --no-warnings -e "
const {DatabaseSync}=require('node:sqlite');
const db=new DatabaseSync('$dir/openclaw.sqlite');
db.exec('CREATE TABLE config_machine_state (state_key TEXT PRIMARY KEY, state_json TEXT, updated_at INTEGER)');
const store={version:1, profiles: $profiles_json};
db.prepare('insert into config_machine_state values (?,?,?)').run('authProfiles.store', JSON.stringify(store), Date.now());
"
}

# _seed_agent_store <profile> <agent> <profiles-json> — writes a per-agent
# auth_profile_store row. Pass "{}" for the healthy read-through-only case.
_seed_agent_store() {
  local profile="$1" agent="$2" profiles_json="$3"
  local dir="$INV_ROOT/.openclaw-$profile/agents/$agent/agent"
  mkdir -p "$dir"
  node --experimental-sqlite --no-warnings -e "
const {DatabaseSync}=require('node:sqlite');
const db=new DatabaseSync('$dir/openclaw-agent.sqlite');
db.exec('CREATE TABLE auth_profile_store (store_key TEXT PRIMARY KEY, store_json TEXT, updated_at INTEGER)');
db.prepare('insert into auth_profile_store values (?,?,?)').run('primary', JSON.stringify({profiles: $profiles_json}), Date.now());
"
}

setup() {
  TEST_TMPDIR="$(mktemp -d)"
  export TEST_TMPDIR
  mkdir -p "$TEST_TMPDIR/bin"

  cat > "$TEST_TMPDIR/bin/ssh" <<'STUB'
#!/bin/bash
echo "test stub: ssh call refused ($*)" >&2
exit 99
STUB
  chmod +x "$TEST_TMPDIR/bin/ssh"
  export PATH="$TEST_TMPDIR/bin:$PATH"

  INV_ROOT="$TEST_TMPDIR/root"
  export INV_ROOT
  export CODEX_AUTH_ROOT="$INV_ROOT"
  export CODEX_AUTH_PROFILES="main"
  export CODEX_EXPECTED_PROFILES_MAIN=3
  export CODEX_EXPECTED_PROFILES_EDGE=0

  _stub_openclaw_version "2026.8.1"

  mkdir -p "$INV_ROOT/.openclaw-main/agents/main/agent"
  _seed_shared_store main '{
    "openai:a@x.com":{"access":"A1","refresh":"R1","expires":1,"accountId":"1"},
    "openai:b@x.com":{"access":"A2","refresh":"R2","expires":1,"accountId":"2"},
    "openai:c@x.com":{"access":"A3","refresh":"R3","expires":1,"accountId":"3"}
  }'
}

teardown() {
  [ -n "${TEST_TMPDIR:-}" ] && rm -rf "$TEST_TMPDIR"
}

@test "not applicable on a pre-2.0 runtime — exits 0" {
  _stub_openclaw_version "2026.7.1"
  run "$SCRIPT" --check
  [ "$status" -eq 0 ]
  [[ "$output" == *"not applicable"* ]]
}

# QA bot finding (PR #897 round 2): an unidentifiable runtime is NOT the same
# fact as a positively-identified pre-2026.8 one — it must be UNEVALUATED
# (exit 2), never a silent "not applicable, exit 0".
@test "UNEVALUATED (exit 2) when the runtime cannot be determined at all" {
  cat > "$TEST_TMPDIR/bin/openclaw" <<'STUB'
#!/bin/bash
exit 1
STUB
  chmod +x "$TEST_TMPDIR/bin/openclaw"
  run "$SCRIPT" --check
  [ "$status" -eq 2 ]
  [[ "$output" == *"UNEVALUATED"* ]]
  [[ "$output" != *"not applicable"* ]]
}

@test "UNEVALUATED (exit 2) when \`openclaw --version\` emits garbage, never exit 0" {
  cat > "$TEST_TMPDIR/bin/openclaw" <<'STUB'
#!/bin/bash
[ "$1" = "--version" ] && echo "garbage not-a-version"
exit 0
STUB
  chmod +x "$TEST_TMPDIR/bin/openclaw"
  run "$SCRIPT" --check
  [ "$status" -eq 2 ]
  [[ "$output" == *"UNEVALUATED"* ]]
  [[ "$output" != *"not applicable"* ]]
}

@test "clean on a well-formed shared store with 3 openai:* profiles and no fan-out" {
  run "$SCRIPT" --check
  [ "$status" -eq 0 ]
  [[ "$output" == *"clean"* ]]
}

@test "CRITICAL when a profile key is not openai:*" {
  _seed_shared_store main '{
    "openai:a@x.com":{"access":"A1","refresh":"R1"},
    "google:b@x.com":{"access":"A2","refresh":"R2"}
  }'
  export CODEX_EXPECTED_PROFILES_MAIN=0
  run "$SCRIPT" --check
  [ "$status" -eq 1 ]
  [[ "$output" == *"non-\"openai:*\" profile key"* ]]
}

@test "CRITICAL when a pre-2.0 openai-codex:* key is still present" {
  _seed_shared_store main '{
    "openai:a@x.com":{"access":"A1","refresh":"R1"},
    "openai-codex:b@x.com":{"access":"A2","refresh":"R2"}
  }'
  export CODEX_EXPECTED_PROFILES_MAIN=0
  run "$SCRIPT" --check
  [ "$status" -eq 1 ]
  [[ "$output" == *"pre-2.0 \"openai-codex:*\" key"* ]]
}

@test "CRITICAL when a profile is missing its refresh token" {
  _seed_shared_store main '{
    "openai:a@x.com":{"access":"A1","refresh":""},
    "openai:b@x.com":{"access":"A2","refresh":"R2"},
    "openai:c@x.com":{"access":"A3","refresh":"R3"}
  }'
  run "$SCRIPT" --check
  [ "$status" -eq 1 ]
  [[ "$output" == *"missing refresh/access"* ]]
  [[ "$output" == *"a@x.com"* ]]
}

@test "CRITICAL when the shared store has no authProfiles.store row" {
  rm -f "$INV_ROOT/.openclaw-main/state/openclaw.sqlite"
  node --experimental-sqlite --no-warnings -e "
const {DatabaseSync}=require('node:sqlite');
const db=new DatabaseSync('$INV_ROOT/.openclaw-main/state/openclaw.sqlite');
db.exec('CREATE TABLE config_machine_state (state_key TEXT PRIMARY KEY, state_json TEXT, updated_at INTEGER)');
"
  run "$SCRIPT" --check
  [ "$status" -eq 1 ]
  [[ "$output" == *"has no authProfiles.store row"* ]]
}

@test "CRITICAL when main's profile count does not match CODEX_EXPECTED_PROFILES_MAIN" {
  export CODEX_EXPECTED_PROFILES_MAIN=5
  run "$SCRIPT" --check
  [ "$status" -eq 1 ]
  [[ "$output" == *"expected 5"* ]]
}

@test "CODEX_EXPECTED_PROFILES_EDGE=0 skips the edge count check" {
  export CODEX_AUTH_PROFILES="main edge"
  mkdir -p "$INV_ROOT/.openclaw-edge/agents/support/agent"
  _seed_shared_store edge '{"openai:solo@x.com":{"access":"A1","refresh":"R1"}}'
  run "$SCRIPT" --check
  [ "$status" -eq 0 ]
  [[ "$output" == *"clean"* ]]
}

@test "CRITICAL when a per-agent auth_profile_store row is non-empty (fan-out)" {
  _seed_agent_store main clio '{"openai:x@x.com":{"access":"A","refresh":"R"}}'
  run "$SCRIPT" --check
  [ "$status" -eq 1 ]
  [[ "$output" == *"fan-out"* ]]
  [[ "$output" == *"main/clio"* ]]
}

@test "clean when a per-agent auth_profile_store row is empty (read-through only)" {
  _seed_agent_store main clio '{}'
  run "$SCRIPT" --check
  [ "$status" -eq 0 ]
  [[ "$output" == *"clean"* ]]
}

@test "CRITICAL when an un-archived auth-profiles.json is present under agents/" {
  mkdir -p "$INV_ROOT/.openclaw-main/agents/clio/agent"
  echo '{}' > "$INV_ROOT/.openclaw-main/agents/clio/agent/auth-profiles.json"
  run "$SCRIPT" --check
  [ "$status" -eq 1 ]
  [[ "$output" == *"un-archived legacy auth file present"* ]]
  [[ "$output" == *"auth-profiles.json"* ]]
}

@test "CRITICAL when an un-archived codex-home/auth.json is present" {
  mkdir -p "$INV_ROOT/.openclaw-edge/agents/support/agent/codex-home"
  echo '{}' > "$INV_ROOT/.openclaw-edge/agents/support/agent/codex-home/auth.json"
  export CODEX_AUTH_PROFILES="main edge"
  _seed_shared_store edge '{"openai:solo@x.com":{"access":"A1","refresh":"R1"}}'
  run "$SCRIPT" --check
  [ "$status" -eq 1 ]
  [[ "$output" == *"codex-home/auth.json"* ]]
}

@test "archived legacy files (.migrated-* / .pre81-* suffix) are exempt" {
  mkdir -p "$INV_ROOT/.openclaw-main/agents/clio/agent"
  echo '{}' > "$INV_ROOT/.openclaw-main/agents/clio/agent/auth-profiles.json.migrated-20260830T000000Z"
  echo '{}' > "$INV_ROOT/.openclaw-main/agents/clio/agent/auth-state.json.pre81-backup"
  run "$SCRIPT" --check
  [ "$status" -eq 0 ]
  [[ "$output" == *"clean"* ]]
}

@test "UNEVALUATED (exit 2) when the shared store sqlite is unreadable" {
  echo "not a sqlite file" > "$INV_ROOT/.openclaw-main/state/openclaw.sqlite"
  run "$SCRIPT" --check
  [ "$status" -eq 2 ]
  [[ "$output" == *"UNREADABLE"* ]]
}

@test "UNEVALUATED (exit 2) when a profile's state dir is absent" {
  export CODEX_AUTH_PROFILES="main edge"
  run "$SCRIPT" --check
  [ "$status" -eq 2 ]
  [[ "$output" == *"state dir"* ]]
  [[ "$output" == *"absent"* ]]
}

@test "an unknown argument is rejected with exit 2" {
  run "$SCRIPT" --ensure
  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown argument"* ]]
}

# ── QA bot finding (PR #897, 2026-08-31): jq/parse failures must never map to
# a clean empty store. A corrupt or wrong-shaped .profiles (e.g. a string
# instead of an object) makes every `keys[]`/`to_entries[]`/`length` jq call
# below FAIL — the fix routes that failure to UNEVALUATED, never "0 findings".

@test "UNEVALUATED (exit 2), not clean, when .profiles is a string instead of an object" {
  local dir="$INV_ROOT/.openclaw-main/state"
  rm -f "$dir/openclaw.sqlite"
  node --experimental-sqlite --no-warnings -e "
const {DatabaseSync}=require('node:sqlite');
const db=new DatabaseSync('$dir/openclaw.sqlite');
db.exec('CREATE TABLE config_machine_state (state_key TEXT PRIMARY KEY, state_json TEXT, updated_at INTEGER)');
db.prepare('insert into config_machine_state values (?,?,?)').run('authProfiles.store', JSON.stringify({version:1, profiles: 'corrupt-not-an-object'}), Date.now());
"
  run "$SCRIPT" --check
  [ "$status" -eq 2 ]
  [[ "$output" == *"UNEVALUATED"* ]]
  [[ "$output" != *"CRITICAL"* ]]
  [[ "$output" == *"not an object"* ]]
}

@test "UNEVALUATED (exit 2), not clean, when a per-agent auth_profile_store row's store_json is corrupt" {
  local dir="$INV_ROOT/.openclaw-main/agents/clio/agent"
  mkdir -p "$dir"
  node --experimental-sqlite --no-warnings -e "
const {DatabaseSync}=require('node:sqlite');
const db=new DatabaseSync('$dir/openclaw-agent.sqlite');
db.exec('CREATE TABLE auth_profile_store (store_key TEXT PRIMARY KEY, store_json TEXT, updated_at INTEGER)');
db.prepare('insert into auth_profile_store values (?,?,?)').run('primary', 'not valid json {{{', Date.now());
"
  run "$SCRIPT" --check
  [ "$status" -eq 2 ]
  [[ "$output" == *"UNEVALUATED"* ]]
  [[ "$output" != *"CRITICAL"* ]]
  [[ "$output" == *"main/clio"* ]]
  [[ "$output" == *"could not be parsed"* ]]
}

# QA bot finding (PR #897 round 2, reproduced live on head 67964d43): a
# per-agent auth_profile_store row shaped `{"profiles":[]}` (a JSON ARRAY)
# has length 0, identical to a well-formed empty object — the fan-out check
# read that as clean (exit 0) instead of UNEVALUATED. Same class as the
# shared-store `.profiles` shape guard above, now extended to the per-agent
# path.
@test "UNEVALUATED (exit 2), not clean, when a per-agent store_json's .profiles is a JSON array" {
  local dir="$INV_ROOT/.openclaw-main/agents/clio/agent"
  mkdir -p "$dir"
  node --experimental-sqlite --no-warnings -e "
const {DatabaseSync}=require('node:sqlite');
const db=new DatabaseSync('$dir/openclaw-agent.sqlite');
db.exec('CREATE TABLE auth_profile_store (store_key TEXT PRIMARY KEY, store_json TEXT, updated_at INTEGER)');
db.prepare('insert into auth_profile_store values (?,?,?)').run('primary', JSON.stringify({profiles: []}), Date.now());
"
  run "$SCRIPT" --check
  [ "$status" -eq 2 ]
  [[ "$output" == *"UNEVALUATED"* ]]
  [[ "$output" != *"CRITICAL"* ]]
  [[ "$output" == *"main/clio"* ]]
  [[ "$output" == *"not an object"* ]]
}

# ── QA bot round 3: access/refresh must be non-empty STRINGS, and .profiles
# must be PRESENT (not defaulted), on both the shared cell and per-agent
# store_json ──────────────────────────────────────────────────────────────

@test "CRITICAL (not clean) when a profile's access value is a JSON array, not a string" {
  # A bare `length == 0` check does not catch this: a non-empty array has a
  # nonzero length, so without a type check this reads as "not missing".
  _seed_shared_store main '{
    "openai:a@x.com":{"access":["A1","A2"],"refresh":"R1"},
    "openai:b@x.com":{"access":"A2","refresh":"R2"},
    "openai:c@x.com":{"access":"A3","refresh":"R3"}
  }'
  run "$SCRIPT" --check
  [ "$status" -eq 1 ]
  [[ "$output" == *"missing refresh/access"* ]]
  [[ "$output" == *"a@x.com"* ]]
}

@test "CRITICAL (not clean) when a profile's refresh value is a JSON object, not a string" {
  _seed_shared_store main '{
    "openai:a@x.com":{"access":"A1","refresh":{"nested":"R1"}},
    "openai:b@x.com":{"access":"A2","refresh":"R2"},
    "openai:c@x.com":{"access":"A3","refresh":"R3"}
  }'
  run "$SCRIPT" --check
  [ "$status" -eq 1 ]
  [[ "$output" == *"missing refresh/access"* ]]
  [[ "$output" == *"a@x.com"* ]]
}

@test "UNEVALUATED (exit 2), not clean, when the shared store's authProfiles.store row has no .profiles key at all" {
  # The migration always writes {version, profiles} — an ABSENT .profiles is
  # a malformed store, not "just empty". The old `// {}` default made this
  # indistinguishable from a genuinely-present empty object and read it as
  # clean (0 profiles, no bad keys, nothing missing).
  local dir="$INV_ROOT/.openclaw-main/state"
  rm -f "$dir/openclaw.sqlite"
  node --experimental-sqlite --no-warnings -e "
const {DatabaseSync}=require('node:sqlite');
const db=new DatabaseSync('$dir/openclaw.sqlite');
db.exec('CREATE TABLE config_machine_state (state_key TEXT PRIMARY KEY, state_json TEXT, updated_at INTEGER)');
db.prepare('insert into config_machine_state values (?,?,?)').run('authProfiles.store', JSON.stringify({version:1}), Date.now());
"
  run "$SCRIPT" --check
  [ "$status" -eq 2 ]
  [[ "$output" == *"UNEVALUATED"* ]]
  [[ "$output" != *"CRITICAL"* ]]
  [[ "$output" == *"absent or not an object"* ]]
}

@test "UNEVALUATED (exit 2), not clean, when a per-agent store_json has no .profiles key at all" {
  local dir="$INV_ROOT/.openclaw-main/agents/clio/agent"
  mkdir -p "$dir"
  node --experimental-sqlite --no-warnings -e "
const {DatabaseSync}=require('node:sqlite');
const db=new DatabaseSync('$dir/openclaw-agent.sqlite');
db.exec('CREATE TABLE auth_profile_store (store_key TEXT PRIMARY KEY, store_json TEXT, updated_at INTEGER)');
db.prepare('insert into auth_profile_store values (?,?,?)').run('primary', JSON.stringify({unrelated: true}), Date.now());
"
  run "$SCRIPT" --check
  [ "$status" -eq 2 ]
  [[ "$output" == *"UNEVALUATED"* ]]
  [[ "$output" != *"CRITICAL"* ]]
  [[ "$output" == *"main/clio"* ]]
  [[ "$output" == *"absent or not an object"* ]]
}

@test "UNEVALUATED (exit 2), not clean, when CODEX_EXPECTED_PROFILES_MAIN is garbage, never a silent skip" {
  # QA bot finding (PR #897 round 4): `[ "$expected" -gt 0 ] 2>/dev/null` used
  # to swallow the numeric-comparison error a non-numeric value produces, so
  # the profile-count invariant silently disabled itself and the run still
  # exited 0 clean — even though the store's 3 profiles genuinely match the
  # sane default, a garbage config value must never be read as "0, skip".
  export CODEX_EXPECTED_PROFILES_MAIN="three"
  run "$SCRIPT" --check
  [ "$status" -eq 2 ]
  [[ "$output" == *"ERROR"* ]]
  [[ "$output" != *"CRITICAL"* ]]
  [[ "$output" == *"CODEX_EXPECTED_PROFILES_MAIN"* ]]
  [[ "$output" == *"three"* ]]
}
