#!/usr/bin/env python3
"""READ-ONLY: why the credit filings at the head of doc-verify's selection never leave it (node-8).

    ssh root@node-8 'cd /opt/hydra/scripts && python3 -' < data/verif-claim-doc-extract-r1/measure_head_of_line.py

For every credit filing `runner._intake_docs` says still owes a read, and separately for the 10 each shard would
take this hour: is it keyed, are its candidates the ones last recorded, how many of its keys are unfinished, and in
how many runs has its document already been located under this VERSION. Opens both stores `mode=ro`; no replica
read, no model call, no write. Prints counts only.
"""
from __future__ import annotations

import collections
import json
import sqlite3
import sys
from types import SimpleNamespace

sys.path.insert(0, "/opt/hydra/scripts")

from credit_verify.docverify import pace, runner  # noqa: E402
from credit_verify.docverify.blobs import BlobStore  # noqa: E402
from credit_verify.docverify.store import DocVerifyStore  # noqa: E402

WORKERS, PER = 4, 10


def state(store: DocVerifyStore, doc) -> tuple[str, int]:
    rec = store.intake_keys_recorded(doc.intake_id)
    runs = store.db.execute("SELECT COUNT(DISTINCT run_id) FROM dv_steps WHERE proof_id=? AND step='locate' AND "
                            "version=?", (doc.sha, runner.VERSION)).fetchone()[0]
    if rec is None:
        return "never_keyed", runs
    if sorted(rec.get("candidates") or []) != sorted(doc.candidate_ids):
        return "candidates_changed", runs
    left = set(rec.get("keys") or []) - store.intake_finished_keys(doc.intake_id)
    return ("keys_unfinished" if left else "settled?"), runs


def main() -> int:
    store = DocVerifyStore.read_only()
    proof = sqlite3.connect(f"file:{runner.PROOF_STORE}?mode=ro", uri=True, timeout=60)
    try:
        paying = frozenset(int(u) for u in json.load(open("/var/lib/credit-trust/paying-users.json"))["ids"])
    except (OSError, ValueError, KeyError, TypeError):
        paying = None
    deps = SimpleNamespace(blobs=BlobStore(), claimants=None)
    every: collections.Counter = collections.Counter()
    head: collections.Counter = collections.Counter()
    head_runs: collections.Counter = collections.Counter()
    head_received: list[str] = []
    for i in range(WORKERS):
        keep = lambda pid, i=i: pace.shard_of(pid, WORKERS) == i  # noqa: E731
        docs = runner._intake_docs(proof, store, deps, 10 ** 9, keep=keep, paying=paying)
        for n, doc in enumerate(docs):
            why, runs = state(store, doc)
            every[why] += 1
            if n < PER:
                head[why] += 1
                head_runs["located in 0 runs" if runs == 0 else "located in 1 run" if runs == 1 else
                          "located in 2-5 runs" if runs <= 5 else "located in 6+ runs"] += 1
                head_received.append(doc.received_at[:10])
    print(json.dumps({"version": runner.VERSION, "owing_a_read": dict(every), "head_40": dict(head),
                      "head_40_located_before": dict(head_runs),
                      "head_40_received": dict(collections.Counter(head_received))}, indent=1, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
