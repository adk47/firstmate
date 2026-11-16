#!/usr/bin/env python3
"""Score the reader against the judge on the blind 60 (docverify-blind-60-r1).

    python3 score.py --cases cases.json --judge judge.json --reader reader.json --out labels.json

Joins the three files the task produced into `labels.json` (one row per case: stratum, the judge's
verdict and the reader's, no names, no titles, no request ids) and prints the confusion matrix and the
bar. `labels.json` is what the committed report and the tests read.

The reader's verdict is the deployed reader's own standing `dv-4` outcome for that claim at the draw's
cutoff (`production_at_cutoff`): that is the answer the 980 measurement was made of. The read-only
re-run (`run_reader.py`) is the check that the answer is reproducible, recorded beside it.

The bar (from the blind check, unchanged): of the claims the judge says the document supports, the
reader verifies at least 8 of 10. Fewer than 10 supportable claims is NOT MEASURED with the count,
never a percentage.
"""
from __future__ import annotations

import argparse
import json
import sys

READER = ("verified", "unverifiable", "unknown")
JUDGE = ("yes", "no", "cannot_tell", "not_judged")
BAR_NEED, BAR_PASS = 10, 8


def label_rows(cases: list[dict], judge: dict, reader: dict) -> list[dict]:
    rows = []
    for c in cases:
        cid = c["case"]
        j = judge.get(cid) or {}
        r = reader.get(cid) or {}
        rows.append({
            "case": cid, "id": c["proof_id"][:16], "stratum": c["stratum"],
            "document_bytes": bool(c.get("bytes")),
            "judge": j.get("verdict") or "not_judged",
            "judge_saw": j.get("saw"),
            "judge_not_judged": j.get("not_judged"),
            "reader": r.get("production_at_cutoff") or "unknown",
            "reader_rerun": r.get("outcome") or "not_run",
            "reader_blockers": r.get("blockers") or [],
        })
    return rows


def matrix(rows: list[dict]) -> dict[str, dict[str, int]]:
    """reader verdict x judge verdict, every cell present, counts only."""
    m = {rv: {jv: 0 for jv in JUDGE} for rv in READER}
    for row in rows:
        if row["reader"] not in m or row["judge"] not in JUDGE:
            raise ValueError(f"{row['case']}: verdict outside the matrix: {row['reader']!r} x {row['judge']!r}")
        m[row["reader"]][row["judge"]] += 1
    return m


def total(m: dict[str, dict[str, int]]) -> int:
    return sum(sum(r.values()) for r in m.values())


def bar(rows: list[dict]) -> dict:
    """The 8-of-10 bar on the supportable claims. Fewer than 10 is NOT MEASURED, never a rate."""
    supportable = [r for r in rows if r["judge"] == "yes"]
    accepted = [r for r in supportable if r["reader"] == "verified"]
    n = len(supportable)
    false_accepts = sum(1 for r in rows if r["judge"] == "no" and r["reader"] == "verified")
    if n < BAR_NEED:
        verdict = f"NOT MEASURED: {n} supportable claims, the bar needs {BAR_NEED}"
    else:
        verdict = "PASS" if len(accepted) * BAR_NEED >= BAR_PASS * n else "FAIL"
    return {"supportable": n, "accepted": len(accepted), "false_accepts": false_accepts,
            "judge_no": sum(1 for r in rows if r["judge"] == "no"), "verdict": verdict}


def render(m: dict[str, dict[str, int]]) -> str:
    out = ["| reader \\ judge | " + " | ".join(JUDGE) + " | total |", "|---" * (len(JUDGE) + 2) + "|"]
    for rv in READER:
        out.append(f"| {rv} | " + " | ".join(str(m[rv][jv]) for jv in JUDGE) + f" | {sum(m[rv].values())} |")
    out.append("| **total** | " + " | ".join(str(sum(m[rv][jv] for rv in READER)) for jv in JUDGE)
               + f" | **{total(m)}** |")
    return "\n".join(out)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--cases", required=True)
    ap.add_argument("--judge", required=True)
    ap.add_argument("--reader", required=True)
    ap.add_argument("--out", required=True)
    a = ap.parse_args()
    rows = label_rows(json.load(open(a.cases))["cases"], json.load(open(a.judge)),
                      json.load(open(a.reader))["cases"])
    with open(a.out, "w") as fh:
        json.dump({"rows": rows}, fh, indent=1, sort_keys=True)
        fh.write("\n")
    m = matrix(rows)
    print(render(m))
    print(json.dumps(bar(rows), sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
