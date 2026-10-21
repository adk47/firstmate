#!/usr/bin/env python3
"""Tests for the trust-yet-verify note step (credit-review.py verify-notify).

Stdlib unittest, no network: the admin API is faked, the gate script is either
faked (unit) or the real one in its TESTABLE copy against a curl stub (wiring).
Run:
    python3 scripts/tests/test_credit_verify_notify.py
"""

from __future__ import annotations

import credit_test_env  # noqa: F401,E402 - first: test logs never reach the production run.log
import json
import re
import os
import shutil
import sqlite3
import stat
import subprocess
import sys
import tempfile
import unittest
import unittest.mock
from datetime import datetime, timedelta, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))

# A fresh, empty proof-on-file list for every test that does not bring its own: the
# driver refuses to send anything without one (missing / stale = zero asks).
_PROOF_DIR = tempfile.mkdtemp(prefix="proof-on-file-")
PROOF_FILE = os.path.join(_PROOF_DIR, "proof-on-file.json")


def proof_doc(entries=(), generated_at=None, age_h=0.0, contacts=()):
    """A complete proof-on-file export: every required part present and fresh, users count
    consistent with entries (the shape the exporter writes)."""
    gen = generated_at or (datetime.now(timezone.utc) - timedelta(hours=age_h)).strftime("%Y-%m-%dT%H:%M:%SZ")
    return {"generated_at": gen,
            "sources": [{"name": "core", "generated_at": gen, "count": 0}]
            + [{"name": n, "generated_at": gen, "stale": False, "count": 0} for n in ("cs-intercom", "cs-gmail")],
            "users": len({str(e["user_id"]) for e in entries}), "entries": list(entries),
            "gmail_contacts_90d": {"generated_at": gen, "source": "test", "user_ids": list(contacts)}}


def write_proof(path=PROOF_FILE, entries=(), age_h=0.0, contacts=()):
    Path(path).write_text(json.dumps(proof_doc(entries, age_h=age_h, contacts=contacts)))


write_proof()
os.environ["CREDIT_PROOF_ON_FILE"] = PROOF_FILE
# Org-affiliation verdicts (RULE-org-affiliation): every test account is "none" unless a test
# brings its own; without a file the run sends nothing.
AFFILIATION_FILE = os.path.join(_PROOF_DIR, "org-affiliation.json")
# One Muso user id per test account: the per-user locks key on the user id as well as the
# email (QA review of #1257 @21f2de0), so two accounts must not share one.
TEST_ACCOUNTS = {"jane@example.com": "42", "bob@example.com": "43", "b@example.com": "44", "c@example.com": "7",
                 "gone@example.com": "77", "paid@example.com": "78", "sam@example.com": "79", "u500@example.com": "500"}


def _uid_of(email):
    return TEST_ACCOUNTS.get((email or "jane@example.com").lower(), "42")


TEST_USERS = ("42", "43", "44", "7", "77", "78", "79", "500")


def affiliation_v1(verdicts, *, age_h=0.0):
    """org-affiliation/v1 around {uid: {verdict, evidence}} (full coverage unless an entry says
    otherwise); a flat file is refused (affiliation.read)."""
    gen = (datetime.now(timezone.utc) - timedelta(hours=age_h)).strftime("%Y-%m-%dT%H:%M:%SZ")
    return {"schema": "org-affiliation/v1", "generated_at": gen,
            "users": {u: {"coverage": "full", **v} for u, v in verdicts.items()}, "held": {}}


def write_affiliation(verdicts=None, path=AFFILIATION_FILE):
    Path(path).write_text(json.dumps(affiliation_v1(verdicts if verdicts is not None
                                                    else {u: {"verdict": "none", "evidence": []} for u in TEST_USERS})))


write_affiliation()
os.environ["CREDIT_RETRO_ORG_AFFILIATION"] = AFFILIATION_FILE
# Paying status: unknown in tests unless a test brings a file (oldest first).
os.environ.setdefault("CREDIT_TRUST_PAYING_USERS_FILE", os.path.join(_PROOF_DIR, "paying-users.json"))

from credit_review import verify_ledger, verify_notify  # noqa: E402

# The replica is never read in tests: every test account's Auth0 subject is "auth-<id>".
verify_notify.AUTH_LOOKUP = lambda ids: {str(u): "auth0|test-subject" for u in ids if str(u)}
from credit_review.verify_notify import CAPTAIN_UID, ContractError, Report  # noqa: E402

PID = "11111111-2222-3333-4444-555555555555"
PID2 = "99999999-2222-3333-4444-555555555555"


def req(rid, *, pid=PID, status="approved", email="jane@example.com", name="Jane Doe", title="Song",
        artist="Big Star", roles=("Mixing",), created="2026-10-15T20:00:00Z", track="t1"):
    return {"id": rid, "profileId": pid, "trackId": track, "status": status, "spotifyTrackTitle": title,
            "spotifyTrackArtists": [{"id": "a", "name": artist}], "credits": list(roles), "createdAt": created,
            "user": {"id": _uid_of(email), "fullName": name, "email": email} if email else None}



class FakeAdmin:
    def __init__(self, rows):
        self.rows = rows
        self.calls = []

    def get(self, path, params=None):
        self.calls.append((path, dict(params or {})))
        if path.startswith("/admin/profile/"):
            return (getattr(self, "profiles", {}) or {}).get(path.rsplit("/", 1)[1], {"isClaimed": False})
        assert path == "/admin/credit-requests"
        p = params or {}
        items = [r for r in self.rows if r["status"] == p.get("status")
                 and (not p.get("profilesIds") or r["profileId"] == p["profilesIds"])
                 and (not p.get("trackId") or r["trackId"] == p["trackId"])]
        lim, page = int(p.get("limit", 10)), int(p.get("page", 1))
        return {"items": items[(page - 1) * lim: page * lim]}


# The decider's ledger schema, copied VERBATIM from credit_review/decide.py SCHEMA (T01 lane,
# fm/credit-trust-llm-t01) so this suite exercises the contract the real decider writes:
# outcomes live in decision_outcomes, never as a column on decisions.
DECIDER_SCHEMA = """
CREATE TABLE IF NOT EXISTS decisions (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  run_id TEXT NOT NULL,
  decided_at TEXT NOT NULL,
  request_id TEXT NOT NULL,
  profile_id TEXT,
  user_id INTEGER,
  track_id TEXT,
  track_title TEXT,
  claimed_roles TEXT,
  popularity INTEGER,
  big_track INTEGER NOT NULL,
  decision TEXT NOT NULL,
  reason TEXT NOT NULL,
  evidence_kind TEXT,
  catalog TEXT,
  web_verdict TEXT,
  web_urls TEXT,
  footprint INTEGER,
  n1 INTEGER NOT NULL DEFAULT 0,
  model TEXT,
  provider TEXT,
  cost_usd REAL,
  prompt_sha256 TEXT,
  llm_call_id INTEGER,
  conflict TEXT,
  mode TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS decision_outcomes (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  run_id TEXT NOT NULL,
  at TEXT NOT NULL,
  request_id TEXT NOT NULL,
  action TEXT NOT NULL,
  outcome TEXT NOT NULL
);
"""


def decisions_db(path, rows, *, schema=DECIDER_SCHEMA):
    """Write decider rows the way decide.py does: one decisions row per decision, then
    the server outcome of the write as a decision_outcomes row."""
    db = sqlite3.connect(path)
    db.executescript(schema)
    for r in rows:
        db.execute("INSERT INTO decisions (run_id, decided_at, request_id, profile_id, user_id, track_id, big_track, "
                   "decision, reason, mode) VALUES (?,?,?,?,?,?,0,?,?, 'apply')",
                   (r["run_id"], r["at"], r["request_id"], r["profile_id"], 42, r["track_id"],
                    "approve" if r["action"] == "approve" else "support", "test"))
        db.execute("INSERT INTO decision_outcomes (run_id, at, request_id, action, outcome) VALUES (?,?,?,?,?)",
                   (r["run_id"], r["at"], r["request_id"], r["action"], r["outcome"]))
    db.commit()
    db.close()


def dec(rid, outcome="approved", pid=PID, run="run-1", at="2026-10-15T22:30:00Z", track="t1", action="approve"):
    return {"request_id": rid, "profile_id": pid, "outcome": outcome, "action": action, "run_id": run, "at": at,
            "track_id": track}


def _ago(hours):
    return (datetime.now(timezone.utc) - timedelta(hours=hours)).strftime("%Y-%m-%dT%H:%M:%SZ")


# firstmate 090: no outgoing message may name a deadline or say a credit will be removed.
REMOVAL_LANGUAGE = re.compile(r"will be removed|be removed from your profile|removed from your profile (after|on|that)"
                              r"|reply[^.]{0,80}\bby (january|february|march|april|may|june|july|august|september|"
                              r"october|november|december|\d)|\b30 days\b|deadline|last reminder", re.I)


def posted_bodies(stub_log):
    """The JSON payloads the curl stub received on POST /messages (subject + HTML body)."""
    p = Path(stub_log + ".bodies")
    return [json.loads(ln) for ln in p.read_text().splitlines() if ln.strip()] if p.exists() else []


def assert_no_removal_language(tc, api_log_or_text):
    text = api_log_or_text if isinstance(api_log_or_text, str) else json.dumps(api_log_or_text)
    m = REMOVAL_LANGUAGE.search(text)
    tc.assertIsNone(m, f"removal/deadline language in an outgoing message: {m.group(0) if m else ''!r}")


class Fake:
    """Records gate invocations; answers like the real gate."""

    def __init__(self, answers=None):
        self.argv = []
        self.payloads = []
        self.answers = answers or {}

    def __call__(self, argv):
        self.argv.append(argv)
        if argv[1] == "send":
            payload = json.loads(Path(argv[argv.index("--credits-file") + 1]).read_text())
            self.payloads.append(payload)
            key = payload["user"]["email"]
            rc, out, err = self.answers.get(key, (0, f"POSTED email message=1 credits={len(payload['credits'])}", ""))
        else:
            rc, out, err = self.answers.get(argv[-1], (3, "NO PROOF YET", ""))
        return subprocess.CompletedProcess(argv, rc, out + "\n", err)


def windowed_note(db):
    """A windowed verify-live note sent 2026-10-01 for r1 and r2 (reminder-14 due 2026-10-15)."""
    return verify_ledger.claim(db, user_key="jane@example.com", day="2026-10-01", request_ids=["r1", "r2"],
                               message_type="email", approved_by=CAPTAIN_UID, approval_ref="ref", windowed=True,
                               refs=[{"request_id": "r1", "profile_id": PID, "track_id": "t1"},
                                     {"request_id": "r2", "profile_id": PID, "track_id": "t2"}])


class LedgerTests(unittest.TestCase):
    def setUp(self):
        self.db = verify_ledger.connect(":memory:")
        self.addCleanup(self.db.close)
        self.kw = dict(message_type="email", approved_by=CAPTAIN_UID, approval_ref="ref")

    def test_claim_is_idempotent_per_request_id(self):
        c = verify_ledger.claim(self.db, user_key="a@x.com", day="2026-10-15", request_ids=["r1", "r2"], **self.kw)
        self.assertEqual(c["result"], "claimed")
        verify_ledger.finalize(self.db, message_row=c["message_row"], status="sent", message_id="9")
        again = verify_ledger.claim(self.db, user_key="a@x.com", day="2026-10-20", request_ids=["r1", "r2"], **self.kw)
        self.assertEqual(again["result"], "already_notified")

    def test_one_note_per_user_per_day(self):
        c = verify_ledger.claim(self.db, user_key="a@x.com", day="2026-10-15", request_ids=["r1"], **self.kw)
        verify_ledger.finalize(self.db, message_row=c["message_row"], status="sent", message_id="9")
        d = verify_ledger.claim(self.db, user_key="a@x.com", day="2026-10-15", request_ids=["r1", "r2"], **self.kw)
        self.assertEqual(d, {"result": "daily_cap", "request_ids": ["r2"]})
        # Deferred ids carry no row; the shared 90-day re-ask lock (Fable 2026-10-17) keeps
        # them waiting after the day too, and they are claimed once the lock lapses.
        self.assertEqual(verify_ledger.blocked_ids(self.db, ["r2"]), set())
        n = verify_ledger.claim(self.db, user_key="a@x.com", day="2026-10-16", request_ids=["r1", "r2"], **self.kw)
        self.assertEqual((n["result"], n["request_ids"]), ("recently_asked", ["r2"]))
        n = verify_ledger.claim(self.db, user_key="a@x.com", day="2027-01-13", request_ids=["r1", "r2"], **self.kw)
        self.assertEqual((n["result"], n["request_ids"]), ("claimed", ["r2"]), "day 90 after the note: the lock lapsed")

    def test_an_attempt_with_unknown_outcome_blocks_a_resend(self):
        c = verify_ledger.claim(self.db, user_key="a@x.com", day="2026-10-15", request_ids=["r1"], **self.kw)
        self.assertEqual(c["result"], "claimed")
        self.assertEqual(verify_ledger.blocked_ids(self.db, ["r1"]), {"r1"})
        self.assertEqual(verify_ledger.claim(self.db, user_key="a@x.com", day="2026-10-16", request_ids=["r1"],
                                             **self.kw)["result"], "already_notified")

    def test_rejected_is_retried_at_most_max_attempts(self):
        for day in range(verify_ledger.MAX_ATTEMPTS):
            c = verify_ledger.claim(self.db, user_key="a@x.com", day=f"2026-10-{15 + day}", request_ids=["r1"], **self.kw)
            self.assertEqual(c["result"], "claimed")
            verify_ledger.finalize(self.db, message_row=c["message_row"], status="rejected", reason="server_error")
        self.assertEqual(verify_ledger.claim(self.db, user_key="a@x.com", day="2026-10-30", request_ids=["r1"],
                                             **self.kw)["result"], "already_notified")

    def test_a_refusal_is_terminal_and_does_not_use_the_daily_note(self):
        verify_ledger.refuse(self.db, user_key="a@x.com", day="2026-10-15", request_ids=["r1"], reason="leak", **self.kw)
        self.assertEqual(verify_ledger.blocked_ids(self.db, ["r1"]), {"r1"})
        c = verify_ledger.claim(self.db, user_key="a@x.com", day="2026-10-15", request_ids=["r2"], **self.kw)
        self.assertEqual(c["result"], "claimed")

    def test_the_proof_sweep_rotates_least_recently_checked_first(self):
        for i in range(3):
            c = verify_ledger.claim(self.db, user_key=f"u{i}@x.com", day="2026-10-15", request_ids=[f"r{i}"], **self.kw)
            verify_ledger.finalize(self.db, message_row=c["message_row"], status="sent", message_id=f"{i}")
        verify_ledger.mark_checked(self.db, message_id="0", now=datetime(2026, 10, 15, 23, tzinfo=timezone.utc))
        verify_ledger.mark_checked(self.db, message_id="1", now=datetime(2026, 10, 15, 22, tzinfo=timezone.utc))
        self.assertEqual(verify_ledger.awaiting_proof(self.db), ["2", "1", "0"])

    def test_awaiting_proof_lists_sent_untagged_notes(self):
        c = verify_ledger.claim(self.db, user_key="a@x.com", day="2026-10-15", request_ids=["r1"], **self.kw)
        verify_ledger.finalize(self.db, message_row=c["message_row"], status="sent", message_id="77")
        self.assertEqual(verify_ledger.awaiting_proof(self.db), ["77"])
        verify_ledger.mark_tagged(self.db, message_id="77", conversation_id="5")
        self.assertEqual(verify_ledger.awaiting_proof(self.db), [])


# The verify ledger schema as the previous version of verify_ledger.py created it (before
# per-credit proof reviews, attachment baselines and reply holds), copied verbatim.
PREVIOUS_LEDGER_SCHEMA = """
CREATE TABLE IF NOT EXISTS verify_messages (
  id INTEGER PRIMARY KEY AUTOINCREMENT, campaign TEXT NOT NULL, kind TEXT NOT NULL, parent_row INTEGER,
  user_key TEXT NOT NULL, day TEXT NOT NULL, due_day TEXT, removal_day TEXT, status TEXT NOT NULL,
  message_type TEXT NOT NULL, contact_id TEXT, message_id TEXT, conversation_id TEXT, request_ids_json TEXT NOT NULL,
  refs_json TEXT, n_credits INTEGER NOT NULL, approved_by TEXT NOT NULL, approval_ref TEXT NOT NULL,
  body_sha256 TEXT, reason TEXT, api_log TEXT, attempts INTEGER NOT NULL DEFAULT 1, created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL, proof_tagged_at TEXT, proof_checked_at TEXT
);
CREATE INDEX IF NOT EXISTS verify_messages_user_day ON verify_messages(user_key, day);
CREATE INDEX IF NOT EXISTS verify_messages_msg ON verify_messages(message_id);
CREATE INDEX IF NOT EXISTS verify_messages_parent ON verify_messages(parent_row, kind);
CREATE TABLE IF NOT EXISTS verify_requests (
  campaign TEXT NOT NULL, request_id TEXT NOT NULL, message_row INTEGER NOT NULL, status TEXT NOT NULL,
  attempts INTEGER NOT NULL DEFAULT 1, updated_at TEXT NOT NULL, profile_id TEXT, track_id TEXT, deferred_at TEXT,
  PRIMARY KEY (campaign, request_id)
);
"""


class LedgerMigrationTests(unittest.TestCase):
    def test_a_ledger_created_by_the_previous_schema_gets_the_new_columns_and_tables(self):
        tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, tmp)
        path = os.path.join(tmp, "ledger.sqlite3")
        old = sqlite3.connect(path)
        old.executescript(PREVIOUS_LEDGER_SCHEMA)
        old.execute("INSERT INTO verify_messages (campaign, kind, user_key, day, due_day, removal_day, status, "
                    "message_type, message_id, contact_id, request_ids_json, n_credits, approved_by, approval_ref, "
                    "created_at, updated_at) VALUES ('verify-live','initial','a@x.com','2026-10-16','2026-11-15',"
                    "'2026-11-16','sent','email','500','c1','[\"r1\",\"r2\"]',2,'u','r','t','t')")
        old.commit()
        old.close()
        res = subprocess.run([sys.executable, str(ROOT / "scripts" / "credit_review" / "verify_ledger.py"), "--db", path,
                              "mark-tagged", "--message-id", "500", "--conversation-id", "9", "--attachments", "1"],
                             capture_output=True, text=True, timeout=60, check=False)
        self.assertEqual(res.returncode, 0, res.stderr)
        db = verify_ledger.connect(path)
        self.addCleanup(db.close)
        self.assertEqual(verify_ledger.message(db, "500")["proof_attachments"], 1)
        self.assertEqual(verify_ledger.mark_replied(db, message_id="500"), "recorded")
        self.assertEqual(verify_ledger.record_proof_review(db, message_id="500", request_ids=["r2"], outcome="rejected",
                                                           reviewer="x", reason="unreadable")["result"], "ok")
        self.assertEqual([(h["request_id"], h["reason"]) for h in verify_ledger.held_for_human(db, day="2026-11-16")],
                         [("r1", verify_ledger.HELD_AWAITING_REVIEW), ("r2", verify_ledger.HELD_NOT_TOLD)])
        c = verify_ledger.claim(db, user_key="b@x.com", day="2026-10-16", request_ids=["r9"], message_type="email",
                                approved_by=CAPTAIN_UID, approval_ref="ref", windowed=True)
        self.assertEqual(c["result"], "claimed")


class WindowAndPastLedgerTests(unittest.TestCase):
    """verify-live windowed notes (new credits: 30 days + removal date, reminders 14/25)
    vs retro-past notes (past credits: no deadline, one follow-up, never removed)."""

    def setUp(self):
        self.db = verify_ledger.connect(":memory:")
        self.addCleanup(self.db.close)
        self.kw = dict(message_type="email", approved_by=CAPTAIN_UID, approval_ref="ref")

    def note(self, ids=("r1",), day="2026-10-16", mid="500", user="a@x.com", campaign="verify-live", windowed=True):
        c = verify_ledger.claim(self.db, user_key=user, day=day, request_ids=list(ids), campaign=campaign,
                                refs=[{"request_id": r, "profile_id": PID, "track_id": "t1"} for r in ids],
                                windowed=windowed, **self.kw)
        self.assertEqual(c["result"], "claimed")
        verify_ledger.finalize(self.db, message_row=c["message_row"], status="sent", message_id=mid)
        return c

    def remind(self, kind, day, ids=("r1",), mid="500", user="a@x.com"):
        return verify_ledger.claim_reminder(self.db, parent_message_id=mid, kind=kind, user_key=user, day=day,
                                            request_ids=list(ids), approved_by=CAPTAIN_UID, approval_ref="ref")

    def test_a_windowed_note_names_the_window_and_the_removal_date(self):
        c = self.note()
        self.assertEqual((c["due_day"], c["removal_day"]), ("2026-11-15", "2026-11-16"),
                         "the note names the reply-by date; removal is due only from the day after it")

    def test_only_new_provisional_approvals_can_carry_a_removal_date(self):
        with self.assertRaises(ValueError):
            verify_ledger.claim(self.db, user_key="a@x.com", day="2026-10-16", request_ids=["r1"],
                                campaign="retro-past", windowed=True, **self.kw)

    def test_a_credit_is_asked_about_once_across_campaigns_and_the_daily_cap_is_shared(self):
        self.note(campaign="retro-past", windowed=False)
        self.assertEqual(verify_ledger.blocked_ids(self.db, ["r1"], "verify-live"), {"r1"})
        self.assertEqual(verify_ledger.blocked_ids(self.db, ["r1"], "retro-past"), {"r1"})
        live = verify_ledger.claim(self.db, user_key="a@x.com", day="2026-10-16", request_ids=["r9"], **self.kw)
        self.assertEqual(live["result"], "daily_cap")

    def test_an_earlier_ask_never_blocks_the_take_back_notice_only_its_own_does(self):
        self.note(campaign="retro-past", windowed=False)
        self.assertEqual(verify_ledger.blocked_ids(self.db, ["r1"], "takeback-notice"), set())
        tb = verify_ledger.claim(self.db, user_key="a@x.com", day="2026-10-20", request_ids=["r1"],
                                 campaign="takeback-notice", **self.kw)
        self.assertEqual((tb["result"], tb["request_ids"]), ("claimed", ["r1"]))
        verify_ledger.finalize(self.db, message_row=tb["message_row"], status="sent", message_id="600")
        self.assertEqual(verify_ledger.blocked_ids(self.db, ["r1"], "takeback-notice"), {"r1"})
        again = verify_ledger.claim(self.db, user_key="a@x.com", day="2026-10-21", request_ids=["r1"],
                                    campaign="takeback-notice", **self.kw)
        self.assertEqual(again["result"], "already_notified")

    def test_windowed_reminders_at_day_14_and_25_once_each_none_after_the_window(self):
        self.note()
        self.assertEqual(self.remind("reminder-14", "2026-10-29")["result"], "not_due")
        r = self.remind("reminder-14", "2026-10-30")
        self.assertEqual((r["result"], r["due_day"], r["removal_day"]), ("claimed", "2026-11-15", "2026-11-16"))
        verify_ledger.finalize(self.db, message_row=r["message_row"], status="sent", message_id="501")
        self.assertEqual(self.remind("reminder-14", "2026-10-31")["result"], "done")
        self.assertEqual(self.remind("reminder-25", "2026-11-09")["result"], "not_due")
        self.assertEqual(self.remind("reminder-25", "2026-11-16")["result"], "done")
        self.assertEqual(self.remind("reminder-25", "2026-11-10")["result"], "claimed")

    def test_an_unwindowed_v1_note_has_no_follow_ups_and_is_never_removal_due(self):
        self.note(windowed=False)
        self.assertEqual(self.remind("reminder-14", "2026-10-30")["result"], "not_applicable")
        self.assertEqual(verify_ledger.reminders_due(self.db, campaign="verify-live", day="2026-10-30"), [])
        self.assertEqual(verify_ledger.removal_due(self.db, day="2027-01-01"), [])

    def test_a_past_note_gets_no_follow_up_and_is_never_removal_due(self):
        self.note(campaign="retro-past", windowed=False)
        for kind in ("reminder-14", "reminder-25"):
            self.assertEqual(self.remind(kind, "2026-10-30")["result"], "not_applicable")
        self.assertEqual(verify_ledger.reminders_due(self.db, campaign="retro-past", day="2026-10-30"), [])
        self.assertEqual(verify_ledger.removal_due(self.db, day="2027-01-01"), [])

    def test_past_one_message_per_user_ever_across_campaigns(self):
        self.note(campaign="verify-live", ids=("n1",))
        c = verify_ledger.claim(self.db, user_key="a@x.com", day="2026-11-30", request_ids=["p1"],
                                campaign="retro-past", **self.kw)
        self.assertEqual((c["result"], c["reason"]), ("user_done", "already_asked"))
        self.assertEqual(verify_ledger.blocked_ids(self.db, ["p1"], "retro-past"), {"p1"})

    def test_past_never_to_a_user_who_sent_proof(self):
        self.note(campaign="verify-live", ids=("n1",), user="b@x.com", mid="700")
        verify_ledger.mark_tagged(self.db, message_id="700", conversation_id="1")
        self.assertEqual(verify_ledger.past_user_done(self.db, "b@x.com"), "already_asked")
        self.assertEqual(verify_ledger.past_user_done(self.db, "fresh@x.com"), "")
        db2 = verify_ledger.connect(":memory:")
        self.addCleanup(db2.close)
        db2.execute("INSERT INTO verify_messages (campaign, kind, user_key, day, status, message_type, request_ids_json, "
                    "n_credits, approved_by, approval_ref, created_at, updated_at, proof_tagged_at) VALUES "
                    "('verify-live','initial','c@x.com','2026-10-16','refused','email','[]',0,'u','r','t','t','t')")
        self.assertEqual(verify_ledger.past_user_done(db2, "c@x.com"), "proof_received")

    def test_a_credit_asked_about_in_one_campaign_is_never_asked_in_another(self):
        self.note(campaign="verify-live", ids=("r1",))
        self.assertEqual(verify_ledger.blocked_ids(self.db, ["r1", "r2"], "retro-past"), {"r1"})



    def test_unverified_past_flags_non_responders_after_30_days_and_never_removes(self):
        self.note(campaign="retro-past", windowed=False, ids=("p1", "p2"))
        self.note(campaign="retro-past", windowed=False, ids=("p3",), mid="600", user="b@x.com")
        verify_ledger.mark_tagged(self.db, message_id="600", conversation_id="7")
        self.assertEqual(verify_ledger.unverified_past(self.db, day="2026-11-14"), [])
        rows = verify_ledger.unverified_past(self.db, day="2026-11-15")
        self.assertEqual([(r["request_id"], r["flag"]) for r in rows], [("p1", "unverified"), ("p2", "unverified")])
        self.assertIn("the credit stays", rows[0]["reason"])

    def test_a_reminder_lists_only_the_notes_credits_for_the_notes_user(self):
        self.note(ids=("r1", "r2"))
        self.assertEqual(self.remind("reminder-14", "2026-10-30", user="b@x.com")["result"], "wrong_user")
        self.assertEqual(self.remind("reminder-14", "2026-10-30", ids=("zz",))["result"], "no_credits")
        self.assertEqual(self.remind("reminder-14", "2026-10-30", ids=("r2", "zz"))["request_ids"], ["r2"])

    def test_proof_on_a_reminder_stops_every_later_reminder_and_removal(self):
        self.note()
        r = self.remind("reminder-14", "2026-10-30")
        verify_ledger.finalize(self.db, message_row=r["message_row"], status="sent", message_id="501")
        verify_ledger.mark_tagged(self.db, message_id="501", conversation_id="9")
        self.assertEqual(self.remind("reminder-25", "2026-11-10")["result"], "proof_received")
        self.assertEqual(verify_ledger.removal_due(self.db, day="2026-11-20"), [])

    def test_reminders_due_offers_only_the_latest_kind(self):
        self.note()
        self.assertEqual([k for _, k, _ in verify_ledger.reminders_due(self.db, campaign="verify-live", day="2026-10-30")],
                         ["reminder-14"])
        due = verify_ledger.reminders_due(self.db, campaign="verify-live", day="2026-11-12")
        self.assertEqual([(m, k) for m, k, _ in due], [("500", "reminder-25")])
        self.assertEqual(due[0][2][0]["profile_id"], PID)
        self.assertEqual(verify_ledger.reminders_due(self.db, campaign="verify-live", day="2026-11-16"), [])

    def review(self, ids, outcome, mid="500", reviewer="ops-doc-step", reason=None):
        if reason is None:
            reason = "doesnt_name_you" if outcome == "rejected" else ""
        return verify_ledger.record_proof_review(self.db, message_id=mid, request_ids=list(ids), outcome=outcome,
                                                 reviewer=reviewer, reason=reason)

    def due_ids(self, day="2026-11-20"):
        return [d["request_id"] for d in verify_ledger.removal_due(self.db, day=day)]

    def held(self, day="2026-11-20"):
        return [(h["request_id"], h["reason"]) for h in verify_ledger.held_for_human(self.db, day=day)]

    def tell(self, day, ids, mid="590"):
        c = self.remind(verify_ledger.AFTER_REJECTION, day, ids=ids)
        self.assertEqual(c["result"], "claimed", c)
        verify_ledger.finalize(self.db, message_row=c["message_row"], status="sent", message_id=mid)
        return c

    def test_only_an_accepted_proof_clears_removal_a_rejected_one_puts_it_back(self):
        self.note()
        self.assertEqual(self.due_ids(), ["r1"])
        verify_ledger.mark_tagged(self.db, message_id="500", conversation_id="9", attachments=1)
        self.assertEqual(self.due_ids(), [], "awaiting review: paused, not cleared")
        self.assertEqual(self.held(), [("r1", verify_ledger.HELD_AWAITING_REVIEW)])
        self.assertEqual(self.review(["r1"], "rejected")["result"], "ok")
        self.assertEqual(self.held(), [("r1", verify_ledger.HELD_NOT_TOLD)], "never removed before the user is told why")
        self.assertEqual(self.remind("reminder-25", "2026-11-10")["result"], "done",
                         "no 'we haven't received a document' reminder after a rejection")
        self.assertEqual([(m, k) for m, k, _ in verify_ledger.reminders_due(self.db, campaign="verify-live",
                                                                            day="2026-11-10")],
                         [("500", verify_ledger.AFTER_REJECTION)])
        self.assertEqual(verify_ledger.awaiting_proof(self.db), ["500"], "the sweep watches for a new attachment")
        c = self.tell("2026-11-10", ["r1"])
        self.assertEqual((c["due_day"], c["removal_day"]), ("2026-11-17", "2026-11-18"),
                         "the reply-by date is never earlier than 7 days after the after-rejection note")
        self.assertEqual(self.due_ids(day="2026-11-17"), [], "removal stays after the date we named")
        due = verify_ledger.removal_due(self.db, day="2026-11-18")
        self.assertEqual([(d["request_id"], d["removal_day"]) for d in due], [("r1", "2026-11-18")])
        self.assertEqual(self.remind(verify_ledger.AFTER_REJECTION, "2026-11-11")["result"], "done", "one per note")
        self.assertEqual(verify_ledger.message(self.db, "500")["proof_attachments"], 1)
        verify_ledger.mark_tagged(self.db, message_id="590", conversation_id="10", attachments=1)
        self.assertEqual(self.due_ids(), [], "a new document puts the rejected credit back under review")
        self.review(["r1"], "accepted", reviewer="U038BM16T7W")
        self.assertEqual((self.due_ids(), self.held()), ([], []))
        row = self.db.execute("SELECT outcome, reviewed_by FROM verify_proof_reviews WHERE request_id='r1'").fetchone()
        self.assertEqual(tuple(row), ("accepted", "U038BM16T7W"))

    def test_the_proof_review_is_per_credit(self):
        self.note(ids=("r1", "r2", "r3"))
        verify_ledger.mark_tagged(self.db, message_id="500", conversation_id="9", attachments=1)
        self.review(["r1"], "accepted")
        self.review(["r2"], "rejected", reason="other_track")
        self.assertEqual(self.held(), [("r2", verify_ledger.HELD_NOT_TOLD), ("r3", verify_ledger.HELD_AWAITING_REVIEW)],
                         "an unreviewed credit on a tagged note never vanishes from both exports")
        st = verify_ledger.reminder_state(self.db, parent_message_id="500", kind=verify_ledger.AFTER_REJECTION,
                                          day="2026-11-01")
        self.assertEqual((st["result"], st["request_ids"], st["reasons"]), ("due", ["r2"], {"r2": "other_track"}),
                         "told as soon as a credit is rejected, while r3 still awaits review")
        self.assertEqual(verify_ledger.awaiting_proof(self.db), ["500"],
                         "the tagged thread is still read for replies while r3 awaits review")
        self.tell("2026-11-01", ["r2"])
        self.assertEqual(verify_ledger.awaiting_proof(self.db), ["500", "590"],
                         "a reply to the after-rejection note is watched")
        self.assertEqual(self.due_ids(), ["r2"], "r1 verified, r3 still awaiting review")
        self.assertEqual(self.held(), [("r3", verify_ledger.HELD_AWAITING_REVIEW)])
        self.review(["r3"], "rejected")
        self.assertEqual(self.due_ids(), ["r2"], "r3 is never removed before the user is told about it")
        self.assertEqual(self.held(), [("r3", verify_ledger.HELD_NOT_TOLD)])
        self.assertEqual(verify_ledger.reminders_due(self.db, campaign="verify-live", day="2026-11-10")[0][1],
                         verify_ledger.AFTER_REJECTION, "no day-14 / day-25 reminder about a reviewed credit")

    def test_a_credit_rejected_after_the_first_after_rejection_note_gets_its_own(self):
        self.note(ids=("r1", "r2", "r3"), day="2026-10-01")
        verify_ledger.mark_tagged(self.db, message_id="500", conversation_id="9", attachments=1)
        self.review(["r1"], "accepted")
        self.review(["r2"], "rejected", reason="other_track")
        first = self.tell("2026-10-10", ["r2", "r3"])
        self.assertEqual((first["request_ids"], first["due_day"]), (["r2"], "2026-10-31"),
                         "only the rejected credit, by the note's own reply-by date")
        self.review(["r3"], "rejected", reason="unreadable")
        st = verify_ledger.reminder_state(self.db, parent_message_id="500", kind=verify_ledger.AFTER_REJECTION,
                                          day="2026-10-25")
        self.assertEqual((st["result"], st["request_ids"], st["reasons"], st["due_day"], st["removal_day"]),
                         ("due", ["r3"], {"r3": "unreadable"}, "2026-11-01", "2026-11-02"),
                         "a second after-rejection note for the newly rejected credit only")
        self.tell("2026-10-25", ["r2", "r3"], mid="591")
        self.assertEqual(self.db.execute("SELECT request_ids_json FROM verify_messages WHERE message_id='591'")
                         .fetchone()[0], '["r3"]')
        self.assertEqual(self.due_ids(day="2026-11-01"), ["r2"], "r3 waits for the date its own note named")
        self.assertEqual(self.due_ids(day="2026-11-02"), ["r2", "r3"])
        self.assertEqual(verify_ledger.reminder_state(self.db, parent_message_id="500", kind=verify_ledger.AFTER_REJECTION,
                                                      day="2026-10-26")["result"], "done",
                         "at most one after-rejection note per credit")

    def test_a_reply_after_the_after_rejection_note_holds_the_credit_until_a_new_review(self):
        self.note(day="2026-10-01")
        verify_ledger.mark_tagged(self.db, message_id="500", conversation_id="9", attachments=1)
        self.review(["r1"], "rejected")
        self.tell("2026-10-20", ["r1"])
        self.assertEqual(self.due_ids(day="2026-11-01"), ["r1"])
        later = lambda h: (datetime.now(timezone.utc) + timedelta(hours=h)).strftime("%Y-%m-%dT%H:%M:%SZ")  # noqa: E731
        self.assertEqual(verify_ledger.mark_replied(self.db, message_id="590", replied_at=later(1)), "recorded")
        self.assertEqual(verify_ledger.mark_replied(self.db, message_id="590", replied_at=later(1)), "already")
        self.assertEqual(self.due_ids(day="2026-11-01"), [], "removal waits for a human")
        self.assertEqual(self.held(day="2026-11-01"), [("r1", verify_ledger.HELD_REPLIED)])
        self.assertEqual(verify_ledger.mark_replied(self.db, message_id="590", replied_at=later(2)), "recorded",
                         "a later reply is seen too")
        verify_ledger.record_proof_review(self.db, message_id="500", request_ids=["r1"], outcome="rejected",
                                          reviewer="U038BM16T7W", reason="other_role",
                                          now=datetime.now(timezone.utc) + timedelta(hours=3))
        self.assertEqual(self.due_ids(day="2026-11-01"), ["r1"], "a human reviewed it again")
        self.assertEqual(verify_ledger.reminder_state(self.db, parent_message_id="500", kind=verify_ledger.AFTER_REJECTION,
                                                      day="2026-11-01")["result"], "done")
        with self.assertRaises(ValueError):
            verify_ledger.mark_replied(self.db, message_id="590", replied_at="yesterday")

    def test_a_reply_in_the_tagged_original_thread_after_an_after_rejection_note_holds_the_credit(self):
        self.note(ids=("r1", "r2", "r3"), day="2026-10-01")
        verify_ledger.mark_tagged(self.db, message_id="500", conversation_id="9", attachments=1)
        self.review(["r1"], "accepted")
        self.review(["r2"], "rejected", reason="other_track")
        self.tell("2026-10-10", ["r2"])
        self.assertEqual(verify_ledger.awaiting_proof(self.db), ["500", "590"],
                         "the tagged original thread is still read while r2 is rejected and r3 awaits review")
        self.assertEqual(self.due_ids(day="2026-11-01"), ["r2"])
        later = (datetime.now(timezone.utc) + timedelta(hours=1)).strftime("%Y-%m-%dT%H:%M:%SZ")
        self.assertEqual(verify_ledger.mark_replied(self.db, message_id="500", replied_at=later), "recorded")
        self.assertEqual(self.due_ids(day="2026-11-01"), [], "removal waits for a human")
        self.assertEqual(self.held(day="2026-11-01"),
                         [("r2", verify_ledger.HELD_REPLIED), ("r3", verify_ledger.HELD_AWAITING_REVIEW)])
        soon = datetime.now(timezone.utc) + timedelta(days=50)
        self.assertEqual(verify_ledger.awaiting_proof(self.db, now=soon), [], "the family sent nothing in 45 days")
        verify_ledger.record_proof_review(self.db, message_id="500", request_ids=["r3"], outcome="rejected",
                                          reviewer="x", reason="unreadable", now=soon - timedelta(days=11))
        c = verify_ledger.claim_reminder(self.db, parent_message_id="500", kind=verify_ledger.AFTER_REJECTION,
                                         user_key="a@x.com", day="2026-10-25", request_ids=["r3"],
                                         approved_by=CAPTAIN_UID, approval_ref="ref", now=soon - timedelta(days=10))
        verify_ledger.finalize(self.db, message_row=c["message_row"], status="sent", message_id="591")
        self.assertEqual(verify_ledger.awaiting_proof(self.db, now=soon), ["500", "590", "591"],
                         "every thread of the note is read while its latest after-rejection note is recent")

    def test_a_tagged_note_whose_credits_are_all_accepted_is_not_read_again(self):
        self.note(ids=("r1", "r2"))
        verify_ledger.mark_tagged(self.db, message_id="500", conversation_id="9", attachments=1)
        self.review(["r1"], "accepted")
        self.assertEqual(verify_ledger.awaiting_proof(self.db), ["500"])
        self.review(["r2"], "accepted")
        self.assertEqual(verify_ledger.awaiting_proof(self.db), [])
        self.note(ids=("p1",), mid="600", user="b@x.com", campaign="retro-past", windowed=False)
        verify_ledger.mark_tagged(self.db, message_id="600", conversation_id="8", attachments=1)
        self.assertEqual(verify_ledger.awaiting_proof(self.db), [], "a past note has no removal for a reply to hold")

    def test_a_rejection_after_a_reply_with_no_document_takes_no_reason(self):
        self.note(ids=("r1",), day="2026-10-01")
        verify_ledger.mark_replied(self.db, message_id="500")
        with self.assertRaises(ValueError):
            self.review(["r1"], "rejected", reason="not_a_document")
        self.assertEqual(self.review(["r1"], "rejected", reason="")["result"], "ok")
        st = verify_ledger.reminder_state(self.db, parent_message_id="500", kind=verify_ledger.AFTER_REJECTION,
                                          day="2026-10-20")
        self.assertEqual((st["received"], st["reasons"]), ({"r1": "reply"}, {"r1": ""}))

    def test_a_review_needs_a_tagged_proof_or_a_reply_a_reviewer_the_notes_credits_and_a_reason(self):
        self.note(ids=("r1", "r2"))
        self.assertEqual(self.review(["r1"], "accepted")["result"], "not_tagged")
        self.assertEqual(self.review(["r1"], "accepted", mid="999")["result"], "no_message")
        verify_ledger.mark_tagged(self.db, message_id="500", conversation_id="9")
        self.assertEqual(self.review(["r1", "zz"], "accepted"), {"result": "not_on_note", "request_ids": ["zz"]})
        self.assertEqual(self.db.execute("SELECT COUNT(*) FROM verify_proof_reviews").fetchone()[0], 0)
        for bad in (dict(ids=["r1"], outcome="maybe"), dict(ids=[], outcome="accepted"),
                    dict(ids=["r1"], outcome="accepted", reviewer=" "), dict(ids=["r1"], outcome="rejected", reason=""),
                    dict(ids=["r1"], outcome="rejected", reason="looks fake"),
                    dict(ids=["r1"], outcome="accepted", reason="unreadable")):
            with self.assertRaises(ValueError):
                self.review(**bad)
        self.assertEqual(self.db.execute("SELECT COUNT(*) FROM verify_proof_reviews").fetchone()[0], 0)

    def test_removal_due_only_after_the_reply_by_date_and_without_proof(self):
        self.note(ids=("r1", "r2"))
        self.note(ids=("r3",), mid="600", user="b@x.com")
        verify_ledger.mark_tagged(self.db, message_id="600", conversation_id="7")
        self.assertEqual(verify_ledger.removal_due(self.db, day="2026-11-15"), [],
                         "a reply on the reply-by date is never already in the export")
        due = verify_ledger.removal_due(self.db, day="2026-11-16")
        self.assertEqual([d["request_id"] for d in due], ["r1", "r2"])
        self.assertEqual((due[0]["due_day"], due[0]["removal_day"], due[0]["campaign"], due[0]["track_id"]),
                         ("2026-11-15", "2026-11-16", "verify-live", "t1"))
        self.assertEqual(due[0]["reason"], "no valid verification within 30 days")

    def test_any_user_reply_holds_the_removal_for_a_human(self):
        self.note(ids=("r1", "r2"))
        r = self.remind("reminder-14", "2026-10-30")
        verify_ledger.finalize(self.db, message_row=r["message_row"], status="sent", message_id="501")
        self.assertEqual(verify_ledger.mark_replied(self.db, message_id="501"), "recorded")
        self.assertEqual(verify_ledger.mark_replied(self.db, message_id="501"), "already")
        self.assertEqual(self.due_ids(), [], "held, not removal-due")
        self.assertEqual(self.held(), [("r1", verify_ledger.HELD_REPLIED), ("r2", verify_ledger.HELD_REPLIED)])
        self.assertEqual(self.held(day="2026-11-15"), [], "only past the reply-by date")
        self.assertEqual(self.review(["r2"], "rejected", reviewer="U038BM16T7W", reason="")["result"], "ok",
                         "a human picks the reply up")
        self.tell("2026-11-01", ["r2"])
        self.assertEqual(self.due_ids(), ["r2"])
        self.assertEqual(self.held(), [("r1", verify_ledger.HELD_REPLIED)])

    def test_a_reply_to_a_note_with_no_removal_date_holds_nothing(self):
        self.note(campaign="retro-past", windowed=False)
        self.assertEqual(verify_ledger.mark_replied(self.db, message_id="500"), "not_applicable")
        self.assertEqual(verify_ledger.mark_replied(self.db, message_id="999"), "no_message")

    def test_skipped_rows_are_never_offered_again(self):
        self.assertEqual(verify_ledger.skip_requests(self.db, campaign="retro-past", request_ids=["r1", "r1"]), 1)
        self.assertEqual(verify_ledger.blocked_ids(self.db, ["r1"], "retro-past"), {"r1"})


class CandidateTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.path = os.path.join(self.tmp, "ledger.sqlite3")
        self.dbs = []

    def tearDown(self):
        for db in self.dbs:
            db.close()
        shutil.rmtree(self.tmp)

    def open(self):
        db = verify_ledger.connect(self.path)
        self.dbs.append(db)
        return db

    def test_no_decisions_table_means_nothing_to_do(self):
        db = self.open()
        self.assertEqual(verify_notify.candidates(db), [])

    def test_a_decisions_table_without_the_contract_columns_fails_loud(self):
        decisions_db(self.path, [], schema="CREATE TABLE decisions (request_id TEXT, decision TEXT);"
                                           "CREATE TABLE decision_outcomes (request_id TEXT, outcome TEXT);")
        with self.assertRaises(ContractError):
            verify_notify.candidates(self.open())

    def test_only_server_approved_outcomes_not_yet_notified(self):
        decisions_db(self.path, [dec("r1"), dec("r2", "skipped:needs_human_review"),
                                 dec("r3", "user_verification_needed", action="support"),
                                 dec("r6", "approved", action="revert"),
                                 dec("r4", run="run-2"), dec("r5")])
        db = self.open()
        c = verify_ledger.claim(db, user_key="a@x.com", day="d", request_ids=["r5"], message_type="email",
                                approved_by=CAPTAIN_UID, approval_ref="ref")
        verify_ledger.finalize(db, message_row=c["message_row"], status="sent", message_id="1")
        self.assertEqual([r for r, _, _ in verify_notify.candidates(db)], ["r1", "r4"])
        self.assertEqual([r for r, _, _ in verify_notify.candidates(db, run_id="run-2")], ["r4"])

    def test_since_hours_uses_the_outcome_time(self):
        decisions_db(self.path, [dec("old", at="2026-10-01T00:00:00Z"), dec("new", at="2026-10-15T22:00:00Z")])
        db = self.open()
        now = datetime(2026, 10, 15, 23, tzinfo=timezone.utc)
        self.assertEqual([r for r, _, _ in verify_notify.candidates(db, since_hours=24, now=now)], ["new"])


class RereadAndPlanTests(unittest.TestCase):
    def test_reread_announces_only_rows_the_server_says_are_approved_now(self):
        admin = FakeAdmin([req("r1"), req("r2", status="user_verification_needed"), req("r3", pid=PID2)])
        found, missing = verify_notify.reread(admin, [("r1", PID, "t1"), ("r2", PID, "t1"), ("r3", PID2, "t1")])
        self.assertEqual(set(found), {"r1", "r3"})
        self.assertEqual(missing, {"r2"})
        self.assertTrue(all(p == "/admin/credit-requests" for p, _ in admin.calls))

    def test_reread_pages_then_falls_back_to_the_track(self):
        rows = [req(f"x{i}", track=f"t{i}") for i in range(verify_notify.PAGE_LIMIT * verify_notify.MAX_PAGES)]
        rows.append(req("deep", track="tdeep"))
        admin = FakeAdmin(rows)
        found, missing = verify_notify.reread(admin, [("deep", PID, "tdeep")])
        self.assertEqual(set(found), {"deep"})
        self.assertEqual(admin.calls[-1][1].get("trackId"), "tdeep")

    def test_plan_groups_by_account_email_with_roles_joined(self):
        rep = Report()
        rows = {"r1": req("r1", email="Jane@Example.com", created="2026-10-15T01:00:00Z"),
                "r2": req("r2", roles=("Producer", "Mixing", "Mastering"), created="2026-10-15T00:00:00Z"),
                "r3": req("r3", email="bob@example.com", name=""),
                "r4": req("r4", email=None)}
        payloads = verify_notify.plan(rows, rep)
        self.assertEqual(rep.no_account, 1)
        by = {p["user"]["email"]: p for p in payloads}
        self.assertEqual(set(by), {"jane@example.com", "bob@example.com"})
        self.assertEqual([c["request_id"] for c in by["jane@example.com"]["credits"]], ["r2", "r1"])
        self.assertEqual(by["jane@example.com"]["credits"][0]["role"], "Producer, Mixing and Mastering")
        self.assertEqual(by["jane@example.com"]["user"]["first_name"], "Jane")
        self.assertEqual(by["bob@example.com"]["user"]["first_name"], "")


class RunTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.path = os.path.join(self.tmp, "ledger.sqlite3")

    def tearDown(self):
        shutil.rmtree(self.tmp)

    def test_apply_calls_the_gate_once_per_account_with_the_captains_approval(self):
        decisions_db(self.path, [dec("r1"), dec("r2"), dec("r3", pid=PID2)])
        admin = FakeAdmin([req("r1"), req("r2"), req("r3", pid=PID2, email="bob@example.com")])
        fake = Fake()
        rep = verify_notify.run(admin, ledger_path=self.path, mode="apply", runner=fake, wrapper="/w")
        sends = [a for a in fake.argv if a[1] == "send"]
        self.assertEqual(len(sends), 2)
        for a in sends:
            self.assertEqual(a[0], "/w")
            self.assertEqual(a[a.index("--approved-by") + 1], CAPTAIN_UID)
            self.assertNotIn("--validate", a)
            self.assertFalse(any("@" in x for x in a), "the account email must not be on argv")
            self.assertFalse(os.path.exists(a[a.index("--credits-file") + 1]), "temp payload file is removed")
        self.assertEqual((rep.sent_notes, rep.sent_credits), (2, 3))
        self.assertTrue(rep.render("apply").startswith("VERIFY NOTES: 2 note(s) sent covering 3 provisionally approved credit(s)."))

    def test_dry_run_only_validates(self):
        decisions_db(self.path, [dec("r1")])
        fake = Fake({"jane@example.com": (0, "VALID email credits=1", "")})
        rep = verify_notify.run(FakeAdmin([req("r1")]), ledger_path=self.path, mode="dry-run", runner=fake, wrapper="/w")
        self.assertIn("--validate", fake.argv[0])
        self.assertEqual([a[1] for a in fake.argv], ["send"])  # no proof sweep in a dry run
        self.assertIn("would get a note", rep.render("dry-run"))

    def test_gate_outcomes_are_counted_and_only_failures_fail_the_run(self):
        decisions_db(self.path, [dec("r1"), dec("r2", pid=PID2), dec("r3", pid=PID2, track="t3")])
        admin = FakeAdmin([req("r1"), req("r2", pid=PID2, email="b@example.com"),
                           req("r3", pid=PID2, email="c@example.com", track="t3")])
        fake = Fake({"jane@example.com": (3, "DEFERRED daily-cap credits=1", ""),
                     "b@example.com": (1, "", "REFUSED: the account email matches 0 Intercom users (need exactly 1); not sending."),
                     "c@example.com": (4, "", "POST FAILED (curl rc=28)")})
        rep = verify_notify.run(admin, ledger_path=self.path, mode="apply", runner=fake, wrapper="/w")
        self.assertEqual((rep.deferred_users, rep.refused_users, rep.failed_users), (1, 1, 1))
        self.assertTrue(rep.failed)
        self.assertIn("matches 0 Intercom users", rep.render("apply"))

    def test_deferred_accounts_alone_are_not_announced(self):
        decisions_db(self.path, [dec("r1")])
        fake = Fake({"jane@example.com": (3, "DEFERRED daily-cap credits=1", "")})
        rep = verify_notify.run(FakeAdmin([req("r1")]), ledger_path=self.path, mode="apply", runner=fake, wrapper="/w")
        self.assertEqual(rep.deferred_users, 1)
        self.assertEqual(rep.render("apply"), "NO_REPLY")
        self.assertFalse(rep.failed)

    def test_quiet_run_is_no_reply(self):
        rep = verify_notify.run(FakeAdmin([]), ledger_path=self.path, mode="apply", runner=Fake(), wrapper="/w")
        self.assertEqual(rep.render("apply"), "NO_REPLY")
        self.assertFalse(rep.failed)

    def test_proof_sweep_tags_only_sent_untagged_notes(self):
        db = verify_ledger.connect(self.path)
        kw = dict(message_type="email", approved_by=CAPTAIN_UID, approval_ref="ref")
        for i, status in enumerate(("sent", "attempted", "sent")):
            c = verify_ledger.claim(db, user_key=f"u{i}@x.com", day="2026-10-15", request_ids=[f"r{i}"], **kw)
            verify_ledger.finalize(db, message_row=c["message_row"], status=status, message_id=f"{100 + i}")
        verify_ledger.mark_tagged(db, message_id="102", conversation_id="5")
        db.close()
        fake = Fake({"100": (0, "TAGGED credit-proof conversation=5 message=100 attachments=1", "")})
        rep = verify_notify.run(FakeAdmin([]), ledger_path=self.path, mode="apply", runner=fake, wrapper="/w")
        self.assertEqual(fake.argv, [["/w", "tag-proof", "--message-id", "100"]])
        self.assertEqual(rep.proof_tagged, 1)

    def test_a_recorded_user_reply_is_reported_for_a_human(self):
        db = verify_ledger.connect(self.path)
        c = verify_ledger.claim(db, user_key="u@x.com", day="2026-10-15", request_ids=["r1"], message_type="email",
                                approved_by=CAPTAIN_UID, approval_ref="ref", windowed=True)
        verify_ledger.finalize(db, message_row=c["message_row"], status="sent", message_id="100")
        db.close()
        fake = Fake({"100": (3, "REPLY RECORDED message=100 conversation=5 (removal held for a human)\n"
                                "NO PROOF YET message=100 conversation=5", "")})
        rep = verify_notify.run(FakeAdmin([]), ledger_path=self.path, mode="apply", runner=fake, wrapper="/w")
        self.assertEqual((rep.extension_requests, rep.proof_tagged, rep.proof_failed), (1, 0, 0))
        self.assertIn("1 user repl(ies) to a note recorded", rep.render("apply"))

    def test_a_credit_awaiting_review_past_its_date_is_counted_as_held_for_a_human(self):
        db = verify_ledger.connect(self.path)
        c = verify_ledger.claim(db, user_key="u@x.com", day="2020-01-01", request_ids=["r1", "r2"],
                                message_type="email", approved_by=CAPTAIN_UID, approval_ref="ref", windowed=True)
        verify_ledger.finalize(db, message_row=c["message_row"], status="sent", message_id="100")
        verify_ledger.mark_tagged(db, message_id="100", conversation_id="5", attachments=1)
        verify_ledger.record_proof_review(db, message_id="100", request_ids=["r1"], outcome="accepted", reviewer="x")
        db.close()
        rep = verify_notify.run(FakeAdmin([]), ledger_path=self.path, mode="apply", runner=Fake(), wrapper="/w",
                                sweep=False)
        self.assertEqual((rep.removal_due, rep.held_for_human), (0, 1))

    def test_a_rejected_credit_gets_the_after_rejection_follow_up(self):
        db = verify_ledger.connect(self.path)
        self.addCleanup(db.close)
        c = windowed_note(db)
        verify_ledger.finalize(db, message_row=c["message_row"], status="sent", message_id="500")
        verify_ledger.mark_tagged(db, message_id="500", conversation_id="5", attachments=1)
        verify_ledger.record_proof_review(db, message_id="500", request_ids=["r1"], outcome="rejected", reviewer="x",
                                          reason="other_role")
        fake, rep = Fake(), Report()
        verify_notify.send_followups(db, FakeAdmin([req("r1", track="t1"), req("r2", track="t2")]), rep, verdicts=verify_notify.affiliation.read(AFFILIATION_FILE),
                                     campaign="verify-live", day="2026-10-20",
                                     documented=verify_notify.load_proof_on_file(PROOF_FILE), limit=150,
                                     pace_seconds=0, wrapper="/w", runner=fake)
        self.assertEqual([[c["request_id"] for c in p["credits"]] for p in fake.payloads], [["r1"]])
        argv = fake.argv[0]
        self.assertEqual(argv[argv.index("--kind") + 1], verify_ledger.AFTER_REJECTION)
        self.assertEqual(rep.reminders_sent, 1)


WAVE_HEADER = "tier,credit_request_id,user_id,profile_id,track_id,role,pop_now,paid,claim_date\n"


def wave_file(path, lines):
    Path(path).write_text(WAVE_HEADER + "".join(",".join(map(str, row)) + "\n" for row in lines))


class WaveTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.path = os.path.join(self.tmp, "ledger.sqlite3")
        self.wave = os.path.join(self.tmp, "wave.csv")

    def tearDown(self):
        shutil.rmtree(self.tmp)

    def test_load_merges_role_rows_and_applies_the_exclusion_file(self):
        wave_file(self.wave, [("HOLD", "r1", "7", PID, "t1", "Mixing", 20, 0, "2026-09-02"),
                              ("HOLD", "r1", "7", PID, "t1", "Mastering", 70, 0, "2026-09-02"),
                              ("HOLD", "r2", "900", PID, "t2", "Producer", 10, 1, "2026-09-03")])
        excl = os.path.join(self.tmp, "exclude.txt")
        Path(excl).write_text("# accounts handled elsewhere\n900  # existing credits stay\n\n")
        rep = Report()
        rows = verify_notify.load_wave(self.wave, exclude=verify_notify.load_exclusions(excl), report=rep)
        self.assertEqual([(w.request_id, w.pop) for w in rows], [("r1", 70)])
        self.assertEqual(rep.excluded, 1)
        self.assertEqual(verify_notify.load_exclusions(None), frozenset())

    def test_a_wave_file_without_the_contract_columns_fails_loud(self):
        Path(self.wave).write_text("credit_request_id,profile_id\nr1,p\n")
        with self.assertRaises(ContractError):
            verify_notify.load_wave(self.wave)

    def test_order_is_paid_first_then_big_tracks_then_oldest(self):
        W = verify_notify.WaveRow
        rows = [W("a", "free-small", PID, pop=10, claimed="2026-09-01"),
                W("b", "free-big", PID, pop=75, claimed="2026-09-20"),
                W("c", "paid-small", PID, pop=5, paid=True, claimed="2026-09-30"),
                W("d", "free-small-older", PID, pop=1, claimed="2026-08-30")]
        self.assertEqual(verify_notify.wave_order(rows), ["paid-small", "free-big", "free-small-older", "free-small"])

    def test_doc_families_map_roles_to_the_gates_document_lists(self):
        self.assertEqual(verify_notify.doc_families(["Mixing", "Mastering", "Producer"]), ["mix_master", "producer"])
        self.assertEqual(verify_notify.doc_families(["Composer"]), ["writer"])
        self.assertEqual(verify_notify.doc_families(["Guitar"]), ["musician"])
        self.assertEqual(verify_notify.doc_families(["Label"]), ["studio_org"])
        self.assertEqual(verify_notify.doc_families(["Studio", "Recording Studio", "Publisher"]), ["studio_org"])
        self.assertEqual(verify_notify.doc_families(["A&R"]), ["anr"])
        self.assertEqual(verify_notify.doc_families(["Studio Manager"]), ["engineer"])

    def test_run_wave_sends_retro_notes_within_budget_and_skips_rows_no_longer_live(self):
        wave_file(self.wave, [("HOLD", "r1", "1", PID, "t1", "Mixing", 10, 0, "2026-09-02"),
                              ("HOLD", "r2", "1", PID, "t2", "Producer", 80, 0, "2026-09-05"),
                              ("HOLD", "r3", "2", PID2, "t3", "Mixing", 10, 1, "2026-09-09"),
                              ("HOLD", "r4", "3", PID2, "t4", "Mixing", 10, 0, "2026-09-01")])
        admin = FakeAdmin([req("r1", track="t1"), req("r2", track="t2", title="Big Song", roles=("Producer",)),
                           req("r3", pid=PID2, email="paid@example.com", track="t3"),
                           req("r4", pid=PID2, email="gone@example.com", track="t4", status="rejected")])
        fake = Fake()
        rep = verify_notify.run_wave(admin, wave_path=self.wave, ledger_path=self.path, mode="apply", max_users=2,
                                     pace_seconds=0, runner=fake, wrapper="/w", today="2026-10-16")
        sends = [a for a in fake.argv if a[1] == "send"]
        # Budget 2: the paid user, then user 1 (big track); user 3 is not reached this run.
        self.assertEqual([fake.payloads[i]["user"]["email"] for i in range(len(sends))], ["paid@example.com", "jane@example.com"])
        for a in sends:
            self.assertEqual(a[a.index("--campaign") + 1], "retro-past")
        jane = fake.payloads[1]
        self.assertEqual([c["request_id"] for c in jane["credits"]], ["r2", "r1"], "big tracks first")
        self.assertEqual(jane["credits"][0]["role_families"], ["producer"])
        self.assertEqual(jane["credits"][0]["track_id"], "t2")
        self.assertEqual(rep.sent_notes, 2)
        # A run that reaches user 3: the row is not approved any more -> closed as skipped, never announced.
        rep2 = verify_notify.run_wave(admin, wave_path=self.wave, ledger_path=self.path, mode="apply", max_users=10,
                                      pace_seconds=0, runner=Fake(), wrapper="/w", today="2026-10-16")
        self.assertEqual(rep2.skipped_not_live, 1)
        db = verify_ledger.connect(self.path)
        self.addCleanup(db.close)
        self.assertEqual(verify_ledger.blocked_ids(db, ["r4"], "retro-past"), {"r4"})

    def test_run_wave_respects_the_daily_note_budget(self):
        wave_file(self.wave, [("HOLD", f"r{i}", str(i), PID, f"t{i}", "Mixing", 10, 0, "2026-09-02") for i in range(3)])
        db = verify_ledger.connect(self.path)
        c = verify_ledger.claim(db, user_key="x@x.com", day="2026-10-16", request_ids=["old"], campaign="retro-past",
                                message_type="email", approved_by=CAPTAIN_UID, approval_ref="ref")
        verify_ledger.finalize(db, message_row=c["message_row"], status="sent", message_id="1")
        db.close()
        admin = FakeAdmin([req(f"r{i}", track=f"t{i}", email=f"u{i}@example.com") for i in range(3)])
        fake = Fake()
        verify_notify.run_wave(admin, wave_path=self.wave, ledger_path=self.path, mode="apply", max_users=10,
                               daily_max_notes=2, pace_seconds=0, runner=fake, wrapper="/w", today="2026-10-16")
        self.assertEqual(len([a for a in fake.argv if a[1] == "send"]), 1)

    def test_human_approved_requests_are_never_asked_about_and_closed(self):
        wave_file(self.wave, [("HOLD", "r1", "1", PID, "t1", "Mixing", 10, 0, "2026-09-02"),
                              ("HOLD", "r2", "1", PID, "t2", "Mixing", 10, 0, "2026-09-03")])
        human = req("r2", track="t2")
        human["metadata"] = {"approval": {"via": "admin", "isAgent": False}}
        agent = req("r1", track="t1")
        agent["metadata"] = {"approval": {"via": "batch", "isAgent": True}}
        fake = Fake()
        rep = verify_notify.run_wave(FakeAdmin([agent, human]), wave_path=self.wave, ledger_path=self.path,
                                     mode="apply", pace_seconds=0, runner=fake, wrapper="/w", today="2026-10-16")
        self.assertEqual([c["request_id"] for c in fake.payloads[0]["credits"]], ["r1"])
        self.assertEqual(rep.human_approved, 1)
        db = verify_ledger.connect(self.path)
        self.addCleanup(db.close)
        self.assertEqual(verify_ledger.blocked_ids(db, ["r2"], "retro-past"), {"r2"})

    def test_unplannable_requests_are_closed_so_they_never_take_a_slot_again(self):
        wave_file(self.wave, [("HOLD", "r1", "1", PID, "t1", "Mixing", 10, 1, "2026-09-02"),
                              ("HOLD", "r2", "2", PID2, "t2", "Mixing", 10, 0, "2026-09-03")])
        noartist = req("r1", track="t1")
        noartist["spotifyTrackArtists"] = []
        admin = FakeAdmin([noartist, req("r2", pid=PID2, track="t2", email="bob@example.com")])
        verify_notify.run_wave(admin, wave_path=self.wave, ledger_path=self.path, mode="apply", max_users=1,
                               pace_seconds=0, runner=Fake(), wrapper="/w", today="2026-10-16")
        fake = Fake()
        verify_notify.run_wave(admin, wave_path=self.wave, ledger_path=self.path, mode="apply", max_users=1,
                               pace_seconds=0, runner=fake, wrapper="/w", today="2026-10-16")
        self.assertEqual([p["user"]["email"] for p in fake.payloads], ["bob@example.com"])

    def test_audit_docs_counts_accounts_that_already_sent_documents_read_only(self):
        wave_file(self.wave, [("HOLD", "r1", "1", PID, "t1", "Mixing", 10, 0, "2026-09-02"),
                              ("HOLD", "r2", "2", PID2, "t2", "Mixing", 10, 0, "2026-09-03")])
        admin = FakeAdmin([req("r1", track="t1"), req("r2", pid=PID2, track="t2", email="bob@example.com")])

        class DocFake(Fake):
            def __call__(self, argv):
                self.argv.append(argv)
                payload = json.loads(Path(argv[argv.index("--credits-file") + 1]).read_text())
                docs = payload["user"]["email"] == "bob@example.com"
                return subprocess.CompletedProcess(argv, 0, ("DOCS the user attached a document" if docs else "NO_DOCS") + "\n", "")
        fake = DocFake()
        out = os.path.join(self.tmp, "audit.csv")
        rep = verify_notify.run_wave(admin, wave_path=self.wave, ledger_path=self.path, mode="dry-run", runner=fake,
                                     wrapper="/w", audit_docs=out)
        self.assertTrue(all("--doc-check" in a for a in fake.argv))
        self.assertEqual((rep.docs_checked, rep.docs_users), (2, 1))
        rows = Path(out).read_text()
        self.assertNotIn("@", rows)
        self.assertIn("docs", rows)
        self.assertEqual(stat.S_IMODE(os.stat(out).st_mode), 0o600)

    def test_users_with_documents_on_file_are_never_asked_and_take_no_slot(self):
        wave_file(self.wave, [("HOLD", "r1", "1", PID, "t1", "Mixing", 10, 1, "2026-09-02"),
                              ("HOLD", "r2", "2", PID2, "t2", "Mixing", 10, 0, "2026-09-03")])
        proof = os.path.join(self.tmp, "proof.json")
        write_proof(proof, [{"user_id": 1, "request_id": None, "kind": "approved_doc", "source": "core", "ref": "v1"}])
        admin = FakeAdmin([req("r1", track="t1"), req("r2", pid=PID2, track="t2", email="bob@example.com")])
        fake = Fake()
        rep = verify_notify.run_wave(admin, wave_path=self.wave, ledger_path=self.path, mode="apply", max_users=1,
                                     pace_seconds=0, runner=fake, wrapper="/w", today="2026-10-16", proof_path=proof)
        self.assertEqual([p["user"]["email"] for p in fake.payloads], ["bob@example.com"])
        self.assertEqual(rep.proof_on_file, 1)
        db = verify_ledger.connect(self.path)
        self.addCleanup(db.close)
        self.assertEqual(verify_ledger.blocked_ids(db, ["r1"], "retro-past"), {"r1"})

    def test_a_missing_or_stale_proof_list_sends_zero_asks_and_fails_loud(self):
        wave_file(self.wave, [("HOLD", "r1", "1", PID, "t1", "Mixing", 10, 0, "2026-09-02")])
        stale = os.path.join(self.tmp, "stale.json")
        write_proof(stale, age_h=3.5)
        future = os.path.join(self.tmp, "future.json")
        write_proof(future, age_h=-24)
        future_part = os.path.join(self.tmp, "future-part.json")
        d = proof_doc()
        d["sources"][0]["generated_at"] = (datetime.now(timezone.utc) + timedelta(hours=24)).strftime("%Y-%m-%dT%H:%M:%SZ")
        Path(future_part).write_text(json.dumps(d))
        for path, why in ((os.path.join(self.tmp, "absent.json"), "missing"), (stale, "3.5h old"),
                          (future, "in the future"), (future_part, "part 'core' is dated 24.0h in the future")):
            fake = Fake()
            rep = verify_notify.run_wave(FakeAdmin([req("r1")]), wave_path=self.wave, ledger_path=self.path,
                                         mode="apply", pace_seconds=0, runner=fake, wrapper="/w", proof_path=path)
            self.assertEqual(fake.argv, [])
            self.assertTrue(rep.failed)
            self.assertIn(why, rep.render("apply"))
            self.assertIn("NO asks sent this run", rep.render("apply"))
        part = os.path.join(self.tmp, "part.json")
        gen = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        doc = proof_doc(generated_at=gen)
        doc["sources"].append({"name": "gmail", "missing": True})
        Path(part).write_text(json.dumps(doc))
        rep = verify_notify.run_wave(FakeAdmin([req("r1")]), wave_path=self.wave, ledger_path=self.path,
                                     mode="apply", pace_seconds=0, runner=Fake(), wrapper="/w", proof_path=part)
        self.assertIn("stale or missing part(s): gmail", rep.render("apply"))
        # The LIVE export's shape (cs lane, firstmate 032): parts "core" (no stale key: its
        # generated_at is its freshness), "cs-intercom" and "cs-gmail", extra fields (detail,
        # coverage), entry sources "intercom" / "core.verifications.netverify". It is
        # accepted; the same file with the Intercom part renamed (e.g. to "intercom") is
        # UNKNOWN and sends nothing.
        live = {"generated_at": gen,
                "sources": [{"name": "core", "generated_at": gen, "count": 2,
                             "detail": {"verifications": 1, "admin_approvals": 1}},
                            {"name": "cs-intercom", "generated_at": gen, "stale": False, "count": 1,
                             "coverage": "Intercom conversations 2021-01 onward"},
                            {"name": "cs-gmail", "generated_at": gen, "stale": False, "count": 0}],
                "users": 2,
                "entries": [{"user_id": 900, "request_id": None, "kind": "pending_doc", "source": "intercom",
                             "ref": "c1"},
                            {"user_id": 901, "request_id": None, "kind": "approved_doc",
                             "source": "core.verifications.netverify", "ref": "v1"}],
                "gmail_contacts_90d": {"generated_at": gen, "source": "support@ inbound, 90 days", "user_ids": [902]}}
        Path(part).write_text(json.dumps(live))
        self.assertEqual(set(verify_notify.load_proof_on_file(part)), {"900", "901"})
        renamed = json.loads(json.dumps(live))
        renamed["sources"][1]["name"] = "intercom"
        Path(part).write_text(json.dumps(renamed))
        fake = Fake()
        rep = verify_notify.run_wave(FakeAdmin([req("r1")]), wave_path=self.wave, ledger_path=self.path,
                                     mode="apply", pace_seconds=0, runner=fake, wrapper="/w", proof_path=part)
        self.assertEqual(fake.argv, [])
        self.assertIn("part 'cs-intercom' is missing", rep.render("apply"))
        # The legacy merged label is read as the Intercom part only: it never vouches for Gmail.
        legacy = json.loads(json.dumps(live))
        legacy["sources"] = [legacy["sources"][0], {**legacy["sources"][1], "name": "cs-systemic intercom+gmail"}]
        Path(part).write_text(json.dumps(legacy))
        with self.assertRaisesRegex(verify_notify.ProofFileError, "part 'cs-gmail' is missing"):
            verify_notify.load_proof_on_file(part)
        legacy["sources"].append(live["sources"][2])
        Path(part).write_text(json.dumps(legacy))
        self.assertEqual(sorted(verify_notify.load_proof_on_file(part)), ["900", "901"])
        # Only that exact legacy label: any other cs-systemic* name is not the Intercom part.
        for name in ("cs-systemic", "cs-systemic gmail", "cs-systemic intercom+gmail v2"):
            other = json.loads(json.dumps(live))
            other["sources"][1]["name"] = name
            Path(part).write_text(json.dumps(other))
            with self.assertRaisesRegex(verify_notify.ProofFileError, "part 'cs-intercom' is missing"):
                verify_notify.load_proof_on_file(part)
        # Any truthy stale/missing flag makes a part unusable, not only the boolean true.
        for flag in ({"stale": "true"}, {"stale": 1}, {"missing": "yes"}):
            flagged = json.loads(json.dumps(live))
            flagged["sources"][1].update(flag)
            Path(part).write_text(json.dumps(flagged))
            with self.assertRaisesRegex(verify_notify.ProofFileError, "part 'cs-intercom' is marked"):
                verify_notify.load_proof_on_file(part)
        # F1: a half-written export (header only: no sources, or an empty list, or a required
        # part absent, or users not matching entries) is never authoritative.
        half = [{"generated_at": gen, "entries": []},
                {"generated_at": gen, "sources": [], "users": 0, "entries": []},
                {**proof_doc(generated_at=gen), "sources": [{"name": "core", "generated_at": gen}]},
                {**proof_doc(generated_at=gen), "users": 5},
                # A malformed row (QA review) may be the one documented user: never skipped.
                {**proof_doc(generated_at=gen), "entries": [None]},
                {**proof_doc([{"user_id": 42, "request_id": "r1", "kind": "pending_doc"}], generated_at=gen),
                 "entries": [{"user_id": 42, "request_id": "r1", "kind": "pending_doc"}, {"kind": "approved_doc"}]},
                {**proof_doc([{"user_id": 42, "request_id": "r1", "kind": "documented"}], generated_at=gen)}]
        for d in half:
            Path(part).write_text(json.dumps(d))
            fake = Fake()
            rep = verify_notify.run_wave(FakeAdmin([req("r1")]), wave_path=self.wave, ledger_path=self.path,
                                         mode="apply", pace_seconds=0, runner=fake, wrapper="/w", proof_path=part)
            self.assertEqual(fake.argv, [], d)
            self.assertIn("NO asks sent this run", rep.render("apply"))
        decisions_db(self.path, [dec("r1")])
        fake = Fake()
        rep = verify_notify.run(FakeAdmin([req("r1")]), ledger_path=self.path, mode="apply", runner=fake, wrapper="/w",
                                proof_path=os.path.join(self.tmp, "absent.json"))
        self.assertEqual((fake.argv, rep.failed), ([], True))

    def test_gmail_part_unusable_asks_nobody(self):
        """cs-gmail missing, stale or old: anyone may have emailed a document to support@
        after any snapshot of who wrote in, so the list is UNKNOWN for everyone: zero asks,
        non-zero exit, in both campaigns. A contact list in the export does not narrow it."""
        decisions_db(self.path, [dec("r1"), dec("r2", track="t2")])
        wave_file(self.wave, [("HOLD", "r1", "42", PID, "t1", "Mixing", 10, 0, "2026-09-02")])
        other = req("r2", track="t2", email="sam@example.com", name="Sam Roe")
        other["user"]["id"] = "43"
        gen = _ago(0)
        proof = os.path.join(self.tmp, "proof.json")
        for gmail in ([], [{"name": "cs-gmail", "generated_at": gen, "stale": True}],
                      [{"name": "cs-gmail", "generated_at": _ago(5), "stale": False}]):
            d = proof_doc(generated_at=gen)
            d["sources"] = d["sources"][:2] + gmail
            Path(proof).write_text(json.dumps({**d, "gmail_contacts_90d": {
                "generated_at": gen, "source": "gmail support@ inbox, 90 days", "user_ids": [42]}}))
            for mode in ("dry-run", "apply"):
                fake = Fake()
                rep = verify_notify.run(FakeAdmin([req("r1"), other]), ledger_path=self.path,
                                        mode=mode, runner=fake, wrapper="/w", proof_path=proof, sweep=False)
                self.assertEqual((fake.argv, rep.failed), ([], True), gmail)
                self.assertIn("part 'cs-gmail'", rep.render(mode))
                fake = Fake()
                rep = verify_notify.run_wave(FakeAdmin([req("r1")]), wave_path=self.wave, ledger_path=self.path,
                                             mode=mode, pace_seconds=0, runner=fake, wrapper="/w", proof_path=proof)
                self.assertEqual((fake.argv, rep.failed), ([], True), gmail)
            with self.assertRaisesRegex(verify_notify.ProofFileError, "part 'cs-gmail'"):
                verify_notify.load_proof_on_file(proof)

    def test_new_credits_any_proof_on_file_holds_the_user(self):
        decisions_db(self.path, [dec("r1"), dec("r2", track="t2"), dec("r3", track="t3")])
        proof = os.path.join(self.tmp, "proof.json")
        write_proof(proof, [{"user_id": 42, "request_id": "r1", "kind": "approved_doc", "source": "core", "ref": "x"},
                            {"user_id": 42, "request_id": "old", "kind": "human_approved_after_doc", "source": "core",
                             "ref": "y"},
                            {"user_id": 42, "request_id": None, "kind": "approved_doc", "source": "id", "ref": "z"}])
        human = req("r3", track="t3")
        human["metadata"] = {"approval": {"isAgent": False}}
        fake = Fake()
        rep = verify_notify.run(FakeAdmin([req("r1"), req("r2", track="t2"), human]), ledger_path=self.path,
                                mode="apply", runner=fake, wrapper="/w", proof_path=proof, sweep=False)
        # Fable 2026-10-17 precondition 1: proof on file from ANY source means no note at all.
        # The credit with its own document and the human-approved one are closed; r2 waits
        # for a human (held, not closed).
        self.assertEqual(fake.payloads, [])
        self.assertEqual((rep.proof_on_file, rep.human_approved, rep.pending_doc_users, rep.documented_users,
                          rep.documented_credits), (1, 1, 0, 1, 1))
        self.assertIn("held for a human: documents already on file", rep.render("apply"))
        db = verify_ledger.connect(self.path)
        self.addCleanup(db.close)
        self.assertEqual(verify_ledger.blocked_ids(db, ["r1", "r2", "r3"]), {"r1", "r3"})
        self.assertEqual(verify_ledger.deferred(db), [("r2", PID, "t2")])

    def test_a_pending_document_on_another_credit_defers_the_user_then_one_ask_after_review(self):
        decisions_db(self.path, [dec("r1"), dec("r2", track="t2"), dec("r3", pid=PID2)])
        bob = req("r3", pid=PID2, email="bob@example.com")
        bob["user"]["id"] = "77"
        admin = FakeAdmin([req("r1"), req("r2", track="t2"), bob])
        proof = os.path.join(self.tmp, "proof.json")
        for entry in ({"user_id": 42, "request_id": "older", "kind": "pending_doc", "source": "core", "ref": "x"},
                      {"user_id": 42, "request_id": None, "kind": "pending_doc", "source": "gmail", "ref": "y"}):
            write_proof(proof, [entry])
            fake = Fake()
            rep = verify_notify.run(admin, ledger_path=self.path, mode="apply", runner=fake, wrapper="/w",
                                    proof_path=proof, sweep=False)
            self.assertEqual([p["user"]["email"] for p in fake.payloads], ["bob@example.com"])
            self.assertEqual((rep.pending_doc_users, rep.pending_doc_credits), (1, 2))
            self.assertIn("1 account(s) (2 credit(s)) waiting while a document", rep.render("apply"))
            db = verify_ledger.connect(self.path)
            self.assertEqual(verify_ledger.blocked_ids(db, ["r1", "r2"]), set(), "held back, not blocked")
            self.assertEqual(verify_ledger.deferred(db), [("r1", PID, "t1"), ("r2", PID, "t2")])
            self.assertEqual(verify_ledger.sent_today(db, campaign="verify-live", day="2026-10-15"), 0)
            db.close()
        write_proof(proof, [])
        fake = Fake()
        verify_notify.run(admin, ledger_path=self.path, mode="apply", runner=fake, wrapper="/w", proof_path=proof,
                          sweep=False)
        jane = [p for p in fake.payloads if p["user"]["email"] == "jane@example.com"]
        self.assertEqual([[c["request_id"] for c in p["credits"]] for p in jane], [["r1", "r2"]])

    def test_unsendable_reminders_are_closed_and_never_starve_a_sendable_one(self):
        db = verify_ledger.connect(self.path)
        self.addCleanup(db.close)
        rows, entries = [], []

        def note(i, rid):
            c = verify_ledger.claim(db, user_key=f"u{i}@example.com", day="2026-10-01", request_ids=[rid],
                                    message_type="email", approved_by=CAPTAIN_UID, approval_ref="ref", windowed=True,
                                    refs=[{"request_id": rid, "profile_id": PID, "track_id": f"t-{rid}"}])
            verify_ledger.finalize(db, message_row=c["message_row"], status="sent", message_id=str(1000 + i))
        for i in range(200):
            rid = f"g{i}" if i % 2 else f"h{i}"
            note(i, rid)
            if i % 2 == 0:
                r = req(rid, email=f"u{i}@example.com", track=f"t-{rid}")
                r["user"]["id"] = f"user{i}"
                rows.append(r)
                entries.append({"user_id": f"user{i}", "request_id": "other", "kind": "pending_doc", "source": "c",
                                "ref": "x"})
        note(500, "ok")
        rows.append(req("ok", email="u500@example.com", track="t-ok"))
        proof = os.path.join(self.tmp, "proof.json")
        write_proof(proof, entries)
        fake, rep = Fake(), Report()
        verify_notify.send_followups(db, FakeAdmin(rows), rep, verdicts=verify_notify.affiliation.read(AFFILIATION_FILE), campaign="verify-live", day="2026-10-15",
                                     documented=verify_notify.load_proof_on_file(proof), limit=150, pace_seconds=0,
                                     wrapper="/w", runner=fake)
        self.assertEqual([[c["request_id"] for c in p["credits"]] for p in fake.payloads], [["ok"]])
        self.assertEqual(rep.pending_doc_users, 100)
        still_due = {mid for mid, _, _ in verify_ledger.reminders_due(db, campaign="verify-live", day="2026-10-15")}
        self.assertEqual(still_due, {str(1000 + i) for i in range(0, 200, 2)} | {"1500"},
                         "gone credits are closed; held users stay due")

    def test_a_held_back_credit_that_is_reverted_on_the_server_is_closed_and_never_removal_due(self):
        decisions_db(self.path, [dec("r1", at=_ago(1))])
        admin = FakeAdmin([req("r1")])
        proof = os.path.join(self.tmp, "proof.json")
        write_proof(proof, [{"user_id": 42, "request_id": "older", "kind": "pending_doc", "source": "core", "ref": "x"}])
        verify_notify.run(admin, ledger_path=self.path, mode="apply", runner=Fake(), wrapper="/w", proof_path=proof,
                          sweep=False)
        db = verify_ledger.connect(self.path)
        self.addCleanup(db.close)
        self.assertEqual(verify_ledger.deferred(db), [("r1", PID, "t1")])
        self.assertEqual(verify_ledger.removal_due(db, day="2027-12-31"), [], "a held-back credit is never removal-due")
        admin.rows[0]["status"] = "rejected"
        write_proof(proof, [])
        fake = Fake()
        verify_notify.run(admin, ledger_path=self.path, mode="apply", runner=fake, wrapper="/w", proof_path=proof,
                          sweep=False)
        self.assertEqual(fake.payloads, [])
        self.assertEqual(verify_ledger.deferred(db), [])
        self.assertEqual(verify_ledger.blocked_ids(db, ["r1"]), {"r1"})

    def test_removal_due_leaves_out_documents_on_file_and_human_approvals(self):
        db = verify_ledger.connect(self.path)
        self.addCleanup(db.close)
        c = verify_ledger.claim(db, user_key="jane@example.com", day="2026-10-01", request_ids=["r1", "r2", "r3"],
                                message_type="email", approved_by=CAPTAIN_UID, approval_ref="ref", windowed=True,
                                refs=[{"request_id": f"r{i}", "profile_id": PID, "track_id": f"t{i}"} for i in (1, 2, 3)])
        verify_ledger.finalize(db, message_row=c["message_row"], status="sent", message_id="500")
        human = req("r2", track="t2")
        human["metadata"] = {"approval": {"isAgent": False}}
        admin = FakeAdmin([req("r1", track="t1"), human, req("r3", track="t3")])
        proof = os.path.join(self.tmp, "proof.json")
        write_proof(proof, [{"user_id": 42, "request_id": "r1", "kind": "pending_doc", "source": "core", "ref": "x"}])
        rows, held = verify_notify.removal_due(db, admin, verify_notify.load_proof_on_file(proof), day="2026-11-02")
        self.assertEqual(([r["request_id"] for r in rows], held), (["r3"], []))

    def test_a_whole_user_document_holds_every_credit_past_its_removal_day(self):
        """firstmate 042: a document emailed to support@ is a user-level entry (no
        request id); that user never hits a per-credit removal day."""
        db = verify_ledger.connect(self.path)
        self.addCleanup(db.close)
        c = verify_ledger.claim(db, user_key="jane@example.com", day="2026-10-01", request_ids=["r1", "r2"],
                                message_type="email", approved_by=CAPTAIN_UID, approval_ref="ref", windowed=True,
                                refs=[{"request_id": f"r{i}", "profile_id": PID, "track_id": f"t{i}"} for i in (1, 2)])
        verify_ledger.finalize(db, message_row=c["message_row"], status="sent", message_id="500")
        admin = FakeAdmin([req("r1", track="t1"), req("r2", track="t2")])
        proof = os.path.join(self.tmp, "proof.json")
        write_proof(proof, [{"user_id": 42, "request_id": None, "kind": "pending_doc", "source": "gmail", "ref": "g"}])
        rows, held = verify_notify.removal_due(db, admin, verify_notify.load_proof_on_file(proof), day="2026-11-02")
        self.assertEqual(rows, [])
        self.assertEqual(sorted(r["request_id"] for r in held), ["r1", "r2"])
        self.assertTrue(all(r["reason"] == verify_ledger.HELD_AWAITING_REVIEW for r in held))
        # A whole-user identity check is no reason to hold (only a document under review is).
        write_proof(proof, [{"user_id": 42, "request_id": None, "kind": "approved_doc", "source": "core", "ref": "n"}])
        rows, held = verify_notify.removal_due(db, admin, verify_notify.load_proof_on_file(proof), day="2026-11-02")
        self.assertEqual(sorted(r["request_id"] for r in rows), ["r1", "r2"])

    def test_the_removal_export_lists_credits_held_by_a_user_reply_separately(self):
        db = verify_ledger.connect(self.path)
        for mid, user, ids in (("500", "jane@example.com", ("r1",)), ("600", "bob@example.com", ("r2",))):
            c = verify_ledger.claim(db, user_key=user, day="2020-01-01", request_ids=list(ids), message_type="email",
                                    approved_by=CAPTAIN_UID, approval_ref="ref", windowed=True,
                                    refs=[{"request_id": r, "profile_id": PID, "track_id": "t1"} for r in ids])
            verify_ledger.finalize(db, message_row=c["message_row"], status="sent", message_id=mid)
        verify_ledger.mark_replied(db, message_id="600")
        db.close()
        out = os.path.join(self.tmp, "due.jsonl")
        stub = os.path.join(self.tmp, "admin.sh")
        Path(stub).write_text('echo \'{"http_status": 200, "body": {"items": []}}\'\n')
        res = subprocess.run([sys.executable, str(ROOT / "scripts" / "credit-review.py"), "--ledger", self.path,
                              "verify-notify", "--removal-due", out, "--proof-on-file", PROOF_FILE],
                             capture_output=True, text=True, timeout=60, check=False,
                             env={**os.environ, "CREDIT_REVIEW_ADMIN_SCRIPT": stub})
        self.assertEqual(res.returncode, 0, res.stdout + res.stderr)
        due = [json.loads(ln)["request_id"] for ln in Path(out).read_text().splitlines()]
        held = [json.loads(ln) for ln in Path(out + ".held").read_text().splitlines()]
        self.assertEqual((due, [h["request_id"] for h in held]), (["r1"], ["r2"]))
        self.assertEqual(held[0]["reason"], "the user replied: removal held for a human")

    def test_a_cron_tick_counts_removal_due_from_the_ledger_without_admin_calls(self):
        db = verify_ledger.connect(self.path)
        c = verify_ledger.claim(db, user_key="jane@example.com", day="2020-01-01", request_ids=["r1", "r2"],
                                message_type="email", approved_by=CAPTAIN_UID, approval_ref="ref", windowed=True,
                                refs=[{"request_id": f"r{i}", "profile_id": PID, "track_id": f"t{i}"} for i in (1, 2)])
        verify_ledger.finalize(db, message_row=c["message_row"], status="sent", message_id="500")
        db.close()
        proof = os.path.join(self.tmp, "proof.json")
        write_proof(proof, [{"user_id": 42, "request_id": "r1", "kind": "pending_doc", "source": "core", "ref": "x"}])
        admin = FakeAdmin([])
        rep = verify_notify.run(admin, ledger_path=self.path, mode="apply", runner=Fake(), wrapper="/w",
                                proof_path=proof, sweep=False)
        self.assertEqual(rep.removal_due, 1)
        self.assertEqual(admin.calls, [])

    def test_removal_due_export_halts_without_a_fresh_proof_list(self):
        out = os.path.join(self.tmp, "due.jsonl")
        stale = os.path.join(self.tmp, "stale.json")
        write_proof(stale, age_h=3.5)
        part = os.path.join(self.tmp, "part.json")
        d = proof_doc(generated_at=_ago(0))
        d["sources"].append({"name": "gmail", "stale": True})
        Path(part).write_text(json.dumps(d))
        for path in (os.path.join(self.tmp, "absent.json"), stale, part):
            res = subprocess.run([sys.executable, str(ROOT / "scripts" / "credit-review.py"), "--ledger", self.path,
                                  "verify-notify", "--removal-due", out, "--proof-on-file", path],
                                 capture_output=True, text=True, timeout=60, check=False)
            self.assertEqual(res.returncode, 1, res.stderr)
            self.assertIn("Nothing was exported", res.stdout)
            self.assertFalse(os.path.exists(out))

    def test_a_pending_document_on_the_credit_itself_closes_that_credit_only(self):
        decisions_db(self.path, [dec("r1")])
        proof = os.path.join(self.tmp, "proof.json")
        write_proof(proof, [{"user_id": 42, "request_id": "r1", "kind": "pending_doc", "source": "core", "ref": "x"}])
        fake = Fake()
        rep = verify_notify.run(FakeAdmin([req("r1")]), ledger_path=self.path, mode="apply", runner=fake,
                                wrapper="/w", proof_path=proof, sweep=False)
        self.assertEqual((fake.payloads, rep.proof_on_file, rep.pending_doc_users), ([], 1, 0))

    def test_reminders_follow_the_same_documents_rule(self):
        db = verify_ledger.connect(self.path)
        self.addCleanup(db.close)
        c = windowed_note(db)
        verify_ledger.finalize(db, message_row=c["message_row"], status="sent", message_id="500")
        admin = FakeAdmin([req("r1", track="t1"), req("r2", track="t2")])
        proof = os.path.join(self.tmp, "proof.json")

        def remind(entries, human=False):
            write_proof(proof, entries)
            if human:
                admin.rows[1]["metadata"] = {"approval": {"isAgent": False}}
            fake, rep = Fake(), Report()
            verify_notify.send_followups(db, admin, rep, verdicts=verify_notify.affiliation.read(AFFILIATION_FILE), campaign="verify-live", day="2026-10-15",
                                         documented=verify_notify.load_proof_on_file(proof), limit=10,
                                         pace_seconds=0, wrapper="/w", runner=fake)
            return fake, rep
        fake, rep = remind([])
        self.assertEqual([[c["request_id"] for c in p["credits"]] for p in fake.payloads], [["r1", "r2"]])
        a = fake.argv[0]
        self.assertEqual((a[a.index("--kind") + 1], a[a.index("--parent-message-id") + 1]), ("reminder-14", "500"))
        # A document on file for one credit holds the user's reminder for a human (any proof:
        # never notified again automatically).
        fake, rep = remind([{"user_id": 42, "request_id": "r1", "kind": "approved_doc", "source": "c", "ref": "x"}])
        self.assertEqual((fake.argv, rep.documented_users), ([], 1))
        fake, rep = remind([{"user_id": 42, "request_id": "other", "kind": "pending_doc", "source": "c", "ref": "x"}])
        self.assertEqual((fake.argv, rep.pending_doc_users), ([], 1))
        fake, rep = remind([{"user_id": 42, "request_id": "r1", "kind": "approved_doc", "source": "c", "ref": "x"}],
                           human=True)
        self.assertEqual((fake.argv, rep.human_approved), ([], 1))

    def test_dry_run_preview_writes_each_rendered_note(self):
        wave_file(self.wave, [("HOLD", "r1", "1", PID, "t1", "Mixing", 10, 0, "2026-09-02")])
        prev = os.path.join(self.tmp, "preview")
        os.mkdir(prev)
        fake = Fake({"jane@example.com": (0, "DRY-RUN retro-30d initial email credits=1\n{}", "")})
        verify_notify.run_wave(FakeAdmin([req("r1")]), wave_path=self.wave, ledger_path=self.path, mode="dry-run",
                               runner=fake, wrapper="/w", preview_dir=prev)
        self.assertIn("--dry-run", fake.argv[0])
        self.assertEqual(os.listdir(prev), ["00001.txt"])
        self.assertEqual(stat.S_IMODE(os.stat(os.path.join(prev, "00001.txt")).st_mode), 0o600)


def owner(email):
    return {"isClaimed": True, "workspaces": [{"email": email, "isClaimed": True}, {"email": "x@y.com", "isClaimed": False}]}


def event(eid, *, pid=PID, reason="misattributed", actor="admin", role="Mixing", title="Song", artist="Big Star",
          url="", at="2026-10-10T10:00:00Z", source="Discogs", policy=""):
    return {"event_id": eid, "profile_id": pid, "track_id": "t", "role": role, "track_title": title,
            "artist_name": artist, "reason": reason, "evidence_url": url, "actor": actor, "removed_at": at,
            "source_label": source, "policy_reason": policy}


class RemovalNoticeTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.path = os.path.join(self.tmp, "ledger.sqlite3")
        self.events = os.path.join(self.tmp, "events.jsonl")
        self.admin = FakeAdmin([])
        self.admin.profiles = {PID: owner("Jane@Example.com"), PID2: owner("bob@example.com")}

    def tearDown(self):
        shutil.rmtree(self.tmp)

    def write(self, evs):
        Path(self.events).write_text("".join(json.dumps(e) + "\n" for e in evs))

    def test_self_and_fraud_removals_are_never_notified_others_are_batched_per_owner(self):
        self.write([event("e1"), event("e2", reason="duplicate", title="B"), event("e3", actor="self"),
                    event("e4", reason="fraud"), event("e5", pid=PID2, reason="policy", policy="org_on_person")])
        fake = Fake()
        rep = verify_notify.run_removal_notices(self.admin, events_path=self.events, ledger_path=self.path,
                                                mode="apply", pace_seconds=0, runner=fake, wrapper="/w")
        self.assertEqual((rep.self_removals, rep.fraud_silent, rep.sent_notes), (1, 1, 2))
        by = {p["user"]["email"]: p for p in fake.payloads}
        self.assertEqual([c["request_id"] for c in by["jane@example.com"]["credits"]], ["e1", "e2"])
        self.assertTrue(all("fraud" not in json.dumps(p) for p in fake.payloads))
        for a in fake.argv:
            self.assertEqual(a[a.index("--campaign") + 1], "removal-notice")
        self.assertIn("1 self-removal(s) and 1 fraud removal(s) are never notified", rep.render("apply"))

    def test_an_unclaimed_or_multi_owner_profile_is_not_notified(self):
        self.admin.profiles[PID2] = {"isClaimed": True, "workspaces": [{"email": "a@x.com", "isClaimed": True},
                                                                        {"email": "b@x.com", "isClaimed": True}]}
        self.write([event("e1", pid=PID2), event("e2", pid="unclaimed")])
        fake = Fake()
        rep = verify_notify.run_removal_notices(self.admin, events_path=self.events, ledger_path=self.path,
                                                mode="apply", pace_seconds=0, runner=fake, wrapper="/w")
        self.assertEqual((rep.no_owner, fake.argv), (2, []))

    def test_dry_run_list_for_approval_has_no_emails(self):
        self.write([event("e1"), event("e5", pid=PID2, reason="policy", policy="duplicate_profile")])
        lst = os.path.join(self.tmp, "list.csv")
        fake = Fake({"jane@example.com": (0, "VALID", ""), "bob@example.com": (0, "VALID", "")})
        rep = verify_notify.run_removal_notices(self.admin, events_path=self.events, ledger_path=self.path,
                                                mode="dry-run", runner=fake, wrapper="/w", list_path=lst)
        self.assertTrue(all("--validate" in a for a in fake.argv))
        body = Path(lst).read_text()
        self.assertNotIn("@", body)
        self.assertIn(PID2, body)
        self.assertIn("policy=1", body)
        self.assertIn("2 owner(s) would be told about 2 removed credit(s)", rep.render("dry-run"))

    def test_invalid_events_are_reported_alone_and_never_block_the_owners_other_notices(self):
        self.write([event("e1"), event("e2", reason="other"), event("evt_3"),
                    event("e4", url="https://octave.ak.muso.ai/x"), event("e5", url="http://x.com/a"),
                    event("e1", title="Again"), event("e6", title="T" * 201), event("e7", reason="Policy", policy="org_on_person"),
                    event("e8", reason="verification"), event("e9", reason="policy"), event("e10", source="")])
        fake = Fake()
        rep = verify_notify.run_removal_notices(self.admin, events_path=self.events, ledger_path=self.path,
                                                mode="apply", pace_seconds=0, runner=fake, wrapper="/w")
        self.assertEqual([[c["request_id"] for c in p["credits"]] for p in fake.payloads], [["e1", "e7"]])
        self.assertEqual(rep.invalid_events, 9)
        out = rep.render("apply")
        for why in ("e2: unknown reason 'other'", "event #3: event_id", "e4: evidence_url points at an internal",
                    "e5: evidence_url is not a plain https URL"):
            self.assertIn(why, out)
        # Fable copy review 2026-10-17: "verification" and a policy removal without a named
        # sub-reason are manual_only; a misattribution names its real source.
        self.assertIn("manual_only", verify_notify.removal_event_problem(event("e8", reason="verification")))
        self.assertIn("manual_only", verify_notify.removal_event_problem(event("e9", reason="policy")))
        self.assertIn("source_label", verify_notify.removal_event_problem(event("e10", source="")))
        quiet = verify_notify.run_removal_notices(self.admin, events_path=self.events, ledger_path=self.path,
                                                  mode="apply", pace_seconds=0, runner=Fake(), wrapper="/w")
        self.assertIn("9 invalid removal event(s)", quiet.render("apply"))

    def test_a_malformed_events_file_fails_loud(self):
        Path(self.events).write_text('{"event_id": "e1"}\n')
        with self.assertRaises(ContractError):
            verify_notify.run_removal_notices(self.admin, events_path=self.events, ledger_path=self.path,
                                              runner=Fake(), wrapper="/w")


CURL_STUB = r"""#!/usr/bin/env bash
payload="" url="" method="GET"
while [ $# -gt 0 ]; do
  case "$1" in
    -X) method="$2"; shift 2 ;;
    --data) payload="$(cat)"; shift 2 ;;
    http*) url="$1"; shift ;;
    *) shift ;;
  esac
done
echo "$method $url" >> "$STUB_LOG"
case "$method ${url#https://api.intercom.io}" in
  "POST /contacts/search")
    e="$(printf '%s' "$payload" | jq -r .query.value)"
    printf '{"data":[{"id":"c%s","role":"user","email":"%s","external_id":"test-subject"}]}' "${#e}" "$e" ;;
  "POST /messages")
    if [ -n "${STUB_REJECT:-}" ] && [ -f "$STUB_REJECT" ]; then
      rm -f "$STUB_REJECT"; printf '{"type":"error.list","errors":[{"code":"rate_limit_exceeded"}]}'; exit 0
    fi
    printf '%s\n' "$payload" >> "$STUB_LOG.bodies"
    n=$(( $(cat "$STUB_N" 2>/dev/null || echo 500) + 1 )); echo "$n" > "$STUB_N"
    printf '{"type":"admin_message","id":"%s","message_type":"email","conversation_id":null}' "$n" ;;
  "POST /conversations/search") printf '{"conversations":[]}' ;;
  *) printf '{"type":"error.list","errors":[{"code":"not_found"}]}' ;;
esac
"""


@unittest.skipUnless(shutil.which("jq") and (shutil.which("timeout") or shutil.which("gtimeout")),
                     "jq and timeout are needed for the wiring test")
class WiringTests(unittest.TestCase):
    """The real gate (TESTABLE copy) behind the real driver: one note per account,
    then a second run the same day sends nothing."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        t = Path(self.tmp)
        src = (ROOT / "scripts" / "intercom-verify-request.sh").read_text()
        self.assertIn("\nreadonly TESTABLE=0\n", src)
        (t / "gate.sh").write_text(src.replace("\nreadonly TESTABLE=0\n", "\nreadonly TESTABLE=1\n"))
        self.assertIn("\nreadonly RETRO_COPY_APPROVED=0\n", src)
        self.assertIn("\nreadonly LIVE_WINDOWED_COPY_APPROVED=0\n", src)  # firstmate 090: no removal language
        unlocked = (src.replace("\nreadonly TESTABLE=0\n", "\nreadonly TESTABLE=1\n")
                    .replace("\nreadonly RETRO_COPY_APPROVED=0\n", "\nreadonly RETRO_COPY_APPROVED=1\n"))
        (t / "gate-retro.sh").write_text(unlocked)
        (t / "gate-windowed.sh").write_text(unlocked.replace("\nreadonly LIVE_WINDOWED_COPY_APPROVED=0\n",
                                                             "\nreadonly LIVE_WINDOWED_COPY_APPROVED=1\n"))
        (t / "curl").write_text(CURL_STUB)
        (t / "gate-removal.sh").write_text(src.replace("\nreadonly TESTABLE=0\n", "\nreadonly TESTABLE=1\n")
                                           .replace("\nreadonly REMOVAL_COPY_APPROVED=0\n",
                                                    "\nreadonly REMOVAL_COPY_APPROVED=1\n"))
        for f in ("gate.sh", "gate-retro.sh", "gate-windowed.sh", "gate-removal.sh", "curl"):
            (t / f).chmod((t / f).stat().st_mode | stat.S_IEXEC)
        self.path = str(t / "ledger.sqlite3")
        self.env = {
            "MUSOAI_INTERCOM_TOKEN": "x", "STUB_LOG": str(t / "calls.log"), "STUB_N": str(t / "n"),
            "INTERCOM_VERIFY_TEST_LOG_DIR": str(t / "api-logs"), "INTERCOM_VERIFY_TEST_LEDGER": self.path,
            "INTERCOM_VERIFY_TEST_LEDGER_HELPER": str(ROOT / "scripts" / "credit_review" / "verify_ledger.py"),
            "INTERCOM_VERIFY_TEST_CURL_BIN": str(t / "curl"), "INTERCOM_VERIFY_TEST_DAY": "2026-10-15",
            "INTERCOM_VERIFY_TEST_TIMEOUT_BIN": shutil.which("timeout") or shutil.which("gtimeout"),
        }
        self.saved = {k: os.environ.get(k) for k in self.env}
        os.environ.update(self.env)

    def tearDown(self):
        for k, v in self.saved.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v
        shutil.rmtree(self.tmp)

    def test_end_to_end_once_per_account_and_idempotent(self):
        decisions_db(self.path, [dec("r1"), dec("r2"), dec("r3", pid=PID2)])
        admin = FakeAdmin([req("r1"), req("r2", title="Other Song"), req("r3", pid=PID2, email="bob@example.com")])
        gate = os.path.join(self.tmp, "gate-windowed.sh")
        rep = verify_notify.run(admin, ledger_path=self.path, mode="apply", wrapper=gate)
        self.assertEqual((rep.sent_notes, rep.sent_credits, rep.failed_users), (2, 3, 0), rep)
        rep2 = verify_notify.run(admin, ledger_path=self.path, mode="apply", wrapper=gate)
        self.assertEqual(rep2.candidates, 0)
        self.assertEqual(rep2.render("apply"), "NO_REPLY")
        posts = [ln for ln in Path(self.env["STUB_LOG"]).read_text().splitlines() if ln.endswith("/messages")]
        self.assertEqual(len(posts), 2)
        db = sqlite3.connect(self.path)
        try:
            self.assertEqual(db.execute("SELECT COUNT(*) FROM verify_requests WHERE status='sent'").fetchone()[0], 3)
        finally:
            db.close()

    def test_a_mixed_user_gets_one_v1_note_through_the_real_gate(self):
        """QA review of #1257 @53428d0, through the real gate and ledger (not Fake): a provisional
        credit and an ordinary decider approval of one user go out as ONE v1 note with no
        removal date; nothing is refused and nothing waits 90 days."""
        decisions_db(self.path, [dec("r1"), dec("r2", track="t2")])
        db = sqlite3.connect(self.path)
        db.execute("UPDATE decisions SET evidence_kind = 'catalog_confirmed' WHERE request_id = 'r1'")
        db.execute("UPDATE decisions SET evidence_kind = 'provisional_paid' WHERE request_id = 'r2'")
        db.commit(); db.close()
        admin = FakeAdmin([req("r1"), req("r2", title="Other Song", track="t2")])
        rep = verify_notify.run(admin, ledger_path=self.path, mode="apply", wrapper=os.path.join(self.tmp, "gate-windowed.sh"))
        self.assertEqual((rep.sent_notes, rep.sent_credits, rep.refused_users, rep.mixed_v1_users), (1, 2, 0, 1), rep)
        db = sqlite3.connect(self.path)
        try:
            self.assertEqual(db.execute("SELECT COUNT(*), MAX(removal_day) FROM verify_messages WHERE kind='initial'")
                             .fetchone(), (1, None))
        finally:
            db.close()
        for b in posted_bodies(self.env["STUB_LOG"]):
            assert_no_removal_language(self, b["subject"] + " " + b["body"])

    def test_past_wave_end_to_end_locked_then_one_message_never_removed(self):
        wave = os.path.join(self.tmp, "wave.csv")
        wave_file(wave, [("HOLD", "r1", "1", PID, "t1", "Mixing", 10, 0, "2026-09-02"),
                         ("HOLD", "r2", "1", PID, "t2", "Composer", 70, 0, "2026-09-03")])
        admin = FakeAdmin([req("r1", track="t1"), req("r2", track="t2", roles=("Composer",))])
        locked = os.path.join(self.tmp, "gate.sh")
        rep = verify_notify.run_wave(admin, wave_path=wave, ledger_path=self.path, mode="apply", pace_seconds=0,
                                     wrapper=locked, today="2026-10-16")
        # Send-locked: refused before any Intercom call or ledger claim, and said so in the report.
        self.assertEqual((rep.sent_notes, rep.refused_users), (0, 1))
        self.assertIn("not approved for sending yet", rep.render("apply"))
        self.assertFalse(Path(self.env["STUB_LOG"]).exists())
        gate = os.path.join(self.tmp, "gate-retro.sh")

        def tick(day):
            os.environ["INTERCOM_VERIFY_TEST_DAY"] = day
            return verify_notify.run_wave(admin, wave_path=wave, ledger_path=self.path, mode="apply", pace_seconds=0,
                                          wrapper=gate, today=day, sweep=False)
        self.assertEqual(tick("2026-10-16").sent_notes, 1)
        self.assertEqual(tick("2026-10-30").reminders_sent, 0, "past credits get no follow-up")
        self.assertEqual(tick("2026-11-10").reminders_sent, 0)
        last = tick("2026-11-16")
        self.assertEqual((last.removal_due, last.unverified), (0, 2), "never removal-due; flagged unverified")
        posts = [ln for ln in Path(self.env["STUB_LOG"]).read_text().splitlines() if ln.endswith("/messages")]
        self.assertEqual(len(posts), 1)

    def test_new_credit_notes_end_to_end_no_reminders_never_removal_due(self):
        """firstmate 090: the note is v1 (no date), so no day-14/25 reminder ever goes out and
        the credit is never removal-due, however long it waits (the committed gate, which
        also has the windowed lock unlocked here, still sends v1 from the driver)."""
        decisions_db(self.path, [dec("r1")])
        admin = FakeAdmin([req("r1", track="t1")])
        gate = os.path.join(self.tmp, "gate-windowed.sh")
        import credit_review.verify_notify as vn
        real_dt = vn.datetime

        class Clock(real_dt):
            now_day = "2026-10-16"

            @classmethod
            def now(cls, tz=None):
                return real_dt.fromisoformat(cls.now_day + "T12:00:00+00:00")
        vn.datetime = Clock
        self.addCleanup(setattr, vn, "datetime", real_dt)

        proof = os.path.join(self.tmp, "proof.json")

        def tick(day):
            Clock.now_day = day
            os.environ["INTERCOM_VERIFY_TEST_DAY"] = day
            Path(proof).write_text(json.dumps(proof_doc(generated_at=day + "T11:30:00Z")))
            return verify_notify.run(admin, ledger_path=self.path, mode="apply", since_hours=None, wrapper=gate,
                                     sweep=False, proof_path=proof)
        self.assertEqual(tick("2026-10-16").sent_notes, 1)
        self.assertEqual(tick("2026-10-30").reminders_sent, 0)
        self.assertEqual(tick("2026-11-10").reminders_sent, 0)
        self.assertEqual(tick("2026-11-16").removal_due, 0)
        self.assertEqual(tick("2027-01-16").removal_due, 0)
        db = sqlite3.connect(self.path)
        try:
            rows = db.execute("SELECT kind, removal_day FROM verify_messages WHERE status='sent' ORDER BY id").fetchall()
        finally:
            db.close()
        self.assertEqual(rows, [("initial", None)])
        bodies = posted_bodies(self.env["STUB_LOG"])
        self.assertEqual(len(bodies), 1)
        for b in bodies:
            assert_no_removal_language(self, b["subject"] + " " + b["body"])

    def test_a_held_back_credit_older_than_the_window_is_asked_exactly_once_after_the_review(self):
        decisions_db(self.path, [dec("r1", at=_ago(1))])
        admin = FakeAdmin([req("r1", track="t1")])
        gate = os.path.join(self.tmp, "gate-windowed.sh")
        proof = os.path.join(self.tmp, "proof.json")
        pending = [{"user_id": 42, "request_id": "older", "kind": "pending_doc", "source": "core", "ref": "x"}]

        def tick(day, entries):
            os.environ["INTERCOM_VERIFY_TEST_DAY"] = day
            write_proof(proof, entries)
            return verify_notify.run(admin, ledger_path=self.path, mode="apply", since_hours=168, wrapper=gate,
                                     sweep=False, proof_path=proof)
        self.assertEqual((tick("2026-10-16", pending).pending_doc_credits), 1)
        db = sqlite3.connect(self.path)
        db.execute("UPDATE decision_outcomes SET at=?", (_ago(24 * 10),))
        db.commit()
        db.close()
        self.assertEqual(tick("2026-10-20", pending).pending_doc_credits, 1)
        self.assertEqual(tick("2026-10-26", []).sent_notes, 1)
        again = tick("2026-10-27", [])
        self.assertEqual((again.candidates, again.sent_notes), (0, 0))
        posts = [ln for ln in Path(self.env["STUB_LOG"]).read_text().splitlines() if ln.endswith("/messages")]
        self.assertEqual(len(posts), 1)

    def test_a_held_back_credit_whose_send_is_rejected_is_retried_beyond_the_window(self):
        decisions_db(self.path, [dec("r1", at=_ago(1))])
        admin = FakeAdmin([req("r1", track="t1")])
        gate = os.path.join(self.tmp, "gate-windowed.sh")
        proof = os.path.join(self.tmp, "proof.json")
        pending = [{"user_id": 42, "request_id": "older", "kind": "pending_doc", "source": "core", "ref": "x"}]

        def tick(day, entries):
            os.environ["INTERCOM_VERIFY_TEST_DAY"] = day
            write_proof(proof, entries)
            return verify_notify.run(admin, ledger_path=self.path, mode="apply", since_hours=168, wrapper=gate,
                                     sweep=False, proof_path=proof)
        self.assertEqual(tick("2026-10-16", pending).pending_doc_credits, 1)
        db = sqlite3.connect(self.path)
        db.execute("UPDATE decision_outcomes SET at=?", (_ago(24 * 10),))
        db.commit()
        db.close()
        reject = os.path.join(self.tmp, "reject-next")
        Path(reject).write_text("1")
        os.environ["STUB_REJECT"] = reject
        self.addCleanup(os.environ.pop, "STUB_REJECT", None)
        first = tick("2026-10-26", [])
        self.assertEqual((first.sent_notes, first.failed_users), (0, 1))
        retry = tick("2026-10-26", [])
        self.assertEqual((retry.candidates, retry.sent_notes), (1, 1))
        self.assertEqual(tick("2026-10-27", []).candidates, 0)
        db = sqlite3.connect(self.path)
        try:
            self.assertEqual(db.execute("SELECT status FROM verify_requests WHERE request_id='r1'").fetchone()[0],
                             "sent")
        finally:
            db.close()

    def test_as_committed_every_note_is_the_no_threat_v1_copy(self):
        """firstmate 090 (2026-10-19 23:27Z): the captain dropped auto-removal, so the committed
        gate sends every new credit's note as v1 (no date, no removal language), records no
        removal date, and refuses the windowed copy and every follow-up."""
        decisions_db(self.path, [dec("r1"), dec("r2", track="t2")])
        admin = FakeAdmin([req("r1", track="t1"), req("r2", title="Other Song", track="t2")])
        os.environ["INTERCOM_VERIFY_TEST_DAY"] = "2026-10-16"
        gate = os.path.join(self.tmp, "gate.sh")
        rep = verify_notify.run(admin, ledger_path=self.path, mode="apply", wrapper=gate, sweep=False)
        self.assertEqual((rep.sent_notes, rep.sent_credits, rep.refused_users), (1, 2, 0), rep)
        db = sqlite3.connect(self.path)
        try:
            self.assertEqual(db.execute("SELECT removal_day, due_day FROM verify_messages WHERE kind='initial'").fetchall(),
                             [(None, None)])
            mid = db.execute("SELECT message_id FROM verify_messages WHERE kind='initial'").fetchone()[0]
        finally:
            db.close()
        bodies = posted_bodies(self.env["STUB_LOG"])
        self.assertEqual(len(bodies), 1)
        self.assertIn("Nothing changes while we check", bodies[0]["body"])
        for b in bodies:
            assert_no_removal_language(self, b["subject"] + " " + b["body"])
        cf = os.path.join(self.tmp, "c.json")
        Path(cf).write_text(json.dumps({"user": {"email": "jane@example.com", "id": "42", "first_name": "Jane"},
                                        "credits": [{"request_id": "r1", "role": "Mixing", "track_title": "Song",
                                                     "artist_name": "Big Star"}]}))
        for extra in (["--copy", "windowed"], ["--kind", "reminder-14", "--parent-message-id", str(mid)],
                      ["--kind", "after-rejection", "--parent-message-id", str(mid)]):
            with self.subTest(extra):
                res = subprocess.run([gate, "send", "--credits-file", cf, "--approved-by", CAPTAIN_UID, *extra],
                                     capture_output=True, text=True, timeout=60, check=False)
                self.assertEqual(res.returncode, 1, res.stdout + res.stderr)
        posts = [ln for ln in Path(self.env["STUB_LOG"]).read_text().splitlines() if ln.endswith("/messages")]
        self.assertEqual(len(posts), 1, "only the v1 note went out")

    def test_removal_notice_end_to_end_once_per_event_locked_until_approved(self):
        events = os.path.join(self.tmp, "events.jsonl")
        Path(events).write_text(json.dumps(event("e1", url="https://www.discogs.com/release/1")) + "\n")
        admin = FakeAdmin([])
        admin.profiles = {PID: owner("jane@example.com")}
        os.environ["INTERCOM_VERIFY_TEST_DAY"] = "2026-10-16"
        locked = verify_notify.run_removal_notices(admin, events_path=events, ledger_path=self.path, mode="apply",
                                                   pace_seconds=0, wrapper=os.path.join(self.tmp, "gate.sh"))
        self.assertEqual((locked.sent_notes, locked.refused_users), (0, 1))
        self.assertFalse(Path(self.env["STUB_LOG"]).exists())
        gate = os.path.join(self.tmp, "gate-removal.sh")
        rep = verify_notify.run_removal_notices(admin, events_path=events, ledger_path=self.path, mode="apply",
                                                pace_seconds=0, wrapper=gate)
        self.assertEqual(rep.sent_notes, 1)
        again = verify_notify.run_removal_notices(admin, events_path=events, ledger_path=self.path, mode="apply",
                                                  pace_seconds=0, wrapper=gate)
        self.assertEqual((again.candidates, again.render("apply")), (0, "NO_REPLY"))
        log = Path(self.env["STUB_LOG"]).read_text()
        self.assertEqual(sum(1 for ln in log.splitlines() if ln.endswith("/messages")), 1)
        self.assertNotIn("conversations/search", log, "a removal notice is not an ask: no document check")

def user_req(rid, uid, *, pid=PID, track=None, created="2026-10-15T20:00:00Z"):
    r = req(rid, pid=pid, email=f"u{uid}@example.com", track=track or f"t-{rid}", created=created)
    r["user"]["id"] = str(uid)
    return r


class AffiliationV1Tests(unittest.TestCase):
    """org-affiliation/v1 (cmux-credit-system-lane, firstmate 054): absent, held, a partial
    check or a file older than 2h = UNKNOWN = held."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.tmp)
        self.path = os.path.join(self.tmp, "aff.json")

    def write(self, users=None, held=None, age_h=0.1, schema="org-affiliation/v1"):
        gen = (datetime.now(timezone.utc) - timedelta(hours=age_h)).strftime("%Y-%m-%dT%H:%M:%SZ")
        Path(self.path).write_text(json.dumps({"schema": schema, "generated_at": gen, "users": users or {},
                                               "held": held or {}}))

    def test_per_user_rule(self):
        from credit_review import affiliation
        self.write({"1": {"verdict": "none", "coverage": "full", "evidence": []},
                    "2": {"verdict": "none", "coverage": "labels_only", "evidence": []},
                    "3": {"verdict": "contributor", "coverage": "full", "evidence": []},
                    "4": {"verdict": "claimed_unverified", "coverage": "full", "evidence": []}},
                   held={"5": {"reason": "catalog read failed"}})
        v = affiliation.read(self.path)
        got = {u: affiliation.hold_reason(v, u) for u in ("1", "2", "3", "4", "5", "6")}
        self.assertEqual(got, {"1": None, "2": "affiliation_partial_check", "3": "org_affiliated",
                               "4": "affiliation_claimed_unverified", "5": "affiliation_held",
                               "6": "affiliation_unknown"})
        # claimed_unverified allows only a trusted-contradicted removal (producer README, firstmate 055).
        self.assertIsNone(affiliation.hold_reason(v, "4", affiliation.ACTION_TRUSTED_REMOVAL))
        self.assertEqual(affiliation.hold_reason(v, "3", affiliation.ACTION_TRUSTED_REMOVAL), "org_affiliated")

    def test_an_untrustworthy_file_is_unknown_for_everyone(self):
        from credit_review import affiliation
        for kw in ({"age_h": 2.5}, {"age_h": -1}, {"schema": "org-affiliation/v2"},
                   {"users": {"1": {"verdict": "maybe", "coverage": "full"}}}):
            with self.subTest(kw):
                self.write(**kw)
                with self.assertRaises(ValueError):
                    affiliation.read(self.path)

    def test_a_legacy_flat_file_is_never_trusted(self):
        """QA review of #1257 @53428d0: the pre-v1 flat shape has no coverage and no stamp, so an
        old one could authorize sends forever."""
        from credit_review import affiliation
        Path(self.path).write_text(json.dumps({"1": {"verdict": "none", "evidence": []}}))
        with self.assertRaises(ValueError):
            affiliation.read(self.path)

    def test_the_decider_asks_for_a_full_check_of_the_next_recipients(self):
        led = os.path.join(self.tmp, "ledger.sqlite3")
        decisions_db(led, [dec("p1"), dec("p2", outcome="error:x")])
        db = verify_ledger.connect(led)
        try:
            path, n = verify_notify.write_affiliation_priority(db, directory=self.tmp)
        finally:
            db.close()
        self.assertEqual((n, json.loads(Path(path).read_text())["user_ids"]), (1, [42]))
        self.assertTrue(path.endswith("org-affiliation-priority-credit-trust-llm-t01.json"))

    def test_priority_file_is_written_atomically(self):
        from credit_review import affiliation
        out = affiliation.write_priority("lane-x", [5, "3", "x", 5], source="t", directory=self.tmp)
        doc = json.loads(Path(out).read_text())
        self.assertEqual((os.path.basename(out), doc["user_ids"], doc["source"]),
                         ("org-affiliation-priority-lane-x.json", [3, 5], "t"))


class EnableGateTests(unittest.TestCase):
    """Fable 2026-10-17, decision-verify-notify-enable: the gates before the first live send."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.tmp)
        self.path = os.path.join(self.tmp, "ledger.sqlite3")
        self.proof = os.path.join(self.tmp, "proof.json")
        self.aff = os.path.join(self.tmp, "aff.json")
        write_affiliation({str(u): {"verdict": "none", "coverage": "full", "evidence": []} for u in range(40, 60)}, path=self.aff)

    def go(self, rows, *, entries=(), contacts=(), fake=None, **kw):
        decisions_db(self.path, [dec(r["id"], pid=r["profileId"], track=r["trackId"]) for r in rows])
        write_proof(self.proof, entries, contacts=contacts)
        fake = fake or Fake()
        kw.setdefault("affiliation_path", self.aff)
        rep = verify_notify.run(FakeAdmin(rows), ledger_path=self.path, mode="apply", runner=fake, wrapper="/w",
                                proof_path=self.proof, sweep=False, since_hours=None, **kw)
        return rep, fake

    def deferred(self):
        db = verify_ledger.connect(self.path)
        try:
            return {rid for rid, _, _ in verify_ledger.deferred(db)}
        finally:
            db.close()

    def test_a_support_at_only_contact_gets_no_note_and_is_held(self):
        """Precondition 1: the 90-day support@ list is read; a user who only emailed
        support@ (no proof-on-file entry at all) is never notified."""
        rep, fake = self.go([user_req("a1", 41), user_req("a2", 42)], contacts=[41])
        self.assertEqual([p["user"]["id"] for p in fake.payloads], ["42"])
        self.assertEqual((rep.support_contact_users, rep.support_contact_credits), (1, 1))
        self.assertEqual(self.deferred(), {"a1"}, "held, not closed")
        self.assertIn("emailed support@ in the last 90 days", rep.render("apply"))

    def test_intercom_proof_of_any_kind_means_no_note(self):
        for kind in ("pending_doc", "approved_doc", "human_approved_after_doc"):
            with self.subTest(kind):
                if os.path.exists(self.path):
                    os.unlink(self.path)
                rep, fake = self.go([user_req("b1", 43)],
                                    entries=[{"user_id": 43, "request_id": None, "kind": kind, "source": "intercom",
                                              "ref": "conv-1"}])
                self.assertEqual(fake.payloads, [], kind)
                self.assertEqual(self.deferred(), {"b1"})

    def test_affiliation_unknown_or_affiliated_is_listed_for_a_human(self):
        write_affiliation({"44": {"verdict": "contributor", "evidence": []},
                           "45": {"verdict": "none", "evidence": []}}, path=self.aff)
        rep, fake = self.go([user_req("c1", 44), user_req("c2", 45), user_req("c3", 46)])
        self.assertEqual([p["user"]["id"] for p in fake.payloads], ["45"])
        self.assertEqual(rep.affiliation_held, ["user 44: org_affiliated", "user 46: affiliation_unknown"])
        self.assertEqual(self.deferred(), {"c1", "c3"})
        self.assertIn("org affiliation unknown or affiliated", rep.render("apply"))

    def test_no_affiliation_file_sends_nothing(self):
        rep, fake = self.go([user_req("d1", 47)], affiliation_path=os.path.join(self.tmp, "absent.json"))
        self.assertEqual(fake.argv, [])
        self.assertIn("org-affiliation", rep.halted)

    def test_an_ask_in_either_campaign_within_90_days_locks_the_user(self):
        db = verify_ledger.connect(self.path)
        day = (datetime.now(timezone.utc) - timedelta(days=30)).strftime("%Y-%m-%d")
        c = verify_ledger.claim(db, user_key="u48@example.com", day=day, request_ids=["old"], message_type="email",
                                approved_by=CAPTAIN_UID, approval_ref="ref", campaign="retro-past")
        verify_ledger.finalize(db, message_row=c["message_row"], status="sent", message_id="1")
        db.close()
        rep, fake = self.go([user_req("e1", 48), user_req("e2", 49)])
        self.assertEqual([p["user"]["id"] for p in fake.payloads], ["49"])
        self.assertEqual((rep.recently_asked_users, rep.recently_asked_credits), (1, 1))
        self.assertEqual(self.deferred(), {"e1"})

    def test_a_mixed_user_gets_one_v1_note_covering_every_credit(self):
        """QA review of #1257 @53428d0: two notes for one user could never both be delivered
        (the 90-day re-ask lock refuses the second), so a user with ANY provisional_paid credit
        gets ONE note, the v1 copy (no date, no removal), for all of them."""
        rows = [user_req("g1", 54), user_req("g2", 54), user_req("g3", 55)]
        decisions_db(self.path, [dec(r["id"], pid=r["profileId"], track=r["trackId"]) for r in rows])
        db = sqlite3.connect(self.path)
        db.execute("UPDATE decisions SET evidence_kind = 'provisional_paid' WHERE request_id = 'g2'")
        db.execute("UPDATE decisions SET evidence_kind = 'catalog_confirmed' WHERE request_id IN ('g1', 'g3')")
        db.commit(); db.close()
        write_proof(self.proof, [])
        fake = Fake()
        rep = verify_notify.run(FakeAdmin(rows), ledger_path=self.path, mode="apply", runner=fake, wrapper="/w",
                                proof_path=self.proof, sweep=False, since_hours=None, affiliation_path=self.aff)
        sent = sorted((sorted(c["request_id"] for c in p["credits"]), "--copy" in a and a[a.index("--copy") + 1])
                      for p, a in zip(fake.payloads, [x for x in fake.argv if x[1] == "send"]))
        self.assertEqual(sent, [(["g1", "g2"], "v1"), (["g3"], "v1")], "firstmate 090: every note is v1")
        self.assertEqual(rep.mixed_v1_users, 1)

    def test_the_90_day_lock_follows_the_user_not_the_email(self):
        """QA review of #1257 @21f2de0: an account that changes its email is still the same
        user: the lock and the daily cap key on the Muso user id too, including notes written
        before account_id existed (via the decider's user id for the credits they covered)."""
        db = verify_ledger.connect(self.path)
        today = datetime.now(timezone.utc).strftime("%Y-%m-%d")
        last_week = (datetime.now(timezone.utc) - timedelta(days=7)).strftime("%Y-%m-%d")
        c = verify_ledger.claim(db, user_key="old@example.com", day=last_week, request_ids=["m1"], message_type="email",
                                approved_by=CAPTAIN_UID, approval_ref="ref", user_id="61")
        verify_ledger.finalize(db, message_row=c["message_row"], status="sent", message_id="900")
        self.assertTrue(verify_ledger.asked_within(db, user_key="new@example.com", day=today, user_id="61"))
        self.assertFalse(verify_ledger.asked_within(db, user_key="new@example.com", day=today, user_id="62"))
        again = verify_ledger.claim(db, user_key="new@example.com", day=today, request_ids=["m2"], message_type="email",
                                    approved_by=CAPTAIN_UID, approval_ref="ref", user_id="61")
        self.assertEqual(again["result"], "recently_asked")
        # A legacy row (no account_id): the decider's user id for its credit identifies the user.
        db.execute("UPDATE verify_messages SET account_id = NULL")
        db.close()
        decisions_db(self.path, [dec("m1")])   # decider user_id 42 for m1
        db = verify_ledger.connect(self.path)
        try:
            self.assertTrue(verify_ledger.asked_within(db, user_key="other@example.com", day=today, user_id="42"))
            self.assertTrue(verify_ledger.capped(db, user_key="other@example.com", day=last_week, user_id="42"))
        finally:
            db.close()

    def test_the_recipient_auth0_subject_is_passed_and_a_missing_one_holds_the_note(self):
        """2026-10-20 07:00Z: the gate matches Intercom's external_id against the account's Auth0
        subject. A user without one is held (deferred, never handed to the gate, whose refusal
        would close the credits); an unreadable replica halts the run with nothing sent."""
        rows = [user_req("a1", 45), user_req("a2", 46)]
        rep, fake = self.go(rows, auth_lookup=lambda ids: {"45": "auth0|abc-45"})
        self.assertEqual([(p["user"]["id"], p["user"].get("auth_id")) for p in fake.payloads], [("45", "auth0|abc-45")])
        self.assertEqual(rep.no_auth_users, 1)
        self.assertIn("a2", self.deferred())
        self.assertIn("no professionalId / Auth0 subject", rep.render("apply"))

        def down(ids):
            raise verify_notify.AuthLookupError("rc=2: trino down")
        rep, fake = self.go([user_req("a3", 47)], auth_lookup=down)
        self.assertEqual(fake.payloads, [])
        self.assertIn("Auth0 subjects cannot be read", rep.halted)
        self.assertTrue(rep.failed)
        self.assertIn("a3", self.deferred())

    def test_the_intercom_identity_is_read_from_neptuneprofessionalid(self):
        """firstmate 118: Intercom's external_id is the account's professionalId
        (users.neptuneprofessionalid), for accounts with and without an Auth0 subject."""
        fake = os.path.join(self.tmp, "trino.sh")
        Path(fake).write_text('#!/bin/sh\ncat > "$0.sql"\nprintf \'"45","8c0d-uuid"\\n"46",""\\n\'\n')
        os.chmod(fake, 0o755)
        with unittest.mock.patch.object(verify_notify, "AUTH_LOOKUP_CMD", fake):
            got = verify_notify.account_auth_ids([45, 46])
        sql = Path(fake + ".sql").read_text()
        self.assertIn("neptuneprofessionalid", sql)
        self.assertEqual(got, {"45": "8c0d-uuid"}, "an account with no identity is absent (held)")

    def test_a_dry_run_can_use_the_real_recipient_check(self):
        rows = [user_req("b1", 48)]
        decisions_db(self.path, [dec(r["id"], pid=r["profileId"], track=r["trackId"]) for r in rows])
        write_proof(self.proof, [])
        fake = Fake()
        verify_notify.run(FakeAdmin(rows), ledger_path=self.path, mode="dry-run", runner=fake, wrapper="/w",
                          proof_path=self.proof, sweep=False, since_hours=None, affiliation_path=self.aff,
                          check_recipients=True)
        self.assertIn("--check-recipient", fake.argv[0])
        self.assertNotIn("--validate", fake.argv[0])

    def test_unknown_paying_status_never_lets_the_cap_choose(self):
        """QA review of #1257 @3b5fea9: with no readable paying-users export, a run whose notes
        exceed the cap sends nothing (all wait, reported); one that fits under the cap sends."""
        missing = Path(os.path.join(self.tmp, "absent-paying.json"))
        rows = [user_req("w1", 51), user_req("w2", 52), user_req("w3", 53)]
        with unittest.mock.patch("credit_review.decide.PAYING_USERS_FILE", missing):
            rep, fake = self.go(rows, max_users=2)
        self.assertEqual(fake.payloads, [])
        self.assertIn("paying status unknown", rep.render("apply"))
        self.assertEqual(self.deferred(), {"w1", "w2", "w3"}, "kept for tomorrow, never closed")
        with unittest.mock.patch("credit_review.decide.PAYING_USERS_FILE", missing):
            rep, fake = self.go(rows, max_users=10)
        self.assertEqual(len(fake.payloads), 3)
        self.assertIn("every note fit under the cap", rep.render("apply"))

    def test_the_days_cap_counts_what_the_ledger_already_sent_today(self):
        """QA review of #1257 @53428d0: a same-day retry or second invocation never gets a fresh cap."""
        db = verify_ledger.connect(self.path)
        today = datetime.now(timezone.utc).strftime("%Y-%m-%d")
        for i, who in enumerate(("u90@example.com", "u91@example.com")):
            c = verify_ledger.claim(db, user_key=who, day=today, request_ids=[f"z{i}"], message_type="email",
                                    approved_by=CAPTAIN_UID, approval_ref="ref", windowed=True)
            verify_ledger.finalize(db, message_row=c["message_row"], status="sent", message_id=str(800 + i))
        db.close()
        paying = os.path.join(self.tmp, "paying.json")
        Path(paying).write_text(json.dumps({"generated_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
                                            "source": "t", "definition": "t", "counts_by_basis": {}, "count": 1,
                                            "ids": [56]}))
        with unittest.mock.patch("credit_review.decide.PAYING_USERS_FILE", Path(paying)):
            rep, fake = self.go([user_req("h1", 56), user_req("h2", 57), user_req("h3", 58)], max_users=3)
            self.assertEqual(len(fake.payloads), 1)
            self.assertEqual(rep.already_today, 2)
            self.assertEqual(len(self.deferred()), 2, "the rest wait for tomorrow")
            rep2, fake2 = self.go([user_req("h1", 56), user_req("h2", 57), user_req("h3", 58)], max_users=2)
        self.assertEqual(fake2.payloads, [], "cap already used up today")

    def test_reminders_pass_the_affiliation_gate_too(self):
        """QA review of #1257 @53428d0: a day-14 reminder is a user message like the note itself."""
        db = verify_ledger.connect(self.path)
        day = (datetime.now(timezone.utc) - timedelta(days=14)).strftime("%Y-%m-%d")
        c = verify_ledger.claim(db, user_key="u50@example.com", day=day, request_ids=["f0"], message_type="email",
                                approved_by=CAPTAIN_UID, approval_ref="ref", windowed=True,
                                refs=[{"request_id": "f0", "profile_id": PID, "track_id": "t-f0"}])
        verify_ledger.finalize(db, message_row=c["message_row"], status="sent", message_id="700")
        db.close()
        write_affiliation({"50": {"verdict": "contributor", "evidence": []}}, path=self.aff)
        rep, fake = self.go([user_req("f0", 50)])
        self.assertEqual((rep.reminders_sent, fake.payloads), (0, []))
        self.assertTrue(any(h.startswith("user 50: org_affiliated") for h in rep.affiliation_held), rep.affiliation_held)
        write_affiliation({"50": {"verdict": "none", "evidence": []}}, path=self.aff)
        rep, fake = self.go([user_req("f0", 50)])
        self.assertEqual(rep.reminders_sent, 1, "not closed: it goes out once the user is cleared")

    def test_a_stale_support_contact_snapshot_sends_nothing(self):
        """QA review of #1257 @53428d0: the export and its parts can be fresh while the embedded
        gmail_contacts_90d snapshot is not."""
        write_proof(self.proof, [])
        doc = json.loads(Path(self.proof).read_text())
        for bad in ({**doc["gmail_contacts_90d"], "generated_at": _ago(5)},
                    {k: v for k, v in doc["gmail_contacts_90d"].items() if k != "generated_at"}, [1, 2]):
            with self.subTest(bad):
                Path(self.proof).write_text(json.dumps({**doc, "gmail_contacts_90d": bad}))
                fake = Fake()
                rep = verify_notify.run(FakeAdmin([user_req("k1", 59)]), ledger_path=self.path, mode="apply",
                                        runner=fake, wrapper="/w", proof_path=self.proof, sweep=False,
                                        since_hours=None, affiliation_path=self.aff)
                self.assertIn("gmail_contacts_90d", rep.halted)
                self.assertEqual(fake.payloads, [])

    def test_paying_users_first_and_the_cap_counts_reminders(self):
        paying = os.path.join(self.tmp, "paying.json")
        Path(paying).write_text(json.dumps({"generated_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
                                            "source": "t", "definition": "t", "counts_by_basis": {}, "count": 1,
                                            "ids": [52]}))
        db = verify_ledger.connect(self.path)
        day = (datetime.now(timezone.utc) - timedelta(days=14)).strftime("%Y-%m-%d")
        c = verify_ledger.claim(db, user_key="u50@example.com", day=day, request_ids=["f0"], message_type="email",
                                approved_by=CAPTAIN_UID, approval_ref="ref", windowed=True,
                                refs=[{"request_id": "f0", "profile_id": PID, "track_id": "t-f0"}])
        verify_ledger.finalize(db, message_row=c["message_row"], status="sent", message_id="700")
        db.close()
        rows = [user_req("f1", 51, created="2026-10-14T00:00:00Z"), user_req("f2", 52, created="2026-10-15T00:00:00Z"),
                user_req("f3", 53, created="2026-10-13T00:00:00Z"), user_req("f0", 50)]
        with unittest.mock.patch.dict(os.environ, {}), \
                unittest.mock.patch("credit_review.decide.PAYING_USERS_FILE", Path(paying)):
            rep, fake = self.go(rows, max_users=2)
        sent = [(p["user"]["id"], [c["request_id"] for c in p["credits"]]) for p in fake.payloads]
        self.assertEqual(sent, [("50", ["f0"]), ("52", ["f2"])], "the reminder first, then the paying user")
        self.assertEqual(rep.reminders_sent, 1)
        self.assertEqual(self.deferred(), {"f1", "f3"}, "over the cap: kept for tomorrow")


class TestKillSwitchCli(unittest.TestCase):
    def test_the_kill_switch_stops_apply_but_not_a_read_only_dry_run(self):
        """QA @052f737: the pre-enable --check-recipients dry run runs under the send switch."""
        switch = os.path.join(credit_test_env._dir, "verify-notify.disabled")
        Path(switch).write_text("x")
        env = {**os.environ, "CREDIT_VERIFY_NOTIFY_KILL_SWITCH": switch}
        absent = os.path.join(credit_test_env._dir, "absent-proof.json")
        base = [sys.executable, str(ROOT / "scripts" / "credit-review.py"), "verify-notify", "--proof-on-file", absent]
        res = subprocess.run(base + ["--mode", "apply"], capture_output=True, text=True, timeout=60, env=env, check=False)
        self.assertEqual((res.returncode, res.stdout.strip()), (0, "NO_REPLY"))
        res = subprocess.run(base + ["--mode", "dry-run", "--check-recipients"], capture_output=True, text=True,
                             timeout=60, env=env, check=False)
        self.assertNotEqual(res.stdout.strip(), "NO_REPLY", "the dry run went past the switch")
        self.assertIn("absent-proof.json", res.stdout + res.stderr + Path(credit_test_env.LOG_PATH).read_text())
        res = subprocess.run(base + ["--mode", "apply", "--check-recipients"], capture_output=True, text=True,
                             timeout=60, env=env, check=False)
        self.assertEqual(res.returncode, 2)


class TestLogIsolation(unittest.TestCase):
    def test_tests_and_their_subprocesses_never_log_to_the_production_run_log(self):
        """firstmate 056: PR Validation runs on node-8; a halt line from a test must not reach
        /var/lib/hydra/credit-review/run.log."""
        from credit_review import runner
        self.assertEqual(runner.LOG_PATH, credit_test_env.LOG_PATH)
        self.assertFalse(os.path.realpath(runner.LOG_PATH).startswith("/var/lib/"))
        res = subprocess.run([sys.executable, str(ROOT / "scripts" / "credit-review.py"), "verify-notify",
                              "--removal-due", os.path.join(credit_test_env._dir, "due.jsonl"),
                              "--proof-on-file", os.path.join(credit_test_env._dir, "absent.json")],
                             capture_output=True, text=True, timeout=60, check=False)
        self.assertNotEqual(res.returncode, 0)
        self.assertIn("absent.json is missing", Path(credit_test_env.LOG_PATH).read_text())


if __name__ == "__main__":
    unittest.main(verbosity=2)
