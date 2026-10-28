"""credit-trust-decide: trust-yet-verify decisions on the HELD queue.

Captain 2026-10-15 ~22:12Z (verbatim): "i want AI live now - we have too many
credits to approve and to get supporting data for - let users know where there
was a credit given and that it needs support (trust yet verify approach)".
Wiring: data/credit-trust-system-fable-a1/live-tonight.md, Piece 1.

Per held (status=unverified) row, PAYING users' rows first, then the rest,
oldest first within each group (paying status changes the ORDER only, never
a decision; it is read from the hourly paying-users export and is UNKNOWN,
so the plain oldest-first order, when that file is missing, malformed or
older than 3h):
  * HOLD (no write, a human looks) when a validator ``reject_*`` rule fired
    (``policy.validator_rejected_rules``, shared with the approval auditor):
    never approved, never asked. Checked on the request row before any
    evidence is read, so no evidence error or 404 can turn it into support.
  * APPROVE (provisional) only when ALL hold:
      - no validator conflict (the server's agentApprovalGuard predicate,
        mirrored in ``validator_conflict``: any ``review_*`` rule >= 30,
        ``rule_errors._hold_on_error``, or track_credit >= 70 AND
        collaborations >= 90) - the server would refuse it anyway;
      - the track is not big (catalog pop >= 60, a linked artist >= 90, or
        unknown = big; the IDP ``_is_big_track`` rule in evidence.py). A
        row that is big only because a linked artist's profile could not be
        read this run is DEFERRED; a popularity the catalog does not carry
        is big (support request). A 404 from the admin catalog routes is
        UNKNOWN, never "missing" (core-backend answers 404 when its own
        catalog read fails): it is re-read once, then the row is deferred, and
        after 3 such deferred runs it goes to support as catalog_unreadable;
      - neither the user nor the profile is on the fraud / PULL / HOLD /
        RE-VERIFY lists (policies/credit-trust-decide.json). There are no
        named-user rules: a high-risk case is caught by the score (big track,
        conflicts, red flags) like anyone else;
      - no red flag (stillfloo pattern, high velocity on big tracks, Muso-only
        identity on an established release, evidence errors);
      - ONE evidence kind: every claimed role trusted-CONFIRMED (Spotify /
        Tidal / MLC / Jaxsta), or a trusted footprint (>= 3 earlier
        trusted-confirmed claims by this profile in EACH claimed role
        family), or web CREDIBLE: Codex on server-fetched sources says
        APPROVE with VERIFIED quoted passages on >= 2 independent domains,
        not all of them crowd-edited (MusicBrainz / Wikipedia only
        corroborate), and nothing contradicting it;
      - an EDITORIAL role (``editorial_role_terms`` in the policy: editor /
        editing / compilation / assembly / Pro Tools) is approved only on
        trusted catalog confirmation on a track under pop 30, and its
        profile's velocity counts double;
      - the user is under 200 approvals today.
  * REQUEST SUPPORT (status=user_verification_needed; Knock sends the "more
    info needed" notice, the credit stays held) for everything decided against:
    big tracks, conflicts, contradictions (one-person roles flagged ``n1``),
    NOT_FOUND on the web, deny-listed users. Every support request except
    NOT_FOUND is recorded ``doc_required`` (apply mode only): uvn-under30
    reads that marker and never approves those rows on popularity alone, and
    the decider approves one only with an approved proof on file (recorded
    as ``proof_id``; HOLD without one, DEFER while proof status is unknown).
  * NEVER RE-ASK (captain standing order 2026-10-16: "make sure you arent
    asking for things from users that already submitted documents and we
    approved"). A support request is filtered before it is written:
      - a user (or request) with a document on file - approved, pending
        review, or a human approval after documents - in the proof-on-file
        export -> HOLD (no write, "proof on file: human review");
      - a request that already received a support write (decision_outcomes)
        -> HOLD: a credit is asked about once, ever;
      - a user asked within the last 24h -> DEFER: one ask per user per
        window, the rest go out together in the next one;
      - the proof-on-file export missing, unreadable, malformed, older
        than 3h, or with a source flagged missing/stale -> no support
        request at all this run (DEFER,
        proof_status_unknown). Approvals are unaffected, except a
        documentation-required approval, which is deferred the same way.
  * DEFER (no write, retried later) when the web check could not run (Codex
    unavailable, nothing fetched and no fallback) - a model outage must never
    turn into a wave of support requests - or the user hit the daily cap.

Writes go through muso-admin-api.sh's conditional endpoint (compare-and-set
``expectedStatus: unverified``) in batches of <= 50, as
``credit-trust-decide@hydra-ops``. The decision row is written BEFORE the PUT
and the server's per-row outcome (updated / skipped:<reason>) AFTER it. The
server stays the authority: an approval it refuses comes back
``skipped:needs_human_review`` and is recorded, never retried blindly.
"""

from __future__ import annotations

import fcntl
import json
import os
import sqlite3
import subprocess
import time
import uuid
from concurrent.futures import ThreadPoolExecutor
from contextlib import contextmanager
from dataclasses import asdict, dataclass, field
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any, Callable, Iterable

from . import admin as admin_api
from . import dsp_gate, proof_parts
from .evidence import (
    BIG_ARTIST_POPULARITY,
    BIG_TRACK_POPULARITY,
    Evidence,
    EvidenceBuilder,
    EvidenceIncomplete,
    parse_ts,
)
from .judge import JudgeResult
from .policy import AUTOMATION_REGISTRY as REGISTRY
from .policy import DECIDE_POLICY as POLICY
from .policy import (
    WEB_CONFIRM_MIN_CONFIDENCE,
    WEB_CONFIRM_MIN_DOMAINS,
    WEB_CONTRADICT_MIN_CONFIDENCE,
    doc_required_ids,
    facts_of,
    server_approval_refusal,
    validator_conflict,
    validator_rejected_rules,
)
from .roles import ONE_PERSON_FAMILIES, editorial_terms, family_of, is_editorial
from .runner import log

AUTOMATION = "credit-trust-decide"
REQUESTER = "credit-trust-decide@hydra-ops"
ADMIN_IDENTITY = "credit-decider"     # muso-admin-api.sh MUSO_ADMIN_IDENTITY: this automation's own admin login
CONDITIONAL_PATH = "/admin/credit-requests/conditional-status"
APPROVED = "approved"
UNVERIFIED = "unverified"
UVN = "user_verification_needed"
BATCH = 50

ROOT = Path(__file__).resolve().parents[2]
KILL_SWITCH = Path(os.environ.get("CREDIT_TRUST_DECIDE_KILL_SWITCH", "/etc/hydra/credit-trust-decide.disabled"))
WRITE_LOCK = Path(os.environ.get("CV_CREDIT_WRITE_LOCK_PATH", "/var/lib/hydra/credit-status-writes.lock"))
PAYING_USERS_FILE = Path(os.environ.get("CREDIT_TRUST_PAYING_USERS_FILE", "/var/lib/credit-trust/paying-users.json"))
PAYING_USERS_MAX_AGE = timedelta(hours=3)
PAYING_USERS_MAX_SKEW = timedelta(minutes=5)
PROOF_ON_FILE = Path(os.environ.get("CREDIT_TRUST_PROOF_ON_FILE", "/var/lib/credit-trust/proof-on-file.json"))
PROOF_MAX_AGE = timedelta(hours=3)
# The proof store whose stage-2 verdicts release a proof-on-file hold to a user ask (with_stage2).
STAGE2_STORE = Path(os.environ.get("CREDIT_PROOF_STORE", os.path.join(
    os.environ.get("CREDIT_VERIFY_STATE_DIR", "/var/lib/hydra-credit-verify"), "proof.sqlite")))
PROOF_KINDS = frozenset({"approved_doc", "pending_doc", "human_approved_after_doc"})
APPROVED_PROOF_KINDS = frozenset({"approved_doc", "human_approved_after_doc"})
PROOF_UNKNOWN_STATE = "proof_on_file_unknown"
SUPPORT_WINDOW = timedelta(hours=24)  # at most one support batch per user per window
PROOF_HOLD_RETRY = timedelta(hours=24)  # a proof-on-file hold is looked at again after this
PROOF_UNKNOWN = "proof_status_unknown"
WINDOW_DEFER = "per-user window: "
# Decisions that did not read the catalog: they neither count as a 404 nor
# reset the consecutive-404 count.
NOT_A_CATALOG_READ = ("catalog_unreadable", PROOF_UNKNOWN, WINDOW_DEFER, "evidence unavailable:",
                      "catalog track unreadable", "a linked artist's profile was unreadable", "evidence incomplete",
                      "track not ingested yet")
STATUS_VERIFY = os.environ.get(
    "CREDIT_TRUST_STATUS_VERIFY",
    "/opt/hydra/workspaces/operations/skills/muso-ops-credit-verification/scripts/verify-credit-request-status.sh")

FOOTPRINT_MIN = 3
CATALOG_404 = "catalog_unreadable (admin API 404 on the re-read; core-backend also answers 404 when its catalog read fails): "
CATALOG_404_MAX_DEFERS = 3            # deferred runs on a 404 before the row goes to support
RETRY_AFTER = timedelta(hours=2)      # a decided row is not re-decided inside this window

# Crowd-edited: anyone, the claimant included, can add a credit there. They
# corroborate; they never carry a web approval on their own.
CROWD_EDITED_DOMAINS = frozenset({"musicbrainz.org", "wikipedia.org"})

# Editorial roles (captain 2026-10-15 ~23:42Z: "some abusers of editorial
# roles"). roles.family_of folds them into "engineer" for the auditor; the
# decider treats them as their own high-risk family, matched on the policy's
# editorial_role_terms (uvn-under30 refuses the same roles).
EDITORIAL_MID_POPULARITY = 30
EDITORIAL_VELOCITY_WEIGHT = 2
HIGH_VELOCITY_24H = 50
HIGH_VELOCITY_7D = 150



@dataclass
class Policy:
    deny_user_ids: set[int]
    deny_profile_ids: set[str]
    editorial_role_terms: tuple[str, ...]
    max_rows_per_run: int = 500
    max_approvals_per_user_per_day: int = 200
    # Distinct users who may receive a support request (Knock "more info needed")
    # per UTC day. firstmate 031: 100/day for the first 48h of go-live.
    max_ask_users_per_day: int = 100

    @classmethod
    def load(cls, path: Path | None = None) -> "Policy":
        """A missing, null or mistyped deny list is fatal (ValueError): it must
        never read as "nobody is denied"."""
        path = Path(path or POLICY)
        d = json.loads(path.read_text(encoding="utf-8"))
        users, profiles = (d.get("deny_user_ids"), d.get("deny_profile_ids")) if isinstance(d, dict) else (None, None)
        if not isinstance(users, list) or not all(isinstance(u, int) and not isinstance(u, bool) for u in users):
            raise ValueError(f"{path}: deny_user_ids must be a list of integer user ids")
        if not isinstance(profiles, list) or not all(isinstance(p, str) and p.strip() for p in profiles):
            raise ValueError(f"{path}: deny_profile_ids must be a list of profile id strings")
        # Firstmate 154: the fraud watchlist (policies/fraud-watchlist.json, beside this file) is held by
        # every approval path too. Required next to the deployed policy; optional beside a test policy.
        from . import watchlist as watchlist_mod
        # QA @1339: requiredness follows the RESOLVED policy location, never whether a path was passed:
        # an explicit load of the deployed policy must fail closed on a missing watchlist too.
        wl = watchlist_mod.load(path.with_name("fraud-watchlist.json"),
                                required=path.resolve().parent == watchlist_mod.DEFAULT.resolve().parent)
        return cls(deny_user_ids=set(users) | set(wl.user_ids),
                   deny_profile_ids={p.strip().lower() for p in profiles} | set(wl.profile_ids),
                   editorial_role_terms=editorial_terms(d.get("editorial_role_terms")),
                   max_rows_per_run=int(d.get("max_rows_per_run") or 500),
                   max_approvals_per_user_per_day=int(d.get("max_approvals_per_user_per_day") or 200),
                   max_ask_users_per_day=_nonneg_int(d.get("max_ask_users_per_day", 100), "max_ask_users_per_day"))


def registry_approved(path: Path | None = None) -> tuple[bool, str]:
    """(approved, why). Apply mode writes nothing unless the captain's approval
    is recorded for this automation (AGENTS.md: nothing approves without it)."""
    path = path or REGISTRY
    try:
        entry = json.loads(Path(path).read_text(encoding="utf-8"))["automations"][AUTOMATION]
    except (OSError, ValueError, KeyError, TypeError) as exc:
        return False, f"registry unreadable or has no {AUTOMATION} entry: {exc}"
    if entry.get("approved") is not True:
        return False, f"{AUTOMATION} is approved=false in {path}"
    if not str(entry.get("approved_by") or "").strip() or not str(entry.get("approval_ref") or "").strip():
        return False, f"{AUTOMATION} has no approved_by / approval_ref"
    return True, f"approved by {entry['approved_by']}"


# ── ledger ──────────────────────────────────────────────────────────────────
SCHEMA = """
CREATE TABLE IF NOT EXISTS decisions (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  run_id TEXT NOT NULL,
  decided_at TEXT NOT NULL,
  request_id TEXT NOT NULL,
  profile_id TEXT,
  user_id INTEGER,
  track_id TEXT,
  track_title TEXT,
  claimed_roles TEXT,
  popularity INTEGER,
  big_track INTEGER NOT NULL,
  decision TEXT NOT NULL,              -- approve | support | hold (no write, a human looks) | defer
  reason TEXT NOT NULL,
  evidence_kind TEXT,                  -- catalog_confirmed | footprint | web_credible | NULL
  catalog TEXT,                        -- per-role trusted verdicts
  web_verdict TEXT,                    -- CREDIBLE | NOT_FOUND | CONTRADICTED | UNAVAILABLE | NULL (not run)
  web_urls TEXT,                       -- JSON: verified findings (url, quote, snapshot sha256)
  footprint INTEGER,
  n1 INTEGER NOT NULL DEFAULT 0,       -- one-person role contradicted by a trusted source or the web
  doc_required INTEGER NOT NULL DEFAULT 0, -- support request that needs documents: uvn-under30 never approves it
  paid_priority INTEGER,               -- 1 paying user (ordered first), 0 not paying, NULL paying status unknown
  proof_id TEXT,                       -- the proof the decider relied on to approve a documentation-required row
  model TEXT,
  provider TEXT,                       -- codex | jev | openrouter | NULL (no model)
  cost_usd REAL,                       -- 0 on Codex; metered on the OpenRouter fallback
  prompt_sha256 TEXT,
  llm_call_id INTEGER,
  conflict TEXT,
  mode TEXT NOT NULL                   -- shadow | apply
);
CREATE INDEX IF NOT EXISTS decisions_req ON decisions(request_id);
CREATE TABLE IF NOT EXISTS state (k TEXT PRIMARY KEY, v TEXT NOT NULL);
CREATE INDEX IF NOT EXISTS decisions_run ON decisions(run_id);
CREATE INDEX IF NOT EXISTS decisions_time ON decisions(decided_at);
CREATE TABLE IF NOT EXISTS decision_outcomes (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  run_id TEXT NOT NULL,
  at TEXT NOT NULL,
  request_id TEXT NOT NULL,
  action TEXT NOT NULL,                -- approve | support | revert
  outcome TEXT NOT NULL                -- approved | user_verification_needed | unverified | skipped:<reason> | error:<msg> | shadow
);
CREATE INDEX IF NOT EXISTS outcomes_req ON decision_outcomes(request_id);
CREATE INDEX IF NOT EXISTS outcomes_run ON decision_outcomes(run_id);
CREATE TRIGGER IF NOT EXISTS decisions_no_update BEFORE UPDATE ON decisions
BEGIN SELECT RAISE(ABORT, 'decisions is append-only'); END;
CREATE TRIGGER IF NOT EXISTS decisions_no_delete BEFORE DELETE ON decisions
BEGIN SELECT RAISE(ABORT, 'decisions is append-only'); END;
CREATE TRIGGER IF NOT EXISTS outcomes_no_update BEFORE UPDATE ON decision_outcomes
BEGIN SELECT RAISE(ABORT, 'decision_outcomes is append-only'); END;
CREATE TRIGGER IF NOT EXISTS outcomes_no_delete BEFORE DELETE ON decision_outcomes
BEGIN SELECT RAISE(ABORT, 'decision_outcomes is append-only'); END;
"""


def utc(ts: datetime | None = None) -> str:
    return (ts or datetime.now(timezone.utc)).strftime("%Y-%m-%dT%H:%M:%SZ")


def ensure_schema(db: sqlite3.Connection) -> None:
    db.executescript(SCHEMA)
    have = {r[1] for r in db.execute("PRAGMA table_info(decisions)")}
    for col, decl in (("doc_required", "INTEGER NOT NULL DEFAULT 0"), ("paid_priority", "INTEGER"),
                      ("proof_id", "TEXT")):
        if col not in have:
            db.execute(f"ALTER TABLE decisions ADD COLUMN {col} {decl}")
    db.commit()


@dataclass
class Decision:
    request_id: str
    profile_id: str
    user_id: int | None
    track_id: str
    track_title: str
    claimed_roles: list[str]
    popularity: int | None
    big_track: bool
    decision: str
    reason: str
    evidence_kind: str | None = None
    catalog: str = ""
    web_verdict: str | None = None
    web_urls: list[dict[str, Any]] = field(default_factory=list)
    footprint: int = 0
    n1: bool = False
    doc_required: bool = False
    paid_priority: bool | None = None
    proof_id: str | None = None
    catalog_404: bool = False            # deferred on a 404 (counted from the reason prefix in the ledger)
    model: str | None = None
    provider: str | None = None
    cost_usd: float | None = None
    prompt_sha256: str | None = None
    llm_call_id: int | None = None
    conflict: dict[str, Any] | None = None
    request_created_at: str | None = None    # the credit request's createdAt (proof-on-file request scope)


def record_decision(db: sqlite3.Connection, run_id: str, mode: str, d: Decision, at: datetime | None = None) -> None:
    db.execute(
        "INSERT INTO decisions (run_id, decided_at, request_id, profile_id, user_id, track_id, track_title, claimed_roles,"
        " popularity, big_track, decision, reason, evidence_kind, catalog, web_verdict, web_urls, footprint, n1,"
        " doc_required, paid_priority, proof_id, model, provider, cost_usd, prompt_sha256, llm_call_id, conflict, mode)"
        " VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
        (run_id, utc(at), d.request_id, d.profile_id, d.user_id, d.track_id, d.track_title, ",".join(d.claimed_roles),
         d.popularity, 1 if d.big_track else 0, d.decision, d.reason[:600], d.evidence_kind, d.catalog, d.web_verdict,
         json.dumps(d.web_urls[:6], ensure_ascii=False), d.footprint, 1 if d.n1 else 0,
         1 if d.doc_required else 0, None if d.paid_priority is None else int(d.paid_priority), d.proof_id,
         d.model, d.provider,
         d.cost_usd, d.prompt_sha256,
         d.llm_call_id, json.dumps(d.conflict) if d.conflict else None, mode))
    db.commit()


def record_outcome(db: sqlite3.Connection, run_id: str, request_id: str, action: str, outcome: str,
                   at: datetime | None = None) -> None:
    db.execute("INSERT INTO decision_outcomes (run_id, at, request_id, action, outcome) VALUES (?,?,?,?,?)",
               (run_id, utc(at), request_id, action, outcome[:300]))
    db.commit()


def recently_decided(db: sqlite3.Connection, since: str) -> set[str]:
    return {r[0] for r in db.execute("SELECT DISTINCT request_id FROM decisions WHERE decided_at >= ?", (since,))}


def approvals_today_by_user(db: sqlite3.Connection, day_start: str) -> dict[int, int]:
    rows = db.execute(
        "SELECT d.user_id, COUNT(DISTINCT o.request_id) FROM decision_outcomes o JOIN decisions d "
        "ON d.request_id = o.request_id AND d.run_id = o.run_id "
        "WHERE o.outcome = 'approved' AND o.action = 'approve' AND o.at >= ? GROUP BY d.user_id", (day_start,))
    return {int(u): int(n) for u, n in rows if u is not None}


def footprint(db: sqlite3.Connection, profile_id: str, families: set[str]) -> int:
    """The smallest, over the claimed role families, count of earlier claims
    by this profile in THAT family that a TRUSTED source confirmed (catalog
    evidence only - never web, never a Muso vouch). A decider claim counts only
    once the server approved it in apply mode (never a shadow, deferred, held or
    server-skipped decision). Every family needs its own footprint; an
    unclassified role ("other") never has one."""
    if not profile_id or not families or families & {"other", ""}:
        return 0
    seen: dict[str, set[str]] = {f: set() for f in families}
    for sql in ("SELECT request_id, claimed_roles FROM reviews WHERE profile_id = ? "
                "AND basis = 'trusted_source_confirmation'",
                "SELECT d.request_id, d.claimed_roles FROM decisions d JOIN decision_outcomes o "
                "ON o.request_id = d.request_id AND o.run_id = d.run_id WHERE d.profile_id = ? "
                "AND d.evidence_kind = 'catalog_confirmed' AND d.mode = 'apply' AND d.decision = 'approve' "
                "AND o.action = 'approve' AND o.outcome = 'approved'"):
        for rid, roles in db.execute(sql, (profile_id,)):
            for fam in {family_of(r) for r in str(roles or "").split(",") if r} & families:
                seen[fam].add(rid)
    return min(len(v) for v in seen.values())


# ── the decision ────────────────────────────────────────────────────────────
def web_reading(j: JudgeResult | None, ev: Evidence) -> tuple[str, list[dict[str, Any]], set[str], set[str]]:
    """(CREDIBLE | NOT_FOUND | CONTRADICTED | UNAVAILABLE, verified findings, supporting, contradicting)."""
    if j is None or not j.ok:
        return "UNAVAILABLE", [], set(), set()
    names = ev.claimant_names
    owned = ev.claimant_domains or []
    sup = j.supporting_domains(owned, names)
    con = j.contradicting_domains(owned, names)
    findings = [{"url": f.get("source_url"), "quote": f.get("quote"), "effect": f.get("effect"),
                 "snapshot_sha256": f.get("body_sha256")} for f in j.findings]
    if j.verdict in ("REJECT-RECOMMENDED", "CONTRADICTED") and j.confidence >= WEB_CONTRADICT_MIN_CONFIDENCE and con:
        return "CONTRADICTED", findings, sup, con
    if (j.verdict in ("APPROVE-RECOMMENDED", "CONFIRMED") and j.confidence >= WEB_CONFIRM_MIN_CONFIDENCE
            and len(sup) >= WEB_CONFIRM_MIN_DOMAINS and sup - CROWD_EDITED_DOMAINS and not con
            and j.identity_consistent is not False and ev.claimant_domains is not None):
        return "CREDIBLE", findings, sup, con
    return "NOT_FOUND", findings, sup, con


def one_person(ev: Evidence) -> bool:
    return any(family_of(r) in ONE_PERSON_FAMILIES for r in ev.claimed_roles)


def known_big(ev: Evidence) -> bool:
    """Big on a popularity that was actually read (not big-because-unknown)."""
    c = ev.catalog
    return ((c.popularity is not None and c.popularity >= BIG_TRACK_POPULARITY)
            or (c.artist_popularity or 0) >= BIG_ARTIST_POPULARITY)


def editorial_velocity(ev: Evidence) -> str | None:
    p = ev.profile
    if p is None:
        return None
    w = EDITORIAL_VELOCITY_WEIGHT
    if p.requests_24h * w >= HIGH_VELOCITY_24H or p.requests_7d * w >= HIGH_VELOCITY_7D:
        return f"{p.requests_24h}/24h, {p.requests_7d}/7d (x{w})"
    return None


def pre_model(req: dict[str, Any], ev: Evidence, policy: Policy, fp: int) -> Decision | None:
    """Everything decidable without the model. None = needs the web check."""
    d = base_decision(req, ev)
    d.footprint = fp
    uid = d.user_id
    if uid is not None and uid in policy.deny_user_ids:
        return _set(d, "support", "user on the fraud / PULL / HOLD / RE-VERIFY list")
    if d.profile_id.lower() in policy.deny_profile_ids:
        return _set(d, "support", "profile on the fleet-scan / stillfloo deny list")
    if not ev.track_id:
        return _set(d, "defer", "track not ingested yet (no trackId): decided once the catalog has it")
    if ev.track_popularity is None and any(e.startswith("track") for e in ev.errors):
        return _defer_unreadable(d, ev, "catalog track unreadable this run: " + "; ".join(ev.errors)[:200])
    conflict = validator_conflict(req.get("verificationData"))
    if conflict:
        d.conflict = conflict
        return _set(d, "support", "validator conflict (the server refuses agent approvals of these): "
                    + ",".join(conflict["hold_rules"] + (["class_c"] if conflict["class_c"] else [])
                               + (["hold_on_error"] if conflict["hold_on_error"] else [])))
    if ev.catalog.artist_read_failed and not known_big(ev):
        return _defer_unreadable(d, ev, "a linked artist's profile was unreadable this run: decided once it is read")
    if ev.big_track:
        return _set(d, "support", "big track (pop >= 60 / big artist / popularity not in the catalog): "
                    "proof is required, never provisional")
    if ev.any_contradicted:
        d.n1 = one_person(ev)
        return _set(d, "support", "a trusted source (Spotify/Tidal/MLC/Jaxsta) credits someone else in this role")
    flags = facts_of(ev).flags
    if flags == ["evidence_errors"]:
        return _defer_unreadable(d, ev, "evidence incomplete this run: " + "; ".join(ev.errors)[:200])
    if flags:
        return _set(d, "support", "red flags: " + ", ".join(flags))
    editorial = [r for r in ev.claimed_roles if is_editorial(r, policy.editorial_role_terms)]
    if editorial:
        roles = ", ".join(editorial)
        velocity = editorial_velocity(ev)
        if velocity:
            return _set(d, "support", f"editorial role ({roles}): high velocity, editorial weighs double ({velocity})")
        if (ev.track_popularity or 0) >= EDITORIAL_MID_POPULARITY:
            return _set(d, "support", f"editorial role ({roles}) on a track at pop >= {EDITORIAL_MID_POPULARITY}: "
                        "documentation required")
        if not ev.all_confirmed:
            return _set(d, "support", f"editorial role ({roles}): only a trusted source naming this profile in "
                        "the role approves it (never footprint or web); documentation required")
    if ev.all_confirmed:
        d.evidence_kind = "catalog_confirmed"
        return _set(d, "approve", "every claimed role is credited to this profile by a trusted source")
    if fp >= FOOTPRINT_MIN:
        d.evidence_kind = "footprint"
        return _set(d, "approve", f"trusted footprint: {fp} earlier trusted-confirmed claims in this role family")
    return None


def with_web(req: dict[str, Any], ev: Evidence, j: JudgeResult | None, fp: int) -> Decision:
    d = base_decision(req, ev)
    d.footprint = fp
    reading, findings, sup, con = web_reading(j, ev)
    d.web_verdict, d.web_urls = reading, findings
    if j is not None:
        d.model, d.prompt_sha256, d.llm_call_id = j.model or None, j.prompt_sha256, j.llm_call_id
        d.provider, d.cost_usd = j.provider, j.cost_usd
    if reading == "UNAVAILABLE":
        return _set(d, "defer", f"web check unavailable ({(j.error if j else 'no judge')}); retried next run")
    if reading == "CONTRADICTED":
        d.n1 = one_person(ev)
        return _set(d, "support", f"web sources contradict the claim: {', '.join(sorted(con))}")
    if reading == "CREDIBLE":
        d.evidence_kind = "web_credible"
        return _set(d, "approve", f"verified web support: {', '.join(sorted(sup))}")
    return _set(d, "support", "no trusted or verifiable web evidence found (NOT_FOUND)", doc_required=False)


def base_decision(req: dict[str, Any], ev: Evidence) -> Decision:
    uid = req.get("userId")
    return Decision(request_id=ev.request_id, profile_id=ev.profile_id, user_id=int(uid) if isinstance(uid, int) else None,
                    track_id=ev.track_id, track_title=ev.track_title, claimed_roles=list(ev.claimed_roles),
                    popularity=ev.track_popularity, big_track=ev.big_track, decision="", reason="",
                    catalog=ev.deterministic_summary(), request_created_at=_created(req))


def _defer_unreadable(d: Decision, ev: Evidence, reason: str) -> Decision:
    if ev.catalog_not_found:
        d.catalog_404 = True
        return _set(d, "defer", CATALOG_404 + reason)
    return _set(d, "defer", reason)


def catalog_404_defers(db: sqlite3.Connection, request_id: str, mode: str) -> int:
    """CONSECUTIVE earlier runs (same mode) that deferred this request on a
    catalog 404. Only a later decision that read the catalog resets the count;
    filter deferrals and other unreadable runs (NOT_A_CATALOG_READ) do not."""
    not_read = " OR ".join("instr(reason, ?) = 1" for _ in NOT_A_CATALOG_READ)
    return int(db.execute(
        "SELECT COUNT(DISTINCT run_id) FROM decisions WHERE request_id = ? AND mode = ? AND decision = 'defer'"
        " AND instr(reason, ?) = 1 AND id > (SELECT COALESCE(MAX(id), 0) FROM decisions"
        f" WHERE request_id = ? AND mode = ? AND NOT ({not_read}))",
        (request_id, mode, CATALOG_404, request_id, mode, *NOT_A_CATALOG_READ)).fetchone()[0])


def skipped_this_run(db: sqlite3.Connection, now: datetime, mode: str) -> set[str]:
    """Requests not re-decided this run: anything decided in the last 2h, a
    hold for a credit already asked about (permanent: a human looks), a
    proof-on-file hold for 24h, and a per-user-window deferral until that
    user's window ends - then ALL of the user's waiting rows come back in the
    same run, so they go out as one batch."""
    skip = recently_decided(db, utc(now - RETRY_AFTER))
    recent_users = users_asked_since(db, utc(now - SUPPORT_WINDOW))
    asked = asked_requests(db)
    proof_since = utc(now - PROOF_HOLD_RETRY)
    for rid, decision, reason, uid, at in db.execute(
            "SELECT d.request_id, d.decision, d.reason, d.user_id, d.decided_at FROM decisions d JOIN"
            " (SELECT request_id, MAX(id) AS m FROM decisions WHERE mode = ? GROUP BY request_id) x ON d.id = x.m"
            " WHERE d.decision IN ('hold', 'defer')", (mode,)):
        if decision == "defer" and str(reason).startswith(WINDOW_DEFER):
            if uid in recent_users:
                skip.add(rid)
            else:
                skip.discard(rid)
        elif decision == "hold" and (rid in asked or str(at) >= proof_since):
            skip.add(rid)
    return skip


@dataclass(frozen=True)
class ProofOnFile:
    """Users and requests with a document or proof on file (approved, pending
    review, or approved by a human after documents): never asked again."""
    user_ids: frozenset[int]
    request_ids: frozenset[str]
    approved_refs: dict[str, str] = field(default_factory=dict)  # request id -> ref of an APPROVED proof

    # Users who emailed support@ in the last 90 days (top-level gmail_contacts_90d):
    # firstmate 041 - always held for a human, never asked, whatever the Gmail scan found.
    support_contacts: frozenset[int] = frozenset()
    # Request ids an APPROVED proof entry names (APPROVED_PROOF_KINDS, with or without a ref).
    approved_requests: frozenset[str] = frozenset()
    # Request ids stage 2 released to a user ask (stage2_verdicts: need_more -> gap-ask,
    # no_document -> uvn-status; Fable 2026-10-26 13:23Z GO 2). Filled by with_stage2().
    stage2_asks: dict[str, str] = field(default_factory=dict)  # request id -> campaign
    # Request scope ([key=pof-user-scope], proof-loop lead 2026-10-27 via firstmate 009). Users with a
    # WHOLE-USER entry (request_id null, or not a credit request id) -> the newest `proof_at` of those
    # entries, or None when any of them carries no date. `user_ids` keeps its old meaning (every user
    # with any entry) for the readers that still exclude whole users (score_approve).
    user_level: dict[int, datetime | None] = field(default_factory=dict)
    # Request ids a document filed in proof_intake names as a candidate (with_intake()).
    intake_requests: frozenset[str] = frozenset()
    # True only once proof_intake was read (with_intake): until then covers() stays whole-user.
    scoped: bool = False

    def covers(self, d: "Decision") -> bool:
        """Is this credit request covered by a document on file (held for a human, never asked,
        never provisionally approved)? Per REQUEST: a request-scoped entry or a proof_intake
        candidate covers its request; a whole-user entry covers only requests that already
        existed when that proof arrived (created at or before the user's newest `proof_at`).
        Anything not known stays covered, exactly as before: an undated whole-user entry, a
        request without createdAt, or a run that could not read proof_intake."""
        rid = d.request_id.lower()
        if rid in self.request_ids or rid in self.intake_requests:
            return True
        if d.user_id not in self.user_ids:
            return False
        if not self.scoped:
            return True
        if d.user_id not in self.user_level:
            return False                 # only request-scoped entries: they cover their own requests
        newest = self.user_level[d.user_id]
        created = parse_ts(getattr(d, "request_created_at", None))
        return newest is None or created is None or created <= newest

    def handed_to_ask(self, d: "Decision") -> str:
        """The verify-gate campaign that asks this covered request's user ('' when none): stage 2
        released it and no APPROVED proof names it. Mere entry existence is not a "never ask
        again" any more for such a request, but the ask is never the decider's support write
        (its Knock notice is a generic re-ask outside the verify ledger's one-per-day rule): it
        stays held here and goes out through intercom-verify-request.sh."""
        rid = d.request_id.lower()
        return "" if rid in self.approved_requests else self.stage2_asks.get(rid, "")

    def contacted_support(self, d: "Decision") -> bool:
        return d.user_id is not None and d.user_id in self.support_contacts


SUPPORT_CONTACTS_KEY = proof_parts.SUPPORT_CONTACTS


def muso_user_id(value: Any) -> int | None:
    """An entry's user id as the integer Muso id (proof_parts accepts "111" and 111 as
    the same user), or None when it is not one."""
    if isinstance(value, bool):
        return None
    if isinstance(value, int):
        return value
    text = str(value).strip()
    return int(text) if text.isdigit() else None


def proof_on_file(path: Path | None = None, now: datetime | None = None
                  ) -> tuple[ProofOnFile | None, str | None]:
    """(proof, None) from the hourly proof-on-file export
    {generated_at, sources: [{name, generated_at, count, stale?, missing?}],
    users, entries: [{user_id, request_id | null, kind, source, ref}],
    gmail_contacts_90d}, or (None, why) when proof status is UNKNOWN.

    Completeness is THE shared rule, credit_review.proof_parts (the verify notes,
    the take-back gate and Caroline's support tool read it the same way): core,
    cs-intercom and cs-gmail all present, unflagged and fresh by their own stamps,
    no other part flagged, entries well-formed and ``users`` consistent. On top of
    it the decider is stricter, never looser: the export's own stamp must be fresh,
    every user id must be a Muso (integer) id, and the support@ contact list must be
    readable (firstmate 041: those users are held, never asked)."""
    path = Path(path or PROOF_ON_FILE)
    now = now or datetime.now(timezone.utc)
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        return None, f"{path} is missing"
    except (OSError, ValueError) as exc:
        return None, f"{path} is unreadable: {exc}"[:200]
    malformed = f"{path} is malformed (want generated_at, sources[], users, entries[])"
    if not isinstance(data, dict):
        return None, malformed
    try:
        proof_parts.check(data, now=now, max_age_h=PROOF_MAX_AGE.total_seconds() / 3600,
                          max_skew_h=PAYING_USERS_MAX_SKEW.total_seconds() / 3600)
        proof_parts.check_entries(data)
    except proof_parts.PartsError as exc:
        return None, f"{path} is not authoritative: {exc}"[:200]
    ts = parse_ts(data.get("generated_at"))
    if ts is None:
        return None, malformed
    contacts = proof_parts.support_contacts(data, now=now, max_age_h=PROOF_MAX_AGE.total_seconds() / 3600,
                                            max_skew_h=PAYING_USERS_MAX_SKEW.total_seconds() / 3600)
    if contacts is None:
        return None, f"{path} has no readable {SUPPORT_CONTACTS_KEY} list (anyone may have emailed support@)"
    users: set[int] = set()
    requests: set[str] = set()
    approved: dict[str, str] = {}
    approved_ids: set[str] = set()
    user_level: dict[int, datetime | None] = {}
    for e in data["entries"]:
        uid = muso_user_id(e["user_id"])
        if uid is None:
            return None, f"{path} has a user_id that is not a Muso user id: {e['user_id']!r}"[:200]
        rid = e.get("request_id")
        whole_user = rid is None
        if rid is not None:
            try:
                rid = str(uuid.UUID(rid))
            except ValueError:
                # Not a credit request id: it can name no request, so it counts as a
                # whole-user entry below, and nobody is asked by mistake.
                rid = rid.strip().lower()
                whole_user = True
            requests.add(rid)
            if e.get("kind") in APPROVED_PROOF_KINDS:
                approved_ids.add(rid)
            if e.get("kind") in APPROVED_PROOF_KINDS and str(e.get("ref") or "").strip():
                approved.setdefault(rid, f"{e.get('source') or 'proof'}:{str(e['ref']).strip()}")
        if whole_user:
            at = parse_ts(e.get("proof_at"))          # when the customer sent it; optional in the export
            if at is None or (uid in user_level and user_level[uid] is None):
                user_level[uid] = None                # one undated entry keeps the whole user covered
            else:
                user_level[uid] = max(at, user_level.get(uid) or at)
        users.add(uid)
    if now - ts > PROOF_MAX_AGE:
        return None, f"{path} is stale (generated {utc(ts)})"
    if ts - now > PAYING_USERS_MAX_SKEW:
        return None, f"{path} is dated in the future ({utc(ts)})"
    return ProofOnFile(frozenset(users), frozenset(requests), approved, support_contacts=contacts,
                       approved_requests=frozenset(approved_ids), user_level=user_level), None


def with_intake(proof: ProofOnFile | None, path: str | None = None) -> ProofOnFile | None:
    """`proof` scoped to the request ([key=pof-user-scope]): the candidate request ids of every
    document filed in proof_intake become per-request cover, and covers() stops treating a
    whole-user entry as cover for requests created after that user's newest proof. If the
    proof store cannot be read the scope is NOT applied (whole-user cover, as before): a
    filed document must never be missed because its table was unreadable."""
    if proof is None:
        return None
    from dataclasses import replace
    p = str(path or STAGE2_STORE)
    try:
        db = sqlite3.connect(f"file:{p}?mode=ro", uri=True, timeout=30)
        try:
            rows = db.execute("SELECT candidate_request_ids_json FROM proof_intake WHERE subject = 'credit'").fetchall()
        finally:
            db.close()
        ids: set[str] = set()
        for (raw,) in rows:
            for rid in json.loads(raw or "[]"):
                ids.add(str(rid).strip().lower())
    except (sqlite3.Error, ValueError, TypeError) as exc:
        log(f"decide: proof_intake unreadable ({exc}); proof-on-file stays whole-user this run")
        return proof
    return replace(proof, intake_requests=frozenset(ids), scoped=True)


STAGE2_ASK_HOLD = "proof on file: stage 2 judged the document"


def with_stage2(proof: ProofOnFile | None, path: str | None = None) -> ProofOnFile | None:
    """`proof` with the stage-2 release (stage2_verdicts.RELEASES). An unreadable proof store
    releases nothing: every covered request keeps the plain proof-on-file hold."""
    if proof is None:
        return None
    from dataclasses import replace

    from . import stage2_verdicts
    try:
        verdicts = stage2_verdicts.load(str(path or STAGE2_STORE))
    except stage2_verdicts.Stage2Error as exc:
        log(f"decide: stage-2 verdicts unreadable ({exc}); proof-on-file holds stay as they are")
        return proof
    asks: dict[str, str] = {}
    for campaign, outcome in stage2_verdicts.RELEASES.items():
        for rid in stage2_verdicts.released(verdicts, outcome):
            asks.setdefault(rid, campaign)
    return replace(proof, stage2_asks=asks)


def stage2_outcome(campaign: str) -> str:
    from . import stage2_verdicts
    return stage2_verdicts.RELEASES.get(campaign, "")


def proof_status_transition(db: sqlite3.Connection, mode: str, proof_why: str | None) -> str | None:
    """The announcement for a change in proof-on-file status: once when it
    becomes unknown, once when it is restored, nothing in between (tracked in
    the ledger's state table, per mode)."""
    key = f"{PROOF_UNKNOWN_STATE}:{mode}"
    row = db.execute("SELECT v FROM state WHERE k = ?", (key,)).fetchone()
    was_unknown = bool(row) and row[0] == "1"
    if bool(proof_why) == was_unknown:
        return None
    db.execute("INSERT INTO state(k, v) VALUES(?, ?) ON CONFLICT(k) DO UPDATE SET v = excluded.v",
               (key, "1" if proof_why else "0"))
    db.commit()
    if proof_why:
        return (f"PROOF-ON-FILE STATUS UNKNOWN ({proof_why}): no support request is sent until it recovers; "
                "announced once.")
    return "PROOF-ON-FILE status restored: support requests resume."


def asked_requests(db: sqlite3.Connection) -> set[str]:
    """Requests a support write may have reached (written, or not provably
    unwritten): never asked again."""
    return {r[0] for r in db.execute(
        "SELECT DISTINCT request_id FROM decision_outcomes WHERE action = 'support'"
        " AND (outcome = ? OR instr(outcome, 'error:unverified:') = 1)", (UVN,))}


def users_asked_since(db: sqlite3.Connection, since: str) -> set[int]:
    return {int(r[0]) for r in db.execute(
        "SELECT DISTINCT d.user_id FROM decision_outcomes o JOIN decisions d"
        " ON d.request_id = o.request_id AND d.run_id = o.run_id"
        " WHERE o.action = 'support' AND (o.outcome = ? OR instr(o.outcome, 'error:unverified:') = 1)"
        " AND o.at >= ? AND d.user_id IS NOT NULL", (UVN, since))}


def _nonneg_int(v: Any, key: str) -> int:
    if isinstance(v, bool) or not isinstance(v, int) or v < 0:
        raise ValueError(f"{key} must be a non-negative integer")
    return v


ASK_CAP_DEFER = "daily ask cap: "


def filter_support(db: sqlite3.Connection, decisions: list["Decision"], res: "RunResult",
                   proof: ProofOnFile | None, proof_why: str | None, now: datetime,
                   max_ask_users_per_day: int | None = None) -> None:
    """Never re-ask: turn support decisions that must not be sent into HOLD or
    DEFER, counting each reason on the run."""
    support = [d for d in decisions if d.decision == "support"]
    res.support_candidates = len(support)
    if proof is None:
        for d in support:
            _set(d, "defer", f"{PROOF_UNKNOWN} ({proof_why}): no support request is sent while it is unknown")
        res.deferred_proof_unknown += len(support)
        return
    asked = asked_requests(db)
    recent = users_asked_since(db, utc(now - SUPPORT_WINDOW))
    for d in support:
        if proof.covers(d) and (ask := proof.handed_to_ask(d)):
            _set(d, "hold", f"{STAGE2_ASK_HOLD} ({stage2_outcome(ask)}): the user is asked through "
                 f"intercom-verify-request.sh --campaign {ask}, never by a support write")
            res.held_stage2_ask += 1
        elif proof.covers(d):
            _set(d, "hold", "proof on file: human review (a document is already on file; never ask again)")
            res.held_proof += 1
        elif proof.contacted_support(d):
            _set(d, "hold", "emailed support@ in the last 90 days: human review, never asked "
                 "(when in doubt, don't send)")
            res.held_proof += 1
        elif d.request_id in asked:
            _set(d, "hold", "support already requested for this credit once: never re-ask; human review")
            res.held_reasked += 1
        elif d.user_id is not None and d.user_id in recent:
            _set(d, "defer", WINDOW_DEFER + "this user was asked in the last 24h; this row goes out with "
                 "the user's next batch")
            res.deferred_window += 1
    if max_ask_users_per_day is None:
        return
    # Daily cap on DISTINCT users asked (UTC day): users already asked today count;
    # a user admitted under the cap gets all of their rows in this run (one batch).
    asked_today = users_asked_since(db, now.strftime("%Y-%m-%dT00:00:00Z"))
    admitted: set[int] = set()
    for d in support:
        if d.decision != "support" or d.user_id is None:
            continue
        if d.user_id in asked_today or d.user_id in admitted:
            continue
        if len(asked_today) + len(admitted) < max_ask_users_per_day:
            admitted.add(d.user_id)
    for d in support:
        if d.decision != "support":
            continue
        if d.user_id is None:
            # No account on the row: nobody to ask, whatever the cap (it was mislabelled as
            # the cap being reached).
            _set(d, "defer", "no account user id on the request: nobody to ask; decided again when it has one")
            continue
        if d.user_id not in asked_today and d.user_id not in admitted:
            _set(d, "defer", ASK_CAP_DEFER + f"{max_ask_users_per_day} users/day already reached; "
                 "this row goes out on a later day")
            res.deferred_ask_cap += 1


def cap_at_write(db: sqlite3.Connection, res: "RunResult", support_ids: list[str], user_of: dict[str, int | None],
                 cap: int | None, send_at: datetime) -> list[str]:
    """Support ids that still fit the day's cap at send time (call under write_lock)."""
    if cap is None:
        return support_ids
    asked_today = users_asked_since(db, send_at.strftime("%Y-%m-%dT00:00:00Z"))
    # A user another run asked since this run decided is now inside their 24h
    # window: this run's rows for them wait for the next batch.
    asked_window = users_asked_since(db, utc(send_at - SUPPORT_WINDOW))
    admitted: set[int] = set()
    keep: list[str] = []
    for rid in support_ids:
        uid = user_of.get(rid)
        if uid is not None and uid in asked_window:
            record_outcome(db, res.run_id, rid, "support", "deferred:per_user_window", send_at)
            res.deferred_window += 1
            continue
        if uid is not None and (uid in admitted or len(asked_today) + len(admitted) < cap):
            admitted.add(uid)
            keep.append(rid)
            continue
        record_outcome(db, res.run_id, rid, "support", "deferred:daily_ask_cap", send_at)
        res.deferred_ask_cap += 1
    return keep


def paying_users(path: Path | None = None, now: datetime | None = None) -> tuple[frozenset[int] | None, str | None]:
    """(paying user ids, None) from the hourly export {generated_at, source,
    definition, count, counts_by_basis, ids: [int, ...]}, or (None, why) when
    paying status is UNKNOWN: the file is missing, unreadable, malformed
    (count != len(ids) included), older than 3h or dated in the future."""
    path = Path(path or PAYING_USERS_FILE)
    now = now or datetime.now(timezone.utc)
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        return None, f"{path} is missing"
    except (OSError, ValueError) as exc:
        return None, f"{path} is unreadable: {exc}"[:200]
    ids = data.get("ids") if isinstance(data, dict) else None
    count = data.get("count") if isinstance(data, dict) else None
    ts = parse_ts(data.get("generated_at")) if isinstance(data, dict) else None
    if (ts is None or not isinstance(ids, list) or not all(isinstance(i, int) and not isinstance(i, bool) for i in ids)
            or not isinstance(count, int) or isinstance(count, bool) or count != len(ids)):
        return None, f"{path} is malformed (want generated_at, integer ids and count == len(ids))"
    if now - ts > PAYING_USERS_MAX_AGE:
        return None, f"{path} is stale (generated {utc(ts)})"
    if ts - now > PAYING_USERS_MAX_SKEW:
        return None, f"{path} is dated in the future ({utc(ts)})"
    return frozenset(ids), None


PAID_SLA = timedelta(hours=24)


def paid_tier(user_id: Any, created_at: Any, paying: frozenset[int] | None, now: datetime) -> int:
    """Fable ruling 6 (credit-backlog-1019): 0 = paid and older than 24h, 1 = paid within
    24h, 2 = free (or paying status unknown)."""
    if paying is None or user_id not in paying:
        return 2
    ts = parse_ts(created_at)
    return 0 if ts is None or now - ts > PAID_SLA else 1


PROVISIONAL_KIND = "provisional_paid"
PROVISIONAL_MAX_PER_USER_PER_DAY = 20
# Fable review-audit-1021 / firstmate 125: the paid provisional approve arm is OFF while this file
# exists (hold / support / defer arms keep running). Undo: rm the file.
PROVISIONAL_PAID_SWITCH = Path(os.environ.get("CREDIT_TRUST_PROVISIONAL_PAID_DISABLED",
                                              "/etc/hydra/credit-trust-decide-provisional-paid.disabled"))


def catalog_verdicts(summary: str) -> dict[str, str]:
    """{claimed role: catalog verdict} from Decision.catalog ("Role=VERDICT,Role=VERDICT")."""
    out: dict[str, str] = {}
    for part in (summary or "").split(","):
        role, sep, verdict = part.rpartition("=")
        if sep and role.strip():
            out[role.strip()] = verdict.strip()
    return out


def provisional_anchor(d: "Decision", row: dict[str, Any], proof: "ProofOnFile | None") -> str:
    """E1 (Fable review-audit-1021): the positive anchor that lets the paid provisional arm fire,
    or "no:<why>". The catalog verdicts are the deterministic evidence summary."""
    verdicts = catalog_verdicts(d.catalog)
    others = sorted(r for r, v in verdicts.items() if v == "OTHERS_ONLY")
    if others:
        return (f"no:the catalog credits {', '.join(others)} to other people only (a contradiction signal): "
                "stage 2 web/doc check, never a provisional approval")
    if proof is None or proof.covers(d):
        return ("no:proof on file (or proof status unknown): the verifier reviews it; never a provisional approval")
    vd = row.get("verificationData") if isinstance(row.get("verificationData"), dict) else {}
    if vd.get("is_approved") is True:
        return "validator approved"
    confirmed = sorted(r for r, v in verdicts.items() if v == "CONFIRMED")
    if confirmed:
        return f"catalog confirms {', '.join(confirmed)}"
    return "no:no positive anchor (the validator declined and the catalog confirms no claimed role)"


def provisional_today_by_user(db: sqlite3.Connection, since: str) -> dict[int, int]:
    """Paid provisional approvals per user since `since` (apply mode, server-confirmed or
    attempted: every approve decision of that kind counts against the cap)."""
    return {int(u): n for u, n in db.execute(
        "SELECT user_id, COUNT(*) FROM decisions WHERE mode = 'apply' AND decision = 'approve' "
        "AND evidence_kind = ? AND decided_at >= ? AND user_id IS NOT NULL GROUP BY user_id",
        (PROVISIONAL_KIND, since))}


def provisional_written_since(db: sqlite3.Connection, since: str) -> dict[int, int]:
    """Paid provisional approvals per user whose approve WRITE was booked at or after `since`
    (decision_outcomes.at: the time the PUT returned), by any run, whatever the server
    answered except a deferral: the write-time count the per-user cap is enforced on."""
    return {int(u): n for u, n in db.execute(
        "SELECT d.user_id, COUNT(DISTINCT d.request_id) FROM decision_outcomes o JOIN decisions d "
        "ON d.request_id = o.request_id AND d.run_id = o.run_id WHERE o.action = 'approve' AND o.at >= ? "
        "AND o.outcome NOT LIKE 'deferred:%' AND o.outcome != 'shadow' AND d.evidence_kind = ? "
        "AND d.user_id IS NOT NULL GROUP BY d.user_id", (since, PROVISIONAL_KIND))}


def provisional_cap_at_write(db: sqlite3.Connection, res: "RunResult", ids: list[str], user_of: dict[str, int | None],
                             provisional: set[str], send_at: datetime) -> list[str]:
    """The approve ids that still fit PROVISIONAL_MAX_PER_USER_PER_DAY on the UTC day the batch
    is actually written (call under write_lock, before each batch; QA review of hydra#1275
    @7c1830a). The decision-time count uses the run's start; a run crossing midnight or two
    overlapping runs could otherwise both pass it. Trimmed rows get
    'deferred:provisional_user_cap' and are decided again on a later run."""
    if not provisional & set(ids):
        return ids
    written = provisional_written_since(db, send_at.strftime("%Y-%m-%dT00:00:00Z"))
    keep: list[str] = []
    for rid in ids:
        uid = user_of.get(rid)
        if rid in provisional and uid is not None:
            if written.get(uid, 0) >= PROVISIONAL_MAX_PER_USER_PER_DAY:
                record_outcome(db, res.run_id, rid, "approve", "deferred:provisional_user_cap", send_at)
                res.deferred += 1
                continue
            written[uid] = written.get(uid, 0) + 1
        keep.append(rid)
    return keep


def order_rows(rows: list[dict[str, Any]], paying: frozenset[int] | None,
               now: datetime | None = None) -> list[dict[str, Any]]:
    """PAID > 24h, then PAID < 24h, then FREE; oldest-created first inside each (Fable
    ruling 6). Paying status unknown = everyone oldest-first."""
    now = now or datetime.now(timezone.utc)
    def created(r: dict[str, Any]) -> str:
        return str(r.get("createdAt") or "")
    return sorted(rows, key=lambda r: (paid_tier(r.get("userId"), r.get("createdAt"), paying, now), created(r)))


def _set(d: Decision, decision: str, reason: str, *, doc_required: bool | None = None) -> Decision:
    """Every support request needs documents unless the caller says otherwise
    (only web NOT_FOUND: nothing was found against an ordinary claim)."""
    d.decision, d.reason = decision, reason
    d.doc_required = decision == "support" if doc_required is None else doc_required
    if decision != "approve" and d.evidence_kind == PROVISIONAL_KIND:
        # A later guard (server approval guard, proof on file, the caps) overrode the paid
        # provisional approval: the ledger must not record a provisional kind on an ask or a
        # hold (the board and reports read decisions.evidence_kind).
        d.evidence_kind = None
    return d


# ── spend guard for the paid fallback ───────────────────────────────────────
class CappedJudge:
    """Wraps the OpenRouter fallback judge with hard caps. Codex is $0; the
    fallback runs only for rows whose free sources are empty, and is the one
    path that costs money. A call is launched only if the reserve (the dearer
    of $0.05 and the dearest call this run) fits under BOTH the per-run cap and
    the captain's $25/day verifier web-judge cap, counted across the
    credit-review audit ledger and every decide run today. Over the cap the
    row gets ok=False -> it is DEFERRED, never sent a support request."""

    MIN_RESERVE = 0.05

    def __init__(self, inner: Any, *, run_cap_usd: float, daily_cap_usd: float, spent_today_usd: float):
        import threading
        self.inner = inner
        self.run_cap, self.daily_cap, self.spent_today = run_cap_usd, daily_cap_usd, spent_today_usd
        self.spent_run = 0.0
        self.reserved = 0.0
        self.dearest = self.MIN_RESERVE
        self.calls = 0
        self.refused = 0
        self._lock = threading.Lock()

    def judge(self, mode: str, evidence: dict[str, Any]) -> JudgeResult:
        with self._lock:
            reserve = max(self.MIN_RESERVE, self.dearest)
            committed = self.spent_run + self.reserved + reserve
            if committed > self.run_cap or self.spent_today + committed > self.daily_cap:
                self.refused += 1
                return JudgeResult(ok=False, provider="openrouter",
                                   error=f"OpenRouter cap reached (run ${self.spent_run:.2f}/{self.run_cap:.2f}, "
                                         f"today ${self.spent_today + self.spent_run:.2f}/{self.daily_cap:.2f})")
            self.reserved += reserve
        try:
            j = self.inner.judge(mode, evidence)
        finally:
            with self._lock:
                self.reserved -= reserve
        cost = j.cost_usd if isinstance(j.cost_usd, (int, float)) else reserve
        with self._lock:
            self.spent_run += cost
            self.dearest = max(self.dearest, cost)
            self.calls += 1
        if j.provider is None:
            j.provider = "openrouter"
        return j


def spent_today_usd(db: sqlite3.Connection, day_start: str) -> float:
    """Metered model spend today in this ledger: the credit-review audit/review
    rows plus decide's fallback calls."""
    ensure_schema(db)
    a = db.execute("SELECT COALESCE(SUM(cost_usd),0) FROM reviews WHERE reviewed_at >= ? AND model IS NOT NULL",
                   (day_start,)).fetchone()[0]
    b = db.execute("SELECT COALESCE(SUM(cost_usd),0) FROM decisions WHERE decided_at >= ?", (day_start,)).fetchone()[0]
    return float(a or 0) + float(b or 0)


# ── writes ──────────────────────────────────────────────────────────────────
Writer = Callable[[str, list[str], str], dict[str, Any]]
Readback = Callable[[str, list[str]], set[str]]


class WriteFailed(admin_api.AdminError):
    """A non-2xx answer. The server commits row by row, so ``body`` may still
    name rows it updated before failing."""

    def __init__(self, msg: str, body: Any = None):
        super().__init__(msg)
        self.body = body


def admin_writer(script: str | None = None, requester: str = REQUESTER,
                 automation_flag: str = "CREDIT_TRUST_DECIDE", timeout_s: int = 300) -> Writer:
    """PUT conditional-status through muso-admin-api.sh on the decider's admin login. The
    requester + env flag pick the wrapper's standing authorization and the
    X-Credit-Automation-Id core binds the grant to (decider by default; score-approve passes
    its own)."""
    script = script or os.environ.get("CREDIT_REVIEW_ADMIN_SCRIPT", admin_api.DEFAULT_ADMIN_SCRIPT)
    flags = {"CREDIT_TRUST_DECIDE": "0", "CREDIT_TRUST_SCORE_APPROVE": "0", automation_flag: "1"}

    def write(status: str, ids: list[str], expected: str) -> dict[str, Any]:
        body = json.dumps({"requestIds": ids, "status": status, "expectedStatus": expected},
                          separators=(",", ":"), sort_keys=True)
        env = {**os.environ, **flags, "MUSO_ADMIN_IDENTITY": ADMIN_IDENTITY}
        proc = subprocess.run(["bash", script, "--requester", requester, "call", "PUT", CONDITIONAL_PATH, body],
                              capture_output=True, text=True, timeout=timeout_s, check=False, env=env)
        if proc.returncode != 0:
            raise admin_api.AdminError(f"PUT failed rc={proc.returncode}: {proc.stderr.strip()[:300]}")
        resp = json.loads(proc.stdout)
        status_code = resp.get("http_status")
        if not isinstance(status_code, int) or not 200 <= status_code < 300:
            raise WriteFailed(f"PUT HTTP {status_code}: {json.dumps(resp.get('body'))[:300]}", resp.get("body"))
        return resp.get("body") or {}
    return write


def status_readback(script: str | None = None, timeout_s: int = 120) -> Readback:
    """The ids (of those asked) whose status in Postgres IS ``status`` now, via
    the read-only Trino verifier uvn-under30 uses after every write."""
    script = script or STATUS_VERIFY

    def read(status: str, ids: list[str]) -> set[str]:
        proc = subprocess.run(["bash", script, "--expected", status, "--ids", ",".join(ids)],
                              capture_output=True, text=True, timeout=timeout_s, check=False)
        if proc.returncode not in (0, 1):
            raise admin_api.AdminError(f"status readback rc={proc.returncode}: {proc.stderr.strip()[:200]}")
        try:
            report = json.loads(proc.stdout.strip().splitlines()[-1])
        except (ValueError, IndexError) as exc:
            raise admin_api.AdminError("status readback returned non-JSON") from exc
        mismatched = report.get("mismatched") if isinstance(report, dict) else None
        matched = report.get("matched") if isinstance(report, dict) else None
        if (report.get("expected") != status or not isinstance(mismatched, list) or not isinstance(matched, int)
                or not all(isinstance(m, dict) and isinstance(m.get("id"), str) for m in mismatched)
                or matched + len(mismatched) != len(set(ids))):
            raise admin_api.AdminError("status readback returned a malformed report")
        return set(ids) - {m["id"] for m in mismatched}
    return read


def refused_by_agent_guard(body: Any, chunk: list[str]) -> dict[str, str]:
    """{request id: reasons} when the answer is core-backend's
    agent_cannot_approve_declined refusal (nothing written), else {}."""
    if not isinstance(body, dict) or body.get("errorCode") != "agent_cannot_approve_declined":
        return {}
    ids = {str(i) for i in body.get("refusedRequestIds") or []} & set(chunk)
    reasons = {str(r.get("id")): ",".join(str(x) for x in r.get("reasons") or [])
               for r in body.get("refused") or [] if isinstance(r, dict)}
    return {i: reasons.get(i, "refused") for i in ids}


def write_chunk(writer: Writer, readback: Readback, status: str, chunk: list[str],
                expected: str, _retry: bool = False) -> tuple[dict[str, str], str | None]:
    """Per-row outcomes of one conditional PUT, and the write error if any. A
    failed or timed-out PUT may still have committed rows, so the outcome of a
    failed chunk comes from the server's updatedIds and a status readback; a
    row is recorded as written only when one of them says so."""
    try:
        return outcomes_of(writer(status, chunk, expected), chunk, status), None
    except (admin_api.AdminError, subprocess.TimeoutExpired, ValueError) as exc:
        err = str(exc)
        body = getattr(exc, "body", None)
        refused = refused_by_agent_guard(body, chunk)
        if refused and not _retry:
            # The server wrote NOTHING and named the rows it refuses: record those
            # as skipped with its reasons and send the rest of the batch once more.
            outs = {rid: f"skipped:agent_cannot_approve_declined:{why}"[:200] for rid, why in refused.items()}
            rest = [i for i in chunk if i not in refused]
            if not rest:
                return outs, None
            more, err2 = write_chunk(writer, readback, status, rest, expected, _retry=True)
            outs.update(more)
            return outs, err2
        data = body.get("data") if isinstance(body, dict) and isinstance(body.get("data"), dict) else body
        committed = {str(i) for i in (data.get("updatedIds") or [])} & set(chunk) if isinstance(data, dict) else set()
        rest = [i for i in chunk if i not in committed]
        prefix = "error:"
        if rest:
            try:
                committed |= readback(status, rest)
            except (admin_api.AdminError, subprocess.TimeoutExpired, OSError) as rexc:
                prefix = "error:unverified:"
                err = f"{err}; readback failed: {rexc}"
        return {rid: status if rid in committed else f"{prefix}{err}"[:200] for rid in chunk}, err


def outcomes_of(body: dict[str, Any], ids: list[str], status: str) -> dict[str, str]:
    data = body.get("data") if isinstance(body.get("data"), dict) else body
    updated = set(data.get("updatedIds") or [])
    reasons = {str(s.get("id")): str(s.get("reason")) for s in data.get("skipped") or [] if isinstance(s, dict)}
    return {i: status if i in updated else f"skipped:{reasons.get(i, 'not_reported')}" for i in ids}


class WriteLockBusy(admin_api.AdminError):
    """The shared credit-write lock was not acquired within the wait (nothing was written)."""


@contextmanager
def write_lock(wait_s: float = 600):
    WRITE_LOCK.parent.mkdir(parents=True, exist_ok=True)
    with WRITE_LOCK.open("a+", encoding="utf-8") as fh:
        deadline = time.monotonic() + wait_s
        while True:
            try:
                fcntl.flock(fh.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                if time.monotonic() > deadline:
                    raise WriteLockBusy("timed out waiting for the shared credit-write lock")
                time.sleep(1)
        try:
            yield
        finally:
            fcntl.flock(fh.fileno(), fcntl.LOCK_UN)


# ── the run ─────────────────────────────────────────────────────────────────
@dataclass
class RunResult:
    run_id: str
    mode: str
    scanned: int = 0
    approved: int = 0
    support: int = 0
    deferred: int = 0
    skipped_by_server: dict[str, int] = field(default_factory=dict)
    errors: int = 0
    web_checked: int = 0
    model_calls: int = 0
    paid_calls: int = 0
    jev_calls: int = 0
    held: int = 0
    support_candidates: int = 0
    held_proof: int = 0
    held_stage2_ask: int = 0
    held_reasked: int = 0
    deferred_window: int = 0
    deferred_ask_cap: int = 0
    deferred_proof_unknown: int = 0
    spend_usd: float = 0.0
    n1: int = 0
    write_errors: list[str] = field(default_factory=list)
    note: str = ""

    def line(self) -> str:
        sk = sum(self.skipped_by_server.values())
        skd = ", ".join(f"{k} {v}" for k, v in sorted(self.skipped_by_server.items()))
        verb = "would approve" if self.mode in ("shadow", "judge") else "approved (provisional)"
        verb2 = "would request support" if self.mode in ("shadow", "judge") else "support requested"
        jev = f", {self.jev_calls} Jev (Codex unavailable; support or defer only)" if self.jev_calls else ""
        return (f"credit-trust-decide {self.mode} run {self.run_id}: {self.scanned} held rows decided - "
                f"{self.approved} {verb}, {self.support} {verb2}, {self.deferred} deferred, {self.held} held for a human, "
                f"{sk} skipped by the server{f' ({skd})' if skd else ''}, {self.n1} one-person contradictions flagged, "
                f"{self.web_checked} web-checked ({self.model_calls - self.paid_calls} Codex calls at $0, {self.paid_calls} "
                f"OpenRouter fallback ${self.spend_usd:.2f}{jev}; the rest had no free source to cite), "
                f"{self.errors} evidence errors. Support asks: {self.support_candidates} before filters, "
                f"{self.held_proof} held for proof on file, "
                + (f"{self.held_stage2_ask} held for proof on file and handed to the stage-2 ask (gap-ask / "
                   "uvn-status), " if self.held_stage2_ask else "")
                + f"{self.held_reasked} held as already asked once, "
                f"{self.deferred_window} deferred for the per-user 24h window, {self.deferred_ask_cap} deferred by the "
                f"daily ask cap, {self.deferred_proof_unknown} deferred "
                f"(proof status unknown), {self.support} {'would be sent' if self.mode in ('shadow', 'judge') else 'sent'}."
                + (f" {self.note}" if self.note else "")
                + (f" WRITE ERRORS: {'; '.join(self.write_errors)[:400]}" if self.write_errors else ""))


def request_decision(req: dict[str, Any]) -> Decision:
    """A decision from the request row alone (no evidence was built)."""
    return Decision(request_id=str(req.get("id")), profile_id=str(req.get("profileId") or ""),
                    user_id=req.get("userId") if isinstance(req.get("userId"), int) else None,
                    track_id=str(req.get("trackId") or ""), track_title=str(req.get("spotifyTrackTitle") or ""),
                    claimed_roles=[str(c) for c in req.get("credits") or []], popularity=None, big_track=True,
                    decision="", reason="", request_created_at=_created(req))


def _created(req: dict[str, Any]) -> str | None:
    v = req.get("createdAt")
    return str(v) if v else None


def held_rows(admin: admin_api.Admin, skip: set[str], page_size: int = 200, max_pages: int = 40) -> list[dict[str, Any]]:
    """Every readable held row not decided recently (the list endpoint is
    updatedAt DESC; ``order_rows`` orders them)."""
    rows: list[dict[str, Any]] = []
    for page in range(1, max_pages + 1):
        items = admin_api.list_requests(admin, status=UNVERIFIED, limit=page_size, page=page)
        rows += [r for r in items if str(r.get("id")) not in skip]
        if len(items) < page_size:
            break
    return rows


def run(admin: admin_api.Admin, db: sqlite3.Connection, judge: Any, *, mode: str, policy: Policy,
        writer: Writer | None = None, readback: Readback | None = None, now: datetime | None = None,
        max_model_calls: int = 120,
        workers: int = 6, budget_s: int = 720, rows: list[dict[str, Any]] | None = None,
        clock: Callable[[], datetime] | None = None) -> RunResult:
    # judge (Fable [key=l11b], 2026-10-27): exactly shadow - no approval PUT, no support/ask write,
    # no provisional approval - but the ledger rows carry mode='judge' so stage 2 (which reads
    # only apply and judge "proof on file" holds) gets input while the approve path stays off.
    # No approval or ask reader counts a judge row: they select mode='apply'.
    if mode not in ("shadow", "apply", "judge"):
        raise ValueError("mode must be shadow, apply or judge")
    ensure_schema(db)
    # `clock` is the wall clock at the WRITE boundary (a run can cross UTC midnight
    # between deciding and sending); an injected `now` pins both for tests.
    clock = clock or ((lambda: now) if now is not None else (lambda: datetime.now(timezone.utc)))
    now = now or datetime.now(timezone.utc)
    t0 = time.monotonic()
    res = RunResult(run_id=now.strftime("%Y%m%dT%H%M%SZ") + "-" + uuid.uuid4().hex[:6], mode=mode)
    if mode == "apply":
        ok, why = registry_approved()
        if not ok:
            res.mode, res.note = "shadow", f"APPLY REFUSED ({why}): ran as shadow, nothing written."
            mode = "shadow"
    skip = skipped_this_run(db, now, mode)
    paying, unknown_why = paying_users(now=now)
    if unknown_why:
        log(f"decide: paying-user status unknown ({unknown_why}); oldest-first order, no paid priority")
    proof, proof_why = proof_on_file(now=now)
    if proof_why:
        log(f"decide: proof-on-file status unknown ({proof_why}); no support request is written this run")
    proof = with_intake(with_stage2(proof))
    batch = order_rows(rows if rows is not None else held_rows(admin, skip), paying, now)[:policy.max_rows_per_run]
    builder = EvidenceBuilder(admin, now=now)
    decisions: list[Decision] = []
    needs_web: list[tuple[dict[str, Any], Evidence, int]] = []
    for req in batch:
        if time.monotonic() - t0 > budget_s:
            break
        rejected = validator_rejected_rules(req.get("verificationData"))
        if rejected:
            decisions.append(_set(request_decision(req), "hold", f"validator reject rule fired ({', '.join(rejected)}): "
                                  "never approved or asked by automation; human review"))
            continue
        try:
            ev = builder.build(req)
        except (EvidenceIncomplete, admin_api.AdminError) as exc:
            res.errors += 1
            ev = None
            d = _set(request_decision(req), "defer", f"evidence unavailable: {exc}"[:300])
            if isinstance(exc.__cause__, admin_api.NotFound) or isinstance(exc, admin_api.NotFound):
                d.catalog_404, d.reason = True, (CATALOG_404 + d.reason)[:300]
            decisions.append(d)
            continue
        fp = footprint(db, ev.profile_id, {family_of(r) for r in ev.claimed_roles})
        d = pre_model(req, ev, policy, fp)
        if d is not None:
            decisions.append(d)
        else:
            needs_web.append((req, ev, fp))
    res.scanned = len(decisions) + len(needs_web)

    def judge_one(item):
        req, ev, fp = item
        try:
            j = judge.judge("review", ev.for_model()) if judge is not None else None
        except Exception as exc:  # noqa: BLE001 - one row's model failure defers that row only
            j = JudgeResult(ok=False, error=f"{type(exc).__name__}: {exc}"[:200])
        return with_web(req, ev, j, fp)

    web_items = needs_web[:max_model_calls]
    for req, ev, fp in needs_web[max_model_calls:]:
        decisions.append(_set(base_decision(req, ev), "defer", "web-check cap for this run reached; next run"))
    with ThreadPoolExecutor(max_workers=max(1, workers)) as pool:
        decisions += list(pool.map(judge_one, web_items))
    res.web_checked = len(web_items) if judge is not None else 0
    res.model_calls = sum(1 for d in decisions if d.provider in ("codex", "openrouter"))
    res.jev_calls = sum(1 for d in decisions if d.provider == "jev")
    paid = [d for d in decisions if d.provider == "openrouter" and d.cost_usd is not None]
    res.paid_calls, res.spend_usd = len(paid), sum(d.cost_usd or 0 for d in paid)

    for d in decisions:
        d.paid_priority = None if paying is None else d.user_id in paying
        if d.catalog_404 and d.decision == "defer":
            n = catalog_404_defers(db, d.request_id, mode)
            if n >= CATALOG_404_MAX_DEFERS:
                _set(d, "support", f"catalog_unreadable: the admin catalog still answers 404 after {n} deferred runs; "
                     "a human checks the catalog and the claim (never approved or denied on a 404)")

    # Fable ruling 4 (credit-backlog-1019, firstmate 072): trust yet verify for PAID users.
    # A small/medium track (big tracks never reach here: pre_model asks for proof) whose
    # web check found nothing against the claim (NOT_FOUND: no contradiction, no red flag,
    # no validator conflict, no editorial-role rule; each of those returned before the web
    # check) is provisionally approved instead of asked. The user gets the verify note
    # (credit live + a no-threat document request). Amendment (firstmate 073, captain rule
    # 10-15: deletes must confirm removal at Spotify/Tidal or prove a different profile; no new
    # lowering classes): NO day-30 auto-removal; unconfirmed after 30 days the row goes to the
    # Ops review list (provisional_review), still live. Capped at
    # PROVISIONAL_MAX_PER_USER_PER_DAY per user per UTC day. Free users stay on the ask path.
    #
    # E1 (Fable review-audit-1021): "paid + nothing contradicts" is not evidence. The arm fires
    # only with a POSITIVE anchor - the validator approved the row, or the catalog CONFIRMS at
    # least one claimed role (cited in the reason) - and never when the catalog credits any
    # claimed role to other people only (OTHERS_ONLY = a contradiction signal: stage 2 web/doc),
    # nor for a user with proof on file (that goes to the verifier, never to a provisional
    # approval). Measured 10-20/21: 230 approvals, all validator-declined, 128 OTHERS_ONLY.
    req_by_id = {str(r.get("id")): r for r in batch}
    prov_today = provisional_today_by_user(db, now.strftime("%Y-%m-%dT00:00:00Z"))
    provisional_paid_off = PROVISIONAL_PAID_SWITCH.exists()
    for d in decisions:
        if provisional_paid_off:
            break
        if not (d.decision == "support" and d.web_verdict == "NOT_FOUND" and d.paid_priority
                and not d.big_track and d.conflict is None and not d.n1):
            continue
        anchor = provisional_anchor(d, req_by_id.get(d.request_id) or {}, proof)
        if anchor.startswith("no:"):
            d.reason = (d.reason + "; " if d.reason else "") + f"not provisionally approved: {anchor[3:]}"
            continue
        if d.user_id is not None and prov_today.get(d.user_id, 0) >= PROVISIONAL_MAX_PER_USER_PER_DAY:
            _set(d, "defer", f"paid provisional approvals for this user reached {PROVISIONAL_MAX_PER_USER_PER_DAY} "
                 "today; next UTC day")
            continue
        d.evidence_kind = PROVISIONAL_KIND
        _set(d, "approve", f"trust yet verify (Fable ruling 4 + E1 review-audit-1021): paid user, small/medium track, "
             f"{anchor}, no claimed role credited to others only, no red flag; provisional approval with a no-threat "
             "document request; never auto-removed: unconfirmed after 30 days it goes to the Ops review list (still live)")
        if d.user_id is not None:
            prov_today[d.user_id] = prov_today.get(d.user_id, 0) + 1

    # Ruling 6 also orders the asks: paid > 24h first, so the daily cap admits them first.
    decisions.sort(key=lambda d: (paid_tier(d.user_id, (req_by_id.get(d.request_id) or {}).get("createdAt"),
                                            paying, now), str((req_by_id.get(d.request_id) or {}).get("createdAt") or "")))

    needs_proof = doc_required_ids(db)
    for d in decisions:
        if d.decision == "approve" and d.request_id.lower() in needs_proof:
            ref = proof.approved_refs.get(d.request_id.lower()) if proof is not None else None
            if ref:
                d.proof_id = ref
            elif proof is None:
                _set(d, "defer", f"{PROOF_UNKNOWN} ({proof_why}): documentation required for this credit and "
                     "whether a proof is on file is unknown; retried")
                res.deferred_proof_unknown += 1
            else:
                _set(d, "hold", "documentation required for this credit and no approved proof is on file for it: "
                     "never approved without a recorded proof id; human review")

    # Approvals core-backend would refuse are never sent (T12 agent guard): a
    # stored popularity outside 1..59 / client-sourced metadata needs documents
    # (support, like any big track); a server proof requirement needs the
    # claimant's proof (support); anything else goes to a human.
    req_of = {str(r.get("id")): r for r in batch}
    for d in decisions:
        if d.decision != "approve" or d.request_id not in req_of:
            continue
        refusal = server_approval_refusal(req_of[d.request_id])
        if not refusal:
            continue
        why = ",".join(refusal)
        # firstmate 036: a stored popularity of 0 is NOT evidence of a big track
        # (it is just unattributed), so those rows go to a human, never a proof ask.
        if "popularity_unattributable" not in refusal and (
                refusal[0] == "proof_required"
                or set(refusal) <= {"popularity_unknown", "big_track", "client_sourced_metadata"}):
            _set(d, "support", f"server approval guard would refuse ({why}): documentation required")
        else:
            _set(d, "hold", f"server approval guard would refuse ({why}): human review")

    # Daily per-user approval cap.
    counts = approvals_today_by_user(db, now.strftime("%Y-%m-%dT00:00:00Z"))
    for d in decisions:
        if d.decision == "approve" and d.user_id is not None:
            if counts.get(d.user_id, 0) >= policy.max_approvals_per_user_per_day:
                _set(d, "defer", f"user reached {policy.max_approvals_per_user_per_day} approvals today")
            else:
                counts[d.user_id] = counts.get(d.user_id, 0) + 1

    filter_support(db, decisions, res, proof, proof_why, now, policy.max_ask_users_per_day)
    if mode != "apply":
        for d in decisions:
            d.doc_required = False
    transition = proof_status_transition(db, mode, proof_why)
    if transition:
        res.note = (res.note + " " if res.note else "") + transition

    # Ledger BEFORE any write.
    for d in decisions:
        record_decision(db, res.run_id, mode, d, now)
        res.n1 += 1 if d.n1 else 0
    res.deferred = sum(1 for d in decisions if d.decision == "defer")
    res.held = sum(1 for d in decisions if d.decision == "hold")

    approve_ids = [d.request_id for d in decisions if d.decision == "approve"]
    support_ids = [d.request_id for d in decisions if d.decision == "support"]
    if mode in ("shadow", "judge"):
        res.approved, res.support = len(approve_ids), len(support_ids)
        for rid in approve_ids + support_ids:
            record_outcome(db, res.run_id, rid, "approve" if rid in approve_ids else "support", "shadow", now)
        return res
    writer = writer or admin_writer()
    readback = readback or status_readback()
    user_of = {d.request_id: d.user_id for d in decisions}

    def write_ids(action: str, status: str, chunk: list[str]) -> None:
        outs, err = write_chunk(writer, readback, status, chunk, UNVERIFIED)
        # Outcomes are booked at the time the PUT (and its readback) RETURNED, not
        # when it started: a request in flight across UTC midnight counts on the
        # later day. The pre-PUT check already fitted it into the earlier day, so
        # neither day can exceed the cap (the later day is counted conservatively).
        done_at = clock()
        if err is not None:
            res.write_errors.append(f"{action} batch of {len(chunk)}: {err}"[:200])
        for rid, out in outs.items():
            record_outcome(db, res.run_id, rid, action, out, done_at)
            if out == status:
                if action == "approve":
                    res.approved += 1
                else:
                    res.support += 1
            elif out.startswith("skipped:"):
                k = out.split(":", 1)[1]
                res.skipped_by_server[k] = res.skipped_by_server.get(k, 0) + 1

    provisional = {d.request_id for d in decisions if d.decision == "approve" and d.evidence_kind == PROVISIONAL_KIND}
    with write_lock():
        # The per-user provisional cap is re-checked here, under the lock, against what is
        # already WRITTEN on the UTC day of each batch (approvals booked by any run).
        pending_ap = list(approve_ids)
        while pending_ap:
            chunk, pending_ap = pending_ap[:BATCH], pending_ap[BATCH:]
            chunk = provisional_cap_at_write(db, res, chunk, user_of, provisional, clock())
            if chunk:
                write_ids("approve", APPROVED, chunk)
        # The daily ask cap is checked at the SUPPORT-write boundary, under the
        # shared write lock, on the UTC day each support batch is actually sent:
        # the clock is read immediately before every batch, and if the day has
        # rolled over since the last check the remaining rows are re-capped
        # against the new day. Overlapping runs, a run crossing midnight, or
        # approval writes that cross midnight can never push a day past the cap.
        # Rows trimmed here get 'deferred:daily_ask_cap' (or
        # 'deferred:per_user_window') and are retried later.
        pending = list(support_ids)
        checked_day: str | None = None
        while pending:
            at = clock()
            day = at.strftime("%Y-%m-%d")
            if day != checked_day:
                pending = cap_at_write(db, res, pending, user_of, policy.max_ask_users_per_day, at)
                checked_day = day
                if not pending:
                    break
            chunk, pending = pending[:BATCH], pending[BATCH:]
            write_ids("support", UVN, chunk)
    return res


# ── explain / export / revert ───────────────────────────────────────────────
def explain(db: sqlite3.Connection, request_id: str) -> list[dict[str, Any]]:
    ensure_schema(db)
    db.row_factory = sqlite3.Row
    out = []
    for r in db.execute("SELECT * FROM decisions WHERE request_id = ? ORDER BY id", (request_id,)):
        row = dict(r)
        row["web_urls"] = json.loads(row["web_urls"] or "[]")
        row["outcomes"] = [dict(o) for o in db.execute(
            "SELECT at, action, outcome FROM decision_outcomes WHERE request_id = ? AND run_id = ? ORDER BY id",
            (request_id, r["run_id"]))]
        out.append(row)
    return out


def export(db: sqlite3.Connection, since: str) -> Iterable[dict[str, Any]]:
    ensure_schema(db)
    db.row_factory = sqlite3.Row
    for r in db.execute("SELECT * FROM decisions WHERE decided_at >= ? ORDER BY id", (since,)):
        row = dict(r)
        row["web_urls"] = json.loads(row["web_urls"] or "[]")
        last = db.execute("SELECT outcome FROM decision_outcomes WHERE request_id = ? AND run_id = ? ORDER BY id DESC LIMIT 1",
                          (r["request_id"], r["run_id"])).fetchone()
        row["server_outcome"] = last["outcome"] if last else None
        yield row


def run_approvals(db: sqlite3.Connection, run_id: str) -> list[str]:
    ensure_schema(db)
    return [r[0] for r in db.execute(
        "SELECT DISTINCT request_id FROM decision_outcomes WHERE run_id = ? AND action = 'approve' AND outcome = 'approved'",
        (run_id,))]


def revert(db: sqlite3.Connection, run_id: str, *, apply: bool, writer: Writer | None = None,
           readback: Readback | None = None) -> dict[str, Any]:
    """Take back a run's provisional approvals (approved -> unverified, the
    only legal backward transition). The server lets only a NAMED HUMAN take
    an approved credit back (firstmate decision 023, requireRemovalAuthority),
    so from the agent token this is refused per profile; the refusal and the
    exact id list are reported for the human path (admin UI, or #10310)."""
    ids = run_approvals(db, run_id)
    out: dict[str, Any] = {"run_id": run_id, "approved_ids": ids, "applied": False}
    if not apply or not ids:
        return out
    # approved -> unverified hides the credit: the captain's live Spotify+Tidal rule (2026-10-23,
    # firstmate 104/105/106) applies before any write.
    dsp_gate.require("decider revert (approved -> unverified hides the credit)")
    writer = writer or admin_writer()
    readback = readback or status_readback()
    results: dict[str, str] = {}
    with write_lock():
        for i in range(0, len(ids), BATCH):
            chunk = ids[i:i + BATCH]
            results.update(write_chunk(writer, readback, UNVERIFIED, chunk, APPROVED)[0])
    for rid, o in results.items():
        record_outcome(db, f"revert-{run_id}", rid, "revert", o)
    out.update(applied=True, results=results)
    return out


def as_json(d: Decision) -> dict[str, Any]:
    return asdict(d)


PROVISIONAL_REVIEW_DAYS = 30


def provisional_review(db: sqlite3.Connection, proof: "ProofOnFile | None", *, now: datetime | None = None,
                       days: int = PROVISIONAL_REVIEW_DAYS) -> list[dict[str, Any]]:
    """The Ops review list (Fable ruling 4 as amended, firstmate 073): paid provisional
    approvals the server confirmed at least `days` ago with no document on file for the
    credit or its user. Read-only; the credits stay live. Removal, if ever, follows the
    normal proof rule with notice and reason, never this list. Proof status unknown =
    everyone is listed (a reviewer decides, nothing is removed)."""
    now = now or datetime.now(timezone.utc)
    cutoff = utc(now - timedelta(days=days))
    rows = [(*r, "provisional_unconfirmed_30d") for r in db.execute(
        "SELECT d.request_id, d.user_id, d.profile_id, d.track_id, d.track_title, d.claimed_roles, o.at "
        "FROM decision_outcomes o JOIN decisions d ON d.request_id = o.request_id AND d.run_id = o.run_id "
        "WHERE o.action = 'approve' AND o.outcome = 'approved' AND d.evidence_kind = ? AND o.at <= ? "
        "ORDER BY o.at", (PROVISIONAL_KIND, cutoff))]
    # A user's other decider approvals that rode in that provisional credit's no-deadline v1
    # note (one note per user, #1257) have no removal date either: listed the same way.
    seen = {str(r[0]) for r in rows}
    riders: set[str] = set()
    try:
        for (ids,) in db.execute("SELECT request_ids_json FROM verify_messages WHERE campaign = 'verify-live' "
                                 "AND kind = 'initial' AND status = 'sent' AND removal_day IS NULL AND created_at <= ?",
                                 (cutoff,)):
            riders |= {str(x) for x in json.loads(ids or "[]")} - seen
    except sqlite3.OperationalError:
        riders = set()   # no verify ledger in this database: no v1 notes to read
    for rid in sorted(riders):
        r = db.execute(
            "SELECT d.request_id, d.user_id, d.profile_id, d.track_id, d.track_title, d.claimed_roles, o.at "
            "FROM decision_outcomes o JOIN decisions d ON d.request_id = o.request_id AND d.run_id = o.run_id "
            "WHERE o.action = 'approve' AND o.outcome = 'approved' AND d.request_id = ? ORDER BY o.at LIMIT 1",
            (rid,)).fetchone()
        if r:
            rows.append((*r, "v1_note_unconfirmed_30d"))
    out = []
    for rid, uid, pid, tid, title, roles, at, flag in rows:
        class _D:
            pass
        probe = _D()
        probe.user_id = uid
        probe.request_id = str(rid)
        if proof is not None and proof.covers(probe):
            continue
        out.append({"request_id": rid, "user_id": uid, "profile_id": pid, "track_id": tid, "track_title": title,
                    "claimed_roles": roles, "approved_at": at, "flag": flag,
                    "action": "Ops review: still live; any removal follows the normal proof rule with notice + reason"})
    return out

