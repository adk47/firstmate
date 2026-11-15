"""credit_review/audience_order.py: the ONE send order of every outbound audience list.

A mixed batch of paying and non-paying users comes out paying first, the longest wait first inside a tier, and the
user id last - whatever order the source returned its rows in. The mutation cases invert the rule and assert that the
same check then FAILS, so this file cannot pass against a builder that sorts the other way round.
"""
from __future__ import annotations

import credit_test_env  # noqa: F401 - first: test logs never reach the production run.log
import random
import sqlite3
import sys
import tempfile
import unittest
from datetime import datetime, timezone
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
from credit_review import audience_order as ao  # noqa: E402
from credit_review import owing_proof as op  # noqa: E402
from credit_review import paid_band_ask  # noqa: E402

#        user, request, status, created, paid, review_fired, proofRequest, proof_required
#  six users with the SAME oldest request (the tie), three paying and three not, plus one older free user and one
#  newer paying user: the free user waited longest of all and must still come after every paying one
SAME = "2026-09-01 00:00:00.000000 UTC"
MIXED = [["10", "r10", "user_verification_needed", SAME, "0", "0", "0", "0"],
         ["9", "r9", "user_verification_needed", SAME, "1", "0", "0", "0"],
         ["2", "r2", "user_verification_needed", SAME, "0", "0", "0", "0"],
         ["30", "r30", "user_verification_needed", SAME, "1", "0", "0", "0"],
         ["4", "r4", "user_verification_needed", SAME, "1", "0", "0", "0"],
         ["7", "r7", "user_verification_needed", SAME, "0", "0", "0", "0"],
         ["50", "r50", "user_verification_needed", "2026-01-01 00:00:00.000000 UTC", "0", "0", "0", "0"],
         ["60", "r60", "user_verification_needed", "2026-10-01 00:00:00.000000 UTC", "1", "0", "0", "0"]]
WANT = ["4", "9", "30", "60",          # paying: the tie by user id (4 < 9 < 30, numeric), then the newer request
        "50", "2", "7", "10"]          # free: the longest wait, then the tie by user id (2 < 7 < 10, not "10" < "2")


def paid_first(flags: list[bool]) -> bool:
    """No paying row after a non-paying one - the check the sentinel runs on what was sent."""
    return not any(flags[i] is False and flags[i + 1] is True for i in range(len(flags) - 1))


class KeyTest(unittest.TestCase):
    def rows(self):
        return [{"user_id": "3", "paid": False, "at_risk": False, "since": "2026-01-01"},
                {"user_id": "1", "paid": True, "at_risk": False, "since": "2026-06-01"},
                {"user_id": "2", "paid": True, "at_risk": True, "since": "2026-09-01"},
                {"user_id": "5", "paid": True, "at_risk": False, "since": "2026-03-01"},
                {"user_id": "4", "paid": False, "at_risk": True, "since": "2026-02-01"}]

    def order(self, rows):
        return [r["user_id"] for r in sorted(rows, key=lambda r: ao.key(
            paid=r["paid"], at_risk=r["at_risk"], waiting_since=r["since"], user_id=r["user_id"]))]

    def test_a_mixed_batch_is_paying_at_risk_then_paying_then_free_oldest_first(self):
        # user 4 carries a churn signal but does not pay: the signal promotes nobody into the paying tiers
        self.assertEqual(self.order(self.rows()), ["2", "5", "1", "3", "4"])

    def test_the_order_does_not_depend_on_the_order_the_rows_arrived_in(self):
        rows = self.rows()
        for seed in range(20):
            random.Random(seed).shuffle(rows)
            self.assertEqual(self.order(rows), ["2", "5", "1", "3", "4"], seed)

    def test_the_same_wait_is_broken_by_the_numeric_user_id(self):
        rows = [{"user_id": u, "paid": True, "at_risk": False, "since": "2026-01-01"} for u in ("10", "9", "100", "2")]
        self.assertEqual(self.order(rows), ["2", "9", "10", "100"])

    def test_a_non_numeric_user_id_sorts_instead_of_raising_and_goes_last_in_its_tie(self):
        rows = [{"user_id": u, "paid": True, "at_risk": False, "since": "2026-01-01"} for u in ("x7", "8", "")]
        self.assertEqual(self.order(rows), ["8", "", "x7"])

    def test_waiting_since_is_compared_as_given_so_an_epoch_stays_numeric(self):
        rows = [{"user_id": "1", "paid": True, "at_risk": False, "since": 1000},
                {"user_id": "2", "paid": True, "at_risk": False, "since": 999}]
        self.assertEqual(self.order(rows), ["2", "1"])        # as strings "1000" < "999" would put user 1 first


class OwingListOrderTest(unittest.TestCase):
    """The uvn-status audience end to end: the list `owing_proof.build` writes, from a mixed batch."""

    def setUp(self):
        d = Path(tempfile.mkdtemp())
        self.ledger = str(d / "ledger.sqlite3")
        db = sqlite3.connect(self.ledger)
        db.execute("CREATE TABLE verify_messages (id INTEGER PRIMARY KEY AUTOINCREMENT, parent_row INTEGER, account_id TEXT, "
                   "user_key TEXT, campaign TEXT DEFAULT 'uvn-status', kind TEXT, status TEXT, day TEXT, message_id TEXT, "
                   "request_ids_json TEXT DEFAULT '[]', proof_tagged_at TEXT, last_reply_at TEXT, "
                   "extension_requested_at TEXT, proof_attachments INTEGER)")
        db.execute("CREATE TABLE verify_proof_reviews (family INTEGER)")
        db.execute("CREATE TABLE verify_refusal_holds (user_id TEXT, reason TEXT, flagged_at TEXT)")
        db.commit()
        self.holds = str(d / "holds.jsonl")
        Path(self.holds).write_text("")
        self.risk = str(d / "none.csv")

    def ask(self, uid, request_ids, day="2026-09-01"):
        db = sqlite3.connect(self.ledger)
        db.execute("INSERT INTO verify_messages (account_id, campaign, kind, status, day, request_ids_json) "
                   "VALUES (?, 'uvn-status', 'initial', 'sent', ?, ?)", (str(uid), day, str([request_ids]).replace("'", '"')))
        db.commit()
        db.close()

    def build(self, rows, now=None):
        def replica(sql):                 # the status guard is answered with the statuses in the table, the rest with rows
            if sql == op.STATUS_GUARD_SQL:
                return [[st] for st in sorted({r[2] for r in rows})]
            return [list(r) for r in rows]
        return op.build(query=replica, ledger_path=self.ledger, holds_path=self.holds, at_risk_path=self.risk,
                        now=now)["users"]

    def test_a_mixed_batch_lists_every_paying_user_before_any_free_one(self):
        users = self.build(MIXED)
        self.assertEqual([u["user_id"] for u in users], WANT)
        self.assertTrue(paid_first([u["paid"] for u in users]))
        self.assertNotIn("_tier", users[0])                   # no sort scaffolding leaks into the signed list

    def test_the_list_is_the_same_whatever_order_the_replica_returned_the_rows_in(self):
        for seed in range(25):
            rows = [list(r) for r in MIXED]
            random.Random(seed).shuffle(rows)
            self.assertEqual([u["user_id"] for u in self.build(rows)], WANT, f"seed {seed}")

    def test_mutation_an_inverted_tier_puts_free_first_and_the_check_fails(self):
        with mock.patch.object(ao, "tier", lambda paid, at_risk=False: 0 if not paid else 1):
            users = self.build(MIXED)
        self.assertFalse(paid_first([u["paid"] for u in users]), "the inverted sort was not noticed")
        self.assertNotEqual([u["user_id"] for u in users], WANT)

    def test_mutation_without_the_user_id_the_order_follows_the_source_rows(self):
        """What the builders did before: (tier, wait) and nothing after it. Paid-first holds, the order does not."""
        with mock.patch.object(ao, "_uid", lambda user_id: ()):
            seen = set()
            for seed in range(25):
                rows = [list(r) for r in MIXED]
                random.Random(seed).shuffle(rows)
                users = self.build(rows)
                self.assertTrue(paid_first([u["paid"] for u in users]))
                seen.add(tuple(u["user_id"] for u in users))
        self.assertGreater(len(seen), 1, "the tie was not order-dependent: this fixture no longer proves the tiebreak")

    def test_a_reminder_class_row_carries_no_sort_scaffolding_and_keeps_its_place_in_the_order(self):
        # users 50 (free, the longest wait) and 60 (paying, the newest request) already had a sent ask naming their only
        # owed row: both are listed as the uvn-reminder-14 class, and the one order still decides where they land
        self.ask(50, "r50")
        self.ask(60, "r60")
        users = self.build(MIXED, now=datetime(2026, 10, 1, tzinfo=timezone.utc))
        self.assertEqual([u["user_id"] for u in users], WANT)
        self.assertEqual({u["user_id"]: u["class"] for u in users if u["class"] == op.REMINDER},
                         {"50": op.REMINDER, "60": op.REMINDER})
        self.assertEqual([u["user_id"] for u in users if "_tier" in u], [])


class PaidBandAskOrderTest(unittest.TestCase):
    """The paid-band ask lane's list: the same order, from the same key, whatever order the build listed its users in."""

    SAME = "2026-09-01T00:00:00Z"

    def users(self):
        return [{"user_id": uid, "paid": paid, "at_risk": False, "class": "uvn", "oldest": self.SAME,
                 "request_ids": [f"r{uid}"], "facts": [[f"r{uid}", "user_verification_needed", False]]}
                for uid, paid in (("10", False), ("9", True), ("2", False), ("30", True), ("4", True), ("7", False))]

    def build(self, users, paid_only=False):
        band = {int(u["user_id"]): set(u["request_ids"]) for u in users}
        doc = {"generated_at": "2026-11-11T11:00:00+00:00", "users": users}
        return paid_band_ask.scope(doc, band, cap=400, paid_only=paid_only)["users"]

    def test_the_tie_is_broken_by_the_user_id_whatever_order_the_build_listed_them_in(self):
        for seed in range(20):
            users = self.users()
            random.Random(seed).shuffle(users)
            got = [u["user_id"] for u in self.build(users)]
            self.assertEqual(got, ["4", "9", "30", "2", "7", "10"], f"seed {seed}")
            self.assertTrue(paid_first([u["paid"] for u in self.build(users)]))

    def test_the_lane_still_lists_paid_users_only_by_default(self):
        self.assertEqual([u["user_id"] for u in self.build(self.users(), paid_only=True)], ["4", "9", "30"])

    def test_mutation_an_inverted_tier_puts_free_first_and_the_check_fails(self):
        with mock.patch.object(ao, "tier", lambda paid, at_risk=False: 0 if not paid else 1):
            users = self.build(self.users())
        self.assertFalse(paid_first([u["paid"] for u in users]), "the inverted sort was not noticed")
        self.assertNotEqual([u["user_id"] for u in users], ["4", "9", "30", "2", "7", "10"])


if __name__ == "__main__":
    unittest.main()
