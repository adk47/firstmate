"""The churn store: /var/lib/hydra/churn/support-state.sqlite.

The ONLY writable surface in this build. Everything else it reads is prod and
read-only (Intercom search/GET, the core replica through trino-query.sh, the
hydra verify ledger and proof store opened `mode=ro`, ClickUp GET).

Why /var/lib and not /opt/hydra: /opt/hydra is rsync-overwritten on every deploy
(AGENTS.md, releases note). A store under the deploy root would be wiped nightly.

Schema notes:
  - one row per user PER MODE: the key is `(user_id, mode)`. The paying row is what the
    PREVENT signal reads and the churned row is the cancel record, so a user who cancels
    and later re-subscribes keeps BOTH: their churned-with-issue history does not vanish
    the next time the paying sweep writes them (the single-key version silently replaced
    it, which undercounted the Monday line and dropped them from risk.json's churned set
    exactly when they came back). Each sweep replaces only its own mode's row;`;
  - `kinds` is the stage's issue kinds, `evidence_json` the rows a human reads;
  - `tier` is T1/T2/T3 as the report defines them, NULL when nothing is waiting;
  - `checked_at`/`run_id` make a stale row visible instead of silently trusted;
  - a writable open REFUSES a store still keyed on user_id alone: `CREATE TABLE IF
    NOT EXISTS` would accept it and `INSERT OR REPLACE` would go back to replacing the
    churned row. Every row here is derived from re-runnable sweeps, so the fix is to
    delete the file, not to migrate it.
"""

from __future__ import annotations

import json
import os
import sqlite3
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Iterable

DEFAULT_PATH = os.environ.get("CHURN_SUPPORT_STATE", "/var/lib/hydra/churn/support-state.sqlite")

SCHEMA = """
CREATE TABLE IF NOT EXISTS support_state (
  user_id          INTEGER NOT NULL,
  mode             TEXT NOT NULL,            -- paying | churned
  tier             TEXT,                     -- T1 | T2 | T3 | NULL
  cause_class      TEXT,
  kinds            TEXT NOT NULL DEFAULT '[]',
  evidence_json    TEXT NOT NULL DEFAULT '[]',
  anchor           TEXT,                     -- ISO ts the state was measured at
  ball_days        REAL NOT NULL DEFAULT 0,
  mrr_list         REAL,
  renews_at        TEXT,
  intercom_conv_ids TEXT NOT NULL DEFAULT '[]',
  open_request_ids TEXT NOT NULL DEFAULT '[]',
  paying           INTEGER NOT NULL DEFAULT 0,
  churned_at       TEXT,
  plan             TEXT,
  cancel_reason    TEXT,
  service          TEXT,
  checked_at       TEXT NOT NULL,
  run_id           TEXT NOT NULL,
  PRIMARY KEY (user_id, mode)
);
CREATE INDEX IF NOT EXISTS support_state_mode ON support_state(mode, tier);
CREATE INDEX IF NOT EXISTS support_state_checked ON support_state(checked_at);
CREATE TABLE IF NOT EXISTS runs (
  run_id     TEXT PRIMARY KEY,
  mode       TEXT NOT NULL,
  started_at TEXT NOT NULL,
  finished_at TEXT,
  users      INTEGER NOT NULL DEFAULT 0,
  errors     INTEGER NOT NULL DEFAULT 0,
  tiers_json TEXT,
  note       TEXT
);
-- one row per Intercom conversation we have READ, with the derived facts that
-- cost a GET (our last message, the customer's last message). A conversation
-- whose updated_at has not moved is not re-read: the nightly sweep is
-- incremental, so a budget-bounded night resumes instead of re-paying.
CREATE TABLE IF NOT EXISTS conv_state (
  conv_id     TEXT PRIMARY KEY,
  updated_at  REAL NOT NULL DEFAULT 0,
  created_at  REAL NOT NULL DEFAULT 0,
  state       TEXT,
  last_at     REAL NOT NULL DEFAULT 0,
  last_who    TEXT,
  admin_at    REAL NOT NULL DEFAULT 0,
  opening_body TEXT,
  last_body   TEXT,
  our_last_body TEXT,
  promise     INTEGER NOT NULL DEFAULT 0,
  ask         INTEGER NOT NULL DEFAULT 0,
  courtesy    INTEGER NOT NULL DEFAULT 0,
  external_ids TEXT NOT NULL DEFAULT '[]',
  read_full   INTEGER NOT NULL DEFAULT 0,
  read_at     TEXT
);
"""


def utcnow() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


# columns put_user JSON-encodes: every reader gets the decoded form, so a caller
# never has to know whether it is holding a row from user() or from users().
JSON_COLUMNS = ("kinds", "evidence_json", "intercom_conv_ids", "open_request_ids")


def decode_state_row(row: dict[str, Any]) -> dict[str, Any]:
    for k in JSON_COLUMNS:
        if k in row:
            try:
                row[k] = json.loads(row.get(k) or "[]")
            except (ValueError, TypeError):
                row[k] = []
    return row


class Store:
    def __init__(self, path: str | None = None, *, readonly: bool = False):
        self.path = path or DEFAULT_PATH
        self.readonly = readonly
        if not readonly:
            Path(self.path).parent.mkdir(parents=True, exist_ok=True)
            uri = f"file:{self.path}?mode=rwc"
            self.db = sqlite3.connect(uri, uri=True, timeout=30)
            self.db.row_factory = sqlite3.Row
            self.db.execute("PRAGMA busy_timeout=30000")
            self.db.executescript(SCHEMA)
            self._require_composite_key()
            return
        uri = f"file:{self.path}?mode=ro"
        self.db = self._open_or_empty(uri)
        self.db.row_factory = sqlite3.Row

    def _require_composite_key(self) -> None:
        """A store built by an earlier revision keeps its single-column key."""
        info = list(self.db.execute("PRAGMA table_info('support_state')"))
        pk = [r["name"] for r in sorted((r for r in info if r["pk"]), key=lambda r: r["pk"])]
        if pk == ["user_id", "mode"]:
            return
        self.db.close()
        raise SystemExit(
            f"{self.path}: support_state was created with PRIMARY KEY({', '.join(pk) or 'none'}), "
            "not (user_id, mode); a sweep would silently replace the other mode's row. Its rows "
            "are derived from re-runnable sweeps, so delete it and run the sweep again: "
            f"rm {self.path}")

    def _open_or_empty(self, uri: str) -> sqlite3.Connection:
        """A read-only store, or an empty one when the store has not been built yet.

        A fresh install (every reader can run before the first nightly) must reach
        the callers' own "no sweep has finished" guards, not a traceback.
        """
        try:
            db = sqlite3.connect(uri, uri=True, timeout=30)
        except sqlite3.DatabaseError:
            db = None
        if db is not None:
            try:
                db.execute("SELECT 1 FROM runs LIMIT 1")
                db.execute("SELECT 1 FROM support_state LIMIT 1")
                return db
            except sqlite3.DatabaseError:
                db.close()
        db = sqlite3.connect(":memory:")
        db.executescript(SCHEMA)
        return db

    # -- writes ------------------------------------------------------------
    def start_run(self, run_id: str, mode: str) -> None:
        if self.readonly:
            return
        self.db.execute("INSERT OR REPLACE INTO runs (run_id, mode, started_at) VALUES (?,?,?)",
                        (run_id, mode, utcnow()))
        self.db.commit()

    def finish_run(self, run_id: str, *, users: int, errors: int, tiers: dict[str, int],
                   note: str = "") -> None:
        if self.readonly:
            return
        self.db.execute("UPDATE runs SET finished_at=?, users=?, errors=?, tiers_json=?, note=? WHERE run_id=?",
                        (utcnow(), users, errors, json.dumps(tiers, sort_keys=True), note[:400], run_id))
        self.db.commit()

    def put_user(self, row: dict[str, Any]) -> None:
        if self.readonly:
            return
        self.db.execute(
            "INSERT OR REPLACE INTO support_state (user_id, mode, tier, cause_class, kinds, evidence_json,"
            " anchor, ball_days, mrr_list, renews_at, intercom_conv_ids, open_request_ids, paying,"
            " churned_at, plan, cancel_reason, service, checked_at, run_id)"
            " VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
            (int(row["user_id"]), row["mode"], row.get("tier"), row.get("cause_class"),
             json.dumps(row.get("kinds") or []), json.dumps(row.get("evidence") or []),
             row.get("anchor"), float(row.get("ball_days") or 0), row.get("mrr_list"),
             row.get("renews_at"), json.dumps(row.get("intercom_conv_ids") or []),
             json.dumps(row.get("open_request_ids") or []), int(bool(row.get("paying"))),
             row.get("churned_at"), row.get("plan"), row.get("cancel_reason"), row.get("service"),
             row.get("checked_at") or utcnow(), row["run_id"]))
        self.db.commit()

    def delete_mode_users(self, mode: str, keep: Iterable[int]) -> int:
        """Drop rows of `mode` the sweep did not see (a deleted role, a vanished sub).

        Only that mode's rows: a user who re-subscribes loses their PAYING row when they
        stop paying, never their churned history (`(user_id, mode)` keys both).
        """
        if self.readonly:
            return 0
        keep = {int(u) for u in keep}
        rows = [int(r[0]) for r in self.db.execute("SELECT user_id FROM support_state WHERE mode=?", (mode,))]
        gone = [u for u in rows if u not in keep]
        for u in gone:
            self.db.execute("DELETE FROM support_state WHERE user_id=? AND mode=?", (u, mode))
        self.db.commit()
        return len(gone)

    def put_conv(self, row: dict[str, Any]) -> None:
        if self.readonly:
            return
        self.db.execute(
            "INSERT OR REPLACE INTO conv_state (conv_id, updated_at, created_at, state, last_at, last_who,"
            " admin_at, opening_body, last_body, our_last_body, promise, ask, courtesy, external_ids,"
            " read_full, read_at) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
            (str(row["conv_id"]), float(row.get("updated_at") or 0), float(row.get("created_at") or 0),
             row.get("state"), float(row.get("last_at") or 0), row.get("last_who"),
             float(row.get("admin_at") or 0), (row.get("opening_body") or "")[:1500],
             (row.get("last_body") or "")[:1500], (row.get("our_last_body") or "")[:1500],
             int(bool(row.get("promise"))), int(bool(row.get("ask"))), int(bool(row.get("courtesy"))),
             json.dumps(row.get("external_ids") or []), int(bool(row.get("read_full"))), utcnow()))
        self.db.commit()

    @staticmethod
    def _conv_row(row: Any) -> dict[str, Any]:
        d = dict(row)
        try:
            d["external_ids"] = json.loads(d.get("external_ids") or "[]")
        except ValueError:
            d["external_ids"] = []
        return d

    def convs(self) -> dict[str, dict[str, Any]]:
        """Every conversation we have read, keyed by id (the sweep's fact base)."""
        try:
            rows = self.db.execute("SELECT * FROM conv_state").fetchall()
        except sqlite3.Error:
            return {}
        return {d["conv_id"]: d for d in (self._conv_row(r) for r in rows)}

    def convs_for_external_ids(self, keys: Iterable[str | None]) -> list[dict[str, Any]]:
        """The conversations one contact's ids carry (a per-user read, not the fleet)."""
        wanted = {str(k).lower() for k in keys if k}
        if not wanted:
            return []
        cond = " OR ".join("lower(external_ids) LIKE ?" for _ in sorted(wanted))
        try:
            rows = self.db.execute(f"SELECT * FROM conv_state WHERE {cond}",
                                   [f'%"{k}"%' for k in sorted(wanted)]).fetchall()
        except sqlite3.Error:
            return []
        out = []
        for row in rows:
            d = self._conv_row(row)
            if wanted & {str(x).lower() for x in d["external_ids"] if x}:
                out.append(d)
        return out

    # -- reads -------------------------------------------------------------
    def user(self, user_id: int, *, mode: str | None = None) -> dict[str, Any] | None:
        """One user's row. With two rows (paying + churned) the newest one wins.

        A caller that knows which question it is asking passes `mode`; a caller
        asking "what is this user's open issue right now" (the hourly cancel page)
        takes the newest row, whichever sweep wrote it.
        """
        if mode:
            row = self.db.execute("SELECT * FROM support_state WHERE user_id=? AND mode=?",
                                  (int(user_id), mode)).fetchone()
        else:
            row = self.db.execute("SELECT * FROM support_state WHERE user_id=? "
                                  "ORDER BY checked_at DESC, mode LIMIT 1", (int(user_id),)).fetchone()
        return decode_state_row(dict(row)) if row else None

    def users(self, *, mode: str | None = None, tier: str | None = None) -> list[dict[str, Any]]:
        sql = "SELECT * FROM support_state WHERE 1=1"
        args: list[Any] = []
        if mode:
            sql += " AND mode=?"
            args.append(mode)
        if tier:
            sql += " AND tier=?"
            args.append(tier)
        out = []
        for row in self.db.execute(sql, args):
            out.append(decode_state_row(dict(row)))
        return out

    def last_run(self, mode: str) -> dict[str, Any] | None:
        row = self.db.execute("SELECT * FROM runs WHERE mode=? AND finished_at IS NOT NULL "
                              "ORDER BY finished_at DESC LIMIT 1", (mode,)).fetchone()
        return dict(row) if row else None

    def close(self) -> None:
        try:
            self.db.close()
        except sqlite3.Error:
            pass
