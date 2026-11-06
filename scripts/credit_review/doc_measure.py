"""The ONE read-only measurement of the doc-verified T0/T1 class.

Two surfaces ask "what would this class approve right now": the arming dry run
(`credit-review.py doc-approvals --dry-run`, which Fable R22a makes the arming condition) and the
watchdog (`credit-decide-watchdog.py`, which pages when the class stalls). They used to answer it
with two different sets of gates, so the number an operator armed on and the number the alerts
paged on could disagree - and the watchdog's set was the smaller one, which is how a class whose
documents all fail a later gate paged a stalled-decider alert every hour while the decider was
behaving correctly (qa-review #1766 r1 finding 4, r2 carried-forward).

Everything here is READ-ONLY. It opens no store for writing, creates nothing, and migrates
nothing: a measurement that mutates the thing it measures is not a measurement.
"""

from __future__ import annotations

import sqlite3
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from . import decide, doc_approve
from .runner import log

#: A safety bound on the core pager, not a measurement limit: 1000 pages of 200 is 200,000 held
#: requests. Reaching it is an INCOMPLETE census, never a successful one (QA #1800 r19, r20).
CORE_AGE_MAX_PAGES = 1000


class LedgerUnreadable(RuntimeError):
    """The ledger exists but could not be read. Never the same thing as an empty ledger."""


class PolicyUnreadable(RuntimeError):
    """The deny/hold policy could not be read, so the hold sets are UNKNOWN.

    QA #1766 r3 finding 3: `load_policy` used to return None and `measure` then held nobody, so a
    denied user could appear in the shadow would-approve count and page a false stalled decider -
    while the decider itself fails closed on the same unreadable policy. An unmeasured hold set is
    a refusal, not an empty one.
    """


class CoreCensusIncomplete(RuntimeError):
    """The core pager hit its safety ceiling with account ages still unread.

    QA #1800 r20: the pager fixed the old 8,000-row limit but still RETURNED the partial map and
    exited 0, so a document-backed request past the ceiling measured as `claimant_no_history` and the
    census printed as complete. A measurement that could not finish is not a measurement.
    """


def rows(db: sqlite3.Connection) -> dict:
    """The ledger facts the doc gates need, per request: the NEWEST decision row for each.

    Read-only. A request the ledger has never decided is absent, and the measurement counts it as
    `no_ledger_row` rather than inventing a popularity or an owner. A ledger that cannot be READ
    raises `LedgerUnreadable` - it never reads as an empty ledger.
    """
    out: dict = {}
    try:
        cur = db.execute(
            "SELECT request_id, user_id, profile_id, popularity, big_track, claimed_roles, decided_at"
            " FROM decisions WHERE id IN (SELECT MAX(id) FROM decisions GROUP BY request_id)")
        fetched = cur.fetchall()
    except Exception as exc:  # noqa: BLE001 - any read failure is an unreadable ledger, never an empty one
        raise LedgerUnreadable(f"the ledger could not be read ({exc})") from exc
    for rid, uid, pid, pop, big, roles, decided in fetched:
        # QA #1800 r11 finding 2: `record_decision` persists claimed_roles COMMA-JOINED, not as JSON.
        # Parsing it as JSON raised ValueError, became (), and every row was then falsely counted as a
        # `role` refusal - the arming dry run would have reported zero eligible rows.
        if isinstance(roles, str):
            role_list = tuple(r.strip() for r in roles.split(",") if r.strip())
        else:
            role_list = tuple(roles or ())
        out[str(rid).lower()] = {"user_id": uid, "profile_id": pid, "popularity": pop,
                                 "big_track": bool(big), "roles": tuple(role_list or ()),
                                 # the ledger has no request createdAt; the decision time is the
                                 # oldest-waiting proxy, and it only ever LOSES priority
                                 "created_at": decided}
    return out


def owners(db, row_map: dict, doc_store, proof_store=None) -> dict:
    """request id -> the account that owns it, for EVERY request a verified document binds.

    QA #1800 r13 finding 2: the dry run passed no `req_users`, so `gate_one_request` skipped the
    cross-account binding check entirely and a document bound to accounts A and B was reported
    `would_approve` although apply refuses it. This builds the SAME owner map decide.py builds: the
    ledger's own decision rows first, then the doc store for requests the ledger never decided. A
    binding with no owner anywhere stays absent, which the gate fails closed on.
    """
    out: dict = {rid: r.get("user_id") for rid, r in row_map.items()}
    try:
        docs = doc_approve.verified_docs(doc_store, proof_store or decide.DOC_PROOF_STORE)
    except (OSError, sqlite3.Error) as exc:
        log(f"doc measurement: the doc store could not be read for owners ({exc}); "
            "bindings without an owner fail closed")
        return out
    bound = {str(i).lower() for ds in docs.values() for d in ds for i in d.candidate_ids}
    missing = sorted(b for b in bound if out.get(b) is None)
    if missing:
        try:
            out.update(decide._ledger_owners(db, missing))
        except Exception as exc:  # noqa: BLE001 - unreadable owners stay unknown: fail closed
            log(f"doc measurement: bound-request owners unreadable from the ledger ({exc})")
        still = sorted(b for b in missing if out.get(b) is None)
        if still:
            try:
                out.update(doc_approve.owners_in_store(doc_store, still))
            except Exception as exc:  # noqa: BLE001 - unreadable owners stay unknown: fail closed
                log(f"doc measurement: bound-request owners unreadable from the doc store ({exc})")
    return out


def core_ages(admin, row_map: dict, *, max_pages: int = CORE_AGE_MAX_PAGES) -> dict:
    """request id -> core's own `user.createdAt`, for the rows the claimant gate has to age.

    QA #1800 r18 finding 1: the claimant gate no longer accepts the ledger's first sighting as an
    account age - the ledger is OUR clock, and an account created five days ago whose first
    `decisions` row is forty days old would pass a 30-day floor it never earned. R22a D2 says a
    missing core `createdAt` is `claimant_no_history`, so a measurement that never asks core reports
    every row as unverifiable and the arming number is structurally 0.

    This reads the SAME population the decider reads (`status=unverified`) and only ever READS. A
    request core does not return keeps no age, which the gate fails closed on.

    QA #1800 r19 finding 1: it used `decide.held_rows`, which stops after 40 pages of 200. Past 8,000
    held requests a document-backed row outside those pages has a real core `createdAt` but measured
    as `claimant_no_history`, understating `would_approve` on exactly the backlog this class exists
    for. This pages until the population is exhausted OR every measured request has been found, and
    RAISES when it stops at the safety bound instead of reporting a short census as complete.
    """
    from . import admin as admin_api
    if not row_map:
        return {}
    want = set(row_map)
    out: dict = {}
    page_size = 200
    for page in range(1, max_pages + 1):
        items = admin_api.list_requests(admin, status=decide.UNVERIFIED, limit=page_size, page=page)
        for req in items:
            rid = str(req.get("id") or "").lower()
            if rid in want:
                out[rid] = decide._account_created_at(req)
        if len(items) < page_size or len(out) == len(want):
            return out
    raise CoreCensusIncomplete(
        f"core pagination stopped at the {max_pages}-page safety bound with"
        f" {len(out)}/{len(want)} account ages read: the census is INCOMPLETE, and a partial census"
        " reported as complete is the one thing a measurement must never be")


_LOAD_POLICY = object()   # sentinel: "measure loads the policy itself, and refuses if it cannot"


def measure(db, *, doc_store, proof_store=None, gate=None, now: datetime | None = None,
            ages: dict | None = None, policy=_LOAD_POLICY) -> dict:
    """The class's full read-only verdict, per document row, plus the cap plan.

    `ages` is the core-age map (`core_ages`); pass `{}` to measure without core, which reports every
    row as `claimant_no_history` - the honest answer when core cannot be asked.

    `policy` supplies the hold sets. Left at its default, `measure` loads it and RAISES
    `PolicyUnreadable` when it cannot: an unreadable policy is not an empty one, and the decider
    fails closed on it, so a measurement that held nobody would report a denied user as approvable
    work (QA #1766 r3 finding 3). Pass an explicit `Policy` to override, or `None` to measure with
    no holds at all - which only a caller that has already decided that is honest should do.

    The result is `doc_approve.dry_run`'s dict: `per_guard`, `verdicts`, `rows`, `would_approve`,
    `admitted`, `would_users`, `would_requests`, `rolled_to_tomorrow`, `spent_users_today`,
    `spent_requests_today`.
    """
    from . import account_gate
    now = now or datetime.now(timezone.utc)
    row_map = rows(db)
    if policy is _LOAD_POLICY:
        policy = load_policy()
        if policy is None:
            raise PolicyUnreadable(
                "the deny/hold policy could not be read, so the hold sets are UNKNOWN")
    hold_users = set()
    if policy is not None:
        hold_users = set(policy.deny_user_ids) | set(policy.deny_profile_ids)
    hold_ids = [rid for rid, r in row_map.items() if r.get("user_id") in hold_users]
    for rid, r in row_map.items():
        r["account_created_at"] = (ages or {}).get(rid)
    return doc_approve.dry_run(
        db, doc_store=doc_store, proof_store=proof_store or decide.DOC_PROOF_STORE, now=now,
        gate=gate if gate is not None else account_gate.Cached(),
        rows=row_map, req_users=owners(db, row_map, doc_store, proof_store),
        hold_ids=hold_ids, hold_users=hold_users)


def load_policy():
    """The deny/hold policy, or None when it cannot be read.

    Returning None is only safe for a caller that then refuses to measure; `measure` raises
    `PolicyUnreadable` rather than holding nobody (QA #1766 r3 finding 3).
    """
    try:
        return decide.Policy.load()
    except (OSError, ValueError) as exc:
        log(f"doc measurement: the deny/hold policy could not be read ({exc})")
        return None


def ledger_path(path=None) -> Path:
    """The decider's own ledger path, imported rather than re-typed.

    QA #1766 r1 finding 3: the watchdog hardcoded `/var/lib/hydra-credit-review/ledger.sqlite`, which
    is not a path the decider has ever written. `_ro` returns None for a missing file, so a live class
    with real approvals read as "0 approvals, no standing refs" and paged a false stall every hour.
    """
    from . import ledger as _ledger
    return Path(path or _ledger.DEFAULT_PATH)
