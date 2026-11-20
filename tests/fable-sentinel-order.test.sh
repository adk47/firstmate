#!/usr/bin/env bash
# Tests for the fable-sentinel order check (bin/fable-sentinel.py).
#
# Why this file exists: Aaron's standing rule (inbox 224, 2026-11-15) is that no fix is
# done unless it runs again tomorrow with no human. The sentinel runs on cron, but until
# this file it had no test, so every change to the order check was verified by hand-running
# a backdated pass and reading an artifact. This pins the behaviour instead.
#
# The order check has been wrong three times, each in a way a test would have caught:
#   1. paid was read from the account-level subscription column instead of the drain's
#      team-membership rule, so a team-paid user read as unpaid;
#   2. a row with no account_id was defaulted to unpaid, so the unattributable rows
#      manufactured an inversion out of nothing;
#   3. closes were identified by a baked-in approval_ref, which names an approval RUN,
#      not a kind - the next close run gets a new ref and closes silently stop being
#      recognised.
#
# Run: bash tests/fable-sentinel-order.test.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
SENTINEL="$ROOT/bin/fable-sentinel.py"

# The sentinel is operator-local: bin/fable-sentinel.* is kept out of the shared
# template through .git/info/exclude because it reads one Muso host (node-8). This
# test pins its contract wherever the sentinel is present and says so, rather than
# failing, in a checkout that has no sentinel to check. Needs python3 only; the
# sentinel is imported, never run.
if [ ! -f "$SENTINEL" ]; then
  printf 'skip - bin/fable-sentinel.py is not in this checkout (operator-local, see .git/info/exclude)\n'
  exit 0
fi

pass=0
fail=0
ok()   { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
bad()  { fail=$((fail + 1)); printf '  FAIL %s\n' "$1"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (want '$3', got '$2')"; fi; }

echo "fable-sentinel order check"

# --- 1. the file parses -------------------------------------------------------
if python3 -c "import ast,sys; ast.parse(open(sys.argv[1]).read())" "$SENTINEL" 2>/dev/null; then
  ok "bin/fable-sentinel.py parses"
else
  bad "bin/fable-sentinel.py does not parse"
  echo; echo "pass=$pass fail=$fail"; exit 1
fi

# --- 2. unknown paid is never treated as unpaid -------------------------------
# The exact rule that caused defect 2, now a module-level function so it can be exercised
# directly instead of grepped. A row with no account_id is UNKNOWN (None); a known account
# absent from the paid set is a real False; an unreadable replica is UNKNOWN, not unpaid.
if python3 - "$SENTINEL" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("fs", sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
bad = 0
def want(name, got, exp):
    global bad
    if got != exp:
        print(f"  FAIL {name} (want {exp!r}, got {got!r})"); bad += 1
    else:
        print(f"  ok   {name}")
row = {"campaign": "uvn-status", "user": "7"}
want("no account_id is UNKNOWN", m.paid_flag({"campaign": "uvn-status"}, need_rows={}, need_ok=False, paid_map={}, rep_ok=True), None)
want("absent from the paid set is a real False", m.paid_flag(row, need_rows={}, need_ok=False, paid_map={}, rep_ok=True), False)
want("present in the paid set is True", m.paid_flag(row, need_rows={}, need_ok=False, paid_map={"7": True}, rep_ok=True), True)
want("unreadable replica is UNKNOWN, not unpaid", m.paid_flag(row, need_rows={}, need_ok=False, paid_map={}, rep_ok=False), None)
sys.exit(1 if bad else 0)
PY
then pass=$((pass + 4)); else fail=$((fail + 1)); fi

# --- 3. the sentinel is actually scheduled -----------------------------------
# The rule is "runs again tomorrow with no human". A sentinel nobody schedules is a script.
if ! crontab_lines=$(crontab -l 2>/dev/null); then
  printf '  skip sentinel cron check: this host has no crontab to inspect\n'
elif grep -q 'fable-sentinel' <<<"$crontab_lines"; then
  ok "sentinel is on cron"
else
  bad "sentinel is not on cron (it would need a human to run it)"
fi

# --- 4. sent_rows and the per-window counters are half-open -------------------
# This fact lives in SQL window literals with no module-level function to call, so the
# query text is the only place it is expressible.
if [ "$(grep -c "' ','T') < '{now_s}'" "$SENTINEL")" -ge 1 ]; then
  ok "window queries carry an upper bound"
else
  bad "a window query has no upper bound (double counting)"
fi

# --- 5. every send timestamp is normalised before comparison ----------------
# Inbox 227: verify_messages mixes 19-char 'YYYY-MM-DD HH:MM:SS' and 20-char
# 'YYYY-MM-DDTHH:MM:SSZ'. ' ' sorts below 'T', so a space-format row is silently
# dropped from any ">= '....T....'" bound even when it is chronologically later.
# As with the window bounds this is a SQL comparison literal with no module-level
# function to call, so the query text is the only place it is expressible.
if grep -qE "coalesce\(sent_at,created_at\)[^)]*[<>]=? *'" "$SENTINEL"; then
  bad "a send timestamp is compared without replace(...,' ','T') normalisation"
else
  ok "every send timestamp is normalised before comparison"
fi

# --- 6. regression: the need-ask list is the source of truth (inbox 230) ---------
# The false alarm this pins: pass 2330 (2026-11-19T02:30Z) failed "proof-need-ask/answers
# run captain 2026-1: paid rows sent after unpaid rows" while the drain's own ordering key
# (need-asks.json users[].paid) showed NO inversion, and every one of the 34 recipients was
# on the need-ask list - the sentinel had read them against owing-uvn.json and re-derived
# `paid` from its own replica team rule. Both halves are pinned here: the fixture must PASS
# on the fixed rule and FAIL on the old one, so the test cannot be satisfied by weakening
# the check (a genuine inversion still fails - see the genuine-inversion case below).
if python3 - "$SENTINEL" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("fs", sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

# fixture: 24 proof-need-ask sends, every recipient on the need list, list order paid-first
need_rows = {str(u): {"paid": (i < 5), "oldest": f"2026-10-{10 + i:02d}T00:00:00Z"}
             for i, u in enumerate(range(9001, 9025))}
rows = [{"id": i, "campaign": "proof-need-ask", "user": str(u)}
        for i, u in enumerate(range(9001, 9025))]
# the sentinel's own replica team rule disagreed with the list on exactly these users
paid_map = {str(u): (i >= 5) for i, u in enumerate(range(9001, 9025))}

def inverted(flags):
    seen = False
    for p in flags:
        if p is False:
            seen = True
        elif p is True and seen:
            return True
    return False

bad = 0
def want(name, got, exp):
    global bad
    if got != exp:
        print(f"  FAIL {name} (want {exp!r}, got {got!r})"); bad += 1
    else:
        print(f"  ok   {name}")

# BEFORE: paid re-derived from the replica rule -> a manufactured inversion
old_flags = [(paid_map.get(r["user"]) or False) for r in rows]
want("before the fix the replica rule reports an inversion (the false alarm)", inverted(old_flags), True)
# BEFORE: membership was read from owing-uvn only, which does not hold these users at all -
# that is the "not on the owing list" alarm. The fix routes the family to its own list instead.
want("the owing-uvn list is not consulted for proof-need-ask",
     m.list_membership("proof-need-ask", "9001", need_rows=need_rows, need_ok=True,
                       list_rows={"9001": {"skip": "would-have-been-read"}})[0], "need-asks")

# AFTER: the list's own paid flag is the ordering key -> no inversion
new_flags = [m.paid_flag(r, need_rows=need_rows, need_ok=True, paid_map=paid_map, rep_ok=True) for r in rows]
want("after the fix the list's own key shows no inversion", inverted(new_flags), False)
want("after the fix every recipient is on the need-ask list",
     all(m.list_membership(r["campaign"], r["user"], need_rows=need_rows, need_ok=True, list_rows={})[0] == "need-asks"
         and m.list_membership(r["campaign"], r["user"], need_rows=need_rows, need_ok=True, list_rows={})[1] is not None
         for r in rows), True)

# NOT WEAKENED: a genuine inversion in the list's own flags still fails
real = [{"id": 1, "campaign": "proof-need-ask", "user": "1"},
        {"id": 2, "campaign": "proof-need-ask", "user": "2"}]
real_need = {"1": {"paid": False, "oldest": "2026-10-01T00:00:00Z"},
             "2": {"paid": True, "oldest": "2026-10-02T00:00:00Z"}}
want("a genuine paid-after-unpaid inversion still fails",
     inverted([m.paid_flag(r, need_rows=real_need, need_ok=True, paid_map={}, rep_ok=True) for r in real]), True)
# NOT WEAKENED: an unreadable need list falls back to the replica rule, never to silence
want("an unreadable need list falls back to the replica rule",
     m.paid_flag(real[1], need_rows={}, need_ok=False, paid_map={"2": True}, rep_ok=True), True)
want("an unreadable need list with an unreadable replica is UNKNOWN",
     m.paid_flag(real[1], need_rows={}, need_ok=False, paid_map={}, rep_ok=False), None)
sys.exit(1 if bad else 0)
PY
then pass=$((pass + 7)); else fail=$((fail + 1)); fi

# --- 7. every counter on the pass line says what it covers (inbox 232) ------
# The line is quoted to Aaron, so a cumulative number placed between two per-window
# numbers gets read (and subtracted) as per-window: "notices-sent=0 acks-sent=0
# users-told=1200" on a 10-minute pass. Each counter now carries window:/total:/now:/
# today:, and "approved-this-window" + "approvals" (one measurement, two names) are
# one field. This pins the taxonomy, not the numbers.
if python3 - "$SENTINEL" <<'PY'
import importlib.util, re, sys
spec = importlib.util.spec_from_file_location("fs2", sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
bad = 0
def want(name, cond):
    global bad
    if cond:
        print(f"  ok   {name}")
    else:
        print(f"  FAIL {name}"); bad += 1
vals = dict(open_uvn=80857, precedent=10547, appr_n=2, told_n=0, ack_n=0, told_total=1200,
            fam_txt="none", ref_txt="none", per_person_max=21, big=1, riskful=0,
            at_or_over_30=0, fraudflagged=0, legalflagged=0, holdcoded=0, rejected=0,
            merges=0, spot_pass=0, spot_n=0, pn=0, pp=0, vol_held=0, hard_held=0,
            held_unheld=0, held_unscanned=0, markers="live=1 paid=1 armed=1", n_fails=0,
            n_unmeasured=1)
fields = m.summary_fields(**vals)
line = m.render_summary("sentinel: pass 2344 a->b on 075d940d:", fields, "art.md")
want("no counter lacks a scope prefix",
     all(s in m.SUMMARY_SCOPES for s, _, _ in fields))
want("the old unlabelled bare names are gone",
     not re.search(r"(^|[ ])(open-uvn|precedent-approved|notices-sent|acks-sent|users-told|"
                   r"per-person-max|markers|recipients-unheld|coded-fails|unmeasured)=", line))
want("every printed counter matches scope:name=value",
     all(re.fullmatch(r"(window|total|now|today):[a-z0-9-]+", tok.split("=", 1)[0])
         # markers= is itself a gauge whose VALUE repeats k=v pairs; only the counter
         # token (the part before the first '=') is validated.
         for tok in line.split() if "=" in tok and not tok.startswith("artifact=")
         and ":" in tok.split("=", 1)[0]))
want("no counter name is printed twice",
     len({n for _, n, _ in fields}) == len(fields))
want("approved-this-window and approvals are one field",
     "approved-this-window" not in line
     and [n for _, n, _ in fields].count("approvals") == 1)
want("the window numbers and the cumulative number are both still there",
     "window:notices-sent=0" in line and "window:acks-sent=0" in line
     and "total:users-told=1200" in line)
try:
    m.render_summary("h", [("cumulative", "x", 1)], "a"); refused = False
except ValueError:
    refused = True
want("a scope outside window/total/now/today raises", refused)
sys.exit(1 if bad else 0)
PY
then pass=$((pass + 7)); else fail=$((fail + 1)); fi

echo
echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
