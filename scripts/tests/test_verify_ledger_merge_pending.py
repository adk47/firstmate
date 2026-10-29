"""verify_ledger rules for merge-pending (go-live-today line M1; send-locked until the captain's own yes): a notice,
one note per merge request ever, never within 7 days of another note from the gate, never an ask."""
from __future__ import annotations

import credit_test_env  # noqa: F401 - first: test logs never reach the production run.log
import sys
import tempfile
import unittest
from datetime import datetime
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
from credit_review import verify_ledger as vl  # noqa: E402

KW = dict(message_type="email", approved_by="U7RP6HKUZ", approval_ref="ref", user_key="jane@example.com", user_id="42")


class MergePendingTest(unittest.TestCase):
    def setUp(self):
        self.db = vl.connect(str(Path(tempfile.mkdtemp()) / "ledger.sqlite3"))

    def claim(self, campaign, ids, day):
        return vl.claim(self.db, day=day, request_ids=list(ids), campaign=campaign,
                        now=datetime.fromisoformat(day + "T01:00:00+00:00"), **KW)

    def sent(self, c):
        self.assertEqual(c["result"], "claimed", c)
        vl.finalize(self.db, message_row=c["message_row"], status="sent", message_id="m")

    def test_registered_as_a_notice_not_an_ask(self):
        self.assertIn("merge-pending", vl.CAMPAIGNS)
        self.assertIn("merge-pending", vl.NOTICE_CAMPAIGNS)
        self.assertNotIn("merge-pending", vl.ASK_CAMPAIGNS)

    def test_once_per_merge_request_and_seven_day_defer(self):
        self.sent(self.claim("merge-pending", ["merge-a"], "2026-10-28"))
        self.assertEqual(self.claim("merge-pending", ["merge-a"], "2026-12-30")["result"], "already_notified")
        got = self.claim("merge-pending", ["merge-b"], "2026-11-02")
        self.assertEqual((got["result"], got.get("reason")), ("recent", "messaged_7d"))
        self.assertEqual(self.claim("merge-pending", ["merge-b"], "2026-11-05")["result"], "claimed")

    def test_any_other_note_in_7_days_defers_it(self):
        self.sent(self.claim("status-team-review", ["r1"], "2026-10-28"))
        got = self.claim("merge-pending", ["merge-a"], "2026-10-30")
        self.assertEqual((got["result"], got.get("reason")), ("recent", "messaged_7d"))


if __name__ == "__main__":
    unittest.main()
