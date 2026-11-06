#!/usr/bin/env python3
"""credit-stale-velocity-revalidate: re-evaluate the stale-velocity class under the CURRENT rules, no-notify
(Fable [key=held-velocity-revalidate]). See scripts/credit_review/stale_velocity.py for the outcomes.

  credit-stale-velocity-revalidate.py --scope stale-velocity-1030.json --preview      print counts, write nothing
  credit-stale-velocity-revalidate.py --scope ... --shadow                            + append shadow decider rows
  credit-stale-velocity-revalidate.py --scope ... --apply --approval-ref <ref>        + append apply decider rows

Read-only to core (Trino replica), the V9 store, the account gate and the fraud-lens hold set. Writes no credit status
and sends nothing: an apply release row feeds the anchor upload + the executor's approve tray, and an ask row feeds the
standard comm_state ask on the outbound timer. Kill file /etc/hydra/fable-trays.disabled (or the legacy fable-decider.disabled) stops apply, not shadow.
"""
from __future__ import annotations

import argparse
import json
import os
import sqlite3
import sys
import uuid
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from credit_review import stale_velocity as sv  # noqa: E402

LEDGER = os.environ.get("CREDIT_REVIEW_LEDGER", "/var/lib/hydra/credit-review/ledger.sqlite3")
DSP_STORE = os.environ.get("CREDIT_DSP_VERIFY_STORE", "/var/lib/hydra-credit-verify/dsp-verify.sqlite")
# [key=fable-trays] (Fable switch-on-plan row 4, firstmate 751): renamed; the old path is still honoured so a rename that
# has not reached node-8 yet can never open this gate silently.
KILLS = ("/etc/hydra/fable-trays.disabled", "/etc/hydra/fable-decider.disabled")


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--scope", required=True, help="JSON {rows:[{request_id, user_id}]}")
    m = ap.add_mutually_exclusive_group(required=True)
    m.add_argument("--preview", action="store_true")
    m.add_argument("--shadow", action="store_true")
    m.add_argument("--apply", action="store_true")
    ap.add_argument("--approval-ref")
    ap.add_argument("--ledger", default=LEDGER)
    ap.add_argument("--sample", type=int, default=0)
    a = ap.parse_args(argv)
    kill = next((k for k in KILLS if os.path.exists(k)), "")
    if a.apply and (not a.approval_ref or kill):
        print(json.dumps({"refused": "apply needs --approval-ref (Fable's GO on the shadow) and no kill file "
                                     + (kill or " / ".join(KILLS))}))
        return 2

    from credit_review import account_gate, comm_state, decide
    from credit_review import fable_executor as fx
    scope = [(str(r["request_id"]).lower(), int(r["user_id"]))
             for r in json.loads(Path(a.scope).read_text(encoding="utf-8"))["rows"]]
    ids = [rid for rid, _ in scope]
    facts: dict = {}
    for i in range(0, len(ids), 400):
        facts.update(fx.fetch_facts(ids[i:i + 400]))
    v9_full = sv.v9_read(ids, DSP_STORE)
    v9 = {rid: v for rid, (v, _c) in v9_full.items()}
    v9_class = {rid: c for rid, (_v, c) in v9_full.items()}
    paid, _ = decide.paying_users()
    rows, skipped = sv.evaluate(scope, facts, v9, account_gate.check, comm_state.account_hold_facts, paid, v9_class)
    for o in rows[:max(a.sample, 0)]:
        print(json.dumps(o.__dict__, default=str))
    out = {"scope": len(scope), "evaluated": len(rows), "skipped": skipped, **sv.summary(rows),
           "rule_version": sv.rule_version()}
    if a.preview:
        out["mode"] = "preview (nothing written)"
    else:
        mode = "apply" if a.apply else "shadow"
        # f1 contract: the account gate per user again immediately before the write
        out["not_green_before_write"] = {str(k): v for k, v in
                                         sv.recheck_before_write(rows, account_gate.check,
                                                                 comm_state.account_hold_facts).items()}
        if out["not_green_before_write"]:
            out.update(sv.summary(rows))
        db = sqlite3.connect(a.ledger, timeout=30)
        run_id = f"stale-velocity-{mode}-" + uuid.uuid4().hex[:10]
        out.update(mode=mode, run_id=run_id, written=sv.record(db, run_id, mode, rows, datetime.now(timezone.utc)),
                   approval_ref=a.approval_ref)
    print(json.dumps(out))
    return 0


if __name__ == "__main__":
    sys.exit(main())
