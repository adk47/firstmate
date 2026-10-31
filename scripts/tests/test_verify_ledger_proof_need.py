"""verify_ledger rules for proof-need-ask (proof-loop captain card L11c; send-locked until the captain's yes):
an ASK handled like gap-ask. Once per request, ever; it never crosses a gap ask on the same request (either way);
it may follow a status-doc-received note inside 7 days (the receipt promised this message) but no other note;
it counts for the shared one-ask locks."""
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

KW = dict(message_type="email", approved_by="U7RP6HKUZ", approval_ref="ref")


class ProofNeedAskTest(unittest.TestCase):
    def setUp(self):
        self.db = vl.connect(str(Path(tempfile.mkdtemp()) / "ledger.sqlite3"))

    def claim(self, campaign, ids, day, user="jane@example.com", uid="42"):
        return vl.claim(self.db, user_key=user, day=day, request_ids=list(ids), campaign=campaign, user_id=uid,
                        now=datetime.fromisoformat(day + "T01:00:00+00:00"), **KW)

    def sent(self, c):
        self.assertEqual(c["result"], "claimed", c)
        vl.finalize(self.db, message_row=c["message_row"], status="sent", message_id=f"m{c['message_row']}")

    def test_registered_as_an_ask_like_gap_ask(self):
        self.assertIn("proof-need-ask", vl.CAMPAIGNS)
        self.assertIn("proof-need-ask", vl.ASK_CAMPAIGNS)
        self.assertEqual(set(vl.GAP_LIKE), {"gap-ask", "proof-need-ask"})

    def test_once_per_request_ever_and_it_counts_as_an_ask(self):
        self.sent(self.claim("proof-need-ask", ["r1"], "2026-10-28"))
        self.assertEqual(self.claim("proof-need-ask", ["r1"], "2026-12-30")["result"], "already_notified")
        self.assertTrue(vl.asked_within(self.db, user_key="jane@example.com", day="2026-11-01", user_id="42"))
        # another request of the same user is its own ask (after the 7-day no-recontact)
        self.sent(self.claim("proof-need-ask", ["r2"], "2026-11-10"))

    def test_an_earlier_ask_on_the_request_does_not_block_it_but_a_gap_ask_does(self):
        self.sent(self.claim("uvn-status", ["r1"], "2026-09-01"))   # the document came back after that ask
        self.assertEqual(vl.blocked_ids(self.db, ["r1"], "proof-need-ask"), set())
        self.sent(self.claim("gap-ask", ["r2"], "2026-09-20"))
        self.assertEqual(vl.blocked_ids(self.db, ["r2"], "proof-need-ask"), {"r2"})
        self.sent(self.claim("proof-need-ask", ["r3"], "2026-10-28"))
        self.assertEqual(vl.blocked_ids(self.db, ["r3"], "gap-ask"), {"r3"})

    def test_it_may_follow_the_receipt_inside_7_days_but_no_other_note(self):
        self.sent(self.claim("status-doc-received", ["r1"], "2026-10-26"))
        self.assertEqual(self.claim("proof-need-ask", ["r1"], "2026-10-28")["result"], "claimed")
        self.sent(self.claim("status-team-review", ["s1"], "2026-10-26", user="b@example.com", uid="43"))
        got = self.claim("proof-need-ask", ["s1"], "2026-10-28", user="b@example.com", uid="43")
        self.assertEqual((got["result"], got.get("reason")), ("recent", "messaged_7d"))


if __name__ == "__main__":
    unittest.main()
