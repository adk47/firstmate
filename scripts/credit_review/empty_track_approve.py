"""ET1 coded rule `empty_track_approve`: a credit on a track that has NO credits yet has nothing to verify.

Captain, 2026-11-16 02:1xZ (verbatim): "if no credits are on a track we let those go on if it makes sense?"
- a track that exists in the catalog with a real ISRC or id, that carries ZERO credits, where the claimant's
claim has no role conflict, no watchlist hit and no R8 account hold, is approved: there is nothing to verify
because nobody is credited on it yet.

This is a SEPARATE predicate from the validator low-risk path (`score_approve.py`: popularity 1-59, total risk
under 30). It reuses none of those thresholds and moves none of them, and it never fires on a row that path
refuses for a reason OTHER than emptiness (a role conflict, a reject_* rule, an account gate that is not a
green allow, a watchlist hit, an R8 hold, a claim on the profile) - those refusals are shared predicates
(`policy.validator_conflict`, `policy.validator_rejected_rules`, `roles.family_of`, `account_gate`,
`watchlist`, `comm_state.account_hold_facts`), not thresholds.

The one condition the captain repeats is the one that must never rot: a track that already has ANY credit is
never approved by this rule, whatever else is true of the row. `test_credit_empty_track_approve.py` pins it.

WHERE "credits on the track" IS READ (and where it must not be): core's own track document,
`GET /admin/track/<id>`, is the only surface that answers it. The analytics replicas look like they do and they
do NOT: on 2026-11-16, `postgresql_stats.public.profile_track` said a track had 0 credits while core's document
listed 5, and `postgresql_core.public.profile_v3_tracks` was empty for tracks core lists 2-71 credits on (40 of 40
sampled tracks disagreed in both directions). Neither table may stand in for condition 2, in a pre-filter or
anywhere else: a rule that "filters on a replica, then approves" would approve tracks that already carry credits.
`track_credit_counts` below is therefore a MEASUREMENT of one replica, kept only so its disagreement stays
readable, and no decision path calls it.

Deterministic, no model. Every unreadable input is a HOLD, never an approve (the track document cannot be read,
its credit list is absent, the gate or the hold set cannot be read, the watchlist file is missing).

NOTHING ARMS HERE. `policies/credit-empty-track-approve.json` ships `apply_enabled: false` with no
`approved_by` / `approval_ref`, and this module wires NO approve writer at all: an apply is a separate reviewed
change (the writer is `score_approve`'s, and a second executor is exactly what AGENTS.md forbids). Until then the
rule reads, decides in shadow and records its own rows in its own ledger table.
"""
from __future__ import annotations

import csv
import hashlib
import io
import json
import os
import re
import sqlite3
import subprocess
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path
from typing import Any, Callable, Iterable

from . import account_gate, watchlist
from .anchor_push_run import page_critical
from .policy import conflict_scan, validator_conflict, validator_rejected_rules

RULE_NAME = "empty_track_approve"
RULE_ID = "ET1:empty_track_approve/v1"
EVIDENCE_KIND = RULE_NAME
#: The statuses this rule may decide. Anything else is counted, never decided.
OPEN_FROM = ("unverified", "user_verification_needed")
#: Every condition, in the order the captain stated them. A row is approved only when all of them hold.
CONDITIONS = ("track_in_catalog", "zero_credits_on_track", "no_role_conflict", "no_watchlist_hit", "no_r8_hold")
POLICY = os.environ.get("EMPTY_TRACK_APPROVE_POLICY",
                        str(Path(__file__).resolve().parents[2] / "policies" / "credit-empty-track-approve.json"))
KILL_FILES = ("/etc/hydra/empty-track-approve.disabled",)
TRINO = os.environ.get("CREDIT_TRUST_TRINO_CMD", "/opt/hydra/scripts/trino-query.sh")
#: A writer is deliberately absent (module docstring). An apply refuses with this until a reviewed change adds
#: one; the policy switch alone can never approve anything.
NO_WRITER = ("no approve writer is wired in this rule: the empty-track APPROVE path is a separate reviewed change "
             "(score_approve owns the writer, and a second executor is forbidden)")

#: An ISRC is 12 characters: a 2-letter country, a 3-character registrant, a 7-digit designation.
ISRC_RE = re.compile(r"^[A-Z]{2}[A-Z0-9]{3}[0-9]{7}$")
#: A Spotify track id is 22 characters of base62.
SPOTIFY_ID_RE = re.compile(r"^[0-9A-Za-z]{22}$")
UUID_RE = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")
#: Values an import writes where an identifier belongs. They are not identifiers, so they never satisfy
#: "a real ISRC or id" - a placeholder is exactly the case the captain excludes.
PLACEHOLDERS = frozenset({"", "none", "null", "nil", "n/a", "na", "unknown", "tbd", "todo", "0", "000000000000",
                          "0000000000000", "-", "--", "?", "xx", "isrc", "spotify", "id"})
#: Role terms that are not a person's credit at all (mirrors score_approve.ORG_ROLE_TERMS; a label, publisher,
#: distributor or studio claim is not the "emptiness" case and the low-risk path refuses it too).
ORG_ROLE_TERMS = ("record label", "label", "publisher", "publishing", "studio", "distributor",
                  "production company", "management", "a&r")


def rule_version() -> str:
    return RULE_ID + "+" + hashlib.sha256(Path(__file__).read_bytes()).hexdigest()[:12]


# ── the catalog side: what the track document says ────────────────────────────────────────────────────────────

@dataclass(frozen=True)
class TrackRecord:
    """One track as core's admin API returns it (`GET /admin/track/<id>`).

    ``credits`` is None when the document carries NO credit list at all - that is unreadable, and an unreadable
    emptiness is never an empty track. ``credits_empty`` is the only thing that says "nobody is credited".
    """
    track_id: str
    isrcs: tuple[str, ...] = ()
    spotify_ids: tuple[str, ...] = ()
    credits: int | None = None            # len(doc["credits"])
    collaborators: int | None = None      # doc["collaboratorsCount"]
    deleted: bool = False
    merged: bool = False
    moved_to: str = ""                   # the document served a DIFFERENT id: this track id was merged away

    @property
    def credits_empty(self) -> bool:
        """ZERO credits, measured: the credit list exists, is empty, and the count agrees."""
        return self.credits == 0 and self.collaborators in (0, None)


def _ints(value: Any) -> int | None:
    if isinstance(value, bool) or value is None:
        return None
    if isinstance(value, int):
        return value
    if isinstance(value, float) and value.is_integer():
        return int(value)
    return None


def real_isrc(isrcs: Iterable[str] | str | None) -> str | None:
    """The first ISRC that is a real identifier, upper-cased with its dashes removed; None when there is none.

    A single string is one identifier, not a sequence of characters: the replica carries the request's own
    `metadata.isrc` as a string, the admin track document carries a list."""
    if isinstance(isrcs, str):
        isrcs = (isrcs,)
    for raw in isrcs or ():
        v = str(raw or "").strip().upper().replace("-", "").replace(" ", "")
        if v.lower() in PLACEHOLDERS:
            continue
        if ISRC_RE.match(v):
            return v
    return None


def real_spotify_id(ids: Iterable[str] | str | None) -> str | None:
    if isinstance(ids, str):
        ids = (ids,)
    for raw in ids or ():
        v = str(raw or "").strip()
        if v.lower() in PLACEHOLDERS:
            continue
        if SPOTIFY_ID_RE.match(v):
            return v
    return None


def track_record(doc: Any, requested: str) -> TrackRecord:
    """Read one admin track document. Raises ValueError on a document it cannot place (never "not found").

    A document for a DIFFERENT id is not a failed read: core redirects a merged-away track id to its survivor, so
    the request points at an id that no longer exists. It is carried as ``moved_to`` and is a hold, never an
    approval - the credit list being empty belongs to the wrong id."""
    if not isinstance(doc, dict):
        raise ValueError("track response is not an object")
    tid = str(doc.get("id") or "").strip().lower()
    if not tid:
        raise ValueError("track document has no id")
    want = str(requested or "").strip().lower()
    moved_to = tid if want and UUID_RE.match(want) and tid != want else ""
    isrcs = doc.get("isrcs")
    isrcs = tuple(str(x) for x in isrcs) if isinstance(isrcs, list) else ()
    if isinstance(doc.get("isrc"), str):
        isrcs = isrcs + (doc["isrc"],)
    spot = doc.get("spotifyIds")
    spot = tuple(str(x) for x in spot) if isinstance(spot, list) else ()
    if isinstance(doc.get("spotifyId"), str):
        spot = spot + (doc["spotifyId"],)
    credits = doc.get("credits")
    return TrackRecord(
        track_id=tid,
        isrcs=isrcs,
        spotify_ids=spot,
        credits=len(credits) if isinstance(credits, list) else None,
        collaborators=_ints(doc.get("collaboratorsCount")),
        deleted=bool(doc.get("deleted")),
        merged=bool(doc.get("merged")),
        moved_to=moved_to,
    )


def empty_track(t: TrackRecord | None) -> str:
    """The catalog conditions for this track: '' when it is a real, empty track; otherwise why it is not.

    Both halves are required: a REAL identifier (a placeholder or a missing one is not an identity) and ZERO
    credits (any credit at all ends this rule for the track, for every request on it)."""
    if t is None:
        return "track_unread"
    if t.moved_to:
        return f"track_moved:{t.moved_to}"
    if t.deleted:
        return "track_deleted"
    if t.merged:
        return "track_merged"
    if real_isrc(t.isrcs) is None and real_spotify_id(t.spotify_ids) is None:
        return "track_identifier_placeholder"
    if t.credits is None:
        return "track_credits_unknown"
    if not t.credits_empty:
        return f"track_has_credits:{t.credits if t.credits is not None else '?'}"
    return ""


# ── the claimant side ────────────────────────────────────────────────────────────────────────────────────────

@dataclass(frozen=True)
class RequestFacts:
    """What the server says about one credit request right now (replica read; None = unread)."""
    status: str | None
    user_id: int | None
    profile_id: str | None
    track_id: str | None
    isrc: str | None
    roles: tuple[str, ...] | None    # the claim's roles; None = the column was NULL, i.e. NOT READ
    verdict: dict[str, Any] | None   # the validator's own verificationdata; None = NOT READ / not measured
    is_approved: str | None
    deleted: bool


@dataclass
class Row:
    request_id: str
    user_id: int | None
    profile_id: str | None
    track_id: str | None
    decision: str                  # approve | hold
    reason_code: str               # "" for an approve; the hold reason's head otherwise
    reason: str
    expected_status: str | None
    popularity: int | None
    paid: bool | None
    gate_state: str
    evidence: dict[str, Any] = field(default_factory=dict)


def role_conflict(roles: Iterable[str], verdict: dict[str, Any] | None) -> str:
    """No role conflict for the claimant: '' when the claim is clean, otherwise why.

    Reuses the predicates the low-risk path already refuses on - a reject_* rule that fired, a review_* hold at
    the server's hold threshold (30, never 100: a hold is a human's), the one-person trusted-source contradiction,
    and a claim that is not a person's credit at all. None of these is a popularity or risk threshold.

    A verdict we could not read is NOT a verdict that said no. A request whose verificationdata is missing, is not
    an object, has no rule_risk_percent map, or carries rule_errors[_hold_on_error] is HELD
    (`validator_rules_unread` / `validator_conflict`), never approved - read through policy.conflict_scan, whose
    `measured` flag exists for exactly this.

    The claim's own roles are the same kind of input: a NULL `credits` column is a claim whose roles we did not
    read, not a claim with no roles, so it is HELD (`roles_unread`). An empty array is a measured answer and is
    left to the validator's rules."""
    if roles is None:
        return "roles_unread"
    scan = conflict_scan(verdict)
    if scan["hold_on_error"]:
        return "validator_conflict"
    if not scan["measured"]:
        return "validator_rules_unread"
    fired = validator_rejected_rules(verdict)
    if fired:
        return "reject_rule:" + ",".join(fired)
    conflict = validator_conflict(verdict)
    if conflict:
        held = conflict.get("hold_rules") or []
        if conflict.get("class_c") or conflict.get("hold_on_error"):
            return "validator_conflict"
        return "review_hold:" + ",".join(str(x) for x in held)
    for r in roles or ():
        low = str(r or "").lower()
        if any(term in low for term in ORG_ROLE_TERMS):
            return "organization_role"
    return ""


def watch_hit(uid: int | None, profile_id: str | None, watch: Any) -> str:
    """No watchlist hit: '' when neither the account nor the profile is watchlisted.

    `watch` is the loaded `credit_review.watchlist.Watchlist`, and None means WE COULD NOT READ IT, which is never
    "nobody is watchlisted": a watchlist that stops watching the moment it cannot read itself is worse than none,
    so an unreadable one holds every row (`watchlist_unread`) and the caller pages."""
    if watch is None:
        return "watchlist_unread"
    if isinstance(uid, int) and uid in (watch.user_ids or ()):
        return "watchlist_user"
    pid = str(profile_id or "").strip().lower()
    if pid and pid in (watch.profile_ids or ()):
        return "watchlist_profile"
    return ""


def rules_of(verdict: Any) -> dict[str, Any]:
    """The rule scores of a verdict we DID read; {} for anything else (which `role_conflict` has already held)."""
    if not isinstance(verdict, dict):
        return {}
    rules = verdict.get("rule_risk_percent")
    return dict(rules) if isinstance(rules, dict) else {}


def local_clean(facts: dict[str, RequestFacts], watch: Any) -> dict[str, RequestFacts]:
    """{request id: facts} for the rows that pass conditions 3-4 locally, i.e. WITHOUT reading a track document.

    The identifier is NOT part of this filter: condition 1 lets core's own track document supply the ISRC *or* the
    Spotify id, so a request that carries no ISRC can still be a real, credit-free track and must be measured.
    An unreadable watchlist selects nothing (`watch_hit` answers `watchlist_unread`)."""
    return {rid: f for rid, f in facts.items()
            if not role_conflict(f.roles, f.verdict) and not watch_hit(f.user_id, f.profile_id, watch)}


def _user_state(uid: int | None, gate_fn: Callable[[int], Any], hold_fn: Callable[[int], list[str]]) -> tuple[str, str]:
    """(gate state, why it holds). Mirrors validator_reject_close._user_state: an unreadable gate or hold set is a
    hold, never a pass."""
    if not isinstance(uid, int):
        return "unknown", "user_unknown"
    try:
        g = gate_fn(uid)
    except Exception as exc:  # noqa: BLE001
        return "unknown", f"account_gate_unknown:{str(exc)[:60]}"
    state = "allow" if g.allowed else str(g.decision)
    if not g.allowed:
        return state, f"account_gate_{state}"
    # ONE reading of "an allow is not an approval": the shared predicate. Its allow covers an amber band (on the
    # fraud watch), a released red and a band nobody measured; only green-with-no-watch is green.
    refusal = account_gate.watch_refusal(g)
    if refusal:
        return state, f"account_not_green:{refusal[:80]}"
    try:
        if hold_fn(uid):
            return state, "R8_account_hold"
    except Exception as exc:  # noqa: BLE001
        return state, f"account_hold_unknown:{str(exc)[:60]}"
    return state, ""


def evaluate(scope: Iterable[str], facts: dict[str, RequestFacts], tracks: dict[str, TrackRecord | None],
             gate_fn: Callable[[int], Any], hold_fn: Callable[[int], list[str]],
             paid_ids: frozenset[int] | None, watch: Any = None,
             popularity: dict[str, int | None] | None = None) -> tuple[list[Row], dict[str, int]]:
    """One Row per in-scope request that is still open; the rest are counted only.

    The five conditions are checked in the captain's order and the FIRST failure is the row's reason. A gate or
    hold read is cached per user, so one broken account is one read, not one per request."""
    rows: list[Row] = []
    skipped: dict[str, int] = {}
    users: dict[int, tuple[str, str]] = {}
    pop_of = popularity or {}
    for rid in scope:
        rid = str(rid).lower()
        f = facts.get(rid)
        if f is None or f.deleted or f.status not in OPEN_FROM:
            k = "not_open:" + ("missing" if f is None else "deleted" if f.deleted else str(f.status))
            skipped[k] = skipped.get(k, 0) + 1
            continue
        uid = f.user_id
        if uid not in users:
            users[uid] = _user_state(uid, gate_fn, hold_fn)
        gate_state, user_why = users[uid]
        track = tracks.get(str(f.track_id or "").strip().lower())
        why = None
        if not f.track_id:
            why = "track_missing_on_request"
        elif (track_why := empty_track(track)):
            why = track_why
        elif (conflict := role_conflict(f.roles, f.verdict)):
            why = conflict
        elif (hit := watch_hit(uid, f.profile_id, watch)):
            why = hit
        elif user_why:
            why = user_why
        evidence = {
            "track_id": f.track_id,
            "isrc": f.isrc,
            "track_identifier": (real_isrc(track.isrcs) or real_spotify_id(track.spotify_ids)) if track else None,
            "track_credits": None if track is None else track.credits,
            "track_collaborators": None if track is None else track.collaborators,
            "roles": list(f.roles or ()),
            "rules": {k: v for k, v in rules_of(f.verdict).items()
                      if str(k).startswith(("reject_", "review_"))},
            "validator_measured": bool(conflict_scan(f.verdict)["measured"]),
            "validator_approved": f.is_approved,
            "conditions": list(CONDITIONS),
        }
        rows.append(Row(
            request_id=rid, user_id=uid, profile_id=f.profile_id, track_id=f.track_id,
            decision="hold" if why else "approve",
            reason_code=why.split(":")[0] if why else "",
            reason=why or "empty track: no credits on it, a real catalog identity, no role conflict, "
                          "no watchlist hit, no R8 hold",
            expected_status=f.status,
            popularity=pop_of.get(rid),
            paid=None if paid_ids is None or uid is None else uid in paid_ids,
            gate_state=gate_state, evidence=evidence))
    rows.sort(key=lambda r: (r.decision != "approve", r.paid is not True, r.user_id or 0, r.request_id))
    return rows, skipped


# ── the ledger: this rule's own table, and no writer ────────────────────────────────────────────────────────

SCHEMA = """
CREATE TABLE IF NOT EXISTS empty_track_decisions (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  run_id TEXT NOT NULL,
  decided_at TEXT NOT NULL,
  request_id TEXT NOT NULL,
  user_id INTEGER,
  profile_id TEXT,
  track_id TEXT,
  decision TEXT NOT NULL,
  reason_code TEXT NOT NULL,
  reason TEXT NOT NULL,
  expected_status TEXT,
  popularity INTEGER,
  paid_priority INTEGER,
  gate_state TEXT,
  mode TEXT NOT NULL,
  rule_version TEXT NOT NULL,
  evidence_json TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS empty_track_decisions_request ON empty_track_decisions (request_id, mode);
"""


def ensure_schema(db: sqlite3.Connection) -> None:
    db.executescript(SCHEMA)


def record(db: sqlite3.Connection, run_id: str, mode: str, rows: list[Row], now: datetime) -> dict[str, Any]:
    """Append this run's rows to the rule's OWN table (one transaction).

    It is not the decider's `decisions`: seven readers act on a request's newest row there, and a shadow approve
    has no business being one of them. A run never decides the same request twice, but a LATER run decides it
    again: the ledger keeps every run's answer, because de-duplicating across runs left a stale `approve` standing
    after a credit appeared on the track (the reviewer's third finding)."""
    ensure_schema(db)
    ver = rule_version()
    at = now.strftime("%Y-%m-%dT%H:%M:%SZ")
    out: dict[str, Any] = {"approve": 0, "hold": {}, "duplicate": 0}
    db.commit()
    db.execute("BEGIN IMMEDIATE")
    try:
        done = {str(r).lower() for (r,) in db.execute(
            "SELECT request_id FROM empty_track_decisions WHERE run_id = ?", (run_id,))}
        for r in rows:
            if r.request_id in done:
                out["duplicate"] += 1
                continue
            db.execute(
                "INSERT INTO empty_track_decisions (run_id, decided_at, request_id, user_id, profile_id, track_id, "
                "decision, reason_code, reason, expected_status, popularity, paid_priority, gate_state, mode, "
                "rule_version, evidence_json) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                (run_id, at, r.request_id, r.user_id, r.profile_id, r.track_id, r.decision, r.reason_code,
                 r.reason[:600], r.expected_status, r.popularity, None if r.paid is None else int(r.paid),
                 r.gate_state, mode, ver, json.dumps(r.evidence, default=str)))
            if r.decision == "approve":
                out["approve"] += 1
            else:
                out["hold"][r.reason_code] = out["hold"].get(r.reason_code, 0) + 1
            done.add(r.request_id)
        db.commit()
    except BaseException:
        db.rollback()
        raise
    return out


def policy(path: str | None = None) -> dict[str, Any]:
    try:
        return json.loads(Path(path or POLICY).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}


def apply_refusal(pol: dict[str, Any], kill_files: Iterable[str] = KILL_FILES) -> str:
    """Why this rule cannot approve right now - and it never can in this shape. Two independent stops, and the
    policy switch is only the first: with no writer in code, no policy edit alone can approve anything."""
    for k in kill_files:
        if os.path.exists(k):
            return f"kill file {k}"
    if pol.get("apply_enabled") is not True:
        return ("policy apply_enabled is not true; apply is decided by this rule's policy switch "
                "(policies/credit-empty-track-approve.json, off)")
    if not pol.get("approved_by") or not pol.get("approval_ref"):
        return "policy has no approved_by / approval_ref"
    return NO_WRITER


# ── the reads ───────────────────────────────────────────────────────────────────────────────────────────────

def _trino(sql: str, timeout: int = 600) -> list[list[str]]:
    p = subprocess.run([TRINO], input=sql, capture_output=True, text=True, timeout=timeout, check=False)
    if p.returncode != 0:
        raise RuntimeError(f"replica query failed rc={p.returncode}: {(p.stderr or p.stdout).strip()[-300:]}")
    return list(csv.reader(io.StringIO("\n".join(
        line for line in p.stdout.splitlines() if line.startswith('"')))))


def _pg_array(text: str) -> tuple[str, ...] | None:
    """`{Composer,"Primary Artist"}` -> ('Composer', 'Primary Artist'); None when it is not an array at all.

    A value that is not PostgreSQL array syntax is an UNREAD roles column, never one role named "garbled": the
    reviewer's reproduction had `_pg_array("garbled")` return `("garbled",)` and the request approve on it."""
    v = str(text or "").strip()
    if not v:
        return None
    if not (v.startswith("{") and v.endswith("}")):
        return None
    v = v[1:-1]
    if not v.strip():
        return ()
    out: list[str] = []
    buf, quoted = "", False
    for ch in v:
        if ch == '"':
            quoted = not quoted
            continue
        if ch == "," and not quoted:
            out.append(buf.strip())
            buf = ""
            continue
        buf += ch
    out.append(buf.strip())
    return tuple(x for x in out if x)


def fetch_facts(ids: Iterable[str], run: Callable[[str], list[list[str]]] | None = None) -> dict[str, RequestFacts]:
    """Fresh facts for exactly these requests. A failed read raises: the caller writes nothing."""
    ids = [i for i in (str(x).lower() for x in ids) if UUID_RE.match(i)]
    if not ids:
        return {}
    quoted = ",".join(f"'{i}'" for i in ids)
    sql = f"""select cast(cr.id as varchar), coalesce(cr.status, ''), cast(cr.userid as varchar),
  cast(cr.profileid as varchar), coalesce(cast(cr.trackid as varchar), ''),
  coalesce(json_extract_scalar(cr.metadata, '$.isrc'), ''),
  coalesce(cast(cr.credits as varchar), ''),
  coalesce(json_format(cr.verificationdata), ''),
  coalesce(json_extract_scalar(cr.verificationdata, '$.is_approved'), ''),
  cast(cr.deletedat is not null as varchar)
from postgresql_core.public.credit_requests cr
where lower(cast(cr.id as varchar)) in ({quoted})"""
    _LAST.append(sql)
    return _rows_to_facts((run or _trino)(sql))


def track_credit_counts(track_ids: Iterable[str],
                        run: Callable[[str], list[list[str]]] | None = None) -> dict[str, int]:
    """{track id: credits the analytics replica knows}, from `postgresql_stats.profile_track`.

    NOT the track's credits, and never a stand-in for condition 2: the replica covers a subset of profiles, and on
    2026-11-16 it read 0 for tracks core lists 2-20 credits on (40 of 40 sampled tracks disagreed, seen through a
    measurement, not through a decision). It is kept so that disagreement stays measurable; no decision path calls
    it. `TrackRecord.credits`, from core's own track document, is the only read of condition 2."""
    tids = sorted({str(t).strip().lower() for t in track_ids if UUID_RE.match(str(t or "").strip().lower())})
    run = run or _trino
    counts: dict[str, int] = {}
    for i in range(0, len(tids), 500):
        batch = tids[i:i + 500]
        quoted = ",".join(f"'{t}'" for t in batch)
        for rec in run(f"select pt.track_id, cast(count(*) as varchar) "
                       f"from postgresql_stats.public.profile_track pt "
                       f"where pt.track_id in ({quoted}) group by 1"):
            if len(rec) == 2 and rec[1].isdigit():
                counts[str(rec[0]).strip().lower()] = int(rec[1])
    return counts


def track_docs(admin: Any, track_ids: Iterable[str], *, pace_s: float = 0.2,
               sleep: Callable[[float], None] | None = None) -> dict[str, TrackRecord | None]:
    """{track id: TrackRecord or None (unread)} from core's admin API, one GET per track.

    Unread is None, never an empty track: a 404 does NOT prove the catalog lacks the track (core answers 404 when
    its own catalog read failed), and an unreadable document can never be the proof that nothing is credited."""
    import time as _t
    sleep = sleep or _t.sleep
    out: dict[str, TrackRecord | None] = {}
    for tid in {str(t).strip().lower() for t in track_ids if str(t or "").strip()}:
        try:
            out[tid] = track_record(admin.get(f"/admin/track/{tid}"), tid)
        except Exception:  # noqa: BLE001  (AdminError, ValueError, transport: all unread)
            out[tid] = None
        if pace_s:
            sleep(pace_s)
    return out


#: The one read of the open queue a measurement makes: every open request with the facts the rule needs, in a
#: single statement (a replica question costs the same whatever it asks, so it is asked once, never per request).
SCAN_FACTS_SQL = """select cast(cr.id as varchar), coalesce(cr.status, ''), cast(cr.userid as varchar),
  cast(cr.profileid as varchar), coalesce(cast(cr.trackid as varchar), ''),
  coalesce(json_extract_scalar(cr.metadata, '$.isrc'), ''),
  coalesce(cast(cr.credits as varchar), ''),
  coalesce(json_format(cr.verificationdata), ''),
  coalesce(json_extract_scalar(cr.verificationdata, '$.is_approved'), ''),
  cast(cr.deletedat is not null as varchar)
from postgresql_core.public.credit_requests cr
where cr.status in ({statuses}) and cr.deletedat is null and cr.trackid is not null{limit}"""

#: Every statement this process ran, so a printed number can be re-derived from the query that produced it.
_LAST: list[str] = []


def status_sql(statuses: Iterable[str]) -> str:
    vals = tuple(statuses)
    bad = [s for s in vals if s not in OPEN_FROM]
    if bad or not vals:
        raise ValueError(f"not an open status: {bad or list(vals)!r}")
    return ", ".join(f"'{s}'" for s in vals)


def scan_facts(limit: int = 0, statuses: Iterable[str] = OPEN_FROM,
               run: Callable[[str], list[list[str]]] | None = None) -> dict[str, RequestFacts]:
    """Every open request that has a track id, in ONE statement. Never one statement per request."""
    sql = SCAN_FACTS_SQL.format(statuses=status_sql(statuses),
                                limit=f"\nlimit {int(limit)}" if limit and limit > 0 else "")
    _LAST.append(sql)
    return _rows_to_facts((run or _trino)(sql))


def last_queries() -> list[str]:
    return list(_LAST)


def _verdict(text: str) -> dict[str, Any] | None:
    """The validator's verificationdata, or None when we could not read it. None is never "no rules"."""
    raw = str(text or "").strip()
    if not raw:
        return None
    try:
        doc = json.loads(raw)
    except ValueError:
        return None
    return doc if isinstance(doc, dict) else None


def _rows_to_facts(records: list[list[str]]) -> dict[str, RequestFacts]:
    out: dict[str, RequestFacts] = {}
    for rec in records:
        if len(rec) != 10:
            raise RuntimeError(f"replica row has {len(rec)} columns, expected 10")
        rid, status, uid, pid, tid, isrc, roles, verdict_json, approved, deleted = rec
        out[rid.lower()] = RequestFacts(
            status=status or None,
            user_id=int(uid) if str(uid).isdigit() else None,
            profile_id=str(pid).lower() or None,
            track_id=str(tid).lower() or None,
            isrc=isrc or None,
            roles=_pg_array(roles) if str(roles or "").strip() else None,
            verdict=_verdict(verdict_json),
            is_approved=approved or None,
            deleted=str(deleted).lower() == "true")
    return out


def newest_ledger_rows(db: sqlite3.Connection, users: Iterable[int]) -> dict[int, dict[str, Any]]:
    """{user id: the newest decider-ledger row} for the human-bucket split of a dry run, read the way
    verification-queue-report.classify_credit reads its ledger part."""
    out: dict[int, dict[str, Any]] = {}
    ids = sorted({int(u) for u in users if isinstance(u, int)})
    for i in range(0, len(ids), 400):
        batch = ids[i:i + 400]
        q = ",".join("?" * len(batch))
        for row in db.execute(
                f"SELECT user_id, reason, decision, proof_id FROM decisions WHERE user_id IN ({q}) "
                "ORDER BY id ASC", batch):
            out[int(row[0])] = {"reason": row[1] or "", "decision": row[2] or "", "proof_id": row[3]}
    return out


def human_bucket(latest: dict[str, Any] | None) -> str:
    """'' when the row is not one a person is holding; otherwise why it is.

    This mirrors the MACHINE-READABLE half of verification-queue-report.classify_credit's `human` branch (a decider
    hold for a document on file, a support request, an emailed support@). That report ALSO counts an Intercom
    reply, a flagged conversation and the 90-day support@ contact list, which this read does not have - so a dry
    run's human-bucket number is a FLOOR, and it says so."""
    if not latest:
        return ""
    reason = str(latest.get("reason") or "")
    if reason.startswith("proof on file: human review"):
        return "proof_on_file"
    if reason.startswith("proof on file") and (latest.get("decision") == "hold" or bool(latest.get("proof_id"))):
        return "proof_on_file"
    if latest.get("decision") == "support":
        return "support_requested"
    if "emailed support@" in reason:
        return "emailed_support"
    if "support already requested" in reason:
        return "support_requested"
    return ""
