"""Trust yet verify: tell users which credits the decider approved, and ask for support.

Captain, 2026-10-15 22:12Z (verbatim): "i want AI live now - we have too many
credits to approve and to get supporting data for - let users know where there
was a credit given and that it needs support (trust yet verify approach)".

This is the step that runs AFTER ``credit-review.py decide`` approves
provisional rows. It never decides anything itself:

  1. Candidates are requests the decider's own server re-read recorded as
     approved (``decision_outcomes`` action='approve', outcome='approved'; the
     server's answer, not the decider's intent), that this step has not
     notified yet.
  2. Every candidate is RE-READ from the admin API (GET only) and kept only
     if the server says it is ``approved`` right now. A row a human or
     ``credit-review.py revert`` has moved back is never announced as live.
  3. Rows are grouped by the credit request's ACCOUNT (``user.email``, the
     person who asked for the credit), and each account gets one call to
     scripts/intercom-verify-request.sh. That gate owns the copy, Caroline's
     identity, the leak check, the one-note-per-user-per-day cap and the
     per-request idempotency (the verify ledger). This module only plans.
  4. Proof sweep: every sent note whose note family sent a message in the
     last 45 days goes through ``intercom-verify-request.sh tag-proof``
     (see ``verify_ledger.awaiting_proof`` for which tagged notes are still
     read), which records user replies, tags a reply WITH attachments
     ``credit-proof`` and does nothing else.

The decider ledger contract this reads (the credit-review ledger SQLite file,
schema owned by credit_review/decide.py): ``decision_outcomes(id, run_id, at,
request_id, action, outcome)`` joined to ``decisions(run_id, request_id,
profile_id, track_id)`` on (request_id, run_id), the same query as
``decide.run_approvals``. --since-hours filters on ``decision_outcomes.at``.
A missing table means the decider has not run yet (nothing to do); a table
without those columns is a contract break and fails loud.
"""

from __future__ import annotations

import collections
import json
import os
import re
import sqlite3
import subprocess
import tempfile
import time
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from typing import Any, Callable, Optional

from . import admin as admin_api
from . import affiliation, proof_parts, verify_ledger
from .roles import family_of

WRAPPER = os.environ.get("CREDIT_VERIFY_NOTIFY_WRAPPER", "/opt/hydra/scripts/intercom-verify-request.sh")
# The shared "documents already on file" exclusion the decider uses too (owner: the
# credit-system lane; refreshed hourly, atomic). Past credits: a user_id listed with ANY kind
# is never asked. New credits: per credit (see screen_live). Missing or older than
# PROOF_MAX_AGE_H => zero asks that run.
PROOF_ON_FILE = os.environ.get("CREDIT_PROOF_ON_FILE", "/var/lib/credit-trust/proof-on-file.json")
PROOF_MAX_AGE_H = 3
# Clock skew tolerated on a generated_at stamped AHEAD of now. Beyond it the stamp is wrong,
# so its age is unknowable and the list is not authoritative (a future stamp would otherwise
# pass the age check long after the export went stale).
PROOF_MAX_SKEW_H = 0.1
# Which parts make the list authoritative (core, cs-intercom and cs-gmail, all required):
# credit_review/proof_parts.py, shared with the take-back gate.
CAPTAIN_UID = "U7RP6HKUZ"
DECISION_COLUMNS = ("run_id", "request_id", "profile_id", "track_id")
OUTCOME_COLUMNS = ("id", "run_id", "at", "request_id", "action", "outcome")
PAGE_LIMIT = 200
MAX_PAGES = 10


class ContractError(RuntimeError):
    pass


@dataclass
class Report:
    candidates: int = 0
    not_approved_now: int = 0
    not_found: int = 0
    no_account: int = 0
    users: int = 0
    sent_notes: int = 0
    sent_credits: int = 0
    skipped: int = 0
    deferred_users: int = 0
    pending_doc_users: int = 0
    support_contact_users: int = 0
    support_contact_credits: int = 0
    documented_users: int = 0          # proof on file (any source) for another credit / whole user
    documented_credits: int = 0
    affiliation_held: list[str] = field(default_factory=list)   # "user <id>: <reason>" for a human
    recently_asked_users: int = 0
    recently_asked_credits: int = 0
    paying_unknown: str = ""
    pending_doc_credits: int = 0
    refused_users: int = 0
    failed_users: int = 0
    proof_tagged: int = 0
    claim_proof_tagged: int = 0        # claim-proof-ask replies (any reply) tagged claim-proof (a separate queue)
    claim_replies: int = 0             # claimant replies to a claim-proof-ask note (its reminder withheld)
    proof_failed: int = 0
    reminders_sent: int = 0
    skipped_not_live: int = 0
    excluded: int = 0
    removal_due: int = 0
    extension_requests: int = 0
    held_for_human: int = 0
    unverified: int = 0
    human_approved: int = 0
    trusted_anchor: int = 0            # band-A automation approvals (anchor_kind=trusted): no note, never removal-due
    docs_users: int = 0
    docs_checked: int = 0
    proof_on_file: int = 0
    no_professional_id: int = 0        # no professional id on the account: Intercom identity unverifiable, held
    flagged: int = 0
    mixed_v1_users: int = 0            # users whose one note is v1 because ANY credit is paid provisional
    already_today: int = 0             # messages the ledger already holds for today (counted against the cap)
    paying_hold: str = ""              # paying status unknown and the cap would have to choose: nothing sent
    recipient_ok: int = 0              # dry run with --check-recipients: the real gate accepted the recipient
    validated: int = 0                 # dry run: the gate validated (or rendered) the note it would send
    halted: str = ""
    failures: list[str] = field(default_factory=list)
    refusals: list[str] = field(default_factory=list)
    flag_failures: list[str] = field(default_factory=list)

    @property
    def failed(self) -> bool:
        return bool(self.failed_users or self.proof_failed or self.halted or self.flag_failures)

    def render(self, mode: str, title: str = "VERIFY NOTES") -> str:
        if self.halted:
            return (f"{title}: NO asks sent this run: {self.halted}. Nothing was sent "
                    "(missing or stale proof-on-file list: when in doubt, no ask goes out).")
        # Deferred accounts alone are not news: they recur every run until tomorrow's note.
        # Held-for-human users are news too (once a day): a human must see them.
        if not (self.sent_notes or self.refused_users or self.failed_users or self.reminders_sent
                or self.proof_tagged or self.proof_failed or self.extension_requests
                or self.claim_proof_tagged or self.claim_replies
                or self.affiliation_held or self.documented_users or self.support_contact_users
                or self.paying_hold or self.no_professional_id) and mode == "apply":
            return "NO_REPLY"
        head = f"{title} (dry run, nothing sent)" if mode != "apply" else title
        parts = [f"{head}: {self.sent_notes} note(s) sent covering {self.sent_credits} provisionally approved credit(s)"
                 if mode == "apply" else f"{head}: {self.users} account(s) would get a note"]
        if self.no_professional_id:
            parts.append(f"{self.no_professional_id} account(s) held: no professional id on the account, so the "
                         "Intercom recipient cannot be matched to it")
        if self.recipient_ok:
            parts.append(f"{self.recipient_ok} recipient(s) accepted by the real gate (read only)")
        if self.paying_hold:
            parts.append(self.paying_hold)
        elif self.paying_unknown:
            parts.append(f"paying status unknown ({self.paying_unknown}); every note fit under the cap, so order did not matter")
        if self.already_today:
            parts.append(f"{self.already_today} message(s) already sent today counted against the day's cap")
        if self.mixed_v1_users:
            parts.append(f"{self.mixed_v1_users} account(s) got one no-deadline note covering a paid provisional "
                         "credit and other new credits (one note per user; no removal date)")
        if self.deferred_users:
            parts.append(f"{self.deferred_users} account(s) already had today's note (their credits go in tomorrow's)")
        if self.refused_users:
            parts.append(f"{self.refused_users} refused by the gate: " + "; ".join(self.refusals[:5]))
        if self.not_approved_now:
            parts.append(f"{self.not_approved_now} no longer approved on the server (not announced)")
        if self.proof_on_file:
            parts.append(f"{self.proof_on_file} credit(s) with documents already on file (not asked)")
        if self.pending_doc_users:
            parts.append(f"{self.pending_doc_users} account(s) ({self.pending_doc_credits} credit(s)) waiting while a "
                         "document they sent for another credit is reviewed (asked once, after the review)")
        if self.documented_users:
            parts.append(f"{self.documented_users} account(s) ({self.documented_credits} credit(s)) held for a human: "
                         "documents already on file for them (never asked)")
        if self.affiliation_held:
            parts.append(f"{len(self.affiliation_held)} account(s) held for a human (org affiliation unknown or "
                         "affiliated; polite-contact variant): " + "; ".join(self.affiliation_held[:5]))
        if self.recently_asked_users:
            parts.append(f"{self.recently_asked_users} account(s) ({self.recently_asked_credits} credit(s)) waiting: "
                         "asked in the last 90 days")
        if self.support_contact_users:
            parts.append(f"{self.support_contact_users} account(s) ({self.support_contact_credits} credit(s)) held for a "
                         "human: emailed support@ in the last 90 days (no note)")
        if self.human_approved:
            parts.append(f"{self.human_approved} approved by a person (not asked again)")
        if self.trusted_anchor:
            parts.append(f"{self.trusted_anchor} band-A approval(s) on a trusted anchor (no document ask; core's approved notice only)")
        if self.docs_checked:
            parts.append(f"documents already sent by {self.docs_users} of {self.docs_checked} account(s) checked (not asked)")
        if self.no_account:
            parts.append(f"{self.no_account} with no account email on the request (not announced)")
        if self.reminders_sent:
            parts.append(f"{self.reminders_sent} reminder(s) sent")
        if self.removal_due:
            parts.append(f"{self.removal_due} new credit(s) past the reply-by date their note named, with no proof (removal due)")
        if self.extension_requests:
            parts.append(f"{self.extension_requests} user repl(ies) to a note recorded: those credits' removal is held "
                         "for a human to pick up")
        if self.held_for_human:
            parts.append(f"{self.held_for_human} new credit(s) past the reply-by date held for a human (a document awaits "
                         "review, the user replied, or a rejection is not yet explained to them; the --removal-due "
                         "export lists them separately)")
        if self.unverified:
            parts.append(f"{self.unverified} past credit(s) with no documents 30+ days after the ask (flagged unverified; they stay)")
        if self.proof_tagged:
            parts.append(f"{self.proof_tagged} proof repl(ies) tagged credit-proof for review")
        if self.claim_replies:
            parts.append(f"{self.claim_replies} claimant repl(ies) to a claim-proof-ask note recorded: no day-7 "
                         "reminder; with a person")
        if self.claim_proof_tagged:
            parts.append(f"{self.claim_proof_tagged} claim repl(ies) tagged claim-proof for a person")
        if self.failed_users or self.proof_failed:
            parts.append(f"FAILED: {self.failed_users} send(s), {self.proof_failed} proof tag(s): " + "; ".join(self.failures[:5]))
        return ". ".join(parts) + "."


def _columns(db: sqlite3.Connection, table: str) -> set[str]:
    return {str(r[1]) for r in db.execute(f"PRAGMA table_info({table})").fetchall()}


def candidates(db: sqlite3.Connection, *, run_id: str | None = None, since_hours: int | None = None,
               now: datetime | None = None) -> list[tuple[str, str, str]]:
    """(request_id, profile_id, track_id) the decider's server re-read confirmed as
    approved, oldest first, minus everything the verify ledger already notified/refused,
    plus every credit the ledger holds back for a pending document (whatever its age).
    Read exactly as decide.run_approvals does: decision_outcomes action='approve' AND
    outcome='approved', joined to decisions on (request_id, run_id)."""
    seen: dict[str, tuple[str, str]] = {}
    for rid, pid, tid in _decider_approvals(db, run_id=run_id, since_hours=since_hours, now=now):
        seen.setdefault(rid, (pid, tid))
    for rid, pid, tid in verify_ledger.deferred(db, campaign="verify-live"):
        if pid:
            seen.setdefault(rid, (pid, tid))
    blocked = verify_ledger.blocked_ids(db, list(seen))
    return [(rid, pid, tid) for rid, (pid, tid) in seen.items() if rid not in blocked]


def _decider_approvals(db: sqlite3.Connection, *, run_id: str | None, since_hours: int | None,
                       now: datetime | None) -> list[tuple[str, str, str]]:
    dcols, ocols = _columns(db, "decisions"), _columns(db, "decision_outcomes")
    if not dcols or not ocols:
        return []
    missing = [f"decisions.{c}" for c in DECISION_COLUMNS if c not in dcols]
    missing += [f"decision_outcomes.{c}" for c in OUTCOME_COLUMNS if c not in ocols]
    if missing:
        raise ContractError(f"the decider ledger lacks {', '.join(missing)} (see credit_review/verify_notify.py candidates)")
    q = ("SELECT o.request_id, d.profile_id, d.track_id FROM decision_outcomes o JOIN decisions d "
         "ON d.request_id = o.request_id AND d.run_id = o.run_id "
         "WHERE o.action = 'approve' AND o.outcome = 'approved'")
    args: list[Any] = []
    if "evidence_kind" in dcols:
        # Fable 10-22 09:30Z: a score approval anchored on a trusted-source credit is band A: no
        # provisional window, no verify note.
        q += " AND coalesce(d.evidence_kind, '') != 'validator_low_risk_trusted'"
    if run_id:
        q += " AND o.run_id = ?"
        args.append(run_id)
    if since_hours:
        since = ((now or datetime.now(timezone.utc)) - timedelta(hours=since_hours)).strftime("%Y-%m-%dT%H:%M:%SZ")
        q += " AND o.at >= ?"
        args.append(since)
    q += " ORDER BY o.id"
    out: list[tuple[str, str, str]] = []
    for r in db.execute(q, args).fetchall():
        rid, pid, tid = str(r[0] or ""), str(r[1] or ""), str(r[2] or "")
        if rid and pid:
            out.append((rid, pid, tid))
    return out


def _take(items: list[dict[str, Any]], left: set[str], found: dict[str, dict[str, Any]]) -> None:
    for it in items:
        rid = str(it.get("id") or "")
        if rid in left and str(it.get("status") or "") == "approved":
            found[rid] = it
            left.discard(rid)


def reread(admin: admin_api.Admin, wanted: list[tuple[str, str, str]]) -> tuple[dict[str, dict[str, Any]], set[str]]:
    """Server truth for each wanted id: (rows the server says are approved NOW, by id;
    ids it does not). GET /admin/credit-requests has no id filter, so a profile's
    approved rows are paged (newest first); a row still unseen after that is looked up
    by its (profile, track) pair when the decider recorded the track."""
    by_profile: dict[str, set[str]] = {}
    tracks: dict[str, tuple[str, str]] = {}
    for rid, pid, tid in wanted:
        by_profile.setdefault(pid, set()).add(rid)
        if tid:
            tracks[rid] = (pid, tid)
    found: dict[str, dict[str, Any]] = {}
    for pid, ids in by_profile.items():
        left = set(ids)
        for page in range(1, MAX_PAGES + 1):
            items = admin_api.list_requests(admin, status="approved", limit=PAGE_LIMIT, page=page, profile_ids=[pid])
            _take(items, left, found)
            if not left or len(items) < PAGE_LIMIT:
                break
        for rid in sorted(left):
            if rid in tracks:
                data = admin.get("/admin/credit-requests", {"status": "approved", "limit": 50, "page": 1,
                                                            "profilesIds": pid, "trackId": tracks[rid][1]})
                items = data.get("items") if isinstance(data, dict) else None
                if not isinstance(items, list):
                    raise admin_api.AdminError("credit-requests list has no items[]")
                _take(items, left, found)
    missing = {rid for rid, _, _ in wanted if rid not in found}
    return found, missing


class ProofFileError(RuntimeError):
    pass


class ProofOnFile(dict[str, list[tuple[Optional[str], str]]]):
    """Documents on file per user id, plus who emailed support@ in the last 90 days
    (``support_contacts``, user ids as strings): those users get no note while listed -
    held for a human (firstmate 050, the decider's rule)."""

    def __init__(self, *args: Any, support_contacts: frozenset[str] = frozenset(), **kw: Any):
        super().__init__(*args, **kw)
        self.support_contacts = support_contacts


def is_support_contact(documented: dict[str, Any], uid: str) -> bool:
    return bool(uid) and uid in getattr(documented, "support_contacts", frozenset())


def load_proof_on_file(path: str | None = None, *, max_age_h: float = PROOF_MAX_AGE_H,
                       now: datetime | None = None) -> ProofOnFile:
    """Documents on file, per user id: [(request_id or None for a whole-user entry, kind)]
    (captain: "make sure you arent asking for things from users that already submitted
    documents and we approved. dont piss anyoen off"). Schema: {generated_at, sources[],
    users, entries: [{user_id, request_id|null, kind, source, ref}]}; kinds approved_doc,
    pending_doc, human_approved_after_doc. Past credits: any entry excludes the whole user.
    New credits: screen_live. A missing, unreadable, stale, future-dated or half-written file,
    or one with any malformed entry, raises ProofFileError: when in doubt, no ask goes out
    (which parts must be usable: credit_review/proof_parts.py)."""
    path = path or PROOF_ON_FILE
    try:
        with open(path, encoding="utf-8") as fh:
            doc = json.load(fh)
    except FileNotFoundError as exc:
        raise ProofFileError(f"the proof-on-file list {path} is missing") from exc
    except (OSError, json.JSONDecodeError) as exc:
        raise ProofFileError(f"the proof-on-file list {path} is unreadable ({type(exc).__name__})") from exc
    if not isinstance(doc, dict) or not isinstance(doc.get("entries"), list):
        raise ProofFileError(f"the proof-on-file list {path} has no entries[]")
    from .evidence import parse_ts
    gen = parse_ts(doc.get("generated_at"))
    if gen is None:
        raise ProofFileError(f"the proof-on-file list {path} has no readable generated_at")
    now = now or datetime.now(timezone.utc)
    age_h = (now - gen).total_seconds() / 3600
    if age_h < -PROOF_MAX_SKEW_H:
        raise ProofFileError(f"the proof-on-file list {path} is dated {-age_h:.1f}h in the future")
    if age_h > max_age_h:
        raise ProofFileError(f"the proof-on-file list {path} is {age_h:.1f}h old (limit {max_age_h:g}h)")
    # Completeness (Fable review of hydra#1239, F1): a half-written export must never be
    # authoritative. sources[] must be a non-empty list that names every required part, each
    # fresh and neither stale nor missing; `users` must equal the distinct user ids in
    # entries[]. Anything else: when in doubt, no ask goes out.
    # Every entry must be well-formed (QA review of hydra#1239): a malformed row may be the
    # one user with a document on file, so it is never skipped -- the whole file is refused.
    try:
        proof_parts.check(doc, now=now, max_age_h=max_age_h, max_skew_h=PROOF_MAX_SKEW_H)
        proof_parts.check_entries(doc)
    except proof_parts.PartsError as exc:
        raise ProofFileError(f"the proof-on-file list {path}: {exc}") from exc
    contacts = proof_parts.support_contacts(doc, now=now, max_age_h=max_age_h, max_skew_h=PROOF_MAX_SKEW_H)
    if contacts is None:
        raise ProofFileError(f"the proof-on-file list {path} has no readable, fresh {proof_parts.SUPPORT_CONTACTS} "
                             "snapshot (anyone may have emailed support@)")
    out = ProofOnFile(support_contacts=frozenset(str(u) for u in contacts))
    for e in doc["entries"]:
        rid = str(e.get("request_id") or "").strip() or None
        out.setdefault(str(e["user_id"]).strip(), []).append((rid, e["kind"]))
    return out


def _user_id(req: dict[str, Any]) -> str:
    user = req.get("user") if isinstance(req.get("user"), dict) else {}
    return str(user.get("id") or req.get("userId") or "")


def drop_documented(rows: dict[str, dict[str, Any]], documented: ProofOnFile, report: Report) -> list[str]:
    """Past credits: remove requests whose account user is on the proof-on-file list with
    any entry; return their ids."""
    gone = [rid for rid, req in rows.items() if _user_id(req) in documented]
    for rid in gone:
        del rows[rid]
    report.proof_on_file += len(gone)
    # Emailed support@ in the last 90 days: no note, held for a human. Not closed (the
    # credit is offered again once the user is off the list or a human has ruled).
    held = {rid: _user_id(req) for rid, req in rows.items() if is_support_contact(documented, _user_id(req))}
    for rid in held:
        del rows[rid]
    report.support_contact_users += len(set(held.values()))
    report.support_contact_credits += len(held)
    return gone


def screen_live(rows: dict[str, dict[str, Any]], documented: ProofOnFile,
                report: Report) -> tuple[list[str], list[tuple[str, str, str]]]:
    """NEW credits: the documents rule is per credit, and nothing escapes the 30-day rule
    silently. In place, per account user; returns (ids to close, credits to hold back):
      - a credit with its own proof-on-file entry (any kind), approved by a person, or a
        band-A automation approval (metadata.approval.anchor_kind = trusted, Fable 10-22
        23:10Z) is not asked about; its id is returned so the caller can close it;
      - if credits are left to ask about and the user emailed support@ in the last 90 days
        (firstmate 050) or has ANY proof-on-file entry (another credit, a whole-user
        document of any kind, any source: Fable 2026-10-17 precondition 1), the user gets
        no note: those credits are returned as (request_id, profile_id, track_id) for the
        ledger's deferred rows, so they are offered again on every run and a human sees
        them (a pending_doc keeps its old meaning: one batched ask once it is reviewed)."""
    own = _documented_ids(documented)
    by_user: dict[str, list[str]] = {}
    for rid, req in rows.items():
        by_user.setdefault(_user_id(req), []).append(rid)
    closed: list[str] = []
    held: list[tuple[str, str, str]] = []
    for uid, rids in by_user.items():
        documented_here = [rid for rid in rids if rid in own]
        by_person = [rid for rid in rids if rid not in own and human_approved(rows[rid])]
        band_a = [rid for rid in rids if rid not in own and rid not in by_person and trusted_anchor(rows[rid])]
        ask = [rid for rid in rids if rid not in own and rid not in by_person and rid not in band_a]
        if ask and is_support_contact(documented, uid):
            # firstmate 050: emailed support@ in the last 90 days - no note, held for a
            # human; the credits to ask about are not closed, so they are offered again.
            report.support_contact_users += 1
            report.support_contact_credits += len(ask)
        elif ask and documented.get(uid):
            # Fable 2026-10-17 (verify-notify enable, precondition 1): a user with proof on
            # file from ANY source (Intercom, support@, core) is never notified. A document
            # under review keeps the old meaning (asked once, after the review); any other
            # entry is held for a human. Nothing is closed: the credits are offered again.
            if any(kind == "pending_doc" for _, kind in documented[uid]):
                report.pending_doc_users += 1
                report.pending_doc_credits += len(ask)
            else:
                report.documented_users += 1
                report.documented_credits += len(ask)
        else:
            ask = []
        held += [(rid, str(rows[rid].get("profileId") or ""), str(rows[rid].get("trackId") or "")) for rid in ask]
        for rid in ask:
            del rows[rid]
        for rid in documented_here + by_person + band_a:
            del rows[rid]
        report.proof_on_file += len(documented_here)
        report.human_approved += len(by_person)
        report.trusted_anchor += len(band_a)
        closed += documented_here + by_person + band_a
    return closed, held


def _documented_ids(documented: ProofOnFile) -> set[str]:
    return {rid for entries in documented.values() for rid, _ in entries if rid}


def undocumented_removal_due(db: sqlite3.Connection, documented: ProofOnFile, *, day: str,
                             held: bool = False) -> list[dict[str, Any]]:
    """The ledger's removal-due credits (held=True: the ones held for a human, see
    verify_ledger.held_for_human) minus any credit with its own proof-on-file entry (any kind: a document
    waiting for review is not a missing one). Ledger only."""
    own = _documented_ids(documented)
    rows = verify_ledger.held_for_human(db, day=day) if held else verify_ledger.removal_due(db, day=day)
    return [r for r in rows if r["request_id"] not in own]


def removal_due(db: sqlite3.Connection, admin: admin_api.Admin, documented: ProofOnFile, *,
                day: str) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    """The removal export: (removal-due credits, credits held for a human), each from undocumented_removal_due minus any credit a person approved
    (re-read from the admin API). The remover still re-checks each one."""
    due = undocumented_removal_due(db, documented, day=day)
    held = undocumented_removal_due(db, documented, day=day, held=True)
    wanted = [(r["request_id"], str(r["profile_id"]), str(r["track_id"] or "")) for r in due + held if r["profile_id"]]
    live, _ = reread(admin, wanted) if wanted else ({}, set())
    by_person = {rid for rid, req in live.items() if human_approved(req)}
    # Proof is matched by USER as well as by credit (firstmate 042): a user with a
    # whole-user document waiting for review (e.g. emailed to support@, no request id)
    # never reaches a per-credit removal day - their credits are held for a human.
    waiting = {rid for rid, req in live.items()
               if _user_pending_doc(documented, _user_id(req)) or is_support_contact(documented, _user_id(req))}
    for r in due:
        if r["request_id"] in waiting:
            r["reason"] = verify_ledger.HELD_AWAITING_REVIEW
    return ([r for r in due if r["request_id"] not in by_person and r["request_id"] not in waiting],
            [r for r in held if r["request_id"] not in by_person]
            + [r for r in due if r["request_id"] in waiting and r["request_id"] not in by_person])


def _user_pending_doc(documented: ProofOnFile, uid: str) -> bool:
    """The user has a whole-user (no request id) document waiting for review."""
    return bool(uid) and any(rid is None and kind == "pending_doc" for rid, kind in documented.get(uid, []))


def human_approved(req: dict[str, Any]) -> bool:
    """A person approved this request (metadata.approval.isAgent is false, the stamp
    core-backend's approvalRecord.js writes). Captain standing order: never ask about
    a credit someone approved after seeing documents; we cannot tell which human
    approvals saw documents, so none is asked about."""
    meta = req.get("metadata") if isinstance(req.get("metadata"), dict) else {}
    appr = meta.get("approval") if isinstance(meta.get("approval"), dict) else {}
    return appr.get("isAgent") is False


def trusted_anchor(req: dict[str, Any]) -> bool:
    """A band-A automation approval: core's metadata.approval.anchor_kind is "trusted" (the
    server-computed band; Fable ruling 2026-10-22 23:10Z on firstmate 095). Core stamps every
    automation approval provisional, but a trusted-anchor one gets NO document ask, only core's
    standard "approved" notice, and is never removal-due: the note is keyed on anchor_kind,
    never on the provisional flag."""
    meta = req.get("metadata") if isinstance(req.get("metadata"), dict) else {}
    appr = meta.get("approval") if isinstance(meta.get("approval"), dict) else {}
    return appr.get("anchor_kind") == "trusted"


def drop_human_approved(rows: dict[str, dict[str, Any]], report: Report) -> list[str]:
    """Remove human-approved requests from `rows` in place; return their ids."""
    gone = [rid for rid, req in rows.items() if human_approved(req)]
    for rid in gone:
        del rows[rid]
    report.human_approved += len(gone)
    return gone


def _andjoin(xs: list[str]) -> str:
    xs = [x for x in xs if x]
    if len(xs) <= 1:
        return xs[0] if xs else ""
    return ", ".join(xs[:-1]) + " and " + xs[-1]


# roles.family_of -> the gate's document-list family (retro-past copy).
DOC_FAMILY = {"mix": "mix_master", "remix": "mix_master", "master": "mix_master", "immersive_mix": "mix_master",
              "immersive_master": "mix_master", "remaster": "mix_master", "producer": "producer",
              "exec_producer": "producer", "writer": "writer", "engineer": "engineer", "assistant": "engineer",
              "performer": "musician", "programming": "musician", "arranger": "musician"}


# Organization roles take the studio/organization document list (Fable copy GO 10-16,
# copy-studio-organization.md), never the musician list; A&R has its own list (copy review
# 2026-10-17). A person on the studio staff (Engineer, Assistant) keeps the engineer list.
STUDIO_ORG_ROLES = ("studio", "record label", "label", "publisher", "management", "distributor",
                    "production company")


def doc_family(role: str) -> str:
    r = " ".join((role or "").lower().replace("&", " & ").split())
    if "studio manager" in r:
        return "engineer"  # a person on the studio staff
    if any(k in r for k in STUDIO_ORG_ROLES) and "engineer" not in r:
        return "studio_org"
    fam = family_of(role)
    if fam == "anr":
        return "anr"
    return DOC_FAMILY.get(fam, "other")


def doc_families(roles: list[str]) -> list[str]:
    return list(dict.fromkeys(doc_family(r) for r in roles)) or ["other"]


def credit_line(req: dict[str, Any]) -> dict[str, Any] | None:
    artists = req.get("spotifyTrackArtists") if isinstance(req.get("spotifyTrackArtists"), list) else []
    artist = str((artists[0] or {}).get("name") or "") if artists and isinstance(artists[0], dict) else ""
    roles = [str(c) for c in (req.get("credits") or []) if c]
    title = str(req.get("spotifyTrackTitle") or "")
    if not (roles and title and artist):
        return None
    return {"request_id": str(req.get("id")), "role": _andjoin(roles), "track_title": title, "artist_name": artist,
            "role_families": doc_families(roles), "profile_id": str(req.get("profileId") or ""),
            "track_id": str(req.get("trackId") or "")}


def plan(rows: dict[str, dict[str, Any]], report: Report,
         key: Callable[[dict[str, Any]], Any] | None = None, dropped: list[str] | None = None) -> list[dict[str, Any]]:
    """One {user, credits} payload per account, in the order of the first credit
    each account has under `key` (default oldest first); credits keep that order.
    Requests that cannot be announced (no account email, title or artist) go to
    `dropped` so the caller can close them instead of re-offering them every run."""
    groups: dict[str, dict[str, Any]] = {}
    for req in sorted(rows.values(), key=key or (lambda r: str(r.get("createdAt") or ""))):
        user = req.get("user") if isinstance(req.get("user"), dict) else {}
        email = str(user.get("email") or "").strip().lower()
        line = credit_line(req)
        if not email or line is None:
            report.no_account += 1
            if dropped is not None:
                dropped.append(str(req.get("id")))
            continue
        full = str(user.get("fullName") or "").strip()
        g = groups.setdefault(email, {"user": {"email": email, "id": str(user.get("id") or ""),
                                               "first_name": full.split(" ")[0] if full else ""},
                                      "credits": []})
        g["credits"].append(line)
    return list(groups.values())


Runner = Callable[[list[str]], "subprocess.CompletedProcess[str]"]
Query = Callable[[str], list[list[str]]]
TRINO = "/opt/hydra/scripts/trino-query.sh"
# Kept from #1295/#1298: the identity lookup's Trino command can be overridden (tests, a
# different replica wrapper). Default: the same trino-query.sh.
AUTH_LOOKUP_CMD = os.environ.get("CREDIT_VERIFY_AUTH_LOOKUP_CMD", TRINO)


def trino(sql: str, cmd: str | None = None) -> list[list[str]]:
    """Read-only query against the core replica (Trino)."""
    import csv
    import io
    p = subprocess.run([cmd or TRINO], input=sql, capture_output=True, text=True, timeout=900, check=False)
    if p.returncode:
        raise RuntimeError(f"trino failed: {p.stderr[-300:]}")
    lines = [ln for ln in p.stdout.splitlines() if ln.startswith('"')]
    return list(csv.reader(io.StringIO("\n".join(lines))))


def _run(argv: list[str]) -> "subprocess.CompletedProcess[str]":
    return subprocess.run(argv, capture_output=True, text=True, timeout=180, check=False)


def _first_line(text: str) -> str:
    return (text.strip().splitlines() or [""])[0][:200]


def send_all(payloads: list[dict[str, Any]], report: Report, *, mode: str,
             wrapper: str = WRAPPER, runner: Runner = _run, extra: list[str] | None = None,
             pace_seconds: float = 0.0, preview_dir: str | None = None, reminder: bool = False,
             check_recipients: bool = False) -> None:
    if mode == "apply" or check_recipients:
        try:
            payloads, _ = attach_identities(payloads, report)
        except Exception as exc:  # noqa: BLE001 - an unreadable replica sends nothing
            report.halted = f"the accounts' professional ids cannot be read from the replica ({exc}); nothing is sent"[:300]
            return
    for i, p in enumerate(payloads):
        if i and pace_seconds and mode == "apply":
            time.sleep(pace_seconds)
        fd, path = tempfile.mkstemp(prefix="verify-note-", suffix=".json")
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as fh:
                json.dump({"user": p["user"], "credits": p["credits"], **({"claim": p["claim"]} if "claim" in p else {})},
                          fh, ensure_ascii=False)
            argv = [wrapper, "send", "--credits-file", path, "--approved-by", CAPTAIN_UID]
            argv += (extra or []) + (p.get("extra") or [])
            if mode != "apply":
                argv.append("--dry-run" if preview_dir else ("--check-recipient" if check_recipients else "--validate"))
            res = runner(argv)
        finally:
            os.unlink(path)
        if preview_dir and mode != "apply" and res.returncode == 0:
            uid = re.sub(r"[^A-Za-z0-9-]", "", str(p["user"].get("id") or ""))[:64]
            out_path = os.path.join(preview_dir, f"{uid or f'{i + 1:05d}'}.txt")
            fdp = os.open(out_path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
            with os.fdopen(fdp, "w", encoding="utf-8") as fh:
                fh.write(res.stdout)
        out, err = _first_line(res.stdout), _first_line(res.stderr)
        if res.returncode == 0 and out.startswith("RECIPIENT OK"):
            report.recipient_ok += 1
        elif res.returncode == 0 and mode != "apply" and out.startswith(("VALID ", "DRY-RUN ")):
            report.validated += 1
        elif res.returncode == 0 and out.startswith("POSTED") and reminder:
            report.reminders_sent += 1
        elif res.returncode == 0 and out.startswith("POSTED"):
            report.sent_notes += 1
            try:
                report.sent_credits += int(out.rsplit("credits=", 1)[1].split()[0])
            except (IndexError, ValueError):
                report.sent_credits += len(p["credits"])
        elif res.returncode == 0:
            report.skipped += 1
        elif res.returncode == 3:
            report.deferred_users += 1
        elif res.returncode == 1:
            report.refused_users += 1
            report.refusals.append(err.removeprefix("REFUSED: ")[:160])
        else:
            report.failed_users += 1
            report.failures.append(f"rc={res.returncode} {err or out}"[:200])


AUTH_ID_RE = re.compile(r"^[A-Za-z0-9._-]{1,128}$")
PRO_ID_RE = re.compile(r"^[A-Za-z0-9._|-]{1,128}$")


_odd_array_logged = False


def pg_text_array(raw: Any) -> str:
    """credit_requests.credits as Trino returns it: a Postgres text[] LITERAL in a varchar
    (e.g. '{"Record Label"}' or '{Mixing,"Mastering Engineer"}'; Trino cannot CAST it to
    array(varchar)). Returns the roles joined with ', ' ('' when NULL or empty). Any other
    shape is '' too (no role: the request is left out of the uvn-status note, its user held only
    when nothing else is showable, and refused by withdrawal-confirm), logged once per process."""
    global _odd_array_logged
    s = str(raw or "").strip()
    if not s:
        return ""
    if not (s.startswith("{") and s.endswith("}")):
        if not _odd_array_logged:
            _odd_array_logged = True
            from .runner import log
            log(f"credit_requests.credits is not a Postgres text[] literal ({s[:60]!r}); "
                "its request reads as having no role")
        return ""
    body, out, cur, quoted, esc, had = s[1:-1], [], [], False, False, False
    for ch in body:
        if esc:
            cur.append(ch)
            esc = False
        elif ch == "\\":
            esc = True
        elif ch == '"':
            quoted = not quoted
            had = True
        elif ch == "," and not quoted:
            out.append("".join(cur))
            cur, had = [], False
        else:
            cur.append(ch)
    if cur or had or out:
        out.append("".join(cur))
    vals = [v.strip() for v in out]
    return ", ".join(v for v in vals if v and v.upper() != "NULL")


def professional_id(raw: Any) -> str:
    """users.neptuneprofessionalid, the id the web app boots Intercom with (its contact
    external_id, firstmate 090): the gate's user.professional_id; '' when missing or malformed."""
    v = str(raw or "").strip()
    return v if PRO_ID_RE.fullmatch(v) else ""


def account_identities(user_ids: list[Any], query: Query | None = None) -> dict[str, dict[str, str]]:
    """{muso user id: {professional_id, auth_id}} from the core replica (Trino, read only)."""
    ids = sorted({int(u) for u in user_ids if str(u).isdigit()})
    out: dict[str, dict[str, str]] = {}
    for i in range(0, len(ids), 500):
        chunk = ",".join(str(u) for u in ids[i:i + 500])
        for uid, pro, auth in (query or (lambda q: trino(q, AUTH_LOOKUP_CMD)))(
                "SELECT CAST(id AS varchar), neptuneprofessionalid, auth0userid FROM postgresql_core.public.users "
                f"WHERE id IN ({chunk})"):
            out[str(uid)] = {"professional_id": professional_id(pro), "auth_id": auth_subject(auth)}
    return out


IDENTITY_LOOKUP: Callable[[list[Any]], dict[str, dict[str, str]]] = account_identities


def attach_identities(payloads: list[dict[str, Any]], report: Report
                      ) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    """(payloads, held): each payload naming a Muso user (user.id) without user.professional_id
    gets the account's professional id and Auth0 subject from the replica; one without a
    professional id is held (report.no_professional_id), never handed to the gate. Payloads
    naming no user (a removal notice's profile owner) pass unchanged. A replica read error
    propagates: the caller sends nothing."""
    need = {id(p) for p in payloads if str(p["user"].get("id") or "") and "professional_id" not in p["user"]}
    if not need:
        return payloads, []
    found = IDENTITY_LOOKUP([p["user"]["id"] for p in payloads if id(p) in need])
    out: list[dict[str, Any]] = []
    held: list[dict[str, Any]] = []
    for p in payloads:
        if id(p) in need:
            ident = found.get(str(p["user"]["id"])) or {}
            if not ident.get("professional_id"):
                report.no_professional_id += 1
                held.append(p)
                continue
            p = {**p, "user": {**p["user"], "professional_id": ident["professional_id"],
                               "auth_id": ident.get("auth_id", "")}}
        out.append(p)
    return out, held


def auth_subject(raw: Any) -> str:
    """The account's Auth0 subject (core users.auth0userid without its auth0| prefix), the
    gate's user.auth_id; '' when missing or malformed (the driver holds that user)."""
    v = re.sub(r"^auth0\|", "", str(raw or "").strip())
    return v if AUTH_ID_RE.fullmatch(v) else ""


SLACK_LIB = os.environ.get("CREDIT_REVIEW_SLACK_LIB",
                           os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "lib", "slack-notify.sh"))
CS_PRIORITY_CHANNEL = "C0BBTAVP44X"  # #cs_priority (only the operations bot is a member)
Poster = Callable[[str], bool]
_EMAIL_RE = re.compile(r"[^\s@<>]+@[^\s@<>]+")


def post_cs_priority(text: str) -> bool:
    """One plain-text post to #cs_priority through scripts/lib/slack-notify.sh (operations bot).
    True only when Slack confirmed it."""
    fd, path = tempfile.mkstemp(prefix="credit-review-flag-", suffix=".json")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            json.dump({"channel": CS_PRIORITY_CHANNEL, "text": text}, fh)
        p = subprocess.run(["bash", "-c", 'source "$1" && slack_notify_payload_file_status "$2"', "slack-flag", SLACK_LIB, path],
                           capture_output=True, text=True, timeout=120, check=False,
                           env={**os.environ, "SLACK_NOTIFY_BOT": "operations",
                                "SLACK_NOTIFY_REQUESTER": "credit-review@hydra-ops"})
        return p.returncode == 0
    finally:
        os.unlink(path)


def flag_refusals(report: Report, *, ledger_path: str, campaigns: list[str] | tuple[str, ...],
                  post: Poster = post_cs_priority, now: datetime | None = None) -> None:
    """Post each re-checkable refusal refused MAX_REFUSALS times to #cs_priority once (Muso user
    id, campaign, reason; never the email) and block it. A failed post leaves it un-flagged
    (retried next run) and is a run failure."""
    db = verify_ledger.connect(ledger_path)
    try:
        for e in verify_ledger.refusals_to_flag(db, campaigns):
            reason = _EMAIL_RE.sub("<email>", e["reason"])[:300]
            text = (f"Caroline's gate refused the {e['campaign']} note for Muso user {e['user_id'] or '(unknown id)'} "
                    f"{e['refusals']} times, {verify_ledger.RECHECK_DAYS} days apart; it is no longer retried and "
                    f"needs a human. Last reason: {reason}")
            if post(text):
                verify_ledger.mark_flagged(db, campaign=e["campaign"], user_key=e["user_key"], now=now)
                report.flagged += 1
            else:
                report.flag_failures.append(f"#cs_priority post failed for user {e['user_id']} ({e['campaign']})")
    finally:
        db.close()


def audit_documents(payloads: list[dict[str, Any]], report: Report, *, path: str, campaign: str,
                    wrapper: str = WRAPPER, runner: Runner = _run) -> None:
    """Read-only: ask the gate (--doc-check) whether each account already sent
    documents. Writes user_id,credits,result (no email) to `path` (0600). The recipient is
    matched like a send (attach_identities): an account without a professional id is held."""
    import csv
    try:
        found, _ = attach_identities(payloads, report)
    except Exception as exc:  # noqa: BLE001 - an unreadable replica checks nothing
        report.halted = f"the accounts' professional ids cannot be read from the replica ({exc}); nothing was checked"[:300]
        return
    kept = {str(p["user"].get("id") or "") for p in found}
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", newline="", encoding="utf-8") as fh:
        w = csv.writer(fh)
        w.writerow(["user_id", "credits", "result"])
        for p in payloads:
            if str(p["user"].get("id") or "") not in kept:
                w.writerow([p["user"].get("id") or "", len(p["credits"]), "held: no professional id on the account"])
        for p in found:
            tfd, tmp = tempfile.mkstemp(prefix="verify-doc-check-", suffix=".json")
            try:
                with os.fdopen(tfd, "w", encoding="utf-8") as tf:
                    json.dump({"user": p["user"], "credits": p["credits"]}, tf, ensure_ascii=False)
                res = runner([wrapper, "send", "--credits-file", tmp, "--approved-by", CAPTAIN_UID,
                              "--campaign", campaign, "--doc-check"])
            finally:
                os.unlink(tmp)
            out = _first_line(res.stdout)
            if res.returncode == 0 and out.startswith("DOCS"):
                result = "docs"
                report.docs_users += 1
            elif res.returncode == 0 and out.startswith("NO_DOCS"):
                result = "no_docs"
            elif res.returncode == 1:
                result = "refused: " + _first_line(res.stderr).removeprefix("REFUSED: ")[:120]
            else:
                result = f"error rc={res.returncode}"
                report.failed_users += 1
                report.failures.append(f"doc-check rc={res.returncode} {_first_line(res.stderr) or out}"[:200])
            report.docs_checked += 1
            w.writerow([p["user"].get("id") or "", len(p["credits"]), result])


def sweep_proofs(db: sqlite3.Connection, report: Report, *, days: int = 30, limit: int = 100,
                 wrapper: str = WRAPPER, runner: Runner = _run) -> None:
    for mid in verify_ledger.awaiting_proof(db, days=days)[:limit]:
        row = verify_ledger.message(db, mid)
        claim = row is not None and row["campaign"] in verify_ledger.CLAIM_CAMPAIGNS
        res = runner([wrapper, "tag-proof", "--message-id", mid])
        verify_ledger.mark_checked(db, message_id=mid)
        lines = res.stdout.strip().splitlines()
        if any(ln.startswith("REPLY RECORDED") for ln in lines):
            if claim:
                report.claim_replies += 1
            else:
                report.extension_requests += 1
        out = next((ln[:200] for ln in lines if not ln.startswith("REPLY RECORDED")), "")
        if res.returncode == 0 and out.startswith("TAGGED") and claim:
            report.claim_proof_tagged += 1
        elif res.returncode == 0 and out.startswith("TAGGED"):
            report.proof_tagged += 1
        elif res.returncode in (0, 3):
            continue
        else:
            report.proof_failed += 1
            report.failures.append(f"tag-proof {mid} rc={res.returncode} {_first_line(res.stderr) or out}"[:200])


def send_followups(db: sqlite3.Connection, admin: admin_api.Admin, report: Report, *, campaign: str, day: str,
                   documented: ProofOnFile, verdicts: dict[str, dict[str, Any]], limit: int, pace_seconds: float,
                   wrapper: str, runner: Runner) -> int:
    """Every follow-up the ledger says is due today: re-read the note's credits and
    send the gate's fixed follow-up for the ones still live, under the same per-credit
    documents rule as the note (screen_live): a credit with its own document on file or
    approved by a person is left out, and a user with a document under review waits.
    The org-affiliation gate applies to a follow-up exactly as to a note (QA review of
    hydra#1257 @53428d0): an unchecked, partially checked or affiliated user gets no automatic
    reminder; it waits (not closed) for the next run. A follow-up with nothing left to send is
    closed in the ledger; only follow-ups that are sent count against `limit`."""
    attempted = 0
    for mid, kind, refs in verify_ledger.reminders_due(db, campaign=campaign, day=day):
        if attempted >= limit:
            break
        wanted = [(str(r.get("request_id")), str(r.get("profile_id") or ""), str(r.get("track_id") or ""))
                  for r in refs if r.get("profile_id")]
        live, _ = reread(admin, wanted) if wanted else ({}, set())
        _, held = screen_live(live, documented, report)
        if held or hold_affiliated(live, verdicts, report):
            continue
        ps = plan(live, report)
        if not ps:
            verify_ledger.close_reminder(db, parent_message_id=mid, kind=kind, day=day,
                                         reason="nothing left to send: every credit documented, approved by a "
                                                "person, no longer approved or not announceable")
            continue
        attempted += len(ps)
        for p in ps:
            p["extra"] = ["--kind", kind, "--parent-message-id", mid]
        send_all(ps, report, mode="apply", wrapper=wrapper, runner=runner,
                 extra=["--campaign", campaign], pace_seconds=pace_seconds, reminder=True)
    return attempted


AFFILIATION_LANE = "credit-trust-llm-t01"


def write_affiliation_priority(db: sqlite3.Connection, *, directory: str | None = None) -> tuple[str, int]:
    """Ask the org-affiliation producer for a FULL check of everyone the next verify-notify
    run may write to: the account users of every candidate credit (decider-approved and not
    yet notified, plus held-back ones), from the decider's decisions.user_id. Called after
    every decider apply run, so the hourly producer has them well before 09:00 Rome.
    Returns (path, number of users)."""
    rids = [rid for rid, _, _ in candidates(db, since_hours=None)]
    uids: set[int] = set()
    for i in range(0, len(rids), 500):
        part = rids[i:i + 500]
        q = f"SELECT DISTINCT user_id FROM decisions WHERE user_id IS NOT NULL AND request_id IN ({','.join('?' * len(part))})"
        uids |= {int(u) for (u,) in db.execute(q, part)}
    path = affiliation.write_priority(AFFILIATION_LANE, uids, directory=directory,
                                      source="credit-trust-llm-t01: verify-notify candidates (decider-approved, not yet noted)")
    return path, len(uids)


def _ref(req: dict[str, Any]) -> tuple[str, str, str]:
    return (str(req.get("id")), str(req.get("profileId") or ""), str(req.get("trackId") or ""))


def hold_affiliated(rows: dict[str, dict[str, Any]], verdicts: dict[str, dict[str, Any]],
                    report: Report) -> list[tuple[str, str, str]]:
    """RULE-org-affiliation: a user with no verdict, or a contributor / verified_org /
    authenticated_domain one, gets no automatic note; listed for a human (polite-contact
    variant). In place; returns the held credits (offered again, nothing closed)."""
    held: list[tuple[str, str, str]] = []
    why_by_user: dict[str, str] = {}
    for rid in list(rows):
        uid = _user_id(rows[rid])
        why = affiliation.hold_reason(verdicts, uid)
        if why:
            held.append(_ref(rows.pop(rid)))
            why_by_user[uid] = why
    report.affiliation_held += [f"user {u}: {w}" for u, w in sorted(why_by_user.items())]
    return held


def hold_recently_asked(db: sqlite3.Connection, payloads: list[dict[str, Any]], rows_by_id: dict[str, dict[str, Any]],
                        report: Report, *, day: str) -> tuple[list[dict[str, Any]], list[tuple[str, str, str]]]:
    """One note per user per 90 days across verify-live and retro-past (the ledger's
    asked_within; the claim enforces it again at the write). Returns (payloads to send,
    credits that wait)."""
    keep: list[dict[str, Any]] = []
    held: list[tuple[str, str, str]] = []
    for p in payloads:
        if verify_ledger.asked_within(db, user_key=p["user"]["email"], day=day, user_id=str(p["user"].get("id") or "")):
            report.recently_asked_users += 1
            report.recently_asked_credits += len(p["credits"])
            held += [_ref(rows_by_id[c["request_id"]]) for c in p["credits"] if c["request_id"] in rows_by_id]
        else:
            keep.append(p)
    return keep, held


PROVISIONAL_KIND = verify_ledger.PROVISIONAL_KIND


def provisional_ids(db: sqlite3.Connection, request_ids: list[str]) -> set[str]:
    """Credits the decider approved as a PAID PROVISIONAL approval (Fable ruling 4): their note
    is the no-threat v1 copy (no date, no removal language) and they are never removal-due
    (firstmate 073). Read from the decider ledger (verify_ledger.provisional_ids)."""
    return verify_ledger.provisional_ids(db, request_ids)


def provisional_copy(payloads: list[dict[str, Any]], prov: set[str], report: "Report | None" = None
                     ) -> list[dict[str, Any]]:
    """Every note is the no-threat v1 copy (firstmate 090, 2026-10-19 23:27Z: the captain dropped
    auto-removal; NO message may say a credit will be removed or name a deadline). One note per
    user (the 90-day re-ask lock). `prov` only feeds the report: users whose note includes a paid
    provisional credit alongside other new credits."""
    out: list[dict[str, Any]] = []
    for p in payloads:
        ids = {c["request_id"] for c in p["credits"]}
        if report is not None and ids & prov and ids - prov:
            report.mixed_v1_users += 1
        out.append({**p, "extra": ["--copy", "v1"]})
    return out


def paid_first(payloads: list[dict[str, Any]], paying: frozenset[int] | None) -> list[dict[str, Any]]:
    """Paying users' notes first (stable: oldest credit first within each group)."""
    if paying is None:
        return payloads
    def is_paying(p: dict[str, Any]) -> bool:
        uid = str(p["user"].get("id") or "")
        return uid.isdigit() and int(uid) in paying
    return sorted(payloads, key=lambda p: not is_paying(p))


def run(admin: admin_api.Admin, *, ledger_path: str | None = None, mode: str = "apply", run_id: str | None = None,
        since_hours: int | None = 168, max_users: int = 150, proof_path: str | None = None,
        sweep: bool = True, wrapper: str = WRAPPER, runner: Runner = _run,
        affiliation_path: str | None = None, check_recipients: bool = False) -> Report:
    """The whole step, once a day (09:00 Europe/Rome). `max_users` is the day's cap on
    messages, reminders included (they go first: the note promised them). Gates, in order:
    proof on file from any source, the support@ 90-day contacts, org affiliation, the shared
    90-day re-ask lock; then paying users first. Any gate source that cannot be read halts
    the run: nothing is sent."""
    report = Report()
    try:
        documented = load_proof_on_file(proof_path)
    except ProofFileError as exc:
        report.halted = str(exc)
        return report
    try:
        verdicts = affiliation.read(affiliation_path)
    except (OSError, ValueError) as exc:
        report.halted = f"the org-affiliation verdicts cannot be read ({exc}); nothing is sent"[:300]
        return report
    from .decide import paying_users  # noqa: PLC0415 (decide imports nothing from here)
    paying, why_paying = paying_users()
    report.paying_unknown = why_paying or ""
    day = datetime.now(timezone.utc).strftime("%Y-%m-%d")
    db = verify_ledger.connect(ledger_path or verify_ledger.DEFAULT_PATH)
    try:
        # The day's cap counts what the ledger already holds for today (a same-day retry or a
        # second invocation never gets a fresh cap), reminders included.
        budget = max(max_users - verify_ledger.messages_today(db, campaign="verify-live", day=day), 0)
        report.already_today = max_users - budget
        if mode == "apply":
            # Day-14 / day-25 reminders of WINDOWED notes count against the day's cap.
            budget -= send_followups(db, admin, report, campaign="verify-live", day=day, documented=documented,
                                     verdicts=verdicts, limit=budget, pace_seconds=0.0, wrapper=wrapper,
                                     runner=runner)
        wanted = candidates(db, run_id=run_id, since_hours=since_hours)
        report.candidates = len(wanted)
        if wanted:
            was_held = {rid for rid, _, _ in verify_ledger.deferred(db, campaign="verify-live")}
            rows, missing = reread(admin, wanted)
            report.not_approved_now = len(missing)
            by_id = dict(rows)
            dropped, held = screen_live(rows, documented, report)
            held += hold_affiliated(rows, verdicts, report)
            dropped += sorted(missing & was_held)
            payloads = plan(rows, report, dropped=dropped)
            payloads, waiting = hold_recently_asked(db, payloads, by_id, report, day=day)
            held += waiting
            payloads = provisional_copy(paid_first(payloads, paying), provisional_ids(db, list(by_id)), report)
            # Paying status unknown (QA review of hydra#1257 @3b5fea9): when today's cap would
            # have to choose who goes first, nothing is sent, so a paying user is never pushed
            # behind older free accounts. Every credit waits for tomorrow (kept, not closed).
            if paying is None and len(payloads) > max(budget, 0):
                report.paying_hold = (f"paying status unknown ({why_paying}) and {len(payloads)} note(s) exceed today's "
                                      f"cap of {max(budget, 0)}: nothing sent, so paying users are never put behind")
                for p in payloads:
                    held += [_ref(by_id[c["request_id"]]) for c in p["credits"] if c["request_id"] in by_id]
                payloads = []
            # The Intercom recipient is matched to the account by its professional id or Auth0
            # subject (the contact's external_id). Neither = cannot verify the recipient: held,
            # never handed to the gate (whose refusal would close the credits for good).
            try:
                payloads, no_id = attach_identities(payloads, report)
            except Exception as exc:  # noqa: BLE001 - an unreadable replica sends nothing
                report.halted = f"the accounts' professional ids cannot be read from the replica ({exc}); nothing is sent"[:300]
                for p in payloads:
                    held += [_ref(by_id[c["request_id"]]) for c in p["credits"] if c["request_id"] in by_id]
                payloads, no_id = [], []
            for p in no_id:
                held += [_ref(by_id[c["request_id"]]) for c in p["credits"] if c["request_id"] in by_id]
            # Over the day's cap: the credits wait for tomorrow (kept in the ledger, so a
            # credit older than the candidate window is never silently dropped).
            for p in payloads[max(budget, 0):]:
                held += [_ref(by_id[c["request_id"]]) for c in p["credits"] if c["request_id"] in by_id]
            payloads = payloads[:max(budget, 0)]
            if mode == "apply" and dropped:
                verify_ledger.skip_requests(db, campaign="verify-live", request_ids=dropped)
            if mode == "apply" and held:
                verify_ledger.defer(db, campaign="verify-live", refs=held)
            report.users = len(payloads)
            send_all(payloads, report, mode=mode, wrapper=wrapper, runner=runner, check_recipients=check_recipients)
        if sweep and mode == "apply":
            sweep_proofs(db, report, days=45, wrapper=wrapper, runner=runner)
        if mode == "apply":
            report.removal_due = len(undocumented_removal_due(db, documented, day=day))
            report.held_for_human = len(undocumented_removal_due(db, documented, day=day, held=True))
    finally:
        db.close()
    return report


# -- retro-past documentation waves (captain 2026-10-15 23:35Z, narrowed 2026-10-16 00:35Z:
# "i dont want to lose users unless its obvious fraud feom tbe past", and 02:00Z: "are you
# annoying people fornbackup that we shpuldnt be?") ------------------------------------
# A no-threat ask to the genuine-risk population in the wave file: no deadline, no
# removal, at most one message per user ever, none to a user who already sent proof.
# Non-response = the credit stays, flagged unverified for the board
# (verify_ledger.unverified_past). Proven fraud is removed by its own take-back path.

CAMPAIGN_RETRO = "retro-past"
WAVE_REQUIRED = ("credit_request_id", "user_id", "profile_id")
BIG_POP = 60


@dataclass
class WaveRow:
    request_id: str
    user_id: str
    profile_id: str
    track_id: str = ""
    tier: str = ""
    pop: int = -1
    paid: bool = False
    claimed: str = ""


def _int(v: Any) -> int:
    try:
        return int(float(str(v)))
    except (TypeError, ValueError):
        return -1


def load_exclusions(path: str | None) -> frozenset[str]:
    """User ids, one per line ('#' comments allowed): accounts whose existing credits
    are handled elsewhere and must never get a past-credit ask."""
    if not path:
        return frozenset()
    out: set[str] = set()
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            uid = line.split("#", 1)[0].strip()
            if uid:
                out.add(uid)
    return frozenset(out)


def load_wave(path: str, *, exclude: frozenset[str] = frozenset(), report: Report | None = None) -> list[WaveRow]:
    """The wave file (the population): CSV, one row per credit request (or per request
    x role; rows are merged per request). Required columns: credit_request_id, user_id,
    profile_id. Optional: track_id, tier, pop_now / pop_at_claim (big = >= 60), paid
    (1/true/yes), claim_date / approved_at. Users in `exclude` are dropped."""
    import csv
    with open(path, newline="", encoding="utf-8") as fh:
        reader = csv.DictReader(fh)
        missing = [c for c in WAVE_REQUIRED if c not in (reader.fieldnames or [])]
        if missing:
            raise ContractError(f"wave file {path} lacks {', '.join(missing)} (see credit_review/verify_notify.py load_wave)")
        rows: dict[str, WaveRow] = {}
        for r in reader:
            rid = (r.get("credit_request_id") or "").strip()
            uid = (r.get("user_id") or "").strip()
            if not rid or not uid:
                continue
            tier = (r.get("tier") or "").strip()
            if uid in exclude:
                if report is not None and rid not in rows:
                    report.excluded += 1
                continue
            pop = max(_int(r.get("pop_now")), _int(r.get("pop_at_claim")))
            w = rows.get(rid)
            if w is None:
                rows[rid] = WaveRow(rid, uid, (r.get("profile_id") or "").strip(), (r.get("track_id") or "").strip(),
                                    tier, pop, str(r.get("paid") or "").strip().lower() in ("1", "true", "yes", "y"),
                                    (r.get("claim_date") or r.get("approved_at") or "").strip())
            else:
                w.pop = max(w.pop, pop)
    return list(rows.values())


def wave_order(rows: list[WaveRow]) -> list[str]:
    """User ids, paid users first, then users with a big track, then the oldest claim."""
    users: dict[str, list[WaveRow]] = {}
    for w in rows:
        users.setdefault(w.user_id, []).append(w)

    def key(uid: str) -> tuple[Any, ...]:
        ws = users[uid]
        return (not any(w.paid for w in ws), not any(w.pop >= BIG_POP for w in ws), min(w.claimed for w in ws), uid)
    return sorted(users, key=key)


def run_wave(admin: admin_api.Admin, *, wave_path: str, ledger_path: str | None = None, mode: str = "dry-run",
             exclude: frozenset[str] = frozenset(), max_users: int = 100, daily_max_notes: int = 600,
             pace_seconds: float = 1.0, sweep: bool = True, preview_dir: str | None = None, today: str | None = None,
             audit_docs: str | None = None, proof_path: str | None = None,
             wrapper: str = WRAPPER, runner: Runner = _run) -> Report:
    """One wave tick: the one note for each of the next users (paid first, big tracks
    first, within the per-run and per-day budgets), then the proof sweep. Every note goes through intercom-verify-request.sh --campaign
    retro-past (send-locked until its copy is approved; dry-run renders it)."""
    report = Report()
    day = today or datetime.now(timezone.utc).strftime("%Y-%m-%d")
    try:
        documented = load_proof_on_file(proof_path)
    except ProofFileError as exc:
        report.halted = str(exc)
        return report
    db = verify_ledger.connect(ledger_path or verify_ledger.DEFAULT_PATH)
    try:
        rows = load_wave(wave_path, exclude=exclude, report=report)
        # Documents already on file: never asked. Dropped before picking, so these users
        # never take a slot of the per-run budget; closed on a real run.
        on_file = [w.request_id for w in rows if w.user_id in documented]
        if on_file:
            report.proof_on_file += len(on_file)
            rows = [w for w in rows if w.user_id not in documented]
            if mode == "apply":
                verify_ledger.skip_requests(db, campaign=CAMPAIGN_RETRO, request_ids=on_file)
        blocked = verify_ledger.blocked_ids(db, [w.request_id for w in rows], CAMPAIGN_RETRO)
        rows = [w for w in rows if w.request_id not in blocked]
        report.candidates = len(rows)
        budget = max(0, min(max_users, daily_max_notes - verify_ledger.sent_today(db, campaign=CAMPAIGN_RETRO, day=day)))
        if mode != "apply":
            budget = max_users
        chosen = set(wave_order(rows)[:budget])
        pick = [w for w in rows if w.user_id in chosen]
        by_id = {w.request_id: w for w in pick}
        if pick:
            live, missing = reread(admin, [(w.request_id, w.profile_id, w.track_id) for w in pick])
            report.not_approved_now = len(missing)
            people = drop_human_approved(live, report) + drop_documented(live, documented, report)
            if mode == "apply" and people:
                report.skipped_not_live += verify_ledger.skip_requests(db, campaign=CAMPAIGN_RETRO, request_ids=people)
            if mode == "apply" and missing:
                report.skipped_not_live += verify_ledger.skip_requests(db, campaign=CAMPAIGN_RETRO, request_ids=sorted(missing))
            rank = {uid: i for i, uid in enumerate(wave_order(pick))}

            def key(req: dict[str, Any]) -> tuple[Any, ...]:
                w = by_id[str(req.get("id"))]
                return (rank.get(w.user_id, 10**9), -w.pop, w.claimed, w.request_id)
            dropped: list[str] = []
            payloads = plan(live, report, key=key, dropped=dropped)
            if mode == "apply" and dropped:
                # Not announceable (no account email / title / artist): close them so these
                # users never take a slot of the per-run budget again.
                report.skipped_not_live += verify_ledger.skip_requests(db, campaign=CAMPAIGN_RETRO, request_ids=dropped)
            report.users = len(payloads)
            if audit_docs and mode != "apply":
                audit_documents(payloads, report, path=audit_docs, campaign=CAMPAIGN_RETRO, wrapper=wrapper,
                                runner=runner)
            else:
                send_all(payloads, report, mode=mode, wrapper=wrapper, runner=runner,
                         extra=["--campaign", CAMPAIGN_RETRO], pace_seconds=pace_seconds, preview_dir=preview_dir)
        if sweep and mode == "apply":
            sweep_proofs(db, report, days=45, wrapper=wrapper, runner=runner)
        report.unverified = len(verify_ledger.unverified_past(db, day=day))
    finally:
        db.close()
    return report


# -- removal notices (firstmate 2026-10-16 15:14Z, captain-driven) --------------------------
# Owners of previously approved credits that WE removed are told which credit and role, why
# and how to dispute. Self-removals are never notified (they did it), and fraud removals are
# silent by captain order (firstmate 15:48Z). One message per owner, batched; idempotent per
# removal event (the verify ledger, campaign removal-notice). Send-locked in the gate.

CAMPAIGN_REMOVAL = "removal-notice"
REMOVAL_REASONS = ("misattributed", "duplicate", "policy")  # "verification" is manual_only (Fable 2026-10-17)
POLICY_REASONS = ("artist_by_non_artist", "org_on_person", "label_role_without_release", "duplicate_profile")
SOURCE_LABELS = ("Spotify credits", "Tidal credits", "Qobuz credits page", "Apple Music credits", "Discogs",
                 "AllMusic", "MusicBrainz")   # no Jaxsta in user copy (captain 03:2xZ)
SELF_ACTORS = frozenset({"self", "owner", "user"})
# The gate's per-credit rules for a removal notice, applied per event here so one bad event
# never refuses its owner's whole batch.
EVENT_ID_RE = re.compile(r"[A-Za-z0-9-]{1,64}")
EVIDENCE_URL_RE = re.compile(r"https://[A-Za-z0-9.-]+(/\S*)?")
INTERNAL_URL_RE = re.compile(r"https://([A-Za-z0-9-]+\.)*(muso\.ai|clickup\.com|slack\.com|intercom\.io|github\.com|"
                             r"gitlab\.com)(/.*)?", re.S)


def _clean(v: Any) -> str:
    return " ".join(str(v or "").split())


def removal_event_problem(ev: dict[str, Any]) -> str:
    """Why the gate would refuse this event ('' when it would not)."""
    if not EVENT_ID_RE.fullmatch(_clean(ev.get("event_id"))):
        return "event_id must be letters, digits and dashes (at most 64)"
    reason = _clean(ev.get("reason")).lower()
    if reason == "verification":
        return "reason 'verification' is manual_only: a named human sends it from the board"
    if reason not in REMOVAL_REASONS:
        return f"unknown reason {reason[:40]!r} (use {', '.join(REMOVAL_REASONS)})"
    if reason == "policy" and _clean(ev.get("policy_reason")).lower() not in POLICY_REASONS:
        return f"a policy removal needs a policy_reason ({', '.join(POLICY_REASONS)}); otherwise it is manual_only"
    if reason == "misattributed" and _clean(ev.get("source_label")) not in SOURCE_LABELS:
        return f"a misattribution needs the real source_label ({', '.join(SOURCE_LABELS)})"
    if len(_clean(ev.get("role"))) > 120 or len(_clean(ev.get("track_title"))) > 200 \
            or len(_clean(ev.get("artist_name"))) > 200:
        return "role, track_title or artist_name exceeds the length caps (120, 200, 200)"
    url = _clean(ev.get("evidence_url"))
    if url and (len(url) > 300 or not EVIDENCE_URL_RE.fullmatch(url)):
        return "evidence_url is not a plain https URL of at most 300 characters"
    if url and INTERNAL_URL_RE.fullmatch(url):
        return "evidence_url points at an internal or Muso surface"
    return ""


def load_removal_events(path: str) -> list[dict[str, Any]]:
    """JSON lines: {event_id, profile_id, track_id?, role, track_title, artist_name, reason,
    evidence_url?, actor, removed_at?}. One line per removed (track, role) credit."""
    out: list[dict[str, Any]] = []
    with open(path, encoding="utf-8") as fh:
        for n, line in enumerate(fh, 1):
            line = line.strip()
            if not line:
                continue
            try:
                ev = json.loads(line)
            except json.JSONDecodeError as exc:
                raise ContractError(f"removal events {path} line {n} is not JSON") from exc
            missing = [k for k in ("event_id", "profile_id", "role", "track_title", "artist_name", "reason", "actor")
                       if not str(ev.get(k) or "").strip()]
            if missing:
                raise ContractError(f"removal events {path} line {n} lacks {', '.join(missing)}")
            out.append(ev)
    return out


def profile_owner(admin: admin_api.Admin, profile_id: str) -> dict[str, str] | None:
    """The claimed owner of a profile (docs/lessons/muso-domain.md ownership rule:
    isClaimed AND exactly one claimed workspace with an email), else None."""
    doc = admin_api.profile(admin, profile_id)
    if doc.get("isClaimed") is not True:
        return None
    claimed = [w for w in (doc.get("workspaces") or []) if isinstance(w, dict) and w.get("isClaimed") is True]
    if len(claimed) != 1 or not str(claimed[0].get("email") or "").strip():
        return None
    return {"email": str(claimed[0]["email"]).strip().lower(), "id": "", "first_name": ""}


@dataclass
class RemovalReport(Report):
    events: int = 0
    self_removals: int = 0
    fraud_silent: int = 0
    no_owner: int = 0
    invalid_events: int = 0
    invalid: list[str] = field(default_factory=list)

    def render(self, mode: str, title: str = "REMOVAL NOTICES") -> str:
        if mode == "apply" and not (self.sent_notes or self.refused_users or self.failed_users or self.invalid_events):
            return "NO_REPLY"
        head = f"{title} (dry run, nothing sent)" if mode != "apply" else title
        parts = [f"{head}: {self.sent_notes} owner(s) told about {self.sent_credits} removed credit(s)"
                 if mode == "apply" else f"{head}: {self.users} owner(s) would be told about {self.candidates} removed credit(s)"]
        parts.append(f"{self.events} removal event(s) read; {self.self_removals} self-removal(s) and "
                     f"{self.fraud_silent} fraud removal(s) are never notified")
        if self.invalid_events:
            parts.append(f"{self.invalid_events} invalid removal event(s) not notified (fix the feed): "
                         + "; ".join(self.invalid[:5]))
        if self.no_owner:
            parts.append(f"{self.no_owner} with no single claimed owner (not notified)")
        if self.deferred_users:
            parts.append(f"{self.deferred_users} owner(s) already had a message today (next run)")
        if self.refused_users:
            parts.append(f"{self.refused_users} refused by the gate: " + "; ".join(self.refusals[:5]))
        if self.failed_users:
            parts.append(f"FAILED: {self.failed_users} send(s): " + "; ".join(self.failures[:5]))
        return ". ".join(parts) + "."


def run_removal_notices(admin: admin_api.Admin, *, events_path: str, ledger_path: str | None = None,
                        mode: str = "dry-run", max_users: int = 100, pace_seconds: float = 1.0,
                        preview_dir: str | None = None, list_path: str | None = None,
                        wrapper: str = WRAPPER, runner: Runner = _run) -> RemovalReport:
    """One pass over a removal-events file (the ongoing feed or the one-time backfill).
    dry-run with --preview/--list writes the rendered notes and the owner list (no emails)
    for firstmate's approval; apply sends through the gate (send-locked until approved)."""
    import csv
    report = RemovalReport()
    events = load_removal_events(events_path)
    report.events = len(events)
    db = verify_ledger.connect(ledger_path or verify_ledger.DEFAULT_PATH)
    try:
        keep: list[dict[str, Any]] = []
        seen: set[str] = set()
        for n, ev in enumerate(events, 1):
            actor = str(ev["actor"]).strip().lower()
            reason = str(ev["reason"]).strip().lower()
            if actor in SELF_ACTORS:
                report.self_removals += 1
                continue
            if reason == "fraud":
                report.fraud_silent += 1
                continue
            eid = _clean(ev["event_id"])
            why = removal_event_problem(ev) or ("duplicate event_id" if eid in seen else "")
            if why:
                report.invalid_events += 1
                report.invalid.append(f"{eid if EVENT_ID_RE.fullmatch(eid) else f'event #{n}'}: {why}")
                continue
            seen.add(eid)
            keep.append({**ev, "event_id": eid})
        blocked = verify_ledger.blocked_ids(db, [str(e["event_id"]) for e in keep], CAMPAIGN_REMOVAL)
        keep = [e for e in keep if str(e["event_id"]) not in blocked]
        report.candidates = len(keep)
        owners: dict[str, dict[str, Any]] = {}
        cache: dict[str, dict[str, str] | None] = {}
        for ev in sorted(keep, key=lambda e: str(e.get("removed_at") or "")):
            pid = str(ev["profile_id"])
            if pid not in cache:
                cache[pid] = profile_owner(admin, pid)
            owner = cache[pid]
            if owner is None:
                report.no_owner += 1
                continue
            g = owners.setdefault(owner["email"], {"user": dict(owner), "credits": [], "profiles": set()})
            g["profiles"].add(pid)
            g["credits"].append({"request_id": str(ev["event_id"]), "role": str(ev["role"]),
                                 "track_title": str(ev["track_title"]), "artist_name": str(ev["artist_name"]),
                                 "reason": str(ev["reason"]).strip().lower(),
                                 "evidence_url": str(ev.get("evidence_url") or ""),
                                 "source_label": str(ev.get("source_label") or ""),
                                 "policy_reason": str(ev.get("policy_reason") or "").strip().lower()})
        payloads = list(owners.values())[:max_users]
        report.users = len(payloads)
        if list_path:
            fd = os.open(list_path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
            with os.fdopen(fd, "w", newline="", encoding="utf-8") as fh:
                w = csv.writer(fh)
                w.writerow(["profile_ids", "credits", "reasons"])
                for p in payloads:
                    reasons = collections.Counter(c["reason"] for c in p["credits"])
                    w.writerow([";".join(sorted(p["profiles"])), len(p["credits"]),
                                ";".join(f"{k}={v}" for k, v in sorted(reasons.items()))])
        send_all([{"user": p["user"], "credits": p["credits"]} for p in payloads], report, mode=mode,
                 wrapper=wrapper, runner=runner, extra=["--campaign", CAMPAIGN_REMOVAL], pace_seconds=pace_seconds,
                 preview_dir=preview_dir)
    finally:
        db.close()
    return report
