#!/usr/bin/env bash
# credit-verify-outbound.sh: the ONE server-side outbound tick for credit verification (captain 2026-10-30 14:4xZ
# "durable, on servers, bi-directional"; plan: firstmate data/proof-loop-lead-fable-p1/unattended-1030.md). Every
# hand-run batch becomes this tick, every 2 h on node-8 (cron from install-aux-units.sh). It never decides anything
# itself: per campaign family it runs the DEPLOYED audience builder and the DEPLOYED runner, whose gates are code
# (copy-ref locks, comm_state, R8/account gate, identity G1-G5, email reachability, C11 dry-run == send, refusals
# recorded with reasons). Per family and segment:
#
#   build the audience -> --check-recipients --outcomes-json (what the send would do, read-only)
#   -> 5 rendered bodies for the after-the-fact sample -> apply up to the per-run cap (LIVE only)
#   -> health read -> auto-kill on a threshold
#
# Modes (files, never hand steps):
#   /etc/hydra/credit-verify-outbound.disabled      kill switch: the whole tick does nothing (written by auto-kill too)
#   /etc/hydra/credit-verify-outbound.live          absent = DRY-RUN tick (outcomes + bodies, nothing sent)
#   /etc/hydra/credit-verify-outbound.paid-enabled  absent = paid segments are dry-run even on a live tick
#                                                   (p1: paid joins after one clean free day)
#   /etc/hydra/credit-verify-outbound.exclude       user ids held out of every family (one per line; the
#                                                   transitional hand-exclusions of the pending rule PRs)
# Caps are CAPACITY caps (Fable 10-30 23:4xZ, m2's shared per-day send cap: credit 2,500 / claim 500 inside notify):
# per tick a family sends at most CAP users; per UTC day a campaign+segment at most its policy row, and ALL credit
# families together at most shared_daily_cap.credit, all claim families at most shared_daily_cap.claim (counted from the
# shared verify ledger, sent + attempted). The safety is the auto-kill, not a small fixed number.
# Auto-kill (writes the kill file and pages) after any apply:
#   - health_check.py non-zero: hard bounce > 2 %, unsubscribe > 2 %, spam > 2 % or any complaint above baseline,
#     or unreadable;
#   - a FRAUD HIT: any account this apply sent to is held by the fraud lens when re-checked right after the send
#     (credit_review.fraud_lens; the lens refusing held users BEFORE a send is normal and never kills), or the lens
#     could not be read;
#   - a refusal spike: refused / attempted > REFUSAL_SPIKE in one apply;
#   - n1's zero-read (#1545) STOP / UNMEASURED.
# The 2 h after-the-fact sample: every apply's ledger id range is appended to $STATE/samples.jsonl (family, segment,
# ledger ids, 5 rendered bodies dir) for flows-verify v1's 2-hourly read of 10 sends per family; v1 stops the tick by
# writing the same kill file.
# Claim families (claim-status, claim-proof-ask; Fable 10-30): the list is the claim lane's (c2) latest
# $CLAIM_LIST (the claim runners refuse a list older than 30 h and keep every claim gate); on Sat/Sun (UTC) the claim
# families run FIRST.
# Outputs per tick: $OUT_ROOT/<UTC stamp>/ (outcomes JSON, check output, 5 bodies per family+segment, the log).
# Exit: 0 ran (or killed/disabled cleanly), 1 a step failed (the tick stops at the first failure), 2 bad config.
set -uo pipefail

# r5 NO-GO @184803d6 / captain [key=unattended]: every GATE input of this unattended timer is a CONSTANT - the kill-file
# and state locations, the ledger (sent counts, budgets), the policy (caps), the fraud lens, the spike threshold, the
# per-tick caps, the day-of-week, the interpreter and every gate script (runner, builders, health, zero-read). The ONE
# seam is the bats harness: with BATS_TEST_TMPDIR set to a directory (bats sets it for every test) the CVO_* test values
# are read; anywhere else no CVO_* / HYDRA_ROOT / PY_BIN environment variable moves anything. Only where the reports land
# (CVO_OUT_ROOT) may move. `--print-config` prints what this run would read, then exits (the test hook).
if [ -n "${BATS_TEST_TMPDIR:-}" ] && [ -d "${BATS_TEST_TMPDIR}" ]; then CVO_HARNESS=1; else CVO_HARNESS=0; fi
cfg() { # <env name> <constant>: the constant - or, under the bats harness only, the test value
  if [ "$CVO_HARNESS" = 1 ]; then local n="$1"; printf '%s' "${!n:-$2}"; else printf '%s' "$2"; fi
}
HYDRA_ROOT="$(cfg HYDRA_ROOT /opt/hydra)"
ETC="$(cfg CVO_ETC /etc/hydra)"
KILL="$ETC/credit-verify-outbound.disabled"
LIVE_FLAG="$ETC/credit-verify-outbound.live"
PAID_FLAG="$ETC/credit-verify-outbound.paid-enabled"
EXCLUDE="$ETC/credit-verify-outbound.exclude"
STATE="$(cfg CVO_STATE /var/lib/hydra/credit-verify-outbound)"
# QA #1541: a durable fallback kill file - if /etc/hydra cannot take the kill file (read-only, full), the auto-kill
# writes here, and every check honours both
KILL2="$STATE/credit-verify-outbound.disabled"
OUT_ROOT="${CVO_OUT_ROOT:-/root/h2-runs/sched}"   # reports only: never a gate input
PY="$(cfg PY_BIN python3)"
RUNNER="$(cfg CVO_RUNNER "$HYDRA_ROOT/scripts/credit-review.py")"
OWING="$(cfg CVO_OWING "$HYDRA_ROOT/scripts/credit_review/owing_proof.py")"
RECEIPTS="$(cfg CVO_RECEIPTS "$HYDRA_ROOT/scripts/credit_review/receipts.py")"
HEALTH="$(cfg CVO_HEALTH "$HYDRA_ROOT/scripts/paid-status/health_check.py")"
ZERO_READ="$(cfg CVO_ZERO_READ "$HYDRA_ROOT/scripts/credit_verify/zero_read.py")"   # n1's durable zero-read (#1545)
FRAUD="$(cfg CVO_FRAUD "")"   # a fraud re-check stub <ledger> <lo> <hi> (tests only); otherwise the lens inline below
MAIN_ENV="$(cfg CVO_MAIN_ENV /etc/openclaw/main.env)"
LEDGER="$(cfg CVO_LEDGER /var/lib/hydra/credit-review/ledger.sqlite3)"
SCRIPTS_DIR="$(cfg CVO_SCRIPTS "$HYDRA_ROOT/scripts")"   # credit_review.uvn_status: the runner's own segment record
RD_SCAN="$(cfg CVO_RD_SCAN "$SCRIPTS_DIR/credit_review/reply_due_scan.py")"   # h2's reply_due audience builder
RD_CAP="$(cfg CVO_RD_CAP 100)"
POLICY="$(cfg CVO_POLICY "$HYDRA_ROOT/policies/credit-verify-outbound.json")"
CLAIM_LIST="$(cfg CVO_CLAIM_LIST "$STATE/claim-list.json")"
CAP="$(cfg CVO_CAP 250)"                 # users per family+segment per tick (l1: 250/run)
R1_CAP="$(cfg CVO_R1_CAP 250)"
CLAIM_CAP="$(cfg CVO_CLAIM_CAP 250)"
DOW="$(cfg CVO_DOW "$(date -u +%u)")"     # 6 = Saturday, 7 = Sunday: claim families first
REFUSAL_SPIKE="$(cfg CVO_REFUSAL_SPIKE 0.20)"
if [ "${1:-}" = "--print-config" ]; then
  for v in CVO_HARNESS HYDRA_ROOT KILL KILL2 LIVE_FLAG PAID_FLAG EXCLUDE STATE PY RUNNER OWING RECEIPTS HEALTH ZERO_READ \
           FRAUD MAIN_ENV LEDGER SCRIPTS_DIR RD_SCAN RD_CAP POLICY CLAIM_LIST CAP R1_CAP CLAIM_CAP DOW REFUSAL_SPIKE; do
    printf '%s=%s\n' "$v" "${!v}"
  done
  exit 0
fi

STAMP="$(date -u +%Y%m%dT%H%MZ)"
OUT="$OUT_ROOT/$STAMP"
log() { printf '%s %s\n' "$(date -u +%FT%TZ)" "$*" | tee -a "$OUT/tick.log"; }
killed() { [ -e "$KILL" ] || [ -e "$KILL2" ]; }

killed && { echo "$(date -u +%FT%TZ) credit-verify-outbound: kill file $KILL or $KILL2 present; nothing runs"; exit 0; }
# a tick that could not stop itself never starts: one of the two kill-file locations must be writable
{ { [ -d "$ETC" ] && [ -w "$ETC" ]; } || { [ -d "$STATE" ] && [ -w "$STATE" ]; } \
  || { [ ! -e "$STATE" ] && [ -d "$(dirname "$STATE")" ] && [ -w "$(dirname "$STATE")" ]; }; } \
  || { echo "$(date -u +%FT%TZ) credit-verify-outbound: neither $ETC nor $STATE is writable for a kill file; nothing runs" >&2; exit 2; }
install -d -m 700 "$STATE" "$OUT_ROOT" "$OUT" || exit 2
exec 9>"$STATE/tick.lock"
flock -n 9 || { log "another tick holds $STATE/tick.lock; exit"; exit 0; }
if [ -r "$MAIN_ENV" ]; then set -a; # shellcheck source=/dev/null
  . "$MAIN_ENV"; set +a; fi
LIVE=0; [ -e "$LIVE_FLAG" ] && LIVE=1
# QA #1541: no live send without the zero-read reader deployed - the tick runs DRY instead (and says so), never a
# first send that can only auto-kill
if [ "$LIVE" = 1 ] && [ ! -r "$ZERO_READ" ]; then
  LIVE=0; ZR_MISSING=1
fi
PAID_LIVE=0; [ "$LIVE" = 1 ] && [ -e "$PAID_FLAG" ] && PAID_LIVE=1
EXCL_ARGS=(); [ -s "$EXCLUDE" ] && EXCL_ARGS=(--exclude-users "$EXCLUDE")
RUN_START="$(date -u +%FT%TZ)"
log "tick start: live=$LIVE paid_live=$PAID_LIVE cap=$CAP out=$OUT"

page() { # best effort: the kill file is the guarantee, the page is the notice
  # shellcheck source=/dev/null
  [ -r "$HYDRA_ROOT/scripts/lib/slack-notify.sh" ] && . "$HYDRA_ROOT/scripts/lib/slack-notify.sh" \
    && declare -F slack_notify_critical >/dev/null && slack_notify_critical "credit-verify-outbound: $*" >/dev/null 2>&1
  return 0
}
autokill() { # <why>
  local where="$KILL"
  if ! printf 'auto-kill %s: %s\n' "$STAMP" "$1" > "$KILL" 2>/dev/null; then
    where="$KILL2"
    if ! printf 'auto-kill %s: %s\n' "$STAMP" "$1" > "$KILL2" 2>/dev/null; then
      log "AUTO-KILL: $1 - BOTH kill-file writes FAILED ($KILL, $KILL2); this tick stops here"
      page "AUTO-KILL $STAMP FAILED TO PERSIST: $1. Neither $KILL nor $KILL2 could be written - the next tick will refuse to start only if a location stays unwritable; a human must stop the timer now."
      exit 3
    fi
  fi
  log "AUTO-KILL: $1 (wrote $where)"
  page "AUTO-KILL $STAMP: $1. Nothing more runs until a human reads $OUT and removes $where."
}

[ "${ZR_MISSING:-0}" = 1 ] && { log "LIVE REFUSED: the zero-read reader $ZERO_READ is not deployed; this tick runs DRY"; page "live tick refused: $ZERO_READ missing (tick ran dry)"; }

# refusal spike of one apply's outcomes JSON: refused / (sent + refused) > REFUSAL_SPIKE
spike() { # <outcomes json> <sent>
  "$PY" - "$1" "$2" "$REFUSAL_SPIKE" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except (OSError, ValueError):
    print("unreadable"); sys.exit(0)
o = d.get("outcomes", d) if isinstance(d, dict) else d
refused = sum(1 for x in o if str(x.get("result", "")).startswith("refused"))
sent = int(sys.argv[2] or 0)
n = sent + refused
print("spike" if n >= 10 and refused / n > float(sys.argv[3]) else "ok")
PY
}

# room <campaign> <segment> <cap>: "<n> <daily>" - n = how many this apply may message today (r5 on #1541): min(cap, the
# policy's daily cap for the campaign+segment minus what the RUNNER recorded for that segment today, the SHARED daily
# cap of the campaign's group (credit / claim, m2) minus every message of that group in the ledger today). A pre-check
# only: the credit runner re-reads its segment record under its run lock before every send (--segment-daily-cap; QA
# #1541: atomic with the send, one segment source - the list's paid flag at send time, never the paying export); the
# claim runners keep their own daily maxima. Unreadable record / policy, or no policy row = 0 (fail closed).
room() {
  "$PY" - "$LEDGER" "$POLICY" "$1" "$2" "$3" "$SCRIPTS_DIR" <<'PY'
import datetime, json, sqlite3, sys
ledger, policy, campaign, seg, cap, scripts = sys.argv[1:7]
sys.path.insert(0, scripts)
try:
    from credit_review import uvn_status
    pol = json.load(open(policy))
    daily = int(pol["daily_cap"][campaign][seg])
    group = next(g for g, cs in pol["groups"].items() if campaign in cs)
    shared = int(pol["shared_daily_cap"][group])
    day = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d")
    if group == "credit":
        done = uvn_status.segment_used_today(ledger, campaign, seg, day)
    else:  # claim runners keep no segment record: count the campaign's ledger rows for the day (both segments)
        done = 0
    cs = pol["groups"][group]
    db = sqlite3.connect(f"file:{ledger}?mode=ro", uri=True)
    used = db.execute("SELECT count(*) FROM verify_messages WHERE day=? AND status IN ('sent','attempted') AND campaign IN (%s)"
                      % ",".join("?" * len(cs)), (day, *cs)).fetchone()[0]
except Exception as exc:  # noqa: BLE001 - QA #1541: a read problem is an ERROR (stop + page), never "cap reached"
    print("ERR", type(exc).__name__, str(exc)[:160].replace("\n", " ")); sys.exit(0)
print(max(0, min(int(cap), daily - done, shared - int(used))), daily, shared)
PY
}

# fraudhit <lo> <hi>: re-run the fraud lens on every account this apply sent to (ledger rows lo..hi, sent/attempted).
# Prints "ok", "hit <ids>" or "unreadable <why>". A held account that RECEIVED a message is the fraud hit (Fable 10-30).
fraudhit() {
  if [ -n "$FRAUD" ]; then "$PY" "$FRAUD" "$LEDGER" "$1" "$2" 2>&1 | tail -1; return 0; fi
  "$PY" - "$LEDGER" "$1" "$2" "$SCRIPTS_DIR" <<'PY'
import sqlite3, sys
ledger, lo, hi, scripts = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4]
sys.path.insert(0, scripts)
try:
    ids = sorted({int(a) for (a,) in sqlite3.connect(f"file:{ledger}?mode=ro", uri=True).execute(
        "SELECT DISTINCT account_id FROM verify_messages WHERE id > ? AND id <= ? AND status IN ('sent','attempted') "
        "AND account_id IS NOT NULL", (lo, hi)) if str(a).strip().isdigit()})
    if not ids:
        print("ok"); sys.exit(0)
    from credit_review import fraud_lens, verify_notify
    held = fraud_lens.split(ids, fraud_lens.default_lens(verify_notify.trino))["held"]
except Exception as exc:  # noqa: BLE001 - an unreadable lens after a send is a stop, never a pass
    print("unreadable", type(exc).__name__, str(exc)[:160]); sys.exit(0)
print("hit " + ",".join(str(h["user_id"]) for h in held) if held else "ok")
PY
}

# sample <tag> <lo> <hi>: the after-the-fact review pointer for flows-verify v1 (2-hourly, 10 sends per family)
sample() {   # returns non-zero when the pointer could not be written (QA #1541: never swallowed)
  printf '{"at":"%s","tick":"%s","family":"%s","ledger_ids":"%s-%s","bodies":"%s"}\n' \
    "$(date -u +%FT%TZ)" "$STAMP" "$1" "$(( $2 + 1 ))" "$3" "$OUT/$1-bodies" >> "$STATE/samples.jsonl" 2>/dev/null
}

maxid() { "$PY" -c 'import sqlite3,sys
try:
    print(sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True).execute("SELECT coalesce(max(id),0) FROM verify_messages").fetchone()[0])
except sqlite3.Error:
    print(-1)' "$LEDGER"; }

# family <name> <segment> <list file> <cap> <runner subcommand> <runner args...>:
#   check -> bodies -> (apply -> health -> spike -> fraud hit -> zero-read -> sample pointer)
family() {
  local name="$1" seg="$2" list="$3" cap="$4" sub="$5"; shift 5
  local tag="$name-$seg" rc
  killed && { log "$tag: kill file present; stop"; return 1; }
  [ -s "$list" ] || { log "$tag: empty audience; skipped"; return 0; }
  local excl=(); [ "$sub" = uvn-status ] && excl=("${EXCL_ARGS[@]}")
  "$PY" "$RUNNER" "$sub" --list "$list" --segment "$seg" "$@" "${excl[@]}" --mode dry-run --max-users "$cap" \
    --check-recipients --outcomes-json "$OUT/$tag-check.json" > "$OUT/$tag-check.out" 2>&1; rc=$?
  log "$tag check (rc=$rc): $(head -c 600 "$OUT/$tag-check.out")"
  [ "$rc" = 0 ] || { log "$tag: check failed; tick stops"; return 1; }
  install -d -m 700 "$OUT/$tag-bodies"
  # r5: the 5 bodies ARE the after-the-fact review sample - no sample, no send (the tick stops)
  "$PY" "$RUNNER" "$sub" --list "$list" --segment "$seg" "$@" "${excl[@]}" --mode dry-run --max-users 5 \
    --preview "$OUT/$tag-bodies" > "$OUT/$tag-bodies.out" 2>&1 \
    || { log "$tag: body sample failed; no apply, tick stops: $(head -c 300 "$OUT/$tag-bodies.out")"; return 1; }
  local live="$LIVE"; [ "$seg" = "paid" ] && live="$PAID_LIVE"
  if [ "$live" != 1 ]; then log "$tag: DRY-RUN tick (no send)"; return 0; fi
  killed && { log "$tag: kill file present; stop"; return 1; }
  local campaign; campaign="$(printf '%s\n' "$@" | awk 'p{print; exit} $0=="--campaign"{p=1}')"
  [ -n "$campaign" ] || campaign="$sub"   # the claim runners: the subcommand IS the campaign
  local rm n daily; rm="$(room "$campaign" "$seg" "$cap")"
  if [[ "$rm" == ERR* ]] || ! [[ "$rm" =~ ^[0-9]+\ [0-9]+\ [0-9]+$ ]]; then
    # QA #1541: an unreadable policy / ledger is an operational failure, not an exhausted cap - stop and page
    autokill "$tag: cap source unreadable (${rm:0:200})"; return 1
  fi
  local shared; read -r n daily shared <<<"$rm"
  if [ "${n:-0}" -le 0 ]; then log "$tag: daily cap reached for $campaign/$seg; no apply"; return 0; fi
  local lo; lo="$(maxid)"
  [ "$lo" -ge 0 ] || { autokill "$tag: ledger unreadable before the apply"; return 1; }
  local capargs=(); [ "$sub" = uvn-status ] && capargs=(--segment-daily-cap "$daily")
  # QA #1541 (uvn_status.py:869): the runner also caps each campaign per UTC day by itself (CREDIT_UVN_DAILY_MAX,
  # default 400 / CREDIT_STATUS_DAILY_MAX, default 1000, both segments together). Left at those defaults it binds
  # BELOW the policy and later ticks would report room but send 0. For this apply it gets the policy's shared group
  # cap (the binding daily total), so one number governs and room() and the runner cannot disagree.
  CREDIT_UVN_DAILY_MAX="$shared" CREDIT_STATUS_DAILY_MAX="$shared" \
  "$PY" "$RUNNER" "$sub" --list "$list" --segment "$seg" "$@" "${excl[@]}" --mode apply --max-users "$n" "${capargs[@]}" \
    --outcomes-json "$OUT/$tag-apply.json" > "$OUT/$tag-apply.out" 2>&1; rc=$?
  log "$tag APPLY (rc=$rc): $(head -c 600 "$OUT/$tag-apply.out")"
  local h hrc; h="$("$PY" "$HEALTH" --since "$RUN_START" --bounce-max-pct 2 --unsub-max-pct 2 --spam-max-pct 2 2>&1 | tail -1)"; hrc=$?
  log "$tag health (rc=$hrc): $h"
  [ "$hrc" = 0 ] || { autokill "$tag health check rc=$hrc: ${h:0:200}"; return 1; }
  # p1 / n1: the durable zero-read over exactly this apply's ledger rows - OK continues; STOP or UNMEASURED (or a missing
  # reader) writes the kill file. Nothing new in the ledger = nothing to read.
  local hi; hi="$(maxid)"
  [ "$hi" -ge 0 ] || { autokill "$tag: ledger unreadable after the apply"; return 1; }   # QA #1541: never a -1 range
  local nsent; nsent="$("$PY" -c 'import sqlite3,sys
print(sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True).execute(
    "SELECT count(*) FROM verify_messages WHERE id > ? AND id <= ? AND status IN (?, ?)",
    (int(sys.argv[2]), int(sys.argv[3]), "sent", "attempted")).fetchone()[0])' \
    "$LEDGER" "$lo" "$hi" 2>/dev/null || echo -1)"
  [ "$nsent" -ge 0 ] || { autokill "$tag: ledger unreadable after the apply"; return 1; }
  # QA #1541 (claim runners print 'sent N', credit runners 'N sent'): the spike reads the LEDGER's own count of this
  # apply's sends - never a grep on a runner's prose, which read 0 for claims and wrote the permanent kill file
  [ "$(spike "$OUT/$tag-apply.json" "$nsent")" = "ok" ] || { autokill "$tag refusal spike (> $REFUSAL_SPIKE of attempts refused)"; return 1; }
  if [ "$nsent" -gt 0 ]; then
    local fh; fh="$(fraudhit "$lo" "$hi")"
    log "$tag fraud re-check ledger $((lo + 1))-$hi: ${fh:0:300}"
    [ "$fh" = ok ] || { autokill "$tag FRAUD ${fh:0:200} (ledger $((lo + 1))-$hi)"; return 1; }
    sample "$tag" "$lo" "$hi" || { autokill "$tag: the v1 sample pointer for ledger $((lo + 1))-$hi could not be written to $STATE/samples.jsonl"; return 1; }
    local zr zrc; zr="$("$PY" "$ZERO_READ" --ledger-ids "$((lo + 1))-$hi" 2>&1 | tail -1)"; zrc=$?
    [ -r "$ZERO_READ" ] || zrc=2
    log "$tag zero-read ledger $((lo + 1))-$hi (rc=$zrc): ${zr:0:300}"
    [ "$zrc" = 0 ] || { autokill "$tag zero-read $([ "$zrc" = 1 ] && echo STOP || echo UNMEASURED) for ledger $((lo + 1))-$hi: ${zr:0:200}"; return 1; }
  fi
  [ "$rc" = 0 ] || { log "$tag: apply failed rc=$rc; tick stops"; return 1; }
}

# ---- audiences (deployed builders only) ----------------------------------------------------------------------
"$PY" "$OWING" --out "$OUT/owing.json" > "$OUT/owing.out" 2>&1 || { log "owing builder failed: $(tail -c 300 "$OUT/owing.out")"; exit 1; }
"$PY" "$RECEIPTS" --out-dir "$OUT/receipts" > "$OUT/receipts.out" 2>&1 || { log "receipts builder failed: $(tail -c 300 "$OUT/receipts.out")"; exit 1; }
# r5 on #1541: the uvn-status family is the UVN class only (owing_proof also lists hold classes - review_hold /
# account_hold - that the uvn-status runner does not cover; they belong to their own campaign's family)
"$PY" - "$OUT/owing.json" "$OUT/owing-uvn.json" <<'PY' >> "$OUT/tick.log" || { log "owing split failed"; exit 1; }
import json, sys, collections
d = json.load(open(sys.argv[1]))
users = d.get("users") or []
json.dump({**d, "users": [u for u in users if u.get("class", "uvn") == "uvn"]}, open(sys.argv[2], "w"))
print("owing classes:", dict(collections.Counter(u.get("class", "uvn") for u in users)), "-> uvn-status family gets the uvn class")
PY
log "audiences: owing $(head -c 300 "$OUT/owing.out"); receipts $(head -c 300 "$OUT/receipts.out")"

# ---- the families, in p1's order (paid first; a family whose builder/runner is not deployed is logged) ---------
for f in proof-need-ask uvn-reminder-7; do
  log "$f: no deployed audience builder/runner on this tree yet (rides its PR); skipped"
done
# reply_due (h2 / firstmate 031): the ONE answer to a user who wrote to us, built by the DEPLOYED reply_due_scan.py
# (open threads where the customer replied > 24 h ago and after us; comm_state.reply_due() per thread; one row per user;
# paid first). It runs FIRST so answers go before unsolicited notes. It sends through the uvn-status runner, so it
# charges the SAME uvn-status daily row and the shared credit cap as the uvn-status family (room() counts every
# uvn-status message of the day, whatever list it came from). Not deployed = logged and skipped; a builder that IS
# deployed and fails stops the tick, like the other builders.
RD_LIST=""
if [ -r "$RD_SCAN" ]; then
  "$PY" "$RD_SCAN" --out "$OUT/reply-due.json" > "$OUT/reply-due.out" 2>&1 \
    || { log "reply_due builder failed: $(tail -c 300 "$OUT/reply-due.out")"; exit 1; }
  RD_LIST="$OUT/reply-due.json"
  log "audiences: reply_due $(head -c 300 "$OUT/reply-due.out")"
else
  log "reply_due: no deployed audience builder ($RD_SCAN) on this tree yet (rides its PR); skipped"
fi
credit_families() {
  if [ -n "$RD_LIST" ]; then
    family reply-due paid "$RD_LIST" "$RD_CAP" uvn-status --campaign uvn-status || return 1
    family reply-due free "$RD_LIST" "$RD_CAP" uvn-status --campaign uvn-status || return 1
  fi
  family uvn-status paid "$OUT/owing-uvn.json" "$CAP" uvn-status --campaign uvn-status || return 1
  family r1 paid "$OUT/receipts/receipts-received.json" "$R1_CAP" uvn-status --campaign status-doc-received --wording received || return 1
  family uvn-status free "$OUT/owing-uvn.json" "$CAP" uvn-status --campaign uvn-status || return 1
  family r1 free "$OUT/receipts/receipts-received.json" "$R1_CAP" uvn-status --campaign status-doc-received --wording received || return 1
}
claim_families() {
  if [ ! -s "$CLAIM_LIST" ]; then log "claim families: no claim list at $CLAIM_LIST (the claim lane drops it); skipped"; return 0; fi
  # QA #1541: the exclude file holds users out of EVERY family - the claim runners take no --exclude-users, so the
  # held claimants are removed from the claim list before any check / preview / apply (unreadable = no claim family)
  local cl="$OUT/claims-filtered.json"
  "$PY" - "$CLAIM_LIST" "$EXCLUDE" "$cl" <<'PY' >> "$OUT/tick.log" 2>&1 || { autokill "claim families: the claim list or the exclude file is unreadable"; return 1; }
import json, os, sys
src, excl, out = sys.argv[1:4]
doc = json.load(open(src))
held = set()
if os.path.exists(excl) and os.path.getsize(excl):
    held = {l.strip() for l in open(excl) if l.strip() and not l.startswith("#")}
claims = doc.get("claims") if isinstance(doc, dict) else None
if not isinstance(claims, list):
    sys.exit("claim list has no claims[]")
keep = [c for c in claims if str(c.get("user_id")) not in held]
json.dump({**doc, "claims": keep}, open(out, "w"))
print(f"claim list: {len(claims)} claims, {len(claims) - len(keep)} held out by the exclude file")
PY
  family claim-proof-ask paid "$cl" "$CLAIM_CAP" claim-proof-ask || return 1
  family claim-status paid "$cl" "$CLAIM_CAP" claim-status || return 1
  family claim-proof-ask free "$cl" "$CLAIM_CAP" claim-proof-ask || return 1
  family claim-status free "$cl" "$CLAIM_CAP" claim-status || return 1
}
if [ "$DOW" = 6 ] || [ "$DOW" = 7 ]; then   # Fable 10-30: claims prioritised Sat-Sun
  log "weekend: claim families first"
  claim_families || exit 1
  credit_families || exit 1
else
  credit_families || exit 1
  claim_families || exit 1
fi
log "tick done"
exit 0
