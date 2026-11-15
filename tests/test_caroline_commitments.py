"""The promise ledger and the support-backlog file.

Stdlib unittest, no network. Run by name in pr-validate.yml:
    python3 -m unittest -v tests.test_caroline_commitments

What each class pins:

  Derive    a promise opens a commitment; only a message SENT on the thread closes it; a check-in
            keeps it open; an answer to a new customer message is not us coming back.
  Summary   the four numbers the instrument carries, and that a promise breaks once.
  Owners    a person can never own a commitment; a promise nobody owns must say so.
  Ledger    the durable rows: rewritten only by reading the thread, never pruned while open,
            and the lookup the status driver uses to find the thread that carries the promise.
  Backlog   the file: whole-inbox numbers, null (never 0) when the inbox was not read, atomic.
  Tick      end to end: the tick writes the file, a blind tick leaves the last good one.
"""
import copy
import json
import os
import sqlite3
import sys
import tempfile
import types
import unittest

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(REPO, "scripts"))

from caroline_monitor import alerts, backlog, cli, commitments, fixloop, rules  # noqa: E402
from caroline_monitor.store import Store  # noqa: E402

HOUR, DAY = 3600, 86400
T0 = 1_800_000_000
C, A, H, P, Q = (rules.EV_CUSTOMER, rules.EV_CAROLINE, rules.EV_HUMAN_REPLY, rules.EV_PROMISE, rules.EV_QUEUE)
REGISTER = fixloop.load_register()


def ask_and_promise(at=T0):
    """The customer asks; Caroline answers with the hand-off line a minute later."""
    return [[at, C], [at + 60, A], [at + 60, P]]


def fact(tid, events, shape="proof_sent", is_open=True, created=None):
    events = sorted(events)
    return {"id": str(tid), "created_at": created or events[0][0], "updated_at": events[-1][0], "open": is_open,
            "shape": shape, "outbound": False, "events": events, "rules": rules.reader_version()}


class Derive(unittest.TestCase):
    def one(self, events, now):
        got = commitments.derive(sorted(events), now=now)
        self.assertEqual(len(got), 1, got)
        return got[0]

    def test_the_hand_off_line_opens_a_commitment_due_in_a_day(self):
        c = self.one(ask_and_promise(), T0 + HOUR)
        self.assertEqual((c["promised_at"], c["promise"], c["due_at"]), (T0 + 60, "person", T0 + 60 + DAY))
        self.assertIsNone(c["closed_at"])
        self.assertEqual(c["marks"], [])   # not due yet: neither kept nor broken

    def test_a_queue_line_is_a_commitment_too(self):
        c = self.one([[T0, C], [T0 + 60, A], [T0 + 60, Q]], T0 + HOUR)
        self.assertEqual(c["promise"], "queue")

    def test_an_answer_with_no_promise_opens_nothing(self):
        self.assertEqual(commitments.derive([[T0, C], [T0 + 60, A]], now=T0 + DAY), [])

    def test_nothing_sent_by_the_due_time_breaks_it_once(self):
        c = self.one(ask_and_promise(), T0 + 9 * DAY)
        self.assertEqual(c["marks"], [[T0 + 60 + DAY, False]])
        self.assertIsNone(c["closed_at"])

    def test_a_message_we_start_closes_it_and_keeps_the_promise(self):
        sent = T0 + 5 * HOUR
        c = self.one(ask_and_promise() + [[sent, A]], T0 + 9 * DAY)
        self.assertEqual((c["closed_at"], c["closed_by"], c["due_at"]), (sent, "message", None))
        self.assertEqual(c["marks"], [[sent, True]])

    def test_a_persons_reply_closes_it(self):
        sent = T0 + 5 * HOUR
        c = self.one(ask_and_promise() + [[sent, H]], T0 + 9 * DAY)
        self.assertEqual((c["closed_at"], c["closed_by"]), (sent, "human_reply"))

    def test_a_late_message_closes_it_but_the_promise_stays_broken(self):
        sent = T0 + 3 * DAY
        c = self.one(ask_and_promise() + [[sent, A]], T0 + 9 * DAY)
        self.assertEqual(c["closed_at"], sent)
        self.assertEqual(c["marks"], [[T0 + 60 + DAY, False]])

    def test_a_check_in_keeps_the_promise_and_leaves_it_open(self):
        told = T0 + 20 * HOUR
        c = self.one(ask_and_promise() + [[told, A], [told, P]], T0 + 21 * HOUR)
        self.assertIsNone(c["closed_at"])
        self.assertEqual((c["told"], c["due_at"]), ([told], told + DAY))
        self.assertEqual(c["marks"], [[told, True]])

    def test_a_check_in_that_is_never_followed_breaks_the_next_day(self):
        told = T0 + 20 * HOUR
        c = self.one(ask_and_promise() + [[told, A], [told, Q]], T0 + 9 * DAY)
        self.assertEqual(c["marks"], [[told, True], [told + DAY, False]])

    def test_answering_the_customers_next_message_is_not_us_coming_back(self):
        chase = T0 + 2 * HOUR
        c = self.one(ask_and_promise() + [[chase, C], [chase + 30, A]], T0 + 9 * DAY)
        self.assertIsNone(c["closed_at"])
        self.assertEqual(c["marks"], [[T0 + 60 + DAY, False]])

    def test_the_second_half_of_the_same_reply_is_not_a_follow_up(self):
        c = self.one(ask_and_promise() + [[T0 + 75, A]], T0 + HOUR)
        self.assertIsNone(c["closed_at"])
        self.assertEqual(c["marks"], [])

    def test_repeating_the_hand_off_line_does_not_open_a_second_commitment(self):
        chase = T0 + 2 * HOUR
        events = ask_and_promise() + [[chase, C], [chase + 30, A], [chase + 30, P]]
        self.assertEqual(self.one(events, T0 + 9 * DAY)["promised_at"], T0 + 60)

    def test_a_new_promise_after_a_close_is_a_new_commitment(self):
        closed, again = T0 + 5 * HOUR, T0 + 2 * DAY
        events = ask_and_promise() + [[closed, A], [again, C], [again + 60, A], [again + 60, P]]
        got = commitments.derive(sorted(events), now=T0 + 9 * DAY)
        self.assertEqual([(c["promised_at"], c["closed_at"]) for c in got], [(T0 + 60, closed), (again + 60, None)])

    def test_what_happens_after_the_reading_is_not_read(self):
        c = self.one(ask_and_promise() + [[T0 + 5 * HOUR, A]], T0 + HOUR)
        self.assertIsNone(c["closed_at"])

    def test_nothing_but_a_message_event_can_close_it(self):
        """An assignment, the output guard, a refusal flag: none of them is a message on the
        thread, so none of them closes a commitment."""
        for code in rules.EVENT_CODES:
            if code in (A, H, C):
                continue
            c = self.one(ask_and_promise() + [[T0 + 5 * HOUR, code]], T0 + 9 * DAY)
            self.assertIsNone(c["closed_at"], code)


class Summary(unittest.TestCase):
    def numbers(self, facts, now):
        return commitments.summarize(facts, REGISTER, now)

    def test_open_overdue_kept_and_broken(self):
        now = T0 + 30 * DAY
        facts = [
            fact(1, ask_and_promise(now - 2 * HOUR)),                                       # open, not due
            fact(2, ask_and_promise(now - 30 * HOUR)),                                      # broke 6h ago
            fact(3, ask_and_promise(now - 9 * DAY)),                                        # broke last week
            fact(4, ask_and_promise(now - 20 * HOUR) + [[now - HOUR, A]]),                  # kept, closed
            fact(5, ask_and_promise(now - 20 * HOUR) + [[now - HOUR, A], [now - HOUR, Q]]),  # kept, still open
        ]
        got = self.numbers(facts, now)
        self.assertEqual(got["commitments_open"], 4)
        self.assertEqual(got["commitments_overdue"], 2)
        self.assertEqual(got["promises_kept_24h"], 2)
        self.assertEqual(got["promises_broken_24h"], 1)   # the week-old one broke once, long ago
        self.assertEqual(got["commitments_closed_24h"], 1)
        self.assertEqual(got["oldest_overdue_h"], (9 * DAY - 60 - DAY) // HOUR)

    def test_a_closed_conversation_does_not_close_its_promise(self):
        now = T0 + 9 * DAY
        got = self.numbers([fact(1, ask_and_promise(), is_open=False)], now)
        self.assertEqual((got["commitments_open"], got["commitments_overdue"]), (1, 1))

    def test_open_promises_are_counted_under_their_owner(self):
        now = T0 + 9 * DAY
        facts = [fact(1, ask_and_promise(), "proof_sent"), fact(2, ask_and_promise(), "stats_wrong"),
                 fact(3, ask_and_promise(), "other")]
        got = self.numbers(facts, now)
        self.assertEqual(got["open_by_kind"], {"credit_verification": 1, "analytics": 1, commitments.UNBACKED: 1})
        self.assertEqual(got["commitments_open_unbacked"], 2)   # analytics has no owner yet, `other` has no kind


class Owners(unittest.TestCase):
    def errors(self, change):
        register = copy.deepcopy(REGISTER)
        change(register["commitments"])
        return commitments.validate(register, rules.SHAPE_IDS)

    def test_the_repo_register_is_valid(self):
        self.assertEqual(commitments.validate(REGISTER, rules.SHAPE_IDS), [])

    def test_credit_verification_comes_first_then_analytics(self):
        kinds = REGISTER["commitments"]["kinds"]
        order = sorted(kinds, key=lambda k: kinds[k]["priority"])
        self.assertEqual(order[:2], ["credit_verification", "analytics"])
        self.assertEqual({kinds[k]["priority"] for k in ("refund", "request_status")}, {3})

    def test_a_person_can_never_own_a_commitment(self):
        for owner in ("Jan", "U038BM16T7W", "5465657", "person:jan", "team:catalog", "job:", ""):
            got = self.errors(lambda s, o=owner: s["kinds"]["credit_verification"].update(owner=o))
            self.assertTrue(any("never an owner" in e for e in got), owner)

    def test_a_promise_nobody_owns_has_to_say_why(self):
        got = self.errors(lambda s: s["kinds"]["analytics"].pop("unbacked_reason"))
        self.assertTrue(any("unbacked_reason" in e for e in got))

    def test_a_kind_must_say_what_is_being_done_and_what_resolves_it(self):
        for field in ("doing", "trigger"):
            got = self.errors(lambda s, f=field: s["kinds"]["claim"].pop(f))
            self.assertTrue(any(f"`{field}` is required" in e for e in got), field)

    def test_a_shape_has_one_owner(self):
        got = self.errors(lambda s: s["kinds"]["claim"]["shapes"].append("proof_sent"))
        self.assertTrue(any("already owned by" in e for e in got))

    def test_an_invented_shape_is_refused(self):
        got = self.errors(lambda s: s["kinds"]["claim"]["shapes"].append("vip_customer"))
        self.assertTrue(any("not a classifier shape" in e for e in got))

    def test_the_register_check_runs_the_ledger_check(self):
        register = copy.deepcopy(REGISTER)
        register["commitments"]["kinds"]["claim"]["owner"] = "Jan"
        self.assertTrue(any("never an owner" in e for e in fixloop.validate(register)))

    def test_a_missing_section_is_an_error(self):
        register = copy.deepcopy(REGISTER)
        del register["commitments"]
        self.assertTrue(any("commitments" in e for e in fixloop.validate(register)))


class Ledger(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.store = Store.open_default(self.tmp.name)
        self.addCleanup(self.store.close)
        self.path = os.path.join(self.tmp.name, "monitor.sqlite")

    def rows(self):
        cur = self.store.db.execute(
            "SELECT conversation_id, promised_at, recorded_at, kind, owner, contact_id, last_told_at, due_at, "
            "closed_at, closed_by, doing, resolves_on FROM commitments ORDER BY conversation_id, promised_at")
        names = [d[0] for d in cur.description]
        return [dict(zip(names, r)) for r in cur]

    def test_a_row_says_what_is_being_done_what_resolves_it_when_and_who_owns_it(self):
        self.store.keep([(fact(1, ask_and_promise()), "contact_a")], REGISTER, T0 + HOUR)
        (row,) = self.rows()
        kind = REGISTER["commitments"]["kinds"]["credit_verification"]
        self.assertEqual(row["conversation_id"], "1")
        self.assertEqual((row["kind"], row["owner"]), ("credit_verification", "job:request-comms"))
        self.assertEqual((row["doing"], row["resolves_on"]), (kind["doing"], kind["trigger"]))
        self.assertEqual((row["due_at"], row["closed_at"], row["contact_id"]), (T0 + 60 + DAY, None, "contact_a"))

    def test_only_a_new_read_of_the_thread_closes_the_row(self):
        first = fact(1, ask_and_promise())
        self.store.keep([(first, "contact_a")], REGISTER, T0 + HOUR)
        self.store.keep([(dict(first, open=False), "contact_a")], REGISTER, T0 + 2 * DAY)   # closed in Intercom
        self.assertIsNone(self.rows()[0]["closed_at"])
        sent = T0 + 3 * DAY
        self.store.keep([(fact(1, ask_and_promise() + [[sent, A]]), "contact_a")], REGISTER, sent + HOUR)
        (row,) = self.rows()
        self.assertEqual((row["closed_at"], row["closed_by"], row["due_at"]), (sent, "message", None))
        self.assertEqual(row["recorded_at"], T0 + HOUR)   # when the ledger first knew, kept

    def test_the_module_has_no_way_to_close_a_commitment_by_hand(self):
        public = [n for n in dir(commitments) if not n.startswith("_") and callable(getattr(commitments, n))]
        self.assertFalse([n for n in public if "close" in n or "resolve" in n or "complete" in n], public)

    def test_an_open_promise_is_never_pruned_and_a_kept_one_is(self):
        old = T0 - 400 * DAY
        self.store.keep([(fact(1, ask_and_promise(old), is_open=False), "a"),
                         (fact(2, ask_and_promise(old) + [[old + HOUR, A]], is_open=False), "b"),
                         (fact(3, ask_and_promise(old) + [[old + HOUR, A]], is_open=True), "c")], REGISTER, T0)
        self.store.prune_facts(T0 - 180 * DAY)
        self.assertEqual(sorted(f["id"] for f in self.store.facts()), ["1", "3"])
        self.assertEqual([r["conversation_id"] for r in self.rows()], ["1", "3"])

    def test_a_thread_that_is_gone_takes_its_rows_with_it(self):
        self.store.keep([(fact(1, ask_and_promise()), "a")], REGISTER, T0 + 2 * DAY)
        self.assertEqual(len(self.store.db.execute(
            "SELECT 1 FROM commitment_outbox").fetchall()), 1)
        self.store.delete_facts(["1"])
        self.assertEqual(self.rows(), [])
        self.assertEqual(self.store.db.execute(
            "SELECT COUNT(*) FROM commitment_outbox").fetchone()[0], 0)

    def test_the_status_driver_is_told_which_thread_carries_the_promise(self):
        self.store.keep([(fact(1, ask_and_promise(), "proof_sent"), "contact_a"),
                         (fact(2, ask_and_promise(T0 + HOUR), "request_status"), "contact_a"),
                         (fact(3, ask_and_promise(), "claim_code_added"), "contact_a"),
                         (fact(4, ask_and_promise() + [[T0 + 5 * HOUR, A]], "proof_sent"), "contact_b")],
                        REGISTER, T0 + DAY)

        def thread(contact, request_type):
            return commitments.thread_for(contact, request_type, REGISTER, self.path)

        self.assertEqual(thread("contact_a", "credit"), "2")     # the newest open credit promise
        self.assertEqual(thread("contact_a", "claim"), "3")
        self.assertEqual(thread("contact_a", "erasure"), "")
        self.assertEqual(thread("contact_b", "credit"), "")      # already closed by a sent message
        self.assertEqual(thread("stranger", "credit"), "")
        self.assertEqual(thread("", "credit"), "")

    def test_an_unreadable_ledger_answers_no_thread(self):
        missing = os.path.join(self.tmp.name, "nope", "monitor.sqlite")
        self.assertEqual(commitments.thread_for("contact_a", "credit", REGISTER, missing), "")

    def test_the_lookup_cannot_write(self):
        self.store.keep([(fact(1, ask_and_promise()), "contact_a")], REGISTER, T0 + HOUR)
        before = self.rows()
        commitments.thread_for("contact_a", "credit", REGISTER, self.path)
        self.assertEqual(self.rows(), before)
        db = sqlite3.connect(f"file:{self.path}?mode=ro", uri=True)
        self.addCleanup(db.close)
        with self.assertRaises(sqlite3.OperationalError):
            db.execute("DELETE FROM commitments")


class Outbox(unittest.TestCase):
    OPEN = {"enabled": True, "lines": {"credit": {"waiting": {"enabled": True, "approval_ref": "fable-r5"}}}}

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.live = os.path.join(self.tmp.name, "request-comms.live")
        open(self.live, "w").close()
        previous = os.environ.get("REQUEST_COMMS_LIVE")
        os.environ["REQUEST_COMMS_LIVE"] = self.live
        self.addCleanup(self._restore_live, previous)
        self.store = Store.open_default(self.tmp.name)
        self.addCleanup(self.store.close)

    @staticmethod
    def _restore_live(previous):
        Outbox._restore("REQUEST_COMMS_LIVE", previous)

    @staticmethod
    def _restore(name, previous):
        if previous is None:
            os.environ.pop(name, None)
        else:
            os.environ[name] = previous

    def rows(self):
        cur = self.store.db.execute(
            "SELECT conversation_id, promised_at, due_at, kind, owner, request_type, line_state, state, "
            "held_reason, sent_at FROM commitment_outbox ORDER BY due_at")
        names = [d[0] for d in cur.description]
        return [dict(zip(names, r)) for r in cur]

    def keep(self, fact_row, now, policy):
        self.store.keep([(fact_row, "contact_a")], REGISTER, now, policy=policy)

    def test_a_due_promise_enqueues_one_row_and_a_second_tick_in_the_cycle_adds_none(self):
        now = T0 + 2 * DAY
        self.keep(fact(1, ask_and_promise()), now, self.OPEN)
        self.keep(fact(1, ask_and_promise()), now + HOUR, self.OPEN)
        (row,) = self.rows()
        self.assertEqual((row["due_at"], row["state"], row["line_state"]),
                         (T0 + 60 + DAY, "queued", "waiting"))
        self.assertEqual((row["kind"], row["owner"], row["request_type"]),
                         ("credit_verification", "job:request-comms", "credit"))
        self.assertIsNone(row["held_reason"])

    def test_a_check_in_marks_that_cycle_sent_and_the_next_cycle_enqueues_again(self):
        told = T0 + 2 * DAY
        self.keep(fact(1, ask_and_promise()), told + HOUR, self.OPEN)
        events = ask_and_promise() + [[told, A], [told, P]]
        self.keep(fact(1, events), told + HOUR, self.OPEN)
        (first,) = self.rows()
        self.assertEqual((first["state"], first["sent_at"]), ("sent", told))
        self.keep(fact(1, events), told + DAY + HOUR, self.OPEN)
        self.assertEqual([r["state"] for r in self.rows()], ["sent", "queued"])
        self.assertEqual(self.rows()[1]["due_at"], told + DAY)

    def test_a_cycle_already_answered_before_the_first_read_is_never_queued(self):
        told = T0 + 2 * DAY
        events = ask_and_promise() + [[told, A], [told, P]]
        self.keep(fact(1, events), told + HOUR, self.OPEN)
        self.assertEqual(self.rows(), [])
        self.assertEqual(commitments.outbox_counts(self.store.db),
                         {"messages_queued": 0, "messages_held": 0, "messages_held_by_reason": {}})

    def test_a_promise_that_comes_due_on_a_thread_nobody_reads_again_is_enqueued(self):
        self.keep(fact(1, ask_and_promise()), T0 + HOUR, self.OPEN)      # read once, not due yet
        self.assertEqual(self.rows(), [])
        later = T0 + 2 * DAY                                             # nothing happened on the thread since
        self.assertEqual(self.store.enqueue_due(REGISTER, later, self.OPEN), 1)
        self.assertEqual(self.store.enqueue_due(REGISTER, later + HOUR, self.OPEN), 0)
        (row,) = self.rows()
        self.assertEqual((row["conversation_id"], row["due_at"], row["state"]), ("1", T0 + 60 + DAY, "queued"))
        self.assertEqual((row["kind"], row["owner"], row["request_type"]),
                         ("credit_verification", "job:request-comms", "credit"))

    def test_the_sweep_and_a_re_read_of_the_same_cycle_make_one_row(self):
        self.keep(fact(1, ask_and_promise()), T0 + HOUR, self.OPEN)
        self.store.enqueue_due(REGISTER, T0 + 2 * DAY, self.OPEN)
        self.keep(fact(1, ask_and_promise()), T0 + 2 * DAY + HOUR, self.OPEN)
        self.assertEqual(len(self.rows()), 1)

    def test_the_sweep_leaves_a_kept_promise_and_one_not_yet_due_alone(self):
        kept = ask_and_promise() + [[T0 + 2 * HOUR, A]]
        self.keep(fact(1, kept), T0 + 3 * HOUR, self.OPEN)
        self.keep(fact(2, ask_and_promise(T0 + 2 * DAY)), T0 + 2 * DAY + HOUR, self.OPEN)
        self.assertEqual(self.store.enqueue_due(REGISTER, T0 + 2 * DAY + 2 * HOUR, self.OPEN), 0)
        self.assertEqual(self.rows(), [])

    def test_the_sweep_skips_a_thread_this_tick_could_not_read(self):
        self.keep(fact(1, ask_and_promise()), T0 + HOUR, self.OPEN)
        self.keep(fact(2, ask_and_promise()), T0 + HOUR, self.OPEN)
        self.assertEqual(self.store.enqueue_due(REGISTER, T0 + 2 * DAY, self.OPEN, skip={"1": "http 503"}), 1)
        self.assertEqual([r["conversation_id"] for r in self.rows()], ["2"])

    def test_the_sweep_holds_an_unowned_promise_with_its_reason(self):
        self.keep(fact(1, ask_and_promise(), shape="stats_wrong"), T0 + HOUR, self.OPEN)
        self.store.enqueue_due(REGISTER, T0 + 2 * DAY, self.OPEN)
        (row,) = self.rows()
        self.assertEqual((row["state"], row["held_reason"]), ("held", "no_owner"))

    def test_an_unowned_kind_is_held_and_says_why(self):
        self.keep(fact(1, ask_and_promise(), shape="stats_wrong"), T0 + 2 * DAY, self.OPEN)
        (row,) = self.rows()
        self.assertEqual((row["state"], row["held_reason"]), ("held", "no_owner"))

    def test_with_the_driver_disabled_the_row_is_held_not_queued(self):
        self.keep(fact(1, ask_and_promise()), T0 + 2 * DAY, dict(self.OPEN, enabled=False))
        (row,) = self.rows()
        self.assertEqual((row["state"], row["held_reason"]), ("held", "driver_disabled"))

    def test_with_the_policy_on_but_no_live_file_the_row_is_held(self):
        os.unlink(self.live)
        self.keep(fact(1, ask_and_promise()), T0 + 2 * DAY, self.OPEN)
        (row,) = self.rows()
        self.assertEqual((row["state"], row["held_reason"]), ("held", "driver_not_live"))

    def test_with_the_kill_file_present_the_row_is_held_as_killed(self):
        killed = os.path.join(self.tmp.name, "request-comms.disabled")
        open(killed, "w").close()
        previous = os.environ.get("REQUEST_COMMS_DISABLED")
        os.environ["REQUEST_COMMS_DISABLED"] = killed
        self.addCleanup(self._restore, "REQUEST_COMMS_DISABLED", previous)
        self.keep(fact(1, ask_and_promise()), T0 + 2 * DAY, self.OPEN)
        (row,) = self.rows()
        self.assertEqual((row["state"], row["held_reason"]), ("held", "driver_killed"))

    def test_a_promise_no_longer_read_from_the_thread_loses_its_outbox_rows(self):
        self.keep(fact(1, ask_and_promise()), T0 + 2 * DAY, self.OPEN)
        self.assertEqual([r["state"] for r in self.rows()], ["queued"])
        self.keep(fact(1, [[T0, C], [T0 + 60, A]]), T0 + 2 * DAY + HOUR, self.OPEN)
        self.assertEqual(self.rows(), [])
        self.assertEqual(commitments.outbox_counts(self.store.db),
                         {"messages_queued": 0, "messages_held": 0, "messages_held_by_reason": {}})

    def test_an_unapproved_line_is_held(self):
        policy = {"enabled": True, "lines": {"credit": {"waiting": {"enabled": True, "approval_ref": ""}}}}
        self.keep(fact(1, ask_and_promise()), T0 + 2 * DAY, policy)
        (row,) = self.rows()
        self.assertEqual((row["state"], row["held_reason"]), ("held", "line_unapproved"))

    def test_the_outbox_never_closes_the_commitment(self):
        self.keep(fact(1, ask_and_promise()), T0 + 2 * DAY, self.OPEN)
        self.assertEqual(self.rows()[0]["state"], "queued")
        still_open = self.store.db.execute(
            "SELECT closed_at FROM commitments WHERE conversation_id='1'").fetchone()[0]
        self.assertIsNone(still_open)

    def test_a_message_on_the_thread_closes_the_commitment_and_marks_the_row_sent(self):
        sent = T0 + 3 * DAY
        self.keep(fact(1, ask_and_promise()), T0 + 2 * DAY, self.OPEN)
        self.keep(fact(1, ask_and_promise() + [[sent, A]]), sent + HOUR, self.OPEN)
        self.assertIsNotNone(self.store.db.execute(
            "SELECT closed_at FROM commitments WHERE conversation_id='1'").fetchone()[0])
        self.assertEqual((self.rows()[0]["state"], self.rows()[0]["sent_at"]), ("sent", sent))

    def test_the_counts_are_the_rows_still_waiting_on_a_send(self):
        self.keep(fact(1, ask_and_promise()), T0 + 2 * DAY, self.OPEN)
        self.keep(fact(2, ask_and_promise(), shape="stats_wrong"), T0 + 2 * DAY, self.OPEN)
        self.assertEqual(commitments.outbox_counts(self.store.db),
                         {"messages_queued": 1, "messages_held": 1,
                          "messages_held_by_reason": {"no_owner": 1}})


class Backlog(unittest.TestCase):
    WHOLE = {"whole_inbox": True}

    def build(self, facts, now, scope=None):
        return backlog.build(facts, REGISTER, now, self.WHOLE if scope is None else scope)

    def test_waiting_runs_from_the_first_unanswered_message(self):
        events = [[T0, C], [T0 + 60, A], [T0 + DAY, C], [T0 + 3 * DAY, C]]
        self.assertEqual(backlog.waiting_since(events, T0 + 9 * DAY), T0 + DAY)
        self.assertIsNone(backlog.waiting_since(events + [[T0 + 4 * DAY, A]], T0 + 9 * DAY))
        self.assertIsNone(backlog.waiting_since([[T0, A]], T0 + DAY))

    def test_a_note_or_an_assignment_does_not_answer_the_customer(self):
        events = [[T0, C], [T0 + 60, rules.EV_HUMAN_ASSIGNED], [T0 + 90, rules.EV_GUARD]]
        self.assertEqual(backlog.waiting_since(events, T0 + DAY), T0)

    def test_the_inbox_numbers(self):
        now = T0 + 30 * DAY
        facts = [
            fact(1, [[now - 3 * DAY, C]], "other"),                                         # waiting on us 3d
            fact(2, [[now - 200 * DAY, C]], "other"),                                       # waiting 200d
            fact(3, [[now - 2 * HOUR, C]], "other"),                                        # under the limit
            fact(4, [[now - 3 * DAY, C]], "robot_mail"),                                    # a bounce
            fact(5, ask_and_promise(now - 5 * HOUR), "proof_sent"),                         # waiting on them
            fact(6, [[now - 3 * DAY, C]], "other", is_open=False),                          # closed: not backlog
            fact(7, [[now - 9 * DAY, C], [now - HOUR, rules.EV_HUMAN_ASSIGNED], [now - HOUR, H]], "other"),
        ]
        doc = self.build(facts, now)
        self.assertEqual(doc["open"], 6)
        self.assertEqual(doc["waiting_on_us"], 2)
        self.assertEqual(doc["waiting_on_us_robot_mail"], 1)
        self.assertEqual(doc["waiting_on_us_under_limit"], 1)
        self.assertEqual(doc["waiting_on_customer"], 2)
        self.assertEqual(doc["oldest_waiting_on_us_h"], 200 * 24)
        self.assertEqual(doc["waiting_on_us_by_wait"],
                         {"under_2d": 0, "2d_to_7d": 1, "7d_to_30d": 0, "30d_to_90d": 0, "over_90d": 1})
        self.assertEqual((doc["promised_a_person_24h"], doc["handed_to_human_24h"], doc["human_replied_24h"]), (1, 1, 1))
        self.assertEqual((doc["commitments_open"], doc["commitments_overdue"]), (1, 0))
        self.assertEqual((doc["promises_kept_24h"], doc["promises_broken_24h"]), (0, 0))
        self.assertEqual((doc["written_at"], doc["schema"]), (now, "support-backlog.v1"))

    def test_the_file_has_every_field_the_instrument_reads(self):
        doc = self.build([fact(1, ask_and_promise())], T0 + DAY)
        for key in ("open", "waiting_on_us", "waiting_on_customer", "promised_a_person_24h", "handed_to_human_24h",
                    "human_replied_24h", "oldest_waiting_on_us_h", "written_at", "commitments_open",
                    "commitments_overdue", "promises_kept_24h", "promises_broken_24h"):
            self.assertIsInstance(doc[key], int, key)

    def test_an_inbox_that_was_not_read_is_null_never_zero(self):
        doc = self.build([fact(1, [[T0, C]], "other")], T0 + 9 * DAY, scope={"whole_inbox": False})
        for key in backlog.INBOX_FIELDS:
            self.assertIsNone(doc[key], key)
        self.assertIn("not measured", backlog.render(doc))
        self.assertEqual(alerts.evaluate_inbox(doc, None, alerts.thresholds(REGISTER)), [])

    def test_the_file_holds_counts_only(self):
        doc = self.build([fact(1234567890123456, ask_and_promise())], T0 + DAY)
        self.assertNotIn("1234567890123456", json.dumps(doc))

    def test_the_write_is_atomic_and_leaves_no_temp_file(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "deep", "support-backlog.json")
            backlog.write({"written_at": 1}, path)
            backlog.write({"written_at": 2}, path)
            self.assertEqual(json.load(open(path)), {"written_at": 2})
            self.assertEqual(os.listdir(os.path.dirname(path)), ["support-backlog.json"])

    def test_more_overdue_promises_than_yesterday_pages(self):
        t = alerts.thresholds(REGISTER)
        now = T0 + 30 * DAY
        today = self.build([fact(i, ask_and_promise(now - 30 * HOUR)) for i in range(130)], now)
        before = dict(today, commitments_overdue=100, waiting_on_us=today["waiting_on_us"])
        keys = [f.key for f in alerts.evaluate_inbox(today, before, t) if f.severity == alerts.PAGE]
        self.assertEqual(keys, ["promises:overdue_rise"])
        self.assertEqual([f.key for f in alerts.evaluate_inbox(today, dict(today), t) if f.severity == alerts.PAGE], [])

    def test_more_customers_waiting_than_yesterday_pages(self):
        t = alerts.thresholds(REGISTER)
        now = T0 + 30 * DAY
        today = self.build([fact(i, [[now - 3 * DAY, C]], "other") for i in range(140)], now)
        keys = [f.key for f in alerts.evaluate_inbox(today, dict(today, waiting_on_us=100), t)]
        self.assertEqual(keys, ["inbox:waiting_rise"])

    def test_no_reading_from_yesterday_is_said_not_assumed_quiet(self):
        today = self.build([fact(1, ask_and_promise())], T0 + DAY)
        (finding,) = alerts.evaluate_inbox(today, None, alerts.thresholds(REGISTER))
        self.assertEqual((finding.key, finding.severity), ("unmeasured:inbox_day_before", alerts.INFO))


def thread(tid, created, parts, is_open=True, contact="contact_a", subject=""):
    """A reduced Intercom thread, the shape scripts/caroline_monitor/collect.py emits."""
    return {"id": str(tid), "created_at": created, "updated_at": max([created] + [p["ts"] for p in parts]),
            "state": "open" if is_open else "closed", "open": is_open, "admin_assignee_id": "5763097",
            "team_assignee_id": "", "tags": [], "tag_at": {}, "contact": "h", "contact_id": contact,
            "source": {"type": "conversation", "delivered_as": "customer_initiated", "at": "user", "aid": "",
                       "subject": subject, "body": "here is the proof for my credit, see the attached file", "att": 1},
            "parts": parts, "parts_total": len(parts), "first_admin_reply_at": None}


def caroline(ts, body):
    return {"t": "comment", "at": "admin", "aid": "5763097", "ts": ts, "body": body, "att": 0, "asg": None}


class FakeIntercom:
    def __init__(self, threads, fail=None):
        self.threads, self.fail, self.fetched = threads, fail, []

    def __call__(self, token, start, end, skip=None, since_ts=None):
        if self.fail:
            raise cli.collect.CollectError(self.fail)
        skip = skip or {}
        listed = [t for t in self.threads
                  if start <= t["created_at"] < end or t["open"] or (since_ts and t["updated_at"] >= since_ts)]
        fetch = [t for t in listed if skip.get(t["id"]) != t["updated_at"]]
        self.fetched.append([t["id"] for t in fetch])
        return {"listed": [{"id": t["id"], "created_at": t["created_at"], "updated_at": t["updated_at"],
                            "open": t["open"]} for t in listed],
                "total_count": len(listed), "threads": fetch,
                "skipped": [t["id"] for t in listed if skip.get(t["id"]) == t["updated_at"]],
                "gone": [], "errors": {}}


class Tick(unittest.TestCase):
    HANDOFF = "I'm pulling in a teammate to take this from here."

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.out = os.path.join(self.tmp.name, "support-backlog.json")
        log, cli.log = cli.log, lambda message: None
        self.addCleanup(setattr, cli, "log", log)

    def tick(self, intercom, now, dry_run=False):
        args = types.SimpleNamespace(register=None, state_dir=self.tmp.name, baseline=None, corpus=None, now=now,
                                     dry_run=dry_run, backlog_out=self.out)
        with open(os.devnull, "w") as sink:
            stdout, sys.stdout = sys.stdout, sink
            try:
                return cli.cmd_tick(args, poster=lambda channel, text: None, collector=intercom, token="t")
            finally:
                sys.stdout = stdout

    def inbox(self, now):
        """One promise made 30h ago with nothing since, and one conversation open since last year."""
        return [thread(1, now - 30 * HOUR, [caroline(now - 30 * HOUR + 60, self.HANDOFF)]),
                thread(2, now - 300 * DAY, [], contact="contact_b")]

    def test_the_tick_writes_the_file_from_the_whole_inbox(self):
        now = T0 + 30 * DAY
        self.tick(FakeIntercom(self.inbox(now)), now)
        doc = json.load(open(self.out))
        self.assertEqual(doc["written_at"], now)
        self.assertTrue(doc["scope"]["whole_inbox"])
        self.assertEqual(doc["open"], 2)                       # the year-old one is outside the weekly window
        self.assertEqual(doc["waiting_on_us"], 1)
        self.assertEqual(doc["oldest_waiting_on_us_h"], 300 * 24)
        self.assertEqual((doc["commitments_open"], doc["commitments_overdue"], doc["promises_broken_24h"]), (1, 1, 1))
        self.assertEqual((doc["messages_queued"], doc["messages_held"]), (0, 1))
        self.assertEqual(doc["messages_held_by_reason"], {"line_disabled": 1})

    def test_the_ledger_row_is_written_by_the_tick_and_closed_by_a_sent_message(self):
        now = T0 + 30 * DAY
        threads = self.inbox(now)
        self.tick(FakeIntercom(threads), now)
        path = os.path.join(self.tmp.name, "monitor.sqlite")
        self.assertEqual(commitments.thread_for("contact_a", "credit", REGISTER, path), "1")
        later = now + 2 * HOUR
        threads[0] = thread(1, now - 30 * HOUR, [caroline(now - 30 * HOUR + 60, self.HANDOFF),
                                                 caroline(now + HOUR, "2 credits were approved and are now live.")])
        self.tick(FakeIntercom(threads), later)
        self.assertEqual(commitments.thread_for("contact_a", "credit", REGISTER, path), "")
        self.assertEqual(json.load(open(self.out))["commitments_open"], 0)

    def test_a_promise_that_comes_due_between_ticks_is_enqueued_though_its_thread_never_moved(self):
        now = T0 + 30 * DAY
        threads = [thread(1, now - 2 * HOUR, [caroline(now - 2 * HOUR + 60, self.HANDOFF)])]
        intercom = FakeIntercom(threads)
        self.tick(intercom, now)
        first = json.load(open(self.out))
        self.assertEqual((first["commitments_open"], first["commitments_overdue"], first["messages_held"]), (1, 0, 0))
        later = now + 26 * HOUR
        self.tick(intercom, later)                             # same thread, same updated_at: not read again
        self.assertEqual(intercom.fetched[-1], [])
        doc = json.load(open(self.out))
        self.assertEqual((doc["commitments_overdue"], doc["messages_queued"], doc["messages_held"]), (1, 0, 1))
        self.tick(intercom, later + 2 * HOUR)
        self.assertEqual(json.load(open(self.out))["messages_held"], 1)

    def test_a_conversation_that_left_the_listing_is_no_longer_open(self):
        now = T0 + 30 * DAY
        threads = self.inbox(now)
        self.tick(FakeIntercom(threads), now)
        threads[1] = dict(threads[1], open=False, state="closed")   # closed with no new activity: not listed again
        self.tick(FakeIntercom(threads), now + 2 * HOUR)
        doc = json.load(open(self.out))
        self.assertEqual((doc["open"], doc["waiting_on_us"]), (1, 0))

    def test_a_blind_tick_leaves_the_last_good_file_to_go_stale(self):
        now = T0 + 30 * DAY
        self.tick(FakeIntercom(self.inbox(now)), now)
        self.assertEqual(self.tick(FakeIntercom([], fail="503"), now + 2 * HOUR), 0)
        self.assertEqual(json.load(open(self.out))["written_at"], now)

    def test_a_dry_run_writes_no_file_and_enqueues_nothing(self):
        now = T0 + 30 * DAY
        self.tick(FakeIntercom(self.inbox(now)), now, dry_run=True)
        self.assertFalse(os.path.exists(self.out))
        self.assertEqual(commitments.outbox_counts(Store.open_default(self.tmp.name).db)["messages_held"], 0)

    def test_a_file_that_cannot_be_written_fails_the_tick(self):
        now = T0 + 30 * DAY
        blocker = os.path.join(self.tmp.name, "blocker")
        open(blocker, "w").close()
        self.out = os.path.join(blocker, "support-backlog.json")
        self.assertEqual(self.tick(FakeIntercom(self.inbox(now)), now), 1)


if __name__ == "__main__":
    unittest.main()
