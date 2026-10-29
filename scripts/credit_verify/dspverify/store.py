"""The verifier's own append-only shadow store. Nothing else writes here and it writes nothing else.

Tables:
  dsp_runs      one row per run: kind (submit | verify | packets), mode (always shadow), counts.
  dsp_captures  one row per fresh-capture request this verifier filed (one per user group): the
                capture tag, requested_at, the request ids and tracks it covers, and every read of it.
  dsp_verdicts  one row per credit request per verify run: verdict, reason, need, confidence, the
                roles it would approve / decline / edit, the anchor, the blockers, and the FULL
                evidence (per role, per DSP) plus the packet's sha256. Append-only (triggers): the
                latest row per (request, version) stands; older rows stay for the audit.

Reversible by construction: a verdict is a row, never an action. Nothing in this store is read by
any writer; a consumer would need the captain's switch (policies/credit-approval-automation.json).
"""

from __future__ import annotations

import hashlib
import json
import os
import sqlite3
from datetime import datetime, timezone
from typing import Any, Iterable

from . import VERSION

DEFAULT_PATH = os.environ.get("CREDIT_DSP_VERIFY_STORE", "/var/lib/hydra-credit-verify/dsp-verify.sqlite")

SCHEMA = """
CREATE TABLE IF NOT EXISTS dsp_runs (
  run_id TEXT PRIMARY KEY,
  kind TEXT NOT NULL,                    -- submit | verify | packets
  mode TEXT NOT NULL DEFAULT 'shadow',   -- the only mode there is
  started_at TEXT NOT NULL,
  finished_at TEXT,
  version TEXT NOT NULL,
  counts_json TEXT
);
CREATE TABLE IF NOT EXISTS dsp_captures (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  run_id TEXT NOT NULL,
  key TEXT NOT NULL,                     -- '<user_id>#<n>' group key
  user_id INTEGER,
  capture_request_id TEXT,               -- the fresh_capture request tag; NULL when the submit failed
  requested_at TEXT,
  submitted_at TEXT NOT NULL,
  request_ids_json TEXT NOT NULL,        -- credit request ids covered
  tracks_json TEXT NOT NULL,             -- [{track_id, profile_id, roles, names}]
  submit_json TEXT NOT NULL,             -- the pod's answer (targets, enqueue_failed, error)
  last_read_at TEXT,
  last_read_json TEXT,
  reads INTEGER NOT NULL DEFAULT 0,
  closed INTEGER NOT NULL DEFAULT 0      -- every reading final (or past the window): verified for good
);
CREATE INDEX IF NOT EXISTS dsp_cap_open ON dsp_captures(closed, submitted_at);
CREATE TABLE IF NOT EXISTS dsp_verdicts (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  run_id TEXT NOT NULL,
  at TEXT NOT NULL,
  request_id TEXT NOT NULL,
  user_id INTEGER,
  profile_id TEXT,
  track_id TEXT,
  paid INTEGER,                          -- 1 paying, 0 not, NULL unknown (ordering only)
  verdict TEXT NOT NULL,                 -- APPROVE | DECLINE | WAIT | DUPLICATE
  reason_class TEXT NOT NULL,            -- approve | decline | duplicate | the WAIT class (rules._WAIT_ORDER)
  reason TEXT NOT NULL,
  need TEXT,
  confidence REAL NOT NULL,
  anchor TEXT NOT NULL,                  -- both | single | none
  approve_roles TEXT NOT NULL,           -- JSON lists
  decline_roles TEXT NOT NULL,
  role_edit_roles TEXT NOT NULL,
  blockers_json TEXT NOT NULL,
  signals_json TEXT NOT NULL,
  evidence_json TEXT NOT NULL,           -- per role per DSP + request evidence
  packet_sha256 TEXT NOT NULL,
  packet_json TEXT,                      -- the complete packet (an anchor record is rebuilt from it)
  capture_request_id TEXT,
  mode TEXT NOT NULL DEFAULT 'shadow',
  version TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS dsp_v_req ON dsp_verdicts(request_id, version);
CREATE INDEX IF NOT EXISTS dsp_v_run ON dsp_verdicts(run_id);
CREATE TABLE IF NOT EXISTS dsp_anchors (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  run_id TEXT NOT NULL,
  at TEXT NOT NULL,
  request_id TEXT NOT NULL,
  kind TEXT,                             -- dsp_anchor | dsp_label_line | NULL when refused
  outcome TEXT NOT NULL,                 -- built | refused | written | write_refused | write_error
  reason TEXT,
  ruling_id TEXT,                        -- metadata only
  verdict_id INTEGER,                    -- the dsp_verdicts row it was built from
  record_json TEXT,
  record_sha256 TEXT,
  sink_response TEXT
);
CREATE INDEX IF NOT EXISTS dsp_a_req ON dsp_anchors(request_id);
CREATE TRIGGER IF NOT EXISTS dsp_a_no_update BEFORE UPDATE ON dsp_anchors
BEGIN SELECT RAISE(ABORT, 'dsp_anchors is append-only'); END;
CREATE TRIGGER IF NOT EXISTS dsp_a_no_delete BEFORE DELETE ON dsp_anchors
BEGIN SELECT RAISE(ABORT, 'dsp_anchors is append-only'); END;
CREATE TRIGGER IF NOT EXISTS dsp_v_no_update BEFORE UPDATE ON dsp_verdicts
BEGIN SELECT RAISE(ABORT, 'dsp_verdicts is append-only'); END;
CREATE TRIGGER IF NOT EXISTS dsp_v_no_delete BEFORE DELETE ON dsp_verdicts
BEGIN SELECT RAISE(ABORT, 'dsp_verdicts is append-only'); END;
CREATE TRIGGER IF NOT EXISTS dsp_v_shadow_only BEFORE INSERT ON dsp_verdicts WHEN NEW.mode != 'shadow'
BEGIN SELECT RAISE(ABORT, 'dsp_verdicts is shadow-only'); END;
"""


def utcnow() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def packet_sha256(packet: dict[str, Any]) -> str:
    return hashlib.sha256(json.dumps(packet, sort_keys=True, default=str, ensure_ascii=False).encode()).hexdigest()


MAX_JSON = 8_000_000      # bytes of one JSON field; above it the row is refused, never truncated


def _j(v: Any) -> str:
    """Complete JSON or ValueError: a truncated document would silently lose audit evidence."""
    text = json.dumps(v, default=str, ensure_ascii=False)
    if len(text) > MAX_JSON:
        raise ValueError(f"JSON field of {len(text)} chars exceeds {MAX_JSON}; refused (never truncated)")
    return text


class Store:
    def __init__(self, path: str | None = None):
        self.path = path or DEFAULT_PATH
        d = os.path.dirname(self.path)
        if d:
            os.makedirs(d, exist_ok=True)
        fresh = not os.path.exists(self.path)
        self.db = sqlite3.connect(self.path, timeout=60)
        if fresh:
            os.chmod(self.path, 0o600)
        self.db.executescript(SCHEMA)
        cols = {r[1] for r in self.db.execute("PRAGMA table_info(dsp_verdicts)")}
        if "packet_json" not in cols:           # stores created before dsp-anchor
            self.db.execute("ALTER TABLE dsp_verdicts ADD COLUMN packet_json TEXT")
            self.db.commit()

    # -- runs ------------------------------------------------------------------
    def start_run(self, run_id: str, kind: str) -> None:
        with self.db:
            self.db.execute("INSERT INTO dsp_runs (run_id, kind, started_at, version) VALUES (?,?,?,?)",
                            (run_id, kind, utcnow(), VERSION))

    def finish_run(self, run_id: str, counts: dict[str, Any]) -> None:
        with self.db:
            self.db.execute("UPDATE dsp_runs SET finished_at=?, counts_json=? WHERE run_id=?",
                            (utcnow(), _j(counts), run_id))

    # -- captures --------------------------------------------------------------
    def add_capture(self, run_id: str, key: str, user_id: int | None, request_ids: list[str],
                    tracks: list[dict[str, Any]], answer: dict[str, Any]) -> int:
        with self.db:
            cur = self.db.execute(
                "INSERT INTO dsp_captures (run_id, key, user_id, capture_request_id, requested_at, submitted_at,"
                " request_ids_json, tracks_json, submit_json, closed) VALUES (?,?,?,?,?,?,?,?,?,?)",
                (run_id, key, user_id, answer.get("request_id"), answer.get("requested_at"), utcnow(),
                 _j(request_ids), _j(tracks), _j(answer), 1 if answer.get("error") else 0))
            return int(cur.lastrowid)

    def open_captures(self) -> list[dict[str, Any]]:
        self.db.row_factory = sqlite3.Row
        try:
            rows = self.db.execute("SELECT * FROM dsp_captures WHERE closed=0 AND capture_request_id IS NOT NULL"
                                   " ORDER BY id").fetchall()
            return [dict(r) for r in rows]
        finally:
            self.db.row_factory = None

    def record_read(self, cap_id: int, read: dict[str, Any], closed: bool) -> None:
        try:
            body = _j(read)
        except ValueError as exc:
            # The raw read is a convenience copy; each verdict row carries its request's full evidence.
            body = json.dumps({"read_not_stored": str(exc)})
        with self.db:
            self.db.execute("UPDATE dsp_captures SET last_read_at=?, last_read_json=?, reads=reads+1, closed=?"
                            " WHERE id=?", (utcnow(), body, 1 if closed else 0, cap_id))

    def requests_with_open_capture(self) -> set[str]:
        out: set[str] = set()
        for (raw,) in self.db.execute("SELECT request_ids_json FROM dsp_captures WHERE closed=0"
                                      " AND capture_request_id IS NOT NULL"):
            out.update(json.loads(raw or "[]"))
        return out

    def requests_verified_since(self, since: str) -> set[str]:
        """Requests with a FINAL (non capture_pending) verdict under this version since `since`."""
        return {r[0] for r in self.db.execute(
            "SELECT DISTINCT request_id FROM dsp_verdicts WHERE version=? AND at>=? AND instr(reason,"
            " 'capture_pending')=0", (VERSION, since))}

    # -- verdicts --------------------------------------------------------------
    def add_verdict(self, run_id: str, v: dict[str, Any], packet: dict[str, Any], paid: bool | None) -> None:
        with self.db:
            self.db.execute(
                "INSERT INTO dsp_verdicts (run_id, at, request_id, user_id, profile_id, track_id, paid, verdict, reason_class,"
                " reason, need, confidence, anchor, approve_roles, decline_roles, role_edit_roles, blockers_json, signals_json,"
                " evidence_json, packet_sha256, packet_json, capture_request_id, mode, version)"
                " VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,'shadow',?)",
                (run_id, utcnow(), v["request_id"], packet.get("user_id"), packet.get("profile_id"),
                 packet.get("track_id"), None if paid is None else int(paid), v["verdict"], v["reason_class"], v["reason"],
                 v.get("need"),
                 float(v["confidence"]), v["anchor"], _j(v["approve_roles"]), _j(v["decline_roles"]),
                 _j(v["role_edit_roles"]), _j(v["blockers"]), _j(v["signals"]),
                 _j({"roles": v["roles"], "request": v["evidence"]}), packet_sha256(packet), _j(packet),
                 (v.get("evidence") or {}).get("capture_request_id"), VERSION))

    def add_anchor(self, run_id: str, request_id: str, outcome: str, *, kind: str | None = None,
                   reason: str | None = None, ruling_id: str | None = None, verdict_id: int | None = None,
                   record: dict[str, Any] | None = None, sink_response: Any = None) -> None:
        with self.db:
            self.db.execute(
                "INSERT INTO dsp_anchors (run_id, at, request_id, kind, outcome, reason, ruling_id, verdict_id,"
                " record_json, record_sha256, sink_response) VALUES (?,?,?,?,?,?,?,?,?,?,?)",
                (run_id, utcnow(), request_id, kind, outcome, (reason or "")[:600] or None, ruling_id, verdict_id,
                 None if record is None else _j(record), (record or {}).get("record_sha256"),
                 None if sink_response is None else _j(sink_response)))

    def anchors(self, request_id: str | None = None) -> list[dict[str, Any]]:
        self.db.row_factory = sqlite3.Row
        try:
            sql, args = "SELECT * FROM dsp_anchors", []
            if request_id:
                sql, args = sql + " WHERE request_id=?", [request_id]
            return [dict(r) for r in self.db.execute(sql + " ORDER BY id", args).fetchall()]
        finally:
            self.db.row_factory = None

    def latest_for(self, request_id: str) -> dict[str, Any] | None:
        """The latest verdict for this request under this version, from ANY run (reports)."""
        self.db.row_factory = sqlite3.Row
        try:
            r = self.db.execute("SELECT * FROM dsp_verdicts WHERE request_id=? AND version=? ORDER BY id DESC LIMIT 1",
                                (request_id, VERSION)).fetchone()
            return dict(r) if r else None
        finally:
            self.db.row_factory = None

    def latest_captured_for(self, request_id: str) -> dict[str, Any] | None:
        """The latest verdict that THIS job produced from its OWN capture (QA @3b7f0b4): a `verify` run,
        whose packet names a capture request this store filed (dsp_captures) for this credit request.
        Verdicts logged from caller-supplied packets (verify-packets --log, eval) never qualify."""
        self.db.row_factory = sqlite3.Row
        try:
            rows = self.db.execute(
                "SELECT v.* FROM dsp_verdicts v JOIN dsp_runs r ON r.run_id = v.run_id"
                " WHERE v.request_id=? AND v.version=? AND r.kind='verify' ORDER BY v.id DESC LIMIT 1",
                (request_id, VERSION)).fetchall()
            if not rows:
                return None
            v = dict(rows[0])
            cap_id = v.get("capture_request_id")
            if not cap_id:
                return None
            for (ids,) in self.db.execute("SELECT request_ids_json FROM dsp_captures WHERE capture_request_id=?",
                                         (cap_id,)):
                if request_id in {str(x).lower() for x in json.loads(ids or "[]")}:
                    packet = json.loads(v.get("packet_json") or "{}")
                    if ((packet.get("capture") or {}).get("request_id")) == cap_id:
                        return v
            return None
        finally:
            self.db.row_factory = None

    LATEST = ("SELECT v.* FROM dsp_verdicts v JOIN (SELECT request_id, MAX(id) id FROM dsp_verdicts WHERE version=?"
              " GROUP BY request_id) l USING(id)")

    def latest(self) -> list[dict[str, Any]]:
        self.db.row_factory = sqlite3.Row
        try:
            return [dict(r) for r in self.db.execute(self.LATEST, (VERSION,)).fetchall()]
        finally:
            self.db.row_factory = None

    def summary(self) -> dict[str, Any]:
        rows = self.latest()
        out: dict[str, Any] = {"version": VERSION, "requests": len(rows), "by_verdict": {}, "by_reason": {},
                               "by_need": {}, "by_anchor": {}, "paid_by_verdict": {}}
        for r in rows:
            out["by_verdict"][r["verdict"]] = out["by_verdict"].get(r["verdict"], 0) + 1
            cls = r["reason_class"]
            out["by_reason"][cls] = out["by_reason"].get(cls, 0) + 1
            if r["need"]:
                out["by_need"][r["need"]] = out["by_need"].get(r["need"], 0) + 1
            out["by_anchor"][r["anchor"]] = out["by_anchor"].get(r["anchor"], 0) + 1
            if r["paid"] == 1:
                out["paid_by_verdict"][r["verdict"]] = out["paid_by_verdict"].get(r["verdict"], 0) + 1
        return out


def export_jsonl(rows: Iterable[dict[str, Any]]) -> Iterable[str]:
    for r in rows:
        yield json.dumps(r, default=str, ensure_ascii=False)
