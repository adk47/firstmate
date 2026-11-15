#!/usr/bin/env python3
"""credit-validator-reject-close: the coded C5 rule `validator_reject` (conversion item 2; firstmate 174).

  credit-validator-reject-close.py --scope FILE --preview            decide, print, write nothing
  credit-validator-reject-close.py --scope FILE --shadow             + append shadow rows to the decider ledger
  credit-validator-reject-close.py --scope FILE --apply --tray-dir D apply rows + executor reject trays (refused
                                                                      until policies/credit-validator-reject-close.json
                                                                      enables apply with its recorded approved_by /
                                                                      approval_ref: its own policy switch, currently
                                                                      off; the r5 go-ahead is retired)

FILE: any JSON with rows[].request_id (e.g. an old hand tray used ONLY as the scope list - every row is re-decided
by this rule from fresh facts; nothing in the file decides anything). Read-only to core (Trino replica), the V9
store, the account gate and the R8 hold set. Writes no credit status. Summary JSON on stdout (per-user split).
"""
from __future__ import annotations

import argparse
import json
import sqlite3
import sys
import uuid
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from credit_review import validator_reject_close as vr  # noqa: E402

LEDGER = "/var/lib/hydra/credit-review/ledger.sqlite3"


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--scope", required=True)
    m = ap.add_mutually_exclusive_group(required=True)
    m.add_argument("--preview", action="store_true")
    m.add_argument("--shadow", action="store_true")
    m.add_argument("--apply", action="store_true")
    ap.add_argument("--tray-dir")
    ap.add_argument("--ledger", default=LEDGER)
    ap.add_argument("--sample", type=int, default=0)
    a = ap.parse_args(argv)
    if a.apply:
        why = vr.apply_refusal(vr.policy())
        if why or not a.tray_dir:
            print(json.dumps({"refused": why or "--apply needs --tray-dir"}))
            return 2
    from credit_review import account_gate, comm_state, decide
    from credit_review import fable_executor as fx
    scope = sorted({str(r["request_id"]).lower() for r in json.loads(Path(a.scope).read_text())["rows"]
                    if isinstance(r, dict) and r.get("request_id")})
    facts: dict = {}
    for i in range(0, len(scope), 400):
        facts.update(fx.fetch_facts(scope[i:i + 400]))
    anchors = fx.dsp_anchors(scope)
    paid, paid_why = decide.paying_users()
    if a.apply and vr.paid_refusal(paid, paid_why):
        print(json.dumps({"refused": vr.paid_refusal(paid, paid_why)}))
        return 2
    rows, skipped = vr.evaluate(scope, facts, anchors, account_gate.check, comm_state.account_hold_facts, paid)
    for r in rows[:max(a.sample, 0)]:
        print(json.dumps(r.__dict__, default=str))
    by_user: dict[str, dict[str, int]] = {}
    holds: dict[str, int] = {}
    for r in rows:
        u = by_user.setdefault(str(r.user_id), {})
        u[r.decision] = u.get(r.decision, 0) + 1
        if r.decision == "hold":
            holds[r.reason_code] = holds.get(r.reason_code, 0) + 1
    out = {"scope": len(scope), "evaluated": len(rows), "skipped": skipped,
           "close": sum(r.decision == "close" for r in rows), "close_users": len({r.user_id for r in rows
                                                                                  if r.decision == "close"}),
           "hold": holds, "by_user": by_user, "rule_version": vr.rule_version()}
    if a.preview:
        out["mode"] = "preview (nothing written)"
    else:
        mode = "apply" if a.apply else "shadow"
        db = sqlite3.connect(a.ledger, timeout=30)
        run_id = f"validator-reject-{mode}-" + uuid.uuid4().hex[:10]
        rec = vr.record(db, run_id, mode, rows, datetime.now(timezone.utc))
        out.update(mode=mode, run_id=run_id, written_close=rec["close"], written_hold=rec["hold"],
                   duplicate=rec["duplicate"])
        if a.apply:
            # every committed-but-unpublished apply row, this run's and any interrupted run's (QA #1559)
            out["trays"] = vr.publish(db, run_id, a.tray_dir, datetime.now(timezone.utc))
    print(json.dumps(out))
    return 0


if __name__ == "__main__":
    sys.exit(main())
