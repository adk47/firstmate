"""The paid-band ask lane (captain r4 GO 3, firstmate 413): the cap, the cohort predicate, and the re-signed list.

Pins the three things that keep this lane bounded - an unreadable policy is a REFUSAL not an uncapped wave, the
scope lists only never-told PAID users with band rows in paid-then-oldest order, and the filtered list still
passes owing_proof.verify_facts (a list that would be refused at signing is worthless)."""
from __future__ import annotations

import credit_test_env  # noqa: F401 - first: test logs never reach the production run.log
import json
import sys
import tempfile
import unittest
from unittest import mock
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
from credit_review import owing_proof, paid_band_ask, verify_ledger  # noqa: E402


def build_doc(users):
    return {"generated_at": "2026-11-11T11:00:00+00:00", "users": users,
            "counts": {}, "replica_facts": owing_proof.facts_header(users)}


def user(uid, rid, *, paid=True, oldest="2026-10-01T00:00:00Z", status="user_verification_needed", cls="uvn"):
    return {"user_id": str(uid), "paid": paid, "skip": None, "at_risk": False, "request_ids": [rid],
            "class": cls, "oldest": oldest, "facts": [[rid, status, False]]}


def replica(entries):
    """The 8-column replica shape owing_proof reads: uid, rid, status, createdat, paid, review_fired,
    proofRequest marker, proof_required."""
    return [[str(uid), rid, status, oldest, "1" if paid else "0", "0", "0", "0"]
            for uid, rid, oldest, paid, status in entries]


class AskCapTest(unittest.TestCase):
    def test_policy_cap_is_read(self):
        p = Path(tempfile.mkdtemp()) / "p.json"
        p.write_text(json.dumps({"max_ask_users_per_day": 400}))
        self.assertEqual(paid_band_ask.ask_cap(str(p)), 400)

    def test_unreadable_or_missing_cap_is_a_refusal(self):
        d = Path(tempfile.mkdtemp())
        for body in ({}, {"max_ask_users_per_day": 0}, {"max_ask_users_per_day": "400"},
                     {"max_ask_users_per_day": True}):
            p = d / "p.json"
            p.write_text(json.dumps(body))
            with self.assertRaises(paid_band_ask.BandAskError):
                paid_band_ask.ask_cap(str(p))
        with self.assertRaises(paid_band_ask.BandAskError):
            paid_band_ask.ask_cap(str(d / "nope.json"))


class CohortTest(unittest.TestCase):
    def test_band_rows_are_parsed_per_user(self):
        q = lambda sql: [["7|a"], ["7|b"], ["9|c"]]  # noqa: E731
        self.assertEqual(paid_band_ask.band_users(q), {7: {"a", "b"}, 9: {"c"}})

    def test_a_malformed_row_is_a_refusal(self):
        for rows in ([["7"]], [["x|a"]], [["7|"]], [["7|a", "extra"]]):
            with self.assertRaises(paid_band_ask.BandAskError):
                paid_band_ask.band_users(lambda sql, r=rows: r)

    def test_scope_keeps_only_never_told_paid_band_users_oldest_first(self):
        doc = build_doc([user(1, "a", oldest="2026-10-05T00:00:00Z"),
                         user(2, "b", paid=False, oldest="2026-09-01T00:00:00Z"),
                         user(3, "c", oldest="2026-09-02T00:00:00Z"),
                         user(4, "d", oldest="2026-08-01T00:00:00Z")])
        out = paid_band_ask.scope(doc, {1: {"a"}, 2: {"b"}, 3: {"c"}}, cap=400)   # 4 has no band row
        self.assertEqual([u["user_id"] for u in out["users"]], ["3", "1"])       # oldest paid first, free dropped
        self.assertEqual(out["ask_lane"]["candidates"], 2)
        self.assertEqual(out["ask_lane"]["listed"], 2)

    def test_an_already_asked_follow_up_user_spends_no_slot(self):
        # QA 1886: owing_proof also lists uvn_new_rows (already asked, new rows unnamed). uvn-status drops those as
        # already_sent before spending budget, so counting them would make the two-day drain a fiction.
        doc = build_doc([user(1, "a", oldest="2026-09-01T00:00:00Z", cls="uvn_new_rows"),
                         user(2, "b", oldest="2026-10-02T00:00:00Z")])
        out = paid_band_ask.scope(doc, {1: {"a"}, 2: {"b"}}, cap=400)
        self.assertEqual([u["user_id"] for u in out["users"]], ["2"])
        self.assertEqual(out["ask_lane"]["candidates"], 1)

    def test_users_inside_the_senders_90_day_lock_are_dropped_and_counted(self):
        doc = build_doc([user(1, "a"), user(2, "b"), user(3, "c")])
        out = paid_band_ask.scope(doc, {1: {"a"}, 2: {"b"}, 3: {"c"}}, cap=400,
                                  asked_recently=lambda uid: uid in {"1", "3"})
        self.assertEqual([u["user_id"] for u in out["users"]], ["2"])
        self.assertEqual(out["ask_lane"]["recently_asked_inside_90d"], 2)
        self.assertEqual(out["ask_lane"]["candidates"], 1)

    def test_the_build_read_is_narrowed_to_the_band_users_only(self):
        seen = []

        def q(sql):
            seen.append(sql)
            return []

        with mock.patch.object(paid_band_ask.verify_notify, "trino", q):
            paid_band_ask.narrowed_query({9, 7})("SELECT 1")
            paid_band_ask.narrowed_query({9, 7})(owing_proof.REPLICA_SQL)
            paid_band_ask.narrowed_query(set())(owing_proof.REPLICA_SQL)
        self.assertEqual(len(seen), 2)                                  # an empty cohort reads nothing at all
        self.assertTrue(seen[1].startswith(owing_proof.REPLICA_SQL))
        self.assertTrue(seen[1].endswith("AND cr.userid IN (7,9)"))     # sorted, ints only

    def test_a_big_cohort_is_read_in_batches(self):
        # 1,015 ids in one IN list blew the cluster's statement timeout (486s, killed); batches of 100 answer in ~5s
        seen = []

        def q(sql):
            seen.append(sql)
            return [["1", "a", "user_verification_needed", "2026-10-01", "1", "0", "0", "0"]]

        with mock.patch.object(paid_band_ask.verify_notify, "trino", q):
            rows = paid_band_ask.narrowed_query(range(1, 251))(owing_proof.REPLICA_SQL)
        self.assertEqual(len(seen), 3)                       # 250 users -> 3 reads, not one
        self.assertEqual(len(rows), 3)
        self.assertIn("IN (" + ",".join(str(i) for i in range(1, 101)) + ")", seen[0])

    def test_cap_defers_the_rest_to_a_later_day(self):
        users = [user(i, f"r{i}", oldest=f"2026-10-{i:02d}T00:00:00Z") for i in range(1, 11)]
        out = paid_band_ask.scope(build_doc(users), {i: {f"r{i}"} for i in range(1, 11)}, cap=4)
        self.assertEqual(len(out["users"]), 4)
        self.assertEqual(out["ask_lane"]["candidates"], 10)
        self.assertEqual(out["ask_lane"]["deferred_to_later_day"], 6)
        self.assertEqual([u["user_id"] for u in out["users"]], ["1", "2", "3", "4"])

    def setUp(self):
        d = Path(tempfile.mkdtemp())
        self.ledger = str(d / "ledger.sqlite3")
        verify_ledger.connect(self.ledger).close()
        self.holds = d / "account_holds.jsonl"
        self.holds.write_text("")

    def facts(self, doc, q):
        return owing_proof.verify_facts(doc, q, holds_path=str(self.holds), ledger_path=self.ledger)

    def test_the_filtered_list_still_passes_verify_facts(self):
        users = [user(1, "a", oldest="2026-10-05T00:00:00Z"), user(2, "b", oldest="2026-10-06T00:00:00Z")]
        doc = paid_band_ask.scope(build_doc(users), {1: {"a"}, 2: {"b"}}, cap=400)
        q = lambda sql: replica([(1, "a", "2026-10-05T00:00:00Z", True, "user_verification_needed"),
                                 (2, "b", "2026-10-06T00:00:00Z", True, "user_verification_needed")])  # noqa: E731
        self.assertEqual(self.facts(doc, q), [])

    def test_a_list_edited_after_the_build_is_refused(self):
        users = [user(1, "a")]
        doc = paid_band_ask.scope(build_doc(users), {1: {"a"}}, cap=400)
        doc["users"][0]["request_ids"] = ["a", "injected"]
        q = lambda sql: replica([(1, "a", "2026-10-01T00:00:00Z", True, "user_verification_needed")])  # noqa: E731
        self.assertTrue(any(d.startswith("1:") for d in self.facts(doc, q)))


if __name__ == "__main__":
    unittest.main()
