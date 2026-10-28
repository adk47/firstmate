"""Caroline's action ledger: every call is one append-only row; the intake queues hang off it.

SQLite at /var/lib/hydra/caroline-actions/ledger.sqlite3 (0600, dir 0700; CAROLINE_ACTIONS_LEDGER).
No email and no name is stored: the account is the Muso user id, the contact is a hash.

  actions      one row per tool call: verb, outcome, line id, refusals, request/claim ids, facts summary
  doc_intake   one row per (conversation, file sha256): the document reader's intake queue
               (credit-proof.py intercom reads it read-only; scripts/credit_verify/proof/intercom.py)
  merge_intake one row per merge request filed to the merge queue (the ClickUp merge ticket id)
  handoffs     one row per (conversation, reason): the credit-trust board's queue (board-export)
"""

from __future__ import annotations

import hashlib
import json
import os
import sqlite3
from datetime import datetime, timedelta, timezone
from typing import Any, Optional

DEFAULT_PATH = os.environ.get("CAROLINE_ACTIONS_LEDGER", "/var/lib/hydra/caroline-actions/ledger.sqlite3")

SCHEMA = """
CREATE TABLE IF NOT EXISTS actions (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  ts TEXT NOT NULL,
  verb TEXT NOT NULL,                 -- status | doc-intake | merge-intake | merge-record | handoff
  conv_id TEXT,
  user_id INTEGER,
  contact_h TEXT,                     -- sha256 of the lower-cased verified email, 16 hex (never the email)
  outcome TEXT NOT NULL,              -- line_offered | line_withheld_locked | refused | filed | recorded | handed_off
  line_id TEXT,
  refusals_json TEXT NOT NULL DEFAULT '[]',
  request_ids_json TEXT NOT NULL DEFAULT '[]',
  claim_ids_json TEXT NOT NULL DEFAULT '[]',
  facts_json TEXT,
  detail_json TEXT
);
CREATE INDEX IF NOT EXISTS actions_user_line ON actions(user_id, outcome, ts);
CREATE TABLE IF NOT EXISTS doc_intake (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  queued_at TEXT NOT NULL,
  conv_id TEXT NOT NULL,
  path TEXT NOT NULL,
  sha256 TEXT NOT NULL,
  bytes INTEGER NOT NULL,
  subject TEXT NOT NULL,              -- credit | claim
  user_id INTEGER,
  contact_h TEXT,
  request_ids_json TEXT NOT NULL DEFAULT '[]',   -- candidate credit requests (the user's open rows)
  claim_ids_json TEXT NOT NULL DEFAULT '[]',     -- candidate claims (the user's pending claims)
  UNIQUE (conv_id, sha256)
);
CREATE TABLE IF NOT EXISTS merge_intake (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  ts TEXT NOT NULL,
  conv_id TEXT,
  user_id INTEGER,
  kind TEXT NOT NULL,
  keep TEXT NOT NULL,
  others_key TEXT NOT NULL,           -- sorted, comma-joined
  status TEXT NOT NULL,               -- to_file | filed | file_failed
  ticket_id TEXT,
  updated_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS merge_intake_key ON merge_intake(user_id, kind, keep, others_key, ts);
CREATE TABLE IF NOT EXISTS handoffs (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  ts TEXT NOT NULL,
  conv_id TEXT NOT NULL,
  user_id INTEGER,
  reason TEXT NOT NULL,
  request_ids_json TEXT NOT NULL DEFAULT '[]',
  claim_ids_json TEXT NOT NULL DEFAULT '[]',
  summary TEXT,
  exported_at TEXT
);
CREATE INDEX IF NOT EXISTS handoffs_key ON handoffs(conv_id, reason, ts);
"""


class _atomic:
    """BEGIN IMMEDIATE ... COMMIT: the write lock is taken BEFORE the check, so a concurrent caller
    waits (busy timeout) and then sees the row this one wrote."""

    def __init__(self, db: sqlite3.Connection):
        self.db = db

    def __enter__(self):
        self.db.execute("BEGIN IMMEDIATE")
        return self.db

    def __exit__(self, exc_type, *_):
        self.db.execute("ROLLBACK" if exc_type else "COMMIT")
        return False


# A to_file row is a filing whose outcome we do not know (the ticket may exist and the record step
# may have failed). It blocks a second filing for the same 7 days as a filed row and NEVER expires
# sooner: a duplicate ticket is worse than a handoff (Fable #1402 review).


def stamp(now: Optional[datetime] = None) -> str:
    return (now or datetime.now(timezone.utc)).astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def contact_hash(email: str) -> str:
    return hashlib.sha256(f"caroline-contact:{(email or '').strip().lower()}".encode()).hexdigest()[:16]


def connect(path: str = DEFAULT_PATH) -> sqlite3.Connection:
    d = os.path.dirname(path)
    if d:
        os.makedirs(d, mode=0o700, exist_ok=True)
    new = not os.path.exists(path)
    # Autocommit; every check-then-write runs in an explicit BEGIN IMMEDIATE (see _atomic), so two
    # Caroline sessions (or two gateways) racing on the same user cannot both pass a dedupe check.
    db = sqlite3.connect(path, timeout=30, isolation_level=None)
    db.row_factory = sqlite3.Row
    if new:
        os.chmod(path, 0o600)
    db.executescript(SCHEMA)
    return db


def connect_ro(path: str = DEFAULT_PATH) -> sqlite3.Connection:
    db = sqlite3.connect(f"file:{path}?mode=ro", uri=True, timeout=30)
    db.row_factory = sqlite3.Row
    return db


def _insert_action(db: sqlite3.Connection, *, verb: str, outcome: str, conv_id: Optional[str], user_id: Optional[int],
                   email: str, line_id: Optional[str] = None, refusals: list[str] | None = None,
                   request_ids: list[str] | None = None, claim_ids: list[str] | None = None,
                   facts: Optional[dict] = None, detail: Optional[dict] = None, now: Optional[datetime] = None) -> int:
    cur = db.execute(
        "INSERT INTO actions (ts, verb, conv_id, user_id, contact_h, outcome, line_id, refusals_json, "
        "request_ids_json, claim_ids_json, facts_json, detail_json) VALUES (?,?,?,?,?,?,?,?,?,?,?,?)",
        (stamp(now), verb, conv_id, user_id, contact_hash(email), outcome, line_id, json.dumps(refusals or []),
         json.dumps(request_ids or []), json.dumps(claim_ids or []),
         json.dumps(facts) if facts is not None else None, json.dumps(detail) if detail is not None else None))
    return int(cur.lastrowid)


def record(db: sqlite3.Connection, **row: Any) -> int:
    """One append-only action row (autocommit)."""
    return _insert_action(db, **row)


def last_line_at(db: sqlite3.Connection, user_id: int) -> Optional[datetime]:
    """The last approved line Caroline was GIVEN for this user (offered counts: she may have sent it)."""
    row = db.execute("SELECT max(ts) FROM actions WHERE user_id = ? AND outcome = 'line_offered'",
                     (user_id,)).fetchone()
    if not row or not row[0]:
        return None
    return datetime.strptime(row[0], "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)


def queue_doc(db: sqlite3.Connection, *, conv_id: str, path: str, sha256: str, size: int, subject: str,
              user_id: Optional[int], email: str, request_ids: list[str], claim_ids: list[str],
              now: Optional[datetime] = None) -> bool:
    """True when newly queued; False when this exact file is already queued for this conversation."""
    cur = db.execute(
        "INSERT OR IGNORE INTO doc_intake (queued_at, conv_id, path, sha256, bytes, subject, user_id, contact_h, "
        "request_ids_json, claim_ids_json) VALUES (?,?,?,?,?,?,?,?,?,?)",
        (stamp(now), conv_id, path, sha256, size, subject, user_id, contact_hash(email), json.dumps(request_ids),
         json.dumps(claim_ids)))
    return cur.rowcount == 1


def queued_docs(path: str = DEFAULT_PATH, *, days: int = 30, now: Optional[datetime] = None) -> dict[str, list[str]]:
    """Read-only: {conversation id: [cached file paths]} queued in the last `days` (for the H3 runner).
    A missing ledger is an empty queue (nothing was ever filed)."""
    if not os.path.exists(path):
        return {}
    since = stamp((now or datetime.now(timezone.utc)) - timedelta(days=days))
    db = connect_ro(path)
    try:
        out: dict[str, list[str]] = {}
        for r in db.execute("SELECT conv_id, path FROM doc_intake WHERE queued_at >= ? ORDER BY id", (since,)):
            out.setdefault(r["conv_id"], []).append(r["path"])
        return out
    finally:
        db.close()


def _merge_existing(db: sqlite3.Connection, *, user_id, kind, keep, others, now) -> Optional[str]:
    """The ticket id (or a marker) of the same request filed, or possibly filed (to_file), in 7 days."""
    since = stamp(now - timedelta(days=7))
    row = db.execute(
        "SELECT status, ticket_id FROM merge_intake WHERE user_id IS ? AND kind = ? AND keep = ? AND others_key = ? "
        "AND status IN ('filed', 'to_file') AND ts >= ? ORDER BY id DESC LIMIT 1",
        (user_id, kind, keep, ",".join(sorted(others)), since)).fetchone()
    if not row:
        return None
    if row["status"] == "filed":
        return row["ticket_id"] or "filed"
    return "in_flight"


def merge_filed_within(db: sqlite3.Connection, *, user_id: Optional[int], kind: str, keep: str, others: list[str],
                       now: Optional[datetime] = None) -> Optional[str]:
    return _merge_existing(db, user_id=user_id, kind=kind, keep=keep, others=others,
                           now=now or datetime.now(timezone.utc))


def merge_claim(db: sqlite3.Connection, *, conv_id: Optional[str], user_id: Optional[int], kind: str, keep: str,
                others: list[str], now: Optional[datetime] = None) -> tuple[Optional[int], Optional[str]]:
    """Atomically: refuse when the same request is filed (7 d) or in flight (15 min), else open a
    to_file row. Returns (row id, None) or (None, existing ticket id / 'in_flight')."""
    now = now or datetime.now(timezone.utc)
    with _atomic(db):
        existing = _merge_existing(db, user_id=user_id, kind=kind, keep=keep, others=others, now=now)
        if existing:
            return None, existing
        ts = stamp(now)
        cur = db.execute("INSERT INTO merge_intake (ts, conv_id, user_id, kind, keep, others_key, status, updated_at) "
                         "VALUES (?,?,?,?,?,?,'to_file',?)",
                         (ts, conv_id, user_id, kind, keep, ",".join(sorted(others)), ts))
        return int(cur.lastrowid), None


def merge_close(db: sqlite3.Connection, row_id: int, *, ticket_id: Optional[str], ok: bool,
                now: Optional[datetime] = None) -> bool:
    """Close a to_file row. Retry-safe: recording the SAME ticket id again on a filed row is a success,
    so the plugin can retry a record step whose answer it lost. A row with a ticket id is never reopened
    or downgraded to file_failed."""
    with _atomic(db):
        row = db.execute("SELECT status, ticket_id FROM merge_intake WHERE id = ?", (row_id,)).fetchone()
        if row is None:
            return False
        if row["status"] == "filed":
            return bool(ok and ticket_id and row["ticket_id"] == ticket_id)
        if row["status"] != "to_file":
            return False
        db.execute("UPDATE merge_intake SET status = ?, ticket_id = ?, updated_at = ? WHERE id = ?",
                   ("filed" if ok else "file_failed", ticket_id, stamp(now), row_id))
        return True


def handoff_within(db: sqlite3.Connection, *, conv_id: str, reason: str, now: Optional[datetime] = None) -> bool:
    since = stamp((now or datetime.now(timezone.utc)) - timedelta(days=7))
    return db.execute("SELECT 1 FROM handoffs WHERE conv_id = ? AND reason = ? AND ts >= ? LIMIT 1",
                      (conv_id, reason, since)).fetchone() is not None


def handoff_claim(db: sqlite3.Connection, *, conv_id: str, user_id: Optional[int], reason: str, request_ids: list[str],
                  claim_ids: list[str], summary: str, now: Optional[datetime] = None) -> Optional[int]:
    """Atomically: None when this conversation was handed off for this reason in 7 days, else the new id."""
    with _atomic(db):
        if handoff_within(db, conv_id=conv_id, reason=reason, now=now):
            return None
        cur = db.execute("INSERT INTO handoffs (ts, conv_id, user_id, reason, request_ids_json, claim_ids_json, summary) "
                         "VALUES (?,?,?,?,?,?,?)", (stamp(now), conv_id, user_id, reason, json.dumps(request_ids),
                                                    json.dumps(claim_ids), summary))
        return int(cur.lastrowid)


def offer_line(db: sqlite3.Connection, *, user_id: int, now: Optional[datetime] = None, **row: Any) -> Optional[int]:
    """Atomically: record line_offered for this user unless one was offered in 7 days (then None).
    Two status calls racing for the same user can never both get a line."""
    now = now or datetime.now(timezone.utc)
    with _atomic(db):
        last = last_line_at(db, user_id)
        if last is not None and now - timedelta(days=7) <= last:
            return None
        return _insert_action(db, user_id=user_id, outcome="line_offered", now=now, **row)


def board_snapshot(db: sqlite3.Connection, *, now: Optional[datetime] = None, days: int = 30) -> dict[str, Any]:
    """The handoff queue as one JSON snapshot for the credit-trust board (paid flag is the board's join)."""
    since = stamp((now or datetime.now(timezone.utc)) - timedelta(days=days))
    rows = db.execute("SELECT * FROM handoffs WHERE ts >= ? ORDER BY ts", (since,)).fetchall()
    items = [{"handoff_id": r["id"], "at": r["ts"], "conversation_id": r["conv_id"], "user_id": r["user_id"],
              "reason": r["reason"], "request_ids": json.loads(r["request_ids_json"]),
              "claim_ids": json.loads(r["claim_ids_json"]), "summary": r["summary"]} for r in rows]
    counts: dict[str, int] = {}
    for i in items:
        counts[i["reason"]] = counts.get(i["reason"], 0) + 1
    return {"as_of": stamp(now), "source": "hydra caroline-actions handoff", "window_days": days,
            "counts": counts, "handoffs": items}
