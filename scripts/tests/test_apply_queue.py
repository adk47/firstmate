"""The temporary gate queue (scripts/credit_review/apply_queue.py). Stdlib only, no network.

What is pinned:
  - one intent per (campaign, user, request), and exactly one caller is told `go` for it, across threads;
  - `attempted` is committed before the gate is called, and the outcome comes from the verify ledger;
  - a dead worker's attempt is settled from the ledger: sent, uncertain (never sent again) or queued again;
  - an unreadable ledger is never read as "nothing was sent";
  - with the queue on, verify_notify.send_all reports exactly what it reports without it;
  - the switch: only an explicit true in a readable policy with no kill file;
  - a kill -9 run on scratch files ends with no request delivered twice and no orphan.
The fake gate keeps the real gate's contract: it claims in the REAL verify ledger before it "posts" and finalises after.
"""
from __future__ import annotations

import credit_test_env  # noqa: F401,E402 - first: test logs never reach the production run.log
import contextlib
import io
import json
import sqlite3
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))

from credit_review import apply_queue as aq  # noqa: E402
from credit_review import claim_proof_ask, verify_ledger, verify_notify  # noqa: E402

CAMPAIGN = "claim-proof-ask"


def payload(i: int) -> dict:
    return {"user": {"id": str(1000 + i), "email": f"u{i}@example.test", "professional_id": "pro"},
            "credits": [{"request_id": f"claim-{i}", "profile_id": f"p{i}"}]}


class LedgerGate:
    """A runner for verify_notify.send_all. `how[request_id]` picks what the gate does; the default posts."""

    def __init__(self, ledger: str, how: dict[str, str] | None = None) -> None:
        self.ledger, self.how, self.calls = ledger, how or {}, []
        self.lock = threading.Lock()

    def claim(self, p: dict) -> dict:
        db = verify_ledger.connect(self.ledger)
        try:
            rid = p["credits"][0]["request_id"]
            return verify_ledger.claim(db, user_key=p["user"]["email"], day=verify_ledger.stamp()[:10],
                                       request_ids=[rid], message_type="email", approved_by="t", approval_ref="t",
                                       campaign=CAMPAIGN, user_id=p["user"]["id"],
                                       refs=[{"request_id": rid, "profile_id": "p", "track_id": ""}])
        finally:
            db.close()

    def finalize(self, row: int, status: str) -> None:
        db = verify_ledger.connect(self.ledger)
        try:
            verify_ledger.finalize(db, message_row=row, status=status, message_id=f"m-{row}" if status == "sent" else "")
        finally:
            db.close()

    def __call__(self, argv: list[str]):
        p = json.loads(Path(argv[argv.index("--credits-file") + 1]).read_text())
        rid = p["credits"][0]["request_id"]
        with self.lock:
            self.calls.append(rid)
        how = self.how.get(rid, "post")
        if how == "refuse":
            return aq.subprocess.CompletedProcess(argv, 1, "", "REFUSED: G1: nothing was sent or claimed\n")
        c = self.claim(p)
        if c.get("result") != "claimed":
            return aq.subprocess.CompletedProcess(argv, 0, f"SKIPPED {c.get('result')} credits=1\n", "")
        if how == "timeout":                 # claimed, the POST may have landed, the answer never came
            raise verify_notify.NoteTimeout("the note step timed out")
        if how == "rejected":
            self.finalize(c["message_row"], "rejected")
            return aq.subprocess.CompletedProcess(argv, 4, "", "POST REJECTED by Intercom (nothing delivered; retried on a later run)\n")
        self.finalize(c["message_row"], "sent")
        return aq.subprocess.CompletedProcess(argv, 0, "POSTED credits=1\n", "")


class Base(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.ledger = str(Path(self.tmp.name) / "ledger.sqlite3")
        verify_ledger.connect(self.ledger).close()
        self.db = aq.connect(aq.journal_path(self.ledger))
        self.addCleanup(self.db.close)

    def state(self, i: int) -> tuple:
        return self.db.execute("SELECT state, attempts, ledger_row, message_id FROM intents WHERE idem_key = ?",
                               (aq.key_of(CAMPAIGN, payload(i)),)).fetchone()

    def attempt(self, i: int, worker: str = "w", **kw) -> str:
        aq.enqueue(self.db, CAMPAIGN, [payload(i)])
        v, _ = aq.begin(self.db, aq.key_of(CAMPAIGN, payload(i)), worker, floor=aq.ledger_floor(self.ledger), **kw)
        return v

    def finish(self, i: int, *, posted: bool = False, worker: str = "w") -> str:
        return aq.finish(self.db, aq.key_of(CAMPAIGN, payload(i)), worker, ledger_path=self.ledger, posted=posted,
                         answer="rc=?")


class JournalTests(Base):
    def test_one_intent_per_user_and_request_however_often_it_is_enqueued(self):
        self.assertEqual(aq.enqueue(self.db, CAMPAIGN, [payload(1), payload(2), payload(1)]), 2)
        self.assertEqual(aq.enqueue(self.db, CAMPAIGN, [payload(1), payload(2)]), 0)
        self.assertEqual(self.db.execute("SELECT COUNT(*) FROM intents").fetchone()[0], 2)

    def test_a_payload_with_no_user_or_no_request_has_no_key_and_is_not_queued(self):
        self.assertEqual(aq.key_of(CAMPAIGN, {"user": {}, "credits": [{"request_id": "claim-1"}]}), "")
        self.assertEqual(aq.key_of(CAMPAIGN, {"user": {"id": "1"}, "credits": []}), "")
        self.assertEqual(aq.enqueue(self.db, CAMPAIGN, [{"user": {}, "credits": [{"request_id": "claim-1"}]}]), 0)

    def test_exactly_one_of_many_threads_is_told_go(self):
        aq.enqueue(self.db, CAMPAIGN, [payload(1)])
        key, path, got = aq.key_of(CAMPAIGN, payload(1)), aq.journal_path(self.ledger), []

        def worker(n: int) -> None:
            db = aq.connect(path)
            try:
                got.append(aq.begin(db, key, f"w{n}", floor=0)[0])
            finally:
                db.close()
        threads = [threading.Thread(target=worker, args=(n,)) for n in range(12)]
        for t in threads:
            t.start()
        for t in threads:
            t.join()
        self.assertEqual(sorted(got), ["busy"] * 11 + ["go"])
        self.assertEqual(self.state(1)[:2], ("attempted", 1))

    def test_attempted_is_committed_before_any_outcome_and_a_second_caller_is_busy_then_unsettled(self):
        self.assertEqual(self.attempt(1, lease_s=0.2), "go")
        other = aq.connect(aq.journal_path(self.ledger))
        self.addCleanup(other.close)
        self.assertEqual(other.execute("SELECT state FROM intents").fetchone()[0], "attempted")   # visible elsewhere
        key = aq.key_of(CAMPAIGN, payload(1))
        self.assertEqual(aq.begin(other, key, "w2", floor=0)[0], "busy")
        time.sleep(0.3)
        self.assertEqual(aq.begin(other, key, "w2", floor=0)[0], "unsettled")     # never taken over unsettled

    def test_the_outcome_is_what_the_ledger_shows(self):
        g = LedgerGate(self.ledger)
        for i, (ledger_status, want) in enumerate([("sent", "sent"), ("attempted", "uncertain"), ("rejected", "queued"),
                                                   ("refused", "queued"), (None, "queued")], start=1):
            self.assertEqual(self.attempt(i), "go")
            if ledger_status:
                row = g.claim(payload(i))["message_row"]
                if ledger_status != "attempted":
                    g.finalize(row, ledger_status)
            self.assertEqual(self.finish(i), want, ledger_status)
            self.assertEqual(self.state(i)[0], want)
        self.assertEqual(self.state(1)[2:], (1, "m-1"))            # the ledger row and Intercom's id ride with `sent`
        self.assertIn("never claimed", self.db.execute(
            "SELECT reason FROM intents WHERE idem_key = ?", (aq.key_of(CAMPAIGN, payload(5)),)).fetchone()[0])

    def test_a_row_from_before_the_attempt_is_not_this_attempts_outcome(self):
        g = LedgerGate(self.ledger)
        g.finalize(g.claim(payload(1))["message_row"], "rejected")     # an earlier run's rejected POST
        self.assertEqual(self.attempt(1), "go")
        self.assertEqual(self.finish(1), "queued")
        self.assertIn("no ledger row", self.db.execute("SELECT reason FROM intents").fetchone()[0])

    def test_posted_is_sent_even_when_the_ledger_cannot_be_read_and_otherwise_it_stays_attempted(self):
        self.assertEqual(self.attempt(1), "go")
        self.assertEqual(self.attempt(2), "go")
        Path(self.ledger).write_bytes(b"not a database, " * 64)
        self.assertEqual(self.finish(1, posted=True), "sent")
        self.assertEqual(self.finish(2), "")                          # unmeasured is not "nothing was sent"
        self.assertEqual(self.state(2)[0], "attempted")
        self.assertEqual(aq.settle(self.db, self.ledger, now=time.time() + 10_000)["unreadable"], 1)
        self.assertEqual(self.state(2)[0], "attempted")

    def test_a_late_outcome_from_a_worker_that_no_longer_holds_the_intent_changes_nothing(self):
        self.assertEqual(self.attempt(1), "go")
        self.assertEqual(self.finish(1, posted=True, worker="someone-else"), "")
        self.assertEqual(self.state(1)[0], "attempted")

    def test_a_retry_reads_the_note_the_released_worker_wrote_after_the_release(self):
        # The window the kill -9 run hit: the lease runs out while the worker is still inside the gate, so the
        # intent is released as "no ledger row" before the note lands. The worker then writes it and its report
        # is discarded (it no longer holds the intent). The retry must read that note, not call it queued again
        # for ever.
        self.assertEqual(self.attempt(1, lease_s=0.01), "go")
        self.assertEqual(aq.settle(self.db, self.ledger, now=time.time() + 10)["queued"], 1)
        g = LedgerGate(self.ledger)
        g.finalize(g.claim(payload(1))["message_row"], "sent")       # the released worker's note, landing late
        self.assertEqual(self.finish(1), "")                         # its own report changes nothing now
        self.assertEqual(self.attempt(1, worker="w2"), "go")
        self.assertEqual(self.finish(1, worker="w2"), "sent")
        self.assertEqual(self.state(1)[0], "sent")

    def test_settle_reads_a_dead_workers_attempt_from_the_ledger(self):
        g = LedgerGate(self.ledger)
        for i in (1, 2, 3):
            self.assertEqual(self.attempt(i, lease_s=0.01), "go")
        g.finalize(g.claim(payload(1))["message_row"], "sent")        # died after the finalize, before reporting
        g.claim(payload(2))                                           # died between the claim and the finalize
        time.sleep(0.05)                                              # 3 died before the gate claimed
        self.assertEqual(aq.settle(self.db, self.ledger), {"sent": 1, "uncertain": 1, "queued": 1, "unreadable": 0})
        self.assertEqual([self.state(i)[0] for i in (1, 2, 3)], ["sent", "uncertain", "queued"])
        key2 = aq.key_of(CAMPAIGN, payload(2))
        self.assertEqual(aq.begin(self.db, key2, "w9", floor=0)[0], "uncertain")          # never sent again
        self.assertEqual(aq.begin(self.db, aq.key_of(CAMPAIGN, payload(3)), "w9", floor=0)[0], "go")

    def test_a_live_workers_attempt_is_not_settled(self):
        self.assertEqual(self.attempt(1), "go")
        self.assertEqual(sum(aq.settle(self.db, self.ledger).values()), 0)
        self.assertEqual(self.state(1)[0], "attempted")

    def test_uncertain_follows_the_ledger_and_otherwise_needs_a_named_person(self):
        g = LedgerGate(self.ledger)
        rows = {}
        for i in (1, 2, 3):
            self.assertEqual(self.attempt(i), "go")
            rows[i] = g.claim(payload(i))["message_row"]
            self.assertEqual(self.finish(i), "uncertain")
        g.finalize(rows[1], "sent")
        g.finalize(rows[2], "rejected")
        aq.settle(self.db, self.ledger)
        self.assertEqual([self.state(i)[0] for i in (1, 2, 3)], ["sent", "queued", "uncertain"])
        key3 = aq.key_of(CAMPAIGN, payload(3))
        with self.assertRaises(ValueError):
            aq.resolve(self.db, key3, "sent", by=" ")
        with self.assertRaises(ValueError):
            aq.resolve(self.db, key3, "rejected", by="Nick")
        self.assertTrue(aq.resolve(self.db, key3, "sent", by="Nick", note="read in Intercom"))
        self.assertFalse(aq.resolve(self.db, key3, "queued", by="Nick"))

    def test_the_database_refuses_what_the_code_must_never_do(self):
        aq.enqueue(self.db, CAMPAIGN, [payload(1), payload(2)])
        k1, k2 = aq.key_of(CAMPAIGN, payload(1)), aq.key_of(CAMPAIGN, payload(2))
        for sql, args, why in [
                ("UPDATE intents SET state = 'sent' WHERE idem_key = ?", (k1,), "sent without a recorded attempt"),
                ("DELETE FROM intents WHERE idem_key = ?", (k1,), "never deleted"),
                ("INSERT INTO intents (idem_key, campaign, user_id, request_key, state, enqueued_at) "
                 "VALUES ('x', 'c', 'u', 'r', 'sent', 0)", (), "starts queued"),
                ("UPDATE intent_events SET detail = 'x'", (), "append-only"),
                ("DELETE FROM intent_events", (), "append-only")]:
            with self.assertRaises(sqlite3.IntegrityError, msg=why) as cm:
                self.db.execute(sql, args)
            self.assertIn(why, str(cm.exception))
        self.assertEqual(aq.begin(self.db, k2, "w", floor=0)[0], "go")
        with self.assertRaises(sqlite3.IntegrityError) as cm:
            self.db.execute("UPDATE intents SET state = 'attempted' WHERE idem_key = ?", (k2,))
        self.assertIn("only a queued intent", str(cm.exception))
        self.assertEqual(aq.finish(self.db, k2, "w", ledger_path=self.ledger, posted=True, answer=""), "sent")
        with self.assertRaises(sqlite3.IntegrityError) as cm:
            self.db.execute("UPDATE intents SET state = 'queued' WHERE idem_key = ?", (k2,))
        self.assertIn("never rewritten", str(cm.exception))


class SendAllTests(Base):
    """The queue under the real verify_notify.send_all, apply mode."""

    def run_apply(self, payloads: list[dict], gate: LedgerGate, *, queue: bool = True, ledger: str = "") -> verify_notify.Report:
        rep = verify_notify.Report()
        session = aq.Session(CAMPAIGN, ledger or self.ledger) if queue else None
        with mock.patch.object(verify_notify, "attach_identities", lambda ps, r: (ps, None)):
            verify_notify.send_all(payloads, rep, mode="apply", runner=gate, extra=["--campaign", CAMPAIGN], queue=session)
        return rep

    def test_the_report_is_the_same_with_and_without_the_queue(self):
        how = {"claim-2": "refuse", "claim-4": "timeout", "claim-5": "rejected"}
        other = str(Path(self.tmp.name) / "direct" / "ledger.sqlite3")
        Path(other).parent.mkdir()
        verify_ledger.connect(other).close()
        ps = [payload(i) for i in range(1, 9)]
        direct = self.run_apply(ps, LedgerGate(other, how), queue=False, ledger=other)
        queued = self.run_apply(ps, LedgerGate(self.ledger, how))
        self.assertEqual(vars(direct), vars(queued))
        self.assertEqual(queued.sent_notes, 5)
        self.assertEqual({s: n for s, n in self.db.execute("SELECT state, COUNT(*) FROM intents GROUP BY 1")},
                         {"sent": 5, "queued": 2, "uncertain": 1})
        v = aq.verify(self.db, self.ledger, CAMPAIGN)
        self.assertEqual(v["must_be_zero"], {"requests_with_two_notes": 0, "orphans": 0, "sent_without_ledger_row": 0})
        self.assertFalse(Path(other).parent.joinpath(aq.JOURNAL_NAME).exists())     # the direct path wrote no journal

    def test_a_second_run_never_reaches_the_gate_for_what_is_sent_or_uncertain(self):
        how = {"claim-2": "refuse", "claim-3": "timeout"}
        ps = [payload(i) for i in (1, 2, 3)]
        self.run_apply(ps, LedgerGate(self.ledger, how))
        gate = LedgerGate(self.ledger, how)
        rep = self.run_apply(ps, gate)
        self.assertEqual(gate.calls, ["claim-2"])                  # only the one the gate itself did not send
        self.assertEqual(rep.sent_notes, 0)
        by_user = {o["user"]: (o["result"], o["reason"]) for o in rep.outcomes}
        self.assertEqual(by_user["1001"][0], "skipped")
        self.assertIn("apply_queue_already_sent", by_user["1001"][1])
        self.assertEqual(by_user["1003"][0], "deferred")
        self.assertIn("apply_queue_uncertain", by_user["1003"][1])
        self.assertEqual(aq.verify(self.db, self.ledger, CAMPAIGN)["must_be_zero"]["requests_with_two_notes"], 0)

    def test_a_request_another_worker_holds_is_deferred_not_sent(self):
        self.assertEqual(self.attempt(1, worker="another-process"), "go")
        gate = LedgerGate(self.ledger)
        rep = self.run_apply([payload(1), payload(2)], gate)
        self.assertEqual(gate.calls, ["claim-2"])
        self.assertIn("apply_queue_busy", rep.outcomes[0]["reason"])
        self.assertEqual(rep.deferred_users, 1)

    def test_a_dead_runs_attempt_is_settled_before_the_next_run_sends(self):
        g = LedgerGate(self.ledger)
        self.assertEqual(self.attempt(1, lease_s=0.01), "go")       # died before the gate claimed: owed again
        self.assertEqual(self.attempt(2, lease_s=0.01), "go")       # died after the POST and the finalize
        g.finalize(g.claim(payload(2))["message_row"], "sent")
        time.sleep(0.05)
        gate = LedgerGate(self.ledger)
        rep = self.run_apply([payload(1), payload(2)], gate)
        self.assertEqual(gate.calls, ["claim-1"])
        self.assertEqual(rep.sent_notes, 1)
        self.assertEqual([self.state(i)[0] for i in (1, 2)], ["sent", "sent"])
        self.assertEqual(aq.verify(self.db, self.ledger, CAMPAIGN)["must_be_zero"],
                         {"requests_with_two_notes": 0, "orphans": 0, "sent_without_ledger_row": 0})

    def test_a_journal_that_cannot_be_opened_is_the_direct_path_and_says_so(self):
        gate = LedgerGate(self.ledger)
        session = aq.Session(CAMPAIGN, self.ledger, path=self.tmp.name)       # a directory, not a file
        rep, err = verify_notify.Report(), io.StringIO()
        with mock.patch.object(verify_notify, "attach_identities", lambda ps, r: (ps, None)), contextlib.redirect_stderr(err):
            verify_notify.send_all([payload(1)], rep, mode="apply", runner=gate, extra=["--campaign", CAMPAIGN], queue=session)
        self.assertEqual(rep.sent_notes, 1)
        self.assertIn("APPLY QUEUE UNAVAILABLE", err.getvalue())

    def test_a_dry_run_never_touches_the_queue(self):
        rep = verify_notify.Report()
        gate = lambda argv: aq.subprocess.CompletedProcess(argv, 0, "VALID credits=1\n", "")      # noqa: E731
        verify_notify.send_all([payload(1)], rep, mode="dry-run", runner=gate, queue=aq.Session(CAMPAIGN, self.ledger))
        self.assertEqual(self.db.execute("SELECT COUNT(*) FROM intents").fetchone()[0], 0)


class SwitchTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.nokill = str(Path(self.tmp.name) / "absent.disabled")

    def policy(self, body: str) -> str:
        p = Path(self.tmp.name) / "policy.json"
        p.write_text(body)
        return str(p)

    def test_the_shipped_policy_switches_on_one_campaign_and_says_it_is_temporary(self):
        shipped = json.loads(aq.POLICY_PATH.read_text())
        self.assertEqual([c for c, row in shipped["campaigns"].items() if row.get("enabled") is True], [CAMPAIGN])
        self.assertIn("TEMPORARY", shipped["_doc"])
        self.assertIn("Remove this file", shipped["_doc"])
        self.assertTrue(aq.enabled_for(CAMPAIGN, kill_file=self.nokill))
        self.assertFalse(aq.enabled_for("uvn-status", kill_file=self.nokill))
        self.assertEqual(claim_proof_ask.CAMPAIGN, CAMPAIGN)

    def test_anything_but_an_explicit_true_is_the_direct_path(self):
        for body in ('{"campaigns": {"claim-proof-ask": {"enabled": "true"}}}', '{"campaigns": {"claim-proof-ask": {"enabled": 1}}}',
                     '{"campaigns": {}}', '{"campaigns": []}', "not json", "[]"):
            self.assertFalse(aq.enabled_for(CAMPAIGN, policy_path=self.policy(body), kill_file=self.nokill), body)
        self.assertFalse(aq.enabled_for(CAMPAIGN, policy_path=str(Path(self.tmp.name) / "missing.json"), kill_file=self.nokill))
        on = self.policy('{"campaigns": {"claim-proof-ask": {"enabled": true}}}')
        self.assertTrue(aq.enabled_for(CAMPAIGN, policy_path=on, kill_file=self.nokill))
        self.assertIsNotNone(aq.session_for(CAMPAIGN, "/x/ledger.sqlite3", policy_path=on, kill_file=self.nokill))
        self.assertIsNone(aq.session_for(CAMPAIGN, ":memory:", policy_path=on, kill_file=self.nokill))

    def test_the_kill_file_is_the_direct_path(self):
        on = self.policy('{"campaigns": {"claim-proof-ask": {"enabled": true}}}')
        kill = Path(self.tmp.name) / "apply-queue.disabled"
        kill.touch()
        self.assertFalse(aq.enabled_for(CAMPAIGN, policy_path=on, kill_file=str(kill)))
        self.assertIsNone(aq.session_for(CAMPAIGN, "/x/ledger.sqlite3", policy_path=on, kill_file=str(kill)))

    def test_only_the_claim_ask_runner_passes_a_queue(self):
        users = [p for p in (ROOT / "scripts").rglob("*.py")
                 if "tests" not in p.parts and p.name != "apply_queue.py" and "apply_queue.session_for" in p.read_text()]
        self.assertEqual([p.name for p in users], ["claim_proof_ask.py"])


class KillNineTests(unittest.TestCase):
    def test_workers_killed_mid_batch_leave_no_request_delivered_twice_and_no_orphan(self):
        r = subprocess.run([sys.executable, str(ROOT / "scripts" / "credit_review" / "apply_queue.py"), "chaos",
                            "--jobs", "120", "--workers", "6", "--latency-ms", "5"],
                           capture_output=True, text=True, timeout=600)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        out = json.loads(r.stdout)
        self.assertGreater(out["in_flight_at_kill"], 0)
        self.assertEqual(out["provider"]["requests_delivered_twice"], 0)
        self.assertEqual(out["must_be_zero"], {"requests_with_two_notes": 0, "orphans": 0, "sent_without_ledger_row": 0})
        self.assertEqual(out["final_states"].get("sent", 0) + out["final_states"].get("uncertain", 0), 120)


if __name__ == "__main__":
    unittest.main()
