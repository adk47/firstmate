#!/usr/bin/env python3
"""Proactively tell a customer when their verification ticket has gone overdue.

Addresses the #1 escalation in the Caroline weekly roll-up: "Delayed
verification follow-ups — customers return after a promised review with no
update." Today the stale-ticket-watchdog tells OPS the queue is overdue, but
the customer is never told, so they come back frustrated. This sends ONE
in-app Intercom reply per overdue verification ticket: "this has taken longer
than it should, we've flagged it, nothing needed from you."

This is CUSTOMER-FACING OUTBOUND, so the design is safety-first. It must never
message the wrong person, the same person twice, or about already-finished
work, and a wiped state file must not blast the whole overdue backlog.

Eligibility (every gate must pass; any fail -> skip + count the reason):
  1. ClickUp list 901000600160, tag `hydra-action-request`, `action:<type>` in
     the Tier-1 verification allowlist (ALLOWLIST). Tier-3 is never eligible.
  2. NOT resolved — `_ticket_resolved()` (custom status resolved/done/closed/
     impossible). The open-tasks fetch still returns resolved-but-not-list-
     closed tickets; without this we apologise for finished work.
  3. Overdue by >= 1 BUSINESS day (a Friday-due ticket isn't "late" on
     Saturday) and <= MAX_AGE_DAYS calendar days (don't apologise for a
     two-month-old stale ticket).
  4. NOT tagged `escalation:sla-breach-customer-followup` (the customer already
     followed up and is being handled reactively).
  5. Recover the Intercom conversation id from the #417 "Intercom Link" custom
     field, else an anchored parse of the description deeplink. Missing -> skip
     (never guess).
  6. Per-conversation dedupe: one customer can have several overdue tickets but
     ONE conversation -> at most one message per conversation, this run AND ever
     (persistent state keyed on both ticket id and `conv:<id>`).
  7. Fresh GET /conversations/{id} right before sending, then:
       - email cross-check: conv `source.author.email` must equal the ticket's
         `customer_email`; mismatch -> skip (wrong-customer guard).
       - suppress if the last part is a human admin reply, or is from the
         customer (they just spoke), or the conversation is assigned to a
         non-bot human, or its state != open (snoozed/closed -> never reopen),
         or it carries a social / abuse-block tag.

Cold-start: on the FIRST run (no, or empty, state file), seed ALL currently-
eligible tickets+conversations as already-seen and send NOTHING. Thereafter
only tickets that go newly overdue are candidates. Per-run cap (MAX) bounds any
blast; sending is gated behind `--apply` (default dry-run). A would-send count
above MAX on a freshly-written state file aborts and pages instead of sending
(the breaker keys on the default MAX, so `--limit` cannot disarm it).

Env:
  CLICKUP_API_KEY                 required
  MUSOAI_INTERCOM_TOKEN           required
  INTERCOM_ADMIN_ID              optional, default 5763097 (Caroline)
  CLICKUP_LIST_ID                optional, default 901000600160
  CLICKUP_INTERCOM_LINK_FIELD_ID optional, default c32dbf6e-... (#417 link field)
  OVERDUE_NOTIFY_STATE           optional, default
                                 /var/lib/overdue-verification-notifier/notified.json
  OVERDUE_NOTIFY_MAX             optional, default 25 (per-run send cap)
  OVERDUE_NOTIFY_MAX_AGE_DAYS    optional, default 14 (skip ancient overdue)
  OVERDUE_NOTIFY_NOW             optional, epoch override (tests)
  OVERDUE_NOTIFY_SUMMARY_MODE    optional, "activity" (default: Slack only when
                                 sent>0 or an anomaly) | "always" | "never"
  OVERDUE_NOTIFY_SUMMARY_CHANNEL optional, default C0ANM0PN9L5 (#cs_chats)
  OVERDUE_NOTIFY_SLACK_ACCOUNT   optional, default operations
  SLACK_NOTIFY_CONFIG            optional, default /root/.openclaw-main/openclaw.json
  OVERDUE_NOTIFY_SKIP_HOST_GUARD optional, "1" to run off ovh-node-8 (tests)

Flags:
  --apply       actually send (default: dry-run — list what it would send)
  --limit N     override the per-run cap for this run
  --self-test   run the inline detector self-test and exit

Exit codes: 0 ok; 1 usage/env error; 2 self-test failed / circuit-breaker
tripped; 3 at least one ticket failed mid-run.
"""
import argparse
import json
import os
import re
import socket
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

INTERCOM_API = "https://api.intercom.io"
INTERCOM_VERSION = "2.11"
CLICKUP_API = os.environ.get("CLICKUP_API", "https://api.clickup.com/api/v2")

CAROLINE_ADMIN_ID = "5763097"
DEFAULT_LIST_ID = "901000600160"
# "Intercom Link" custom field (#417); value is the conversation deeplink
# https://app.intercom.com/a/inbox/<ws>/inbox/conversation/<convId>.
INTERCOM_LINK_FIELD = os.environ.get(
    "CLICKUP_INTERCOM_LINK_FIELD_ID", "c32dbf6e-f680-4ff1-a532-192bb96245c3")
_CONV_ID_RE = re.compile(r"/conversation/([^/?#\s\"']+)")

# Only proactively reach out about verification-class work the customer was
# promised a review on. NEVER refunds / disputes / deletions / exports (Tier 3).
# analytics-followup is EXCLUDED on purpose even though ticket-format tiers it as
# Tier 1: per the analytics carve-out (workspaces/support/SOUL.md:53-54,
# reference/active-incidents.md:15, reference/common-issues.md:181-208) analytics
# is a platform-wide migration with NO per-account fix and NO follow-up promise —
# proactively telling a customer "we've flagged it for a priority look" is the
# exact lie that doctrine forbids.
ALLOWLIST = {
    "credit-verify", "credit-claim", "credit-correction",
    "profile-claim",
}
SKIP_TICKET_TAGS = {"escalation:sla-breach-customer-followup"}
# Conversation tags that mean "do not auto-message here".
BLOCKED_CONV_TAGS = {
    "abuse-block", "instagram", "facebook", "twitter", "x",
    "whatsapp", "messenger", "tiktok", "sms",
}

DEFAULT_SUMMARY_CHANNEL = "C0ANM0PN9L5"  # #cs_chats
SLACK_API = "https://slack.com/api/chat.postMessage"

# Caroline-voice proactive note. FIXED CONSTANT — no ticket/customer field is
# ever interpolated, so this bash/urllib send (which bypasses the plugin's
# SanitizingIntercomClient) has zero leak surface. Lowercase Caroline tone,
# DASH-FREE (the support surface forbids em-dashes), no new timeframe, and a
# DISTINCT opening from her reactive SLA-breach reply ("you're right that this
# has taken longer than it should") so a rare race can't double-send the same
# words.
MESSAGE = (
    "hi! quick update on your request with us: it's taken longer than it "
    "should have on our side. i've flagged it for a priority look, and we'll "
    "follow up right here as soon as it's sorted. nothing needed from you in "
    "the meantime."
)


# --------------------------------------------------------------------------
# Network seam (module-level so tests monkeypatch these, never real HTTP).
# --------------------------------------------------------------------------
def http(method, url, headers, body=None, timeout=30, attempts=4):
    """Single urllib wrapper with retry on transient URLErrors."""
    data = None
    hdrs = dict(headers)
    if body is not None:
        hdrs["Content-Type"] = "application/json"
        data = json.dumps(body).encode()
    for a in range(attempts):
        try:
            req = urllib.request.Request(url, data=data, method=method)
            for k, v in hdrs.items():
                req.add_header(k, v)
            with urllib.request.urlopen(req, timeout=timeout) as r:
                return r.status, json.loads(r.read() or b"null")
        except urllib.error.HTTPError:
            raise  # 4xx/5xx are real — let the caller decide
        except (urllib.error.URLError, socket.timeout) as e:
            if a == attempts - 1:
                raise RuntimeError(f"{method} {url} failed after {attempts}: {e}")
            time.sleep(2 * (a + 1))


def _ic_headers(token):
    return {"Authorization": f"Bearer {token}", "Accept": "application/json",
            "Intercom-Version": INTERCOM_VERSION}


def clickup_list_page(key, list_id, page):
    q = urllib.parse.urlencode(
        {"archived": "false", "include_closed": "false",
         "subtasks": "false", "order_by": "due_date", "page": str(page)})
    s, body = http("GET", f"{CLICKUP_API}/list/{list_id}/task?{q}",
                   {"Authorization": key})
    if s != 200 or not isinstance(body, dict) or "tasks" not in body:
        raise RuntimeError(f"clickup list page {page} -> {s}: "
                           f"{(body or {}).get('err') if isinstance(body, dict) else body}")
    return body


def get_conversation(conv_id, token):
    s, body = http("GET",
                   f"{INTERCOM_API}/conversations/{conv_id}?display_as=plaintext",
                   _ic_headers(token))
    if s != 200:
        raise RuntimeError(f"intercom get conv {conv_id} -> {s}")
    return body


def post_intercom_reply(conv_id, admin_id, message, token):
    s, body = http("POST", f"{INTERCOM_API}/conversations/{conv_id}/reply",
                   _ic_headers(token),
                   body={"message_type": "comment", "type": "admin",
                         "admin_id": str(admin_id), "body": message})
    if s not in (200, 201):
        raise RuntimeError(f"intercom reply {conv_id} -> {s}: {body}")
    return body


# --------------------------------------------------------------------------
# Pure logic (no network — directly unit-testable).
# --------------------------------------------------------------------------
def _ticket_resolved(t):
    """True if a ClickUp task is handled. Mirrors close-resolved-conversations."""
    st = t.get("status") or {}
    return (st.get("type") in ("closed", "done")
            or st.get("status") in ("resolved", "impossible"))


def _conv_id_from_link(value):
    m = _CONV_ID_RE.search(str(value))
    return m.group(1) if m else None


def parse_action_request(description):
    """Extract the ---ACTION-REQUEST--- JSON block from a ticket description."""
    if not description:
        return None
    start, end = "---ACTION-REQUEST---", "---END-ACTION-REQUEST---"
    if start in description and end in description:
        block = description.split(start, 1)[1].split(end, 1)[0]
        try:
            return json.loads(block.strip())
        except Exception:
            return None
    return None


def _tag_names(task):
    return {str(t.get("name", "")).lower() for t in (task.get("tags") or [])}


def action_types_of(task):
    """All distinct `action:<type>` tags on a task, sorted for determinism.

    `_tag_names` returns a set, whose iteration order varies across processes
    under hash randomization — returning the "first" action tag would make a
    dual-tagged ticket eligible non-deterministically. Handing back the full
    sorted set lets the caller refuse ambiguous (multi-action) tickets so a
    Tier-3 tag can never ride in alongside an allowlisted one.
    """
    return sorted({name.split("action:", 1)[1] for name in _tag_names(task)
                   if name.startswith("action:")})


def conv_id_of(task):
    """Recover the Intercom conversation id, #417 field first (structured),
    description deeplink second. None when neither is present/parseable."""
    for cf in task.get("custom_fields") or []:
        if cf.get("id") == INTERCOM_LINK_FIELD and cf.get("value"):
            cid = _conv_id_from_link(cf["value"])
            if cid:
                return cid
    desc = task.get("description") or task.get("text_content") or ""
    for line in desc.splitlines():
        if "**Conversation:**" in line or "/inbox/conversation/" in line:
            cid = _conv_id_from_link(line)
            if cid:
                return cid
    return None


def business_days_elapsed(due_epoch, now_epoch):
    """Whole Mon-Fri days strictly after `due_epoch`'s day up to `now_epoch`.

    due_date is pinned to noon UTC, date-only (ticket-format.ts slaDueDateMs),
    so day-granularity in UTC is the right resolution. A ticket due Friday is
    NOT overdue-by-a-business-day until Monday.
    """
    if not due_epoch or now_epoch <= due_epoch:
        return 0
    day = 86400
    due_day = int(due_epoch // day)
    now_day = int(now_epoch // day)
    count = 0
    for d in range(due_day + 1, now_day + 1):
        # Unix day 0 (1970-01-01) was a Thursday -> weekday = (d + 3) % 7,
        # where 0=Mon .. 6=Sun.
        if (d + 3) % 7 < 5:
            count += 1
    return count


def extract_candidate(task, now_epoch, max_age_days):
    """Return a candidate dict if the TICKET-side gates pass, else (None, reason)."""
    tags = _tag_names(task)
    if "hydra-action-request" not in tags:
        return None, "not-action-request"
    atypes = action_types_of(task)
    # Exactly one action tag, and allowlisted. A ticket carrying two action:
    # tags is ambiguous; refuse it rather than non-deterministically picking
    # one — a Tier-3 tag must never slip through next to an allowlisted one.
    if len(atypes) != 1 or atypes[0] not in ALLOWLIST:
        return None, "action-type"
    atype = atypes[0]
    if _ticket_resolved(task):
        return None, "resolved"
    if tags & SKIP_TICKET_TAGS:
        return None, "already-followed-up"
    due = task.get("due_date")
    try:
        due_epoch = int(int(due) / 1000) if due is not None else None
    except (TypeError, ValueError):
        due_epoch = None
    if not due_epoch or due_epoch >= now_epoch:
        return None, "not-overdue"
    if business_days_elapsed(due_epoch, now_epoch) < 1:
        return None, "weekend-only"
    if (now_epoch - due_epoch) > max_age_days * 86400:
        return None, "too-old"
    conv_id = conv_id_of(task)
    if not conv_id:
        return None, "no-conv"
    ar = parse_action_request(task.get("description") or task.get("text_content") or "")
    email = (ar or {}).get("customer_email")
    if not email:
        return None, "no-email"
    return {
        "ticket_id": task.get("id"),
        "conv_id": conv_id,
        "email": str(email).strip().lower(),
        "action_type": atype,
        "due_epoch": due_epoch,
    }, None


def conversation_suppressed(conv, ticket_email, bot_admin_id):
    """(reason | None). Reason is non-None when the conversation must be skipped."""
    src = conv.get("source") or {}
    au = src.get("author") or {}
    # Identity must be POSITIVELY confirmed before any outbound. Read the source
    # author's email regardless of author type and fail CLOSED: if it is absent
    # or does not equal the ticket's customer_email, suppress. (The old guard
    # only read the email for type=="user", so an admin-initiated or lead-
    # authored conversation sailed past the wrong-customer check with an empty
    # conv_email — fail-open on the #1 safety property.)
    conv_email = (au.get("email") or "").strip().lower()
    if ticket_email and conv_email != ticket_email:
        return "email-mismatch"
    # Fail closed on a missing state too: an Intercom conversation GET always
    # carries `state`; its absence is an anomaly, not an invitation to message.
    if conv.get("state") != "open":
        return "not-open"
    assignee = conv.get("admin_assignee_id")
    if assignee and str(assignee) != str(bot_admin_id):
        return "assignee-human"
    tags = {str(t.get("name", "")).lower()
            for t in (conv.get("tags") or {}).get("tags", [])}
    if tags & BLOCKED_CONV_TAGS:
        return "blocked-tag"
    parts = (conv.get("conversation_parts") or {}).get("conversation_parts") or []
    if parts:
        last = parts[-1]
        a = last.get("author") or {}
        if a.get("type") == "user":
            return "customer-last"
        if a.get("type") in ("admin", "team") and str(a.get("id")) != str(bot_admin_id):
            return "human-reply"
    return None


# --------------------------------------------------------------------------
# Persistent state (atomic; seed on absent).
# --------------------------------------------------------------------------
def load_state(path):
    try:
        with open(path) as f:
            return json.load(f)
    except FileNotFoundError:
        return None
    except (OSError, ValueError):
        # A corrupt/truncated state file is NOT treated as "seeded" — return
        # None so the caller re-seeds (sends nothing) rather than mass-sending.
        return None


def write_state(path, state):
    """Atomic rewrite (tmp + os.replace) so a crash never leaves a partial file."""
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = f"{path}.tmp.{os.getpid()}"
    with open(tmp, "w") as f:
        json.dump(state, f)
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, path)


def state_keys(cand):
    return [cand["ticket_id"], f"conv:{cand['conv_id']}"]


def already_seen(state, cand):
    return any(k in state for k in state_keys(cand))


def mark_seen(state, cand, now_epoch):
    for k in state_keys(cand):
        state[k] = now_epoch


def prune_state(state, now_epoch, keep_days=90):
    cutoff = now_epoch - keep_days * 86400
    return {k: v for k, v in state.items() if isinstance(v, (int, float)) and v >= cutoff}


# --------------------------------------------------------------------------
# Inline self-test (mirrors fallback-swallow-watchdog): fail the run if the
# detector is broken, so a silently-misfiring notifier pages via cron-health
# rather than rotting unnoticed.
# --------------------------------------------------------------------------
def _self_test(now_epoch):
    day = 86400
    base = {"id": "T", "tags": [{"name": "hydra-action-request"},
                                {"name": "action:credit-verify"}],
            "custom_fields": [{"id": INTERCOM_LINK_FIELD,
                               "value": "https://app.intercom.com/a/inbox/w/inbox/conversation/C1"}],
            "description": "---ACTION-REQUEST---\n{\"customer_email\": \"a@b.com\"}\n---END-ACTION-REQUEST---",
            "due_date": str((now_epoch - 3 * day) * 1000)}

    clean = dict(base, status={"type": "open", "status": "in progress"})
    c, r = extract_candidate(clean, now_epoch, 14)
    assert c and r is None and c["conv_id"] == "C1" and c["email"] == "a@b.com", ("clean", c, r)

    resolved = dict(base, status={"type": "open", "status": "resolved"})
    c, r = extract_candidate(resolved, now_epoch, 14)
    assert c is None and r == "resolved", ("resolved-not-dropped", c, r)

    refund = dict(base, status={"type": "open", "status": "in progress"},
                  tags=[{"name": "hydra-action-request"}, {"name": "action:subscription-refund"}])
    c, r = extract_candidate(refund, now_epoch, 14)
    assert c is None and r == "action-type", ("tier3-not-excluded", c, r)

    # Friday-due, checked Saturday -> weekend-only, not yet overdue-by-a-bizday.
    friday = 1623412800  # 2021-06-11 12:00 UTC (a Friday)
    saturday = friday + day + 3600
    fri_t = dict(base, status={"type": "open"}, due_date=str(friday * 1000))
    c, r = extract_candidate(fri_t, saturday, 14)
    assert c is None and r == "weekend-only", ("weekend-not-skipped", c, r)

    # Suppression: a human admin spoke last.
    conv = {"source": {"author": {"type": "user", "email": "a@b.com"}},
            "state": "open",
            "conversation_parts": {"conversation_parts": [
                {"author": {"type": "admin", "id": "999"}}]}}
    assert conversation_suppressed(conv, "a@b.com", CAROLINE_ADMIN_ID) == "human-reply", "human-reply"
    # Suppression: wrong customer.
    conv2 = {"source": {"author": {"type": "user", "email": "other@x.com"}}, "state": "open",
             "conversation_parts": {"conversation_parts": []}}
    assert conversation_suppressed(conv2, "a@b.com", CAROLINE_ADMIN_ID) == "email-mismatch", "email-mismatch"
    # Clean conversation passes.
    conv3 = {"source": {"author": {"type": "user", "email": "a@b.com"}}, "state": "open",
             "conversation_parts": {"conversation_parts": [{"author": {"type": "admin", "id": CAROLINE_ADMIN_ID}}]}}
    assert conversation_suppressed(conv3, "a@b.com", CAROLINE_ADMIN_ID) is None, "clean-conv"
    return True


# --------------------------------------------------------------------------
# Slack summary (best-effort; never fails the run). Mirrors close-resolved.
# --------------------------------------------------------------------------
def _read_slack_token(config_path, account):
    try:
        with open(config_path) as f:
            cfg = json.load(f)
        return cfg["channels"]["slack"]["accounts"][account]["botToken"]
    except (OSError, KeyError, ValueError, TypeError):
        return None


def post_slack(text, channel, config_path, account):
    token = _read_slack_token(config_path, account)
    if not token:
        print(f"WARN: no Slack token for '{account}' in {config_path}; summary skipped",
              file=sys.stderr)
        return False
    try:
        s, body = http("POST", SLACK_API,
                       {"Authorization": f"Bearer {token}"},
                       body={"channel": channel, "text": text,
                             "unfurl_links": False, "unfurl_media": False},
                       attempts=1)
        if not (isinstance(body, dict) and body.get("ok")):
            print(f"WARN: Slack post failed: {body}", file=sys.stderr)
            return False
        return True
    except Exception as e:  # noqa: BLE001 — best-effort by contract
        print(f"WARN: Slack post error: {type(e).__name__}: {str(e)[:140]}", file=sys.stderr)
        return False


def fetch_all_tasks(key, list_id):
    tasks, page = [], 0
    while page < 200:
        body = clickup_list_page(key, list_id, page)
        batch = body.get("tasks", [])
        if not batch:
            break
        tasks.extend(batch)
        if body.get("last_page"):
            break
        page += 1
    return tasks


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--apply", action="store_true",
                    help="actually send (default: dry-run)")
    ap.add_argument("--limit", type=int, default=0,
                    help="override the per-run send cap")
    ap.add_argument("--self-test", action="store_true",
                    help="run the inline detector self-test and exit")
    args = ap.parse_args()

    now_epoch = int(os.environ.get("OVERDUE_NOTIFY_NOW") or time.time())

    # Self-test first — a broken detector must page, never run.
    try:
        _self_test(now_epoch)
    except AssertionError as e:
        print(f"overdue-verification-notifier: SELF-TEST FAILED: {e}", file=sys.stderr)
        return 2
    if args.self_test:
        print("self-test ok")
        return 0

    if os.environ.get("OVERDUE_NOTIFY_SKIP_HOST_GUARD") != "1" \
            and socket.gethostname() != "ovh-node-8":
        print("overdue-verification-notifier: not on ovh-node-8 — refusing "
              "(set OVERDUE_NOTIFY_SKIP_HOST_GUARD=1 to override)", file=sys.stderr)
        return 0

    key = os.environ.get("CLICKUP_API_KEY")
    token = os.environ.get("MUSOAI_INTERCOM_TOKEN")
    if not key or not token:
        print("overdue-verification-notifier: CLICKUP_API_KEY and "
              "MUSOAI_INTERCOM_TOKEN are required", file=sys.stderr)
        return 1
    admin_id = os.environ.get("INTERCOM_ADMIN_ID") or CAROLINE_ADMIN_ID
    list_id = os.environ.get("CLICKUP_LIST_ID", DEFAULT_LIST_ID)
    state_path = os.environ.get(
        "OVERDUE_NOTIFY_STATE",
        "/var/lib/overdue-verification-notifier/notified.json")
    default_max = int(os.environ.get("OVERDUE_NOTIFY_MAX", "25"))
    # `--limit` may raise the per-run SEND cap, but it must NOT raise the
    # circuit-breaker trip point (below) — otherwise the very flag an operator
    # reaches for to clear a backlog also disarms the guard against a
    # wiped-state blast. The breaker always trips on the default MAX.
    cap = args.limit if args.limit > 0 else default_max
    max_age = int(os.environ.get("OVERDUE_NOTIFY_MAX_AGE_DAYS", "14"))

    tasks = fetch_all_tasks(key, list_id)
    suppressed = {}
    candidates = []
    for t in tasks:
        cand, reason = extract_candidate(t, now_epoch, max_age)
        if cand:
            candidates.append(cand)
        elif reason not in ("not-action-request", "action-type", "not-overdue"):
            # Count only the "was a verification ticket but dropped" reasons;
            # the list is mostly unrelated/on-time tickets.
            suppressed[reason] = suppressed.get(reason, 0) + 1
    candidates.sort(key=lambda c: c["due_epoch"])  # oldest-overdue first

    state = load_state(state_path)

    # ---- Cold start: first run (or wiped/corrupt state) seeds, sends nothing.
    # An empty dict counts as wiped state too: load_state returns {} for a
    # `{}`-truncated file (valid JSON, so not the corrupt->None path), and
    # treating it as "seen nothing -> every candidate is new" would blast the
    # backlog. `not state` folds both None and {} into the safe seed path.
    if not state:
        seed = {}
        for c in candidates:
            mark_seen(seed, c, now_epoch)
        write_state(state_path, seed)
        msg = (f"overdue-verification-notifier: SEEDED {len(candidates)} "
               f"currently-overdue verification ticket(s); sent 0 (cold start)")
        print(msg)
        _summary(args, sent=0, scanned=len(tasks), candidates=len(candidates),
                 suppressed=suppressed, note="seed", anomaly=True)
        return 0

    new = [c for c in candidates if not already_seen(state, c)]

    # ---- Circuit breaker: a large new-overdue set on a freshly-written state
    # file signals a wipe/corruption/tagging bug, not normal flow. Page, don't
    # send. (Atomic writes make a partial seed impossible, so this is belt-and-
    # suspenders for an externally-mangled state file.)
    try:
        state_age = now_epoch - int(os.path.getmtime(state_path))
    except OSError:
        state_age = 10 ** 9
    if len(new) > default_max and state_age < 12 * 3600:
        text = (f":rotating_light: overdue-verification-notifier ABORTED: "
                f"{len(new)} newly-overdue tickets on a state file written "
                f"{state_age // 60}min ago — looks like wiped/mangled state. "
                f"Sent nothing. Investigate before re-enabling.")
        print(text, file=sys.stderr)
        _post_anomaly(text)
        return 2

    # A dry-run is a PURE preview: it never mutates the persistent state. All
    # state writes below are gated on args.apply. `dirty` defers the non-send
    # bookkeeping writes (dedup/suppression marks) to one prune-write at the end;
    # a successful SEND writes immediately (crash-safe, never re-sends).
    seen_convs = set()
    to_send = new[:cap]
    sent, failed = 0, 0
    dirty = False
    for c in to_send:
        try:
            if c["conv_id"] in seen_convs or f"conv:{c['conv_id']}" in state:
                suppressed["dedup-conv"] = suppressed.get("dedup-conv", 0) + 1
                if args.apply:
                    mark_seen(state, c, now_epoch)
                    dirty = True
                continue
            conv = get_conversation(c["conv_id"], token)
            reason = conversation_suppressed(conv, c["email"], admin_id)
            if reason:
                suppressed[reason] = suppressed.get(reason, 0) + 1
                if args.apply:
                    # Record ticket-level seen so we don't re-GET it daily, but
                    # do NOT mark the conv seen — a later legit ticket on this
                    # conv may still deserve a message once the suppressor clears.
                    state[c["ticket_id"]] = now_epoch
                    dirty = True
                continue
            print(json.dumps({"ticket_id": c["ticket_id"], "conv_id": c["conv_id"],
                              "action_type": c["action_type"],
                              "mode": "apply" if args.apply else "dry-run"}))
            if args.apply:
                post_intercom_reply(c["conv_id"], admin_id, MESSAGE, token)
                # Persist ONLY after the customer-facing write succeeds, atomically
                # per send, so a mid-batch crash never re-sends what already went.
                seen_convs.add(c["conv_id"])
                mark_seen(state, c, now_epoch)
                write_state(state_path, state)
                dirty = True
                _log_send(c)
            else:
                seen_convs.add(c["conv_id"])
            sent += 1
        except urllib.error.HTTPError as e:
            try:
                detail = e.read().decode("utf-8", "replace")[:300]
            except Exception:
                detail = ""
            print(f"[{c['ticket_id']}] ERROR HTTP {e.code}: {detail}", file=sys.stderr)
            failed += 1
        except (RuntimeError, urllib.error.URLError, ValueError, KeyError) as e:
            print(f"[{c['ticket_id']}] ERROR {type(e).__name__}: {e}", file=sys.stderr)
            failed += 1

    if args.apply and dirty:
        write_state(state_path, prune_state(state, now_epoch))

    backlog = len(new) > cap
    print(f"overdue-verification-notifier: scanned={len(tasks)} "
          f"candidates={len(candidates)} new={len(new)} "
          f"{'sent' if args.apply else 'would-send'}={sent} "
          f"failed={failed} capped={backlog} "
          f"suppressed={json.dumps(suppressed, sort_keys=True)}")
    _summary(args, sent=sent, scanned=len(tasks), candidates=len(candidates),
             suppressed=suppressed, note="capped" if backlog else "",
             anomaly=backlog or suppressed.get("email-mismatch", 0) > 0)
    return 3 if failed else 0


# Send audit log line (structured; email hashed so the log carries no PII).
def _log_send(c):
    import hashlib
    eh = hashlib.sha256(c["email"].encode()).hexdigest()[:12]
    line = (f"{time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())} sent "
            f"conv={c['conv_id']} ticket={c['ticket_id']} "
            f"action_type={c['action_type']} email_sha={eh}\n")
    path = os.environ.get("OVERDUE_NOTIFY_LOG",
                          "/var/log/overdue-verification-notifier.log")
    try:
        with open(path, "a") as f:
            f.write(line)
    except OSError:
        sys.stderr.write(line)


def _post_anomaly(text):
    channel = os.environ.get("OVERDUE_NOTIFY_SUMMARY_CHANNEL", DEFAULT_SUMMARY_CHANNEL)
    cfg = os.environ.get("SLACK_NOTIFY_CONFIG", "/root/.openclaw-main/openclaw.json")
    account = os.environ.get("OVERDUE_NOTIFY_SLACK_ACCOUNT", "operations")
    post_slack(text, channel, cfg, account)


def _summary(args, sent, scanned, candidates, suppressed, note, anomaly):
    mode = os.environ.get("OVERDUE_NOTIFY_SUMMARY_MODE", "activity")
    if mode == "never":
        return
    if mode == "activity" and not (sent > 0 or anomaly):
        return
    verb = "sent" if args.apply else "would send"
    extra = f" ({note})" if note else ""
    text = (f":envelope_with_arrow: overdue-verification-notifier{extra}: "
            f"{verb} {sent} proactive overdue-verification note(s). "
            f"scanned={scanned} candidates={candidates} "
            f"suppressed={json.dumps(suppressed, sort_keys=True)}")
    _post_anomaly(text)


if __name__ == "__main__":
    sys.exit(main())
