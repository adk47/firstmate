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
#   - n1's zero-read (#1545): a STOP is an unexplained credit-class message, and it kills the WHOLE run. An UNMEASURED
#     is a source we could not read: it stops only that batch's segment, writes a zero_read_unmeasured outcome row per
#     affected user, pages #clio_devops the same minute, and every other family continues on its own read (ruling B).
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
NEED_RUNNER="$(cfg CVO_NEED_RUNNER "$HYDRA_ROOT/scripts/credit_review/need_asks.py")"   # proof-need-ask (E): build + send
OWING="$(cfg CVO_OWING "$HYDRA_ROOT/scripts/credit_review/owing_proof.py")"
RECEIPTS="$(cfg CVO_RECEIPTS "$HYDRA_ROOT/scripts/credit_review/receipts.py")"
HEALTH="$(cfg CVO_HEALTH "$HYDRA_ROOT/scripts/paid-status/health_check.py")"
ZERO_READ="$(cfg CVO_ZERO_READ "$HYDRA_ROOT/scripts/credit_verify/zero_read.py")"   # n1's durable zero-read (#1545)
DEPLOYED_SHA_FILE="$(cfg CVO_DEPLOYED_SHA "$HYDRA_ROOT/.deployed-sha")"   # p1 579: named in every tick artefact
JUDGE="$(cfg CVO_JUDGE "$HYDRA_ROOT/scripts/credit-batch-judge.py")"   # b1 / t01b's batch judge (#1591): SHADOW only here
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
FIRST_CAP=100                          # [key=scale-now]: a family's first unsigned ticks, until v1's 10-sample line
# p1 22:0xZ / 519, b1 518, QA #1587: a live-gate check costs ~6-15 s a user (10-31), and the 20:00Z dry tick ran past
# 22:00Z holding the lock, so the 22:00Z tick exited. A tick must end inside its 2 h cadence. The per-family SIZE is the
# family cap (FIRST_CAP before v1's date, the full cap after - #1596 runs read-only checks on 4 workers); the TIME is
# bounded at every step by a hard deadline inside the cadence:
#  - no NEW family after TICK_BUDGET_S, and none whose worst case (check + bodies = 2 x cap x CHECK_S_PER_USER, plus
#    RESERVE_PAD_S) does not fit before TICK_HARD_S;
#  - the bodies are skipped once TICK_HARD_S is passed; the apply is cut to what fits before it at APPLY_S_PER_USER.
TICK_BUDGET_S="$(cfg CVO_TICK_BUDGET_S 6000)"
TICK_HARD_S="$(cfg CVO_TICK_HARD_S 6900)"
CHECK_ENTRIES="$(cfg CVO_CHECK_ENTRIES 200)"   # p1 599 / r5 598: a uvn family walks at most this many LIST ENTRIES a tick
CHECK_S_PER_USER="$(cfg CVO_CHECK_S_PER_USER 4)"   # ~10-15 s a live-gate check on 4 read-only workers (#1596)
RESERVE_PAD_S="$(cfg CVO_RESERVE_PAD_S 300)"      # + the replica read (~86 s) and the health / zero-read rails
APPLY_S_PER_USER="$(cfg CVO_APPLY_S_PER_USER 15)"
TICK_ELAPSED0="$(cfg CVO_TICK_ELAPSED0 0)"     # bats only: the tick started this many seconds ago
TICK_CADENCE_S=7200
TIMEOUT_BIN="$(cfg CVO_TIMEOUT_BIN /usr/bin/timeout)"   # QA #1587: every stage of a started family runs under the deadline
# [key=scale-now] FINAL (Fable + p1 + r5, 10-31 17:5xZ): a family APPLIES on this unattended timer only from the date
# p1's read-back line set for it HERE - its first batch read back clean (ledger sent set == the check-recipients
# would-send set, health + zero-read clean). Unset = SIGNED-only: the tick still checks it and writes its bodies,
# but never applies it (a signed batch goes by hand). FULL_CAP_FROM = v1's 10-sample line: before it the family runs
# at FIRST_CAP, after it at its normal cap. Constants only - a date moves by PR, never by env or a state file.
declare -A UNSIGNED_FROM=(
  [uvn-status]="2026-10-31T18:02Z"     # AE-send-3: 3/3 = would-send 3, health + zero-read clean (h2 18:05Z, n1 465)
  [status-team-review]="2026-10-31T08:20Z"   # /k-ap 7: 7/7 = the signed set, health + zero-read clean (not a timer family yet)
  [claim-status]="2026-10-31T17:55Z"   # c2 batch 5 FREE 250: ledger 5763-6052 == the checked/signed 250, health + zero-read clean (p1 488)
  # status-doc-received (r1): UNSET - no r1 batch has read back clean under the strict definition (p1 488)
  # proof-need-ask (E): UNSET (p1 555). First clean coded batch 2026-11-01T03:19:09Z (c2 E batch 1: 3 sent == signed,
  # +60 health + zero-read clean), but it needed two hand-applied /l2 rules (180-d filing, roles) not yet in the
  # renderer - it is dated only from a clean batch on the deployed /l2 renderer
)
# a SUB-class inside a family: uvn-status:c2 = the asks that carry the /c2 correction (class C, never sent yet). Until
# its date is set the uvn-status family passes --no-correction and the gate defers them (check == send)
declare -A FULL_CAP_FROM=()
# bats only (cfg reads env only under the harness): one dated full-cap entry "family=ISO" to test a REACHED date
FULL_CAP_FROM_TEST="$(cfg CVO_FULL_CAP_FROM_TEST "")"
[ -z "$FULL_CAP_FROM_TEST" ] || FULL_CAP_FROM["${FULL_CAP_FROM_TEST%%=*}"]="${FULL_CAP_FROM_TEST#*=}"
# the bats harness only (cfg's seam): every family unsigned at its full cap, so the family tests exercise the applies
UNSIGNED_ALL="$(cfg CVO_UNSIGNED_ALL 0)"
NOW_EPOCH="$(cfg CVO_NOW_EPOCH "$(date -u +%s)")"   # harness-only clock for the date boundaries
# QA #1587: a dated constant counts only once its UTC time has PASSED (equal = passed); a future or unparseable date
# is not yet - the family stays signed-only / at the first cap
reached() { # <YYYY-MM-DDTHH:MMZ>
  [ -n "$1" ] || return 1
  py - "$1" "$NOW_EPOCH" <<'PY'
import sys
from datetime import datetime, timezone
try:
    t = datetime.strptime(sys.argv[1], "%Y-%m-%dT%H:%MZ").replace(tzinfo=timezone.utc).timestamp()
except ValueError:
    sys.exit(1)
sys.exit(0 if t <= int(sys.argv[2]) else 1)
PY
}
if [ "${1:-}" = "--print-config" ]; then
  for v in CVO_HARNESS HYDRA_ROOT KILL KILL2 LIVE_FLAG PAID_FLAG EXCLUDE STATE PY RUNNER OWING RECEIPTS HEALTH ZERO_READ \
           FRAUD MAIN_ENV LEDGER SCRIPTS_DIR RD_SCAN RD_CAP POLICY CLAIM_LIST CAP R1_CAP CLAIM_CAP DOW REFUSAL_SPIKE NEED_RUNNER FIRST_CAP UNSIGNED_ALL NOW_EPOCH JUDGE DEPLOYED_SHA_FILE CHECK_ENTRIES TICK_BUDGET_S TICK_HARD_S CHECK_S_PER_USER RESERVE_PAD_S APPLY_S_PER_USER TICK_ELAPSED0 FULL_CAP_FROM_TEST TIMEOUT_BIN; do
    printf '%s=%s\n' "$v" "${!v}"
  done
  exit 0
fi

STAMP="$(date -u +%Y%m%dT%H%MZ)"
TICK_T0="$(( $(date -u +%s) - TICK_ELAPSED0 ))"
OUT="$OUT_ROOT/$STAMP"
log() { printf '%s %s\n' "$(date -u +%FT%TZ)" "$*" | tee -a "$OUT/tick.log"; }
killed() { [ -e "$KILL" ] || [ -e "$KILL2" ]; }

killed && { echo "$(date -u +%FT%TZ) credit-verify-outbound: kill file $KILL or $KILL2 present; nothing runs"; exit 0; }
# a tick that could not stop itself never starts: one of the two kill-file locations must be writable
{ { [ -d "$ETC" ] && [ -w "$ETC" ]; } || { [ -d "$STATE" ] && [ -w "$STATE" ]; } \
  || { [ ! -e "$STATE" ] && [ -d "$(dirname "$STATE")" ] && [ -w "$(dirname "$STATE")" ]; }; } \
  || { echo "$(date -u +%FT%TZ) credit-verify-outbound: neither $ETC nor $STATE is writable for a kill file; nothing runs" >&2; exit 2; }
install -d -m 700 "$STATE" "$OUT_ROOT" "$OUT" || exit 2
exec 9>>"$STATE/tick.lock"
if ! flock -n 9; then
  # the measured reason (b1 518 / p1 519 (2)): who holds it and for how long. A held flock is a LIVE tick (it dies with its
  # holder), possibly mid-apply - so a tick past its cadence is logged STALE for a human, never killed or taken over.
  read -r hpid hstart < "$STATE/tick.holder" 2>/dev/null || { hpid="?"; hstart=""; }
  age=$(( $(date -u +%s) - ${hstart:-$(date -u +%s)} ))
  if [ "$age" -gt "$TICK_CADENCE_S" ]; then
    log "STALE: tick pid $hpid has held $STATE/tick.lock for ${age}s (> cadence ${TICK_CADENCE_S}s); this tick exits, nothing taken over"
  else
    log "another tick holds $STATE/tick.lock (pid $hpid, ${age}s); exit"
  fi
  exit 0
fi
printf '%s %s\n' "$$" "$(date -u +%s)" > "$STATE/tick.holder"
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
log "tick start: live=$LIVE paid_live=$PAID_LIVE cap=$CAP out=$OUT deployed=$(cat "$DEPLOYED_SHA_FILE" 2>/dev/null || echo unreadable)"

notify() { # <text>: 0 only when the notifier ACCEPTED it (missing notifier / a Slack failure = 1)
  # shellcheck source=/dev/null
  [ -r "$HYDRA_ROOT/scripts/lib/slack-notify.sh" ] && . "$HYDRA_ROOT/scripts/lib/slack-notify.sh" \
    && declare -F slack_notify_critical >/dev/null && slack_notify_critical "credit-verify-outbound: $*" >/dev/null 2>&1
}
page() { # best effort: the kill file is the guarantee, the page is the notice (call sites keep this contract)
  notify "$@" || { log "page not delivered: $*"; return 0; }
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
  py - "$1" "$2" "$REFUSAL_SPIKE" <<'PY'
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

# zero_unmeasured <tag> <lo> <hi> <why> - Fable ruling 2026-11-03 (B): an UNMEASURED must NOT wedge the whole tick.
# It stops THAT batch's segment only: every affected user carries the zero-read verdict on their OWN outcome row in the
# batch's outcomes file (annotated where the row exists, appended where it does not, with the batch ref and the reason -
# so the batch's outcomes balance per user) and #clio_devops is paged the same minute. It stops THIS batch's segment,
# never the family: the next tick measures its own new rows normally (no persistent marker - a single uncorrelated
# notice must not wedge a family forever). The global kill file stays for STOP only: a STOP is an unexplained
# credit-class message and auto-kills the whole run.
zero_unmeasured() { # <tag> <lo> <hi> <why>
  local out
  out="$(py - "$OUT/$1-apply.json" "$LEDGER" "$2" "$3" "$1" "$4" <<'PY'
import json, sqlite3, sys
path, ledger, lo, hi, tag, why = sys.argv[1:7]
try:
    d = json.load(open(path))
except (OSError, ValueError):
    d = {}
rows = d.get("outcomes") if isinstance(d, dict) else None
if not isinstance(rows, list):
    rows = []
try:
    db = sqlite3.connect(f"file:{ledger}?mode=ro", uri=True)
    users = [str(r[0]) for r in db.execute(
        "SELECT DISTINCT account_id FROM verify_messages WHERE id > ? AND id <= ? "
        "AND status IN ('sent','attempted') AND account_id IS NOT NULL", (int(lo), int(hi)))]
    db.close()
except sqlite3.Error as e:
    print("unreadable ledger: %s" % e); sys.exit(3)
by_user = {}
for r in rows:
    if isinstance(r, dict) and r.get("user") is not None:
        by_user.setdefault(str(r["user"]), []).append(r)
annotated = appended = 0
for u in users:
    mine = by_user.get(u)
    if mine:
        for r in mine:                    # the user's own row carries the verdict; never a second row for them
            r["zero_read"] = "unmeasured"; r["zero_read_reason"] = why; r["zero_read_batch"] = tag
            r["zero_read_ledger"] = "%d-%d" % (int(lo) + 1, int(hi))
        annotated += 1
    else:
        rows.append({"user": u, "result": "zero_read_unmeasured", "reason": why, "batch": tag})
        appended += 1
if isinstance(d, dict):
    d["outcomes"] = rows
    d["zero_read"] = {"batch": tag, "ledger": "%d-%d" % (int(lo) + 1, int(hi)), "verdict": "UNMEASURED", "reason": why}
    json.dump(d, open(path, "w"), indent=1, sort_keys=True)
print("zero_read_unmeasured users %d (annotated %d, appended %d)" % (len(users), annotated, appended))
PY
)" || { echo "zero_unmeasured failed"; return 1; }
  echo "$out"
}

# room <campaign> <segment> <cap>: "<n> <daily>" - n = how many this apply may message today (r5 on #1541): min(cap, the
# policy's daily cap for the campaign+segment minus what the RUNNER recorded for that segment today, the SHARED daily
# cap of the campaign's group (credit / claim, m2) minus every message of that group in the ledger today). A pre-check
# only: the credit runner re-reads its segment record under its run lock before every send (--segment-daily-cap; QA
# #1541: atomic with the send, one segment source - the list's paid flag at send time, never the paying export); the
# claim runners keep their own daily maxima. Unreadable record / policy, or no policy row = 0 (fail closed).
room() {
  py - "$LEDGER" "$POLICY" "$1" "$2" "$3" "$SCRIPTS_DIR" <<'PY'
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
    if group == "credit" and campaign != "proof-need-ask":
        done = uvn_status.segment_used_today(ledger, campaign, seg, day)
    elif campaign == "proof-need-ask":   # need_asks keeps no segment record: its own ledger rows today (both segments)
        done = sqlite3.connect(f"file:{ledger}?mode=ro", uri=True).execute(
            "SELECT count(*) FROM verify_messages WHERE day=? AND campaign=? AND status IN ('sent','attempted')",
            (day, campaign)).fetchone()[0]
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
  if [ -n "$FRAUD" ]; then py "$FRAUD" "$LEDGER" "$1" "$2" 2>&1 | tail -1; return 0; fi
  py - "$LEDGER" "$1" "$2" "$SCRIPTS_DIR" <<'PY'
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

maxid() { py -c 'import sqlite3,sys
try:
    print(sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True).execute("SELECT coalesce(max(id),0) FROM verify_messages").fetchone()[0])
except sqlite3.Error:
    print(-1)' "$LEDGER"; }

# family <name> <segment> <list file> <cap> <runner subcommand> <runner args...>:
#   check -> bodies -> (apply -> health -> spike -> fraud hit -> zero-read -> sample pointer)
# judge_shadow <tag>: the batch judge's items file from this family's rendered bodies - {user_id, body_html, facts (the
# renderer's own JSON object), copy_ref} per body - and, when the judge is deployed, its verdict in SHADOW: written and
# logged next to the batch, acting on NOTHING (p1 / r5: live only after the coverage set; the GO-or-no-apply rail is its
# own PR). A missing judge or a failed call is logged, never a stopped tick.
# p1 579 (the 08:00Z artefacts: claim-status free rendered 100 bodies, 13 accepted): the judge contract is
# items == would-send. accept_bodies keeps in <tag>-bodies ONLY the users in the check's ACCEPTED set (the runner's
# report.accepted, written by --outcomes-json); every other rendered body moves to <tag>-bodies-not-accepted. An
# unreadable check file or an accepted user with no rendered body stops the family (the sample IS the would-send set).
accept_bodies() {
  local tag="$1"
  py - "$OUT/$tag-check.json" "$OUT/$tag-bodies" "$OUT/$tag-bodies-not-accepted" <<'PY' >> "$OUT/tick.log" 2>&1
import glob, json, os, sys
chk, d, aside = sys.argv[1:4]
try:
    acc = {str(a.get("user")) for a in json.load(open(chk))["accepted"]}
except (OSError, ValueError, KeyError, TypeError, AttributeError) as exc:
    print(f"accepted set unreadable from {chk}: {type(exc).__name__}"); sys.exit(1)
os.makedirs(aside, mode=0o700, exist_ok=True)
have, moved = set(), 0
for f in sorted(glob.glob(os.path.join(d, "*.txt"))):
    uid = os.path.basename(f)[:-4]
    if uid in acc:
        have.add(uid); continue
    for g in (f, f[:-4] + ".facts.json"):
        if os.path.exists(g):
            os.replace(g, os.path.join(aside, os.path.basename(g)))
    moved += 1
missing = sorted(acc - have)
print(f"bodies == accepted: {len(have)} kept, {moved} rendered but not accepted moved aside, {len(missing)} accepted without a body")
sys.exit(2 if missing else 3 if not acc else 0)      # 3 = the check accepted nobody (QA #1610: no apply)
PY
}

judge_shadow() {
  local tag="$1" items="$OUT/$1-items.jsonl"
  py - "$OUT/$tag-bodies" "$items" "$(cat "$DEPLOYED_SHA_FILE" 2>/dev/null)" <<'PY' >> "$OUT/tick.log" 2>&1 || { log "$tag: judge items not built"; return 0; }
import glob, json, os, sys
d, out, deployed = sys.argv[1:4]
n = 0
with open(out, "w") as fh:
    os.chmod(out, 0o600)
    for f in sorted(glob.glob(os.path.join(d, "*.txt"))):
        txt = open(f).read()
        head, _, rest = txt.partition("\n")
        try:
            body = json.loads(rest).get("body", "")
        except ValueError:
            body = ""
        ff = f[:-4] + ".facts.json"
        facts = json.load(open(ff)) if os.path.exists(ff) else None
        ref = next((w[5:] for w in head.split() if w.startswith("copy=")), "")
        fh.write(json.dumps({"user_id": os.path.basename(f)[:-4], "body_html": body, "facts": facts, "copy_ref": ref,
                             "deployed": deployed or None}) + "\n")
        n += 1
print(f"judge items: {n} bodies -> {out}")
PY
  if [ -r "$JUDGE" ]; then
    # the 10:00Z tick on 231d6c47: the deployed judge wants the batch's --copy-ref (rc=2 without it). One judge call
    # per copy ref in the items (a family renders one copy, but a mixed batch is split, never mislabelled)
    local ref refs
    refs="$(py -c 'import json,sys; print("\n".join(sorted({json.loads(l).get("copy_ref") or "" for l in open(sys.argv[1]) if l.strip()})))' "$items" 2>/dev/null)"
    : > "$OUT/$tag-judge.out"
    while IFS= read -r ref; do
      [ -n "$ref" ] || { log "$tag JUDGE CALL FAILED: an item has no copy_ref; not judged"; page "$tag: shadow judge not run - an item has no copy_ref"; continue; }
      py -c 'import json,sys; [sys.stdout.write(l) for l in open(sys.argv[1]) if l.strip() and json.loads(l).get("copy_ref") == sys.argv[2]]' \
        "$items" "$ref" > "$OUT/$tag-items-$ref.jsonl" 2>/dev/null
      local jrc
      py "$JUDGE" judge --items "$OUT/$tag-items-$ref.jsonl" --copy-ref "$ref" >> "$OUT/$tag-judge.out" 2>&1; jrc=$?
      log "$tag judge SHADOW copy=$ref (rc=$jrc, acts on nothing): $(tail -c 300 "$OUT/$tag-judge.out")"
      # r5 596: a judge call that fails (argv, crash) is LOUD - logged as such and paged - never a silent shadow line;
      # it still acts on nothing (shadow)
      [ "$jrc" = 0 ] || { log "$tag JUDGE CALL FAILED (rc=$jrc) copy=$ref"; page "$tag: shadow judge call failed rc=$jrc (copy=$ref)"; }
    done <<<"$refs"
  else
    log "$tag judge: not deployed ($JUDGE); items written for the shadow read"
  fi
  return 0
}

elapsed() { echo $(( $(date -u +%s) - TICK_T0 )); }
# QA #1587: every subprocess of a started family runs under the deadline - `bounded` gives it the seconds left before
# TICK_HARD_S (at least 1) and SIGTERMs it there (SIGKILL 30 s later); rc 124/137 = it hit the deadline
bounded() { local left=$(( TICK_HARD_S - $(elapsed) )); [ "$left" -ge 1 ] || left=1
  "$TIMEOUT_BIN" --kill-after=30 "${left}s" "$@"; }
deadline_rc() { [ "$1" = 124 ] || [ "$1" = 137 ]; }
# b1 560: EVERY python subprocess of the tick - builders, filters, cap reads, checks, renders, the judge, the apply and
# the post-send health / ledger / zero-read reads - runs under the one deadline wrapper; no exceptions
py() { bounded "$PY" "$@"; }
# QA #1587 / b1 546: ONE cap rule - past the family's dated full-cap line its own cap, before it at most FIRST_CAP
family_cap() { # <family> <its cap>
  if [ "$UNSIGNED_ALL" = 1 ] || reached "${FULL_CAP_FROM[$1]:-}"; then echo "$2"
  elif [ "$2" -gt "$FIRST_CAP" ]; then echo "$FIRST_CAP"; else echo "$2"; fi
}

# QA #1612: the next page's first entry from a run's own page record ({start, end, listed}; end = the first entry that
# run did not get to), wrapping to 0 at the list's end. Non-zero rc = no page record.
page_next() { py -c 'import json,sys; p=json.load(open(sys.argv[1])).get("page") or {}; e,n=int(p["end"]),int(p["listed"]); print(e if e < n else 0)' "$1" 2>/dev/null; }
advance_cursor() { # <tag> <cursor file> <run's outcomes json> <this tick's start>; the paged families only (a cursor file)
  [ -n "$2" ] || return 0
  local nxt; nxt="$(page_next "$3")" || { log "$1: no page record in $(basename "$3"); the cursor stays at $4"; return 0; }
  printf '%s\n' "$nxt" > "$2.tmp" && mv -f "$2.tmp" "$2"
  log "$1 page: entries from $4 this tick; next tick starts at $nxt"
}

family() {
  local name="$1" seg="$2" list="$3" cap="$4" sub="$5"; shift 5
  local tag="$name-$seg" rc
  killed && { log "$tag: kill file present; stop"; return 1; }
  if [ "$(elapsed)" -ge "$TICK_BUDGET_S" ]; then
    log "$tag: tick budget ${TICK_BUDGET_S}s reached; this family waits for the next tick"; return 0
  fi

  [ -s "$list" ] || { log "$tag: empty audience; skipped"; return 0; }
  local excl=(); [ "$sub" = uvn-status ] && excl=("${EXCL_ARGS[@]}")
  # p1 599 / r5 598 (the 10:00Z check walked all 4,172 entries for an hour): the uvn runner's walk is paged by LIST
  # ENTRIES - the check, the bodies and the apply walk the same page (--max-users caps accepts only)
  # QA #1612: the page ROTATES - a per-family cursor in $STATE (the next page's first entry), advanced from the check's
  # own page record right after a clean check, wrapping to 0 at the list's end; so persistent deferrals at the head
  # never starve the rest. The check, bodies and apply of one tick walk the SAME page (the value read here).
  local cur_file="" cur=0 paged=0
  # r5 639 / p1 638: the proof-need-ask family (need_asks) pages the same way (it ran unpaged for 85+ min at 16:20Z)
  { [ "$sub" = uvn-status ] || [ "$sub" = need-send ]; } && paged=1
  if [ "$paged" = 1 ]; then
    cur_file="$STATE/cursor-$tag"
    cur="$(cat "$cur_file" 2>/dev/null || echo 0)"; [[ "$cur" =~ ^[0-9]{1,9}$ ]] || cur=0
  fi
  local pg=(); [ "$paged" = 1 ] && pg=(--max-entries "$CHECK_ENTRIES" --start-entry "$cur")
  local runner="$RUNNER"; if [ "$sub" = need-send ]; then runner="$NEED_RUNNER"; sub=send; fi
  # [key=scale-now]: the family's unsigned date (unset = SIGNED-only) and its cap before v1's 10-sample line
  local fam="$name"; [ "$name" = r1 ] && fam=status-doc-received
  local unsigned=""
  reached "${UNSIGNED_FROM[$fam]:-}" && unsigned="${UNSIGNED_FROM[$fam]}"
  [ "$UNSIGNED_ALL" = 1 ] && unsigned=harness
  cap="$(family_cap "$fam" "$cap")"
  local walk="$cap"; [ "$paged" = 1 ] && [ "$CHECK_ENTRIES" -gt "$cap" ] && walk="$CHECK_ENTRIES"
  local worst=$(( 2 * walk * CHECK_S_PER_USER + RESERVE_PAD_S ))
  if [ $(( $(elapsed) + worst )) -gt "$TICK_HARD_S" ]; then
    log "$tag: $(elapsed)s into the tick and its worst case is ${worst}s (cap $cap); it does not fit before the ${TICK_HARD_S}s deadline; this family waits for the next tick"
    return 0
  fi
  py "$runner" "$sub" --list "$list" --segment "$seg" "$@" "${excl[@]}" "${pg[@]}" --mode dry-run --max-users "$cap" \
    --check-recipients --outcomes-json "$OUT/$tag-check.json" > "$OUT/$tag-check.out" 2>&1; rc=$?
  log "$tag check (rc=$rc): $(head -c 600 "$OUT/$tag-check.out")"
  if deadline_rc "$rc"; then log "$tag: check hit the ${TICK_HARD_S}s deadline (read-only, stopped); the tick ends"; return 1; fi
  [ "$rc" = 0 ] || { log "$tag: check failed; tick stops"; return 1; }
  # QA #1612 (round 2): the cursor moves only when the family's step for this page is DONE - a dry tick or a check
  # that accepted nobody (to where the CHECK stopped), or a clean apply (to where the APPLY stopped) - and to the
  # first entry that run did not get to (page.end), never past entries a capped run never examined
  if [ "$paged" = 1 ]; then
    page_next "$OUT/$tag-check.json" >/dev/null || { log "$tag: the check recorded no page; tick stops"; return 1; }
  fi
  if [ "$(elapsed)" -ge "$TICK_HARD_S" ]; then log "$tag: ${TICK_HARD_S}s deadline passed after the check; no bodies, no apply this tick"; return 0; fi
  install -d -m 700 "$OUT/$tag-bodies"
  # r5: the bodies ARE the after-the-fact review sample - no sample, no send (the tick stops). [key=scale-now-openclaw]:
  # the WHOLE batch is rendered (not 5), each body with the renderer's facts beside it - the batch judge's items
  py "$runner" "$sub" --list "$list" --segment "$seg" "$@" "${excl[@]}" "${pg[@]}" --mode dry-run --max-users "$cap" \
    --preview "$OUT/$tag-bodies" --preview-accepted "$OUT/$tag-check.json" > "$OUT/$tag-bodies.out" 2>&1; rc=$?
  if deadline_rc "$rc"; then log "$tag: bodies hit the ${TICK_HARD_S}s deadline (read-only, stopped); no apply, the tick ends"; return 1; fi
  [ "$rc" = 0 ] || { log "$tag: body sample failed; no apply, tick stops: $(head -c 300 "$OUT/$tag-bodies.out")"; return 1; }
  accept_bodies "$tag"; rc=$?
  if deadline_rc "$rc"; then log "$tag: the accepted-bodies step hit the ${TICK_HARD_S}s deadline; no apply, the tick ends"; return 1; fi
  # QA #1610: a check that accepted NOBODY is a no-apply family outcome - never an apply over the original list
  if [ "$rc" = 3 ]; then log "$tag: the check accepted nobody; no apply this tick (the family is done)"; advance_cursor "$tag" "$cur_file" "$OUT/$tag-check.json" "$cur"; return 0; fi
  [ "$rc" = 0 ] || { log "$tag: the rendered bodies are not the check's accepted set (rc=$rc); no apply, tick stops"; return 1; }
  judge_shadow "$tag"
  local live="$LIVE"; [ "$seg" = "paid" ] && live="$PAID_LIVE"
  if [ "$live" != 1 ]; then log "$tag: DRY-RUN tick (no send)"; advance_cursor "$tag" "$cur_file" "$OUT/$tag-check.json" "$cur"; return 0; fi
  if [ -z "$unsigned" ]; then log "$tag: SIGNED-only family (no read-back date in UNSIGNED_FROM): checked, not applied"; return 0; fi
  killed && { log "$tag: kill file present; stop"; return 1; }
  local campaign; campaign="$(printf '%s\n' "$@" | awk 'p{print; exit} $0=="--campaign"{p=1}')"
  [ -n "$campaign" ] || campaign="$sub"   # the claim runners: the subcommand IS the campaign
  [ "$runner" = "$NEED_RUNNER" ] && campaign=proof-need-ask
  local rm n daily; rm="$(room "$campaign" "$seg" "$cap")"
  if [[ "$rm" == ERR* ]] || ! [[ "$rm" =~ ^[0-9]+\ [0-9]+\ [0-9]+$ ]]; then
    # QA #1541: an unreadable policy / ledger is an operational failure, not an exhausted cap - stop and page
    autokill "$tag: cap source unreadable (${rm:0:200})"; return 1
  fi
  local _shared; read -r n daily _shared <<<"$rm"   # (the shared cap is the runner's own policy read)
  if [ "${n:-0}" -le 0 ]; then log "$tag: daily cap reached for $campaign/$seg; no apply"; return 0; fi
  local fit=$(( (TICK_HARD_S - $(elapsed)) / APPLY_S_PER_USER ))
  if [ "$fit" -le 0 ]; then log "$tag: no time left before the ${TICK_HARD_S}s deadline; no apply this tick"; return 0; fi
  if [ "$n" -gt "$fit" ]; then log "$tag: apply cut from $n to $fit (what fits before the ${TICK_HARD_S}s deadline)"; n="$fit"; fi
  local lo; lo="$(maxid)"
  [ "$lo" -ge 0 ] || { autokill "$tag: ledger unreadable before the apply"; return 1; }
  local capargs=(); [ "$sub" = uvn-status ] && capargs=(--segment-daily-cap "$daily")
  # [key=uvn-daily-cap-400] (r5 626): the runner reads the ONE credit daily cap from the policy file itself - the tick
  # passes no cap through the environment (no env-moved gate input)
  # [key=apply-sized-to-list]: the apply sends only this tick's own check's accepted set (--signed-accepted); the
  # tick pages that set by its caps and deadline by design (--page: a subset, never a user outside it)
  py "$runner" "$sub" --list "$list" --segment "$seg" "$@" "${excl[@]}" "${pg[@]}" --mode apply --max-users "$n" "${capargs[@]}" \
    --signed-accepted "$OUT/$tag-check.json" --page \
    --outcomes-json "$OUT/$tag-apply.json" > "$OUT/$tag-apply.out" 2>&1; rc=$?
  log "$tag APPLY (rc=$rc): $(head -c 600 "$OUT/$tag-apply.out")"
  # a SEND cut at the deadline: whatever it sent is in the ledger, but the read-back is incomplete - a human looks first
  if deadline_rc "$rc"; then autokill "$tag: the apply hit the ${TICK_HARD_S}s deadline mid-run (ledger $((lo + 1))-…); read back by hand before re-arming"; return 1; fi
  local h hrc; h="$(py "$HEALTH" --since "$RUN_START" --bounce-max-pct 2 --unsub-max-pct 2 --spam-max-pct 2 2>&1 | tail -1)"; hrc=$?
  log "$tag health (rc=$hrc): $h"
  [ "$hrc" = 0 ] || { autokill "$tag health check rc=$hrc: ${h:0:200}"; return 1; }
  # p1 / n1: the durable zero-read over exactly this apply's ledger rows - OK continues; STOP or UNMEASURED (or a missing
  # reader) writes the kill file. Nothing new in the ledger = nothing to read.
  local hi; hi="$(maxid)"
  [ "$hi" -ge 0 ] || { autokill "$tag: ledger unreadable after the apply"; return 1; }   # QA #1541: never a -1 range
  local nsent; nsent="$(py -c 'import sqlite3,sys
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
    local zr zrc; zr="$(py "$ZERO_READ" --ledger-ids "$((lo + 1))-$hi" 2>&1 | tail -1)"; zrc=$?
    [ -r "$ZERO_READ" ] || zrc=2
    # QA #1545 round 8 (Important): under `set -o pipefail` a READER CRASH exits 1, and 1 means CONFIRMED STOP to the
    # lines below - so a transient Trino/kubectl timeout would write the global kill file as if a credit-class message
    # had been observed. The reader prints exactly one verdict line (OK:/STOP:/UNMEASURED:); anything else is a crash,
    # i.e. a source we could not read, and UNMEASURED is the honest reading of it.
    case "${zr:-}" in
      OK|OK:*|STOP|STOP:*|UNMEASURED|UNMEASURED:*) ;;
      *) zr="UNMEASURED: the zero-read printed no verdict (a crash is not a STOP): ${zr:0:200}"; zrc=2 ;;
    esac
    log "$tag zero-read ledger $((lo + 1))-$hi (rc=$zrc): ${zr:0:300}"
    if [ "$zrc" = 1 ]; then
      # STOP: an unexplained credit-class message - the auto-kill for the whole run (unchanged)
      autokill "$tag zero-read STOP for ledger $((lo + 1))-$hi: ${zr:0:200}"; return 1
    fi
    if [ "$zrc" != 0 ]; then
      # (B) UNMEASURED never wedges the tick: rows so the batch's outcomes balance, a page the same minute, this
      # segment stops here (its remaining users stay owed and unsent), every other family continues on its own read.
      local zu; zu="$(zero_unmeasured "$tag" "$lo" "$hi" "${zr:0:200}" 2>&1 | tail -1)"
      log "$tag zero-read UNMEASURED ledger $((lo + 1))-$hi: $zu; this segment stops here, other families continue"
      case "$zu" in *"zero_read_unmeasured users"*) ;; *) autokill "$tag: the zero_read_unmeasured rows could not be written ($zu) - the batch's outcomes would not balance"; return 1 ;; esac
      # ruling B requires the page the SAME MINUTE. A page that could not be delivered is persisted and RETRIED at the
      # top of the next tick, and THIS tick fails closed for the family - an unattended outage must never be only a log.
      if notify "$tag zero-read UNMEASURED for ledger $((lo + 1))-$hi: ${zr:0:200}. This segment stops after its send; its remaining users stay owed and unsent; every other family continues. Rows: $OUT/$tag-apply.json"; then
        log "$tag: paged #clio_devops"
      else
        printf 'zero-read UNMEASURED (undelivered page) %s ledger %d-%d: %s\n' "$(date -u +%FT%TZ)" "$((lo + 1))" "$hi" "${zr:0:200}" \
          > "$STATE/zero-unmeasured-undelivered-$tag" 2>/dev/null \
          || { autokill "$tag: the zero-read was UNMEASURED, the page FAILED, and no durable retry marker could be written ($STATE)"; return 1; }
        log "$tag zero-read UNMEASURED: the PAGE FAILED; persisted $STATE/zero-unmeasured-undelivered-$tag for the next tick's retry - this tick stops here (fail closed)"
        return 1
      fi
      # QA #1545 finding 3: a NONZERO apply is a FAILED apply - rows may already be sent. The UNMEASURED continuation
      # must never turn that into a successful family by skipping the rc guard below.
      if [ "$rc" != 0 ]; then
        log "$tag: apply FAILED (rc=$rc) AND the zero-read was UNMEASURED; the tick stops here (a partial send is never a clean family)"
        return 1
      fi
      # QA #1545 round 9 (Important): this continuation returned 0 WITHOUT moving the paged family's cursor, so every
      # later tick re-walked the SAME page - a persistent UNMEASURED (Loki or Trino down for hours) starved every entry
      # behind it while the tick reported clean for the other families. The page's work IS done: the apply ran and its
      # users carry the zero-read verdict on their own rows, so the cursor moves exactly as a clean apply moves it.
      advance_cursor "$tag" "$cur_file" "$OUT/$tag-apply.json" "$cur"
      return 0
    fi
  fi
  [ "$rc" = 0 ] || { log "$tag: apply failed rc=$rc; tick stops"; return 1; }
  advance_cursor "$tag" "$cur_file" "$OUT/$tag-apply.json" "$cur"
}

# ---- audiences (deployed builders only) ----------------------------------------------------------------------
# r5 on #1541: the uvn-status family is the UVN class only (owing_proof also lists hold classes - review_hold /
# account_hold - that the uvn-status runner does not cover; they belong to their own campaign's family).
# r5 776 / p1 581: the BUILDER writes the uvn-class list (its own facts header over exactly those users); the tick
# never edits a built list - a list changed after its build is refused by the facts check, by design.
py "$OWING" --out "$OUT/owing.json" --class-out "uvn=$OUT/owing-uvn.json" > "$OUT/owing.out" 2>&1 \
  || { log "owing builder failed: $(tail -c 300 "$OUT/owing.out")"; exit 1; }
[ -s "$OUT/owing-uvn.json" ] || { log "owing builder wrote no uvn-class list; tick stops"; exit 1; }
py "$RECEIPTS" --out-dir "$OUT/receipts" > "$OUT/receipts.out" 2>&1 || { log "receipts builder failed: $(tail -c 300 "$OUT/receipts.out")"; exit 1; }
log "owing classes: $(tail -1 "$OUT/owing.out" | py -c 'import json,sys; print(json.dumps(json.loads(sys.stdin.read() or "{}").get("classes", {})))' 2>/dev/null) -> uvn-status family gets the uvn class (owing-uvn.json, built by the builder)"
log "audiences: owing $(head -c 300 "$OUT/owing.out"); receipts $(head -c 300 "$OUT/receipts.out")"

# ---- the families, in p1's order (paid first; a family whose builder/runner is not deployed is logged) ---------
log "uvn-reminder-7: no deployed audience builder/runner on this tree yet (rides its PR); skipped"
# reply_due (h2 / firstmate 031): the ONE answer to a user who wrote to us, built by the DEPLOYED reply_due_scan.py
# (open threads where the customer replied > 24 h ago and after us; comm_state.reply_due() per thread; one row per user;
# paid first). It runs FIRST so answers go before unsolicited notes. It sends through the uvn-status runner, so it
# charges the SAME uvn-status daily row and the shared credit cap as the uvn-status family (room() counts every
# uvn-status message of the day, whatever list it came from). Not deployed = logged and skipped; a builder that IS
# deployed and fails stops the tick, like the other builders.
NEED_LIST=""
if py "$NEED_RUNNER" build --out "$OUT/need-asks-all.json" > "$OUT/need-asks.out" 2>&1; then
  # the exclude file (users another lane messages today) holds them out of the need family too - need_asks has no
  # --exclude-users, so the tick filters its list, as it does the claim list
  py - "$OUT/need-asks-all.json" "$EXCLUDE" "$OUT/need-asks.json" <<'PY' >> "$OUT/tick.log" || { log "need list filter failed"; exit 1; }
import json, os, sys
src, excl, out = sys.argv[1:4]
doc = json.load(open(src))
held = {l.strip() for l in open(excl) if l.strip() and not l.startswith("#")} if os.path.exists(excl) else set()
users = doc.get("users") or []
keep = [u for u in users if str(u.get("user_id")) not in held]
if keep:
    json.dump({**doc, "users": keep}, open(out, "w"))
else:
    open(out, "w").close()                       # an empty audience: the family logs and skips
print(f"need list: {len(users)} users, {len(users) - len(keep)} held out by the exclude file")
PY
  NEED_LIST="$OUT/need-asks.json"
  log "audiences: proof-need-ask $(head -c 300 "$OUT/need-asks.out")"
else
  log "proof-need-ask builder failed: $(tail -c 300 "$OUT/need-asks.out")"; exit 1
fi
RD_LIST=""
if [ -r "$RD_SCAN" ]; then
  py "$RD_SCAN" --out "$OUT/reply-due.json" > "$OUT/reply-due.out" 2>&1 \
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
  local c2=(); reached "${UNSIGNED_FROM[uvn-status:c2]:-}" || c2=(--no-correction)
  family uvn-status paid "$OUT/owing-uvn.json" "$CAP" uvn-status --campaign uvn-status "${c2[@]}" || return 1
  family r1 paid "$OUT/receipts/receipts-received.json" "$R1_CAP" uvn-status --campaign status-doc-received --wording received || return 1
  family uvn-status free "$OUT/owing-uvn.json" "$CAP" uvn-status --campaign uvn-status "${c2[@]}" || return 1
  family r1 free "$OUT/receipts/receipts-received.json" "$R1_CAP" uvn-status --campaign status-doc-received --wording received || return 1
  # [key=proof-need-ask-family] (b1 / Fable 17:5xZ): the per-need ask (E) - need_asks.py, --check-recipients (#1582);
  # SIGNED-only until E's first clean coded batch sets UNSIGNED_FROM[proof-need-ask]. QA #1587: a deployed runner that
  # predates #1582 (no --check-recipients) cannot be checked - logged and skipped, never a failed tick
  if grep -q -- '"--check-recipients"' "$NEED_RUNNER" 2>/dev/null; then
    family proof-need-ask paid "$NEED_LIST" "$CAP" need-send || return 1
    family proof-need-ask free "$NEED_LIST" "$CAP" need-send || return 1
  else
    log "proof-need-ask: the deployed need_asks.py has no --check-recipients (#1582 not deployed); skipped"
  fi
}
claim_families() {
  if [ ! -s "$CLAIM_LIST" ]; then log "claim families: no claim list at $CLAIM_LIST (the claim lane drops it); skipped"; return 0; fi
  # QA #1541: the exclude file holds users out of EVERY family - the claim runners take no --exclude-users, so the
  # held claimants are removed from the claim list before any check / preview / apply (unreadable = no claim family)
  local cl="$OUT/claims-filtered.json"
  py - "$CLAIM_LIST" "$EXCLUDE" "$cl" <<'PY' >> "$OUT/tick.log" 2>&1 || { autokill "claim families: the claim list or the exclude file is unreadable"; return 1; }
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
  # p1 638 / r5 639 (16Z on 29f: the claim checks ran a list signed on e4f65c4a with 5e733e0f deployed): a claim list
  # whose signed_on is not EXACTLY the deployed head is never checked - the claim lane rebuilds it on the deployed head.
  # Read after the filter (which kills on an unreadable list). Refused LOUD (logged + paged) before any check; the
  # credit families still run. An unreadable deployed sha or a missing signed_on = refused.
  local cl_signed dep_sha
  cl_signed="$(py -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d.get("signed_on") or "" if isinstance(d, dict) else "")' "$cl" 2>/dev/null)" || cl_signed=""
  dep_sha="$(cat "$DEPLOYED_SHA_FILE" 2>/dev/null)" || dep_sha=""
  if ! [[ "$dep_sha" =~ ^[0-9a-f]{40}$ ]] || [ "$cl_signed" != "$dep_sha" ]; then
    log "claim families: list_signed_on_stale - $CLAIM_LIST is signed on ${cl_signed:-(none)}, deployed ${dep_sha:-(unreadable)}; not checked this tick (the claim lane rebuilds it on the deployed head)"
    page "claim families: list_signed_on_stale (signed on ${cl_signed:0:12}, deployed ${dep_sha:0:12}) - claim list not checked; rebuild it on the deployed head"
    return 0
  fi
  family claim-proof-ask paid "$cl" "$CLAIM_CAP" claim-proof-ask || return 1
  family claim-status paid "$cl" "$CLAIM_CAP" claim-status || return 1
  family claim-proof-ask free "$cl" "$CLAIM_CAP" claim-proof-ask || return 1
  family claim-status free "$cl" "$CLAIM_CAP" claim-status || return 1
}
# ruling B: an UNMEASURED tick whose page could not be delivered left a durable marker. Retry it at the top of every
# tick; a marker that still cannot be delivered fails this tick closed (the outage is never only a log line).
for m in "$STATE"/zero-unmeasured-undelivered-*; do
  [ -e "$m" ] || continue
  why="$(head -c 400 "$m" 2>/dev/null | tr '\n' ' ')"
  if notify "RETRY (page previously undelivered): $why"; then
    log "retried the undelivered zero-read page from $(basename "$m"); delivered - marker cleared"
    rm -f "$m"
  else
    log "STOP: the undelivered zero-read page in $(basename "$m") still cannot be delivered; this tick fails closed"
    exit 1
  fi
done

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
