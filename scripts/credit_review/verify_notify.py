"""Trust yet verify: tell users which credits the decider approved, and ask for support.

Captain, 2026-10-15 22:12Z (verbatim): "i want AI live now - we have too many
credits to approve and to get supporting data for - let users know where there
was a credit given and that it needs support (trust yet verify approach)".

This is the step that runs AFTER ``credit-review.py decide`` approves
provisional rows. It never decides anything itself:

  1. Candidates are requests the decider's own server re-read recorded as
     approved (``decision_outcomes`` action='approve', outcome='approved'; the
     server's answer, not the decider's intent), that this step has not
     notified yet.
  2. Every candidate is RE-READ from the admin API (GET only) and kept only
     if the server says it is ``approved`` right now. A row a human or
     ``credit-review.py revert`` has moved back is never announced as live.
  3. Rows are grouped by the credit request's ACCOUNT (``user.email``, the
     person who asked for the credit), and each account gets one call to
     scripts/intercom-verify-request.sh. That gate owns the copy, Caroline's
     identity, the leak check, the one-note-per-user-per-day cap and the
     per-request idempotency (the verify ledger). This module only plans.
  4. Proof sweep: every sent note whose note family sent a message in the
     last 45 days goes through ``intercom-verify-request.sh tag-proof``
     (see ``verify_ledger.awaiting_proof`` for which tagged notes are still
     read), which records user replies, tags a reply WITH attachments
     ``credit-proof`` and does nothing else.

The decider ledger contract this reads (the credit-review ledger SQLite file,
schema owned by credit_review/decide.py): ``decision_outcomes(id, run_id, at,
request_id, action, outcome)`` joined to ``decisions(run_id, request_id,
profile_id, track_id)`` on (request_id, run_id), the same query as
``decide.run_approvals``. --since-hours filters on ``decision_outcomes.at``.
A missing table means the decider has not run yet (nothing to do); a table
without those columns is a contract break and fails loud.
"""

from __future__ import annotations

import collections
import concurrent.futures
import json
import math
import os
import re
import sqlite3
import subprocess
import tempfile
import time
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from typing import Any, Callable, Optional

from . import admin as admin_api
from . import affiliation, proof_parts, verify_ledger
# delivered_asks: which requests a note actually asked about (firstmate 768 backfill).
from .provisional_tracker import delivered_asks
from .roles import family_of

WRAPPER = os.environ.get("CREDIT_VERIFY_NOTIFY_WRAPPER", "/opt/hydra/scripts/intercom-verify-request.sh")
# The shared "documents already on file" exclusion the decider uses too (owner: the
# credit-system lane; refreshed hourly, atomic). Past credits: a user_id listed with ANY kind
# is never asked. New credits: per credit (see screen_live). Missing or older than
# PROOF_MAX_AGE_H => zero asks that run.
PROOF_ON_FILE = os.environ.get("CREDIT_PROOF_ON_FILE", "/var/lib/credit-trust/proof-on-file.json")
PROOF_MAX_AGE_H = 3
# Clock skew tolerated on a generated_at stamped AHEAD of now. Beyond it the stamp is wrong,
# so its age is unknowable and the list is not authoritative (a future stamp would otherwise
# pass the age check long after the export went stale).
PROOF_MAX_SKEW_H = 0.1
# Which parts make the list authoritative (core, cs-intercom and cs-gmail, all required):
# credit_review/proof_parts.py, shared with the take-back gate.
CAPTAIN_UID = "U7RP6HKUZ"
DECISION_COLUMNS = ("run_id", "request_id", "profile_id", "track_id")
OUTCOME_COLUMNS = ("id", "run_id", "at", "request_id", "action", "outcome")
PAGE_LIMIT = 200
MAX_PAGES = 10


class ContractError(RuntimeError):
    pass


@dataclass
class Report:
    candidates: int = 0
    not_approved_now: int = 0
    not_found: int = 0
    no_account: int = 0
    users: int = 0
    sent_notes: int = 0
    sent_credits: int = 0
    skipped: int = 0
    deferred_users: int = 0
    # [key=user-window] the holds the 7-day USER window makes (verify_ledger.claim_cross_check's
    # 'messaged_7d'): kept apart from deferred_users because it is the one hold a per-CLAIM check
    # cannot see and a per-USER send always applies - r5 10-31/11-03 on the 4-of-11 paid batch.
    # TWO counters, because they answer two questions (QA on #1681): held_user_window is every window
    # hold in the run; window_after_gate is the subset that ALSO landed in deferred_users (the send
    # refused it). A check-time hold is in the first only, so the generic 'deferred by the gate' line
    # must subtract window_after_gate, never held_user_window.
    held_user_window: int = 0
    window_after_gate: int = 0
    pending_doc_users: int = 0
    support_contact_users: int = 0
    support_contact_credits: int = 0
    documented_users: int = 0          # proof on file (any source) for another credit / whole user
    documented_credits: int = 0
    affiliation_held: list[str] = field(default_factory=list)   # "user <id>: <reason>" for a human
    recently_asked_users: int = 0
    recently_asked_credits: int = 0
    paying_unknown: str = ""
    pending_doc_credits: int = 0
    refused_users: int = 0
    failed_users: int = 0
    # r5 / firstmate 764 (2026-11-04, the 22Z round): ONE user's failed send-time read holds THAT USER. A single
    # unreadable account (a Trino read that failed) made the whole r1 family - and with it every claim family behind it -
    # stop for the night. The round is not the unit of failure; the user is. Each entry is {user, reason, user_key}.
    failed_held: list = field(default_factory=list)
    # ... and the batch stops only when the failures are SYSTEMIC: FAIL_STOP_MIN users or FAIL_STOP_SHARE of the users
    # walked, whichever is larger. This is a stop, never a kill file: it ends the run, it does not arm anything.
    stopped_on_failures: int = 0
    # ... and a read that keeps failing across ticks is not a fluke: three in a row pages a human (Fable 769).
    read_failure_pages: list = field(default_factory=list)
    # r5 (firstmate 770) (1): a POST that failed is an UNKNOWN outcome, not a held read - see _failed().
    post_failed: int = 0
    post_rejected: int = 0             # Intercom refused the POST (nothing delivered, retried later) - a deferral
    post_failures: list = field(default_factory=list)
    proof_tagged: int = 0
    claim_proof_tagged: int = 0        # claim-proof-ask replies (any reply) tagged claim-proof (a separate queue)
    claim_replies: int = 0             # claimant replies to a claim-proof-ask note (its reminder withheld)
    proof_failed: int = 0
    reminders_sent: int = 0
    skipped_not_live: int = 0
    excluded: int = 0
    removal_due: int = 0
    extension_requests: int = 0
    held_for_human: int = 0
    unverified: int = 0
    human_approved: int = 0
    trusted_anchor: int = 0            # band-A automation approvals (anchor_kind=trusted): no note, never removal-due
    docs_users: int = 0
    docs_checked: int = 0
    proof_on_file: int = 0
    no_professional_id: int = 0        # no professional id on the account: Intercom identity unverifiable, held
    flagged: int = 0
    mixed_v1_users: int = 0            # users whose one note is v1 because ANY credit is paid provisional
    already_today: int = 0             # messages the ledger already holds for today (counted against the cap)
    paying_hold: str = ""              # paying status unknown and the cap would have to choose: nothing sent
    recipient_ok: int = 0              # dry run with --check-recipients: the real gate accepted the recipient
    # ... and WHO, per user: {user, campaign, request_ids, gate} - the gate's own RECIPIENT OK line (QA / r5 #1582)
    accepted: list = field(default_factory=list)
    # t01b 563: every user an APPLY posted to, {user, campaign, request_ids, gate} (the gate's POSTED line carries the
    # channel + message id) - the per-user read-back record next to the ledger
    sent: list = field(default_factory=list)
    filtered: list = field(default_factory=list)  # users a runner dropped BEFORE the gate: {user, result, reason}
    validated: int = 0                 # dry run: the gate validated (or rendered) the note it would send
    halted: str = ""
    failures: list[str] = field(default_factory=list)
    refusals: list[str] = field(default_factory=list)
    # C11 (p1 223): every per-user gate answer that was not a send, with the user and the gate's own reason - a dry run
    # and a send are compared on these, and a deferral is never reported without why (claim 1621425, 10-30 00:16Z)
    deferrals: list[str] = field(default_factory=list)
    outcomes: list[dict[str, str]] = field(default_factory=list)
    flag_failures: list[str] = field(default_factory=list)
    # [key=note-step-timeout] (firstmate 748, the 15:05Z auto-kill): a note step that TIMED OUT or raised leaves the
    # outcome UNKNOWN (the POST may have landed; the gate's claim is written before it, so a retry can never double-send).
    # Counted on their own: the run still reports on every other user, and the tick must never score these as refusals.
    timeout_users: int = 0
    error_users: int = 0
    # [key=post-failed-unknown] (QA #1756 Important 2): the gate printed POST FAILED and exited 4 - the POST was
    # ATTEMPTED and nobody can prove it did not land. Neither a refusal (it must never enter the refusal ratio, which
    # would blame the user) nor a delivery. The tick's own post_failed arm reads this row; before this counter existed
    # the loop recorded every such return as a plain `failed`, so that arm could never fire and one unknown POST was
    # scored as an ordinary failure instead of an outcome-unknown stop.
    post_failed_users: int = 0
    # [key=note-step-budget] (Fable 753): deferred because ONE MORE worst-case note would not fit the share left. A
    # deferral, never a refusal: the user keeps no claim, stays owed, and the next tick starts them.
    budget_deferred_users: int = 0

    @property
    def failed(self) -> bool:
        # r5 / firstmate 764: `failed_users` alone is NOT a failed run any more - a user whose own read failed is HELD
        # (recorded, held, skipped by the next run) while the rest of the round goes on. Only a SYSTEMIC stop
        # (stopped_on_failures) or one of the run-level failures above fails the exit code.
        #
        # QA #1780 (Critical, 03:07Z): a POST failure is the ONE per-user outcome that is ALWAYS fatal to the run, at
        # any count. The read succeeded and the send did not land, so the outcome is UNKNOWN and the message may
        # already be delivered: a run that exits 0 over it reports success for a delivery it cannot prove, and the
        # next tick may send the same note again. It is never auto-resent (the gate leaves the row CLAIMED) and it is
        # never a read hold - but the exit code must say so.
        #
        # [key=post-failed-unknown] BOTH counters are fatal, and they are not the same fact: `post_failed_users` is
        # raised by the gate's POST FAILED LINE (checked before the generic branches, so it is the one that fires for
        # the real gate), `post_failed` by the rc=4/5 code path in _failed(kind="post"). Either one means a note may
        # or may not have reached a customer, so the caller must never exit 0 on it.
        return bool(self.stopped_on_failures or self.proof_failed or self.halted or self.flag_failures
                    or self.post_failed or self.post_failed_users)

    def render(self, mode: str, title: str = "VERIFY NOTES") -> str:
        if self.halted:
            return (f"{title}: NO asks sent this run: {self.halted}. Nothing was sent "
                    "(missing or stale proof-on-file list: when in doubt, no ask goes out).")
        # A daily-cap deferral alone is not news (it recurs every run until tomorrow's note); any OTHER gate deferral
        # is (C11, QA #1515: the reason must reach the summary). Held-for-human users are news too (once a day).
        news_defer = [d for d in self.deferrals if "daily-cap" not in d]
        # QA #1756 finding 2: an UNMEASURED note is news in its own right. Without these two counters a run whose every
        # selected user timed out rendered NO_REPLY - the one summary that most needs to be read was the silent one.
        if not (self.sent_notes or self.refused_users or self.failed_users or self.failed_held or self.post_failed
                or self.reminders_sent or news_defer or self.timeout_users or self.error_users
                or self.post_failed_users
                or self.proof_tagged or self.proof_failed or self.extension_requests
                or self.claim_proof_tagged or self.claim_replies
                or self.affiliation_held or self.documented_users or self.support_contact_users
                or self.paying_hold or self.no_professional_id or self.read_failure_pages) and mode == "apply":
            return "NO_REPLY"
        head = f"{title} (dry run, nothing sent)" if mode != "apply" else title
        parts = [f"{head}: {self.sent_notes} note(s) sent covering {self.sent_credits} provisionally approved credit(s)"
                 if mode == "apply" else f"{head}: {self.users} account(s) would get a note"]
        if self.no_professional_id:
            parts.append(f"{self.no_professional_id} account(s) held: no professional id on the account, so the "
                         "Intercom recipient cannot be matched to it")
        if self.recipient_ok:
            parts.append(f"{self.recipient_ok} recipient(s) accepted by the real gate (read only)")
        if self.paying_hold:
            parts.append(self.paying_hold)
        elif self.paying_unknown:
            parts.append(f"paying status unknown ({self.paying_unknown}); every note fit under the cap, so order did not matter")
        if self.already_today:
            parts.append(f"{self.already_today} message(s) already sent today counted against the day's cap")
        if self.mixed_v1_users:
            parts.append(f"{self.mixed_v1_users} account(s) got one no-deadline note covering a paid provisional "
                         "credit and other new credits (one note per user; no removal date)")
        if self.post_failed:
            parts.append(f"{self.post_failed} send(s) FAILED at the POST (unknown outcome: may already be delivered; "
                         "left claimed and never re-sent automatically): "
                         + "; ".join(f"user {h['user']}: {h['reason'][:120]}" for h in self.post_failures[:3]))
        if self.read_failure_pages:
            parts.append(f"{len(self.read_failure_pages)} account(s) have failed their own read on "
                         f"{verify_ledger.READ_FAILURES_TO_PAGE} consecutive ticks (a pattern, not a fluke): "
                         + "; ".join(self.read_failure_pages))
        if self.deferred_users:
            # the label comes from the gate's own reasons (QA #1515), never a fixed 'already had today's note'
            parts.append(f"{self.deferred_users} account(s) deferred by the gate"
                         + (": " + "; ".join(self.deferrals[:20]) if self.deferrals else " (no reason recorded)"))
        if self.refused_users:
            parts.append(f"{self.refused_users} refused by the gate: " + "; ".join(self.refusals[:5]))
        if self.budget_deferred_users:
            parts.append(f"{self.budget_deferred_users} account(s) not started this run: one more note's worst case "
                         f"({WORST_USER_S:.0f}s) would not have fitted the budget left; they stay owed for the next tick")
        if self.post_failed_users:
            parts.append(f"{self.post_failed_users} note(s) with an UNKNOWN outcome (the gate printed POST FAILED: the "
                         "POST was attempted and we cannot prove it was not delivered; the ledger row stays claimed and "
                         "is never re-sent automatically)")
        if self.timeout_users or self.error_users:
            lacking = []
            if self.timeout_users:
                lacking.append(f"{self.timeout_users} timed out after {NOTE_ATTEMPTS} attempts")
            if self.error_users:
                lacking.append(f"{self.error_users} raised inside the gate")
            parts.append("UNMEASURED (outcome unknown, not a refusal - the ledger row stays claimed and is never "
                         "re-sent automatically): " + ", ".join(lacking))
        if self.not_approved_now:
            parts.append(f"{self.not_approved_now} no longer approved on the server (not announced)")
        if self.proof_on_file:
            parts.append(f"{self.proof_on_file} credit(s) with documents already on file (not asked)")
        if self.pending_doc_users:
            parts.append(f"{self.pending_doc_users} account(s) ({self.pending_doc_credits} credit(s)) waiting while a "
                         "document they sent for another credit is reviewed (asked once, after the review)")
        if self.documented_users:
            parts.append(f"{self.documented_users} account(s) ({self.documented_credits} credit(s)) held for a human: "
                         "documents already on file for them (never asked)")
        if self.affiliation_held:
            parts.append(f"{len(self.affiliation_held)} account(s) held for a human (org affiliation unknown or "
                         "affiliated; polite-contact variant): " + "; ".join(self.affiliation_held[:5]))
        if self.recently_asked_users:
            parts.append(f"{self.recently_asked_users} account(s) ({self.recently_asked_credits} credit(s)) waiting: "
                         "asked in the last 90 days")
        if self.support_contact_users:
            parts.append(f"{self.support_contact_users} account(s) ({self.support_contact_credits} credit(s)) held for a "
                         "human: emailed support@ in the last 90 days (no note)")
        if self.human_approved:
            parts.append(f"{self.human_approved} approved by a person (not asked again)")
        if self.trusted_anchor:
            parts.append(f"{self.trusted_anchor} band-A approval(s) on a trusted anchor (no document ask; core's approved notice only)")
        if self.docs_checked:
            parts.append(f"documents already sent by {self.docs_users} of {self.docs_checked} account(s) checked (not asked)")
        if self.no_account:
            parts.append(f"{self.no_account} with no account email on the request (not announced)")
        if self.reminders_sent:
            parts.append(f"{self.reminders_sent} reminder(s) sent")
        if self.removal_due:
            parts.append(f"{self.removal_due} new credit(s) past the reply-by date their note named, with no proof (removal due)")
        if self.extension_requests:
            parts.append(f"{self.extension_requests} user repl(ies) to a note recorded: those credits' removal is held "
                         "for a human to pick up")
        if self.held_for_human:
            parts.append(f"{self.held_for_human} new credit(s) past the reply-by date held for a human (a document awaits "
                         "review, the user replied, or a rejection is not yet explained to them; the --removal-due "
                         "export lists them separately)")
        if self.unverified:
            parts.append(f"{self.unverified} past credit(s) with no documents 30+ days after the ask (flagged unverified; they stay)")
        if self.proof_tagged:
            parts.append(f"{self.proof_tagged} proof repl(ies) tagged credit-proof for review")
        if self.claim_replies:
            parts.append(f"{self.claim_replies} claimant repl(ies) to a claim-proof-ask note recorded: no day-7 "
                         "reminder; with a person")
        if self.claim_proof_tagged:
            parts.append(f"{self.claim_proof_tagged} claim repl(ies) tagged claim-proof for a person")
        if self.failed_held or self.post_failed or self.proof_failed:
            # r5 / firstmate 764: FAILED stays the word a replay greps; the OUTCOME is a hold - that user was not
            # messaged, was not closed, and the rest of the round went on.
            #
            # QA #1780 (Important, 02:12Z): `failed_users` counts BOTH a held read and an unknown POST, so keying the
            # "held, not messaged" sentence off it told the operator the opposite of the actual delivery state for a
            # POST failure - the one outcome where the note may ALREADY be delivered. The two are now rendered from
            # their own counts, and the held sentence is emitted only when a read hold actually exists.
            bits = []
            if self.failed_held:
                bits.append(f"{len(self.failed_held)} send(s) held, not messaged, not retried this run")
            if self.post_failed:
                bits.append(f"{self.post_failed} send(s) with an UNKNOWN outcome (the POST was attempted and we cannot "
                            "prove it was not delivered; the ledger row stays claimed and is never re-sent "
                            "automatically)")
            if self.stopped_on_failures:
                bits.append(f"SYSTEMIC at {self.stopped_on_failures}: the run stopped")
            if self.proof_failed:
                bits.append(f"{self.proof_failed} proof tag(s)")
            parts.append("FAILED: " + "; ".join(bits) + ": " + "; ".join(self.failures[:5]))
        return ". ".join(parts) + "."


def _columns(db: sqlite3.Connection, table: str) -> set[str]:
    return {str(r[1]) for r in db.execute(f"PRAGMA table_info({table})").fetchall()}


# (firstmate 768) A provisional credit whose ask never left is unreachable by a windowed
# audience: the default window is 7 days and 279 provisional credits across 63 accounts were
# approved 9-14 days ago with no delivered ask, so the day they aged out of the window they
# became unaskable FOREVER - the ledger cannot start a clock that no note ever started, and the
# tracker reports them as ``backup_ask_undelivered`` every day. The window is a cap on how far
# back we are willing to re-read, never a reason to abandon a credit that was never asked. This
# backfill is BOUNDED (never_asked_days) and rides the same gates, ledger dedupe and daily cap.
NEVER_ASKED_DAYS = 30


def candidates(db: sqlite3.Connection, *, run_id: str | None = None, since_hours: int | None = None,
               now: datetime | None = None, never_asked_days: int | None = NEVER_ASKED_DAYS,
               ) -> list[tuple[str, str, str]]:
    """(request_id, profile_id, track_id) the decider's server re-read confirmed as
    approved, oldest first, minus everything the verify ledger already notified/refused,
    plus every credit the ledger holds back for a pending document (whatever its age), plus
    (firstmate 768) every approval in the last ``never_asked_days`` that NO note ever asked
    about - the window bounds re-reading, not who may be asked.

    Read exactly as decide.run_approvals does: decision_outcomes action='approve' AND
    outcome='approved', joined to decisions on (request_id, run_id)."""
    seen: dict[str, tuple[str, str]] = {}
    for rid, pid, tid in _decider_approvals(db, run_id=run_id, since_hours=since_hours, now=now):
        seen.setdefault(rid, (pid, tid))
    rank: dict[str, int] | None = None
    if never_asked_days:
        # A windowed run stops at ``since_hours``, so the backfill re-reads the wider span and
        # keeps only the credits no delivered note ever covered. Without this, an approval that
        # aged past the window while its ask was blocked is never asked at all.
        asked = delivered_asks(db)
        wide = _decider_approvals(db, run_id=run_id, since_hours=24 * never_asked_days, now=now)
        # The decider's own order (oldest first) must survive the two passes, or a backfilled
        # 10-day-old credit would sit behind today's: paid_first() is stable, so order is policy.
        rank = {rid: i for i, (rid, _, _) in enumerate(wide)}
        for rid, pid, tid in wide:
            if str(rid).lower() not in asked:
                seen.setdefault(rid, (pid, tid))
    for rid, pid, tid in verify_ledger.deferred(db, campaign="verify-live"):
        if pid:
            seen.setdefault(rid, (pid, tid))
    blocked = verify_ledger.blocked_ids(db, list(seen))
    out = [(rid, pid, tid) for rid, (pid, tid) in seen.items() if rid not in blocked]
    if rank is not None:
        out.sort(key=lambda x: rank.get(x[0], len(rank)))
    return out


def _decider_approvals(db: sqlite3.Connection, *, run_id: str | None, since_hours: int | None,
                       now: datetime | None) -> list[tuple[str, str, str]]:
    dcols, ocols = _columns(db, "decisions"), _columns(db, "decision_outcomes")
    if not dcols or not ocols:
        return []
    missing = [f"decisions.{c}" for c in DECISION_COLUMNS if c not in dcols]
    missing += [f"decision_outcomes.{c}" for c in OUTCOME_COLUMNS if c not in ocols]
    if missing:
        raise ContractError(f"the decider ledger lacks {', '.join(missing)} (see credit_review/verify_notify.py candidates)")
    q = ("SELECT o.request_id, d.profile_id, d.track_id FROM decision_outcomes o JOIN decisions d "
         "ON d.request_id = o.request_id AND d.run_id = o.run_id "
         "WHERE o.action = 'approve' AND o.outcome = 'approved'")
    args: list[Any] = []
    if "evidence_kind" in dcols:
        # Fable 10-22 09:30Z: a score approval anchored on a trusted-source credit is band A: no
        # provisional window, no verify note.
        q += " AND coalesce(d.evidence_kind, '') != 'validator_low_risk_trusted'"
    if run_id:
        q += " AND o.run_id = ?"
        args.append(run_id)
    if since_hours:
        since = ((now or datetime.now(timezone.utc)) - timedelta(hours=since_hours)).strftime("%Y-%m-%dT%H:%M:%SZ")
        q += " AND o.at >= ?"
        args.append(since)
    q += " ORDER BY o.id"
    out: list[tuple[str, str, str]] = []
    for r in db.execute(q, args).fetchall():
        rid, pid, tid = str(r[0] or ""), str(r[1] or ""), str(r[2] or "")
        if rid and pid:
            out.append((rid, pid, tid))
    return out


def _take(items: list[dict[str, Any]], left: set[str], found: dict[str, dict[str, Any]]) -> None:
    for it in items:
        rid = str(it.get("id") or "")
        if rid in left and str(it.get("status") or "") == "approved":
            found[rid] = it
            left.discard(rid)


def reread(admin: admin_api.Admin, wanted: list[tuple[str, str, str]]) -> tuple[dict[str, dict[str, Any]], set[str]]:
    """Server truth for each wanted id: (rows the server says are approved NOW, by id;
    ids it does not). GET /admin/credit-requests has no id filter, so a profile's
    approved rows are paged (newest first); a row still unseen after that is looked up
    by its (profile, track) pair when the decider recorded the track."""
    by_profile: dict[str, set[str]] = {}
    tracks: dict[str, tuple[str, str]] = {}
    for rid, pid, tid in wanted:
        by_profile.setdefault(pid, set()).add(rid)
        if tid:
            tracks[rid] = (pid, tid)
    found: dict[str, dict[str, Any]] = {}
    for pid, ids in by_profile.items():
        left = set(ids)
        for page in range(1, MAX_PAGES + 1):
            items = admin_api.list_requests(admin, status="approved", limit=PAGE_LIMIT, page=page, profile_ids=[pid])
            _take(items, left, found)
            if not left or len(items) < PAGE_LIMIT:
                break
        for rid in sorted(left):
            if rid in tracks:
                data = admin.get("/admin/credit-requests", {"status": "approved", "limit": 50, "page": 1,
                                                            "profilesIds": pid, "trackId": tracks[rid][1]})
                items = data.get("items") if isinstance(data, dict) else None
                if not isinstance(items, list):
                    raise admin_api.AdminError("credit-requests list has no items[]")
                _take(items, left, found)
    missing = {rid for rid, _, _ in wanted if rid not in found}
    return found, missing


class ProofFileError(RuntimeError):
    pass


class ProofOnFile(dict[str, list[tuple[Optional[str], str]]]):
    """Documents on file per user id, plus who emailed support@ in the last 90 days
    (``support_contacts``, user ids as strings): those users get no note while listed -
    held for a human (firstmate 050, the decider's rule)."""

    def __init__(self, *args: Any, support_contacts: frozenset[str] = frozenset(), **kw: Any):
        super().__init__(*args, **kw)
        self.support_contacts = support_contacts
        self.scoped = False      # [key=asks-scoped-pof]: cs-gmail stale; support_contacts = claim_holds' held set
        # {user: [(request_id | None, kind, proof_at | "")]}: when each document arrived (p1 198 / Fable 199: a
        # document filed BEFORE a request cannot be that request's proof)
        self.dated: dict[str, list[tuple[Optional[str], str, str]]] = {}


def is_support_contact(documented: dict[str, Any], uid: str) -> bool:
    return bool(uid) and uid in getattr(documented, "support_contacts", frozenset())


def load_proof_on_file(path: str | None = None, *, max_age_h: float = PROOF_MAX_AGE_H,
                       now: datetime | None = None) -> ProofOnFile:
    """Documents on file, per user id: [(request_id or None for a whole-user entry, kind)]
    (captain: "make sure you arent asking for things from users that already submitted
    documents and we approved. dont piss anyoen off"). Schema: {generated_at, sources[],
    users, entries: [{user_id, request_id|null, kind, source, ref}]}; kinds approved_doc,
    pending_doc, human_approved_after_doc. Past credits: any entry excludes the whole user.
    New credits: screen_live. A missing, unreadable, stale, future-dated or half-written file,
    or one with any malformed entry, raises ProofFileError: when in doubt, no ask goes out
    (which parts must be usable: credit_review/proof_parts.py)."""
    path = path or PROOF_ON_FILE
    try:
        with open(path, encoding="utf-8") as fh:
            doc = json.load(fh)
    except FileNotFoundError as exc:
        raise ProofFileError(f"the proof-on-file list {path} is missing") from exc
    except (OSError, json.JSONDecodeError) as exc:
        raise ProofFileError(f"the proof-on-file list {path} is unreadable ({type(exc).__name__})") from exc
    if not isinstance(doc, dict) or not isinstance(doc.get("entries"), list):
        raise ProofFileError(f"the proof-on-file list {path} has no entries[]")
    from .evidence import parse_ts
    gen = parse_ts(doc.get("generated_at"))
    if gen is None:
        raise ProofFileError(f"the proof-on-file list {path} has no readable generated_at")
    now = now or datetime.now(timezone.utc)
    age_h = (now - gen).total_seconds() / 3600
    if age_h < -PROOF_MAX_SKEW_H:
        raise ProofFileError(f"the proof-on-file list {path} is dated {-age_h:.1f}h in the future")
    if age_h > max_age_h:
        raise ProofFileError(f"the proof-on-file list {path} is {age_h:.1f}h old (limit {max_age_h:g}h)")
    # Completeness (Fable review of hydra#1239, F1): a half-written export must never be
    # authoritative. sources[] must be a non-empty list that names every required part, each
    # fresh and neither stale nor missing; `users` must equal the distinct user ids in
    # entries[]. Anything else: when in doubt, no ask goes out.
    # Every entry must be well-formed (QA review of hydra#1239): a malformed row may be the
    # one user with a document on file, so it is never skipped -- the whole file is refused.
    try:
        proof_parts.check(doc, now=now, max_age_h=max_age_h, max_skew_h=PROOF_MAX_SKEW_H)
        proof_parts.check_entries(doc)
    except proof_parts.PartsError as exc:
        raise ProofFileError(f"the proof-on-file list {path}: {exc}") from exc
    contacts = proof_parts.support_contacts(doc, now=now, max_age_h=max_age_h, max_skew_h=PROOF_MAX_SKEW_H)
    if contacts is None:
        raise ProofFileError(f"the proof-on-file list {path} has no readable, fresh {proof_parts.SUPPORT_CONTACTS} "
                             "snapshot (anyone may have emailed support@)")
    return proof_from_entries(doc, frozenset(str(u) for u in contacts))


def proof_from_entries(doc: dict[str, Any], support_contacts: frozenset[str]) -> ProofOnFile:
    """The documents of an export whose entries[] passed proof_parts.check_entries, keyed by user id (the one parser:
    load_proof_on_file, and the asks' scoped read [key=asks-scoped-pof] after claim_holds admitted the export)."""
    out = ProofOnFile(support_contacts=support_contacts)
    for e in doc["entries"]:
        rid = str(e.get("request_id") or "").strip() or None
        out.setdefault(str(e["user_id"]).strip(), []).append((rid, e["kind"]))
        out.dated.setdefault(str(e["user_id"]).strip(), []).append((rid, e["kind"], str(e.get("proof_at") or "")))
    return out


def _user_id(req: dict[str, Any]) -> str:
    user = req.get("user") if isinstance(req.get("user"), dict) else {}
    return str(user.get("id") or req.get("userId") or "")


def drop_documented(rows: dict[str, dict[str, Any]], documented: ProofOnFile, report: Report) -> list[str]:
    """Past credits: remove requests whose account user is on the proof-on-file list with
    any entry; return their ids."""
    gone = [rid for rid, req in rows.items() if _user_id(req) in documented]
    for rid in gone:
        del rows[rid]
    report.proof_on_file += len(gone)
    # Emailed support@ in the last 90 days: no note, held for a human. Not closed (the
    # credit is offered again once the user is off the list or a human has ruled).
    held = {rid: _user_id(req) for rid, req in rows.items() if is_support_contact(documented, _user_id(req))}
    for rid in held:
        del rows[rid]
    report.support_contact_users += len(set(held.values()))
    report.support_contact_credits += len(held)
    return gone


def screen_live(rows: dict[str, dict[str, Any]], documented: ProofOnFile,
                report: Report) -> tuple[list[str], list[tuple[str, str, str]]]:
    """NEW credits: the documents rule is per credit, and nothing escapes the 30-day rule
    silently. In place, per account user; returns (ids to close, credits to hold back):
      - a credit with its own proof-on-file entry (any kind), approved by a person, or a
        band-A automation approval (metadata.approval.anchor_kind = trusted, Fable 10-22
        23:10Z) is not asked about; its id is returned so the caller can close it;
      - if credits are left to ask about and the user emailed support@ in the last 90 days
        (firstmate 050) or has ANY proof-on-file entry (another credit, a whole-user
        document of any kind, any source: Fable 2026-10-17 precondition 1), the user gets
        no note: those credits are returned as (request_id, profile_id, track_id) for the
        ledger's deferred rows, so they are offered again on every run and a human sees
        them (a pending_doc keeps its old meaning: one batched ask once it is reviewed)."""
    own = _documented_ids(documented)
    by_user: dict[str, list[str]] = {}
    for rid, req in rows.items():
        by_user.setdefault(_user_id(req), []).append(rid)
    closed: list[str] = []
    held: list[tuple[str, str, str]] = []
    for uid, rids in by_user.items():
        documented_here = [rid for rid in rids if rid in own]
        by_person = [rid for rid in rids if rid not in own and human_approved(rows[rid])]
        band_a = [rid for rid in rids if rid not in own and rid not in by_person and trusted_anchor(rows[rid])]
        ask = [rid for rid in rids if rid not in own and rid not in by_person and rid not in band_a]
        if ask and is_support_contact(documented, uid):
            # firstmate 050: emailed support@ in the last 90 days - no note, held for a
            # human; the credits to ask about are not closed, so they are offered again.
            report.support_contact_users += 1
            report.support_contact_credits += len(ask)
        elif ask and documented.get(uid):
            # Fable 2026-10-17 (verify-notify enable, precondition 1): a user with proof on
            # file from ANY source (Intercom, support@, core) is never notified. A document
            # under review keeps the old meaning (asked once, after the review); any other
            # entry is held for a human. Nothing is closed: the credits are offered again.
            if any(kind == "pending_doc" for _, kind in documented[uid]):
                report.pending_doc_users += 1
                report.pending_doc_credits += len(ask)
            else:
                report.documented_users += 1
                report.documented_credits += len(ask)
        else:
            ask = []
        held += [(rid, str(rows[rid].get("profileId") or ""), str(rows[rid].get("trackId") or "")) for rid in ask]
        for rid in ask:
            del rows[rid]
        for rid in documented_here + by_person + band_a:
            del rows[rid]
        report.proof_on_file += len(documented_here)
        report.human_approved += len(by_person)
        report.trusted_anchor += len(band_a)
        closed += documented_here + by_person + band_a
    return closed, held


def _documented_ids(documented: ProofOnFile) -> set[str]:
    return {rid for entries in documented.values() for rid, _ in entries if rid}


def undocumented_removal_due(db: sqlite3.Connection, documented: ProofOnFile, *, day: str,
                             held: bool = False, core_told: Any = None) -> list[dict[str, Any]]:
    """The ledger's removal-due credits (held=True: the ones held for a human, see
    verify_ledger.held_for_human) minus any credit with its own proof-on-file entry (any kind: a document
    waiting for review is not a missing one). Ledger only.

    `core_told` answers "did CORE's own decline email tell this user" (QA #1718, 2026-11-06): with core's route on,
    hydra writes no `decline` row, so without it every rejected credit is held as never-told forever."""
    own = _documented_ids(documented)
    rows = (verify_ledger.held_for_human(db, day=day, core_told=core_told) if held
            else verify_ledger.removal_due(db, day=day, core_told=core_told))
    return [r for r in rows if r["request_id"] not in own]


def removal_due(db: sqlite3.Connection, admin: admin_api.Admin, documented: ProofOnFile, *,
                day: str, core_told: Any = None) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    """The removal export: (removal-due credits, credits held for a human), each from undocumented_removal_due minus any credit a person approved
    (re-read from the admin API). The remover still re-checks each one."""
    due = undocumented_removal_due(db, documented, day=day, core_told=core_told)
    held = undocumented_removal_due(db, documented, day=day, held=True, core_told=core_told)
    wanted = [(r["request_id"], str(r["profile_id"]), str(r["track_id"] or "")) for r in due + held if r["profile_id"]]
    live, _ = reread(admin, wanted) if wanted else ({}, set())
    by_person = {rid for rid, req in live.items() if human_approved(req)}
    # Proof is matched by USER as well as by credit (firstmate 042): a user with a
    # whole-user document waiting for review (e.g. emailed to support@, no request id)
    # never reaches a per-credit removal day - their credits are held for a human.
    waiting = {rid for rid, req in live.items()
               if _user_pending_doc(documented, _user_id(req)) or is_support_contact(documented, _user_id(req))}
    for r in due:
        if r["request_id"] in waiting:
            r["reason"] = verify_ledger.HELD_AWAITING_REVIEW
    return ([r for r in due if r["request_id"] not in by_person and r["request_id"] not in waiting],
            [r for r in held if r["request_id"] not in by_person]
            + [r for r in due if r["request_id"] in waiting and r["request_id"] not in by_person])


def _user_pending_doc(documented: ProofOnFile, uid: str) -> bool:
    """The user has a whole-user (no request id) document waiting for review."""
    return bool(uid) and any(rid is None and kind == "pending_doc" for rid, kind in documented.get(uid, []))


def human_approved(req: dict[str, Any]) -> bool:
    """A person approved this request (metadata.approval.isAgent is false, the stamp
    core-backend's approvalRecord.js writes). Captain standing order: never ask about
    a credit someone approved after seeing documents; we cannot tell which human
    approvals saw documents, so none is asked about."""
    meta = req.get("metadata") if isinstance(req.get("metadata"), dict) else {}
    appr = meta.get("approval") if isinstance(meta.get("approval"), dict) else {}
    return appr.get("isAgent") is False


def trusted_anchor(req: dict[str, Any]) -> bool:
    """A band-A automation approval: core's metadata.approval.anchor_kind is "trusted" (the
    server-computed band; Fable ruling 2026-10-22 23:10Z on firstmate 095). Core stamps every
    automation approval provisional, but a trusted-anchor one gets NO document ask, only core's
    standard "approved" notice, and is never removal-due: the note is keyed on anchor_kind,
    never on the provisional flag."""
    meta = req.get("metadata") if isinstance(req.get("metadata"), dict) else {}
    appr = meta.get("approval") if isinstance(meta.get("approval"), dict) else {}
    return appr.get("anchor_kind") == "trusted"


def drop_human_approved(rows: dict[str, dict[str, Any]], report: Report) -> list[str]:
    """Remove human-approved requests from `rows` in place; return their ids."""
    gone = [rid for rid, req in rows.items() if human_approved(req)]
    for rid in gone:
        del rows[rid]
    report.human_approved += len(gone)
    return gone


def _andjoin(xs: list[str]) -> str:
    xs = [x for x in xs if x]
    if len(xs) <= 1:
        return xs[0] if xs else ""
    return ", ".join(xs[:-1]) + " and " + xs[-1]


# roles.family_of -> the gate's document-list family (retro-past copy).
DOC_FAMILY = {"mix": "mix_master", "remix": "mix_master", "master": "mix_master", "immersive_mix": "mix_master",
              "immersive_master": "mix_master", "remaster": "mix_master", "producer": "producer",
              "exec_producer": "producer", "writer": "writer", "engineer": "engineer", "assistant": "engineer",
              "performer": "musician", "programming": "musician", "arranger": "musician"}


# Organization roles take the studio/organization document list (Fable copy GO 10-16,
# copy-studio-organization.md), never the musician list; A&R has its own list (copy review
# 2026-10-17). A person on the studio staff (Engineer, Assistant) keeps the engineer list.
STUDIO_ORG_ROLES = ("studio", "record label", "label", "publisher", "management", "distributor",
                    "production company")


def doc_family(role: str) -> str:
    r = " ".join((role or "").lower().replace("&", " & ").split())
    if "studio manager" in r:
        return "engineer"  # a person on the studio staff
    if any(k in r for k in STUDIO_ORG_ROLES) and "engineer" not in r:
        return "studio_org"
    fam = family_of(role)
    if fam == "anr":
        return "anr"
    return DOC_FAMILY.get(fam, "other")


def doc_families(roles: list[str]) -> list[str]:
    return list(dict.fromkeys(doc_family(r) for r in roles)) or ["other"]


def credit_line(req: dict[str, Any]) -> dict[str, Any] | None:
    artists = req.get("spotifyTrackArtists") if isinstance(req.get("spotifyTrackArtists"), list) else []
    artist = str((artists[0] or {}).get("name") or "") if artists and isinstance(artists[0], dict) else ""
    roles = [str(c) for c in (req.get("credits") or []) if c]
    title = str(req.get("spotifyTrackTitle") or "")
    if not (roles and title and artist):
        return None
    return {"request_id": str(req.get("id")), "role": _andjoin(roles), "track_title": title, "artist_name": artist,
            "role_families": doc_families(roles), "profile_id": str(req.get("profileId") or ""),
            "track_id": str(req.get("trackId") or "")}


def plan(rows: dict[str, dict[str, Any]], report: Report,
         key: Callable[[dict[str, Any]], Any] | None = None, dropped: list[str] | None = None) -> list[dict[str, Any]]:
    """One {user, credits} payload per account, in the order of the first credit
    each account has under `key` (default oldest first); credits keep that order.
    Requests that cannot be announced (no account email, title or artist) go to
    `dropped` so the caller can close them instead of re-offering them every run."""
    groups: dict[str, dict[str, Any]] = {}
    for req in sorted(rows.values(), key=key or (lambda r: str(r.get("createdAt") or ""))):
        user = req.get("user") if isinstance(req.get("user"), dict) else {}
        email = str(user.get("email") or "").strip().lower()
        line = credit_line(req)
        if not email or line is None:
            report.no_account += 1
            if dropped is not None:
                dropped.append(str(req.get("id")))
            continue
        full = str(user.get("fullName") or "").strip()
        g = groups.setdefault(email, {"user": {"email": email, "id": str(user.get("id") or ""),
                                               "first_name": full.split(" ")[0] if full else ""},
                                      "credits": []})
        g["credits"].append(line)
    return list(groups.values())


Runner = Callable[[list[str]], "subprocess.CompletedProcess[str]"]
Query = Callable[[str], list[list[str]]]
TRINO = "/opt/hydra/scripts/trino-query.sh"
# Kept from #1295/#1298: the identity lookup's Trino command can be overridden (tests, a
# different replica wrapper). Default: the same trino-query.sh.
AUTH_LOOKUP_CMD = os.environ.get("CREDIT_VERIFY_AUTH_LOOKUP_CMD", TRINO)


class TrinoTransientError(RuntimeError):
    """Trino itself said "retry in a few minutes" (verify-outbound-migration-race-m1 addendum, 2026-11-05 14:25:53Z).

    A transient condition is NOT a terminal failure of the run: the caller retries it bounded and then DEFERS the
    family, instead of stopping the tick and starving every family behind it. Everything else stays a bare
    RuntimeError - a SQL error, a missing table, an auth failure must still be terminal."""


# Trino's own words for "this is not your query's fault". Matched case-insensitively against the stderr tail.
TRINO_TRANSIENT_MARKERS = (
    "under too much load",
    "transient issue",
    "please retry",
    "updating task",
    "error 503",
    "error 502",
    "503 service unavailable",
    "502 bad gateway",
)


def trino_transient(stderr: str) -> bool:
    """True when Trino's own stderr says the failure is transient (retryable), False for a real query failure."""
    low = (stderr or "").lower()
    return any(m in low for m in TRINO_TRANSIENT_MARKERS)


def trino(sql: str, cmd: str | None = None) -> list[list[str]]:
    """Read-only query against the core replica (Trino)."""
    import csv
    import io
    p = subprocess.run([cmd or TRINO], input=sql, capture_output=True, text=True, timeout=900, check=False)
    if p.returncode:
        if trino_transient(p.stderr):
            raise TrinoTransientError(f"trino transient: {p.stderr[-300:]}")
        raise RuntimeError(f"trino failed: {p.stderr[-300:]}")
    lines = [ln for ln in p.stdout.splitlines() if ln.startswith('"')]
    return list(csv.reader(io.StringIO("\n".join(lines))))


# [key=note-step-timeout] (firstmate 748, re-answered for 750): one stalled note step aborted the WHOLE run - the
# 15:05Z apply died on a 180 s TimeoutExpired, wrote no outcomes file, and the tick read the missing artefact as a
# refusal spike and killed itself. A timeout is retried because it is the ONE failure whose outcome is unknown, and a
# retry can add nothing a first attempt did not already commit to: the gate writes its CLAIM (keyed on the user and the
# day) BEFORE it posts, so a re-run of the same user finds the claim and answers without a second note. The 7-day
# per-user window is the backstop across midnight, not the mechanism.
#
# THE BUDGET IS THE POINT (d2 r5, amended 751/753). A run of slow users must not eat the family's share, or the family
# DEFERS every tick (the 11-02 "tick budget reached; this family waits" livelock) - a quieter failure than the crash, not
# a better one. TWO numbers, and they are different things (Fable 753):
#   - the EXPECTED cost of one user (APPLY_S_PER_USER in the tick) sizes the apply: 40 s, what a note step measured;
#   - the WORST case one user can cost is NOTE_ATTEMPTS x NOTE_TIMEOUT_S + sum(NOTE_BACKOFF_S) = 3 x 55 + (10 + 25)
#     = 200 s (APPLY_USER_WORST_S in the tick). Sizing the apply at the WORST case to survive a 1-in-80 event cut
#     throughput 3x (fit = budget/200 = ~25 users a tick), so instead the SEND LOOP refuses to START a user whose worst
#     case would not fit in the share it was given: one slow user can then overrun by at most one retry budget, and only
#     the last one. Change a number here, change the tick's.
NOTE_TIMEOUT_S = 55
NOTE_ATTEMPTS = 3
NOTE_BACKOFF_S = (10.0, 25.0)          # between attempts 1->2 and 2->3
WORST_USER_S = NOTE_ATTEMPTS * NOTE_TIMEOUT_S + sum(NOTE_BACKOFF_S)   # 200: what the send loop guards against

# A read-only gate call (--check-recipient / --validate / --dry-run) is NEVER retried: CHECK_WORKERS of them run in
# parallel, so a retry there multiplies across threads, and none of them posts anything. One short attempt (~2x the ~10 s
# a live-gate check costs), then NoteTimeout - the run sends nothing this tick, which is the safe direction.
READ_TIMEOUT_S = 20

# Everything else that goes through the runner (tag-proof, the proof sweep) keeps main's single 180 s attempt: it is not
# a note POST, so it has neither the double-send protection nor the retry.
OTHER_TIMEOUT_S = 180

_READ_ONLY_FLAGS = ("--check-recipient", "--validate", "--dry-run")

# [key=note-step-budget] (Fable 753): the seconds this run may spend, handed in by the tick that owns the clock. None = no
# guard (a hand-run apply is bounded by --max-users and a human watching it). Run-scoped, like APPLY_ONLY below.
APPLY_BUDGET_S: float | None = None


def set_apply_budget(seconds: float | None) -> None:
    """One place (credit-review.py main) hands the tick's remaining share to every family's send loop."""
    global APPLY_BUDGET_S  # noqa: PLW0603 - a run-scoped switch, exactly like APPLY_ONLY/PREVIEW_ONLY
    APPLY_BUDGET_S = (float(seconds) if seconds and float(seconds) > 0 else None)


def budget_exhausted() -> bool:
    """[key=note-step-budget] (QA #1756 Important): would the send loop refuse to START another user right now?

    The loop's own guard is the authority; this is the same predicate exposed so a caller that does work BEFORE the
    send (need_asks mints a distributor's F9 code, then sends) can ask it first. Without this, a distributor user whose
    share was already spent still had a code minted and then deferred - a code issued for a note that was never sent.
    """
    if APPLY_BUDGET_S is None:
        return False
    started = _SESSION_STARTED if _SESSION_STARTED is not None else time.monotonic()
    return (time.monotonic() - started) + WORST_USER_S > APPLY_BUDGET_S


class NoteTimeout(RuntimeError):
    """The note step exhausted its attempts: the outcome is UNKNOWN, never a refusal and never a send."""


def _note_post(argv: list[str]) -> bool:
    """The one call a retry is safe for: `send` with no read-only flag (see the claim-before-POST note above)."""
    return "send" in argv and not any(f in argv for f in _READ_ONLY_FLAGS)


def _run(argv: list[str]) -> "subprocess.CompletedProcess[str]":
    post = _note_post(argv)
    attempts = NOTE_ATTEMPTS if post else 1
    timeout = (NOTE_TIMEOUT_S if post else
               READ_TIMEOUT_S if any(f in argv for f in _READ_ONLY_FLAGS) else OTHER_TIMEOUT_S)
    timed_out = 0
    for attempt in range(1, attempts + 1):
        try:
            res = subprocess.run(argv, capture_output=True, text=True, timeout=timeout, check=False)
        except subprocess.TimeoutExpired:
            timed_out += 1
            if attempt >= attempts:
                raise NoteTimeout(f"{'the note step' if post else 'a gate call'} timed out after "
                                  f"{attempts} attempt(s) of {timeout}s") from None
            time.sleep(NOTE_BACKOFF_S[min(attempt, len(NOTE_BACKOFF_S)) - 1])
            continue
        if timed_out:
            # [key=note-step-timeout] (QA #1756 Important 2): the EARLIER attempt's outcome is unknown - the gate claims
            # the user BEFORE it posts, so the retry can answer "already claimed/notified" whether the timed-out POST
            # landed or died before it. The answer alone cannot settle that, so it must not erase the timeout: the
            # caller reads this flag and records the user as UNMEASURED instead of as a skip.
            setattr(res, "after_timeout", timed_out)
        return res
    raise NoteTimeout("the note step was never attempted")          # unreachable: the loop returns or raises


def _first_line(text: str) -> str:
    return (text.strip().splitlines() or [""])[0][:200]


# Fable 526 / measured 10-31 23:1xZ: a live-gate check costs ~10 s, so a read-only pass (check-recipients, preview,
# validate) runs its gate calls on CHECK_WORKERS threads. Safe because every gate write is guarded by ACTION=post and the
# ledger opens --readonly off post; results are consumed in LIST order, so the accounting equals a serial pass. A real
# send (apply) is always serial: one writer for claims, caps and pacing.
CHECK_WORKERS = 4

# Fable r5's ruled bar (firstmate 764, restated in 765): a run of failed users becomes a systemic stop at
# max(3, 2% of the users walked) - NOT 5%, which was my reading and r5's ruling corrects. Below the bar every failed
# user is HELD and the round continues; at or above it the run stops and says so, because at that point the failures
# are a statement about the environment, not about one account.
FAIL_STOP_MIN = 3
FAIL_STOP_SHARE = 0.02


def fail_stop_after(walked: int) -> int:
    """How many failed users make a run systemic (>= max(FAIL_STOP_MIN, FAIL_STOP_SHARE of the users walked))."""
    return max(FAIL_STOP_MIN, math.ceil(FAIL_STOP_SHARE * max(1, int(walked))))

# Fable [key=signed-on-sha] (r5 747, the 04:21Z C p3 stop: a deploy landed between signing and apply): a signature is
# for ONE deploy head. Every list builder records signed_on = the deployed sha at build / dry-run time; a list-driven
# apply re-reads /opt/hydra/.deployed-sha before EVERY user and defers that user (sha_mismatch, nothing sent, no claim)
# when it differs - a deploy mid-batch stops the rest, and a list header without signed_on sends nothing. Every apply
# also holds APPLY_LOCK (shared: applies may run side by side) so a deploy refuses while one is in flight (deploy.sh).
DEPLOYED_SHA_PATH = "/opt/hydra/.deployed-sha"
APPLY_LOCK_PATH = "/var/lib/hydra/credit-review/apply.lock"


def _test_harness_dir() -> str:
    """The credit test harness's temp dir (scripts/tests/credit_test_env.py) - honoured ONLY when it is a directory
    under the system temp dir carrying the harness marker; anything else is production. Same posture as the timer's
    harness-only cfg: the suites run on node-8 (PR Validation) and must never read its deploy head or take its lock."""
    d = os.environ.get("CREDIT_TEST_ENV_DIR") or ""
    if not d:
        return ""
    real, tmp = os.path.realpath(d), os.path.realpath(tempfile.gettempdir())
    ok = real.startswith(tmp + os.sep) and os.path.isdir(real) and os.path.isfile(os.path.join(real, ".credit-test-env"))
    return real if ok else ""


if _test_harness_dir():
    DEPLOYED_SHA_PATH = os.path.join(_test_harness_dir(), "no-deployed-sha")
    APPLY_LOCK_PATH = os.path.join(_test_harness_dir(), "apply.lock")

LIST_SIGNED_ON: str | None = None       # bound by the list loaders (None = no list loaded: not a list-driven send)
HEAD_REFUSED = 0                        # users this process deferred on the sha rail (the CLIs exit 3)


def deployed_head() -> str:
    """The deployed sha, or '' when it cannot be read or is not EXACTLY a 40-hex sha (QA #1604: never normalised - a
    malformed or truncated record is unreadable, and an unreadable head refuses). For the builders' signed_on."""
    try:
        raw = open(DEPLOYED_SHA_PATH, encoding="utf-8").read()
    except (OSError, UnicodeDecodeError):
        return ""
    raw = raw[:-1] if raw.endswith("\n") else raw
    return raw if re.fullmatch(r"[0-9a-f]{40}", raw) else ""


def bind_list(doc: Any) -> None:
    """Record the loaded list's signed_on (its header) for the per-user sha rail."""
    global LIST_SIGNED_ON
    LIST_SIGNED_ON = str(doc.get("signed_on") or "") if isinstance(doc, dict) else ""


def head_mismatch() -> str:
    """'' when this apply may send now; otherwise why not (one line)."""
    if LIST_SIGNED_ON is None:
        return ""                                    # not a list-driven send
    h = _test_harness_dir()
    if h and DEPLOYED_SHA_PATH == os.path.join(h, "no-deployed-sha"):
        return ""                                    # the credit test harness's stand-in (its own tests patch a real one)
    # QA #1604: no readable deployed sha = refuse, whatever the header says (a list-driven apply never sends blind)
    dep = deployed_head()
    if not dep:
        return f"sha_mismatch: the deployed sha ({DEPLOYED_SHA_PATH}) is unreadable"
    s_ = LIST_SIGNED_ON
    if not s_:
        return "sha_mismatch: the list header carries no signed_on (re-build / re-dry-run it on the deployed head)"
    # the FULL sha, exactly (QA #1604): no prefix match, no case folding, no trimming
    if not re.fullmatch(r"[0-9a-f]{40}", s_) or s_ != dep:
        return f"sha_mismatch: signed on {s_[:12]}, deployed {dep[:12]} - re-dry-run and re-sign on the deployed head"
    return ""


class ApplyLockError(RuntimeError):
    pass


class ApplyLockUnopenable(ApplyLockError):
    """QA #1799 r12 (carried): the lock could not be OPENED at all - a permissions or I/O fault, not contention.

    It subclasses ApplyLockError so every existing caller keeps its contract (exit 3, nothing sent), but the tick can
    tell the two apart: a broken lock is a HARD STOP, never "a deploy holds the lock" retried and deferred."""


# QA #1799 r11: exit 3 is NOT synonymous with a held deploy lock. credit-review.py also exits 3 for a cap-short, a
# signed-set mismatch and HEAD_REFUSED, and ApplyLockError itself covers a lock that could not be OPENED. The tick used
# to retry every rc=3 with an unchanged ledger, so a hard refusal was mislabelled "a deploy holds the apply lock",
# retried, and then let the tick continue into later groups and exit 2 instead of preserving the hard stop. The lock
# path now prints this marker on stderr; the tick retries rc=3 ONLY when it sees it. Nothing else changes contract:
# the exit code stays 3 for every caller, and a hard refusal simply never prints the marker.
APPLY_LOCK_MARKER = "APPLY_LOCK_HELD"
# QA #1799 r12: a lock that could not be OPENED is a permissions/I-O fault, never contention - its own marker, so the
# tick stops hard instead of retrying and deferring a broken lock as if a deploy held it.
APPLY_LOCK_UNOPENABLE_MARKER = "APPLY_LOCK_UNOPENABLE"


_SESSION_LOCK: Any = None              # the apply lock held for a whole outer apply run (apply_session)
# [key=note-step-budget] (QA #1756 Critical): the monotonic start of the OUTER apply run, set by apply_session. The
# budget is a RUN share handed in by the tick, but a caller that sends one user per send_all call (uvn_status.run does
# exactly that) restarted the clock on every user, so several slow notes could together overrun the share and hit the
# tick's hard deadline mid-apply - a partial send, then the auto-kill. One clock per run, not one per call.
_SESSION_STARTED: float | None = None


class apply_session:  # noqa: N801 - used as `with verify_notify.apply_session():`
    """QA #1604 (b1 568): the shared apply lock is held ONCE around a whole apply run (every per-user send_all call, E's
    preflight + code issuance + send) - a deploy cannot slip in between two users. Re-entrant: send_all inside a session
    does not take or release the lock itself. Raises ApplyLockError when the lock cannot be taken (nothing is sent)."""

    def __enter__(self) -> "apply_session":
        global _SESSION_LOCK, _SESSION_STARTED  # noqa: PLW0603 - one run-scoped clock with the one run-scoped lock
        self.outer = _SESSION_LOCK is None
        if self.outer:
            _SESSION_LOCK = _apply_lock()
            # the budget's clock starts with the LOCK, i.e. with the run: everything the share must pay for (the per-user
            # planning between sends included) is inside it, and no per-user send_all call can reset it
            _SESSION_STARTED = time.monotonic()
        return self

    def __exit__(self, *exc: Any) -> None:
        global _SESSION_LOCK, _SESSION_STARTED
        if self.outer and _SESSION_LOCK is not None:
            _SESSION_LOCK.close()
            _SESSION_LOCK = None
        if self.outer:
            _SESSION_STARTED = None


def _apply_lock() -> Any:
    """Take the apply lock SHARED and non-blocking for this apply's whole run (QA #1604: the directory is created when
    missing - never 'no lock'). A deploy holding it exclusively (deploy.sh, with the prune lock) or an unopenable lock
    raises ApplyLockError: the apply sends nothing."""
    import fcntl  # noqa: PLC0415
    try:
        os.makedirs(os.path.dirname(APPLY_LOCK_PATH), mode=0o700, exist_ok=True)
        fh = open(APPLY_LOCK_PATH, "a+")
    except OSError as exc:
        raise ApplyLockUnopenable(f"the apply lock {APPLY_LOCK_PATH} cannot be opened ({exc}); nothing sent") from exc
    try:
        fcntl.flock(fh.fileno(), fcntl.LOCK_SH | fcntl.LOCK_NB)
    except OSError as exc:
        fh.close()
        raise ApplyLockError(f"a deploy holds the apply lock {APPLY_LOCK_PATH}; nothing sent (re-run after it)") from exc
    return fh


ASK_CAMPAIGNS = ("uvn-status", "proof-need-ask", "gap-ask", "claim-proof-ask", "verify-live", "retro-past")


# QA #1626: the facts key tracks and roles with the RENDERER's own string rules, which are jq's: ascii_downcase lowers A-Z
# only ("Été" and "été" stay two titles), and jq's \s is Unicode whitespace WITHOUT the separators chr(28)..chr(31) that
# Python's \s adds (the same class as attempted_reconcile._WS, #1607)
_JQ_WS = re.compile("[^\\S" + "".join(chr(c) for c in range(28, 32)) + "]+")
_ASCII_LOWER = str.maketrans("ABCDEFGHIJKLMNOPQRSTUVWXYZ", "abcdefghijklmnopqrstuvwxyz")


def _ascii_lower(s: str) -> str:
    return s.translate(_ASCII_LOWER)


def _jq_tnorm(v: Any) -> str:        # the gate's tnorm: tostring | ascii_downcase | gsub("\\s+"; " ") | gsub("^ +| +$"; "")
    return _JQ_WS.sub(" ", _ascii_lower(str(v if v is not None else ""))).strip(" ")


def _jq_trim(s: str) -> str:          # jq: gsub("^\\s+|\\s+$"; "")
    return re.sub("^" + _JQ_WS.pattern + "|" + _JQ_WS.pattern + "$", "", s)


def render_facts(p: dict[str, Any], extra: list[str]) -> dict[str, Any]:
    """The facts row the batch judge reads for one rendered body, from the payload the gate rendered: the class (ask /
    status, by campaign), whether the user owes proof (an ask, or the R1 receipt to a user who still owes it), the
    distinct tracks with their roles, and the document dates the copy may name."""
    camp = extra[extra.index("--campaign") + 1] if "--campaign" in extra[:-1] else ""
    copy = extra[extra.index("--copy") + 1] if "--copy" in extra[:-1] else ""
    credits = p.get("credits") or []
    # QA #1626: the facts count tracks and roles EXACTLY as the gate renderer does - a track is its tkey (track_id, else
    # the case/space-normalised title + artist), and a track's roles are track_roles' (comma-split, trimmed, each role
    # once case-insensitively, the first form kept) - so the judge never sees a number the body did not render
    tnorm = _jq_tnorm

    keyed: dict[str, tuple[str, list[str]]] = {}
    for c in credits:
        k = (f"id:{c['track_id']}" if str(c.get("track_id") or "") else
             f"t:{tnorm(c.get('track_title') or '')}|{tnorm(c.get('artist_name') or '')}")
        title, roles = keyed.setdefault(k, (str(c.get("track_title") or ""), []))
        for r in [_jq_trim(r) for r in str(c.get("role") or "").split(",") if _jq_trim(r)]:
            if all(_ascii_lower(r) != _ascii_lower(x) for x in roles):
                roles.append(r)
    tracks = {k: v for k, v in keyed.items()}
    need = p.get("need") or {}
    dates = sorted({str(d)[:10] for d in [need.get("doc_received_at")] + [c.get("doc_received_at") for c in credits] if d})
    return {"class": "ask" if camp in ASK_CAMPAIGNS else "status", "campaign": camp, "copy": copy,
            "owes_proof": camp in ASK_CAMPAIGNS or copy == "received",
            # t01b 655 / b1 656: ONE fact name on both sides - the v9 RULES name `tracks` (title + roles of each distinct
            # track), so the fact is `tracks` [[title, [roles]]] (was tracks_roles, which no rule named); today_year is
            # the judge clock's year (never the body's: R4 old_date_year ran blind live without it); document_count is
            # what the payload's need names (None = not known)
            "distinct_tracks": len(tracks), "tracks": sorted([t, sorted(r)] for t, r in tracks.values()),
            "today_year": datetime.now(timezone.utc).year,
            "document_count": _doc_count(need),
            "document_dates": dates, "credits": len(credits), "source": "renderer"}


def _doc_count(need: dict[str, Any]) -> int | None:
    n = need.get("doc_count")
    if isinstance(n, int) and not isinstance(n, bool) and n >= 1:
        return n
    shas = need.get("doc_shas")
    return len(set(shas)) if isinstance(shas, list) and shas else None


# t01b 584 / p1 579: a preview renders EXACTLY the check's accepted set. Set (by --preview-accepted) to the user ids the
# --check-recipients run accepted; a preview then renders those users only - a user the check deferred never takes a
# render (or a slot of the run's size). None = every user (the default).
PREVIEW_ONLY: frozenset[str] | None = None


# Fable [key=apply-sized-to-list] (amended 586): an apply of a SIGNED check sends only users in that check's accepted
# set - set by --signed-accepted. A user outside it is never sent (deferred, no gate call). None = no signed set.
APPLY_ONLY: frozenset[str] | None = None
# set - the RAW page end the signed CHECK reached; a paged apply clamps its cursor to it (QA #1662)
APPLY_RAW_END: int | None = None
APPLY_REPORTS: list[Any] = []          # the reports a signed apply ran through send_all (for the sent == signed check)
APPLY_PAGE = False                     # --page: the outbound tick's signed set may be paged (cap / deadline)


def not_signed(mode: str, uid: Any) -> bool:
    """QA #1611: True when a signed apply (APPLY_ONLY set) must leave this user out BEFORE any per-user work - the
    run-size slice, a preflight, a code issuance. Callers drop such users before they take a slot."""
    return mode == "apply" and APPLY_ONLY is not None and str(uid) not in APPLY_ONLY


def signed_set_mismatch(reports: list[Any], accepted: frozenset[str], *, page: bool) -> str:
    """'' when the apply's sent set is the signed accepted set (or, paged, a subset of it); else the refusal naming the
    users. A user sent outside the set is always a refusal (it cannot happen through send_all - a second wall)."""
    sent = {str(x.get("user")) for r in reports for x in getattr(r, "sent", [])}
    outcomes = [o for r in reports for o in getattr(r, "outcomes", [])]
    extra, missing = sorted(sent - accepted), sorted(accepted - sent)
    if extra:
        return f"SENT OUTSIDE THE SIGNED SET: {len(extra)} user(s) ({', '.join(extra[:20])})"
    if missing and not page:
        why = {o.get("user"): o.get("reason", "") for o in outcomes}
        named = "; ".join(f"{u}: {(why.get(u) or 'not reached')[:80]}" for u in missing[:20])
        return (f"SIGNED SET NOT SENT WHOLE: {len(sent)} of {len(accepted)} signed accepted users sent; "
                f"{len(missing)} not ({named})")
    return ""


def load_preview_accepted(path: str) -> frozenset[str]:
    """The `accepted` user ids of a --check-recipients --outcomes-json file. Raises ValueError when it has none."""
    with open(path, encoding="utf-8") as fh:
        doc = json.load(fh)
    acc = doc.get("accepted") if isinstance(doc, dict) else None
    if not isinstance(acc, list) or doc.get("mode") == "apply":
        raise ValueError(f"{path} is not a dry-run check's outcomes file with an accepted set")
    return frozenset(str(a.get("user")) for a in acc if isinstance(a, dict))


def send_all(payloads: list[dict[str, Any]], report: Report, *, mode: str,
             wrapper: str = WRAPPER, runner: Runner = _run, extra: list[str] | None = None,
             pace_seconds: float = 0.0, preview_dir: str | None = None, reminder: bool = False,
             check_recipients: bool = False, workers: int | None = None,
             walked: int | None = None, ledger_path: str | None = None,
             campaign: str = "") -> None:
    """``ledger_path`` + ``campaign`` turn on the read-failure hold for this lane (Fable r5 2026-11-06 00:53Z): a user
    whose own send-time read failed on an earlier tick is SKIPPED until the hold expires, and a read that works clears
    the streak. Both are apply-only; a dry run neither honours nor writes a hold."""
    if PREVIEW_ONLY is not None and preview_dir and mode != "apply" and not check_recipients:
        payloads = [p for p in payloads if _uid(p) in PREVIEW_ONLY]          # never a gate call for the rest
    if APPLY_ONLY is not None and mode == "apply":
        if not any(r is report for r in APPLY_REPORTS):
            APPLY_REPORTS.append(report)
        for p in [p for p in payloads if _uid(p) not in APPLY_ONLY]:
            report.deferred_users += 1
            _outcome(report, p, "deferred", "not_in_signed_accepted: not in the signed check's accepted set; not sent")
        payloads = [p for p in payloads if _uid(p) in APPLY_ONLY]
    if mode == "apply" or check_recipients:
        try:
            payloads, held = attach_identities(payloads, report)
        except Exception as exc:  # noqa: BLE001 - an unreadable replica sends nothing
            report.halted = f"the accounts' professional ids cannot be read from the replica ({exc}); nothing is sent"[:300]
            return
        # QA #1582: a user held here never reaches the gate - name them, so the run accounts for every listed user
        report.filtered += [{"user": _uid(p), "result": "filtered",
                             "reason": "no professional id on the account (Intercom identity unverifiable): held"} for p in held or []]
    def gate(p: dict[str, Any]) -> subprocess.CompletedProcess:
        fd, path = tempfile.mkstemp(prefix="verify-note-", suffix=".json")
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as fh:
                json.dump({"user": p["user"], "credits": p["credits"],
                           **{k: p[k] for k in ("claim", "need") if k in p}}, fh, ensure_ascii=False)
            argv = [wrapper, "send", "--credits-file", path, "--approved-by", CAPTAIN_UID]
            argv += (extra or []) + (p.get("extra") or [])
            if mode != "apply":
                # C11: the recipient check runs every send-time check read-only (dry run == send); it wins over a preview
                argv.append("--check-recipient" if check_recipients else ("--dry-run" if preview_dir else "--validate"))
            return runner(argv)
        finally:
            os.unlink(path)

    n_workers = CHECK_WORKERS if workers is None else workers
    pre: list[subprocess.CompletedProcess] | None = None
    if mode != "apply" and n_workers > 1 and len(payloads) > 1:
        with concurrent.futures.ThreadPoolExecutor(max_workers=n_workers) as ex:
            pre = list(ex.map(gate, payloads))           # list order, whatever order they finish in
    lock = None
    if mode == "apply" and _SESSION_LOCK is None:    # inside an apply_session the run already holds it
        try:
            lock = _apply_lock()
        except ApplyLockError as exc:
            report.halted = str(exc)[:300]
            return
    try:
        _send_loop(payloads, report, mode=mode, pace_seconds=pace_seconds, pre=pre, gate=gate, extra=extra,
                   preview_dir=preview_dir, reminder=reminder, walked=walked, ledger_path=ledger_path,
                   campaign=campaign)
    finally:
        if lock is not None:
            lock.close()


def _send_loop(payloads: list[dict[str, Any]], report: Report, *, mode: str, pace_seconds: float, pre: Any,
               gate: Callable[[dict[str, Any]], Any], extra: list[str] | None, preview_dir: str | None,
               reminder: bool, walked: int | None = None, ledger_path: str | None = None,
               campaign: str = "") -> None:
    # r5 (firstmate 770) (3): `walked` is the POPULATION the run walks, never len(payloads). uvn_status sends one user
    # per send_all() call, so len(payloads) was 1 and the systemic bar became max(3, 2% of 1) = 3 threshold against a
    # denominator of 1 - and a family that stopped at 3 of 8 kept walking all 8 because the outer loop never looked.
    walked = len(payloads) if walked is None else max(int(walked), len(payloads))
    # the run's clock when there IS a run (apply_session): QA #1756 Critical. Without it this loop measured the budget
    # from its own call, so N per-user calls each got the whole share and the family overran the tick by N times.
    started = _SESSION_STARTED if (mode == "apply" and _SESSION_STARTED is not None) else time.monotonic()
    for i, p in enumerate(payloads):
        # [key=note-step-budget] (Fable 753): never START a user whose WORST case (the whole retry budget) would not fit
        # in the share this run was given. The rest keep no row at all - they stay owed and unsent, exactly like a user
        # the page never reached - so nothing here is a refusal and nothing is lost; the next tick starts them again.
        # This is what lets the tick size an apply at the EXPECTED cost (40 s) instead of the worst case (200 s): one
        # slow user can overrun the share by at most one retry budget, and only the last one started.
        if mode == "apply" and APPLY_BUDGET_S is not None:
            spent = time.monotonic() - started
            if spent + WORST_USER_S > APPLY_BUDGET_S:
                for rest in payloads[i:]:
                    report.deferred_users += 1
                    report.budget_deferred_users += 1
                    _outcome(report, rest, "deferred",
                             f"apply_budget: {spent:.0f}s of {APPLY_BUDGET_S:.0f}s spent and one note can cost up to "
                             f"{WORST_USER_S:.0f}s; not started, stays owed for the next tick")
                break
        if i and pace_seconds and mode == "apply":
            time.sleep(pace_seconds)
        if mode == "apply":
            hm = head_mismatch()
            if hm:
                global HEAD_REFUSED
                HEAD_REFUSED += 1
                report.deferred_users += 1
                why = _outcome(report, p, "deferred", hm)
                report.deferrals.append(f"user {_uid(p)}: {why}"[:200])
                continue
        # Fable r5 2026-11-06 00:53Z: the hold is HONOURED by every lane, not only by UVN. A user whose own read failed
        # on an earlier tick is skipped with a named deferral until it expires, so the consecutive count can reach the
        # page instead of the same unreadable read being walked every run with no memory of it.
        hold_ukey = str((p.get("user") or {}).get("email") or "").strip().lower()
        if mode == "apply" and ledger_path and campaign:
            hold_until = read_hold_until(ledger_path, campaign, hold_ukey)
            if hold_until:
                report.deferred_users += 1
                report.outcomes.append({"user": _uid(p), "result": "deferred",
                                        "reason": f"read_failed_hold until {hold_until}"})
                report.deferrals.append(f"user {_uid(p)}: read failed on an earlier tick; retry after {hold_until}")
                continue
        fh0 = len(report.failed_held)
        # [key=note-step-timeout] (firstmate 748, the 15:05Z auto-kill): ONE note step that timed out or raised used to
        # propagate out of this loop and abort the run before its outcomes file was written - so the tick saw a missing
        # artefact (and the deployed tick scored that as a refusal spike) and killed itself over a single stall, while
        # the notes it never reached stayed owed. An unknown outcome is now recorded PER USER and the loop continues:
        # the artefact always exists, it names success / timeout / error for every user it touched, and the users it
        # never reached keep no row at all, which the tick reads as UNMEASURED (never as a refusal).
        try:
            res = pre[i] if pre is not None else gate(p)
        except NoteTimeout as exc:
            report.timeout_users += 1
            _outcome(report, p, "timeout", f"{exc}; outcome unknown, never scored as a refusal")
            continue
        except Exception as exc:  # noqa: BLE001 - one user's crash must not cost the batch its artefact
            report.error_users += 1
            _outcome(report, p, "error", f"the gate raised {type(exc).__name__}: {exc}"[:180])
            continue
        if preview_dir and mode != "apply" and res.returncode == 0:
            uid = re.sub(r"[^A-Za-z0-9-]", "", str(p["user"].get("id") or ""))[:64]
            out_path = os.path.join(preview_dir, f"{uid or f'{i + 1:05d}'}.txt")
            fdp = os.open(out_path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
            with os.fdopen(fdp, "w", encoding="utf-8") as fh:
                fh.write(res.stdout)
            # [key=scale-now-openclaw] the batch judge's contract (p1 485 / r5): the RENDERER's own facts for this body,
            # a JSON object beside it - never derived later from the text
            fdf = os.open(out_path[:-4] + ".facts.json", os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
            with os.fdopen(fdf, "w", encoding="utf-8") as fh:
                json.dump(render_facts(p, extra or []), fh)
        out, err = _first_line(res.stdout), _first_line(res.stderr)
        if res.returncode == 0 and out.startswith("RECIPIENT OK"):
            report.recipient_ok += 1
            camp = (extra or [])[(extra or []).index("--campaign") + 1] if "--campaign" in (extra or [])[:-1] else ""
            report.accepted.append({"user": _uid(p), "campaign": camp,
                                    "request_ids": [str(c.get("request_id") or "") for c in p.get("credits") or []],
                                    "gate": out[:300]})
        elif res.returncode == 0 and mode != "apply" and out.startswith(("VALID ", "DRY-RUN ")):
            report.validated += 1
        elif res.returncode == 0 and out.startswith("POSTED") and reminder:
            report.reminders_sent += 1
            camp = (extra or [])[(extra or []).index("--campaign") + 1] if "--campaign" in (extra or [])[:-1] else ""
            report.sent.append({"user": _uid(p), "campaign": camp, "kind": "reminder",      # QA #1606: every POSTED
                                "request_ids": [str(c.get("request_id") or "") for c in p.get("credits") or []],
                                "gate": out[:300]})
        elif res.returncode == 0 and out.startswith("POSTED"):
            report.sent_notes += 1
            camp = (extra or [])[(extra or []).index("--campaign") + 1] if "--campaign" in (extra or [])[:-1] else ""
            report.sent.append({"user": _uid(p), "campaign": camp,
                                "request_ids": [str(c.get("request_id") or "") for c in p.get("credits") or []],
                                "gate": out[:300]})
            try:
                report.sent_credits += int(out.rsplit("credits=", 1)[1].split()[0])
            except (IndexError, ValueError):
                report.sent_credits += len(p["credits"])
        elif getattr(res, "after_timeout", 0) and not _post_failed_line(res.stderr):
            # QA #1756 Important 2 (r12): a timeout was followed by a NON-POSTED answer - and that is every answer but
            # a proven POSTED, not just rc=0. The claim is written before the POST, so "already notified" (rc=0),
            # "REFUSED" (rc=1) and "DEFERRED" (rc=3) can each mean "the timed-out attempt landed" or "it died after
            # claiming"; the run cannot tell them apart. UNMEASURED, never a skip and NEVER a refusal: scoring the
            # rc=1 case as a refusal blames the user for our timeout and can trip the refusal-spike kill, and scoring
            # the rc=3 case as a known deferral asserts a certainty we do not have. The one exception is the gate's
            # explicit POST FAILED line, which is its own unknown (post_failed) and is classified below.
            report.timeout_users += 1
            _outcome(report, p, "timeout",
                     f"a POST attempt timed out and the retry answered rc={res.returncode} {out!r}; the claim may "
                     f"have landed without a note, so the outcome is unknown and it is never scored as a skip or a "
                     f"refusal")
        elif res.returncode == 0:
            report.skipped += 1
            _outcome(report, p, "skipped", out)
        elif res.returncode == 3:
            report.deferred_users += 1
            why = _outcome(report, p, "deferred", out.removeprefix("DEFERRED ") or err)
            # the 7-day USER window is counted on its own, IN ADDITION: the check measures per claim, the send per user,
            # so this is the population a signed 'accepted' set overstates. deferred_users stays what every family
            # already reports; the claim line shows the window separately (deferred_users - held_user_window).
            if "messaged_7d" in why:
                report.held_user_window += 1
                report.window_after_gate += 1        # this one IS in deferred_users above
            report.deferrals.append(f"user {_uid(p)}: {why}"[:200])
        elif _post_failed_line(res.stderr):
            # [key=post-failed-unknown] (QA #1756 Important 2): the gate's POST FAILED line, checked BEFORE the generic
            # failure branches. The real gate prints it and exits 4 (scripts/intercom-verify-request.sh:3603-3606);
            # every other rc=4 is a pre-POST "nothing was sent or claimed" and stays a plain failure. Classifying by
            # the LINE, not the code, is what makes the tick's post_failed arm reachable at all.
            #
            # ONE classification, TWO counters: `_failed(kind="post")` is the single place that records an unknown
            # POST (failed_users, post_failed, post_failures, the `post_failed` outcome row), and
            # `post_failed_users` is the line-level count the tick's arm reads. Bumping only one of them is how the
            # two surfaces drifted apart in the first place.
            report.post_failed_users += 1
            _failed(report, p, _post_failed_line(res.stderr), walked, kind="post")
        elif res.returncode == 1 and _refused_line(res.stderr):
            # the gate's OWN refusal line (r5 on #1515: the first stderr line can be an info line). A refusal before the
            # claim ('nothing was sent or claimed', e.g. G1-G5) has no ledger row by design: recorded as such, by user
            why = _refused_line(res.stderr)
            report.refused_users += 1
            report.refusals.append(why[:160])
            _outcome(report, p, "refused_unledgered" if "nothing was sent or claimed" in why else "refused", why)
        elif res.returncode == 1:
            # rc 1 with no REFUSED line: the gate stopped abnormally - a failure, never a silent 'refused'
            _failed(report, p, f"rc=1 without a REFUSED line: {_failure_text(res, err or out)}", walked)
        elif res.returncode == POST_FAILED_RC or _post_failed_line(res.stderr) or _post_failed_line(res.stdout):
            # (1): the gate's OWN line is the authority for WHAT failed. rc 4 is its documented contract for this
            # (scripts/intercom-verify-request.sh) but an rc alone must never relabel a failed READ as a failed POST:
            # a read that failed under rc 4 would then escape the hold that retries it next tick.
            # the same unknown-POST fact, reached by the CODE (rc=5, or the line on stdout) rather than the stderr
            # line above: the tick's arm reads post_failed_users, so it is bumped here too - never one surface only.
            report.post_failed_users += 1
            _failed(report, p, f"rc={res.returncode} {_failure_text(res, err or out)}", walked, kind="post")
        elif _post_rejected_line(res.stderr) or _post_rejected_line(res.stdout):
            # QA #1780 (Important, 03:07Z): Intercom's error.list answers rc=4 with "POST REJECTED by Intercom (nothing
            # delivered; retried on a later run)" AFTER the reads succeeded. That is not an unreadable read: counting
            # three of them as three consecutive read failures pages a human for the wrong condition and holds a user
            # whose account was perfectly readable. Nothing was delivered, so it is a DEFERRAL (the gate retries it),
            # never a failure and never a read hold.
            why = _post_rejected_line(res.stderr) or _post_rejected_line(res.stdout)
            report.post_rejected += 1
            report.deferred_users += 1
            report.deferrals.append(f"user {_uid(p)}: {why}"[:200])
            _outcome(report, p, "post_rejected", why)
        else:
            _failed(report, p, f"rc={res.returncode} {_failure_text(res, err or out)}", walked)
        # The read worked for this user iff no per-user read hold was recorded for them: a refusal, a deferral or a
        # rejected POST is not a failed read, so the consecutive counter starts over (QA #1780, r8 771 (4)).
        if mode == "apply" and ledger_path and campaign and len(report.failed_held) == fh0:
            clear_read_hold(ledger_path, campaign, hold_ukey)
        if report.stopped_on_failures:
            return


# r8 (firstmate 771) (2): the gate's exit codes are distinct facts. 4 = NOTHING WAS SENT (a pre-send check failed),
# 5 = ATTEMPTED, OUTCOME UNKNOWN (posted, transport failed or the answer could not be verified; row left CLAIMED).
POST_FAILED_RC = 5


def _failed(report: Report, p: dict[str, Any], why: str, walked: int, *, kind: str = "read") -> None:
    """One user's own read or POST failed. Record it PER USER, keep walking, and stop the run only once the failures are
    systemic (r5 / firstmate 764). A held user is a KNOWN outcome; a stopped round is not.

    r5 (firstmate 770) (1): a POST failure is NOT a failed read. The read succeeded and the send did not land - the gate
    exited 4, logged the row and left it CLAIMED, so the outcome is UNKNOWN and the message may already be delivered. It
    is counted (a burst of them is systemic) and rendered, but it never becomes a "read failed" hold: retrying the read
    next tick would be a lie about what failed, and a hold that says "unreadable read" would hide a possible double
    send."""
    report.failed_users += 1
    report.failures.append(why[:300])
    if kind == "post":
        report.post_failed += 1
        report.post_failures.append({"user": _uid(p), "reason": why[:300],
                                     "user_key": str((p.get("user") or {}).get("email") or "").strip().lower()})
        _outcome(report, p, "post_failed", why)
    else:
        report.failed_held.append({"user": _uid(p), "reason": why[:300],
                                   "user_key": str((p.get("user") or {}).get("email") or "").strip().lower()})
        _outcome(report, p, "failed", why)
    stop = fail_stop_after(walked)
    if report.failed_users >= stop and not report.stopped_on_failures:
        report.stopped_on_failures = report.failed_users
        report.failures.append((f"SYSTEMIC: {report.failed_users} of {walked} user(s) failed "
                                f"(>= max({FAIL_STOP_MIN}, {int(FAIL_STOP_SHARE * 100)}%) = {stop}); the run stopped "
                                "here, the users after this one were not walked")[:300])


_ENC_QUERY = re.compile(r"\S*%[0-9A-Fa-f]{2}\S*")          # a URL-encoded query is not an error message


_ERR_HINT = re.compile(r"(FAILED|ERROR|refused|no readable|not set|timed out|Traceback|rc=\d+)", re.I)


def _failure_text(res: Any, fallback: str = "") -> str:
    """The gate's OWN error sentence, never a SQL fragment (r5 / firstmate 764).

    The 22Z tick recorded 'trino rc=1: AS+varchar%29+FROM+postgresql_core.public.claiming+WHERE+userid+IN+%28310729%29
    +AND+updatedat...' - the QUERY, URL-encoded, and the server's answer - the only part a human can act on - was cut
    off at 200 characters by the old first-line-only rule. So: read the whole stderr, keep the line that talks about
    the FAILURE (not an embedded query), and elide any percent-encoded blob. A reader must be able to tell what broke."""
    lines = [ln.strip() for ln in str(getattr(res, "stderr", "") or "").splitlines() if ln.strip()]
    if not lines:
        text = " ".join(str(fallback or getattr(res, "stdout", "") or "").split())
        if not text:
            return f"rc={getattr(res, 'returncode', '?')} with no message"
        return _ENC_QUERY.sub("[query elided]", text)[:300]
    pick = next((ln for ln in lines if _ERR_HINT.search(ln) and not _ENC_QUERY.search(ln)), None) \
        or next((ln for ln in lines if _ERR_HINT.search(ln)), None) or lines[-1]
    return _ENC_QUERY.sub("[query elided]", " ".join(pick.split()))[:300]


def hold_failed_users(db: Any, report: Report, campaign: str, *, now: Any = None) -> int:
    """Record every user whose own send-time read failed (r5 / firstmate 764), so the next tick RETRIES them.

    Fable 2026-11-05 00:1xZ (firstmate 769) replaced the first cut of this: a failed read used to write the
    7-day *refusal* hold, which was wrong twice - an unreadable read is not the user refusing anything, and a
    week-long hold would starve the account over one bad query. The hold now expires at the NEXT TICK
    (``verify_ledger.READ_RETRY_H``), the failure is counted as CONSECUTIVE across ticks, and the third in a
    row pages a human (``READ_FAILURES_TO_PAGE``). Best effort per user: a record that cannot be written is
    reported (flag_failures), never fatal, because the round has already happened."""
    n = 0
    for h in report.failed_held:
        uid = str(h.get("user") or "")
        if not uid.isdigit():
            continue
        key = h.get("user_key") or f"user:{uid}"
        try:
            rec = verify_ledger.record_read_failure(db, campaign=campaign, user_key=key,
                                                    reason=f"read failed: {h.get('reason') or ''}"[:500],
                                                    user_id=uid, now=now)
            n += 1
            if rec.get("page") and verify_ledger.mark_read_failure_paged(db, campaign=campaign, user_key=key, now=now):
                report.read_failure_pages.append(f"user {uid}: {rec['failures']} consecutive failed reads, "
                                                 f"first {rec['first_failed_at']}")
        except Exception as exc:  # noqa: BLE001 - a failed record is reported, never a reason to lose the report
            report.flag_failures.append(f"hold user {uid} failed: {str(exc)[:160]}")
    return n


def read_hold_until(path: str, campaign: str, user_key: str, *, now: Any = None) -> str:
    """The read-failure hold the walk writes is only worth writing if the next walk HONOURS it (r8 / firstmate 771).
    Returns the retry time while the hold is open, "" when there is none - an unreadable ledger is "no hold" (the send
    path re-reads everything anyway), never a reason to stop the walk.

    Fable r5 2026-11-06 00:53Z: this lives HERE, beside ``hold_failed_users``, because the hold is written by every
    runner that calls ``send_all`` and must be honoured by every one of them - not by the UVN lane alone."""
    if not user_key:
        return ""
    try:
        db = verify_ledger.connect(path)
        try:
            row = verify_ledger.read_failure(db, campaign=campaign, user_key=user_key, now=now)
        finally:
            db.close()
    except sqlite3.Error:
        return ""
    return str(row.get("next_retry_at") or "")


def clear_read_hold(path: str, campaign: str, user_key: str) -> None:
    """A SUCCESSFUL read resets the count, so "three CONSECUTIVE failed reads" means three - without this the count
    only ever grew and a flaky account paged on failures from days apart (r8 / firstmate 771)."""
    if not user_key:
        return
    try:
        db = verify_ledger.connect(path)
        try:
            db.execute("DELETE FROM verify_read_failures WHERE campaign=? AND user_key=?", (campaign, user_key))
        finally:
            db.close()
    except sqlite3.Error:
        pass


def finish_failed_reads(db: Any, report: Report, campaign: str, *, mode: str, now: Any = None) -> int:
    """Record every user whose own send-time read failed, for EVERY runner that calls ``send_all``.

    Fable r5 2026-11-06 00:53Z (QA #1780's carried finding): ``hold_failed_users`` had exactly one caller - the UVN
    lane - so on the two daily lanes (``verify-live`` and ``retro-past``) a failed send-time read exited 0, printed
    "held", wrote no ``verify_read_failures`` row, was re-walked by the next run with no consecutive count, and the
    ``READ_FAILURES_TO_PAGE`` page could never fire. The word was false and the alarm was absent.

    APPLY ONLY: a dry run is a read, so it never writes a hold row (Fable 769). Best effort: a record that cannot be
    written is reported (``flag_failures``), never fatal, because the round has already happened."""
    if mode != "apply" or not report.failed_held:
        return 0
    n = hold_failed_users(db, report, campaign, now=now)
    # ``note()`` is the UVN report's by-reason tally; this module's Report has no such counter, so the call is
    # conditional rather than a second Report shape (the hold itself is the record that matters).
    note = getattr(report, "note", None)
    if n and callable(note):
        note("failed_held")
    return n


def _post_failed_line(stderr: str) -> bool:
    """The gate's POST FAILED marker, independent of the exit code (defence in depth: rc 4 is the contract)."""
    return any(ln.strip().startswith("POST FAILED") for ln in (stderr or "").splitlines())


def _post_rejected_line(stderr: str) -> str:
    """The gate's POST REJECTED marker (Intercom refused the POST; NOTHING was delivered), or ''.

    QA #1780: this shares rc=4 with a pre-send check failure, so the LINE - not the code - is what tells a rejected
    POST (a deferral, retried later) from a failed read (a per-user hold)."""
    for ln in (stderr or "").splitlines():
        if ln.strip().startswith("POST REJECTED"):
            return ln.strip()[:200]
    return ""


def _post_failed_line(stderr: str) -> str:
    """The gate's 'POST FAILED ...' line (anywhere in its stderr), without the prefix; '' when there is none.

    [key=post-failed-unknown] The gate writes this ONLY after the POST was attempted and its outcome is unknown
    (scripts/intercom-verify-request.sh:3603). It is the one signal that separates an outcome-unknown send from a
    pre-POST failure, and the tick's post_failed arm keys on the row this produces."""
    for ln in (stderr or "").splitlines():
        if ln.startswith("POST FAILED"):
            return ln.strip()
    return ""


def _refused_line(stderr: str) -> str:
    """The gate's 'REFUSED: <reason>' line (anywhere in its stderr), without the prefix; '' when there is none."""
    for ln in (stderr or "").splitlines():
        if ln.startswith("REFUSED: "):
            return ln.removeprefix("REFUSED: ").strip()
    return ""


def _uid(p: dict[str, Any]) -> str:
    return re.sub(r"[^A-Za-z0-9-]", "", str((p.get("user") or {}).get("id") or ""))[:64] or "?"


def _outcome(report: Report, p: dict[str, Any], result: str, reason: str) -> str:
    """Record one per-user gate answer that was not a send (C11): the user, the result and the gate's own first line;
    a gate that gave no line is recorded as such, never dropped."""
    why = (reason or "").strip()[:200] or "(the gate printed no reason)"
    report.outcomes.append({"user": _uid(p), "result": result, "reason": why})
    return why


AUTH_ID_RE = re.compile(r"^[A-Za-z0-9._-]{1,128}$")
PRO_ID_RE = re.compile(r"^[A-Za-z0-9._|-]{1,128}$")


_odd_array_logged = False


def pg_text_array(raw: Any) -> str:
    """credit_requests.credits as Trino returns it: a Postgres text[] LITERAL in a varchar
    (e.g. '{"Record Label"}' or '{Mixing,"Mastering Engineer"}'; Trino cannot CAST it to
    array(varchar)). Returns the roles joined with ', ' ('' when NULL or empty). Any other
    shape is '' too (no role: the request is left out of the uvn-status note, its user held only
    when nothing else is showable, and refused by withdrawal-confirm), logged once per process."""
    global _odd_array_logged
    s = str(raw or "").strip()
    if not s:
        return ""
    if not (s.startswith("{") and s.endswith("}")):
        if not _odd_array_logged:
            _odd_array_logged = True
            from .runner import log
            log(f"credit_requests.credits is not a Postgres text[] literal ({s[:60]!r}); "
                "its request reads as having no role")
        return ""
    body, out, cur, quoted, esc, had = s[1:-1], [], [], False, False, False
    for ch in body:
        if esc:
            cur.append(ch)
            esc = False
        elif ch == "\\":
            esc = True
        elif ch == '"':
            quoted = not quoted
            had = True
        elif ch == "," and not quoted:
            out.append("".join(cur))
            cur, had = [], False
        else:
            cur.append(ch)
    if cur or had or out:
        out.append("".join(cur))
    vals = [v.strip() for v in out]
    return ", ".join(v for v in vals if v and v.upper() != "NULL")


def professional_id(raw: Any) -> str:
    """users.neptuneprofessionalid, the id the web app boots Intercom with (its contact
    external_id, firstmate 090): the gate's user.professional_id; '' when missing or malformed."""
    v = str(raw or "").strip()
    return v if PRO_ID_RE.fullmatch(v) else ""


def account_identities(user_ids: list[Any], query: Query | None = None) -> dict[str, dict[str, str]]:
    """{muso user id: {professional_id, auth_id}} from the core replica (Trino, read only)."""
    ids = sorted({int(u) for u in user_ids if str(u).isdigit()})
    out: dict[str, dict[str, str]] = {}
    for i in range(0, len(ids), 500):
        chunk = ",".join(str(u) for u in ids[i:i + 500])
        for uid, pro, auth in (query or (lambda q: trino(q, AUTH_LOOKUP_CMD)))(
                "SELECT CAST(id AS varchar), neptuneprofessionalid, auth0userid FROM postgresql_core.public.users "
                f"WHERE id IN ({chunk})"):
            out[str(uid)] = {"professional_id": professional_id(pro), "auth_id": auth_subject(auth)}
    return out


IDENTITY_LOOKUP: Callable[[list[Any]], dict[str, dict[str, str]]] = account_identities


def account_presented_ids(user_ids: list[Any], query: Query | None = None) -> dict[str, list[str]]:
    """{muso user id: [presented profile ids]} (r5, credit_review.identity_resolver): the account's
    processed claims and representation profile that resolve to exactly that account. The mobile app
    logs into Intercom with the presented profile, so these are also this account's Intercom identity."""
    from . import identity_resolver  # noqa: PLC0415 - kept lazy, like the replica itself
    return identity_resolver.presented_ids(user_ids, query or (lambda q: trino(q, AUTH_LOOKUP_CMD)))


PRESENTED_LOOKUP: Callable[[list[Any]], dict[str, list[str]]] = account_presented_ids
_presented_unread_logged = False


def _with_presented(payloads: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """Each payload naming a Muso user gets user.presented_ids (only when it has any). Additive: the
    gate only ever WIDENS the account's own Intercom contacts with them, so an unreadable lookup
    leaves today's behaviour (professional id / Auth0 subject only), logged once."""
    global _presented_unread_logged
    uids = sorted({str(p["user"].get("id") or "") for p in payloads
                   if str(p["user"].get("id") or "").isdigit() and "presented_ids" not in p["user"]})
    if not uids:
        return payloads
    try:
        found = PRESENTED_LOOKUP(uids) or {}
    except Exception as exc:  # noqa: BLE001 - additive identity: degrade to today's matcher
        if not _presented_unread_logged:
            _presented_unread_logged = True
            from .runner import log
            log(f"presented profile ids unreadable ({str(exc)[:160]}); recipients matched by professional id only")
        return payloads
    out = []
    for p in payloads:
        ids = [x for x in (found.get(str(p["user"].get("id") or "")) or []) if PRO_ID_RE.fullmatch(str(x))]
        out.append({**p, "user": {**p["user"], "presented_ids": ids}} if ids and "presented_ids" not in p["user"] else p)
    return out


def attach_identities(payloads: list[dict[str, Any]], report: Report
                      ) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    """(payloads, held): each payload naming a Muso user (user.id) without user.professional_id
    gets the account's professional id and Auth0 subject from the replica; one without a
    professional id is held (report.no_professional_id), never handed to the gate. Payloads
    naming no user (a removal notice's profile owner) pass unchanged. A replica read error
    propagates: the caller sends nothing."""
    need = {id(p) for p in payloads if str(p["user"].get("id") or "") and "professional_id" not in p["user"]}
    if not need:
        return _with_presented(payloads), []
    found = IDENTITY_LOOKUP([p["user"]["id"] for p in payloads if id(p) in need])
    out: list[dict[str, Any]] = []
    held: list[dict[str, Any]] = []
    for p in payloads:
        if id(p) in need:
            ident = found.get(str(p["user"]["id"])) or {}
            if not ident.get("professional_id"):
                report.no_professional_id += 1
                held.append(p)
                continue
            p = {**p, "user": {**p["user"], "professional_id": ident["professional_id"],
                               "auth_id": ident.get("auth_id", "")}}
        out.append(p)
    return _with_presented(out), held


def auth_subject(raw: Any) -> str:
    """The account's Auth0 subject (core users.auth0userid without its auth0| prefix), the
    gate's user.auth_id; '' when missing or malformed (the driver holds that user)."""
    v = re.sub(r"^auth0\|", "", str(raw or "").strip())
    return v if AUTH_ID_RE.fullmatch(v) else ""


SLACK_LIB = os.environ.get("CREDIT_REVIEW_SLACK_LIB",
                           os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "lib", "slack-notify.sh"))
CS_PRIORITY_CHANNEL = "C0BBTAVP44X"  # #cs_priority (only the operations bot is a member)
Poster = Callable[[str], bool]
_EMAIL_RE = re.compile(r"[^\s@<>]+@[^\s@<>]+")


def post_cs_priority(text: str) -> bool:
    """One plain-text post to #cs_priority through scripts/lib/slack-notify.sh (operations bot).
    True only when Slack confirmed it."""
    fd, path = tempfile.mkstemp(prefix="credit-review-flag-", suffix=".json")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            json.dump({"channel": CS_PRIORITY_CHANNEL, "text": text}, fh)
        p = subprocess.run(["bash", "-c", 'source "$1" && slack_notify_payload_file_status "$2"', "slack-flag", SLACK_LIB, path],
                           capture_output=True, text=True, timeout=120, check=False,
                           env={**os.environ, "SLACK_NOTIFY_BOT": "operations",
                                "SLACK_NOTIFY_REQUESTER": "credit-review@hydra-ops"})
        return p.returncode == 0
    finally:
        os.unlink(path)


def flag_refusals(report: Report, *, ledger_path: str, campaigns: list[str] | tuple[str, ...],
                  post: Poster = post_cs_priority, now: datetime | None = None) -> None:
    """Post each re-checkable refusal refused MAX_REFUSALS times to #cs_priority once (Muso user
    id, campaign, reason; never the email) and block it. A failed post leaves it un-flagged
    (retried next run) and is a run failure."""
    db = verify_ledger.connect(ledger_path)
    try:
        for e in verify_ledger.refusals_to_flag(db, campaigns):
            reason = _EMAIL_RE.sub("<email>", e["reason"])[:300]
            text = (f"Caroline's gate refused the {e['campaign']} note for Muso user {e['user_id'] or '(unknown id)'} "
                    f"{e['refusals']} times, {verify_ledger.RECHECK_DAYS} days apart; it is no longer retried and "
                    f"needs a human. Last reason: {reason}")
            if post(text):
                verify_ledger.mark_flagged(db, campaign=e["campaign"], user_key=e["user_key"], now=now)
                report.flagged += 1
            else:
                report.flag_failures.append(f"#cs_priority post failed for user {e['user_id']} ({e['campaign']})")
    finally:
        db.close()


def audit_documents(payloads: list[dict[str, Any]], report: Report, *, path: str, campaign: str,
                    wrapper: str = WRAPPER, runner: Runner = _run) -> None:
    """Read-only: ask the gate (--doc-check) whether each account already sent
    documents. Writes user_id,credits,result (no email) to `path` (0600). The recipient is
    matched like a send (attach_identities): an account without a professional id is held."""
    import csv
    try:
        found, _ = attach_identities(payloads, report)
    except Exception as exc:  # noqa: BLE001 - an unreadable replica checks nothing
        report.halted = f"the accounts' professional ids cannot be read from the replica ({exc}); nothing was checked"[:300]
        return
    kept = {str(p["user"].get("id") or "") for p in found}
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", newline="", encoding="utf-8") as fh:
        w = csv.writer(fh)
        w.writerow(["user_id", "credits", "result"])
        for p in payloads:
            if str(p["user"].get("id") or "") not in kept:
                w.writerow([p["user"].get("id") or "", len(p["credits"]), "held: no professional id on the account"])
        for p in found:
            tfd, tmp = tempfile.mkstemp(prefix="verify-doc-check-", suffix=".json")
            try:
                with os.fdopen(tfd, "w", encoding="utf-8") as tf:
                    json.dump({"user": p["user"], "credits": p["credits"]}, tf, ensure_ascii=False)
                res = runner([wrapper, "send", "--credits-file", tmp, "--approved-by", CAPTAIN_UID,
                              "--campaign", campaign, "--doc-check"])
            finally:
                os.unlink(tmp)
            out = _first_line(res.stdout)
            if res.returncode == 0 and out.startswith("DOCS"):
                result = "docs"
                report.docs_users += 1
            elif res.returncode == 0 and out.startswith("NO_DOCS"):
                result = "no_docs"
            elif res.returncode == 1:
                result = "refused: " + _first_line(res.stderr).removeprefix("REFUSED: ")[:120]
            else:
                result = f"error rc={res.returncode}"
                report.failed_users += 1
                report.failures.append(f"doc-check rc={res.returncode} {_first_line(res.stderr) or out}"[:200])
            report.docs_checked += 1
            w.writerow([p["user"].get("id") or "", len(p["credits"]), result])


def sweep_proofs(db: sqlite3.Connection, report: Report, *, days: int = 30, limit: int = 100,
                 wrapper: str = WRAPPER, runner: Runner = _run) -> None:
    for mid in verify_ledger.awaiting_proof(db, days=days)[:limit]:
        row = verify_ledger.message(db, mid)
        claim = row is not None and row["campaign"] in verify_ledger.CLAIM_CAMPAIGNS
        res = runner([wrapper, "tag-proof", "--message-id", mid])
        verify_ledger.mark_checked(db, message_id=mid)
        lines = res.stdout.strip().splitlines()
        if any(ln.startswith("REPLY RECORDED") for ln in lines):
            if claim:
                report.claim_replies += 1
            else:
                report.extension_requests += 1
        out = next((ln[:200] for ln in lines if not ln.startswith("REPLY RECORDED")), "")
        if res.returncode == 0 and out.startswith("TAGGED") and claim:
            report.claim_proof_tagged += 1
        elif res.returncode == 0 and out.startswith("TAGGED"):
            report.proof_tagged += 1
        elif res.returncode in (0, 3):
            continue
        else:
            report.proof_failed += 1
            report.failures.append(f"tag-proof {mid} rc={res.returncode} {_first_line(res.stderr) or out}"[:200])


def send_followups(db: sqlite3.Connection, admin: admin_api.Admin, report: Report, *, campaign: str, day: str,
                   documented: ProofOnFile, verdicts: dict[str, dict[str, Any]], limit: int, pace_seconds: float,
                   wrapper: str, runner: Runner) -> int:
    """Every follow-up the ledger says is due today: re-read the note's credits and
    send the gate's fixed follow-up for the ones still live, under the same per-credit
    documents rule as the note (screen_live): a credit with its own document on file or
    approved by a person is left out, and a user with a document under review waits.
    The org-affiliation gate applies to a follow-up exactly as to a note (QA review of
    hydra#1257 @53428d0): an unchecked, partially checked or affiliated user gets no automatic
    reminder; it waits (not closed) for the next run. A follow-up with nothing left to send is
    closed in the ledger; only follow-ups that are sent count against `limit`."""
    attempted = 0
    for mid, kind, refs in verify_ledger.reminders_due(db, campaign=campaign, day=day):
        if attempted >= limit:
            break
        wanted = [(str(r.get("request_id")), str(r.get("profile_id") or ""), str(r.get("track_id") or ""))
                  for r in refs if r.get("profile_id")]
        live, _ = reread(admin, wanted) if wanted else ({}, set())
        _, held = screen_live(live, documented, report)
        if held or hold_affiliated(live, verdicts, report):
            continue
        ps = plan(live, report)
        if not ps:
            verify_ledger.close_reminder(db, parent_message_id=mid, kind=kind, day=day,
                                         reason="nothing left to send: every credit documented, approved by a "
                                                "person, no longer approved or not announceable")
            continue
        attempted += len(ps)
        for p in ps:
            p["extra"] = ["--kind", kind, "--parent-message-id", mid]
        send_all(ps, report, mode="apply", wrapper=wrapper, runner=runner,
                 extra=["--campaign", campaign], pace_seconds=pace_seconds, reminder=True)
    return attempted


AFFILIATION_LANE = "credit-trust-llm-t01"


def write_affiliation_priority(db: sqlite3.Connection, *, directory: str | None = None) -> tuple[str, int]:
    """Ask the org-affiliation producer for a FULL check of everyone the next verify-notify
    run may write to: the account users of every candidate credit (decider-approved and not
    yet notified, plus held-back ones), from the decider's decisions.user_id. Called after
    every decider apply run, so the hourly producer has them well before 09:00 Rome.
    Returns (path, number of users)."""
    rids = [rid for rid, _, _ in candidates(db, since_hours=None)]
    uids: set[int] = set()
    for i in range(0, len(rids), 500):
        part = rids[i:i + 500]
        q = f"SELECT DISTINCT user_id FROM decisions WHERE user_id IS NOT NULL AND request_id IN ({','.join('?' * len(part))})"
        uids |= {int(u) for (u,) in db.execute(q, part)}
    path = affiliation.write_priority(AFFILIATION_LANE, uids, directory=directory,
                                      source="credit-trust-llm-t01: verify-notify candidates (decider-approved, not yet noted)")
    return path, len(uids)


def _ref(req: dict[str, Any]) -> tuple[str, str, str]:
    return (str(req.get("id")), str(req.get("profileId") or ""), str(req.get("trackId") or ""))


def hold_affiliated(rows: dict[str, dict[str, Any]], verdicts: dict[str, dict[str, Any]],
                    report: Report) -> list[tuple[str, str, str]]:
    """RULE-org-affiliation: a user with no verdict, or a contributor / verified_org /
    authenticated_domain one, gets no automatic note; listed for a human (polite-contact
    variant). In place; returns the held credits (offered again, nothing closed)."""
    held: list[tuple[str, str, str]] = []
    why_by_user: dict[str, str] = {}
    for rid in list(rows):
        uid = _user_id(rows[rid])
        why = affiliation.hold_reason(verdicts, uid)
        if why:
            held.append(_ref(rows.pop(rid)))
            why_by_user[uid] = why
    report.affiliation_held += [f"user {u}: {w}" for u, w in sorted(why_by_user.items())]
    return held


def hold_recently_asked(db: sqlite3.Connection, payloads: list[dict[str, Any]], rows_by_id: dict[str, dict[str, Any]],
                        report: Report, *, day: str) -> tuple[list[dict[str, Any]], list[tuple[str, str, str]]]:
    """One note per user per 90 days across verify-live and retro-past (the ledger's
    asked_within; the claim enforces it again at the write). Returns (payloads to send,
    credits that wait)."""
    keep: list[dict[str, Any]] = []
    held: list[tuple[str, str, str]] = []
    for p in payloads:
        if verify_ledger.asked_within(db, user_key=p["user"]["email"], day=day, user_id=str(p["user"].get("id") or "")):
            report.recently_asked_users += 1
            report.recently_asked_credits += len(p["credits"])
            held += [_ref(rows_by_id[c["request_id"]]) for c in p["credits"] if c["request_id"] in rows_by_id]
        else:
            keep.append(p)
    return keep, held


PROVISIONAL_KIND = verify_ledger.PROVISIONAL_KIND


def provisional_ids(db: sqlite3.Connection, request_ids: list[str]) -> set[str]:
    """Credits the decider approved as a PAID PROVISIONAL approval (Fable ruling 4): their note
    is the no-threat v1 copy (no date, no removal language) and they are never removal-due
    (firstmate 073). Read from the decider ledger (verify_ledger.provisional_ids)."""
    return verify_ledger.provisional_ids(db, request_ids)


def provisional_copy(payloads: list[dict[str, Any]], prov: set[str], report: "Report | None" = None
                     ) -> list[dict[str, Any]]:
    """Every note is the no-threat v1 copy (firstmate 090, 2026-10-19 23:27Z: the captain dropped
    auto-removal; NO message may say a credit will be removed or name a deadline). One note per
    user (the 90-day re-ask lock). `prov` only feeds the report: users whose note includes a paid
    provisional credit alongside other new credits."""
    out: list[dict[str, Any]] = []
    for p in payloads:
        ids = {c["request_id"] for c in p["credits"]}
        if report is not None and ids & prov and ids - prov:
            report.mixed_v1_users += 1
        out.append({**p, "extra": ["--copy", "v1"]})
    return out


def paid_first(payloads: list[dict[str, Any]], paying: frozenset[int] | None) -> list[dict[str, Any]]:
    """Paying users' notes first (stable: oldest credit first within each group)."""
    if paying is None:
        return payloads
    def is_paying(p: dict[str, Any]) -> bool:
        uid = str(p["user"].get("id") or "")
        return uid.isdigit() and int(uid) in paying
    return sorted(payloads, key=lambda p: not is_paying(p))


def run(admin: admin_api.Admin, *, ledger_path: str | None = None, mode: str = "apply", run_id: str | None = None,
        since_hours: int | None = 168, max_users: int = 150, proof_path: str | None = None,
        sweep: bool = True, wrapper: str = WRAPPER, runner: Runner = _run,
        affiliation_path: str | None = None, check_recipients: bool = False,
        never_asked_days: int | None = NEVER_ASKED_DAYS) -> Report:
    """The whole step, once a day (09:00 Europe/Rome). `max_users` is the day's cap on
    messages, reminders included (they go first: the note promised them). Gates, in order:
    proof on file from any source, the support@ 90-day contacts, org affiliation, the shared
    90-day re-ask lock; then paying users first. Any gate source that cannot be read halts
    the run: nothing is sent."""
    report = Report()
    try:
        documented = load_proof_on_file(proof_path)
    except ProofFileError as exc:
        report.halted = str(exc)
        return report
    try:
        verdicts = affiliation.read(affiliation_path)
    except (OSError, ValueError) as exc:
        report.halted = f"the org-affiliation verdicts cannot be read ({exc}); nothing is sent"[:300]
        return report
    from .decide import paying_users  # noqa: PLC0415 (decide imports nothing from here)
    paying, why_paying = paying_users()
    report.paying_unknown = why_paying or ""
    day = datetime.now(timezone.utc).strftime("%Y-%m-%d")
    db = verify_ledger.connect(ledger_path or verify_ledger.DEFAULT_PATH)
    try:
        # The day's cap counts what the ledger already holds for today (a same-day retry or a
        # second invocation never gets a fresh cap), reminders included.
        budget = max(max_users - verify_ledger.messages_today(db, campaign="verify-live", day=day), 0)
        report.already_today = max_users - budget
        if mode == "apply":
            # Day-14 / day-25 reminders of WINDOWED notes count against the day's cap.
            budget -= send_followups(db, admin, report, campaign="verify-live", day=day, documented=documented,
                                     verdicts=verdicts, limit=budget, pace_seconds=0.0, wrapper=wrapper,
                                     runner=runner)
        wanted = candidates(db, run_id=run_id, since_hours=since_hours, never_asked_days=never_asked_days)
        report.candidates = len(wanted)
        if wanted:
            was_held = {rid for rid, _, _ in verify_ledger.deferred(db, campaign="verify-live")}
            rows, missing = reread(admin, wanted)
            report.not_approved_now = len(missing)
            by_id = dict(rows)
            dropped, held = screen_live(rows, documented, report)
            held += hold_affiliated(rows, verdicts, report)
            dropped += sorted(missing & was_held)
            payloads = plan(rows, report, dropped=dropped)
            payloads, waiting = hold_recently_asked(db, payloads, by_id, report, day=day)
            held += waiting
            payloads = provisional_copy(paid_first(payloads, paying), provisional_ids(db, list(by_id)), report)
            # Paying status unknown (QA review of hydra#1257 @3b5fea9): when today's cap would
            # have to choose who goes first, nothing is sent, so a paying user is never pushed
            # behind older free accounts. Every credit waits for tomorrow (kept, not closed).
            if paying is None and len(payloads) > max(budget, 0):
                report.paying_hold = (f"paying status unknown ({why_paying}) and {len(payloads)} note(s) exceed today's "
                                      f"cap of {max(budget, 0)}: nothing sent, so paying users are never put behind")
                for p in payloads:
                    held += [_ref(by_id[c["request_id"]]) for c in p["credits"] if c["request_id"] in by_id]
                payloads = []
            # The Intercom recipient is matched to the account by its professional id or Auth0
            # subject (the contact's external_id). Neither = cannot verify the recipient: held,
            # never handed to the gate (whose refusal would close the credits for good).
            try:
                payloads, no_id = attach_identities(payloads, report)
            except Exception as exc:  # noqa: BLE001 - an unreadable replica sends nothing
                report.halted = f"the accounts' professional ids cannot be read from the replica ({exc}); nothing is sent"[:300]
                for p in payloads:
                    held += [_ref(by_id[c["request_id"]]) for c in p["credits"] if c["request_id"] in by_id]
                payloads, no_id = [], []
            for p in no_id:
                held += [_ref(by_id[c["request_id"]]) for c in p["credits"] if c["request_id"] in by_id]
            # Over the day's cap: the credits wait for tomorrow (kept in the ledger, so a
            # credit older than the candidate window is never silently dropped).
            for p in payloads[max(budget, 0):]:
                held += [_ref(by_id[c["request_id"]]) for c in p["credits"] if c["request_id"] in by_id]
            payloads = payloads[:max(budget, 0)]
            if mode == "apply" and dropped:
                verify_ledger.skip_requests(db, campaign="verify-live", request_ids=dropped)
            if mode == "apply" and held:
                verify_ledger.defer(db, campaign="verify-live", refs=held)
            report.users = len(payloads)
            send_all(payloads, report, mode=mode, wrapper=wrapper, runner=runner, check_recipients=check_recipients,
                     ledger_path=ledger_path or verify_ledger.DEFAULT_PATH, campaign="verify-live")
            # Fable r5 2026-11-06 00:53Z: this lane holds its own failed reads too. Without this a failed send-time
            # read exited 0, printed "held", wrote no row and could never page - the exact defect class #1780 closes.
            finish_failed_reads(db, report, "verify-live", mode=mode)
        if sweep and mode == "apply":
            sweep_proofs(db, report, days=45, wrapper=wrapper, runner=runner)
        if mode == "apply":
            report.removal_due = len(undocumented_removal_due(db, documented, day=day))
            report.held_for_human = len(undocumented_removal_due(db, documented, day=day, held=True))
    finally:
        db.close()
    return report


# -- retro-past documentation waves (captain 2026-10-15 23:35Z, narrowed 2026-10-16 00:35Z:
# "i dont want to lose users unless its obvious fraud feom tbe past", and 02:00Z: "are you
# annoying people fornbackup that we shpuldnt be?") ------------------------------------
# A no-threat ask to the genuine-risk population in the wave file: no deadline, no
# removal, at most one message per user ever, none to a user who already sent proof.
# Non-response = the credit stays, flagged unverified for the board
# (verify_ledger.unverified_past). Proven fraud is removed by its own take-back path.

CAMPAIGN_RETRO = "retro-past"
WAVE_REQUIRED = ("credit_request_id", "user_id", "profile_id")
BIG_POP = 60


@dataclass
class WaveRow:
    request_id: str
    user_id: str
    profile_id: str
    track_id: str = ""
    tier: str = ""
    pop: int = -1
    paid: bool = False
    claimed: str = ""


def _int(v: Any) -> int:
    try:
        return int(float(str(v)))
    except (TypeError, ValueError):
        return -1


def load_exclusions(path: str | None) -> frozenset[str]:
    """User ids, one per line ('#' comments allowed): accounts whose existing credits
    are handled elsewhere and must never get a past-credit ask."""
    if not path:
        return frozenset()
    out: set[str] = set()
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            uid = line.split("#", 1)[0].strip()
            if uid:
                out.add(uid)
    return frozenset(out)


def load_wave(path: str, *, exclude: frozenset[str] = frozenset(), report: Report | None = None) -> list[WaveRow]:
    """The wave file (the population): CSV, one row per credit request (or per request
    x role; rows are merged per request). Required columns: credit_request_id, user_id,
    profile_id. Optional: track_id, tier, pop_now / pop_at_claim (big = >= 60), paid
    (1/true/yes), claim_date / approved_at. Users in `exclude` are dropped."""
    import csv
    with open(path, newline="", encoding="utf-8") as fh:
        reader = csv.DictReader(fh)
        missing = [c for c in WAVE_REQUIRED if c not in (reader.fieldnames or [])]
        if missing:
            raise ContractError(f"wave file {path} lacks {', '.join(missing)} (see credit_review/verify_notify.py load_wave)")
        rows: dict[str, WaveRow] = {}
        for r in reader:
            rid = (r.get("credit_request_id") or "").strip()
            uid = (r.get("user_id") or "").strip()
            if not rid or not uid:
                continue
            tier = (r.get("tier") or "").strip()
            if uid in exclude:
                if report is not None and rid not in rows:
                    report.excluded += 1
                continue
            pop = max(_int(r.get("pop_now")), _int(r.get("pop_at_claim")))
            w = rows.get(rid)
            if w is None:
                rows[rid] = WaveRow(rid, uid, (r.get("profile_id") or "").strip(), (r.get("track_id") or "").strip(),
                                    tier, pop, str(r.get("paid") or "").strip().lower() in ("1", "true", "yes", "y"),
                                    (r.get("claim_date") or r.get("approved_at") or "").strip())
            else:
                w.pop = max(w.pop, pop)
    return list(rows.values())


def wave_order(rows: list[WaveRow]) -> list[str]:
    """User ids, paid users first, then users with a big track, then the oldest claim."""
    users: dict[str, list[WaveRow]] = {}
    for w in rows:
        users.setdefault(w.user_id, []).append(w)

    def key(uid: str) -> tuple[Any, ...]:
        ws = users[uid]
        return (not any(w.paid for w in ws), not any(w.pop >= BIG_POP for w in ws), min(w.claimed for w in ws), uid)
    return sorted(users, key=key)


def run_wave(admin: admin_api.Admin, *, wave_path: str, ledger_path: str | None = None, mode: str = "dry-run",
             exclude: frozenset[str] = frozenset(), max_users: int = 100, daily_max_notes: int = 600,
             pace_seconds: float = 1.0, sweep: bool = True, preview_dir: str | None = None, today: str | None = None,
             audit_docs: str | None = None, proof_path: str | None = None,
             wrapper: str = WRAPPER, runner: Runner = _run) -> Report:
    """One wave tick: the one note for each of the next users (paid first, big tracks
    first, within the per-run and per-day budgets), then the proof sweep. Every note goes through intercom-verify-request.sh --campaign
    retro-past (send-locked until its copy is approved; dry-run renders it)."""
    report = Report()
    day = today or datetime.now(timezone.utc).strftime("%Y-%m-%d")
    try:
        documented = load_proof_on_file(proof_path)
    except ProofFileError as exc:
        report.halted = str(exc)
        return report
    db = verify_ledger.connect(ledger_path or verify_ledger.DEFAULT_PATH)
    try:
        rows = load_wave(wave_path, exclude=exclude, report=report)
        # Documents already on file: never asked. Dropped before picking, so these users
        # never take a slot of the per-run budget; closed on a real run.
        on_file = [w.request_id for w in rows if w.user_id in documented]
        if on_file:
            report.proof_on_file += len(on_file)
            rows = [w for w in rows if w.user_id not in documented]
            if mode == "apply":
                verify_ledger.skip_requests(db, campaign=CAMPAIGN_RETRO, request_ids=on_file)
        blocked = verify_ledger.blocked_ids(db, [w.request_id for w in rows], CAMPAIGN_RETRO)
        rows = [w for w in rows if w.request_id not in blocked]
        report.candidates = len(rows)
        budget = max(0, min(max_users, daily_max_notes - verify_ledger.sent_today(db, campaign=CAMPAIGN_RETRO, day=day)))
        if mode != "apply":
            budget = max_users
        chosen = set(wave_order(rows)[:budget])
        pick = [w for w in rows if w.user_id in chosen]
        by_id = {w.request_id: w for w in pick}
        if pick:
            live, missing = reread(admin, [(w.request_id, w.profile_id, w.track_id) for w in pick])
            report.not_approved_now = len(missing)
            people = drop_human_approved(live, report) + drop_documented(live, documented, report)
            if mode == "apply" and people:
                report.skipped_not_live += verify_ledger.skip_requests(db, campaign=CAMPAIGN_RETRO, request_ids=people)
            if mode == "apply" and missing:
                report.skipped_not_live += verify_ledger.skip_requests(db, campaign=CAMPAIGN_RETRO, request_ids=sorted(missing))
            rank = {uid: i for i, uid in enumerate(wave_order(pick))}

            def key(req: dict[str, Any]) -> tuple[Any, ...]:
                w = by_id[str(req.get("id"))]
                return (rank.get(w.user_id, 10**9), -w.pop, w.claimed, w.request_id)
            dropped: list[str] = []
            payloads = plan(live, report, key=key, dropped=dropped)
            if mode == "apply" and dropped:
                # Not announceable (no account email / title / artist): close them so these
                # users never take a slot of the per-run budget again.
                report.skipped_not_live += verify_ledger.skip_requests(db, campaign=CAMPAIGN_RETRO, request_ids=dropped)
            report.users = len(payloads)
            if audit_docs and mode != "apply":
                audit_documents(payloads, report, path=audit_docs, campaign=CAMPAIGN_RETRO, wrapper=wrapper,
                                runner=runner)
            else:
                send_all(payloads, report, mode=mode, wrapper=wrapper, runner=runner,
                         extra=["--campaign", CAMPAIGN_RETRO], pace_seconds=pace_seconds, preview_dir=preview_dir,
                         ledger_path=ledger_path or verify_ledger.DEFAULT_PATH, campaign=CAMPAIGN_RETRO)
                # Fable r5 2026-11-06 00:53Z: the retro lane holds its own failed reads, same as verify-live.
                finish_failed_reads(db, report, CAMPAIGN_RETRO, mode=mode)
        if sweep and mode == "apply":
            sweep_proofs(db, report, days=45, wrapper=wrapper, runner=runner)
        report.unverified = len(verify_ledger.unverified_past(db, day=day))
    finally:
        db.close()
    return report


# -- removal notices (firstmate 2026-10-16 15:14Z, captain-driven) --------------------------
# Owners of previously approved credits that WE removed are told which credit and role, why
# and how to dispute. Self-removals are never notified (they did it), and fraud removals are
# silent by captain order (firstmate 15:48Z). One message per owner, batched; idempotent per
# removal event (the verify ledger, campaign removal-notice). Send-locked in the gate.

CAMPAIGN_REMOVAL = "removal-notice"
REMOVAL_REASONS = ("misattributed", "duplicate", "policy")  # "verification" is manual_only (Fable 2026-10-17)
POLICY_REASONS = ("artist_by_non_artist", "org_on_person", "label_role_without_release", "duplicate_profile")
SOURCE_LABELS = ("Spotify credits", "Tidal credits", "Qobuz credits page", "Apple Music credits", "Discogs",
                 "AllMusic", "MusicBrainz")   # no Jaxsta in user copy (captain 03:2xZ)
SELF_ACTORS = frozenset({"self", "owner", "user"})
# The gate's per-credit rules for a removal notice, applied per event here so one bad event
# never refuses its owner's whole batch.
EVENT_ID_RE = re.compile(r"[A-Za-z0-9-]{1,64}")
EVIDENCE_URL_RE = re.compile(r"https://[A-Za-z0-9.-]+(/\S*)?")
INTERNAL_URL_RE = re.compile(r"https://([A-Za-z0-9-]+\.)*(muso\.ai|clickup\.com|slack\.com|intercom\.io|github\.com|"
                             r"gitlab\.com)(/.*)?", re.S)


def _clean(v: Any) -> str:
    return " ".join(str(v or "").split())


def removal_event_problem(ev: dict[str, Any]) -> str:
    """Why the gate would refuse this event ('' when it would not)."""
    if not EVENT_ID_RE.fullmatch(_clean(ev.get("event_id"))):
        return "event_id must be letters, digits and dashes (at most 64)"
    reason = _clean(ev.get("reason")).lower()
    if reason == "verification":
        return "reason 'verification' is manual_only: a named human sends it from the board"
    if reason not in REMOVAL_REASONS:
        return f"unknown reason {reason[:40]!r} (use {', '.join(REMOVAL_REASONS)})"
    if reason == "policy" and _clean(ev.get("policy_reason")).lower() not in POLICY_REASONS:
        return f"a policy removal needs a policy_reason ({', '.join(POLICY_REASONS)}); otherwise it is manual_only"
    if reason == "misattributed" and _clean(ev.get("source_label")) not in SOURCE_LABELS:
        return f"a misattribution needs the real source_label ({', '.join(SOURCE_LABELS)})"
    if len(_clean(ev.get("role"))) > 120 or len(_clean(ev.get("track_title"))) > 200 \
            or len(_clean(ev.get("artist_name"))) > 200:
        return "role, track_title or artist_name exceeds the length caps (120, 200, 200)"
    url = _clean(ev.get("evidence_url"))
    if url and (len(url) > 300 or not EVIDENCE_URL_RE.fullmatch(url)):
        return "evidence_url is not a plain https URL of at most 300 characters"
    if url and INTERNAL_URL_RE.fullmatch(url):
        return "evidence_url points at an internal or Muso surface"
    return ""


def load_removal_events(path: str) -> list[dict[str, Any]]:
    """JSON lines: {event_id, profile_id, track_id?, role, track_title, artist_name, reason,
    evidence_url?, actor, removed_at?}. One line per removed (track, role) credit."""
    out: list[dict[str, Any]] = []
    with open(path, encoding="utf-8") as fh:
        for n, line in enumerate(fh, 1):
            line = line.strip()
            if not line:
                continue
            try:
                ev = json.loads(line)
            except json.JSONDecodeError as exc:
                raise ContractError(f"removal events {path} line {n} is not JSON") from exc
            missing = [k for k in ("event_id", "profile_id", "role", "track_title", "artist_name", "reason", "actor")
                       if not str(ev.get(k) or "").strip()]
            if missing:
                raise ContractError(f"removal events {path} line {n} lacks {', '.join(missing)}")
            out.append(ev)
    return out


def profile_owner(admin: admin_api.Admin, profile_id: str) -> dict[str, str] | None:
    """The claimed owner of a profile (docs/lessons/muso-domain.md ownership rule:
    isClaimed AND exactly one claimed workspace with an email), else None."""
    doc = admin_api.profile(admin, profile_id)
    if doc.get("isClaimed") is not True:
        return None
    claimed = [w for w in (doc.get("workspaces") or []) if isinstance(w, dict) and w.get("isClaimed") is True]
    if len(claimed) != 1 or not str(claimed[0].get("email") or "").strip():
        return None
    return {"email": str(claimed[0]["email"]).strip().lower(), "id": "", "first_name": ""}


@dataclass
class RemovalReport(Report):
    events: int = 0
    self_removals: int = 0
    fraud_silent: int = 0
    no_owner: int = 0
    invalid_events: int = 0
    invalid: list[str] = field(default_factory=list)

    def render(self, mode: str, title: str = "REMOVAL NOTICES") -> str:
        if mode == "apply" and not (self.sent_notes or self.refused_users or self.failed_users or self.invalid_events):
            return "NO_REPLY"
        head = f"{title} (dry run, nothing sent)" if mode != "apply" else title
        parts = [f"{head}: {self.sent_notes} owner(s) told about {self.sent_credits} removed credit(s)"
                 if mode == "apply" else f"{head}: {self.users} owner(s) would be told about {self.candidates} removed credit(s)"]
        parts.append(f"{self.events} removal event(s) read; {self.self_removals} self-removal(s) and "
                     f"{self.fraud_silent} fraud removal(s) are never notified")
        if self.invalid_events:
            parts.append(f"{self.invalid_events} invalid removal event(s) not notified (fix the feed): "
                         + "; ".join(self.invalid[:5]))
        if self.no_owner:
            parts.append(f"{self.no_owner} with no single claimed owner (not notified)")
        if self.deferred_users:
            parts.append(f"{self.deferred_users} owner(s) already had a message today (next run)")
        if self.refused_users:
            parts.append(f"{self.refused_users} refused by the gate: " + "; ".join(self.refusals[:5]))
        if self.failed_users:
            parts.append(f"FAILED: {self.failed_users} send(s): " + "; ".join(self.failures[:5]))
        return ". ".join(parts) + "."


def run_removal_notices(admin: admin_api.Admin, *, events_path: str, ledger_path: str | None = None,
                        mode: str = "dry-run", max_users: int = 100, pace_seconds: float = 1.0,
                        preview_dir: str | None = None, list_path: str | None = None,
                        wrapper: str = WRAPPER, runner: Runner = _run) -> RemovalReport:
    """One pass over a removal-events file (the ongoing feed or the one-time backfill).
    dry-run with --preview/--list writes the rendered notes and the owner list (no emails)
    for firstmate's approval; apply sends through the gate (send-locked until approved)."""
    import csv
    report = RemovalReport()
    events = load_removal_events(events_path)
    report.events = len(events)
    db = verify_ledger.connect(ledger_path or verify_ledger.DEFAULT_PATH)
    try:
        keep: list[dict[str, Any]] = []
        seen: set[str] = set()
        for n, ev in enumerate(events, 1):
            actor = str(ev["actor"]).strip().lower()
            reason = str(ev["reason"]).strip().lower()
            if actor in SELF_ACTORS:
                report.self_removals += 1
                continue
            if reason == "fraud":
                report.fraud_silent += 1
                continue
            eid = _clean(ev["event_id"])
            why = removal_event_problem(ev) or ("duplicate event_id" if eid in seen else "")
            if why:
                report.invalid_events += 1
                report.invalid.append(f"{eid if EVENT_ID_RE.fullmatch(eid) else f'event #{n}'}: {why}")
                continue
            seen.add(eid)
            keep.append({**ev, "event_id": eid})
        blocked = verify_ledger.blocked_ids(db, [str(e["event_id"]) for e in keep], CAMPAIGN_REMOVAL)
        keep = [e for e in keep if str(e["event_id"]) not in blocked]
        report.candidates = len(keep)
        owners: dict[str, dict[str, Any]] = {}
        cache: dict[str, dict[str, str] | None] = {}
        for ev in sorted(keep, key=lambda e: str(e.get("removed_at") or "")):
            pid = str(ev["profile_id"])
            if pid not in cache:
                cache[pid] = profile_owner(admin, pid)
            owner = cache[pid]
            if owner is None:
                report.no_owner += 1
                continue
            g = owners.setdefault(owner["email"], {"user": dict(owner), "credits": [], "profiles": set()})
            g["profiles"].add(pid)
            g["credits"].append({"request_id": str(ev["event_id"]), "role": str(ev["role"]),
                                 "track_title": str(ev["track_title"]), "artist_name": str(ev["artist_name"]),
                                 "reason": str(ev["reason"]).strip().lower(),
                                 "evidence_url": str(ev.get("evidence_url") or ""),
                                 "source_label": str(ev.get("source_label") or ""),
                                 "policy_reason": str(ev.get("policy_reason") or "").strip().lower()})
        payloads = list(owners.values())[:max_users]
        report.users = len(payloads)
        if list_path:
            fd = os.open(list_path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
            with os.fdopen(fd, "w", newline="", encoding="utf-8") as fh:
                w = csv.writer(fh)
                w.writerow(["profile_ids", "credits", "reasons"])
                for p in payloads:
                    reasons = collections.Counter(c["reason"] for c in p["credits"])
                    w.writerow([";".join(sorted(p["profiles"])), len(p["credits"]),
                                ";".join(f"{k}={v}" for k, v in sorted(reasons.items()))])
        send_all([{"user": p["user"], "credits": p["credits"]} for p in payloads], report, mode=mode,
                 wrapper=wrapper, runner=runner, extra=["--campaign", CAMPAIGN_REMOVAL], pace_seconds=pace_seconds,
                 preview_dir=preview_dir)
    finally:
        db.close()
    return report
