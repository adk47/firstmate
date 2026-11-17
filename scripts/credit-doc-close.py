#!/usr/bin/env python3
"""credit-doc-close: the coded document closes C3 `junk_proof` and C8 `fraud_document` (credit_review/doc_close.py).

  credit-doc-close.py --rule junk  --preview    decide, print the per-user split, write nothing
  credit-doc-close.py --rule fraud --rulings F  + append SHADOW rows to the decider ledger (coded-close shape);
                                                 F = the labelled rulings (a 'not' always holds); shadow is the default
  credit-doc-close.py --rule junk --mode apply --batch-id B   write the coded CLOSES, refused unless the rule's
                                                 apply_enabled is true in policies/credit-doc-close.json

Inputs, all read-only:
  - the doc-verify store (artifact kinds; the forged_positive outcomes and their history);
  - proof_intake (the filings);
  - core facts (Trino replica, fable_executor.fetch_facts), V9 anchors, the account gate, the R8 hold set.
It never writes a credit status. Apply is decided by the per-rule policy switch (policies/credit-doc-close.json) and is
read at the write: a rule whose entry is not `apply_enabled` refuses the run and writes nothing. Summary JSON on stdout.
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

from credit_review import doc_close as dc  # noqa: E402

LEDGER = "/var/lib/hydra/credit-review/ledger.sqlite3"
DV_STORE = "/var/lib/hydra-credit-verify/doc-verify.sqlite"
PROOF_STORE = "/var/lib/hydra-credit-verify/proof.sqlite"


def _facts(ids: list[str]) -> dict:
    from credit_review import fable_executor as fx
    out: dict = {}
    for i in range(0, len(ids), 400):
        out.update(fx.fetch_facts(ids[i:i + 400]))
    return out


def junk_rows(dv: sqlite3.Connection, pdb: sqlite3.Connection, paid: frozenset[int] | None):
    from credit_review import account_gate, comm_state
    from credit_review import fable_executor as fx
    from credit_verify.docverify import artifacts
    from credit_verify.docverify.extract import _title_key
    from credit_verify.docverify.store import VERSION
    from credit_verify.proof import stage2
    docs = artifacts.filed_rows(dv, pdb, paid or frozenset(), version=VERSION)
    junk_rids = sorted({rid for r in docs if r["artifact"] for rid in r["candidates"]})
    reqs = stage2.requests(junk_rids) if junk_rids else {}
    titles = {rid: _title_key(q.title) for rid, q in reqs.items()}
    jl = artifacts.junk_list(docs, titles, None)
    scope = sorted({str(p["request_id"]).lower() for p in jl["decline_requests"] + jl["held_untied"]})
    facts = _facts(scope)
    return dc.evaluate_junk(jl, docs, facts, fx.dsp_anchors(scope), account_gate.check,
                            comm_state.account_hold_facts, paid)


def fraud_rows(dv_path: str, pdb: sqlite3.Connection, paid: frozenset[int] | None, now: datetime, rulings_text: str,
               facts_fn=None, anchors_fn=None, gate_fn=None, hold_fn=None):
    """C8 rows. `rulings_text`: the labelled rulings file (QA #1571): a document ruled `not` (a known false forgery)
    carries that ruling into evaluate_fraud and holds. The real readers are the defaults; tests inject fakes."""
    from credit_verify.docverify import tray
    from credit_verify.docverify.store import VERSION, DocVerifyStore
    if facts_fn is None or anchors_fn is None or gate_fn is None or hold_fn is None:
        from credit_review import account_gate, comm_state
        from credit_review import fable_executor as fx
        facts_fn, anchors_fn = facts_fn or _facts, anchors_fn or fx.dsp_anchors
        gate_fn, hold_fn = gate_fn or account_gate.check, hold_fn or comm_state.account_hold_facts
    store = DocVerifyStore.read_only(dv_path)

    def intake_of(iid: str) -> dict:
        r = pdb.execute("SELECT subject, received_at FROM proof_intake WHERE intake_id=?", (iid,)).fetchone()
        return {"subject": r[0], "received_at": r[1]} if r else {}
    deny, _short = tray.forged_tray(store, intake_of=intake_of, rulings=tray.parse_rulings(rulings_text))
    scope = sorted({str(q["request_id"]).lower() for d in deny for q in d["requests"]})
    return dc.evaluate_fraud(deny, lambda oid: dc.forged_since(store.db, VERSION, oid), facts_fn(scope),
                             anchors_fn(scope), gate_fn, hold_fn, paid, now)


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--rule", choices=("junk", "fraud"), required=True)
    m = ap.add_mutually_exclusive_group()
    m.add_argument("--preview", action="store_true")
    m.add_argument("--mode", choices=dc.MODES, default="shadow",
                   help="shadow (default) records the decisions only; apply writes the coded closes and is refused "
                        "unless the rule's apply_enabled is true in policies/credit-doc-close.json")
    ap.add_argument("--batch-id", help="tags every row of an apply run (required with --mode apply)")
    ap.add_argument("--ledger", default=LEDGER)
    ap.add_argument("--doc-verify-store", default=DV_STORE)
    ap.add_argument("--proof-store", default=PROOF_STORE)
    ap.add_argument("--rulings", help="the labelled rulings file ('ruling: forged-<sha8> confirm|not'); REQUIRED for "
                                      "--rule fraud so a known false forgery always holds (QA #1571)")
    ap.add_argument("--sample", type=int, default=0)
    a = ap.parse_args(argv)
    if a.mode != "apply" and a.batch_id is not None:
        print(json.dumps({"refused": "--batch-id tags an apply run only (--mode apply)"}))
        return 2
    if a.rule == "fraud":
        try:
            rulings_text = Path(a.rulings).read_text(encoding="utf-8") if a.rulings else None
        except OSError as exc:
            rulings_text, why = None, f"{type(exc).__name__}"
        else:
            why = "no --rulings file"
        if rulings_text is None:
            print(json.dumps({"refused": f"--rule fraud needs a readable --rulings file ({why}): a 'not' ruling "
                                         "must reach the rule"}))
            return 2
    from credit_review import decide
    now = datetime.now(timezone.utc)
    kind = dc.JUNK if a.rule == "junk" else dc.FRAUD
    paid, _why = decide.paying_users()
    dv = sqlite3.connect(f"file:{a.doc_verify_store}?mode=ro", uri=True)
    pdb = sqlite3.connect(f"file:{a.proof_store}?mode=ro", uri=True)
    rows, skipped = junk_rows(dv, pdb, paid) if kind == dc.JUNK else \
        fraud_rows(a.doc_verify_store, pdb, paid, now, rulings_text)
    for r in rows[:max(a.sample, 0)]:
        print(json.dumps(r.__dict__, default=str))
    out = {"rule": kind, "rule_version": dc.rule_version(kind), "skipped": skipped, **dc.summary(rows)}
    if a.preview:
        out["mode"] = "preview (nothing written)"
    else:
        db = sqlite3.connect(a.ledger, timeout=30)
        run_id = f"doc-close-{a.rule}-{a.mode}-" + uuid.uuid4().hex[:10]
        try:
            rec = dc.record(db, run_id, kind, rows, now, mode=a.mode, batch_id=a.batch_id)
        except dc.ApplyRefused as exc:
            out.update(mode=a.mode, refused=str(exc), written_close=0)
            print(json.dumps(out, default=str))
            return 3
        out.update(mode=a.mode, run_id=run_id, written_close=rec["close"], written_hold=rec["hold"],
                   duplicate=rec["duplicate"])
    print(json.dumps(out, default=str))
    return 0


if __name__ == "__main__":
    sys.exit(main())
