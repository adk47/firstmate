-- The request ledger's schema as node-8 holds it: sqlite_master of
-- /var/lib/hydra/credit-review/ledger.sqlite3, read 2026-11-14T12:48:37Z (read-only), verbatim.
-- It is NOT the DDL in scripts/credit_review/request_state.py: the live table has two more
-- columns (expires_at, decision_reason) and a trigger, rs_audit, that no tracked file creates.
-- Tests run against this so they meet what a write meets in production. Do not tidy it.
CREATE TABLE request_state (
  request_id   TEXT PRIMARY KEY,
  user_key     TEXT,
  state        TEXT NOT NULL,
  entered_at   TEXT NOT NULL,
  reason       TEXT,
  actor        TEXT
, expires_at TEXT, decision_reason TEXT);
CREATE TABLE request_state_log (
  id         INTEGER PRIMARY KEY AUTOINCREMENT,
  request_id TEXT NOT NULL,
  from_state TEXT,
  to_state   TEXT NOT NULL,
  at         TEXT NOT NULL,
  reason     TEXT,
  actor      TEXT
);
CREATE TABLE state_transitions(id INTEGER PRIMARY KEY, request_id TEXT, from_state TEXT, to_state TEXT, at TEXT, actor TEXT, reason TEXT);
CREATE INDEX request_state_log_req ON request_state_log(request_id);
CREATE INDEX request_state_state ON request_state(state);
CREATE INDEX request_state_user ON request_state(user_key);
CREATE TRIGGER rs_audit AFTER UPDATE OF state ON request_state BEGIN INSERT INTO state_transitions(request_id,from_state,to_state,at,actor,reason) VALUES(NEW.request_id,OLD.state,NEW.state,datetime('now'),'trigger',NULL); END;
