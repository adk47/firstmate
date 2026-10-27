#!/usr/bin/env python3
"""READ-ONLY silent count (captain 2026-10-26 16:05Z "nothing sits silent"), credit requests, paid and free.
Silent user = has an open credit request (not approved/rejected, not deleted), no core ask on any open row
(proofRequest.noticeSentAt/responseAt, infoRequest.responseAt) and no verify_messages sent/attempted row EVER
(any campaign, by account_id). G9 (paid) uses 'since 10-20' instead of 'ever'; both are printed.
Writes silent-paid.txt / silent-free.txt (ids only) in argv[1]."""
import csv, io, json, sqlite3, subprocess, sys
from pathlib import Path
OUT = Path(sys.argv[1]); OUT.mkdir(parents=True, exist_ok=True)
PAID = "(select distinct s.teamid from postgresql_core.public.subscriptions s where s.status in ('active','trialing'))"
sql = f"""
select cast(cr.userid as varchar),
       cast(max(case when cr.workspaceid in {PAID} then 1 else 0 end) as varchar),
       cast(max(case when coalesce(json_extract_scalar(cr.metadata,'$.proofRequest.noticeSentAt'),
                                   json_extract_scalar(cr.metadata,'$.proofRequest.responseAt'),
                                   json_extract_scalar(cr.metadata,'$.infoRequest.responseAt')) is not null then 1 else 0 end) as varchar),
       cast(count(*) as varchar)
from postgresql_core.public.credit_requests cr
where cr.deletedat is null and cr.status not in ('approved','rejected')
group by 1"""
p = subprocess.run(["/opt/hydra/scripts/trino-query.sh"], input=sql, capture_output=True, text=True, timeout=1200)
if p.returncode:
    sys.exit(p.stderr[-300:])
rows = [r for r in csv.reader(io.StringIO("\n".join(l for l in p.stdout.splitlines() if l.startswith('"')))) if r[0].isdigit()]
db = sqlite3.connect("file:/var/lib/hydra/credit-review/ledger.sqlite3?mode=ro", uri=True)
ever = {int(a) for (a,) in db.execute("select distinct account_id from verify_messages where status in ('sent','attempted')")
        if a and str(a).isdigit()}
since = {int(a) for (a,) in db.execute("select distinct account_id from verify_messages where status='sent' and created_at>='2026-10-20'")
         if a and str(a).isdigit()}
out = {}
for seg in ("paid", "free"):
    us = [(int(u), int(n)) for u, paid, asked, n in rows if (paid == "1") == (seg == "paid") and asked == "0"]
    pending = sum(1 for u, paid, *_ in rows if (paid == "1") == (seg == "paid"))
    silent = sorted(u for u, _ in us if u not in ever)
    g9 = sorted(u for u, _ in us if u not in since)
    (OUT / f"silent-{seg}.txt").write_text("".join(f"{u}\n" for u in silent))
    out[seg] = {"users_with_open_requests": pending, "no_core_ask": len(us), "silent_never_messaged_ever": len(silent),
                "g9_not_messaged_since_1020": len(g9), "open_rows_of_silent": sum(n for u, n in us if u not in ever)}
print(json.dumps(out, indent=1))
