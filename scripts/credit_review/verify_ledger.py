#!/usr/bin/env python3
"""Verify-request ledger: which users were asked to support which credits.

The approved campaigns (CAMPAIGNS; only ASK_CAMPAIGNS count as "already asked") send through ONE path,
scripts/intercom-verify-request.sh, and that gate records every send here, in
the same SQLite file as the decider's ``decisions`` table
(/var/lib/hydra/credit-review/ledger.sqlite3):

  verify-live  NEW provisional approvals by the decider (captain 2026-10-15
               22:12Z: "let users know where there was a credit given and that
               it needs support (trust yet verify approach)"). The WINDOWED
               note (23:40Z: "if no valid verification comes it should be
               removed") gives 30 days, names the reply-by date (removal is due
               from the day after it) and gets reminders at day 14 and day 25. A note sent
               with the earlier unwindowed copy promised no date, so it is never
               removal-due.
  retro-past   PAST credits from the agent batch (09-01 -> 10-11). Captain
               00:35Z: "i dont want to lose users unless its obvious fraud feom
               tbe past"; 02:00Z: "are you annoying people fornbackup that we
               shpuldnt be?". A friendly documentation ask with no deadline and
               no removal language, AT MOST ONE message per user ever, no
               follow-up, and never to a user who already sent proof. Never
               removal-due: a non-response is exported as "unverified" for the
               board, and the credit stays. Proven fraud is removed by its own
               (take-back) path, never by this ledger.

  removal-notice  owners of credits WE removed (non-self, non-fraud) are told which
               credit, why, and how to dispute. Not an ask: never removal-due, no
               follow-ups; idempotent per removal event id.
  takeback-notice  the notice of a proven take-back (credit_retro/notice.py). Not an ask.
  uvn-status   one status + reminder per user whose requests wait on them
               (user_verification_needed), ever; an ask (credit_review/uvn_status.py).
  withdrawal-confirm  confirms a requester-withdrawn request, once per request. Not an ask.
  gap-ask      the stage-2 gap ask (Fable 2026-10-26 13:23Z): a user whose document on file
               does not cover a held credit is told what it shows and what is missing. An ask,
               once per credit, at most one message per user per day and none within 7 days of
               another note (a status-doc-received note excepted: the gap ask is the follow-up it
               promised). Not blocked by an earlier ask about the same credit, nor by a proof
               reply: the user's earlier reply is what stage 2 judged.
  Details: docs/credit-verification/verify-request-notes.md.

Guarantees:
  - a request id gets a campaign's initial note AT MOST once;
  - each reminder kind is sent AT MOST once per note, and an after-rejection note
    names a credit AT MOST once (windowed notes only);
  - retro-past and uvn-status: one message per user, ever, and none to a user with a proof
    reply (uvn-status also none within 7 days of another note);
  - a user gets AT MOST one message per UTC day across every campaign and kind;
  - the claim is written BEFORE the POST, so a crash or timeout after the POST can
    never produce a second message: an ``attempted`` row blocks a resend until a
    human clears it. Only ``rejected`` (Intercom answered an error, nothing landed)
    is retried, at most MAX_ATTEMPTS times.

Statuses:
  attempted  claimed, POST in flight or outcome unknown (blocks resend)
  sent       Intercom confirmed an admin_message, or (in-thread) a Caroline comment part (terminal)
  rejected   Intercom answered an error; nothing was delivered (retryable)
  refused    the gate refused (no unique Intercom user, leak check, ...) (terminal)
  skipped    verify_requests: a wave row the server no longer has approved, so it is
             never announced (terminal; message_row 0). verify_messages: a follow-up
             with nothing left to send (every credit documented, approved by a person
             or no longer approved), closed so it is never offered again (terminal)
  deferred_pending_doc  (verify_requests only, verify-live) a NEW credit held back
             while its user has a document under review on another credit. Not
             blocking and no message: the driver offers it again on every run,
             whatever its age, until it is notified, skipped or closed (which
             overwrite the row; deferred_at stays, so a rejected send of it is
             still offered while retries are left). Never removal-due.

Removal (windowed notes only) is per credit: removal-due from the day after the reply-by
date unless an accepted document cleared the credit (verify_proof_reviews) or a tagged
document awaits review for it (held for a human). A rejected credit gets ONE after-rejection
note of its own (a later rejection on the same note gets another note for the newly rejected
credits; the reviewer's fixed reason, or "we still need a document" after a reply with no
document; a reply-by date at least 7 days out) and is removal-due only after the date that
note named. Any user reply to the note (extension_requested_at) holds its unreviewed credits
for a human, and a reply after a credit's after-rejection note holds that credit until a
review rules on it again (last_reply_at per message).

The wrapper calls this as a CLI (one op per call, JSON on stdout). The driver
(credit_review/verify_notify.py) imports it.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import sqlite3
import urllib.parse
import sys
from datetime import date, datetime, timedelta, timezone
from pathlib import Path
from typing import Any

DEFAULT_PATH = os.environ.get("CREDIT_REVIEW_LEDGER", "/var/lib/hydra/credit-review/ledger.sqlite3")
MAX_ATTEMPTS = 3
BLOCKING = ("attempted", "sent", "refused", "skipped")
DEFERRED = "deferred_pending_doc"
CAMPAIGNS = ("verify-live", "retro-past", "removal-notice", "takeback-notice", "uvn-status", "withdrawal-confirm",
             "status-doc-received", "status-team-review", "email-changed", "email-changed-dup",
             "claim-proof-ask", "claim-status", "gap-ask", "merge-pending", "credit-hold-status", "claim-proof-pending", "proof-need-ask",
             "merge-claim-first",
             "reply-ref",   # [key=product-dispute-refs]: r5's approved reply set, reply_due answers only
             "refund-confirm",   # fable-copy-1103-d2/refund-confirm: a refund that ALREADY happened, told once per refund id
             "uvn-new-rows")   # fable-copy-1101-r5/n1: a told user's owed rows no ask named (one message per row ever)
# claim-proof-ask (steers-1830 #5, firstmate 125/126): a dated ask to the claimant of a pending
# profile CLAIM (band B/C) to put the claim's bound-proof code in one platform bio. Its "request
# id" is the claim key "claim-<claiming.id>", so only its own rows block it (claim ids never meet
# credit request ids); one note per claim, ever, plus ONE day-7 reminder; the initial note
# names the close day (due_day), the reminder repeats it. Its rows never count as a credit
# ask or as credit proof: a reply with attachments is tagged claim-proof, not credit-proof.
CLAIM_CAMPAIGN = "claim-proof-ask"
CLAIM_REMINDER = "reminder-7"
CLAIM_WINDOW_DAYS = 14          # the close day: always 14 days after the note
# claim-status (Fable claims-documentation-readiness-1023 ruling 3): a no-ask status note to the
# claimant of a pending claim who gets NO proof ask (holds, organizations, claims with no surface
# the daily code check can read). Same claim key, one note per claim ever, no follow-up. Never
# for a claim that has a claim-proof-ask note, and nobody gets the other claim note within 7 days
# of one (claim_cross_check). Its replies are claim-proof (a person), never credit proof.
CLAIM_STATUS_CAMPAIGN = "claim-status"
# claim-proof-pending (Fable copy-owing-proof-1027 S2; send-locked until the captain's L14b): the neutral line
# to a claimant whose claim needs proof while the claim ask is off. Same claim key and the same rules as
# claim-status (claim_cross_check): one note per claim ever, never to a claim with a claim-proof-ask note,
# never within 7 days of another note; a claim-proof-ask waits 7 days after it.
CLAIM_PENDING_CAMPAIGN = "claim-proof-pending"
CLAIM_CAMPAIGNS = (CLAIM_CAMPAIGN, CLAIM_STATUS_CAMPAIGN, CLAIM_PENDING_CAMPAIGN)
# credit-hold-status (Fable S1; send-locked until L14a): the neutral line to a credit requester who owes
# proof while no ask can go out. A once-per-user status campaign (STATUS_CAMPAIGNS) and a notice: NOT an
# ask (it asks for nothing), and NOT in STATUS_NOTE_CAMPAIGNS, so hold-silent (which stops the "nothing
# else is needed" notes) does not stop it: Fable, "S1 goes to held accounts too".
CREDIT_HOLD_CAMPAIGN = "credit-hold-status"
GAP_ASK = "gap-ask"
# merge-pending (go-live-today line M1; send-locked until the captain's yes): a status note per merge request, key
# "merge-<merge request id>". A notice (only its own rows block it: one note per merge request, ever), never an
# ask, and never within 7 days of another note from this gate to the user (messaged_7d, a deferral).
MERGE_PENDING = "merge-pending"
# merge-claim-first (r5 copy e1): the claim-first ask for the dup-dsp-linked class; key "mcf-<user id>", so only its own
# rows block it (one ask per user, ever). Not a credit ask (its replies are claim/merge, never credit proof).
MERGE_CLAIM_FIRST = "merge-claim-first"
# proof-need-ask (proof-loop captain card L11c; send-locked until the captain's yes): the per-need ask for ONE
# credit whose document the reader could not check. An ASK (it counts for the one-ask locks), handled like
# gap-ask: it exists because a document arrived, so only its own rows and a gap ask on the same request block
# it (once per request, ever), and it may follow a status-doc-received note inside 7 days.
PROOF_NEED_ASK = "proof-need-ask"
GAP_LIKE = (GAP_ASK, PROOF_NEED_ASK)
# The notes the gap ask may follow inside 7 days (one per day still holds): the doc-received
# status note says "we have the document you sent ... we'll message you here as soon as it's
# checked", and the gap ask is that message (firstmate, verify-ask-wiring-h2 inbox 003).
GAP_ASK_FOLLOWS = ("status-doc-received",)
# Once-per-user status campaigns: one message per user ever (per campaign), never within 7 days
# of another note from this gate. Only uvn-status is an ask (and also stops after a proof reply).
STATUS_CAMPAIGNS = ("uvn-status", "status-doc-received", "status-team-review", CREDIT_HOLD_CAMPAIGN)
# Notices: only their own rows block them (they are not asks and never close one).
NOTICE_CAMPAIGNS = ("takeback-notice", "withdrawal-confirm", "status-doc-received", "status-team-review",
                    "email-changed", "email-changed-dup", CLAIM_CAMPAIGN, CLAIM_STATUS_CAMPAIGN, MERGE_PENDING, MERGE_CLAIM_FIRST,
                    CLAIM_PENDING_CAMPAIGN, CREDIT_HOLD_CAMPAIGN, "reply-ref")
# Campaigns whose gate refusals are re-checkable (firstmate 076, 082, 083): a refusal holds the
# USER (campaign, user_key or user_id) in verify_refusal_holds for RECHECK_DAYS (the runner and the gate skip
# them until next_recheck_at, whatever requests are listed); a later send clears it; after
# MAX_REFUSALS refusals it is posted once to #cs_priority for a human and the user is blocked.
RECHECKABLE_REFUSALS = ("status-doc-received", "status-team-review", "email-changed", "email-changed-dup",
                        CREDIT_HOLD_CAMPAIGN)
RECHECK_DAYS = 7
MAX_REFUSALS = 3
# The campaigns that ASK the user for something. Only these count as "already asked";
# notices and confirmations (removal-notice, takeback-notice, withdrawal-confirm) never close
# a user's asks (firstmate 063/064).
UVN_NEW_ROWS = "uvn-new-rows"
# an uvn-new-rows note IS an ask (its rows are never asked again by any ask), but it is never the user's one-ask-ever:
# it exists because the user was already asked (prior_uvn_ask)
ASK_CAMPAIGNS = ("verify-live", "retro-past", "uvn-status", GAP_ASK, PROOF_NEED_ASK, UVN_NEW_ROWS)
# Historical only (deleted from the sender 2026-11-04): rows of this kind stay readable in
# the ledger, and `reminders_due` no longer offers it. Do not re-add it to a sender campaign
# without a new copy ruling - the old copy named which check failed.
AFTER_REJECTION = "after-rejection"
KINDS = ("initial", "reminder-14", "reminder-25", AFTER_REJECTION, CLAIM_REMINDER)
# Days after a WINDOWED note (reminder-14/25) or a claim-proof-ask note (reminder-7) at which each
# reminder becomes due.
REMINDER_DAYS = {"reminder-14": 14, "reminder-25": 25, CLAIM_REMINDER: 7}
# The after-rejection note's reply-by date is never earlier than this many days after it is sent.
AFTER_REJECTION_MIN_DAYS = 7
# The reviewer's reason for a rejection: a fixed list, the only text the after-rejection note shows.
REJECTION_REASONS = ("doesnt_name_you", "other_track", "other_role", "unreadable", "not_a_document")
WINDOW_DAYS = 30            # windowed (new provisional approval) notes only
UNVERIFIED_AFTER_DAYS = 30  # retro-past: no proof after this long -> exported as unverified (credit stays)

SCHEMA = """
CREATE TABLE IF NOT EXISTS verify_messages (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  campaign TEXT NOT NULL,            -- verify-live | retro-past | removal-notice
  kind TEXT NOT NULL,                -- initial | reminder-14 | reminder-25 | after-rejection
  parent_row INTEGER,                -- follow-ups: verify_messages.id of the initial note
  user_key TEXT NOT NULL,            -- lower-cased account email (never printed)
  account_id TEXT,                   -- the Muso user id: the per-user locks key on it too (an email can change)
  day TEXT NOT NULL,                 -- UTC YYYY-MM-DD the per-day cap counts on
  due_day TEXT,                      -- windowed notes: last day of the 30-day window
  removal_day TEXT,                  -- windowed notes: the removal date the note named
  status TEXT NOT NULL,              -- attempted | sent | rejected | refused | deferred (log_deferral: no message)
  message_type TEXT NOT NULL,        -- email (POST /messages) | comment (in-thread reply)
  contact_id TEXT,                   -- Intercom contact the note went to
  message_id TEXT,                   -- Intercom admin_message id (in-thread: the conversation part id)
  conversation_id TEXT,
  request_ids_json TEXT NOT NULL,
  refs_json TEXT,                    -- [{request_id, profile_id, track_id}] for re-reads
  n_credits INTEGER NOT NULL,
  approved_by TEXT NOT NULL,
  approval_ref TEXT NOT NULL,
  body_sha256 TEXT,
  reason TEXT,
  api_log TEXT,
  attempts INTEGER NOT NULL DEFAULT 1,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  sent_at TEXT,                      -- immutable: the first time this note was finalized 'sent' (clocks start here)
  proof_tagged_at TEXT,              -- a reply with attachments was tagged credit-proof (awaiting review)
  proof_checked_at TEXT,             -- last proof sweep look (sweep rotates oldest-checked first)
  proof_attachments INTEGER NOT NULL DEFAULT 0,  -- user attachments counted when last tagged
  extension_requested_at TEXT,       -- initial note: the user replied (text or attachment); removal held for a human
  last_reply_at TEXT,                -- this message: time of the latest user reply seen in its conversation
  copy_ref TEXT,                     -- p1 615: the gate's copy token this note rendered (uvn, docrecvr, refq, ...)
  variant TEXT,                      -- p1 615: the openers/prefixes it carried, comma-joined (c2, reply_due_correction, o)
  approver_kind TEXT,                -- captain-slack | fable-ruling; NULL only on rows written before 2026-11-03
  approval_id TEXT,                  -- the Slack UID, or the fable-ruling-YYYYMMDD-N id, that authorizes this send
  template_sha256 TEXT               -- sha256 of the template identity it rendered (campaign|kind|copy|variant)
);
CREATE TABLE IF NOT EXISTS verify_proof_reviews (
  family INTEGER NOT NULL,           -- verify_messages.id of the initial note
  request_id TEXT NOT NULL,
  outcome TEXT NOT NULL,             -- accepted | rejected (the document review, never this gate)
  reason TEXT,                       -- rejected with a document: one of REJECTION_REASONS
  document INTEGER NOT NULL DEFAULT 0,  -- 1: a document (attachment) was received on the note; 0: a reply only
  reviewed_at TEXT NOT NULL,
  reviewed_by TEXT NOT NULL,
  PRIMARY KEY (family, request_id)
);
CREATE TABLE IF NOT EXISTS verify_requests (
  campaign TEXT NOT NULL,
  request_id TEXT NOT NULL,
  message_row INTEGER NOT NULL,      -- verify_messages.id of the latest initial attempt
  status TEXT NOT NULL,
  attempts INTEGER NOT NULL DEFAULT 1,
  updated_at TEXT NOT NULL,
  profile_id TEXT,                   -- deferred_pending_doc: the refs for the re-read
  track_id TEXT,
  deferred_at TEXT,                  -- deferred_pending_doc: when first held back
  PRIMARY KEY (campaign, request_id)
);
CREATE TABLE IF NOT EXISTS verify_refusal_holds (
  campaign TEXT NOT NULL,            -- a RECHECKABLE_REFUSALS campaign
  user_key TEXT NOT NULL,            -- lower-cased account email (never printed)
  user_id TEXT,                      -- the Muso account id (the only id the human flag shows)
  refusals INTEGER NOT NULL DEFAULT 0,  -- refusals since the last send
  reason TEXT,                       -- the gate's latest reason
  next_recheck_at TEXT NOT NULL,     -- the user is skipped until this time
  flagged_at TEXT,                   -- posted to #cs_priority after MAX_REFUSALS: blocked from then on
  updated_at TEXT NOT NULL,
  PRIMARY KEY (campaign, user_key)
);
CREATE TABLE IF NOT EXISTS verify_channel_clears (
  user_key TEXT NOT NULL,            -- lower-cased account email
  user_id TEXT NOT NULL DEFAULT '',  -- the Muso account id
  cleared_by TEXT NOT NULL,          -- the person who cleared the no-channel hold (Slack id / name)
  ref TEXT NOT NULL,                 -- why (the ticket, the contact fix)
  cleared_at TEXT NOT NULL,
  after_row INTEGER NOT NULL DEFAULT 0   -- verify_messages max(id) when cleared: covers failures up to that row only
);
CREATE TABLE IF NOT EXISTS reply_ref_picks (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  conversation TEXT NOT NULL,        -- QA #1601 (2): the classifier's pick, recorded BEFORE the gate is called,
  part TEXT NOT NULL,                -- keyed by conversation + the customer part it answers
  ref TEXT NOT NULL,                 -- the allow-listed ref id it picked (fable-copy-1031-r5/<letter>) or a non-ref
  reason TEXT NOT NULL,              -- 'mapped' is the only reason a reply-ref may be posted on
  llm_call_id TEXT,                  -- the credit_trust.llm row of the classification (append-only audit)
  refs_sha256 TEXT,                  -- the allow-list file the pick was made against
  picked_at TEXT NOT NULL
);
"""
INDEXES = """
CREATE INDEX IF NOT EXISTS verify_messages_user_day ON verify_messages(user_key, day);
CREATE INDEX IF NOT EXISTS verify_messages_msg ON verify_messages(message_id);
CREATE INDEX IF NOT EXISTS verify_messages_parent ON verify_messages(parent_row, kind);
"""
TABLES = ("verify_messages", "verify_proof_reviews", "verify_requests", "verify_refusal_holds", "verify_channel_clears",
          "reply_ref_picks")
# The verify_messages columns credit-retro's take-back / wave reader depends on
# (credit_retro.waves.already_engaged). Pinned here, next to the writer's schema, and
# checked against it by scripts/tests/test_verify_ledger_contract.py.
READER_COLUMNS = frozenset({"request_ids_json", "proof_tagged_at", "user_key", "campaign", "status", "kind"})


def utcnow() -> datetime:
    return datetime.now(timezone.utc)


def stamp(now: datetime | None = None) -> str:
    return (now or utcnow()).strftime("%Y-%m-%dT%H:%M:%SZ")


# QA #1564 (round 3): a process under the credit-ops-notes kill sets this ONCE; from then on EVERY connect() in the
# process - the runner's, verify_notify's, any later one - is connect_ro(must_exist=True): never created, never migrated,
# and a write fails loud (sqlite: readonly database). Not a per-call promise that a later open could forget.
READ_ONLY_PROCESS = False


def connect(path: str) -> sqlite3.Connection:
    if READ_ONLY_PROCESS and path != ":memory:":
        return connect_ro(path, must_exist=True)
    if path != ":memory:":
        Path(path).parent.mkdir(parents=True, exist_ok=True)
    db = sqlite3.connect(path, timeout=30, isolation_level=None)
    db.row_factory = sqlite3.Row
    db.executescript(SCHEMA)
    _migrate(db)
    db.executescript(INDEXES)
    return db


class ReadOnlyLedgerError(RuntimeError):
    """A read-only open is impossible without writing (the ledger is missing or needs a migration)."""


def connect_ro(path: str, *, must_exist: bool = False) -> sqlite3.Connection:
    """QA #1564: the ledger opened READ-ONLY (mode=ro) - never created, never migrated. A missing ledger, or one whose
    schema lacks any table, index, trigger, view or column connect() would add (it would CREATE / ALTER), raises: the caller that must not
    write (a dry run under the credit-ops-notes kill, the gate's --check-recipient) then refuses instead.
    A ledger that does not exist yet reads as an EMPTY one (an in-memory copy of the schema: nothing was ever sent, so
    nothing is recorded) and no file is created; `must_exist` makes a missing ledger an error instead."""
    if path == ":memory:" or not Path(path).exists():
        if must_exist:
            raise ReadOnlyLedgerError(f"verify ledger {path} does not exist (a read-only run never creates it)")
        mem = sqlite3.connect(":memory:", isolation_level=None)
        mem.row_factory = sqlite3.Row
        mem.executescript(SCHEMA)
        mem.executescript(INDEXES)
        return mem
    # QA #1564: the path is PERCENT-ENCODED into the URI - a raw '?' (or '#') in it would end the path early and open a
    # different, writable file without mode=ro
    db = sqlite3.connect(f"file:{urllib.parse.quote(str(Path(path).resolve()))}?mode=ro", uri=True, timeout=30,
                         isolation_level=None)
    db.row_factory = sqlite3.Row
    ref = sqlite3.connect(":memory:")
    try:
        # QA #1564 (round 2): EVERYTHING connect() could write is checked - every table, index, trigger and view that
        # SCHEMA + INDEXES create (a missing index = CREATE INDEX = a schema write), and every column (_migrate)
        ref.executescript(SCHEMA)
        ref.executescript(INDEXES)
        q = "SELECT type, name FROM sqlite_master WHERE name NOT LIKE 'sqlite_%'"
        missing = sorted({(str(t), str(n)) for t, n in ref.execute(q)} - {(str(t), str(n)) for t, n in db.execute(q)})
        if missing:
            db.close()
            raise ReadOnlyLedgerError(f"verify ledger {path} needs a migration (missing {missing[:3]}); "
                                      "a read-only run never migrates it")
        for table in TABLES:
            have = {str(r[1]) for r in db.execute(f"PRAGMA table_info({table})").fetchall()}
            want = {str(r[1]) for r in ref.execute(f"PRAGMA table_info({table})").fetchall()}
            if want - have:
                db.close()
                raise ReadOnlyLedgerError(f"verify ledger {path} needs a migration ({table}: {sorted(want - have)[:3]}); "
                                          "a read-only run never migrates it")
    finally:
        ref.close()
    return db


def _migrate(db: sqlite3.Connection) -> None:
    """Add every column SCHEMA has that an existing (older) table lacks, so a ledger
    created by an earlier version of this module keeps working."""
    ref = sqlite3.connect(":memory:")
    try:
        ref.executescript(SCHEMA)
        for table in TABLES:
            have = {str(r[1]) for r in db.execute(f"PRAGMA table_info({table})").fetchall()}
            for _, name, typ, notnull, default, _ in ref.execute(f"PRAGMA table_info({table})").fetchall():
                if name in have:
                    continue
                decl = f"{name} {typ}"
                if default is not None:
                    decl += f"{' NOT NULL' if notnull else ''} DEFAULT {default}"
                db.execute(f"ALTER TABLE {table} ADD COLUMN {decl}")
    finally:
        ref.close()


def _check(campaign: str, kind: str = "initial") -> None:
    if campaign not in CAMPAIGNS:
        raise ValueError(f"unknown campaign {campaign!r}")
    if kind not in KINDS:
        raise ValueError(f"unknown kind {kind!r}")


# ---------------------------------------------------------------------------------------
# The approval stamp (captain 2026-11-03: "users aren't in the dark ... no human reviews is the goal").
# A send is authorized either by a human's Slack id (the original path) or by a Fable ruling that pre-approved the
# exact template class (policies/fable-rulings.json). Which one it was, and the template it rendered, is stamped on the
# row so an audit answers "who authorized this send?" from the ledger alone - never from a log, a chat or a promise.
APPROVER_CAPTAIN = "captain-slack"
# The captain's Slack user id: the ONLY approver the pre-stamp gate accepted. A row with no approver_kind whose
# approved_by is this id was authorised by that gate, before the stamp columns existed (see stamp_problem).
CAPTAIN_UID = "U7RP6HKUZ"
# When the STAMPED gate went live: the deploy that shipped the stamp columns (hydra deploy run 42021981460, started
# 2026-11-05T11:48:49Z). A row created BEFORE this instant cannot have been written by the stamped gate, so a NULL
# approver_kind on it is history. A row created AFTER it must carry a stamp - the gate always writes one - so a NULL
# kind there is a finding no matter who approved_by names. The deploy START is used, not its completion, because a row
# written while the deploy was still running is ambiguous and the fail-closed answer is "finding".
# Move this forward only with a deploy that changes the stamp; STAMP_CUTOVER_OVERRIDE exists for tests.
STAMP_CUTOVER = "2026-11-05T11:48:49Z"
APPROVER_RULING = "fable-ruling"
APPROVER_KINDS = (APPROVER_CAPTAIN, APPROVER_RULING)
SLACK_UID_RE = re.compile(r"^U[A-Z0-9]{8,12}$")
RULING_ID_RE = re.compile(r"^fable-ruling-[0-9]{4}-[A-Za-z0-9][A-Za-z0-9._-]*(/[A-Za-z0-9][A-Za-z0-9._-]*)?$")
TEMPLATE_SHA_RE = re.compile(r"^[0-9a-f]{64}$")


def approval_stamp(kind: str = "", approval_id: str = "", template_sha256: str = "",
                   approved_by: str = "") -> tuple[str | None, str | None, str | None]:
    """Validate and normalise one approval stamp. An absent kind is legal (a caller that predates the stamp), but a
    kind without a usable id is always a bug: a half stamp reads as authorized to everyone downstream."""
    if not kind:
        if approval_id or template_sha256:
            raise ValueError("an approval id or template hash without its approver kind is not a stamp")
        return None, None, None
    if kind not in APPROVER_KINDS:
        raise ValueError(f"unknown approver kind {kind!r} (one of {', '.join(APPROVER_KINDS)})")
    if not approval_id:
        raise ValueError("an approval stamp needs an approval id (a Slack user id or a ruling id)")
    if kind == APPROVER_CAPTAIN and not SLACK_UID_RE.match(approval_id):
        raise ValueError(f"captain-slack approval id {approval_id!r} is not a human's Slack user id")
    if kind == APPROVER_RULING and not RULING_ID_RE.match(approval_id):
        raise ValueError(f"fable-ruling approval id {approval_id!r} is not a fable-ruling-YYYYMMDD-N id")
    if template_sha256 and not TEMPLATE_SHA_RE.match(template_sha256):
        raise ValueError("the template hash must be 64 lowercase hex characters")
    if approved_by and approved_by != approval_id:
        raise ValueError(f"the stamp names {approval_id} but approved_by is {approved_by!r}: an audit cannot tell "
                         "which one authorized the send")
    return kind, approval_id, template_sha256 or None


def template_identity_sha256(*, campaign: str, kind: str, copy_ref: str, variant: str = "") -> str:
    """The template identity hash the gate stamps: campaign|kind|copy|variant. It pins WHICH approved template a note
    rendered (so a send of an unregistered copy token is visible in the ledger); the prose itself is pinned by the
    gate's byte-exact copy tests and by body_sha256, which the finalize step records for the exact bytes sent."""
    identity = "|".join((campaign, kind, copy_ref, variant or ""))
    return hashlib.sha256(identity.encode("utf-8")).hexdigest()


def _plus(day: str, n: int) -> str:
    return (date.fromisoformat(day) + timedelta(days=n)).isoformat()


def claim_close_day(day: str) -> str:
    """The close day a claim-proof-ask note sent on `day` names: CLAIM_WINDOW_DAYS after it."""
    return _plus(day, CLAIM_WINDOW_DAYS)


def window(day: str) -> tuple[str, str]:
    """(due_day, removal_day) of a windowed note sent on `day`. The note names ONE date
    (Fable copy review 2026-10-17): the reply-by date, 30 days after the note. A reply by
    the end of that (UTC) day is in time, so the credit is removal-due only from the next
    day, 00:00Z."""
    due = _plus(day, WINDOW_DAYS)
    return due, _plus(due, 1)


def _marks(seq: tuple[str, ...] | list[str]) -> str:
    """'?,?,...' for an IN list over `seq` (never a hard-coded count: the campaign tuples grow)."""
    return ",".join("?" * len(seq))


def blocked_ids(db: sqlite3.Connection, request_ids: list[str], campaign: str = "verify-live") -> set[str]:
    """Request ids that must not get this campaign's initial note: already noted,
    refused or skipped in this campaign, or already asked about in any ASK campaign
    (never re-ask the same credit, no repeats across waves). takeback-notice and
    withdrawal-confirm are not asks but notices about that very request, so only their own
    rows block them. gap-ask exists BECAUSE the credit was asked about and the reply did not
    cover it, so it too is blocked only by its own rows."""
    out: set[str] = set()
    asks = ",".join("?" * len(ASK_CAMPAIGNS))
    for rid in request_ids:
        if campaign in GAP_LIKE:
            # the document asks never cross on one request: a gap ask closes it for proof-need-ask and back
            sib = [c for c in GAP_LIKE if c != campaign]
            other = db.execute(
                f"SELECT 1 FROM verify_requests WHERE request_id=? AND campaign IN ({_marks(sib)}) "
                "AND status IN ('attempted','sent') LIMIT 1", (rid, *sib)).fetchone()
        else:
            other = None if campaign in NOTICE_CAMPAIGNS else db.execute(
                f"SELECT 1 FROM verify_requests WHERE request_id=? AND campaign<>? AND campaign IN ({asks}) "
                "AND status IN ('attempted','sent') LIMIT 1", (rid, campaign, *ASK_CAMPAIGNS)).fetchone()
        if other is not None:
            out.add(rid)
            continue
        r = db.execute("SELECT status, attempts FROM verify_requests WHERE campaign=? AND request_id=?",
                       (campaign, rid)).fetchone()
        if r is None:
            continue
        if r["status"] in BLOCKING or (r["status"] == "rejected" and int(r["attempts"]) >= MAX_ATTEMPTS):
            out.add(rid)
    return out


def _hold_of(user_key: str, user_id: str = "") -> tuple[str, tuple[Any, ...]]:
    """SQL condition + params for "this user's refusal hold": the same account email OR the same
    Muso user id, so an email change neither frees a held user nor resets the refusal count."""
    uid = str(user_id or "").strip()
    return ("(user_key = ? OR user_id = ?)", (user_key, uid)) if uid else ("user_key = ?", (user_key,))


def refusal_hold(db: sqlite3.Connection, campaign: str, user_key: str, now: datetime | None = None,
                 user_id: str = "") -> dict[str, Any]:
    """This user's re-check state in a RECHECKABLE_REFUSALS campaign: {} (free),
    {"flagged": True} (refused MAX_REFUSALS times and flagged: blocked) or
    {"until": next_recheck_at} (held after a refusal). "This user" is _hold_of."""
    if campaign not in RECHECKABLE_REFUSALS or not (user_key or str(user_id or "").strip()):
        return {}
    cond, params = _hold_of(user_key, user_id)
    rows = db.execute(f"SELECT next_recheck_at, flagged_at FROM verify_refusal_holds WHERE campaign=? AND {cond}",
                      (campaign, *params)).fetchall()
    if any(r["flagged_at"] for r in rows):
        return {"flagged": True}
    until = max((str(r["next_recheck_at"]) for r in rows), default="")
    return {"until": until} if until > stamp(now) else {}


def no_channel(db: sqlite3.Connection, user_key: str, user_id: str = "") -> str:
    """r5 / p1 (10-31 17:1xZ) [no-channel]: when this user's LATEST delivery outcome from this gate (a sent or a rejected
    row, any campaign) is Intercom refusing the message with action_forbidden, the contact cannot be reached: '' -> a
    reason, and NO campaign re-attempts them - the no-channel tray - until a person records a clear after that rejection
    (clear-no-channel). A later successful send ends it too. Read at the dry run (pending) and at the send (claim)."""
    if not (user_key or str(user_id or "").strip()):
        return ""
    cond, params = _same_user(db, user_key, user_id)
    # QA #1588: ordered by ROW ID (monotonic), never by 1-second timestamps. The channel FAILURES: an Intercom
    # action_forbidden rejection, or #1511's terminal refusal (email unreachable and no in-app route) - p1 17:35Z. Only a
    # later successful SEND ends one; any other rejection or refusal after it proves nothing about the channel.
    last = db.execute(f"SELECT m.id, m.day, m.status, m.reason FROM verify_messages m WHERE ({cond}) AND ("
                      "(m.status = 'rejected' AND m.reason LIKE '%action_forbidden%') OR "
                      "(m.status = 'refused' AND m.reason LIKE 'no_channel: email_unreachable%')) "
                      "ORDER BY m.id DESC LIMIT 1", params).fetchone()
    if last is None:
        return ""
    if db.execute(f"SELECT 1 FROM verify_messages m WHERE ({cond}) AND m.status = 'sent' AND m.id > ? LIMIT 1",
                  (*params, last["id"])).fetchone():
        return ""
    uid = str(user_id or "").strip()
    # a person's clear covers the failures written BEFORE it (by row id): a refusal after the clear holds again
    cleared = db.execute("SELECT max(after_row) FROM verify_channel_clears WHERE user_key = ? OR (? <> '' AND user_id = ?)",
                         (user_key, uid, uid)).fetchone()[0]
    if cleared is not None and int(cleared) >= int(last["id"]):
        return ""
    what = "Intercom refused our message with action_forbidden" if last["status"] == "rejected" else \
        "Intercom will not email this contact and there is no in-app route (email_unreachable)"
    return f"no_channel: {what} on {last['day']} (ledger {last['id']})"


def clear_no_channel(db: sqlite3.Connection, *, user_key: str, user_id: str, cleared_by: str, ref: str,
                     now: datetime | None = None) -> None:
    if not (cleared_by.strip() and ref.strip()):
        raise ValueError("a no-channel clear names the person and the reason")
    hi = db.execute("SELECT coalesce(max(id), 0) FROM verify_messages").fetchone()[0]
    db.execute("INSERT INTO verify_channel_clears (user_key, user_id, cleared_by, ref, cleared_at, after_row) VALUES (?,?,?,?,?,?)",
               (user_key, str(user_id or ""), cleared_by.strip(), ref.strip(), stamp(now), int(hi)))


def _same_user(db: sqlite3.Connection, user_key: str, user_id: str = "") -> tuple[str, tuple[Any, ...]]:
    """SQL condition (on verify_messages m) + params for "a message to THIS user": the same
    account email, OR the same Muso user id - stored on the row (account_id), or, for rows
    written before account_id existed, the user the decider recorded for any credit the note
    covered. An account whose email changed is still the same user (QA review of hydra#1257
    @21f2de0: the 90-day lock must not reset on an address change)."""
    uid = str(user_id or "").strip()
    if not uid:
        return "m.user_key = ?", (user_key,)
    cond, params = "m.user_key = ? OR m.account_id = ?", [user_key, uid]
    if db.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name='decisions'").fetchone() and \
            "user_id" in {r[1] for r in db.execute("PRAGMA table_info(decisions)")}:
        cond += (" OR (m.account_id IS NULL AND EXISTS (SELECT 1 FROM json_each(m.request_ids_json) j "
                 "JOIN decisions d ON d.request_id = j.value WHERE CAST(d.user_id AS TEXT) = ?))")
        params.append(uid)
    return f"({cond})", tuple(params)


def capped(db: sqlite3.Connection, *, user_key: str, day: str, user_id: str = "") -> bool:
    """True when this user already has a message (attempted or sent) on this UTC day, any campaign."""
    cond, params = _same_user(db, user_key, user_id)
    return db.execute(f"SELECT 1 FROM verify_messages m WHERE {cond} AND m.day=? AND m.status IN ('attempted','sent') "
                      "LIMIT 1", (*params, day)).fetchone() is not None


REASK_LOCK_DAYS = 90


def prior_uvn_ask(db: sqlite3.Connection, user_key: str, user_id: str = "") -> bool:
    """fable-copy-1101-r5/n1 gate fact: this user has a SENT uvn-status ask (the 'told' user the n1 opener is true for)."""
    if not (user_key or str(user_id or "").strip()):
        return False
    cond, params = _same_user(db, user_key, user_id)
    return db.execute(f"SELECT 1 FROM verify_messages m WHERE ({cond}) AND m.campaign = 'uvn-status' AND m.kind = 'initial' "
                      "AND m.status = 'sent' LIMIT 1", params).fetchone() is not None


def asked_within(db: sqlite3.Connection, *, user_key: str, day: str, days: int = REASK_LOCK_DAYS,
                 user_id: str = "") -> bool:
    """True when this user got an initial ASK (any ASK_CAMPAIGNS note, attempted or sent)
    in the last `days` days: the shared per-user re-ask lock (Fable 2026-10-17, decision
    verify-notify-enable precondition 4). Follow-ups of that note are not new asks."""
    try:
        since = _plus(day, -days)
    except ValueError:
        since = ""  # an unreadable day: any earlier ask counts (stricter, never looser)
    cond, params = _same_user(db, user_key, user_id)
    q = (f"SELECT 1 FROM verify_messages m WHERE {cond} AND m.kind='initial' AND m.status IN ('attempted','sent') "
         f"AND m.campaign IN ({','.join('?' * len(ASK_CAMPAIGNS))}) AND m.day > ? LIMIT 1")
    return db.execute(q, (*params, *ASK_CAMPAIGNS, since)).fetchone() is not None


def past_user_done(db: sqlite3.Connection, user_key: str, user_id: str = "") -> str:
    """retro-past: why this user must not get a past-credit ask ('' when they may).
    One ask per user, ever (an ask from any ASK campaign counts: no repeats across
    waves; a notice or confirmation does not); and never re-ask someone who already sent
    proof (a credit-proof reply on any credit note; a reply to a claim note is not credit proof)."""
    cond, params = _same_user(db, user_key, user_id)
    asks = ",".join("?" * len(ASK_CAMPAIGNS))
    if db.execute(f"SELECT 1 FROM verify_messages m WHERE {cond} AND m.kind='initial' AND m.campaign IN ({asks}) "
                  "AND m.status IN ('attempted','sent') LIMIT 1", (*params, *ASK_CAMPAIGNS)).fetchone():
        return "already_asked"
    if db.execute(f"SELECT 1 FROM verify_messages m WHERE {cond} AND m.proof_tagged_at IS NOT NULL "
                  f"AND m.campaign NOT IN ({_marks(CLAIM_CAMPAIGNS)}) LIMIT 1", (*params, *CLAIM_CAMPAIGNS)).fetchone():
        return "proof_received"
    return ""


def uvn_user_done(db: sqlite3.Connection, user_key: str, *, now: datetime | None = None,
                  campaign: str = "uvn-status", user_id: str = "", skip_7d: bool = False,
                  request_ids: list[str] | tuple[str, ...] = ()) -> str:
    """A STATUS_CAMPAIGNS note: why this user must not get it ('' when they may). One per user,
    ever, per campaign; never within 7 days of any note from this gate (messaged_7d, a deferral);
    uvn-status (an ask) also never after a proof reply, and never within 90 days of an ask from
    any ask campaign (the shared one-ask lock: recently_asked, a deferral, nothing closed).
    "This user" is _same_user: an email change is the same user.
    skip_7d: a reply_due ANSWER ([key=reply-due]) - only the 7-day cooldown on unsolicited notes is lifted; one per
    user ever, proof_received and the 90-day ask lock still apply (QA #1509)."""
    cond, params = _same_user(db, user_key, user_id)
    if db.execute(f"SELECT 1 FROM verify_messages m WHERE {cond} AND m.campaign=? AND m.kind='initial' "
                  "AND m.status IN ('attempted','sent') LIMIT 1", (*params, campaign)).fetchone():
        return "already_sent"
    if campaign == "uvn-status" and db.execute(
            f"SELECT 1 FROM verify_messages m WHERE {cond} AND m.proof_tagged_at IS NOT NULL "
            f"AND m.campaign NOT IN ({_marks(CLAIM_CAMPAIGNS)}) LIMIT 1",
            (*params, *CLAIM_CAMPAIGNS)).fetchone():
        return "proof_received"
    since = ((now or utcnow()) - timedelta(days=7)).strftime("%Y-%m-%d")
    if not skip_7d:
        recent = db.execute(f"SELECT m.campaign, m.request_ids_json, m.status FROM verify_messages m WHERE {cond} AND m.day>=? "
                            "AND m.status IN ('attempted','sent')", (*params, since)).fetchall()
        # [key=k-proof-required] /c2 (r5 05:3xZ): an ask about requests a recent STATUS LINE of ours named corrects that
        # line - when EVERY note of the last 7 days is such a line (naming one of these requests), the cooldown it set
        # does not defer the correction. Any other recent note still defers. Read here, never on the caller's word.
        # QA / r5 #1565: only a CONFIRMED (sent) status line is exempt - the /c2 correction is computed from sent lines
        # only, so an ATTEMPTED (unknown) line keeps its cooldown: unknown holds, never an uncorrected ask.
        want = {str(r).strip().lower() for r in request_ids if str(r).strip()}
        if recent and not (campaign == "uvn-status" and want and all(
                c in STATUS_LINE_CAMPAIGNS and st == "sent" and want & _ids_of(j) for c, j, st in recent)):
            return "messaged_7d"
    # uvn-status is an ask: the shared one-ask-per-user-per-90-days lock across the ask
    # campaigns applies (QA @59645fb; doc rule 'One ask per user per 90 days'). A deferral,
    # like messaged_7d: nothing is closed, the user is offered again once the lock lapses.
    if campaign == "uvn-status" and asked_within(db, user_key=user_key,
                                                 day=(now or utcnow()).strftime("%Y-%m-%d"), user_id=user_id):
        return "recently_asked"
    return ""


def new_rows_user_done(db: sqlite3.Connection, user_key: str, *, now: datetime | None = None, user_id: str = "") -> str:
    """fable-copy-1101-r5/n1: why this told user must not get an uvn-new-rows note now ('' when they may).
    'no_prior_ask' (closed: the opener is only true after a SENT uvn-status ask); 'proof_received' (closed: never ask
    someone who sent proof); 'messaged_7d' (a deferral: any note from this gate in the last 7 days). Per ROW once is
    blocked_ids'; the per-day cap is claim()'s. The 90-day one-ask lock does not apply: the class follows an ask by
    definition (r5 n1's gate list)."""
    if not prior_uvn_ask(db, user_key, user_id):
        return "no_prior_ask"
    cond, params = _same_user(db, user_key, user_id)
    if db.execute(f"SELECT 1 FROM verify_messages m WHERE {cond} AND m.proof_tagged_at IS NOT NULL "
                  f"AND m.campaign NOT IN ({_marks(CLAIM_CAMPAIGNS)}) LIMIT 1", (*params, *CLAIM_CAMPAIGNS)).fetchone():
        return "proof_received"
    since = ((now or utcnow()) - timedelta(days=7)).strftime("%Y-%m-%d")
    if db.execute(f"SELECT 1 FROM verify_messages m WHERE {cond} AND m.day>=? AND m.status IN ('attempted','sent') "
                  "LIMIT 1", (*params, since)).fetchone():
        return "messaged_7d"
    return ""


def claim_cross_check(db: sqlite3.Connection, campaign: str, request_ids: list[str], user_key: str, *,
                      day: str, user_id: str = "") -> str:
    """The claim notes never cross ('' when this one may go). A claim-status or claim-proof-pending
    note never goes to a claim that has a claim-proof-ask note ('proof_ask_sent', closed: that
    claimant is told there); a claim-status note never goes to a claim that has a claim-proof-pending
    note ('proof_pending_sent', closed: it would say nothing else is needed after S2 said proof is);
    and neither goes within 7 days of any note from this gate to the user ('messaged_7d', a deferral). A claim-proof-ask note waits 7 days after a claim-status or
    claim-proof-pending note ('messaged_7d')."""
    if campaign not in CLAIM_CAMPAIGNS:
        return ""
    cond, params = _same_user(db, user_key, user_id)
    # The send day the gate claims for, not the wall clock: the 7 days are counted back from it.
    since = (datetime.strptime(day, "%Y-%m-%d") - timedelta(days=7)).strftime("%Y-%m-%d")
    if campaign in (CLAIM_STATUS_CAMPAIGN, CLAIM_PENDING_CAMPAIGN):
        marks = ",".join("?" * len(request_ids))

        def noted(by: str) -> bool:
            return bool(request_ids) and db.execute(
                f"SELECT 1 FROM verify_requests r JOIN verify_messages m ON m.id = r.message_row "
                f"WHERE r.campaign=? AND r.request_id IN ({marks}) AND m.status IN ('attempted','sent') LIMIT 1",
                (by, *request_ids)).fetchone() is not None
        if noted(CLAIM_CAMPAIGN):
            return "proof_ask_sent"
        # QA on #1409: once S2 told the claimant proof is required, claim-status ("Nothing else is needed")
        # never follows for that claim (closed, not deferred).
        if campaign == CLAIM_STATUS_CAMPAIGN and noted(CLAIM_PENDING_CAMPAIGN):
            return "proof_pending_sent"
        if db.execute(f"SELECT 1 FROM verify_messages m WHERE {cond} AND m.day>=? AND m.status IN ('attempted','sent') "
                      "LIMIT 1", (*params, since)).fetchone():
            return "messaged_7d"
        return ""
    if db.execute(f"SELECT 1 FROM verify_messages m WHERE {cond} AND m.campaign IN (?,?) AND m.day>=? "
                  "AND m.status IN ('attempted','sent') LIMIT 1",
                  (*params, CLAIM_STATUS_CAMPAIGN, CLAIM_PENDING_CAMPAIGN, since)).fetchone():
        return "messaged_7d"
    return ""


# uvn_user_done reasons that only DEFER the user (nothing closed, offered again later).
DEFER_REASONS = ("messaged_7d", "recently_asked")


def gap_user_done(db: sqlite3.Connection, user_key: str, *, now: datetime | None = None, user_id: str = "") -> str:
    """gap-ask: why this user must not get one now ('' when they may). Only a deferral exists:
    messaged_7d, any note from this gate in the last 7 days except a GAP_ASK_FOLLOWS note. The
    per-credit once and the one-message-per-user-per-day cap are claim()'s."""
    cond, params = _same_user(db, user_key, user_id)
    since = ((now or utcnow()) - timedelta(days=7)).strftime("%Y-%m-%d")
    follows = ",".join("?" * len(GAP_ASK_FOLLOWS))
    if db.execute(f"SELECT 1 FROM verify_messages m WHERE {cond} AND m.day>=? AND m.status IN ('attempted','sent') "
                  f"AND m.campaign NOT IN ({follows}) LIMIT 1", (*params, since, *GAP_ASK_FOLLOWS)).fetchone():
        return "messaged_7d"
    return ""


def followed_notes(db: sqlite3.Connection, user_key: str, *, now: datetime | None = None,
                   user_id: str = "") -> dict[str, list[str]]:
    """The GAP_ASK_FOLLOWS notes sent to this user in the last 7 days: their Intercom message ids
    (in-thread: the part id) and conversation ids, so the gate's Intercom-side 7-day check can
    leave exactly those messages out (every other message from us still defers)."""
    cond, params = _same_user(db, user_key, user_id)
    since = ((now or utcnow()) - timedelta(days=7)).strftime("%Y-%m-%d")
    follows = ",".join("?" * len(GAP_ASK_FOLLOWS))
    rows = db.execute(f"SELECT m.message_id, m.conversation_id FROM verify_messages m WHERE {cond} AND m.day>=? "
                      f"AND m.status = 'sent' AND m.campaign IN ({follows})", (*params, since, *GAP_ASK_FOLLOWS)).fetchall()
    return {"message_ids": sorted({str(r[0]) for r in rows if r[0]}),
            "conversation_ids": sorted({str(r[1]) for r in rows if r[1]})}


def claim(db: sqlite3.Connection, *, user_key: str, day: str, request_ids: list[str], message_type: str,
          approved_by: str, approval_ref: str, contact_id: str = "", campaign: str = "verify-live",
          refs: list[dict[str, Any]] | None = None, windowed: bool = False, now: datetime | None = None,
          enforce_cap: bool = True, user_id: str = "", reply_due: str = "", conversation: str = "", copy_ref: str = "",
          variant: str = "", pick_id: str = "", approver_kind: str = "", approval_id: str = "",
          template_sha256: str = "") -> dict[str, Any]:
    """Atomically claim an initial note. One transaction (BEGIN IMMEDIATE) so two
    concurrent runs cannot both claim the same user-day or request id. A claim-proof-ask note
    records its close day (claim_close_day) as due_day."""
    _check(campaign)
    approver_kind, approval_id, template_sha256 = approval_stamp(approver_kind, approval_id, template_sha256,
                                                                 approved_by)
    if windowed and campaign != "verify-live":
        raise ValueError("only verify-live (new provisional approvals) notes carry a removal date")
    ts = stamp(now)
    db.execute("BEGIN IMMEDIATE")
    try:
        blocked = blocked_ids(db, request_ids, campaign)
        fresh = [r for r in dict.fromkeys(request_ids) if r and r not in blocked]
        if not fresh:
            db.execute("COMMIT")
            return {"result": "already_notified", "request_ids": []}
        nc = no_channel(db, user_key, user_id)
        if nc:
            db.execute("COMMIT")
            return {"result": "no_channel", "reason": nc, "request_ids": fresh}
        hold = refusal_hold(db, campaign, user_key, now, user_id) if enforce_cap else {}
        if hold:
            db.execute("COMMIT")
            return {"result": "refusal_hold", "request_ids": fresh, **hold}
        if reply_due:
            # [key=reply-due]: EXACTLY ONE answer per triggering customer part, ever, and one reply_due answer per
            # thread per 48 h; the 7-day status cooldown does not apply to answering (the gate verified the trigger)
            if not (reply_due.isdigit() and conversation.isdigit()):
                db.execute("COMMIT")
                return {"result": "refusal_hold", "request_ids": fresh, "reason": "reply_due needs a part and a thread"}
            if db.execute("SELECT 1 FROM verify_messages WHERE approval_ref LIKE ? AND status IN ('attempted','sent') LIMIT 1",
                          (f"%reply_due:{reply_due} %",)).fetchone():
                db.execute("COMMIT")
                return {"result": "already_notified", "request_ids": []}
            since48 = stamp((now or utcnow()) - timedelta(hours=48))
            if _ref_marked(db, f"thread:{conversation}", "AND created_at >= ? AND status IN ('attempted','sent')",
                           (since48,)):
                db.execute("COMMIT")
                return {"result": "recent", "reason": "reply_due_48h", "request_ids": fresh}
            if campaign == "reply-ref":
                # QA #1615: the classifier's pick is serialized WITH the claim - inside this transaction the latest pick
                # for the part must still be the one the gate matched (record_pick refuses once this claim exists)
                latest = pick_for(db, conversation=conversation, part=reply_due)
                if not latest or str(latest["id"]) != str(pick_id or ""):
                    db.execute("COMMIT")
                    return {"result": "pick_changed", "request_ids": fresh,
                            "reason": f"latest pick {latest['id'] if latest else 'none'} != matched pick {pick_id or 'none'}"}
            approval_ref = f"{approval_ref} reply_due:{reply_due} thread:{conversation}"
        if campaign in STATUS_CAMPAIGNS and enforce_cap:
            # inside this transaction: a reply_due answer lifts ONLY the 7-day cooldown (QA #1509)
            why = uvn_user_done(db, user_key, now=now, campaign=campaign, user_id=user_id, skip_7d=bool(reply_due),
                                request_ids=fresh)
            if why in DEFER_REASONS:
                db.execute("COMMIT")
                return {"result": "recent", "reason": why, "request_ids": fresh}
            if why:
                _skip(db, campaign, fresh, ts)
                db.execute("COMMIT")
                return {"result": "user_done", "reason": why, "request_ids": fresh}
        if campaign in GAP_LIKE and enforce_cap:
            why = gap_user_done(db, user_key, now=now, user_id=user_id)
            if why:
                db.execute("COMMIT")
                return {"result": "recent", "reason": why, "request_ids": fresh}
        if campaign == UVN_NEW_ROWS and enforce_cap:
            # fable-copy-1101-r5/n1, inside this transaction (the peek reads the same)
            why = new_rows_user_done(db, user_key, now=now, user_id=user_id)
            if why == "messaged_7d":
                db.execute("COMMIT")
                return {"result": "recent", "reason": why, "request_ids": fresh}
            if why == "no_prior_ask":                # never closed: the user may be asked first, then followed up
                db.execute("COMMIT")
                return {"result": "no_prior_ask", "request_ids": fresh}
            if why:
                _skip(db, campaign, fresh, ts)
                db.execute("COMMIT")
                return {"result": "user_done", "reason": why, "request_ids": fresh}
        if campaign == MERGE_PENDING and enforce_cap:
            cond, params = _same_user(db, user_key, user_id)
            since = (datetime.strptime(day, "%Y-%m-%d") - timedelta(days=7)).strftime("%Y-%m-%d")
            if db.execute(f"SELECT 1 FROM verify_messages m WHERE {cond} AND m.day>=? AND m.status IN ('attempted','sent') "
                          "LIMIT 1", (*params, since)).fetchone():
                db.execute("COMMIT")
                return {"result": "recent", "reason": "messaged_7d", "request_ids": fresh}
        if campaign == "retro-past" and enforce_cap:
            why = past_user_done(db, user_key, user_id)
            if why:
                _skip(db, campaign, fresh, ts)
                db.execute("COMMIT")
                return {"result": "user_done", "reason": why, "request_ids": fresh}
        if campaign in CLAIM_CAMPAIGNS and enforce_cap:
            why = claim_cross_check(db, campaign, fresh, user_key, day=day, user_id=user_id)
            if why in DEFER_REASONS:
                db.execute("COMMIT")
                return {"result": "recent", "reason": why, "request_ids": fresh}
            if why:
                _skip(db, campaign, fresh, ts)
                db.execute("COMMIT")
                return {"result": "user_done", "reason": why, "request_ids": fresh}
        if enforce_cap and capped(db, user_key=user_key, day=day, user_id=user_id):
            db.execute("COMMIT")
            return {"result": "daily_cap", "request_ids": fresh}
        if campaign == "verify-live" and enforce_cap and asked_within(db, user_key=user_key, day=day, user_id=user_id):
            # One note per user per 90 days across the ask campaigns: the credits wait
            # (nothing is closed) until the lock lapses or a human acts.
            db.execute("COMMIT")
            return {"result": "recently_asked", "request_ids": fresh}
        keep = [r for r in (refs or []) if str(r.get("request_id")) in set(fresh)]
        due, removal = window(day) if windowed else (None, None)
        if campaign == CLAIM_CAMPAIGN:
            due = claim_close_day(day)
        cur = db.execute(
            "INSERT INTO verify_messages (campaign, kind, user_key, account_id, day, due_day, removal_day, status, "
            "message_type, contact_id, request_ids_json, refs_json, n_credits, approved_by, approval_ref, created_at, "
            "updated_at, approver_kind, approval_id, template_sha256) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
            (campaign, "initial", user_key, str(user_id or "").strip() or None, day, due, removal, "attempted",
             message_type, contact_id or None,
             json.dumps(fresh), json.dumps(keep) if keep else None, len(fresh), approved_by, approval_ref, ts, ts,
             approver_kind, approval_id, template_sha256))
        row = int(cur.lastrowid)
        # p1 615: what the note rendered, on the row - audits read the ledger, never a preview dir
        db.execute("UPDATE verify_messages SET copy_ref = ?, variant = ? WHERE id = ?",
                   (copy_ref or None, variant or None, row))
        for rid in fresh:
            db.execute(
                "INSERT INTO verify_requests (campaign, request_id, message_row, status, attempts, updated_at) "
                "VALUES (?,?,?,?,?,?) ON CONFLICT(campaign, request_id) DO UPDATE SET message_row=excluded.message_row, "
                "status='attempted', attempts=verify_requests.attempts+1, updated_at=excluded.updated_at",
                (campaign, rid, row, "attempted", 1, ts))
        cond, params = _hold_of(user_key, user_id)
        db.execute(f"DELETE FROM verify_refusal_holds WHERE campaign=? AND {cond} AND flagged_at IS NULL",
                   (campaign, *params))
        db.execute("COMMIT")
        return {"result": "claimed", "message_row": row, "request_ids": fresh, "due_day": due, "removal_day": removal}
    except Exception:
        db.execute("ROLLBACK")
        raise


def reminder_state(db: sqlite3.Connection, *, parent_message_id: str, kind: str, day: str) -> dict[str, Any]:
    """Whether follow-up `kind` of the note `parent_message_id` may be sent on `day`.
    result: due | not_due | done | proof_received | not_applicable | no_parent.
      windowed note (removal date): day 14 and day 25, none after the window ends, and only
      for credits no review has ruled on; after-rejection: as soon as a review rejected a
      credit, for every rejected credit no after-rejection note has named yet (at most one
      per credit), with what was received (document | reply), the reasons and a reply-by
      date never earlier than AFTER_REJECTION_MIN_DAYS after `day` (removal the day after);
      claim-proof-ask note: one reminder-7, from day 7 up to the day before its close day
      (due_day), unless it was closed (close_reminder: code found, claim decided or
      withdrawn); never once the claimant replied to the note (proof_received: a claim-proof
      tag or any recorded reply; the reply waits for a person); any other kind of follow-up
      is not_applicable;
      any other note (retro-past, preview-era v1): no follow-ups."""
    if kind not in KINDS[1:]:
        raise ValueError(f"unknown follow-up kind {kind!r}")
    parent = db.execute("SELECT * FROM verify_messages WHERE message_id=? AND kind='initial' AND status='sent' "
                        "ORDER BY id DESC LIMIT 1", (parent_message_id,)).fetchone()
    if parent is None:
        return {"result": "no_parent"}
    info = {"parent_row": int(parent["id"]), "campaign": parent["campaign"], "user_key": parent["user_key"],
            "contact_id": parent["contact_id"], "account_id": parent["account_id"], "due_day": parent["due_day"],
            "removal_day": parent["removal_day"],
            "windowed": parent["removal_day"] is not None, "request_ids": json.loads(parent["request_ids_json"]),
            "message_type": parent["message_type"]}
    if parent["campaign"] == CLAIM_CAMPAIGN:
        if kind != CLAIM_REMINDER:
            return {"result": "not_applicable", **info}
        prior = db.execute("SELECT status, attempts FROM verify_messages WHERE parent_row=? AND kind=? "
                           "ORDER BY id DESC LIMIT 1", (parent["id"], kind)).fetchone()
        if prior is not None and (prior["status"] in BLOCKING or int(prior["attempts"]) >= MAX_ATTEMPTS):
            return {"result": "done", **info}
        today = date.fromisoformat(day)
        if today < date.fromisoformat(parent["day"]) + timedelta(days=REMINDER_DAYS[kind]):
            return {"result": "not_due", **info}
        if today >= date.fromisoformat(parent["due_day"]):
            return {"result": "done", **info}
        if parent["proof_tagged_at"] or parent["extension_requested_at"]:
            return {"result": "proof_received", **info}
        return {"result": "due", **info}
    if kind == CLAIM_REMINDER or not info["windowed"]:
        return {"result": "not_applicable", **info}
    reviews = db.execute("SELECT request_id, outcome, reason, document FROM verify_proof_reviews WHERE family=?",
                         (parent["id"],)).fetchall()
    if kind == AFTER_REJECTION:
        rej = {str(r["request_id"]): r for r in reviews if r["outcome"] == "rejected"}
        rejected = [rid for rid in info["request_ids"] if rid in rej]
        if not rejected:
            return {"result": "not_due", **info}
        closed = _told(db, int(parent["id"]), finished=True)
        pending = [rid for rid in rejected if rid not in closed]
        if not pending:
            return {"result": "done", **info}
        reply_by = max(str(parent["due_day"]), _plus(day, AFTER_REJECTION_MIN_DAYS))
        return {**info, "result": "due", "request_ids": pending,
                "reasons": {r: str(rej[r]["reason"] or "") for r in pending},
                "received": {r: "document" if rej[r]["document"] else "reply" for r in pending},
                "due_day": reply_by, "removal_day": _plus(reply_by, 1)}
    prior = db.execute("SELECT status, attempts FROM verify_messages WHERE parent_row=? AND kind=? "
                       "ORDER BY id DESC LIMIT 1", (parent["id"], kind)).fetchone()
    finished = prior is not None and (prior["status"] in BLOCKING or int(prior["attempts"]) >= MAX_ATTEMPTS)
    if parent["proof_tagged_at"]:
        return {"result": "proof_received", **info}
    if finished:
        return {"result": "done", **info}
    reviewed = {str(r["request_id"]) for r in reviews}
    info["request_ids"] = [rid for rid in info["request_ids"] if rid not in reviewed]
    if not info["request_ids"]:
        return {"result": "done", **info}
    today = date.fromisoformat(day)
    if today < date.fromisoformat(parent["day"]) + timedelta(days=REMINDER_DAYS[kind]):
        return {"result": "not_due", **info}
    if today > date.fromisoformat(parent["due_day"]):
        return {"result": "done", **info}
    return {"result": "due", **info}


def _told(db: sqlite3.Connection, family: int, *, finished: bool = False) -> dict[str, sqlite3.Row]:
    """request_id -> the latest after-rejection row of `family` that names it: sent ones
    only, or (finished=True) every row that ends that credit's after-rejection note (sent,
    in flight, refused, closed, or rejected with no retries left)."""
    out: dict[str, sqlite3.Row] = {}
    for r in db.execute("SELECT * FROM verify_messages WHERE parent_row=? AND kind=? ORDER BY id",
                        (family, AFTER_REJECTION)).fetchall():
        done = r["status"] == "sent" or (finished and (r["status"] in BLOCKING or int(r["attempts"]) >= MAX_ATTEMPTS))
        if done:
            for rid in json.loads(r["request_ids_json"]):
                out[str(rid)] = r
    return out


def close_reminder(db: sqlite3.Connection, *, parent_message_id: str, kind: str, day: str, reason: str,
                   now: datetime | None = None) -> bool:
    """Close follow-up `kind` of a note as `skipped` when nothing on it can be sent any
    more, so reminders_due stops offering it. Only a due follow-up is closed (or a claim
    reminder the claimant's reply withheld); no message
    is sent and the daily cap is untouched. True when a row was written."""
    ts = stamp(now)
    db.execute("BEGIN IMMEDIATE")
    try:
        st = reminder_state(db, parent_message_id=parent_message_id, kind=kind, day=day)
        if st["result"] != "due" and not (st["result"] == "proof_received" and st.get("campaign") == CLAIM_CAMPAIGN):
            db.execute("COMMIT")
            return False
        db.execute(
            "INSERT INTO verify_messages (campaign, kind, parent_row, user_key, day, due_day, removal_day, status, "
            "message_type, contact_id, request_ids_json, n_credits, approved_by, approval_ref, reason, attempts, "
            "created_at, updated_at) VALUES (?,?,?,?,?,?,?,'skipped',?,?,?,0,'','',?,0,?,?)",
            (st["campaign"], kind, st["parent_row"], st["user_key"], day, st["due_day"], st["removal_day"],
             st["message_type"], st["contact_id"], json.dumps(st["request_ids"]), reason[:500], ts, ts))
        db.execute("COMMIT")
        return True
    except Exception:
        db.execute("ROLLBACK")
        raise


def claim_reminder(db: sqlite3.Connection, *, parent_message_id: str, kind: str, user_key: str, day: str,
                   request_ids: list[str], approved_by: str, approval_ref: str,
                   now: datetime | None = None, copy_ref: str = "", variant: str = "",
                   approver_kind: str = "", approval_id: str = "", template_sha256: str = "") -> dict[str, Any]:
    """Atomically claim follow-up `kind` of a sent note. The listed credits must be
    a subset of the note's credits; the user must be the note's user."""
    approver_kind, approval_id, template_sha256 = approval_stamp(approver_kind, approval_id, template_sha256,
                                                                 approved_by)
    ts = stamp(now)
    db.execute("BEGIN IMMEDIATE")
    try:
        st = reminder_state(db, parent_message_id=parent_message_id, kind=kind, day=day)
        if st["result"] != "due":
            db.execute("COMMIT")
            return st
        if st["user_key"] != user_key:
            db.execute("COMMIT")
            return {"result": "wrong_user"}
        keep = [r for r in dict.fromkeys(request_ids) if r in set(st["request_ids"])]
        if not keep:
            db.execute("COMMIT")
            return {**st, "result": "no_credits"}
        # QA #1588: the no-channel hold covers follow-ups too, inside the same atomic claim - a reminder whose earlier
        # attempt Intercom refused (action_forbidden) is never re-attempted without a person's clear
        nc = no_channel(db, user_key, st.get("account_id") or "")
        if nc:
            db.execute("COMMIT")
            return {**st, "result": "no_channel", "reason": nc, "request_ids": keep}
        if capped(db, user_key=user_key, day=day, user_id=st.get("account_id") or ""):
            db.execute("COMMIT")
            return {**st, "result": "daily_cap"}
        priors = db.execute("SELECT attempts, request_ids_json FROM verify_messages WHERE parent_row=? AND kind=? "
                            "AND status='rejected' ORDER BY id DESC", (st["parent_row"], kind)).fetchall()
        if kind == AFTER_REJECTION:
            priors = [p for p in priors if set(json.loads(p["request_ids_json"])) & set(keep)]
        attempts = 1 + max([int(p["attempts"]) for p in priors[:1 if kind != AFTER_REJECTION else None]] or [0])
        cur = db.execute(
            "INSERT INTO verify_messages (campaign, kind, parent_row, user_key, account_id, day, due_day, removal_day, "
            "status, message_type, contact_id, request_ids_json, n_credits, approved_by, approval_ref, attempts, "
            "created_at, updated_at, approver_kind, approval_id, template_sha256) "
            "VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
            (st["campaign"], kind, st["parent_row"], user_key, st.get("account_id"), day, st["due_day"],
             st["removal_day"], "attempted",
             st["message_type"], st["contact_id"], json.dumps(keep), len(keep), approved_by, approval_ref, attempts,
             ts, ts, approver_kind, approval_id, template_sha256))
        db.execute("UPDATE verify_messages SET copy_ref = ?, variant = ? WHERE id = ?",
                   (copy_ref or None, variant or None, int(cur.lastrowid)))
        db.execute("COMMIT")
        return {**st, "result": "claimed", "message_row": int(cur.lastrowid), "request_ids": keep}
    except Exception:
        db.execute("ROLLBACK")
        raise


DEFERRAL_REASONS = ("core_notice_within_7d", "comm_state")


THREAD_EVENTS = ("handoff", "reassign")


def _ref_marked(db: sqlite3.Connection, mark: str, where: str, params: tuple = ()) -> bool:
    """QA #1615: a verify_messages row whose approval_ref carries `mark` as WHOLE space-separated tokens - never a
    prefix (`thread:777` must not match `thread:7777`). LIKE narrows the rows; the token match decides."""
    rx = re.compile(r"(?:^| )" + re.escape(mark) + r"(?: |$)")
    for (ref,) in db.execute(f"SELECT approval_ref FROM verify_messages WHERE approval_ref LIKE ? {where}",
                             (f"%{mark}%", *params)):
        if rx.search(ref or ""):
            return True
    return False


class PickLocked(ValueError):
    """A reply-ref send for this part is claimed or sent: no newer pick may be recorded for it."""


def record_pick(db: sqlite3.Connection, *, conversation: str, part: str, ref: str, reason: str, llm_call_id: str = "",
                refs_sha256: str = "", now: datetime | None = None) -> int:
    """QA #1601 (2): the reply-ref picker's pick for one customer part, recorded before it calls the gate."""
    for name, v in (("conversation", conversation), ("part", part)):
        if not re.fullmatch(r"[0-9]{1,24}", str(v or "")):
            raise ValueError(f"{name} must be digits")
    if not ref or not reason:
        raise ValueError("ref and reason are required")
    db.execute("BEGIN IMMEDIATE")
    try:
        # QA #1615: once a reply-ref send for this part is claimed (attempted) or sent, its pick is final - a later pick
        # is refused (the picker does not call the gate), so no in-flight send can be superseded under it
        if _ref_marked(db, f"reply_due:{part} thread:{conversation}", "AND campaign = 'reply-ref' AND status IN ('attempted','sent')"):
            raise PickLocked(f"a reply-ref send for part {part} in conversation {conversation} is claimed or sent; "
                             "its pick is final")
        cur = db.execute("INSERT INTO reply_ref_picks (conversation, part, ref, reason, llm_call_id, refs_sha256, picked_at) "
                         "VALUES (?, ?, ?, ?, ?, ?, ?)", (conversation, part, ref, reason, llm_call_id or None,
                                                         refs_sha256 or None, stamp(now)))
        db.execute("COMMIT")
    except Exception:
        db.execute("ROLLBACK")
        raise
    return int(cur.lastrowid)


def pick_for(db: sqlite3.Connection, *, conversation: str, part: str) -> dict[str, Any] | None:
    """The LATEST recorded pick for this conversation + part (None = never picked, or the table is not there yet)."""
    try:
        r = db.execute("SELECT id, ref, reason, llm_call_id, refs_sha256, picked_at FROM reply_ref_picks "
                       "WHERE conversation = ? AND part = ? ORDER BY id DESC LIMIT 1", (conversation, part)).fetchone()
    except sqlite3.OperationalError as exc:
        # QA #1615: only a ledger that predates the table reads as "no pick"; a locked / failing read raises (the gate
        # then refuses reply_ref:pick_unreadable - an outage is never mislabelled as a classifier decision)
        if "no such table" in str(exc):
            return None
        raise
    if not r:
        return None
    return {"id": int(r[0]), "ref": r[1], "reason": r[2], "llm_call_id": r[3] or "", "refs_sha256": r[4] or "",
            "picked_at": r[5]}


def thread_event(db: sqlite3.Connection, *, kind: str, conversation: str, from_admin: str, to_admin: str,
                 note_part: str, reply_due_part: str, request_ids: list[str], user_id: str, approved_by: str,
                 approval_ref: str, now: datetime | None = None) -> dict[str, Any]:
    """Fable [key=lamberto-reply-due]: a reply_due thread event, ledgered BEFORE anything is posted to the customer.
    'handoff' = the internal note carrying the exact coded answer for the assigned human (note_part = that note);
    'reassign' = the thread moved to the gate's admin with an internal note (reversible: reassign back to from_admin).
    The row is keyed to the THREAD (user_key 'thread:<id>', no account_id) and carries its own status, so no per-user
    lock, cooldown or 'told' read ever counts it as a message to the user."""
    if kind not in THREAD_EVENTS:
        raise ValueError(f"unknown thread event {kind!r}")
    for name, v in (("conversation", conversation), ("note part", note_part), ("reply_due part", reply_due_part),
                    ("from admin", from_admin), ("to admin", to_admin)):
        if not re.fullmatch(r"[0-9]{1,24}", str(v or "")):
            raise ValueError(f"{name} must be digits")
    ts = stamp(now)
    cur = db.execute(
        "INSERT INTO verify_messages (campaign, kind, user_key, account_id, day, status, message_type, message_id, "
        "conversation_id, request_ids_json, n_credits, approved_by, approval_ref, created_at, updated_at) "
        "VALUES (?, 'initial', ?, NULL, ?, ?, 'note', ?, ?, ?, ?, ?, ?, ?, ?)",
        (kind, f"thread:{conversation}", ts[:10], kind, note_part, conversation, json.dumps(sorted(request_ids)),
         len(request_ids), approved_by,
         # the event first: a long approval_ref (the captain's standing order) must never truncate it away
         f"{kind} from:{from_admin} to:{to_admin} reply_due:{reply_due_part} user:{user_id} | {approval_ref}"[:500], ts, ts))
    db.commit()
    return {"result": "recorded", "message_row": cur.lastrowid}


def log_deferral(db: sqlite3.Connection, *, campaign: str, user_key: str, day: str, request_ids: list[str],
                 message_type: str, approved_by: str, approval_ref: str, reason: str, detail: str = "",
                 user_id: str = "", now: datetime | None = None) -> dict[str, Any]:
    """Record that the gate held a note back for an outside reason (core_notice_within_7d: core told the user
    something within 7 days; Fable sender map 2026-10-27 item 2). A LOG, never a lock: status 'deferred' is not
    'attempted'/'sent' (no cap, no idempotency, no 7-day gate), not 'refused'/'rejected' (not terminal, not a
    never-delivered ask, no refusal hold or count), and no verify_requests row is written, so the note is offered
    again next run. One row per user, campaign, day and reason (a re-run the same day adds nothing)."""
    _check(campaign)
    if reason not in DEFERRAL_REASONS:
        raise ValueError(f"unknown deferral reason {reason!r}")
    ts = stamp(now)
    uid = str(user_id or "").strip() or None
    db.execute("BEGIN IMMEDIATE")
    try:
        cond = "(account_id = ? OR user_key = ?)" if uid else "user_key = ?"
        params = (uid, user_key) if uid else (user_key,)
        if db.execute(f"SELECT 1 FROM verify_messages WHERE {cond} AND campaign=? AND day=? AND status='deferred' "
                      "AND reason LIKE ? LIMIT 1", (*params, campaign, day, reason + "%")).fetchone():
            db.execute("COMMIT")
            return {"result": "already_logged"}
        ids = list(dict.fromkeys(request_ids))
        cur = db.execute(
            "INSERT INTO verify_messages (campaign, kind, user_key, account_id, day, status, message_type, "
            "request_ids_json, n_credits, approved_by, approval_ref, reason, created_at, updated_at) "
            "VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
            (campaign, "initial", user_key, uid, day, "deferred", message_type, json.dumps(ids), len(ids),
             approved_by, approval_ref, (reason + (f": {detail}" if detail else ""))[:500], ts, ts))
        db.execute("COMMIT")
        return {"result": "logged", "message_row": int(cur.lastrowid)}
    except Exception:
        db.execute("ROLLBACK")
        raise


def finalize(db: sqlite3.Connection, *, message_row: int, status: str, message_id: str = "", conversation_id: str = "",
             reason: str = "", body_sha256: str = "", api_log: str = "", now: datetime | None = None) -> None:
    if status not in ("sent", "rejected", "refused", "attempted"):
        raise ValueError(f"bad status {status!r}")
    ts = stamp(now)
    db.execute("BEGIN IMMEDIATE")
    try:
        db.execute(
            "UPDATE verify_messages SET status=?, message_id=COALESCE(NULLIF(?,''),message_id), "
            "conversation_id=COALESCE(NULLIF(?,''),conversation_id), reason=COALESCE(NULLIF(?,''),reason), "
            "body_sha256=COALESCE(NULLIF(?,''),body_sha256), api_log=COALESCE(NULLIF(?,''),api_log), updated_at=?, "
            "sent_at=CASE WHEN ?='sent' THEN COALESCE(sent_at, ?) ELSE sent_at END "
            "WHERE id=?", (status, message_id, conversation_id, reason[:500], body_sha256, api_log, ts, status, ts,
                           message_row))
        db.execute("UPDATE verify_requests SET status=?, updated_at=? WHERE message_row=?", (status, ts, message_row))
        db.execute("COMMIT")
    except Exception:
        db.execute("ROLLBACK")
        raise


def refuse(db: sqlite3.Connection, *, user_key: str, day: str, request_ids: list[str], message_type: str,
           approved_by: str, approval_ref: str, reason: str, campaign: str = "verify-live",
           now: datetime | None = None, user_id: str = "") -> dict[str, Any]:
    """Record a gate refusal so the driver does not re-offer the same rows every
    run. Terminal: a human re-opens it. Does not use the user's daily message, and
    a refused note named no date, so it is never removal-due. RECHECKABLE_REFUSALS are
    not terminal: see recheck_refusal."""
    _check(campaign)
    if campaign in RECHECKABLE_REFUSALS:
        return recheck_refusal(db, campaign=campaign, user_key=user_key, reason=reason, user_id=user_id, now=now)
    c = claim(db, user_key=user_key, day=day, request_ids=request_ids, message_type=message_type,
              approved_by=approved_by, approval_ref=approval_ref, campaign=campaign, now=now, enforce_cap=False)
    if c["result"] == "claimed":
        finalize(db, message_row=c["message_row"], status="refused", reason=reason, now=now)
    return c


def recheck_refusal(db: sqlite3.Connection, *, campaign: str, user_key: str, reason: str,
                    user_id: str = "", now: datetime | None = None) -> dict[str, Any]:
    """A re-checkable refusal: hold the user for RECHECK_DAYS and count the refusal (a
    refusal during a hold, or of a flagged user, changes nothing). A user whose email changed
    keeps the hold row of their Muso user id (_hold_of): the count carries on, it never resets."""
    ts = stamp(now)
    nxt = stamp((now or utcnow()) + timedelta(days=RECHECK_DAYS))
    db.execute("BEGIN IMMEDIATE")
    try:
        cond, params = _hold_of(user_key, user_id)
        old = db.execute(f"SELECT user_key FROM verify_refusal_holds WHERE campaign=? AND {cond} "
                         "ORDER BY user_key = ? DESC, refusals DESC LIMIT 1", (campaign, *params, user_key)).fetchone()
        user_key = str(old["user_key"]) if old is not None else user_key
        db.execute(
            "INSERT INTO verify_refusal_holds (campaign, user_key, user_id, refusals, reason, next_recheck_at, updated_at) "
            "VALUES (?,?,?,1,?,?,?) ON CONFLICT(campaign, user_key) DO UPDATE SET "
            "refusals=verify_refusal_holds.refusals+1, reason=excluded.reason, next_recheck_at=excluded.next_recheck_at, "
            "user_id=COALESCE(excluded.user_id, verify_refusal_holds.user_id), updated_at=excluded.updated_at "
            "WHERE verify_refusal_holds.flagged_at IS NULL AND verify_refusal_holds.next_recheck_at <= excluded.updated_at",
            (campaign, user_key, user_id or None, reason[:500], nxt, ts))
        r = db.execute("SELECT refusals, next_recheck_at FROM verify_refusal_holds WHERE campaign=? AND user_key=?",
                       (campaign, user_key)).fetchone()
        db.execute("COMMIT")
    except Exception:
        db.execute("ROLLBACK")
        raise
    return {"result": "refused_recheck", "refusals": int(r["refusals"]), "next_recheck_at": str(r["next_recheck_at"])}


def refusals_to_flag(db: sqlite3.Connection, campaigns: list[str] | tuple[str, ...]) -> list[dict[str, Any]]:
    """Users refused MAX_REFUSALS times and not flagged yet, one entry per (campaign, user):
    {campaign, user_key, user_id, reason, refusals}."""
    camps = [c for c in campaigns if c in RECHECKABLE_REFUSALS]
    if not camps:
        return []
    return [{"campaign": str(r["campaign"]), "user_key": str(r["user_key"]), "user_id": str(r["user_id"] or ""),
             "reason": str(r["reason"] or ""), "refusals": int(r["refusals"])}
            for r in db.execute(f"SELECT campaign, user_key, user_id, reason, refusals FROM verify_refusal_holds "
                                f"WHERE refusals>=? AND flagged_at IS NULL AND campaign IN ({','.join('?' * len(camps))}) "
                                f"ORDER BY campaign, user_id", (MAX_REFUSALS, *camps)).fetchall()]


# The no-ask status notes ("... nothing else is needed from you right now"): the campaigns a
# silent hold blocks.
STATUS_NOTE_CAMPAIGNS = ("status-doc-received", "status-team-review")
HOLD_REASON_RE = re.compile(r"^[a-z0-9][a-z0-9-]{2,63}$")


def hold_silent(db: sqlite3.Connection, *, user_ids: list[str], reason: str,
                campaigns: tuple[str, ...] = STATUS_NOTE_CAMPAIGNS, now: datetime | None = None) -> dict[str, int]:
    """Hold these Muso users from the status notes for good (Fable ruling 017, 2026-10-27: the 40 users
    told 'nothing else is needed' while they owe proof get no such note again; the uvn-status ask is
    NOT held, so they stay first in line for it). A flagged verify_refusal_holds row per campaign,
    keyed user:<id> and matched by user_id (refusal_hold), so an email change does not free them:
    the runner and the gate skip them (refused-flagged), a later send never clears it, and it is
    never posted to #cs_priority (refusals_to_flag reads unflagged rows only). Idempotent: an
    existing row is flagged with this reason. Returns {"held": rows written, "already": rows that
    were flagged already}."""
    if not HOLD_REASON_RE.match(reason):
        raise ValueError(f"reason must be a short slug (got {reason!r})")
    for c in campaigns:
        if c not in RECHECKABLE_REFUSALS:
            raise ValueError(f"{c!r} has no refusal hold")
    ids = [str(u).strip() for u in user_ids if str(u).strip()]
    bad = [u for u in ids if not u.isdigit()]
    if bad:
        raise ValueError(f"not Muso user ids: {bad[:3]}")
    ts = stamp(now)
    out = {"held": 0, "already": 0}
    db.execute("BEGIN IMMEDIATE")
    try:
        for c in campaigns:
            for uid in dict.fromkeys(ids):
                cond, params = _hold_of(f"user:{uid}", uid)
                rows = db.execute(f"SELECT user_key, flagged_at FROM verify_refusal_holds WHERE campaign=? AND {cond}",
                                  (c, *params)).fetchall()
                if any(r["flagged_at"] for r in rows):
                    out["already"] += 1
                    continue
                if rows:
                    for r in rows:
                        db.execute("UPDATE verify_refusal_holds SET flagged_at=?, reason=?, updated_at=? "
                                   "WHERE campaign=? AND user_key=?", (ts, reason, ts, c, r["user_key"]))
                else:
                    db.execute("INSERT INTO verify_refusal_holds (campaign, user_key, user_id, refusals, reason, "
                               "next_recheck_at, flagged_at, updated_at) VALUES (?,?,?,0,?,?,?,?)",
                               (c, f"user:{uid}", uid, reason, "9999-12-31T00:00:00Z", ts, ts))
                out["held"] += 1
        db.execute("COMMIT")
    except Exception:
        db.execute("ROLLBACK")
        raise
    return out


def mark_flagged(db: sqlite3.Connection, *, campaign: str, user_key: str, now: datetime | None = None) -> int:
    """A flagged user: blocked in this campaign from now on (flagged_at recorded)."""
    ts = stamp(now)
    return db.execute("UPDATE verify_refusal_holds SET flagged_at=?, updated_at=? WHERE campaign=? AND user_key=? "
                      "AND flagged_at IS NULL", (ts, ts, campaign, user_key)).rowcount


def _skip(db: sqlite3.Connection, campaign: str, request_ids: list[str], ts: str) -> int:
    n = 0
    for rid in dict.fromkeys(request_ids):
        cur = db.execute("INSERT INTO verify_requests (campaign, request_id, message_row, status, attempts, "
                         "updated_at) VALUES (?,?,0,'skipped',0,?) ON CONFLICT(campaign, request_id) DO UPDATE "
                         "SET status='skipped', updated_at=excluded.updated_at WHERE verify_requests.status=? "
                         "OR (verify_requests.status='rejected' AND verify_requests.deferred_at IS NOT NULL)",
                         (campaign, rid, ts, DEFERRED))
        n += cur.rowcount
    return n


def defer(db: sqlite3.Connection, *, campaign: str, refs: list[tuple[str, str, str]],
          now: datetime | None = None) -> int:
    """Hold NEW credits back while their user has a document under review on another
    credit: (request_id, profile_id, track_id) rows in deferred_pending_doc, keeping the
    first deferral time. Rows already notified, refused or closed are left alone."""
    _check(campaign)
    if campaign != "verify-live":
        raise ValueError("only new provisional approvals (verify-live) are held back for a pending document")
    ts = stamp(now)
    n = 0
    for rid, pid, tid in refs:
        cur = db.execute(
            "INSERT INTO verify_requests (campaign, request_id, message_row, status, attempts, updated_at, profile_id, "
            "track_id, deferred_at) VALUES (?,?,0,?,0,?,?,?,?) ON CONFLICT(campaign, request_id) DO UPDATE SET "
            "status=excluded.status, updated_at=excluded.updated_at, profile_id=excluded.profile_id, "
            "track_id=excluded.track_id, deferred_at=COALESCE(verify_requests.deferred_at, excluded.deferred_at) "
            "WHERE verify_requests.status IN (?, 'rejected')",
            (campaign, rid, DEFERRED, ts, pid or None, tid or None, ts, DEFERRED))
        n += cur.rowcount
    return n


def deferred(db: sqlite3.Connection, *, campaign: str = "verify-live") -> list[tuple[str, str, str]]:
    """(request_id, profile_id, track_id) of every credit ever held back that is not yet
    terminally resolved: still deferred, or its send was rejected by Intercom with retries
    left (deferred_at survives the claim). First deferred first."""
    rows = db.execute("SELECT request_id, profile_id, track_id FROM verify_requests WHERE campaign=? AND "
                      "(status=? OR (status='rejected' AND deferred_at IS NOT NULL AND attempts < ?)) "
                      "ORDER BY deferred_at, request_id", (campaign, DEFERRED, MAX_ATTEMPTS)).fetchall()
    return [(str(r[0]), str(r[1] or ""), str(r[2] or "")) for r in rows]


def skip_requests(db: sqlite3.Connection, *, campaign: str, request_ids: list[str], now: datetime | None = None) -> int:
    """Close rows that will never be announced: no longer approved on the server, not
    plannable (no account email / title / artist), or the user is done (retro-past)."""
    _check(campaign)
    return _skip(db, campaign, request_ids, stamp(now))


def _refs(r: sqlite3.Row) -> list[dict[str, Any]]:
    return json.loads(r["refs_json"]) if r["refs_json"] else [{"request_id": x} for x in json.loads(r["request_ids_json"])]


def _reviews(db: sqlite3.Connection, family: int) -> dict[str, str]:
    return {str(r["request_id"]): str(r["outcome"]) for r in
            db.execute("SELECT request_id, outcome FROM verify_proof_reviews WHERE family=?", (family,)).fetchall()}


HELD_AWAITING_REVIEW = "document awaiting review"
HELD_REPLIED = "the user replied: removal held for a human"
HELD_NOT_TOLD = "document rejected: the user has not been told why yet"


def _past_removal_day(db: sqlite3.Connection, day: str) -> list[tuple[dict[str, Any], bool]]:
    """(row, held) per credit on a windowed note whose removal day has come and that no
    accepted document cleared. Held for a human (never removed by the export): a credit
    whose document awaits review, one whose user replied (extension_requested_at) and no
    review has ruled on, a rejected one no sent after-rejection note named yet, and a
    rejected one whose user replied after that note and no review has ruled on since. A
    rejected credit is removal-due from the later of the note's removal day and the one ITS
    after-rejection note named."""
    out: list[tuple[dict[str, Any], bool]] = []
    rows = db.execute("SELECT * FROM verify_messages WHERE kind='initial' AND status='sent' "
                      "AND removal_day IS NOT NULL AND removal_day <= ? ORDER BY id", (day,)).fetchall()
    for r in rows:
        reviews = {str(x["request_id"]): x for x in
                   db.execute("SELECT * FROM verify_proof_reviews WHERE family=?", (r["id"],)).fetchall()}
        told = _told(db, int(r["id"]))
        replied = db.execute("SELECT MAX(last_reply_at) FROM verify_messages WHERE id=? OR parent_row=?",
                             (r["id"], r["id"])).fetchone()[0]
        for ref in _refs(r):
            rid = str(ref.get("request_id"))
            review = reviews.get(rid)
            outcome = review["outcome"] if review is not None else None
            removal = str(r["removal_day"])
            reason = "no valid verification within 30 days"
            if outcome == "accepted":
                continue
            if outcome == "rejected":
                note = told.get(rid)
                if note is None:
                    reason = HELD_NOT_TOLD
                elif replied and replied > str(note["created_at"]) and replied > str(review["reviewed_at"]):
                    reason = HELD_REPLIED
                else:
                    removal = max(removal, str(note["removal_day"]))
                    if removal > day:
                        continue
                    reason = "the document sent did not verify it, and nothing else came by the date we named"
            elif r["proof_tagged_at"]:
                reason = HELD_AWAITING_REVIEW
            elif r["extension_requested_at"] is not None:
                reason = HELD_REPLIED
            held = reason in (HELD_AWAITING_REVIEW, HELD_REPLIED, HELD_NOT_TOLD)
            out.append(({"request_id": rid, "profile_id": ref.get("profile_id") or None,
                         "track_id": ref.get("track_id") or None, "campaign": r["campaign"],
                         "message_id": r["message_id"], "noted_day": r["day"], "due_day": r["due_day"],
                         "removal_day": removal, "reason": reason}, held))
    return out


def removal_due(db: sqlite3.Connection, *, day: str) -> list[dict[str, Any]]:
    """Credits that may be removed on `day`: ONLY credits whose note named a reply-by
    date (windowed notes for NEW provisional approvals; captain 23:40Z "if no valid
    verification comes it should be removed", narrowed 00:35Z to new credits), from the
    day after it, with no valid document. Past (retro-past) credits are never here. Per
    credit: an accepted document clears it; a document awaiting review holds it; a rejected
    one puts it back once its after-rejection note went out and the date it named passed. A
    note the user replied to is held for a human (held_for_human) until a review rules on
    the credit. The remover must still re-check each credit (confirmed meanwhile -> never
    removed)."""
    return [row for row, held in _past_removal_day(db, day) if not held]


def held_for_human(db: sqlite3.Connection, *, day: str) -> list[dict[str, Any]]:
    """Credits past their removal day that the export never removes, each with why: a
    document awaits review, the user replied to the note (text or attachment), or a
    rejection the user has not been told about yet. A human picks them up."""
    return [row for row, held in _past_removal_day(db, day) if held]


def unverified_past(db: sqlite3.Connection, *, day: str, after_days: int = UNVERIFIED_AFTER_DAYS) -> list[dict[str, Any]]:
    """Past credits asked for documents at least `after_days` ago with no proof reply:
    flagged UNVERIFIED for the board / valuation basis. The credit stays (captain
    00:35Z). Nothing here is ever removed by this ledger."""
    cutoff = _plus(day, -after_days)
    out: list[dict[str, Any]] = []
    rows = db.execute("SELECT * FROM verify_messages WHERE campaign='retro-past' AND kind='initial' AND status='sent' "
                      "AND proof_tagged_at IS NULL AND day <= ? ORDER BY id", (cutoff,)).fetchall()
    for r in rows:
        for ref in _refs(r):
            out.append({"request_id": str(ref.get("request_id")), "profile_id": ref.get("profile_id") or None,
                        "track_id": ref.get("track_id") or None, "message_id": r["message_id"], "noted_day": r["day"],
                        "flag": "unverified", "reason": "no documents within 30 days of the ask; the credit stays"})
    return out


def message(db: sqlite3.Connection, message_id: str) -> sqlite3.Row | None:
    return db.execute("SELECT * FROM verify_messages WHERE message_id=? AND status='sent' ORDER BY id DESC LIMIT 1",
                      (message_id,)).fetchone()


PROOF_OUTCOMES = ("accepted", "rejected")


def mark_replied(db: sqlite3.Connection, *, message_id: str, replied_at: str = "",
                 now: datetime | None = None) -> str:
    """The user replied to a windowed note or one of its follow-ups, or to a claim-proof-ask
    note (its day-7 reminder is then never sent) (any reply: the gate
    looks at the author only). `replied_at` is the latest user reply's own time (UTC
    YYYY-MM-DDTHH:MM:SSZ; now when the conversation gives none). Records it on that message
    when it is newer than the one already recorded, and extension_requested_at on the
    initial note once: unreviewed credits are held for a human, and so is a rejected credit
    whose user replied after its after-rejection note, until a review rules on it again.
    recorded | already | not_applicable | no_message."""
    if replied_at and not re.fullmatch(r"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ", replied_at):
        raise ValueError("replied_at must be UTC YYYY-MM-DDTHH:MM:SSZ")
    root = _family(db, message_id)
    if root is None:
        return "no_message"
    note = db.execute("SELECT removal_day, campaign FROM verify_messages WHERE id=?", (root,)).fetchone()
    if note is None or (note["removal_day"] is None and note["campaign"] != CLAIM_CAMPAIGN):
        return "not_applicable"
    msg = db.execute("SELECT id, last_reply_at FROM verify_messages WHERE message_id=? ORDER BY id DESC LIMIT 1",
                     (message_id,)).fetchone()
    prev = msg["last_reply_at"]
    if prev and (not replied_at or replied_at <= prev):
        return "already"
    ts = stamp(now)
    at = replied_at or ts
    db.execute("BEGIN IMMEDIATE")
    try:
        db.execute("UPDATE verify_messages SET last_reply_at=?, updated_at=? WHERE id=?", (at, ts, msg["id"]))
        db.execute("UPDATE verify_messages SET extension_requested_at=COALESCE(extension_requested_at, ?), updated_at=? "
                   "WHERE id=?", (at, ts, root))
        db.execute("COMMIT")
    except Exception:
        db.execute("ROLLBACK")
        raise
    return "recorded"


def _family(db: sqlite3.Connection, message_id: str) -> int | None:
    r = db.execute("SELECT id, parent_row FROM verify_messages WHERE message_id=? ORDER BY id DESC LIMIT 1",
                   (message_id,)).fetchone()
    return int(r["parent_row"] or r["id"]) if r is not None else None


def mark_tagged(db: sqlite3.Connection, *, message_id: str, conversation_id: str, attachments: int = 0,
                now: datetime | None = None) -> None:
    """Tag a note (and, for a follow-up, its initial note and every sibling) as proof
    received AWAITING REVIEW: no further follow-up goes out and none of its credits is
    removal-due while the document is reviewed. The review is per credit
    (record_proof_review); a new document puts every rejected credit back under review.
    `attachments` is the user's attachment count now, so a later sweep only re-tags when
    something NEW arrives."""
    ts = stamp(now)
    db.execute("BEGIN IMMEDIATE")
    try:
        db.execute("UPDATE verify_messages SET proof_tagged_at=?, conversation_id=?, proof_attachments=?, "
                   "updated_at=? WHERE message_id=?", (ts, conversation_id, int(attachments), ts, message_id))
        root = _family(db, message_id)
        if root is not None:
            db.execute("UPDATE verify_messages SET proof_tagged_at=COALESCE(proof_tagged_at, ?), updated_at=? "
                       "WHERE id=? OR parent_row=?", (ts, ts, root, root))
            db.execute("DELETE FROM verify_proof_reviews WHERE family=? AND outcome='rejected'", (root,))
        db.execute("COMMIT")
    except Exception:
        db.execute("ROLLBACK")
        raise


def record_proof_review(db: sqlite3.Connection, *, message_id: str, request_ids: list[str], outcome: str,
                        reviewer: str, reason: str = "", now: datetime | None = None) -> dict[str, Any]:
    """The document review's verdict, PER CREDIT, on a note with a tagged proof or a user
    reply (Fable review of hydra#1239, F2; firstmate decision on review finding
    proof-review-is-all-or-nothing-per-note):
    accepted  these credits are verified; never removal-due;
    rejected  these credits are not verified. When a document (attachment) was received on
              the note, `reason` (one of REJECTION_REASONS) is required and is all the
              user's after-rejection note says about why; after a reply with no document
              there is no reason (the note says we still need a document). They are
              removal-due after the date their after-rejection note names.
    Credits on the note not reviewed yet stay held while the proof awaits review. Once every
    credit on the note is reviewed and any was rejected, the note returns to "no proof" (the
    sweep watches for a NEW attachment beyond the ones already reviewed). A reviewed credit
    never gets a day-14 / day-25 reminder."""
    if outcome not in PROOF_OUTCOMES:
        raise ValueError(f"outcome must be one of {PROOF_OUTCOMES}")
    reason = str(reason or "").strip()
    if reason and reason not in REJECTION_REASONS:
        raise ValueError(f"a rejection reason is one of {REJECTION_REASONS}")
    if outcome == "accepted" and reason:
        raise ValueError("an accepted document takes no rejection reason")
    if not str(reviewer or "").strip():
        raise ValueError("a review names its reviewer")
    ids = list(dict.fromkeys(str(x).strip() for x in request_ids if str(x).strip()))
    if not ids:
        raise ValueError("a review names the credits (request ids) it covers")
    root = _family(db, message_id)
    if root is None:
        return {"result": "no_message"}
    ts = stamp(now)
    db.execute("BEGIN IMMEDIATE")
    try:
        note = db.execute("SELECT * FROM verify_messages WHERE id=?", (root,)).fetchone()
        on_note = [str(x) for x in json.loads(note["request_ids_json"])]
        stray = [x for x in ids if x not in on_note]
        if stray:
            db.execute("COMMIT")
            return {"result": "not_on_note", "request_ids": stray}
        tagged = db.execute("SELECT 1 FROM verify_messages WHERE (id=? OR parent_row=?) AND proof_tagged_at IS NOT NULL "
                            "LIMIT 1", (root, root)).fetchone()
        if tagged is None and not note["extension_requested_at"]:
            db.execute("COMMIT")
            return {"result": "not_tagged"}
        document = tagged is not None or db.execute(
            "SELECT 1 FROM verify_messages WHERE (id=? OR parent_row=?) AND proof_attachments > 0 LIMIT 1",
            (root, root)).fetchone() is not None
        if outcome == "rejected" and document and not reason:
            raise ValueError(f"a document was received on this note: a rejection needs a reason, one of "
                             f"{REJECTION_REASONS}")
        if outcome == "rejected" and not document and reason:
            raise ValueError("no document was received on this note (a reply only): a rejection takes no reason; "
                             "the user is told we still need a document")
        for rid in ids:
            db.execute("INSERT INTO verify_proof_reviews (family, request_id, outcome, reason, document, reviewed_at, "
                       "reviewed_by) VALUES (?,?,?,?,?,?,?) ON CONFLICT(family, request_id) DO UPDATE SET "
                       "outcome=excluded.outcome, reason=excluded.reason, document=excluded.document, "
                       "reviewed_at=excluded.reviewed_at, reviewed_by=excluded.reviewed_by",
                       (root, rid, outcome, reason or None, int(document), ts, reviewer))
        reviews = _reviews(db, root)
        if all(x in reviews for x in on_note) and "rejected" in reviews.values():
            db.execute("UPDATE verify_messages SET proof_tagged_at=NULL, updated_at=? WHERE id=? OR parent_row=?",
                       (ts, root, root))
        db.execute("COMMIT")
    except Exception:
        db.execute("ROLLBACK")
        raise
    return {"result": "ok", "outcome": outcome, "request_ids": ids}


def set_conversation(db: sqlite3.Connection, *, message_id: str, conversation_id: str) -> None:
    db.execute("UPDATE verify_messages SET conversation_id=? WHERE message_id=? AND conversation_id IS NULL",
               (conversation_id, message_id))


def awaiting_proof(db: sqlite3.Connection, *, days: int = 45, now: datetime | None = None) -> list[str]:
    """Message ids of sent notes and follow-ups whose note family sent a message within
    `days`: every one not yet tagged (credit-proof; claim-proof for a claim-proof-ask or claim-status note,
    which the gate tags apart from the credit queue), and a tagged one too while its windowed
    note still has a credit no accepted review cleared (awaiting review, or rejected), so a
    user reply in ANY thread of the family is recorded (tag-proof never re-tags it). Never-
    checked first, then least recently checked, so a capped sweep reaches every note in
    turn instead of re-reading the same oldest ones."""
    since = stamp((now or utcnow()) - timedelta(days=days))
    rows = db.execute(
        "SELECT m.message_id, m.proof_tagged_at, f.removal_day, f.request_ids_json, f.id AS family "
        "FROM verify_messages m JOIN verify_messages f ON f.id = COALESCE(m.parent_row, m.id) "
        "WHERE m.status='sent' AND m.message_id IS NOT NULL AND EXISTS (SELECT 1 FROM verify_messages s "
        "WHERE (s.id=f.id OR s.parent_row=f.id) AND s.status='sent' AND s.created_at >= ?) "
        "ORDER BY m.proof_checked_at IS NOT NULL, m.proof_checked_at, m.id", (since,)).fetchall()
    out: list[str] = []
    for r in rows:
        if r["proof_tagged_at"]:
            if r["removal_day"] is None:
                continue
            reviews = _reviews(db, int(r["family"]))
            if all(reviews.get(str(x)) == "accepted" for x in json.loads(r["request_ids_json"])):
                continue
        out.append(str(r["message_id"]))
    return out


def mark_checked(db: sqlite3.Connection, *, message_id: str, now: datetime | None = None) -> None:
    db.execute("UPDATE verify_messages SET proof_checked_at=? WHERE message_id=?", (stamp(now), message_id))


def reminders_due(db: sqlite3.Connection, *, campaign: str, day: str) -> list[tuple[str, str, list[dict[str, Any]]]]:
    """(parent message id, kind, refs) for every follow-up due on `day`, oldest note
    first, at most one per note: a reminder. When both reminders are due (day 25 came before
    day 14 went out) only the later one is offered: two reminders a few days apart add nothing.
    The after-rejection note is NOT offered any more (Fable ruling-79 denial 2026-11-04,
    dispatch `decline-copy.md`): the sender no longer has that kind, and a decline is the
    `decline` campaign's single approved sentence. `reminder_state` still understands the
    historical kind so old `verify_messages` rows stay readable; nothing asks for it."""
    out: list[tuple[str, str, list[dict[str, Any]]]] = []
    rows = db.execute("SELECT * FROM verify_messages WHERE campaign=? AND kind='initial' AND status='sent' "
                      "AND removal_day IS NOT NULL AND message_id IS NOT NULL ORDER BY id", (campaign,)).fetchall()
    for r in rows:
        for kind in ("reminder-25", "reminder-14"):
            st = reminder_state(db, parent_message_id=str(r["message_id"]), kind=kind, day=day)
            if st["result"] == "due":
                keep = set(st["request_ids"])
                out.append((str(r["message_id"]), kind, [ref for ref in _refs(r) if str(ref.get("request_id")) in keep]))
                break
            if kind == "reminder-25" and st["result"] in ("done", "proof_received"):
                break
    return out


def claim_reminders_due(db: sqlite3.Connection, *, day: str) -> list[dict[str, Any]]:
    """Every sent claim-proof-ask note whose reminder-7 is in its window on `day`, oldest first:
    {message_id, user_key, account_id, request_ids, due_day, result}. result `due`: the caller
    re-checks the claim (still pending, code not found) and sends, or closes the reminder with
    close_reminder; `proof_received`: the claimant replied, so the caller closes it unsent."""
    out: list[dict[str, Any]] = []
    rows = db.execute("SELECT * FROM verify_messages WHERE campaign=? AND kind='initial' AND status='sent' "
                      "AND message_id IS NOT NULL ORDER BY id", (CLAIM_CAMPAIGN,)).fetchall()
    for r in rows:
        st = reminder_state(db, parent_message_id=str(r["message_id"]), kind=CLAIM_REMINDER, day=day)
        if st["result"] in ("due", "proof_received"):
            out.append({"message_id": str(r["message_id"]), "user_key": r["user_key"], "account_id": r["account_id"],
                        "request_ids": st["request_ids"], "due_day": r["due_day"], "result": st["result"]})
    return out


# r5 / p1 [key=k-proof-required], fable-copy-1030-r5/c2: the status notes that tell a user their requests are with us
# (nothing asked of them) - an ask about any of the SAME requests afterwards opens with the correction sentence
STATUS_LINE_CAMPAIGNS = ("status-team-review", "status-doc-received")


def _ids_of(request_ids_json: str | None) -> set[str]:
    try:
        return {str(x).strip().lower() for x in json.loads(request_ids_json or "[]")}
    except ValueError:
        return set()


def nothing_needed_overlap(db: sqlite3.Connection, user_id: str, request_ids: list[str]) -> dict[str, Any]:
    """The requests among `request_ids` an earlier SENT status line to this user named, and where those lines went
    (conversation ids; empty = by email) and their message ids (QA #1565: exactly those messages - nothing else - are
    exempt from the gate's 7-day recent-contact check). No overlap = no correction (that note was about other requests)."""
    want = {str(r).strip().lower() for r in request_ids if str(r).strip()}
    overlap: set[str] = set()
    convs: set[str] = set()
    mids: set[str] = set()
    by_email = False
    for rids, conv, mid in db.execute(
            f"SELECT request_ids_json, coalesce(conversation_id, ''), coalesce(message_id, '') FROM verify_messages WHERE account_id=? "
            f"AND status='sent' AND campaign IN ({','.join('?' * len(STATUS_LINE_CAMPAIGNS))})",
            (str(user_id), *STATUS_LINE_CAMPAIGNS)):
        try:
            named = {str(x).strip().lower() for x in json.loads(rids or "[]")}
        except ValueError:
            named = set(want)                                # unreadable ids: assume it named them (correct, never omit)
        hit = named & want
        if hit:
            overlap |= hit
            if mid:
                mids.add(str(mid))
            if conv:
                convs.add(str(conv))
            else:
                by_email = True
    return {"overlap": sorted(overlap), "conversations": sorted(convs), "by_email": by_email, "message_ids": sorted(mids)}


def sent_today(db: sqlite3.Connection, *, campaign: str, day: str, kind: str = "initial",
               message_type: str | None = None) -> int:
    """Notes of `campaign` claimed on `day` (attempted or sent); only those of `message_type`
    (email | comment | inapp) when given: the email-only cap (captain 2026-10-26 16:05Z)."""
    q = ("SELECT COUNT(*) FROM verify_messages WHERE campaign=? AND kind=? AND day=? "
         "AND status IN ('attempted','sent')")
    params: tuple[Any, ...] = (campaign, kind, day)
    if message_type:
        q += " AND message_type=?"
        params += (message_type,)
    return int(db.execute(q, params).fetchone()[0])



def messages_today(db: sqlite3.Connection, *, campaign: str, day: str) -> int:
    """Every message of `campaign` claimed on `day` (initial notes AND follow-ups, attempted or
    sent): the run's daily budget is what is left of the cap after these, so a same-day retry
    can never send another full cap (QA review of hydra#1257 @53428d0)."""
    return int(db.execute("SELECT COUNT(*) FROM verify_messages WHERE campaign=? AND day=? "
                          "AND status IN ('attempted','sent')", (campaign, day)).fetchone()[0])


PROVISIONAL_KIND = "provisional_paid"


def _decider_approved(db: sqlite3.Connection, request_ids: list[str], *, kind: str | None) -> set[str]:
    """The ids the credit decider approved and the server confirmed (decisions joined to an
    'approve' -> 'approved' outcome of the same run); `kind` narrows to one evidence kind."""
    cols = {r[1] for r in db.execute("PRAGMA table_info(decisions)")}
    if not request_ids or "evidence_kind" not in cols:
        return set()
    out: set[str] = set()
    for i in range(0, len(request_ids), 500):
        part = request_ids[i:i + 500]
        q = ("SELECT DISTINCT d.request_id FROM decisions d JOIN decision_outcomes o ON o.request_id = d.request_id "
             "AND o.run_id = d.run_id WHERE d.decision = 'approve' AND o.action = 'approve' AND o.outcome = 'approved' "
             + ("AND d.evidence_kind = ? " if kind else "")
             + f"AND d.request_id IN ({','.join('?' * len(part))})")
        out |= {str(r) for (r,) in db.execute(q, ((kind,) if kind else ()) + tuple(part))}
    return out


def provisional_ids(db: sqlite3.Connection, request_ids: list[str]) -> set[str]:
    """Credits the decider approved as a PAID PROVISIONAL approval (Fable ruling 4)."""
    return _decider_approved(db, request_ids, kind=PROVISIONAL_KIND)


def v1_eligible(db: sqlite3.Connection, request_ids: list[str]) -> dict[str, Any]:
    """Whether a verify-live note over `request_ids` may be sent (the v1 copy, the only one sent
    since firstmate 090). Checked by the send gate itself (QA review of hydra#1257 @53428d0), so
    a direct or misrouted caller cannot send a "we added your credit" note for a credit the
    decider never approved: every credit must be a server-confirmed decider approval."""
    ids = list(dict.fromkeys(request_ids))
    if not ids:
        return {"eligible": False, "reason": "no credits"}
    approved = _decider_approved(db, ids, kind=None)
    missing = [r for r in ids if r not in approved]
    if missing:
        return {"eligible": False, "reason": f"{len(missing)} credit(s) are not server-confirmed decider approvals",
                "not_decider_approved": missing[:20]}
    return {"eligible": True}


# -- CLI (called by scripts/intercom-verify-request.sh) -----------------------

def _ids(s: str) -> list[str]:
    return [x for x in s.split(",") if x]


def load_rulings(path: str | Path) -> dict[str, Any]:
    """The Fable ruling registry (policies/fable-rulings.json) as {ruling id: entry}. An unreadable or malformed file
    raises: a registry nobody can read must never mean 'everything is approved'."""
    data = json.loads(Path(path).read_text(encoding="utf-8"))
    rulings = data.get("rulings")
    if not isinstance(rulings, dict):
        raise ValueError(f"{path}: no 'rulings' object")
    for rid, entry in rulings.items():
        if not RULING_ID_RE.match(str(rid)):
            raise ValueError(f"{path}: ruling id {rid!r} is not a fable-ruling-YYYYMMDD-N id")
        classes = entry.get("classes") if isinstance(entry, dict) else None
        if not isinstance(classes, dict):
            raise ValueError(f"{path}: ruling {rid!r} has no 'classes' object")
        for campaign, copies in classes.items():
            if campaign not in CAMPAIGNS:
                raise ValueError(f"{path}: ruling {rid!r} names unknown campaign {campaign!r}")
            if not isinstance(copies, list) or not all(isinstance(c, str) and c for c in copies):
                raise ValueError(f"{path}: ruling {rid!r} class {campaign!r} must be a list of copy tokens")
    return rulings


REFUND_ID_RE = re.compile(r"^re_[A-Za-z0-9]{8,64}$")


def refund_unconfirmed(db: sqlite3.Connection, *, feed: str | Path, hours: float,
                       now: str | None = None) -> dict[str, Any]:
    """Refunds the payment processor issued that NO refund-confirm note has told the customer about (captain
    2026-11-03 20:04Z building rule; Fable d2 ruling refund-confirm-1103): 'refund issued with no confirmation > N h'.

    The feed is the processor facts (one JSON object per line: refund_id, user_key, issued_at), written by whoever
    reads Stripe; this check never guesses a refund into existence. An unreadable or malformed feed RAISES - a
    watchdog must page 'cannot check', never report clean - and a refund whose issued_at cannot be parsed is a
    finding, not silence. Confirmed means a refund-confirm verify_messages row with status 'sent' names that refund
    id; anything else (attempted-but-stuck, refused, deferred, never touched) is worth a human's attention."""
    from datetime import datetime, timezone
    path = Path(feed)
    text = path.read_text(encoding="utf-8")   # missing/unreadable -> raises
    now_dt = (datetime.strptime(now, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc) if now
              else datetime.now(timezone.utc))
    rows = db.execute("SELECT request_ids_json, status FROM verify_messages WHERE campaign = 'refund-confirm'"
                      " AND status = 'sent'").fetchall()
    told: set[str] = set()
    for refs, _status in rows:
        try:
            for ref in json.loads(refs or "[]"):
                # a ref is either {"request_id": ...} or the bare id string (older rows and the claim helpers)
                rid = str(ref.get("request_id") or "") if isinstance(ref, dict) else str(ref or "")
                if rid:
                    told.add(rid)
        except (ValueError, TypeError):
            continue          # an unreadable refs cell cannot confirm anything; it never confirms a refund
    seen: set[str] = set()
    unconfirmed = []
    for n, line in enumerate(text.splitlines(), 1):
        line = line.strip()
        if not line:
            continue
        try:
            rec = json.loads(line)
        except ValueError as exc:
            raise ValueError(f"{path}:{n}: not JSON ({exc})") from exc
        if not isinstance(rec, dict):
            raise ValueError(f"{path}:{n}: not a JSON object")
        rid = str(rec.get("refund_id") or "")
        if not REFUND_ID_RE.match(rid):
            raise ValueError(f"{path}:{n}: refund_id {rid!r} is not a Stripe refund id (re_...)")
        if rid in seen:
            continue
        seen.add(rid)
        if rid in told:
            continue
        issued_raw = str(rec.get("issued_at") or "")
        try:
            issued = datetime.strptime(issued_raw, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
        except ValueError:
            unconfirmed.append({"refund_id": rid, "user_key": str(rec.get("user_key") or ""),
                                "issued_at": issued_raw, "age_hours": None,
                                "why": "issued_at is not a canonical UTC timestamp, so the age cannot be measured"})
            continue
        age_h = (now_dt - issued).total_seconds() / 3600.0
        if age_h >= hours:
            unconfirmed.append({"refund_id": rid, "user_key": str(rec.get("user_key") or ""),
                                "issued_at": issued_raw, "age_hours": round(age_h, 1),
                                "why": f"refunded {age_h:.1f} h ago and no refund-confirm note has been sent"})
    return {"feed": str(path), "hours": hours, "checked": len(seen), "unconfirmed": unconfirmed,
            "ok": not unconfirmed}


def stamp_problem(row: Any, rulings: dict[str, Any]) -> str:
    """Why this row is not a validly-authorized send ('' when it is). Reads the stamp only: the ledger, never a log.

    QA 2026-11-04 finding 2: the template hash is RECOMPUTED from the row's own campaign|kind|copy|variant, not merely
    checked for being non-empty. A fabricated-but-well-shaped digest is worse than a missing one: it makes the audit
    that exists to prove which template rendered the note report clean on a note no template produced."""
    kind, approval_id, template_sha256 = row[6], row[7], row[8]
    approved_by, campaign, copy_ref = row[9], row[1], row[5]
    variant = row[10] if len(row) > 10 else ""
    created_at = row[11] if len(row) > 11 else ""
    if not kind:
        # A row written BEFORE the stamped gate went live cannot carry a stamp, and the old gate accepted exactly one
        # approver - the captain's Slack user id - so such a row that names it is history, not a finding. (Without
        # this the audit reports every pre-stamp row forever and the unit sits in systemd 'failed' every 15 minutes
        # over 677 sends that were all legitimately authorised.)
        #
        # QA 2026-11-05 round 6 finding 2: the absence of a stamp is NOT the evidence. A row written AFTER the cutover
        # with no stamp is a finding whoever approved_by names, because the stamped gate always writes one - so an
        # unstamped captain-attributed row appearing tomorrow is exactly the thing this audit exists to catch. The
        # provenance is a POSITIVE fact (created_at before the cutover), never an inference from the gate's behaviour.
        if str(approved_by) == CAPTAIN_UID and str(created_at or "") and str(created_at) < STAMP_CUTOVER:
            return ""
        if str(approved_by) == CAPTAIN_UID:
            return (f"no approver stamp on a row created {created_at or 'at an unknown time'}, which is not before the "
                    f"stamped gate went live ({STAMP_CUTOVER}) - an unstamped send after the cutover is a finding "
                    f"whoever approved_by names")
        return "no approver stamp (a send that did not come through the stamped gate path)"
    if kind not in APPROVER_KINDS:
        return f"unknown approver kind {kind!r}"
    if not approval_id:
        return "no approval id"
    if kind == APPROVER_CAPTAIN:
        if not SLACK_UID_RE.match(str(approval_id)):
            return f"captain-slack approval id {approval_id!r} is not a Slack user id"
        if str(approved_by) != str(approval_id):
            return f"the stamp names {approval_id} but approved_by is {approved_by}"
    else:
        if not RULING_ID_RE.match(str(approval_id)):
            return f"fable-ruling approval id {approval_id!r} is not a ruling id"
        if str(approved_by) != str(approval_id):
            return f"the stamp names {approval_id} but approved_by is {approved_by}"
        entry = rulings.get(str(approval_id))
        if entry is None:
            return f"ruling {approval_id} is not in the registry (policies/fable-rulings.json)"
        allowed = (entry.get("classes") or {}).get(str(campaign)) or []
        if str(copy_ref or "") not in allowed:
            return (f"ruling {approval_id} does not pre-approve copy {copy_ref!r} for campaign {campaign!r} "
                    f"(it lists {allowed or 'nothing'})")
    if not template_sha256:
        return "no template hash"
    if not TEMPLATE_SHA_RE.match(str(template_sha256)):
        return f"template hash {str(template_sha256)[:16]}... is not a sha256 digest"
    want = template_identity_sha256(campaign=str(campaign or ""), kind=str(row[4] or ""),
                                    copy_ref=str(copy_ref or ""), variant=str(variant or ""))
    if str(template_sha256) != want:
        return (f"template hash {str(template_sha256)[:16]}... does not match the row's own identity "
                f"(campaign={campaign!r} kind={row[4]!r} copy={copy_ref!r} variant={variant!r} -> {want[:16]}...)")
    return ""


def audit_stamps(db: sqlite3.Connection, *, since_day: str, registry: str | Path) -> dict[str, Any]:
    """Every send from `since_day` on must carry a usable approval stamp. Returns the rows that do not, so a watchdog
    can page: an unauthorized customer message is the one failure this ledger exists to make impossible to hide."""
    rulings = load_rulings(registry)
    q = ("SELECT id, campaign, status, day, kind, copy_ref, approver_kind, approval_id, template_sha256, approved_by, "
         "variant, created_at FROM verify_messages WHERE status IN ('attempted','sent') AND day >= ? ORDER BY id")
    rows = db.execute(q, (since_day,)).fetchall()
    problems = []
    for row in rows:
        why = stamp_problem(row, rulings)
        if why:
            problems.append({"id": row[0], "campaign": row[1], "status": row[2], "day": row[3], "copy_ref": row[5],
                             "approver_kind": row[6], "approval_id": row[7], "why": why})
    return {"since": since_day, "checked": len(rows), "problems": problems,
            "rulings": sorted(rulings), "ok": not problems}


def _main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description="verify-request ledger ops (JSON on stdout)")
    p.add_argument("--db", default=DEFAULT_PATH)
    p.add_argument("--readonly", action="store_true", help="QA #1564: open mode=ro; never create or migrate (read ops only)")
    sub = p.add_subparsers(dest="op", required=True)
    sub.add_parser("migrate", help="create or upgrade the verify tables in this ledger (idempotent; "
                                   "touches no other table); scripts/deploy.sh runs it every deploy")
    for name in ("claim", "refuse"):
        s = sub.add_parser(name)
        s.add_argument("--campaign", default="verify-live", choices=CAMPAIGNS)
        s.add_argument("--user-key", required=True)
        s.add_argument("--day", required=True)
        s.add_argument("--request-ids", required=True, help="comma-separated")
        s.add_argument("--message-type", required=True)
        s.add_argument("--approved-by", required=True)
        s.add_argument("--approval-ref", required=True)
        s.add_argument("--contact-id", default="")
        s.add_argument("--refs-file", default="", help="JSON [{request_id, profile_id, track_id}]")
        s.add_argument("--windowed", action="store_true", help="the note names a 30-day window and a removal date")
        s.add_argument("--reason", default="")
        s.add_argument("--user-id", default="",
                       help="the Muso account id (the per-user locks key on it too; re-checkable refusals)")
        s.add_argument("--reply-due", default="", help="[key=reply-due]: the customer part this note answers")
        s.add_argument("--conversation", default="", help="[key=reply-due]: the thread the answer goes into")
        s.add_argument("--copy-ref", default="", help="p1 615: the gate's copy token this note renders")
        s.add_argument("--variant", default="", help="p1 615: its openers/prefixes, comma-joined (c2, o, ...)")
        s.add_argument("--pick-id", default="", help="QA #1615: reply-ref - the pick the gate matched (re-checked here)")
        if name == "claim":
            # the approval stamp (captain 2026-11-03): who authorized this send, and which template it rendered
            s.add_argument("--approver-kind", default="", choices=("", *APPROVER_KINDS),
                           help="captain-slack | fable-ruling; empty only for callers that predate the stamp")
            s.add_argument("--approval-id", default="", help="the Slack user id, or the fable-ruling-YYYYMMDD-N id")
            s.add_argument("--template-sha256", default="", help="sha256 of the template identity rendered")
    ld = sub.add_parser("log-deferral", help="a note held back for an outside reason: logged, never a lock")
    ld.add_argument("--campaign", required=True, choices=CAMPAIGNS)
    ld.add_argument("--user-key", required=True)
    ld.add_argument("--user-id", default="")
    ld.add_argument("--day", required=True)
    ld.add_argument("--request-ids", required=True)
    ld.add_argument("--message-type", required=True)
    ld.add_argument("--approved-by", required=True)
    ld.add_argument("--approval-ref", required=True)
    ld.add_argument("--reason", required=True, choices=DEFERRAL_REASONS)
    ld.add_argument("--detail", default="")
    te = sub.add_parser("thread-event", help="[key=lamberto-reply-due] a handoff / reassign row, before any post")
    te.add_argument("--kind", required=True, choices=THREAD_EVENTS)
    te.add_argument("--conversation", required=True)
    te.add_argument("--from-admin", required=True)
    te.add_argument("--to-admin", required=True)
    te.add_argument("--note-part", required=True)
    te.add_argument("--reply-due", required=True)
    te.add_argument("--request-ids", required=True)
    te.add_argument("--user-id", default="")
    te.add_argument("--approved-by", required=True)
    te.add_argument("--approval-ref", required=True)
    cr = sub.add_parser("claim-reminder")
    cr.add_argument("--copy-ref", default="")
    cr.add_argument("--variant", default="")
    cr.add_argument("--approver-kind", default="", choices=("", *APPROVER_KINDS))
    cr.add_argument("--approval-id", default="")
    cr.add_argument("--template-sha256", default="")
    cr.add_argument("--parent-message-id", required=True)
    cr.add_argument("--kind", required=True, choices=KINDS[1:])
    cr.add_argument("--user-key", required=True)
    cr.add_argument("--day", required=True)
    cr.add_argument("--request-ids", required=True)
    cr.add_argument("--approved-by", required=True)
    cr.add_argument("--approval-ref", required=True)
    f = sub.add_parser("finalize")
    f.add_argument("--message-row", type=int, required=True)
    f.add_argument("--status", required=True)
    f.add_argument("--message-id", default="")
    f.add_argument("--conversation-id", default="")
    f.add_argument("--reason", default="")
    f.add_argument("--body-sha256", default="")
    f.add_argument("--api-log", default="")
    pn = sub.add_parser("pending", help="the given request ids that have NOT had this campaign's note yet")
    pn.add_argument("--campaign", default="verify-live", choices=CAMPAIGNS)
    pn.add_argument("--request-ids", required=True)
    pn.add_argument("--user-key", default="")
    pn.add_argument("--day", default="")
    pn.add_argument("--user-id", default="")
    sk = sub.add_parser("skip", help="close request ids as skipped (never announced)")
    sk.add_argument("--campaign", required=True, choices=CAMPAIGNS)
    sk.add_argument("--request-ids", required=True)
    rs = sub.add_parser("reminder-state")
    rs.add_argument("--parent-message-id", required=True)
    rs.add_argument("--kind", required=True, choices=KINDS[1:])
    rs.add_argument("--day", required=True)
    g = sub.add_parser("message")
    g.add_argument("--message-id", required=True)
    t = sub.add_parser("mark-tagged")
    t.add_argument("--message-id", required=True)
    t.add_argument("--conversation-id", required=True)
    t.add_argument("--attachments", type=int, default=0)
    mr = sub.add_parser("mark-replied", help="the user replied to a note: hold its removal for a human")
    mr.add_argument("--message-id", required=True)
    mr.add_argument("--replied-at", default="", help="UTC time of the latest user reply (YYYY-MM-DDTHH:MM:SSZ)")
    nn = sub.add_parser("nothing-needed-overlap", help="fable-copy-1030-r5/c2: an earlier status note to this user about "
                        "any of these requests (the ask then opens with the correction)")
    nn.add_argument("--user-id", required=True)
    nn.add_argument("--request-ids", required=True)
    ve = sub.add_parser("v1-eligible", help="may a note over these credits use the v1 (no-deadline) copy?")
    ve.add_argument("--request-ids", required=True)
    nc = sub.add_parser("clear-no-channel", help="a PERSON clears a no-channel hold (after the contact was fixed)")
    nc.add_argument("--user-key", required=True)
    nc.add_argument("--user-id", default="")
    nc.add_argument("--cleared-by", required=True)
    nc.add_argument("--ref", required=True)
    hs = sub.add_parser("hold-silent", help="hold Muso users from the status notes for good (flagged refusal hold)")
    hs.add_argument("--user-ids-file", required=True, help="one Muso user id per line")
    hs.add_argument("--reason", required=True, help="a short slug, e.g. owe-proof-told-nothing-needed")
    fo = sub.add_parser("followed-notes", help="gap-ask: this user's status-doc-received notes of the last 7 days")
    fo.add_argument("--user-key", required=True)
    fo.add_argument("--user-id", default="")
    rp = sub.add_parser("record-pick", help="QA #1601 (2): the reply-ref classifier's pick for conversation + part")
    rp.add_argument("--conversation", required=True)
    rp.add_argument("--part", required=True)
    rp.add_argument("--ref", required=True)
    rp.add_argument("--reason", required=True)
    rp.add_argument("--llm-call-id", default="")
    rp.add_argument("--refs-sha256", default="")
    pf = sub.add_parser("pick-for", help="the latest recorded pick for conversation + part ({} when none)")
    pf.add_argument("--conversation", required=True)
    pf.add_argument("--part", required=True)
    c = sub.add_parser("set-conversation")
    c.add_argument("--message-id", required=True)
    c.add_argument("--conversation-id", required=True)
    at = sub.add_parser("audit-stamps", help="every send from --since on must carry a usable approval stamp; the rows "
                        "that do not are the alert (scripts/audit-approval-stamps.sh pages on them)")
    at.add_argument("--since", required=True, help="UTC day YYYY-MM-DD: audit sends from this day on")
    at.add_argument("--registry", required=True, help="policies/fable-rulings.json (the ruling ids an audit accepts)")
    ru = sub.add_parser("refund-unconfirmed", help="refunds the processor issued that no refund-confirm note has told "
                        "the customer about (the 'refund issued with no confirmation > N h' alert; "
                        "scripts/audit-refund-confirmations.sh pages on them)")
    ru.add_argument("--feed", required=True, help="processor refund facts, one JSON object per line (refund_id, "
                     "user_key, issued_at)")
    ru.add_argument("--hours", type=float, default=24.0, help="age at which a silent refund is a finding (default 24)")
    ru.add_argument("--now", default="", help="evaluate the age at this UTC timestamp (tests: YYYY-MM-DDTHH:MM:SSZ)")
    a = p.parse_args(argv)
    try:
        db = connect_ro(a.db) if a.readonly else connect(a.db)
    except ReadOnlyLedgerError as exc:
        print(json.dumps({"error": str(exc)}), file=sys.stderr)
        return 2
    if a.op == "migrate":
        # connect() already created/upgraded every verify table; report what is there now.
        out = {"result": "ok", "tables": {t: sorted(str(r[1]) for r in db.execute(f"PRAGMA table_info({t})"))
                                          for t in TABLES}}
    elif a.op in ("claim", "refuse"):
        refs = json.loads(Path(a.refs_file).read_text()) if a.refs_file else None
        kw = dict(user_key=a.user_key, day=a.day, request_ids=_ids(a.request_ids), message_type=a.message_type,
                  approved_by=a.approved_by, approval_ref=a.approval_ref, campaign=a.campaign)
        if a.op == "claim":
            out = claim(db, contact_id=a.contact_id, refs=refs, windowed=a.windowed, user_id=a.user_id,
                        reply_due=a.reply_due, conversation=a.conversation, copy_ref=a.copy_ref, variant=a.variant,
                        pick_id=a.pick_id, approver_kind=a.approver_kind, approval_id=a.approval_id,
                        template_sha256=a.template_sha256, **kw)
        else:
            out = refuse(db, reason=a.reason, user_id=a.user_id, **kw)
    elif a.op == "log-deferral":
        out = log_deferral(db, campaign=a.campaign, user_key=a.user_key, user_id=a.user_id, day=a.day,
                           request_ids=_ids(a.request_ids), message_type=a.message_type, approved_by=a.approved_by,
                           approval_ref=a.approval_ref, reason=a.reason, detail=a.detail)
    elif a.op == "record-pick":
        try:
            out = {"id": record_pick(db, conversation=a.conversation, part=a.part, ref=a.ref, reason=a.reason,
                                     llm_call_id=a.llm_call_id, refs_sha256=a.refs_sha256)}
        except PickLocked as exc:            # QA #1615: the send owns this part; the caller must not call the gate
            print(json.dumps({"result": "pick_locked", "error": str(exc)}))
            return 3
    elif a.op == "pick-for":
        out = pick_for(db, conversation=a.conversation, part=a.part) or {}
    elif a.op == "thread-event":
        out = thread_event(db, kind=a.kind, conversation=a.conversation, from_admin=a.from_admin, to_admin=a.to_admin,
                           note_part=a.note_part, reply_due_part=a.reply_due, request_ids=_ids(a.request_ids),
                           user_id=a.user_id, approved_by=a.approved_by, approval_ref=a.approval_ref)
    elif a.op == "claim-reminder":
        out = claim_reminder(db, parent_message_id=a.parent_message_id, kind=a.kind, user_key=a.user_key, day=a.day,
                             request_ids=_ids(a.request_ids), approved_by=a.approved_by, approval_ref=a.approval_ref,
                             copy_ref=a.copy_ref, variant=a.variant, approver_kind=a.approver_kind,
                             approval_id=a.approval_id, template_sha256=a.template_sha256)
    elif a.op == "audit-stamps":
        out = audit_stamps(db, since_day=a.since, registry=a.registry)
    elif a.op == "refund-unconfirmed":
        out = refund_unconfirmed(db, feed=a.feed, hours=a.hours, now=(a.now or None))
    elif a.op == "finalize":
        finalize(db, message_row=a.message_row, status=a.status, message_id=a.message_id,
                 conversation_id=a.conversation_id, reason=a.reason, body_sha256=a.body_sha256, api_log=a.api_log)
        out = {"result": "ok"}
    elif a.op == "pending":
        ids = _ids(a.request_ids)
        blocked = blocked_ids(db, ids, a.campaign)
        out = {"request_ids": [r for r in dict.fromkeys(ids) if r not in blocked],
               "hold": refusal_hold(db, a.campaign, a.user_key, user_id=a.user_id),
               "no_channel": no_channel(db, a.user_key, a.user_id)}
        if a.user_key and a.day:
            out["daily_cap"] = capped(db, user_key=a.user_key, day=a.day, user_id=a.user_id)
        if a.user_key and a.campaign == "retro-past":
            out["user_done"] = past_user_done(db, a.user_key, a.user_id)
        if a.user_key and a.campaign in STATUS_CAMPAIGNS:
            why = uvn_user_done(db, a.user_key, campaign=a.campaign, user_id=a.user_id,
                                request_ids=_ids(a.request_ids) if getattr(a, "request_ids", None) else ())
            out["user_done"] = "" if why in DEFER_REASONS else why
            out["recent"] = why in DEFER_REASONS
            out["recent_why"] = why if why in DEFER_REASONS else ""
        if a.user_key and a.campaign in GAP_LIKE:
            why = gap_user_done(db, a.user_key, user_id=a.user_id)
            out["user_done"], out["recent"], out["recent_why"] = "", bool(why), why
        if a.campaign == UVN_NEW_ROWS:
            why = new_rows_user_done(db, a.user_key, user_id=a.user_id)
            out["prior_uvn_ask"] = why != "no_prior_ask"
            out["user_done"] = why if why == "proof_received" else ""
            out["recent"], out["recent_why"] = why == "messaged_7d", why if why == "messaged_7d" else ""
    elif a.op == "clear-no-channel":
        clear_no_channel(db, user_key=a.user_key, user_id=a.user_id, cleared_by=a.cleared_by, ref=a.ref)
        out = {"result": "cleared"}
    elif a.op == "hold-silent":
        ids = [ln.split("#")[0].strip() for ln in Path(a.user_ids_file).read_text().splitlines()]
        out = hold_silent(db, user_ids=[i for i in ids if i], reason=a.reason)
    elif a.op == "followed-notes":
        out = followed_notes(db, a.user_key, user_id=a.user_id)
    elif a.op == "skip":
        out = {"skipped": skip_requests(db, campaign=a.campaign, request_ids=_ids(a.request_ids))}
    elif a.op == "reminder-state":
        out = reminder_state(db, parent_message_id=a.parent_message_id, kind=a.kind, day=a.day)
        if out.get("result") == "due":       # QA #1588: the pre-send peek reads the same hold the claim enforces
            out["no_channel"] = no_channel(db, out.get("user_key") or "", out.get("account_id") or "")
    elif a.op == "message":
        r = message(db, a.message_id)
        out = dict(r) if r is not None else None
    elif a.op == "mark-tagged":
        mark_tagged(db, message_id=a.message_id, conversation_id=a.conversation_id, attachments=a.attachments)
        out = {"result": "ok"}
    elif a.op == "v1-eligible":
        out = v1_eligible(db, _ids(a.request_ids))
    elif a.op == "nothing-needed-overlap":
        out = nothing_needed_overlap(db, a.user_id, _ids(a.request_ids))
    elif a.op == "mark-replied":
        out = {"result": mark_replied(db, message_id=a.message_id, replied_at=a.replied_at)}
    else:
        set_conversation(db, message_id=a.message_id, conversation_id=a.conversation_id)
        out = {"result": "ok"}
    print(json.dumps(out))
    return 0


if __name__ == "__main__":
    sys.exit(_main())
