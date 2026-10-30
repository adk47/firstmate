"""Tests for scripts/intercom-backlog/which_account.py: the "which account?" ask (fable-copy-1030-r5/b) to an
unmatched proof document's sender. Pure functions + an in-memory verify ledger; no Intercom, Trino or
ops-write call. Stdlib unittest; safe to run as root on node-8."""
import importlib.util
import os
import re
import sys
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "scripts"))
sys.path.insert(0, os.path.join(ROOT, "scripts", "intercom-backlog"))
spec = importlib.util.spec_from_file_location(
    "ib_which", os.path.join(ROOT, "scripts", "intercom-backlog", "which_account.py"))
wa = importlib.util.module_from_spec(spec)
spec.loader.exec_module(wa)
vl = wa.verify_ledger

SHA1, SHA2 = "a" * 64, "b" * 64
TRAY = {"source": "intercom", "files": f"['{SHA1}', '{SHA2}']", "received_at": "['2026-10-30T13:23:12Z']"}
GOT = 1793366592  # 2026-10-30T13:23:12Z
CONV = {"statistics": {"last_admin_reply_at": GOT - 3600}}
ONE = [{"id": "c1", "email": "Ann@X.io", "name": "Ann Lee", "role": "lead"}]
NOACCT = {"decision": "no-proposal", "reason": "no Muso account has this email"}


class Copy(unittest.TestCase):
    def test_copy_is_byte_for_byte_the_approved_string(self):
        self.assertEqual(wa.COPY_REF, "fable-copy-1030-r5/b")
        self.assertEqual(wa.COPY, "Hi {first}, thanks for the document you sent. We couldn't match it to a Muso "
                         "account yet. Reply here with the email address on your Muso account, or the link to "
                         "your Muso profile, and we'll attach it to the right request.")

    def test_render_first_name_fallback_and_no_hint(self):
        self.assertTrue(wa.render(ONE[0]).startswith("Hi Ann, thanks"))
        self.assertTrue(wa.render({"name": "123 x"}).startswith("Hi there,"))
        self.assertTrue(wa.render({}).startswith("Hi there,"))
        body = wa.render(ONE[0]).lower()
        for banned in ("id ", "passport", "another account", "reason", "by "):
            self.assertNotIn(banned, body)

    def test_copy_passes_the_write_wrappers_sanitizer(self):
        with open(os.path.join(ROOT, "scripts", "intercom-ops-write.sh")) as f:
            wrapper = f.read()
        words = re.search(r'readonly SANITIZER_WORDS="([^"]+)"', wrapper).group(1)
        leak = re.compile(r"(^|[^A-Za-z0-9_])(" + words + r")([^A-Za-z0-9_]|$)", re.I)
        self.assertIsNone(leak.search(wa.render(ONE[0])))


class Eligible(unittest.TestCase):
    def test_the_unmatched_single_sender_is_asked(self):
        self.assertEqual(wa.eligible(TRAY, CONV, ONE, NOACCT), "")
        self.assertEqual(wa.eligible(TRAY, CONV, ONE, {"decision": "no-proposal",
                                                      "reason": "no contact on the thread has an email"}), "")

    def test_every_other_case_is_skipped(self):
        cases = {
            "not an Intercom document": (dict(TRAY, source="gmail"), CONV, ONE, NOACCT),
            "unreadable": (TRAY, None, ONE, NOACCT),
            "2 contacts": (TRAY, CONV, ONE + [{"id": "c2"}], NOACCT),
            "resolvable": (TRAY, CONV, ONE, {"decision": "propose"}),
            "young contact": (TRAY, CONV, ONE, {"decision": "wait", "reason": "younger"}),
            "ambiguous": (TRAY, CONV, ONE, {"decision": "no-proposal", "reason": "2 Muso accounts have this email"}),
            "names another account": (TRAY, CONV, ONE, {"decision": "no-proposal",
                                                        "reason": "a contact's external_id names another Muso account (9)"}),
            "no hash": (dict(TRAY, files="['not-a-hash']"), CONV, ONE, NOACCT),
            "no time": (dict(TRAY, received_at=""), CONV, ONE, NOACCT),
            "already replied": (TRAY, {"statistics": {"last_admin_reply_at": GOT + 60}}, ONE, NOACCT),
        }
        for name, args in cases.items():
            with self.subTest(case=name):
                self.assertNotEqual(wa.eligible(*args), "")


class Ledger(unittest.TestCase):
    def setUp(self):
        self.db = vl.connect(":memory:")

    def claim(self, keys, day="2026-10-30", key="ann@x.io"):
        return vl.claim(self.db, user_key=key, day=day, request_ids=keys, message_type="comment",
                        approved_by=wa.APPROVER, approval_ref=wa.COPY_REF, campaign=wa.CAMPAIGN)

    def test_registered_notice_campaign(self):
        self.assertIn(vl.WHICH_ACCOUNT, vl.CAMPAIGNS)
        self.assertIn(vl.WHICH_ACCOUNT, vl.NOTICE_CAMPAIGNS)

    def test_one_message_for_several_documents_and_once_per_document_ever(self):
        keys = wa.doc_keys(TRAY)
        self.assertEqual(keys, [f"doc-{SHA1}", f"doc-{SHA2}"])
        c = self.claim(keys)
        self.assertEqual((c["result"], c["request_ids"]), ("claimed", keys))
        vl.finalize(self.db, message_row=c["message_row"], status="sent")
        self.assertEqual(self.claim(keys, day="2026-11-09")["result"], "already_notified")
        # a new document in the same thread later gets asked about, alone
        c2 = self.claim(keys + ["doc-" + "c" * 64], day="2026-11-09")
        self.assertEqual(c2["request_ids"], ["doc-" + "c" * 64])

    def test_daily_cap_across_campaigns(self):
        o = vl.claim(self.db, user_key="ann@x.io", day="2026-10-30", request_ids=["r1"], message_type="email",
                     approved_by="U7RP6HKUZ", approval_ref="t", campaign="status-team-review")
        vl.finalize(self.db, message_row=o["message_row"], status="sent")
        self.assertEqual(self.claim(wa.doc_keys(TRAY))["result"], "daily_cap")

    def test_user_key_without_email(self):
        self.assertEqual(wa.user_key({"id": "c9", "email": ""}), "intercom-contact:c9")
        self.assertEqual(wa.user_key(ONE[0]), "ann@x.io")


if __name__ == "__main__":
    unittest.main()
