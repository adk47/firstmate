#!/usr/bin/env python3
"""Profile-merge verifier (SHADOW): one verdict per open merge request, with the evidence and the
exact command a human or the self-serve path would run. It never runs that command, never merges,
unmerges, settles a ledger row, tags a ticket or messages anyone. Its only write is its own audit
store. Doc: docs/credit-verification/merge-verify.md. Tests: scripts/tests/test_merge_verify.py.

  merge-verify.py run [--limit N] [--store PATH] [--eval-log PATH] [--json]   live read (node-8, gateway env)
  merge-verify.py replay [--set PATH | --measure DIR --states MD] [--eval-log PATH] [--json]
  merge-verify.py summary [--store PATH]

Kill switch: /etc/hydra/merge-verify.disabled (or MERGE_VERIFY_DISABLED_FILE) - `run` exits 0 and
reads nothing. Exit codes: 0 ok / disabled; 1 usage; 2 a read failed for every ticket.
"""
from __future__ import annotations

import argparse
import collections
import json
import os
import sys
import time
import uuid
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

from merge_verify import eval_log, rules, snapshot  # noqa: E402

KILL = "/etc/hydra/merge-verify.disabled"


def _summary(judged: list) -> dict:
    tickets = collections.Counter(v.verdict for _, v in judged)
    dups = collections.Counter(lv.verdict for _, v in judged for lv in v.losers)
    m1 = collections.Counter(v.m1_state for _, v in judged)
    return {"tickets": len(judged), "ticket_verdicts": dict(tickets.most_common()),
            "duplicate_verdicts": dict(dups.most_common()), "m1_states": dict(m1.most_common()),
            "eligible_commands": sum(1 for _, v in judged for lv in v.losers if lv.command)}


def _print(judged: list, as_json: bool) -> None:
    if as_json:
        print(json.dumps({"summary": _summary(judged), "verdicts": [v.to_dict() for _, v in judged]}, indent=1))
        return
    s = _summary(judged)
    print(f"merge-verify {rules.RULE_VERSION}: {s['tickets']} open tickets")
    for k, n in s["ticket_verdicts"].items():
        print(f"  {k:40s} {n}")
    print("duplicates (stage 8):")
    for k, n in s["duplicate_verdicts"].items():
        print(f"  {k:40s} {n}")
    for _, v in judged:
        for lv in v.losers:
            if lv.command:
                print(f"\n{v.ticket} {v.keep[:8]} <- {lv.loser[:8]} ({lv.basis}; fresh_read={v.fresh_read})\n  {lv.command}")


def cmd_run(a: argparse.Namespace) -> int:
    kill = os.environ.get("MERGE_VERIFY_DISABLED_FILE", KILL)
    if os.path.exists(kill):
        print(f"merge-verify: disabled ({kill})")
        return 0
    from credit_review import admin as admin_mod, fraud_lens, verify_notify, watchlist  # noqa: PLC0415
    from merge_verify import collect, store  # noqa: PLC0415
    cu, ic = collect.env_clients()
    started = time.time()
    facts = collect.collect(cu=cu, admin=admin_mod.AdminClient(), query=verify_notify.trino, ic=ic,
                            watchlist=watchlist.load(), holds=fraud_lens.load_holds(), list_id=a.list_id, limit=a.limit)
    judged = [(f, rules.decide(f, fresh=bool((f.get("read") or {}).get("fresh")))) for f in facts]
    run_id = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime(started)) + "-" + uuid.uuid4().hex[:6]
    n = store.Store(a.store).record(run_id, "live", started, judged, _summary(judged))
    if a.eval_log:
        eval_log.write(a.eval_log, judged)
    _print(judged, a.json)
    print(f"\nrun {run_id}: {n} audit rows -> {a.store or store.DEFAULT}", file=sys.stderr)
    return 2 if judged and all(v.verdict == "unknown" for _, v in judged) else 0


def cmd_replay(a: argparse.Namespace) -> int:
    if a.measure:
        facts = snapshot.build(a.measure, a.states)
    else:
        facts = snapshot.load_set(Path(a.set) if a.set else snapshot.SET_PATH)
    judged = [(f, rules.decide(f, fresh=False)) for f in facts]
    if a.write_set:
        snapshot.write_set(facts, Path(a.write_set))
    if a.eval_log:
        eval_log.write(a.eval_log, judged)
    if a.agreement:
        dis = [(f["ticket"], f.get("m1_state"), v.m1_state, v.verdict, v.reasons) for f, v in judged
               if f.get("m1_state") and f["m1_state"] != v.m1_state]
        have = sum(1 for f, _ in judged if f.get("m1_state"))
        print(f"agreement with m1 merge-states-1028: {have - len(dis)}/{have}")
        for d in dis:
            print("  disagree", *d)
    _print(judged, a.json)
    return 0


def cmd_summary(a: argparse.Namespace) -> int:
    from merge_verify import store  # noqa: PLC0415
    rows = store.Store(a.store).latest()
    c = collections.Counter((r["ticket_verdict"], r["verdict"]) for r in rows)
    for (t, d), n in c.most_common():
        print(f"{n:5d}  ticket {t:35s} duplicate {d}")
    return 0


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)
    r = sub.add_parser("run")
    r.add_argument("--limit", type=int)
    r.add_argument("--list-id", default="901000600160")
    r.add_argument("--store")
    r.add_argument("--eval-log")
    r.add_argument("--json", action="store_true")
    r.set_defaults(fn=cmd_run)
    rp = sub.add_parser("replay")
    rp.add_argument("--set")
    rp.add_argument("--measure")
    rp.add_argument("--states")
    rp.add_argument("--write-set")
    rp.add_argument("--eval-log")
    rp.add_argument("--agreement", action="store_true")
    rp.add_argument("--json", action="store_true")
    rp.set_defaults(fn=cmd_replay)
    s = sub.add_parser("summary")
    s.add_argument("--store")
    s.set_defaults(fn=cmd_summary)
    a = p.parse_args(argv)
    return a.fn(a)


if __name__ == "__main__":
    sys.exit(main())
