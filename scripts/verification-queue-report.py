#!/usr/bin/env python3
"""verification-queue-report.py — the captain's every-30-minutes DM: how many open
CREDITS (credit requests) and CLAIMS (profile claims) sit in each queue, and whether
the number moved since the last report.

Runs ON NODE-8 (needs the hydra ledger, proof-on-file feed, watchlist and the Trino
wrapper; it reads nothing but local files plus Trino). READ-ONLY: the only writes are
one Slack DM (with --post) and the small state file that makes the arrows possible.

Buckets (first match wins, so they partition the open population exactly and
`open = sum of the buckets` is an invariant the self-check enforces):

  1. not touched by us at all   — no ask ever, no message ever, no decision ever
  2. approved in the last 24h   — flow, not open (core updatedat window)
  3. needs documents, user told — we asked (ledger ask note or core noticeSentAt)
  4. needs documents, not told  — we decided something, the user was never asked
  5. user sent documents, we owe a look — a document is on file / the reply is unreviewed
  6. sitting with a person      — a support ticket/hold a person must clear, a reply, a flagged hold
  7. held for fraud / watchlist — the fraud watchlist or the fraud-lens holds
  8. muted, no more messages    — a messaging refusal hold suppresses further notes
  9. declined in the last 24h   — flow, not open (core updatedat window)

The precedence order matters and is deliberate: a row a human or the fraud lens owns
must never be counted as "waiting on the user", and "not touched by us" must mean
literally nothing was ever written — that is the bucket the captain acts on. The mirror
of that rule: a row the AI can move must never be parked with a person. Having emailed
support@ in the last 90 days is therefore NOT bucket 6 (captain 2026-11-16, #1992/#2090):
the decider asks those users in the verify notes, and the report counts them where the
ask ladder can see them — untouched, told, muted or not told.

Definitions reused from the measurement the ops steward already runs
(data/verification-ops-steward-s1/s1_tick.py + scoreboard.md) and from the queue-arm
analysis (data/credit-refresh-t01b/queue-arms-1026.md):
  - open credit request = credit_requests.deletedat IS NULL AND status NOT IN
    ('approved','rejected'); open claim = claiming.deletedat IS NULL AND status='pending'
  - paid = the row's workspace/team holds an active or trialing subscription
  - "documents required" is core's own signal (status='user_verification_needed', or a
    decider `support` write with doc_required=1)
  - "documents on file" is /var/lib/credit-trust/proof-on-file.json (the same feed the
    decider holds on: "proof on file: human review")
  - "user told" is the hydra message ledger (verify_messages, ASK_CAMPAIGNS sent or
    attempted) or core's metadata proofRequest.noticeSentAt / infoRequest.responseAt

Scheduling: /etc/cron.d/verification-queue-report every 30 min, plus a 5-minute
--light tick, both installed by scripts/install-aux-units.sh.
Kill switches: /etc/hydra/verification-queue-report.disabled (the report) and
/etc/hydra/backlog-sentinel.disabled (the pages; the sentinel never pages itself).

  --post       send the DM to the captain (default: measure, print, write state)
  --dry-run    measure and print the message text, never post, never write state
  --json       print the raw measurement object instead of the message
  --no-state   do not read or write the arrows state file (implied by --dry-run)
  --grid       print (and DM with --post) the date x state grids, and write VQR_GRID_OUT
  --light      the 5-minute tick: the backlog sentinel only, skipping the sources that
               need a network round-trip (merges, Intercom). Never DMs the report.
  --selftest   run the bucket classifier on fixtures (no network, no host reads)
  --help       print this text
"""

from __future__ import annotations

import csv
import fcntl
import hashlib
import io
import json
import os
import re
import sqlite3
import statistics
import subprocess
import sys
import time
import urllib.request
from datetime import date, datetime, timedelta, timezone
from pathlib import Path
from types import SimpleNamespace

TRINO = os.environ.get("VQR_TRINO", "/opt/hydra/scripts/trino-query.sh")
LEDGER = os.environ.get("VQR_LEDGER", "/var/lib/hydra/credit-review/ledger.sqlite3")
PROOF = os.environ.get("VQR_PROOF_ON_FILE", "/var/lib/credit-trust/proof-on-file.json")
WATCHLIST = os.environ.get("VQR_WATCHLIST", "/opt/hydra/policies/fraud-watchlist.json")
ENV_FILE = os.environ.get("VQR_ENV_FILE", "/etc/openclaw/main.env")
KILL = os.environ.get("VQR_KILL_SWITCH", "/etc/hydra/verification-queue-report.disabled")
STATE = os.environ.get("VQR_STATE", "/var/lib/hydra/verification-queue-report/last.json")
CAPTAIN = os.environ.get("VQR_CAPTAIN", "U7RP6HKUZ")
QUERY_TIMEOUT = int(os.environ.get("VQR_QUERY_TIMEOUT", "100"))
BASELINE = os.environ.get("VQR_BASELINE", "2026-10-26T21:00:00Z")
SENTINEL_STATE = os.environ.get("VQR_SENTINEL_STATE",
                                "/var/lib/hydra/backlog-sentinel/state.json")
SENTINEL_KILL = os.environ.get("VQR_SENTINEL_KILL", "/etc/hydra/backlog-sentinel.disabled")
TRINO_SESSION = "SET SESSION query_max_execution_time='90s'; "

# [key=open-status-index] The open filter must be a POSITIVE status list, the way core's status
# index can serve it. `status NOT IN ('approved','rejected')` is not pushed down, so it reads the
# whole table (5.65M rows, 76 GB of JSON) and dies on the session's 90s cap: on 2026-11-12 the
# reporter's credits query was the piece that failed, "Query exceeded the maximum execution time
# limit of 90.00s", and it took the whole report down with it (last.json stuck at 2026-11-10
# 12:01Z, so "the untold count fell" could not be measured). The consumer that actually sends
# (owing_proof.REPLICA_SQL) already uses this exact list after #1893: 106.9 s whole-table vs
# 8.2 s on the index. Keep this beside CREDIT_OPEN_STATUSES' owner; a test asserts the two agree
# so they cannot drift apart.
CLOSED_STATUSES = ("approved", "rejected")
OPEN_STATUSES = ("unverified", "processing", "user_verification_needed")
OPEN_STATUS_LIST = ", ".join(f"'{s}'" for s in OPEN_STATUSES)

# Campaigns in the hydra ledger that ASK the user for something (see
# scripts/credit_review/verify_ledger.py ASK_CAMPAIGNS). A note from one of these is
# "the user has been told"; any other campaign (a status note, a take-back notice) is
# a message but not an ask.
ASK_CAMPAIGNS = ("verify-live", "retro-past", "uvn-status", "gap-ask")
CLAIM_CAMPAIGNS = ("claim-proof-ask", "claim-status")

PAID_TEAMS = ("(SELECT DISTINCT s.teamid FROM postgresql_core.public.subscriptions s "
              "WHERE s.status IN ('active','trialing'))")

# The captain's backlog sentinel (2026-10-26 21:05Z): "no backlog should ever form from
# here on out for anything that is waiting on us! if it does get me involved immediately".
# One row per lane where the ball is in OUR court. `sla_h` is how long an item may sit
# there before it is a breach; `owner` is the lane that owes the action (see the lane
# roster in each firstmate brief — a page that does not name an owner is just noise).
# Items that were ALREADY past their SLA at the baseline are not breaches: they are the
# legacy backlog, tracked as a line in the 30-minute report that has to fall.
SENTINEL_BUCKETS = (
    ("credits_untouched", "credits nobody has touched", "verify-ask-wiring-h2", 24),
    ("credits_docs_in", "credit documents back, we owe a look",
     "verification worker, creds home (firstmate-assigned 2026-11-13)", 24),
    ("claims_untouched", "profile claims nobody has touched", "claim-lane-resume-c2", 24),
    ("claims_docs_in", "claim documents back, we owe a look", "claim-lane-resume-c2", 24),
    ("merges_waiting", "profile merges waiting on us", "merge-queue-clear-q1", 24),
    ("intercom_customer_last", "Intercom: the customer spoke last", "intercom-backlog-i1", 4),
    ("support_unanswered", "support@ emails with no reply", "intercom-backlog-i1", 4),
    ("fable_decider", "decider holds only a person can clear", "ops-completeness-fable-o1", 1),
)
# Captain 2026-10-27 00:52Z: these lanes are HELD BY HIS OWN ORDER, not rotting. They stay
# visible, but a page per tick would be noise about a decision he already made — so a held
# lane pages once per CHANGE of its item SET (never because the oldest item aged another
# hour), and never as "backlog forming". A new breach in any other lane still pages at once.
#
# The words (reason / unblock / owner / ETA) live in policies/queue-report-held-lanes.json so
# a stale blocker is a one-line reviewed edit, not a code change. Where the true blocker can
# be READ from the box (the account gate is wired, an approval kill switch is present, a send
# lock is on), held_lane() derives the sentence from that live state, so a blocker that has
# already shipped can never be paged as the reason (firstmate 038/039, 2026-10-27).
HELD_LANES_FILE = os.environ.get("VQR_HELD_LANES", str(Path(__file__).resolve().parents[1]
                                                      / "policies" / "queue-report-held-lanes.json"))
CAPTAIN_HELD = {
    # Measured on node-8 2026-11-13: the reader (doc-verify) IS live, and every user in this
    # bucket is here on a ledger proof tag that nothing reviews. doc-verify is a judge with no
    # executor: its verdict is written neither to core nor as a proof review in the ledger.
    "credits_docs_in": ("the returned-document reader is live, but nothing writes a doc-verify "
                        "verdict back (no executor: not to core, not as a proof review in the "
                        "ledger), so a user cannot leave this bucket by being read",
                        "the captain decides whether to wire a verdict write-back"),
    "claims_untouched": ("claim sends are behind hydra #1377 review", "#1377 review lands"),
    "fable_decider": ("approvals paused until the account gate is live",
                      "ship the account gate"),
    "intercom_customer_last": ("no new copy", "approved copy"),
}
# Live-state facts the held sentences are derived from (read once per tick; tests inject them).
GATE_SCRIPT = os.environ.get("VQR_ACCOUNT_GATE", "/opt/firstmate/fraud-lens/account_gate.py")
SCORE_APPROVE_PY = os.environ.get("VQR_SCORE_APPROVE", str(Path(__file__).resolve().parent
                                                           / "credit_review" / "score_approve.py"))
DECIDE_SWITCH = os.environ.get("VQR_DECIDE_SWITCH", "/etc/hydra/credit-trust-decide.disabled")
VERIFY_REQUEST_SH = os.environ.get("VQR_VERIFY_REQUEST", str(Path(__file__).resolve().parent
                                                             / "intercom-verify-request.sh"))
# What the docs_in held sentence is derived from: the returned-document reader's own store
# (doc-verify) and the approval registry. Both are local files, so the 5-minute light tick
# pays a few milliseconds for them and no network round trip.
DOC_VERIFY_STORE = os.environ.get("CREDIT_DOC_VERIFY_STORE",
                                  "/var/lib/hydra-credit-verify/doc-verify.sqlite")
# Where the returned documents are filed. Read only to tell a reader with NOTHING to read from
# one that stopped reading: dv_steps carries a row only for a document a run processed, so a
# quiet store on its own is not evidence about the reader at all.
DOC_PROOF_STORE = os.environ.get("CREDIT_PROOF_STORE",
                                 "/var/lib/hydra-credit-verify/proof.sqlite")
# Where the filed bytes are stored, `<root>/<sha[:2]>/<sha>` (credit_verify/docverify/blobs.py).
# A filing whose bytes are not here cannot be read by any run: blob-backfill owes them.
DOC_BLOB_ROOT = os.environ.get("CREDIT_DOC_VERIFY_BLOBS",
                               "/var/lib/hydra-credit-verify/blobs")
APPROVAL_REGISTRY = str(Path(__file__).resolve().parents[1]
                        / "policies" / "credit-approval-automation.json")
# The registry row that would let a read document approve a request: the row
# credit_review/decide.py doc_class_approved() gates on (a test pins the two readers equal).
DOC_APPROVAL_AUTOMATION = "document_small_track"
# "The reader is live" = a doc-verify step inside the last hour OR a user judged inside the
# last 24 hours. The cron (credit-doc-verify) fires hourly, so a working reader with documents
# to read steps at least once an hour; the 24-hour half keeps one quiet hour (nothing newly
# filed, one failed run, a short pause) from flipping the sentence, because the sentence is
# part of the held page's signature and every flip pages the captain.
DOC_READER_STEP_FRESH = timedelta(hours=1)
DOC_READER_JUDGED_WINDOW = timedelta(hours=24)
# Past both windows the reader's silence is only evidence of a STOPPED reader if there was work
# it should have read: a returned document filed for a credit request with no doc-verify step.
# proof_intake has no filed-at column (`received_at` is when the CUSTOMER sent it, arbitrarily
# older than the filing — a paused feeder files documents sent days before), so the newest
# DOC_READER_WAIT_ROWS rows by rowid are what "filed recently" means; the rowid walk stops and
# the step lookup per filing is indexed by proof_id. With nothing waiting the honest sentence is
# that the reader is caught up, never that it stopped.
DOC_READER_WAIT_ROWS = 500
# Neither table has an index on `at` and dv_steps holds 2.46M rows, so both reads walk the
# AUTOINCREMENT rowid backwards and stop. The bound only has to find ONE recent judged user;
# 5,000 outcome rows is more than a day of judging (3,826 in 24h, measured 2026-11-13) and
# reads in ~3 ms. Rows carried forward on a version bump keep their old `at`, so a tail of
# them reads as "nobody judged" and the step half decides.
DOC_READER_TAIL_ROWS = 5000
DOC_READER_BUSY_S = 1.0     # a busy store must not stall the tick: it reads as unknown
# The document's own date is read from the reader's own extraction, in chunks of this many
# user ids / sha256s per statement (the same bound doc_reader_waiting uses).
DOC_DATE_CHUNK = 500
# The decider sentences that mean "a document is on file" for THIS lane: the reason-5 hold, and
# the per-role split that carries a verified document. An allowlist, not a `proof on file` prefix:
# `proof on file: stage 2 judged the document` is a hold where the user was ALREADY asked.
ON_FILE_HOLD_PREFIXES = ("proof on file: human review", "proof on file: dv-")


def read_held_lanes(path: str = None) -> dict:
    """{bucket: {reason, unblock, owner, eta}} from the policy file. A missing or malformed
    file falls back to CAPTAIN_HELD's words with no owner override: the page still goes out,
    it is never silenced by a config problem."""
    try:
        with open(path or HELD_LANES_FILE) as fh:
            data = json.load(fh)
        lanes = data.get("lanes") if isinstance(data, dict) else None
        if isinstance(lanes, dict):
            return {k: v for k, v in lanes.items() if isinstance(v, dict)}
    except (OSError, ValueError):
        pass
    return {}


def doc_blob_present(sha: str) -> bool:
    """Whether the filed bytes are on disk, the check the reader's own selection makes
    (credit_verify/docverify/blobs.py BlobStore.has)."""
    try:
        return os.path.isfile(os.path.join(DOC_BLOB_ROOT, sha[:2], sha))
    except (OSError, TypeError):
        return False


def doc_reader_waiting(db, proof_path: str = None) -> tuple[int, int] | None:
    """(readable, unread) over the returned credit documents with no doc-verify step: the work
    a live reader should have read, and the filings no run can read (bytes not on file, or no
    credit request to point a verdict at), which are never evidence that it stopped. Bounded
    (DOC_READER_WAIT_ROWS filings, one indexed step lookup, one registration lookup and one
    isfile per unread filing). None when the proof feed cannot be read: then the reader's quiet
    is not measurable, which is its own state."""
    try:
        proof = sqlite3.connect(f"file:{proof_path or DOC_PROOF_STORE}?mode=ro", uri=True,
                                timeout=DOC_READER_BUSY_S)
    except sqlite3.Error:
        return None
    try:
        rows = proof.execute(
            "select file_sha256, candidate_request_ids_json, conversation_id from proof_intake "
            "where subject = 'credit' order by rowid desc limit ?",
            (DOC_READER_WAIT_ROWS,)).fetchall()
    except sqlite3.Error:
        return None
    finally:
        proof.close()
    # A claim filing carries no candidate request, and the reader's credit pass is not what it
    # is waiting for: only a document filed for a credit request is work this lane can name. A
    # filing whose candidates carry no usable id is one the reader skips, so it is not evidence
    # about the reader either.
    unread = 0
    filed = []
    for sha, cands, convo in rows:
        if not sha:
            continue
        try:
            usable = any(json.loads(cands or "[]"))
        except ValueError:
            usable = False
        if usable:
            filed.append((sha, convo or ""))
        else:
            unread += 1
    # doc-verify records every step against the document's sha256 (its proof id), which is
    # proof_intake.file_sha256; intake_id is `<user_id>:<sha256 prefix>` and matches no step.
    seen: set = set()
    try:
        for start in range(0, len(filed), 500):
            chunk = [f[0] for f in filed[start:start + 500]]
            seen.update(x[0] for x in db.execute(
                "select distinct proof_id from dv_steps where proof_id in (%s)"
                % ",".join("?" * len(chunk)), chunk).fetchall())
    except sqlite3.Error:
        return None
    unread_filed = [(sha, convo) for sha, convo in filed if sha not in seen]
    if not unread_filed:
        return 0, unread
    # The reader's own selection rule (intake_read.needs_backfill): a filing whose bytes are not
    # stored is skipped when it came in by email, or when its stored blob was deleted; an
    # Intercom filing with no stored blob is still fetched from the conversation attachment.
    try:
        registered = {x[0] for x in db.execute(
            "select sha256 from dv_blobs where sha256 in (%s)"
            % ",".join("?" * len(unread_filed)), [sha for sha, _ in unread_filed]).fetchall()}
    except sqlite3.Error:
        # Whether the bytes were ever stored is what separates readable work from a blob the
        # reader will skip: an unreadable registry would silently call an owed filing readable
        # and page a healthy reader as stopped, so it is unmeasured, like every other read here.
        return None
    readable = 0
    for sha, convo in unread_filed:
        if doc_blob_present(sha):
            readable += 1
        elif convo.startswith("gmail:") or sha in registered:
            unread += 1
        else:
            readable += 1
    return readable, unread


def doc_reader_facts(path: str = None, now: datetime = None, proof_path: str = None) -> dict:
    """What the returned-document reader is doing, asked of its own store in bounded reads
    (DOC_READER_TAIL_ROWS outcomes, DOC_READER_WAIT_ROWS filings). `doc_reader_state` is
    "live", "stopped" only when there was readable work it did not read, "bytes_owed" when the
    only filings left are ones no run can read, "caught_up" when there was no work at all, and
    "unknown" when a store could not be read (not node-8, missing or busy): an unmeasured
    reader is never called stopped and never called caught up."""
    out = {"doc_reader_state": "unknown", "doc_reader_last_step": None}
    now = now or datetime.now(timezone.utc)
    try:
        db = sqlite3.connect(f"file:{path or DOC_VERIFY_STORE}?mode=ro", uri=True,
                             timeout=DOC_READER_BUSY_S)
    except sqlite3.Error:
        return out
    try:
        step = db.execute("select at from dv_steps order by id desc limit 1").fetchone()
        since = (now - DOC_READER_JUDGED_WINDOW).strftime("%Y-%m-%dT%H:%M:%SZ")
        judged = db.execute(
            "select count(distinct user_id) from (select user_id, at from dv_outcomes "
            "order by id desc limit ?) where at >= ?", (DOC_READER_TAIL_ROWS, since)).fetchone()[0]
        last = step[0] if step else None
        last_at = parse_ts(last or "")
        fresh = bool(last_at and now - last_at <= DOC_READER_STEP_FRESH)
        if fresh or judged > 0:
            return {"doc_reader_state": "live", "doc_reader_last_step": last}
        waiting = doc_reader_waiting(db, proof_path)
    except sqlite3.Error:
        return out
    finally:
        db.close()
    if waiting is None:
        state = "unknown"
    elif waiting[0]:
        state = "stopped"
    elif waiting[1]:
        state = "bytes_owed"
    else:
        state = "caught_up"
    return {"doc_reader_state": state, "doc_reader_last_step": last}


def doc_dates(users, path: str = None, proof_path: str = None) -> dict[int, dict] | None:
    """user id -> {"filed": bool, "read": bool, "date": date | None, "received_at": str |
    None, "docs": [{"read", "date", "received_at"}]}: whether the
    returned-document reader has READ a credit document on file for that account, the document's
    own date when it read one (the earliest signed/issued/sent date at >= 0.6 —
    `runner.document_date`'s rule, imported rather than restated, because a second copy of that
    threshold is a second answer to "when was this document signed"), and when the customer sent
    the newest document on file.

    `docs` is the same reading per document, because a user can have several: the lane clock has
    to be the arrival of the document that actually keeps the row in `docs_in`, and the newest
    arrival across the whole set would hide an older document nobody has opened.

    Why this exists: the decider's proof feed carries no timestamp at all, so an undated "proof on
    file" hold could never be shown to postdate the request it serves and was counted with a
    person. The date is not missing from the box — doc-verify records every date it reads out of
    the file in its `extract` step, keyed by the document's sha256, which is `proof_intake`'s
    `file_sha256`. So the hold is decided on the document's own date, like a dated proof tag.

    `read` is True only when EVERY credit document on file has an extraction ANSWER under the
    reader's CURRENT version: a document nobody has opened yet (or whose transient failure is
    still retryable) is work WE owe, never a reason to ask the customer for a dated copy. An
    answer under a superseded version is not an answer — the deployed reader re-reads it. A
    settled failure is an answer — the reader looked and could not read it — so it is read with
    no date, which is the ask lane.

    "On file" is the READER's own eligibility, not every row in `proof_intake`: it selects
    `subject = 'credit' AND candidate_request_ids_json != '[]'` (`intake_read.intake_docs`), so a
    filing with no candidate request is one it will never open. Counting it here would put the
    row in `docs_in` forever with no reader work behind it, which is the lane this whole change
    exists to empty.

    None when either store cannot be read: an unmeasured date must never be read as "undated"
    (that would ask a customer for a copy of a document we simply did not open)."""
    ids = sorted({int(u) for u in users})
    if not ids:
        return {}
    try:
        proof = sqlite3.connect(f"file:{proof_path or DOC_PROOF_STORE}?mode=ro", uri=True,
                                timeout=DOC_READER_BUSY_S)
    except sqlite3.Error:
        return None
    try:
        shas: dict[int, set] = {}
        arrivals: dict[int, dict] = {}
        for start in range(0, len(ids), DOC_DATE_CHUNK):
            chunk = ids[start:start + DOC_DATE_CHUNK]
            for uid, sha, received in proof.execute(
                    "select user_id, file_sha256, received_at from proof_intake where subject = 'credit' "
                    "and file_sha256 is not null and candidate_request_ids_json != '[]' "
                    "and user_id in (%s)"
                    % ",".join("?" * len(chunk)), chunk):
                if str(uid).strip().isdigit() and sha:
                    shas.setdefault(int(uid), set()).add(sha)
                    if received:
                        arrivals.setdefault(int(uid), {})[sha] = received
    except sqlite3.Error:
        return None
    finally:
        proof.close()
    here = os.path.dirname(os.path.abspath(__file__))
    if here not in sys.path:
        sys.path.insert(0, here)
    from credit_verify.docverify import VERSION
    from credit_verify.docverify.runner import (MAX_EXTRACT_ATTEMPTS, TRANSIENT,
                                                document_date)
    try:
        db = sqlite3.connect(f"file:{path or DOC_VERIFY_STORE}?mode=ro", uri=True,
                             timeout=DOC_READER_BUSY_S)
    except sqlite3.Error:
        return None
    try:
        every = sorted({s for v in shas.values() for s in v})
        reads: dict[str, tuple] = {}
        for start in range(0, len(every), DOC_DATE_CHUNK):
            chunk = every[start:start + DOC_DATE_CHUNK]
            # Every extract answer for each document, oldest first: the last row is the reading
            # that counts, and the error count is what makes a transient failure settled. A
            # provider outage is neither an extraction nor a failure, so it is not in the status
            # list (doc_sources.documents).
            # `proof_id` and `proof_intake.file_sha256` are both hashlib.hexdigest() output
            # (lowercase), so they are compared exactly and dv_steps_proof(proof_id, request_id)
            # serves the lookup; a lower() here would force a full scan of the step table.
            for sha, status, detail in db.execute(
                    "select proof_id, status, detail_json from dv_steps where step = 'extract' "
                    "and status in ('ok','error') and proof_id in (%s) and version = ? order by id"
                    % ",".join("?" * len(chunk)), list(chunk) + [VERSION]):
                prev = reads.get(sha)
                reads[sha] = (status, detail, (prev[2] if prev else 0) + (status == "error"))
    except sqlite3.Error:
        return None
    finally:
        db.close()
    out: dict[int, dict] = {}
    for uid in ids:
        on_file = shas.get(uid, ())
        read, unread, dates = bool(on_file), False, []
        docs = []
        for sha in on_file:
            got = reads.get(sha)
            if got is None:
                unread = True
                docs.append({"read": False, "date": None,
                             "received_at": arrivals.get(uid, {}).get(sha)})
                continue
            status, detail, errors = got
            try:
                body = json.loads(detail or "{}") or {}
            except ValueError:
                body = {}
            if status == "error":
                err = str(body.get("error") or "")
                if err.startswith(TRANSIENT) and errors < MAX_EXTRACT_ATTEMPTS:
                    unread = True
                    docs.append({"read": False, "date": None,
                                 "received_at": arrivals.get(uid, {}).get(sha)})
                else:
                    docs.append({"read": True, "date": None,
                                 "received_at": arrivals.get(uid, {}).get(sha)})
                continue
            d = document_date(SimpleNamespace(dates=body.get("dates") or []))
            if d is not None:
                dates.append(d)
            docs.append({"read": True, "date": d,
                         "received_at": arrivals.get(uid, {}).get(sha)})
        # The NEWEST date among the documents on file: if any of them postdates the request the
        # user did send a current document, and that is the reading that never hides work.
        sent = [(parse_ts(t), t) for t in arrivals.get(uid, {}).values()]
        sent = [x for x in sent if x[0] is not None]
        out[uid] = {"filed": bool(on_file), "read": read and not unread,
                    "date": max(dates) if dates else None,
                    "received_at": max(sent)[1] if sent else None,
                    "docs": docs}
    return out


def doc_writeback_approved(path: str = None) -> bool | None:
    """Whether any automation is approved to act on a read document, as the registry records
    it (approved AND approved_by AND approval_ref, the rule decide.doc_class_approved applies).
    None when the registry or its row cannot be read: for a sentence that is unknown, where
    the gate itself fails closed."""
    try:
        with open(path or APPROVAL_REGISTRY, encoding="utf-8") as fh:
            entry = json.load(fh)["automations"][DOC_APPROVAL_AUTOMATION]
        return (entry.get("approved") is True
                and bool(str(entry.get("approved_by") or "").strip())
                and bool(str(entry.get("approval_ref") or "").strip()))
    except (OSError, ValueError, KeyError, TypeError, AttributeError):
        return None


def held_facts() -> dict:
    """Read the live blockers from the box. Every read fails to None (unknown), never to a
    guess: an unknown fact keeps the policy-file sentence."""
    def has(path, needle=None):
        try:
            if needle is None:
                return os.path.exists(path)
            with open(path, errors="replace") as fh:
                return needle in fh.read()
        except OSError:
            return None

    def lock(name):
        try:
            with open(VERIFY_REQUEST_SH, errors="replace") as fh:
                m = re.search(rf"^readonly {name}=([01])", fh.read(), re.M)
            return None if not m else m.group(1) == "1"
        except OSError:
            return None

    gate = has(GATE_SCRIPT)
    wired = has(SCORE_APPROVE_PY, "account_gate")
    return {"account_gate_live": (gate and wired) if gate is not None and wired is not None else None,
            "decide_switch": has(DECIDE_SWITCH),
            "claim_status_on": lock("CLAIM_STATUS_COPY_APPROVED"),
            "claim_proof_ask_on": lock("CLAIM_PROOF_ASK_COPY_APPROVED"),
            **doc_reader_facts(),
            "doc_writeback_approved": doc_writeback_approved()}


def held_lane(key: str, facts: dict | None = None, lanes: dict | None = None) -> dict | None:
    """The held sentence for one bucket, or None when the lane is no longer held (then its
    breaches page as BACKLOG FORMING like any other lane). Live state wins over the file."""
    if key not in CAPTAIN_HELD:
        return None
    facts = facts or {}
    reason, unblock = CAPTAIN_HELD[key]
    spec = {"reason": reason, "unblock": unblock, "owner": None, "eta": None}
    spec.update({k: v for k, v in ((lanes or {}).get(key) or {}).items() if v})
    if key == "fable_decider":
        gate, switch = facts.get("account_gate_live"), facts.get("decide_switch")
        if switch:
            spec["reason"] = ("decider approvals are switched off by the captain's order "
                              "(/etc/hydra/credit-trust-decide.disabled)"
                              + ("; the account gate is live" if gate else ""))
            spec["unblock"] = "the captain lifts the approval pause"
            spec["eta"] = spec.get("eta") or "on the captain's decision"
        elif gate:
            return None               # gate live, switch gone: nothing holds it any more
    if key == "claims_untouched" and facts.get("claim_status_on"):
        if facts.get("claim_proof_ask_on"):
            return None               # both claim sends are on: an untouched claim is a breach
        spec["reason"] = ("claim-status notes are on (hydra #1377 is live); claim proof asks "
                          "stay off until a returned document can be accepted")
        spec["unblock"] = spec.get("unblock_after_status") or "the returned-document reader goes live"
    if key == "credits_docs_in":
        # The reader's state is what can be read from the box; the file supplies the owner, the
        # eta and the unblock. An unmeasured reader is said as unmeasured, never as the file's
        # dated claim. No timestamp or count that moves while the reader works goes in a reason:
        # it is part of the page's signature.
        state, armed = facts.get("doc_reader_state"), facts.get("doc_writeback_approved")
        reading = {
            "live": "the returned-document reader is live and reading",
            "caught_up": ("the returned-document reader has read every returned credit "
                          "document in the newest filings (nothing among them is waiting to "
                          "be read)"),
            "bytes_owed": ("the returned-document reader is not the blocker in the newest "
                           "filings: every returned credit document it can read there has "
                           "been read, and the ones still unread cannot be read by any run "
                           "(their bytes are not on file, or they carry no credit request to "
                           "point a verdict at)"),
        }.get(state, "")
        if state in ("live", "caught_up", "bytes_owed"):
            if armed is False:
                spec["reason"] = (reading + ", but nothing writes its verdict back: no automation "
                                  "is approved to act on a read document (" + DOC_APPROVAL_AUTOMATION
                                  + " is approved=false in the approval registry), so a user "
                                  "cannot leave this bucket by being read")
                spec["eta"] = spec.get("eta") or "when the captain decides"
            elif armed:
                spec["reason"] = (reading + ", and document approvals are registered approved ("
                                  + DOC_APPROVAL_AUTOMATION + "); the documents still here were "
                                  "not decided by that path")
                spec["unblock"] = "find why the approved document path leaves these documents"
            else:
                spec["reason"] = (reading + "; whether a verdict write-back is approved was not "
                                  "measured (the approval registry could not be read)")
            if state == "bytes_owed":
                spec["unblock"] = ("restore the filed bytes (credit-doc-verify.py blob-backfill "
                                   "for the filings whose bytes are owed); then: "
                                   + spec["unblock"])
        elif state == "stopped":
            # Stopped means a returned document filed for a request was not read, not that the
            # store went quiet. The latest step does not move while it is stopped, and the
            # write-back half is said as the registry measures it, exactly as above.
            write_back = {
                False: ", and nothing writes a doc-verify verdict back either",
                True: ", and document approvals are registered approved ("
                      + DOC_APPROVAL_AUTOMATION + "), so it was not that path",
            }.get(armed, "; whether a verdict write-back is approved was not measured"
                          " (the approval registry could not be read)")
            spec["reason"] = ("the returned-document reader has stopped reading (a returned "
                              "document filed for a request is still unread; latest "
                              "doc-verify step "
                              f"{facts.get('doc_reader_last_step') or 'none on record'}"
                              + write_back)
            spec["unblock"] = ("restart the reader (cron credit-doc-verify); then: "
                               + spec["unblock"])
        else:
            # An unknown is not a fact: say it was not measured, in the same voice as an
            # unread approval registry, and never the file's dated claim about the reader.
            spec["reason"] = ("whether the returned-document reader is reading was not measured "
                              "(the doc-verify store or the proof feed could not be read), so "
                              "whether these documents have been read is unknown")
    return spec


def held_words_now(stored: dict, facts: dict | None, lanes: dict | None,
                   live: dict | None = None) -> dict:
    """The report's held block, with each lane's WORDS as they are derived on this tick.

    `stored` is the state file's `held`: a snapshot taken when a page was last DELIVERED. Its
    count and item hash are the dedupe record and stay as they are. Its sentence is a copy of
    what was true then, and printing the copy is how a false sentence outlives its fix: a dry
    run, a rejected page or the sentinel's kill switch all leave the old words in the file,
    and the 30-minute report would go on saying them (2026-11-13: it still called the
    document reader "not live yet", 17 days after the reader went live).

    `live` is this tick's `{bucket: (count, oldest_h)}`; the numbers move and are printed, but
    they are not part of the page's dedupe record (that is `items_sha`, and it stays stored)."""
    owners = {key: owner for key, _label, owner, _sla in SENTINEL_BUCKETS}
    out = {}
    for key, row in stored.items():
        spec = held_lane(key, facts, lanes)
        row = dict(row)
        if live and key in live:
            row["count"], row["oldest_h"] = live[key]
        out[key] = row if spec is None else dict(
            row, reason=spec["reason"], unblock=spec["unblock"],
            owner=spec.get("owner") or owners.get(key) or row.get("owner"), eta=spec.get("eta"))
    return out


def held_signature(items: list) -> dict:
    """What a held lane's page is deduped on: the item SET, not the oldest age (the age moves
    every tick, which paged the same held lane every hour: 120 held pages on 10-27)."""
    ids = sorted(i["id"] for i in items)
    return {"count": len(ids), "items_sha": hashlib.sha256("\n".join(ids).encode()).hexdigest()[:16]}

# Reasons a decider hold is NOT something the machine will ever finish on its own: the
# validator reject rules and the server approval guards. Everything else ("score approval
# not now: …") is waiting for data, which a later run picks up by itself.
DECIDER_DEAD_ENDS = ("validator reject rule fired", "server approval guard would refuse")


BUCKETS = (
    ("watch", "Held for fraud / watchlist"),
    ("docs_in", "User sent documents - we owe a look"),
    ("human", "Sitting with a person"),
    ("muted", "Muted - no more messages"),
    ("told", "Needs documents - user told"),
    ("untouched", "Not touched by us at all"),
    ("not_told", "Needs documents - user NOT told"),
)


# ── measurement ────────────────────────────────────────────────────────────────

def trino(sql: str, timeout: int = QUERY_TIMEOUT, numeric_first: bool = True) -> list[list[str]]:
    if OFFLINE:
        return []
    """CSV rows from the read-only Trino replica. Non-data lines (the JVM banner,
    warnings) are dropped: the wrapper streams them on stderr and mixes them in.
    `numeric_first` keeps only rows whose first column is a number — the per-user queries
    are keyed by user id and that filter is what removes the banner. A query whose first
    column is a word (a status) MUST pass numeric_first=False or every row is dropped."""
    p = subprocess.run([TRINO], input=TRINO_SESSION + sql, capture_output=True, text=True,
                       timeout=timeout)
    if p.returncode:
        raise RuntimeError((p.stderr or p.stdout)[-400:])
    rows = list(csv.reader(io.StringIO("\n".join(
        line for line in p.stdout.splitlines() if line.startswith('"')))))
    return [r for r in rows if r and (r[0].isdigit() or not numeric_first)]


def age_h(ts: str, now: datetime) -> float:
    """Hours since a core timestamp (`2026-10-26 07:38:56.936000 UTC`)."""
    if not ts:
        return 0.0
    v = ts.replace(" UTC", "+00:00").replace(" ", "T", 1)
    try:
        return max(0.0, (now - datetime.fromisoformat(v)).total_seconds() / 3600)
    except ValueError:
        return 0.0


def readable_age_h(ts: str, now: datetime) -> float | None:
    """age_h(), but None when the timestamp is empty or unreadable, so a real 0.0 stays a 0.0."""
    if not ts:
        return None
    v = ts.replace(" UTC", "+00:00").replace(" ", "T", 1)
    try:
        return max(0.0, (now - datetime.fromisoformat(v)).total_seconds() / 3600)
    except ValueError:
        return None


def age_stats(pop: dict, now: datetime, request_median_h: float | None = None) -> dict:
    """How long the open users of one table have waited: the median and the oldest, in hours.

    `median_h` is the median age of an OPEN REQUEST, one sample per request, read by
    request_median_h() - the done criterion is per request, and a per-user figure moves
    differently (one 2-year-old request beside ten fresh ones is one sample, not eleven).
    `oldest_per_user_median_h` is the per-user figure: one age per USER, the user's oldest
    open request, the same clock every bucket's `oldest` uses. A user whose oldest request
    has no readable time is left out and counted in `undated`: readable_age_h() answers None
    for it, and a zero would pull the median down.
    """
    ages = sorted(h for h in (readable_age_h(i.get("oldest") or "", now) for i in pop.values())
                  if h is not None)
    out = {"users": len(ages), "undated": len(pop) - len(ages),
           "oldest_per_user_median_h": statistics.median(ages) if ages else None,
           "oldest_h": ages[-1] if ages else None}
    if request_median_h is not None:
        out["median_h"] = request_median_h
    return out


OPEN_REQUEST_SQL = {
    "credits": f"""select cast(cr.createdat as varchar)
from postgresql_core.public.credit_requests cr
where cr.deletedat is null and cr.status in ({OPEN_STATUS_LIST})""",
    "claims": """select cast(c.createdat as varchar)
from postgresql_core.public.claiming c
where c.deletedat is null and c.status = 'pending'""",
}


def request_median_h(family: str, now: datetime) -> float:
    """The median age of an OPEN REQUEST of one family, one sample per request.

    A read that answers no request with a readable time raises: an empty answer is a failed
    read, never a 0-hour median.
    """
    rows = trino(OPEN_REQUEST_SQL[family], numeric_first=False)
    ages = sorted(h for h in (readable_age_h(r[0], now) for r in rows) if h is not None)
    if not ages:
        raise RuntimeError(f"no open {family} request has a readable time")
    return statistics.median(ages)


def credit_status_guard() -> list[str]:
    """[key=open-status-index] The positive open-status filter is only equal to "not approved/rejected" while every
    status in the table is one we know. An unknown status (core adds `review_pending`) would be silently left out of
    the population, and the untold/owing count would read LOWER while the work is still there - a served number
    lowered by a filter, which is the one thing this report must never do. So the statuses are read first and an
    unknown one refuses the report (FATAL-prefixed, so the tick pages instead of publishing a smaller number).

    The guard is owing_proof's, not a copy: one list, one decision about who is asked. An offline run measures
    nothing at all (every reader is bypassed on purpose), so it has no population to guard and no baseline to
    publish; the guard stays out of its way rather than turning a shape-only run into a refusal."""
    if OFFLINE:
        return []
    here = os.path.dirname(os.path.abspath(__file__))
    if here not in sys.path:
        sys.path.insert(0, here)
    from credit_review import owing_proof
    return owing_proof.check_statuses(lambda sql: [list(r) for r in trino(sql, numeric_first=False)])


def credit_rows() -> dict[int, dict]:
    credit_status_guard()
    rows = trino(f"""
select cast(cr.userid as varchar),
 cast(max(case when cr.workspaceid in {PAID_TEAMS} then 1 else 0 end) as varchar),
 cast(count(*) as varchar), cast(min(cr.createdat) as varchar),
 cast(max(case when coalesce(json_extract_scalar(cr.metadata,'$.proofRequest.noticeSentAt'),
   json_extract_scalar(cr.metadata,'$.proofRequest.responseAt'),
   json_extract_scalar(cr.metadata,'$.infoRequest.responseAt')) is not null then 1 else 0 end) as varchar),
 cast(max(case when json_extract_scalar(cr.metadata,'$.proofRequest.responseAt') is not null
   and cast(json_extract_scalar(cr.metadata,'$.proofRequest.responseAt') as timestamp) > cr.createdat
   then json_extract_scalar(cr.metadata,'$.proofRequest.responseAt') end) as varchar),
 cast(max(case when cr.status = 'user_verification_needed' then 1 else 0 end) as varchar),
 cast(sum(case when cr.workspaceid in {PAID_TEAMS} then 1 else 0 end) as varchar),
 cast(max(cr.createdat) as varchar)
from postgresql_core.public.credit_requests cr
where cr.deletedat is null and cr.status in ({OPEN_STATUS_LIST})
group by 1""")
    return {int(r[0]): {"paid": r[1] == "1", "n": int(r[2]), "oldest": r[3],
                        "core_ask": r[4] == "1",
                        # Fable: only a document NEWER than the request that names it counts as
                        # "the user sent documents". `reply_at` is empty when every recorded
                        # response predates the request it would serve (an old accepted doc).
                        "reply_at": r[5] or "",
                        "core_reply": bool(r[5]),
                        "needs_docs": r[6] == "1", "paid_n": int(r[7] or 0),
                        "newest": (r[8] if len(r) > 8 else r[3])} for r in rows}


def claim_rows() -> dict[int, dict]:
    rows = trino(f"""
select cast(c.userid as varchar),
 cast(max(case when c.teamid in {PAID_TEAMS} then 1 else 0 end) as varchar),
 cast(count(*) as varchar), cast(min(c.createdat) as varchar),
 cast(array_join(array_agg(distinct case when c.profileid is not null then cast(c.profileid as varchar) end),
   ',') as varchar),
 cast(array_join(array_agg(distinct cast(c.id as varchar)), ',') as varchar),
 cast(sum(case when c.teamid in {PAID_TEAMS} then 1 else 0 end) as varchar)
from postgresql_core.public.claiming c
where c.deletedat is null and c.status = 'pending'
group by 1""")
    out = {}
    for r in rows:
        out[int(r[0])] = {"paid": r[1] == "1", "n": int(r[2]), "oldest": r[3],
                          "profiles": [p for p in (r[4] or "").split(",") if p],
                          "claims": [c for c in (r[5] or "").split(",") if c],
                          "paid_n": int(r[6] or 0)}
    return out


CLICKUP_LIST = os.environ.get("VQR_CLICKUP_LIST", "901000600160")   # User Requests
CLICKUP_OPEN = ("to do", "waiting", "in progress")
# A ticket carries these once WE have done something with it. Its absence is the only honest
# reading of "nobody has touched it yet" available from the ticket itself.
MERGE_TOUCHED = ("merge-claim-first-asked", "merge-queued", "merge-contested-hold",
                 "merge-keep-conflict", "merge-intake-stale")


def clickup_merge_queue(now: datetime) -> dict:
    if OFFLINE:
        return {}
    """The captain's merge table needs the ClickUp user-requests queue, not just core's
    ledger: 242 open profile-merge tickets live there and core knows about almost none of
    them. Read-only (`tasks list`), three single-status walks — one call per status, because
    the CLI silently ignores a multi-status filter and pages the whole list (~3 min)."""
    env = dict(os.environ)
    try:
        with open(ENV_FILE, errors="replace") as fh:
            for line in fh:
                line = line.strip()
                if line and not line.startswith("#") and "=" in line:
                    k, v = line.split("=", 1)
                    env.setdefault(k.strip(), v.strip().strip('"').strip("'"))
    except OSError:
        pass
    muso = "/usr/local/bin/muso" if os.path.exists("/usr/local/bin/muso") else "muso"
    tasks = []
    for status in CLICKUP_OPEN:
        for page in range(6):
            p = subprocess.run([muso, "clickup", "tasks", "list", "--list", CLICKUP_LIST,
                                "--query", f"page={page}", "--query", f"statuses[]={status}",
                                "--json"], capture_output=True, text=True, timeout=60, env=env)
            if not p.stdout.strip().startswith("{"):
                raise RuntimeError((p.stderr or p.stdout)[-200:])
            d = json.loads(p.stdout).get("data") or {}
            got = d.get("tasks") or []
            tasks.extend(got)
            if d.get("last_page") or not got:
                break
    def tags(t):
        return {x.get("name") for x in (t.get("tags") or [])}
    merge = [t for t in tasks if "action:profile-merge" in tags(t)]
    today = now.strftime("%Y-%m-%d")
    out = {"open": len(merge), "untouched": 0, "waiting_user": 0, "held": 0,
           "done24": 0, "declined_known": 0, "grid": {}}
    for label, _, _ in DATE_BUCKETS:
        out["grid"][label] = {c: 0 for c, _ in GRID_COLS}
    def bucket_of(t):
        raw = t.get("date_created")
        try:
            then = datetime.fromtimestamp(int(raw) / 1000, timezone.utc)
        except (TypeError, ValueError):
            return None
        return date_bucket((now - then).total_seconds() / 3600)

    for t in merge:
        tg = tags(t)
        label = bucket_of(t)
        if any(str(x).startswith("merge-outcome:") for x in tg):
            if f"merge-outcome-at:{today}" in tg:
                out["done24"] += 1
            continue
        if "merge-claim-first-asked" in tg:
            out["waiting_user"] += 1
            col = "c"
        elif tg & set(MERGE_TOUCHED):
            out["held"] += 1
            col = "e"
        else:
            out["untouched"] += 1
            col = "a"
        if label:
            out["grid"][label][col] += 1
    return out


def merge_rows() -> dict[str, dict]:
    """core's merge ledger, one row per request: `status` is unverified (never run),
    callback_received (the backend asked us to call back) or verified (landed, with
    `verified_at`). There are no "declined" rows in core: a refused merge writes nothing, so
    a decline has to come from the ClickUp ticket side, which is reported as unmeasured here
    rather than as zero."""
    rows = trino("""
select cast(m.status as varchar), cast(count(*) as varchar),
 cast(count(distinct json_extract_scalar(m.requested_by, '$.email')) as varchar),
 cast(min(m.created_at) as varchar), cast(max(m.verified_at) as varchar),
 cast(max(m.last_verify_at) as varchar)
from postgresql_core.public.profile_merges m group by 1""", numeric_first=False)
    return {r[0]: {"rows": int(r[1]), "users": int(r[2]), "oldest": r[3],
                   "verified_at": r[4], "last_verify_at": r[5]} for r in rows}


def merges_24h() -> dict[str, int]:
    rows = trino("""
select cast(count(*) as varchar), cast(count(distinct json_extract_scalar(m.requested_by, '$.email')) as varchar)
from postgresql_core.public.profile_merges m
where m.status = 'verified' and m.verified_at > now() - interval '24' hour""")
    if not rows:
        return {"rows": 0, "users": 0}
    return {"rows": int(rows[0][0]), "users": int(rows[0][1]) if len(rows[0]) > 1 else 0}


def flow_24h(table: str, paid_col: str, good: str, bad: str) -> dict[str, dict]:
    """Rows that left the queue in the last 24h, per outcome. `paid_col` is the table's own
    paid marker: credit rows carry a workspace, claim rows a team."""
    rows = trino(f"""
select cr.status, cast(count(*) as varchar), cast(count(distinct cr.userid) as varchar),
 cast(count(distinct case when cr.{paid_col} in {PAID_TEAMS} then cr.userid end) as varchar)
from postgresql_core.public.{table} cr
where cr.deletedat is null and cr.status in ('{good}','{bad}')
 and cr.updatedat > now() - interval '24' hour
group by 1""", numeric_first=False)
    out = {"approved": {"rows": 0, "users": 0, "paid": 0},
           "declined": {"rows": 0, "users": 0, "paid": 0}}
    for status, n, users, paid in rows:
        out["approved" if status == good else "declined"] = {
            "rows": int(n), "users": int(users), "paid": int(paid)}
    return out


def pending_request_ids() -> list[str]:
    """The id of every credit request waiting on the user's verification. An empty answer is a
    failed read, never "nothing is pending": the wrapper drops every line it cannot parse."""
    rows = trino("select lower(cast(cr.id as varchar)) from postgresql_core.public.credit_requests cr "
                 "where cr.deletedat is null and cr.status = 'user_verification_needed'",
                 numeric_first=False)
    if not rows:
        raise RuntimeError("the pending-request read returned no rows")
    return [r[0] for r in rows]


def ask_campaigns() -> tuple[str, ...]:
    """The ledger's own list of campaigns that ASK the user for something."""
    here = os.path.dirname(os.path.abspath(__file__))
    if here not in sys.path:
        sys.path.insert(0, here)
    from credit_review import verify_ledger
    return tuple(verify_ledger.ASK_CAMPAIGNS)


def ask_gap(pending: list[str]) -> dict:
    """OURS: the pending requests no ask has been DELIVERED for. Joined by request id, against the
    ledger's sent ASK messages (a status note or a take-back notice is not an ask). Subtracting a
    count of sent ids from a count of pending ones under-reads it by every sent id that is no
    longer pending (16,861 on 2026-11-14). `never_asked` is the part of it with no
    `verify_requests` row of any campaign; the rest was tried and not delivered."""
    asks = ask_campaigns()
    db = sqlite3.connect(f"file:{LEDGER}?mode=ro", uri=True)
    try:
        delivered = {str(r[0]).lower() for r in db.execute(
            "SELECT DISTINCT r.request_id FROM verify_requests r "
            "JOIN verify_messages m ON m.id = r.message_row WHERE m.status = 'sent' "
            f"AND m.campaign IN ({','.join('?' * len(asks))})", asks)}
        tried = {str(r[0]).lower() for r in db.execute("SELECT DISTINCT request_id FROM verify_requests")}
    finally:
        db.close()
    ids = set(pending)
    return {"pending": len(ids), "ours": len(ids - delivered), "never_asked": len(ids - tried)}


def intake_1h() -> dict:
    """Credit requests created in the last hour: what the decisions of that hour are measured
    against (verification-standing.py `decisions_per_intake`)."""
    rows = trino("select cast(count(*) as varchar) from postgresql_core.public.credit_requests cr "
                 "where cr.createdat > now() - interval '1' hour")
    if not rows:
        raise RuntimeError("the intake read returned no row")
    return {"requests": int(rows[0][0])}


# The lanes whose membership is decided by the ledger + proof feed + watchlist: if any of those
# reads fails, the answer to "which lane is this row in" is unknown, so they are carried and
# reported unmeasured rather than recomputed from empty facts.
CLASSIFICATION_LANES = {"credits_untouched", "credits_docs_in", "claims_untouched",
                        "claims_docs_in"}

# Only the claim lanes read the proof feed: `classify_claim` holds a support@ contact, while
# `classify_credit` takes its proof tags from the ledger and reads no contact list at all.
PROOF_FEED_LANES = {"claims_untouched", "claims_docs_in"}


def _EMPTY_FACTS() -> dict:
    """The shape every reader expects, so an unreadable ledger degrades to "nothing known"
    (everything unmeasured) instead of aborting the unattended job."""
    return {"asked": {}, "messaged": {}, "latest": {}, "decided": set(),
            "replied": set(), "proof_waiting": {}, "proof_tags": {}, "muted": {}, "flagged": {},
            "claim_notes": {}, "claim_proofs": {}, "claim_replied": set(), "claim_muted": {},
            "claim_flagged": {}, "first_proof_hold": {}, "first_deadend": {},
            "support_contacts": set(), "doc_dates": None}


def ledger_facts() -> dict:
    """Everything the hydra ledger knows about who we have already touched."""
    if OFFLINE:
        return _EMPTY_FACTS()
    db = sqlite3.connect(f"file:{LEDGER}?mode=ro", uri=True)
    try:
        ask_marks = ",".join("?" * len(ASK_CAMPAIGNS))
        asked: dict[int, str] = {}
        for acct, at in db.execute(
                f"SELECT account_id, min(coalesce(sent_at, created_at)) FROM verify_messages "
                f"WHERE campaign IN ({ask_marks}) AND status IN ('sent','attempted') "
                f"AND account_id IS NOT NULL GROUP BY 1", ASK_CAMPAIGNS):
            if acct is not None and str(acct).strip().isdigit():
                asked[int(acct)] = at or ""
        messaged: dict[int, str] = {}
        for acct, at in db.execute(
                "SELECT account_id, min(coalesce(sent_at, created_at)) FROM verify_messages "
                "WHERE status IN ('sent','attempted') AND account_id IS NOT NULL GROUP BY 1"):
            if acct is not None and str(acct).strip().isdigit():
                messaged[int(acct)] = at or ""
        # Latest decider verdict per user. `support` is the decider's own ASK (see
        # decide.py: REQUEST SUPPORT = status user_verification_needed, the requester is
        # told), NOT a ticket and NOT a person: it never makes a row 'human'. A `hold`
        # reason naming a human is the only verdict that does.
        # The LATEST decision per user. The bare columns are safe ONLY because this query
        # has exactly one aggregate (max): SQLite then takes them from the row that holds
        # the maximum. Add a second aggregate here and every reason silently becomes an
        # arbitrary row's reason — which would move users between buckets.
        latest: dict[int, dict] = {}
        for uid, dec, reason, docreq, at, proof in db.execute(
                "SELECT user_id, decision, reason, doc_required, max(decided_at), proof_id FROM decisions "
                "WHERE user_id IS NOT NULL GROUP BY user_id"):
            latest[int(uid)] = {"decision": dec, "reason": reason or "",
                                "doc_required": int(docreq or 0), "at": at or "",
                                "proof_id": proof or ""}
        first_proof_hold: dict[int, str] = {}
        for uid, at in db.execute(
                "SELECT user_id, min(decided_at) FROM decisions WHERE decision='hold' "
                "AND user_id IS NOT NULL AND reason LIKE 'proof on file%' GROUP BY user_id"):
            first_proof_hold[int(uid)] = at or ""
        first_deadend: dict[int, str] = {}
        # LIKE, not substr(...) IN: the reasons are longer than the marker, so a prefix
        # compare has to be a LIKE or every dead-end hold silently falls out of the counter
        # (it did — the bucket read 0 while 438 rows were held on reject rules).
        #
        # The clock is the start of the CURRENT dead-end episode, not the first one ever: a
        # user held on a reject rule last week, resolved, then held again today must be
        # clocked from today — otherwise the fresh hold looks a week old and pages as if the
        # captain had slept through it (QA @3fd56a0).
        marks = [m + "%" for m in DECIDER_DEAD_ENDS]
        # `dead` IS the whole reason predicate — prefixing it with `reason LIKE` again would
        # compare a string to the boolean result of the OR and match nothing (QA @05262eb).
        #
        # The clock is the start of the CURRENT dead-end episode, not the first one ever: a
        # user held on a reject rule last week, resolved, then held again today must be
        # clocked from today, or the fresh hold looks a week old and pages as if the captain
        # had slept through it.
        #
        # ONE pass with a window function. A correlated `max(...)` subquery here is
        # catastrophic — the decider re-holds the same rows every 15 minutes, so there are
        # tens of thousands of candidate rows and each one scanned the 447k-row table: it
        # took 3m21s of CPU on node-8 and blew the tick's budget.
        dead = "(" + " OR ".join("reason LIKE ?" for _ in DECIDER_DEAD_ENDS) + ")"
        for uid, at in db.execute(
                "SELECT user_id, min(decided_at) FROM ("
                "  SELECT user_id, decided_at, decision, reason,"
                "    max(CASE WHEN NOT (decision='hold' AND " + dead + ") THEN decided_at END)"
                "      OVER (PARTITION BY user_id) AS last_ok"
                "  FROM decisions WHERE user_id IS NOT NULL"
                ") WHERE decision='hold' AND " + dead +
                " AND (last_ok IS NULL OR decided_at > last_ok) GROUP BY user_id",
                marks + marks):
            first_deadend[int(uid)] = at or ""
        decided_users = {int(u) for (u,) in db.execute(
            "SELECT DISTINCT user_id FROM decisions WHERE user_id IS NOT NULL")}
        # A user who replied to a note (the removal was held for a human).
        replied = {int(a) for (a,) in db.execute(
            "SELECT DISTINCT account_id FROM verify_messages WHERE extension_requested_at IS NOT NULL "
            "AND account_id IS NOT NULL") if str(a).strip().isdigit()}
        # A document came back on a note and the review has not resolved it. The value is
        # WHEN it came back: the sentinel's clock for "we have owed this look since then".
        proof_tags: dict[int, list[str]] = {}
        for acct, at in db.execute(
                "SELECT account_id, proof_tagged_at FROM verify_messages m "
                "WHERE m.proof_tagged_at IS NOT NULL AND m.account_id IS NOT NULL "
                "AND NOT EXISTS (SELECT 1 FROM verify_proof_reviews r WHERE r.family = "
                "(CASE WHEN m.parent_row IS NULL THEN m.id ELSE m.parent_row END) "
                "AND r.request_id IN (SELECT value FROM json_each(m.request_ids_json)))"):
            if acct is not None and str(acct).strip().isdigit() and at:
                proof_tags.setdefault(int(acct), []).append(at)
        proof_waiting: dict[int, str] = {}
        for acct, at in db.execute(
                "SELECT m.account_id, min(m.proof_tagged_at) FROM verify_messages m "
                "WHERE m.proof_tagged_at IS NOT NULL AND m.account_id IS NOT NULL "
                "AND NOT EXISTS (SELECT 1 FROM verify_proof_reviews r WHERE r.family = "
                "(CASE WHEN m.parent_row IS NULL THEN m.id ELSE m.parent_row END) "
                "AND r.request_id IN (SELECT value FROM json_each(m.request_ids_json))) GROUP BY 1"):
            if acct is not None and str(acct).strip().isdigit():
                proof_waiting[int(acct)] = at or ""
        # Messaging holds: a refusal hold with a future recheck mutes the user; a flagged
        # hold has already been handed to #cs_priority.
        muted: dict[int, str] = {}
        flagged: dict[int, str] = {}
        now_z = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        for uid, recheck, flag, upd in db.execute(
                "SELECT user_id, next_recheck_at, flagged_at, updated_at FROM verify_refusal_holds "
                "WHERE user_id IS NOT NULL"):
            if not str(uid).strip().isdigit():
                continue
            if flag:
                flagged[int(uid)] = flag
            elif recheck and recheck > now_z:
                muted[int(uid)] = recheck
        # CLAIM-scoped copies of the reply / hold facts. The credit ledger's own reply and
        # refusal rows say nothing about a profile claim: a user who replied to an unrelated
        # credit note (or whose CREDIT messages are muted) must NOT read as "a person owns
        # this claim", which would hide real claim backlog behind a credit conversation.
        claim_campaigns = ",".join("?" * len(CLAIM_CAMPAIGNS))
        claim_replied = {int(a) for (a,) in db.execute(
            f"SELECT DISTINCT account_id FROM verify_messages WHERE account_id IS NOT NULL "
            f"AND extension_requested_at IS NOT NULL AND campaign IN ({claim_campaigns})",
            CLAIM_CAMPAIGNS) if str(a).strip().isdigit()}
        claim_muted: dict[int, str] = {}
        claim_flagged: dict[int, str] = {}
        for uid, recheck, flag in db.execute(
                f"SELECT user_id, next_recheck_at, flagged_at FROM verify_refusal_holds "
                f"WHERE user_id IS NOT NULL AND campaign IN ({claim_campaigns})",
                CLAIM_CAMPAIGNS):
            if not str(uid).strip().isdigit():
                continue
            if flag:
                claim_flagged[int(uid)] = flag
            elif recheck and recheck > now_z:
                claim_muted[int(uid)] = recheck
        # Claim notes: keyed by 'claim-<claiming.id>' inside request_ids_json.
        claim_notes: dict[str, dict] = {}
        for rid_json, status, at in db.execute(
                "SELECT request_ids_json, status, coalesce(sent_at, created_at) FROM verify_messages "
                "WHERE status IN ('sent','attempted') AND request_ids_json LIKE '%claim-%'"):
            try:
                keys = json.loads(rid_json or "[]")
            except ValueError:
                continue
            for k in keys if isinstance(keys, list) else []:
                if isinstance(k, str) and k.startswith("claim-"):
                    claim_notes.setdefault(k, {"at": at})
        claim_proofs: dict[str, str] = {}
        for rid_json, at in db.execute(
                # A tagged proof that a reviewer has already ACCEPTED is not waiting on us: exclude
                # claims with an accepted verify_proof_reviews row for the same family, else an
                # already-reviewed claim sits in the 24h docs_in lane and pages falsely (QA @059da4d).
                "SELECT m.request_ids_json, min(m.proof_tagged_at) FROM verify_messages m "
                "WHERE m.status IN ('sent','attempted') AND m.proof_tagged_at IS NOT NULL "
                "AND m.request_ids_json LIKE '%claim-%' "
                "AND NOT EXISTS (SELECT 1 FROM verify_proof_reviews r WHERE r.family = "
                "(CASE WHEN m.parent_row IS NULL THEN m.id ELSE m.parent_row END) "
                "AND r.request_id IN (SELECT value FROM json_each(m.request_ids_json))) "
                "GROUP BY m.request_ids_json"):
            try:
                keys = json.loads(rid_json or "[]")
            except ValueError:
                continue
            for k in keys if isinstance(keys, list) else []:
                if isinstance(k, str) and k.startswith("claim-"):
                    claim_proofs.setdefault(k, at or "")
    finally:
        db.close()
    return {"asked": asked, "messaged": messaged, "latest": latest, "decided": decided_users,
            "replied": replied, "proof_waiting": proof_waiting,
            "proof_tags": proof_tags,
            "muted": muted, "flagged": flagged, "claim_notes": claim_notes,
            "claim_proofs": claim_proofs, "claim_replied": claim_replied,
            "claim_muted": claim_muted, "claim_flagged": claim_flagged,
            "first_proof_hold": first_proof_hold,
            "first_deadend": first_deadend, "support_contacts": set()}


def proof_feed() -> tuple[frozenset, dict]:
    if OFFLINE:
        return frozenset(), {}
    """The decider's document feed (/var/lib/credit-trust/proof-on-file.json):
    (users who emailed support@ in the last 90 days, feed metadata). The feed also carries
    one entry per (user, request, kind) — approved_doc / human_approved_after_doc (resolved)
    and pending_doc (a document is on file, the request is still open). The decider reads it
    to hold on "proof on file: human review"; we reuse ITS verdict (the hold reason) for the
    "we owe a look" bucket, so the two never disagree."""
    with open(PROOF) as fh:
        d = json.load(fh)
    contacts = ((d.get("gmail_contacts_90d") or {}).get("user_ids") or [])
    users = {int(u) for u in contacts if str(u).strip().isdigit()}
    return frozenset(users), {"generated_at": d.get("generated_at"),
                              "support_contacts_90d": len(users)}


def watchlist_ids() -> tuple[frozenset, frozenset]:
    if OFFLINE:
        return frozenset(), frozenset()
    """The fraud watchlist (policies/fraud-watchlist.json): entries carry tier 'fraud' or
    'review' plus the user and profile ids they name. Both tiers HOLD an approval, so both
    count as "held for fraud / watchlist"."""
    with open(WATCHLIST) as fh:
        d = json.load(fh)
    users: set[int] = set()
    profiles: set[str] = set()
    for e in d.get("entries") or []:
        for u in e.get("user_ids") or []:
            if str(u).strip().isdigit():
                users.add(int(u))
        for p in e.get("profile_ids") or []:
            profiles.add(str(p))
    return frozenset(users), frozenset(profiles)


# ── classification ─────────────────────────────────────────────────────────────

def qualifying_proof_tags(user: int, facts: dict, credit: dict) -> list[str]:
    """Every unreviewed proof tag that is NEWER than the user's newest open request, oldest
    first. The comparison has to happen BEFORE picking a tag: taking the minimum tag first made
    an old January tag hide an October one, so a user with a fresh returned document was
    classified `told` and the returned-document SLA was never watched (QA @4a25b33)."""
    tags = list((facts.get("proof_tags") or {}).get(user) or [])
    if not tags and (facts.get("proof_waiting") or {}).get(user):
        tags = [(facts["proof_waiting"] or {}).get(user)]
    req_at = parse_ts(credit.get("newest") or credit.get("oldest") or "")
    if not req_at:
        return []
    ok = [(parse_ts(t), t) for t in tags if t]
    return [t for d, t in sorted(x for x in ok if x[0] is not None and x[0] > req_at)]


def proof_newer_than_request(user: int, facts: dict, credit: dict) -> bool:
    """True when a document arrived AFTER the request it serves. The only proof source with a
    timestamp is the ledger (`verify_messages.proof_tagged_at`); it is compared against the
    user's OLDEST open request, so a document that predates every request that user has open
    never counts. An undateable proof counts for nothing — "we cannot date it" is not evidence
    that it is new (Fable, 2026-10-27)."""
    if qualifying_proof_tags(user, facts, credit):
        return True
    tag = (facts.get("proof_waiting") or {}).get(user)
    if not tag:
        return False
    # Compared against the user's NEWEST open request on purpose: a per-user bound cannot name
    # the one request a note served, so the strict end is the only safe one — a document older
    # than every open request can never be counted, and a worse-than-exact rule here makes the
    # lane quieter rather than louder (Fable: an old accepted document is not a returned one).
    tag_at = parse_ts(tag)
    req_at = parse_ts(credit.get("newest") or credit.get("oldest") or "")
    return bool(tag_at and req_at and tag_at > req_at)


def on_file_hold(lat: dict) -> bool:
    """Whether the decider's LATEST verdict for this user is a "a document is on file" hold.

    The decider's own sentence for it is "a document is already on file; never ask again; human
    review". A per-role split carries the same prefix but may have NO document at all (the catalog
    proved some roles and the rest are owed an ask): only the hold sentence, a hold, or a split
    with a recorded document is a document on file. The hold sentence is keyed on directly because
    a PARTIAL row held for a document on file keeps its decision and carries no proof_id.

    An ALLOWLIST of sentences, not a `proof on file` prefix: `proof on file: stage 2 judged the
    document` (decide.STAGE2_ASK_HOLD) is a different hold — that user has ALREADY been asked
    through a campaign, so reading it as "not told" would ask them again and reading it as
    "documents back" would page a breach nobody owes. It is not this lane.

    ONE predicate, read by the classifier and by the population whose document date is looked up,
    so the two can never disagree about who is in this lane."""
    reason = lat.get("reason") or ""
    return reason.startswith(ON_FILE_HOLD_PREFIXES)


def undated_hold_users(facts: dict) -> list[int]:
    """The users whose latest decider verdict is a "document on file" hold: the population whose
    document date is read, and the one reason 5 used to park on a person."""
    return sorted(u for u, lat in (facts.get("latest") or {}).items() if on_file_hold(lat))


def doc_lane_arrival(user: int, facts: dict, credit: dict) -> str | None:
    """When the document that keeps this row in `docs_in` arrived.

    The lane clock is the arrival of the EVIDENCE, not of the newest thing in the account: a
    document received 2026-10-20 that nobody has opened is still outstanding work when a second
    document arrived 2026-11-15 and was read, and clocking the row from the newer arrival files
    the older look as fresh and never pages its breach.

    So: the OLDEST arrival among the documents that are themselves the reason the row is here —
    every unread document (the look is ours), plus every read document dated on or after the
    request (the evidence that qualifies it).

    None when none of those has a usable arrival, so the caller falls back to the request date.
    Falling back to the newest arrival on file would clock the row from a document that is NOT the
    reason it is here — a current dated document with no recorded arrival beside an older
    non-qualifying one would be filed as pre-baseline LEGACY and its new breach never paged."""
    seen = (facts.get("doc_dates") or {}).get(user) or {}
    req_at = parse_ts(credit.get("newest") or credit.get("oldest") or "")
    stamps = []
    for doc in seen.get("docs") or ():
        if not doc.get("read"):
            stamps.append(doc.get("received_at"))
        elif doc.get("date") and req_at and doc["date"] >= req_at.date():
            stamps.append(doc.get("received_at"))
    parsed = [(parse_ts(t), t) for t in stamps if t]
    parsed = [x for x in parsed if x[0] is not None]
    if parsed:
        return min(parsed)[1]
    return None


def classify_on_file(user: int, facts: dict, credit: dict) -> str | None:
    """Where a "document on file" hold belongs now that the document can be DATED.

    The decider's proof feed carries no timestamp, so this hold used to be counted with a person
    ("we cannot date it"). The date is not missing from the box: the returned-document reader
    records every date it reads out of the file, so the hold is decided on the document's own
    date, exactly like a dated proof tag (5b/5c):

      - dated AFTER the request  -> docs_in: a returned document we owe a look at
      - dated ON the request day -> docs_in: it may have just been sent (see below)
      - dated BEFORE it          -> None: an old document is not proof, so the user is owed an
                                    ask for a current one
      - read, but no date in it  -> None: the user is owed an ask for a DATED copy
      - not read yet             -> docs_in: the look is OURS, and asking a customer for a copy of
                                    a document we have not opened is not an ask
      - no reader-eligible file  -> None: the reader will never look at it, so there is no look to
                                    owe; the ask lane is where it belongs

    None means "not ours to look at": the caller falls through to the ask/told logic, so a user
    who was ALREADY asked lands in `told` and only a never-asked one in `not_told`. Returning
    `not_told` from here would relabel an already-asked user as "needs documents - user NOT told".

    A document dated the SAME day as the request counts as returned: asking someone for a document
    they may have just sent is the one error this lane must never make.

    An unmeasured date (the reader's store could not be read) keeps the old reading — with a
    person — never a guess in either direction."""
    seen = (facts.get("doc_dates") or {}).get(user)
    if seen is None:
        return "human"
    if not seen.get("filed"):
        return None
    if not seen.get("read"):
        return "docs_in"
    doc_at = seen.get("date")
    req_at = parse_ts(credit.get("newest") or credit.get("oldest") or "")
    if doc_at is None or req_at is None:
        return None
    return "docs_in" if doc_at >= req_at.date() else None


def classify_credit(user: int, facts: dict, credit: dict, wz: frozenset) -> str:
    """Which bucket one open-credit user belongs to. First match wins (see module doc)."""
    lat = facts["latest"].get(user) or {}
    reason = lat.get("reason") or ""
    if user in wz:
        return "watch"
    if credit["core_reply"] or proof_newer_than_request(user, facts, credit):
        return "docs_in"
    # A person owns the row when a support ticket was raised, the user replied, or a flagged
    # refusal hold is already posted. This outranks the document-on-file reading: a ticket is a
    # person's.
    # NOT `decision == "support"`: that write is our OWN ask, not a ticket and not a person
    # (captain 2026-11-16, "the only people involved should be the requester"). decide.py's
    # REQUEST SUPPORT moves the row to user_verification_needed and Knock sends the "more
    # info needed" notice, so the requester is the one who was told and the row carries on
    # down the ask/approve/no ladder: `told` once core records that notice, `not_told` while
    # the write has not landed (the report's own decided-not-closed class). Calling it a
    # support ticket parked every asked row on a person who was never working it.
    # NOT having emailed support@ either: the decider stopped parking those users on 2026-11-14
    # (#1992) and asks them through the verify notes instead (#2090), and the credit classifier
    # reads no contact list at all (#2108). The ledger is append-only, so the old "emailed
    # support@ … never asked" sentences are still on file; no code treats them as a hold, and
    # such a row falls through to muted / told / untouched / not_told.
    # A CLAIM whose claimant emailed support@ is still a person (classify_claim below:
    # claim_proof_ask still holds those claimants).
    if "support already requested" in reason or user in facts["replied"] \
            or user in facts["flagged"]:
        return "human"
    # A "proof on file" hold is NOT "documents back, we owe a look" unless the document can be
    # shown to postdate the request (Fable, 2026-10-27). It used to be counted with a person
    # because the proof feed carries no timestamp at all; the reader's own extraction does, so the
    # hold is now decided on the document's own date (classify_on_file) and never parks on a human.
    if on_file_hold(lat):
        where = classify_on_file(user, facts, credit)
        if where:
            return where
    if user in facts["muted"]:
        return "muted"
    if user in facts["asked"] or credit["core_ask"]:
        return "told"
    if user not in facts["decided"] and user not in facts["messaged"]:
        return "untouched"
    return "not_told"


def classify_claim(user: int, facts: dict, claim: dict, wz: frozenset,
                   wz_profiles: frozenset) -> str:
    """Claims use CLAIM-scoped facts only: a credit decision says nothing about a claim, so
    it must never make a claim look touched. What counts here is a claim note ("claim-<id>"
    in the ledger), the claimant emailing support@, and the watchlist (by user or profile)."""
    if user in wz or (wz_profiles & set(claim["profiles"])):
        return "watch"
    # A document that came back on a claim note is OURS to review, and that outranks every
    # other reading — including a messaging hold: the claimant may ALSO have replied in words
    # (claim_replied), be a support@ contact, or be inside a refusal hold, and each of those
    # branches used to win, which kept the returned document out of claims_docs_in so its 24h
    # SLA could never page (QA @e878249, @be2b000, @0b45ef9).
    if any(facts["claim_proofs"].get(f"claim-{cid}") for cid in claim["claims"]):
        return "docs_in"
    if user in facts["claim_muted"]:
        return "muted"
    if user in facts["claim_replied"] or user in facts["claim_flagged"] \
            or user in facts["support_contacts"]:
        return "human"
    if any(f"claim-{cid}" in facts["claim_notes"] for cid in claim["claims"]):
        return "told"
    return "untouched"



# ── backlog sentinel ───────────────────────────────────────────────────────────

def parse_ts(ts: str) -> datetime | None:
    """Parse BOTH timestamp spellings this program meets: core's
    `2026-10-26 20:40:29.948000 UTC` and the ledger's `2026-10-26T20:40:29Z`. Returns
    None for anything unreadable — an unparseable timestamp must never be read as
    "just arrived" (that would hide a breach) and never as ancient (that would page)."""
    if not ts:
        return None
    v = ts.strip().replace(" UTC", "+00:00").replace(" ", "T", 1)
    if v.endswith("Z"):
        v = v[:-1] + "+00:00"
    try:
        d = datetime.fromisoformat(v)
    except ValueError:
        return None
    return d if d.tzinfo else d.replace(tzinfo=timezone.utc)


def hours_between(earlier: str, now: datetime) -> float | None:
    d = parse_ts(earlier)
    return None if d is None else max(0.0, (now - d).total_seconds() / 3600)


def merges_waiting() -> list[tuple[str, str]]:
    """Open profile merges, i.e. a person owes the next step: `unverified` (never run)
    and `callback_received` (the backend asked us to call back). `verified` is done."""
    rows = trino("""
select cast(m.id as varchar), cast(m.status as varchar), cast(m.created_at as varchar)
from postgresql_core.public.profile_merges m
where m.status in ('unverified','callback_received')""", numeric_first=False)
    return [(f"merge:{r[0]}", r[2]) for r in rows]


def intercom_search(query: dict, per_page: int = 150, max_pages: int = 40,
                    deadline_s: float = 25.0,
                    start_after: str | None = None) -> tuple[list, bool, str | None]:
    """One paged Intercom conversation search. Returns (conversations, truncated).
    The filter is applied SERVER-side: walking every open conversation cost ~170s on
    node-8 (5,262 open, 36 pages at ~4.7s each), which alone would blow the 2-minute
    tick. A `updated_at > last_walk` filter returns a handful instead."""
    token = None
    for line in open(ENV_FILE, errors="replace"):
        if line.startswith("MUSOAI_INTERCOM_TOKEN="):
            token = line.split("=", 1)[1].strip().strip('"').strip("'")
    if not token:
        raise RuntimeError(f"MUSOAI_INTERCOM_TOKEN is not in {ENV_FILE}")
    out, after, pages = [], start_after, 0
    started = time.time()
    while pages < max_pages:
        if time.time() - started > deadline_s:
            return out, True, after   # truncated: resume from here, never "nothing waiting"
        body = {"query": query, "pagination": {"per_page": per_page}}
        if after:
            body["pagination"]["starting_after"] = after
        req = urllib.request.Request(
            "https://api.intercom.io/conversations/search", data=json.dumps(body).encode(),
            headers={"Authorization": f"Bearer {token}", "Accept": "application/json",
                     "Content-Type": "application/json", "Intercom-Version": "2.11"})
        d = json.load(urllib.request.urlopen(req, timeout=15))
        pages += 1
        out.extend(d.get("conversations") or [])
        nxt = (d.get("pages") or {}).get("next")
        after = nxt.get("starting_after") if isinstance(nxt, dict) else None
        if not after:
            return out, False, None
    return out, True, after


def owes_reply(c: dict) -> tuple[bool, str]:
    """(customer spoke last, when). A conversation we owe a reply on is one where the
    customer's last message is at or after ours, or where we have never written. See
    owes_reply_ever() for the comms-coverage question ("have we EVER answered them")."""
    st = c.get("statistics") or {}
    src = c.get("source") or {}
    admin_at = st.get("last_admin_reply_at") or 0
    contact_at = st.get("last_contact_reply_at") or 0
    created = c.get("created_at") or 0
    delivered = src.get("delivered_as")
    inbound = (delivered == "customer_initiated" if delivered
               else (src.get("author") or {}).get("type") in ("user", "lead", "contact"))
    if (admin_at == 0 and contact_at == 0 and inbound) or (contact_at and admin_at <= contact_at):
        when = contact_at or created
        return True, datetime.fromtimestamp(when, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    return False, ""


def apply_intercom(convs, held: dict, never_answered: dict) -> None:
    """Fold a batch of conversations into BOTH ledgers: who we owe a reply (held) and who has
    never had one (never_answered). One function so no scan path can update only the first —
    a complete scan used to return `info=None`, which dropped the never-answered ledger
    entirely and made the comms class read zero (QA @62baa91)."""
    for c in convs:
        cid = f"conv:{c.get('id')}"
        owed, when = owes_reply(c)
        if owed:
            held[cid] = when
            if ever_answered(c):
                never_answered.pop(cid, None)
            else:
                never_answered[cid] = when
        else:
            held.pop(cid, None)
            never_answered.pop(cid, None)


def ever_answered(c: dict) -> bool:
    """True when an admin has EVER replied on this conversation. A conversation the customer
    is still waiting on with no admin reply at all is the "never told" class the captain asked
    about — different from "waiting on us" (which includes threads we answered and then went
    quiet on)."""
    return bool(((c.get("statistics") or {}).get("last_admin_reply_at")) or 0)


def intercom_items(prev_state: dict | None, now: datetime) -> tuple[list[tuple[str, str]], str | None]:
    """The Intercom owe-reply set, carried forward between ticks.

    Exact, and cheap: a conversation can only change classification when it is UPDATED,
    so each tick re-reads (a) open conversations updated since the last walk and (b)
    conversations closed since the last walk. Everything else keeps its last verdict,
    which is why we only walk a handful of pages instead of 36. A first run (or a lost
    state file) falls back to the full open walk once."""
    held: dict[str, str] = {}
    never_answered: dict[str, str] = dict(
        ((prev_state or {}).get("intercom") or {}).get("never_answered") or {})
    ic = (prev_state or {}).get("intercom") or {}
    last_walk = ic.get("last_walk") or ""
    for iid, entered in (ic.get("items") or {}).items():
        held[iid] = entered
    since = parse_ts(last_walk)
    everything = since is None
    if everything:
        # A first / post-state-loss scan that hits the deadline is PARTIAL. Advancing the
        # watermark on it would make the next tick a delta over a set that never contained
        # the conversations the partial scan skipped — they would stay invisible until they
        # happened to change, and the lane would read measured-and-clear (QA @0b3507c).
        # So: resume from the saved cursor, carry what we already have, and do NOT advance
        # the watermark until a complete snapshot exists.
        convs, truncated, cursor = intercom_search(
            {"field": "state", "operator": "=", "value": "open"},
            start_after=ic.get("boot_cursor"))
        apply_intercom(convs, held, never_answered)
        if truncated:
            return sorted(held.items()), {"truncated": True, "cursor": cursor,
                                          "items": dict(held),
                                          "never_answered": dict(never_answered)}
        # a COMPLETE full walk already covers every open conversation: no delta or closed scan
        # is needed, and falling through would run them against a watermark that does not
        # exist yet
        return sorted(held.items()), {"never_answered": dict(never_answered)}
    else:
        ep = max(0, int(since.timestamp()) - INTERCOM_DELTA_OVERLAP_S)
        convs, truncated, delta_cursor = intercom_search({"operator": "AND", "value": [
            {"field": "state", "operator": "=", "value": "open"},
            {"field": "updated_at", "operator": ">", "value": ep}]},
            start_after=ic.get("delta_cursor"))
    apply_intercom(convs, held, never_answered)
    if truncated and not everything:
        # A partial DELTA cannot advance the watermark (conversations it skipped would stay
        # invisible), but it must not re-read the same pages for ever either: the window only
        # grows, so every later tick truncates too and the lane is stuck unmeasured — that is
        # exactly what happened on 10-27 (watermark frozen at 07:25Z, 30.9s and truncated every
        # tick). Save the resume cursor and carry on from it next tick.
        return sorted(held.items()), {"truncated": True, "keep_walk": True,
                                      "cursor": delta_cursor,
                                      "never_answered": dict(never_answered)}
    if not everything:
        ep = max(0, int(since.timestamp()) - INTERCOM_DELTA_OVERLAP_S)
        closed, closed_trunc, closed_cursor = intercom_search({"operator": "AND", "value": [
            {"field": "state", "operator": "=", "value": "closed"},
            {"field": "updated_at", "operator": ">", "value": ep}]},
            start_after=ic.get("closed_cursor"))
        # Apply the closures we DID see BEFORE deciding whether to resume: on a truncated
        # scan the rows already returned are evidence, and dropping them left a conversation
        # that closed on page 1 counted (and paged) as awaiting a reply, while the resumed
        # scan started at page 2 and never revisited it (QA @ecfa985).
        for c in closed:
            held.pop(f"conv:{c.get('id')}", None)
            never_answered.pop(f"conv:{c.get('id')}", None)
        if closed_trunc:
            # a partial CLOSED scan is just as unsafe as a partial open one: a conversation
            # we owe that was closed in an omitted page stays carried and keeps paging as
            # open. Hold the watermark and resume this scan from its cursor next tick.
            return sorted(held.items()), {"truncated": True, "keep_walk": True,
                                          "closed_cursor": closed_cursor,
                                          "never_answered": dict(never_answered)}
    # EVERY scan outcome hands the never-answered ledger back, complete delta included: a
    # complete delta used to return None here, so probe_sources saved items+last_walk only and
    # carry_caches dropped the ledger — the comms class read 0 (QA @265e00b).
    return sorted(held.items()), {"never_answered": dict(never_answered)}


def probe_stale(base_ts: str | None, state: dict | None) -> bool:
    """True when the state under the lock is not the state the out-of-lock probe was taken
    from. Then the probe's source results are the stale ones: writing them would roll the
    owed-reply set back and wipe the delivered-page ledger, so a later tick would re-page work
    this one already reported.

    A NO-STATE -> state transition counts too (QA @17edb6c): two first-run ticks both probe
    with nothing, and the later lock holder must not overwrite the earlier tick's set."""
    now_ts = (state or {}).get("ts")
    if now_ts is None:
        return False                 # nothing written yet: whatever we probed is still news
    return base_ts != now_ts         # includes base_ts is None (we probed no state)


def probe_sources(prev_state: dict | None, now: datetime) -> dict:
    """The two source reads that need a network round-trip, done BEFORE the sentinel lock is
    taken. They are the slow part (Intercom especially); holding the shared state lock across
    them starves the other tick, and did: at 22:30Z a light tick and the full report started
    on the same second and the report lost the lock for its whole 120s wait."""
    probe = {"merges": None, "intercom": None, "intercom_flag": None, "errors": [],
             "unmeasured": set()}
    if OFFLINE:
        probe["unmeasured"] |= {"merges_waiting", "intercom_customer_last"}
        return probe
    try:
        merges = dict(merges_waiting())
        probe["merges"] = {"items": merges,
                           "last_walk": now.strftime("%Y-%m-%dT%H:%M:%SZ")}
    except Exception as e:                                      # noqa: BLE001
        probe["unmeasured"].add("merges_waiting")
        probe["errors"].append(f"merges: {e}")
    try:
        convs, info = intercom_items(prev_state, now)
        if isinstance(info, dict) and info.get("truncated"):
            # Partial scan: keep the items we have, keep the watermark where it was, and carry
            # the resume cursor so the next tick continues instead of re-reading page 1 for
            # ever. Keys are mapped EXPLICITLY — a chained str.replace here silently stored the
            # closed cursor as `closed_delta_cursor` while the reader asks for `closed_cursor`,
            # so a truncated closed scan never resumed (QA @c61de56).
            prev_ic = (prev_state or {}).get("intercom") or {}
            if info.get("keep_walk"):
                probe["intercom"] = {"items": dict(convs),
                                     "last_walk": prev_ic.get("last_walk") or ""}
                if info.get("never_answered") is not None:
                    probe["intercom"]["never_answered"] = info["never_answered"]
                for src_key, state_key in INTERCOM_CURSORS:
                    value = info.get(src_key) or prev_ic.get(state_key)
                    if value:
                        probe["intercom"][state_key] = value
            else:
                # the FIRST scan was truncated: keep the resume cursor AND the ledger we built
                # from the pages we did read, or the resumed scan starts from an empty
                # never-answered set and the earlier page is never revisited (QA @ccd62bf)
                probe["intercom"] = {"items": dict(convs), "last_walk": "",
                                     "boot_cursor": info.get("cursor"),
                                     "never_answered": info.get("never_answered") or {}}
        else:
            probe["intercom"] = {"items": dict(convs),
                                 "last_walk": now.strftime("%Y-%m-%dT%H:%M:%SZ")}
            if info and info.get("never_answered") is not None:
                probe["intercom"]["never_answered"] = info["never_answered"]
        partial = isinstance(info, dict) and bool(info.get("truncated"))
        probe["intercom_flag"] = partial
        if partial:
            probe["unmeasured"].add("intercom_customer_last")
    except Exception as e:                                      # noqa: BLE001
        probe["unmeasured"].add("intercom_customer_last")
        probe["errors"].append(f"intercom: {e}")
    return probe


def earliest(timestamps) -> str:
    """The oldest of a set of timestamps, string-agnostic (the two spellings this program meets
    do not sort correctly as text). Used where a USER owns several items: the lane's clock is
    the oldest outstanding one, never whichever the query happened to return first (QA @36fb305
    — two claims, one proof 49h old and one 1h old, let the fresh one hide the breach)."""
    parsed = [(parse_ts(t), t) for t in timestamps if t]
    parsed = [(d, t) for d, t in parsed if d is not None]
    return min(parsed)[1] if parsed else ""


def sentinel_items(credits: dict, claims: dict, facts: dict, classify_c, classify_k,
                   wz: frozenset, wz_profiles: frozenset, *, light: bool = False,
                   prev_state: dict | None = None, now: datetime | None = None,
                   probe: dict | None = None, failed_pop: frozenset = frozenset()) -> dict:
    """{bucket key: [(item id, when it ENTERED this waiting-on-us state)]}, plus the
    buckets this host cannot see. Each item's clock is the moment the ball moved into OUR
    court, not the row's birthday: a document that landed an hour ago is not a 3-year-old
    backlog item.

    In `light` mode (the 5-minute tick) the two sources that need a network round-trip are
    CARRIED from the previous state instead of re-read: merges (Trino) and Intercom (API).
    That is exact rather than a guess for Intercom, whose set is maintained as a delta, and
    near-exact for merges, which move a couple of times a day. An unmeasured bucket is
    reported as unmeasured, never as 0."""
    items: dict[str, list] = {k: [] for k, _, _, _ in SENTINEL_BUCKETS}
    prev_state = prev_state or {}
    carried_items = prev_state.get("items") or {}
    if light:
        # The 5-minute tick must be CHEAP: the two per-user Trino queries behind credits
        # and claims cost ~25s, and re-running them 12x an hour buys nothing — an item can
        # only cross its SLA on an age, which this tick recomputes from the carried set.
        # Anything that ENTERED a bucket since the last 30-minute tick is picked up there.
        for key in ("credits_untouched", "credits_docs_in", "claims_untouched",
                    "claims_docs_in", "fable_decider"):
            items[key] = sorted((carried_items.get(key) or {}).items())
        merged_light = True
    else:
        merged_light = False
    for uid, c in (() if light or "credits_untouched" in failed_pop else credits.items()):
        key = classify_c(uid, c)
        if key == "untouched":
            items["credits_untouched"].append((f"user:{uid}", c["oldest"]))
        elif key == "docs_in":
            # Clock from the evidence that QUALIFIED the row, not from a historic hold: an old
            # "proof on file" hold followed by a brand-new response used to date the lane from
            # the old hold, so the fresh document was filed as pre-baseline legacy and never
            # paged as a new breach (QA @ecfa985).
            qualifying = [c.get("reply_at")] + qualifying_proof_tags(uid, facts, c)
            if on_file_hold(facts["latest"].get(uid) or {}) \
                    and not (c.get("core_reply") or proof_newer_than_request(uid, facts, c)):
                sent_at = doc_lane_arrival(uid, facts, c)
                if sent_at:
                    qualifying.append(sent_at)
            entered = earliest(qualifying) or c["oldest"]
            items["credits_docs_in"].append((f"user:{uid}", entered))
    for uid, k in (() if light or "claims_untouched" in failed_pop else claims.items()):
        key = classify_k(uid, k)
        if key == "untouched":
            items["claims_untouched"].append((f"user:{uid}", k["oldest"]))
        elif key == "docs_in":
            # the OLDEST unreviewed proof across the user's pending claims, never the first one
            # the query returned
            entered = earliest(facts["claim_proofs"].get(f"claim-{cid}") for cid in k["claims"])
            entered = entered or earliest(
                (facts["claim_notes"].get(f"claim-{cid}") or {}).get("at") for cid in k["claims"])
            items["claims_docs_in"].append((f"user:{uid}", entered or k["oldest"]))
    # A decider hold that no machine arm will ever clear: the clock is the hold itself.
    if not light:
        for uid, at in facts["first_deadend"].items():
            # the FIRST dead-end hold is the clock, but only while the LATEST verdict is
            # still one: otherwise a resolved hold (approved, supported, re-decided) would
            # keep the user counted — and paged — as "waiting on a person" forever
            # (QA @3974dfd).
            lat = facts["latest"].get(uid) or {}
            if lat.get("decision") == "hold" and \
                    (lat.get("reason") or "").startswith(DECIDER_DEAD_ENDS):
                items["fable_decider"].append((f"user:{uid}", at))

    unmeasured: set[str] = set(failed_pop)
    # A population query that FAILED leaves an empty dict, which would read as "this lane is
    # empty" and overwrite the carried items with zeros. Carry the last known set instead and
    # report the lane unmeasured (QA @3974dfd).
    for key in failed_pop:
        items[key] = sorted((carried_items.get(key) or {}).items())
    now = now or datetime.now(timezone.utc)
    # The network reads arrive pre-fetched (probe_sources, before the lock). They are
    # refreshed on EVERY tick, light included: a customer replying is the one thing that can
    # move a waiting item in or out of a lane between the 30-minute reports.
    probe = probe or {"merges": None, "intercom": None, "errors": [], "unmeasured": set()}
    unmeasured |= set(probe.get("unmeasured") or ())
    if probe.get("merges"):
        items["merges_waiting"] = sorted((probe["merges"]["items"] or {}).items())
        items["_merges"] = probe["merges"]
    elif "merges_waiting" in unmeasured:
        # a transient Trino failure must not blank a lane the captain is already told about
        items["merges_waiting"] = sorted(
            ((carried_items.get("merges_waiting")
              or (prev_state or {}).get("merges", {}).get("items") or {})).items())
    if probe.get("intercom"):
        items["intercom_customer_last"] = sorted((probe["intercom"]["items"] or {}).items())
        items["_intercom"] = probe["intercom"]
    elif "intercom_customer_last" in unmeasured:
        # the probe FAILED: an empty list here would read as "nobody is owed a reply" and
        # would also drop the lane's delivery ledger. Carry the last known set instead — a
        # broken probe may neither hide work nor clear what the captain was already told.
        items["intercom_customer_last"] = sorted(
            ((carried_items.get("intercom_customer_last")
              or (prev_state or {}).get("intercom", {}).get("items") or {})).items())
    if probe.get("errors"):
        items["_errors"] = items.get("_errors", []) + list(probe["errors"])
    # There is no per-thread support@ ledger on this host: the hourly triage is an agent
    # skill that reads Gmail and persists nothing, and `gog` needs a keyring password.
    # UNMEASURED, never 0 — "we cannot see it" must not read as "nothing is waiting".
    unmeasured.add("support_unanswered")
    return {"items": items, "unmeasured": unmeasured}



# ── the date x state grid (captain 2026-10-27 00:5xZ) ─────────────────────────

DATE_BUCKETS = (("today", 0, 1), ("1-2 d", 1, 3), ("3-7 d", 3, 8), ("8-30 d", 8, 31),
                ("31-90 d", 31, 91), ("91-365 d", 91, 366), (">1 y", 366, 10 ** 6))
GRID_COLS = (("a", "US: not answered"), ("b", "US: answered"), ("c", "USER: told"),
             ("d", "USER: not told"), ("e", "held"))
GRID_CLOSED = (("approved", "appr"), ("declined", "decl"), ("closed", "closed"))


def date_bucket(hours: float) -> str:
    days = hours / 24
    for label, lo, hi in DATE_BUCKETS:
        if lo <= days < hi:
            return label
    return ">1 y"


def grid_column(bucket: str) -> str:
    """Map the report's bucket onto the captain's five states.
    a = we never answered them; b = we have answered and it is back with us (a document
    arrived, a person owns it); c = we told them what we need; d = they need something but
    were never told; e = a gate (fraud, watchlist, messaging hold) holds it."""
    return {"untouched": "a", "docs_in": "b", "human": "b", "not_told": "d",
            "told": "c", "muted": "e", "watch": "e"}.get(bucket, "a")


def grid_build(pop: dict, classify, flows: dict) -> dict:
    cells = {label: {c: {"users": 0, "rows": 0, "paid": 0} for c, _ in GRID_COLS}
             for label, _, _ in DATE_BUCKETS}
    for user, item in pop.items():
        h = item.get("oldest_h")
        if h is None:
            continue
        col = grid_column(classify(user, item))
        cell = cells[date_bucket(h)][col]
        cell["users"] += 1
        cell["rows"] += item["n"]
        cell["paid"] += 1 if item["paid"] else 0
    closed24 = {"approved": flows.get("approved", {}), "declined": flows.get("declined", {}),
                "closed": {}}
    return {"cells": cells, "closed24": closed24}


def grid_render(title: str, g: dict, unit: str) -> list[str]:
    head = f"{title}  users (requests) [paid]"
    w = 12
    lines = [head, "",
             "date".ljust(w) + "".join(f"{k}: {lbl}".ljust(20) for k, lbl in GRID_COLS)]
    for label, _, _ in DATE_BUCKETS:
        cells = g["cells"][label]
        total = sum(c["users"] for c in cells.values())
        if not total:
            continue
        row = label.ljust(w)
        for k, _ in GRID_COLS:
            c = cells[k]
            row += (f"{c['users']} ({c['rows']}) [{c['paid']}]").ljust(20)
        lines.append(row)
    cl = g["closed24"]
    lines.append("closed last 24h (not bucketed by date): " + " / ".join(
        f"{lbl} {(cl[k] or {}).get('users', 0)} users ({(cl[k] or {}).get('rows', 0)})"
        for k, lbl in GRID_CLOSED if (cl[k] or {}).get("users")))
    return lines



# ── comms coverage (captain 2026-10-27 20:1xZ) ────────────────────────────────
# "are you sure all users that need to be communicated have been already?" The five classes
# below are the ones where a person is still owed a message. `job` names the thing that owns
# sending it, so the block answers "who fixes this" as well as "how bad is it".


def comms_classes() -> tuple:
    """(key, label, owner job, paid-aware) for the five classes, in report order."""
    return (
        ("credits_waiting_us", "credits waiting on us, never told", "verify-ask-wiring-h2", True),
        ("credits_owing_proof", "credits owing proof, never asked", "verify-ask-wiring-h2", True),
        ("claims_pending", "profile claims pending, never told", "claim-lane-resume-c2", True),
        ("merges_pending", "profile merges pending, never told", "merge-queue-clear-q1", False),
        ("intercom_inbound", "Intercom inbound, never answered", "intercom-backlog-i1", False),
    )


def comms_build(credits: dict, claims: dict, facts: dict, classify_c, classify_k,
                wz: frozenset, wz_profiles: frozenset, clickup: dict,
                intercom_never: dict, now: datetime, unmeasured: set | frozenset = frozenset()) -> dict:
    """Per class: how many people are still owed a message, split paid/free, with the oldest
    age on each side. "Never told" means literally no message ever: for credits/claims that is
    the `untouched` class (no ask, no message, no decision); `not_told` is the owing-proof
    class (they need documents and were never asked); for Intercom it is a conversation the
    customer is waiting on with no admin reply at all. Paid is unmeasured where the source
    cannot tell us (merges carry no plan; Intercom paid needs an account join) — never 0."""
    # `measured` is per class (QA @059da4d): a truncated or failed source read must not print
    # its partial map as a complete count, nor persist a zero baseline that pages as growth
    # when the source recovers. Unmeasured classes render as such, keep the previous
    # signature, and never page.
    out = {k: {"paid": 0, "free": 0, "paid_oldest_h": None, "free_oldest_h": None,
               "owner": job, "paid_known": paid_aware, "measured": True}
           for k, _, job, paid_aware in comms_classes()}

    def add(key: str, is_paid, oldest):
        c = out[key]
        h = age_h(oldest, now) if oldest else None
        side = "paid" if is_paid else "free"
        c[side] += 1
        if h is not None:
            k = f"{side}_oldest_h"
            if c[k] is None or h > c[k]:
                c[k] = h

    # The credits/claims classes are decided by the ledger + proof feed + watchlist. If any
    # of those reads failed this tick (the sentinel's CLASSIFICATION_LANES are in `unmeasured`),
    # the classifier is running on EMPTY facts: an already-asked user reads as `untouched`,
    # which is not backlog growth but a blind read (QA @ac05f37). Those classes are unmeasured.
    # The gate is per family: a failed proof feed blinds only the claim lanes, so the credit
    # classes stay measured.
    credit_blind = bool(unmeasured & (CLASSIFICATION_LANES - PROOF_FEED_LANES))
    claim_blind = bool(unmeasured & CLASSIFICATION_LANES)
    if credit_blind:
        for key in ("credits_waiting_us", "credits_owing_proof"):
            out[key]["measured"] = False
    else:
        for uid, item in credits.items():
            b = classify_c(uid, item)
            if b == "untouched":
                add("credits_waiting_us", item["paid"], item["oldest"])
            elif b == "not_told":
                add("credits_owing_proof", item["paid"], item["oldest"])
    if claim_blind:
        out["claims_pending"]["measured"] = False
    else:
        for uid, item in claims.items():
            if classify_k(uid, item) == "untouched":
                add("claims_pending", item["paid"], item["oldest"])
    if clickup and "merges_waiting" not in unmeasured:
        out["merges_pending"]["free"] = clickup.get("untouched") or 0
        out["merges_pending"]["paid_known"] = False
    else:
        out["merges_pending"]["paid_known"] = None          # unmeasured, not zero
        out["merges_pending"]["measured"] = False
    out["intercom_inbound"]["paid_known"] = None
    if "intercom_customer_last" in unmeasured:
        # a truncated or failed Intercom scan: the never_answered map is partial, so it is
        # neither a count nor a baseline
        out["intercom_inbound"]["measured"] = False
    else:
        out["intercom_inbound"]["free"] = len(intercom_never or {})
        if intercom_never:
            hrs = [age_h(t, now) for t in intercom_never.values()]
            out["intercom_inbound"]["free_oldest_h"] = max(hrs) if hrs else None
    return out


def comms_signature(comms: dict, prev_sig: dict | None = None) -> dict:
    """What a comms page is deduped on: the size of each class plus whether a paid user has
    crossed 48h untold. Not the ages themselves — those move every tick. An UNMEASURED class
    keeps the previous tick's signature (or none): a failed read must not persist a zero
    baseline that the recovered source then pages against as growth (QA @059da4d)."""
    sig = {}
    for key, c in comms.items():
        if not c.get("measured", True):
            if prev_sig and key in prev_sig:
                sig[key] = dict(prev_sig[key])
            continue
        sig[key] = {"count": c["paid"] + c["free"],
                    "paid_48h": bool(c["paid_oldest_h"] and c["paid_oldest_h"] > 48)}
    return sig


def comms_pages(comms: dict, prev_sig: dict | None) -> list[str]:
    """Page only when a class GREW, or when a paid user is untold past 48h (once, not every
    tick). A shrinking class is the system working: silence. The FIRST reading of a new
    class baseline pages nothing — "grew from 0" is an artefact of there being no previous
    number, not news."""
    if prev_sig is None:
        return []
    msgs = []
    for key, c in comms.items():
        if not c.get("measured", True):
            continue                                   # unmeasured never pages
        now_sig = {"count": c["paid"] + c["free"],
                   "paid_48h": bool(c["paid_oldest_h"] and c["paid_oldest_h"] > 48)}
        if key not in prev_sig:
            # No MEASURED prior signature for this class (the previous ticks could not read its
            # source, so comms_signature persisted nothing for it): this reading is the class's
            # first baseline, exactly like a brand-new class — "grew from nothing" would page
            # unchanged backlog as growth the moment the source recovers (QA @ac05f37).
            continue
        was = prev_sig[key] or {}
        if now_sig["count"] > (was.get("count") or 0):
            msgs.append(f"COMMS COVERAGE: {dict((k, l) for k, l, _, _ in comms_classes())[key]} "
                        f"grew to {now_sig['count']} people "
                        f"(paid {c['paid']}, free {c['free']}), owner {c['owner']}")
        elif now_sig["paid_48h"] and not was.get("paid_48h"):
            oldest = c["paid_oldest_h"] or 0
            msgs.append(f"COMMS COVERAGE: a paid user has been untold for "
                        f"{age_words(oldest)} on {dict((k, l) for k, l, _, _ in comms_classes())[key]}, "
                        f"owner {c['owner']}")
    return msgs


def comms_render(comms: dict) -> list[str]:
    L = ["*COMMS COVERAGE (people still owed a message)*"]
    for key, label, job, paid_aware in comms_classes():
        c = comms[key]
        total = c["paid"] + c["free"]
        if not c.get("measured", True):
            L.append(f"- {label}: UNMEASURED (source read incomplete this tick), owner {job}")
            continue
        if c["paid_known"] is None:
            who = f"{total:,} (paid not measured on this source)"
        elif paid_aware:
            who = f"{total:,} (paid {c['paid']:,} / free {c['free']:,})"
        else:
            who = f"{total:,}"
        ages = []
        if c["paid_oldest_h"]:
            ages.append(f"paid oldest {age_words(c['paid_oldest_h'])}")
        if c["free_oldest_h"]:
            ages.append(f"free oldest {age_words(c['free_oldest_h'])}")
        L.append(f"{label} · {who}" + (f" · {', '.join(ages)}" if ages else "") + f" · {job}")
    L.append("_Never told = no message has ever gone to them. Paid counts are per user; a "
             "source that cannot tell us the plan says so instead of showing 0._")
    return L



# ── the three-bucket headline (Fable, via firstmate 014) ──────────────────────
# The captain's complaint about the old headline was the raw unverified count: a status name,
# not a decision. These three buckets are decision-shaped — who owes the next move — and they
# add the class nothing was watching: rows a ruling already decided but nobody executed.
AWAITING_US = ("untouched", "not_told", "docs_in", "human")
AWAITING_USER = ("told",)
# What a ledger ruling's successful write looks like in core.
RULING_TERMINAL = {"approve": "approved", "support": "user_verification_needed"}


def decided_not_closed(days: int = 7) -> dict:
    """Rows a ruling DECIDED but whose write never landed (Fable: decided-not-closed).

    Read from the ledger alone, so it runs on node-8 with no Mac and no tray files: for every
    apply-mode approve/support decision in the window, the latest recorded outcome decides
    whether it executed. A missing outcome is the loudest case — the write was never attempted
    or never returned — and is counted, never assumed done."""
    if OFFLINE:
        return {"rows": None, "users_lb": None, "unmeasured": True, "by_outcome": {},
                "by_ruling": {}}
    try:
        db = sqlite3.connect(f"file:{LEDGER}?mode=ro", uri=True)
        try:
            rows = db.execute(
                "WITH latest AS (SELECT request_id, max(id) AS mid FROM decision_outcomes "
                "GROUP BY request_id) "
                "SELECT d.decision, coalesce(o.outcome, ''), count(*), count(distinct d.user_id) "
                "FROM decisions d LEFT JOIN latest l ON l.request_id = d.request_id "
                "LEFT JOIN decision_outcomes o ON o.id = l.mid "
                "WHERE d.mode='apply' AND d.decision IN ('approve','support') "
                "AND d.decided_at > datetime('now', ?) GROUP BY 1, 2",
                (f"-{days} day",)).fetchall()
            # the exact distinct-user count for the non-terminal rows (the per-outcome groups
            # above overlap, so a max() over them would be a lower bound)
            exact_users = db.execute(
                "WITH latest AS (SELECT request_id, max(id) AS mid FROM decision_outcomes "
                "GROUP BY request_id) "
                "SELECT count(distinct d.user_id) FROM decisions d "
                "LEFT JOIN latest l ON l.request_id = d.request_id "
                "LEFT JOIN decision_outcomes o ON o.id = l.mid "
                "WHERE d.mode='apply' AND d.decision IN ('approve','support') "
                "AND d.decided_at > datetime('now', ?) "
                # the SAME predicate the row loop uses: a row is unresolved when its outcome is
                # not the terminal one FOR ITS OWN RULING. A global terminal list made a
                # support-with-approved row count in rows but not in users (QA @987d77e).
                "AND coalesce(o.outcome,'') <> CASE d.decision "
                "WHEN 'approve' THEN 'approved' ELSE 'user_verification_needed' END",
                (f"-{days} day",)).fetchone()
        finally:
            db.close()
    except sqlite3.Error as e:
        # a ledger we cannot read is UNKNOWN, never "nothing decided" (and never a crash on an
        # unattended tick)
        return {"rows": None, "users_lb": None, "unmeasured": True, "error": str(e),
                "by_outcome": {}, "by_ruling": {}}
    out = {"rows": 0, "users_lb": 0, "by_ruling": {}, "by_outcome": {}}
    seen_users = {}
    for decision, outcome, n, users in rows:
        if outcome == RULING_TERMINAL.get(decision):
            continue                     # executed: not this class
        out["rows"] += n
        out["by_ruling"][decision] = out["by_ruling"].get(decision, 0) + n
        key = outcome or "no outcome recorded"
        out["by_outcome"][key] = out["by_outcome"].get(key, 0) + n
        seen_users[(decision, key)] = users
    out["users_lb"] = (exact_users[0] if exact_users else 0) or 0
    return out


def headline_build(credits: dict, claims: dict, classify_c, classify_k, dnc: dict) -> dict:
    """The three buckets, counted in users / requests / paid users. Buckets are the DECISION
    classes, so a reader can act on them without knowing a status name."""
    buckets = {k: {"users": 0, "rows": 0, "paid_users": 0}
               for k in ("awaiting_us", "awaiting_user", "decided_not_closed")}
    for pop, classify in ((credits, classify_c), (claims, classify_k)):
        for uid, item in pop.items():
            b = classify(uid, item)
            key = ("awaiting_us" if b in AWAITING_US
                   else "awaiting_user" if b in AWAITING_USER else None)
            if key is None:
                continue                 # watch / muted: a gate holds it, reported in the table
            bucket = buckets[key]
            bucket["users"] += 1
            bucket["rows"] += item["n"]
            if item["paid"]:
                bucket["paid_users"] += 1
    buckets["decided_not_closed"] = {"users": dnc.get("users_lb"),
                                     "rows": dnc.get("rows"), "paid_users": None}
    return buckets


def headline_render(h: dict, dnc: dict) -> list[str]:
    def line(key, label, note):
        b = h[key]
        if b["users"] is None or b["rows"] is None:
            return f"*{label}* · unmeasured this tick{note}"
        paid = "paid not measured" if b["paid_users"] is None else f"{b['paid_users']:,} paid"
        return (f"*{label}* · {b['users']:,} users / {b['rows']:,} requests ({paid}){note}")

    why = ""
    if dnc.get("by_outcome"):
        why = "  (" + ", ".join(f"{k} {v:,}" for k, v in
                                sorted(dnc["by_outcome"].items(), key=lambda x: -x[1])[:3]) + ")"
    return [
        "*HEADLINE*",
        line("awaiting_us", "Awaiting US", "  — we owe the next move"),
        line("awaiting_user", "Awaiting the USER", "  — we asked, the ball is theirs"),
        line("decided_not_closed", "DECIDED-NOT-CLOSED",
             f"  — ruled, the write never landed{why}"),
    ]


# ── rendering ──────────────────────────────────────────────────────────────────

def age_words(hours: float) -> str:
    if hours >= 48:
        return f"{round(hours / 24):,}d"
    if hours >= 1:
        return f"{round(hours)}h"
    return "new"


UP, DOWN = "▲", "▼"
# Captain 2026-10-26 23:30Z. Printed at the top of EVERY report until firstmate says it is
# lifted: the reader must know these three things are deliberately not moving, or a flat
# "never touched" number looks like the machine is failing rather than obeying.
PAUSED_LINE = ("_Paused by captain order 23:30Z: approvals of validator-declined rows, "
               "name-match, claim approvals other than one-time code._")


def arrow(cur: int, prev) -> str:
    """Change since the previous report, or nothing when there is no previous one."""
    if prev is None:
        return ""
    d = cur - prev
    if d == 0:
        return " ="
    return " " + (UP if d > 0 else DOWN) + f"{abs(d):,}"


def render(m: dict, prev: dict | None) -> str:
    def pv(section, key):
        if not prev:
            return None
        return ((prev.get(section) or {}).get("buckets") or {}).get(key, {}).get("users")

    def pv_flow(section, key):
        if not prev:
            return None
        return ((prev.get(section) or {}).get("flow") or {}).get(key, {}).get("users")

    def pv_open(section):
        if not prev:
            return None
        return (prev.get(section) or {}).get("open_users")

    L = [f"Credits, profile claims and profile merges, open right now ({m['at']})",
         PAUSED_LINE, ""]
    if m.get("headline"):
        L.extend(headline_render(m["headline"], m.get("decided_not_closed") or {}))
        L.append("")
    for section, title, unit in (("credits", "CREDITS (credit requests)", "requests"),
                                 ("claims", "PROFILE CLAIMS", "claims")):
        s = m[section]
        L.append(f"*{title}*")
        L.append(f"Approved in the last 24h · {s['flow']['approved']['users']:,} users / "
                 f"{s['flow']['approved']['rows']:,} {unit} "
                 f"({s['flow']['approved']['paid']:,} paid){arrow(s['flow']['approved']['users'], pv_flow(section, 'approved'))}")
        L.append(f"Declined in the last 24h · {s['flow']['declined']['users']:,} users / "
                 f"{s['flow']['declined']['rows']:,} {unit} "
                 f"({s['flow']['declined']['paid']:,} paid){arrow(s['flow']['declined']['users'], pv_flow(section, 'declined'))}")
        for key, label in BUCKETS:
            b = s["buckets"][key]
            age = f"  oldest {age_words(b['oldest_h'])}" if b["oldest_h"] else ""
            L.append(f"{label} · {b['users']:,} users / {b['rows']:,} {unit} "
                     f"({b['paid_users']:,} paid users, {b['paid_rows']:,} paid {unit})"
                     f"{age}{arrow(b['users'], pv(section, key))}")
        L.append(f"*Total open · {s['open_users']:,} users / {s['open_rows']:,} {unit} "
                 f"({s['open_paid_users']:,} paid users, {s['open_paid']:,} paid {unit})*"
                 f"{arrow(s['open_users'], pv_open(section))}")
        L.append("")
    mg = m.get("merges")
    if mg:
        cu = mg.get("clickup") or {}
        L.append("*PROFILE MERGES*")
        if cu:
            L.append(f"Nobody has touched them yet · {cu['untouched']:,} of {cu['open']:,} open "
                     f"merge requests")
            L.append(f"Waiting on the user (must claim the duplicate first) · "
                     f"{cu['waiting_user']:,} requests")
            L.append(f"Held for a person (contested / conflict / intake stale) · "
                     f"{cu['held']:,} requests")
        else:
            L.append("Nobody has touched them yet · unmeasured — the ClickUp user-requests "
                     "read failed this tick")
        age = f"  oldest {age_words(mg['stuck_oldest_h'])}" if mg["stuck_oldest_h"] else ""
        L.append(f"Executing or stuck in the merge engine · {mg['stuck_rows']:,} merges "
                 f"(callback_received {mg['callback']}, unverified {mg['unverified']}){age}")
        done = cu.get("done24") if cu else None
        L.append(f"Done in the last 24h · {done if done is not None else 'unmeasured'} marked "
                 f"merged, {mg['done24_rows']:,} verified in the merge engine")
        L.append("Declined or closed in the last 24h · unmeasured — the resolved-ticket read "
                 "is not wired yet")
        L.append("")

    lg = legacy_line(m, prev)
    if lg:
        L.append("")
        L.append(lg)
    if m.get("sentinel_lock_busy"):
        L.append("_The backlog sentinel could not take its state lock this tick, so its counters "
                 "are missing here (not zero). The tables above are unaffected._")
    if m.get("comms"):
        # render() is only reached by a full tick (a light tick never renders a report)
        L.append("")
        L.extend(comms_render(m["comms"]))
    held = (m.get("held") or {})
    if held:
        L.append("_Held by captain order (visible, not moving):_")
        for key, h in held.items():
            L.append(f"  · {h['label']} · {h['count']:,} items, oldest {age_words(h['oldest_h'])}"
                     f" · owner {h['owner']} · {h['reason']} · unblock: {h['unblock']}")
    blind = [LABELS.get(k, k) for k, v in (m.get("sentinel") or {}).items() if v.get("unmeasured")]
    if blind:
        L.append(f"_No live source on this host for: {', '.join(blind)} — that lane is "
                 f"unmeasured, not clear._")
    L.append("_The groups don't overlap: anything a person or the fraud list already owns is "
             "counted there, never as waiting on the user. \"Not touched by us at all\" means "
             "we have never asked, messaged or decided anything for that user. The arrows are "
             "the change since the last report (none yet on the first one)._")
    return "\n".join(L)



def sentinel_evaluate(found: dict, now: datetime) -> dict:
    """Count each sentinel bucket's legacy backlog (entered before the baseline) and its
    NEW breaches (entered after it, already older than the SLA)."""
    base = parse_ts(BASELINE)
    out = {}
    for key, label, owner, sla in SENTINEL_BUCKETS:
        legacy, breach, undateable = [], [], 0
        for iid, ts in found["items"].get(key) or []:
            d = parse_ts(ts)
            if d is None:
                undateable += 1            # neither "new" nor "legacy": do not guess
                continue
            age = (now - d).total_seconds() / 3600
            if age <= sla:
                continue
            # LEGACY means it was ALREADY past its SLA at the baseline — not merely entered
            # before it. A decider hold entered at 20:45Z with a 1h SLA was healthy at the
            # 21:00Z baseline and only became overdue at 21:45Z: that is a NEW breach the
            # captain must hear about, so it is paged, not filed as old backlog.
            overdue_at_baseline = bool(base) and (d + timedelta(hours=sla)) <= base
            (legacy if overdue_at_baseline else breach).append((iid, round(age, 1)))
        out[key] = {"label": label, "owner": owner, "sla_h": sla,
                    "legacy": len(legacy), "breaches": breach,
                    "unmeasured": key in found["unmeasured"],
                    "undateable": undateable}
    return out


def sentinel_page(ev: dict, prev: dict | None, now: datetime, dry: bool,
                  held_facts_now: dict | None = None,
                  held_lanes_now: dict | None = None) -> tuple[list, dict, list]:
    """One DM per bucket that has an item newly past its SLA (never a DM per item: a bad
    afternoon in one lane must not bury Slack).

    Returns (messages, state, page_map). `page_map` pairs each message with the item ids it
    covers, so the caller can record ONLY the pages Slack actually accepted: the delivery
    ledger is `state["paged"]`, kept apart from `state["breaches"]` (what is currently
    overdue, for firstmate). Marking an undelivered page as told would make the next tick
    silent about a queue that is still rotting."""
    told: dict[str, set] = {}
    for key, ids in ((prev or {}).get("paged") or {}).items():
        told[key] = set(ids or [])
    if prev is not None and "paged" not in prev:
        # an older state file recorded deliveries in `breaches` itself; read it once so a
        # live deploy does not re-page everything that was already told.
        for b in prev.get("breaches") or []:
            told.setdefault(b.get("bucket"), set()).update(b.get("items") or [])
    # Prune: an id stays in the ledger only while it is STILL a breach. Otherwise a user who
    # was paged once, cleared, then came back with new overdue work would never page again —
    # the dedupe key is the id, and the old id is still there (QA @0b3507c).
    live = {k: {i for i, _ in (ev[k]["breaches"] or [])} for k, _, _, _ in SENTINEL_BUCKETS}
    # lanes that are still HELD (their blocker has not shipped). A lane that still has overdue
    # items but is no longer held must NOT keep its old captain-held entry: the page says
    # actionable and the report would keep calling it paused (QA @d5c1d18).
    still_held: set[str] = set()
    blind = {k for k in ev if ev[k]["unmeasured"]}
    told = {k: (v if k in blind else v & live.get(k, set())) for k, v in told.items()}
    now_z = now.strftime("%Y-%m-%dT%H:%M:%SZ")
    breaches, messages, page_map, held_pending = [], [], [], {}
    for key, _, _, _ in SENTINEL_BUCKETS:
        b = ev[key]
        if not b["breaches"]:
            continue
        items = [{"id": iid, "age_h": age} for iid, age in sorted(b["breaches"], key=lambda x: -x[1])]
        new = [i for i in items if i["id"] not in told.get(key, set())]
        breaches.append({"bucket": key, "label": b["label"], "owner": b["owner"],
                         "count": len(items),
                         "oldest_h": max((i["age_h"] for i in items), default=0),
                         "items": [i["id"] for i in items]})
        blind = bool(ev[key].get("unmeasured"))
        spec = held_lane(key, held_facts_now, held_lanes_now)
        if spec is not None:
            still_held.add(key)
            reason, unblock = spec["reason"], spec["unblock"]
            owner = spec.get("owner") or b["owner"]
            oldest_h = round(max((i["age_h"] for i in items), default=0))
            sig = dict(held_signature(items), reason=reason)
            last = ((prev or {}).get("held") or {}).get(key) or {}
            # Page only when the SET of held items or the blocker sentence changes. A state file
            # from before this fix carries count+oldest_h and no items_sha: compare on count
            # alone for it, so the deploy itself does not re-page every held lane.
            changed = (last.get("count") != sig["count"]
                       or ("items_sha" in last and last.get("items_sha") != sig["items_sha"])
                       or ("reason" in last and last.get("reason") != reason))
            if changed and not blind:
                eta = f" · ETA {spec['eta']}" if spec.get("eta") else ""
                messages.append(
                    f"BACKLOG HELD BY CAPTAIN ORDER: {b['label']} {sig['count']} items, "
                    f"oldest {age_words(oldest_h)}, owner {owner} — {reason}; "
                    f"unblock: {unblock}{eta}")
                # A held page covers NO item ids, but it still occupies a slot: leaving it
                # out of page_map shifted every later page's ids onto the wrong message, so
                # a failed post could be recorded as delivered (QA @99d61a6).
                page_map.append((key, None))
            # NOT recorded here: a rejected held page must retry on the next tick, exactly
            # like an actionable one. It is moved into state["held"] only after delivery.
            held_pending[key] = dict(sig, oldest_h=oldest_h, unblock=unblock, owner=owner,
                                     eta=spec.get("eta"), label=b["label"])
            continue
        # A lane we could not measure carries its previous set, and an item in it may have
        # changed classification while the feed was down: report it, never page from it. When
        # the source comes back, anything still overdue pages as usual (QA @870cebb).
        if new and not blind:
            oldest = max(i["age_h"] for i in new)
            messages.append(f"BACKLOG FORMING: {b['label']} {len(items)} items, "
                            f"oldest {age_words(oldest)}, owner {b['owner']}")
            page_map.append((key, [i["id"] for i in new]))
    state = {"ts": now_z, "baseline": BASELINE, "breaches": breaches,
             "paged": {k: sorted(v) for k, v in told.items() if v},
             "legacy": {k: ev[k]["legacy"] for k, _, _, _ in SENTINEL_BUCKETS},
             "unmeasured": sorted(k for k in ev if ev[k]["unmeasured"]),
             # Only lanes that are STILL breached and STILL held survive into the state. A lane
             # that drained (or whose blocker shipped, so held_lane() returns None) must
             # disappear, not linger in the report as a held row with a stale sentence.
             "held": {k: v for k, v in (((prev or {}).get("held") or {})).items()
                      if k in still_held},
             "_held_pending": held_pending,
             "undateable": {k: ev[k]["undateable"] for k in ev if ev[k]["undateable"]}}
    return messages, state, page_map


def record_paged(state: dict, page_map: list, delivered: list) -> dict:
    """Add to the delivery ledger only the pages Slack confirmed. A held page carries no ids
    (`None`): its SIGNATURE moves into `held` only once delivered, so a rejected held page is
    retried on the next tick instead of being swallowed (QA @f64ebbb)."""
    paged = {k: set(v) for k, v in (state.get("paged") or {}).items()}
    held = dict(state.get("held") or {})
    pending = state.pop("_held_pending", None) or {}
    for (key, ids), ok in zip(page_map, delivered):
        if not ok:
            continue
        if ids:
            paged.setdefault(key, set()).update(ids)
        elif key in pending:
            held[key] = pending[key]
    state["held"] = held
    state["paged"] = {k: sorted(v) for k, v in paged.items() if v}
    return state


def carry_caches(state: dict, found: dict, prev: dict | None) -> dict:
    """Folder the carried Intercom / merges sets into the sentinel state. A light tick did
    not refresh them, so it must forward the previous copy — dropping it would wipe the
    Intercom set and make the next full tick re-page breaches we already reported."""
    state["items"] = {k: dict(v) for k, v in (found["items"] or {}).items()
                      if not k.startswith("_") and v}
    for key, name in (("_intercom", "intercom"), ("_merges", "merges")):
        fresh = found["items"].get(key)
        if fresh:
            state[name] = fresh
        elif (prev or {}).get(name):
            state[name] = prev[name]
    return state


SENTINEL_LOCK = os.environ.get("VQR_SENTINEL_LOCK", "/var/lib/hydra/backlog-sentinel/.lock")
SENTINEL_LOCK_WAIT = float(os.environ.get("VQR_SENTINEL_LOCK_WAIT", "20"))
# Intercom's updated_at has SECOND resolution: a conversation updated in the same second as
# the last snapshot carries the same epoch second, so a strict `>` excludes it for ever and it
# never enters the owed-reply lane. The delta therefore re-reads a small window behind the
# watermark (the held set is keyed by conversation id, so the overlap is idempotent).
INTERCOM_DELTA_OVERLAP_S = int(os.environ.get("VQR_INTERCOM_DELTA_OVERLAP_S", "5"))
# (key the scan returns, key the state stores) — written out, never derived by string surgery.
INTERCOM_CURSORS = (("cursor", "delta_cursor"), ("closed_cursor", "closed_cursor"))
GRID_OUT = os.environ.get("VQR_GRID_OUT", "")
# 1 in tests / CI: the network probes (Trino merges, Intercom) are skipped and the buckets
# they feed read unmeasured, so no test ever reaches a live integration.
# Tests / CI set this: EVERY external read is bypassed (Trino, ClickUp, Intercom, the proof
# feed, the watchlist, the ledger), so an offline subprocess test can never hang on a live
# service or depend on a credential. Only the control flow under test is exercised.
OFFLINE = os.environ.get("VQR_OFFLINE") == "1"


class sentinel_lock:
    """Serializes the read -> evaluate -> page -> write transaction on the shared sentinel
    state. The 30-minute report and the 5-minute light tick use DIFFERENT flock files in
    cron (so a light tick can never be starved by a 33s report), which means the cron locks
    cannot serialize the thing they share. Without this, two coincident ticks can both see
    the same new breach and page it twice, and either can overwrite the other's state."""

    def __init__(self, path: str | None = None, timeout: float = 120.0):
        # resolved at CALL time, not at import: a default of SENTINEL_LOCK froze the path
        # into the signature, so overriding the setting later had no effect.
        self.path, self.timeout, self.fh = path or SENTINEL_LOCK, timeout, None

    def __enter__(self):
        os.makedirs(os.path.dirname(self.path), exist_ok=True)
        self.fh = open(self.path, "a+")
        deadline = time.time() + self.timeout
        while True:
            try:
                fcntl.flock(self.fh, fcntl.LOCK_EX | fcntl.LOCK_NB)
                return self
            except OSError:
                if time.time() >= deadline:
                    raise TimeoutError(f"another tick held {self.path} for {self.timeout}s")
                time.sleep(0.2)

    def __exit__(self, *exc):
        if self.fh:
            fcntl.flock(self.fh, fcntl.LOCK_UN)
            self.fh.close()
        return False


def sentinel_state_path() -> str:
    return SENTINEL_STATE


def write_sentinel_state(state: dict) -> None:
    os.makedirs(os.path.dirname(SENTINEL_STATE), exist_ok=True)
    tmp = f"{SENTINEL_STATE}.tmp.{os.getpid()}"
    with open(tmp, "w") as f:
        json.dump(state, f, indent=1)
    os.replace(tmp, SENTINEL_STATE)


def read_sentinel_state() -> dict | None:
    try:
        with open(SENTINEL_STATE) as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return None


def legacy_line(m: dict, prev: dict | None) -> str:
    """The one line in the 30-minute report the captain uses to watch the OLD backlog
    drain. It must fall every report."""
    lg = m.get("legacy") or {}
    if not lg:
        return ""
    total = lg.get("total", 0)
    prev_total = ((prev or {}).get("legacy") or {}).get("total")
    flat = (prev or {}).get("legacy_flat", 0) or 0
    worst = sorted(((v, k) for k, v in lg.items() if k != "total" and v), reverse=True)[:3]
    parts = ", ".join(f"{LABELS.get(k, k)} {v:,}" for v, k in worst)
    return (f"*Old backlog from before the 21:00Z line · {total:,} items*{arrow(total, prev_total)}"
            + (f"  ({parts})" if parts else "")
            + (f"  — not falling {flat + 1 if total == prev_total else 0} reports in a row"
               if total == prev_total and total > 0 else ""))


LABELS = {k: label.lower() for k, label, _, _ in SENTINEL_BUCKETS}


# Everything the CLASSIFICATION depends on. A credits/claims population without the ledger,
# the proof feed or the watchlist is not "5,781 users nobody touched" — it is unknown: without
# them every row falls through to `untouched` and the watch lane reads empty (QA @f64ebbb).
FATAL_PREFIXES = ("credits", "claims", "credit flow", "claim flow", "ledger", "proof feed",
                  "watchlist")


def incomplete_errors(errors: list[str]) -> list[str]:
    """The errors that mean the TABLES were never measured (as opposed to one subsidiary
    lane). A report with one of these must say so instead of posting a confident zero."""
    return [e for e in errors if e.split(":")[0] in FATAL_PREFIXES]


def stall_pages(m: dict, prev: dict | None) -> list[str]:
    """Page when the OLD backlog does not fall: a rise, or the same number two reports
    running (a backlog that is merely stable is still a backlog)."""
    lg = m.get("legacy") or {}
    if not lg:
        return []                      # sentinel did not run: no trend to judge
    total = lg.get("total", 0)
    prev_total = ((prev or {}).get("legacy") or {}).get("total")
    if prev_total is None:
        return []
    msgs = []
    if total > prev_total:
        msgs.append(f"BACKLOG FORMING: old backlog rose {prev_total:,} -> {total:,} items, "
                    f"owner ops-completeness-fable-o1")
    elif total == prev_total and total > 0 and (m.get("legacy_flat") or 0) >= 2:
        msgs.append(f"BACKLOG STUCK: old backlog has not fallen for "
                    f"{(m.get('legacy_flat') or 0) + 1} reports at {total:,} items, "
                    f"owner ops-completeness-fable-o1")
    return msgs

# ── slack ──────────────────────────────────────────────────────────────────────

def slack_token() -> str:
    for line in open(ENV_FILE, errors="replace"):
        if line.startswith("MUSO_SLACK_BOT_TOKEN_DEVOPS="):
            return line.split("=", 1)[1].strip().strip('"').strip("'")
    raise RuntimeError(f"MUSO_SLACK_BOT_TOKEN_DEVOPS is not in {ENV_FILE}")


def slack_post(token: str, text: str) -> str:
    """chat.postMessage to the captain's DM: conversations.open first (an IM channel id is
    not the user id on every workspace), then post. Returns the message ts."""
    def call(method: str, body: dict) -> dict:
        req = urllib.request.Request(f"https://slack.com/api/{method}",
                                     data=json.dumps(body).encode(),
                                     headers={"Authorization": f"Bearer {token}",
                                              "Content-Type": "application/json; charset=utf-8"})
        d = json.load(urllib.request.urlopen(req, timeout=15))
        if not d.get("ok"):
            raise RuntimeError(f"{method}: {d.get('error')}")
        return d

    channel = call("conversations.open", {"users": CAPTAIN})["channel"]["id"]
    d = call("chat.postMessage", {"channel": channel, "text": text,
                                  "unfurl_links": False, "mrkdwn": True})
    return d["ts"]


# ── main ───────────────────────────────────────────────────────────────────────

def selftest() -> int:
    """Fixture run for the two classifiers: `--selftest`, and the cron bats suite."""
    REQ_OLD = "2026-10-01 00:00:00.000000 UTC"      # an open request from a month ago
    PROOF_NEW = "2026-10-27T10:00:00Z"              # a document that landed yesterday
    # a tagged proof implies a note went out, so 15/16/17 are messaged like 1/2/3.
    facts = {"asked": {1: ""}, "messaged": {1: "", 2: "", 3: "", 15: "", 16: "", 17: ""},
             "latest": {
                 3: {"decision": "support", "reason": "x", "doc_required": 1, "at": ""},
                 # a "proof on file" hold whose document the reader DATED after the request
                 5: {"decision": "hold",
                     "reason": "proof on file: human review (a document is on file)",
                     "doc_required": 0, "at": ""},
                 # the same hold, and the reader read the document but found NO date in it
                 30: {"decision": "hold",
                      "reason": "proof on file: human review (a document is on file)",
                      "doc_required": 0, "at": ""},
                 # the same hold, and the reader has not opened the document yet
                 31: {"decision": "hold",
                      "reason": "proof on file: human review (a document is on file)",
                      "doc_required": 0, "at": ""},
                 # the same hold, one document read with no date and another never opened
                 32: {"decision": "hold",
                      "reason": "proof on file: human review (a document is on file)",
                      "doc_required": 0, "at": ""},
                 # the same hold, but the document on file is not one the reader can ever look at
                 33: {"decision": "hold",
                      "reason": "proof on file: human review (a document is on file)",
                      "doc_required": 0, "at": ""},
                 # a STAGE-2 hold: the user was ALREADY asked through a campaign, so this is not
                 # the reason-5 lane and must not be re-read as "not told" (or as a look we owe)
                 34: {"decision": "hold",
                      "reason": "proof on file: stage 2 judged the document",
                      "doc_required": 0, "at": ""},
                 6: {"decision": "hold", "reason": "emailed support@ in the last 90 days",
                     "doc_required": 0, "at": ""}},
             "decided": {3, 5, 6, 30, 31, 32, 33, 34}, "replied": set(),
             # 15/16 have a DATED proof reply; 17's is dated but OLDER than its request.
             "proof_waiting": {15: PROOF_NEW, 16: PROOF_NEW, 17: "2026-09-01T10:00:00Z",
                               19: "2026-10-27T10:00:00Z"},
             # 19 has BOTH an old unreviewed tag (Jan) and a fresh one: the fresh one must win
             "proof_tags": {19: ["2026-01-02T10:00:00Z", "2026-10-27T10:00:00Z"]},
             "muted": {4: "2030-01-01T00:00:00Z"}, "flagged": {9: "2026-01-01"},
             "claim_notes": {}, "claim_proofs": {}, "claim_replied": set(), "claim_muted": {},
             "claim_flagged": {}, "first_proof_hold": {}, "first_deadend": {},
             "support_contacts": set(),
             # what the returned-document reader read out of each document on file: 5's document
             # is dated after its request, 20's was read and carries no date, 21's was never read,
             # 22 has one read document with no date beside one nobody opened, and 23 has no
             # reader-eligible filing at all (the reader will never look, so it is not our look).
             "doc_dates": {5: {"filed": True, "read": True, "date": date(2026, 10, 20)},
                           30: {"filed": True, "read": True, "date": None},
                           31: {"filed": True, "read": False, "date": None},
                           32: {"filed": True, "read": False, "date": None},
                           33: {"filed": False, "read": False, "date": None}}}

    def cred(**over) -> dict:
        base = {"paid": False, "n": 1, "oldest": REQ_OLD, "core_ask": False,
                "reply_at": "", "core_reply": False, "needs_docs": True, "paid_n": 0}
        base.update(over)
        return base

    cases = [
        ("1 an ask went out", 1, "told", cred()),
        # a status note is a message, so the user is NOT untouched: it is a row that needs
        # documents and was never asked for them.
        ("2 only ever got a status note", 2, "not_told", cred()),
        # our own support ASK whose core write never landed: waiting on us to tell them,
        # never with a person.
        ("3 our own support ask, never told", 3, "not_told", cred()),
        ("3b our own support ask, told (core notice)", 20, "told", cred(core_ask=True)),
        ("4 muted hold", 4, "muted", cred()),
        ("5 a document on file the reader DATED after the request is docs_in", 5, "docs_in",
         cred()),
        ("5b a document dated AFTER the request is docs_in", 15, "docs_in", cred()),
        ("5c a dated document OLDER than the request is not proof", 17, "not_told", cred()),
        ("5d a core response newer than its request is docs_in", 18, "docs_in",
         cred(reply_at="2026-10-26T00:00:00Z", core_reply=True)),
        # reason 5's defect: an undated document never parks on a person. Read and undated is an
        # ASK for a dated copy; not read yet is a look WE owe.
        ("5e a document the reader read with NO date in it is an ask for a dated copy", 30,
         "not_told", cred()),
        ("5f a document the reader has not opened is ours to look at", 31, "docs_in", cred()),
        ("5g a mixed read/unopened document set is ours to look at", 32, "docs_in", cred()),
        # no reader-eligible filing: the reader will never look, so there is no look to owe and
        # the row belongs in the ask lane (never asked -> not_told, asked -> told).
        ("5h a document the reader can never look at is the ask lane", 33, "not_told", cred()),
        # a STAGE-2 hold is a different hold: that user was already asked, so it is `told` and
        # never re-read as "needs documents - user NOT told" nor as a look we owe.
        ("5i a stage-2 hold is not the reason-5 lane", 34, "told",
         cred(core_ask=True)),
        # A legacy hold row naming the support@ contact is not a person any more: the row was
        # decided (so not untouched) and nobody ever asked (so not told).
        ("6 emailed support@", 6, "not_told", cred()),
        ("6b support@ BUT a newer dated document wins", 16, "docs_in", cred()),
        ("6c an OLD tag beside a NEW one still qualifies", 19, "docs_in", cred()),
        ("7 untouched", 7, "untouched", cred()),
        ("8 watchlist", 8, "watch", cred()),
        ("9 flagged refusal hold", 9, "human", cred()),
    ]
    bad = 0
    for name, user, want, c in cases:
        got = classify_credit(user, facts, c, frozenset({8}))
        if got != want:
            print(f"FAIL {name}: want {want} got {got}")
            bad += 1
    cl = {"paid": False, "n": 1, "oldest": "", "profiles": ["p1"], "claims": ["11"]}
    if classify_claim(10, dict(facts, claim_notes={"claim-11": {"at": ""}}), cl,
                      frozenset(), frozenset()) != "told":
        print("FAIL claim note recognised as told")
        bad += 1
    if classify_claim(11, facts, cl, frozenset(), frozenset({"p1"})) != "watch":
        print("FAIL claim profile watchlist")
        bad += 1
    print("selftest ok" if not bad else f"selftest: {bad} failure(s)")
    return 1 if bad else 0


USAGE = __doc__ or "verification-queue-report.py [--post|--dry-run|--json|--selftest]"


def main(argv: list[str]) -> int:
    args = set(argv[1:])
    if args & {"-h", "--help"}:
        print(USAGE)
        return 0
    if "--selftest" in args:
        return selftest()
    light = "--light" in args          # 5-minute tick: skips the network-only sources
    # The REPORT kill switch silences the report only. A `--light --post` tick exists to run
    # the sentinel, which has its own switch (SENTINEL_KILL) — one switch must not turn off
    # the other (QA @99d61a6).
    if os.path.exists(KILL) and "--post" in args and not light:
        print("NO_REPLY")
        return 0
    dry = "--dry-run" in args
    started = time.time()
    now = datetime.now(timezone.utc)
    errors = []

    credits = claim = {}
    flows_c = flows_k = {}
    # The light tick carries the credits/claims sets from the last full tick, so it must
    # not pay for those two Trino queries (~25s of the 33s run) — that is the difference
    # between a 5-minute tick costing 4s and one costing 32s, twelve times an hour.
    for name, fn in (() if light else (("credits", credit_rows), ("claims", claim_rows))):
        try:
            if name == "credits":
                credits = fn()
            else:
                claim = fn()
        except Exception as e:                                 # noqa: BLE001
            errors.append(f"{name}: {type(e).__name__}: {e}")
    if not light:
        try:
            flows_c = flow_24h("credit_requests", "workspaceid", "approved", "rejected")
        except Exception as e:                                 # noqa: BLE001
            errors.append(f"credit flow: {e}")
        try:
            flows_k = flow_24h("claiming", "teamid", "processed", "rejected")
        except Exception as e:                                 # noqa: BLE001
            errors.append(f"claim flow: {e}")

    # Two numbers the standing page prints and this report does not. A failed read leaves the key
    # out and its error in: the page then says unmeasured. Neither stops the tables.
    gap = intake = None
    medians: dict[str, float] = {}
    if not light and not OFFLINE:
        for name in ("credits", "claims"):
            try:
                medians[name] = request_median_h(name, now)
            except Exception as e:                             # noqa: BLE001
                errors.append(f"{name} median: {type(e).__name__}: {e}")
        try:
            gap = ask_gap(pending_request_ids())
        except Exception as e:                                 # noqa: BLE001
            errors.append(f"ours: {type(e).__name__}: {e}")
        try:
            intake = intake_1h()
        except Exception as e:                                 # noqa: BLE001
            errors.append(f"intake: {type(e).__name__}: {e}")

    local_failed: set[str] = set()
    if light:
        facts = _EMPTY_FACTS()
    else:
        try:
            facts = ledger_facts()
        except Exception as e:                                 # noqa: BLE001
            facts = _EMPTY_FACTS()
            local_failed |= CLASSIFICATION_LANES | {"fable_decider"}
            errors.append(f"ledger: {type(e).__name__}: {e}")
    proof_meta = {}
    if not light:
        try:
            support_contacts, proof_meta = proof_feed()
            facts["support_contacts"] = support_contacts
        except Exception as e:                                 # noqa: BLE001
            errors.append(f"proof feed: {type(e).__name__}: {e}")
            # the 90-day support@ contact list comes from that feed, and only the claim lanes
            # read it: without it a claim's human / docs_in split is unknown, so those lanes
            # are unmeasured, never reclassified. The credit lanes read no contact list.
            local_failed |= PROOF_FEED_LANES
    # The document's own date, for the users whose latest verdict is a "document on file" hold.
    # Read only for that population: it is the one lane whose bucket depends on it, and the read
    # is two indexed statements per chunk. An unreadable store leaves those rows with a person
    # (never a guess) and marks the lanes unmeasured, because docs_in would be under-counted.
    if not light:
        try:
            holds = undated_hold_users(facts)
            facts["doc_dates"] = doc_dates(holds) if holds else {}
            if holds and facts["doc_dates"] is None:
                local_failed |= CLASSIFICATION_LANES
                errors.append("doc dates: the returned-document reader's store could not be read")
        except Exception as e:                                 # noqa: BLE001
            facts["doc_dates"] = None
            local_failed |= CLASSIFICATION_LANES
            errors.append(f"doc dates: {type(e).__name__}: {e}")
    if light:
        wz, wz_profiles = frozenset(), frozenset()
    else:
        try:
            wz, wz_profiles = watchlist_ids()
        except Exception as e:                                 # noqa: BLE001
            wz, wz_profiles = frozenset(), frozenset()
            # a missing watchlist makes every credit/claim lane unmeasured, never empty
            local_failed |= CLASSIFICATION_LANES
            errors.append(f"watchlist: {type(e).__name__}: {e}")

    def summarize_merges(src: dict, done24: dict, now: datetime, failed: bool,
                         cu: dict) -> dict:
        """The captain's five merge rows from core's ledger. `stuck` is callback_received +
        unverified with the request's age; `done24` is verified in the last 24h. The two
        ticket-side rows (nobody has touched / waiting on the user) come from the ClickUp
        user-requests queue and are reported UNMEASURED here until that read is wired."""
        stuck_rows = sum(v["rows"] for k, v in src.items() if k in ("callback_received", "unverified"))
        stuck_users = sum(v["users"] for k, v in src.items() if k in ("callback_received", "unverified"))
        oldest = [age_h(v["oldest"], now) for k, v in src.items()
                  if k in ("callback_received", "unverified") and v["oldest"]]
        return {"stuck_rows": stuck_rows, "stuck_users": stuck_users,
                "stuck_oldest_h": max(oldest) if oldest else None,
                "callback": src.get("callback_received", {}).get("rows", 0),
                "unverified": src.get("unverified", {}).get("rows", 0),
                "done24_rows": done24["rows"], "done24_users": done24["users"],
                "unmeasured": failed, "clickup": cu}

    def summarize(pop: dict, flows: dict, classify, name: str) -> dict:
        buckets = {k: {"users": 0, "rows": 0, "paid_users": 0, "paid_rows": 0,
                       "oldest_h": None} for k, _ in BUCKETS}
        for user, item in pop.items():
            item = dict(item, oldest_h=age_h(item["oldest"], now))
            key = classify(user, item)
            b = buckets[key]
            b["users"] += 1
            b["rows"] += item["n"]
            # A paid user with two requests is ONE paid user and TWO paid requests: the
            # old single `paid` counter mixed the units (a user's rows were summed under a
            # users/requests label), so both are kept and both are printed.
            b["paid_rows"] += item.get("paid_n") or (item["n"] if item["paid"] else 0)
            if item["paid"]:
                b["paid_users"] += 1
            h = age_h(item["oldest"], now)      # the longest-open row in this bucket
            if h and (b["oldest_h"] is None or h > b["oldest_h"]):
                b["oldest_h"] = h
        open_users = sum(b["users"] for b in buckets.values())
        open_rows = sum(b["rows"] for b in buckets.values())
        pop_rows = sum(i["n"] for i in pop.values())
        pop_paid_rows = sum(i.get("paid_n") or (i["n"] if i["paid"] else 0) for i in pop.values())
        pop_paid_users = sum(1 for i in pop.values() if i["paid"])
        if open_rows != pop_rows:
            errors.append(f"{name}: partition mismatch {open_rows} != {pop_rows} "
                          f"(a row landed in no bucket)")
        return {"buckets": buckets, "open_users": open_users, "open_rows": open_rows,
                "open_paid": pop_paid_rows, "open_paid_users": pop_paid_users,
                "age": age_stats(pop, now, medians.get(name)), "flow": flows}

    merges = {}
    clickup: dict = {}
    merges_done24 = {"rows": 0, "users": 0}
    if not light:
        try:
            merges = merge_rows()
        except Exception as e:                                 # noqa: BLE001
            errors.append(f"merges: {type(e).__name__}: {e}")
        try:
            merges_done24 = merges_24h()
        except Exception as e:                                 # noqa: BLE001
            errors.append(f"merges 24h: {type(e).__name__}: {e}")
        try:
            clickup = clickup_merge_queue(now)
        except Exception as e:                                 # noqa: BLE001
            clickup = {}
            errors.append(f"merges clickup: {type(e).__name__}: {e}")
    mrg = summarize_merges(merges, merges_done24, now, bool(
        [e for e in errors if e.startswith("merges")]), clickup)
    cred = summarize(credits, flows_c, lambda u, i: classify_credit(u, facts, i, wz), "credits")
    clai = summarize(claim, flows_k, lambda u, i: classify_claim(u, facts, i, wz, wz_profiles),
                     "claims")
    m = {"at": now.strftime("%Y-%m-%d %H:%MZ"), "credits": cred, "claims": clai,
         "merges": mrg,
         "proof_on_file": proof_meta, "errors": errors,
         "runtime_s": round(time.time() - started, 1)}
    m.update({k: v for k, v in (("ours", gap), ("intake_1h", intake)) if v is not None})

    # ── the backlog sentinel (captain 21:05Z) — runs on every tick, light or full ──
    c_class = lambda u, i: classify_credit(u, facts, i, wz)                    # noqa: E731
    k_class = lambda u, i: classify_claim(u, facts, i, wz, wz_profiles)        # noqa: E731
    failed_pop = frozenset(
        key for prefix, keys in (("credits", ("credits_untouched", "credits_docs_in")),
                                 ("claims", ("claims_untouched", "claims_docs_in")))
        for key in keys if any(e.startswith(prefix + ":") for e in m["errors"]))
    # A failed watchlist or proof feed blinds the lanes that read it: the watchlist feeds
    # `watch` for both families, and the proof feed feeds a CLAIM's support@ contact evidence
    # (the credit classifier reads no contact list), so the sentinel could post a false backlog
    # page built on facts it never read. Those lanes carry their last known set and read
    # unmeasured, exactly like a failed population query (QA @4a25b33).
    failed_pop = failed_pop | frozenset(local_failed)
    probe_base = read_sentinel_state()
    probe_base_ts = (probe_base or {}).get("ts")
    probe = probe_sources(probe_base, now)
    lock_failure: Exception | None = None
    state_write_failure: Exception | None = None
    breaches_msgs, sentinel_state, page_map = [], {"legacy": {}, "breaches": [], "held": {}}, []
    held_facts_now, held_lanes_now = None, None
    found: dict = {"items": {}, "unmeasured": set()}
    ev: dict = {}
    try:
        with sentinel_lock(timeout=SENTINEL_LOCK_WAIT):
            # Re-read under the lock. If another tick advanced the state while we were probing
            # outside it, OUR source results are the stale ones — writing them would roll the
            # owed-reply set back and wipe the delivered-page ledger, so the next tick would
            # page the same conversation again (QA @870cebb).
            sent_prev = read_sentinel_state()
            stale_probe = probe_stale(probe_base_ts, sent_prev)
            if stale_probe:
                # Carry the newer tick's view. Both lanes must read UNMEASURED as well: with an
                # empty unmeasured set sentinel_items treats them as measured-and-empty and
                # clears them, and sentinel_page prunes their delivered ids — so a later delta
                # rediscovers the work and pages it again (QA @17edb6c).
                probe = {"merges": None, "intercom": None,
                         "unmeasured": {"merges_waiting", "intercom_customer_last"}}
            found = sentinel_items(credits, claim, facts, c_class, k_class, wz, wz_profiles,
                                   light=light, prev_state=sent_prev, now=now,
                                   probe=probe, failed_pop=failed_pop)
            ev = sentinel_evaluate(found, now)
            held_facts_now, held_lanes_now = held_facts(), read_held_lanes()
            breaches_msgs, sentinel_state, page_map = sentinel_page(
                ev, sent_prev, now, dry, held_facts_now, held_lanes_now)
            # Deliver the pages and write the shared ledger INSIDE the lock: this is the
            # transaction two coincident ticks would otherwise race on, and an item is only
            # marked told once Slack has confirmed it.
            delivered: list[bool] = []
            for msg in breaches_msgs:
                ok = False
                if "--post" in args and not os.path.exists(SENTINEL_KILL):
                    try:
                        slack_post(slack_token(), msg)
                        ok = True
                        print(f"paged: {msg}")
                    except Exception as e:                      # noqa: BLE001
                        m["errors"].append(f"slack: {type(e).__name__}: {e}")
                delivered.append(ok)
            sentinel_state = record_paged(sentinel_state, page_map, delivered)
            if not dry and "--no-state" not in args:
                try:
                    write_sentinel_state(carry_caches(sentinel_state, found, sent_prev))
                except OSError as e:
                    # If Slack accepted a page but the ledger could not be saved, the next
                    # tick re-sends it. That is a FAILED run, not a log line (QA @90e4006).
                    state_write_failure = e
                    print(f"backlog-sentinel: could not write {SENTINEL_STATE}: {e}")
    except (OSError, TimeoutError) as e:
        # The sentinel could not take its state lock. That must NOT take the report down with
        # it: the captain's 30-minute DM is the product, and returning 0 here made it vanish
        # silently while cron saw success (QA @ba0264b). Report a degraded tick, say so, and
        # exit non-zero so cron-health notices.
        lock_failure = e
        print(f"backlog-sentinel: could not take the state lock: {e}")
    m["errors"].extend((found.get("items", {}) or {}).get("_errors", []))
    m["legacy"] = dict(sentinel_state.get("legacy") or {},
                       total=sum((sentinel_state.get("legacy") or {}).values()))
    if lock_failure is not None:
        # An unknown legacy trend is not a flat one: drop the line rather than print zeros.
        m["legacy"] = {}
        m["errors"].append(f"sentinel lock: {type(lock_failure).__name__}: {lock_failure}")
    comms = comms_build(credits, claim, facts, c_class, k_class, wz, wz_profiles, clickup,
                        ((probe.get("intercom") or {}).get("never_answered")
                         or ((read_sentinel_state() or {}).get("intercom") or {}
                             ).get("never_answered") or {}),
                        now, unmeasured=set(probe.get("unmeasured") or ()) | set(local_failed))
    m["comms"] = comms
    dnc = decided_not_closed()
    m["decided_not_closed"] = dnc
    m["headline"] = headline_build(credits, claim, c_class, k_class, dnc)
    m["held"] = held_words_now(
        sentinel_state.get("held") or {}, held_facts_now, held_lanes_now,
        {k: (len(v.get("breaches") or ()), round(max((a for _i, a in v.get("breaches") or ()),
                                                     default=0)))
         for k, v in ev.items() if v.get("breaches")})
    m["sentinel_lock_busy"] = lock_failure is not None
    m["sentinel"] = {k: {"legacy": v["legacy"], "breaches": len(v["breaches"]),
                         "unmeasured": v["unmeasured"], "owner": v["owner"]}
                     for k, v in ev.items()}

    prev = None
    if "--no-state" not in args and not dry and os.path.exists(STATE):
        try:
            with open(STATE) as fh:
                prev = json.load(fh)
        except ValueError:
            prev = None

    # An empty m["legacy"] means the sentinel did not run this tick (lock busy), NOT that the
    # backlog is zero: comparing it would raise KeyError('total') and take the DM with it
    # (QA @90e4006).
    prev_total = ((prev or {}).get("legacy") or {}).get("total")
    cur_total = m["legacy"].get("total") if m.get("legacy") else None
    if prev_total is not None and cur_total is not None and cur_total == prev_total \
            and cur_total > 0:
        m["legacy_flat"] = ((prev or {}).get("legacy_flat") or 0) + 1
    else:
        m["legacy_flat"] = 0

    if "--grid" in args:
        gc = grid_build({u: dict(i, oldest_h=age_h(i["oldest"], now)) for u, i in credits.items()},
                        lambda u, i: classify_credit(u, facts, i, wz), flows_c)
        gk = grid_build({u: dict(i, oldest_h=age_h(i["oldest"], now)) for u, i in claim.items()},
                        lambda u, i: classify_claim(u, facts, i, wz, wz_profiles), flows_k)
        lines = [f"Where the queues stand by request date ({m['at']})", PAUSED_LINE, ""]
        lines += grid_render("CREDITS", gc, "requests") + [""]
        lines += grid_render("PROFILE CLAIMS", gk, "claims") + [""]
        cu = (m.get("merges") or {}).get("clickup") or {}
        lines += ["PROFILE MERGES  (ClickUp user-requests queue + merge engine)", ""]
        if cu:
            lines.append(f"open {cu['open']} · nobody has touched {cu['untouched']} · "
                         f"waiting on the user (must claim first) {cu['waiting_user']} · "
                         f"held (contested/conflict/stale) {cu['held']} · "
                         f"done 24h {cu['done24']}")
        mg = m.get("merges") or {}
        lines.append(f"engine: {mg.get('stuck_rows', 0)} executing/stuck "
                     f"(callback_received {mg.get('callback', 0)}, unverified "
                     f"{mg.get('unverified', 0)}), {mg.get('done24_rows', 0)} verified in 24h")
        lines.append("_Per-date buckets for merges need the ticket date_created + tag state "
                     "joined; the ClickUp read here returns per-status counts only — reported "
                     "as counts, not bucketed, rather than guessed._")
        text = "```\n" + "\n".join(lines) + "\n```"
        if "--post" in args:
            try:
                print(f"posted ts={slack_post(slack_token(), text)}")
            except Exception as e:                             # noqa: BLE001
                print(f"grid DM failed: {type(e).__name__}: {e}")
                return 1
        else:
            print(text)
        if GRID_OUT:
            os.makedirs(os.path.dirname(GRID_OUT), exist_ok=True)
            with open(GRID_OUT, "w") as fh:
                fh.write(text.strip("`").strip() + "\n")
            print(f"wrote {GRID_OUT}")
        return 0

    if "--json" in args:
        print(json.dumps(m, indent=1, default=str))
        return 0
    # The legacy trend is a property of the 30-MINUTE REPORT, not of a light probe: a light
    # tick never writes the report state, so comparing against it would page the same stale
    # delta over and over (it did once: 5,062 -> 5,063 at 21:45Z).
    stalls = [] if light else stall_pages(m, prev)
    comms_msgs = [] if light else comms_pages(m.get("comms") or {},
                                              (prev or {}).get("comms_sig"))
    # A failed credits/claims read leaves {} behind — and render() would raise on it before
    # the captain ever saw an honest line (QA @be2b000). So the fatal decision comes FIRST:
    # an unmeasured report says exactly that, once, and never touches the state.
    fatal = incomplete_errors(m["errors"])
    if fatal and not light:
        m["incomplete"] = fatal
        # An INCOMPLETE report must not page coverage either: its comms classes were built on
        # tables that were never measured, and a page is a stronger claim than a table line
        # (QA @ac05f37). The sentinel breaches keep their own unmeasured handling.
        comms_msgs = []
        text = ("Credits, claims and merges report INCOMPLETE at "
                f"{m['at']} — the numbers are not zeros, they were not measured: "
                + "; ".join(fatal[:2]) +
                ". No baseline was written, so the next report's arrows stay honest.")
    elif light:
        # A light tick is a sentinel probe, not a report: the report tables were never
        # measured, and half a report is worse than none.
        text = ""
    else:
        text = render(m, prev)
    if "--post" in args:
        try:
            token = slack_token()
            if not light:
                ts = slack_post(token, text)
                m["slack_ts"] = ts
                print(f"posted ts={ts}")
            for msg in comms_msgs + stalls:
                if os.path.exists(SENTINEL_KILL):
                    break
                slack_post(token, msg)
                print(f"paged: {msg}")
            if os.path.exists(SENTINEL_KILL) and breaches_msgs:
                print(f"backlog-sentinel: {len(breaches_msgs)} page(s) suppressed by "
                      f"{SENTINEL_KILL}; they stay unsent for the next tick")
        except Exception as e:                                 # noqa: BLE001
            print(f"verification-queue-report: Slack post failed: {type(e).__name__}: {e}")
            return 1
    else:
        if text:
            print(text)
        for msg in breaches_msgs + comms_msgs + stalls:
            print()
            print(msg)
    if dry or "--no-state" in args:
        return 0
    if light:
        # A light tick measured no tables. Writing its (empty) payload as the report state
        # would wipe the arrows baseline the next 30-minute report compares against — and
        # it did, once (22:10Z). Its sentinel state was already written under the lock.
        #
        # A light tick MUST fail on a state-write failure too: if Slack accepted a breach
        # page but the `paged` ledger could not be saved, the next tick re-pages it, and
        # returning 0 here told cron everything was fine (QA @a327b83).
        if state_write_failure is not None:
            print(f"backlog-sentinel: delivered pages could not be persisted to "
                  f"{SENTINEL_STATE} ({state_write_failure}) — the next tick may re-page them; "
                  f"failing the run")
            return 1
        return 1 if m["errors"] else 0
    if m.get("incomplete"):
        print("; ".join(m["incomplete"]))
        return 1
    m["comms_sig"] = comms_signature(m.get("comms") or {}, (prev or {}).get("comms_sig"))
    try:
        os.makedirs(os.path.dirname(STATE), exist_ok=True)
        tmp = STATE + ".tmp"
        with open(tmp, "w") as f:
            json.dump(m, f)
        os.replace(tmp, STATE)
    except OSError as e:
        # The arrows baseline is the product's memory: if it could not be saved, the next DM
        # repeats stale deltas. That is a failed run, not a log line (QA @d5c1d18).
        print(f"verification-queue-report: could not write {STATE}: {e}")
        return 1
    if lock_failure is not None:
        print(f"backlog-sentinel: state lock busy — sentinel did not run this tick ({lock_failure})")
        return 1
    if state_write_failure is not None:
        print(f"backlog-sentinel: delivered pages could not be persisted to {SENTINEL_STATE} "
              f"({state_write_failure}) — the next tick may re-page them; failing the run")
        return 1
    if m["errors"]:
        print("; ".join(m["errors"]))
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
