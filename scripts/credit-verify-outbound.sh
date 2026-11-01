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
NEED_RUNNER="$(cfg CVO_NEED_RUNNER "$HYDRA_ROOT/scripts/credit_review/need_asks.py")"   # proof-need-ask (E): build + send
OWING="$(cfg CVO_OWING "$HYDRA_ROOT/scripts/credit_review/owing_proof.py")"
RECEIPTS="$(cfg CVO_RECEIPTS "$HYDRA_ROOT/scripts/credit_review/receipts.py")"
HEALTH="$(cfg CVO_HEALTH "$HYDRA_ROOT/scripts/paid-status/health_check.py")"
ZERO_READ="$(cfg CVO_ZERO_READ "$HYDRA_ROOT/scripts/credit_verify/zero_read.py")"   # n1's durable zero-read (#1545)
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
           FRAUD MAIN_ENV LEDGER SCRIPTS_DIR RD_SCAN RD_CAP POLICY CLAIM_LIST CAP R1_CAP CLAIM_CAP DOW REFUSAL_SPIKE NEED_RUNNER FIRST_CAP UNSIGNED_ALL NOW_EPOCH JUDGE TICK_BUDGET_S TICK_HARD_S CHECK_S_PER_USER RESERVE_PAD_S APPLY_S_PER_USER TICK_ELAPSED0 FULL_CAP_FROM_TEST TIMEOUT_BIN; do
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
judge_shadow() {
  local tag="$1" items="$OUT/$1-items.jsonl"
  py - "$OUT/$tag-bodies" "$items" <<'PY' >> "$OUT/tick.log" 2>&1 || { log "$tag: judge items not built"; return 0; }
import glob, json, os, sys
d, out = sys.argv[1:3]
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
        fh.write(json.dumps({"user_id": os.path.basename(f)[:-4], "body_html": body, "facts": facts, "copy_ref": ref}) + "\n")
        n += 1
print(f"judge items: {n} bodies -> {out}")
PY
  if [ -r "$JUDGE" ]; then
    py "$JUDGE" judge --items "$items" > "$OUT/$tag-judge.out" 2>&1
    log "$tag judge SHADOW (rc=$?, acts on nothing): $(tail -c 300 "$OUT/$tag-judge.out")"
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

family() {
  local name="$1" seg="$2" list="$3" cap="$4" sub="$5"; shift 5
  local tag="$name-$seg" rc
  killed && { log "$tag: kill file present; stop"; return 1; }
  if [ "$(elapsed)" -ge "$TICK_BUDGET_S" ]; then
    log "$tag: tick budget ${TICK_BUDGET_S}s reached; this family waits for the next tick"; return 0
  fi

  [ -s "$list" ] || { log "$tag: empty audience; skipped"; return 0; }
  local excl=(); [ "$sub" = uvn-status ] && excl=("${EXCL_ARGS[@]}")
  local runner="$RUNNER"; if [ "$sub" = need-send ]; then runner="$NEED_RUNNER"; sub=send; fi
  # [key=scale-now]: the family's unsigned date (unset = SIGNED-only) and its cap before v1's 10-sample line
  local fam="$name"; [ "$name" = r1 ] && fam=status-doc-received
  local unsigned=""
  reached "${UNSIGNED_FROM[$fam]:-}" && unsigned="${UNSIGNED_FROM[$fam]}"
  [ "$UNSIGNED_ALL" = 1 ] && unsigned=harness
  cap="$(family_cap "$fam" "$cap")"
  local worst=$(( 2 * cap * CHECK_S_PER_USER + RESERVE_PAD_S ))
  if [ $(( $(elapsed) + worst )) -gt "$TICK_HARD_S" ]; then
    log "$tag: $(elapsed)s into the tick and its worst case is ${worst}s (cap $cap); it does not fit before the ${TICK_HARD_S}s deadline; this family waits for the next tick"
    return 0
  fi
  py "$runner" "$sub" --list "$list" --segment "$seg" "$@" "${excl[@]}" --mode dry-run --max-users "$cap" \
    --check-recipients --outcomes-json "$OUT/$tag-check.json" > "$OUT/$tag-check.out" 2>&1; rc=$?
  log "$tag check (rc=$rc): $(head -c 600 "$OUT/$tag-check.out")"
  if deadline_rc "$rc"; then log "$tag: check hit the ${TICK_HARD_S}s deadline (read-only, stopped); the tick ends"; return 1; fi
  [ "$rc" = 0 ] || { log "$tag: check failed; tick stops"; return 1; }
  if [ "$(elapsed)" -ge "$TICK_HARD_S" ]; then log "$tag: ${TICK_HARD_S}s deadline passed after the check; no bodies, no apply this tick"; return 0; fi
  install -d -m 700 "$OUT/$tag-bodies"
  # r5: the bodies ARE the after-the-fact review sample - no sample, no send (the tick stops). [key=scale-now-openclaw]:
  # the WHOLE batch is rendered (not 5), each body with the renderer's facts beside it - the batch judge's items
  py "$runner" "$sub" --list "$list" --segment "$seg" "$@" "${excl[@]}" --mode dry-run --max-users "$cap" \
    --preview "$OUT/$tag-bodies" > "$OUT/$tag-bodies.out" 2>&1; rc=$?
  if deadline_rc "$rc"; then log "$tag: bodies hit the ${TICK_HARD_S}s deadline (read-only, stopped); no apply, the tick ends"; return 1; fi
  [ "$rc" = 0 ] || { log "$tag: body sample failed; no apply, tick stops: $(head -c 300 "$OUT/$tag-bodies.out")"; return 1; }
  judge_shadow "$tag"
  local live="$LIVE"; [ "$seg" = "paid" ] && live="$PAID_LIVE"
  if [ "$live" != 1 ]; then log "$tag: DRY-RUN tick (no send)"; return 0; fi
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
  local shared; read -r n daily shared <<<"$rm"
  if [ "${n:-0}" -le 0 ]; then log "$tag: daily cap reached for $campaign/$seg; no apply"; return 0; fi
  local fit=$(( (TICK_HARD_S - $(elapsed)) / APPLY_S_PER_USER ))
  if [ "$fit" -le 0 ]; then log "$tag: no time left before the ${TICK_HARD_S}s deadline; no apply this tick"; return 0; fi
  if [ "$n" -gt "$fit" ]; then log "$tag: apply cut from $n to $fit (what fits before the ${TICK_HARD_S}s deadline)"; n="$fit"; fi
  local lo; lo="$(maxid)"
  [ "$lo" -ge 0 ] || { autokill "$tag: ledger unreadable before the apply"; return 1; }
  local capargs=(); [ "$sub" = uvn-status ] && capargs=(--segment-daily-cap "$daily")
  # QA #1541 (uvn_status.py:869): the runner also caps each campaign per UTC day by itself (CREDIT_UVN_DAILY_MAX,
  # default 400 / CREDIT_STATUS_DAILY_MAX, default 1000, both segments together). Left at those defaults it binds
  # BELOW the policy and later ticks would report room but send 0. For this apply it gets the policy's shared group
  # cap (the binding daily total), so one number governs and room() and the runner cannot disagree.
  CREDIT_UVN_DAILY_MAX="$shared" CREDIT_STATUS_DAILY_MAX="$shared" \
  py "$runner" "$sub" --list "$list" --segment "$seg" "$@" "${excl[@]}" --mode apply --max-users "$n" "${capargs[@]}" \
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
    log "$tag zero-read ledger $((lo + 1))-$hi (rc=$zrc): ${zr:0:300}"
    [ "$zrc" = 0 ] || { autokill "$tag zero-read $([ "$zrc" = 1 ] && echo STOP || echo UNMEASURED) for ledger $((lo + 1))-$hi: ${zr:0:200}"; return 1; }
  fi
  [ "$rc" = 0 ] || { log "$tag: apply failed rc=$rc; tick stops"; return 1; }
}

# ---- audiences (deployed builders only) ----------------------------------------------------------------------
py "$OWING" --out "$OUT/owing.json" > "$OUT/owing.out" 2>&1 || { log "owing builder failed: $(tail -c 300 "$OUT/owing.out")"; exit 1; }
py "$RECEIPTS" --out-dir "$OUT/receipts" > "$OUT/receipts.out" 2>&1 || { log "receipts builder failed: $(tail -c 300 "$OUT/receipts.out")"; exit 1; }
# r5 on #1541: the uvn-status family is the UVN class only (owing_proof also lists hold classes - review_hold /
# account_hold - that the uvn-status runner does not cover; they belong to their own campaign's family)
py - "$OUT/owing.json" "$OUT/owing-uvn.json" <<'PY' >> "$OUT/tick.log" || { log "owing split failed"; exit 1; }
import json, sys, collections
d = json.load(open(sys.argv[1]))
users = d.get("users") or []
json.dump({**d, "users": [u for u in users if u.get("class", "uvn") == "uvn"]}, open(sys.argv[2], "w"))
print("owing classes:", dict(collections.Counter(u.get("class", "uvn") for u in users)), "-> uvn-status family gets the uvn class")
PY
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
