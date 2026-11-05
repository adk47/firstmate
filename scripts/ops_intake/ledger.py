"""The action ledger: every write the router performs, with its inverse.

This is the #1702 shape (action-audit-ledger-a1) for the ops-intake surface: one
row per write, written BEFORE the write executes, carrying the exact inverse.
The census's finding was not "the Ops bot wrote things" - it was that ~39 merges,
134 ClickUp writes, 34 Intercom replies, 21 hides and 420 request rejections in
14 days each left no row anywhere with a way back. A ledger is the difference
between a reversible ops bot and an irreversible one.

Ordering (load-bearing):

  1. ``plan`` writes the row with ``result='planned'`` and the inverse params;
     NO inverse, NO row, NO write - :func:`plan` raises.
  2. the caller performs the write and then calls :func:`mark_applied`, or
     :func:`mark_failed` if the write raised.
  3. a plan that never reached a terminal result is DRIFT: the watcher reports
     plans older than an hour as ``orphaned``, because a write that DID run
     without a marked plan is exactly what this table exists to expose. Planned
     rows still count against the burst caps on purpose - a burst of plans is
     still a burst - so the orphaned report surfaces the drift, it does not
     exempt the row from the cap.

Caps are counted from this table, not from the ask register: the question is
"how many writes", so the answer must come from the rows that mean writes.

Path: ``/var/lib/hydra/ops-intake/actions.sqlite`` (``OPS_INTAKE_ACTIONS_DB``),
deliberately its OWN file so action-audit-ledger-a1 can adopt or supersede it
without touching the ask register. Until that shared ledger lands,
``ledger_ticket`` stays NULL and :func:`plan` is the only writer.
"""
from __future__ import annotations

import json
import os
import sqlite3
from contextlib import contextmanager
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any, Callable, Iterator

DEFAULT_PATH = os.environ.get("OPS_INTAKE_ACTIONS_DB",
                              "/var/lib/hydra/ops-intake/actions.sqlite")

SCHEMA = """
CREATE TABLE IF NOT EXISTS action_ledger (
  id              INTEGER PRIMARY KEY AUTOINCREMENT,
  at              TEXT NOT NULL,
  actor           TEXT NOT NULL,          -- ops-intake@hydra-ops
  surface         TEXT NOT NULL,          -- slack:operations
  ask_id          TEXT NOT NULL,
  requester_id    TEXT NOT NULL,
  tier            TEXT NOT NULL,          -- W1 today; W2 may never be written here
  action          TEXT NOT NULL,
  target          TEXT,
  params_json     TEXT NOT NULL,
  inverse_action  TEXT NOT NULL,
  inverse_params_json TEXT NOT NULL,
  result          TEXT NOT NULL,          -- planned | applied | failed | reverted
  undo_state      TEXT NOT NULL DEFAULT 'available',
  reverted_at     TEXT,
  detail          TEXT,
  undo_attempts   INTEGER NOT NULL DEFAULT 0,  -- failed revert attempts (retryable)
  ledger_ticket   TEXT                   -- #1702 shared-ledger id, when it lands
);
CREATE INDEX IF NOT EXISTS action_ledger_req ON action_ledger(requester_id, at);
CREATE INDEX IF NOT EXISTS action_ledger_target ON action_ledger(target, at);
CREATE INDEX IF NOT EXISTS action_ledger_ask ON action_ledger(ask_id, id);
"""

ACTOR = "ops-intake@hydra-ops"
SURFACE = "slack:operations"
WRITE_TIERS = ("W1",)  # W2 is never written from this surface

# What each recorded inverse needs in order to be EXECUTABLE. A row whose inverse
# lacks these cannot undo anything, so :func:`ActionLedger.plan` refuses it.
REQUIRED_INVERSE_PARAMS: dict[str, tuple[str, ...]] = {
    "hide_pr_close": ("profile_ids",),
    "profile_rename_back": ("profile_id", "previous_display_name"),
}

# Handles only the WRITE can produce. They are absent at plan time and must be
# recorded before the row is marked applied - a NULL here is an inverse nobody
# can run (the #1702 failure in a new place).
DEFERRED_INVERSE_PARAMS: dict[str, tuple[str, ...]] = {
    "hide_pr_close": ("pr",),
}
DEFERRED_SOURCE_KEYS: dict[str, tuple[str, ...]] = {
    "pr": ("pr", "pr_number", "number"),
}


def utcnow() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def inverse_handle(inverse_action: str, result: Any) -> dict[str, Any] | None:
    """The inverse params the write's own result supplies, or None if a
    deferred handle is missing. ``{}`` means this inverse needs none."""
    wanted = DEFERRED_INVERSE_PARAMS.get(inverse_action, ())
    if not wanted:
        return {}
    body = result if isinstance(result, dict) else {}
    handle: dict[str, Any] = {}
    for key in wanted:
        value = None
        for source in DEFERRED_SOURCE_KEYS.get(key, (key,)):
            candidate = body.get(source)
            if candidate not in (None, "", [], {}):
                value = candidate
                break
        if value is None:
            return None
        handle[key] = value
    return handle


class LedgerError(RuntimeError):
    """The write must not happen."""


class ActionLedger:
    def __init__(self, path: str | Path | None = None):
        self.path = str(path or DEFAULT_PATH)

    @contextmanager
    def connect(self) -> Iterator[sqlite3.Connection]:
        Path(self.path).parent.mkdir(parents=True, exist_ok=True)
        try:
            os.chmod(Path(self.path).parent, 0o700)
        except OSError:
            pass
        conn = sqlite3.connect(self.path, timeout=15)
        conn.row_factory = sqlite3.Row
        try:
            conn.execute("PRAGMA journal_mode=WAL")
            conn.execute("PRAGMA busy_timeout=15000")
            conn.executescript(SCHEMA)
            columns = {row["name"] for row in conn.execute("PRAGMA table_info(action_ledger)")}
            if "undo_attempts" not in columns:
                conn.execute("ALTER TABLE action_ledger "
                             "ADD COLUMN undo_attempts INTEGER NOT NULL DEFAULT 0")
            yield conn
            conn.commit()
        finally:
            conn.close()
        try:
            os.chmod(self.path, 0o600)
        except OSError:
            pass

    # -- the only way in --------------------------------------------------
    def plan(self, *, ask_id: str, requester_id: str, tier: str, action: str,
             target: str | None, params: dict[str, Any], inverse_action: str,
             inverse_params: dict[str, Any], at: str | None = None,
             detail: str | None = None) -> int:
        """Write the row BEFORE the write. Refuses anything not invertible."""
        if tier not in WRITE_TIERS:
            raise LedgerError(f"tier {tier!r} is not a write tier on this surface")
        if not inverse_action or not isinstance(inverse_params, dict):
            raise LedgerError(f"action {action!r} has no recorded inverse - refusing the write")
        if inverse_action == action and inverse_params == params:
            raise LedgerError(f"action {action!r} records itself as its inverse - that is not an inverse")
        missing = [key for key in REQUIRED_INVERSE_PARAMS.get(inverse_action, ())
                   if inverse_params.get(key) in (None, "", [], {})]
        if missing:
            raise LedgerError(
                f"action {action!r} inverse {inverse_action!r} is missing "
                f"{', '.join(missing)} - it could not be executed, so there is no inverse")
        with self.connect() as conn:
            cur = conn.execute(
                """INSERT INTO action_ledger (at, actor, surface, ask_id, requester_id, tier,
                     action, target, params_json, inverse_action, inverse_params_json,
                     result, undo_state, detail)
                   VALUES (?,?,?,?,?,?,?,?,?,?,?,'planned','available',?)""",
                (at or utcnow(), ACTOR, SURFACE, ask_id, requester_id, tier, action, target,
                 json.dumps(params, sort_keys=True), inverse_action,
                 json.dumps(inverse_params, sort_keys=True), detail))
            return int(cur.lastrowid)

    def set_inverse(self, ledger_id: int, params: dict[str, Any]) -> None:
        """Merge the handle the WRITE returned into the recorded inverse."""
        row = self.get(ledger_id)
        if row is None:
            raise LedgerError(f"ledger row {ledger_id} not found")
        merged = json.loads(row["inverse_params_json"] or "{}")
        merged.update(params)
        with self.connect() as conn:
            conn.execute("UPDATE action_ledger SET inverse_params_json=? WHERE id=?",
                         (json.dumps(merged, sort_keys=True), ledger_id))

    def missing_deferred(self, ledger_id: int, inverse_action: str) -> list[str]:
        """Deferred inverse handles this row still needs before it counts as applied."""
        row = self.get(ledger_id)
        if row is None:
            raise LedgerError(f"ledger row {ledger_id} not found")
        recorded = json.loads(row["inverse_params_json"] or "{}")
        return [key for key in DEFERRED_INVERSE_PARAMS.get(inverse_action, ())
                if recorded.get(key) in (None, "", [], {})]

    def mark_applied(self, ledger_id: int, *, detail: str | None = None,
                     undo_state: str = "available") -> None:
        """The write HAPPENED. ``undo_state`` says whether its inverse can still run
        (``unavailable`` when the write returned no handle to undo it)."""
        with self.connect() as conn:
            if detail is None:
                conn.execute("UPDATE action_ledger SET result='applied', undo_state=? "
                             "WHERE id=?", (undo_state, ledger_id))
            else:
                conn.execute("UPDATE action_ledger SET result='applied', undo_state=?, "
                             "detail=? WHERE id=?", (undo_state, detail[:2000], ledger_id))

    def mark_failed(self, ledger_id: int, *, detail: str, undo_state: str = "n/a") -> None:
        with self.connect() as conn:
            conn.execute(
                "UPDATE action_ledger SET result='failed', undo_state=?, detail=? WHERE id=?",
                (undo_state, detail[:2000], ledger_id))

    def mark_reverted(self, ledger_id: int, *, detail: str | None = None) -> None:
        with self.connect() as conn:
            conn.execute(
                "UPDATE action_ledger SET undo_state='reverted', reverted_at=?, "
                "detail=COALESCE(?, detail) WHERE id=?",
                (utcnow(), detail, ledger_id))

    def get(self, ledger_id: int) -> dict[str, Any] | None:
        with self.connect() as conn:
            row = conn.execute("SELECT * FROM action_ledger WHERE id=?", (ledger_id,)).fetchone()
            return dict(row) if row else None

    def rows_for_ask(self, ask_id: str) -> list[dict[str, Any]]:
        with self.connect() as conn:
            return [dict(r) for r in conn.execute(
                "SELECT * FROM action_ledger WHERE ask_id=? ORDER BY id", (ask_id,))]

    # -- burst caps -------------------------------------------------------
    def writes_by_requester(self, requester_id: str, *, within: timedelta,
                            now: datetime | None = None) -> int:
        cut = (now or datetime.now(timezone.utc)) - within
        with self.connect() as conn:
            return int(conn.execute(
                "SELECT COUNT(*) n FROM action_ledger WHERE requester_id=? "
                "AND result IN ('applied','planned') AND at >= ?",
                (requester_id, cut.strftime("%Y-%m-%dT%H:%M:%SZ"))).fetchone()["n"])

    def writes_to_target(self, target: str, *, within: timedelta,
                         now: datetime | None = None) -> int:
        cut = (now or datetime.now(timezone.utc)) - within
        with self.connect() as conn:
            return int(conn.execute(
                "SELECT COUNT(*) n FROM action_ledger WHERE target=? "
                "AND result IN ('applied','planned') AND at >= ?",
                (target, cut.strftime("%Y-%m-%dT%H:%M:%SZ"))).fetchone()["n"])

    def cap_check(self, *, requester_id: str, target: str | None, limits: dict[str, Any],
                  now: datetime | None = None) -> tuple[bool, str]:
        """(allowed, reason). A missing/zero cap is a violation, not 'unlimited'."""
        per_hour = int(limits.get("w1_per_requester_per_hour") or 0)
        per_target = int(limits.get("writes_per_target_per_day") or 0)
        if per_hour <= 0 or per_target <= 0:
            return False, "caps.missing"
        used = self.writes_by_requester(requester_id, within=timedelta(hours=1), now=now)
        if used >= per_hour:
            return False, f"cap:requester-hour {used}/{per_hour}"
        if target:
            tgt = self.writes_to_target(target, within=timedelta(days=1), now=now)
            if tgt >= per_target:
                return False, f"cap:target-day {tgt}/{per_target}"
        return True, "under-cap"

    # -- undo -------------------------------------------------------------
    def revert(self, ledger_id: int, executor: Callable[[str, dict[str, Any]], Any], *,
               note: str | None = None) -> dict[str, Any]:
        """Run the recorded inverse. The inverse is a (action, params) pair, so a
        caller cannot 'revert' into some other write."""
        row = self.get(ledger_id)
        if row is None:
            raise LedgerError(f"ledger row {ledger_id} not found")
        if row["undo_state"] != "available":
            raise LedgerError(f"ledger row {ledger_id} undo_state={row['undo_state']}")
        if row["result"] != "applied":
            raise LedgerError(f"ledger row {ledger_id} result={row['result']} - nothing to revert")
        params = json.loads(row["inverse_params_json"])
        try:
            executor(row["inverse_action"], params)
        except Exception as exc:  # noqa: BLE001 - surfaced, never swallowed
            # A transient inverse failure must not destroy the inverse: the write
            # is still live, so the row stays applied/available and can be retried.
            with self.connect() as conn:
                conn.execute(
                    "UPDATE action_ledger SET undo_attempts = undo_attempts + 1, "
                    "detail=? WHERE id=?",
                    (f"revert failed (attempt {int(row['undo_attempts'] or 0) + 1}): "
                     f"{exc}"[:2000], ledger_id))
            raise
        self.mark_reverted(ledger_id, detail=note or f"reverted via {row['inverse_action']}")
        return {"ledger_id": ledger_id, "inverse_action": row["inverse_action"],
                "params": params}

    def orphaned_plans(self, *, older_than: timedelta = timedelta(hours=1),
                       now: datetime | None = None) -> list[dict[str, Any]]:
        cut = (now or datetime.now(timezone.utc)) - older_than
        with self.connect() as conn:
            return [dict(r) for r in conn.execute(
                "SELECT * FROM action_ledger WHERE result='planned' AND at <= ?",
                (cut.strftime("%Y-%m-%dT%H:%M:%SZ"),))]
