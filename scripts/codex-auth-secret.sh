#!/usr/bin/env bash
# codex-auth-secret.sh — carry the codex (ChatGPT OAuth) ACCESS credentials from
# Caroline's canonical auth cell to the qa-review-gateway pods, through ONE
# Kubernetes Secret, without ever moving a real refresh token.
#
# 2026-10-28 (node8-to-pods T9; firstmate plan data/node8-to-pods-fable-a2/plan.md
# §2d "model quota"; security-arch-fable-s1 BLOCKING note: "the codex-auth Secret
# writer must copy ACCESS credentials only with the SYNC-MANAGED-NO-REFRESH-TOKEN
# sentinel (single-refresher invariant)").
#
# ── Why it reuses codex-edge-mirror.sh instead of deriving a payload itself ──
# The derivation (whitelisted fields, sentinel refresh slot, accountId == token
# claim, freshness margin, "never mirror a mirror", leak scan) already exists,
# was QA'd for 14 rounds on #935, and keeps edge alive today. A second copy of
# it here would drift. So `export` points lib/codex-edge-mirror.sh at a scratch
# fleet: source `main` = the real canonical cell (read-only), target `qa` = a
# throwaway cell in a temp dir. Whatever the mirror converges that scratch cell
# to IS the Secret payload. This script only adds the extraction, a second
# sentinel-only belt, and the kubectl write.
#
# The real refresh token stays in main's cell, whose ONLY writer remains
# codex-canonical-refresh.sh (Sun+Wed 04:00 UTC). The pods can never rotate the
# chain: every refresh slot they receive is the sentinel, and `import` refuses
# a payload that carries anything else.
#
# ── Modes ────────────────────────────────────────────────────────────────────
#   export  --out FILE           derive the payload into FILE (0600). Writer side.
#   publish [--out FILE]         export, then server-side-apply it as the Secret
#                                $CODEX_AUTH_SECRET_NAMESPACE/$CODEX_AUTH_SECRET_NAME
#                                (key auth-profiles.store.json). Writer CronJob.
#   import  --in FILE            write FILE into THIS process's own state cell
#                                ($OPENCLAW_STATE_DIR/state/openclaw.sqlite):
#                                authProfiles.store + auth.sharedStore=state-db.
#                                Pod side, before the gateway starts.
#   verify  --in FILE            read-only: FILE is a well-formed, sentinel-only
#                                payload with no token inside the freshness margin.
# Exit: 0 ok | 1 refused (stale token, a real refresh token seen, a profile the
# mirror refused) | 2 structural (usage, missing store, node/kubectl absent).
# A refused export publishes NOTHING: the previous Secret (still fresh for
# days) keeps serving, and the CronJob's failed run is the page.
#
# Tokens never cross argv: node reads and writes files; bash passes paths. stdout
# carries only value-free summary lines.
#
# ── Env ──────────────────────────────────────────────────────────────────────
#   CODEX_AUTH_ROOT              root holding .openclaw-main/state (default /root;
#                                the writer CronJob mounts node-8's copy there)
#   CODEX_AUTH_SECRET_NAMESPACE  default hydra-qa
#   CODEX_AUTH_SECRET_NAME       default qa-codex-auth
#   CODEX_AUTH_SECRET_MIN_TOKEN_MIN  freshness margin, minutes (default 1440 = 1 day:
#                                a pod cannot refresh, and the Secret is re-read only
#                                on a rollout, so a token must outlive the next run
#                                by a wide margin)
#   CODEX_AUTH_SECRET_IMPORT_MIN_TOKEN_MIN  the pod-side margin for import/verify
#                                (default 60, the mirror's own): a pod restarted
#                                late in a token's life still boots; one inside
#                                the hour refuses, rather than boot onto a token
#                                it cannot refresh
#   CODEX_AUTH_MIRROR            mirror path (default lib/codex-edge-mirror.sh)
#   KUBECTL / NODE_BIN           binaries (default kubectl / node)
set -uo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SENTINEL_REFRESH="SYNC-MANAGED-NO-REFRESH-TOKEN"
NODE_BIN="${NODE_BIN:-node}"
KUBECTL="${KUBECTL:-kubectl}"
MIRROR="${CODEX_AUTH_MIRROR:-$SCRIPT_DIR/lib/codex-edge-mirror.sh}"
CODEX_AUTH_ROOT="${CODEX_AUTH_ROOT:-/root}"
SECRET_NS="${CODEX_AUTH_SECRET_NAMESPACE:-hydra-qa}"
SECRET_NAME="${CODEX_AUTH_SECRET_NAME:-qa-codex-auth}"
SECRET_KEY="auth-profiles.store.json"
MIN_TOKEN_MIN="${CODEX_AUTH_SECRET_MIN_TOKEN_MIN:-1440}"
IMPORT_MIN_TOKEN_MIN="${CODEX_AUTH_SECRET_IMPORT_MIN_TOKEN_MIN:-60}"

LOGPREFIX="[codex-auth-secret $(date -u +%Y-%m-%dT%H:%M:%SZ)]"
log() { echo "$LOGPREFIX $*" >&2; }
die() { log "ERROR: $2"; exit "$1"; }

[[ "$MIN_TOKEN_MIN" =~ ^[0-9]+$ ]] || die 2 "CODEX_AUTH_SECRET_MIN_TOKEN_MIN must be an integer (minutes), got '$MIN_TOKEN_MIN'"
[[ "$IMPORT_MIN_TOKEN_MIN" =~ ^[0-9]+$ ]] || die 2 "CODEX_AUTH_SECRET_IMPORT_MIN_TOKEN_MIN must be an integer (minutes), got '$IMPORT_MIN_TOKEN_MIN'"
[[ "$SECRET_NS" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || die 2 "bad namespace '$SECRET_NS'"
[[ "$SECRET_NAME" =~ ^[a-z0-9]([-a-z0-9.]*[a-z0-9])?$ ]] || die 2 "bad secret name '$SECRET_NAME'"

MODE="${1:-}"; shift || true
IN=""; OUT=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --in)  IN="${2:-}"; shift 2 ;;
    --out) OUT="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,60p' "$0"; exit 0 ;;
    *) die 2 "unknown argument: $1" ;;
  esac
done
command -v "$NODE_BIN" >/dev/null 2>&1 || die 2 "node not found (needed for node:sqlite)"

# ── the payload checker/importer: ONE node program, two modes ───────────────
# argv: verify <file> <sentinel> <minTokenMin>
#       import <file> <sentinel> <minTokenMin> <stateDb>
#       extract <stateDb> <outFile> <sentinel> <minTokenMin>
# A payload is {"version":1,"profiles":{"openai:<email>":{...}}} where EVERY
# profile is type oauth / provider openai, carries access + accountId (equal to
# the token's chatgpt_account_id claim) + a future expires, and a refresh slot
# that is EXACTLY the sentinel. Anything else is refused whole.
NODE_PROG='
const { DatabaseSync } = require("node:sqlite");
const fs = require("node:fs");
const [mode, a1, a2, a3, a4] = process.argv.slice(1);
const AUTH_CLAIM = "https://api.openai.com/auth";
const ALLOWED = new Set(["type","provider","email","access","refresh","idToken","accountId","chatgptPlanType","expires"]);
const say = (k, id, d) => process.stdout.write(`${k}\t${id}\t${d}\n`);
function die(code, msg) { console.error(msg); process.exit(code); }
function claimOf(tok) {
  const p = typeof tok === "string" ? tok.split(".")[1] : undefined;
  if (!p) return undefined;
  try { return JSON.parse(Buffer.from(p, "base64url").toString("utf8")); } catch { return undefined; }
}
function check(store, sentinel, minMin) {
  if (!store || typeof store !== "object" || Array.isArray(store)) return ["payload is not an object"];
  const keys = Object.keys(store).filter((k) => k !== "version" && k !== "profiles");
  const errs = keys.length ? [`unexpected top-level keys: ${keys.join(",")}`] : [];
  if (!store.profiles || typeof store.profiles !== "object" || Array.isArray(store.profiles)) return [...errs, ".profiles absent"];
  const ids = Object.keys(store.profiles);
  if (ids.length === 0) errs.push("no profiles");
  const floor = Date.now() + minMin * 60000;
  for (const id of ids) {
    const p = store.profiles[id];
    const e = [];
    if (!id.startsWith("openai:")) e.push("id is not openai:*");
    if (!p || typeof p !== "object") { errs.push(`${id}: not an object`); continue; }
    const extra = Object.keys(p).filter((k) => !ALLOWED.has(k));
    if (extra.length) e.push(`non-whitelisted fields: ${extra.join(",")}`);
    if (p.type !== "oauth" || p.provider !== "openai") e.push("type/provider is not oauth/openai");
    if (p.refresh !== sentinel) e.push("refresh slot is NOT the sentinel (a real refresh token must never leave the canonical cell)");
    if (typeof p.access !== "string" || !p.access) e.push("access missing");
    const c = claimOf(p.access);
    const acct = c && c[AUTH_CLAIM] && c[AUTH_CLAIM].chatgpt_account_id;
    if (typeof p.accountId !== "string" || acct !== p.accountId) e.push("accountId does not equal the token claim");
    if (typeof p.expires !== "number" || p.expires <= floor) e.push(`expires is inside the ${minMin}min freshness margin`);
    if (c && typeof c.exp === "number" && c.exp * 1000 <= floor) e.push("JWT exp is inside the freshness margin");
    if (e.length) errs.push(`${id}: ${e.join("; ")}`);
  }
  return errs;
}
function readJson(f) {
  let raw;
  try { raw = fs.readFileSync(f, "utf8"); } catch (e) { die(2, `cannot read ${f}: ${e.message}`); }
  try { return JSON.parse(raw); } catch (e) { die(1, `${f} is not JSON`); }
}
const summary = (store) => Object.entries(store.profiles).map(([id, p]) => `${id} access_len=${p.access.length} expires=${new Date(p.expires).toISOString()} refresh=sentinel`);
function verifyOrDie(store, sentinel, minMin) {
  const errs = check(store, sentinel, minMin);
  if (errs.length) { for (const x of errs) say("REFUSED", "-", x); process.exit(1); }
}
if (mode === "verify") {
  const store = readJson(a1);
  verifyOrDie(store, a2, Number(a3));
  for (const l of summary(store)) say("OK", "-", l);
} else if (mode === "extract") {
  // a1 = scratch state db the mirror converged, a2 = out file
  let db;
  try { db = new DatabaseSync(a1, { readOnly: true }); } catch (e) { die(2, `scratch open failed: ${e.message}`); }
  const r = db.prepare("select value_json from config_machine_state where state_key=?").get("authProfiles.store");
  if (!r) die(1, "mirror left no authProfiles.store row in the scratch cell");
  const store = JSON.parse(r.value_json);
  const out = { version: 1, profiles: Object.fromEntries(Object.entries(store.profiles || {}).filter(([k]) => k.startsWith("openai:"))) };
  verifyOrDie(out, a3, Number(a4));
  fs.writeFileSync(a2, JSON.stringify(out), { mode: 0o600 });
  for (const l of summary(out)) say("EXPORTED", "-", l);
} else if (mode === "import") {
  const store = readJson(a1);
  verifyOrDie(store, a2, Number(a3));
  const dbPath = a4;
  if (!fs.existsSync(dbPath)) die(2, `state store not found: ${dbPath} (run openclaw doctor --non-interactive first)`);
  const db = new DatabaseSync(dbPath);
  db.exec("pragma busy_timeout=5000");
  try { db.prepare("select 1 from config_machine_state limit 1").get(); }
  catch (e) { die(2, `${dbPath} has no config_machine_state table — refusing to create openclaw schema`); }
  const get = (k) => { const r = db.prepare("select value_json from config_machine_state where state_key=?").get(k); return r ? JSON.parse(r.value_json) : undefined; };
  const put = (k, v) => db.prepare("insert into config_machine_state (state_key, value_json, updated_at_ms) values (?,?,?) on conflict(state_key) do update set value_json=excluded.value_json, updated_at_ms=excluded.updated_at_ms").run(k, JSON.stringify(v), Date.now());
  db.exec("BEGIN IMMEDIATE");
  try {
    const own = get("auth.sharedStore");
    if (own !== undefined && !(own && own.location === "state-db")) throw Object.assign(new Error(`auth.sharedStore is ${JSON.stringify(own)}, not state-db — not a pod-fresh store`), { code: 1 });
    const cur = get("authProfiles.store");
    for (const [id, p] of Object.entries((cur && cur.profiles) || {})) {
      if (p && typeof p.refresh === "string" && p.refresh && p.refresh !== a2) throw Object.assign(new Error(`${id} in this store holds a REAL refresh token — an independent chain in a QA pod violates the single-refresher invariant; refusing to touch it`), { code: 1 });
    }
    if (own === undefined) put("auth.sharedStore", { location: "state-db" });
    put("authProfiles.store", store);
    db.exec("COMMIT");
  } catch (e) {
    try { db.exec("ROLLBACK"); } catch {}
    die(e.code === 1 ? 1 : 2, `import failed: ${e.message}`);
  }
  for (const l of summary(store)) say("IMPORTED", "-", l);
} else die(2, `unknown node mode ${mode}`);
'
run_node() { "$NODE_BIN" --experimental-sqlite --no-warnings -e "$NODE_PROG" "$@"; }

# The scratch cell gets the ONE table the mirror needs. It is an intermediate
# that no openclaw process ever opens, so its schema only has to match the
# columns the mirror reads and writes (config_machine_state, openclaw 2026.8).
make_scratch_cell() {
  "$NODE_BIN" --experimental-sqlite --no-warnings -e '
const { DatabaseSync } = require("node:sqlite");
const db = new DatabaseSync(process.argv[1]);
db.exec("CREATE TABLE IF NOT EXISTS config_machine_state (state_key TEXT NOT NULL PRIMARY KEY, value_json TEXT NOT NULL, updated_at_ms INTEGER NOT NULL) STRICT");
' "$1"
}

do_export() {
  local out="$1" scratch rc
  [ -n "$out" ] || die 2 "export needs --out FILE"
  [ -x "$MIRROR" ] || [ -r "$MIRROR" ] || die 2 "mirror not found: $MIRROR"
  [ -r "$CODEX_AUTH_ROOT/.openclaw-main/state/openclaw.sqlite" ] \
    || die 2 "canonical cell not readable: $CODEX_AUTH_ROOT/.openclaw-main/state/openclaw.sqlite"
  scratch="$(mktemp -d)" || die 2 "mktemp failed"
  # shellcheck disable=SC2064 # expand now: the trap must remove THIS scratch dir
  trap "rm -rf '$scratch'" EXIT
  ln -s "$CODEX_AUTH_ROOT/.openclaw-main" "$scratch/.openclaw-main"
  mkdir -p "$scratch/.openclaw-qa/state" "$scratch/mirror-state"
  make_scratch_cell "$scratch/.openclaw-qa/state/openclaw.sqlite" || die 2 "could not create the scratch cell"
  # The mirror's own paging is switched to a no-op on purpose: this runs as a
  # CronJob, and a failed Job is the page (HydraCronMissed on the CronJob's
  # last-success clock). Its stamps and markers land in the scratch dir.
  CODEX_AUTH_ROOT="$scratch" CODEX_MIRROR_SOURCE=main CODEX_MIRROR_TARGET=qa \
    CODEX_MIRROR_MIN_TOKEN_MIN="$MIN_TOKEN_MIN" CODEX_MIRROR_PAGE_FN=true \
    CODEX_MIRROR_STATE_DIR="$scratch/mirror-state" NOTIFY_UNIT_FAILED_MARKER_DIR="$scratch/mirror-state" \
    HYDRA_SELF_PAGED_DIR="$scratch/mirror-state" NODE_BIN="$NODE_BIN" \
    bash "$MIRROR" --ensure >&2
  rc=$?
  case "$rc" in
    0) ;;
    1) die 1 "the mirror REFUSED or FAILED a profile (see its lines above) — nothing exported; the current Secret keeps serving" ;;
    *) die 2 "the mirror could not run (exit $rc) — nothing exported" ;;
  esac
  run_node extract "$scratch/.openclaw-qa/state/openclaw.sqlite" "$out" "$SENTINEL_REFRESH" "$MIN_TOKEN_MIN" || exit $?
}

case "$MODE" in
  export) do_export "$OUT" ;;
  publish)
    command -v "$KUBECTL" >/dev/null 2>&1 || die 2 "kubectl not found"
    if [ -z "$OUT" ]; then OUT="$(mktemp)" || die 2 "mktemp failed"; fi
    do_export "$OUT"
    # create --dry-run renders the Secret (base64) on a pipe; the tokens never
    # reach argv. Server-side apply with our own field manager: the reconciler
    # declares no Secret here (none is committed), so nothing fights this write.
    "$KUBECTL" -n "$SECRET_NS" create secret generic "$SECRET_NAME" \
        --from-file="$SECRET_KEY=$OUT" --dry-run=client -o yaml \
      | "$KUBECTL" label --local -f - -o yaml app.kubernetes.io/part-of=qa-review-gateway app.kubernetes.io/managed-by=codex-auth-secret-writer \
      | "$KUBECTL" apply --server-side --field-manager=codex-auth-secret-writer -f - >&2 \
      || die 2 "kubectl apply of $SECRET_NS/$SECRET_NAME failed"
    rm -f "$OUT"
    log "published $SECRET_NS/$SECRET_NAME"
    ;;
  import)
    [ -n "$IN" ] || die 2 "import needs --in FILE"
    [ -n "${OPENCLAW_STATE_DIR:-}" ] || die 2 "import needs OPENCLAW_STATE_DIR (the pod's own state dir; never defaulted, so it can never land in Caroline's)"
    case "$OPENCLAW_STATE_DIR" in
      */.openclaw-main|*/.openclaw-main/|*/.openclaw-edge|*/.openclaw-edge/) die 2 "refusing to import into a Caroline state dir ($OPENCLAW_STATE_DIR)" ;;
    esac
    run_node import "$IN" "$SENTINEL_REFRESH" "$IMPORT_MIN_TOKEN_MIN" "$OPENCLAW_STATE_DIR/state/openclaw.sqlite"
    ;;
  verify)
    [ -n "$IN" ] || die 2 "verify needs --in FILE"
    run_node verify "$IN" "$SENTINEL_REFRESH" "$IMPORT_MIN_TOKEN_MIN"
    ;;
  *) die 2 "usage: codex-auth-secret.sh export --out FILE | publish | import --in FILE | verify --in FILE" ;;
esac
