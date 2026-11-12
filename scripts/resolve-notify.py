#!/usr/bin/env python3
"""Proactively tell a customer when their request is verified complete.

The close-the-loop counterpart of overdue-verification-notifier.py. Today
close-resolved-conversations.py SILENTLY closes an Intercom conversation once
its ClickUp ticket(s) are customer-complete — the customer is never told "it's
done", so a finished request just goes quiet. This sends ONE in-app Intercom
reply per newly customer-complete ticket: "good news, your request is sorted."
The existing close-resolved batch then closes the conversation (the notify makes us
"we spoke last", which is close-resolved's gate).

This is CUSTOMER-FACING OUTBOUND, so the design is safety-first and mirrors the
overdue notifier exactly. It must never message the wrong person, the same
person twice, or about a conversation that is already closed, and a wiped state
file must not blast the whole customer-complete backlog.

Eligibility (every gate must pass; any fail -> skip + count the reason):
  1. ClickUp list 901000600160, tag `hydra-action-request`, exactly one
     `action:<type>` and it is in the Tier-1 verification allowlist (ALLOWLIST).
  2. CUSTOMER COMPLETE — ClickUp work is terminal (but not `impossible`) AND
     the ticket carries exactly one valid `customer-outcome:*` tag whose value
     is `complete`. A terminal status alone fails closed.
  3. Recover the Intercom conversation id from the #417 "Intercom Link" custom
     field, else an anchored parse of the description deeplink. Missing -> skip.
  4. Per-conversation dedupe: one customer may have several complete tickets but
     ONE conversation -> at most one "done" message per conversation, this run
     AND ever (persistent state keyed on both ticket id and `conv:<id>`).
  5. Fresh GET /conversations/{id} right before sending, then:
       - email cross-check: conv `source.author.email` must equal the ticket's
         `customer_email`; mismatch -> skip (wrong-customer guard).
       - suppress if a human admin replied last (they likely already told the
         customer), the conversation is assigned to a non-bot human, its state
         != open (closed/snoozed -> never reopen with a "done" note), or it
         carries a social / abuse-block tag. A customer who spoke LAST is NOT
         suppressed here — a completed request where the customer is waiting on
         us is exactly who should hear it's done.

Cold-start: on the FIRST run (no, or empty, state file), seed ALL currently-
complete tickets+conversations as already-seen and send NOTHING. Thereafter
only tickets that become customer-complete are candidates. Per-run cap (MAX) bounds any
blast; sending is gated behind `--apply` (default dry-run). A newly-observed
batch above MAX is persisted and held for one run; later runs drain that exact
snapshot at MAX only after one warning is confirmed delivered. State writes
carry a versioned checksum, so actual state damage fails closed into the cold-
start seed path instead of being guessed from the file's mtime.

Env:
  CLICKUP_API_KEY                 required
  MUSOAI_INTERCOM_TOKEN           required
  INTERCOM_ADMIN_ID              ignored unless it is 5763097 (Caroline); the posting identity is fixed
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
  --migrate-legacy-state
                atomically upgrade the pre-checksum state and exit; no API calls

Exit codes: 0 ok; 1 usage/env error; 2 self-test failed; 3 at least one ticket
failed mid-run.
"""
import argparse
import fcntl
import hashlib
import hmac
import json
import os
import re
import socket
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from lib import clickup_client  # noqa: E402
from lib.customer_outcome import customer_complete, workflow_terminal  # noqa: E402
from lib.intercom_identity import resolve_admin_id  # noqa: E402
from lib.jev_shadow import shadow_judge  # noqa: E402
from outbound_copy import sendgate  # noqa: E402

# The copy gate's name for this family (scripts/outbound_copy/sendgate.py).
COPY_FAMILY = COPY_CAMPAIGN = "resolve-notify"

INTERCOM_API = "https://api.intercom.io"
INTERCOM_VERSION = "2.11"
CLICKUP_API = os.environ.get("CLICKUP_API", "https://api.clickup.com/api/v2")

# Phase 2a shadow-only Jev surface (docs/plans/jev-adoption.md #2a). Judges
# whether the customer's own last message actually closes the loop, so the
# shadow report can compare Jev's read against this script's real suppress
# decision without influencing it in any way (the call happens strictly AFTER
# `conversation_suppressed()` below, never before or instead of it).
JEV_SURFACE_CS_CLOSER = "cs-closer"
CS_CLOSER_QUESTIONS = {
    "last_customer_message_is_closer": {
        "type": "noul",
        "instructions": (
            "State carries the customer's most recent message in this "
            "conversation as `customer_message`, and — when one exists — the "
            "admin's message immediately BEFORE it as `preceding_admin_message`. "
            "Decide whether the customer's message genuinely closes the loop "
            "(e.g. thanks, confirms it's resolved, says no further help is "
            "needed) rather than just replying to something the admin asked. "
            "You MUST weigh `preceding_admin_message`: if the admin asked a "
            "yes/no question, a bare 'ok', 'yes', or 'thanks' from the customer "
            "is CONSENT to that question, not a closer. A bare link, or a "
            "message like 'urgent' or 'please help', is NEVER a closer even "
            "though it is the last customer message."
        ),
        "criteria": {
            "true": "The customer's message genuinely signals the conversation is finished/resolved from their side.",
            "false": "The customer's message does not signal closure (an answer to the admin's question, a bare link, an urgency ping, or a new ask).",
        },
    },
}

CAROLINE_ADMIN_ID = "5763097"
DEFAULT_LIST_ID = "901000600160"
SERVER_TAG = "customer-outcome:complete"  # required by customer_complete (gate 4 of extract_candidate)
# "Intercom Link" custom field (#417); value is the conversation deeplink
# https://app.intercom.com/a/inbox/<ws>/inbox/conversation/<convId>.
INTERCOM_LINK_FIELD = os.environ.get(
    "CLICKUP_INTERCOM_LINK_FIELD_ID", "c32dbf6e-f680-4ff1-a532-192bb96245c3")
# Canonical shared copy: scripts/lib/intercom_link.py — keep this in sync with it.
_CONV_ID_RE = re.compile(r"/conversation/([^/?#\s\"']+)")

# Only proactively reach out about verification-class work the customer was
# promised a review on — the SAME set the overdue notifier uses. analytics-
# followup is included now that the 2026-04 analytics migration is complete and
# analytics is handled per-account like any other Tier-1 follow-up (carve-out
# retired 2026-06-30; see workspaces/support/SOUL.md "Analytics handling" and
# docs/lessons/muso-domain.md).
ALLOWLIST = {
    "credit-verify", "credit-claim", "credit-correction", "credit-removal",
    "profile-claim", "analytics-followup",
    # 2026-11-03: added by the bulk-credit-change drainer (#drainer spec item 4).
    # PLACEMENT, not new wording: it reuses MESSAGE verbatim, because the line is
    # the same "it's all sorted now on our side" note every other completed
    # action type already sends. The drainer only tags `complete` when EVERY row
    # it was asked to change was read back verified; a batch that half-landed is
    # tagged `partial` and is not in this set, so it never reaches this sender.
    "bulk-credit-change",
}
# Conversation tags that mean "do not auto-message here".
BLOCKED_CONV_TAGS = {
    "abuse-block", "instagram", "facebook", "twitter", "x",
    "whatsapp", "messenger", "tiktok", "sms",
}

MAX_PAGES = 200
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
    # status would be invisible: never cold-start seeded, never notified.
    #
    # tags[]=SERVER_TAG: the one server-side filter, taken from a gate
    # extract_candidate already requires, so it drops only tasks that could never
    # be candidates (lossless; measured 29 Oct: 5 pages vs 138 unfiltered, same
    # 17 candidates, vs 111 pages for hydra-action-request). It deliberately differs from
    # close-resolved-conversations.py, which must see EVERY ticket's Intercom link
    # for its index. Not a date_updated_gt watermark: the bulk guard needs every
    # held id in this run's scan, and a windowed cold-start seed would let an old
    # resolved ticket look new. If the gate in extract_candidate changes, change
    # SERVER_TAG with it.
    q = urllib.parse.urlencode(
        {"archived": "false", "include_closed": "true",
         "subtasks": "false", "order_by": "updated", "page": str(page),
         "tags[]": SERVER_TAG})
    s, body = clickup_client.shared(key, CLICKUP_API).request(
        "GET", f"/list/{list_id}/task?{q}")
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
    # No reviewer verdict bound to these exact bytes, no POST: raises sendgate.NotApproved.
    permit = sendgate.require_verdict(message, family=COPY_FAMILY, campaign=COPY_CAMPAIGN,
                                      copy="resolved-v1", message_type="comment", ref=conv_id)
    s, body = http("POST", f"{INTERCOM_API}/conversations/{conv_id}/reply",
                   _ic_headers(token),
                   body={"message_type": "comment", "type": "admin",
                         "admin_id": str(admin_id), "body": message})
    if s not in (200, 201):
        raise RuntimeError(f"intercom reply {conv_id} -> {s}: {body}")
    sendgate.record_sent(permit, ref=conv_id,
                         message_id=(body or {}).get("id", "") if isinstance(body, dict) else "")
    return body


# --------------------------------------------------------------------------
# Pure logic (no network — directly unit-testable).
# --------------------------------------------------------------------------
def _ticket_customer_complete(t):
    """True only when workflow and customer-visible outcome are complete."""
    return customer_complete(t)


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
    if not workflow_terminal(task):
        return None, "not-resolved"
    if not _ticket_customer_complete(task):
        return None, "customer-outcome"
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


def _text_of(part):
    body = part.get("body") if part else None
    return re.sub(r"<[^>]+>", " ", body).strip() if body else ""


def last_customer_message_state(conv):
    """(state | None) for the cs-closer Jev question: the last customer part's
    text plus the admin part immediately before it, if any. Pure/no network —
    reads only the conversation_parts already present on `conv`. Returns None
    when there is no customer part to judge (nothing to shadow-judge)."""
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
    }


# --------------------------------------------------------------------------
# Persistent state (atomic; seed on absent).
# --------------------------------------------------------------------------
def load_state(path):
    try:
        with open(path) as f:
            state = json.load(f)
    except FileNotFoundError:
        return None
    except (OSError, ValueError):
        # A corrupt/truncated state file is NOT treated as "seeded" — return
        # None so the caller re-seeds (sends nothing) rather than mass-sending.
        return None
    if not isinstance(state, dict):
        return None

    # Normal operation is strict. The one pre-v2 production state is upgraded
    # explicitly by --migrate-legacy-state during unit installation; retaining
    # an implicit legacy path here would let removal of BOTH metadata fields
    # masquerade as a valid old state forever.
    version = state.get(STATE_VERSION_KEY)
    expected = state.get(STATE_CHECKSUM_KEY)
    if version != STATE_VERSION or not isinstance(expected, str) \
            or not hmac.compare_digest(expected, _state_checksum(state)):
        return None

    backlog = state.get(BULK_BACKLOG_KEY)
    if backlog is not None:
        ids = backlog.get("ticket_ids") if isinstance(backlog, dict) else None
        first_seen = backlog.get("first_seen_at") if isinstance(backlog, dict) else None
        alerted = backlog.get("alerted") if isinstance(backlog, dict) else None
        if not isinstance(ids, list) or any(not isinstance(tid, str) for tid in ids) \
                or not isinstance(first_seen, (int, float)) \
                or not isinstance(alerted, bool):
            return None
    return state


def _state_checksum(state):
    payload = {k: v for k, v in state.items() if k != STATE_CHECKSUM_KEY}
    raw = json.dumps(payload, ensure_ascii=False, separators=(",", ":"),
                     sort_keys=True).encode()
    return hashlib.sha256(raw).hexdigest()


def write_state(path, state):
    """Atomic rewrite (tmp + os.replace) so a crash never leaves a partial file."""
    state[STATE_VERSION_KEY] = STATE_VERSION
    state[STATE_CHECKSUM_KEY] = _state_checksum(state)
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    tmp = f"{path}.tmp.{os.getpid()}"
    with open(tmp, "w") as f:
        json.dump(state, f)
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, path)
    _mark_state_v2(path)


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
STATE_VERSION = 2
STATE_VERSION_KEY = "__state_version__"
STATE_CHECKSUM_KEY = "__state_checksum__"
BULK_BACKLOG_KEY = "__bulk_backlog__"
STATE_MIGRATION_MARKER_SUFFIX = ".v2-migrated"


def _mark_state_v2(path):
    marker = f"{path}{STATE_MIGRATION_MARKER_SUFFIX}"
    if os.path.exists(marker):
        return
    tmp = f"{marker}.tmp.{os.getpid()}"
    with open(tmp, "w") as f:
        f.write(f"{STATE_VERSION}\n")
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, marker)


def _acquire_state_lock(path):
    """Hold a nonblocking process lock for the complete read/send/write cycle."""
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    lock_file = open(f"{path}.lock", "a+")
    try:
        fcntl.flock(lock_file, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        lock_file.close()
        return None
    return lock_file


def migrate_legacy_state(path):
    """One-shot, offline upgrade of the known flat pre-v2 state schema."""
    lock_file = _acquire_state_lock(path)
    if lock_file is None:
        print("resolve-notify: state migration skipped; another run holds the lock",
              file=sys.stderr)
        return 1
    try:
        with open(path) as f:
            legacy = json.load(f)
    except FileNotFoundError:
        print("resolve-notify: no legacy state to migrate")
        return 0
    except (OSError, ValueError) as e:
        print(f"resolve-notify: legacy state migration refused: {type(e).__name__}",
              file=sys.stderr)
        return 1

    if load_state(path) is not None:
        _mark_state_v2(path)
        print("resolve-notify: state already uses checksum format")
        return 0
    if os.path.exists(f"{path}{STATE_MIGRATION_MARKER_SUFFIX}"):
        print("resolve-notify: legacy state migration refused: v2 was already established",
              file=sys.stderr)
        return 1
    reserved = {STATE_VERSION_KEY, STATE_CHECKSUM_KEY, BULK_BACKLOG_KEY}
    valid = (isinstance(legacy, dict)
             and isinstance(legacy.get(SEED_SENTINEL), (int, float))
             and not (reserved & set(legacy))
             and all(isinstance(value, (int, float)) for value in legacy.values()))
    if not valid:
        print("resolve-notify: legacy state migration refused: unexpected schema",
              file=sys.stderr)
        return 1
    write_state(path, legacy)
    print(f"resolve-notify: migrated legacy state ({len(legacy) - 1} seen keys)")
    return 0


def prune_state(state, now_epoch, keep_days=90):
    cutoff = now_epoch - keep_days * 86400
    reserved = {SEED_SENTINEL, STATE_VERSION_KEY, BULK_BACKLOG_KEY}
    return {k: v for k, v in state.items()
            if k in reserved or (isinstance(v, (int, float)) and v >= cutoff)}


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

    resolved = dict(base, status={"type": "done", "status": "complete"},
                    tags=base["tags"] + [{"name": "customer-outcome:complete"}])
    c, r = extract_candidate(resolved, now_epoch)
    assert c and r is None and c["conv_id"] == "C1" and c["email"] == "a@b.com", ("resolved", c, r)

    open_t = dict(base, status={"type": "open", "status": "in progress"})
    c, r = extract_candidate(open_t, now_epoch)
    assert c is None and r == "not-resolved", ("open-not-dropped", c, r)

    no_outcome = dict(base, status={"type": "done", "status": "resolved"})
    c, r = extract_candidate(no_outcome, now_epoch)
    assert c is None and r == "customer-outcome", ("missing-outcome-not-dropped", c, r)

    impossible = dict(base, status={"type": "done", "status": "impossible"},
                      tags=base["tags"] + [{"name": "customer-outcome:complete"}])
    c, r = extract_candidate(impossible, now_epoch)
    assert c is None and r == "customer-outcome", ("impossible-not-dropped", c, r)

    refund = dict(base, status={"type": "done", "status": "complete"},
                  tags=[{"name": "hydra-action-request"}, {"name": "action:subscription-refund"}])
    c, r = extract_candidate(refund, now_epoch)
    assert c is None and r == "action-type", ("tier3-not-excluded", c, r)

    # A whitespace-only customer_email must fail CLOSED (no-email), not pass as "".
    ws = dict(base, status={"type": "done"},
              tags=base["tags"] + [{"name": "customer-outcome:complete"}],
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
        from lib.slack_token import resolve_secret
        return resolve_secret(cfg["channels"]["slack"]["accounts"][account]["botToken"])
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
    """Every task of the list. A scan that does not reach last_page raises: a
    partial list must never reach the send loop."""
    tasks, page = [], 0
    while page < MAX_PAGES:
        body = clickup_list_page(key, list_id, page)
        batch = body.get("tasks", [])
        if not batch:
            break
        tasks.extend(batch)
        if body.get("last_page"):
            break
        page += 1
    else:
        raise RuntimeError(f"clickup list {list_id}: no last_page after {MAX_PAGES} pages; "
                           f"refusing a partial scan")
    return tasks


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--apply", action="store_true",
                    help="actually send (default: dry-run)")
    ap.add_argument("--limit", type=int, default=0,
                    help="override the per-run send cap")
    ap.add_argument("--self-test", action="store_true",
                    help="run the inline detector self-test and exit")
    ap.add_argument("--migrate-legacy-state", action="store_true",
                    help="upgrade the pre-checksum state and exit")
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

    state_path = os.environ.get(
        "RESOLVE_NOTIFY_STATE", "/var/lib/resolve-notify/notified.json")
    if args.migrate_legacy_state:
        return migrate_legacy_state(state_path)

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
    admin_id = resolve_admin_id()
    list_id = os.environ.get("CLICKUP_LIST_ID", DEFAULT_LIST_ID)
    default_max = int(os.environ.get("RESOLVE_NOTIFY_MAX", "25"))
    # `--limit` may raise the normal per-run cap, but it cannot raise either the
    # bulk threshold or a held backlog's drain cap.
    cap = args.limit if args.limit > 0 else default_max
    bulk_cap = min(cap, default_max)

    # systemd serializes its own timer starts, but a manual invocation can race
    # it. Hold this descriptor for the full function so two apply runs can never
    # select and message the same pending prefix.
    _lock_file = None
    if args.apply:
        _lock_file = _acquire_state_lock(state_path)
        if _lock_file is None:
            print("resolve-notify: another run holds the state lock; skipping")
            return 0

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
    new_by_id = {str(c["ticket_id"]): c for c in new}

    # ---- Bulk guard: a legitimate batch resolution and a tagging mistake look
    # identical on first observation. Freeze the exact batch, hold it for one
    # run, and confirm ONE accurate warning before it becomes drainable. Tickets
    # discovered later stay outside this snapshot; after it clears they receive
    # their own normal/bulk classification. Integrity comes from the checksum,
    # never mtime.
    bulk = state.get(BULK_BACKLOG_KEY)
    dirty = False
    if bulk:
        pending_ids = [tid for tid in bulk["ticket_ids"] if tid in new_by_id]
        if not pending_ids:
            state.pop(BULK_BACKLOG_KEY, None)
            bulk = None
            dirty = True

    if bulk:
        if not bulk["alerted"]:
            text = _bulk_warning(len(pending_ids), default_max)
            print(text, file=sys.stderr)
            if args.apply and _post_anomaly(text):
                bulk["alerted"] = True
                write_state(state_path, state)
            return 0
        to_send = [new_by_id[tid] for tid in pending_ids[:bulk_cap]]
    elif len(new) > default_max:
        if args.apply:
            state[BULK_BACKLOG_KEY] = {
                "first_seen_at": now_epoch,
                "ticket_ids": list(new_by_id),
                "alerted": False,
            }
            write_state(state_path, state)
        text = _bulk_warning(len(new), default_max, preview=not args.apply)
        print(text, file=sys.stderr)
        if args.apply and _post_anomaly(text):
            state[BULK_BACKLOG_KEY]["alerted"] = True
            write_state(state_path, state)
        return 0
    else:
        to_send = new[:cap]

    # A dry-run is a PURE preview: it never mutates the persistent state. All
    # state writes below are gated on args.apply.
    seen_convs = set()
    completed_ids = set()
    sent, failed = 0, 0
    held, held_reason = 0, ""
    for i, c in enumerate(to_send):
        try:
            if c["conv_id"] in seen_convs or f"conv:{c['conv_id']}" in state:
                suppressed["dedup-conv"] = suppressed.get("dedup-conv", 0) + 1
                if args.apply:
                    mark_seen(state, c, now_epoch)
                    dirty = True
                completed_ids.add(str(c["ticket_id"]))
                continue
            conv = get_conversation(c["conv_id"], token)
            reason = conversation_suppressed(conv, c["email"], admin_id)
            # Shadow-only (Phase 2a #2a): fires strictly AFTER the real decision
            # above and can never change it, `reason`, `to_send`, stdout, or the
            # exit code. See docs/plans/jev-adoption.md #2a. State is built
            # lazily inside shadow_judge's never-raise boundary (a build_state
            # callable, not a pre-built dict) — last_customer_message_state()
            # can raise on a malformed conv, and evaluating it as a bare
            # argument here would raise BEFORE shadow_judge's own try is ever
            # entered. build_state returning None (no customer part at all)
            # is a legitimate no-op, not a failure.
            shadow_judge(JEV_SURFACE_CS_CLOSER, c["conv_id"],
                         lambda conv=conv: last_customer_message_state(conv),
                         CS_CLOSER_QUESTIONS,
                         actual=("sent" if not reason else f"suppressed:{reason}"))
            if reason:
                suppressed[reason] = suppressed.get(reason, 0) + 1
                if args.apply:
                    # Record ticket-level seen so we don't re-GET it every run,
                    # but do NOT mark the conv seen — a later legit ticket on
                    # this conv may still deserve a message once it reopens.
                    state[c["ticket_id"]] = now_epoch
                    dirty = True
                completed_ids.add(str(c["ticket_id"]))
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
            completed_ids.add(str(c["ticket_id"]))
            sent += 1
        except sendgate.NotApproved as e:
            # Nothing was posted and nothing is marked seen, so the closer still defers this
            # conversation (it reads the same state) and the next run offers the ticket again.
            # The copy is one fixed constant: this answer is the answer for every candidate left.
            held, held_reason = len(to_send) - i, e.reason
            print(f"[{c['ticket_id']}] HELD by the copy gate ({e.result}): {e.reason}; "
                  f"{held} candidate(s) not sent this run", file=sys.stderr)
            if e.result == "error":
                failed += 1     # the gate could not answer: the run is a failure, not a quiet skip
            break
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

    bulk_remaining = 0
    if bulk:
        unattempted_ids, attempted_ids = [], []
        attempted = {str(c["ticket_id"]) for c in to_send}
        for tid in bulk["ticket_ids"]:
            cand = new_by_id.get(tid)
            if cand and not already_seen(state, cand) and tid not in completed_ids:
                (attempted_ids if tid in attempted else unattempted_ids).append(tid)
        remaining_ids = unattempted_ids + attempted_ids
        bulk_remaining = len(remaining_ids)
        if args.apply:
            if remaining_ids:
                bulk["ticket_ids"] = remaining_ids
            else:
                state.pop(BULK_BACKLOG_KEY, None)
            dirty = True

    if args.apply and dirty:
        write_state(state_path, prune_state(state, now_epoch))

    backlog = bulk_remaining > 0 or (not bulk and len(new) > cap)
    print(f"resolve-notify: scanned={len(tasks)} candidates={len(candidates)} "
          f"new={len(new)} {'sent' if args.apply else 'would-send'}={sent} "
          f"failed={failed} held={held}{' (' + held_reason + ')' if held else ''} "
          f"capped={backlog} bulk_remaining={bulk_remaining} "
          f"suppressed={json.dumps(suppressed, sort_keys=True)}")
    _summary(args, sent=sent, scanned=len(tasks), candidates=len(candidates),
             suppressed=suppressed,
             note=(f"{held} held by the copy gate: {held_reason}" if held
                   else "bulk-drain" if bulk else ("capped" if backlog else "")),
             anomaly=held > 0 or suppressed.get("email-mismatch", 0) > 0)
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
    return post_slack(text, channel, cfg, account)


def _bulk_warning(count, default_max, preview=False):
    if preview:
        return (f"resolve-notify would hold {count} newly customer-complete "
                f"tickets in "
                f"apply mode because this exceeds the {default_max}-ticket "
                f"automatic threshold. Dry-run sent nothing and changed no state.")
    return (f":warning: resolve-notify held {count} newly customer-complete "
            f"tickets for "
            f"one run; this exceeds the {default_max}-ticket automatic "
            f"threshold. Sent nothing. State is readable, the timer remains "
            f"enabled, and later runs will drain at up to {default_max} per run after this "
            f"warning is delivered.")


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
