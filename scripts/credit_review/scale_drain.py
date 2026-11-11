#!/usr/bin/env python3
"""The verification scale drain: a deterministic, sharded, idempotent decision pass.

Design of record: ``data/verification-scale-plan.md``. Captain 2026-11-11: "we need to
scale that to faster more parallel 1000s a min". 92,861 requests carry a declared state;
at 1,000/min the whole drain is 93 minutes, so this is a ONE-TIME PASS plus a small
continuous tail, not a forever-throughput problem.

Why the old path could not get there: ``muso-admin-api.sh`` did three round trips per
user (token resolve, account resolve, route) and the side window measured 1.4 minutes
per user end to end. Even perfect batching tops out near 1,000/day at that cost. The
fix is not a faster loop, it is to stop paying per-user cost at all:

  1. HOIST. Token resolves once per run (``batch_admin.BatchAdmin``), account resolve is
     one query for N ids, route is one call per page. Per-user cost drops from ~84 s to
     single-digit milliseconds.
  2. DECIDE DETERMINISTICALLY, in rank order, with NO model in the hot path. Every rule
     is a SQL predicate over a local snapshot; the ladder stops at the first match. A
     model reviews a sample and proposes rule changes, it never decides a row (captain
     2026-10-29). A model call is 1-3 s; a predicate is microseconds.
  3. SHARD by contiguous id range, one idempotency key per request
     (``decision_key = sha256(request_id || rule || version)``). A re-run cannot
     double-apply; a restarted worker skips every row already in the ledger.
  4. PARALLELISE THE READ, KEEP THE WRITE ORDERED. The decision pass is read-only and
     runs 32 wide; the apply is a write, bounded to 6-8 against the same API, with the
     read pool running ahead.

The rank order (stop at the first match):

  | # | rule            | outcome                          | share of the 92,861 |
  |---|-----------------|----------------------------------|---------------------|
  | 1 | duplicate       | close DUPLICATE                  | 6,631               |
  | 2 | precedent       | approve / queue for tier-2       | ~9,465              |
  | 3 | proof_verdict   | approve / queue on the verdict   | 1,755               |
  | 4 | expired         | queue once, with a reason code   | the aged tail       |
  | 5 | ask             | ask once                         | 23,247              |

Expiry may only refuse a request we actually ASKED (``asked_at IS NOT NULL``). A
never-asked request falls through to ``ask``: the 23,247 OPEN_UNASKED rows are the
drain's population, not its refuse pile, and refusing a customer we never asked is a
customer-facing denial we do not do.

Two invariants are code, not prose:

  * **Byte-identical re-run.** ``plan`` emits canonical JSONL (sorted by request_id,
    sorted keys, fixed separators) and carries NO clock and NO run id. Two runs over the
    same snapshot are byte-identical, which is what makes "re-run and diff" a real test.
  * **No duplicate send.** The apply ledger has ``UNIQUE(decision_key)`` and append-only
    triggers. A ``kill -9`` mid-pass leaves committed rows committed and uncommitted rows
    absent; the restart re-plans the same keys and the unique index makes the second
    write a no-op. That is the proof against a duplicate send, not a hope.
  * **Ledger first.** A decision with an API side effect is an ``intents`` row before the
    API hears of it, and ``applied`` + ``confirmed`` after. An intent nobody confirmed is
    reconciled against the live request on the next run, never retried blind.

The ASK outcome does NOT send anything here. It emits rows in the reviewed ask path's
own list schema and hands them to ``need_asks`` -> ``intercom-verify-request.sh``, which
owns the copy, the copy lock, the go-live guards, the comm_state read and the
one-ask-per-user-per-90-days ledger. There is exactly ONE reviewed ask/notify path and
this module is not it (see ``docs/credit-verification/scale-drain.md``).

CLI:
  scale_drain.py plan   --snapshot FILE --out FILE [--shards N] [--now TS]
  scale_drain.py apply  --plan FILE --ledger FILE [--shards N] [--write-pool N] [--dry-run]
  scale_drain.py verify --plan FILE --ledger FILE
  scale_drain.py chaos  --plan FILE --kill-after N [--rounds N]
  scale_drain.py bench  --snapshot FILE [--shards N]
"""
from __future__ import annotations

import argparse
import dataclasses
import hashlib
import json
import os
import sqlite3
import subprocess
import sys
import tempfile
import threading
import time
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any, Callable, Iterable, Sequence

#: Bumped whenever a rule's meaning changes. It is part of the idempotency key, so a
#: rule change deliberately produces NEW keys and a re-run re-decides those rows; an
#: unchanged rule produces the same key and the write is a no-op.
RULE_VERSION = "1"

#: The rank order. Stop at the first match. Order is the specification, not a hint.
RULES: tuple[str, ...] = ("duplicate", "precedent", "proof_verdict", "expired", "ask")

#: rule -> the outcome it produces. `proof_verdict` is resolved from the verdict itself.
#:
#: ``queue_tier2`` is the outcome for every row the ladder would REFUSE. A refusal is a
#: customer-facing denial, so it is not ours to make autonomously: the wrapper's reject
#: gate demands a tier-2 approver and it is right to. The drain writes nothing for these
#: rows, records them with their reason code, and lists them for a named human
#: (``tier2-queue``). A duplicate close is different and IS autonomous - deduplication is
#: not a new decision, the original decision stands, and the customer's outcome is
#: unchanged (captain decision 2026-11-11).
OUTCOME_OF: dict[str, str] = {
    "duplicate": "close_duplicate",
    "precedent": "approve",
    "proof_verdict": "verdict",     # approve | queue_tier2, from the computed verdict
    "expired": "queue_tier2",
    "ask": "ask",
}

#: Outcomes that perform an API write. ``ask`` belongs to need_asks.py and
#: ``queue_tier2`` belongs to a named human, so neither is a drain write.
WRITING_OUTCOMES: tuple[str, ...] = ("approve", "close_duplicate")

#: The reason code a refusal names. A refusal without a code is not a refusal we can
#: audit, so every refuse outcome carries one of these.
REASON_CODES: dict[str, str] = {
    "duplicate": "duplicate_of_decided",
    "precedent": "precedent_match",
    "proof_verdict_approve": "proof_verdict_approve",
    "proof_verdict_refuse": "proof_verdict_refuse",
    "precedent_refuse": "precedent_refuse",
    "expired": "expired_no_proof",
    "ask": "no_rule_matched",
    # The ladder wanted to approve but the row carries no row-specific evidence anchor,
    # so the wrapper's approve gate would refuse it. Ask instead of approving blind.
    "no_evidence_anchor": "no_evidence_anchor",
    # A row that CARRIES a decision fact (a duplicate target, a precedent key, a proof
    # verdict) that could not be resolved against its source. It is neither written nor
    # asked: a row the customer was already decided on must never become a fresh ask, so
    # it is counted as unmatched and left for the next pass.
    "unmatched_duplicate": "unmatched_duplicate",
    "unmatched_precedent": "unmatched_precedent",
    "unmatched_proof_verdict": "unmatched_proof_verdict",
    # ``verificationData.duplicate_of`` names credits ALREADY ON THE PROFILE, not a decided
    # request: in core it is a map ``{"<track>|<role>": "<credit id>"}``. There is no
    # original request for the gate to verify, so the drain cannot close it, and
    # ``uvn_status.ask_class`` already rules such a request is never asked about. Counted,
    # never written, never asked.
    "already_on_profile": "already_on_profile",
    # An ``ask`` row that already has a document on file whose verdict is not a decision
    # (SUSPECT / PLAUSIBLE / UNDETERMINED, or roles the analysis does not cover). Still an
    # ``ask`` - need_asks.py decides whether a per-need ask about THAT document is due or
    # the row waits - but named, so "rows nobody has heard from" and "rows that already
    # sent something" are never one number.
    "proof_on_file_undecided": "proof_on_file_undecided",
}

#: The outcome for a fact-carrying row whose fact could not be resolved. Not a write and
#: not an ask: it is reported, never committed, so the next pass can resolve it.
UNMATCHED: str = "unmatched"

#: Requests in these states are the drain's population. Anything else is already decided
#: or not ours to touch.
PENDING_STATUSES: tuple[str, ...] = ("user_verification_needed", "unverified")

#: Default window after which an unanswered ask expires and is refused once. The plan
#: requires `expires_at` to exist; when core does not carry one we derive it from
#: createdAt so the expired rule is always evaluable.
ASK_WINDOW_DAYS = 30

#: Read pool: the decision pass is read-only, so it is safe to run wide.
READ_POOL = 32
#: Write pool: the apply is a write against the same API. The plan's ceiling is 6-8.
WRITE_POOL = 6
#: Start at 16 shards, tune to 32 if the API sustains it (plan, change 3).
DEFAULT_SHARDS = 16


#: The requester identity every admin call is made under. It is the drain's OWN identity,
#: not a shared one: the wrapper's approve gate admits a drain approve only when the
#: requester is exactly this, ``SCALE_DRAIN=1`` is set, the registry entry is approved,
#: and the evidence excerpt is a well-formed drain digest naming an auto-approvable rule.
SERVICE_REQUESTER = "scale-drain@hydra-ops"

#: The rules whose approve is evidence-bearing. ``ask``, ``expired`` and ``duplicate``
#: can never approve, and the wrapper's gate enforces that independently of this list.
AUTO_APPROVABLE_RULES = ("precedent", "proof_verdict")


class DrainError(RuntimeError):
    pass


class DrainWriteError(DrainError):
    """A write through the reviewed path did not land. The row is NOT committed."""


# ── the idempotency key ─────────────────────────────────────────────────────

def decision_key(request_id: str, rule: str, outcome: str,
                 version: str = RULE_VERSION) -> str:
    """``sha256(request_id || rule || outcome || version)``.

    The plan specifies ``sha256(request_id || rule || version)``; the OUTCOME is added
    because without it a decision that CHANGES keeps its key and ``apply`` skips it. A
    refusal queued for a tier-2 approver that later becomes an approval would be silently
    dropped (QA review 2 of hydra#1883). With the outcome in the key, a changed decision is
    a new key and gets applied; an unchanged one is still byte-identical, so a re-run
    cannot double-apply.

    The separator is a NUL so no request id can be crafted to collide with a different
    (rule, outcome, version) tuple by shifting bytes across the boundary.
    """
    if not request_id:
        raise DrainError("decision_key needs a request_id")
    if rule not in RULES:
        raise DrainError(f"decision_key: unknown rule {rule!r}")
    if not outcome:
        raise DrainError("decision_key needs an outcome")
    raw = f"{request_id}\x00{rule}\x00{outcome}\x00{version}".encode("utf-8")
    return hashlib.sha256(raw).hexdigest()


# ── sharding ────────────────────────────────────────────────────────────────

def shard_bounds(ids: Sequence[str], shards: int) -> list[tuple[int, int]]:
    """Contiguous ``[start, stop)`` slices of the SORTED id list, one per shard.

    Request ids are UUIDs, so "contiguous id range" means contiguous in the canonical
    sorted order rather than a numeric range. That keeps the plan's property that
    matters - each worker owns one contiguous slice for the whole pass, so there is no
    per-row coordination - and it is deterministic: the same id set always produces the
    same slices, so a restarted worker re-reads exactly its own shard.
    """
    if shards < 1:
        raise DrainError("shards must be >= 1")
    ordered = sorted(ids)
    n = len(ordered)
    out: list[tuple[int, int]] = []
    for k in range(shards):
        start = (k * n) // shards
        stop = ((k + 1) * n) // shards
        out.append((start, stop))
    return out


def shard_of(ids: Sequence[str], shards: int, request_id: str) -> int:
    """Which shard owns ``request_id``. Deterministic and total over the id set."""
    ordered = sorted(ids)
    try:
        pos = ordered.index(request_id)
    except ValueError as exc:
        raise DrainError(f"{request_id} is not in the snapshot") from exc
    for k, (start, stop) in enumerate(shard_bounds(ordered, shards)):
        if start <= pos < stop:
            return k
    raise DrainError(f"no shard owns {request_id}")  # unreachable for a valid id set


# ── the snapshot ────────────────────────────────────────────────────────────

SNAPSHOT_SCHEMA = """
CREATE TABLE IF NOT EXISTS requests (
  request_id        TEXT PRIMARY KEY,
  profile_id        TEXT,
  user_id           INTEGER,
  status            TEXT NOT NULL,
  created_at        TEXT,
  expires_at        TEXT,          -- derived from created_at when core carries none
  duplicate_of      TEXT,          -- the request this one duplicates
  -- What ``duplicate_of`` WAS in the source: 'request' (an id, in duplicate_of),
  -- 'profile_credit' (core's {track|role: credit id} map) or 'other'. Only 'request' can
  -- be closed; the other two are a duplicate FACT with nothing for the gate to verify.
  duplicate_kind    TEXT,
  precedent_key     TEXT,          -- the precedent class this request falls in
  proof_verdict     TEXT,          -- approve | refuse | NULL (no verdict computed)
  proof_received_at TEXT,
  proof_id          TEXT,
  asked_at          TEXT,          -- when we last asked about THIS request; NULL = never asked
  -- The row-specific anchor an approve must cite. A precedent approve cites the
  -- request that set the precedent; a proof-verdict approve cites the proof. Without
  -- one the row is NOT auto-approvable and falls through to ask.
  precedent_request_id TEXT,
  track_id          TEXT,
  claimed_roles     TEXT           -- JSON array, the claim the precedent key is built from
);
CREATE INDEX IF NOT EXISTS requests_status ON requests(status);
CREATE TABLE IF NOT EXISTS decided (
  request_id TEXT PRIMARY KEY,
  decision   TEXT NOT NULL         -- approved | rejected | closed
);
CREATE TABLE IF NOT EXISTS precedent (
  precedent_key TEXT PRIMARY KEY,
  outcome       TEXT NOT NULL,     -- approve | refuse
  -- The request that SET the precedent. An approve must cite it: the wrapper's approve
  -- gate checks a row-specific anchor, so a precedent with no request id cannot approve.
  request_id    TEXT
);
"""


def derive_expires_at(created_at: str | None, window_days: int = ASK_WINDOW_DAYS) -> str | None:
    """``created_at + window_days`` in the ledger's UTC stamp format.

    The plan requires ``expires_at`` to exist so the expired rule is always evaluable.
    Core does not carry one on a credit request, so we derive it from ``createdAt``. An
    unparseable or absent ``createdAt`` yields NULL, which makes the expired rule
    inapplicable rather than silently refusing a request we cannot date.
    """
    if not created_at:
        return None
    ts = parse_ts(created_at)
    if ts is None:
        return None
    return (ts + timedelta(days=window_days)).strftime("%Y-%m-%dT%H:%M:%SZ")


def parse_ts(value: Any) -> datetime | None:
    if not isinstance(value, str) or not value:
        return None
    text = value.strip()
    if text.endswith("Z"):
        text = text[:-1] + "+00:00"
    try:
        ts = datetime.fromisoformat(text)
    except ValueError:
        return None
    if ts.tzinfo is None:
        ts = ts.replace(tzinfo=timezone.utc)
    return ts.astimezone(timezone.utc)


def utc(ts: datetime | None = None) -> str:
    return (ts or datetime.now(timezone.utc)).strftime("%Y-%m-%dT%H:%M:%SZ")


def open_snapshot(path: str | None = None) -> sqlite3.Connection:
    db = sqlite3.connect(path or ":memory:")
    db.executescript(SNAPSHOT_SCHEMA)
    # A snapshot file made before ``duplicate_kind`` existed gains the column on open.
    if "duplicate_kind" not in {r[1] for r in db.execute("PRAGMA table_info(requests)")}:
        db.execute("ALTER TABLE requests ADD COLUMN duplicate_kind TEXT")
    return db


DUP_REQUEST, DUP_PROFILE_CREDIT, DUP_OTHER = "request", "profile_credit", "other"


def classify_duplicate(value: Any) -> tuple[str | None, str | None]:
    """``(request id | None, kind | None)`` for a source ``duplicate_of`` value.

    The ladder was written for a request id. Core's ``verificationData.duplicate_of`` is
    not one: on every pending row that carries it (856 of 96,703 on 2026-11-11) it is a
    map ``{"<track uuid>|<role>": "<24-hex credit id>"}`` - the credits already on the
    profile that this request repeats. Bound straight into SQLite that map raised
    ``ProgrammingError: type 'dict' is not supported`` and the whole plan died.

    Nothing here guesses. A string is taken as the request id it claims to be (and is
    ``unmatched`` if no decided request has that id). Anything else truthy is a duplicate
    fact of another kind: it is recorded as such, so the row is neither closed - there is
    no decided original to verify - nor silently treated as a fresh ask.
    """
    if value is None or value == "" or value == {} or value == []:
        return None, None
    if isinstance(value, str):
        return value, DUP_REQUEST
    if isinstance(value, dict):
        return None, DUP_PROFILE_CREDIT
    return None, DUP_OTHER


def load_snapshot(db: sqlite3.Connection, rows: Iterable[dict[str, Any]], *,
                  window_days: int = ASK_WINDOW_DAYS) -> int:
    """Load request rows into the snapshot. Idempotent: a re-load replaces the row.

    ``rows`` are the batched reads' output (``batch_admin``), one dict per request. The
    only field this function invents is ``expires_at``, and only when the row carries
    none - see ``derive_expires_at``.
    """
    n = 0
    for r in rows:
        rid = str(r.get("request_id") or r.get("id") or "")
        if not rid:
            raise DrainError("snapshot row has no request_id")
        expires = r.get("expires_at") or derive_expires_at(r.get("created_at") or r.get("createdAt"), window_days)
        duplicate_of, duplicate_kind = classify_duplicate(r.get("duplicate_of"))
        db.execute(
            "INSERT INTO requests (request_id, profile_id, user_id, status, created_at, expires_at,"
            " duplicate_of, duplicate_kind, precedent_key, proof_verdict, proof_received_at, proof_id,"
            " asked_at, precedent_request_id, track_id, claimed_roles)"
            " VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)"
            " ON CONFLICT(request_id) DO UPDATE SET profile_id=excluded.profile_id, user_id=excluded.user_id,"
            " status=excluded.status, created_at=excluded.created_at, expires_at=excluded.expires_at,"
            " duplicate_of=excluded.duplicate_of, duplicate_kind=excluded.duplicate_kind,"
            " precedent_key=excluded.precedent_key,"
            " proof_verdict=excluded.proof_verdict, proof_received_at=excluded.proof_received_at,"
            " proof_id=excluded.proof_id, asked_at=excluded.asked_at,"
            " precedent_request_id=excluded.precedent_request_id, track_id=excluded.track_id,"
            " claimed_roles=excluded.claimed_roles",
            (rid, r.get("profile_id"), r.get("user_id"), str(r.get("status") or ""),
             r.get("created_at") or r.get("createdAt"), expires,
             duplicate_of, duplicate_kind, r.get("precedent_key"), r.get("proof_verdict"),
             r.get("proof_received_at"), r.get("proof_id"),
             r.get("asked_at") or r.get("askedAt"),
             r.get("precedent_request_id") or r.get("precedentRequestId"),
             r.get("track_id") or r.get("trackId"),
             json.dumps(list(r.get("claimed_roles") or []), sort_keys=True)))
        n += 1
    db.commit()
    return n


def load_decided(db: sqlite3.Connection, rows: Iterable[dict[str, Any]]) -> int:
    n = 0
    for r in rows:
        rid = str(r.get("request_id") or r.get("id") or "")
        if not rid:
            continue
        db.execute("INSERT INTO decided (request_id, decision) VALUES (?,?)"
                   " ON CONFLICT(request_id) DO UPDATE SET decision=excluded.decision",
                   (rid, str(r.get("decision") or r.get("status") or "decided")))
        n += 1
    db.commit()
    return n


def claim_key(user_id: Any, track_id: Any, roles: Sequence[str] | None) -> str | None:
    """The precedent key: the CLAIMANT plus the claim (track and exact role set).

    Precedent means "this claimant was already approved for this claim", never "this
    track+role class is legitimate". A key without the claimant would let one account's
    approval approve every other account's identical claim, which is an authorization
    bug, not a shortcut. A row missing the claimant, the track or the roles cannot
    produce a key and is not matched on precedent at all; it falls to the
    verdict/expiry/ask rules on its own merits.
    """
    uid = str(user_id or "").strip()
    track = str(track_id or "").strip().lower()
    fams = sorted({str(r).strip().lower() for r in (roles or ()) if str(r).strip()})
    if not uid or not track or not fams:
        return None
    raw = uid + "\x00" + track + "\x00" + "\x00".join(fams)
    return "claim:" + hashlib.sha256(raw.encode("utf-8")).hexdigest()[:32]


def load_precedent(db: sqlite3.Connection, rows: Iterable[dict[str, Any]]) -> int:
    n = 0
    for r in rows:
        key = str(r.get("precedent_key") or r.get("key") or "")
        if not key:
            continue
        db.execute("INSERT INTO precedent (precedent_key, outcome, request_id) VALUES (?,?,?)"
                   " ON CONFLICT(precedent_key) DO UPDATE SET outcome=excluded.outcome,"
                   " request_id=excluded.request_id",
                   (key, str(r.get("outcome") or ""),
                    r.get("request_id") or r.get("precedent_request_id")))
        n += 1
    db.commit()
    return n


# ── the ladder ──────────────────────────────────────────────────────────────

#: The rank-order ladder as ONE SQL statement. Every rule is a predicate; the CASE stops
#: at the first match, which is the plan's "stop at the first match" made mechanical.
#: `:now` is the only parameter, and it is passed in - never read from the clock here -
#: so a plan is reproducible from (snapshot, now). The one interpolation is the ask window,
#: a module constant rather than a parameter so the SQL cannot be shaped by input.
LADDER_SQL = """
SELECT
  r.request_id,
  r.profile_id,
  r.user_id,
  r.status,
  r.expires_at,
  r.proof_verdict,
  CASE
    -- ``duplicate_kind`` without ``duplicate_of`` is a duplicate fact that names no
    -- request (core's map of credits already on the profile). It still takes rank 1: it
    -- must not slide down to an ask.
    WHEN r.duplicate_of IS NOT NULL OR r.duplicate_kind IS NOT NULL THEN 'duplicate'
    WHEN p.precedent_key IS NOT NULL THEN 'precedent'
    WHEN r.proof_verdict IS NOT NULL THEN 'proof_verdict'
    -- Expiry may only refuse a request we actually ASKED. A never-asked request falls
    -- through to 'ask' (rule 5, "ask, once"): refusing a customer we never asked is a
    -- customer-facing denial we do not do. The 23,247 OPEN_UNASKED rows are the drain's
    -- population, not its refuse pile.
    --
    -- The window runs from the ASK, not from creation. Derived from `created_at`, a
    -- request created in January and asked yesterday would be expired today - one day
    -- after the customer was asked for documents, which is not a window at all (QA review
    -- 3 of hydra#1883).
    WHEN r.asked_at IS NOT NULL
         AND datetime(r.asked_at, '+{window} days') <= datetime(:now)
         AND r.proof_received_at IS NULL THEN 'expired'
    ELSE 'ask'
  END AS rule,
  d.decision AS duplicate_decision,
  r.duplicate_of,
  p.outcome  AS precedent_outcome,
  p.request_id AS precedent_request_id,
  r.proof_id,
  r.duplicate_kind,
  r.proof_received_at
FROM requests r
LEFT JOIN decided   d ON d.request_id = r.duplicate_of
LEFT JOIN precedent p ON p.precedent_key = r.precedent_key
WHERE r.status IN ('user_verification_needed', 'unverified')
ORDER BY r.request_id
""".format(window=int(ASK_WINDOW_DAYS))



@dataclasses.dataclass(frozen=True)
class Decision:
    request_id: str
    rule: str
    outcome: str
    reason_code: str
    decision_key: str
    profile_id: str | None = None
    user_id: int | None = None
    status: str | None = None
    expires_at: str | None = None
    proof_verdict: str | None = None
    #: The row-specific evidence an approve cites (a precedent request id or a proof id).
    #: ``None`` on a row the ladder wanted to approve means the row is not auto-approvable.
    evidence_anchor: str | None = None
    #: For a duplicate close: the already-decided request this row duplicates. The close
    #: is only autonomous because that original decision stands, so the ledger row and
    #: the audit trail both name it.
    duplicate_of: str | None = None

    def as_row(self) -> dict[str, Any]:
        """The canonical plan row. Sorted keys, no clock, no run id -> byte-identical."""
        return {
            "decision_key": self.decision_key,
            "duplicate_of": self.duplicate_of,
            "evidence_anchor": self.evidence_anchor,
            "expires_at": self.expires_at,
            "outcome": self.outcome,
            "profile_id": self.profile_id,
            "proof_verdict": self.proof_verdict,
            "reason_code": self.reason_code,
            "request_id": self.request_id,
            "rule": self.rule,
            "status": self.status,
            "user_id": self.user_id,
        }


def _resolve(rule: str, proof_verdict: str | None,
             precedent_outcome: str | None = None,
             evidence_anchor: str | None = None,
             duplicate_decision: str | None = None,
             duplicate_kind: str | None = None,
             proof_received_at: str | None = None) -> tuple[str, str]:
    """(outcome, reason_code) for a matched rule.

    A precedent carries its own outcome: a ``refuse`` precedent queues the row for a
    named tier-2 approver, never an autonomous reject. The ladder selects the row; this
    function is what makes the row's verdict binding.

    An APPROVE must cite a row-specific anchor (the precedent request, or the proof).
    The wrapper's approve gate checks that anchor, so a row that cannot produce one is
    not auto-approvable: it falls through to ``ask`` with ``no_evidence_anchor`` rather
    than approving on a rule name alone. A REFUSE needs no anchor - the approve gate is
    the gate that exists, and refusing is not the direction that needs evidence.
    """
    if rule == "duplicate":
        if duplicate_kind == DUP_PROFILE_CREDIT:
            return UNMATCHED, REASON_CODES["already_on_profile"]
        if not (duplicate_decision or "").strip():
            return UNMATCHED, REASON_CODES["unmatched_duplicate"]
        return OUTCOME_OF["duplicate"], REASON_CODES["duplicate"]
    if rule == "precedent":
        outcome = (precedent_outcome or "").strip().lower()
        if outcome == "refuse":
            return "queue_tier2", REASON_CODES["precedent_refuse"]
        if outcome == "approve":
            if not evidence_anchor:
                return UNMATCHED, REASON_CODES["unmatched_precedent"]
            return "approve", REASON_CODES["precedent"]
        return UNMATCHED, REASON_CODES["unmatched_precedent"]
    if rule == "proof_verdict":
        verdict = (proof_verdict or "").strip().lower()
        if verdict == "approve":
            if not evidence_anchor:
                return UNMATCHED, REASON_CODES["unmatched_proof_verdict"]
            return "approve", REASON_CODES["proof_verdict_approve"]
        if verdict == "refuse":
            # A refusal is a customer-facing denial. Queue it for a tier-2 approver
            # rather than rejecting autonomously; the reason code still names why.
            return "queue_tier2", REASON_CODES["proof_verdict_refuse"]
        return UNMATCHED, REASON_CODES["unmatched_proof_verdict"]
    if rule == "ask" and (proof_received_at or "").strip():
        return "ask", REASON_CODES["proof_on_file_undecided"]
    return OUTCOME_OF[rule], REASON_CODES[rule]


def plan(db: sqlite3.Connection, *, now: datetime | None = None) -> list[Decision]:
    """Run the ladder and return the decisions, sorted by request_id.

    Read-only. Safe to run 32 wide (plan, change 4). The returned order is the canonical
    order, so the serialized plan is byte-identical across runs.
    """
    stamp = utc(now)
    out: list[Decision] = []
    for (rid, profile_id, user_id, _status, expires_at, proof_verdict,
         rule, duplicate_decision, duplicate_of, precedent_outcome, precedent_request_id,
         proof_id, duplicate_kind, proof_received_at) in db.execute(LADDER_SQL, {"now": stamp}):
        anchor = precedent_request_id if rule == "precedent" else (
            proof_id if rule == "proof_verdict" else None)
        outcome, reason = _resolve(rule, proof_verdict, precedent_outcome, anchor,
                                   duplicate_decision, duplicate_kind, proof_received_at)
        out.append(Decision(
            request_id=rid,
            rule=rule,
            outcome=outcome,
            reason_code=reason,
            decision_key=decision_key(rid, rule, outcome),
            profile_id=profile_id,
            user_id=user_id,
            status=_status,
            expires_at=expires_at,
            proof_verdict=proof_verdict,
            evidence_anchor=anchor,
            duplicate_of=duplicate_of if rule == "duplicate" else None,
        ))
    out.sort(key=lambda d: d.request_id)
    return out


def serialize(decisions: Sequence[Decision]) -> bytes:
    """Canonical JSONL: one row per decision, sorted by request_id, sorted keys.

    No timestamp, no run id, no shard number - nothing that changes between two runs over
    the same snapshot. This is what makes "run it twice, diff the bytes" a real test.
    """
    lines = [json.dumps(d.as_row(), sort_keys=True, separators=(",", ":"), ensure_ascii=False)
             for d in sorted(decisions, key=lambda d: d.request_id)]
    return ("\n".join(lines) + ("\n" if lines else "")).encode("utf-8")


def parse_plan(data: bytes | str) -> list[Decision]:
    text = data.decode("utf-8") if isinstance(data, bytes) else data
    out: list[Decision] = []
    for line in text.splitlines():
        if not line.strip():
            continue
        row = json.loads(line)
        out.append(Decision(
            request_id=row["request_id"], rule=row["rule"], outcome=row["outcome"],
            reason_code=row["reason_code"], decision_key=row["decision_key"],
            profile_id=row.get("profile_id"), user_id=row.get("user_id"),
            status=row.get("status"), expires_at=row.get("expires_at"),
            proof_verdict=row.get("proof_verdict"),
            evidence_anchor=row.get("evidence_anchor"),
            duplicate_of=row.get("duplicate_of")))
    return out


# ── the apply ledger ────────────────────────────────────────────────────────

#: The ledger a real apply writes. Chaos refuses this path outright: it commits writing
#: outcomes with no writer, so a rehearsal here would mark rows applied that were never
#: written and the next real run would skip them.
DEFAULT_LEDGER = "/var/lib/hydra/credit-review/drain.sqlite"

LEDGER_SCHEMA = """
CREATE TABLE IF NOT EXISTS applied (
  decision_key TEXT PRIMARY KEY,     -- the idempotency key: a re-run cannot double-apply
  request_id   TEXT NOT NULL,
  rule         TEXT NOT NULL,
  outcome      TEXT NOT NULL,
  reason_code  TEXT NOT NULL,
  shard        INTEGER NOT NULL,
  applied_at   TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS applied_req ON applied(request_id);
CREATE INDEX IF NOT EXISTS applied_shard ON applied(shard, decision_key);
CREATE TABLE IF NOT EXISTS told (
  request_id  TEXT NOT NULL,         -- a refusal is told to the user ONCE
  reason_code TEXT NOT NULL,
  told_at     TEXT NOT NULL,
  PRIMARY KEY (request_id, reason_code)
);
CREATE TRIGGER IF NOT EXISTS applied_no_update BEFORE UPDATE ON applied
BEGIN SELECT RAISE(ABORT, 'applied is append-only'); END;
CREATE TRIGGER IF NOT EXISTS applied_no_delete BEFORE DELETE ON applied
BEGIN SELECT RAISE(ABORT, 'applied is append-only'); END;
CREATE TRIGGER IF NOT EXISTS told_no_update BEFORE UPDATE ON told
BEGIN SELECT RAISE(ABORT, 'told is append-only'); END;
CREATE TRIGGER IF NOT EXISTS told_no_delete BEFORE DELETE ON told
BEGIN SELECT RAISE(ABORT, 'told is append-only'); END;
CREATE TABLE IF NOT EXISTS intents (
  decision_key TEXT PRIMARY KEY,     -- one intent per decision, ever
  request_id   TEXT NOT NULL,
  rule         TEXT NOT NULL,
  outcome      TEXT NOT NULL,
  reason_code  TEXT NOT NULL,
  shard        INTEGER NOT NULL,
  planned_at   TEXT NOT NULL,        -- committed BEFORE the API call is made
  state        TEXT NOT NULL DEFAULT 'planned'
               CHECK (state IN ('planned', 'confirmed', 'abandoned')),
  resolution   TEXT,                 -- written | reconciled | <abandon reason code>
  resolved_at  TEXT,
  CHECK ((state = 'planned') = (resolution IS NULL)),
  CHECK ((state = 'planned') = (resolved_at IS NULL))
);
CREATE INDEX IF NOT EXISTS intents_state ON intents(state);
CREATE TRIGGER IF NOT EXISTS intents_no_delete BEFORE DELETE ON intents
BEGIN SELECT RAISE(ABORT, 'an intent is never deleted'); END;
CREATE TRIGGER IF NOT EXISTS intents_resolved_once BEFORE UPDATE ON intents
WHEN OLD.state <> 'planned' OR NEW.state = 'planned'
  OR NEW.decision_key IS NOT OLD.decision_key OR NEW.request_id IS NOT OLD.request_id
  OR NEW.rule IS NOT OLD.rule OR NEW.outcome IS NOT OLD.outcome
  OR NEW.reason_code IS NOT OLD.reason_code OR NEW.shard IS NOT OLD.shard
  OR NEW.planned_at IS NOT OLD.planned_at
BEGIN SELECT RAISE(ABORT, 'an intent is resolved once, and only its resolution changes'); END;
CREATE TRIGGER IF NOT EXISTS intents_confirmed_is_applied BEFORE UPDATE ON intents
WHEN NEW.state = 'confirmed'
  AND NOT EXISTS (SELECT 1 FROM applied WHERE decision_key = NEW.decision_key)
BEGIN SELECT RAISE(ABORT, 'a confirmed intent needs its applied row'); END;
"""

#: Intent states. ``planned`` is the write-ahead row: it says what the drain was about to
#: do, and it is on disk before the API hears about it. It ends exactly once, as
#: ``confirmed`` (the side effect is known to have happened; an ``applied`` row exists)
#: or ``abandoned`` (it is known this decision did not and will not happen, with why).
PLANNED, CONFIRMED, ABANDONED = "planned", "confirmed", "abandoned"

#: How a confirmed intent was confirmed. ``written``: this process made the API call and
#: read the backend naming the row. ``reconciled``: an earlier process recorded the intent
#: and never confirmed it, and the live request was found in the status it was going to
#: set. The second is an inference, and the ledger keeps it apart from the first.
WRITTEN, RECONCILED = "written", "reconciled"


def open_ledger(path: str) -> sqlite3.Connection:
    # check_same_thread=False: the write pool is a thread pool, and every DB access is
    # serialised by the caller's lock. Without this, sqlite3 raises ProgrammingError on
    # the first worker thread and the whole apply silently counts errors instead of rows.
    db = sqlite3.connect(path, timeout=30, isolation_level=None, check_same_thread=False)
    db.execute("PRAGMA journal_mode=WAL")
    db.execute("PRAGMA synchronous=FULL")   # a kill -9 must not lose a committed row
    db.executescript(LEDGER_SCHEMA)
    return db


def already_applied(db: sqlite3.Connection, keys: Iterable[str]) -> set[str]:
    keys = list(keys)
    out: set[str] = set()
    for i in range(0, len(keys), 500):
        chunk = keys[i:i + 500]
        marks = ",".join("?" * len(chunk))
        out |= {r[0] for r in db.execute(f"SELECT decision_key FROM applied WHERE decision_key IN ({marks})", chunk)}
    return out


def _commit(db: sqlite3.Connection, d: Decision, shard: int, now: datetime) -> bool:
    """Commit one decision. Returns False when the key was already applied.

    The INSERT is the idempotency proof: ``decision_key`` is the primary key, so a second
    attempt is a no-op rather than a second send.
    """
    stamp = utc(now)
    try:
        db.execute("BEGIN IMMEDIATE")
        db.execute("INSERT INTO applied (decision_key, request_id, rule, outcome, reason_code, shard, applied_at)"
                   " VALUES (?,?,?,?,?,?,?)",
                   (d.decision_key, d.request_id, d.rule, d.outcome, d.reason_code, shard, stamp))
        db.execute("COMMIT")
        return True
    except sqlite3.IntegrityError as exc:
        db.execute("ROLLBACK")
        # ONLY a duplicate decision_key means "already applied". Any other constraint
        # failure (a NOT NULL, a CHECK, a foreign key) is a real bug and must not be
        # laundered into a silent skip - that is how a broken row disappears from a drain.
        if "applied.decision_key" in str(exc) or "UNIQUE" in str(exc).upper():
            return False
        raise
    except BaseException:
        try:
            db.execute("ROLLBACK")
        except sqlite3.Error:
            pass
        raise


def _stamp_precise(ts: datetime) -> str:
    """``planned_at`` keeps its microseconds: it is compared with the backend's clock."""
    return ts.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%fZ")


def intent_of(db: sqlite3.Connection, decision_key: str) -> tuple[str, str, str | None] | None:
    """``(state, planned_at, resolution)`` for a decision, or None if none was recorded."""
    row = db.execute("SELECT state, planned_at, resolution FROM intents WHERE decision_key = ?",
                     (decision_key,)).fetchone()
    return (row[0], row[1], row[2]) if row else None


def _record_intent(db: sqlite3.Connection, d: Decision, shard: int, at: datetime) -> str:
    """Step 1 of a write: say what is about to happen, durably, BEFORE it happens.

    Its own transaction, on a ``synchronous=FULL`` connection, so the row is on disk when
    this returns. If it cannot be written the caller makes no API call: a side effect the
    ledger never heard about is the one state that cannot be recovered from.
    """
    planned_at = _stamp_precise(at)
    try:
        db.execute("BEGIN IMMEDIATE")
        db.execute("INSERT INTO intents (decision_key, request_id, rule, outcome, reason_code,"
                   " shard, planned_at) VALUES (?,?,?,?,?,?,?)",
                   (d.decision_key, d.request_id, d.rule, d.outcome, d.reason_code, shard,
                    planned_at))
        db.execute("COMMIT")
    except BaseException:
        try:
            db.execute("ROLLBACK")
        except sqlite3.Error:
            pass
        raise
    return planned_at


def _confirm_intent(db: sqlite3.Connection, d: Decision, shard: int, now: datetime,
                    how: str) -> bool:
    """Step 3: the side effect is known to have happened. ONE transaction.

    The ``applied`` row and the intent's ``confirmed`` are the same fact and commit
    together, so there is no instant at which one says done and the other does not.
    Returns False when the key was already applied.
    """
    stamp = utc(now)
    try:
        db.execute("BEGIN IMMEDIATE")
        if db.execute("SELECT 1 FROM applied WHERE decision_key = ?",
                      (d.decision_key,)).fetchone():
            db.execute("ROLLBACK")
            return False
        db.execute("INSERT INTO applied (decision_key, request_id, rule, outcome, reason_code, shard, applied_at)"
                   " VALUES (?,?,?,?,?,?,?)",
                   (d.decision_key, d.request_id, d.rule, d.outcome, d.reason_code, shard, stamp))
        changed = db.execute(
            "UPDATE intents SET state = ?, resolution = ?, resolved_at = ?"
            " WHERE decision_key = ? AND state = ?",
            (CONFIRMED, how, stamp, d.decision_key, PLANNED)).rowcount
        if changed != 1:
            raise DrainError(f"{d.request_id}: no open intent to confirm; refusing to record "
                             "a write the ledger was never told to expect")
        db.execute("COMMIT")
        return True
    except BaseException:
        try:
            db.execute("ROLLBACK")
        except sqlite3.Error:
            pass
        raise


def _abandon_intent(db: sqlite3.Connection, d: Decision, now: datetime, reason_code: str) -> None:
    """The decision did not happen and will not: record why, and write no ``applied`` row."""
    try:
        db.execute("BEGIN IMMEDIATE")
        changed = db.execute(
            "UPDATE intents SET state = ?, resolution = ?, resolved_at = ?"
            " WHERE decision_key = ? AND state = ?",
            (ABANDONED, reason_code, utc(now), d.decision_key, PLANNED)).rowcount
        if changed != 1:
            raise DrainError(f"{d.request_id}: no open intent to abandon")
        db.execute("COMMIT")
    except BaseException:
        try:
            db.execute("ROLLBACK")
        except sqlite3.Error:
            pass
        raise


def mark_told(db: sqlite3.Connection, request_id: str, reason_code: str, now: datetime | None = None) -> bool:
    """Record that a refusal was told to the user. True the first time, False after.

    "A refusal names the reason code, and the user is told once" - the primary key is the
    once. A second attempt is a no-op, so a re-run cannot re-tell.
    """
    try:
        db.execute("INSERT INTO told (request_id, reason_code, told_at) VALUES (?,?,?)",
                   (request_id, reason_code, utc(now)))
        return True
    except sqlite3.IntegrityError:
        return False


# ── the apply ───────────────────────────────────────────────────────────────

#: A writer performs the real side effect for one decision. It is injected so the engine
#: stays testable and so the production writer is the reviewed path, not a second one.
Writer = Callable[[Decision], None]

#: A reconciler answers, for an intent that was recorded and never confirmed, whether the
#: write landed: ``LANDED`` (the live request holds the status this decision sets, and the
#: evidence says the decision made it), ``NOT_LANDED`` (still pending - retry), or it
#: raises ``Abandon`` (decided, and not by this decision). Any other exception means the
#: live request could not be read; the intent stays open and NOTHING is written.
Reconciler = Callable[["Decision", str], str]
LANDED, NOT_LANDED = "landed", "not_landed"


class Abandon(DrainError):
    """An open intent whose decision did not happen and must not be retried."""

    def __init__(self, reason_code: str, message: str = ""):
        super().__init__(message or reason_code)
        self.reason_code = reason_code

#: The reviewed write path. ``muso-admin-api.sh`` already exposes exactly one way to move
#: a credit request's status, and the lobster MVP pipeline already uses it for autonomous
#: approves: a chunked ``PUT /admin/credit-requests {"requestIds":[...],"status":...}``
#: through the wrapper, with the approve gate's evidence requirement satisfied by a
#: signal digest (``lobster-signal:...``). The drain uses the SAME verb, the SAME wrapper
#: and the SAME gate treatment - it does not invent an endpoint and does not speak HTTP
#: directly, because a direct client would bypass the approve/reject/removal/tier-2/pace/
#: merge-reverse/enrich-link/bulk-destructive gates.
ADMIN_WRITER_SCRIPT = "/opt/hydra/workspaces/operations/skills/muso-ops-admin/scripts/muso-admin-api.sh"

#: The token BOTH drain writes must present - an approval and a duplicate close. It is the
#: drain's execution identity: the wrapper refuses a file that is not mode 600 owned by
#: the drain's own user, and refuses a token that does not match. It raises the bar to
#: "can read that file" and is not claimed to be non-forgeable; an approval is ALSO gated
#: on its verified per-row anchor, a close on its verified original.
#:
#: The path is FIXED, here and in the wrapper. It used to be overridable with
#: ``SCALE_DRAIN_TOKEN_FILE``, which let a caller name a file it had just written and
#: present its contents back - an identity the caller invents is not one (QA review 4 of
#: hydra#1883). The variable is now a tripwire on both sides: set, the write is refused.
DRAIN_TOKEN_FILE = "/etc/hydra/scale-drain.token"
DRAIN_TOKEN_FILE_ENV = "SCALE_DRAIN_TOKEN_FILE"

#: outcome -> the status the reviewed path writes. ``ask`` is not a write: it is a send,
#: and the send belongs to ``need_asks.py`` (the one reviewed ask path). ``queue_tier2``
#: is not a write either: a refusal is a customer-facing denial and belongs to a named
#: tier-2 approver, so the drain only records it.
WRITE_STATUS = {"approve": "approved", "close_duplicate": "rejected"}

#: The duplicate-close route. A close is a reject at the API, but it is NOT the reject
#: gate's business: deduplication is not a new decision, the original decision stands and
#: the customer's outcome is unchanged. It goes through the conditional-status route with
#: the original request named in the evidence, so the wrapper can prove the row it closes
#: points at a decided original before it writes.
DUPLICATE_CLOSE_PATH = "/admin/credit-requests/conditional-status"


def duplicate_evidence(d: Decision) -> str:
    """The digest the duplicate-close predicate CHECKS.

    ``drain-dup:<original request id>;<reason>;v<version>;<profile>``. The original is the
    whole justification for closing without a human: it is the decision that already
    stands. The trailing profile id is what lets the wrapper VERIFY that claim - it fetches
    that profile's requests in one GET and checks the original is decided and matches this
    request on claimant, track and roles. Without it the digest only asserted a duplicate
    (QA review 2 of hydra#1883).
    """
    return (f"drain-dup:{d.duplicate_of};{d.reason_code};v{RULE_VERSION};"
            f"{d.profile_id or '-'}")


def drain_evidence(d: Decision) -> str:
    """The signal digest the approve gate CHECKS for a drain decision.

    Same shape as the lobster pipeline's ``lobster-signal:...``: a short, literal,
    machine-generated statement of WHY this row was approved, carrying the row-specific
    anchor (the precedent request id, or the proof id). It is not browser evidence and
    does not pretend to be - it names the rule that fired and the row it fired on, which
    is what a reviewer needs to audit an autonomous approve.

    The wrapper's ``is_scale_drain_approval`` parses this string and refuses anything that
    is not ``drain-signal:<auto-approvable rule>;<reason>;v<version>;<anchor>;<profile>``.
    The gate is therefore doing real work on the evidence, not skipping it.

    The trailing profile id is what makes the anchor VERIFIABLE rather than merely
    well-formed: the wrapper hands the parts to ``credit_review.verify_anchor``, which
    fetches that profile's requests in one GET and checks the anchor is approved and
    matches this request on claimant, track and roles. A caller can forge the digest but
    cannot make the admin API report an approval that does not exist (QA review of
    hydra#1883, 2026-11-11).
    """
    return (f"drain-signal:{d.rule};{d.reason_code};v{RULE_VERSION};"
            f"{d.evidence_anchor};{d.profile_id or '-'}")


def admin_writer(script: str | None = None, *, timeout: int = 120,
                 runner: Callable[..., Any] | None = None,
                 token_file: str = DRAIN_TOKEN_FILE) -> Writer:
    """The production writer: one reviewed ``PUT /admin/credit-requests`` per decision.

    ``ask`` decisions perform no write and return immediately - the drain decides WHO is
    asked, and ``need_asks.py`` owns the send. Every other outcome moves the request's
    status through the wrapper, so the full gate chain still runs.

    A non-2xx response raises ``DrainWriteError``; ``apply`` counts it and does NOT confirm
    the row. The intent ``apply`` recorded before calling this stays open, and the next
    run settles it against the live request before anything is written again - a failure
    here does not prove the write did not land (a timeout is the obvious case).

    ``token_file`` is an argument so a unit test can hand the writer a scratch file. It is
    never read from the environment, and the CLI does not expose it.
    """
    script = script or os.environ.get("CREDIT_REVIEW_ADMIN_SCRIPT", ADMIN_WRITER_SCRIPT)
    run = runner or subprocess.run

    def present_token(d: Decision, env: dict[str, str], what: str) -> None:
        """Put the drain's execution identity in ``env``, for BOTH writes.

        The wrapper gates an approval and a duplicate close alike on the token file. It
        raises the bar to "can read that file"; it is not non-forgeable and is not claimed
        to be (captain decision, 2026-11-11). The per-row control is the verified anchor.
        """
        if DRAIN_TOKEN_FILE_ENV in os.environ:
            # Refused, not ignored. The wrapper refuses it too (the variable reaches it
            # through ``env``); saying so here names the cause before a process is spawned.
            raise DrainWriteError(
                f"{d.request_id}: {DRAIN_TOKEN_FILE_ENV} is set, but the token path "
                f"is pinned to {DRAIN_TOKEN_FILE} and cannot be redirected")
        try:
            with open(token_file, encoding="utf-8") as fh:
                env["SCALE_DRAIN_TOKEN"] = fh.read().strip()
        except OSError as exc:
            raise DrainWriteError(
                f"{d.request_id}: {what} needs {token_file}: {exc}") from exc

    def write(d: Decision) -> None:
        status = WRITE_STATUS.get(d.outcome)
        if status is None:
            return  # ask / queue_tier2: not a drain write
        env = dict(os.environ)
        env.pop("CV_APPROVE_GATE_DISABLED", None)
        env["OPS_DRY_RUN"] = "0"
        argv = ["bash", script]
        if d.outcome == "close_duplicate":
            if not d.duplicate_of:
                # The ladder only reaches 'duplicate' when the original is decided, so a
                # missing original means a hand-edited plan. Refuse rather than close a
                # row we cannot point at a standing decision for.
                raise DrainWriteError(
                    f"{d.request_id}: duplicate close with no decided original")
            if d.status not in PENDING_STATUSES:
                raise DrainWriteError(
                    f"{d.request_id}: duplicate close with unknown expected status {d.status!r}")
            evidence = duplicate_evidence(d)
            env["SCALE_DRAIN"] = "1"
            env["EVIDENCE_EXCERPT"] = evidence
            present_token(d, env, "duplicate close")
            body = json.dumps({"expectedStatus": d.status,
                               "requestIds": [d.request_id],
                               "status": "rejected"}, sort_keys=True)
            argv += ["--evidence-excerpt", evidence, "--requester", SERVICE_REQUESTER,
                     "call", "PUT", DUPLICATE_CLOSE_PATH, body]
            proc = run(argv, capture_output=True, text=True, timeout=timeout, env=env,
                       check=False)
            if proc.returncode != 0:
                raise DrainWriteError(
                    f"{d.request_id}: wrapper rc={proc.returncode}: "
                    f"{(proc.stderr or proc.stdout).strip()[:300]}")
            _assert_written(d, proc.stdout)
            return
        body = json.dumps({"requestIds": [d.request_id], "status": status}, sort_keys=True)
        if status == "approved":
            if d.rule not in AUTO_APPROVABLE_RULES or not d.evidence_anchor:
                # Belt and braces: the ladder already downgrades these to ask, so reaching
                # here means a plan file was hand-edited. Refuse rather than approve blind.
                raise DrainWriteError(
                    f"{d.request_id}: rule {d.rule!r} with anchor {d.evidence_anchor!r} "
                    "is not auto-approvable")
            evidence = drain_evidence(d)
            # The drain's OWN registered predicate in the wrapper, NOT the blanket
            # CV_APPROVE_GATE_DISABLED bypass. That variable skips every evidence
            # requirement and must not be set by an agent; this one admits exactly one
            # caller (this requester, this env flag, this registry entry, this digest
            # shape) and the gate parses the digest before returning 0.
            env["SCALE_DRAIN"] = "1"
            env["EVIDENCE_EXCERPT"] = evidence
            present_token(d, env, "approve")
            argv += ["--evidence-excerpt", evidence]
        argv += ["--requester", SERVICE_REQUESTER, "call", "PUT", "/admin/credit-requests", body]
        proc = run(argv, capture_output=True, text=True, timeout=timeout, env=env, check=False)
        if proc.returncode != 0:
            raise DrainWriteError(
                f"{d.request_id}: wrapper rc={proc.returncode}: {(proc.stderr or proc.stdout).strip()[:300]}")
        _assert_written(d, proc.stdout)

    return write


def live_reconciler(admin: Any = None) -> Reconciler:
    """The production reconciler: the verifier's read of the LIVE request.

    It reads through the same pinned admin wrapper the write gate verifies with
    (``verify_anchor.pinned_admin``), so a redirected ``CREDIT_REVIEW_ADMIN_SCRIPT`` makes
    it fail rather than answer. It performs no write. ``admin`` exists for unit tests.
    """
    from . import verify_anchor as va  # noqa: PLC0415 - only a resumed apply needs it

    def reconcile(d: Decision, planned_at: str) -> str:
        if d.outcome == "close_duplicate":
            rule, anchor = "duplicate", d.duplicate_of
        else:
            rule, anchor = d.rule, d.evidence_anchor
        if d.outcome not in WRITE_STATUS or not anchor:
            raise DrainError(f"{d.request_id}: an intent for {d.outcome!r} with anchor "
                             f"{anchor!r} is not one this drain writes")
        try:
            verdict = va.reconcile(rule, anchor, d.request_id, d.profile_id or "",
                                   planned_at=planned_at, admin=admin)
        except va.Elsewhere as exc:
            raise Abandon(exc.reason_code, str(exc)) from exc
        except (va.Refused, va.Unavailable) as exc:
            raise DrainError(f"{d.request_id}: could not reconcile: {exc}") from exc
        return LANDED if verdict == va.LANDED else NOT_LANDED

    return reconcile


def _updated_ids(envelope: dict[str, Any]) -> list[str] | None:
    """The per-row report the backend names, under ``.data`` or at the top level."""
    body = envelope.get("body")
    if isinstance(body, str):
        try:
            body = json.loads(body)
        except ValueError:
            return None
    if not isinstance(body, dict):
        return None
    inner = body.get("data") if isinstance(body.get("data"), dict) else body
    ids = inner.get("updatedIds")
    if not isinstance(ids, list):
        return None
    return [str(i).lower() for i in ids]


def _assert_written(d: Decision, stdout: str) -> None:
    """The backend's per-row report, not the HTTP code, is the proof the write landed."""
    text = (stdout or "").strip()
    if not text:
        raise DrainWriteError(f"{d.request_id}: wrapper wrote nothing")
    try:
        envelope = json.loads(text.splitlines()[-1])
    except (ValueError, IndexError) as exc:
        raise DrainWriteError(f"{d.request_id}: unreadable wrapper output: {text[:200]}") from exc
    status = envelope.get("http_status") if isinstance(envelope, dict) else None
    if not isinstance(status, int) or not 200 <= status < 300:
        raise DrainWriteError(f"{d.request_id}: wrapper reported HTTP {status}")
    updated = _updated_ids(envelope)
    if updated is None:
        raise DrainWriteError(
            f"{d.request_id}: wrapper response names no updatedIds; the write is unattributable")
    if d.request_id.lower() not in updated:
        raise DrainWriteError(
            f"{d.request_id}: backend did not name this row in updatedIds")


def apply(decisions: Sequence[Decision], db: sqlite3.Connection, *, shards: int = DEFAULT_SHARDS,
          write_pool: int = WRITE_POOL, writer: Writer | None = None,
          now: datetime | None = None, stop_after: int | None = None,
          commit_writes: bool = True, reconciler: Reconciler | None = None) -> dict[str, Any]:
    """Apply the plan through a bounded write pool, idempotently.

    The read (plan) already happened; this is the write half of change 4. ``write_pool``
    is the plan's 6-8 ceiling against the same API. Each shard is processed in order and
    each ledger step is its own transaction, so a ``kill -9`` at any point leaves whole
    rows and nothing half-written.

    A decision with an API side effect is three steps, and the ledger is first:

    1. **intent** - a ``planned`` row, committed before the API hears anything;
    2. **write** - the reviewed PUT, through the wrapper and its gate;
    3. **confirm** - the ``applied`` row and the intent's ``confirmed``, one transaction.

    A process that dies between 2 and 3 leaves an intent with no confirmation, and the
    request already moved. The next run does NOT write that row again - the gate would
    refuse a request that is no longer pending, forever (QA review 5 of hydra#1883). It
    asks ``reconciler`` what happened to the live request and records the answer: landed
    -> confirmed as ``reconciled``; still pending -> the write is retried, through the
    gate; decided some other way -> abandoned with a reason code, never overwritten;
    unreadable -> the intent stays open, an error is counted and nothing is written.
    With no reconciler an open intent is an error, not a blind retry.

    ``stop_after`` exists for the chaos test: it aborts the run after N commits, which is
    the same observable state as a kill at that point.

    ``commit_writes=False`` is the ledger-rehearsal mode: a writing outcome is reported
    as ``would_write`` and NOT committed, because the ledger means "the side effect
    happened". A committed rehearsal would make the next real run skip the row.
    """
    stamp = now or datetime.now(timezone.utc)
    clock: Callable[[], datetime] = (lambda: now) if now else (lambda: datetime.now(timezone.utc))
    ids = [d.request_id for d in decisions]
    bounds = shard_bounds(ids, shards)
    ordered = sorted(decisions, key=lambda d: d.request_id)
    by_shard: list[list[Decision]] = [ordered[s:e] for s, e in bounds]

    lock = threading.Lock()
    stats = {"applied": 0, "skipped": 0, "told": 0, "errors": 0, "would_write": 0,
             "unmatched": 0, "reconciled": 0, "abandoned": 0, "unreconciled": 0,
             "stopped": False}
    committed = [0]

    def run_shard(shard: int, items: list[Decision]) -> None:
        for d in items:
            # INTENT, WRITE, CONFIRM. The ledger hears about a side effect before the API
            # does, so there is no crash point at which a request has moved and the ledger
            # has no row saying we were about to move it. The API writer still runs
            # OUTSIDE the lock so the write pool bounds concurrent side effects; the
            # ledger is one connection, one lock, one transaction per step.
            side_effect = d.outcome in WRITING_OUTCOMES and writer is not None
            open_since: str | None = None   # planned_at of an intent an earlier run left open
            with lock:
                if stats["stopped"]:
                    return
                if stop_after is not None and committed[0] >= stop_after:
                    stats["stopped"] = True
                    return
                if d.decision_key in already_applied(db, [d.decision_key]):
                    stats["skipped"] += 1
                    continue
                if d.outcome == UNMATCHED:
                    stats["unmatched"] += 1
                    continue
                if not commit_writes and d.outcome in WRITING_OUTCOMES:
                    stats["would_write"] += 1
                    continue
                if d.outcome in WRITING_OUTCOMES:
                    try:
                        intent = intent_of(db, d.decision_key)
                        if intent is None:
                            if side_effect:
                                _record_intent(db, d, shard, clock())
                        elif intent[0] == ABANDONED:
                            stats["skipped"] += 1   # settled by an earlier run, with a reason
                            continue
                        else:
                            open_since = intent[1]
                    except sqlite3.Error:
                        # No intent on disk, so no API call: a side effect the ledger
                        # never heard about cannot be recovered from.
                        stats["errors"] += 1
                        continue
            if open_since is not None:
                # An earlier run meant to write this row and never confirmed it. Find out
                # what happened to the request BEFORE doing anything to it.
                try:
                    if reconciler is None:
                        raise DrainError(f"{d.request_id}: an unconfirmed intent and no "
                                         "reconciler to settle it")
                    verdict = reconciler(d, open_since)
                except Abandon as gone:
                    with lock:
                        try:
                            _abandon_intent(db, d, stamp, gone.reason_code)
                            stats["abandoned"] += 1
                        except (sqlite3.Error, DrainError):
                            stats["errors"] += 1
                    continue
                except Exception:  # noqa: BLE001 - unread is not a verdict: the intent stays open
                    with lock:
                        stats["errors"] += 1
                        stats["unreconciled"] += 1
                    continue
                if verdict == LANDED:
                    with lock:
                        try:
                            fresh = _confirm_intent(db, d, shard, stamp, RECONCILED)
                        except (sqlite3.Error, DrainError):
                            stats["errors"] += 1
                            continue
                        if fresh:
                            stats["applied"] += 1
                            stats["reconciled"] += 1
                            committed[0] += 1
                        else:
                            stats["skipped"] += 1
                    continue
                if verdict != NOT_LANDED or not side_effect:
                    # An answer this code does not know, or a retry with nothing to
                    # retry it with. Neither is permission to mark the row done.
                    with lock:
                        stats["errors"] += 1
                        stats["unreconciled"] += 1
                    continue
                # NOT_LANDED: the request is still pending, so the write is retried below,
                # through the gate, under the intent already on disk.
            # ``ask`` is not a write: the send belongs to need_asks.py, the one
            # reviewed ask path. Calling the writer for it would be a no-op at best.
            if side_effect:
                try:
                    writer(d)
                except Exception:  # noqa: BLE001 - a writer failure is counted, never fatal
                    with lock:
                        stats["errors"] += 1
                    continue  # no confirm: the intent stays open and the next run settles it
            with lock:
                # Re-check under the commit lock: a worker that passed the first check
                # before another worker committed could otherwise overshoot stop_after.
                # With a writer this is exactly the crash window: written, not confirmed.
                if stop_after is not None and committed[0] >= stop_after:
                    stats["stopped"] = True
                    return
                try:
                    if side_effect:
                        fresh = _confirm_intent(db, d, shard, stamp, WRITTEN)
                    else:
                        fresh = _commit(db, d, shard, stamp)
                except (sqlite3.Error, DrainError):
                    stats["errors"] += 1
                    continue
                if fresh:
                    stats["applied"] += 1
                    committed[0] += 1
                    if d.outcome == "queue_tier2" and mark_told(db, d.request_id, d.reason_code, stamp):
                        stats["told"] += 1
                else:
                    stats["skipped"] += 1

    # A bounded pool over shards. Shards are the unit of ownership, so the pool size is
    # min(write_pool, shards) - more workers than shards would only add contention.
    width = max(1, min(write_pool, len(by_shard)))
    queue = list(enumerate(by_shard))
    qlock = threading.Lock()

    def worker() -> None:
        while True:
            with qlock:
                if not queue:
                    return
                shard, items = queue.pop(0)
            run_shard(shard, items)

    threads = [threading.Thread(target=worker, daemon=True) for _ in range(width)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    stats["shards"] = len(by_shard)
    stats["write_pool"] = width
    return stats


def verify(decisions: Sequence[Decision], db: sqlite3.Connection) -> dict[str, Any]:
    """Check the ledger against the plan: every key applied exactly once, no orphans.

    "Zero duplicate sends, zero orphaned requests" made checkable. An orphan is a row in
    the ledger whose request is not in the plan (a stale write) or a plan row with no
    ledger row (an unapplied decision).

    ``unconfirmed`` lists intents recorded and never settled: the API may have been
    written and the ledger does not yet know. ``abandoned`` lists decisions the drain
    gave up on, each with its reason code.
    """
    planned = {d.decision_key: d for d in decisions if d.outcome != UNMATCHED}
    unmatched = sorted(d.request_id for d in decisions if d.outcome == UNMATCHED)
    applied = {r[0]: r[1] for r in db.execute("SELECT decision_key, request_id FROM applied")}
    # An abandoned intent is a decision that is KNOWN not to have happened, with the
    # reason on the row: it is reported, and it is not "missing". An intent still
    # ``planned`` is the opposite - a write that may have landed and was never confirmed -
    # and the ledger is not clean while one exists, whether or not this plan names it.
    abandoned = {r[0]: {"request_id": r[1], "reason": r[2]} for r in db.execute(
        "SELECT decision_key, request_id, resolution FROM intents WHERE state = ?", (ABANDONED,))}
    unconfirmed = sorted(r[0] for r in db.execute(
        "SELECT request_id FROM intents WHERE state = ?", (PLANNED,)))
    missing = sorted(set(planned) - set(applied) - set(abandoned))
    orphan = sorted(set(applied) - set(planned))
    # A request may legitimately have more than one row: a refusal queued for a tier-2
    # approver and then an approval are two different decisions. A DOUBLE-APPLY is the
    # same request applied twice for the same outcome, which is what this counts.
    dupes = [r[0] for r in db.execute(
        "SELECT request_id FROM applied GROUP BY request_id, outcome HAVING COUNT(*) > 1")]
    return {
        "planned": len(planned),
        "applied": len(applied),
        "missing": missing,
        "orphans": orphan,
        "unmatched": unmatched,
        "duplicate_request_ids": dupes,
        "unconfirmed": unconfirmed,
        "abandoned": [abandoned[k] for k in sorted(abandoned)],
        "ok": not missing and not orphan and not dupes and not unconfirmed,
    }


# ── the snapshot, from the replica ──────────────────────────────────────────

#: The bulk read comes from the CORE REPLICA, not the admin list API. The admin list
#: refuses unfiltered paging past offset 20,000 (``enforce_admin_list_bounds``), and its
#: own refusal text names the fix: "Use an updatedAt window, a filter, or Trino." 92,861
#: rows at limit=200 is page 465, so the admin API cannot enumerate the population at
#: all. The replica can, in one query, and it is the same surface the existing
#: ``uvn_status.uvn_requests`` already reads. The admin API stays the WRITE path.
SNAPSHOT_SQL = """
SELECT CAST(id AS varchar), CAST(userid AS varchar), CAST(profileid AS varchar), status,
       CAST(createdat AS varchar), json_format(CAST(verificationdata AS json)),
       json_format(CAST(metadata AS json)), CAST(trackid AS varchar), credits
FROM postgresql_core.public.credit_requests
WHERE status IN ('user_verification_needed', 'unverified') AND deletedat IS NULL
"""

#: The already-decided population. It is the ONLY source of precedent (there is no
#: precedent table in core) and of the duplicate closes' standing decisions. Read from
#: the same replica as the pending rows, so one snapshot carries both halves.
DECIDED_SQL = """
SELECT CAST(id AS varchar), status, CAST(userid AS varchar), CAST(trackid AS varchar), credits
FROM postgresql_core.public.credit_requests
WHERE status IN ('approved', 'rejected') AND deletedat IS NULL
"""

#: Proof verdicts live in the proof store, not in core's verificationData. Only a verdict
#: that is a decision is mapped: a soft or undetermined verdict is not an approval and is
#: not a refusal, so it stays unmapped and the row follows its own rules.
PROOF_VERDICT_APPROVE = ("GENUINE", "VERIFIED")
PROOF_VERDICT_REFUSE = ("FORGED_LIKELY", "INCONSISTENT")
PROOF_VERDICT_SQL = """
SELECT proof_id, request_id, verdict, created_at FROM verdicts
WHERE request_id != '' ORDER BY created_at, id
"""

#: The proof store does not key a verdict by request. It keys it by CLAIM:
#: ``<request uuid>#<Role>``, one row per role of the request (``stage2.py`` builds the
#: id as ``f"{request_id}#{role}"``, with the role ``unknown`` when the request names
#: none). All 326,611 bound rows on 2026-11-11 have that shape and none is a bare uuid,
#: so a lookup by bare request id matched nothing: the proof rule never fired and 10,559
#: pending requests with a document on file read as "no proof received".
CLAIM_SEP = "#"
NO_ROLE = "unknown"

#: When we last asked this user. Core has no such column: the ask history lives in the
#: verify ledger, and only the ASK campaigns count (a removal notice is not an ask).
#: Ask history keyed by REQUEST, not by account. Keying it by account let an old unasked
#: request be marked expired because a DIFFERENT request for the same user had been asked
#: (QA review 2 of hydra#1883). ``request_ids_json`` is the list the note actually named.
ASKED_AT_SQL = """
SELECT j.value, MAX(m.sent_at) FROM verify_messages m, json_each(m.request_ids_json) j
WHERE m.status = 'sent' AND m.sent_at IS NOT NULL
  AND m.campaign IN ({campaigns})
GROUP BY j.value
"""


def asked_at_by_request(ledger_path: str | None = None) -> dict[str, str]:
    """``{request_id: last asked at}`` from the verify ledger. Absent = never asked."""
    from . import verify_ledger  # noqa: PLC0415 - avoid a cycle at import time

    path = ledger_path or verify_ledger.DEFAULT_PATH
    if not os.path.exists(path):
        return {}
    campaigns = ",".join("'" + c.replace("'", "''") + "'" for c in verify_ledger.ASK_CAMPAIGNS)
    db = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
    try:
        return {str(rid): str(ts) for rid, ts in db.execute(ASKED_AT_SQL.format(campaigns=campaigns))}
    except sqlite3.Error:
        # An unreadable ledger is not "nobody was ever asked": that would turn every
        # asked-and-expired request into a fresh ask. Refuse instead of guessing.
        raise DrainError(f"the verify ledger {path} could not be read for ask history")
    finally:
        db.close()


def _roles(raw: Any) -> list[str]:
    """``credit_requests.credits`` as a role list (a Postgres text[] literal on the replica)."""
    from .verify_notify import pg_text_array  # noqa: PLC0415 - only snapshot needs it

    text = pg_text_array(raw)
    return [r.strip() for r in text.split(", ") if r.strip()]


def _role_key(role: Any) -> str:
    return str(role or "").strip().lower()


def proof_claims(store_path: str | None = None) -> dict[str, dict[str, tuple[str, str, str]]]:
    """``{request id: {role: (VERDICT, proof_id, created_at)}}`` - the newest verdict per CLAIM.

    The store key ``<request>#<Role>`` is split on the first ``#``; a key with no ``#`` is
    a verdict on the whole request and is filed under the role ``""``. Request ids and
    roles are lower-cased, because the replica and the store do not promise one case.

    The newest verdict per claim wins, INCLUDING a soft one: a newer ``PLAUSIBLE`` clears
    an older ``GENUINE``, because approving on evidence the current analyzer refuses to
    approve is a stale approval. A missing store means no proof was analysed yet; a store
    that exists but cannot be read is a hard error, because treating it as empty would
    turn every request with a document on file into "no proof received".
    """
    from credit_verify.proof import store as proof_store  # noqa: PLC0415 - sibling package

    path = store_path or proof_store.DEFAULT_PATH
    if not os.path.exists(path):
        return {}
    db = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
    try:
        out: dict[str, dict[str, tuple[str, str, str]]] = {}
        for proof_id, key, verdict, created in db.execute(PROOF_VERDICT_SQL):
            request_id, _, role = str(key).partition(CLAIM_SEP)
            out.setdefault(request_id.strip().lower(), {})[_role_key(role)] = (
                str(verdict or "").strip().upper(), str(proof_id or ""), str(created or ""))
        return out
    except sqlite3.Error as exc:
        raise DrainError(f"the proof store {path} could not be read for verdicts") from exc
    finally:
        db.close()


def proof_fact(claims: dict[str, tuple[str, str, str]] | None,
               claimed_roles: Sequence[str] | None = None) -> dict[str, Any]:
    """One request's proof fact from its claims: ``proof_verdict``, ``proof_id``, ``proof_received_at``.

    A request is ONE row in core and one write, so its verdict has to hold for the whole
    request:

    * **refuse** - any claim's newest verdict is a refusal. One forged role is a forged
      document; a human decides (``queue_tier2``), and the proof named is the refusing one.
    * **approve** - EVERY claim on file is an approval, they all rest on ONE proof (the
      digest carries one anchor, and the gate checks every claim against it), and every
      role the request claims is covered by its OWN claim (a verdict keyed by the bare
      request id does not stand in for a role; the gate applies the same rule against the
      live request). ``claimed_roles=None`` skips only the coverage test, for a caller
      that does not know the roles.
    * otherwise no verdict: a document is on file and it is not a decision.

    ``proof_received_at`` is set whenever any claim exists - whatever the verdict - so a
    request with a document on file can never be read as "expired with no proof".
    """
    if not claims:
        return {}
    received = max(created for _v, _p, created in claims.values()) or None
    refusing = sorted((created, proof) for verdict, proof, created in claims.values()
                      if verdict in PROOF_VERDICT_REFUSE)
    if refusing:
        return {"proof_verdict": "refuse", "proof_id": refusing[-1][1] or None,
                "proof_received_at": received}
    proofs = {proof for _v, proof, _c in claims.values()}
    approved = all(verdict in PROOF_VERDICT_APPROVE for verdict, _p, _c in claims.values())
    covered = True
    if claimed_roles is not None:
        wanted = {_role_key(r) for r in claimed_roles if _role_key(r)} or {NO_ROLE}
        covered = wanted <= (set(claims) - {""})
    if approved and covered and len(proofs) == 1 and "" not in proofs:
        return {"proof_verdict": "approve", "proof_id": next(iter(proofs)),
                "proof_received_at": received}
    return {"proof_verdict": None, "proof_id": None, "proof_received_at": received}


def proof_facts(store_path: str | None = None) -> dict[str, dict[str, Any]]:
    """``{request id: proof fact}`` for every request the store holds a claim for.

    The request-level view with no knowledge of the claimed roles (see ``proof_fact``).
    ``snapshot_from_replica`` does know them, and joins ``proof_claims`` itself.
    """
    return {rid: proof_fact(claims) for rid, claims in proof_claims(store_path).items()}


def decided_facts(query: Callable[[str], list[list[Any]]]) -> tuple[list[dict[str, Any]],
                                                                     list[dict[str, Any]]]:
    """(decided rows, precedent rows) derived from the decided population.

    No precedent key was ever recorded, so the key is the narrowest one every decided row
    can still produce: the claimant plus its track and exact claimed role set
    (``claim_key``). An approved row sets an APPROVE precedent for THAT claimant; a
    claimant+claim with no approval sets a REFUSE precedent naming the rejected request.
    A key with several approvals cites the lowest approved request id (the replica returns
    no ordering here, so the lowest id is used: the choice is stable across runs, which is
    what the byte-identical plan needs).
    """
    decided: list[dict[str, Any]] = []
    approved: dict[str, str] = {}
    rejected: dict[str, str] = {}
    for rid, status, user_id, track_id, credits in query(DECIDED_SQL):
        rid = str(rid)
        state = str(status or "").strip().lower()
        decided.append({"request_id": rid, "decision": state})
        key = claim_key(user_id, track_id, _roles(credits))
        if key is None:
            continue
        if state == "approved":
            if key not in approved or rid < approved[key]:
                approved[key] = rid
        elif state == "rejected":
            if key not in rejected or rid < rejected[key]:
                rejected[key] = rid
    precedent: list[dict[str, Any]] = []
    for key in sorted(set(approved) | set(rejected)):
        if key in approved:
            precedent.append({"precedent_key": key, "outcome": "approve",
                              "request_id": approved[key]})
        else:
            precedent.append({"precedent_key": key, "outcome": "refuse",
                              "request_id": rejected[key]})
    return decided, precedent


def snapshot_from_replica(query: Callable[[str], list[list[Any]]], *,
                          ledger_path: str | None = None,
                          proof_store_path: str | None = None) -> list[dict[str, Any]]:
    """Build snapshot rows from the core replica, joined to the real facts.

    ``query`` is ``verify_notify.trino`` (or a test double). One query for the whole
    population, one for the ask history - no per-user round trip, which is the hoist.
    Duplicate targets come from core's ``verificationData`` and are carried RAW (it is a
    map of profile credits there, not a request id - ``classify_duplicate`` reads it when
    the snapshot is loaded); precedent keys are derived from the decided population; proof
    verdicts are joined from the proof store per CLAIM (``proof_claims``), against the
    roles this request claims.
    """
    asked = asked_at_by_request(ledger_path)
    proofs = proof_claims(proof_store_path)
    rows: list[dict[str, Any]] = []
    for rid, uid, pid, status, created, vd_json, _meta, track_id, credits in query(SNAPSHOT_SQL):
        try:
            vd = json.loads(vd_json or "{}")
        except ValueError:
            vd = {}
        if not isinstance(vd, dict):
            vd = {}
        rid = str(rid)
        roles = _roles(credits)
        fact = proof_fact(proofs.get(rid.strip().lower()), roles)
        rows.append({
            "request_id": rid,
            "user_id": int(uid) if str(uid).isdigit() else None,
            "profile_id": str(pid or ""),
            "status": str(status or ""),
            "created_at": str(created or ""),
            "track_id": str(track_id or ""),
            "claimed_roles": roles,
            "duplicate_of": vd.get("duplicate_of"),
            "precedent_key": claim_key(uid, track_id, roles),
            "proof_verdict": fact.get("proof_verdict"),
            "proof_received_at": fact.get("proof_received_at"),
            "proof_id": fact.get("proof_id"),
            "asked_at": asked.get(rid),
        })
    return rows


# ── the continuous tail ─────────────────────────────────────────────────────

def tail(db: sqlite3.Connection, *, now: datetime | None = None) -> list[Decision]:
    """The continuous tail: decide whatever is still pending, on arrival.

    Same ladder, same keys, same ledger. The drain and the tail are one code path, which
    is why the tail cannot drift from the pass. The p95 target (< 1 hour from proof
    received to the user being told) is a property of how often this is called, not of
    the decision itself - the decision is microseconds.
    """
    return plan(db, now=now)


# ── CLI ─────────────────────────────────────────────────────────────────────

def _read_jsonl(path: str) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            if line.strip():
                rows.append(json.loads(line))
    return rows


def replica_snapshot_rows(query: Callable[[str], list[list[Any]]], *,
                          ledger_path: str | None = None,
                          proof_store_path: str | None = None) -> list[dict[str, Any]]:
    """The snapshot file's rows: pending requests plus the decided and precedent rows.

    One document, so the documented ``snapshot`` then ``plan --snapshot`` contract carries
    every fact the ladder needs without a second flag.
    """
    requests = snapshot_from_replica(query, ledger_path=ledger_path,
                                     proof_store_path=proof_store_path)
    decided, precedent = decided_facts(query)
    return ([{**r, "__kind": "request"} for r in requests]
            + [{**r, "__kind": "decided"} for r in decided]
            + [{**r, "__kind": "precedent"} for r in precedent])


def _split_snapshot_rows(rows: Iterable[dict[str, Any]]) -> tuple[list[dict[str, Any]],
                                                                  list[dict[str, Any]],
                                                                  list[dict[str, Any]]]:
    requests: list[dict[str, Any]] = []
    decided: list[dict[str, Any]] = []
    precedent: list[dict[str, Any]] = []
    for r in rows:
        kind = r.get("__kind")
        if kind == "decided":
            decided.append(r)
        elif kind == "precedent":
            precedent.append(r)
        else:
            requests.append(r)
    return requests, decided, precedent


def _build_snapshot(args: argparse.Namespace) -> sqlite3.Connection:
    db = open_snapshot()
    requests, decided, precedent = _split_snapshot_rows(_read_jsonl(args.snapshot))
    load_snapshot(db, requests, window_days=args.ask_window_days)
    load_decided(db, decided)
    load_precedent(db, precedent)
    if args.decided:
        load_decided(db, _read_jsonl(args.decided))
    if args.precedent:
        load_precedent(db, _read_jsonl(args.precedent))
    return db


def _cmd_plan(args: argparse.Namespace) -> int:
    db = _build_snapshot(args)
    now = parse_ts(args.now) if args.now else datetime.now(timezone.utc)
    decisions = plan(db, now=now)
    data = serialize(decisions)
    if args.out:
        Path(args.out).write_bytes(data)
    counts: dict[str, int] = {}
    outcomes: dict[str, int] = {}
    reasons: dict[str, int] = {}
    for d in decisions:
        counts[d.rule] = counts.get(d.rule, 0) + 1
        outcomes[d.outcome] = outcomes.get(d.outcome, 0) + 1
        # outcome/reason, so an `ask` that already has a document on file and an
        # `unmatched` that is already on the profile are each their own number
        key = f"{d.outcome}/{d.reason_code}"
        reasons[key] = reasons.get(key, 0) + 1
    print(json.dumps({"decisions": len(decisions), "by_rule": counts, "by_outcome": outcomes,
                      "by_reason": reasons,
                      "unmatched": outcomes.get(UNMATCHED, 0), "out": args.out,
                      "shards": args.shards, "sha256": hashlib.sha256(data).hexdigest()},
                     sort_keys=True))
    return 0


def _cmd_apply(args: argparse.Namespace) -> int:
    decisions = parse_plan(Path(args.plan).read_bytes())
    if args.dry_run:
        print(json.dumps({"dry_run": True, "decisions": len(decisions)}, sort_keys=True))
        return 0
    db = open_ledger(args.ledger)
    # The production writer is the reviewed PUT path. ``--no-write`` exists for a ledger
    # rehearsal (and for the chaos test, which must not touch the API); it is never the
    # default, because an apply that performs no side effect does not drain anything.
    writer = None if args.no_write else admin_writer(args.admin_script)
    # The reconciler settles any intent an earlier run recorded and never confirmed. It
    # is a read, through the verifier's pinned admin source; it is not optional on a real
    # apply, because without it such a row can only be retried blind or left forever.
    stats = apply(decisions, db, shards=args.shards, write_pool=args.write_pool, writer=writer,
                  commit_writes=not args.no_write,
                  reconciler=None if args.no_write else live_reconciler())
    print(json.dumps(stats, sort_keys=True))
    return 0 if stats["errors"] == 0 else 1


def _cmd_verify(args: argparse.Namespace) -> int:
    decisions = parse_plan(Path(args.plan).read_bytes())
    db = open_ledger(args.ledger)
    result = verify(decisions, db)
    print(json.dumps(result, sort_keys=True))
    return 0 if result["ok"] else 1


def _cmd_chaos(args: argparse.Namespace) -> int:
    """``kill -9`` every worker mid-pass, restart, verify zero duplicates and zero orphans.

    The kill is modelled as an abrupt stop after N commits (``stop_after``), which is the
    observable state a SIGKILL leaves: committed rows present, in-flight rows absent, no
    partial transaction. Two rounds must produce identical final state.
    """
    decisions = parse_plan(Path(args.plan).read_bytes())
    # A chaos run commits writing outcomes with NO writer, so it must never share a ledger
    # with a real apply: the ledger means "the side effect happened", and a rehearsal that
    # marks rows applied makes the next real run skip them and leaves the backlog
    # undrained. Refusing a named ledger is not enough - an EMPTY one is just as dangerous,
    # and a fresh CUSTOM path a real run is about to use is indistinguishable from a
    # scratch file - so chaos never takes a ledger at all. It makes its own, in its own
    # temporary directory, and reports where (QA review 3 of hydra#1883).
    ledger_dir = tempfile.mkdtemp(prefix="scale-drain-chaos-")
    ledger_path = os.path.join(ledger_dir, "chaos.sqlite")
    db = open_ledger(ledger_path)
    rounds: list[dict[str, Any]] = []
    for r in range(args.rounds):
        # Chaos is a ledger property, not an API one: no writer, so the test never
        # touches production while proving the idempotency and orphan invariants.
        stats = apply(decisions, db, shards=args.shards, write_pool=args.write_pool,
                      stop_after=args.kill_after)
        result = verify(decisions, db)
        rounds.append({"round": r, "stats": stats, "verify": result})
        if not result["ok"] and result["missing"]:
            # A kill leaves rows unapplied; that is expected. What must never happen is a
            # duplicate or an orphan, so only those fail the round.
            if result["orphans"] or result["duplicate_request_ids"]:
                print(json.dumps({"rounds": rounds, "ok": False}, sort_keys=True))
                return 1
    # The restart: one more pass with no kill, which is what a resumed worker does. It
    # must finish the population from the committed prefix alone - no re-plan, no reset.
    resumed = apply(decisions, db, shards=args.shards, write_pool=args.write_pool)
    final = verify(decisions, db)
    print(json.dumps({"rounds": rounds, "resumed": resumed, "final": final,
                      "ledger": ledger_path, "ok": final["ok"]}, sort_keys=True))
    return 0 if final["ok"] else 1


def _cmd_snapshot(args: argparse.Namespace) -> int:
    """Build the snapshot: the bulk read comes from the core replica, not the admin list.

    The admin list API refuses unfiltered paging past offset 20,000
    (``enforce_admin_list_bounds``), and its own refusal text names the fix: "Use an
    updatedAt window, a filter, or Trino." 92,861 rows at limit=200 is page 465, so the
    admin API cannot enumerate the population at all. The replica can, in one query, and
    it is the same surface ``uvn_status.uvn_requests`` already reads. The admin API stays
    the WRITE path (``apply``), where the gate chain matters.

    ``--source admin`` remains for a small, shallow read (a smoke test, a single page);
    it refuses to walk past the gate's offset cap rather than failing halfway.
    """
    from . import batch_admin  # noqa: PLC0415 - only the admin source needs it

    if args.source == "replica":
        from . import verify_notify  # noqa: PLC0415 - pulls the Trino client

        rows = replica_snapshot_rows(verify_notify.trino, ledger_path=args.ledger)
        decided = [r for r in rows if r.get("__kind") == "decided"]
        precedent = [r for r in rows if r.get("__kind") == "precedent"]
        stats: dict[str, Any] = {"source": "replica", "decided": len(decided),
                                 "precedent": len(precedent)}
    else:
        client = batch_admin.BatchAdmin(script=args.admin_script, pool=args.pool)
        rows = []
        page = 1
        while True:
            if (page - 1) * args.page_size > 20000:
                raise DrainError(
                    "the admin list refuses unfiltered paging past offset 20,000; "
                    "use --source replica for the full population")
            data = client.get("/admin/credit-requests",
                              {"status": ",".join(args.status), "limit": args.page_size,
                               "page": page})
            items = data.get("items") if isinstance(data, dict) else None
            if not isinstance(items, list):
                raise DrainError("credit-requests list has no items[]")
            if not items:
                break
            rows.extend(batch_admin.snapshot_rows(items))
            if len(items) < args.page_size or (args.max_rows and len(rows) >= args.max_rows):
                break
            page += 1
        stats = {"source": "admin", "pages": page, **client.stats.as_dict()}
    if args.max_rows:
        rows = rows[:args.max_rows]
    blob = "".join(json.dumps(r, sort_keys=True) + "\n" for r in rows).encode("utf-8")
    if args.out:
        Path(args.out).write_bytes(blob)
    else:
        sys.stdout.buffer.write(blob)
    print(json.dumps({"rows": len(rows), **stats}, sort_keys=True), file=sys.stderr)
    return 0


def _cmd_tier2_queue(args: argparse.Namespace) -> int:
    """Print the rows the ladder would REFUSE, for a named tier-2 approver.

    A refusal is a customer-facing denial, so the drain does not make it. These rows are
    recorded in the ledger with their reason code and nothing is written to the API; this
    command is how a human picks them up. It prints the exact wrapper invocation, with
    ``--confirmed-by`` and ``--approval-msg-id`` left as placeholders a human fills in -
    the drain never supplies them, because supplying them would be the bypass.
    """
    db = open_ledger(args.ledger)
    rows = [
        {"request_id": rid, "reason_code": reason, "queued_at": at}
        for rid, reason, at in db.execute(
            "SELECT request_id, reason_code, applied_at FROM applied"
            " WHERE outcome = 'queue_tier2' ORDER BY request_id")
    ]
    payload = "".join(json.dumps(r, sort_keys=True) + "\n" for r in rows)
    if args.out:
        Path(args.out).write_text(payload, encoding="utf-8")
    else:
        sys.stdout.write(payload)
    print(json.dumps({"queued": len(rows),
                      "command": ("bash muso-admin-api.sh --confirmed-by <tier2> "
                                  "--approval-msg-id <slack-ts> call PATCH "
                                  "/admin/credit-requests/<id> '{\"status\":\"rejected\"}'")},
          sort_keys=True), file=sys.stderr)
    return 0


def _cmd_bench(args: argparse.Namespace) -> int:
    """The one number the plan says to instrument: seconds per request, end to end."""
    db = _build_snapshot(args)
    now = datetime.now(timezone.utc)
    t0 = time.perf_counter()
    decisions = plan(db, now=now)
    elapsed = time.perf_counter() - t0
    n = max(1, len(decisions))
    print(json.dumps({"decisions": len(decisions), "seconds": round(elapsed, 6),
                      "ms_per_request": round(elapsed * 1000.0 / n, 6),
                      "requests_per_second": round(n / elapsed, 1) if elapsed else None},
                     sort_keys=True))
    return 0


def _main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = ap.add_subparsers(dest="op", required=True)

    def common(p: argparse.ArgumentParser) -> None:
        p.add_argument("--shards", type=int, default=DEFAULT_SHARDS)

    p = sub.add_parser("plan")
    p.add_argument("--snapshot", required=True, help="JSONL of request rows (batched reads)")
    p.add_argument("--decided", default=None, help="JSONL of already-decided requests")
    p.add_argument("--precedent", default=None, help="JSONL of precedent_key -> outcome")
    p.add_argument("--out", default=None)
    p.add_argument("--now", default=None, help="ISO timestamp; the only clock the plan reads")
    p.add_argument("--ask-window-days", type=int, default=ASK_WINDOW_DAYS)
    common(p)
    p.set_defaults(fn=_cmd_plan)

    p = sub.add_parser("apply")
    p.add_argument("--plan", required=True)
    p.add_argument("--ledger", default=DEFAULT_LEDGER)
    p.add_argument("--write-pool", type=int, default=WRITE_POOL)
    p.add_argument("--dry-run", action="store_true")
    p.add_argument("--no-write", action="store_true",
                   help="ledger rehearsal: report writing outcomes as would_write, commit nothing")
    p.add_argument("--admin-script", default=None, help="override the reviewed wrapper path")
    common(p)
    p.set_defaults(fn=_cmd_apply)

    p = sub.add_parser("verify")
    p.add_argument("--plan", required=True)
    p.add_argument("--ledger", default=DEFAULT_LEDGER)
    common(p)
    p.set_defaults(fn=_cmd_verify)

    p = sub.add_parser("chaos", help="scratch-ledger rehearsal; never takes your ledger")
    p.add_argument("--plan", required=True)
    p.add_argument("--kill-after", type=int, default=100)
    p.add_argument("--rounds", type=int, default=2)
    p.add_argument("--write-pool", type=int, default=WRITE_POOL)
    common(p)
    p.set_defaults(fn=_cmd_chaos)

    p = sub.add_parser("snapshot", help="build the snapshot (core replica by default)")
    p.add_argument("--out", default=None)
    p.add_argument("--source", choices=("replica", "admin"), default="replica")
    p.add_argument("--ledger", default=None, help="verify ledger, for the ask history")
    p.add_argument("--status", action="append", default=None,
                   help="pending status to include (repeatable; default the two pending ones)")
    p.add_argument("--page-size", type=int, default=200)
    p.add_argument("--max-rows", type=int, default=0)
    p.add_argument("--pool", type=int, default=8)
    p.add_argument("--admin-script", default=None)
    common(p)
    p.set_defaults(fn=_cmd_snapshot)

    p = sub.add_parser("tier2-queue",
                       help="list the rows the drain will NOT refuse: a named human decides")
    p.add_argument("--ledger", default=DEFAULT_LEDGER)
    p.add_argument("--out", default=None, help="write the queue as JSONL (default stdout)")
    common(p)
    p.set_defaults(fn=_cmd_tier2_queue)

    p = sub.add_parser("bench")
    p.add_argument("--snapshot", required=True)
    p.add_argument("--decided", default=None)
    p.add_argument("--precedent", default=None)
    p.add_argument("--ask-window-days", type=int, default=ASK_WINDOW_DAYS)
    common(p)
    p.set_defaults(fn=_cmd_bench)

    a = ap.parse_args(argv)
    if getattr(a, "status", None) is None and a.op == "snapshot":
        a.status = list(PENDING_STATUSES)
    return int(a.fn(a))


if __name__ == "__main__":
    sys.exit(_main())
