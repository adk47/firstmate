"""Who may NOT be messaged, and who we can reach - decided in code, fail-closed.

R5's exclusion list, in the order it is applied. Every entry either reads its own source and
HOLDS the user when that source is unreadable, or delegates explicitly to the send gateway and
records the delegation (duplicating a gate we cannot read would only make the two disagree):

    1 holdout                sha256 hash bucket: never messaged, so returns stay measurable
    2 campaign_once          this lane's own ledger: one message per user, ever (R5)
    3 open_dispute           any dispute on file (we cannot see open vs closed from here:
                             a dispute is a stop, and the alternative is guessing)
    4 staff_or_test          @muso.ai, example.com, test/qa/demo local parts
    5 fraud_watchlist        policies/fraud-watchlist.json (credit_review.watchlist)
    6 affiliation            /var/lib/credit-trust/org-affiliation.json, full coverage, held
                             on any doubt: a major label/publisher gets a NAMED human, never
                             an automated note
    7 paying_again           core subscriptions, by user OR by their default team
    8 no_verified_email      no address, or emailconfirmed = false
    9 -                      prefs suppression / marketing-in-7d / one-per-UTC-day: the send
                             gateway owns these and the sender seat's own gate enforces them
                             (delegated in policies/winback-fix.json, not re-implemented here)

The last three rows are the ones that burn reputation, so each returns a REASON that lands in
the ticket's event log: "why was this user not messaged" is always answerable afterwards.
"""

from __future__ import annotations

import csv
import io
import re
from dataclasses import dataclass, field
from typing import Any, Callable, Iterable, Mapping, Sequence

from . import model

#: Never a real customer: staff domain, documentation domain, or a test/qa local part.
STAFF_DOMAINS = ("muso.ai", "example.com", "example.org", "localhost")
TEST_LOCALPART = re.compile(r"^(?:test|tests|qa|demo|dummy|sample|musotest|e2e)\d*(?:[._+-]|$)", re.I)

#: Core states that mean "they are a paying customer right now" - nothing to win back.
LIVE_SUB_STATUSES = ("active", "trialing", "past_due")


@dataclass(frozen=True)
class Recipient:
    user_id: str
    email: str
    first_name: str
    email_confirmed: bool
    is_admin: bool = False
    #: ``None`` means the core read returned a cell we could not parse. That is NOT zero: a
    #: paying user with a malformed count must be held, never messaged as "not paying".
    live_subs: int | None = 0


@dataclass
class Decision:
    """One user's audience verdict. ``send`` False means: hold, with the reason on record."""

    user_id: str
    send: bool
    reason: str
    recipient: Recipient | None = None
    holdout: bool = False


@dataclass
class Batch:
    send: list[Decision] = field(default_factory=list)
    hold: list[Decision] = field(default_factory=list)
    holdout: list[Decision] = field(default_factory=list)

    def reasons(self) -> dict[str, int]:
        counts: dict[str, int] = {}
        for d in self.hold:
            counts[d.reason] = counts.get(d.reason, 0) + 1
        return dict(sorted(counts.items(), key=lambda kv: (-kv[1], kv[0])))


def is_staff_or_test(email: str, *, is_admin: bool = False) -> bool:
    addr = (email or "").strip().lower()
    if is_admin:
        return True
    if "@" not in addr:
        return True
    local, _, domain = addr.partition("@")
    if any(domain == d or domain.endswith("." + d) for d in STAFF_DOMAINS):
        return True
    return bool(TEST_LOCALPART.match(local))


# ── core reads (one statement, SELECT order IS the contract) ────────────────
PEOPLE_SQL = (
    "SELECT u.id, coalesce(u.email, ''), coalesce(u.firstname, ''), "
    "coalesce(u.isadmin, false), coalesce(u.emailconfirmed, false), "
    "count_if(s.status IN ('active','trialing','past_due')) AS live_subs "
    "FROM postgresql_core.public.users u "
    "LEFT JOIN postgresql_core.public.subscriptions s "
    "  ON s.userid = u.id OR s.teamid = u.defaultteamid "
    "WHERE u.id IN ({ids}) GROUP BY 1, 2, 3, 4, 5"
)


def _chunks(ids: Sequence[str], size: int) -> Iterable[Sequence[str]]:
    for i in range(0, len(ids), size):
        yield ids[i:i + size]


def _truthy(raw: Any) -> bool:
    return str(raw or "").strip().lower() in ("true", "t", "1", "yes")


def resolve_people(user_ids: Sequence[str], *, run_sql: Callable[[str], list[list[str]]]) -> dict[str, Recipient]:
    """{user id: Recipient} from core: email, first name, admin flag, live subscription count.

    One statement per 500 ids. A query failure is fatal for the whole batch: a chunk we could
    not read looks exactly like "not paying, no email" if we let it pass, which would message
    people who are already paying.
    """
    ids = [str(u).strip() for u in user_ids if str(u).strip().isdigit()]
    out: dict[str, Recipient] = {}
    for chunk in _chunks(ids, 500):
        rows = run_sql(PEOPLE_SQL.format(ids=",".join(chunk)))
        for row in rows:
            if not row or len(row) < 6:
                continue
            try:
                live = int(float(row[5] or 0))
            except (TypeError, ValueError):
                live = None
            out[str(row[0]).strip()] = Recipient(
                user_id=str(row[0]).strip(),
                email=str(row[1] or "").strip(),
                first_name=str(row[2] or "").strip(),
                email_confirmed=_truthy(row[4]),
                is_admin=_truthy(row[3]),
                live_subs=live,
            )
    return out


def parse_csv(stdout: str) -> list[list[str]]:
    return [row for row in csv.reader(io.StringIO(stdout)) if row]


# ── exclusion sources ───────────────────────────────────────────────────────
def watchlist_hits(user_ids: Sequence[str], *, watchlist: Any) -> set[str]:
    """Ids named by policies/fraud-watchlist.json (both tiers: watchlisted = no marketing)."""
    if watchlist is None:
        return set()
    named = set()
    for raw in user_ids:
        try:
            uid = int(str(raw).strip())
        except ValueError:
            continue
        if uid in watchlist.user_ids:
            named.add(str(uid))
    return named


def affiliation_holds(user_ids: Sequence[str], verdicts: Mapping[str, Mapping[str, Any]]) -> dict[str, str]:
    """{user id: reason} for everyone a full-coverage affiliation check does not clear.

    Delegates to ``credit_review.affiliation.hold_reason`` - the ONE consumer rule every
    automatic user-facing step already reads (RULE-org-affiliation) - rather than restating it
    here, because two copies of a safety rule drift and the drift is invisible until it sends.
    """
    from credit_review import affiliation  # noqa: PLC0415 - scripts/ is on sys.path at runtime

    holds: dict[str, str] = {}
    for raw in user_ids:
        uid = str(raw).strip()
        reason = affiliation.hold_reason(dict(verdicts), uid, affiliation.ACTION_NOTE)
        if reason:
            holds[uid] = reason
    return holds


# ── selection ───────────────────────────────────────────────────────────────
def select(tickets: Sequence[Any], *, policy: Mapping[str, Any], people: Mapping[str, Recipient],
           watchlist: Any = None, verdicts: Mapping[str, Mapping[str, Any]] | None = None,
           already_messaged: Callable[[str], bool] | None = None,
           cap: int | None = None) -> Batch:
    """Apply the exclusion list to Seen tickets and return the batch in send order."""
    win = policy.get("windows") or {}
    hold_cfg = policy.get("holdout") or {}
    modulus = int(hold_cfg.get("modulus") or 10)
    residue = int(hold_cfg.get("residue") or 0)
    batch = Batch()
    seen_ids = [str(t.user_id) for t in tickets]
    watched = watchlist_hits(seen_ids, watchlist=watchlist) if watchlist is not None else set()
    aff = affiliation_holds(seen_ids, verdicts or {}) if verdicts is not None else {}
    limit = int(cap if cap is not None else (policy.get("caps") or {}).get("per_run") or 0)

    one_each: list[Any] = []
    claimed: set[str] = set()
    for ticket in tickets:
        uid = str(ticket.user_id)
        if uid in claimed:
            continue
        claimed.add(uid)
        one_each.append(ticket)

    for ticket in one_each:
        uid = str(ticket.user_id)
        if model.holdout(uid, modulus, residue):
            batch.holdout.append(Decision(uid, False, "holdout", holdout=True))
            continue
        if already_messaged and already_messaged(uid):
            batch.hold.append(Decision(uid, False, "campaign_once"))
            continue
        cand = dict(getattr(ticket, "candidate", None) or {})
        if int(cand.get("disputes") or 0) > 0:
            batch.hold.append(Decision(uid, False, "open_dispute"))
            continue
        person = people.get(uid)
        if person is None:
            batch.hold.append(Decision(uid, False, "unreadable: core read returned no row for this user"))
            continue
        if uid in watched:
            batch.hold.append(Decision(uid, False, "fraud_watchlist", person))
            continue
        if uid in aff:
            batch.hold.append(Decision(uid, False, aff[uid], person))
            continue
        if is_staff_or_test(person.email, is_admin=person.is_admin):
            batch.hold.append(Decision(uid, False, "staff_or_test", person))
            continue
        if person.live_subs is None:
            batch.hold.append(Decision(uid, False, "unreadable: live subscription count", person))
            continue
        if person.live_subs > 0:
            batch.hold.append(Decision(uid, False, "paying_again", person))
            continue
        if not person.email or "@" not in person.email:
            batch.hold.append(Decision(uid, False, "no_email", person))
            continue
        if not person.email_confirmed:
            batch.hold.append(Decision(uid, False, "email_not_confirmed", person))
            continue
        if limit and len(batch.send) >= limit:
            batch.hold.append(Decision(uid, False, "cap_per_run", person))
            continue
        batch.send.append(Decision(uid, True, "send", person))
    return batch
