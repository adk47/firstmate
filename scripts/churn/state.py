"""Where the 325 come from: the support-state store, or the measured baseline artifact.

The store is ``support_state.py``'s (churn-risk-signal-prevent-p1): a nightly join of
core subscriptions, Intercom threads, open credit/claim rows, the verify ledger and the
proof store, written to ``/var/lib/hydra/churn/support-state.sqlite``. This module is the
READER only - it builds nothing and writes nothing.

**Store contract** (what this reader requires of that sqlite; a rename is a contract
break, not a silent zero):

    CREATE TABLE support_state (
      user_id TEXT PRIMARY KEY,
      tier TEXT NOT NULL,          -- T1-unanswered | T2-open-told-wait | T3-silent-pending | none
      primary_class TEXT NOT NULL, -- credits_not_approved | proof_sent_no_update |
                                   -- merge_claim_stuck | analytics_stale_wrong |
                                   -- billing_confusion | other
      classes_json TEXT,           -- JSON array: every cause class seen for this user
      mrr_cents INTEGER,           -- list MRR at cancel, cents (an `mrr` dollars column is accepted)
      plan TEXT, reason TEXT,
      cancel_at REAL NOT NULL,     -- epoch seconds (the cancel REQUEST when known)
      request_at REAL,
      wait_days REAL,
      evidence_json TEXT,          -- JSON array of human-readable evidence lines
      intercom_convs_json TEXT,    -- JSON array of Intercom conversation ids
      credit_open_json TEXT,       -- JSON object incl. `request_ids` when the store holds them
      claims_json TEXT, refunds INTEGER, disputes INTEGER,
      discount TEXT, customer_id TEXT, profile_id TEXT,
      measured_at REAL NOT NULL    -- when this row's state was measured
    );
    CREATE TABLE support_state_meta (k TEXT PRIMARY KEY, v TEXT NOT NULL);
      -- optional: generated_at (epoch), churn_days

The measured baseline artifact (``measure/winback-candidates.json`` from the Fable report)
is the same information in JSON. It exists so the campaign can be reasoned about and
rehearsed against the exact audience the report counted ($5,371 list MRR / 325 users)
before the store ships - and it is read the same way, through the same ``Candidate``
shape, so nothing downstream knows which one it got.

Neither source ships inside this repo. The sqlite store is churn-risk-signal-prevent-p1's
deliverable and the JSON baseline is the Fable report's measured artifact (kept in firstmate
data: it is a snapshot of user ids, not code). So a run always names its source, and
``load()`` says which one is missing instead of pretending the population is empty:

    ./scripts/route_fix.py --source json      # reads policy.paths.measured_candidates
    ./scripts/route_fix.py --source sqlite    # reads policy.paths.support_state_sqlite

**The window is measured from the SNAPSHOT, not from the wall clock.** "cancel <= 60 d"
means 60 days before the state was measured. Anchoring on run time would drop a user
mid-window because a nightly run landed an hour late, and would make the same snapshot
route differently on two consecutive days - the opposite of idempotent.
"""

from __future__ import annotations

import json
import sqlite3
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Iterable, Mapping

from . import model

CHURN_DAYS_DEFAULT = 60

_TEXT_COLS = {"user_id", "tier", "plan", "reason", "discount", "customer_id", "profile_id"}


class StateUnreadable(RuntimeError):
    """The store (or artifact) cannot be trusted. Always fatal: a silent zero here reads
    as 'nobody has an unhandled support state', which is the one wrong answer."""


@dataclass
class Snapshot:
    """The measured audience, plus everything needed to explain what was filtered out."""

    candidates: list[model.Candidate]
    anchor: float                     # epoch the state was measured at
    source: str                       # 'sqlite' | 'json'
    path: str
    churn_days: int = CHURN_DAYS_DEFAULT
    total_rows: int = 0
    skipped_tier_none: int = 0
    skipped_old: int = 0
    skipped_unreadable: int = 0
    notes: list[str] = field(default_factory=list)

    @property
    def mrr_cents(self) -> int:
        return sum(c.mrr_cents for c in self.candidates)

    def counts(self) -> dict[str, Any]:
        by_tier: dict[str, int] = {}
        by_lane: dict[str, int] = {}
        for c in self.candidates:
            by_tier[c.tier] = by_tier.get(c.tier, 0) + 1
            by_lane[c.lane] = by_lane.get(c.lane, 0) + 1
        return {
            "users": len(self.candidates),
            "mrr_cents": self.mrr_cents,
            "by_tier": dict(sorted(by_tier.items())),
            "by_lane": dict(sorted(by_lane.items())),
            "total_rows": self.total_rows,
            "skipped_tier_none": self.skipped_tier_none,
            "skipped_old": self.skipped_old,
            "skipped_unreadable": self.skipped_unreadable,
            "anchor": self.anchor,
            "source": self.source,
        }


def _json_list(raw: Any) -> tuple[Any, ...]:
    if raw is None or raw == "":
        return ()
    if isinstance(raw, (list, tuple)):
        return tuple(raw)
    try:
        val = json.loads(raw)
    except (TypeError, ValueError):
        return ()
    return tuple(val) if isinstance(val, list) else ()


def _json_map(raw: Any) -> dict[str, Any]:
    if isinstance(raw, Mapping):
        return dict(raw)
    if raw is None or raw == "":
        return {}
    try:
        val = json.loads(raw)
    except (TypeError, ValueError):
        return {}
    return dict(val) if isinstance(val, Mapping) else {}


def _epoch_or_none(raw: Any) -> float | None:
    """An epoch, or None when the column is absent/unreadable - never a placeholder zero.

    A NULL ``request_at`` mapped to 0.0 is indistinguishable from a real epoch of zero once it
    is written to ``candidate_json``, and the read-back then has to guess whether the user's
    wait started at the epoch or was never recorded.
    """
    if raw is None or raw == "":
        return None
    try:
        value = float(raw)
    except (TypeError, ValueError):
        return None
    return value if value > 0 else None


def _mrr_cents(row: Mapping[str, Any], mrr_column: str) -> int:
    if mrr_column == "mrr_cents":
        try:
            return int(round(float(row.get("mrr_cents") or 0)))
        except (TypeError, ValueError):
            return 0
    try:
        return int(round(float(row.get("mrr") or 0) * 100))
    except (TypeError, ValueError):
        return 0


def _candidate(row: Mapping[str, Any], *, mrr_column: str) -> model.Candidate | None:
    user_id = str(row.get("user_id") or "").strip()
    if not user_id:
        return None
    claims = row.get("claims")
    claims_map = _json_map(claims if claims not in (None, {}) else row.get("claims_json"))
    try:
        cancel_at = float(row.get("cancel_at") or 0.0)
    except (TypeError, ValueError):
        cancel_at = 0.0
    if cancel_at <= 0:
        return None
    return model.Candidate(
        user_id=user_id,
        tier=str(row.get("tier") or "none").strip(),
        primary_class=model.normalize_class(row.get("primary_class") or row.get("primary")),
        classes=tuple(model.normalize_class(c) for c in _json_list(row.get("classes") or row.get("classes_json"))),
        mrr_cents=_mrr_cents(row, mrr_column),
        plan=str(row.get("plan") or ""),
        reason=str(row.get("reason") or ""),
        cancel_at=cancel_at,
        request_at=_epoch_or_none(row.get("request_at")),
        wait_days=float(row.get("wait_days") or 0.0),
        evidence=tuple(str(e) for e in _json_list(row.get("evidence") or row.get("evidence_json"))),
        intercom_convs=tuple(str(c) for c in _json_list(row.get("intercom_convs") or row.get("intercom_convs_json"))),
        credit_open=_json_map(row.get("credit_open") or row.get("credit_open_json")),
        claims=claims_map or None,
        refunds=int(row.get("refunds") or 0),
        disputes=int(row.get("disputes") or 0),
        discount=(str(row["discount"]) if row.get("discount") else None),
        customer_id=(str(row["customer_id"]) if row.get("customer_id") else None),
        profile_id=(str(row["profile_id"]) if row.get("profile_id") else None),
    )


def _select(rows: Iterable[Mapping[str, Any]], *, anchor: float, churn_days: int,
            mrr_column: str) -> tuple[list[model.Candidate], int, int, int, int]:
    kept: list[model.Candidate] = []
    total = skipped_none = skipped_old = unreadable = 0
    window = churn_days * 86400.0
    for row in rows:
        total += 1
        cand = _candidate(row, mrr_column=mrr_column)
        if cand is None:
            unreadable += 1
            continue
        if model.tier_rank(cand.tier) >= len(model.TIERS):
            skipped_none += 1
            continue
        # An anchor in the future (clock skew, a replayed artifact) must not silently admit
        # negative ages; a cancel after the snapshot is simply not yet in the window.
        if cand.cancel_at > anchor + 60.0 or (anchor - cand.cancel_at) > window:
            skipped_old += 1
            continue
        kept.append(cand)
    kept.sort(key=model.Candidate.sort_key)
    return kept, total, skipped_none, skipped_old, unreadable


# ── sqlite store ─────────────────────────────────────────────────────────────
def _sqlite_mrr_column(cols: set[str]) -> str:
    if "mrr_cents" in cols:
        return "mrr_cents"
    if "mrr" in cols:
        return "mrr"
    raise StateUnreadable("support_state has neither an mrr_cents nor an mrr column")


def _sqlite_anchor(db: sqlite3.Connection) -> float:
    try:
        row = db.execute("SELECT v FROM support_state_meta WHERE k = 'generated_at'").fetchone()
    except sqlite3.Error:
        row = None
    if row and row[0]:
        try:
            return float(row[0])
        except (TypeError, ValueError):
            pass
    got = db.execute("SELECT MAX(measured_at) FROM support_state").fetchone()
    anchor = float(got[0] or 0.0) if got else 0.0
    if anchor <= 0:
        raise StateUnreadable("support_state has no usable generated_at / measured_at: cannot anchor the 60-day window")
    return anchor


def load_sqlite(path: str | Path, *, churn_days: int = CHURN_DAYS_DEFAULT,
                as_of: float | None = None) -> Snapshot:
    p = Path(path)
    if not p.exists():
        raise StateUnreadable(
            f"{p} does not exist. The store is churn-risk-signal-prevent-p1's deliverable "
            "(scripts/churn/support_state.py, nightly; not in this repo). To run against the "
            "measured baseline instead: --source json --candidates <policy.paths.measured_candidates>"
        )
    try:
        db = sqlite3.connect(f"file:{p}?mode=ro", uri=True, timeout=30)
    except sqlite3.Error as exc:  # pragma: no cover - depends on the filesystem
        raise StateUnreadable(f"{p} is unreadable: {exc}") from exc
    try:
        db.row_factory = sqlite3.Row
        cols = {r[1] for r in db.execute("PRAGMA table_info(support_state)")}
        if not cols:
            raise StateUnreadable(f"{p} has no support_state table (contract: scripts/churn/state.py)")
        for required in ("user_id", "tier", "cancel_at"):
            if required not in cols:
                raise StateUnreadable(f"{p}: support_state is missing the {required!r} column")
        anchor = float(as_of) if as_of else _sqlite_anchor(db)
        rows = [dict(r) for r in db.execute("SELECT * FROM support_state")]
        mrr_column = _sqlite_mrr_column(cols)
    finally:
        db.close()
    kept, total, none_, old, unreadable = _select(rows, anchor=anchor, churn_days=churn_days, mrr_column=mrr_column)
    return Snapshot(candidates=kept, anchor=anchor, source="sqlite", path=str(p), churn_days=churn_days,
                    total_rows=total, skipped_tier_none=none_, skipped_old=old, skipped_unreadable=unreadable)


# ── measured baseline artifact ───────────────────────────────────────────────
def load_json(path: str | Path, *, churn_days: int = CHURN_DAYS_DEFAULT,
              as_of: float | None = None) -> Snapshot:
    p = Path(path)
    try:
        raw = json.loads(p.read_text(encoding="utf-8"))
    except FileNotFoundError as exc:
        raise StateUnreadable(f"{p} does not exist") from exc
    except (OSError, ValueError) as exc:
        raise StateUnreadable(f"{p} is unreadable: {exc}") from exc
    if isinstance(raw, Mapping):
        rows = raw.get("candidates") or raw.get("users") or []
        anchor = float(raw.get("generated_at") or 0.0) or None
    else:
        rows, anchor = raw, None
    if not isinstance(rows, list):
        raise StateUnreadable(f"{p}: expected a JSON list of candidates")
    # The artifact carries no timestamp of its own, so its own write time is the snapshot.
    anchor = float(as_of) if as_of else float(anchor or p.stat().st_mtime)
    kept, total, none_, old, unreadable = _select(rows, anchor=anchor, churn_days=churn_days, mrr_column="mrr")
    snap = Snapshot(candidates=kept, anchor=anchor, source="json", path=str(p), churn_days=churn_days,
                    total_rows=total, skipped_tier_none=none_, skipped_old=old, skipped_unreadable=unreadable)
    snap.notes.append("measured baseline artifact: the audience the Fable report counted (ids only, no contact data)")
    return snap


def load(*, source: str = "sqlite", state: str | Path | None = None,
         candidates: str | Path | None = None, churn_days: int = CHURN_DAYS_DEFAULT,
         as_of: float | None = None) -> Snapshot:
    """Read the audience from the store (default) or the measured artifact."""
    if source == "json":
        if not candidates:
            raise StateUnreadable(
                "--source json needs --candidates <winback-candidates.json> (default: "
                "policy.paths.measured_candidates, the Fable report's measured artifact)")
        return load_json(candidates, churn_days=churn_days, as_of=as_of)
    if source != "sqlite":
        raise StateUnreadable(f"unknown --source {source!r} (sqlite | json)")
    if not state:
        raise StateUnreadable("--source sqlite needs --state <support-state.sqlite>")
    return load_sqlite(state, churn_days=churn_days, as_of=as_of)


def age_days(cancel_at: float, now: float | None = None) -> float:
    return ((now or time.time()) - float(cancel_at or 0.0)) / 86400.0
