#!/usr/bin/env python3
"""credit-anchored-approve: feed every V9 APPROVE to the ANCHORED approval path (Fable [key=first-awards] path 1).

  credit-anchored-approve.py [--limit 1] --out-dir DIR

Reads the V9 store (latest self-captured APPROVE per request), core facts (Trino, read-only) and the executor audit
(never feeds a request twice); builds the anchor records in the verifier store (the verifier's own builder) and
writes ONE executor approve tray per expected status into DIR. Writes no credit status and uploads nothing. Then:
  python3 scripts/credit-anchors-push.py --tray <tray>            # dry run
  python3 scripts/credit-anchors-push.py --tray <tray> --apply    # ONE row first; b1 verifies the read-back
  python3 scripts/credit-fable-execute.py --tray <tray>           # executor dry run
  python3 scripts/credit-fable-execute.py --tray <tray> --apply --limit 1
Summary JSON on stdout.
"""
from __future__ import annotations

import argparse
import json
import sqlite3
import sys
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from credit_review import anchored_feed as af  # noqa: E402
from credit_review import fable_executor as fx  # noqa: E402


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--limit", type=int, default=1, help="candidates fed this run (start with 1)")
    ap.add_argument("--out-dir", required=True)
    ap.add_argument("--store", default=fx.DSP_STORE)
    a = ap.parse_args(argv)
    if a.limit < 1 or a.limit > fx.APPROVE_CAP:
        print(json.dumps({"refused": f"--limit must be 1..{fx.APPROVE_CAP}"}))
        return 2
    from credit_verify.dspverify.store import Store
    ro = sqlite3.connect(f"file:{a.store}?mode=ro", uri=True, timeout=10)
    try:
        cands = af.approve_candidates(ro)
    finally:
        ro.close()
    lines = []
    try:
        for ln in Path(fx.AUDIT_PATH).read_text(encoding="utf-8").splitlines():
            try:
                lines.append(json.loads(ln))
            except ValueError:
                continue
    except FileNotFoundError:
        pass
    res = af.feed(cands, outcomes=lambda ids: fx.dsp_verdict_outcomes([int(i.split(":")[1]) for i in ids], a.store),
                  facts=fx.fetch_facts, build=af.build_with_runner(Store(a.store)),
                  handled=af.already_handled(lines), limit=a.limit)
    out = Path(a.out_dir)
    out.mkdir(parents=True, exist_ok=True)
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    trays = []
    for status, doc in res.trays.items():
        p = out / f"anchored-approve-{stamp}-{status}.json"
        p.write_text(af.dumps(doc), encoding="utf-8")
        trays.append(str(p))
    print(json.dumps({"candidates": res.candidates, "built": [c.request_id for c in res.built],
                      "skipped": res.skipped, "trays": trays}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
