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
from credit_verify.docverify import VERSION as VER  # noqa: E402

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

    def dv(self, verdicts, extract=None, version=None):
        """A doc-verify store with the reader's latest artifact step per file sha ({sha: kind-or-None}) and its extract
        step's status ({sha: 'ok'|'error'}, default 'ok' for every sha in verdicts)."""
        self.n_dv = getattr(self, "n_dv", 0) + 1
        path = str(self.d / f"dv{self.n_dv}.sqlite")
        dv = sqlite3.connect(path)
        dv.execute("CREATE TABLE dv_steps (id INTEGER PRIMARY KEY, proof_id TEXT, step TEXT, status TEXT, detail_json TEXT, "
                   "version TEXT)")
        for sha, st in {**{s: "ok" for s in verdicts}, **(extract or {})}.items():
            dv.execute("INSERT INTO dv_steps (proof_id, step, status, detail_json, version) VALUES (?, 'extract', ?, ?, ?)",
                       (sha, st, json.dumps({"ok": st == "ok", "error": None if st == "ok" else "boom"}), version or VER))
        for sha, kind in verdicts.items():
            dv.execute("INSERT INTO dv_steps (proof_id, step, status, detail_json, version) VALUES (?, 'artifact', ?, ?, ?)",
                       (sha, kind or "none", json.dumps({"artifact": kind, "why": "t", "text_checked": True}), version or VER))
        dv.commit()
        db = sqlite3.connect(self.store)
        db.execute("CREATE TABLE IF NOT EXISTS fingerprints (proof_id TEXT, kind TEXT)")
        db.commit()
        return path

    def test_the_r1_list_states_the_filing_class_from_the_doc_reader_and_only_when_known(self):
        # h2 r1 filing-class producer: user 2 (received; sha6) read as a document of record -> false; user 7 (sha1) a
        # Muso screenshot (SYS-001) -> true; user 8 (sha2) unread -> no field (the gate refuses r1_filing_class_unknown)
        res = self.build(dv_store=self.dv({"sha6": None, "sha1": "muso_ui_screenshot", "sha4": "muso_ui_screenshot", "sha5": None}))
        got = {u["user_id"]: u.get("filing_muso_ui", "absent") for u in res["lists"]["received"]}
        self.assertEqual(got, {"2": False, "7": True, "8": "absent"})
        # one Muso screenshot among a user's filings (user 1: sha4 SYS-001 + sha5 a record) states true
        self.assertIs(next(u for u in res["lists"]["queued"] if u["user_id"] == "1")["filing_muso_ui"], True)
        self.assertEqual((res["counts"]["filing_class_record"], res["counts"]["filing_class_muso_ui"]), (1, 2))
        # one unread filing among a user's documents keeps the class unknown (every filing must be read for 'false')
        db = sqlite3.connect(self.store)
        db.execute("INSERT INTO proof_intake (intake_id, user_id, subject, candidate_request_ids_json, conversation_id, "
                   "source, file_sha256, received_at, filed_by, matched_by) VALUES ('2:x', 2, 'credit', '[\"r-c\"]', '777', "
                   "'intercom', 'sha-unread', '2026-10-28T08:00:00Z', 'b1', 'professional_id')")
        db.commit()
        res = self.build(dv_store=self.dv({"sha6": None, "sha1": "muso_ui_screenshot"}))
        self.assertNotIn("filing_muso_ui", next(u for u in res["lists"]["received"] if u["user_id"] == "2"))
        # QA #1602: an extract that ENDED IN ERROR is unread - the class stays unknown, never false (user 8, sha2)
        V = {"sha6": None, "sha1": "muso_ui_screenshot", "sha2": None}
        res = self.build(dv_store=self.dv(V, extract={"sha2": "error"}))
        self.assertNotIn("filing_muso_ui", next(u for u in res["lists"]["received"] if u["user_id"] == "8"))
        # ... and a later ok re-read makes it a record (the LATEST extract step counts)
        path = self.dv(V, extract={"sha2": "error"})
        dv = sqlite3.connect(path)
        dv.execute("INSERT INTO dv_steps (proof_id, step, status, detail_json, version) VALUES ('sha2', 'extract', 'ok', '{}', ?)", (VER,))
        dv.execute("INSERT INTO dv_steps (proof_id, step, status, detail_json, version) VALUES ('sha2', 'artifact', 'none', ?, ?)",
                   (json.dumps({"artifact": None, "why": "t", "text_checked": True}), VER))   # its verdict follows it
        dv.commit()
        res = self.build(dv_store=path)
        self.assertIs(next(u for u in res["lists"]["received"] if u["user_id"] == "8")["filing_muso_ui"], False)
        # QA #1602: reads under an OLDER reader version say nothing - only the current VERSION's steps count
        res = self.build(dv_store=self.dv({"sha6": None, "sha1": "muso_ui_screenshot"}, version="dv-old"))
        self.assertTrue(all("filing_muso_ui" not in u for k in res["lists"] for u in res["lists"][k]))
        # ... and a current-version artifact whose only ok extract is from an OLDER reader stays unknown (user 8, sha2)
        path = self.dv({"sha6": None, "sha1": "muso_ui_screenshot", "sha2": None})
        dv = sqlite3.connect(path)
        dv.execute("DELETE FROM dv_steps WHERE proof_id = 'sha2' AND step = 'extract'")
        dv.execute("INSERT INTO dv_steps (proof_id, step, status, detail_json, version) VALUES ('sha2', 'extract', 'ok', '{}', 'dv-old')")
        dv.commit()
        res = self.build(dv_store=path)
        self.assertNotIn("filing_muso_ui", next(u for u in res["lists"]["received"] if u["user_id"] == "8"))
        # QA #1602: an ok extract with NO artifact verdict (the stored-data fallback) stays unknown (user 8, sha2)
        path = self.dv({"sha6": None, "sha1": "muso_ui_screenshot", "sha2": None})
        dv = sqlite3.connect(path)
        dv.execute("DELETE FROM dv_steps WHERE proof_id = 'sha2' AND step = 'artifact'")
        dv.commit()
        res = self.build(dv_store=path)
        self.assertNotIn("filing_muso_ui", next(u for u in res["lists"]["received"] if u["user_id"] == "8"))
        # QA #1602: a NEW ok extract committed after the latest artifact verdict (its own verdict not written yet) - the
        # older verdict is for an earlier read: unknown (user 8, sha2)
        path = self.dv({"sha6": None, "sha1": "muso_ui_screenshot", "sha2": None})
        dv = sqlite3.connect(path)
        dv.execute("INSERT INTO dv_steps (proof_id, step, status, detail_json, version) VALUES ('sha2', 'extract', 'ok', '{}', ?)", (VER,))
        dv.commit()
        res = self.build(dv_store=path)
        self.assertNotIn("filing_muso_ui", next(u for u in res["lists"]["received"] if u["user_id"] == "8"))
        dv.execute("INSERT INTO dv_steps (proof_id, step, status, detail_json, version) VALUES ('sha2', 'artifact', 'none', ?, ?)",
                   (json.dumps({"artifact": None, "why": "t", "text_checked": True}), VER))
        dv.commit()
        res = self.build(dv_store=path)                       # ... its verdict lands: a record again
        self.assertIs(next(u for u in res["lists"]["received"] if u["user_id"] == "8")["filing_muso_ui"], False)
        # a filing the reader returns no row for is unread, never a record
        import unittest.mock
        from credit_verify.docverify import artifacts
        with unittest.mock.patch.object(artifacts, "filed_rows", lambda *a, **kw: []):
            res = self.build(dv_store=self.dv({}))
        self.assertTrue(all("filing_muso_ui" not in u for k in res["lists"] for u in res["lists"][k]))
        # unreadable doc-verify store: nobody gets the field (fail closed), and the run says so
        res = self.build(dv_store=str(self.d / "missing" / "dv.sqlite"))
        self.assertTrue(all("filing_muso_ui" not in u for k in res["lists"] for u in res["lists"][k]))
        self.assertEqual(res["counts"]["filing_class_unreadable"], 1)

    def test_with_filing_carries_the_class_only_as_a_bool(self):
        from credit_review import uvn_status
        for src, want in (({"filing_muso_ui": False}, False), ({"filing_muso_ui": True}, True),
                          ({"filing_muso_ui": "false"}, "absent"), ({}, "absent")):
            p = uvn_status.with_filing({"user": {"id": "2"}}, src)
            self.assertEqual(p["user"].get("filing_muso_ui", "absent"), want, src)

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




class StrongLabelTest(unittest.TestCase):
    """[key=receipt-match-label] (l1 ruling-external-id-receipts-1102.md): the Intercom contact-handle match is
    a professional-id+email match under an older spelling. Normalising the LABEL re-admits the rows already in
    the store without a data migration, and does not widen the allowlist to any other string."""

    def test_the_old_spelling_normalises_and_admits(self):
        self.assertEqual(receipts.receipt_strong_label("external_id+email"), "professional_id+email")
        self.assertIn(receipts.receipt_strong_label("external_id+email"), receipts.RECEIPT_MATCH)

    def test_the_strict_set_is_unchanged_and_the_literal_is_not_added(self):
        """QA on #1649: STRONG_MATCH is shared with need_asks.py's producer and pinned equal to the send gate's
        EMAIL_FILED_STRONG_MATCH. It must stay exactly these three labels, or the producer lists asks the gate
        refuses. The receipt-only label lives in RECEIPT_MATCH."""
        self.assertEqual(receipts.STRONG_MATCH, ("professional_id", "authenticated_email", "session"))
        self.assertEqual(" ".join(receipts.STRONG_MATCH),
                         "professional_id authenticated_email session")   # the gate's pinned literal
        self.assertNotIn("external_id+email", receipts.STRONG_MATCH)
        self.assertNotIn("proof_on_file", receipts.STRONG_MATCH)
        for label in receipts.STRONG_MATCH:
            self.assertEqual(receipts.strong_label(label), label)
        self.assertEqual(receipts.strong_label("professional_id+email"), "")      # receipt-only
        self.assertEqual(receipts.receipt_strong_label("professional_id+email"), "professional_id+email")

    def test_weak_or_unknown_labels_stay_refused(self):
        for label in (None, "", "  ", "email", "email+domain", "external_id", "proof_on_file",
                      "professional_id+email+extra", "unmatched: no verified account handle"):
            self.assertEqual(receipts.strong_label(label), "", label)
            self.assertEqual(receipts.receipt_strong_label(label), "", label)

    def test_the_new_spelling_is_what_todays_writer_emits(self):
        src = (ROOT / "scripts" / "credit_verify" / "proof" / "intake.py").read_text()
        self.assertIn('return ids[0], "professional_id+email"', src)
        self.assertNotIn('return ids[0], "external_id+email"', src)


class LegacyRowAdmittanceTest(unittest.TestCase):
    """The 999 rows already written with the old label must produce receipts on the next build, and
    proof_on_file must keep being skipped until l1 answers Ruling 2 (it is an identity label, but a
    weaker one: it has no email confirmation - only a unique export conversation bucket)."""

    def setUp(self):
        self.d = Path(tempfile.mkdtemp())
        self.store = str(self.d / "proof.sqlite")
        db = sqlite3.connect(self.store)
        db.execute(SCHEMA)
        for i, (uid, matched) in enumerate(((11, "external_id+email"), (12, "proof_on_file"),
                                            (13, "professional_id+email"), (14, "email"),
                                            (15, "proof_on_file"))):
            conv = "" if uid == 15 else "215475213550081"   # 15: same-conversation label with no conversation
            db.execute("INSERT INTO proof_intake (intake_id, user_id, subject, candidate_request_ids_json, "
                       "conversation_id, source, file_sha256, received_at, filed_by, matched_by) "
                       "VALUES (?,?,?,?,?,?,?,?,?,?)",
                       (f"{uid}:{i}", uid, "credit", json.dumps([f"r-{uid}"]), conv,
                        "intercom", f"sha{uid}", "2026-11-01T02:20:11Z", "intake-cron", matched))
        db.commit()

    def test_old_label_admits_and_weak_labels_do_not(self):
        out, counts = receipts.intake_by_user(self.store)
        self.assertIn(11, out)                     # the old spelling, re-admitted
        self.assertIn(13, out)                     # today's spelling
        self.assertNotIn(14, out)                  # email-only: still weak
        self.assertIn(12, out)                     # proof_on_file WITH a conversation: admitted (Ruling 2)
        self.assertIn(11, out)                     # the old spelling still re-admits through RECEIPT_MATCH
        self.assertNotIn(15, out)                  # proof_on_file without one: no same-conversation receipt
        self.assertEqual(counts["skip_weak_identity"], 2)
        self.assertEqual(counts["admit_same_conversation_match"], 1)
        self.assertEqual(out[11]["request_ids"], ["r-11"])
        self.assertEqual(out[12]["filing_conversation"], "215475213550081")   # the thread the receipt replies into

    def test_a_same_conversation_label_is_never_in_the_strict_set(self):
        """Ruling 2 admits proof_on_file for RECEIPTS only; the identity sets used by approvals/link/dedupe
        must stay exactly the strict set, so the label can never leak into them."""
        self.assertEqual(receipts.strong_label("proof_on_file"), "")
        self.assertNotIn("proof_on_file", receipts.STRONG_MATCH)
        self.assertEqual(receipts.receipt_label("proof_on_file", "215475213550081"), "proof_on_file")
        self.assertEqual(receipts.receipt_label("proof_on_file", ""), "")

if __name__ == "__main__":
    unittest.main()
