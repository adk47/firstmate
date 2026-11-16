#!/usr/bin/env python3
"""Caroline coach: read what just happened in Intercom and count where a customer or Caroline struggled.

Captain 2026-11-14: "there are CS lanes aging with caroline and questions not responding well you should be
monitoring convos closely and improving caroline ... as users struggle or caroline struggles".

`caroline-monitor.py` answers "what did Caroline do with each conversation" every 2 hours, from events alone. This
reader asks a different question, on a short interval and from the text: in the conversations touched in the last
N minutes, where did somebody get stuck? Each answer is a SIGNAL (below). A signal is a reason to open the thread,
not a verdict about it, and a count per signal is what turns into one fix per pattern.

What it reuses, and never restates: which part is a reply, who is a person, what a promise of a person is and the
shape of the ask are `caroline_monitor.rules` (`read_events`, `classify`); who is waiting on us is
`caroline_monitor.backlog.waiting_since`; the Intercom reads are `caroline_monitor.collect`.

It reads Intercom (search and GET only), the monitor's own facts file and the output guard's ledger, all
read-only. It sends nothing, assigns nothing and writes nothing outside `--out`. Its output carries conversation
ids and signal names, never message text; `show` prints one masked thread to the terminal for a person or an agent
to read, and stores nothing.

    caroline_coach.py tick [--minutes 30] [--out DIR]     one reading, as JSON on stdout (and kept under DIR)
    caroline_coach.py line  < tick.json                   the one-line status for that reading
    caroline_coach.py census [--out DIR]                  every open conversation in one terminal state, or none
    caroline_coach.py census-line < census.json>          the one-line Item D status for that census
    caroline_coach.py show <conversation id>              one masked thread, to read

Exit: 0 read · 2 could not read Intercom (the reading is NOT MEASURED, and says so; it never prints zeros).
Any other exit is a fault in this reader or a record it did not expect: the reading is marked NOT MEASURED
too, and the run fails so the unit's pager fires. Exit 2 is never used for that.
"""
from __future__ import annotations

import argparse
import concurrent.futures
import hashlib
import json
import os
import re
import sqlite3
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)) if "__file__" in globals() else os.getcwd())

from caroline_monitor import backlog, collect, fixloop, rules  # noqa: E402

SCHEMA = "caroline-coach.v1"
FACTS_DB = "/var/lib/hydra/caroline-monitor/monitor.sqlite"
# The output guard's own record of what it refused, one JSON row per event (plugins/intercom/src/safety-ledger.ts).
# It is the only place that says WHY a reply was replaced with the fallback line: the conversation shows the
# fallback and nothing else. Read-only, and a file that cannot be read is `not_measured`, never "no reason".
SAFETY_LEDGER = "/var/lib/hydra/injection-watch/ledger.jsonl"
GUARD_WHY_MAX = 3             # reasons kept per conversation, newest first
HOUR, DAY = 3600, 86400
AGING_HOURS = 24              # "aging": the customer wrote last and has waited this long
AGING_READ_DAYS = 7           # aging threads younger than this are read in full each tick; older ones are counted
AGING_READ_CAP = 300
UNANSWERED_MINUTES = 15       # Caroline answers in minutes; a customer left longer than this got no answer
MIN_TOKENS = 5                # a message shorter than this is not compared ("ok", "thanks", "any update?")
REPEAT_JACCARD = 0.6
LOOP_JACCARD = 0.9

WHO_CUSTOMER, WHO_CAROLINE, WHO_HUMAN = "c", "a", "h"
ROBOT_MAIL = "robot_mail"     # the monitor's shape for a bounce, an auto-reply or a mailing-list message
KEEP_TICK_DAYS = 14           # --out keeps this many days of readings

FRUSTRATION = re.compile(
    r"\b(frustrat\w+|ridiculous|unacceptable|disappoint\w+|terrible|awful|useless|a joke|fed up|sick of|waste of (my )?time"
    r"|nobody (is |has )?(repl|answer|respond|help)\w*|no ?one (is |has )?(repl|answer|respond|help)\w*"
    r"|still (waiting|no (reply|response|answer|update))|been waiting|(for|it'?s been) (weeks|months)"
    r"|(second|third|fourth|fifth|2nd|3rd|4th|5th) time|how many times|i (already|just) (told|said|sent|explained)"
    r"|as i (said|mentioned|wrote)|again and again|over and over|going (a)?round in circles|same (answer|response|reply)"
    r"|not (helping|helpful|what i asked)|you('re| are) not (listening|reading|answering)|didn'?t answer"
    r"|cancel my (subscription|account)|charge ?back|report (you|this)|scam)\b", re.I)

CANNOT = re.compile(
    r"\b(i (can'?t|cannot|am not able to|'m not able to|am unable to|'m unable to|don'?t have (access|a way|the ability)|"
    r"do not have (access|a way|the ability))|i can'?t tell you when|i'?m not able to (see|check|access|confirm|verify)|"
    r"i (don'?t|do not) (know|have (any )?(information|visibility)))\b", re.I)

# WHAT she said she cannot do, read from the sentence that says it. The kind is what turns a count into one fix:
# "cannot say when" is a missing date or outcome, "cannot tell if the proof is enough" is a missing read of the
# request's own document state, "cannot see the status" is a missing status read. First match wins, in this order.
CANNOT_KINDS = (
    ("mail_bounce", re.compile(r"\b(delivery (failure|delay|notice)s?|automated (message|reply)|outside muso|other organi[sz]ations"
                               r"|mail setup|on your behalf)\b", re.I)),
    ("when", re.compile(r"\b(when|date|time(frame)?|how long|faster|speed (it|this|that)? ?up|sooner|wait time|response time"
                        r"|make (it|the review) move)\b", re.I)),
    ("proof_enough", re.compile(r"\b(enough|sufficient|added to your|document(ation)?|screenshots?|photos?|proof|links? alone"
                                r"|needs? (one|more))\b", re.I)),
    ("status", re.compile(r"\b(status|claims?|review|holding|pending|progress|hidden|removed|completed|approved?|cancell?ed"
                          r"|which (account|profile))\b", re.I)),
)
CANNOT_OTHER = "other"

SIGNALS = {
    "repeat_ask": "the customer sent the same ask again after we had answered it",
    "frustration": "the customer's words say they are stuck or angry",
    "asks_human": "the customer asked for a person",
    "caroline_loop": "Caroline sent the same reply twice in one thread",
    "caroline_cannot": "Caroline said she cannot do or see something",
    "promise_unbacked": "Caroline said a person is coming and nobody was assigned",
    "guard_fallback": "the output guard replaced her reply with the fallback line",
    "customer_unanswered": f"the customer wrote last and has had no answer for {UNANSWERED_MINUTES} minutes or more",
}
# Asked for by the lane and NOT readable from a thread. They are named so that nobody reads their absence as zero.
NOT_MEASURED = {
    "tool_error": "a failed tool call is in the gateway's log, not in the conversation",
    "account_mismatch": "whether an answer matches the customer's account needs the account read, which this reader does not make",
}

_WORD = re.compile(r"[a-z0-9À-ɏ']{3,}")


def tokens(text):
    """The words a message is compared on: quoted mail history and signatures removed, by the rules' own reading."""
    return frozenset(_WORD.findall(rules._strip_quote(rules.norm(text))))  # noqa: SLF001 (the one quote rule)


def jaccard(a, b):
    return (len(a & b) / len(a | b)) if (a and b) else 0.0


def messages(thread, non_human=rules.DEFAULT_NON_HUMAN_ADMINS):
    """The thread as [(ts, who, text)], oldest first. Which part is a message is `rules.read_events`' rule; a test
    holds this walk to that one, so the two cannot drift."""
    non_human = set(str(x) for x in non_human) | {"", "0", "None"}
    created = int(thread.get("created_at") or 0)
    source = thread.get("source") or {}
    out = []
    if source.get("at") in rules.CUSTOMER_AUTHOR_TYPES:
        out.append((created, WHO_CUSTOMER, source.get("body") or ""))
    for part in thread.get("parts") or []:
        kind, author_type = part.get("t"), part.get("at")
        body = (part.get("body") or "").strip()
        ts = int(part.get("ts") or created)
        if author_type in rules.CUSTOMER_AUTHOR_TYPES:
            if kind == "comment" and (body or part.get("att")):
                out.append((ts, WHO_CUSTOMER, body))
            continue
        if author_type != "admin" or kind not in rules._REPLY_PART_TYPES or not body:  # noqa: SLF001
            continue
        author_id = str(part.get("aid") or "")
        if author_id == rules.CAROLINE_ADMIN_ID:
            out.append((ts, WHO_CAROLINE, body))
        elif author_id not in non_human:
            out.append((ts, WHO_HUMAN, body))
    out.sort(key=lambda m: m[0])
    return out


def held_by_a_person(thread, non_human=rules.DEFAULT_NON_HUMAN_ADMINS, staffed=()):
    """Whether a person, or a team the register lists as staffed, holds the thread NOW. Asked of the rules'
    own reader and not restated: with no parts to read, `read_events` reports a human assignment exactly when
    the final assignee is one."""
    holder = {"created_at": thread.get("created_at"), "updated_at": thread.get("updated_at"),
              "admin_assignee_id": thread.get("admin_assignee_id"), "team_assignee_id": thread.get("team_assignee_id")}
    return any(code == rules.EV_HUMAN_ASSIGNED for _, code in rules.read_events(holder, non_human, staffed))


def signals_of(thread, events, now, non_human=rules.DEFAULT_NON_HUMAN_ADMINS, staffed=()):
    """{signal: timestamp of the newest part that shows it}. A signal absent from the dict was not seen."""
    msgs = messages(thread, non_human)
    found = {}

    def hit(name, ts):
        found[name] = max(found.get(name, 0), ts)

    earlier_customer, earlier_caroline = [], []     # [words, answered since?] and [words]
    for ts, who, text in msgs:
        if who == WHO_CUSTOMER:
            words = tokens(text)
            normed = rules.norm(text)
            if FRUSTRATION.search(normed):
                hit("frustration", ts)
            if rules._HUMAN.search(normed):  # noqa: SLF001 (the rules' own "asked for a person")
                hit("asks_human", ts)
            if len(words) >= MIN_TOKENS:
                # "after we had answered it": at least one reply of ours stands between the two messages.
                if any(answered and jaccard(words, w) >= REPEAT_JACCARD for w, answered in earlier_customer):
                    hit("repeat_ask", ts)
                earlier_customer.append((words, False))
        else:
            # every earlier customer message has now had a reply after it
            earlier_customer = [(w, True) for w, _ in earlier_customer]
            if who == WHO_CAROLINE:
                words = tokens(text)
                if CANNOT.search(rules.norm(text)):
                    hit("caroline_cannot", ts)
                if len(words) >= MIN_TOKENS and any(jaccard(words, w) >= LOOP_JACCARD for w in earlier_caroline):
                    hit("caroline_loop", ts)
                if len(words) >= MIN_TOKENS:
                    earlier_caroline.append(words)

    # A promise of a person is backed when a person was assigned at or after it, or a person holds the thread
    # now (assigned BEFORE she said it and still there). A person who held it earlier and gave it back does not.
    assigned = [ts for ts, code in events if code == rules.EV_HUMAN_ASSIGNED]
    held = held_by_a_person(thread, non_human, staffed)
    for ts, code in events:
        if code == rules.EV_PROMISE and not held and not any(a >= ts for a in assigned):
            hit("promise_unbacked", ts)
        elif code == rules.EV_GUARD:
            hit("guard_fallback", ts)
    since = backlog.waiting_since(events, now)
    if since is not None and now - since >= UNANSWERED_MINUTES * 60:
        hit("customer_unanswered", since)
    return found


def cannot_kinds(thread, since=0, non_human=rules.DEFAULT_NON_HUMAN_ADMINS):
    """The kinds of thing Caroline said she cannot do, in her replies at or after `since`, sorted."""
    kinds = set()
    for ts, who, text in messages(thread, non_human):
        if who != WHO_CAROLINE or ts < since:
            continue
        for sentence in re.split(r"(?<=[.!?;])\s+", rules.norm(text)):
            if CANNOT.search(sentence):
                kinds.add(next((name for name, rx in CANNOT_KINDS if rx.search(sentence)), CANNOT_OTHER))
    return sorted(kinds)


def last_word(events, now):
    for ts, code in reversed(events):
        if ts <= now and code in (rules.EV_CUSTOMER, rules.EV_CAROLINE, rules.EV_HUMAN_REPLY):
            return code
    return ""


def search_touched(token, since_ts, request=None):
    """(rows, Intercom's own count) for every conversation touched since `since_ts`, whatever its age."""
    query = {"operator": "AND", "value": [{"field": "updated_at", "operator": ">", "value": int(since_ts) - 1}]}
    kwargs = {"request": request} if request else {}
    try:
        return collect._search(token, query, lambda r: r["updated_at"] >= since_ts, **kwargs)  # noqa: SLF001
    except (OSError, ValueError) as exc:      # the transport's own failures, as collect.collect() names them
        raise collect.CollectError(f"Intercom search failed: {type(exc).__name__}: {exc}") from exc


def fetch_all(token, ids, request=None, workers=collect.WORKERS):
    """({id: thread}, {id: reason}, [gone ids])."""
    kwargs = {"request": request} if request else {}
    threads, errors, gone = {}, {}, []
    if not ids:
        return threads, errors, gone
    with concurrent.futures.ThreadPoolExecutor(max_workers=max(1, workers)) as pool:
        for cid, (record, err) in zip(ids, pool.map(lambda c: collect.fetch_thread(token, c, **kwargs), ids)):
            if record is not None:
                threads[cid] = record
            elif err == "gone":
                gone.append(cid)
            else:
                errors[cid] = err
    return threads, errors, gone


def guard_reasons(ids, path=SAFETY_LEDGER, now=None, days=AGING_READ_DAYS):
    """{conversation id: [why the guard refused, newest first]} from the guard's own ledger.

    A `guard_fallback` signal says a reply was replaced with the fallback line; it does not say which rule fired,
    and the conversation cannot: the customer only ever saw the fallback. The ledger can, so the pattern table can
    name the cause instead of guessing at it. Only rows for the ids asked about are kept, and only the newest
    GUARD_WHY_MAX reasons per conversation.

    Returns `{"not_measured": reason}` when the ledger cannot be read: an unreadable ledger is not "no reason".
    """
    now = now or int(time.time())
    wanted = {str(c) for c in ids}
    if not wanted:
        return {}
    files = [path]
    try:                       # the ledger is sealed daily; a thread from last week is in a sealed file
        folder = os.path.dirname(path)
        base = os.path.basename(path)
        for name in sorted(os.listdir(folder)):
            if name.startswith(base + ".sealed-"):
                full = os.path.join(folder, name)
                if now - os.path.getmtime(full) <= days * DAY:
                    files.append(full)
    except OSError:
        pass                   # no sealed files is normal; the current file is still read below
    found, read_any = {}, False
    for full in files:
        try:
            with open(full, encoding="utf-8", errors="replace") as fh:
                read_any = True
                for raw in fh:
                    try:
                        row = json.loads(raw)
                    except ValueError:
                        continue
                    cid = str(row.get("ref") or "")
                    if cid not in wanted:
                        continue
                    why = guard_why_of(row)
                    if why:
                        found.setdefault(cid, []).append((str(row.get("ts") or ""), why))
        except OSError as exc:
            if full == path:
                return {"not_measured": f"{type(exc).__name__}: {exc}"[:200]}
    if not read_any:
        return {"not_measured": "the guard's ledger was not read"}
    out = {}
    for cid, rows in found.items():
        seen, kept = set(), []
        for _, why in sorted(rows, reverse=True):
            if why not in seen:
                seen.add(why)
                kept.append(why)
        out[cid] = kept[:GUARD_WHY_MAX]
    return out


def guard_why_of(row):
    """One reason string for a ledger row, or '' when the row is not a REFUSAL.

    Only an enforced, terminal refusal is a reason a reply was replaced with the fallback line. The ledger also
    records rows that refused nothing, and counting those would name a cause that did not fire: an `output_note`
    is a passing answer that was noted, an `output_guard` row in shadow mode (`enforced: false`) did not stop
    anything, and a retry whose outcome is `pending` or `passed` did not fail. A conversation that was refused once
    and answered properly later would otherwise be reported as refused for the later row's reason (QA 2026-11-15).

    `enforced` is the guard's own word for "this row replaced the reply" and every `output_guard` row has carried
    it since the guard shipped (caroline-safety.ts), so it alone decides. `mode` is not read: a row that says
    `enforced: false` refused nothing whatever else it says, and a row with no `enforced` is not a known refusal.
    """
    kind = row.get("kind")
    if kind == "output_guard_retry":
        if str(row.get("outcome") or "") != "unusable":
            return ""
        why = str(row.get("why") or "")
        return f"retry:{why}" if why else "retry:unusable"
    if kind == "unbacked_handoff":
        return "unbacked_handoff" if str(row.get("action") or "") == "fallback" else ""
    if kind == "output_guard":
        if row.get("enforced") is not True:
            return ""
        names = []
        for f in row.get("flags") or []:
            if not isinstance(f, dict) or not f.get("rule"):
                continue
            family = str(f.get("family") or "")
            names.append(f"{family}:{f['rule']}" if family and family != "note" else str(f["rule"]))
        return "guard:" + ",".join(names[:2]) if names else ""
    return ""


def read_aging(db_path, now):
    """Who has waited on us for AGING_HOURS or more, from the monitor's facts. A file that cannot be read is
    `not_measured` with the reason, never an empty list: "nobody is waiting" and "could not look" are different."""
    try:
        db = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True, timeout=10)
        try:
            rows = db.execute("SELECT id, events, shape FROM facts WHERE open = 1").fetchall()
            taken = db.execute("SELECT MAX(taken_at) FROM readings").fetchone()[0]
        finally:
            db.close()
    except sqlite3.Error as exc:
        return {"not_measured": f"{type(exc).__name__}: {exc}"[:200]}
    if not taken:
        return {"not_measured": "the monitor has recorded no reading"}
    by_band, recent, total, robot = {}, [], 0, 0
    for cid, events_json, shape in rows:
        try:
            events = json.loads(events_json)
        except ValueError:
            return {"not_measured": f"facts row {cid} does not parse"}
        since = backlog.waiting_since(events, now)
        if since is None or now - since < AGING_HOURS * HOUR:
            continue
        if shape == ROBOT_MAIL:      # a bounce or an auto-reply is not a customer waiting: counted apart, never read
            robot += 1
            continue
        total += 1
        band = backlog.wait_band(now - since)
        by_band[band] = by_band.get(band, 0) + 1
        if now - since < AGING_READ_DAYS * DAY:
            recent.append((since, str(cid)))
    recent.sort()      # longest wait first: past the limit, the ones left unread are the shortest waits
    return {"hours": AGING_HOURS, "count": total, "robot_mail": robot, "by_wait": by_band,
            "facts_age_min": int((now - int(taken)) / 60), "under_read_days": len(recent),
            "read_limit": AGING_READ_CAP, "not_read_over_limit": max(0, len(recent) - AGING_READ_CAP),
            "read_ids": [cid for _, cid in recent[:AGING_READ_CAP]]}


# ---------------------------------------------------------------------------------------------------------------
# The terminal-state census (plan-everything-ends-20261115 Item D).
#
# Every OPEN conversation ends in exactly one of four states, or in none:
#
#   answered            a fact was given and nothing is owed by either side
#   decided             an approve or a refuse with the reason and what would change it
#   waiting_on_customer one named item the customer has to send or do
#   closed_stale        we spoke last and the customer has been silent STALE_DAYS
#   none                no terminal state: the customer spoke last, or our last line settled nothing
#
# "none" is the lingering count and it is the number that must fall. The classification is read from the LAST
# message of the thread by the ordered table below, and a message that matches no row is `none`/`unclassified`:
# the fail-closed direction is the one that keeps the number honest, because an unread line counted as answered
# is a conversation nobody will ever look at again.
#
# The two holding lines are `none` on purpose and are counted apart, because they are the shape that looks like
# an answer and is not one: the backlog drain's "we did not reply to this message when you sent it ... tell us what
# you need" asks the customer to restate a question we already have, and the hand-off line promises a person who
# does not exist. Counting either as `waiting_on_customer` would make the number fall while nothing was answered.
CENSUS_SCHEMA = "caroline-coach-census.v1"
# Bumped whenever a rule below changes: the cache is keyed on it, so a changed rule re-reads every thread
# instead of serving the previous rule set's answers.
CENSUS_VERSION = "2026-11-15.12"
CENSUS_CACHE = "/var/lib/hydra/caroline-coach/census.sqlite"
STALE_DAYS = 90
CENSUS_STATES = ("none", "answered", "decided", "waiting_on_customer", "closed_stale")

# The drain's holding line and the hand-off line, as the senders write them. Both are `none`.
HOLDING = re.compile(
    r"(we did not reply to this message when you sent it"
    r"|your message is here and it will be read)", re.I)
HANDOFF = re.compile(
    r"(pulling in a teammate|i'?m bringing in|hand(ing)? (this|you) (over|to) (a|the) (teammate|team))", re.I)
# A refusal on its own is not a decision. "Your request was denied." gives no reason and no way forward, so it
# is a dead end and counts as `none`; the approved decline paragraph carries what would change it ("You can
# resubmit for the credit again later"), and that is what makes it a decision.
REFUSAL = re.compile(r"\b(denied|declined|rejected|refused|not approved|we can'?t approve|we cannot approve"
                     r"|closed when|wasn'?t enough to confirm|was not enough to confirm|submit it again)\b", re.I)
RESUBMIT = re.compile(r"\b(resubmit|re-?submit|apply again|submit (it|them|those|these) again"
                      r"|send (it|them|those|these) again|again later|fresh review)\b", re.I)
DECISION = re.compile(
    r"\b(approved|denied|declined|rejected|refused|we can'?t approve|we cannot approve|not approved|has been reviewed"
    r"|have been reviewed|you can resubmit|resubmit (for )?(those|these|the) credits?"
    r"|submit (it|them|those|these) again|closed when|wasn'?t enough to confirm|was not enough to confirm"
    r"|has been removed"
    r"|have been removed|we removed|credit was added|credits are on your (muso )?profile)\b", re.I)
# What turns a "cannot" into an answer: where the outcome will come from. Without one it is a dead end.
#
# The courtesy invitations are deliberately NOT here ("let me know", "reply here", "keep you posted"). They give
# the customer nothing to do about the thing they asked about, so "I cannot tell you when the review will finish.
# Let me know if you have any other questions." is a dead end that happens to end politely, not an answer (QA
# round 4 on #2049).
NEXT_STEP = re.compile(
    r"\b(will appear here|appears? here|you'?ll hear|you will hear|in this conversation|by email"
    r"|i'?ve added|i have added|has been added|have been added|added (that|your|it|this)"
    r"|the team (can|will)|we'?ll follow up|we will follow up|will be in touch|an update)\b", re.I)
# One named item the customer has to send or do. A question mark is the strongest form of it.
ASK = re.compile(
    r"(\?|\b(could you|can you|would you|please (also )?(send|share|reply|confirm|let|paste)|paste the"
    r"|send (us|me|the|a|your|it|over|everything)|resend|include your|share the link|reply (here|from|with)"
    r"|tell (us|me) (what|which|a little)"
    r"|which one did you mean|what happened on"
    r"|confirm it'?s you|confirm it is you|upload|attach)\b)", re.I)

# The same ask, but only for a CONCRETE thing the customer owes us. A refusal that names an item to send has a
# way forward even when it does not say "resubmit": "We cannot approve this without proof. Could you send us
# your agreement?" is waiting_on_customer, not a dead end (QA round 3 on #2049).
#
# Three things are deliberately NOT here. The bare `?`, because a refusal ending on a courtesy question ("Any
# other questions?") is still a refusal with no way forward. The generic closing invitations ("reply here and
# tell us what you need", "let me know"), because the approved decision copy ends on one of those and it is
# politeness, not an item the customer owes us. And a bare "could you" / "can you" / "would you", because the
# verb after it decides everything: "Could you send us your agreement?" asks for an item, and "Could you let us
# know if you have any other questions?" asks for nothing (QA round 5 on #2049).
NAMED_ASK = re.compile(
    r"\b((could|can|would) you (also )?(send|share|confirm|paste|resend|include|upload|attach|provide|give)"
    r"|(could|can|would) you (also )?tell (us|me) which"
    r"|please (also )?(send|share|confirm|paste|resend|include|upload|attach|provide|give)"
    r"|paste the|send (us|me|the|a|your|it|over|everything)|resend|include your|share the link"
    r"|which one did you mean|confirm it'?s you|confirm it is you|upload|attach)\b", re.I)

# A fact given: a status, an outcome, how something works, or a closing line. Nothing is owed after it. This is
# an explicit list of the shapes Caroline actually sends, read off node-8's open conversations - NOT a default.
# A line no rule matches is `none`/`unclassified`, because "We are looking into this." is not an answer and must
# never lower the lingering count.
ANSWERED = re.compile(
    r"\b(you'?re right|you are right|you got it|got it|none taken|no worries|that helps|that makes sense"
    r"|makes sense|thanks for the|thank you for the|perfect, thanks|yep|love to hear it|glad (i could|to help|it)"
    r"|you don'?t need to|you do not need to|this screen is asking|you'?ll need to|you will need to"
    r"|i'?ve added|i have added|has been added|have been added|i'?ve updated|i'?ve sent|i'?ve flagged|flagged"
    r"|both profiles are yours|we can see|fair question|anytime|you'?re welcome|you are welcome|no problem"
    r"|happy to help|let me know|i'?m here if|good to hear|fingers crossed|here'?s how|here is how"
    r"|in the verification queue|verification queue|in our review queue|we'?ll message you here"
    r"|you'?ll hear|you will hear|will appear here|appears? here|we will follow up here|follow up within"
    r"|has taken longer than it should|taken longer than it should|we have your request|we have the document"
    r"|everything you send here is recorded|claims are confirmed by|i'?m caroline, an ai assistant"
    r"|remains open|here is where your request|is complete|refunded|refreshed|corrected|all sorted"
    r"|you can pull|to see public stats|fully reviewed|credits are the roles|in progress|that'?s the correct"
    r"|we don'?t currently|it'?s linked|is free forever|may take 24hrs|are now hidden|no longer publicly available"
    r"|has been updated to|still working on|for manual (review|verification)|it is with the team|good bet"
    # A completed action in the first person is a fact given, whatever the verb: "I've applied 50% off",
    # "I've created a ticket", "we've refreshed your analytics".
    r"|\b(i'?ve|i have|we'?ve|we have)\s+\w+ed\b"
    # A state the customer can act on, or a link they can use.
    r"|\b(is|are|was|were)\s+(now\s+)?(verified|added|cancell?ed|complete|completed|updated|included|hidden"
    r"|removed|merged|linked|applied|active|set|sorted|in progress|with the team|being (printed|processed))\b"
    # A thing that is now on the profile or the account is a fact given, whatever the noun: "The track La Vida
    # is now on your profile." The noun is the customer's own title, so it can never be a fixed word list.
    r"|\b(is|are|was|were)\s+(now\s+)?(on|in)\s+your\s+(profile|account|page)\b"
    r"|\b(you'?re|you are)\s+(all set|very welcome|welcome)\b"
    r"|\b(log in at|sign in at|go to settings|open the (track|album|app)|select\b|choose\b|click\b|try again"
    r"|try that|try the|forgot password|clear .{0,20}cache)\b"
    r"|\b(refund|refunded|here'?s the profile|best bet|always a pleasure|marked as a priority|created a ticket"
    r"|can confirm|i can see|nothing else you need to do|already verified|is verified|isn'?t guaranteed"
    r"|aren'?t visible|isn'?t visible|will keep|you'?ll keep|will remain|will apply|hasn'?t shipped"
    r"|no tracking link|is now your main page|merged into it|doesn'?t review|only for muso|points to)\b"
    r"|\b(app\.muso\.ai|muso\.ai/)\b"
    r"|\b(you too|sure thing|just shout|contact the|report the|been removed|will be hidden|you can use"
    r"|don'?t offer|no longer be associated|updated the request)\b"
    r"|^(added|done)\b)", re.I)

# Non-ASCII characters English copy itself uses. Anything else outside ASCII means the line is not English.
TYPOGRAPHIC = frozenset("‘’“”–—… ")

# Words that are not English and are common in the languages Caroline answers in. Used ONLY for a line too short
# for the English ratio to decide (see is_english): several of these are also ordinary name and title tokens
# ("De La Cruz", "La Vida"), so a long English line must never be judged by one of them (QA round 4 on #2049).
NON_ENGLISH = frozenset("avec plaisir merci bonjour oui non gracias hola por para con muy saludos tienes razon "
                        "gern danke bitte und der die das ist nicht sie wir ich de la el los las que".split())

# Words that are English and are rare in the other languages Caroline answers in. Used only to tell "this line is
# in a language these rules cannot read" from "this line settled something" - never to judge what it settled.
ENGLISH = frozenset("the you your we our is are was were it that this these there their its i'm you're we've "
                    "can't don't doesn't won't will would should with from have has had they them but not"
                    .split())

# (state, reason, pattern) in the order they are tried. First match wins.
CENSUS_RULES = (
    ("none", "holding_line", HOLDING),
    ("none", "promise_no_person", HANDOFF),
    # A named ask outranks a decision: "We cannot approve this without proof. Could you send us your
    # agreement?" is conditional, and the customer owes us one item, so the conversation is waiting on
    # them. It sits AFTER the holding and hand-off lines because those also say "reply here" and are
    # still not answers (QA round 3 on #2049).
    ("waiting_on_customer", "asks_customer", NAMED_ASK),
    ("decided", "decision", DECISION),
    ("waiting_on_customer", "asks_customer", ASK),
)


def is_english(text):
    """Whether a line is in English, by its letters and the share of English function words in it.

    Caroline answers in the customer's language, so a third of her outbound lines are not English. These rules
    are English, so a line in another language is `none`/`not_english` and is counted: never read as settled,
    and never silently guessed at. A letter outside ASCII settles it on its own - "¿Puedes ayudarme?" carries a
    question mark, and the question-mark rule must not read it as a named ask in a language it cannot parse.
    """
    body = text or ""
    words = [w.lower() for w in re.findall(r"[^\W\d_]+(?:'[^\W\d_]+)?", body)]
    if len(words) < 4:
        # Too short for a ratio, so vocabulary and characters decide: "Merci beaucoup!" is two ASCII words and
        # no English, and "¿Puedes ayudarme?" is two ASCII words and a Spanish question mark. "Approved." carries
        # no language signal and stays English.
        if any(w in NON_ENGLISH for w in words):
            return False
        return not any(ord(ch) > 127 and ch not in TYPOGRAPHIC for ch in body)
    # A long line is decided by its English function words alone. A name or a title inside an English sentence
    # ("Your profile for De La Cruz is now verified.") must not make the line unreadable.
    return sum(1 for w in words if w in ENGLISH) / len(words) >= 0.10


# A conditional courtesy invitation is politeness, never content: "Let me know if you need anything else." and
# "Any other questions?" give the customer nothing to do about the thing they asked about. The courtesy CLAUSE is
# removed before the ask and answer rules run, so a non-answer it is appended to stays a non-answer (QA round 6
# on #2049).
#
# The match starts at the nearest CLAUSE boundary, not the nearest sentence: a comma is as much of a boundary as a
# full stop here. "Your profile is now verified, let me know if you need anything else." is an answer in the first
# clause and a courtesy in the second, and starting the match at the previous full stop erased both (QA round 7
# on #2049). A standalone closing ("Anytime, Ricardo!") is not conditional and is not removed.
COURTESY = re.compile(
    r"[^.!?,;:]*\b(any other questions|let me know if|reply here if|if you need anything else"
    r"|keep you posted|if there'?s anything else|if you have any other)\b[^.!?,;:]*[.!?]?", re.I)


def classify_last(text):
    """(state, reason) for the last message of a thread.

    Ordered, first match wins. A line in a language these rules cannot read is `none`/`not_english` before any
    English pattern is tried. A "cannot" with no next step behind it is `none`/`only_cannot` - a dead end is not
    an answer. A line no rule matches is `none`/`unclassified`: the fail-closed direction is the one that keeps
    the number honest, because an unread line counted as answered is a conversation nobody will look at again.
    """
    normed = rules.norm(text or "")
    if not (text or "").strip():
        return "none", "unclassified"
    if not is_english(text):
        return "none", "not_english"
    # The courtesy sentence goes before any rule reads the line, so neither the ask rule (on its question mark)
    # nor the answer rule (on "let me know") can settle a thread the courtesy was merely appended to.
    normed = COURTESY.sub(" ", normed)
    # A stripped clause leaves its own separator behind: "...verified, let me know..." ends on a comma.
    normed = normed.strip().rstrip(",;:").strip()
    if not normed:
        return "none", "unclassified"
    if REFUSAL.search(normed) and not RESUBMIT.search(normed) and not NAMED_ASK.search(normed):
        return "none", "refusal_no_way_forward"
    # The holding and hand-off lines first: they also say "reply here" and are still not answers.
    for state, reason, pattern in CENSUS_RULES[:2]:
        if pattern.search(normed):
            return state, reason
    # The dead-end check runs BEFORE the ask and decision rules, not after. "I cannot remove this. Reply here if
    # you need anything else." carries a courtesy invitation that the ask rule would read as a named item, and
    # "I cannot tell you when the review will finish. Let me know..." carries one the answer rule would read as a
    # fact. Neither resolves the request, so both stay dead ends (QA round 4 on #2049). A refusal that names a
    # CONCRETE item to send is not a dead end and falls through to the ask rule below.
    if (CANNOT.search(normed) and not NAMED_ASK.search(normed) and not NEXT_STEP.search(normed)
            and not RESUBMIT.search(normed)):
        return "none", "only_cannot"
    for state, reason, pattern in CENSUS_RULES[2:]:
        if pattern.search(normed):
            return state, reason
    if ANSWERED.search(normed):
        return "answered", "fact_given"
    return "none", "unclassified"


def census_row(thread, now, non_human=rules.DEFAULT_NON_HUMAN_ADMINS, staffed=()):
    """One conversation's terminal state, read from its last message and its assignee."""
    msgs = messages(thread, non_human)
    held = held_by_a_person(thread, non_human, staffed)
    if not msgs:
        return {"state": "none", "reason": "no_message", "last_who": "", "last_ts": 0, "held": held,
                "frustrated_ts": 0, "shape": rules.classify(thread)}
    last_ts, last_who, last_text = msgs[-1]
    if last_who == WHO_CUSTOMER:
        state, reason = "none", "customer_last"
    elif now - last_ts >= STALE_DAYS * DAY:
        state, reason = "closed_stale", "silent_90d"
    else:
        state, reason = classify_last(last_text)
    # A person holding the thread is a terminal state of its own kind: it is not ours to answer. It is counted
    # apart and never folded into `answered`, because a thread a person is sitting on is not a fact given.
    if held and state == "none" and reason in ("customer_last", "unclassified"):
        reason = "held_by_person"
    # The newest customer message that says they are stuck or angry. The hour window is applied when the
    # reading is put together, NOT here: this row is cached until the thread changes, so a boolean decided at
    # read time would carry last hour's answer into every hour after it.
    frustrated_ts = max([ts for ts, who, text in msgs
                         if who == WHO_CUSTOMER and FRUSTRATION.search(rules.norm(text))] or [0])
    return {"state": state, "reason": reason, "last_who": last_who, "last_ts": last_ts, "held": held,
            "frustrated_ts": frustrated_ts, "shape": rules.classify(thread)}


CENSUS_KEY = f"{rules.RULES_VERSION}+census{CENSUS_VERSION}"


def _cache_key(updated_at):
    """What a cached row is invalidated by: the thread's own `updated_at`, which is the monitor's own rule.

    `facts.updated_at` is Intercom's thread timestamp, not the row's write time - the monitor keeps it so that
    "a thread whose `updated_at` has not moved is not fetched again" (caroline_monitor/store.py). It moves on
    every change to the thread, a reassignment with no new message included, which is exactly when a cached
    state can be wrong. Keying on the last event instead missed that: an assignment part writes no message, so
    a thread handed from a person to automation kept its key and served a stale `held`.
    """
    return str(int(updated_at or 0))


def _census_cache(path):
    """The cache, or None when it cannot be opened. A cache that cannot be written is not a reason to fail a
    reading: the reading is still true, it is only slower."""
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        db = sqlite3.connect(path, timeout=30)
        db.execute("CREATE TABLE IF NOT EXISTS census (id TEXT PRIMARY KEY, updated_at INTEGER, rules TEXT,"
                   " state TEXT, reason TEXT, shape TEXT, last_ts INTEGER, last_who TEXT, held INTEGER,"
                   " frustrated INTEGER, seen_at INTEGER)")
        db.commit()
        return db
    except (sqlite3.Error, OSError):
        return None


def census(token, now, db_path=FACTS_DB, cache_path=CENSUS_CACHE, request=None, workers=collect.WORKERS):
    """Every open conversation in one terminal state, or none. Reads Intercom; writes only the cache."""
    try:
        db = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True, timeout=10)
        try:
            rows = db.execute("SELECT id, updated_at, events FROM facts WHERE open = 1").fetchall()
            taken = db.execute("SELECT MAX(taken_at) FROM readings").fetchone()[0]
        finally:
            db.close()
    except sqlite3.Error as exc:
        return {"schema": CENSUS_SCHEMA, "as_of": now, "not_measured_reason": f"facts: {type(exc).__name__}: {exc}"[:200]}
    if not rows:
        return {"schema": CENSUS_SCHEMA, "as_of": now, "not_measured_reason": "the monitor lists no open conversation"}

    cfg = (fixloop.load_register() or {}).get("monitor") or {}
    non_human = tuple(cfg.get("non_human_admin_ids") or rules.DEFAULT_NON_HUMAN_ADMINS)
    staffed = tuple(cfg.get("staffed_team_ids") or ())

    cache = _census_cache(cache_path)
    known = {}
    if cache is not None:
        try:
            for cid, up, ver, state, reason, shape, last_ts, last_who, held, frus in cache.execute(
                    "SELECT id, updated_at, rules, state, reason, shape, last_ts, last_who, held, frustrated FROM census"):
                if ver == CENSUS_KEY:
                    known[(str(cid), str(up))] = {"state": state, "reason": reason, "shape": shape,
                                                  "last_ts": int(last_ts), "last_who": last_who,
                                                  "held": bool(held), "frustrated_ts": int(frus or 0)}
        except sqlite3.Error:
            known = {}

    wanted = [(str(cid), _cache_key(up)) for cid, up, _events in rows]
    stale = [cid for cid, up in wanted if (cid, up) not in known]
    threads, errors, gone = fetch_all(token, stale, request, workers)

    out, fresh = {}, []
    for cid, up in wanted:
        row = known.get((cid, up))
        if row is None and cid in threads:
            row = census_row(threads[cid], now, non_human, staffed)
            fresh.append((cid, up, row))
        if row is not None:
            out[cid] = row
    if cache is not None and fresh:
        try:
            cache.executemany("INSERT OR REPLACE INTO census VALUES (?,?,?,?,?,?,?,?,?,?,?)",
                              [(cid, up, CENSUS_KEY, r["state"], r["reason"], r["shape"], r["last_ts"],
                                r["last_who"], int(r["held"]), int(r["frustrated_ts"]), now) for cid, up, r in fresh])
            cache.commit()
        except sqlite3.Error:
            pass
    if cache is not None:
        cache.close()

    by_state = {name: 0 for name in CENSUS_STATES}
    by_reason, by_state_reason, by_shape_none, frustrated_shapes = {}, {}, {}, {}
    held = 0
    for row in out.values():
        # The 90-day boundary is TIME, not a change to the thread, so it is applied here and not only at read
        # time: a row cached as `answered` on day 89 would otherwise be served unchanged on day 90 forever.
        if (row["state"] != "closed_stale" and row["last_who"] != WHO_CUSTOMER and row["last_ts"]
                and now - row["last_ts"] >= STALE_DAYS * DAY):
            row = dict(row, state="closed_stale", reason="silent_90d")
        by_state[row["state"]] = by_state.get(row["state"], 0) + 1
        by_reason[row["reason"]] = by_reason.get(row["reason"], 0) + 1
        by_state_reason.setdefault(row["state"], {})
        by_state_reason[row["state"]][row["reason"]] = by_state_reason[row["state"]].get(row["reason"], 0) + 1
        if row["held"]:
            held += 1
        if row["state"] == "none":
            by_shape_none[row["shape"]] = by_shape_none.get(row["shape"], 0) + 1
        if row["frustrated_ts"] >= now - HOUR:
            frustrated_shapes[row["shape"]] = frustrated_shapes.get(row["shape"], 0) + 1
    top = sorted(frustrated_shapes.items(), key=lambda kv: (-kv[1], kv[0]))[:5]
    return {
        "schema": CENSUS_SCHEMA, "as_of": now, "as_of_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(now)),
        "rules": rules.RULES_VERSION, "states": CENSUS_STATES, "stale_days": STALE_DAYS,
        "open": len(wanted), "classified": len(out), "read": len(threads), "cached": len(wanted) - len(stale),
        "read_errors": len(errors), "gone": len(gone), "facts_age_min": int((now - int(taken)) / 60) if taken else None,
        # A thread we could not read is not in any state, and it is NOT a zero: it is counted on its own so a
        # partial reading can never be read as a complete one with a lower `none`.
        "unread": len(wanted) - len(out), "complete": len(wanted) == len(out),
        "by_state": by_state, "by_reason": by_reason, "by_state_reason": by_state_reason, "humans_assigned": held,
        "none_by_shape": dict(sorted(by_shape_none.items(), key=lambda kv: -kv[1])[:10]),
        "frustrated_this_hour": sum(frustrated_shapes.values()),
        "frustrated_top": [{"shape": s, "count": n} for s, n in top],
    }


def census_line(doc):
    """The Item D line: `none` first, then the four states, then humans-assigned and the hour's frustration."""
    if doc.get("not_measured_reason"):
        return f"NOT MEASURED: {doc['not_measured_reason']}"
    s = doc["by_state"]
    why = ", ".join(f"{k} {v}" for k, v in sorted(doc["by_state_reason"].get("none", {}).items(), key=lambda kv: -kv[1]))
    top = ", ".join(f"{r['shape']} {r['count']}" for r in doc["frustrated_top"]) or "none"
    unread = doc.get("unread") or 0
    partial = f" | PARTIAL: {unread} unread, in no state" if unread else ""
    # The census reads the monitor's facts, so it is only as fresh as the monitor's last pass. A reading
    # served from an hour-old facts file is not a reading of the last hour, and the line has to say so.
    age = doc.get("facts_age_min")
    fresh = f" | facts {age}m old" if age is not None else ""
    return (f"census {doc['as_of_utc']}: open {doc['open']} ({doc['read']} read, {doc['cached']} cached,"
            f" {doc['read_errors']} read errors) | none {s['none']} ({why}) | answered {s['answered']}"
            f" | decided {s['decided']} | waiting-on-customer {s['waiting_on_customer']} | closed-stale {s['closed_stale']}"
            f" | humans-assigned {doc['humans_assigned']} | frustrated this hour {doc['frustrated_this_hour']}: {top}"
            f"{fresh}{partial}")


def tick(token, now, minutes=30, db_path=FACTS_DB, request=None, register=None, ledger_path=SAFETY_LEDGER):
    since = now - minutes * 60
    cfg = (register or {}).get("monitor") or {}
    non_human = tuple(cfg.get("non_human_admin_ids") or rules.DEFAULT_NON_HUMAN_ADMINS)
    staffed = tuple(cfg.get("staffed_team_ids") or ())
    rows, total = search_touched(token, since, request)
    aging = read_aging(db_path, now)
    touched = [r["id"] for r in rows]
    # A thread can be in both sets (the customer has waited two days and something touched it five minutes
    # ago). It is fetched once and read twice: the window's part for the window, its whole history for the wait.
    aging_ids = list(aging.get("read_ids", []))
    threads, errors, gone = fetch_all(token, touched + [c for c in aging_ids if c not in set(touched)], request)

    def row_of(cid, windowed):
        thread = threads[cid]
        events = rules.read_events(thread, non_human, staffed)
        found = signals_of(thread, events, now, non_human, staffed)
        if windowed:   # a touched thread counts a signal only when the part that shows it is inside the window
            found = {k: ts for k, ts in found.items() if ts >= since or k == "customer_unanswered"}
        kinds = cannot_kinds(thread, since if windowed else 0, non_human) if "caroline_cannot" in found else []
        waited = backlog.waiting_since(events, now)
        return {"id": cid, "shape": rules.classify(thread), "last": last_word(events, now),
                "signals": sorted(found), "cannot": kinds,
                "waiting": bool(waited is not None and now - waited >= AGING_HOURS * HOUR),
                "outbound": (thread.get("source") or {}).get("at") not in rules.CUSTOMER_AUTHOR_TYPES}

    def count(convs):
        out = {name: 0 for name in SIGNALS}
        for c in convs:
            for name in c["signals"]:
                out[name] += 1
        return out

    def count_cannot(convs):
        out = {}
        for c in convs:
            for kind in c["cannot"]:
                out[kind] = out.get(kind, 0) + 1
        return out

    def count_guard_why(convs):
        """{reason: count} over the threads the guard refused, so the pattern table names the cause."""
        out = {}
        for c in convs:
            why = c.get("guard_why")
            if why:
                out[why] = out.get(why, 0) + 1
        return out

    win = [row_of(c, True) for c in touched if c in threads]
    read_old = [row_of(c, False) for c in aging_ids if c in threads]
    # Why the guard refused, for the threads where it did. The conversation cannot say (the customer only saw the
    # fallback line), so the guard's own ledger is read for exactly those ids. A ledger that cannot be read leaves
    # every such row `guard_why: not measured` and the reading says so: an unknown cause is not "no cause".
    guarded = [c["id"] for c in win + read_old if "guard_fallback" in c["signals"]]
    reasons = guard_reasons(guarded, path=ledger_path, now=now) if guarded else {}
    for c in win + read_old:
        if "guard_fallback" in c["signals"]:
            why = reasons.get("not_measured") or reasons.get(c["id"])
            if isinstance(why, list):
                c["guard_why"] = ", ".join(why)
            else:
                c["guard_why"] = f"not measured: {why}" if why else "not measured"
    # The monitor's facts are up to two hours old. A thread they list as waiting that the live read shows
    # answered since is counted apart and is in no signal count: nobody is waiting on it any more.
    old = [c for c in read_old if c["waiting"]]
    for c in win + read_old:
        del c["waiting"]
    by_shape, seen = {}, set()
    for c in old + win:            # a thread in both sets counts once per signal; its whole-history row is first
        for name in c["signals"]:
            if (c["id"], name) not in seen:
                seen.add((c["id"], name))
                by_shape.setdefault(name, {}).setdefault(c["shape"], 0)
                by_shape[name][c["shape"]] += 1
    aging_out = {k: v for k, v in aging.items() if k != "read_ids"}
    if "not_measured" not in aging:
        aging_out.update({"read": len(read_old), "answered_since": len(read_old) - len(old),
                          "by_signal": count(old), "by_cannot": count_cannot(old),
                          "by_guard_why": count_guard_why(old), "conversations": old})
    return {
        "schema": SCHEMA, "as_of": now, "as_of_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(now)),
        "rules": rules.RULES_VERSION, "signals": SIGNALS, "not_measured": NOT_MEASURED,
        "window": {"minutes": minutes, "since": since, "listed": len(rows), "intercom_total_count": total,
                   "short_read": bool(total is not None and len(rows) < total), "read": len(win),
                   "gone": len(gone), "read_errors": len(errors), "struggling": sum(1 for c in win if c["signals"]),
                   "by_signal": count(win), "by_cannot": count_cannot(win),
                   "by_guard_why": count_guard_why(win), "conversations": win},
        "aging": aging_out, "by_signal_shape": by_shape,
    }


def line(doc):
    """The one-line status for a reading. A part that was not measured says so and carries no number."""
    if doc.get("not_measured_reason"):
        return f"NOT MEASURED: {doc['not_measured_reason']}"
    w, a = doc["window"], doc["aging"]
    seen = ", ".join(f"{k} {v}" for k, v in sorted(w["by_signal"].items(), key=lambda kv: -kv[1]) if v) or "none"
    head = (f"read {w['read']} of {w['listed']} conversations touched in {w['minutes']} min"
            f" ({w['read_errors']} read errors{', SHORT READ' if w['short_read'] else ''});"
            f" {w['struggling']} with a struggle signal: {seen}")
    if "not_measured" in a:
        return head + f"; aging over {AGING_HOURS}h: NOT MEASURED ({a['not_measured']})"
    worst = ", ".join(f"{k} {v}" for k, v in sorted(a["by_signal"].items(), key=lambda kv: -kv[1])
                      if v and k != "customer_unanswered") or "none"
    partial = (f" (PARTIAL: {a['not_read_over_limit']} more under {AGING_READ_DAYS} days not read, limit"
               f" {a['read_limit']} a tick)" if a["not_read_over_limit"] else "")
    answered = f", {a['answered_since']} answered since that reading" if a["answered_since"] else ""
    refused = ", ".join(f"{k} {v}" for k, v in sorted(a.get("by_guard_why", {}).items(), key=lambda kv: -kv[1]))
    return head + (f"; customer last over {a['hours']}h: {a['count']} plus {a['robot_mail']} robot mail"
                   f" (monitor's reading, {a['facts_age_min']} min old), {a['read']} of them under {AGING_READ_DAYS}"
                   f" days read{partial}{answered}: {worst}"
                   + (f"; guard refused: {refused}" if refused else ""))


def show(token, cid, request=None):
    kwargs = {"request": request} if request else {}
    thread, err = collect.fetch_thread(token, cid, **kwargs)
    if thread is None:
        return f"could not read {cid}: {err}"
    cfg = (fixloop.load_register() or {}).get("monitor") or {}
    non_human = tuple(cfg.get("non_human_admin_ids") or rules.DEFAULT_NON_HUMAN_ADMINS)
    staffed = tuple(cfg.get("staffed_team_ids") or ())
    events = rules.read_events(thread, non_human, staffed)
    found = signals_of(thread, events, int(time.time()), non_human, staffed)
    head = [f"conversation {cid} shape={rules.classify(thread)} open={thread['open']} tags={','.join(thread['tags'])}",
            f"signals: {', '.join(sorted(found)) or 'none'}"]
    subject = (thread.get("source") or {}).get("subject")
    if subject:
        head.append(f"subject: {subject}")
    names = {WHO_CUSTOMER: "CUSTOMER", WHO_CAROLINE: "CAROLINE", WHO_HUMAN: "PERSON"}
    body = [f"[{time.strftime('%Y-%m-%d %H:%M', time.gmtime(ts))} {names[who]}] {text}"
            for ts, who, text in messages(thread, non_human)]
    return "\n".join(head + body)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    t = sub.add_parser("tick")
    t.add_argument("--minutes", type=int, default=30)
    t.add_argument("--db", default=FACTS_DB)
    t.add_argument("--out", default="", help="also write <out>/latest.json and <out>/ticks/<as_of>.json")
    sub.add_parser("line")
    c = sub.add_parser("census")
    c.add_argument("--db", default=FACTS_DB)
    c.add_argument("--cache", default=CENSUS_CACHE)
    c.add_argument("--workers", type=int, default=collect.WORKERS)
    c.add_argument("--out", default="", help="also write <out>/census-latest.json and <out>/census/<as_of>.json")
    sub.add_parser("census-line")
    s = sub.add_parser("show")
    s.add_argument("conversation")
    args = ap.parse_args(argv)

    if args.cmd == "line":
        print(line(json.load(sys.stdin)))
        return 0
    if args.cmd == "census-line":
        print(census_line(json.load(sys.stdin)))
        return 0
    token = collect.resolve_token()
    now = int(time.time())

    def emit(doc):
        """Print the reading and, with --out, keep it. A reading that could not run is kept too: it carries no
        number, so the newest file never shows an older tick's counts as the current ones."""
        text = json.dumps(doc, sort_keys=True)
        out = getattr(args, "out", "")
        if out:
            ticks = os.path.join(out, "ticks")
            os.makedirs(ticks, exist_ok=True)
            for path in (os.path.join(ticks, f"{now}.json"), os.path.join(out, "latest.json")):
                tmp = path + ".tmp"
                with open(tmp, "w") as f:
                    f.write(text + "\n")
                os.replace(tmp, path)
            for name in os.listdir(ticks):
                stamp = name[:-5] if name.endswith(".json") else ""
                if stamp.isdigit() and int(stamp) < now - KEEP_TICK_DAYS * DAY:
                    os.remove(os.path.join(ticks, name))
        print(text)

    def unmeasured(why):
        emit({"schema": SCHEMA, "as_of": now, "as_of_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(now)),
              "not_measured_reason": why[:300]})
        return 2

    if not token:
        return unmeasured("no Intercom token on this host")
    if args.cmd == "show":
        if not re.fullmatch(r"[0-9]+", args.conversation):
            ap.error("a conversation id is digits")
        print(show(token, args.conversation))
        return 0
    if args.cmd == "census":
        try:
            doc = census(token, now, args.db, args.cache, workers=args.workers)
        except collect.CollectError as exc:
            return unmeasured(f"{type(exc).__name__}: {exc}")
        except Exception as exc:  # noqa: BLE001
            unmeasured(f"census fault: {type(exc).__name__}: {exc}")
            raise
        if doc.get("not_measured_reason"):
            return unmeasured(doc["not_measured_reason"])
        text = json.dumps(doc, sort_keys=True)
        if args.out:
            keep = os.path.join(args.out, "census")
            os.makedirs(keep, exist_ok=True)
            for path in (os.path.join(keep, f"{now}.json"), os.path.join(args.out, "census-latest.json")):
                tmp = path + ".tmp"
                with open(tmp, "w") as f:
                    f.write(text + "\n")
                os.replace(tmp, path)
        print(text)
        return 0
    try:
        doc = tick(token, now, args.minutes, args.db, register=fixloop.load_register())
    except collect.CollectError as exc:      # Intercom could not be read: a recorded NOT MEASURED, exit 2
        return unmeasured(f"{type(exc).__name__}: {exc}")
    except Exception as exc:  # noqa: BLE001
        # Anything else is a fault in this code or in a record it did not expect. The reading is still marked
        # NOT MEASURED, so the newest file never shows an older tick's counts, and then the fault is raised:
        # the unit fails and its pager fires. Exit 2 is kept for "could not read Intercom" alone.
        unmeasured(f"reader fault: {type(exc).__name__}: {exc}")
        raise
    emit(doc)
    return 0


if __name__ == "__main__":
    sys.exit(main())
