#!/usr/bin/env python3
"""paid-wave-runner-p1: READ-ONLY. Build the paid never-contacted population (credit-trust-llm-t01's
G9 definition, same query as /root/ct-t01-spike/nc3.py) and apply the captain's FRAUD LENS before any
batch. Writes (in OUT dir, node-8 <PWR_DIR>):
  never.txt         every paid never-contacted user id (G9)
  clean.txt         never.txt minus fraud-held users  -> input for census classify.py
  fraud-held.json   [{user_id, reasons[]}]  (never messaged, never approved)
  lens-summary.json counts
Nothing is sent or written anywhere else.
"""
import csv, io, json, sqlite3, subprocess, sys
from collections import defaultdict
from pathlib import Path

if len(sys.argv) < 2:
    sys.exit("usage: fraud_lens.py <out-dir>")
OUT = Path(sys.argv[1])
TRINO = "/opt/hydra/scripts/trino-query.sh"
WATCHLIST = "/opt/hydra/policies/fraud-watchlist.json"

BRIEF_WATCH = {350590: "brief watchlist", 256637: "brief watchlist", 219737: "brief watchlist",
               305363: "brief watchlist", 184149: "brief watchlist"}
A1_PULL = [195823, 58586, 25291, 95146, 301754, 98515, 33718, 229176, 32731, 307585, 141609, 199411, 47513,
           162720, 128308]
A1_HOLD = [1387162, 75893, 299503, 335445, 1376456, 1393437, 216092, 100509]
S1_FRAUD = [1387162, 58586, 301754, 305363, 307585, 25291, 98515, 350590, 184149, 256637, 219737]
BANDC_E = [53136]          # band-c evidence: contradiction-dominant (17/25)
LINKED = [340552]          # band-c evidence: linked to 335445 (a1 HOLD) - same person/circle
VEL_ROWS = 300             # s1 level B' rows per profile per UTC day
VEL_BIG = 10               # s1 level C big-track (pop >= 70) rows per profile per UTC day
BIG_POP = 60
SINGLE_SIGNAL_CODES = ("review_big_track_without_trusted_credit", "review_big_track_weak_footprint")


def q(sql):
    p = subprocess.run([TRINO], input=sql, capture_output=True, text=True, timeout=1200)
    if p.returncode != 0:
        sys.exit(f"trino failed: {p.stderr[-400:]}")
    return [r for r in csv.reader(io.StringIO("\n".join(l for l in p.stdout.splitlines() if l.startswith('"'))))]


PAID = "(select distinct s.teamid from postgresql_core.public.subscriptions s where s.status in ('active','trialing'))"
rows = q(f"""
select cast(cr.userid as varchar),
       cast(max(case when coalesce(json_extract_scalar(cr.metadata,'$.proofRequest.noticeSentAt'),
                              json_extract_scalar(cr.metadata,'$.proofRequest.responseAt'),
                              json_extract_scalar(cr.metadata,'$.infoRequest.responseAt')) is not null then 1 else 0 end) as varchar),
       cast(count(*) as varchar)
from postgresql_core.public.credit_requests cr
where cr.deletedat is null and cr.status not in ('approved','rejected') and cr.workspaceid in {PAID}
group by 1""")
users = {int(r[0]): (r[1] == "1", int(r[2])) for r in rows if r[0].isdigit()}
db = sqlite3.connect("file:/var/lib/hydra/credit-review/ledger.sqlite3?mode=ro", uri=True)
sent = {int(a) for (a,) in db.execute("select account_id from verify_messages where status='sent' and created_at >= '2026-10-20'")
        if a and str(a).strip().isdigit()}
never = sorted(u for u, (asked, n) in users.items() if not asked and u not in sent)
import os as _os
if _os.environ.get("POP_FILE"):  # p2 free run: population = silent_count.py's list (any segment), lens unchanged
    never = sorted(int(x) for x in open(_os.environ["POP_FILE"]).read().split())
OUT.mkdir(parents=True, exist_ok=True)
(OUT / "never.txt").write_text("\n".join(map(str, never)) + "\n")

reasons = defaultdict(list)
wl = json.load(open(WATCHLIST))
wl_users, wl_profiles = {}, {}
for e in wl["entries"]:
    for u in e.get("user_ids") or []:
        wl_users[u] = f"policy watchlist {e['tier']}: {e['reason']}"
    for p in e.get("profile_ids") or []:
        wl_profiles[p.lower()] = f"policy watchlist {e['tier']} profile: {e['reason']}"
named = {}
for u in A1_PULL: named[u] = "a1 audit PULL account"
for u in A1_HOLD: named.setdefault(u, "a1 audit HOLD account")
for u in S1_FRAUD: named.setdefault(u, "s1 likely-fraud verdict")
for u in BANDC_E: named.setdefault(u, "band-C contradiction-dominant (17/25)")
for u in LINKED: named.setdefault(u, "linked to a1 HOLD 335445")
named.update({u: v for u, v in BRIEF_WATCH.items() if u not in named})
nset = set(never)
for u in nset:
    if u in BRIEF_WATCH: reasons[u].append("brief watchlist")
    if u in wl_users: reasons[u].append(wl_users[u])
    if u in named and named[u] != "brief watchlist": reasons[u].append(named[u])

# per-user features over the never-contacted set (chunks of 400)
ids = never
for i in range(0, len(ids), 400):
    chunk = ",".join(map(str, ids[i:i + 400]))
    # watchlisted profile on any open request
    for uid, pid in q(f"select distinct cast(userid as varchar), cast(profileid as varchar) from postgresql_core.public.credit_requests "
                      f"where deletedat is null and status not in ('approved','rejected') and userid in ({chunk})"):
        if pid and pid.lower() in wl_profiles:
            reasons[int(uid)].append(wl_profiles[pid.lower()])
    # velocity above band, 90 days, per profile per UTC day
    for uid, mx, mxbig in q(f"""
        select cast(userid as varchar), cast(max(n) as varchar), cast(max(nbig) as varchar) from (
          select userid, profileid, date(createdat at time zone 'UTC') d, count(*) n,
                 sum(case when spotifypopularity >= 70 then 1 else 0 end) nbig
          from postgresql_core.public.credit_requests
          where createdat > current_timestamp - interval '90' day and userid in ({chunk})
          group by 1, 2, 3) group by 1"""):
        mx, mxbig = int(mx or 0), int(mxbig or 0)
        if mx > VEL_ROWS:
            reasons[int(uid)].append(f"velocity above band: {mx} rows on one profile in one UTC day (> {VEL_ROWS}, s1 level B')")
        if mxbig > VEL_BIG:
            reasons[int(uid)].append(f"velocity above band: {mxbig} big-track (pop>=70) rows on one profile in one UTC day (> {VEL_BIG}, s1 level C)")
    # big-track claim on a single signal (open rows only)
    for uid, n in q(f"""
        select cast(userid as varchar), cast(count(*) as varchar) from postgresql_core.public.credit_requests
        where deletedat is null and status not in ('approved','rejected') and userid in ({chunk})
          and spotifypopularity >= {BIG_POP}
          and (json_array_contains(json_extract(verificationdata, '$.hold_reason_codes'), '{SINGLE_SIGNAL_CODES[0]}')
               or json_array_contains(json_extract(verificationdata, '$.hold_reason_codes'), '{SINGLE_SIGNAL_CODES[1]}')
               or json_extract_scalar(verificationdata, '$.shortcut_source') is not null)
        group by 1"""):
        reasons[int(uid)].append(f"big-track claim on a single signal: {n} open row(s) pop>={BIG_POP} with no trusted source "
                                 "(hold code big_track_without_trusted_credit/weak_footprint, or a lone shortcut)")

held = [{"user_id": u, "reasons": sorted(set(r))} for u, r in sorted(reasons.items()) if u in nset and r]
held_ids = {h["user_id"] for h in held}
clean = [u for u in never if u not in held_ids]
(OUT / "clean.txt").write_text("\n".join(map(str, clean)) + "\n")
(OUT / "fraud-held.json").write_text(json.dumps(held, indent=1))
cat = defaultdict(int)
for h in held:
    for r in h["reasons"]:
        cat[r.split(":")[0]] += 1
summ = {"paid_pending_users": len(users), "ledger_contacted": len(sent & set(users)),
        "paid_never_contacted": len(never), "fraud_held": len(held), "clean": len(clean), "held_by_reason": dict(cat)}
(OUT / "lens-summary.json").write_text(json.dumps(summ, indent=1))
print(json.dumps(summ, indent=1))
