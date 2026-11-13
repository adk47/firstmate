#!/usr/bin/env python3
"""The bulk send queue (scripts/credit_review/bulk_queue.py; docs/credit-verification/bulk-send-queue.md).

What is pinned here: one verdict per person from one statement, one job per (user, stage) however often it runs,
no job without a `send` verdict and no `sent` without a recorded attempt (refused by the database, not by a
caller), an atomic claim, what `recover` does with a dead worker's rows on a provider that de-duplicates and on one
that does not, that a body the copy gate has not approved is never handed to the sender, and the kill -9 run.
Stdlib only.
"""
from __future__ import annotations

import json
import os
import sqlite3
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts" / "credit_review"))
import bulk_queue as bq  # noqa: E402

SCRIPT = ROOT / "scripts" / "credit_review" / "bulk_queue.py"
PIN = "a" * 64
POLICY = {
    "enabled": True,
    "routes": {"chat": {"batch_capable": False, "idempotent": False},
               "email": {"batch_capable": True, "idempotent": True, "enabled": True,
                         "template_keys": {"status-doc-received": "credit_status_doc_received",
                                           "status-team-review": "credit_status_team_review"},
                         "template_sha256": {"credit_status_doc_received": PIN, "credit_status_team_review": PIN}},
               "intercom": {"batch_capable": False, "idempotent": False}},
    "stages": {"doc_received": "status-doc-received", "team_review": "status-team-review"},
}


def person(i: int, **over) -> dict:
    p = {"user_key": f"u{i}@example.test", "user_id": str(1000 + i), "email": f"u{i}@example.test",
         "email_confirmed": True, "stage": "doc_received", "request_ids": [f"r{i}a", f"r{i}b"],
         "body": "We have your document.", "data": {"request_type": "credit"}}
    p.update(over)
    return p


class Gate:
    """A copy gate that approves, or holds every body, and counts what it was asked."""

    def __init__(self, hold: str = ""):
        self.hold, self.asked = hold, []

    def require(self, campaign, body, **kw):
        self.asked.append((campaign, body, kw.get("copy")))
        if self.hold:
            raise RuntimeError(f"copy_review_hold: {self.hold}")
        return {"state": "approved"}


class Exec:
    """Stands in for the one kubectl exec. `answer(payload)` returns the gateway's answer, None for no line at
    all, or raises to model an exec that died mid-batch."""

    def __init__(self, answer):
        self.answer, self.seen = answer, []

    def __call__(self, lines):
        for line in lines[1:]:
            p = json.loads(line)
            self.seen.append(p)
            ans = self.answer(p)
            if ans is not None:
                yield dict(ans, k=p["k"])


class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="bulk-queue-test-")
        self.addCleanup(self.tmp.cleanup)
        self.path = os.path.join(self.tmp.name, "queue.sqlite")
        self.db = bq.connect(self.path, init=True)
        self.addCleanup(self.db.close)
        bq.apply_policy(self.db, POLICY)
        self.kill = os.path.join(self.tmp.name, "kill")

    def fill(self, people):
        bq.load_people(self.db, people)
        return bq.decide(self.db), bq.enqueue(self.db)

    def states(self):
        return dict(self.db.execute("SELECT state, COUNT(*) FROM jobs GROUP BY 1").fetchall())

    def job(self, i):
        return self.db.execute("SELECT state, reason, provider_id, not_before, attempts FROM jobs WHERE user_key=?",
                               (f"u{i}@example.test",)).fetchone()

    def events(self, i):
        return [e for (e,) in self.db.execute(
            "SELECT e.event FROM job_events e JOIN jobs j ON j.idem_key = e.idem_key WHERE j.user_key = ? "
            "ORDER BY e.seq", (f"u{i}@example.test",))]

    def run_email(self, answer, gate=None, **kw):
        ex = Exec(answer)
        route = bq.EmailRoute(POLICY, exec_batch=ex, gate=gate or Gate())
        return bq.work(self.db, route, kw.pop("worker", "w1"), kill_file=self.kill, **kw), ex


class DecideTests(Base):
    def test_one_statement_gives_one_verdict_per_person_in_rank_order(self):
        decided, _ = self.fill([
            person(1), person(2, hold="unmeasured"), person(3, told=["doc_received"]), person(4, request_ids=[]),
            person(5, stage="unmapped"), person(6, body=""), person(7, email="", intercom_thread="c7"),
            person(8, email_confirmed=False), person(9, hold="lens:band_red", told=["doc_received"]),
            person(10, chat_reachable=True)])
        got = {u.split("@")[0]: f"{v}:{r}:{rt}" for u, v, r, rt in self.db.execute(
            "SELECT user_key, verdict, reason, route FROM verdicts")}
        self.assertEqual(got, {
            "u1": "send:predicates_clear:email", "u2": "hold:unmeasured:", "u3": "skip:already_told:",
            "u4": "skip:nothing_open:", "u5": "hold:no_class_for_stage:", "u6": "hold:no_copy:",
            "u7": "hold:no_route:", "u8": "hold:no_route:", "u9": "hold:lens:band_red:",
            "u10": "send:predicates_clear:email"})  # chat is not batch capable, so a chat user goes by email
        self.assertEqual(decided["people"], 10)
        self.assertEqual(decided["rows_covered"], 18)  # every request of a person carries that person's verdict
        self.assertEqual(self.db.execute(
            "SELECT verdict FROM row_verdicts WHERE request_id = 'r2b'").fetchone()[0], "hold")

    def test_rerun_changes_nothing_and_queues_nobody_twice(self):
        _, first = self.fill([person(i) for i in range(50)])
        before = self.db.execute("SELECT user_key, stage, verdict, decided_at FROM verdicts ORDER BY 1").fetchall()
        bq.decide(self.db)
        again = bq.enqueue(self.db)
        self.assertEqual((first["enqueued"], again["enqueued"]), (50, 0))
        self.assertEqual(before, self.db.execute(
            "SELECT user_key, stage, verdict, decided_at FROM verdicts ORDER BY 1").fetchall())
        self.assertEqual(bq.verify(self.db)["users_with_two_jobs_in_a_stage"], 0)

    def test_a_cleared_hold_is_redecided_and_a_send_verdict_never_is(self):
        self.fill([person(1, hold="unmeasured"), person(2)])
        self.assertEqual(self.states(), {"queued": 1})
        self.fill([person(1), person(2, hold="lens:band_red")])
        self.assertEqual(self.states(), {"queued": 2})  # u1 cleared and queued; u2's job and verdict stand
        self.assertEqual(self.db.execute(
            "SELECT verdict FROM verdicts WHERE user_key = 'u2@example.test'").fetchone()[0], "send")

    def test_a_new_stage_is_a_new_verdict_and_a_new_job(self):
        self.fill([person(1)])
        self.fill([person(1, stage="team_review")])
        self.assertEqual(self.db.execute("SELECT COUNT(*), COUNT(DISTINCT stage) FROM jobs").fetchone(), (2, 2))

    def test_the_decision_is_fast_enough_to_matter(self):
        bq.load_people(self.db, bq.synth_people(20000))
        d = bq.decide(self.db)
        self.assertEqual(d["people"], 20000)
        self.assertGreater(d["decisions_per_min"], 100_000)  # the target is 1,000; a loop would not get here


class DatabaseRefusesTests(Base):
    def test_no_job_without_a_send_verdict(self):
        self.fill([person(1, hold="unmeasured")])
        with self.assertRaisesRegex(sqlite3.IntegrityError, "no send verdict"):
            self.db.execute("INSERT INTO jobs (idem_key, user_key, stage, message_class, route, state, enqueued_at) "
                            "VALUES ('k', 'u1@example.test', 'doc_received', 'status-doc-received', 'email', "
                            "'queued', 1)")
        with self.assertRaises(sqlite3.IntegrityError):  # and none for a person with no verdict at all
            self.db.execute("INSERT INTO jobs (idem_key, user_key, stage, message_class, route, state, enqueued_at) "
                            "VALUES ('k', 'nobody', 'doc_received', 'status-doc-received', 'email', 'queued', 1)")

    def test_sent_needs_a_recorded_attempt_and_settled_rows_are_final(self):
        self.fill([person(1)])
        for sql, why in (
                ("UPDATE jobs SET state='sent'", "sent without a recorded attempt"),
                ("UPDATE jobs SET state='attempted'", "attempted without a claim"),
                ("DELETE FROM jobs", "never deleted"),
                ("UPDATE verdicts SET verdict='hold'", "send verdict is final"),
                ("DELETE FROM verdicts", "send verdict is final")):
            with self.assertRaisesRegex(sqlite3.IntegrityError, why):
                self.db.execute(sql)
        self.run_email(lambda p: {"http": 200, "status": "sent", "id": "m1"})
        self.assertEqual(self.job(1)[0], "sent")
        with self.assertRaisesRegex(sqlite3.IntegrityError, "never rewritten"):
            self.db.execute("UPDATE jobs SET state='queued'")
        with self.assertRaisesRegex(sqlite3.IntegrityError, "append-only"):
            self.db.execute("DELETE FROM job_events")

    def test_second_job_for_the_same_user_and_stage_is_refused(self):
        self.fill([person(1)])
        with self.assertRaises(sqlite3.IntegrityError):
            self.db.execute("INSERT INTO jobs (idem_key, user_key, stage, message_class, route, state, enqueued_at) "
                            "VALUES ('other-key', 'u1@example.test', 'doc_received', 'status-doc-received', "
                            "'email', 'queued', 1)")


class ClaimAndRecoverTests(Base):
    def test_two_workers_never_claim_the_same_job(self):
        self.fill([person(i) for i in range(40)])
        other = bq.connect(self.path)
        self.addCleanup(other.close)
        a = bq.claim(self.db, "a", 15, route="email")
        b = bq.claim(other, "b", 15, route="email")
        c = bq.claim(self.db, "a", 15, route="email")
        keys = [j.idem_key for j in a + b + c]
        self.assertEqual((len(a), len(b), len(c), len(set(keys))), (15, 15, 10, 40))

    def test_a_claim_that_never_attempted_goes_back_to_the_queue(self):
        self.fill([person(1)])
        bq.claim(self.db, "dead", 5, route="email", lease_s=10)
        self.assertEqual(bq.recover(self.db), {"requeued": 0, "represent": 0, "uncertain": 0})  # lease still live
        self.assertEqual(bq.recover(self.db, now=time.time() + 11)["requeued"], 1)
        self.assertEqual(self.job(1)[0], "queued")

    def _attempt_and_die(self):
        jobs = bq.claim(self.db, "dead", 5, route="email", lease_s=10)
        bq.mark_attempted(self.db, bq.precheck(self.db, jobs, "dead", lambda j: ""), "dead", lease_s=10)

    def test_attempted_with_no_outcome_is_presented_again_only_where_the_provider_dedupes(self):
        self.fill([person(1)])
        self._attempt_and_die()
        self.assertEqual(bq.recover(self.db, now=time.time() + 11)["represent"], 1)
        _, ex = self.run_email(lambda p: {"http": 200, "status": "sent", "id": "m-first", "duplicate": True})
        self.assertEqual(self.job(1)[:3], ("sent", "duplicate", "m-first"))
        self.assertEqual(ex.seen[0]["idempotency_key"], "credit-status:status-doc-received:1001")

    def test_attempted_with_no_outcome_is_never_sent_again_where_it_does_not(self):
        policy = json.loads(json.dumps(POLICY))
        policy["routes"]["email"]["idempotent"] = False
        bq.apply_policy(self.db, policy)
        self.fill([person(1)])
        self._attempt_and_die()
        self.assertEqual(bq.recover(self.db, now=time.time() + 11)["uncertain"], 1)
        done, ex = self.run_email(lambda p: {"http": 200, "status": "sent", "id": "m2"})
        self.assertEqual((done["claimed"], ex.seen, self.job(1)[:2]), (0, [], ("uncertain", "attempted_no_outcome")))
        with self.assertRaises(ValueError):
            bq.resolve(self.db, "x", "sent", by=" ")
        key = self.db.execute("SELECT idem_key FROM jobs").fetchone()[0]
        self.assertTrue(bq.resolve(self.db, key, "sent", by="Nick", note="seen in the provider log"))
        self.assertEqual(self.job(1)[0], "sent")

    def test_presentations_are_bounded(self):
        self.fill([person(1)])
        for _ in range(bq.MAX_ATTEMPTS):
            self._attempt_and_die()
            bq.recover(self.db, now=time.time() + 11)
        self.assertEqual(self.job(1)[:2], ("uncertain", "unconfirmed_after_max_attempts"))

    def test_a_represented_job_told_by_another_sender_is_uncertain_and_not_presented_again(self):
        self.fill([person(1)])
        self._attempt_and_die()
        self.assertEqual(bq.recover(self.db, now=time.time() + 11)["represent"], 1)
        bq.load_people(self.db, [person(1, told=["doc_received"])])
        _, ex = self.run_email(lambda p: {"http": 200, "status": "sent", "id": "m"})
        self.assertEqual((ex.seen, self.job(1)[:2]), ([], ("uncertain", "already_told")))  # ours may have landed

    def test_a_represented_job_whose_person_moved_on_is_uncertain_not_rejected(self):
        self.fill([person(1), person(2)])
        jobs = bq.claim(self.db, "dead", 1, route="email", lease_s=10)  # one of the two, whichever sorts first
        tried = int(jobs[0].user_key[1:].split("@")[0])
        bq.mark_attempted(self.db, bq.precheck(self.db, jobs, "dead", lambda j: ""), "dead", lease_s=10)
        bq.recover(self.db, now=time.time() + 11)
        bq.load_people(self.db, [person(1, stage="team_review"), person(2, stage="team_review")])
        _, ex = self.run_email(lambda p: {"http": 200, "status": "sent", "id": "m"}, max_jobs=2)
        self.assertEqual([p["to"]["user_id"] for p in ex.seen if "doc_received" in p["key"]], [])
        self.assertEqual(self.job(tried)[:2], ("uncertain", "stale_stage"))     # it may have been sent
        self.assertEqual(self.job(3 - tried)[:2], ("rejected", "stale_stage"))  # it never left


class EmailRouteTests(Base):
    def test_a_body_with_no_verdict_is_never_handed_to_the_sender(self):
        self.fill([person(1), person(2)])
        gate = Gate(hold="pending_review")
        done, ex = self.run_email(lambda p: {"http": 200, "status": "sent", "id": "m"}, gate=gate)
        self.assertEqual(ex.seen, [])
        self.assertEqual(len(gate.asked), 1)  # the same bytes in one batch are asked once
        self.assertEqual(gate.asked[0][2], f"email-template:credit_status_doc_received@{PIN}")
        state, reason, _, not_before, attempts = self.job(1)
        self.assertEqual((state, attempts), ("queued", 0))  # a hold is a log, never a lock, and burns no attempt
        self.assertIn("copy_review_hold: pending_review", reason)
        self.assertGreater(not_before, time.time() + 60)
        self.assertNotIn("attempted", self.events(1))
        self.assertEqual(done["released"], 2)

    def test_an_unpinned_template_sends_nothing(self):
        policy = json.loads(json.dumps(POLICY))
        policy["routes"]["email"]["template_sha256"] = {}
        self.fill([person(1)])
        ex = Exec(lambda p: {"http": 200, "status": "sent", "id": "m"})
        bq.work(self.db, bq.EmailRoute(policy, exec_batch=ex, gate=Gate()), "w1", kill_file=self.kill)
        self.assertEqual(ex.seen, [])
        self.assertIn("email_template_unpinned:credit_status_doc_received", self.job(1)[1])

    def test_a_hold_placed_after_the_verdict_stops_the_send(self):
        self.fill([person(1)])
        bq.load_people(self.db, [person(1, hold="lens:band_red")])
        _, ex = self.run_email(lambda p: {"http": 200, "status": "sent", "id": "m"})
        self.assertEqual((ex.seen, self.job(1)[:2]), ([], ("queued", "hold:lens:band_red")))

    def test_a_stage_another_sender_told_after_the_job_was_queued_is_never_sent(self):
        self.fill([person(1), person(2)])
        self.assertEqual(self.states(), {"queued": 2})
        bq.load_people(self.db, [person(1, told=["doc_received"])])  # another sender got there first
        self.assertEqual(bq.decide(self.db)["verdicts"], {"send:predicates_clear": 2})  # a send verdict is final
        _, ex = self.run_email(lambda p: {"http": 200, "status": "sent", "id": "m"}, max_jobs=2)
        self.assertEqual([p["to"]["user_id"] for p in ex.seen], ["1002"])
        self.assertEqual((self.job(1)[:2], self.job(2)[0]), (("rejected", "already_told"), "sent"))
        self.assertEqual(self.events(1), ["claimed", "rejected"])

    def test_each_answer_is_recorded_as_what_the_gateway_said(self):
        self.fill([person(i) for i in range(1, 6)])
        answers = {"1001": {"http": 200, "status": "sent", "id": "m1"},
                   "1002": {"http": 200, "status": "suppressed", "reason": "unsubscribed"},
                   "1003": {"http": 503, "reason": "upstream"},
                   "1004": None,
                   "1005": {"status": "not_sent", "reason": "template_pin_mismatch"}}
        done, ex = self.run_email(lambda p: answers[p["to"]["user_id"]], max_jobs=5)
        self.assertEqual({k: done[k] for k in ("sent", "rejected", "pending", "defer")},
                         {"sent": 1, "rejected": 1, "pending": 2, "defer": 1})
        self.assertEqual(self.job(1)[:3], ("sent", "", "m1"))
        self.assertEqual(self.job(2)[0], "rejected")
        self.assertEqual((self.job(3)[0], self.job(4)[0]), ("attempted", "attempted"))  # may have landed
        self.assertEqual(self.job(5)[0], "queued")
        self.assertEqual(self.events(1), ["claimed", "attempted", "sent"])
        self.assertEqual(ex.seen[0]["_template_sha256"], PIN)
        self.assertEqual(ex.seen[0]["data"]["event"]["status_line"], "We have your document.")
        self.assertFalse(any(bq.verify(self.db).values()))

    def test_the_gateway_ceiling_parks_the_whole_route_until_the_next_utc_day(self):
        self.fill([person(i) for i in range(1, 8)])
        done, ex = self.run_email(lambda p: {"http": 200, "status": "would_send", "gate": "route_ceiling"}, batch=3)
        self.assertEqual((len(ex.seen), done["defer"], self.states()), (3, 3, {"queued": 7}))
        self.assertEqual(self.db.execute("SELECT not_before FROM routes WHERE route='email'").fetchone()[0],
                         bq.next_utc_midnight(time.time()))
        self.assertEqual(bq.claim(self.db, "w2", 5, route="email"), [])
        tomorrow = bq.next_utc_midnight(time.time()) + 1
        self.assertEqual(len(bq.claim(self.db, "w2", 5, route="email", now=tomorrow)), 5)

    def test_an_exec_that_dies_mid_batch_loses_nothing_and_resends_nothing(self):
        self.fill([person(i) for i in range(1, 7)])
        delivered: dict[str, str] = {}

        def gateway(p):  # at-most-once per idempotency_key, like send-gateway
            key = p["idempotency_key"]
            dup = key in delivered
            delivered.setdefault(key, f"m{len(delivered) + 1}")
            return {"http": 200, "status": "sent", "id": delivered[key], "duplicate": dup}

        def dies(p):
            if len(delivered) == 3:
                gateway(p)  # the fourth lands at the provider, and the answer never comes back
                raise OSError("exec died")
            return gateway(p)

        with self.assertRaises(OSError):
            self.run_email(dies, worker="dead", lease_s=10)
        self.assertEqual(self.states(), {"sent": 3, "attempted": 3})
        self.assertEqual(bq.recover(self.db, now=time.time() + 11)["represent"], 3)
        self.run_email(gateway, worker="next")
        self.assertEqual(self.states(), {"sent": 6})
        self.assertEqual(len(delivered), 6)
        dup = self.db.execute("SELECT COUNT(*) FROM jobs WHERE reason = 'duplicate'").fetchone()[0]
        self.assertEqual(dup, 1)  # the one the dead exec delivered was answered from the gateway's own record
        self.assertFalse(any(bq.verify(self.db).values()))


class ArmingTests(Base):
    def test_the_shipped_policy_is_unarmed_and_names_no_batch_chat_or_intercom(self):
        shipped = bq.load_policy()
        self.assertIs(shipped["enabled"], False)
        self.assertTrue(all(r.get("enabled") is False for r in shipped["routes"].values()))
        self.assertEqual([n for n, r in shipped["routes"].items() if r["batch_capable"]], ["email"])
        self.assertEqual([n for n, r in shipped["routes"].items() if r["idempotent"]], ["email"])
        self.assertEqual(shipped["routes"]["email"]["template_sha256"], {})
        self.assertIn("not true", bq._armed(shipped, "email"))
        self.assertEqual(bq._armed(POLICY, "email"), "")
        self.assertNotEqual(bq._armed(POLICY, "chat"), "")

    def test_the_cli_sends_nothing_without_apply_or_with_an_unarmed_policy(self):
        self.fill([person(1)])
        for extra in ([], ["--apply"]):
            res = subprocess.run([sys.executable, str(SCRIPT), "work", "--db", self.path, *extra],
                                 capture_output=True, text=True, timeout=60, check=False)
            self.assertEqual(res.returncode, 2, res.stderr)
            self.assertIn("REFUSED", res.stderr)
        self.assertEqual(self.states(), {"queued": 1})

    def test_the_kill_file_stops_a_worker_before_it_claims(self):
        self.fill([person(1)])
        Path(self.kill).write_text("stop")
        done, ex = self.run_email(lambda p: {"http": 200, "status": "sent", "id": "m"})
        self.assertTrue(done["killed"])
        self.assertEqual((ex.seen, self.states()), ([], {"queued": 1}))


class KillNineTests(unittest.TestCase):
    def test_kill_nine_mid_batch_leaves_no_duplicate_and_no_orphan(self):
        res = subprocess.run([sys.executable, str(SCRIPT), "chaos", "--jobs", "300", "--workers", "4",
                              "--batch", "10", "--latency-ms", "3"], capture_output=True, text=True,
                             timeout=600, check=False)
        self.assertEqual(res.returncode, 0, res.stdout[-2000:] + res.stderr[-2000:])
        rep = json.loads(res.stdout)
        for mode in ("provider_dedupes", "provider_keeps_no_key"):
            r = rep[mode]
            self.assertGreater(r["in_flight_at_kill"], 0, mode)
            self.assertEqual(r["provider"]["keys_delivered_twice"], 0, mode)
            self.assertFalse(any(r["verify"].values()), mode)
        self.assertEqual(rep["provider_dedupes"]["final_states"], {"sent": rep["provider_dedupes"]["jobs"]})
        self.assertEqual(rep["provider_keeps_no_key"]["presented_again"], 0)


if __name__ == "__main__":
    unittest.main()
