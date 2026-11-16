#!/usr/bin/env python3
"""The bulk first ask by email (scripts/credit_review/bulk_asks.py; docs/credit-verification/bulk-asks.md).

What is pinned here: the ramp's judge (floor, doubling only after a clean, measured window, holds on bounce and
complaint rates that stand for `rate_hold_s`), that a tick's clock is its health sample's own time (the false
`health_not_counting_our_sends` hold), the audience order and its drops, an end-to-end rehearsal with zero
duplicates at every layer, that a seeded rehearsal never writes its seed, that the ledger claim is the only commit
point (one `derive` pass makes every job and outcome from it, and a kill at every step of a tick, in a child
process, ends with the person sent once or offered again), and that the verify ledger's per-user reads stay on an
index (the cost of every claim). Stdlib only.
"""
from __future__ import annotations

import dataclasses
import hashlib
import json
import os
import sqlite3
import subprocess
import sys
import tempfile
import time
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts" / "credit_review"))
sys.path.insert(0, str(ROOT / "scripts"))
import bulk_asks as ba  # noqa: E402
import bulk_queue as bq  # noqa: E402
from credit_review import verify_ledger as vl  # noqa: E402

CFG = {"floor_per_min": 100, "max_per_min": 1000, "factor": 2, "window_s": 600, "health_lag_s": 300,
       "min_judged": 50, "hard_bounce_max": 0.01, "complaint_max": 0.001, "soft_bounce_max": 0.10,
       "rate_hold_s": 3600}


def S(at, sent, hard=0, soft=0, complained=0, readable=True, paused=False):
    return ba.Sample(at, readable, sent, hard, soft, complained, paused)


def Q(**over):
    q = {"uncertain": 0, "blocked_until": 0, "sent_since_step": 0, "sent_before_lag": 0, "backlog": 0}
    q.update(over)
    return q



class JudgeTests(unittest.TestCase):
    def test_a_first_minute_starts_at_the_floor(self):
        v = ba.judge(CFG, 0, 0, [S(0, 0)], Q(), 0)
        self.assertEqual((v.rate, v.state, v.reason), (100, "ramping", "start_at_floor"))

    def test_nothing_doubles_before_the_window_and_its_lag_have_passed(self):
        v = ba.judge(CFG, 100, 0, [S(0, 0), S(800, 800)], Q(sent_since_step=800, sent_before_lag=500), 800)
        self.assertEqual((v.rate, v.reason), (100, "window_open"))

    def test_a_clean_measured_window_doubles(self):
        v = ba.judge(CFG, 100, 0, [S(0, 0), S(960, 1000)], Q(sent_since_step=1000, sent_before_lag=1000), 960)
        self.assertEqual((v.rate, v.reason, v.step_at), (200, "clean_window", 960))

    def test_never_past_the_top(self):
        v = ba.judge(CFG, 800, 0, [S(0, 0), S(960, 9000)], Q(sent_since_step=9000, sent_before_lag=9000), 960)
        self.assertEqual(v.rate, 1000)

    def test_a_window_that_did_not_reach_its_rate_does_not_double(self):
        v = ba.judge(CFG, 100, 0, [S(0, 0), S(960, 600)], Q(sent_since_step=600, sent_before_lag=600), 960)
        self.assertEqual((v.rate, v.reason), (100, "rate_not_reached"))

    def test_hard_bounces_over_the_bar_hold(self):
        v = ba.judge(CFG, 400, 0, [S(0, 0), S(300, 1000, hard=11)], Q(sent_before_lag=900), 300)
        self.assertEqual((v.rate, v.state), (0, "held"))
        self.assertTrue(v.reason.startswith("hard_bounce:11/1000"))

    def test_complaints_and_soft_bounces_hold(self):
        for kw, name in (({"complained": 2}, "complaint"), ({"soft": 101}, "soft_bounce")):
            v = ba.judge(CFG, 400, 0, [S(0, 0), S(300, 1000, **kw)], Q(sent_before_lag=900), 300)
            self.assertTrue(v.reason.startswith(name), v)

    def test_a_rate_hold_stands_for_rate_hold_s_then_restarts_at_the_floor(self):
        held = "hard_bounce:11/1000"
        v = ba.judge(CFG, 0, 1000, [S(1000, 0), S(2000, 0)], Q(), 2000, held_for=held)
        self.assertEqual((v.rate, v.reason), (0, held))
        v = ba.judge(CFG, 0, 1000, [S(1000, 0), S(4700, 0)], Q(), 4700, held_for=held)
        self.assertEqual((v.rate, v.reason), (100, "start_at_floor"))

    def test_unreadable_paused_refused_and_uncertain_all_hold(self):
        self.assertEqual(ba.judge(CFG, 100, 0, [S(0, 0, readable=False)], Q(), 0).reason, "health_unreadable")
        self.assertEqual(ba.judge(CFG, 100, 0, [], Q(), 0).reason, "health_unreadable")
        self.assertEqual(ba.judge(CFG, 100, 0, [S(0, 0, paused=True)], Q(), 0).reason, "route_paused")
        self.assertEqual(ba.judge(CFG, 100, 0, [S(0, 0)], Q(blocked_until=50), 10).reason, "route_refused_batch_send")
        self.assertEqual(ba.judge(CFG, 100, 0, [S(0, 0)], Q(uncertain=1), 0).reason, "uncertain_jobs:1")

    def test_a_health_read_that_does_not_count_our_sends_holds(self):
        v = ba.judge(CFG, 400, 0, [S(0, 500), S(300, 500)], Q(sent_before_lag=400), 300)
        self.assertEqual(v.reason, "health_not_counting_our_sends:0/400")

    def test_a_rate_hold_stands_across_an_unreadable_sample(self):
        with tempfile.TemporaryDirectory() as tmp:
            w = World(tmp, people=0)

            def at(t, s):
                return ba.tick(w.rdb, w.qdb, w.policy, health=lambda: s, lane=w.lane, now=t)

            self.assertEqual(at(1000.0, S(1000.0, 0))["state"], "ramping")
            held = at(1600.0, S(1600.0, 1000, hard=11))
            self.assertEqual((held["state"], held["reason"]), ("held", "hard_bounce:11/1000"))
            self.assertEqual(at(1700.0, S(1700.0, 0, readable=False))["reason"], "health_unreadable")
            still = at(1800.0, S(1800.0, 1000))
            self.assertEqual((still["rate"], still["state"]), (0, "held"))
            self.assertTrue(still["reason"].startswith("hard_bounce"), still)


class TickClockTests(unittest.TestCase):
    """A tick's `now` is its health sample's time. Sampling after the settle stamped a late read with the tick's
    early clock: the next minute saw no new sends against 400 the queue had made, and held (2026-11-15)."""

    def test_the_tick_runs_on_the_sample_clock(self):
        with tempfile.TemporaryDirectory() as tmp:
            w = World(tmp, people=0)
            order = []

            def health():
                order.append("health")
                return S(1234.5, 0)

            attempted = w.lane.attempted
            lane = dataclasses.replace(w.lane, attempted=lambda: order.append("ledger") or attempted())
            t = ba.tick(w.rdb, w.qdb, w.policy, health=health, lane=lane)
            self.assertEqual(t["at"], 1234.5)
            self.assertEqual(order[:2], ["health", "ledger"])
            self.assertEqual(w.rdb.execute("SELECT at FROM samples").fetchone()[0], 1234.5)
            self.assertEqual(w.rdb.execute("SELECT at, step_at FROM ticks").fetchone()[:], (1234.5, 1234.5))


class SelectTests(unittest.TestCase):
    POLICY = {"stage": "ask", "body": "b", "subject": "s", "template_data": {}}

    @staticmethod
    def acct(**over):
        a = {"email": "x@example.invalid", "email_confirmed": True, "email_owners": 1, "hold": "",
             "proof_on_file": False, "asked_before": False, "paid": False}
        a.update(over)
        return a

    def test_never_asked_first_then_paid_then_user_id_and_one_row_per_user(self):
        plan = [{"outcome": "ask", "user_id": u, "request_id": f"R-{u}-{k}"} for u in (1, 2, 3, 4) for k in (1, 2)]
        accounts = {"1": self.acct(email="a@x.invalid", asked_before=True, paid=True),
                    "2": self.acct(email="b@x.invalid"),
                    "3": self.acct(email="c@x.invalid", paid=True),
                    "4": self.acct(email="d@x.invalid", asked_before=True)}
        people, dropped = ba.select(plan, accounts, self.POLICY)
        self.assertEqual([p["user_id"] for p in people], ["3", "2", "1", "4"])
        self.assertEqual(people[0]["request_ids"], ["r-3-1", "r-3-2"])
        self.assertEqual(dropped, {})

    def test_an_unmeasured_fact_drops_and_never_reads_as_clear(self):
        plan = [{"outcome": "ask", "user_id": u, "request_id": f"r{u}"} for u in (1, 2, 3)]
        accounts = {"1": self.acct(), "2": {k: v for k, v in self.acct().items() if k != "hold"}}
        accounts["1"]["paid"] = None
        people, dropped = ba.select(plan, accounts, self.POLICY)
        self.assertEqual(people, [])
        self.assertEqual(dropped, {"unmeasured:account": 1, "unmeasured:hold": 1, "unmeasured:paid": 1})

    def test_holds_proof_on_file_and_unusable_addresses_drop(self):
        plan = [{"outcome": "ask", "user_id": u, "request_id": f"r{u}"} for u in range(1, 7)]
        plan.append({"outcome": "ask", "user_id": 7, "request_id": "r7", "reason_code": ba.PROOF_ON_FILE_REASON})
        plan.append({"outcome": "approve", "user_id": 8, "request_id": "r8"})
        accounts = {"1": self.acct(hold="fraud"), "2": self.acct(proof_on_file=True), "3": self.acct(email=""),
                    "4": self.acct(email_confirmed=False), "5": self.acct(email_owners=2), "6": self.acct(),
                    "7": self.acct(), "8": self.acct()}
        people, dropped = ba.select(plan, accounts, self.POLICY)
        self.assertEqual([p["user_id"] for p in people], ["6"])
        self.assertEqual(dropped, {"email_shared": 1, "email_unconfirmed": 1, "hold": 1, "no_email": 1,
                                   "proof_on_file": 2})


class RehearsalTests(unittest.TestCase):
    RAMP = dict(CFG, window_s=1.0, health_lag_s=0.2)

    def test_the_whole_path_ramps_and_nothing_is_sent_twice(self):
        rep = ba.rehearse(4000, 2, tick_s=1.0, minutes_at_max=1, ramp=self.RAMP, latency_ms=0.0)
        self.assertEqual({k: v for k, v in rep["verify"].items() if v}, {})
        self.assertEqual(rep["provider"]["keys_delivered_twice"], 0)
        self.assertNotIn("held", {t["state"] for t in rep["ticks"]}, rep["ticks"])
        self.assertEqual(max(t["rate"] for t in rep["ticks"]), 1000)
        sent = rep["provider"]["deliveries"]
        self.assertEqual(sum(m["sent"] for m in rep["ledger_per_minute"]), sent)
        self.assertEqual(sum(m["claimed"] for m in rep["ledger_per_minute"]), sent)
        self.assertEqual(rep["seeded"]["journal_mode"], "wal")
        self.assertEqual((rep["stop_reason"], ba.rehearse_exit(rep)), ("", 0))

    def test_a_seeded_rehearsal_reads_its_seed_and_never_writes_it(self):
        with tempfile.TemporaryDirectory() as tmp:
            seed = os.path.join(tmp, "seed.sqlite3")
            db = vl.connect(seed)
            vl.claim(db, user_key="real@example.invalid", day="2026-11-01", request_ids=["real-1"],
                     message_type="email", approved_by="fable-ruling-0000-test", approval_ref="test",
                     campaign="uvn-status", user_id="42", approver_kind=vl.APPROVER_RULING,
                     approval_id="fable-ruling-0000-test", template_sha256="0" * 64)
            db.close()
            before = hashlib.sha256(Path(seed).read_bytes()).hexdigest()
            rep = ba.rehearse(300, 1, tick_s=0.5, minutes_at_max=1, ramp=self.RAMP, latency_ms=0.0,
                              seed_ledger=seed, tmp_root=tmp)
            self.assertEqual(hashlib.sha256(Path(seed).read_bytes()).hexdigest(), before)
            self.assertEqual(rep["seeded"]["verify_messages"], 1)
            self.assertEqual({k: v for k, v in rep["verify"].items() if v}, {})
            self.assertEqual(sorted(os.listdir(tmp)), ["seed.sqlite3"])

    def test_an_unreadable_health_stops_the_rehearsal_and_reports_the_hold(self):
        rep = ba.rehearse(20, 1, tick_s=0.01, minutes_at_max=1, ramp=self.RAMP, latency_ms=0.0, hold_ticks=2,
                          health=lambda: S(time.time(), 0, readable=False))
        self.assertTrue(rep["stop_reason"].startswith("health_unreadable"), rep["stop_reason"])
        self.assertLessEqual(len(rep["ticks"]), 2)
        self.assertEqual(ba.rehearse_exit(rep), ba.EXIT_HELD)

    def test_a_health_read_that_never_counts_our_sends_stops_the_rehearsal(self):
        ramp = dict(CFG, window_s=10.0, health_lag_s=0.0, min_judged=1)
        rep = ba.rehearse(500, 1, tick_s=0.2, minutes_at_max=2, ramp=ramp, latency_ms=0.0, hold_ticks=3,
                          health=lambda: S(time.time(), 0))
        self.assertTrue(rep["stop_reason"].startswith("health_not_counting_our_sends"), rep["stop_reason"])
        self.assertLessEqual(len(rep["ticks"]), 8)
        self.assertEqual(ba.rehearse_exit(rep), ba.EXIT_HELD)
        self.assertGreater(rep["provider"]["deliveries"], 0)


NOW = datetime(2026, 11, 16, 12, 0, tzinfo=timezone.utc).timestamp()
DAY = 86400.0
APPROVAL = {"approved_by": "fable-ruling-0000-test", "approval_ref": "test_bulk_asks",
            "approver_kind": vl.APPROVER_RULING, "approval_id": "fable-ruling-0000-test"}
#: The copy the gate approved this tick. Every person is loaded with body "old", so a job carrying "b" proves the
#: queue was given the approved bytes, never the stored row's.
COPY = {"body": "b", "subject": "s", "data": {"titles": "B"}, "copy_data": ["titles"]}
HELD = "copy_review_hold: CopyHeld"


def person(uid):
    return {"user_key": f"u{uid}@example.invalid", "user_id": str(uid), "email": f"u{uid}@example.invalid",
            "email_confirmed": True, "stage": "ask", "request_ids": [f"r{uid}"], "body": "old", "subject": "old",
            "data": {}, "copy_data": [], "paid": False, "never_asked": True}


class _HeldRoute(bq.FakeRoute):
    """A worker whose copy gate holds every body (a pending review)."""

    def hold(self, job):  # noqa: ARG002
        return HELD


class World:
    """One lane on scratch stores: a real ramp store, a real queue, the real shared verify ledger, a fake provider.
    Opening it again on the same directory (a restart after a kill) reads the same stores."""

    def __init__(self, tmp, people=1, *, load=True):
        self.rdb = ba.connect(os.path.join(tmp, "ramp.sqlite"), init=True)
        self.qdb = bq.connect(os.path.join(tmp, "queue.sqlite"), init=True)
        pol = json.loads(json.dumps(bq.SCRATCH_POLICY))
        pol["stages"] = {"ask": "uvn-status"}
        bq.apply_policy(self.qdb, pol)
        self.ldb = vl.connect(os.path.join(tmp, "ledger.sqlite3"))
        self.policy = {"stage": "ask", "ramp": CFG, "message_class": "uvn-status", "approval": APPROVAL,
                       "template_sha256": "0" * 64}
        self.lane = ba.ledger_lane(self.ldb, self.policy, "0" * 64)
        self.prov = os.path.join(tmp, "provider.sqlite")
        if load:
            bq.FakeProvider(self.prov, init=True)
            ba.load_audience(self.rdb, [person(i) for i in range(1, people + 1)])

    def tick(self, at, held=""):
        return ba.tick(self.rdb, self.qdb, self.policy, health=lambda: S(at, 0), lane=self.lane,
                       retry_when=ba.ledger_retry_when(self.ldb), precheck=lambda: (held, dict(COPY)))

    def work(self, route=None):
        return bq.work(self.qdb, route or bq.FakeRoute("email", bq.FakeProvider(self.prov)), "w", batch=50)

    def ledger(self, uid=1):
        return [r[0] for r in self.ldb.execute(
            "SELECT status FROM verify_messages WHERE user_key = ? ORDER BY id", (f"u{uid}@example.invalid",))]

    def jobs(self):
        return [tuple(r) for r in self.qdb.execute("SELECT user_key, state FROM jobs ORDER BY user_key")]

    def audience(self, uid=1):
        r = self.rdb.execute("SELECT released_at, retry_at, outcome FROM audience WHERE user_key = ?",
                             (f"u{uid}@example.invalid",)).fetchone()
        return tuple(r)

    def delivered(self):
        return bq.FakeProvider(self.prov).counts()

    def clean(self, case):
        bad = {k: v for k, v in ba.verify(self.rdb, self.qdb, self.ldb, self.policy).items() if v}
        case.assertEqual(bad, {})


# Where a kill lands. ("lane", f): inside the lane's ledger call f; ("ba"/"bq", f): a module function the tick
# calls. "before" dies before the call takes effect, "after" right after it committed.
KILL_POINTS = {
    "before_claim": ("lane", "claim", "before"),
    "after_claim": ("lane", "claim", "after"),
    "after_release": ("ba", "release", "after"),
    "after_enqueue": ("bq", "enqueue", "after"),
    "before_finalize": ("lane", "finalize", "before"),
    "after_finalize": ("lane", "finalize", "after"),
    "after_cancel": ("bq", "cancel_held", "after"),
    "after_give_back": ("lane", "give_back", "after"),
}
KILLED = 9


def _killed_tick(tmp, point, at):
    """Child process: one tick that `os._exit`s at `point`. Nothing is unwound, as in a SIGKILL."""
    w = World(tmp, load=False)
    target, name, when = KILL_POINTS[point]

    def wrap(fn):
        def inner(*a, **k):
            if when == "before":
                os._exit(KILLED)
            fn(*a, **k)
            os._exit(KILLED)
        return inner

    if target == "lane":
        w.lane = dataclasses.replace(w.lane, **{name: wrap(getattr(w.lane, name))})
    else:
        mod = ba if target == "ba" else ba.bulk_queue
        setattr(mod, name, wrap(getattr(mod, name)))
    w.tick(at)
    os._exit(0)


class KillTests(unittest.TestCase):
    """The ledger claim is the only commit point. A kill at any step of a tick (in a child process, `os._exit`:
    nothing unwound) leaves a state the next tick finishes from the ledger: the person is sent exactly once, under
    one claim, or given back and offered again. Never sent twice, never sent without a claim, never left blocked
    behind an `attempted` row."""

    def _kill(self, tmp, point, at):
        code = (f"import sys; sys.path.insert(0, {str(Path(__file__).resolve().parent)!r}); "
                f"import test_bulk_asks as T; T._killed_tick({tmp!r}, {point!r}, {at!r})")
        rc = subprocess.run([sys.executable, "-c", code], capture_output=True, text=True, timeout=120)
        self.assertEqual(rc.returncode, KILLED, rc.stderr[-2000:])

    def _finish(self, w, start):
        """Ticks and workers with no kill, across a day, until nothing is left to do."""
        for at in (start, start + 60, start + 120, start + DAY + 60, start + DAY + 120, start + DAY + 180):
            w.tick(at)
            w.work()

    def _sent_once(self, w):
        self.assertEqual(w.delivered()["deliveries"], 1)
        self.assertEqual(w.delivered()["keys_delivered_twice"], 0)
        self.assertEqual(w.ledger().count("sent"), 1, w.ledger())
        self.assertNotIn("attempted", w.ledger())
        self.assertEqual(w.audience()[2], "sent")
        self.assertEqual(w.qdb.execute("SELECT body FROM people").fetchone()[0], "b")
        w.clean(self)

    def test_a_kill_anywhere_on_the_way_to_a_job(self):
        for point in ("before_claim", "after_claim", "after_release", "after_enqueue"):
            with self.subTest(point=point), tempfile.TemporaryDirectory() as tmp:
                World(tmp)
                self._kill(tmp, point, NOW)
                w = World(tmp, load=False)
                self.assertEqual(w.delivered()["deliveries"], 0)
                self._finish(w, NOW + 60)
                self._sent_once(w)

    def test_a_kill_while_a_sent_job_is_written_down(self):
        for point in ("before_finalize", "after_finalize"):
            with self.subTest(point=point), tempfile.TemporaryDirectory() as tmp:
                w = World(tmp)
                w.tick(NOW)
                w.work()
                self.assertEqual(w.ledger(), ["attempted"])
                self._kill(tmp, point, NOW + 60)
                w = World(tmp, load=False)
                self._finish(w, NOW + 120)
                self._sent_once(w)

    def test_a_kill_while_a_held_job_is_given_back(self):
        for point in ("after_cancel", "after_give_back"):
            with self.subTest(point=point), tempfile.TemporaryDirectory() as tmp:
                w = World(tmp)
                w.tick(NOW)
                w.work(_HeldRoute("email", bq.FakeProvider(w.prov)))
                self.assertEqual(w.jobs(), [("u1@example.invalid", "queued")])
                self._kill(tmp, point, NOW + 60)
                w = World(tmp, load=False)
                self.assertEqual(w.delivered()["deliveries"], 0)
                self._finish(w, NOW + 120)
                self._sent_once(w)


class DeriveTests(unittest.TestCase):
    """The one pass that turns this lane's ledger claims into jobs and outcomes."""

    def test_a_claim_becomes_one_job_on_the_approved_bytes_and_is_written_down_when_sent(self):
        with tempfile.TemporaryDirectory() as tmp:
            w = World(tmp, people=3)
            t = w.tick(NOW)
            self.assertEqual(t["released"], 3)
            self.assertEqual(json.loads(w.rdb.execute("SELECT detail FROM ticks").fetchone()[0])
                             ["release"]["queued"], 3)
            self.assertEqual([s for _, s in w.jobs()], ["queued"] * 3)
            body, data, copy_data = w.qdb.execute(
                "SELECT body, data_json, copy_data_json FROM people WHERE user_key = 'u1@example.invalid'").fetchone()
            self.assertEqual((body, json.loads(data), json.loads(copy_data)), ("b", {"titles": "B"}, ["titles"]))
            w.tick(NOW + 60)
            self.assertEqual(len(w.jobs()), 3)  # a second pass makes no second job
            w.work()
            w.tick(NOW + 120)
            self.assertEqual([w.ledger(i) for i in (1, 2, 3)], [["sent"]] * 3)
            w.clean(self)

    def test_a_tick_reports_the_queue_it_just_filled(self):
        """`run` stops on `audience_left == 0 and backlog == 0`: a tick that released the last person must report
        that person's job, or the run kills the workers before it is sent."""
        with tempfile.TemporaryDirectory() as tmp:
            w = World(tmp)
            t = w.tick(NOW)
            self.assertEqual((t["audience_left"], t["backlog"]), (0, 1))
            w.work()
            self.assertEqual(w.tick(NOW + 60)["backlog"], 0)

    def test_a_held_body_claims_nobody(self):
        with tempfile.TemporaryDirectory() as tmp:
            w = World(tmp)
            t = w.tick(NOW, held=HELD)
            self.assertEqual((t["released"], t["release_hold"]), (0, HELD))
            self.assertEqual(w.ledger(), [])
            self.assertEqual(w.audience()[0], 0)

    def test_a_held_job_is_cancelled_its_claim_given_back_and_no_job_is_made_without_a_fresh_claim(self):
        with tempfile.TemporaryDirectory() as tmp:
            w = World(tmp)
            w.tick(NOW)
            w.work(_HeldRoute("email", bq.FakeProvider(w.prov)))
            self.assertTrue(vl.capped(w.ldb, user_key="u1@example.invalid", day="2026-11-16"))
            w.tick(NOW + 60)
            self.assertEqual(w.jobs(), [])
            self.assertEqual(w.ledger(), ["deferred"])
            self.assertFalse(vl.capped(w.ldb, user_key="u1@example.invalid", day="2026-11-16"))
            self.assertEqual(w.audience()[2], f"deferred:{HELD}")
            # The queue still holds a `send` verdict for the person: no tick, release or worker turns it into a job.
            for at in (NOW + 120, NOW + 180):
                w.tick(at)
                w.work()
            self.assertEqual((w.jobs(), w.delivered()["deliveries"]), ([], 0))
            w.tick(NOW + 60 + DAY)  # the deferral lapses: a fresh claim, then exactly one job and one send
            w.work()
            w.tick(NOW + 120 + DAY)
            self.assertEqual(w.ledger().count("sent"), 1)
            self.assertEqual(w.delivered()["deliveries"], 1)
            w.clean(self)

    def test_a_claim_is_given_back_when_the_gate_holds_the_copy_before_its_job_exists(self):
        with tempfile.TemporaryDirectory() as tmp:
            w = World(tmp)
            w.lane.claim(person(1), NOW)  # a claim whose tick died before the job
            w.tick(NOW + 60, held=HELD)
            self.assertEqual((w.ledger(), w.jobs()), (["deferred"], []))

    def test_a_worker_that_took_the_job_is_never_given_back(self):
        with tempfile.TemporaryDirectory() as tmp:
            w = World(tmp)
            w.tick(NOW)
            self.assertEqual(len(ba.bulk_queue.claim(w.qdb, "w", 5, route="email", now=NOW)), 1)
            w.tick(NOW + 60, held=HELD)
            self.assertEqual((w.ledger(), w.jobs()), (["attempted"], [("u1@example.invalid", "claimed")]))

    def test_a_queue_hold_gives_the_claim_back_and_a_terminal_skip_closes_the_person(self):
        for hold, outcome in (("no_route", "deferred"), ("", "closed")):
            with self.subTest(hold=hold), tempfile.TemporaryDirectory() as tmp:
                w = World(tmp)
                if hold:
                    w.rdb.execute("UPDATE audience SET row_json = json_set(row_json, '$.hold', ?)", (hold,))
                else:
                    w.qdb.execute("INSERT INTO told (user_key, stage, source) VALUES (?,?,?)",
                                  ("u1@example.invalid", "ask", "test"))
                w.tick(NOW)
                self.assertEqual((w.ledger(), w.jobs()), (["deferred"], []))
                self.assertTrue(w.audience()[2].startswith(outcome), w.audience())
                self.assertEqual(w.audience()[1] > 0, outcome == "deferred")

    def test_another_lanes_claim_is_never_touched(self):
        with tempfile.TemporaryDirectory() as tmp:
            w = World(tmp)
            other = ba.ledger_lane(w.ldb, dict(w.policy, approval=dict(APPROVAL, approval_ref="another sender")),
                                   "0" * 64)
            other.claim(person(1), NOW)
            w.tick(NOW + 60, held=HELD)
            w.tick(NOW + 120)
            self.assertEqual((w.ledger(), w.jobs()), (["attempted"], []))

    def test_a_job_from_an_earlier_claim_never_settles_a_new_one(self):
        with tempfile.TemporaryDirectory() as tmp:
            w = World(tmp)
            w.tick(NOW)
            w.work()
            w.tick(NOW + 60)
            self.assertEqual(w.ledger(), ["sent"])
            later = vl.stamp(datetime.fromtimestamp(NOW + 40 * DAY, timezone.utc))
            w.ldb.execute(  # a claim of this lane's (a later ask, or a hand-made one) for a stage already spent
                "INSERT INTO verify_messages (campaign, kind, user_key, account_id, day, status, message_type, "
                "request_ids_json, n_credits, approved_by, approval_ref, created_at, updated_at) "
                "VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)",
                ("uvn-status", "initial", "u1@example.invalid", "1", later[:10], "attempted", "email", "[]", 1,
                 APPROVAL["approved_by"], APPROVAL["approval_ref"], later, later))
            w.ldb.commit()
            w.tick(NOW + 40 * DAY + 60)
            self.assertEqual(w.ledger(), ["sent", "deferred"])
            self.assertTrue(w.audience()[2].startswith("closed:bulk-asks: an earlier job"), w.audience())
            self.assertEqual(w.delivered()["deliveries"], 1)

    def test_a_claim_no_audience_row_names_is_given_back(self):
        with tempfile.TemporaryDirectory() as tmp:
            w = World(tmp, people=0)
            w.lane.claim(person(7), NOW)
            w.tick(NOW + 60)
            self.assertEqual((w.ledger(7), w.jobs()), (["deferred"], []))


class DeferralTests(unittest.TestCase):
    """A deferral is not a decision: the person is offered again when the ledger's lock lapses. Only a terminal
    result closes the audience row."""

    @staticmethod
    def _release(w, why, at, retry_when=None):
        lane = dataclasses.replace(w.lane, claim=lambda p, now: (0, why))
        return ba.release(w.rdb, 1, lane, now=at, copy=dict(COPY), retry_when=retry_when)

    def test_a_deferral_is_offered_again_when_its_lock_lapses(self):
        for why in ("recent:messaged_7d", "recent:recently_asked", "daily_cap", "no_channel: action_forbidden"):
            with self.subTest(why=why), tempfile.TemporaryDirectory() as tmp:
                w = World(tmp)
                self.assertEqual(self._release(w, why, 1000.0)["offered"], 1)
                delay = ba.retry_delay(why)
                self.assertEqual(self._release(w, why, 1000.0 + delay - 1)["offered"], 0)
                self.assertEqual(self._release(w, why, 1000.0 + delay)["offered"], 1)

    def test_a_deferral_is_offered_at_the_ledgers_actual_expiry(self):
        for reason, campaign, days in (("messaged_7d", "removal-notice", 6),
                                       ("recently_asked", "verify-live", 89)):
            with self.subTest(reason=reason), tempfile.TemporaryDirectory() as tmp:
                w = World(tmp)
                now = datetime(2026, 11, 16, 12, 0, tzinfo=timezone.utc)
                day = (now - timedelta(days=days)).strftime("%Y-%m-%d")
                w.ldb.execute(
                    "INSERT INTO verify_messages (campaign, kind, user_key, account_id, day, status, message_type, "
                    "request_ids_json, n_credits, approved_by, approval_ref, created_at, updated_at) "
                    "VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)",
                    (campaign, "initial", "u1@example.invalid", "1", day, "sent", "email", "[]", 1, "x", "y",
                     day, day))
                w.ldb.commit()
                why = f"recent:{reason}"
                rw = ba.ledger_retry_when(w.ldb)
                self._release(w, why, now.timestamp(), rw)
                retry = w.audience()[1]
                lock_days = vl.MESSAGED_COOLDOWN_DAYS + 1 if reason == "messaged_7d" else vl.REASK_LOCK_DAYS
                expected = datetime.strptime(day, "%Y-%m-%d").replace(tzinfo=timezone.utc) + timedelta(days=lock_days)
                self.assertEqual(retry, expected.timestamp())
                self.assertEqual(vl.uvn_user_done(w.ldb, "u1@example.invalid", now=expected, campaign="uvn-status",
                                                  user_id="1"), "")
                self.assertNotEqual(vl.uvn_user_done(w.ldb, "u1@example.invalid",
                                                     now=expected - timedelta(seconds=1), campaign="uvn-status",
                                                     user_id="1"), "")
                self.assertEqual(self._release(w, why, retry - 1, rw)["offered"], 0)
                self.assertEqual(self._release(w, why, retry, rw)["offered"], 1)

    def test_a_terminal_result_closes_the_person(self):
        for why in ("already_notified", "user_done:already_sent"):
            with self.subTest(why=why), tempfile.TemporaryDirectory() as tmp:
                w = World(tmp)
                self._release(w, why, 1000.0)
                self.assertEqual(self._release(w, why, 1000.0 + 365 * DAY)["offered"], 0)


class EnforcedCopyGateTests(unittest.TestCase):
    """This sender sends only bytes a reviewer signed an approve for: an observed pass is a hold."""

    class _Gate:
        class CopyHeld(RuntimeError):
            pass

        def __init__(self, result):
            self.result = result

        def require(self, campaign, body, **kw):
            return {"result": self.result, "body_sha256": "0" * 64}

    def test_an_observed_pass_is_a_hold_and_a_signed_approve_sends(self):
        with self.assertRaises(self._Gate.CopyHeld):
            ba.EnforcedCopyGate(self._Gate("observed")).require("uvn-status", "body")
        self.assertEqual(ba.EnforcedCopyGate(self._Gate("approved")).require("uvn-status", "body")["result"],
                         "approved")

    def test_the_email_route_holds_an_observed_body(self):
        job = bq.Job(idem_key="k", user_key="u@example.invalid", stage="ask", message_class="uvn-status",
                     route="email", attempts=0, email="u@example.invalid", user_id="1", body="b", subject="s")
        route = bq.EmailRoute(
            {"routes": {"email": {"template_keys": {"uvn-status": "credit_status_uvn_ask"},
                                   "template_sha256": {"credit_status_uvn_ask": "0" * 64}}}},
            gate=ba.EnforcedCopyGate(self._Gate("observed")))
        self.assertTrue(route.hold(job).startswith("copy_review_hold"))

    def test_a_copy_precheck_asks_the_gate_on_the_queues_own_frame(self):
        asked = []

        class _Recorder(self._Gate):
            def require(self, campaign, body, **kw):
                asked.append((campaign, body, kw))
                return super().require(campaign, body, **kw)

        policy = {"message_class": "uvn-status", "template_key": "credit_status_uvn_ask", "body": "b",
                  "subject": "s"}
        qpolicy = {"routes": {"email": {"template_keys": {"uvn-status": "credit_status_uvn_ask"},
                                          "template_sha256": {"credit_status_uvn_ask": "1" * 64}}}}
        check = ba.copy_precheck(qpolicy, policy, gate=ba.EnforcedCopyGate(_Recorder("approved")))
        self.assertEqual(check(), ("", {"body": "b", "subject": "s", "data": {}, "copy_data": []}))
        self.assertEqual(asked, [("uvn-status", "b", {"subject": "s",
                                                      "copy": "email-template:credit_status_uvn_ask@" + "1" * 64,
                                                      "data": ()})])
        self.assertTrue(ba.copy_precheck(qpolicy, policy, gate=ba.EnforcedCopyGate(
            _Recorder("pending")))()[0].startswith("copy_review"))


class SupervisorTests(unittest.TestCase):
    def test_a_refused_worker_stops_the_supervisor_instead_of_being_re_spawned(self):
        out = ba.supervise([sys.executable, "-c", f"import sys; sys.exit({ba.EXIT_REFUSED})"], 1,
                           stop=lambda: False, poll_s=0.01)
        self.assertTrue(out["refused"])
        self.assertEqual(out["restarts"], 0)


class LedgerIndexTests(unittest.TestCase):
    """Every per-user read of the verify ledger (capped, uvn_user_done, no_channel, ...) is `_same_user`, and
    claim() makes them inside the write lock every sender shares. Without verify_messages(account_id) the OR is a
    full scan: ~45 ms of reads per claim on node-8's ledger (15k messages), ~6 ms with it."""

    def test_the_same_user_read_is_a_multi_index_or(self):
        db = vl.connect(":memory:")
        cond, params = vl._same_user(db, "a@example.invalid", "42")
        plan = " | ".join(str(r[3]) for r in db.execute(
            f"EXPLAIN QUERY PLAN SELECT 1 FROM verify_messages m WHERE {cond} AND m.status='attempted'", params))
        self.assertIn("MULTI-INDEX OR", plan)
        self.assertIn("verify_messages_account", plan)
        self.assertNotIn("SCAN m", plan)


class LedgerRateBlindTests(unittest.TestCase):
    """`data/verif-1000-per-min-r1/tools/ledger_rate.py` is the acceptance read of the sustained run. A required source
    it could not read is BLIND (exit 2), never a pass: it once passed `--check` with `ask` unread because only an
    all-sources-unread result was refused (QA and Opus on #2098 at 174112ce2)."""

    TOOL = ROOT / "data" / "verif-1000-per-min-r1" / "tools" / "ledger_rate.py"

    def _run(self, *args):
        r = subprocess.run([sys.executable, str(self.TOOL), "--since", "2026-11-16T10:00:00", "--until",
                            "2026-11-16T10:01:00", "--target", "1", "--sustain", "1", "--check", *args],
                           capture_output=True, text=True, timeout=60)
        return r.returncode, json.loads(r.stdout)

    def _decide_only(self, tmp):
        """A ledger with the decider's tables and one shadow decision in the window, and no `verify_messages`."""
        from credit_review import decide
        path = f"{tmp}/decide-only.sqlite3"
        db = sqlite3.connect(path)
        db.executescript(decide.SCHEMA)
        db.execute("INSERT INTO decisions (run_id, decided_at, request_id, big_track, decision, reason, mode) "
                   "VALUES ('r', '2026-11-16T10:00:05Z', 'q', 0, 'approve', 'x', 'shadow')")
        db.commit()
        db.close()
        return path

    def _full(self, tmp):
        path = self._decide_only(tmp).replace("decide-only", "full")
        os.rename(f"{tmp}/decide-only.sqlite3", path)
        vl.connect(path).close()
        return path

    def test_a_partial_read_is_blind_not_a_pass(self):
        with tempfile.TemporaryDirectory() as tmp:
            rc, out = self._run("--ledger", self._decide_only(tmp))
            # The one source it read meets the target with nothing unproved; the unread one still decides.
            self.assertTrue(out["sustained"])
            self.assertEqual(out["applied_without_proof"], 0)
            self.assertEqual((rc, out["absent"]), (2, ["ask"]))

    def test_a_named_drain_that_cannot_be_read_is_blind(self):
        with tempfile.TemporaryDirectory() as tmp:
            full = self._full(tmp)
            self.assertEqual(self._run("--ledger", full)[0], 0)
            rc, out = self._run("--ledger", full, "--drain", f"{tmp}/no-such-drain.sqlite")
            self.assertEqual((rc, out["absent"]), (2, ["drain"]))
            self.assertFalse(Path(f"{tmp}/no-such-drain.sqlite").exists())

    def test_every_source_read_and_proved_passes(self):
        from credit_review import scale_drain
        with tempfile.TemporaryDirectory() as tmp:
            full = self._full(tmp)
            drain = sqlite3.connect(f"{tmp}/drain.sqlite")
            drain.executescript(scale_drain.LEDGER_SCHEMA)
            drain.close()
            rc, out = self._run("--ledger", full, "--drain", f"{tmp}/drain.sqlite")
            self.assertEqual((rc, out["absent"]), (0, []))


    def test_a_missing_proof_table_is_blind_not_a_note(self):
        """Without `decision_outcomes` (decide) or `intents` (drain) no applied row can show its proof, so the source is
        absent: before, it was a note beside the counts and a window with no applied row passed (QA, e4135a000)."""
        from credit_review import scale_drain
        with tempfile.TemporaryDirectory() as tmp:
            full = self._full(tmp)
            drain = sqlite3.connect(f"{tmp}/drain.sqlite")
            drain.executescript(scale_drain.LEDGER_SCHEMA)
            drain.close()
            self.assertEqual(self._run("--ledger", full, "--drain", f"{tmp}/drain.sqlite")[0], 0)
            db = sqlite3.connect(full)
            db.execute("DROP TABLE decision_outcomes")
            db.commit()
            db.close()
            rc, out = self._run("--ledger", full, "--drain", f"{tmp}/drain.sqlite")
            self.assertEqual((rc, out["absent"]), (2, ["decide"]))
            self.assertIn("decision_outcomes", out["sources"]["decide"]["absent"])
            db = sqlite3.connect(f"{tmp}/drain.sqlite")
            db.execute("DROP TABLE intents")
            db.commit()
            db.close()
            rc, out = self._run("--ledger", full, "--drain", f"{tmp}/drain.sqlite")
            self.assertEqual((rc, out["absent"]), (2, ["decide", "drain"]))
            self.assertIn("intents", out["sources"]["drain"]["absent"])

if __name__ == "__main__":
    unittest.main()
