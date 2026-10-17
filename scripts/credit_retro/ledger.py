"""Append-only ledger for credit-retro runs: sqlite + one JSONL file per run.

Every row-level step is an EVENT: (run id, row id, request/user/profile/track,
role, action, outcome, HTTP status, before state, after state, evidence URL,
approval ref, reason, actor, time). Events are never updated or deleted: the
sqlite triggers abort any UPDATE/DELETE, and the JSONL mirror is opened in
append mode and fsynced per line, so the record survives a lost sqlite file.

The state directory lives outside /opt/hydra (deploy rsync overwrites that).
"""

from __future__ import annotations

import hashlib
import json
import os
import sqlite3
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Iterable

DEFAULT_DIR = os.environ.get("CREDIT_RETRO_DIR", "/var/lib/hydra/credit-retro")

SCHEMA = """
CREATE TABLE IF NOT EXISTS runs (
  run_id TEXT PRIMARY KEY,
  kind TEXT NOT NULL,            -- plan | apply | readback | revert | prepare-waves
  parent_run TEXT,               -- apply: the plan it executes; revert/readback: the apply run
  actor TEXT NOT NULL,
  manifest TEXT,
  manifest_sha256 TEXT,
  argv TEXT,
  started_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS run_ends (
  run_id TEXT PRIMARY KEY REFERENCES runs(run_id),
  finished_at TEXT NOT NULL,
  counts_json TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS events (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  run_id TEXT NOT NULL REFERENCES runs(run_id),
  row_id TEXT NOT NULL,
  request_id TEXT,
  user_id TEXT,
  profile_id TEXT,
  track_id TEXT,
  role TEXT,
  action TEXT NOT NULL,          -- gate | remove | readback | revert | prepare
  outcome TEXT NOT NULL,
  http_status INTEGER,
  before_json TEXT,
  after_json TEXT,
  evidence_url TEXT,
  approval_ref TEXT,
  reason TEXT,
  actor TEXT NOT NULL,
  at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS events_run ON events(run_id, action);
CREATE INDEX IF NOT EXISTS events_row ON events(row_id);
CREATE TRIGGER IF NOT EXISTS events_no_update BEFORE UPDATE ON events
  BEGIN SELECT RAISE(ABORT, 'credit-retro ledger is append-only'); END;
CREATE TRIGGER IF NOT EXISTS events_no_delete BEFORE DELETE ON events
  BEGIN SELECT RAISE(ABORT, 'credit-retro ledger is append-only'); END;
CREATE TRIGGER IF NOT EXISTS runs_no_update BEFORE UPDATE ON runs
  BEGIN SELECT RAISE(ABORT, 'credit-retro ledger is append-only'); END;
CREATE TRIGGER IF NOT EXISTS runs_no_delete BEFORE DELETE ON runs
  BEGIN SELECT RAISE(ABORT, 'credit-retro ledger is append-only'); END;
"""

UNRESOLVED = ("sent", "indeterminate")  # remove outcomes with no known server result

EVENT_FIELDS = ("row_id", "request_id", "user_id", "profile_id", "track_id", "role", "action", "outcome",
                "http_status", "before", "after", "evidence_url", "approval_ref", "reason")


def utcnow() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%fZ")


def sha256_file(path: str | Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()


def new_run_id(kind: str) -> str:
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    return f"{kind}-{stamp}-{uuid.uuid4().hex[:6]}"


class Ledger:
    def __init__(self, state_dir: str | Path = DEFAULT_DIR):
        self.dir = Path(state_dir)
        (self.dir / "runs").mkdir(parents=True, exist_ok=True)
        os.chmod(self.dir, 0o700)
        self.path = self.dir / "ledger.sqlite3"
        self.db = sqlite3.connect(self.path)
        self.db.row_factory = sqlite3.Row
        self.db.executescript(SCHEMA)
        self.db.commit()

    def close(self) -> None:
        self.db.close()

    def jsonl_path(self, run_id: str) -> Path:
        return self.dir / "runs" / f"{run_id}.jsonl"

    def _append_jsonl(self, run_id: str, record: dict[str, Any]) -> None:
        line = json.dumps(record, sort_keys=True, ensure_ascii=False) + "\n"
        fd = os.open(self.jsonl_path(run_id), os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
        try:
            os.write(fd, line.encode())
            os.fsync(fd)
        finally:
            os.close(fd)

    def start_run(self, *, kind: str, actor: str, manifest: str | None = None,
                  parent_run: str | None = None, argv: Iterable[str] | None = None,
                  run_id: str | None = None) -> str:
        run_id = run_id or new_run_id(kind)
        record = {
            "run_id": run_id, "kind": kind, "parent_run": parent_run, "actor": actor,
            "manifest": manifest, "manifest_sha256": sha256_file(manifest) if manifest else None,
            "argv": json.dumps(list(argv or [])), "started_at": utcnow(),
        }
        self.db.execute(
            "INSERT INTO runs(run_id, kind, parent_run, actor, manifest, manifest_sha256, argv, started_at) "
            "VALUES(:run_id, :kind, :parent_run, :actor, :manifest, :manifest_sha256, :argv, :started_at)", record)
        self.db.commit()
        self._append_jsonl(run_id, {"type": "run_start", **record})
        return run_id

    def finish_run(self, run_id: str, counts: dict[str, Any]) -> None:
        record = {"run_id": run_id, "finished_at": utcnow(), "counts_json": json.dumps(counts, sort_keys=True)}
        self.db.execute("INSERT INTO run_ends(run_id, finished_at, counts_json) "
                        "VALUES(:run_id, :finished_at, :counts_json)", record)
        self.db.commit()
        self._append_jsonl(run_id, {"type": "run_end", "run_id": run_id, "finished_at": record["finished_at"],
                                    "counts": counts})

    def event(self, run_id: str, actor: str, **fields: Any) -> dict[str, Any]:
        unknown = set(fields) - set(EVENT_FIELDS)
        if unknown:
            raise ValueError(f"unknown ledger fields {sorted(unknown)}")
        rec = {k: fields.get(k) for k in EVENT_FIELDS}
        rec.update(run_id=run_id, actor=actor, at=utcnow())
        # JSONL first: if sqlite then fails, the line already says what was attempted.
        self._append_jsonl(run_id, {"type": "event", **rec})
        self.db.execute(
            "INSERT INTO events(run_id, row_id, request_id, user_id, profile_id, track_id, role, action, outcome, "
            "http_status, before_json, after_json, evidence_url, approval_ref, reason, actor, at) VALUES "
            "(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
            (run_id, rec["row_id"], rec["request_id"], rec["user_id"], rec["profile_id"], rec["track_id"],
             rec["role"], rec["action"], rec["outcome"], rec["http_status"],
             json.dumps(rec["before"], sort_keys=True) if rec["before"] is not None else None,
             json.dumps(rec["after"], sort_keys=True) if rec["after"] is not None else None,
             rec["evidence_url"], rec["approval_ref"], rec["reason"], actor, rec["at"]))
        self.db.commit()
        return rec

    # -- reads ---------------------------------------------------------------
    def run(self, run_id: str) -> sqlite3.Row | None:
        return self.db.execute("SELECT * FROM runs WHERE run_id = ?", (run_id,)).fetchone()

    def run_end(self, run_id: str) -> sqlite3.Row | None:
        return self.db.execute("SELECT * FROM run_ends WHERE run_id = ?", (run_id,)).fetchone()

    def events(self, run_id: str, action: str | None = None) -> list[sqlite3.Row]:
        if action:
            return self.db.execute("SELECT * FROM events WHERE run_id = ? AND action = ? ORDER BY id",
                                   (run_id, action)).fetchall()
        return self.db.execute("SELECT * FROM events WHERE run_id = ? ORDER BY id", (run_id,)).fetchall()

    def child_runs(self, parent_run: str, kind: str) -> list[sqlite3.Row]:
        return self.db.execute("SELECT * FROM runs WHERE parent_run = ? AND kind = ? ORDER BY started_at",
                               (parent_run, kind)).fetchall()

    def remove_results(self, apply_run: str) -> list[sqlite3.Row]:
        """The LATEST remove event per row of an apply run. A DELETE is recorded as
        ``sent`` before it goes out; the response (or a later live reconcile) appends
        the result, so a row whose latest outcome is still in UNRESOLVED may or may
        not have been removed."""
        last: dict[str, sqlite3.Row] = {}
        for e in self.events(apply_run, "remove"):
            last[e["row_id"]] = e
        return list(last.values())

    def removed_rows(self, apply_run: str) -> list[sqlite3.Row]:
        """Rows an apply run removed (server 2xx, or confirmed gone by a live reconcile)."""
        return [e for e in self.remove_results(apply_run) if e["outcome"] == "removed"]

    def unresolved_rows(self, apply_run: str) -> list[sqlite3.Row]:
        """Rows whose DELETE went out with no known result (crash or transport error)."""
        return [e for e in self.remove_results(apply_run) if e["outcome"] in UNRESOLVED]

    def revert_results(self, apply_run: str) -> list[sqlite3.Row]:
        """The LATEST revert event per row across every revert run of ``apply_run``.
        A re-add is recorded as ``sent`` before the POST goes out; the response (or a
        later live reconcile) appends the result."""
        last: dict[str, sqlite3.Row] = {}
        for rr in self.child_runs(apply_run, "revert"):
            for e in self.events(rr["run_id"], "revert"):
                last[e["row_id"]] = e
        return list(last.values())

    def reverted_row_ids(self, apply_run: str) -> set[str]:
        """Row ids of ``apply_run`` already re-added by any revert run."""
        return {e["row_id"] for e in self.revert_results(apply_run) if e["outcome"] == "re_added"}

    def unresolved_reverts(self, apply_run: str) -> list[sqlite3.Row]:
        """Re-adds that went out with no known result (crash or transport error)."""
        return [e for e in self.revert_results(apply_run) if e["outcome"] in UNRESOLVED]

    def takeback_notified(self, since: str) -> set[str]:
        """User ids that got a ``sent`` take-back notice (any apply run) at or after ``since``."""
        return {r["user_id"] for r in self.db.execute(
            "SELECT e.user_id FROM events e JOIN runs r ON r.run_id = e.run_id WHERE r.kind = 'apply' "
            "AND e.action = 'notify' AND e.outcome = 'sent' AND e.at >= ?", (since,))}

    def apply_runs(self, manifest_sha256: str | None = None) -> list[str]:
        """Apply runs on one manifest, or every apply run when ``manifest_sha256`` is None."""
        if manifest_sha256 is None:
            return [r["run_id"] for r in self.db.execute(
                "SELECT run_id FROM runs WHERE kind = 'apply' ORDER BY started_at")]
        return [r["run_id"] for r in self.db.execute(
            "SELECT run_id FROM runs WHERE kind = 'apply' AND manifest_sha256 = ? ORDER BY started_at",
            (manifest_sha256,))]

    def removed_on_manifest(self, manifest_sha256: str) -> tuple[list[str], set[str]]:
        """(apply runs on this manifest, row ids any of them removed and no revert re-added)."""
        runs = self.apply_runs(manifest_sha256)
        rows: set[str] = set()
        for run_id in runs:
            reverted = self.reverted_row_ids(run_id)
            rows.update(e["row_id"] for e in self.removed_rows(run_id) if e["row_id"] not in reverted)
        return runs, rows
