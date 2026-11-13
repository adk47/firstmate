#!/usr/bin/env python3
"""TEMPORARY: a durable send queue in front of the reviewed gate, for claim-proof-ask first notes.

REMOVE WHEN: `bulk_queue.py`'s email route carries this family, which needs a reviewed claim-proof-ask template in
send-gateway and its sha256 pinned in `policies/bulk-send-queue.json`. Until then the ask can only leave through
`intercom-verify-request.sh`, so this module puts the queue around that one call and replaces nothing else.

What it changes. The apply used to keep every outcome in memory and write them when the run ended, so a run that
was killed lost them (39 sends at 15:05Z and 79 at 17:24Z on 2026-11-04). Here each message is a row:

  enqueue    one intent per (campaign, user, request), key = sha256 of those three. INSERT OR IGNORE.
  begin      ONE `BEGIN IMMEDIATE` transaction claims the intent and commits `attempted` before the gate is called.
             Any number of threads or processes may run it; exactly one gets `go` for a key.
  finish     commits the outcome the moment the gate answers. It is read from the VERIFY LEDGER, not from the
             gate's stdout: the gate writes its own claim row there before it POSTs and finalises it after.
  settle     a dead worker's `attempted` row is settled from the same ledger on the next run: a `sent` row is
             sent, an `attempted` row is `uncertain` (the POST may have landed; nothing sends it again), and no
             row at all means the gate never claimed, so nothing was POSTed and the intent is queued again.

What it does not change: who is asked (the ladder in `claim_proof_ask.run`), the gate, the copy, any cap, the tick,
or `verify_notify`'s accounting. The wrapped gate hands the gate's own answer back untouched. The queue never
decides a refusal: an intent the gate did not send goes back to `queued` and is offered again only if the ladder
lists it again.

Operator doc: docs/credit-verification/bulk-send-queue.md ("The gate queue").
"""
from __future__ import annotations

import argparse
import contextlib
import hashlib
import json
import os
import random
import signal
import sqlite3
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path
from typing import Any, Callable, Iterator

ROOT = Path(__file__).resolve().parents[2]
POLICY_PATH = ROOT / "policies" / "apply-queue.json"
KILL_FILE = "/etc/hydra/apply-queue.disabled"      # present: every family uses the direct path again
JOURNAL_NAME = "apply-queue.sqlite3"               # beside the verify ledger it mirrors
LEASE_S = 600.0                                    # three times the gate's worst case (verify_notify.WORST_USER_S)
KIND_FIRST = "initial"

SCHEMA = """
CREATE TABLE IF NOT EXISTS intents (
  idem_key TEXT PRIMARY KEY,
  campaign TEXT NOT NULL,
  user_id TEXT NOT NULL,
  request_key TEXT NOT NULL,
  state TEXT NOT NULL DEFAULT 'queued' CHECK (state IN ('queued','attempted','sent','uncertain')),
  worker TEXT NOT NULL DEFAULT '',
  lease_until REAL NOT NULL DEFAULT 0,
  attempts INTEGER NOT NULL DEFAULT 0,
  ledger_floor INTEGER NOT NULL DEFAULT 0,   -- max(verify_messages.id) when the attempt was recorded
  ledger_row INTEGER,
  message_id TEXT NOT NULL DEFAULT '',
  reason TEXT NOT NULL DEFAULT '',
  enqueued_at REAL NOT NULL,
  attempted_at REAL NOT NULL DEFAULT 0,
  done_at REAL NOT NULL DEFAULT 0,
  UNIQUE (campaign, user_id, request_key)
);
CREATE INDEX IF NOT EXISTS intents_state ON intents (state, lease_until);
CREATE TABLE IF NOT EXISTS intent_events (
  seq INTEGER PRIMARY KEY AUTOINCREMENT,
  idem_key TEXT NOT NULL, at REAL NOT NULL, worker TEXT NOT NULL, event TEXT NOT NULL, detail TEXT NOT NULL DEFAULT ''
);
CREATE INDEX IF NOT EXISTS intent_events_key ON intent_events (idem_key);
CREATE TRIGGER IF NOT EXISTS intent_starts_queued BEFORE INSERT ON intents WHEN NEW.state <> 'queued'
BEGIN SELECT RAISE(ABORT, 'apply_queue: an intent starts queued'); END;
CREATE TRIGGER IF NOT EXISTS intent_no_delete BEFORE DELETE ON intents
BEGIN SELECT RAISE(ABORT, 'apply_queue: an intent is never deleted'); END;
CREATE TRIGGER IF NOT EXISTS intent_sent_is_final BEFORE UPDATE ON intents WHEN OLD.state = 'sent'
BEGIN SELECT RAISE(ABORT, 'apply_queue: a sent intent is never rewritten'); END;
CREATE TRIGGER IF NOT EXISTS intent_sent_needs_attempt BEFORE UPDATE OF state ON intents
WHEN NEW.state = 'sent' AND NOT (OLD.state IN ('attempted','uncertain') AND OLD.attempted_at > 0)
BEGIN SELECT RAISE(ABORT, 'apply_queue: sent without a recorded attempt'); END;
CREATE TRIGGER IF NOT EXISTS intent_attempt_from_queued BEFORE UPDATE OF state ON intents
WHEN NEW.state = 'attempted' AND OLD.state <> 'queued'
BEGIN SELECT RAISE(ABORT, 'apply_queue: only a queued intent can be attempted'); END;
CREATE TRIGGER IF NOT EXISTS intent_events_no_update BEFORE UPDATE ON intent_events
BEGIN SELECT RAISE(ABORT, 'apply_queue: the event log is append-only'); END;
CREATE TRIGGER IF NOT EXISTS intent_events_no_delete BEFORE DELETE ON intent_events
BEGIN SELECT RAISE(ABORT, 'apply_queue: the event log is append-only'); END;
"""


# ---------------------------------------------------------------- the switch

def enabled_for(campaign: str, *, policy_path: Path | str = POLICY_PATH, kill_file: str = KILL_FILE) -> bool:
    """Is this campaign's apply queued? Only on an explicit `true` in a readable policy with no kill file.

    Anything else is the direct path, which is the one that ran before this module existed."""
    if os.path.exists(kill_file):
        return False
    try:
        policy = json.loads(Path(policy_path).read_text(encoding="utf-8"))
        return policy["campaigns"][campaign]["enabled"] is True
    except (OSError, ValueError, KeyError, TypeError):
        return False


def journal_path(ledger_path: str) -> str:
    return str(Path(ledger_path).resolve().parent / JOURNAL_NAME)


# ---------------------------------------------------------------- the journal

def _ensure_wal(db: sqlite3.Connection) -> None:
    """Set WAL once, retrying the transition.

    `PRAGMA journal_mode=WAL` needs an exclusive lock to CHANGE the mode and answers SQLITE_BUSY at once (it does
    not wait on the busy handler) when another connection is mid-transition. The mode is persistent, so only the
    first connections race; a retry is what makes concurrent workers deterministic instead of one of them falling
    back to the direct path."""
    deadline = time.monotonic() + 30
    while True:
        try:
            db.execute("PRAGMA journal_mode=WAL")
            return
        except sqlite3.OperationalError as exc:
            if "locked" not in str(exc) or time.monotonic() >= deadline:
                raise
            time.sleep(0.02)


def connect(path: str) -> sqlite3.Connection:
    if not os.path.exists(path):
        os.close(os.open(path, os.O_WRONLY | os.O_CREAT, 0o600))
    db = sqlite3.connect(path, timeout=120, isolation_level=None)
    _ensure_wal(db)
    db.execute("PRAGMA synchronous=FULL")
    db.executescript(SCHEMA)
    return db


@contextlib.contextmanager
def tx(db: sqlite3.Connection) -> Iterator[None]:
    db.execute("BEGIN IMMEDIATE")
    try:
        yield
    except BaseException:
        db.execute("ROLLBACK")
        raise
    db.execute("COMMIT")


def _event(db: sqlite3.Connection, key: str, worker: str, event: str, detail: str, now: float) -> None:
    db.execute("INSERT INTO intent_events (idem_key, at, worker, event, detail) VALUES (?,?,?,?,?)",
               (key, now, worker, event, detail[:300]))


def user_id_of(p: dict[str, Any]) -> str:
    return str((p.get("user") or {}).get("id") or "").strip()


def request_key(p: dict[str, Any]) -> str:
    return ",".join(sorted({str(c.get("request_id") or "").strip() for c in p.get("credits") or []} - {""}))


def idem_key(campaign: str, user_id: str, rkey: str) -> str:
    return hashlib.sha256(f"{campaign}\x1f{user_id}\x1f{rkey}".encode()).hexdigest()


def key_of(campaign: str, p: dict[str, Any]) -> str:
    """'' when the payload names no user or no request: it cannot be queued, so it is not sent."""
    uid, rkey = user_id_of(p), request_key(p)
    return idem_key(campaign, uid, rkey) if uid and rkey else ""


def enqueue(db: sqlite3.Connection, campaign: str, payloads: list[dict[str, Any]], *, now: float | None = None) -> int:
    now = time.time() if now is None else now
    added = 0
    with tx(db):
        for p in payloads:
            key = key_of(campaign, p)
            if not key:
                continue
            cur = db.execute("INSERT OR IGNORE INTO intents (idem_key, campaign, user_id, request_key, enqueued_at) "
                             "VALUES (?,?,?,?,?)", (key, campaign, user_id_of(p), request_key(p), now))
            if cur.rowcount:
                added += 1
                _event(db, key, "", "enqueued", "", now)
    return added


# ---------------------------------------------------------------- the verify ledger, read-only

def _ledger_ro(ledger_path: str) -> sqlite3.Connection | None:
    """None when the ledger does not exist yet: nothing was ever claimed in it."""
    if not os.path.exists(ledger_path):
        return None
    return sqlite3.connect(f"file:{ledger_path}?mode=ro", uri=True, timeout=30)


def ledger_floor(ledger_path: str) -> int:
    db = _ledger_ro(ledger_path)
    if db is None:
        return 0
    try:
        return int(db.execute("SELECT COALESCE(MAX(id), 0) FROM verify_messages").fetchone()[0])
    finally:
        db.close()


def ledger_rows(ledger_path: str, campaign: str, rkey: str, floor: int = 0) -> list[tuple[int, str, str]]:
    """(id, status, message_id) of this campaign's FIRST notes above `floor` that name any of the requests."""
    db = _ledger_ro(ledger_path)
    if db is None:
        return []
    want = set(rkey.split(","))
    out = []
    try:
        for rid, status, mid, ids in db.execute(
                "SELECT id, status, COALESCE(message_id, ''), request_ids_json FROM verify_messages "
                "WHERE campaign = ? AND id > ? AND COALESCE(kind, ?) = ? ORDER BY id",
                (campaign, floor, KIND_FIRST, KIND_FIRST)):
            try:
                if want & {str(x) for x in json.loads(ids or "[]")}:
                    out.append((int(rid), str(status), str(mid)))
            except ValueError:
                continue
    finally:
        db.close()
    return out


def ledger_truth(ledger_path: str, campaign: str, rkey: str, floor: int) -> tuple[str, int, str]:
    """What the gate recorded for this attempt: ('sent'|'attempted'|'none'|<other status>, row id, message id).

    `sent` wins over `attempted`, and either wins over a row that says nothing left."""
    rows = ledger_rows(ledger_path, campaign, rkey, floor)
    for want in ("sent", "attempted"):
        for rid, status, mid in rows:
            if status == want:
                return status, rid, mid
    if rows:
        return rows[-1][1], rows[-1][0], rows[-1][2]
    return "none", 0, ""


# ---------------------------------------------------------------- claim, record, settle

def begin(db: sqlite3.Connection, key: str, worker: str, *, floor: int, lease_s: float = LEASE_S,
          now: float | None = None) -> tuple[str, str]:
    """Claim one intent and commit `attempted`, in one transaction. Returns (verdict, detail).

    go        this caller, and only this caller, may call the gate for the key
    sent      already sent
    uncertain an earlier attempt has an unknown outcome
    busy      another worker holds it
    unsettled a dead worker's attempt has not been settled from the ledger yet
    missing   no intent was written"""
    now = time.time() if now is None else now
    with tx(db):
        row = db.execute("SELECT state, worker, lease_until FROM intents WHERE idem_key = ?", (key,)).fetchone()
        if row is None:
            return "missing", ""
        state, holder, lease = row
        if state in ("sent", "uncertain"):
            return state, ""
        if state == "attempted":
            return ("busy" if lease > now else "unsettled"), holder
        db.execute("UPDATE intents SET state = 'attempted', worker = ?, lease_until = ?, attempts = attempts + 1, "
                   "attempted_at = ?, ledger_floor = ?, reason = '' WHERE idem_key = ?",
                   (worker, now + lease_s, now, floor, key))
        _event(db, key, worker, "attempted", f"ledger_floor={floor}", now)
    return "go", ""


def _apply_truth(db: sqlite3.Connection, key: str, worker: str, truth: tuple[str, int, str], *, posted: bool,
                 answer: str, now: float, from_states: tuple[str, ...]) -> str:
    """Move one intent to what the ledger shows. Caller holds the transaction. Returns the new state."""
    status, row, mid = truth
    if posted or status == "sent":
        new, why = "sent", ("" if status == "sent" else "the gate answered POSTED; no sent ledger row was found")
    elif status == "attempted":
        new, why = "uncertain", f"ledger row {row} is attempted: the POST may have landed"
    elif status == "none":
        new, why = "queued", f"no ledger row: the gate never claimed, nothing was posted ({answer})"
    else:
        new, why = "queued", f"ledger row {row} is {status}: nothing was delivered ({answer})"
    marks = ",".join("?" * len(from_states))
    cur = db.execute(
        f"UPDATE intents SET state = ?, worker = '', lease_until = 0, ledger_row = ?, message_id = ?, reason = ?, "
        f"done_at = ? WHERE idem_key = ? AND state IN ({marks})",
        (new, row or None, mid, why[:300], now if new != "queued" else 0, key, *from_states))
    if not cur.rowcount:
        return ""
    _event(db, key, worker, new if new != "queued" else "released", why, now)
    return new


def finish(db: sqlite3.Connection, key: str, worker: str, *, ledger_path: str, posted: bool, answer: str,
           now: float | None = None) -> str:
    """Commit the outcome of an attempt this worker made. Returns the new state.

    '' when the ledger could not be read and the gate did not say POSTED: the intent stays `attempted` and is
    settled on a later run. An unreadable ledger is never read as "nothing was sent"."""
    now = time.time() if now is None else now
    row = db.execute("SELECT campaign, request_key, ledger_floor FROM intents WHERE idem_key = ? AND state = "
                     "'attempted' AND worker = ?", (key, worker)).fetchone()
    if row is None:
        return ""
    try:
        truth = ledger_truth(ledger_path, row[0], row[1], row[2])
    except sqlite3.Error as exc:
        if not posted:
            with tx(db):
                _event(db, key, worker, "unsettled", f"ledger unreadable ({type(exc).__name__}); {answer}", now)
            return ""
        truth = ("unreadable", 0, "")
    with tx(db):
        return _apply_truth(db, key, worker, truth, posted=posted, answer=answer, now=now, from_states=("attempted",))


def settle(db: sqlite3.Connection, ledger_path: str, *, now: float | None = None) -> dict[str, int]:
    """Settle every attempt whose worker is gone, and re-read every `uncertain` intent, from the ledger."""
    now = time.time() if now is None else now
    out = {"sent": 0, "uncertain": 0, "queued": 0, "unreadable": 0}
    rows = db.execute("SELECT idem_key, campaign, request_key, ledger_floor, state FROM intents "
                      "WHERE (state = 'attempted' AND lease_until < ?) OR state = 'uncertain'", (now,)).fetchall()
    for key, campaign, rkey, floor, state in rows:
        try:
            truth = ledger_truth(ledger_path, campaign, rkey, floor)
        except sqlite3.Error:
            out["unreadable"] += 1
            continue
        if state == "uncertain" and truth[0] in ("attempted", "none"):
            continue                       # nothing new is known: it stays for a person
        with tx(db):
            new = _apply_truth(db, key, "settle", truth, posted=False, answer="the worker did not report", now=now,
                               from_states=(state,))
        if new:
            out[new] += 1
    return out


def resolve(db: sqlite3.Connection, key: str, as_state: str, by: str, note: str = "") -> bool:
    """A named person settles an `uncertain` intent after reading the provider. The only other way out of it."""
    if as_state not in ("sent", "queued"):
        raise ValueError("resolve as `sent` or `queued`")
    if not by.strip():
        raise ValueError("resolve needs the name of the person who read the provider")
    now = time.time()
    with tx(db):
        cur = db.execute("UPDATE intents SET state = ?, reason = ?, done_at = ? WHERE idem_key = ? AND state = "
                         "'uncertain'", (as_state, f"resolved by {by.strip()}: {note}"[:300], now, key))
        if cur.rowcount:
            _event(db, key, f"person:{by.strip()}", "resolved", f"{as_state}: {note}", now)
        return bool(cur.rowcount)


# ---------------------------------------------------------------- the wrapped gate

def _answer(rc: int, line: str) -> subprocess.CompletedProcess:
    return subprocess.CompletedProcess(args=["apply_queue"], returncode=rc, stdout=line + "\n", stderr="")


def _first(text: Any) -> str:
    return (str(text or "").strip().splitlines() or [""])[0][:160]


def posted(res: Any) -> bool:
    """The same test verify_notify applies: rc 0 and a first stdout line that starts POSTED."""
    return getattr(res, "returncode", 1) == 0 and _first(getattr(res, "stdout", "")).startswith("POSTED")


class Session:
    """One apply run's use of the queue for one campaign. Safe to share between threads: every call opens its own
    connection, and nothing about an intent is held in memory."""

    def __init__(self, campaign: str, ledger_path: str, *, path: str = "", lease_s: float = LEASE_S) -> None:
        self.campaign = campaign
        self.ledger_path = ledger_path
        self.path = path or journal_path(ledger_path)
        self.lease_s = lease_s
        self.run = f"{os.getpid()}-{int(time.time())}"

    def open(self, payloads: list[dict[str, Any]], gate: Callable[[dict[str, Any]], Any]) -> Callable[[dict[str, Any]], Any]:
        """Settle what earlier runs left, write this run's intents, and return the gate to call.

        When the journal cannot be opened nothing is in flight yet, so the run uses the direct path and says so."""
        try:
            db = connect(self.path)
            try:
                settle(db, self.ledger_path)
                enqueue(db, self.campaign, payloads)
            finally:
                db.close()
        except (sqlite3.Error, OSError) as exc:
            print(f"APPLY QUEUE UNAVAILABLE for {self.campaign} ({type(exc).__name__}: {exc}); this run uses the "
                  f"direct path", file=sys.stderr)
            return gate
        return self.wrap(gate)

    def wrap(self, gate: Callable[[dict[str, Any]], Any]) -> Callable[[dict[str, Any]], Any]:
        def queued_gate(p: dict[str, Any]) -> Any:
            key = key_of(self.campaign, p)
            if not key:
                return _answer(3, "DEFERRED apply_queue_unkeyed: the payload names no user id or no request id; "
                                  "no intent can be recorded, so nothing was sent")
            worker = f"{self.run}:{threading.get_ident()}"
            try:
                db = connect(self.path)
                try:
                    floor = ledger_floor(self.ledger_path)
                    verdict, who = begin(db, key, worker, floor=floor, lease_s=self.lease_s)
                    if verdict == "unsettled":
                        settle(db, self.ledger_path)
                        verdict, who = begin(db, key, worker, floor=floor, lease_s=self.lease_s)
                finally:
                    db.close()
            except (sqlite3.Error, OSError) as exc:
                return _answer(3, f"DEFERRED apply_queue_unwritable ({type(exc).__name__}): no attempt could be "
                                  f"recorded, so nothing was sent")
            if verdict == "sent":
                return _answer(0, "SKIPPED apply_queue_already_sent: the queue already sent this request's note")
            if verdict != "go":
                why = {"uncertain": "an earlier attempt has an unknown outcome; the queue never sends it again",
                       "busy": f"another worker ({who}) is sending it now",
                       "unsettled": "an earlier attempt has no readable outcome yet",
                       "missing": "no intent was written for it"}[verdict]
                return _answer(3, f"DEFERRED apply_queue_{verdict}: {why}; nothing was sent")
            try:
                res = gate(p)
            except BaseException as exc:
                self._finish(key, worker, False, f"the gate raised {type(exc).__name__}")
                raise
            self._finish(key, worker, posted(res), f"rc={getattr(res, 'returncode', '?')} "
                                                   f"{_first(getattr(res, 'stdout', '')) or _first(getattr(res, 'stderr', ''))}")
            return res
        return queued_gate

    def _finish(self, key: str, worker: str, was_posted: bool, answer: str) -> None:
        # A journal that cannot take the outcome costs nothing: the gate's answer still reaches the caller, the
        # intent stays `attempted`, and the next run settles it from the ledger.
        try:
            db = connect(self.path)
            try:
                finish(db, key, worker, ledger_path=self.ledger_path, posted=was_posted, answer=answer)
            finally:
                db.close()
        except (sqlite3.Error, OSError):
            pass


def session_for(campaign: str, ledger_path: str, *, policy_path: Path | str = POLICY_PATH,
                kill_file: str = KILL_FILE) -> Session | None:
    """The queue for this campaign's apply, or None for the direct path."""
    if not ledger_path or ledger_path == ":memory:" or not enabled_for(campaign, policy_path=policy_path,
                                                                        kill_file=kill_file):
        return None
    return Session(campaign, ledger_path)


# ---------------------------------------------------------------- read-outs

def status(db: sqlite3.Connection) -> dict[str, dict[str, int]]:
    out: dict[str, dict[str, int]] = {}
    for campaign, state, n in db.execute("SELECT campaign, state, COUNT(*) FROM intents GROUP BY 1, 2"):
        out.setdefault(campaign, {})[state] = n
    return out


def verify(db: sqlite3.Connection, ledger_path: str, campaign: str, *, now: float | None = None) -> dict[str, Any]:
    """The acceptance read: every queued send against the verify ledger. All of `must_be_zero` must be 0."""
    now = time.time() if now is None else now
    states = dict(db.execute("SELECT state, COUNT(*) FROM intents WHERE campaign = ? GROUP BY 1", (campaign,)))
    dup = no_row = 0
    for rkey, state in db.execute("SELECT request_key, state FROM intents WHERE campaign = ? AND attempts > 0",
                                  (campaign,)).fetchall():
        rows = ledger_rows(ledger_path, campaign, rkey)
        if sum(1 for _, s, _ in rows if s in ("sent", "attempted")) > 1:
            dup += 1
        if state == "sent" and not any(s == "sent" for _, s, _ in rows):
            no_row += 1
    orphans = db.execute("SELECT COUNT(*) FROM intents WHERE campaign = ? AND state = 'attempted' AND lease_until < ?",
                         (campaign, now)).fetchone()[0]
    first, last = db.execute("SELECT MIN(done_at), MAX(done_at) FROM intents WHERE campaign = ? AND state = 'sent'",
                             (campaign,)).fetchone()
    return {"campaign": campaign, "states": states, "sent": states.get("sent", 0),
            "uncertain": states.get("uncertain", 0), "first_sent_at": first, "last_sent_at": last,
            "must_be_zero": {"requests_with_two_notes": dup, "orphans": orphans, "sent_without_ledger_row": no_row}}


# ---------------------------------------------------------------- the kill -9 proof (scratch files only)

def _chaos_payloads(n: int) -> list[dict[str, Any]]:
    return [{"user": {"id": str(5000 + i), "email": f"c{i}@example.test"},
             "credits": [{"request_id": f"claim-{i}", "profile_id": f"p{i}"}]} for i in range(n)]


def _chaos_gate(scratch: str, latency_s: float) -> Callable[[dict[str, Any]], Any]:
    """A stand-in for the gate that keeps the gate's contract: claim in the REAL verify ledger, then POST to a
    provider that keeps no key of ours, then finalise. A kill can land between any two steps."""
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    import verify_ledger  # noqa: PLC0415
    ledger = os.path.join(scratch, "ledger.sqlite3")

    def gate(p: dict[str, Any]) -> Any:
        rid = p["credits"][0]["request_id"]
        db = verify_ledger.connect(ledger)
        try:
            c = verify_ledger.claim(db, user_key=p["user"]["email"], day=verify_ledger.stamp()[:10], request_ids=[rid],
                                    message_type="email", approved_by="chaos", approval_ref="chaos",
                                    campaign="claim-proof-ask", user_id=p["user"]["id"],
                                    refs=[{"request_id": rid, "profile_id": p["credits"][0]["profile_id"], "track_id": ""}])
            if c.get("result") != "claimed":
                return _answer(0, f"SKIPPED {c.get('result')}")
            time.sleep(latency_s)
            prov = sqlite3.connect(os.path.join(scratch, "provider.sqlite3"), timeout=120, isolation_level=None)
            try:
                prov.execute("INSERT INTO deliveries (request_id, at) VALUES (?, ?)", (rid, time.time()))
            finally:
                prov.close()
            time.sleep(latency_s)
            verify_ledger.finalize(db, message_row=c["message_row"], status="sent", message_id=f"fake-{rid}")
            return _answer(0, "POSTED credits=1")
        finally:
            db.close()
    return gate


def _chaos_worker(scratch: str, n: int, latency_s: float, lease_s: float, seed: int) -> int:
    s = Session("claim-proof-ask", os.path.join(scratch, "ledger.sqlite3"), lease_s=lease_s)
    payloads = _chaos_payloads(n)
    random.Random(seed).shuffle(payloads)      # every worker walks ALL the intents, so they contend for each one
    send = s.open(payloads, _chaos_gate(scratch, latency_s))
    for p in payloads:
        send(p)
    return 0


def chaos(n: int, workers: int, latency_ms: float) -> dict[str, Any]:
    """N workers walk the same intents; half are killed with SIGKILL mid-batch; fresh workers finish the queue."""
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    import verify_ledger  # noqa: PLC0415
    lease = 3.0
    with tempfile.TemporaryDirectory(prefix="apply-queue-chaos-") as scratch:
        ledger = os.path.join(scratch, "ledger.sqlite3")
        verify_ledger.connect(ledger).close()
        prov = sqlite3.connect(os.path.join(scratch, "provider.sqlite3"), isolation_level=None)
        prov.execute("PRAGMA journal_mode=WAL")
        prov.execute("CREATE TABLE deliveries (request_id TEXT NOT NULL, at REAL NOT NULL)")

        def spawn(k: int, seed0: int) -> list[subprocess.Popen]:
            return [subprocess.Popen([sys.executable, __file__, "_chaos-worker", "--scratch", scratch, "--jobs", str(n),
                                      "--latency-ms", str(latency_ms), "--lease", str(lease), "--seed", str(seed0 + i)])
                    for i in range(k)]

        t0 = time.time()
        procs = spawn(workers, 0)
        while prov.execute("SELECT COUNT(*) FROM deliveries").fetchone()[0] < n * 0.3:
            if all(p.poll() is not None for p in procs):
                break
            time.sleep(0.01)
        killed = procs[: workers // 2]
        for p in killed:
            p.send_signal(signal.SIGKILL)
        db = connect(journal_path(ledger))
        at_kill = dict(db.execute("SELECT state, COUNT(*) FROM intents GROUP BY 1"))
        delivered_at_kill = prov.execute("SELECT COUNT(*) FROM deliveries").fetchone()[0]
        for p in procs:
            p.wait()
        time.sleep(lease + 0.5)                # the dead workers' leases run out
        rounds = 0
        while db.execute("SELECT COUNT(*) FROM intents WHERE state IN ('queued','attempted')").fetchone()[0] and rounds < 6:
            for p in spawn(workers, 100 * (rounds + 1)):
                p.wait()
            rounds += 1
        took = time.time() - t0
        v = verify(db, ledger, "claim-proof-ask")
        twice = prov.execute("SELECT COUNT(*) FROM (SELECT 1 FROM deliveries GROUP BY request_id HAVING COUNT(*) > 1)").fetchone()[0]
        delivered = prov.execute("SELECT COUNT(DISTINCT request_id) FROM deliveries").fetchone()[0]
        led = dict(sqlite3.connect(ledger).execute(
            "SELECT status, COUNT(*) FROM verify_messages WHERE campaign = 'claim-proof-ask' GROUP BY 1"))
        unc_delivered = 0
        for (rkey,) in db.execute("SELECT request_key FROM intents WHERE state = 'uncertain'").fetchall():
            unc_delivered += prov.execute("SELECT COUNT(*) FROM deliveries WHERE request_id = ?", (rkey,)).fetchone()[0]
        settled = dict(db.execute("SELECT event, COUNT(*) FROM intent_events WHERE worker = 'settle' GROUP BY 1"))
        db.close()
        ok = (twice == 0 and not any(v["must_be_zero"].values()) and at_kill.get("attempted", 0) > 0
              and v["sent"] + v["uncertain"] == n and v["sent"] == led.get("sent", 0)
              and v["uncertain"] == led.get("attempted", 0) and delivered == v["sent"] + unc_delivered)
        return {"ok": ok, "intents": n, "workers": workers, "killed": len(killed), "seconds": round(took, 1),
                "states_at_kill": at_kill, "in_flight_at_kill": at_kill.get("attempted", 0),
                "delivered_at_kill": delivered_at_kill, "final_states": v["states"], "ledger_rows": led,
                "settled_from_ledger": settled, "provider": {"requests_delivered": delivered,
                                                             "requests_delivered_twice": twice},
                "uncertain_that_were_delivered": unc_delivered, "must_be_zero": v["must_be_zero"]}


# ---------------------------------------------------------------- CLI

def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    for name in ("status", "verify", "resolve"):
        s = sub.add_parser(name)
        s.add_argument("--ledger", required=True, help="the verify ledger; the queue's journal is the file beside it")
        if name != "status":
            s.add_argument("--campaign", default="claim-proof-ask")
        if name == "resolve":
            s.add_argument("--idem", required=True)
            s.add_argument("--as", dest="as_state", required=True, choices=("sent", "queued"))
            s.add_argument("--by", required=True)
            s.add_argument("--note", default="")
    c = sub.add_parser("chaos", help="kill -9 proof on scratch files; takes no --ledger on purpose")
    c.add_argument("--jobs", type=int, default=300)
    c.add_argument("--workers", type=int, default=8)
    c.add_argument("--latency-ms", type=float, default=5.0)
    w = sub.add_parser("_chaos-worker")
    w.add_argument("--scratch", required=True)
    w.add_argument("--jobs", type=int, required=True)
    w.add_argument("--latency-ms", type=float, required=True)
    w.add_argument("--lease", type=float, required=True)
    w.add_argument("--seed", type=int, required=True)
    a = ap.parse_args(argv)
    if a.cmd == "_chaos-worker":
        return _chaos_worker(a.scratch, a.jobs, a.latency_ms / 1000.0, a.lease, a.seed)
    if a.cmd == "chaos":
        out = chaos(a.jobs, a.workers, a.latency_ms)
        print(json.dumps(out, indent=1, sort_keys=True))
        return 0 if out["ok"] else 1
    path = journal_path(a.ledger)
    if not os.path.exists(path):
        print(f"no journal at {path}: the queue has not run against this ledger", file=sys.stderr)
        return 2
    db = connect(path)
    try:
        if a.cmd == "status":
            print(json.dumps(status(db), indent=1, sort_keys=True))
            return 0
        if a.cmd == "verify":
            out = verify(db, a.ledger, a.campaign)
            print(json.dumps(out, indent=1, sort_keys=True))
            return 1 if any(out["must_be_zero"].values()) else 0
        done = resolve(db, a.idem, a.as_state, a.by, a.note)
        print("resolved" if done else "no uncertain intent has that key")
        return 0 if done else 1
    finally:
        db.close()


if __name__ == "__main__":
    sys.exit(main())
