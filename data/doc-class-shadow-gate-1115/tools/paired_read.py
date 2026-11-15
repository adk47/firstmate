#!/usr/bin/env python3
"""Order #7 (captain 2026-11-15): the doc_class shadow gate, read-only.

    false-approve rate of doc_class where both outcomes exist,
    threshold <= 1% on >= 200 paired decisions, fixed BEFORE the read.

The rule this file applies is written in `../report.md` section "Fixed before the read" and
was committed before this file was ever run on node-8; the worker-added approvals minimum was
removed after the read, on review, and the file was not run again. `THRESHOLD` and `MIN_PAIRS`
below are that rule; nothing in this file takes them from a flag, an env var or the data.

Run (nothing is copied to node-8; the file is piped to the interpreter):

    ssh root@<node-8> 'PYTHONDONTWRITEBYTECODE=1 nice -n 10 python3 -' < paired_read.py > read.json

What it reads, and that it only reads:

  * the decider's ledger, opened `mode=ro` with `PRAGMA query_only=ON`;
  * core's replica, ONE `SELECT id, status` through `/opt/hydra/scripts/trino-query.sh`.

It prints counts only: no request id, user id or document id reaches stdout.
"""
from __future__ import annotations

import csv
import datetime as dt
import io
import json
import os
import sqlite3
import subprocess
import sys

# ---- the rule, fixed before the read (report.md "Fixed before the read") -------------------
THRESHOLD = 0.01          # false-approve rate must be <= 1%
MIN_PAIRS = 200           # on >= 200 paired decisions
# ---------------------------------------------------------------------------------------------

HYDRA = "/opt/hydra"
LEDGER = "/var/lib/hydra/credit-review/ledger.sqlite3"
TRINO = f"{HYDRA}/scripts/trino-query.sh"
DOC_KIND = "doc_verified"
APPROVE_EVENTS = ("would_approve", "approved")     # doc_approve.approve(): shadow / apply
REFUSE_EVENTS = ("refused",)
# decide.py records a document-backed verdict as `approve` or `approve_partial` (PARTIAL, R90).
APPROVE_DECISIONS = ("approve", "approve_partial")
REAL = {"approved": "approved", "rejected": "rejected"}
DECIDED_SQL = (
    "SELECT CAST(id AS varchar), status FROM postgresql_core.public.credit_requests"
    " WHERE status IN ('approved', 'rejected') AND deletedat IS NULL"
)

sys.dont_write_bytecode = True
# the deployed modules log to the production run.log on some error paths; a read must not.
os.environ["CREDIT_REVIEW_LOG"] = "/tmp/doc-class-shadow-gate-1115.read.log"


def now() -> str:
    return dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def ro(path: str) -> sqlite3.Connection:
    if not os.path.exists(path):
        raise SystemExit(f"unreadable: {path} does not exist (a read never creates it)")
    c = sqlite3.connect(f"file:{path}?mode=ro", uri=True, timeout=60)
    c.execute("PRAGMA query_only=ON")
    return c


def tables(db: sqlite3.Connection) -> set[str]:
    return {r[0] for r in db.execute("SELECT name FROM sqlite_master WHERE type='table'")}


def recorded_verdicts(db: sqlite3.Connection) -> tuple[dict[str, str], dict]:
    """request id -> 'approve' | 'refuse', from every place doc_class records a verdict.

    A request doc_class EVER recorded an approve for is an approve (the conservative direction:
    it can only add approve verdicts, so it can only add false approves).
    """
    have = tables(db)
    facts: dict = {"tables_present": {}, "rows": {}}
    approve: set[str] = set()
    refuse: set[str] = set()
    for t in ("doc_approval_events", "doc_approvals", "doc_approval_audit"):
        facts["tables_present"][t] = t in have
    if "doc_approval_events" in have:
        by_state: dict[str, int] = {}
        for rid, state in db.execute("SELECT request_id, state FROM doc_approval_events"):
            by_state[state] = by_state.get(state, 0) + 1
            rid = str(rid).lower()
            if state in APPROVE_EVENTS:
                approve.add(rid)
            elif state in REFUSE_EVENTS:
                refuse.add(rid)
        facts["rows"]["doc_approval_events_by_state"] = by_state
    for t in ("doc_approvals", "doc_approval_audit"):
        if t in have:
            n = 0
            for (rid,) in db.execute(f"SELECT request_id FROM {t}"):
                approve.add(str(rid).lower())
                n += 1
            facts["rows"][t] = n
    kinds: dict[str, int] = {}
    for kind, decision, mode, n in db.execute(
            "SELECT evidence_kind, decision, mode, COUNT(*) FROM decisions"
            " WHERE evidence_kind = ? OR lower(evidence_kind) LIKE 'doc%' OR lower(evidence_kind) LIKE 'dv%'"
            " GROUP BY 1, 2, 3", (DOC_KIND,)):
        kinds[f"{kind}/{decision}/{mode}"] = n
    facts["rows"]["decisions_doc_kinds"] = kinds
    for rid, decision in db.execute(
            "SELECT request_id, decision FROM decisions WHERE evidence_kind = ?", (DOC_KIND,)):
        if decision not in APPROVE_DECISIONS:
            # Fail closed: an unrecognised decision is not a refusal, and counting it as one
            # would shrink the false-approve rate. Stop instead of answering on a guess.
            raise SystemExit(
                f"unreadable: a {DOC_KIND} decision row has unknown decision {decision!r}")
        approve.add(str(rid).lower())
    out = {rid: "refuse" for rid in refuse}
    out.update({rid: "approve" for rid in approve})
    facts["requests_with_recorded_verdict"] = len(out)
    facts["recorded_approve"] = len(approve)
    facts["recorded_refuse_only"] = len(out) - len(approve)
    return out, facts


def real_outcomes() -> dict[str, str]:
    """request id -> approved | rejected, from core's replica. One statement, read whole."""
    p = subprocess.run([TRINO], input=DECIDED_SQL, capture_output=True, text=True, timeout=900, check=False)
    if p.returncode != 0:
        raise SystemExit(f"unreadable: core replica read failed rc={p.returncode}: {p.stderr.strip()[:300]}")
    out: dict[str, str] = {}
    for row in csv.reader(io.StringIO(p.stdout)):
        if len(row) == 2 and row[1] in REAL:
            out[row[0].strip().lower()] = REAL[row[1]]
    if not out:
        raise SystemExit("unreadable: core replica returned no decided request (an empty answer is not a zero)")
    return out


def rate(n: int, d: int):
    return None if d == 0 else n / d


def verdict(pairs: int, false_approves: int) -> tuple[str, str]:
    """The rule of report.md "Fixed before the read", and nothing else."""
    if pairs < MIN_PAIRS:
        return "NOT MEASURED", f"{pairs} paired decision(s): fewer than {MIN_PAIRS}"
    r = rate(false_approves, pairs)
    if r > THRESHOLD:
        return "CANNOT", f"{false_approves}/{pairs} paired decisions are false approves, over {THRESHOLD:.0%}"
    return "PASS", f"{false_approves}/{pairs} paired decisions are false approves, <= {THRESHOLD:.0%}"


def main() -> int:
    out: dict = {"order": "#7 doc_class shadow gate", "read_started_at": now(),
                 "threshold": THRESHOLD, "min_pairs": MIN_PAIRS, "ledger": LEDGER}
    try:
        out["deployed_sha"] = open(f"{HYDRA}/.deployed-sha", encoding="utf-8").read().strip()
    except OSError as exc:
        out["deployed_sha"] = f"unread ({exc})"
    try:
        reg = json.load(open(f"{HYDRA}/policies/credit-approval-automation.json", encoding="utf-8"))
        a = reg["automations"]["document_small_track"]
        out["live_policy"] = {"approved": a.get("approved"), "approved_by": a.get("approved_by"),
                              "doc_class.shadow": a.get("doc_class", {}).get("shadow"),
                              "verdict_version": a.get("doc_class", {}).get("verdict_version")}
    except (OSError, ValueError, KeyError) as exc:
        out["live_policy"] = f"unread ({exc})"
    db = ro(LEDGER)
    try:
        recorded, facts = recorded_verdicts(db)
        out["recorded"] = facts
        real = real_outcomes()
        out["core_decided_requests"] = {"approved": sum(1 for v in real.values() if v == "approved"),
                                        "rejected": sum(1 for v in real.values() if v == "rejected")}
        pairs = {rid: (v, real[rid]) for rid, v in recorded.items() if rid in real}
        approve_pairs = sum(1 for v, _ in pairs.values() if v == "approve")
        false_approves = sum(1 for v, r in pairs.values() if v == "approve" and r == "rejected")
        word, why = verdict(len(pairs), false_approves)
        out["gate"] = {
            "paired_decisions": len(pairs),
            "paired_doc_class_approve": approve_pairs,
            "paired_doc_class_refuse": len(pairs) - approve_pairs,
            "false_approves": false_approves,
            "false_approve_rate_of_paired_decisions": rate(false_approves, len(pairs)),
            "verdict": word, "why": why}
    finally:
        db.close()
    out["read_finished_at"] = now()
    print(json.dumps(out, indent=1, sort_keys=False, default=str))
    return 0


if __name__ == "__main__":
    sys.exit(main())
