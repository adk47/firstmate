"""scripts/paid-status/b0_gap.py: a uvn ask the gate REFUSED or Intercom REJECTED was never delivered, so it is NOT
"ask handled": that user owes the ask and gets no "nothing else is needed" note (firstmate 025/026, 2026-10-27:
37 users who still owed proof got B0 because terminal identity refusals close the request rows)."""
import importlib.util
import os
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, ".."))
from credit_review import verify_ledger  # noqa: E402

spec = importlib.util.spec_from_file_location("b0_gap", os.path.join(HERE, "..", "paid-status", "b0_gap.py"))
b0_gap = importlib.util.module_from_spec(spec)
spec.loader.exec_module(b0_gap)


class DecideTest(unittest.TestCase):
    def d(self, **kw):
        base = dict(messaged=False, never_delivered=False, ask_only=False, documented=False, pending_doc=False)
        base.update(kw)
        return b0_gap.decide(**base)[0]

    def test_an_ask_skipped_user_gets_b0(self):
        self.assertEqual(self.d(), "B2")

    def test_a_never_delivered_ask_gets_nothing(self):
        self.assertEqual(self.d(never_delivered=True), "")
        self.assertEqual(self.d(never_delivered=True, documented=True), "")  # refusal wins over the B0 rule

    def test_messaged_before_gets_nothing(self):
        self.assertEqual(self.d(messaged=True), "")

    def test_ask_only_rules(self):
        self.assertEqual(self.d(ask_only=True), "")
        self.assertEqual(self.d(ask_only=True, documented=True), "B2")
        self.assertEqual(self.d(ask_only=True, documented=True, pending_doc=True), "A3")


class LedgerTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.db = verify_ledger.connect(os.path.join(self.tmp, "ledger.sqlite3"))

    def add(self, campaign, status, account="7", key="a@example.com"):
        self.db.execute(
            "INSERT INTO verify_messages (campaign, kind, user_key, account_id, day, status, message_type, request_ids_json, "
            "n_credits, approved_by, approval_ref, created_at, updated_at) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)",
            (campaign, "initial", key, account, "2026-10-26", status, "email", "[\"r1\"]", 1, "x", "x",
             "2026-10-26T15:00:00Z", "2026-10-26T15:00:00Z"))

    def test_refused_and_rejected_uvn_asks_are_never_delivered(self):
        for st in ("refused", "rejected"):
            with self.subTest(status=st):
                self.db.execute("DELETE FROM verify_messages")
                self.add("uvn-status", st)
                self.assertTrue(b0_gap.ask_never_delivered(self.db, "a@example.com", 7))
                self.assertFalse(b0_gap.ever_messaged(self.db, "a@example.com", 7))

    def test_matched_by_account_id_across_an_email_change(self):
        self.add("uvn-status", "refused", key="old@example.com")
        self.assertTrue(b0_gap.ask_never_delivered(self.db, "new@example.com", 7))

    def test_a_sent_ask_is_messaged_not_never_delivered(self):
        self.add("uvn-status", "sent")
        self.assertFalse(b0_gap.ask_never_delivered(self.db, "a@example.com", 7))
        self.assertTrue(b0_gap.ever_messaged(self.db, "a@example.com", 7))

    def test_another_campaign_refusal_does_not_count(self):
        self.add("status-team-review", "refused")
        self.assertFalse(b0_gap.ask_never_delivered(self.db, "a@example.com", 7))


if __name__ == "__main__":
    unittest.main()
