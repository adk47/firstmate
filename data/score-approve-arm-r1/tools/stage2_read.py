#!/usr/bin/env python3
"""READ-ONLY, runs on node-8: the stage-2 verdict of each request on stdin, from the deployed reader.

stdin: {"requests": {request id: user id}}. stdout: one JSON object, ids and outcomes only (no name, no
email, no document text). It opens the proof store through credit_review/stage2_verdicts.py, which opens it
`mode=ro`; it writes nothing and calls no API.

    ssh root@<node-8> 'cd /opt/hydra && PYTHONDONTWRITEBYTECODE=1 python3 -B -' < <(cat stage2_read.py; ...)

measure_held.py builds that command.
"""
import json
import sys

sys.path.insert(0, "/opt/hydra/scripts")
from credit_review import stage2_verdicts as s2  # noqa: E402

REQUESTS = json.loads(REQUESTS_JSON)  # noqa: F821 - prepended by measure_held.py
users = sorted({int(u) for u in REQUESTS.values()})
verdicts = s2.load(user_ids=users)            # every verdict of these accounts: an account hold needs them all
held = s2.held_accounts(verdicts)
out = {}
for rid, uid in REQUESTS.items():
    roles = verdicts.get(rid.lower())
    out[rid] = {"outcome": s2.outcome_of(roles) or "no_verdict",
                "roles": sorted({v.effective for v in (roles or {}).values()}),
                "account_held": int(uid) in held,
                "judged_at": max((v.judged_at for v in (roles or {}).values()), default="")}
print(json.dumps({"analyzer_version": s2.analyzer_version(), "users": len(users), "held_accounts": len(held & set(users)),
                  "requests": out}))
