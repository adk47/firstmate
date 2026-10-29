"""verify_ledger rules for Fable's two owing-proof lines (copy-owing-proof-1027; send-locked until L14):
credit-hold-status (S1) is a once-per-user status campaign and a notice, NOT an ask, and NOT stopped by the
hold-silent flags that stop the "nothing else is needed" notes (Fable: S1 goes to held accounts too);
claim-proof-pending (S2) follows claim-status's claim rules. Also pins the IN-list fix: the claim tuple grew
to three, and the hard-coded "NOT IN (?,?)" broke every uvn-status claim."""
from __future__ import annotations

import credit_test_env  # noqa: F401 - first: test logs never reach the production run.log
import sys
import tempfile
import unittest
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
from credit_review import verify_ledger as vl  # noqa: E402

KW = dict(message_type="email", approved_by="U7RP6HKUZ", approval_ref="ref")
NOW = datetime(2026, 10, 28, 1, 0, tzinfo=timezone.utc)


class OwingProofTest(unittest.TestCase):
    def setUp(self):
        self.db = vl.connect(str(Path(tempfile.mkdtemp()) / "ledger.sqlite3"))

    def claim(self, campaign, ids, day="2026-10-28", user="jane@example.com", uid="42"):
        return vl.claim(self.db, user_key=user, day=day, request_ids=list(ids), campaign=campaign, user_id=uid,
                        now=datetime.fromisoformat(day + "T01:00:00+00:00"), **KW)

    def sent(self, c):
        vl.finalize(self.db, message_row=c["message_row"], status="sent", message_id="m1")

    def test_registered(self):
        for c in ("credit-hold-status", "claim-proof-pending"):
            self.assertIn(c, vl.CAMPAIGNS)
        self.assertIn("credit-hold-status", vl.STATUS_CAMPAIGNS)
        self.assertNotIn("credit-hold-status", vl.ASK_CAMPAIGNS)
        self.assertNotIn("credit-hold-status", vl.STATUS_NOTE_CAMPAIGNS)
        self.assertIn("claim-proof-pending", vl.CLAIM_CAMPAIGNS)
        self.assertNotIn("claim-proof-pending", vl.ASK_CAMPAIGNS)

    def test_s1_once_per_user_ever_and_never_an_ask(self):
        c = self.claim("credit-hold-status", ["r1"])
        self.assertEqual(c["result"], "claimed")
        self.sent(c)
        self.assertFalse(vl.asked_within(self.db, user_key="jane@example.com", day="2026-10-29", user_id="42"))
        later = self.claim("credit-hold-status", ["r2"], day="2026-12-30")
        self.assertEqual((later["result"], later.get("reason")), ("user_done", "already_sent"))
        # within 7 days of S1, a status note defers (messaged_7d), nothing closed
        tr = self.claim("status-team-review", ["r3"], day="2026-10-30")
        self.assertEqual((tr["result"], tr.get("reason")), ("recent", "messaged_7d"))

    def test_s1_is_not_blocked_by_an_ask_on_the_same_credit(self):
        self.sent(self.claim("uvn-status", ["r1"], day="2026-09-01"))
        self.assertEqual(vl.blocked_ids(self.db, ["r1"], "credit-hold-status"), set())

    def test_hold_silent_does_not_stop_s1(self):
        vl.hold_silent(self.db, user_ids=["42"], reason="account-hold")
        self.assertTrue(vl.refusal_hold(self.db, "status-team-review", "jane@example.com", user_id="42"))
        self.assertEqual(vl.refusal_hold(self.db, "credit-hold-status", "jane@example.com", user_id="42"), {})
        self.assertEqual(self.claim("credit-hold-status", ["r1"])["result"], "claimed")

    def test_s2_follows_the_claim_status_rules(self):
        c = self.claim("claim-proof-pending", ["claim-1"], day="2026-10-28")
        self.assertEqual(c["result"], "claimed")
        self.sent(c)
        ask = self.claim("claim-proof-ask", ["claim-2"], day="2026-11-02")
        self.assertEqual((ask["result"], ask.get("reason")), ("recent", "messaged_7d"))
        self.assertEqual(self.claim("claim-proof-pending", ["claim-1"], day="2026-12-30")["result"], "already_notified")
        # a claim with a proof ask never gets S2 (closed)
        self.sent(self.claim("claim-proof-ask", ["claim-3"], day="2026-11-20"))
        s2 = self.claim("claim-proof-pending", ["claim-3"], day="2026-12-30")
        self.assertEqual((s2["result"], s2.get("reason")), ("user_done", "proof_ask_sent"))

    def test_claim_status_never_follows_s2_on_the_same_claim(self):
        # QA on #1409: S2 then claim-status 9 days later must not say "nothing else is needed"
        self.sent(self.claim("claim-proof-pending", ["claim-7"], day="2026-10-28"))
        st = self.claim("claim-status", ["claim-7"], day="2026-11-06")
        self.assertEqual((st["result"], st.get("reason")), ("user_done", "proof_pending_sent"))
        # another claim of the same user is unaffected (after the 7 days)
        self.assertEqual(self.claim("claim-status", ["claim-8"], day="2026-11-06")["result"], "claimed")
        # the other order stays allowed: S2 after claim-status corrects the earlier note
        self.sent(self.claim("claim-status", ["claim-9"], day="2026-09-01", user="b@example.com", uid="43"))
        self.assertEqual(self.claim("claim-proof-pending", ["claim-9"], day="2026-10-01", user="b@example.com",
                                    uid="43")["result"], "claimed")

    def test_the_in_list_covers_every_claim_campaign(self):
        # regression: a proof-tagged claim-proof-pending reply is claim proof, never credit proof, so a
        # uvn-status note still goes (the old "NOT IN (?,?)" raised once the tuple held three campaigns)
        c = self.claim("claim-proof-pending", ["claim-1"], day="2026-10-01")
        self.sent(c)
        self.db.execute("UPDATE verify_messages SET proof_tagged_at='2026-10-02T00:00:00Z' WHERE id=?", (c["message_row"],))
        self.db.commit()
        self.assertEqual(vl.uvn_user_done(self.db, "jane@example.com", now=NOW, user_id="42"), "")
        self.assertEqual(vl.past_user_done(self.db, "jane@example.com", "42"), "")


if __name__ == "__main__":
    unittest.main()
