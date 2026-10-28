"""Pure rules: which approved line (if any) Caroline may give, and why not. No I/O.

Captain and Fable rules this encodes (each is a refusal code, each has a test):
  identity_unverified     the verified Intercom author is not exactly one confirmed Muso account
  facts_unknown           a source could not be read: UNKNOWN never answers (no line)
  owes_proof              any user_verification_needed row, an open row (pending / processing / unverified)
                          with an IDP review_* flag, or an IDP-list hold:
                          every approved line says "nothing else is needed", which is false for them
                          (captain 2026-10-27 12:55Z item 5), and the ask is locked
  account_hold            the shared account gate holds the account (it owes proof too)
  status_note_hold        hold-silent in the verify ledger (Fable ruling 017)
  support_contact_held    emailed support@ in 90 days: a person answers (firstmate 050)
  core_notice_within_7d   core delivered a notice in 7 days (proofRequest / infoRequest / approvedNotice
                          marker, or a claim event): no double (sender map 2026-10-27 §4.1)
  status_changed_today    a request or claim changed status today: core's own notice covers it
  hydra_note_within_7d    a hydra note (any campaign) went to this user in 7 days
  caroline_line_within_7d Caroline already gave an approved status line in 7 days
  decided_not_closed      a validator reject_* row waits on a person's ruling: "with our team" misleads
  nothing_pending         no open request and no pending claim: there is no status to give
  no_titles / no_profile_name   a fact the approved line needs is missing: never a half line

Nothing here approves, rejects, deletes or hides. The output is a line id or None.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from datetime import datetime, timedelta
from typing import Optional

from . import copy as approved
from .facts import Facts

WINDOW = timedelta(days=7)


@dataclass
class Decision:
    action: str
    line_id: Optional[str] = None
    reply_line: Optional[str] = None
    refusals: list[str] = field(default_factory=list)
    request_ids: list[str] = field(default_factory=list)
    claim_ids: list[str] = field(default_factory=list)
    note: str = ""

    @property
    def ok(self) -> bool:
        return not self.refusals

    def as_dict(self) -> dict:
        return {"action": self.action, "line_id": self.line_id, "reply_line": self.reply_line,
                "refusals": list(self.refusals), "request_ids": list(self.request_ids),
                "claim_ids": list(self.claim_ids), "note": self.note}


def _within(t: Optional[datetime], now: datetime, window: timedelta = WINDOW) -> bool:
    return t is not None and now - window <= t <= now + timedelta(minutes=5)


def _today(t: Optional[datetime], now: datetime) -> bool:
    return t is not None and t.date() == now.date()


def owes_proof(f: Facts) -> bool:
    open_rows = [r for r in f.requests if r.open]
    return (any(r.status == "user_verification_needed" for r in open_rows)
            or any(r.review_hold for r in open_rows)      # an IDP review_* row on ANY open status (QA @d158f638)
            or f.idp_hold is True)


def common_refusals(f: Facts, now: datetime) -> list[str]:
    """Every rule that blocks ANY approved line for this user. Order is stable (tests pin it)."""
    if f.identity != "resolved":
        return ["identity_unverified"]
    out: list[str] = []
    if f.unknown or f.gate == "unknown" or f.idp_hold is None:
        out.append("facts_unknown")
    if owes_proof(f):
        out.append("owes_proof")
    if f.gate == "hold":
        out.append("account_hold")
    if f.status_note_hold:
        out.append("status_note_hold")
    if f.support_contact:
        out.append("support_contact_held")
    markers = [t for r in f.requests for t in (r.proof_notice_at, r.info_request_at, r.approved_notice_at)]
    markers += [c.updated_at for c in f.claims if c.status != "pending"]
    if any(_within(t, now) for t in markers):
        out.append("core_notice_within_7d")
    if any(_today(r.updated_at, now) for r in f.requests) or any(_today(c.updated_at, now) for c in f.claims):
        out.append("status_changed_today")
    if _within(f.last_hydra_note_at, now):
        out.append("hydra_note_within_7d")
    if _within(f.last_caroline_line_at, now):
        out.append("caroline_line_within_7d")
    return out


def _credit_line(f: Facts, now: datetime, *, doc_just_filed: bool, action: str) -> Decision:
    d = Decision(action)
    open_rows = [r for r in f.requests if r.open]
    d.request_ids = [r.id for r in open_rows]
    d.refusals = common_refusals(f, now)
    if f.identity != "resolved":
        return d
    if not open_rows:
        d.refusals.append("nothing_pending")
    if any(r.reject_rule for r in open_rows):
        d.refusals.append("decided_not_closed")
    if f.doc_pending is None and not doc_just_filed and "facts_unknown" not in d.refusals:
        d.refusals.append("facts_unknown")
    titles = list(dict.fromkeys(r.title.strip() for r in open_rows if r.title.strip()))
    if open_rows and not titles:
        d.refusals.append("no_titles")
    if d.refusals:
        return d
    d.line_id = "status-doc-received" if (doc_just_filed or f.doc_pending) else "status-team-review"
    d.reply_line = approved.render(d.line_id, full_name=f.full_name, track_titles=titles)
    return d


def _claim_line(f: Facts, now: datetime, *, doc_just_filed: bool, action: str) -> Decision:
    d = Decision(action)
    pending = [c for c in f.claims if c.status == "pending"]
    d.claim_ids = [c.id for c in pending]
    d.refusals = common_refusals(f, now)
    if f.identity != "resolved":
        return d
    # A claim with no proof link owes proof (the claim ask is locked). A document just FILED does not
    # change that: a filed document is not an accepted one (Fable, #1402 review), so it never earns the
    # "nothing else is needed" line. doc_just_filed is accepted for symmetry and deliberately unused here.
    if pending and not all(c.has_links for c in pending) and "owes_proof" not in d.refusals:
        d.refusals.append("owes_proof")
    if not pending:
        d.refusals.append("nothing_pending")
    if len(pending) > 1:
        d.refusals.append("multiple_pending_claims")
    if d.refusals:
        return d
    name = f.profile_names.get(pending[0].profile_id, "").strip()
    if not name:
        d.refusals.append("no_profile_name")
        return d
    d.line_id = "claim-status"
    d.reply_line = approved.render("claim-status", full_name=f.full_name, profile_name=name)
    return d


def decide_status(f: Facts, now: datetime, *, topic: str = "credit") -> Decision:
    """The status lookup: one approved line for this topic, or refusals."""
    if topic == "claim":
        return _claim_line(f, now, doc_just_filed=False, action="status")
    if topic != "credit":
        d = Decision("status", refusals=["unsupported_topic"])
        return d
    return _credit_line(f, now, doc_just_filed=False, action="status")


def decide_doc_reply(f: Facts, now: datetime, *, subject: str) -> Decision:
    """After a document is filed: the doc-received line (credit) or the claim-status line (claim), only
    when nothing else is owed. The document is filed either way; the line is what may be withheld."""
    if subject == "claim":
        return _claim_line(f, now, doc_just_filed=True, action="doc-intake")
    return _credit_line(f, now, doc_just_filed=True, action="doc-intake")


MERGE_KINDS = ("profile-merge", "unmerge-request", "track-merge")


def decide_merge_intake(f: Facts, now: datetime, *, kind: str, keep: str, others: list[str],
                        filed_within_7d: Optional[str]) -> Decision:
    """A merge request goes to the merge queue (a ClickUp merge ticket the executor works). Never an
    execution, never a line: there is no approved merge wording, so reply_line stays None."""
    d = Decision("merge-intake")
    if f.identity != "resolved":
        d.refusals.append("identity_unverified")
    if kind not in MERGE_KINDS:
        d.refusals.append("unsupported_kind")
    if not keep or not others:
        d.refusals.append("missing_profiles")
    if keep and keep in others:
        d.refusals.append("keep_in_others")
    if len(others) > 5:
        d.refusals.append("too_many_profiles")
    if filed_within_7d:
        d.refusals.append("already_filed_within_7d")
        d.note = filed_within_7d
    return d


HANDOFF_REASONS = ("owes_proof", "dispute", "decided_not_closed", "account_hold", "facts_unknown",
                   "no_approved_line", "customer_asked_for_person", "claim_proof", "merge_contested", "other")


def decide_handoff(f: Facts, *, reason: str, already: bool) -> Decision:
    d = Decision("handoff")
    if reason not in HANDOFF_REASONS:
        d.refusals.append("unsupported_reason")
    if already:
        d.refusals.append("already_handed_off_within_7d")
    d.request_ids = [r.id for r in f.requests if r.open]
    d.claim_ids = [c.id for c in f.claims if c.status == "pending"]
    return d
