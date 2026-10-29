"""credit_review/owing_proof.py: the audience for the send-locked S1 line credit-hold-status (card L14a). Users who
owe proof (U / H2 / H1, the steward's CLASS_SQL) AND were never told (no ledger note, no proofRequest marker); the
rows they owe on; at-risk paid first, then paid, then free, oldest first; inputs fail closed."""
from __future__ import annotations

import credit_test_env  # noqa: F401 - first: test logs never reach the production run.log
import sqlite3
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
from credit_review import owing_proof as op  # noqa: E402

#        user, request, status, created, paid, review_fired, proofRequest
ROWS = [["1", "u1", "user_verification_needed", "2026-09-01", "0", "0", "0"],   # free U, never told
        ["2", "h2", "unverified", "2026-08-01", "1", "1", "0"],                  # paid H2, never told
        ["2", "ok", "processing", "2026-08-02", "1", "0", "0"],                  #   (not owed: not named)
        ["3", "a3", "unverified", "2026-10-01", "1", "0", "0"],                  # paid held account (H1)
        ["4", "t4", "user_verification_needed", "2026-07-01", "1", "0", "0"],    # paid U but told by the ledger
        ["5", "m5", "user_verification_needed", "2026-07-01", "0", "0", "1"],    # proofRequest marker: told
        ["6", "n6", "unverified", "2026-07-01", "1", "0", "0"],                  # owes nothing: not listed
        ["7", "r7", "user_verification_needed", "2026-10-02", "1", "0", "0"]]    # paid U, at-risk


class OwingProofTest(unittest.TestCase):
    def setUp(self):
        d = Path(tempfile.mkdtemp())
        self.ledger = str(d / "ledger.sqlite3")
        db = sqlite3.connect(self.ledger)
        db.execute("CREATE TABLE verify_messages (account_id TEXT, status TEXT)")
        db.execute("CREATE TABLE verify_refusal_holds (user_id TEXT, reason TEXT, flagged_at TEXT)")
        db.execute("INSERT INTO verify_messages VALUES ('4', 'sent'), ('1', 'refused')")   # a refusal is not "told"
        db.execute("INSERT INTO verify_refusal_holds VALUES ('3', 'account-hold', 'x')")
        db.commit()
        self.holds = str(d / "holds.jsonl"); Path(self.holds).write_text("")
        self.risk = str(d / "risk.csv")
        Path(self.risk).write_text("userid,teamid,churn_signal\n7,t,past_due\n2,t,\n")
        self.d = d

    def build(self, **kw):
        return op.build(**{"query": lambda sql: [list(r) for r in ROWS], "ledger_path": self.ledger,
                           "holds_path": self.holds, "at_risk_path": self.risk, **kw})

    def test_audience_classes_never_told_and_order(self):
        res = self.build()
        got = [(u["user_id"], u["class"], u["request_ids"], u["paid"], u["at_risk"]) for u in res["users"]]
        self.assertEqual(got, [("7", "uvn", ["r7"], True, True),             # paid at-risk first
                               ("2", "review_hold", ["h2"], True, False),    # then paid, oldest first
                               ("3", "account_hold", ["a3"], True, False),
                               ("1", "uvn", ["u1"], False, False)])          # then free
        c = res["counts"]
        self.assertEqual((c["skip_already_told_uvn"], c["list_paid_at_risk"], c["at_risk_source"]), (2, 1, "read"))
        self.assertTrue(all(u["skip"] is None for u in res["users"]))

    def test_without_the_at_risk_file_paid_still_lead(self):
        res = self.build(at_risk_path=str(self.d / "none.csv"))
        self.assertEqual([u["user_id"] for u in res["users"]], ["2", "3", "7", "1"])
        self.assertEqual(res["counts"]["at_risk_source"], "missing")

    def test_inputs_fail_closed(self):
        for kw in ({"query": lambda sql: [["1", "x", "unverified", "d", "1", "maybe", "0"]]},
                   {"ledger_path": str(self.d / "nodir" / "l.sqlite3")}, {"holds_path": str(self.d / "nope.jsonl")}):
            with self.assertRaises(op.OwingProofError, msg=str(kw)):
                self.build(**kw)


if __name__ == "__main__":
    unittest.main()
