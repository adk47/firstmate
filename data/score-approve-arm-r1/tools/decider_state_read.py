#!/usr/bin/env python3
"""READ-ONLY, runs on node-8: where each engaged request stands with the DECIDER and with stage 2.

Stage 2 judges only the requests whose latest decider decision (mode apply / judge) is a hold that starts
"proof on file" (credit_verify/proof/stage2.py held_rows). So a request score-approve leaves "for stage 2"
reaches stage 2 only if the decider holds it that way. This reads, per request on stdin literal
REQUESTS_JSON ({request id: user id}):

  * the latest decider decision of mode apply / judge: decision + the reason up to its first ':' or ' (';
  * how many stage2_shadow rows the request has, per analyzer version (any version, not only the current);
  * whether a filed document names it as a candidate (proof_intake), and that document's doc-verify state
    is NOT read here.

Both stores are opened `mode=ro`. stdout: one JSON object, ids / counts / reason classes only.
"""
import collections
import json
import sqlite3
import sys

LEDGER = "/var/lib/hydra/credit-review/ledger.sqlite3"
PROOF = "/var/lib/hydra-credit-verify/proof.sqlite"
REQUESTS = json.loads(REQUESTS_JSON)  # noqa: F821 - prepended by the caller
ids = sorted({r.lower() for r in REQUESTS})


def chunks(seq, n=400):
    for i in range(0, len(seq), n):
        yield seq[i:i + n]


def cls(reason):
    return str(reason or "").split(" (")[0].split(":")[0][:70]


latest, modes = {}, collections.Counter()
db = sqlite3.connect(f"file:{LEDGER}?mode=ro", uri=True, timeout=30)
try:
    for part in chunks(ids):
        q = ",".join("?" * len(part))
        for rid, mode, decision, reason, at in db.execute(
                "WITH last AS (SELECT request_id, MAX(id) id FROM decisions WHERE mode IN ('apply', 'judge') "
                f"AND lower(request_id) IN ({q}) GROUP BY request_id) "
                "SELECT lower(d.request_id), d.mode, d.decision, d.reason, d.decided_at "
                "FROM decisions d JOIN last USING(id)", part):
            latest[rid] = {"mode": mode, "decision": decision, "reason_class": cls(reason),
                           "reason_head": str(reason or "")[:90], "decided_at": at}
finally:
    db.close()

shadow = collections.defaultdict(collections.Counter)
candidate = set()
db = sqlite3.connect(f"file:{PROOF}?mode=ro", uri=True, timeout=30)
try:
    for part in chunks(ids):
        q = ",".join("?" * len(part))
        for rid, ver, n in db.execute(
                f"SELECT lower(request_id), analyzer_version, COUNT(*) FROM stage2_shadow "
                f"WHERE lower(request_id) IN ({q}) GROUP BY 1, 2", part):
            shadow[rid][ver] = n
    want = set(ids)
    for (raw,) in db.execute("SELECT candidate_request_ids_json FROM proof_intake WHERE subject = 'credit'"):
        for rid in json.loads(raw or "[]"):
            rid = str(rid).strip().lower()
            if rid in want:
                candidate.add(rid)
finally:
    db.close()

print(json.dumps({"requests": {r: {"decider": latest.get(r), "stage2_rows": dict(shadow.get(r, {})),
                                   "intake_candidate": r in candidate} for r in ids}}))
