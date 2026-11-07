#!/usr/bin/env python3
"""`request_comm_state`: the ONE append-only ledger of what we told a user about their request.

Why a second ledger when `verify_messages` exists (scripts/credit_review/verify_ledger.py):
that one is a per-CAMPAIGN lock ("this credit was asked about once, ever"), which is the wrong
unit for a status feed — the same request legitimately gets a message at every state it enters.
This ledger's unit is **(request_ref, state)**, plus the two clocks the captain's rule needs:
`last_told_at` and `next_due_at` (= last_told_at + 48 h while the request is open).

Every row is one EVENT (`observed`, `sending`, `sent`, `rejected`, `uncertain`, `held`,
`would_send`). "What does this request look like now" is the latest row per `request_ref`;
"when did we last tell the user" is the latest row with an outcome that reached them.
Append-only is enforced in the database itself (BEFORE UPDATE/DELETE triggers raise ABORT),
not by convention, and every row is sha256-chained to its predecessor so a deleted or edited
row is detectable (`verify`).

`sending` is written BEFORE the network call and is terminal for that (request, state) pair
for the rest of the run: a crash or a timeout after the POST can never produce a second
message. Only `rejected` (the transport answered "nothing landed") may be re-offered.

Store: /var/lib/hydra/request-comms/state.sqlite (dir 0700, file 0600 — under /var/lib because
the deploy rsync owns /opt/hydra).
"""
from __future__ import annotations

import hashlib
import json
import os
import sqlite3
import time
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any, Iterable

DEFAULT_PATH = "/var/lib/hydra/request-comms/state.sqlite"

# The outcome vocabulary. `sending` and `sent` both BLOCK a resend of the same (request, state).
OUTCOMES = ("observed", "sending", "sent", "rejected", "uncertain", "held", "would_send", "stopped")
TOLD_OUTCOMES = ("sent",)                     # a message the user actually received
# `sending` and `sent` are obvious; `uncertain` (the call happened, the answer was unreadable) counts
# too, because a second copy of a status line is worse than none. Only a clean `rejected` — the
# transport saying nothing landed — may be offered again on the next tick.
BLOCKING_OUTCOMES = ("sending", "sent", "uncertain")
SETTLED_OUTCOMES = ("sending", "sent", "uncertain", "rejected")

SCHEMA = """
CREATE TABLE IF NOT EXISTS request_comm_state (
  id              INTEGER PRIMARY KEY,
  at              TEXT NOT NULL,             -- ISO-8601 Z, the moment of the event
  request_type    TEXT NOT NULL,             -- credit | claim | merge | erasure | refund
  request_id      TEXT NOT NULL,             -- the owning table's id / ticket id
  request_ref     TEXT NOT NULL,             -- "<type>:<id>" (the ledger's unit)
  user_id         TEXT NOT NULL,
  channel_pref    TEXT DEFAULT '',           -- intercom | email | bell (the channel this event chose)
  state           TEXT DEFAULT '',           -- the request's state as observed
  last_told_state TEXT DEFAULT '',           -- the last state we told the user about (before this event)
  last_told_at    TEXT DEFAULT '',
  next_due_at     TEXT DEFAULT '',           -- last_told_at + 48 h while open
  waiting_on      TEXT DEFAULT '',           -- us | user | third_party:<x> | ''
  outcome         TEXT NOT NULL,
  line_key        TEXT DEFAULT '',           -- "<type>/<state>" of the line used (or would be)
  detail          TEXT DEFAULT '{}',         -- JSON: reasons, source, created_at, channel answers
  prev_sha        TEXT DEFAULT '',
  sha256          TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS request_comm_state_ref ON request_comm_state (request_ref, id);
CREATE INDEX IF NOT EXISTS request_comm_state_at ON request_comm_state (at);
CREATE INDEX IF NOT EXISTS request_comm_state_user ON request_comm_state (user_id, at);
CREATE TRIGGER IF NOT EXISTS request_comm_state_no_update BEFORE UPDATE ON request_comm_state
BEGIN SELECT RAISE(ABORT, 'request_comm_state is append-only'); END;
CREATE TRIGGER IF NOT EXISTS request_comm_state_no_delete BEFORE DELETE ON request_comm_state
BEGIN SELECT RAISE(ABORT, 'request_comm_state is append-only'); END;
"""

FIELDS = ("at", "request_type", "request_id", "request_ref", "user_id", "channel_pref", "state",
          "last_told_state", "last_told_at", "next_due_at", "waiting_on", "outcome", "line_key", "detail")


def stamp(now: float | None = None) -> str:
    return datetime.fromtimestamp(now if now is not None else time.time(), timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def day_of(ts: str) -> str:
    return (ts or "")[:10]


def iso(ts: str) -> datetime | None:
    """Parse an ISO-8601 Z stamp; None when unreadable (callers treat that as 'unknown', never as fresh)."""
    s = str(ts or "").strip()
    if not s:
        return None
    try:
        return datetime.fromisoformat(s.replace("Z", "+00:00"))
    except ValueError:
        return None


def due_at(last_told_at: str, open_request: bool, hours: int = 48) -> str:
    """next_due_at = last_told_at + 48 h while the request is open; a decided request is never due again."""
    if not open_request or not last_told_at:
        return ""
    at = iso(last_told_at)
    if at is None:
        return ""
    return (at + timedelta(hours=hours)).strftime("%Y-%m-%dT%H:%M:%SZ")


def ref(typ: str, rid: Any) -> str:
    return f"{typ}:{rid}"


class Store:
    """The append-only ledger. `path` is a directory (a sqlite file) or ':memory:'."""

    def __init__(self, path: str = DEFAULT_PATH, *, now: float | None = None) -> None:
        self.path = path
        self.now = now
        if path != ":memory:":
            Path(path).parent.mkdir(parents=True, exist_ok=True)
            try:
                os.chmod(Path(path).parent, 0o700)
            except OSError:
                pass
        self.db = sqlite3.connect(path if path == ":memory:" else f"file:{path}", uri=path != ":memory:")
        self.db.row_factory = sqlite3.Row
        self.db.executescript(SCHEMA)
        self.db.commit()
        if path != ":memory:":
            try:
                os.chmod(path, 0o600)
            except OSError:
                pass

    def close(self) -> None:
        self.db.close()

    # ---------- write ----------
    def append(self, *, request_type: str, request_id: str, user_id: str, outcome: str, **kw: Any) -> int:
        if outcome not in OUTCOMES:
            raise ValueError(f"unknown outcome {outcome!r}")
        row = {f: kw.get(f, "") for f in FIELDS}
        row["at"] = kw.get("at") or stamp(self.now)
        row["request_type"], row["request_id"] = str(request_type), str(request_id)
        row["request_ref"] = kw.get("request_ref") or ref(request_type, request_id)
        row["user_id"], row["outcome"] = str(user_id), outcome
        detail = row.get("detail") or {}
        row["detail"] = json.dumps(detail, sort_keys=True, separators=(",", ":")) if not isinstance(detail, str) else detail
        prev = self.db.execute("SELECT sha256 FROM request_comm_state ORDER BY id DESC LIMIT 1").fetchone()
        row["prev_sha"] = str(prev["sha256"]) if prev else ""
        payload = json.dumps([row[f] for f in FIELDS] + [row["prev_sha"]], separators=(",", ":"), sort_keys=True)
        row["sha256"] = hashlib.sha256(payload.encode()).hexdigest()
        cols = ", ".join(FIELDS + ("prev_sha", "sha256"))
        marks = ", ".join("?" * (len(FIELDS) + 2))
        cur = self.db.execute(f"INSERT INTO request_comm_state ({cols}) VALUES ({marks})",
                              [row[f] for f in FIELDS] + [row["prev_sha"], row["sha256"]])
        self.db.commit()
        return int(cur.lastrowid or 0)

    # ---------- read ----------
    def latest_per_ref(self, *, since: str = "") -> dict[str, sqlite3.Row]:
        sql = "SELECT * FROM request_comm_state"
        args: list[Any] = []
        if since:
            sql += " WHERE at >= ?"
            args.append(since)
        sql += " ORDER BY id"
        out: dict[str, sqlite3.Row] = {}
        for r in self.db.execute(sql, args):
            out[r["request_ref"]] = r
        return out

    def told_per_ref(self, *, since: str = "") -> dict[str, sqlite3.Row]:
        """The latest row per request that actually reached the user (`sent`).

        `since` bounds the working set: the ledger is append-only and grows for years, while a
        status feed only ever needs the recent past (the 48 h floor is 2 days). Unbounded reads
        are how a per-tick loop slows to a crawl eleven months from now.
        """
        sql, args = "SELECT * FROM request_comm_state WHERE outcome = 'sent'", []
        if since:
            sql += " AND at >= ?"
            args.append(since)
        out: dict[str, sqlite3.Row] = {}
        for r in self.db.execute(sql + " ORDER BY id", args):
            out[r["request_ref"]] = r
        return out

    def attempted_per_ref(self, *, since: str = "") -> dict[str, sqlite3.Row]:
        """The latest row per request that represents an ATTEMPT to tell the user something.

        `told_per_ref` answers "what did they last confirm receiving", which is what the 48 h floor
        and `last_told_state` need. This answers "when did we last try", which is what the provider
        idempotency key needs: an attempt whose reply was lost (`sending`/`uncertain`) still consumed
        a key at the provider, so the NEXT cycle must not reuse it. Same `since` bound, same reason.
        """
        marks = ",".join("?" * len(SETTLED_OUTCOMES))
        sql = f"SELECT * FROM request_comm_state WHERE outcome IN ({marks})"
        args: list[Any] = list(SETTLED_OUTCOMES)
        if since:
            sql += " AND at >= ?"
            args.append(since)
        out: dict[str, sqlite3.Row] = {}
        for r in self.db.execute(sql + " ORDER BY id", args):
            out[r["request_ref"]] = r
        return out

    def blocking_map(self, *, since: str = "") -> dict[str, dict[str, str]]:
        """request_ref -> {state: when it was claimed/sent}, one pass over the ledger.

        A pair is blocked by its LATEST settled row: `rejected` releases it (nothing landed), anything
        else keeps it claimed. That is what makes a crash mid-send safe without making a 5xx poison
        the request forever. The TIMESTAMP is load-bearing: a state may legitimately be told twice
        (`verifying -> need_you -> verifying`), so a claim only blocks the cycle it belongs to.
        """
        marks = ",".join("?" * len(SETTLED_OUTCOMES))
        last: dict[tuple[str, str], str] = {}
        sql = (f"SELECT request_ref, state, outcome, at FROM request_comm_state "
               f"WHERE outcome IN ({marks})")
        args = list(SETTLED_OUTCOMES)
        if since:
            sql += " AND at >= ?"
            args.append(since)
        for r in self.db.execute(sql + " ORDER BY id", args):
            last[(str(r["request_ref"]), str(r["state"]))] = (str(r["outcome"]), str(r["at"]))
        out: dict[str, dict[str, str]] = {}
        for (ref, state), (outcome, at) in last.items():
            if outcome in BLOCKING_OUTCOMES:
                out.setdefault(ref, {})[state] = at
        return out

    def blocking_states(self, request_ref: str) -> dict[str, str]:
        """{state: at} for the states this request was messaged about (or claimed for)."""
        return self.blocking_map().get(str(request_ref), {})

    def stopped(self) -> dict[str, set[str]]:
        """request_ref -> the states a human explicitly stopped (empty set = the whole request).

        `stop` used to be a synthetic `sent` row, which merely delayed the next reminder by 48 h and
        then let the floor fire again: the operator said "stop" and the machine said "noted, tomorrow".
        A `stopped` row is a standing instruction, read before planning.
        """
        out: dict[str, set[str]] = {}
        for r in self.db.execute("SELECT request_ref, state FROM request_comm_state "
                                 "WHERE outcome = 'stopped'"):
            out.setdefault(str(r["request_ref"]), set()).add(str(r["state"] or ""))
        return out

    def sent_rows(self, *, since: str = "") -> list[sqlite3.Row]:
        sql = "SELECT * FROM request_comm_state WHERE outcome = 'sent'"
        args: list[Any] = []
        if since:
            sql += " AND at >= ?"
            args.append(since)
        return list(self.db.execute(sql + " ORDER BY id", args))

    def rows(self, *, outcome: str = "", since: str = "") -> list[sqlite3.Row]:
        sql, args = "SELECT * FROM request_comm_state WHERE 1=1", []
        if outcome:
            sql += " AND outcome=?"
            args.append(outcome)
        if since:
            sql += " AND at >= ?"
            args.append(since)
        return list(self.db.execute(sql + " ORDER BY id", args))

    def sent_today(self, day: str) -> dict[str, int]:
        """user_id -> messages that may have reached them that UTC day (the 1/user/day counter).

        `uncertain` counts: the provider may have delivered and we cannot prove it did not, so the
        honest reading of "how many messages did this person get today" is sent + uncertain.
        """
        out: dict[str, int] = {}
        # Normalised in SQL so rows written before this rule are counted the same way: an
        # email-shaped key and its `email:` form are one person, never two.
        for r in self.db.execute(
                "SELECT CASE WHEN user_id LIKE 'email:%' THEN lower(user_id) "
                "WHEN instr(user_id,'@') > 0 THEN 'email:'||lower(user_id) ELSE user_id END k, "
                "count(*) n FROM request_comm_state "
                "WHERE outcome IN ('sent','uncertain') AND substr(at,1,10)=? GROUP BY k", (day,)):
            out[str(r["k"])] = int(r["n"])
        return out

    def last_sent_for_user(self, user_id: str) -> str:
        r = self.db.execute("SELECT max(at) a FROM request_comm_state WHERE outcome='sent' AND user_id=?",
                            (str(user_id),)).fetchone()
        return str((r["a"] if r else "") or "")

    def verify(self) -> list[str]:
        """Recompute the chain. Returns the ids that do not match (empty = intact)."""
        bad: list[str] = []
        prev = ""
        for r in self.db.execute("SELECT * FROM request_comm_state ORDER BY id"):
            row = {f: r[f] for f in FIELDS}
            payload = json.dumps([row[f] for f in FIELDS] + [prev], separators=(",", ":"), sort_keys=True)
            if hashlib.sha256(payload.encode()).hexdigest() != r["sha256"] or (r["prev_sha"] or "") != prev:
                bad.append(str(r["id"]))
            prev = str(r["sha256"])
        return bad


def rows_to_dicts(rows: Iterable[sqlite3.Row]) -> list[dict[str, Any]]:
    out = []
    for r in rows:
        d = {k: r[k] for k in r.keys()}
        try:
            d["detail"] = json.loads(d.get("detail") or "{}")
        except ValueError:
            d["detail"] = {}
        out.append(d)
    return out
