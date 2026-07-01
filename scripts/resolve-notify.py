#!/usr/bin/env python3
"""Proactively tell a customer when their request has been resolved.

The close-the-loop counterpart of overdue-verification-notifier.py. Today
close-resolved-conversations.py SILENTLY closes an Intercom conversation once
its ClickUp ticket(s) resolve — the customer is never told "it's done", so a
finished request just goes quiet. This sends ONE in-app Intercom reply per
newly-resolved verification ticket: "good news, your request is sorted." The
existing close-resolved batch then closes the conversation (the notify makes us
"we spoke last", which is close-resolved's gate).

This is CUSTOMER-FACING OUTBOUND, so the design is safety-first and mirrors the
overdue notifier exactly. It must never message the wrong person, the same
person twice, or about a conversation that is already closed, and a wiped state
file must not blast the whole resolved backlog.

Eligibility (every gate must pass; any fail -> skip + count the reason):
  1. ClickUp list 901000600160, tag `hydra-action-request`, exactly one
     `action:<type>` and it is in the Tier-1 verification allowlist (ALLOWLIST).
  2. RESOLVED — `_ticket_resolved()` (done/closed type, or resolved/impossible
     status). The ClickUp fetch uses include_closed=true so true closed-type
     resolutions are visible too (not just done-type), matching close-resolved.
  3. Recover the Intercom conversation id from the #417 "Intercom Link" custom
     field, else an anchored parse of the description deeplink. Missing -> skip.
  4. Per-conversation dedupe: one customer may have several resolved tickets but
     ONE conversation -> at most one "done" message per conversation, this run
     AND ever (persistent state keyed on both ticket id and `conv:<id>`).
  5. Fresh GET /conversations/{id} right before sending, then:
       - email cross-check: conv `source.author.email` must equal the ticket's
         `customer_email`; mismatch -> skip (wrong-customer guard).
       - suppress if a human admin replied last (they likely already told the
         customer), the conversation is assigned to a non-bot human, its state
         != open (closed/snoozed -> never reopen with a "done" note), or it
         carries a social / abuse-block tag. A customer who spoke LAST is NOT
         suppressed here — a resolved request where the customer is waiting on
         us is exactly who should hear it's done.

Cold-start: on the FIRST run (no, or empty, state file), seed ALL currently-
resolved tickets+conversations as already-seen and send NOTHING. Thereafter
only tickets that go newly resolved are candidates. Per-run cap (MAX) bounds any
blast; sending is gated behind `--apply` (default dry-run). A would-send count
above MAX on a freshly-written state file aborts and pages instead of sending
(the breaker keys on the default MAX, so `--limit` cannot disarm it).

Env:
  CLICKUP_API_KEY                 required
  MUSOAI_INTERCOM_TOKEN           required
  INTERCOM_ADMIN_ID              optional, default 5763097 (Caroline)
  CLICKUP_LIST_ID                optional, default 901000600160
  CLICKUP_INTERCOM_LINK_FIELD_ID optional, default c32dbf6e-... (#417 link field)
  RESOLVE_NOTIFY_STATE           optional, default
                                 /var/lib/resolve-notify/notified.json
  RESOLVE_NOTIFY_MAX             optional, default 25 (per-run send cap)
  RESOLVE_NOTIFY_NOW             optional, epoch override (tests)
  RESOLVE_NOTIFY_SUMMARY_MODE    optional, "activity" (default: Slack only when
                                 sent>0 or an anomaly) | "always" | "never"
  RESOLVE_NOTIFY_SUMMARY_CHANNEL optional, default C0ANM0PN9L5 (#cs_chats)
  RESOLVE_NOTIFY_SLACK_ACCOUNT   optional, default operations
  SLACK_NOTIFY_CONFIG            optional, default /root/.openclaw-main/openclaw.json
  RESOLVE_NOTIFY_SKIP_HOST_GUARD optional, "1" to run off ovh-node-8 (tests)

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
# promised a review on — the SAME set the overdue notifier uses. analytics-
# followup is included now that the 2026-04 analytics migration is complete and
# analytics is handled per-account like any other Tier-1 follow-up (carve-out
# retired 2026-06-30; see workspaces/support/SOUL.md "Analytics handling" and
# docs/lessons/muso-domain.md).
ALLOWLIST = {
    "credit-verify", "credit-claim", "credit-correction",
    "profile-claim", "analytics-followup",
}
# Conversation tags that mean "do not auto-message here".
BLOCKED_CONV_TAGS = {
    "abuse-block", "instagram", "facebook", "twitter", "x",
    "whatsapp", "messenger", "tiktok", "sms",
}

DEFAULT_SUMMARY_CHANNEL = "C0ANM0PN9L5"  # #cs_chats
SLACK_API = "https://slack.com/api/chat.postMessage"

# Caroline-voice resolution note. FIXED CONSTANT — no ticket/customer field is
# ever interpolated, so this urllib send (which bypasses the plugin's
# SanitizingIntercomClient) has zero leak surface. Lowercase Caroline tone,
# DASH-FREE (the support surface forbids em-dashes), banned-word-clean
# (SOUL.md:242), and a DISTINCT opening from both her reactive replies and the
# overdue notifier so a rare race can't double-send the same words.
MESSAGE = (
    "hi! quick update on your request with us: it's all sorted now on our "
    "side. if anything still doesn't look right on your end, just reply right "
    "here and i'll take another look. thanks for hanging in there."
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
    # include_closed=true: resolve-notify hunts for RESOLVED tickets, which
    # INCLUDES true closed-type statuses. (The overdue notifier uses false — it
    # wants open/overdue work.) With false here, a ticket that moves to a closed
    # status would be invisible: never cold-start seeded, never notified. Mirrors
    # close-resolved-conversations.py, which fetches include_closed=true for the
    # same reason.
    q = urllib.parse.urlencode(
        {"archived": "false", "include_closed": "true",
         "subtasks": "false", "order_by": "updated", "page": str(page)})
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

    Returning the full sorted set lets the caller refuse ambiguous (multi-action)
    tickets so a Tier-3 tag can never ride in alongside an allowlisted one.
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


def extract_candidate(task, now_epoch):
    """Return a candidate dict if the TICKET-side gates pass, else (None, reason).

    Unlike the overdue notifier, the trigger is RESOLVED (not overdue): there is
    no due_date / business-day / age gate, and an sla-breach tag does NOT exclude
    (a resolved request that breached SLA still deserves the "done" note).
    """
    tags = _tag_names(task)
    if "hydra-action-request" not in tags:
        return None, "not-action-request"
    atypes = action_types_of(task)
    # Exactly one action tag, and allowlisted. A ticket carrying two action:
    # tags is ambiguous; refuse it rather than non-deterministically picking one.
    if len(atypes) != 1 or atypes[0] not in ALLOWLIST:
        return None, "action-type"
    atype = atypes[0]
    if not _ticket_resolved(task):
        return None, "not-resolved"
    conv_id = conv_id_of(task)
    if not conv_id:
        return None, "no-conv"
    ar = parse_action_request(task.get("description") or task.get("text_content") or "")
    # Strip BEFORE the emptiness check: a whitespace-only customer_email ("   ")
    # is truthy raw but normalizes to "", which would then make the
    # conversation_suppressed email-match guard a no-op (ticket_email falsey) and
    # let outbound go without a positive email match. Fail closed here.
    email = str((ar or {}).get("customer_email") or "").strip().lower()
    if not email:
        return None, "no-email"
    return {
        "ticket_id": task.get("id"),
        "conv_id": conv_id,
        "email": email,
        "action_type": atype,
    }, None


def conversation_suppressed(conv, ticket_email, bot_admin_id):
    """(reason | None). Reason is non-None when the conversation must be skipped.

    Differs from the overdue notifier in ONE way: a customer who spoke LAST is
    NOT suppressed — a resolved request where the customer is still waiting is
    exactly who should hear it's done. A human admin who spoke last IS suppressed
    (they likely already told the customer), as are closed/assigned/blocked convs.
    """
    src = conv.get("source") or {}
    au = src.get("author") or {}
    # Identity must be POSITIVELY confirmed before any outbound. Read the source
    # author's email regardless of author type and fail CLOSED: absent or
    # mismatched -> suppress (the #1 safety property, wrong-customer guard).
    conv_email = (au.get("email") or "").strip().lower()
    # Fail CLOSED: a falsey ticket_email (extract_candidate already drops empty
    # emails — this is defense-in-depth) or any mismatch suppresses, so outbound
    # never goes without a positive, equal email match.
    if not ticket_email or conv_email != ticket_email:
        return "email-mismatch"
    # Never reopen a closed/snoozed conversation with a "done" note.
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


# The seed always writes this sentinel so a genuinely-seeded-but-empty state is
# never {} (which would look "never seeded" and re-cold-start every run).
SEED_SENTINEL = "__seeded_at__"


def prune_state(state, now_epoch, keep_days=90):
    cutoff = now_epoch - keep_days * 86400
    return {k: v for k, v in state.items()
            if k == SEED_SENTINEL or (isinstance(v, (int, float)) and v >= cutoff)}


# --------------------------------------------------------------------------
# Inline self-test: fail the run if the detector is broken, so a silently-
# misfiring notifier pages via cron-health rather than rotting unnoticed.
# --------------------------------------------------------------------------
def _self_test(now_epoch):
    base = {"id": "T", "tags": [{"name": "hydra-action-request"},
                                {"name": "action:credit-verify"}],
            "custom_fields": [{"id": INTERCOM_LINK_FIELD,
                               "value": "https://app.intercom.com/a/inbox/w/inbox/conversation/C1"}],
            "description": "---ACTION-REQUEST---\n{\"customer_email\": \"a@b.com\"}\n---END-ACTION-REQUEST---"}

    resolved = dict(base, status={"type": "done", "status": "complete"})
    c, r = extract_candidate(resolved, now_epoch)
    assert c and r is None and c["conv_id"] == "C1" and c["email"] == "a@b.com", ("resolved", c, r)

    open_t = dict(base, status={"type": "open", "status": "in progress"})
    c, r = extract_candidate(open_t, now_epoch)
    assert c is None and r == "not-resolved", ("open-not-dropped", c, r)

    refund = dict(base, status={"type": "done", "status": "complete"},
                  tags=[{"name": "hydra-action-request"}, {"name": "action:subscription-refund"}])
    c, r = extract_candidate(refund, now_epoch)
    assert c is None and r == "action-type", ("tier3-not-excluded", c, r)

    # A whitespace-only customer_email must fail CLOSED (no-email), not pass as "".
    ws = dict(base, status={"type": "done"},
              description="---ACTION-REQUEST---\n{\"customer_email\": \"   \"}\n---END-ACTION-REQUEST---")
    c, r = extract_candidate(ws, now_epoch)
    assert c is None and r == "no-email", ("whitespace-email-not-dropped", c, r)

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
    # Suppression: closed conversation is never reopened.
    conv_closed = {"source": {"author": {"type": "user", "email": "a@b.com"}}, "state": "closed",
                   "conversation_parts": {"conversation_parts": []}}
    assert conversation_suppressed(conv_closed, "a@b.com", CAROLINE_ADMIN_ID) == "not-open", "not-open"
    # KEY DIFFERENCE vs overdue: a customer who spoke last is NOT suppressed —
    # a resolved request where the customer is waiting should hear it's done.
    conv_cust = {"source": {"author": {"type": "user", "email": "a@b.com"}}, "state": "open",
                 "conversation_parts": {"conversation_parts": [{"author": {"type": "user", "id": "u1"}}]}}
    assert conversation_suppressed(conv_cust, "a@b.com", CAROLINE_ADMIN_ID) is None, "customer-last-allowed"
    # Defense-in-depth: an empty ticket_email must fail closed (never a no-op guard).
    conv_ok = {"source": {"author": {"type": "user", "email": "a@b.com"}}, "state": "open",
               "conversation_parts": {"conversation_parts": []}}
    assert conversation_suppressed(conv_ok, "", CAROLINE_ADMIN_ID) == "email-mismatch", "empty-ticket-email-failclosed"
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

    now_epoch = int(os.environ.get("RESOLVE_NOTIFY_NOW") or time.time())

    # Self-test first — a broken detector must page, never run.
    try:
        _self_test(now_epoch)
    except AssertionError as e:
        print(f"resolve-notify: SELF-TEST FAILED: {e}", file=sys.stderr)
        return 2
    if args.self_test:
        print("self-test ok")
        return 0

    if os.environ.get("RESOLVE_NOTIFY_SKIP_HOST_GUARD") != "1" \
            and socket.gethostname() != "ovh-node-8":
        print("resolve-notify: not on ovh-node-8 — refusing "
              "(set RESOLVE_NOTIFY_SKIP_HOST_GUARD=1 to override)", file=sys.stderr)
        return 0

    key = os.environ.get("CLICKUP_API_KEY")
    token = os.environ.get("MUSOAI_INTERCOM_TOKEN")
    if not key or not token:
        print("resolve-notify: CLICKUP_API_KEY and MUSOAI_INTERCOM_TOKEN "
              "are required", file=sys.stderr)
        return 1
    admin_id = os.environ.get("INTERCOM_ADMIN_ID") or CAROLINE_ADMIN_ID
    list_id = os.environ.get("CLICKUP_LIST_ID", DEFAULT_LIST_ID)
    state_path = os.environ.get(
        "RESOLVE_NOTIFY_STATE", "/var/lib/resolve-notify/notified.json")
    default_max = int(os.environ.get("RESOLVE_NOTIFY_MAX", "25"))
    # `--limit` may raise the per-run SEND cap, but it must NOT raise the
    # circuit-breaker trip point — otherwise the flag an operator reaches for to
    # clear a backlog also disarms the wiped-state guard. The breaker trips on
    # the default MAX.
    cap = args.limit if args.limit > 0 else default_max

    tasks = fetch_all_tasks(key, list_id)
    suppressed = {}
    candidates = []
    for t in tasks:
        cand, reason = extract_candidate(t, now_epoch)
        if cand:
            candidates.append(cand)
        elif reason not in ("not-action-request", "action-type", "not-resolved"):
            # Count only the "was a verification ticket but dropped" reasons;
            # the list is mostly unrelated/unresolved tickets.
            suppressed[reason] = suppressed.get(reason, 0) + 1
    candidates.sort(key=lambda c: str(c["ticket_id"]))  # deterministic order

    state = load_state(state_path)

    # ---- Cold start: first run, or wiped/corrupt/empty state, seeds and sends
    # nothing. `not state` folds missing/corrupt (None) and `{}` into the safe
    # seed path so a wipe never blasts the resolved backlog. The seed ALWAYS
    # writes SEED_SENTINEL so a legitimately-seeded-but-empty state is never {}.
    if not state:
        seed = {SEED_SENTINEL: now_epoch}
        for c in candidates:
            mark_seen(seed, c, now_epoch)
        write_state(state_path, seed)
        print(f"resolve-notify: SEEDED {len(candidates)} currently-resolved "
              f"verification ticket(s); sent 0 (cold start)")
        _summary(args, sent=0, scanned=len(tasks), candidates=len(candidates),
                 suppressed=suppressed, note="seed", anomaly=True)
        return 0

    new = [c for c in candidates if not already_seen(state, c)]

    # ---- Circuit breaker: a large new-resolved set on a freshly-written state
    # file signals a wipe/corruption/tagging bug, not normal flow. Page, don't
    # send.
    try:
        state_age = now_epoch - int(os.path.getmtime(state_path))
    except OSError:
        state_age = 10 ** 9
    if len(new) > default_max and state_age < 12 * 3600:
        text = (f":rotating_light: resolve-notify ABORTED: {len(new)} newly-"
                f"resolved tickets on a state file written {state_age // 60}min "
                f"ago — looks like wiped/mangled state. Sent nothing. "
                f"Investigate before re-enabling.")
        print(text, file=sys.stderr)
        _post_anomaly(text)
        return 2

    # A dry-run is a PURE preview: it never mutates the persistent state. All
    # state writes below are gated on args.apply.
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
                    # Record ticket-level seen so we don't re-GET it every run,
                    # but do NOT mark the conv seen — a later legit ticket on
                    # this conv may still deserve a message once it reopens.
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
    print(f"resolve-notify: scanned={len(tasks)} candidates={len(candidates)} "
          f"new={len(new)} {'sent' if args.apply else 'would-send'}={sent} "
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
    path = os.environ.get("RESOLVE_NOTIFY_LOG", "/var/log/resolve-notify.log")
    try:
        with open(path, "a") as f:
            f.write(line)
    except OSError:
        sys.stderr.write(line)


def _post_anomaly(text):
    channel = os.environ.get("RESOLVE_NOTIFY_SUMMARY_CHANNEL", DEFAULT_SUMMARY_CHANNEL)
    cfg = os.environ.get("SLACK_NOTIFY_CONFIG", "/root/.openclaw-main/openclaw.json")
    account = os.environ.get("RESOLVE_NOTIFY_SLACK_ACCOUNT", "operations")
    post_slack(text, channel, cfg, account)


def _summary(args, sent, scanned, candidates, suppressed, note, anomaly):
    mode = os.environ.get("RESOLVE_NOTIFY_SUMMARY_MODE", "activity")
    if mode == "never":
        return
    if mode == "activity" and not (sent > 0 or anomaly):
        return
    verb = "sent" if args.apply else "would send"
    extra = f" ({note})" if note else ""
    text = (f":white_check_mark: resolve-notify{extra}: {verb} {sent} "
            f"proactive resolution note(s). scanned={scanned} "
            f"candidates={candidates} "
            f"suppressed={json.dumps(suppressed, sort_keys=True)}")
    _post_anomaly(text)


if __name__ == "__main__":
    sys.exit(main())
