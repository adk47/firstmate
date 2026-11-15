#!/usr/bin/env python3
"""Corrected OURS for the verification lane: pending requests that no DELIVERED ask names.

The gauge (firstmate's verif-lane.check.sh) prints `pending - sent`, where `sent` is every request id in
verify_requests whose message row is `sent`. That count is not restricted to requests still pending, so every
delivered ask on a request that has since been decided is subtracted from today's pending.

Two reads, because the two facts live in two stores (core replica, node-8 ledger), then a join by request id.
Read-only. Run from the repo root on a box that reaches both (ak47):

    python3 data/ask-never-asked-r1/tools/corrected_ours.py
"""
from __future__ import annotations

import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
PENDING_SQL = ("SELECT lower(CAST(id AS varchar)) FROM postgresql_core.public.credit_requests "
               "WHERE status = 'user_verification_needed' AND deletedat IS NULL")
# every verify_requests row counts as "asked" (the gauge's own definition), so the join to the message is a LEFT join
LEDGER_SQL = ("select lower(r.request_id), coalesce(m.status, '') from verify_requests r "
              "left join verify_messages m on m.id = r.message_row")
SSH = ["ssh", "-o", "ConnectTimeout=15", "-J", "root@135.148.169.37", "root@10.0.0.8"]
LEDGER = "/var/lib/hydra/credit-review/ledger.sqlite3"


def lines(argv: list[str], stdin: str | None = None) -> list[str]:
    res = subprocess.run(argv, input=stdin, capture_output=True, text=True, timeout=600, check=False)
    if res.returncode != 0:
        sys.exit(f"read failed (rc {res.returncode}): {' '.join(argv[:3])} ... {res.stderr.strip()[-300:]}")
    return [ln.strip().strip('"') for ln in res.stdout.splitlines() if ln.strip()]


def main() -> int:
    pending = set(lines([str(ROOT / "scripts" / "trino-query.sh")], stdin=PENDING_SQL))
    rows = [ln.split("|") for ln in lines(SSH + [f"sqlite3 -readonly {LEDGER} \"{LEDGER_SQL}\""])]
    if not pending or not rows:
        sys.exit("an empty read is not a measurement: nothing printed")
    asked = {r[0] for r in rows}
    sent = {r[0] for r in rows if r[1] == "sent"}
    refused = {r[0] for r in rows if r[1] in ("rejected", "refused")}
    n = len(pending)
    print(f"read at {datetime.now(timezone.utc):%Y-%m-%dT%H:%MZ}")
    print(f"pending {n}")
    print(f"gauge arithmetic:  sent {len(sent)} (all time)  -> OURS = {n - len(sent)}; "
          f"never asked = {n - len(asked)}; refused = {len(refused)}")
    print(f"sent ids that are pending {len(sent & pending)}; sent ids no longer pending {len(sent - pending)}")
    print(f"corrected:         OURS = {len(pending - sent)}  (pending with no delivered ask)")
    print(f"  never asked (no ledger row)          {len(pending - asked)}")
    print(f"  refused or rejected, never delivered {len((pending & refused) - sent)}")
    print(f"  other ledger row, never delivered    {len((pending & asked) - sent - refused)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
