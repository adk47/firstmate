"""The proof reviewer (credit_review/proof_reviewer.py): the AI writer of `verify_proof_reviews`.

Pins what the captain ruled on 2026-11-13 ("never should we ever use a person to evaluate this"): a tagged proof
gets a verdict with no person involved; accepted clears the credit from removal-due; rejected carries a specific
ask and never leaks the internal reason; a credit our reader has not answered for gets no verdict at all, at any
age; and no tagged credit is left with no AI writer able to rule on it."""
from __future__ import annotations

import credit_test_env  # noqa: F401 - first: test logs never reach the production run.log
import io
import json
import os
import re
import shutil
import signal
import sqlite3
import subprocess
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from datetime import datetime, timedelta, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
from credit_review import proof_reviewer as pr  # noqa: E402
from credit_review import verify_ledger as vl  # noqa: E402
from credit_verify.docverify.store import DocVerifyStore  # noqa: E402
from credit_verify.proof.store import ProofStore  # noqa: E402

#: the sentence the send gate's own ruled copy carries for each sendable need (the ask the reviewer records)
GATE_COPY = {
    pr.NEED_READABLE: "the same document as a PDF or a clear photo of the whole page",
    pr.NEED_COUNTERPARTY: "a split sheet or agreement signed by the artist or label",
    pr.NEED_DASHBOARD: "type this code in the find box: MUSO-7K2Q",
}

NOW = datetime(2026, 11, 13, 12, 0, tzinfo=timezone.utc)
OLD = "2026-11-01T10:00:00Z"            # a document filed well before NOW
NEW = "2026-11-13T09:00:00Z"            # a document filed just before NOW
MODEL = "deepseek/deepseek-v4.1-flash-1017"
NOT_NAMED = "the document itself does not name the claimant in this role on this track"
A, B, C, D = (f"{c * 8}-0000-4000-8000-000000000000" for c in "abcd")


class ProofReviewerTest(unittest.TestCase):
    def setUp(self) -> None:
        d = Path(tempfile.mkdtemp())
        self.ledger, self.store, self.kill = str(d / "ledger.sqlite3"), str(d / "proof.sqlite"), str(d / "kill")
        self.dv_path = str(d / "doc-verify.sqlite")
        self.waiting = str(d / "proof-reader-waiting.json")
        self.db = vl.connect(self.ledger)
        ProofStore(self.store).db.close()                       # the real schemas, empty
        self.dv = DocVerifyStore(self.dv_path)
        self.n = 0

    # ---- fixtures -------------------------------------------------------------------------------------------
    def note(self, *, account="42", campaign="verify-live", ids=(A,), tagged=OLD, message_id="auto",
             removal_day="2026-11-10", parent=None, kind="initial") -> int:
        self.n += 1
        mid = f"m{self.n}" if message_id == "auto" else message_id
        cur = self.db.execute(
            "INSERT INTO verify_messages (campaign, kind, parent_row, user_key, account_id, day, due_day, removal_day, "
            "status, message_type, message_id, request_ids_json, n_credits, approved_by, approval_ref, created_at, "
            "updated_at, sent_at, proof_tagged_at) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
            (campaign, kind, parent, "u@example.com", account, "2026-10-10", "2026-11-09", removal_day, "sent",
             "email", mid, json.dumps(list(ids)), len(ids), "U1", "ref", "2026-10-10T00:00:00Z",
             "2026-10-10T00:00:00Z", "2026-10-10T00:00:00Z", tagged))
        return int(cur.lastrowid)

    def doc(self, *, user=42, at=OLD, requests=(A,)) -> str:
        self.n += 1
        sha = f"sha{self.n}"
        with sqlite3.connect(self.store) as s:
            s.execute("INSERT INTO proof_intake (intake_id, user_id, subject, candidate_request_ids_json, "
                      "conversation_id, source, file_sha256, received_at, filed_by) VALUES (?,?,?,?,?,?,?,?,?)",
                      (f"{user}:{sha}", user, "credit", json.dumps(list(requests)), "conv", "intercom", sha, at,
                       "intake-cron"))
        return sha

    def read(self, sha: str, *, request=A, role="Producer", outcome="unverifiable", reason=NOT_NAMED,
             need: str | None = pr.NEED_COUNTERPARTY, user: int | None = 42, hold=False, model: str | None = MODEL) -> None:
        self.keyed(sha, request=request, roles=(role,))
        self.dv.outcome("run1", proof_id=sha, request_id=request, role=role, user_id=user, source_ref=None,
                        h3_verdict="GENUINE", outcome=outcome, reason=reason, need=need, account_hold=hold, detail={})
        if model:
            self.dv.llm_call({"proof_id": sha, "model": model, "outcome": "ok"})

    def intake_of(self, sha: str) -> tuple[str, list[str]]:
        with sqlite3.connect(self.store) as s:
            iid, candidates = s.execute("SELECT intake_id, candidate_request_ids_json FROM proof_intake "
                                        "WHERE file_sha256=?", (sha,)).fetchone()
        return str(iid), json.loads(candidates)

    def keyed(self, sha: str, *, request=A, roles=None) -> None:
        """Record, as doc-verify's keying pass does, roles the filing committed to read for a request."""
        iid, candidates = self.intake_of(sha)
        rec = self.dv.intake_keys_recorded(iid) or {"candidates": candidates, "keys": []}
        keys = list(dict.fromkeys([*rec["keys"], *[f"{request}#{r}" for r in (roles or ("Producer",))]]))
        self.dv.record_intake_keys(iid, candidates, keys)

    def cut(self, sha: str, *, request=A, roles=None) -> None:
        """Record, as doc-verify's fan-out cut does, the claim keys the document does not name."""
        iid, _ = self.intake_of(sha)
        self.keyed(sha, request=request, roles=roles or ("Producer",))
        self.dv.record_intake_unmatched(iid, [f"{request}#{r}" for r in (roles or ("Producer",))])

    def step_raw(self, sha: str, detail: dict, status: str = "ok") -> None:
        iid, _ = self.intake_of(sha)
        self.dv.step("run1", sha, "intake_keys", status, detail, request_id=f"intake:{iid}")

    def step_keyed(self, sha: str, *, keys) -> None:
        """A filing whose run wrote only its dv_steps row: no dv_intake_keys row, in the shape the runner writes."""
        keys = list(keys)
        self.step_raw(sha, {"candidates": len(keys), "keys": len(keys), "first_keys": keys[:20],
                            "bytes": "stored"})

    def run_op(self, op: str, *extra: str, now: datetime = NOW) -> tuple[int, dict]:
        buf = io.StringIO()
        real = pr.datetime
        pr.datetime = type("Clock", (real,), {"now": classmethod(lambda cls, tz=None: now)})
        try:
            with redirect_stdout(buf):
                rc = pr.main([op, "--ledger", self.ledger, "--dv-store", self.dv_path, "--store", self.store,
                              "--kill-file", self.kill, "--waiting-file", self.waiting, *extra])
        finally:
            pr.datetime = real
        return rc, json.loads(buf.getvalue())

    def review(self, request=A) -> sqlite3.Row | None:
        return self.db.execute("SELECT * FROM verify_proof_reviews WHERE request_id=?", (request,)).fetchone()

    def decision(self, request=A) -> sqlite3.Row | None:
        return self.db.execute("SELECT * FROM proof_review_decisions WHERE request_id=? ORDER BY id DESC",
                               (request,)).fetchone()

    def tag_of(self, row: int) -> str | None:
        return self.db.execute("SELECT proof_tagged_at FROM verify_messages WHERE id=?", (row,)).fetchone()[0]

    def killed_apply(self, after: str) -> int:
        """Run `apply` in its own process and SIGKILL that process the moment `verify_ledger.<after>` returns.

        The kill is the operating system's, on the real entry point: nothing gets to roll back, close or flush.
        Returns the child's exit status (-SIGKILL when the kill landed where it was aimed)."""
        child = (
            "import os, signal, sys\n"
            "from datetime import datetime\n"
            f"sys.path.insert(0, {str(ROOT / 'scripts')!r})\n"
            "from credit_review import proof_reviewer as pr\n"
            "from credit_review import verify_ledger as vl\n"
            f"now = datetime.fromisoformat({NOW.isoformat()!r})\n"
            "pr.datetime = type('Clock', (pr.datetime,), {'now': classmethod(lambda cls, tz=None: now)})\n"
            f"real = getattr(vl, {after!r})\n"
            "def then_die(*a, **k):\n"
            "    real(*a, **k)\n"
            "    os.kill(os.getpid(), signal.SIGKILL)\n"
            f"setattr(vl, {after!r}, then_die)\n"
            "raise SystemExit(pr.main(sys.argv[1:]))\n")
        r = subprocess.run([sys.executable, "-c", child, "apply", "--ledger", self.ledger, "--dv-store", self.dv_path,
                            "--store", self.store, "--kill-file", self.kill, "--waiting-file", self.waiting],
                           capture_output=True, text=True, timeout=120, check=False)
        return r.returncode

    def gate_render(self, need: str) -> tuple[int, str]:
        """Run the real send gate (a TESTABLE copy, in a temp dir) for one need code and return (rc, stdout).

        This is the path the reviewer's `ask_route` names: `intercom-verify-request.sh --campaign proof-need-ask
        --dry-run`. Hermetic: the gate's own test seams keep it off the network and its ledger in the temp dir."""
        import subprocess  # noqa: PLC0415

        d = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, d, True)
        gate = d / "gate.sh"
        gate.write_text((ROOT / "scripts/intercom-verify-request.sh").read_text()
                        .replace("readonly TESTABLE=0", "readonly TESTABLE=1"))
        body = {"code": need, "doc_sha": "a" * 64, "doc_received_at": "2026-10-18T09:30:00Z", "doc_kind": "image",
                "doc_count": 1, "doc_shas": ["a" * 64]}
        if need == pr.NEED_DASHBOARD:
            body["verify_code"] = "MUSO-7K2Q"
        payload = {"user": {"email": "Jane.Doe@Example.com", "id": "42", "first_name": "Jane",
                            "professional_id": "9b2f6c1e-4d3a-4e8b-a1c7-5f0e2d8b3a64",
                            "auth_id": "auth0|9b2f6c1e-4d3a-4e8b-a1c7-5f0e2d8b3a64"},
                   "credits": [{"request_id": "r1", "role": "Mixing", "track_title": "Song A",
                                "artist_name": "Big Star", "profile_id": "p1", "track_id": "t1"}],
                   "need": body}
        credits = d / "n.json"
        credits.write_text(json.dumps(payload))
        env = {**os.environ, "MUSOAI_INTERCOM_TOKEN": "test-token", "INTERCOM_VERIFY_TEST_DAY": "2026-10-15",
               "INTERCOM_VERIFY_TEST_LOG_DIR": str(d / "api-logs"),
               "INTERCOM_VERIFY_TEST_LEDGER": str(d / "ledger.sqlite3"),
               "INTERCOM_VERIFY_TEST_PROOF_DB": str(d / "proof.sqlite"),
               "INTERCOM_VERIFY_TEST_LEDGER_HELPER": str(ROOT / "scripts/credit_review/verify_ledger.py"),
               "INTERCOM_VERIFY_TEST_JQ_LIB": str(ROOT / "scripts/lib"),
               "INTERCOM_VERIFY_TEST_API_RETRY_SLEEPS": "0 0"}
        r = subprocess.run(["bash", str(gate), "send", "--campaign", "proof-need-ask", "--credits-file", str(credits),
                            "--approved-by", "U7RP6HKUZ", "--dry-run"],
                           env=env, capture_output=True, text=True, timeout=300)
        return r.returncode, r.stdout + r.stderr

    def due(self) -> list[str]:
        return [r["request_id"] for r in vl.removal_due(self.db, day="2026-11-13")]

    def held(self) -> dict[str, str]:
        return {r["request_id"]: r["reason"] for r in vl.held_for_human(self.db, day="2026-11-13")}

    # ---- the acceptance: a tagged proof gets an AI verdict with no person involved ----------------------------
    def test_a_verified_document_is_accepted_by_the_ai_and_the_credit_is_never_removal_due(self) -> None:
        self.note()
        self.read(self.doc(), outcome="verified", reason="independently confirmed by xc_dsp", need=None)
        self.assertEqual(self.held(), {A: vl.HELD_AWAITING_REVIEW})          # before: held while it awaits review
        rc, out = self.run_op("apply")
        self.assertEqual(rc, 0)
        self.assertEqual(out["recorded"], 1)
        row = self.review()
        self.assertEqual(row["outcome"], "accepted")
        self.assertIsNone(row["reason"])
        self.assertEqual(row["reviewed_by"], f"ai:proof-reviewer/{pr.RULE} doc-verify/{pr.DV_VERSION} model={MODEL}")
        self.assertEqual(self.due(), [])
        self.assertEqual(self.held(), {})
        d = self.decision()
        self.assertEqual(d["outcome"], "accepted")
        self.assertIsNone(d["ask_need"])
        self.assertEqual(d["result"], "ok")

    def test_a_rejection_carries_a_specific_ask_built_from_the_failing_gate(self) -> None:
        nid = self.note()
        self.read(self.doc())
        rc, out = self.run_op("apply")
        self.assertEqual(rc, 0)
        self.assertEqual(out["rejected"], 1)
        self.assertEqual(out["ask:" + pr.NEED_COUNTERPARTY], 1)
        self.assertEqual(out["ask_route:" + pr.ROUTE_ASK], 1)
        row = self.review()
        self.assertEqual(row["outcome"], "rejected")
        self.assertEqual(row["reason"], "doesnt_name_you")
        self.assertEqual(row["document"], 1)
        self.assertTrue(row["reviewed_by"].startswith("ai:proof-reviewer/"))
        d = self.decision()
        self.assertEqual(d["ask_need"], pr.NEED_COUNTERPARTY)
        self.assertEqual(d["ask"], pr.ASK_LINES[pr.NEED_COUNTERPARTY])
        self.assertIn("split sheet or agreement signed by the artist or label", d["ask"])
        self.assertEqual(d["ask_route"], pr.ROUTE_ASK)
        self.assertEqual(d["dv_reason"], NOT_NAMED)                          # internal, on the audit row only
        # decided, not parked: the note is back to "no proof" and nothing awaits a review
        self.assertIsNone(self.db.execute("SELECT proof_tagged_at FROM verify_messages WHERE id=?", (nid,)).fetchone()[0])
        self.assertNotIn(vl.HELD_AWAITING_REVIEW, self.held().values())
        # and the credit is never removed on a verdict the customer has not been told about
        self.assertEqual(self.due(), [])

    def test_the_ask_follows_the_gate_that_failed(self) -> None:
        cases = [("claims not extracted (degraded)", pr.NEED_READABLE, "unreadable", pr.NEED_READABLE),
                 ("not a document of record (dashboard_screenshot): a catalog/DSP panel", pr.NEED_DASHBOARD,
                  "not_a_document", pr.NEED_DASHBOARD),
                 ("the document credits the claimant on other tracks (X), not on this one", pr.NEED_COUNTERPARTY,
                  "other_track", pr.NEED_COUNTERPARTY),
                 ("no independent source confirms the credit", pr.NEED_COUNTERPARTY, "not_a_document",
                  pr.NEED_COUNTERPARTY)]
        for why, need, reason, ask in cases:
            with self.subTest(why=why):
                v = pr.judge(A, "42", pr.Evidence(rows={A: [
                    {"id": 1, "proof_id": "s", "role": "Producer", "user_id": 42, "outcome": "unverifiable",
                     "reason": why, "need": need, "account_hold": 0}]}), now=NOW)
                self.assertEqual(v.outcome, "rejected")
                self.assertEqual(v.reason, reason)
                self.assertEqual(v.ask_need, ask)
                self.assertEqual(v.ask_route, pr.ROUTE_ASK)

    def test_nothing_that_can_reach_a_customer_carries_the_internal_reason(self) -> None:
        self.note()
        self.read(self.doc())
        rc, out = self.run_op("plan", "--list")
        self.assertEqual(rc, 0)
        listed = json.dumps(out)
        for code in vl.REJECTION_REASONS:
            with self.subTest(code=code):
                self.assertNotIn(code, json.dumps(out["verdicts"]))
                for line in pr.ASK_LINES.values():
                    self.assertNotIn(code, line)
        self.assertNotIn(NOT_NAMED, listed)
        self.assertNotIn("does not name", listed)
        v = pr.judge(A, "42", pr.read_evidence(self.dv_path, self.store), now=NOW)
        self.assertEqual(sorted(v.public()), ["ask", "ask_need", "ask_route", "outcome"])
        self.assertEqual(out["verdicts"], [{"request_id": A, **v.public()}])

    def test_every_ask_is_a_need_the_send_gate_renders_and_the_reviewed_path_sends(self) -> None:
        from credit_review import need_asks
        ev = pr.Evidence(rows={A: [{"id": 1, "proof_id": "s", "role": "Producer", "user_id": 42,
                                    "outcome": "unverifiable", "reason": "x", "need": need, "account_hold": 0}
                               for need in pr.SENDABLE]})
        for need in pr.SENDABLE:
            with self.subTest(need=need):
                one = pr.Evidence(rows={A: [r for r in ev.rows[A] if r["need"] == need]})
                v = pr.judge(A, "42", one, now=NOW)
                self.assertEqual(v.ask_need, need)
                self.assertEqual(v.ask, pr.ASK_LINES[need])
                self.assertEqual(v.ask_route, pr.ROUTE_ASK)
                self.assertIn(need, pr.ASK_NEEDS)
        self.assertEqual(tuple(pr.SENDABLE), tuple(need_asks.SENDABLE))
        self.assertEqual(pr.ROUTE_ASK, need_asks.CAMPAIGN)
        for need in pr.SENDABLE:
            with self.subTest(gate=need):
                rc, out = self.gate_render(need)
                self.assertEqual(rc, 0, out[-400:])
                self.assertIn("DRY-RUN proof-need-ask", out)
                self.assertIn(GATE_COPY[need], out)

    def test_a_contradicted_read_is_a_specific_ask_and_the_account_hold(self) -> None:
        self.note()
        self.read(self.doc(), outcome="contradicted", reason="spotify and tidal contradict it", need=None)
        rc, out = self.run_op("plan")
        self.assertEqual(rc, 0)
        self.assertEqual(out["reason:doesnt_name_you"], 1)
        v = pr.judge(A, "42", pr.read_evidence(self.dv_path, self.store), now=NOW)
        self.assertEqual(v.outcome, "rejected")
        self.assertEqual(v.ask_route, pr.BLOCKED_HOLD)
        self.assertEqual(v.ask_need, "")
        self.assertEqual(v.ask, "")

    # ---- our reader owns an unread document, with no clock on it ------------------------------------------------
    def test_a_read_that_came_back_unknown_gets_no_verdict_at_any_age(self) -> None:
        self.note()
        sha = self.doc(at=OLD)
        self.read(sha, outcome="unknown", reason="tooling: provider down", need=None)
        rc, out = self.run_op("apply")
        self.assertEqual(rc, 0)
        self.assertEqual(out["wait_reader"], 1)
        self.assertNotIn("recorded", out)
        self.assertIsNone(self.review())
        self.assertIsNone(self.decision())
        self.assertEqual(self.held(), {A: vl.HELD_AWAITING_REVIEW})
        self.assertEqual(self.due(), [])
        rc, out = self.run_op("apply", now=NOW + timedelta(days=60))
        self.assertEqual(rc, 0)
        self.assertEqual(out["wait_reader"], 1)
        self.assertIsNone(self.review())
        self.assertEqual(self.due(), [])
        self.read(sha, outcome="verified", reason="independently confirmed", need=None)
        rc, out = self.run_op("apply", now=NOW + timedelta(days=61))
        self.assertEqual(rc, 0)
        self.assertEqual(out["accepted"], 1)
        self.assertEqual(self.review()["outcome"], "accepted")
        self.assertEqual(self.due(), [])
        self.assertEqual(self.held(), {})

    def test_a_tagged_credit_nothing_was_read_for_gets_no_verdict(self) -> None:
        self.note()                                             # tagged, and nothing on file anywhere
        rc, out = self.run_op("apply")
        self.assertEqual(rc, 0)
        self.assertEqual(out["wait_reader"], 1)
        self.assertNotIn("recorded", out)
        self.assertIsNone(self.review())
        self.assertIsNone(self.decision())
        self.assertEqual(self.held(), {A: vl.HELD_AWAITING_REVIEW})
        self.assertEqual(self.due(), [])

    def test_a_document_read_and_recorded_as_unreadable_still_rejects(self) -> None:
        self.note()
        self.read(self.doc(), need=pr.NEED_READABLE, reason="claims not extracted (degraded photo)")
        rc, out = self.run_op("apply")
        self.assertEqual(rc, 0)
        self.assertEqual(out["reason:unreadable"], 1)
        self.assertEqual(out["ask:" + pr.NEED_READABLE], 1)
        self.assertEqual(self.review()["outcome"], "rejected")
        self.assertEqual(self.review()["reason"], "unreadable")
        self.assertEqual(self.decision()["ask_need"], pr.NEED_READABLE)
        self.assertIsNone(self.db.execute("SELECT proof_tagged_at FROM verify_messages").fetchone()[0])

    def test_a_mixed_note_writes_the_accepted_credit_listed_after_the_rejected_one(self) -> None:
        self.note(ids=(A, B))                                   # the failing credit is listed first
        sha = self.doc(requests=(A, B))
        self.read(sha, request=A)
        self.read(sha, request=B, outcome="verified", reason="independently confirmed", need=None)
        rc, out = self.run_op("apply")
        self.assertEqual(rc, 0)
        self.assertEqual(out["recorded"], 2)
        self.assertEqual(out["record:ok"], 2)
        self.assertEqual(self.review(A)["outcome"], "rejected")
        self.assertEqual(self.review(B)["outcome"], "accepted")
        rows = "SELECT COUNT(*) FROM proof_review_decisions WHERE request_id=?"
        self.assertEqual(self.db.execute(rows, (B,)).fetchone()[0], 1)
        rc, out = self.run_op("apply", now=NOW + timedelta(hours=1))
        self.assertEqual(rc, 0)
        self.assertNotIn("recorded", out)
        self.assertEqual(self.db.execute(rows, (B,)).fetchone()[0], 1)

    def test_a_mixed_note_writes_the_accepted_credit_listed_before_the_rejected_one(self) -> None:
        self.note(ids=(B, A))                                   # the verified credit is listed first
        sha = self.doc(requests=(A, B))
        self.read(sha, request=A)
        self.read(sha, request=B, outcome="verified", reason="independently confirmed", need=None)
        rc, out = self.run_op("apply")
        self.assertEqual(rc, 0)
        self.assertEqual(out["record:ok"], 2)
        self.assertEqual(self.review(A)["outcome"], "rejected")
        self.assertEqual(self.review(B)["outcome"], "accepted")
        self.assertEqual(self.db.execute(
            "SELECT COUNT(*) FROM verify_proof_reviews WHERE request_id=?", (B,)).fetchone()[0], 1)

    def test_a_credit_waiting_on_the_reader_is_counted_with_its_age_and_writes_no_verdict(self) -> None:
        self.note(tagged=OLD)
        self.doc(at=OLD)                                        # filed; our reader has not answered it yet
        rc, out = self.run_op("apply")
        self.assertEqual(rc, 0)
        self.assertEqual(out["wait_reader"], 1)
        self.assertEqual(out["wait_reader_oldest_days"], 12)
        self.assertEqual(self.db.execute("SELECT COUNT(*) FROM verify_proof_reviews").fetchone()[0], 0)
        self.assertIsNone(self.decision())
        with open(self.waiting) as fh:
            reported = json.load(fh)
        self.assertEqual(reported["wait_reader"], 1)
        self.assertEqual(reported["oldest_days"], 12)
        self.assertEqual(reported["at"], "2026-11-13T12:00:00Z")

    def test_a_note_whose_sibling_credit_is_still_unread_keeps_its_tag_and_charges_nobody(self) -> None:
        nid = self.note(ids=(A, B))
        self.read(self.doc(requests=(A,)))                       # A read; B's own document is still unread
        self.doc(requests=(B,))
        rc, out = self.run_op("apply")
        self.assertEqual(rc, 0)
        self.assertEqual(out["recorded"], 1)
        self.assertIsNotNone(self.db.execute(
            "SELECT proof_tagged_at FROM verify_messages WHERE id=?", (nid,)).fetchone()[0])
        self.assertEqual(self.held()[B], vl.HELD_AWAITING_REVIEW)      # still our reader's, never removal-due
        self.assertNotIn(A, self.due())
        self.assertEqual(self.due(), [])

    def test_an_unread_document_waits_for_the_ai_reader_however_long_it_takes(self) -> None:
        self.note(tagged=NEW)
        sha = self.doc(at=NEW)                                  # filed, doc-verify has not read it yet
        rc, out = self.run_op("apply")
        self.assertEqual(rc, 0)
        self.assertEqual(out["wait_reader"], 1)
        self.assertNotIn("recorded", out)
        self.assertIsNone(self.review())
        rc, out = self.run_op("apply", now=NOW + timedelta(days=60))
        self.assertEqual(rc, 0)
        self.assertEqual(out["wait_reader"], 1)
        self.assertNotIn("recorded", out)
        self.assertIsNone(self.review())
        self.assertEqual(self.held(), {A: vl.HELD_AWAITING_REVIEW})
        self.assertEqual(self.due(), [])
        self.read(sha)                                          # the reader answers: the credit is decided
        rc, out = self.run_op("apply", now=NOW + timedelta(days=61))
        self.assertEqual(rc, 0)
        self.assertEqual(out["recorded"], 1)
        self.assertEqual(self.review()["outcome"], "rejected")

    def test_a_new_document_after_a_rejection_is_read_before_the_credit_is_ruled_on_again(self) -> None:
        self.note(message_id="m-resubmit")
        self.read(self.doc(at=OLD))
        self.run_op("apply")
        self.assertEqual(self.review()["outcome"], "rejected")
        self.doc(at=NEW)                                        # the resubmission, not read yet
        vl.mark_tagged(self.db, message_id="m-resubmit", conversation_id="c1", attachments=1, now=NOW)
        self.assertIsNone(self.review())                        # the tag put the credit back under review
        rc, out = self.run_op("apply")
        self.assertEqual(out["wait_reader"], 1)                 # never re-rejected on the old read
        self.assertIsNone(self.review())

    # ---- the verdicts' edges ----------------------------------------------------------------------------------
    def test_one_proven_role_of_two_is_a_rejection_for_the_other_role(self) -> None:
        self.note()
        sha = self.doc()
        self.read(sha, role="Producer", outcome="verified", reason="independently confirmed", need=None)
        self.read(sha, role="Composer")
        self.run_op("apply")
        self.assertEqual(self.review()["outcome"], "rejected")
        self.assertEqual(self.review()["reason"], "other_role")
        self.assertEqual(self.decision()["ask_need"], pr.NEED_COUNTERPARTY)

    def test_a_role_the_filing_claims_and_the_reader_never_recorded_waits_instead_of_accepting(self) -> None:
        self.note()
        sha = self.doc()
        self.keyed(sha, roles=("Producer", "Composer"))          # the filing claims both; the cap kept one key
        self.read(sha, role="Producer", outcome="verified", reason="independently confirmed", need=None)
        rc, out = self.run_op("apply")
        self.assertEqual(rc, 0)
        self.assertEqual(out["wait_reader"], 1)
        self.assertEqual(out.get("accepted", 0), 0)
        self.assertIsNone(self.review())

    def test_a_request_all_of_whose_claims_the_cap_dropped_waits_instead_of_being_denied(self) -> None:
        self.note(ids=(A, B))
        sha = self.doc(requests=(A, B))
        self.read(sha, request=A, outcome="verified", reason="independently confirmed", need=None)
        self.keyed(sha, request=B, roles=("Producer",))          # B's key was cut by the per-run claim cap
        rc, out = self.run_op("apply")
        self.assertEqual(rc, 0)
        self.assertEqual(out["accepted"], 1)
        self.assertEqual(out["wait_reader"], 1)
        self.assertIsNone(self.review(B))
        self.assertNotIn(B, self.due())

    def test_a_claim_the_fanout_cut_marked_not_matched_is_a_read_filing_with_no_claim(self) -> None:
        self.note(ids=(A, B))
        sha = self.doc(requests=(A, B))
        self.read(sha, request=A, outcome="verified", reason="independently confirmed", need=None)
        self.cut(sha, request=B, roles=("Composer",))           # doc-verify finished: the document does not name B
        rc, out = self.run_op("apply")
        self.assertEqual(rc, 0)
        self.assertEqual(self.review(B)["reason"], "other_track")
        self.assertEqual(self.decision(B)["ask_route"], pr.BLOCKED_NO_READ)
        self.assertIsNone(self.decision(B)["ask_need"])

    def test_a_filing_the_cut_matched_nothing_on_is_not_left_waiting_forever(self) -> None:
        self.note(ids=(A,))
        sha = self.doc(requests=(A,))
        self.cut(sha, request=A, roles=("Producer",))           # no outcome row at all: the cut finished the filing
        rc, out = self.run_op("apply")
        self.assertEqual(rc, 0)
        self.assertEqual(out.get("wait_reader", 0), 0)
        self.assertEqual(self.review()["reason"], "other_track")

    def test_every_role_the_filing_claims_verified_is_accepted(self) -> None:
        self.note()
        sha = self.doc()
        self.keyed(sha, roles=("Producer", "Composer"))
        self.read(sha, role="Producer", outcome="verified", reason="independently confirmed", need=None)
        self.read(sha, role="Composer", outcome="verified", reason="independently confirmed", need=None)
        rc, out = self.run_op("apply")
        self.assertEqual(rc, 0)
        self.assertEqual(out["accepted"], 1)
        self.assertEqual(self.review()["outcome"], "accepted")

    def test_an_account_less_note_waits_while_a_document_for_the_credit_is_unread(self) -> None:
        row = self.note(account=None)
        self.read(self.doc(at=OLD))
        self.keyed(self.doc(at=NEW))
        rc, out = self.run_op("apply")
        self.assertEqual(rc, 0)
        self.assertEqual(out["wait_reader"], 1)
        self.assertIsNone(self.review())
        self.assertEqual(self.tag_of(row), OLD)

    def test_a_credit_two_accounts_filed_on_and_a_note_with_no_account_gets_no_verdict(self) -> None:
        self.note(account=None)
        self.read(self.doc(user=42))
        self.read(self.doc(user=43), user=43)
        rc, out = self.run_op("apply")
        self.assertEqual(rc, 0)
        self.assertEqual(out["wait_reader"], 1)
        self.assertIsNone(self.review())

    def test_a_filing_keyed_only_in_its_step_is_judged_on_those_keys(self) -> None:
        self.note()
        sha = self.doc()
        self.step_keyed(sha, keys=(f"{A}#Producer",))
        self.dv.outcome("run1", proof_id=sha, request_id=A, role="Producer", user_id=42, source_ref=None,
                        h3_verdict="GENUINE", outcome="verified", reason="independently confirmed", need=None,
                        account_hold=False, detail={})
        rc, out = self.run_op("apply")
        self.assertEqual(rc, 0)
        self.assertEqual(out["accepted"], 1)
        self.assertEqual(self.review()["outcome"], "accepted")

    def test_a_step_whose_keys_were_cut_at_twenty_gets_no_verdict(self) -> None:
        row = self.note()
        sha = self.doc()
        self.step_raw(sha, {"candidates": 25, "keys": 25, "first_keys": [f"{A}#Producer"] * 20})
        rc, out = self.run_op("apply")
        self.assertEqual(rc, 0)
        self.assertEqual(out["wait_reader"], 1)
        self.assertIsNone(self.review())
        self.assertEqual(self.tag_of(row), OLD)

    def test_a_step_that_recorded_a_keying_error_gets_no_verdict(self) -> None:
        row = self.note()
        sha = self.doc()
        self.step_raw(sha, {"error": "ProviderDown: sendgrid"}, status="error")
        rc, out = self.run_op("apply")
        self.assertEqual(rc, 0)
        self.assertEqual(out["wait_reader"], 1)
        self.assertIsNone(self.review())
        self.assertEqual(self.tag_of(row), OLD)

    def test_a_step_written_before_a_failed_rekeying_does_not_supply_the_keys(self) -> None:
        row = self.note()
        sha = self.doc()
        self.step_keyed(sha, keys=(f"{A}#Producer",))
        self.step_raw(sha, {"error": "ProviderDown: sendgrid"}, status="error")
        self.dv.outcome("run1", proof_id=sha, request_id=A, role="Producer", user_id=42, source_ref=None,
                        h3_verdict="GENUINE", outcome="verified", reason="independently confirmed", need=None,
                        account_hold=False, detail={})
        rc, out = self.run_op("apply")
        self.assertEqual(rc, 0)
        self.assertEqual(out["wait_reader"], 1)
        self.assertIsNone(self.review())
        self.assertEqual(self.tag_of(row), OLD)

    def test_two_tagged_notes_are_planned_on_their_own_credits(self) -> None:
        one = self.note(ids=(A,), message_id="m-one")
        two = self.note(ids=(B,), message_id="m-two", tagged=NEW)
        self.read(self.doc(requests=(A,)), request=A, outcome="verified", reason="independently confirmed",
                  need=None)
        self.read(self.doc(requests=(B,)), request=B, outcome="verified", reason="independently confirmed",
                  need=None)
        rc, out = self.run_op("apply")
        self.assertEqual(rc, 0)
        self.assertEqual(out["accepted"], 2)
        self.assertEqual(out["notes_under_review"], 2)
        self.assertEqual(self.review(A)["family"], one)
        self.assertEqual(self.review(B)["family"], two)

    def test_a_note_whose_credits_are_all_reviewed_costs_no_per_credit_note_scan(self) -> None:
        self.note()
        self.read(self.doc(), outcome="verified", reason="independently confirmed", need=None)
        self.assertEqual(self.run_op("apply")[0], 0)
        asked: list[str] = []
        real = vl._note_of

        def counting(db: sqlite3.Connection, request_id: str) -> int | None:
            asked.append(str(request_id))
            return real(db, request_id)

        vl._note_of = counting
        try:
            rc, out = self.run_op("apply", now=NOW + timedelta(hours=1))
        finally:
            vl._note_of = real
        self.assertEqual(rc, 0)
        self.assertEqual(out["already_ruled"], 1)
        self.assertEqual(asked, [])

    def test_a_verified_read_stands_when_a_later_document_for_the_same_role_is_unverifiable(self) -> None:
        self.note()
        self.read(self.doc(at=OLD), outcome="verified", reason="independently confirmed", need=None)
        self.read(self.doc(at=NEW))                             # same role, a second document that proves nothing
        rc, out = self.run_op("apply")
        self.assertEqual(rc, 0)
        self.assertEqual(out["accepted"], 1)
        self.assertNotIn("rejected", out)
        self.assertEqual(self.review()["outcome"], "accepted")
        self.assertIsNone(self.review()["reason"])
        self.assertIsNone(self.decision()["ask_need"])
        self.assertEqual(self.due(), [])
        self.assertEqual(self.held(), {})

    def test_a_resubmission_that_verifies_is_accepted_over_the_first_document_that_did_not(self) -> None:
        self.note()
        self.read(self.doc(at=OLD))                             # the first document proved nothing
        self.read(self.doc(at=NEW), outcome="verified", reason="independently confirmed", need=None)
        rc, out = self.run_op("apply")
        self.assertEqual(rc, 0)
        self.assertEqual(out["accepted"], 1)
        self.assertNotIn("rejected", out)
        self.assertEqual(self.review()["outcome"], "accepted")
        self.assertEqual(self.due(), [])

    def test_a_verified_role_never_carries_another_documents_unverifiable_read_of_a_different_role(self) -> None:
        self.note()
        self.read(self.doc(at=OLD), role="Producer", outcome="verified", reason="independently confirmed", need=None)
        self.read(self.doc(at=NEW), role="Composer")           # a different role, and nothing verified for it
        rc, out = self.run_op("apply")
        self.assertEqual(rc, 0)
        self.assertNotIn("accepted", out)
        self.assertEqual(self.review()["outcome"], "rejected")
        self.assertEqual(self.review()["reason"], "other_role")
        self.assertEqual(self.decision()["ask_need"], pr.NEED_COUNTERPARTY)

    def test_a_same_role_unverifiable_read_does_not_hide_a_second_role_that_is_not_proven(self) -> None:
        self.note()
        self.read(self.doc(at=OLD), role="Producer", outcome="verified", reason="independently confirmed", need=None)
        late = self.doc(at=NEW)
        self.read(late, role="Producer")                        # same role as the verified read: changes nothing
        self.read(late, role="Composer")                        # not proven by any document
        rc, out = self.run_op("apply")
        self.assertNotIn("accepted", out)
        self.assertEqual(self.review()["outcome"], "rejected")
        self.assertEqual(self.review()["reason"], "other_role")

    def test_a_verified_read_gets_no_verdict_while_another_document_for_the_credit_is_unread(self) -> None:
        self.note()
        self.read(self.doc(at=OLD), outcome="verified", reason="independently confirmed", need=None)
        late = self.doc(at=NEW)                                 # filed, not read yet
        rc, out = self.run_op("apply")
        self.assertEqual(rc, 0)
        self.assertEqual(out["wait_reader"], 1)
        self.assertNotIn("accepted", out)
        self.assertIsNone(self.review())
        self.assertEqual(self.due(), [])
        self.assertEqual(self.held(), {A: vl.HELD_AWAITING_REVIEW})
        self.read(late)                                         # read, and it proves nothing: the verified read stands
        rc, out = self.run_op("apply")
        self.assertEqual(out["accepted"], 1)
        self.assertEqual(self.review()["outcome"], "accepted")

    def test_a_verified_read_gets_no_verdict_while_another_read_of_the_credit_is_unknown(self) -> None:
        self.note()
        self.read(self.doc(at=OLD), outcome="verified", reason="independently confirmed", need=None)
        self.read(self.doc(at=NEW), outcome="unknown", reason="tooling: provider down", need=None)
        rc, out = self.run_op("apply")
        self.assertEqual(rc, 0)
        self.assertEqual(out["wait_reader"], 1)
        self.assertNotIn("accepted", out)
        self.assertIsNone(self.review())
        self.assertEqual(self.due(), [])

    def test_an_accepted_verdict_is_not_rewritten_by_a_later_unverifiable_read_of_the_same_role(self) -> None:
        self.note(message_id="m-again")
        self.read(self.doc(at=OLD), outcome="verified", reason="independently confirmed", need=None)
        self.run_op("apply")
        first = dict(self.review())
        self.assertEqual(first["outcome"], "accepted")
        decisions = self.db.execute("SELECT COUNT(*) FROM proof_review_decisions").fetchone()[0]
        self.read(self.doc(at=NEW))                             # a later document, same role, proves nothing
        vl.mark_tagged(self.db, message_id="m-again", conversation_id="c1", attachments=2, now=NOW)
        rc, out = self.run_op("apply", now=NOW + timedelta(hours=1))
        self.assertEqual(rc, 0)
        self.assertNotIn("recorded", out)
        self.assertNotIn("rejected", out)
        self.assertEqual(out["already_ruled"], 1)
        self.assertEqual(dict(self.review()), first)            # the same row: outcome, time and reviewer unchanged
        self.assertEqual(self.db.execute("SELECT COUNT(*) FROM proof_review_decisions").fetchone()[0], decisions)
        self.assertEqual(self.due(), [])

    def test_a_forged_read_is_never_accepted_and_its_ask_is_counted_as_blocked(self) -> None:
        self.note()
        self.read(self.doc(), outcome="forged", reason="forensics: edited_pdf", need=None, hold=True)
        rc, out = self.run_op("apply")
        self.assertEqual(out["rejected"], 1)
        self.assertEqual(out["ask_route:" + pr.BLOCKED_HOLD], 1)
        self.assertNotIn("accepted", out)
        self.assertEqual(self.review()["reason"], "not_a_document")
        self.assertEqual(self.decision()["ask_route"], pr.BLOCKED_HOLD)

    def test_a_verified_credit_on_a_held_account_is_accepted(self) -> None:
        self.note(ids=(A, B))
        self.read(self.doc(requests=(A,)), request=A, outcome="forged", reason="forensics: edited_pdf", need=None,
                  hold=True)
        self.read(self.doc(requests=(B,)), request=B, outcome="verified", reason="independently confirmed",
                  need=None, hold=True)
        rc, out = self.run_op("apply")
        self.assertEqual(rc, 0)
        self.assertEqual(self.review(B)["outcome"], "accepted")
        self.assertIsNone(self.review(B)["reason"])
        self.assertEqual(self.review(A)["outcome"], "rejected")
        self.assertEqual(self.decision(B)["ask_need"], None)
        self.assertEqual(self.due(), [])
        self.assertEqual(self.held(), {A: vl.HELD_NOT_TOLD})

    def test_a_sibling_credit_the_document_is_not_about_is_ruled_on_too(self) -> None:
        self.note(ids=(A, B))
        self.read(self.doc(requests=(A,)), request=A, outcome="verified", reason="independently confirmed", need=None)
        rc, out = self.run_op("apply")
        self.assertEqual(out["accepted"], 1)
        self.assertEqual(out["rejected"], 1)
        self.assertEqual(self.review(A)["outcome"], "accepted")
        self.assertEqual(self.review(B)["reason"], "other_track")
        self.assertEqual(self.decision(B)["ask_route"], pr.BLOCKED_NO_READ)
        self.assertEqual(self.decision(B)["ask_need"], None)                 # held, not recorded as an ask

    def test_the_issuer_email_ask_is_recorded_and_counted_as_locked(self) -> None:
        self.note()
        self.read(self.doc(), need=pr.NEED_ISSUER)
        rc, out = self.run_op("apply")
        self.assertEqual(self.decision()["ask_route"], pr.BLOCKED_VERIFY_AT)
        self.assertEqual(out["ask_route:" + pr.BLOCKED_VERIFY_AT], 1)

    def test_another_accounts_read_of_the_request_is_not_this_accounts_evidence(self) -> None:
        self.note()
        self.read(self.doc(), outcome="verified", reason="independently confirmed", need=None, user=99)
        self.run_op("apply")
        self.assertEqual(self.review()["outcome"], "rejected")

    # ---- no tagged credit is left with no AI writer -----------------------------------------------------------
    def test_no_tagged_credit_is_left_awaiting_a_review_nobody_can_write(self) -> None:
        self.note(ids=(A,), message_id=None)                                    # no Intercom message id
        self.note(ids=(B,), account="", removal_day=None)                       # no account id, no window
        root = self.note(ids=(C,), account="7", tagged=None)                    # tagged on its reminder only
        self.note(ids=(C,), account="7", parent=root, kind="reminder-14")
        d1 = "dddddddd-0000-4000-8000-000000000000"
        self.note(ids=(d1,), campaign=vl.DECLINE_CAMPAIGN, account="8", removal_day=None)   # a document on a decline
        self.read(self.doc(requests=(A,)), request=A)
        self.read(self.doc(requests=(B,)), request=B)
        self.read(self.doc(user=7, requests=(C,)), request=C, user=7)
        self.read(self.doc(user=8, requests=(d1,)), request=d1, user=8)
        self.assertEqual(pr.under_review(self.db)[1]["credits_unreviewed"], 4)
        rc, out = self.run_op("apply")
        self.assertEqual(rc, 0)
        self.assertEqual(out["recorded"], 4)
        self.assertEqual(out["record:ok"], 4)
        notes, counts = pr.under_review(self.db)
        self.assertEqual(notes, [])
        self.assertEqual(counts["credits_unreviewed"], 0)
        reviewers = [r[0] for r in self.db.execute("SELECT reviewed_by FROM verify_proof_reviews")]
        self.assertEqual(len(reviewers), 4)
        for who in reviewers:
            with self.subTest(who=who):
                self.assertRegex(who, r"^ai:proof-reviewer/pr-\d+ doc-verify/dv-\d+ model=\S+$")
        self.assertNotIn(vl.HELD_AWAITING_REVIEW, self.held().values())

    def test_every_verdict_is_accepted_or_rejected_and_every_rejection_has_an_ask(self) -> None:
        outcomes = ("verified", "unverifiable", "unknown", "forged", "forged_positive", "contradicted")
        for outcome in outcomes:
            for need in (None, *pr.ASK_NEEDS, "account_on_hold", "something_new"):
                with self.subTest(outcome=outcome, need=need):
                    v = pr.judge(A, "42", pr.Evidence(rows={A: [
                        {"id": 1, "proof_id": "s", "role": "Producer", "user_id": 42, "outcome": outcome,
                         "reason": "x", "need": need, "account_hold": 0}]}), now=NOW)
                    if outcome == "unknown":
                        self.assertIsNone(v)
                        continue
                    self.assertIsNotNone(v)
                    self.assertIn(v.outcome, vl.PROOF_OUTCOMES)
                    if v.outcome == "rejected":
                        self.assertIn(v.reason, vl.REJECTION_REASONS)
                        if v.ask_route == pr.ROUTE_ASK:
                            self.assertIn(v.ask_need, pr.ASK_NEEDS)
                            self.assertEqual(v.ask, pr.ASK_LINES[v.ask_need])
                        else:
                            self.assertEqual(v.ask_need, "")
                            self.assertEqual(v.ask, "")

    def test_a_claim_note_is_left_to_the_claim_ladder(self) -> None:
        self.note(campaign=vl.CLAIM_CAMPAIGN, ids=("claim-5",), removal_day=None)
        rc, out = self.run_op("apply")
        self.assertEqual(out["claim_notes_not_credits"], 1)
        self.assertNotIn("recorded", out)

    # ---- the backlog: bounded, idempotent, revertible ---------------------------------------------------------
    def test_a_run_is_bounded_and_a_second_run_decides_nothing_twice(self) -> None:
        for i, rid in enumerate((A, B, C)):
            self.note(ids=(rid,), tagged=f"2026-11-0{i + 1}T00:00:00Z")
            self.read(self.doc(requests=(rid,)), request=rid)
        rc, out = self.run_op("apply", "--max-notes", "2")
        self.assertEqual(out["recorded"], 2)
        self.assertEqual(out["notes_left_for_next_run"], 1)
        self.assertIsNone(self.review(C))                       # oldest tag first
        rc, out = self.run_op("apply", "--max-notes", "2")
        self.assertEqual(out["recorded"], 1)
        rc, out = self.run_op("apply", "--max-notes", "2")
        self.assertNotIn("recorded", out)
        self.assertEqual(self.db.execute("SELECT COUNT(*) FROM verify_proof_reviews").fetchone()[0], 3)
        self.assertEqual(self.db.execute("SELECT COUNT(*) FROM proof_review_decisions").fetchone()[0], 3)

    def test_the_waiting_count_covers_every_note_even_past_the_note_bound(self) -> None:
        self.note(ids=(A,), tagged=OLD)
        self.read(self.doc(requests=(A,)), request=A)
        for rid, tag in ((B, "2026-11-02T00:00:00Z"), (C, "2026-11-03T00:00:00Z")):
            self.note(ids=(rid,), tagged=tag)
            self.doc(requests=(rid,), at="2026-10-30T00:00:00Z")
        rc, out = self.run_op("apply", "--max-notes", "1")
        self.assertEqual(out["recorded"], 1)
        self.assertEqual(out["wait_reader"], 2)
        self.assertEqual(out["wait_reader_oldest_days"], 14)
        with open(self.waiting) as fh:
            self.assertEqual(json.load(fh)["wait_reader"], 2)
        self.assertEqual(self.db.execute("SELECT COUNT(*) FROM verify_proof_reviews").fetchone()[0], 1)

    def two_tagged_rows(self) -> int:
        """An initial note and its reminder for ONE credit, both tagged by the ledger's own tag writer."""
        root = self.note(tagged=None, message_id="m-initial")
        self.note(tagged=None, message_id="m-reminder", parent=root, kind="followup")
        vl.mark_tagged(self.db, message_id="m-reminder", conversation_id="c1", attachments=1, now=NOW)
        self.assertEqual(self.db.execute(
            "SELECT COUNT(*) FROM verify_messages WHERE proof_tagged_at IS NOT NULL").fetchone()[0], 2)
        return root

    def test_one_credit_is_ruled_on_once_when_its_family_has_two_tagged_rows(self) -> None:
        self.two_tagged_rows()
        self.read(self.doc(), outcome="verified", reason="independently confirmed", need=None)
        rc, out = self.run_op("apply")
        self.assertEqual(rc, 0)
        self.assertEqual(out["recorded"], 1)
        self.assertEqual(out["accepted"], 1)
        self.assertEqual(self.review()["outcome"], "accepted")
        self.assertEqual(self.db.execute("SELECT COUNT(*) FROM proof_review_decisions").fetchone()[0], 1)
        rc, back = self.run_op("revert", "--run-id", out["run_id"])
        self.assertEqual(back["reverted"], 1)
        self.assertEqual(back["changed_since"], 0)
        self.assertIsNone(self.review())

    def test_a_rejection_on_two_tagged_rows_is_counted_once_and_writes_no_stray_row(self) -> None:
        self.two_tagged_rows()
        self.read(self.doc())
        rc, out = self.run_op("apply")
        self.assertEqual(rc, 0)
        self.assertEqual(out["rejected"], 1)
        self.assertEqual(out["ask:" + pr.NEED_COUNTERPARTY], 1)
        self.assertNotIn("record:not_tagged", out)
        self.assertEqual(self.db.execute(
            "SELECT COUNT(*) FROM proof_review_decisions WHERE result='not_tagged'").fetchone()[0], 0)

    def test_a_credit_waiting_on_the_reader_is_counted_once_with_two_tagged_rows(self) -> None:
        self.two_tagged_rows()
        self.doc()
        rc, out = self.run_op("apply")
        self.assertEqual(rc, 0)
        self.assertEqual(out["wait_reader"], 1)
        self.assertNotIn("recorded", out)

    def test_a_credit_with_two_tagged_rows_takes_one_slot_of_the_note_bound(self) -> None:
        self.two_tagged_rows()
        self.note(ids=(B,), tagged="2026-11-02T00:00:00Z")
        self.read(self.doc(), outcome="verified", reason="independently confirmed", need=None)
        self.read(self.doc(requests=(B,)), request=B, outcome="verified", reason="independently confirmed", need=None)
        rc, out = self.run_op("apply", "--max-notes", "1")
        self.assertEqual(rc, 0)
        self.assertEqual(out["recorded"], 1)
        self.assertEqual(out["notes_left_for_next_run"], 1)

    def test_one_credit_named_by_two_notes_is_ruled_on_once_and_reverts_cleanly(self) -> None:
        self.note(tagged=None, message_id="m-ask", campaign="proof-need-ask")
        self.note(tagged=None, message_id="m-status", campaign="status-doc-received")
        vl.mark_tagged(self.db, message_id="m-ask", conversation_id="c1", attachments=1, now=NOW)
        vl.mark_tagged(self.db, message_id="m-status", conversation_id="c1", attachments=1, now=NOW)
        self.assertEqual(self.db.execute(
            "SELECT COUNT(*) FROM verify_messages WHERE proof_tagged_at IS NOT NULL").fetchone()[0], 2)
        self.read(self.doc(), outcome="verified", reason="independently confirmed", need=None)
        rc, out = self.run_op("apply", "--max-notes", "1")
        self.assertEqual(rc, 0)
        self.assertEqual(out["recorded"], 1)
        self.assertEqual(out["accepted"], 1)
        self.assertNotIn("notes_left_for_next_run", out)
        self.assertEqual(self.db.execute("SELECT COUNT(*) FROM verify_proof_reviews").fetchone()[0], 1)
        self.assertEqual(self.db.execute("SELECT COUNT(*) FROM proof_review_decisions").fetchone()[0], 1)
        rc, back = self.run_op("revert", "--run-id", out["run_id"])
        self.assertEqual(back["reverted"], 1)
        self.assertEqual(back["changed_since"], 0)
        self.assertIsNone(self.review())
        self.assertEqual(self.db.execute(
            "SELECT COUNT(*) FROM proof_review_decisions WHERE result='ok' AND reverted_at IS NULL").fetchone()[0], 0)

    def three_notes_one_shared_credit(self, *, read_b: bool) -> None:
        """An ask note naming A and B, a status note naming A and C, a team-review note naming A and D."""
        self.note(ids=(A, B), message_id="m-ask", campaign="proof-need-ask", tagged=None)
        self.note(ids=(A, C), message_id="m-s1", campaign="status-doc-received", tagged=None)
        self.note(ids=(A, D), message_id="m-s2", campaign="status-team-review", tagged=None)
        for i, mid in enumerate(("m-s1", "m-s2", "m-ask")):
            vl.mark_tagged(self.db, message_id=mid, conversation_id="c1", attachments=1,
                           now=NOW - timedelta(hours=5 - i))
        self.read(self.doc(requests=(A,)), request=A)
        if read_b:
            self.read(self.doc(requests=(B,)), request=B, outcome="verified", reason="independently confirmed",
                      need=None)
        else:
            self.doc(requests=(B,))
        for r in (C, D):
            self.read(self.doc(requests=(r,)), request=r, outcome="verified", reason="independently confirmed",
                      need=None)

    def test_a_pending_credit_keeps_its_verdict_when_an_earlier_note_is_rejected(self) -> None:
        self.three_notes_one_shared_credit(read_b=True)
        rc, out = self.run_op("apply")
        self.assertEqual(rc, 0)
        self.assertNotIn("record:not_tagged", out)
        self.assertEqual(out["recorded"], 4)
        self.assertEqual(self.review(B)["outcome"], "accepted")
        self.assertEqual(self.review(C)["outcome"], "accepted")
        self.assertEqual(self.review(D)["outcome"], "accepted")

    def test_a_family_keeps_its_tag_while_a_credit_in_it_waits_on_the_reader(self) -> None:
        self.three_notes_one_shared_credit(read_b=False)
        rc, out = self.run_op("apply")
        self.assertEqual(rc, 0)
        self.assertEqual(out["wait_reader"], 1)
        self.assertIsNone(self.review(B))
        self.assertIsNotNone(self.db.execute(
            "SELECT proof_tagged_at FROM verify_messages WHERE message_id='m-ask'").fetchone()[0])

    def test_plan_writes_nothing(self) -> None:
        self.note()
        self.read(self.doc())
        rc, out = self.run_op("plan")
        self.assertEqual(rc, 0)
        self.assertEqual(out["rejected"], 1)
        self.assertIsNone(self.review())
        self.assertIsNone(self.db.execute("SELECT 1 FROM sqlite_master WHERE name='proof_review_decisions'").fetchone())

    def test_revert_removes_a_runs_verdicts_and_puts_the_note_back_under_review(self) -> None:
        nid = self.note()
        self.read(self.doc())
        rc, out = self.run_op("apply")
        rc, back = self.run_op("revert", "--run-id", out["run_id"])
        self.assertEqual(back["reverted"], 1)
        self.assertEqual(back["changed_since"], 0)
        self.assertIsNone(self.review())
        self.assertEqual(self.db.execute("SELECT proof_tagged_at FROM verify_messages WHERE id=?", (nid,)).fetchone()[0], OLD)
        self.assertEqual(self.held(), {A: vl.HELD_AWAITING_REVIEW})

    def test_revert_leaves_a_verdict_something_else_rewrote(self) -> None:
        self.note(message_id="m-override")
        self.read(self.doc())
        rc, out = self.run_op("apply")
        self.db.execute("UPDATE verify_proof_reviews SET reviewed_by='ops-override', reviewed_at='2026-11-13T13:00:00Z'")
        rc, back = self.run_op("revert", "--run-id", out["run_id"])
        self.assertEqual(back["reverted"], 0)
        self.assertEqual(back["changed_since"], 1)
        self.assertEqual(self.review()["reviewed_by"], "ops-override")

    # ---- a run that dies part-way leaves the ledger as it found it ---------------------------------------------
    def test_a_run_killed_between_the_verdict_and_its_audit_row_leaves_no_verdict(self) -> None:
        nid = self.note()
        self.read(self.doc())
        self.assertEqual(self.killed_apply("record_proof_review"), -signal.SIGKILL)
        self.assertIsNone(self.review())
        self.assertIsNone(self.decision())
        self.assertEqual(self.tag_of(nid), OLD)
        self.assertEqual(self.held(), {A: vl.HELD_AWAITING_REVIEW})
        rc, out = self.run_op("apply")
        self.assertEqual(out["recorded"], 1)
        self.assertEqual(self.review()["outcome"], "rejected")
        self.assertEqual(self.decision()["result"], "ok")

    def test_a_run_killed_after_it_cleared_a_tag_leaves_the_tag_and_no_verdict(self) -> None:
        nid = self.note()
        self.read(self.doc())
        self.assertEqual(self.killed_apply("settle_proof_tags"), -signal.SIGKILL)
        self.assertIsNone(self.review())
        self.assertIsNone(self.decision())
        self.assertEqual(self.tag_of(nid), OLD)
        rc, out = self.run_op("apply")
        self.assertIsNone(self.tag_of(nid))
        self.assertEqual(json.loads(self.decision()["cleared_tags_json"]), [[nid, OLD]])
        rc, back = self.run_op("revert", "--run-id", out["run_id"])
        self.assertEqual(back["reverted"], 1)
        self.assertEqual(self.tag_of(nid), OLD)

    def test_a_run_that_fails_part_way_writes_nothing_and_the_next_run_decides_it(self) -> None:
        nid = self.note(ids=(A, B))
        self.read(self.doc())
        self.read(self.doc(requests=(B,)), request=B, outcome="verified", reason="independently confirmed", need=None)
        real = vl.settle_proof_tags

        def fails(*a, **k):
            raise sqlite3.OperationalError("disk I/O error")

        vl.settle_proof_tags = fails
        try:
            rc, out = self.run_op("apply")
        finally:
            vl.settle_proof_tags = real
        self.assertEqual(rc, 2)
        self.assertIsNone(self.review(A))
        self.assertIsNone(self.review(B))
        self.assertIsNone(self.decision(A))
        self.assertEqual(self.tag_of(nid), OLD)
        rc, out = self.run_op("apply")
        self.assertEqual(out["recorded"], 2)
        self.assertEqual(self.review(B)["outcome"], "accepted")

    def test_the_kill_file_stops_it_before_anything_is_read(self) -> None:
        self.note()
        Path(self.kill).write_text("")
        rc, out = self.run_op("apply")
        self.assertEqual(rc, 0)
        self.assertEqual(out, {"op": "apply", "killed": self.kill})
        self.assertIsNone(self.review())

    def test_an_unreadable_store_is_an_error_and_never_a_rejection(self) -> None:
        self.note()
        Path(self.dv_path).unlink()
        rc, out = self.run_op("apply")
        self.assertEqual(rc, 2)
        self.assertIn("does not exist", out["error"])
        self.assertIsNone(self.review())

    # ---- no statement that a person reviews proof ---------------------------------------------------------------
    def test_every_former_hold_is_an_ai_verdict_or_a_wait_on_the_customer(self) -> None:
        self.note()
        self.read(self.doc(), outcome="verified")
        rc, out = self.run_op("apply")
        self.assertEqual(rc, 0)
        self.assertEqual(self.review()["outcome"], "accepted")
        self.assertTrue(self.review()["reviewed_by"].startswith("ai:proof-reviewer/"))
        self.assertEqual(self.held(), {})
        self.assertEqual(self.due(), [])

    def test_a_reply_with_no_document_waits_on_the_customer_not_on_staff(self) -> None:
        self.note(tagged=None)
        self.db.execute("UPDATE verify_messages SET extension_requested_at=? WHERE id=1", (OLD,))
        self.db.commit()
        self.assertEqual(self.held(), {A: vl.HELD_REPLIED})

    def test_no_text_a_customer_or_the_ledger_shows_names_a_person(self) -> None:
        said = re.compile(r"Jan reviews|for a human|a person decides|human review")
        self.note()
        self.read(self.doc(), outcome="unverifiable")
        rc, out = self.run_op("apply")
        self.assertEqual(rc, 0)
        d = self.decision()
        self.assertEqual(d["outcome"], "rejected")
        shown = json.dumps({"ask": d["ask"], "ask_need": d["ask_need"], "ask_route": d["ask_route"],
                            "reviewer": d["reviewer"], "held": self.held()})
        self.assertIsNone(said.search(shown))
        for need in pr.SENDABLE:
            with self.subTest(need=need):
                rc, rendered = self.gate_render(need)
                self.assertEqual(rc, 0)
                self.assertIn(GATE_COPY[need], rendered)
                self.assertIsNone(said.search(rendered))

    def test_the_cron_runs_it_hourly_and_names_its_kill_file(self) -> None:
        jobs = {j["name"]: j for j in json.loads((ROOT / "cron-jobs.json").read_text())["jobs"]}
        job = jobs["credit-proof-reviewer"]
        self.assertEqual(job["payload"]["argv"],
                         ["python3", "/opt/hydra/scripts/credit_review/proof_reviewer.py", "apply"])
        self.assertEqual(job["payload"]["kind"], "command")
        self.assertEqual(job["sessionTarget"], "isolated")
        self.assertEqual(job["delivery"]["mode"], "none")
        self.assertFalse(job["enabled"])


if __name__ == "__main__":
    unittest.main()
