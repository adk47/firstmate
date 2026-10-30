#!/usr/bin/env python3
"""Push the DSP verifier's built anchor records to core (POST /admin/credit-anchors) as the verifier identity.

  credit-anchors-push.py --tray <approve tray.json> [--apply] [--store <dsp-verify.sqlite>]
  credit-anchors-push.py --ids <id,id,...> [--apply]

Dry run by default: prints how many built records exist for the tray's requests and how many core rows they make.
--apply posts them (<= 100 rows per call) and appends each outcome to the verifier store. Writes no credit status,
sends nothing. Never scheduled (manual, per approve tray, before the executor's approve run).
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from credit_review import anchor_upload  # noqa: E402
from credit_verify.dspverify import store as dsp_store  # noqa: E402


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument("--tray")
    g.add_argument("--ids")
    ap.add_argument("--apply", action="store_true")
    ap.add_argument("--store", default=None)
    a = ap.parse_args()
    if a.tray:
        doc = json.loads(Path(a.tray).read_text())
        if doc.get("action") != "approve":
            print(json.dumps({"refused": "anchors are pushed for approve trays only"}))
            return 2
        ids = [r["request_id"] for r in doc.get("rows") or []]
    else:
        ids = [i.strip() for i in a.ids.split(",") if i.strip()]
    st = dsp_store.Store(a.store)
    rep = anchor_upload.push(st, ids, apply=a.apply)
    print(json.dumps(rep))
    return 1 if rep.get("stopped") else 0


if __name__ == "__main__":
    sys.exit(main())
