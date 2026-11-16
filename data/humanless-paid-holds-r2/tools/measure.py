#!/usr/bin/env python3
"""Read-only census of the paid holds that end at a person (humanless-paid-holds-r2).

Run on node-8 without leaving a file there:
    ssh root@node-8 'nice -n 10 python3 -' < data/humanless-paid-holds-r2/tools/measure.py

Reads the credit-review ledger with mode=ro and writes nothing. A row is in the population when it is
the LATEST `decisions` row of its request (highest id, any mode), the row is paid (`paid_priority = 1`)
and its reason falls in one of the three groups below. Group precedence is the order of GROUPS, so a
row is counted once.
"""
import collections
import json
import sqlite3
import sys

LEDGER = sys.argv[1] if len(sys.argv) > 1 else "/var/lib/hydra/credit-review/ledger.sqlite3"


def group(reason: str) -> str | None:
    if reason.startswith("score approval not now"):
        return "score_not_now"
    if reason.startswith("proof on file: stage 2 judged"):
        return "stage2_judged"
    if "human review" in reason:
        return "human_review"
    return None


def site(g: str, reason: str) -> str:
    """The code site that wrote the row, read off the reason's fixed prefix."""
    if g == "human_review":
        for prefix in ("proof on file: human review", "validator reject rule fired", "emailed support@",
                       "support already requested", "server approval guard would refuse",
                       "doc approval refused", "documentation required"):
            if reason.startswith(prefix):
                return prefix
        return "other"
    if g == "score_not_now":
        rest = reason[len("score approval not now: "):]
        for prefix in ("proof path: engaged user", "stored popularity", "organization / label",
                       "no independent anchor", "same_anchor_requests", "big track", "user on the decider",
                       "user reached"):
            if rest.startswith(prefix):
                return prefix
        return "other: " + rest[:50]
    return reason.split("(", 1)[1].split(")", 1)[0] if "(" in reason else "other"


def main() -> None:
    db = sqlite3.connect(f"file:{LEDGER}?mode=ro", uri=True, timeout=30)
    total, lo, hi = db.execute("SELECT count(*), min(decided_at), max(decided_at) FROM decisions").fetchone()
    rows = db.execute(
        "SELECT d.user_id, d.decision, d.reason, d.mode FROM decisions d"
        " JOIN (SELECT request_id, max(id) mid FROM decisions GROUP BY request_id) m ON m.mid = d.id"
        " WHERE d.paid_priority = 1").fetchall()
    out: dict = {"ledger_rows": total, "first": lo, "last": hi, "paid_latest_requests": len(rows), "groups": {}}
    union: set = set()
    for g in ("human_review", "score_not_now", "stage2_judged"):
        users: set = set()
        n = 0
        by_mode: dict = collections.defaultdict(lambda: [0, set()])
        by_decision: dict = collections.Counter()
        by_site: dict = collections.defaultdict(lambda: [0, set()])
        for user_id, decision, reason, mode in rows:
            if group(reason) != g:
                continue
            n += 1
            users.add(user_id)
            by_mode[mode][0] += 1
            by_mode[mode][1].add(user_id)
            by_decision[decision] += 1
            s = site(g, reason)
            by_site[s][0] += 1
            by_site[s][1].add(user_id)
        union |= users
        out["groups"][g] = {
            "rows": n, "users": len(users),
            "by_mode": {k: {"rows": v[0], "users": len(v[1])} for k, v in sorted(by_mode.items())},
            "by_decision": dict(by_decision),
            "by_site": {k: {"rows": v[0], "users": len(v[1])}
                        for k, v in sorted(by_site.items(), key=lambda kv: -kv[1][0])},
        }
    out["users_in_any_group"] = len(union)
    json.dump(out, sys.stdout, indent=1, sort_keys=False)
    print()


if __name__ == "__main__":
    main()
