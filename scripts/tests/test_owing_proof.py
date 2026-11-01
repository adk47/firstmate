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

#        user, request, status, created, paid, review_fired, proofRequest, proof_required
ROWS = [["1", "u1", "user_verification_needed", "2026-09-01", "0", "0", "0", "0"],   # free U, never told
        ["2", "h2", "unverified", "2026-08-01", "1", "1", "0", "0"],                  # paid H2, never told
        ["2", "ok", "processing", "2026-08-02", "1", "0", "0", "0"],                  #   (not owed: not named)
        ["3", "a3", "unverified", "2026-10-01", "1", "0", "0", "0"],                  # paid held account (H1)
        ["4", "t4", "user_verification_needed", "2026-07-01", "1", "0", "0", "0"],    # paid U but told by the ledger
        ["5", "m5", "user_verification_needed", "2026-07-01", "0", "0", "1", "0"],    # proofRequest marker: told
        ["6", "n6", "unverified", "2026-07-01", "1", "0", "0", "0"],                  # owes nothing: not listed
        ["7", "r7", "user_verification_needed", "2026-10-02", "1", "0", "0", "0"]]    # paid U, at-risk


class OwingProofTest(unittest.TestCase):
    def setUp(self):
        d = Path(tempfile.mkdtemp())
        self.ledger = str(d / "ledger.sqlite3")
        db = sqlite3.connect(self.ledger)
        db.execute("CREATE TABLE verify_messages (account_id TEXT, status TEXT, campaign TEXT DEFAULT 'uvn-status')")
        db.execute("CREATE TABLE verify_refusal_holds (user_id TEXT, reason TEXT, flagged_at TEXT)")
        db.execute("INSERT INTO verify_messages (account_id, status) VALUES ('4', 'sent'), ('1', 'refused')")   # a refusal is not "told"
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
        for kw in ({"query": lambda sql: [["1", "x", "unverified", "d", "1", "maybe", "0", "0"]]},
                   {"query": lambda sql: [["1", "x", "unverified", "d", "1", "0", "0", "yes"]]},
                   {"ledger_path": str(self.d / "nodir" / "l.sqlite3")}, {"holds_path": str(self.d / "nope.jsonl")}):
            with self.assertRaises(op.OwingProofError, msg=str(kw)):
                self.build(**kw)


class ProofRequiredAudienceTest(OwingProofTest):
    """v1 / r5 / p1 [key=k-proof-required]: an open unverified/processing row with core proof_required = true is OWED
    (the ask class), and only an earlier uvn-status ASK - never a status line - keeps a user off the list."""

    def test_proof_required_rows_are_asked_and_a_status_line_does_not_block(self):
        rows = [["8", "p8", "unverified", "2026-09-05", "1", "0", "0", "1"],      # the 21's shape
                ["8", "q8", "processing", "2026-09-06", "1", "0", "0", "0"],      # not owed: not named
                ["9", "p9", "unverified", "2026-09-07", "1", "0", "0", "1"],      # told by a status line only
                ["10", "p10", "unverified", "2026-09-08", "1", "0", "0", "1"]]    # already ASKED
        db = sqlite3.connect(self.ledger)
        db.execute("INSERT INTO verify_messages VALUES ('9', 'sent', 'status-team-review'), ('10', 'sent', 'uvn-status')")
        db.commit(); db.close()
        res = self.build(query=lambda sql: [list(r) for r in rows])
        got = {u["user_id"]: (u["class"], u["request_ids"], u["facts"]) for u in res["users"]}
        self.assertEqual(got, {"8": ("uvn", ["p8"], [["p8", "unverified", True]]),
                               "9": ("uvn", ["p9"], [["p9", "unverified", True]])})
        self.assertEqual(len(res["replica_facts"]["sha256"]), 64)
        self.assertIn("proof_required", res["replica_facts"]["query"])
        # r5: the header's query is the EXACT runnable SQL the build ran (and verify_facts re-runs), with its sha256
        seen = []
        res = self.build(query=lambda sql: seen.append(sql) or [list(r) for r in rows])
        self.assertIn(res["replica_facts"]["query"], seen)
        self.assertTrue(res["replica_facts"]["query"].startswith("SELECT "))
        import hashlib
        self.assertEqual(res["replica_facts"]["query_sha256"], hashlib.sha256(res["replica_facts"]["query"].encode()).hexdigest())

    def vf(self, lst, query):
        return op.verify_facts(lst, query, holds_path=self.holds, ledger_path=self.ledger)

    def test_verify_facts_flags_a_user_whose_rows_changed(self):
        rows = [["8", "p8", "unverified", "2026-09-05", "1", "0", "0", "1"]]
        lst = self.build(query=lambda sql: [list(r) for r in rows])
        self.assertEqual(self.vf(lst, lambda sql: [list(r) for r in rows]), [])
        moved = [["8", "p8", "approved", "2026-09-05", "1", "0", "0", "1"]]            # decided since the build
        self.assertEqual(len(self.vf(lst, lambda sql: [list(r) for r in moved])), 1)
        cleared = [["8", "p8", "unverified", "2026-09-05", "1", "0", "0", "0"]]        # proof no longer required
        self.assertEqual(len(self.vf(lst, lambda sql: [list(r) for r in cleared])), 1)
    def test_verify_facts_sees_a_request_owed_after_the_build_and_an_edited_list(self):
        # QA #1565: the owed set is RECOMPUTED - a second proof_required row that appeared after the build is a change
        rows = [["8", "p8", "unverified", "2026-09-05", "1", "0", "0", "1"]]
        lst = self.build(query=lambda sql: [list(r) for r in rows])
        self.assertEqual(self.vf(lst, lambda sql: [list(r) for r in rows]), [])
        more = rows + [["8", "p9", "processing", "2026-10-30", "1", "0", "0", "1"]]
        self.assertEqual(len(self.vf(lst, lambda sql: [list(r) for r in more])), 1)
        import copy
        edited = copy.deepcopy(lst)
        u8 = next(u for u in edited["users"] if u["user_id"] == "8")
        u8["request_ids"] = []                                                    # ids no longer what is owed
        self.assertTrue(any(d.startswith("8:") for d in self.vf(edited, lambda sql: [list(r) for r in rows])))
        tampered = copy.deepcopy(lst)
        next(u for u in tampered["users"] if u["user_id"] == "8")["facts"] = [["p8", "unverified", False]]
        self.assertTrue(any(d.startswith("header:") for d in self.vf(tampered, lambda sql: [list(r) for r in rows])))


    def test_the_builders_class_list_verifies_and_a_rewrite_carrying_the_parent_header_does_not(self):
        # r5 776: the 08:00Z dry tick's split kept the full list's facts sha -> the uvn check refused it (rightly)
        q = lambda sql: [list(r) for r in ROWS]
        res = self.build()
        uvn = op.class_list(res, "uvn")
        self.assertEqual([u["user_id"] for u in uvn["users"]], ["7", "1"])
        self.assertEqual(uvn["split_of"], {"class": "uvn", "users": 4, "sha256": res["replica_facts"]["sha256"]})
        self.assertEqual(self.vf(uvn, q), [])                                   # the split list verifies
        old_way = {**res, "users": uvn["users"]}                                # the tick's old rewrite
        self.assertTrue(any(d.startswith("header:") for d in self.vf(old_way, q)))
        # the CLI writes it with signed_on, from the same build
        import json, unittest.mock
        out, cls = self.d / "owing.json", self.d / "owing-uvn.json"
        with unittest.mock.patch.object(op, "build", lambda **kw: res):
            self.assertEqual(op._main(["--out", str(out), "--class-out", f"uvn={cls}"]), 0)
        doc = json.loads(cls.read_text())
        self.assertEqual((doc["replica_facts"], doc["users"]), (uvn["replica_facts"], uvn["users"]))
        self.assertIn("signed_on", doc)
        with self.assertRaises(SystemExit):
            op._main(["--out", str(out), "--class-out", "bogus=x"])


if __name__ == "__main__":
    unittest.main()
