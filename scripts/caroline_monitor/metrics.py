#!/usr/bin/env python3
"""Named metrics over thread facts. Pure: facts in, numbers out, no network and no clock.

A thread is read at a CUT-OFF. Two cut-offs are used and they answer different questions:

  * as of now       — "what is the state of the last 30 days today". Reconciles with the
                      caroline-intent-mining-m1 report, which read every thread once.
  * matured (48 h)  — "what had happened 48 hours after each thread opened". This is the series
                      the monitor pages on. Without it the newest week is always read younger
                      than the week it is compared with (fewer assignments, fewer human replies,
                      fewer chases), and the comparison moves for no reason.

Every thread lands in exactly ONE outcome class, so the classes sum to the cohort and nothing can
be counted twice or dropped. The headline is one class: `handoff_no_assignment`.
"""
from . import rules

DAY = 86400
HOUR = 3600

# Mutually exclusive, in precedence order. See `outcome_class`.
OUTCOME_CLASSES = (
    "handoff_no_assignment",   # Caroline said a person is coming; no human was assigned. THE failure.
    "handoff_assigned",        # she said it and a human was assigned
    "assigned_silent",         # a human was assigned, the customer was not told
    "queue_line",              # parked on "it is with the team", no person, no assignment
    "never_answered",          # the customer wrote and nothing came back at all
    "refused",                 # refused with a reason and a way back (the exemptions' proper shape)
    "answered",                # answered, none of the above, nothing left waiting: resolved without a hand-off
    "answered_awaiting",       # answered, none of the above, but the customer's last message has no reply
    "no_customer_message",     # we opened it and the customer has not written
)
HEADLINE = "handoff_no_assignment"


def state_at(events, cut):
    """Flags for one thread as of `cut` (events after it have not happened yet)."""
    seen = set()
    first_customer = promise_at = None
    last_conversational = None
    chased = False
    human_reply_after_promise = False
    for ts, code in events:
        if ts > cut:
            break
        seen.add(code)
        if code == rules.EV_CUSTOMER:
            if first_customer is None:
                first_customer = ts
            last_conversational = code
            if (promise_at is not None and not human_reply_after_promise
                    and ts - promise_at >= DAY):
                chased = True
        elif code in (rules.EV_CAROLINE, rules.EV_HUMAN_REPLY):
            last_conversational = code
            if code == rules.EV_HUMAN_REPLY and promise_at is not None:
                human_reply_after_promise = True
        elif code == rules.EV_PROMISE and promise_at is None:
            promise_at = ts
    return {
        "customer": rules.EV_CUSTOMER in seen,
        "caroline": rules.EV_CAROLINE in seen,
        "human_reply": rules.EV_HUMAN_REPLY in seen,
        "promise": rules.EV_PROMISE in seen,
        "queue": rules.EV_QUEUE in seen,
        "date_promise": rules.EV_DATE in seen,
        "refusal": rules.EV_REFUSAL in seen,
        "assigned": rules.EV_HUMAN_ASSIGNED in seen,
        "guard": rules.EV_GUARD in seen,
        "awaiting": last_conversational == rules.EV_CUSTOMER,
        "first_customer_at": first_customer,
        "chased": chased,
    }


def outcome_class(state):
    if not state["customer"]:
        return "no_customer_message"
    if state["promise"]:
        return "handoff_assigned" if state["assigned"] else "handoff_no_assignment"
    if state["assigned"]:
        return "assigned_silent"
    if state["queue"]:
        return "queue_line"
    if not (state["caroline"] or state["human_reply"]):
        return "never_answered"
    if state["refusal"]:
        return "refused"
    return "answered_awaiting" if state["awaiting"] else "answered"


def _blank_shape():
    row = {"threads": 0}
    row.update({name: 0 for name in OUTCOME_CLASSES})
    row["date_promise"] = 0
    row["guard_blocked"] = 0
    return row


def _rate(numerator, denominator):
    return round(numerator / denominator, 4) if denominator else None


def measure(facts, start, end, now, maturity_hours=None, unanswered_hours=24):
    """Metrics for the cohort of threads CREATED in [start, end), each read at its cut-off.

    `maturity_hours=None` reads every thread as of `now`. With a maturity, a thread is read at
    `created_at + maturity` (never later than `now`), and the caller is expected to pass a
    window whose end is at least that old, so every thread in it is fully matured.
    """
    counts = {name: 0 for name in OUTCOME_CLASSES}
    extra = {"assigned": 0, "human_reply": 0, "caroline_replied": 0, "date_promise": 0,
             "told_person_or_assigned_broad": 0, "handoff_no_assignment_broad": 0,
             "handoff_assigned_no_human_reply": 0, "never_answered_over_n_hours": 0,
             "chased_after_promise": 0, "outbound_started": 0,
             "guard_blocked": 0, "headline_guard_forced": 0, "guard_assigned": 0}
    shapes = {}
    threads = 0
    for fact in facts:
        created = fact["created_at"]
        if not (start <= created < end):
            continue
        cut = now if maturity_hours is None else min(now, created + maturity_hours * HOUR)
        state = state_at(fact["events"], cut)
        klass = outcome_class(state)
        threads += 1
        counts[klass] += 1
        shape = shapes.setdefault(fact["shape"], _blank_shape())
        shape["threads"] += 1
        shape[klass] += 1
        extra["assigned"] += state["assigned"]
        extra["human_reply"] += state["human_reply"]
        extra["caroline_replied"] += state["caroline"]
        extra["date_promise"] += state["date_promise"]
        shape["date_promise"] += state["date_promise"]
        extra["outbound_started"] += bool(fact.get("outbound"))
        broad = state["promise"] or state["queue"]
        extra["told_person_or_assigned_broad"] += bool(broad or state["assigned"])
        extra["handoff_no_assignment_broad"] += bool(broad and not state["assigned"])
        extra["handoff_assigned_no_human_reply"] += bool(
            state["promise"] and state["assigned"] and not state["human_reply"])
        extra["chased_after_promise"] += state["chased"]
        extra["guard_blocked"] += state["guard"]
        extra["headline_guard_forced"] += bool(state["guard"] and klass == HEADLINE)
        extra["guard_assigned"] += bool(state["guard"] and state["assigned"])
        shape["guard_blocked"] += state["guard"]
        if (klass == "never_answered" and fact["shape"] != "robot_mail"
                and state["first_customer_at"] is not None
                and cut - state["first_customer_at"] >= unanswered_hours * HOUR):
            extra["never_answered_over_n_hours"] += 1
    handoff = counts["handoff_no_assignment"] + counts["handoff_assigned"]
    days = (end - start) / DAY
    return {
        "window": {"start": start, "end": end, "days": round(days, 2), "as_of": now,
                   "maturity_hours": maturity_hours, "unanswered_hours": unanswered_hours},
        "threads": threads,
        "outcomes": counts,
        "headline": counts[HEADLINE],
        "headline_per_week": round(counts[HEADLINE] * 7 / days, 1) if days else None,
        "handoff": handoff,
        "extra": extra,
        "rates": {
            "handoff_rate": _rate(handoff, threads),
            "handoff_no_assignment_rate": _rate(counts[HEADLINE], threads),
            "assignment_rate": _rate(extra["assigned"], threads),
            "human_reply_rate": _rate(extra["human_reply"], threads),
            "resolved_without_handoff_rate": _rate(counts["answered"], threads),
            "never_answered_rate": _rate(counts["never_answered"], threads),
        },
        "shapes": {k: shapes[k] for k in sorted(shapes)},
    }


def matured_weeks(facts, now, maturity_hours=48, weeks=2, unanswered_hours=24):
    """The last `weeks` full, matured 7-day cohorts, newest first.

    Week 0 is threads created in [now - maturity - 7d, now - maturity): the newest seven days
    in which every thread has had its full maturity.
    """
    edge = now - maturity_hours * HOUR
    out = []
    for k in range(weeks):
        end = edge - k * 7 * DAY
        out.append(measure(facts, end - 7 * DAY, end, now, maturity_hours, unanswered_hours))
    return out


def coverage(facts, start, end):
    """Oldest and newest created_at we hold inside a window, and how many: the reader's reach."""
    stamps = [f["created_at"] for f in facts if start <= f["created_at"] < end]
    return {"threads": len(stamps), "oldest": min(stamps) if stamps else None,
            "newest": max(stamps) if stamps else None}
