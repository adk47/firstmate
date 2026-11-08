"""The fix-ticket ledger: what we routed, what came back Seen, who we therefore may message.

One sqlite file under /var/lib/hydra/churn (deploy-proof; /opt/hydra is rsync-overwritten):

* ``fix_tickets``   - one row per (user, primary class). The row is the campaign's memory:
                      it is what makes a second daily run a no-op instead of a twin ticket,
                      and it is the only thing that can make a user message-eligible.
* ``fix_events``    - append-only audit of every state change (routed / seen / ineligible /
                      handed / refused), so "why was this user messaged / not messaged" is
                      answerable from the file alone.
* ``send_messages`` - the campaign ledger (``campaign='wb_fix_1'``). ``UNIQUE (campaign,
                      user_id)`` is R5's "one message per user, ever" expressed as a
                      constraint rather than as a code path that hopes to remember.

State machine, and nothing may skip a step:

    routed      the owning lane has the ticket (lane_ref points into its intake)
    seen        the fix is visible in the system of record, with evidence (``fix_readback``)
    ineligible  it was fixed (or cannot be fixed) but this campaign may not message them -
                e.g. the read-back could not fill the FIX_LINE numbers, or the thread was
                closed by a sweep line rather than a human answer. Recorded, never messaged.

Only ``seen`` rows are ever handed to the sender seat, and only inside the 7-day window
(``policies/winback-fix.json`` -> windows.fix_eligible_days).

``fix_tickets.readback_attempts`` is the read-back's own clock: ``pending_readback`` hands back
only what is DUE under the policy's backoff schedule (``readback.backoff_hours``, one interval
per attempt measured from the previous attempt), so a ticket that never becomes Seen is re-read
five times over eight days and then stops consuming the hourly run - it stays ``routed`` and is
reported as ``readback_exhausted`` for the owning lane, never silently ineligible.
"""

from __future__ import annotations

import json
import os
import sqlite3
import time
from contextlib import contextmanager
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable, Iterator, Mapping

from . import model

CAMPAIGN = "wb_fix_1"

ROUTED, SEEN, INELIGIBLE = "routed", "seen", "ineligible"
STATES = (ROUTED, SEEN, INELIGIBLE)

SCHEMA = """
CREATE TABLE IF NOT EXISTS fix_tickets (
  ticket_id TEXT PRIMARY KEY,              -- sha256(user_id | primary class): one per user+class
  user_id TEXT NOT NULL,
  primary_class TEXT NOT NULL,
  lane TEXT NOT NULL,
  tier TEXT NOT NULL,
  mrr_cents INTEGER NOT NULL,
  wait_days REAL NOT NULL DEFAULT 0,
  cancel_at REAL NOT NULL,
  churned_tag TEXT NOT NULL,               -- churned:YYYY-MM-DD (the lane's priority tag)
  priority INTEGER NOT NULL DEFAULT 0,     -- 0 = head of the paid segment (R4)
  paid_priority_until REAL NOT NULL,       -- routed_at + 30 d: after this the flag lapses
  routed_at REAL NOT NULL,
  state TEXT NOT NULL,
  lane_ref TEXT,
  evidence_json TEXT NOT NULL DEFAULT '[]',
  candidate_json TEXT NOT NULL DEFAULT '{}',
  fixed_at REAL,
  readback_at REAL,
  readback_attempts INTEGER NOT NULL DEFAULT 0,   -- read-backs applied, for the backoff schedule
  readback_json TEXT
);
CREATE INDEX IF NOT EXISTS fix_tickets_lane ON fix_tickets(lane, state, priority, mrr_cents DESC);
CREATE INDEX IF NOT EXISTS fix_tickets_state ON fix_tickets(state, fixed_at);
CREATE TABLE IF NOT EXISTS fix_events (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  at REAL NOT NULL,
  ticket_id TEXT NOT NULL,
  event TEXT NOT NULL,
  detail TEXT
);
CREATE INDEX IF NOT EXISTS fix_events_ticket ON fix_events(ticket_id, at);
CREATE TABLE IF NOT EXISTS send_messages (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  campaign TEXT NOT NULL,
  user_id TEXT NOT NULL,
  ticket_id TEXT,
  day TEXT NOT NULL,                       -- UTC YYYY-MM-DD the send was handed on
  created_at REAL NOT NULL,
  template_key TEXT NOT NULL,
  cause_class TEXT NOT NULL,
  list_mrr_cents INTEGER NOT NULL,
  body_sha256 TEXT NOT NULL,
  state TEXT NOT NULL,                     -- handed | refused | failed
  detail TEXT,
  UNIQUE (campaign, user_id)
);
"""


def utc_day(ts: float | None = None) -> str:
    return time.strftime("%Y-%m-%d", time.gmtime(ts if ts is not None else time.time()))


def _json_map(raw: Any) -> dict[str, Any]:
    if raw in (None, ""):
        return {}
    try:
        val = json.loads(raw)
    except (TypeError, ValueError):
        return {}
    return dict(val) if isinstance(val, Mapping) else {}


@dataclass(frozen=True)
class Ticket:
    ticket_id: str
    user_id: str
    primary_class: str
    lane: str
    tier: str
    mrr_cents: int
    wait_days: float
    cancel_at: float
    churned_tag: str
    priority: int
    paid_priority_until: float
    routed_at: float
    state: str
    lane_ref: str | None
    evidence: tuple[str, ...]
    candidate: Mapping[str, Any]
    fixed_at: float | None
    readback_at: float | None
    readback: Mapping[str, Any] | None
    readback_attempts: int = 0

    @property
    def paid_priority(self) -> bool:
        return self.priority == 0

    @classmethod
    def from_row(cls, row: Mapping[str, Any]) -> "Ticket":
        def _load(raw: Any, *, as_map: bool = False) -> Any:
            if raw in (None, ""):
                return {} if as_map else ()
            try:
                val = json.loads(raw)
            except (TypeError, ValueError):
                return {} if as_map else ()
            if as_map:
                return val if isinstance(val, Mapping) else {}
            return tuple(val) if isinstance(val, list) else ()

        return cls(
            ticket_id=row["ticket_id"],
            user_id=row["user_id"],
            primary_class=row["primary_class"],
            lane=row["lane"],
            tier=row["tier"],
            mrr_cents=int(row["mrr_cents"]),
            wait_days=float(row["wait_days"] or 0.0),
            cancel_at=float(row["cancel_at"] or 0.0),
            churned_tag=row["churned_tag"],
            priority=int(row["priority"] or 0),
            paid_priority_until=float(row["paid_priority_until"] or 0.0),
            routed_at=float(row["routed_at"] or 0.0),
            state=row["state"],
            lane_ref=row["lane_ref"],
            evidence=_load(row["evidence_json"]),
            candidate=_load(row["candidate_json"], as_map=True),
            fixed_at=(float(row["fixed_at"]) if row["fixed_at"] is not None else None),
            readback_at=(float(row["readback_at"]) if row["readback_at"] is not None else None),
            readback=_load(row["readback_json"], as_map=True) or None,
            readback_attempts=int(row["readback_attempts"] or 0),
        )


def draft(candidate: model.Candidate, *, lane: str, now: float, paid_priority_days: int,
          churn_window_start: float | None = None) -> dict[str, Any]:
    """The row a routing run would write. Pure, so a dry run reports the same numbers.

    ``churn_window_start`` is the snapshot watermark minus ``windows.churn_days`` - the floor a
    fix is dated against when the read-back proves it. It is recorded here because this is the
    one place the measured snapshot is in hand; the read-back never guesses it from the clock.
    """
    row_candidate = candidate.as_row()
    row_candidate["churn_window_start"] = (float(churn_window_start)
                                          if churn_window_start is not None else None)
    return {
        "ticket_id": candidate.ticket_key(),
        "user_id": candidate.user_id,
        "primary_class": candidate.primary_class,
        "lane": lane,
        "tier": candidate.tier,
        "mrr_cents": candidate.mrr_cents,
        "wait_days": float(candidate.wait_days or 0.0),
        "cancel_at": candidate.cancel_at,
        "churned_tag": f"churned:{utc_day(now)}",
        "priority": 0,
        # R4 is a PROMOTION granted when we route, so its clock starts here, not at the cancel:
        # anchoring on cancel_at would hand the longest-waiting half of the audience a flag that
        # is already in the past, and the decider drops a lapsed entry.
        "paid_priority_until": now + paid_priority_days * 86400.0,
        "routed_at": now,
        "state": ROUTED,
        "lane_ref": None,
        "evidence": list(candidate.evidence),
        "candidate": row_candidate,
    }


_PRIVATE_DIR = 0o700
_PRIVATE_FILE = 0o600


class TicketStore:
    """The sqlite ledger. Opened read-only for the reader/reporter paths.

    A read-write open makes the state dir 0700 and the ledger (plus its sqlite journal
    siblings) 0600: ``fix_tickets.readback_json`` and ``fix_events.detail`` carry the staff
    reply verbatim, the same correspondence the run artifacts already protect.
    """

    def __init__(self, path: str | Path, *, readonly: bool = False):
        self.path = Path(path)
        self.readonly = readonly
        if readonly:
            if not self.path.exists():
                raise FileNotFoundError(self.path)
            self.db = sqlite3.connect(f"file:{self.path}?mode=ro", uri=True, timeout=30)
        else:
            self._prepare_state_dir()
            self.db = sqlite3.connect(self.path, timeout=30)
            self.db.executescript(SCHEMA)
            self._migrate()
            self._commit()
        self.db.row_factory = sqlite3.Row

    #: Columns added after the first deployments. ``CREATE TABLE IF NOT EXISTS`` never alters an
    #: existing table, so a live ledger would otherwise keep the old shape and fail every write.
    _ADDED_COLUMNS = {
        "readback_attempts": "INTEGER NOT NULL DEFAULT 0",
    }

    def _migrate(self) -> None:
        have = {str(r[1]) for r in self.db.execute("PRAGMA table_info(fix_tickets)")}
        for name, decl in self._ADDED_COLUMNS.items():
            if name not in have:
                self.db.execute(f"ALTER TABLE fix_tickets ADD COLUMN {name} {decl}")

    def _prepare_state_dir(self) -> None:
        if str(self.path) == ":memory:":
            return
        parent = self.path.parent
        if str(parent) in ("", "."):
            return
        parent.mkdir(parents=True, exist_ok=True, mode=_PRIVATE_DIR)
        os.chmod(parent, _PRIVATE_DIR)

    def _lock_down(self) -> None:
        """Best-effort 0600 on the ledger and its journal siblings.

        This runs AFTER a commit, so it must never raise: a chmod that fails (a read-only
        remount, EIO, EPERM) would otherwise turn a committed write into an exception the
        caller reads as "nothing was written".
        """
        if str(self.path) == ":memory:":
            return
        for path in (self.path, *(self.path.with_name(self.path.name + suffix)
                                 for suffix in ("-journal", "-wal", "-shm"))):
            try:
                os.chmod(path, _PRIVATE_FILE)
            except OSError:
                continue

    def _commit(self) -> None:
        self.db.commit()
        self._lock_down()

    def close(self) -> None:
        self.db.close()

    def __enter__(self) -> "TicketStore":
        return self

    def __exit__(self, *exc: Any) -> None:
        self.close()

    # ── reads ───────────────────────────────────────────────────────────────
    def get(self, ticket_id: str) -> Ticket | None:
        row = self.db.execute("SELECT * FROM fix_tickets WHERE ticket_id = ?", (ticket_id,)).fetchone()
        return Ticket.from_row(row) if row else None

    def by_state(self, state: str) -> list[Ticket]:
        rows = self.db.execute(
            "SELECT * FROM fix_tickets WHERE state = ? ORDER BY priority, mrr_cents DESC, wait_days DESC, user_id",
            (state,),
        )
        return [Ticket.from_row(r) for r in rows]

    def eligible(self, window_days: int, *, now: float | None = None) -> list[Ticket]:
        """Seen inside the window, highest list MRR first - the sender's candidate list.

        This method is the ONE owner of ``windows.fix_eligible_days``: a ticket fixed exactly at
        the cutoff instant is still inside it, one second older is not. Callers pass the window
        and must not re-filter the result.
        """
        now = now if now is not None else time.time()
        floor = now - window_days * 86400.0
        rows = self.db.execute(
            "SELECT * FROM fix_tickets WHERE state = ? AND fixed_at IS NOT NULL AND fixed_at >= ? "
            "ORDER BY priority, mrr_cents DESC, wait_days DESC, user_id",
            (SEEN, floor),
        )
        return [Ticket.from_row(r) for r in rows]

    def lane_counts(self) -> dict[str, int]:
        rows = self.db.execute("SELECT lane, COUNT(*) AS n FROM fix_tickets GROUP BY lane ORDER BY lane")
        return {r["lane"]: int(r["n"]) for r in rows}

    def state_counts(self) -> dict[str, int]:
        rows = self.db.execute("SELECT state, COUNT(*) AS n FROM fix_tickets GROUP BY state ORDER BY state")
        return {r["state"]: int(r["n"]) for r in rows}

    def pending_readback(self, *, schedule: Iterable[float], now: float | None = None,
                         limit: int | None = None) -> list[Ticket]:
        """The routed tickets DUE for another read-back, oldest-due first, at most ``limit``.

        ``schedule`` is ``policy.readback.backoff_hours``: the wait before attempt N is
        ``schedule[N]`` hours measured from the previous attempt (``routed_at`` for the first),
        so a ticket is due when ``COALESCE(readback_at, routed_at) + schedule[attempts] <= now``.
        A ticket that has used the whole schedule is NOT returned - it is exhausted, and
        ``exhausted_readback`` counts it. There is no "unbounded, everything, every hour".
        """
        hours = self._schedule(schedule)
        now = now if now is not None else time.time()
        whens = " ".join(f"WHEN {i} THEN {h * 3600.0!r}" for i, h in enumerate(hours))
        sql = (
            "SELECT *, (COALESCE(readback_at, routed_at) + (CASE readback_attempts "
            f"{whens} ELSE 0 END)) AS due_at FROM fix_tickets "
            "WHERE state = ? AND readback_attempts < ? "
            "AND COALESCE(readback_at, routed_at) + (CASE readback_attempts "
            f"{whens} ELSE 0 END) <= ? "
            "ORDER BY due_at, priority, mrr_cents DESC, wait_days DESC, user_id"
        )
        params: list[Any] = [ROUTED, len(hours), now]
        if limit is not None and limit > 0:
            sql += " LIMIT ?"
            params.append(int(limit))
        return [Ticket.from_row(r) for r in self.db.execute(sql, params)]

    def exhausted_readback(self, *, schedule: Iterable[float],
                           limit: int | None = None) -> list[Ticket]:
        """Routed tickets whose whole backoff schedule has been spent without becoming Seen."""
        sql = "SELECT * FROM fix_tickets WHERE state = ? AND readback_attempts >= ? "
        sql += "ORDER BY readback_at, priority, user_id"
        params: list[Any] = [ROUTED, len(self._schedule(schedule))]
        if limit is not None and limit > 0:
            sql += " LIMIT ?"
            params.append(int(limit))
        return [Ticket.from_row(r) for r in self.db.execute(sql, params)]

    @staticmethod
    def _schedule(schedule: Iterable[float]) -> tuple[float, ...]:
        hours = tuple(float(h) for h in schedule)
        if not hours or any(h <= 0 for h in hours):
            raise ValueError("a read-back schedule needs one positive interval per attempt")
        return hours

    # ── writes ──────────────────────────────────────────────────────────────
    def route(self, row: Mapping[str, Any], *, now: float | None = None) -> tuple[str, Ticket]:
        """Insert the ticket if new; return ('new'|'existing', ticket).

        Idempotency lives here and only here: the ticket id is a hash of (user, class), so a
        re-run finds its own row and the caller skips the intake write. A dry-run row that
        was never given a lane_ref is upgraded when a real run finally writes one.
        """
        existing = self.get(str(row["ticket_id"]))
        if existing is not None:
            return "existing", existing
        self.db.execute(
            "INSERT INTO fix_tickets (ticket_id, user_id, primary_class, lane, tier, mrr_cents, wait_days, "
            "cancel_at, churned_tag, priority, paid_priority_until, routed_at, state, lane_ref, evidence_json, "
            "candidate_json) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
            (
                row["ticket_id"], row["user_id"], row["primary_class"], row["lane"], row["tier"],
                int(row["mrr_cents"]), float(row["wait_days"]), float(row["cancel_at"]), row["churned_tag"],
                int(row["priority"]), float(row["paid_priority_until"]), float(row["routed_at"]), ROUTED,
                row.get("lane_ref"), json.dumps(list(row.get("evidence") or [])),
                json.dumps(dict(row.get("candidate") or {})),
            ),
        )
        self._event(str(row["ticket_id"]), "routed", {"lane": row["lane"], "lane_ref": row.get("lane_ref")}, now=now)
        self._commit()
        return "new", self.get(str(row["ticket_id"]))  # type: ignore[return-value]

    def set_lane_ref(self, ticket_id: str, lane_ref: str | None) -> None:
        self.db.execute("UPDATE fix_tickets SET lane_ref = ? WHERE ticket_id = ?", (lane_ref, ticket_id))
        self._event(ticket_id, "lane_ref", {"lane_ref": lane_ref})
        self._commit()

    def mark_seen(self, ticket_id: str, *, evidence: Mapping[str, Any], at: float | None = None) -> None:
        at = at if at is not None else time.time()
        self.db.execute(
            "UPDATE fix_tickets SET state = ?, fixed_at = ?, readback_at = ?, readback_json = ? WHERE ticket_id = ?",
            (SEEN, at, at, json.dumps(dict(evidence)), ticket_id),
        )
        self._event(ticket_id, "seen", dict(evidence), now=at)
        self._commit()

    def mark_ineligible(self, ticket_id: str, *, reason: str, evidence: Mapping[str, Any] | None = None,
                        at: float | None = None) -> None:
        at = at if at is not None else time.time()
        self.db.execute(
            "UPDATE fix_tickets SET state = ?, readback_at = ?, readback_json = ? WHERE ticket_id = ?",
            (INELIGIBLE, at, json.dumps({"reason": reason, **dict(evidence or {})}), ticket_id),
        )
        self._event(ticket_id, "ineligible", {"reason": reason, **dict(evidence or {})}, now=at)
        self._commit()

    def note(self, ticket_id: str, *, event: str, detail: Mapping[str, Any] | None = None,
             at: float | None = None) -> None:
        """Record why a Seen ticket did not go out, leaving its state AND its evidence alone.

        A policy gap is not this user's fault and a later policy edit may let them send, so the
        reason goes on the event log rather than into the terminal state or the evidence cell.
        """
        self._event(ticket_id, event, dict(detail or {}), now=at)
        self._commit()

    def record_readback(self, ticket_id: str, *, verdict: str, schedule: Iterable[float],
                        detail: Mapping[str, Any] | None = None,
                        at: float | None = None) -> bool:
        """One read-back attempt that is not yet Seen: the state is left alone.

        The attempt counter and ``readback_at`` always move (that is the backoff clock), but
        ``fix_events`` only gets a row when the VERDICT changes - the same reason read twice is
        not news, and an hourly cron must not grow the audit table by one row per ticket per
        hour. Returns True when this attempt used the last interval of ``schedule``: the ticket
        stays ``routed`` and is reported as ``readback_exhausted`` for the owning lane.
        """
        at = at if at is not None else time.time()
        row = self.db.execute(
            "SELECT readback_json, readback_attempts FROM fix_tickets WHERE ticket_id = ?", (ticket_id,)
        ).fetchone()
        if row is None:
            raise KeyError(ticket_id)
        previous = _json_map(row["readback_json"])
        attempts = int(row["readback_attempts"] or 0) + 1
        payload = {"verdict": verdict, **dict(detail or {})}
        self.db.execute(
            "UPDATE fix_tickets SET readback_at = ?, readback_attempts = ?, readback_json = ? "
            "WHERE ticket_id = ?",
            (at, attempts, json.dumps(payload), ticket_id),
        )
        if previous != payload:
            self._event(ticket_id, f"readback:{verdict}", payload, now=at)
        budget = len(self._schedule(schedule))
        if attempts == budget:
            self._event(ticket_id, "readback_exhausted",
                        {"attempts": attempts, "last": payload}, now=at)
            self._commit()
            return True
        self._commit()
        return False

    # ── the campaign ledger ─────────────────────────────────────────────────
    def messaged(self, user_id: str) -> bool:
        row = self.db.execute(
            "SELECT 1 FROM send_messages WHERE campaign = ? AND user_id = ?", (CAMPAIGN, user_id)
        ).fetchone()
        return row is not None

    @contextmanager
    def transaction(self) -> Iterator[None]:
        """One sqlite transaction: committed on success, rolled back on any exception.

        The send path claims the batch's ledger rows inside this and STAGES the hand-off
        manifest under a ``.tmp`` name, so a manifest that cannot be written leaves NO
        ``handed`` row behind. The staged file is published under the name the sender seat
        reads only after this returns, and a publish that fails releases the claims
        (``release_claims``): a batch that never reached the sender seat must not consume
        anyone's one message ever.
        """
        with self.db:
            yield
        self._lock_down()

    def ledger_row(self, *, user_id: str, ticket: Ticket, body_sha256: str, state: str,
                   day: str | None = None, detail: str = "", now: float | None = None,
                   commit: bool = True) -> bool:
        """Claim the one message this campaign may ever send this user. True = claimed.

        Claimed before the hand-off (R5). A duplicate claim returns False and the caller
        must not put the user in the batch: the constraint, not the caller, is the promise.
        ``commit=False`` leaves the claim inside the caller's transaction.
        """
        at = now if now is not None else time.time()
        try:
            self.db.execute(
                "INSERT INTO send_messages (campaign, user_id, ticket_id, day, created_at, template_key, "
                "cause_class, list_mrr_cents, body_sha256, state, detail) VALUES (?,?,?,?,?,?,?,?,?,?,?)",
                (CAMPAIGN, user_id, ticket.ticket_id, day or utc_day(at), at, CAMPAIGN, ticket.primary_class,
                 int(ticket.mrr_cents), body_sha256, state, detail[:500]),
            )
        except sqlite3.IntegrityError:
            return False
        self._event(ticket.ticket_id, f"ledger:{state}", {"user_id": user_id, "detail": detail[:200]}, now=at)
        if commit:
            self._commit()
        return True

    def release_claims(self, user_ids: Iterable[str], *, now: float | None = None,
                       detail: str = "") -> int:
        """Undo claims whose hand-off never became visible: those users keep their one message.

        Only a ``handed`` row is released, and only for the campaign's own ledger: a claim that
        already moved past the hand-off is somebody else's state to change.
        """
        at = now if now is not None else time.time()
        released = 0
        with self.db:
            for user_id in user_ids:
                row = self.db.execute(
                    "SELECT ticket_id FROM send_messages WHERE campaign=? AND user_id=? AND state=?",
                    (CAMPAIGN, user_id, "handed")).fetchone()
                if not row:
                    continue
                self.db.execute("DELETE FROM send_messages WHERE campaign=? AND user_id=?",
                                (CAMPAIGN, user_id))
                self._event(row[0], "ledger:released",
                            {"user_id": user_id, "detail": detail[:200]}, now=at)
                released += 1
        self._lock_down()
        return released

    def _event(self, ticket_id: str, event: str, detail: Mapping[str, Any], *, now: float | None = None) -> None:
        self.db.execute(
            "INSERT INTO fix_events (at, ticket_id, event, detail) VALUES (?,?,?,?)",
            (now if now is not None else time.time(), ticket_id, event, json.dumps(dict(detail))[:2000]),
        )


def lane_report(store: TicketStore) -> dict[str, Any]:
    """The counts a reviewer reads: per lane, per state, plus the paid-priority head."""
    return {
        "ledger": str(store.path),
        "by_lane": store.lane_counts(),
        "by_state": store.state_counts(),
        "total": sum(store.lane_counts().values()),
    }


def iter_lines(path: str | Path) -> Iterable[dict[str, Any]]:
    """Read a JSONL intake file (tolerant: a torn last line is skipped, never fatal)."""
    p = Path(path)
    if not p.exists():
        return
    with p.open(encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                yield json.loads(line)
            except ValueError:
                continue
