#!/usr/bin/env bash
# codex-mint-idtoken.sh — post-doctor ID-token mint for the openclaw 2026.8.1
# upgrade window (docs/runbooks/UPGRADE-2026.8.1.md Phase 4).
#
# ── Why this exists ───────────────────────────────────────────────────────
# openclaw 2.0's shared auth lives in ONE sqlite cell:
#   <state-dir>/state/openclaw.sqlite -> table config_machine_state ->
#   row state_key='authProfiles.store', value_json = {version, profiles: {
#     "openai:<email>": {type:"oauth", provider:"openai", email, access,
#                         refresh, idToken, accountId, chatgptPlanType,
#                         expires}
#   }} (companion row state_key='authProfiles.state').
# A profile migrated (or re-seeded) onto that cell can arrive with no
# `idToken` field — this script closes that gap by doing exactly ONE
# `grant_type=refresh_token` POST (the same flow codex-oauth-refresh.sh
# runs against the pre-8.1 JSON store — see that script for the reference
# shape; this one targets the sqlite cell instead) and writing the
# access/refresh/idToken/expires the response carries back into the SAME
# profile row.
#
# ── Secret handling ────────────────────────────────────────────────────────
# Tokens NEVER cross a process boundary as argv or env: this script hands
# node only non-secret arguments (db path, profile id, token URL, client id,
# scope) and node itself reads the sqlite cell, performs the HTTPS POST via
# its built-in fetch (no curl — a token never touches a subshell or a second
# process), and writes the result straight back into the same cell. On ANY
# failure the cell is left untouched and only the OAuth error field (or a
# structural diagnostic that never contains token bytes) is printed.
#
# ── Refusals (fail loud, change nothing) ───────────────────────────────────
#   - runtime < 2026.8 (this sqlite cell doesn't exist yet on 7.x)
#   - no refresh token on the target profile
#   - a refresh token matching a known sentinel pattern (STAGING-/
#     SYNC-MANAGED — see codex-auth-sync.sh's SENTINEL_REFRESH) — a
#     sentinel means --state-dir points at a DERIVED store, not canonical
#   - the sqlite cell / row / profile is missing
#   - the refresh POST fails or the response is incomplete
#
# ── Usage ────────────────────────────────────────────────────────────────
#   codex-mint-idtoken.sh [--state-dir <path>] [--profile-id <id>]
#
#   --state-dir   profile state dir holding state/openclaw.sqlite
#                 (default: /root/.openclaw-main)
#   --profile-id  profile key in authProfiles.store, e.g. openai:aaron@muso.ai
#                 (default: derived from /var/lib/hydra/codex-active-account
#                 — CODEX_ACTIVE_ACCOUNT_FILE override — stripping any
#                 "openai:"/"openai-codex:" prefix and prepending "openai:")
#
# Env overrides: NODE_BIN, CODEX_ACTIVE_ACCOUNT_FILE, CODEX_OAUTH_TOKEN_URL,
# CODEX_OAUTH_CLIENT_ID, CODEX_OAUTH_SCOPE (same defaults/names as
# codex-oauth-refresh.sh, so an operator override applies to both).
# ────────────────────────────────────────────────────────────────────────────
set -euo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=version-compare.sh
source "$SCRIPT_DIR/version-compare.sh"

STATE_DIR="/root/.openclaw-main"
PROFILE_ID=""
NODE_BIN="${NODE_BIN:-node}"
CODEX_ACTIVE_ACCOUNT_FILE="${CODEX_ACTIVE_ACCOUNT_FILE:-/var/lib/hydra/codex-active-account}"
OAUTH_TOKEN_URL="${CODEX_OAUTH_TOKEN_URL:-https://auth.openai.com/oauth/token}"
OAUTH_CLIENT_ID="${CODEX_OAUTH_CLIENT_ID:-app_EMoamEEZ73f0CkXaXp7hrann}"
OAUTH_SCOPE="${CODEX_OAUTH_SCOPE:-openid profile email offline_access}"
RUNTIME_FLOOR="2026.8"

LOGPREFIX="[codex-mint-idtoken $(date -u +%Y-%m-%dT%H:%M:%SZ)]"
log() { echo "$LOGPREFIX $*" >&2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --state-dir)  STATE_DIR="${2:?--state-dir needs a path}"; shift 2 ;;
    --profile-id) PROFILE_ID="${2:?--profile-id needs an id}"; shift 2 ;;
    --all-profiles) ALL_PROFILES=1; shift ;;
    -h|--help)    sed -n '2,44p' "$0"; exit 0 ;;
    *)            log "ERROR: unknown argument: $1 (see --help)"; exit 2 ;;
  esac
done

ALL_PROFILES="${ALL_PROFILES:-0}"
if [ "$ALL_PROFILES" = "1" ] && [ -n "${PROFILE_ID:-}" ]; then
  log "ERROR: --all-profiles and --profile-id are mutually exclusive"
  exit 2
fi

command -v "$NODE_BIN" >/dev/null 2>&1 || { log "ERROR: node not found (needed for node:sqlite + fetch)"; exit 2; }

# ── runtime gate: refuse below 2026.8 (fail CLOSED on unknown) ─────────────
runtime_ver="$(openclaw_runtime_version)"
if [ -z "$runtime_ver" ] || ! version_at_least "$RUNTIME_FLOOR" "$runtime_ver"; then
  log "ERROR: refusing — openclaw runtime is '${runtime_ver:-unknown}', needs >= ${RUNTIME_FLOOR} (2.0 shared-auth sqlite store; docs/runbooks/UPGRADE-2026.8.1.md)"
  exit 2
fi

# ── profile-id derivation ───────────────────────────────────────────────────
if [ "$ALL_PROFILES" != "1" ] && [ -z "$PROFILE_ID" ]; then
  raw=""
  if [ -r "$CODEX_ACTIVE_ACCOUNT_FILE" ]; then
    raw="$(head -n1 "$CODEX_ACTIVE_ACCOUNT_FILE" 2>/dev/null | tr -d '[:space:]')" || raw=""
  fi
  if [ -z "$raw" ]; then
    log "ERROR: no --profile-id given and $CODEX_ACTIVE_ACCOUNT_FILE is missing/empty — refusing to guess"
    exit 2
  fi
  stripped="${raw#openai-codex:}"
  stripped="${stripped#openai:}"
  PROFILE_ID="openai:${stripped}"
fi
log "profile-id: $PROFILE_ID"

DB_PATH="$STATE_DIR/state/openclaw.sqlite"
[ -f "$DB_PATH" ] || { log "ERROR: sqlite store not found: $DB_PATH"; exit 2; }

# ── the mint itself — ONE node process reads, POSTs, and writes back ───────
# SENTINEL_RE mirrors codex-auth-sync.sh's SENTINEL_REFRESH constant: derived
# stores carry a "SYNC-MANAGED-NO-REFRESH-TOKEN" placeholder, and hydra's own
# bats fixtures/staging copies use a "STAGING-" prefix (see
# docs/lessons/reference_staging_copy_neuter_checklist). Either means this
# --state-dir is not the canonical profile — refuse rather than burn a POST
# against a token that was never real.
NODE_HELPER='
import { DatabaseSync } from "node:sqlite";
import fs from "node:fs";
import path from "node:path";

const [dbPath, profileId, tokenUrl, clientId, scope] = process.argv.slice(1);
const SENTINEL_RE = /^(STAGING-|SYNC-MANAGED)/;

function fail(msg) {
  console.error(msg);
  process.exit(1);
}

if (!fs.existsSync(dbPath)) fail(`sqlite store not found: ${dbPath}`);

let db;
try {
  db = new DatabaseSync(dbPath, { readOnly: false });
} catch (e) {
  fail(`store open failed: ${e.message}`);
}

let row;
try {
  row = db.prepare("select value_json from config_machine_state where state_key=?").get("authProfiles.store");
} catch (e) {
  fail(`store read failed: ${e.message}`);
}
if (!row) fail("no authProfiles.store row in config_machine_state");

let store;
try {
  store = JSON.parse(row.value_json);
} catch (e) {
  fail(`authProfiles.store value_json is not valid JSON: ${e.message}`);
}

const profile = store.profiles && store.profiles[profileId];
if (!profile) fail(`profile "${profileId}" not found in authProfiles.store`);

const refreshTok = profile.refresh;
if (!refreshTok) fail(`profile "${profileId}" has no refresh token — needs device-code re-auth`);
if (SENTINEL_RE.test(refreshTok)) {
  fail(`profile "${profileId}" carries a sentinel refresh token — this is a DERIVED store, not canonical; point --state-dir at the canonical profile store`);
}

const body = new URLSearchParams({
  grant_type: "refresh_token",
  client_id: clientId,
  refresh_token: refreshTok,
  scope,
});

let resp, json;
try {
  resp = await fetch(tokenUrl, {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: body.toString(),
  });
} catch (e) {
  fail(`refresh POST failed: ${e.message}`);
}
try {
  json = await resp.json();
} catch (e) {
  json = {};
}

if (!resp.ok || !json.access_token || !json.refresh_token || !json.expires_in || !json.id_token) {
  const err = json.error || json.error_description || `HTTP ${resp.status}`;
  fail(`refresh failed: ${err}`);
}

// The endpoint has ROTATED the single-use refresh token: from this line on, the
// only copy of a usable refresh token is `json`. Persist it to a 0600 recovery
// file BEFORE touching the store (same contract as codex-oauth-refresh.sh), so a
// store-write failure cannot burn the auth chain — the operator merges the file
// by hand instead of needing a device re-auth. Removed only after a COMMITTED
// store write.
const recoveryDir = process.env.CODEX_MINT_RECOVERY_DIR || path.dirname(dbPath);
const recoveryPath = path.join(recoveryDir, `codex-mint-recovery.${profileId.replace(/[^A-Za-z0-9._@-]/g, "_")}.${Date.now()}.json`);
try {
  const tmp = recoveryPath + ".tmp";
  fs.writeFileSync(tmp, JSON.stringify({ profileId, minted_at: new Date().toISOString(), token_response: json }), { mode: 0o600, flag: "wx" });
  fs.chmodSync(tmp, 0o600);
  fs.renameSync(tmp, recoveryPath);
} catch (e) {
  // Cannot even persist the rotated token: refuse to proceed to a store write we
  // could not recover from, but say EXACTLY what was lost and where it is (only
  // in the memory of this process, so print nothing token-bearing).
  fail(`refresh succeeded but the recovery file could not be written (${e.message}) — the rotated refresh token for ${profileId} exists only in this process; the store was NOT touched; re-run will need device re-auth (refresh_token_reused)`);
}

const expires = Date.now() + json.expires_in * 1000;
profile.access = json.access_token;
profile.refresh = json.refresh_token;
profile.idToken = json.id_token;
profile.expires = expires;
store.profiles[profileId] = profile;

const newValueJson = JSON.stringify(store);
try {
  db.exec("BEGIN IMMEDIATE");
  const res = db.prepare("update config_machine_state set value_json=?, updated_at_ms=? where state_key=?")
    .run(newValueJson, Date.now(), "authProfiles.store");
  if (res.changes !== 1) throw new Error(`expected 1 row updated, got ${res.changes}`);
  db.exec("COMMIT");
} catch (e) {
  try { db.exec("ROLLBACK"); } catch { /* nothing to roll back */ }
  fail(`store write failed: ${e.message} — the ROTATED refresh token is preserved (mode 0600) at ${recoveryPath}; merge it into authProfiles.store for ${profileId} by hand, then shred the file. Do NOT re-run the mint: the old refresh token in the store is already spent.`);
}
try { db.exec("pragma wal_checkpoint(TRUNCATE)"); } catch { /* non-WAL db */ }
// Committed: the store now holds the rotated token, so the recovery copy is a
// liability, not a safety net. Overwrite-then-unlink (best effort; unlink is what matters).
try { fs.writeFileSync(recoveryPath, "\0".repeat(4096)); } catch { /* ignore */ }
try { fs.unlinkSync(recoveryPath); } catch (e) { console.error(`WARNING: could not remove recovery file ${recoveryPath}: ${e.message} — shred it by hand`); }

console.log(JSON.stringify({
  profile: profileId,
  access_len: json.access_token.length,
  refresh_len: json.refresh_token.length,
  id_token_len: json.id_token.length,
  expires_at: new Date(expires).toISOString(),
}));
'

# ── cross-process serialization ──────────────────────────────────────────────
# The helper reads the WHOLE auth cell, refreshes ONE profile, and writes the
# whole cell back. Two mints running at once (two operators, or a loop and a
# retry) would each snapshot the same cell, each rotate their single-use token,
# and the last whole-cell UPDATE would overwrite the other's fresh credentials
# with its stale snapshot — silently, both exiting 0. Hold an exclusive flock
# keyed to the state dir across read -> refresh -> commit; the helper only
# opens the DB after the lock is ours, so its snapshot is always current.
MINT_LOCK="${CODEX_MINT_LOCK_FILE:-$STATE_DIR/state/.codex-mint.lock}"
exec 9>"$MINT_LOCK" || { log "ERROR: cannot open mint lock $MINT_LOCK"; exit 2; }
if ! flock -w "${CODEX_MINT_LOCK_WAIT_SECS:-300}" 9; then
  log "ERROR: another mint holds $MINT_LOCK for >${CODEX_MINT_LOCK_WAIT_SECS:-300}s — not proceeding (a concurrent mint would clobber the cell)"
  exit 2
fi
_mint_one() {
  "$NODE_BIN" --experimental-sqlite --no-warnings --input-type=module -e "$NODE_HELPER" \
    "$DB_PATH" "$1" "$OAUTH_TOKEN_URL" "$OAUTH_CLIENT_ID" "$OAUTH_SCOPE"
}

if [ "$ALL_PROFILES" != "1" ]; then
  if _mint_one "$PROFILE_ID"; then
    log "mint OK — restart the gateway on $STATE_DIR to load the new token"
    exit 0
  fi
  log "mint FAILED — $DB_PATH left untouched"
  exit 1
fi

# ── --all-profiles sweep ────────────────────────────────────────────────────
# Enumerate INSIDE the flock we already hold, so the id list and every rotation
# see one consistent cell. ONE acquisition for the whole sweep, not one per
# profile: three separate acquisitions would let another writer interleave and
# clobber a fresh credential with a stale whole-cell snapshot.
#
# A profile whose refresh slot carries a SENTINEL is SKIPPED, not failed. A
# sentinel means that row is a DERIVED copy with nothing to rotate; aborting on
# it would leave the real profiles unrefreshed, and a loop that tried to
# "recover" past it risks rotating a real single-use chain twice in one run.
_enum="$("$NODE_BIN" --experimental-sqlite --no-warnings -e '
  const { DatabaseSync } = require("node:sqlite");
  const db = new DatabaseSync(process.argv[1], { readOnly: true });
  const row = db.prepare("select value_json from config_machine_state where state_key=?").get("authProfiles.store");
  if (!row || !row.value_json) process.exit(3);
  const profiles = (JSON.parse(row.value_json).profiles) || {};
  const SENTINEL_RE = /^(STAGING-|SYNC-MANAGED)/;
  for (const [id, pr] of Object.entries(profiles)) {
    const r = pr && typeof pr.refresh === "string" ? pr.refresh : "";
    const st = !r ? "none" : (SENTINEL_RE.test(r) ? "sentinel" : "real");
    process.stdout.write(id + "\t" + st + "\n");
  }
' "$DB_PATH" 2>/dev/null)" || {
  log "ERROR: could not enumerate profiles from $DB_PATH — refusing the sweep"
  exit 2
}

if [ -z "$_enum" ]; then
  log "ERROR: authProfiles.store holds NO profiles — refusing (an empty sweep must not read as success)"
  exit 2
fi

attempted=0; succeeded=0; failed=0; skipped=0

# Emit SWEEP_ROTATED on EVERY exit path once a rotation has been COMMITTED.
# _mint_one persists each rotation immediately, so profile A can be written to
# the cell and its old single-use refresh token SPENT, and then profile B can
# fail and exit before any marker is printed. The wrapper would see a non-zero
# rc, skip the restart, and leave A's fresh credentials persisted-but-unloaded:
# the running gateway keeps serving a snapshot whose refresh chain has already
# moved on. A committed rotation MUST be loadable even when a later profile
# fails, so the count is reported from a trap rather than from the success path.
# Also covers being killed mid-sweep (SIGTERM at the systemd TimeoutStartSec).
# `return 0` is load-bearing, and ONLY under `set -e` (which this script sets
# at :53) — measured, because my first comment here got the mechanism wrong:
#   set -euo pipefail ; t(){ [ 0 -ge 1 ] && echo hi; } ; trap t EXIT ; exit 2  -> 1
#   set -euo pipefail ; t(){ ... ; return 0; }          ; trap t EXIT ; exit 2  -> 2
#   (no set -e)       ; t(){ [ 0 -ge 1 ] && echo hi; }  ; trap t EXIT ; exit 2  -> 2
# So under set -e an EXIT trap whose LAST command fails replaces the script's
# status with 1. Without the `return 0`, an all-skipped sweep exited 1 instead
# of its intended 2 — caught by this suite's own all-skipped regression.
_emit_rotated() {
  [ "${succeeded:-0}" -ge 1 ] && printf 'SWEEP_ROTATED=%s\n' "$succeeded"
  return 0
}
trap _emit_rotated EXIT
# IFS=$'\t' rather than a literal tab in quotes. The literal tab WORKED
# (proven: the extracted line splits openai:a@x.com<TAB>real correctly), but
# it is an INVISIBLE character in source — indistinguishable from IFS="\\t",
# which does NOT split and would make every rotation look up a nonexistent
# profile id. A reviewer read it as the broken form, and any editor, patch or
# copy-paste that converts tabs to spaces turns correct code into silently
# broken code. $'\t' is explicit and cannot be mangled.
while IFS=$'\t' read -r pid pstate; do
  [ -n "$pid" ] || continue
  if [ "$pstate" = "sentinel" ]; then
    skipped=$((skipped + 1))
    log "skip $pid — refresh slot carries a sentinel (derived store copy; nothing to rotate)"
    continue
  fi
  if [ "$pstate" = "none" ]; then
    skipped=$((skipped + 1))
    log "skip $pid — no refresh token on this profile"
    continue
  fi
  attempted=$((attempted + 1))
  if _mint_one "$pid"; then
    succeeded=$((succeeded + 1))
  else
    failed=$((failed + 1))
    log "mint FAILED for $pid"
  fi
done <<EOF
$_enum
EOF

log "sweep: attempted=$attempted ok=$succeeded failed=$failed skipped=$skipped"

# Non-zero on ANY failure so the timer goes red. Non-zero ALSO when nothing was
# attempted: an all-skipped sweep means every profile is derived or tokenless,
# which is a broken canonical store, not a healthy no-op.
if [ "$failed" -gt 0 ]; then
  log "sweep FAILED — $failed profile(s) did not rotate"
  exit 1
fi
if [ "$attempted" -eq 0 ]; then
  log "ERROR: sweep attempted NOTHING ($skipped skipped) — refusing to report success"
  exit 2
fi
log "sweep OK ($succeeded rotated) — restart the gateway on $STATE_DIR to load the new tokens"
# The marker is emitted by the EXIT trap above — the SINGLE emission point, so
# every exit path reports a committed rotation identically.
exit 0
