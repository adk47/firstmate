"""credit_review/never_asked_digest.py: one digest per customer, who is left out and why, paid first, and a canary
that continues only on a measured refusal rate under the bar. The module sends nothing; neither do these tests."""
from __future__ import annotations

import credit_test_env  # noqa: F401 - first: test logs never reach the production run.log
import ast
import json
import sys
import tempfile
import unittest
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
from credit_review import never_asked_digest as nad  # noqa: E402


def p(rid, uid, created="2026-10-01", paid=False, core=False):
    return nad.Pending(rid, uid, created, paid, core)


FOUR = [p("r1", "7", "2026-10-04"), p("r2", "7", "2026-10-02"), p("r3", "7", "2026-10-03"), p("r4", "7", "2026-10-01")]


class OnePerCustomerTests(unittest.TestCase):
    def test_a_customer_with_four_pending_requests_gets_one_digest_naming_all_four(self):
        aud = nad.build(FOUR, [], nad.Holds())
        self.assertEqual(len(aud.digests), 1)
        self.assertEqual(aud.digests[0].user_id, "7")
        self.assertEqual(aud.digests[0].request_ids, ("r1", "r2", "r3", "r4"))
        self.assertEqual(aud.digests[0].oldest, "2026-10-01")

    def test_no_customer_appears_twice_however_the_rows_arrive(self):
        # the builder's list names 56 customers in two classes; rows repeat, interleave and differ in case
        rows = FOUR + [p("a1", "8"), p("R1", "7"), p("a2", "8"), p("r2", "7"), p("b1", "9", paid=True), p("a1", "8")]
        aud = nad.build(rows, [], nad.Holds())
        per_user = Counter(d.user_id for d in aud.digests)
        self.assertEqual(set(per_user.values()), {1})
        self.assertEqual(sorted(per_user), ["7", "8", "9"])
        named = [rid for d in aud.digests for rid in d.request_ids]
        self.assertEqual(len(named), len(set(named)))                      # and no request is named twice
        self.assertEqual(aud.never_asked, 7)

    def test_user_ids_that_differ_only_in_spacing_are_one_customer(self):
        aud = nad.build([p("r1", "7"), p("r2", " 7 ")], [], nad.Holds())
        self.assertEqual([(d.user_id, d.request_ids) for d in aud.digests], [("7", ("r1", "r2"))])

    def test_a_request_the_ledger_names_is_not_in_the_digest(self):
        aud = nad.build(FOUR, ["R2", "r4"], nad.Holds())
        self.assertEqual(aud.digests[0].request_ids, ("r1", "r3"))
        self.assertEqual(aud.never_asked, 2)

    def test_a_customer_whose_every_request_was_asked_gets_nothing(self):
        aud = nad.build(FOUR, ["r1", "r2", "r3", "r4"], nad.Holds())
        self.assertEqual((aud.digests, aud.left_out, aud.never_asked), ([], {}, 0))

    def test_a_request_core_asked_about_is_left_out_of_the_digest(self):
        aud = nad.build([p("r1", "7"), p("r2", "7", core=True)], [], nad.Holds())
        self.assertEqual(aud.digests[0].request_ids, ("r1",))

    def test_a_customer_core_asked_about_every_request_is_owed_nothing(self):
        aud = nad.build([p("r1", "7", core=True), p("r2", "7", core=True)], [], nad.Holds())
        self.assertEqual(aud.digests, [])
        self.assertEqual(aud.core_asked_only, {"7"})
        self.assertEqual(aud.left_out, {})

    def test_a_request_with_no_user_is_counted_and_written_to_nobody(self):
        aud = nad.build([p("r1", ""), p("r2", "7")], [], nad.Holds())
        self.assertEqual((aud.no_user, [d.user_id for d in aud.digests]), (1, ["7"]))

    def test_a_row_with_no_request_id_refuses_the_build(self):
        with self.assertRaises(nad.DigestError):
            nad.build([p("", "7")], [], nad.Holds())


class LeftOutTests(unittest.TestCase):
    def test_each_hold_leaves_out_its_customer_and_only_that_customer(self):
        for name in nad.LEFT_OUT:
            with self.subTest(hold=name):
                aud = nad.build([p("r1", "7"), p("r2", "8")], [], nad.Holds(**{name: frozenset({"7"})}))
                self.assertEqual(aud.left_out, {"7": name})
                self.assertEqual([d.user_id for d in aud.digests], ["8"])

    def test_a_dsp_request_in_flight_skips_the_customer(self):
        aud = nad.build(FOUR, [], nad.Holds(dsp_in_flight=frozenset({"7"})))
        self.assertEqual((aud.digests, aud.left_out), ([], {"7": "dsp_in_flight"}))

    def test_an_opt_out_or_bounce_is_never_offered_whatever_else_is_true(self):
        aud = nad.build(FOUR, [], nad.Holds(never_again=frozenset({"7"}), dsp_in_flight=frozenset({"7"})))
        self.assertEqual(aud.left_out, {"7": "never_again"})

    def test_the_stop_list_outranks_every_other_reason(self):
        every = {name: frozenset({"7"}) for name in nad.LEFT_OUT}
        self.assertEqual(nad.build(FOUR, [], nad.Holds(**every)).left_out, {"7": "stopped"})

    def test_stopping_one_customer_changes_no_other_digest(self):
        rows = FOUR + [p("a1", "8", paid=True), p("b1", "9")]
        before = nad.build(rows, [], nad.Holds())
        after = nad.build(rows, [], nad.Holds(stopped=frozenset({"8"})))
        self.assertEqual([d for d in before.digests if d.user_id != "8"], after.digests)
        self.assertEqual(after.left_out, {"8": "stopped"})

    def test_every_customer_is_in_exactly_one_place(self):
        rows = FOUR + [p("a1", "8"), p("b1", "9", core=True), p("c1", "10"), p("d1", "")]
        aud = nad.build(rows, [], nad.Holds(document_on_file=frozenset({"8"})))
        placed = [d.user_id for d in aud.digests] + list(aud.left_out) + list(aud.core_asked_only)
        self.assertEqual(sorted(placed, key=int), ["7", "8", "9", "10"])
        c = aud.counts()
        self.assertEqual((c["digests"], c["left_out_document_on_file"], c["core_asked_only_customers"],
                          c["no_user_requests"], c["never_asked_requests"]), (2, 1, 1, 1, 8))


class OrderTests(unittest.TestCase):
    def test_paid_customers_come_first_then_the_oldest_request(self):
        rows = [p("f-old", "1", "2024-01-01"), p("p-new", "2", "2026-11-01", paid=True),
                p("f-new", "3", "2026-11-02"), p("p-old", "4", "2025-01-01", paid=True)]
        self.assertEqual([d.user_id for d in nad.build(rows, [], nad.Holds()).digests], ["4", "2", "1", "3"])

    def test_one_paid_row_makes_the_customer_paid(self):
        aud = nad.build([p("r1", "7"), p("r2", "7", paid=True, core=True)], [], nad.Holds())
        self.assertTrue(aud.digests[0].paid)


class StopListTests(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.dir.cleanup)
        self.path = Path(self.dir.name) / "stop.json"

    def test_a_missing_file_stops_nobody(self):
        self.assertEqual(nad.load_stop_list(self.path), frozenset())

    def test_ids_are_read_as_text_whether_written_as_numbers_or_strings(self):
        self.path.write_text(json.dumps([7, "8", " 9 "]))
        self.assertEqual(nad.load_stop_list(self.path), frozenset({"7", "8", "9"}))

    def test_a_file_that_is_not_an_array_of_ids_refuses(self):
        for text in ("{not json", json.dumps({"7": True}), json.dumps([["7"]]), json.dumps([None]), json.dumps([True])):
            with self.subTest(text=text):
                self.path.write_text(text)
                with self.assertRaises(nad.DigestError):
                    nad.load_stop_list(self.path)


def outcomes(sent=0, refused=0, held=0, unmeasured=0):
    out, n = {}, 0
    for name, count in (("sent", sent), ("refused", refused), ("held", held), ("unmeasured", unmeasured)):
        for _ in range(count):
            n += 1
            out[str(n)] = name
    return out


class CanaryTests(unittest.TestCase):
    def test_the_bar_is_two_percent_of_five_hundred(self):
        self.assertEqual((nad.CANARY_USERS, nad.REFUSAL_BAR, nad.MAX_REFUSED), (500, 0.02, 9))

    def test_the_rate_is_refused_over_sent_plus_refused(self):
        r = nad.read_canary(outcomes(sent=95, refused=5, held=40, unmeasured=7))
        self.assertEqual((r.measured, r.rate, r.held, r.unmeasured), (100, 0.05, 40, 7))

    def test_no_measured_outcome_is_no_rate_not_a_zero(self):
        self.assertIsNone(nad.read_canary(outcomes(held=3, unmeasured=2)).rate)

    def test_an_outcome_this_code_does_not_know_is_not_counted_as_sent(self):
        with self.assertRaises(nad.DigestError):
            nad.read_canary({"1": "sent", "2": "delivered"})

    def test_it_runs_until_five_hundred_are_measured(self):
        d = nad.decide(nad.read_canary(outcomes(sent=120, refused=2)), remaining=1000)
        self.assertEqual((d.verdict, d.may_offer), (nad.RUNNING, 378))

    def test_nine_refusals_in_five_hundred_continue(self):
        d = nad.decide(nad.read_canary(outcomes(sent=491, refused=9)), remaining=1000)
        self.assertEqual((d.verdict, d.reason, d.may_offer), (nad.CONTINUE, "canary_complete_under_the_bar", 1000))
        self.assertLess(d.reading.rate, 0.02)

    def test_ten_refusals_in_five_hundred_is_two_percent_and_stops(self):
        d = nad.decide(nad.read_canary(outcomes(sent=490, refused=10)), remaining=1000)
        self.assertEqual((d.verdict, d.may_offer), (nad.STOP, 0))
        self.assertEqual(d.reading.rate, 0.02)

    def test_the_tenth_refusal_stops_the_canary_before_it_is_complete(self):
        d = nad.decide(nad.read_canary(outcomes(sent=40, refused=10)), remaining=1000)
        self.assertEqual((d.verdict, d.reason, d.may_offer), (nad.STOP, "refusals_past_the_bar", 0))

    def test_held_and_unmeasured_customers_do_not_complete_the_canary(self):
        d = nad.decide(nad.read_canary(outcomes(sent=300, held=150, unmeasured=100)), remaining=50)
        self.assertEqual((d.verdict, d.may_offer), (nad.RUNNING, 50))

    def test_a_population_smaller_than_the_canary_never_reads_as_continue(self):
        # the measured first-contact population is 238: every one sent and none refused is still not a canary
        d = nad.decide(nad.read_canary(outcomes(sent=238)), remaining=0)
        self.assertEqual((d.verdict, d.reason, d.may_offer), (nad.STOP, "canary_short", 0))

    def test_a_negative_remaining_refuses(self):
        with self.assertRaises(nad.DigestError):
            nad.decide(nad.read_canary({}), remaining=-1)


class PageTests(unittest.TestCase):
    def setUp(self):
        rows = [p(f"r{i}", str(i), f"2026-01-{i:02d}", paid=i in (3, 5)) for i in range(1, 9)]
        self.digests = nad.build(rows, [], nad.Holds()).digests

    def ids(self, page):
        return [d.user_id for d in page]

    def test_the_page_is_paid_first_and_no_larger_than_asked(self):
        self.assertEqual(self.ids(nad.next_page(self.digests, {}, 3)), ["3", "5", "1"])

    def test_a_sent_or_refused_customer_is_never_offered_again(self):
        page = nad.next_page(self.digests, {"3": "sent", "5": "refused"}, 3)
        self.assertEqual(self.ids(page), ["1", "2", "4"])

    def test_a_held_or_unmeasured_customer_is_offered_again(self):
        page = nad.next_page(self.digests, {"3": "held", "5": "unmeasured"}, 2)
        self.assertEqual(self.ids(page), ["3", "5"])

    def test_no_page_is_offered_after_a_stop(self):
        stopped = {str(100 + i): "refused" for i in range(10)}
        self.assertEqual(nad.next_page(self.digests, stopped, 5), [])

    def test_the_canary_never_offers_past_five_hundred_measured(self):
        done = {str(1000 + i): "sent" for i in range(498)}
        self.assertEqual(len(nad.next_page(self.digests, done, 50)), 2)

    def test_past_a_complete_canary_under_the_bar_the_page_is_the_callers_size(self):
        done = {str(1000 + i): "sent" for i in range(500)}
        self.assertEqual(len(nad.next_page(self.digests, done, 5)), 5)

    def test_a_negative_page_size_refuses(self):
        with self.assertRaises(nad.DigestError):
            nad.next_page(self.digests, {}, -1)


class SendsNothingTests(unittest.TestCase):
    def test_the_module_imports_nothing_that_could_send_or_write_a_ledger(self):
        # an import allowlist, read from the syntax tree: a sender, a ledger, a process or a socket is not on it
        tree = ast.parse((ROOT / "scripts/credit_review/never_asked_digest.py").read_text())
        imported = set()
        for node in ast.walk(tree):
            if isinstance(node, ast.Import):
                imported.update(alias.name for alias in node.names)
            elif isinstance(node, ast.ImportFrom):
                imported.add(("." * node.level) + (node.module or ""))
        self.assertEqual(imported, {"__future__", "json", "dataclasses", "pathlib", "typing"})
        called = {n.func.id for n in ast.walk(tree) if isinstance(n, ast.Call) and isinstance(n.func, ast.Name)}
        self.assertEqual(called & {"open", "exec", "eval", "__import__"}, set())


if __name__ == "__main__":
    unittest.main()
