#!/usr/bin/env python3
"""Read-only: what IS the newer intake that holds each paid user, and was it ever asked about.

Run on node-8:  python3 classify_held.py /root/h2-runs/sched/<tick>/need-asks-all.json

Reads the builder's list, proof.sqlite and doc-verify.sqlite (mode=ro) and the verify ledger (connect_ro). Writes
nothing. For every paid user the newer-intake rule holds on at least one need it takes the NEWEST intake that holds
one of their needs (never the held document itself, unless it also holds another need) and says which of these it is:

  askable_unasked        on this list with a sendable need, and none of its requests has a proof-need-ask row
  asked_in_window        on this list, and its requests were asked inside REASK_LOCK_DAYS
  asked_out_of_window    on this list, and its requests were asked longer ago than that
  same_file_resent       the same file (sha) as a listed document, sent again later
  unread                 doc-verify has no outcome row for it
  read:<outcome>/<need>  doc-verify read it and it is not on the list (not unverifiable, no sendable need, or its
                         request is no longer pending); <need> is the need that read recorded, '-' for none
"""
import json
import sqlite3
import sys
from collections import Counter
from datetime import datetime, timedelta, timezone

sys.path.insert(0, "/opt/hydra/scripts")
from credit_review import comm_state, verify_ledger  # noqa: E402

NEED_ORDER = ("counterparty_signed_or_registered", "readable_document", "distributor_dashboard_with_code")
PROOF = "/var/lib/hydra-credit-verify/proof.sqlite"
DV = "/var/lib/hydra-credit-verify/doc-verify.sqlite"


def ts(s):
    return datetime.strptime(s[:19], "%Y-%m-%dT%H:%M:%S")


def main():
    listed = json.load(open(sys.argv[1]))
    now = datetime.fromisoformat(listed["generated_at"]).astimezone(timezone.utc).replace(tzinfo=None)
    since = now - timedelta(days=verify_ledger.REASK_LOCK_DAYS)
    pdb = sqlite3.connect(f"file:{PROOF}?mode=ro", uri=True)
    ddb = sqlite3.connect(f"file:{DV}?mode=ro", uri=True)
    ldb = verify_ledger.connect_ro(verify_ledger.DEFAULT_PATH, must_exist=True)
    dv_cols = {r[1] for r in ddb.execute("PRAGMA table_info(dv_outcomes)")}
    paid = [u for u in listed["users"] if u.get("paid")]
    kinds, stuck_kinds, same_second = Counter(), Counter(), Counter()
    for u in paid:
        uid, arrivals = int(u["user_id"]), u.get("arrivals") or []
        needs, held_needs, zero = {a["need"] for a in u["asks"]} & set(NEED_ORDER), 0, False
        holders = set()
        for need in NEED_ORDER:
            cand = [a for a in u["asks"] if a["need"] == need]
            if not cand:
                continue
            newest = max(cand, key=lambda a: (a["doc_received_at"], a["doc_sha"]))
            docs = [a for a in cand if a["doc_received_at"][:10] == newest["doc_received_at"][:10]
                    and a["filing_conversation"] == newest["filing_conversation"]]
            named = {str(a.get("intake_id") or "") for a in docs if a.get("intake_id")}
            if comm_state.newer_intake(newest["doc_received_at"], arrivals, named):
                held_needs += 1
                t = ts(newest["doc_received_at"])
                holders |= {(a[0], str(a[1] or "")) for a in arrivals
                            if ts(a[0]) > t or (ts(a[0]) == t and a[1] and str(a[1]) not in named)}
                if not any(ts(a[0]) > ts(newest["doc_received_at"]) for a in arrivals):
                    zero = True                 # held only by an intake of the same second
        if not held_needs:
            continue
        last_at, last_id = max(holders)
        on_list = [a for a in u["asks"] if str(a.get("intake_id") or "") == last_id]
        row = pdb.execute("SELECT file_sha256 FROM proof_intake WHERE user_id=? AND intake_id=?", (uid, last_id)).fetchone()
        sha = row[0] if row else ""
        if on_list:
            rids = sorted({a["request_id"].lower() for a in on_list})
            marks = ",".join("?" * len(rids))
            sent = [r[0] for r in ldb.execute(
                f"SELECT updated_at FROM verify_requests WHERE campaign='proof-need-ask' AND lower(request_id) IN ({marks}) "
                "AND status IN ('attempted','sent')", rids)]
            if not sent:
                kind = "askable_unasked"
            else:
                kind = "asked_in_window" if ts(max(sent)) > since else "asked_out_of_window"
        elif sha and any(a["doc_sha"] == sha for a in u["asks"]):
            kind = "same_file_resent"
        else:
            where = "(intake_id=? OR proof_id=?)" if "intake_id" in dv_cols else "(proof_id=? OR proof_id=?)"
            r = ddb.execute(f"SELECT outcome, coalesce(need, '') FROM dv_outcomes WHERE user_id=? AND {where} "
                            "ORDER BY at DESC, id DESC LIMIT 1", (uid, last_id, sha)).fetchone()
            kind = f"read:{r[0]}/{r[1] or '-'}" if r else "unread"
        kinds[kind] += 1
        if held_needs == len(needs):
            stuck_kinds[kind] += 1
            same_second["stuck, held only by a same-second intake" if zero else "stuck, a later intake"] += 1
    print(f"list generated_at={listed['generated_at']} window={verify_ledger.REASK_LOCK_DAYS}d paid_users={len(paid)}")
    print(f"held on at least one need: {sum(kinds.values())}")
    for k, n in kinds.most_common():
        print(f"  {k}: {n}")
    print(f"held on every need: {sum(stuck_kinds.values())}")
    for k, n in stuck_kinds.most_common():
        print(f"  {k}: {n}")
    for k, n in same_second.most_common():
        print(f"  [{k}: {n}]")


if __name__ == "__main__":
    main()
