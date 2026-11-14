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

A tag does what `verify_ledger.mark_tagged` does, in the same transaction (rule pm-2):

  * the FAMILY is tagged: the note's initial note and every follow-up of it that has no tag yet, so no sibling
    keeps getting a follow-up;
  * `proof_attachments` on the note is set to the number of documents that answer it;
  * the rejected verdicts are cleared for every family `verify_ledger.proof_families` names: the note's own and
    the note of every credit it covers. A note names credits first asked about on other notes, and a credit's
    rejected verdict lives under its own note, so clearing the first note alone left them rejected and
    removal-due after the customer sent the document.

A note is tagged only by a document no review has seen: a review suppresses the tag for the credits it was
recorded against (its own `request_id`, under that credit's own note), never for another credit's document, and
never across families. A claim note has no credit to compare, so its own family is the unit. A review whose time
cannot be read blocks the credit it belongs to.

The one field of `mark_tagged` it does not write is `conversation_id`. On a note that column is the thread the
NOTE was sent in (empty = sent by email): `nothing_needed_overlap` reads it to decide where a correction goes,
and `tag-proof` reads that thread for the customer's reply. The marker knows the DOCUMENT's conversation, which
is another thread for a note sent by email. It stays in `proof_intake`, reachable through `proof_marks.intake_id`.

What it never does: judge a document, approve, or send.

Every tag is one `proof_marks` row (note, document, run, the sibling rows it tagged, the verdicts it cleared, the
attachment count it replaced), so a run can be counted and undone: `revert --run-id RUN` puts all of that back
where nothing has changed since, and marks that document spent for that note: a later document for the same note
still answers it. A note with no account id cannot be measured and is counted as `unmeasured`, never as "no
answer". An unreadable proof store is exit 2 and nothing is written.

`reconcile` brings the marks an earlier rule wrote up to this one (attachment count, sibling rows, verdicts older
than the document). It prints the counts and writes nothing without `--apply`; it sets no new tag.

Kill file: /etc/hydra/proof-marker.disabled stops plan, apply and revert (exit 0, nothing read or written). It
does not stop `reconcile`, which is the repair a person runs while the marker is held.
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
from credit_review.verify_ledger import CLAIM_CAMPAIGNS, ledger_open, note_index, proof_families  # noqa: E402

RULE = "pm-2"
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
# added by pm-2; a ledger whose table was created by pm-1 gets them on the next write
MARKS_COLUMNS = (
    ("family_rows_json", "TEXT NOT NULL DEFAULT '[]'"),   # the sibling rows (verify_messages.id) this tag also tagged
    ("prev_attachments", "INTEGER"),                      # the note's proof_attachments before this tag wrote it
)


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


def ensure_marks(db: sqlite3.Connection) -> None:
    db.executescript(MARKS)
    have = {r[1] for r in db.execute("PRAGMA table_info(proof_marks)")}
    for name, decl in MARKS_COLUMNS:
        if name not in have:
            db.execute(f"ALTER TABLE proof_marks ADD COLUMN {name} {decl}")


def _reviews(db: sqlite3.Connection) -> dict[tuple[int, str], datetime | None]:
    """{(family, request id): the review of that credit under that note}. None = a time that cannot be read:
    nothing is newer than it, for that credit only."""
    out: dict[tuple[int, str], datetime | None] = {}
    for fam, rid, at in db.execute("SELECT family, request_id, reviewed_at FROM verify_proof_reviews"):
        out[(int(fam), str(rid))] = _ts(at)
    return out


def _answers(doc: dict[str, Any], *, claim: bool, root: int, named: set[str],
             note_of: Any, reviews: dict[tuple[int, str], datetime | None]) -> bool:
    """Whether this document is new to the note: unseen for at least one credit the note names (a claim note has
    no credit, so its own family is the unit). A review of another credit, or on another note, hides nothing."""
    if claim:
        return all(t is not None and t < doc["at"] for t in (v for (fam, _), v in reviews.items() if fam == root))
    for rid in doc["requests"] & named:
        key = (note_of(rid) or root, rid)
        if key not in reviews:
            return True
        t = reviews[key]
        if t is not None and t < doc["at"]:
            return True
    return False


def plan(db: sqlite3.Connection, docs: dict[str, list[dict[str, Any]]]) -> tuple[list[dict[str, Any]], Counter]:
    """(the tags to set, counts). Reads only."""
    try:
        rows = db.execute("SELECT id, campaign, account_id, COALESCE(sent_at, created_at) AS asked, parent_row, "
                          "request_ids_json, proof_tagged_at FROM verify_messages WHERE status='sent' "
                          "ORDER BY id").fetchall()
        reviews = _reviews(db)
        note_of = note_index(db).get if reviews else None        # no review on file: nothing to compare or clear
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
        named = _ids(r["request_ids_json"])
        mine = after if claim else [d for d in after if d["requests"] & named]
        if not mine:
            n["document_for_another_request"] += 1
            continue
        answering = len(mine)
        root = int(r["parent_row"] or r["id"])
        if reviews:
            try:
                proof_families(db, root, r["request_ids_json"], note_of=note_of)
            except (TypeError, ValueError):
                n["unmeasured"] += 1                      # the note's credits cannot be read: neither can its reviews
                continue
            # a reviewed credit is answered again only by a document no review of THAT credit has seen
            mine = [d for d in mine if _answers(d, claim=claim, root=root, named=named, note_of=note_of,
                                                reviews=reviews)]
            if not mine:
                n["reviewed_already"] += 1
                continue
        mine = [d for d in mine if (int(r["id"]), d["intake_id"]) not in stands]
        if not mine:
            n["reverted_stands"] += 1
            continue
        n["to_tag"] += 1
        n["to_tag:" + str(r["campaign"])] += 1
        todo.append({"row": int(r["id"]), "root": root, "ids": r["request_ids_json"], "claim": claim,
                     "doc_requests": sorted(mine[0]["requests"]), "intake_id": mine[0]["intake_id"],
                     "at": _stamp(mine[0]["at"]), "documents": len(mine), "attachments": answering})
    return todo, n


def _untagged_family(db: sqlite3.Connection, root: int, row: int) -> list[int]:
    """The other rows of the family (the initial note and its follow-ups) that carry no tag."""
    return [int(x[0]) for x in db.execute(
        "SELECT id FROM verify_messages WHERE (id=? OR parent_row=?) AND id<>? AND proof_tagged_at IS NULL "
        "ORDER BY id", (root, root, row))]


def _rejected(db: sqlite3.Connection, fams: list[int] | set[int], before: datetime | None = None) -> list[dict[str, Any]]:
    """The rejected verdicts under these families; with `before`, only the ones recorded before that time."""
    out: list[dict[str, Any]] = []
    for fam in sorted(fams):
        for x in db.execute(f"SELECT {', '.join(REVIEW_COLS)} FROM verify_proof_reviews "
                            "WHERE family=? AND outcome='rejected' ORDER BY request_id", (fam,)):
            got = dict(zip(REVIEW_COLS, x))
            at = _ts(got["reviewed_at"])
            if before is None or (at is not None and at < before):
                out.append(got)
    return out


def _delete_reviews(db: sqlite3.Connection, rows: list[dict[str, Any]]) -> None:
    for x in rows:
        db.execute("DELETE FROM verify_proof_reviews WHERE family=? AND request_id=? AND outcome='rejected'",
                   (x["family"], x["request_id"]))


def apply(db: sqlite3.Connection, todo: list[dict[str, Any]], *, run_id: str, now: datetime) -> int:
    """Set the tags in ONE transaction, each as `verify_ledger.mark_tagged` does: the note, its family, its
    attachment count, and the rejected verdicts of every family it covers. The families and their reviews are
    read again here, under the write lock: a note tagged, changed or reviewed since the plan is left alone."""
    ts, done = _stamp(now), 0
    ensure_marks(db)
    db.execute("BEGIN IMMEDIATE")
    try:
        reviews = _reviews(db)
        note_of = note_index(db).get if reviews else None
        for t in todo:
            at, root, named, fams = _ts(t["at"]), int(t["root"]), _ids(t["ids"]), {int(t["root"])}
            if at is None:
                continue
            if reviews:
                try:
                    fams = proof_families(db, root, t["ids"], note_of=note_of)
                except (TypeError, ValueError):
                    continue
                doc = {"at": at, "requests": set(t["doc_requests"])}
                if not _answers(doc, claim=bool(t["claim"]), root=root, named=named, note_of=note_of,
                                reviews=reviews):
                    continue                              # a review of these credits landed after the plan
            prev = db.execute("SELECT proof_attachments FROM verify_messages WHERE id=?", (t["row"],)).fetchone()
            cur = db.execute("UPDATE verify_messages SET proof_tagged_at=?, proof_attachments=?, updated_at=? "
                             "WHERE id=? AND status='sent' AND proof_tagged_at IS NULL",
                             (t["at"], int(t["attachments"]), ts, t["row"]))
            if cur.rowcount != 1:
                continue
            family = _untagged_family(db, root, t["row"])
            for rid in family:
                db.execute("UPDATE verify_messages SET proof_tagged_at=?, updated_at=? WHERE id=?", (t["at"], ts, rid))
            # a new document puts every rejected credit back under review, under each credit's own note; a
            # verdict recorded at or after the document is a review of it and is never cleared
            cleared = _rejected(db, fams, before=at)
            _delete_reviews(db, cleared)
            if cleared:
                reviews = _reviews(db)                    # a later note of this run reads the reviews as they now are
            db.execute("INSERT INTO proof_marks (message_row, intake_id, received_at, documents, run_id, rule, "
                       "marked_at, cleared_reviews_json, family_rows_json, prev_attachments) VALUES (?,?,?,?,?,?,?,?,?,?)",
                       (t["row"], t["intake_id"], t["at"], t["documents"], run_id, RULE, ts, json.dumps(cleared),
                        json.dumps(family), int(prev[0] or 0) if prev is not None else None))
            done += 1
        db.execute("COMMIT")
    except Exception:
        db.execute("ROLLBACK")
        raise
    return done


def revert(db: sqlite3.Connection, *, run_id: str, now: datetime) -> dict[str, int]:
    """Undo what `run_id` set: the tags (the note's and its siblings'), the attachment count and the cleared
    verdicts. A tag something else has changed since is left and counted."""
    ts, out = _stamp(now), Counter()
    ensure_marks(db)
    db.execute("BEGIN IMMEDIATE")
    try:
        marks = db.execute("SELECT * FROM proof_marks WHERE run_id=? AND reverted_at IS NULL", (run_id,)).fetchall()
        for m in marks:
            cur = db.execute("UPDATE verify_messages SET proof_tagged_at=NULL, "
                             "proof_attachments=COALESCE(?, proof_attachments), updated_at=? "
                             "WHERE id=? AND proof_tagged_at=?",
                             (m["prev_attachments"], ts, m["message_row"], m["received_at"]))
            if cur.rowcount != 1:
                out["changed_since"] += 1
                continue
            for rid in json.loads(m["family_rows_json"] or "[]"):
                db.execute("UPDATE verify_messages SET proof_tagged_at=NULL, updated_at=? "
                           "WHERE id=? AND proof_tagged_at=?", (ts, int(rid), m["received_at"]))
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


def reconcile(db: sqlite3.Connection, *, write: bool, now: datetime) -> dict[str, Any]:
    """Bring every standing mark up to this rule, as if `apply` had written it: the note's attachment count, the
    untagged rows of its family, and the rejected verdicts (in every family the note covers) that are OLDER than
    the document. A verdict recorded after the document is a review of it and is never cleared; a mark whose tag
    was changed since is left alone. Sets no new tag. `write=False` counts and writes nothing."""
    ts, n = _stamp(now), Counter()
    if write:
        ensure_marks(db)
        db.execute("BEGIN IMMEDIATE")
    try:
        if not db.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name='proof_marks'").fetchone():
            return {"marks": 0}
        cols = {r[1] for r in db.execute("PRAGMA table_info(proof_marks)")}
        marks = db.execute(
            "SELECT k.*, m.id AS note, m.parent_row, m.proof_tagged_at AS tag, m.proof_attachments AS att, "
            "m.request_ids_json FROM proof_marks k LEFT JOIN verify_messages m ON m.id = k.message_row "
            "WHERE k.reverted_at IS NULL ORDER BY k.message_row, k.intake_id").fetchall()
        reviews = _reviews(db)
        note_of = note_index(db).get if reviews else None
        for m in marks:
            n["marks"] += 1
            n["run:" + str(m["run_id"])] += 1
            if m["note"] is None or m["tag"] != m["received_at"]:
                n["changed_since"] += 1                   # reviewed, re-tagged or reverted by hand since: not ours
                continue
            row, root, at = int(m["message_row"]), int(m["parent_row"] or m["message_row"]), _ts(m["received_at"])
            fill = int(m["att"] or 0) == 0 and int(m["documents"] or 0) > 0
            family = _untagged_family(db, root, row)
            cleared: list[dict[str, Any]] = []
            if reviews:
                try:
                    fams = proof_families(db, root, m["request_ids_json"], note_of=note_of)
                except (TypeError, ValueError):
                    n["credits_unreadable"] += 1
                    continue
                cleared = _rejected(db, fams, before=at)
                n["review_newer_than_document"] += len(_rejected(db, fams)) - len(cleared)
            stale_rule = str(m["rule"]) != RULE
            n["attachments_filled"] += fill
            n["family_rows_tagged"] += len(family)
            n["reviews_cleared"] += len(cleared)
            n["rule_updated"] += stale_rule
            if not write or not (fill or family or cleared or stale_rule):
                continue
            if fill:
                db.execute("UPDATE verify_messages SET proof_attachments=?, updated_at=? WHERE id=? AND proof_tagged_at=?",
                           (int(m["documents"]), ts, row, m["received_at"]))
            for rid in family:
                db.execute("UPDATE verify_messages SET proof_tagged_at=?, updated_at=? WHERE id=? "
                           "AND proof_tagged_at IS NULL", (m["received_at"], ts, rid))
            _delete_reviews(db, cleared)
            was_family = json.loads(m["family_rows_json"] or "[]") if "family_rows_json" in cols else []
            db.execute("UPDATE proof_marks SET rule=?, family_rows_json=?, cleared_reviews_json=?, "
                       "prev_attachments=COALESCE(prev_attachments, ?) WHERE message_row=? AND intake_id=?",
                       (RULE, json.dumps(was_family + family),
                        json.dumps(json.loads(m["cleared_reviews_json"] or "[]") + cleared),
                        0 if fill else None, row, m["intake_id"]))
        if write:
            db.execute("COMMIT")
    except Exception:
        if write:
            db.execute("ROLLBACK")
        raise
    out: dict[str, Any] = {k: n[k] for k in ("marks", "changed_since", "credits_unreadable", "attachments_filled",
                                             "family_rows_tagged", "reviews_cleared", "review_newer_than_document",
                                             "rule_updated")}
    out["runs"] = {k[4:]: v for k, v in sorted(n.items()) if k.startswith("run:")}
    return out


def _rw(path: str) -> sqlite3.Connection:
    if not Path(path).is_file():
        raise Unreadable(f"{path} does not exist (the marker never creates a ledger)")
    db = ledger_open().open_rw(path, opener="credit_review.proof_marker", timeout=30, isolation_level=None)
    db.row_factory = sqlite3.Row
    return db


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    p.add_argument("op", choices=("plan", "apply", "revert", "reconcile"))
    p.add_argument("--ledger", default=LEDGER)
    p.add_argument("--store", default=PROOF_STORE)
    p.add_argument("--kill-file", default=KILL)
    p.add_argument("--run-id", default=None, help="revert: the run to undo")
    p.add_argument("--apply", action="store_true", help="reconcile: write (without it, counts only)")
    a = p.parse_args(argv)
    if a.apply and a.op != "reconcile":
        p.error("--apply belongs to reconcile; the op that tags is `apply`")
    if a.op != "reconcile" and Path(a.kill_file).exists():
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
        if a.op == "reconcile":
            db = _rw(a.ledger) if a.apply else _ro(a.ledger)
            print(json.dumps({"op": "reconcile", "apply": bool(a.apply), "rule": RULE,
                              **reconcile(db, write=bool(a.apply), now=now)}))
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
