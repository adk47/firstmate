#!/usr/bin/env python3
"""policies/fraud-watchlist.json + credit_review/watchlist.py (firstmate 154). Stdlib only."""
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from credit_review import decide, watchlist  # noqa: E402
import uvn_under30_policy as up  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
P1 = "11111111-1111-4111-8111-111111111111"


def ledger():
    import sqlite3
    path = Path(tempfile.mkdtemp()) / "ledger.sqlite3"
    db = sqlite3.connect(path)
    decide.ensure_schema(db)
    db.close()
    return path


def entry(**kw):
    e = {"tier": "fraud", "user_ids": [9001], "profile_ids": [P1], "reason": "test", "evidence": "x",
         "added_at": "2026-10-23", "added_by": "test"}
    e.update(kw)
    return e


class Shipped(unittest.TestCase):
    def test_the_repo_watchlist_loads_and_every_path_holds_it(self):
        wl = watchlist.load()
        self.assertTrue(wl.fraud_user_ids, "the seed has fraud-tier actors")
        self.assertTrue(wl.fraud_user_ids <= wl.user_ids and wl.fraud_profile_ids <= wl.profile_ids)
        pol = decide.Policy.load()
        self.assertTrue(wl.user_ids <= pol.deny_user_ids and wl.profile_ids <= pol.deny_profile_ids)
        dl = up.load_deny_list(ROOT / "policies/credit-trust-decide.json", ledger())
        self.assertTrue(wl.user_ids <= set(dl.user_ids) and wl.profile_ids <= set(dl.profile_ids))

    def test_no_clear_text_names_or_emails(self):
        doc = json.loads((ROOT / "policies/fraud-watchlist.json").read_text())
        allowed = {"tier", "user_ids", "profile_ids", "reason", "evidence", "added_at", "added_by",
                   "name_sha256", "email_sha256", "email_domains"}
        for e in doc["entries"]:
            self.assertLessEqual(set(e), allowed)
            self.assertNotIn("@", json.dumps({k: v for k, v in e.items() if k != "email_domains"}))


class Loader(unittest.TestCase):
    def write(self, doc):
        d = tempfile.mkdtemp()
        p = Path(d) / "fraud-watchlist.json"
        p.write_text(json.dumps(doc))
        return p

    def test_tiers_and_hash_matching(self):
        p = self.write({"entries": [entry(name_sha256=[watchlist.sha("bigboy")],
                                          email_sha256=[watchlist.sha("a@b.com")], email_domains=["evil.example"]),
                                    entry(tier="review", user_ids=[9002], profile_ids=[])]})
        wl = watchlist.load(p)
        self.assertEqual((wl.user_ids, wl.fraud_user_ids), ({9001, 9002}, {9001}))
        self.assertTrue(wl.name_hit("Big Boy!") and wl.name_hit("BIG-BOY"))
        self.assertTrue(wl.email_hit(" A@B.com ") and wl.email_hit("x@evil.example"))
        self.assertFalse(wl.email_hit("x@gmail.com") or wl.name_hit(""))

    def test_malformed_is_fatal_never_empty(self):
        for bad in ({}, {"entries": [entry(tier="maybe")]}, {"entries": [entry(user_ids=["9001"])]},
                    {"entries": [entry(profile_ids=["not-a-uuid"])]}, {"entries": [entry(reason="")]},
                    {"entries": [entry(user_ids=[], profile_ids=[])]}, {"entries": [entry(name_sha256=["Big Boy"])]}):
            with self.assertRaises(ValueError, msg=bad):
                watchlist.load(self.write(bad))

    def test_shared_mail_domains_are_refused(self):
        for dom in ("privaterelay.appleid.com", "outlook.it", "gmail.com", "hotmail.co.uk", "yahoo.com.br"):
            with self.assertRaises(ValueError, msg=dom):
                watchlist.load(self.write({"entries": [entry(email_domains=[dom])]}))
        wl = watchlist.load(self.write({"entries": [entry(email_domains=["fraudlabel.example"])]}))
        self.assertTrue(wl.email_hit("a@fraudlabel.example"))

    def test_an_explicit_load_of_the_deployed_policy_needs_the_watchlist(self):
        import shutil
        d = Path(tempfile.mkdtemp())
        shutil.copy(ROOT / "policies/credit-trust-decide.json", d / "credit-trust-decide.json")
        from unittest import mock
        with mock.patch.object(watchlist, "DEFAULT", d / "fraud-watchlist.json"):
            with self.assertRaises(ValueError):
                decide.Policy.load(d / "credit-trust-decide.json")       # explicit, deployed dir, missing
            with self.assertRaises(ValueError):
                decide.Policy.load(Path(os.path.relpath(d / "credit-trust-decide.json")))  # relative path

    def test_missing_is_fatal_only_where_required(self):
        missing = Path(tempfile.mkdtemp()) / "fraud-watchlist.json"
        self.assertEqual(watchlist.load(missing), watchlist.Watchlist())
        with self.assertRaises(ValueError):
            watchlist.load(missing, required=True)

    def test_a_test_policy_dir_unions_its_own_watchlist(self):
        p = self.write({"entries": [entry()]})
        pol_path = p.with_name("credit-trust-decide.json")
        pol_path.write_text(json.dumps({"deny_user_ids": [1], "deny_profile_ids": [], "editorial_role_terms": ["edit"]}))
        pol = decide.Policy.load(pol_path)
        self.assertEqual((pol.deny_user_ids, pol.deny_profile_ids), ({1, 9001}, {P1}))
        dl = up.load_deny_list(pol_path, ledger())
        self.assertIn(9001, dl.user_ids)
        p.write_text("{not json")
        with self.assertRaises(ValueError):
            decide.Policy.load(pol_path)
        with self.assertRaises(up.PolicyError):
            up.load_deny_list(pol_path, ledger())


if __name__ == "__main__":
    unittest.main()
