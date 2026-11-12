#!/usr/bin/env python3
"""When the monitor pages. Pure: readings and thresholds in, findings out.

A metric that cannot page is a report. Every finding here has a key, a number and one sentence,
and `due` decides whether it goes out now: a new finding pages at once, an unchanged one is
repeated only after `repage_hours`, and one that got materially worse pages again immediately.

Two rules run through all of it:
  * UNMEASURED IS NOT ZERO. A week the reader could not cover produces an `unmeasured` finding
    and no comparison; it never reads as "nothing rose".
  * The raw assignment rate and the human reply rate have no wrong direction of their own (one
    sibling task raises assignment, another lowers it), so neither pages bare. They page through
    what they mean for a customer: a hand-off with nobody assigned, and a hand-off that WAS
    assigned and that nobody answered.
"""
from collections import namedtuple

from . import fixloop, metrics, rules

Finding = namedtuple("Finding", "key severity value text")

PAGE = "page"
INFO = "info"
# Where a page goes when the register itself cannot be read (#clio_devops, the captain).
FALLBACK_TARGET = {"slack": {"channel": "C0ADV2W76G4", "mention_ids": ["U7RP6HKUZ"]}}

DEFAULT_PAGE = {
    "headline_rise_pct": 10, "headline_rise_min": 25,
    "headline_ceiling_per_week": None,
    "handoff_rate_rise_pp": 5,
    "resolved_rate_fall_pp": 5,
    "never_answered_rise_pct": 50, "never_answered_rise_min": 10,
    "assigned_no_reply_rise_pct": 25, "assigned_no_reply_rise_min": 25,
    "date_promise_max_per_week": 0,
    "shape_rise_pct": 30, "shape_rise_min": 15,
    "residual_share_max": 0.25,
    "min_threads_week": 100,
    "overdue_rise_pct_day": 5, "overdue_rise_min_day": 25,
    "waiting_rise_pct_day": 10, "waiting_rise_min_day": 25,
    "repage_hours": 72, "escalate_pct": 10,
}


def thresholds(register):
    out = dict(DEFAULT_PAGE)
    out.update(((register.get("monitor") or {}).get("page")) or {})
    return out


def _pct(part, whole):
    return f"{100.0 * part / whole:.0f}%" if whole else "n/a"


def _rose(now, before, pct, minimum):
    return now - before >= minimum and now >= before * (1 + pct / 100.0)


def evaluate(weeks, register, verdicts=(), covered=True):
    """Findings for the newest matured week against the one before it.

    `weeks` is `metrics.matured_weeks(...)`, newest first. `covered` is False when the thread
    facts do not reach back over both weeks; then nothing is compared.
    """
    t = thresholds(register)
    findings = []
    cur = weeks[0]
    prev = weeks[1] if len(weeks) > 1 else None
    if cur["threads"] < t["min_threads_week"]:
        findings.append(Finding(
            "unmeasured:low_volume", PAGE, cur["threads"],
            f"only {cur['threads']} threads in the last matured week (floor {t['min_threads_week']}): "
            "either support went quiet or the reader lost its window. Nothing was compared."))
        return findings
    head = cur["headline"]
    ceiling = t.get("headline_ceiling_per_week")
    if ceiling is not None and head > ceiling:
        findings.append(Finding(
            "headline:ceiling", PAGE, head,
            f"hand-offs with nobody assigned: {head} in the last matured week, over the ceiling of "
            f"{ceiling} ({_pct(head, cur['threads'])} of {cur['threads']} threads)."))
    if cur["extra"]["date_promise"] > t["date_promise_max_per_week"]:
        findings.append(Finding(
            "exemption:date_promise", PAGE, cur["extra"]["date_promise"],
            f"Caroline promised a date or a day count in {cur['extra']['date_promise']} threads last week "
            f"(allowed {t['date_promise_max_per_week']}). She must never promise a date."))
    share = fixloop.residual_share(cur)
    if share is not None and share > t["residual_share_max"]:
        findings.append(Finding(
            "shapes:residual", PAGE, round(share, 4),
            f"{share:.0%} of last week's threads fit no named shape (limit {t['residual_share_max']:.0%}): "
            "a shape is missing from the classifier. Read the residual and add it."))
    if prev is None or not covered or prev["threads"] < t["min_threads_week"]:
        findings.append(Finding(
            "unmeasured:no_previous_week", INFO, 0,
            "no comparable previous week on hand, so week-over-week rules did not run."))
    else:
        findings.extend(_compare(cur, prev, t))
    for verdict in verdicts:
        name = fixloop.verdict_name(verdict)
        if verdict["verdict"] == "did_not_work":
            findings.append(Finding(
                f"fix:did_not_work:{name}", PAGE, verdict.get("relative_drop", 0),
                f"the fix for `{name}` shipped {verdict['shipped_at']} did not move its own number: "
                f"{verdict['metric']} {verdict['before']['count']}/{verdict['before']['threads']} before, "
                f"{verdict['after']['count']}/{verdict['after']['threads']} after. It did not work."))
        elif verdict["verdict"] == "worked" and verdict.get("status") == "shipped":
            findings.append(Finding(
                f"fix:worked:{name}", INFO, verdict.get("relative_drop", 0),
                f"the fix for `{name}` moved its number ({verdict['before']['rate']:.0%} to "
                f"{verdict['after']['rate']:.0%}); mark the row verified."))
    return findings


def _compare(cur, prev, t):
    out = []
    head, head_prev = cur["headline"], prev["headline"]
    if _rose(head, head_prev, t["headline_rise_pct"], t["headline_rise_min"]):
        rate, rate_prev = cur["rates"]["handoff_no_assignment_rate"], prev["rates"]["handoff_no_assignment_rate"]
        cause = ("the RATE rose too, so this is behaviour, not volume" if rate - rate_prev >= 0.02
                 else "the rate is flat, so this is volume: more threads, same behaviour")
        out.append(Finding(
            "headline:rise", PAGE, head,
            f"hand-offs with nobody assigned ROSE: {head} last matured week, was {head_prev} "
            f"({rate:.0%} of {cur['threads']} threads, was {rate_prev:.0%} of {prev['threads']}); {cause}."))
    hr, hr_prev = cur["rates"]["handoff_rate"], prev["rates"]["handoff_rate"]
    if (hr - hr_prev) * 100 >= t["handoff_rate_rise_pp"]:
        out.append(Finding(
            "handoff_rate:rise", PAGE, round(hr, 4),
            f"hand-off rate rose to {hr:.0%} of threads, was {hr_prev:.0%}."))
    rr, rr_prev = cur["rates"]["resolved_without_handoff_rate"], prev["rates"]["resolved_without_handoff_rate"]
    if (rr_prev - rr) * 100 >= t["resolved_rate_fall_pp"]:
        out.append(Finding(
            "resolved:fall", PAGE, round(1 - rr, 4),
            f"resolved without a hand-off FELL to {rr:.0%} of threads "
            f"({cur['outcomes']['answered']}), was {rr_prev:.0%} ({prev['outcomes']['answered']})."))
    na, na_prev = cur["extra"]["never_answered_over_n_hours"], prev["extra"]["never_answered_over_n_hours"]
    if _rose(na, na_prev, t["never_answered_rise_pct"], t["never_answered_rise_min"]):
        out.append(Finding(
            "never_answered:rise", PAGE, na,
            f"threads with no reply at all after {cur['window']['unanswered_hours']}h: {na}, was {na_prev}."))
    an, an_prev = cur["extra"]["handoff_assigned_no_human_reply"], prev["extra"]["handoff_assigned_no_human_reply"]
    if _rose(an, an_prev, t["assigned_no_reply_rise_pct"], t["assigned_no_reply_rise_min"]):
        out.append(Finding(
            "assigned_no_reply:rise", PAGE, an,
            f"handed off AND assigned to a person, with no human reply inside "
            f"{cur['window']['maturity_hours']}h: {an}, was {an_prev}. The assignment is real; the answer is not."))
    for sid in rules.SHAPE_IDS:
        now_n = (cur["shapes"].get(sid) or {}).get(metrics.HEADLINE, 0)
        prev_n = (prev["shapes"].get(sid) or {}).get(metrics.HEADLINE, 0)
        if _rose(now_n, prev_n, t["shape_rise_pct"], t["shape_rise_min"]):
            threads = (cur["shapes"].get(sid) or {}).get("threads", 0)
            prev_threads = (prev["shapes"].get(sid) or {}).get("threads", 0)
            out.append(Finding(
                f"shape:rise:{sid}", PAGE, now_n,
                f"shape `{sid}`: {now_n} of {threads} threads handed off with nobody assigned, "
                f"was {prev_n} of {prev_threads}."))
    return out


def evaluate_inbox(doc, before, t):
    """Findings from the support instrument (backlog.py) against the reading of about a day ago.

    Two things are watched here because neither shows in the weekly cohort: promises going overdue
    with nothing sent, and conversations left waiting on us. A reading that did not cover the
    whole inbox is not compared at all, and a first reading has nothing to be compared with.
    """
    if not (doc.get("scope") or {}).get("whole_inbox"):
        return []
    if before is None:
        return [Finding("unmeasured:inbox_day_before", INFO, 0,
                        "no inbox reading from about a day ago to compare with yet.")]
    out = []
    od, od_prev = doc["commitments_overdue"], before.get("commitments_overdue")
    kept, broken = doc["promises_kept_24h"], doc["promises_broken_24h"]
    if od_prev is not None and broken > kept and _rose(od, od_prev, t["overdue_rise_pct_day"], t["overdue_rise_min_day"]):
        out.append(Finding(
            "promises:overdue_rise", PAGE, od,
            f"promises overdue with nothing sent on the thread: {od:,}, was {od_prev:,} a day ago. "
            f"Last 24h: {kept} kept, {broken} broken."))
    w, w_prev = doc["waiting_on_us"], before.get("waiting_on_us")
    if w_prev is not None and _rose(w, w_prev, t["waiting_rise_pct_day"], t["waiting_rise_min_day"]):
        out.append(Finding(
            "inbox:waiting_rise", PAGE, w,
            f"conversations waiting on us for over {doc['waiting_on_us_hours']}h: {w:,}, was {w_prev:,} a day ago "
            f"(oldest {doc['oldest_waiting_on_us_h']}h)."))
    return out


def due(findings, last_page, now, t):
    """The findings to send now. `last_page(key)` returns {'value', 'paged_at'} or None.

    New: send. Unchanged: send again only after `repage_hours`. Worse by `escalate_pct`: send.
    """
    out = []
    for f in findings:
        if f.severity != PAGE:
            continue
        last = last_page(f.key)
        if last is None or now - last["paged_at"] >= t["repage_hours"] * 3600:
            out.append(f)
            continue
        base = last["value"] or 0
        if base and f.value >= base * (1 + t["escalate_pct"] / 100.0):
            out.append(f)
    return out


def render_page(findings, weeks, mention_ids=(), drill=False):
    """One Slack message. The headline number is always the first line."""
    cur = weeks[0]
    prev = weeks[1] if len(weeks) > 1 else None
    mentions = " ".join(f"<@{m}>" for m in mention_ids if m)
    was = f", {prev['headline']} the week before" if prev else ""
    lines = [
        (":test_tube: *DRILL (nothing is wrong)* " if drill else ":rotating_light: ")
        + f"*Caroline monitor* {mentions}".rstrip(),
        f"*Hand-offs with nobody assigned: {cur['headline']} last matured week*{was} "
        f"({_pct(cur['headline'], cur['threads'])} of {cur['threads']} threads).",
    ]
    lines.extend(f"• {f.text}" for f in findings)
    lines.append("_Runbook: docs/support/caroline-monitor.md. Shapes: `caroline-monitor.py shapes`._")
    return "\n".join(lines)


def render_weekly(weeks, baseline_week=None):
    """The one line to watch. Posted once a week whether or not anything pages."""
    cur = weeks[0]
    prev = weeks[1] if len(weeks) > 1 else None
    bits = [f":bar_chart: *Caroline, hand-offs with nobody assigned: {cur['headline']} last week*"]
    if prev:
        bits.append(f"(week before {prev['headline']}")
        bits[-1] += f", baseline {baseline_week})" if baseline_week is not None else ")"
    elif baseline_week is not None:
        bits.append(f"(baseline {baseline_week})")
    bits.append(
        f"That is {_pct(cur['headline'], cur['threads'])} of {cur['threads']} threads. "
        f"Resolved without a hand-off: {cur['outcomes']['answered']} "
        f"({_pct(cur['outcomes']['answered'], cur['threads'])}).")
    return " ".join(bits)


def _n(value):
    return "not measured" if value is None else f"{value:,}"


def render_health(when, how, reading, inbox, open_findings, paged, page_failed=False):
    """One line per run, pages or not: proof the monitor ran, what it read, and where the
    numbers stand. It carries no mention; a regression is the page's job."""
    bits = [f":stopwatch: *Caroline monitor* {when}"]
    if how.get("listed") is not None:
        bits.append(f"read {how['listed']:,} conversations ({how.get('fetched', 0):,} re-read, "
                    f"{how.get('errors', 0)} errors)")
    if reading["weeks_covered"][0]:
        cur = reading["weeks"][0]
        was = f" (was {reading['weeks'][1]['headline']:,})" if reading["weeks_covered"][1] else ""
        bits.append(f"hand-offs with nobody assigned {cur['headline']:,} of {cur['threads']:,} last matured week{was}")
    else:
        bits.append("hand-offs with nobody assigned: last matured week not measured")
    if (inbox.get("scope") or {}).get("whole_inbox"):
        bands = inbox.get("waiting_on_us_by_wait") or {}
        recent = bands.get("under_2d", 0) + bands.get("2d_to_7d", 0)
        bits.append(f"last 24h: {_n(inbox['promised_a_person_24h'])} told a person is coming, "
                    f"{_n(inbox['handed_to_human_24h'])} assigned to a person, "
                    f"{_n(inbox['human_replied_24h'])} answered by a person")
        bits.append(f"waiting on us over {inbox['waiting_on_us_hours']}h {_n(inbox['waiting_on_us'])} "
                    f"({recent:,} under 7d)")
        bits.append(f"promises {_n(inbox['commitments_open'])} open, {_n(inbox['commitments_overdue'])} overdue, "
                    f"{_n(inbox['promises_kept_24h'])} kept and {_n(inbox['promises_broken_24h'])} broken in 24h")
    else:
        bits.append("inbox not measured")
    if not open_findings:
        bits.append("nothing paging")
    elif page_failed:
        bits.append(f"{open_findings} regression(s) open, PAGE NOT DELIVERED")
    elif paged:
        bits.append(f"{open_findings} regression(s) open, {paged} paged just now")
    else:
        bits.append(f"{open_findings} regression(s) open, already paged")
    return " · ".join(bits)


def render_health_blind(when, reason, consecutive):
    """The health line of a run that could not measure. It never repeats an old number."""
    return (f":stopwatch: *Caroline monitor* {when} · NOT MEASURED ({consecutive} run(s) in a row): {reason} · "
            "no number is current")

