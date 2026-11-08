#!/usr/bin/env python3
"""churn_returns.py — stage 4: did the win-back work? Returns vs the untouched holdout.

    ./scripts/churn_returns.py --dry-run     # cohort sizes only, no Trino read
    ./scripts/churn_returns.py               # read Trino, write the artifact, print one line
    ./scripts/churn_returns.py --no-write     # measure and print, leave no artifact

The only claim this campaign can make is a comparison: of the churned users this campaign
touched (every routed non-holdout user, fixed or not - the ledger has no confirmed-send receipt),
how many came back - versus the same routed population we deliberately never messaged
(``holdout.modulus/residue``). Both groups are measured the same way, with one statement against
core subscriptions.

The artifact is a file because the weekly churn line reads files
(churn-risk-signal-prevent-p1): ``<state>/returns/<day>.json``. This script posts nothing -
two posters for one number is how a number gets printed twice and believed once.

Exit codes: 0 measured (or rehearsed), 1 no ledger / nothing to measure, 3 Trino unavailable
(``readback.SourceUnreadable``: non-zero exit, a missing wrapper, or the 180s timeout - a source
outage must not be written down as "zero returns").
"""

from __future__ import annotations

import argparse
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from churn import cli, readback, returns, tickets  # noqa: E402


def main(argv: list[str] | None = None) -> int:
    ap = cli.add_common(argparse.ArgumentParser(description="Measure wb_fix_1 returns against the holdout."))
    ap.add_argument("--dry-run", action="store_true", help="show the cohorts; read no subscriptions")
    ap.add_argument("--no-write", action="store_true", help="measure and print; write no artifact")
    args = ap.parse_args(argv)

    policy = cli.load_policy(args.policy)
    state_dir = cli.state_dir(policy, args.state_dir)
    db_path = state_dir / "tickets.sqlite"
    if not db_path.exists():
        cli.log(f"no ledger at {db_path}: nothing has been routed yet, so there is nothing to measure")
        return 1

    now = time.time()
    with tickets.TicketStore(db_path) as store:
        cohort = returns.build_cohort(store, policy=policy)
        if args.dry_run:
            cli.emit({"stage": "returns", "dry_run": True, "intent_to_treat": len(cohort.intent),
                      "holdout": len(cohort.holdout),
                      "holdout_by_tier": {k: len(v) for k, v in sorted(cohort.holdout_by_tier.items())},
                      "holdout_by_lane": {k: len(v) for k, v in sorted(cohort.holdout_by_lane.items())},
                      "note": "no Trino read: a rehearsal never measures returns"})
            return 0
        if not cohort.intent and not cohort.holdout:
            cli.log("no routed users and no holdout members yet: returns are not measurable")
            return 1
        try:
            doc = returns.report(store, policy=policy, run_sql=readback.trino_sql, now=now)
        except readback.SourceUnreadable as exc:
            # A Trino outage is not "zero returns". Writing that down would be the same class of
            # mistake this campaign exists to answer.
            cli.log(f"subscriptions unreadable, so no returns were measured: {exc}")
            return 3

    if not args.no_write:
        doc["path"] = str(returns.write_report(doc, state_dir=state_dir,
                                              day=time.strftime("%Y-%m-%d", time.gmtime(now))))
    cli.log(returns.text(doc))
    cli.emit(doc)
    return 0


if __name__ == "__main__":
    sys.exit(main())
