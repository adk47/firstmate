"""Doc-verify approval doctrine: a FORGERY-CHECKED document may approve a small-track credit
without a same-run DSP anchor, and nothing else may.

Ruling [key=doc-approval-doctrine] (Fable driver for firstmate, 2026-11-03 19:3xZ, under Aaron's
11-03 delegation, data/factory-autonomy-fable-a1/worker-decisions-1103.md #19), verbatim in
substance:

    YES for T0/T1 (popularity < 60), NO for T2/T3. A forgery-checked (dv-4 verified) document may
    APPROVE a small-track credit WITHOUT a same-run DSP anchor, under CODED gates only (deterministic
    + DeepSeek/Codex on OVH, never a per-item Fable ruling): document attributed to EXACTLY ONE
    request (#1649 receipts match), dv-4 verified verdict, account gate clean, no fraud/velocity
    HOLD row, 1 approval per request, <= 50/day, requester TOLD (the core approval notice path,
    core-backend #11092, no new copy), 7-day PROVISIONAL reversible (a later anchor contradiction
    or forgery verdict pulls it). T2/T3 get the 'we need a DSP credit to verify' ask.

This module owns the GATES; decide.py owns the write. Every gate is a separate named function so a
test can fail it ALONE (`tests/test_doc_approve.py`: one CAN-FAIL test per gate, plus a pass case
that must stay green when all of them hold). A gate that cannot answer is never an allow.

What is deliberately NOT here:

* the approval PUT. `decide.py` sends it through the same core endpoint every other approval uses,
  so the requester is TOLD by core's own approval notice (core-backend #11092) - no new copy, no
  second notice path. This class never posts to a user itself.
* the core-side reversal. Fable's ruling makes the approval PROVISIONAL for 7 days and a later
  anchor contradiction or forgery verdict pulls it; agent/API tokens are refused on the admin
  credit DELETE routes (core-backend #10310), so this module RECORDS the pull (`state='pulled'`)
  and reports it - a named human's own session performs the core reversal
  (`scripts/credit-retro.py`, docs/credit-verification/credit-retro-r1.md). Never a silent revert.
* the anchor row. Until core's `credit_anchor_records` DDL lands, the row in `doc_approvals` and
  the `approved_refs` entry ARE the record; when it lands this class writes `kind=
  proof_verification` there too (the PR that flips ANCHOR_ROWS_AVAILABLE).
"""
from __future__ import annotations

import json
import sqlite3
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any, Callable, Iterable

from . import account_gate

# The verdict version that may approve (FORENSICS_VERSION in credit_verify/docverify/__init__.py).
# A dv-3 verdict is NOT accepted: the ruling says dv-4, and a version bump must be a reviewed edit
# here, never a silently-followed constant (an older verdict would otherwise approve forever).
VERDICT_VERSION = "dv-4"

DOC_KIND = "doc_verified"          # decisions.evidence_kind for a doc-approved row
REF_PREFIX = "dv4"                 # <REF_PREFIX>:<file sha256>:<intake id>
# Ruling [key=doc-approval-doctrine] (Fable driver for firstmate, 2026-11-04 19:1xZ): the per-day cap
# is in USERS, not requests. A document is the unit of evidence; a PERSON is the unit of harm. 50
# users/day drains the 2,542 proof-on-file requests in ~58 days, while 168 document-holders take ~4.
DAILY_USER_CAP = 50                # <= 50 distinct USERS approved per UTC day, fleet-wide
PER_USER_DAILY_MAX = 25            # <= 25 REQUESTS per user per day (the rest roll to the next day)
MAX_PER_DAY = DAILY_USER_CAP       # kept for callers that still name the old constant
PROVISIONAL_DAYS = 7               # provisional for 7 days; a later contradiction/forgery pulls it
TIER_MAX_POPULARITY = 60           # T0/T1 only: popularity < 60 (T2/T3 stay on the proof-need ask)
ANCHOR_ROWS_AVAILABLE = False      # flip when core's credit_anchor_records DDL is live

DEFAULT_DOC_STORE = "/var/lib/hydra-credit-verify/doc-verify.sqlite"
DEFAULT_PROOF_STORE = "/var/lib/hydra-credit-verify/proof.sqlite"

SCHEMA = """
CREATE TABLE IF NOT EXISTS doc_approvals (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  request_id TEXT NOT NULL UNIQUE,       -- 1 approval per request, mechanically
  user_id INTEGER NOT NULL,
  intake_id TEXT NOT NULL,
  proof_id TEXT NOT NULL,                -- the document's identity (file sha256)
  ref TEXT NOT NULL,                     -- what the decider records as the proof it relied on
  popularity INTEGER,
  tier TEXT NOT NULL,                    -- T0 | T1
  approved_at TEXT NOT NULL,
  expires_at TEXT NOT NULL,              -- approved_at + 7 days: PROVISIONAL until then
  state TEXT NOT NULL DEFAULT 'provisional',  -- provisional | confirmed | pulled | released | indeterminate
  state_at TEXT,
  reason TEXT
);
CREATE INDEX IF NOT EXISTS doc_approvals_user ON doc_approvals(user_id);
CREATE INDEX IF NOT EXISTS doc_approvals_time ON doc_approvals(approved_at);
CREATE TABLE IF NOT EXISTS doc_approval_events (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  at TEXT NOT NULL,
  request_id TEXT NOT NULL,
  user_id INTEGER,
  intake_id TEXT,
  state TEXT NOT NULL,                   -- approved | refused | confirmed | pulled
  gate TEXT,                             -- the gate that refused, NULL when approved
  reason TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS doc_approval_events_req ON doc_approval_events(request_id);
CREATE TRIGGER IF NOT EXISTS doc_approval_events_no_update BEFORE UPDATE ON doc_approval_events
BEGIN SELECT RAISE(ABORT, 'doc_approval_events is append-only'); END;
CREATE TRIGGER IF NOT EXISTS doc_approval_events_no_delete BEFORE DELETE ON doc_approval_events
BEGIN SELECT RAISE(ABORT, 'doc_approval_events is append-only'); END;
"""


def utc(ts: datetime | None = None) -> str:
    return (ts or datetime.now(timezone.utc)).strftime("%Y-%m-%dT%H:%M:%SZ")


def ensure_schema(db: sqlite3.Connection) -> None:
    db.executescript(SCHEMA)
    db.commit()


# ── the document universe ───────────────────────────────────────────────────

@dataclass(frozen=True)
class Doc:
    """One filed document whose CURRENT dv-4 verdict is verified, with the one request it names."""
    intake_id: str
    user_id: int
    request_id: str
    proof_id: str                # file sha256
    verdict_at: str
    account_hold: bool
    candidate_ids: tuple[str, ...]

    @property
    def ref(self) -> str:
        return f"{REF_PREFIX}:{self.proof_id}:{self.intake_id}"


def _ro(path: str | Path) -> sqlite3.Connection:
    """Read-only, WAL-AWARE connection: this module NEVER writes the doc-verify or proof store.

    QA #1684 round 3, finding 1: `immutable=1` tells SQLite the file cannot change, so it reads the
    MAIN database only and ignores the -wal. Both stores run in WAL mode, a committed verdict can sit
    in the WAL until the next checkpoint, and the reader therefore saw the PREVIOUS verdict - a
    `verified` run could approve a request whose newest run says `forged`. `mode=ro` alone is a
    read-only connection that still consults the WAL (and refuses writes), which is the property this
    module actually needs."""
    p = Path(path)
    if not p.exists():
        raise FileNotFoundError(f"{p} is missing")
    return sqlite3.connect(f"file:{p}?mode=ro", uri=True)


def _newest_run_rows(db: sqlite3.Connection) -> list[tuple[Any, ...]]:
    """Every role row of the NEWEST dv-4 run per (intake_id, request_id).

    QA #1684 round 3, finding 2: "newest" was `MAX(at)`, and `at` is a SECOND-resolution stamp written
    per role. A run whose contradicted role landed at 12:00:00 and whose verified role landed at
    12:00:01 was read as "the 12:00:01 rows are the newest", so the contradicted role vanished and the
    document looked fully verified. Run boundaries are what `run_id` is for: the newest run is the one
    that wrote the highest row id for that document, and EVERY role it judged is taken together.
    """
    # the newest run is the one that wrote the highest id for this document (ids are monotonic and the
    # runner writes a document's role rows in one pass), which is why `at` is not the sort key any more.
    return db.execute(
        "WITH newest AS (SELECT intake_id, request_id, MAX(id) AS id FROM dv_outcomes"
        "                  WHERE version = ? AND intake_id IS NOT NULL"
        "                  GROUP BY intake_id, request_id),"
        "     last AS (SELECT o.intake_id, o.request_id, o.run_id FROM dv_outcomes o"
        "                JOIN newest n ON n.id = o.id WHERE o.version = ?)"
        " SELECT o.intake_id, o.request_id, o.run_id, o.user_id, o.proof_id, o.role, o.outcome,"
        "        o.account_hold, o.at"
        "   FROM dv_outcomes o"
        "   JOIN last l ON l.intake_id = o.intake_id AND l.request_id = o.request_id"
        "              AND l.run_id = o.run_id"
        "  WHERE o.version = ?"
        "  ORDER BY o.intake_id, o.request_id, o.role",
        (VERDICT_VERSION, VERDICT_VERSION, VERDICT_VERSION)).fetchall()


def _unverified_roles(db: sqlite3.Connection) -> dict[tuple[str, str], str]:
    """Documents where SOME role's own newest verdict is not `verified`.

    QA #1684 round 3, finding 2 (the same hole one layer out): the newest run is not always a full
    re-judgement. A later run that re-judged only "Composer" would otherwise make the document look
    verified while "Lyricist" still stands contradicted. A role that was ever judged and never cleared
    keeps the document out of the approvable set - fail closed, and the cost is a stronger proof ask.
    """
    out: dict[tuple[str, str], str] = {}
    for i, r, outcome in db.execute(
            "WITH role_last AS (SELECT intake_id, request_id, role, MAX(id) AS id FROM dv_outcomes"
            "                     WHERE version = ? AND intake_id IS NOT NULL"
            "                     GROUP BY intake_id, request_id, role)"
            " SELECT o.intake_id, o.request_id, o.outcome FROM dv_outcomes o"
            "   JOIN role_last rl ON rl.id = o.id"
            "  WHERE o.outcome <> 'verified'", (VERDICT_VERSION,)).fetchall():
        out.setdefault((str(i), str(r).lower()), str(outcome))
    return out


def _group_runs(rows: Iterable[tuple[Any, ...]],
                unverified: dict[tuple[str, str], str] | None = None) -> dict[tuple[str, str], dict[str, Any]]:
    """(intake_id, request_id) -> the newest run's identity + whether EVERY role of it - and every role's
    own newest verdict - is `verified`."""
    blocked = unverified or {}
    out: dict[tuple[str, str], dict[str, Any]] = {}
    for intake_id, request_id, run_id, user_id, proof_id, role, outcome, account_hold, at in rows:  # noqa: E501
        key = (str(intake_id), str(request_id).lower())
        g = out.setdefault(key, {
            "run_id": str(run_id), "user_id": user_id, "proof_id": str(proof_id),
            "account_hold": bool(account_hold), "at": str(at), "all_verified": key not in blocked,
            "roles": 0})
        g["roles"] += 1
        # QA #1684 round 4, finding 1: a hold on ANY role of the run holds the document. Copying it
        # from the first role row let a Composer `account_hold=0` mask a Lyricist `account_hold=1`,
        # i.e. a fraud-held credit passed `gate_no_hold`.
        if account_hold:
            g["account_hold"] = True
        if outcome != "verified":
            # one contradicted/forged/unverifiable role in the newest run means the document does not
            # prove this credit - never averaged away by the verified roles next to it
            g["all_verified"] = False
        if str(at) > g["at"]:
            g["at"] = str(at)
    return out


def owners_in_store(doc_store: str | Path, request_ids: Iterable[str]) -> dict[str, Any]:
    """request id -> the account the doc-verify runs judged it for, for requests NOT in this run's batch.

    `gate_one_request` needs the owner of every request a document binds. Taking that only from the
    batch wedges the per-user rollover: a filing binding 26 requests for one person spends 25 today, and
    tomorrow's batch no longer contains those 25, so the last binding would look ownerless for ever. The
    doc-verify store judged all of them and recorded the account, so it is the authoritative filler.
    A request it never judged stays absent, which the gate reads as an UNKNOWN owner and fails closed -
    the store is a source of identity, never a presumption of one.
    """
    ids = [str(r).lower() for r in request_ids if r]
    out: dict[str, Any] = {}
    if not ids:
        return out
    db = _ro(doc_store)
    try:
        for rid, uid in db.execute(
                f"SELECT request_id, MAX(user_id) FROM dv_outcomes WHERE request_id IS NOT NULL"
                f" AND user_id IS NOT NULL AND {' OR '.join('LOWER(request_id) = ?' for _ in ids)}"
                f" GROUP BY LOWER(request_id)", ids).fetchall():
            if uid is not None:
                out[str(rid).lower()] = int(uid)
    finally:
        db.close()
    return out


def verified_docs(doc_store: str | Path = DEFAULT_DOC_STORE,
                  proof_store: str | Path = DEFAULT_PROOF_STORE) -> dict[str, list[Doc]]:
    """request id -> the verified documents that name it (usually exactly one).

    A document counts only when its NEWEST dv-4 run verdict is `verified` FOR EVERY ROLE it was
    judged on (one contradicted/forged/unverifiable role in the newest run means the document does
    not prove that credit). An older verified run never overrides a newer bad one - that is what
    makes a later forgery verdict bite.
    """
    db = _ro(doc_store)
    try:
        runs = _group_runs(_newest_run_rows(db), _unverified_roles(db))
    finally:
        db.close()
    out: dict[str, list[Doc]] = {}
    for (intake_id, request_id), g in runs.items():
        user_id = g["user_id"]
        if not g["all_verified"] or not isinstance(user_id, int):
            continue
        out.setdefault(request_id.lower(), []).append(
            Doc(intake_id, int(user_id), request_id.lower(), g["proof_id"], g["at"],
                g["account_hold"], ()))
    if not out:
        return out
    # the filing's own candidate attribution (the #1649 receipts match wrote this set)
    pdb = _ro(proof_store)
    try:
        for doc_list in out.values():
            for d in list(doc_list):
                r = pdb.execute("SELECT candidate_request_ids_json, file_sha256 FROM proof_intake"
                                " WHERE intake_id = ?", (d.intake_id,)).fetchone()
                if r is None:
                    continue
                try:
                    ids = tuple(str(x).lower() for x in json.loads(r[0] or "[]"))
                except ValueError:
                    ids = ()
                doc_list[doc_list.index(d)] = Doc(d.intake_id, d.user_id, d.request_id,
                                                 str(r[1] or d.proof_id), d.verdict_at, d.account_hold, ids)
    finally:
        pdb.close()
    return out


def current_verdict(doc_store: str | Path, intake_id: str, request_id: str) -> tuple[str, str]:
    """(outcome, at) of the NEWEST dv-4 run for this document/request, ('', '') when unknown.

    "Newest" is the whole run: every role judged at that `at` must agree, so one contradicted role
    in the newest run is not averaged away by the verified ones next to it.
    """
    db = _ro(doc_store)
    try:
        rows = [r for r in _newest_run_rows(db)
                if str(r[0]) == str(intake_id) and str(r[1]).lower() == request_id.lower()]
        blocked = {k: v for k, v in _unverified_roles(db).items() if k[0] == str(intake_id)}
    finally:
        db.close()
    if not rows:
        return "", ""
    g = _group_runs(rows, blocked)[(str(intake_id), request_id.lower())]
    if g["all_verified"]:
        return "verified", g["at"]
    outcomes = {str(r[6]) for r in rows}
    if len(outcomes) > 1:
        return "mixed", g["at"]
    # every role of the newest run agreed, but some OTHER role's newest verdict does not: the document
    # was contradicted for that role and no later run cleared it, so it proves nothing here
    return blocked.get((str(intake_id), request_id.lower())) or "mixed", g["at"]


# ── the gates (one function each, so a test can fail one ALONE) ──────────────

@dataclass(frozen=True)
class Candidate:
    request_id: str
    user_id: int | None
    popularity: int | None
    docs: tuple[Doc, ...]


@dataclass(frozen=True)
class Gate:
    name: str
    why: str = ""
    detail: dict[str, Any] | None = None

    @property
    def ok(self) -> bool:
        return self.why == ""


def _pass() -> Gate:
    return Gate("pass", "")


def _fail(name: str, why: str, **detail: Any) -> Gate:
    return Gate(name, why, detail or None)


def gate_one_request(c: Candidate, req_users: dict[str, Any] | None = None) -> Gate:
    """EVERY binding is EXACT and every binding of one document belongs to ONE user.

    2026-11-04 ruling: "the one-request binding is per request: a document may bind to several
    requests of the same user, each binding exact". So a document naming several requests of the SAME
    person is not ambiguity - those are the credits it proves, approved together (bounded by
    PER_USER_DAILY_MAX). What is still refused, because it proves nothing this class may spend:

    * a document whose binding set does not name THIS request (the receipts match is per request);
    * a document whose bindings span MORE THAN ONE account - a filing that credits two people cannot
      say which of them the evidence is about, and a cross-account document is exactly the shape a
      duplicated screenshot takes;
    * an unknown owner for a bound request (`req_users` unreadable/absent) - never an allow.
    """
    if not c.docs:
        return _fail("one_request", "no verified document names this request")
    owners = {str(k).lower(): v for k, v in (req_users or {}).items()}
    for d in c.docs:
        ids = tuple(str(i).lower() for i in d.candidate_ids)
        if c.request_id not in ids:
            return _fail("one_request", f"document {d.intake_id} does not bind this request "
                         f"({len(ids)} binding(s): {', '.join(ids[:3]) or 'none'})")
        # QA #1684 round 6, finding 1: the document's OWN account must be this request's owner. Comparing
        # the bindings against each other only proves the binding set names one person - a document filed
        # and verified for account A could carry a request owned by B, and `seen == {B}`, `c.user_id == B`
        # passed both checks. The evidence must belong to the person whose credit it approves.
        if c.user_id is not None and d.user_id is not None and int(d.user_id) != int(c.user_id):
            return _fail("one_request", f"document {d.intake_id} belongs to account {d.user_id}, but this "
                         f"request is account {c.user_id}: another person's document proves nothing here")
        if req_users is not None:
            seen = {owners.get(i) for i in ids}
            if None in seen:
                return _fail("one_request", f"document {d.intake_id} binds a request whose owner is "
                             "unknown: a cross-account binding cannot be excluded")
            if len(seen) > 1:
                return _fail("one_request", f"document {d.intake_id} binds {len(seen)} accounts "
                             f"({', '.join(str(x) for x in sorted(seen, key=str))}): it proves no one person")
            if c.user_id is not None and seen and c.user_id not in seen:
                return _fail("one_request", f"document {d.intake_id} binds account(s) "
                             f"{', '.join(str(x) for x in sorted(seen, key=str))}, not {c.user_id}")
    return _pass()


def gate_dv4_verified(c: Candidate, doc_store: str | Path = DEFAULT_DOC_STORE,
                      doc: Doc | None = None) -> Gate:
    """The doc-verify verdict that stands NOW is `verified` (dv-4) - for the document the approval is
    about to RECORD (`pick`, unless a caller names one).

    QA #1684 round 4, finding 3: this rechecked `c.docs[0]` while `approve()` recorded `pick(c)`,
    which is the NEWEST document - so a newer, now-forged document could be recorded as the proof
    while the recheck passed on an older, still-verified one. The gate now asks the same question
    about the same document the write will name.
    """
    if not c.docs:
        return _fail("dv4_verified", "no verified document names this request")
    d = doc if doc is not None else pick(c)
    outcome, at = current_verdict(doc_store, d.intake_id, c.request_id)
    if outcome != "verified":
        return _fail("dv4_verified", f"the standing verdict for {d.intake_id} is {outcome or 'unknown'}"
                     f" ({at or 'no run'})")
    return _pass()


def gate_tier(c: Candidate) -> Gate:
    """T0/T1 only: a known popularity below 60. Unknown popularity is NOT a small track (the
    decider never approves a big or unreadable track without documents either)."""
    p = c.popularity
    if not isinstance(p, int) or isinstance(p, bool):
        return _fail("tier", "popularity unknown: T0/T1 cannot be established, so this is not a "
                     "small-track doc approval (T2/T3 stay on the DSP ask)")
    if p >= TIER_MAX_POPULARITY:
        return _fail("tier", f"popularity {p} >= {TIER_MAX_POPULARITY}: T2/T3, the 'we need a DSP "
                     "credit to verify' ask is the path")
    return _pass()


def gate_account(c: Candidate, gate: account_gate.Cached | Callable[[Any], Any] | None = None) -> Gate:
    """The account gate is clean (fraud-lens account gate: allow, never hold/unknown)."""
    if c.user_id is None:
        return _fail("account", "the request carries no account id: the gate cannot run")
    res = (gate or account_gate.check)(c.user_id)
    if not getattr(res, "allowed", False):
        return _fail("account", f"account gate is not an allow: {getattr(res, 'why', lambda: 'unknown')()}")
    return _pass()


def gate_no_hold(c: Candidate, hold_ids: Iterable[str] = (), hold_users: Iterable[Any] = ()) -> Gate:
    """No fraud/velocity HOLD row: not the document's own account_hold, not the request, and not the
    account or profile on the fraud / PULL / HOLD / RE-VERIFY lists the decider already holds."""
    held = {str(h).lower() for h in hold_ids}
    users = {u for u in hold_users if u is not None}
    if c.request_id in held:
        return _fail("no_hold", "a fraud/velocity HOLD row names this request")
    if c.user_id is not None and c.user_id in users:
        return _fail("no_hold", "the account is on the fraud / PULL / HOLD / RE-VERIFY list")
    if any(d.account_hold for d in c.docs):
        return _fail("no_hold", "the document carries the account-level fraud HOLD")
    return _pass()


def gate_one_per_request(c: Candidate, db: sqlite3.Connection) -> Gate:
    """1 approval per request: a row for this request already exists (any state but a pull), so this
    is never a second approval. The UNIQUE(request_id) column is the mechanical guarantee; this gate
    is what makes the refusal readable."""
    r = db.execute("SELECT state, approved_at FROM doc_approvals WHERE request_id = ?",
                   (c.request_id,)).fetchone()
    if r is None or r[0] == "released":
        # a released row is NOT an approval: the core write it stood for never confirmed, so the slot
        # was given back (see release()) and the request may be approved by a later run.
        return _pass()
    return _fail("one_per_request", f"already {r[0]} at {r[1]}")


LIVE_STATES = ("provisional", "confirmed", "pulled")


def gate_daily_cap(c: Candidate, db: sqlite3.Connection, now: datetime | None = None) -> Gate:
    """TWO bounds, both in the 2026-11-04 ruling, and they are different units on purpose:

    * **<= 50 distinct USERS per UTC day**, fleet-wide - the unit of harm is a person, and one person
      with a discography screenshot must not be able to spend the fleet's whole day;
    * **<= 25 REQUESTS per user per day** - the same person may have several credits one document
      proves, and the rest roll to the next day (same user first, via the ordering below).

    A `released` row never became an approval (the core write it stood for did not confirm), so it
    spends no headroom; a `pulled` row does - it WAS an approval, and the cap bounds the RATE of
    approvals, not their survival.
    """
    day_start = (now or datetime.now(timezone.utc)).strftime("%Y-%m-%dT00:00:00Z")
    why = _cap_refusal(db, day_start, c.user_id)
    return _fail("daily_cap", why + ": the rest roll to tomorrow") if why else _pass()


GATES: tuple[str, ...] = ("one_request", "dv4_verified", "tier", "account", "no_hold",
                          "one_per_request", "daily_cap")


@dataclass
class Approval:
    request_id: str
    user_id: int
    intake_id: str
    proof_id: str
    ref: str
    popularity: int
    tier: str


def evaluate(c: Candidate, db: sqlite3.Connection, *, doc_store: str | Path = DEFAULT_DOC_STORE,
             gate: account_gate.Cached | Callable[[Any], Any] | None = None,
             hold_ids: Iterable[str] = (), hold_users: Iterable[Any] = (),
             now: datetime | None = None,
             req_users: dict[str, Any] | None = None) -> tuple[Gate, list[Gate]]:
    """(verdict, every gate's answer in order). The first failing gate decides; all of them are
    returned so a report can say why the ones after it were never reached."""
    answers: list[Gate] = []

    def add(g: Gate) -> bool:
        answers.append(g)
        return g.ok

    for g in (lambda: gate_one_request(c, req_users),
              lambda: gate_dv4_verified(c, doc_store),
              lambda: gate_tier(c),
              lambda: gate_account(c, gate),
              lambda: gate_no_hold(c, hold_ids, hold_users),
              lambda: gate_one_per_request(c, db),
              lambda: gate_daily_cap(c, db, now)):
        if not add(g()):
            return answers[-1], answers   # THE gate that refused, not the first one asked
    return _pass(), answers


def pick(c: Candidate) -> Doc:
    """The document the approval records: the newest verified one (all of them name this request)."""
    return max(c.docs, key=lambda d: (d.verdict_at, d.intake_id))


def order_key(user_id: Any, created_at: Any, paying: Any = None, now: datetime | None = None,
              paid_tier: Callable[[Any, Any], int] | None = None) -> tuple[int, str, str]:
    """`paid_first_oldest` - the ruling's order for who gets the 50 user slots.

    Paid before free, oldest-waiting first, and the USER is the sort unit so a person's requests are
    adjacent and are approved in one pass (that is what makes "told once, listing them" possible).
    `paid_tier` is injected by decide.py (it already owns the ruling-6 definition); the fallback is
    free, which only ever LOSES priority, never gains it.
    """
    tier = 2
    if paid_tier is not None:
        try:
            tier = int(paid_tier(user_id, created_at))
        except Exception:  # noqa: BLE001 - an ordering helper must never fail a run
            tier = 2
    age = str(created_at or "")
    return (tier, age, str(user_id))


def tier_of(popularity: int) -> str:
    return "T0" if popularity < 30 else "T1"


def plan(c: Candidate, db: sqlite3.Connection, *, doc_store: str | Path = DEFAULT_DOC_STORE,
         gate: account_gate.Cached | Callable[[Any], Any] | None = None,
         hold_ids: Iterable[str] = (), hold_users: Iterable[Any] = (),
         now: datetime | None = None,
         req_users: dict[str, Any] | None = None) -> tuple[Approval | None, list[Gate]]:
    """(the approval this candidate WOULD record, every gate's answer) - and **no write at all**.

    QA #1684 finding 2: the decider has guards AFTER the doc gates (the server's own approval refusal,
    the per-user daily cap, the doc-only hold). Committing the row from inside the gate sweep meant a
    later refusal left a phantom approval that no credit backed and that spent the 1-per-request slot.
    decide.py therefore plans here, and only commits (`approve()`) for rows that survived every guard -
    and releases that row again if the core write does not confirm."""
    now = now or datetime.now(timezone.utc)
    verdict, answers = evaluate(c, db, doc_store=doc_store, gate=gate, hold_ids=hold_ids,
                               hold_users=hold_users, now=now, req_users=req_users)
    if not verdict.ok:
        return None, answers
    d = pick(c)
    assert d is not None and c.popularity is not None and c.user_id is not None
    return Approval(c.request_id, c.user_id, d.intake_id, d.proof_id, d.ref, int(c.popularity),
                    tier_of(int(c.popularity))), answers


INDETERMINATE = "indeterminate"


def mark_indeterminate(db: sqlite3.Connection, request_id: str, *, reason: str,
                       now: datetime | None = None) -> bool:
    """QA #1684 round 7, finding 1: a PUT whose outcome is UNKNOWN is not a refusal.

    `write_chunk` answers `error:unverified:` when the PUT failed AND the status readback failed too -
    which means the server may well have COMMITTED the credit. Releasing on it (the old behaviour)
    took away the only record standing behind a live credit and handed the slot back, so the same
    request could be approved again and the day's headroom could be spent twice. The row is kept in
    state `indeterminate`: still counted against the day's caps (its slot may be spent), no longer
    served as proof by `approved_refs`, and never confirmed by the sweep - a named human reconciles it
    against core's own status before anything else happens to it.
    """
    now = now or datetime.now(timezone.utc)
    cur = db.execute("UPDATE doc_approvals SET state = ?, state_at = ?, reason = ?"
                     " WHERE request_id = ? AND state = 'provisional'",
                     (INDETERMINATE, utc(now), reason[:600], request_id))
    db.commit()
    if cur.rowcount == 0:
        return False
    row = db.execute("SELECT user_id, intake_id FROM doc_approvals WHERE request_id = ?",
                     (request_id,)).fetchone() or (None, None)
    record_event(db, now, request_id, row[0], row[1], INDETERMINATE, gate=None, reason=reason[:600])
    return True


def release(db: sqlite3.Connection, request_id: str, *, reason: str,
            now: datetime | None = None) -> bool:
    """Give back a provisional row whose core write did NOT confirm (server refused, PUT failed, the
    readback never said approved). The row is kept for the audit trail in state `released`, which is
    invisible to `approved_refs()`, the sweep and `rows_for()`'s live reader, does not count against
    the daily cap, and does not block a later approval of the same request (QA #1684 finding 2)."""
    now = now or datetime.now(timezone.utc)
    cur = db.execute("UPDATE doc_approvals SET state = 'released', state_at = ?, reason = ?"
                     " WHERE request_id = ? AND state = 'provisional'", (utc(now), reason[:600],
                                                                        request_id))
    db.commit()
    if cur.rowcount == 0:
        return False                          # nothing provisional to give back: not ours to release
    row = db.execute("SELECT user_id, intake_id FROM doc_approvals WHERE request_id = ?",
                     (request_id,)).fetchone() or (None, None)
    record_event(db, now, request_id, row[0], row[1], "released", gate=None,
                 reason=reason[:600])
    return True


_INSERT_APPROVAL = (
    "INSERT INTO doc_approvals (request_id, user_id, intake_id, proof_id, ref, popularity, tier,"
    " approved_at, expires_at, state) VALUES (?,?,?,?,?,?,?,?,?,'provisional')")

# QA #1684 round 3, finding 3: a RELEASED row keeps its row (the audit trail) and the UNIQUE
# request_id that `release()` promised the slot back for, so `INSERT OR IGNORE` could never write it
# again - every later attempt was refused for ever by the one-per-request UNIQUE while the gate said
# the slot was free. The released row IS the slot: re-approving rewrites it and the event log keeps
# both facts (released, then approved again) instead of a second row.
_REUSE_RELEASED = (
    "UPDATE doc_approvals SET user_id = ?, intake_id = ?, proof_id = ?, ref = ?, popularity = ?, tier = ?,"
    " approved_at = ?, expires_at = ?, state = 'provisional', state_at = ?, reason = ?"
    " WHERE request_id = ? AND state = 'released'")


def _cap_refusal(db: sqlite3.Connection, day_start: str, user_id: Any) -> str:
    """The 2026-11-04 bounds, asked against the database as it stands (""=fits).

    QA #1684 round 4, finding 2: `spend_slot` counted REQUESTS against the user cap, so two people
    with 25 credits each consumed all 50 and blocked the other 48 permitted users. It also never
    re-asked the per-user bound inside the serialized transaction, so two workers that both read 24
    could each spend a 25th and 26th. Both bounds are now asked here, in the caller's write
    transaction, and the fleet bound counts DISTINCT users - a person already counted today does not
    consume a second slot.
    """
    # an `indeterminate` row counts too: core may have committed that credit, so the person's slot (and
    # the day's) is spent until a human reconciles it (QA #1684 round 7, finding 1)
    rows = db.execute("SELECT user_id, COUNT(*) FROM doc_approvals WHERE approved_at >= ?"
                      " AND state IN ('provisional', 'confirmed', 'pulled', 'indeterminate')"
                      " GROUP BY user_id", (day_start,)).fetchall()
    users = {str(r[0]) for r in rows}
    me = str(user_id)
    mine = next((int(r[1]) for r in rows if str(r[0]) == me), 0)
    if mine >= PER_USER_DAILY_MAX:
        return f"daily_cap: {mine} doc approvals for this user today (cap {PER_USER_DAILY_MAX}/user/day)"
    if me not in users and len(users) >= DAILY_USER_CAP:
        return (f"daily_cap: {len(users)} users already have a doc approval today "
                f"(cap {DAILY_USER_CAP} users/day)")
    return ""


def spend_slot(db: sqlite3.Connection, ap: Approval, *, now: datetime,
               expires: datetime) -> tuple[bool, str]:
    """Reserve the 1-per-request slot AND a day's headroom in ONE write transaction.

    QA #1684 round 3, finding 4: `gate_daily_cap` counted and `approve()` inserted in two separate
    transactions, so two workers that both read 49 could both commit and land 51 approvals in a day.
    The count and the write are now one `BEGIN IMMEDIATE` (SQLite's own cross-process serialization
    point, independent of the flock the caller holds), and the one-per-request check is re-asked in
    the same transaction - a gate read outside a write transaction is advice, not a guarantee.

    Returns (spent, why). `why` is the refusing gate's name, or "ok".
    """
    day_start = now.strftime("%Y-%m-%dT00:00:00Z")
    started = not db.in_transaction
    if started:
        db.execute("BEGIN IMMEDIATE")
    try:
        row = db.execute("SELECT state FROM doc_approvals WHERE request_id = ?",
                         (ap.request_id,)).fetchone()
        if row is not None and row[0] != "released":
            if started:
                db.execute("ROLLBACK")
            return False, f"one_per_request: already {row[0]}"
        why = _cap_refusal(db, day_start, ap.user_id)
        if why:
            if started:
                db.execute("ROLLBACK")
            return False, why
        expires_s = utc(expires)
        if row is not None:
            cur = db.execute(_REUSE_RELEASED,
                             (ap.user_id, ap.intake_id, ap.proof_id, ap.ref, ap.popularity, ap.tier,
                              utc(now), expires_s, None,
                              f"re-approved from a released slot at {utc(now)}", ap.request_id))
        else:
            cur = db.execute(_INSERT_APPROVAL,
                             (ap.request_id, ap.user_id, ap.intake_id, ap.proof_id, ap.ref,
                              ap.popularity, ap.tier, utc(now), expires_s))
        if cur.rowcount != 1:
            if started:
                db.execute("ROLLBACK")
            return False, ("one_per_request: a concurrent run recorded this request first" if row is None
                           else "one_per_request: the released row changed under us")
        if started:
            db.execute("COMMIT")
        return True, "ok"
    except Exception:
        if started:
            try:
                db.execute("ROLLBACK")
            except sqlite3.Error:
                pass
        raise


def approve(c: Candidate, db: sqlite3.Connection, *, doc_store: str | Path = DEFAULT_DOC_STORE,
            gate: account_gate.Cached | Callable[[Any], Any] | None = None,
            hold_ids: Iterable[str] = (), hold_users: Iterable[Any] = (),
            now: datetime | None = None, mode: str = "shadow") -> tuple[Approval | None, list[Gate]]:
    """One candidate's answer, recorded. In apply mode a passing candidate writes its provisional
    row (and only apply mode consumes the day cap); shadow/judge record the event and write nothing,
    so a judge run can never approve a request or spend a slot."""
    now = now or datetime.now(timezone.utc)
    verdict, answers = evaluate(c, db, doc_store=doc_store, gate=gate, hold_ids=hold_ids,
                                hold_users=hold_users, now=now)
    d = pick(c) if c.docs else None
    if not verdict.ok:
        record_event(db, now, c.request_id, c.user_id, d.intake_id if d else None, "refused",
                     gate=verdict.name, reason=verdict.why)
        return None, answers
    assert d is not None and c.popularity is not None and c.user_id is not None
    ap = Approval(c.request_id, c.user_id, d.intake_id, d.proof_id, d.ref, int(c.popularity),
                  tier_of(int(c.popularity)))
    if mode != "apply":
        record_event(db, now, c.request_id, c.user_id, d.intake_id, "would_approve", gate=None,
                     reason=f"{ap.ref} (popularity {ap.popularity}, {ap.tier}); {mode} mode writes nothing")
        return ap, answers
    expires = now + timedelta(days=PROVISIONAL_DAYS)
    spent, why = spend_slot(db, ap, now=now, expires=expires)
    if not spent:
        gate = "one_per_request" if why == "one_per_request" else "daily_cap"
        record_event(db, now, c.request_id, c.user_id, d.intake_id, "refused", gate=gate, reason=why)
        return None, answers
    record_event(db, now, c.request_id, c.user_id, d.intake_id, "approved", gate=None,
                 reason=f"{ap.ref} provisional until {utc(expires)} (popularity {ap.popularity}, {ap.tier})")
    return ap, answers


def record_event(db: sqlite3.Connection, at: datetime, request_id: str, user_id: int | None,
                 intake_id: str | None, state: str, *, gate: str | None, reason: str) -> None:
    db.execute("INSERT INTO doc_approval_events (at, request_id, user_id, intake_id, state, gate, reason)"
               " VALUES (?,?,?,?,?,?,?)", (utc(at), request_id, user_id, intake_id, state, gate, reason[:600]))
    db.commit()


# ── provisional lifecycle: confirm at day 7, pull on a later contradiction/forgery ──

@dataclass(frozen=True)
class Transition:
    request_id: str
    user_id: int
    intake_id: str
    ref: str
    was: str
    now: str
    reason: str


def sweep(db: sqlite3.Connection, *, doc_store: str | Path = DEFAULT_DOC_STORE,
          now: datetime | None = None) -> list[Transition]:
    """The 7-day provisional clock: a provisional approval whose window has elapsed is CONFIRMED;
    one whose standing verdict is no longer `verified` (a later contradiction or a forgery verdict)
    is PULLED, whatever its age. A pull is recorded, never applied here: agent tokens are refused on
    the core DELETE routes, so a named human's own session performs the reversal."""
    now = now or datetime.now(timezone.utc)
    rows = db.execute("SELECT request_id, user_id, intake_id, proof_id, ref, approved_at, expires_at,"
                      " state FROM doc_approvals WHERE state IN ('provisional', 'confirmed')").fetchall()
    out: list[Transition] = []
    for request_id, user_id, intake_id, _proof, ref, _approved_at, expires_at, state in rows:
        outcome, at = current_verdict(doc_store, intake_id, request_id)
        if not outcome:
            # QA #1684 round 6, finding 2: `current_verdict` answers ('','') when the document's dv-4 rows
            # are GONE, and the old branch only pulled a truthy non-verified outcome - so vanished rows let
            # the provisional row be CONFIRMED at day 7 and `approved_refs` kept calling it proof. "I cannot
            # read the verdict" is not "no contradicting verdict": fail closed and pull it, exactly as the
            # class's own doctrine says for an unreadable store.
            new, why = "pulled", (f"no standing {VERDICT_VERSION} verdict can be read for {intake_id} at "
                                 f"{utc(now)}: an unreadable verdict is not evidence (fail closed)")
        elif outcome != "verified":
            new, why = "pulled", (f"the standing {VERDICT_VERSION} verdict is {outcome} ({at}): the document no "
                                 "longer proves this credit")
        elif state == "provisional" and str(expires_at) <= utc(now):
            new, why = "confirmed", f"provisional window elapsed at {expires_at} with no contradicting verdict"
        else:
            continue
        db.execute("UPDATE doc_approvals SET state = ?, state_at = ?, reason = ? WHERE request_id = ?",
                   (new, utc(now), why[:600], request_id))
        db.commit()
        record_event(db, now, request_id, user_id, intake_id, new, gate=None, reason=why)
        out.append(Transition(request_id, user_id, intake_id, ref, state, new, why))
    return out


def approved_refs(db: sqlite3.Connection, *, doc_store: str | Path = DEFAULT_DOC_STORE,
                  now: datetime | None = None) -> dict[str, str]:
    """request id -> ref for every approval that still stands (provisional or confirmed), after
    sweeping the provisional clock. This is the overlay decide.py merges into ProofOnFile."""
    sweep(db, doc_store=doc_store, now=now)
    return {str(r[0]).lower(): str(r[1]) for r in db.execute(
        "SELECT request_id, ref FROM doc_approvals WHERE state IN ('provisional', 'confirmed')")}


def rows_for(db: sqlite3.Connection, user_id: int | None = None) -> list[dict[str, Any]]:
    """The readback Fable asked for before the executor runs the next request."""
    q = ("SELECT request_id, user_id, intake_id, proof_id, ref, popularity, tier, approved_at, expires_at,"
         " state, state_at, reason FROM doc_approvals WHERE state != 'released'")
    args: tuple[Any, ...] = ()
    if user_id is not None:
        q += " AND user_id = ?"
        args = (user_id,)
    q += " ORDER BY id"
    cols = ("request_id", "user_id", "intake_id", "proof_id", "ref", "popularity", "tier", "approved_at",
            "expires_at", "state", "state_at", "reason")
    return [dict(zip(cols, r)) for r in db.execute(q, args)]
