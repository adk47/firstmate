"""Append-only audit ledger for every credit-trust model call.

One row per ATTEMPT on a ladder rung - a served answer, a failure, or a skip
(quota, kill switch, capability). The core-backend case log links to a row by
``llm_call_id`` (the integer id) or ``call_uid``. Rows are never updated or
deleted: SQLite triggers refuse both, so the trail cannot be rewritten by the
code that writes it.

The raw exchange (prompt, schema, answer text, codex metadata) is written to a
0600 file under ``raw/`` BEFORE the row is inserted, and the row carries its
path and the prompt's sha256, so an auditor can re-hash the stored prompt and
match it to the row.

Lives under /var/lib/hydra (deploy-proof; /opt/hydra is rsync-overwritten).
"""

from __future__ import annotations

import json
import os
import sqlite3
import threading
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

DEFAULT_PATH = os.environ.get("CREDIT_TRUST_LEDGER", "/var/lib/hydra/credit-trust/ledger.sqlite3")

SCHEMA = """
CREATE TABLE IF NOT EXISTS llm_calls (
  id INTEGER PRIMARY KEY AUTOINCREMENT,      -- llm_call_id
  call_uid TEXT NOT NULL UNIQUE,
  ts TEXT NOT NULL,
  step TEXT NOT NULL,                        -- web_credibility | doc_forensics | caroline_draft | ops_decision | digest | probe | eval
  provider TEXT NOT NULL,                    -- codex | jev
  outcome TEXT NOT NULL,                     -- ok | error | skipped
  reason TEXT,                               -- skip/error reason (quota, model_unsupported, tool_violation, ...)
  model TEXT,
  prompt_sha256 TEXT NOT NULL,
  schema_sha256 TEXT,
  input_tokens INTEGER,
  output_tokens INTEGER,
  cost_usd REAL,                             -- 0 on the subscription; NULL when the provider bills outside us (Jev plan)
  latency_ms INTEGER,
  citations_json TEXT NOT NULL DEFAULT '[]', -- engine-returned URLs only
  uncited_urls INTEGER NOT NULL DEFAULT 0,   -- URLs the model wrote that no engine returned (dropped)
  web INTEGER NOT NULL DEFAULT 0,
  meta_json TEXT,                            -- codex argv/account/tool census, jev surface, ...
  raw_path TEXT
);
CREATE INDEX IF NOT EXISTS llm_calls_ts ON llm_calls(ts);
CREATE INDEX IF NOT EXISTS llm_calls_prompt ON llm_calls(prompt_sha256);
CREATE TRIGGER IF NOT EXISTS llm_calls_no_update BEFORE UPDATE ON llm_calls
BEGIN SELECT RAISE(ABORT, 'llm_calls is append-only'); END;
CREATE TRIGGER IF NOT EXISTS llm_calls_no_delete BEFORE DELETE ON llm_calls
BEGIN SELECT RAISE(ABORT, 'llm_calls is append-only'); END;
"""

COLUMNS = ("call_uid", "ts", "step", "provider", "outcome", "reason", "model", "prompt_sha256", "schema_sha256",
           "input_tokens", "output_tokens", "cost_usd", "latency_ms", "citations_json", "uncited_urls", "web",
           "meta_json", "raw_path")


def utcnow() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def day_start(now: datetime | None = None) -> str:
    now = now or datetime.now(timezone.utc)
    return now.strftime("%Y-%m-%dT00:00:00Z")


class Ledger:
    def __init__(self, path: str | None = None, raw_dir: str | None = None):
        self.path = path or DEFAULT_PATH
        if self.path != ":memory:":
            Path(self.path).parent.mkdir(parents=True, exist_ok=True)
            self.raw_dir: Path | None = Path(raw_dir) if raw_dir else Path(self.path).parent / "raw"
        else:
            self.raw_dir = Path(raw_dir) if raw_dir else None
        # One connection is shared by the decider's worker threads; every use of
        # it (insert+commit+lastrowid, and reads) runs under this lock.
        self._lock = threading.Lock()
        self.db = sqlite3.connect(self.path, timeout=30, check_same_thread=False)
        self.db.row_factory = sqlite3.Row
        self.db.executescript(SCHEMA)
        self.db.commit()

    def close(self) -> None:
        self.db.close()

    def _write_raw(self, uid: str, raw: dict[str, Any]) -> str | None:
        if self.raw_dir is None:
            return None
        d = self.raw_dir / datetime.now(timezone.utc).strftime("%Y-%m-%d")
        d.mkdir(parents=True, exist_ok=True, mode=0o700)
        p = d / f"{uid}.json"
        fd = os.open(p, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            json.dump(raw, fh, ensure_ascii=False, default=str)
        return str(p)

    def record(self, row: dict[str, Any], raw: dict[str, Any] | None = None) -> tuple[int, str]:
        """Insert one attempt; returns (llm_call_id, call_uid). The raw
        exchange is persisted first so a row never points at a missing file."""
        uid = row.get("call_uid") or uuid.uuid4().hex
        raw_path = None
        if raw is not None:
            try:
                raw_path = self._write_raw(uid, raw)
            except OSError as exc:  # the row still records the call; say why raw is absent
                row = {**row, "meta_json": {**_as_obj(row.get("meta_json")), "raw_write_error": str(exc)[:200]}}
        vals = []
        for c in COLUMNS:
            v = row.get(c)
            if c == "call_uid":
                v = uid
            elif c == "ts":
                v = v or utcnow()
            elif c == "raw_path":
                v = raw_path
            elif c in ("citations_json", "meta_json") and v is not None and not isinstance(v, str):
                v = json.dumps(v, ensure_ascii=False, default=str)
            elif c == "citations_json" and v is None:
                v = "[]"
            elif c in ("web",):
                v = 1 if v else 0
            elif c == "uncited_urls":
                v = int(v or 0)
            vals.append(v)
        with self._lock:
            cur = self.db.execute(f"INSERT INTO llm_calls ({','.join(COLUMNS)}) VALUES ({','.join('?' * len(COLUMNS))})", vals)
            self.db.commit()
            return int(cur.lastrowid), uid

    def _fetch(self, q: str, args: Any) -> list[sqlite3.Row]:
        with self._lock:
            return self.db.execute(q, args).fetchall()

    # -- reads --------------------------------------------------------------
    def cost_since(self, ts: str, provider: str | None = None) -> float:
        q = "SELECT COALESCE(SUM(cost_usd),0) c FROM llm_calls WHERE ts >= ?"
        args: list[Any] = [ts]
        if provider:
            q += " AND provider = ?"
            args.append(provider)
        return float(self._fetch(q, args)[0]["c"])

    def recently_unsupported(self, model: str, since: str) -> bool:
        return bool(self._fetch("SELECT 1 FROM llm_calls WHERE provider='codex' AND model=? AND reason='model_unsupported' "
                                "AND ts >= ? LIMIT 1", (model, since)))

    def rows(self, since: str | None = None, limit: int = 50) -> list[sqlite3.Row]:
        if since:
            return self._fetch("SELECT * FROM llm_calls WHERE ts >= ? ORDER BY id DESC LIMIT ?", (since, limit))
        return self._fetch("SELECT * FROM llm_calls ORDER BY id DESC LIMIT ?", (limit,))


def _as_obj(v: Any) -> dict[str, Any]:
    if isinstance(v, dict):
        return v
    if isinstance(v, str):
        try:
            o = json.loads(v)
            return o if isinstance(o, dict) else {}
        except json.JSONDecodeError:
            return {}
    return {}
