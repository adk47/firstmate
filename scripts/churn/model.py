"""The churned-with-issue user, and the ONE lane each of them belongs to.

Inputs are rows from the support-state store (``support_state.py``, built by
churn-risk-signal-prevent-p1) or from the measured baseline artifact
``winback-candidates.json``; ``state.py`` normalizes either into ``Candidate``.
This module is deliberately pure: no IO, no clock, no policy file, so the lane
decision, the paid-priority order and the holdout are testable in isolation.

Vocabulary (report 0, 0.1):

* **tier** - T1 unanswered / promise-not-kept, T2 open-told-to-wait, T3 silent
  pending credit or claim. ``none`` means no unhandled support state: never routed.
* **cause class** - what the user was actually waiting on: credits, proof, merge or
  claim, analytics, billing, other. The PRIMARY class picks the lane.
* **lane** - the existing intake that owns the fix. Routing is not a new queue.
"""

from __future__ import annotations

import hashlib
from dataclasses import dataclass, field
from typing import Any, Iterable, Mapping

# ── lanes (the OWNING intakes; each one already exists and already has an owner) ──
CREDIT_REVIEW = "credit-review"      # the decider's held-row queue (t01b / #1555 writer)
PROOF = "proof"                      # proof_intake re-read + status-doc-received family
CLAIM = "claim"                      # claim-proof-check-c2 list head
MERGE = "merge"                      # merge-queue-clear-q1 ClickUp intake
REFUND = "refund"                    # refund judge G8 classes / cs-systemic-c3 over $150
ANALYTICS = "analytics"              # analytics-followup ClickUp with profile id + evidence
CAROLINE = "caroline-drain"          # paid-threads-answer-a1 backlog drain, human-quality

LANES = (CREDIT_REVIEW, PROOF, CLAIM, MERGE, REFUND, ANALYTICS, CAROLINE)

#: Cause classes, exactly the report 0.1 set. Anything else normalizes to ``other``.
CLASSES = (
    "credits_not_approved",
    "proof_sent_no_update",
    "merge_claim_stuck",
    "analytics_stale_wrong",
    "billing_confusion",
    "other",
)

#: A billing complaint bigger than this is a systemic refund, not a judge-able G8 row:
#: cs-systemic-c3 owns it (report 3.1). In cents so the comparison is exact.
SYSTEMIC_REFUND_CENTS = 15_000

#: Tiers that count as an unhandled support state. ``none`` never routes.
TIERS = ("T1-unanswered", "T2-open-told-wait", "T3-silent-pending")

#: The stage prefixes the analyzer puts in front of the primary class
#: ("open_told_wait:credits_not_approved"). Stripped, never treated as a class.
_STAGE_PREFIXES = ("open_told_wait", "no_reply", "promise_not_kept")


def normalize_class(raw: Any) -> str:
    """'open_told_wait:credits_not_approved' -> 'credits_not_approved'.

    The measured artifact carries the *stage* in front of the class; a stage is not a
    cause. Unknown text is ``other`` rather than a new lane that nobody drains.
    """
    text = str(raw or "").strip().lower()
    if not text:
        return "other"
    parts = [p.strip() for p in text.split(":") if p.strip()]
    if len(parts) > 1 and parts[0] in _STAGE_PREFIXES:
        text = parts[-1]
    elif text in _STAGE_PREFIXES:
        return "other"
    return text if text in CLASSES else "other"


def tier_rank(tier: Any) -> int:
    """Sort helper: T1 (we went silent on them) outranks T2 outranks T3."""
    text = str(tier or "")
    for i, known in enumerate(TIERS):
        if text.startswith(known[:2]):
            return i
    return len(TIERS)


@dataclass(frozen=True)
class Candidate:
    """One churned paying user who left with an unhandled support state."""

    user_id: str
    tier: str
    primary_class: str
    classes: tuple[str, ...] = ()
    mrr_cents: int = 0
    plan: str = ""
    reason: str = ""
    cancel_at: float = 0.0
    request_at: float | None = None
    wait_days: float = 0.0
    evidence: tuple[str, ...] = ()
    intercom_convs: tuple[str, ...] = ()
    credit_open: Mapping[str, Any] = field(default_factory=dict)
    claims: Mapping[str, Any] | None = None
    refunds: int = 0
    disputes: int = 0
    discount: str | None = None
    customer_id: str | None = None
    profile_id: str | None = None

    # ── derived ──────────────────────────────────────────────────────────────
    @property
    def lane(self) -> str:
        return lane_for(self)

    @property
    def request_ids(self) -> tuple[str, ...]:
        """The open credit request ids this user is waiting on (the decider's key)."""
        ids = self.credit_open.get("request_ids") if isinstance(self.credit_open, Mapping) else None
        return tuple(str(i) for i in ids or () if str(i).strip())

    @property
    def mrr(self) -> float:
        return self.mrr_cents / 100.0

    @property
    def annual(self) -> bool:
        return "annual" in (self.plan or "").lower()

    @property
    def is_regional(self) -> bool:
        return "regional" in (self.discount or "").lower()

    @property
    def charge_cents(self) -> int:
        """What the last charge would have been: a year of list MRR for an annual plan."""
        return self.mrr_cents * 12 if self.annual else self.mrr_cents

    def sort_key(self) -> tuple:
        """Highest list MRR first (the captain's audience order), then the longest wait.

        Wait-days breaks MRR ties because two users at $12.50 are not equally wronged:
        the one who waited 300 days has been ignored for most of a year.
        """
        return (-self.mrr_cents, -float(self.wait_days or 0.0), self.user_id)

    def ticket_key(self) -> str:
        """Idempotency key: one fix ticket per (user, primary class).

        Deliberately NOT time-dependent: a second daily run must find the ticket it
        already wrote, not write a twin. A user whose primary class changes on a later
        measurement gets a second ticket in the lane that class belongs to - which is
        correct, because that is a different thing they are still waiting on.
        """
        raw = f"{self.user_id}\0{self.primary_class}".encode("utf-8")
        return hashlib.sha256(raw).hexdigest()[:24]

    def as_row(self) -> dict[str, Any]:
        return {
            "user_id": self.user_id,
            "tier": self.tier,
            "primary_class": self.primary_class,
            "classes": list(self.classes),
            "mrr_cents": self.mrr_cents,
            "plan": self.plan,
            "reason": self.reason,
            "cancel_at": self.cancel_at,
            "request_at": self.request_at,
            "wait_days": self.wait_days,
            "evidence": list(self.evidence),
            "intercom_convs": list(self.intercom_convs),
            "credit_open": dict(self.credit_open or {}),
            "claims": dict(self.claims) if isinstance(self.claims, Mapping) else None,
            "refunds": int(self.refunds or 0),
            "disputes": int(self.disputes or 0),
            "discount": self.discount,
            "customer_id": self.customer_id,
            "profile_id": self.profile_id,
        }


def lane_for(candidate: Candidate) -> str:
    """Which existing intake owns THIS user's fix.

    Two classes split on evidence rather than on the class name, because the class
    name is the customer's words and the evidence is what actually has to happen:

    * ``merge_claim_stuck`` - a pending claim row goes to the claim list; the rest are
      duplicate-profile merges and go to the merge ClickUp intake.
    * ``billing_confusion`` - always the refund lane; the lane itself escalates a charge
      over ``SYSTEMIC_REFUND_CENTS`` to cs-systemic-c3 (see ``refund_escalates``).
    """
    cls = candidate.primary_class
    if cls == "credits_not_approved":
        return CREDIT_REVIEW
    if cls == "proof_sent_no_update":
        return PROOF
    if cls == "merge_claim_stuck":
        return CLAIM if candidate.claims else MERGE
    if cls == "analytics_stale_wrong":
        return ANALYTICS
    if cls == "billing_confusion":
        return REFUND
    return CAROLINE


def refund_escalates(candidate: Candidate) -> bool:
    """A charge over $150 is a systemic refund (cs-systemic-c3), not a G8 judge row."""
    return candidate.charge_cents > SYSTEMIC_REFUND_CENTS


def holdout(user_id: Any, modulus: int, residue: int) -> bool:
    """True when the user is in the never-messaged control group.

    ``sha256("muso-holdout:<user_id>") % modulus == residue``: a stable hash of the user id,
    so the control group does not drift between runs and the return rate this campaign reports
    is measured against users it provably never touched. The ``muso-holdout:`` prefix is part
    of the assignment - changing it reshuffles every control group mid-campaign.
    """
    if modulus <= 0:
        raise ValueError("holdout modulus must be positive")
    digest = hashlib.sha256(f"muso-holdout:{user_id}".encode("utf-8")).hexdigest()
    return int(digest, 16) % modulus == residue


def in_lane(candidates: Iterable[Candidate]) -> dict[str, list[Candidate]]:
    """Bucket candidates by lane, each bucket in send order (``sort_key``).

    Routing writes the buckets in this order, so the lane's queue is already sorted the
    way R4 asks for: highest list MRR first, longest wait next.
    """
    out: dict[str, list[Candidate]] = {lane: [] for lane in LANES}
    for c in candidates:
        out.setdefault(c.lane, []).append(c)
    for bucket in out.values():
        bucket.sort(key=Candidate.sort_key)
    return {lane: rows for lane, rows in out.items() if rows}
