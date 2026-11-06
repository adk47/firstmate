"""Tests for scripts/intercom-backlog/tail_lists.py (WS2 e4): the > 30 d tail becomes input lists
for the existing approved campaign senders. Pure functions only: no Trino, no Intercom, no ledger.
The C (uvn-status) list must never be offerable before lift L11 (Fable R4), proven against the
real driver loader. Stdlib unittest; safe to run as root on node-8."""
import datetime as dt
import importlib.util
import json
import os
import sys
import tempfile
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DIR = os.path.join(ROOT, "scripts", "intercom-backlog")


def load(name, file):
    spec = importlib.util.spec_from_file_location(name, os.path.join(DIR, file))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


tail = load("ib_tail", "tail_lists.py")
census = load("ib_census", "census.py")
sys.path.insert(0, os.path.join(ROOT, "scripts"))
from credit_review import uvn_status, verify_notify  # noqa: E402

TAG = tail.TAIL_TAG


def row(cid, uid, topic="credit", action="draft-credit", band="gt30d", paid=False, waiting=100, tags=(TAG,)):
    return {"id": cid, "user_id": uid, "topic": topic, "action": action, "band": band, "paid": paid,
            "waiting_since": waiting, "tags": list(tags)}


def proof(entries):
    return verify_notify.ProofOnFile(entries)


class Classify(unittest.TestCase):
    def test_a_vs_b_by_document_on_file(self):
        rows = [row("1", "10", waiting=1), row("2", "20", waiting=2), row("3", "30", waiting=3)]
        pending = {"10": [("r1", "unverified"), ("r2", "processing")], "20": [("r3", "unverified")],
                   "30": [("r4", "processing")]}
        docs = proof({"10": [("r2", "pending_doc")], "30": [(None, "pending_doc")]})
        out = tail.classify(rows, pending, {}, docs)
        self.assertEqual([(e["user_id"], e["request_ids"]) for e in out["A"]], [(10, ["r2"]), (30, ["r4"])])
        self.assertEqual([(e["user_id"], e["request_ids"]) for e in out["B"]], [(20, ["r3"])])

    def test_unreadable_proof_writes_no_a_or_b(self):
        out = tail.classify([row("1", "10")], {"10": [("r1", "unverified")]}, {}, None)
        self.assertNotIn("A", out)
        self.assertNotIn("B", out)
        self.assertEqual(len(out["AB-unreadable"]), 1)

    def test_uvn_only_is_held_by_r4(self):
        out = tail.classify([row("1", "10")], {"10": [("r1", "user_verification_needed")]}, {}, proof({}))
        self.assertEqual(out["C"][0]["skip"], tail.R4_SKIP)

    def test_claim_merge_noaccount_and_none(self):
        rows = [row("1", "10", topic="claim", action="claim-pending"), row("2", "20", topic="merge", action="draft-merge"),
                row("3", None, action="no-identity"), row("4", "40")]
        out = tail.classify(rows, {}, {"10": ["c9"]}, proof({}))
        self.assertEqual(out["D"][0]["claim_ids"], ["c9"])
        self.assertEqual(out["M"][0]["conversation_id"], "2")
        self.assertEqual(out["X"][0]["conversation_id"], "3")
        self.assertEqual(out["none"][0]["conversation_id"], "4")

    def test_scope_band_tag_and_overrides(self):
        rows = [row("1", "10", band="1-30d"), row("2", "20", tags=()), row("3", "30", action="captain-billing"),
                row("4", "40", action="hold-read"), row("5", "50", topic="removal", action="draft-removal"),
                row("6", "60")]
        pending = {u: [("r" + u, "unverified")] for u in ("10", "20", "30", "40", "50", "60")}
        out = tail.classify(rows, pending, {}, proof({}))
        self.assertEqual([e["conversation_id"] for e in out["B"]], ["6"])
        self.assertEqual([e["conversation_id"] for e in out["out-of-scope"]], ["5"])
        everywhere = {e["conversation_id"] for v in out.values() for e in v}
        self.assertFalse({"1", "2", "3", "4"} & everywhere)
        # --tag '' widens to every > 30 d row, still never the captain's or hold-read
        wide = tail.classify(rows, pending, {}, proof({}), tag="")
        self.assertEqual(sorted(e["conversation_id"] for e in wide["B"]), ["2", "6"])

    def test_one_user_one_class_oldest_conversation_first(self):
        rows = [row("new", "10", waiting=50), row("old", "10", waiting=5), row("x", "20", waiting=1)]
        pending = {"10": [("r1", "unverified")], "20": [("r2", "unverified")]}
        out = tail.classify(rows, pending, {"10": ["c1"]}, proof({}))
        self.assertEqual([e["conversation_id"] for e in out["B"]], ["x", "old"])
        self.assertEqual([e["conversation_id"] for e in out["dup"]], ["new"])
        self.assertNotIn("D", out)  # credit status wins over the claim note for the same user


class DriverShape(unittest.TestCase):
    def write(self, doc):
        d = tempfile.mkdtemp()
        p = os.path.join(d, "l.json")
        with open(p, "w") as f:
            json.dump(doc, f)
        return p

    def test_lists_load_in_the_real_driver_and_c_is_never_offered(self):
        out = tail.classify([row("1", "10", paid=True), row("2", "20", paid=True)],
                            {"10": [("r1", "unverified")], "20": [("r2", "user_verification_needed")]},
                            {}, proof({}))
        users_b, err = uvn_status.load_list(self.write(tail.driver_list(out["B"], "status-team-review")))
        self.assertEqual(err, "")
        self.assertEqual([(u["user_id"], u["request_ids"], u["skip"]) for u in users_b], [(10, ["r1"], None)])
        users_c, err = uvn_status.load_list(self.write(tail.driver_list(out["C"], "uvn-status")))
        self.assertEqual(err, "")
        # uvn_status.run offers only skip == None rows of the segment (uvn_status.py `offered`)
        self.assertEqual([u for u in users_c if u.get("skip") is None], [])

    def test_stale_list_is_refused_by_the_driver(self):
        old = dt.datetime.now(dt.timezone.utc) - dt.timedelta(hours=uvn_status.LIST_MAX_AGE_H + 1)
        doc = tail.driver_list([], "status-team-review", now=old)
        users, err = uvn_status.load_list(self.write(doc))
        self.assertEqual(users, [])
        self.assertIn("old", err)


class CensusNeutralTags(unittest.TestCase):
    def test_priority_demoted_is_neutral(self):
        self.assertIn("priority-demoted", census.NEUTRAL_TAGS)
        self.assertEqual(census.topic_of("hello there"), "other")


if __name__ == "__main__":
    unittest.main()
