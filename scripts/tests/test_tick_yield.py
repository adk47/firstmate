#!/usr/bin/env python3
"""tick_yield: a family that spends the tick on gate calls and sends nobody is counted, paged once, and owed again
when the page was not delivered. Stdlib only; every file is a temp file."""
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from credit_review import tick_yield as ty  # noqa: E402

HELD = "HELD comm_state credits=1 (replied: proof_on_file)"


def rows(n, reason=HELD, result="deferred"):
    return [{"user": f"user-{i}", "result": result, "reason": reason} for i in range(n)]


class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.state = str(self.root / "state" / "tick-yield.json")
        self.n = 0

    def tick(self, **checks):
        """One tick directory. checks: tag -> (outcome rows, accepted count) | raw str (written as is)."""
        self.n += 1
        out = self.root / f"tick-{self.n}"
        out.mkdir()
        for tag, val in checks.items():
            path = out / f"{tag.replace('_', '-')}-check.json"
            if isinstance(val, str):
                path.write_text(val)
                continue
            outcomes, accepted = val
            path.write_text(json.dumps({"mode": "dry-run", "outcomes": outcomes,
                                        "accepted": [{"user": f"a{i}"} for i in range(accepted)]}))
        return ty.record(str(out), self.state)

    def seg(self, tag):
        return json.loads(Path(self.state).read_text())["segments"].get(tag)


class CodeTests(unittest.TestCase):
    def test_the_code_is_the_gates_word_not_its_sentence(self):
        for reason, want in (
            ("HELD comm_state credits=1 (replied: proof_on_file)", "comm_state"),
            ("DEFERRED c2_signed_only credits=3 (this ask would correct an earlier status line)", "c2_signed_only"),
            ("core_notice_within_7d credits=2 (approvedNotice)", "core_notice_within_7d"),
            ("HELD r1_receipted_in_thread last_admin_comment_at=2026-11-01", "r1_receipted_in_thread"),
            ("r1_filing_class_unknown: the R1 payload does not state the filing's class", "r1_filing_class_unknown"),
            ("gate_timeout: a gate call timed out after 1 attempt(s) of 20s", "gate_timeout"),
            ("G5: 1 interpolated field(s) carry a link", "G5"),
            ("messaged_7d credits=1", "messaged_7d"),
            ("run_size", "run_size"),
        ):
            self.assertEqual(ty.code_of(reason), want, reason)

    def test_prose_is_other_and_never_a_code(self):
        for reason in ("the gate raised RuntimeError", "credits has 1172 entries", "rc=2", "HELD 1", "POST FAILED"):
            self.assertEqual(ty.code_of(reason), "other", reason)

    def test_a_row_with_no_reason_takes_a_coded_result(self):
        self.assertEqual(ty.code_of("", "post_failed"), "post_failed")
        self.assertEqual(ty.code_of("", "deferred"), "other")
        self.assertEqual(ty.code_of(None, None), "other")


class MeasureTests(Base):
    def test_a_gate_call_is_an_answered_row_or_an_accepted_user(self):
        out = self.root / "t"
        out.mkdir()
        p = out / "uvn-status-free-check.json"
        p.write_text(json.dumps({"outcomes": rows(30) + rows(200, "run_size") + rows(7, "daily_cap")
                                 + rows(3, "apply_budget") + rows(2, "G5: 1 field"),
                                 "accepted": [{"user": "a"}, {"user": "b"}]}))
        m = ty.measure(str(p))
        self.assertEqual((m["gate_calls"], m["accepted"]), (34, 2))
        self.assertEqual(m["codes"], {"comm_state": 30, "G5": 2})

    def test_a_file_that_cannot_be_measured_raises_and_is_never_an_empty_walk(self):
        out = self.root / "t"
        out.mkdir()
        for name, body in (("a", "{not json"), ("b", "[]"), ("c", '{"counts": {}}'),
                           ("d", '{"outcomes": [1]}'), ("e", '{"outcomes": [], "accepted": 3}')):
            p = out / f"{name}-check.json"
            p.write_text(body)
            with self.assertRaises(ty.Unreadable, msg=body):
                ty.measure(str(p))
        with self.assertRaises(ty.Unreadable):
            ty.measure(str(out / "missing-check.json"))

    def test_spent_needs_the_calls_and_the_empty_hands(self):
        mk = lambda calls, acc: {"gate_calls": calls, "accepted": acc, "codes": {}}  # noqa: E731
        self.assertTrue(ty.spent(mk(40, 0)))
        self.assertTrue(ty.spent(mk(249, 1)))          # 2026-11-13 10:00Z, uvn-status free
        self.assertTrue(ty.spent(mk(100, 1)))
        self.assertFalse(ty.spent(mk(39, 0)))          # a short walk costs little
        self.assertFalse(ty.spent(mk(99, 1)))
        self.assertFalse(ty.spent(mk(50, 3)))          # 2026-11-15 16:00Z, proof-need-ask free: it sends
        self.assertFalse(ty.spent(mk(0, 0)))
        self.assertFalse(ty.sends(mk(0, 0)))           # an empty walk sent nobody
        self.assertFalse(ty.sends(mk(249, 1)))
        self.assertTrue(ty.sends(mk(10, 1)))


class StreakTests(Base):
    def test_the_page_is_owed_on_the_third_spent_tick_and_names_the_segment_the_count_and_the_code(self):
        for _ in range(ty.STREAK_TO_PAGE - 1):
            res = self.tick(r1_paid=(rows(120, "HELD r1_receipted_in_thread x") + rows(30), 0))
            self.assertEqual(res["page"], "")
        res = self.tick(r1_paid=(rows(120, "HELD r1_receipted_in_thread x") + rows(30), 0))
        self.assertIn("1 segment(s)", res["page"])
        self.assertIn("r1-paid 3 ticks, 450 gate calls, 0 accepted, 80% r1_receipted_in_thread", res["page"])
        self.assertIn("r1-paid 3 ticks", "\n".join(res["lines"]))

    def test_every_owed_segment_rides_one_page(self):
        for _ in range(ty.STREAK_TO_PAGE):
            res = self.tick(r1_paid=(rows(50), 0), r1_free=(rows(60), 0), uvn_status_free=(rows(10), 5))
        self.assertIn("2 segment(s)", res["page"])
        self.assertIn("r1-free 3 ticks", res["page"])
        self.assertIn("r1-paid 3 ticks", res["page"])
        self.assertNotIn("uvn-status-free", res["page"])

    def test_an_undelivered_page_is_owed_again_and_a_delivered_one_is_quiet_until_the_repeat(self):
        for _ in range(ty.STREAK_TO_PAGE):
            res = self.tick(r1_paid=(rows(50), 0))
        self.assertTrue(res["page"])
        res = self.tick(r1_paid=(rows(50), 0))                 # nobody called paged(): Slack did not confirm
        self.assertIn("r1-paid 4 ticks", res["page"])
        self.assertEqual(ty.paged(self.state), 1)
        self.assertEqual(self.seg("r1-paid")["paged_at"], 4)
        for _ in range(ty.REPAGE_EVERY - 1):
            self.assertEqual(self.tick(r1_paid=(rows(50), 0))["page"], "")
        res = self.tick(r1_paid=(rows(50), 0))
        self.assertIn(f"r1-paid {4 + ty.REPAGE_EVERY} ticks", res["page"])

    def test_paged_covers_only_what_record_said_was_owed(self):
        for _ in range(ty.STREAK_TO_PAGE):
            self.tick(r1_paid=(rows(50), 0))
        self.tick(r1_paid=(rows(50), 0), r1_free=(rows(50), 0))
        self.assertEqual(ty.paged(self.state), 1)
        self.assertEqual(self.seg("r1-free")["paged_at"], 0)   # one spent tick: nothing was said about it
        self.assertEqual(ty.paged(self.state), 0)              # and a second call has nothing left to mark

    def test_a_tick_that_sends_ends_the_streak(self):
        self.tick(r1_paid=(rows(50), 0))
        self.tick(r1_paid=(rows(50), 0))
        res = self.tick(r1_paid=(rows(50), 4))
        self.assertEqual(res["page"], "")
        self.assertIsNone(self.seg("r1-paid"))
        self.tick(r1_paid=(rows(50), 0))
        self.assertEqual(self.seg("r1-paid")["streak"], 1)

    def test_a_short_walk_that_sent_nobody_neither_extends_nor_ends_the_streak(self):
        # 2026-11-15: r1 paid walked 120-141 gate calls on most ticks and 14 on one whose page was cut. Ending the
        # streak there paged the same segment four times in a day.
        self.tick(r1_paid=(rows(50), 0))
        self.tick(r1_paid=(rows(50), 0))
        res = self.tick(r1_paid=(rows(14), 0))
        self.assertEqual(res["page"], "")
        self.assertEqual(self.seg("r1-paid")["streak"], 2)
        self.assertIn("r1-paid 3 ticks", self.tick(r1_paid=(rows(50), 0))["page"])

    def test_a_short_walk_that_sends_ends_the_streak(self):
        self.tick(r1_paid=(rows(50), 0))
        self.tick(r1_paid=(rows(10), 1))
        self.assertIsNone(self.seg("r1-paid"))

    def test_a_streak_nothing_extends_is_forgotten(self):
        self.tick(r1_paid=(rows(50), 0))
        for _ in range(ty.IDLE_TO_DROP - 1):
            self.tick(r1_paid=([], 0))
        self.assertEqual(self.seg("r1-paid")["streak"], 1)
        self.tick(r1_paid=([], 0))
        self.assertIsNone(self.seg("r1-paid"))

    def test_a_spent_tick_starts_the_idle_count_over(self):
        self.tick(r1_paid=(rows(50), 0))
        for _ in range(ty.IDLE_TO_DROP - 1):
            self.tick(r1_paid=([], 0))
        self.tick(r1_paid=(rows(50), 0))
        self.assertEqual(self.seg("r1-paid")["idle"], 0)
        self.tick(r1_paid=([], 0))
        self.assertEqual(self.seg("r1-paid")["streak"], 2)

    def test_a_family_the_tick_did_not_reach_keeps_its_streak(self):
        self.tick(r1_paid=(rows(50), 0))
        self.tick(r1_paid=(rows(50), 0))
        res = self.tick(uvn_status_free=(rows(5), 5))          # no r1-paid check file this tick
        self.assertEqual(res["page"], "")
        self.assertEqual(self.seg("r1-paid")["streak"], 2)
        self.assertTrue(self.tick(r1_paid=(rows(50), 0))["page"])

    def test_an_unreadable_check_is_named_and_neither_extends_nor_ends_the_streak(self):
        self.tick(r1_paid=(rows(50), 0))
        self.tick(r1_paid=(rows(50), 0))
        res = self.tick(r1_paid="{not json")
        self.assertEqual(res["page"], "")
        self.assertEqual(self.seg("r1-paid")["streak"], 2)
        self.assertIn("tick yield UNMEASURED for r1-paid", "\n".join(res["lines"]))
        self.assertIn("0 check(s) measured", "\n".join(res["lines"]))

    def test_rows_the_walk_stopped_before_are_not_gate_calls(self):
        for _ in range(ty.STREAK_TO_PAGE):
            res = self.tick(uvn_status_free=(rows(30) + rows(400, "run_size"), 0))
        self.assertEqual(res["page"], "")
        self.assertIsNone(self.seg("uvn-status-free"))                 # 30 gate calls: never a spent tick

    def test_an_unreadable_state_restarts_the_streaks_and_says_so(self):
        self.tick(r1_paid=(rows(50), 0))
        for junk in ("{not json", "[]", '{"v": 99, "segments": {}, "owed": []}',
                     '{"v": 1, "segments": {"r1-paid": {"streak": "3"}}, "owed": []}'):
            Path(self.state).write_text(junk)
            res = self.tick(r1_paid=(rows(50), 0))
            self.assertIn("streaks restart", res["lines"][0], junk)
            self.assertEqual(self.seg("r1-paid")["streak"], 1, junk)

    def test_the_state_file_holds_counts_and_codes_and_no_user(self):
        for _ in range(ty.STREAK_TO_PAGE):
            self.tick(r1_paid=(rows(50), 0))
        raw = Path(self.state).read_text()
        self.assertNotIn("user-", raw)
        self.assertEqual(set(json.loads(raw)), {"v", "segments", "owed"})
        self.assertEqual(set(self.seg("r1-paid")), {"streak", "gate_calls", "accepted", "codes", "paged_at", "idle"})


class CliTests(Base):
    def run_main(self, *argv):
        import contextlib
        import io
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            rc = ty.main(list(argv))
        return rc, buf.getvalue()

    def test_record_prints_the_page_line_only_when_one_is_owed_and_paged_starts_the_window(self):
        for i in range(ty.STREAK_TO_PAGE):
            out = self.root / f"cli-{i}"
            out.mkdir()
            (out / "r1-paid-check.json").write_text(json.dumps({"outcomes": rows(50), "accepted": []}))
            rc, text = self.run_main("record", "--out", str(out), "--state", self.state)
            self.assertEqual(rc, 0)
            self.assertEqual("PAGE: " in text, i == ty.STREAK_TO_PAGE - 1, text)
        rc, text = self.run_main("paged", "--state", self.state)
        self.assertEqual((rc, text.strip()), (0, "tick yield: page delivered for 1 segment(s)"))
        rc, text = self.run_main("report", "--state", self.state)
        self.assertIn("r1-paid 3 ticks, 150 gate calls, 0 accepted, 100% comm_state (paged at tick 3)", text)

    def test_record_without_a_tick_directory_is_unmeasured_and_writes_no_state(self):
        rc, text = self.run_main("record", "--out", str(self.root / "nope"), "--state", self.state)
        self.assertEqual(rc, 2)
        self.assertIn("UNMEASURED", text)
        self.assertFalse(os.path.exists(self.state))

    def test_report_before_any_tick_says_so(self):
        rc, text = self.run_main("report", "--state", self.state)
        self.assertEqual((rc, text.strip()), (0, "no tick has been counted yet (no state file)"))


if __name__ == "__main__":
    unittest.main()
