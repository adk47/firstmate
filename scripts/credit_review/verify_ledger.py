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
  decline      ONE reason-free decline to the owner of a request we closed (captain 2026-10-29
               13:2xZ; decline-copy-ruling.md). A notice, not an ask: it closes nothing, asks for
               nothing, and names no reason (the row keeps its real one internally). Sent by the
               L12 close path only when core's own credits_rejected email is not routed to that
               user, so a user never gets two declines; once per request id ever, one message per
               user per day, and none within 7 days of another note from this gate.
  Details: docs/credit-verification/verify-request-notes.md.

Guarantees:
  - a request id gets a campaign's initial note AT MOST once;
  - each reminder kind is sent AT MOST once per note; a decline names a request AT MOST once;
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
document awaits review for it (held for a human). A rejected credit is told ONCE, in the
`decline` campaign's reason-free words (no reason, no document list, no date: the reviewer's
coded reason stays on the row and in the audit file, never in the copy), and is removal-due
only once that decline actually went out (never before the user is told) and its own note's
removal day has come. Any user reply to the note (extension_requested_at) holds its
unreviewed credits for a human, and a reply after the decline holds that credit until a
review rules on it again (last_reply_at per message).

The wrapper calls this as a CLI (one op per call, JSON on stdout). The driver
(credit_review/verify_notify.py) imports it.
"""

from __future__ import annotations

import argparse
import contextlib
import hashlib
import importlib.util
import json
import os
import re
import sqlite3
import time
import urllib.parse
import sys
from datetime import date, datetime, timedelta, timezone
from pathlib import Path
from typing import Any, Callable

DEFAULT_PATH = os.environ.get("CREDIT_REVIEW_LEDGER", "/var/lib/hydra/credit-review/ledger.sqlite3")
# The path every deployed sender is pinned to (intercom-verify-request.sh PROD_LEDGER, credit-verify-outbound.sh
# LEDGER; test_verify_ledger_contract.py holds the three equal). A literal: no env var or flag moves it. connect() never
# creates the send record at this path (see LedgerAbsentError).
PRODUCTION_PATH = "/var/lib/hydra/credit-review/ledger.sqlite3"
SEND_RECORD_TABLE = "verify_messages"
MAX_ATTEMPTS = 3
BLOCKING = ("attempted", "sent", "refused", "skipped")
DEFERRED = "deferred_pending_doc"
# decider-support (Fable d2 [key=decider-support-arm], coordinated with verify-ask-wiring-h2): the credit decider's
# OWN ask. The support write is `unverified -> user_verification_needed` and the note a user sees for it comes from
# core (Knock), so no hydra sender posts it - but it IS an ask for the user, so it must be ledgered HERE or the
# tick's shared per-user locks (asked_within / capped, and the one-sender-per-family rule) cannot see it and a
# second sender mails the same person the same day. record_external_ask() writes those rows; nothing in this
# module sends anything for this campaign, and it is deliberately NOT a STATUS_CAMPAIGN and NOT uvn-status
# (prior_uvn_ask stays False: the decider's in-app note is a different flare than the uvn-status email).
DECIDER_SUPPORT = "decider-support"
CAMPAIGNS = ("verify-live", "retro-past", "removal-notice", "takeback-notice", "uvn-status", "withdrawal-confirm",
             "status-doc-received", "status-team-review", "email-changed", "email-changed-dup",
             "claim-proof-ask", "claim-status", "gap-ask", "merge-pending", "credit-hold-status", "claim-proof-pending", "proof-need-ask",
             "merge-claim-first",
             "credit-approved-elsewhere",   # send-locked; see APPROVED_ELSEWHERE below
             "proof-refusal",   # the reason-bearing note for a rejected document; see PROOF_REFUSAL below
             "agent-reply",   # a reply an agent composed, sent on the copy gate's signed verdict; see AGENT_REPLY
             "reply-ref",   # [key=product-dispute-refs]: r5's approved reply set, reply_due answers only
             "refund-confirm",   # fable-copy-1103-d2/refund-confirm: a refund that ALREADY happened, told once per refund id
             "uvn-new-rows",   # fable-copy-1101-r5/n1: a told user's owed rows no ask named (one message per row ever)
             "backlog-reply",
             "decline",    # captain 2026-10-29 13:2xZ + decline-copy-ruling.md: the ONE reason-free decline
             DECIDER_SUPPORT,  # Fable d2 [key=decider-support-arm]: the decider's support write is an ask
             # [key=wait-apology] (Fable d2 2026-11-05 01:4xZ): the apology + live status line for users who waited
             # with no message from us. ONE per user, ever - and ledgered under ITS OWN campaign so every 7-day gate
             # (the ask families', the status notes', the core notice) sees it: nobody gets this and a status note in
             # the same week, and nobody gets it twice.
             "wait-apology",
             # uvn-reminder-14 (captain 2026-11-13 15:08Z): the ONE reminder of a sent uvn-status ask, 14 days on,
             # to a user who neither replied nor sent a document. See UVN_REMINDER below.
             "uvn-reminder-14")
# backlog-reply (intercom-backlog-i1, hydra#1379; Fable review @092894d4): a reply in an Intercom
# conversation where the customer spoke last, sent by scripts/intercom-backlog/send.py through
# intercom-ops-write.sh. Its "request id" is "conv-<conversation id>" (one reply per conversation,
# ever); it is a notice, not an ask, so only its own rows block it. It exists in THIS ledger so the
# one-message-per-user-per-UTC-day cap (capped()) and the status campaigns' 7-day deferral see it.
BACKLOG_REPLY = "backlog-reply"
# agent-reply (caroline-coach-c1, after hydra#1998): ONE reply an agent composed for ONE Intercom conversation,
# posted on the copy gate's SIGNED verdict (scripts/intercom-agent-reply.py -> intercom-ops-write.sh reply
# --agent). Its "request id" is "conv-<conversation id>" - deliberately the SAME key backlog-reply uses, so the
# two reply campaigns can see each other and one thread is never answered twice - and it exists in THIS ledger
# for one reason: the one-message-per-user-per-UTC-day cap and that conversation key must see the reply, or the
# next campaign messages the same person the same day. A NOTICE: it asks for nothing and closes no ask.
AGENT_REPLY = "agent-reply"
# decline (captain 2026-10-29 13:2xZ verbatim: "It feels like we are over-communicating when we deny a credit: we
# could just say supporting information was not provided adequate enough to earn the credit, and if they want to
# submit something they can submit something again to start the process again"; ruling decline-copy-ruling.md): the
# owner of a request we closed is told the supporting information was not enough and that they may submit again.
# A NOTICE: it asks for nothing, closes no ask, and says nothing about why (a decline never states a reason, and no
# copy teaches what we check). One per request id, ever; one message per user per UTC day; none within 7 days of
# another note from this gate. It exists for the window where core's own credits_rejected email is not routed
# (MESSAGING_EMAIL_ROUTES): when core's email goes out, core's is the single decline and this campaign sends none.
DECLINE_CAMPAIGN = "decline"
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
# credit-approved-elsewhere (send-locked, the line is not approved): the line to a requester whose credit the
# conflict rule decided `credit_approved_for_another_user`. A notice: only its own rows block it (one message per
# request, ever), it is not an ask for the one-ask locks, and it closes no ask.
APPROVED_ELSEWHERE = "credit-approved-elsewhere"
# proof-refusal (captain 2026-11-15, the three bodies approved corr=208a8463f735ff45): the note that tells a person
# why the document they sent did not verify a credit and what would. A notice: only its own rows block it (one
# message per request, ever), it is not an ask for the one-ask locks or the 90-day re-ask lock, and it closes no ask.
# It is deliberately not an ASK_CAMPAIGN: a refusal starts no expiry window on the request it names.
PROOF_REFUSAL = "proof-refusal"
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
                    CLAIM_PENDING_CAMPAIGN, CREDIT_HOLD_CAMPAIGN, "reply-ref", BACKLOG_REPLY, DECLINE_CAMPAIGN,
                    APPROVED_ELSEWHERE, PROOF_REFUSAL, AGENT_REPLY)
# Campaigns whose gate refusals are re-checkable (firstmate 076, 082, 083): a refusal holds the
# USER (campaign, user_key or user_id) in verify_refusal_holds for RECHECK_DAYS (the runner and the gate skip
# them until next_recheck_at, whatever requests are listed); a later send clears it; after
# MAX_REFUSALS refusals it is posted once to #cs_priority for a human and the user is blocked.
RECHECKABLE_REFUSALS = ("status-doc-received", "status-team-review", "email-changed", "email-changed-dup",
                        CREDIT_HOLD_CAMPAIGN)
RECHECK_DAYS = 7
# r5 770 (2): the retry horizon must be SHORTER than the tick cadence, not equal to it. At exactly 2 h against a
# 2-hourly tick the hold written mid-tick (say 04:20) was still live when the 06:03 tick ran (06:03 < 06:20:00), so that
# tick counted the SAME failure again and the count only advanced on every OTHER tick - the 3-tick page landed on tick 5.
# 1 h is inside the cadence with room for a tick that starts later than its boundary: the very next tick always sees an
# expired hold and counts a new, consecutive failure.
# 2026-11-13: the tick went HOURLY (scripts/install-aux-units.sh) and this number was NOT changed with it, so the rule
# above is no longer met: 1 h now EQUALS the cadence. A hold written at 04:20 is live at the 05:03 tick, which skips the
# user, so a failing read is retried on every OTHER tick. In wall-clock terms that is what the 2-hourly tick did (a retry
# about every 2 h, the page about 4 h after the first failure); what is lost is "the next tick always retries". The
# value that restores it has to be under an hour AND outlast the tick that wrote it, and ticks run 10 to 95 minutes:
# that is a decision, not a constant to halve.
READ_RETRY_H = 1
# ... and three consecutive failed reads across ticks is a pattern, not a fluke: it pages a human.
READ_FAILURES_TO_PAGE = 3
MAX_REFUSALS = 3
# The campaigns that ASK the user for something. Only these count as "already asked";
# notices and confirmations (removal-notice, takeback-notice, withdrawal-confirm) never close
# a user's asks (firstmate 063/064).
UVN_NEW_ROWS = "uvn-new-rows"
# an uvn-new-rows note IS an ask (its rows are never asked again by any ask), but it is never the user's one-ask-ever:
# it exists because the user was already asked (prior_uvn_ask)
ASK_CAMPAIGNS = ("verify-live", "retro-past", "uvn-status", GAP_ASK, PROOF_NEED_ASK, UVN_NEW_ROWS, DECIDER_SUPPORT)
# uvn-reminder-14 (captain 2026-11-13 15:08Z, "fix it scale it now" / "see it through": yes on re-asking verification
# non-responders after 14 days). The ONE reminder of a SENT uvn-status ask: it names the same requests the ask named,
# so only its own rows block it (blocked_ids), and it is ledgered under its own campaign with kind 'initial', its
# parent_row naming the ask it follows - one per user per ask (reminder14_user_done). It is deliberately NOT in
# ASK_CAMPAIGNS: a reminder is a follow-up of an
# ask, never a new one, so it neither restarts nor shortens REASK_LOCK_DAYS (90, unchanged for every first ask) and
# asked_within() never counts it. Who may get it is decided by reminder14_user_done alone.
UVN_REMINDER = "uvn-reminder-14"
UVN_REMINDER_AFTER_DAYS = 14
# reminder14_user_done reasons that only DEFER (nothing closed, the user is offered again later)
REMINDER_DEFER_REASONS = ("messaged_7d", "not_due")

# Historical only (deleted from the sender 2026-11-04): rows of this kind stay readable in
# the ledger, and `reminders_due` no longer offers it. Do not re-add it to a sender campaign
# without a new copy ruling - the old copy named which check failed.
AFTER_REJECTION = "after-rejection"
KINDS = ("initial", "reminder-14", "reminder-25", AFTER_REJECTION, CLAIM_REMINDER)
# Days after a WINDOWED note (reminder-14/25) or a claim-proof-ask note (reminder-7) at which each
# reminder becomes due.
REMINDER_DAYS = {"reminder-14": 14, "reminder-25": 25, CLAIM_REMINDER: 7}
# The reviewer's reason for a rejection: a fixed list, recorded on the review row and in the audit file. No copy
# shows a code, and a DECLINE never states a reason (captain 2026-10-29 13:2xZ + decline-copy-ruling.md). Scoped by
# the captain on 2026-11-15: a statement about a document the person sent is not a denial of the person, so the
# proof-refusal campaign selects one approved sentence by (reason, the reader's recorded need) for the three
# reasons that have one (credit_review/proof_refusal.PAIRS). The decider's CLI validates against this list and the
# removal path reports it to a human.
REJECTION_REASONS = ("doesnt_name_you", "other_track", "other_role", "unreadable", "not_a_document")
WINDOW_DAYS = 30            # windowed (new provisional approval) notes only
UNVERIFIED_AFTER_DAYS = 30  # retro-past: no proof after this long -> exported as unverified (credit stays)

SCHEMA = """
CREATE TABLE IF NOT EXISTS verify_messages (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  campaign TEXT NOT NULL,            -- verify-live | retro-past | removal-notice
  kind TEXT NOT NULL,                -- initial | reminder-14 | reminder-25 | reminder-7
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
  approver_kind TEXT,                -- captain-slack | fable-ruling | copy-gate; NULL only on rows written before 2026-11-03
  approval_id TEXT,                  -- the Slack UID, or the fable-ruling-YYYYMMDD-N id, that authorizes this send
  template_sha256 TEXT,              -- sha256 of the template identity it rendered (campaign|kind|copy|variant)
  copy_verdict_id TEXT,              -- outbound copy gate: the reviewer's signed verdict on body_sha256 (ocv-...)
  copy_verdict_sha256 TEXT,          -- sha256 of that signed statement, so the row names the exact artefact
  copy_review TEXT                   -- what the copy review said when the note left: approved | observed:<pending|rewrite|...>
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
-- Fable 2026-11-05 00:1xZ (firstmate 769), amending #1780: a user whose own send-time READ failed is held
-- for READ_RETRY_H (1 h), so on the hourly cron the retry lands on the tick after next (see READ_RETRY_H),
-- never for the 7-day refusal window - an unreadable read is not a refusal, and
-- suppressing the account for a week because one query failed is exactly the starvation #1780 exists to end.
-- Separate table on purpose: the refusal counters must never be polluted by read failures, and a read
-- failure must be visible (and pageable) for campaigns that do not honour refusal holds at all.
CREATE TABLE IF NOT EXISTS verify_read_failures (
  campaign TEXT NOT NULL,
  user_key TEXT NOT NULL,            -- lower-cased user key (user:<id> for uvn-status)
  user_id TEXT,
  failures INTEGER NOT NULL DEFAULT 1,  -- CONSECUTIVE failures; 3 across ticks pages (firstmate 769)
  reason TEXT,
  next_retry_at TEXT NOT NULL,       -- now + READ_RETRY_H: retried within 2 h (see READ_RETRY_H), nothing longer
  first_failed_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  paged_at TEXT,                     -- set once when it was reported for a human
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
CREATE INDEX IF NOT EXISTS verify_messages_account ON verify_messages(account_id);
CREATE INDEX IF NOT EXISTS verify_messages_campaign_status ON verify_messages(campaign, status, created_at);
"""
# verify_messages_account is what lets every _same_user read use SQLite's multi-index OR (user_key, account_id, and the
# account_id IS NULL legacy rows) instead of a full scan of verify_messages. Measured on a copy of node-8's ledger,
# 2026-11-16 (15,164 messages, 1.2M decisions, 383 users, identical answers): capped 19.9 -> 0.8 ms, uvn_user_done
# 19.9 -> 4.9 ms, no_channel 6.1 -> 0.2 ms. claim() reads all three inside BEGIN IMMEDIATE, so the write lock every
# sender shares was held ~45 ms per claim for reads alone (data/verif-1000-per-min-r1/report.md).
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
#
# 2026-11-13: it is SCOPED, never assigned. credit-review.py used to set it to True and leave it, so a process that ran
# a kill-switch dry run and then anything that writes got a mode=ro ledger for the write too, with nothing saying why.
# Enter it with `with read_only_process():`; it is restored on the way out, an exception included.
READ_ONLY_PROCESS = False


@contextlib.contextmanager
def read_only_process():
    """Every connect() inside the block is connect_ro(must_exist=True). Restores what it found, so blocks nest."""
    global READ_ONLY_PROCESS
    before = READ_ONLY_PROCESS
    READ_ONLY_PROCESS = True
    try:
        yield
    finally:
        READ_ONLY_PROCESS = before


def ledger_open() -> Any:
    """ledger_open.py, loaded from THIS file's directory: the read opener, the write opener, and the error that names
    why a write was refused. Not `from . import ledger_open`: this file is also run as a script
    (`python3 -I verify_ledger.py migrate`, deploy.sh) and imported top-level, where there is no parent package."""
    name = "credit_review_ledger_open"
    cached = sys.modules.get(name)
    if cached is not None:
        return cached
    path = Path(__file__).resolve().with_name("ledger_open.py")
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise ImportError(f"{path} cannot be loaded")
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module          # before exec: dataclasses resolves a class's module through sys.modules
    try:
        spec.loader.exec_module(module)
    except BaseException:
        sys.modules.pop(name, None)
        raise
    return sys.modules[name]


class LedgerAbsentError(RuntimeError):
    """The production ledger has no send record (no file, or a file with no verify_messages table), and this open
    would have created an empty one. An empty send record answers "never messaged" for every person, so a sender on
    a host that lacks the real ledger would message everyone again. Measured 2026-11-13: `pending` against a missing
    path exited 0 with daily_cap false and user_done "" and left a 73,728-byte ledger with 0 rows.
    Deliberately NOT a ReadOnlyLedgerError and not a sqlite3.Error: the callers that tolerate those and carry on
    must not tolerate this."""


def is_production_path(path: str) -> bool:
    """True when `path` is the production ledger, a symlink to it included."""
    return path != ":memory:" and os.path.realpath(path) == os.path.realpath(PRODUCTION_PATH)


def _has_send_record(db: sqlite3.Connection) -> bool:
    return db.execute("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?",
                      (SEND_RECORD_TABLE,)).fetchone() is not None


def _holds_tables(db: sqlite3.Connection) -> bool:
    return db.execute("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'").fetchone() \
        is not None


def _absent(path: str, what: str) -> LedgerAbsentError:
    return LedgerAbsentError(
        f"verify ledger {path} {what}; refusing to create an empty send record (it would say nobody was ever "
        "messaged). Restore the send record, or init a fresh path")


def _missing(path: str) -> LedgerAbsentError:
    return LedgerAbsentError(
        f"verify ledger {path} does not exist; refusing to create an empty send record (it would say nobody was "
        f"ever messaged). On a host that has truly never sent run: verify_ledger.py --db {path} init")


def _connection_path(db: sqlite3.Connection) -> str:
    """The file a connection opened elsewhere is attached to ('' for :memory: or an unreadable handle)."""
    try:
        rows = db.execute("PRAGMA database_list").fetchall()
    except sqlite3.Error:
        return ""
    for row in rows:
        if str(row[1]) == "main":
            return str(row[2] or "")
    return ""


def connect(path: str, *, create: bool = False) -> sqlite3.Connection:
    """The WRITE opener (migrates; creates a scratch ledger). A read-only run uses connect_ro(), or
    read_only_process() around its whole body. A write this connection is refused raises
    ledger_open().LedgerNotWritableError naming the reason.

    At PRODUCTION_PATH it never creates the send record: a missing file, or a file with no verify_messages table,
    raises LedgerAbsentError and nothing is written. `create=True` is the one way to make it, and only init() passes
    it. New tables and columns are still added to a ledger that already holds the send record."""
    if READ_ONLY_PROCESS and path != ":memory:":
        return connect_ro(path, must_exist=True)
    guarded = not create and is_production_path(path)
    if guarded and not Path(path).is_file():
        raise _missing(path)
    if path != ":memory:" and not guarded:
        Path(path).parent.mkdir(parents=True, exist_ok=True)
    db = ledger_open().open_rw(path, opener="verify_ledger.connect", timeout=30, isolation_level=None)
    db.row_factory = sqlite3.Row
    if guarded and not _has_send_record(db):
        db.close()
        raise _absent(path, f"has no {SEND_RECORD_TABLE} table")
    db.executescript(SCHEMA)
    _migrate(db)
    db.executescript(INDEXES)
    return db


class ReadOnlyLedgerError(RuntimeError):
    """A read-only open is impossible without writing (the ledger is missing or needs a migration)."""


# verify-outbound-migration-race-m1 (Fable 2026-11-05 12:2xZ): a reader that opens between two of _migrate()'s ALTERs
# sees a PARTIAL schema and refuses - correct for a genuinely stale ledger, wrong for a migration that is mid-flight.
# Part 1 makes the migration atomic (one transaction, so a reader sees pre- or post-, never partial); part 3 gives the
# reader a bounded wait for the additive case only. A genuinely un-migrated ledger still raises, loudly.
RO_RETRY_ATTEMPTS = 3
RO_RETRY_SLEEP_S = 2.0


def _schema_gap(db: sqlite3.Connection, ref: sqlite3.Connection) -> list[str]:
    """What connect() would CREATE / ALTER that this ledger lacks - the ADDITIVE difference only. Anything else (a
    missing file, a corrupt file, a schema that differs in some other way) is not this function's business: the caller
    raises on it immediately."""
    q = "SELECT type, name FROM sqlite_master WHERE name NOT LIKE 'sqlite_%'"
    missing = sorted({(str(t), str(n)) for t, n in ref.execute(q)} - {(str(t), str(n)) for t, n in db.execute(q)})
    out = [f"{t} {n}" for t, n in missing]
    for table in TABLES:
        have = {str(r[1]) for r in db.execute(f"PRAGMA table_info({table})").fetchall()}
        want = {str(r[1]) for r in ref.execute(f"PRAGMA table_info({table})").fetchall()}
        if want - have:
            out.append(f"{table}: {sorted(want - have)[:3]}")
    return out


def connect_ro(path: str, *, must_exist: bool = False) -> sqlite3.Connection:
    """QA #1564: the ledger opened READ-ONLY (mode=ro) - never created, never migrated. A ledger whose schema lacks any
    table, index, trigger, view or column connect() would add (it would CREATE / ALTER) raises ReadOnlyLedgerError: the
    caller that must not write (a dry run under the credit-ops-notes kill, the gate's --check-recipient) then refuses
    instead, and a caller whose answer may safely default (a durable idempotency check, a read-failure hold read - see
    `verify_notify._already_noted_today` / `read_hold_until`) catches ReadOnlyLedgerError and continues. It is a
    RuntimeError, not a sqlite3.Error, so `except sqlite3.Error` around a read does NOT tolerate it.
    A ledger that does not exist yet reads as an EMPTY one (an in-memory copy of the schema: nothing was ever sent, so
    nothing is recorded) and no file is created; `must_exist` raises ReadOnlyLedgerError for a missing ledger instead.

    verify-outbound-migration-race-m1: when the ONLY difference is something _migrate() would add, the check is retried
    RO_RETRY_ATTEMPTS times RO_RETRY_SLEEP_S apart before raising - a live tick's migration is a few ALTERs, and a
    reader that lands inside it must not report 89 FAILED. After the window it raises exactly as before: the tolerance
    is for a race, never for a deploy gap."""
    if path == ":memory:" or not Path(path).exists():
        if must_exist:
            raise ReadOnlyLedgerError(f"verify ledger {path} does not exist (a read-only run never creates it)")
        mem = sqlite3.connect(":memory:", isolation_level=None)
        mem.row_factory = sqlite3.Row
        mem.executescript(SCHEMA)
        mem.executescript(INDEXES)
        return mem
    ref = sqlite3.connect(":memory:")
    try:
        # QA #1564 (round 2): EVERYTHING connect() could write is checked - every table, index, trigger and view that
        # SCHEMA + INDEXES create (a missing index = CREATE INDEX = a schema write), and every column (_migrate)
        ref.executescript(SCHEMA)
        ref.executescript(INDEXES)
        gap: list[str] = []
        for attempt in range(1, RO_RETRY_ATTEMPTS + 1):
            # QA #1564: the path is PERCENT-ENCODED into the URI - a raw '?' (or '#') in it would end the path early and
            # open a different, writable file without mode=ro. Re-opened per attempt: a schema change made by the
            # migrating writer is only guaranteed visible to a fresh read.
            # (ledger_open.open_ro does the encoding.) A write on this connection raises
            # ReadOnlyConnectionWriteError, which says the caller holds a reader - never a bare OperationalError.
            db = ledger_open().open_ro(path, opener="verify_ledger.connect_ro", timeout=30, isolation_level=None)
            db.row_factory = sqlite3.Row
            try:
                gap = _schema_gap(db, ref)
            except sqlite3.DatabaseError as exc:      # corrupt / not a database: never a race, never retried
                db.close()
                raise ReadOnlyLedgerError(f"verify ledger {path} cannot be read ({exc})") from exc
            if not gap:
                return db
            db.close()
            if attempt < RO_RETRY_ATTEMPTS:
                time.sleep(RO_RETRY_SLEEP_S)
        raise ReadOnlyLedgerError(f"verify ledger {path} needs a migration (missing {gap[:3]}); "
                                  "a read-only run never migrates it")
    finally:
        ref.close()


def init(path: str) -> dict[str, Any]:
    """The one explicit creation of the send record, for a host that has truly never sent. A ledger that already
    holds it is left exactly as it is (`exists`): init never empties, replaces or re-stamps one.

    An existing file that holds tables but no send record is REFUSED, never given an empty one: that file is a
    restored pre-send-record backup (or another instance's file), and an empty send record beside the decider's
    history answers "never messaged" for everyone."""
    if path != ":memory:" and Path(path).is_file():
        ro = ledger_open().open_ro(path, opener="verify_ledger.init", timeout=30, isolation_level=None)
        try:
            if _has_send_record(ro):
                return {"result": "exists", "path": path}
            if _holds_tables(ro):
                raise LedgerAbsentError(
                    f"verify ledger {path} exists without a send record - restore the send record, or init a "
                    "fresh path")
        finally:
            ro.close()
    connect(path, create=True).close()
    return {"result": "created", "path": path}


def ensure_schema(db: sqlite3.Connection) -> None:
    """Create/migrate this ledger's tables on a connection opened elsewhere (the credit decider's
    own handle: its asks live in verify_messages in the same file). Idempotent.

    It refuses to START the send record at PRODUCTION_PATH, like connect(): a decider handle to a ledger that has
    no verify_messages table would otherwise create an empty one, which answers "never messaged" for everyone."""
    path = _connection_path(db)
    if path and is_production_path(path) and not _has_send_record(db):
        raise _absent(path, f"has no {SEND_RECORD_TABLE} table")
    db.executescript(SCHEMA)
    _migrate(db)


def _migrate(db: sqlite3.Connection) -> None:
    """Add every column SCHEMA has that an existing (older) table lacks, so a ledger
    created by an earlier version of this module keeps working.

    verify-outbound-migration-race-m1: the whole column set is ONE transaction (BEGIN IMMEDIATE / COMMIT, ROLLBACK on
    error). SQLite DDL is transactional, so a concurrent reader sees the pre-migration schema or the post-migration
    schema - never the partial one that produced 89 FAILED at 11:49:02Z.

    QA #1799 r10: the gap is derived UNDER the write lock, not before it. Deriving it first let two migrators read the
    same pre-migration schema; the loser then acquired the lock after the winner had committed, executed its now-stale
    ALTER list and died on "duplicate column name" - and the pre-tick migration path turns that into a killed tick over
    a ledger that is already current. BEGIN IMMEDIATE serialises the readers of the gap as well as the writers of it."""
    ref = sqlite3.connect(":memory:")
    try:
        ref.executescript(SCHEMA)
        db.execute("BEGIN IMMEDIATE")
        try:
            for stmt in _alters(db, ref):
                db.execute(stmt)
            db.execute("COMMIT")
        except Exception:
            db.execute("ROLLBACK")
            raise
    finally:
        ref.close()


def _alters(db: sqlite3.Connection, ref: sqlite3.Connection) -> list[str]:
    """The ALTER statements that bring ``db`` up to ``ref``'s column set. MUST be called inside the write transaction
    (see _migrate): the answer is only true while nobody else can migrate."""
    alters: list[str] = []
    for table in TABLES:
        have = {str(r[1]) for r in db.execute(f"PRAGMA table_info({table})").fetchall()}
        for _, name, typ, notnull, default, _ in ref.execute(f"PRAGMA table_info({table})").fetchall():
            if name in have:
                continue
            decl = f"{name} {typ}"
            if default is not None:
                decl += f"{' NOT NULL' if notnull else ''} DEFAULT {default}"
            alters.append(f"ALTER TABLE {table} ADD COLUMN {decl}")
    return alters


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
STAMP_TS_FORMAT = "%Y-%m-%dT%H:%M:%SZ"


def stamp_ts(value: Any) -> datetime | None:
    """A ledger timestamp as a datetime, or None when it is not exactly the format the writer emits.

    QA 2026-11-05 round 7 follow-up: the provenance check compared created_at to the cutover as STRINGS, which is a
    format predicate, not a time predicate. An epoch integer ("1793843252") or a space-separated stamp
    ("2026-11-05 11:00:00") sorts BEFORE "2026-11-05T11:48:49Z" lexicographically, so an unreadable value was
    silently exempted - the same defect class as an absent one: an unreadable value read as a pass. Parsing strictly
    and returning None on failure makes the caller fail closed.

    QA 2026-11-05 round 8: and it must ROUND-TRIP. strptime accepts a non-zero-padded value ("2026-1-5T1:2:3Z") under
    this format even though the writer never emits one, so a parseable-but-noncanonical stamp would have been exempted
    again - the same defect one level down: a value read as the writer's own when it is only something the parser
    tolerates. Requiring strftime to reproduce the input byte for byte makes "is this the writer's format" a fact
    about the value rather than an assumption about the parser."""
    if not isinstance(value, str) or not value:
        return None
    try:
        parsed = datetime.strptime(value, STAMP_TS_FORMAT)
    except (TypeError, ValueError):
        return None
    if parsed.strftime(STAMP_TS_FORMAT) != value:
        return None
    return parsed.replace(tzinfo=timezone.utc)
APPROVER_RULING = "fable-ruling"
# copy-gate (caroline-coach-c1, 2026-11-15): the authorization is the outbound copy gate's SIGNED verdict on the
# exact bytes (approval id = the ocv-<16 hex> verdict id), not a person and not a ruling. It is a third kind
# rather than an unstamped row because `audit_stamps` reads an unstamped send after the cutover as a finding, and
# a finding is a page: a legitimate path must be able to say what authorized it. The verdict's own signature is
# checked by gate.py before this id exists; the ledger checks only the SHAPE and that the row's bytes, campaign
# and frame are the ones the caller named.
APPROVER_COPY_GATE = "copy-gate"
APPROVER_KINDS = (APPROVER_CAPTAIN, APPROVER_RULING, APPROVER_COPY_GATE)
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
    if kind == APPROVER_COPY_GATE and not COPY_VERDICT_ID_RE.match(approval_id):
        raise ValueError(f"copy-gate approval id {approval_id!r} is not an ocv-<16 hex> verdict id")
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
            # uvn-reminder-14 names the requests its ask named: the ask's own row must not block its one reminder
            other = None if campaign in NOTICE_CAMPAIGNS or campaign == UVN_REMINDER else db.execute(
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


def sent_request_ids(db: sqlite3.Connection, campaign: str) -> set[str]:
    """Every request id (lower-cased) this campaign's note has gone out for, or may have: the request's own row in
    `attempted` (claimed before the POST, so the message may have landed) or `sent`. It is the row the gate writes
    when it sends, read as it stands, so the answer is the same for a second run, a retry and any other entry point.
    Narrower than blocked_ids on purpose: a refused or skipped row closes the request for the campaign and tells the
    customer nothing, and a claim the copy gate gave back (hold_copy_review) leaves no row here at all."""
    if campaign not in CAMPAIGNS:
        raise ValueError(f"unknown campaign {campaign!r}")
    return {str(r[0]).lower() for r in db.execute(
        "SELECT request_id FROM verify_requests WHERE campaign=? AND status IN ('attempted','sent')", (campaign,))}


def _decline_family(db: sqlite3.Connection, request_ids: list[str]) -> int | None:
    """The row of the note a decline answers, so the decline joins that note's FAMILY: the credit's story is one
    family (the note, its reminders, its reviews, the decline and any reply to it), which is what the removal rule,
    the proof sweep and the review all read. The decline itself names no date; the family's note carries it. A
    decline covering credits of several notes is filed under the first one it lists (request ids are unique, and the
    per-credit rules look the credit up, never the row alone)."""
    for rid in request_ids:
        note = _note_of(db, rid)
        if note is not None:
            return note
    return None


CLOSE_SINCE_MARGIN_DAYS = 1


def close_since(db: sqlite3.Connection, request_ids: list[str]) -> dict[str, Any]:
    """The moment these credits were CLOSED, so a caller can ask "did core already tell this user about THIS close"
    instead of "did anyone email this user lately" (QA #1718 B). A user-level window cannot prove a single request
    was not declined: a core note from before the close belongs to an earlier request, and a fixed window either
    misses it (31 days ago -> a second decline) or lets it suppress a request that was never told.

    The close is the earliest `rejected` review on any of the credits, minus a one-day margin for clock and
    propagation. `since: null` = nothing to attribute the read to, and the caller must hold.

    THE NOTE DAY IS A HARD FLOOR, AND IT IS THE IMMUTABLE BOUNDARY (QA #1718, 2026-11-06). A review timestamp cannot
    be the boundary on its own: `verify_proof_reviews.reviewed_at` is OVERWRITTEN by a later re-rejection and
    `mark_tagged` DELETEs the old verdict outright, so a re-rejection moves the earliest surviving review FORWARD.
    A boundary that can move forward excludes core's earlier decline email, a zero count then reads as "core never
    told them", and hydra sends a SECOND decline for the same request - the one forbidden outcome. A request cannot
    be closed before it was asked, and a note's `day` is written once and never edited, so the earliest note that
    asked for these credits is a lower bound on the first close that no later review can move. The answer is the
    EARLIER of the two, so the window can only ever WIDEN toward silence. (A credit no note names - asked outside
    this ledger - still resolves from its reviews alone.)

    The cost is a wider window for a credit asked long before it closed: a core note about ANOTHER of that user's
    requests inside the gap holds this one. That is the safe direction - a hold is printed and a person decides,
    while a duplicate decline is invisible - and it is the same trade the module makes everywhere else."""
    ids = list(dict.fromkeys(str(x).strip() for x in request_ids if str(x).strip()))
    if not ids:
        return {"since": None, "why": "no request ids"}
    q = ",".join("?" * len(ids))
    row = db.execute(f"SELECT MIN(reviewed_at) AS t, COUNT(*) AS n FROM verify_proof_reviews "
                     f"WHERE outcome='rejected' AND request_id IN ({q})", ids).fetchone()
    base = str(row["t"] or "") if row is not None else ""
    why = f"the earliest rejection on these credits ({row['n']} reviewed)" if base else ""
    # the earliest note that ASKED for them: a lower bound on the first close that no re-rejection can move
    note = db.execute(f"SELECT MIN(day) AS d FROM verify_messages WHERE kind='initial' AND parent_row IS NULL "
                      f"AND EXISTS (SELECT 1 FROM json_each(request_ids_json) j WHERE j.value IN ({q}))",
                      ids).fetchone()
    note_day = f"{note['d']}T00:00:00Z" if note is not None and note["d"] else ""
    if note_day and (not base or note_day < base):
        base = note_day
        why = ("the earliest note that asked for these credits (a first close before it is impossible)" if not row
               or not row["t"] else
               f"the earliest note that asked for these credits: a first close before {row['t']} cannot be ruled out")
    if not base:
        return {"since": None, "why": "no review and no note names these credits"}
    day = date.fromisoformat(base[:10]) - timedelta(days=CLOSE_SINCE_MARGIN_DAYS)
    return {"since": f"{day.isoformat()}{base[10:]}", "why": why, "request_ids": ids}


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


# One message per person per UTC day is the rule, and the day is the day the customer GOT it. A row carries the day it
# was CLAIMED on, and a POST accepted after midnight delivers on the next day, so the cap also holds a day on which
# the row's `sent_at` falls (finalize records it). No fixed latency window: the writer has no bounded POST latency
# (QA 2026-11-15).
#
# An `attempted` row is a message that MAY have been delivered and whose delivery day nobody knows, so it holds every
# day until it is reconciled. Bounding it to the day after its claim let a claim still in flight on the 15th be
# followed by another message on the 17th (QA 2026-11-15). The cost is that a stuck attempt blocks that person until
# somebody reconciles it, which is the safe side and is visible: the row says `attempted`.
#
# What this changes for EVERY sender, since they all ask here (measured on node-8's ledger, 2026-11-15 15:00Z):
#   - the delivered-day clause: 1 of 9,280 sent rows with a `sent_at` has it on another day than its claim (a claim at
#     23:59:59, delivered 00:00:17). A row finalized `sent` long after its claim (a backfill, a late reconcile) holds
#     the day it is FINALIZED on as well, because that is what `sent_at` then says;
#   - the unresolved-attempt clause: 1 `attempted` row in the ledger (uvn-status, claimed 2026-11-04), so one person
#     is held from every campaign until that row is settled. No job settles an `attempted` row today.


def capped(db: sqlite3.Connection, *, user_key: str, day: str, user_id: str = "") -> bool:
    """True when this user already has a message (attempted or sent) claimed on this UTC day, any campaign, one
    DELIVERED on it (a claim made before midnight whose POST landed after it), or an unresolved `attempted` one on
    any day (a message that may have been delivered and whose delivery day nobody knows)."""
    cond, params = _same_user(db, user_key, user_id)
    if db.execute(f"SELECT 1 FROM verify_messages m WHERE {cond} AND m.day=? AND m.status IN ('attempted','sent') "
                  "LIMIT 1", (*params, day)).fetchone() is not None:
        return True
    if db.execute(f"SELECT 1 FROM verify_messages m WHERE {cond} AND m.status='sent' AND substr(m.sent_at,1,10)=? "
                  "LIMIT 1", (*params, day)).fetchone() is not None:
        return True
    return db.execute(f"SELECT 1 FROM verify_messages m WHERE {cond} AND m.status='attempted' "
                      "LIMIT 1", params).fetchone() is not None


REASK_LOCK_DAYS = 90
MESSAGED_COOLDOWN_DAYS = 7


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


def deferral_expiry(db: sqlite3.Connection, *, user_key: str, reason: str, user_id: str = "",
                    now: datetime | None = None) -> datetime | None:
    """When the lock that deferred this user lapses, read from the ledger: the first instant the ledger's own
    check admits the person. `messaged_7d` counts the note's own day (`m.day >= now - 7d`), so it lapses the day
    after that window; `recently_asked` uses `m.day > now - 90d`, so it lapses on the 90th day. None when the
    ledger has no row."""
    cond, params = _same_user(db, user_key, user_id)
    if reason == "messaged_7d":
        row = db.execute(f"SELECT MAX(m.day) FROM verify_messages m WHERE {cond} AND m.status IN ('attempted','sent')",
                         params).fetchone()
        days = MESSAGED_COOLDOWN_DAYS + 1
    elif reason == "recently_asked":
        asks = ",".join("?" * len(ASK_CAMPAIGNS))
        row = db.execute(f"SELECT MAX(m.day) FROM verify_messages m WHERE {cond} AND m.kind='initial' "
                         f"AND m.status IN ('attempted','sent') AND m.campaign IN ({asks})",
                         (*params, *ASK_CAMPAIGNS)).fetchone()
        days = REASK_LOCK_DAYS
    else:
        return None
    day = str(row[0])[:10] if row and row[0] else ""
    if not day:
        return None
    try:
        return datetime.strptime(day, "%Y-%m-%d").replace(tzinfo=timezone.utc) + timedelta(days=days)
    except ValueError:
        return None


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
    since = ((now or utcnow()) - timedelta(days=MESSAGED_COOLDOWN_DAYS)).strftime("%Y-%m-%d")
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


_REMINDER_COLS = ("id", "parent_row", "account_id", "user_key", "campaign", "kind", "status", "day", "message_id",
                  "request_ids_json", "proof_tagged_at", "last_reply_at", "extension_requested_at", "proof_attachments")
# What the reminder rule reads per row: the columns above plus `reviewed`, the number of document-review verdicts on
# the row's family. A rejected review sets proof_tagged_at back to NULL (record_proof_review, settle_proof_tags), so
# the tag alone forgets that a document arrived; the attachment count and the verdict rows do not.
_REMINDER_KEYS = (*_REMINDER_COLS, "reviewed")


def _reminder_select(alias: str = "") -> str:
    a = f"{alias}." if alias else "verify_messages."
    return (", ".join(f"{a}{c}" for c in _REMINDER_COLS)
            + f", (SELECT COUNT(*) FROM verify_proof_reviews v WHERE v.family = COALESCE({a}parent_row, {a}id))")


def _day_start(day: str | None) -> datetime | None:
    """00:00 UTC of an ISO day, or None when it is empty or unreadable (the caller then uses the clock)."""
    try:
        return datetime.strptime(str(day or ""), "%Y-%m-%d").replace(tzinfo=timezone.utc)
    except ValueError:
        return None


def reminder14_ask_of(rows: list[dict[str, Any]]) -> dict[str, Any] | None:
    """The ask an uvn-reminder-14 note would follow, from ONE user's ledger rows: their LATEST initial ask across the
    ask campaigns (attempted or sent), or None. The day the copy states ("we asked on <date>") is this row's `day`:
    read from the ledger, never taken from a payload."""
    asks = [r for r in rows if r["kind"] == "initial" and r["status"] in ("attempted", "sent")
            and r["campaign"] in ASK_CAMPAIGNS]
    return max(asks, key=lambda r: (str(r["day"] or ""), int(r["id"]))) if asks else None


def reminder14_why(rows: list[dict[str, Any]], *, now: datetime | None = None) -> str:
    """uvn-reminder-14: why the user these ledger rows belong to must not get the reminder now ('' when they may).
    THE rule: the audience builder (reminder14_bulk), the gate's peek and claim() (reminder14_user_done, inside its
    transaction) all call this one function, so the three cannot disagree about a row they all see.

    Not closed (the user may become eligible):
      'no_prior_ask'  the user's LAST ask is not a SENT uvn-status ask (never asked, asked by another family, or the
                      ask's delivery is unconfirmed): there is nothing this copy may truthfully remind them of.
      'not_due'       the last ask is younger than UVN_REMINDER_AFTER_DAYS (a deferral).
      'messaged_7d'   any note from this gate in the last 7 days (a deferral).
    Closed (never offered again):
      'already_sent'      one reminder per user per ask: a live uvn-reminder-14 row whose parent_row names THIS ask
                          (uvn-status asks a user once, so today one-per-ask and one-per-user select the same people).
                          A live reminder row whose reference is missing or unreadable also closes here: unknown
                          never sends a second reminder.
      'proof_received'    a credit-proof reply is tagged on any credit note, or was (an attachment was counted on
                          it, or a document review of its family is on record - a rejected review clears the tag,
                          and "we haven't received it" would then be false): never re-ask someone who sent documents.
      'replied'           a reply is recorded on any credit note (last_reply_at / extension_requested_at): never
                          re-ask someone who answered. Stricter than "since the ask" on purpose: unknown never asks.
      'already_reminded'  a follow-up of ANY kind ('reminder%') was sent or attempted to this user on or after the
                          ask day, by this gate or by a sender outside it (the 2026-11-09 `reminder-1` rows carry
                          no account id, so a user's rows are matched by account email too): one reminder, whoever
                          sent it.
      'noted_since_ask'   any OTHER credit note was sent or attempted to this user on or after the ask day (a status
                          line, a decline, a note of a sender outside this gate such as the 2026-11-09
                          `first-ask-1` emails): the ask is no longer the last thing we told them, so "we asked
                          and have not heard back" may contradict it. The reminder follows an ask nothing followed.
    The per-day cap is claim()'s (capped). The 90-day one-ask lock is not read here: this is the follow-up of an
    ask, not an ask."""
    ask = reminder14_ask_of(rows)
    if ask is None or ask["campaign"] != "uvn-status" or ask["status"] != "sent":
        return "no_prior_ask"
    live = [r for r in rows if r["status"] in ("attempted", "sent")]
    for r in live:
        if r["campaign"] != UVN_REMINDER:
            continue
        try:
            ref = int(r.get("parent_row"))
        except (TypeError, ValueError):
            return "already_sent"      # no readable reference: fail closed, never a second reminder
        if ref == int(ask["id"]):
            return "already_sent"
    credit = [r for r in rows if r["campaign"] not in CLAIM_CAMPAIGNS]
    if any(r["proof_tagged_at"] or r.get("proof_attachments") or r.get("reviewed") for r in credit):
        return "proof_received"
    if any(r["last_reply_at"] or r["extension_requested_at"] for r in credit):
        return "replied"
    if any(str(r["kind"] or "").startswith("reminder") and str(r["day"] or "") >= str(ask["day"]) for r in live):
        return "already_reminded"
    if any(r["id"] != ask["id"] and r["campaign"] not in CLAIM_CAMPAIGNS and str(r["day"] or "") >= str(ask["day"])
           for r in live):
        return "noted_since_ask"
    at = now or utcnow()
    try:
        due = _plus(str(ask["day"]), UVN_REMINDER_AFTER_DAYS)
    except (TypeError, ValueError):
        return "not_due"           # an unreadable ask day: the reminder waits (stricter, never looser)
    if at.strftime("%Y-%m-%d") < due:
        return "not_due"
    since = (at - timedelta(days=7)).strftime("%Y-%m-%d")
    if any(str(r["day"] or "") >= since for r in live):
        return "messaged_7d"
    return ""


def _reminder14_rows(db: sqlite3.Connection, user_key: str, user_id: str = "") -> list[dict[str, Any]]:
    if not (user_key or str(user_id or "").strip()):
        return []
    cond, params = _same_user(db, user_key, user_id)
    return [dict(zip(_REMINDER_KEYS, r))
            for r in db.execute(f"SELECT {_reminder_select('m')} FROM verify_messages m WHERE {cond}", params)]


def reminder14_ask(db: sqlite3.Connection, user_key: str, user_id: str = "") -> dict[str, Any] | None:
    """This user's ask a reminder would follow (reminder14_ask_of over every ledger row of theirs)."""
    return reminder14_ask_of(_reminder14_rows(db, user_key, user_id))


def reminder14_user_done(db: sqlite3.Connection, user_key: str, *, now: datetime | None = None,
                         user_id: str = "") -> str:
    """reminder14_why over every ledger row of this user (the account id, the account email, and - where the
    decisions table knows the user - a note sent under an earlier email of theirs)."""
    return reminder14_why(_reminder14_rows(db, user_key, user_id), now=now)


def reminder14_bulk(db: sqlite3.Connection, *, now: datetime | None = None) -> dict[int, dict[str, Any]]:
    """{account id: {"why", "asked_day", "request_ids"}} for every account with a ledger row: reminder14_why in ONE
    pass over the ledger, for the audience builder (a per-user read of ~3,500 accounts would be ~3,500 table scans).

    A user's rows here are the rows carrying their account id plus the rows carrying an email any of those rows
    carries - which is how the account-less `reminder-1` rows of 2026-11-09 are found. It does not follow the
    decisions table across an email change, so it can see FEWER rows than the gate does: it is the audience
    pre-filter, and reminder14_user_done (the runner, the peek and the claim) is the decision."""
    rows = [dict(zip(_REMINDER_KEYS, r)) for r in db.execute(f"SELECT {_reminder_select()} FROM verify_messages")]
    by_acct: dict[int, list[dict[str, Any]]] = {}
    by_key: dict[str, list[dict[str, Any]]] = {}
    for r in rows:
        acct = str(r["account_id"] or "").strip()
        if acct.isdigit():
            by_acct.setdefault(int(acct), []).append(r)
        if r["user_key"]:
            by_key.setdefault(str(r["user_key"]), []).append(r)
    out: dict[int, dict[str, Any]] = {}
    for acct, own in by_acct.items():
        mine = {int(r["id"]): r for r in own}
        for key in {str(r["user_key"]) for r in own if r["user_key"]}:
            mine.update({int(r["id"]): r for r in by_key.get(key, [])})
        rs = list(mine.values())
        why = reminder14_why(rs, now=now)
        ask = reminder14_ask_of(rs) or {}
        try:
            ids = [str(i).lower() for i in json.loads(ask.get("request_ids_json") or "[]")]
        except ValueError:
            ids = []
        out[acct] = {"why": why, "asked_day": str(ask.get("day") or ""), "request_ids": ids}
    return out


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


def decline_user_done(db: sqlite3.Connection, user_key: str, *, day: str, user_id: str = "") -> str:
    """decline: why this user must not get one now ('' when they may). Only a deferral exists:
    messaged_7d (a note from this gate in the last 7 days, of any campaign - one decline never
    lands on top of another message). The per-request once is blocked_ids', the one-message-per-user
    -per-UTC-day cap is claim()'s. A decline is a NOTICE: it never blocks an ask and an ask never
    blocks it beyond the 7-day cooldown."""
    cond, params = _same_user(db, user_key, user_id)
    # anchored on the DAY this note would go out (the ledger's own clock), never on the wall clock: a replayed or
    # back-dated run then reads the same window every time.
    since = _plus(day, -7)
    if db.execute(f"SELECT 1 FROM verify_messages m WHERE {cond} AND m.day>=? AND m.status IN ('attempted','sent') "
                  "LIMIT 1", (*params, since)).fetchone():
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
          template_sha256: str = "", min_interval_hours: float = 0) -> dict[str, Any]:
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
        if campaign == DECLINE_CAMPAIGN:
            # a decline names a credit a REVIEW ruled rejected at most: never one awaiting review, and never one a
            # review accepted. A credit with no review at all is allowed through (a human may have rejected it in
            # core), but a review that says otherwise always wins.
            for rid in request_ids:
                rv = db.execute("SELECT outcome FROM verify_proof_reviews WHERE request_id=? LIMIT 1",
                                (rid,)).fetchone()
                if rv is not None and str(rv["outcome"]) != "rejected":
                    blocked.add(rid)
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
        if campaign in (DECLINE_CAMPAIGN, PROOF_REFUSAL) and enforce_cap:
            # proof-refusal keeps the same cooldown (firstmate 2026-11-15: a refusal never lands inside 7 days of
            # another note from this gate, an ask included; the person waits and is offered again)
            why = decline_user_done(db, user_key, day=day, user_id=user_id)
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
        if campaign == UVN_REMINDER and enforce_cap:
            # inside this transaction (the peek and the audience builder read the same function)
            # "today" is the day this claim counts on (the caller's UTC day), so the 14-day and 7-day windows and
            # the per-day cap read ONE clock
            why = reminder14_user_done(db, user_key, now=_day_start(day) or now, user_id=user_id)
            if why in REMINDER_DEFER_REASONS:
                db.execute("COMMIT")
                return {"result": "recent", "reason": why, "request_ids": fresh}
            if why == "no_prior_ask":                # never closed: a first ask may still go, and be followed up
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
        if min_interval_hours and enforce_cap:
            # A rolling interval, checked INSIDE this transaction: the per-day cap reads one day, so a reply claimed
            # at 23:59:45 whose POST lands at 00:00:02 is recorded on yesterday and a second message today would pass
            # it. A caller's own precheck cannot close this - two runs can both pass it before either claims (QA
            # 2026-11-15). Measured from the row's created_at, so a late POST still holds the next day.
            since = stamp((now or utcnow()) - timedelta(hours=float(min_interval_hours)))
            cond, params = _same_user(db, user_key, user_id)
            if db.execute(f"SELECT 1 FROM verify_messages m WHERE {cond} AND m.status IN ('attempted','sent') "
                          "AND m.created_at >= ? LIMIT 1", (*params, since)).fetchone():
                db.execute("COMMIT")
                return {"result": "recent", "reason": f"min_interval:{min_interval_hours}h", "request_ids": fresh}
        if campaign == "verify-live" and enforce_cap and asked_within(db, user_key=user_key, day=day, user_id=user_id):
            # One note per user per 90 days across the ask campaigns: the credits wait
            # (nothing is closed) until the lock lapses or a human acts.
            db.execute("COMMIT")
            return {"result": "recently_asked", "request_ids": fresh}
        keep = [r for r in (refs or []) if str(r.get("request_id")) in set(fresh)]
        due, removal = window(day) if windowed else (None, None)
        if campaign == CLAIM_CAMPAIGN:
            due = claim_close_day(day)
        if campaign == DECLINE_CAMPAIGN:
            parent = _decline_family(db, fresh)
        elif campaign == UVN_REMINDER:
            # the ask this reminder follows, recorded so already_sent closes THIS ask and no other
            followed = reminder14_ask(db, user_key, user_id)
            parent = int(followed["id"]) if followed is not None else None
        else:
            parent = None
        cur = db.execute(
            "INSERT INTO verify_messages (campaign, kind, parent_row, user_key, account_id, day, due_day, removal_day, "
            "status, message_type, contact_id, request_ids_json, refs_json, n_credits, approved_by, approval_ref, "
            "created_at, updated_at, approver_kind, approval_id, template_sha256) "
            "VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
            (campaign, "initial", parent, user_key, str(user_id or "").strip() or None, day, due, removal, "attempted",
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


def record_external_ask(db: sqlite3.Connection, *, user_key: str, user_id: str = "", day: str,
                        request_ids: list[str], approved_by: str, approval_ref: str,
                        now: datetime | None = None, message_type: str = "inapp") -> dict[str, Any]:
    """Ledger an ask ANOTHER sender has already sent, so the shared per-user locks see it.

    The credit decider's support write (unverified -> user_verification_needed) is an ask whose note
    comes from core (Knock): no hydra sender posts it, and until this row exists no gate here knows the
    user was asked. One sender per family (Fable d2 [key=decider-support-arm]) means the tick's own
    campaigns must find this row and stand down, so it is written with the campaign that names the
    sender (DECIDER_SUPPORT) in the same transaction as its per-request rows.

    Deliberately NOT routed through claim(): nothing is claimed or reserved here (the send already
    happened) and no cap is re-checked (a row per user per run is the caller's business). Returns
    ``{"result": "recorded", "message_row", "request_ids"}``.
    """
    _check(DECIDER_SUPPORT)
    key = (user_key or "").strip().lower()
    uid = str(user_id or "").strip()
    if not (key or uid):
        raise ValueError("record_external_ask needs a user_key or a user_id: an ask nobody can be matched to")
    ids = [str(r) for r in dict.fromkeys(request_ids) if str(r or "").strip()]
    if not ids:
        raise ValueError("record_external_ask needs at least one request id")
    ts = stamp(now)
    db.execute("BEGIN IMMEDIATE")
    try:
        cur = db.execute(
            "INSERT INTO verify_messages (campaign, kind, user_key, account_id, day, status, message_type, "
            "request_ids_json, n_credits, approved_by, approval_ref, created_at, updated_at, sent_at) "
            "VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
            (DECIDER_SUPPORT, "initial", key or uid, uid or None, day, "sent", message_type,
             json.dumps(ids), len(ids), approved_by, approval_ref, ts, ts, ts))
        row = int(cur.lastrowid)
        for rid in ids:
            db.execute(
                "INSERT INTO verify_requests (campaign, request_id, message_row, status, attempts, updated_at) "
                "VALUES (?,?,?,?,?,?) ON CONFLICT(campaign, request_id) DO UPDATE SET "
                "message_row=excluded.message_row, status='sent', attempts=verify_requests.attempts+1, "
                "updated_at=excluded.updated_at",
                (DECIDER_SUPPORT, rid, row, "sent", 1, ts))
        db.execute("COMMIT")
        return {"result": "recorded", "message_row": row, "request_ids": ids}
    except Exception:
        db.execute("ROLLBACK")
        raise


def reminder_state(db: sqlite3.Connection, *, parent_message_id: str, kind: str, day: str) -> dict[str, Any]:
    """Whether follow-up `kind` of the note `parent_message_id` may be sent on `day`.
    result: due | not_due | done | proof_received | not_applicable | no_parent.
      windowed note (removal date): day 14 and day 25, none after the window ends, and only
      for credits no review has ruled on (a rejected credit is told by the reason-free `decline`
      campaign, which is its own message, never a follow-up of this note);
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


def _declined(db: sqlite3.Connection, user_key: str = "", user_id: str = "") -> dict[str, sqlite3.Row]:
    """request_id -> the latest `decline` row that names it: SENT ones only (the user has actually
    been told). A claim that is in flight or was refused tells nobody, so the credit stays held
    (HELD_NOT_TOLD) - never removed before its owner heard from us. Keyed across every note of
    the user, because a decline is not a follow-up of the windowed note: it is its own message.
    """
    out: dict[str, sqlite3.Row] = {}
    cond, params = _same_user(db, user_key, user_id) if (user_key or str(user_id or "").strip()) else ("1=1", ())
    for r in db.execute(f"SELECT m.* FROM verify_messages m WHERE m.campaign=? AND {cond} AND m.status='sent' ORDER BY m.id",
                        (DECLINE_CAMPAIGN, *params)).fetchall():
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
        attempts = 1 + max([int(p["attempts"]) for p in priors[:1]] or [0])
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
             reason: str = "", body_sha256: str = "", api_log: str = "", now: datetime | None = None,
             copy_verdict_id: str = "", copy_verdict_sha256: str = "", copy_review: str = "") -> None:
    if status not in ("sent", "rejected", "refused", "attempted"):
        raise ValueError(f"bad status {status!r}")
    if copy_review and not COPY_REVIEW_RE.match(copy_review):
        raise ValueError(f"copy review {copy_review!r} is not `approved` or `observed:<state>`")
    if copy_review == "approved" and not (copy_verdict_id and copy_verdict_sha256):
        raise ValueError("an approved copy review names its verdict id and sha256")
    if copy_verdict_id and not COPY_VERDICT_ID_RE.match(copy_verdict_id):
        raise ValueError(f"copy verdict id {copy_verdict_id!r} is not an ocv-<16 hex> id")
    if copy_verdict_sha256 and not TEMPLATE_SHA_RE.match(copy_verdict_sha256):
        raise ValueError("copy verdict sha256 is not a sha256 hex digest")
    ts = stamp(now)
    db.execute("BEGIN IMMEDIATE")
    try:
        db.execute(
            "UPDATE verify_messages SET status=?, message_id=COALESCE(NULLIF(?,''),message_id), "
            "conversation_id=COALESCE(NULLIF(?,''),conversation_id), reason=COALESCE(NULLIF(?,''),reason), "
            "body_sha256=COALESCE(NULLIF(?,''),body_sha256), api_log=COALESCE(NULLIF(?,''),api_log), updated_at=?, "
            "sent_at=CASE WHEN ?='sent' THEN COALESCE(sent_at, ?) ELSE sent_at END, "
            "copy_verdict_id=COALESCE(NULLIF(?,''),copy_verdict_id), "
            "copy_verdict_sha256=COALESCE(NULLIF(?,''),copy_verdict_sha256), "
            "copy_review=COALESCE(NULLIF(?,''),copy_review) "
            "WHERE id=?", (status, message_id, conversation_id, reason[:500], body_sha256, api_log, ts, status, ts,
                           copy_verdict_id, copy_verdict_sha256, copy_review, message_row))
        db.execute("UPDATE verify_requests SET status=?, updated_at=? WHERE message_row=?", (status, ts, message_row))
        db.execute("COMMIT")
    except Exception:
        db.execute("ROLLBACK")
        raise


COPY_VERDICT_ID_RE = re.compile(r"^ocv-[0-9a-f]{16}$")
# approved = a signed approval on the exact bytes. observed:<state> = the campaign was in the gate's observe mode, the
# note left WITHOUT an approval, and <state> is what the review said (pending, rewrite, verdict_invalid).
COPY_REVIEW_RE = re.compile(r"^(approved|observed:[a-z_]{1,40})$")
COPY_HOLD_PREFIX = "copy_review"


def hold_copy_review(db: sqlite3.Connection, *, message_row: int, reason: str, body_sha256: str = "",
                     now: datetime | None = None) -> dict[str, Any]:
    """The outbound copy gate did not approve the body this claim rendered, so NOTHING was posted: give the claim
    back (`give_back_claim`), carrying the reason and the body's hash."""
    if not reason.startswith(COPY_HOLD_PREFIX):
        raise ValueError(f"a copy-review hold reason starts with {COPY_HOLD_PREFIX!r}: {reason!r}")
    return give_back_claim(db, message_row=message_row, reason=reason, body_sha256=body_sha256, now=now)


def give_back_claim(db: sqlite3.Connection, *, message_row: int, reason: str, body_sha256: str = "",
                    now: datetime | None = None) -> dict[str, Any]:
    """Give a never-posted claim back: the row becomes a `deferred` LOG (never a lock: no cap, no idempotency, no
    7-day gate, not a refusal) that carries the reason, and its requests return to what they were before the claim,
    so the note is offered again next run. A caller that is not the copy gate says so in its own words; the guard
    that matters is that nothing was posted. Refuses any row that is not a never-posted `attempted` claim: a
    give-back can never un-send a message. One log row per user, campaign, day and reason; a repeat the same day
    drops the fresh claim instead of adding a second identical line."""
    if body_sha256 and not TEMPLATE_SHA_RE.match(body_sha256):
        raise ValueError("body sha256 is not a sha256 hex digest")
    ts = stamp(now)
    full = (reason + (f" body={body_sha256}" if body_sha256 else ""))[:500]
    db.execute("BEGIN IMMEDIATE")
    try:
        row = db.execute("SELECT id, campaign, kind, user_key, account_id, day, status, message_id FROM verify_messages "
                         "WHERE id=?", (message_row,)).fetchone()
        if row is None or row["status"] != "attempted" or row["message_id"]:
            db.execute("ROLLBACK")
            raise ValueError(f"row {message_row} is not a never-posted claim; a give-back cannot touch it")
        # the claim's own request rows: a first attempt is removed, a retry goes back to the rejected attempt it was
        db.execute("DELETE FROM verify_requests WHERE message_row=? AND status='attempted' AND attempts<=1",
                   (message_row,))
        db.execute("UPDATE verify_requests SET status='rejected', attempts=attempts-1, updated_at=? "
                   "WHERE message_row=? AND status='attempted'", (ts, message_row))
        dup = db.execute(
            "SELECT id FROM verify_messages WHERE id<>? AND campaign=? AND kind=? AND user_key=? AND day=? "
            "AND status='deferred' AND reason=? LIMIT 1",
            (message_row, row["campaign"], row["kind"], row["user_key"], row["day"], full)).fetchone()
        if dup is not None:
            db.execute("DELETE FROM verify_messages WHERE id=?", (message_row,))
            db.execute("UPDATE verify_messages SET updated_at=? WHERE id=?", (ts, dup["id"]))
            db.execute("COMMIT")
            return {"result": "held", "message_row": int(dup["id"]), "repeat": True}
        db.execute("UPDATE verify_messages SET status='deferred', reason=?, body_sha256=COALESCE(NULLIF(?,''),body_sha256), "
                   "attempts=MAX(COALESCE(attempts,1)-1,0), updated_at=? WHERE id=?",
                   (full, body_sha256, ts, message_row))
        db.execute("COMMIT")
        return {"result": "held", "message_row": message_row, "repeat": False}
    except sqlite3.Error:
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


def record_read_failure(db: sqlite3.Connection, *, campaign: str, user_key: str, reason: str,
                        user_id: str = "", now: datetime | None = None) -> dict[str, Any]:
    """Fable 769: ONE user's send-time read failed. Hold that user only until the NEXT TICK
    (``READ_RETRY_H``, not RECHECK_DAYS), count it as a consecutive failure, and report whether this is the
    third in a row (which pages a human).

    Deliberately NOT ``record_refusal``/``recheck_refusal``: an unreadable read is not the user refusing
    anything, and a 7-day refusal hold would starve the account for a week over one bad query.
    """
    now = now or utcnow()
    ts = stamp(now)
    retry_at = stamp((now + timedelta(hours=READ_RETRY_H)))
    db.execute("BEGIN IMMEDIATE")
    try:
        old = db.execute("SELECT failures, next_retry_at, first_failed_at FROM verify_read_failures "
                         "WHERE campaign=? AND user_key=?", (campaign, user_key)).fetchone()
        if old is None:
            failures, first, nxt = 1, ts, retry_at
        elif str(old["next_retry_at"]) > ts:
            # Still inside the SAME hold: the same tick failing again is one failure, not two - and it must
            # not push the retry horizon out, or two failures a minute apart would look like one forever.
            failures, first, nxt = int(old["failures"]), str(old["first_failed_at"]), str(old["next_retry_at"])
        else:
            nxt = retry_at
            # A new tick failed the same read again: consecutive, so the count carries on.
            failures, first = int(old["failures"]) + 1, str(old["first_failed_at"])
        db.execute(
            "INSERT INTO verify_read_failures (campaign, user_key, user_id, failures, reason, next_retry_at, "
            "first_failed_at, updated_at) VALUES (?,?,?,?,?,?,?,?) ON CONFLICT(campaign, user_key) DO UPDATE SET "
            "failures=excluded.failures, reason=excluded.reason, next_retry_at=excluded.next_retry_at, "
            "first_failed_at=excluded.first_failed_at, updated_at=excluded.updated_at, "
            "user_id=COALESCE(excluded.user_id, verify_read_failures.user_id)",
            (campaign, user_key, user_id or None, failures, reason[:500], nxt, first, ts))
        db.execute("COMMIT")
    except Exception:
        db.execute("ROLLBACK")
        raise
    return {"failures": failures, "next_retry_at": nxt, "first_failed_at": first,
            "page": failures >= READ_FAILURES_TO_PAGE}


def read_failure(db: sqlite3.Connection, *, campaign: str, user_key: str,
                 now: datetime | None = None) -> dict[str, Any]:
    """This user's open read-failure hold: {} when there is none or its retry time has passed."""
    row = db.execute("SELECT failures, reason, next_retry_at, updated_at FROM verify_read_failures "
                     "WHERE campaign=? AND user_key=?", (campaign, user_key)).fetchone()
    if row is None or str(row["next_retry_at"]) <= stamp(now):
        return {}
    return {"failures": int(row["failures"]), "reason": str(row["reason"] or ""),
            "next_retry_at": str(row["next_retry_at"])}


def mark_read_failure_paged(db: sqlite3.Connection, *, campaign: str, user_key: str,
                            now: datetime | None = None) -> bool:
    """Set paged_at once, so a standing failure pages on the tick it crosses the line and not every tick."""
    cur = db.execute("UPDATE verify_read_failures SET paged_at=?, updated_at=? WHERE campaign=? AND user_key=? "
                     "AND paged_at IS NULL", (stamp(now), stamp(now), campaign, user_key))
    return cur.rowcount > 0


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
# A note exists but cannot be tied to THIS credit (QA #1718 round 7, 2026-11-06): no store we can read carries a
# request id, so a user-level count cannot prove this credit was one of the ones core told. Distinct from
# HELD_NOT_TOLD on purpose - "we saw a note but cannot attribute it" and "we saw no note" are different facts, and
# the human picking this up needs the right one.
HELD_NOT_ATTRIBUTABLE = ("document rejected: core's decline route is on and the send ledger shows a note for this "
                         "user, but a send.messages row carries no request id, so we cannot prove THIS credit was "
                         "told; a person decides")


def _past_removal_day(db: sqlite3.Connection, day: str, *,
                      core_told: Callable[[str, str, list[str], str], dict[str, bool] | None] | None = None
                      ) -> list[tuple[dict[str, Any], bool]]:
    """(row, held) per credit on a windowed note whose removal day has come and that no
    accepted document cleared. Held for a human (never removed by the export): a credit
    whose document awaits review, one whose user replied (extension_requested_at) and no
    review has ruled on, a rejected one whose user has NOT been told the reason-free decline
    yet, and a rejected one whose user replied after that decline and no review has ruled on
    since. A declined credit is removal-due from the note's own removal day once the decline
    went out; the decline itself never names a date.

    WHO TOLD THEM (QA #1718, 2026-11-06): with core's own `credits_rejected` email routed, the telling is CORE's
    message and hydra writes no `decline` row at all - so a decision that reads only hydra's ledger holds every
    rejected credit forever. `core_told(user_key, user_id, request_ids, since)` answers for core: a dict of the credits core
    told them about, or None when that cannot be established (which holds, never releases). No reader supplied means
    hydra's own sent decline is the only telling, which is the pre-existing behaviour."""
    out: list[tuple[dict[str, Any], bool]] = []
    rows = db.execute("SELECT * FROM verify_messages WHERE kind='initial' AND status='sent' "
                      "AND removal_day IS NOT NULL AND removal_day <= ? ORDER BY id", (day,)).fetchall()
    for r in rows:
        reviews = {str(x["request_id"]): x for x in
                   db.execute("SELECT * FROM verify_proof_reviews WHERE family=?", (r["id"],)).fetchall()}
        told = _declined(db, str(r["user_key"]), str(r["account_id"] or ""))
        rejected_ids = [str(ref.get("request_id")) for ref in _refs(r)
                        if str(ref.get("request_id")) in reviews and reviews[str(ref.get("request_id"))]["outcome"] == "rejected"]
        by_core: dict[str, bool] | None = {}
        if core_told and rejected_ids:
            # the close boundary: core's email is emitted on the `rejected` transition, so a delivery for this user
            # can only be at or after the earliest of these reviews
            closed_at = min(str(reviews[rid]["reviewed_at"]) for rid in rejected_ids)
            by_core = core_told(str(r["user_key"]), str(r["account_id"] or ""), rejected_ids, closed_at)
        for ref in _refs(r):
            rid = str(ref.get("request_id"))
            review = reviews.get(rid)
            outcome = review["outcome"] if review is not None else None
            # a reply may land in the original thread or in the user's decline of that very credit
            replied = db.execute(
                "SELECT MAX(last_reply_at) FROM verify_messages m2 WHERE (m2.id=? OR m2.parent_row=?) "
                "OR (m2.campaign=? AND EXISTS (SELECT 1 FROM json_each(m2.request_ids_json) j WHERE j.value=?))",
                (r["id"], r["id"], DECLINE_CAMPAIGN, rid)).fetchone()[0]
            # a document may arrive in reply to the ORIGINAL note or to the user's decline of this credit (the decline is
            # its own message, not a follow-up: it names the request ids, which is how the two are tied together).
            proof_at = db.execute(
                "SELECT MAX(proof_tagged_at) FROM verify_messages m2 WHERE (m2.id=? OR m2.parent_row=?) "
                "OR (m2.campaign=? AND EXISTS (SELECT 1 FROM json_each(m2.request_ids_json) j WHERE j.value=?))",
                (r["id"], r["id"], DECLINE_CAMPAIGN, rid)).fetchone()[0]
            removal = str(r["removal_day"])
            reason = "no valid verification within 30 days"
            if outcome == "accepted":
                continue
            if outcome == "rejected":
                note = told.get(rid)
                # core's email is emitted on the `rejected` transition, so the review time is when they were told
                told_at = str(note["created_at"]) if note is not None else (
                    str(review["reviewed_at"]) if by_core and by_core.get(rid) is True else None)
                if proof_at and str(proof_at) > str(review["reviewed_at"]):
                    # a document arrived AFTER this review: the decline says the person can resubmit ("You can
                    # resubmit for the credit again later"), and this is that resubmission, so the credit is held for
                    # that review, never removed on the strength of the earlier one.
                    reason = HELD_AWAITING_REVIEW
                elif told_at is None:
                    # `rid in by_core` with a False value means core's route is on and a note exists, but it cannot be
                    # attributed to this request; absent means no note at all was found.
                    reason = HELD_NOT_ATTRIBUTABLE if (by_core and rid in by_core) else HELD_NOT_TOLD
                elif replied and replied > told_at and replied > str(review["reviewed_at"]):
                    reason = HELD_REPLIED
                else:
                    # the decline names no date (no deadline in the copy by design): the note's own
                    # removal day governs, and only once the user has actually been told.
                    if removal > day:
                        continue
                    reason = "the document sent did not verify it, and nothing else came by the date we named"
            elif r["proof_tagged_at"]:
                reason = HELD_AWAITING_REVIEW
            elif r["extension_requested_at"] is not None:
                reason = HELD_REPLIED
            held = reason in (HELD_AWAITING_REVIEW, HELD_REPLIED, HELD_NOT_TOLD, HELD_NOT_ATTRIBUTABLE)
            out.append(({"request_id": rid, "profile_id": ref.get("profile_id") or None,
                         "track_id": ref.get("track_id") or None, "campaign": r["campaign"],
                         "message_id": r["message_id"], "noted_day": r["day"], "due_day": r["due_day"],
                         "removal_day": removal, "reason": reason}, held))
    return out


def removal_due(db: sqlite3.Connection, *, day: str,
                core_told: Callable[[str, str, list[str], str], dict[str, bool] | None] | None = None
                ) -> list[dict[str, Any]]:
    """Credits that may be removed on `day`: ONLY credits whose note named a reply-by
    date (windowed notes for NEW provisional approvals; captain 23:40Z "if no valid
    verification comes it should be removed", narrowed 00:35Z to new credits), from the
    day after it, with no valid document. Past (retro-past) credits are never here. Per
    credit: an accepted document clears it; a document awaiting review holds it; a rejected
    one puts it back once the reason-free decline went out. A note the user replied to is held
    for a human (held_for_human) until a review rules on the credit. The remover must still
    re-check each credit (confirmed meanwhile -> never removed)."""
    return [row for row, held in _past_removal_day(db, day, core_told=core_told) if not held]


def held_for_human(db: sqlite3.Connection, *, day: str,
                   core_told: Callable[[str, str, list[str], str], dict[str, bool] | None] | None = None
                   ) -> list[dict[str, Any]]:
    """Credits past their removal day that the export never removes, each with why: a
    document awaits review, the user replied to the note (text or attachment), or a
    rejection the user has not been told about yet. A human picks them up."""
    return [row for row, held in _past_removal_day(db, day, core_told=core_told) if held]


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
    whose user replied after the reason-free decline, until a review rules on it again.
    recorded | already | not_applicable | no_message."""
    if replied_at and not re.fullmatch(r"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ", replied_at):
        raise ValueError("replied_at must be UTC YYYY-MM-DDTHH:MM:SSZ")
    root = _family(db, message_id)
    if root is None:
        return "no_message"
    note = db.execute("SELECT removal_day, campaign FROM verify_messages WHERE id=?", (root,)).fetchone()
    # a decline names no date, but a reply to it still matters: it is the user answering the decline, and the
    # credit it names must stop being removal-due until a human reads that reply.
    if note is None or (note["removal_day"] is None
                        and note["campaign"] not in (CLAIM_CAMPAIGN, DECLINE_CAMPAIGN)):
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


def _note_of(db: sqlite3.Connection, request_id: str) -> int | None:
    """The note an id was asked about: a CREDIT's own family, whatever row it is read from. A decline
    can cover credits of SEVERAL notes (a user whose credits were rejected on two of them), so the
    family of a review, a re-tag or a rejected verdict is the credit's note — never the first note the
    declining row happens to name (QA #1718 2: a single parent_row cannot represent several families)."""
    row = db.execute(
        "SELECT MIN(id) AS id FROM verify_messages WHERE kind='initial' AND parent_row IS NULL "
        "AND EXISTS (SELECT 1 FROM json_each(request_ids_json) j WHERE j.value=?)", (str(request_id),)).fetchone()
    return int(row["id"]) if row is not None and row["id"] is not None else None


def note_index(db: sqlite3.Connection) -> dict[str, int]:
    """`_note_of` for every request id at once: {request id: its note}, in one pass over the initial notes. For a
    caller that asks about every credit of many rows (the proof marker), where one `_note_of` per id is a scan of
    the table each. A test holds the two to the same answer."""
    out: dict[str, int] = {}
    for r in db.execute("SELECT id, request_ids_json FROM verify_messages WHERE kind='initial' AND parent_row IS NULL "
                        "ORDER BY id"):
        try:
            ids = json.loads(r[1] or "[]")
        except ValueError:
            continue                      # json_each raises on these rows; no id can be read from them
        for rid in ids if isinstance(ids, list) else []:
            if isinstance(rid, str):      # json_each's value equals a text parameter only for a JSON string
                out.setdefault(rid, int(r[0]))
    return out


def proof_families(db: sqlite3.Connection, root: int, request_ids_json: str | None,
                   note_of: Callable[[str], int | None] | None = None) -> set[int]:
    """The families a new document on a row re-opens: the row's own family and the note of EVERY credit the row
    covers. A decline (and any later note) names credits first asked about on other notes, and a credit's rejected
    verdict lives under its own note (`_note_of`), so the row's first note alone misses them (QA #1718 2). The ONE
    place this set is built: `mark_tagged` and the proof marker both call it. `note_of` defaults to `_note_of`;
    the marker passes `note_index(db).get`."""
    find = note_of or (lambda rid: _note_of(db, rid))
    fams = {int(root)}
    for rid in json.loads(request_ids_json or "[]"):
        fams.add(find(str(rid)) or int(root))
    return fams


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
            # the fresh review starts from nothing for EVERY credit this row covered: a decline can name
            # credits of several notes, so its rejected verdicts live under each credit's own family
            row = db.execute("SELECT request_ids_json FROM verify_messages WHERE message_id=?", (message_id,)).fetchone()
            for fam in proof_families(db, root, row["request_ids_json"] if row is not None else None):
                db.execute("DELETE FROM verify_proof_reviews WHERE family=? AND outcome='rejected'", (fam,))
        db.execute("COMMIT")
    except Exception:
        db.execute("ROLLBACK")
        raise


def settle_proof_tags(db: sqlite3.Connection, *, root: int, covered: list[str],
                      now: datetime | None = None) -> None:
    """Return a family to "no proof" once every credit its own notes name is reviewed and any was rejected.

    Called ONCE after every verdict for a note is written, so which credit is written first cannot decide
    whether another credit's verdict is accepted or refused. The census is read from the family's rows, not
    from the caller's list, so a credit of the family the caller never looked at still holds the tag."""
    ts = stamp(now)
    for fam in sorted({_note_of(db, rid) or int(root) for rid in covered}):
        reviews = _reviews(db, fam)
        named = {x for r in db.execute("SELECT request_ids_json FROM verify_messages WHERE id=? OR parent_row=?",
                                       (fam, fam)).fetchall() for x in _ids_of(r["request_ids_json"])}
        fam_ids = [x for x in sorted(named) if (_note_of(db, x) or fam) == fam]
        if fam_ids and all(x in reviews for x in fam_ids) and any(reviews[x] == "rejected" for x in fam_ids):
            db.execute("UPDATE verify_messages SET proof_tagged_at=NULL, updated_at=? WHERE id=? OR parent_row=?",
                       (ts, fam, fam))


def record_proof_review(db: sqlite3.Connection, *, message_id: str, request_ids: list[str], outcome: str,
                        reviewer: str, reason: str = "", now: datetime | None = None,
                        message_row: int | None = None, settle: bool = True,
                        transaction: bool = True) -> dict[str, Any]:
    """The document review's verdict, PER CREDIT, on a note with a tagged proof or a user
    reply (Fable review of hydra#1239, F2; firstmate decision on review finding
    proof-review-is-all-or-nothing-per-note):
    accepted  these credits are verified; never removal-due;
    rejected  these credits are not verified. When a document (attachment) was received on
              the note, `reason` (one of REJECTION_REASONS) is required and stays INTERNAL:
              it rides on this row and the audit file only, and no user-facing copy ever
              shows it (the decline says the information was not enough, nothing more).
              They are removal-due once the reason-free decline went out.
    Credits on the note not reviewed yet stay held while the proof awaits review. Once every
    credit on the note is reviewed and any was rejected, the note returns to "no proof" (the
    sweep watches for a NEW attachment beyond the ones already reviewed). A reviewed credit
    never gets a day-14 / day-25 reminder. `message_row` names the reviewed row by its ledger
    id, for a note that carries no Intercom message id; `settle=False` leaves the "no proof"
    reset to the caller, for one writing several verdicts for the same note. `transaction=False`
    is for a caller that already holds a BEGIN IMMEDIATE and writes its own rows with the verdict:
    this function then begins, commits and rolls back nothing, so the caller's commit lands the
    verdict and those rows together or not at all."""
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
    root = _family(db, message_id) if message_row is None else None
    if message_row is not None:
        at = db.execute("SELECT id, parent_row FROM verify_messages WHERE id=?", (int(message_row),)).fetchone()
        root = int(at["parent_row"] or at["id"]) if at is not None else None
    if root is None:
        return {"result": "no_message"}
    ts = stamp(now)
    if transaction:
        db.execute("BEGIN IMMEDIATE")
    try:
        note = db.execute("SELECT * FROM verify_messages WHERE id=?", (root,)).fetchone()
        row = (db.execute("SELECT * FROM verify_messages WHERE id=?", (int(message_row),)).fetchone()
               if message_row is not None else
               db.execute("SELECT * FROM verify_messages WHERE message_id=? ORDER BY id DESC LIMIT 1",
                          (message_id,)).fetchone())
        # what the reviewed row itself covered (a decline names its own credits) plus the family note's
        # credits: a review may name any credit the thread it arrives on actually asked about
        covered = list(dict.fromkeys(
            [str(x) for x in json.loads(note["request_ids_json"] or "[]")]
            + [str(x) for x in json.loads((row["request_ids_json"] if row is not None else None) or "[]")]))
        fams = sorted({_note_of(db, rid) or root for rid in ids})
        stray = [x for x in ids if x not in covered]
        if stray:
            if transaction:
                db.execute("COMMIT")
            return {"result": "not_on_note", "request_ids": stray}
        # the threads a document or a reply can have arrived on: every reviewed credit's own family, the row's
        # family, and the row the review is recorded against (a decline is its own message, filed under one note)
        cand = sorted(set(fams) | {root, int(row["id"]) if row is not None else root})
        in_fams = ",".join("?" * len(cand))
        tagged = db.execute(f"SELECT 1 FROM verify_messages WHERE (id IN ({in_fams}) OR parent_row IN ({in_fams})) "
                            "AND proof_tagged_at IS NOT NULL LIMIT 1", (*cand, *cand)).fetchone()
        replied_to = note["extension_requested_at"] or db.execute(
            f"SELECT 1 FROM verify_messages WHERE (id IN ({in_fams}) OR parent_row IN ({in_fams})) "
            "AND extension_requested_at IS NOT NULL LIMIT 1", (*cand, *cand)).fetchone() is not None
        if tagged is None and not replied_to:
            if transaction:
                db.execute("COMMIT")
            return {"result": "not_tagged"}
        document = tagged is not None or db.execute(
            f"SELECT 1 FROM verify_messages WHERE (id IN ({in_fams}) OR parent_row IN ({in_fams})) "
            "AND proof_attachments > 0 LIMIT 1", (*cand, *cand)).fetchone() is not None
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
                       (_note_of(db, rid) or root, rid, outcome, reason or None, int(document), ts, reviewer))
        # the row returns to "no proof" PER FAMILY: once every credit of a family that this thread covered
        # is reviewed and any of them was rejected
        if settle:
            for fam in fams:
                reviews = _reviews(db, fam)
                fam_ids = [x for x in covered if (_note_of(db, x) or root) == fam]
                if fam_ids and all(x in reviews for x in fam_ids) and any(reviews[x] == "rejected" for x in fam_ids):
                    db.execute("UPDATE verify_messages SET proof_tagged_at=NULL, updated_at=? WHERE id=? OR parent_row=?",
                               (ts, fam, fam))
        if transaction:
            db.execute("COMMIT")
    except Exception:
        if transaction:
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
    # m.campaign, NOT f.campaign (QA #1718 round 9, 2026-11-06): `f` is the note family's parent, and a decline is
    # parented to the note whose credits it closed - which may be a `retro-past` note. Reading the family's campaign
    # made a decline look like a retro-past note, so a tagged decline reply was skipped and the fresh review the
    # decline promised never entered the sweep. A parent's own campaign equals its family's, and a follow-up row is
    # written with its parent's campaign (record_reminder), so the message's own campaign is the right question to
    # ask: "is THIS message a decline".
    rows = db.execute(
        "SELECT m.message_id, m.proof_tagged_at, f.removal_day, f.request_ids_json, m.campaign AS campaign, "
        "m.request_ids_json AS own_ids, f.id AS family "
        "FROM verify_messages m JOIN verify_messages f ON f.id = COALESCE(m.parent_row, m.id) "
        "WHERE m.status='sent' AND m.message_id IS NOT NULL AND EXISTS (SELECT 1 FROM verify_messages s "
        "WHERE (s.id=f.id OR s.parent_row=f.id) AND s.status='sent' AND s.created_at >= ?) "
        "ORDER BY m.proof_checked_at IS NOT NULL, m.proof_checked_at, m.id", (since,)).fetchall()
    out: list[str] = []
    for r in rows:
        if r["proof_tagged_at"]:
            if r["campaign"] == DECLINE_CAMPAIGN:
                # A decline is read whatever its parent note's date is: the user's new document is the restart the
                # decline offered ("You can resubmit for the credit again later"), never a dead thread.
                # And it names its OWN credits, which can come from SEVERAL note families (QA #1718, 2026-11-06):
                # reading the parent note's ids and the parent's reviews meant that once the FIRST credit was
                # accepted the whole decline was skipped, so a fresh document for the second credit was never
                # swept. Each id is judged against its own family, never the parent's.
                own = [str(x) for x in json.loads(r["own_ids"] or "[]")]
                if own and all(_reviews(db, _note_of(db, x) or int(r["family"])).get(x) == "accepted"
                               for x in own):
                    continue
            elif r["removal_day"] is None:
                continue
            else:
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
        if str(approved_by) == CAPTAIN_UID:
            # FAIL CLOSED on an unreadable timestamp: a value that does not parse is a finding, exactly like a missing
            # one. Comparing the strings would have exempted an epoch integer or a space-separated stamp, because both
            # sort before the cutover lexicographically (QA 2026-11-05 round 7 follow-up).
            made = stamp_ts(created_at)
            cutover = stamp_ts(STAMP_CUTOVER)
            if made is not None and cutover is not None and made < cutover:
                return ""
            if made is None:
                return (f"no approver stamp on a row whose created_at {created_at!r} cannot be read as "
                        f"{STAMP_TS_FORMAT} - an unreadable timestamp cannot prove the row predates the stamped gate "
                        f"({STAMP_CUTOVER}), so it is a finding")
            return (f"no approver stamp on a row created {created_at}, which is not before the stamped gate went live "
                    f"({STAMP_CUTOVER}) - an unstamped send after the cutover is a finding whoever approved_by names")
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
    elif kind == APPROVER_COPY_GATE:
        # The verdict id IS the approval. Its signature is verified by the copy gate when it is created (and again
        # by the writer, which asks the gate itself before its POST); checked here: the row names the verdict it
        # was authorized by, and it is the campaign the copy gate approves at all. The template hash below is
        # recomputed from campaign|kind|copy, so a row cannot claim one verdict and render another frame.
        if not COPY_VERDICT_ID_RE.match(str(approval_id)):
            return f"copy-gate approval id {approval_id!r} is not an ocv-<16 hex> verdict id"
        if str(approved_by) != str(approval_id):
            return f"the stamp names {approval_id} but approved_by is {approved_by}"
        if str(campaign) != AGENT_REPLY:
            return f"copy-gate authorized campaign {campaign!r}, which the copy gate does not approve"
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
                                   "touches no other table); scripts/deploy.sh runs it every deploy. At the "
                                   "production path it upgrades only: a ledger with no send record is refused")
    sub.add_parser("init", help="create an EMPTY send record in a path that has none. For a host that has truly "
                                 "never sent; a ledger that has one is untouched, and an existing file that holds "
                                 "other tables is refused. Logs who ran it to stderr")
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
    f.add_argument("--copy-verdict-id", default="")
    f.add_argument("--copy-verdict-sha256", default="")
    f.add_argument("--copy-review", default="")
    hc = sub.add_parser("hold-copy-review", help="give back a claim whose body the copy gate did not approve")
    hc.add_argument("--message-row", type=int, required=True)
    hc.add_argument("--reason", required=True)
    hc.add_argument("--body-sha256", default="")
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
    cs = sub.add_parser("close-since", help="when these credits were closed (the window a per-user decline read needs)")
    cs.add_argument("--request-ids", required=True)
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
    if a.op == "init":
        if a.readonly:
            print(json.dumps({"error": "init writes; it cannot run --readonly"}), file=sys.stderr)
            return 2
        try:
            out = init(a.db)
        except LedgerAbsentError as exc:
            print(json.dumps({"error": str(exc)}), file=sys.stderr)
            return 2
        who = os.environ.get("SUDO_USER") or os.environ.get("USER") or os.environ.get("LOGNAME") or "unknown"
        print(json.dumps(out))
        print(f"verify_ledger.py init: {out['result']} the send record at {out['path']} (by {who})",
              file=sys.stderr)
        return 0
    try:
        db = connect_ro(a.db) if a.readonly else connect(a.db)
    except (ReadOnlyLedgerError, LedgerAbsentError) as exc:
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
                 conversation_id=a.conversation_id, reason=a.reason, body_sha256=a.body_sha256, api_log=a.api_log,
                 copy_verdict_id=a.copy_verdict_id, copy_verdict_sha256=a.copy_verdict_sha256,
                 copy_review=a.copy_review)
        out = {"result": "ok"}
    elif a.op == "hold-copy-review":
        out = hold_copy_review(db, message_row=a.message_row, reason=a.reason, body_sha256=a.body_sha256)
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
        if a.user_key and a.campaign in (DECLINE_CAMPAIGN, PROOF_REFUSAL):
            why = decline_user_done(db, a.user_key, day=a.day or utcnow().strftime("%Y-%m-%d"), user_id=a.user_id)
            out["user_done"], out["recent"], out["recent_why"] = "", bool(why), why
        if a.campaign == UVN_NEW_ROWS:
            why = new_rows_user_done(db, a.user_key, user_id=a.user_id)
            out["prior_uvn_ask"] = why != "no_prior_ask"
            out["user_done"] = why if why == "proof_received" else ""
            out["recent"], out["recent_why"] = why == "messaged_7d", why if why == "messaged_7d" else ""
        if a.campaign == UVN_REMINDER:
            why = reminder14_user_done(db, a.user_key, now=_day_start(a.day), user_id=a.user_id)
            ask = reminder14_ask(db, a.user_key, a.user_id) or {}
            out["prior_uvn_ask"] = why != "no_prior_ask"
            out["asked_day"] = str(ask.get("day") or "") if why != "no_prior_ask" else ""
            out["user_done"] = "" if why in REMINDER_DEFER_REASONS or why == "no_prior_ask" else why
            out["recent"] = why in REMINDER_DEFER_REASONS
            out["recent_why"] = why if why in REMINDER_DEFER_REASONS else ""
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
    elif a.op == "close-since":
        out = close_since(db, _ids(a.request_ids))
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
