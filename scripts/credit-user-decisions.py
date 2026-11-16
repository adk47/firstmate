#!/usr/bin/env python3
"""credit-user-decisions: one verdict per PERSON over the held queue, and the proof it equals the per-row answers.

  credit-user-decisions.py snapshot --out rows.json [--court unverified|paid-held]   read the replica (read-only)
  credit-user-decisions.py equivalence --rows rows.json [--per-cohort 10]            per-row vs per-user, row for row
  credit-user-decisions.py plan --rows rows.json [--top 30] [--json]                 the per-person worklist

READ-ONLY. It reads the core replica (snapshot) or a rows file, and writes only the file named by --out. It calls no
admin API, writes no credit status, no ledger row and no message. The rules and the unit they are evaluated in are
scripts/credit_review/user_decision.py; the doc is docs/credit-verification/user-level-decisions.md.

Exit codes (equivalence): 0 every row agrees; 1 at least one row disagrees (a defect in the user-level pass, printed);
2 the input could not be read; 3 the sample is too small to prove anything (fewer than --min-users people).
"""
from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from credit_review import user_decision as ud  # noqa: E402

TRINO = os.environ.get("CREDIT_TRUST_TRINO_CMD", "/opt/hydra/scripts/trino-query.sh")


def _policy(path: str | None):
    from credit_review import decide
    return decide.Policy.load(Path(path) if path else None)


def _rows(path: str) -> list[dict]:
    rows = json.loads(Path(path).read_text(encoding="utf-8"))
    if not isinstance(rows, list) or not all(isinstance(r, dict) for r in rows):
        raise ValueError(f"{path}: expected a JSON list of request rows")
    if not rows:
        raise ValueError(f"{path}: no rows (unmeasured, not an empty queue)")
    return rows


def _measure(label: str, rows: list[dict], policy, repeat: int) -> dict:
    e = ud.equivalence(rows, policy, repeat=repeat)
    return {"scope": label, **ud.summary(rows, policy), "agree": e.agree, "disagreement_count": len(e.disagreements),
            "equivalent": e.equivalent, "ms_per_row_unit": round(e.seconds_per_row * 1000, 2),
            "ms_per_user_unit": round(e.seconds_per_user * 1000, 2), "disagreements": e.disagreements[:50]}


def _line(m: dict) -> str:
    return (f"{m['scope']:<13} rows {m['rows']:>6}  users {m['users']:>5}  agree {m['agree']:>6}  "
            f"disagree {m['disagreement_count']:>3}  walks {m['walks_per_row']:>6} -> {m['walks_per_user']:>5}  "
            f"fallback {m['fallback']:>4}  lines {m['worklist_lines']:>5}  users fully decided "
            f"{m['users_fully_decided']:>4}  rows still per-row {m['rows_per_row']:>5}  "
            f"clock {m['ms_per_row_unit']:.1f} -> {m['ms_per_user_unit']:.1f} ms")


def cmd_snapshot(a) -> int:
    try:
        rows = ud.snapshot(a.trino, a.court, a.timeout)
    except Exception as exc:  # noqa: BLE001 - one line, non-zero: unmeasured is never an empty file
        print(f"snapshot failed: {exc}", file=sys.stderr)
        return 2
    Path(a.out).write_text(json.dumps(rows), encoding="utf-8")
    print(f"{a.court}: {len(rows)} rows / {len({r['userId'] for r in rows if r['userId'] is not None})} users "
          f"-> {a.out}")
    return 0


def cmd_equivalence(a) -> int:
    try:
        rows, policy = _rows(a.rows), _policy(a.policy)
    except Exception as exc:  # noqa: BLE001
        print(f"unreadable input: {exc}", file=sys.stderr)
        return 2
    sample = ud.sample_users(rows, a.per_cohort)
    out = [_measure("SAMPLE", sample, policy, a.repeat), _measure("ALL", rows, policy, a.repeat)]
    out += [_measure(c, members, policy, a.repeat) for c, members in ud.by_cohort(rows).items() if members]
    sample_cohorts = {c: len({r["userId"] for r in m}) for c, m in ud.by_cohort(sample).items() if m}
    if a.json:
        print(json.dumps({"sample_users_by_cohort": sample_cohorts, "measurements": out}, indent=1))
    else:
        print("per-row answer vs per-user answer, row for row (walks = ladder evaluations; clock = best of "
              f"{a.repeat} in-process passes, same rows, same host)")
        for m in out:
            print(_line(m))
        print("sample: every row of the", a.per_cohort, "largest and", a.per_cohort,
              "smallest holders in each cohort; users by cohort:", json.dumps(sample_cohorts))
        for m in out:
            for d in m["disagreements"][:10]:
                print("DISAGREE", m["scope"], json.dumps(d))
    if any(not m["equivalent"] for m in out):
        return 1
    if out[0]["users"] < a.min_users:
        print(f"sample has {out[0]['users']} users, fewer than --min-users {a.min_users}: proves nothing",
              file=sys.stderr)
        return 3
    return 0


def cmd_plan(a) -> int:
    try:
        rows, policy = _rows(a.rows), _policy(a.policy)
    except Exception as exc:  # noqa: BLE001
        print(f"unreadable input: {exc}", file=sys.stderr)
        return 2
    plan = ud.decide_users(rows, policy)
    verdicts = sorted(plan.verdicts, key=lambda v: (-v.rows, v.user_id if v.user_id is not None else -1))
    if a.json:
        print(json.dumps([{"user_id": v.user_id, "rows": v.rows, "cohorts": dict(v.cohorts), "walks": v.walks,
                           "fallback": v.fallback,
                           "answers": [{"rule": g.rule, "decision": g.decision, "reason": g.reason,
                                        "can_still_defer_on": g.live, "request_ids": ids} for g, ids in v.groups]}
                          for v in verdicts], indent=1))
        return 0
    print(json.dumps(ud.summary(rows, policy)))
    for v in verdicts[:a.top]:
        print(f"user {v.user_id}  rows {v.rows}  cohorts {dict(v.cohorts)}"
              + (f"  per-row fallback {len(v.fallback)}" if v.fallback else ""))
        for g, ids in v.groups:
            print(f"    {len(ids):>5} x {g.decision or 'per-row'} [{g.rule}] {g.reason}")
    return 0


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("snapshot")
    s.add_argument("--out", required=True)
    s.add_argument("--court", choices=(ud.COURT_UNVERIFIED, ud.COURT_PAID_HELD), default=ud.COURT_UNVERIFIED)
    s.add_argument("--trino", default=TRINO)
    s.add_argument("--timeout", type=int, default=600)
    s.set_defaults(fn=cmd_snapshot)
    for name, fn in (("equivalence", cmd_equivalence), ("plan", cmd_plan)):
        p = sub.add_parser(name)
        p.add_argument("--rows", required=True, help="JSON list of request rows (snapshot --out)")
        p.add_argument("--policy", help="decider policy JSON (default: the deployed credit-trust-decide.json)")
        p.add_argument("--json", action="store_true")
        p.set_defaults(fn=fn)
        if name == "equivalence":
            p.add_argument("--per-cohort", type=int, default=10)
            p.add_argument("--min-users", type=int, default=50)
            p.add_argument("--repeat", type=int, default=9)
        else:
            p.add_argument("--top", type=int, default=30)
    a = ap.parse_args(argv)
    return a.fn(a)


if __name__ == "__main__":
    sys.exit(main())
