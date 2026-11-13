#!/usr/bin/env python3
"""[key=apply-pipeline] the pooled apply at its production width, with real threads and a real ledger.

test_uvn_status.py pins WHAT each user is checked against, one user in flight. This file pins what only exists with
several users in flight: nobody is sent two notes, a cap is exact across workers, an outcome is never lost, and one
worker's stop does not strand the others. The gate here claims in the ledger the way the real gate does
(`verify_ledger.claim`, BEGIN IMMEDIATE), holds each call open long enough for calls to overlap, and counts how many
were open at once, so a test that passes with the pool idle fails on `peak`."""
from __future__ import annotations

import credit_test_env  # noqa: F401,E402 - first: test logs + the signed-head harness never reach production

import json
import re
import sqlite3
import subprocess
import sys
import tempfile
import threading
import time
import unittest
import unittest.mock
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
sys.path.insert(0, str(Path(__file__).resolve().parent))

from credit_review import uvn_status, verify_ledger, verify_notify  # noqa: E402
import test_uvn_status as base  # noqa: E402 - the replica / proof fakes (it also pins the width to 1: undone in setUp)

NOW = base.NOW
DAY = NOW.strftime("%Y-%m-%d")
WIDTH = 8
CAMPAIGN = "uvn-status"


class PoolGate:
    """The gate, thread-safe: claim, then sent. `script[user id]` = 'unknown' (claims, then fails the post check and
    leaves the claim `attempted`) or 'defer' (an Intercom deferral, no claim). `on_call(uid)` runs inside the call."""

    def __init__(self, ledger: str, hold: float = 0.04, script: dict | None = None, on_call=None) -> None:
        self.ledger, self.hold, self.script, self.on_call = ledger, hold, script or {}, on_call
        self.lock = threading.Lock()
        self.entered: list[str] = []        # every user a gate call was opened for
        self.posted: list[str] = []
        self.flying: list[str] = []
        self.peak = 0
        self.same_user_overlap = 0

    def __call__(self, argv):
        payload = json.loads(Path(argv[argv.index("--credits-file") + 1]).read_text())
        if "--thread-contact" in argv:
            return subprocess.CompletedProcess(
                argv, 0, "THREAD_CONTACT " + json.dumps({"contacts": 1, "role": "user", "external_id": ""}), "")
        uid = str(payload["user"]["id"])
        with self.lock:
            self.same_user_overlap += uid in self.flying
            self.flying.append(uid)
            self.entered.append(uid)
            self.peak = max(self.peak, len(self.flying))
        try:
            if self.on_call is not None:
                self.on_call(uid)
            if self.hold:
                time.sleep(self.hold)
            what = self.script.get(uid)
            if what == "defer":
                return subprocess.CompletedProcess(argv, 3, "DEFERRED messaged_7d credits=1 (we replied)", "")
            db = verify_ledger.connect(self.ledger)
            try:
                c = verify_ledger.claim(db, campaign=CAMPAIGN, user_key=payload["user"]["email"], day=DAY,
                                        request_ids=[r["request_id"] for r in payload["credits"]], message_type="email",
                                        approved_by="U7RP6HKUZ", approval_ref="ref", now=NOW, user_id=uid)
                if c["result"] != "claimed":
                    return subprocess.CompletedProcess(argv, 0, "SKIPPED already-notified credits=1", "")
                if what == "unknown":
                    verify_ledger.finalize(db, message_row=c["message_row"], status="attempted",
                                           reason="unverified response")
                    return subprocess.CompletedProcess(
                        argv, 4, "", "POST NOT VERIFIED: expected an admin_message; left CLAIMED")
                verify_ledger.finalize(db, message_row=c["message_row"], status="sent", message_id=f"m{uid}")
            finally:
                db.close()
            with self.lock:
                self.posted.append(uid)
            return subprocess.CompletedProcess(argv, 0, "POSTED email message=1 credits=1", "")
        finally:
            with self.lock:
                self.flying.remove(uid)


def ledger_rows(path: str) -> list[tuple[str, str]]:
    """(account, status) of every note claimed today, attempted or sent."""
    if not Path(path).exists():
        return []
    db = sqlite3.connect(path)
    try:
        return [(str(a), str(s)) for a, s in db.execute(
            "SELECT account_id, status FROM verify_messages WHERE day = ? AND status IN ('attempted', 'sent') "
            "ORDER BY id", (DAY,))]
    finally:
        db.close()


class PooledApplyTests(unittest.TestCase):
    """uvn_status.run(), WIDTH users in flight."""

    def setUp(self):
        self.dir = Path(tempfile.mkdtemp(prefix="pool-"))
        self.list = self.dir / "list.json"
        self.proof = self.dir / "proof.json"
        self.ledger = str(self.dir / "ledger.sqlite3")
        base.proof(self.proof)
        wide = unittest.mock.patch.object(verify_notify, "PIPELINE_WORKERS", WIDTH)
        wide.start()
        self.addCleanup(wide.stop)

    def run_(self, n: int, gate: PoolGate | None = None, **kw):
        users = [{"user_id": u, "paid": True, "skip": None, "request_ids": [f"r{u}"]} for u in range(1, n + 1)]
        self.list.write_text(json.dumps({"generated_at": base.iso(2), "users": users}))
        gate = gate or PoolGate(self.ledger)
        wrapper = self.dir / "gate.sh"
        wrapper.write_text("readonly UVN_STATUS_COPY_APPROVED=1\nreadonly CREDIT_HOLD_STATUS_COPY_APPROVED=0\n")
        rep = uvn_status.run(list_path=str(self.list), segment="paid", mode="apply", max_users=kw.pop("max_users", n),
                             ledger_path=self.ledger, proof_path=str(self.proof),
                             query=kw.pop("query", base.replica(range(1, n + 1))), runner=gate, wrapper=str(wrapper),
                             now=NOW, pace_seconds=kw.pop("pace_seconds", 0), **kw)
        return rep, gate

    def test_several_users_are_in_flight_at_once_and_each_is_sent_exactly_one_note(self):
        rep, gate = self.run_(40)
        rows = ledger_rows(self.ledger)
        self.assertEqual(rep.halted, "")
        self.assertEqual(rep.sent_notes, 40)
        self.assertEqual(sorted(int(a) for a, _ in rows), list(range(1, 41)), "one row per user, nobody twice")
        self.assertEqual({s for _, s in rows}, {"sent"})
        self.assertGreater(gate.peak, 1, "the pool never engaged: this is the serial walk again")
        self.assertLessEqual(gate.peak, WIDTH, "more users in flight than the pool's bound")
        self.assertEqual(gate.same_user_overlap, 0, "one user was in two workers at once")

    def test_the_daily_cap_is_exact_across_workers_and_nobody_past_it_reaches_the_gate(self):
        with unittest.mock.patch.object(uvn_status, "DAILY_MAX", 5):
            rep, gate = self.run_(40)
        self.assertEqual(len(ledger_rows(self.ledger)), 5)
        self.assertEqual(rep.sent_notes, 5)
        self.assertEqual(len(gate.entered), 5, "a user past the cap was handed to the gate")
        left = sorted(int(o["user"]) for o in rep.outcomes if o.get("reason") == "daily_cap")
        self.assertEqual(left, list(range(6, 41)), "every user the cap left is a row, so the run balances")

    def test_the_run_size_is_exact_across_workers(self):
        rep, gate = self.run_(40, max_users=7)
        self.assertEqual((rep.sent_notes, len(ledger_rows(self.ledger)), len(gate.entered)), (7, 7, 7))

    def test_the_segment_cap_is_exact_across_workers(self):
        rep, gate = self.run_(40, segment_daily_cap=6)
        self.assertEqual((rep.sent_notes, len(ledger_rows(self.ledger)), len(gate.entered)), (6, 6, 6))
        self.assertEqual(uvn_status.segment_used_today(self.ledger, CAMPAIGN, "paid", DAY), 6)

    def test_a_claim_left_without_a_verified_post_is_charged_to_the_cap_per_user(self):
        # users 2 and 5 claim and then fail the post check: their rows stay `attempted` and each uses a cap slot
        with unittest.mock.patch.object(uvn_status, "DAILY_MAX", 6):
            rep, gate = self.run_(40, gate=PoolGate(self.ledger, script={"2": "unknown", "5": "unknown"}))
        rows = ledger_rows(self.ledger)
        self.assertEqual(len(rows), 6, "the cap counts every claim, verified or not")
        self.assertEqual(sorted(int(a) for a, s in rows if s == "attempted"), [2, 5])
        self.assertEqual((rep.sent_notes, rep.outcome_unknown), (4, 2))
        self.assertEqual(len(gate.entered), 6)

    def test_a_user_the_gate_defers_gives_the_slot_back_and_the_next_user_takes_it(self):
        # the cap is charged for a user in flight as if sent; a deferral frees that slot instead of wasting it
        with unittest.mock.patch.object(uvn_status, "DAILY_MAX", 5):
            rep, gate = self.run_(40, gate=PoolGate(self.ledger, script={"1": "defer", "3": "defer"}))
        self.assertEqual(sorted(int(a) for a, _ in ledger_rows(self.ledger)), [2, 4, 5, 6, 7])
        self.assertEqual(rep.sent_notes, 5)

    def test_slots_that_go_while_users_are_in_flight_are_not_handed_out_twice(self):
        """The cap has room for 10 and ten users are picked. While user 1 is being sent, four slots go to notes this
        walk did not send, and users 2-8 are still in flight. Each of those seven may yet use a slot, so the five
        slots left are all spoken for: users 9 and 10 wait, and are never started once the seven have answered.

        What the pool cannot do is call back a user already in flight, so this run ends 2 over the cap. Only a sender
        outside the group lock can cause that: `uvn_status.run` and `need_asks` both hold it for the whole apply."""
        release = threading.Event()
        ledger = self.ledger
        gate = PoolGate(self.ledger)

        def on_call(uid):
            if uid != "1":
                release.wait(30)
                return
            deadline = time.monotonic() + 30
            while len(gate.entered) < WIDTH and time.monotonic() < deadline:
                time.sleep(0.01)                         # the slots go only once the pool is full: users 1-8 in flight
            db = verify_ledger.connect(ledger)
            try:
                for k in (91, 92, 93, 94):
                    c = verify_ledger.claim(db, campaign=CAMPAIGN, user_key=f"o{k}@x.com", day=DAY,
                                            request_ids=[f"o{k}"], message_type="email", approved_by="U",
                                            approval_ref="r", now=NOW, user_id=str(k))
                    verify_ledger.finalize(db, message_row=c["message_row"], status="sent", message_id=f"9{k}")
            finally:
                db.close()
            timer = threading.Timer(1.0, release.set)    # long after user 1 is recorded and user 9 has been asked about
            timer.daemon = True
            timer.start()
        gate.on_call = on_call
        with unittest.mock.patch.object(uvn_status, "DAILY_MAX", 10):
            rep, gate = self.run_(30, gate=gate)
        self.assertEqual(sorted(gate.entered, key=int), [str(i) for i in range(1, 9)],
                         "a user was started on a slot a user in flight could still use")
        self.assertEqual(rep.sent_notes, 8)
        self.assertEqual(len(ledger_rows(self.ledger)), 12)
        self.assertEqual(sorted(int(o["user"]) for o in rep.outcomes if o.get("reason") == "daily_cap"),
                         list(range(9, 31)))

    def test_a_user_held_by_the_send_time_read_never_reaches_the_gate_and_uses_no_slot(self):
        gone = {1, 2, 3}
        inner = base.replica(range(1, 13))

        def q(sql):
            m = re.search(r"IN \(([0-9,]+)\)", sql)
            ids = {int(x) for x in m.group(1).split(",")} if m else set()
            if "public.users" not in sql and len(ids) == 1 and ids <= gone:
                return []                       # resolved since the batch was built: the per-user re-read sees it
            return inner(sql)
        with unittest.mock.patch.object(uvn_status, "DAILY_MAX", 5):
            rep, gate = self.run_(12, query=q)
        self.assertEqual(sorted(int(a) for a, _ in ledger_rows(self.ledger)), [4, 5, 6, 7, 8])
        self.assertFalse(gone & {int(u) for u in gate.entered}, "a user whose request was resolved was messaged")
        self.assertEqual(rep.no_longer_uvn, 3)

    def test_a_proof_list_that_turns_unreadable_stops_the_starts_and_loses_no_outcome(self):
        proof = self.proof

        def spoil(uid):
            if uid == "5":
                proof.write_text("{not json")
        rep, gate = self.run_(40, gate=PoolGate(self.ledger, on_call=spoil))
        rows = ledger_rows(self.ledger)
        self.assertTrue(rep.halted)
        self.assertLess(len(gate.entered), 40, "the run went on after the proof list became unreadable")
        self.assertEqual(len(rows), rep.sent_notes, "a note landed that the report does not carry")
        self.assertEqual(sorted(a for a, _ in rows), sorted(gate.posted))

    def test_a_second_run_the_same_day_sends_nothing(self):
        self.run_(20)
        rep, gate = self.run_(20)
        self.assertEqual(rep.sent_notes, 0)
        self.assertEqual(len(ledger_rows(self.ledger)), 20)


def payloads(ids) -> list[dict]:
    return [{"user": {"id": str(i), "email": f"u{i}@x.com", "professional_id": base.pro(i)},
             "credits": [{"request_id": f"r{i}"}]} for i in ids]


class PipelineLoopTests(unittest.TestCase):
    """verify_notify.send_all() with a pipeline, driven directly."""

    def setUp(self):
        self.dir = Path(tempfile.mkdtemp(prefix="pipe-"))
        self.ledger = str(self.dir / "ledger.sqlite3")
        verify_ledger.connect(self.ledger).close()
        ident = unittest.mock.patch.object(verify_notify, "attach_identities", lambda ps, r: (ps, []))
        ident.start()
        self.addCleanup(ident.stop)

    def send(self, ps, gate, pipeline, **kw):
        rep = verify_notify.Report()
        verify_notify.send_all(ps, rep, mode="apply", runner=gate, extra=["--campaign", CAMPAIGN],
                               ledger_path=self.ledger, campaign=CAMPAIGN, pipeline=pipeline, **kw)
        return rep

    @staticmethod
    def open_pipeline(**kw):
        opts = {"admit": lambda p, in_flight: "go", "prepare": lambda p: p, "settle": lambda p, **facts: None,
                "workers": WIDTH}
        return verify_notify.ApplyPipeline(**{**opts, **kw})

    def test_a_user_listed_three_times_in_one_run_gets_one_gate_call(self):
        gate = PoolGate(self.ledger)
        rep = self.send(payloads([1, 2, 1, 3, 1, 4, 2]), gate, self.open_pipeline())
        self.assertEqual(sorted(gate.entered), ["1", "2", "3", "4"])
        self.assertEqual(gate.same_user_overlap, 0)
        self.assertEqual(rep.sent_notes, 4)

    def test_two_runs_racing_for_the_same_users_send_each_user_one_note(self):
        # the one-per-day rule is the ledger's (claim is BEGIN IMMEDIATE): two pools, sixteen workers, the same list
        gate = PoolGate(self.ledger)
        reps: list = []
        errors: list = []

        def one():
            try:
                reps.append(self.send(payloads(range(1, 31)), gate, self.open_pipeline()))
            except Exception as exc:  # noqa: BLE001 - surfaced by the assert below
                errors.append(exc)
        threads = [threading.Thread(target=one) for _ in range(2)]
        for t in threads:
            t.start()
        for t in threads:
            t.join(120)
        self.assertEqual(errors, [])
        rows = ledger_rows(self.ledger)
        self.assertEqual(sorted(int(a) for a, _ in rows), list(range(1, 31)), "one note per user across both runs")
        self.assertEqual(sum(r.sent_notes for r in reps), 30, "a run reported a note the ledger does not have")
        self.assertEqual(sorted(gate.posted, key=int), [str(i) for i in range(1, 31)])

    def test_the_pace_is_a_floor_between_two_starts_and_the_pool_does_not_divide_it(self):
        slept: list[float] = []
        real = time.sleep

        def sleep(s):
            slept.append(s)
            real(0)
        with unittest.mock.patch.object(verify_notify.time, "sleep", sleep):
            self.send(payloads(range(1, 11)), PoolGate(self.ledger, hold=0), self.open_pipeline(), pace_seconds=0.25)
        self.assertEqual([s for s in slept if s == 0.25], [0.25] * 9, "one whole pace before every start but the first")

    def test_wait_is_asked_again_after_a_result_so_no_user_is_refused_on_a_guess(self):
        # room for 3 notes. Users in flight are charged as sent; user 2 is deferred, so a fourth user gets that slot.
        done = {"n": 0}
        asked: list[tuple[str, int]] = []

        def admit(p, in_flight):
            asked.append((p["user"]["id"], in_flight))
            if done["n"] >= 3:
                return "stop"
            return "wait" if done["n"] + in_flight >= 3 else "go"

        def settle(p, *, gated, reached, read_failed):
            done["n"] += reached
        gate = PoolGate(self.ledger, script={"2": "defer"})
        walk = self.open_pipeline(admit=admit, settle=settle)
        rep = self.send(payloads(range(1, 11)), gate, walk)
        self.assertEqual(rep.sent_notes, 3)
        self.assertEqual(sorted(gate.entered, key=int), ["1", "2", "3", "4"])
        self.assertEqual(walk.unstarted, [str(i) for i in range(5, 11)], "the users the bound left, still owed")
        self.assertLessEqual(max(n for _, n in asked), 3, "more users in flight than the room allows")

    def test_one_users_failed_send_time_read_is_that_users_and_the_rest_are_sent(self):
        def prepare(p):
            if p["user"]["id"] == "3":
                raise RuntimeError("replica timed out")
            return p
        settled: dict[str, dict] = {}
        gate = PoolGate(self.ledger)
        rep = self.send(payloads(range(1, 9)), gate,
                        self.open_pipeline(prepare=prepare, settle=lambda p, **f: settled.update({p["user"]["id"]: f})))
        self.assertEqual(sorted(gate.entered, key=int), ["1", "2", "4", "5", "6", "7", "8"])
        self.assertEqual(rep.sent_notes, 7)
        self.assertTrue(settled["3"]["read_failed"])
        self.assertEqual(sorted(settled, key=int), [str(i) for i in range(1, 9)], "every started user is settled once")

    def test_a_bound_that_cannot_be_read_stops_the_starts_and_records_the_users_in_flight(self):
        def admit(p, in_flight):
            if p["user"]["id"] == "5":
                raise sqlite3.OperationalError("database is locked")
            return "go"
        gate = PoolGate(self.ledger)
        walk = self.open_pipeline(admit=admit)
        rep = self.send(payloads(range(1, 13)), gate, walk)
        self.assertIn("could not be read", rep.halted)
        self.assertEqual(sorted(gate.entered, key=int), ["1", "2", "3", "4"])
        self.assertEqual((rep.sent_notes, len(ledger_rows(self.ledger))), (4, 4))
        self.assertEqual(walk.unstarted, [str(i) for i in range(5, 13)])

    def test_a_held_users_report_changes_run_on_the_callers_thread(self):
        main = threading.get_ident()
        ran: list[int] = []

        def prepare(p):
            if int(p["user"]["id"]) % 2:
                return verify_notify.Held(apply=lambda: ran.append(threading.get_ident()))
            return p
        rep = self.send(payloads(range(1, 13)), PoolGate(self.ledger), self.open_pipeline(prepare=prepare))
        self.assertEqual(ran, [main] * 6, "a worker wrote to the report")
        self.assertEqual(rep.sent_notes, 6)


if __name__ == "__main__":
    unittest.main()
