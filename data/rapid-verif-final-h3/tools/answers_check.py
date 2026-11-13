#!/usr/bin/env python3
"""Read-only check of "did they answer" against a second source (rapid-verif-final-h3, task 3).

    PYTHONPATH=/opt/hydra/scripts python3 answers_check.py plan      # asks a document on file followed, untagged
    PYTHONPATH=/opt/hydra/scripts python3 answers_check.py report --since 2026-11-07

IT WRITES NOTHING. The ledger is opened mode=ro and there is no apply. The marker that writes
`verify_messages.proof_tagged_at` is lane proof-processing-ovh-e1's `credit_review/proof_marker.py` (rule pm-1),
which reads `proof_intake` and requires a credit note's document to name one of the note's requests. This tool is
NOT a second marker and must not become one: it exists to measure the marker from outside, on a different source
(`/var/lib/credit-trust/proof-on-file.json`) and a looser rule (the same ACCOUNT filed a document after the send,
inside WINDOW_DAYS), so the difference between the two is a number instead of an argument.

`plan` counts sent ask rows that are untagged and that an account-level document followed. `report` reads the
ledger alone: per send day and campaign, asks that resolve to an account, those tagged with a stamp dated after
the send, and the lag. A stamp that predates its send is counted apart and is never an answer.

A row with no account id takes its parent's, else the ONE account every other ledger row with the same user_key
carries (two is `account_ambiguous`, none is `account_unresolved`; neither is guessed).

An evidence file that is missing, stale or half-written is exit 1: "could not read" is never "nobody answered".
"""
from __future__ import annotations

import hashlib
import json
import os
import sqlite3
import statistics
from collections import Counter, defaultdict
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any

from credit_review import proof_parts, verify_ledger  # the DEPLOYED modules

LEDGER = "/var/lib/hydra/credit-review/ledger.sqlite3"
EVIDENCE = "/var/lib/credit-trust/proof-on-file.json"

EVIDENCE_MAX_AGE_H = 3      # the same age verify_notify.PROOF_MAX_AGE_H gives the list before an ask may read it
EVIDENCE_MAX_SKEW_H = 0.1
WINDOW_DAYS = 45            # verify_ledger.awaiting_proof's window: how long after an ask a document is its answer

# A row that ASKS for a document. first-ask-1 and reminder-1 are the 9 November one-off drivers' campaigns: they are
# in the ledger (1,087 sent rows) and in no constant of this tree. A receipt, a status line, a loop close, a refund
# note and every claim family are not asks for credit proof and are counted as `not_an_ask`, never linked.
ASK_CAMPAIGNS = tuple(sorted(set(verify_ledger.ASK_CAMPAIGNS) | {"first-ask-1", "reminder-1"}))

class EvidenceError(RuntimeError):
    """The proof-on-file list cannot be read as authoritative: nothing is linked."""


class LedgerError(RuntimeError):
    """The verify ledger cannot be read: nothing is linked."""


def utcnow() -> datetime:
    return datetime.now(timezone.utc)


def parse_time(value: Any) -> datetime | None:
    """A ledger or evidence time as an aware UTC datetime, or None. The ledger holds two spellings of a send time
    ('2026-11-13T10:51:42Z' from the gate, '2026-11-09 13:04:15' from the one-off drivers); an epoch integer or
    anything else is None, and a row or a document with no readable time is counted and never linked."""
    if not isinstance(value, str) or len(value) < 19 or not value[:4].isdigit():
        return None
    try:
        ts = datetime.fromisoformat(value.strip().replace(" ", "T", 1).replace("Z", "+00:00"))
    except ValueError:
        return None
    return (ts if ts.tzinfo else ts.replace(tzinfo=timezone.utc)).astimezone(timezone.utc)


def _ids(raw: Any) -> frozenset[str]:
    try:
        got = json.loads(raw or "[]")
    except (TypeError, ValueError):
        return frozenset()
    return frozenset(str(x).strip().lower() for x in got) if isinstance(got, list) else frozenset()


def load_evidence(path: str = EVIDENCE, *, now: datetime | None = None,
                  max_age_h: float = EVIDENCE_MAX_AGE_H) -> dict[str, Any]:
    """{generated_at, sha256, by_account: {account: [(proof_at, request_id|'', source, kind, ref)] oldest first},
    undated}. Raises EvidenceError unless the file passes the one completeness rule every reader of it uses
    (credit_review/proof_parts.py): present, fresh, every required part usable, every entry well-formed."""
    now = now or utcnow()
    try:
        raw = Path(path).read_bytes()
        doc = json.loads(raw)
    except FileNotFoundError as exc:
        raise EvidenceError(f"the proof-on-file list {path} is missing") from exc
    except (OSError, ValueError) as exc:
        raise EvidenceError(f"the proof-on-file list {path} is unreadable ({type(exc).__name__})") from exc
    if not isinstance(doc, dict):
        raise EvidenceError(f"the proof-on-file list {path} is not an object")
    gen = proof_parts.parse_ts(doc.get("generated_at"))
    if gen is None:
        raise EvidenceError(f"the proof-on-file list {path} has no readable generated_at")
    age_h = (now - gen).total_seconds() / 3600
    if age_h < -EVIDENCE_MAX_SKEW_H or age_h > max_age_h:
        raise EvidenceError(f"the proof-on-file list {path} is {age_h:.1f}h old (limit {max_age_h:g}h)")
    try:
        proof_parts.check(doc, now=now, max_age_h=max_age_h, max_skew_h=EVIDENCE_MAX_SKEW_H)
        proof_parts.check_entries(doc)
    except proof_parts.PartsError as exc:
        raise EvidenceError(f"the proof-on-file list {path}: {exc}") from exc
    by_account: dict[str, list[tuple[datetime, str, str, str, str]]] = defaultdict(list)
    undated = 0
    for e in doc["entries"]:
        at = parse_time(e.get("proof_at"))
        if at is None or at > now + timedelta(hours=EVIDENCE_MAX_SKEW_H):
            undated += 1            # no time, or a time in the future: it cannot be placed after a send
            continue
        by_account[str(e["user_id"]).strip()].append(
            (at, str(e.get("request_id") or "").strip().lower(), str(e.get("source") or ""), str(e["kind"]),
             str(e.get("ref") or "")))
    for docs in by_account.values():
        docs.sort()
    return {"generated_at": verify_ledger.stamp(gen), "sha256": hashlib.sha256(raw).hexdigest(),
            "by_account": dict(by_account), "undated": undated, "entries": len(doc["entries"])}


def open_ledger(path: str = LEDGER) -> sqlite3.Connection:
    """The ledger as it is: never created, never migrated. A missing file or a missing column is LedgerError."""
    if not os.path.isfile(path):
        raise LedgerError(f"the verify ledger {path} is missing")
    try:
        db = sqlite3.connect(f"file:{path}?mode=ro", uri=True, timeout=30,
                             isolation_level=None)
        db.row_factory = sqlite3.Row
        have = {str(r[1]) for r in db.execute("PRAGMA table_info(verify_messages)").fetchall()}
    except sqlite3.Error as exc:
        raise LedgerError(f"the verify ledger {path} is unreadable ({exc})") from exc
    need = {"id", "campaign", "kind", "status", "parent_row", "user_key", "account_id", "request_ids_json",
            "sent_at", "created_at", "proof_tagged_at", "updated_at"}
    if need - have:
        raise LedgerError(f"the verify ledger {path} lacks {sorted(need - have)}")
    return db


def read_rows(db: sqlite3.Connection) -> tuple[list[dict[str, Any]], Counter]:
    """Every SENT row with the account it resolves to. Counts say what was left out and why."""
    counts: Counter = Counter()
    rows = db.execute("SELECT id, campaign, kind, status, parent_row, user_key, account_id, request_ids_json, "
                      "coalesce(sent_at, created_at) AS at, proof_tagged_at FROM verify_messages ORDER BY id").fetchall()
    own = {int(r["id"]): str(r["account_id"] or "").strip() for r in rows}
    by_key: dict[str, set[str]] = defaultdict(set)
    for r in rows:
        key, acct = str(r["user_key"] or "").strip().lower(), own[int(r["id"])]
        if key and acct:
            by_key[key].add(acct)
    out = []
    for r in rows:
        if r["status"] != "sent":
            continue
        counts["sent"] += 1
        if r["campaign"] not in ASK_CAMPAIGNS:
            counts["not_an_ask"] += 1
            continue
        counts["asks"] += 1
        rid = int(r["id"])
        acct, how = own[rid], "row"
        if not acct and r["parent_row"] is not None:
            acct, how = own.get(int(r["parent_row"]), ""), "parent"
        if not acct:
            same = by_key.get(str(r["user_key"] or "").strip().lower(), set())
            if len(same) > 1:
                counts["account_ambiguous"] += 1
                continue
            acct, how = (next(iter(same)), "user_key") if same else ("", "")
        if not acct:
            counts["account_unresolved"] += 1
            continue
        counts[f"account_by_{how}"] += 1
        at = parse_time(r["at"])
        if at is None:
            counts["send_time_unreadable"] += 1
            continue
        out.append({"id": rid, "campaign": str(r["campaign"]), "kind": str(r["kind"] or ""), "account": acct,
                    "root": int(r["parent_row"] or rid), "at": at, "ids": _ids(r["request_ids_json"]),
                    "tagged": r["proof_tagged_at"]})
    return out, counts


def plan(rows: list[dict[str, Any]], evidence: dict[str, Any], *, window_days: int = WINDOW_DAYS,
         now: datetime | None = None) -> tuple[list[dict[str, Any]], Counter]:
    """The stamps to write, oldest document first. Pure: the same rows and the same evidence give the same plan."""
    now = now or utcnow()
    counts: Counter = Counter()
    window = timedelta(days=window_days)
    by_account: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for r in rows:
        by_account[r["account"]].append(r)
    links: dict[int, dict[str, Any]] = {}
    for acct, asks in sorted(by_account.items()):
        docs = evidence["by_account"].get(acct)
        if not docs:
            counts["rows_no_document_on_file"] += len(asks)
            continue
        asks.sort(key=lambda r: (r["at"], r["id"]))
        hit: set[int] = set()
        for at, request_id, source, kind, ref in docs:
            before = [r for r in asks if r["at"] < at <= r["at"] + window]
            if not before:
                continue
            named = [r for r in before if request_id and request_id in r["ids"]]
            target = (named or before)[-1]
            how = "request" if named else "account"
            for r in [target] + [x for x in before if x["root"] == target["root"] and x["id"] != target["id"]]:
                hit.add(r["id"])
                if r["tagged"] or r["id"] in links:
                    continue        # the first document that answers a row is the one recorded; never overwritten
                links[r["id"]] = {"row_id": r["id"], "account_id": acct, "campaign": r["campaign"],
                                  "sent_at": verify_ledger.stamp(r["at"]), "stamp": verify_ledger.stamp(at),
                                  "match": how if r["id"] == target["id"] else "family", "source": source,
                                  "kind": kind, "ref": ref, "request_id": request_id}
        counts["rows_document_only_before_send_or_past_window"] += sum(1 for r in asks if r["id"] not in hit)
    counts["rows_already_tagged"] = sum(1 for r in rows if r["tagged"])
    out = sorted(links.values(), key=lambda x: (x["stamp"], x["row_id"]))
    for x in out:
        counts[f"link_{x['match']}"] += 1
    counts["to_link"] = len(out)
    return out, counts


def report(*, ledger: str = LEDGER, since: str = "", now: datetime | None = None) -> dict[str, Any]:
    """Did they answer, from the ledger alone: per send day and campaign, the asks sent, how many resolve to an
    account (an unkeyed row can never show an answer), how many carry a stamp dated after the send, and the lag.
    A stamp that predates its send is counted apart and is never an answer."""
    now = now or utcnow()
    try:
        db = open_ledger(ledger)
    except LedgerError as exc:
        return {"rc": 1, "result": "unmeasured", "error": str(exc)}
    try:
        rows, counts = read_rows(db)
    finally:
        db.close()
    cells: dict[tuple[str, str], dict[str, Any]] = {}
    for r in rows:
        day = r["at"].strftime("%Y-%m-%d")
        if since and day < since:
            continue
        c = cells.setdefault((day, r["campaign"]), {"keyed": 0, "answered": 0, "stamp_predates_send": 0, "lag_h": []})
        c["keyed"] += 1
        tagged = parse_time(r["tagged"]) if r["tagged"] else None
        if r["tagged"] and (tagged is None or tagged <= r["at"]):
            c["stamp_predates_send"] += 1
        elif tagged is not None:
            c["answered"] += 1
            c["lag_h"].append((tagged - r["at"]).total_seconds() / 3600)
    out = []
    for (day, campaign), c in sorted(cells.items()):
        lag = sorted(c.pop("lag_h"))
        out.append({"day": day, "campaign": campaign, **c,
                    "answered_pct": round(100 * c["answered"] / c["keyed"], 1) if c["keyed"] else None,
                    "lag_h_p50": round(statistics.median(lag), 1) if lag else None,
                    "lag_h_max": round(lag[-1], 1) if lag else None})
    total_keyed = sum(c["keyed"] for c in out)
    return {"rc": 0, "result": "report", "at": verify_ledger.stamp(now), "since": since,
            "ledger_counts": dict(sorted(counts.items())), "keyed": total_keyed,
            "answered": sum(c["answered"] for c in out),
            "stamp_predates_send": sum(c["stamp_predates_send"] for c in out), "cells": out}


def main() -> int:
    import argparse
    import sys
    ap = argparse.ArgumentParser()
    ap.add_argument("mode", choices=("plan", "report"))
    ap.add_argument("--ledger", default=LEDGER)
    ap.add_argument("--evidence", default=EVIDENCE)
    ap.add_argument("--since", default="")
    a = ap.parse_args()
    if a.mode == "report":
        out = report(ledger=a.ledger, since=a.since)
    else:
        now = utcnow()
        try:
            ev = load_evidence(a.evidence, now=now)
            db = open_ledger(a.ledger)
        except (EvidenceError, LedgerError) as exc:
            out = {"rc": 1, "result": "unmeasured", "error": str(exc)}
        else:
            try:
                rows, counts = read_rows(db)
            finally:
                db.close()
            todo, pc = plan(rows, ev, now=now)
            counts.update(pc)
            out = {"rc": 0, "result": "planned", "at": verify_ledger.stamp(now),
                   "evidence_generated_at": ev["generated_at"], "evidence_entries": ev["entries"],
                   "evidence_undated": ev["undated"], "counts": dict(sorted(counts.items())),
                   "untagged_by_campaign": dict(sorted(Counter(x["campaign"] for x in todo).items())),
                   "untagged_by_match": dict(sorted(Counter(x["match"] for x in todo).items()))}
    json.dump(out, sys.stdout, indent=1, sort_keys=True)
    print()
    return int(out.get("rc", 1))


if __name__ == "__main__":
    raise SystemExit(main())
