"""Did any of it work? Returns measured against the untouched holdout.

The campaign's only honest claim is a comparison: of the churned users this campaign touched
(whose fix we fixed, or whose fix we could not prove), how many came back - versus the same
population we deliberately never messaged
(``holdout.modulus/residue``). Both groups are drawn from the SAME routed population and are
measured the same way, with one statement on core subscriptions.

    returned  := a subscription in an active-ish state created inside THAT user's own window
                 (``status IN ('active','trialing')`` AND ``anchor <= createdat < anchor + 30d``)
                 where anchor = fixed_at if the read-back proved the fix, else routed_at: the
                 moment the campaign touched that user, so an unfixed control user can register
                 a return too.

No model, no projection, no "influenced revenue". The output is a JSON artifact per run plus a
one-line text rendering, because the weekly churn line (churn-risk-signal-prevent-p1) reads
files rather than being told numbers by an agent.

This lane does not post to Slack itself: the weekly line already owns that surface, and two
posters for one number is how a number ends up printed twice and believed once.
"""

from __future__ import annotations

import calendar
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Callable, Collection, Mapping

from . import cli, model, tickets as tickets_mod

RETURN_SQL = (
    "SELECT DISTINCT s.userid, s.createdat FROM postgresql_core.public.subscriptions s "
    "WHERE s.status IN ('active','trialing') AND s.createdat >= TIMESTAMP '{since}' "
    "AND s.createdat < TIMESTAMP '{until}' "
    "AND s.userid IN ({ids})"
)


def _iso(epoch: float) -> str:
    return time.strftime("%Y-%m-%d %H:%M:%S", time.gmtime(float(epoch or 0.0)))


def _epoch(raw: Any) -> float | None:
    """A Trino timestamp cell as an epoch, or None when it cannot be read as one."""
    text = str(raw or "").strip().replace("T", " ").rstrip("Z")[:19]
    for fmt in ("%Y-%m-%d %H:%M:%S", "%Y-%m-%d %H:%M", "%Y-%m-%d"):
        try:
            return float(calendar.timegm(time.strptime(text, fmt)))
        except ValueError:
            continue
    return None


@dataclass
class Cohort:
    """The two groups the comparison needs, both from the routed population."""

    holdout: dict[str, float] = field(default_factory=dict)  # user id -> anchor (never messaged)
    #: Every routed user who is NOT holdout, whose fix read back or not: the intent-to-treat arm.
    #: A per-protocol "messaged" arm cannot be measured honestly (the sender seat's outcome never
    #: reaches this ledger), so the arm that cannot be selected for is the only headline.
    intent: dict[str, float] = field(default_factory=dict)
    #: Holdout-only breakdowns. Named for the population they hold: a per-tier number scored
    #: against the holdout is NOT the campaign's per-tier rate, and the artifact must not read
    #: as if it were. Sets, because fix_tickets is keyed per (user, class): one user with two
    #: tickets must not be counted twice in a denominator.
    holdout_by_tier: dict[str, set[str]] = field(default_factory=dict)
    holdout_by_lane: dict[str, set[str]] = field(default_factory=dict)
    #: Users whose fix was proven by the read-back (``fixed_at``). The fixed/unfixed split is a
    #: secondary view of each arm, never the headline.
    fixed: set[str] = field(default_factory=set)
    #: Routed users with neither a fix epoch nor a routing epoch: no window exists in which any
    #: return could be attributed to this campaign, so they are counted here instead of being
    #: dropped from an arm without trace.
    unmeasurable: set[str] = field(default_factory=set)


def build_cohort(store: tickets_mod.TicketStore, *, policy: Mapping[str, Any]) -> Cohort:
    """Everyone this campaign touched (intent) and everyone it deliberately did not (holdout)."""
    modulus = int((policy.get("holdout") or {}).get("modulus") or 10)
    residue = int((policy.get("holdout") or {}).get("residue") or 0)
    cohort = Cohort()
    for ticket in store.db.execute(
            "SELECT user_id, tier, lane, fixed_at, routed_at FROM fix_tickets"):
        uid = str(ticket["user_id"])
        fixed_at = float(ticket["fixed_at"] or 0.0)
        # The anchor is the moment this campaign touched the user: the fix if the read-back
        # proved one, otherwise the routing. Anchoring only fixed users gave every unfixed
        # control a window that could never open, which diluted the holdout toward zero.
        anchor = fixed_at or float(ticket["routed_at"] or 0.0)
        if anchor <= 0.0:
            cohort.unmeasurable.add(uid)
            continue
        holdout = model.holdout(uid, modulus, residue)
        arm = cohort.holdout if holdout else cohort.intent
        # One user can hold two tickets (per primary class): the earliest touch is the moment
        # their window opens, so a later ticket cannot shrink a return they already registered.
        arm[uid] = min(arm.get(uid, anchor), anchor)
        if fixed_at > 0.0:
            cohort.fixed.add(uid)
        if holdout:
            cohort.holdout_by_tier.setdefault(str(ticket["tier"]), set()).add(uid)
            cohort.holdout_by_lane.setdefault(str(ticket["lane"]), set()).add(uid)
    return cohort


def returned_ids(anchors: Mapping[str, float], *, days: int,
                 run_sql: Callable[[str], list[list[str]]]) -> set[str]:
    """Ids with a fresh active subscription created inside their OWN ``[anchor, anchor+days)``.

    The window is per user, anchored on that user's own fix-or-send epoch: a campaign that runs
    daily for months fixes people at different times, and a single campaign-wide bound would drop
    the return of anyone fixed after its 30th day however real that return is. It is still closed
    at the top: without an upper bound every later subscription counts and the line creeps up
    forever. Users with no anchor are not in ``anchors`` at all: ``build_cohort`` puts them in
    its explicit ``unmeasurable`` bucket rather than silently dropping them from a denominator.

    One SQL statement per chunk: the chunk's WHERE clause spans the widest window in it, and each
    row is kept only when its ``createdat`` falls inside that user's own bound.
    """
    windows: dict[str, tuple[float, float]] = {}
    for user_id, anchor in anchors.items():
        uid = str(user_id).strip()
        start = float(anchor or 0.0)
        if uid.isdigit() and start > 0.0:
            windows[uid] = (start, start + days * 86400.0)
    if not windows:
        return set()
    lo = min(start for start, _ in windows.values())
    hi = max(end for _, end in windows.values())
    ids = list(windows)
    out: set[str] = set()
    for i in range(0, len(ids), 500):
        chunk = ids[i:i + 500]
        rows = run_sql(RETURN_SQL.format(since=_iso(lo), until=_iso(hi), ids=",".join(chunk)))
        for row in rows:
            if not row:
                continue
            uid = str(row[0]).strip()
            created = _epoch(row[1]) if len(row) > 1 else None
            window = windows.get(uid)
            if window and created is not None and window[0] <= created < window[1]:
                out.add(uid)
    return out


def _rate(num: int, den: int) -> dict[str, Any]:
    return {"returned": num, "n": den, "rate": round(num / den, 4) if den else None}


def report(store: tickets_mod.TicketStore, *, policy: Mapping[str, Any],
           run_sql: Callable[[str], list[list[str]]], now: float | None = None) -> dict[str, Any]:
    """The measurement artifact: intent-to-treat vs holdout, plus the HOLDOUT-only per-tier and
    per-lane breakdowns (labelled as such: they are not the campaign's own rates)."""
    now = now if now is not None else time.time()
    days = int((policy.get("windows") or {}).get("returns_days") or 30)
    cohort = build_cohort(store, policy=policy)
    anchors = [v for v in (cohort.holdout.values(), cohort.intent.values()) for v in v if v]
    since = min(anchors) if anchors else now
    until = max(anchors) + days * 86400.0 if anchors else now  # envelope; each arm is bounded per user
    hold_returned = (returned_ids(cohort.holdout, days=days, run_sql=run_sql)
                     if cohort.holdout else set())
    intent_returned = (returned_ids(cohort.intent, days=days, run_sql=run_sql)
                       if cohort.intent else set())

    def _bucket(ids: Collection[str], hits: set[str]) -> dict[str, Any]:
        return _rate(sum(1 for uid in ids if uid in hits), len(ids))

    def _fix_split(ids: Collection[str], hits: set[str]) -> dict[str, Any]:
        fixed = [uid for uid in ids if uid in cohort.fixed]
        unfixed = [uid for uid in ids if uid not in cohort.fixed]
        return {"fixed": _bucket(fixed, hits), "unfixed": _bucket(unfixed, hits)}

    tier_keys = sorted(cohort.holdout_by_tier)
    lanes = sorted(set(cohort.holdout_by_lane))
    return {
        "campaign": tickets_mod.CAMPAIGN,
        "measured_at": now,
        "returns_days": days,
        "since": since,
        "until": until,
        "holdout": _bucket(list(cohort.holdout), hold_returned),
        "intent_to_treat": _bucket(list(cohort.intent), intent_returned),
        "window_days": days,
        "window_rule": "per user: [that user's fix-or-routed epoch, + returns_days)",
        # Every denominator, spelled out: the arms above are rates, and a rate whose n is not
        # printed next to it is how a two-person holdout became a "win".
        "denominators": {
            "intent_to_treat": len(cohort.intent),
            "holdout": len(cohort.holdout),
            "unmeasurable": len(cohort.unmeasurable),
        },
        # SECONDARY split, never the headline: fixed users are the ones whose fix we proved, and
        # the rows of this table must always sum back to the arm's own denominator.
        "fixed_vs_unfixed": {
            "holdout": _fix_split(list(cohort.holdout), hold_returned),
            "intent_to_treat": _fix_split(list(cohort.intent), intent_returned),
        },
        "holdout_by_tier": {t: _bucket(cohort.holdout_by_tier.get(t, set()), hold_returned) for t in tier_keys},
        "holdout_by_lane": {lane: _bucket(cohort.holdout_by_lane.get(lane, set()), hold_returned) for lane in lanes},
        "note": (
            "Holdout is assigned by hash before any fix or send, so it is the only arm that cannot be "
            "selected for. The headline is 'intent_to_treat': every routed user who is not holdout, "
            "whose fix read back or not, against the holdout. A per-protocol 'messaged' arm is not "
            "reported: the sender seat can reject a hand-off after this lane releases it, and no "
            "confirmation of the real send reaches this ledger, so that arm would count claims as "
            "messages. Both arms are anchored on the moment the campaign touched each user (their "
            "fix if the read-back proved one, otherwise their routing), so an unfixed control user can "
            "register a return. The fixed/unfixed split beside each arm is secondary: it answers what "
            "happened to the users we could not prove, never how well the campaign did. A difference "
            "smaller than the group sizes support is noise, and this report never rounds it into a win."
        ),
    }


def text(report_doc: Mapping[str, Any]) -> str:
    """One line for the weekly churn line, honest about its own sample size."""
    hold = report_doc.get("holdout") or {}
    itt = report_doc.get("intent_to_treat") or {}
    return (
        f"wb_fix_1 returns over {report_doc.get('returns_days')}d: "
        f"intent-to-treat {itt.get('returned')}/{itt.get('n')} ({_pct(itt.get('rate'))}) vs "
        f"holdout {hold.get('returned')}/{hold.get('n')} ({_pct(hold.get('rate'))}); "
        f"unmeasurable {int((report_doc.get('denominators') or {}).get('unmeasurable') or 0)}"
    )


def _pct(rate: Any) -> str:
    return "n/a" if rate is None else f"{float(rate) * 100:.1f}%"


def write_report(report_doc: Mapping[str, Any], *, state_dir: str | Path, day: str | None = None) -> Path:
    out = Path(state_dir) / "returns" / f"{day or time.strftime('%Y-%m-%d', time.gmtime())}.json"
    return cli.write_private_json(out, report_doc)
