#!/usr/bin/env python3
"""The monitor's durable state: one SQLite file under /var/lib (never /opt/hydra, which the
deploy rsync overwrites).

What is kept holds no text by construction: a thread row is an id, two timestamps, whether it is
open, a shape id and a list of (timestamp, one-letter code). No message, no subject, no email.
Thread rows are the measurement substrate, kept so that a thread whose `updated_at` has not moved
is not fetched again and so that a shape can be re-measured over a window that has left
Intercom's search. They are never the fix loop's output: that is the shape register.

The promise ledger (commitments.py) lives in the same file. Its rows carry Intercom's own opaque
contact id, which is what lets a status line be routed onto the thread that carries the promise.
"""
import json
import os
import sqlite3

from . import commitments

DEFAULT_STATE_DIR = os.environ.get("CAROLINE_MONITOR_STATE_DIR", "/var/lib/hydra/caroline-monitor")
DB_NAME = "monitor.sqlite"

SCHEMA = """
CREATE TABLE IF NOT EXISTS facts (
  id TEXT PRIMARY KEY,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  open INTEGER NOT NULL DEFAULT 0,
  rules TEXT NOT NULL,
  shape TEXT NOT NULL,
  outbound INTEGER NOT NULL,
  events TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS facts_created ON facts (created_at);
CREATE TABLE IF NOT EXISTS readings (
  taken_at INTEGER NOT NULL,
  kind TEXT NOT NULL,
  payload TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS readings_kind ON readings (kind, taken_at);
CREATE TABLE IF NOT EXISTS pages (
  key TEXT PRIMARY KEY,
  value REAL,
  paged_at INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS kv (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL
);
"""


class Store:
    def __init__(self, path):
        self.path = path
        if path != ":memory:":
            os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
        self.db = sqlite3.connect(path, timeout=30)
        self.db.executescript(SCHEMA)
        commitments.ensure_schema(self.db)
        self.db.commit()

    @classmethod
    def open_default(cls, state_dir=None):
        return cls(os.path.join(state_dir or DEFAULT_STATE_DIR, DB_NAME))

    def close(self):
        self.db.close()

    # --- facts ------------------------------------------------------------------------------
    def put_facts(self, facts, commit=True):
        self.db.executemany(
            "INSERT INTO facts (id, created_at, updated_at, open, rules, shape, outbound, events) "
            "VALUES (?,?,?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET created_at=excluded.created_at, "
            "updated_at=excluded.updated_at, open=excluded.open, rules=excluded.rules, "
            "shape=excluded.shape, outbound=excluded.outbound, events=excluded.events",
            [(f["id"], f["created_at"], f["updated_at"], int(bool(f.get("open"))), f["rules"], f["shape"],
              int(bool(f.get("outbound"))), json.dumps(f["events"], separators=(",", ":")))
             for f in facts])
        if commit:
            self.db.commit()

    def keep(self, rows, register, now, policy=None):
        """Facts and the promises read from them, for many threads, in ONE transaction: a thread
        is never stored with its facts updated and its commitments still describing the old read.
        `rows` is (fact, contact_id) pairs."""
        policy = commitments.load_request_lines() if policy is None else policy
        try:
            for fact, contact_id in rows:
                self.put_facts([fact], commit=False)
                commitments.sync(self.db, fact["id"], contact_id, fact, register, now, policy)
        except BaseException:
            self.db.rollback()
            raise
        self.db.commit()

    def delete_facts(self, ids):
        self.db.executemany("DELETE FROM facts WHERE id = ?", [(i,) for i in ids])
        commitments.forget(self.db, ids)
        self.db.commit()

    def held(self, rules_version):
        """{id: updated_at} for every thread we already hold under THIS rule set, whatever its age:
        an old conversation that is still open is listed on every tick."""
        rows = self.db.execute("SELECT id, updated_at FROM facts WHERE rules = ?", (rules_version,))
        return {r[0]: r[1] for r in rows}

    def close_unlisted(self, listed_ids):
        """A thread we hold as open that a complete listing of open conversations no longer
        returns is not open any more. Only call this after the listing passed its coverage check."""
        listed = set(listed_ids)
        stale = [r[0] for r in self.db.execute("SELECT id FROM facts WHERE open = 1") if r[0] not in listed]
        self.db.executemany("UPDATE facts SET open = 0 WHERE id = ?", [(i,) for i in stale])
        self.db.commit()
        return len(stale)

    def sync_commitments(self, thread_id, contact_id, fact, register, now, policy=None):
        still_open = commitments.sync(self.db, thread_id, contact_id, fact, register, now, policy)
        self.db.commit()
        return still_open

    def facts(self, start=0, end=2 ** 62, rules_version=None):
        sql = "SELECT id, created_at, updated_at, rules, shape, outbound, events, open FROM facts " \
              "WHERE created_at >= ? AND created_at < ?"
        args = [start, end]
        if rules_version is not None:
            sql += " AND rules = ?"
            args.append(rules_version)
        return [{"id": r[0], "created_at": r[1], "updated_at": r[2], "rules": r[3], "shape": r[4],
                 "outbound": bool(r[5]), "events": json.loads(r[6]), "open": bool(r[7])}
                for r in self.db.execute(sql, args)]

    def prune_facts(self, older_than):
        """Age out old threads, but never one that is still open and never one that still carries
        an open commitment: forgetting a promise is not a way of keeping it."""
        keep = "SELECT conversation_id FROM commitments WHERE closed_at IS NULL"
        where = f"created_at < ? AND open = 0 AND id NOT IN ({keep})"
        self.db.execute(f"DELETE FROM commitment_outbox WHERE conversation_id IN (SELECT id FROM facts WHERE {where})",
                        (older_than,))
        self.db.execute(f"DELETE FROM commitments WHERE conversation_id IN (SELECT id FROM facts WHERE {where})",
                        (older_than,))
        cur = self.db.execute(f"DELETE FROM facts WHERE {where}", (older_than,))
        self.db.commit()
        return cur.rowcount

    # --- readings ---------------------------------------------------------------------------
    def add_reading(self, taken_at, kind, payload):
        self.db.execute("INSERT INTO readings (taken_at, kind, payload) VALUES (?,?,?)",
                        (taken_at, kind, json.dumps(payload, separators=(",", ":"), sort_keys=True)))
        self.db.commit()

    def readings(self, kind, limit=50):
        rows = self.db.execute(
            "SELECT taken_at, payload FROM readings WHERE kind = ? ORDER BY taken_at DESC LIMIT ?",
            (kind, limit))
        return [(r[0], json.loads(r[1])) for r in rows]

    # --- page dedupe ------------------------------------------------------------------------
    def last_page(self, key):
        row = self.db.execute("SELECT value, paged_at FROM pages WHERE key = ?", (key,)).fetchone()
        return {"value": row[0], "paged_at": row[1]} if row else None

    def stamp_page(self, key, value, paged_at):
        self.db.execute(
            "INSERT INTO pages (key, value, paged_at) VALUES (?,?,?) ON CONFLICT(key) DO UPDATE SET "
            "value=excluded.value, paged_at=excluded.paged_at", (key, value, paged_at))
        self.db.commit()

    def clear_pages_except(self, keys):
        """A finding that is no longer present loses its stamp, so its return pages at once."""
        held = [r[0] for r in self.db.execute("SELECT key FROM pages")]
        gone = [k for k in held if k not in set(keys)]
        self.db.executemany("DELETE FROM pages WHERE key = ?", [(k,) for k in gone])
        self.db.commit()
        return gone

    # --- small state ------------------------------------------------------------------------
    def get(self, key, default=None):
        row = self.db.execute("SELECT value FROM kv WHERE key = ?", (key,)).fetchone()
        return json.loads(row[0]) if row else default

    def set(self, key, value):
        self.db.execute(
            "INSERT INTO kv (key, value) VALUES (?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
            (key, json.dumps(value)))
        self.db.commit()
