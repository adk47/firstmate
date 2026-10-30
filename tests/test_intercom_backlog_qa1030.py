"""QA NO-GO on hydra#1379 @5d8fb2ed (2026-10-30 17:17Z): one test class per review thread. Pure functions
and fakes only (no Intercom, Trino, ops-write or production ledger). Stdlib unittest; safe as root on node-8."""
import importlib.util
import json
import os
import shutil
import sys
import tempfile
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DIR = os.path.join(ROOT, "scripts", "intercom-backlog")
sys.path.insert(0, os.path.join(ROOT, "scripts"))
sys.path.insert(0, DIR)


def load(name, file):
    spec = importlib.util.spec_from_file_location(name, os.path.join(DIR, file))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


census = load("q_census", "census.py")
topics = load("q_topics", "topics.py")
count = load("q_count", "count.py")
overrides = load("q_overrides", "overrides.py")
send = load("q_send", "send.py")
tail = load("q_tail", "tail_lists.py")
ip = load("q_ip", "intake_proposals.py")
wa = load("q_wa", "which_account.py")


def tmpdir(tc):
    d = tempfile.mkdtemp()
    tc.addCleanup(shutil.rmtree, d)
    return d


class LatestMessageTopic(unittest.TestCase):
    """census.py: classify on the LATEST customer message, billing veto first."""

    def t(self, opening, latest):
        return topics.latest_topic(opening, latest, census.topic_of)

    def test_refund_after_a_credit_thread_is_billing(self):
        self.assertEqual(self.t("credit", "I want a refund for my subscription"), "billing")
        self.assertEqual(self.t("credit", "why was I charged twice?"), "billing")

    def test_legal_after_anything_is_legal(self):
        self.assertEqual(self.t("credit", "my attorney will contact you"), "legal")

    def test_credit_card_is_not_a_credit_word_but_is_billing(self):
        self.assertEqual(self.t("other", "my credit card was declined"), "billing")

    def test_uninformative_latest_keeps_the_opening_topic_and_unread_is_held(self):
        self.assertEqual(self.t("credit", "hello?"), "credit")
        self.assertEqual(self.t("credit", None), "unread")
        self.assertFalse(send.eligible({"action": "draft-unread"}))

    def test_followup_detection(self):
        self.assertTrue(census.has_followup({"lcr": 2000, "created_at": 1000}))
        self.assertFalse(census.has_followup({"lcr": 0, "created_at": 1000}))
        self.assertFalse(census.has_followup({"lcr": 1030, "created_at": 1000}))

    def test_shared_billing_pattern(self):
        try:
            from credit_review import comm_state
        except ImportError:
            comm_state = None
        shared = getattr(comm_state, "TOPIC_BILLING_RE", None)
        if shared is not None:
            self.assertEqual(shared.pattern, topics.BILLING_PATTERN)
            self.assertIs(topics.TOPIC_BILLING_RE, shared)
        else:
            self.assertEqual(topics.TOPIC_BILLING_RE.pattern, topics.BILLING_PATTERN)

    def test_count_applies_the_veto(self):
        self.assertEqual(count.classify("credit", "refund please", "credit-like"), "billing-money")
        self.assertEqual(count.classify("credit", "where is my credit request?", "credit-like"), "credit-claim-merge")
        self.assertEqual(count.classify("credit", None, None), "unread")
        self.assertEqual(count.classify("other", "my attorney", "other"), "legal")


class OverridesBothMaps(unittest.TestCase):
    def test_missing_add_or_remove_is_refused(self):
        for doc in ({"remove": {"215476553442968": "x"}}, {"add": {"215476553442968": "privacy"}}, {}):
            p = os.path.join(tmpdir(self), "ov.json")
            with open(p, "w") as f:
                json.dump(doc, f)
            with self.subTest(doc=doc), self.assertRaises(overrides.OverridesError):
                overrides.load(p)

    def test_empty_maps_are_fine(self):
        p = os.path.join(tmpdir(self), "ov.json")
        with open(p, "w") as f:
            json.dump({"add": {}, "remove": {}}, f)
        self.assertEqual(overrides.load(p), {"add": {}, "remove": {}})


class LiveStateBeforeSend(unittest.TestCase):
    """send.py: the 'nothing pending' lines are re-checked against live core state."""

    def q(self, credits, claims):
        def query(sql):
            return [[str(credits if "credit_requests" in sql else claims)]]
        return query

    def test_new_pending_credit_or_claim_refuses(self):
        self.assertIn("state changed", send.live_state_ok({"user_id": "7"}, self.q(1, 0)))
        self.assertIn("state changed", send.live_state_ok({"user_id": "7"}, self.q(0, 2)))

    def test_nothing_pending_or_no_account_passes(self):
        self.assertEqual(send.live_state_ok({"user_id": "7"}, self.q(0, 0)), "")
        self.assertEqual(send.live_state_ok({"user_id": None}, self.q(5, 5)), "")

    def test_unreadable_core_refuses(self):
        def boom(sql):
            raise RuntimeError("trino down")
        self.assertEqual(send.live_state_ok({"user_id": "7"}, boom), "core state unreadable")


class StaleTailLists(unittest.TestCase):
    def entry(self, uid):
        return {"user_id": uid, "paid": False, "skip": None, "request_ids": ["r1"], "conversation_id": "c"}

    def test_a_second_run_without_ab_removes_the_old_lists(self):
        d = tmpdir(self)
        first = tail.publish(d, {"A": [self.entry(1)], "B": [self.entry(2)], "D": [{"claim_ids": ["9"]}]})
        self.assertEqual(sorted(first), ["A", "B", "D"])
        tail.publish(d, {"AB-unreadable": [self.entry(1)]})
        self.assertEqual(sorted(os.listdir(d)), [])

    def test_unrelated_files_are_left_alone(self):
        d = tmpdir(self)
        open(os.path.join(d, "keep.txt"), "w").close()
        tail.publish(d, {"B": [self.entry(2)]})
        self.assertEqual(sorted(os.listdir(d)), ["keep.txt", "tail-status-team-review.json"])


class MixedContactConflict(unittest.TestCase):
    """intake_proposals.py: a no-email contact's external_id still blocks the proposal."""

    def test_second_contact_without_email_naming_another_account_blocks(self):
        now = 2_000_000_000.0
        a = ip.rec.Account(user_id=7, email="x@y.io", email_confirmed=True)
        contacts = [{"email": "x@y.io", "role": "user", "external_id": "", "created_at": now - 9 * 86400},
                    {"email": "", "role": "user", "external_id": "ext-b", "created_at": now - 9 * 86400}]
        common = dict(accounts_by_email={"x@y.io": [7]}, facts={7: a}, now=now)
        r = ip.propose_one("c", {}, contacts, ext_owner={"ext-b": {"9"}}, **common)
        self.assertEqual(r["decision"], "no-proposal")
        self.assertIn("names another Muso account", r["reason"])
        r = ip.propose_one("c", {}, contacts, ext_owner={}, reverted={"ext-b": {"9"}}, **common)
        self.assertEqual(r["decision"], "no-proposal")
        self.assertIn("reverted claim", r["reason"])


class BucketAllowlist(unittest.TestCase):
    def test_ambiguous_identity_and_other_non_allowlisted_actions_are_refused(self):
        for act in ("ambiguous-identity", "unknown-action", "draft-unread", "captain-billing", "hold-read"):
            with self.subTest(action=act):
                self.assertFalse(send.bucket_eligible({"bucket": "stats", "action": act}))
                rows = [{"id": "1", "bucket": "stats", "action": act, "band": "gt30d", "paid": False,
                         "waiting_since": 1}]
                self.assertEqual(send.select_rows(rows, "bucket", {}, {"add": {}, "remove": {}}, bucket="stats"), [])
        self.assertTrue(send.bucket_eligible({"bucket": "stats", "action": "draft-other"}))
        self.assertTrue(send.bucket_eligible({"bucket": "stats", "action": "no-identity"}))


class SecondMessageSinceSnapshot(unittest.TestCase):
    def conv(self, lar, lcr, state="open"):
        return {"state": state, "statistics": {"last_admin_reply_at": lar, "last_contact_reply_at": lcr}}

    def test_a_new_customer_message_refuses(self):
        ok, why = send.still_owed(self.conv(100, 500), snapshot_waiting_since=300)
        self.assertFalse(ok)
        self.assertIn("wrote again", why)
        # an unanswered first message (snapshot = created_at) that later got a customer reply
        self.assertFalse(send.still_owed(self.conv(0, 900), snapshot_waiting_since=800)[0])

    def test_unchanged_thread_passes(self):
        self.assertEqual(send.still_owed(self.conv(100, 500), snapshot_waiting_since=500), (True, ""))
        self.assertEqual(send.still_owed(self.conv(0, 0), snapshot_waiting_since=800), (True, ""))


class WhichAccountFinalCheck(unittest.TestCase):
    """which_account.py: re-read the thread and account facts right before posting."""
    SHA = "a" * 64
    TRAY = {"source": "intercom", "files": f"['{SHA}']", "received_at": "['2026-10-30T13:23:12Z']"}
    GOT = 1793366592

    def get_factory(self, lar, email="ann@x.io", ext=""):
        conv = {"contacts": {"contacts": [{"id": "c1"}]}, "statistics": {"last_admin_reply_at": lar}}
        contact = {"id": "c1", "email": email, "external_id": ext, "role": "lead", "created_at": self.GOT - 9 * 86400}
        return lambda path: conv if path.startswith("/conversations/") else contact

    def query(self, linked=False):
        def q(sql):
            if "lower(trim(email))" in sql and "SELECT CAST(id" in sql:
                return [["7", "ann@x.io"]] if linked else []
            return []
        return q

    def test_unchanged_unmatched_sender_passes(self):
        why, _c, cs = wa.fresh_assess("1", self.TRAY, self.get_factory(self.GOT - 3600), self.query(False),
                                      now=self.GOT + 86400)
        self.assertEqual(why, "")
        self.assertEqual(len(cs), 1)

    def test_a_reply_during_the_run_refuses(self):
        why, _c, _cs = wa.fresh_assess("1", self.TRAY, self.get_factory(self.GOT + 60), self.query(False),
                                       now=self.GOT + 86400)
        self.assertIn("already replied", why)

    def test_a_link_during_the_run_refuses(self):
        why, _c, _cs = wa.fresh_assess("1", self.TRAY, self.get_factory(self.GOT - 3600), self.query(True),
                                       now=self.GOT + 86400)
        self.assertNotEqual(why, "")

    def test_unreadable_core_refuses(self):
        def boom(sql):
            raise RuntimeError("trino down")
        why, _c, _cs = wa.fresh_assess("1", self.TRAY, self.get_factory(self.GOT - 3600), boom, now=self.GOT + 86400)
        self.assertIn("unreadable", why)


if __name__ == "__main__":
    unittest.main()
