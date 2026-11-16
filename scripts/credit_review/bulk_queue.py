#!/usr/bin/env python3
"""The bulk send queue: one verdict per PERSON, a durable queue of send intents, N idempotent workers.

Operator doc: docs/credit-verification/bulk-send-queue.md. Policy: policies/bulk-send-queue.json.

Why it exists. The apply step it replaces is one long-lived subprocess per message that writes its outcomes when the
run ends, so a run that outlives its timeout loses them (policies/credit-verify-outbound.json `tick_cap`: 39 sends at
15:05Z and 79 at 17:24Z on 2026-11-04, both lost). Nothing here holds an outcome in memory:

  decide    ONE SQL statement over the `people` state table writes one verdict per (person, stage). No loop, no
            model. A `send` verdict is final; every other verdict is re-decided on the next pass.
  enqueue   ONE SQL statement turns `send` verdicts into jobs. The job key is sha256(user | stage | message class) and
            (user, stage) is UNIQUE, so a person is queued once per stage, ever, however often this runs.
  work      a worker claims a batch atomically (BEGIN IMMEDIATE: one writer, the SQLite equivalent of
            SELECT ... FOR UPDATE SKIP LOCKED), commits `attempted` BEFORE the send, and commits each outcome as the
            provider answers it. A worker killed at any point leaves rows the next `recover` settles:
              claimed, never attempted   -> queued again (nothing left this host)
              attempted, no outcome      -> re-presented under the SAME provider key when the route's provider
                                            de-duplicates on it (email: send-gateway is at-most-once per
                                            idempotency_key), else `uncertain`, which nothing ever re-sends

It is a TRANSPORT. It composes no copy (the person row carries the line a reviewed builder wrote, and every body
passes scripts/lib/copy_gate.py before it leaves), approves no credit, writes no credit status and never touches a
served number. The database refuses a job with no `send` verdict and a `sent` that was not `attempted` first.

Routes, in the captain's order (2026-11-12): our own chat, then email, then Intercom only where a thread lives
there. Chat and Intercom are `batch_capable: false` in the policy (the doc says why), so today a `send` verdict
means email, and a person reachable only by Intercom stays on scripts/intercom-verify-request.sh.

CLI:  bulk_queue.py init|load|decide|enqueue|work|drain|recover|status|verify|resolve --db FILE ...
      bulk_queue.py bench [--people N] [--workers N]     decisions/min and drain rate, scratch files only
      bulk_queue.py chaos [--jobs N] [--workers N]       kill -9 mid-batch, then prove no duplicate and no orphan
`bench` and `chaos` take no --db on purpose: a proof run must never be able to fill a ledger a real run reads.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import signal
import sqlite3
import subprocess
import sys
import tempfile
import threading
import time
from contextlib import contextmanager
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable, Iterable, Iterator

ROOT = Path(__file__).resolve().parents[2]
POLICY_PATH = ROOT / "policies" / "bulk-send-queue.json"
DEFAULT_DB = "/var/lib/hydra/bulk-send-queue/queue.sqlite"
KILL_FILE = "/etc/hydra/bulk-send-queue.disabled"
RULES_VERSION = 1
ROUTE_ORDER = ("chat", "email", "intercom")  # captain 2026-11-12: our chat, then email, then Intercom
MAX_ATTEMPTS = 5          # presentations of one job to a de-duplicating provider before a person looks at it
LEASE_S = 300.0
PENDING_RETRY_S = 900.0   # the gateway reconciles an unconfirmed send itself; ask again after this
HOLD_RETRY_S = 3600.0     # a held body or a held person is offered again after this (a hold is never a lock)
EXIT_KILLED = 3

SCHEMA = """
CREATE TABLE IF NOT EXISTS routes (
  route TEXT PRIMARY KEY, batch_capable INTEGER NOT NULL, idempotent INTEGER NOT NULL,
  not_before REAL NOT NULL DEFAULT 0, why TEXT NOT NULL DEFAULT '');
CREATE TABLE IF NOT EXISTS stage_classes (
  stage TEXT PRIMARY KEY, message_class TEXT NOT NULL, enabled INTEGER NOT NULL DEFAULT 1);
CREATE TABLE IF NOT EXISTS people (
  user_key TEXT PRIMARY KEY, user_id TEXT NOT NULL DEFAULT '', email TEXT NOT NULL DEFAULT '',
  email_confirmed INTEGER NOT NULL DEFAULT 0, stage TEXT NOT NULL, open_rows INTEGER NOT NULL DEFAULT 0,
  hold TEXT NOT NULL DEFAULT '', chat_reachable INTEGER NOT NULL DEFAULT 0,
  intercom_thread TEXT NOT NULL DEFAULT '', body TEXT NOT NULL DEFAULT '', subject TEXT NOT NULL DEFAULT '',
  data_json TEXT NOT NULL DEFAULT '{}', copy_data_json TEXT NOT NULL DEFAULT '[]', loaded_at REAL NOT NULL);
CREATE TABLE IF NOT EXISTS person_rows (
  request_id TEXT PRIMARY KEY, user_key TEXT NOT NULL);
CREATE INDEX IF NOT EXISTS person_rows_user ON person_rows(user_key);
CREATE TABLE IF NOT EXISTS told (
  user_key TEXT NOT NULL, stage TEXT NOT NULL, source TEXT NOT NULL DEFAULT '', PRIMARY KEY (user_key, stage));
CREATE TABLE IF NOT EXISTS verdicts (
  user_key TEXT NOT NULL, stage TEXT NOT NULL, verdict TEXT NOT NULL CHECK (verdict IN ('send','skip','hold')),
  reason TEXT NOT NULL, message_class TEXT NOT NULL DEFAULT '', route TEXT NOT NULL DEFAULT '',
  rules_version INTEGER NOT NULL, decided_at REAL NOT NULL, PRIMARY KEY (user_key, stage));
CREATE TABLE IF NOT EXISTS jobs (
  idem_key TEXT PRIMARY KEY, user_key TEXT NOT NULL, stage TEXT NOT NULL, message_class TEXT NOT NULL,
  route TEXT NOT NULL,
  state TEXT NOT NULL CHECK (state IN ('queued','claimed','attempted','sent','rejected','uncertain')),
  worker TEXT NOT NULL DEFAULT '', lease_until REAL NOT NULL DEFAULT 0, not_before REAL NOT NULL DEFAULT 0,
  attempts INTEGER NOT NULL DEFAULT 0, provider_id TEXT NOT NULL DEFAULT '', reason TEXT NOT NULL DEFAULT '',
  enqueued_at REAL NOT NULL, attempted_at REAL NOT NULL DEFAULT 0, done_at REAL NOT NULL DEFAULT 0,
  UNIQUE (user_key, stage),
  FOREIGN KEY (user_key, stage) REFERENCES verdicts(user_key, stage));
CREATE INDEX IF NOT EXISTS jobs_state ON jobs(state, route, not_before);
CREATE TABLE IF NOT EXISTS job_events (
  seq INTEGER PRIMARY KEY AUTOINCREMENT, idem_key TEXT NOT NULL, at REAL NOT NULL, worker TEXT NOT NULL,
  event TEXT NOT NULL, detail TEXT NOT NULL DEFAULT '');
CREATE INDEX IF NOT EXISTS job_events_key ON job_events(idem_key);
CREATE VIEW IF NOT EXISTS row_verdicts AS
  SELECT r.request_id, v.user_key, v.stage, v.verdict, v.reason, v.message_class, v.route
    FROM person_rows r JOIN people p ON p.user_key = r.user_key
    JOIN verdicts v ON v.user_key = p.user_key AND v.stage = p.stage;
CREATE TRIGGER IF NOT EXISTS verdict_send_is_final BEFORE UPDATE ON verdicts WHEN OLD.verdict = 'send'
  BEGIN SELECT RAISE(ABORT, 'bulk_queue: a send verdict is final'); END;
CREATE TRIGGER IF NOT EXISTS verdict_send_no_delete BEFORE DELETE ON verdicts WHEN OLD.verdict = 'send'
  BEGIN SELECT RAISE(ABORT, 'bulk_queue: a send verdict is final'); END;
CREATE TRIGGER IF NOT EXISTS job_needs_send_verdict BEFORE INSERT ON jobs
  WHEN NOT EXISTS (SELECT 1 FROM verdicts v WHERE v.user_key = NEW.user_key AND v.stage = NEW.stage
                      AND v.verdict = 'send' AND v.message_class = NEW.message_class AND v.route = NEW.route)
  BEGIN SELECT RAISE(ABORT, 'bulk_queue: no send verdict for this job'); END;
CREATE TRIGGER IF NOT EXISTS job_starts_queued BEFORE INSERT ON jobs WHEN NEW.state <> 'queued'
  BEGIN SELECT RAISE(ABORT, 'bulk_queue: a job starts queued'); END;
DROP TRIGGER IF EXISTS job_no_delete;
CREATE TRIGGER IF NOT EXISTS job_no_delete BEFORE DELETE ON jobs
  WHEN OLD.state <> 'queued' OR OLD.attempted_at > 0 OR substr(OLD.reason, 1, 12) <> 'copy_review_'
  BEGIN SELECT RAISE(ABORT, 'bulk_queue: a job is never deleted'); END;
CREATE TRIGGER IF NOT EXISTS job_terminal_is_final BEFORE UPDATE ON jobs WHEN OLD.state IN ('sent','rejected')
  BEGIN SELECT RAISE(ABORT, 'bulk_queue: a settled job is never rewritten'); END;
CREATE TRIGGER IF NOT EXISTS job_sent_needs_attempt BEFORE UPDATE OF state ON jobs
  WHEN NEW.state = 'sent' AND (OLD.state NOT IN ('attempted','uncertain') OR OLD.attempted_at <= 0)
  BEGIN SELECT RAISE(ABORT, 'bulk_queue: sent without a recorded attempt'); END;
CREATE TRIGGER IF NOT EXISTS job_attempt_needs_claim BEFORE UPDATE OF state ON jobs
  WHEN NEW.state = 'attempted' AND OLD.state <> 'claimed'
  BEGIN SELECT RAISE(ABORT, 'bulk_queue: attempted without a claim'); END;
CREATE TRIGGER IF NOT EXISTS job_events_no_update BEFORE UPDATE ON job_events
  BEGIN SELECT RAISE(ABORT, 'bulk_queue: the event log is append-only'); END;
CREATE TRIGGER IF NOT EXISTS job_events_no_delete BEFORE DELETE ON job_events
  BEGIN SELECT RAISE(ABORT, 'bulk_queue: the event log is append-only'); END;
"""

# The whole decision: a rank-ordered predicate set over the state table. First match wins. Unmeasured is never
# "clear": a builder that could not read the fraud lens writes hold='unmeasured', which is a hold like any other.
DECIDE_SQL = """
WITH facts AS (
  SELECT p.user_key, p.stage, p.hold, p.open_rows, p.body, COALESCE(c.message_class, '') AS message_class,
         EXISTS (SELECT 1 FROM told t WHERE t.user_key = p.user_key AND t.stage = p.stage) AS told,
         CASE WHEN p.chat_reachable = 1
                   AND EXISTS (SELECT 1 FROM routes r WHERE r.route = 'chat' AND r.batch_capable = 1) THEN 'chat'
              WHEN p.email <> '' AND p.email_confirmed = 1 AND p.user_id <> ''
                   AND EXISTS (SELECT 1 FROM routes r WHERE r.route = 'email' AND r.batch_capable = 1) THEN 'email'
              WHEN p.intercom_thread <> ''
                   AND EXISTS (SELECT 1 FROM routes r WHERE r.route = 'intercom' AND r.batch_capable = 1)
                   THEN 'intercom'
              ELSE '' END AS route
    FROM people p LEFT JOIN stage_classes c ON c.stage = p.stage AND c.enabled = 1
), ranked AS (
  SELECT facts.*, CASE
           WHEN hold <> '' THEN 'hold:' || hold
           WHEN told THEN 'skip:already_told'
           WHEN open_rows <= 0 THEN 'skip:nothing_open'
           WHEN message_class = '' THEN 'hold:no_class_for_stage'
           WHEN body = '' THEN 'hold:no_copy'
           WHEN route = '' THEN 'hold:no_route'
           ELSE 'send:predicates_clear' END AS vr
    FROM facts
)
INSERT INTO verdicts (user_key, stage, verdict, reason, message_class, route, rules_version, decided_at)
SELECT user_key, stage, substr(vr, 1, instr(vr, ':') - 1), substr(vr, instr(vr, ':') + 1),
       CASE WHEN vr LIKE 'send:%' THEN message_class ELSE '' END,
       CASE WHEN vr LIKE 'send:%' THEN route ELSE '' END, :version, :now
  FROM ranked WHERE true
ON CONFLICT (user_key, stage) DO UPDATE SET
  verdict = excluded.verdict, reason = excluded.reason, message_class = excluded.message_class,
  route = excluded.route, rules_version = excluded.rules_version, decided_at = excluded.decided_at
  WHERE verdicts.verdict <> 'send'
"""

ENQUEUE_SQL = """
INSERT INTO jobs (idem_key, user_key, stage, message_class, route, state, enqueued_at)
SELECT bq_idem(v.user_key, v.stage, v.message_class), v.user_key, v.stage, v.message_class, v.route, 'queued', :now
  FROM verdicts v
 WHERE v.verdict = 'send'
   AND NOT EXISTS (SELECT 1 FROM jobs j WHERE j.user_key = v.user_key AND j.stage = v.stage)
"""

ENQUEUE_SCOPED_SQL = """
INSERT INTO jobs (idem_key, user_key, stage, message_class, route, state, enqueued_at)
SELECT bq_idem(v.user_key, v.stage, v.message_class), v.user_key, v.stage, v.message_class, v.route, 'queued', :now
  FROM verdicts v
 WHERE v.verdict = 'send'
   AND v.user_key IN (SELECT value FROM json_each(:only))
   AND NOT EXISTS (SELECT 1 FROM jobs j WHERE j.user_key = v.user_key AND j.stage = v.stage)
"""


def idem_key(user_key: str, stage: str, message_class: str) -> str:
    """The job key. One per (user, stage, message class); UNIQUE(user, stage) then makes it one per stage."""
    return hashlib.sha256(f"{user_key}\x1f{stage}\x1f{message_class}".encode()).hexdigest()


def provider_key(message_class: str, user_id: str) -> str:
    """The key the provider de-duplicates on. Deliberately the shape scripts/paid-status/email_route.py already
    sends (`credit-status:<campaign>:<user id>`), so send-gateway answers `duplicate` for a person either sender
    already mailed in that class, and its `credit-status:` prefix keeps the send inside the warm-up batch ceiling."""
    return f"credit-status:{message_class}:{user_id}"


def connect(path: str | os.PathLike, *, init: bool = False) -> sqlite3.Connection:
    if init:
        Path(path).parent.mkdir(parents=True, exist_ok=True)
    db = sqlite3.connect(str(path), timeout=120, isolation_level=None)
    db.execute("PRAGMA busy_timeout = 120000")
    db.execute("PRAGMA foreign_keys = ON")
    db.create_function("bq_idem", 3, idem_key, deterministic=True)
    if init:
        db.execute("PRAGMA journal_mode = WAL")
        db.executescript(SCHEMA)
    db.execute("PRAGMA synchronous = FULL")
    return db


@contextmanager
def tx(db: sqlite3.Connection) -> Iterator[sqlite3.Connection]:
    """One writer at a time. BEGIN IMMEDIATE takes the write lock up front, so a claim reads and marks its rows
    with no other writer between the two: two workers can never claim the same job."""
    db.execute("BEGIN IMMEDIATE")
    try:
        yield db
    except BaseException:
        db.execute("ROLLBACK")
        raise
    db.execute("COMMIT")


def load_policy(path: str | os.PathLike | None = None) -> dict:
    return json.loads(Path(path or POLICY_PATH).read_text(encoding="utf-8"))


def apply_policy(db: sqlite3.Connection, policy: dict) -> None:
    """Copy the policy's routes and stage classes into the tables DECIDE_SQL joins. A route's `not_before` (a
    ceiling the provider told us about) survives a reload."""
    routes = policy.get("routes") or {}
    with tx(db):
        for name in ROUTE_ORDER:
            r = routes.get(name) or {}
            db.execute(
                "INSERT INTO routes (route, batch_capable, idempotent, why) VALUES (?,?,?,?) "
                "ON CONFLICT(route) DO UPDATE SET batch_capable=excluded.batch_capable, "
                "idempotent=excluded.idempotent, why=excluded.why",
                (name, int(bool(r.get("batch_capable"))), int(bool(r.get("idempotent"))), str(r.get("why") or "")))
        db.execute("UPDATE stage_classes SET enabled = 0")
        for stage, cls in (policy.get("stages") or {}).items():
            db.execute("INSERT INTO stage_classes (stage, message_class, enabled) VALUES (?,?,1) "
                       "ON CONFLICT(stage) DO UPDATE SET message_class=excluded.message_class, enabled=1",
                       (str(stage), str(cls)))


def load_people(db: sqlite3.Connection, rows: Iterable[dict], *, now: float | None = None) -> int:
    """Upsert the state table: one row per person, the requests that are theirs, and what any sender already told
    them. The builder that fills it owns identity, the fraud lens and the copy; this only stores what it measured."""
    now = time.time() if now is None else now
    n = 0
    with tx(db):
        for p in rows:
            uk, stage = str(p.get("user_key") or "").strip(), str(p.get("stage") or "").strip()
            if not uk or not stage:
                raise ValueError(f"person row {n + 1}: user_key and stage are required")
            ids = [str(i) for i in (p.get("request_ids") or [])]
            db.execute(
                "INSERT INTO people (user_key, user_id, email, email_confirmed, stage, open_rows, hold, "
                "chat_reachable, intercom_thread, body, subject, data_json, copy_data_json, loaded_at) "
                "VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?) ON CONFLICT(user_key) DO UPDATE SET "
                "user_id=excluded.user_id, email=excluded.email, email_confirmed=excluded.email_confirmed, "
                "stage=excluded.stage, open_rows=excluded.open_rows, hold=excluded.hold, "
                "chat_reachable=excluded.chat_reachable, intercom_thread=excluded.intercom_thread, "
                "body=excluded.body, subject=excluded.subject, data_json=excluded.data_json, "
                "copy_data_json=excluded.copy_data_json, loaded_at=excluded.loaded_at",
                (uk, str(p.get("user_id") or ""), str(p.get("email") or "").strip().lower(),
                 int(bool(p.get("email_confirmed"))), stage, int(p.get("open_rows", len(ids)) or 0),
                 str(p.get("hold") or ""), int(bool(p.get("chat_reachable"))),
                 str(p.get("intercom_thread") or ""), str(p.get("body") or ""), str(p.get("subject") or ""),
                 json.dumps(p.get("data") or {}, sort_keys=True), json.dumps(list(p.get("copy_data") or [])), now))
            db.execute("DELETE FROM person_rows WHERE user_key = ?", (uk,))
            db.executemany("INSERT OR REPLACE INTO person_rows (request_id, user_key) VALUES (?,?)",
                           [(i, uk) for i in ids])
            db.executemany("INSERT OR IGNORE INTO told (user_key, stage, source) VALUES (?,?,?)",
                           [(uk, str(s), "import") for s in (p.get("told") or [])])
            n += 1
    return n


def decide(db: sqlite3.Connection, *, now: float | None = None) -> dict:
    """One verdict per person, in one statement. Returns the counts and the seconds the statement took."""
    now = time.time() if now is None else now
    t0 = time.perf_counter()
    with tx(db):
        db.execute(DECIDE_SQL, {"version": RULES_VERSION, "now": now})
    secs = time.perf_counter() - t0
    people = db.execute("SELECT COUNT(*) FROM people").fetchone()[0]
    by = {f"{v}:{r}": n for v, r, n in db.execute(
        "SELECT v.verdict, v.reason, COUNT(*) FROM verdicts v JOIN people p "
        "ON p.user_key = v.user_key AND p.stage = v.stage GROUP BY 1, 2 ORDER BY 1, 2")}
    rows = db.execute("SELECT COUNT(*) FROM row_verdicts").fetchone()[0]
    return {"people": people, "rows_covered": rows, "seconds": round(secs, 4), "verdicts": by,
            "decisions_per_min": int(people / secs * 60) if secs > 0 else None}


def enqueue(db: sqlite3.Connection, *, now: float | None = None, only: Iterable[str] | None = None) -> dict:
    """Every `send` verdict that has no job yet becomes one queued job; `only` narrows that to the named people,
    which is how a caller makes a job exist only for someone holding a live claim. Running it again adds nothing."""
    now = time.time() if now is None else now
    t0 = time.perf_counter()
    with tx(db):
        if only is None:
            added = db.execute(ENQUEUE_SQL, {"now": now}).rowcount
        else:
            added = db.execute(ENQUEUE_SCOPED_SQL,
                               {"now": now, "only": json.dumps(sorted(set(only)))}).rowcount
    return {"enqueued": added, "seconds": round(time.perf_counter() - t0, 4)}


# ------------------------------------------------------------------------------------------------ the worker side
@dataclass
class Job:
    idem_key: str
    user_key: str
    stage: str
    message_class: str
    route: str
    attempts: int
    attempted_before: bool = False  # a dead worker may already have sent it: only the provider knows
    user_id: str = ""
    email: str = ""
    body: str = ""
    subject: str = ""
    data: dict | None = None
    copy_data: tuple = ()

    @property
    def provider_key(self) -> str:
        return provider_key(self.message_class, self.user_id)


@dataclass
class Outcome:
    """What the provider said about one job.
       sent      it confirmed delivery to itself (provider_id is its id)
       rejected  it answered that nothing was sent and never will be under this key (terminal)
       defer     nothing left this host or the provider kept no record: offer the job again after delay_s
       pending   the call may have landed: the job stays `attempted` and is settled by `recover`"""
    kind: str
    reason: str = ""
    provider_id: str = ""
    delay_s: float = 0.0
    pause_route_until: float = 0.0


def _event(db: sqlite3.Connection, key: str, worker: str, event: str, detail: str = "", now: float = 0.0) -> None:
    db.execute("INSERT INTO job_events (idem_key, at, worker, event, detail) VALUES (?,?,?,?,?)",
               (key, now or time.time(), worker, event, detail[:300]))


def recover(db: sqlite3.Connection, *, now: float | None = None) -> dict:
    """Settle what a dead worker left. Safe to run from every worker on every loop.

    A `claimed` row never reached the send, so it is simply queued again. An `attempted` row may have been sent:
    it goes back to the queue only when the route's provider de-duplicates on our key (the re-presentation is then
    answered with the first send's record), and only MAX_ATTEMPTS times; otherwise it becomes `uncertain`, which
    no code path sends again - a person reads the provider and records what happened with `resolve`."""
    now = time.time() if now is None else now
    out = {"requeued": 0, "represent": 0, "uncertain": 0}
    if db.execute("SELECT 1 FROM jobs WHERE state IN ('claimed','attempted') AND lease_until < ? LIMIT 1",
                  (now,)).fetchone() is None:
        return out  # the common case takes no write lock
    with tx(db):
        for (key,) in db.execute("SELECT idem_key FROM jobs WHERE state='claimed' AND lease_until < ?",
                                 (now,)).fetchall():
            db.execute("UPDATE jobs SET state='queued', worker='', reason='lease_expired' WHERE idem_key=?", (key,))
            _event(db, key, "recover", "requeued", "claimed, never attempted", now)
            out["requeued"] += 1
        stale = db.execute(
            "SELECT j.idem_key, j.attempts, COALESCE(r.idempotent, 0) FROM jobs j LEFT JOIN routes r "
            "ON r.route = j.route WHERE j.state='attempted' AND j.lease_until < ?", (now,)).fetchall()
        for key, attempts, idempotent in stale:
            if idempotent and attempts < MAX_ATTEMPTS:
                # attempted -> claimed -> ... is refused by the trigger order, so the row re-enters as queued and
                # keeps attempted_at: the next presentation uses the same provider key.
                db.execute("UPDATE jobs SET state='queued', worker='', reason='represent' WHERE idem_key=?", (key,))
                _event(db, key, "recover", "represent", "attempted, no outcome: same key again", now)
                out["represent"] += 1
            else:
                why = "unconfirmed_after_max_attempts" if idempotent else "attempted_no_outcome"
                db.execute("UPDATE jobs SET state='uncertain', reason=?, done_at=? WHERE idem_key=?",
                           (why, now, key))
                _event(db, key, "recover", "uncertain", why, now)
                out["uncertain"] += 1
    return out


def claim(db: sqlite3.Connection, worker: str, n: int, *, route: str, lease_s: float = LEASE_S,
          now: float | None = None) -> list[Job]:
    """Atomically take up to `n` queued jobs for `route`. The read and the mark are one write transaction."""
    now = time.time() if now is None else now
    with tx(db):
        rows = db.execute(
            "SELECT j.idem_key, j.user_key, j.stage, j.message_class, j.route, j.attempts, j.attempted_at "
            "FROM jobs j "
            "JOIN routes r ON r.route = j.route WHERE j.state='queued' AND j.route = ? AND j.not_before <= ? "
            "AND r.not_before <= ? ORDER BY j.enqueued_at, j.idem_key LIMIT ?", (route, now, now, n)).fetchall()
        for row in rows:
            db.execute("UPDATE jobs SET state='claimed', worker=?, lease_until=?, attempts=attempts+1 "
                       "WHERE idem_key=? AND state='queued'", (worker, now + lease_s, row[0]))
            _event(db, row[0], worker, "claimed", "", now)
    return [Job(*row[:5], attempts=row[5] + 1, attempted_before=row[6] > 0) for row in rows]


def cancel_held(db: sqlite3.Connection, *, user_key: str, stage: str, reason: str, now: float) -> bool:
    """Cancel a copy-gate-held job whose ledger claim has been given back: no claim, no job. Cancels only while
    the job is still queued and never attempted, in one transaction, so a job a worker already took keeps
    running and settles normally. The row leaves `jobs` so the person's next claim may enqueue a fresh one."""
    with tx(db):
        row = db.execute("SELECT idem_key, state, attempted_at FROM jobs WHERE user_key = ? AND stage = ?",
                         (user_key, stage)).fetchone()
        if row is None or row[1] != "queued" or row[2] > 0:
            return False
        _event(db, row[0], "", "cancelled", reason, now)
        return db.execute("DELETE FROM jobs WHERE idem_key = ? AND state = 'queued' AND attempted_at = 0",
                          (row[0],)).rowcount == 1


def _release(db: sqlite3.Connection, job: Job, worker: str, reason: str, delay_s: float, now: float) -> None:
    db.execute("UPDATE jobs SET state='queued', worker='', reason=?, not_before=?, attempts=attempts-1 "
               "WHERE idem_key=? AND state='claimed'", (reason[:300], now + delay_s, job.idem_key))
    _event(db, job.idem_key, worker, "released", reason, now)


def precheck(db: sqlite3.Connection, jobs: list[Job], worker: str, hold: Callable[[Job], str], *,
             now: float | None = None) -> list[Job]:
    """Re-read each claimed job's person and ask the route whether it may go. Returns the jobs that may.

    A person whose stage moved on since the verdict gets no message for the old stage (terminal `stale_stage`), and
    so does one another sender has told about this stage since the job was queued (terminal `already_told`: a send
    verdict is final, so `decide` cannot take it back, and `told` is never unwritten); a hold that appeared since,
    or a body the copy gate has not approved, gives the claim back for a later run. A job
    a dead worker already attempted is different: it may have been sent, so one that may no longer go becomes
    `uncertain` (we will not send it, and we do not claim it was not sent)."""
    now = time.time() if now is None else now
    ready: list[Job] = []
    facts: dict[str, tuple] = {}
    for job in jobs:
        facts[job.idem_key] = db.execute(
            "SELECT p.user_id, p.email, p.body, p.subject, p.data_json, p.copy_data_json, p.hold, "
            "(SELECT v.verdict FROM verdicts v WHERE v.user_key = p.user_key AND v.stage = ?), "
            "EXISTS (SELECT 1 FROM told t WHERE t.user_key = p.user_key AND t.stage = p.stage) "
            "FROM people p WHERE p.user_key = ? AND p.stage = ?", (job.stage, job.user_key, job.stage)).fetchone()
    asked: dict[tuple, str] = {}
    held: list[tuple[Job, str, str]] = []
    for job in jobs:
        f = facts[job.idem_key]
        if f is None:
            held.append((job, "rejected", "stale_stage"))
            continue
        job.user_id, job.email, job.body, job.subject = f[0], f[1], f[2], f[3]
        job.data, job.copy_data = json.loads(f[4] or "{}"), tuple(json.loads(f[5] or "[]"))
        if f[7] != "send":
            held.append((job, "rejected", "no_send_verdict"))
        elif f[8]:  # told by another sender since the verdict: one message per user per stage, ever
            held.append((job, "rejected", "already_told"))
        elif f[6]:
            held.append((job, "release", f"hold:{f[6]}"))
        else:
            sig = (job.message_class, job.subject, job.body, job.copy_data)
            if sig not in asked:  # the same bytes in one batch are asked once
                asked[sig] = hold(job)
            if asked[sig]:
                held.append((job, "release", asked[sig]))
            else:
                ready.append(job)
    if held:
        with tx(db):
            for job, how, reason in held:
                if how == "release":
                    _release(db, job, worker, reason, HOLD_RETRY_S, now)
                else:
                    state = "uncertain" if job.attempted_before else "rejected"
                    db.execute("UPDATE jobs SET state=?, reason=?, done_at=? WHERE idem_key=? "
                               "AND state='claimed'", (state, reason, now, job.idem_key))
                    _event(db, job.idem_key, worker, state, reason, now)
    return ready


def mark_attempted(db: sqlite3.Connection, jobs: list[Job], worker: str, *, lease_s: float = LEASE_S,
                   now: float | None = None) -> list[Job]:
    """Commit `attempted` for the whole batch BEFORE anything is sent. Returns the jobs this worker still holds."""
    now = time.time() if now is None else now
    mine: list[Job] = []
    with tx(db):
        for job in jobs:
            cur = db.execute("UPDATE jobs SET state='attempted', attempted_at=?, lease_until=? "
                             "WHERE idem_key=? AND state='claimed' AND worker=?",
                             (now, now + lease_s, job.idem_key, worker))
            if cur.rowcount:
                _event(db, job.idem_key, worker, "attempted", job.provider_key, now)
                mine.append(job)
    return mine


def record(db: sqlite3.Connection, job: Job, out: Outcome, worker: str, *, now: float | None = None) -> bool:
    """Commit one outcome the moment the provider answers it. False when the row was already settled elsewhere."""
    now = time.time() if now is None else now
    key = job.idem_key
    with tx(db):
        if out.pause_route_until:
            db.execute("UPDATE routes SET not_before = MAX(not_before, ?) WHERE route = ?",
                       (out.pause_route_until, job.route))
        if out.kind == "sent":
            cur = db.execute(
                "UPDATE jobs SET state='sent', provider_id=?, reason=?, done_at=? WHERE idem_key=? AND "
                "(state='attempted' OR (state='uncertain' AND worker=?))",
                (out.provider_id, out.reason[:300], now, key, worker))
        elif out.kind == "rejected":
            cur = db.execute("UPDATE jobs SET state='rejected', reason=?, done_at=? WHERE idem_key=? AND "
                             "state='attempted'", (out.reason[:300], now, key))
        elif out.kind == "defer":
            cur = db.execute("UPDATE jobs SET state='queued', worker='', reason=?, not_before=?, "
                             "attempts=attempts-1 WHERE idem_key=? AND state='attempted'",
                             (out.reason[:300], now + out.delay_s, key))
        elif out.kind == "pending":
            cur = db.execute("UPDATE jobs SET reason=?, lease_until=?, worker='' WHERE idem_key=? "
                             "AND state='attempted'",
                             (out.reason[:300], now + (out.delay_s or PENDING_RETRY_S), key))
        else:
            raise ValueError(f"unknown outcome kind {out.kind!r}")
        ok = bool(cur.rowcount)
        _event(db, key, worker, out.kind if ok else "late_outcome",
               f"{out.provider_id} {out.reason}".strip(), now)
    return ok


def heartbeat(db: sqlite3.Connection, worker: str, lease_s: float, *, now: float | None = None) -> None:
    """Push this worker's leases out while it is alive and answering, so only a dead worker's rows expire."""
    now = time.time() if now is None else now
    with tx(db):
        db.execute("UPDATE jobs SET lease_until=? WHERE worker=? AND state IN ('claimed','attempted') "
                   "AND lease_until < ?", (now + lease_s, worker, now + lease_s))


def work(db: sqlite3.Connection, route: Any, worker: str, *, batch: int = 25, lease_s: float = LEASE_S,
         max_jobs: int = 0, idle_exit: bool = True, kill_file: str = KILL_FILE) -> dict:
    """One worker: recover, claim, check, mark attempted, send, record. It holds nothing between loops."""
    done = {"claimed": 0, "sent": 0, "rejected": 0, "defer": 0, "pending": 0, "released": 0, "killed": False}
    while not max_jobs or done["claimed"] < max_jobs:
        if os.path.exists(kill_file):
            done["killed"] = True
            break
        recover(db)
        jobs = claim(db, worker, batch, route=route.name, lease_s=lease_s)
        if not jobs:
            if idle_exit:
                break
            time.sleep(1.0)
            continue
        done["claimed"] += len(jobs)
        ready = mark_attempted(db, precheck(db, jobs, worker, route.hold), worker, lease_s=lease_s)
        done["released"] += len(jobs) - len(ready)
        by_key = {j.idem_key: j for j in ready}
        beat = time.time()
        for key, out in route.send(ready):
            if key in by_key and record(db, by_key.pop(key), out, worker):
                done[out.kind] += 1
            if time.time() - beat > lease_s / 4:
                heartbeat(db, worker, lease_s)
                beat = time.time()
        for job in by_key.values():  # the provider said nothing about these: they may have landed
            record(db, job, Outcome("pending", "no answer for this job"), worker)
            done["pending"] += 1
    return done


# ------------------------------------------------------------------------------------------------------ routes
class FakeProvider:
    """A provider on disk, outside every worker, so a killed worker cannot take its record with it. `dedupe` models
    send-gateway (at-most-once per key); without it every presentation is a delivery, as with a provider that
    keeps no key. `calls` records every presentation either way."""

    def __init__(self, path: str | os.PathLike, *, dedupe: bool = True, init: bool = False):
        self.dedupe = dedupe
        self.db = sqlite3.connect(str(path), timeout=120, isolation_level=None)
        self.db.execute("PRAGMA busy_timeout = 120000")
        if init:
            self.db.execute("PRAGMA journal_mode = WAL")
            self.db.executescript(
                "CREATE TABLE IF NOT EXISTS calls (seq INTEGER PRIMARY KEY AUTOINCREMENT, key TEXT, at REAL);"
                "CREATE TABLE IF NOT EXISTS deliveries (seq INTEGER PRIMARY KEY AUTOINCREMENT, key TEXT, at REAL);"
                "CREATE INDEX IF NOT EXISTS deliveries_key ON deliveries(key);")

    def send(self, key: str) -> tuple[str, bool]:
        now = time.time()
        self.db.execute("BEGIN IMMEDIATE")
        self.db.execute("INSERT INTO calls (key, at) VALUES (?,?)", (key, now))
        first = self.db.execute("SELECT seq FROM deliveries WHERE key = ? ORDER BY seq LIMIT 1", (key,)).fetchone()
        if first is None or not self.dedupe:
            seq = self.db.execute("INSERT INTO deliveries (key, at) VALUES (?,?)", (key, now)).lastrowid
        else:
            seq = first[0]
        self.db.execute("COMMIT")
        return f"fake-{seq}", first is not None

    def counts(self) -> dict:
        q = self.db.execute
        return {"calls": q("SELECT COUNT(*) FROM calls").fetchone()[0],
                "deliveries": q("SELECT COUNT(*) FROM deliveries").fetchone()[0],
                "keys_delivered": q("SELECT COUNT(DISTINCT key) FROM deliveries").fetchone()[0],
                "keys_delivered_twice": q("SELECT COUNT(*) FROM (SELECT key FROM deliveries GROUP BY key "
                                          "HAVING COUNT(*) > 1)").fetchone()[0]}


class FakeRoute:
    """The bench and chaos route. `latency_s` is the provider's time per send."""

    def __init__(self, name: str, provider: FakeProvider, *, latency_s: float = 0.0):
        self.name, self.provider, self.latency_s = name, provider, latency_s

    def hold(self, job: Job) -> str:  # noqa: ARG002 - no copy leaves a fake route
        return ""

    def send(self, jobs: list[Job]) -> Iterator[tuple[str, Outcome]]:
        for job in jobs:
            if self.latency_s:
                time.sleep(self.latency_s)
            pid, dup = self.provider.send(job.provider_key)
            yield job.idem_key, Outcome("sent", "duplicate" if dup else "", pid)


# One exec for a whole claimed batch: payloads in as JSON lines, one answer line out per payload as it completes.
# The template check is scripts/request_comms/channels.py SEND_JS's, unchanged: the reviewed template is pinned by
# the sha256 of its source and a pod whose live template differs posts nothing for that key.
BATCH_JS = r"""
let s='';process.stdin.on('data',d=>s+=d).on('end',async()=>{
 const fs=require('fs'),path=require('path'),crypto=require('crypto');
 const out=o=>console.log(JSON.stringify(o));
 const lines=s.split('\n').filter(x=>x.trim());
 let head={};try{head=JSON.parse(lines.shift()||'{}');}catch(e){}
 const tok=(process.env.INTERNAL_TOKENS||'').split(',').map(x=>x.trim()).find(x=>x.startsWith('admin:'));
 const dir=process.env.TEMPLATES_DIR||path.resolve(process.cwd(),'..','..','templates');
 const live={};
 const liveSha=key=>{if(key in live)return live[key];let v;
  try{const rd=f=>JSON.parse(fs.readFileSync(path.join(dir,f),'utf8')).keys||{};
   const found=[rd('registry.json'),rd('native.json')].filter(k=>Object.prototype.hasOwnProperty.call(k,key));
   if(found.length!==1)v={err:'template_unreadable: '+found.length+' entries for the key'};
   else{const e=found[0][key];
    if(typeof e.subject!=='string'||typeof e.html!=='string'||typeof e.text!=='string')v={err:'template_unreadable: entry shape'};
    else{const h=crypto.createHash('sha256');
     for(const part of [Buffer.from(e.subject,'utf8'),Buffer.from(String(e.preview_text||''),'utf8'),
                        fs.readFileSync(path.join(dir,e.html)),fs.readFileSync(path.join(dir,e.text))]){
      h.update(String(part.length)+':');h.update(part);}
     v={sha:h.digest('hex')};}}
  }catch(e){v={err:'template_unreadable: '+String(e.code||e.name||'error')};}
  live[key]=v;return v;};
 const one=async line=>{let p;try{p=JSON.parse(line);}catch(e){return out({k:'',status:'not_sent',reason:'unreadable payload'});}
  const k=p.k;delete p.k;const want=String(p._template_sha256||'');delete p._template_sha256;
  if(!tok)return out({k,status:'not_sent',reason:'no admin caller token in the pod'});
  if(!/^[0-9a-f]{64}$/.test(want))return out({k,status:'not_sent',reason:'template_pin_missing'});
  const l=liveSha(String(p.key||''));
  if(l.err)return out({k,status:'not_sent',reason:l.err});
  if(l.sha!==want)return out({k,status:'not_sent',reason:'template_pin_mismatch'});
  try{const r=await fetch('http://127.0.0.1:'+(process.env.PORT||8080)+'/v1/send',{method:'POST',
   headers:{'content-type':'application/json',authorization:'Bearer '+tok.slice(6)},body:JSON.stringify(p)});
   const b=await r.json().catch(()=>({}));
   out({k,http:r.status,id:b.id,status:b.status,gate:b.gate,reason:b.reason||b.error,duplicate:!!b.duplicate});}
  catch(e){out({k,status:'uncertain',reason:'fetch '+e.message});}};
 let i=0;const c=Math.max(1,Math.min(32,Number(head.concurrency)||8));
 await Promise.all(Array.from({length:c},async()=>{while(i<lines.length){await one(lines[i++]);}}));});
"""

WARMUP_GATES = ("route_ceiling", "route_paused", "route_health_unreadable", "news_daily_cap")


def next_utc_midnight(now: float) -> float:
    return (int(now) // 86400 + 1) * 86400.0


def classify_email(ans: dict, *, now: float | None = None) -> Outcome:
    """send-gateway's answer for one payload -> an Outcome. Anything that might have landed is `pending`: the job is
    re-presented under the same idempotency key, which the gateway answers from its own record."""
    now = time.time() if now is None else now
    status, gate = str(ans.get("status") or ""), str(ans.get("gate") or "")
    http = int(ans.get("http") or 0)
    reason = f"send-gateway {status or 'no status'} {gate} {ans.get('reason') or ''}".strip()
    if status == "sent":
        return Outcome("sent", "duplicate" if ans.get("duplicate") else "", str(ans.get("id") or ""))
    if status == "not_sent":  # refused inside the pod, before any POST
        return Outcome("defer", f"not_sent: {ans.get('reason') or ''}", delay_s=HOLD_RETRY_S)
    if status == "would_send":  # the gateway recorded no send and kept no key
        if gate == "route_ceiling" or gate == "news_daily_cap":
            return Outcome("defer", reason, delay_s=next_utc_midnight(now) - now,
                           pause_route_until=next_utc_midnight(now))
        if gate in WARMUP_GATES:
            return Outcome("defer", reason, delay_s=HOLD_RETRY_S, pause_route_until=now + HOLD_RETRY_S)
        return Outcome("defer", reason, delay_s=HOLD_RETRY_S)
    if status in ("pending", "unconfirmed", "sent_unrecorded", "uncertain") or http >= 500 or not http:
        return Outcome("pending", reason)
    return Outcome("rejected", reason)  # 4xx, or a 2xx decline (suppressed, unsubscribed, failed)


def kubectl_batch(lines: list[str], *, timeout_s: float = LEASE_S * 0.8) -> Iterator[dict]:
    """Run BATCH_JS once in a send-gateway pod and yield its answer lines as they arrive. A pod that cannot be
    found yields nothing-was-sent answers; an exec that dies mid-batch simply stops yielding."""
    keys = [json.loads(line).get("k", "") for line in lines[1:]]
    try:
        pod = subprocess.run(
            ["kubectl", "-n", "messaging", "get", "pod", "-l", "app.kubernetes.io/name=send-gateway",
             "--field-selector=status.phase=Running", "-o", "name"],
            capture_output=True, text=True, timeout=60, check=False)
        name = (pod.stdout.split() or [""])[0]
    except (OSError, subprocess.SubprocessError):
        name = ""
    if not name:
        for k in keys:
            yield {"k": k, "status": "not_sent", "reason": "no running send-gateway pod"}
        return
    proc = subprocess.Popen(["kubectl", "-n", "messaging", "exec", "-i", name, "--", "node", "-e", BATCH_JS],
                            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
    timer = threading.Timer(timeout_s, proc.kill)
    timer.start()
    try:
        proc.stdin.write("\n".join(lines) + "\n")
        proc.stdin.close()
        for line in proc.stdout:
            try:
                ans = json.loads(line)
            except ValueError:
                continue
            if isinstance(ans, dict) and ans.get("k"):
                yield ans
    finally:
        timer.cancel()
        proc.kill()
        proc.wait()


def _copy_gate():
    import importlib.util  # noqa: PLC0415
    name = "hydra_lib_copy_gate"
    if name not in sys.modules:
        spec = importlib.util.spec_from_file_location(name, ROOT / "scripts" / "lib" / "copy_gate.py")
        mod = importlib.util.module_from_spec(spec)
        sys.modules[name] = mod
        spec.loader.exec_module(mod)
    return sys.modules[name]


class EmailRoute:
    """send-gateway, one exec per claimed batch. The gateway is at-most-once per idempotency_key, so this route is
    `idempotent`: a job with no recorded outcome is presented again under the same key."""

    name = "email"

    def __init__(self, policy: dict, *, exec_batch: Callable[[list[str]], Iterable[dict]] | None = None,
                 gate: Any = None):
        cfg = (policy.get("routes") or {}).get("email") or {}
        self.keys = cfg.get("template_keys") or {}
        self.pins = cfg.get("template_sha256") or {}
        self.concurrency = int(cfg.get("pod_concurrency") or 8)
        self.exec_batch = exec_batch or kubectl_batch
        self.gate = gate

    def _frame(self, job: Job) -> tuple[str, str, str]:
        key = str(self.keys.get(job.message_class) or "")
        pin = str(self.pins.get(key) or "").strip().lower()
        ok = len(pin) == 64 and all(c in "0123456789abcdef" for c in pin)
        return key, (pin if ok else ""), (f"email-template:{key}@{pin}" if key and ok else "")

    def hold(self, job: Job) -> str:
        """'' when this exact body may leave in this exact template, else why it may not. The copy gate is asked
        on the bytes; there is no argument that skips it."""
        key, pin, frame = self._frame(job)
        if not key:
            return f"no template key for {job.message_class}"
        if not pin:
            return f"copy_review_hold: email_template_unpinned:{key}"
        if not job.email or not job.user_id:
            return "no_route: email or user id missing"
        try:
            (self.gate or _copy_gate()).require(job.message_class, job.body, subject=job.subject, copy=frame,
                                                data=job.copy_data)
        except Exception as exc:  # noqa: BLE001 - CopyHeld, or a gate that could not run: both hold
            text = str(exc)
            return text[:300] if text.startswith("copy_review_hold") else f"copy_review_hold: {type(exc).__name__}"
        return ""

    def payload(self, job: Job) -> dict:
        key, pin, _ = self._frame(job)
        return {"k": job.idem_key, "key": key, "to": {"email": job.email, "user_id": job.user_id},
                "data": {"event": dict(job.data or {}, status_line=job.body)},
                "idempotency_key": job.provider_key, "_template_sha256": pin}

    def send(self, jobs: list[Job]) -> Iterator[tuple[str, Outcome]]:
        if not jobs:
            return
        lines = [json.dumps({"concurrency": self.concurrency})] + [json.dumps(self.payload(j)) for j in jobs]
        for ans in self.exec_batch(lines):
            yield str(ans.get("k") or ""), classify_email(ans)


# ------------------------------------------------------------------------------------------- reading the queue
def status(db: sqlite3.Connection) -> dict:
    q = db.execute
    return {"people": q("SELECT COUNT(*) FROM people").fetchone()[0],
            "verdicts": {f"{v}:{r}": n for v, r, n in q(
                "SELECT verdict, reason, COUNT(*) FROM verdicts GROUP BY 1, 2 ORDER BY 1, 2")},
            "jobs": {f"{r}:{s}": n for r, s, n in q(
                "SELECT route, state, COUNT(*) FROM jobs GROUP BY 1, 2 ORDER BY 1, 2")},
            "routes": {r: {"batch_capable": bool(b), "idempotent": bool(i), "not_before": nb, "why": w}
                       for r, b, i, nb, w in q("SELECT route, batch_capable, idempotent, not_before, why FROM routes")}}


def verify(db: sqlite3.Connection, *, now: float | None = None) -> dict:
    """The guardrails, read back from the rows. Every count must be 0 (`open_leases` once the workers stopped)."""
    now = time.time() if now is None else now
    q = lambda sql, *a: db.execute(sql, a).fetchone()[0]  # noqa: E731
    return {
        "jobs_without_send_verdict": q(
            "SELECT COUNT(*) FROM jobs j WHERE NOT EXISTS (SELECT 1 FROM verdicts v WHERE v.user_key = j.user_key "
            "AND v.stage = j.stage AND v.verdict = 'send')"),
        "users_with_two_jobs_in_a_stage": q(
            "SELECT COUNT(*) FROM (SELECT 1 FROM jobs GROUP BY user_key, stage HAVING COUNT(*) > 1)"),
        "sent_without_attempt": q(
            "SELECT COUNT(*) FROM jobs j WHERE j.state = 'sent' AND NOT EXISTS (SELECT 1 FROM job_events a "
            "JOIN job_events s ON s.idem_key = a.idem_key AND s.event = 'sent' AND s.seq > a.seq "
            "WHERE a.idem_key = j.idem_key AND a.event = 'attempted')"),
        "sent_without_provider_id": q("SELECT COUNT(*) FROM jobs WHERE state = 'sent' AND provider_id = ''"),
        "orphans": q("SELECT COUNT(*) FROM jobs WHERE state IN ('claimed','attempted') AND lease_until < ?", now),
    }


def resolve(db: sqlite3.Connection, key: str, as_state: str, by: str, note: str = "") -> bool:
    """A named person records what the provider shows for an `uncertain` job. The only way out of `uncertain`."""
    if as_state not in ("sent", "rejected") or not by.strip():
        raise ValueError("resolve needs --as sent|rejected and a named person in --by")
    now = time.time()
    with tx(db):
        cur = db.execute("UPDATE jobs SET state=?, reason=?, provider_id=CASE WHEN ?='sent' AND provider_id='' "
                         "THEN 'resolved-by-hand' ELSE provider_id END, done_at=? WHERE idem_key=? "
                         "AND state='uncertain'", (as_state, f"resolved by {by}: {note}"[:300], as_state, now, key))
        if cur.rowcount:
            _event(db, key, f"human:{by}", as_state, f"resolved by hand: {note}", now)
    return bool(cur.rowcount)


# -------------------------------------------------------------------------------------------- bench and chaos
SCRATCH_POLICY = {
    "routes": {"chat": {"batch_capable": False, "idempotent": False},
               "email": {"batch_capable": True, "idempotent": True},
               "intercom": {"batch_capable": False, "idempotent": False}},
    "stages": {"doc_received": "status-doc-received", "team_review": "status-team-review"},
}


def synth_people(n: int) -> Iterator[dict]:
    """A deterministic population that exercises every predicate: 1 in 50 held, 1 in 25 already told, 1 in 20 with
    no confirmed email, 1 in 100 in a stage with no message class; the rest send. Two requests each."""
    for i in range(n):
        yield {"user_key": f"u{i:07d}@example.test", "user_id": str(100000 + i),
               "email": "" if i % 20 == 7 else f"u{i:07d}@example.test", "email_confirmed": i % 20 != 7,
               "stage": "unmapped" if i % 100 == 3 else ("doc_received" if i % 2 else "team_review"),
               "request_ids": [f"r{i:07d}a", f"r{i:07d}b"], "hold": "unmeasured" if i % 50 == 11 else "",
               "intercom_thread": "c1" if i % 20 == 7 else "", "body": "We have your document.",
               "told": ["doc_received", "team_review"] if i % 25 == 5 else []}


def _spawn(db_path: str, provider: str, n: int, *, route: str, batch: int, latency_ms: float, dedupe: bool,
           lease_s: float, tag: str) -> list[subprocess.Popen]:
    argv = [sys.executable, str(Path(__file__).resolve()), "work", "--db", db_path, "--route", route, "--fake",
            provider, "--batch", str(batch), "--latency-ms", str(latency_ms), "--lease", str(lease_s),
            "--kill-file", os.path.join(os.path.dirname(db_path), "kill")]
    if not dedupe:
        argv.append("--no-dedupe")
    return [subprocess.Popen(argv + ["--worker-id", f"{tag}{i}"], stdout=subprocess.DEVNULL) for i in range(n)]


def _scratch(tmp: str, people: int, *, idempotent: bool) -> tuple[str, str, dict, dict]:
    db_path, prov = os.path.join(tmp, "queue.sqlite"), os.path.join(tmp, "provider.sqlite")
    policy = json.loads(json.dumps(SCRATCH_POLICY))
    policy["routes"]["email"]["idempotent"] = idempotent
    db = connect(db_path, init=True)
    apply_policy(db, policy)
    load_people(db, synth_people(people))
    FakeProvider(prov, dedupe=idempotent, init=True)
    decided = decide(db)
    queued = enqueue(db)
    db.close()
    return db_path, prov, decided, queued


def bench(people: int, workers: int, batch: int, latency_ms: float) -> dict:
    """Time the decision statement over `people` rows, then drain what it queued with `workers` processes."""
    with tempfile.TemporaryDirectory(prefix="bulk-queue-bench-") as tmp:
        db_path, prov, decided, queued = _scratch(tmp, people, idempotent=True)
        t0 = time.perf_counter()
        procs = _spawn(db_path, prov, workers, route="email", batch=batch, latency_ms=latency_ms, dedupe=True,
                       lease_s=LEASE_S, tag="b")
        rcs = [p.wait() for p in procs]
        secs = time.perf_counter() - t0
        db = connect(db_path)
        sent = db.execute("SELECT COUNT(*) FROM jobs WHERE state='sent'").fetchone()[0]
        return {"decide": decided, "enqueue": queued,
                "drain": {"workers": workers, "batch": batch, "provider_latency_ms": latency_ms, "sent": sent,
                          "seconds": round(secs, 3), "sends_per_min": int(sent / secs * 60) if secs else None,
                          "worker_exit_codes": rcs},
                "verify": verify(db), "provider": FakeProvider(prov).counts()}


def chaos(jobs: int, workers: int, batch: int, latency_ms: float) -> dict:
    """kill -9 half the workers mid-batch, twice: against a provider that de-duplicates on our key (email) and
    against one that does not. Then recover, drain with fresh workers, and read the invariants back."""
    report: dict[str, Any] = {"ok": True}
    for mode, idempotent in (("provider_dedupes", True), ("provider_keeps_no_key", False)):
        with tempfile.TemporaryDirectory(prefix="bulk-queue-chaos-") as tmp:
            lease = 4.0
            db_path, prov, _, queued = _scratch(tmp, int(jobs / 0.86) + 1, idempotent=idempotent)
            procs = _spawn(db_path, prov, workers, route="email", batch=batch, latency_ms=latency_ms,
                           dedupe=idempotent, lease_s=lease, tag="k")
            db = connect(db_path)
            total = queued["enqueued"]
            deadline = time.time() + 120
            while time.time() < deadline and db.execute(
                    "SELECT COUNT(*) FROM jobs WHERE state='sent'").fetchone()[0] < total * 0.3:
                time.sleep(0.02)
            victims = procs[: max(1, workers // 2)]
            for p in victims:
                p.send_signal(signal.SIGKILL)
            at_kill = dict(db.execute("SELECT state, COUNT(*) FROM jobs GROUP BY 1").fetchall())
            for p in procs:
                p.wait()
            time.sleep(lease + 0.3)  # every dead worker's lease has now run out
            recover(db)
            for p in _spawn(db_path, prov, workers, route="email", batch=batch, latency_ms=latency_ms,
                            dedupe=idempotent, lease_s=lease, tag="r"):
                p.wait()
            time.sleep(lease + 0.3)
            recover(db)
            states = dict(db.execute("SELECT state, COUNT(*) FROM jobs GROUP BY 1").fetchall())
            recovered = dict(db.execute(  # by whichever worker's loop got there first, survivors included
                "SELECT event, COUNT(*) FROM job_events WHERE worker = 'recover' GROUP BY 1").fetchall())
            counts, checks = FakeProvider(prov).counts(), verify(db)
            sent, uncertain = states.get("sent", 0), states.get("uncertain", 0)
            settled = sent + uncertain + states.get("rejected", 0) == total
            # every `sent` job is one the provider holds; an `uncertain` one may or may not be there, never twice
            in_flight = at_kill.get("attempted", 0) + at_kill.get("claimed", 0)
            ok = (counts["keys_delivered_twice"] == 0 and not any(checks.values()) and settled
                  and in_flight > 0  # a kill that caught nothing in flight proves nothing
                  and sent <= counts["keys_delivered"] <= sent + uncertain
                  and (uncertain == 0 if idempotent else True))
            report[mode] = {"jobs": total, "workers": workers, "killed": len(victims), "states_at_kill": at_kill,
                            "in_flight_at_kill": in_flight, "recovered": recovered, "final_states": states, "provider": counts, "verify": checks,
                            "presented_again": counts["calls"] - counts["keys_delivered"], "ok": ok}
            report["ok"] = report["ok"] and ok
    return report


# -------------------------------------------------------------------------------------------------------- CLI
def _armed(policy: dict, route: str) -> str:
    """'' when a real route may send, else the reason. Off unless the policy says on, at both levels."""
    if policy.get("enabled") is not True:
        return "policies/bulk-send-queue.json enabled is not true"
    r = (policy.get("routes") or {}).get(route) or {}
    if r.get("enabled") is not True or r.get("batch_capable") is not True:
        return f"route {route} is not enabled and batch_capable in the policy"
    return ""


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    for name in ("init", "load", "decide", "enqueue", "work", "drain", "recover", "status", "verify", "resolve"):
        sp = sub.add_parser(name)
        sp.add_argument("--db", default=DEFAULT_DB)
        sp.add_argument("--policy", default=str(POLICY_PATH))
        if name == "load":
            sp.add_argument("--people", required=True, help="JSONL, one person per line")
        if name in ("work", "drain"):
            sp.add_argument("--route", default="email", choices=ROUTE_ORDER)
            sp.add_argument("--batch", type=int, default=25)
            sp.add_argument("--lease", type=float, default=LEASE_S)
            sp.add_argument("--apply", action="store_true", help="send through the real route (policy must arm it)")
            sp.add_argument("--fake", default="", metavar="PROVIDER_DB", help="send to an on-disk fake provider")
            sp.add_argument("--no-dedupe", action="store_true")
            sp.add_argument("--latency-ms", type=float, default=0.0)
            sp.add_argument("--kill-file", default=KILL_FILE)
        if name == "work":
            sp.add_argument("--worker-id", default=f"w{os.getpid()}")
            sp.add_argument("--max-jobs", type=int, default=0)
        if name == "drain":
            sp.add_argument("--workers", type=int, default=8)
        if name == "resolve":
            sp.add_argument("--idem", required=True)
            sp.add_argument("--as", dest="as_state", required=True, choices=("sent", "rejected"))
            sp.add_argument("--by", required=True)
            sp.add_argument("--note", default="")
    for name in ("bench", "chaos"):
        sp = sub.add_parser(name)
        sp.add_argument("--people" if name == "bench" else "--jobs", dest="n", type=int,
                        default=100000 if name == "bench" else 2000)
        sp.add_argument("--workers", type=int, default=8)
        sp.add_argument("--batch", type=int, default=25)
        sp.add_argument("--latency-ms", type=float, default=2.0)
    a = ap.parse_args(argv)
    say = lambda o: print(json.dumps(o, indent=2, sort_keys=True))  # noqa: E731

    if a.cmd == "bench":
        say(bench(a.n, a.workers, a.batch, a.latency_ms))
        return 0
    if a.cmd == "chaos":
        rep = chaos(a.n, a.workers, a.batch, a.latency_ms)
        say(rep)
        return 0 if rep["ok"] else 1
    if a.cmd == "init":
        db = connect(a.db, init=True)
        apply_policy(db, load_policy(a.policy))
        say(status(db))
        return 0
    db = connect(a.db)
    if a.cmd == "load":
        with open(a.people, encoding="utf-8") as fh:
            say({"loaded": load_people(db, (json.loads(line) for line in fh if line.strip()))})
    elif a.cmd == "decide":
        apply_policy(db, load_policy(a.policy))
        say(decide(db))
    elif a.cmd == "enqueue":
        say(enqueue(db))
    elif a.cmd == "recover":
        say(recover(db))
    elif a.cmd == "status":
        say(status(db))
    elif a.cmd == "verify":
        rep = verify(db)
        say(rep)
        return 1 if any(rep.values()) else 0
    elif a.cmd == "resolve":
        say({"resolved": resolve(db, a.idem, a.as_state, a.by, a.note)})
    elif a.cmd in ("work", "drain"):
        policy = {} if a.fake else load_policy(a.policy)
        if not a.fake:
            why = "pass --apply to send through the real route" if not a.apply else _armed(policy, a.route)
            if why:
                print(f"REFUSED: {why}; nothing was claimed or sent", file=sys.stderr)
                return 2
        if a.cmd == "drain":
            extra = ["--route", a.route, "--batch", str(a.batch), "--lease", str(a.lease), "--latency-ms",
                     str(a.latency_ms), "--kill-file", a.kill_file, "--policy", a.policy]
            extra += (["--fake", a.fake] if a.fake else ["--apply"]) + (["--no-dedupe"] if a.no_dedupe else [])
            t0 = time.perf_counter()
            procs = [subprocess.Popen([sys.executable, str(Path(__file__).resolve()), "work", "--db", a.db,
                                       "--worker-id", f"d{i}"] + extra, stdout=subprocess.DEVNULL)
                     for i in range(a.workers)]
            rcs = [p.wait() for p in procs]
            say({"workers": a.workers, "exit_codes": rcs, "seconds": round(time.perf_counter() - t0, 3),
                 "jobs": status(db)["jobs"]})
            return max(rcs)
        if a.fake:
            route: Any = FakeRoute(a.route, FakeProvider(a.fake, dedupe=not a.no_dedupe),
                                   latency_s=a.latency_ms / 1000.0)
        elif a.route == "email":
            route = EmailRoute(policy)
        else:
            print(f"REFUSED: route {a.route} has no batch sender", file=sys.stderr)
            return 2
        done = work(db, route, a.worker_id, batch=a.batch, lease_s=a.lease, max_jobs=a.max_jobs,
                    kill_file=a.kill_file)
        say(done)
        return EXIT_KILLED if done["killed"] else 0
    return 0


if __name__ == "__main__":
    sys.exit(main())
