#!/usr/bin/env python3
"""READ-ONLY per-role partial list (captain 2026-11-06 ~17:05Z: "approve the roles where proof supports it
... handle this furably for future partial support documents coming in").

The decider's per-role split approves the roles its proof covered and still owes an ask for the rest. The
request stays `unverified` in core (the per-role write half does not exist yet), so the replica re-check
drops it and no ask campaign names it. This builder emits exactly that population - the ledger's latest
`approve_partial` rows with roles still pending and no ask hold on them - in the deployed uvn-status
runner's list format (list-P.json, ids only), so the one ask sender that runs today can reach them.
Only the split requests are listed: the sender scopes a PARTIAL entry to its listed rows, so another
open request of the same user is never asked about here (and never holds the split as `unlisted`).

Writes list-P.json in argv[1]. Never writes a credit, never sends."""
import csv, io, json, os, subprocess, sys
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from credit_review.uvn_status import partial_pending_ids  # noqa: E402 - the decider's own read, one definition

OUT = Path(sys.argv[1]); OUT.mkdir(parents=True, exist_ok=True)
LEDGER = os.environ.get("CREDIT_REVIEW_LEDGER", "/var/lib/hydra/credit-review/ledger.sqlite3")
TRINO = os.environ.get("CREDIT_PROOF_TRINO", "/opt/hydra/scripts/trino-query.sh")
PAID = "(select distinct s.teamid from postgresql_core.public.subscriptions s where s.status in ('active','trialing'))"
now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
def trino(sql: str) -> list[list[str]]:
    p = subprocess.run([TRINO], input=sql, capture_output=True, text=True, timeout=1200)
    if p.returncode:
        sys.exit(p.stderr[-300:])
    return list(csv.reader(io.StringIO("\n".join(l for l in p.stdout.splitlines() if l.startswith('"')))))


ids = sorted(partial_pending_ids(LEDGER))
users = []
if ids:
    by_user = {}
    for rid, uid, paid in trino(f"""
select cast(cr.id as varchar), cast(cr.userid as varchar),
       cast(max(case when cr.workspaceid in {PAID} then 1 else 0 end) as varchar)
from postgresql_core.public.credit_requests cr
where cr.deletedat is null and cr.id in ({",".join(f"'{i}'" for i in ids)})
group by 1, 2"""):
        if rid and uid.isdigit():
            row = by_user.get(int(uid))
            if row is None:
                row = by_user[int(uid)] = {"user_id": int(uid), "paid": paid == "1", "skip": None,
                                           "request_ids": [], "class": "PARTIAL"}
            # PAID is ORed across the user's rows, never taken from the first row seen: Trino returns the
            # rows in no guaranteed order, and a free-workspace partial arriving before a paid-workspace
            # one used to mark the user free, running both requests under the free segment and its cap.
            row["paid"] = row["paid"] or paid == "1"
            row["request_ids"].append(rid)
    users = [by_user[u] for u in sorted(by_user) if by_user[u]["request_ids"]]
with open(OUT / "list-P.json", "w") as fh:
    json.dump({"generated_at": now, "source": "partial_asks", "campaign": "uvn-status", "users": users},
              fh, indent=1)
print(json.dumps({"partial_requests": len(ids), "users": len(users),
                  "paid": sum(1 for u in users if u["paid"])}))
