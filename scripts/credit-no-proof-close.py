#!/usr/bin/env python3
"""credit-no-proof-close: the coded C5 rule `no_proof_after_ask` (Fable [key=paid-to-zero]).

  credit-no-proof-close.py [--shadow]                 decide every request past its ask + 14 d deadline; append
                                                      shadow rows to the decider ledger (default; no core write)
  credit-no-proof-close.py --preview-as-of 2026-11-06 the same decision as of a future date, printed only (writes
                                                      nothing): what the first deadlines will close
  credit-no-proof-close.py --apply --tray-dir DIR     apply rows (<= 100 closes/day) + one executor reject tray per
                                                      status in DIR; refused unless policies/credit-no-proof-close.json
                                                      enables apply with an approved closing line

Never writes a credit status itself: the L12 executor does, from the apply rows (coded_outcome decisions:<id>),
re-checking every rail at write time. Read-only to core (Trino replica) and Intercom (GET/search only).
Output: one JSON summary on stdout; --sample N prints N decided rows as JSONL first.
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

from credit_review import no_proof_close as npc  # noqa: E402


def real_inputs(rids: list[str], use_intercom: bool):
    from credit_review import account_gate, comm_state, decide
    from credit_review import fable_executor as fx
    facts: dict = {}
    for i in range(0, len(rids), 400):
        facts.update(fx.fetch_facts(rids[i:i + 400]))
    anchors = fx.dsp_anchors(rids)
    paid, _why = decide.paying_users()

    def docs(uid, keys, since):
        return comm_state.store_facts(uid, keys, since=since)["docs"]

    def intercom(contact, since):
        if not use_intercom:
            raise RuntimeError("Intercom not read (--no-intercom)")
        return npc.intercom_read(contact, since, comm_state.intercom)

    return facts, docs, intercom, anchors, account_gate.check, paid


def real_recheck(use_intercom: bool):
    """Proof AND reply re-read right before a tray is published (QA #1536): '' = the close still stands."""
    if use_intercom:
        return npc.live_recheck
    return lambda uid, rids, since, contact: "unknown:intercom not read (--no-intercom)"


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    mode = ap.add_mutually_exclusive_group()
    mode.add_argument("--shadow", action="store_true")
    mode.add_argument("--apply", action="store_true")
    mode.add_argument("--preview-as-of", metavar="YYYY-MM-DD")
    ap.add_argument("--ledger", default=npc.LEDGER)
    ap.add_argument("--tray-dir", help="apply: where the executor trays are written")
    ap.add_argument("--no-intercom", action="store_true", help="do not read Intercom (every due row then HOLDS)")
    ap.add_argument("--sample", type=int, default=0)
    a = ap.parse_args(argv)

    now = datetime.now(timezone.utc)
    if a.preview_as_of:
        now = datetime.fromisoformat(a.preview_as_of).replace(tzinfo=timezone.utc)
    if a.apply:
        why = npc.apply_refusal(npc.policy())
        if why:
            print(json.dumps({"refused": why}))
            return 2
        if not a.tray_dir:
            print(json.dumps({"refused": "--apply needs --tray-dir"}))
            return 2
    ro = sqlite3.connect(f"file:{a.ledger}?mode=ro", uri=True, timeout=30)
    asks = npc.latest_asks(ro)
    reminded = npc.reminders(ro)
    ro.close()
    due = {rid: ask for rid, ask in asks.items() if npc._dt(ask.sent_at) + npc.timedelta(days=npc.DEADLINE_DAYS) <= now}
    facts, docs, intercom, anchors, gate, paid = real_inputs(sorted(due), not a.no_intercom)
    rows, skipped = npc.evaluate(now, due, reminded, facts, docs, intercom, anchors, gate, paid)
    for r in rows[:max(a.sample, 0)]:
        print(json.dumps(r.__dict__, default=str))
    summary = {"as_of": now.strftime("%Y-%m-%dT%H:%M:%SZ"), "asked_requests": len(asks), "due": len(due),
               "skipped": skipped, "would_close": sum(r.decision == "close" for r in rows),
               "would_close_paid": sum(r.decision == "close" and r.paid is True for r in rows),
               "hold": {}, "rule_version": npc.rule_version()}
    for r in rows:
        if r.decision == "hold":
            k = r.reason.split(":")[0]
            summary["hold"][k] = summary["hold"].get(k, 0) + 1
    if a.preview_as_of:
        summary["mode"] = "preview (nothing written)"
        print(json.dumps(summary))
        return 0
    mode_s = "apply" if a.apply else "shadow"
    db = sqlite3.connect(a.ledger, timeout=30)
    npc.ensure_columns(db)
    run_id = f"no-proof-{mode_s}-" + uuid.uuid4().hex[:10]
    rec = npc.record(db, run_id, mode_s, rows, now)
    summary.update(mode=mode_s, run_id=run_id, written_close=rec["close"], written_hold=rec["hold"],
                   duplicate=rec["duplicate"])
    if a.apply:
        # every committed-but-unpublished apply row, this run's and any earlier interrupted run's (QA #1536)
        summary["publish"] = npc.publish(db, run_id, a.tray_dir, now, real_recheck(not a.no_intercom))
    print(json.dumps(summary))
    return 0


if __name__ == "__main__":
    sys.exit(main())
