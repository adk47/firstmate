#!/usr/bin/env bash
# Read the canonical Codex auth profile store without writing or exposing the
# complete credential payload. OpenClaw 2026.8 moved the shared store from
# agents/main/agent/auth-profiles.json into state/openclaw.sqlite and renamed
# profile ids from openai-codex:<email> to openai:<email>.

cas_legacy_json_path() {
  if [ "${CAS_LEGACY_JSON+x}" = x ]; then
    printf '%s' "$CAS_LEGACY_JSON"
  else
    printf '%s/.openclaw-%s/agents/main/agent/auth-profiles.json' \
      "${CAS_ROOT:-/root}" "${1:-main}"
  fi
}

cas_legacy_state_path() {
  if [ "${CAS_LEGACY_STATE+x}" = x ]; then
    printf '%s' "$CAS_LEGACY_STATE"
  else
    printf '%s/.openclaw-%s/agents/main/agent/auth-state.json' \
      "${CAS_ROOT:-/root}" "${1:-main}"
  fi
}

cas_sqlite_path() {
  if [ "${CAS_SQLITE_PATH+x}" = x ]; then
    printf '%s' "$CAS_SQLITE_PATH"
  else
    printf '%s/.openclaw-%s/state/openclaw.sqlite' \
      "${CAS_ROOT:-/root}" "${1:-main}"
  fi
}

cas_agent_sqlite_path() {
  if [ "${CAS_AGENT_SQLITE_PATH+x}" = x ]; then
    printf '%s' "$CAS_AGENT_SQLITE_PATH"
  else
    printf '%s/.openclaw-%s/agents/main/agent/openclaw-agent.sqlite' \
      "${CAS_ROOT:-/root}" "${1:-main}"
  fi
}

# _cas_sqlite <command> <db> [profile-key] [field] [shared|agent]
# Exit 4 means the database/table/row is absent; 3 means it exists but is
# unreadable or malformed. `profiles` emits only id/email/plan metadata.
_cas_sqlite() {
  local command="$1" db="$2" key="${3:-}" field="${4:-}" backend="${5:-shared}"
  command -v node >/dev/null 2>&1 || return 3
  CAS_COMMAND="$command" CAS_DB_PATH="$db" CAS_PROFILE_KEY="$key" \
    CAS_PROFILE_FIELD="$field" CAS_SQLITE_BACKEND="$backend" \
    node --experimental-sqlite --no-warnings -e '
const fs=require("fs");
const {DatabaseSync}=require("node:sqlite");
const command=process.env.CAS_COMMAND;
const path=process.env.CAS_DB_PATH;
const backend=process.env.CAS_SQLITE_BACKEND;
if(!fs.existsSync(path)) process.exit(4);
let db;
try { db=new DatabaseSync(path,{readOnly:true}); }
catch { process.exit(3); }
function readCell(key) {
  let row;
  try {
    if(backend==="agent") {
      row=key==="authProfiles.store"
        ? db.prepare("SELECT store_json AS value_json FROM auth_profile_store WHERE store_key=?").get("primary")
        : db.prepare("SELECT state_json AS value_json FROM auth_profile_state WHERE state_key=?").get("primary");
    } else {
      row=db.prepare("SELECT value_json FROM config_machine_state WHERE state_key=?").get(key);
    }
  } catch (error) {
    if(/no such table/i.test(String(error && error.message))) process.exit(4);
    process.exit(3);
  }
  if(!row || typeof row.value_json!=="string") process.exit(4);
  try { return JSON.parse(row.value_json); }
  catch { process.exit(3); }
}
function isCodexOAuthProfile(id,profile) {
  if(!profile || typeof profile!=="object" || Array.isArray(profile)) return false;
  if(id.startsWith("openai:")) return profile.provider==="openai" && profile.type==="oauth";
  if(!id.startsWith("openai-codex:")) return false;
  if(profile.type && profile.type!=="oauth") return false;
  return !profile.provider || profile.provider==="openai" || profile.provider==="openai-codex";
}
if(command==="ownership") {
  if(backend!=="shared") process.exit(3);
  const value=readCell("auth.sharedStore");
  if(!value || (value.location!=="state-db" && value.location!=="legacy-main")) process.exit(3);
  process.stdout.write(value.location);
} else if(command==="profiles") {
  const store=readCell("authProfiles.store");
  if(!store || !store.profiles || Array.isArray(store.profiles) || typeof store.profiles!=="object") process.exit(3);
  const profiles={};
  for(const [id,value] of Object.entries(store.profiles)) {
    const profile=value && typeof value==="object" ? value : {};
    let canonical;
    if(id.startsWith("openai:")) {
      if(!isCodexOAuthProfile(id,profile)) continue;
      canonical="openai-codex:"+id.slice(7);
    } else if(id.startsWith("openai-codex:")) {
      if(!isCodexOAuthProfile(id,profile)) continue;
      canonical=id;
    } else continue;
    profiles[canonical]={
      email: typeof profile.email==="string" ? profile.email : "",
      chatgptPlanType: typeof profile.chatgptPlanType==="string" ? profile.chatgptPlanType : ""
    };
  }
  process.stdout.write(JSON.stringify({profiles}));
} else if(command==="active") {
  const state=readCell("authProfiles.state");
  const value=state && state.lastGood && (state.lastGood.openai || state.lastGood["openai-codex"]);
  if(typeof value!=="string") process.exit(4);
  if(value.startsWith("openai:")) process.stdout.write("openai-codex:"+value.slice(7));
  else if(value.startsWith("openai-codex:")) process.stdout.write(value);
  else process.exit(4);
} else if(command==="field") {
  const allowed=new Set(["access","refresh","expires","accountId","email","chatgptPlanType"]);
  const field=process.env.CAS_PROFILE_FIELD;
  if(!allowed.has(field)) process.exit(3);
  const store=readCell("authProfiles.store");
  if(!store || !store.profiles || Array.isArray(store.profiles) || typeof store.profiles!=="object") process.exit(3);
  const canonical=process.env.CAS_PROFILE_KEY || "";
  if(!canonical.startsWith("openai-codex:")) process.exit(3);
  const translated="openai:"+canonical.slice(13);
  const id=Object.prototype.hasOwnProperty.call(store.profiles,translated) ? translated : canonical;
  const profile=store.profiles[id];
  if(!isCodexOAuthProfile(id,profile)) process.exit(0);
  const value=profile && profile[field];
  if(value!==undefined && value!==null) process.stdout.write(String(value));
} else {
  process.exit(3);
}
' 2>/dev/null
}

# cas_source_kind [profile] — `legacy`, `agent-sqlite`, or `sqlite`.
# An explicit CAS_LEGACY_JSON is a strict isolation boundary: never fall
# through to the host SQLite when a fixture/caller-selected file is absent or
# malformed.
cas_source_kind() {
  local profile="${1:-main}" db agent_db ownership rc
  if [ "${CAS_LEGACY_JSON+x}" = x ]; then
    printf 'legacy'
    return 0
  fi
  db="$(cas_sqlite_path "$profile")"
  agent_db="$(cas_agent_sqlite_path "$profile")"
  if [ -e "$db" ]; then
    ownership="$(_cas_sqlite ownership "$db")"; rc=$?
    if [ "$rc" -eq 0 ]; then
      case "$ownership" in
        state-db) printf 'sqlite'; return 0 ;;
        legacy-main)
          _cas_sqlite profiles "$agent_db" "" "" agent >/dev/null || return 3
          printf 'agent-sqlite'; return 0
          ;;
        *) return 3 ;;
      esac
    fi
    if [ "$rc" -eq 3 ]; then return 3; fi
    # Compatibility for early SQLite stores that predate the ownership cell:
    # the main agent database remains authoritative until shared state owns it.
    _cas_sqlite profiles "$agent_db" "" "" agent >/dev/null; rc=$?
    [ "$rc" -eq 0 ] && { printf 'agent-sqlite'; return 0; }
    [ "$rc" -eq 3 ] && return 3
    if [ -r "$(cas_legacy_json_path "$profile")" ]; then
      printf 'legacy'; return 0
    fi
    _cas_sqlite profiles "$db" >/dev/null; rc=$?
    [ "$rc" -eq 0 ] && { printf 'sqlite'; return 0; }
    [ "$rc" -eq 4 ] && { printf 'legacy'; return 0; }
    return 3
  fi
  _cas_sqlite profiles "$agent_db" "" "" agent >/dev/null; rc=$?
  [ "$rc" -eq 0 ] && { printf 'agent-sqlite'; return 0; }
  [ "$rc" -eq 3 ] && return 3
  printf 'legacy'
}

cas_profiles_redacted() {
  local profile="${1:-main}" source legacy db backend
  source="$(cas_source_kind "$profile")" || return 3
  if [ "$source" != legacy ]; then
    if [ "$source" = sqlite ]; then db="$(cas_sqlite_path "$profile")"; backend=shared
    else db="$(cas_agent_sqlite_path "$profile")"; backend=agent; fi
    _cas_sqlite profiles "$db" "" "" "$backend" || return 3
    return 0
  fi
  legacy="$(cas_legacy_json_path "$profile")"
  [ -e "$legacy" ] || { printf '{"profiles":{}}'; return 0; }
  [ -r "$legacy" ] && [ -f "$legacy" ] || return 3
  jq -ce '
    if ((.profiles // null) | type) != "object" then error("profiles must be an object")
    else {profiles: (.profiles | with_entries(
      select(.key | startswith("openai-codex:"))
      | {key:.key,value:{email:(.value.email // ""),chatgptPlanType:(.value.chatgptPlanType // "")}}
    ))} end
  ' "$legacy" 2>/dev/null || return 3
}

cas_active_key() {
  local profile="${1:-main}" source state db value backend
  source="$(cas_source_kind "$profile")" || return 3
  if [ "$source" != legacy ]; then
    if [ "$source" = sqlite ]; then db="$(cas_sqlite_path "$profile")"; backend=shared
    else db="$(cas_agent_sqlite_path "$profile")"; backend=agent; fi
    _cas_sqlite active "$db" "" "" "$backend"; return $?
  fi
  state="$(cas_legacy_state_path "$profile")"
  [ -e "$state" ] || return 0
  [ -r "$state" ] && [ -f "$state" ] || return 3
  value="$(jq -er '.lastGood["openai-codex"] // empty' "$state" 2>/dev/null)" || {
    [ "$?" -eq 4 ] && return 0
    return 3
  }
  printf '%s' "$value"
}

cas_profile_field() {
  local profile="${1:-main}" key="$2" field="$3" source legacy db backend
  source="$(cas_source_kind "$profile")" || return 3
  if [ "$source" != legacy ]; then
    if [ "$source" = sqlite ]; then db="$(cas_sqlite_path "$profile")"; backend=shared
    else db="$(cas_agent_sqlite_path "$profile")"; backend=agent; fi
    _cas_sqlite field "$db" "$key" "$field" "$backend"; return $?
  fi
  legacy="$(cas_legacy_json_path "$profile")"
  [ -e "$legacy" ] || return 0
  [ -r "$legacy" ] && [ -f "$legacy" ] || return 3
  jq -er --arg key "$key" --arg field "$field" '
    if ((.profiles // null) | type) != "object" then error("profiles must be an object")
    else (.profiles[$key][$field] // empty) | tostring end
  ' "$legacy" 2>/dev/null
  case "$?" in 0) return 0 ;; 4) return 0 ;; *) return 3 ;; esac
}

cas_list_canonical_keys() {
  local payload
  payload="$(cas_profiles_redacted "${1:-main}")" || return 3
  printf '%s' "$payload" | jq -er '.profiles | keys[]' 2>/dev/null
  case "$?" in 0) return 0 ;; 4) return 0 ;; *) return 3 ;; esac
}

cas_store_available() {
  local profile="${1:-main}" source legacy
  source="$(cas_source_kind "$profile")" || return 3
  if [ "$source" = legacy ]; then
    legacy="$(cas_legacy_json_path "$profile")"
    [ -r "$legacy" ] && [ -f "$legacy" ] || return 4
  fi
  cas_profiles_redacted "$profile" >/dev/null
}
