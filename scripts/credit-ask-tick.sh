#!/usr/bin/env bash
# credit-ask-tick: one bounded pass of the per-need proof ask (campaign proof-need-ask) between two rounds of the
# hourly outbound tick. Operator doc: docs/credit-verification/credit-ask-tick.md.
#
# It builds the need-ask list and hands ONE segment (paid, then free, alternating) to the one reviewed ask path,
# `credit_review/need_asks.py`. It decides nothing about a user and writes no copy: every gate the sender has (the
# campaign lock, the copy gate, the live recipient gates, the distributor preflight, the shared daily cap, the deploy
# head rail) runs unchanged, and this script has no flag that skips one. The policy's own per-tick and per-family
# daily rows are read here too, so this path cannot outrun the caps the hourly tick enforces.
#
# The send is the hourly tick's own two-step path, not a direct apply: the family's arming row is read first (a
# disarmed family or an unreached unsigned date sends nothing), then a read-only `--check-recipients` pass, then an
# apply handed that check's `--signed-accepted` set with `--page`. Without the signed set the sender would apply to
# every user on the page, including users the real gate deferred - the bypass this path exists to avoid.
#
# Why it has this shape (measured on node-8, 2026-11-14 23:55Z to 2026-11-15 01:55Z, on the hand-installed version):
#   - no cursor: every run walked the same first 200 paid entries, 40 minutes of gate calls, 0 sent, and was killed at
#     its 3600 s timeout before or during the free segment. A run now walks the list in batches and saves where it stopped after each.
#   - the run outlived its 30-minute timer, so the unit restarted the second it was killed and held the credit-group
#     run lock without a gap. The hourly tick's first credit apply then found the lock taken ("another uvn-status
#     apply run is in progress"), which that tick treats as a failed apply: every credit family behind it was dropped
#     at 00:18Z and 01:15Z. A run now ends inside RUN_S, is killed at HARD_S, and yields to an outbound tick in flight.
#   - `distributor_preflight_not_ok` was never one broken dependency: it labels a per-user gate answer, and the
#     sender now prints that answer with the label.
#
# Exit: 0 ran, yielded or stopped cleanly; 1 a step failed or could not be measured (the unit pages); 2 bad config.
#
# Reviewed baseline: deploy overwrites. node-8 carries a hand-written file at this path that was never in git
# (installed 2026-11-14 23:26Z: no cursor, no budget, both segments in one run under a 3600 s timeout). The path is
# absent at the baseline, so the three-way check reads the server's bytes as differing from both the baseline and HEAD
# and classifies this file CONFLICT; the deploy takes the repository's copy only because this HEAD blob carries the
# marker line just above (scripts/lib/delta-sync.sh, delta_gate). A hand-written file added to a future delta needs
# that same line, or the deploy hard-stops on it.
set -uo pipefail

# Every gate input is a constant. The one seam is the bats harness (bats sets BATS_TEST_TMPDIR to a directory for
# every test): only there are the ASK_TICK_* / HYDRA_ROOT / PY_BIN values read. Same posture as the outbound tick.
if [ -n "${BATS_TEST_TMPDIR:-}" ] && [ -d "${BATS_TEST_TMPDIR}" ]; then ASK_TICK_HARNESS=1; else ASK_TICK_HARNESS=0; fi
cfg() { # <env name> <constant>: the constant, or under the bats harness only the test value
  if [ "$ASK_TICK_HARNESS" = 1 ]; then local n="$1"; printf '%s' "${!n:-$2}"; else printf '%s' "$2"; fi
}
HYDRA_ROOT="$(cfg HYDRA_ROOT /opt/hydra)"
ETC="$(cfg ASK_TICK_ETC /etc/hydra)"
STATE="$(cfg ASK_TICK_STATE /var/lib/hydra/credit-ask-tick)"
# The hand-installed version took this same path, so a copy of it still running excludes this one and the reverse.
LOCK="$(cfg ASK_TICK_LOCK /run/credit-ask-tick.lock)"
OUTBOUND_LOCK="$(cfg ASK_TICK_OUTBOUND_LOCK /var/lib/hydra/credit-verify-outbound/tick.lock)"
RUNNER="$(cfg ASK_TICK_RUNNER "$HYDRA_ROOT/scripts/credit_review/need_asks.py")"
POLICY="$(cfg ASK_TICK_POLICY "$HYDRA_ROOT/policies/credit-verify-outbound.json")"
LEDGER="$(cfg ASK_TICK_LEDGER /var/lib/hydra/credit-review/ledger.sqlite3)"
PY="$(cfg PY_BIN python3)"
TIMEOUT_BIN="$(cfg ASK_TICK_TIMEOUT_BIN timeout)"
KILL="$ETC/credit-ask-tick.disabled"
KILL_LEGACY="$ETC/credit-ask-STOP"     # the hand-installed version's stop file: still honoured, never removed here
# The outbound tick's safety checks, run after every apply of this one (scripts/credit-verify-outbound.sh family_run):
# the mail health read, the refusal spike, the fraud re-check, the durable zero-read and the v1 sample pointer.
HEALTH="$(cfg ASK_TICK_HEALTH "$HYDRA_ROOT/scripts/paid-status/health_check.py")"
ZERO_READ="$(cfg ASK_TICK_ZERO_READ "$HYDRA_ROOT/scripts/credit_verify/zero_read.py")"
FRAUD="$(cfg ASK_TICK_FRAUD '')"       # harness only: a fraud re-check stub; production reads the lens inline
REFUSAL_SPIKE="$(cfg ASK_TICK_REFUSAL_SPIKE 0.20)"
NOTIFY_LIB="$(cfg ASK_TICK_NOTIFY_LIB "$HYDRA_ROOT/scripts/lib/slack-notify.sh")"
RUN_START="$(date -u +%FT%TZ)"

# The budget. INTERVAL_S is the timer's period (credit-ask-tick.timer, pinned to this by a bats test). A run's sends
# are budgeted to end by RUN_S, any step still running at HARD_S is killed, and systemd's TimeoutStartSec sits above
# HARD_S and under INTERVAL_S: two runs cannot overlap. Whatever RUN_S allows, a run also ends OUTBOUND_MARGIN_S
# before the hourly outbound tick's cron at :00 (below), so no apply of this one holds the credit-group lock then.
INTERVAL_S="$(cfg ASK_TICK_INTERVAL_S 1800)"
# A run walks the list in batches until RUN_S (or the outbound tick's next start, below) leaves no room for another.
# HARD_S is the last resort for a hung step; the unit's TimeoutStartSec sits past HARD_S + the kill grace.
RUN_S="$(cfg ASK_TICK_RUN_S 1500)"
HARD_S="$(cfg ASK_TICK_HARD_S 1680)"
KILL_GRACE_S="$(cfg ASK_TICK_KILL_GRACE_S 30)"
# SIGKILL this long after a step's SIGTERM at its deadline.
# The least a send is started with. The send loop starts no user whose worst case (verify_notify.WORST_USER_S, 200 s)
# would not fit its share, so a share at or under that sends nobody; a bats test holds this above it.
MIN_SHARE_S="$(cfg ASK_TICK_MIN_SHARE_S 230)"
# List entries walked per BATCH. Each batch is one read-only check and, when the check accepted anyone, one apply; the
# cursor is saved after every batch, so a killed run resumes at the first batch it did not finish. The check pays a
# gate call per gated user (about 12 s; most entries are filtered before the gate), so 20 keeps a batch near a minute.
PAGE="$(cfg ASK_TICK_PAGE 20)"
# The longest share one apply is handed. The apply is the only step that holds the credit-group run lock
# (ledger.sqlite3.credit-group.run.lock, taken inside need_asks' apply and released when it exits), so this is the
# longest that lock is held at a time; between batches it is free.
BATCH_APPLY_S="$(cfg ASK_TICK_BATCH_APPLY_S 300)"
MAX_BATCHES="$(cfg ASK_TICK_MAX_BATCHES 200)"
# The hourly outbound tick starts at minute :00 (/etc/cron.d/credit-verify-outbound) and refuses its credit applies
# when another run holds the credit-group lock (it retries only a deploy's APPLY_LOCK_HELD). No batch of this run may
# still be running then: the run ends OUTBOUND_MARGIN_S before the next :00, which also covers HARD_S - RUN_S of overrun.
OUTBOUND_MARGIN_S="$(cfg ASK_TICK_OUTBOUND_MARGIN_S 240)"
OUTBOUND_DUE_S="$(cfg ASK_TICK_OUTBOUND_DUE_S '')"   # harness only: seconds from the run's start to the next :00
ELAPSED0="$(cfg ASK_TICK_ELAPSED0 0)"   # harness only: seconds already spent, so no test sleeps
FAMILY=proof-need-ask

T0="$(date +%s)"
elapsed() { echo $(( $(date +%s) - T0 + ELAPSED0 )); }
log() { printf '%s credit-ask-tick: %s\n' "$(date -u +%FT%TZ)" "$*"; }
killed() { [ -e "$KILL" ] || [ -e "$KILL_LEGACY" ]; }
# A held flock is a live outbound tick (the same read scripts/lib/deploy-send-tick-hold.sh makes).
outbound_in_flight() { [ -e "$OUTBOUND_LOCK" ] && ! flock -n -x "$OUTBOUND_LOCK" true 2>/dev/null; }

# ── the safety checks after every apply (the outbound tick's, scripts/credit-verify-outbound.sh) ──
page() { # best effort: the kill file is the guarantee, the page is the notice
  # shellcheck source=/dev/null
  if [ -r "$NOTIFY_LIB" ] && . "$NOTIFY_LIB" 2>/dev/null && declare -F slack_notify_critical >/dev/null; then
    slack_notify_critical "credit-ask-tick: $*" >/dev/null 2>&1 || log "page not delivered: $*"
  else
    log "page not delivered (no notifier at $NOTIFY_LIB): $*"
  fi
}
autokill() { # <why>: the kill file first, then the page. Nothing more of this family runs until a human removes it.
  if printf 'auto-kill %s: %s\n' "$(date -u +%FT%TZ)" "$1" > "$KILL" 2>/dev/null; then
    log "AUTO-KILL: $1 (wrote $KILL)"
    page "AUTO-KILL: $1. Nothing more runs until a human reads the ledger and removes $KILL."
  else
    log "AUTO-KILL: $1 - the kill file $KILL could NOT be written"
    page "AUTO-KILL FAILED TO PERSIST: $1 ($KILL could not be written); the run stops, the next one is NOT stopped"
  fi
}
maxid() { "$PY" -c 'import sqlite3,sys
try:
    print(sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True).execute("SELECT coalesce(max(id),0) FROM verify_messages").fetchone()[0])
except sqlite3.Error:
    print(-1)' "$LEDGER" 2>/dev/null || echo -1; }
nsent_between() { # <lo> <hi>: the ledger's own count of sent/attempted rows in (lo, hi], -1 when unreadable
  "$PY" -c 'import sqlite3,sys
try:
    print(sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True).execute(
        "SELECT count(*) FROM verify_messages WHERE id > ? AND id <= ? AND status IN (?, ?)",
        (int(sys.argv[2]), int(sys.argv[3]), "sent", "attempted")).fetchone()[0])
except sqlite3.Error:
    print(-1)' "$LEDGER" "$1" "$2" 2>/dev/null || echo -1; }
spike() { # <outcomes json> <sent>: ok | spike | unmeasured <why> (the outbound tick's rule, unchanged)
  "$PY" - "$1" "$2" "$REFUSAL_SPIKE" <<'PY'
import json, sys
path, sent, limit = sys.argv[1], int(sys.argv[2]), float(sys.argv[3])
try:
    with open(path, encoding="utf-8") as fh:
        o = json.load(fh).get("outcomes")
except FileNotFoundError:
    print(f"unmeasured {path} was never written (the apply did not reach its outcome write)"); sys.exit()
except (OSError, ValueError, AttributeError) as exc:
    print(f"unmeasured {path} is unreadable ({exc})"); sys.exit()
if not isinstance(o, list):
    print(f"unmeasured {path} carries no outcomes list (got {type(o).__name__})"); sys.exit()
pf = [x for x in o if str((x or {}).get("result", "")).startswith("post_failed")]
if pf:
    print(f"unmeasured {len(pf)} post(s) with an UNKNOWN outcome (POST FAILED: attempted, and we cannot prove it was "
          "not delivered)"); sys.exit()
refused = sum(1 for x in o if str((x or {}).get("result", "")).startswith("refused"))
n = sent + refused
print("spike" if n >= 10 and refused / n > limit else "ok")
PY
}
fraudhit() { # <lo> <hi>: ok | hit <ids> | unreadable <why>. A held account that RECEIVED a message is the hit.
  if [ -n "$FRAUD" ]; then "$PY" "$FRAUD" "$LEDGER" "$1" "$2" 2>&1 | tail -1; return 0; fi
  PYTHONPATH="$HYDRA_ROOT/scripts${PYTHONPATH:+:$PYTHONPATH}" "$PY" - "$LEDGER" "$1" "$2" <<'PY' 2>&1 | tail -1
import sqlite3, sys
try:
    db = sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True)
    ids = sorted({str(r[0]) for r in db.execute(
        "SELECT DISTINCT account_id FROM verify_messages WHERE id > ? AND id <= ? AND status IN ('sent','attempted') "
        "AND account_id IS NOT NULL", (int(sys.argv[2]), int(sys.argv[3]))) if str(r[0]).isdigit()})
    if not ids:
        print("ok"); sys.exit()
    from credit_review import fraud_lens, verify_notify
    held = fraud_lens.split(ids, fraud_lens.default_lens(verify_notify.trino))["held"]
except SystemExit:
    raise
except Exception as exc:  # an unreadable lens after a send is a stop, never a pass
    print(f"unreadable {type(exc).__name__} {str(exc)[:160]}"); sys.exit()
print("hit " + ",".join(str(h["user_id"]) for h in held) if held else "ok")
PY
}
# rails <batch> <lo> <outcomes json|-> : 0 = every check read clean; 1 = auto-killed (the kill file is written);
# 2 = the zero-read could not read a source: this run stops, it is paged, and no kill file is written (the outbound
# tick's ruling B: an UNMEASURED never wedges the family). An outcomes file of '-' (a killed apply) skips the spike,
# because a killed apply wrote none, and still reads back every row it did write.
rails() {
  local n="$1" lo="$2" outc="$3" h hrc hi ns sv fh zr zrc
  h="$("$PY" "$HEALTH" --since "$RUN_START" --bounce-max-pct 2 --unsub-max-pct 2 --spam-max-pct 2 2>&1 | tail -1)"; hrc=${PIPESTATUS[0]}
  log "batch $n health (rc=$hrc): ${h:0:300}"
  [ "$hrc" = 0 ] || { autokill "batch $n health check rc=$hrc: ${h:0:200}"; return 1; }
  hi="$(maxid)"
  [ "$hi" -ge 0 ] 2>/dev/null || { autokill "batch $n: ledger unreadable after the apply"; return 1; }
  ns="$(nsent_between "$lo" "$hi")"
  [ "$ns" -ge 0 ] 2>/dev/null || { autokill "batch $n: ledger unreadable after the apply"; return 1; }
  if [ "$outc" != - ]; then
    sv="$(spike "$outc" "$ns")"
    case "$sv" in
      ok) ;;
      spike) autokill "batch $n refusal spike: $ns sent and the apply's own outcomes refused more than ${REFUSAL_SPIKE} of attempts (ledger $((lo + 1))-$hi)"; return 1 ;;
      unmeasured*) autokill "batch $n OUTCOMES UNMEASURED after $ns send(s) (ledger $((lo + 1))-$hi): ${sv#unmeasured }; this is not a spike - read the sends back before lifting"; return 1 ;;
      *) autokill "batch $n spike() answered '${sv:0:120}' - an unexpected verdict is not a pass (ledger $((lo + 1))-$hi)"; return 1 ;;
    esac
  fi
  [ "$ns" -gt 0 ] || return 0
  fh="$(fraudhit "$lo" "$hi")"
  log "batch $n fraud re-check ledger $((lo + 1))-$hi: ${fh:0:300}"
  [ "$fh" = ok ] || { autokill "batch $n FRAUD ${fh:0:200} (ledger $((lo + 1))-$hi)"; return 1; }
  printf '{"at":"%s","tick":"credit-ask-tick","family":"%s","ledger_ids":"%s-%s","outcomes":"%s"}\n' \
    "$(date -u +%FT%TZ)" "$FAMILY" "$((lo + 1))" "$hi" "$outc" >> "$STATE/samples.jsonl" 2>/dev/null \
    || { autokill "batch $n: the v1 sample pointer for ledger $((lo + 1))-$hi could not be written"; return 1; }
  zr="$("$PY" "$ZERO_READ" --ledger-ids "$((lo + 1))-$hi" 2>&1 | tail -1)"
  # The reader prints one verdict line. A STOP of any form is a STOP and wins over UNMEASURED; anything else is a crash,
  # i.e. a source nobody read, and UNMEASURED is the honest reading of it (the outbound tick's QA #1545 / #1747 rules).
  case "${zr:-}" in
    OK|OK:*) zrc=0 ;;
    UNMEASURED|UNMEASURED:*) zrc=2 ;;
    STOP|STOP:*|STOP+UNMEASURED|STOP+UNMEASURED:*) zrc=1 ;;
    *) zr="UNMEASURED: the zero-read printed no verdict (a crash is not a STOP): ${zr:0:200}"; zrc=2 ;;
  esac
  log "batch $n zero-read ledger $((lo + 1))-$hi (rc=$zrc): ${zr:0:300}"
  if [ "$zrc" = 1 ]; then autokill "batch $n zero-read ${zr:0:240} (ledger $((lo + 1))-$hi)"; return 1; fi
  if [ "$zrc" = 2 ]; then
    page "zero-read UNMEASURED for $FAMILY ledger $((lo + 1))-$hi: ${zr:0:200}. This run stopped; the next run reads again."
    return 2
  fi
  return 0
}
# <end second> <command...>: the command, killed at that second of the run (SIGTERM, SIGKILL KILL_GRACE_S later).
bounded_to() { local end="$1"; shift; local left=$(( end - $(elapsed) )); [ "$left" -ge 1 ] || left=1
  "$TIMEOUT_BIN" --kill-after="$KILL_GRACE_S" "${left}s" "$@"; }
deadline_rc() { [ "$1" = 124 ] || [ "$1" = 137 ]; }

if killed; then log "stop file present ($KILL or $KILL_LEGACY); nothing runs"; exit 0; fi

for v in "$INTERVAL_S" "$RUN_S" "$HARD_S" "$KILL_GRACE_S" "$MIN_SHARE_S" "$PAGE" "$ELAPSED0" "$BATCH_APPLY_S" \
         "$MAX_BATCHES" "$OUTBOUND_MARGIN_S" "${OUTBOUND_DUE_S:-0}"; do
  case "$v" in ''|*[!0-9]*) log "BAD CONFIG: '$v' is not a whole number; nothing runs"; exit 2 ;; esac
done
if [ "$PAGE" -lt 1 ] || [ "$MAX_BATCHES" -lt 1 ] || [ "$RUN_S" -le "$MIN_SHARE_S" ] || [ "$RUN_S" -ge "$HARD_S" ] \
   || [ "$BATCH_APPLY_S" -lt "$MIN_SHARE_S" ] || [ $(( HARD_S + 60 )) -gt "$INTERVAL_S" ] \
   || [ "$OUTBOUND_MARGIN_S" -lt $(( HARD_S - RUN_S )) ]; then
  log "BAD BUDGET: page $PAGE, batches $MAX_BATCHES, share floor ${MIN_SHARE_S}s, batch apply ${BATCH_APPLY_S}s, run ${RUN_S}s, hard stop ${HARD_S}s, outbound margin ${OUTBOUND_MARGIN_S}s, timer period ${INTERVAL_S}s. A run must fit one send (run > share floor, batch apply >= share floor), end before its hard stop, the hard stop must sit at least 60 s inside the timer period, and the outbound margin must cover the hard stop's overrun; nothing runs"
  exit 2
fi
# Where this run must end: RUN_S, or OUTBOUND_MARGIN_S before the outbound tick's next start, whichever is first.
if [ -n "$OUTBOUND_DUE_S" ]; then due="$OUTBOUND_DUE_S"; else due=$(( 3600 - $(date -u +%s) % 3600 )); fi
RUN_END=$(( ELAPSED0 + due - OUTBOUND_MARGIN_S ))
[ "$RUN_END" -le "$RUN_S" ] || RUN_END="$RUN_S"
# An apply that overruns its share is killed this long after the run's end at the latest, inside the margin.
APPLY_END=$(( RUN_END + HARD_S - RUN_S ))

install -d -m 700 "$STATE" 2>/dev/null || { log "cannot create $STATE; nothing runs"; exit 2; }
exec 9>>"$LOCK" || { log "cannot open the run lock $LOCK; nothing runs"; exit 2; }
if ! flock -n 9; then log "another run holds $LOCK; exit"; exit 0; fi

# One line per run and $STATE/last-run.json, read from the sender's own output and outcomes file. A number the
# sender did not print is `unmeasured`, never 0. Reasons are counted by class; no user id reaches the journal.
# A run that did not reach the sender reads no sender file: an earlier run's numbers are never this run's.
SENDER_RAN=0
BATCHES=0
# Every batch leaves check-<seg>-<n>.json (the gate's answer for each walked user), and an applied batch also
# send-<seg>-<n>.out and outcomes-<seg>-<n>.json. The record sums them: the senders' figures, why each applied user
# was not sent, and why each walked user never reached the apply (the gate's reason, or the filter before the gate).
record() { # <state> <segment> <rc> <this run's start entry> <next start entry> <1 when the sender was run> <batches>
  "$PY" - "$STATE" "$@" <<'PY'
import collections, datetime, json, os, re, sys, tempfile

state_dir, state, seg, rc, start, nxt, ran, batches = sys.argv[1:9]
ran, batches = ran == "1", int(batches)


def last_json(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            lines = fh.read().splitlines()
    except OSError:
        return {}
    for line in reversed(lines):
        if line.lstrip().startswith("{"):
            try:
                doc = json.loads(line)
            except ValueError:
                continue
            if isinstance(doc, dict):
                return doc
    return {}


def reason_class(row):
    words = [w for w in re.split(r"[ :(;,]+", str(row.get("reason") or "")) if w]
    if words and words[0] == "HELD":
        words = words[1:]
    return f"{row.get('result')}/{words[0] if words else '?'}"


def load(path):
    try:
        with open(path, encoding="utf-8") as fh:
            doc = json.load(fh)
    except (OSError, ValueError):
        return {}
    return doc if isinstance(doc, dict) else {}


KEYS = ("candidates", "sent", "deferred", "refused", "failed")
totals = {k: 0 for k in KEYS}
reasons, gate, filtered = collections.Counter(), collections.Counter(), collections.Counter()
halted, refusals, page, applied, walked = "", [], None, 0, 0
for n in range(1, batches + 1):
    check = load(os.path.join(state_dir, f"check-{seg}-{n}.json"))
    gate.update(reason_class(r) for r in (check.get("outcomes") or [])
                if isinstance(r, dict) and r.get("result") != "accepted")
    filtered.update(reason_class(r) for r in (check.get("filtered") or []) if isinstance(r, dict))
    if isinstance(check.get("listed"), int):
        walked += check["listed"]
    page = check.get("page") or page
    out = os.path.join(state_dir, f"send-{seg}-{n}.out")
    if not (ran and os.path.exists(out)):
        continue
    applied += 1
    summary = last_json(out)
    outcomes = load(os.path.join(state_dir, f"outcomes-{seg}-{n}.json"))
    reasons.update(reason_class(r) for r in (outcomes.get("outcomes") or []) if isinstance(r, dict))
    page = outcomes.get("page") or page
    for key in KEYS:
        v = summary.get(key)
        totals[key] = totals[key] + v if isinstance(v, int) and isinstance(totals[key], int) else None
    halted = str(summary.get("halted") or "")[:300] or halted
    refusals += [str(r)[:300] for r in (summary.get("refusals") or [])]
if not applied:
    totals = {k: None for k in KEYS}
doc = {"at": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"), "state": state,
       "sender_ran": ran,
       "segment": None if seg == "-" else seg, "rc": int(rc), "start_entry": int(start), "next_entry": int(nxt),
       "batches": batches, "applied_batches": applied, "walked": walked,
       "page": page, "reasons": dict(reasons.most_common()),
       "gate_skips": dict(gate.most_common()), "filtered_before_gate": dict(filtered.most_common()),
       "halted": halted, "refusals": refusals[:10], **totals}
fd, tmp = tempfile.mkstemp(prefix=".last-run-", dir=state_dir)
with os.fdopen(fd, "w", encoding="utf-8") as fh:
    json.dump(doc, fh, indent=1)
os.replace(tmp, os.path.join(state_dir, "last-run.json"))
num = lambda k: "unmeasured" if doc[k] is None else doc[k]  # noqa: E731
if ran:
    line = (f"{state}: segment {seg}, {batches} batch(es), {applied} applied, entries from {start}, next run starts "
            f"at {nxt}; candidates "
            f"{num('candidates')}, sent {num('sent')}, deferred {num('deferred')}, refused {num('refused')}, "
            f"failed {num('failed')}")
else:
    line = f"{state}: the sender was not run; segment {seg}, next run starts at entry {nxt}"
if doc["halted"]:
    line += f"; halted: {doc['halted']}"
if reasons:
    line += "; not sent because: " + ", ".join(f"{k} x{v}" for k, v in reasons.most_common(8))
if gate:
    line += "; the gate did not accept: " + ", ".join(f"{k} x{v}" for k, v in gate.most_common(8))
if filtered:
    line += "; filtered before the gate: " + ", ".join(f"{k} x{v}" for k, v in filtered.most_common(8))
print(line)
PY
}
finish() { # <exit code> <state> [segment rc start next]: the run's record, then the exit
  local code="$1" line; shift
  if line="$(record "$1" "${2:--}" "${3:-0}" "${4:-0}" "${5:-0}" "$SENDER_RAN" "$BATCHES")"; then log "$line"
  else log "$1 (the run record $STATE/last-run.json could not be written)"; [ "$code" != 0 ] || code=1; fi
  exit "$code"
}

if outbound_in_flight; then
  log "the outbound tick is in flight ($OUTBOUND_LOCK is held): it owns the credit-group budget now; this run yields"
  finish 0 yielded_to_outbound_tick
fi
# No live send without the readers that check it afterwards (the outbound tick's LIVE REFUSED rule, QA #1541).
if [ ! -r "$ZERO_READ" ] || [ ! -r "$HEALTH" ]; then
  log "LIVE REFUSED: the zero-read reader ($ZERO_READ) or the health read ($HEALTH) is not deployed; nothing built, nothing sent"
  page "live run refused: $ZERO_READ or $HEALTH missing"
  finish 1 rails_missing
fi
if [ "$RUN_END" -lt "$RUN_S" ] && [ $(( RUN_END - $(elapsed) )) -le "$MIN_SHARE_S" ]; then
  log "the outbound tick starts in $(( RUN_END + OUTBOUND_MARGIN_S - $(elapsed) ))s: too soon for one send to finish ${OUTBOUND_MARGIN_S}s before it; this run yields"
  finish 0 outbound_tick_due
fi

# ── the family's arming ──
# The hourly tick applies a family only when the policy's own row arms it for that segment and its unsigned date has
# passed (`family_armed` / `reached` in credit-verify-outbound.sh). A scheduled sender that skipped that row could
# apply while the family is disarmed, so the same row is read here first and a read that cannot answer sends nothing.
# No `armed_families` at all is the pre-policy shape: the two legacy flag files decide, exactly as the hourly tick reads
# them. `unsigned_from` absent or empty means no date to wait for.
read -r arm_state arm_live arm_paid arm_reached <<<"$("$PY" - "$POLICY" "$FAMILY" <<'PY'
import datetime, json, sys
path, family = sys.argv[1:3]
try:
    with open(path, encoding="utf-8") as fh:
        doc = json.load(fh)
except (OSError, ValueError) as exc:
    print("ERR", f"cannot read it ({str(exc)[:160].replace(chr(10), ' ')})", "0", "0"); sys.exit(0)
if not isinstance(doc, dict):
    print("ERR", "it is not a JSON object", "0", "0"); sys.exit(0)
rows = doc.get("armed_families")
if rows is None:
    print("LEGACY", "0", "0", "0"); sys.exit(0)
if not isinstance(rows, dict):
    print("ERR", "armed_families is not an object", "0", "0"); sys.exit(0)
row = rows.get(family)
if row is None:
    print("OK", "0", "0", "0"); sys.exit(0)
if not isinstance(row, dict):
    print("ERR", f"armed_families.{family} is not an object", "0", "0"); sys.exit(0)
live, paid = row.get("live"), row.get("paid")
if not isinstance(live, bool) or not isinstance(paid, bool):
    print("ERR", f"armed_families.{family} has no boolean live/paid", "0", "0"); sys.exit(0)
uf = row.get("unsigned_from")
if uf is None or uf in ("", "-"):
    reached = 1
elif not isinstance(uf, str):
    print("ERR", f"armed_families.{family}.unsigned_from is not a string", "0", "0"); sys.exit(0)
else:
    when = None
    for fmt in ("%Y-%m-%dT%H:%MZ", "%Y-%m-%dT%H:%M:%SZ"):
        try:
            when = datetime.datetime.strptime(uf, fmt).replace(tzinfo=datetime.timezone.utc)
            break
        except ValueError:
            pass
    if when is None:
        print("ERR", f"armed_families.{family}.unsigned_from {uf!r} is not an instant", "0", "0"); sys.exit(0)
    reached = 1 if datetime.datetime.now(datetime.timezone.utc) >= when else 0
print("OK", "1" if live else "0", "1" if paid else "0", str(reached))
PY
)"
case "$arm_state" in
  OK) ;;
  ERR) log "POLICY UNREADABLE (arming): $POLICY $arm_live; nothing sent"
       finish 1 arming_unreadable - 0 0 0 ;;
  LEGACY)
    arm_live=0; [ -e "$ETC/credit-verify-outbound.live" ] && arm_live=1
    arm_paid=0; [ "$arm_live" = 1 ] && [ -e "$ETC/credit-verify-outbound.paid-enabled" ] && arm_paid=1
    arm_reached=1 ;;
  *) log "POLICY UNREADABLE (arming): the arming read answered nothing; nothing sent"
     finish 1 arming_unreadable - 0 0 0 ;;
esac
if [ "$arm_live" != 1 ] || [ "$arm_reached" != 1 ]; then
  log "$FAMILY: the policy does not arm this family (live=$arm_live, unsigned_from reached=$arm_reached); nothing sent"
  finish 0 family_not_armed - 0 0 0
fi

# ── the list ──
LIST="$STATE/asks.json"; LIST_TMP="$LIST.tmp"
rm -f "$LIST_TMP" 2>/dev/null
bounded_to $(( RUN_END - MIN_SHARE_S )) "$PY" "$RUNNER" build --out "$LIST_TMP" > "$STATE/build.out" 2>&1; rc=$?
if [ "$rc" != 0 ] || [ ! -s "$LIST_TMP" ]; then
  rm -f "$LIST_TMP"
  if deadline_rc "$rc"; then log "BUILD KILLED at $(( RUN_END - MIN_SHARE_S ))s: the list was not built in the time that leaves room for one send; nothing sent"
  else log "BUILD FAILED (rc=$rc): $(tail -n 1 "$STATE/build.out" 2>/dev/null | cut -c1-300); nothing sent"; fi
  finish 1 build_failed
fi
mv -f "$LIST_TMP" "$LIST" || { log "cannot move the built list into place; nothing sent"; finish 1 build_failed; }
log "list built in $(elapsed)s: $(tail -n 1 "$STATE/build.out" 2>/dev/null | cut -c1-400)"

# ── one segment ──
seg="$(cat "$STATE/next-segment" 2>/dev/null || true)"; [ "$seg" = free ] || seg=paid
# A paid segment the policy does not arm is never applied; the free segment carries every run until it is armed.
if [ "$seg" = paid ] && [ "$arm_paid" != 1 ]; then
  log "$FAMILY/paid: the policy does not arm the paid segment; this run takes free"
  seg=free
fi
other=free; [ "$seg" = free ] && other=paid
[ "$arm_paid" = 1 ] || other=free
cur="$(cat "$STATE/cursor-$seg" 2>/dev/null || echo 0)"; [[ "$cur" =~ ^[0-9]{1,9}$ ]] || cur=0

if killed; then log "stop file placed during the build; nothing sent"; finish 0 stopped "$seg" 0 "$cur" "$cur"; fi
if outbound_in_flight; then
  log "the outbound tick started during the build; this run yields before any send"
  finish 0 yielded_to_outbound_tick "$seg" 0 "$cur" "$cur"
fi

# The family's caps in the policy, the same rows the outbound tick's room() honours. The per-tick cap bounds this
# RUN's attempts (all batches together); the per-family daily cap (which need_asks does not read on this path) is
# counted against today's proof-need-ask ledger rows, both segments together - the same count room() makes, because
# need_asks keeps no per-segment record. Both are read again before every batch, so what a batch spent is what the next
# one sees: the ledger, not this script, is the count. A read that cannot answer sends nothing.
read_caps() { # prints: <tick cap> <daily cap> <today's rows>  |  POLICY|LEDGER 0 0 <why>
  "$PY" - "$POLICY" "$LEDGER" "$FAMILY" "$seg" "$PAGE" <<'PY'
import datetime, json, sqlite3, sys
path, ledger, family, seg, page = sys.argv[1:6]
try:
    with open(path, encoding="utf-8") as fh:
        doc = json.load(fh)
except (OSError, ValueError) as exc:
    print("POLICY", "0", "0", str(exc)[:160].replace("\n", " ")); sys.exit(0)
tick = ((doc.get("tick_cap") or {}).get(family) or {}).get(seg)
daily = ((doc.get("daily_cap") or {}).get(family) or {}).get(seg)
if isinstance(daily, bool) or not isinstance(daily, int) or daily < 0:
    print("POLICY", "0", "0", f"daily_cap.{family}.{seg} is not a whole number"); sys.exit(0)
if tick is None:
    tick = int(page)
elif isinstance(tick, bool) or not isinstance(tick, int) or tick < 0:
    print("POLICY", "0", "0", f"tick_cap.{family}.{seg} is not a whole number"); sys.exit(0)
day = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d")
try:
    db = sqlite3.connect(f"file:{ledger}?mode=ro", uri=True)
    used = db.execute("SELECT count(*) FROM verify_messages WHERE day=? AND campaign=? "
                      "AND status IN ('sent','attempted')", (day, family)).fetchone()[0]
    db.close()
except sqlite3.Error as exc:
    print("LEDGER", "0", "0", str(exc)[:160].replace("\n", " ")); sys.exit(0)
print(tick, daily, int(used))
PY
}
# <path> <segment-or-empty>: the first entry after the page a sender's file records, wrapping to 0 at the end
page_next() { "$PY" -c 'import json,sys; p=json.load(open(sys.argv[1])).get("page") or {}; e,n=int(p["end"]),int(p["listed"]); print(e if e < n else 0)' "$1" 2>/dev/null; }
save_cursor() { printf '%s\n' "$1" > "$STATE/cursor-$seg.tmp" && mv -f "$STATE/cursor-$seg.tmp" "$STATE/cursor-$seg"; }

# ── the batches ──
# One batch = one read-only check of PAGE entries from the cursor, then (only when the gate accepted someone) one apply
# of exactly the check's accepted set. The cursor is saved after each batch, so a run killed anywhere resumes at the
# first batch it did not finish; a user that batch already sent is not sent again, because the ledger claims every note
# before it is posted (verify_ledger.claim, one BEGIN IMMEDIATE per user) and the sender skips any request with a live
# claim (verify_ledger.blocked_ids). This script holds no ledger lock: the credit-group run lock lives inside each
# apply process, so between two batches it is free, and the outbound tick is re-read before every check and apply.
rm -f "$STATE"/check-*.json "$STATE"/check-*.out "$STATE"/send-*.out "$STATE"/outcomes-*.json 2>/dev/null
start_cur="$cur"; tick0=""; end_state=ran; rc=0
while :; do
  if [ "$BATCHES" -ge "$MAX_BATCHES" ]; then log "$FAMILY/$seg: $MAX_BATCHES batches walked; the run ends"; break; fi
  if [ "$BATCHES" -gt 0 ]; then
    if killed; then log "stop file placed during the run; no further batch"; end_state=stopped; break; fi
    if outbound_in_flight; then
      log "the outbound tick started; this run yields after $BATCHES batch(es)"; end_state=yielded_to_outbound_tick; break
    fi
  fi
  if [ $(( RUN_END - $(elapsed) )) -le "$MIN_SHARE_S" ]; then
    if [ "$BATCHES" -eq 0 ]; then
      log "SEND NOT REACHED: $(( RUN_END - $(elapsed) ))s of the run are left after the build, and one send needs ${MIN_SHARE_S}s; nothing sent"
      finish 1 send_not_reached "$seg" 0 "$cur" "$cur"
    fi
    log "$FAMILY/$seg: the run's time is spent after $BATCHES batch(es); the next run starts at entry $cur"
    end_state=budget_spent; break
  fi

  read -r tick daily used detail <<<"$(read_caps)"
  case "$tick" in
    POLICY) log "POLICY UNREADABLE: $POLICY gave no per-tick and per-day cap for $FAMILY/$seg ($detail); nothing sent"
            finish 1 policy_unreadable "$seg" 0 "$start_cur" "$cur" ;;
    LEDGER) log "LEDGER UNREADABLE: $LEDGER could not answer today's $FAMILY sends ($detail); nothing sent"
            finish 1 ledger_unreadable "$seg" 0 "$start_cur" "$cur" ;;
  esac
  if ! [[ "$tick" =~ ^[0-9]{1,6}$ ]] || ! [[ "$daily" =~ ^[0-9]{1,9}$ ]] || ! [[ "$used" =~ ^[0-9]{1,9}$ ]]; then
    log "POLICY UNREADABLE: $POLICY gave no per-tick and per-day cap for $FAMILY/$seg; nothing sent"
    finish 1 policy_unreadable "$seg" 0 "$start_cur" "$cur"
  fi
  [ -n "$tick0" ] || tick0="$used"
  if [ "$tick" -lt 1 ]; then
    printf '%s\n' "$other" > "$STATE/next-segment"
    log "$FAMILY/$seg: the policy's per-tick cap is 0; nothing sent, the next run takes $other"
    finish 0 tick_cap_zero "$seg" 0 "$start_cur" "$cur"
  fi
  left=$(( daily - used )); tick_left=$(( tick - (used - tick0) ))
  if [ "$left" -le 0 ]; then
    printf '%s\n' "$other" > "$STATE/next-segment"
    log "$FAMILY/$seg: today's $used sends have used the policy's daily cap of $daily; nothing more sent, the next run takes $other"
    end_state=daily_cap_used; break
  fi
  if [ "$tick_left" -le 0 ]; then
    log "$FAMILY/$seg: this run has sent the policy's per-tick cap of $tick; the next run starts at entry $cur"
    end_state=tick_cap_spent; break
  fi
  cap="$PAGE"; [ "$cap" -le "$tick_left" ] || cap="$tick_left"; [ "$cap" -le "$left" ] || cap="$left"
  BATCHES=$(( BATCHES + 1 )); n="$BATCHES"

  # The real gate, read only. Its `accepted` set is the ONLY set the apply may send; the hourly tick builds the list the
  # same way and hands the same file to the apply. Bounded to leave MIN_SHARE_S for the apply.
  CHECK="$STATE/check-$seg-$n.json"; CHECK_OUT="$STATE/check-$seg-$n.out"
  : > "$CHECK_OUT"
  bounded_to $(( RUN_END - MIN_SHARE_S )) "$PY" "$RUNNER" send --list "$LIST" --segment "$seg" --mode dry-run \
    --max-users "$cap" --max-entries "$PAGE" --start-entry "$cur" --check-recipients --outcomes-json "$CHECK" \
    > "$CHECK_OUT" 2>&1; rc=$?
  if deadline_rc "$rc"; then
    if [ "$n" -gt 1 ]; then
      log "$FAMILY/$seg: batch $n's check did not finish in the run's time; nothing of it sent, the next run starts at entry $cur"
      end_state=budget_spent; rc=0; break
    fi
    log "CHECK KILLED at $(( RUN_END - MIN_SHARE_S ))s: the recipient check did not finish; nothing sent, the cursor stays at $cur"
    finish 1 check_killed "$seg" "$rc" "$start_cur" "$cur"
  fi
  if [ "$rc" != 0 ]; then
    log "CHECK FAILED (rc=$rc): $(grep -v '^{' "$CHECK_OUT" | tail -n 1 | cut -c1-300); nothing more sent"
    finish 1 check_failed "$seg" "$rc" "$start_cur" "$cur"
  fi
  accepted="$("$PY" -c 'import json,sys; a=json.load(open(sys.argv[1])).get("accepted"); print("" if a is None else len(a))' "$CHECK" 2>/dev/null)" || accepted=""
  if ! [[ "$accepted" =~ ^[0-9]{1,6}$ ]]; then
    log "CHECK UNMEASURED: $CHECK records no accepted set; nothing more sent"
    finish 1 check_unmeasured "$seg" "$rc" "$start_cur" "$cur"
  fi

  if [ "$accepted" -eq 0 ]; then
    # This batch is DONE (the gate accepted nobody): the next one starts where the check stopped.
    nxt="$(page_next "$CHECK")" || nxt=""
    if ! [[ "$nxt" =~ ^[0-9]{1,9}$ ]]; then
      log "NO PAGE RECORD in $CHECK: where the check stopped is unmeasured; the cursor stays at $cur"
      finish 1 page_unmeasured "$seg" "$rc" "$start_cur" "$cur"
    fi
    save_cursor "$nxt" || { log "cannot save the cursor; the next run starts at $cur again"; finish 1 cursor_not_saved "$seg" "$rc" "$start_cur" "$cur"; }
    cur="$nxt"
    if [ "$BATCHES" -eq 1 ] && [ "$MAX_BATCHES" -eq 1 ]; then end_state=check_accepted_nobody; break; fi
    if [ "$cur" -eq 0 ]; then log "$FAMILY/$seg: the end of the list is reached"; end_state=pass_complete; break; fi
    continue
  fi

  if outbound_in_flight; then
    log "the outbound tick started during batch $n's check; this run yields before its apply, the next run starts at entry $cur"
    end_state=yielded_to_outbound_tick; break
  fi
  if killed; then log "stop file placed during batch $n's check; nothing of it sent"; end_state=stopped; break; fi
  share=$(( RUN_END - $(elapsed) )); [ "$share" -le "$BATCH_APPLY_S" ] || share="$BATCH_APPLY_S"
  if [ "$share" -lt "$MIN_SHARE_S" ]; then
    if [ "$n" -eq 1 ]; then
      log "SEND NOT REACHED: ${share}s of the run are left after the build and the check, and one send needs ${MIN_SHARE_S}s; nothing sent"
      finish 1 send_not_reached "$seg" 0 "$start_cur" "$cur"
    fi
    log "$FAMILY/$seg: ${share}s left after batch $n's check, under one send's ${MIN_SHARE_S}s; the next run starts at entry $cur"
    end_state=budget_spent; break
  fi

  OUTCOMES="$STATE/outcomes-$seg-$n.json"; SEND_OUT="$STATE/send-$seg-$n.out"
  : > "$SEND_OUT"
  lo="$(maxid)"   # the ledger's last row before this apply: the checks after it read exactly the rows it wrote
  if ! [ "$lo" -ge 0 ] 2>/dev/null; then
    log "the ledger cannot be read before batch $n's apply; nothing of it sent"
    finish 1 ledger_unreadable "$seg" 0 "$start_cur" "$cur"
  fi
  SENDER_RAN=1
  # The apply is handed the check's signed set and its share, and stops itself (it starts no user whose worst case would
  # not fit, and the user in flight finishes). APPLY_END is the last resort for a hung interpreter, not how it ends.
  apply_end=$(( $(elapsed) + share + HARD_S - RUN_S )); [ "$apply_end" -le "$APPLY_END" ] || apply_end="$APPLY_END"
  [ "$apply_end" -le "$HARD_S" ] || apply_end="$HARD_S"
  bounded_to "$apply_end" "$PY" "$RUNNER" send --list "$LIST" --segment "$seg" --mode apply --max-users "$cap" \
    --max-entries "$PAGE" --start-entry "$cur" --apply-budget-s "$share" --signed-accepted "$CHECK" --page \
    --outcomes-json "$OUTCOMES" > "$SEND_OUT" 2>&1; rc=$?
  # the sender was reached: the other segment takes the next run, whatever this one answered
  printf '%s\n' "$other" > "$STATE/next-segment"

  if deadline_rc "$rc"; then
    log "SEND KILLED at ${apply_end}s (rc=$rc): notes may have been sent before the kill; the verify ledger is the record and blocks each of them from a second send; the cursor stays at $cur"
    rails "$n" "$lo" -; [ "$?" = 1 ] && finish 1 auto_killed "$seg" "$rc" "$start_cur" "$cur"
    finish 1 send_killed "$seg" "$rc" "$start_cur" "$cur"
  fi
  if [ "$rc" != 0 ]; then
    # Two answers are another holder's turn, not a failure: the credit-group run lock (another credit sender is
    # applying) and the deploy's apply lock. Nothing was sent by this batch; the cursor stays.
    if grep -qF -e 'another credit-group apply run is in progress' -e 'holds the apply lock' "$SEND_OUT"; then
      finish 0 lock_held_by_another "$seg" "$rc" "$start_cur" "$cur"
    fi
    log "SEND FAILED (rc=$rc): $(grep -v '^{' "$SEND_OUT" | tail -n 1 | cut -c1-300)"
    # whatever a failed apply wrote is still read back; an outcomes file it never wrote is a failure, not a spike
    outc="$OUTCOMES"; [ -s "$OUTCOMES" ] || outc=-
    rails "$n" "$lo" "$outc"; [ "$?" = 1 ] && finish 1 auto_killed "$seg" "$rc" "$start_cur" "$cur"
    finish 1 send_failed "$seg" "$rc" "$start_cur" "$cur"
  fi

  # The next batch starts at the first entry this one did not examine (the apply's own page record). It is saved
  # before the checks read the batch back, so a batch the checks then stop is not walked again: what it sent is done.
  nxt="$(page_next "$OUTCOMES")" || nxt=""
  if [[ "$nxt" =~ ^[0-9]{1,9}$ ]]; then
    save_cursor "$nxt" || { log "cannot save the cursor; the next run starts at $cur again"; nxt=unsaved; }
  fi
  rails "$n" "$lo" "$OUTCOMES"; rr=$?
  if [ "$rr" = 1 ]; then
    if [[ "$nxt" =~ ^[0-9]{1,9}$ ]]; then finish 1 auto_killed "$seg" "$rc" "$start_cur" "$nxt"; fi
    finish 1 auto_killed "$seg" "$rc" "$start_cur" "$cur"
  fi
  if ! [[ "$nxt" =~ ^[0-9]{1,9}$ ]]; then
    if [ "$nxt" = unsaved ]; then finish 1 cursor_not_saved "$seg" "$rc" "$start_cur" "$cur"; fi
    log "NO PAGE RECORD in $OUTCOMES: where this batch stopped is unmeasured; the cursor stays at $cur"
    finish 1 page_unmeasured "$seg" "$rc" "$start_cur" "$cur"
  fi
  cur="$nxt"
  [ "$rr" = 2 ] && finish 1 zero_read_unmeasured "$seg" "$rc" "$start_cur" "$cur"
  if [ "$cur" -eq 0 ]; then log "$FAMILY/$seg: the end of the list is reached"; end_state=pass_complete; break; fi
done
finish 0 "$end_state" "$seg" "$rc" "$start_cur" "$cur"
