#!/usr/bin/env python3
"""Decisions persisted per minute, measured at the ledger, and a proof row behind every applied conclusion.

Lane verif-1000-per-min-r1, firstmate 017 (2026-11-16 12:02Z): "a sustained run (>= 30 min) measuring decisions
persisted per minute plus a proof row per applied conclusion; report the measured rate."

Read-only. Every store is opened `mode=ro` (never created, never migrated). Output is counts, minutes and ledger row
ids only: no email, no user id, no request id leaves the host.

What it counts, per UTC minute, from three stores (a store, or any table it needs including its proof table, that
cannot be read is reported as `absent` with
its error, never as a zero):

  decide   `decisions` in the credit-review ledger (`decide.py`), by `decided_at`.
           An apply-mode approve (`mode = 'apply'`, `decision IN ('approve', 'approve_partial')`) is a conclusion the
           writer tried to apply; its `decision_outcomes` row (same run and request) is the writer's read-back of
           core. `approved` = an applied conclusion. `skipped:*` / `error:*` = recorded, not applied (core moved
           first, or core's guard refused), counted by reason. NO outcome row at all = an attempt with no proof
           row, the gap --check fails on. An applied conclusion must also name its `evidence_kind`. The evidence of a
           `validator_low_risk` or `precedent` approval is the validator verdict or the precedent request, not a
           catalog, web or proof id column, so those columns are not the proof.
  drain    `applied` in the scale-drain ledger (`scale_drain.py`), by `applied_at`.
           Applied conclusion: an `applied` row whose outcome writes (`approve`, `close_duplicate`).
           Proof: its `intents` row is `confirmed` with resolution `written` or `reconciled` (the read-back of core).
  ask      `verify_messages` in the credit-review ledger finalized `sent` (every sender, or one campaign with
           --campaign), by `sent_at`.
           Applied conclusion: every `sent` row.
           Proof: a provider receipt on the row (`message_id`, or an `api_log` naming `send-gateway:<id>`).

A decision is counted once, in the minute it was persisted. The combined line adds the three sources; they never name
the same row.

  ledger_rate.py --ledger L [--drain D] (--since T --until T | --last-minutes N) [--campaign C]
                 [--target 1000] [--sustain 30] [--check]

--check exits 1 unless some run of --sustain consecutive minutes is at or above --target AND no applied conclusion in
the window lacks its proof row; without it the exit is 0. Exit 2 (BLIND) whenever any required source (`decide`,
`ask`, and `drain` when --drain is given) could not be read, with or without --check: a partial read is never a pass.
"""
from __future__ import annotations

import argparse
import json
import sqlite3
import statistics
import sys
import time
from datetime import datetime, timedelta, timezone
from pathlib import Path

WRITE_DECISIONS = ("approve", "approve_partial")
WRITE_DRAIN_OUTCOMES = ("approve", "close_duplicate")
SAMPLE_IDS = 20


def open_ro(path: str) -> sqlite3.Connection:
    if not Path(path).is_file():
        raise FileNotFoundError(path)
    db = sqlite3.connect(Path(path).resolve().as_uri() + "?mode=ro", uri=True, timeout=30)
    db.execute("PRAGMA query_only = ON")
    return db


def norm(ts: str) -> str:
    """A ledger stamp as `YYYY-MM-DDTHH:MM:SS`, whatever separator or fraction it was written with."""
    return (ts or "").replace(" ", "T")[:19]


def minute(ts: str) -> str:
    return norm(ts)[:16]


def stamp(dt: datetime) -> str:
    return dt.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S")


def has_table(db: sqlite3.Connection, name: str) -> bool:
    return db.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name=?", (name,)).fetchone() is not None


def day_bounds(since: str, until: str) -> tuple[str, str]:
    """A coarse SQL range on the date prefix, which sorts the same for `T`- and space-separated stamps; the exact
    [since, until) cut is made in Python on the normalized stamp."""
    nxt = (datetime.strptime(until[:10], "%Y-%m-%d") + timedelta(days=1)).strftime("%Y-%m-%d")
    return since[:10], nxt


# Every table a source needs, its proof tables included. One that is missing makes the source absent (BLIND), never a
# note beside a count: without `decision_outcomes` or `intents` no applied row can show its proof, so `--check` must
# not be able to pass (QA on #2098 at e4135a000).
REQUIRED_TABLES = {
    "decide": ("decisions", "decision_outcomes"),
    "drain": ("applied", "intents"),
    "ask": ("verify_messages",),
}


def missing_tables(db: sqlite3.Connection, source: str) -> dict | None:
    gone = [t for t in REQUIRED_TABLES[source] if not has_table(db, t)]
    return {"absent": "no table: " + ", ".join(gone)} if gone else None


def read_decide(db: sqlite3.Connection, since: str, until: str) -> dict:
    gone = missing_tables(db, "decide")
    if gone:
        return gone
    rows = db.execute(
        "SELECT d.id, d.decided_at, d.mode, d.decision, COALESCE(d.evidence_kind, ''), "
        "(SELECT CASE WHEN SUM(o.outcome = 'approved') > 0 THEN 'approved' ELSE MIN(substr(o.outcome, 1, 40)) END "
        " FROM decision_outcomes o WHERE o.request_id = d.request_id AND o.run_id = d.run_id) "
        "FROM decisions d WHERE d.decided_at >= ? AND d.decided_at < ?", day_bounds(since, until)).fetchall()
    per, applied, missing, kinds, not_applied = {}, 0, [], {}, {}
    secs: dict[str, set] = {}
    for rid, at, mode, decision, kind, outcome in rows:
        if not (since <= norm(at) < until):
            continue
        m = minute(at)
        per[m] = per.get(m, 0) + 1
        secs.setdefault(m, set()).add(norm(at))
        if mode != "apply" or decision not in WRITE_DECISIONS:
            continue
        if outcome is None:
            missing.append(rid)
        elif outcome == "approved":
            applied += 1
            k = kinds.setdefault(kind or "(none)", {"applied": 0, "without_proof": 0})
            k["applied"] += 1
            if not kind:
                missing.append(rid)
                k["without_proof"] += 1
        else:
            not_applied[outcome] = not_applied.get(outcome, 0) + 1
    out = {"per_minute": per, "stamped_seconds": {k: len(v) for k, v in secs.items()}, "applied": applied, "without_proof": len(missing),
           "without_proof_row_ids": missing[:SAMPLE_IDS], "applied_by_evidence_kind": kinds,
           "attempted_not_applied": not_applied}
    return out


def read_drain(db: sqlite3.Connection, since: str, until: str) -> dict:
    gone = missing_tables(db, "drain")
    if gone:
        return gone
    q = ("SELECT a.rowid, a.applied_at, a.outcome, i.state, i.resolution "
         "FROM applied a LEFT JOIN intents i ON i.decision_key = a.decision_key "
         "WHERE a.applied_at >= ? AND a.applied_at < ?")
    per, applied, missing = {}, 0, []
    secs: dict[str, set] = {}
    for rid, at, outcome, state, resolution in db.execute(q, day_bounds(since, until)):
        if not (since <= norm(at) < until):
            continue
        m = minute(at)
        per[m] = per.get(m, 0) + 1
        secs.setdefault(m, set()).add(norm(at))
        if outcome in WRITE_DRAIN_OUTCOMES:
            applied += 1
            if not (state == "confirmed" and resolution in ("written", "reconciled")):
                missing.append(rid)
    out = {"per_minute": per, "stamped_seconds": {k: len(v) for k, v in secs.items()}, "applied": applied, "without_proof": len(missing),
           "without_proof_row_ids": missing[:SAMPLE_IDS]}
    return out


def read_ask(db: sqlite3.Connection, since: str, until: str, campaign: str) -> dict:
    gone = missing_tables(db, "ask")
    if gone:
        return gone
    q = ("SELECT id, sent_at, COALESCE(message_id,''), COALESCE(api_log,'') FROM verify_messages "
         "WHERE status = 'sent' AND sent_at >= ? AND sent_at < ?" + (" AND campaign = ?" if campaign else ""))
    args = day_bounds(since, until) + ((campaign,) if campaign else ())
    per, applied, missing = {}, 0, []
    secs: dict[str, set] = {}
    for rid, at, message_id, api_log in db.execute(q, args):
        if not (since <= norm(at) < until):
            continue
        m = minute(at)
        per[m] = per.get(m, 0) + 1
        secs.setdefault(m, set()).add(norm(at))
        applied += 1
        if not message_id.strip() and "send-gateway:" not in api_log:
            missing.append(rid)
    return {"per_minute": per, "stamped_seconds": {k: len(v) for k, v in secs.items()}, "applied": applied, "without_proof": len(missing),
            "without_proof_row_ids": missing[:SAMPLE_IDS]}


def minutes_between(since: str, until: str) -> list[str]:
    a = datetime.strptime(since[:16], "%Y-%m-%dT%H:%M").replace(tzinfo=timezone.utc)
    b = datetime.strptime(until[:16], "%Y-%m-%dT%H:%M").replace(tzinfo=timezone.utc)
    out = []
    while a < b:
        out.append(a.strftime("%Y-%m-%dT%H:%M"))
        a += timedelta(minutes=1)
    return out


def summarize(series: list[int], target: int) -> dict:
    run = best = 0
    for v in series:
        run = run + 1 if v >= target else 0
        best = max(best, run)
    return {"minutes": len(series), "total": sum(series),
            "per_minute_min": min(series) if series else 0,
            "per_minute_median": statistics.median(series) if series else 0,
            "per_minute_max": max(series) if series else 0,
            "minutes_at_or_above_target": sum(v >= target for v in series),
            "longest_run_at_or_above_target": best}


def measure(ledger: str, drain: str, since: str, until: str, *, campaign: str = "", target: int = 1000) -> dict:
    t0 = time.monotonic()
    sources: dict[str, dict] = {}
    try:
        ldb = open_ro(ledger)
        sources["decide"] = read_decide(ldb, since, until)
        sources["ask"] = read_ask(ldb, since, until, campaign)
    except (OSError, sqlite3.Error) as e:
        sources["decide"] = sources["ask"] = {"absent": f"{type(e).__name__}: {e}"}
    if drain:
        try:
            sources["drain"] = read_drain(open_ro(drain), since, until)
        except (OSError, sqlite3.Error) as e:
            sources["drain"] = {"absent": f"{type(e).__name__}: {e}"}
    mins = minutes_between(since, until)
    combined = [sum(s.get("per_minute", {}).get(m, 0) for s in sources.values()) for m in mins]
    stamped = [sum(s.get("stamped_seconds", {}).get(m, 0) for s in sources.values()) for m in mins]
    return {
        "window": {"since": since, "until": until, "minutes": len(mins)},
        "target_per_minute": target,
        "sources": {k: dict(v, summary=summarize([v.get("per_minute", {}).get(m, 0) for m in mins], target))
                    if "absent" not in v else v for k, v in sources.items()},
        # A minute at the target whose rows carry a handful of distinct stamps is one batch write, not a rate.
        "combined": dict(summarize(combined, target), per_minute=dict(zip(mins, combined)),
                         stamped_seconds=dict(zip(mins, stamped)),
                         minutes_at_target_stamped_in_under_10_seconds=sum(
                             c >= target and n < 10 for c, n in zip(combined, stamped))),
        "applied": sum(s.get("applied", 0) for s in sources.values()),
        "applied_without_proof": sum(s.get("without_proof", 0) for s in sources.values()),
        "absent": sorted(k for k, v in sources.items() if "absent" in v),
        "read_seconds": round(time.monotonic() - t0, 3),
    }


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    p.add_argument("--ledger", required=True)
    p.add_argument("--drain", default="")
    p.add_argument("--since", default="")
    p.add_argument("--until", default="")
    p.add_argument("--last-minutes", type=int, default=0)
    p.add_argument("--campaign", default="")
    p.add_argument("--target", type=int, default=1000)
    p.add_argument("--sustain", type=int, default=30)
    p.add_argument("--check", action="store_true")
    a = p.parse_args(argv)
    if a.last_minutes:
        end = datetime.now(timezone.utc).replace(second=0, microsecond=0)
        since, until = stamp(end - timedelta(minutes=a.last_minutes)), stamp(end)
    elif a.since and a.until:
        since, until = norm(a.since), norm(a.until)
    else:
        p.error("give --since and --until, or --last-minutes")
    out = measure(a.ledger, a.drain, since, until, campaign=a.campaign, target=a.target)
    out["sustain_minutes"] = a.sustain
    out["sustained"] = out["combined"]["longest_run_at_or_above_target"] >= a.sustain
    print(json.dumps(out, indent=1, sort_keys=True))
    # Every required source must be read: the ledger's `decide` and `ask`, and `drain` when --drain names it. A store
    # that could not be read is BLIND, never a pass and never a zero, whether one source or all of them.
    if out["absent"]:
        print(f"BLIND: not read: {', '.join(out['absent'])}", file=sys.stderr)
        return 2
    if a.check and not (out["sustained"] and out["applied_without_proof"] == 0):
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
