#!/usr/bin/env bash
# codex-auth-sync.sh — fan the codex (ChatGPT OAuth) ACCESS token out to every
# store the openclaw 2026.7.x runtime actually reads, from ONE canonical file.
# Successor to the 6.1-era JSON-symlink fabric (ensure-codex-auth.sh), which
# 7.x made inert: the runtime no longer reads auth-profiles.json at all.
#
# ── The 7.x auth surfaces (staging-validated 2026-07-14) ─────────────────────
# 1. agents/main/agent/openclaw-agent.sqlite, table auth_profile_store, row
#    store_key='primary' — the HARDCODED inheritance base ("main" is baked in
#    via resolveDefaultAgentDir({}); the configured default agent is NOT it).
#    Core merges this store into every agent's runtime store.
# 2. <agentDir>/codex-home/auth.json — the native codex app-server's own store;
#    this is what actually authenticates the model call. auth_mode "apikey"
#    with hydra's placeholder OPENAI_API_KEY forces the api-key route → fleet
#    401 invalid_api_key. auth_mode "chatgpt" + tokens = the working OAuth
#    (wss://api.openai.com/v1/responses; the chatgpt.com/backend-api route is
#    gone in 7.x — don't diagnose by the old URL tell).
#
# ── Single-refresher invariant (THE load-bearing rule) ───────────────────────
# codex refresh tokens are SINGLE-USE and rotating: any two independent holders
# eventually mutually invalidate the whole chain (incidents 2026-05-29,
# 2026-06-08; and `doctor --fix` on 7.1 recreates exactly that topology by
# fanning the profile into EVERY agent DB — observed on staging). Therefore:
#   - the REAL refresh token lives ONLY in the canonical JSON
#     (agents/main/agent/auth-profiles.json), owned by codex-oauth-refresh.sh
#     (the twice-weekly timer), the SOLE refresher on the box;
#   - every derived store (sqlite rows, every codex-home/auth.json) gets the
#     current ACCESS token plus a SENTINEL refresh token, so neither openclaw
#     core nor the codex app-server can ever rotate the chain themselves.
#     Derived payloads are built by WHITELIST (named fields only), so a
#     future canonical shape (refresh_token/refreshToken/…) can never smuggle
#     the real token into a derived store.
# Access tokens live ~8-10 days; the Sun+Wed refresh keeps them always fresh,
# so nothing in-process ever needs to refresh (same posture as the 6.1 #57399
# workaround). codex-keepalive.sh remains the safety-net pager.
#
# ── Modes ────────────────────────────────────────────────────────────────────
#   (default / ensure): idempotently write surfaces 1+2 for the managed profile
#     state dirs and delete per-agent auth_profile_store rows (fan-out
#     cleanup). Exit 0 when every surface converged, 1 when any surface FAILED
#     to converge (callers page/log — the fleet would silently ride a stale
#     access token otherwise), 2 on structural error (canonical missing,
#     node/jq absent). Gateways must restart to load a changed token.
#   --check: read-only. Exit 1 if any surface drifted (apikey-mode, stale or
#     unreadable stores, per-agent rows present, REAL refresh token leaked
#     anywhere — including raw sqlite bytes), 0 clean, 2 error.
#     Exit-code convention matches the repo's other guards.
#
# ── Version gate ─────────────────────────────────────────────────────────────
# On a pre-2026.7 runtime this script is a NO-OP (exit 0): the 6.1 fabric
# (symlinks + apikey-mode auth.json) is still what works there. An UNKNOWN
# runtime (openclaw missing/unparseable) is also a no-op — never apply 7.x
# semantics on a box we can't positively identify as 7.x. --force bypasses
# both (used right after the runtime bump, before the first start).
#
# ── Env overrides ────────────────────────────────────────────────────────────
#   CODEX_AUTH_ROOT      sandbox root (default /root) — bats points this at a
#                        throwaway fleet so tests never touch live auth.
#   CODEX_AUTH_PROFILES  space-separated profile names to manage (default
#                        "main edge"). Deliberately NOT a glob: a leftover
#                        .openclaw-stage71 staging copy must not be kept
#                        credentialed by the twice-weekly refresh.
#   CANON_DIR            canonical agent dir (default
#                        $CODEX_AUTH_ROOT/.openclaw-main/agents/main/agent).
#   CODEX_AUTH_PRIMARY   canonical profile key whose identity goes into
#                        codex-home/auth.json (default openai-codex:aaron@muso.ai;
#                        falls back to the first profile if absent).
#   NODE_BIN             node binary (default: node on PATH).
set -uo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=version-compare.sh
source "$SCRIPT_DIR/version-compare.sh"

CODEX_AUTH_ROOT="${CODEX_AUTH_ROOT:-/root}"
CODEX_AUTH_PROFILES="${CODEX_AUTH_PROFILES:-main edge}"
CANON_DIR="${CANON_DIR:-${CODEX_AUTH_ROOT}/.openclaw-main/agents/main/agent}"
CANON_PROFILES="$CANON_DIR/auth-profiles.json"
# CODEX_AUTH_PRIMARY: env wins; else the account-rotation state file
# (/var/lib/hydra/codex-active-account — written by codex-account-rotate.sh,
# survives deploys); else the baked default. Resolved AFTER the canonical
# checks below, because the state-file key is validated against canonical.
# shellcheck source=codex-active-account.sh
source "$SCRIPT_DIR/codex-active-account.sh"
NODE_BIN="${NODE_BIN:-node}"
SENTINEL_REFRESH="SYNC-MANAGED-NO-REFRESH-TOKEN"
RUNTIME_FLOOR="2026.7"

LOGPREFIX="[codex-auth-sync $(date -u +%Y-%m-%dT%H:%M:%SZ)]"
log() { echo "$LOGPREFIX $*" >&2; }

MODE="ensure"
FORCE=0
for arg in "$@"; do
  case "$arg" in
    --check) MODE="check" ;;
    --force) FORCE=1 ;;
    ""|--ensure) ;;
    -h|--help) sed -n '2,75p' "$0"; exit 0 ;;
    *) log "ERROR: unknown argument: $arg (use --check, --ensure, --force)"; exit 2 ;;
  esac
done

command -v jq >/dev/null 2>&1 || { log "ERROR: jq not found"; exit 2; }
command -v "$NODE_BIN" >/dev/null 2>&1 || { log "ERROR: node not found (needed for node:sqlite)"; exit 2; }

# ── version gate (fail CLOSED on unknown — mirror codex-version.sh's hold) ───
if [ "$FORCE" -eq 0 ]; then
  runtime_ver="$(openclaw_runtime_version)"
  if [ -z "$runtime_ver" ]; then
    log "no-op: cannot determine the openclaw runtime version — refusing to apply 7.x sync semantics to an unidentified box (use --force to override)"
    exit 0
  fi
  if ! version_at_least "$RUNTIME_FLOOR" "$runtime_ver"; then
    log "no-op: runtime $runtime_ver < $RUNTIME_FLOOR — the 6.1 symlink fabric still applies (use --force to override)"
    exit 0
  fi
fi

[ -r "$CANON_PROFILES" ] || { log "ERROR: canonical store not readable: $CANON_PROFILES"; exit 2; }
jq -e '.profiles | length > 0' "$CANON_PROFILES" >/dev/null 2>&1 \
  || { log "ERROR: canonical store has no profiles: $CANON_PROFILES"; exit 2; }

CODEX_AUTH_PRIMARY="${CODEX_AUTH_PRIMARY:-$(caa_active_key "$CANON_PROFILES")}"

# ── derived payloads from canonical ──────────────────────────────────────────

# Unified-provider store payload for the main-agent sqlite row: keys
# openai-codex:<email> -> openai:<email>, provider -> openai (7.x
# "openai-provider-unification" naming). WHITELIST of fields — the real
# refresh token (whatever key it hides under) can never reach a derived store.
store_payload() {
  jq -c --arg sentinel "$SENTINEL_REFRESH" '
    { version: 1,
      profiles: (
        [ .profiles | to_entries[]
          | select(.key | startswith("openai-codex:"))
          | .key as $k
          | { key: ("openai:" + (.value.email // ($k | sub("^openai-codex:"; "")))),
              value: (
                (.value | {type, email, access, accountId, expires, chatgptPlanType}
                        | with_entries(select(.value != null)))
                + {provider: "openai", refresh: $sentinel}) }
        ] | from_entries)
    }' "$CANON_PROFILES"
}

# Primary identity for codex-home/auth.json (one identity per file).
primary_profile() {
  jq -c --arg p "$CODEX_AUTH_PRIMARY" '
    (.profiles[$p] // (.profiles | to_entries | map(select(.key | startswith("openai-codex:"))) | .[0].value))' \
    "$CANON_PROFILES"
}

STORE_JSON="$(store_payload)"
PRIMARY_JSON="$(primary_profile)"
[ -n "$STORE_JSON" ] && [ "$PRIMARY_JSON" != "null" ] \
  || { log "ERROR: could not derive payloads from canonical (no openai-codex:* profiles?)"; exit 2; }

PRIMARY_ACCESS="$(printf '%s' "$PRIMARY_JSON" | jq -r '.access // empty')"
PRIMARY_ACCOUNT="$(printf '%s' "$PRIMARY_JSON" | jq -r '.accountId // empty')"
[ -n "$PRIMARY_ACCESS" ] || { log "ERROR: primary profile has no access token"; exit 2; }

# Real refresh tokens from canonical, under ANY plausible key name — these
# must not appear in any derived store (used by BOTH modes: check flags them,
# ensure scrubs them).
REAL_REFRESH_TOKENS="$(jq -r '.profiles[] | (.refresh?, .refresh_token?, .refreshToken?) | select(. != null and . != "")' "$CANON_PROFILES")"

# ── node:sqlite helper ───────────────────────────────────────────────────────
# Subcommands (argv after -e code): read <agentDir> | upsert <agentDir> <json>
# | clear <agentDir>. `read` prints the primary row's store_json or nothing;
# it distinguishes "absent DB / no row" (exit 0, empty) from a REAL error
# (locked/corrupt/unreadable DB → exit 3) so --check can never report a store
# it could not read as clean.
NODE_HELPER='
const {DatabaseSync}=require("node:sqlite");
const [cmd, agentDir, payload] = process.argv.slice(1);
const path = agentDir + "/openclaw-agent.sqlite";
const fs = require("fs");
if (cmd === "read") {
  if (!fs.existsSync(path)) process.exit(0);
  try {
    const db = new DatabaseSync(path, {readOnly: true});
    let r;
    try {
      r = db.prepare("select store_json from auth_profile_store where store_key=?").get("primary");
    } catch (e) {
      if (/no such table/i.test(String(e.message))) process.exit(0);
      throw e;
    }
    if (r) process.stdout.write(r.store_json);
  } catch (e) { console.error(String(e.message)); process.exit(3); }
} else if (cmd === "upsert") {
  const db = new DatabaseSync(path);
  db.exec("CREATE TABLE IF NOT EXISTS auth_profile_store (store_key TEXT NOT NULL PRIMARY KEY, store_json TEXT NOT NULL, updated_at INTEGER NOT NULL)");
  db.exec("CREATE TABLE IF NOT EXISTS auth_profile_state (state_key TEXT NOT NULL PRIMARY KEY, state_json TEXT NOT NULL, updated_at INTEGER NOT NULL)");
  db.prepare("insert into auth_profile_store values (?,?,?) on conflict(store_key) do update set store_json=excluded.store_json, updated_at=excluded.updated_at")
    .run("primary", payload, Date.now());
} else if (cmd === "clear") {
  if (!fs.existsSync(path)) process.exit(0);
  try {
    const db = new DatabaseSync(path);
    try {
      db.exec("delete from auth_profile_store");
      db.exec("delete from auth_profile_state");
    } catch (e) {
      if (!/no such table/i.test(String(e.message))) throw e;
    }
    // Deleted rows can linger as raw bytes in the WAL — truncate it so the
    // --check byte-scan converges after a clear.
    try { db.exec("pragma wal_checkpoint(TRUNCATE)"); } catch (e) { /* non-WAL db */ }
  } catch (e) { console.error(String(e.message)); process.exit(3); }
} else if (cmd === "clear_state") {
  // Wipe ONLY auth_profile_state, preserving the just-upserted store row.
  // The main-agent branch upserts auth_profile_store but never clears state;
  // a real refresh token left in a LIVE auth_profile_state row survives VACUUM
  // (VACUUM reclaims dead rows/free pages, not live ones), so --check would
  // flag it forever. Only invoked when a leak is actually detected.
  if (!fs.existsSync(path)) process.exit(0);
  try {
    const db = new DatabaseSync(path);
    try {
      db.exec("delete from auth_profile_state");
    } catch (e) {
      if (!/no such table/i.test(String(e.message))) throw e;
    }
    try { db.exec("pragma wal_checkpoint(TRUNCATE)"); } catch (e) { /* non-WAL db */ }
  } catch (e) { console.error(String(e.message)); process.exit(3); }
} else if (cmd === "vacuum") {
  // Deleted token bytes also linger in FREE PAGES of the main DB file until a
  // VACUUM rewrites it. Only invoked when a leak is actually detected — never
  // routinely (a VACUUM on a live agent DB is unwanted contention).
  if (!fs.existsSync(path)) process.exit(0);
  try {
    const db = new DatabaseSync(path);
    db.exec("pragma wal_checkpoint(TRUNCATE)");
    db.exec("VACUUM");
    db.exec("pragma wal_checkpoint(TRUNCATE)");
  } catch (e) { console.error(String(e.message)); process.exit(3); }
} else { process.exit(2); }
'
sqlite_helper() { "$NODE_BIN" --experimental-sqlite --no-warnings -e "$NODE_HELPER" "$@" 2>/dev/null; }

# Enumerate agent dirs of the MANAGED profiles only (never a glob over every
# .openclaw-* — see CODEX_AUTH_PROFILES in the header).
agent_dirs() {
  shopt -s nullglob
  local p d
  for p in $CODEX_AUTH_PROFILES; do
    for d in "$CODEX_AUTH_ROOT/.openclaw-$p"/agents/*/agent; do
      [ -d "$d" ] && printf '%s\n' "$d"
    done
  done
  shopt -u nullglob
}

# Is this agent dir a per-state-dir "main" (inheritance base)?
is_main_agent_dir() { [[ "$1" == */agents/main/agent ]]; }

# ── ensure mode ──────────────────────────────────────────────────────────────

write_auth_json() {
  local dir="$1" f="$1/codex-home/auth.json" cur_access cur_mode cur_refresh
  mkdir -p "$dir/codex-home" 2>/dev/null || { log "WARNING: cannot create $dir/codex-home"; return 1; }
  if [ -f "$f" ]; then
    cur_mode="$(jq -r '.auth_mode // empty' "$f" 2>/dev/null || true)"
    cur_access="$(jq -r '.tokens.access_token // empty' "$f" 2>/dev/null || true)"
    cur_refresh="$(jq -r '.tokens.refresh_token // empty' "$f" 2>/dev/null || true)"
    # Fast path ONLY when the refresh slot is the sentinel too — a file left
    # by a bad migration with current access + the REAL refresh token must be
    # rewritten, or ensure would never converge what --check flags.
    if [ "$cur_mode" = "chatgpt" ] && [ "$cur_access" = "$PRIMARY_ACCESS" ] \
       && [ "$cur_refresh" = "$SENTINEL_REFRESH" ]; then
      return 0  # already correct — avoid last_refresh churn
    fi
  fi
  local tmp="$f.tmp.$$"
  if jq -n --arg access "$PRIMARY_ACCESS" --arg account "$PRIMARY_ACCOUNT" \
        --arg sentinel "$SENTINEL_REFRESH" --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{auth_mode: "chatgpt", OPENAI_API_KEY: null,
          tokens: {id_token: $access, access_token: $access,
                   refresh_token: $sentinel, account_id: $account},
          last_refresh: $now}' > "$tmp" 2>/dev/null \
     && chmod 600 "$tmp" && mv "$tmp" "$f"; then
    log "wrote chatgpt-mode auth.json: $f"
    return 0
  fi
  rm -f "$tmp"
  log "WARNING: failed to write $f"
  return 1
}

run_ensure() {
  local dir current failures=0
  while IFS= read -r dir; do
    if is_main_agent_dir "$dir"; then
      current="$(sqlite_helper read "$dir")" || current=""  # read error → upsert decides
      if [ "$current" != "$STORE_JSON" ]; then
        if sqlite_helper upsert "$dir" "$STORE_JSON"; then
          log "seeded main auth store row: $dir/openclaw-agent.sqlite"
        else
          log "WARNING: failed to upsert store row in $dir"
          failures=$((failures + 1))
        fi
      fi
    elif [ -e "$dir/openclaw-agent.sqlite" ]; then
      # Fan-out cleanup: non-main agents must never hold their own auth rows.
      # Clear whenever the DB EXISTS — not only when the primary row is
      # non-empty: --check byte-scans auth_profile_state/WAL/future tables,
      # so ensure must converge those too (clear wipes both auth tables and
      # truncates the WAL). Idempotent and cheap on an already-clean DB.
      if sqlite_helper clear "$dir"; then
        log "cleared per-agent auth tables: $dir"
      else
        log "WARNING: failed to clear per-agent rows in $dir"
        failures=$((failures + 1))
      fi
    fi
    write_auth_json "$dir" || failures=$((failures + 1))

    # Scrub check: deleted/replaced token bytes can survive in the DB's free
    # pages (and WAL) — if canonical's real refresh token is still readable
    # in the raw file, VACUUM it out; anything still leaked after that is a
    # failure --check would keep flagging.
    local scrub
    for scrub in "$dir/openclaw-agent.sqlite" "$dir/openclaw-agent.sqlite-wal"; do
      if refresh_leaked_into "$scrub"; then
        # On the main agent, upsert rewrote auth_profile_store but left
        # auth_profile_state intact — a leaked token there is a LIVE row VACUUM
        # cannot remove. Delete the state rows first so VACUUM can converge.
        # (Non-main agents already had both tables wiped by `clear` above, so
        # any residual leak is free-page bytes VACUUM alone handles.)
        if is_main_agent_dir "$dir"; then
          sqlite_helper clear_state "$dir" || true
        fi
        log "scrubbing leaked token bytes via VACUUM: $dir/openclaw-agent.sqlite"
        sqlite_helper vacuum "$dir" || true
        if refresh_leaked_into "$dir/openclaw-agent.sqlite" || refresh_leaked_into "$dir/openclaw-agent.sqlite-wal"; then
          log "WARNING: real refresh token still present in $dir/openclaw-agent.sqlite after VACUUM"
          failures=$((failures + 1))
        fi
        break
      fi
    done
  done < <(agent_dirs)

  if [ "$failures" -gt 0 ]; then
    log "ensure INCOMPLETE: $failures surface(s) failed to converge — the runtime may be on a STALE access token"
    return 1
  fi
  log "ensure complete"
  return 0
}

# ── --check mode ─────────────────────────────────────────────────────────────

# Does file $1 contain any REAL refresh token from canonical? Works on binary
# (sqlite) and text stores alike. Single-refresher invariant enforcement.
refresh_leaked_into() {
  local f="$1" rt
  [ -e "$f" ] || return 1
  while IFS= read -r rt; do
    [ -n "$rt" ] || continue
    if grep -aqF -- "$rt" "$f"; then
      return 0
    fi
  done <<< "$REAL_REFRESH_TOKENS"
  return 1
}

run_check() {
  local offenders=() dir row rc f mode access db

  while IFS= read -r dir; do
    rc=0
    row="$(sqlite_helper read "$dir")" || rc=$?
    db="$dir/openclaw-agent.sqlite"
    if [ "$rc" -ne 0 ]; then
      offenders+=("$db: UNREADABLE (cannot verify auth store — locked/corrupt?)")
    elif is_main_agent_dir "$dir"; then
      if [ -z "$row" ]; then
        offenders+=("$db: main auth store row MISSING")
      elif [ "$(printf '%s' "$row" | jq -S . 2>/dev/null)" != "$(printf '%s' "$STORE_JSON" | jq -S .)" ]; then
        offenders+=("$db: main store row is STALE (differs from canonical-derived payload)")
      fi
    elif [ -n "$row" ]; then
      offenders+=("$db: per-agent auth rows present (fan-out)")
    fi
    # Leak scan over the RAW sqlite bytes (+ WAL): catches token material in
    # auth_profile_state, non-primary rows, or any future table.
    for f in "$db" "$db-wal"; do
      if refresh_leaked_into "$f"; then
        offenders+=("$f: REAL refresh token leaked into derived store")
        break
      fi
    done

    f="$dir/codex-home/auth.json"
    if [ ! -f "$f" ]; then
      offenders+=("$f: missing (codex app-server would fall back to api-key mode)")
    else
      mode="$(jq -r '.auth_mode // empty' "$f" 2>/dev/null || true)"
      access="$(jq -r '.tokens.access_token // empty' "$f" 2>/dev/null || true)"
      if [ "$mode" != "chatgpt" ]; then
        offenders+=("$f: auth_mode is '${mode:-unset}' (must be chatgpt — apikey mode 401s the fleet)")
      elif [ "$access" != "$PRIMARY_ACCESS" ]; then
        offenders+=("$f: access token STALE (differs from canonical)")
      fi
      if refresh_leaked_into "$f"; then
        offenders+=("$f: REAL refresh token leaked into codex-home store")
      fi
    fi
  done < <(agent_dirs)

  if [ "${#offenders[@]}" -gt 0 ]; then
    log "DRIFT DETECTED (${#offenders[@]} offender(s)):"
    local o
    for o in "${offenders[@]}"; do
      echo "  - $o"
    done
    log "Run scripts/lib/codex-auth-sync.sh (ensure mode) to converge, then restart gateways."
    return 1
  fi
  log "clean: all derived codex auth stores match canonical; no refresh-token fan-out"
  return 0
}

case "$MODE" in
  check)  run_check;  exit $? ;;
  ensure) run_ensure; exit $? ;;
esac
