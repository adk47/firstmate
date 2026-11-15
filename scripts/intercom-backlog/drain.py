#!/usr/bin/env python3
"""Drain the customer-last Intercom backlog: one fixed, true line per thread, as Caroline.

Captain 2026-11-13: "issues like this need responses by caroline and she isn't responding ... look at
all the intercom messages without responses". On that day 1,669 open conversations had the customer as
the last speaker by the sentinel's rule (`intercom_customer_last`) for more than 4 hours. Read thread
by thread, 953 were not owed anything (914 end on our own reply, 865 of them posted as the workspace
bot Caroline's answers went out under before she had a seat, which the statistics flag does not count),
610 were owed an answer and 106 were billing, erasure or legal. Nothing in the plugin answers a thread
until the customer writes again, so the 610 would wait for ever. This is the sender for them.

WHAT IT SENDS. One of the fixed bodies in LINES, chosen by code from facts read at send time:

  no-account        no single Muso account resolves from the contact: write from your account email
  credits-approved  every credit request on the account is approved, none open
  credits-decided   every request is decided, some approved and some declined
  no-request        no credit request and no pending claim on the account
  late-reply        the thread is not about a request's status and has been quiet over 30 days: we did
                    not answer, reply if you still need help (Caroline answers that reply herself)
  stale-close       the customer has been silent for over 90 days and we wrote last: a short note,
                    then the conversation is closed (it opens again when they reply)

WHAT IT NEVER SENDS. An account with an open credit request or a pending claim is NOT answered here:
the verification senders own it (`proof-need-ask`, `uvn-status`, `status-doc-received`, `claim-status`
through scripts/intercom-verify-request.sh), and there is exactly one reviewed ask path. Those rows are
listed as `owner` with the campaign that owns them. An account line (the `credits-*` / `no-request`
lines) goes only to a thread that asks where a request stands: a request for a merge, a removal or a
stats fix is not answered by "every request is approved".

AN OPEN PROMISE. The monitor's ledger lists what we told a customer we would do (`commitments`, read at
plan time and again at send time). A fixed line goes on a thread with an open promise only when that line
IS the promised update (PROMISE_MET_BY: the three every-request-decided lines, for a credit-verification
or request-status promise). Any other line would answer a customer who is waiting on a merge, a hidden
profile or a person with an unrelated sentence, so the row is listed `caroline` / `open_promise` and, when
the customer spoke last, handed back. A promise that opened after the plan skips the row under its own
counted reason; the next plan routes it.

THE HAND-BACK. A customer-last thread no fixed line can answer is handed to Caroline's own live turn
instead of being left open: every `caroline` row (a specific ask written in the last 30 days, or an open
promise no line here keeps) and every `owner` row whose customer wrote in the last 30 days. For each, after the same send-time re-checks, this
posts ONE internal note as Caroline beginning with HANDBACK_MARKER, naming the reason code and the class. ONE
note per thread, ever (firstmate 2026-11-14 12:32Z): no repeats and no retry policy. The note is an ATTEMPT,
not a delivery — the conversation itself is the record. `read_thread` reports the newest marker note
(`handback_note_at`), and at plan time a thread carrying one is `handback_confirmed` when a worded comment of
ours is dated after it, `handback_pending` inside HANDBACK_UNCONFIRMED_AFTER_S, and `handback_unconfirmed`
past it (ids in the plan, and printed by the next send run from a read of the thread made in that run, never
from the plan's copy). Unconfirmed is owed and it is visible; nothing re-posts and nothing is ever called
delivered without that reply.
The plugin (conversation.admin.noted) sees that note, reads the thread live and runs Caroline's ordinary
customer-message path. Older `owner` rows stay with their campaign. Billing, legal, erasure and hand-read
threads are listed as `separate`, and so is any thread the monitor shapes as an erasure request, a legal
notice or a refund dispute whatever its census topic says (SEPARATE_SHAPES; the shape is read again in the
run). A thread held by a person or by the escalation queue, a restricted contact, and a user the fraud lens
holds get nothing.

WHO HOLDS THE THREAD (the monitor's ONE who-is-who rule: policies/caroline-shapes.json
`monitor.non_human_admin_ids` / `staffed_team_ids`, falling back to caroline_monitor.rules). Caroline ->
"caroline". Any other id on that non-human list (the Operator bot) -> "bot", Caroline-side. Any other admin
-> "person". No admin and the escalation team -> "escalation_team". A team on the staffed list ->
"staffed_team". Anything else -> "nobody". person, escalation_team and staffed_team are HELD. caroline is
already hers; nobody and bot are assigned to Caroline first (firstmate 2026-11-14 01:25Z), then answered.

THE RULES A ROW PASSES, IN ORDER, AT SEND TIME (the plan is only a list of candidates):
  1. the shared ledger: one reply per conversation ever, one message per user per UTC day across lanes;
  2. a live read of the thread: still open, nobody has written since the plan was made, and the last
     word is still the customer's (or ours, for a close);
  3. the erasure register and the open promises are read again: a thread the register names is skipped,
     a close is skipped on any open promise, and a line is skipped unless it is the promised update;
  4. for a line that states account facts: the request states are read from the core replica now and
     pick the line; the fraud lens is asked; a document on file or an open ask in 30 days is a hold;
     and the thread has exactly one contact (it states one person's account to whoever reads it);
  5. the outbound copy gate approves these exact bytes (a signed approval: an `observed` answer is a
     hold here, whatever the mode table says);
  6. intercom-ops-write.sh --validate, the ledger claim, then the one POST.
Unmeasured is a hold: a store or a read that fails sends nothing for that row.

  7. the assignment, for a thread nobody or a bot holds: `intent` (with its inverse), the assignment as
     Caroline, then a read-back that must show her; otherwise nothing is sent on that thread.
A hand-back row passes the same checks against its own shared ledger key (`handback-<conversation id>`, one
note per conversation, ever) and the user's one message per UTC day, then posts its note and records `intent`
and `handback_posted` in the run audit. A row whose key is blocked, or whose live read already shows a marker
note, posts nothing and is counted `handback_unconfirmed` with its id: a claimed note that never became
visible stays owed and visible, never a silent skip.
Hand-backs are walked after the sending rows, count inside --max, and have their own per-run cap.

A close happens only after this run's own note POSTED on that conversation, and is read back.
`reopen --ledger FILE` opens again every conversation a run closed. A sent note cannot be unsent.

Usage (node-8, root):
  set -a; . /etc/openclaw/main.env; set +a
  python3 drain.py plan  <census.triage.jsonl> --out plan.jsonl
  python3 drain.py lines                       # asks the gate about every body (queues it for review)
  python3 drain.py send  plan.jsonl [--max 200] [--only LINE,LINE]            # dry run
  python3 drain.py send  plan.jsonl --apply --ledger run.jsonl [--max 200]
  python3 drain.py reopen --ledger run.jsonl
  python3 drain.py unassign --ledger run.jsonl   # undo the assignments this run made, from their inverse

Ships UNARMED: no cron job and no systemd unit runs it; it answers only when a person runs it by hand.
"""
import argparse
import collections
import datetime as dt
import hashlib
import json
import os
import re
import sqlite3
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from types import SimpleNamespace

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPTS = os.path.dirname(HERE)
sys.path.insert(0, SCRIPTS)
sys.path.insert(0, HERE)
from credit_review import verify_ledger  # noqa: E402  the shared message ledger
from lib import copy_gate  # noqa: E402  the outbound copy gate's caller
import overrides  # noqa: E402  the ONE captain-overrides loader
import send as backlog  # noqa: E402  the backlog sender's ledger, stage-2 and replica helpers
from caroline_monitor import cli as monitor_cli  # noqa: E402  who is a person (the monitor's ONE rule)
from caroline_monitor import fixloop as monitor_register  # noqa: E402  the shape register it reads
from caroline_monitor import rules as monitor_rules  # noqa: E402  the fallback who-is-who lists

INTERCOM_ADMIN_ID = "5763097"   # Caroline: the only identity this file posts or closes as
API = "https://api.intercom.io"
API_VERSION = "2.11"
OPS_WRITE = backlog.OPS_WRITE
APPROVER = backlog.APPROVER
LEDGER = backlog.LEDGER
GATE_CAMPAIGN = "backlog-drain"
MAX_PER_RUN = 200               # firstmate 2026-11-13: capped at 200 per run
MIN_AGE_H = 4                   # the sentinel's limit for intercom_customer_last
STALE_DAYS = 90
LATE_REPLY_DAYS = 30            # a newer thread with a specific ask needs its own answer, not a fixed line
# Monitor shapes (scripts/caroline_monitor/rules.py) in which the customer asks where a request stands.
STATUS_SHAPES = ("proof_sent", "request_status", "proof_what_needed", "credit_add_howto", "declined_why")
STATUS_TOPICS = ("credit", "claim")   # census topics, used only when the monitor names no shape
# Monitor shapes no fixed line here answers, and the `separate` class each one joins. The census topic is a
# keyword read of the opening message; on 2026-11-15 it typed 11 threads the monitor shaped as an erasure
# request, a legal notice or a refund dispute as "other", and the plan gave them the late-reply line
# ("tell us what you need"). The shape decides, whatever the topic says (firstmate 2026-11-15 08:07Z).
# Decision 2026-11-15 08:07Z: these rows are excluded from this sender by rule; erasure is owned by the GDPR
# pipeline's DSAR ladder (docs/support/gdpr-pipeline.md), legal and refund by the legal / refund lane.
SEPARATE_SHAPES = {"gdpr_erasure": "erasure", "legal_notice": "legal", "refund_dispute": "billing"}
ESCALATION_TEAM = "7111842"     # openclaw-edge.json escalationTeamId: a thread escalated there is not ours
HELD_HOLDERS = ("person", "escalation_team", "staffed_team")   # a person or a worked inbox
ASSIGNABLE_HOLDERS = ("nobody", "bot")
DEFAULT_WHO = (tuple(monitor_rules.DEFAULT_NON_HUMAN_ADMINS), ())
RESTRICTED_TS = os.path.join(os.path.dirname(SCRIPTS), "plugins", "intercom", "src", "restricted-accounts.ts")
RESTRICTED_SETS = ("RESTRICTED_CATEGORY", "PROOF_REVIEW_CATEGORY")
MONITOR_DB = "/var/lib/hydra/caroline-monitor/monitor.sqlite"
GDPR_DB = "/var/lib/hydra-gdpr/erasure.sqlite"
CUSTOMER_AUTHORS = ("user", "lead", "contact")
OURS = ("caroline", "caroline_as_operator", "person")
PENDING = ("unverified", "processing", "user_verification_needed")
NOT_OWED_SHAPES = {"robot_mail": "automated mail", "thanks_empty": "the customer's last message is a thanks"}

# Fixed bodies. No name, no count, no date: the bytes the reviewer signs are the bytes every person gets.
# A line is changed by changing it here, which makes it a new body that needs its own verdict.
LINES = {
    "no-account": (
        "Sorry for the slow reply. We could not match this conversation to a Muso account, so we cannot look up "
        "your request from here. Please write to us from the email address you use to sign in to Muso, or message "
        "us in the Muso app while you are signed in, and tell us what you need."),
    "credits-approved": (
        "Sorry for the slow reply. Every credit request on your account has been reviewed and approved. You can "
        "see your credits on your Muso profile. If something is still missing, or you need help with anything "
        "else, reply here and tell us what you need."),
    "credits-decided": (
        "Sorry for the slow reply. Every credit request on your account has been reviewed. The approved credits "
        "are on your Muso profile. The others were denied for now. You can resubmit for those credits again "
        "later. If you need help with anything else, reply here and tell us what you need."),
    "credits-declined": (
        "Sorry for the slow reply. Every credit request on your account has been reviewed and denied for now. "
        "You can resubmit for the credit again later. If you need help with anything else, reply here and tell "
        "us what you need."),
    # the how-to is the reviewed wording of workspaces/support/reference/faq.md ("Add Credits" / "Add Missing Credits")
    "no-request": (
        "Sorry for the slow reply. There is no open credit request or profile claim on your account right now. "
        "To add a credit, open your profile on muso.ai and choose Add Credits in the Summary panel, or open the "
        "track in the Muso app and choose Add Missing Credits. If you need help with anything else, reply here "
        "and tell us what you need."),
    "late-reply": (
        "Sorry, we did not reply to this message when you sent it. If you still need help, reply here and "
        "tell us what you need, and you will get an answer in this conversation."),
    "stale-close": (
        "Your last message here was answered and the conversation has been quiet since, so we are closing it. "
        "If you still need help, reply here at any time and it will open again."),
}
ACCOUNT_LINES = ("credits-approved", "credits-decided", "credits-declined", "no-request")
# The only lines that ARE a promised update, and the promise kinds (caroline_monitor commitments.kind) each
# one keeps. `no-request`, `no-account` and `late-reply` keep no promise: "there is no open request" is not
# the outcome of a merge, a hide or a person we said was coming.
_DECIDED_KEEPS = ("credit_verification", "request_status")
PROMISE_MET_BY = {"credits-approved": _DECIDED_KEEPS, "credits-decided": _DECIDED_KEEPS,
                  "credits-declined": _DECIDED_KEEPS}
# must equal plugins/intercom/src/filters.ts HANDBACK_MARKER; no test compares the two copies
HANDBACK_MARKER = "hydra-handback:"
HANDBACK_MAX_PER_RUN = 25       # each hand-back starts a model turn
HANDBACK_PACE_S = 2.0
# ONE hand-back note per thread, no repeats and no retry policy (firstmate 2026-11-14 12:32Z): a note is
# an attempt, the thread itself is the record, and a hand-back not read back within this window is listed
# as `handback_unconfirmed` on every plan and run. Nothing re-posts.
HANDBACK_UNCONFIRMED_AFTER_S = 24 * 3600
# An account with something open belongs to a reviewed verification sender, never to this file.
OWNER_CAMPAIGN = {
    "credit_doc_not_enough": "proof-need-ask",
    "credit_doc_on_file": "status-doc-received",
    "credit_needs_document": "uvn-status",
    "credit_open_undecided": "status-team-review",
    "claim_pending": "claim-status",
}
TAG = re.compile(r"<[^>]+>")


class Refused(Exception):
    pass


class Unmeasured(Exception):
    """A fact this run needs could not be read. Never a pass."""


def now_z():
    return dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def clock_now(deps):
    """The run's clock as a datetime. `deps.now()` is a POSIX timestamp (the tests drive it), and the ledger's
    finalize takes a datetime: a confirmed send is recorded on the day it went out, so it must use this clock."""
    return dt.datetime.fromtimestamp(deps.now(), dt.timezone.utc)


def utc_day(ts):
    return dt.datetime.fromtimestamp(ts, dt.timezone.utc).strftime("%Y-%m-%d")


def words(body):
    return " ".join(TAG.sub(" ", body or "").split())


def is_handback_note(part, non_human=DEFAULT_WHO[0]):
    """Is this part a hand-back note? The SAME rule as plugins/intercom/src/filters.ts handbackNoteReason:
    a note of ours whose stored body carries a LINE starting with HANDBACK_MARKER — intercom-ops-write.sh
    writes its own "Note to team ..." header above the body it is given."""
    if not isinstance(part, dict) or part.get("part_type") != "note":
        return False
    author = part.get("author") or {}
    if author.get("type") != "admin" or str(author.get("id") or "") not in non_human:
        return False
    lines = (line.strip() for line in TAG.sub("\n", str(part.get("body") or "")).split("\n"))
    return any(line.startswith(HANDBACK_MARKER) for line in lines)


def who_of(author, non_human=DEFAULT_WHO[0]):
    author = author or {}
    if author.get("type") in CUSTOMER_AUTHORS:
        return "customer"
    author_id = str(author.get("id") or "")
    if author_id == INTERCOM_ADMIN_ID:
        return "caroline"
    if author.get("type") == "bot" or (author_id and author_id in non_human):
        return "caroline_as_operator"
    if author.get("type") == "admin":
        return "person"
    return "other"


def read_who(path=None):
    """(non-human admin ids, staffed team ids) from the monitor's ONE shape register. Raises Unmeasured.
    firstmate 2026-11-14 01:25Z: the bots are Caroline-side, never a person."""
    try:
        register = monitor_register.load_register(path) if path else monitor_register.load_register()
    except monitor_register.RegisterError as e:
        raise Unmeasured("caroline shapes unreadable: " + type(e).__name__) from e
    non_human, staffed = monitor_cli.who(register.get("monitor") or {})
    return tuple(str(i) for i in non_human), tuple(str(i) for i in staffed)


def read_thread(conv, non_human=DEFAULT_WHO[0], staffed=DEFAULT_WHO[1]):
    """What the thread's own parts say. Pure. The statistics block is not used: it does not count a reply
    posted as the workspace bot, which is how 865 answered threads read as customer-last."""
    if not isinstance(conv, dict) or "_error" in conv or not conv.get("id"):
        return {"read": "unreadable"}
    block = conv.get("conversation_parts") or {}
    parts = block.get("conversation_parts") or []
    if int(block.get("total_count") or len(parts)) > len(parts):
        return {"read": "truncated"}   # the newest parts may be missing: the last word is not known
    src = conv.get("source") or {}
    said = []
    src_who = who_of(src.get("author"), non_human)
    if src_who == "customer" or words(src.get("body")) or src.get("subject"):
        said.append((int(conv.get("created_at") or 0), src_who))
    for p in parts:
        if p.get("part_type") != "comment":
            continue
        part_who = who_of(p.get("author"), non_human)
        if part_who == "customer" or words(p.get("body")):
            said.append((int(p.get("created_at") or 0), part_who))
    said.sort()
    note_at = 0
    for p in parts:
        if is_handback_note(p, non_human):
            note_at = max(note_at, int(p.get("created_at") or 0))
    admin = str(conv.get("admin_assignee_id") or "")
    team = str(conv.get("team_assignee_id") or "")
    if admin == INTERCOM_ADMIN_ID:
        holder = "caroline"
    elif admin and admin in non_human:
        holder = "bot"
    elif admin:
        holder = "person"
    elif team == ESCALATION_TEAM:
        holder = "escalation_team"
    elif team and team in staffed:
        holder = "staffed_team"
    else:
        holder = "nobody"
    contacts = (conv.get("contacts") or {}).get("contacts") or []
    return {
        "read": "ok", "state": conv.get("state"), "holder": holder, "contacts": len(contacts),
        "admin_assignee_id": admin or None, "team_assignee_id": team or None,
        "contact_ids": [str(c.get("id") or "") for c in contacts if isinstance(c, dict)],
        "last_word": said[-1][1] if said else "none",
        "last_customer_at": max([t for t, w in said if w == "customer"] or [0]),
        "last_reply_at": max([t for t, w in said if w in OURS] or [0]),
        "handback_note_at": note_at,
    }


def account_class(row, docs_on_file, need):
    """(class, basis) from the census row's account facts. Pure. A class in OWNER_CAMPAIGN is never sent."""
    c, cl = row.get("credits") or {}, row.get("claims") or {}
    if not row.get("user_id"):
        return "no_account", "no single Muso account resolves from the contact"
    if c.get("pending"):
        if docs_on_file:
            if need:
                return "credit_doc_not_enough", f"{c['pending']} open, document on file, read: not enough alone ({need})"
            return "credit_doc_on_file", f"{c['pending']} open, document on file, not decided"
        if c.get("uvn"):
            return "credit_needs_document", f"{c['pending']} open, {c['uvn']} need a document, none on file"
        return "credit_open_undecided", f"{c['pending']} open, never asked"
    if cl.get("pending"):
        return "claim_pending", f"{cl['pending']} claim pending"
    if c.get("approved") or c.get("rejected"):
        return "credit_all_decided", f"approved {c.get('approved', 0)}, declined {c.get('rejected', 0)}, none open"
    return "no_request_on_file", "no credit request and no pending claim"


PLAN_LINE = {"no_account": "no-account", "credit_all_decided": "credits-approved", "no_request_on_file": "no-request"}


def plan_line(klass, row):
    """The line a census class would use. Pure. The send-time read picks the real one."""
    if klass == "credit_all_decided":
        c = row.get("credits") or {}
        approved, rejected = int(c.get("approved", 0)), int(c.get("rejected", 0))
        if approved and rejected:
            return "credits-decided"
        return "credits-approved" if approved else "credits-declined"
    return PLAN_LINE[klass]


def promise_unmet(line, promises):
    """The open promises `line` does not keep, as sorted kind names. Pure. [] = none open, or all kept."""
    kept = PROMISE_MET_BY.get(line, ())
    return sorted({str(k) for k in promises or () if k not in kept})


def classify(row, thread, facts, now_s):
    """One plan row: (list, class, line, mode, basis). Pure.

    list: send | close | owner | caroline | separate | held | not_owed | unread.  `facts` holds what the stores say about
    this conversation and account: shape, erasure (bool), promises (list), docs_on_file, need, restricted."""
    action = str(row.get("action") or "")
    if thread.get("read") != "ok":
        why = thread.get("error") or thread.get("read")
        return "unread", "unread", "", "", "the thread could not be read (" + str(why) + ")"
    if thread["state"] != "open":
        return "not_owed", "not_open", "", "", "no longer open"
    special = ""
    if facts.get("erasure"):
        special = "erasure"
    elif action.startswith("captain-"):
        special = action[len("captain-"):]
    elif action == overrides.HOLD_READ:
        special = "hand_read"
    elif facts.get("shape") in SEPARATE_SHAPES:
        special = SEPARATE_SHAPES[facts["shape"]]
    label = special + (" (monitor shape " + facts["shape"] + ")" if facts.get("shape") in SEPARATE_SHAPES else "")
    held = thread["holder"] in HELD_HOLDERS
    ours_last = thread["last_word"] in OURS
    if thread["last_word"] not in OURS + ("customer",):
        return "not_owed", "nothing_said", "", "", "no message with words on the thread"
    if not ours_last:
        if special in ("erasure", "legal"):
            return "separate", special, "", "", label + " thread: outside this sender"
        if facts.get("shape") in NOT_OWED_SHAPES:
            return "not_owed", facts["shape"], "", "", NOT_OWED_SHAPES[facts["shape"]]
        if special:
            return "separate", special, "", "", label + " thread: outside this sender"
    else:
        silent_days = (now_s - thread["last_customer_at"]) / 86400 if thread["last_customer_at"] else 0
        if not facts.get("promises"):
            if silent_days <= STALE_DAYS:
                return "not_owed", "answered", "", "", "we wrote last (" + thread["last_word"] + ")"
            if special or held or facts.get("restricted"):
                return "not_owed", "answered", "", "", "we wrote last; " + (label or "held or restricted") + ": left open"
            return "close", "stale", "stale-close", "close", f"we wrote last, customer silent {int(silent_days)} days, no open promise"
        if special:
            return "separate", special, "", "", label + " thread with an open promise: outside this sender"
    if held:
        return "held", thread["holder"], "", "", "held by " + thread["holder"].replace("_", " ")
    if facts.get("restricted"):
        return "held", "restricted", "", "", "restricted contact"
    mode = "promise" if ours_last else "answer"
    klass, basis = account_class(row, facts.get("docs_on_file"), facts.get("need"))
    shape = facts.get("shape") or ""
    asks_status = shape in STATUS_SHAPES or (shape in ("", "other") and row.get("topic") in STATUS_TOPICS)
    if not asks_status:
        quiet_days = (now_s - thread["last_customer_at"]) / 86400 if thread["last_customer_at"] else 0
        about = "about " + (shape or str(row.get("topic") or "other"))
        if quiet_days <= LATE_REPLY_DAYS:
            return "caroline", "specific_ask", "", mode, about + ", written in the last 30 days: needs its own answer"
        sending = ("send", "specific_ask", "late-reply", mode, about + f", quiet {int(quiet_days)} days")
    elif klass in OWNER_CAMPAIGN:
        return "owner", klass, "", mode, basis + "; owned by " + OWNER_CAMPAIGN[klass]
    else:
        sending = ("send", klass, plan_line(klass, row), mode, basis)
    unmet = promise_unmet(sending[2], facts.get("promises"))
    if unmet:
        return ("caroline", "open_promise", "", mode,
                "an open promise (" + ", ".join(unmet) + ") the " + sending[2] + " line does not keep")
    return sending


def account_line(statuses, claims_pending):
    """(line, why-not) from the request states read NOW. Pure. The census never picks an account line."""
    pending = sum(int(statuses.get(s, 0)) for s in PENDING)
    if pending or claims_pending:
        return "", "an open request or claim: owned by the verification senders"
    approved, rejected = int(statuses.get("approved", 0)), int(statuses.get("rejected", 0))
    if sum(int(n) for s, n in statuses.items() if s not in PENDING + ("approved", "rejected")):
        return "", "a request in a state this sender has no line for"
    if approved and rejected:
        return "credits-decided", ""
    if approved:
        return "credits-approved", ""
    if rejected:
        return "credits-declined", ""
    return "no-request", ""


def handback_of(row, now_s):
    """(reason code, class label) for a customer-last row no fixed line answers, else "". Pure.
    firstmate 2026-11-14 12:10Z: the plan counts only what the sender can post, so a mode the send
    loop refuses for its own reasons (a promise on a thread we answered) is no hand-back."""
    if row.get("mode") != "answer" or row.get("handback_note_at"):
        return ""
    if row.get("list") == "caroline":
        if row.get("class") == "open_promise":
            return "open_promise", "open promise"
        return "specific_ask", "specific ask"
    if row.get("list") == "owner":
        last = int(row.get("last_customer_at") or 0)
        if last and now_s - last <= LATE_REPLY_DAYS * 86400:
            klass = str(row.get("class") or "owner")
            return "owner_recent", OWNER_CAMPAIGN.get(klass, klass)
    return ""


def handback_note(reason, klass):
    return f"{HANDBACK_MARKER} reason={reason} class={klass}"


def handback_key(conversation_id):
    """The shared ledger 'request id' of a hand-back: one note per conversation, ever
    (firstmate 2026-11-14 12:32Z: no repeats and no retry policy)."""
    return "handback-" + str(conversation_id)


def handback_state_of(rec, now_s):
    """What the thread itself says about the note already on it. Pure.

    firstmate 2026-11-14 12:32Z: one note per thread, so the read of the conversation IS the record.
    confirmed = a worded comment of ours after the note; pending = the customer is still last and the
    note is younger than HANDBACK_UNCONFIRMED_AFTER_S; unconfirmed = still last and past that window."""
    note_at = int(rec.get("handback_note_at") or 0)
    if not note_at:
        return ""
    if int(rec.get("last_reply_at") or 0) > note_at:
        return "confirmed"
    if rec.get("last_word") == "customer":
        return "pending" if now_s - note_at < HANDBACK_UNCONFIRMED_AFTER_S else "unconfirmed"
    return "confirmed"


def live_thread_ok(row, thread, now_s):
    """'' when the thread read NOW still matches the plan row, else the skip reason. Pure."""
    if thread.get("read") != "ok":
        return "thread unreadable: " + str(thread.get("read"))
    if thread["state"] != "open":
        return "no longer open"
    if thread["last_customer_at"] != int(row.get("last_customer_at") or 0):
        return "the customer wrote again since the plan"
    if thread["last_reply_at"] != int(row.get("last_reply_at") or 0):
        return "answered since the plan"
    if thread["holder"] in HELD_HOLDERS:
        return "held by " + thread["holder"].replace("_", " ")
    if row["mode"] == "answer" and thread["last_word"] != "customer":
        return "the customer no longer spoke last"
    if row["mode"] in ("promise", "close") and thread["last_word"] not in OURS:
        return "we no longer spoke last"
    if row["mode"] == "close" and now_s - thread["last_customer_at"] <= STALE_DAYS * 86400:
        return "not silent for over 90 days"
    return ""


# ---------------------------------------------------------------------------------------------- reads

def intercom_get(token, path):
    for attempt in range(5):
        try:
            req = urllib.request.Request(API + path, headers={
                "Authorization": "Bearer " + token, "Accept": "application/json", "Intercom-Version": API_VERSION})
            with urllib.request.urlopen(req, timeout=30) as r:
                return json.load(r)
        except urllib.error.HTTPError as e:
            if e.code not in (429, 500, 502, 503, 504):
                return {"_error": e.code}
        except (urllib.error.URLError, TimeoutError, ValueError):
            pass
        time.sleep(2 * (attempt + 1))
    return {"_error": "unreadable"}


def get_conv(token, conversation_id):
    return intercom_get(token, f"/conversations/{conversation_id}?display_as=plaintext")


def _ro(path):
    return sqlite3.connect(f"file:{path}?mode=ro", uri=True)


def read_erasure():
    """Conversation ids with an open row in the erasure register. Raises Unmeasured."""
    try:
        db = _ro(GDPR_DB)
        try:
            return {str(r[0]) for r in db.execute(
                "select conversation_id from erasure_requests where status='open' and conversation_id <> ''")}
        finally:
            db.close()
    except sqlite3.Error as e:
        raise Unmeasured("erasure register unreadable: " + type(e).__name__) from e


def read_monitor():
    """({conversation id: shape}, {conversation id: [open promise kinds]}). Raises Unmeasured."""
    try:
        db = _ro(MONITOR_DB)
        try:
            shape = {str(i): s or "" for i, s in db.execute("select id, shape from facts")}
            promises = collections.defaultdict(list)
            for cid, kind in db.execute(
                    "select conversation_id, kind from commitments where closed_at is null or closed_at = ''"):
                promises[str(cid)].append(kind or "")
            return shape, dict(promises)
        finally:
            db.close()
    except sqlite3.Error as e:
        raise Unmeasured("monitor store unreadable: " + type(e).__name__) from e


def read_documents(uids):
    """({user id: documents on file}, {user id: the need doc-verify names, '' when none}). Raises Unmeasured."""
    docs, need = {}, {}
    try:
        pdb = _ro(backlog.PROOF_STORE)
        ddb = _ro(os.path.join(os.path.dirname(backlog.PROOF_STORE), "doc-verify.sqlite"))
        try:
            for i in range(0, len(uids), 400):
                chunk = uids[i:i + 400]
                marks = ",".join("?" * len(chunk))
                for uid, n in pdb.execute(
                        f"select cast(user_id as text), count(*) from proof_intake "
                        f"where cast(user_id as text) in ({marks}) group by 1", chunk):
                    docs[uid] = int(n)
                seen = collections.defaultdict(collections.Counter)
                for uid, outcome, nd, n in ddb.execute(
                        f"select cast(user_id as text), outcome, coalesce(need,''), count(*) from dv_outcomes "
                        f"where cast(user_id as text) in ({marks}) group by 1,2,3", chunk):
                    seen[uid][(outcome, nd)] += int(n)
                for uid, counts in seen.items():
                    needs = collections.Counter({k[1]: n for k, n in counts.items() if k[0] == "unverifiable" and k[1]})
                    verified = sum(n for k, n in counts.items() if k[0] == "verified")
                    need[uid] = needs.most_common(1)[0][0] if needs and not verified else ""
        finally:
            pdb.close()
            ddb.close()
    except sqlite3.Error as e:
        raise Unmeasured("proof store unreadable: " + type(e).__name__) from e
    return docs, need


def read_restricted(path=RESTRICTED_TS):
    """Contact ids the plugin keeps Caroline's reply from (restricted-accounts.ts). Raises Unmeasured.

    That file is hand-maintained prose plus TypeScript: a shape this scrape cannot read must refuse the
    run, because an empty set would read as "nobody is restricted" and answer a banned contact."""
    try:
        with open(path, encoding="utf8") as f:
            src = f.read()
    except OSError as e:
        raise Unmeasured("restricted accounts unreadable: " + type(e).__name__) from e
    missing = [name for name in RESTRICTED_SETS if name not in src]
    if missing:
        raise Unmeasured("restricted accounts unreadable: no " + ", ".join(missing) + " in the plugin file")
    ids = frozenset(re.findall(r'"([0-9a-f]{24})"', src))
    if not ids:
        raise Unmeasured("restricted accounts unreadable: no contact ids in the plugin file")
    return ids


def live_account(uid, presented, query):
    """({status: rows}, pending claims) for every profile the account presents, from the core replica now."""
    where = [f"userid = {int(uid)}"]
    ids = (presented or {}).get(str(uid), [])
    if ids:
        where.append("cast(profileid as varchar) in (" + ",".join("'" + p.replace("'", "''") + "'" for p in ids) + ")")
    rows = query("select status, cast(count(*) as varchar) from postgresql_core.public.credit_requests "
                 "where deletedat is null and (" + " or ".join(where) + ") group by status")
    statuses = {}
    for r in rows:
        if len(r) != 2 or not str(r[1]).strip().isdigit():
            raise RuntimeError("request states unreadable")
        statuses[str(r[0])] = int(r[1])
    k = query("select cast(count(*) as varchar) from postgresql_core.public.claiming where deletedat is null "
              f"and status = 'pending' and userid = {int(uid)}")
    if not k or not k[0] or not str(k[0][0]).strip().isdigit():
        raise RuntimeError("claim state unreadable")
    return statuses, int(k[0][0])


# ---------------------------------------------------------------------------------------------- writes

def post_reply(conversation_id, body, line_key, validate=False):
    """The ONE customer POST of this file. No signed approval on these exact bytes, no POST."""
    permit = copy_gate.require(GATE_CAMPAIGN, body, copy=line_key, message_type="comment")
    if permit.get("result") != "approved":
        raise copy_gate.CopyHeld("copy_not_approved:" + str(permit.get("review") or permit.get("result")),
                                 hashlib.sha256(body.encode("utf-8")).hexdigest(), pending=True)
    with tempfile.NamedTemporaryFile("w", delete=False, suffix=".txt", encoding="utf8") as f:
        f.write(body)
    try:
        argv = [OPS_WRITE, "reply", "--conversation", str(conversation_id), "--requested-by", APPROVER,
                "--customer-facing", "--approved-by", APPROVER, "--body-file", f.name]
        p = subprocess.run(argv + (["--validate"] if validate else []), capture_output=True, text=True, check=False)
    finally:
        os.unlink(f.name)
    return {"rc": p.returncode, "stdout": p.stdout or "", "stderr": p.stderr or "",
            "verdict_id": str(permit.get("verdict_id") or "")}


def post_note(conversation_id, body, validate=False):
    """The ONE internal-note POST of this file: a hand-back note, never a customer reply."""
    with tempfile.NamedTemporaryFile("w", delete=False, suffix=".txt", encoding="utf8") as f:
        f.write(body)
    try:
        argv = [OPS_WRITE, "note", "--conversation", str(conversation_id), "--requested-by", APPROVER,
                "--audience", "team", "--body-file", f.name]
        p = subprocess.run(argv + (["--validate"] if validate else []), capture_output=True, text=True, check=False)
    finally:
        os.unlink(f.name)
    return {"rc": p.returncode, "stdout": p.stdout or "", "stderr": p.stderr or ""}


def _part(token, conversation_id, message_type, assignee_id="", assignee_type="admin"):
    payload = {"message_type": message_type, "type": assignee_type, "admin_id": INTERCOM_ADMIN_ID}
    if assignee_id:
        payload["assignee_id"] = assignee_id
    req = urllib.request.Request(
        f"{API}/conversations/{conversation_id}/parts", method="POST",
        data=json.dumps(payload).encode(),
        headers={"Authorization": "Bearer " + token, "Accept": "application/json",
                 "Content-Type": "application/json", "Intercom-Version": API_VERSION})
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.load(r)


def assign_thread(token, conversation_id, assignee_id=INTERCOM_ADMIN_ID, assignee_type="admin"):
    """Assign the conversation, as Caroline. The forward assignee is the constant, never a parameter.
    The POST is the only thing this does: every caller reads the thread back itself."""
    _part(token, conversation_id, "assignment", assignee_id=assignee_id, assignee_type=assignee_type)


def close_thread(token, conversation_id):
    """Close as Caroline, no body (the note already went out). Returns the state read back."""
    _part(token, conversation_id, "close")
    return str(get_conv(token, conversation_id).get("state") or "unread")


def reopen_thread(token, conversation_id):
    _part(token, conversation_id, "open")
    return str(get_conv(token, conversation_id).get("state") or "unread")


def append_ledger(path, row):
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
    with os.fdopen(fd, "a", encoding="utf8") as f:
        f.write(json.dumps(row, sort_keys=True) + "\n")
        f.flush()
        os.fsync(f.fileno())


# ---------------------------------------------------------------------------------------------- plan

LIST_RANK = {"send": 0, "close": 1}


def plan_order(x):
    """The sort key of a plan row. Pure. A run is capped, so this decides WHO is answered, not how it reads.

    Closes come after every answer. Inside a list: a paying customer first (firstmate 2026-11-15 09:14Z:
    "paid first, then proof-sent, then oldest inside each group"; runs 1 to 4 sent oldest-first across paid
    and unpaid alike), then the threads whose customer already sent proof (firstmate 2026-11-13 23:29Z: they
    did their part and are waiting on us; confirmed 2026-11-14 on review finding
    send-order-puts-proof-sent-ahead-of-oldest), then oldest first. A contact with no account is not paid.

    The three keys are lexicographic by decision (firstmate 2026-11-15 09:28Z, on review finding
    paid-group-not-oldest-first): inside the paying customers, those who already sent proof come first,
    then oldest."""
    return (LIST_RANK.get(x.get("list"), 2), not x.get("paid"),
            x.get("shape") != "proof_sent" if x.get("list") == "send" else False,
            int(x.get("waiting_since") or 0))


def build_plan(rows, threads, erasure, shape, promises, docs, need, restricted, now_s):
    """Plan rows in send order. Pure: every read has already happened."""
    out = []
    for r, t in zip(rows, threads):
        cid, uid = str(r["id"]), r.get("user_id") or ""
        facts = {"shape": shape.get(cid, ""), "erasure": cid in erasure, "promises": promises.get(cid, []),
                 "docs_on_file": docs.get(uid, 0), "need": need.get(uid, ""),
                 "restricted": bool(set(t.get("contact_ids") or ()) & restricted)}
        lst, klass, line, mode, basis = classify(r, t, facts, now_s)
        rec = {
            "id": cid, "list": lst, "class": klass, "line": line, "mode": mode, "basis": basis,
            "waiting_since": int(r.get("waiting_since") or 0), "topic": r.get("topic"), "shape": facts["shape"],
            "paid": bool(r.get("paid")), "user_id": uid, "contact_id": r.get("contact_id") or "",
            "email": r.get("email") or "", "open_promises": sorted(facts["promises"]),
            "last_customer_at": t.get("last_customer_at", 0), "last_reply_at": t.get("last_reply_at", 0),
            "holder": t.get("holder", ""), "contacts": t.get("contacts", 0),
            "last_word": t.get("last_word", ""), "handback_note_at": t.get("handback_note_at", 0),
        }
        rec["handback"] = handback_of(rec, now_s)
        rec["handback_state"] = handback_state_of(rec, now_s)
        out.append(rec)
    out.sort(key=plan_order)
    for i, x in enumerate(out, 1):
        x["order"] = i
    return out


def summarize(plan):
    count = collections.Counter
    return {
        "rows": len(plan),
        "by_list": dict(count(x["list"] for x in plan).most_common()),
        "send_by_line": dict(count(x["line"] for x in plan if x["list"] == "send").most_common()),
        "send_by_mode": dict(count(x["mode"] for x in plan if x["list"] == "send").most_common()),
        "close": sum(1 for x in plan if x["list"] == "close"),
        "owner_by_campaign": dict(count(OWNER_CAMPAIGN[x["class"]] for x in plan if x["list"] == "owner").most_common()),
        "caroline": sum(1 for x in plan if x["list"] == "caroline"),
        "caroline_by_class": dict(count(x["class"] for x in plan if x["list"] == "caroline").most_common()),
        "handback": sum(1 for x in plan if x.get("handback")),
        "handback_confirmed": sum(1 for x in plan if x.get("handback_state") == "confirmed"),
        "handback_pending": sum(1 for x in plan if x.get("handback_state") == "pending"),
        "handback_unconfirmed": sum(1 for x in plan if x.get("handback_state") == "unconfirmed"),
        "handback_unconfirmed_ids": [x["id"] for x in plan if x.get("handback_state") == "unconfirmed"],
        "handback_by_class": dict(count(x["handback"][1] for x in plan if x.get("handback")).most_common()),
        "separate_by_class": dict(count(x["class"] for x in plan if x["list"] == "separate").most_common()),
        "held_by_class": dict(count(x["class"] for x in plan if x["list"] == "held").most_common()),
        "not_owed_by_class": dict(count(x["class"] for x in plan if x["list"] == "not_owed").most_common()),
        "unread": sum(1 for x in plan if x["list"] == "unread"),
        "needs_assignment": sum(1 for x in plan
                                if (x["list"] in ("send", "close") or x.get("handback"))
                                and x.get("holder") in ASSIGNABLE_HOLDERS),
        "no_ledger_key": sum(1 for x in plan
                             if (x["list"] in ("send", "close") or x.get("handback"))
                             and not (x.get("email") or x.get("contact_id"))),
    }


def cmd_plan(a, token):
    with open(a.source, encoding="utf8") as f:
        rows = [json.loads(line) for line in f if line.strip()]
    now_s = time.time()
    rows = [r for r in rows if now_s - int(r.get("waiting_since") or 0) > MIN_AGE_H * 3600]
    rows = overrides.apply(rows, overrides.load(a.overrides) if a.overrides else overrides.load())
    try:
        erasure = read_erasure()
        shape, promises = read_monitor()
        docs, need = read_documents(sorted({r["user_id"] for r in rows if r.get("user_id")}))
        restricted = read_restricted()
        non_human, staffed = read_who()
    except Unmeasured as e:
        print(f"UNMEASURED: {e}. No plan written.", file=sys.stderr)
        return 3
    def plan_thread(r):
        try:
            return read_thread(get_conv(token, r["id"]), non_human, staffed)
        except Exception as e:                      # one conversation, never the whole measurement
            return {"read": "unreadable", "error": type(e).__name__}

    with ThreadPoolExecutor(max_workers=6) as ex:
        threads = list(ex.map(plan_thread, rows))
    plan = build_plan(rows, threads, erasure, shape, promises, docs, need, restricted, now_s)
    fd = os.open(a.out, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf8") as f:
        for x in plan:
            f.write(json.dumps(x, sort_keys=True) + "\n")
    print(json.dumps({**summarize(plan), "out": a.out}, indent=1))
    return 0


# ---------------------------------------------------------------------------------------------- send

def real_deps(token, apply):
    def lens(uids):
        from credit_review import fraud_lens  # noqa: PLC0415  (read at send time)
        return fraud_lens.default_lens(backlog.trino)([int(u) for u in uids])
    return SimpleNamespace(
        now=time.time, sleep=time.sleep,
        get_conv=lambda cid: get_conv(token, cid),
        erasure=read_erasure, monitor=read_monitor, restricted=read_restricted, who=read_who,
        presented=lambda rows: backlog.resolve_presented(rows),
        live_account=lambda uid, presented: live_account(uid, presented, backlog.trino),
        account_emails=account_emails, lens=lens, stage2_hold=backlog.stage2_hold,
        ledger=verify_ledger.connect(LEDGER) if apply else backlog.ledger_ro(LEDGER),
        post_reply=post_reply, post_note=post_note, assign=lambda cid: assign_thread(token, cid),
        close_thread=lambda cid: close_thread(token, cid))


def account_emails(uids):
    out = {}
    for i in range(0, len(uids), 150):
        for uid, email in backlog.trino(
                "select cast(id as varchar), coalesce(email,'') from postgresql_core.public.users "
                f"where id in ({','.join(str(int(u)) for u in uids[i:i + 150])})"):
            out[uid] = email
    return out


def run_send(plan, deps, *, apply=False, max_rows=MAX_PER_RUN, only=(), ledger_path="", out=print):
    """Walk the plan in order. Returns the stats. Every refusal is counted under its reason."""
    if max_rows > MAX_PER_RUN or max_rows < 1:
        raise Refused(f"--max is 1 to {MAX_PER_RUN} per run")
    if apply and not ledger_path:
        raise Refused("--apply needs --ledger: every send and every close is recorded before it happens")
    unknown = sorted(set(only) - set(LINES))
    if unknown:
        raise Refused(f"--only names lines that do not exist: {unknown}")
    sends = [x for x in plan if x.get("list") in ("send", "close") and (not only or x.get("line") in only)]
    sends.sort(key=lambda x: int(x.get("order") or 0))
    # the hand-backs are capped per run too, so they take the same rule: paid first, then oldest
    handbacks = [] if only else sorted((x for x in plan if x.get("handback")),
                                      key=lambda x: (not x.get("paid"), int(x.get("waiting_since") or 0)))
    rows = sends + handbacks
    stats = {"sent": 0, "closed": 0, "dry": 0, "failed": 0, "assigned": 0, "handback_posted": 0,
             "handback_dry": 0, "handback_pending": 0, "handback_unconfirmed": 0,
             "handback_unconfirmed_ids": [], "handback_confirmed": 0, "handback_unread": 0,
             "handback_unread_ids": [],
             "skipped": {}, "by_line": {}, "copy_held": {}}

    def skip(reason):
        stats["skipped"][reason] = stats["skipped"].get(reason, 0) + 1

    def note_already_on(cid, thread):
        """The state of the hand-back note this thread already carries, counted once: '' when none."""
        if not thread.get("handback_note_at"):
            return ""
        state = handback_state_of(thread, deps.now())
        if state == "unconfirmed":
            stats["handback_unconfirmed"] += 1
            stats["handback_unconfirmed_ids"].append(cid)
            out(f"HANDBACK UNCONFIRMED {cid} note_at={thread['handback_note_at']}")
        elif state == "pending":
            stats["handback_pending"] += 1
            out(f"HANDBACK PENDING {cid} note_at={thread['handback_note_at']}")
        return state

    def ensure_assigned(cid, thread):
        """'' when Caroline holds the thread (assigning it first when nobody or a bot does), else a reason.

        firstmate 2026-11-14 01:25Z: an unassigned or bot-held thread is assigned to Caroline first and
        then answered, so the plan never promises something every run skips."""
        holder = thread["holder"]
        if holder in HELD_HOLDERS:
            return "held by " + holder.replace("_", " ")
        if holder == "caroline":
            return ""
        before = {"admin_assignee_id": thread.get("admin_assignee_id"),
                  "team_assignee_id": thread.get("team_assignee_id")}
        if not apply:
            out(f"DRY-ASSIGN {cid} from {holder}")
            return ""
        append_ledger(ledger_path, {"phase": "intent", "run_id": run_id, "ts": now_z(), "id": cid, "what": "assign",
                                    "from": before, "to": INTERCOM_ADMIN_ID})
        try:
            deps.assign(cid)
        except Exception as e:
            stats["failed"] += 1
            append_ledger(ledger_path, {"phase": "error", "run_id": run_id, "ts": now_z(), "id": cid,
                                        "what": "assign", "error": type(e).__name__})
            out(f"FAILED ASSIGN {cid}: {type(e).__name__}")
            return "assignment failed: " + type(e).__name__
        append_ledger(ledger_path, {"phase": "assigned", "run_id": run_id, "ts": now_z(), "id": cid,
                                    "from": before, "to": INTERCOM_ADMIN_ID, "confirmed": False})
        try:
            after = read_thread(deps.get_conv(cid), non_human, staffed)
        except Exception as e:
            after = {"read": type(e).__name__}
        if after.get("read") != "ok" or after.get("holder") != "caroline":
            stats["failed"] += 1
            append_ledger(ledger_path, {"phase": "error", "run_id": run_id, "ts": now_z(), "id": cid,
                                        "what": "assign", "state": after.get("holder") or after.get("read")})
            out(f"FAILED ASSIGN {cid}: assignment not confirmed")
            return "assignment not confirmed"
        stats["assigned"] += 1
        return ""

    try:
        erasure = deps.erasure()
        shape, promises = deps.monitor()
        restricted = deps.restricted()
        non_human, staffed = deps.who()
    except Unmeasured as e:
        raise Refused(f"UNMEASURED: {e}. Nothing sent.") from e
    jumped = {str(x.get("id") or "") for x in rows}
    # firstmate 2026-11-14 12:32Z: the plan and the send run are both the record. A plan row the sender does
    # not post (a thread already carrying a marker note is classified by the ordinary rules, so it is not in
    # `rows`) still has to be counted and printed here, or a fresh plan's owed, unconfirmed threads vanish.
    # The plan only says WHICH threads to look at: the state printed is the one the thread shows NOW, so a
    # hand-back Caroline answered after the plan was made is never listed as owed. A thread that cannot be
    # read is counted `handback_unread` with its id: neither owed nor answered is claimed for it.
    for x in plan:
        cid = str(x.get("id") or "")
        if cid in jumped or x.get("handback_state") not in ("pending", "unconfirmed"):
            continue
        try:
            thread = read_thread(deps.get_conv(cid), non_human, staffed)
        except Exception as e:
            thread = {"read": type(e).__name__}
        if thread.get("read") != "ok":
            stats["handback_unread"] += 1
            stats["handback_unread_ids"].append(cid)
            out(f"HANDBACK UNREAD {cid}: {thread.get('read')}")
            continue
        if note_already_on(cid, thread) == "confirmed":
            stats["handback_confirmed"] += 1
    uids = sorted({x["user_id"] for x in rows if x.get("user_id")})
    emails = deps.account_emails(uids) if uids else {}
    presented = lens = None          # read once, on the first row that needs them; False = the read FAILED
    run_id = "drain-" + dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    if apply:
        append_ledger(ledger_path, {"phase": "run", "run_id": run_id, "ts": now_z(), "max": max_rows,
                                    "only": sorted(only), "candidates": len(rows)})
    done = 0
    handbacks_done = 0
    for x in rows:
        if done >= max_rows:
            break
        cid = str(x.get("id") or "")
        now_shape = shape.get(cid, "")
        if now_shape in SEPARATE_SHAPES and (x.get("list") in ("send", "close") or x.get("handback")):
            skip("monitor shape " + now_shape + ": outside this sender"); continue
        if x.get("list") not in ("send", "close"):
            if not x.get("handback"):
                skip("not a hand-back this sender posts"); continue
            if handbacks_done >= HANDBACK_MAX_PER_RUN:
                break
            reason, klass = x["handback"]
            uid = x.get("user_id") or ""
            if cid in erasure:
                skip("open erasure or access request on this thread"); continue
            key = backlog.user_key_of(x, emails.get(uid, ""))
            if not key:
                skip("no_ledger_key"); continue
            try:
                thread = read_thread(deps.get_conv(cid), non_human, staffed)
            except Exception as e:
                skip("thread unreadable: " + type(e).__name__); continue
            if thread.get("read") != "ok":
                skip("thread unreadable: " + str(thread.get("read"))); continue
            if set(thread.get("contact_ids") or ()) & restricted:
                skip("restricted contact"); continue
            if thread["state"] != "open":
                skip("no longer open"); continue
            if thread["last_word"] != "customer":
                skip("the customer no longer spoke last"); continue
            if thread["holder"] in HELD_HOLDERS:
                skip("held by " + thread["holder"].replace("_", " ")); continue
            already = note_already_on(cid, thread)
            if already:
                skip("hand-back already posted (" + already + ")"); continue
            if verify_ledger.blocked_ids(deps.ledger, [handback_key(cid)], backlog.CAMPAIGN):
                stats["handback_unconfirmed"] += 1
                stats["handback_unconfirmed_ids"].append(cid)
                out(f"HANDBACK UNCONFIRMED {cid} claimed, no note visible")
                skip("hand-back claimed, no note visible"); continue
            note = handback_note(reason, klass)
            v = deps.post_note(cid, note, validate=True)
            if v["rc"]:
                stats["failed"] += 1
                out(f"REFUSED {cid}: {v['stderr'].strip()[:200]}"); continue
            why = ensure_assigned(cid, thread)
            if why:
                skip(why); continue
            done += 1
            handbacks_done += 1
            if not apply:
                stats["handback_dry"] += 1
                out(f"DRY-HANDBACK {cid} {reason} {klass}")
                continue
            today = utc_day(deps.now())
            claim = verify_ledger.claim(deps.ledger, user_key=key, day=today,
                                        request_ids=[handback_key(cid)],
                                        message_type="note", approved_by=APPROVER,
                                        approval_ref="backlog-handback:" + reason,
                                        contact_id=x.get("contact_id") or "", campaign=backlog.CAMPAIGN, user_id=uid)
            if claim["result"] != "claimed":
                done -= 1
                handbacks_done -= 1
                skip("ledger: " + str(claim["result"]))
                continue
            append_ledger(ledger_path, {"phase": "intent", "run_id": run_id, "ts": now_z(), "id": cid,
                                        "what": "handback", "reason": reason, "class": klass})
            p = deps.post_note(cid, note)
            posted = p["rc"] == 0 and p["stdout"].startswith("POSTED note")
            backlog.ledger_finalize(deps.ledger, claim["message_row"], cid, p["rc"], p["stdout"], p["stderr"], note,
                                    part_type="note", now=clock_now(deps))
            if not posted:
                stats["failed"] += 1
                append_ledger(ledger_path, {"phase": "error", "run_id": run_id, "ts": now_z(), "id": cid,
                                            "what": "handback", "rc": p["rc"]})
                out(f"FAILED HANDBACK {cid}: rc={p['rc']} {p['stderr'].strip()[:200]}"); continue
            stats["handback_posted"] += 1
            append_ledger(ledger_path, {"phase": "handback_posted", "run_id": run_id, "ts": now_z(), "id": cid,
                                        "reason": reason, "class": klass})
            out(f"HANDBACK POSTED {cid} {reason} {klass}")
            deps.sleep(HANDBACK_PACE_S)
            continue
        uid, mode = x.get("user_id") or "", x.get("mode")
        if x.get("line") not in LINES or mode not in ("answer", "promise", "close"):
            raise Refused(f"{cid}: the plan row names no line this sender has")
        today = utc_day(deps.now())
        key = backlog.user_key_of(x, emails.get(uid, ""))
        if not key:
            skip("no_ledger_key"); continue
        pre = backlog.ledger_precheck(deps.ledger, cid, key, uid, today)
        if pre:
            skip(pre); continue
        try:
            thread = read_thread(deps.get_conv(cid), non_human, staffed)
        except Exception as e:
            skip("thread unreadable: " + type(e).__name__); continue
        if set(thread.get("contact_ids") or ()) & restricted:
            skip("restricted contact"); continue
        already = note_already_on(cid, thread)
        if already:
            skip("hand-back already posted (" + already + ")"); continue
        why = live_thread_ok(x, thread, deps.now())
        if why:
            skip(why); continue
        if cid in erasure:
            skip("open erasure or access request on this thread"); continue
        if mode == "close" and promises.get(cid):
            skip("an open promise on this thread: answer it, do not close it"); continue
        line = x["line"]
        if uid:
            if presented is None:
                presented = deps.presented(rows)
            if lens is None:
                try:
                    lens = deps.lens(uids)
                except Exception:
                    lens = False
            if presented is False or lens is False:
                skip("account facts unreadable (refuse, never guess)"); continue
            verdict = lens.get(int(uid))
            if verdict is None or verdict.held:
                skip("fraud lens: held or unmeasured"); continue
            if line in ACCOUNT_LINES:
                try:
                    statuses, claims = deps.live_account(uid, presented)
                except Exception:
                    skip("account facts unreadable (refuse, never guess)"); continue
                line, why = account_line(statuses, claims)   # the census never picks an account line
                if not line:
                    skip(why); continue
        elif line in ACCOUNT_LINES:
            raise Refused(f"{cid}: an account line on a row with no account")
        # the promises read in THIS run and the line picked in THIS run: a promise opened since the plan, or
        # an account line that changed at send time, never puts an unrelated sentence on a waiting customer
        if mode != "close" and promise_unmet(line, promises.get(cid)):
            skip("an open promise this line does not keep"); continue
        if line in ACCOUNT_LINES:
            if thread["contacts"] != 1:
                skip("more than one contact on the thread: no account facts are stated there"); continue
            why = deps.stage2_hold(deps.ledger, key, uid, cid, today)
            if why:
                skip(why); continue
        body = LINES[line]
        try:
            v = deps.post_reply(cid, body, line, validate=True)
        except copy_gate.CopyHeld as e:
            stats["copy_held"][line] = stats["copy_held"].get(line, 0) + 1
            skip(f"copy gate holds {line}: {str(e)[:80]}"); continue
        if v["rc"]:
            stats["failed"] += 1
            out(f"REFUSED {cid}: {v['stderr'].strip()[:200]}"); continue
        why = ensure_assigned(cid, thread)
        if why:
            skip(why); continue
        done += 1
        if not apply:
            stats["dry"] += 1
            stats["by_line"][line] = stats["by_line"].get(line, 0) + 1
            out(f"DRY {cid} {mode} {line}")
            continue
        today = utc_day(deps.now())
        claim = backlog.ledger_claim(deps.ledger, cid, key, uid, today, x.get("contact_id") or "", v["verdict_id"])
        if claim["result"] != "claimed":
            done -= 1
            skip(f"ledger: {claim['result']}"); continue
        append_ledger(ledger_path, {"phase": "intent", "run_id": run_id, "ts": now_z(), "id": cid, "line": line,
                                    "mode": mode, "verdict_id": v["verdict_id"]})
        try:
            p = deps.post_reply(cid, body, line)
        except copy_gate.CopyHeld as e:
            p = {"rc": 1, "stdout": "", "stderr": "copy gate: " + str(e)[:200], "verdict_id": ""}
        posted = p["rc"] == 0 and p["stdout"].startswith("POSTED comment")
        backlog.ledger_finalize(deps.ledger, claim["message_row"], cid, p["rc"], p["stdout"], p["stderr"], body,
                                now=clock_now(deps))
        if not posted:
            stats["failed"] += 1
            append_ledger(ledger_path, {"phase": "error", "run_id": run_id, "ts": now_z(), "id": cid,
                                        "what": "reply", "rc": p["rc"]})
            out(f"FAILED {cid}: rc={p['rc']} {p['stderr'].strip()[:200]}"); continue
        stats["sent"] += 1
        stats["by_line"][line] = stats["by_line"].get(line, 0) + 1
        append_ledger(ledger_path, {"phase": "sent", "run_id": run_id, "ts": now_z(), "id": cid, "line": line})
        out(p["stdout"].strip())
        if mode == "close":
            # only after this run's own note POSTED on this conversation, and read back
            append_ledger(ledger_path, {"phase": "close_intent", "run_id": run_id, "ts": now_z(), "id": cid})
            try:
                state = deps.close_thread(cid)
            except Exception as e:
                state = "error:" + type(e).__name__
            if state == "closed":
                stats["closed"] += 1
                append_ledger(ledger_path, {"phase": "closed", "run_id": run_id, "ts": now_z(), "id": cid})
            else:
                stats["failed"] += 1
                append_ledger(ledger_path, {"phase": "error", "run_id": run_id, "ts": now_z(), "id": cid,
                                            "what": "close", "state": state})
        deps.sleep(0.5)
    return stats


def cmd_send(a, token):
    with open(a.plan, encoding="utf8") as f:
        plan = [json.loads(line) for line in f if line.strip()]
    only = tuple(k for k in (a.only or "").split(",") if k)
    stats = run_send(plan, real_deps(token, a.apply), apply=a.apply, max_rows=a.max, only=only,
                     ledger_path=a.ledger or "")
    print(json.dumps(stats, sort_keys=True))
    return 0 if not stats["failed"] else 4


def cmd_lines(_a, _token):
    """Ask the gate about every body. A body with no verdict is queued for the reviewer by the asking."""
    held = 0
    for key, body in LINES.items():
        sha = hashlib.sha256(body.encode("utf-8")).hexdigest()
        try:
            ans = copy_gate.require(GATE_CAMPAIGN, body, copy=key, message_type="comment")
            state = str(ans.get("result")) + (":" + str(ans.get("review")) if ans.get("result") != "approved" else "")
        except copy_gate.CopyHeld as e:
            state = "held:" + str(e)[:120]
        held += state != "approved"
        print(json.dumps({"line": key, "body_sha256": sha, "gate": state, "body": body}))
    return 0 if not held else 3


def cmd_unassign(a, token):
    """Undo this sender's assignments from the inverse each `assigned` row recorded."""
    with open(a.ledger, encoding="utf8") as f:
        rows = [json.loads(line) for line in f if line.strip()]
    latest = {}
    for r in rows:
        if r.get("phase") == "assigned" and r.get("id"):
            latest[str(r["id"])] = r          # a conversation assigned twice in one ledger: the last wins
    try:
        non_human, _staffed = read_who()
    except Unmeasured as e:
        raise Refused(f"UNMEASURED: {e}. Nothing restored.") from e
    stats = {"restored": 0, "refused": 0, "failed": 0}

    def refuse(cid, why, extra=None):
        stats["refused"] += 1
        append_ledger(a.ledger + ".unassign", {"ts": now_z(), "id": cid, "result": "refused", "why": why,
                                               **(extra or {})})

    for cid in sorted(latest):
        before = latest[cid].get("from") or {}
        admin = str(before.get("admin_assignee_id") or "")
        team = str(before.get("team_assignee_id") or "")
        if admin and admin not in non_human:
            refuse(cid, "the recorded holder is a person, not 0 or a bot", {"from": before})
            continue
        try:
            live = read_thread(get_conv(token, cid), non_human)
        except Exception as e:
            refuse(cid, "the thread could not be read", {"live": type(e).__name__})
            continue
        if live.get("read") != "ok":
            refuse(cid, "the thread could not be read", {"live": live.get("read")})
            continue
        if live.get("state") != "open":
            refuse(cid, "the thread is closed", {"live": live.get("state")})
            continue
        if live.get("holder") in HELD_HOLDERS:
            refuse(cid, "held by " + str(live.get("holder")).replace("_", " "), {"live": live.get("holder")})
            continue
        if (str(live.get("admin_assignee_id") or "") != INTERCOM_ADMIN_ID
                or str(live.get("team_assignee_id") or "") != team):
            refuse(cid, "not the assignment this sender made", {"live": live.get("admin_assignee_id"),
                                                                "team": live.get("team_assignee_id")})
            continue
        targets = [(admin, "admin")] if admin else [("0", "admin")] + ([(team, "team")] if team else [])
        try:
            for target, kind in targets:
                assign_thread(token, cid, target, kind)
            back = read_thread(get_conv(token, cid))
            ok = (back.get("read") == "ok" and str(back.get("admin_assignee_id") or "") == admin
                  and str(back.get("team_assignee_id") or "") == team)
        except Exception:
            ok = False
        stats["restored" if ok else "failed"] += 1
        append_ledger(a.ledger + ".unassign", {"ts": now_z(), "id": cid, "before": before,
                                               "result": "restored" if ok else "failed"})
    print(json.dumps(stats, sort_keys=True))
    return 0 if not stats["failed"] else 4


def cmd_reopen(a, token):
    """Open again every conversation the run on this ledger closed, unless it is open already."""
    with open(a.ledger, encoding="utf8") as f:
        ids = sorted({r["id"] for r in (json.loads(line) for line in f if line.strip()) if r.get("phase") == "closed"})
    stats = {"reopened": 0, "already_open": 0, "failed": 0}
    for cid in ids:
        state = str(get_conv(token, cid).get("state") or "unread")
        if state == "open":
            stats["already_open"] += 1
            continue
        try:
            after = reopen_thread(token, cid) if state == "closed" else state
        except Exception:
            after = "error"
        stats["reopened" if after == "open" else "failed"] += 1
        append_ledger(a.ledger + ".reopen", {"ts": now_z(), "id": cid, "before": state, "after": after})
        time.sleep(0.25)
    print(json.dumps(stats, sort_keys=True))
    return 0 if not stats["failed"] else 4


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    sub = ap.add_subparsers(dest="command", required=True)
    p = sub.add_parser("plan")
    p.add_argument("source")
    p.add_argument("--out", required=True)
    p.add_argument("--overrides")
    s = sub.add_parser("send")
    s.add_argument("plan")
    s.add_argument("--apply", action="store_true")
    s.add_argument("--max", type=int, default=MAX_PER_RUN)
    s.add_argument("--only")
    s.add_argument("--ledger")
    sub.add_parser("lines")
    r = sub.add_parser("reopen")
    r.add_argument("--ledger", required=True)
    u = sub.add_parser("unassign")
    u.add_argument("--ledger", required=True)
    a = ap.parse_args(argv)
    token = os.environ.get("MUSOAI_INTERCOM_TOKEN", "")
    if a.command != "lines" and not token:
        print("REFUSED: MUSOAI_INTERCOM_TOKEN is not set", file=sys.stderr)
        return 2
    try:
        return {"plan": cmd_plan, "send": cmd_send, "lines": cmd_lines, "reopen": cmd_reopen,
                "unassign": cmd_unassign}[a.command](a, token)
    except (Refused, overrides.OverridesError) as e:
        print(f"REFUSED: {e}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
