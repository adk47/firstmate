#!/usr/bin/env python3
"""Draw the stratified blind sample of 60 record-type documents (docverify-blind-60-r1).

Read-only (`mode=ro`). Run on node-8, output to stdout as JSON:

    ssh root@node-8 'nice -n 10 python3 - --emit' < draw_sample.py > sample.json

THE POPULATION is the one the captain's "980 real record-type documents" was measured on
(docverify-blind-check-r1, `support_by_type.json`, 2026-11-15 01:23Z): every document with a
standing doc-verify outcome row of the current verifier version written at or before CUTOFF,
whose extraction (as of CUTOFF) is ok and has a `doc_type` in `gate.RECORD_DOC_TYPES`. Freezing
it at CUTOFF reproduces 980 exactly (8,167 not-record, 796 no extraction); the live count has grown
since, and the draw does not use it.

THE DRAW is proportional allocation by document type (largest remainder), then a seeded uniform
draw inside each stratum from the sorted proof ids. Nothing the reader decided (outcome, reason,
gate detail, extracted support) is read: the draw sees only the document type and the id.

The pure parts (`allocate`, `draw`) are imported by the tests; only `main` touches node-8.
"""
import hashlib
import json
import random
import sys

CUTOFF = "2026-11-15T01:23:59Z"
SEED = "docverify-blind-60-r1"
SAMPLE_SIZE = 60
DB = "file:/var/lib/hydra-credit-verify/doc-verify.sqlite?mode=ro"


def allocate(counts, n):
    """Largest-remainder proportional allocation of n over {stratum: population}.

    A stratum never gets more than its population; any shortfall goes to the strata with room,
    largest remainder first, so the result always sums to n (or to the whole population if smaller).
    """
    total = sum(counts.values())
    if total == 0:
        return {k: 0 for k in counts}
    n = min(n, total)
    quota = {k: n * v / total for k, v in counts.items()}
    alloc = {k: min(int(q), counts[k]) for k, q in quota.items()}
    order = sorted(counts, key=lambda k: (-(quota[k] - int(quota[k])), k))
    while sum(alloc.values()) < n:
        moved = False
        for k in order:
            if sum(alloc.values()) >= n:
                break
            if alloc[k] < counts[k]:
                alloc[k] += 1
                moved = True
        if not moved:
            break
    return alloc


def draw(population, n, seed=SEED):
    """population: {stratum: [ids]} -> [(id, stratum)], seeded, deterministic, no repeats."""
    counts = {k: len(set(v)) for k, v in population.items()}
    alloc = allocate(counts, n)
    out = []
    for stratum in sorted(population):
        ids = sorted(set(population[stratum]))
        rng = random.Random(hashlib.sha256(f"{seed}:{stratum}".encode()).hexdigest())
        for pid in rng.sample(ids, alloc[stratum]):
            out.append((pid, stratum))
    return out, counts, alloc


def main():  # pragma: no cover - runs on node-8 only
    import sqlite3
    sys.path.insert(0, "/opt/hydra/scripts")
    from credit_verify.docverify import VERSION
    from credit_verify.docverify.gate import RECORD_DOC_TYPES

    dv = sqlite3.connect(DB, uri=True, timeout=120)
    docs = {r[0] for r in dv.execute(
        "select distinct proof_id from dv_outcomes where version=? and at<=?", (VERSION, CUTOFF))}
    doc_type = {}
    for pid, dj in dv.execute("select proof_id, detail_json from dv_steps where step='extract' "
                              "and request_id='' and at<=? order by id", (CUTOFF,)):
        try:
            d = json.loads(dj)
        except ValueError:
            continue
        doc_type[pid] = d.get("doc_type") if d.get("ok") else None
    population = {}
    for pid in docs:
        t = doc_type.get(pid)
        if t in RECORD_DOC_TYPES:
            population.setdefault(t, []).append(pid)
    for t in RECORD_DOC_TYPES:
        population.setdefault(t, [])
    sample, counts, alloc = draw(population, SAMPLE_SIZE)
    json.dump({"version": VERSION, "cutoff": CUTOFF, "seed": SEED,
               "record_doc_types": list(RECORD_DOC_TYPES),
               "population_total": sum(counts.values()), "population": counts, "drawn": alloc,
               "sample": [{"n": i + 1, "proof_id": pid, "doc_type": t, "stratum": t}
                          for i, (pid, t) in enumerate(sample)]}, sys.stdout, indent=1)
    print()


if __name__ == "__main__" and "--emit" in sys.argv:  # pragma: no cover
    main()
