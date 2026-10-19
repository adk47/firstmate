"""SQLite ledger: the review record for every audited or reviewed request.

Lives under /var/lib/hydra (deploy-proof; /opt/hydra is rsync-overwritten).
One row per (request_id, mode, reviewed_at). The newest row per request and
mode is the current verdict. The digest, the weekly metric, the human
re-review queue and the approve-gate lookup all read from here.
"""

from __future__ import annotations

import json
import os
import sqlite3
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Iterable

DEFAULT_PATH = os.environ.get("CREDIT_REVIEW_LEDGER", "/var/lib/hydra/credit-review/ledger.sqlite3")

SCHEMA = """
CREATE TABLE IF NOT EXISTS reviews (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  request_id TEXT NOT NULL,
  mode TEXT NOT NULL,                -- audit | review | eval
  phase TEXT NOT NULL,               -- shadow | advise | live
  reviewed_at TEXT NOT NULL,
  verdict TEXT NOT NULL,
  confidence REAL NOT NULL,
  basis TEXT NOT NULL,
  big_track INTEGER NOT NULL,
  profile_id TEXT,
  track_id TEXT,
  track_title TEXT,
  claimed_roles TEXT,
  spotify_popularity INTEGER,
  approved_at TEXT,
  status_at_review TEXT,
  approver_alert TEXT,
  model TEXT,
  cost_usd REAL,
  prompt_version TEXT,
  reasons_json TEXT,
  evidence_json TEXT,
  judge_json TEXT,
  alerted INTEGER NOT NULL DEFAULT 0,
  label TEXT                          -- eval only: known_bad | known_good
);
CREATE INDEX IF NOT EXISTS reviews_req ON reviews(request_id, mode);
CREATE INDEX IF NOT EXISTS reviews_time ON reviews(reviewed_at);
CREATE INDEX IF NOT EXISTS reviews_profile ON reviews(profile_id);
CREATE TABLE IF NOT EXISTS rereview_queue (
  request_id TEXT PRIMARY KEY,
  queued_at TEXT NOT NULL,
  reason TEXT NOT NULL,
  verdict TEXT NOT NULL,
  resolved_at TEXT,
  resolution TEXT
);
CREATE TABLE IF NOT EXISTS state (k TEXT PRIMARY KEY, v TEXT NOT NULL);
-- Requests whose essential evidence (the trusted raw credits) could not be
-- read. They are NOT recorded as reviewed; every later run retries them from
-- this snapshot even after they leave the audit window (QA on hydra#1142).
CREATE TABLE IF NOT EXISTS evidence_retry (
  request_id TEXT NOT NULL,
  mode TEXT NOT NULL,
  first_failed_at TEXT NOT NULL,
  last_failed_at TEXT NOT NULL,
  attempts INTEGER NOT NULL DEFAULT 1,
  last_error TEXT NOT NULL,
  request_json TEXT NOT NULL,
  PRIMARY KEY (request_id, mode)
);
"""


def utcnow() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


class Ledger:
    def __init__(self, path: str | None = None):
        self.path = path or DEFAULT_PATH
        if self.path != ":memory:":
            Path(self.path).parent.mkdir(parents=True, exist_ok=True)
        self.db = sqlite3.connect(self.path, timeout=30)
        self.db.row_factory = sqlite3.Row
        self.db.executescript(SCHEMA)
        self.db.commit()

    def close(self) -> None:
        self.db.close()

    # -- writes -------------------------------------------------------------
    def record(self, row: dict[str, Any]) -> int:
        cols = ["request_id", "mode", "phase", "reviewed_at", "verdict", "confidence", "basis",
                "big_track", "profile_id", "track_id", "track_title", "claimed_roles",
                "spotify_popularity", "approved_at", "status_at_review", "approver_alert", "model",
                "cost_usd", "prompt_version", "reasons_json", "evidence_json", "judge_json", "label"]
        vals = []
        for c in cols:
            v = row.get(c)
            if c.endswith("_json") and v is not None and not isinstance(v, str):
                v = json.dumps(v, ensure_ascii=False, default=str)
            if c == "claimed_roles" and isinstance(v, list):
                v = ",".join(v)
            if c == "big_track":
                v = 1 if v else 0
            if c == "reviewed_at" and not v:
                v = utcnow()
            vals.append(v)
        cur = self.db.execute(
            f"INSERT INTO reviews ({','.join(cols)}) VALUES ({','.join('?' * len(cols))})", vals)
        self.db.commit()
        return int(cur.lastrowid)

    def mark_alerted(self, row_id: int) -> None:
        self.db.execute("UPDATE reviews SET alerted=1 WHERE id=?", (row_id,))
        self.db.commit()

    def queue_rereview(self, request_id: str, verdict: str, reason: str) -> bool:
        """Queue for human re-review; returns False if it was already queued."""
        cur = self.db.execute(
            "INSERT OR IGNORE INTO rereview_queue (request_id, queued_at, reason, verdict) VALUES (?,?,?,?)",
            (request_id, utcnow(), reason[:500], verdict))
        self.db.commit()
        return cur.rowcount == 1

    def note_evidence_failure(self, request: dict[str, Any], mode: str, error: str) -> bool:
        """Park a request whose essential evidence failed. Returns True on its
        FIRST failure (the caller alerts once), False on a repeat."""
        rid = str(request.get("id") or "")
        now = utcnow()
        cur = self.db.execute(
            "UPDATE evidence_retry SET last_failed_at=?, attempts=attempts+1, last_error=? "
            "WHERE request_id=? AND mode=?", (now, error[:500], rid, mode))
        fresh = cur.rowcount == 0
        if fresh:
            self.db.execute(
                "INSERT INTO evidence_retry (request_id, mode, first_failed_at, last_failed_at, last_error, request_json) "
                "VALUES (?,?,?,?,?,?)",
                (rid, mode, now, now, error[:500], json.dumps(request, ensure_ascii=False, default=str)))
        self.db.commit()
        return fresh

    def clear_evidence_failure(self, request_id: str, mode: str) -> None:
        self.db.execute("DELETE FROM evidence_retry WHERE request_id=? AND mode=?", (request_id, mode))
        self.db.commit()

    def evidence_retries(self, mode: str) -> list[dict[str, Any]]:
        """Parked request snapshots, oldest failure first."""
        rows = self.db.execute(
            "SELECT request_json FROM evidence_retry WHERE mode=? ORDER BY first_failed_at", (mode,)).fetchall()
        out: list[dict[str, Any]] = []
        for r in rows:
            try:
                req = json.loads(r["request_json"])
            except json.JSONDecodeError:
                continue
            if isinstance(req, dict):
                out.append(req)
        return out

    def evidence_retry_count(self, mode: str) -> tuple[int, str | None]:
        r = self.db.execute("SELECT COUNT(*) n, MIN(first_failed_at) oldest FROM evidence_retry WHERE mode=?",
                            (mode,)).fetchone()
        return int(r["n"]), r["oldest"]

    def set_state(self, k: str, v: str) -> None:
        self.db.execute("INSERT INTO state(k,v) VALUES(?,?) ON CONFLICT(k) DO UPDATE SET v=excluded.v", (k, v))
        self.db.commit()

    # -- reads --------------------------------------------------------------
    def get_state(self, k: str) -> str | None:
        r = self.db.execute("SELECT v FROM state WHERE k=?", (k,)).fetchone()
        return r["v"] if r else None

    def model_checked_since(self, request_id: str, mode: str, ts: str) -> bool:
        r = self.db.execute("SELECT 1 FROM reviews WHERE request_id=? AND mode=? AND model IS NOT NULL "
                            "AND COALESCE(basis,'') != 'model_error' AND reviewed_at >= ? LIMIT 1",
                            (request_id, mode, ts)).fetchone()
        return r is not None

    def reviewed(self, request_id: str, mode: str) -> bool:
        r = self.db.execute("SELECT 1 FROM reviews WHERE request_id=? AND mode=? LIMIT 1", (request_id, mode)).fetchone()
        return r is not None

    def latest(self, request_ids: Iterable[str], mode: str) -> dict[str, sqlite3.Row]:
        out: dict[str, sqlite3.Row] = {}
        for rid in request_ids:
            r = self.db.execute(
                "SELECT * FROM reviews WHERE request_id=? AND mode=? ORDER BY id DESC LIMIT 1", (rid, mode)).fetchone()
            if r is not None:
                out[rid] = r
        return out

    def contradicted_by_profile(self) -> dict[str, int]:
        rows = self.db.execute(
            "SELECT profile_id, COUNT(DISTINCT request_id) n FROM reviews "
            "WHERE verdict IN ('CONTRADICTED','REJECT-RECOMMENDED') AND mode IN ('audit','review') "
            "GROUP BY profile_id").fetchall()
        return {r["profile_id"]: int(r["n"]) for r in rows if r["profile_id"]}

    def since(self, ts: str, mode: str, verdicts: Iterable[str] | None = None) -> list[sqlite3.Row]:
        q = "SELECT * FROM reviews WHERE reviewed_at >= ? AND mode = ?"
        args: list[Any] = [ts, mode]
        if verdicts:
            vs = list(verdicts)
            q += f" AND verdict IN ({','.join('?' * len(vs))})"
            args += vs
        return self.db.execute(q + " ORDER BY id", args).fetchall()

    def dearest_call_since(self, ts: str) -> float:
        """The most expensive single model call recorded since `ts` (0 if none).
        Seeds the per-call budget reservation so a run never launches a call
        it could only afford if calls were cheaper than they have been. A batched
        call's cost is split across its claims' rows, so each row's share is
        scaled back up by the call's batch_size."""
        r = self.db.execute(
            "SELECT COALESCE(MAX(cost_usd * COALESCE(CASE WHEN json_valid(judge_json) "
            "THEN json_extract(judge_json,'$.batch_size') END, 1)),0) c "
            "FROM reviews WHERE reviewed_at >= ? AND model IS NOT NULL", (ts,)).fetchone()
        return float(r["c"])

    def cost_since(self, ts: str) -> tuple[float, int]:
        r = self.db.execute("SELECT COALESCE(SUM(cost_usd),0) c, COUNT(*) n FROM reviews WHERE reviewed_at >= ? AND model IS NOT NULL",
                            (ts,)).fetchone()
        return float(r["c"]), int(r["n"])
