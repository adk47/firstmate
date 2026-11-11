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
import threading
import pathlib
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

from credit_review import affiliation, decline_close, verify_ledger, verify_notify  # noqa: E402
from credit_review import verify_notify as _vn_r5  # noqa: E402
_vn_r5.PRESENTED_LOOKUP = lambda ids: {}  # r5: presented profile ids never come from the replica in tests

# The env vars above are read at import time; another test module in the same process (e.g.
# test_credit_retro via credit_retro.takeback) may have imported these first, so pin them too.
verify_notify.PROOF_ON_FILE = PROOF_FILE
affiliation.PATH = AFFILIATION_FILE

# The replica is never read in tests: every test account's professional id is "test-pro".
verify_notify.IDENTITY_LOOKUP = lambda ids: {str(u): {"professional_id": "test-pro", "auth_id": ""} for u in ids}
from credit_review.verify_notify import CAPTAIN_UID, ContractError, Report  # noqa: E402

PID = "11111111-2222-3333-4444-555555555555"
PID2 = "99999999-2222-3333-4444-555555555555"


def req(rid, *, pid=PID, status="approved", email="jane@example.com", name="Jane Doe", title="Song",
        artist="Big Star", roles=("Mixing",), created="2026-10-15T20:00:00Z", track="t1"):
    return {"id": rid, "profileId": pid, "trackId": track, "status": status, "spotifyTrackTitle": title,
            "spotifyTrackArtists": [{"id": "a", "name": artist}], "credits": list(roles), "createdAt": created,
            "user": {"id": _uid_of(email), "fullName": name, "email": email} if email else None}



class PresentedIdsTests(unittest.TestCase):
    """r5 (Fable [key=x2-sample-1027]): every payload naming a Muso user carries user.presented_ids (the
    account's own presented profiles: the mobile app's Intercom login id), whether or not the producer
    already set the professional id. Additive: an unreadable lookup degrades to today's matcher."""

    def setUp(self):
        self.saved = (verify_notify.PRESENTED_LOOKUP, verify_notify.IDENTITY_LOOKUP)
        verify_notify.IDENTITY_LOOKUP = lambda ids: {str(u): {"professional_id": f"pro-{u}", "auth_id": ""} for u in ids}

    def tearDown(self):
        verify_notify.PRESENTED_LOOKUP, verify_notify.IDENTITY_LOOKUP = self.saved

    def pay(self, uid, **user):
        return {"user": {"email": f"u{uid}@x.com", "id": str(uid), **user}, "credits": [{"request_id": f"r{uid}"}]}

    def test_presented_ids_reach_every_payload_with_a_user(self):
        seen = []
        verify_notify.PRESENTED_LOOKUP = lambda ids: seen.append(list(ids)) or {"45": ["5d0c7c1a-8e2b-4f6d-9a3e-1b7c4d2e6f80", "bad id"], "46": []}
        out, held = verify_notify.attach_identities(
            [self.pay(45), self.pay(46, professional_id="pro-46"), {"user": {"email": "owner@x.com"}, "credits": []}], Report())
        self.assertEqual(held, [])
        self.assertEqual(out[0]["user"]["presented_ids"], ["5d0c7c1a-8e2b-4f6d-9a3e-1b7c4d2e6f80"], "a malformed id is dropped")
        self.assertNotIn("presented_ids", out[1]["user"], "none found: the payload is unchanged")
        self.assertNotIn("presented_ids", out[2]["user"], "no Muso user: nothing to look up")
        self.assertEqual(seen, [["45", "46"]])

    def test_an_unreadable_lookup_degrades_to_the_professional_id_only(self):
        def down(ids):
            raise RuntimeError("trino down")
        verify_notify.PRESENTED_LOOKUP = down
        out, held = verify_notify.attach_identities([self.pay(45)], Report())
        self.assertEqual((out[0]["user"]["professional_id"], "presented_ids" in out[0]["user"], held), ("pro-45", False, []))

    def test_the_real_lookup_uses_the_resolver(self):
        seen = []

        def q(sql):
            seen.append(sql)
            if "neptuneprofessionalid FROM postgresql_core.public.users WHERE id IN" in sql:
                return [["45", "c-45", "pro-45"]]
            if "public.claiming WHERE userid IN" in sql:
                return [["45", "c-45"]]
            if "public.claiming WHERE CAST(profileid AS varchar) IN" in sql:
                return [["c-45", "45", "processed"]]
            if "CAST(representationprofileid AS varchar) IN" in sql:
                return [["45", "pro-45", None, "c-45"]]
            raise AssertionError(sql)
        self.assertEqual(verify_notify.account_presented_ids([45], query=q), {"45": ["c-45"]})


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


# A RELATIVE default: verify_notify.run() looks back since_hours=168 from the real clock, so a fixed
# date made every run-level test fail once it was 7 days old (2026-10-22 22:30Z, all branches).
RECENT = (datetime.now(timezone.utc) - timedelta(hours=1)).strftime("%Y-%m-%dT%H:%M:%SZ")


def dec(rid, outcome="approved", pid=PID, run="run-1", at=None, track="t1", action="approve"):
    at = at or RECENT
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

    def decline(self, day, ids, mid="590", user="a@x.com"):
        """The one reason-free decline (campaign `decline`): a rejected credit is HELD until a SENT decline row
        names it. The decline names no date, so the ORIGINAL note's removal day governs from the moment the
        user has been told."""
        c = verify_ledger.claim(self.db, user_key=user, day=day, request_ids=list(ids), campaign="decline", **self.kw)
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
        self.assertEqual(verify_ledger.reminders_due(self.db, campaign="verify-live", day="2026-11-10"), [],
                         "no follow-up after a rejection: the after-rejection kind is deleted from the "
                         "sender (2026-11-04) and the ledger no longer offers it")
        self.assertEqual(verify_ledger.awaiting_proof(self.db), ["500"], "the sweep watches for a new attachment")
        c = self.decline("2026-11-10", ["r1"])
        self.assertEqual(c["request_ids"], ["r1"], "the decline names the rejected credit")
        self.assertFalse(c["removal_day"], "and it names no date")
        self.assertEqual(self.held(), [], "told: the credit is no longer held for a human")
        self.assertEqual(self.due_ids(day="2026-11-15"), [], "removal stays after the note's own window")
        due = verify_ledger.removal_due(self.db, day="2026-11-16")
        self.assertEqual([(d["request_id"], d["removal_day"]) for d in due], [("r1", "2026-11-16")],
                         "the original note's removal day governs once the user has been told")
        again = verify_ledger.claim(self.db, user_key="a@x.com", day="2026-11-11", request_ids=["r1"],
                                    campaign="decline", **self.kw)
        self.assertEqual(again["result"], "already_notified", "a declined request id is declined once, ever")
        self.assertEqual(verify_ledger.message(self.db, "500")["proof_attachments"], 1)
        row = self.db.execute("SELECT outcome, reviewed_by, reason FROM verify_proof_reviews WHERE request_id='r1'")
        self.assertEqual(tuple(row.fetchone()), ("rejected", "ops-doc-step", "doesnt_name_you"),
                         "the reason and its reviewer stay on the internal row: nothing about them reaches the user")
        later = datetime.now(timezone.utc) + timedelta(hours=1)
        verify_ledger.mark_tagged(self.db, message_id="590", conversation_id="10", attachments=1, now=later)
        self.assertEqual(self.due_ids(), [], "a new document puts the rejected credit back under review")
        self.assertEqual((self.due_ids(), self.held()), ([], [("r1", verify_ledger.HELD_AWAITING_REVIEW)]),
                         "the document the decline invited is a FRESH review's input, so the credit waits for a human "
                         "and is never removed on the strength of the earlier rejection")
        # a resubmission is a new request in core (the decline says "submit the credit again"); this closed one is
        # resolved by a person reading held_for_human, never by the export.
        self.assertEqual(verify_ledger.removal_due(self.db, day="2027-01-01"), [])
        self.assertEqual(self.db.execute("SELECT COUNT(*) FROM verify_proof_reviews WHERE request_id='r1'").fetchone()[0],
                         0, "the new document cleared the old verdict: the fresh review starts from nothing")

    def test_a_tagged_decline_parented_to_a_retro_past_note_is_still_read(self):
        """QA #1718 round 9 (2026-11-06): a decline is parented to the note whose credits it closed, and that note
        may be a `retro-past` one. Reading the FAMILY's campaign made the decline look like a retro-past note, so a
        tagged decline reply was skipped and the fresh review the decline promised never entered the sweep.

        Both halves are asserted in ONE family, so the test proves the gate reads the MESSAGE and not the family: a
        tagged decline in a retro-past family is read, and a tagged non-decline follow-up in that same family is not.
        """
        self.note(campaign="retro-past", windowed=False, ids=("p1",))
        self.assertIsNone(verify_ledger.message(self.db, "500")["removal_day"], "a retro-past note names no date")
        c = self.decline("2026-11-10", ["p1"])
        self.assertEqual(c["result"], "claimed", c)
        parent = self.db.execute("SELECT f.campaign FROM verify_messages m JOIN verify_messages f "
                                 "ON f.id = m.parent_row WHERE m.message_id='590'").fetchone()[0]
        self.assertEqual(parent, "retro-past", "the decline is parented to the retro-past note, not to a decline family")
        # The mirror half. A retro-past note gets no follow-ups from the sender (reminder_state: not_applicable), so
        # the row is written directly: a tagged, sent, non-decline follow-up in the SAME family, whose removal_day is
        # NULL because the family root names no date. It must NOT be read - only a decline restarts the process.
        self.db.execute(
            "INSERT INTO verify_messages (campaign, kind, parent_row, user_key, day, status, message_type, "
            "message_id, request_ids_json, n_credits, approved_by, approval_ref, created_at, updated_at, "
            "proof_tagged_at) VALUES ('retro-past','reminder-14',1,'a@x.com','2026-11-01','sent','email',"
            "'591','[\"p1\"]',1,?,'ref','2026-11-01T00:00:00Z','2026-11-01T00:00:00Z','2026-11-02T00:00:00Z')",
            (CAPTAIN_UID,))
        verify_ledger.mark_tagged(self.db, message_id="590", conversation_id="10", attachments=1)
        read = verify_ledger.awaiting_proof(self.db)
        self.assertIn("590", read,
                      "the reply to a decline is read even when the note it closed was a retro-past one")
        self.assertNotIn("591", read,
                         "a tagged non-decline follow-up in the same family is still not read: only a decline restarts")

    def test_a_multi_note_decline_is_still_read_after_its_first_credit_is_accepted(self):
        """QA #1718 (2026-11-06): one decline can name credits from SEVERAL notes, and it is parented to only one of
        them. Reading the parent note's ids and the parent's reviews meant that once the FIRST credit was accepted
        the whole decline was skipped, so a fresh document for the second credit was never swept."""
        self.note(ids=("r1",), mid="500")
        # A second real note for the SAME user is impossible by design (one ask per user per 90 days, one retro-past
        # note per user ever), so the second family is written directly: a sent verify-live note for r2. The claim
        # gates are not what this test is about - the multi-family READ is.
        self.db.execute(
            "INSERT INTO verify_messages (campaign, kind, user_key, day, due_day, removal_day, status, message_type, "
            "message_id, request_ids_json, n_credits, approved_by, approval_ref, created_at, updated_at) "
            "VALUES ('verify-live','initial','a@x.com','2026-10-24','2026-11-23','2026-11-24','sent','email',"
            "'501','[\"r2\"]',1,?,'ref',?,?)",
            (CAPTAIN_UID, "2026-10-24T00:00:00Z", "2026-10-24T00:00:00Z"))
        c = self.decline("2026-11-10", ["r1", "r2"])
        self.assertEqual(c["request_ids"], ["r1", "r2"], "one decline, two credits, two note families")
        parent = self.db.execute("SELECT f.message_id FROM verify_messages m JOIN verify_messages f "
                                 "ON f.id = m.parent_row WHERE m.message_id='590'").fetchone()[0]
        self.assertEqual(parent, "500", "the decline is parented to the FIRST note only")
        verify_ledger.mark_tagged(self.db, message_id="590", conversation_id="10", attachments=1)
        self.assertEqual(self.review(["r1"], "accepted")["result"], "ok")
        self.assertIn("590", verify_ledger.awaiting_proof(self.db),
                      "r2 is still unreviewed, so the decline's thread is still read: the parent note's acceptance "
                      "cannot close a decline that also named another note's credit")
        self.assertEqual(self.review(["r2"], "accepted", mid="590")["result"], "ok",
                         "the document arrived on the decline thread, and the review is filed under r2's own note")
        self.assertNotIn("590", verify_ledger.awaiting_proof(self.db),
                         "both credits accepted: the decline's thread is done")

    def test_the_proof_review_is_per_credit(self):
        self.note(ids=("r1", "r2", "r3"))
        verify_ledger.mark_tagged(self.db, message_id="500", conversation_id="9", attachments=1)
        self.review(["r1"], "accepted")
        self.review(["r2"], "rejected", reason="other_track")
        self.assertEqual(self.held(), [("r2", verify_ledger.HELD_NOT_TOLD), ("r3", verify_ledger.HELD_AWAITING_REVIEW)],
                         "an unreviewed credit on a tagged note never vanishes from both exports")
        self.assertEqual(verify_ledger.awaiting_proof(self.db), ["500"],
                         "the tagged thread is still read for replies while r3 awaits review")
        self.decline("2026-11-01", ["r2"])
        self.assertEqual(self.due_ids(), ["r2"], "r2: rejected, told, past the note's removal day")
        self.assertEqual(self.held(), [("r3", verify_ledger.HELD_AWAITING_REVIEW)], "r1 verified, r3 awaiting review")
        self.review(["r3"], "rejected")
        self.assertEqual(self.due_ids(), ["r2"], "r3 is never removed before the user is told about it")
        self.assertEqual(self.held(), [("r3", verify_ledger.HELD_NOT_TOLD)])
        self.assertEqual(verify_ledger.reminders_due(self.db, campaign="verify-live", day="2026-11-10"), [],
                         "no day-14 / day-25 reminder about a reviewed credit, and no after-rejection note")

    def test_each_rejected_credit_is_declined_once_in_its_own_message(self):
        self.note(ids=("r1", "r2", "r3"), day="2026-10-01")
        verify_ledger.mark_tagged(self.db, message_id="500", conversation_id="9", attachments=1)
        self.review(["r1"], "accepted")
        self.review(["r2"], "rejected", reason="other_track")
        first = self.decline("2026-10-10", ["r1", "r2"])
        self.assertEqual((first["request_ids"], first["due_day"], first["removal_day"]), (["r2"], None, None),
                         "only the review-rejected credit (r1 was accepted), and the decline names no date")
        self.review(["r3"], "rejected", reason="unreadable")
        second = self.decline("2026-10-25", ["r2", "r3"], mid="591")
        self.assertEqual(second["request_ids"], ["r3"], "the newly rejected credit, never r2 again")
        self.assertEqual(self.db.execute("SELECT request_ids_json FROM verify_messages WHERE message_id='591'")
                         .fetchone()[0], '["r3"]')
        self.assertEqual(self.due_ids(day="2026-10-15"), [], "before the note's reply-by date")
        self.assertEqual(sorted(self.due_ids(day="2026-11-16")), ["r2", "r3"],
                         "the note's own removal day governs, for every told credit")
        again = verify_ledger.claim(self.db, user_key="a@x.com", day="2026-10-26", request_ids=["r3"],
                                    campaign="decline", **self.kw)
        self.assertEqual(again["result"], "already_notified", "at most one decline per credit, ever")

    def test_a_decline_covering_two_notes_reviews_each_credit_in_its_own_family(self):
        # a user whose credits were rejected on two different notes: ONE decline names both (QA #1718 2). Each
        # credit's family is its own note, so a document sent in reply can be reviewed for the second note's
        # credit too — a single parent_row could not carry that.
        self.note(ids=("r1",), day="2026-10-01")
        # a second verify-live note for the same user, past the 90-day one-note lock
        self.note(ids=("r2",), day="2027-01-05", mid="600")
        self.review(["r1"], "rejected")
        self.review(["r2"], "rejected", mid="600")
        c = self.decline("2027-01-20", ["r1", "r2"])
        self.assertEqual(c["request_ids"], ["r1", "r2"], "one decline names both credits")
        self.assertEqual(self.db.execute("SELECT parent_row FROM verify_messages WHERE message_id='590'").fetchone()[0],
                         self.db.execute("SELECT id FROM verify_messages WHERE message_id='500'").fetchone()[0],
                         "the row is filed under the first note it names")
        later = datetime.now(timezone.utc) + timedelta(hours=1)
        verify_ledger.mark_tagged(self.db, message_id="590", conversation_id="10", attachments=1, now=later)
        self.assertEqual(self.db.execute("SELECT COUNT(*) FROM verify_proof_reviews WHERE outcome='rejected'").fetchone()[0],
                         0, "the new document cleared BOTH notes' rejected verdicts, not only the first")
        second = verify_ledger.record_proof_review(self.db, message_id="590", request_ids=["r2"], outcome="accepted",
                                                   reviewer="ops-doc-step", now=later + timedelta(hours=1))
        self.assertEqual(second, {"result": "ok", "outcome": "accepted", "request_ids": ["r2"]},
                         "the second note's credit is reviewable through the decline: no not_on_note")
        self.assertEqual(self.db.execute("SELECT family FROM verify_proof_reviews WHERE request_id='r2'").fetchone()[0],
                         self.db.execute("SELECT id FROM verify_messages WHERE message_id='600'").fetchone()[0],
                         "the verdict lives under r2's own note family, which is what the per-credit reads join on")
        self.assertEqual(self.due_ids(day="2027-02-10"), [],
                         "r2 is verified; r1 is still rejected and now awaits its fresh review")
        self.assertEqual(self.held(day="2027-02-10"), [("r1", verify_ledger.HELD_AWAITING_REVIEW)])
        self.assertEqual(verify_ledger.record_proof_review(
            self.db, message_id="500", request_ids=["r2"], outcome="accepted", reviewer="x")["result"],
            "not_on_note", "a credit another note asked about is still refused on THAT note's own thread")

    def test_close_since_is_the_credits_own_close_not_a_fixed_window(self):
        # the send gate's window (QA #1718 B): a core note about an EARLIER close must not suppress this one, and an
        # old close must not fall outside the read and let a second decline through
        self.note(ids=("r1", "r2"), day="2026-10-01")
        verify_ledger.mark_tagged(self.db, message_id="500", conversation_id="9", attachments=1)
        self.review(["r1"], "rejected")
        closed = self.db.execute("SELECT reviewed_at FROM verify_proof_reviews WHERE request_id='r1'").fetchone()[0]
        out = verify_ledger.close_since(self.db, ["r1"])
        self.assertRegex(out["since"], r"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$")
        self.assertLess(out["since"], closed, "the read starts a day BEFORE the close, for clock and propagation")
        # the note day is a hard floor (QA #1718, 2026-11-06): a request cannot be closed before it was asked, and a
        # note's day is written once, so the window can never move past a core email we cannot see
        self.assertEqual(out["since"][:10], "2026-09-30", "the note that asked for r1 went out on 2026-10-01")
        # a credit no review names (a human closed it in core) falls back to the note that asked for it: a LONGER
        # window, which can only ever move toward silence
        self.assertEqual(verify_ledger.close_since(self.db, ["r2"])["since"][:10], "2026-09-30")
        self.assertEqual(verify_ledger.close_since(self.db, ["zz"])["since"], None,
                         "nothing in the ledger names this credit: no window, so the gate holds")
        self.assertEqual(verify_ledger.close_since(self.db, [])["since"], None)

    def test_the_close_boundary_never_moves_forward_on_a_re_rejection(self):
        # QA #1718 (2026-11-06): `verify_proof_reviews.reviewed_at` is overwritten by a re-rejection and `mark_tagged`
        # deletes the old verdict, so a review timestamp alone moves FORWARD. If the boundary moved, a later
        # re-rejection would exclude core's EARLIER decline email, a zero count would read as "core never told them",
        # and hydra would send a SECOND decline for the same request - the one forbidden outcome. The note day is the
        # immutable floor, so the window can only ever widen.
        self.note(ids=("r1",), day="2026-10-01")
        verify_ledger.mark_tagged(self.db, message_id="500", conversation_id="9", attachments=1)
        first = datetime(2026, 10, 5, 12, 0, tzinfo=timezone.utc)
        self.review(["r1"], "rejected")
        self.db.execute("UPDATE verify_proof_reviews SET reviewed_at=? WHERE request_id='r1'",
                        (verify_ledger.stamp(first),))
        self.assertEqual(verify_ledger.close_since(self.db, ["r1"])["since"][:10], "2026-09-30")
        # a NEW document clears the verdict, then a LATER review rejects the same credit again
        verify_ledger.mark_tagged(self.db, message_id="500", conversation_id="9", attachments=2,
                                  now=first + timedelta(days=20))
        self.assertEqual(self.db.execute("SELECT COUNT(*) FROM verify_proof_reviews WHERE outcome='rejected'")
                         .fetchone()[0], 0, "the fresh document cleared the old verdict")
        self.review(["r1"], "rejected")
        self.assertEqual(verify_ledger.close_since(self.db, ["r1"])["since"][:10], "2026-09-30",
                         "the boundary is the note day, so core's earlier decline email stays inside the window")

    def test_a_credit_no_note_names_still_resolves_from_its_reviews(self):
        # a credit asked outside this ledger has no note day to floor the window: its own review is the boundary
        self.note(ids=("r1",), day="2026-10-01")
        verify_ledger.mark_tagged(self.db, message_id="500", conversation_id="9", attachments=1)
        self.review(["r1"], "rejected")
        self.db.execute("UPDATE verify_messages SET request_ids_json='[\"other\"]'")
        out = verify_ledger.close_since(self.db, ["r1"])
        self.assertIsNotNone(out["since"], "the review still names it")
        self.assertIn("earliest rejection", out["why"])

    def test_a_reply_after_the_decline_holds_the_credit_for_a_human(self):
        self.note(day="2026-10-01")
        verify_ledger.mark_tagged(self.db, message_id="500", conversation_id="9", attachments=1)
        self.review(["r1"], "rejected")
        self.decline("2026-10-20", ["r1"])
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
        with self.assertRaises(ValueError):
            verify_ledger.mark_replied(self.db, message_id="590", replied_at="yesterday")

    def test_two_notes_for_one_credit_never_release_the_other(self):
        """The r1/r2 case END TO END, with the REAL reader (QA #1718, 2026-11-06): r1 is rejected twice, so the send
        ledger shows two `credits_rejected` notes for this user, while r2's email never went out. A per-user count
        cannot tell the two apart, so neither credit may be released - and r2 in particular must not be, because no
        decline for r2 ever reached the customer. This joins the two halves (the reader and the ledger) in one test
        so a future change to either cannot quietly restore the count."""
        self.note(ids=("r1", "r2"))
        self.db.execute("UPDATE verify_messages SET account_id='42' WHERE message_id='500'")
        verify_ledger.mark_tagged(self.db, message_id="500", conversation_id="9", attachments=1)
        self.review(["r1", "r2"], "rejected")
        # the real reader, with two notes in the ledger that both belong to r1
        def real(user_key, user_id, ids, since):
            return decline_close.core_told(user_key, user_id, ids, since, route="routed", notes={42: 2})
        self.assertEqual(real("a@x.com", "42", ["r1", "r2"], "2026-10-05T12:00:00Z"),
                         {"r1": False, "r2": False}, "two notes for r1 cannot say r2 was told")
        self.assertEqual(verify_ledger.removal_due(self.db, day="2026-11-20", core_told=real), [],
                         "neither credit is released on a count that cannot name a request")
        self.assertEqual([(h["request_id"], h["reason"]) for h in
                          verify_ledger.held_for_human(self.db, day="2026-11-20", core_told=real)],
                         [("r1", verify_ledger.HELD_NOT_ATTRIBUTABLE),
                          ("r2", verify_ledger.HELD_NOT_ATTRIBUTABLE)],
                         "r2 is held, not released: no decline for r2 ever reached the customer")

    def test_core_sent_declines_release_a_rejected_credit_for_removal(self):
        # QA #1718 (2026-11-06): with core's own credits_rejected email routed, hydra writes NO `decline` row, so a
        # removal decision that reads only hydra's ledger holds every rejected credit as never-told forever. The
        # reader answers for core; an unreadable route holds, and a route measured OFF leaves hydra's row in charge.
        self.note(ids=("r1",))
        verify_ledger.mark_tagged(self.db, message_id="500", conversation_id="9", attachments=1)
        self.review(["r1"], "rejected")
        self.assertEqual(self.held(), [("r1", verify_ledger.HELD_NOT_TOLD)], "nobody has told them yet")
        # THE REAL READER TODAY (QA #1718 round 7, 2026-11-06): core's route is on and the ledger shows a note, but no
        # store we can read carries a request id, so the note cannot be attributed to THIS credit. That is a HOLD with
        # its own reason - not "not told" (a note exists) and not a release (we cannot prove it was this one).
        unattributable = lambda *a: {"r1": False}  # noqa: E731
        self.assertEqual([(h["request_id"], h["reason"]) for h in
                          verify_ledger.held_for_human(self.db, day="2026-11-20", core_told=unattributable)],
                         [("r1", verify_ledger.HELD_NOT_ATTRIBUTABLE)])
        self.assertEqual(verify_ledger.removal_due(self.db, day="2026-11-20", core_told=unattributable), [],
                         "an unattributable note never releases a credit")
        # THE CONTRACT FOR THE DAY CORE'S EMAIL CARRIES A REQUEST ID: a True is a per-request delivery and releases.
        # `core_told` cannot return True today (see test_decline_close), so this pins the ledger half only.
        routed = lambda *a: {"r1": True}  # noqa: E731
        self.assertEqual([d["request_id"] for d in verify_ledger.removal_due(self.db, day="2026-11-20",
                                                                           core_told=routed)], ["r1"])
        self.assertEqual(verify_ledger.held_for_human(self.db, day="2026-11-20", core_told=routed), [])
        self.assertEqual(self.held(), [("r1", verify_ledger.HELD_NOT_TOLD)],
                         "no reader supplied: hydra's own sent decline is the only telling")
        self.assertEqual(self.held(), [("r1", verify_ledger.HELD_NOT_TOLD)])
        self.assertEqual([(h["request_id"], h["reason"]) for h in
                          verify_ledger.held_for_human(self.db, day="2026-11-20", core_told=lambda *a: None)],
                         [("r1", verify_ledger.HELD_NOT_TOLD)], "an unreadable route holds, never releases")
        self.assertEqual([(h["request_id"], h["reason"]) for h in
                          verify_ledger.held_for_human(self.db, day="2026-11-20", core_told=lambda *a: {})],
                         [("r1", verify_ledger.HELD_NOT_TOLD)], "route off and no hydra decline: still not told")
        # a reply after core's email holds it for a human, exactly as a reply after hydra's decline does
        later = (datetime.now(timezone.utc) + timedelta(hours=1)).strftime("%Y-%m-%dT%H:%M:%SZ")
        verify_ledger.mark_replied(self.db, message_id="500", replied_at=later)
        self.assertEqual([(h["request_id"], h["reason"]) for h in
                          verify_ledger.held_for_human(self.db, day="2026-11-20", core_told=routed)],
                         [("r1", verify_ledger.HELD_REPLIED)])

    def test_a_reply_in_the_tagged_original_thread_after_a_decline_holds_the_credit(self):
        self.note(ids=("r1", "r2", "r3"), day="2026-10-01")
        verify_ledger.mark_tagged(self.db, message_id="500", conversation_id="9", attachments=1)
        self.review(["r1"], "accepted")
        self.review(["r2"], "rejected", reason="other_track")
        self.decline("2026-10-10", ["r2"])
        self.assertEqual(verify_ledger.awaiting_proof(self.db), ["500", "590"],
                         "the tagged original thread and the decline are both read while r2 is rejected and r3 awaits "
                         "review")
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
        c = verify_ledger.claim(self.db, user_key="a@x.com", day="2026-10-25", request_ids=["r3"],
                                campaign="decline", approved_by=CAPTAIN_UID, approval_ref="ref",
                                message_type="email", now=soon - timedelta(days=10))
        self.assertEqual(c["result"], "claimed")
        verify_ledger.finalize(self.db, message_row=c["message_row"], status="sent", message_id="591")
        self.assertEqual(verify_ledger.awaiting_proof(self.db, now=soon), ["500", "590", "591"],
                         "every thread of the note and every decline of it is read while recent")

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
        row = self.db.execute("SELECT outcome, reason FROM verify_proof_reviews WHERE request_id='r1'").fetchone()
        self.assertEqual(tuple(row), ("rejected", None), "no reason: the user replied but sent no document to read")
        c = self.decline("2026-10-20", ["r1"])
        self.assertEqual(c["request_ids"], ["r1"], "the decline still goes out, reason-free")

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
        self.decline("2026-11-20", ["r2"])
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
        # The WINDOW on its own: firstmate 768's backfill is a separate, bounded rule, so this
        # test disables it and still pins the outcome-time cut exactly as before.
        self.assertEqual([r for r, _, _ in verify_notify.candidates(db, since_hours=24, now=now,
                                                                   never_asked_days=0)], ["new"])
        # With the default backfill, "old" is inside never_asked_days and no note ever asked
        # about it, so the window no longer decides whether it may be asked at all.
        self.assertEqual([r for r, _, _ in verify_notify.candidates(db, since_hours=24, now=now)],
                         ["old", "new"])

    def test_a_credit_that_aged_out_of_the_window_is_still_askable_if_no_note_ever_asked(self):
        """firstmate 768: 279 provisional credits (63 accounts) had NO delivered ask after 48 h.
        The window is a cap on re-reading, never a reason to abandon a credit nobody asked
        about: a 10-day-old approval with no delivered note is a candidate; the same age WITH a
        delivered note is not (its own clock runs from that send)."""
        decisions_db(self.path, [dec("asked", at=_ago(240)), dec("never", at=_ago(240)),
                                 dec("too_old", at=_ago(24 * 40))])
        db = self.open()
        c = verify_ledger.claim(db, user_key="asked@x.com", day="d", request_ids=["asked"], message_type="email",
                                approved_by=CAPTAIN_UID, approval_ref="ref")
        verify_ledger.finalize(db, message_row=c["message_row"], status="sent", message_id="1")
        now = datetime.now(timezone.utc)
        got = [r for r, _, _ in verify_notify.candidates(db, since_hours=168, now=now)]
        self.assertEqual(got, ["never"], "the old ask keeps its own clock; the never-asked one is reachable")
        self.assertEqual([r for r, _, _ in verify_notify.candidates(db, since_hours=168, now=now,
                                                                   never_asked_days=0)], [],
                         "0 disables the backfill, so the window is strictly a window")
        self.assertNotIn("too_old", [r for r, _, _ in verify_notify.candidates(db, since_hours=168, now=now)],
                         "the backfill is BOUNDED: 40 days back is outside never_asked_days")

    def test_the_backfill_never_reopens_a_credit_the_ledger_already_refused(self):
        decisions_db(self.path, [dec("refused", at=_ago(240))])
        db = self.open()
        c = verify_ledger.claim(db, user_key="r@x.com", day="d", request_ids=["refused"], message_type="email",
                                approved_by=CAPTAIN_UID, approval_ref="ref")
        verify_ledger.finalize(db, message_row=c["message_row"], status="refused", message_id="")
        self.assertEqual(verify_notify.candidates(db, since_hours=168), [],
                         "a refusal closes the credit for good; the backfill must not re-open it")


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

    def test_band_a_row_gets_no_verify_note_and_never_expires(self):
        """Fable 2026-10-22 23:10Z (firstmate 095): core stamps every automation approval
        provisional; a trusted-anchor (band A) one gets NO document ask, is closed in the ledger
        so it is never offered again, and so is never reminded or removal-due."""
        decisions_db(self.path, [dec("r1"), dec("r2")])
        band_a = req("r1")
        band_a["metadata"] = {"approval": {"via": "score-approve", "isAgent": True, "provisional": True,
                                           "proofDueAt": "2026-11-21T00:00:00Z", "anchor_kind": "trusted"}}
        band_b = req("r2")
        band_b["metadata"] = {"approval": {"via": "score-approve", "isAgent": True, "provisional": True,
                                           "proofDueAt": "2026-11-21T00:00:00Z", "anchor_kind": "none"}}
        fake = Fake()
        rep = verify_notify.run(FakeAdmin([band_a, band_b]), ledger_path=self.path, mode="apply", runner=fake,
                                wrapper="/w")
        self.assertEqual([c["request_id"] for p in fake.payloads for c in p["credits"]], ["r2"])
        self.assertEqual(rep.trusted_anchor, 1)
        db = verify_ledger.connect(self.path)
        self.addCleanup(db.close)
        self.assertEqual(verify_ledger.blocked_ids(db, ["r1"]), {"r1"})        # closed: never offered again
        for day in ("2026-12-01", "2027-06-01"):
            self.assertNotIn("r1", {str(x.get("request_id")) for x in
                                    verify_ledger.removal_due(db, day=day) if isinstance(x, dict)})
        self.assertNotIn("r1", [rid for rid, _, _ in verify_notify.candidates(db)])
        self.assertTrue(verify_notify.trusted_anchor({"metadata": {"approval": {"anchor_kind": "trusted"}}}))
        self.assertFalse(verify_notify.trusted_anchor({"metadata": {"approval": {"anchorKind": "Trusted"}}}))
        self.assertFalse(verify_notify.trusted_anchor({"metadata": {"approval": {"anchor_kind": "Trusted"}}}))
        self.assertFalse(verify_notify.trusted_anchor({"metadata": {"approval": {"provisional": True}}}))

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

    def test_a_timed_out_note_step_is_UNMEASURED_and_never_aborts_the_batch(self):
        """firstmate 748 / the 15:05Z auto-kill: one note step hit a 180 s timeout inside the gate call, the exception
        escaped the send loop, and the run died before writing its outcomes file - the tick then read the missing
        artefact as a refusal spike and killed itself while every note it had not reached stayed owed. A timeout is now
        an outcome the report carries (UNMEASURED, never a refusal), so the file is always written and the batch goes on.
        """
        decisions_db(self.path, [dec("r1"), dec("r2", pid=PID2)])
        admin = FakeAdmin([req("r1"), req("r2", pid=PID2, email="bob@example.com")])

        class OneTimesOut(Fake):
            def __call__(self, args):
                if args[1] == "send":
                    who = json.loads(Path(args[args.index("--credits-file") + 1]).read_text())["user"]["email"]
                    if who == "jane@example.com":
                        raise verify_notify.NoteTimeout("the note step timed out after 3 attempt(s) of 180s")
                return super().__call__(args)

        rep = verify_notify.run(admin, ledger_path=self.path, mode="apply", runner=OneTimesOut(), wrapper="/w")
        self.assertEqual(rep.timeout_users, 1)
        self.assertEqual(rep.sent_notes, 1)                      # the other account was still served
        self.assertFalse(rep.failed, "an unknown outcome is not a failed run: the artefact must still be written")
        self.assertEqual([o for o in rep.outcomes if o["result"].startswith("refused")], [])
        timed = [o for o in rep.outcomes if o["result"] == "timeout"]
        self.assertEqual(len(timed), 1)
        self.assertIn("outcome unknown", timed[0]["reason"])
        self.assertIn("UNMEASURED", rep.render("apply"))          # the summary says it, so the operator sees it
        self.assertNotIn("refused by the gate", rep.render("apply"))

    @staticmethod
    def _timeout_then(rc, out, err=""):
        """A real `_run` whose FIRST attempt times out and whose retry answers (rc, out, err)."""
        calls = {"n": 0}

        def fake_run(argv, **kw):
            calls["n"] += 1
            if calls["n"] == 1:
                raise subprocess.TimeoutExpired(argv, kw.get("timeout") or 1)
            return subprocess.CompletedProcess(argv, rc, out + "\n", err)

        return fake_run

    def test_a_timeout_then_a_REFUSED_retry_is_UNMEASURED_never_a_refusal(self):
        """QA #1756 Important 1 (r12): `after_timeout` was read only on rc=0, so a timed-out POST whose retry answered
        rc=1 REFUSED was scored as a REFUSAL - blaming the user for our timeout, and able to trip the refusal-spike
        kill on a run where nothing was refused. The gate claims the user BEFORE it posts, so the retry's REFUSED
        cannot settle whether the first attempt landed. UNMEASURED, and the run is not failed."""
        decisions_db(self.path, [dec("r1")])
        admin = FakeAdmin([req("r1")])
        with unittest.mock.patch.object(verify_notify.subprocess, "run",
                                        self._timeout_then(1, "", "REFUSED user already messaged in the last 7 days")), \
             unittest.mock.patch.object(verify_notify.time, "sleep", lambda *_: None):
            rep = verify_notify.run(admin, ledger_path=self.path, mode="apply", wrapper="/w")
        self.assertEqual((rep.timeout_users, rep.refused_users, rep.sent_notes), (1, 0, 0))
        self.assertEqual([o["result"] for o in rep.outcomes], ["timeout"])
        self.assertIn("rc=1", rep.outcomes[0]["reason"])
        self.assertFalse(rep.failed, "an unknown outcome is not a failed run: the artefact must still be written")
        self.assertIn("UNMEASURED", rep.render("apply"))

    def test_a_timeout_then_a_DEFERRED_retry_is_UNMEASURED_never_a_known_deferral(self):
        """QA #1756 Important 1 (r12), the rc=3 half: a timed-out POST whose retry answered DEFERRED was recorded as a
        KNOWN deferral, which asserts a certainty the run does not have - the first attempt may have landed. Same
        classification as the rc=1 case: UNMEASURED."""
        decisions_db(self.path, [dec("r1")])
        admin = FakeAdmin([req("r1")])
        with unittest.mock.patch.object(verify_notify.subprocess, "run",
                                        self._timeout_then(3, "DEFERRED messaged_7d")), \
             unittest.mock.patch.object(verify_notify.time, "sleep", lambda *_: None):
            rep = verify_notify.run(admin, ledger_path=self.path, mode="apply", wrapper="/w")
        self.assertEqual((rep.timeout_users, rep.deferred_users, rep.sent_notes), (1, 0, 0))
        self.assertEqual([o["result"] for o in rep.outcomes], ["timeout"])
        self.assertIn("rc=3", rep.outcomes[0]["reason"])
        self.assertFalse(rep.failed)

    def test_a_timeout_then_a_POST_FAILED_retry_stays_post_failed(self):
        """The one exception: the gate's explicit POST FAILED line is its own unknown (post_failed), which the tick's
        arm reads to kill. A timeout before it must not reclassify it into the quieter `timeout` bucket."""
        decisions_db(self.path, [dec("r1")])
        admin = FakeAdmin([req("r1")])
        with unittest.mock.patch.object(verify_notify.subprocess, "run",
                                        self._timeout_then(4, "", "POST FAILED: the note may or may not have landed")), \
             unittest.mock.patch.object(verify_notify.time, "sleep", lambda *_: None):
            rep = verify_notify.run(admin, ledger_path=self.path, mode="apply", wrapper="/w")
        self.assertEqual((rep.post_failed_users, rep.timeout_users), (1, 0))
        self.assertEqual([o["result"] for o in rep.outcomes], ["post_failed"])
        self.assertTrue(rep.failed)

    def test_a_gate_that_raises_is_recorded_per_user_and_never_costs_the_artefact(self):
        decisions_db(self.path, [dec("r1"), dec("r2", pid=PID2)])
        admin = FakeAdmin([req("r1"), req("r2", pid=PID2, email="bob@example.com")])

        class OneExplodes(Fake):
            def __call__(self, args):
                if args[1] == "send":
                    who = json.loads(Path(args[args.index("--credits-file") + 1]).read_text())["user"]["email"]
                    if who == "jane@example.com":
                        raise RuntimeError("subprocess died in an unexpected way")
                return super().__call__(args)

        rep = verify_notify.run(admin, ledger_path=self.path, mode="apply", runner=OneExplodes(), wrapper="/w")
        self.assertEqual(rep.error_users, 1)
        self.assertEqual(rep.sent_notes, 1)
        self.assertEqual([o["result"] for o in rep.outcomes], ["error"])
        self.assertIn("RuntimeError", rep.outcomes[0]["reason"])
        self.assertFalse(rep.failed)

    def test_a_run_of_only_unknown_outcomes_still_reports(self):
        """QA #1756 finding 2: render() returned NO_REPLY before it reached the UNMEASURED clause, so the one run that
        most needs a human - every selected user timed out or crashed - was the silent one."""
        class AllUnknown(Fake):
            def __call__(self, args):
                if args[1] == "send":
                    raise verify_notify.NoteTimeout("the note step timed out after 3 attempt(s) of 180s")
                return super().__call__(args)

        decisions_db(self.path, [dec("r1")])
        rep = verify_notify.run(FakeAdmin([req("r1")]), ledger_path=self.path, mode="apply",
                                runner=AllUnknown(), wrapper="/w")
        self.assertEqual((rep.sent_notes, rep.timeout_users), (0, 1))
        out = rep.render("apply")
        self.assertNotEqual(out, "NO_REPLY", "an all-unknown run must say so")
        self.assertIn("UNMEASURED", out)
        # the negative control: an apply that did nothing at all is still quiet (the early return is not disabled)
        self.assertEqual(verify_notify.Report().render("apply"), "NO_REPLY")
        self.assertNotEqual(verify_notify.Report(error_users=1).render("apply"), "NO_REPLY")
        self.assertNotEqual(verify_notify.Report(timeout_users=1).render("apply"), "NO_REPLY")

    def test_the_send_loop_never_starts_a_user_whose_worst_case_would_not_fit_the_budget(self):
        """[key=note-step-budget] (Fable 753): the amendment that pays for APPLY_S_PER_USER being the EXPECTED cost.

        3 x 55 + 35 = 200 s worst case per user. With a 40 s expected cost the tick sizes an apply at ~165 users; without
        a guard, a run of slow users would carry the family past its share and it would defer every tick (the 11-02
        livelock). The loop therefore refuses to START a user whose whole retry budget does not fit what is left, and the
        users it never started are DEFERRED - they keep no claim, stay owed, and are never scored as refusals."""
        payloads = [{"user": {"id": str(i), "email": f"u{i}@x.com"}, "credits": [{"request_id": f"r{i}"}]}
                    for i in range(5)]
        clock = {"t": 0.0}
        started = []

        def run(argv):
            started.append(argv[argv.index("--credits-file") + 1])
            clock["t"] += 120.0                      # one user eats most of a 200 s share
            return subprocess.CompletedProcess(argv, 0, "POSTED email message=1 credits=1\n", "")

        rep = verify_notify.Report()
        with unittest.mock.patch.object(verify_notify, "attach_identities", lambda ps, r: (ps, [])), \
             unittest.mock.patch.object(verify_notify, "APPLY_WORKERS", 1), \
             unittest.mock.patch.object(verify_notify.time, "monotonic", lambda: clock["t"]), \
             unittest.mock.patch.object(verify_notify.time, "sleep", lambda s: None):
            try:
                verify_notify.set_apply_budget(200)  # room for ONE worst-case user, never two
                verify_notify.send_all(payloads, rep, mode="apply", runner=run, extra=["--campaign", "uvn-status"])
            finally:
                verify_notify.set_apply_budget(None)
        self.assertEqual(len(started), 1, "only the user the budget could fit was started")
        self.assertEqual(rep.budget_deferred_users, 4)
        self.assertEqual(rep.deferred_users, 4)
        self.assertEqual(rep.refused_users, 0, "a budget deferral is never a refusal")
        deferred = [o for o in rep.outcomes if o["result"] == "deferred"]
        self.assertEqual(len(deferred), 4)
        self.assertTrue(all("apply_budget" in o["reason"] for o in deferred))
        self.assertIn("not started this run", rep.render("apply"))
        # negative control: no budget set (a hand-run apply) -> no guard, every user is attempted
        rep2 = verify_notify.Report()
        with unittest.mock.patch.object(verify_notify, "attach_identities", lambda ps, r: (ps, [])), \
             unittest.mock.patch.object(verify_notify.time, "sleep", lambda s: None):
            verify_notify.send_all(payloads[:3], rep2, mode="apply", runner=run, extra=["--campaign", "uvn-status"])
        self.assertEqual((rep2.deferred_users, rep2.budget_deferred_users), (0, 0))

    def test_the_apply_budget_is_ONE_run_clock_not_reset_by_every_per_user_call(self):
        """QA #1756 Critical: uvn_status.run() calls send_all([p]) once per USER, and the loop measured the budget from
        its own call - so N per-user calls each got the whole share, a run of slow notes overran the tick's share by N
        times and hit its hard deadline mid-apply (a partial send, then the 15:05Z auto-kill). The clock is the apply
        SESSION's: one run, whatever number of send_all calls it makes."""
        clock = {"t": 1000.0}
        started = []
        payloads = [{"user": {"id": str(i), "email": f"u{i}@x.com"}, "credits": [{"request_id": f"r{i}"}]}
                    for i in range(3)]

        def run(argv):
            started.append(argv[argv.index("--credits-file") + 1])
            clock["t"] += 60.0                       # each user eats 60 s of a 300 s run share
            return subprocess.CompletedProcess(argv, 0, "POSTED email message=1 credits=1\n", "")

        rep = verify_notify.Report()
        with unittest.mock.patch.object(verify_notify, "attach_identities", lambda ps, r: (ps, [])), \
             unittest.mock.patch.object(verify_notify.time, "monotonic", lambda: clock["t"]), \
             unittest.mock.patch.object(verify_notify.time, "sleep", lambda s: None), \
             unittest.mock.patch.object(verify_notify, "_apply_lock", lambda: unittest.mock.MagicMock()), \
             verify_notify.apply_session():
            try:
                verify_notify.set_apply_budget(300)
                for p_ in payloads:                  # exactly the real caller's shape: one send_all per user
                    verify_notify.send_all([p_], rep, mode="apply", runner=run, extra=["--campaign", "uvn-status"])
            finally:
                verify_notify.set_apply_budget(None)
        # 60 s per user from ONE clock, 200 s worst case each: user 1 starts at 0 s, user 2 at 60 s (260 of 300),
        # user 3 at 120 s (320 of 300) does not fit. Before the fix every call restarted the clock at 0, so all THREE
        # started and the family could overrun the tick's share by one whole budget per extra user.
        self.assertEqual(len(started), 2, "the third user's worst case does not fit the RUN's remaining share")
        self.assertEqual(rep.sent_notes, 2)
        self.assertEqual(rep.budget_deferred_users, 1)
        self.assertEqual(rep.refused_users, 0)
        deferred = [o for o in rep.outcomes if o["result"] == "deferred"]
        self.assertEqual(len(deferred), 1)
        self.assertIn("apply_budget", deferred[0]["reason"])

    def test_a_timeout_followed_by_an_already_notified_retry_stays_UNMEASURED_and_is_never_a_skip(self):
        """QA #1756 Important 2: the gate claims the user BEFORE it posts, so when the first POST times out and the
        retry answers 'already notified', the run cannot tell 'the timed-out POST landed' from 'it died after
        claiming'. Recording that as `skipped` asserts we know nothing went out - we do not."""
        import subprocess as sp
        calls = []

        def fake_run(argv, **kw):
            calls.append(argv)
            if len(calls) == 1:
                raise sp.TimeoutExpired(argv, verify_notify.NOTE_TIMEOUT_S)
            return sp.CompletedProcess(argv, 0, "SKIPPED already-notified user=5\n", "")

        rep = verify_notify.Report()
        p = {"user": {"id": "5", "email": "u5@x.com"}, "credits": [{"request_id": "r5"}]}
        with unittest.mock.patch.object(verify_notify, "attach_identities", lambda ps, r: (ps, [])), \
             unittest.mock.patch.object(verify_notify.time, "sleep", lambda s: None), \
             unittest.mock.patch.object(verify_notify.subprocess, "run", side_effect=fake_run):
            verify_notify.send_all([p], rep, mode="apply", extra=["--campaign", "uvn-status"])
        self.assertEqual(len(calls), 2, "a note POST is retried once after a timeout")
        self.assertEqual((rep.skipped, rep.timeout_users, rep.sent_notes), (0, 1, 0))
        unknown = [o for o in rep.outcomes if o["result"] == "timeout"]
        self.assertEqual(len(unknown), 1)
        self.assertIn("never scored as a skip", unknown[0]["reason"])
        # negative control: an already-notified answer with NO earlier timeout is still an ordinary skip
        rep2 = verify_notify.Report()
        with unittest.mock.patch.object(verify_notify, "attach_identities", lambda ps, r: (ps, [])), \
             unittest.mock.patch.object(verify_notify.subprocess, "run",
                                        side_effect=lambda argv, **kw: sp.CompletedProcess(argv, 0, "SKIPPED already-notified\n", "")):
            verify_notify.send_all([p], rep2, mode="apply", extra=["--campaign", "uvn-status"])
        self.assertEqual((rep2.skipped, rep2.timeout_users), (1, 0))

    def test_the_note_step_retries_a_timeout_with_backoff_then_gives_up(self):
        """Bounded retry with backoff on the ONE failure whose outcome is unknown. Safe because the gate writes its claim
        BEFORE it posts: a re-run of the same user finds the claim and never posts a second note."""
        import subprocess as sp
        sleeps = []
        real_sleep = verify_notify.time.sleep
        verify_notify.time.sleep = lambda s: sleeps.append(s)
        try:
            with unittest.mock.patch.object(verify_notify.subprocess, "run",
                                            side_effect=sp.TimeoutExpired("x", verify_notify.NOTE_TIMEOUT_S)) as run:
                with self.assertRaises(verify_notify.NoteTimeout):
                    verify_notify._run(["/opt/hydra/scripts/intercom-verify-request.sh", "send"])
        finally:
            verify_notify.time.sleep = real_sleep
        self.assertEqual(run.call_count, verify_notify.NOTE_ATTEMPTS)
        self.assertEqual(run.call_args.kwargs["timeout"], verify_notify.NOTE_TIMEOUT_S)
        self.assertEqual(sleeps, list(verify_notify.NOTE_BACKOFF_S))    # one backoff per gap, then give up

    def test_the_tick_models_the_expected_cost_and_the_loop_guards_the_worst_case(self):
        """d2 r5 (750), amended by Fable 753: TWO numbers, pinned to the code that owns each.

        APPLY_S_PER_USER is the EXPECTED cost and it is what sizes the apply (fit = remaining / expected). Sizing the
        apply at the WORST case to survive a 1-in-80 event cut throughput 3x (fit = remaining / 200 = ~25 users a tick),
        so the worst case is bounded by the SEND LOOP instead: it will not START a user whose whole retry budget would
        not fit the share it was handed. This test holds both sides: the tick's expected cost is the smaller number, and
        the tick's APPLY_USER_WORST_S equals this module's derived worst case, so neither can drift silently."""
        worst = verify_notify.NOTE_ATTEMPTS * verify_notify.NOTE_TIMEOUT_S + sum(verify_notify.NOTE_BACKOFF_S)
        self.assertEqual(worst, verify_notify.WORST_USER_S, "WORST_USER_S must be derived, never a second literal")
        src = (pathlib.Path(__file__).resolve().parents[2] / "scripts" / "credit-verify-outbound.sh").read_text()
        exp = re.search(r'APPLY_S_PER_USER="\$\(cfg CVO_APPLY_S_PER_USER (\d+)\)"', src)
        got = re.search(r'APPLY_USER_WORST_S="\$\(cfg CVO_APPLY_USER_WORST_S (\d+)\)"', src)
        self.assertIsNotNone(exp, "APPLY_S_PER_USER must be a literal default the tick can be held to")
        self.assertIsNotNone(got, "APPLY_USER_WORST_S must be a literal default the tick can be held to")
        self.assertEqual(int(got.group(1)), worst,
                         f"the tick guards {got.group(1)}s per user but one slow user can cost {worst}s")
        self.assertLess(int(exp.group(1)), worst,
                        "the sizing number is the EXPECTED cost; guarding at the worst case sizes the apply 3x too small")
        self.assertIn("--apply-budget-s", src, "the apply must hand the loop the share it may spend")

    def test_a_read_only_gate_call_is_never_retried_and_caps_short(self):
        """d2 r5 (750): CHECK_WORKERS read-only calls run in parallel, so a retry there multiplies across threads and no
        read-only call posts anything. One short attempt, then NoteTimeout."""
        import subprocess as sp
        sleeps = []
        real_sleep = verify_notify.time.sleep
        verify_notify.time.sleep = lambda s: sleeps.append(s)
        try:
            for flag in ("--check-recipient", "--validate", "--dry-run"):
                with unittest.mock.patch.object(verify_notify.subprocess, "run",
                                                side_effect=sp.TimeoutExpired("x", 1)) as run:
                    with self.assertRaises(verify_notify.NoteTimeout):
                        verify_notify._run(["/opt/hydra/scripts/intercom-verify-request.sh", "send", flag])
                self.assertEqual(run.call_count, 1, flag)
                self.assertEqual(run.call_args.kwargs["timeout"], verify_notify.READ_TIMEOUT_S, flag)
            # a mutation that is not a note POST keeps main's single 180 s attempt and is not retried either
            with unittest.mock.patch.object(verify_notify.subprocess, "run",
                                            side_effect=sp.TimeoutExpired("x", 1)) as run:
                with self.assertRaises(verify_notify.NoteTimeout):
                    verify_notify._run(["/opt/hydra/scripts/intercom-verify-request.sh", "tag-proof", "--message-id", "m"])
            self.assertEqual(run.call_count, 1)
            self.assertEqual(run.call_args.kwargs["timeout"], verify_notify.OTHER_TIMEOUT_S)
        finally:
            verify_notify.time.sleep = real_sleep
        self.assertEqual(sleeps, [], "nothing outside the note POST may sleep-and-retry")

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
        # r5 / firstmate 764 CHANGED this on purpose: one failed READ is HELD, not a failed run. The refusal is still a
        # refusal and still speaks. r5 770 (1) then split the two kinds: the POST failure is NOT a held read.
        # QA #1780 (Critical, 03:07Z) CHANGED the exit code back: an uncertain POST is the ONE per-user outcome that is
        # ALWAYS fatal to the run - the message may already be delivered, so a run that exits 0 over it reports success
        # for a delivery it cannot prove.
        # QA #1756 Important 2: it is ALSO counted on its own (post_failed_users), which is the counter the tick's
        # post_failed arm reads. One classification, two counters - the user is still a failed_users entry, because
        # `_failed(kind="post")` is the single place that records an unknown POST.
        self.assertEqual(rep.post_failed_users, 1, "the tick's post_failed arm reads this counter")
        self.assertTrue(rep.failed, "an uncertain POST is fatal to the run's exit code, at any count")
        self.assertEqual(rep.failed_held, [], "a POST FAILED is not a failed READ: nothing was unreadable")
        self.assertEqual([h["user"] for h in rep.post_failures], ["7"], "it is recorded as an unknown-outcome send")
        self.assertIn("unknown outcome", rep.render("apply"))
        self.assertIn("matches 0 Intercom users", rep.render("apply"))
        self.assertIn("POST FAILED (curl rc=28)", rep.render("apply"))

    def test_a_rejected_post_is_a_deferral_never_a_failed_read(self):
        """QA #1780 (Important, 03:07Z): Intercom's error.list answers rc=4 with "POST REJECTED by Intercom (nothing
        delivered; retried on a later run)" AFTER the reads succeeded. Counting three of those as three consecutive
        unreadable reads paged a human for the wrong condition and held a user whose account was perfectly readable."""
        decisions_db(self.path, [dec("r1")])
        admin = FakeAdmin([req("r1")])
        fake = Fake({"jane@example.com": (4, "", "POST REJECTED by Intercom (nothing delivered; retried on a later "
                                                 "run). Logged at /tmp/x. Response:\n{}")})
        rep = verify_notify.run(admin, ledger_path=self.path, mode="apply", runner=fake, wrapper="/w")
        self.assertEqual((rep.post_rejected, rep.failed_users, rep.deferred_users), (1, 0, 1))
        self.assertEqual(rep.failed_held, [], "a rejected POST is not a failed READ: nothing was unreadable")
        self.assertEqual(rep.post_failures, [], "and it is not an unknown-outcome send either: nothing was delivered")
        self.assertFalse(rep.failed, "nothing was delivered and the gate retries it: a deferral, not a failed run")
        self.assertIn("POST REJECTED", rep.render("apply"))
        self.assertEqual(verify_notify._post_rejected_line("POST REJECTED by Intercom"), "POST REJECTED by Intercom")
        self.assertEqual(verify_notify._post_rejected_line("POST FAILED (curl rc=28)"), "")

    def test_one_users_failed_read_holds_that_user_and_the_round_goes_on(self):
        """r5 / firstmate 764 - the 22Z round: ONE user's core read failed (a Trino query, recorded as a URL-encoded SQL
        fragment) and the r1 family - plus every claim family behind it - stopped for the night. The user is the unit of
        failure: they are HELD, the rest of the round goes on, and the run does not fail its exit code."""
        decisions_db(self.path, [dec("r1"), dec("r2", pid=PID2), dec("r3", pid=PID2, track="t3")])
        admin = FakeAdmin([req("r1"), req("r2", pid=PID2, email="b@example.com"),
                           req("r3", pid=PID2, email="c@example.com", track="t3")])
        # the exact shape the tick recorded: trino rc=1, then the query URL-encoded instead of the server's answer
        sql = ("trino rc=1: AS+varchar%29+FROM+postgresql_core.public.claiming+WHERE+userid+IN+%28310729%29"
               "+AND+updatedat+>+CAST")
        fake = Fake({"jane@example.com": (4, "", "CORE NOTICE CHECK FAILED (rc=2); nothing was sent or claimed: "
                                               + json.dumps({'hold': None, 'reasons': [f"trino rc=1: {sql}"]})),
                     "b@example.com": (0, "VALID email credits=1", "")})
        rep = verify_notify.run(admin, ledger_path=self.path, mode="dry-run", runner=fake, wrapper="/w")
        self.assertEqual(rep.failed_users, 1)
        self.assertEqual([h["user"] for h in rep.failed_held], [str(_uid_of("jane@example.com"))])
        self.assertEqual(rep.stopped_on_failures, 0)
        self.assertFalse(rep.failed, "one held user is not a failed run: the round continues")
        self.assertEqual(rep.validated, 1, "the user after the failed one was still checked")
        self.assertIn("held, not messaged", rep.render("dry-run"))
        self.assertNotIn("%29", rep.render("dry-run"), "a URL-encoded query is never the error a reader sees")
        self.assertIn("[query elided]", rep.render("dry-run"))

    def test_a_post_failure_is_never_rendered_as_held_and_not_messaged(self):
        """QA #1780 (Important, 02:12Z): `failed_users` counts BOTH a held read and an unknown POST, so the
        "held, not messaged" sentence keyed off it told the operator the opposite of the actual delivery state for the
        one outcome where the note may ALREADY be delivered. The two are rendered from their own counts."""
        decisions_db(self.path, [dec("r1"), dec("r2", pid=PID2)])
        admin = FakeAdmin([req("r1"), req("r2", pid=PID2, email="b@example.com")])
        # rc=5 = ATTEMPTED, OUTCOME UNKNOWN (the gate posted, then the transport failed and the row was left CLAIMED)
        fake = Fake({"jane@example.com": (5, "", "POST FAILED (curl rc=28); logged at /x and left CLAIMED"),
                     "b@example.com": (0, "POSTED email message=1 credits=1", "")})
        rep = verify_notify.run(admin, ledger_path=self.path, mode="apply", runner=fake, wrapper="/w")
        self.assertEqual((rep.post_failed, len(rep.failed_held)), (1, 0))
        out = rep.render("apply")
        self.assertIn("FAILED", out, "the word a replay greps stays")
        self.assertIn("UNKNOWN outcome", out)
        self.assertNotIn("held, not messaged", out,
                         "a POST failure may already be delivered: it is never rendered as a held read")

    def test_a_held_read_and_an_unknown_post_are_rendered_as_two_different_outcomes(self):
        """Both in one run: the held user is named as held, the POST user as unknown, and neither count absorbs the
        other."""
        decisions_db(self.path, [dec("r1"), dec("r2", pid=PID2), dec("r3", pid=PID2, track="t3")])
        admin = FakeAdmin([req("r1"), req("r2", pid=PID2, email="b@example.com"),
                           req("r3", pid=PID2, email="c@example.com", track="t3")])
        fake = Fake({"jane@example.com": (4, "", "CORE NOTICE CHECK FAILED (rc=2); nothing was sent or claimed"),
                     "b@example.com": (5, "", "POST FAILED (curl rc=28); logged at /x and left CLAIMED"),
                     "c@example.com": (0, "POSTED email message=1 credits=1", "")})
        rep = verify_notify.run(admin, ledger_path=self.path, mode="apply", runner=fake, wrapper="/w")
        self.assertEqual((len(rep.failed_held), rep.post_failed), (1, 1))
        out = rep.render("apply")
        self.assertIn("1 send(s) held, not messaged, not retried this run", out)
        self.assertIn("1 send(s) with an UNKNOWN outcome", out)

    def test_the_batch_stops_only_when_the_failures_are_systemic(self):
        """max(3, 5% of the users walked): below it every failed user is held and the round continues; at it the run stops
        and says so - because at that point the failure is a statement about the environment."""
        rows = [dec(f"r{i}") for i in range(1, 9)]
        decisions_db(self.path, rows)
        admin = FakeAdmin([req("r1")] + [req(f"r{i}", email=f"u{i}@example.com", track=f"t{i}")
                                        for i in range(2, 9)])
        fake = Fake({f"u{i}@example.com": (4, "", "CORE NOTICE CHECK FAILED (rc=2)") for i in (2, 3, 4)})
        rep = verify_notify.run(admin, ledger_path=self.path, mode="dry-run", runner=fake, wrapper="/w",
                                max_users=8)
        self.assertEqual(rep.failed_users, 3)
        self.assertEqual(rep.stopped_on_failures, 3)
        self.assertTrue(rep.failed, "three failures is systemic: the run fails and the tick must stop")
        self.assertIn("SYSTEMIC", rep.render("dry-run"))
        # r5's bar, at the boundary: max(3, 2% of walked)
        self.assertEqual(verify_notify.fail_stop_after(100), 3, "2% of 100 is 2, floored at 3")
        self.assertEqual(verify_notify.fail_stop_after(200), 4, "2% of 200 is 4")
        self.assertEqual(verify_notify.fail_stop_after(8), 3)
        self.assertEqual(verify_notify.fail_stop_after(2), 3, "a tiny batch still needs 3")

    def test_the_systemic_boundary_on_a_hundred_user_family_is_three_not_two(self):
        """Fable r5's bar as a BOUNDARY (firstmate 765): on a 100-user family max(3, 2% of 100) = 3, so TWO failed
        users are two per-user holds and the round runs to the end, and THREE are a systemic stop."""
        decisions_db(self.path, [dec("r1"), dec("r2"), dec("r3")])
        admin = FakeAdmin([req("r1", email="u1@example.com"), req("r2", email="u2@example.com", track="t2"),
                           req("r3", email="u3@example.com", track="t3")])

        def run_with(failing):
            fake = Fake({f"u{i}@example.com": (4, "", "CORE NOTICE CHECK FAILED (rc=2)") for i in failing})
            return verify_notify.run(admin, ledger_path=self.path, mode="dry-run", runner=fake, wrapper="/w",
                                     max_users=100), fake

        rep, fake = run_with((1, 2))
        self.assertEqual((rep.failed_users, rep.stopped_on_failures), (2, 0), "two of 100 is below the bar")
        self.assertFalse(rep.failed)
        self.assertEqual(len(rep.failed_held), 2)
        self.assertEqual(len(fake.payloads), 3, "the third user was still walked: two holds did not stop the round")

        rep, fake = run_with((1, 2, 3))
        self.assertEqual((rep.failed_users, rep.stopped_on_failures), (3, 3), "three of 100 is the bar")
        self.assertTrue(rep.failed)
        self.assertIn("SYSTEMIC", rep.render("dry-run"))

    def test_a_failed_read_holds_the_user_until_the_next_tick_and_pages_on_the_third(self):
        """Fable 769 + r5 770 (2): an unreadable read is NOT a refusal. The hold expires before the NEXT tick (never the
        7-day refusal window, and never AT the cadence - see the boundary test below), the third consecutive failed read
        pages a human, and a repeat inside the same hold is one failure."""
        decisions_db(self.path, [dec("r1")])
        admin = FakeAdmin([req("r1")])
        fake = Fake({"jane@example.com": (4, "", "CORE NOTICE CHECK FAILED (rc=2)")})
        rep = verify_notify.run(admin, ledger_path=self.path, mode="dry-run", runner=fake, wrapper="/w")
        db = verify_ledger.connect(self.path)
        uid = str(_uid_of("jane@example.com"))
        t0 = datetime(2026, 11, 5, 0, 30, tzinfo=timezone.utc)
        self.assertEqual(verify_notify.hold_failed_users(db, rep, "uvn-status-paid", now=t0), 1)
        row = verify_ledger.read_failure(db, campaign="uvn-status-paid", user_key="jane@example.com", now=t0)
        self.assertEqual(row["failures"], 1)
        self.assertEqual(row["next_retry_at"], "2026-11-05T01:30:00Z",
                         "READ_RETRY_H is 1 h: inside the 2-hourly cadence, so the NEXT tick always retries")
        self.assertLess(verify_ledger.READ_RETRY_H * 3600, 7200,
                        "a horizon equal to the cadence skips every other tick (r5 770 (2))")
        self.assertTrue(row["reason"].startswith("read failed:"), "the reason names the failure, not a refusal")
        self.assertEqual(verify_ledger.refusal_hold(db, "uvn-status-paid", "jane@example.com", None, uid), {},
                         "no refusal hold: a failed read must never suppress an account for RECHECK_DAYS")
        self.assertEqual(verify_ledger.refusal_hold(db, "status-doc-received", "jane@example.com", None, uid), {},
                         "and not for a campaign that honours refusal holds either")
        # The same tick failing again is ONE failure; the next tick failing again is the second.
        verify_notify.hold_failed_users(db, rep, "uvn-status-paid", now=t0 + timedelta(minutes=5))
        self.assertEqual(verify_ledger.read_failure(db, campaign="uvn-status-paid", user_key="jane@example.com",
                                                    now=t0 + timedelta(minutes=6))["failures"], 1)
        self.assertEqual(verify_ledger.read_failure(db, campaign="uvn-status-paid", user_key="jane@example.com",
                                                    now=t0 + timedelta(hours=3)),
                         {}, "the hold has expired: the next tick retries the account")
        rep2 = verify_notify.Report()
        rep2.failed_held = list(rep.failed_held)
        verify_notify.hold_failed_users(db, rep2, "uvn-status-paid", now=t0 + timedelta(hours=2, minutes=1))
        self.assertEqual(rep2.read_failure_pages, [], "two is not a pattern yet")
        rep3 = verify_notify.Report()
        rep3.failed_held = list(rep.failed_held)
        verify_notify.hold_failed_users(db, rep3, "uvn-status-paid", now=t0 + timedelta(hours=4, minutes=2))
        self.assertEqual(len(rep3.read_failure_pages), 1, "three consecutive failed reads is a pattern: page")
        self.assertIn("3 consecutive ticks", rep3.render("apply"), "the page reaches the summary a human reads")
        self.assertEqual(len(rep2.read_failure_pages), 0, "two in a row is not a page")

    def test_a_post_failure_is_never_held_as_a_failed_read(self):
        """r5 (firstmate 770) (1): the gate exits 4 with POST FAILED and leaves the row CLAIMED - the message may already
        be delivered. Filing it as a failed read would both mislabel what failed and promise a retry that could double
        send, so it is an UNKNOWN OUTCOME: counted, rendered, never held."""
        decisions_db(self.path, [dec("r1")])
        rep = verify_notify.run(FakeAdmin([req("r1")]), ledger_path=self.path, mode="apply", wrapper="/w",
                                runner=Fake({"jane@example.com": (4, "", "POST FAILED (curl rc=28); left CLAIMED")}))
        self.assertEqual((rep.failed_users, rep.post_failed), (1, 1))
        self.assertEqual(rep.failed_held, [], "no read hold, so the next tick does not 'retry the read'")
        db = verify_ledger.connect(self.path)
        self.assertEqual(db.execute("SELECT count(*) FROM verify_read_failures").fetchone()[0], 0,
                         "and nothing is written to the read-failure table")
        self.assertEqual(len(rep.post_failures), 1)
        self.assertTrue(any("never re-sent" in ln for ln in [rep.render("apply")]), "the summary says so out loud")

    def test_rc_four_without_the_gates_post_line_is_still_a_failed_read(self):
        """Defence in depth: rc 4 is the POST contract, but the GATE'S OWN LINE decides what failed - an rc alone must
        never relabel a failed read as a failed post, because a read failure is the one that must be retried."""
        decisions_db(self.path, [dec("r1")])
        rep = verify_notify.run(FakeAdmin([req("r1")]), ledger_path=self.path, mode="apply", wrapper="/w",
                                runner=Fake({"jane@example.com": (4, "", "CORE NOTICE CHECK FAILED (rc=2)")}))
        self.assertEqual((rep.post_failed, len(rep.failed_held)), (0, 1))

    def test_the_three_tick_page_lands_on_the_third_tick_not_the_fifth(self):
        """r5 770 (2), the measured defect: the 2-hourly tick fails at 04:20, 06:03, 08:03, 10:03, 12:03. With a horizon
        equal to the cadence the 06:03 tick found a still-live hold (06:03 < 06:20:00), counted the same failure and the
        count only advanced every OTHER tick - the page landed at 12:03, tick FIVE. A human waiting for a page about a
        persistently broken read waits half a day instead of four hours."""
        decisions_db(self.path, [dec("r1")])
        fake = Fake({"jane@example.com": (4, "", "CORE NOTICE CHECK FAILED (rc=2)")})
        rep0 = verify_notify.run(FakeAdmin([req("r1")]), ledger_path=self.path, mode="dry-run", runner=fake, wrapper="/w")
        db = verify_ledger.connect(self.path)
        for_hold = lambda: (lambda r: (setattr(r, "failed_held", list(rep0.failed_held)), r)[1])(verify_notify.Report())
        paged = []
        # the tick times the probed collisions actually used: an 04:03 boundary, a failure mid-tick, then every 2 h
        for tick, at in enumerate([datetime(2026, 11, 5, 4, 20, tzinfo=timezone.utc),
                                   datetime(2026, 11, 5, 6, 3, tzinfo=timezone.utc),
                                   datetime(2026, 11, 5, 8, 3, tzinfo=timezone.utc),
                                   datetime(2026, 11, 5, 10, 3, tzinfo=timezone.utc),
                                   datetime(2026, 11, 5, 12, 3, tzinfo=timezone.utc)]):
            r = for_hold()
            verify_notify.hold_failed_users(db, r, "uvn-status", now=at)
            if r.read_failure_pages:
                paged.append(tick + 1)
        self.assertEqual(paged, [3], "the page lands on the THIRD consecutive tick: with a horizon == the cadence it "
                                     "lands on a later tick (4 here, 5 in the probed collision)")

    def test_a_post_failed_row_is_outcome_unknown_never_a_refusal_and_never_a_plain_failure(self):
        """QA #1756 Important 2: the real gate prints `POST FAILED (curl rc=..)` and exits 4 after the POST was
        ATTEMPTED (scripts/intercom-verify-request.sh:3603-3606). The loop recorded every such return as `failed`, so
        the tick's post_failed arm - which keys on the outcome row - could never fire, and one note that may or may not
        have reached a customer was scored as an ordinary failure. Classified by the LINE, not the code: every other
        rc=4 is a pre-POST "nothing was sent or claimed" and stays a plain failure."""
        decisions_db(self.path, [dec("r1"), dec("r2", pid=PID2), dec("r3", pid=PID2, track="t3")])
        admin = FakeAdmin([req("r1"), req("r2", pid=PID2, email="b@example.com"),
                           req("r3", pid=PID2, email="c@example.com", track="t3")])
        fake = Fake({"jane@example.com": (4, "", "POST FAILED (curl rc=28); logged at /x and left CLAIMED"),
                     "b@example.com": (4, "", "CORE NOTICE CHECK FAILED (rc=1); nothing was sent or claimed"),
                     "c@example.com": (0, "POSTED email message=1 credits=1", "")})
        rep = verify_notify.run(admin, ledger_path=self.path, mode="apply", runner=fake, wrapper="/w")
        by_result = {o["result"]: o for o in rep.outcomes}
        self.assertIn("POST FAILED", by_result["post_failed"]["reason"])
        # the pre-POST rc=4 is NOT a post failure: nothing was attempted, so it stays a plain failure
        self.assertIn("CORE NOTICE CHECK FAILED", by_result["failed"]["reason"])
        # TWO failed_users, and that is the point: the pre-POST rc=4 above is a plain failure, and the POST FAILED
        # user is recorded through the SAME `_failed(kind="post")` path (failed_users + post_failed + post_failures +
        # the `post_failed` outcome row) with `post_failed_users` bumped alongside it. One classification, two
        # counters - the tick's arm reads post_failed_users, the summary reads failed_users/post_failures.
        self.assertEqual((rep.post_failed_users, rep.failed_users, rep.refused_users), (1, 2, 0))
        self.assertTrue(rep.failed)
        self.assertIn("UNKNOWN outcome", rep.render("apply"))

    def test_a_post_failed_row_alone_still_fails_the_run_and_is_never_no_reply(self):
        """The one summary that most needs reading must not be the silent one: a run whose only event was an unknown
        POST renders a line and exits non-zero."""
        decisions_db(self.path, [dec("r1")])
        fake = Fake({"jane@example.com": (4, "", "POST FAILED (curl rc=28)")})
        rep = verify_notify.run(FakeAdmin([req("r1")]), ledger_path=self.path, mode="apply", runner=fake, wrapper="/w")
        self.assertEqual(rep.post_failed_users, 1)
        self.assertTrue(rep.failed)
        self.assertNotEqual(rep.render("apply"), "NO_REPLY")

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


class FailedReadHoldEveryLaneTests(unittest.TestCase):
    """Fable r5 2026-11-06 00:53Z (QA #1780's carried finding): the per-user read hold had exactly ONE caller - the UVN
    lane - so on the two daily lanes a failed send-time read exited 0, printed "held", wrote no ``verify_read_failures``
    row, was re-walked by the next run with no consecutive count, and the ``READ_FAILURES_TO_PAGE`` page could never
    fire. The word was false and the alarm was absent.

    These are ENTRYPOINT tests: they go through ``run()`` / ``run_wave()``, never through ``hold_failed_users()``, so
    deleting the ``finish_failed_reads()`` call in either entrypoint turns them red on the MISSING ROW."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.path = os.path.join(self.tmp, "ledger.sqlite3")
        self.wave = os.path.join(self.tmp, "wave.csv")

    def tearDown(self):
        shutil.rmtree(self.tmp)

    def _rows(self, campaign):
        db = verify_ledger.connect(self.path)
        try:
            return [tuple(r) for r in db.execute(
                "SELECT campaign, user_key, failures FROM verify_read_failures WHERE campaign=?", (campaign,))]
        finally:
            db.close()

    def test_verify_live_holds_its_own_failed_read_and_the_next_run_skips_the_user(self):
        decisions_db(self.path, [dec("r1")])
        admin = FakeAdmin([req("r1")])
        rep = verify_notify.run(admin, ledger_path=self.path, mode="apply", wrapper="/w",
                                runner=Fake({"jane@example.com": (4, "", "CORE NOTICE CHECK FAILED (rc=2)")}))
        self.assertEqual(len(rep.failed_held), 1)
        self.assertEqual(self._rows("verify-live"), [("verify-live", "jane@example.com", 1)],
                         "the entrypoint writes the hold for its OWN campaign: without the finish_failed_reads() call "
                         "in run() this is [] and the user is never held")
        # The next run HONOURS it: the user is skipped with a named deferral and the gate is never called again.
        second = Fake()
        rep2 = verify_notify.run(admin, ledger_path=self.path, mode="apply", runner=second, wrapper="/w")
        self.assertEqual([a for a in second.argv if a[1] == "send"], [], "a held user is not walked again")
        self.assertTrue(any("read failed on an earlier tick" in d for d in rep2.deferrals), rep2.deferrals)
        self.assertFalse(rep2.failed, "a held user is a KNOWN outcome, not a failed round")

    def test_verify_live_dry_run_writes_no_hold(self):
        decisions_db(self.path, [dec("r1")])
        verify_notify.run(FakeAdmin([req("r1")]), ledger_path=self.path, mode="dry-run", wrapper="/w",
                          runner=Fake({"jane@example.com": (4, "", "CORE NOTICE CHECK FAILED (rc=2)")}))
        self.assertEqual(self._rows("verify-live"), [], "a dry run is a read: it never writes a hold row")

    def test_retro_past_holds_its_own_failed_read_and_the_next_run_skips_the_user(self):
        wave_file(self.wave, [("HOLD", "r1", "42", PID, "t1", "Mixing", 10, 0, "2026-09-02")])
        admin = FakeAdmin([req("r1")])
        rep = verify_notify.run_wave(admin, wave_path=self.wave, ledger_path=self.path, mode="apply", max_users=10,
                                     pace_seconds=0, wrapper="/w", today="2026-10-16",
                                     runner=Fake({"jane@example.com": (4, "", "CORE NOTICE CHECK FAILED (rc=2)")}))
        self.assertEqual(len(rep.failed_held), 1)
        self.assertEqual(self._rows("retro-past"), [("retro-past", "jane@example.com", 1)],
                         "the retro entrypoint writes the hold for its OWN campaign")
        second = Fake()
        rep2 = verify_notify.run_wave(admin, wave_path=self.wave, ledger_path=self.path, mode="apply", max_users=10,
                                      pace_seconds=0, runner=second, wrapper="/w", today="2026-10-16")
        self.assertEqual([a for a in second.argv if a[1] == "send"], [], "a held user is not walked again")
        self.assertTrue(any("read failed on an earlier tick" in d for d in rep2.deferrals), rep2.deferrals)

    def test_retro_past_dry_run_writes_no_hold(self):
        wave_file(self.wave, [("HOLD", "r1", "42", PID, "t1", "Mixing", 10, 0, "2026-09-02")])
        verify_notify.run_wave(FakeAdmin([req("r1")]), wave_path=self.wave, ledger_path=self.path, mode="dry-run",
                               max_users=10, pace_seconds=0, wrapper="/w", today="2026-10-16",
                               runner=Fake({"jane@example.com": (4, "", "CORE NOTICE CHECK FAILED (rc=2)")}))
        self.assertEqual(self._rows("retro-past"), [], "a dry run is a read: it never writes a hold row")

    def test_a_successful_read_clears_the_streak_on_the_daily_lane(self):
        """The counter is CONSECUTIVE: a read that works deletes the row, so three failures days apart never page."""
        decisions_db(self.path, [dec("r1")])
        admin = FakeAdmin([req("r1")])
        verify_notify.run(admin, ledger_path=self.path, mode="apply", wrapper="/w",
                          runner=Fake({"jane@example.com": (4, "", "CORE NOTICE CHECK FAILED (rc=2)")}))
        self.assertEqual(len(self._rows("verify-live")), 1)
        db = verify_ledger.connect(self.path)
        try:
            db.execute("UPDATE verify_read_failures SET next_retry_at='2000-01-01T00:00:00Z'")
        finally:
            db.close()
        verify_notify.run(admin, ledger_path=self.path, mode="apply", wrapper="/w", runner=Fake())
        self.assertEqual(self._rows("verify-live"), [], "a verified successful read resets the consecutive count")

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

    def test_claim_proof_ask_replies_are_counted_apart_from_credit_proof(self):
        db = verify_ledger.connect(self.path)
        for i, campaign in enumerate(("claim-proof-ask", "claim-proof-ask", "verify-live")):
            c = verify_ledger.claim(db, campaign=campaign, user_key=f"u{i}@x.com", day="2026-10-15",
                                    request_ids=[f"claim-{i}" if campaign == "claim-proof-ask" else f"r{i}"],
                                    message_type="email", approved_by=CAPTAIN_UID, approval_ref="ref")
            verify_ledger.finalize(db, message_row=c["message_row"], status="sent", message_id=f"{100 + i}")
        db.close()
        fake = Fake({"100": (0, "TAGGED claim-proof conversation=5 message=100 attachments=1", ""),
                     "101": (3, "REPLY RECORDED message=101 conversation=6 (no day-7 reminder; with a person)\n"
                                "NO PROOF YET message=101 conversation=6", ""),
                     "102": (0, "TAGGED credit-proof conversation=7 message=102 attachments=1", "")})
        rep = verify_notify.run(FakeAdmin([]), ledger_path=self.path, mode="apply", runner=fake, wrapper="/w")
        self.assertEqual((rep.proof_tagged, rep.extension_requests, rep.claim_proof_tagged, rep.claim_replies),
                         (1, 0, 1, 1))
        text = rep.render("apply")
        self.assertIn("1 proof repl(ies) tagged credit-proof for review", text)
        self.assertIn("1 claim repl(ies) tagged claim-proof for a person", text)
        self.assertIn("1 claimant repl(ies) to a claim-proof-ask note recorded", text)

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

    def test_a_rejected_credit_gets_no_follow_up_from_the_sender(self):
        """The after-rejection note is DELETED (Fable ruling-79 denial 2026-11-04, dispatch
        decline-copy.md, Aaron 2026-10-29 wording rule): its copy named which check failed.
        A rejected credit therefore sends nothing from this script, and the credit stays held
        for a human - never removed before the user is told why, and the tell is now the
        `decline` campaign's single approved sentence."""
        db = verify_ledger.connect(self.path)
        self.addCleanup(db.close)
        c = windowed_note(db)
        verify_ledger.finalize(db, message_row=c["message_row"], status="sent", message_id="500")
        verify_ledger.mark_tagged(db, message_id="500", conversation_id="5", attachments=1)
        verify_ledger.record_proof_review(db, message_id="500", request_ids=["r1"], outcome="rejected", reviewer="x",
                                          reason="other_role")
        self.assertEqual(verify_ledger.reminders_due(db, campaign="verify-live", day="2026-10-20"), [],
                         "the ledger no longer offers the deleted kind")
        fake, rep = Fake(), Report()
        verify_notify.send_followups(db, FakeAdmin([req("r1", track="t1"), req("r2", track="t2")]), rep, verdicts=verify_notify.affiliation.read(AFFILIATION_FILE),
                                     campaign="verify-live", day="2026-10-20",
                                     documented=verify_notify.load_proof_on_file(PROOF_FILE), limit=150,
                                     pace_seconds=0, wrapper="/w", runner=fake)
        self.assertEqual(fake.payloads, [], "nothing named a reason: the rejected credit sends no note")
        self.assertEqual(rep.reminders_sent, 0)
        self.assertEqual([(h["request_id"], h["reason"]) for h in verify_ledger.held_for_human(db, day="2026-11-20")],
                         [("r1", verify_ledger.HELD_NOT_TOLD), ("r2", verify_ledger.HELD_AWAITING_REVIEW)],
                         "a rejected credit is never removed before the user is told why; the "
                         "unreviewed one still awaits review")


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
        self.assertEqual([f for f in os.listdir(prev) if f.endswith(".txt")], ["42.txt"])   # + its .facts.json (the judge)
        self.assertEqual(stat.S_IMODE(os.stat(os.path.join(prev, "42.txt")).st_mode), 0o600)


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
    printf '{"data":[{"id":"c%s","role":"user","email":"%s","external_id":"%s"}]}' "${#e}" "$e" "${STUB_EXT_ID:-test-pro}" ;;
  "POST /messages")
    if [ -n "${STUB_REJECT:-}" ] && [ -f "$STUB_REJECT" ]; then
      rm -f "$STUB_REJECT"; printf '{"type":"error.list","errors":[{"code":"rate_limit_exceeded"}]}'; exit 0
    fi
    printf '%s\n' "$payload" >> "$STUB_LOG.bodies"
    n=$(( $(cat "$STUB_N" 2>/dev/null || echo 500) + 1 )); echo "$n" > "$STUB_N"
    printf '{"type":"admin_message","id":"%s","message_type":"email","conversation_id":null}' "$n" ;;
  "POST /conversations/search") printf '{"conversations":[]}' ;;
  "GET /contacts/"*)   # the contact read (Intercom returns the contact object; #1511 reads its email reachability)
    printf '{"type":"contact","id":"%s","role":"user","has_hard_bounced":false}' "${url##*/}" ;;
  *) printf '{"type":"error.list","errors":[{"code":"not_found"}]}' ;;
esac
"""


@unittest.skipUnless(shutil.which("jq") and (shutil.which("timeout") or shutil.which("gtimeout")),
                     "jq and timeout are needed for the wiring test")
class SignedHeadTests(unittest.TestCase):
    """Fable [key=signed-on-sha]: a list-driven apply sends only on the deploy head its list was signed on (signed_on in
    the header) - re-read before EVERY user - and holds the shared apply lock for its whole run."""

    def setUp(self):
        self.d = Path(tempfile.mkdtemp())
        self.sha = self.d / ".deployed-sha"
        self.sha.write_text("a" * 40 + "\n")
        self.lock = self.d / "lock" / "apply.lock"
        (self.d / "lock").mkdir()
        self.p = [unittest.mock.patch.object(verify_notify, "DEPLOYED_SHA_PATH", str(self.sha)),
                  unittest.mock.patch.object(verify_notify, "APPLY_LOCK_PATH", str(self.lock)),
                  unittest.mock.patch.object(verify_notify, "LIST_SIGNED_ON", "a" * 40),
                  unittest.mock.patch.object(verify_notify, "HEAD_REFUSED", 0)]
        for x in self.p:
            x.start()

    def tearDown(self):
        for x in self.p:
            x.stop()

    def payloads(self, n=5):
        return [{"user": {"id": str(i), "email": f"u{i}@x.com"}, "credits": [{"request_id": f"r{i}"}]} for i in range(n)]

    def apply(self, runner, n=5):
        rep = Report()
        # [key=apply-pool] these tests pin the HEAD / signed-set semantics, which are per-user and unchanged by the
        # pool; pinning APPLY_WORKERS=1 keeps them deterministic. The pool's own bound is tested in ApplyPoolTests.
        with unittest.mock.patch.object(verify_notify, "attach_identities", lambda ps, r: (ps, [])), \
             unittest.mock.patch.object(verify_notify, "APPLY_WORKERS", 1):
            verify_notify.send_all(self.payloads(n), rep, mode="apply", runner=runner, extra=["--campaign", "uvn-status"])
        return rep

    def test_a_deploy_mid_batch_defers_every_remaining_user(self):
        import fcntl
        sent = []

        def run(argv):
            uid = json.load(open(argv[argv.index("--credits-file") + 1]))["user"]["id"]
            with open(self.lock) as fh:                        # the shared apply lock is held while sending
                with self.assertRaises(BlockingIOError):
                    fcntl.flock(fh.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
            sent.append(uid)
            if uid == "1":
                self.sha.write_text("b" * 40 + "\n")          # a deploy lands after user 1
            return subprocess.CompletedProcess(argv, 0, "POSTED email message=1 credits=1\n", "")
        rep = self.apply(run)
        self.assertEqual(sent, ["0", "1"])
        self.assertEqual(rep.deferred_users, 3)
        self.assertTrue(all("sha_mismatch: signed on aaaaaaaaaaaa, deployed bbbbbbbbbbbb" in o["reason"] for o in rep.outcomes))
        self.assertEqual(verify_notify.HEAD_REFUSED, 3)
        with open(self.lock) as fh:                            # released after the run
            fcntl.flock(fh.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)

    def test_a_header_without_signed_on_sends_nothing_a_mismatch_neither_and_dry_runs_are_unaffected(self):
        calls = []
        run = lambda argv: calls.append(argv) or subprocess.CompletedProcess(argv, 0, "POSTED email message=1 credits=1\n", "")
        verify_notify.bind_list({"generated_at": "x", "users": []})              # no signed_on in the header
        rep = self.apply(run)
        self.assertEqual((calls, rep.deferred_users), ([], 5))
        self.assertIn("the list header carries no signed_on", rep.outcomes[0]["reason"])
        # QA #1604: the FULL sha exactly - a prefix, another case, a padded value or another head refuses
        for bad in ("aaaaaaa", "a" * 39, "A" * 40, " " + "a" * 40, "a" * 40 + "\n", "b" * 40, "a" * 41):
            verify_notify.bind_list({"signed_on": bad})
            self.assertTrue(verify_notify.head_mismatch().startswith("sha_mismatch"), repr(bad))
        verify_notify.bind_list({"signed_on": "a" * 40})
        self.assertEqual(verify_notify.head_mismatch(), "")
        # a malformed or truncated deployed record is UNREADABLE (never normalised): refuse
        for rec in ("aaaaaaaZ\n", "a" * 39 + "\n", "a" * 40 + "Z\n", "A" * 40 + "\n", " " + "a" * 40 + "\n", ""):
            self.sha.write_text(rec)
            verify_notify.bind_list({"signed_on": "a" * 40})
            self.assertIn("unreadable", verify_notify.head_mismatch(), repr(rec))
            verify_notify.bind_list({"signed_on": "aaaaaaa"})
            self.assertTrue(verify_notify.head_mismatch().startswith("sha_mismatch"), repr(rec))
        self.sha.write_text("a" * 40 + "\n")
        self.sha.unlink()
        self.assertIn("unreadable", verify_notify.head_mismatch())               # signed, but the head cannot be read
        verify_notify.bind_list({"users": []})                                   # QA #1604: BOTH missing -> refuse
        self.assertIn("unreadable", verify_notify.head_mismatch())
        with unittest.mock.patch.object(verify_notify, "LIST_SIGNED_ON", None):  # not a list-driven send
            self.assertEqual(verify_notify.head_mismatch(), "")
        verify_notify.bind_list({"signed_on": "b" * 40})
        rep = Report()
        verify_notify.send_all(self.payloads(2), rep, mode="dry-run", runner=lambda a: subprocess.CompletedProcess(
            a, 0, "VALID uvn-status credits=1\n", ""), extra=["--campaign", "uvn-status"], workers=1)
        self.assertEqual(rep.deferred_users, 0)                                  # the rail is apply-only

    def test_a_held_or_missing_apply_lock_dir_never_fails_open(self):
        import fcntl
        calls = []
        run = lambda argv: calls.append(argv) or subprocess.CompletedProcess(argv, 0, "POSTED email message=1 credits=1\n", "")
        # QA #1604: a deploy holding the lock exclusively -> the apply sends nothing
        with open(self.lock, "a+") as fh:
            fcntl.flock(fh.fileno(), fcntl.LOCK_EX)
            rep = self.apply(run)
        self.assertEqual(calls, [])
        self.assertIn("a deploy holds the apply lock", rep.halted)
        # a missing lock directory is CREATED (never 'no lock'), and the apply runs under the lock
        missing = self.d / "fresh" / "dir" / "apply.lock"
        with unittest.mock.patch.object(verify_notify, "APPLY_LOCK_PATH", str(missing)):
            rep = self.apply(run, n=1)
        self.assertTrue(missing.exists())
        self.assertEqual(len(calls), 1)
        # an unopenable lock refuses
        with unittest.mock.patch.object(verify_notify, "APPLY_LOCK_PATH", str(self.sha) + "/x/apply.lock"):
            rep = self.apply(run, n=1)
        self.assertIn("cannot be opened", rep.halted)
        self.assertEqual(len(calls), 1)

    def test_one_apply_lock_spans_the_whole_run_between_users_and_the_cli_refuses_under_a_deploy(self):
        import fcntl, argparse, importlib.util
        run = lambda argv: subprocess.CompletedProcess(argv, 0, "POSTED email message=1 credits=1\n", "")

        def deploy_can_lock():
            with open(self.lock, "a+") as fh:
                try:
                    fcntl.flock(fh.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
                    return True
                except BlockingIOError:
                    return False
        # QA #1604: between two per-user send_all calls of ONE run the deploy still cannot take the lock
        with verify_notify.apply_session():
            self.apply(run, n=1)
            self.assertFalse(deploy_can_lock())                 # the gap between users
            self.apply(run, n=1)
            with verify_notify.apply_session():                 # re-entrant: an inner session does not release it
                pass
            self.assertFalse(deploy_can_lock())
        self.assertTrue(deploy_can_lock())                      # released when the run ends
        # the CLI: a deploy holding the lock -> the apply run refuses before ANY work (exit 3)
        spec = importlib.util.spec_from_file_location("credit_review_cli_lock", str(ROOT / "scripts" / "credit-review.py"))
        cli = importlib.util.module_from_spec(spec); spec.loader.exec_module(cli)
        called = []
        ns = argparse.Namespace(cmd="uvn-status", mode="apply", fn=lambda a: called.append(1) or 0)
        with open(self.lock, "a+") as fh, unittest.mock.patch.object(cli, "parser") as par:
            fcntl.flock(fh.fileno(), fcntl.LOCK_EX)
            par.return_value.parse_args.return_value = ns
            self.assertEqual(cli.main([]), 3)
        self.assertEqual(called, [])

    def test_the_cli_prints_a_DIFFERENT_marker_for_an_unopenable_lock_than_for_a_held_one(self):
        """QA #1799 r12 (carried): ApplyLockError covered BOTH contention and a lock that could not be OPENED, so a
        permissions/I-O fault was reported as "a deploy holds the lock", retried, deferred, and the tick went on into
        later groups. The two now carry different markers, and the tick stops hard on the unopenable one."""
        import argparse, importlib.util, io, contextlib
        spec = importlib.util.spec_from_file_location("credit_review_cli_unopenable",
                                                      str(ROOT / "scripts" / "credit-review.py"))
        cli = importlib.util.module_from_spec(spec); spec.loader.exec_module(cli)
        ns = argparse.Namespace(cmd="uvn-status", mode="apply", fn=lambda a: 0)

        def run_with(exc):
            err = io.StringIO()
            with unittest.mock.patch.object(cli, "parser") as par, \
                    unittest.mock.patch.object(verify_notify, "apply_session",
                                               side_effect=lambda: contextlib.nullcontext()):
                par.return_value.parse_args.return_value = ns
                with unittest.mock.patch.object(verify_notify, "apply_session") as sess:
                    sess.return_value.__enter__.side_effect = exc
                    sess.return_value.__exit__.return_value = False
                    with contextlib.redirect_stderr(err):
                        rc = cli.main([])
            return rc, err.getvalue()

        rc, err = run_with(verify_notify.ApplyLockUnopenable("the apply lock /x cannot be opened (PermissionError)"))
        self.assertEqual(rc, 3, "the exit code contract is unchanged for every caller")
        self.assertIn(verify_notify.APPLY_LOCK_UNOPENABLE_MARKER, err)
        self.assertNotIn(verify_notify.APPLY_LOCK_MARKER + ":", err,
                         "an unopenable lock must never be reported as a held one")
        rc, err = run_with(verify_notify.ApplyLockError("a deploy holds the apply lock /x"))
        self.assertEqual(rc, 3)
        self.assertIn(verify_notify.APPLY_LOCK_MARKER, err)
        self.assertNotIn(verify_notify.APPLY_LOCK_UNOPENABLE_MARKER, err)
        # and the subclass relationship is what keeps every existing caller working
        self.assertTrue(issubclass(verify_notify.ApplyLockUnopenable, verify_notify.ApplyLockError))

    def test_the_builders_record_signed_on_and_the_loaders_bind_it(self):
        self.sha.write_text("c" * 40 + "\n")
        self.assertEqual(verify_notify.deployed_head(), "c" * 40)
        self.sha.write_text("aaaaaaaZ\n")
        self.assertEqual(verify_notify.deployed_head(), "")                       # QA #1604: never normalised
        self.sha.write_text("c" * 40 + "\n")
        from credit_review import uvn_status, need_asks, owing_proof, receipts, claim_proof_ask
        for mod in (owing_proof, receipts):
            self.assertIn('"signed_on": verify_notify.deployed_head()', open(mod.__file__).read(), mod.__name__)
        self.assertIn('"signed_on": verify_notify.deployed_head()}', open(need_asks.__file__).read())
        src = open(need_asks.__file__).read()
        self.assertLess(src.index("    verify_notify.bind_list(doc)"), src.index('    users = [u for u in doc["users"]'))
        lst = self.d / "l.json"
        lst.write_text(json.dumps({"generated_at": datetime.now(timezone.utc).isoformat(), "users": [],
                                   "signed_on": "d" * 40}))
        uvn_status.load_list(str(lst))
        self.assertEqual(verify_notify.LIST_SIGNED_ON, "d" * 40)
        lst.write_text(json.dumps({"generated_at": datetime.now(timezone.utc).isoformat(), "claims": [],
                                   "signed_on": "e" * 40}))
        claim_proof_ask.load_list(str(lst), require_daily_check=False)
        self.assertEqual(verify_notify.LIST_SIGNED_ON, "e" * 40)


class ApplySentRecordTests(unittest.TestCase):
    """t01b 563: a clean apply records WHO it sent to - report.sent per POSTED user, written as "sent" in the outcomes
    file (it held only non-sends, so a 50/50 apply left an empty file)."""

    def test_an_apply_records_every_posted_user_and_the_outcomes_file_carries_them(self):
        import argparse, importlib.util
        pays = [{"user": {"id": str(i), "email": f"u{i}@x.com"}, "credits": [{"request_id": f"r{i}"}]} for i in (7, 8)]
        run = lambda argv: subprocess.CompletedProcess(argv, 0, "POSTED email message=55%s credits=1\n" % argv[-1][-1:], "")
        rep = Report()
        with unittest.mock.patch.object(verify_notify, "attach_identities", lambda ps, r: (ps, [])):
            verify_notify.send_all(pays, rep, mode="apply", runner=run, extra=["--campaign", "uvn-status"])
        self.assertEqual([(s["user"], s["campaign"], s["request_ids"]) for s in rep.sent],
                         [("7", "uvn-status", ["r7"]), ("8", "uvn-status", ["r8"])])
        self.assertTrue(all(s["gate"].startswith("POSTED email message=") for s in rep.sent))
        self.assertEqual((rep.outcomes, rep.sent_notes), ([], 2))
        spec = importlib.util.spec_from_file_location("credit_review_cli_sent", str(ROOT / "scripts" / "credit-review.py"))
        cli = importlib.util.module_from_spec(spec); spec.loader.exec_module(cli)
        out = Path(tempfile.mkdtemp()) / "o.json"
        cli.write_outcomes(argparse.Namespace(outcomes_json=str(out), mode="apply", segment="paid"), rep)
        d = json.loads(out.read_text())
        self.assertEqual(([s["user"] for s in d["sent"]], d["outcomes"]), (["7", "8"], []))
        # QA #1606: a POSTED reminder lands in sent too (every POSTED line of every runner path)
        rep = Report()
        with unittest.mock.patch.object(verify_notify, "attach_identities", lambda ps, r: (ps, [])):
            verify_notify.send_all(pays[:1], rep, mode="apply", runner=run, extra=["--campaign", "claim-proof-ask"],
                                   reminder=True)
        self.assertEqual((rep.reminders_sent, [(s["user"], s["campaign"], s.get("kind")) for s in rep.sent]),
                         (1, [("7", "claim-proof-ask", "reminder")]))


class ParallelCheckTests(unittest.TestCase):
    """Fable 526: a read-only pass runs its gate calls on CHECK_WORKERS threads; the report equals the serial pass field
    for field (accepted in list order), and a real send (apply) never runs two gate calls at once."""

    def outcomes(self):
        lines = {0: (0, "RECIPIENT OK user=%s", ""), 1: (3, "DEFERRED comm_state: hold", ""),
                 2: (1, "", "REFUSED: some gate rule (%s)"), 3: (0, "SKIPPED already told %s", "")}
        return lines

    def runner(self, live, peak, lock):
        import random, threading, time as _t
        lines = self.outcomes()

        def run(argv):
            with lock:
                live[0] += 1; peak[0] = max(peak[0], live[0])
            try:
                _t.sleep(random.uniform(0, 0.02))           # completions arrive out of order
                uid = json.load(open(argv[argv.index("--credits-file") + 1]))["user"]["id"]
                rc, out, err = lines[int(uid) % 4]
                return subprocess.CompletedProcess(argv, rc, (out % uid) if "%s" in out else out,
                                                   (err % uid) if "%s" in err else err)
            finally:
                with lock:
                    live[0] -= 1
        return run, threading

    def payloads(self, n=23):
        return [{"user": {"id": str(i), "email": f"u{i}@x.com"}, "credits": [{"request_id": f"r{i}"}]} for i in range(n)]

    def report_of(self, mode, workers, check=True):
        import threading
        live, peak, lock = [0], [0], threading.Lock()
        run, _ = self.runner(live, peak, lock)
        rep = Report()
        with unittest.mock.patch.object(verify_notify, "attach_identities", lambda ps, r: (ps, [])):
            verify_notify.send_all(self.payloads(), rep, mode=mode, runner=run, extra=["--campaign", "uvn-status"],
                                   check_recipients=check, workers=workers)
        return rep, peak[0]

    def test_parallel_check_equals_serial_and_keeps_list_order(self):
        serial, sp = self.report_of("dry-run", 1)
        par, pp = self.report_of("dry-run", 4)
        self.assertEqual(sp, 1)
        self.assertGreater(pp, 1)                            # it really ran concurrently
        self.assertEqual([a["user"] for a in par.accepted], [str(i) for i in range(23) if i % 4 == 0])
        self.assertEqual(par.accepted, serial.accepted)
        self.assertEqual(par.outcomes, serial.outcomes)
        self.assertEqual((par.recipient_ok, par.deferred_users, par.deferrals, par.skipped),
                         (serial.recipient_ok, serial.deferred_users, serial.deferrals, serial.skipped))

    def test_apply_runs_a_bounded_pool_never_more_than_APPLY_WORKERS_at_once(self):
        """[key=apply-pool] (captain 2026-11-11, work order item 1): a real send used to be strictly serial. It now
        runs a bounded pool, and the bound is the constant - never an unbounded fan-out."""
        _, peak = self.report_of("apply", 4, check=False)
        self.assertGreater(peak, 1, "apply really runs more than one note step at once")
        self.assertLessEqual(peak, verify_notify.APPLY_WORKERS)
        self.assertEqual(verify_notify.APPLY_WORKERS, 6, "the pool is bounded at 6 by the captain's work order")

    def test_one_gate_timeout_in_the_parallel_pre_gate_is_that_users_row_never_the_batchs_abort(self):
        """Defect A (Fable d2): `pre = list(ex.map(gate, payloads))` re-raised the FIRST worker's NoteTimeout out of
        send_all, so one slow read-only gate call (>= READ_TIMEOUT_S) aborted the whole check and every user behind it
        got nothing (22:28Z / 00:19Z / 02:30Z). Any runner's timeout is now captured per user: that user is
        `unmeasured` (gate_timeout), the rest are classified exactly as serial, and the run is not failed below the
        max(5, 10% of the batch) bar. At the bar it stops and fails loudly."""
        import threading
        live, peak, lock = [0], [0], threading.Lock()
        base, _ = self.runner(live, peak, lock)

        def run(argv):
            uid = json.load(open(argv[argv.index("--credits-file") + 1]))["user"]["id"]
            if uid == "5":
                raise verify_notify.NoteTimeout("a gate call timed out after 1 attempt(s) of 20s")
            return base(argv)

        rep = Report()
        with unittest.mock.patch.object(verify_notify, "attach_identities", lambda ps, r: (ps, [])):
            verify_notify.send_all(self.payloads(), rep, mode="dry-run", runner=run, extra=["--campaign", "uvn-status"],
                                   check_recipients=True, workers=4)
        self.assertEqual([a["user"] for a in rep.accepted], [str(i) for i in range(23) if i % 4 == 0])
        self.assertEqual((rep.timeout_users, rep.unmeasured_users, rep.unmeasured_stop_at), (1, 1, 5))
        self.assertEqual([(o["user"], o["reason"][:12]) for o in rep.outcomes if o["result"] == "unmeasured"],
                         [("5", "gate_timeout")])
        self.assertFalse(rep.failed)
        self.assertIn("UNMEASURED", rep.render("dry-run"))
        self.assertIn("bar 5 = max(5, 10% of the batch)", rep.render("dry-run"))
        # the bar: 23 users -> max(5, ceil(2.3)) = 5; five stalls stop the run loudly, four do not
        for slow, stopped in (({"1", "2", "3", "5"}, False), ({"1", "2", "3", "5", "6"}, True)):
            def run_n(argv, slow=slow):
                uid = json.load(open(argv[argv.index("--credits-file") + 1]))["user"]["id"]
                if uid in slow:
                    raise verify_notify.NoteTimeout("a gate call timed out after 1 attempt(s) of 20s")
                return base(argv)
            rep = Report()
            with unittest.mock.patch.object(verify_notify, "attach_identities", lambda ps, r: (ps, [])):
                verify_notify.send_all(self.payloads(), rep, mode="dry-run", runner=run_n,
                                       extra=["--campaign", "uvn-status"], check_recipients=True, workers=4)
            self.assertEqual(rep.unmeasured_users, len(slow))
            self.assertEqual(rep.failed, stopped, slow)
            self.assertEqual(bool(rep.stopped_on_unmeasured), stopped)
            if stopped:
                self.assertIn("UNMEASURED STOP: 5 of 23", rep.stopped_on_unmeasured)
                self.assertIn("UNMEASURED STOP", rep.render("dry-run"))


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
        # core_notice.py stand-in: core told nobody anything lately (its own rules: test_core_notice.py).
        (t / "core_notice.py").write_text('import json; print(json.dumps({"hold": False, "reasons": []}))\n')
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
            "INTERCOM_VERIFY_TEST_CORE_NOTICE_HELPER": str(t / "core_notice.py"),
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
        # QA #1780 (Important): Intercom's error.list is a REJECTED POST - nothing was delivered and the gate retries it
        # on a later run. It is a deferral, never a failed read: counting three of them as three unreadable reads paged a
        # human for the wrong condition and held a user whose account was perfectly readable.
        self.assertEqual((first.sent_notes, first.failed_users, first.post_rejected), (0, 0, 1))
        self.assertEqual(first.failed_held, [], "a rejected POST is not a failed READ")
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

    def test_the_recipient_professional_id_is_passed_and_a_missing_one_holds_the_note(self):
        """The gate matches Intercom's external_id against the account's professional id or Auth0
        subject. A user without a professional id is held (deferred, never handed to the gate,
        whose refusal would close the credits); an unreadable replica halts the run with nothing
        sent."""
        saved = verify_notify.IDENTITY_LOOKUP
        try:
            verify_notify.IDENTITY_LOOKUP = lambda ids: {"45": {"professional_id": "pro-45", "auth_id": "abc-45"}}
            rows = [user_req("a1", 45), user_req("a2", 46)]
            rep, fake = self.go(rows)
            self.assertEqual([(p["user"]["id"], p["user"].get("professional_id"), p["user"].get("auth_id"))
                              for p in fake.payloads], [("45", "pro-45", "abc-45")])
            self.assertEqual(rep.no_professional_id, 1)
            self.assertIn("a2", self.deferred())
            self.assertIn("no professional id", rep.render("apply"))

            def down(ids):
                raise RuntimeError("rc=2: trino down")
            verify_notify.IDENTITY_LOOKUP = down
            rep, fake = self.go([user_req("a3", 47)])
            self.assertEqual(fake.payloads, [])
            self.assertIn("professional ids cannot be read", rep.halted)
            self.assertTrue(rep.failed)
            self.assertIn("a3", self.deferred())
        finally:
            verify_notify.IDENTITY_LOOKUP = saved

    def test_the_intercom_identity_is_read_from_neptuneprofessionalid(self):
        """firstmate 118: Intercom's external_id is the account's professionalId
        (users.neptuneprofessionalid), for accounts with and without an Auth0 subject."""
        seen = []

        def q(sql):
            seen.append(sql)
            return [["45", "8c0d-uuid", "auth0|8c0d-uuid"], ["46", None, None]]
        got = verify_notify.account_identities([45, 46], query=q)
        self.assertIn("neptuneprofessionalid", seen[0])
        self.assertEqual(got["45"]["professional_id"], "8c0d-uuid")
        self.assertEqual(got["46"]["professional_id"], "", "an account with no identity has none (held by the driver)")

    def test_the_identity_lookup_honours_the_lookup_command_override(self):
        """Kept from #1295/#1298: CREDIT_VERIFY_AUTH_LOOKUP_CMD (AUTH_LOOKUP_CMD) still names the
        command the identity lookup runs."""
        fake = os.path.join(self.tmp, "trino.sh")
        Path(fake).write_text('#!/bin/sh\ncat > "$0.sql"\nprintf \'"45","8c0d-uuid",""\\n\'\n')
        os.chmod(fake, 0o755)
        with unittest.mock.patch.object(verify_notify, "AUTH_LOOKUP_CMD", fake):
            got = verify_notify.account_identities([45])
        self.assertIn("neptuneprofessionalid", Path(fake + ".sql").read_text())
        self.assertEqual(got["45"]["professional_id"], "8c0d-uuid")

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



class PreviewAcceptedTests(unittest.TestCase):
    """t01b 584 / p1 579: the preview renders exactly the check's accepted set; every outcomes file names the head."""

    def setUp(self):
        import importlib.util
        spec = importlib.util.spec_from_file_location("credit_review_cli_pa", str(ROOT / "scripts" / "credit-review.py"))
        self.cli = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.cli)
        self.d = Path(tempfile.mkdtemp())
        self.chk = self.d / "check.json"
        self.chk.write_text(json.dumps({"mode": "dry-run", "accepted": [{"user": "11"}, {"user": "12"}], "outcomes": []}))
        self.lst = self.d / "list.json"
        self.lst.write_text(json.dumps({"users": [{"user_id": str(u)} for u in range(1, 13)]}))
        self.p = unittest.mock.patch.object(verify_notify, "PREVIEW_ONLY", None)
        self.p.start()

    def tearDown(self):
        self.p.stop()

    def ns(self, **kw):
        import argparse
        base = dict(preview_accepted=str(self.chk), preview=str(self.d / "prev"), mode="dry-run", check_recipients=False,
                    list=str(self.lst), max_users=5)
        return argparse.Namespace(**{**base, **kw})

    def test_the_cli_loads_the_accepted_set_and_walks_the_whole_list(self):
        a = self.ns()
        self.assertEqual(self.cli.preview_accepted(a), "")
        self.assertEqual((verify_notify.PREVIEW_ONLY, a.max_users), (frozenset({"11", "12"}), 12))
        for bad in (dict(mode="apply"), dict(check_recipients=True), dict(preview="")):
            self.assertIn("goes with --preview", self.cli.preview_accepted(self.ns(**bad)))
        self.chk.write_text(json.dumps({"mode": "apply", "accepted": []}))          # an apply file is not a check
        self.assertIn("--preview-accepted", self.cli.preview_accepted(self.ns()))
        self.chk.write_text(json.dumps({"mode": "dry-run", "outcomes": []}))         # no accepted set
        self.assertIn("--preview-accepted", self.cli.preview_accepted(self.ns()))
        self.assertEqual(self.cli.preview_accepted(self.ns(preview_accepted="")), "")   # off by default

    def test_send_all_renders_only_the_accepted_users_and_calls_no_gate_for_the_rest(self):
        calls = []
        def run(argv):
            calls.append(json.load(open(argv[argv.index("--credits-file") + 1]))["user"]["id"])
            return subprocess.CompletedProcess(argv, 0, "DRY-RUN uvn-status initial email credits=1\nx\n", "")
        pays = [{"user": {"id": str(u), "email": f"u{u}@x.com"}, "credits": [{"request_id": f"r{u}"}]} for u in range(1, 13)]
        prev = self.d / "prev"; prev.mkdir()
        verify_notify.PREVIEW_ONLY = frozenset({"11", "12"})
        verify_notify.send_all(pays, Report(), mode="dry-run", runner=run, preview_dir=str(prev), workers=1)
        self.assertEqual((calls, sorted(f for f in os.listdir(prev) if f.endswith(".txt"))), (["11", "12"], ["11.txt", "12.txt"]))
        calls.clear()
        verify_notify.send_all(pays, Report(), mode="dry-run", runner=run, check_recipients=True, workers=1)
        self.assertEqual(len(calls), 12)                         # the CHECK itself is never narrowed

    def test_the_outcomes_file_names_the_deployed_head_and_the_lists_signed_on(self):
        import argparse
        sha = self.d / ".deployed-sha"; sha.write_text("b" * 40 + "\n")
        out = self.d / "o.json"
        with unittest.mock.patch.object(verify_notify, "DEPLOYED_SHA_PATH", str(sha)), \
                unittest.mock.patch.object(verify_notify, "LIST_SIGNED_ON", "c" * 40):
            self.assertEqual(self.cli.write_outcomes(argparse.Namespace(outcomes_json=str(out), mode="dry-run",
                                                                        segment="paid"), Report()), "")
        d = json.loads(out.read_text())
        self.assertEqual((d["deployed"], d["signed_on"]), ("b" * 40, "c" * 40))



class SignedAcceptedTests(SignedHeadTests):
    """Fable [key=apply-sized-to-list] (amended 586; C p4 sent 50 of a signed 51): the apply is sized from the signed
    check's attempt cap, sends only its accepted set, and the sent set equals it or the run exits 3."""

    def setUp(self):
        super().setUp()
        import importlib.util
        spec = importlib.util.spec_from_file_location("credit_review_cli_sa", str(ROOT / "scripts" / "credit-review.py"))
        self.cli = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.cli)
        self.chk = self.d / "check.json"
        self.chk.write_text(json.dumps({"mode": "dry-run", "max_users": 51,
                                        "accepted": [{"user": u} for u in ("1", "2", "3")], "outcomes": []}))
        self.sub = self.d / "signed-subset.json"           # a NEW list of exactly the signed rows
        self.sub.write_text(json.dumps({"users": [{"user_id": u, "paid": True} for u in ("1", "2", "3")]}))
        self.q = [unittest.mock.patch.object(verify_notify, "APPLY_ONLY", None),
                  unittest.mock.patch.object(verify_notify, "APPLY_REPORTS", [])]
        for x in self.q:
            x.start()

    def tearDown(self):
        for x in self.q:
            x.stop()
        super().tearDown()

    def ns(self, **kw):
        import argparse
        return argparse.Namespace(**{"signed_accepted": str(self.chk), "mode": "apply", "max_users": None, "page": False,
                                     "list": str(self.sub), "segment": "paid", **kw})

    def test_the_run_is_sized_from_the_signed_checks_attempt_cap_never_a_default(self):
        a = self.ns()
        self.assertEqual(self.cli.signed_accepted(a), ("", frozenset({"1", "2", "3"})))
        self.assertEqual((a.max_users, verify_notify.APPLY_ONLY), (51, frozenset({"1", "2", "3"})))
        why, _ = self.cli.signed_accepted(self.ns(max_users=50))                       # the C p4 shape: 50 < 51
        self.assertIn("apply-sized-to-list", why)
        self.assertEqual(self.cli.signed_accepted(self.ns(max_users=50, page=True))[0], "")   # the tick pages
        self.assertIn("--mode apply", self.cli.signed_accepted(self.ns(mode="dry-run"))[0])
        # Fable rule (r5, E page 2): the PARENT list (rows outside the signed set) refuses; paged (the tick) it may
        parent = self.d / "parent.json"
        parent.write_text(json.dumps({"users": [{"user_id": u, "paid": True} for u in ("1", "2", "3", "4")]
                                      + [{"user_id": "9", "paid": False}]}))
        why, _ = self.cli.signed_accepted(self.ns(list=str(parent)))
        self.assertIn("signed-subset-list: the list holds 1 paid user(s) outside the signed accepted set (4)", why)
        self.assertEqual(self.cli.signed_accepted(self.ns(list=str(parent), page=True))[0], "")
        self.assertIn("needs the --list", self.cli.signed_accepted(self.ns(list=None))[0])
        self.chk.write_text(json.dumps({"mode": "dry-run", "accepted": []}))           # no attempt cap recorded
        self.assertIn("no attempt cap", self.cli.signed_accepted(self.ns())[0])

    def test_only_the_signed_set_is_sent_and_a_short_send_exits_3(self):
        run = lambda argv: subprocess.CompletedProcess(argv, 0, "POSTED email message=1 credits=1\n", "")
        verify_notify.APPLY_ONLY = frozenset({"1", "2", "3"})
        rep = self.apply(run, n=5)                                                     # users 0..4 offered
        self.assertEqual(sorted(s["user"] for s in rep.sent), ["1", "2", "3"])
        self.assertEqual(sorted(o["user"] for o in rep.outcomes if "not_in_signed_accepted" in o["reason"]), ["0", "4"])
        acc = frozenset({"1", "2", "3"})
        self.assertEqual(verify_notify.signed_set_mismatch(verify_notify.APPLY_REPORTS, acc, page=False), "")
        short = frozenset({"1", "2", "3", "9"})                                        # 9 signed, never sent
        self.assertIn("SIGNED SET NOT SENT WHOLE: 3 of 4", verify_notify.signed_set_mismatch([rep], short, page=False))
        self.assertEqual(verify_notify.signed_set_mismatch([rep], short, page=True), "")
        self.assertIn("SENT OUTSIDE THE SIGNED SET", verify_notify.signed_set_mismatch([rep], frozenset({"1"}), page=True))

    def test_the_cli_exits_3_when_the_sent_set_is_not_the_signed_set(self):
        run = lambda argv: subprocess.CompletedProcess(argv, 0, "POSTED email message=1 credits=1\n", "")

        def fn(args):
            self.assertEqual(args.max_users, 51)
            self.apply(run, n=3)                                                       # sends 1, 2 (0 is outside)
            return 0
        import argparse
        ns = argparse.Namespace(cmd="uvn-status", mode="apply", fn=fn, signed_accepted=str(self.chk), max_users=None,
                                page=False, max_users_default=50, preview_accepted="", preview="",
                                list=str(self.sub), segment="paid")
        with unittest.mock.patch.object(self.cli, "parser") as par, \
                unittest.mock.patch.object(self.cli, "write_outcomes", lambda a, r: ""):
            par.return_value.parse_args.return_value = ns
            self.assertEqual(self.cli.main([]), 3)                                     # 3 was signed, never sent

    def test_need_asks_send_takes_the_same_rule(self):
        import contextlib, io
        from credit_review import need_asks
        base = ["send", "--list", str(self.d / "none.json"), "--segment", "paid", "--signed-accepted", str(self.chk)]
        parent = self.d / "parent-n.json"
        parent.write_text(json.dumps({"users": [{"user_id": u, "paid": True} for u in ("1", "2", "3", "4")]}))
        for extra, want in ((["--mode", "dry-run"], "is for --mode apply"),
                            (["--mode", "apply", "--max-users", "50"], "apply-sized-to-list"),
                            (["--mode", "apply", "--list", str(parent)], "signed-subset-list")):
            out = io.StringIO()
            with contextlib.redirect_stdout(out):
                self.assertEqual(need_asks._main(base + extra), 2)
            self.assertIn(want, out.getvalue())


class AfterTimeoutUnmeasuredBarTests(unittest.TestCase):
    """A timed-out POST whose retry answers is UNMEASURED, and the bar applies to it exactly as it applies to a
    timeout that raised: once enough of the batch is unmeasured the apply walk stops instead of sending on."""

    def _send(self, n, stopped_after):
        calls = []

        def run(argv):
            uid = json.load(open(argv[argv.index("--credits-file") + 1]))["user"]["id"]
            calls.append(uid)
            res = subprocess.CompletedProcess(argv, 1, "", "REFUSED user already messaged in the last 7 days\n")
            res.after_timeout = 1
            return res

        payloads = [{"user": {"id": str(i), "email": f"u{i}@x.com"},
                     "credits": [{"request_id": f"r{i}"}]} for i in range(1, n + 1)]
        rep = verify_notify.Report()
        with unittest.mock.patch.object(verify_notify, "attach_identities", lambda ps, r: (ps, [])), \
             unittest.mock.patch.object(verify_notify, "APPLY_WORKERS", 1), \
             tempfile.TemporaryDirectory() as d, \
             unittest.mock.patch.object(verify_notify, "APPLY_LOCK_PATH", os.path.join(d, "apply.lock")):
            verify_notify.send_all(payloads, rep, mode="apply", runner=run, extra=["--campaign", "uvn-status"])
        self.assertEqual(len(calls), stopped_after)
        self.assertEqual(rep.timeout_users, stopped_after)
        return rep

    def test_the_after_timeout_branch_honours_the_unmeasured_bar(self):
        rep = self._send(12, 5)
        self.assertEqual(rep.unmeasured_stop_at, 5)
        self.assertTrue(rep.failed)
        self.assertIn("UNMEASURED STOP: 5 of 12", rep.stopped_on_unmeasured)
        self.assertIn("UNMEASURED STOP: 5 of 12", rep.render("apply"))
        self.assertEqual([o["result"] for o in rep.outcomes], ["timeout"] * 5)
        self.assertEqual(rep.refused_users, 0)

    def test_below_the_bar_the_walk_continues(self):
        rep = self._send(4, 4)
        self.assertEqual(rep.timeout_users, 4)
        self.assertFalse(rep.failed)
        self.assertEqual(rep.stopped_on_unmeasured, "")


class ApplyPoolTests(unittest.TestCase):
    """[key=apply-pool] (captain 2026-11-11, work order item 1): the apply loop runs a bounded pool of 6 note steps,
    each user carrying an idempotency key (campaign|user|UTC day). The three things this must never do: send twice for
    one user, send again on a re-run, or fan out past the bound."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="apply-pool-")
        self.ledger = os.path.join(self.tmp, "ledger.sqlite3")
        self.lock = os.path.join(self.tmp, "apply.lock")
        self.day = verify_ledger.stamp()[:10]

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def payloads(self, users):
        return [{"user": {"id": str(u), "email": f"u{u}@x.com"}, "credits": [{"request_id": f"r{u}"}]} for u in users]

    def send(self, payloads, runner, workers=None):
        rep = Report()
        patches = [unittest.mock.patch.object(verify_notify, "attach_identities", lambda ps, r: (ps, [])),
                   unittest.mock.patch.object(verify_notify, "APPLY_LOCK_PATH", self.lock)]
        if workers is not None:
            patches.append(unittest.mock.patch.object(verify_notify, "APPLY_WORKERS", workers))
        for x in patches:
            x.start()
        try:
            verify_notify.send_all(payloads, rep, mode="apply", runner=runner, extra=["--campaign", "uvn-status"],
                                   ledger_path=self.ledger, campaign="uvn-status")
        finally:
            for x in reversed(patches):
                x.stop()
        return rep

    def claiming_runner(self, calls):
        """A gate that does what the real one does: claim the user in the ledger BEFORE posting."""
        def run(argv):
            body = json.loads(Path(argv[argv.index("--credits-file") + 1]).read_text())
            calls.append(body["user"]["id"])
            db = verify_ledger.connect(self.ledger)
            try:
                got = verify_ledger.claim(db, user_key=body["user"]["email"], day=self.day,
                                          request_ids=[c["request_id"] for c in body["credits"]],
                                          message_type="email", approved_by=CAPTAIN_UID, approval_ref="ref",
                                          campaign="uvn-status")
            finally:
                db.close()
            if got.get("result") != "claimed":
                return subprocess.CompletedProcess(argv, 0, "SKIPPED already told\n", "")
            return subprocess.CompletedProcess(argv, 0, "POSTED email message=1 credits=1\n", "")
        return run

    def test_a_rerun_sends_nothing(self):
        """The exit criterion, literally: run the same batch twice and the second run opens no note step at all."""
        calls = []
        run = self.claiming_runner(calls)
        first = self.send(self.payloads([1, 2, 3]), run)
        self.assertEqual(sorted(calls), ["1", "2", "3"])
        self.assertEqual(first.sent_notes, 3)
        calls.clear()
        second = self.send(self.payloads([1, 2, 3]), run)
        self.assertEqual(calls, [], "a re-run must not even call the gate for a user the ledger already noted today")
        self.assertEqual(second.sent_notes, 0)
        # SKIPPED, not deferred: the gate's own answer for this user is "SKIPPED already told", so the served numbers
        # do not move - the re-run just never pays for the subprocess to say it.
        self.assertEqual(second.skipped, 3)
        self.assertEqual(second.deferred_users, 0)
        self.assertTrue(all("already_notified_today" in o["reason"] for o in second.outcomes), second.outcomes)
        self.assertFalse(second.failed, "a re-run that sends nothing is a KNOWN outcome, not a failed round")

    def test_two_workers_cannot_both_send_for_the_same_user(self):
        """The idempotency key is checked BEFORE a worker starts, so a duplicate payload is a named deferral and the
        gate is never called for it - whatever the pool size."""
        calls = []
        run = self.claiming_runner(calls)
        dup = self.payloads([7]) + self.payloads([7])
        rep = self.send(dup, run, workers=6)
        self.assertEqual(calls, ["7"], "exactly one note step for one user, never two")
        self.assertEqual(rep.sent_notes, 1)
        self.assertEqual(rep.deferred_users, 1)
        self.assertTrue(any("duplicate_idempotency_key" in o["reason"] for o in rep.outcomes), rep.outcomes)

    def test_a_deploy_mid_batch_defers_every_user_not_yet_started(self):
        """The head check is a pre-START guard. With a pool, the users already in flight when a deploy lands may still
        send (they started under the signed head); every user not yet started is deferred, and the bound is the pool."""
        import threading
        sha = Path(self.tmp) / "deployed.sha"
        sha.write_text("a" * 40 + "\n")
        barrier = threading.Barrier(2)
        sent = []

        def run(argv):
            uid = json.loads(Path(argv[argv.index("--credits-file") + 1]).read_text())["user"]["id"]
            sha.write_text("b" * 40 + "\n")          # the deploy lands while both in-flight workers are inside
            barrier.wait(timeout=10)
            sent.append(uid)
            return subprocess.CompletedProcess(argv, 0, "POSTED email message=1 credits=1\n", "")

        rep = Report()
        with unittest.mock.patch.object(verify_notify, "attach_identities", lambda ps, r: (ps, [])), \
             unittest.mock.patch.object(verify_notify, "APPLY_LOCK_PATH", self.lock), \
             unittest.mock.patch.object(verify_notify, "APPLY_WORKERS", 2), \
             unittest.mock.patch.object(verify_notify, "DEPLOYED_SHA_PATH", str(sha)), \
             unittest.mock.patch.object(verify_notify, "LIST_SIGNED_ON", "a" * 40), \
             unittest.mock.patch.object(verify_notify, "HEAD_REFUSED", 0):
            verify_notify.send_all(self.payloads([0, 1, 2, 3, 4]), rep, mode="apply", runner=run,
                                   extra=["--campaign", "uvn-status"])
            self.assertEqual(verify_notify.HEAD_REFUSED, 3)      # read inside the patch: the counter is a module global
        self.assertEqual(sorted(sent), ["0", "1"], "only the two users already in flight when the deploy landed")
        self.assertEqual(rep.deferred_users, 3)
        self.assertTrue(all("sha_mismatch" in o["reason"] for o in rep.outcomes), rep.outcomes)

    def test_the_pooled_budget_guard_stops_submitting_at_the_wall_clock_deadline(self):
        """With a pool the worst case is ONE retry budget of wall clock (the workers run at once), so the guard is a
        deadline: once `spent + WORST_USER_S` would pass the share, nothing more is started and the rest stay owed."""
        clock = {"t": 0.0}
        started = []

        def run(argv):
            started.append(json.loads(Path(argv[argv.index("--credits-file") + 1]).read_text())["user"]["id"])
            clock["t"] += 120.0
            return subprocess.CompletedProcess(argv, 0, "POSTED email message=1 credits=1\n", "")

        rep = Report()
        with unittest.mock.patch.object(verify_notify, "attach_identities", lambda ps, r: (ps, [])), \
             unittest.mock.patch.object(verify_notify, "APPLY_LOCK_PATH", self.lock), \
             unittest.mock.patch.object(verify_notify, "APPLY_WORKERS", 2), \
             unittest.mock.patch.object(verify_notify.time, "monotonic", lambda: clock["t"]), \
             unittest.mock.patch.object(verify_notify.time, "sleep", lambda s: None):
            try:
                verify_notify.set_apply_budget(200)
                verify_notify.send_all(self.payloads([0, 1, 2, 3, 4]), rep, mode="apply", runner=run,
                                       extra=["--campaign", "uvn-status"])
            finally:
                verify_notify.set_apply_budget(None)
        self.assertEqual(sorted(started), ["0", "1"], "the two in flight fit; the third would not")
        self.assertEqual(rep.budget_deferred_users, 3)
        self.assertEqual(rep.refused_users, 0, "a budget deferral is never a refusal")
        self.assertTrue(all("apply_budget" in o["reason"] for o in rep.outcomes if o["result"] == "deferred"))

    def test_a_stop_joins_the_pool_so_a_late_send_is_recorded_not_lost(self):
        """QA on #1884: the pool used to be shut down with `wait=False`, so a worker already in flight when the
        systemic stop fired could POST *after* `_send_loop` returned and after `send_all` released the apply lock -
        a real note to a real user that appeared in no counter and in no outcomes file. The stop now drains: every
        in-flight call is joined and accounted for before the lock is released.

        Three cheap failures trip the systemic bar (`fail_stop_after` = max(3, 2% of walked)) while user 4 is still
        blocked inside its gate; 4 only completes after the stop has fired.
        """
        release = threading.Event()
        in_flight = threading.Event()

        def run(argv):
            body = json.loads(Path(argv[argv.index("--credits-file") + 1]).read_text())
            uid = str((body.get("user") or {}).get("id") or "")
            if uid == "4":
                in_flight.set()
                release.wait(timeout=15)
                return subprocess.CompletedProcess(argv, 0, "POSTED email message=1 credits=1\n", "")
            if uid in ("1", "2", "3"):
                return subprocess.CompletedProcess(argv, 1, "", "")
            return subprocess.CompletedProcess(argv, 0, "SKIPPED\n", "")

        threading.Timer(1.5, release.set).start()
        rep = Report()
        with unittest.mock.patch.object(verify_notify, "attach_identities", lambda ps, r: (ps, [])), \
             unittest.mock.patch.object(verify_notify, "APPLY_LOCK_PATH", self.lock), \
             unittest.mock.patch.object(verify_notify, "APPLY_WORKERS", 3):
            verify_notify.send_all(self.payloads([1, 2, 3, 4]), rep, mode="apply", runner=run,
                                   extra=["--campaign", "uvn-status"])

        self.assertTrue(rep.stopped_on_failures)
        self.assertEqual(rep.failed_users, 3)
        self.assertTrue(in_flight.is_set(), "the worker was still running when the stop fired")
        # THE ASSERTION THAT MATTERS: the worker that was mid-call across the stop had its POST counted.
        self.assertEqual(rep.sent_notes, 1)
        self.assertEqual([s["user"] for s in rep.sent], ["4"])
        # ...and nobody is silently absent from the accounting.
        accounted = {str(o["user"]) for o in rep.outcomes} | {str(s["user"]) for s in rep.sent}
        self.assertEqual(accounted, {"1", "2", "3", "4"})


if __name__ == "__main__":
    unittest.main(verbosity=2)
