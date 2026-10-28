#!/usr/bin/env python3
"""Caroline's real, safe actions (caroline-operator-c1). Called by the support-tools plugin only.

  caroline-actions.py status        --email E --conv C [--topic credit|claim]
  caroline-actions.py doc-intake    --email E --conv C --subject credit|claim
  caroline-actions.py merge-intake  --email E --conv C --kind profile-merge --keep UUID --other UUID [...]
  caroline-actions.py merge-record  --email E --conv C --row N (--ticket-id ID | --failed)
  caroline-actions.py handoff       --email E --conv C --reason R [--summary TEXT]
  caroline-actions.py board-export  [--out FILE]      (the handoff queue as one JSON snapshot)

--email is the VERIFIED Intercom author email the plugin derived from the trusted session key; never a
model argument. Prints ONE JSON object on stdout. Never approves, rejects, deletes or hides anything,
and sends nothing: approved lines are returned for Caroline's reply only while
/etc/hydra/caroline-actions-lines.enabled exists (absent while the freeze holds).
Kill switch: /etc/hydra/caroline-actions.disabled -> {"disabled": true}, nothing read or written.
Design: docs/credit-verification/caroline-actions.md.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from caroline_actions import actions, ledger  # noqa: E402


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(prog="caroline-actions.py")
    ap.add_argument("--ledger", default=ledger.DEFAULT_PATH)
    sub = ap.add_subparsers(dest="verb", required=True)

    def common(p):
        p.add_argument("--email", required=True)
        p.add_argument("--conv", required=True)

    p = sub.add_parser("status"); common(p); p.add_argument("--topic", choices=("credit", "claim"), default="credit")
    p = sub.add_parser("doc-intake"); common(p); p.add_argument("--subject", choices=("credit", "claim"), required=True)
    p = sub.add_parser("merge-intake"); common(p)
    p.add_argument("--kind", default="profile-merge")
    p.add_argument("--keep", required=True)
    p.add_argument("--other", action="append", default=[])
    p = sub.add_parser("merge-record"); common(p)
    p.add_argument("--row", type=int, required=True)
    g = p.add_mutually_exclusive_group(required=True)
    g.add_argument("--ticket-id")
    g.add_argument("--failed", action="store_true")
    p = sub.add_parser("handoff"); common(p)
    p.add_argument("--reason", required=True)
    p.add_argument("--summary", default="")
    p = sub.add_parser("board-export"); p.add_argument("--out", default=None)
    a = ap.parse_args(argv)

    if os.path.exists(actions.KILL_SWITCH):
        print(json.dumps({"disabled": True, "note": "caroline actions are switched off"}))
        return 0
    db = ledger.connect(a.ledger)
    try:
        if a.verb == "board-export":
            snap = ledger.board_snapshot(db)
            text = json.dumps(snap, indent=1)
            if a.out:
                tmp = a.out + ".tmp"
                Path(tmp).write_text(text + "\n")
                os.chmod(tmp, 0o600)
                os.replace(tmp, a.out)
                print(json.dumps({"exported": len(snap["handoffs"]), "out": a.out}))
            else:
                print(text)
            return 0
        load = actions.default_loader(db)
        if a.verb == "status":
            out = actions.status(db, email=a.email, conv=a.conv, topic=a.topic, load=load)
        elif a.verb == "doc-intake":
            out = actions.doc_intake(db, email=a.email, conv=a.conv, subject=a.subject, load=load)
        elif a.verb == "merge-intake":
            out = actions.merge_intake(db, email=a.email, conv=a.conv, kind=a.kind, keep=a.keep, others=a.other,
                                       load=load)
        elif a.verb == "merge-record":
            out = actions.merge_record(db, email=a.email, conv=a.conv, row=a.row, ticket_id=a.ticket_id,
                                       ok=not a.failed)
        else:
            out = actions.handoff(db, email=a.email, conv=a.conv, reason=a.reason, summary=a.summary, load=load)
    finally:
        db.close()
    print(json.dumps(out, default=str))
    return 0


if __name__ == "__main__":
    sys.exit(main())
