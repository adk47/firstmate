#!/usr/bin/env python3
"""intercom-backlog triage: READ-ONLY. Joins a census file (census.py) to the user's LIVE
state on the core replica (Trino) and the hydra verify ledger, and assigns every customer-last
conversation exactly one rule-based action. Writes nothing to Intercom or core.

Actions (first match wins; the order is the captain's routing rules):
  captain-legal      legal topic (C&D, attorney, lawsuit)        -> captain's list, no reply from us
  captain-billing    billing/refund/cancel/charge topic          -> captain's list, no reply from us
  no-identity        no Muso user resolves from the contact      -> per-category draft (Fable GO)
  ledger-today       the user already had a ledger note today    -> defer to tomorrow (1 msg/user/day)
  gate-doc-received  pending credit rows + a proof response      -> intercom-verify-request status-doc-received
  gate-uvn-status    pending rows incl. user_verification_needed -> uvn-status (approved ask copy)
  gate-team-review   pending credit rows, no proof response      -> status-team-review (no-ask / count)
  claim-pending      a pending profile claim                     -> claim-status copy (send-locked: Fable GO)
  draft-<topic>      nothing pending we can state from a rule    -> per-category draft (Fable GO)

Usage (node-8): python3 triage.py <census.jsonl>   -> <census>.triage.jsonl (0600) + summary
"""
import collections
import csv
import datetime as dt
import io
import json
import os
import sqlite3
import subprocess
import sys

LEDGER = "/var/lib/hydra/credit-review/ledger.sqlite3"
PENDING = ("unverified", "processing", "user_verification_needed")
PAID = ("(select distinct s.teamid from postgresql_core.public.subscriptions s "
        "where s.status in ('active','trialing'))")


def trino(sql, timeout=900):
    p = subprocess.run(["/opt/hydra/scripts/trino-query.sh"], input=sql, capture_output=True,
                       text=True, timeout=timeout)
    if p.returncode:
        raise RuntimeError(p.stderr.strip()[:300] + " ... " + p.stderr.strip()[-200:])
    return list(csv.reader(io.StringIO("\n".join(
        l for l in p.stdout.splitlines() if l.startswith('"')))))


def q(s):
    return "'" + str(s).replace("'", "''") + "'"


def chunks(xs, n=150):
    xs = list(xs)
    for i in range(0, len(xs), n):
        yield xs[i:i + n]


def main():
    src = sys.argv[1]
    rows = [json.loads(l) for l in open(src)]
    ext = {r["external_id"] for r in rows if r.get("external_id")}
    # external_id -> user id: professional id, Auth0 subject (with or without auth0|), or users.id
    uid_of = {}
    for ch in chunks(ext):
        vals = ",".join(q(e) for e in ch)
        subs = ",".join(q(e if e.startswith("auth0|") else "auth0|" + e) for e in ch)
        ids = ",".join(e for e in ch if e.isdigit()) or "-1"
        for uid, pro, sub in trino(
                "select cast(id as varchar), cast(neptuneprofessionalid as varchar), auth0userid "
                f"from postgresql_core.public.users where ("
                f"cast(neptuneprofessionalid as varchar) in ({vals}) or auth0userid in ({vals}) "
                f"or auth0userid in ({subs}) or id in ({ids}))"):
            for k in (pro, sub, (sub or "").replace("auth0|", ""), uid):
                if k in ext:
                    uid_of.setdefault(k, set()).add(uid)
    uids = {u for s in uid_of.values() for u in s}
    cred = collections.defaultdict(lambda: {"pending": 0, "uvn": 0, "proof": 0, "approved": 0,
                                            "rejected": 0})
    paid_users = set()
    claims = collections.defaultdict(lambda: collections.Counter())
    for ch in chunks(uids):
        ids = ",".join(ch)
        # Paid = member of a team with an active/trialing subscription (fraud_lens.PAID_TEAMS),
        # read from membership, NOT from credit rows: a subscriber with no credit request is paid.
        for (uid,) in trino(
                "select distinct cast(tu.userid as varchar) from postgresql_core.public.team_users tu "
                f"where tu.userid in ({ids}) and tu.teamid in {PAID}"):
            paid_users.add(uid)
        for uid, status, proof, n in trino(
                "select cast(cr.userid as varchar), cr.status, "
                "cast(sum(case when coalesce(json_extract_scalar(cr.metadata,'$.proofRequest.responseAt'),"
                "json_extract_scalar(cr.metadata,'$.infoRequest.responseAt')) is not null then 1 else 0 end) as varchar), "
                "cast(count(*) as varchar) from postgresql_core.public.credit_requests cr "
                f"where cr.deletedat is null and cr.userid in ({ids}) group by 1,2"):
            c = cred[uid]
            n = int(n)
            if status in PENDING:
                c["pending"] += n
                c["proof"] += int(proof)
                if status == "user_verification_needed":
                    c["uvn"] += n
            elif status in ("approved", "rejected"):
                c[status] += n
        for uid, status, n in trino(
                "select cast(userid as varchar), status, cast(count(*) as varchar) "
                f"from postgresql_core.public.claiming where deletedat is null and userid in ({ids}) group by 1,2"):
            claims[uid][status] += int(n)
    db = sqlite3.connect(f"file:{LEDGER}?mode=ro", uri=True)
    today = dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%d")
    led_today, led_any = set(), collections.Counter()
    for acct, day in db.execute("select account_id, day from verify_messages "
                                "where status in ('sent','attempted')"):
        if acct:
            led_any[str(acct)] += 1
            if day == today:
                led_today.add(str(acct))

    out_path = src.replace(".jsonl", ".triage.jsonl")
    fd = os.open(out_path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    summary = collections.Counter()
    with os.fdopen(fd, "w") as out:
        for r in rows:
            us = sorted(uid_of.get(r.get("external_id") or "", ()))
            uid = us[0] if len(us) == 1 else None
            c = cred.get(uid) if uid else None
            cl = claims.get(uid, {}) if uid else {}
            t = r["topic"]
            if t == "legal":
                act = "captain-legal"
            elif t == "billing":
                act = "captain-billing"
            elif not uid:
                act = "no-identity" if not us else "ambiguous-identity"
            elif uid in led_today:
                act = "ledger-today"
            elif c and c["pending"] and c["proof"]:
                act = "gate-doc-received"
            elif c and c["uvn"]:
                act = "gate-uvn-status"
            elif c and c["pending"]:
                act = "gate-team-review"
            elif cl.get("pending"):
                act = "claim-pending"
            else:
                act = "draft-" + t
            r.update({"user_id": uid, "paid": uid in paid_users, "credits": c,
                      "claims": dict(cl), "ledger_msgs": led_any.get(uid or "", 0), "action": act})
            out.write(json.dumps(r) + "\n")
            summary[(r["band"], act)] += 1
    res = collections.defaultdict(dict)
    for (b, a), n in sorted(summary.items()):
        res[b][a] = n
    print(json.dumps({"file": out_path, "by_band_action": res}, indent=1, sort_keys=True))


if __name__ == "__main__":
    main()
