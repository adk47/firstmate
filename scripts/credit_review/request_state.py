#!/usr/bin/env python3
"""request_state: a declared per-request state machine with a transition log.

Fable's ruling: "Nothing else is measurable until this exists." Request state was
inferred from ledger rows; now it is declared, with entered_at, reason and actor.

States (a request is in exactly one):
  OPEN_UNASKED      nobody has ever asked the customer
  ASKED             we asked; ball with the customer
  REMINDED          second ask sent
  PROOF_RECEIVED    customer sent a document; not yet compared
  PROOF_MISMATCH    document names someone else
  PROOF_INSUFFICIENT document missing a required element
  READY             document verifies the claim; awaiting approval write
  APPROVED          approved (by proof, precedent, or validator)
  REJECTED          rejected
  CLOSED_NO_PROOF   closed at the deadline without a document (reopenable)
  DUPLICATE         closed as a duplicate of an already-approved credit

Every transition appends to request_state_log. Nothing updates in place.
"""
import os, sqlite3, sys, time

LEDGER = os.environ.get("LEDGER", "/var/lib/hydra/credit-review/ledger.sqlite3")

DDL = """
CREATE TABLE IF NOT EXISTS request_state (
  request_id   TEXT PRIMARY KEY,
  user_key     TEXT,
  state        TEXT NOT NULL,
  entered_at   TEXT NOT NULL,
  reason       TEXT,
  actor        TEXT
);
CREATE TABLE IF NOT EXISTS request_state_log (
  id         INTEGER PRIMARY KEY AUTOINCREMENT,
  request_id TEXT NOT NULL,
  from_state TEXT,
  to_state   TEXT NOT NULL,
  at         TEXT NOT NULL,
  reason     TEXT,
  actor      TEXT
);
CREATE INDEX IF NOT EXISTS request_state_log_req ON request_state_log(request_id);
CREATE INDEX IF NOT EXISTS request_state_state ON request_state(state);
CREATE INDEX IF NOT EXISTS request_state_user ON request_state(user_key);
"""

def connect():
    db = sqlite3.connect(LEDGER, timeout=60)
    db.execute("PRAGMA busy_timeout=60000")
    db.execute("PRAGMA journal_mode=WAL")
    return db

def init(db):
    for stmt in DDL.split(";"):
        if stmt.strip():
            db.execute(stmt)
    db.commit()

def transition(db, request_id, to_state, reason="", actor="system", at=None):
    """Append a transition. No-op if already in that state."""
    at = at or time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    row = db.execute("SELECT state FROM request_state WHERE request_id=?", (request_id,)).fetchone()
    frm = row[0] if row else None
    if frm == to_state:
        return False
    db.execute(
        "INSERT INTO request_state(request_id,user_key,state,entered_at,reason,actor) "
        "VALUES(?,?,?,?,?,?) ON CONFLICT(request_id) DO UPDATE SET "
        "state=excluded.state, entered_at=excluded.entered_at, "
        "reason=excluded.reason, actor=excluded.actor",
        (request_id, None, to_state, at, reason, actor))
    db.execute(
        "INSERT INTO request_state_log(request_id,from_state,to_state,at,reason,actor) "
        "VALUES(?,?,?,?,?,?)", (request_id, frm, to_state, at, reason, actor))
    return True

def backfill(db):
    """Derive the current state of every request the ledger knows about."""
    n = 0
    # 1. every request that appears in verify_messages.request_ids_json
    for (rids, kind, status, sent_at, last_reply, proof, ukey) in db.execute(
        "SELECT request_ids_json, kind, status, sent_at, last_reply_at, proof_attachments, user_key "
        "FROM verify_messages WHERE request_ids_json IS NOT NULL"):
        try:
            ids = __import__("json").loads(rids)
        except Exception:
            continue
        for rid in ids:
            rid = str(rid)
            if status in ("sent", "claimed", "attempted"):
                st = "REMINDED" if kind.startswith("reminder") else "ASKED"
            elif status == "duplicate_suppressed":
                st = "DUPLICATE"
            else:
                continue
            if proof and int(proof) > 0:
                st = "PROOF_RECEIVED"
            # >>> not in node-8's copy
            # A request core approved stays APPROVED: an old ask must not put it back in the
            # undecided count. transition() does nothing for a request already in the state.
            held = db.execute("SELECT state FROM request_state WHERE request_id=?", (rid,)).fetchone()
            if held and held[0] == "APPROVED":
                st = "APPROVED"
            # <<< not in node-8's copy
            if transition(db, rid, st, f"backfill from {kind}/{status}", "backfill", sent_at):
                n += 1
            db.execute("UPDATE request_state SET user_key=? WHERE request_id=? AND user_key IS NULL", (ukey, rid))
    db.commit()
    return n

def report(db):
    rows = db.execute("SELECT state, count(*) FROM request_state GROUP BY state ORDER BY 2 DESC").fetchall()
    total = sum(r[1] for r in rows)
    print(f"request_state: {total} requests")
    for st, n in rows:
        print(f"  {st:20s} {n:>8d}")

if __name__ == "__main__":
    db = connect(); init(db)
    cmd = sys.argv[1] if len(sys.argv) > 1 else "report"
    if cmd == "backfill":
        print(f"backfilled {backfill(db)} transitions")
    report(db)
