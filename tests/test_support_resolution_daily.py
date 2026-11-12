"""Behavioural tests for scripts/support-resolution-daily.py.

The script runs unattended once a day and is READ-ONLY on Intercom. What these lock:

  * every conversation in the window lands in exactly one outcome, and they sum to the cohort;
  * the resolution number cannot be raised by closing a conversation, by an internal note, by the
    guard's fallback line, or by a promise of a person;
  * "could not read" is UNMEASURED (exit 3, no rate), never a zero and never a healthy number;
  * the reader can only search and read: any other Intercom call is refused before the network;
  * nothing a customer wrote reaches the record or the posted line.

Stdlib unittest, no network, no clock: every thread is built here.
"""
import importlib.util
import io
import json
import os
import pathlib
import re
import tempfile
import unittest
import urllib.error
from contextlib import redirect_stdout
from unittest import mock

_ROOT = pathlib.Path(__file__).resolve().parent.parent
_spec = importlib.util.spec_from_file_location("support_resolution_daily", _ROOT / "scripts" / "support-resolution-daily.py")
d = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(d)

START, END = 1_000_000, 1_000_000 + 24 * 3600
CARO, JAN = d.CAROLINE_ADMIN_ID, "5465657"
HANDOFF = "I'm pulling in a teammate to take this from here."
QUEUE = "Everything you send here is recorded against your account and your open requests and goes to the verification team."
ANSWER = "You can add a credit from the track page: open the track, choose Add credit, and pick your role."
SECRET_WORDS = "ZEBRA-CUSTOMER-WORDS"


def cust(ts, body=SECRET_WORDS, att=0):
    return {"t": "comment", "at": "user", "aid": "", "ts": ts, "body": body, "att": att, "asg": None}


def caro(ts, body, kind="comment"):
    return {"t": kind, "at": "admin", "aid": CARO, "ts": ts, "body": body, "att": 0, "asg": None}


def human(ts, body="Hi, this is sorted now."):
    return {"t": "comment", "at": "admin", "aid": JAN, "ts": ts, "body": body, "att": 0, "asg": None}


def assign(ts, to=JAN, by=CARO):
    return {"t": "assignment", "at": "admin", "aid": by, "ts": ts, "body": "", "att": 0,
            "asg": {"type": "admin", "id": to}}


def thread(parts, cid="1", created=START - 10 * 86400, source="admin", assignee=CARO, **extra):
    t = {"id": cid, "created_at": created, "updated_at": END, "admin_assignee_id": assignee,
         "source": {"at": source}, "parts": parts}
    t.update(extra)
    return t


T = START + 100


class OutcomeTests(unittest.TestCase):
    def one(self, parts, **kw):
        return d.outcome(thread(parts, **kw), START, END)

    def test_answered_with_nothing_left_waiting_is_resolved(self):
        self.assertEqual(self.one([cust(T), caro(T + 5, ANSWER)]), "resolved")

    def test_the_customer_did_not_write_in_the_window_so_it_is_not_in_the_cohort(self):
        self.assertIsNone(self.one([cust(START - 50), caro(T, ANSWER)]))
        # A bulk message we sent with no customer message is not a conversation she resolved.
        self.assertIsNone(self.one([caro(T, "Your credit was approved.")]))
        self.assertIsNone(self.one([cust(END + 1)]))

    def test_no_reply(self):
        self.assertEqual(self.one([cust(T)]), "no_reply")

    def test_a_new_conversation_opened_by_the_customer_counts_from_its_first_message(self):
        self.assertEqual(self.one([], created=T, source="user"), "no_reply")
        self.assertEqual(self.one([caro(T + 5, ANSWER)], created=T, source="user"), "resolved")

    def test_closing_a_conversation_does_not_resolve_it(self):
        self.assertEqual(self.one([cust(T)], state="closed", open=False), "no_reply")
        closed = {"t": "close", "at": "admin", "aid": CARO, "ts": T + 5, "body": "", "att": 0, "asg": None}
        self.assertEqual(self.one([cust(T), closed], state="closed", open=False), "no_reply")

    def test_an_internal_note_is_not_a_reply(self):
        self.assertEqual(self.one([cust(T), caro(T + 5, ANSWER, kind="note")]), "no_reply")
        self.assertEqual(self.one([cust(T), {**human(T + 5), "t": "note"}]), "no_reply")

    def test_the_customer_wrote_again_and_has_no_reply(self):
        self.assertEqual(self.one([cust(T), caro(T + 5, ANSWER), cust(T + 9)]), "customer_wrote_again")

    def test_an_attachment_with_no_text_is_a_customer_message(self):
        self.assertEqual(self.one([cust(T), caro(T + 5, ANSWER), cust(T + 9, body="", att=1)]), "customer_wrote_again")

    def test_a_promise_of_a_person_is_never_resolved(self):
        self.assertEqual(self.one([cust(T), caro(T + 5, ANSWER + " " + HANDOFF)]), "person_promised_unassigned")
        self.assertEqual(self.one([cust(T), caro(T + 5, HANDOFF), assign(T + 6)]), "person_promised_assigned")
        # Curly apostrophe and Spanish, as seen live.
        self.assertEqual(self.one([cust(T), caro(T + 5, "I\u2019m pulling in a teammate to take this from here.")]),
                         "person_promised_unassigned")
        self.assertEqual(self.one([cust(T), caro(T + 5, "Un compa\u00f1ero se encargar\u00e1 del seguimiento.")]),
                         "person_promised_unassigned")

    def test_a_person_replying_after_a_promise_does_not_turn_it_into_caroline_resolving_it(self):
        # A person answered after her promise: not hers, and the customer is no longer waiting.
        self.assertEqual(self.one([cust(T), caro(T + 5, HANDOFF), assign(T + 6), human(T + 60)]),
                         "answered_by_person")

    def test_a_queue_line_then_a_promise_then_a_persons_reply_is_answered_by_a_person(self):
        # The sequence from the QA review of 6bbdb73da, exactly: it must never land in waiting.
        parts = [cust(T), caro(T + 5, QUEUE), caro(T + 10, HANDOFF), human(T + 60)]
        self.assertEqual(self.one(parts), "answered_by_person")
        m = d.measure([thread(parts)], START, END)
        self.assertEqual((m["resolved"], m["answered_by_person"], m["still_waiting"]), (0, 1, 0))

    def test_a_persons_reply_settles_each_kind_of_parked_reply_before_it(self):
        fallback = d.FALLBACK_LINE
        WAITING = set(d.OUTCOMES) - {"resolved", "answered_by_person"}
        for parked in ([caro(T + 5, QUEUE)],
                       [caro(T + 5, HANDOFF)],
                       [caro(T + 5, HANDOFF), assign(T + 6)],
                       [caro(T + 5, fallback)],
                       [caro(T + 5, QUEUE), caro(T + 10, HANDOFF), assign(T + 11)]):
            with self.subTest(parked=[p.get("body") for p in parked]):
                self.assertIn(self.one([cust(T)] + parked), WAITING)   # parked, and nobody answered
                self.assertEqual(self.one([cust(T)] + parked + [human(T + 60)]), "answered_by_person")

    def test_a_guard_refusal_on_the_ledger_is_settled_by_a_persons_reply_too(self):
        parts = [cust(T), caro(T + 5, ANSWER), human(T + 60)]
        self.assertEqual(d.outcome(thread(parts), START, END, refused_at=T + 5), "answered_by_person")
        self.assertEqual(d.outcome(thread(parts[:2]), START, END, refused_at=T + 5), "guard_fallback")
        # A refusal AFTER the person's reply is not settled by it.
        self.assertEqual(d.outcome(thread(parts), START, END, refused_at=T + 90), "guard_fallback")

    # --- her own later answer settles her queue line, her refusal and the fallback line ---------
    FALLBACK = "I want to get this right for you. Could you tell me a little more about what you need help with?"
    REFUSAL = "A request is closed when the supporting information is not enough; you can submit it again with your supporting documents."

    def test_a_queue_line_she_then_answered_is_not_a_customer_waiting(self):
        # QA review of 19ced4778: customer -> her queue line -> her answer was read as queue_line.
        t = thread([cust(T), caro(T + 5, QUEUE), caro(T + 3600, ANSWER)])
        self.assertEqual(d.outcome(t, START, END), "resolved")
        m = d.measure([t], START, END)
        self.assertEqual((m["resolved"], m["still_waiting"]), (1, 0))

    def test_the_fallback_line_she_then_answered_is_not_a_customer_waiting(self):
        self.assertEqual(self.one([cust(T), caro(T + 5, self.FALLBACK)]), "guard_fallback")
        self.assertEqual(self.one([cust(T), caro(T + 5, self.FALLBACK), cust(T + 60), caro(T + 90, ANSWER)]), "resolved")

    def test_a_refusal_she_then_answered_is_not_a_customer_waiting(self):
        self.assertEqual(self.one([cust(T), caro(T + 5, self.REFUSAL), caro(T + 3600, ANSWER)]), "resolved")

    def test_her_latest_answer_decides_so_parking_it_again_is_waiting_again(self):
        self.assertEqual(self.one([cust(T), caro(T + 5, QUEUE), caro(T + 60, ANSWER), caro(T + 90, QUEUE)]), "queue_line")
        self.assertEqual(self.one([cust(T), caro(T + 5, ANSWER), caro(T + 60, self.FALLBACK)]), "guard_fallback")
        self.assertEqual(self.one([cust(T), caro(T + 5, QUEUE), caro(T + 60, self.REFUSAL)]), "refused")

    def test_an_answer_after_a_queue_line_does_not_cover_a_later_customer_message(self):
        self.assertEqual(self.one([cust(T), caro(T + 5, QUEUE), caro(T + 60, ANSWER), cust(T + 90)]), "customer_wrote_again")

    def test_a_bare_courtesy_is_a_reply_but_settles_nothing(self):
        for courtesy in ("You're welcome!", "Anytime, Eduardo!", "You got it.", "\u00a1Con gusto! Aqu\u00ed estoy si necesitas algo m\u00e1s.",
                         "De nada, Dao.", "Di nulla, Andrea!", "You're very welcome - glad I could help. Have a great day too."):
            with self.subTest(courtesy=courtesy):
                self.assertEqual(self.one([cust(T), caro(T + 5, QUEUE), cust(T + 60), caro(T + 65, courtesy)]), "queue_line")
                self.assertEqual(self.one([cust(T), caro(T + 5, self.FALLBACK), cust(T + 60), caro(T + 65, courtesy)]), "guard_fallback")
                self.assertEqual(self.one([cust(T), caro(T + 5, self.REFUSAL), cust(T + 60), caro(T + 65, courtesy)]), "refused")
                # With nothing parked before it, a courtesy is an ordinary reply, as it always was.
                self.assertEqual(self.one([cust(T), caro(T + 5, courtesy)]), "resolved")

    def test_a_courtesy_that_goes_on_to_say_something_is_an_answer(self):
        long_one = "You're welcome, Ian. " + ANSWER
        self.assertGreater(len(long_one), d.COURTESY_MAX_CHARS)
        self.assertEqual(self.one([cust(T), caro(T + 5, QUEUE), cust(T + 60), caro(T + 65, long_one)]), "resolved")
        # A courtesy that itself parks the conversation is a queue line, not a courtesy.
        parks = "You're welcome. We'll be in touch."
        self.assertNotIn(d.EV_COURTESY, {code for _, code in d.read_events(thread([caro(T, parks)]))})
        self.assertEqual(self.one([cust(T), caro(T + 5, ANSWER), cust(T + 60), caro(T + 65, parks)]), "queue_line")

    def test_only_a_person_settles_a_promise_of_a_person(self):
        # Her own later answer never does, and while the promise is open it settles nothing else.
        self.assertEqual(self.one([cust(T), caro(T + 5, HANDOFF), caro(T + 3600, ANSWER)]), "person_promised_unassigned")
        self.assertEqual(self.one([cust(T), caro(T + 5, HANDOFF), assign(T + 6), caro(T + 3600, ANSWER)]), "person_promised_assigned")
        self.assertEqual(self.one([cust(T), caro(T + 5, self.FALLBACK), caro(T + 9, HANDOFF), caro(T + 3600, ANSWER)]), "guard_fallback")
        t = thread([cust(T), caro(T + 5, HANDOFF), caro(T + 3600, ANSWER)])
        self.assertEqual(d.outcome(t, START, END, refused_at=T + 5), "guard_fallback")

    def test_a_refusal_on_the_ledger_is_settled_only_by_an_answer_that_came_later(self):
        refused, grace = T + 5, d.REFUSAL_GRACE_SECONDS
        # The line that REPLACED her refused reply lands seconds after the ledger row: not an answer.
        self.assertEqual(d.outcome(thread([cust(T), caro(refused + 1, ANSWER)]), START, END, refused_at=refused), "guard_fallback")
        self.assertEqual(d.outcome(thread([cust(T), caro(refused + grace, ANSWER)]), START, END, refused_at=refused), "guard_fallback")
        self.assertEqual(d.outcome(thread([cust(T), caro(refused + grace + 1, ANSWER)]), START, END, refused_at=refused), "resolved")
        later = [cust(T), caro(refused + 1, self.FALLBACK), cust(T + 600), caro(T + 700, ANSWER)]
        self.assertEqual(d.outcome(thread(later), START, END, refused_at=refused), "resolved")
        # A courtesy later is not an answer; a queue line later is what she left the customer with.
        self.assertEqual(d.outcome(thread(later[:3] + [caro(T + 700, "You're welcome!")]), START, END, refused_at=refused), "guard_fallback")
        self.assertEqual(d.outcome(thread(later[:3] + [caro(T + 700, QUEUE)]), START, END, refused_at=refused), "queue_line")

    def test_after_a_persons_reply_her_own_answer_settles_her_own_later_queue_line(self):
        parts = [cust(T), human(T + 60), cust(T + 90), caro(T + 95, QUEUE)]
        self.assertEqual(self.one(parts), "queue_line")
        self.assertEqual(self.one(parts + [caro(T + 3600, ANSWER)]), "answered_by_person")   # not waiting, not hers

    def test_only_what_follows_the_persons_reply_can_leave_the_customer_waiting_again(self):
        answered = [cust(T), caro(T + 5, QUEUE), human(T + 60)]
        self.assertEqual(self.one(answered + [cust(T + 90)]), "customer_wrote_again")
        self.assertEqual(self.one(answered + [cust(T + 90), caro(T + 95, QUEUE)]), "queue_line")
        self.assertEqual(self.one(answered + [cust(T + 90), caro(T + 95, HANDOFF)]),
                         "person_promised_unassigned")
        self.assertEqual(self.one(answered + [cust(T + 90), caro(T + 95, d.FALLBACK_LINE)]), "guard_fallback")
        self.assertEqual(self.one(answered + [caro(T + 95, QUEUE)]), "queue_line")
        # She parks it again and a person answers again: the LAST person's reply is the one that stands.
        self.assertEqual(self.one(answered + [caro(T + 95, QUEUE), human(T + 120)]), "answered_by_person")
        self.assertEqual(self.one(answered + [cust(T + 90), caro(T + 95, HANDOFF), human(T + 120)]),
                         "answered_by_person")
        self.assertEqual(self.one(answered + [cust(T + 90), human(T + 120)]), "answered_by_person")
        # She answers the follow-up cleanly: nobody is waiting, and it is still not counted as hers.
        self.assertEqual(self.one(answered + [cust(T + 90), caro(T + 95, ANSWER)]), "answered_by_person")

    def test_a_person_who_has_not_replied_changes_nothing(self):
        # An assignment or an internal note is not a reply: the queue line and the promise still wait.
        note = dict(human(T + 60), t="note")
        self.assertEqual(self.one([cust(T), caro(T + 5, QUEUE), note]), "queue_line")
        self.assertEqual(self.one([cust(T), caro(T + 5, HANDOFF), assign(T + 6)]), "person_promised_assigned")
        # A person's reply BEFORE the customer wrote settles nothing that came after it.
        self.assertEqual(self.one([human(T - 50), cust(T), caro(T + 5, QUEUE)]), "queue_line")

    def test_the_merge_paragraph_conditional_is_not_a_promise(self):
        merge = "Profiles claimed by someone else, and company or label profiles, are handled differently: I'll pass those on."
        self.assertEqual(self.one([cust(T), caro(T + 5, merge)]), "resolved")

    # The rate is Caroline's. A reply from a person is a person's answer, never her resolution.
    def test_a_reply_from_a_person_alone_is_not_caroline_resolving_it(self):
        self.assertEqual(self.one([cust(T), human(T + 60)]), "answered_by_person")

    def test_a_reply_from_a_person_after_hers_is_not_caroline_resolving_it(self):
        self.assertEqual(self.one([cust(T), caro(T + 5, ANSWER), human(T + 60)]), "answered_by_person")
        self.assertEqual(self.one([cust(T), human(T + 5), caro(T + 60, ANSWER)]), "answered_by_person")

    def test_a_person_who_replied_before_the_customer_wrote_does_not_take_her_answer_away(self):
        self.assertEqual(self.one([human(START - 700), cust(T), caro(T + 5, ANSWER)]), "resolved")

    def test_the_customer_writing_again_after_a_person_replied_is_still_waiting(self):
        self.assertEqual(self.one([cust(T), human(T + 60), cust(T + 120)]), "customer_wrote_again")

    def test_a_note_from_a_person_is_not_a_persons_answer(self):
        self.assertEqual(self.one([cust(T), caro(T + 5, ANSWER), {**human(T + 60), "t": "note"}]), "resolved")

    def test_assigned_to_a_person_without_telling_the_customer(self):
        self.assertEqual(self.one([cust(T), caro(T + 5, ANSWER), assign(T + 6)]), "assigned_untold")
        # The final assignee is a person but no assignment part says so.
        self.assertEqual(self.one([cust(T), caro(T + 5, ANSWER)], assignee=JAN), "assigned_untold")
        # Assigning to Caroline or the operator bot is not a person.
        self.assertEqual(self.one([cust(T), caro(T + 5, ANSWER), assign(T + 6, to=CARO)]), "resolved")
        self.assertEqual(self.one([cust(T), caro(T + 5, ANSWER), assign(T + 6, to=d.OPERATOR_BOT_ID)]), "resolved")

    def test_a_queue_line_is_not_resolved(self):
        self.assertEqual(self.one([cust(T), caro(T + 5, "Thank you. " + QUEUE)]), "queue_line")
        self.assertEqual(self.one([cust(T), caro(T + 5, "Your request is in the verification queue and the outcome comes to this conversation.")]),
                         "queue_line")

    def test_a_holding_message_is_not_an_answer(self):
        # The five bodies a bulk sender posted as Caroline on 2026-11-12 02Z to conversations
        # nobody had answered. Read as answers they were 38 "resolutions" in one hour.
        for body in (
            "Hi there \u2014 your message is here and it will be read. We will write to you here.",
            "Hi there \u2014 your credit request for this recording is here and queued for review. Nothing is needed from you right now.",
            "Hi there \u2014 I can see what you are asking about and it is with the team. If it is about a charge, we will tell you what we find; if it is about access to your account, we will tell you what we need.",
            "Hi there \u2014 your request to claim your profile is here. We are checking it and will write to you here with the result.",
            "Hi there \u2014 your removal request is here and has been logged. We will write to you here with the outcome.",
        ):
            self.assertEqual(self.one([cust(T), caro(T + 3 * 3600, body)]), "queue_line", body)

    def test_the_guard_fallback_line_is_not_resolved(self):
        self.assertEqual(self.one([cust(T), caro(T + 5, "I want to get this right for you. Could you tell me a little more about what you need help with?")]),
                         "guard_fallback")

    def test_a_refusal_on_the_ledger_is_not_resolved_whatever_the_conversation_shows(self):
        t = thread([cust(T), caro(T + 5, ANSWER)], cid="77")
        self.assertEqual(d.outcome(t, START, END), "resolved")
        self.assertEqual(d.outcome(t, START, END, refused_at=T + 5), "guard_fallback")
        self.assertEqual(d.measure([t], START, END, {"77": T + 5})["resolved"], 0)
        self.assertEqual(d.measure([t], START, END, {"other": T + 5})["resolved"], 1)

    def test_a_refusal_with_a_way_back(self):
        self.assertEqual(self.one([cust(T), caro(T + 5, "A request is closed when the supporting information is not enough; you can submit it again with your supporting documents.")]),
                         "refused")

    def test_an_earlier_promise_still_open_keeps_todays_answer_from_counting(self):
        earlier = [cust(START - 900), caro(START - 800, HANDOFF)]
        self.assertEqual(self.one(earlier + [cust(T), caro(T + 5, ANSWER)]), "earlier_promise_open")
        # Kept by a person replying, or by a person being assigned: today's answer counts.
        self.assertEqual(self.one(earlier + [human(START - 700), cust(T), caro(T + 5, ANSWER)]), "resolved")

    def test_events_after_the_window_have_not_happened(self):
        self.assertEqual(self.one([cust(T), caro(END + 5, ANSWER)]), "no_reply")
        self.assertEqual(self.one([cust(T), caro(T + 5, ANSWER), caro(END + 5, HANDOFF)]), "resolved")

    def test_an_operator_bot_part_is_not_a_reply(self):
        bot = {"t": "comment", "at": "bot", "aid": d.OPERATOR_BOT_ID, "ts": T + 5, "body": "We typically reply in a few hours.", "att": 0, "asg": None}
        self.assertEqual(self.one([cust(T), bot]), "no_reply")


class MeasureTests(unittest.TestCase):
    def test_every_conversation_lands_in_exactly_one_outcome_and_they_sum_to_the_cohort(self):
        threads = [
            thread([cust(T), caro(T + 5, ANSWER)], cid="a"),
            thread([cust(T)], cid="b"),
            thread([cust(T), caro(T + 5, HANDOFF)], cid="c"),
            thread([cust(T), caro(T + 5, QUEUE)], cid="d"),
            thread([caro(T, "bulk")], cid="outside"),
        ]
        m = d.measure(threads, START, END)
        self.assertEqual(m["cohort"], 4)
        self.assertEqual(sum(m["outcomes"].values()), 4)
        self.assertEqual(set(m["outcomes"]), set(d.OUTCOMES))
        self.assertEqual((m["resolved"], m["not_resolved"], m["resolution_rate"]), (1, 3, 0.25))
        self.assertEqual((m["answered_by_person"], m["still_waiting"]), (0, 3))

    def test_a_persons_answer_is_in_neither_carolines_rate_nor_the_waiting_count(self):
        threads = [
            thread([cust(T), caro(T + 5, ANSWER)], cid="a"),
            thread([cust(T), human(T + 60)], cid="b"),
            thread([cust(T), caro(T + 5, ANSWER), human(T + 60)], cid="c"),
            thread([cust(T)], cid="d"),
            thread([cust(T), caro(T + 5, QUEUE), caro(T + 10, HANDOFF), human(T + 60)], cid="e"),
            thread([cust(T), caro(T + 5, QUEUE)], cid="f"),
        ]
        record = d.build(threads, START, END, 24, None, None)
        m = record["window"]
        self.assertEqual(sum(m["outcomes"].values()), m["cohort"])
        self.assertEqual((m["cohort"], m["resolved"], m["answered_by_person"], m["still_waiting"]), (6, 1, 3, 2))
        self.assertEqual(m["resolved"] + m["answered_by_person"] + m["still_waiting"], m["cohort"])
        line = d.render(record)
        self.assertIn("resolved 1 of 6 (16.7%)", line)
        self.assertIn("Three buckets that add up to 6: resolved by Caroline 1, "
                      "answered by a person 3, waiting on us 2 (", line)

    def test_an_empty_window_has_no_rate_rather_than_a_zero_or_a_hundred(self):
        m = d.measure([], START, END)
        self.assertEqual(m["cohort"], 0)
        self.assertIsNone(m["resolution_rate"])
        self.assertIn("no conversations", d.render(d.build([], START, END, 24, None, None)))


class FallbackLinePinTests(unittest.TestCase):
    def test_the_fallback_line_is_the_one_the_plugin_posts(self):
        src = (_ROOT / "plugins" / "intercom" / "src" / "answer-bank.ts").read_text(encoding="utf-8")
        m = re.search(r'export const AI_QUEUE_FALLBACK = "([^"]+)";', src)
        self.assertIsNotNone(m)
        self.assertEqual(d.norm(m.group(1)), d.FALLBACK_LINE)
        self.assertIn("export const BLOCKED_REPLY_FALLBACK = AI_QUEUE_FALLBACK;", src)


class GuardLedgerTests(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.dir.cleanup)
        self.path = os.path.join(self.dir.name, "ledger.jsonl")
        # epoch 1_000_000 is 1970-01-12T13:46:40Z
        self.inside, self.before, self.after = "1970-01-12T14:00:00.000Z", "1970-01-12T13:00:00.000Z", "1970-01-13T13:46:40.000Z"

    def write(self, rows, name="ledger.jsonl"):
        with open(os.path.join(self.dir.name, name), "w", encoding="utf-8") as fh:
            for r in rows:
                fh.write((r if isinstance(r, str) else json.dumps(r)) + "\n")

    def test_a_missing_ledger_is_not_read_rather_than_zero_refusals(self):
        self.assertIsNone(d.read_guard(self.path, START, END))
        self.assertIsNone(d.read_guard("/nonexistent-dir/ledger.jsonl", START, END))
        text = d.render(d.build([], START, END, 24, None, None))
        self.assertIn("ledger NOT READ", text)
        self.assertNotIn("0 refusal", text)

    def test_counts_by_kind_inside_the_window_only(self):
        self.write([
            # The shape caroline-safety.ts writes: flags are {family, rule, excerpt}.
            {"ts": self.inside, "kind": "output_guard", "ref": "c1", "enforced": True, "flags": [
                {"family": "note", "rule": "altered_approved_line:status_chase", "excerpt": SECRET_WORDS},
                {"family": "contradict", "rule": "fact_unverified:status_chase", "excerpt": SECRET_WORDS}]},
            {"ts": self.inside, "kind": "output_guard", "ref": "c1", "enforced": True, "flags": [
                {"family": "promise", "rule": "timeframe_within", "excerpt": SECRET_WORDS}, "not a flag"]},
            {"ts": self.inside, "kind": "output_guard", "ref": "shadow", "enforced": False, "flags": [
                {"family": "promise", "rule": "guarantee", "excerpt": "x"}]},
            {"ts": self.before, "kind": "output_guard", "ref": "old", "enforced": True, "flags": []},
            {"ts": self.after, "kind": "output_guard", "ref": "new", "enforced": True, "flags": []},
            {"ts": self.inside, "kind": "output_guard_retry", "ref": "c2", "outcome": "pending"},
            {"ts": self.inside, "kind": "output_guard_retry", "ref": "c2", "outcome": "passed"},
            {"ts": self.inside, "kind": "output_guard_retry", "ref": "c3", "outcome": "pending"},
            {"ts": self.inside, "kind": "output_guard_retry", "ref": "c3", "outcome": "unusable"},
            {"ts": self.inside, "kind": "unbacked_handoff", "ref": "c4", "action": "stripped"},
            {"ts": self.inside, "kind": "unbacked_handoff", "ref": "c5", "action": "retry"},
            {"ts": self.inside, "kind": "inbound_injection", "ref": "c6"},
            "not json at all",
        ])
        g = d.read_guard(self.path, START, END)
        self.assertEqual(g["refused_final"], 2)
        self.assertEqual(g["refused_at"], {"c1": START + 800})   # 14:00:00, epoch seconds
        self.assertEqual(g["by_rule"], {"contradict/fact_unverified:status_chase": 1, "promise/timeframe_within": 1})
        self.assertEqual((g["retry_pending"], g["retry_passed"], g["retry_unusable"]), (2, 1, 1))
        self.assertEqual((g["handoff_stripped"], g["handoff_only"]), (1, 1))
        self.assertNotIn(SECRET_WORDS, json.dumps(g))

    def test_the_ledger_row_shape_read_here_is_the_one_the_plugin_writes(self):
        src = (_ROOT / "plugins" / "intercom" / "src" / "caroline-safety.ts").read_text(encoding="utf-8")
        row = src[src.index('kind: "output_guard",'):]
        row = row[:row.index("});")]
        for field in ("ref: p.conversationId", "enforced,", "flags: result.flags"):
            self.assertIn(field, row)
        for kind in ('kind: "output_guard_retry"', 'outcome: "pending"', 'outcome: "passed"'):
            self.assertIn(kind, src)
        chan = (_ROOT / "plugins" / "intercom" / "src" / "channel.ts").read_text(encoding="utf-8")
        for needle in ('kind: "unbacked_handoff"', '"stripped"', 'outcome: "unusable"'):
            self.assertIn(needle, chan)

    def test_sealed_generations_are_read_too(self):
        self.write([])
        self.write([{"ts": self.inside, "kind": "output_guard", "ref": "s1", "enforced": True, "flags": []}],
                   name="ledger.jsonl.sealed-19700112T140500Z")
        self.assertEqual(set(d.read_guard(self.path, START, END)["refused_at"]), {"s1"})

    def test_the_latest_refusal_in_a_conversation_is_the_one_kept(self):
        def iso(ts):
            return d.time.strftime("%Y-%m-%dT%H:%M:%S", d.time.gmtime(ts)) + ".790Z"
        self.write([{"ts": iso(START + 900), "kind": "output_guard", "ref": "c1", "enforced": True, "flags": []},
                    {"ts": iso(START + 7200), "kind": "output_guard", "ref": "c1", "enforced": True, "flags": []},
                    {"ts": iso(START + 300), "kind": "output_guard", "ref": "c1", "enforced": True, "flags": []}])
        self.assertEqual(d.read_guard(self.path, START, END)["refused_at"], {"c1": START + 7200})

    def test_the_line_prints_the_baseline_read_under_the_same_rules(self):
        text = d.render(d.build([], START, END, 24, None, None))
        resolved, cohort = d.BASELINE
        self.assertIn(f"Baseline 2026-11-12 under these rules: {resolved} of {cohort} (15.1%)", text)
        self.assertIn(f"it read {d.BASELINE_FIRST_READ} before", text)
        self.assertIn(f"Rules {d.RULES_VERSION}.", text)

    def test_the_record_never_carries_conversation_ids(self):
        self.write([{"ts": self.inside, "kind": "output_guard", "ref": "c1", "enforced": True, "flags": []}])
        rec = d.build([], START, END, 24, d.read_guard(self.path, START, END), None)
        self.assertNotIn("refused_at", rec["guard"])
        self.assertNotIn("c1", json.dumps(rec))
        json.dumps(rec)  # serialisable: no set left in it


class FakeIntercom:
    """Search and read only. `fail` is a set of conversation ids whose GET raises."""

    def __init__(self, convs, total=None, fail=(), search_error=None):
        self.convs, self.total, self.fail, self.search_error = convs, total, set(fail), search_error
        self.calls = []

    def __call__(self, method, path, token, body=None, attempts=5):
        self.calls.append((method, path))
        if path == "/conversations/search":
            if self.search_error:
                raise self.search_error
            return {"total_count": len(self.convs) if self.total is None else self.total,
                    "conversations": list(self.convs.values()), "pages": {}}
        cid = path.split("/")[2].split("?")[0]
        if cid in self.fail:
            raise urllib.error.URLError("boom")
        if cid == "gone":
            raise urllib.error.HTTPError(path, 404, "not found", None, None)
        return {"id": cid, "created_at": START - 5, "updated_at": END, "admin_assignee_id": CARO,
                "source": {"author": {"type": "admin", "id": CARO}},
                "conversation_parts": {"conversation_parts": [
                    {"part_type": "comment", "author": {"type": "user", "id": "u1"}, "created_at": T, "body": SECRET_WORDS},
                    {"part_type": "comment", "author": {"type": "admin", "id": CARO}, "created_at": T + 5, "body": ANSWER}]}}


class CollectTests(unittest.TestCase):
    def convs(self, n):
        return {str(i): {"id": str(i), "waiting_since": END - 60} for i in range(n)}

    def test_reads_every_listed_conversation(self):
        api = FakeIntercom(self.convs(3))
        threads, unread = d.collect("tok", START, request=api)
        self.assertEqual((len(threads), unread), (3, 0))
        self.assertEqual(d.measure(threads, START, END)["resolved"], 3)
        self.assertTrue(all(m in ("GET", "POST") for m, _ in api.calls))

    def test_a_failed_search_is_unmeasured_never_an_empty_inbox(self):
        with self.assertRaises(d.Unmeasured):
            d.collect("tok", START, request=FakeIntercom({}, search_error=urllib.error.URLError("down")))

    def test_a_short_search_is_unmeasured(self):
        with self.assertRaises(d.Unmeasured):
            d.collect("tok", START, request=FakeIntercom(self.convs(10), total=400))

    def test_too_many_unreadable_conversations_is_unmeasured(self):
        with self.assertRaises(d.Unmeasured):
            d.collect("tok", START, request=FakeIntercom(self.convs(10), fail={"1"}))

    def test_a_few_unreadable_are_counted_and_said(self):
        threads, unread = d.collect("tok", START, request=FakeIntercom(self.convs(100), fail={"1"}))
        self.assertEqual((len(threads), unread), (99, 1))
        rec = d.build(threads, START, END, 24, None, None, unread)
        self.assertIn("1 conversation(s) could not be read and are in neither number", d.render(rec))

    def test_a_deleted_conversation_is_not_a_read_failure(self):
        convs = self.convs(2)
        convs["gone"] = {"id": "gone"}
        threads, unread = d.collect("tok", START, request=FakeIntercom(convs))
        self.assertEqual((len(threads), unread), (2, 0))

    def test_inbox_waiting_buckets_by_how_long(self):
        now = END
        convs = {str(i): {"id": str(i), "waiting_since": now - age} for i, age in enumerate(
            (60, 5 * 3600, 7 * 3600, 2 * 86400, 30 * 86400, 200 * 86400))}
        w = d.inbox_waiting("tok", now, request=FakeIntercom(convs))
        self.assertEqual(w, {"under_6h": 2, "6h_to_24h": 1, "1d_to_7d": 1, "over_7d": 2, "total": 6})

    def test_inbox_waiting_that_cannot_be_read_is_unmeasured(self):
        with self.assertRaises(d.Unmeasured):
            d.inbox_waiting("tok", END, request=FakeIntercom({}, search_error=OSError("down")))


class ReadOnlyTests(unittest.TestCase):
    def test_the_reader_refuses_anything_but_a_search_or_a_read_before_the_network(self):
        with mock.patch.object(d.urllib.request, "urlopen", side_effect=AssertionError("network reached")):
            for method, path in (("PUT", "/conversations/1"), ("POST", "/conversations/1/reply"),
                                 ("POST", "/conversations/1/parts"), ("DELETE", "/conversations/1"),
                                 ("POST", "/conversations")):
                with self.assertRaises(ValueError, msg=f"{method} {path}"):
                    d._request(method, path, "tok", {})

    def test_the_source_names_no_write_route(self):
        src = (_ROOT / "scripts" / "support-resolution-daily.py").read_text(encoding="utf-8")
        for needle in ("/reply", "/parts", "/tags", "/close", "/snooze"):
            self.assertNotIn(f'"{needle}', src)
            self.assertNotIn(f"{needle}\"", src)


class MainTests(unittest.TestCase):
    def run_main(self, argv):
        out = io.StringIO()
        with redirect_stdout(out):
            rc = d.main(argv)
        return rc, out.getvalue()

    def test_offline_corpus_prints_the_line_and_keeps_customer_words_out(self):
        with tempfile.TemporaryDirectory() as tmp:
            corpus = os.path.join(tmp, "c.jsonl")
            with open(corpus, "w", encoding="utf-8") as fh:
                fh.write(json.dumps({"_meta": {}}) + "\n")
                fh.write(json.dumps(thread([cust(T), caro(T + 5, ANSWER)], cid="a")) + "\n")
                fh.write(json.dumps(thread([cust(T), caro(T + 5, HANDOFF)], cid="b")) + "\n")
            rc, text = self.run_main(["--corpus", corpus, "--until", str(END), "--no-ledger", "--state-dir", tmp])
            self.assertEqual(rc, 0)
            self.assertIn("resolved 1 of 2 (50.0%)", text)
            self.assertIn("resolved by Caroline 1, answered by a person 0, waiting on us 1 (", text)
            self.assertIn("Whole inbox, customer wrote last: NOT READ", text)
            self.assertNotIn(SECRET_WORDS, text)
            (record,) = [f for f in os.listdir(tmp) if f.endswith(".json")]
            body = pathlib.Path(tmp, record).read_text(encoding="utf-8")
            self.assertNotIn(SECRET_WORDS, body)
            self.assertNotIn(ANSWER, body)
            self.assertEqual(json.loads(body)["rules"], d.RULES_VERSION)

    def test_unmeasured_prints_no_rate_and_exits_3(self):
        with mock.patch.object(d, "resolve_token", return_value="tok"), \
                mock.patch.object(d, "collect", side_effect=d.Unmeasured("search failed: URLError")):
            rc, text = self.run_main(["--until", str(END), "--no-ledger"])
        self.assertEqual(rc, 3)
        self.assertIn("UNMEASURED", text)
        self.assertNotIn("%", text)
        self.assertNotIn("resolved 0", text)

    def test_no_token_is_unmeasured(self):
        with self.assertRaises(d.Unmeasured):
            d.resolve_token(env={}, files=("/nonexistent/edge.env",))

    def test_a_live_run_writes_only_counts(self):
        with tempfile.TemporaryDirectory() as tmp, \
                mock.patch.object(d, "resolve_token", return_value="tok"), \
                mock.patch.object(d, "collect", return_value=([thread([cust(T), caro(T + 5, ANSWER)])], 0)), \
                mock.patch.object(d, "inbox_waiting", return_value={"under_6h": 1, "6h_to_24h": 0, "1d_to_7d": 0, "over_7d": 4, "total": 5}):
            rc, text = self.run_main(["--until", str(END), "--no-ledger", "--state-dir", tmp, "--json"])
            self.assertEqual(rc, 0)
            rec = json.loads(text)
            self.assertEqual(rec["window"]["resolved"], 1)
            self.assertEqual(rec["inbox_waiting"]["total"], 5)
            self.assertNotIn(SECRET_WORDS, text)
            self.assertIn("nobody has replied: 5 (under 6h 1, 6h to 24h 0, 1 to 7 days 0, over 7 days 4)", d.render(rec))


if __name__ == "__main__":
    unittest.main()
