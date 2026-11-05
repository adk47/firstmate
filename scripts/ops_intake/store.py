"""The ask register: one sqlite row per inbound ask, and its event trail.

``ops_asks`` is what makes "queued" a fact instead of a sentence. Before this
table existed, the Ops bot told Jan an ask was "queued for FirstMate" on at
least 24 of 301 asks in the 14-day census and there was no queue at all; the
watchdog that chases an open ask past ``due_at`` (scripts/ops_intake/watcher.py)
can only exist because the row does.

Path: ``/var/lib/hydra/ops-intake/asks.sqlite``, overridable with
``OPS_INTAKE_DB`` (tests always override). Under /var/lib, never /opt/hydra:
the deploy rsync overwrites /opt/hydra, and a queue that a deploy can erase is
not a queue.

States (the column is the machine's answer, never a model's):

  ``open``        row written, coded answerer has not finished
  ``answered``    reply posted in the asker's thread from measured evidence
  ``held``        a burst cap or a fraud-lens hold stopped the work (paged)
  ``quarantined`` a HIGH injection-watch hit in an input; the model never saw it
  ``refused``     the tier does not permit what was asked; the human path is named
  ``ask``         the router needs one specific fact (e.g. register identity
                  UNKNOWN) and says which - never a hide on a guess
  ``escalated``   the watcher pushed it past ``due_at``
  ``failed``      a canary leak or an unhandled error; fails CLOSED
"""
from __future__ import annotations

import json
import os
import secrets
import sqlite3
from contextlib import contextmanager
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any, Iterator

DEFAULT_PATH = os.environ.get("OPS_INTAKE_DB", "/var/lib/hydra/ops-intake/asks.sqlite")
# An ask is due 30 minutes after the Slack message (spec j2 item 1). A reply that
# says "queued" must name this time or it is not a reply.
DUE_AFTER = timedelta(minutes=30)

STATES = ("open", "answered", "held", "quarantined", "refused", "ask",
          "escalated", "failed")

SCHEMA = """
CREATE TABLE IF NOT EXISTS ops_asks (
  ask_id        TEXT PRIMARY KEY,
  slack_ts      TEXT NOT NULL,
  slack_channel TEXT NOT NULL,
  slack_thread  TEXT,
  account_id    TEXT NOT NULL,          -- slack account that received it (operations)
  requester_id  TEXT NOT NULL,          -- Slack ENVELOPE user id, never text
  requester_name TEXT,
  tier          TEXT NOT NULL,          -- R | W1
  class         TEXT NOT NULL,
  candidates    TEXT NOT NULL,          -- JSON array: every class the text also matched
  text_sha256   TEXT NOT NULL,          -- the body is NOT stored: one hash + the ids
  extracted_ids TEXT NOT NULL,          -- JSON
  state         TEXT NOT NULL,
  verdict       TEXT,
  verdict_source TEXT,                  -- coded | dv_outcomes | firstmate-ruling:<path> | none
  action        TEXT,
  ledger_id     INTEGER,
  lens_json     TEXT,                   -- fraud-lens result, verbatim
  due_at        TEXT NOT NULL,
  created_at    TEXT NOT NULL,
  updated_at    TEXT NOT NULL,
  reply_ts      TEXT,
  reply_text    TEXT,
  note          TEXT
);
CREATE INDEX IF NOT EXISTS ops_asks_state_due ON ops_asks(state, due_at);
CREATE INDEX IF NOT EXISTS ops_asks_slack ON ops_asks(slack_channel, slack_ts);
CREATE INDEX IF NOT EXISTS ops_asks_requester ON ops_asks(requester_id, created_at);

CREATE TABLE IF NOT EXISTS ops_ask_events (
  id      INTEGER PRIMARY KEY AUTOINCREMENT,
  ask_id  TEXT NOT NULL,
  at      TEXT NOT NULL,
  kind    TEXT NOT NULL,
  detail  TEXT
);
CREATE INDEX IF NOT EXISTS ops_ask_events_ask ON ops_ask_events(ask_id, id);

CREATE TABLE IF NOT EXISTS ops_intake_lease (
  ask_id  TEXT PRIMARY KEY,             -- one intake run owns one ask
  owner   TEXT NOT NULL,                -- the child that acquired it
  at      TEXT NOT NULL                 -- last renewal; expires after the lease
);
"""


def utcnow() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def parse_ts(value: str) -> datetime:
    return datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)


def slack_ts_to_dt(ts: str) -> datetime:
    """Slack ts ('1792677595.277939') -> aware UTC datetime."""
    seconds = float(ts)
    return datetime.fromtimestamp(seconds, tz=timezone.utc)


def new_ask_id(*, at: datetime | None = None) -> str:
    """``oa-YYYYMMDD-HHMMSS-<6 hex>``. Sorts by time; the suffix keeps it unique."""
    stamp = (at or datetime.now(timezone.utc)).strftime("%Y%m%d-%H%M%S")
    return f"oa-{stamp}-{secrets.token_hex(3)}"


@dataclass(frozen=True)
class NewAsk:
    slack_ts: str
    slack_channel: str
    slack_thread: str | None
    account_id: str
    requester_id: str
    requester_name: str | None
    tier: str
    cls: str
    candidates: tuple[str, ...]
    text_sha256: str
    extracted_ids: dict[str, list[str]]
    due_at: str
    state: str = "open"
    note: str | None = None


class AskStore:
    """Thin sqlite wrapper. Every method opens its own connection: the router runs
    as a short-lived child process per inbound message, and a held connection
    across a Slack post is how a wedged sqlite file stalls intake."""

    def __init__(self, path: str | Path | None = None):
        self.path = str(path or DEFAULT_PATH)

    @contextmanager
    def connect(self) -> Iterator[sqlite3.Connection]:
        parent = Path(self.path).parent
        parent.mkdir(parents=True, exist_ok=True)
        try:
            os.chmod(parent, 0o700)
        except OSError:
            pass
        conn = sqlite3.connect(self.path, timeout=15)
        conn.row_factory = sqlite3.Row
        try:
            conn.execute("PRAGMA journal_mode=WAL")
            conn.execute("PRAGMA busy_timeout=15000")
            conn.executescript(SCHEMA)
            self._ensure_unique_slack_index(conn)
            yield conn
            conn.commit()
        finally:
            conn.close()
        try:
            os.chmod(self.path, 0o600)
        except OSError:
            pass

    @staticmethod
    def _ensure_unique_slack_index(conn: sqlite3.Connection) -> None:
        """Make (channel, ts) the register's key, migrating an older database.

        The pair is the register's identity. A database written before the unique
        index may hold duplicates from the old read-then-act insert, and an index
        of the same name may exist but be non-unique, so the order is: drop the
        old index, keep the OLDEST row per pair, then create the unique one. Once
        it is unique this is a single catalog read.
        """
        row = conn.execute(
            "SELECT sql FROM sqlite_master WHERE type='index' AND name='ops_asks_slack'"
        ).fetchone()
        if row is not None and row["sql"] and "UNIQUE" in row["sql"].upper():
            return
        conn.execute("DROP INDEX IF EXISTS ops_asks_slack")
        conn.execute(
            "DELETE FROM ops_asks WHERE rowid NOT IN ("
            "  SELECT MIN(rowid) FROM ops_asks GROUP BY slack_channel, slack_ts)")
        conn.execute(
            "CREATE UNIQUE INDEX ops_asks_slack ON ops_asks(slack_channel, slack_ts)")

    # -- writes -----------------------------------------------------------
    def add_ask(self, ask: NewAsk, *, now: str | None = None) -> tuple[str, bool]:
        """Insert the row. Idempotent on (channel, ts) AT THE STORAGE LAYER: the
        unique index makes the pair the key, so two concurrent claims cannot both
        create a row. Returns (ask_id, created)."""
        now = now or utcnow()
        ask_id = new_ask_id()
        with self.connect() as conn:
            cur = conn.execute(
                """INSERT INTO ops_asks (ask_id, slack_ts, slack_channel, slack_thread, account_id,
                     requester_id, requester_name, tier, class, candidates, text_sha256,
                     extracted_ids, state, due_at, created_at, updated_at, note)
                   VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                   ON CONFLICT(slack_channel, slack_ts) DO NOTHING""",
                (ask_id, ask.slack_ts, ask.slack_channel, ask.slack_thread, ask.account_id,
                 ask.requester_id, ask.requester_name, ask.tier, ask.cls,
                 json.dumps(list(ask.candidates)), ask.text_sha256,
                 json.dumps(ask.extracted_ids), ask.state, ask.due_at, now, now, ask.note))
            if cur.rowcount == 0:
                row = conn.execute(
                    "SELECT ask_id FROM ops_asks WHERE slack_channel=? AND slack_ts=?",
                    (ask.slack_channel, ask.slack_ts)).fetchone()
                return (row["ask_id"] if row else ask_id), False
            self._event(conn, ask_id, now, "created", f"class={ask.cls} tier={ask.tier}")
            return ask_id, True

    def mark_handoff(self, ask_id: str, *, verdict: str,
                     verdict_source: str = "agent-handoff",
                     now: str | None = None) -> bool:
        """Record a hand-off on a row that is still open/ask.

        A re-delivered event re-claims the same row, so this must never reopen a
        terminal one or overwrite the agent's verdict.
        """
        now = now or utcnow()
        with self.connect() as conn:
            cur = conn.execute(
                "UPDATE ops_asks SET verdict=?, verdict_source=?, updated_at=? "
                "WHERE ask_id=? AND state IN ('open','ask')",
                (verdict, verdict_source, now, ask_id))
            if cur.rowcount:
                self._event(conn, ask_id, now, "handed-off", "class=other agent turn")
            return cur.rowcount > 0

    def transition(self, ask_id: str, state: str, *, now: str | None = None,
                   **fields: Any) -> None:
        if state not in STATES:
            raise ValueError(f"unknown ask state {state!r}")
        now = now or utcnow()
        cols = ["state=?", "updated_at=?"]
        vals: list[Any] = [state, now]
        for key in ("verdict", "verdict_source", "action", "ledger_id", "lens_json",
                    "reply_ts", "reply_text", "note", "tier"):
            if key in fields:
                cols.append(f"{key}=?")
                vals.append(fields[key])
        vals.append(ask_id)
        with self.connect() as conn:
            conn.execute(f"UPDATE ops_asks SET {', '.join(cols)} WHERE ask_id=?", vals)
            self._event(conn, ask_id, now, f"state:{state}",
                        fields.get("note") or fields.get("verdict"))

    @staticmethod
    def _event(conn: sqlite3.Connection, ask_id: str, at: str, kind: str,
               detail: str | None = None) -> None:
        conn.execute("INSERT INTO ops_ask_events (ask_id, at, kind, detail) VALUES (?,?,?,?)",
                     (ask_id, at, kind, detail))

    def event(self, ask_id: str, kind: str, detail: str | None = None,
              at: str | None = None) -> None:
        with self.connect() as conn:
            self._event(conn, ask_id, at or utcnow(), kind, detail)

    def acquire_intake_lease(self, ask_id: str, *, owner: str, within: timedelta,
                             now: datetime | None = None) -> bool:
        """Take the intake lease for this ask, atomically. False = someone else owns it.

        A Slack retry that lands while the first ``intake`` child is still working
        must not start a second one, so the check and the claim are ONE statement:
        an expired lease is deleted and the insert either wins or hits the primary
        key. Past the lease the child is presumed dead and a retry takes over.
        """
        now_dt = now or datetime.now(timezone.utc)
        cut = (now_dt - within).strftime("%Y-%m-%dT%H:%M:%SZ")
        with self.connect() as conn:
            conn.execute("DELETE FROM ops_intake_lease WHERE at <= ?", (cut,))
            try:
                conn.execute(
                    "INSERT INTO ops_intake_lease (ask_id, owner, at) VALUES (?,?,?)",
                    (ask_id, owner, now_dt.strftime("%Y-%m-%dT%H:%M:%SZ")))
            except sqlite3.IntegrityError:
                return False
        return True

    def renew_intake_lease(self, ask_id: str, *, owner: str,
                           now: datetime | None = None) -> bool:
        """Renew OUR lease; False when another child owns it."""
        at = (now or datetime.now(timezone.utc)).strftime("%Y-%m-%dT%H:%M:%SZ")
        with self.connect() as conn:
            cur = conn.execute(
                "UPDATE ops_intake_lease SET at=? WHERE ask_id=? AND owner=?",
                (at, ask_id, owner))
            return cur.rowcount > 0

    def intake_in_flight(self, ask_id: str, *, within: timedelta,
                         now: datetime | None = None) -> bool:
        """Is an intake run for this ask still inside its lease?"""
        cut = (now or datetime.now(timezone.utc)) - within
        with self.connect() as conn:
            row = conn.execute(
                "SELECT at FROM ops_intake_lease WHERE ask_id=?", (ask_id,)).fetchone()
        return bool(row and row["at"] and row["at"] >= cut.strftime("%Y-%m-%dT%H:%M:%SZ"))

    # -- reads ------------------------------------------------------------
    def get(self, ask_id: str) -> dict[str, Any] | None:
        with self.connect() as conn:
            row = conn.execute("SELECT * FROM ops_asks WHERE ask_id=?", (ask_id,)).fetchone()
            return dict(row) if row else None

    def by_slack(self, channel: str, ts: str) -> dict[str, Any] | None:
        with self.connect() as conn:
            row = conn.execute(
                "SELECT * FROM ops_asks WHERE slack_channel=? AND slack_ts=?",
                (channel, ts)).fetchone()
            return dict(row) if row else None

    def events(self, ask_id: str) -> list[dict[str, Any]]:
        with self.connect() as conn:
            rows = conn.execute(
                "SELECT * FROM ops_ask_events WHERE ask_id=? ORDER BY id", (ask_id,)).fetchall()
            return [dict(r) for r in rows]

    def overdue(self, *, now: datetime | None = None) -> list[dict[str, Any]]:
        """Open asks past due. This is the watcher's query (j-w1)."""
        now = now or datetime.now(timezone.utc)
        with self.connect() as conn:
            rows = conn.execute(
                "SELECT * FROM ops_asks WHERE state IN ('open','ask') AND due_at <= ? "
                "ORDER BY due_at", (now.strftime("%Y-%m-%dT%H:%M:%SZ"),)).fetchall()
            return [dict(r) for r in rows]

    def digest(self, *, day: datetime | None = None) -> dict[str, Any]:
        """Daily digest line: asks by class / answered-by-code / escalated / held."""
        day = day or datetime.now(timezone.utc)
        start = day.replace(hour=0, minute=0, second=0, microsecond=0)
        end = start + timedelta(days=1)
        lo, hi = start.strftime("%Y-%m-%dT%H:%M:%SZ"), end.strftime("%Y-%m-%dT%H:%M:%SZ")
        with self.connect() as conn:
            by_class = {r["class"]: r["n"] for r in conn.execute(
                "SELECT class, COUNT(*) n FROM ops_asks WHERE created_at >= ? AND created_at < ? "
                "GROUP BY class ORDER BY n DESC", (lo, hi))}
            by_state = {r["state"]: r["n"] for r in conn.execute(
                "SELECT state, COUNT(*) n FROM ops_asks WHERE created_at >= ? AND created_at < ? "
                "GROUP BY state", (lo, hi))}
            answered_by_code = conn.execute(
                "SELECT COUNT(*) n FROM ops_asks WHERE created_at >= ? AND created_at < ? "
                "AND state='answered' AND COALESCE(verdict_source,'') <> 'agent'",
                (lo, hi)).fetchone()["n"]
            agent_handled = conn.execute(
                "SELECT COUNT(*) n FROM ops_asks WHERE created_at >= ? AND created_at < ? "
                "AND state='answered' AND verdict_source='agent'",
                (lo, hi)).fetchone()["n"]
            total = sum(by_class.values())
        return {"day": start.strftime("%Y-%m-%d"), "asks": total, "by_class": by_class,
                "by_state": by_state, "answered_by_code": answered_by_code,
                "agent_handled": agent_handled}
