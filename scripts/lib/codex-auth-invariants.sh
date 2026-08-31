#!/usr/bin/env bash
# codex-auth-invariants.sh — read-only checker for the openclaw >= 2026.8
# shared codex (ChatGPT OAuth) auth-profile store. Staging-verified on node-8
# against a real 2026.8.1 install (2026-08-31).
#
# ── Why this exists (2.0's auth surface, distinct from 7.x) ──────────────────
# 7.x's per-agent codex-auth-sync.sh fabric (main-agent sqlite row +
# codex-home/auth.json per agent) is INERT on 2.0: the runtime moved shared
# auth into ONE machine-wide store —
#   <state-dir>/state/openclaw.sqlite, table config_machine_state,
#   row state_key='authProfiles.store' (JSON: {version, profiles:{
#     "openai:<email>": {access, refresh, expires, accountId, ...}}})
#   and a sibling row state_key='authProfiles.state'.
# Per-agent stores (agents/<id>/agent/openclaw-agent.sqlite, table
# auth_profile_store) become pure READ-THROUGH inheritance: a non-empty
# profiles map there is the SAME class of bug 7.x's fan-out was (independent
# copies of a single-use rotating refresh token mutually invalidate each
# other — see ensure-codex-auth.sh / codex-auth-sync.sh history). Legacy
# per-agent files (auth-profiles.json, auth-state.json, codex-home/auth.json)
# must not exist un-archived either — the migration is supposed to have
# retired them (archived forms keep a `.migrated-*` or `.pre81-*` suffix and
# are exempt; that suffix is what makes them archived, not live).
#
# ── Modes ─────────────────────────────────────────────────────────────────
# --check is the default AND only mode (this is a read-only checker, unlike
# the ensure-*.sh healers — there is no convergent fix to apply here: only
# codex-auth-sync's 2.0 successor, or a human, writes this store). Exit-code
# convention matches the repo's other guards:
#   0  clean (or: not applicable — see below)
#   1  a violation was CONFIRMED
#   2  something could not be evaluated (unreadable store, missing node/jq)
#
# ── Runtime gate ──────────────────────────────────────────────────────────
# On a runtime below 2026.8 (or unidentified) this script is INERT: it prints
# a "not applicable" line and exits 0. The 2.0 auth surfaces this script reads
# do not exist below 2026.8, so running the checks there would be a false
# positive, not a stricter one.
#
# ── Env overrides (used by scripts/tests/codex-auth-invariants.bats) ────────
#   CODEX_AUTH_ROOT              sandbox root (default /root)
#   CODEX_AUTH_PROFILES          space-separated profiles (default "main edge")
#   CODEX_EXPECTED_PROFILES_MAIN expected profile count for main (default 3)
#   CODEX_EXPECTED_PROFILES_EDGE expected profile count for edge (default 0,
#                                 meaning "skip the count check" — arm this
#                                 once Option B logins land on edge)
#   NODE_BIN                     node binary (default: node on PATH)
#   `openclaw` is resolved from PATH so tests can stub --version.
#
# set -uo pipefail (NOT -e): a --check run must always reach its own exit
# code, never abort mid-collection on a single profile's failure.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=version-compare.sh
source "$SCRIPT_DIR/version-compare.sh"

CODEX_AUTH_ROOT="${CODEX_AUTH_ROOT:-/root}"
CODEX_AUTH_PROFILES="${CODEX_AUTH_PROFILES:-main edge}"
CODEX_EXPECTED_PROFILES_MAIN="${CODEX_EXPECTED_PROFILES_MAIN:-3}"
CODEX_EXPECTED_PROFILES_EDGE="${CODEX_EXPECTED_PROFILES_EDGE:-0}"
NODE_BIN="${NODE_BIN:-node}"
RUNTIME_FLOOR="2026.8"

LOGPREFIX="[codex-auth-invariants $(date -u +%Y-%m-%dT%H:%M:%SZ)]"
log() { echo "$LOGPREFIX $*" >&2; }

# QA bot finding (PR #897 round 4): a non-numeric CODEX_EXPECTED_PROFILES_*
# (e.g. "three") used to make `[ "$expected" -gt 0 ]`'s numeric comparison
# ERROR, and that error was swallowed by `2>/dev/null` — the `if` then reads
# a bash comparison error identically to "expected is 0", silently SKIPPING
# the whole profile-count invariant instead of failing loud. Validate each
# value up front as a non-negative integer; a malformed one is UNEVALUATED,
# never a silent disable.
for _expected_profiles_var in CODEX_EXPECTED_PROFILES_MAIN CODEX_EXPECTED_PROFILES_EDGE; do
  _expected_profiles_val="${!_expected_profiles_var}"
  if ! [[ "$_expected_profiles_val" =~ ^[0-9]+$ ]]; then
    log "ERROR: $_expected_profiles_var=\"$_expected_profiles_val\" is not a non-negative integer — refusing to silently disable the profile-count invariant"
    exit 2
  fi
done
unset _expected_profiles_var _expected_profiles_val

case "${1:-}" in
  ""|--check) ;;
  -h|--help) sed -n '2,60p' "$0"; exit 0 ;;
  *) log "ERROR: unknown argument: $1 (this checker only supports --check / no args)"; exit 2 ;;
esac

command -v jq >/dev/null 2>&1 || { log "ERROR: jq not found"; exit 2; }
command -v "$NODE_BIN" >/dev/null 2>&1 || { log "ERROR: node not found (needed for node:sqlite)"; exit 2; }

runtime_ver="$(openclaw_runtime_version)"
# QA bot finding (PR #897 round 2): a POSITIVELY-identified pre-2026.8
# runtime (checks genuinely do not apply there) is a different fact from an
# empty/garbage `openclaw --version` (we don't know WHAT applies). Conflating
# them into one "not applicable, exit 0" line hid an unevaluated host behind
# a clean exit code. Split: only a version string that actually parses as
# below the floor is "not applicable" — anything unparseable is UNEVALUATED.
if [ -z "$runtime_ver" ] || ! [[ "$runtime_ver" =~ ^[0-9]{4}(\.[0-9]+)+$ ]]; then
  log "UNEVALUATED: could not determine openclaw runtime version (\`openclaw --version\` returned nothing/unparseable: '${runtime_ver:-}') — cannot verify whether the 2026.8+ auth-profile-store checks apply to this host"
  exit 2
fi
if ! version_at_least "$RUNTIME_FLOOR" "$runtime_ver"; then
  log "not applicable on $runtime_ver (this checker targets openclaw >= $RUNTIME_FLOOR) — nothing to verify"
  exit 0
fi

# ── node:sqlite helper ───────────────────────────────────────────────────────
# Subcommand: `read_state <sqlitePath> <stateKey>` — prints the state_json
# column for that row, or nothing if the row/table/db is absent. Distinguishes
# "absent" (exit 0, empty stdout) from a REAL read error (locked/corrupt file
# → exit 3), same contract as codex-auth-sync.sh's `read` subcommand, so a
# --check run never mistakes an unreadable store for a clean one.
NODE_HELPER='
const {DatabaseSync}=require("node:sqlite");
const fs=require("fs");
const [cmd, dbPath, key] = process.argv.slice(1);
if (cmd === "read_state") {
  if (!fs.existsSync(dbPath)) process.exit(0);
  try {
    const db = new DatabaseSync(dbPath, {readOnly: true});
    let r;
    try {
      r = db.prepare("select state_json from config_machine_state where state_key=?").get(key);
    } catch (e) {
      if (/no such table/i.test(String(e.message))) process.exit(0);
      throw e;
    }
    if (r) process.stdout.write(r.state_json);
  } catch (e) { console.error(String(e.message)); process.exit(3); }
} else if (cmd === "read_agent_store") {
  if (!fs.existsSync(dbPath)) process.exit(0);
  try {
    const db = new DatabaseSync(dbPath, {readOnly: true});
    let r;
    try {
      r = db.prepare("select store_json from auth_profile_store where store_key=?").get("primary");
    } catch (e) {
      if (/no such table/i.test(String(e.message))) process.exit(0);
      throw e;
    }
    if (r) process.stdout.write(r.store_json);
  } catch (e) { console.error(String(e.message)); process.exit(3); }
} else { process.exit(2); }
'
sqlite_helper() { "$NODE_BIN" --experimental-sqlite --no-warnings -e "$NODE_HELPER" "$@" 2>/dev/null; }

# ── collectors ────────────────────────────────────────────────────────────

# _check_shared_store <profile> — emits "SEV\tmsg" lines on stdout, one per
# finding, for the machine-wide authProfiles.store row of one profile.
_check_shared_store() {
  local profile="$1" state_dir sqlite rc row expected
  state_dir="$CODEX_AUTH_ROOT/.openclaw-$profile"
  sqlite="$state_dir/state/openclaw.sqlite"

  if [ ! -d "$state_dir" ]; then
    printf 'UNEVALUATED\tprofile %s: state dir %s absent\n' "$profile" "$state_dir"
    return
  fi

  rc=0
  row="$(sqlite_helper read_state "$sqlite" "authProfiles.store")" || rc=$?
  if [ "$rc" -ne 0 ]; then
    printf 'UNEVALUATED\tprofile %s: %s UNREADABLE (cannot verify authProfiles.store — locked/corrupt?)\n' "$profile" "$sqlite"
    return
  fi
  if [ -z "$row" ]; then
    printf 'CRITICAL\tprofile %s: %s has no authProfiles.store row — shared codex auth is MISSING\n' "$profile" "$sqlite"
    return
  fi
  if ! printf '%s' "$row" | jq -e . >/dev/null 2>&1; then
    printf 'CRITICAL\tprofile %s: authProfiles.store in %s is not valid JSON\n' "$profile" "$sqlite"
    return
  fi

  # .profiles must be PRESENT as an object — the migration always writes
  # {version, profiles}, so an absent .profiles is a malformed store, not
  # "just empty". QA bot finding (PR #897 round 3): the earlier `// {}`
  # default made an absent .profiles indistinguishable from a genuinely
  # empty (but present) one, silently reading a malformed store as clean.
  # A wrong shape here (string/array/number) also makes `keys[]` /
  # `to_entries[]` jq calls FAIL below — treating that failure's empty
  # stdout as "no bad keys found" would read a corrupt/wrong-shaped store as
  # clean. Fail this profile's shape checks as UNEVALUATED instead of
  # guessing either way.
  if ! printf '%s' "$row" | jq -e 'has("profiles") and (.profiles | type == "object")' >/dev/null 2>&1; then
    printf 'UNEVALUATED\tprofile %s: authProfiles.store .profiles in %s is absent or not an object — cannot verify shape\n' \
      "$profile" "$sqlite"
    return
  fi

  # Non-openai:* profile keys (unexpected shape) and any lingering
  # openai-codex:* key (the pre-2.0 namespace — its presence here means the
  # migration did not complete, or something wrote the old key back).
  local bad_keys jq_rc
  bad_keys="$(printf '%s' "$row" | jq -r '(.profiles // {}) | keys[] | select(startswith("openai:") | not)')"
  jq_rc=$?
  if [ "$jq_rc" -ne 0 ]; then
    printf 'UNEVALUATED\tprofile %s: authProfiles.store in %s could not be parsed for profile-key checks (jq exit %s)\n' \
      "$profile" "$sqlite" "$jq_rc"
    return
  fi
  if [ -n "$bad_keys" ]; then
    printf 'CRITICAL\tprofile %s: authProfiles.store has non-"openai:*" profile key(s): %s\n' \
      "$profile" "$(printf '%s' "$bad_keys" | tr '\n' ' ')"
  fi
  local codex_keys
  codex_keys="$(printf '%s' "$row" | jq -r '(.profiles // {}) | keys[] | select(startswith("openai-codex:"))')"
  jq_rc=$?
  if [ "$jq_rc" -ne 0 ]; then
    printf 'UNEVALUATED\tprofile %s: authProfiles.store in %s could not be parsed for legacy-key checks (jq exit %s)\n' \
      "$profile" "$sqlite" "$jq_rc"
    return
  fi
  if [ -n "$codex_keys" ]; then
    printf 'CRITICAL\tprofile %s: authProfiles.store still carries pre-2.0 "openai-codex:*" key(s): %s\n' \
      "$profile" "$(printf '%s' "$codex_keys" | tr '\n' ' ')"
  fi

  # Every profile needs refresh + access to be NON-EMPTY STRINGS. QA bot
  # finding (PR #897 round 3): a bare `length == 0` check reads TYPE too
  # loosely — `"access": ["a","b"]` (an array) has length 2, so it silently
  # passes as "not missing" even though it is not the string the caller
  # expects. `type != "string"` is a distinct malformed shape from "empty",
  # and both must be caught here.
  local incomplete
  incomplete="$(printf '%s' "$row" | jq -r '
    (.profiles // {}) | to_entries[]
    | select(
        ((.value.refresh // "") | type != "string") or ((.value.refresh // "") | length == 0)
        or ((.value.access // "") | type != "string") or ((.value.access // "") | length == 0)
      )
    | .key')"
  jq_rc=$?
  if [ "$jq_rc" -ne 0 ]; then
    printf 'UNEVALUATED\tprofile %s: authProfiles.store in %s could not be parsed for refresh/access checks (jq exit %s)\n' \
      "$profile" "$sqlite" "$jq_rc"
    return
  fi
  if [ -n "$incomplete" ]; then
    printf 'CRITICAL\tprofile %s: profile(s) missing refresh/access: %s\n' \
      "$profile" "$(printf '%s' "$incomplete" | tr '\n' ' ')"
  fi

  # Expected profile count, per-profile configurable ("0" on edge = skip
  # until Option B logins land there).
  case "$profile" in
    main) expected="$CODEX_EXPECTED_PROFILES_MAIN" ;;
    edge) expected="$CODEX_EXPECTED_PROFILES_EDGE" ;;
    *) expected=0 ;;
  esac
  if [ "$expected" -gt 0 ] 2>/dev/null; then
    local count
    count="$(printf '%s' "$row" | jq -r '(.profiles // {}) | length')"
    jq_rc=$?
    if [ "$jq_rc" -ne 0 ]; then
      printf 'UNEVALUATED\tprofile %s: authProfiles.store in %s could not be parsed for profile-count check (jq exit %s)\n' \
        "$profile" "$sqlite" "$jq_rc"
      return
    fi
    if [ "$count" != "$expected" ]; then
      printf 'CRITICAL\tprofile %s: authProfiles.store has %s profile(s), expected %s\n' \
        "$profile" "$count" "$expected"
    fi
  fi
}

# _check_agent_stores <profile> — every agents/*/agent/openclaw-agent.sqlite
# auth_profile_store row must be EMPTY or absent — a non-empty profiles map
# there is 2.0's shape of the same fan-out 7.x's ensure-codex-auth.sh /
# codex-auth-sync.sh guarded against.
_check_agent_stores() {
  local profile="$1" state_dir dir rc row profiles_len profiles_rc
  state_dir="$CODEX_AUTH_ROOT/.openclaw-$profile"
  [ -d "$state_dir" ] || return

  shopt -s nullglob
  for dir in "$state_dir"/agents/*/agent; do
    [ -d "$dir" ] || continue
    local agent_id
    agent_id="$(basename "$(dirname "$dir")")"
    rc=0
    row="$(sqlite_helper read_agent_store "$dir/openclaw-agent.sqlite" 2>/dev/null)" || rc=$?
    if [ "$rc" -ne 0 ]; then
      printf 'UNEVALUATED\tprofile %s/%s: %s UNREADABLE\n' "$profile" "$agent_id" "$dir/openclaw-agent.sqlite"
      continue
    fi
    [ -n "$row" ] || continue
    # A jq/parse failure here (corrupt or wrong-shaped store_json) must NOT
    # collapse to 0 (== "no fan-out" == clean) — that reads a corrupt store
    # as an empty one. UNEVALUATED, never clean, on any parse failure.
    if ! printf '%s' "$row" | jq -e 'type' >/dev/null 2>&1; then
      printf 'UNEVALUATED\tprofile %s/%s: %s auth_profile_store row could not be parsed for fan-out check\n' \
        "$profile" "$agent_id" "$dir/openclaw-agent.sqlite"
      continue
    fi
    # `.profiles` must be PRESENT as a JSON object: `{"profiles":[]}` (an
    # array) has length 0 same as an empty object, but is NOT the expected
    # shape — a QA-bot-reproduced hole (PR #897 round 2) where an array
    # silently read as "no fan-out" instead of UNEVALUATED like every other
    # shape mismatch. Round 3: the `// {}` default made an ABSENT .profiles
    # indistinguishable from a genuinely-present empty one too — the
    # migration always writes {version, profiles}, so absent is malformed,
    # not "just no fan-out". Drop the default; require it present.
    if ! printf '%s' "$row" | jq -e 'has("profiles") and (.profiles | type == "object")' >/dev/null 2>&1; then
      printf 'UNEVALUATED\tprofile %s/%s: %s auth_profile_store .profiles is absent or not an object — cannot verify fan-out shape\n' \
        "$profile" "$agent_id" "$dir/openclaw-agent.sqlite"
      continue
    fi
    profiles_len="$(printf '%s' "$row" | jq -r '(.profiles // {}) | length' 2>/dev/null)"
    profiles_rc=$?
    if [ "$profiles_rc" -ne 0 ] || ! [ "$profiles_len" -ge 0 ] 2>/dev/null; then
      printf 'UNEVALUATED\tprofile %s/%s: %s auth_profile_store row could not be parsed for fan-out check\n' \
        "$profile" "$agent_id" "$dir/openclaw-agent.sqlite"
      continue
    fi
    if [ "$profiles_len" -gt 0 ] 2>/dev/null; then
      printf 'CRITICAL\tprofile %s/%s: per-agent auth_profile_store row carries %s profile(s) — fan-out, must be read-through only\n' \
        "$profile" "$agent_id" "$profiles_len"
    fi
  done
  shopt -u nullglob
}

# _check_legacy_files <profile> — un-archived legacy auth files anywhere
# under agents/. A regular file OR symlink named exactly one of the legacy
# names is live; a `.migrated-*`/`.pre81-*` suffixed name is archived and
# exempt (the suffix is what makes it archived — an exact-name match by
# construction excludes it).
_check_legacy_files() {
  local profile="$1" state_dir agents_dir f
  state_dir="$CODEX_AUTH_ROOT/.openclaw-$profile"
  agents_dir="$state_dir/agents"
  [ -d "$agents_dir" ] || return

  while IFS= read -r -d '' f; do
    printf 'CRITICAL\tprofile %s: un-archived legacy auth file present: %s\n' "$profile" "$f"
  done < <(find "$agents_dir" \
    \( -name 'auth-profiles.json' -o -name 'auth-state.json' -o -path '*/codex-home/auth.json' \) \
    \( -type f -o -type l \) -print0 2>/dev/null)
}

# ── main ──────────────────────────────────────────────────────────────────

main() {
  local findings="" profile viol=0 uneval=0
  for profile in $CODEX_AUTH_PROFILES; do
    [ -n "$profile" ] || continue
    findings="${findings}$(_check_shared_store "$profile")"$'\n'
    findings="${findings}$(_check_agent_stores "$profile")"$'\n'
    findings="${findings}$(_check_legacy_files "$profile")"$'\n'
  done

  local sev msg
  while IFS=$'\t' read -r sev msg; do
    [ -n "$sev" ] || continue
    case "$sev" in
      CRITICAL) viol=1; log "VIOLATION: $msg"; echo "  - [$sev] $msg" ;;
      UNEVALUATED) uneval=1; log "UNEVALUATED: $msg"; echo "  - [$sev] $msg" ;;
    esac
  done <<< "$findings"

  if [ "$viol" -eq 1 ]; then
    log "codex auth invariant VIOLATION(S) found (openclaw $runtime_ver, profiles: $CODEX_AUTH_PROFILES)"
    return 1
  fi
  if [ "$uneval" -eq 1 ]; then
    log "codex auth invariants could not be fully evaluated (nothing confirmed, but NOT clean)"
    return 2
  fi
  log "clean: authProfiles.store shape is correct, no per-agent fan-out, no un-archived legacy files (openclaw $runtime_ver, profiles: $CODEX_AUTH_PROFILES)"
  return 0
}

main
exit $?
