#!/usr/bin/env python3
"""credit-decision-told: core's own decision notice for requests core decided and never told (Fable
[key=decided-not-told-531]). Hydra sends no words: core's agent status route renders its live credits_accepted /
credits_rejected template under copyRef decision-approved / decision-rejected.

  credit-decision-told.py plan --list F --list-sha S                 re-read eligibility (read-only), per-user plan
  credit-decision-told.py dry  --list F --list-sha S --limit 10 --out D     route dry run per user (the signed file)
  credit-decision-told.py apply --list F --list-sha S --signed D --limit 1  the ONE real send
  credit-decision-told.py apply ... --signed D --readback-ok <that run id> --limit 100   the rest, paid first

Ladder: 10 signed dry (p1 + r5) -> ONE real -> read-back -> the rest. First live write ever = 1 user; a UTC day
<= 100 users. Kill file /etc/hydra/credit-decision-told.disabled stops dry and apply. The ledger, the kill file and
the route script are constants (no flag or env moves them); a list naming user 15 is refused. JSON on stdout.
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

from credit_review import decision_told as dt  # noqa: E402
from credit_review.core_notice import trino  # noqa: E402

LEDGER = "/var/lib/hydra/credit-review/ledger.sqlite3"
ADMIN_SCRIPT = "/opt/hydra/skills-all/muso-ops-admin/scripts/muso-admin-api.sh"


def _plans(a: argparse.Namespace, db: sqlite3.Connection, now: datetime, query, verify_ledger: str):
    header, users = dt.load_list(Path(a.list).read_bytes(), a.list_sha)
    ids = dt._ids(users)
    core = dt.core_rows(query, ids)
    vdb = sqlite3.connect(f"file:{verify_ledger}?mode=ro", uri=True)
    notes = dt.status_notes(vdb, ids)
    dt.ensure_table(db)
    return header, dt.plan(users, core, notes, dt.attempts(db), now, told=dt.told(db))


def main(argv: list[str] | None = None, *, query=trino, caller=None, ledger: str = LEDGER,
         verify_ledger: str = LEDGER, kill_file: str = dt.KILL_FILE) -> int:
    """argv carries no gate input (r5 [key=unattended]): the ledger the ladder counts, the kill file and the
    confirmer are constants. The keyword parameters are TEST SEAMS only; the __main__ entry never passes them."""
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("cmd", choices=("plan", "dry", "apply"))
    ap.add_argument("--list", required=True)
    ap.add_argument("--list-sha", required=True, help="the signed list's sha256[:12] (the facts header)")
    ap.add_argument("--limit", type=int, default=10)
    ap.add_argument("--channel", default=dt.CHANNEL)
    ap.add_argument("--signed", help="apply: the signed dry-run file")
    ap.add_argument("--out", help="dry: write the dry-run report here (the file p1 + r5 sign)")
    ap.add_argument("--readback-ok", default="", help="apply past the first: the run id of the ONE real send you read back")
    a = ap.parse_args(argv)
    if a.cmd != "plan" and os.path.exists(kill_file):
        print(json.dumps({"refused": f"kill file {kill_file} present"}))
        return 3
    db = sqlite3.connect(ledger, timeout=30, isolation_level=None)
    now = datetime.now(timezone.utc)
    try:
        header, plans = _plans(a, db, now, query, verify_ledger)
    except (dt.DecisionToldError, OSError, sqlite3.Error, ValueError) as exc:
        print(json.dumps({"refused": f"{type(exc).__name__}: {exc}"}))
        return 2
    if a.cmd == "plan":
        ready = [p for p in plans if not p.hold]
        held: dict[str, int] = {}
        for p in plans:
            if p.hold:
                held[p.hold] = held.get(p.hold, 0) + 1
        print(json.dumps({"facts_header": header, "users": len(plans), "eligible": len(ready),
                          "with_prior_status_note": sum(bool(p.prior_status_note) for p in ready),
                          "later_groups": sum(len(p.later_groups) for p in ready),
                          "eligible_paid": sum(p.paid for p in ready), "requests": sum(len(p.subject_ids) for p in ready),
                          "by_copy_ref": {r: sum(p.copy_ref == r for p in ready) for r in dt.COPY_REF.values()},
                          "held": held, "first": [p.as_dict() for p in ready[:a.limit]]}, sort_keys=True))
        return 0
    signed = None
    if a.cmd == "apply":
        if not a.signed:
            print(json.dumps({"refused": "apply needs --signed <the signed dry-run file>"}))
            return 2
        dry = json.loads(Path(a.signed).read_text())
        if (dry.get("facts_header") or {}).get("list_sha") != header["list_sha"]:
            print(json.dumps({"refused": "the signed dry run is for a different list"}))
            return 2
        try:
            signed = dt.signed_subjects(dry)
        except dt.DecisionToldError as exc:
            print(json.dumps({"refused": str(exc)}))
            return 2
    call = caller or dt.admin_caller(ADMIN_SCRIPT)          # the confirmer is a constant: no env can swap it
    run_id = f"decision-told-{a.cmd}-" + uuid.uuid4().hex[:10]
    out = dt.run(db, plans, call, run_id=run_id, now=now, channel=a.channel,
                 apply=a.cmd == "apply", limit=a.limit, signed=signed, kill_file=kill_file,
                 readback_of=a.readback_ok)
    out["facts_header"] = header
    if a.out:
        Path(a.out).write_text(json.dumps(out, indent=1, sort_keys=True))
    print(json.dumps(out, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
