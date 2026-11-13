#!/usr/bin/env python3
"""tick_census: what each outbound tick's uvn-status check did with the users it reached. READ-ONLY.

Reads only the tick's own artefacts (<sched-root>/<stamp>/uvn-status-<segment>-check.json and tick.log); no ledger,
no replica, no Intercom. Per tick and segment: users reached, accepted, and the gate's answer by reason code.
Written for data/rapid-verif-final-h3/report.md (what class C costs a tick, and the pass rate of everyone else).

    python3 tick_census.py --sched-root /root/h2-runs/sched --days 20261112,20261113
"""
import argparse
import glob
import json
import os
import re
import sys
from collections import Counter

CODES = ("c2_signed_only", "messaged_7d", "core_notice_within_7d", "no_channel", "comm_state", "run_size",
         "daily_cap", "g1_contact_fresh", "gate_timeout", "read_failed", "inapp_not_armed", "apply_budget")


def code(reason: str) -> str:
    for c in CODES:
        if c in reason:
            return c
    m = re.match(r"\s*(?:DEFERRED|HELD|REFUSED)?\s*([A-Za-z0-9_=]+)", reason or "")
    return m.group(1) if m and m.group(1) else "other"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--sched-root", default="/root/h2-runs/sched")
    ap.add_argument("--days", required=True, help="comma-separated YYYYMMDD")
    a = ap.parse_args()
    total: Counter = Counter()
    rows = []
    for day in a.days.split(","):
        for d in sorted(glob.glob(os.path.join(a.sched_root, f"{day}T*"))):
            for seg in ("paid", "free"):
                p = os.path.join(d, f"uvn-status-{seg}-check.json")
                if not os.path.isfile(p):
                    continue
                try:
                    doc = json.load(open(p, encoding="utf-8"))
                except (OSError, ValueError):
                    rows.append({"tick": os.path.basename(d), "segment": seg, "unreadable": True})
                    continue
                by = Counter(code(str(o.get("reason") or "")) if o.get("result") not in ("accepted", "sent")
                             else "ACCEPTED" for o in doc.get("outcomes") or [])
                acc = len(doc.get("accepted") or [])
                gate = sum(n for c, n in by.items() if c not in ("run_size", "daily_cap", "ACCEPTED"))
                rows.append({"tick": os.path.basename(d), "segment": seg, "listed": (doc.get("page") or {}).get("listed"),
                             "accepted": acc, "gate_answers": gate, "c2_signed_only": by.get("c2_signed_only", 0),
                             "stopped_on_unmeasured": bool(doc.get("stopped_on_unmeasured")),
                             "unmeasured": len(doc.get("unmeasured_users") or []) if isinstance(
                                 doc.get("unmeasured_users"), list) else doc.get("unmeasured_users"),
                             "by": dict(sorted(by.items()))})
                total.update(by)
                total["__accepted__"] += acc
                total["__gate_answers__"] += gate
                total["__checks__"] += 1
    print(json.dumps({"ticks": rows, "total": dict(sorted(total.items()))}, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
