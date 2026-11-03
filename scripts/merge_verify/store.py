"""The merge verifier's own append-only audit store (SHADOW). The only thing it ever writes.

Default /var/lib/hydra-merge-verify/merge-verify.sqlite (0600). One `mv_runs` row per run and one
`mv_verdicts` row per (run, ticket, duplicate), carrying the rule version, the verdict, the reasons,
the exact command (eligible only), and the facts it was decided on with their sha256, so any
verdict can be re-derived later. Rows are never updated or deleted by this code; "reverting" a run
means ignoring it (nothing outside this file read it).
"""
from __future__ import annotations

import hashlib
import json
import os
import sqlite3
import time
from pathlib import Path
from typing import Any

DEFAULT = "/var/lib/hydra-merge-verify/merge-verify.sqlite"

SCHEMA = """
CREATE TABLE IF NOT EXISTS mv_runs (
  run_id TEXT PRIMARY KEY, started REAL, finished REAL, mode TEXT, rule_version TEXT,
  tickets INTEGER, summary TEXT);
CREATE TABLE IF NOT EXISTS mv_verdicts (
  id INTEGER PRIMARY KEY AUTOINCREMENT, run_id TEXT NOT NULL, at REAL NOT NULL, rule_version TEXT NOT NULL,
  ticket TEXT NOT NULL, keep TEXT, loser TEXT, stage TEXT, verdict TEXT NOT NULL, eval TEXT NOT NULL,
  ticket_verdict TEXT NOT NULL, m1_state TEXT, fresh_read INTEGER NOT NULL, reasons TEXT, basis TEXT,
  command TEXT, self_serve TEXT, facts_sha256 TEXT NOT NULL, facts TEXT NOT NULL);
CREATE INDEX IF NOT EXISTS mv_verdicts_ticket ON mv_verdicts(ticket, loser, id);
"""


def facts_sha(facts: dict) -> str:
    return hashlib.sha256(json.dumps(facts, sort_keys=True, default=str).encode()).hexdigest()


class Store:
    def __init__(self, path: str | None = None):
        self.path = path or os.environ.get("MERGE_VERIFY_STORE", DEFAULT)
        Path(self.path).parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        new = not Path(self.path).exists()
        self.db = sqlite3.connect(self.path)
        if new:
            os.chmod(self.path, 0o600)
        self.db.executescript(SCHEMA)

    def record(self, run_id: str, mode: str, started: float, pairs: list[tuple[dict, Any]], summary: dict) -> int:
        """pairs = [(facts, TicketVerdict)]; one row per duplicate (or one ticket-level row)."""
        n = 0
        now = time.time()
        with self.db:
            for facts, v in pairs:
                sha, blob = facts_sha(facts), json.dumps(facts, sort_keys=True, default=str)
                rows = v.losers or [None]
                for lv in rows:
                    self.db.execute(
                        "INSERT INTO mv_verdicts (run_id, at, rule_version, ticket, keep, loser, stage, verdict, eval, "
                        "ticket_verdict, m1_state, fresh_read, reasons, basis, command, self_serve, facts_sha256, facts) "
                        "VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                        (run_id, now, v.rule_version, v.ticket, v.keep, lv.loser if lv else None, v.stage,
                         lv.verdict if lv else v.verdict, lv.eval if lv else v.eval, v.verdict, v.m1_state,
                         int(v.fresh_read), json.dumps((lv.reasons if lv else []) + v.reasons),
                         lv.basis if lv else None, lv.command if lv else None,
                         json.dumps(lv.self_serve) if lv and lv.self_serve else None, sha, blob))
                    n += 1
            self.db.execute("INSERT OR REPLACE INTO mv_runs VALUES (?,?,?,?,?,?,?)",
                            (run_id, started, now, mode, pairs[0][1].rule_version if pairs else None, len(pairs),
                             json.dumps(summary, sort_keys=True)))
        return n

    def latest(self) -> list[sqlite3.Row]:
        self.db.row_factory = sqlite3.Row
        return list(self.db.execute(
            "SELECT * FROM mv_verdicts WHERE run_id = (SELECT run_id FROM mv_runs ORDER BY finished DESC LIMIT 1) ORDER BY id"))
