#!/usr/bin/env bash
# codex-edge-mirror.sh — mirror main's codex (ChatGPT OAuth) ACCESS credentials
# into edge's openclaw 2.0 shared auth cell, from ONE canonical cell.
#
# ── Why this exists ─────────────────────────────────────────────────────────
# On openclaw >= 2026.8 each gateway PROFILE reads its own shared auth cell:
#   <stateDir>/state/openclaw.sqlite → table config_machine_state →
#   row state_key='authProfiles.store', column value_json (NOT state_json),
#   profiles keyed "openai:<email>".
# The 2026-09-10 migration populated MAIN's cell (doctor imported the canonical
# JSON) but edge's cell came up with NO row: its 7.x auth files were derived
# sentinel copies and were scrubbed on purpose before doctor ran. Since then
# every edge turn (Caroline, agent `support`) has failed over to paid
# OpenRouter with `Explicit auth order for openai has no usable profiles`.
# The upgrade plan's "Option B" (three independent device logins on edge) was
# never executed and would ALSO have created a second refresh chain per
# account — the exact topology the single-refresher invariant forbids.
#
# ── What it writes (and what it never writes) ───────────────────────────────
# Per "openai:<email>" profile in main's cell, ONE atomic replace of that
# profile in edge's cell with a WHITELISTED payload:
#   type, provider, email, access, accountId, chatgptPlanType, expires,
#   idToken (if present), and refresh = SYNC-MANAGED-NO-REFRESH-TOKEN.
# The REAL refresh token is copied NOWHERE (single-refresher invariant: only
# main's cell holds the rotating single-use chain; the scheduled refresher —
# codex-canonical-refresh.sh — is its sole writer). The mirror re-reads the
# target after every write and fails loud if any source refresh token is
# found in it. `access` and `accountId` are always written TOGETHER, in one
# transaction: the runtime decodes the account id from the access token and
# THROWS on a mismatch with the stored one (dist shared-client
# buildChatgptAuthTokensParams), so they can never be written apart.
#
# Tokens never cross a process boundary: bash hands node only paths and mode
# flags; node reads, derives, writes and verifies. stdout carries only
# value-free summary lines (profile id, token LENGTH, account id, expiry).
#
# ── Modes ───────────────────────────────────────────────────────────────────
#   (default / --ensure)  converge edge's cell. Exit 0 converged, 1 when any
#                         profile was REFUSED or FAILED (see below), 2 on a
#                         structural error (runtime unknown, store/table
#                         missing, node absent), 6 when --restart's gateway
#                         restart failed after a successful write.
#   --check               read-only. Exit 1 on drift (row/profile missing,
#                         stale access/expires, accountId ≠ token claim,
#                         refresh slot not the sentinel, extra openai:*
#                         profiles, leaked refresh token), 0 clean, 2 when it
#                         could not evaluate.
#   --dry-run             print exactly what --ensure would write, per
#                         profile, and write NOTHING. Exit as --ensure would.
#   --restart             (ensure only) drain-restart the target gateway —
#                         but ONLY when at least one profile was written. The
#                         gateway loads auth at startup; a converged cell
#                         under a running gateway is persisted-but-unloaded.
#                         An unchanged cell never restarts anything.
#
# ── Paging is a property of the FAILURE, not of the mode ────────────────────
# Every structural failure (exit 2) and every INCOMPLETE run (refused/failed
# profiles) pages CRITICAL whether the caller passed --restart or not — the
# ExecStartPre path swallows exit codes on purpose and systemd never runs
# OnFailure for a gateway that started, so a mode-gated page left edge booting
# onto paid OpenRouter with only a journal line (QA finding on #935, round
# 10). Only --check stays quiet: it is a read-only inspector whose output IS
# its exit code. Delivery goes through the status-returning
# lib/deploy-notify.sh; a failed delivery leaves the same durable marker
# notify-unit-failed.sh leaves (cron-health-watchdog.sh pages it within a
# tick). One page per CODEX_MIRROR_PAGE_COOLDOWN_SECS (default 1h) — a
# persistent failure must not page on every gateway restart.
#
# ── Refusals (per profile, loud, change nothing for that profile) ───────────
#   - source profile missing access/accountId/expires, or its stored
#     accountId differs from the access token's chatgpt_account_id claim
#   - source refresh slot missing or itself a SENTINEL (then --source is a
#     derived store, not canonical — never mirror a mirror)
#   - target profile already holds a REAL (non-sentinel) refresh token: that
#     is an independent chain someone logged in deliberately; overwriting it
#     silently is not this script's call
#   - an extra openai:* profile on the target that carries a REAL refresh
#     token (not pruned; sentinel-bearing extras ARE pruned — they are ours)
#
# ── Runtime gate ────────────────────────────────────────────────────────────
# Below 2026.8 the cell does not exist: "not applicable", exit 0. An UNKNOWN
# runtime (openclaw missing/unparseable) is exit 2 — never apply 2.0 write
# semantics to a box we cannot positively identify.
#
# ── Where it runs ───────────────────────────────────────────────────────────
#   - openclaw-pre-start-heal.sh edge (ExecStartPre): so every edge restart —
#     including the one codex-canonical-refresh.sh performs right after it
#     rotates main's chain — boots on the CURRENT access token.
#   - codex-edge-mirror.timer (daily 04:30 UTC, after the 04:00 refresher):
#     belt for a missed pre-start; restarts edge only if it changed something.
#
# ── Env overrides ───────────────────────────────────────────────────────────
#   CODEX_AUTH_ROOT           sandbox root (default /root) — bats points this
#                             at a throwaway fleet so tests never touch live auth
#   CODEX_MIRROR_SOURCE       source profile (default main)
#   CODEX_MIRROR_TARGET       target profile (default edge)
#   CODEX_MIRROR_SERVICE      unit restarted by --restart
#                             (default openclaw-gateway-<target>.service)
#   CODEX_MIRROR_RESTART_LIB  path of the drain-restart library (default
#                             lib/gateway-restart.sh; tests stub it)
#   CODEX_MIRROR_PAGE_FN      name of a function taking one message and
#                             RETURNING the delivery status (default: lib/
#                             deploy-notify.sh critical; tests stub it)
#   CODEX_MIRROR_STATE_DIR    page-cooldown stamp dir (default /var/lib/hydra)
#   NOTIFY_UNIT_FAILED_MARKER_DIR  durable marker dir on failed delivery
#                             (default /var/lib/hydra/unit-failed-unpaged)
#   CODEX_MIRROR_MIN_TOKEN_MIN  freshness margin in minutes (default: the quota
#                             probe's CODEX_PROBE_MIN_TOKEN_MIN, else 60): a
#                             source token expiring inside it is REFUSED, never
#                             mirrored — edge cannot refresh (sentinel slot)
#   HYDRA_SELF_PAGED_DIR      stamp dir telling hydra-unit-failed@ that this
#                             unit already paged for its own failure
#   NODE_BIN                  node binary (default: node on PATH)
set -uo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=version-compare.sh
source "$SCRIPT_DIR/version-compare.sh"

CODEX_AUTH_ROOT="${CODEX_AUTH_ROOT:-/root}"
SOURCE_PROFILE="${CODEX_MIRROR_SOURCE:-main}"
TARGET_PROFILE="${CODEX_MIRROR_TARGET:-edge}"
SERVICE="${CODEX_MIRROR_SERVICE:-openclaw-gateway-${TARGET_PROFILE}.service}"
RESTART_LIB="${CODEX_MIRROR_RESTART_LIB:-$SCRIPT_DIR/gateway-restart.sh}"
NODE_BIN="${NODE_BIN:-node}"
SENTINEL_REFRESH="SYNC-MANAGED-NO-REFRESH-TOKEN"
RUNTIME_FLOOR="2026.8"
# ONE freshness margin, shared with codex-quota-probe.sh (which skips accounts
# expiring inside CODEX_PROBE_MIN_TOKEN_MIN so app-server never enters its
# refresh path). A mirrored token cannot be refreshed on edge (sentinel slot),
# so anything inside the margin is dead-on-arrival there.
MIN_TOKEN_MIN="${CODEX_MIRROR_MIN_TOKEN_MIN:-${CODEX_PROBE_MIN_TOKEN_MIN:-60}}"
[[ "$MIN_TOKEN_MIN" =~ ^[0-9]+$ ]] || { echo "[codex-edge-mirror] ERROR: CODEX_MIRROR_MIN_TOKEN_MIN must be an integer (minutes), got '$MIN_TOKEN_MIN'" >&2; exit 2; }

LOGPREFIX="[codex-edge-mirror $(date -u +%Y-%m-%dT%H:%M:%SZ)]"
log() { echo "$LOGPREFIX $*" >&2; }

MODE="ensure"
RESTART=0
for arg in "$@"; do
  case "$arg" in
    --check)   MODE="check" ;;
    --dry-run) MODE="dry-run" ;;
    --ensure)  MODE="ensure" ;;
    --restart) RESTART=1 ;;
    -h|--help) sed -n '2,90p' "$0"; exit 0 ;;
    *) log "ERROR: unknown argument: $arg (use --ensure, --check, --dry-run, --restart)"; exit 2 ;;
  esac
done
if [ "$RESTART" -eq 1 ] && [ "$MODE" != "ensure" ]; then
  log "ERROR: --restart only applies to ensure mode"
  exit 2
fi
if [ "$SOURCE_PROFILE" = "$TARGET_PROFILE" ]; then
  log "ERROR: source and target profile are both '$SOURCE_PROFILE' — a store cannot mirror itself"
  exit 2
fi

# ── paging seam (status-returning) ──────────────────────────────────────────
_mirror_page_default() {
  [ -r "$SCRIPT_DIR/deploy-notify.sh" ] || return 1
  bash "$SCRIPT_DIR/deploy-notify.sh" critical "$1"
}
PAGE_FN="${CODEX_MIRROR_PAGE_FN:-_mirror_page_default}"
_page() { "$PAGE_FN" "$1"; }
MIRROR_STATE_DIR="${CODEX_MIRROR_STATE_DIR:-/var/lib/hydra}"
MARKER_DIR="${NOTIFY_UNIT_FAILED_MARKER_DIR:-/var/lib/hydra/unit-failed-unpaged}"
PAGE_COOLDOWN_SECS="${CODEX_MIRROR_PAGE_COOLDOWN_SECS:-3600}"
PAGE_STAMP="$MIRROR_STATE_DIR/codex-edge-mirror.page-cooldown"
MARKER_UNIT="codex-edge-mirror@${TARGET_PROFILE}"
SELF_PAGED_DIR="${HYDRA_SELF_PAGED_DIR:-/var/lib/hydra/self-paged}"
# The systemd unit THIS script runs under (the OnFailure= source), not the
# gateway unit it restarts.
SELF_UNIT="${CODEX_MIRROR_SELF_UNIT:-codex-edge-mirror.service}"

# page_failure <message> — the ONE paging path for every failure of this
# script (see the header): never in --check; deduped by PAGE_STAMP; on a
# failed delivery a durable marker is left for cron-health-watchdog.sh and
# the stamp is still written (the watchdog's page covers the window).
page_failure() {
  local now last spool tmp delivered=0 spooled=0
  [ "$MODE" = "check" ] && return 0
  now="$(date -u +%s)"
  last="$(cat "$PAGE_STAMP" 2>/dev/null || echo 0)"
  case "$last" in (*[!0-9]*|"") last=0 ;; esac
  if [ $((now - last)) -lt "$PAGE_COOLDOWN_SECS" ] && [ $((now - last)) -ge 0 ]; then
    log "page suppressed: last page $((now - last))s ago (< ${PAGE_COOLDOWN_SECS}s cooldown)"
    return 0
  fi
  if _page "$1"; then
    log "paged #clio_devops"; delivered=1
  else
    # Spool: ONE record per file, written to a temp name, fsynced, renamed
    # into place — no producer ever holds an fd on a file the watchdog can
    # claim, and "spooled" below means the rename returned success.
    mkdir -p "$MARKER_DIR" 2>/dev/null || true
    spool="$MARKER_DIR/${MARKER_UNIT}.${now}.$$.unpaged"; tmp="$spool.tmp"
    if printf '%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$MARKER_UNIT" "$(printf '%s' "$1" | tr '\n\t' '  ' | cut -c1-400)" > "$tmp" 2>/dev/null \
       && { command -v sync >/dev/null 2>&1 && sync "$tmp" 2>/dev/null || true; } \
       && mv -f "$tmp" "$spool" 2>/dev/null; then
      log "page NOT delivered — durable marker ${spool} left for cron-health-watchdog"; spooled=1
    else
      rm -f "$tmp" 2>/dev/null
      log "WARN: page NOT delivered AND the marker could not be written under ${MARKER_DIR} — nothing surfaced this failure; no stamp, no cooldown: the OnFailure handler and the next run stay armed"
    fi
  fi
  # Stamps only AFTER a confirmed outcome (QA finding on #935, round 14):
  #   delivered page  → cooldown (we did page) + self-paged (handler must not double-page)
  #   spooled only    → self-paged (the watchdog pages the record; the handler
  #                     must not race it) but NO cooldown (nothing was paged
  #                     by us — the next run may try again / spool again)
  #   neither         → NOTHING: the OnFailure handler pages now and the next
  #                     run retries; a stamp here would be a silent outage.
  if [ "$delivered" -eq 1 ]; then
    mkdir -p "$MIRROR_STATE_DIR" 2>/dev/null || true
    printf '%s' "$now" > "$PAGE_STAMP" 2>/dev/null || true
  fi
  if [ "$delivered" -eq 1 ] || [ "$spooled" -eq 1 ]; then
    if [ "$RESTART" -eq 1 ]; then
      mkdir -p "$SELF_PAGED_DIR" 2>/dev/null || true
      printf '%s' "$now" > "$SELF_PAGED_DIR/$SELF_UNIT" 2>/dev/null || true
    fi
  fi
}

# unevaluated <reason> — exit 2 for every structural failure AFTER argument
# parsing, PAGING first in every mode but --check (see the header: an edge
# cell that vanished or a store that became unreadable must never leave
# Caroline on paid OpenRouter with only a journal line, whichever caller ran
# us). The systemd unit also carries OnFailure=hydra-unit-failed@%n for the
# failures that never reach bash.
unevaluated() {
  log "UNEVALUATED: $1 — nothing was written"
  page_failure "*codex edge mirror could NOT run* on node-8 (profile \`${TARGET_PROFILE}\`, source \`${SOURCE_PROFILE}\`, mode ${MODE}${RESTART:+, restart=$RESTART}) — $1. The \`${TARGET_PROFILE}\` auth cell was NOT converged and its gateway may be serving turns on the openrouter fallback. Run \`/opt/hydra/scripts/lib/codex-edge-mirror.sh --check\`; log: \`/var/log/codex-edge-mirror.log\`."
  exit 2
}

command -v "$NODE_BIN" >/dev/null 2>&1 || unevaluated "node not found (needed for node:sqlite)"

# ── runtime gate ────────────────────────────────────────────────────────────
runtime_ver="$(openclaw_runtime_version)"
if [ -z "$runtime_ver" ]; then
  unevaluated "cannot determine the openclaw runtime version (\`openclaw --version\` returned nothing/unparseable) — refusing to apply 2.0 auth-cell semantics to an unidentified box"
fi
if ! version_at_least "$RUNTIME_FLOOR" "$runtime_ver"; then
  log "not applicable on $runtime_ver (the shared auth cell exists only on openclaw >= $RUNTIME_FLOOR) — nothing to mirror"
  exit 0
fi

# --restart runs stand down inside a planned maintenance window: a human (or a
# deploy) is deliberately restarting gateways then, and this would add a second
# drain-restart on top (same reasoning as codex-canonical-refresh.sh). Decided
# BEFORE the write, never between write and restart — a converged-but-unloaded
# cell is the half-applied state this script exists to avoid. Fail-safe: an
# absent/expired/malformed flag reads as "not in maintenance". Plain --ensure
# (the ExecStartPre path) is unaffected: there the gateway is starting anyway.
if [ "$RESTART" -eq 1 ] && [ -r "$SCRIPT_DIR/maintenance-flag.sh" ]; then
  # shellcheck source=maintenance-flag.sh
  source "$SCRIPT_DIR/maintenance-flag.sh"
  if maintenance_active 2>/dev/null; then
    log "maintenance window open ($(maintenance_reason 2>/dev/null || echo 'unknown')) — standing down; the next edge start mirrors via ExecStartPre and the next tick retries"
    exit 0
  fi
fi

SOURCE_DB="$CODEX_AUTH_ROOT/.openclaw-$SOURCE_PROFILE/state/openclaw.sqlite"
TARGET_DB="$CODEX_AUTH_ROOT/.openclaw-$TARGET_PROFILE/state/openclaw.sqlite"

# ── node:sqlite helper — ONE process reads, derives, writes, verifies ───────
# argv after -e: <sourceDb> <targetDb> <mode> <sentinel> <minTokenMin>
# stdout: TAB-separated, value-free lines
#   PLAN|WRITTEN|UNCHANGED|PRUNED|REFUSED|FAILED|CHECK_OK|CHECK_FAIL <id> <detail>
#   SUMMARY <k=v ...>
# exit: 0 ok, 1 refused/failed/drift, 3 structural (source/target unusable)
NODE_HELPER='
const { DatabaseSync } = require("node:sqlite");
const fs = require("node:fs");
const [srcPath, dstPath, mode, sentinel, minTokenMinArg] = process.argv.slice(1);
const MIN_TTL_MS = Number(minTokenMinArg) * 60 * 1000;
const KEY = "authProfiles.store";
const AUTH_CLAIM = "https://api.openai.com/auth";
const SENTINEL_RE = /^(STAGING-|SYNC-MANAGED)/;
const out = (kind, id, detail) => process.stdout.write(`${kind}\t${id}\t${detail}\n`);
function die(code, msg) { console.error(msg); process.exit(code); }

function openDb(p, readOnly) {
  const db = new DatabaseSync(p, { readOnly });
  db.exec("pragma busy_timeout=5000");
  return db;
}
// readCell: {tableAbsent} | {rowAbsent} | {invalid} | {store}
function readCell(db) {
  let r;
  try {
    r = db.prepare("select value_json from config_machine_state where state_key=?").get(KEY);
  } catch (e) {
    if (/no such table/i.test(String(e.message))) return { tableAbsent: true };
    throw e;
  }
  if (!r) return { rowAbsent: true };
  let j;
  try { j = JSON.parse(r.value_json); } catch (e) { return { invalid: `value_json is not JSON: ${e.message}` }; }
  if (!j || typeof j !== "object" || Array.isArray(j) || !j.profiles || typeof j.profiles !== "object" || Array.isArray(j.profiles)) {
    return { invalid: ".profiles is absent or not an object" };
  }
  return { store: j };
}
// The runtime decodes this claim from the access token and THROWS when it
// differs from the stored accountId (buildChatgptAuthTokensParams).
function jwtAccountId(tok) {
  if (typeof tok !== "string") return undefined;
  const payload = tok.split(".")[1];
  if (!payload) return undefined;
  try {
    const j = JSON.parse(Buffer.from(payload, "base64url").toString("utf8"));
    const auth = j && typeof j === "object" ? j[AUTH_CLAIM] : undefined;
    const id = auth && typeof auth === "object" ? auth.chatgpt_account_id : undefined;
    return typeof id === "string" && id.trim() ? id.trim() : undefined;
  } catch { return undefined; }
}
const isRealRefresh = (r) => typeof r === "string" && r.length > 0 && !SENTINEL_RE.test(r);
// jwtExpMs: the exp claim of the access token itself (ms), when decodable.
function jwtExpMs(tok) {
  if (typeof tok !== "string") return undefined;
  const payload = tok.split(".")[1];
  if (!payload) return undefined;
  try { const j = JSON.parse(Buffer.from(payload, "base64url").toString("utf8")); return typeof j.exp === "number" ? j.exp * 1000 : undefined; } catch { return undefined; }
}
// freshness: the ONE predicate derive() (ensure/dry-run/check alike) applies —
// a token must be safely in the future by MIN_TTL_MS on BOTH its stored
// `expires` and its JWT `exp` (when present). Edge cannot refresh a mirrored
// token (sentinel slot), so an expired or nearly-expired one is dead on
// arrival there and must never be mirrored, reported UNCHANGED or CHECK_OK.
function staleness(p) {
  const now = Date.now(), floor = now + MIN_TTL_MS;
  const iso = (ms) => new Date(ms).toISOString();
  if (p.expires <= now) return `access token EXPIRED at ${iso(p.expires)}`;
  if (p.expires <= floor) return `access token expires at ${iso(p.expires)} — inside the ${MIN_TTL_MS / 60000}min freshness margin`;
  const exp = jwtExpMs(p.access);
  if (exp !== undefined && exp <= floor) return `access token JWT exp ${iso(exp)} is inside the ${MIN_TTL_MS / 60000}min freshness margin (stored expires ${iso(p.expires)} disagrees)`;
  return undefined;
}
const summary = (d) => `access_len=${d.access.length} accountId=${d.accountId} expires=${new Date(d.expires).toISOString()} plan=${d.chatgptPlanType || "-"} idToken=${d.idToken ? "yes" : "no"} refresh=sentinel`;
const canon = (o) => JSON.stringify(Object.keys(o).sort().map((k) => [k, o[k]]));

// WHITELIST derivation. Field order matches the migrated cell so diffs read
// naturally; the refresh slot is ALWAYS the sentinel.
function derive(p) {
  const errs = [];
  if (!p || typeof p !== "object") return { err: "profile is not an object" };
  if (p.type !== undefined && p.type !== "oauth") errs.push(`type=${p.type} (expected oauth)`);
  if (typeof p.access !== "string" || !p.access) errs.push("access missing");
  if (typeof p.accountId !== "string" || !p.accountId.trim()) errs.push("accountId missing");
  if (typeof p.expires !== "number" || !Number.isFinite(p.expires)) errs.push("expires missing");
  if (typeof p.refresh !== "string" || !p.refresh) errs.push("source refresh missing (canonical must hold the real chain)");
  else if (SENTINEL_RE.test(p.refresh)) errs.push("source refresh is a SENTINEL — the source is a derived store, not canonical; never mirror a mirror");
  if (errs.length) return { err: errs.join("; ") };
  const stale = staleness(p);
  if (stale) return { err: stale };
  const claim = jwtAccountId(p.access);
  if (!claim) return { err: "access token carries no decodable chatgpt_account_id claim" };
  if (claim !== p.accountId.trim()) return { err: `stored accountId ${p.accountId} != token claim ${claim} (the runtime throws on this mismatch)` };
  const d = { type: "oauth", provider: "openai" };
  if (typeof p.email === "string" && p.email) d.email = p.email;
  d.access = p.access;
  d.refresh = sentinel;
  if (typeof p.idToken === "string" && p.idToken) d.idToken = p.idToken;
  d.accountId = p.accountId.trim();
  if (typeof p.chatgptPlanType === "string" && p.chatgptPlanType) d.chatgptPlanType = p.chatgptPlanType;
  d.expires = p.expires;
  return { d };
}

// ── source ──────────────────────────────────────────────────────────────────
if (!fs.existsSync(srcPath)) die(3, `source store not found: ${srcPath}`);
let src;
try { src = openDb(srcPath, true); } catch (e) { die(3, `source open failed: ${e.message}`); }
// loadSource: the source is re-read AFTER the target verification too (see
// the end of the ensure path): main can rotate its access token between our
// first read and the last target transaction, and a run that validated the
// target against a stale in-memory snapshot would exit 0 and load the OLD
// token into edge (QA finding on #935, round 11).
function loadSource() {
  let cell;
  try { cell = readCell(src); } catch (e) { die(3, `source read failed: ${e.message}`); }
  if (cell.tableAbsent) die(3, `source ${srcPath} has no config_machine_state table (un-migrated store)`);
  if (cell.rowAbsent) die(3, `source ${srcPath} has no authProfiles.store row — nothing canonical to mirror`);
  if (cell.invalid) die(3, `source authProfiles.store: ${cell.invalid}`);
  const profiles = Object.entries(cell.store.profiles).filter(([k]) => k.startsWith("openai:"));
  if (profiles.length === 0) die(3, "source authProfiles.store holds no openai:* profiles");
  return { s: cell, srcProfiles: profiles, realRefresh: new Set(profiles.map(([, p]) => p && p.refresh).filter(isRealRefresh)) };
}
let s, srcProfiles, realRefresh;
({ s, srcProfiles, realRefresh } = loadSource());
// sourceSig: canonical signature of what the mirror would DERIVE from a source
// profile set (errors included) — the thing that must be stable across a run.
const sourceSig = (profiles) => canon(Object.fromEntries(profiles.map(([id, p]) => { const r = derive(p); return [id, r.d ? canon(r.d) : `ERR:${r.err}`]; })));

// ── target ──────────────────────────────────────────────────────────────────
if (!fs.existsSync(dstPath)) die(3, `target store not found: ${dstPath} (its gateway has never run / doctor never created it)`);
let dst;
try { dst = openDb(dstPath, mode !== "ensure"); } catch (e) { die(3, `target open failed: ${e.message}`); }
let t;
try { t = readCell(dst); } catch (e) { die(3, `target read failed: ${e.message}`); }
if (t.tableAbsent) die(3, `target ${dstPath} has no config_machine_state table — un-migrated store; refusing to create it`);
if (t.invalid) die(3, `target authProfiles.store: ${t.invalid}`);
let tStore = t.store || null;

// leakScan: any string value anywhere in the target cell equal to a source
// refresh token. Belt over the whitelist — the single-refresher invariant.
function leakScan(store) {
  const hits = [];
  const walk = (v, path) => {
    if (typeof v === "string") { if (realRefresh.has(v)) hits.push(path); return; }
    if (v && typeof v === "object") for (const [k, x] of Object.entries(v)) walk(x, `${path}.${k}`);
  };
  walk(store, "$");
  return hits;
}

// ── --check ─────────────────────────────────────────────────────────────────
if (mode === "check") {
  let ok = 0, fail = 0;
  for (const [id, p] of srcProfiles) {
    const r = derive(p);
    if (r.err) { out("CHECK_FAIL", id, `source profile unusable: ${r.err}`); fail++; continue; }
    if (!tStore) { out("CHECK_FAIL", id, "target authProfiles.store row ABSENT"); fail++; continue; }
    const cur = tStore.profiles[id];
    if (!cur || typeof cur !== "object") { out("CHECK_FAIL", id, "missing from target"); fail++; continue; }
    const problems = [];
    if (cur.refresh !== sentinel) problems.push(isRealRefresh(cur.refresh) ? "refresh slot holds a REAL token (fan-out)" : "refresh slot is not the mirror sentinel");
    if (cur.access !== r.d.access) problems.push("access STALE (differs from source)");
    if (cur.accountId !== r.d.accountId) problems.push("accountId differs from source");
    const claim = jwtAccountId(cur.access);
    if (!claim) problems.push("mirrored access token carries no decodable chatgpt_account_id claim");
    else if (claim !== cur.accountId) problems.push(`stored accountId ${cur.accountId} != token claim ${claim} (runtime would THROW)`);
    if (cur.expires !== r.d.expires) problems.push("expires differs from source");
    // Exact mirror equality of the WHOLE canonicalized profile — type, provider,
    // email, chatgptPlanType, idToken and any unexpected extra field included.
    // The named checks above give the operator the precise reason; this one
    // is the invariant (QA finding on #935, round 7: a profile with type
    // flipped to api_key and its token fields intact read CHECK_OK).
    if (canon(cur) !== canon(r.d)) {
      const diff = [...new Set([...Object.keys(cur), ...Object.keys(r.d)])].filter((k) => JSON.stringify(cur[k]) !== JSON.stringify(r.d[k])).sort();
      problems.push(`profile differs from the source-derived value (fields: ${diff.join(",")})`);
    }
    if (problems.length) { out("CHECK_FAIL", id, problems.join("; ")); fail++; } else { out("CHECK_OK", id, summary(cur)); ok++; }
  }
  if (tStore) {
    for (const id of Object.keys(tStore.profiles)) {
      if (id.startsWith("openai:") && !s.store.profiles[id]) { out("CHECK_FAIL", id, "extra openai:* profile on target, absent from source"); fail++; }
    }
    for (const hit of leakScan(tStore)) { out("CHECK_FAIL", hit, "REAL source refresh token present in target cell"); fail++; }
  }
  out("SUMMARY", "-", `ok=${ok} fail=${fail}`);
  process.exit(fail > 0 ? 1 : 0);
}

// ── --ensure / --dry-run ────────────────────────────────────────────────────
const dry = mode === "dry-run";
let written = 0, unchanged = 0, pruned = 0, refused = 0, failed = 0;
const refusedIds = new Set();   // profiles this run deliberately left alone
const expectedById = new Map(); // what every non-refused source profile must equal at the end

// replaceProfile: ONE transaction; re-reads the cell inside it so a concurrent
// writer (the runtime, a mint) can never be clobbered by our earlier snapshot.
// transact: ONE transaction per profile. The cell is RE-READ inside BEGIN
// IMMEDIATE and the real-refresh refusal is RE-EVALUATED there — the pre-check
// on the initial snapshot is only a fast path. Without this, a real refresh
// token committed for this profile between the pre-check and the transaction
// (the runtime, a device login, an operator) would be overwritten or pruned
// despite the documented refusal (QA finding on #935). Returns
// "written" | "refused" | "failed".
//   CODEX_MIRROR_TEST_HOOK_BEFORE_TXN: test seam — a shell command run right
//   before BEGIN IMMEDIATE so a concurrent writer can be injected
//   deterministically. Never set in production units.
function transact(mutate, id, verb) {
  try {
    if (process.env.CODEX_MIRROR_TEST_HOOK_BEFORE_TXN) {
      require("node:child_process").execSync(process.env.CODEX_MIRROR_TEST_HOOK_BEFORE_TXN, { stdio: "inherit" });
    }
    dst.exec("BEGIN IMMEDIATE");
    const fresh = readCell(dst);
    if (fresh.tableAbsent) throw new Error("config_machine_state vanished");
    if (fresh.invalid) throw new Error(`target cell became invalid: ${fresh.invalid}`);
    const store = fresh.rowAbsent ? { version: 1, profiles: {} } : fresh.store;
    const live = store.profiles[id];
    if (live && typeof live === "object" && isRealRefresh(live.refresh)) {
      dst.exec("ROLLBACK");
      tStore = store;
      out("REFUSED", id, `target gained a REAL refresh token before the ${verb} transaction — an independent chain; leaving it byte-identical`);
      refused++; refusedIds.add(id);
      return "refused";
    }
    mutate(store);
    const vj = JSON.stringify(store);
    const now = Date.now();
    if (fresh.rowAbsent) {
      dst.prepare("insert into config_machine_state (state_key, value_json, updated_at_ms) values (?,?,?)").run(KEY, vj, now);
    } else {
      const res = dst.prepare("update config_machine_state set value_json=?, updated_at_ms=? where state_key=?").run(vj, now, KEY);
      if (res.changes !== 1) throw new Error(`expected 1 row updated, got ${res.changes}`);
    }
    dst.exec("COMMIT");
    tStore = store;
    return "written";
  } catch (e) {
    try { dst.exec("ROLLBACK"); } catch { /* nothing open */ }
    out("FAILED", id, `${verb} failed: ${e.message}`);
    failed++;
    return "failed";
  }
}

// ensurePass: one full convergence pass (profiles → prune → post-write
// verification) against the CURRENT source snapshot. Run again if the source
// moved under us.
function ensurePass() {
refusedIds.clear(); expectedById.clear();
for (const [id, p] of srcProfiles) {
  const r = derive(p);
  if (r.err) { out("REFUSED", id, r.err); refused++; continue; }
  // Fast-path refusal on the initial snapshot; transact() re-checks INSIDE the
  // transaction, which is the check that actually holds.
  const cur = tStore ? tStore.profiles[id] : undefined;
  if (cur && typeof cur === "object" && isRealRefresh(cur.refresh)) {
    out("REFUSED", id, "target holds a REAL refresh token — an independent chain someone logged in deliberately; refusing to overwrite it (log it out first)");
    refused++; refusedIds.add(id);
    continue;
  }
  expectedById.set(id, r.d);
  if (cur && typeof cur === "object" && canon(cur) === canon(r.d)) { out("UNCHANGED", id, summary(r.d)); unchanged++; continue; }
  const verb = cur ? "replace" : "add", done = cur ? "replaced" : "added";
  if (dry) { out("PLAN", id, `would ${verb}: ${summary(r.d)}`); written++; continue; }
  if (transact((store) => { store.profiles[id] = r.d; }, id, verb) === "written") { out("WRITTEN", id, `${done}: ${summary(r.d)}`); written++; }
}

// Extras: openai:* profiles on the target that the source no longer has.
if (tStore) {
  for (const id of Object.keys(tStore.profiles)) {
    if (!id.startsWith("openai:") || s.store.profiles[id]) continue;
    const cur = tStore.profiles[id];
    if (cur && typeof cur === "object" && isRealRefresh(cur.refresh)) {
      out("REFUSED", id, "extra profile on target holds a REAL refresh token — not ours to prune (log it out deliberately)");
      refused++; refusedIds.add(id);
      continue;
    }
    if (dry) { out("PLAN", id, "would prune: stale sentinel-bearing mirror profile absent from source"); pruned++; continue; }
    if (transact((store) => { delete store.profiles[id]; }, id, "prune") === "written") { out("PRUNED", id, "stale sentinel-bearing mirror profile absent from source"); pruned++; }
  }
}

// Post-write verification (ensure only): the cell we just left behind must not
// carry any real source refresh token (whitelist AND belt) — and no target
// openai:* profile may hold ANY real refresh token at all. The per-transaction
// refusal only guards the profile being written: a device login or the runtime
// can commit an independent chain into profile A after the A transaction while
// the B transaction is still running, and equality with the source tokens would
// never see it (QA finding on #935, round 4). A real token anywhere means
// --restart would load an independent chain, so this is FAILED, never success.
if (!dry && tStore) {
  let verify;
  try { verify = readCell(dst); } catch (e) { out("FAILED", "-", `post-write re-read failed: ${e.message}`); failed++; verify = null; }
  if (verify && verify.store) {
    for (const hit of leakScan(verify.store)) { out("FAILED", hit, "REAL source refresh token present in target cell after write — single-refresher invariant VIOLATED"); failed++; }
    // Profiles already REFUSED above are known and reported (exit 1); this
    // catches the ones the run believed it owned.
    for (const [id, pr] of Object.entries(verify.store.profiles)) {
      if (refusedIds.has(id)) continue;
      if (id.startsWith("openai:") && pr && typeof pr === "object" && isRealRefresh(pr.refresh)) {
        out("FAILED", id, "target profile holds a REAL refresh token after the mirror ran (an independent chain was written concurrently) — refusing to report success or restart");
        failed++;
      }
    }
    // The same equality + profile-set validation --check applies, on the cell
    // we actually left behind. Each profile commits in its own transaction
    // and nothing outside this script honours our flock, so a writer that
    // restores an older cell or deletes profile A between the A and B
    // transactions leaves A stale/missing while B re-reads that cell and
    // updates only itself; a real-token scan alone sees nothing wrong and
    // --restart would load the stale A (QA finding on #935, round 6).
    for (const [id, want] of expectedById) {
      const got = verify.store.profiles[id];
      if (!got || typeof got !== "object") { out("FAILED", id, "target profile MISSING after the mirror ran (removed by a concurrent writer) — refusing to report success or restart"); failed++; continue; }
      if (isRealRefresh(got.refresh)) continue;   // already reported above
      if (canon(got) !== canon(want)) { out("FAILED", id, "target profile DRIFTED from the source-derived value after the mirror ran (rewritten by a concurrent writer) — refusing to report success or restart"); failed++; }
    }
    // Identical openai:* key sets: an extra that appeared after the prune pass
    // enumerated its candidates (i.e. during a prune transaction, or after the
    // last profile transaction) is on the cell we would load. A sentinel extra
    // that appeared EARLIER is pruned normally (pinned by a test).
    for (const id of Object.keys(verify.store.profiles)) {
      if (id.startsWith("openai:") && !s.store.profiles[id] && !refusedIds.has(id)) {
        out("FAILED", id, "extra openai:* profile on target after the mirror ran (appeared during the run) — refusing to report success or restart"); failed++;
      }
    }
  } else if (verify && !verify.store) {
    out("FAILED", "-", "post-write re-read found no valid authProfiles.store row"); failed++;
  }
}
}

ensurePass();
if (!dry) {
  // Source staleness gate: re-read the source AFTER the target verification.
  // If what we would derive from it changed while we ran (a rotation on
  // main), converge ONCE more against the fresh source and check again; a
  // source that keeps moving is FAILED — never a success that --restart
  // would load a stale token from.
  const before = sourceSig(srcProfiles);
  ({ s, srcProfiles, realRefresh } = loadSource());
  if (sourceSig(srcProfiles) !== before) {
    out("SOURCE_CHANGED", "-", "source cell changed during the run (rotation?) — re-converging once against the fresh source");
    const before2 = sourceSig(srcProfiles);
    ensurePass();
    ({ s, srcProfiles, realRefresh } = loadSource());
    if (sourceSig(srcProfiles) !== before2) {
      out("FAILED", "-", "source cell changed AGAIN during the retry — refusing to report success or restart (the next run converges)"); failed++;
    }
  }
}

out("SUMMARY", "-", `written=${written} unchanged=${unchanged} pruned=${pruned} refused=${refused} failed=${failed}`);
process.exit(refused + failed > 0 ? 1 : 0);
'

# ── serialize concurrent mirrors (timer vs pre-start vs operator) ───────────
MIRROR_LOCK="$CODEX_AUTH_ROOT/.openclaw-$TARGET_PROFILE/state/.codex-edge-mirror.lock"
if [ -d "$(dirname "$MIRROR_LOCK")" ]; then
  exec 9>"$MIRROR_LOCK" || unevaluated "cannot open mirror lock $MIRROR_LOCK"
  if ! flock -w "${CODEX_MIRROR_LOCK_WAIT_SECS:-120}" 9; then
    unevaluated "another mirror holds $MIRROR_LOCK for >${CODEX_MIRROR_LOCK_WAIT_SECS:-120}s — not proceeding"
  fi
fi

log "mode=$MODE source=$SOURCE_DB target=$TARGET_DB (runtime $runtime_ver)"
# node's stderr carries structural diagnostics (never token bytes): logged, and
# kept so a timer-path page can name the store and the reason. stdout is the
# machine channel, echoed line-by-line below.
helper_out=""
helper_err=""
helper_rc=0
helper_err_file="$(mktemp "${TMPDIR:-/tmp}/codex-edge-mirror.err.XXXXXX")" || unevaluated "cannot create a temp file for the helper's diagnostics"
helper_out="$("$NODE_BIN" --experimental-sqlite --no-warnings -e "$NODE_HELPER" \
  "$SOURCE_DB" "$TARGET_DB" "$MODE" "$SENTINEL_REFRESH" "$MIN_TOKEN_MIN" 2>"$helper_err_file")" || helper_rc=$?
helper_err="$(tr '\n' ' ' < "$helper_err_file")"; rm -f "$helper_err_file"
[ -n "$helper_err" ] && log "$helper_err"
[ -n "$helper_out" ] && printf '%s\n' "$helper_out"

[ "$helper_rc" -eq 3 ] && unevaluated "a store could not be used: ${helper_err:-see the log}"
if [ "$helper_rc" -ne 0 ] && [ "$helper_rc" -ne 1 ]; then
  unevaluated "helper exited $helper_rc unexpectedly"
fi

summary="$(printf '%s\n' "$helper_out" | awk -F'\t' '$1=="SUMMARY" {print $3}' | tail -1)"
[ -n "$summary" ] || unevaluated "helper emitted no SUMMARY line — refusing to guess what happened"

case "$MODE" in
  check)
    if [ "$helper_rc" -ne 0 ]; then
      log "DRIFT DETECTED ($summary): $TARGET_PROFILE's cell does not mirror $SOURCE_PROFILE's — run $(basename "$0") to converge, then restart $SERVICE"
      exit 1
    fi
    log "clean ($summary): $TARGET_PROFILE's openai:* profiles mirror $SOURCE_PROFILE's access credentials; refresh slots are sentinels"
    exit 0
    ;;
  dry-run)
    log "dry-run ($summary): nothing written"
    exit "$helper_rc"
    ;;
esac

# ── ensure: report, then restart only when something actually changed ───────
written="$(printf '%s\n' "$summary" | awk '{ for (i = 1; i <= NF; i++) if ($i ~ /^written=[0-9]+$/) { sub(/^written=/, "", $i); print $i } }')"
[ -n "$written" ] || unevaluated "SUMMARY carries no written= count — refusing to decide on a restart"

if [ "$helper_rc" -ne 0 ]; then
  log "ensure INCOMPLETE ($summary) — see the REFUSED/FAILED lines above"
  page_failure "*codex edge mirror INCOMPLETE* on node-8 (${summary}, mode ${MODE}, restart=${RESTART}) — at least one openai:* profile was NOT mirrored into ${TARGET_PROFILE}'s auth cell (a refused profile holds an independent refresh chain, or the cell changed under us); Caroline may be on the openrouter fallback for that account. See \`/var/log/codex-edge-mirror.log\`."
fi

if [ "$written" -lt 1 ]; then
  [ "$helper_rc" -eq 0 ] && log "converged ($summary) — nothing changed, no restart needed"
  exit "$helper_rc"
fi

# Restart ONLY a fully clean run. A REFUSED profile means a real refresh token
# (an independent chain) sits in the target; a FAILED post-write check means
# one appeared while we ran. Restarting would load that chain into the gateway
# under our name — the single-refresher invariant this script exists to keep.
if [ "$helper_rc" -ne 0 ]; then
  log "NOT restarting $SERVICE: the run was not clean ($summary) — the written profiles load on the next start once the target is clean"
  exit "$helper_rc"
fi

if [ "$RESTART" -ne 1 ]; then
  log "converged ($summary) — restart $SERVICE to load the new credentials (or let its next start pick them up)"
  exit "$helper_rc"
fi

# (The maintenance stand-down was decided above, BEFORE the write — never here,
# between write and restart.)
if [ ! -r "$RESTART_LIB" ]; then
  log "ERROR: $RESTART_LIB missing or unreadable — the cell CHANGED but $SERVICE cannot be restarted from here"
  page_failure "*codex edge mirror* wrote new credentials into ${TARGET_PROFILE}'s auth cell on node-8 but \`$(basename "$RESTART_LIB")\` is missing, so \`${SERVICE}\` was NOT restarted and still serves the old credentials. Restart it by hand."
  exit 6
fi
# shellcheck source=gateway-restart.sh
source "$RESTART_LIB"
GATEWAY_FALLBACK_NOTIFY_FN="${GATEWAY_FALLBACK_NOTIFY_FN:-_page}"
export GATEWAY_FALLBACK_NOTIFY_FN
if drain_restart_gateway "$SERVICE" "$TARGET_PROFILE"; then
  log "$SERVICE restarted — mirrored credentials loaded (written=$written)"
  exit "$helper_rc"
fi
log "ERROR: $SERVICE restart FAILED — the mirrored credentials are persisted but NOT loaded"
page_failure "*codex edge mirror wrote ${written} profile(s) but the ${SERVICE} restart FAILED* on node-8 — the cell is converged but the running gateway still serves the OLD credentials. Run \`systemctl status ${SERVICE}\` now."
exit 6
