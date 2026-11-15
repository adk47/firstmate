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

It reads Intercom (search and GET only) and the monitor's own facts file, read-only. It sends nothing, assigns
nothing and writes nothing outside `--out`. Its output carries conversation ids and signal names, never message
text; `show` prints one masked thread to the terminal for a person or an agent to read, and stores nothing.

    caroline_coach.py tick [--minutes 30] [--out DIR]     one reading, as JSON on stdout (and kept under DIR)
    caroline_coach.py line  < tick.json                   the one-line status for that reading
    caroline_coach.py show <conversation id>              one masked thread, to read

Exit: 0 read · 2 could not read Intercom (the reading is NOT MEASURED, and says so; it never prints zeros).
Any other exit is a fault in this reader or a record it did not expect: the reading is marked NOT MEASURED
too, and the run fails so the unit's pager fires. Exit 2 is never used for that.
"""
from __future__ import annotations

import argparse
import concurrent.futures
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


def tick(token, now, minutes=30, db_path=FACTS_DB, request=None, register=None):
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

    win = [row_of(c, True) for c in touched if c in threads]
    read_old = [row_of(c, False) for c in aging_ids if c in threads]
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
                          "by_signal": count(old), "by_cannot": count_cannot(old), "conversations": old})
    return {
        "schema": SCHEMA, "as_of": now, "as_of_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(now)),
        "rules": rules.RULES_VERSION, "signals": SIGNALS, "not_measured": NOT_MEASURED,
        "window": {"minutes": minutes, "since": since, "listed": len(rows), "intercom_total_count": total,
                   "short_read": bool(total is not None and len(rows) < total), "read": len(win),
                   "gone": len(gone), "read_errors": len(errors), "struggling": sum(1 for c in win if c["signals"]),
                   "by_signal": count(win), "by_cannot": count_cannot(win), "conversations": win},
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
    return head + (f"; customer last over {a['hours']}h: {a['count']} plus {a['robot_mail']} robot mail"
                   f" (monitor's reading, {a['facts_age_min']} min old), {a['read']} of them under {AGING_READ_DAYS}"
                   f" days read{partial}{answered}: {worst}")


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
    s = sub.add_parser("show")
    s.add_argument("conversation")
    args = ap.parse_args(argv)

    if args.cmd == "line":
        print(line(json.load(sys.stdin)))
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
