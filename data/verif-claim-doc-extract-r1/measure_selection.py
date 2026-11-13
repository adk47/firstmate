#!/usr/bin/env python3
"""READ-ONLY measurement of doc-verify's claim-only selection on the live stores (node-8).

Run it from stdin so nothing is written to the host:
    ssh root@node-8 'cd /opt/hydra/scripts && python3 -' < data/verif-claim-doc-extract-r1/measure_selection.py

It opens both stores `mode=ro`, asks the replica ONE question (the open-claim accounts, uncached: a read-only
store cannot keep it) and calls the deployed `runner._intake_docs` / `runner.claim_only_docs` exactly as
`runner.run` does for each of the cron's shards (`--max-docs 40 --workers 4` = 10 per shard). No model call, no
Intercom, no admin API, no write.
"""
from __future__ import annotations

import json
import sqlite3
import sys
import time
from types import SimpleNamespace

sys.path.insert(0, "/opt/hydra/scripts")

from claim_verify import decline_rules  # noqa: E402
from credit_verify.docverify import pace, runner  # noqa: E402
from credit_verify.docverify.blobs import BlobStore  # noqa: E402
from credit_verify.docverify.store import DocVerifyStore  # noqa: E402
from credit_verify.proof import stage2  # noqa: E402

WORKERS, MAX_DOCS = 4, 40
PAYING = "/var/lib/credit-trust/paying-users.json"


def main() -> int:
    store = DocVerifyStore.read_only()
    proof = sqlite3.connect(f"file:{runner.PROOF_STORE}?mode=ro", uri=True, timeout=60)
    try:
        paying = frozenset(int(u) for u in json.load(open(PAYING))["ids"])
    except (OSError, ValueError, KeyError, TypeError):
        paying = None
    statuses = ",".join(f"'{s}'" for s in decline_rules.OPEN_STATUSES)
    accounts = frozenset(int(r[0]) for r in decline_rules._rows(stage2.trino_query(
        "SELECT DISTINCT cast(userid as varchar) FROM postgresql_core.public.claiming "
        f"WHERE deletedat IS NULL AND userid IS NOT NULL AND status IN ({statuses})")) if r and r[0].isdigit())
    deps = SimpleNamespace(blobs=BlobStore(), claimants=lambda: accounts)
    out: dict = {"at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "version": runner.VERSION,
                 "open_claim_accounts": len(accounts), "paying_known": paying is not None, "shards": []}
    per = [MAX_DOCS // WORKERS + (1 if i < MAX_DOCS % WORKERS else 0) for i in range(WORKERS)]
    tot_credit = tot_claim = tot_room = 0
    for i, budget in enumerate(per):
        keep = lambda pid, i=i: pace.shard_of(pid, WORKERS) == i  # noqa: E731
        credit_all = runner._intake_docs(proof, store, deps, 10 ** 9, keep=keep, paying=paying)
        claim_all = runner.claim_only_docs(proof, store, deps, 10 ** 9, keep=keep, paying=paying)
        pre = runner._intake_docs(proof, store, deps, budget, keep=keep, paying=paying)
        got = runner.claim_only_docs(proof, store, deps, budget - len(pre), keep=keep, paying=paying)
        out["shards"].append({"shard": i, "budget": budget, "credit_filings_owing_a_read": len(credit_all),
                              "claim_only_owing_a_read": len(claim_all), "credit_selected": len(pre),
                              "room_left_for_claim_only": budget - len(pre), "claim_only_selected": len(got)})
        tot_credit += len(credit_all)
        tot_claim += len(claim_all)
        tot_room += len(got)
    c = proof.execute
    out["proof_intake"] = {
        "no_candidate": c("SELECT count(*) FROM proof_intake WHERE candidate_request_ids_json='[]'").fetchone()[0],
        "no_candidate_with_file_path": c("SELECT count(*) FROM proof_intake WHERE candidate_request_ids_json='[]' "
                                         "AND coalesce(file_path,'') != ''").fetchone()[0],
        "no_candidate_open_claim_account": sum(
            1 for (u,) in c("SELECT user_id FROM proof_intake WHERE candidate_request_ids_json='[]'") if
            int(u) in accounts)}
    out["totals"] = {"credit_filings_owing_a_read": tot_credit, "claim_only_owing_a_read": tot_claim,
                     "claim_only_selected_next_run": tot_room}
    print(json.dumps(out, indent=1))
    return 0


if __name__ == "__main__":
    sys.exit(main())
