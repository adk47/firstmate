#!/usr/bin/env python3
"""A precedent approval has its decision row in the ledger (credit_review/precedent_ledger.py).

The incident: precedent_v1 approves in core's Postgres from inside a pod and wrote nothing to the
node-8 ledger's `decisions` / `decision_outcomes`, so every approval count read from the ledger
left its approvals out (request 094355b2, approved 2026-11-15T07:36:55Z, no row; 10,384 in core).

The two stores cannot share a transaction, so what is tested is the order and the reader that
closes it: a claim before the core write, and a reconcile that reads core. Every ledger here is
the live request-state schema (trigger included) plus the decider's own `decisions` DDL. Nothing
reaches node-8 or the replica: the replica is `Core`, a function this file supplies.

What must hold:
  * a precedent approval writes exactly ONE decision row and one `approved` outcome, however
    many times and by whichever route it is offered;
  * a claim is not an approval: no approval count reads it, before or after it closes;
  * a claim whose core write did not land is closed and leaves no approval behind;
  * core unread, or half read, writes nothing;
  * a second backfill inserts zero, and a backfilled row names its batch.
"""
from __future__ import annotations

import credit_test_env  # noqa: F401,E402 - first: test logs never reach the production run.log
import json
import os
import re
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
sys.path.insert(0, str(ROOT / "scripts"))

from credit_review import decide  # noqa: E402 - its SCHEMA is the ledger's decision tables
from credit_review import precedent_ledger as pl  # noqa: E402
from credit_review import reconcile_approved, verify_notify  # noqa: E402

MODULE = ROOT / "scripts" / "credit_review" / "precedent_ledger.py"
SCHEMA = ROOT / "scripts" / "tests" / "fixtures" / "credit-precedent" / "request-ledger-live-schema.sql"

A = "11111111-1111-4111-8111-111111111111"
B = "22222222-2222-4222-8222-222222222222"
C = "33333333-3333-4333-8333-333333333333"
D = "44444444-4444-4444-8444-444444444444"
P1 = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1"
P2 = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa2"
P3 = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa3"
RUN = "prev-2026-11-15T07"
OTHER_RUN = "prev-2026-11-15T05"
CORE_AT = "2026-11-15T07:36:55.643006+00:00"     # core's approval.at, as core writes it
LEDGER_AT = "2026-11-15T07:36:55Z"               # the same instant, as the ledger writes a time
NOW = pl._epoch("2026-11-15T08:00:00Z")
CLAIMED = pl._epoch("2026-11-15T07:36:00Z")      # 24 min before NOW: past NOT_LANDED_AFTER_S
# The count the reports carry (firstmate data/verif-fixes.md): the literal statement. It compares
# the ledger's 'YYYY-MM-DDTHH:MM:SSZ' with SQLite's 'YYYY-MM-DD HH:MM:SS' as text, so a row of
# the current UTC date always compares greater: assert an exclusion with APPLIED_SINCE instead.
APPLIED_1H = "select count(*) from decision_outcomes where outcome='approved' and at > datetime('now','-1 hour')"
APPLIED_SINCE = "select count(*) from decision_outcomes where outcome='approved' and at > ?"

_UUID_IN = re.compile(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}")
_STAMP_IN = re.compile(r"''(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ)''::timestamptz")


def holds(sql, stamp):
    """This statement's `updatedAt` window holds `stamp`."""
    stamps = _STAMP_IN.findall(sql)
    return bool(stamps) and stamps[0] <= stamp and (len(stamps) == 1 or stamp < stamps[1])


def plan_line(batch, run=RUN, **over):
    return json.dumps({"marker": pl.PLAN_MARKER, "run": run,
                       "batch": [{"id": rid, "precedent_ids": list(prec)} for rid, prec in batch], **over})


def result_line(ids, run=RUN):
    return json.dumps({"marker": "PREV2_RESULT", "run": run, "changed": len(ids),
                       "approved": len(ids), "approved_ids": list(ids)})


class Core:
    """The replica, for the three statements precedent_ledger makes: by id, by window, and the
    list of ids a window changed. `fail(kind, sql)` True makes that statement not answer."""

    def __init__(self):
        self.rows: dict[str, dict] = {}
        self.calls: list[tuple[str, str]] = []
        self.fail = lambda kind, sql: False

    def put(self, rid, *, status="approved", deleted=False, via=pl.VIA, run=RUN, at=CORE_AT,
            own=(P1, P2, P3), sets=1, updated=LEDGER_AT):
        self.rows[rid] = {"status": status, "deleted": deleted, "via": via, "run": run, "at": at,
                          "own": list(own), "sets": sets, "updated": updated}

    def wire(self, rid):
        r = self.rows[rid]
        return [rid, r["status"], "true" if r["deleted"] else "false", r["via"], r["run"], r["at"],
                str(r["sets"]), json.dumps(r["own"]) if r["sets"] == 1 else ""]

    def kinds(self):
        return [k for k, _ in self.calls]

    def __call__(self, sql):
        kind = "ids" if sql.startswith("SELECT id FROM") else "by_id" if "id IN (" in sql else "window"
        self.calls.append((kind, sql))
        if self.fail(kind, sql):
            raise RuntimeError("trino failed: ERROR: canceling statement due to statement timeout")
        if kind == "by_id":
            asked = _UUID_IN.findall(sql.split("id IN (", 1)[1])
            return [self.wire(rid) for rid in asked if rid in self.rows]
        stamps = _STAMP_IN.findall(sql)
        start, end = stamps[0], (stamps[1] if len(stamps) > 1 else None)
        hit = [rid for rid, r in sorted(self.rows.items())
               if r["updated"] >= start and (end is None or r["updated"] < end)]
        if kind == "ids":
            return [[rid] for rid in hit]
        return [self.wire(rid) for rid in hit if self.rows[rid]["via"] == pl.VIA]


class LedgerCase(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.path = str(Path(self.tmp.name) / "ledger.sqlite3")
        db = sqlite3.connect(self.path)
        db.executescript(SCHEMA.read_text())
        db.executescript(decide.SCHEMA)   # the fixture is the request-state half; the live ledger holds both
        db.commit()
        db.close()
        self.core = Core()

    def q(self, sql, *args):
        db = sqlite3.connect(self.path)
        try:
            return db.execute(sql, args).fetchall()
        finally:
            db.close()

    def one(self, sql, *args):
        return self.q(sql, *args)[0][0]

    def claim(self, batch, run=RUN, now=CLAIMED):
        db = pl.open_ledger(self.path)
        try:
            return pl.claim(db, run, list(batch), now=now)
        finally:
            db.close()

    def reconcile(self, now=NOW, **kw):
        db = pl.open_ledger(self.path)
        try:
            return pl.reconcile(db, self.core, now=now, **kw)
        finally:
            db.close()

    def backfill(self, apply=True, batch="precedent-backfill-t1", floor="2026-11-14T00:00:00Z", now=NOW):
        return pl.backfill(self.path, apply=apply, batch=batch, query=self.core, floor=floor, now=now)

    def decisions(self):
        return self.q("SELECT request_id, run_id, decided_at, decision, mode, evidence_kind, reason, "
                      "profile_id, user_id, big_track FROM decisions ORDER BY id")

    def outcomes(self):
        return self.q("SELECT request_id, run_id, at, action, outcome FROM decision_outcomes ORDER BY id")

    def claims(self):
        return self.q("SELECT request_id, run_id, state, core_said FROM precedent_claims ORDER BY id")

    def state(self, rid):
        got = self.q("SELECT state FROM request_state WHERE request_id = ?", rid)
        return got[0][0] if got else None

    def snapshot(self):
        return (self.decisions(), self.outcomes(), self.q("SELECT * FROM request_state ORDER BY request_id"),
                self.q("SELECT * FROM request_state_log ORDER BY id"))


class ClaimThenLanded(LedgerCase):
    def test_a_precedent_approval_writes_exactly_one_decision_row(self):
        self.assertEqual(self.claim([(A, [P1, P2, P3])]), {"run": RUN, "offered": 1, "claimed": 1, "already": 0})
        self.core.put(A)
        out = self.reconcile()
        self.assertEqual((out["landed"], out["approvals_written"], out["not_landed"], out["still_open"]), (1, 1, 0, 0))
        self.assertEqual(self.decisions(), [(
            A, RUN, LEDGER_AT, "approve", "apply", "precedent",
            f"precedent_v1 run {RUN}: matched 3 approved request(s) of the same user: {P1},{P2},{P3}",
            None, None, 0)])
        self.assertEqual(self.outcomes(), [(A, RUN, LEDGER_AT, "approve", "approved")])
        self.assertEqual(self.state(A), "APPROVED")
        self.assertEqual(self.claims(), [(A, RUN, "landed", f"approved under run {RUN}")])

    def test_every_later_offer_of_the_same_approval_writes_no_second_row(self):
        self.claim([(A, [P1, P2, P3])])
        self.core.put(A)
        self.reconcile()
        before = self.snapshot()
        again = self.reconcile(result_ids=[A], since_hours=6)
        self.assertEqual((again["approvals_written"], again["approvals_already"]), (0, 1))
        self.assertEqual(self.backfill()["inserted"], 0)
        self.assertEqual(self.snapshot(), before)
        self.assertEqual(self.one("SELECT count(*) FROM decisions WHERE request_id = ?", A), 1)

    def test_the_precedent_on_the_row_is_the_claims_own_when_core_recorded_the_whole_batch(self):
        """prev2.js writes every request's set into every row of the batch: core cannot say which
        is whose, the claim can."""
        self.claim([(A, [P1, P2, P3]), (B, [P2, P3, P1])])
        self.core.put(A, sets=2)
        self.core.put(B, sets=2)
        self.reconcile()
        reasons = dict(self.q("SELECT request_id, reason FROM decisions"))
        self.assertTrue(reasons[A].endswith(f"{P1},{P2},{P3}"), reasons[A])
        self.assertTrue(reasons[B].endswith(f"{P2},{P3},{P1}"), reasons[B])

    def test_the_same_plan_twice_is_one_claim_and_keeps_the_first(self):
        self.claim([(A, [P1, P2, P3])])
        again = self.claim([(A, [P3, P2, P1])], now=CLAIMED + 60)
        self.assertEqual((again["claimed"], again["already"]), (0, 1))
        self.assertEqual(self.q("SELECT precedent_ids, claimed_at FROM precedent_claims"),
                         [(json.dumps([P1, P2, P3]), "2026-11-15T07:36:00Z")])

    def test_a_claim_is_all_of_its_batch_or_none(self):
        db = pl.open_ledger(self.path)
        try:
            with self.assertRaises(TypeError):
                pl.claim(db, RUN, [(A, [P1]), (B, object())], now=CLAIMED)   # the second row cannot be written
        finally:
            db.close()
        self.assertEqual(self.claims(), [])


class ClaimIsNotAnApproval(LedgerCase):
    def test_an_open_claim_is_in_no_approval_count(self):
        self.claim([(A, [P1, P2, P3])], now=time.time())
        self.assertEqual(self.decisions(), [])
        self.assertEqual(self.outcomes(), [])
        self.assertEqual(self.one(APPLIED_1H), 0)
        self.assertIsNone(self.state(A))

    def test_a_claim_whose_core_write_failed_is_not_left_claiming_an_approval(self):
        self.claim([(A, [P1, P2, P3])])
        self.core.put(A, status="user_verification_needed", via="", run="", at="", sets=-1)
        out = self.reconcile()
        self.assertEqual((out["not_landed"], out["landed"], out["still_open"], out["approvals_written"]), (1, 0, 0, 0))
        self.assertEqual(self.claims(), [(A, RUN, "not_landed",
                                          "status user_verification_needed, no approval recorded")])
        self.assertEqual(self.decisions(), [])
        self.assertEqual(self.outcomes(), [])
        self.assertIsNone(self.state(A))
        self.assertEqual(self.one(APPLIED_1H), 0)
        self.assertEqual(pl.report(self.path)["precedent_approvals"], 0)
        # and it stays closed: the next pass has no open claim to act on
        self.assertEqual(self.reconcile()["claims_open"], 0)

    def test_a_request_core_does_not_hold_at_all_closes_the_claim(self):
        self.claim([(A, [P1, P2, P3])])
        self.assertEqual(self.reconcile()["not_landed"], 1)
        self.assertEqual(self.claims(), [(A, RUN, "not_landed", "core holds no such request")])
        self.assertEqual(self.decisions(), [])

    def test_an_approval_deleted_in_core_is_not_landed(self):
        self.claim([(A, [P1, P2, P3])])
        self.core.put(A, deleted=True)
        self.assertEqual(self.reconcile()["not_landed"], 1)
        self.assertEqual(self.claims()[0][3], "deleted in core (status approved)")
        self.assertEqual(self.decisions(), [])

    def test_a_young_claim_core_does_not_show_yet_stays_open_and_writes_nothing(self):
        """The read is a replica and the claim precedes the write: no approval yet is not a failure yet."""
        self.claim([(A, [P1, P2, P3])], now=NOW - pl.NOT_LANDED_AFTER_S + 1)
        self.core.put(A, status="user_verification_needed", via="", run="", at="", sets=-1)
        out = self.reconcile()
        self.assertEqual((out["still_open"], out["not_landed"], out["landed"]), (1, 0, 0))
        self.assertEqual(self.claims(), [(A, RUN, "claimed", None)])
        self.assertEqual(self.decisions(), [])
        self.core.put(A)   # the write lands, the next pass sees it
        self.assertEqual(self.reconcile(now=NOW + 60)["landed"], 1)
        self.assertEqual(len(self.decisions()), 1)

    def test_core_approved_it_under_another_run_so_this_claim_did_not_land_and_that_run_gets_the_row(self):
        self.claim([(A, [P1, P2, P3])])
        self.core.put(A, run=OTHER_RUN)
        out = self.reconcile()
        self.assertEqual((out["not_landed"], out["approvals_written"]), (1, 1))
        self.assertEqual(self.claims(), [(A, RUN, "not_landed",
                                          f"status approved; core's precedent approval is run {OTHER_RUN}, not this one")])
        self.assertEqual([(d[0], d[1]) for d in self.decisions()], [(A, OTHER_RUN)])

    def test_a_claim_closed_not_landed_is_closed_landed_when_core_shows_the_approval_later(self):
        self.claim([(A, [P1, P2, P3])])
        self.core.put(A, status="user_verification_needed", via="", run="", at="", sets=-1)
        self.reconcile()
        self.assertEqual(self.claims()[0][2], "not_landed")
        self.core.put(A)
        out = self.reconcile(now=NOW + 3600, since_hours=6)
        self.assertEqual((out["approvals_written"], out["landed_late"]), (1, 1))
        self.assertEqual(self.claims()[0][2], "landed")
        self.assertEqual(len(self.decisions()), 1)

    def test_an_approval_core_holds_with_no_readable_time_is_named_and_its_claim_stays_open(self):
        self.claim([(A, [P1, P2, P3])])
        self.core.put(A, at="yesterday")
        out = self.reconcile()
        self.assertEqual((out["unreadable_in_core"], out["still_open"], out["not_landed"], out["approvals_written"]),
                         (1, 1, 0, 0))
        self.assertEqual(self.decisions(), [])


class CoreUnreadWritesNothing(LedgerCase):
    def test_a_by_id_read_that_does_not_answer_leaves_the_claim_open_and_no_row(self):
        self.claim([(A, [P1, P2, P3]), (B, [P1, P2, P3])])
        self.core.put(A)
        self.core.put(B)
        self.core.fail = lambda kind, sql: kind == "by_id" and B in sql
        before = self.snapshot()
        with self.assertRaises(pl.CoreUnread):
            self.reconcile()
        self.assertEqual(self.snapshot(), before)
        self.assertEqual([c[2] for c in self.claims()], ["claimed", "claimed"])

    def test_a_row_core_was_not_asked_for_is_an_unread_core(self):
        self.claim([(A, [P1, P2, P3])])
        self.core.put(A)
        real = self.core.__call__

        def odd(sql):
            return real(sql) + [[B, "approved", "false", pl.VIA, RUN, CORE_AT, "1", json.dumps([P1])]]
        db = pl.open_ledger(self.path)
        try:
            with self.assertRaises(pl.CoreUnread):
                pl.reconcile(db, odd, now=NOW)
        finally:
            db.close()
        self.assertEqual(self.decisions(), [])

    def test_a_ledger_without_the_decision_tables_is_refused_and_gets_no_claims_table(self):
        other = str(Path(self.tmp.name) / "half.sqlite3")
        db = sqlite3.connect(other)
        db.executescript(SCHEMA.read_text())
        db.commit()
        db.close()
        with self.assertRaises(pl.LedgerRefused):
            pl.open_ledger(other)
        self.assertEqual(sqlite3.connect(other).execute(
            "SELECT count(*) FROM sqlite_master WHERE name = 'precedent_claims'").fetchone(), (0,))


class WithoutAClaim(LedgerCase):
    """Today's case: the prev2.js that runs prints no plan line."""

    def test_a_result_lines_ids_get_their_rows_from_what_core_holds(self):
        self.core.put(A)                       # a batch of one: core's set is this request's
        self.core.put(B, sets=41, own=())      # a batch of 41: core does not say which set is B's
        self.core.put(C, status="user_verification_needed", via="", run="", at="", sets=-1)
        out = self.reconcile(result_ids=[A, B, C])
        self.assertEqual((out["approvals_written"], out["result_ids_not_approved_in_core"]), (2, 1))
        reasons = dict(self.q("SELECT request_id, reason FROM decisions"))
        self.assertEqual(sorted(reasons), [A, B])
        self.assertTrue(reasons[A].endswith(f"{P1},{P2},{P3}"))
        self.assertIn("the 41 precedent sets of this request's batch and not which one", reasons[B])
        self.assertEqual((self.state(A), self.state(B), self.state(C)), ("APPROVED", "APPROVED", None))

    def test_the_sweep_finds_an_approval_nothing_named(self):
        self.core.put(A, updated="2026-11-15T07:36:55Z")
        self.core.put(B, updated="2026-11-14T09:00:00Z")   # outside a 6 h sweep
        out = self.reconcile(since_hours=6)
        self.assertEqual((out["swept"], out["approvals_written"]), (1, 1))
        self.assertEqual([d[0] for d in self.decisions()], [A])

    def test_the_sweep_writes_an_approval_core_recorded_with_no_run_name(self):
        self.core.put(A, run="")
        out = self.reconcile(since_hours=6)
        self.assertEqual((out["approvals_written"], out["unreadable_in_core"]), (1, 0))
        self.assertEqual(self.decisions()[0][1:3], ("prev-unnamed-" + LEDGER_AT, LEDGER_AT))
        self.assertEqual(self.reconcile(since_hours=6)["approvals_written"], 0)
        self.assertEqual(len(self.decisions()), 1)

    def test_an_approval_made_ten_minutes_ago_is_in_applied_1h_and_an_old_one_is_not(self):
        fresh = datetime.now(timezone.utc) - timedelta(minutes=10)
        self.core.put(A, at=fresh.isoformat())
        self.core.put(B, at="2026-11-10T19:02:11.000001+00:00", run="prev-2026-11-10T19")
        self.assertEqual(self.one(APPLIED_1H), 0)
        self.reconcile(result_ids=[A, B])
        self.assertEqual(self.one(APPLIED_1H), 1)
        hour_ago = (datetime.now(timezone.utc) - timedelta(hours=1)).strftime("%Y-%m-%dT%H:%M:%SZ")
        self.assertEqual(self.q("SELECT request_id FROM decision_outcomes WHERE outcome='approved' AND at > ?",
                                hour_ago), [(A,)])
        self.assertEqual(self.one("SELECT at FROM decision_outcomes WHERE request_id = ?", A),
                         fresh.strftime("%Y-%m-%dT%H:%M:%SZ"))

    def test_a_request_approved_by_another_path_gets_no_precedent_row(self):
        self.core.put(A, via="scale_drain", run="", at="", sets=-1)
        self.assertEqual(self.reconcile(result_ids=[A])["approvals_written"], 0)
        self.assertEqual(self.decisions(), [])


class OtherReaders(LedgerCase):
    """The row is shaped so that the readers which ACT on an approve row do not pick it up."""

    def setUp(self):
        super().setUp()
        self.core.put(A)
        self.reconcile(result_ids=[A])

    def test_it_is_not_in_the_verify_note_audience(self):
        db = sqlite3.connect(self.path)
        try:
            self.assertEqual(verify_notify._decider_approvals(db, run_id=None, since_hours=None, now=None), [])
        finally:
            db.close()

    def test_it_counts_against_no_users_daily_cap(self):
        db = sqlite3.connect(self.path)
        try:
            self.assertEqual(decide.approvals_today_by_user(db, "2026-11-01T00:00:00Z"), {})
        finally:
            db.close()

    def test_the_decision_tables_stay_append_only(self):
        db = sqlite3.connect(self.path)
        try:
            with self.assertRaises(sqlite3.DatabaseError):
                db.execute("UPDATE decisions SET reason = 'x'")
            with self.assertRaises(sqlite3.DatabaseError):
                db.execute("DELETE FROM decision_outcomes")
        finally:
            db.close()


class CoreWalk(unittest.TestCase):
    """The all-time read: slices of `updatedAt`, halved when the replica cancels one."""

    def setUp(self):
        self.core = Core()

    def walk(self, start="2026-11-15T00:00:00Z", now=NOW):
        return pl.core_since(self.core, start, now=now)

    def test_the_walk_covers_the_span_and_its_last_slice_is_open_ended(self):
        self.core.put(A, updated="2026-11-15T01:00:00Z")
        self.core.put(B, updated="2026-11-15T09:30:00Z")   # changed after the walk began
        self.assertEqual(sorted(self.walk()), [A, B])
        windows = [_STAMP_IN.findall(sql) for kind, sql in self.core.calls]
        self.assertEqual(windows, [["2026-11-15T00:00:00Z", "2026-11-15T06:00:00Z"], ["2026-11-15T06:00:00Z"]])

    def test_a_slice_the_replica_cancels_is_halved_until_it_answers(self):
        self.core.put(A, updated="2026-11-15T01:00:00Z")
        self.core.put(B, updated="2026-11-15T04:00:00Z")
        self.core.fail = lambda kind, sql: (kind == "window" and "2026-11-15T00:00:00Z" in sql
                                            and "2026-11-15T06:00:00Z" in sql)
        self.assertEqual(sorted(self.walk()), [A, B])
        self.assertIn(["2026-11-15T00:00:00Z", "2026-11-15T03:00:00Z"],
                      [_STAMP_IN.findall(sql) for _, sql in self.core.calls])
        self.assertNotIn("ids", self.core.kinds())

    def test_the_smallest_slice_is_read_by_id_and_keeps_only_precedent_approvals(self):
        """One UPDATE stamps its whole batch with one `updatedAt`: no smaller slice separates it."""
        self.core.put(A, updated="2026-11-15T01:00:00Z", sets=2000, own=())
        self.core.put(B, updated="2026-11-15T01:00:00Z", via="", run="", at="", sets=-1)   # changed, not ours
        self.core.fail = lambda kind, sql: kind == "window" and holds(sql, "2026-11-15T01:00:00Z")
        got = self.walk()
        self.assertEqual(sorted(got), [A])
        self.assertEqual(got[A].sets, 2000)
        self.assertEqual(self.core.kinds().count("ids"), 1)
        self.assertEqual([_STAMP_IN.findall(sql) for kind, sql in self.core.calls if kind == "ids"],
                         [["2026-11-15T00:56:15Z", "2026-11-15T01:07:30Z"]])   # 675 s: at or under MIN_SLICE_S
        self.assertIn("by_id", self.core.kinds())

    def test_a_by_id_chunk_the_replica_cancels_is_halved_down_to_one_id(self):
        ids = sorted(f"{n:08d}-1111-4111-8111-111111111111" for n in range(8))
        for rid in ids:
            self.core.put(rid)
        self.core.fail = lambda kind, sql: len(_UUID_IN.findall(sql.split("id IN (", 1)[1])) > 2
        self.assertEqual(sorted(pl.core_by_id(ids, self.core)), ids)
        self.core.fail = lambda kind, sql: ids[5] in sql
        with self.assertRaises(pl.CoreUnread) as caught:
            pl.core_by_id(ids, self.core)
        self.assertIn(ids[5], str(caught.exception))

    def test_a_slice_that_answers_neither_way_is_an_unread_core(self):
        self.core.put(A, updated="2026-11-15T01:00:00Z")
        self.core.fail = lambda kind, sql: kind != "by_id" and holds(sql, "2026-11-15T01:00:00Z")
        with self.assertRaises(pl.CoreUnread) as caught:
            self.walk()
        self.assertIn("the list of changed ids", str(caught.exception))

    def test_core_time_is_written_the_way_ledger_readers_compare_it(self):
        self.assertEqual(pl.ledger_time(CORE_AT), LEDGER_AT)
        self.assertEqual(pl.ledger_time("2026-11-15T09:36:55.643006+02:00"), LEDGER_AT)
        self.assertEqual(pl.ledger_time("2026-11-15T07:36:55"), "")    # no zone: not guessed
        self.assertEqual(pl.ledger_time(""), "")

    def test_no_statement_can_write_and_a_bad_id_or_time_never_becomes_sql(self):
        for sql in (pl.by_id_sql([A]), pl.window_sql(LEDGER_AT, None), pl.ids_changed_sql(LEDGER_AT, LEDGER_AT)):
            self.assertTrue(sql.startswith("SELECT "), sql)
            self.assertIn("postgresql_core.system.query", sql)
            self.assertIsNone(re.search(r"\b(update|insert|delete|alter|drop|truncate)\b", sql, re.I), sql)
        with self.assertRaises(ValueError):
            pl.by_id_sql([A, "x' OR 1=1 --"])
        with self.assertRaises(ValueError):
            pl.window_sql("2026-11-15' --", None)
        with self.assertRaises(ValueError):
            pl.ids_changed_sql(LEDGER_AT, "now()")


class Backfill(LedgerCase):
    def fill(self):
        self.core.put(A, run="prev-2026-11-14T10", at="2026-11-14T10:02:00.5+00:00", updated="2026-11-14T10:02:00Z")
        self.core.put(B, run="prev-2026-11-14T10", at="2026-11-14T10:02:00.5+00:00", updated="2026-11-14T10:02:00Z",
                      sets=2, own=())
        self.core.put(C, updated="2026-11-15T07:36:55Z")

    def test_the_plan_writes_nothing_and_no_claims_table(self):
        self.fill()
        before = self.snapshot()
        out = self.backfill(apply=False)
        self.assertEqual((out["mode"], out["core_precedent_approvals"], out["missing"], out["inserted"]),
                         ("plan", 3, 3, 0))
        self.assertEqual(self.snapshot(), before)
        self.assertEqual(self.one("SELECT count(*) FROM sqlite_master WHERE name = 'precedent_claims'"), 0)

    def test_it_inserts_what_is_missing_and_a_second_run_inserts_zero(self):
        self.fill()
        first = self.backfill()
        self.assertEqual((first["inserted"], first["missing"], first["already_present"]), (3, 3, 0))
        before = self.snapshot()
        second = self.backfill(batch="precedent-backfill-t2")
        self.assertEqual((second["inserted"], second["missing"], second["already_present"]), (0, 0, 3))
        self.assertEqual(self.snapshot(), before)
        self.assertEqual(self.one("SELECT count(*) FROM decisions"), 3)
        self.assertEqual(self.one("SELECT count(*) FROM decision_outcomes WHERE outcome = 'approved'"), 3)

    def test_a_backfilled_row_names_its_batch_and_carries_cores_run_and_time(self):
        self.fill()
        self.backfill()
        rows = {d[0]: d for d in self.decisions()}
        for rid in (A, B, C):
            self.assertTrue(rows[rid][6].endswith(" [backfill precedent-backfill-t1]"), rows[rid][6])
        self.assertEqual(rows[A][1:3], ("prev-2026-11-14T10", "2026-11-14T10:02:00Z"))
        self.assertEqual(rows[C][1:3], (RUN, LEDGER_AT))
        self.assertEqual(self.q("SELECT DISTINCT actor FROM request_state"), [("precedent-backfill",)])
        # the row carries when core approved, never when the backfill ran: it is in no later hour's count
        self.assertEqual(self.one(APPLIED_SINCE, "2026-11-15T07:36:55Z"), 0)
        self.assertEqual(self.one(APPLIED_SINCE, "2026-11-15T07:36:54Z"), 1)

    def test_a_live_row_is_already_present_and_only_the_gap_is_backfilled(self):
        self.fill()
        self.reconcile(result_ids=[C])
        out = self.backfill()
        self.assertEqual((out["inserted"], out["already_present"]), (2, 1))
        got = pl.report(self.path)
        self.assertEqual((got["precedent_approvals"], got["live"], got["backfilled"]),
                         (3, 1, {"precedent-backfill-t1": 2}))

    def test_every_approval_core_returned_is_in_exactly_one_class(self):
        self.fill()
        self.core.put(D, status="user_verification_needed", updated="2026-11-14T12:00:00Z")   # taken back
        self.core.put(P1, deleted=True, updated="2026-11-14T12:00:00Z")
        self.core.put(P2, at="", updated="2026-11-14T12:00:00Z")
        out = self.backfill()
        self.assertEqual(out["core_precedent_approvals"], 6)
        self.assertEqual(sum(out[k] for k in ("missing", "already_present", "not_approved_now", "deleted",
                                              "unreadable_approval")), 6)
        self.assertEqual((out["not_approved_now"], out["deleted"], out["unreadable_approval"], out["inserted"]),
                         (1, 1, 1, 3))
        self.assertEqual(sorted(d[0] for d in self.decisions()), [A, B, C])

    def test_an_approval_core_recorded_with_no_run_name_is_backfilled_under_its_approval_time(self):
        # 9,465 of the 10,384 approvals in core on 2026-11-15 are two UPDATEs of 2026-11-10 whose
        # `approval` object has no `run` key. Left out, the backfill closed 919 of the gap.
        at = "2026-11-10T12:22:56.104+00:00"
        self.core.put(A, run="", at=at, updated="2026-11-14T10:00:00Z", sets=5000, own=())
        self.core.put(B, run="", at=at, updated="2026-11-14T10:00:00Z", sets=5000, own=())
        self.core.put(C, updated="2026-11-15T07:36:55Z")
        first = self.backfill()
        self.assertEqual((first["inserted"], first["missing"], first["missing_with_no_run_name"],
                          first["unreadable_approval"]), (3, 3, 2, 0))
        rows = {d[0]: d for d in self.decisions()}
        for rid in (A, B):
            self.assertEqual(rows[rid][1:3], ("prev-unnamed-2026-11-10T12:22:56Z", "2026-11-10T12:22:56Z"))
            self.assertIn("core recorded no run name", rows[rid][6])
            self.assertNotIn("precedent_v1 run ", rows[rid][6])
        self.assertEqual(rows[C][1], RUN)
        before = self.snapshot()
        second = self.backfill(batch="precedent-backfill-t2")
        self.assertEqual((second["inserted"], second["already_present"], second["missing_with_no_run_name"]),
                         (0, 3, 0))
        self.assertEqual(self.snapshot(), before)

    def test_a_run_name_that_is_not_one_is_unreadable_and_gets_no_row(self):
        self.fill()
        self.core.put(D, run="prev 2026'; --", updated="2026-11-14T12:00:00Z")
        out = self.backfill()
        self.assertEqual((out["inserted"], out["unreadable_approval"]), (3, 1))
        self.assertNotIn(D, [d[0] for d in self.decisions()])

    def test_a_core_half_read_inserts_nothing(self):
        self.fill()
        self.core.fail = lambda kind, sql: kind != "by_id" and holds(sql, "2026-11-15T07:36:55Z")   # C's slice
        before = self.snapshot()
        with self.assertRaises(pl.CoreUnread):
            self.backfill()
        self.assertEqual(self.snapshot(), before)

    def test_an_empty_answer_is_an_unread_core(self):
        with self.assertRaises(pl.CoreUnread):
            self.backfill()
        self.assertEqual(self.decisions(), [])

    def test_a_batch_id_that_is_not_one_is_refused_before_core_is_read(self):
        with self.assertRaises(ValueError):
            self.backfill(batch="x] [backfill other")
        self.assertEqual(self.core.calls, [])


class PlanLine(unittest.TestCase):
    def test_the_last_plan_line_of_a_programs_output_wins(self):
        text = f"candidates: 2\n{plan_line([(A, [P1])])}\nnoise\n{plan_line([(B, [P1, P2, P3])])}\n"
        self.assertEqual(pl.parse_plan(text), {"run": RUN, "batch": [(B, [P1, P2, P3])]})

    def test_a_line_this_cannot_act_on_is_refused(self):
        bad = {
            "no line": "safe to approve: 3\n",
            "not json": '{"marker": "PREV2_PLAN", "run": ',
            "no run": plan_line([(A, [P1])], run=""),
            "run with a space": plan_line([(A, [P1])], run="prev 1"),
            "batch not a list": json.dumps({"marker": pl.PLAN_MARKER, "run": RUN, "batch": {A: [P1]}}),
            "bad request id": plan_line([("nope", [P1])]),
            "repeated request": plan_line([(A, [P1]), (A, [P2])]),
            "no precedent": plan_line([(A, [])]),
            "bad precedent id": plan_line([(A, [P1, "x"])]),
        }
        for name, text in bad.items():
            with self.subTest(name), self.assertRaises(pl.NoPlan):
                pl.parse_plan(text)


class RealEntrypoint(LedgerCase):
    """The unit runs this as a FILE; so do these."""

    def run_file(self, *args, stdin="", env=None):
        return subprocess.run([sys.executable, str(MODULE), *args], input=stdin, capture_output=True,
                              text=True, timeout=60, check=False, env={**os.environ, **(env or {})})

    def test_claim_reads_the_plan_from_stdin_and_exits_0_only_with_every_claim_held(self):
        text = f"safe to approve: 2\n{plan_line([(A, [P1, P2, P3]), (B, [P1, P2, P3])])}\n"
        p = self.run_file("claim", "--ledger", self.path, stdin=text)
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(json.loads(p.stdout), {"run": RUN, "offered": 2, "claimed": 2, "already": 0})
        self.assertEqual([c[2] for c in self.claims()], ["claimed", "claimed"])
        self.assertEqual(self.decisions(), [])

    def test_no_plan_line_is_exit_2_and_nothing_is_claimed(self):
        p = self.run_file("claim", "--ledger", self.path, stdin="safe to approve: 0\n")
        self.assertEqual(p.returncode, pl.EXIT_NO_PLAN)
        self.assertIn("nothing was written", p.stderr)
        self.assertEqual(self.one("SELECT count(*) FROM sqlite_master WHERE name = 'precedent_claims'"), 0)

    def test_a_path_with_no_ledger_is_exit_3_and_no_file_is_made(self):
        missing = str(Path(self.tmp.name) / "nope.sqlite3")
        for args, stdin in ((("claim",), plan_line([(A, [P1])])), (("report",), ""), (("backfill",), "")):
            with self.subTest(args):
                p = self.run_file(*args, "--ledger", missing, stdin=stdin)
                self.assertEqual(p.returncode, pl.EXIT_LEDGER, p.stderr)
                self.assertFalse(Path(missing).exists())

    def test_the_kill_file_stops_the_scheduled_reconcile_before_it_reads_anything(self):
        self.claim([(A, [P1, P2, P3])])
        kill = Path(self.tmp.name) / "precedent-ledger.disabled"
        kill.touch()
        p = self.run_file("reconcile", "--since-hours", "6", "--ledger", self.path,
                          env={"PRECEDENT_LEDGER_KILL_FILE": str(kill)})
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(json.loads(p.stdout), {"skipped": "kill_file"})
        self.assertEqual([c[2] for c in self.claims()], ["claimed"])

    def test_report_reads_a_ledger_no_write_has_touched(self):
        p = self.run_file("report", "--ledger", self.path)
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(json.loads(p.stdout), {"precedent_approvals": 0, "live": 0, "backfilled": {},
                                                "claims": {}, "oldest_open_claim": None})
        self.assertEqual(self.one("SELECT count(*) FROM sqlite_master WHERE name = 'precedent_claims'"), 0)

    def test_main_runs_the_three_steps_against_the_replica_client(self):
        """In process, with the one Trino client replaced: claim, then core says approved, then reconcile."""
        with mock.patch.object(verify_notify, "trino", lambda sql, cmd=None: self.core(sql)), \
                mock.patch("sys.stdout"), mock.patch.dict(os.environ, {"PRECEDENT_LEDGER_KILL_FILE": "/nonexistent"}):
            self.assertEqual(pl.main(["claim", plan_line([(A, [P1, P2, P3])]), "--ledger", self.path]), 0)
            self.core.put(A)
            self.assertEqual(pl.main(["reconcile", "--result", result_line([A]), "--ledger", self.path]), 0)
            self.assertEqual(pl.main(["backfill", "--apply", "--ledger", self.path]), 0)
        self.assertEqual(len(self.decisions()), 1)
        self.assertEqual(self.claims(), [(A, RUN, "landed", f"approved under run {RUN}")])

    def test_an_unread_core_is_exit_4_and_says_nothing_was_written(self):
        self.claim([(A, [P1, P2, P3])])

        def down(sql, cmd=None):
            raise RuntimeError("trino failed: connection refused")
        with mock.patch.object(verify_notify, "trino", down), mock.patch("sys.stderr") as err, \
                mock.patch.dict(os.environ, {"PRECEDENT_LEDGER_KILL_FILE": "/nonexistent"}):
            self.assertEqual(pl.main(["reconcile", "--ledger", self.path]), pl.EXIT_CORE_UNREAD)
        self.assertIn("nothing was written", "".join(c.args[0] for c in err.write.call_args_list))
        self.assertEqual([c[2] for c in self.claims()], ["claimed"])
        self.assertEqual(reconcile_approved.EXIT_CORE_UNREAD, pl.EXIT_CORE_UNREAD)


if __name__ == "__main__":
    unittest.main()
