#!/usr/bin/env python3
"""READ-ONLY list builder (daily.sh, only with ASKS=1). Users on the day's ask list whose ask was SKIPPED (documents
on file, or the ask is not needed: approval path / already on the profile / documents in Intercom) and who were
never told anything get a status note instead: B0 "with our team for review", or Copy A when a document of theirs
awaits review. Captain 2026-10-26 16:05Z: "nothing sits silent".

A "nothing else is needed" note must never contradict an open ask, so a user is excluded when:
- the ledger already messaged them (verify_ledger._same_user: account email OR account id OR the decider's user);
- their uvn ask was REFUSED by the gate or REJECTED by Intercom (decide(): never delivered). uvn-status refusals are
  terminal and close the request rows, which looks exactly like "already handled"; on 2026-10-26 that misread sent B0
  to 37 users who still owed proof (firstmate 025/026). They owe the ask, not a status note;
- they are ask-only (fraud lens, Fable Ruling B) with no document: the ask is their status.
Writes list-B2.json (B0) and list-A3.json (Copy A), runner format, in $PWR_DIR; prints counts.
"""
from __future__ import annotations

import glob
import json
import os
import sqlite3
import sys
from collections import Counter
from datetime import datetime, timezone

HERE = os.path.dirname(os.path.abspath(__file__))
for p in ("/opt/hydra/scripts", os.path.dirname(HERE)):  # the deployed tree, then this repo's scripts/
    if p not in sys.path:
        sys.path.insert(0, p)

NEVER_DELIVERED = ("refused", "rejected")


def ever_messaged(db: sqlite3.Connection, email: str, uid: int) -> bool:
    from credit_review import verify_ledger
    cond, params = verify_ledger._same_user(db, email, str(uid))
    return db.execute(f"SELECT 1 FROM verify_messages m WHERE {cond} AND m.status IN ('sent','attempted') LIMIT 1",
                      params).fetchone() is not None


def ask_never_delivered(db: sqlite3.Connection, email: str, uid: int) -> bool:
    """True when a uvn-status ask to this user was refused by the gate or rejected by Intercom: the ask never
    reached them, so their closed rows do NOT mean the ask was handled."""
    from credit_review import verify_ledger
    cond, params = verify_ledger._same_user(db, email, str(uid))
    q = (f"SELECT 1 FROM verify_messages m WHERE {cond} AND m.campaign='uvn-status' "
         f"AND m.status IN ({','.join('?' * len(NEVER_DELIVERED))}) LIMIT 1")
    return db.execute(q, (*params, *NEVER_DELIVERED)).fetchone() is not None


def decide(*, messaged: bool, never_delivered: bool, ask_only: bool, documented: bool, pending_doc: bool) -> tuple[str, str]:
    """(list, reason): list is "B2" (B0), "A3" (Copy A) or "" (no note from this builder)."""
    if messaged:
        return "", "messaged before (ledger, _same_user)"
    if never_delivered:
        return "", "uvn ask refused/rejected, never delivered: owes the ask, not B0"
    if ask_only:
        if documented and pending_doc:
            return "A3", "ask-only with a pending document: Copy A (firstmate 006 #4)"
        if documented:
            return "B2", "ask-only, documented for other credits: B0 (firstmate 008b)"
        return "", "ask-only, no document: the ask is their status (Ruling B)"
    return "B2", "ask skipped: B0"


def main() -> int:
    from credit_review import uvn_status, verify_ledger, verify_notify
    D = os.environ["PWR_DIR"]
    paid = os.environ.get("SEGMENT", "paid") == "paid"
    seg = {r["user_id"]: r for r in json.load(open(f"{D}/segments.json"))}
    cls = {r["user_id"]: r["class"] for r in json.load(open(sorted(glob.glob(f"{D}/cls/dry-run-*.json"))[-1]))}
    db = sqlite3.connect(f"file:{verify_ledger.DEFAULT_PATH}?mode=ro", uri=True)
    db.row_factory = sqlite3.Row
    proof = verify_notify.load_proof_on_file(None)
    u_list = json.load(open(f"{D}/list-U.json"))["users"]
    acct = uvn_status.accounts_of([u["user_id"] for u in u_list])
    out: dict[str, list] = {"B2": [], "A3": []}
    why: Counter = Counter()
    for u in u_list:
        uid = u["user_id"]
        s = seg[uid]
        email = (acct.get(uid) or {}).get("email", "")
        if s["identity_hold"] or s["forbidden"]:
            why["email route"] += 1
            continue
        lst, reason = decide(messaged=ever_messaged(db, email, uid), never_delivered=ask_never_delivered(db, email, uid),
                             ask_only=bool(s["ask_only"]), documented=str(uid) in proof, pending_doc=cls.get(uid) == "A_DOC")
        why[reason] += 1
        if lst:
            out[lst].append({"user_id": uid, "paid": paid, "skip": None, "request_ids": u["request_ids"],
                             "class": "A_DOC" if lst == "A3" else "B_TEAM"})
    now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    for name, src in (("B2", "ask skipped -> B0 status (classifier rule)"),
                      ("A3", "ask-only with a pending document -> Copy A (firstmate 006 #4)")):
        json.dump({"generated_at": now, "source": "paid-status b0_gap: " + src, "campaign": name, "users": out[name]},
                  open(f"{D}/list-{name}.json", "w"), indent=1)
    print(json.dumps({"U_list": len(u_list), "B2_b0": len(out["B2"]), "A3_copyA": len(out["A3"]), "reasons": why}, indent=1))
    return 0


if __name__ == "__main__":
    sys.exit(main())
