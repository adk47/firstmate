"""The never-asked digest: WHO would get one first-contact message, and whether a canary may grow.

This module decides an audience and reads a canary. It sends nothing, renders no copy, writes no ledger row and
calls no gate: the send stays with the one reviewed path (`intercom-verify-request.sh` behind `credit-review.py`),
and nothing here is wired to it. Measured population and the open rulings: data/never-asked-canary-r1/report.md.

One digest per CUSTOMER. A never-asked request is a pending request no verify-ledger row names. A customer's digest
names every such request of theirs that core did not already ask about (`metadata.proofRequest`); a customer with
four of them is one entry carrying four ids, never four entries.

A customer is left out, with one reason, by the first of these that applies (LEFT_OUT, in order):
  stopped            on the per-customer stop list: the undo for one customer, touching nobody else
  never_again        an opt-out, a bounce, or a refused / rejected row on file: never offered again
  document_on_file   a proof entry on file: owed a read, not an ask
  told_by_us         a sent uvn-status ask exists: these rows are a follow-up (uvn-new-rows), not a first contact
  other_note         a sent note of ours in another campaign
  support_contacted  emailed support@ in the last 90 days (the hold another lane owns)
  dsp_in_flight      a DSP capture that has not come back; offered again once it has

The canary is CANARY_USERS customers with a measured outcome. "Refused" is the gate refusing the customer, at the
dry-run check or at the post: since 2026-11-03 a refusal at the check writes no ledger row, so a rate read from
ledger rows alone reads 0 whatever happened. A hold (a 7-day wait, a held thread) is neither sent nor refused, and
an unmeasured outcome is never a pass: both stay out of the rate and are reported beside it.
"""
from __future__ import annotations

import json
from dataclasses import dataclass, field
from pathlib import Path
from typing import Iterable

CANARY_USERS = 500          # customers with a measured outcome before the canary can be read as complete
REFUSAL_BAR = 0.02          # continue only UNDER this; equal is a stop
# The most refusals a complete canary can carry and still be under the bar. One more and no later outcome can
# bring a canary of CANARY_USERS back under it, so the canary stops there instead of spending the rest.
MAX_REFUSED = next(n for n in range(CANARY_USERS, -1, -1) if n < REFUSAL_BAR * CANARY_USERS)

LEFT_OUT = ("stopped", "never_again", "document_on_file", "told_by_us", "other_note", "support_contacted",
            "dsp_in_flight")
OUTCOMES = ("sent", "refused", "held", "unmeasured")

RUNNING, CONTINUE, STOP = "canary_running", "continue", "stop"


class DigestError(Exception):
    """An input that cannot be read as what it claims to be. Nothing is built from it."""


@dataclass(frozen=True)
class Pending:
    """One pending request as core holds it."""
    request_id: str
    user_id: str            # "" when the request has no user: nobody to write to
    created: str            # sortable timestamp text, as the replica prints it
    paid: bool
    core_asked: bool        # core sent its own proof notice for THIS request


@dataclass(frozen=True)
class Holds:
    """Per-customer facts, each a set of user ids, each read by the caller from its own source."""
    stopped: frozenset[str] = frozenset()
    never_again: frozenset[str] = frozenset()
    document_on_file: frozenset[str] = frozenset()
    told_by_us: frozenset[str] = frozenset()
    other_note: frozenset[str] = frozenset()
    support_contacted: frozenset[str] = frozenset()
    dsp_in_flight: frozenset[str] = frozenset()

    def why(self, user_id: str) -> str | None:
        return next((name for name in LEFT_OUT if user_id in getattr(self, name)), None)


@dataclass(frozen=True)
class Digest:
    user_id: str
    paid: bool
    request_ids: tuple[str, ...]    # every never-asked request of this customer core did not ask about, sorted
    oldest: str


@dataclass
class Audience:
    digests: list[Digest] = field(default_factory=list)          # paid first, then oldest request first
    left_out: dict[str, str] = field(default_factory=dict)       # user id -> the one reason
    core_asked_only: set[str] = field(default_factory=set)       # every never-asked request carries core's notice
    no_user: int = 0                                             # never-asked requests with nobody to write to
    never_asked: int = 0                                         # never-asked requests read

    def counts(self) -> dict[str, int]:
        out = {"never_asked_requests": self.never_asked, "no_user_requests": self.no_user,
               "core_asked_only_customers": len(self.core_asked_only), "digests": len(self.digests),
               "digests_paid": sum(d.paid for d in self.digests),
               "digest_requests": sum(len(d.request_ids) for d in self.digests)}
        for name in LEFT_OUT:
            out[f"left_out_{name}"] = sum(1 for why in self.left_out.values() if why == name)
        return out


def _uid(value: object) -> str:
    return str(value if value is not None else "").strip()


def build(pending: Iterable[Pending], asked_ids: Iterable[str], holds: Holds) -> Audience:
    """One Digest per customer who is owed a first contact. `asked_ids` is every request id the verify ledger names,
    in any campaign and with any outcome; ids compare lower-cased."""
    asked = {str(i).strip().lower() for i in asked_ids}
    owed: dict[str, dict[str, str]] = {}        # user -> {request id: created}, core-asked requests left out
    paid: dict[str, bool] = {}
    seen_user: set[str] = set()
    aud = Audience()
    seen_request: set[str] = set()
    for row in pending:
        rid = str(row.request_id).strip().lower()
        if not rid:
            raise DigestError("a pending row with no request id")
        if rid in asked or rid in seen_request:      # a request read twice is still one request
            continue
        seen_request.add(rid)
        aud.never_asked += 1
        uid = _uid(row.user_id)
        if not uid:
            aud.no_user += 1
            continue
        seen_user.add(uid)
        paid[uid] = paid.get(uid, False) or bool(row.paid)
        if not row.core_asked:
            owed.setdefault(uid, {})[rid] = str(row.created)
    aud.core_asked_only = seen_user - set(owed)
    for uid, rows in owed.items():
        why = holds.why(uid)
        if why:
            aud.left_out[uid] = why
            continue
        aud.digests.append(Digest(uid, paid[uid], tuple(sorted(rows)), min(rows.values())))
    aud.digests.sort(key=lambda d: (not d.paid, d.oldest, d.user_id))
    return aud


def load_stop_list(path: str | Path) -> frozenset[str]:
    """The per-customer stop list: a JSON array of user ids. A missing file stops nobody; a file that is there and
    cannot be read as that array raises, because "could not read who is stopped" must never build an audience."""
    p = Path(path)
    if not p.exists():
        return frozenset()
    try:
        data = json.loads(p.read_text())
    except (OSError, ValueError) as exc:
        raise DigestError(f"stop list unreadable: {p}: {exc}") from exc
    if not isinstance(data, list) or any(isinstance(i, (dict, list, bool)) or i is None for i in data):
        raise DigestError(f"stop list is not a JSON array of user ids: {p}")
    return frozenset(_uid(i) for i in data if _uid(i))


@dataclass(frozen=True)
class Reading:
    """The canary as measured: one outcome per customer, the newest one."""
    sent: int
    refused: int
    held: int
    unmeasured: int

    @property
    def measured(self) -> int:
        return self.sent + self.refused

    @property
    def rate(self) -> float | None:
        return self.refused / self.measured if self.measured else None


def read_canary(outcomes: dict[str, str]) -> Reading:
    """`outcomes` is {user id: outcome}, one per customer. An outcome outside OUTCOMES raises: a result this code
    does not know is not counted as sent."""
    unknown = sorted({o for o in outcomes.values() if o not in OUTCOMES})
    if unknown:
        raise DigestError(f"unknown canary outcome(s): {', '.join(unknown)}")
    tally = {name: sum(1 for o in outcomes.values() if o == name) for name in OUTCOMES}
    return Reading(tally["sent"], tally["refused"], tally["held"], tally["unmeasured"])


@dataclass(frozen=True)
class Decision:
    verdict: str        # RUNNING, CONTINUE or STOP
    reason: str
    reading: Reading
    may_offer: int      # how many more customers may be offered to the gate now


def decide(reading: Reading, *, remaining: int) -> Decision:
    """Continue past the canary only on a measured rate under the bar over a complete canary. `remaining` is how
    many digests have not been offered yet."""
    if remaining < 0:
        raise DigestError("remaining cannot be negative")
    if reading.refused > MAX_REFUSED:
        return Decision(STOP, "refusals_past_the_bar", reading, 0)
    if reading.measured >= CANARY_USERS:
        # refused <= MAX_REFUSED over at least CANARY_USERS measured is under the bar by construction; the rate is
        # compared anyway so a change to either constant cannot open the gate by arithmetic alone
        rate = reading.rate
        if rate is not None and rate < REFUSAL_BAR:
            return Decision(CONTINUE, "canary_complete_under_the_bar", reading, remaining)
        return Decision(STOP, "canary_complete_at_or_over_the_bar", reading, 0)
    if remaining == 0:
        # the population ran out before the canary filled: a short canary authorises nothing by itself
        return Decision(STOP, "canary_short", reading, 0)
    return Decision(RUNNING, "canary_not_complete", reading, min(remaining, CANARY_USERS - reading.measured))


def next_page(digests: list[Digest], outcomes: dict[str, str], size: int) -> list[Digest]:
    """The next customers to offer, in the audience's own order (paid first), never past what `decide` allows and
    never a customer who already has a sent or refused outcome. A held or unmeasured customer is offered again."""
    if size < 0:
        raise DigestError("page size cannot be negative")
    settled = {uid for uid, o in outcomes.items() if o in ("sent", "refused")}
    waiting = [d for d in digests if d.user_id not in settled]
    allowed = decide(read_canary(outcomes), remaining=len(waiting)).may_offer
    return waiting[:min(size, allowed)]
