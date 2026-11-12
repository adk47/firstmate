#!/usr/bin/env python3
"""Daily: Caroline's resolution rate, and how many customers are still waiting.

READ-ONLY on Intercom (`POST /conversations/search`, `GET /conversations/{id}`) and on the safety
ledger. It sends nothing to a customer, closes nothing, tags nothing and calls no model. Its only
outputs are one line of text, one JSON record of COUNTS (no customer text, no contact id), and an
exit code. The wrapper `scripts/support-resolution-daily.sh` posts the line to #clio_devops.

Two numbers, and what each one means (ai-support-quality-v1, captain 2026-11-12):

  resolution rate   Of the conversations where a customer wrote in the window, the share Caroline
                    answered with nothing left waiting. A conversation is NOT resolved when, from
                    the customer's first message in the window onward:
                      - nobody replied, or the customer's last message has no reply;
                      - she said a person is coming (assigned or not), or a person was assigned;
                      - she, or any sender posting as her, parked it on a queue or holding line
                        ("it is with the verification team", "your message is here and it will
                        be read");
                      - the output guard replaced her reply with the fallback line;
                      - she refused;
                      - an EARLIER promise of a person is still open (no person assigned, no
                        person replied), whatever she said today; or
                      - a person replied. The rate is hers: a conversation a person answered,
                        alone or after her, is counted as `answered_by_person`, which is
                        neither her resolution nor a customer waiting. A person's reply settles
                        what came before it (her queue line, her promise, the fallback line),
                        so such a conversation is waiting again only if, AFTER that reply, the
                        customer wrote or she parked it once more.
                    Her own later answer settles less than a person's does. Her LATEST answer
                    decides whether a queue line, a refusal or the fallback line still stands:
                    one she has since followed with an answer is not what the customer was left
                    with. A bare courtesy ("you're welcome") is a reply but not an answer, and
                    decides nothing. A promise of a person is settled only by a person, and
                    while one is open nothing she says later settles anything.
                    Closing a conversation does not make it resolved: `state` is never read.

  still waiting     Two counts, never added together:
                      - of the window's conversations, every one that is neither resolved by
                        her nor answered by a person;
                      - across the whole open inbox, conversations whose last message is the
                        customer's (Intercom `waiting_since`), by how long they have waited.

The rule set (the phrases that count as a promise of a person, a queue or holding line, a refusal)
reads the 2026-11-12 baseline as 63 resolved of 417, 15.1 percent (BASELINE below; pinned on
every rule change by re-reading that window). The captain's brief and
data/ai-support-quality-v1/report.md say 58, 13.9 percent: that was the read up to rules .4, which
kept 5 conversations waiting on a queue line she had since followed with an answer. Nothing about
the inbox changed between the two, only the count. It follows scripts/caroline_monitor/rules.py of lane
caroline-monitor-and-fixloop-k2. Changing a phrase changes the number, so RULES_VERSION is in
every record and a record read under another version is never compared with this one.

"Could not read" is never a zero. A search that fails, or more than UNREAD_LIMIT of the window's
conversations failing to load, is UNMEASURED: exit 3, no rate printed. An unreadable ledger leaves
the Intercom numbers standing and prints the guard counts as "not read".
"""
import argparse
import calendar
import concurrent.futures
import html
import json
import os
import re
import sys
import time
import urllib.error
import urllib.request

RULES_VERSION = "asq-2026-11-12.5"
INTERCOM_API = "https://api.intercom.io"
INTERCOM_VERSION = "2.11"
TOKEN_ENV = "MUSOAI_INTERCOM_TOKEN"
TOKEN_ENV_FILES = ("/etc/openclaw/edge.env", "/etc/openclaw/shared.env")
LEDGER_PATH = "/var/lib/hydra/injection-watch/ledger.jsonl"
STATE_DIR = "/var/lib/hydra/support-resolution"
PER_PAGE = 150
WORKERS = 4
UNREAD_LIMIT = 0.02  # share of the window's conversations that may fail to load
HOUR = 3600
DAY = 86400

CAROLINE_ADMIN_ID = "5763097"
OPERATOR_BOT_ID = "4359478"
NON_HUMAN_ADMINS = frozenset((CAROLINE_ADMIN_ID, OPERATOR_BOT_ID, "", "0", "None"))
CUSTOMER_AUTHOR_TYPES = ("user", "lead", "contact")
REPLY_PART_TYPES = ("comment", "open", "assignment", "assign_and_reopen", "close")

# The line the plugin posts when the output guard refuses a reply and the retry did not produce a
# usable one (plugins/intercom/src/answer-bank.ts AI_QUEUE_FALLBACK). Pinned equal by the test.
FALLBACK_LINE = "i want to get this right for you. could you tell me a little more about what you need help with?"

_WS = re.compile(r"\s+")
# Typographic characters to their plain form, keyed by code point: curly single and double quotes,
# en and em dash, zero-width space. Written as numbers on purpose: a file that talks to Intercom
# carries no escaped string literal (scripts/check-intercom-reply-identity.sh).
_PLAIN = {0x2019: "'", 0x2018: "'", 0x201C: '"', 0x201D: '"', 0x2013: "-", 0x2014: "-", 0x200B: " "}


def norm(text):
    """Lowercased, entity-decoded, straight-quoted, single-spaced text."""
    text = html.unescape(text or "").translate(_PLAIN)
    return _WS.sub(" ", text).strip().lower()


def _rx(pattern):
    return re.compile(pattern, re.I)


# A BARE COURTESY: a short reply that only acknowledges thanks. It is a reply, so the customer is
# not left unanswered, but it is not an answer: it never settles a queue line, a refusal or the
# fallback line that came before it. A closed list on purpose. A courtesy in a wording that is not
# here reads as an answer, which errs toward "resolved"; add the wording and bump RULES_VERSION.
COURTESY_MAX_CHARS = 80
COURTESY = _rx(
    r"^\W*(?:you're (?:very |most )?welcome|you are (?:very |most )?welcome|anytime|any time|you got it"
    r"|my pleasure|happy to help|glad (?:i|we) could help|no problem|of course"
    r"|con (?:mucho )?gusto|de nada|di nulla|prego|gern geschehen|gerne|je vous en prie|avec plaisir|de rien)\b"
)


# A PROMISE OF A PERSON: she says a person or "the team" will take this over or come back.
PERSON_PROMISE = _rx(
    r"pulling in a teammate|\bteammate (will|to|is)\b|\bloop(ing)? in\b[^.]{0,30}\b(team|teammate|colleague)"
    r"|\b(they|our team|the team|someone|a teammate|a specialist|a colleague|a member of (our|the) team|our (support|verification|catalog|billing) team)"
    r"('ll| will) (follow up|review|take|be in touch|get back|reach out|look into|contact|respond|reply|help|handle|check|investigate)"
    r"|\b(flagged|passed|forwarded|escalated|sent|handed|routed|raised)\b (it|this|that|them|your\b[^.]{0,80}?|the\b[^.]{0,80}?)\s*\b(for|to|with|over to) (our|the) (\w+ )?team\b"
    r"|\bi('ve| have) (flagged|escalated|raised) (your|the|this|that|it|them)\b"
    r"|\bi('ve| have) submitted (your|the|a)\b[^.]{0,60}\brequest\b|\bto your existing request so (that )?(our|the) team\b"
    r"|\bso (that )?(our|the) team can\b|\byou'll hear from (us|the team|our team)\b"
    r"|\bte responderemos\b|\b(a|con) (nuestro|el) equipo\b|\bj'ai (signalé|transmis)\b|\b(à|a) notre équipe\b"
    r"|\bfor a priority look\b|\bgets to the team\b|\bi'll pass (it|this|that|them|those) on\b"
    r"|\bhear back within\b|\bresponse within\b|\bfor manual review\b|\bteam will (see|take|pick)\b"
    r"|\bleave the review with the team\b|\bte responder[aá]n\b|\bun compa[ñn]ero\b|\bnuestro equipo (te|lo|la|va)\b"
    r"|\bwe('ll| will) follow up (here|right here|with you)\b|\bfollow up right here\b"
)
# The merge paragraph's conditional is an explanation, not a promise about this conversation.
PERSON_PROMISE_EXCLUDE = _rx(r"are handled differently: i'll pass those on")
# A QUEUE LINE: it is with the team or in a queue, with no person named.
QUEUE_LINE = _rx(
    r"goes to the verification team|in the verification queue|review in the order requests arrive"
    r"|will email you when yours has been reviewed|we'll message you here as soon as|we are continuing to review"
    r"|we will follow up here once|we'll be in touch|we'll update you|the outcome comes to this conversation"
    # Holding messages. On 2026-11-12 02Z another sender posted 190 of these as Caroline to
    # conversations nobody had answered ("your message is here and it will be read"). They are
    # honest, and they are not answers: under rules .1 they read as 38 resolutions in one hour.
    r"|\bit will be read\b|\bwe will write to you here\b|\bqueued for review\b|\bit is with the team\b"
    r"|\bwe will tell you what we (find|need)\b|\bwe are checking it\b|\bte escribiremos (aqu[ií]|por aqu[ií])\b"
)
# A REFUSAL with a way back. Not a hand-off, and not resolved either.
REFUSAL_LINE = _rx(
    r"a request is closed when the supporting information|you can submit it again with your supporting documents"
    r"|i can't (see|share|tell you)\b[^.]{0,80}\b(review|how|why|where|source|who)|i can't (give|offer) (you )?(legal|a legal)"
    r"|i can't (promise|guarantee|give you|commit to)\b[^.!?]{0,60}\b(date|time|timeline|timeframe|by|within|when)\b"
    r"|that's not something i can (share|confirm|speak to)"
    r"|once a page is hidden it stays hidden"
)

EV_CUSTOMER, EV_CAROLINE, EV_HUMAN_REPLY = "c", "a", "h"
EV_PROMISE, EV_QUEUE, EV_REFUSAL, EV_HUMAN_ASSIGNED, EV_FALLBACK = "p", "q", "r", "A", "f"
EV_COURTESY = "k"   # her reply is only "you're welcome": it answers nothing and settles nothing
REPLY_MARKS = (EV_FALLBACK, EV_PROMISE, EV_QUEUE, EV_REFUSAL, EV_COURTESY)
# The ledger row and the line that replaced her reply are written by two clocks, seconds apart
# (0 to 1 s on the 60 refusals of the baseline window). Only a reply later than this is a new one.
REFUSAL_GRACE_SECONDS = 120
# The frozen 24h window to 2026-11-12T00:45Z, read under RULES_VERSION: (resolved, conversations).
BASELINE = (63, 417)
BASELINE_FIRST_READ = 58   # the same window under rules .1 to .4, and the number in the brief

# Every conversation in the window lands in exactly one of these; they sum to the cohort.
OUTCOMES = (
    "resolved",                  # CAROLINE answered, no person had to, nothing left waiting, no promise open
    "answered_by_person",        # a person's reply stands as the answer: not hers, and not waiting
    "no_reply",                  # nobody has answered the customer's message(s) in the window
    "customer_wrote_again",      # answered, then the customer wrote and has no reply
    "person_promised_unassigned",  # told a person is coming; nobody was assigned
    "person_promised_assigned",  # told a person is coming; a person was assigned
    "assigned_untold",           # a person was assigned, the customer was not told
    "queue_line",                # parked on "it is with the team"
    "guard_fallback",            # the output guard refused her reply; the fallback line went out
    "refused",                   # refused with a way back
    "earlier_promise_open",      # answered today, but an earlier promise of a person is still open
)


class Unmeasured(RuntimeError):
    """The measurement could not be taken. Never rendered as a number."""


def read_events(thread):
    """The conversation as a time-ordered list of (timestamp, code). No clock, no judgement."""
    created = int(thread.get("created_at") or 0)
    events = []
    if (thread.get("source") or {}).get("at") in CUSTOMER_AUTHOR_TYPES:
        events.append((created, EV_CUSTOMER))
    saw_human_assignment = False
    for part in thread.get("parts") or []:
        kind, author_type = part.get("t"), part.get("at")
        author_id = str(part.get("aid") or "")
        body = (part.get("body") or "").strip()
        ts = int(part.get("ts") or created)
        target = part.get("asg")
        if target and target.get("type") == "admin" and str(target.get("id") or "") not in NON_HUMAN_ADMINS:
            events.append((ts, EV_HUMAN_ASSIGNED))
            saw_human_assignment = True
        if author_type in CUSTOMER_AUTHOR_TYPES:
            if kind == "comment" and (body or part.get("att")):
                events.append((ts, EV_CUSTOMER))
            continue
        if author_type != "admin" or kind not in REPLY_PART_TYPES or not body:
            continue  # notes are internal; automation parts are not a reply
        if author_id == CAROLINE_ADMIN_ID:
            events.append((ts, EV_CAROLINE))
            text = norm(body)
            if text == FALLBACK_LINE:
                events.append((ts, EV_FALLBACK))
            if PERSON_PROMISE.search(PERSON_PROMISE_EXCLUDE.sub(" ", text)):
                events.append((ts, EV_PROMISE))
            if QUEUE_LINE.search(text):
                events.append((ts, EV_QUEUE))
            if REFUSAL_LINE.search(text):
                events.append((ts, EV_REFUSAL))
            if events[-1][1] == EV_CAROLINE and len(text) <= COURTESY_MAX_CHARS and COURTESY.search(text):
                events.append((ts, EV_COURTESY))   # only when the reply carries no other mark
        elif author_id not in NON_HUMAN_ADMINS:
            events.append((ts, EV_HUMAN_REPLY))
    if str(thread.get("admin_assignee_id") or "") not in NON_HUMAN_ADMINS and not saw_human_assignment:
        # Dated late on purpose: an assignment we cannot date never covers a promise early.
        events.append((int(thread.get("updated_at") or created), EV_HUMAN_ASSIGNED))
    events.sort(key=lambda e: e[0])
    return events


def _flags(events):
    seen = {code for _, code in events}
    last = None
    for _, code in events:
        if code in (EV_CUSTOMER, EV_CAROLINE, EV_HUMAN_REPLY):
            last = code
    return seen, last


def _her_replies(events):
    """Her replies in order, each as (timestamp, the marks read_events put on that reply)."""
    replies = []
    for ts, code in events:
        if code == EV_CAROLINE:
            replies.append((ts, set()))
        elif code in REPLY_MARKS and replies and replies[-1][0] == ts:
            replies[-1][1].add(code)
    return replies


def outcome(thread, start, end, refused_at=None):
    """One of OUTCOMES, or None when the customer did not write in [start, end).

    `refused_at` is when the output guard last refused a reply of hers in this conversation (the
    safety ledger's timestamp), or None.
    """
    events = [e for e in read_events(thread) if e[0] <= end]   # later events have not happened yet
    in_window = [ts for ts, code in events if code == EV_CUSTOMER and start <= ts < end]
    if not in_window:
        return None
    whole, _ = _flags(events)
    since_events = [e for e in events if e[0] >= min(in_window)]
    since, last = _flags(since_events)
    person = EV_HUMAN_REPLY in since
    # A person's reply settles everything before it: her queue line, her promise of a person, the
    # guard's fallback line. What can still leave the customer waiting is only what came AFTER the
    # person's last reply, so the waiting rules below read that tail and nothing earlier.
    tail = since_events
    if person:
        cut = max(i for i, (_, code) in enumerate(since_events) if code == EV_HUMAN_REPLY)
        if refused_at is not None and refused_at <= since_events[cut][0]:
            refused_at = None   # the person answered after the guard's refusal
        tail = since_events[cut + 1:]
    after, _ = _flags(tail)
    replies = _her_replies(tail)
    # A promise of a person is settled only by a person. While one is open nothing she says later
    # settles anything, so every mark in the tail still stands.
    promised = EV_PROMISE in after
    if promised:
        standing = set(after)
        if refused_at is not None:
            standing.add(EV_FALLBACK)
    else:
        # Otherwise her LATEST answer decides. A queue line, a refusal or the fallback line that
        # she has since followed with an answer is no longer what the customer is left with. A
        # bare courtesy is not an answer and decides nothing.
        answers = [reply for reply in replies if EV_COURTESY not in reply[1]]
        standing = set(answers[-1][1]) if answers else set()
        if refused_at is not None and not (answers and answers[-1][0] > refused_at + REFUSAL_GRACE_SECONDS):
            standing.add(EV_FALLBACK)
    if person and not (EV_CUSTOMER in after or promised or standing & {EV_FALLBACK, EV_QUEUE}):
        return "answered_by_person"   # the person's reply stands: the customer is not waiting
    if EV_FALLBACK in standing:
        return "guard_fallback"
    if promised:
        # An assignment made before the person replied still holds the conversation.
        return "person_promised_assigned" if EV_HUMAN_ASSIGNED in since else "person_promised_unassigned"
    if EV_HUMAN_ASSIGNED in after:
        return "assigned_untold"
    if EV_QUEUE in standing:
        return "queue_line"
    if not (EV_CAROLINE in since or person):
        return "no_reply"
    if EV_REFUSAL in standing:
        return "refused"
    if last == EV_CUSTOMER:
        return "customer_wrote_again"
    if EV_PROMISE in whole and EV_HUMAN_ASSIGNED not in whole and EV_HUMAN_REPLY not in whole:
        return "earlier_promise_open"
    # The rate is Caroline's. Reaching here with a person's reply in the thread means the customer
    # wrote again after it and she then answered: not waiting, and not counted as hers.
    if person:
        return "answered_by_person"
    return "resolved"


def measure(threads, start, end, guard_refused_at=None):
    """`guard_refused_at` maps a conversation id to when the guard last refused her reply in it."""
    refused = guard_refused_at or {}
    counts = {name: 0 for name in OUTCOMES}
    for thread in threads:
        got = outcome(thread, start, end, refused.get(str(thread.get("id"))))
        if got is not None:
            counts[got] += 1
    cohort = sum(counts.values())
    return {
        "cohort": cohort,
        "outcomes": counts,
        "resolved": counts["resolved"],
        "resolution_rate": round(counts["resolved"] / cohort, 4) if cohort else None,
        "answered_by_person": counts["answered_by_person"],
        "not_resolved": cohort - counts["resolved"],
        # Waiting on us: everything that is neither her resolution nor a person's answer.
        "still_waiting": cohort - counts["resolved"] - counts["answered_by_person"],
    }


# ---------------------------------------------------------------------------------------------
# The safety ledger: what the guard did in the window. Counts only.
# ---------------------------------------------------------------------------------------------
def read_guard(ledger_path, start, end):
    """Counts from the live ledger file and its sealed generations, or None when unreadable."""
    directory, base = os.path.split(ledger_path)
    try:
        names = [n for n in os.listdir(directory) if n == base or n.startswith(base + ".sealed-")]
    except OSError:
        return None
    if base not in names:
        return None
    lo = time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(start))
    hi = time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(end))
    out = {"refused_final": 0, "retry_pending": 0, "retry_passed": 0, "retry_unusable": 0,
           "handoff_stripped": 0, "handoff_only": 0, "refused_at": {}, "by_rule": {}}
    for name in names:
        try:
            with open(os.path.join(directory, name), encoding="utf-8", errors="replace") as fh:
                for line in fh:
                    try:
                        row = json.loads(line)
                    except ValueError:
                        continue
                    ts = str(row.get("ts") or "")[:19]
                    if not (lo <= ts < hi):
                        continue
                    kind = row.get("kind")
                    if kind == "output_guard" and row.get("enforced", True):
                        out["refused_final"] += 1
                        ref = str(row.get("ref"))
                        try:
                            at = calendar.timegm(time.strptime(ts, "%Y-%m-%dT%H:%M:%S"))
                        except ValueError:
                            at = end   # undated: no later reply of hers can be read as settling it
                        out["refused_at"][ref] = max(at, out["refused_at"].get(ref, 0))
                        # The plugin writes flags as {family, rule, excerpt}. Only the two names are
                        # read: the excerpt is a piece of her reply and never leaves the ledger.
                        for flag in row.get("flags") or []:
                            if not isinstance(flag, dict) or flag.get("family") in (None, "note"):
                                continue
                            rule = f"{flag.get('family')}/{flag.get('rule')}"
                            out["by_rule"][rule] = out["by_rule"].get(rule, 0) + 1
                    elif kind == "output_guard_retry":
                        key = {"pending": "retry_pending", "passed": "retry_passed",
                               "unusable": "retry_unusable"}.get(row.get("outcome"))
                        if key:
                            out[key] += 1
                    elif kind == "unbacked_handoff":
                        out["handoff_stripped" if row.get("action") == "stripped" else "handoff_only"] += 1
        except OSError:
            return None
    return out


# ---------------------------------------------------------------------------------------------
# Intercom, read-only.
# ---------------------------------------------------------------------------------------------
def resolve_token(env=None, files=TOKEN_ENV_FILES):
    env = os.environ if env is None else env
    if env.get(TOKEN_ENV):
        return env[TOKEN_ENV]
    for path in files:
        try:
            with open(path, encoding="utf-8") as fh:
                for line in fh:
                    if line.startswith(TOKEN_ENV + "="):
                        return line.split("=", 1)[1].strip().strip('"').strip("'")
        except OSError:
            continue
    raise Unmeasured("no Intercom token")


def _request(method, path, token, body=None, attempts=5):
    if method not in ("GET", "POST") or (method == "POST" and path != "/conversations/search"):
        raise ValueError("this reader only searches and reads")  # read-only by construction
    data = json.dumps(body).encode() if body is not None else None
    last = None
    for attempt in range(attempts):
        req = urllib.request.Request(
            INTERCOM_API + path, data=data, method=method,
            headers={"Authorization": f"Bearer {token}", "Accept": "application/json",
                     "Content-Type": "application/json", "Intercom-Version": INTERCOM_VERSION})
        try:
            with urllib.request.urlopen(req, timeout=60) as resp:
                return json.load(resp)
        except urllib.error.HTTPError as e:
            last = e
            if e.code == 429:
                wait = 5.0
            elif 500 <= e.code < 600:
                wait = 2.0 * (attempt + 1)
            else:
                raise
        except (urllib.error.URLError, OSError, ValueError) as e:
            last = e
            wait = 2.0 * (attempt + 1)
        time.sleep(wait)
    raise last


def _search(token, query, request):
    """Every conversation matching `query`, oldest first. Raises Unmeasured on any gap."""
    found, cursor, total = {}, None, None
    while True:
        page = {"per_page": PER_PAGE}
        if cursor:
            page["starting_after"] = cursor
        try:
            res = request("POST", "/conversations/search", token,
                          {"query": query, "pagination": page, "sort": {"field": "created_at", "order": "ascending"}})
        except (urllib.error.URLError, OSError, ValueError) as e:
            raise Unmeasured(f"search failed: {type(e).__name__}") from e
        total = res.get("total_count") if total is None else total
        for conv in res.get("conversations") or []:
            found[str(conv.get("id"))] = conv
        cursor = (((res.get("pages") or {}).get("next")) or {}).get("starting_after")
        if not cursor:
            break
    if total is not None and len(found) < int(total) * (1 - UNREAD_LIMIT):
        raise Unmeasured(f"search returned {len(found)} of {total}")
    return found


def _f(field, op, value):
    return {"field": field, "operator": op, "value": value}


def reduce_thread(detail):
    """What the reader needs from one conversation. Bodies stay in memory and are never written."""
    def author(obj):
        a = obj.get("author") or {}
        return a.get("type") or "", str(a.get("id") or "")
    parts = []
    for p in ((detail.get("conversation_parts") or {}).get("conversation_parts")) or []:
        kind, aid = author(p)
        asg = p.get("assigned_to")
        parts.append({"t": p.get("part_type") or "", "at": kind, "aid": aid if kind != "user" else "",
                      "ts": int(p.get("created_at") or 0), "body": p.get("body") or "",
                      "att": len(p.get("attachments") or []),
                      "asg": {"type": asg.get("type") or "", "id": str(asg.get("id") or "")}
                      if isinstance(asg, dict) else None})
    skind, _ = author(detail.get("source") or {})
    return {"id": str(detail.get("id")), "created_at": int(detail.get("created_at") or 0),
            "updated_at": int(detail.get("updated_at") or 0),
            "admin_assignee_id": str(detail.get("admin_assignee_id") or ""),
            "source": {"at": skind}, "parts": parts}


def collect(token, start, request=_request, workers=WORKERS):
    """(threads, unread). The window's candidates: the customer wrote, or it was opened, since `start`."""
    listed = _search(token, {"operator": "OR", "value": [
        _f("statistics.last_contact_reply_at", ">", start - 1), _f("created_at", ">", start - 1)]}, request)

    def fetch(cid):
        try:
            return reduce_thread(request("GET", f"/conversations/{cid}?display_as=plaintext", token))
        except urllib.error.HTTPError as e:
            return None if e.code == 404 else e   # a deleted conversation is not a read failure
        except (urllib.error.URLError, OSError, ValueError) as e:
            return e

    threads, unread = [], 0
    with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as pool:
        for got in pool.map(fetch, sorted(listed)):
            if isinstance(got, Exception):
                unread += 1
            elif got is not None:
                threads.append(got)
    if listed and unread > len(listed) * UNREAD_LIMIT:
        raise Unmeasured(f"{unread} of {len(listed)} conversations could not be read")
    return threads, unread


WAIT_BUCKETS = (("under_6h", 6 * HOUR), ("6h_to_24h", DAY), ("1d_to_7d", 7 * DAY), ("over_7d", None))


def inbox_waiting(token, now, request=_request):
    """Open conversations whose last message is the customer's, by wait. From the search pages only."""
    listed = _search(token, {"operator": "AND", "value": [_f("open", "=", True), _f("waiting_since", ">", 0)]}, request)
    out = {name: 0 for name, _ in WAIT_BUCKETS}
    for conv in listed.values():
        waited = now - int(conv.get("waiting_since") or now)
        for name, limit in WAIT_BUCKETS:
            if limit is None or waited < limit:
                out[name] += 1
                break
    out["total"] = len(listed)
    return out


# ---------------------------------------------------------------------------------------------
def render(record):
    m, w, g = record["window"], record.get("inbox_waiting"), record.get("guard")
    o = m["outcomes"]
    rate = "no conversations" if m["resolution_rate"] is None else f"{100 * m['resolution_rate']:.1f}%"
    lines = [
        f"Caroline, last {record['hours']}h to {record['until']}: resolved {m['resolved']} of {m['cohort']} ({rate}). "
        f"Three buckets that add up to {m['cohort']}: resolved by Caroline {m['resolved']}, "
        f"answered by a person {m['answered_by_person']}, waiting on us {m['still_waiting']}"
        f" (no reply {o['no_reply']}, wrote again {o['customer_wrote_again']}, on a queue line {o['queue_line']}, "
        f"promised a person {o['person_promised_unassigned']} unassigned + {o['person_promised_assigned']} assigned, "
        f"assigned untold {o['assigned_untold']}, guard fallback {o['guard_fallback']}, refused {o['refused']}, "
        f"earlier promise open {o['earlier_promise_open']})."
    ]
    if w is None:
        lines.append("Whole inbox, customer wrote last: NOT READ.")
    else:
        lines.append(
            f"Whole inbox, customer wrote last and nobody has replied: {w['total']} "
            f"(under 6h {w['under_6h']}, 6h to 24h {w['6h_to_24h']}, 1 to 7 days {w['1d_to_7d']}, over 7 days {w['over_7d']}).")
    if g is None:
        lines.append("Output guard: ledger NOT READ, so refusals and retries are not counted here.")
    else:
        lines.append(
            f"Output guard: {g['retry_pending']} refusal(s) explained to her, {g['retry_passed']} corrected on retry, "
            f"{g['retry_unusable']} retry unusable, {g['refused_final']} ended on the fallback line; "
            f"person-promise removed from {g['handoff_stripped']} repl(ies), {g['handoff_only']} were only the promise.")
    if record.get("unread"):
        lines.append(f"{record['unread']} conversation(s) could not be read and are in neither number.")
    lines.append(
        f"Baseline 2026-11-12 under these rules: {BASELINE[0]} of {BASELINE[1]} ({BASELINE[0] / BASELINE[1]:.1%}); "
        f"it read {BASELINE_FIRST_READ} before an answer after a queue line counted. Rules {record['rules']}.")
    return "\n".join(lines)


def build(threads, start, end, hours, guard, waiting, unread=0):
    g = None
    if guard is not None:
        g = {k: v for k, v in guard.items() if k != "refused_at"}
    return {
        "rules": RULES_VERSION, "hours": hours,
        "until": time.strftime("%Y-%m-%dT%H:%MZ", time.gmtime(end)),
        "window": measure(threads, start, end, guard["refused_at"] if guard else None),
        "inbox_waiting": waiting, "guard": g, "unread": unread,
    }


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--hours", type=int, default=24)
    ap.add_argument("--until", type=int, default=None, help="window end, epoch seconds (default: now)")
    ap.add_argument("--corpus", help="read conversations from a JSONL file instead of Intercom (offline)")
    ap.add_argument("--ledger", default=LEDGER_PATH)
    ap.add_argument("--no-ledger", action="store_true", help="do not read the safety ledger")
    ap.add_argument("--state-dir", default=None, help=f"write the day's record here (live default: {STATE_DIR})")
    ap.add_argument("--no-record", action="store_true", help="print only; write no day record (a dry run)")
    ap.add_argument("--json", action="store_true", help="print the record instead of the text")
    args = ap.parse_args(argv)
    end = args.until or int(time.time())
    start = end - args.hours * HOUR
    try:
        guard = None if args.no_ledger else read_guard(args.ledger, start, end)
        if args.corpus:
            with open(args.corpus, encoding="utf-8") as fh:
                threads = [t for t in (json.loads(line) for line in fh if line.strip()) if "id" in t]
            waiting, unread = None, 0
        else:
            token = resolve_token()
            threads, unread = collect(token, start)
            waiting = inbox_waiting(token, end)
    except Unmeasured as e:
        print(f"Caroline resolution daily: UNMEASURED ({e}). No rate is reported for this run.")
        return 3
    record = build(threads, start, end, args.hours, guard, waiting, unread)
    state_dir = args.state_dir or (None if args.corpus else STATE_DIR)
    if state_dir and not args.no_record:
        os.makedirs(state_dir, mode=0o700, exist_ok=True)
        path = os.path.join(state_dir, time.strftime("%Y-%m-%d", time.gmtime(end)) + ".json")
        with open(path + ".tmp", "w", encoding="utf-8") as fh:
            json.dump(record, fh, sort_keys=True)
        os.replace(path + ".tmp", path)
    print(json.dumps(record, sort_keys=True) if args.json else render(record))
    return 0


if __name__ == "__main__":
    sys.exit(main())
