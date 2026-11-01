"""decision-told (Fable [key=decided-not-told-531] + 197): core's own decision notice, one per (user, profile)
group, re-read at signing, ladder signed dry -> ONE real (confirmed) -> <=100/day. Hermetic: fake replica, fake route,
temp ledgers."""
from __future__ import annotations

import contextlib
import importlib.util
import io
import json
import sqlite3
import sys
import tempfile
import threading
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from credit_review import decision_told as dt  # noqa: E402

_spec = importlib.util.spec_from_file_location("credit_decision_told_cli",
                                               Path(__file__).resolve().parents[1] / "credit-decision-told.py")
cli = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(cli)

A1 = "a1111111-1111-4111-8111-111111111111"
A2 = "a2222222-2222-4222-8222-222222222222"
B1 = "b1111111-1111-4111-8111-111111111111"
C1 = "c1111111-1111-4111-8111-111111111111"
D1 = "d1111111-1111-4111-8111-111111111111"
D2 = "d2222222-2222-4222-8222-222222222222"
D3 = "d3333333-3333-4333-8333-333333333333"
NOW = datetime.now(timezone.utc)
#: the one clock the midnight test may use: 30 s before a UTC midnight, far from any real "today" a CI run can have
FROZEN_MIDNIGHT_EVE = datetime(1999, 12, 31, 23, 59, 30, tzinfo=timezone.utc)


def list_file(users):
    doc = {"class": "decided_not_told_531", "counts": {}, "generated_at": "x", "query_sha": "q", "ruling": "r",
           "source": "s", "users": [{"user_id": str(u), "paid": paid, "class": "c", "request_ids": [f[0] for f in fs],
                                     "facts": [[f[0], f[1], "2026-10-26"] for f in fs]} for u, paid, fs in users]}
    p = Path(tempfile.mkdtemp()) / "list.json"
    p.write_bytes(json.dumps(doc).encode())
    return str(p), dt.file_sha(p.read_bytes())


USERS = [(10, False, [(A1, "approved"), (A2, "approved")]),
         (20, True, [(B1, "approved")]),
         (30, True, [(C1, "rejected")]),
         (40, True, [(D1, "approved"), (D2, "approved"), (D3, "approved")])]

LIVE = {A1: ["approved", "false", "false", "w", "p1"], A2: ["approved", "false", "false", "w", "p1"],
        B1: ["approved", "false", "false", "w", "p2"], C1: ["rejected", "false", "false", "w", "p3"],
        D1: ["approved", "false", "false", "w", "p4"], D2: ["approved", "false", "false", "w", "p4"],
        D3: ["approved", "false", "false", "w2", "p5"]}


def replica(rows):
    def q(sql):
        return [[rid, *rows[rid]] for rid in rows if f"'{rid}'" in sql]
    return q


def ledgers():
    d = tempfile.mkdtemp()
    v = f"{d}/v.sqlite3"
    db = sqlite3.connect(v)
    db.execute("CREATE TABLE verify_messages (id INTEGER PRIMARY KEY, status TEXT, request_ids_json TEXT, day TEXT, "
               "sent_at TEXT)")
    db.commit()
    return f"{d}/l.sqlite3", v


class Route:
    """Core's route: echoes an affirmative report naming the subjects it accepts (all requested, by default)."""

    def __init__(self, sent=True, refused=(), body=None, on_call=None):
        self.calls, self.sent, self.refused, self.fixed, self.on_call = [], sent, list(refused), body, on_call

    def __call__(self, b):
        self.calls.append(b)
        if self.on_call:
            self.on_call(b)
        if self.fixed is not None:
            return self.fixed
        rep = {"dryRun": not b["apply"], "userId": str(b["userId"]), "copyRef": b["copyRef"], "channel": "live",
               "group": {"workspaceId": "w", "profileId": "p", "subjects": list(b["subjectIds"])},
               "blockedBy": [], "sent": False}
        if self.refused:
            rep["refusedSubjects"] = self.refused
        if b["apply"]:
            if self.sent:
                rep["sent"], rep["outcome"] = True, "sent"
        else:
            rep["outcome"] = "would_send"
        return rep


SEAMS = {"--ledger": "ledger", "--verify-ledger": "verify_ledger", "--kill-file": "kill_file"}


def seam_main(argv, **kw):
    """Tests keep the old argv shape for readability; the gate paths are lifted out of argv and passed through the
    function's keyword TEST SEAMS (the real CLI has no such flags - see test_gate_paths_are_not_argv)."""
    argv, seams = list(argv), {}
    for flag, name in SEAMS.items():
        while flag in argv:
            i = argv.index(flag)
            seams[name] = argv[i + 1]
            del argv[i:i + 2]
    return cli.main(argv, **seams, **kw)


def run(argv, route, live=LIVE):
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        rc = seam_main(argv, query=replica(live), caller=route)
    return rc, json.loads(buf.getvalue())


class Base(unittest.TestCase):
    def setUp(self):
        self.lst, self.sha = list_file(USERS)
        self.led, self.ver = ledgers()
        self.kill = str(Path(tempfile.mkdtemp()) / "kill")
        self.base = ["--list", self.lst, "--list-sha", self.sha, "--ledger", self.led, "--verify-ledger", self.ver,
                     "--kill-file", self.kill]
        self.dry = str(Path(tempfile.mkdtemp()) / "dry.json")

    def signed_dry(self, route=None):
        route = route or Route()
        rc, out = run(["dry", *self.base, "--limit", "10", "--out", self.dry], route)
        self.assertEqual(rc, 0)
        return route, out

    def note(self, rid, day):
        db = sqlite3.connect(self.ver)
        db.execute("INSERT INTO verify_messages (status, request_ids_json, day, sent_at) VALUES ('sent', ?, ?, ?)",
                   (json.dumps([rid]), day, f"{day}T09:00:00Z"))
        db.commit()


class PlanTest(Base):
    def test_a_list_that_moved_is_refused(self):
        rc, out = run(["plan", *self.base[:2], "--list-sha", "000000000000", *self.base[4:]], Route())
        self.assertEqual(rc, 2)
        self.assertIn("!= the signed sha", out["refused"])

    def test_plan_paid_first_biggest_group_first_later_groups_listed(self):
        rc, out = run(["plan", *self.base], Route())
        self.assertEqual([(u["user_id"], u["copy_ref"]) for u in out["first"]],
                         [(20, "decision-approved"), (30, "decision-rejected"), (40, "decision-approved"),
                          (10, "decision-approved")])
        u40 = out["first"][2]
        self.assertEqual((u40["group_key"], u40["subject_ids"]), ("w|p4", sorted([D1, D2])))
        self.assertEqual(u40["later_groups"], [{"group_key": "w2|p5", "subject_ids": [D3]}])

    def test_rows_core_already_told_moved_or_deleted_are_dropped(self):
        live = {**LIVE, A1: ["approved", "false", "true", "w", "p1"],
                B1: ["user_verification_needed", "false", "false", "w", "p2"], C1: ["rejected", "true", "false", "w", "p3"]}
        rc, out = run(["plan", *self.base], Route(), live)
        self.assertEqual(out["held"], {"nothing_left": 2})
        self.assertEqual(out["first"][1]["subject_ids"], [A2])

    def test_a_pre_decision_status_note_rides_along_and_a_note_today_waits(self):
        self.note(B1, (NOW - timedelta(days=3)).strftime("%Y-%m-%d"))
        rc, out = run(["plan", *self.base], Route())
        self.assertEqual((out["first"][0]["user_id"], out["first"][0]["prior_status_note"]), (20, [1]))
        self.assertEqual(out["with_prior_status_note"], 1)
        self.note(C1, NOW.strftime("%Y-%m-%d"))
        rc, out = run(["plan", *self.base], Route())
        self.assertEqual(out["held"], {"status_note_today": 1})

    def test_a_partial_replica_read_holds_the_whole_user(self):
        live = {k: v for k, v in LIVE.items() if k != A2}                      # A2 (user 10) missing from the read
        rc, out = run(["plan", *self.base], Route(), live)
        self.assertEqual(out["held"], {"replica_incomplete": 1})
        self.assertNotIn(10, [u["user_id"] for u in out["first"]])
        self.signed_dry()                                                       # complete read: 10 signed with A1+A2
        rc, out = run(["apply", *self.base, "--signed", self.dry, "--limit", "1"], Route())
        route = Route()
        run(["apply", *self.base, "--signed", self.dry, "--limit", "9", "--readback-ok", out["run_id"]], route, live)
        self.assertNotIn(10, [c["userId"] for c in route.calls])                # never sends A1 alone

    def test_an_unreadable_replica_refuses_everything(self):
        def boom(sql):
            raise dt.DecisionToldError("replica down")
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            rc = seam_main(["plan", *self.base], query=boom, caller=Route())
        self.assertEqual(rc, 2)

    def test_mixed_decisions_hold(self):
        p = dt.plan([{"user_id": 1, "paid": True, "requests": [{"request_id": A1, "status": "approved"},
                                                              {"request_id": C1, "status": "rejected"}]}],
                    {A1: ("approved", False, False, "w", "p"), C1: ("rejected", False, False, "w", "p")}, {}, {}, NOW)
        self.assertEqual(p[0].hold, "mixed_decisions")


class GateInputsTest(Base):
    """r5 [key=unattended]: no argv or env moves the ledger the ladder counts, the kill file or the confirmer; the
    founder account is refused in code."""

    def test_gate_paths_are_not_argv(self):
        for flag in ("--ledger", "--verify-ledger", "--kill-file"):
            with self.assertRaises(SystemExit), contextlib.redirect_stderr(io.StringIO()):
                cli.main(["plan", "--list", self.lst, "--list-sha", self.sha, flag, "/tmp/elsewhere"],
                         query=replica(LIVE), caller=Route())

    def test_the_real_entry_uses_the_constant_paths(self):
        import inspect
        sig = inspect.signature(cli.main)
        self.assertEqual((sig.parameters["ledger"].default, sig.parameters["verify_ledger"].default,
                          sig.parameters["kill_file"].default),
                         ("/var/lib/hydra/credit-review/ledger.sqlite3", "/var/lib/hydra/credit-review/ledger.sqlite3",
                          "/etc/hydra/credit-decision-told.disabled"))
        self.assertIn("if __name__ == \"__main__\":\n    sys.exit(main())", Path(cli.__file__).read_text())

    def test_the_confirmer_script_is_a_constant_no_env_swaps_it(self):
        import os
        seen = []
        real = cli.dt.admin_caller
        cli.dt.admin_caller = lambda script, *a, **k: seen.append(script) or Route()
        os.environ["CREDIT_REVIEW_ADMIN_SCRIPT"] = "/tmp/evil.sh"
        try:
            with contextlib.redirect_stdout(io.StringIO()):
                seam_main(["dry", *self.base, "--limit", "1"], query=replica(LIVE))
        finally:
            cli.dt.admin_caller = real
            os.environ.pop("CREDIT_REVIEW_ADMIN_SCRIPT", None)
        self.assertEqual(seen, ["/opt/hydra/skills-all/muso-ops-admin/scripts/muso-admin-api.sh"])

    def test_a_list_naming_user_15_is_refused_whole(self):
        lst, sha = list_file(USERS + [(15, True, [("f1111111-1111-4111-8111-111111111111", "approved")])])
        route = Route()
        rc, out = run(["dry", "--list", lst, "--list-sha", sha, *self.base[4:]], route)
        self.assertEqual((rc, route.calls), (2, []))
        self.assertIn("user 15", out["refused"])

    def test_run_refuses_user_15_even_from_a_hand_built_plan(self):
        p = dt.Plan(15, True, "decision-approved", "g", [A1])
        db = sqlite3.connect(":memory:", isolation_level=None)
        route = Route()
        with self.assertRaisesRegex(dt.DecisionToldError, "never automated"):
            dt.run(db, [p], route, run_id="r", now=NOW, channel="live", apply=False, limit=5, kill_file=self.kill)
        self.assertEqual(route.calls, [])

    def test_an_unknown_send_stays_reserved_even_if_the_process_dies_mid_call(self):
        self.signed_dry()

        def dies(body):
            raise SystemExit("killed mid-call")
        with self.assertRaises(SystemExit), contextlib.redirect_stdout(io.StringIO()):
            seam_main(["apply", *self.base, "--signed", self.dry, "--limit", "1"], query=replica(LIVE), caller=dies)
        db = sqlite3.connect(self.led)
        self.assertEqual(db.execute("SELECT user_id, outcome FROM decision_told WHERE mode = 'apply'").fetchall(),
                         [(20, "attempt")])                                   # reserved; no outcome row
        route = Route()
        rc, out = run(["apply", *self.base, "--signed", self.dry, "--limit", "5", "--readback-ok", "x"], route)
        self.assertNotIn(20, [c["userId"] for c in route.calls])
        rc, out = run(["plan", *self.base], Route())
        self.assertEqual(out["held"].get("already_told"), 1)                   # never retried as new


class LadderTest(Base):
    def first_real(self):
        self.signed_dry()
        rc, out = run(["apply", *self.base, "--signed", self.dry, "--limit", "50"], Route())
        self.rb = ["--readback-ok", out["run_id"]]
        return out

    def test_dry_calls_the_route_with_apply_false_and_only_the_allowed_fields(self):
        route, out = self.signed_dry()
        self.assertEqual([c["userId"] for c in route.calls], [20, 30, 40, 10])
        for c in route.calls:
            self.assertEqual(sorted(c), ["apply", "channel", "copyRef", "subjectIds", "userId"])
            self.assertEqual((c["apply"], c["channel"]), (False, "live"))

    def test_an_absent_or_malformed_dry_report_is_never_signed(self):
        good = {"dryRun": True, "userId": "20", "copyRef": "decision-approved", "group": {"subjects": [B1]}, "blockedBy": [], "outcome": "would_send"}
        self.assertEqual(dt.report_subjects(good, dt.Plan(20, True, "decision-approved", "g", [B1]), apply=False), [B1])
        for bad in ({}, {"dryRun": True, "userId": "20", "copyRef": "decision-approved"},
                    {**good, "dryRun": False},
                    {**good, "group": {"subjects": [A1]}},
                    {**good, "outcome": "would_send_when_unblocked", "blockedBy": ["decisions_off"]},   # QA: core's shape
                    {**good, "blockedBy": ["hold_list_missing"]},
                    {**good, "refusedSubjects": [{"id": B1, "reason": "core_notice_sent"}]},
                    {**good, "outcome": "nothing_owed"}, {**good, "blockedBy": "x"}, {**good, "blockedBy": {}}):
            self.setUp()
            self.signed_dry(Route(body=bad))
            with self.assertRaisesRegex(dt.DecisionToldError, "0 affirmed"):
                dt.signed_subjects(json.loads(Path(self.dry).read_text()))

    def test_a_confirmed_send_with_a_refused_row_is_recorded_sent_and_the_refusal_kept(self):
        rep = {"dryRun": False, "userId": "20", "copyRef": "decision-approved", "group": {"subjects": [B1]},
               "blockedBy": [], "refusedSubjects": [{"id": "x", "reason": "deleted"}], "sent": True, "outcome": "sent"}
        self.assertEqual(dt.report_subjects(rep, dt.Plan(20, True, "decision-approved", "g", [B1]), apply=True), [B1])
        with self.assertRaises(dt.DecisionToldError):
            dt.report_subjects({**rep, "outcome": "deduped_7d"}, dt.Plan(20, True, "decision-approved", "g", [B1]),
                               apply=True)

    def test_a_refused_dry_row_is_not_signed(self):
        self.signed_dry(Route(refused=[{"id": B1, "reason": "core_notice_sent"}]))
        with self.assertRaises(dt.DecisionToldError):
            dt.signed_subjects(json.loads(Path(self.dry).read_text()))

    def test_the_first_live_send_needs_the_full_signed_dry_rung(self):
        rc, out = run(["dry", *self.base, "--limit", "1", "--out", self.dry], Route())       # QA: a 1-user dry file
        route = Route()
        rc, out = run(["apply", *self.base, "--signed", self.dry, "--limit", "1"], route)
        self.assertEqual((rc, route.calls), (2, []))
        self.assertIn("the rung needs 4", out["refused"])                         # all 4 eligible here (< 10)
        big = [(100 + i, True, [(f"e{i:07d}-1111-4111-8111-111111111111", "approved")]) for i in range(12)]
        lst, sha = list_file(big)
        live = {f[0]: ["approved", "false", "false", "w", f"p{u}"] for u, _, fs in big for f in fs}
        base = ["--list", lst, "--list-sha", sha, *self.base[4:]]
        run(["dry", *base, "--limit", "9", "--out", self.dry], Route(), live)
        rc, out = run(["apply", *base, "--signed", self.dry, "--limit", "1"], Route(), live)
        self.assertIn("has 9 affirmed user(s); the rung needs 10", out["refused"])
        run(["dry", *base, "--limit", "10", "--out", self.dry], Route(), live)
        route = Route()
        rc, out = run(["apply", *base, "--signed", self.dry, "--limit", "1"], route, live)
        self.assertEqual((rc, len(route.calls)), (0, 1))

    def test_apply_needs_a_signed_dry_run_for_this_list(self):
        rc, out = run(["apply", *self.base], Route())
        self.assertEqual(rc, 2)
        self.signed_dry()
        other, osha = list_file(USERS[:1])
        rc, out = run(["apply", "--list", other, "--list-sha", osha, *self.base[4:], "--signed", self.dry], Route())
        self.assertEqual((rc, out["refused"]), (2, "the signed dry run is for a different list"))

    def test_first_live_write_is_one_user_until_it_is_confirmed_then_never_twice(self):
        out = self.first_real()
        self.assertEqual(([r["user_id"] for r in out["results"]], out["results"][0]["outcome"]), ([20], "sent"))
        route = Route()
        rc, out = run(["apply", *self.base, "--signed", self.dry, "--limit", "50"], route)
        self.assertEqual((route.calls, out["stopped"]), ([], "readback_required"))   # no read-back named
        rc, out = run(["apply", *self.base, "--signed", self.dry, "--limit", "50", "--readback-ok", "nope"], route)
        self.assertEqual(route.calls, [])                                              # not a confirmed run
        rc, out = run(["apply", *self.base, "--signed", self.dry, "--limit", "50", *self.rb], route)
        self.assertEqual([c["userId"] for c in route.calls], [30, 40, 10])        # 20 is never sent again

    def test_an_unconfirmed_first_send_blocks_the_ladder(self):
        self.signed_dry()
        rc, out = run(["apply", *self.base, "--signed", self.dry, "--limit", "1"], Route(sent=False))
        self.assertEqual(out["results"][0]["outcome"], "error")
        route = Route()
        rc, out = run(["apply", *self.base, "--signed", self.dry, "--limit", "5", "--readback-ok", out["run_id"]],
                      route)
        self.assertEqual((route.calls, out["stopped"]), ([], "first_live_write_is_one_user"))

    def test_a_user_whose_rows_changed_since_signing_is_not_sent(self):
        self.first_real()
        live = {**LIVE, A1: ["approved", "false", "true", "w", "p1"], A2: ["approved", "false", "true", "w", "p1"]}
        route = Route()
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            seam_main(["apply", *self.base, "--signed", self.dry, "--limit", "9", *self.rb], query=replica(live),
                     caller=route)
        self.assertEqual([c["userId"] for c in route.calls], [30, 40])

    def test_the_second_profile_group_waits_for_the_slot_then_goes(self):
        self.first_real()
        run(["apply", *self.base, "--signed", self.dry, "--limit", "9", *self.rb], Route())
        rc, out = run(["plan", *self.base], Route())
        self.assertEqual(out["held"].get("slot_wait"), 1)                          # 40's w2|p5 group
        db = sqlite3.connect(self.led)
        old = (NOW - timedelta(days=dt.SLOT_DAYS + 1)).strftime("%Y-%m-%dT%H:%M:%SZ")
        db.execute("CREATE TEMP TABLE x AS SELECT * FROM decision_told")
        tried = dt.attempts(db)
        tried[40] = {k: old for k in tried[40]}
        hd, users = dt.load_list(Path(self.lst).read_bytes(), self.sha)
        core = {k: (v[0], v[1] == "true", v[2] == "true", v[3], v[4]) for k, v in LIVE.items()}
        p40 = [p for p in dt.plan(users, core, {}, tried, NOW) if p.user_id == 40][0]
        self.assertEqual((p40.hold, p40.group_key, p40.subject_ids), ("", "w2|p5", [D3]))

    def test_a_failed_send_stays_reserved(self):
        self.first_real()

        def boom(body):
            raise dt.DecisionToldError("HTTP 502")
        run(["apply", *self.base, "--signed", self.dry, "--limit", "1", *self.rb], boom)
        route = Route()
        run(["apply", *self.base, "--signed", self.dry, "--limit", "5", *self.rb], route)
        self.assertEqual([c["userId"] for c in route.calls], [40, 10])          # 30 stays reserved

    def test_the_day_cap_bounds_a_run(self):
        db = sqlite3.connect(self.led)
        dt.ensure_table(db)
        at = NOW.strftime("%Y-%m-%dT%H:%M:%SZ")
        db.execute("INSERT INTO decision_told (run_id, at, user_id, group_key, copy_ref, subject_ids_json, mode, "
                   "outcome) VALUES ('x', ?, 999, 'g', 'decision-approved', '[]', 'apply', 'sent')", (at,))
        db.execute("INSERT INTO decision_told (run_id, at, user_id, group_key, copy_ref, subject_ids_json, mode, "
                   "outcome) VALUES ('x', ?, 999, 'g', 'decision-approved', '[]', 'apply', 'attempt')", (at,))
        for i in range(dt.FIRST_DAY_CAP - 2):
            db.execute("INSERT INTO decision_told (run_id, at, user_id, group_key, copy_ref, subject_ids_json, mode, "
                       "outcome) VALUES ('x', ?, ?, 'g', 'decision-approved', '[]', 'apply', 'attempt')", (at, 1000 + i))
        db.commit()
        self.signed_dry()
        route = Route()
        rc, out = run(["apply", *self.base, "--signed", self.dry, "--limit", "50", "--readback-ok", "x"], route)
        self.assertEqual((len(route.calls), out["stopped"]), (1, "day_cap"))

    def test_a_batch_crossing_midnight_counts_each_attempt_on_its_own_utc_day(self):
        # FROZEN clock only (Fable 224): nothing here reads the real date or names a calendar day. Every timestamp -
        # the read-back run, the 99 seed rows, the batch's reservations - derives from FROZEN_MIDNIGHT_EVE.
        day1 = FROZEN_MIDNIGHT_EVE
        stamp = lambda t: t.strftime("%Y-%m-%dT%H:%M:%SZ")                     # noqa: E731
        db = sqlite3.connect(self.led, isolation_level=None)
        dt.ensure_table(db)
        earlier = stamp(day1 - timedelta(hours=3))
        db.execute("INSERT INTO decision_told (run_id, at, user_id, group_key, copy_ref, subject_ids_json, mode, "
                   "outcome) VALUES ('rb', ?, 999, 'g', 'decision-approved', '[]', 'apply', 'attempt')", (earlier,))
        db.execute("INSERT INTO decision_told (run_id, at, user_id, group_key, copy_ref, subject_ids_json, mode, "
                   "outcome) VALUES ('rb', ?, 999, 'g', 'decision-approved', '[]', 'apply', 'sent')", (earlier,))
        for i in range(dt.FIRST_DAY_CAP - 2):                                   # with 999: day 1 holds 99 users
            db.execute("INSERT INTO decision_told (run_id, at, user_id, group_key, copy_ref, subject_ids_json, mode, "
                       "outcome) VALUES ('x', ?, ?, 'g', 'decision-approved', '[]', 'apply', 'attempt')",
                       (earlier, 5000 + i))
        ticks = iter([day1 + timedelta(seconds=10),                  # 23:59:40: the 100th user of day 1
                      day1 + timedelta(seconds=40),                  # 00:00:10: day 2
                      day1 + timedelta(seconds=50),                  # 00:00:20: day 2
                      day1 + timedelta(seconds=60)])                 # 00:00:30: day 2
        hd, users = dt.load_list(Path(self.lst).read_bytes(), self.sha)
        core = {k: (v[0], v[1] == "true", v[2] == "true", v[3], v[4]) for k, v in LIVE.items()}
        plans = dt.plan(users, core, {}, dt.attempts(db), day1)
        signed = {p.user_id: (p.group_key, p.subject_ids) for p in plans if not p.hold}
        route = Route()
        dt.run(db, plans, route, run_id="midnight", now=day1, channel="live", apply=True, limit=9, signed=signed,
               kill_file=self.kill, readback_of="rb", clock=lambda: next(ticks))
        self.assertEqual(len(route.calls), 4)            # day 1 fills to 100 with the first; the other three are day 2's
        got = [r[0] for r in db.execute("SELECT substr(at, 1, 10) FROM decision_told WHERE run_id = 'midnight' AND "
                                        "outcome = 'attempt' ORDER BY id")]
        d1, d2 = day1.strftime("%Y-%m-%d"), (day1 + timedelta(days=1)).strftime("%Y-%m-%d")
        self.assertEqual(got, [d1, d2, d2, d2])

    def test_the_midnight_test_never_reads_the_real_clock(self):
        """Lint (Fable 224): the clock-sensitive test may use only the frozen clock - no real-clock helper, no
        datetime.now, no NOW, no literal date string."""
        import ast
        import inspect
        import textwrap
        src = textwrap.dedent(inspect.getsource(LadderTest.test_a_batch_crossing_midnight_counts_each_attempt_on_its_own_utc_day))
        tree = ast.parse(src)
        names = {n.id for n in ast.walk(tree) if isinstance(n, ast.Name)}
        attrs = {n.attr for n in ast.walk(tree) if isinstance(n, ast.Attribute)}
        for barred in ("NOW", "first_real", "signed_dry", "run", "seam_main"):
            self.assertNotIn(barred, names, barred)
        for barred in ("now", "utcnow", "today", "first_real", "signed_dry"):
            self.assertNotIn(barred, attrs, barred)
        literals = [n.value for n in ast.walk(tree) if isinstance(n, ast.Constant) and isinstance(n.value, str)]
        import re
        self.assertEqual([x for x in literals if re.search(r"\b(19|20)\d\d-\d\d-\d\d", x)], [])

    def test_two_concurrent_processes_never_pass_the_first_live_limit(self):
        self.signed_dry()
        lst2, sha2 = self.lst, self.sha
        calls, errs = [], []

        def go():
            try:
                db = sqlite3.connect(self.led, timeout=30, isolation_level=None)
                hd, users = dt.load_list(Path(lst2).read_bytes(), sha2)
                core = {k: (v[0], v[1] == "true", v[2] == "true", v[3], v[4]) for k, v in LIVE.items()}
                plans = dt.plan(users, core, {}, dt.attempts(db), NOW)
                signed = dt.signed_subjects(json.loads(Path(self.dry).read_text()))
                dt.run(db, plans, Route(on_call=calls.append), run_id=f"r{threading.get_ident()}", now=NOW,
                       channel="live", apply=True, limit=50, signed=signed, kill_file=self.kill)
            except Exception as exc:  # noqa: BLE001
                errs.append(exc)
        ts = [threading.Thread(target=go) for _ in range(4)]
        [t.start() for t in ts]
        [t.join() for t in ts]
        self.assertEqual((errs, len(calls)), ([], 1))

    def test_the_kill_file_stops_a_batch_mid_run(self):
        self.first_real()
        route = Route(on_call=lambda b: Path(self.kill).write_text("stop"))
        rc, out = run(["apply", *self.base, "--signed", self.dry, "--limit", "9", *self.rb], route)
        self.assertEqual((len(route.calls), out["stopped"]), (1, f"kill file {self.kill}"))

    def test_kill_file_stops_dry_and_apply_at_start(self):
        Path(self.kill).write_text("x")
        route = Route()
        rc, out = run(["dry", *self.base], route)
        self.assertEqual((rc, route.calls), (3, []))

    def test_the_admin_caller_turns_a_bodyless_200_into_an_error(self):
        d = Path(tempfile.mkdtemp())
        for out, ok in (('{"http_status": 200, "body": null}', False), ('{"http_status": 200, "raw": "x"}', False),
                        ('{"http_status": 409, "body": {"error": "x"}}', False),
                        ('{"http_status": 200, "body": {"dryRun": true}}', True)):
            sh = d / "api.sh"
            sh.write_text(f"#!/bin/bash\ncat <<'J'\n{out}\nJ\n")
            call = dt.admin_caller(str(sh))
            if ok:
                self.assertEqual(call({"userId": 1}), {"dryRun": True})
            else:
                with self.assertRaises(dt.DecisionToldError):
                    call({"userId": 1})

    def test_a_user_attempted_by_another_process_after_planning_is_skipped(self):
        self.first_real()
        db = sqlite3.connect(self.led, isolation_level=None)
        hd, users = dt.load_list(Path(self.lst).read_bytes(), self.sha)
        core = {k: (v[0], v[1] == "true", v[2] == "true", v[3], v[4]) for k, v in LIVE.items()}
        plans = dt.plan(users, core, {}, dt.attempts(db), NOW)
        db.execute("INSERT INTO decision_told (run_id, at, user_id, group_key, copy_ref, subject_ids_json, mode, "
                   "outcome) VALUES ('other', ?, 30, 'w|p3', 'decision-rejected', '[]', 'apply', 'attempt')",
                   (NOW.strftime("%Y-%m-%dT%H:%M:%SZ"),))
        route = Route()
        out = dt.run(db, plans, route, run_id="late", now=NOW, channel="live", apply=True, limit=9,
                     signed=dt.signed_subjects(json.loads(Path(self.dry).read_text())), kill_file=self.kill,
                     readback_of=self.rb[1])
        self.assertNotIn(30, [c["userId"] for c in route.calls])
        self.assertIn({"user_id": 30, "outcome": "already_attempted"}, out["results"])

    def test_ledger_is_append_only(self):
        self.signed_dry()
        db = sqlite3.connect(self.led)
        with self.assertRaises(sqlite3.DatabaseError):
            db.execute("DELETE FROM decision_told")


if __name__ == "__main__":
    unittest.main()
