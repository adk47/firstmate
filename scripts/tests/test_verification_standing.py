#!/usr/bin/env python3
"""scripts/verification-standing.py - the one page that answers where verifications stand.

Stdlib only, no network, no node-8: the script is imported and fed a fixture ledger, a fixture
snapshot and a fixture policy. What these cases hold:

* a number is the number in the durable state, in users;
* "could not read it" prints `unmeasured`, never 0 - including the snapshot that recorded its own
  failed read and saved 0 open;
* a stale snapshot is marked on every cell it feeds, with the stop file named;
* only a row the ledger calls `sent` is a tell;
* the page reads and never writes unless `--save` names a directory, and it fits one screen with
  the policy main ships;
* `--save`, the form the timer runs, fails on a number that has a writer and is unmeasured or
  stale, and on nothing else.
"""
import ast
import hashlib
import importlib.util
import io
import json
import os
import re
import shutil
import sqlite3
import sys
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from datetime import datetime, timedelta, timezone
from unittest import mock

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SCRIPT = os.path.join(REPO, "scripts", "verification-standing.py")
spec = importlib.util.spec_from_file_location("vstanding", SCRIPT)
vs = importlib.util.module_from_spec(spec)
spec.loader.exec_module(vs)

NOW = datetime(2026, 11, 15, 4, 0, tzinfo=timezone.utc)
POLICY = {"groups": {"credit": ["uvn-status", "proof-need-ask", "wait-apology"],
                     "claim": ["claim-status", "claim-proof-ask"]}}


def ago(**kw) -> str:
    return (NOW - timedelta(**kw)).strftime("%Y-%m-%dT%H:%M:%SZ")


def section(users, rows, told, approved, declined, oldest_h, age=None) -> dict:
    hold = min(5, users - told)
    none = {"users": 0, "rows": 0, "oldest_h": None}
    sec = {"buckets": {"told": {"users": told, "rows": told, "oldest_h": oldest_h / 2},
                       "untouched": {"users": users - told - hold, "rows": rows - told, "oldest_h": oldest_h},
                       "watch": {"users": hold, "rows": hold, "oldest_h": 1.0},
                       "docs_in": dict(none), "human": dict(none), "not_told": dict(none), "muted": dict(none)},
           "open_users": users, "open_rows": rows,
           "flow": {"approved": {"rows": approved * 10, "users": approved},
                    "declined": {"rows": declined * 10, "users": declined}}}
    if age is not None:
        sec["age"] = age
    return sec


def snapshot(at=None, **over) -> dict:
    snap = {"at": (at or NOW - timedelta(minutes=20)).strftime("%Y-%m-%d %H:%MZ"), "errors": [],
            "credits": section(800, 9000, 300, 60, 4, 24000.0),
            "claims": section(120, 150, 70, 10, 0, 1400.0),
            "ours": {"pending": 1000, "ours": 400, "never_asked": 150}, "intake_1h": {"requests": 4}}
    snap.update(over)
    return snap


class Fixture(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.dir = self.tmp.name
        self.ledger = os.path.join(self.dir, "ledger.sqlite3")
        self.snap = os.path.join(self.dir, "last.json")
        self.policy = os.path.join(self.dir, "policy.json")
        self.kill = os.path.join(self.dir, "report.disabled")
        self.out = os.path.join(self.dir, "sched")
        self.tick = os.path.join(self.out, "20261115T0350Z")
        db = sqlite3.connect(self.ledger)
        db.execute("CREATE TABLE verify_messages (id INTEGER PRIMARY KEY, campaign TEXT, kind TEXT, "
                   "user_key TEXT, account_id TEXT, status TEXT, created_at TEXT, updated_at TEXT, "
                   "sent_at TEXT, reason TEXT)")
        db.execute("CREATE TABLE decision_told (run_id TEXT, at TEXT, user_id INTEGER, copy_ref TEXT, "
                   "mode TEXT, outcome TEXT)")
        db.execute("CREATE TABLE decisions (id INTEGER PRIMARY KEY, run_id TEXT, decided_at TEXT, "
                   "request_id TEXT, decision TEXT, mode TEXT, evidence_kind TEXT)")
        db.execute("CREATE TABLE decision_outcomes (id INTEGER PRIMARY KEY, run_id TEXT, at TEXT, "
                   "request_id TEXT, action TEXT, outcome TEXT)")
        db.commit()
        db.close()
        self.write_snapshot(snapshot())
        self.write_tick([{"user": 1, "campaign": "uvn-status", "kind": "initial"}])
        with open(self.policy, "w") as f:
            json.dump(POLICY, f)

    def write_snapshot(self, snap):
        with open(self.snap, "w") as f:
            json.dump(snap, f)

    def write_tick(self, sent, stamp="20261115T0350Z", name="uvn-status-apply.json", raw=None):
        if os.path.isdir(self.out):
            for old in os.listdir(self.out):
                shutil.rmtree(os.path.join(self.out, old))
        tick = os.path.join(self.out, stamp)
        os.makedirs(tick, exist_ok=True)
        with open(os.path.join(tick, name), "w") as f:
            f.write(raw if raw is not None else json.dumps({"mode": "apply", "sent": sent}))

    def decision(self, request, at, kind="catalog", outcome=None, decision="approve", mode="apply"):
        """One decision row and, when `outcome` is given, the outcome row of the same run."""
        db = sqlite3.connect(self.ledger)
        db.execute("INSERT INTO decisions (run_id, decided_at, request_id, decision, mode, evidence_kind) "
                   "VALUES ('run-1', ?, ?, ?, ?, ?)", (at, request, decision, mode, kind))
        if outcome:
            db.execute("INSERT INTO decision_outcomes (run_id, at, request_id, action, outcome) "
                       "VALUES ('run-1', ?, ?, 'approve', ?)", (at, request, outcome))
        db.commit()
        db.close()

    def note(self, campaign, user, sent_at, status="sent", account=True, created_at=None, updated_at=None,
             reason=None):
        db = sqlite3.connect(self.ledger)
        db.execute("INSERT INTO verify_messages (campaign, kind, user_key, account_id, status, created_at, "
                   "updated_at, sent_at, reason) VALUES (?, 'initial', ?, ?, ?, ?, ?, ?, ?)",
                   (campaign, f"{user}@example.test", str(user) if account else None, status,
                    created_at or sent_at, updated_at or sent_at, sent_at, reason))
        db.commit()
        db.close()

    def notice(self, user, at, mode="apply", outcome="sent"):
        db = sqlite3.connect(self.ledger)
        db.execute("INSERT INTO decision_told VALUES ('r', ?, ?, 'decision-approved', ?, ?)",
                   (at, user, mode, outcome))
        db.commit()
        db.close()

    def build(self, **over):
        kw = dict(ledger=self.ledger, snapshot=self.snap, policy=self.policy, kill=self.kill,
                  out_root=self.out, now=NOW)
        kw.update(over)
        return vs.build(**kw)

    def family(self, page, name):
        return next(f for f in page["families"] if f["family"] == name)


class Cells(Fixture):
    def test_the_numbers_are_the_durable_state_in_users(self):
        for user in range(1, 15):                       # 14 users told today by one family
            self.note("uvn-status", user, ago(hours=3))
        for user in range(15, 22):                      # 7 more, three days ago
            self.note("proof-need-ask", user, ago(days=3, hours=1))
        self.notice(500, ago(hours=1))
        self.note("claim-proof-ask", 900, ago(hours=5))
        page = self.build()
        c = self.family(page, "credits")
        self.assertEqual(c["open"], {"value": 800, "stale": False})
        self.assertEqual((c["decided_24h"]["value"], c["decided_rows"]["value"]), (64, 640))
        self.assertEqual(c["told_24h"]["value"], 15)
        self.assertEqual(c["oldest_h"]["value"], 24000.0)
        self.assertEqual(c["last_send"]["value"], ago(hours=1))
        # 22 users told in 7 days -> 22/7 a day -> 800 open users / that
        self.assertAlmostEqual(c["days_to_zero"]["value"], 800 / (22 / 7))
        k = self.family(page, "claims")
        self.assertEqual((k["open"]["value"], k["told_24h"]["value"]), (120, 1))
        self.assertAlmostEqual(k["days_to_zero"]["value"], 120 / (1 / 7))
        text = vs.render(page)
        self.assertIn("credits", text)
        self.assertRegex(text, r"credits +800 +<=64 +15 ")      # 60 approved + 4 declined users
        self.assertRegex(text, r"claims +120 +10 +1 ")           # one outcome only: exact
        self.assertIn("the columns count users. requests: credits 9,000 open, 640 decided 24h; "
                      "claims 150 open, 100 decided 24h", text)
        self.assertIn("users waiting on us / on the user / on hold: credits 495 / 300 / 5, claims 45 / 70 / 5", text)
        self.assertFalse(vs.incomplete(page) and "~" in text)

    def test_one_user_told_by_two_families_is_one_user(self):
        self.note("uvn-status", 7, ago(hours=2))
        self.note("proof-need-ask", 7, ago(hours=1))
        self.note("wait-apology", 7, ago(hours=4), account=False)    # the email-only row, same person
        page = self.build()
        c = self.family(page, "credits")
        self.assertEqual(c["told_24h"]["value"], 1)
        self.assertEqual([s["told_24h"] for s in c["senders"]], [1, 1, 1, 0])

    def test_only_a_sent_row_is_a_tell(self):
        for i, status in enumerate(("attempted", "refused", "deferred", "duplicate_suppressed", "failed")):
            self.note("uvn-status", 100 + i, ago(hours=2), status=status)
        self.notice(1, ago(hours=1), mode="dry", outcome="dry_ok")
        self.notice(2, ago(hours=1), outcome="attempt")
        self.notice(3, ago(hours=1), outcome="error")
        # sent ten days ago; a proof tag moved updated_at to an hour ago
        self.note("uvn-status", 300, ago(days=10), updated_at=ago(hours=1))
        c = self.family(self.build(), "credits")
        self.assertEqual(c["told_24h"]["value"], 0)
        self.assertEqual(c["last_send"]["value"], ago(days=10))
        self.assertTrue(c["days_to_zero"].get("no_tells"))

    def test_no_tells_is_not_a_number(self):
        text = vs.render(self.build())
        self.assertIn("no tells 7d", text)
        self.assertNotIn("inf", text)
        self.assertIn("no send in 7 days: uvn-status (never), proof-need-ask (never)", text)

    def test_nothing_open_is_zero_days(self):
        self.write_snapshot(snapshot(claims=section(0, 0, 0, 3, 0, 0)))
        k = self.family(self.build(), "claims")
        self.assertEqual(k["days_to_zero"]["value"], 0.0)

    def test_a_row_without_sent_at_is_dated_by_created_at(self):
        self.note("uvn-status", 1, None, created_at=ago(hours=6), updated_at=ago(minutes=5))
        c = self.family(self.build(), "credits")
        self.assertEqual(c["told_24h"]["value"], 1)
        self.assertEqual(c["last_send"]["value"], ago(hours=6))

    def test_a_sent_row_with_no_readable_time_is_unmeasured_and_never_a_lower_count(self):
        """A sent row the page cannot date may be a user told today. Left out, `told 24h` reads
        lower than the truth and `last send` reads `never`: both are unmeasured instead."""
        self.note("claim-status", 50, ago(hours=2))
        for label, write, named in (
                ("a time that is not a time",
                 lambda: self.note("uvn-status", 2, None, created_at="not a time"), "uvn-status 1"),
                ("no time at all",
                 lambda: self.note("proof-need-ask", 2, None), "proof-need-ask 1"),
                ("a day that does not exist",
                 lambda: self.note("uvn-status", 2, "2026-13-45T00:00:00Z"), "uvn-status 1"),
                ("a decision notice", lambda: self.notice(2, "yesterday"), "decision notices 1")):
            with self.subTest(label):
                db = sqlite3.connect(self.ledger)
                db.execute("DELETE FROM verify_messages WHERE campaign != 'claim-status'")
                db.execute("DELETE FROM decision_told")
                db.commit()
                db.close()
                self.note("uvn-status", 1, ago(hours=6))          # a readable send beside it
                write()
                page = self.build()
                c, k = self.family(page, "credits"), self.family(page, "claims")
                why = f"sent rows with no readable time: {named}"
                for key in ("told_24h", "last_send", "per_day"):
                    self.assertEqual(c[key], {"unmeasured": why}, key)
                self.assertEqual(c["days_to_zero"], {"unmeasured": "told is unmeasured"})
                self.assertEqual(c["senders"], [])
                self.assertEqual(c["open"]["value"], 800)         # the snapshot's cells are not touched
                self.assertEqual(k["told_24h"]["value"], 1)       # nor the other family
                self.assertEqual(k["last_send"]["value"], ago(hours=2))
                broken = dict(vs.broken_cells(page))
                self.assertEqual(broken["credits told_24h"], why)
                self.assertEqual(broken["credits last_send"], why)
                self.assertNotIn("claims told_24h", broken)
                text = " ".join(vs.render(page).split())
                # told, (median: this fixture's snapshot has none), last send, days to zero
                self.assertIn("credits 800 <=64 unmeasured unmeasured 1,000d unmeasured unmeasured ", text)
                self.assertIn("claims 120 10 1 unmeasured 58d 11-15 02:00Z (2h00m) ", text)
                self.assertRegex(text, r"unmeasured, not zero - credits told 24h, credits last send"
                                       r"(, sent_this_tick)?: " + re.escape(why))

    def test_an_undated_row_of_a_sender_outside_the_policy_is_said_and_fails_no_family(self):
        self.note("uvn-status", 1, ago(hours=6))
        self.note("backlog-reply", 2, None, created_at="not a time")
        page = self.build()
        self.assertEqual(self.family(page, "credits")["told_24h"]["value"], 1)
        self.assertIn("sent rows outside these families with no readable time: "
                      "backlog-reply 1; not counted", page["notes"])

    def test_every_spelling_of_a_time_the_ledger_holds(self):
        want = datetime(2026, 11, 9, 19, 6, 57, tzinfo=timezone.utc)
        for raw in ("2026-11-09T19:06:57Z", "2026-11-09T19:06:57", "2026-11-09 19:06:57",
                    "2026-11-09 19:06:57.000+00", "2026-11-09 19:06:57.000000 UTC",
                    "2026-11-09T19:06:57+00:00"):
            self.assertEqual(vs.parse_ts(raw), want, raw)
        self.assertEqual(vs.parse_ts("2026-11-14 17:30Z"), datetime(2026, 11, 14, 17, 30, tzinfo=timezone.utc))
        for raw in ("", None, "soon", 5):
            self.assertIsNone(vs.parse_ts(raw))

    def test_a_sender_outside_the_policy_is_named(self):
        self.note("backlog-reply", 1, ago(hours=1))
        self.note("backlog-reply", 2, ago(hours=2))
        page = self.build()
        self.assertEqual(page["other_24h"], {"backlog-reply": 2})
        self.assertEqual(self.family(page, "credits")["told_24h"]["value"], 0)
        self.assertIn("told 24h by senders outside these families: backlog-reply 2", vs.render(page))

    def test_whose_move_it_is_uses_the_snapshot_writers_own_two_lists(self):
        spec = importlib.util.spec_from_file_location(
            "vqr", os.path.join(REPO, "scripts", "verification-queue-report.py"))
        vqr = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(vqr)
        buckets = {b: {"users": 0, "rows": 0, "oldest_h": None}
                   for b in vqr.AWAITING_US + vqr.AWAITING_USER + ("muted",)}
        for i, b in enumerate(vqr.AWAITING_US):
            buckets[b]["users"] = i + 1
        for b in vqr.AWAITING_USER:
            buckets[b]["users"] = 10
        buckets["muted"]["users"] = 7
        sec = section(0, 0, 0, 0, 0, 0)
        sec["buckets"] = buckets
        sec["open_users"] = sum(b["users"] for b in buckets.values())
        sec["open_rows"] = sec["open_users"]
        self.write_snapshot(snapshot(credits=sec))
        c = self.family(self.build(), "credits")
        self.assertEqual(c["waiting_us"]["value"], sum(range(1, len(vqr.AWAITING_US) + 1)))
        self.assertEqual(c["waiting_user"]["value"], 10 * len(vqr.AWAITING_USER))
        self.assertEqual(c["on_hold"]["value"], 7)

    def test_a_policy_group_with_no_row_is_said(self):
        with open(self.policy, "w") as f:
            json.dump({"groups": dict(POLICY["groups"], merge=["merge-pending"])}, f)
        self.assertIn("note: policy group `merge` has no row on this page", vs.render(self.build()))


class Tracking(Fixture):
    """The credit requests' five numbers: OURS, sent_this_tick, applied_1h, decisions_per_intake,
    held_evidence_unbounded."""

    def tracking(self, **over):
        page = self.build(**over)
        return page["tracking"], " ".join(vs.render(page).split()), page

    def test_each_number_is_the_durable_state(self):
        snap_at = NOW - timedelta(minutes=20)
        for i in range(12):                                         # the hour to the snapshot
            self.decision(f"r{i % 3}", (snap_at - timedelta(minutes=5 * i)).strftime("%Y-%m-%dT%H:%M:%SZ"),
                          decision="support", mode="judge")
        self.decision("old", (snap_at - timedelta(minutes=61)).strftime("%Y-%m-%dT%H:%M:%SZ"), mode="judge")
        self.decision("late", ago(minutes=5), mode="judge")         # after the snapshot: not its hour
        self.decision("a1", ago(minutes=50), outcome="approved")
        self.decision("a2", ago(minutes=59), outcome="approved")
        self.decision("a2", ago(minutes=58), outcome="approved")    # one request approved twice is one
        self.decision("a3", ago(minutes=61), outcome="approved")    # outside the hour
        for user in range(1, 8):                                    # the tick's own sends, in the ledger
            self.note("uvn-status", user, ago(minutes=5))
        t, text, page = self.tracking()
        self.assertEqual(t["ours"], {"value": 400, "stale": False, "pending": 1000, "never_asked": 150})
        self.assertEqual(t["sent_this_tick"], {"value": 7, "stale": False, "at": ago(minutes=10)})
        self.assertEqual(t["applied_1h"]["value"], 2)
        self.assertEqual(t["decisions_per_intake"],
                         {"value": 4.0, "stale": False, "decisions": 16, "intake": 4})   # 12 + the 4 approvals
        self.assertIn("credit requests: OURS 400 of 1,000 pending have no delivered ask "
                      "(150 with no ask row of any campaign) sent_this_tick 7 (tick 11-15 03:50Z (10m)); "
                      "applied_1h 2 decisions_per_intake 4.0 (16 decisions / 4 created); "
                      "held_evidence_unbounded unmeasured", text)

    def raw(self, sql, *args):
        db = sqlite3.connect(self.ledger)
        db.execute(sql, args)
        db.commit()
        db.close()

    def test_an_approved_outcome_with_no_readable_time_is_not_zero_applied(self):
        outcome = ("INSERT INTO decision_outcomes (run_id, at, request_id, action, outcome) "
                   "VALUES ('run-1', ?, 'a9', 'approve', ?)")
        self.decision("a1", ago(minutes=30), outcome="approved")
        self.raw(outcome, "soon", "skipped:lost_race")            # not an approval: says nothing here
        t, _, _ = self.tracking()
        self.assertEqual(t["applied_1h"]["value"], 1)
        for at in ("soon", None, "", "2026-11-15T99:00:00Z", "1763179200"):
            with self.subTest(at=at):
                self.raw("DELETE FROM decision_outcomes WHERE request_id = 'a9'")
                self.raw(outcome, at, "approved")
                t, text, page = self.tracking()
                why = "ledger rows with no readable time: approved outcomes 1"
                self.assertEqual(t["applied_1h"], {"unmeasured": why})
                self.assertEqual(t["decisions_per_intake"]["decisions"], 1)   # its own rows are readable
                self.assertIn("applied_1h unmeasured", text)
                self.assertIn(f"unmeasured, not zero - applied_1h: {why}", text)
                self.assertEqual(dict(vs.broken_cells(page))["applied_1h"], why)

    def test_a_decision_with_no_readable_time_is_not_zero_decisions_per_intake(self):
        self.decision("a1", ago(minutes=30), outcome="approved")
        for at in ("soon", None, "2026-11-15T99:00:00Z"):
            with self.subTest(at=at):
                self.raw("DELETE FROM decisions WHERE request_id = 'd9'")
                self.raw("INSERT INTO decisions (run_id, decided_at, request_id, decision, mode) "
                         "VALUES ('run-1', ?, 'd9', 'support', 'judge')", at)
                t, text, _ = self.tracking()
                why = "ledger rows with no readable time: decisions 1"
                self.assertEqual(t["decisions_per_intake"], {"unmeasured": why})
                self.assertEqual(t["applied_1h"]["value"], 1)     # the approvals are still readable
                self.assertIn("decisions_per_intake unmeasured", text)

    def test_a_sent_row_with_no_readable_time_is_not_zero_sent_this_tick(self):
        self.note("uvn-status", 1, ago(minutes=5))
        self.note("claim-status", 2, None, created_at="soon")     # not a family this tick sent
        self.assertEqual(self.tracking()[0]["sent_this_tick"]["value"], 1)
        for at in ("soon", None, "2026-11-15T99:00:00Z"):
            with self.subTest(at=at):
                self.raw("DELETE FROM verify_messages WHERE user_key = '9@example.test'")
                self.note("uvn-status", 9, None, created_at=at)
                t, text, _ = self.tracking()
                self.assertEqual(t["sent_this_tick"], {
                    "unmeasured": "sent rows with no readable time: uvn-status 1"})
                self.assertIn("sent_this_tick unmeasured", text)

    def test_an_approval_counts_whatever_its_evidence_kind(self):
        self.decision("a1", ago(minutes=30), outcome="approved")
        self.decision("p1", ago(minutes=20), kind="precedent", outcome="approved")
        self.decision("p0", ago(hours=30), kind="precedent", outcome="approved")
        t, text, _ = self.tracking()
        self.assertEqual(t["applied_1h"]["value"], 2)
        self.assertIn("applied_1h 2", text)

    def test_only_an_approved_outcome_is_applied(self):
        for i, outcome in enumerate(("shadow", "user_verification_needed", "unverified", "skipped:held",
                                     "error:timeout")):
            self.decision(f"x{i}", ago(minutes=10), outcome=outcome)
        self.decision("no-outcome", ago(minutes=10))
        self.assertEqual(self.tracking()[0]["applied_1h"]["value"], 0)

    def test_held_evidence_unbounded_is_unmeasured_until_a_writer_records_it(self):
        t, text, page = self.tracking()
        self.assertEqual(t["held_evidence_unbounded"], {"unmeasured": vs.HELD_UNMEASURED})
        self.assertIn("held_evidence_unbounded unmeasured", text)
        self.assertNotIn("held_evidence_unbounded 0", text)
        self.assertTrue(vs.incomplete(page))
        self.note("uvn-status", 1, ago(minutes=5), reason="evidence_unbounded")
        self.assertEqual(self.tracking()[0]["held_evidence_unbounded"], {"unmeasured": vs.HELD_UNMEASURED})

    def test_no_tick_is_not_zero_sent(self):
        shutil.rmtree(self.out)
        t, text, _ = self.tracking()
        self.assertEqual(t["sent_this_tick"],
                         {"unmeasured": f"no sender output at {self.out} (FileNotFoundError)"})
        self.assertIn("sent_this_tick unmeasured; applied_1h 0", text)
        self.assertFalse(os.path.exists(self.out))

    def test_a_tick_that_recorded_no_send_is_not_zero_sent(self):
        for raw in ('{"mode": "apply"}', '{"mode": "apply", "sent": null}', '{"mode": "apply", "sent": 3}',
                    "{", "[]"):
            self.write_tick(None, raw=raw)
            self.assertIn("unmeasured", self.tracking()[0]["sent_this_tick"], raw)
        self.write_tick(None, name="tick.log", raw="")
        self.assertIn("recorded no apply", self.tracking()[0]["sent_this_tick"]["unmeasured"])

    def test_a_check_only_tick_is_not_zero_sent(self):
        self.write_tick(None, name="uvn-status-check.json", raw=json.dumps({"mode": "check", "sent": []}))
        t, text, _ = self.tracking()
        self.assertIn("recorded no apply", t["sent_this_tick"]["unmeasured"])
        self.assertIn("sent_this_tick unmeasured", text)

    def test_an_old_tick_is_marked(self):
        self.write_tick([], stamp="20261115T0159Z")
        t, text, _ = self.tracking()
        self.assertEqual((t["sent_this_tick"]["value"], t["sent_this_tick"]["stale"]), (0, True))
        self.assertIn("sent_this_tick 0~ (tick 11-15 01:59Z (2h01m))", text)

    def test_a_send_after_the_ticks_first_hour_is_counted(self):
        self.write_tick([{"user": 1, "campaign": "uvn-status", "kind": "initial"}], stamp="20261115T0200Z")
        self.note("uvn-status", 1, ago(minutes=6))
        t, text, _ = self.tracking()
        self.assertEqual(t["sent_this_tick"]["value"], 1)
        self.assertIn("sent_this_tick 1 (tick 11-15 02:00Z (2h00m))", text)

    def test_a_send_after_the_ticks_last_log_line_is_counted(self):
        self.write_tick([{"user": 1, "campaign": "uvn-status", "kind": "initial"}], stamp="20261115T0200Z")
        older = os.path.join(self.out, "20261115T0100Z")
        os.makedirs(older)
        with open(os.path.join(older, "uvn-status-apply.json"), "w") as f:
            json.dump({"mode": "apply", "sent": []}, f)
        with open(os.path.join(self.out, "20261115T0200Z", "tick.log"), "w") as f:
            f.write("2026-11-15T02:00:01Z start\n2026-11-15T02:05:00Z credit families: page 1\n")
        self.note("uvn-status", 1, "2026-11-15T02:15:00Z")
        self.assertEqual(self.tracking()[0]["sent_this_tick"]["value"], 1)

    def test_a_send_before_the_ticks_stamp_is_not_counted(self):
        self.write_tick([{"user": 1, "campaign": "uvn-status", "kind": "initial"}], stamp="20261115T0200Z")
        self.note("uvn-status", 1, "2026-11-15T01:50:00Z")
        self.assertEqual(self.tracking()[0]["sent_this_tick"]["value"], 0)

    def test_a_send_past_the_ticks_hard_deadline_is_not_counted(self):
        self.write_tick([{"user": 1, "campaign": "uvn-status", "kind": "initial"}], stamp="20261115T0200Z")
        self.note("uvn-status", 1, "2026-11-15T04:00:00Z")
        self.assertEqual(self.tracking()[0]["sent_this_tick"]["value"], 0)

    def test_a_tick_with_an_unreadable_stamp_is_unmeasured(self):
        self.write_tick([{"user": 1, "campaign": "uvn-status", "kind": "initial"}], stamp="20261345T9999Z")
        self.assertIn("no readable stamp", self.tracking()[0]["sent_this_tick"]["unmeasured"])

    def test_a_snapshot_from_before_the_writer_recorded_them_is_unmeasured(self):
        for over in ({"ours": None, "intake_1h": None}, {"ours": {"pending": 9}, "intake_1h": {"requests": "4"}},
                     {"ours": {"pending": 9, "ours": -1, "never_asked": 0}, "intake_1h": []}):
            self.write_snapshot(snapshot(**over))
            t, text, _ = self.tracking()
            self.assertEqual((t["ours"], t["decisions_per_intake"]),
                             ({"unmeasured": vs.NOT_RECORDED}, {"unmeasured": vs.NOT_RECORDED}))
            self.assertIn("credit requests: OURS unmeasured sent_this_tick 0", text)
            self.assertIn("decisions_per_intake unmeasured; held_evidence_unbounded unmeasured", text)
            self.assertIn("OURS, decisions_per_intake: " + vs.NOT_RECORDED, text)

    def test_a_tracking_read_the_writer_failed_is_unmeasured_and_leaves_the_tables_alone(self):
        self.write_snapshot(snapshot(ours=None, errors=["ours: RuntimeError: the pending-request read returned no rows"]))
        t, text, page = self.tracking()
        self.assertIn("could not read it (ours: RuntimeError", t["ours"]["unmeasured"])
        self.assertEqual(t["decisions_per_intake"]["intake"], 4)
        c = self.family(page, "credits")
        self.assertEqual((c["open"]["value"], c["waiting_us"]["value"], c["waiting_user"]["value"]), (800, 495, 300))
        # a stale 400 left in the file beside the error is not read either
        self.write_snapshot(snapshot(errors=["intake: TimeoutExpired: 100s", "ours: RuntimeError: x"]))
        t, _, _ = self.tracking()
        self.assertTrue("unmeasured" in t["ours"] and "unmeasured" in t["decisions_per_intake"])

    def test_no_intake_is_said_and_never_divided(self):
        self.decision("r1", ago(minutes=40), mode="judge")
        self.write_snapshot(snapshot(intake_1h={"requests": 0}))
        t, text, _ = self.tracking()
        self.assertEqual(t["decisions_per_intake"], {"value": None, "stale": False, "decisions": 1, "intake": 0})
        self.assertIn("decisions_per_intake no intake (1 decisions / 0 created)", text)

    def test_a_ledger_without_the_decision_told_table_is_unmeasured(self):
        db = sqlite3.connect(self.ledger)
        db.execute("DROP TABLE decision_told")
        db.commit()
        db.close()
        page = self.build()
        self.assertIn("no such table: decision_told", page["ledger_unmeasured"])
        for name in ("credits", "claims"):
            fam = self.family(page, name)
            self.assertIn("no such table: decision_told", fam["told_24h"]["unmeasured"])
            self.assertEqual(fam["days_to_zero"], {"unmeasured": "told is unmeasured"})
        self.assertIn("no such table: decision_told", vs.render(page))

    def test_a_ledger_without_the_decision_tables_is_unmeasured(self):
        db = sqlite3.connect(self.ledger)
        db.execute("DROP TABLE decision_outcomes")
        db.commit()
        db.close()
        t, text, page = self.tracking()
        self.assertIn("no such table: decision_outcomes", t["applied_1h"]["unmeasured"])
        self.assertIn("no such table: decision_outcomes", t["decisions_per_intake"]["unmeasured"])
        self.assertIn("applied_1h unmeasured decisions_per_intake unmeasured", text)
        self.assertEqual(self.family(page, "credits")["open"]["value"], 800)
        t, _, _ = self.tracking(ledger=os.path.join(self.dir, "none.sqlite3"))
        self.assertIn("no ledger at", t["applied_1h"]["unmeasured"])
        self.assertFalse(os.path.exists(os.path.join(self.dir, "none.sqlite3")))

    def test_a_missing_snapshot_leaves_the_ledger_numbers_measured(self):
        os.remove(self.snap)
        self.decision("a1", ago(minutes=30), outcome="approved")
        t, _, _ = self.tracking()
        self.assertEqual((t["applied_1h"]["value"], t["sent_this_tick"]["value"]), (1, 0))
        self.assertIn("no snapshot at", t["ours"]["unmeasured"])
        self.assertIn("no snapshot at", t["decisions_per_intake"]["unmeasured"])

    def test_a_stale_snapshot_marks_the_two_numbers_it_feeds(self):
        snap_at = NOW - timedelta(hours=10)
        self.write_snapshot(snapshot(at=snap_at))
        for minutes in (5, 30, 59, 61):                             # decisions in the snapshot's hour, not now's
            self.decision("r", (snap_at - timedelta(minutes=minutes)).strftime("%Y-%m-%dT%H:%M:%SZ"), mode="judge")
        self.decision("now", ago(minutes=5), mode="judge")
        t, text, _ = self.tracking()
        self.assertEqual((t["ours"]["stale"], t["decisions_per_intake"]["stale"], t["applied_1h"]["stale"]),
                         (True, True, False))
        self.assertEqual(t["decisions_per_intake"]["decisions"], 3)
        self.assertIn("OURS 400~ of 1,000 pending", text)
        self.assertIn("decisions_per_intake 0.8~ (3 decisions / 4 created)", text)


class Ages(Fixture):
    def test_the_median_comes_from_the_snapshot(self):
        self.write_snapshot(snapshot(credits=section(
            800, 9000, 300, 60, 4, 24000.0, age={"users": 800, "undated": 0, "median_h": 2400.0,
                                                  "oldest_per_user_median_h": 24000.0,
                                                  "oldest_h": 24960.0})))
        page = self.build()
        c = self.family(page, "credits")
        self.assertEqual((c["median_h"]["value"], c["oldest_h"]["value"]), (2400.0, 24960.0))
        self.assertEqual(c["oldest_per_user_median_h"]["value"], 24000.0)
        text = vs.render(page)
        self.assertRegex(text, r"credits .* 100d +1,040d ")
        self.assertIn("median age is per open request; per user's oldest request: credits 1,000d", text)

    def test_the_per_user_figure_never_stands_under_the_median_age_label(self):
        self.write_snapshot(snapshot(credits=section(
            800, 9000, 300, 60, 4, 24000.0, age={"users": 800, "undated": 0, "median_h": 24.0,
                                                  "oldest_per_user_median_h": 24000.0,
                                                  "oldest_h": 24960.0})))
        page = self.build()
        self.assertEqual(self.family(page, "credits")["median_h"]["value"], 24.0)
        self.assertRegex(vs.render(page), r"credits .* 24h +1,040d ")

    def test_a_snapshot_without_a_median_is_unmeasured_with_the_reason(self):
        page = self.build()
        self.assertIn("unmeasured", self.family(page, "credits")["median_h"])
        text = vs.render(page)
        self.assertIn("unmeasured, not zero - credits median age, claims median age: the snapshot's writer "
                      "did not record it", " ".join(text.split()))
        self.assertTrue(vs.incomplete(page))


class Unmeasured(Fixture):
    def test_a_missing_ledger_is_unmeasured_and_is_not_created(self):
        gone = os.path.join(self.dir, "absent.sqlite3")
        page = self.build(ledger=gone)
        c = self.family(page, "credits")
        for key in ("told_24h", "last_send", "days_to_zero"):
            self.assertIn("unmeasured", c[key], key)
        self.assertEqual(c["open"]["value"], 800)               # the snapshot is still read
        self.assertFalse(os.path.exists(gone))
        text = vs.render(page)
        self.assertRegex(text, r"credits +800 +<=64 +unmeasured ")
        self.assertIn("no ledger at", text)

    def test_a_ledger_that_is_not_a_database_is_unmeasured(self):
        with open(self.ledger, "wb") as f:
            f.write(b"not sqlite" * 400)
        self.assertIn("unmeasured", self.family(self.build(), "claims")["told_24h"])

    def test_a_missing_snapshot_is_unmeasured(self):
        self.note("uvn-status", 1, ago(hours=1))
        os.unlink(self.snap)
        page = self.build()
        c = self.family(page, "credits")
        for key in ("open", "decided_24h", "median_h", "oldest_h", "days_to_zero"):
            self.assertIn("unmeasured", c[key], key)
        self.assertEqual(c["told_24h"]["value"], 1)             # the ledger is still read
        self.assertRegex(vs.render(page), r"credits +unmeasured +unmeasured +1 ")

    def test_a_snapshot_that_recorded_its_own_failed_read_is_not_zero_open(self):
        # the writer saves an empty population as 0 open when the read failed
        self.write_snapshot(snapshot(errors=["credits: TimeoutExpired: 90s", "credit flow: boom"],
                                     credits=section(0, 0, 0, 0, 0, 0)))
        page = self.build()
        c, k = self.family(page, "credits"), self.family(page, "claims")
        for key in ("open", "decided_24h", "oldest_h", "days_to_zero"):
            self.assertIn("unmeasured", c[key], key)
        self.assertEqual((k["open"]["value"], k["decided_24h"]["value"]), (120, 10))
        self.assertIn("unmeasured", c["decided_rows"])
        self.assertIn("unmeasured", c["waiting_us"])      # buckets not classified cleanly
        self.assertIn("unmeasured", c["waiting_user"])

    def test_an_error_that_says_nothing_about_bucketing_leaves_waiting_measured(self):
        for err in ("merges: RuntimeError: boom", "credits median: RuntimeError: boom",
                    "slack: boom", "ours: boom", "claims: TimeoutExpired: 90s"):
            self.write_snapshot(snapshot(errors=[err]))
            c = self.family(self.build(), "credits")
            self.assertEqual(c["waiting_us"]["value"], 495, err)
            self.assertEqual(c["waiting_user"]["value"], 300, err)

    def test_a_ledger_proof_feed_or_watchlist_error_makes_waiting_unmeasured(self):
        for err in ("ledger: RuntimeError: boom", "proof feed: RuntimeError: boom",
                    "watchlist: RuntimeError: boom"):
            self.write_snapshot(snapshot(errors=[err]))
            c = self.family(self.build(), "credits")
            for key in ("waiting_us", "waiting_user", "on_hold"):
                self.assertIn("unmeasured", c[key], f"{err} {key}")
            text = vs.render(self.build())
            self.assertIn("users waiting on us / on the user / on hold: credits unmeasured / unmeasured / "
                          "unmeasured", text)
            self.assertIn("unmeasured, not zero - credits waiting on us, credits waiting on the user, "
                          "credits on hold", text)

    def test_an_unreadable_policy_is_unmeasured(self):
        self.note("uvn-status", 1, ago(hours=1))
        with open(self.policy, "w") as f:
            f.write("{")
        c = self.family(self.build(), "credits")
        self.assertIn("unmeasured", c["told_24h"])
        self.assertEqual(c["open"]["value"], 800)

    def test_a_policy_group_the_page_cannot_read_is_unmeasured_and_never_zero_told(self):
        """The policy file is valid JSON, and one family's group is missing or is not a list
        of names. That family's sends cannot be told apart, so its row is unmeasured; the
        family whose group is readable keeps its numbers."""
        self.note("uvn-status", 1, ago(hours=1))
        self.note("claim-status", 2, ago(hours=2))
        credit = POLICY["groups"]["credit"]
        cases = (("claim-status", "is not a list of send family names"),
                 ({"claim-status": True}, "is not a list of send family names"),
                 (["claim-status", 7], "is not a list of send family names"),
                 (["claim-status", ""], "is not a list of send family names"),
                 (None, "is not a list of send family names"),
                 ([], "lists no send family"),
                 (..., "no `claim` group"))
        for claim, reason in cases:
            with self.subTest(claim=claim):
                groups = {"credit": credit} if claim is ... else {"credit": credit, "claim": claim}
                with open(self.policy, "w") as f:
                    json.dump({"groups": groups}, f)
                page = self.build()
                c = self.family(page, "claims")
                for key in ("told_24h", "last_send", "per_day"):
                    self.assertIn(reason, c[key].get("unmeasured", ""), key)
                    self.assertNotIn("value", c[key], key)
                self.assertEqual(set(c["days_to_zero"]), {"unmeasured"})
                self.assertEqual(c["senders"], [])
                self.assertEqual(c["open"]["value"], 120)       # the snapshot is still read
                self.assertEqual(self.family(page, "credits")["told_24h"], {"value": 1, "stale": False})
                self.assertTrue(vs.incomplete(page))
                text = " ".join(vs.render(page).split())
                # told, median (not in this fixture), oldest, last send, days to zero
                self.assertIn("claims 120 10 unmeasured unmeasured 58d unmeasured unmeasured ", text)
                self.assertIn("unmeasured, not zero - claims told 24h, claims last send: "
                              f"policy {self.policy}: ", text)
                self.assertIn("unmeasured, not zero - claims days to zero: told is unmeasured", text)
                self.assertIn(reason, text)
                # the send is not hidden: it is named, outside a family the page could classify
                self.assertIn("told 24h by senders outside these families: claim-status 1", text)

    def test_a_readable_policy_group_still_counts_its_sends(self):
        self.note("claim-status", 2, ago(hours=2))
        c = self.family(self.build(), "claims")
        self.assertEqual((c["told_24h"], c["senders"][0]["family"]), ({"value": 1, "stale": False}, "claim-status"))

    def test_a_snapshot_dated_after_now_is_unmeasured(self):
        self.write_snapshot(snapshot(at=NOW + timedelta(hours=3)))
        self.assertIn("unmeasured", self.family(self.build(), "credits")["open"])


class Stale(Fixture):
    def test_a_stale_snapshot_marks_every_cell_it_feeds_and_names_the_stop_file(self):
        self.note("uvn-status", 1, ago(hours=1))
        self.write_snapshot(snapshot(at=NOW - timedelta(hours=10, minutes=30)))
        open(self.kill, "w").close()
        page = self.build()
        c = self.family(page, "credits")
        for key in ("open", "decided_24h", "oldest_h", "days_to_zero"):
            self.assertTrue(c[key]["stale"], key)
        self.assertFalse(c["told_24h"]["stale"])                # read now, from the ledger
        text = vs.render(page)
        self.assertRegex(text, r"credits +800~ +<=64~ +1 ")
        self.assertIn("on hold: credits 495~ / 300~ / 5~, claims 45~ / 70~ / 5~", text)
        flat = " ".join(text.split())
        self.assertIn("~ open, decided, ages: snapshot 11-14 17:30Z, 10h30m old (limit 2h); its writer is "
                      f"stopped by {self.kill}", flat)
        self.assertTrue(vs.incomplete(page))

    def test_a_fresh_snapshot_is_not_marked(self):
        text = vs.render(self.build())
        self.assertNotIn("~", text)
        self.assertIn("open, decided, ages: snapshot 11-15 03:40Z, 20m old.", text)

    def test_the_limit_is_two_hours(self):
        self.write_snapshot(snapshot(at=NOW - timedelta(hours=1, minutes=59)))
        self.assertFalse(self.build()["snapshot"]["stale"])
        self.write_snapshot(snapshot(at=NOW - timedelta(hours=2, minutes=1)))
        self.assertTrue(self.build()["snapshot"]["stale"])


class ReadOnlyAndOneScreen(Fixture):
    def digest(self):
        out = {}
        for name in sorted(os.listdir(self.dir)):
            if not os.path.isfile(os.path.join(self.dir, name)):
                continue
            with open(os.path.join(self.dir, name), "rb") as f:
                out[name] = hashlib.sha256(f.read()).hexdigest()
        return out

    def test_it_writes_nothing(self):
        self.note("uvn-status", 1, ago(hours=1))
        before = self.digest()
        vs.render(self.build())
        self.assertEqual(self.digest(), before)
        with self.assertRaises(sqlite3.OperationalError):
            db = sqlite3.connect(f"file:{self.ledger}?mode=ro", uri=True)
            db.execute("PRAGMA query_only = 1")
            db.execute("DELETE FROM verify_messages")

    def test_one_screen_with_the_policy_main_ships(self):
        real = os.path.join(REPO, "policies", "credit-verify-outbound.json")
        groups = vs.read_policy(real)
        self.assertEqual(set(groups), {g for _, g, *_ in vs.FAMILIES},
                         "a new policy group needs a row in verification-standing.py FAMILIES")
        user = 0
        for fams in groups.values():                    # the worst case: every family sent this week
            for fam in fams:
                user += 1
                self.note(fam, user, ago(hours=user))
        self.notice(999, ago(hours=1))
        for extra in ("backlog-reply", "reply-ref", "refund-confirm"):
            self.note(extra, 5000, ago(hours=2))
        self.note("backlog-reply", 6000, None, created_at="unreadable")
        self.write_snapshot(snapshot(at=NOW - timedelta(hours=30), errors=["intake: RuntimeError: x"]))
        shutil.rmtree(self.out)
        open(self.kill, "w").close()
        text = vs.render(self.build(policy=real, kill="/etc/hydra/verification-queue-report.disabled"
                                    if os.path.exists("/etc/hydra/verification-queue-report.disabled")
                                    else self.kill))
        lines = text.splitlines()
        self.assertLessEqual(len(lines), vs.MAX_LINES, text)
        self.assertLessEqual(max(map(len, lines)), vs.MAX_COLS, text)
        for fams in groups.values():
            for fam in fams:
                self.assertIn(fam, text)
        # A family whose sent rows cannot be dated loses its sender rows and gains its reasons.
        for fam in groups["claim"]:
            self.note(fam, 7000, None, created_at="unreadable")
        text = vs.render(self.build(policy=real))
        lines = text.splitlines()
        self.assertLessEqual(len(lines), vs.MAX_LINES, text)
        self.assertLessEqual(max(map(len, lines)), vs.MAX_COLS, text)
        self.assertIn("claims told 24h, claims last send: sent rows with no readable time: ", text)


class Cli(Fixture):
    def run_main(self, *args):
        env = {"CREDIT_REVIEW_LEDGER": self.ledger, "VQR_STATE": self.snap, "CVO_POLICY": self.policy,
               "VQR_KILL_SWITCH": self.kill}
        out, err = io.StringIO(), io.StringIO()
        with mock.patch.multiple(vs, LEDGER=env["CREDIT_REVIEW_LEDGER"], SNAPSHOT=env["VQR_STATE"],
                                 POLICY=env["CVO_POLICY"], SNAPSHOT_KILL=env["VQR_KILL_SWITCH"],
                                 OUT_ROOT=self.out):
            with redirect_stdout(out), redirect_stderr(err):
                rc = vs.main(["verification-standing.py", *args])
        return rc, out.getvalue(), err.getvalue()

    def test_the_page_and_the_json_carry_the_same_cells(self):
        self.note("uvn-status", 1, datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"))
        rc, out, _ = self.run_main()
        self.assertEqual(rc, 0)
        self.assertIn("VERIFICATIONS - where they stand", out)
        rc, out, _ = self.run_main("--json")
        page = json.loads(out)
        self.assertEqual(rc, 0)
        self.assertEqual([f["family"] for f in page["families"]], ["credits", "claims"])
        self.assertEqual(page["families"][0]["told_24h"]["value"], 1)

    def test_strict_fails_on_an_unmeasured_or_stale_cell(self):
        rc, out, _ = self.run_main("--strict")                   # the fixture snapshot is days old by the wall clock
        self.assertEqual(rc, 3)
        self.assertIn("VERIFICATIONS", out)                      # the page is still printed

    def test_an_unknown_argument_is_refused(self):
        rc, out, err = self.run_main("--post")
        self.assertEqual((rc, out), (2, ""))
        self.assertIn("unknown argument --post", err)


class Saved(Cli):
    """`--save DIR`: the form verification-standing.timer runs. It fails on a cell a job is
    supposed to write, and only on those."""

    AGE = {"users": 800, "undated": 0, "median_h": 2400.0, "oldest_per_user_median_h": 24000.0,
           "oldest_h": 24960.0}

    def setUp(self):
        super().setUp()
        self.saved = os.path.join(self.dir, "standing")
        self.wall = datetime.now(timezone.utc)
        self.fresh()

    def fresh(self, **over):
        """Every source written minutes ago by the wall clock: `main` takes no clock."""
        self.write_snapshot(snapshot(at=self.wall - timedelta(minutes=20),
                                     credits=section(800, 9000, 300, 60, 4, 24000.0, age=self.AGE),
                                     claims=section(120, 150, 70, 10, 0, 1400.0, age=self.AGE), **over))
        self.write_tick([{"user": 1, "campaign": "uvn-status", "kind": "initial"}],
                        stamp=(self.wall - timedelta(minutes=10)).strftime("%Y%m%dT%H%MZ"))

    def files(self):
        return sorted(os.listdir(self.saved)) if os.path.isdir(self.saved) else None

    def test_a_page_whose_every_written_cell_is_measured_is_saved_and_passes(self):
        rc, out, err = self.run_main("--save", self.saved)
        self.assertEqual((rc, err), (0, ""))
        self.assertEqual(self.files(), ["latest.json", "latest.txt"])       # no temp file left behind
        with open(os.path.join(self.saved, "latest.txt")) as f:
            self.assertEqual(f.read(), out)
        with open(os.path.join(self.saved, "latest.json")) as f:
            page = json.load(f)
        self.assertEqual(self.family(page, "credits")["open"]["value"], 800)
        self.assertEqual(page["tracking"]["held_evidence_unbounded"], {"unmeasured": vs.HELD_UNMEASURED})

    def test_the_cell_no_job_writes_yet_fails_strict_and_not_the_timer(self):
        self.assertEqual(self.run_main("--save", self.saved)[0], 0)
        self.assertEqual(self.run_main("--strict")[0], 3)
        self.assertEqual(self.run_main("--save", self.saved, "--strict")[0], 3)

    def test_a_stale_snapshot_fails_and_the_stale_page_is_still_saved(self):
        self.write_snapshot(snapshot(at=self.wall - timedelta(hours=30),
                                     credits=section(800, 9000, 300, 60, 4, 24000.0, age=self.AGE),
                                     claims=section(120, 150, 70, 10, 0, 1400.0, age=self.AGE)))
        rc, out, err = self.run_main("--save", self.saved)
        self.assertEqual(rc, 3)
        self.assertRegex(err, r"(?m)^verification-standing: stale: credits open, .*waiting_us, waiting_user, "
                              r"on_hold.*; claims open, .*oldest_h.*; ours, ")
        self.assertEqual(len(err.splitlines()), 1)               # one line per reason, not one per cell
        self.assertNotIn("held_evidence_unbounded", err)
        with open(os.path.join(self.saved, "latest.txt")) as f:
            self.assertEqual(f.read(), out)
        open(self.kill, "w").close()                              # the stop file is named when it is why
        err = self.run_main("--save", self.saved)[2]
        self.assertIn(f"verification-standing: the snapshot's writer is stopped by {self.kill}", err)

    def write_policy(self, policy):
        with open(self.policy, "w") as f:
            json.dump(policy, f)

    def test_a_ledger_time_nobody_can_read_fails_the_run_and_names_the_cells(self):
        self.note("uvn-status", 1, (self.wall - timedelta(minutes=5)).strftime("%Y-%m-%dT%H:%M:%SZ"))
        self.assertEqual(self.run_main("--save", self.saved)[0], 0)
        self.note("uvn-status", 2, None, created_at="not a time")
        db = sqlite3.connect(self.ledger)
        db.execute("INSERT INTO decision_outcomes (run_id, at, request_id, action, outcome) "
                   "VALUES ('run-1', 'soon', 'a9', 'approve', 'approved')")
        db.commit()
        db.close()
        rc, out, err = self.run_main("--save", self.saved)
        self.assertEqual(rc, 3)
        self.assertRegex(err, r"(?m)^verification-standing: unmeasured \(sent rows with no readable time: "
                              r"uvn-status 1\): credits told_24h, last_send; sent_this_tick$")
        self.assertRegex(err, r"(?m)^verification-standing: unmeasured \(ledger rows with no readable time: "
                              r"approved outcomes 1\): applied_1h$")
        with open(os.path.join(self.saved, "latest.txt")) as f:
            self.assertEqual(f.read(), out)

    def test_a_cell_its_writer_left_unmeasured_fails_with_the_reason(self):
        stamp = (self.wall - timedelta(minutes=10)).strftime("%Y%m%dT%H%MZ")
        cases = (                                                 # the ledger last: nothing puts it back
            ("no snapshot", lambda: os.unlink(self.snap), r"unmeasured \(no snapshot at .*\): credits open, "),
            ("a snapshot without the median",
             lambda: self.write_snapshot(snapshot(at=self.wall - timedelta(minutes=20))),
             r"unmeasured \(the snapshot's writer did not record it\): "
             r"credits oldest_per_user_median_h, median_h; claims oldest_per_user_median_h, median_h$"),
            # the reviewer's case: every column and tracking number is read, the buckets are not
            ("a snapshot whose buckets were not classified",
             lambda: self.write_snapshot(snapshot(
                 at=self.wall - timedelta(minutes=20), errors=["watchlist: RuntimeError: boom"],
                 credits=section(800, 9000, 300, 60, 4, 24000.0, age=self.AGE),
                 claims=section(120, 150, 70, 10, 0, 1400.0, age=self.AGE))),
             r"unmeasured \(the snapshot's buckets were not classified cleanly\): "
             r"credits waiting_us, waiting_user, on_hold; claims waiting_us, waiting_user, on_hold$"),
            ("a tick that sent nothing",
             lambda: self.write_tick(None, name="uvn-status-check.json", stamp=stamp,
                                     raw=json.dumps({"mode": "check", "sent": []})),
             r"unmeasured \(.*recorded no apply.*\): sent_this_tick$"),
            ("a policy group that is not a list",
             lambda: self.write_policy({"groups": {"credit": ["uvn-status"], "claim": "claim-status"}}),
             r"unmeasured \(policy .*`claim` group.*\): claims told_24h, last_send$"),
            ("no ledger", lambda: os.unlink(self.ledger), r"unmeasured \(no ledger at .*\): credits told_24h, "),
        )
        for name, broken, line in cases:
            with self.subTest(name):
                self.fresh()
                self.write_policy(POLICY)
                self.assertEqual(self.run_main("--save", self.saved)[0], 0, "the fixture must start clean")
                broken()
                rc, _, err = self.run_main("--save", self.saved)
                self.assertEqual(rc, 3)
                self.assertRegex(err, "(?m)^verification-standing: " + line)
                self.assertNotIn("held_evidence_unbounded", err)

    def test_no_cell_on_the_page_can_be_unmeasured_or_stale_and_pass(self):
        """Every cell a family row or the tracking block carries, broken alone on a clean page,
        is a failure. The cells are read off the page, so a cell added later is covered."""
        clean = self.build(now=self.wall)
        self.assertEqual([c for c in vs.broken_cells(clean) if c[1] not in vs.NO_WRITER_YET], [])
        cells = [(i, k) for i, f in enumerate(clean["families"]) for k, c in f.items() if isinstance(c, dict)]
        self.assertGreaterEqual({k for _, k in cells}, set(vs.WAITING) | {"open", "told_24h", "days_to_zero"})
        for holder, key in cells + [(None, k) for k in clean["tracking"]]:
            if key in vs.SAME_READ or (holder is None and clean["tracking"][key].get("unmeasured")):
                continue
            for bad in ({"unmeasured": "x"}, {"value": 1, "stale": True}):
                with self.subTest(cell=key, bad=sorted(bad)[0]):
                    page = json.loads(json.dumps(clean))
                    row = page["tracking"] if holder is None else page["families"][holder]
                    row[key] = bad
                    name = key if holder is None else f"{row['family']} {key}"
                    self.assertIn((name, bad.get("unmeasured", "stale")), vs.broken_cells(page))

    def test_a_figure_left_out_of_the_scan_is_never_unmeasured_alone(self):
        """SAME_READ figures are skipped only because the cell each is named with says the same."""
        def pages():
            yield self.build(now=self.wall)
            self.write_snapshot(snapshot(at=self.wall - timedelta(hours=30)))
            yield self.build(now=self.wall)
            self.write_snapshot(snapshot(at=self.wall - timedelta(minutes=20),
                                         errors=["credits: RuntimeError: x", "claims flow: RuntimeError: x"]))
            yield self.build(now=self.wall)
            self.write_snapshot(snapshot(at=self.wall - timedelta(minutes=20),
                                         errors=["watchlist: RuntimeError: boom"]))
            yield self.build(now=self.wall)
            self.write_policy({"groups": {"credit": ["uvn-status"], "claim": "claim-status"}})
            yield self.build(now=self.wall)
            yield self.build(now=self.wall, ledger=self.ledger + ".none", snapshot=self.snap + ".none")
        seen = set()
        for page in pages():
            for f in page["families"]:
                for helper, named in vs.SAME_READ.items():
                    state = [("unmeasured" in f[k], bool(f[k].get("stale"))) for k in (helper, named)]
                    self.assertEqual(state[0], state[1], f"{f['family']} {helper} vs {named}")
                    seen.add((helper, state[0]))
        for helper in vs.SAME_READ:                               # each was seen measured, unmeasured and stale
            self.assertGreaterEqual(seen, {(helper, (False, False)), (helper, (True, False)),
                                           (helper, (False, True))} - {("per_day", (False, True))})

    def test_a_directory_that_cannot_be_written_fails_and_is_not_a_clean_run(self):
        with open(self.saved, "w") as f:                          # a file where the directory should be
            f.write("")
        rc, _, err = self.run_main("--save", self.saved)
        self.assertEqual(rc, 1)
        self.assertIn(f"could not save the page in {self.saved}", err)

    def test_save_without_a_directory_is_refused(self):
        for args in (("--save",), ("--save", "--json")):
            rc, out, err = self.run_main(*args)
            self.assertEqual((rc, out), (2, ""))
            self.assertIn("--save needs a directory", err)
        self.assertIsNone(self.files())

    def test_nothing_is_written_without_save(self):
        before = sorted(os.listdir(self.dir))
        for args in ((), ("--json",), ("--strict",)):
            self.run_main(*args)
        self.assertEqual(sorted(os.listdir(self.dir)), before)


if __name__ == "__main__":
    unittest.main()
