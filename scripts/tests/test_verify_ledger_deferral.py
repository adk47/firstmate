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


if __name__ == "__main__":
    unittest.main()
