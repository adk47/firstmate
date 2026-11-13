"""The proof marker (credit_review/proof_marker.py): a sent note is tagged `proof_tagged_at` from the documents on
file. Pins the rule (a document dated after the note, filed against one of the note's requests; any document for
a claim note), the things it never does (judge, send, write a conversation id), the review rail, the audit row,
the revert, and that an unreadable proof store is never read as "no documents"."""
from __future__ import annotations

import credit_test_env  # noqa: F401 - first: test logs never reach the production run.log
import io
import json
import socket
import sqlite3
import subprocess
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from datetime import datetime, timezone
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
from credit_review import proof_marker as pm  # noqa: E402
from credit_review import verify_ledger as vl  # noqa: E402
from credit_verify.proof.store import ProofStore  # noqa: E402

NOW = datetime(2026, 11, 13, 12, 0, tzinfo=timezone.utc)


class ProofMarkerTest(unittest.TestCase):
    def setUp(self) -> None:
        d = Path(tempfile.mkdtemp())
        self.ledger, self.store, self.kill = str(d / "ledger.sqlite3"), str(d / "proof.sqlite"), str(d / "kill")
        self.db = vl.connect(self.ledger)
        ProofStore(self.store).db.close()                       # the real schema, empty
        self.n = 0

    def note(self, *, account="42", campaign="status-team-review", ids=("r1",), sent="2026-11-01T00:00:00Z",
             status="sent", parent=None, tagged=None) -> int:
        cur = self.db.execute(
            "INSERT INTO verify_messages (campaign, kind, parent_row, user_key, account_id, day, status, message_type, "
            "request_ids_json, n_credits, approved_by, approval_ref, created_at, updated_at, sent_at, proof_tagged_at) "
            "VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
            (campaign, "initial", parent, "u@example.com", account, sent[:10], status, "email", json.dumps(list(ids)),
             len(ids), "U1", "ref", sent, sent, sent, tagged))
        return int(cur.lastrowid)

    def doc(self, *, user=42, at="2026-11-05T10:00:00Z", requests=("r1",)) -> str:
        self.n += 1
        iid = f"{user}:doc{self.n}"
        with sqlite3.connect(self.store) as s:
            s.execute("INSERT INTO proof_intake (intake_id, user_id, subject, candidate_request_ids_json, "
                      "conversation_id, source, file_sha256, received_at, filed_by) VALUES (?,?,?,?,?,?,?,?,?)",
                      (iid, user, "credit", json.dumps(list(requests)), "conv-of-the-document", "intercom",
                       f"sha{self.n}", at, "intake-cron"))
        return iid

    def run_op(self, op: str, *extra: str) -> tuple[int, dict]:
        buf = io.StringIO()
        with redirect_stdout(buf):
            rc = pm.main([op, "--ledger", self.ledger, "--store", self.store, "--kill-file", self.kill, *extra])
        return rc, json.loads(buf.getvalue())

    def row(self, rid: int) -> sqlite3.Row:
        return self.db.execute("SELECT * FROM verify_messages WHERE id=?", (rid,)).fetchone()

    def test_a_document_after_the_note_for_its_request_tags_it_with_the_documents_date(self) -> None:
        rid = self.note()
        self.assertEqual(vl.past_user_done(self.db, "u@example.com", "42"), "")
        self.doc(at="2026-11-07T08:00:00Z")
        first = self.doc(at="2026-11-05T10:00:00Z")
        rc, out = self.run_op("apply")
        self.assertEqual((rc, out["tagged"], out["to_tag:status-team-review"]), (0, 1, 1))
        r = self.row(rid)
        self.assertEqual(r["proof_tagged_at"], "2026-11-05T10:00:00Z")           # the FIRST answer's own date
        # the sweep's fields are not this writer's: the document's conversation is not the note's
        self.assertEqual((r["conversation_id"], r["proof_attachments"], r["proof_checked_at"]), (None, 0, None))
        mark = self.db.execute("SELECT * FROM proof_marks").fetchone()
        self.assertEqual((mark["message_row"], mark["intake_id"], mark["documents"], mark["run_id"], mark["rule"]),
                         (rid, first, 2, out["run_id"], pm.RULE))
        # and every reader that asks "did they answer" now says yes
        self.assertEqual(vl.past_user_done(self.db, "u@example.com", "42"), "proof_received")

    def test_it_is_idempotent(self) -> None:
        self.note()
        self.doc()
        self.assertEqual(self.run_op("apply")[1]["tagged"], 1)
        rc, out = self.run_op("apply")
        self.assertEqual((rc, out["tagged"], out["already_tagged"]), (0, 0, 1))
        self.assertEqual(self.db.execute("SELECT COUNT(*) FROM proof_marks").fetchone()[0], 1)

    def test_an_older_document_never_answers_a_later_note(self) -> None:
        rid = self.note(sent="2026-11-01T00:00:00Z")
        self.doc(at="2026-10-31T23:59:59Z")
        rc, out = self.run_op("apply")
        self.assertEqual((out["tagged"], out["no_document_after"]), (0, 1))
        self.assertIsNone(self.row(rid)["proof_tagged_at"])

    def test_a_document_for_another_request_does_not_answer_a_credit_note(self) -> None:
        rid = self.note(ids=("r1", "r2"))
        self.doc(requests=("r9",))
        self.doc(requests=())
        rc, out = self.run_op("apply")
        self.assertEqual((out["tagged"], out["document_for_another_request"]), (0, 1))
        self.assertIsNone(self.row(rid)["proof_tagged_at"])
        self.doc(requests=("R2",), at="2026-11-09T00:00:00Z")                    # ids compare case-blind
        self.assertEqual(self.run_op("apply")[1]["tagged"], 1)
        self.assertEqual(self.row(rid)["proof_tagged_at"], "2026-11-09T00:00:00Z")

    def test_another_accounts_document_never_tags(self) -> None:
        rid = self.note(account="42")
        self.doc(user=43)
        self.assertEqual(self.run_op("apply")[1]["tagged"], 0)
        self.assertIsNone(self.row(rid)["proof_tagged_at"])

    def test_a_claim_note_is_answered_by_any_document_after_it(self) -> None:
        for campaign in vl.CLAIM_CAMPAIGNS:
            self.note(campaign=campaign, ids=("claim-7",), account="50")
        self.doc(user=50, requests=("some-credit-request",))
        rc, out = self.run_op("apply")
        self.assertEqual(out["tagged"], len(vl.CLAIM_CAMPAIGNS))
        # a claim tag is not a credit answer: the credit readers still exclude it
        self.assertEqual(vl.past_user_done(self.db, "u@example.com", "50"), "")

    def test_only_sent_notes_and_a_note_with_no_account_is_unmeasured(self) -> None:
        held = self.note(status="deferred")
        blind = self.note(account=None)
        self.doc()
        rc, out = self.run_op("apply")
        self.assertEqual((out["tagged"], out["sent"], out["unmeasured"]), (0, 1, 1))
        self.assertIsNone(self.row(held)["proof_tagged_at"])
        self.assertIsNone(self.row(blind)["proof_tagged_at"])

    def test_an_existing_tag_is_never_rewritten(self) -> None:
        rid = self.note(tagged="2026-10-18T00:00:00Z")
        self.doc()
        self.assertEqual(self.run_op("apply")[1]["tagged"], 0)
        self.assertEqual(self.row(rid)["proof_tagged_at"], "2026-10-18T00:00:00Z")

    def test_plan_writes_nothing_and_does_not_create_the_marks_table(self) -> None:
        rid = self.note()
        self.doc()
        rc, out = self.run_op("plan")
        self.assertEqual((rc, out["to_tag"], out.get("tagged")), (0, 1, None))
        self.assertIsNone(self.row(rid)["proof_tagged_at"])
        self.assertIsNone(self.db.execute("SELECT 1 FROM sqlite_master WHERE name='proof_marks'").fetchone())

    def test_a_rejected_review_is_reopened_only_by_a_newer_document(self) -> None:
        rid = self.note()
        old = self.doc(at="2026-11-05T10:00:00Z")
        self.assertEqual(self.run_op("apply")[1]["tagged"], 1)
        vl.finalize(self.db, message_row=rid, status="sent", message_id="m1")
        got = vl.record_proof_review(self.db, message_id="m1", request_ids=["r1"], outcome="rejected",
                                     reviewer="jan", reason="unreadable",
                                     now=datetime(2026, 11, 6, tzinfo=timezone.utc))
        self.assertEqual(got["result"], "ok")
        self.assertIsNone(self.row(rid)["proof_tagged_at"])                      # the review returned it to "no proof"
        rc, out = self.run_op("apply")                                           # the rejected document is still on file
        self.assertEqual((out["tagged"], out["reviewed_already"]), (0, 1))
        self.assertIsNone(self.row(rid)["proof_tagged_at"])
        self.doc(at="2026-11-08T00:00:00Z")                                      # a NEW document
        rc, out = self.run_op("apply")
        self.assertEqual(out["tagged"], 1)
        self.assertEqual(self.row(rid)["proof_tagged_at"], "2026-11-08T00:00:00Z")
        self.assertEqual(self.db.execute("SELECT COUNT(*) FROM verify_proof_reviews").fetchone()[0], 0)
        # undoing that run puts the rejected verdict back
        self.assertEqual(self.run_op("revert", "--run-id", out["run_id"])[1]["reverted"], 1)
        self.assertEqual(self.db.execute("SELECT outcome, reason FROM verify_proof_reviews").fetchone()[:],
                         ("rejected", "unreadable"))
        self.assertNotEqual(old, "")

    def test_revert_clears_only_its_own_untouched_tags_and_stands(self) -> None:
        a, b = self.note(account="42"), self.note(account="43", ids=("r5",))
        self.doc(user=42)
        self.doc(user=43, requests=("r5",))
        rc, out = self.run_op("apply")
        self.assertEqual(out["tagged"], 2)
        self.db.execute("UPDATE verify_messages SET proof_tagged_at='2026-11-12T00:00:00Z' WHERE id=?", (b,))  # a sweep re-tag
        rc, rev = self.run_op("revert", "--run-id", out["run_id"])
        self.assertEqual((rev["reverted"], rev["changed_since"]), (1, 1))
        self.assertIsNone(self.row(a)["proof_tagged_at"])
        self.assertEqual(self.row(b)["proof_tagged_at"], "2026-11-12T00:00:00Z")
        rc, again = self.run_op("apply")                                         # a person's revert is not undone
        self.assertEqual((again["tagged"], again["reverted_stands"]), (0, 1))
        self.assertIsNone(self.row(a)["proof_tagged_at"])

    def test_a_revert_does_not_block_a_later_document_for_the_same_note(self) -> None:
        rid = self.note()
        self.doc(at="2026-11-05T10:00:00Z")
        rc, out = self.run_op("apply")
        self.assertEqual(out["tagged"], 1)
        self.assertEqual(self.run_op("revert", "--run-id", out["run_id"])[1]["reverted"], 1)
        later = self.doc(at="2026-11-10T00:00:00Z")                              # the customer answered again
        rc, again = self.run_op("apply")
        self.assertEqual((again["tagged"], again.get("reverted_stands", 0)), (1, 0))
        self.assertEqual(self.row(rid)["proof_tagged_at"], "2026-11-10T00:00:00Z")
        self.assertEqual(vl.past_user_done(self.db, "u@example.com", "42"), "proof_received")
        mark = self.db.execute("SELECT intake_id, reverted_at FROM proof_marks WHERE message_row=? "
                               "ORDER BY marked_at", (rid,)).fetchall()
        self.assertEqual([(m[0], m[1] is None) for m in mark][-1], (later, True))

    def test_an_unreadable_store_is_an_error_and_writes_nothing(self) -> None:
        rid = self.note()
        for bad in (self.store + ".missing", self.ledger):                       # absent; present with no proof_intake
            buf = io.StringIO()
            with redirect_stdout(buf):
                rc = pm.main(["apply", "--ledger", self.ledger, "--store", bad, "--kill-file", self.kill])
            self.assertEqual(rc, 2)
            self.assertIn("error", json.loads(buf.getvalue()))
        self.assertIsNone(self.row(rid)["proof_tagged_at"])
        buf = io.StringIO()
        with redirect_stdout(buf):                                               # and it never creates a ledger
            self.assertEqual(pm.main(["apply", "--ledger", self.ledger + ".missing", "--store", self.store,
                                      "--kill-file", self.kill]), 2)
        self.assertFalse(Path(self.ledger + ".missing").exists())

    def test_an_undated_document_is_counted_and_never_answers(self) -> None:
        rid = self.note()
        self.doc(at="not a date")
        rc, out = self.run_op("apply")
        self.assertEqual((out["tagged"], out["documents_undated"]), (0, 1))
        self.assertIsNone(self.row(rid)["proof_tagged_at"])

    def test_the_kill_file_stops_it(self) -> None:
        rid = self.note()
        self.doc()
        Path(self.kill).write_text("off")
        rc, out = self.run_op("apply")
        self.assertEqual((rc, out["killed"]), (0, self.kill))
        self.assertIsNone(self.row(rid)["proof_tagged_at"])

    def test_it_adds_nothing_to_the_ledger_schema_readers_check(self) -> None:
        # a table in verify_ledger.SCHEMA makes every read-only reader refuse until a writer migrates the ledger
        self.assertNotIn("proof_marks", vl.SCHEMA)
        self.note()
        self.doc()
        self.run_op("apply")
        vl.connect_ro(self.ledger, must_exist=True).close()                      # still opens read-only

    def test_a_run_opens_no_connection_and_writes_no_conversation(self) -> None:
        rid = self.note()
        self.doc()

        def counts() -> dict[str, int]:
            names = [r[0] for r in self.db.execute("SELECT name FROM sqlite_master WHERE type='table'")]
            return {n: self.db.execute(f"SELECT COUNT(*) FROM {n}").fetchone()[0] for n in names}
        before = counts()

        def refuse(*a, **k):
            raise AssertionError("the marker reached out of the process")
        with mock.patch.object(socket.socket, "connect", refuse), \
                mock.patch.object(socket, "create_connection", refuse), \
                mock.patch.object(subprocess, "run", refuse), \
                mock.patch.object(subprocess, "Popen", refuse):
            rc, out = self.run_op("apply")
        self.assertEqual((rc, out["tagged"]), (0, 1))
        after = counts()
        self.assertEqual({n: after.get(n, 0) - before.get(n, 0) for n in set(before) | set(after)
                          if after.get(n, 0) != before.get(n, 0)}, {"proof_marks": 1})
        r = self.row(rid)
        self.assertEqual((r["conversation_id"], r["proof_attachments"], r["proof_checked_at"]), (None, 0, None))

    def test_the_cron_runs_it_hourly_and_names_its_kill_file(self) -> None:
        jobs = {j["name"]: j for j in json.loads((ROOT / "cron-jobs.json").read_text())["jobs"]}
        job = jobs["credit-proof-marker"]
        self.assertEqual(job["payload"]["argv"],
                         ["python3", "/opt/hydra/scripts/credit_review/proof_marker.py", "apply"])
        self.assertEqual((job["payload"]["kind"], job["sessionTarget"], job["delivery"]["mode"]),
                         ("command", "isolated", "none"))
        self.assertIn(pm.KILL, job["description"])


if __name__ == "__main__":
    unittest.main()
