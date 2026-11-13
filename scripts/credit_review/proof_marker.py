#!/usr/bin/env python3
"""The proof marker: "did they answer?" set from the documents on file.

`verify_messages.proof_tagged_at` is the one column that says a note we sent was answered with a document. Its
only writer was the Intercom tag sweep (`verify_notify.sweep_proofs` -> `intercom-verify-request.sh tag-proof` ->
`verify_ledger.mark_tagged`), which runs only inside `verify-notify --mode apply`. That cron is off, and the
sweep reads one conversation per note, which is not how documents arrive: they are filed into `proof_intake` by
`credit-proof.py file-recent` from every channel. Measured on node-8 2026-11-13: the sweep had never recorded a
look (`proof_checked_at` set on 0 rows) while 565 sent notes had a document on file dated after the note.

This module is the join. It reads `proof_intake` (read-only) and tags a SENT note when:

  * the note has an account id, and that account filed a document dated at or after the note was sent; and
  * a credit note: the document was filed against one of the requests the note names (`candidate_request_ids`).
    One old document must not answer every later ask (proof on file is per request, not per user);
  * a claim note: any document from the account after the note (a claim has no credit request to match).

The marker is the document's own `received_at`: the clock for "we have owed this a look since then".

What it never does: judge a document, approve, send, or write a conversation id or an attachment count (those
belong to the sweep, which reads the note's own conversation). A note with a proof review on file is tagged only
by a document newer than every review, and then its rejected verdicts are cleared exactly as `mark_tagged` does.

Every tag is one `proof_marks` row (note, document, run), so a run can be counted and undone:
`revert --run-id RUN` clears the tags that run set and that nothing has changed since, and marks that document
spent for that note: a later document for the same note still answers it. A note with no account id cannot be
measured and is counted as `unmeasured`, never as "no answer". An unreadable proof store is exit 2 and nothing
is written.

Kill file: /etc/hydra/proof-marker.disabled (exit 0, nothing read or written).
"""
from __future__ import annotations

import argparse
import json
import os
import sqlite3
import sys
from collections import Counter
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from credit_review.verify_ledger import CLAIM_CAMPAIGNS, ledger_open  # noqa: E402

RULE = "pm-1"
LEDGER = os.environ.get("CREDIT_REVIEW_LEDGER", "/var/lib/hydra/credit-review/ledger.sqlite3")
PROOF_STORE = "/var/lib/hydra-credit-verify/proof.sqlite"
KILL = "/etc/hydra/proof-marker.disabled"

# Not part of verify_ledger.SCHEMA on purpose: a table added there makes every read-only reader of the ledger
# refuse until a writer has migrated it (connect_ro). This table is created here, by the only code that reads it.
MARKS = """
CREATE TABLE IF NOT EXISTS proof_marks (
  message_row INTEGER NOT NULL,      -- verify_messages.id of the note that was answered
  intake_id TEXT NOT NULL,           -- proof_intake.intake_id of the first document that answers it
  received_at TEXT NOT NULL,         -- that document's received_at: the value written to proof_tagged_at
  documents INTEGER NOT NULL,        -- how many documents answered the note when it was tagged
  run_id TEXT NOT NULL,
  rule TEXT NOT NULL,
  marked_at TEXT NOT NULL,
  cleared_reviews_json TEXT NOT NULL DEFAULT '[]',   -- rejected verify_proof_reviews rows this tag cleared
  reverted_at TEXT,
  PRIMARY KEY (message_row, intake_id)
);
CREATE INDEX IF NOT EXISTS proof_marks_run ON proof_marks(run_id);
"""


REVIEW_COLS = ("family", "request_id", "outcome", "reason", "document", "reviewed_at", "reviewed_by")


class Unreadable(RuntimeError):
    """The proof store or the ledger could not be read. Never the same thing as 'no documents'."""


def _ts(value: Any) -> datetime | None:
    try:
        d = datetime.fromisoformat(str(value).strip().replace("Z", "+00:00"))
    except (TypeError, ValueError):
        return None
    return d if d.tzinfo else d.replace(tzinfo=timezone.utc)


def _stamp(d: datetime) -> str:
    return d.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _ids(raw: Any) -> set[str]:
    try:
        got = json.loads(raw or "[]")
    except (TypeError, ValueError):
        return set()
    return {str(x).lower() for x in got} if isinstance(got, list) else set()


def _ro(path: str) -> sqlite3.Connection:
    if not Path(path).is_file():
        raise Unreadable(f"{path} does not exist")
    try:
        db = sqlite3.connect(f"file:{path}?mode=ro", uri=True, timeout=30)
    except sqlite3.Error as exc:
        raise Unreadable(f"{path}: {exc}") from exc
    db.row_factory = sqlite3.Row
    return db


def read_documents(store: str) -> tuple[dict[str, list[dict[str, Any]]], int]:
    """({account id: its documents, oldest first}, documents whose date cannot be read)."""
    try:
        with _ro(store) as db:
            rows = db.execute("SELECT intake_id, user_id, received_at, candidate_request_ids_json "
                              "FROM proof_intake").fetchall()
    except sqlite3.Error as exc:
        raise Unreadable(f"proof_intake unreadable: {exc}") from exc
    docs: dict[str, list[dict[str, Any]]] = {}
    undated = 0
    for r in rows:
        at = _ts(r["received_at"])
        if at is None:
            undated += 1
            continue
        docs.setdefault(str(r["user_id"]), []).append(
            {"intake_id": str(r["intake_id"]), "at": at, "requests": _ids(r["candidate_request_ids_json"])})
    for mine in docs.values():
        mine.sort(key=lambda d: (d["at"], d["intake_id"]))
    return docs, undated


def plan(db: sqlite3.Connection, docs: dict[str, list[dict[str, Any]]]) -> tuple[list[dict[str, Any]], Counter]:
    """(the tags to set, counts). Reads only."""
    try:
        rows = db.execute("SELECT id, campaign, account_id, COALESCE(sent_at, created_at) AS asked, parent_row, "
                          "request_ids_json, proof_tagged_at FROM verify_messages WHERE status='sent'").fetchall()
        reviewed = {int(f): _ts(at) for f, at in db.execute(
            "SELECT family, MAX(reviewed_at) FROM verify_proof_reviews GROUP BY family")}
        has_marks = db.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name='proof_marks'").fetchone()
        stands = {(int(m), str(i)) for m, i in db.execute(
            "SELECT message_row, intake_id FROM proof_marks WHERE reverted_at IS NOT NULL")} if has_marks else set()
    except sqlite3.Error as exc:
        raise Unreadable(f"verify ledger unreadable: {exc}") from exc
    n: Counter = Counter()
    todo: list[dict[str, Any]] = []
    for r in rows:
        n["sent"] += 1
        if r["proof_tagged_at"]:
            n["already_tagged"] += 1
            continue
        account, asked = str(r["account_id"] or "").strip(), _ts(r["asked"])
        if not account or asked is None:
            n["unmeasured"] += 1                          # no account id or no send time: not "no answer"
            continue
        after = [d for d in docs.get(account) or [] if d["at"] >= asked]
        if not after:
            n["no_document_after"] += 1
            continue
        claim = str(r["campaign"]) in CLAIM_CAMPAIGNS
        mine = after if claim else [d for d in after if d["requests"] & _ids(r["request_ids_json"])]
        if not mine:
            n["document_for_another_request"] += 1
            continue
        family = int(r["parent_row"] or r["id"])
        last_review = reviewed.get(family)
        if family in reviewed:
            # a reviewed note is answered again only by a document the review has not seen
            mine = [d for d in mine if last_review is not None and d["at"] > last_review]
            if not mine:
                n["reviewed_already"] += 1
                continue
        mine = [d for d in mine if (int(r["id"]), d["intake_id"]) not in stands]
        if not mine:
            n["reverted_stands"] += 1
            continue
        n["to_tag"] += 1
        n["to_tag:" + str(r["campaign"])] += 1
        todo.append({"row": int(r["id"]), "family": family, "intake_id": mine[0]["intake_id"],
                     "at": _stamp(mine[0]["at"]), "documents": len(mine), "reviewed": family in reviewed})
    return todo, n


def apply(db: sqlite3.Connection, todo: list[dict[str, Any]], *, run_id: str, now: datetime) -> int:
    """Set the tags in ONE transaction. A note tagged or changed since the plan is left alone."""
    ts, done = _stamp(now), 0
    db.executescript(MARKS)
    db.execute("BEGIN IMMEDIATE")
    try:
        for t in todo:
            cur = db.execute("UPDATE verify_messages SET proof_tagged_at=?, updated_at=? "
                             "WHERE id=? AND status='sent' AND proof_tagged_at IS NULL", (t["at"], ts, t["row"]))
            if cur.rowcount != 1:
                continue
            cleared: list[dict[str, Any]] = []
            if t["reviewed"]:
                # a new document puts every rejected credit back under review (as verify_ledger.mark_tagged)
                cleared = [dict(zip(REVIEW_COLS, x)) for x in db.execute(
                    f"SELECT {', '.join(REVIEW_COLS)} FROM verify_proof_reviews "
                    "WHERE family=? AND outcome='rejected'", (t["family"],))]
                db.execute("DELETE FROM verify_proof_reviews WHERE family=? AND outcome='rejected'", (t["family"],))
            db.execute("INSERT INTO proof_marks (message_row, intake_id, received_at, documents, run_id, rule, "
                       "marked_at, cleared_reviews_json) VALUES (?,?,?,?,?,?,?,?)",
                       (t["row"], t["intake_id"], t["at"], t["documents"], run_id, RULE, ts, json.dumps(cleared)))
            done += 1
        db.execute("COMMIT")
    except Exception:
        db.execute("ROLLBACK")
        raise
    return done


def revert(db: sqlite3.Connection, *, run_id: str, now: datetime) -> dict[str, int]:
    """Clear the tags `run_id` set. A tag something else has changed since is left and counted."""
    ts, out = _stamp(now), Counter()
    db.executescript(MARKS)
    db.execute("BEGIN IMMEDIATE")
    try:
        marks = db.execute("SELECT * FROM proof_marks WHERE run_id=? AND reverted_at IS NULL", (run_id,)).fetchall()
        for m in marks:
            cur = db.execute("UPDATE verify_messages SET proof_tagged_at=NULL, updated_at=? "
                             "WHERE id=? AND proof_tagged_at=?", (ts, m["message_row"], m["received_at"]))
            if cur.rowcount != 1:
                out["changed_since"] += 1
                continue
            for x in json.loads(m["cleared_reviews_json"] or "[]"):
                db.execute(f"INSERT OR IGNORE INTO verify_proof_reviews ({', '.join(REVIEW_COLS)}) "
                           f"VALUES ({', '.join('?' * len(REVIEW_COLS))})", [x.get(c) for c in REVIEW_COLS])
            db.execute("UPDATE proof_marks SET reverted_at=? WHERE message_row=? AND intake_id=?",
                       (ts, m["message_row"], m["intake_id"]))
            out["reverted"] += 1
        db.execute("COMMIT")
    except Exception:
        db.execute("ROLLBACK")
        raise
    return {"reverted": out["reverted"], "changed_since": out["changed_since"]}


def _rw(path: str) -> sqlite3.Connection:
    if not Path(path).is_file():
        raise Unreadable(f"{path} does not exist (the marker never creates a ledger)")
    db = ledger_open().open_rw(path, opener="credit_review.proof_marker", timeout=30, isolation_level=None)
    db.row_factory = sqlite3.Row
    return db


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    p.add_argument("op", choices=("plan", "apply", "revert"))
    p.add_argument("--ledger", default=LEDGER)
    p.add_argument("--store", default=PROOF_STORE)
    p.add_argument("--kill-file", default=KILL)
    p.add_argument("--run-id", default=None, help="revert: the run to undo")
    a = p.parse_args(argv)
    if Path(a.kill_file).exists():
        print(json.dumps({"op": a.op, "killed": a.kill_file}))
        return 0
    now = datetime.now(timezone.utc)
    try:
        if a.op == "revert":
            if not a.run_id:
                p.error("revert needs --run-id")
            print(json.dumps({"op": "revert", "run_id": a.run_id,
                              **revert(_rw(a.ledger), run_id=a.run_id, now=now)}))
            return 0
        docs, undated = read_documents(a.store)
        db = _rw(a.ledger) if a.op == "apply" else _ro(a.ledger)
        todo, n = plan(db, docs)
        out: dict[str, Any] = {"op": a.op, "rule": RULE, "documents": sum(len(v) for v in docs.values()),
                               "accounts_with_documents": len(docs), "documents_undated": undated,
                               **dict(sorted(n.items()))}
        if a.op == "apply":
            out["run_id"] = "pm-" + now.strftime("%Y%m%dT%H%M%SZ")
            out["tagged"] = apply(db, todo, run_id=out["run_id"], now=now)
        print(json.dumps(out))
        return 0
    except (Unreadable, sqlite3.Error) as exc:
        print(json.dumps({"op": a.op, "error": str(exc)[:300]}))
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
