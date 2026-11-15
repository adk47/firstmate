#!/usr/bin/env python3
"""intercom-backlog triage: READ-ONLY. Joins a census file (census.py) to the user's LIVE
state on the core replica (Trino) and the hydra verify ledger, and assigns every customer-last
conversation exactly one rule-based action. Writes nothing to Intercom or core.

Actions (first match wins; the order is the captain's routing rules):
  captain-legal      legal topic (C&D, attorney, lawsuit)        -> captain's list, no reply from us
  captain-billing    billing/refund/cancel/charge topic          -> captain's list, no reply from us
  no-identity        no Muso account owns the contact's id       -> per-category draft (Fable GO)
  ambiguous-identity the id is owned by 2+ accounts, or another account had a reverted claim on it
  ledger-today       the user already had a ledger note today    -> defer to tomorrow (1 msg/user/day)
  gate-doc-received  pending credit rows + a proof response      -> intercom-verify-request status-doc-received
  gate-uvn-status    pending rows incl. user_verification_needed -> uvn-status (approved ask copy)
  gate-team-review   pending credit rows, no proof response      -> status-team-review (no-ask / count)
  claim-pending      a pending profile claim                     -> claim-status copy (send-locked: Fable GO)
  draft-<topic>      nothing pending we can state from a rule    -> per-category draft (Fable GO)

WHO THE CONTACT IS comes from ONE place, credit_review/identity_resolver.py (r5): the contact's Intercom
external_id is the account's professional id, its Auth0 subject, or its PRESENTED profile (a processed
claim, or the profile it represents), for exactly one account. The mobile app logs into Intercom with the
presented profile, so a matcher that reads users only calls every mobile claimant "no account": on
2026-11-14 that told 20 customers we could not match them to an account they were signed in to. The
resolver is the rule. ONE recorded fallback follows it: a contact whose Intercom id is a bare account
number (`users.id`) is that account, so no contact that matched before reads as no account (firstmate
2026-11-14 21:42Z). The fallback is read only for an id the resolver leaves with no owner at all; it
never overrides a refusal, so an id two accounts own, or one another account's claim was reverted on,
stays `ambiguous-identity`. `matched_by` is `users_id` when the fallback answered. The owner doc for this
rule and the lines it picks is docs/support/backlog-drain.md.

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

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
from credit_review import identity_resolver  # noqa: E402  the ONE external_id -> account rule

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


def chunks(xs, n=150):
    xs = list(xs)
    for i in range(0, len(xs), n):
        yield xs[i:i + n]


def users_id_accounts(exts, query):
    """The bare account numbers among `exts` that name a `users` row: {external_id}. Digits only, so
    nothing but integers is ever interpolated. Read ONLY for ids the house resolver leaves unowned."""
    found = set()
    ids = sorted({x for x in exts if str(x).isdigit()})
    asked = set(ids)
    for ch in chunks(ids):
        for (uid,) in query("SELECT CAST(id AS varchar) FROM postgresql_core.public.users "
                            f"WHERE id IN ({','.join(ch)})"):
            uid = str(uid).strip()
            if uid in asked:
                found.add(uid)
    return found


def identity_of(resolution, bare_account=""):
    """(account id or '', how it matched, why it did not, action for an unresolved contact). Pure.

    `resolution` is the house resolver's answer for the contact's external_id, or None when the contact
    has no external_id; `bare_account` is the users.id fallback's answer, passed only where the resolver
    found no owner. An id nobody owns is `no-identity`; an id the resolver refuses although an account
    does own it (two accounts, or another account's reverted claim) is `ambiguous-identity`."""
    if resolution is None:
        return "", "", "no external_id on the contact", "no-identity"
    if resolution.account_id is not None:
        return str(resolution.account_id), resolution.matched_by, "", ""
    if bare_account:
        return str(bare_account), "users_id", "", ""
    return "", "", resolution.why, "ambiguous-identity" if resolution.owners else "no-identity"


def main():
    src = sys.argv[1]
    with open(src) as f:
        rows = [json.loads(l) for l in f]
    ext = {str(r["external_id"]).strip() for r in rows if r.get("external_id")}
    # external_id -> account: the house resolver is the rule; the bare account number is the one
    # recorded fallback, read only for an id the resolver leaves with no owner (see the docstring)
    resolved = identity_resolver.resolve(ext, trino)
    bare = users_id_accounts({x for x, r in resolved.items() if not r.owners}, trino)
    uids = {str(r.account_id) for r in resolved.values() if r.account_id is not None} | bare
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
            e = str(r.get("external_id") or "").strip()
            uid, matched_by, why, unresolved = identity_of(resolved.get(e), e if e in bare else "")
            uid = uid or None
            c = cred.get(uid) if uid else None
            cl = claims.get(uid, {}) if uid else {}
            t = r["topic"]
            if t == "legal":
                act = "captain-legal"
            elif t == "billing":
                act = "captain-billing"
            elif not uid:
                act = unresolved
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
            r.update({"user_id": uid, "matched_by": matched_by, "identity_why": why,
                      "paid": uid in paid_users, "credits": c,
                      "claims": dict(cl), "ledger_msgs": led_any.get(uid or "", 0), "action": act})
            out.write(json.dumps(r) + "\n")
            summary[(r["band"], act)] += 1
    res = collections.defaultdict(dict)
    for (b, a), n in sorted(summary.items()):
        res[b][a] = n
    print(json.dumps({"file": out_path, "by_band_action": res}, indent=1, sort_keys=True))


if __name__ == "__main__":
    main()
