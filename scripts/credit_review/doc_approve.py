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
import os
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
# Fable R22 (2026-11-05 20:2xZ, data/verify-sla-driver-fable-d2/ruling-R22-doc-only-approval.md) is the
# ruling this module implements: document-only approval for T0/T1 under EIGHT coded guards, never a
# per-item ruling. Guard 5 names the registered automation scope, so the registry key and this constant
# are the same string - a rename in one place without the other is a dormant class, not a silent one.
SCOPE = "document_small_track"     # R22 guard 5: the registered automation scope name
# R22 guard 7 caps, in the units the ruling names: 1/request (UNIQUE), 5/user/day, 10/profile/day,
# 50 users/day. The 2026-11-04 ruling's 25/user is SUPERSEDED by R22's 5/user.
DAILY_USER_CAP = 50                # <= 50 distinct USERS approved per UTC day, fleet-wide
PER_USER_DAILY_MAX = 5             # R22 guard 7: <= 5 REQUESTS per user per day (rest roll to tomorrow)
PER_PROFILE_DAILY_MAX = 10         # R22 guard 7: <= 10 approvals per PROFILE per day
MAX_PER_DAY = DAILY_USER_CAP       # kept for callers that still name the old constant
PROVISIONAL_DAYS = 7               # R22 guard 6: provisional for 7 days, NEVER lowered
PROVISIONAL_MIN_DAYS = 7           # R22 guard 6: the floor; a smaller value is a bug, not a knob
AUDIT_DAYS = 14                    # R22 guard 8: 100% audit for 14 days after the first approval
CLEAN_CLAIMANT_DAYS = 30           # R22 guard 4: a clean claimant >= 30 days, or a prior approval
TIER_MAX_POPULARITY = 60           # T0/T1 only: popularity < 60 (T2/T3 stay on the proof-need ask)
ANCHOR_ROWS_AVAILABLE = False      # flip when core's credit_anchor_records DDL is live
# R22 guard 8: ONE reversal freezes the class. The marker is a file so a human can see it, and so a
# freeze survives a deploy (the deploy rsync overwrites /opt/hydra, never /var/lib).
DEFAULT_FREEZE_PATH = "/var/lib/hydra-credit-verify/doc-approve.frozen"
FREEZE_PATH = Path(os.environ.get("CREDIT_DOC_APPROVE_FREEZE", DEFAULT_FREEZE_PATH))

DEFAULT_DOC_STORE = "/var/lib/hydra-credit-verify/doc-verify.sqlite"
DEFAULT_PROOF_STORE = "/var/lib/hydra-credit-verify/proof.sqlite"

SCHEMA = """
CREATE TABLE IF NOT EXISTS doc_approvals (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  request_id TEXT NOT NULL UNIQUE,       -- 1 approval per request, mechanically
  user_id INTEGER NOT NULL,
  profile_id TEXT,                       -- R22 guard 7: the per-profile daily cap
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
CREATE TABLE IF NOT EXISTS doc_approval_audit (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  at TEXT NOT NULL,
  request_id TEXT NOT NULL,
  user_id INTEGER NOT NULL,
  profile_id TEXT,
  intake_id TEXT NOT NULL,
  ref TEXT NOT NULL,
  popularity INTEGER,
  tier TEXT NOT NULL,
  h3 TEXT,                              -- the forensics verdict the approval relied on
  checks_json TEXT,                     -- every independent cross-check, verbatim
  issuer_type TEXT,
  notice TEXT,                          -- how the requester is told (core's own approval notice)
  scope TEXT NOT NULL                   -- R22 guard 5: document_small_track
);
CREATE INDEX IF NOT EXISTS doc_approval_audit_time ON doc_approval_audit(at);
CREATE TRIGGER IF NOT EXISTS doc_approval_audit_no_update BEFORE UPDATE ON doc_approval_audit
BEGIN SELECT RAISE(ABORT, 'doc_approval_audit is append-only'); END;
CREATE TRIGGER IF NOT EXISTS doc_approval_audit_no_delete BEFORE DELETE ON doc_approval_audit
BEGIN SELECT RAISE(ABORT, 'doc_approval_audit is append-only'); END;
-- R22 guard 8: the freeze is recorded in the LEDGER as well as in a marker file. The file is what a
-- human sees and what survives a deploy; the row is what makes the freeze un-ignorable, because a
-- marker write that fails (a full disk, a read-only /var/lib) must not leave the class approving.
CREATE TABLE IF NOT EXISTS doc_approval_freeze (
  id INTEGER PRIMARY KEY CHECK (id = 1),   -- one row, ever
  at TEXT NOT NULL,
  reason TEXT NOT NULL
);
"""


def utc(ts: datetime | None = None) -> str:
    return (ts or datetime.now(timezone.utc)).strftime("%Y-%m-%dT%H:%M:%SZ")


def ensure_schema(db: sqlite3.Connection) -> None:
    """Create the tables, then MIGRATE a ledger that predates a column.

    QA #1800 finding 2: `doc_approvals` shipped without `profile_id`, so on a real ledger every new
    query and write naming that column failed. `CREATE TABLE IF NOT EXISTS` does not add a column to
    an existing table, so the column is added explicitly when it is missing.
    """
    db.executescript(SCHEMA)
    have = {str(r[1]) for r in db.execute("PRAGMA table_info(doc_approvals)").fetchall()}
    if "profile_id" not in have:
        db.execute("ALTER TABLE doc_approvals ADD COLUMN profile_id TEXT")
    db.commit()


_REQUIRED_TABLES = ("doc_approvals", "doc_approval_events", "doc_approval_audit",
                    "doc_approval_freeze")


def schema_ready(db: sqlite3.Connection) -> str:
    """Empty when the ledger already carries every table and column the class needs, else WHY not.

    QA #1800 r13 finding 5: `cmd_doc_approvals` called `ensure_schema()` BEFORE the `--dry-run`
    branch, so the promised 0-write arming pass ran `ALTER TABLE doc_approvals ADD COLUMN
    profile_id` (and created the audit/freeze tables and their triggers) on a production ledger that
    predated them. A dry run that migrates the database is not a dry run, and the arming measurement
    would have been taken against a schema the run itself changed.

    This is the read-only half: it answers the same question `ensure_schema` acts on, and NEVER
    writes. A ledger that is not ready is refused by name rather than silently migrated.
    """
    try:
        have = {str(r[1]) for r in db.execute("PRAGMA table_info(doc_approvals)").fetchall()}
    except sqlite3.Error as exc:
        return f"the ledger could not be read ({exc})"
    if not have:
        return ("the ledger has no doc_approvals table yet: run `credit-review.py doc-approvals`"
                " once (without --dry-run) to create it")
    if "profile_id" not in have:
        return ("the ledger predates profile_id: run `credit-review.py doc-approvals` once"
                " (without --dry-run) to migrate it, then re-run the dry run")
    for t in _REQUIRED_TABLES:
        r = db.execute("SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?",
                       (t,)).fetchone()
        if r is None:
            return (f"the ledger has no {t} table yet: run `credit-review.py doc-approvals` once"
                    " (without --dry-run) to create it")
    return ""


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


def _attribute_filings(out: dict[str, list[Doc]], proof_store: str | Path) -> None:
    """Fill each Doc's `candidate_ids` from the filing's own attribution (the #1649 receipts match)."""
    if not out:
        return
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


def _docs_by_request(doc_store: str | Path, proof_store: str | Path, *,
                     verified_only: bool) -> dict[str, list[Doc]]:
    """request id -> the documents that name it, from the doc-verify store's NEWEST run per role."""
    db = _ro(doc_store)
    try:
        runs = _group_runs(_newest_run_rows(db), _unverified_roles(db))
    finally:
        db.close()
    out: dict[str, list[Doc]] = {}
    for (intake_id, request_id), g in runs.items():
        user_id = g["user_id"]
        if not isinstance(user_id, int):
            continue
        if verified_only and not g["all_verified"]:
            continue
        out.setdefault(request_id.lower(), []).append(
            Doc(intake_id, int(user_id), request_id.lower(), g["proof_id"], g["at"],
                g["account_hold"], ()))
    _attribute_filings(out, proof_store)
    return out


def verified_docs(doc_store: str | Path = DEFAULT_DOC_STORE,
                  proof_store: str | Path = DEFAULT_PROOF_STORE) -> dict[str, list[Doc]]:
    """request id -> the verified documents that name it (usually exactly one).

    A document counts only when its NEWEST dv-4 run verdict is `verified` FOR EVERY ROLE it was
    judged on (one contradicted/forged/unverifiable role in the newest run means the document does
    not prove that credit). An older verified run never overrides a newer bad one - that is what
    makes a later forgery verdict bite.
    """
    return _docs_by_request(doc_store, proof_store, verified_only=True)


def document_universe(doc_store: str | Path = DEFAULT_DOC_STORE,
                      proof_store: str | Path = DEFAULT_PROOF_STORE
                      ) -> tuple[dict[str, list[Doc]], dict[str, list[Doc]]]:
    """(every document that names a request, the requests at least one VERIFIED document names).

    `verified_docs` is the WRITE's view: what an approval may consider. The arming MEASUREMENT needs
    the whole filed backlog instead, because a dry run built on `verified_docs` silently drops every
    document whose newest dv-4 run is contradicted or unverifiable - and every filing that never got
    a run at all - so a real backlog reports a complete-looking pass over rows it never looked at
    (QA #1800 r17). Those rows are counted at `dv4_verified`, the gate that would refuse them.

    The second element is what keeps the measurement faithful to the write: a request with BOTH a
    verified and a newer unverified document is measured on the verified one, exactly as `plan()`
    and `approve()` would pick it, rather than being refused for a document the write never sees.
    """
    verified = verified_docs(doc_store, proof_store)
    docs = _docs_by_request(doc_store, proof_store, verified_only=False)
    # filings that never got a dv-4 run: they are in the proof store, not in `dv_outcomes`, so the
    # doc-verify store cannot enumerate them. `subject = 'credit'` is the filing's own declaration of
    # what it is meant to prove; a claim filing is not a credit document and is not counted here.
    #
    # QA #1800 r19 finding 2: this de-duplicated by INTAKE, so one filing bound to requests A and B
    # whose dv-4 run judged only A was skipped whole and B vanished from the census instead of being
    # counted at `dv4_verified`. The unit is the (document, request) PAIR, which is what a verdict is.
    seen = {(d.intake_id, d.request_id) for ds in docs.values() for d in ds}
    pdb = _ro(proof_store)
    try:
        filings = pdb.execute("SELECT intake_id, user_id, candidate_request_ids_json, file_sha256"
                              " FROM proof_intake WHERE subject = 'credit'").fetchall()
    finally:
        pdb.close()
    for intake_id, user_id, ids_json, sha in filings:
        if not isinstance(user_id, int):
            continue
        try:
            ids = tuple(str(x).lower() for x in json.loads(ids_json or "[]"))
        except ValueError:
            ids = ()
        for rid in ids:
            if (str(intake_id), rid) in seen:
                continue
            docs.setdefault(rid, []).append(
                Doc(str(intake_id), int(user_id), rid, str(sha or ""), "", False, ids))
    return docs, verified


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


# ── the evidence the R22 guards read (forensics + independent cross-checks) ──

@dataclass(frozen=True)
class Evidence:
    """What the newest dv-4 run RECORDED about a document, for the R22 guards.

    R22 guards 1-3 are not new judgements: they are questions the doc-verify run already answered and
    wrote into `dv_outcomes.detail_json` (forensics `h3`, the `checks` map, the issuer/signatory
    blocks). Reading them here - rather than re-deriving them - is what keeps the approval class and
    the verifier from drifting apart. `readable=False` is never an allow.
    """
    readable: bool
    h3: str = ""
    checks: dict[str, str] = None            # type: ignore[assignment]
    issuer_type: str = ""
    issuer_name: str = ""
    signatory_name: str = ""
    issuer_confidence: float = 0.0
    signatory_confidence: float = 0.0
    roles: tuple[str, ...] = ()
    why: str = ""

    def check(self, name: str) -> str:
        return str((self.checks or {}).get(name) or "").lower()


# the independent cross-checks R22 guard 1 names, and the two that also prove SAME-RELEASE (guard 2):
# xc_dsp is the claimed role on the track in Muso's trusted raw credits, xc_isrc is MusicBrainz/Deezer
# by ISRC. Both are keyed to the release itself, which is exactly what guard 2 asks for.
CROSSCHECKS = ("xc_dsp", "xc_isrc", "xc_label", "xc_domain")
RELEASE_CHECKS = ("xc_dsp", "xc_isrc")


def doc_evidence(doc_store: str | Path, intake_id: str, request_id: str) -> Evidence:
    """The newest dv-4 run's forensics + cross-checks for one document/request, merged over its roles.

    Merge rules are fail-closed: a `contradicts` on ANY role wins over a `positive` on another, and the
    forensics verdict is the WORST any role got (a document whose Composer role is PLAUSIBLE and whose
    Lyricist role is SUSPECT is not a PLAUSIBLE document).
    """
    try:
        db = _ro(doc_store)
    except (FileNotFoundError, sqlite3.Error) as exc:
        return Evidence(False, why=f"the doc-verify store is unreadable ({exc})")
    try:
        rows = db.execute(
            "WITH newest AS (SELECT intake_id, request_id, MAX(id) AS id FROM dv_outcomes"
            "                  WHERE version = ? AND intake_id IS NOT NULL"
            "                  GROUP BY intake_id, request_id),"
            "     last AS (SELECT o.intake_id, o.request_id, o.run_id FROM dv_outcomes o"
            "                JOIN newest n ON n.id = o.id WHERE o.version = ?)"
            " SELECT o.role, o.detail_json FROM dv_outcomes o"
            "   JOIN last l ON l.intake_id = o.intake_id AND l.request_id = o.request_id"
            "              AND l.run_id = o.run_id"
            "  WHERE o.version = ? AND o.intake_id = ? AND LOWER(o.request_id) = ?",
            (VERDICT_VERSION, VERDICT_VERSION, VERDICT_VERSION, str(intake_id),
             str(request_id).lower())).fetchall()
    except sqlite3.Error as exc:
        return Evidence(False, why=f"the doc-verify store could not be read ({exc})")
    finally:
        db.close()
    if not rows:
        return Evidence(False, why=f"no {VERDICT_VERSION} run recorded for {intake_id}")
    h3_rank = {"PLAUSIBLE": 3, "SUSPECT": 2, "IMPLAUSIBLE": 1}
    h3, checks, issuer_type = "", {}, ""
    issuer_conf, sign_conf, roles = 1.0, 1.0, []
    # QA #1800 r15 finding 1: a confidence is not an identity. The run writes `issuer`/`signatory`
    # blocks with `name`, `type`/`title` and `confidence`, and a block whose name is blank is a block
    # the run did NOT extract - it just scored one. Merged fail-closed like the rest: a blank name on
    # ANY role makes the document's name blank, so one role cannot rescue another's missing identity.
    issuer_name: str | None = None
    sign_name: str | None = None
    for role, detail_json in rows:
        roles.append(str(role))
        try:
            d = json.loads(detail_json or "{}")
        except ValueError:
            return Evidence(False, why=f"the {VERDICT_VERSION} detail for {intake_id} is unreadable")
        if not isinstance(d, dict):
            return Evidence(False, why=f"the {VERDICT_VERSION} detail for {intake_id} is not an object")
        got = str(d.get("h3") or "").upper()
        if h3_rank.get(got, 0) < h3_rank.get(h3, 4):
            h3 = got
        for k, v in (d.get("checks") or {}).items():
            v = str(v or "").lower()
            prev = checks.get(str(k), "")
            if v == "contradicts" or prev == "contradicts":
                checks[str(k)] = "contradicts"
            elif v == "positive" or prev == "positive":
                checks[str(k)] = "positive"
            else:
                checks[str(k)] = prev or v
        iss = d.get("issuer") or {}
        sig = d.get("signatory") or {}
        if isinstance(iss, dict):
            issuer_type = issuer_type or str(iss.get("type") or "")
            issuer_conf = min(issuer_conf, _conf(iss.get("confidence")))
            issuer_name = _merge_name(issuer_name, iss.get("name"))
        else:
            issuer_name = _merge_name(issuer_name, None)
        if isinstance(sig, dict):
            sign_conf = min(sign_conf, _conf(sig.get("confidence")))
            sign_name = _merge_name(sign_name, sig.get("name"))
        else:
            sign_name = _merge_name(sign_name, None)
    return Evidence(True, h3=h3, checks=checks, issuer_type=issuer_type,
                    issuer_name=issuer_name or "", signatory_name=sign_name or "",
                    issuer_confidence=issuer_conf, signatory_confidence=sign_conf,
                    roles=tuple(roles))


def _merge_name(prev: str | None, got: Any) -> str:
    """Fail-closed merge of one extracted identity name across a document's role rows.

    `None` means "no role has spoken yet". After that, a blank name on ANY role wins: the document is
    only fully extracted when every role's run named the issuer/signatory.
    """
    name = str(got or "").strip()
    if prev is None:
        return name
    return prev if (prev and name) else ""


def _conf(v: Any) -> float:
    try:
        return float(v)
    except (TypeError, ValueError):
        return 0.0


# ── the gates (one function each, so a test can fail one ALONE) ──────────────

@dataclass(frozen=True)
class Candidate:
    request_id: str
    user_id: int | None
    popularity: int | None
    docs: tuple[Doc, ...]
    profile_id: str | None = None      # R22 guard 7: the per-profile daily cap
    roles: tuple[str, ...] = ()        # R22 guard 3: the claimed roles (artist/org are refused)
    big_track: bool = False            # R22's tier line: "popularity 1-59, artist < 90"
    account_created_at: str | None = None   # R22a D2: core's own account createdAt, when supplied


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


def gate_forensics(c: Candidate, doc_store: str | Path = DEFAULT_DOC_STORE,
                   doc: Doc | None = None, ev: Evidence | None = None) -> Gate:
    """R22 guard 1a: the document's FORENSICS ran and came back PLAUSIBLE.

    R22: "doc-verify VERIFIED with an independent cross-check PLUS forensics" - both, not either. The
    forensics half is the `h3` verdict plus the issuer/signatory blocks the run extracted; a run that
    never extracted them (confidence 0 on both) did not do forensics, whatever its outcome says.
    """
    if not c.docs:
        return _fail("forensics", "no verified document names this request")
    d = doc if doc is not None else pick(c)
    e = ev if ev is not None else doc_evidence(doc_store, d.intake_id, c.request_id)
    if not e.readable:
        return _fail("forensics", f"the forensics record is unreadable: {e.why}")
    if e.h3 != "PLAUSIBLE":
        return _fail("forensics", f"the forensics verdict is {e.h3 or 'absent'}, not PLAUSIBLE")
    if e.issuer_confidence <= 0 or e.signatory_confidence <= 0:
        return _fail("forensics", "the run extracted no issuer/signatory identity: forensics did not run")
    # QA #1800 r15 finding 1: a confidence is not an identity. A block with `confidence: 0.9` and a
    # blank `name` is a block the run scored but did not extract, and the guard's own claim is that the
    # run EXTRACTED the issuer and signatory. Require the names, not just the scores.
    if not e.issuer_name or not e.signatory_name:
        missing = [w for w, v in (("issuer", e.issuer_name), ("signatory", e.signatory_name)) if not v]
        return _fail("forensics", f"the run extracted no {', '.join(missing)} name: "
                                   "a confidence without an identity is not forensics")
    return _pass()


def gate_crosscheck(c: Candidate, doc_store: str | Path = DEFAULT_DOC_STORE,
                    doc: Doc | None = None, ev: Evidence | None = None) -> Gate:
    """R22 guard 1b: at least one INDEPENDENT cross-check is positive, and none contradicts.

    The cross-checks are the sources the user does not control (Muso's trusted raw credits, MusicBrainz
    / Deezer by ISRC, the release's label line, the issuer's official domain). A document with no
    positive cross-check is a document nobody independent agreed with - the forensics half alone is not
    enough, which is the whole point of "PLUS".
    """
    if not c.docs:
        return _fail("crosscheck", "no verified document names this request")
    d = doc if doc is not None else pick(c)
    e = ev if ev is not None else doc_evidence(doc_store, d.intake_id, c.request_id)
    if not e.readable:
        return _fail("crosscheck", f"the cross-check record is unreadable: {e.why}")
    bad = [k for k in CROSSCHECKS if e.check(k) == "contradicts"]
    if bad:
        return _fail("crosscheck", f"an independent source contradicts the document ({', '.join(bad)})")
    good = [k for k in CROSSCHECKS if e.check(k) == "positive"]
    if not good:
        return _fail("crosscheck", "no independent cross-check is positive ("
                     + ", ".join(f"{k}={e.check(k) or 'absent'}" for k in CROSSCHECKS) + ")")
    return _pass()


def gate_same_release(c: Candidate, doc_store: str | Path = DEFAULT_DOC_STORE,
                      doc: Doc | None = None, ev: Evidence | None = None) -> Gate:
    """R22 guard 2: the document and the request are about the SAME RELEASE.

    The binding set says the filing was matched to this request; it does not say the document is about
    this track. The two release-keyed cross-checks do: `xc_dsp` compares the claimed role on THIS track
    in Muso's trusted raw credits, `xc_isrc` looks the release up by ISRC. One of them positive is the
    same-release proof; a contradiction on either is a document about something else.
    """
    if not c.docs:
        return _fail("same_release", "no verified document names this request")
    d = doc if doc is not None else pick(c)
    e = ev if ev is not None else doc_evidence(doc_store, d.intake_id, c.request_id)
    if not e.readable:
        return _fail("same_release", f"the release record is unreadable: {e.why}")
    bad = [k for k in RELEASE_CHECKS if e.check(k) == "contradicts"]
    if bad:
        return _fail("same_release", f"a trusted source places the document on another release "
                     f"({', '.join(bad)})")
    if not any(e.check(k) == "positive" for k in RELEASE_CHECKS):
        return _fail("same_release", "no trusted source ties the document to this release ("
                     + ", ".join(f"{k}={e.check(k) or 'absent'}" for k in RELEASE_CHECKS) + ")")
    return _pass()


def gate_role(c: Candidate, doc_store: str | Path = DEFAULT_DOC_STORE,
              doc: Doc | None = None, ev: Evidence | None = None) -> Gate:
    """R22 guard 3: the claimed role is not contradicted at a trusted source, and is not artist/org.

    Two refusals, both from the ruling: a trusted source that credits someone ELSE in this role (the
    `xc_dsp`/`xc_isrc` contradiction the verifier already recorded), and a claim whose role family is
    an artist or an organisation - those are not personal credits a document can prove, and R22 says
    NO to them whatever the document says.
    """
    from .roles import NON_PERSON_FAMILIES, family_of
    if not c.roles:
        return _fail("role", "the request carries no claimed role: the guard cannot run")
    bad_fam = sorted({family_of(r) for r in c.roles} & (set(NON_PERSON_FAMILIES) | {"artist"}))
    if bad_fam:
        return _fail("role", f"the claimed role is {', '.join(bad_fam)}: not a personal credit a "
                     "document can prove")
    if not c.docs:
        return _fail("role", "no verified document names this request")
    d = doc if doc is not None else pick(c)
    e = ev if ev is not None else doc_evidence(doc_store, d.intake_id, c.request_id)
    if not e.readable:
        return _fail("role", f"the role record is unreadable: {e.why}")
    bad = [k for k in RELEASE_CHECKS if e.check(k) == "contradicts"]
    if bad:
        return _fail("role", f"a trusted source credits someone else in this role ({', '.join(bad)})")
    return _pass()


def gate_doc_reuse(c: Candidate, proof_store: str | Path | None = None,
                   doc: Doc | None = None) -> Gate:
    """Fable R22a D3: refuse a document whose file sha256 is also filed for a DIFFERENT account.

    One file is one person's evidence. The same bytes filed under two accounts is either a shared
    template (a forged or recycled document) or a mis-filing, and neither is proof of THIS person's
    credit. The check is on the sha256 across the whole proof store, not just this intake, because the
    reuse is exactly what a second intake id would hide.
    """
    if not c.docs:
        return _fail("doc_reuse", "no verified document names this request")
    d = doc if doc is not None else pick(c)
    sha = str(d.proof_id or "")
    if not sha:
        return _fail("doc_reuse", "the document has no file sha256: reuse cannot be ruled out")
    db = _ro(proof_store or DEFAULT_PROOF_STORE)
    try:
        rows = db.execute("SELECT DISTINCT user_id FROM proof_intake WHERE file_sha256 = ?",
                          (sha,)).fetchall()
    except sqlite3.Error as exc:
        return _fail("doc_reuse", f"the proof store is unreadable ({exc}): reuse cannot be ruled out")
    finally:
        db.close()
    others = sorted({int(r[0]) for r in rows if r[0] is not None and int(r[0]) != int(d.user_id)})
    if others:
        return _fail("doc_reuse", f"the same file sha256 is filed for another account "
                     f"({', '.join(str(u) for u in others[:5])}): one file is one person's evidence")
    return _pass()


def gate_claimant(c: Candidate, db: sqlite3.Connection, now: datetime | None = None) -> Gate:
    """R22 guard 4: a CLEAN claimant >= 30 days, or a prior approval on the account.

    "Clean" is measured on what this ledger knows: the account's first appearance is at least 30 days
    old and it has never had an approval PULLED. "Or a prior approval" is the escape hatch the ruling
    gives an account that is new but already trusted: any approval of theirs that still stands. An
    account with no history at all is neither, so it is refused - fail closed, and the cost is that a
    brand-new account waits for the ordinary path.
    """
    if c.user_id is None:
        return _fail("claimant", "the request carries no account id: the guard cannot run")
    now = now or datetime.now(timezone.utc)
    prior = db.execute("SELECT COUNT(*) FROM doc_approvals WHERE user_id = ?"
                       " AND state IN ('provisional', 'confirmed')", (c.user_id,)).fetchone()
    if prior and int(prior[0]) > 0:
        return _pass()
    pulled = db.execute("SELECT COUNT(*) FROM doc_approvals WHERE user_id = ? AND state = 'pulled'",
                        (c.user_id,)).fetchone()
    if pulled and int(pulled[0]) > 0:
        return _fail("claimant", "the account has had a doc approval PULLED: not a clean claimant")
    # Fable R22a D2: "Claimant age must come from core createdAt, or count claimant_no_history." The
    # ledger's first sighting is OUR clock, not the account's age - an account that has been on Muso
    # for years but only reached this ledger yesterday would read as brand new. Core's own createdAt is
    # the authority when the caller can supply it; when it cannot, the refusal is NAMED
    # `claimant_no_history` so a dry run can count it instead of it hiding inside a generic refusal.
    core_seen = str(c.account_created_at or "")
    if not core_seen:
        # R22a D2: "Claimant age must come from core createdAt, or count claimant_no_history." The
        # ledger's first sighting is OUR clock, not the account's age, and it fails OPEN in the one
        # direction that matters: an account created five days ago whose first `decisions` row is
        # forty days old (a claim, a merge, a backfill) would pass a 30-day floor it never earned.
        # So the ledger can never PASS this gate - only core's own createdAt can (QA #1800 r18).
        return _fail("claimant_no_history", "core's account createdAt was not supplied: the "
                     "claimant's age cannot be established from the ledger, which is our clock and "
                     "not the account's")
    try:
        age = now - datetime.strptime(core_seen, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
    except ValueError:
        return _fail("claimant", f"core's account createdAt is unreadable ({core_seen}): the "
                     "claimant's age cannot be established")
    if age < timedelta(days=CLEAN_CLAIMANT_DAYS):
        return _fail("claimant", f"the account is {age.days}d old at core, below the "
                     f"{CLEAN_CLAIMANT_DAYS}d clean-claimant floor")
    return _pass()


def gate_tier(c: Candidate) -> Gate:
    """T0/T1 only: a known popularity below 60 AND a linked artist below 90.

    R22's tier line is "popularity 1-59, artist < 90", which is the decider's own big-track rule
    (`evidence.TrackCatalog.big`: unknown, track >= 60, artists unknown, or artist >= 90). The
    popularity check alone would approve a pop-20 track by a 95-popularity artist - a T2/T3 case
    wearing a small track's number - so the caller's `big_track` is refused here too.
    """
    if c.big_track:
        return _fail("tier", "the decider's own big-track rule says big (artist >= 90, or the "
                     "catalog read was incomplete): T2/T3, not a small-track doc approval")
    p = c.popularity
    if not isinstance(p, int) or isinstance(p, bool):
        return _fail("tier", "popularity unknown: T0/T1 cannot be established, so this is not a "
                     "small-track doc approval (T2/T3 stay on the DSP ask)")
    if p <= 0:
        # Fable R22a D1 (2026-11-05 21:01Z): "Refuse popularity 0 in gate_tier. (d2's popularity-0
        # question is answered NO.)" A zero is not a small track, it is an UNATTRIBUTABLE one - core's
        # own agent guard refuses it as `popularity_unattributable`, so approving it here would plan a
        # write core rejects. R22's tier line is "popularity 1-59", and 0 is not in it.
        return _fail("tier", f"popularity {p}: R22's tier line is 1-59, and a zero is an "
                     "unattributable track (core refuses it too), not a small one")
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


def gate_profile_cap(c: Candidate, db: sqlite3.Connection, now: datetime | None = None) -> Gate:
    """R22 guard 7: <= 10 approvals per PROFILE per UTC day.

    A profile is the artist page the credits hang off, and one profile can be claimed by several
    accounts (a band, a shared login, a manager). The user cap alone let ten accounts spend 50 credits
    on one profile in a day; this is the bound that makes a single profile's damage small.
    """
    if not c.profile_id:
        return _fail("profile_cap", "the request carries no profile id: the per-profile cap cannot run")
    day_start = (now or datetime.now(timezone.utc)).strftime("%Y-%m-%dT00:00:00Z")
    n = db.execute("SELECT COUNT(*) FROM doc_approvals WHERE approved_at >= ? AND profile_id = ?"
                   " AND state IN ('provisional', 'confirmed', 'pulled', 'indeterminate')",
                   (day_start, str(c.profile_id))).fetchone()
    if n and int(n[0]) >= PER_PROFILE_DAILY_MAX:
        return _fail("profile_cap", f"{int(n[0])} doc approvals for this profile today "
                     f"(cap {PER_PROFILE_DAILY_MAX}/profile/day): the rest roll to tomorrow")
    return _pass()


def _freeze_row(db: sqlite3.Connection) -> tuple[str, str] | None:
    """(at, reason) of the ledger's freeze row, or None. A ledger that predates the table has none."""
    try:
        r = db.execute("SELECT at, reason FROM doc_approval_freeze WHERE id = 1").fetchone()
    except sqlite3.Error:
        return None
    return (str(r[0]), str(r[1])) if r else None


def frozen(db: sqlite3.Connection | None = None, path: str | Path | None = None) -> bool:
    """R22 guard 8: is the class auto-frozen? EITHER the ledger row OR the marker file says so.

    QA #1800 finding 1 (Critical): the marker file was the only record, and a failed write was
    swallowed - so after a pull the next run could keep approving, which defeats the guard the whole
    arming condition rests on. The ledger row is written FIRST, in the same transaction as the pull,
    so the freeze cannot be lost to a filesystem problem; the file stays because it is what a human
    sees and what survives a deploy (the deploy rsync owns /opt/hydra, never /var/lib).
    """
    if Path(path or FREEZE_PATH).exists():
        return True
    return db is not None and _freeze_row(db) is not None


def freeze(db: sqlite3.Connection, *, reason: str, now: datetime | None = None,
           path: str | Path | None = None) -> bool:
    """R22 guard 8: ONE reversal freezes the class. Called by `sweep()` on the first pull.

    The ledger row is the guarantee and is written first: if it cannot be written this RAISES, because
    a pull that cannot freeze the class must fail the run rather than leave it approving. The marker
    file is the human-visible copy; a failure to write it is recorded and reported, never swallowed,
    and the class is still frozen by the row.

    Deliberately NOT self-clearing: a human reads the pull, decides, and clears both. An auto-unfreeze
    would make the guard a delay.
    """
    now = now or datetime.now(timezone.utc)
    db.execute("INSERT OR REPLACE INTO doc_approval_freeze (id, at, reason) VALUES (1, ?, ?)",
               (utc(now), reason[:600]))
    db.commit()
    p = Path(path or FREEZE_PATH)
    wrote = True
    try:
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(f"frozen at {utc(now)}: {reason[:600]}\n", encoding="utf-8")
    except OSError as exc:
        wrote = False
        record_event(db, now, "-", None, None, "freeze_marker_failed", gate=None,
                     reason=f"the class IS frozen by the ledger row, but {p} could not be written "
                            f"({exc}): a human must clear the row too"[:600])
    record_event(db, now, "-", None, None, "frozen", gate=None,
                 reason=reason[:600] + ("" if wrote else " (marker file NOT written)"))
    return wrote


def gate_not_frozen(c: Candidate, db: sqlite3.Connection | None = None,
                    path: str | Path | None = None) -> Gate:
    """R22 guard 8: a frozen class approves nothing until a human clears it."""
    p = Path(path or FREEZE_PATH)
    row = _freeze_row(db) if db is not None else None
    if row is None and not p.exists():
        return _pass()
    why = row[1] if row else ""
    if not why and p.exists():
        try:
            why = p.read_text(encoding="utf-8").strip()
        except OSError:
            why = ""
    where = f"{p} and the ledger row" if row and p.exists() else (str(p) if p.exists() else "the ledger row")
    return _fail("not_frozen", f"the class is AUTO-FROZEN ({where}): {why or 'no reason recorded'}")


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


GATES: tuple[str, ...] = ("one_request", "dv4_verified", "forensics", "crosscheck", "same_release",
                          "role", "doc_reuse", "tier", "account", "no_hold", "claimant",
                          "one_per_request", "profile_cap", "daily_cap", "not_frozen")


@dataclass
class Approval:
    request_id: str
    user_id: int
    intake_id: str
    proof_id: str
    ref: str
    popularity: int
    tier: str
    profile_id: str | None = None
    evidence: Evidence | None = None


def evaluate(c: Candidate, db: sqlite3.Connection, *, doc_store: str | Path = DEFAULT_DOC_STORE,
             proof_store: str | Path | None = None,
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

    # R22's eight guards, in the order that refuses cheapest-and-most-fundamental first. The evidence
    # is read ONCE per candidate and handed to the three gates that need it, so a run does not re-read
    # the doc-verify store four times for the same document.
    ev: Evidence | None = None
    if c.docs:
        d0 = pick(c)
        ev = doc_evidence(doc_store, d0.intake_id, c.request_id)
    for g in (lambda: gate_one_request(c, req_users),
              lambda: gate_dv4_verified(c, doc_store),
              lambda: gate_forensics(c, doc_store, ev=ev),
              lambda: gate_crosscheck(c, doc_store, ev=ev),
              lambda: gate_same_release(c, doc_store, ev=ev),
              lambda: gate_role(c, doc_store, ev=ev),
              lambda: gate_doc_reuse(c, proof_store),
              lambda: gate_tier(c),
              lambda: gate_account(c, gate),
              lambda: gate_no_hold(c, hold_ids, hold_users),
              lambda: gate_claimant(c, db, now),
              lambda: gate_one_per_request(c, db),
              lambda: gate_profile_cap(c, db, now),
              lambda: gate_daily_cap(c, db, now),
              lambda: gate_not_frozen(c)):
        if not add(g()):
            return answers[-1], answers   # THE gate that refused, not the first one asked
    return _pass(), answers


# The gates that are about the ROW, in the order `evaluate` asks them. The three cap gates are
# deliberately NOT here: a dry run over the whole document universe would refuse almost every row on
# the 50-user day cap, which says nothing about whether the row is approvable. The caps are reported
# separately, as the plan they produce.
ROW_GATES: tuple[str, ...] = ("one_request", "dv4_verified", "forensics", "crosscheck", "same_release",
                              "role", "doc_reuse", "tier", "account", "no_hold", "claimant",
                              "one_per_request", "not_frozen")


def dry_run(db: sqlite3.Connection, *, doc_store: str | Path = DEFAULT_DOC_STORE,
            proof_store: str | Path | None = None,
            gate: account_gate.Cached | Callable[[Any], Any] | None = None,
            hold_ids: Iterable[str] = (), hold_users: Iterable[Any] = (),
            now: datetime | None = None, rows: dict[str, dict[str, Any]] | None = None,
            req_users: dict[str, Any] | None = None) -> dict[str, Any]:
    """Fable R22a's arming condition: a **0-write** pass over every document row, split per guard.

    It writes NOTHING - no `doc_approvals` row, no event, no audit row, no freeze, no core call. It
    answers two questions and keeps them apart, because conflating them is how a dry run lies:

    1. **Per guard**: for every request a verified document names, which gate refuses it FIRST. A row
       that no gate refuses is `would_approve`. The cap gates are excluded here (see `ROW_GATES`): a
       50-user day cap would refuse nearly every row and say nothing about the row itself.
    2. **The plan**: of the rows that pass every row gate, how many USERS and REQUESTS the caps would
       actually approve today, in `paid_first_oldest` order, and how many roll to tomorrow.

    `rows` maps a lowercased request id to the ledger facts the gates need (`user_id`, `popularity`,
    `profile_id`, `roles`, `big_track`, `account_created_at`). A request with no ledger row is counted
    as `no_ledger_row` rather than guessed at.
    """
    now = now or datetime.now(timezone.utc)
    rows = rows or {}
    try:
        # `proof_store` is optional everywhere else (`gate_doc_reuse` falls back to the default), so
        # the dry run must fall back too: the CLI passes no proof store, and the store readers would
        # otherwise be handed None and raise instead of measuring anything.
        docs, verified = document_universe(doc_store, proof_store or DEFAULT_PROOF_STORE)
    except (OSError, sqlite3.Error) as exc:
        return {"unreadable": f"the doc-verify store could not be read ({exc})", "per_guard": {},
                "verdicts": {}, "would_approve": 0, "rows": 0}
    per_guard: dict[str, int] = {}
    verdicts: dict[str, str] = {}                    # request id -> the gate that refused it first
    passed: list[tuple[str, Any, Any, tuple]] = []   # (request_id, user_id, profile_id, order key)
    for rid, ds in sorted(docs.items()):
        # QA #1800 r17: the measurement covers the whole filed backlog. A request no VERIFIED document
        # names is counted at the gate that refuses it, not dropped - a dry run that only sees the
        # already-verified rows reports a complete pass over a backlog it never looked at.
        if rid not in verified:
            per_guard["dv4_verified"] = per_guard.get("dv4_verified", 0) + 1
            verdicts[rid] = "dv4_verified"
            continue
        ds = verified[rid]
        r = rows.get(rid.lower())
        if r is None:
            per_guard["no_ledger_row"] = per_guard.get("no_ledger_row", 0) + 1
            verdicts[rid] = "no_ledger_row"
            continue
        c = Candidate(rid, r.get("user_id"), r.get("popularity"), tuple(ds),
                      r.get("profile_id"), tuple(r.get("roles") or ()), bool(r.get("big_track")),
                      r.get("account_created_at"))
        verdict = _row_verdict(c, db, doc_store=doc_store, proof_store=proof_store, gate=gate,
                               hold_ids=hold_ids, hold_users=hold_users, now=now,
                               req_users=req_users)
        per_guard[verdict] = per_guard.get(verdict, 0) + 1
        verdicts[rid] = verdict
        if verdict == "would_approve":
            passed.append((rid, c.user_id, c.profile_id,
                           order_key(c.user_id, r.get("created_at"), None, now)))
    # the plan: the caps applied to the rows that survived every row gate, ON TOP OF what today's
    # ledger has already spent (QA #1800 r13 finding 3). Starting the plan from zero reported 50 more
    # users when 49 were already approved, ignored the per-profile bound entirely, and dropped the
    # users past the fleet cap out of `rolled_to_tomorrow` instead of counting them.
    try:
        plan = plan_caps(db, now, passed)
    except sqlite3.Error as exc:
        # the same rule as the doc store above: a ledger that cannot answer is an ERROR, never a
        # clean zero. `_spent_today` deliberately raises rather than reporting an empty day.
        return {"unreadable": f"the ledger could not be read for today's spent slots ({exc})",
                "per_guard": per_guard, "verdicts": verdicts, "would_approve": 0, "rows": len(docs)}
    return {"unreadable": "", "per_guard": per_guard, "verdicts": verdicts, "rows": len(docs),
            "would_approve": per_guard.get("would_approve", 0),
            "eligible_users": plan["eligible_users"], "would_users": plan["would_users"],
            "would_requests": plan["would_requests"],
            "admitted": plan["admitted"],
            "rolled_to_tomorrow": plan["rolled_to_tomorrow"],
            "spent_users_today": plan["spent_users_today"],
            "spent_requests_today": plan["spent_requests_today"],
            "user_cap": DAILY_USER_CAP, "per_user_max": PER_USER_DAILY_MAX,
            "per_profile_max": PER_PROFILE_DAILY_MAX}


def _spent_today(db: sqlite3.Connection, day_start: str) -> tuple[dict[str, int], dict[str, int]]:
    """(per-user counts, per-profile counts) already spent today, by the SAME state filter the
    write boundary uses (`_cap_refusal`). An `indeterminate` row counts: core may have committed it.

    Read-only. A ledger that cannot answer RAISES rather than reporting an empty day, because an
    empty day is the answer that makes a dry run over-report.
    """
    users: dict[str, int] = {}
    profiles: dict[str, int] = {}
    for uid, pid, n in db.execute(
            "SELECT user_id, profile_id, COUNT(*) FROM doc_approvals WHERE approved_at >= ?"
            " AND state IN ('provisional', 'confirmed', 'pulled', 'indeterminate')"
            " GROUP BY user_id, profile_id", (day_start,)).fetchall():
        users[str(uid)] = users.get(str(uid), 0) + int(n)
        if pid:
            profiles[str(pid)] = profiles.get(str(pid), 0) + int(n)
    return users, profiles


def plan_caps(db: sqlite3.Connection, now: datetime,
               passed: list[tuple[str, Any, Any, tuple]]) -> dict[str, Any]:
    """The cap plan: walk the surviving rows in `paid_first_oldest` order and apply the SAME three
    bounds `_cap_refusal` applies at the write boundary, against a simulated copy of today's ledger.

    A request the caps would refuse today is counted in `rolled_to_tomorrow` - including the ones
    past the fleet cap, which the old plan silently dropped.

    `admitted` names the requests the caps would actually let through TODAY. QA #1766 r3 finding 1:
    a caller that counts pre-cap `would_approve` rows as "approvable work" pages a stalled decider
    when every daily slot is already spent, although zero approvals is then the correct answer.
    """
    day_start = now.strftime("%Y-%m-%dT00:00:00Z")
    spent_users, spent_profiles = _spent_today(db, day_start)
    users = dict(spent_users)
    profiles = dict(spent_profiles)
    spent_requests = sum(spent_users.values())
    eligible = {uid for _rid, uid, _pid, _k in passed if uid is not None}
    approved_users: set[Any] = set()
    admitted: list[str] = []
    would_requests = 0
    rolled = 0
    for _rid, uid, pid, _k in sorted(passed, key=lambda t: t[3]):
        if uid is None:
            rolled += 1
            continue
        me = str(uid)
        if users.get(me, 0) >= PER_USER_DAILY_MAX:
            rolled += 1
            continue
        if pid and profiles.get(str(pid), 0) >= PER_PROFILE_DAILY_MAX:
            rolled += 1
            continue
        if me not in users and len(users) >= DAILY_USER_CAP:
            rolled += 1
            continue
        users[me] = users.get(me, 0) + 1
        if pid:
            profiles[str(pid)] = profiles.get(str(pid), 0) + 1
        approved_users.add(uid)
        admitted.append(_rid)
        would_requests += 1
    return {"eligible_users": len(eligible), "would_users": len(approved_users),
            "would_requests": would_requests, "rolled_to_tomorrow": rolled,
            "spent_users_today": len(spent_users), "spent_requests_today": spent_requests,
            "admitted": admitted}


def _row_verdict(c: Candidate, db: sqlite3.Connection, *, doc_store: str | Path,
                 proof_store: str | Path | None, gate: Any, hold_ids: Iterable[str],
                 hold_users: Iterable[Any], now: datetime,
                 req_users: dict[str, Any] | None) -> str:
    """The FIRST row gate that refuses this candidate, or `would_approve`. Never writes."""
    ev: Evidence | None = None
    if c.docs:
        ev = doc_evidence(doc_store, pick(c).intake_id, c.request_id)
    for name, g in (("one_request", lambda: gate_one_request(c, req_users)),
                    ("dv4_verified", lambda: gate_dv4_verified(c, doc_store)),
                    ("forensics", lambda: gate_forensics(c, doc_store, ev=ev)),
                    ("crosscheck", lambda: gate_crosscheck(c, doc_store, ev=ev)),
                    ("same_release", lambda: gate_same_release(c, doc_store, ev=ev)),
                    ("role", lambda: gate_role(c, doc_store, ev=ev)),
                    ("doc_reuse", lambda: gate_doc_reuse(c, proof_store)),
                    ("tier", lambda: gate_tier(c)),
                    ("account", lambda: gate_account(c, gate)),
                    ("no_hold", lambda: gate_no_hold(c, hold_ids, hold_users)),
                    ("claimant", lambda: gate_claimant(c, db, now)),
                    ("one_per_request", lambda: gate_one_per_request(c, db)),
                    ("not_frozen", lambda: gate_not_frozen(c, db))):
        got = g()
        if not got.ok:
            # QA #1800 r16 finding 2: the tuple label is the gate's FAMILY, not the answer it gave.
            # `gate_claimant` answers `claimant_no_history` for a candidate with no decision history
            # and no core createdAt, and R22a D2 requires that population to be counted BY NAME - the
            # dry run reported it as plain `claimant`, hiding the rows the ruling names.
            return got.name or name
    return "would_approve"


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
         proof_store: str | Path | None = None,
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
    # QA #1800 r16 finding 1: `proof_store` was accepted and then dropped, so `gate_doc_reuse` inside
    # `evaluate` read the DEFAULT proof store while the caller believed it had checked the configured
    # one. A file SHA reused across two accounts in the configured store was refused by the gate and
    # approved by the plan.
    verdict, answers = evaluate(c, db, doc_store=doc_store, proof_store=proof_store, gate=gate,
                               hold_ids=hold_ids, hold_users=hold_users, now=now, req_users=req_users)
    if not verdict.ok:
        return None, answers
    d = pick(c)
    assert d is not None and c.popularity is not None and c.user_id is not None
    return Approval(c.request_id, c.user_id, d.intake_id, d.proof_id, d.ref, int(c.popularity),
                    tier_of(int(c.popularity)), c.profile_id,
                    doc_evidence(doc_store, d.intake_id, c.request_id)), answers


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
    "INSERT INTO doc_approvals (request_id, user_id, profile_id, intake_id, proof_id, ref, popularity,"
    " tier, approved_at, expires_at, state) VALUES (?,?,?,?,?,?,?,?,?,?,'provisional')")

# QA #1684 round 3, finding 3: a RELEASED row keeps its row (the audit trail) and the UNIQUE
# request_id that `release()` promised the slot back for, so `INSERT OR IGNORE` could never write it
# again - every later attempt was refused for ever by the one-per-request UNIQUE while the gate said
# the slot was free. The released row IS the slot: re-approving rewrites it and the event log keeps
# both facts (released, then approved again) instead of a second row.
_REUSE_RELEASED = (
    "UPDATE doc_approvals SET user_id = ?, profile_id = ?, intake_id = ?, proof_id = ?, ref = ?,"
    " popularity = ?, tier = ?, approved_at = ?, expires_at = ?, state = 'provisional', state_at = ?,"
    " reason = ? WHERE request_id = ? AND state = 'released'")


def _cap_refusal(db: sqlite3.Connection, day_start: str, user_id: Any,
                 profile_id: Any = None) -> str:
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
    if profile_id:
        # R22 guard 7: the per-PROFILE bound, re-asked inside the same write transaction as the others
        pn = db.execute("SELECT COUNT(*) FROM doc_approvals WHERE approved_at >= ? AND profile_id = ?"
                        " AND state IN ('provisional', 'confirmed', 'pulled', 'indeterminate')",
                        (day_start, str(profile_id))).fetchone()
        if pn and int(pn[0]) >= PER_PROFILE_DAILY_MAX:
            return (f"profile_cap: {int(pn[0])} doc approvals for this profile today "
                    f"(cap {PER_PROFILE_DAILY_MAX}/profile/day)")
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
        # R22 guard 8, re-asked INSIDE the write transaction (QA #1800 r13 finding 1, Critical):
        # `gate_not_frozen` runs during evaluation, but a concurrent `sweep()` can commit a pull and
        # freeze the class between that read and this write - and the approval still committed, so the
        # one-reversal stop condition had a window. A gate read outside the write transaction is
        # advice, not a guarantee, which is exactly why the caps are re-asked here too.
        if frozen(db):
            if started:
                db.execute("ROLLBACK")
            return False, "not_frozen: the class was frozen by a concurrent pull"
        row = db.execute("SELECT state FROM doc_approvals WHERE request_id = ?",
                         (ap.request_id,)).fetchone()
        if row is not None and row[0] != "released":
            if started:
                db.execute("ROLLBACK")
            return False, f"one_per_request: already {row[0]}"
        why = _cap_refusal(db, day_start, ap.user_id, ap.profile_id)
        if why:
            if started:
                db.execute("ROLLBACK")
            return False, why
        # R22 guard 6: PROVISIONAL served, NEVER lowered. A shorter window is a bug, not a knob, so it
        # is refused at the write boundary rather than trusted from the caller.
        if (expires - now) < timedelta(days=PROVISIONAL_MIN_DAYS):
            if started:
                db.execute("ROLLBACK")
            return False, (f"provisional: the window is {(expires - now).days}d, below the "
                           f"{PROVISIONAL_MIN_DAYS}d floor R22 requires")
        expires_s = utc(expires)
        if row is not None:
            cur = db.execute(_REUSE_RELEASED,
                             (ap.user_id, ap.profile_id, ap.intake_id, ap.proof_id, ap.ref,
                              ap.popularity, ap.tier, utc(now), expires_s, None,
                              f"re-approved from a released slot at {utc(now)}", ap.request_id))
        else:
            cur = db.execute(_INSERT_APPROVAL,
                             (ap.request_id, ap.user_id, ap.profile_id, ap.intake_id, ap.proof_id,
                              ap.ref, ap.popularity, ap.tier, utc(now), expires_s))
        if cur.rowcount != 1:
            if started:
                db.execute("ROLLBACK")
            return False, ("one_per_request: a concurrent run recorded this request first" if row is None
                           else "one_per_request: the released row changed under us")
        # R22 guard 8: the audit row is written in the SAME transaction as the approval. QA #1800
        # finding 4: committing the approval first meant an audit failure left an UNAUDITED approval,
        # and "100% audit for 14 days" is exactly the property that must not have a gap. If the audit
        # insert fails, the approval rolls back with it.
        _audit_row(db, ap, now)
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
            proof_store: str | Path | None = None,
            gate: account_gate.Cached | Callable[[Any], Any] | None = None,
            hold_ids: Iterable[str] = (), hold_users: Iterable[Any] = (),
            now: datetime | None = None, mode: str = "shadow") -> tuple[Approval | None, list[Gate]]:
    """One candidate's answer, recorded. In apply mode a passing candidate writes its provisional
    row (and only apply mode consumes the day cap); shadow/judge record the event and write nothing,
    so a judge run can never approve a request or spend a slot."""
    now = now or datetime.now(timezone.utc)
    verdict, answers = evaluate(c, db, doc_store=doc_store, proof_store=proof_store, gate=gate,
                                hold_ids=hold_ids, hold_users=hold_users, now=now)
    d = pick(c) if c.docs else None
    if not verdict.ok:
        record_event(db, now, c.request_id, c.user_id, d.intake_id if d else None, "refused",
                     gate=verdict.name, reason=verdict.why)
        return None, answers
    assert d is not None and c.popularity is not None and c.user_id is not None
    ev = doc_evidence(doc_store, d.intake_id, c.request_id)
    ap = Approval(c.request_id, c.user_id, d.intake_id, d.proof_id, d.ref, int(c.popularity),
                  tier_of(int(c.popularity)), c.profile_id, ev)
    if mode != "apply":
        record_event(db, now, c.request_id, c.user_id, d.intake_id, "would_approve", gate=None,
                     reason=f"{ap.ref} (popularity {ap.popularity}, {ap.tier}); {mode} mode writes nothing")
        return ap, answers
    expires = now + timedelta(days=PROVISIONAL_DAYS)
    spent, why = spend_slot(db, ap, now=now, expires=expires)
    if not spent:
        # The refusal is NAMED by the gate that produced it, not folded into `daily_cap`. QA #1800 r13
        # finding 1: a freeze that lands between evaluation and the write is refused by `spend_slot`,
        # and recording that as `daily_cap` would have hidden the one-reversal stop condition inside a
        # cap refusal - the event log is the audit trail, so it must say which guard actually fired.
        name = why.split(":", 1)[0] or "daily_cap"
        answers = answers + [Gate(name, why)]
        record_event(db, now, c.request_id, c.user_id, d.intake_id, "refused", gate=name, reason=why)
        return None, answers
    record_event(db, now, c.request_id, c.user_id, d.intake_id, "approved", gate=None,
                 reason=f"{ap.ref} provisional until {utc(expires)} (popularity {ap.popularity}, {ap.tier})")
    # R22 guard 8: 100% audit - EVERY approval writes its evidence snapshot, not a sample, and
    # `spend_slot` wrote it inside the approval's own transaction (see _audit_row).
    return ap, answers


def _audit_row(db: sqlite3.Connection, ap: Approval, now: datetime) -> None:
    """The audit INSERT itself, with NO commit: the caller owns the transaction so the row and the
    approval it describes land together or not at all (QA #1800 finding 4)."""
    ev = ap.evidence
    db.execute("INSERT INTO doc_approval_audit (at, request_id, user_id, profile_id, intake_id, ref,"
               " popularity, tier, h3, checks_json, issuer_type, notice, scope)"
               " VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)",
               (utc(now), ap.request_id, ap.user_id, ap.profile_id, ap.intake_id, ap.ref,
                ap.popularity, ap.tier, (ev.h3 if ev else None),
                json.dumps((ev.checks if ev else {}) or {}, sort_keys=True),
                (ev.issuer_type if ev else None),
                "core approval notice (one per user per PUT)", SCOPE))


def audit_approval(db: sqlite3.Connection, ap: Approval, *, now: datetime | None = None) -> None:
    """R22 guard 8: one audit row per approval, with the evidence the guards actually read.

    Kept as a public entry point for a caller that already holds a transaction; `spend_slot` writes the
    row inline so the approval and its audit are atomic.
    """
    _audit_row(db, ap, now or datetime.now(timezone.utc))
    db.commit()


def audit_window(db: sqlite3.Connection, now: datetime | None = None) -> tuple[bool, str]:
    """R22 guard 8: is the 14-day 100% audit window still open, and how many rows has it written?

    The window opens at the FIRST AUDITED approval and runs 14 days. It is reported, never enforced by
    refusing approvals - the audit is a record, and a record that stops recording is the failure the
    watchdog pages on.

    QA #1800 r18 finding 2: it used to open at the first `doc_approvals` row, which on a MIGRATED
    ledger includes approvals written before `doc_approval_audit` existed. A ledger whose oldest
    approval is 15 days old then reported the window CLOSED the moment the class was armed, and an
    8-day-old first row left six days - the audit would have been declared over before it began. The
    window is about the rows this class actually audits, so it anchors to the first approval that HAS
    an audit row.
    """
    now = now or datetime.now(timezone.utc)
    first = db.execute(
        "SELECT MIN(a.approved_at) FROM doc_approvals a"
        " WHERE EXISTS (SELECT 1 FROM doc_approval_audit u WHERE u.request_id = a.request_id)"
    ).fetchone()
    start = str((first or [""])[0] or "")
    n = db.execute("SELECT COUNT(*) FROM doc_approval_audit").fetchone()
    rows = int((n or [0])[0] or 0)
    if not start:
        return False, (f"no AUDITED approval yet: the {AUDIT_DAYS}-day audit window has not opened"
                       f" ({rows} rows)")
    try:
        opened = datetime.strptime(start, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
    except ValueError:
        return False, f"the first approval stamp is unreadable ({start}): audit state unknown"
    left = (opened + timedelta(days=AUDIT_DAYS)) - now
    if left <= timedelta(0):
        return False, f"the {AUDIT_DAYS}-day audit window closed at {utc(opened + timedelta(days=AUDIT_DAYS))} ({rows} rows)"
    return True, f"audit window open, {left.days}d left, {rows} rows written"


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
        if new == "pulled":
            # R22 guard 8: ONE reversal freezes the class, and the freeze is written in the SAME
            # transaction as the pull - a pull that committed without its freeze would leave the class
            # approving, which is the failure QA #1800 finding 1 named. `freeze` raises if the row
            # cannot be written, so the pull rolls back with it.
            db.execute("INSERT OR REPLACE INTO doc_approval_freeze (id, at, reason) VALUES (1, ?, ?)",
                       (utc(now), f"a provisional approval was PULLED ({request_id}, {intake_id}): {why}"[:600]))
        db.commit()
        record_event(db, now, request_id, user_id, intake_id, new, gate=None, reason=why)
        if new == "pulled":
            # the human-visible copy; the ledger row above is what actually guarantees the freeze
            freeze(db, reason=f"a provisional approval was PULLED ({request_id}, {intake_id}): {why}",
                   now=now)
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
    q = ("SELECT request_id, user_id, profile_id, intake_id, proof_id, ref, popularity, tier, approved_at,"
         " expires_at, state, state_at, reason FROM doc_approvals WHERE state != 'released'")
    args: tuple[Any, ...] = ()
    if user_id is not None:
        q += " AND user_id = ?"
        args = (user_id,)
    q += " ORDER BY id"
    cols = ("request_id", "user_id", "profile_id", "intake_id", "proof_id", "ref", "popularity", "tier",
            "approved_at", "expires_at", "state", "state_at", "reason")
    return [dict(zip(cols, r)) for r in db.execute(q, args)]
