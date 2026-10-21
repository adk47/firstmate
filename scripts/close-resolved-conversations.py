#!/usr/bin/env python3
"""Silently close Intercom conversations whose ClickUp tickets are customer-complete.

Closes the regrowth axis where a customer's requested state was verified but
the Intercom conversation was never closed — the
decoupling that let the open-conversation pile grow unbounded. Root cause +
triage: docs/2026-06-02-queue-triage-report.md.

SAFETY — a conversation is closed ONLY when BOTH of:
  - WE spoke last: last_admin_reply_at > last_contact_reply_at. This excludes
    `customer_last` (customer waiting on us) and `never_replied` (a chat that
    never got an answer — possibly a dropped customer). We never silently bury
    a conversation that still needs a human, AND
  - the conversation is tied to a customer-complete ticket: terminal ClickUp
    workflow (excluding `impossible`) plus exactly one
    `customer-outcome:complete` tag. How that tie is established
    depends on the mode:
      * default (what the unattended daily timer runs): PRECISE linkage only.
        The conversation id appears in a ClickUp ticket's "Intercom Link" field
        (added in #417) and EVERY ticket linked to THIS conversation is
        customer-complete. A conversation with no linked ticket — or with any
        open linked ticket — is left alone. So a new/unrelated conversation
        for a customer who merely had older complete tickets is NOT closed.
      * --backfill (explicit, human-run, one-time): for conversations with no
        #417 link, fall back to loose email matching — the customer's email
        matches >=1 ticket and EVERY email-matched ticket is customer-complete. This
        drains the pre-#417 backlog under supervision; the timer never uses it.
The close is SILENT (no customer-facing message), so it generates no new
inbound — safe to run while CS has no bandwidth.

Dry-run by default. `--apply` is the explicit gate. Every close is appended to
a shadow log (id, timestamp, email) so it can be reversed.

Env:
  MUSOAI_INTERCOM_TOKEN          required
  CLICKUP_API_KEY                required
  INTERCOM_ADMIN_ID             ignored unless it is 5763097 (Caroline); the posting identity is fixed
  CLICKUP_LIST_ID               optional, default 901000600160 (User Requests)
  CLICKUP_INTERCOM_LINK_FIELD_ID optional, default c32dbf6e-... (#417 link field)
  CLOSE_SHADOW_LOG              optional, default /var/log/close-resolved-shadow.jsonl
                                (falls back to /tmp if that path is not writable)
  RESOLVE_NOTIFY_STATE          optional, default
                                /var/lib/resolve-notify/notified.json
  CLOSE_NOTIFY                  optional, "1" = post a #cs_chats summary (== --notify)
  CLOSE_SUMMARY_CHANNEL        optional, default C0ANM0PN9L5 (#cs_chats)
  CLOSE_SUMMARY_SLACK_ACCOUNT  optional, default operations (which Slack bot posts)
  SLACK_NOTIFY_CONFIG          optional, default /root/.openclaw-main/openclaw.json
                                (openclaw config holding the Slack bot token)
  CLOSE_RESOLVED_JEV_SAMPLE_SIZE optional, default 25 — Phase 2a shadow-only
                                Jev sample size (docs/plans/jev-adoption.md
                                #2a; see JEV_SURFACE_CLOSE_RESOLVED below).
                                Each run draws a FRESH random sample (never
                                the head of the scan) of this size from the
                                FULL open-conversation scan (~5,800/run
                                measured), not just the eligible-to-close
                                slice — so most sampled rows are
                                `actual="not-eligible"` and a few are
                                `actual="eligible"`, mirroring is_eligible()'s
                                own decision. This can never change what gets
                                closed.

Flags:
  --apply       actually close (default: dry-run — list only, no writes)
  --backfill    ALSO close pre-#417 conversations matched loosely by customer
                email (no #417 link). Off by default so the unattended timer
                only closes conversations precisely linked to a customer-complete ticket.
  --limit N     cap the number closed this run (ramp safely)
  --notify      after an --apply run that closed >=1, post a summary (count +
                clickable ClickUp + Intercom links) to #cs_chats as the
                operations Slack bot. No-op on dry-run or when nothing closed.

Exit codes: 0 ok; 1 usage/env error; 3 at least one close failed.
"""
import argparse
import hashlib
import hmac
import json
import os
import random
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from lib.customer_outcome import customer_complete  # noqa: E402
from lib.intercom_identity import resolve_admin_id  # noqa: E402
from lib.jev_shadow import shadow_judge  # noqa: E402

INTERCOM_API = "https://api.intercom.io"
INTERCOM_VERSION = "2.11"
CLICKUP_API = "https://api.clickup.com/api/v2"
USER_EMAIL_FIELD = "e8618c74-d065-4b75-9a5a-86d658392409"  # "User Email" custom field
# "Intercom Link" custom field added in #417 (default mirrors support-tools'
# plugins/support-tools/src/index.ts). Its value is the conversation deeplink
# https://app.intercom.com/a/inbox/<ws>/inbox/conversation/<convId>, from which
# we recover the conversation id for precise (non-email) matching.
INTERCOM_LINK_FIELD = os.environ.get(
    "CLICKUP_INTERCOM_LINK_FIELD_ID", "c32dbf6e-f680-4ff1-a532-192bb96245c3")
# Must match resolve-notify.py's _CONV_ID_RE exactly (excludes quotes too), so a
# description-deeplink conv id extracted here is byte-identical to the one the
# notifier targets — otherwise the defer set (notify_owed) would key on a
# different id than the open conversation and silently fail to defer.
# Canonical shared copy: scripts/lib/intercom_link.py — keep this in sync with it.
_CONV_ID_RE = re.compile(r"/conversation/([^/?#\s\"']+)")
DEFAULT_LIST_ID = "901000600160"
CLICKUP_TASK_URL = "https://app.clickup.com/t/{}"
SLACK_API = "https://slack.com/api/chat.postMessage"
DEFAULT_SUMMARY_CHANNEL = "C0ANM0PN9L5"  # #cs_chats
SUMMARY_MAX_LINES = 25
RESOLVE_STATE_VERSION = 2
RESOLVE_STATE_VERSION_KEY = "__state_version__"
RESOLVE_STATE_CHECKSUM_KEY = "__state_checksum__"
RESOLVE_BULK_BACKLOG_KEY = "__bulk_backlog__"
DEFAULT_JEV_SAMPLE_SIZE = 25

# Phase 2a shadow-only Jev surface (docs/plans/jev-adoption.md #2a). Judges,
# for a RANDOM sample of the full open-conversation scan, whether the
# conversation reads as genuinely resolved from the customer's own
# perspective — independent of and strictly AFTER this script's own
# deterministic is_eligible() decision, never influencing it. See
# CLOSE_RESOLVED_JEV_SAMPLE_SIZE above.
JEV_SURFACE_CLOSE_RESOLVED = "close-resolved"
CLOSE_RESOLVED_QUESTIONS = {
    "conversation_genuinely_resolved": {
        "type": "noul",
        "instructions": (
            "State carries the customer's most recent message in this open "
            "conversation as `customer_message`, the admin's message "
            "immediately BEFORE it (if any) as `preceding_admin_message`, "
            "and whether every ClickUp ticket precisely linked to this "
            "conversation (#417 field) is marked customer-complete as "
            "`linked_ticket_customer_complete` (true/false/null — null means "
            "no linked ticket was found for this conversation). Decide "
            "whether this conversation reads as GENUINELY resolved from the "
            "customer's own perspective, not merely administratively closed "
            "out on the ticket side."
        ),
        "criteria": {
            "true": "The conversation reads as genuinely resolved for the customer.",
            "false": "The conversation does not read as resolved (an unanswered question, a still-open concern, or no evidence of resolution in the message text).",
        },
    },
}


def _resolve_state_checksum(state):
    payload = {k: v for k, v in state.items() if k != RESOLVE_STATE_CHECKSUM_KEY}
    raw = json.dumps(payload, ensure_ascii=False, separators=(",", ":"),
                     sort_keys=True).encode()
    return hashlib.sha256(raw).hexdigest()


def _verified_resolve_state(path):
    """Load + integrity-check resolve-notify's state file.

    Returns the validated dict; {} if the file is absent (clean first run — the
    notifier has processed nothing yet); or None if it is present but
    unreadable / corrupt / checksum-mismatched, in which case the caller MUST
    fail closed (refuse silent closes) rather than trust a damaged state."""
    try:
        with open(path) as f:
            state = json.load(f)
    except FileNotFoundError:
        return {}
    except (OSError, ValueError):
        return None
    if not isinstance(state, dict):
        return None
    expected = state.get(RESOLVE_STATE_CHECKSUM_KEY)
    if state.get(RESOLVE_STATE_VERSION_KEY) != RESOLVE_STATE_VERSION \
            or not isinstance(expected, str) \
            or not hmac.compare_digest(expected, _resolve_state_checksum(state)):
        return None
    return state


def load_held_ticket_ids(path):
    """Return the verified resolve-notify backlog, or None on unreadable state."""
    state = _verified_resolve_state(path)
    if state is None:
        return None
    backlog = state.get(RESOLVE_BULK_BACKLOG_KEY)
    if backlog is None:
        return set()
    ids = backlog.get("ticket_ids") if isinstance(backlog, dict) else None
    if not isinstance(ids, list) or any(not isinstance(tid, str) for tid in ids):
        return None
    return set(ids)


def load_seen_ticket_ids(path):
    """Return the set of ClickUp ticket ids resolve-notify has already PROCESSED
    (notified, suppressed, deduped, or first-run-seeded), or None on unreadable
    state.

    resolve-notify records each processed ticket as a top-level `<ticket_id>`
    key and each notified conversation as `conv:<id>`; its metadata keys are
    `__…__`. A resolved hydra-action-request ticket that is NOT in this set has
    not been processed yet — it resolved after the notifier's last scan (or the
    notifier errored on it) — and the closer must not close its conversation out
    from under the pending "your request is resolved" note. See is_eligible."""
    state = _verified_resolve_state(path)
    if state is None:
        return None
    return {k for k in state
            if not k.startswith("__") and not k.startswith("conv:")}


def _retry_json(req, attempts=4):
    for a in range(attempts):
        try:
            with urllib.request.urlopen(req, timeout=60) as resp:
                return json.load(resp)
        except urllib.error.URLError:
            if a == attempts - 1:
                raise
            time.sleep(2 * (a + 1))


def intercom_search(token, body):
    req = urllib.request.Request(
        f"{INTERCOM_API}/conversations/search",
        data=json.dumps(body).encode(),
        headers={"Authorization": f"Bearer {token}", "Accept": "application/json",
                 "Content-Type": "application/json", "Intercom-Version": INTERCOM_VERSION},
        method="POST")
    return _retry_json(req)


def clickup_get(url, key):
    return _retry_json(urllib.request.Request(url, headers={"Authorization": key}))


def _ticket_customer_complete(t):
    """True only when workflow and customer-visible outcome are complete."""
    return customer_complete(t)


def _notifier_owned(t):
    """True if resolve-notify OWNS this ticket — i.e. it carries the
    `hydra-action-request` trigger tag, the notifier's first candidate gate
    (resolve-notify.py extract_candidate). The closer must never silently close
    a conversation whose resolved notifier-owned ticket the notifier has not yet
    processed; for every other ticket the notifier sends nothing, so the closer
    may close freely.

    Deliberately ONLY the tag gate (not the notifier's allowlist / email /
    single-action gates) so a newly-added action type can never make us
    UNDER-defer and drop a customer note. The cost is a bounded OVER-defer: a
    resolved hydra-action-request ticket the notifier permanently DROPS
    (no customer_email, or multiple/non-allowlisted action tags — none of which
    it ever marks "seen") stays unseen forever, so its conversation is never
    auto-closed. That is a safe leak (an open conversation, never a lost or
    mis-sent message), and such malformed action-request tickets are rare; the
    alternative — duplicating the notifier's email/allowlist gates here — risks
    the unsafe direction (drift → under-defer → lost note)."""
    return "hydra-action-request" in {
        str(tag.get("name", "")).lower() for tag in (t.get("tags") or [])}


def _notifier_conv_id(t):
    """The Intercom conversation resolve-notify would message for this ticket.

    MUST mirror resolve-notify.py `conv_id_of`: the #417 "Intercom Link" custom
    field first, then a `/inbox/conversation/<id>` (or `**Conversation:**`)
    deeplink in the ticket description. The closer's own #417-only ticket index
    (build_ticket_index) misses the description-deeplink path, so relying on it
    alone would let a description-linked notifier-owned ticket resolve after the
    notifier's scan, get closed by a SIBLING #417 ticket on the same
    conversation, and lose the note. This recovers the same conversation the
    notifier will target, so the defer set covers both linkage styles."""
    for cf in t.get("custom_fields") or []:
        if cf.get("id") == INTERCOM_LINK_FIELD and cf.get("value"):
            cid = _conv_id_from_link(cf["value"])
            if cid:
                return cid
    desc = t.get("description") or t.get("text_content") or ""
    for line in desc.splitlines():
        if "**Conversation:**" in line or "/inbox/conversation/" in line:
            cid = _conv_id_from_link(line)
            if cid:
                return cid
    return None


def _conv_id_from_link(value):
    """Recover the Intercom conversation id from an "Intercom Link" field value."""
    m = _CONV_ID_RE.search(str(value))
    return m.group(1) if m else None


def build_ticket_index(key, list_id):
    """Scan the ClickUp list once and return (email_states, conv_states, notify_owed).

    email_states: email(lower) -> set[bool]  — loose, by "User Email" field.
                  Used only by --backfill for the pre-#417 backlog.
    conv_states:  intercom_conv_id -> {
                    "complete": set[bool],                # True iff each ticket is customer-complete
                    "tickets":  {task_id: {"name","url"}},# linked ClickUp tickets (for summary links)
                    "intercom_url": str,                  # the #417 "Intercom Link" deeplink
                  }
                  — precise, by the #417 "Intercom Link" field. The default
                  matching path. Eligibility reads only ["complete"]; "tickets"
                  and "intercom_url" exist purely to build the #cs_chats summary.
    notify_owed:  intercom_conv_id -> set[task_id]  — hydra-action-request tickets
                  (OPEN or resolved) resolve-notify may still owe a "your request
                  is resolved" note for, keyed by the conversation the NOTIFIER
                  targets (conv_id_of: #417 field OR description deeplink). This is
                  a SEPARATE, wider index than conv_states — it uses the notifier's
                  own linkage so the closer never closes a conversation out from
                  under a pending note (an open ticket that will resolve later
                  included). Used ONLY to DEFER a close, never to make one eligible.
    """
    email_states, conv_states, notify_owed = {}, {}, {}
    page = 0
    while page < 200:
        # Params mirror resolve-notify.py clickup_list_page so both scans see the
        # same task set + description field (the deeplink fallback in
        # _notifier_conv_id needs the description).
        q = urllib.parse.urlencode({"archived": "false", "include_closed": "true",
                                    "subtasks": "false", "order_by": "updated", "page": str(page)})
        data = clickup_get(f"{CLICKUP_API}/list/{list_id}/task?{q}", key)
        tasks = data.get("tasks", [])
        if not tasks:
            break
        for t in tasks:
            done = _ticket_customer_complete(t)
            tid = t.get("id")
            tname = t.get("name") or tid
            # A ticket resolve-notify owes a note for — record it against the
            # conversation the NOTIFIER targets so is_eligible can defer the close
            # until the notifier has processed it (seen-set). Track it whether
            # OPEN or resolved: an OPEN owned ticket is never in the seen-set, so
            # this holds the conversation open until the ticket resolves AND the
            # notifier sends its note. Gating on resolved would let a resolved
            # #417 sibling close the conversation while this ticket is still open;
            # when it later resolves, the notifier would suppress ("not-open")
            # and mark it seen — a permanent, longer-window note loss.
            if tid and _notifier_owned(t):
                owed_cid = _notifier_conv_id(t)
                if owed_cid:
                    notify_owed.setdefault(owed_cid, set()).add(tid)
            for cf in t.get("custom_fields", []):
                cid, val = cf.get("id"), cf.get("value")
                if not val:
                    continue
                if cid == USER_EMAIL_FIELD:
                    email_states.setdefault(str(val).lower().strip(), set()).add(done)
                elif cid == INTERCOM_LINK_FIELD:
                    conv_id = _conv_id_from_link(val)
                    if conv_id:
                        cs = conv_states.setdefault(
                            conv_id, {"complete": set(), "tickets": {}, "intercom_url": str(val)})
                        cs["complete"].add(done)
                        cs["intercom_url"] = str(val)
                        if tid:
                            cs["tickets"][tid] = {"name": tname, "url": CLICKUP_TASK_URL.format(tid)}
        page += 1
        if data.get("last_page"):
            break
    return email_states, conv_states, notify_owed


def fetch_open_convs(token):
    convs = []
    after = None
    while True:
        body = {"query": {"field": "state", "operator": "=", "value": "open"},
                "pagination": {"per_page": 150}}
        if after:
            body["pagination"]["starting_after"] = after
        data = intercom_search(token, body)
        for c in data.get("conversations", []):
            src = c.get("source") or {}
            au = src.get("author") or {}
            stats = c.get("statistics") or {}
            convs.append({
                "id": c.get("id"),
                "email": (au.get("email") or "").lower().strip() if au.get("type") == "user" else "",
                "lar": stats.get("last_admin_reply_at") or 0,
                "lcr": stats.get("last_contact_reply_at") or 0,
            })
        nxt = (data.get("pages") or {}).get("next")
        after = nxt.get("starting_after") if isinstance(nxt, dict) else None
        if not nxt or not after:
            break
    return convs


# Bounded, single-attempt (no retry/backoff), short timeout — unlike
# _retry_json (used by this script's own correctness-critical GETs, which
# legitimately need generous retries), this fetch feeds ONLY a best-effort
# shadow Jev sample: a failure here just means that one sample is skipped
# this run (see close_resolved_shadow_state), so it must be bounded exactly
# as tightly as the jev.sh call itself (jev_shadow.DEFAULT_TIMEOUT_S) rather
# than able to add minutes of latency chasing a single dead sample.
JEV_SHADOW_FETCH_TIMEOUT_S = 5


def get_conversation_for_shadow(conv_id, token):
    """GET /conversations/{id}?display_as=plaintext (read-only), single
    attempt, JEV_SHADOW_FETCH_TIMEOUT_S bound.

    Used ONLY to build state for the Phase 2a close-resolved shadow Jev
    sample below — this script's own real is_eligible() decision never
    depends on conversation body text (fetch_open_convs only reads
    lar/lcr timestamps). Always called from inside shadow_judge's
    build_state boundary (see close_resolved_shadow_state), so a failure
    here is caught there and never reaches the close loop itself."""
    req = urllib.request.Request(
        f"{INTERCOM_API}/conversations/{conv_id}?display_as=plaintext",
        headers={"Authorization": f"Bearer {token}", "Accept": "application/json",
                 "Intercom-Version": INTERCOM_VERSION},
        method="GET")
    with urllib.request.urlopen(req, timeout=JEV_SHADOW_FETCH_TIMEOUT_S) as resp:
        return json.load(resp)


def _text_of(part):
    body = part.get("body") if part else None
    return re.sub(r"<[^>]+>", " ", body).strip() if body else ""


def close_resolved_shadow_state(conv_id, token, linked_ticket_complete):
    """(state | None) for the close-resolved Jev question: the sampled
    conversation's most recent customer message, the admin message
    immediately before it (if any), and whether every #417-linked ticket is
    customer-complete. Fetches the conversation (network — the reason this
    is a build_state callable, not a plain dict). Returns None when the
    fetched conversation has no customer part to judge."""
    conv = get_conversation_for_shadow(conv_id, token)
    parts = (conv.get("conversation_parts") or {}).get("conversation_parts") or []
    last_customer_idx = None
    for i in range(len(parts) - 1, -1, -1):
        a = (parts[i].get("author") or {})
        if a.get("type") == "user":
            last_customer_idx = i
            break
    if last_customer_idx is None:
        return None
    preceding_admin = None
    for i in range(last_customer_idx - 1, -1, -1):
        a = (parts[i].get("author") or {})
        if a.get("type") in ("admin", "team"):
            preceding_admin = _text_of(parts[i])
            break
    return {
        "customer_message": _text_of(parts[last_customer_idx]),
        "preceding_admin_message": preceding_admin,
        "linked_ticket_customer_complete": linked_ticket_complete,
    }


def _jev_sample_size():
    raw = os.environ.get("CLOSE_RESOLVED_JEV_SAMPLE_SIZE")
    if not raw:
        return DEFAULT_JEV_SAMPLE_SIZE
    try:
        n = int(raw)
    except ValueError:
        return DEFAULT_JEV_SAMPLE_SIZE
    return n if n > 0 else DEFAULT_JEV_SAMPLE_SIZE


def is_eligible(conv, email_states, conv_states, backfill=False,
                held_ticket_ids=None, defer_convs=None):
    """Eligible to close iff we spoke last and every linked ticket is customer-complete.

    We-spoke-last is required first (excludes never_replied + customer_last).

    Then the notify→close RACE GUARD (applies to BOTH matching paths below): if
    resolve-notify still owes an unsent "your request is resolved" note for this
    conversation — a hydra-action-request ticket (open OR resolved) it has NOT
    processed (`defer_convs`, computed in main from notify_owed minus the
    seen-set) — never close. A ticket can go resolved AFTER the notifier's scan
    but before this closer's; it is absent from `held`, so without this the closer would
    silently close the conversation and the notifier's next run would suppress
    the note because the conversation is already closed (permanent notification
    loss). Deferring makes the notifier's classification authoritative; the
    conversation closes a cycle later, once the note is out. The defer set uses
    the NOTIFIER's own conversation linkage (conv_id_of: #417 field OR
    description deeplink), so it also covers tickets the closer's #417-only
    index below would miss.

    The tie to a customer-complete ticket is established, most-precise-first:
      1. PRECISE (#417 link): if this conversation id is linked to any ticket,
         that linkage is authoritative — close iff EVERY linked ticket is
         customer-complete and NONE is in resolve-notify's active batch (held).
      2. EMAIL fallback (--backfill only): for conversations with no link, the
         pre-#417 path — close iff the customer's email matches >=1 ticket and
         EVERY email-matched ticket is customer-complete.
    """
    lar, lcr = conv["lar"], conv["lcr"]
    # Strictly admin-last. Intercom timestamps are second-granular, so lar == lcr
    # is an ambiguous ordering, not proven admin-last — for an unattended silent
    # close we require lar > lcr. lar > 0 also excludes never_replied.
    if not (lar > 0 and lar > lcr):
        return False
    cid = conv["id"]
    # Race guard, BEFORE either match path: resolve-notify owes an unsent note.
    if cid in (defer_convs or set()):
        return False
    if cid in conv_states:  # precise linkage is authoritative
        linked_ids = set((conv_states[cid].get("tickets") or {}).keys())
        if linked_ids & (held_ticket_ids or set()):
            return False
        return all(conv_states[cid]["complete"])
    if not backfill:  # steady-state: precise links only, never loose email
        return False
    # Backfill is an explicit human-run compatibility path and cannot map its
    # loose email rows back to held ticket ids. Pause it conservatively while
    # any resolve-notify batch is held.
    if held_ticket_ids:
        return False
    em = conv["email"]
    return bool(em) and em in email_states and all(email_states[em])


def close_conversation(token, admin_id, conv_id):
    req = urllib.request.Request(
        f"{INTERCOM_API}/conversations/{conv_id}/parts",
        data=json.dumps({"message_type": "close", "type": "admin", "admin_id": str(admin_id)}).encode(),
        headers={"Authorization": f"Bearer {token}", "Accept": "application/json",
                 "Content-Type": "application/json", "Intercom-Version": INTERCOM_VERSION},
        method="POST")
    with urllib.request.urlopen(req, timeout=30) as resp:
        return json.load(resp)


def open_shadow_log():
    path = os.environ.get("CLOSE_SHADOW_LOG", "/var/log/close-resolved-shadow.jsonl")
    try:
        return open(path, "a"), path
    except OSError:
        fallback = "/tmp/close-resolved-shadow.jsonl"
        try:
            return open(fallback, "a"), fallback
        except OSError:
            return None, None


def _slack_escape(s):
    """Escape free text for Slack mrkdwn, esp. inside <url|text> link labels.

    Per Slack's API the only characters to escape are & < > — in that order so
    the & in the entities isn't itself re-escaped. A ClickUp ticket title like
    "Refund <urgent> & stuff" would otherwise break the link rendering.
    """
    return str(s).replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def format_slack_summary(closed, conv_states, when, shadow_path=None, max_lines=SUMMARY_MAX_LINES):
    """Slack mrkdwn summary of the conversations closed this run.

    `closed` is the list of closed conv dicts (id, email). Hyperlinks use Slack
    mrkdwn `<url|text>` (blue clickable text). Conversations with no #417 link
    (email-backfill closes) degrade to plain conv-id text — never a broken link.
    """
    n = len(closed)
    plural = "" if n == 1 else "s"
    lines = [f":white_check_mark: *Closed {n} resolved-ticket conversation{plural}* — {when}"]
    for c in closed[:max_lines]:
        meta = conv_states.get(c["id"]) or {}
        url = meta.get("intercom_url")
        conv_ref = f"<{url}|conversation {c['id']}>" if url else f"conversation {c['id']}"
        tickets = meta.get("tickets") or {}
        ticket_refs = (", ".join(f"<{t['url']}|{_slack_escape(t['name'])}>" for t in tickets.values())
                       if tickets else "_no linked ticket_")
        lines.append(f"• {conv_ref} — {ticket_refs} ({_slack_escape(c.get('email') or 'no email')})")
    if n > max_lines:
        lines.append(f"…and {n - max_lines} more")
    if shadow_path:
        lines.append(f"_Reversible — full log: {shadow_path}_")
    return "\n".join(lines)


def _read_slack_token(config_path, account):
    """Read a Slack bot token from an openclaw config (channels.slack.accounts.<account>)."""
    try:
        with open(config_path) as f:
            cfg = json.load(f)
        from lib.slack_token import resolve_secret
        return resolve_secret(cfg["channels"]["slack"]["accounts"][account]["botToken"])
    except (OSError, KeyError, ValueError, TypeError):
        return None


def post_slack_summary(text, channel, config_path, account):
    """Best-effort post to Slack. NEVER raises — the closes already happened and
    are shadow-logged, so a Slack failure must not fail the run. Returns bool."""
    token = _read_slack_token(config_path, account)
    if not token:
        print(f"WARN: no Slack token for account '{account}' in {config_path}; notify skipped", file=sys.stderr)
        return False
    try:
        req = urllib.request.Request(
            SLACK_API,
            data=json.dumps({"channel": channel, "text": text,
                             "unfurl_links": False, "unfurl_media": False}).encode(),
            headers={"Authorization": f"Bearer {token}",
                     "Content-Type": "application/json; charset=utf-8"},
            method="POST")
        with urllib.request.urlopen(req, timeout=20) as resp:
            body = json.load(resp)
        if not body.get("ok"):
            print(f"WARN: Slack post failed: {body.get('error')}", file=sys.stderr)
            return False
        return True
    except Exception as e:  # noqa: BLE001 — best-effort by contract: a read
        # timeout (socket.timeout/TimeoutError), connection reset (OSError),
        # IncompleteRead (http.client.HTTPException) or bad JSON must NOT fail
        # the run after conversations were already closed + shadow-logged.
        print(f"WARN: Slack post error: {type(e).__name__}: {str(e)[:140]}", file=sys.stderr)
        return False


def should_notify(apply, notify_enabled, ok):
    """Gate for the #cs_chats summary: only a real (--apply) run that closed >=1."""
    return bool(apply and notify_enabled and ok > 0)


def main():
    ap = argparse.ArgumentParser(description="Silently close conversations whose ClickUp ticket is customer-complete")
    ap.add_argument("--apply", action="store_true", help="actually close (default: dry-run)")
    ap.add_argument("--backfill", action="store_true",
                    help="also close pre-#417 conversations matched loosely by email")
    ap.add_argument("--limit", type=int, default=0, help="cap closes this run (0 = no cap)")
    ap.add_argument("--notify", action="store_true",
                    help="post a #cs_chats summary after an --apply run that closed >=1")
    args = ap.parse_args()

    token = os.environ.get("MUSOAI_INTERCOM_TOKEN")
    key = os.environ.get("CLICKUP_API_KEY")
    if not token or not key:
        print("ERROR: MUSOAI_INTERCOM_TOKEN and CLICKUP_API_KEY are required", file=sys.stderr)
        return 1
    admin_id = resolve_admin_id()
    list_id = os.environ.get("CLICKUP_LIST_ID", DEFAULT_LIST_ID)
    resolve_state = os.environ.get(
        "RESOLVE_NOTIFY_STATE", "/var/lib/resolve-notify/notified.json")
    held_ticket_ids = load_held_ticket_ids(resolve_state)
    seen_ticket_ids = load_seen_ticket_ids(resolve_state)
    if held_ticket_ids is None or seen_ticket_ids is None:
        print("ERROR: resolve-notify state is unreadable; refusing silent closes",
              file=sys.stderr)
        return 1

    email_states, conv_states, notify_owed = build_ticket_index(key, list_id)
    # Conversations resolve-notify still owes an unsent note for: it has a
    # resolved hydra-action-request ticket the notifier has NOT processed yet
    # (owed minus seen). Closing any of these would drop the customer note, so
    # is_eligible defers them on both the precise and backfill paths.
    defer_convs = {cid for cid, owed in notify_owed.items()
                   if owed - seen_ticket_ids}
    convs = fetch_open_convs(token)
    eligible = [c for c in convs if is_eligible(
        c, email_states, conv_states, args.backfill, held_ticket_ids, defer_convs)]

    mode = "precise #417 link + email backfill" if args.backfill else "precise #417 link only"
    print(f"matching mode: {mode}")
    print(f"resolved-ticket conversation links: {len(conv_states)}")
    print(f"held resolve-notify tickets excluded: {len(held_ticket_ids)}")
    print(f"resolve-notify processed (seen) tickets: {len(seen_ticket_ids)}")
    print(f"deferred (resolve-notify owes an unsent note): {len(defer_convs)}")
    print(f"open conversations scanned: {len(convs)}")
    print(f"eligible (linked ticket customer-complete AND we replied last): {len(eligible)}")

    # Shadow-only (Phase 2a #2a): fires strictly AFTER is_eligible() above, on
    # a RANDOM sample of the FULL open-conversation scan (never the head),
    # and can never change `eligible`, closes, stdout, or the exit code. A
    # fresh, non-fixed seed each run is logged to stderr so a run can be
    # reproduced. See docs/plans/jev-adoption.md #2a and
    # CLOSE_RESOLVED_JEV_SAMPLE_SIZE above.
    eligible_ids = {c["id"] for c in eligible}
    jev_k = min(_jev_sample_size(), len(convs))
    if jev_k > 0:
        jev_seed = random.SystemRandom().randrange(2 ** 32)
        print(f"jev shadow sample: seed={jev_seed} size={jev_k} "
              f"(pool={len(convs)})", file=sys.stderr)
        for c in random.Random(jev_seed).sample(convs, jev_k):
            linked_complete = (all(conv_states[c["id"]]["complete"])
                                if c["id"] in conv_states else None)
            shadow_judge(JEV_SURFACE_CLOSE_RESOLVED, c["id"],
                         lambda cid=c["id"], lc=linked_complete:
                             close_resolved_shadow_state(cid, token, lc),
                         CLOSE_RESOLVED_QUESTIONS,
                         actual=("eligible" if c["id"] in eligible_ids else "not-eligible"))

    if not args.apply:
        for c in eligible[:15]:
            print(f"  would close conv={c['id']} email={c['email']}")
        if len(eligible) > 15:
            print(f"  ... and {len(eligible) - 15} more")
        print("DRY-RUN — no conversations closed. Re-run with --apply to close.")
        return 0

    targets = eligible[:args.limit] if args.limit > 0 else eligible
    shadow, shadow_path = open_shadow_log()
    closed, fail = [], []
    for c in targets:
        try:
            res = close_conversation(token, admin_id, c["id"])
            if shadow:
                shadow.write(json.dumps({"id": c["id"], "closed_at": int(time.time()),
                                         "email": c["email"], "new_state": res.get("state")}) + "\n")
                shadow.flush()
            closed.append(c)
        except (urllib.error.URLError, ValueError) as e:
            fail.append((c["id"], str(e)[:140]))
        time.sleep(0.3)
    if shadow:
        shadow.close()
    ok = len(closed)
    print(f"closed_ok={ok} failed={len(fail)} (shadow log: {shadow_path})")
    for f in fail[:15]:
        print(f"  FAIL {f}", file=sys.stderr)

    notify_enabled = args.notify or os.environ.get("CLOSE_NOTIFY") == "1"
    if should_notify(args.apply, notify_enabled, ok):
        when = time.strftime("%Y-%m-%d %H:%M UTC", time.gmtime())
        text = format_slack_summary(closed, conv_states, when, shadow_path)
        channel = os.environ.get("CLOSE_SUMMARY_CHANNEL", DEFAULT_SUMMARY_CHANNEL)
        cfg = os.environ.get("SLACK_NOTIFY_CONFIG", "/root/.openclaw-main/openclaw.json")
        account = os.environ.get("CLOSE_SUMMARY_SLACK_ACCOUNT", "operations")
        posted = post_slack_summary(text, channel, cfg, account)
        print(f"slack notify: {'posted' if posted else 'skipped/failed'} -> {channel}")

    return 3 if fail else 0


if __name__ == "__main__":
    sys.exit(main())
