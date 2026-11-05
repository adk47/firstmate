#!/usr/bin/env python3
"""weekly_line.py: the Monday 08:00Z line on the churn-with-open-issue signal.

    churned with open support issue: N users / $MRR (T1 n / T2 n / T3 n) - prev week N'

where N counts the users who cancelled in the last 7 days while a support issue was
still open (T1/T2/T3 as the firstmate report section 1.2: firstmate/data/
support-churn-winback-fable-c1/report.md
defines them, measured by scripts/churn/support_state.py --churned-since).

It reads the store, not Intercom: the nightly churned sweep at 04:15Z has already
classified everyone who cancelled in the last 30 days, so the Monday tick is a
query even on a quiet night.

Baseline it is measured against (report section 0, 60 days):
    T1 86 / T2 81 / T3 184, $5,371 list MRR, 16.3% of paying churn.
A per-week rate near 16.3% means the PREVENT signal is not biting yet; a fall in
the next weeks is the number the captain asked for.

CLI:
    weekly_line.py               the line, ready to post
    weekly_line.py --json        the counts
    weekly_line.py --days 7      a different window
"""

from __future__ import annotations

import argparse
import json
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from churn import stages          # noqa: E402
from churn.store import Store     # noqa: E402

POLICY = str(Path(__file__).resolve().parents[2] / "policies" / "churn-risk.json")
DEFAULT_TMPL = ("churned with open support issue: {n} users / ${mrr} "
                "(T1 {t1} / T2 {t2} / T3 {t3}) \u2014 prev week {prev}")


def load_policy(path: str) -> dict[str, Any]:
    with open(path, encoding="utf-8") as fh:
        doc = json.load(fh)
    if not isinstance(doc, dict):
        raise SystemExit(f"{path} is not a JSON object")
    return doc


def window_counts(rows: list[dict[str, Any]], lo: float, hi: float) -> dict[str, Any]:
    users = 0
    mrr = 0.0
    tiers: dict[str, int] = {}
    for row in rows:
        at = stages.iso_to_ts(row.get("churned_at"))
        if not at or not (lo <= at < hi):
            continue
        if not row.get("tier"):
            continue                      # cancelled, but nothing was waiting on us
        users += 1
        mrr += float(row.get("mrr_list") or 0)
        tiers[str(row["tier"])] = tiers.get(str(row["tier"]), 0) + 1
    return {"users": users, "mrr": round(mrr, 2), "tiers": tiers}


def line_for(doc: dict[str, Any], tmpl: str) -> str:
    return tmpl.format(n=doc["users"], mrr=f"{doc['mrr']:.2f}",
                       t1=doc["tiers"].get("T1", 0), t2=doc["tiers"].get("T2", 0),
                       t3=doc["tiers"].get("T3", 0), prev=doc["prev_users"])


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="the weekly churn-with-open-issue line")
    ap.add_argument("--policy", default=POLICY)
    ap.add_argument("--days", type=float, default=7.0)
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--now", type=float, default=None, help="epoch (tests)")
    args = ap.parse_args(argv)

    policy = load_policy(args.policy)
    store_path = (policy.get("store") or {}).get("support_state")
    store = Store(store_path, readonly=True)
    try:
        rows = store.users(mode="churned")
        run = store.last_run("churned")
    finally:
        store.close()

    now = args.now if args.now is not None else time.time()
    span = args.days * stages.DAY
    cur = window_counts(rows, now - span, now)
    prev = window_counts(rows, now - 2 * span, now - span)
    tmpl = ((policy.get("slack") or {}).get("weekly_line") or DEFAULT_TMPL)
    doc = {"users": cur["users"], "mrr": cur["mrr"], "tiers": cur["tiers"],
           "prev_users": prev["users"], "prev_mrr": prev["mrr"],
           "window_days": args.days,
           "churned_sweep_finished_at": (run or {}).get("finished_at"),
           "generated_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")}
    doc["line"] = line_for(doc, tmpl)
    limit_h = float((policy.get("thresholds") or {}).get("risk_max_age_hours", 36))
    finished_at = (run or {}).get("finished_at")
    finished_ts = stages.iso_to_ts(finished_at)
    if finished_at is None:
        doc["warning"] = "no churned sweep has finished; the line reads 0 by construction"
    elif not finished_ts or (now - finished_ts) / 3600.0 > limit_h:
        # the row set is whatever the last churned sweep wrote, so an old finished_at
        # means this line repeats an old week rather than measuring this one
        age_h = (now - finished_ts) / 3600.0 if finished_ts else float("inf")
        doc["churned_sweep_age_hours"] = round(age_h, 2) if finished_ts else None
        doc["warning"] = (f"the churned sweep finished {age_h:.1f}h ago (max {limit_h:.0f}h); "
                          f"the line repeats an old week") if finished_ts else \
                         "the churned sweep finished_at is unreadable; the line repeats an old week"
    elif int((run or {}).get("errors") or 0) > 0:
        # a partial sweep (ClickUp 500 sets tasks=[]) drops tiers, so its count is not
        # the measurement this line exists to publish
        doc["churned_sweep_errors"] = int(run["errors"])
        doc["warning"] = (f"the churned sweep finished with {run['errors']} source error(s) "
                          f"({run.get('note') or 'no detail'}); the line undercounts")
    if doc.get("warning"):
        # the warning rides ON the posted line: stderr only reaches the cron log, and
        # the reader who acts on this number is in Slack, where a stale or partial
        # sweep would otherwise announce an undercount as the week's measurement
        doc["line"] = f"{doc['line']} \u2014 WARNING: {doc['warning']}"
    if args.json:
        print(json.dumps(doc, sort_keys=True))
    else:
        print(doc["line"])
        if doc.get("warning"):
            print(f"weekly_line: {doc['warning']}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
