#!/usr/bin/env python3
"""Intercom unanswered-reply watchdog -> #cs_priority. Deterministic: no LLM. READ-ONLY on
Intercom and the replica: it never replies, tags, assigns, snoozes or closes anything.

Born 2026-11-11 (captain: "can you assure these are not slipping through the cracks").
Conversation 215476618428402: a customer on two paid subscriptions answered Caroline's
question AND asked a status question; Caroline answered twice with "I'm pulling in a
teammate", and no human had written in that thread for 13 days. Nothing paged, because the
backlog count (scripts/intercom-backlog/count.py) is a number in a file and Caroline's reply
made the thread look answered.

THE CLASS (per open or snoozed conversation, decided by reading the thread, never from
`statistics.last_admin_reply_at` alone, which neither sees a robot auto-reply as a non-message
nor a bot's "a teammate will follow up" as a non-answer):
  customer_last    the customer's latest real message has no reply after it (robot mail is
                   not a message; a thanks-only / noise final message is `not_owed`: counted,
                   never paged);
  handoff_chased   Caroline told the customer a person or team would follow up (PROMISE_RE),
                   no HUMAN admin has replied since, the customer has written again (more
                   than a thank-you), and the thread still ENDS on such a promise. Asked
                   twice, told "a teammate" twice: the shape of the thread above. The clock
                   runs from the FIRST unkept promise;
  promise_open     any other unkept promise (the customer has not chased it, or Caroline has
                   said something else since). Counted in every page, not listed line by line:
                   it was 1,488 paid threads on the day this was written, and a list that long
                   is a report nobody reads.
Only a HUMAN admin reply (any admin except Caroline) ends a promise episode; any reply ends a
customer_last one, and a reply part carrying only an attachment is still a reply.

PAID vs FREE: the one house list, /var/lib/credit-trust/paying-users.json, read through
credit_review.decide.paying_users() (missing / malformed / older than 3 h = UNKNOWN, never
"free"; likewise, when some paying accounts could not be mapped to an Intercom identity this
tick, a thread that did not match is UNKNOWN, never "free"). A conversation is paid when a
paying account matches, in this order:
  contact         a contact's Intercom external_id = the account's professional id or Auth0 id
  sender_email    the address that opened the conversation = the account's email
  mentioned_email an address the customer typed in the thread = the account's email
`mentioned_email` exists because people write from a different address than the one they
paid with (the thread above did). It only ever RAISES a page's priority; it is not identity
and nothing may write on it. Emails are held as sha256 only.

N = 24 h (THRESHOLD_H). Caroline answers in about a minute, so a thread still in the class
after an hour is already one she could not or did not answer; what is left to wait for is a
person, and 24 h gives every timezone one working day. It is also the paid SLA the credit
decider already uses (decide.PAID_SLA). Longer and a paying customer waits days before anyone
is told; shorter and overnight threads page before anyone could have read them.

THE PAGE (one Slack message per tick, only when something is due): paid first, a thread not
yet paged before a repeat, oldest wait first, each with its wait, class, paid basis and link. Listed: paid customer_last and
handoff_chased threads, once when they pass N and again every REPAGE_H while unanswered; and
free customer_last and handoff_chased threads, once and then every FREE_LIST_DAYS, a broken
promise ahead of silence. At most
MAX_LINES per message; the rest are listed on the next tick. Threads waiting longer than
LIST_MAX_DAYS are the old backlog: always in the count, never listed. Every message ends with
the whole class count (paid / free / unverified, each class). When nothing is listable but
any thread is still owed, the count alone is posted once every COUNT_EVERY_H: the number
is in front of a person at least daily while it is not zero, and never only in a file. A
degraded paying split rides that same count page (at most once per COUNT_EVERY_H), because
it is warned rather than failed: it never makes the tick exit non-zero.

CLOSED IS NOT ANSWERED: a thread that was in the class last tick and is no longer open is
re-read. Still unanswered => it is reported as "closed without an answer" in the same page.
Closing a thread must never be the way this count falls (317 were closed that way on
2026-10-21).

"Could not read" is a third state: an unreadable thread (a 404 included) keeps its previous
verdict (never treated as answered), is counted as `unread`, and the tick exits non-zero. A
thread that left the open set and could not be re-read keeps that cached verdict in the
published count (`unresolved_left`, `complete: false`) until the re-read succeeds, so a failed
read never lowers the number or invents a zero.

State (one file, /var/lib/intercom-unanswered-reply-watchdog/state.json): the per-thread
verdict cache keyed by updated_at (so a tick re-reads only what changed), the page record,
and the paying accounts' identity keys. `latest.json` beside it is the PII-free count.

Usage:
  python3 scripts/intercom-unanswered-reply-watchdog.py            # live tick (systemd timer)
  python3 scripts/intercom-unanswered-reply-watchdog.py --dry-run  # print counts + would-page, write nothing
  python3 scripts/intercom-unanswered-reply-watchdog.py --dry-run --at 2026-11-11T20:00:00Z
"""
import argparse
import csv
import hashlib
import html
import http.client
import importlib.util
import io
import json
import os
import pathlib
import re
import subprocess
import sys
import time
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor

_HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(_HERE))
sys.path.insert(0, str(_HERE / "intercom-backlog"))
import buckets  # noqa: E402  (the one bucket classifier: thanks-only / noise are not owed a reply)
from credit_review import decide  # noqa: E402  (paying_users: the one paid definition)
from lib import robot_mail  # noqa: E402
from lib.intercom_identity import resolve_admin_id  # noqa: E402  (Caroline's admin id)


def _load(name, filename):
    spec = importlib.util.spec_from_file_location(name, _HERE / filename)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


# Shared deterministic helpers (search headers, deeplink, Slack post, atomic ledger write).
base = _load("intercom_data_complaint_watchdog", "intercom-data-complaint-watchdog.py")

DEFAULT_CHANNEL = "C0BBTAVP44X"      # #cs_priority
DEFAULT_MENTION_IDS = "U038BM16T7W"  # Jan
DEFAULT_STATE_DIR = "/var/lib/intercom-unanswered-reply-watchdog"
TRINO = os.environ.get("UNANSWERED_REPLY_TRINO", "/opt/hydra/scripts/trino-query.sh")
THRESHOLD_H = 24
REPAGE_H = 72
COUNT_EVERY_H = 24  # nothing listable but any thread still owed (free included): post the count this often
LIST_MAX_DAYS = 30
FREE_LIST_DAYS = 7
MAX_LINES = 25
MAX_READS = 12000
MAX_CLOSED_READS = 60
READ_WORKERS = 8
READ_BUDGET_S = 1500
CLOSED_BUDGET_S = 600  # the closed-without-answer pass gets its own budget, not what the open pass left
IDMAP_CHUNK = 1000
IDMAP_TTL_S = 24 * 3600  # re-read a paying account's identity keys at least daily
PAGED_RETENTION_S = 60 * 86400
OPEN_STATES = ("open", "snoozed")
INBOUND = ("user", "lead", "contact")
REPLY_PARTS = ("comment", "assign_and_reopen", "open")
CUSTOMER_LAST, HANDOFF_CHASED, PROMISE_OPEN, NOT_OWED = "customer_last", "handoff_chased", "promise_open", "not_owed"
LISTED = (CUSTOMER_LAST, HANDOFF_CHASED)   # paged line by line
OWED = LISTED + (PROMISE_OPEN,)            # the whole class: counted in every page
# An account email on our own domain is staff. Customers quote support@ in every email reply,
# so matching it would turn 300+ threads "paid" (measured 2026-11-11: 315).
STAFF_EMAIL_DOMAINS = ("muso.ai",)
NOT_OWED_BUCKETS = ("thanks-only", "auto-noise", "social-noise")
READ_ERRORS = (urllib.error.URLError, ValueError, OSError, http.client.HTTPException)

# What Caroline says when a person or team is supposed to pick the thread up. The first
# alternative is the approved hand-off line (plugins/intercom/src/answer-bank.ts HANDOFF_LINE)
# and the second the SOUL.md fallback; the rest are the hand-off families the 2026-10-22
# close-out sweep missed. A bare "within N days" is deliberately NOT here: it is how she
# describes a normal turnaround, and the page says "told a teammate would follow up".
PROMISE_RE = re.compile(
    r"pulling in a teammate|make sure this gets to the team|a teammate will\b|"
    r"\b(?:passed|sent|flagged|escalated|raised|forwarded|handed)\b[^.?!;]{0,60}"
    r"\b(?:team|teammate|review|specialist|engineers?|engineering)\b|"
    r"you(?:'|’)ll hear back|we(?:'|’)ll (?:be in touch|get back to you|follow up)|"
    r"manual review", re.I)
EMAIL_RE = re.compile(r"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}")
_TAG_RE = re.compile(r"<[^>]*>")


def _text(value):
    return " ".join(html.unescape(_TAG_RE.sub(" ", value or "")).split())


def sha(email):
    return hashlib.sha256((email or "").strip().lower().encode()).hexdigest()


def _all_parts(detail):
    return [detail.get("source") or {}] + list(((detail.get("conversation_parts") or {})
                                                .get("conversation_parts")) or [])


def verdict(detail, bot_admin_id):
    """{"k": class, "s": waiting-since epoch, "e": episode id, "b": bucket, "m": [email sha]}
    for the thread as it stands, or {"k": None, "m": [...]} when nothing is owed.

    The episode id is what a page is keyed on: the customer's part for customer_last (a new
    customer message is a new episode) and the FIRST unkept promise for the promise classes
    (more bot replies or customer nudges never restart that clock; only a human reply ends it)."""
    last_cust, texts, human_at, bot_at, promises, mentioned = None, [], 0, 0, [], []
    last_bot_promised = False
    for i, p in enumerate(_all_parts(detail)):
        a = p.get("author") or {}
        ts = int(p.get("created_at") or (detail.get("created_at") if i == 0 else 0) or 0)
        body = _text(p.get("body"))
        if a.get("type") in INBOUND:
            if not (body or p.get("attachments")):
                continue
            subj = _text(p.get("subject")) if i == 0 else ""
            if robot_mail.is_robot_mail(subj, body, (a.get("email") or "").strip().lower())[0]:
                continue
            last_cust = (ts, str(p.get("id") or "source"))
            texts.append((ts, body or "(attachment)"))  # a file with no words is still a message
            mentioned += [sha(m) for m in EMAIL_RE.findall(body)]
        elif (body or p.get("attachments")) and p.get("part_type", "comment") in REPLY_PARTS \
                and a.get("type") in ("admin", "bot"):
            if a.get("type") == "admin" and str(a.get("id")) != str(bot_admin_id):
                human_at = max(human_at, ts)
            else:
                promised = bool(PROMISE_RE.search(body))
                if ts >= bot_at:
                    bot_at, last_bot_promised = ts, promised
                if promised:
                    promises.append((ts, str(p.get("id") or "source")))
    out = {"k": None, "m": sorted(set(mentioned))[:20]}
    unkept = sorted(x for x in promises if x[0] > human_at)
    waiting = bool(last_cust) and last_cust[0] > max(human_at, bot_at)
    bucket = buckets.bucket_of(" ".join(b for _, b in texts[-3:]), texts[-1][1]) if texts else "thanks-only"
    if waiting and bucket not in NOT_OWED_BUCKETS:
        out.update(k=CUSTOMER_LAST, s=last_cust[0], e=last_cust[1], b=bucket)
    elif unkept and last_cust:
        # a chase is a real message after the promise; "ok thanks" is not one
        chased = last_bot_promised and any(
            t > unkept[0][0] and buckets.bucket_of(b, b) not in NOT_OWED_BUCKETS for t, b in texts)
        out.update(k=HANDOFF_CHASED if chased else PROMISE_OPEN, s=unkept[0][0],
                   e="promise:" + unkept[0][1], b=bucket)
    elif waiting:
        out.update(k=NOT_OWED, s=last_cust[0], e=last_cust[1], b=bucket)
    return out


def needs_read(conv):
    """A conversation the customer never wrote in (an outbound message nobody answered) owes
    nothing, so it is not read at all."""
    st = conv.get("statistics") or {}
    src = conv.get("source") or {}
    inbound = (src.get("delivered_as") == "customer_initiated") if src.get("delivered_as") \
        else ((src.get("author") or {}).get("type") in INBOUND)
    return bool(st.get("last_contact_reply_at")) or inbound


def conv_keys(conv):
    """(external ids, sender email sha) from the SEARCH row: no extra read."""
    exts = [str(c.get("external_id")) for c in ((conv.get("contacts") or {}).get("contacts") or [])
            if c.get("external_id")]
    author = (conv.get("source") or {}).get("author") or {}
    email = (author.get("email") or "").strip() if author.get("type") in INBOUND else ""
    return exts, (sha(email) if email else None)


# ── paid: the paying list + the identity keys of the accounts on it ──────────
def trino(sql):
    p = subprocess.run([TRINO], input=sql, capture_output=True, text=True, timeout=300, check=False)
    if p.returncode:
        raise OSError(f"replica read failed: {p.stderr.strip()[-160:]}")
    return list(csv.reader(io.StringIO("\n".join(
        ln for ln in p.stdout.splitlines() if ln.startswith('"')))))


def refresh_idmap(idmap, paying, query=None, now=None):
    """idmap = {user id: [professional id, auth0 id, email sha, refreshed_at]} for exactly the
    paying ids. An account is re-read when it is new or its keys are older than IDMAP_TTL_S, so
    a customer who paid an hour ago is known on the next tick and a changed email / Auth0 /
    professional id is picked up instead of labelling their thread free forever. Returns the
    number of paying accounts still unmapped."""
    query = query or trino
    now = int(time.time()) if now is None else int(now)
    for uid in [u for u in idmap if int(u) not in paying]:
        del idmap[uid]
    stale = sorted(u for u in paying
                   if str(u) not in idmap
                   or now - int((idmap[str(u)] + [0])[3] or 0) >= IDMAP_TTL_S)
    # a key we are about to re-read is not trusted meanwhile: if the read fails, the account
    # is unmapped (unverified) rather than classified on keys that may no longer be its own
    for uid in stale:
        idmap.pop(str(uid), None)
    for i in range(0, len(stale), IDMAP_CHUNK):
        chunk = stale[i:i + IDMAP_CHUNK]
        try:
            rows = query("SELECT CAST(id AS varchar), coalesce(neptuneprofessionalid, ''), "
                         "coalesce(auth0userid, ''), lower(coalesce(email, '')) "
                         "FROM postgresql_core.public.users "
                         f"WHERE id IN ({', '.join(str(int(u)) for u in chunk)})")
        except (OSError, subprocess.SubprocessError) as e:
            print(f"ERROR: paying-account identity read failed: {e}", file=sys.stderr)
            break
        for r in rows:
            if len(r) == 4:
                staff = r[3].rsplit("@", 1)[-1] in STAFF_EMAIL_DOMAINS
                idmap[str(r[0])] = [r[1], r[2], sha(r[3]) if r[3] and not staff else "", now]
    return sum(1 for u in paying if str(u) not in idmap)


def paid_index(idmap):
    ext, mail = {}, {}
    for uid, (pro, a0, esha, *_) in idmap.items():
        for k in (pro, a0, a0.replace("auth0|", "")):
            if k:
                ext[k] = uid
        if esha:
            mail[esha] = uid
    return ext, mail


def paid_of(exts, sender, mentioned, index, partial=False):
    """("paid", basis) | ("free", None) | ("unknown", None) when there is no paying list,
    or when the list is only partly mapped and this thread did not match it."""
    if index is None:
        return "unknown", None
    ext, mail = index
    if any(e in ext or e.replace("auth0|", "") in ext for e in exts):
        return "paid", "contact"
    if sender and sender in mail:
        return "paid", "sender_email"
    if any(m in mail for m in mentioned or []):
        return "paid", "mentioned_email"
    return ("unknown", None) if partial else ("free", None)


# ── Intercom reads ───────────────────────────────────────────────────────────
def _get(token, path, attempts=4):
    req = urllib.request.Request(
        f"{base.INTERCOM_API}{path}",
        headers={"Authorization": f"Bearer {token}", "Accept": "application/json",
                 "Intercom-Version": base.INTERCOM_VERSION})
    for i in range(attempts):
        try:
            with urllib.request.urlopen(req, timeout=60) as resp:
                return json.load(resp)
        except urllib.error.HTTPError as e:
            if e.code in (429, 500, 502, 503, 504) and i < attempts - 1:
                time.sleep(2 ** i)
                continue
            raise
        except READ_ERRORS:  # a DNS blip or a dropped read: one bad second must not fail the tick
            if i < attempts - 1:
                time.sleep(2 ** i)
                continue
            raise


def fetch_conversation(token, cid):
    return _get(token, f"/conversations/{cid}?display_as=plaintext")


def fetch_open(token):
    """Every open or snoozed conversation (search rows: statistics, contacts, source)."""
    convs, after = [], None
    while True:
        body = {"query": {"operator": "OR", "value": [
            {"field": "state", "operator": "=", "value": s} for s in OPEN_STATES]},
            "pagination": {"per_page": 150}}
        if after:
            body["pagination"]["starting_after"] = after
        data = base._intercom_search(token, body)
        convs += data.get("conversations") or []
        nxt = (data.get("pages") or {}).get("next")
        after = nxt.get("starting_after") if isinstance(nxt, dict) else None
        if not after:
            return convs


def read_many(token, cids, bot, deadline):
    """{cid: verdict | Exception}; a cid past the deadline is simply absent. A 404 is an
    unreadable conversation, never proof that the customer was answered."""
    def one(cid):
        if time.monotonic() >= deadline:
            return cid, None
        try:
            d = fetch_conversation(token, cid)
            return cid, {"state": base.conv_state(d), **verdict(d, bot)}
        except READ_ERRORS as e:
            return cid, e
    with ThreadPoolExecutor(max_workers=READ_WORKERS) as ex:
        return {cid: v for cid, v in ex.map(one, cids) if v is not None}


# ── state ────────────────────────────────────────────────────────────────────
RECORDS = ("threads", "paged", "idmap", "meta")


def empty_state():
    return {k: {} for k in RECORDS}


def load_state(path):
    """A missing file is a fresh start; any other shape raises, so a state file we do not
    understand is never silently replaced (and its page record never silently lost)."""
    try:
        with open(path) as f:
            raw = json.load(f)
    except FileNotFoundError:
        return empty_state()
    state = empty_state()
    if not isinstance(raw, dict) or not set(raw) <= set(state):
        raise ValueError(f"unrecognised state shape in {path}")
    state.update(raw)
    if not all(isinstance(state[k], dict) for k in RECORDS):
        raise ValueError(f"unrecognised state shape in {path}")
    return state


# ── page ─────────────────────────────────────────────────────────────────────
def should_page(row, now, paged, threshold_h, repage_h):
    """Paid (or paid-unverified) LISTED classes: once the wait passes the threshold, then every
    repage_h while the same episode stays unanswered. Free: once per episode and then every
    FREE_LIST_DAYS. promise_open is counted, never listed."""
    wait = now - row["s"]
    if row["k"] not in LISTED or wait < threshold_h * 3600 or wait > LIST_MAX_DAYS * 86400:
        return False
    entry = paged.get(row["id"]) or {}
    if row["paid"] == "free":
        if entry.get("episode") != row["e"]:
            return True
        return now - int(entry.get("last_paged") or 0) >= FREE_LIST_DAYS * 86400
    if entry.get("episode") != row["e"]:
        return True
    return now - int(entry.get("last_paged") or 0) >= repage_h * 3600


def _wait(seconds):
    h = int(seconds // 3600)
    return f"{h} h" if h < 72 else f"{h // 24} d"


BASIS = {"contact": "paid", "sender_email": "paid (sender's email)",
         "mentioned_email": "paid (account named in the thread)"}


def render_line(row, now, workspace_id):
    what = {CUSTOMER_LAST: "customer wrote last, no reply",
            HANDOFF_CHASED: "asked again, told again that a teammate would follow up, no human since",
            PROMISE_OPEN: "told a teammate would follow up, no human since"}[row["k"]]
    who = {"paid": BASIS.get(row.get("basis"), "paid"), "free": "free",
           "unknown": "paid status unverified"}[row["paid"]]
    closed = " *CLOSED without an answer*" if row.get("closed") else ""
    return (f"• *{_wait(now - row['s'])}*{closed} {what} · {who} · "
            f"{base.slack_escape(row.get('subj') or '(no subject)')[:90]} "
            f"{base.deeplink(workspace_id, row['id'])}")


def summarize(rows, now, threshold_h):
    """PII-free counts of the class at the threshold: the number a person is shown."""
    out = {"threshold_h": threshold_h, "total": 0,
           "by_paid": {p: 0 for p in ("paid", "free", "unknown")},
           "by_class": {p: {k: 0 for k in OWED} for p in ("paid", "free", "unknown")},
           "within_list_window": {p: 0 for p in ("paid", "free", "unknown")},
           "paid_by_basis": {}, "not_owed": 0, "oldest_days": {"paid": 0, "free": 0, "unknown": 0}}
    for r in rows:
        wait = now - r["s"]
        if wait < threshold_h * 3600:
            continue
        if r["k"] == NOT_OWED:
            out["not_owed"] += 1
            continue
        p = r["paid"]
        out["total"] += 1
        out["by_paid"][p] += 1
        out["by_class"][p][r["k"]] += 1
        out["oldest_days"][p] = max(out["oldest_days"][p], int(wait // 86400))
        if wait <= LIST_MAX_DAYS * 86400:
            out["within_list_window"][p] += 1
        if p == "paid":
            out["paid_by_basis"][r["basis"]] = out["paid_by_basis"].get(r["basis"], 0) + 1
    return out


def render(due, more, closed, summary, paid_note, unread, now, mention_ids, workspace_id):
    s, n = summary, summary["threshold_h"]
    what = (f"*{len(due) + len(closed)} customer thread(s) need an answer*" if due or closed else
            f"*Nothing new to list, and {s['total']} thread(s) still have no answer from a person* "
            f"(*{s['by_paid']['paid'] + s['by_paid']['unknown']} paid*)")
    head = (f"{' '.join(f'<@{m}>' for m in mention_ids)} :hourglass_flowing_sand: {what} "
            f"({n} h+; Caroline saying a teammate will follow up is not an answer)")
    lines = [head] + [render_line(r, now, workspace_id) for r in due]
    if more:
        lines.append(f"_+{more} more due, listed next tick._")
    if closed:
        lines.append("*Left the list by being closed, not answered (reopen, do not count as done):*")
        lines += [render_line(r, now, workspace_id) for r in closed]
    def cls(p):
        c = s["by_class"][p]
        return (f"{c[CUSTOMER_LAST]} customer wrote last, {c[HANDOFF_CHASED]} asked again after a hand-off, "
                f"{c[PROMISE_OPEN]} told a teammate would follow up")
    lines.append(
        f"_Whole class right now, {n} h+ with no human: *{s['by_paid']['paid']} paid* ({cls('paid')}; "
        f"{s['within_list_window']['paid']} in the last {LIST_MAX_DAYS} d, oldest {s['oldest_days']['paid']} d) · "
        f"{s['by_paid']['free']} free ({cls('free')}) · {s['by_paid']['unknown']} paid-status unverified. "
        f"customer_last and handoff_chased are listed line by line; promise_open is counted, "
        f"never listed; nothing older than {LIST_MAX_DAYS} d._")
    if paid_note:
        lines.append(f":warning: _Paid split incomplete: {base.slack_escape(paid_note)}_")
    if unread:
        lines.append(f":warning: _{unread} thread(s) could not be read this tick; they are NOT counted as answered._")
    return "\n".join(lines)


def blocks_for(text, limit=2900):
    """Slack sections cap at 3000 chars: split on lines so no item is ever cut off."""
    blocks, cur = [], ""
    for line in text.split("\n"):
        if cur and len(cur) + 1 + len(line) > limit:
            blocks.append({"type": "section", "text": {"type": "mrkdwn", "text": cur}})
            cur = ""
        cur = (cur + "\n" + line) if cur else line[:limit]
    if cur:
        blocks.append({"type": "section", "text": {"type": "mrkdwn", "text": cur}})
    return blocks


# ── tick ─────────────────────────────────────────────────────────────────────
def run(args):
    token = os.environ.get("MUSOAI_INTERCOM_TOKEN")
    if not token:
        print("ERROR: MUSOAI_INTERCOM_TOKEN not set", file=sys.stderr)
        return 1
    try:
        now = int(base._epoch(args.at))
    except Exception as e:  # noqa: BLE001
        print(f"ERROR: bad --at: {e}", file=sys.stderr)
        return 1
    state_dir = os.environ.get("UNANSWERED_REPLY_STATE_DIR", DEFAULT_STATE_DIR)
    state_path = os.path.join(state_dir, "state.json")
    try:
        state = load_state(state_path)
    except (OSError, ValueError) as e:
        print(f"ERROR: cannot use state {state_path} (left untouched): {e}", file=sys.stderr)
        return 1
    threads, paged, idmap, meta = (state[k] for k in RECORDS)
    bot = resolve_admin_id()
    workspace_id = os.environ.get("INTERCOM_WORKSPACE_ID", base.DEFAULT_WORKSPACE_ID)
    mention_ids = [s.strip() for s in os.environ.get(
        "UNANSWERED_REPLY_MENTION_IDS", DEFAULT_MENTION_IDS).split(",") if s.strip()]
    rc = 0

    # 1. paid: the house list, then the identity keys of the accounts on it
    paying, why = decide.paying_users(os.environ.get("UNANSWERED_REPLY_PAYING_FILE") or None)
    index, paid_note, partial = None, None, False
    if paying is None:
        paid_note = f"paying list unusable ({why}); every thread is 'paid status unverified', none is 'free'"
    else:
        unmapped = refresh_idmap(idmap, paying, now=now)
        index = paid_index(idmap)
        if unmapped:
            partial = True
            paid_note = (f"{unmapped} of {len(paying)} paying accounts could not be matched to an "
                         "Intercom identity this tick; an unmatched thread is 'paid status "
                         "unverified', never free")
    if paid_note:
        # A degraded paying split is WARNED, never a failed unit. The tick still measured and
        # paged, and a oneshot that exits non-zero freezes lastSuccessfulTime, so "the house
        # list was stale" would be indistinguishable from "the check is dead". The warning
        # rides the page (and latest.json's paid_split) instead of the exit code.
        print(f"WARN: {paid_note}", file=sys.stderr)

    # 2. every open / snoozed conversation; re-read only what changed since its cached verdict
    try:
        convs = {str(c.get("id")): c for c in fetch_open(token)}
    except READ_ERRORS as e:
        print(f"ERROR: Intercom search failed (nothing measured, nothing paged): {e}", file=sys.stderr)
        return 2
    want = [cid for cid, c in convs.items() if needs_read(c)
            and (threads.get(cid) or {}).get("u") != int(c.get("updated_at") or 0)]
    # Longest wait first, on the wait the page itself reports: a cached verdict's `s` is the
    # first unkept promise for handoff_chased/promise_open and the customer's message for
    # customer_last, so it can be far older than the customer's last reply. The read cap must
    # drop the FRESHEST threads, never the ones that have been waiting longest: those are the
    # whole reason this check exists, and sorting newest-first silently starved them on any tick
    # where the cap or the budget bit. Only a thread with no cached verdict yet falls back to
    # last_contact_reply_at, because its `s` is unknown before the read. A missing value sorts
    # oldest, because an unknown wait is not a short one.
    def wait_start(cid):
        cached = threads.get(cid) or {}
        if cached.get("s") is not None:
            return int(cached["s"])
        return int((convs[cid].get("statistics") or {}).get("last_contact_reply_at") or 0)

    want.sort(key=wait_start)
    deadline = time.monotonic() + READ_BUDGET_S
    got = read_many(token, want[:MAX_READS], bot, deadline)
    unread = 0
    for cid in want:
        v = got.get(cid)
        if isinstance(v, dict):
            threads[cid] = {"u": int(convs[cid].get("updated_at") or 0),
                            **{k: v[k] for k in ("k", "s", "e", "b", "m") if k in v}}
        else:  # read error (404 included), or past the cap / budget: the previous verdict stands
            unread += 1
            if isinstance(v, Exception):
                print(f"ERROR: could not read {cid}: {v}", file=sys.stderr)
    if unread:
        print(f"ERROR: {unread} conversation(s) not read this tick (kept, never counted as answered)",
              file=sys.stderr)
        rc = 2

    # 3. closed is not answered: re-read what left the open set while it was owed
    left = [cid for cid, t in threads.items()
            if cid not in convs and t.get("k") in OWED and not t.get("closed_at")]
    left.sort(key=lambda cid: int(threads[cid].get("s") or 0))
    closed_rows, closed_all, unverified = [], [], 0
    regot = read_many(token, left[:MAX_CLOSED_READS], bot, time.monotonic() + CLOSED_BUDGET_S)
    for cid in left:
        v = regot.get(cid)
        if isinstance(v, dict) and v.get("k") in OWED and v["state"] not in OPEN_STATES:
            threads[cid].update(closed_at=now, **{k: v[k] for k in ("k", "s", "e", "b", "m")})
        elif isinstance(v, dict):
            del threads[cid]  # answered, or reopened (next tick sees it open)
        else:
            unverified += 1  # not re-read yet: neither "closed unanswered" nor forgotten
    if unverified:
        print(f"ERROR: {unverified} thread(s) left the open set and could not be re-read yet", file=sys.stderr)
        rc = 2
    for cid in [c for c in threads if c not in convs and threads[c].get("k") not in OWED]:
        del threads[cid]

    # 4. classify + count + decide what is due
    rows, unresolved = [], []
    for cid, t in threads.items():
        if not t.get("k"):
            continue
        c = convs.get(cid) or {}
        exts, sender = conv_keys(c) if c else (t.get("x") or [], t.get("se"))
        if c:  # keep the search-row keys so a closed thread can still be classified
            t.update(x=exts, se=sender, subj=_text((c.get("source") or {}).get("subject"))[:110])
        paid, basis = paid_of(exts, sender, t.get("m"), index, partial)
        row = {"id": cid, "k": t["k"], "s": int(t["s"]), "e": t["e"], "paid": paid, "basis": basis,
               "subj": t.get("subj") or "", "closed": bool(t.get("closed_at"))}
        if cid not in convs:
            if row["closed"]:
                closed_all.append(row)  # still owed: a close never lowers the count
                if paged.get(cid, {}).get("closed_paged") != t["e"]:
                    closed_rows.append(row)
            else:
                # left the open set and not re-read yet: keep its last owed verdict in the
                # count. Dropping it would let an unread failure publish an invented zero.
                unresolved.append(row)
            continue
        rows.append(row)
    summary = summarize(rows + closed_all + unresolved, now, args.threshold_hours)
    order = {"paid": 0, "unknown": 0, "free": 1}
    due_all = sorted((r for r in rows if should_page(r, now, paged, args.threshold_hours, REPAGE_H)),
                     key=lambda r: (order[r["paid"]],
                                    0 if r["paid"] == "free" and r["k"] == HANDOFF_CHASED else 1,
                                    (paged.get(r["id"]) or {}).get("episode") == r["e"], r["s"]))
    due, more = due_all[:MAX_LINES], max(0, len(due_all) - MAX_LINES)
    closed_rows = sorted(closed_rows, key=lambda r: (order[r["paid"]], r["s"]))[:MAX_LINES]
    snapshot = {"generated_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(now)),
                "open_or_snoozed": len(convs), "unread": unread,
                "unresolved_left": len(unresolved), "complete": not unread and not unresolved,
                "paid_split": "measured" if not paid_note else paid_note,
                "due_now": len(due_all), "closed_unanswered": len(closed_all), **summary}

    # nothing listable is not nothing owed: the count still reaches a person once a day
    # A degraded paying split reaches a person on the next count page, at most once per
    # COUNT_EVERY_H: it is the one signal that no longer fails the unit, so it must not be
    # able to go unseen either.
    count_only = (not due and not closed_rows and (summary["total"] > 0 or paid_note)
                  and now - int(meta.get("last_post") or 0) >= COUNT_EVERY_H * 3600)
    text = (render(due, more, closed_rows, summary, paid_note, unread + len(unresolved), now,
                   mention_ids, workspace_id)
            if due or closed_rows or count_only else None)

    if args.dry_run:
        print(json.dumps(snapshot, indent=2))
        print(text or "(nothing would be posted this tick)", file=sys.stderr)
        return rc

    if text:
        try:
            slack_token = base.resolve_slack_token()
            if not slack_token:
                raise RuntimeError("no Slack bot token")
            base.slack_post(slack_token, os.environ.get("UNANSWERED_REPLY_CHANNEL", DEFAULT_CHANNEL),
                            text[:200], blocks_for(text))
        except READ_ERRORS + (RuntimeError,) as e:
            print(f"ERROR: Slack post failed: {e}", file=sys.stderr)
            rc = 2  # no page recorded: every item retries next tick
        else:
            meta["last_post"] = now
            for r in due:
                prev = paged.get(r["id"]) or {}
                same = prev.get("episode") == r["e"]
                paged[r["id"]] = {"episode": r["e"], "last_paged": now,
                                  "pages": (int(prev.get("pages") or 0) + 1) if same else 1}
            for r in closed_rows:
                paged.setdefault(r["id"], {}).update(closed_paged=r["e"], last_paged=now)
    state["paged"] = {k: v for k, v in paged.items()
                      if k in threads or now - int(v.get("last_paged") or 0) < PAGED_RETENTION_S}
    try:
        base.save_ledger(state_path, state)
        base.save_ledger(os.path.join(state_dir, "latest.json"), snapshot)
    except OSError as e:
        print(f"ERROR: could not write state under {state_dir}: {e}", file=sys.stderr)
        return 2
    print(json.dumps({k: snapshot[k] for k in ("generated_at", "total", "by_paid", "due_now", "unread")}))
    return rc


def main():
    p = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    p.add_argument("--dry-run", action="store_true", help="print counts + would-page; no Slack, no state write")
    p.add_argument("--at", default=None, help="evaluate as-if at this instant (iso or epoch)")
    p.add_argument("--threshold-hours", type=int, default=THRESHOLD_H)
    return run(p.parse_args())


if __name__ == "__main__":
    sys.exit(main())
