"""The support instrument: one small JSON file that says how the inbox stands right now.

Written by every good monitor tick to /var/lib/hydra/support-backlog.json (not /opt/hydra, which
the deploy rsync overwrites). Anything that wants to know whether support is getting better reads
this file and its age, instead of asking Slack or running its own count with its own rules.

It is counted on the WHOLE inbox, not on the monitor's weekly cohort: every open conversation of
any age, plus everything touched in the last day. The weekly cohort alone held 4,485 threads on
2026-11-11 while 9,080 conversations were open.

Three rules of the file:

* It is rewritten only by a tick that could read the inbox. A blind tick leaves the last good
  file in place, so `written_at` goes stale and the staleness is the signal.
* A number that could not be counted is `null`, never 0. A reading that did not cover the whole
  inbox (a corpus replay of the weekly cohort, for example) has `null` for every inbox-wide field.
* Counts only. No conversation id, no text.
"""
import json
import os
import tempfile
import time
from datetime import datetime, timezone

from . import commitments, rules, safety_records

HOUR = 3600
DAY = 86400
DEFAULT_PATH = os.environ.get("CAROLINE_MONITOR_BACKLOG_PATH", "/var/lib/hydra/support-backlog.json")
SCHEMA = "support-backlog.v1"
INBOX_FIELDS = ("open", "waiting_on_us", "waiting_on_us_robot_mail", "waiting_on_customer",
                "oldest_waiting_on_us_h", "promised_a_person_24h", "handed_to_human_24h", "human_replied_24h",
                "commitments_open", "commitments_overdue", "promises_kept_24h", "promises_broken_24h",
                "messages_queued", "messages_held", "messages_held_by_reason",
                "owed_followup_24h", "owed_followup_unbacked", "owed_followup_unmeasured",
                "owed_followup_error")
_MESSAGES = (rules.EV_CUSTOMER, rules.EV_CAROLINE, rules.EV_HUMAN_REPLY)
WAIT_BANDS = (("under_2d", 2), ("2d_to_7d", 7), ("7d_to_30d", 30), ("30d_to_90d", 90), ("over_90d", None))


def wait_band(seconds):
    for name, days in WAIT_BANDS:
        if days is None or seconds < days * DAY:
            return name


def waiting_since(events, now):
    """When the customer started waiting on us, or None if the last word is ours (or nobody's).

    It is the FIRST customer message after our last one: someone who wrote on Monday and again
    on Thursday has been waiting since Monday.
    """
    since = None
    for ts, code in events:
        if ts > now or code not in _MESSAGES:
            continue
        if code == rules.EV_CUSTOMER:
            since = ts if since is None else since
        else:
            since = None
    return since


def _happened(events, code, start, now):
    return any(c == code and start < ts <= now for ts, c in events)


def build(facts, register, now, scope, week=None, outbox=None):
    """The file's content. `scope` says what was read; `scope["whole_inbox"]` must be true for the
    inbox-wide numbers to be anything other than null."""
    cfg = register.get("monitor") or {}
    wait_s = int(cfg.get("waiting_on_us_hours", 24)) * HOUR
    doc = {"schema": SCHEMA, "written_at": int(now),
           "written_at_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(now)),
           "rules": facts[0]["rules"] if facts else None, "scope": dict(scope)}
    doc.update({k: None for k in INBOX_FIELDS})
    if week:
        w = week["window"]
        doc["handoff_no_assignment_last_matured_week"] = week["headline"]
        doc["last_matured_week"] = {"from": w["start"], "to": w["end"], "threads": week["threads"]}
    if not scope.get("whole_inbox"):
        doc["scope"]["note"] = ("this reading did not cover the whole inbox, so the inbox-wide numbers "
                                "are not measured (null), not zero")
        return doc
    counts = {"open": 0, "waiting_on_us": 0, "waiting_on_us_robot_mail": 0, "waiting_on_us_under_limit": 0,
              "waiting_on_customer": 0, "open_no_message": 0, "promised_a_person_24h": 0,
              "handed_to_human_24h": 0, "human_replied_24h": 0}
    oldest = 0
    bands = {name: 0 for name, _ in WAIT_BANDS}
    for f in facts:
        ev = f["events"]
        counts["promised_a_person_24h"] += _happened(ev, rules.EV_PROMISE, now - DAY, now)
        counts["handed_to_human_24h"] += _happened(ev, rules.EV_HUMAN_ASSIGNED, now - DAY, now)
        counts["human_replied_24h"] += _happened(ev, rules.EV_HUMAN_REPLY, now - DAY, now)
        if not f.get("open"):
            continue
        counts["open"] += 1
        since = waiting_since(ev, now)
        if since is None:
            spoke = any(c in _MESSAGES for _, c in ev)
            counts["waiting_on_customer" if spoke else "open_no_message"] += 1
        elif now - since <= wait_s:
            counts["waiting_on_us_under_limit"] += 1
        elif f["shape"] == "robot_mail":
            counts["waiting_on_us_robot_mail"] += 1   # a bounce or a helpdesk auto-reply is owed nothing
        else:
            counts["waiting_on_us"] += 1
            bands[wait_band(now - since)] += 1
            oldest = max(oldest, (now - since) // HOUR)
    doc.update(counts)
    doc["waiting_on_us_by_wait"] = bands
    doc["oldest_waiting_on_us_h"] = oldest if counts["waiting_on_us"] else 0
    doc["waiting_on_us_hours"] = wait_s // HOUR
    ledger = commitments.summarize(facts, register, now)
    for key in ("commitments_open", "commitments_overdue", "promises_kept_24h", "promises_broken_24h",
                "commitments_open_unbacked", "commitments_closed_24h", "oldest_overdue_h"):
        doc[key] = ledger[key]
    doc["commitments_by_kind"] = by_kind(ledger, register)
    doc.update(safety_records.summarize(facts, now=datetime.fromtimestamp(now, timezone.utc)))
    if outbox is not None:
        doc.update(outbox)
    return doc


def by_kind(ledger, register):
    """Open and overdue commitments per kind, in the captain's priority order, with the owner."""
    kinds = ((register.get("commitments") or {}).get("kinds") or {})
    names = sorted(set(ledger["open_by_kind"]) | set(kinds),
                   key=lambda k: ((kinds.get(k) or {}).get("priority", 99), k))
    return [{"kind": k, "priority": (kinds.get(k) or {}).get("priority"), "owner": (kinds.get(k) or {}).get("owner"),
             "open": ledger["open_by_kind"].get(k, 0), "overdue": ledger["overdue_by_kind"].get(k, 0)}
            for k in names]


def write(doc, path=None):
    """Atomic: a reader never sees half a file."""
    path = path or DEFAULT_PATH
    folder = os.path.dirname(path) or "."
    os.makedirs(folder, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=".support-backlog.", dir=folder)
    try:
        with os.fdopen(fd, "w") as fh:
            json.dump(doc, fh, indent=2, sort_keys=True)
            fh.write("\n")
        os.chmod(tmp, 0o644)
        os.replace(tmp, path)
    except BaseException:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise
    return path


def held_reasons(counts):
    if not isinstance(counts, dict):
        return ""
    return "   (" + ", ".join(f"{k} {v:,}" for k, v in sorted(counts.items())) + ")" if counts else ""


def render(doc):
    """The block the report prints."""
    if not doc["scope"].get("whole_inbox"):
        return "INBOX RIGHT NOW: not measured. " + doc["scope"]["note"]

    def n(key):
        return "not measured" if doc.get(key) is None else f"{doc[key]:,}"

    lines = [
        f"INBOX RIGHT NOW (every open conversation, as of {doc['written_at_utc']})",
        f"  open                                    {n('open')}",
        f"  waiting on us over {doc['waiting_on_us_hours']}h                  {n('waiting_on_us')}"
        f"   (oldest {n('oldest_waiting_on_us_h')}h; robots and bounces not counted: {n('waiting_on_us_robot_mail')})",
        "    by how long: " + ", ".join(f"{k.replace('_', ' ')} {v:,}" for k, v in doc["waiting_on_us_by_wait"].items()),
        f"  waiting on the customer                 {n('waiting_on_customer')}",
        f"  last 24h: told a person is coming       {n('promised_a_person_24h')}",
        f"  last 24h: handed to a person            {n('handed_to_human_24h')}",
        f"  last 24h: a person replied              {n('human_replied_24h')}",
        f"  last 24h: owed follow-ups recorded      {n('owed_followup_24h')}"
        f"   (no commitment on the thread: {n('owed_followup_unbacked')};"
        f" thread not read: {n('owed_followup_unmeasured')})",
        "",
        "PROMISES (a promise closes only when a message is sent on its own thread)",
        f"  open                                    {n('commitments_open')}"
        f"   (nobody owns: {n('commitments_open_unbacked')})",
        f"  overdue, nothing sent                   {n('commitments_overdue')}   (oldest {n('oldest_overdue_h')}h)",
        f"  last 24h: kept                          {n('promises_kept_24h')}",
        f"  last 24h: broken                        {n('promises_broken_24h')}",
        f"  messages queued                         {n('messages_queued')}",
        f"  messages held                           {n('messages_held')}" + held_reasons(doc.get("messages_held_by_reason")),
    ]
    for row in doc.get("commitments_by_kind") or ():
        if row["open"]:
            owner = row["owner"] or "NOBODY"
            lines.append(f"    {row['kind']:<22} open {row['open']:>6,}  overdue {row['overdue']:>6,}  owner {owner}")
    return "\n".join(lines)
