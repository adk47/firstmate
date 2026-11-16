#!/usr/bin/env python3
"""Push the DSP verifier's built anchor records to core (POST /admin/credit-anchors) as the verifier identity.

  credit-anchors-push.py --pending [--apply] [--max-requests N]      the scheduled run (cron `credit-anchors-push`)
  credit-anchors-push.py --scheduler-runs [N]                        the scheduler's last N runs of that cron
  credit-anchors-push.py --tray <approve tray.json> [--apply] [--store <dsp-verify.sqlite>]
  credit-anchors-push.py --ids <id,id,...> [--apply]

Dry run by default: prints how many built records exist and how many core rows they make. --apply posts them
in whole-request batches of <= 100 rows (a request is never split; one over the cap is reported as a convert
error) and appends each outcome to the verifier store. Writes no credit status, sends nothing.

--pending takes no list: it uploads every built record that has not landed in core yet, and appends one run record
(start, end, exit code, what it pushed) to /var/lib/hydra/credit-anchors-push/runs.jsonl. With nothing built and
unlanded it posts nothing and exits 0 (`nothing_pending`). Kill files: /etc/hydra/credit-anchors-push.disabled and
the shared /etc/hydra/credit-verify.disabled. A record whose upload failed 12 times is paged and rests an hour; a
later run that finds core reachable (one admin GET) uploads it again. Rules and exit codes:
scripts/credit_review/anchor_push_run.py.

--scheduler-runs reads the gateway's cron receipts read-only and pairs each with its run record. Exit 0 only when
the N newest finished runs (default 2) each succeeded from the schedule; 1 when they did not; 2 when the
scheduler's store could not be read.

--tray / --ids are the operator's per-tray path. They share the schedule's packing rule (a request is never split
across POSTs; one over the 100-row cap is a convert error), and an apply that does not land every requested row
exits 1.
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from credit_review import anchor_push_run, anchor_upload  # noqa: E402
from credit_verify.dspverify import store as dsp_store  # noqa: E402


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument("--tray")
    g.add_argument("--ids")
    g.add_argument("--pending", action="store_true")
    g.add_argument("--scheduler-runs", nargs="?", type=int, const=2, default=None, metavar="N")
    ap.add_argument("--apply", action="store_true")
    ap.add_argument("--store", default=None)
    ap.add_argument("--max-requests", type=int, default=anchor_push_run.MAX_REQUESTS)
    ap.add_argument("--state-db", default=anchor_push_run.GATEWAY_STATE_DB,
                    help="the gateway state db --scheduler-runs reads (read-only)")
    a = ap.parse_args()
    if a.scheduler_runs is not None:
        if a.scheduler_runs < 1:
            ap.error("--scheduler-runs needs N >= 1")
        try:
            rep = anchor_push_run.scheduler_runs(a.scheduler_runs, state_db=a.state_db)
        except anchor_push_run.SchedulerUnreadable as exc:
            print(json.dumps({"unreadable": str(exc)}))
            return 2
        print(json.dumps(rep, indent=1, sort_keys=True))
        return 0 if rep["consecutive_ok"] else 1
    if a.pending:
        rec = anchor_push_run.scheduled_run(lambda: dsp_store.Store(a.store), apply=a.apply,
                                            max_requests=a.max_requests)
        print(json.dumps(rec, sort_keys=True))
        return int(rec["exit_code"])
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
