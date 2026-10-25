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
import json
import os
import re
import sqlite3
import sys
from datetime import date, datetime, timedelta, timezone
from pathlib import Path
from typing import Any

DEFAULT_PATH = os.environ.get("CREDIT_REVIEW_LEDGER", "/var/lib/hydra/credit-review/ledger.sqlite3")
MAX_ATTEMPTS = 3
BLOCKING = ("attempted", "sent", "refused", "skipped")
DEFERRED = "deferred_pending_doc"
CAMPAIGNS = ("verify-live", "retro-past", "removal-notice", "takeback-notice", "uvn-status", "withdrawal-confirm",
             "status-doc-received", "status-team-review", "email-changed", "email-changed-dup")
# Once-per-user status campaigns: one message per user ever (per campaign), never within 7 days
# of another note from this gate. Only uvn-status is an ask (and also stops after a proof reply).
STATUS_CAMPAIGNS = ("uvn-status", "status-doc-received", "status-team-review")
# Notices: only their own rows block them (they are not asks and never close one).
NOTICE_CAMPAIGNS = ("takeback-notice", "withdrawal-confirm", "status-doc-received", "status-team-review",
                    "email-changed", "email-changed-dup")
# Campaigns whose gate refusals are re-checkable (firstmate 076, 082, 083): a refusal holds the
# USER (campaign, user_key or user_id) in verify_refusal_holds for RECHECK_DAYS (the runner and the gate skip
# them until next_recheck_at, whatever requests are listed); a later send clears it; after
# MAX_REFUSALS refusals it is posted once to #cs_priority for a human and the user is blocked.
RECHECKABLE_REFUSALS = ("status-doc-received", "status-team-review", "email-changed", "email-changed-dup")
RECHECK_DAYS = 7
MAX_REFUSALS = 3
# The campaigns that ASK the user for something. Only these count as "already asked";
# notices and confirmations (removal-notice, takeback-notice, withdrawal-confirm) never close
# a user's asks (firstmate 063/064).
ASK_CAMPAIGNS = ("verify-live", "retro-past", "uvn-status")
AFTER_REJECTION = "after-rejection"
KINDS = ("initial", "reminder-14", "reminder-25", AFTER_REJECTION)
# Days after a WINDOWED note at which each reminder becomes due.
REMINDER_DAYS = {"reminder-14": 14, "reminder-25": 25}
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
  status TEXT NOT NULL,              -- attempted | sent | rejected | refused
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
  last_reply_at TEXT                 -- this message: time of the latest user reply seen in its conversation
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
"""
INDEXES = """
CREATE INDEX IF NOT EXISTS verify_messages_user_day ON verify_messages(user_key, day);
CREATE INDEX IF NOT EXISTS verify_messages_msg ON verify_messages(message_id);
CREATE INDEX IF NOT EXISTS verify_messages_parent ON verify_messages(parent_row, kind);
"""
TABLES = ("verify_messages", "verify_proof_reviews", "verify_requests", "verify_refusal_holds")
# The verify_messages columns credit-retro's take-back / wave reader depends on
# (credit_retro.waves.already_engaged). Pinned here, next to the writer's schema, and
# checked against it by scripts/tests/test_verify_ledger_contract.py.
READER_COLUMNS = frozenset({"request_ids_json", "proof_tagged_at", "user_key", "campaign", "status", "kind"})


def utcnow() -> datetime:
    return datetime.now(timezone.utc)


def stamp(now: datetime | None = None) -> str:
    return (now or utcnow()).strftime("%Y-%m-%dT%H:%M:%SZ")


def connect(path: str) -> sqlite3.Connection:
    if path != ":memory:":
        Path(path).parent.mkdir(parents=True, exist_ok=True)
    db = sqlite3.connect(path, timeout=30, isolation_level=None)
    db.row_factory = sqlite3.Row
    db.executescript(SCHEMA)
    _migrate(db)
    db.executescript(INDEXES)
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


def _plus(day: str, n: int) -> str:
    return (date.fromisoformat(day) + timedelta(days=n)).isoformat()


def window(day: str) -> tuple[str, str]:
    """(due_day, removal_day) of a windowed note sent on `day`. The note names ONE date
    (Fable copy review 2026-10-17): the reply-by date, 30 days after the note. A reply by
    the end of that (UTC) day is in time, so the credit is removal-due only from the next
    day, 00:00Z."""
    due = _plus(day, WINDOW_DAYS)
    return due, _plus(due, 1)


def blocked_ids(db: sqlite3.Connection, request_ids: list[str], campaign: str = "verify-live") -> set[str]:
    """Request ids that must not get this campaign's initial note: already noted,
    refused or skipped in this campaign, or already asked about in any ASK campaign
    (never re-ask the same credit, no repeats across waves). takeback-notice and
    withdrawal-confirm are not asks but notices about that very request, so only their own
    rows block them."""
    out: set[str] = set()
    asks = ",".join("?" * len(ASK_CAMPAIGNS))
    for rid in request_ids:
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
    proof (a credit-proof reply on any note, any campaign)."""
    cond, params = _same_user(db, user_key, user_id)
    asks = ",".join("?" * len(ASK_CAMPAIGNS))
    if db.execute(f"SELECT 1 FROM verify_messages m WHERE {cond} AND m.kind='initial' AND m.campaign IN ({asks}) "
                  "AND m.status IN ('attempted','sent') LIMIT 1", (*params, *ASK_CAMPAIGNS)).fetchone():
        return "already_asked"
    if db.execute(f"SELECT 1 FROM verify_messages m WHERE {cond} AND m.proof_tagged_at IS NOT NULL LIMIT 1",
                  params).fetchone():
        return "proof_received"
    return ""


def uvn_user_done(db: sqlite3.Connection, user_key: str, *, now: datetime | None = None,
                  campaign: str = "uvn-status", user_id: str = "") -> str:
    """A STATUS_CAMPAIGNS note: why this user must not get it ('' when they may). One per user,
    ever, per campaign; never within 7 days of any note from this gate (messaged_7d, a deferral);
    uvn-status (an ask) also never after a proof reply, and never within 90 days of an ask from
    any ask campaign (the shared one-ask lock: recently_asked, a deferral, nothing closed).
    "This user" is _same_user: an email change is the same user."""
    cond, params = _same_user(db, user_key, user_id)
    if db.execute(f"SELECT 1 FROM verify_messages m WHERE {cond} AND m.campaign=? AND m.kind='initial' "
                  "AND m.status IN ('attempted','sent') LIMIT 1", (*params, campaign)).fetchone():
        return "already_sent"
    if campaign == "uvn-status" and db.execute(
            f"SELECT 1 FROM verify_messages m WHERE {cond} AND m.proof_tagged_at IS NOT NULL LIMIT 1",
            params).fetchone():
        return "proof_received"
    since = ((now or utcnow()) - timedelta(days=7)).strftime("%Y-%m-%d")
    if db.execute(f"SELECT 1 FROM verify_messages m WHERE {cond} AND m.day>=? AND m.status IN ('attempted','sent') "
                  "LIMIT 1", (*params, since)).fetchone():
        return "messaged_7d"
    # uvn-status is an ask: the shared one-ask-per-user-per-90-days lock across the ask
    # campaigns applies (QA @59645fb; doc rule 'One ask per user per 90 days'). A deferral,
    # like messaged_7d: nothing is closed, the user is offered again once the lock lapses.
    if campaign == "uvn-status" and asked_within(db, user_key=user_key,
                                                 day=(now or utcnow()).strftime("%Y-%m-%d"), user_id=user_id):
        return "recently_asked"
    return ""


# uvn_user_done reasons that only DEFER the user (nothing closed, offered again later).
DEFER_REASONS = ("messaged_7d", "recently_asked")


def claim(db: sqlite3.Connection, *, user_key: str, day: str, request_ids: list[str], message_type: str,
          approved_by: str, approval_ref: str, contact_id: str = "", campaign: str = "verify-live",
          refs: list[dict[str, Any]] | None = None, windowed: bool = False, now: datetime | None = None,
          enforce_cap: bool = True, user_id: str = "") -> dict[str, Any]:
    """Atomically claim an initial note. One transaction (BEGIN IMMEDIATE) so two
    concurrent runs cannot both claim the same user-day or request id."""
    _check(campaign)
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
        hold = refusal_hold(db, campaign, user_key, now, user_id) if enforce_cap else {}
        if hold:
            db.execute("COMMIT")
            return {"result": "refusal_hold", "request_ids": fresh, **hold}
        if campaign in STATUS_CAMPAIGNS and enforce_cap:
            why = uvn_user_done(db, user_key, now=now, campaign=campaign, user_id=user_id)
            if why in DEFER_REASONS:
                db.execute("COMMIT")
                return {"result": "recent", "reason": why, "request_ids": fresh}
            if why:
                _skip(db, campaign, fresh, ts)
                db.execute("COMMIT")
                return {"result": "user_done", "reason": why, "request_ids": fresh}
        if campaign == "retro-past" and enforce_cap:
            why = past_user_done(db, user_key, user_id)
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
        cur = db.execute(
            "INSERT INTO verify_messages (campaign, kind, user_key, account_id, day, due_day, removal_day, status, "
            "message_type, contact_id, request_ids_json, refs_json, n_credits, approved_by, approval_ref, created_at, "
            "updated_at) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
            (campaign, "initial", user_key, str(user_id or "").strip() or None, day, due, removal, "attempted",
             message_type, contact_id or None,
             json.dumps(fresh), json.dumps(keep) if keep else None, len(fresh), approved_by, approval_ref, ts, ts))
        row = int(cur.lastrowid)
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
    if not info["windowed"]:
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
    more, so reminders_due stops offering it. Only a due follow-up is closed; no message
    is sent and the daily cap is untouched. True when a row was written."""
    ts = stamp(now)
    db.execute("BEGIN IMMEDIATE")
    try:
        st = reminder_state(db, parent_message_id=parent_message_id, kind=kind, day=day)
        if st["result"] != "due":
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
                   now: datetime | None = None) -> dict[str, Any]:
    """Atomically claim follow-up `kind` of a sent note. The listed credits must be
    a subset of the note's credits; the user must be the note's user."""
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
            "created_at, updated_at) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
            (st["campaign"], kind, st["parent_row"], user_key, st.get("account_id"), day, st["due_day"],
             st["removal_day"], "attempted",
             st["message_type"], st["contact_id"], json.dumps(keep), len(keep), approved_by, approval_ref, attempts,
             ts, ts))
        db.execute("COMMIT")
        return {**st, "result": "claimed", "message_row": int(cur.lastrowid), "request_ids": keep}
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
    """The user replied to a windowed note or one of its follow-ups (any reply: the gate
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
    note = db.execute("SELECT removal_day FROM verify_messages WHERE id=?", (root,)).fetchone()
    if note is None or note["removal_day"] is None:
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
    `days`: every one not yet tagged credit-proof, and a tagged one too while its windowed
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
    first, at most one per note: the after-rejection note first (it may be due while other
    credits on the note still await review), else a reminder. When both reminders are due
    (day 25 came before day 14 went out) only the later one is offered: two reminders a few
    days apart add nothing."""
    out: list[tuple[str, str, list[dict[str, Any]]]] = []
    rows = db.execute("SELECT * FROM verify_messages WHERE campaign=? AND kind='initial' AND status='sent' "
                      "AND removal_day IS NOT NULL AND message_id IS NOT NULL ORDER BY id", (campaign,)).fetchall()
    for r in rows:
        for kind in (AFTER_REJECTION, "reminder-25", "reminder-14"):
            st = reminder_state(db, parent_message_id=str(r["message_id"]), kind=kind, day=day)
            if st["result"] == "due":
                keep = set(st["request_ids"])
                out.append((str(r["message_id"]), kind, [ref for ref in _refs(r) if str(ref.get("request_id")) in keep]))
                break
            if kind == "reminder-25" and st["result"] in ("done", "proof_received"):
                break
    return out


def sent_today(db: sqlite3.Connection, *, campaign: str, day: str, kind: str = "initial") -> int:
    return int(db.execute("SELECT COUNT(*) FROM verify_messages WHERE campaign=? AND kind=? AND day=? "
                          "AND status IN ('attempted','sent')", (campaign, kind, day)).fetchone()[0])


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


def _main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description="verify-request ledger ops (JSON on stdout)")
    p.add_argument("--db", default=DEFAULT_PATH)
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
    cr = sub.add_parser("claim-reminder")
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
    ve = sub.add_parser("v1-eligible", help="may a note over these credits use the v1 (no-deadline) copy?")
    ve.add_argument("--request-ids", required=True)
    c = sub.add_parser("set-conversation")
    c.add_argument("--message-id", required=True)
    c.add_argument("--conversation-id", required=True)
    a = p.parse_args(argv)
    db = connect(a.db)
    if a.op == "migrate":
        # connect() already created/upgraded every verify table; report what is there now.
        out = {"result": "ok", "tables": {t: sorted(str(r[1]) for r in db.execute(f"PRAGMA table_info({t})"))
                                          for t in TABLES}}
    elif a.op in ("claim", "refuse"):
        refs = json.loads(Path(a.refs_file).read_text()) if a.refs_file else None
        kw = dict(user_key=a.user_key, day=a.day, request_ids=_ids(a.request_ids), message_type=a.message_type,
                  approved_by=a.approved_by, approval_ref=a.approval_ref, campaign=a.campaign)
        if a.op == "claim":
            out = claim(db, contact_id=a.contact_id, refs=refs, windowed=a.windowed, user_id=a.user_id, **kw)
        else:
            out = refuse(db, reason=a.reason, user_id=a.user_id, **kw)
    elif a.op == "claim-reminder":
        out = claim_reminder(db, parent_message_id=a.parent_message_id, kind=a.kind, user_key=a.user_key, day=a.day,
                             request_ids=_ids(a.request_ids), approved_by=a.approved_by, approval_ref=a.approval_ref)
    elif a.op == "finalize":
        finalize(db, message_row=a.message_row, status=a.status, message_id=a.message_id,
                 conversation_id=a.conversation_id, reason=a.reason, body_sha256=a.body_sha256, api_log=a.api_log)
        out = {"result": "ok"}
    elif a.op == "pending":
        ids = _ids(a.request_ids)
        blocked = blocked_ids(db, ids, a.campaign)
        out = {"request_ids": [r for r in dict.fromkeys(ids) if r not in blocked],
               "hold": refusal_hold(db, a.campaign, a.user_key, user_id=a.user_id)}
        if a.user_key and a.day:
            out["daily_cap"] = capped(db, user_key=a.user_key, day=a.day, user_id=a.user_id)
        if a.user_key and a.campaign == "retro-past":
            out["user_done"] = past_user_done(db, a.user_key, a.user_id)
        if a.user_key and a.campaign in STATUS_CAMPAIGNS:
            why = uvn_user_done(db, a.user_key, campaign=a.campaign, user_id=a.user_id)
            out["user_done"] = "" if why in DEFER_REASONS else why
            out["recent"] = why in DEFER_REASONS
            out["recent_why"] = why if why in DEFER_REASONS else ""
    elif a.op == "skip":
        out = {"skipped": skip_requests(db, campaign=a.campaign, request_ids=_ids(a.request_ids))}
    elif a.op == "reminder-state":
        out = reminder_state(db, parent_message_id=a.parent_message_id, kind=a.kind, day=a.day)
    elif a.op == "message":
        r = message(db, a.message_id)
        out = dict(r) if r is not None else None
    elif a.op == "mark-tagged":
        mark_tagged(db, message_id=a.message_id, conversation_id=a.conversation_id, attachments=a.attachments)
        out = {"result": "ok"}
    elif a.op == "v1-eligible":
        out = v1_eligible(db, _ids(a.request_ids))
    elif a.op == "mark-replied":
        out = {"result": mark_replied(db, message_id=a.message_id, replied_at=a.replied_at)}
    else:
        set_conversation(db, message_id=a.message_id, conversation_id=a.conversation_id)
        out = {"result": "ok"}
    print(json.dumps(out))
    return 0


if __name__ == "__main__":
    sys.exit(_main())
