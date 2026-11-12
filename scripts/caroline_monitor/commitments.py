"""The promise ledger: what Caroline committed us to, and whether we came back.

When Caroline cannot settle something in the thread she tells the customer that someone will take
it from here, or that it sits in a queue and they will hear. Each of those sentences is a
COMMITMENT, and until now nothing recorded it: the promise was made, and no job knew it existed.

This module turns the sentences into rows. It is driven by the same reader as the monitor
(`rules.read_events`), so "she promised" means exactly what the headline means, and there is no
second classifier.

The rules, each one a line of code below and a test in tests/test_caroline_commitments.py:

* A commitment is OPENED BY CODE from what was actually sent (a person promise or a queue line),
  never by asking the model to remember to write one down.
* Its owner is a rule, a job or a tool: `policies/caroline-shapes.json` -> `commitments.kinds`.
  A person is never an owner. A shape nobody owns yet is recorded as UNBACKED and counted
  anyway, because a promise we have no way to keep is the one that most needs to be visible.
* It is CLOSED ONLY BY A MESSAGE SENT ON THE SAME THREAD: a person's reply, or a message we
  started ourselves that says something other than "still in the queue". A conversation being
  closed, a request being approved, a ticket moving: none of those close it, because none of
  them told the customer anything.
* A message we started that only says where things stand ("still reviewing") is a CHECK-IN. It
  keeps the promise for that day and moves the next check forward. It does not close anything.
* An answer to a NEW message from the customer is not us coming back. The customer came back.
  This is strict on purpose, and it undercounts: when Caroline answers a chase with the actual
  result, the customer was told, and this ledger still shows the promise as broken, because
  from the events alone that answer cannot be told apart from her answering the next question
  in the same sitting (1,469 of the 1,896 threads where a later reply exists, on the 11-11
  corpus). An undercount of kept promises is the safe direction for a number that pages.
* The due time is OURS. It is the moment a job must have said something, and it is never told
  to the customer, so the ledger makes no date promise a job could fail to keep.

Nothing here sends anything. The sender for every request-backed kind is the existing request
status driver (scripts/request_comms/), which asks `thread_for` where the customer is waiting
so that its line lands on that thread instead of beside it.
"""
from __future__ import annotations

import json
import os
import re
import sqlite3

from . import rules

HOUR = 3600
DAY = 86400
OWNER = re.compile(r"^(job|rule|tool):[a-z0-9][a-z0-9_.\-]*$")
UNBACKED = "unbacked"
DEFAULTS = {"due_hours": 24, "followup_min_seconds": 300}
REQUEST_LINES = os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))),
                             "policies", "request-status-lines.json")
REQUEST_COMMS_LIVE = "/etc/hydra/request-comms.live"
REQUEST_COMMS_DISABLED = "/etc/hydra/request-comms.disabled"

_OURS = (rules.EV_CAROLINE, rules.EV_HUMAN_REPLY)
_PROMISES = (rules.EV_PROMISE, rules.EV_QUEUE)


def load_request_lines(path=None):
    try:
        with open(path or REQUEST_LINES) as f:
            doc = json.load(f)
    except (OSError, ValueError):
        return {}
    return doc if isinstance(doc, dict) else {}


def outbox_reason(policy, row):
    """Why the line a due commitment calls for would not be sent, or "" when it would.

    Read from the real switches: the kind's owner and request type, the `waiting` line in
    policies/request-status-lines.json and the driver's own `enabled`, plus
    `/etc/hydra/request-comms.live` (override `REQUEST_COMMS_LIVE`), which the driver also
    requires before it sends anything. A row is `queued` only when every switch a real send
    needs is on.
    """
    if not row.get("owner"):
        return "no_owner"
    request_type = row.get("request_type")
    if not request_type:
        return "no_request_type"
    line = ((policy.get("lines") or {}).get(request_type) or {}).get("waiting")
    if not isinstance(line, dict):
        return "line_missing"
    if not line.get("enabled"):
        return "line_disabled"
    if not str(line.get("approval_ref") or "").strip():
        return "line_unapproved"
    if not policy.get("enabled"):
        return "driver_disabled"
    if os.path.exists(os.environ.get("REQUEST_COMMS_DISABLED", REQUEST_COMMS_DISABLED)):
        return "driver_killed"
    if not os.path.exists(os.environ.get("REQUEST_COMMS_LIVE", REQUEST_COMMS_LIVE)):
        return "driver_not_live"
    return ""


def config(register):
    cfg = dict(DEFAULTS)
    cfg.update({k: v for k, v in ((register or {}).get("commitments") or {}).items() if k in DEFAULTS})
    return cfg


def kind_of(register, shape):
    """(kind id, kind row) for a shape. A shape no kind lists is UNBACKED: nobody owns it."""
    for kid, row in (((register or {}).get("commitments") or {}).get("kinds") or {}).items():
        if shape in (row.get("shapes") or ()):
            return kid, row
    return UNBACKED, {}


def validate(register, shape_ids):
    """Errors in the `commitments` section. An owner that is not a rule, a job or a tool is the
    one this exists to refuse."""
    section = (register or {}).get("commitments")
    if not isinstance(section, dict):
        return ["commitments: missing section"]
    errors, seen = [], {}
    for key in DEFAULTS:
        if not isinstance(section.get(key), int) or section[key] <= 0:
            errors.append(f"commitments.{key}: must be a positive whole number")
    kinds = section.get("kinds")
    if not isinstance(kinds, dict) or not kinds:
        return errors + ["commitments.kinds: missing"]
    if UNBACKED in kinds:
        errors.append(f"commitments.kinds.{UNBACKED}: reserved for shapes no kind lists")
    for kid, row in kinds.items():
        where = f"commitments.kinds.{kid}"
        for field in ("doing", "trigger"):
            if not str(row.get(field) or "").strip():
                errors.append(f"{where}: `{field}` is required (what is being done, and what resolves it)")
        owner = row.get("owner")
        if owner is None:
            if not str(row.get("unbacked_reason") or "").strip():
                errors.append(f"{where}: no owner needs `unbacked_reason`. A promise nobody can keep has to say so")
        elif not isinstance(owner, str) or not OWNER.match(owner):
            errors.append(f"{where}: owner {owner!r} must be a rule, a job or a tool "
                          "(`job:<name>`, `rule:<name>`, `tool:<name>`). A person is never an owner")
        if not isinstance(row.get("priority"), int) or row["priority"] < 1:
            errors.append(f"{where}: `priority` must be a whole number from 1")
        shapes = row.get("shapes")
        if not isinstance(shapes, list) or not shapes:
            errors.append(f"{where}: `shapes` must list at least one shape")
            continue
        for shape in shapes:
            if shape not in shape_ids:
                errors.append(f"{where}: {shape!r} is not a classifier shape")
            elif shape in seen:
                errors.append(f"{where}: shape {shape} is already owned by {seen[shape]}")
            seen[shape] = kid
    return errors


def derive(events, cfg=None, now=None):
    """Every commitment in one thread, oldest first, from its events alone.

    Each is a dict: `promised_at`, `promise` ("person" or "queue"), `told` (times we came back
    without closing it), `due_at` (when a job next owes the customer a word; None once closed),
    `closed_at`, `closed_by` ("human_reply" or "message", else None), and `marks`.

    A mark is one `[time, kept]` per due time: `[when we came back, True]` if we came back by
    then, `[the due time, False]` if it passed with nothing sent. A late message closes or
    re-arms the commitment and does not turn the broken mark into a kept one. A due time still
    ahead of `now` has no mark yet.

    A later promise inside an open commitment opens nothing: one thread waits on one thing at a
    time, and counting each repeat of the hand-off line would turn one broken promise into five.
    """
    cfg = cfg or DEFAULTS
    due_s = int(cfg["due_hours"]) * HOUR
    gap = int(cfg["followup_min_seconds"])
    events = [e for e in events if now is None or e[0] <= now]
    at = {}
    for ts, code in events:
        at.setdefault(ts, set()).add(code)
    out, current = [], None
    last_ours, customer_since, seen = None, False, set()
    for ts, code in events:
        if code == rules.EV_CUSTOMER:
            customer_since = True
            continue
        if code not in _OURS or (ts, code) in seen:
            continue
        seen.add((ts, code))
        promises = bool(at[ts].intersection(_PROMISES))
        human = code == rules.EV_HUMAN_REPLY
        # We started it: nothing from the customer since our last message, and not the second
        # half of the reply we were already sending.
        ours_first = not customer_since and last_ours is not None and ts - last_ours >= gap
        if current is not None and ts > current["promised_at"] and (human or ours_first):
            current["answered"].append([current["due_at"], ts])
            current["marks"].append([ts, True] if ts <= current["due_at"] else [current["due_at"], False])
            if human or not promises:
                current.update(closed_at=ts, closed_by="human_reply" if human else "message", due_at=None)
                out.append(current)
                current = None
            else:
                current["told"].append(ts)
                current["due_at"] = ts + due_s
        elif current is None and promises and not human:
            current = {"promised_at": ts, "promise": "person" if rules.EV_PROMISE in at[ts] else "queue",
                       "told": [], "due_at": ts + due_s, "closed_at": None, "closed_by": None, "marks": [],
                       "answered": []}
        last_ours, customer_since = ts, False
    if current is not None:
        if now is not None and current["due_at"] <= now:
            current["marks"].append([current["due_at"], False])
        out.append(current)
    return out


def summarize(facts, register, now, window=DAY):
    """The four numbers the support instrument carries, plus who owns what is open.

    `promises_kept_24h` counts the times we came back inside the due time during the last
    `window` seconds; `promises_broken_24h` counts the due times that passed in that window with
    nothing sent. A promise breaks ONCE, when it goes overdue: after that it is carried by
    `commitments_overdue`, the stock, so the two numbers say different things.
    """
    cfg = config(register)
    out = {"commitments_open": 0, "commitments_overdue": 0, "promises_kept_24h": 0, "promises_broken_24h": 0,
           "commitments_open_unbacked": 0, "commitments_closed_24h": 0, "oldest_overdue_h": 0,
           "open_by_kind": {}, "overdue_by_kind": {}}
    for fact in facts:
        kind, row = kind_of(register, fact["shape"])
        for c in derive(fact["events"], cfg, now):
            for when, kept in c["marks"]:
                if now - window < when <= now:
                    out["promises_kept_24h" if kept else "promises_broken_24h"] += 1
            if c["closed_at"] is not None:
                out["commitments_closed_24h"] += now - window < c["closed_at"] <= now
                continue
            out["commitments_open"] += 1
            out["open_by_kind"][kind] = out["open_by_kind"].get(kind, 0) + 1
            out["commitments_open_unbacked"] += not row.get("owner")
            if c["due_at"] <= now:
                out["commitments_overdue"] += 1
                out["overdue_by_kind"][kind] = out["overdue_by_kind"].get(kind, 0) + 1
                out["oldest_overdue_h"] = max(out["oldest_overdue_h"], (now - c["due_at"]) // HOUR)
    return out


# --- the durable rows -------------------------------------------------------------------------
SCHEMA = """
CREATE TABLE IF NOT EXISTS commitments (
    conversation_id TEXT NOT NULL,
    promised_at     INTEGER NOT NULL,
    recorded_at     INTEGER NOT NULL,
    promise         TEXT NOT NULL,
    shape           TEXT NOT NULL,
    kind            TEXT NOT NULL,
    doing           TEXT NOT NULL,
    resolves_on     TEXT NOT NULL,
    owner           TEXT,
    contact_id      TEXT NOT NULL DEFAULT '',
    last_told_at    INTEGER,
    due_at          INTEGER,
    closed_at       INTEGER,
    closed_by       TEXT,
    PRIMARY KEY (conversation_id, promised_at)
);
CREATE INDEX IF NOT EXISTS commitments_open ON commitments (contact_id, closed_at);
CREATE TABLE IF NOT EXISTS commitment_outbox (
    conversation_id TEXT NOT NULL,
    promised_at     INTEGER NOT NULL,
    due_at          INTEGER NOT NULL,
    enqueued_at     INTEGER NOT NULL,
    kind            TEXT NOT NULL,
    owner           TEXT,
    request_type    TEXT,
    line_state      TEXT NOT NULL,
    state           TEXT NOT NULL,
    held_reason     TEXT,
    sent_at         INTEGER,
    PRIMARY KEY (conversation_id, promised_at, due_at)
);
CREATE INDEX IF NOT EXISTS commitment_outbox_state ON commitment_outbox (state);
"""


def ensure_schema(db):
    db.executescript(SCHEMA)


def _outbox_answered(db, conversation_id, promised_at, answered, closed_at):
    for due_at, sent_at in answered:
        db.execute(
            "UPDATE commitment_outbox SET state='sent', sent_at=? WHERE conversation_id=? AND promised_at=? "
            "AND due_at=? AND state IN ('queued','held')",
            (sent_at, conversation_id, promised_at, due_at))
    if closed_at is not None:
        db.execute(
            "UPDATE commitment_outbox SET state='superseded' WHERE conversation_id=? AND promised_at=? "
            "AND state IN ('queued','held')",
            (conversation_id, promised_at))


def _outbox_enqueue(db, conversation_id, c, kind, row, policy, now):
    if c["closed_at"] is not None or c["due_at"] is None or c["due_at"] > now:
        return
    exists = db.execute(
        "SELECT 1 FROM commitment_outbox WHERE conversation_id=? AND promised_at=? AND due_at=?",
        (conversation_id, c["promised_at"], c["due_at"])).fetchone()
    if exists:
        return
    reason = outbox_reason(policy, row)
    db.execute(
        "INSERT INTO commitment_outbox (conversation_id, promised_at, due_at, enqueued_at, kind, owner, "
        "request_type, line_state, state, held_reason) VALUES (?,?,?,?,?,?,?,?,?,?)",
        (conversation_id, c["promised_at"], c["due_at"], now, kind, row.get("owner"),
         row.get("request_type"), "waiting", "held" if reason else "queued", reason or None))


def outbox_counts(db):
    """The outbox rows still waiting on a send, for support-backlog.json."""
    out = {"messages_queued": 0, "messages_held": 0, "messages_held_by_reason": {}}
    for state, reason, count in db.execute(
            "SELECT state, held_reason, COUNT(*) FROM commitment_outbox "
            "WHERE state IN ('queued','held') GROUP BY state, held_reason"):
        if state == "queued":
            out["messages_queued"] += count
        else:
            out["messages_held"] += count
            key = reason or "unknown"
            out["messages_held_by_reason"][key] = out["messages_held_by_reason"].get(key, 0) + count
    return out


def sync(db, thread_id, contact_id, fact, register, now, policy=None):
    """Rewrite one thread's rows from its events. Returns how many are open.

    A row is the result of reading the thread, so re-reading the thread is the only thing that
    changes it: there is no `close` call anywhere, and so no way to close a commitment except
    for a sent message to appear on the thread. `recorded_at` survives the rewrite: it is when
    this ledger first knew.
    """
    cfg = config(register)
    kind, row = kind_of(register, fact["shape"])
    policy = load_request_lines() if policy is None else policy
    conversation_id = str(thread_id)
    known = dict(db.execute(
        "SELECT promised_at, recorded_at FROM commitments WHERE conversation_id = ?", (conversation_id,)))
    db.execute("DELETE FROM commitments WHERE conversation_id = ?", (conversation_id,))
    derived = derive(fact["events"], cfg, now)
    promised = {c["promised_at"] for c in derived}
    for (promised_at,) in db.execute(
            "SELECT DISTINCT promised_at FROM commitment_outbox WHERE conversation_id = ?",
            (conversation_id,)).fetchall():
        if promised_at not in promised:
            db.execute("DELETE FROM commitment_outbox WHERE conversation_id = ? AND promised_at = ?",
                       (conversation_id, promised_at))
    still_open = 0
    for c in derived:
        still_open += c["closed_at"] is None
        db.execute(
            "INSERT INTO commitments VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
            (conversation_id, c["promised_at"], known.get(c["promised_at"], now), c["promise"], fact["shape"],
             kind, row.get("doing") or "not owned by any rule, job or tool yet",
             row.get("trigger") or "nothing: no owner", row.get("owner"), str(contact_id or ""),
             max(c["told"]) if c["told"] else None, c["due_at"], c["closed_at"], c["closed_by"]))
        _outbox_enqueue(db, conversation_id, c, kind, row, policy, now)
        _outbox_answered(db, conversation_id, c["promised_at"], c["answered"], c["closed_at"])
    return still_open


def forget(db, thread_ids):
    ids = [(str(i),) for i in thread_ids]
    db.executemany("DELETE FROM commitments WHERE conversation_id = ?", ids)
    db.executemany("DELETE FROM commitment_outbox WHERE conversation_id = ?", ids)


def open_rows(db):
    cur = db.execute("SELECT kind, owner, COUNT(*) FROM commitments WHERE closed_at IS NULL GROUP BY kind, owner")
    return [{"kind": k, "owner": o, "open": n} for k, o, n in cur]


def default_db_path():
    from .store import DB_NAME, DEFAULT_STATE_DIR
    return os.path.join(DEFAULT_STATE_DIR, DB_NAME)


def thread_for(contact_id, request_type, register=None, db_path=None):
    """The conversation where this contact is waiting on a `request_type` commitment, or "".

    Asked by the request status driver just before it sends, so the status line goes onto the
    thread that carries the promise. The newest open commitment wins. Any failure answers "":
    the driver then sends the way it always did, which is never worse than not sending.
    """
    if not contact_id or not request_type:
        return ""
    try:
        if register is None:
            from . import fixloop
            register = fixloop.load_register()
        kinds = [kid for kid, row in ((register.get("commitments") or {}).get("kinds") or {}).items()
                 if row.get("request_type") == request_type]
        if not kinds:
            return ""
        path = db_path or default_db_path()
        db = sqlite3.connect(f"file:{path}?mode=ro", uri=True, timeout=5)
        try:
            marks = ",".join("?" * len(kinds))
            got = db.execute(
                f"SELECT conversation_id FROM commitments WHERE contact_id = ? AND closed_at IS NULL "
                f"AND kind IN ({marks}) ORDER BY promised_at DESC LIMIT 1", [str(contact_id)] + kinds).fetchone()
        finally:
            db.close()
        return str(got[0]) if got else ""
    except Exception:  # noqa: BLE001 - see the docstring: an unreadable ledger must not stop a send
        return ""
