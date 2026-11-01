"""verify_ledger.log_deferral: a core_notice_within_7d hold (Fable sender map 2026-10-27 item 2) is LOGGED in
verify_messages as status 'deferred' and is never a lock. It never takes the day's message, never blocks the
same credits, never starts or counts a refusal hold, is never a "never delivered" ask to b0_gap, and logs once
per user, campaign, day and reason."""
from __future__ import annotations

import credit_test_env  # noqa: F401 - first: test logs never reach the production run.log
import importlib.util
import json
import sqlite3
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
from credit_review import verify_ledger as vl  # noqa: E402

spec = importlib.util.spec_from_file_location("b0_gap", ROOT / "scripts" / "paid-status" / "b0_gap.py")
b0 = importlib.util.module_from_spec(spec)
spec.loader.exec_module(b0)
DAY = "2026-10-27"
KW = dict(message_type="email", approved_by="U7RP6HKUZ", approval_ref="ref")


class DeferralTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.path = str(Path(self.tmp) / "ledger.sqlite3")
        self.db = vl.connect(self.path)

    def defer(self, campaign="uvn-status", user_key="jane@example.com", user_id="42", ids=("r1",), day=DAY):
        return vl.log_deferral(self.db, campaign=campaign, user_key=user_key, user_id=user_id, day=day,
                               request_ids=list(ids), reason="core_notice_within_7d", detail="approvedNotice within 7d",
                               **KW)

    def test_logged_once_per_user_campaign_day(self):
        self.assertEqual(self.defer()["result"], "logged")
        self.assertEqual(self.defer()["result"], "already_logged")
        self.assertEqual(self.defer(user_key="new@example.com")["result"], "already_logged")   # same Muso id
        self.assertEqual(self.defer(campaign="status-team-review")["result"], "logged")
        self.assertEqual(self.defer(day="2026-10-28")["result"], "logged")
        rows = self.db.execute("SELECT status, reason, account_id, request_ids_json FROM verify_messages").fetchall()
        self.assertEqual(len(rows), 3)
        self.assertEqual(tuple(rows[0]), ("deferred", "core_notice_within_7d: approvedNotice within 7d", "42", '["r1"]'))

    def test_a_deferral_is_never_a_lock(self):
        self.defer()
        self.defer(campaign="status-team-review")
        self.assertFalse(vl.capped(self.db, user_key="jane@example.com", day=DAY, user_id="42"))
        self.assertEqual(vl.blocked_ids(self.db, ["r1"], "uvn-status"), set())
        self.assertEqual(vl.refusal_hold(self.db, "status-team-review", "jane@example.com", user_id="42"), {})
        self.assertEqual(self.db.execute("SELECT COUNT(*) FROM verify_requests").fetchone()[0], 0)
        self.assertFalse(b0.ask_never_delivered(self.db, "jane@example.com", 42))
        c = vl.claim(self.db, user_key="jane@example.com", day=DAY, request_ids=["r1"], campaign="uvn-status",
                     user_id="42", **KW)
        self.assertEqual(c["result"], "claimed")

    def test_unknown_reason_or_campaign_is_refused(self):
        with self.assertRaises(ValueError):
            vl.log_deferral(self.db, campaign="uvn-status", user_key="a@b.co", day=DAY, request_ids=["r1"],
                            reason="anything", **KW)
        with self.assertRaises(ValueError):
            self.defer(campaign="not-a-campaign")
        self.assertEqual(self.db.execute("SELECT COUNT(*) FROM verify_messages").fetchone()[0], 0)

    def test_cli(self):
        cmd = [sys.executable, "-I", str(ROOT / "scripts" / "credit_review" / "verify_ledger.py"), "--db", self.path,
               "log-deferral", "--campaign", "status-doc-received", "--user-key", "jane@example.com", "--user-id", "42",
               "--day", DAY, "--request-ids", "r1,r2", "--message-type", "email", "--approved-by", "U7RP6HKUZ",
               "--approval-ref", "ref", "--reason", "core_notice_within_7d", "--detail", "claim updated within 7d"]
        p = subprocess.run(cmd, capture_output=True, text=True, check=False)
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(json.loads(p.stdout)["result"], "logged")
        db = sqlite3.connect(self.path)
        self.assertEqual(db.execute("SELECT status, n_credits FROM verify_messages").fetchone(), ("deferred", 2))
        bad = subprocess.run(cmd[:-4] + ["--reason", "other"], capture_output=True, text=True, check=False)
        self.assertNotEqual(bad.returncode, 0)



class NoChannelTest(unittest.TestCase):
    """r5 / p1 [no-channel]: a user whose latest delivery outcome is an Intercom action_forbidden rejection is never
    re-attempted by ANY campaign until a person clears it; a later successful send ends it."""

    def test_action_forbidden_holds_every_campaign_until_a_person_clears_it(self):
        import tempfile as _t
        from datetime import datetime as _dt, timedelta as _td, timezone as _tz
        from credit_review import verify_ledger as vl
        db = vl.connect(str(Path(_t.mkdtemp()) / "l.sqlite3"))
        t0 = _dt(2026, 10, 30, 13, 4, tzinfo=_tz.utc)
        c = vl.claim(db, campaign="uvn-status", user_key="a@x.com", day="2026-10-30", request_ids=["r1"],
                     message_type="email", approved_by="U", approval_ref="r", user_id="7", now=t0)
        vl.finalize(db, message_row=c["message_row"], status="rejected", reason="intercom error: action_forbidden")
        self.assertIn("action_forbidden", vl.no_channel(db, "a@x.com", "7"))
        self.assertIn("action_forbidden", vl.no_channel(db, "new@x.com", "7"))           # same user, new email
        # a LATER unrelated refusal (identity, copy) proves nothing about the channel: still held
        db.execute("INSERT INTO verify_messages (campaign, kind, user_key, day, status, message_type, request_ids_json, "
                   "n_credits, approved_by, approval_ref, reason, attempts, created_at, updated_at, account_id) VALUES "
                   "('status-team-review','initial','a@x.com','2026-10-31','refused','email','[]',0,'U','r',"
                   "'the account email matches 0 Intercom users (need exactly 1); not sending',1,?,?,'7')",
                   (vl.stamp(_dt.now(_tz.utc) + _td(hours=1)), vl.stamp(_dt.now(_tz.utc) + _td(hours=1))))
        self.assertIn("action_forbidden", vl.no_channel(db, "a@x.com", "7"))
        for camp in ("uvn-status", "status-team-review", "proof-need-ask", "claim-proof-ask"):
            got = vl.claim(db, campaign=camp, user_key="a@x.com", day="2026-11-09", request_ids=["r2"],
                           message_type="email", approved_by="U", approval_ref="r", user_id="7",
                           now=t0 + _td(days=10), enforce_cap=False)
            self.assertEqual(got["result"], "no_channel", camp)
        # any other rejection reason is not a channel fact
        db2 = vl.connect(str(Path(_t.mkdtemp()) / "l.sqlite3"))
        c = vl.claim(db2, campaign="uvn-status", user_key="b@x.com", day="2026-10-30", request_ids=["r1"],
                     message_type="email", approved_by="U", approval_ref="r", user_id="8", now=t0)
        vl.finalize(db2, message_row=c["message_row"], status="rejected", reason="intercom error: server_error")
        self.assertEqual(vl.no_channel(db2, "b@x.com", "8"), "")
        # p1 17:35Z: #1511's terminal no-channel refusal (email unreachable, no in-app route) is the same fact
        db3 = vl.connect(str(Path(_t.mkdtemp()) / "l.sqlite3"))
        db3.execute("INSERT INTO verify_messages (campaign, kind, user_key, day, status, message_type, request_ids_json, "
                    "n_credits, approved_by, approval_ref, reason, attempts, created_at, updated_at, account_id) VALUES "
                    "('uvn-status','initial','c@x.com','2026-10-31','refused','email','[]',0,'U','r',"
                    "'no_channel: email_unreachable:hard_bounced (Intercom will not email this contact); x',1,"
                    "'2026-10-31T10:00:00Z','2026-10-31T10:00:01Z','9')")
        self.assertIn("email_unreachable", vl.no_channel(db3, "c@x.com", "9"))
        db3.execute("UPDATE verify_messages SET reason='the account email matches 0 Intercom users'")
        self.assertEqual(vl.no_channel(db3, "c@x.com", "9"), "")                   # other refusals: not a channel fact
        # a LATER successful send to the user means the channel works again
        c = vl.claim(db2, campaign="uvn-status", user_key="b@x.com", day="2026-10-30", request_ids=["r9"],
                     message_type="email", approved_by="U", approval_ref="r", user_id="8", now=t0, enforce_cap=False)
        vl.finalize(db2, message_row=c["message_row"], status="rejected", reason="intercom error: action_forbidden")
        self.assertTrue(vl.no_channel(db2, "b@x.com", "8"))
        db2.execute("INSERT INTO verify_messages (campaign, kind, user_key, day, status, message_type, request_ids_json, "
                    "n_credits, approved_by, approval_ref, attempts, created_at, updated_at, account_id) VALUES "
                    "('status-team-review','initial','b@x.com','2026-11-02','sent','email','[]',0,'U','r',1,"
                    "'2026-11-02T10:00:00Z','2026-11-02T10:00:01Z','8')")
        self.assertEqual(vl.no_channel(db2, "b@x.com", "8"), "")
        # a person's clear (after the rejection) releases it; a clear needs a name and a reason
        with self.assertRaises(ValueError):
            vl.clear_no_channel(db, user_key="a@x.com", user_id="7", cleared_by="", ref="x")
        vl.clear_no_channel(db, user_key="a@x.com", user_id="7", cleared_by="U7RP6HKUZ", ref="contact unblocked",
                            now=_dt.now(_tz.utc))
        self.assertEqual(vl.no_channel(db, "a@x.com", "7"), "")
        # QA #1588: a NEW refusal after the clear - even in the same second - holds again (row order, not the clock)
        c = vl.claim(db, campaign="uvn-status", user_key="a@x.com", day="2026-11-10", request_ids=["r7"],
                     message_type="email", approved_by="U", approval_ref="r", user_id="7", enforce_cap=False)
        vl.finalize(db, message_row=c["message_row"], status="rejected", reason="intercom error: action_forbidden")
        self.assertIn("action_forbidden", vl.no_channel(db, "a@x.com", "7"))
        # QA #1588: an unrelated rejection AFTER the action_forbidden one never ends the hold
        db.execute("INSERT INTO verify_messages (campaign, kind, user_key, day, status, message_type, request_ids_json, "
                   "n_credits, approved_by, approval_ref, reason, attempts, created_at, updated_at, account_id) VALUES "
                   "('status-team-review','initial','a@x.com','2026-11-11','rejected','email','[]',0,'U','r',"
                   "'intercom error: server_error',1,'2026-11-11T00:00:00Z','2099-01-01T00:00:00Z','7')")   # in flight
        self.assertIn("action_forbidden", vl.no_channel(db, "a@x.com", "7"))

if __name__ == "__main__":
    unittest.main()
