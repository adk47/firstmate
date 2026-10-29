"""scripts/credit_review/receipts.py: receipt lists from proof_intake (proof-loop [key=proof-loop-plan-1027] ACK).
A user who owes nothing else gets the approved queued line; a user who still owes proof (any
user_verification_needed row) gets R1 (send-locked), never "no need to send anything else"."""
from __future__ import annotations

import credit_test_env  # noqa: F401 - first: test logs never reach the production run.log
import json
import os
import sqlite3
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
from credit_review import receipts  # noqa: E402

SCHEMA = """CREATE TABLE proof_intake (intake_id TEXT PRIMARY KEY, user_id INTEGER NOT NULL, subject TEXT NOT NULL,
  candidate_request_ids_json TEXT NOT NULL DEFAULT '[]', conversation_id TEXT NOT NULL, source TEXT NOT NULL,
  file_sha256 TEXT NOT NULL, file_path TEXT, mime TEXT, bytes INTEGER, received_at TEXT NOT NULL,
  filed_by TEXT NOT NULL, matched_by TEXT, contact_h TEXT, detail_json TEXT, UNIQUE (user_id, file_sha256))"""


class ReceiptsTest(unittest.TestCase):
    def setUp(self):
        self.d = Path(tempfile.mkdtemp())
        self.store = str(self.d / "proof.sqlite")
        db = sqlite3.connect(self.store)
        db.execute(SCHEMA)
        rows = [  # user, subject, candidates, received (the free user first: paid must still lead)
            (6, "credit", ["r-f"], "2026-10-25T08:00:00Z"),           # free, owes nothing -> queued, after paid
            (7, "credit", ["r-g"], "2026-10-25T09:00:00Z"),           # H2: a review_* rule fired -> received
            (8, "credit", ["r-h"], "2026-10-25T10:00:00Z"),           # H1: held account -> received
            (9, "credit", ["r-i"], "2026-10-25T11:00:00Z"),           # email-only match -> no receipt
            (1, "credit", ["R-A"], "2026-10-27T10:00:00Z"),           # owes nothing else -> queued
            (1, "credit", ["r-b"], "2026-10-27T09:00:00Z"),           # second document, same user: merged
            (2, "credit", ["r-c"], "2026-10-27T08:00:00Z"),           # owes proof elsewhere -> received
            (3, "credit", ["r-d"], "2026-10-26T08:00:00Z"),           # approved since -> nothing pending
            (4, "credit", [], "2026-10-26T08:00:00Z"),                # no candidates
            (5, "claim", ["claim-9"], "2026-10-26T08:00:00Z"),        # not a credit receipt
        ]
        for i, (u, subj, c, at) in enumerate(rows):
            matched = "email" if u == 9 else ("authenticated_email" if u == 2 else "professional_id")
            db.execute("INSERT INTO proof_intake (intake_id, user_id, subject, candidate_request_ids_json, "
                       "conversation_id, source, file_sha256, received_at, filed_by, matched_by) VALUES (?,?,?,?,?,?,?,?,?,?)",
                       (f"{u}:{i}", u, subj, json.dumps(c), "777", "intercom", f"sha{i}", at, "b1", matched))
        db.commit()
        self.paying = str(self.d / "paying.json")
        Path(self.paying).write_text(json.dumps({"ids": [1, 2]}))
        self.pending = {1: {"r-a": ("unverified", 0), "r-b": ("pending", 0)},
                        2: {"r-c": ("unverified", 0), "r-x": ("user_verification_needed", 0)},
                        3: {}, 6: {"r-f": ("processing", 0)},
                        7: {"r-g": ("processing", 0), "r-y": ("unverified", 1)},
                        8: {"r-h": ("unverified", 0)}, 9: {"r-i": ("processing", 0)}}
        self.holds = str(self.d / "account_holds.jsonl")
        Path(self.holds).write_text('{"user_id": "999", "kind": "approval_hold"}\n')
        self.ledger = str(self.d / "ledger.sqlite3")
        lg = sqlite3.connect(self.ledger)
        lg.execute("CREATE TABLE verify_refusal_holds (campaign TEXT, user_key TEXT, user_id TEXT, refusals INTEGER, "
                   "reason TEXT, next_recheck_at TEXT, updated_at TEXT, flagged_at TEXT)")
        lg.execute("INSERT INTO verify_refusal_holds VALUES ('status-team-review','user:8','8',1,'account-hold','x','x','x')")
        lg.commit()

    def query(self, sql):
        assert "review_[a-z_]+" in sql   # the H2 predicate is in the replica read
        return [[str(u), rid, st, str(f)] for u, rows in self.pending.items() for rid, (st, f) in rows.items()
                if f"{u}" in sql.split("IN (")[-1]]

    def build(self, **kw):
        return receipts.build(**{"proof_store": self.store, "paying_path": self.paying, "query": self.query,
                                 "holds_path": self.holds, "ledger_path": self.ledger, **kw})

    def test_lists_split_on_owing_proof_and_skip_what_cannot_be_named(self):
        res = self.build()
        q, r = res["lists"]["queued"], res["lists"]["received"]
        self.assertEqual([(u["user_id"], u["paid"], sorted(u["request_ids"])) for u in q],
                         [("1", True, ["r-a", "r-b"]), ("6", False, ["r-f"])])
        # G3: the list names the conversation the (earliest) document was filed in, for the gate's contact check
        self.assertEqual({u["user_id"]: u["filing_conversation"] for u in q + r}["1"], "777")
        self.assertEqual([(u["user_id"], u["request_ids"]) for u in r], [("2", ["r-c"]), ("7", ["r-g"]), ("8", ["r-h"])])
        self.assertTrue(all(u["skip"] is None for u in q + r))
        self.assertEqual(q[0]["first_received"], "2026-10-27T09:00:00Z")
        c = res["counts"]
        self.assertEqual((c["skip_nothing_pending"], c["skip_no_candidate_request"], c["intake_rows_claim"]), (1, 1, 1))
        self.assertEqual((c["list_queued_paid"], c["list_queued_free"], c["list_received_paid"]), (1, 1, 1))
        self.assertEqual((c["owes_uvn"], c["owes_review_hold"], c["owes_account_hold"]), (1, 1, 1))
        self.assertEqual(c["skip_weak_identity"], 1)                     # user 9: email-only match, no receipt
        self.assertNotIn("9", [u["user_id"] for u in q + r])

    def test_the_fraud_lens_hold_list_marks_a_held_account(self):
        Path(self.holds).write_text('{"user_id": "6", "kind": "approval_hold"}\n')
        res = self.build()
        self.assertEqual([u["user_id"] for u in res["lists"]["received"]], ["2", "6", "7", "8"])

    def test_a_stale_hold_list_lists_nothing(self):
        # s1 guard G8: account_holds.jsonl older than 72 h -> stop (a stale list could miss a new hold)
        old = __import__("time").time() - 73 * 3600
        os.utime(self.holds, (old, old))
        with self.assertRaises(receipts.ReceiptsError) as cm:
            self.build()
        self.assertIn("G8", str(cm.exception))

    def test_a_future_dated_hold_list_lists_nothing(self):
        # QA #1456: a future mtime must not read as fresh (its negative age never exceeds 72 h)
        t = __import__("time").time()
        os.utime(self.holds, (t + 3600, t + 3600))
        with self.assertRaises(receipts.ReceiptsError) as cm:
            self.build()
        self.assertIn("future", str(cm.exception))
        os.utime(self.holds, (t + 120, t + 120))     # within the 5-minute clock-skew slack: fine
        self.build()

    def test_unreadable_inputs_list_nothing(self):
        for kw in ({"proof_store": str(self.d / "missing.sqlite")}, {"paying_path": str(self.d / "nope.json")},
                   {"query": lambda sql: [["1", "x"]]}, {"query": lambda sql: [["1", "r", "unverified", "maybe"]]},
                   {"holds_path": str(self.d / "nope.jsonl")}, {"ledger_path": str(self.d / "nodir" / "l.sqlite3")}):
            with self.assertRaises(receipts.ReceiptsError, msg=str(kw)):
                self.build(**kw)
        db = sqlite3.connect(self.store)
        for bad in ('not json', '"r-f"', '{"r-f": 1}', '[1, 2]', '["r-f", ""]', '[null]'):
            db.execute("UPDATE proof_intake SET candidate_request_ids_json=? WHERE user_id=6", (bad,))
            db.commit()
            with self.assertRaises(receipts.ReceiptsError, msg=bad):
                self.build()

    def test_cli_writes_runner_lists_and_fails_closed(self):
        out = self.d / "out"
        p = subprocess.run([sys.executable, str(ROOT / "scripts" / "credit_review" / "receipts.py"), "--out-dir", str(out),
                            "--proof-store", str(self.d / "missing.sqlite"), "--paying", self.paying],
                           capture_output=True, text=True, check=False)
        self.assertEqual(p.returncode, 2)
        self.assertFalse((out / "receipts-queued.json").exists())
        db = sqlite3.connect(self.store)
        db.execute("DELETE FROM proof_intake")
        db.commit()
        p = subprocess.run([sys.executable, str(ROOT / "scripts" / "credit_review" / "receipts.py"), "--out-dir", str(out),
                            "--proof-store", self.store, "--paying", self.paying],
                           capture_output=True, text=True, check=False)
        self.assertEqual(p.returncode, 0, p.stderr)
        for k in ("queued", "received"):
            doc = json.loads((out / f"receipts-{k}.json").read_text())
            self.assertEqual(doc["users"], [])
            self.assertTrue(doc["generated_at"])


if __name__ == "__main__":
    unittest.main()
