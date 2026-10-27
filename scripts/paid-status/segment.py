#!/usr/bin/env python3
"""paid-wave-runner-p2: READ-ONLY segmentation of the live G9 paid never-contacted population.
Input: <PWR_DIR>/never.txt + fraud-held.json (from p1's fraud_lens.py, run unchanged).
Output: <PWR_DIR>/segments.json (ids only) and a counts summary on stdout. Sends nothing, writes nothing
outside <PWR_DIR>. Emails are read only to key the ledger (user_key) and never written out.

Rules applied (sources in the p2 report):
  MSG_HOLD   Fable ruling-watchlist-consistency-1026 sec.4 messaging holds: 3 banned + captain's 5 + 53136.
  LENS_HELD  Fable ruling-intercom-external-id-1026 Ruling B: velocity above band, or >= 10 open
             big-track single-signal rows -> held.  1..9 such rows -> ASK_ONLY (uvn-status ask only).
             Watchlist / a1 / s1 membership alone is NOT a hold (ruling-watchlist-consistency sec.2).
  SUPPORT    emailed support@ in the last 90 days (proof-on-file gmail_contacts_90d).
  IDENTITY   live refusal hold in verify_refusal_holds whose reason is an Intercom identity reason.
  FORBIDDEN  verify_messages rejected with action_forbidden.
"""
import csv, io, json, re, sqlite3, subprocess, sys
from collections import Counter
from datetime import datetime, timezone

D = __import__("os").environ["PWR_DIR"]  # the run dir (daily.sh sets it)
TRINO = "/opt/hydra/scripts/trino-query.sh"
MSG_HOLD = {58586: "banned", 162720: "banned", 301754: "banned",
            350590: "captain's 5", 256637: "captain's 5", 219737: "captain's 5", 305363: "captain's 5",
            184149: "captain's 5", 53136: "band-C contradiction-dominant (review 2026-11-02)"}


def q(sql):
    p = subprocess.run([TRINO], input=sql, capture_output=True, text=True, timeout=900)
    if p.returncode != 0:
        sys.exit("trino failed: " + p.stderr[-400:])
    return list(csv.reader(io.StringIO("\n".join(l for l in p.stdout.splitlines() if l.startswith('"')))))


never = [int(x) for x in open(f"{D}/never.txt").read().split()]
lens = {h["user_id"]: h["reasons"] for h in json.load(open(f"{D}/fraud-held.json"))}
proof = json.load(open("/var/lib/credit-trust/proof-on-file.json"))
support = set(proof.get("gmail_contacts_90d", {}).get("user_ids") or [])
excl = {int(x) for x in open(f"{D}/exclude-cs.txt").read().split() if x.strip().isdigit()}

acct = {}
for i in range(0, len(never), 400):
    ids = ",".join(map(str, never[i:i + 400]))
    for uid, email, conf, pro in q(f"select cast(id as varchar), lower(trim(email)), cast(emailconfirmed as varchar), "
                                   f"coalesce(neptuneprofessionalid,'') from postgresql_core.public.users where id in ({ids})"):
        acct[int(uid)] = {"email": email, "confirmed": conf == "true", "pro": bool(pro)}
# another account holding the same address (case-insensitive)?
emails = sorted({a["email"] for a in acct.values() if a["email"]})
dup = Counter()
for i in range(0, len(emails), 300):
    lit = ",".join("'" + e.replace("'", "''") + "'" for e in emails[i:i + 300])
    for e, n in q(f"select lower(trim(email)), cast(count(*) as varchar) from postgresql_core.public.users "
                  f"where lower(trim(email)) in ({lit}) group by 1"):
        dup[e] = int(n)

now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S")
db = sqlite3.connect("file:/var/lib/hydra/credit-review/ledger.sqlite3?mode=ro", uri=True)
holds = {}
for camp, key, uid, n, reason, nxt, flagged in db.execute(
        "select campaign, user_key, user_id, refusals, reason, next_recheck_at, flagged_at from verify_refusal_holds"):
    holds.setdefault(key, []).append({"campaign": camp, "user_id": uid, "n": n, "reason": reason or "",
                                      "until": nxt, "flagged": bool(flagged)})
forbidden = {k for (k,) in db.execute("select distinct user_key from verify_messages where status='rejected' "
                                      "and reason like '%action_forbidden%'")}
last_any = dict(db.execute("select user_key, max(coalesce(sent_at, created_at)) from verify_messages "
                           "where status='sent' group by user_key"))

IDENT = re.compile(r"external_id|Intercom users|not linked|Intercom user", re.I)


def single_signal_rows(rs):
    m = [int(x) for r in rs for x in re.findall(r"single signal: (\d+) open", r)]
    return max(m) if m else 0


seg, out = Counter(), []
for u in never:
    a = acct.get(u, {})
    key = a.get("email", "")
    rs = lens.get(u, [])
    ss = single_signal_rows(rs)
    vel = any(r.startswith("velocity above band") for r in rs)
    hs = [h for h in holds.get(key, []) if h["until"] > now or h["flagged"]]
    ident = [h for h in hs if IDENT.search(h["reason"])]
    row = {"user_id": u, "confirmed": a.get("confirmed", False), "email_shared": dup.get(key, 0) > 1,
           "support90": u in support, "cs_excluded": u in excl, "msg_hold": MSG_HOLD.get(u, ""),
           "lens_held": (vel or ss >= 10) and __import__("os").environ.get("LENS_ASK") != "1",
           "ask_only": ((not vel) and 1 <= ss < 10) or ((vel or ss >= 10) and __import__("os").environ.get("LENS_ASK") == "1"), "single_signal_rows": ss,
           "velocity": vel, "watchlist_only": bool(rs) and not vel and ss == 0,
           "identity_hold": bool(ident), "identity_flagged": any(h["flagged"] for h in ident),
           "identity_until": min((h["until"] for h in ident), default=""),
           "other_refusal": [h["reason"][:80] for h in hs if not IDENT.search(h["reason"])],
           "forbidden": key in forbidden, "last_ledger_send": last_any.get(key, "")}
    # primary bucket, most protective first
    if row["msg_hold"]:
        b = "1 messaging hold (Fable 9)"
    elif row["lens_held"]:
        b = "2 lens held (velocity or >=10 single-signal)"
    elif not row["confirmed"] or row["email_shared"]:
        b = "3 email not confirmed or shared"
    elif row["identity_hold"]:
        b = "4 Intercom identity refusal hold"
    elif row["forbidden"]:
        b = "5 Intercom action_forbidden"
    elif row["support90"]:
        b = "6 support@ 90-day"
    elif row["cs_excluded"]:
        b = "7 cs Copy-A / withdrawal (already messaged by cs)"
    elif row["other_refusal"]:
        b = "8 other refusal hold"
    else:
        b = "9 open (Intercom route, existing gate)"
    row["bucket"] = b
    seg[b] += 1
    out.append(row)
json.dump(out, open(f"{D}/segments.json", "w"), indent=1)
print(json.dumps({"population": len(never), "buckets": dict(sorted(seg.items())),
                  "ask_only_total": sum(r["ask_only"] for r in out),
                  "watchlist_only_now_messageable": [r["user_id"] for r in out if r["watchlist_only"] and not r["msg_hold"]],
                  "identity_hold_total": sum(r["identity_hold"] for r in out),
                  "identity_flagged": sum(r["identity_flagged"] for r in out),
                  "support90_total": sum(r["support90"] for r in out),
                  "unconfirmed": sum(not r["confirmed"] for r in out),
                  "email_shared": sum(r["email_shared"] for r in out)}, indent=1))
