"""Tests for the Caroline monitor and fix loop (scripts/caroline_monitor/, scripts/caroline-monitor.py).

Stdlib unittest only (no pytest, no network) - run by name in pr-validate.yml:

    python3 -m unittest -v tests.test_caroline_monitor

What is pinned here, and why each pin is load-bearing:

* ``Classifier`` - every shape is reachable, the order decides ties the way the register expects,
  and a reply that quotes our own mail is not read as a robot.
* ``ApprovedCopy`` - the reader is tied to the REAL approved lines in
  plugins/intercom/src/answer-bank.ts: the hand-off line is a promise, the decline line is a
  refusal, the receipt line is a queue line. If the copy changes and the patterns do not follow,
  the headline silently drops to zero; this fails instead.
* ``Events`` - who counts as a person. The default team is not one; a note is not a reply.
* ``Metrics`` - every thread lands in exactly one outcome class, and a matured read ignores what
  happened after the cut.
* ``Alerts`` - the monitor can FIRE: a rise pages, an unchanged page is not repeated, a worse one
  is, and an unmeasured week is never read as a quiet one.
* ``Register`` - the repo's register is valid, and each rule of the fix loop refuses its
  mutation (a thread id in the register, a person row with no reason, automation on a copy row,
  a ceiling raised above the baseline).
* ``Remeasure`` - a fix that did not move its own shape is `did_not_work`; one that fell with
  everything else is not credited.
* ``Tick`` - end to end with a fake Intercom and a fake Slack: pages once, stamps only after
  delivery, pages about being blind, keeps no text.
"""
from __future__ import annotations

import copy
import json
import os
import re
import sqlite3
import sys
import tempfile
import types
import time
import unittest

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(REPO, "scripts"))

from caroline_monitor import (alerts, calibrate, cli, collect, commitments, fixloop, metrics, rules,  # noqa: E402
                              safety_records)
from caroline_monitor.store import Store  # noqa: E402
sys.path.insert(0, os.path.join(REPO, "scripts", "lib"))
import injection_watch  # noqa: E402
from datetime import datetime, timezone  # noqa: E402,F401

DAY, HOUR = 86400, 3600
CAROLINE, JAN, BOT = "5763097", "5465657", "4359478"
DEFAULT_TEAM = "2238258"
HANDOFF = "I'm pulling in a teammate to take this from here."
NOW = 1_800_000_000


def part(kind, author_type, author_id, ts, body="", assigned=None):
    return {"t": kind, "at": author_type, "aid": author_id, "ts": ts, "body": body, "att": 0, "asg": assigned}


def thread(tid="1", created=NOW - 10 * DAY, ask="hello", subject="", parts=(), outbound=False,
           source_type="conversation", admin_assignee=CAROLINE, team_assignee=DEFAULT_TEAM, tags=(), tag_at=None):
    return {
        "id": str(tid), "created_at": created, "updated_at": created + 5 * DAY, "state": "open", "open": True,
        "admin_assignee_id": admin_assignee, "team_assignee_id": team_assignee, "tags": list(tags),
        "tag_at": tag_at or {},
        "source": {"type": source_type, "delivered_as": "customer_initiated", "at": "admin" if outbound else "user",
                   "aid": CAROLINE if outbound else "", "subject": subject, "body": "" if outbound else ask, "att": 0},
        "parts": ([part("comment", "user", "", created + 60, ask)] if outbound else []) + list(parts),
        "parts_total": len(parts), "contact": "x", "first_admin_reply_at": None,
    }


def codes(t, **kw):
    return "".join(code for _, code in rules.read_events(t, **kw))


def fact(tid, created, events, shape="other"):
    return {"id": str(tid), "created_at": created, "updated_at": created, "shape": shape, "outbound": False,
            "events": sorted([[created + off, code] for off, code in events]), "rules": rules.reader_version()}


def bank_text(entry_id):
    """The text of one answer-bank entry, read from the TypeScript source."""
    with open(os.path.join(REPO, "plugins", "intercom", "src", "answer-bank.ts")) as f:
        source = f.read()
    at = source.index(f'id: "{entry_id}"')
    m = re.compile(r'text:\s*((?:"(?:[^"\\]|\\.)*"\s*\+?\s*)+)').search(source, at)
    return "".join(re.findall(r'"((?:[^"\\]|\\.)*)"', m.group(1))).replace("\\'", "'")


def bank_const(name):
    with open(os.path.join(REPO, "plugins", "intercom", "src", "answer-bank.ts")) as f:
        return re.search(rf'export const {name} = "([^"]+)"', f.read()).group(1)


class Classifier(unittest.TestCase):
    PROOF_SUBJECT = "Re: Additional Information Required for Credit Submission"
    CASES = [
        ("robot_mail", dict(ask="This is an automatic reply. I am out of office until Monday.", subject="Automatic reply: hello", source_type="email")),
        ("legal_notice", dict(ask="This is a DMCA takedown notice from our attorney regarding copyright infringement.")),
        ("gdpr_erasure", dict(ask="Under GDPR I request erasure of all my personal data. Please delete my account.")),
        ("claim_conflict", dict(ask="Someone else has claimed my profile and it is not them, it is mine.")),
        ("refund_dispute", dict(ask="I was charged twice and I want a refund.")),
        ("cancel_subscription", dict(ask="I want to cancel my subscription.")),
        ("plaque_order", dict(ask="Where is the plaque I ordered last month?")),
        ("artist_link", dict(ask="Hi Muso, I'd like to connect a Spotify or Tidal artist profile to my Muso profile.")),
        ("declined_why", dict(ask="Why was my credit request declined?")),
        ("proof_what_needed", dict(ask="What exactly do you need from me? Which credit is this about?", subject=PROOF_SUBJECT, outbound=True, source_type="email")),
        ("proof_sent", dict(ask="Here is the screenshot of the liner notes, attached.", subject=PROOF_SUBJECT, outbound=True, source_type="email")),
        ("claim_code_added", dict(ask="I added the code to my Instagram bio.")),
        ("request_status", dict(ask="Any update on my credit request? It has been pending for weeks.")),
        ("request_withdraw_correct", dict(ask="Please withdraw my pending credit request, I submitted the wrong role.")),
        ("claim_start_problem", dict(ask="How do I claim my profile? The claim button does nothing.")),
        ("merge_split", dict(ask="I have two profiles under my name, can you merge them into one?")),
        ("credit_wrong", dict(ask="There is a credit on my profile that is not mine, please remove it.")),
        ("credit_add_howto", dict(ask="How do I add a missing credit to my profile?")),
        ("billing_question", dict(ask="What is the price of the pro plan and when is my next invoice?")),
        ("account_access", dict(ask="I can't log in to my account, the password reset never arrives.")),
        ("human_request", dict(ask="Can I talk to a human please")),
        ("thanks_empty", dict(ask="Thanks!")),
    ]

    def test_each_case_lands_on_its_shape(self):
        for expected, kw in self.CASES:
            with self.subTest(shape=expected):
                self.assertEqual(rules.classify(thread(**kw)), expected)

    def test_every_rule_names_a_real_shape_and_other_is_the_only_fallback(self):
        named = [sid for sid, _ in rules.RULES]
        self.assertEqual(len(named), len(set(named)))
        self.assertEqual(set(named) | {"other"}, set(rules.SHAPE_IDS))
        self.assertEqual(rules.classify(thread(ask="zxqv plomb treeb wunder gallop ferrin moss")), "other")

    def test_a_reply_quoting_our_own_mail_is_not_a_robot(self):
        ask = ("Here are my documents.\n\nOn Mon, Nov 3, 2026 Muso.AI <support@muso.ai> wrote:\n"
               "This is an automated message. Please do not reply. Unsubscribe here.")
        t = thread(ask=ask, subject=self.PROOF_SUBJECT, outbound=True, source_type="email")
        self.assertEqual(rules.classify(t), "proof_sent")

    def test_the_ask_is_read_past_a_bare_greeting(self):
        t = thread(ask="Hi", parts=[part("comment", "user", "", NOW - 9 * DAY, "I want to cancel my subscription")])
        self.assertEqual(rules.classify(t), "cancel_subscription")

    def test_legal_outranks_everything_a_legal_notice_also_mentions(self):
        t = thread(ask="Our lawyer is sending a cease and desist. Cancel my subscription and refund me.")
        self.assertEqual(rules.classify(t), "legal_notice")


class ApprovedCopy(unittest.TestCase):
    """The reader against the real approved lines. No copy is duplicated here."""

    def reply(self, text):
        t = thread(parts=[part("comment", "admin", CAROLINE, NOW - 9 * DAY, text)])
        return codes(t)

    def test_the_hand_off_line_is_a_person_promise(self):
        self.assertIn(rules.EV_PROMISE, self.reply(bank_const("HANDOFF_LINE")))

    def test_the_honesty_lines_are_owed_follow_ups_and_not_person_promises(self):
        # firstmate inbox 010 (2026-11-14): "keep counting it as a commitment ... make the guard and
        # the monitor agree on it (both treat it as an owed follow-up, not a person promise)".
        for name in ("HONEST_FALLBACK", "HONEST_FALLBACK_UNRECORDED"):
            with self.subTest(line=name):
                got = self.reply(bank_const(name))
                self.assertIn(rules.EV_QUEUE, got)
                self.assertNotIn(rules.EV_PROMISE, got)
                facts = rules.thread_facts(thread(parts=[
                    part("comment", "customer", "contact_1", NOW - 9 * DAY, "Where is my request?"),
                    part("comment", "admin", CAROLINE, NOW - 9 * DAY, bank_const(name)),
                ]))
                opened = commitments.derive(facts["events"], now=NOW - 8 * DAY)
                self.assertEqual([c["promise"] for c in opened], ["queue"], opened)

    def test_the_old_honesty_line_is_still_a_person_promise(self):
        # Already-answered threads carry it; rewriting history would under-count them.
        self.assertIn(rules.EV_PROMISE, self.reply("I'll make sure this gets to the team."))

    def test_the_decline_line_is_a_refusal_and_not_a_hand_off(self):
        got = self.reply(bank_text("declined"))
        self.assertIn(rules.EV_REFUSAL, got)
        self.assertNotIn(rules.EV_PROMISE, got)

    def test_the_receipt_and_status_lines_are_queue_lines_not_promises(self):
        # document_thanks stopped being a queue line on 2026-11-15 (Aaron order #2): it used to say
        # the document "goes to the verification team", which is a person-coming line. It is now a
        # receipt only, so the assertion is that it names no queue AND no promise.
        got = self.reply(bank_text("document_thanks"))
        self.assertNotIn(rules.EV_QUEUE, got)
        self.assertNotIn(rules.EV_PROMISE, got)
        # status_chase still names the verification queue, which is a job queue, not a person.
        got = self.reply(bank_text("status_chase"))
        self.assertIn(rules.EV_QUEUE, got)
        self.assertNotIn(rules.EV_PROMISE, got)

    def test_the_merge_paragraph_is_an_explanation_not_a_promise(self):
        self.assertNotIn(rules.EV_PROMISE, self.reply(bank_text("merge_how")))

    def test_the_claim_copy_still_carries_a_day_count(self):
        # The known residual of the date-promise exemption. When the copy is fixed this test is
        # the reminder to lower monitor.page.date_promise_max_per_week to 0.
        self.assertIn(rules.EV_DATE, self.reply(bank_text("claim_how")))

    def test_the_statutory_clock_and_a_refused_date_are_not_date_promises(self):
        self.assertNotIn(rules.EV_DATE, self.reply("Written confirmation on this thread, within one month of today."))
        got = self.reply("I can't promise a response or full resolution by Friday.")
        self.assertNotIn(rules.EV_DATE, got)
        self.assertIn(rules.EV_REFUSAL, got)
        self.assertIn(rules.EV_DATE, self.reply("You'll hear back within 3 business days."))


class SafetyRecords(unittest.TestCase):
    """The pre-send owed-follow-up record `outbound.ts` writes before it claims a case was recorded."""

    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.ledger = os.path.join(self.dir, "ledger.jsonl")

    def record(self, conv, at):
        injection_watch.append({"kind": "owed_followup", "source": "intercom", "ref": conv,
                                "ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(at)),
                                "bank_version": "2026-11-14.1"}, ledger=self.ledger)

    def test_a_record_the_thread_owes_a_follow_up_for_is_backed(self):
        self.record("1", NOW - 2 * HOUR)
        got = safety_records.summarize([fact("1", NOW - DAY, [(0, "c"), (HOUR, "a"), (DAY - HOUR, "q")])],
                                       ledger=self.ledger, now=NOW)
        self.assertEqual((got["owed_followup_24h"], got["owed_followup_unbacked"], got["owed_followup_error"]),
                         (1, 0, None))

    def test_a_record_with_no_commitment_on_the_thread_is_unbacked(self):
        self.record("2", NOW - 2 * HOUR)
        got = safety_records.summarize([fact("2", NOW - DAY, [(0, "c"), (HOUR, "a")])],
                                       ledger=self.ledger, now=NOW)
        self.assertEqual((got["owed_followup_24h"], got["owed_followup_unbacked"]), (1, 1))

    def test_a_commitment_opened_before_the_record_does_not_back_it(self):
        self.record("3", NOW - 2 * HOUR)
        got = safety_records.summarize([fact("3", NOW - DAY, [(0, "c"), (DAY - 3 * HOUR, "q")])],
                                       ledger=self.ledger, now=NOW)
        self.assertEqual(got["owed_followup_unbacked"], 1)

    def record_ms(self, conv, at):
        """Exactly what the plugin writes: `new Date().toISOString()`, milliseconds included."""
        stamp = datetime.fromtimestamp(at, timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z"
        injection_watch.append({"kind": "owed_followup", "source": "intercom", "ref": conv,
                                "ts": stamp, "bank_version": "2026-11-14.2"}, ledger=self.ledger)
        return stamp

    def not_sent(self, conv, record_ts):
        """Exactly what the plugin writes when the POST after the record failed."""
        injection_watch.append({"kind": "owed_followup_not_sent", "source": "intercom", "ref": conv,
                                "record_ts": record_ts,
                                "ts": record_ts,
                                "bank_version": "2026-11-14.2"}, ledger=self.ledger)

    def test_a_record_the_send_never_delivered_is_not_counted(self):
        at = NOW - 2 * HOUR
        stamp = self.record_ms("11", at)
        self.not_sent("11", stamp)
        got = safety_records.summarize([fact("11", NOW - DAY, [(0, "c"), (HOUR, "a")])],
                                       ledger=self.ledger, now=NOW)
        self.assertEqual((got["owed_followup_24h"], got["owed_followup_unbacked"],
                          got["owed_followup_unmeasured"]), (0, 0, 0))

    def test_a_second_record_in_the_same_conversation_is_still_counted(self):
        at = NOW - 2 * HOUR
        self.not_sent("12", self.record_ms("12", at))
        self.record_ms("12", at + 60)
        got = safety_records.summarize([fact("12", NOW - DAY, [(0, "c"), (HOUR, "a")])],
                                       ledger=self.ledger, now=NOW)
        self.assertEqual((got["owed_followup_24h"], got["owed_followup_unbacked"]), (1, 1))

    def test_the_send_that_follows_the_record_in_the_same_second_backs_it(self):
        # The record is written immediately before the POST, and the monitor truncates thread
        # event times to whole seconds: the commitment lands in the same second, never before it.
        self.record_ms("5", NOW - 2 * HOUR + 0.9)
        got = safety_records.summarize([fact("5", NOW - DAY, [(0, "c"), (NOW - 2 * HOUR, "q")])],
                                       ledger=self.ledger, now=NOW)
        self.assertEqual((got["owed_followup_24h"], got["owed_followup_unbacked"]), (1, 0))

    def test_a_record_whose_thread_was_not_read_is_unmeasured(self):
        self.record("6", NOW - 2 * HOUR)
        got = safety_records.summarize([fact("7", NOW - DAY, [(0, "c")])],
                                       ledger=self.ledger, now=NOW)
        self.assertEqual((got["owed_followup_24h"], got["owed_followup_unbacked"],
                          got["owed_followup_unmeasured"]), (1, 0, 1))

    def test_a_record_is_never_both_unmeasured_and_unbacked(self):
        self.record("8", NOW - 2 * HOUR)      # thread not read
        self.record("9", NOW - 2 * HOUR)      # thread read, no commitment
        got = safety_records.summarize([fact("9", NOW - DAY, [(0, "c")])], ledger=self.ledger, now=NOW)
        self.assertEqual((got["owed_followup_unbacked"], got["owed_followup_unmeasured"]), (1, 1))

    def test_with_no_thread_read_nothing_is_called_unbacked(self):
        self.record("10", NOW - 2 * HOUR)
        got = safety_records.summarize([], ledger=self.ledger, now=NOW)
        self.assertIsNone(got["owed_followup_unbacked"])
        self.assertEqual(got["owed_followup_unmeasured"], 1)

    def test_an_unreadable_ledger_is_unknown_never_zero(self):
        got = safety_records.summarize([fact("1", NOW - DAY, [(0, "q")])], ledger=self.dir, now=NOW)
        self.assertIsNone(got["owed_followup_24h"])
        self.assertIsNone(got["owed_followup_unbacked"])
        self.assertTrue(got["owed_followup_error"])

    def test_the_ledger_digest_counts_the_records(self):
        self.record("1", NOW - HOUR)
        self.record("1", NOW - 2 * HOUR)
        got = injection_watch.digest(self.ledger, hours=24, now=datetime.now(timezone.utc))
        self.assertEqual(got["owed_followup"]["records"], 2)

    def test_the_ledger_digest_leaves_out_a_record_the_send_never_delivered(self):
        stamp = self.record_ms("13", NOW - HOUR)
        self.not_sent("13", stamp)
        got = injection_watch.digest(self.ledger, hours=24, now=datetime.now(timezone.utc))
        self.assertEqual(got["owed_followup"]["records"], 0)
        self.assertEqual(got["owed_followup"]["conversations"], [])
        self.assertEqual(got["owed_followup"]["not_sent"], 1)


class Events(unittest.TestCase):
    def test_the_default_team_and_caroline_herself_are_not_a_person(self):
        t = thread(parts=[
            part("default_assignment", "bot", BOT, NOW - 9 * DAY, "", {"type": "team", "id": DEFAULT_TEAM}),
            part("assignment", "admin", CAROLINE, NOW - 9 * DAY, "", {"type": "admin", "id": CAROLINE}),
            part("comment", "admin", CAROLINE, NOW - 9 * DAY, HANDOFF)])
        self.assertNotIn(rules.EV_HUMAN_ASSIGNED, codes(t))

    def test_an_assignment_to_a_human_admin_is(self):
        t = thread(parts=[part("assignment", "admin", CAROLINE, NOW - 9 * DAY, "", {"type": "admin", "id": JAN})])
        self.assertIn(rules.EV_HUMAN_ASSIGNED, codes(t))

    def test_a_team_counts_only_once_the_register_names_it_as_staffed(self):
        t = thread(parts=[part("assignment", "admin", CAROLINE, NOW - 9 * DAY, "", {"type": "team", "id": "7111794"})])
        self.assertNotIn(rules.EV_HUMAN_ASSIGNED, codes(t))
        self.assertIn(rules.EV_HUMAN_ASSIGNED, codes(t, staffed_teams=("7111794",)))
        self.assertNotEqual(rules.reader_version(), rules.reader_version(staffed_teams=("7111794",)))

    def test_a_new_bot_id_stops_counting_once_listed(self):
        t = thread(parts=[part("assignment", "admin", CAROLINE, NOW - 9 * DAY, "", {"type": "admin", "id": "999"})])
        self.assertIn(rules.EV_HUMAN_ASSIGNED, codes(t))
        self.assertNotIn(rules.EV_HUMAN_ASSIGNED, codes(t, non_human_admins=(CAROLINE, BOT, "999")))

    def test_an_unseen_assignment_is_dated_late_never_early(self):
        t = thread(admin_assignee=JAN)
        events = rules.read_events(t)
        self.assertIn([t["updated_at"], rules.EV_HUMAN_ASSIGNED], events)

    def test_notes_and_bot_parts_are_not_replies(self):
        t = thread(parts=[part("note", "admin", JAN, NOW - 9 * DAY, "internal"),
                          part("comment", "bot", BOT, NOW - 9 * DAY, "We typically reply in a few hours.")])
        self.assertEqual(codes(t), rules.EV_CUSTOMER)

    def test_a_human_comment_is_a_human_reply(self):
        t = thread(parts=[part("comment", "admin", JAN, NOW - 9 * DAY, "Done, merged.")])
        self.assertIn(rules.EV_HUMAN_REPLY, codes(t))

    def test_the_guard_tag_is_an_event_at_the_time_it_was_applied(self):
        t = thread(tags=[rules.GUARD_TAG], tag_at={rules.GUARD_TAG: NOW - 8 * DAY})
        self.assertIn([NOW - 8 * DAY, rules.EV_GUARD], rules.read_events(t))

    def test_facts_hold_no_text(self):
        t = thread(ask="my email is a@b.co and here is my story", subject="secret subject")
        f = rules.thread_facts(t)
        self.assertEqual(set(f), {"id", "created_at", "updated_at", "open", "shape", "outbound", "events", "rules"})
        self.assertNotIn("story", json.dumps(f))


class Metrics(unittest.TestCase):
    def test_every_thread_lands_in_exactly_one_class(self):
        import itertools
        facts = []
        for i, combo in enumerate(itertools.product([0, 1], repeat=len(rules.EVENT_CODES))):
            events = [(60 * (j + 1), code) for j, (on, code) in enumerate(zip(combo, rules.EVENT_CODES)) if on]
            facts.append(fact(i, NOW - 5 * DAY, events))
        m = metrics.measure(facts, NOW - 6 * DAY, NOW, NOW)
        self.assertEqual(sum(m["outcomes"].values()), m["threads"])
        self.assertEqual(m["threads"], len(facts))
        self.assertEqual(sum(r["threads"] for r in m["shapes"].values()), len(facts))

    def test_precedence(self):
        def klass(events):
            return metrics.outcome_class(metrics.state_at(sorted([[t, c] for t, c in events]), 10 ** 12))
        self.assertEqual(klass([(1, "c"), (2, "a"), (2, "p")]), "handoff_no_assignment")
        self.assertEqual(klass([(1, "c"), (2, "a"), (2, "p"), (3, "A")]), "handoff_assigned")
        self.assertEqual(klass([(1, "c"), (3, "A")]), "assigned_silent")
        self.assertEqual(klass([(1, "c"), (2, "a"), (2, "q")]), "queue_line")
        self.assertEqual(klass([(1, "c")]), "never_answered")
        self.assertEqual(klass([(1, "c"), (2, "a"), (2, "r")]), "refused")
        self.assertEqual(klass([(1, "c"), (2, "a")]), "answered")
        self.assertEqual(klass([(1, "c"), (2, "a"), (3, "c")]), "answered_awaiting")
        self.assertEqual(klass([(2, "a")]), "no_customer_message")
        # A refusal that ALSO promises a person is a hand-off: the exemption did not hold.
        self.assertEqual(klass([(1, "c"), (2, "a"), (2, "r"), (2, "p")]), "handoff_no_assignment")

    def test_a_matured_read_ignores_what_happened_after_the_cut(self):
        created = NOW - 10 * DAY
        f = fact(1, created, [(0, "c"), (60, "a"), (60, "p"), (72 * HOUR, "A")])
        matured = metrics.measure([f], created - 1, created + 1, NOW, maturity_hours=48)
        as_of_now = metrics.measure([f], created - 1, created + 1, NOW)
        self.assertEqual(matured["headline"], 1)
        self.assertEqual(as_of_now["headline"], 0)
        self.assertEqual(as_of_now["outcomes"]["handoff_assigned"], 1)

    def test_matured_weeks_are_full_weeks_that_end_at_the_maturity_edge(self):
        weeks = metrics.matured_weeks([], NOW, 48, weeks=3)
        self.assertEqual(weeks[0]["window"]["end"], NOW - 48 * HOUR)
        self.assertEqual(weeks[0]["window"]["start"], weeks[1]["window"]["end"])
        self.assertEqual(weeks[2]["window"]["end"] - weeks[2]["window"]["start"], 7 * DAY)

    def test_unanswered_over_n_hours_leaves_robots_out_and_respects_age(self):
        old = fact(1, NOW - 3 * DAY, [(0, "c")])
        robot = fact(2, NOW - 3 * DAY, [(0, "c")], shape="robot_mail")
        fresh = fact(3, NOW - 2 * HOUR, [(0, "c")])
        m = metrics.measure([old, robot, fresh], NOW - 4 * DAY, NOW, NOW, unanswered_hours=24)
        self.assertEqual(m["outcomes"]["never_answered"], 3)
        self.assertEqual(m["extra"]["never_answered_over_n_hours"], 1)

    def test_a_chase_is_a_customer_message_a_day_after_the_promise_with_no_person_between(self):
        chased = fact(1, NOW - 9 * DAY, [(0, "c"), (60, "a"), (60, "p"), (30 * HOUR, "c")])
        served = fact(2, NOW - 9 * DAY, [(0, "c"), (60, "a"), (60, "p"), (5 * HOUR, "h"), (30 * HOUR, "c")])
        m = metrics.measure([chased, served], NOW - 10 * DAY, NOW, NOW)
        self.assertEqual(m["extra"]["chased_after_promise"], 1)

    def test_guard_forced_hand_offs_are_counted_inside_the_headline(self):
        f = fact(1, NOW - 9 * DAY, [(0, "c"), (60, "a"), (60, "p"), (60, "g")])
        m = metrics.measure([f], NOW - 10 * DAY, NOW, NOW)
        self.assertEqual((m["headline"], m["extra"]["headline_guard_forced"]), (1, 1))


def week(threads, headline, answered=None, extra=None, shapes=None, assigned=0):
    """A measured week with just the fields the alert rules read."""
    answered = threads - headline - assigned if answered is None else answered
    outcomes = {name: 0 for name in metrics.OUTCOME_CLASSES}
    outcomes.update({"handoff_no_assignment": headline, "handoff_assigned": assigned, "answered": answered})
    ex = {"date_promise": 0, "never_answered_over_n_hours": 0, "handoff_assigned_no_human_reply": 0,
          "assigned": assigned, "human_reply": 0}
    ex.update(extra or {})
    return {"window": {"start": 0, "end": 7 * DAY, "maturity_hours": 48, "unanswered_hours": 24},
            "threads": threads, "headline": headline, "handoff": headline + assigned, "outcomes": outcomes, "extra": ex,
            "rates": {"handoff_rate": (headline + assigned) / threads, "handoff_no_assignment_rate": headline / threads,
                      "resolved_without_handoff_rate": answered / threads},
            "shapes": shapes or {"proof_sent": {"threads": threads, "handoff_no_assignment": headline, "answered": answered}}}


REGISTER = fixloop.load_register()


def keys(findings, severity=alerts.PAGE):
    return [f.key for f in findings if f.severity == severity]


class Alerts(unittest.TestCase):
    def reg(self, **page):
        r = copy.deepcopy(REGISTER)
        r["monitor"]["page"].update({"headline_ceiling_per_week": None, "date_promise_max_per_week": 0})
        r["monitor"]["page"].update(page)
        return r

    def test_a_rise_in_the_headline_pages(self):
        got = alerts.evaluate([week(1000, 600), week(1000, 500)], self.reg())
        self.assertIn("headline:rise", keys(got))
        text = next(f.text for f in got if f.key == "headline:rise")
        self.assertIn("600", text)
        self.assertIn("behaviour", text)

    def test_a_rise_that_is_only_volume_says_so(self):
        got = alerts.evaluate([week(1200, 600, answered=600), week(1000, 500, answered=500)], self.reg())
        self.assertIn("volume", next(f.text for f in got if f.key == "headline:rise"))

    def test_a_small_or_flat_move_does_not_page(self):
        self.assertEqual(keys(alerts.evaluate([week(1000, 510), week(1000, 500)], self.reg())), [])
        self.assertEqual(keys(alerts.evaluate([week(1000, 400), week(1000, 500)], self.reg())), [])

    def test_the_ceiling_pages_even_with_no_previous_week(self):
        got = alerts.evaluate([week(1000, 600)], self.reg(headline_ceiling_per_week=550))
        self.assertIn("headline:ceiling", keys(got))

    def test_a_fall_in_resolved_without_hand_off_pages(self):
        got = alerts.evaluate([week(1000, 500, answered=100), week(1000, 500, answered=300)], self.reg())
        self.assertIn("resolved:fall", keys(got))

    def test_a_date_promise_over_the_allowed_count_pages(self):
        got = alerts.evaluate([week(1000, 500, extra={"date_promise": 3}), week(1000, 500)], self.reg())
        self.assertIn("exemption:date_promise", keys(got))

    def test_one_shape_rising_pages_by_name(self):
        def shapes(n):
            return {"proof_sent": {"threads": 800, "handoff_no_assignment": 400, "answered": 0},
                    "artist_link": {"threads": 100, "handoff_no_assignment": n, "answered": 0},
                    "other": {"threads": 100, "handoff_no_assignment": 0, "answered": 0}}
        got = alerts.evaluate([week(1000, 460, shapes=shapes(60)), week(1000, 440, shapes=shapes(40))], self.reg())
        self.assertEqual(keys(got), ["shape:rise:artist_link"])

    def test_assigned_but_never_answered_pages(self):
        cur = week(1000, 500, assigned=200, extra={"handoff_assigned_no_human_reply": 200})
        prev = week(1000, 500, assigned=200, extra={"handoff_assigned_no_human_reply": 40})
        self.assertIn("assigned_no_reply:rise", keys(alerts.evaluate([cur, prev], self.reg())))

    def test_an_unmeasured_week_is_never_a_quiet_week(self):
        got = alerts.evaluate([week(40, 0), week(1000, 500)], self.reg())
        self.assertEqual(keys(got), ["unmeasured:low_volume"])
        got = alerts.evaluate([week(1000, 900), week(1000, 500)], self.reg(), covered=False)
        self.assertNotIn("headline:rise", keys(got))
        self.assertIn("unmeasured:no_previous_week", keys(got, alerts.INFO))

    def test_a_residual_bucket_that_outgrows_its_limit_pages(self):
        shapes = {"other": {"threads": 400, "handoff_no_assignment": 0, "answered": 0},
                  "proof_sent": {"threads": 600, "handoff_no_assignment": 500, "answered": 0}}
        got = alerts.evaluate([week(1000, 500, shapes=shapes), week(1000, 500, shapes=shapes)], self.reg())
        self.assertIn("shapes:residual", keys(got))

    def test_a_fix_that_did_not_work_pages(self):
        verdict = {"shape": "proof_sent", "metric": "handoff_no_assignment", "shipped_at": "2026-11-20",
                   "verdict": "did_not_work", "relative_drop": 0.02, "status": "shipped",
                   "before": {"count": 500, "threads": 600, "rate": 0.83},
                   "after": {"count": 490, "threads": 600, "rate": 0.82}}
        got = alerts.evaluate([week(1000, 500), week(1000, 500)], self.reg(), [verdict])
        self.assertIn("fix:did_not_work:proof_sent", keys(got))

    def test_due_sends_new_repeats_after_the_window_and_escalates_when_worse(self):
        t = alerts.thresholds(self.reg())
        f = alerts.Finding("headline:rise", alerts.PAGE, 600, "x")
        self.assertEqual(alerts.due([f], lambda k: None, NOW, t), [f])
        recent = {"value": 600, "paged_at": NOW - HOUR}
        self.assertEqual(alerts.due([f], lambda k: recent, NOW, t), [])
        self.assertEqual(alerts.due([f._replace(value=700)], lambda k: recent, NOW, t), [f._replace(value=700)])
        old = {"value": 600, "paged_at": NOW - 73 * HOUR}
        self.assertEqual(alerts.due([f], lambda k: old, NOW, t), [f])
        info = alerts.Finding("fix:worked:x", alerts.INFO, 0, "x")
        self.assertEqual(alerts.due([info], lambda k: None, NOW, t), [])

    def test_the_page_leads_with_the_headline_number_and_the_mention(self):
        f = alerts.Finding("headline:rise", alerts.PAGE, 600, "it rose")
        text = alerts.render_page([f], [week(1000, 600), week(1000, 500)], ["U123"])
        first, second = text.split("\n")[:2]
        self.assertIn("<@U123>", first)
        self.assertIn("600", second)
        self.assertIn("500", second)
        self.assertIn("DRILL", alerts.render_page([f], [week(1000, 600)], [], drill=True))


class Register(unittest.TestCase):
    BASELINE = cli.load_baseline()

    def errors(self, mutate):
        r = copy.deepcopy(REGISTER)
        mutate(r)
        return fixloop.validate(r, self.BASELINE)

    def assertRefused(self, mutate, fragment):
        got = self.errors(mutate)
        self.assertTrue(any(fragment in e for e in got), f"expected an error containing {fragment!r}, got {got}")

    def test_the_repo_register_is_valid_against_the_recorded_baseline(self):
        self.assertIsNotNone(self.BASELINE, "data/caroline-monitor/baseline.json is missing")
        self.assertEqual(fixloop.validate(REGISTER, self.BASELINE), [])

    def test_a_conversation_id_or_inbox_link_is_refused(self):
        self.assertRefused(lambda r: r["shapes"]["proof_sent"].update(why="see 215471234567890"), "never threads")
        self.assertRefused(lambda r: r["shapes"]["proof_sent"].update(
            ref="https://app.intercom.com/a/inbox/x/inbox/conversation/5"), "never threads")

    def test_every_classifier_shape_needs_a_row_and_no_row_is_invented(self):
        self.assertRefused(lambda r: r["shapes"].pop("merge_split"), "no register row")
        self.assertRefused(lambda r: r["shapes"].update(vibes=dict(r["shapes"]["other"])), "not a classifier shape")

    def test_a_person_row_must_name_why(self):
        self.assertRefused(lambda r: r["shapes"]["legal_notice"].pop("person_reason"), "person_reason")

    def test_person_shapes_must_stay_rare(self):
        def mutate(r):
            r["shapes"]["proof_sent"].update(fix_type="person", person_reason="because")
        self.assertRefused(mutate, "over the")
        self.assertRefused(lambda r: r["monitor"]["fix_loop"].update(person_share_max=0.5), "has to stay rare")

    def test_only_rule_and_tool_rows_become_automation(self):
        def mutate(r):
            r["shapes"]["declined_why"]["automation"] = "scripts/answer-declined.py"
        self.assertRefused(mutate, "only rule and tool")

    def test_a_refusal_needs_its_reason_and_its_way_back(self):
        self.assertRefused(lambda r: r["shapes"]["declined_why"]["refusal"].pop("reapply_path"), "reapply_path")

    def test_the_four_exemptions_must_all_be_registered_with_a_way_back(self):
        for name in fixloop.REQUIRED_EXEMPTIONS:
            with self.subTest(exemption=name):
                self.assertRefused(lambda r, n=name: r["exemptions"].pop(n), f"exemption {name}: missing")
                self.assertRefused(lambda r, n=name: r["exemptions"][n].pop("reapply_path"), "reapply_path")

    def test_shipped_needs_a_date_and_a_ref(self):
        self.assertRefused(lambda r: r["shapes"]["proof_sent"].update(status="shipped"), "needs `shipped_at`")
        self.assertRefused(lambda r: r["shapes"]["proof_sent"].update(status="shipped", shipped_at="2026-11-20"),
                           "needs `ref`")
        self.assertRefused(lambda r: r["global_fixes"]["same_step_assignment"].update(status="verified"),
                           "needs `shipped_at`")

    def test_only_residual_buckets_may_go_undecided(self):
        self.assertRefused(lambda r: r["shapes"]["merge_split"].update(fix_type="none", status="not_planned"),
                           "only for residual buckets")

    def test_the_page_ceilings_only_come_down(self):
        base = self.BASELINE["matured_weeks"][0]
        self.assertRefused(lambda r: r["monitor"]["page"].update(headline_ceiling_per_week=base["headline"] + 1),
                           "may only come down")
        self.assertRefused(lambda r: r["monitor"]["page"].update(
            date_promise_max_per_week=base["extra"]["date_promise"] + 1), "may only come down")
        self.assertEqual(self.errors(lambda r: r["monitor"]["page"].update(headline_ceiling_per_week=1)), [])

    def test_a_rule_change_makes_the_register_stale(self):
        self.assertRefused(lambda r: r.update(rules_version="2020-01-01.1"), "rules changed")


class Remeasure(unittest.TestCase):
    SHIP = "2026-11-20"
    CFG = REGISTER["monitor"]

    def facts(self, shape_before, shape_after, other_before, other_after, n=40):
        """`x_before` / `x_after` = how many of n threads are handed off with nobody assigned."""
        ship = fixloop.parse_day(self.SHIP)
        out, tid = [], 0
        for shape, before, after in (("proof_sent", shape_before, shape_after), ("other", other_before, other_after)):
            for start, bad in ((ship - 8 * DAY, before), (ship + DAY, after)):
                for i in range(n):
                    tid += 1
                    events = [(0, "c"), (60, "a")] + ([(60, "p")] if i < bad else [])
                    out.append(fact(tid, start + i * 60, events, shape=shape))
        return out

    def verdict(self, facts, now_offset_days=12):
        now = fixloop.parse_day(self.SHIP) + now_offset_days * DAY
        return fixloop.remeasure(facts, "proof_sent", metrics.HEADLINE, self.SHIP, now, self.CFG)

    def test_the_shape_fell_and_the_others_stayed_put(self):
        v = self.verdict(self.facts(36, 8, 20, 20))
        self.assertEqual(v["verdict"], "worked")
        self.assertEqual((v["before"]["count"], v["after"]["count"]), (36, 8))

    def test_a_fix_that_did_not_move_its_own_shape_did_not_work(self):
        self.assertEqual(self.verdict(self.facts(36, 34, 20, 20))["verdict"], "did_not_work")

    def test_a_shape_that_fell_with_everything_else_is_not_credited(self):
        self.assertEqual(self.verdict(self.facts(36, 12, 30, 10))["verdict"], "fell_with_everything")

    def shipped(self, precision):
        register = copy.deepcopy(REGISTER)
        register["shapes"]["proof_sent"].update(status="shipped", shipped_at=self.SHIP, ref="https://example.test/pr/1")
        calibration = {"classifier": {"shapes": {"proof_sent": {"precision": precision, "labelled": 30}}}}
        now = fixloop.parse_day(self.SHIP) + 12 * DAY
        got = fixloop.remeasure_all(self.facts(36, 8, 20, 20), register, now, calibration=calibration)
        return [v for v in got if v.get("shape") == "proof_sent"][0]

    def test_a_shape_the_rules_pick_well_keeps_its_verdict(self):
        v = self.shipped(0.83)
        self.assertEqual((v["verdict"], v["shape_precision"]["precision"]), ("worked", 0.83))

    def test_a_shape_the_rules_pick_wrongly_cannot_prove_its_own_fix(self):
        v = self.shipped(0.25)
        self.assertEqual((v["verdict"], v["measured_as"]), ("unmeasured", "worked"))
        self.assertIn("25%", v["reason"])
        self.assertEqual((v["before"]["count"], v["after"]["count"]), (36, 8))   # the counts are still shown

    def test_before_the_after_window_has_matured_it_is_too_early(self):
        v = self.verdict(self.facts(36, 8, 20, 20), now_offset_days=5)
        self.assertEqual(v["verdict"], "too_early")
        self.assertEqual(v["ready_at"], fixloop.parse_day(self.SHIP) + 9 * DAY)

    def test_thin_or_missing_evidence_is_unmeasured_never_a_pass(self):
        self.assertEqual(self.verdict(self.facts(5, 0, 20, 20, n=6))["verdict"], "unmeasured")
        only_after = [f for f in self.facts(36, 8, 20, 20) if f["created_at"] >= fixloop.parse_day(self.SHIP)]
        self.assertEqual(self.verdict(only_after)["verdict"], "unmeasured")

    def test_an_unshipped_row_is_not_shipped(self):
        v = fixloop.remeasure([], "proof_sent", metrics.HEADLINE, None, NOW, self.CFG)
        self.assertEqual(v["verdict"], "not_shipped")

    def test_the_table_is_one_row_per_shape_and_carries_no_thread(self):
        facts = self.facts(36, 8, 20, 20)
        ship = fixloop.parse_day(self.SHIP)
        table = fixloop.shape_table(REGISTER, metrics.measure(facts, ship, ship + 7 * DAY, ship + 12 * DAY, 48))
        self.assertEqual(sorted(r["shape"] for r in table), sorted(rules.SHAPE_IDS))
        self.assertEqual(table[0]["shape"], "other")
        self.assertFalse(any("id" in r or "threads_list" in r for r in table))


class FakeIntercom:
    """Stands in for `collect.collect`: serves reduced threads, records what it was asked to skip."""

    def __init__(self, threads, total=None, fail=None, errors=None):
        self.threads, self.total, self.fail = threads, total, fail
        self.errors, self.skips, self.since = errors or {}, [], []

    def __call__(self, token, start, end, skip=None, since_ts=None):
        if self.fail:
            raise collect.CollectError(self.fail)
        self.skips.append(dict(skip or {}))
        self.since.append(since_ts)

        def wanted(t):   # the backlog scope: in the window, or open, or touched since `since_ts`
            return (start <= t["created_at"] < end or t.get("open")
                    or (since_ts is not None and t["updated_at"] >= since_ts))

        listed = [{"id": t["id"], "created_at": t["created_at"], "updated_at": t["updated_at"]}
                  for t in self.threads if wanted(t)]
        fetch = [t for t in self.threads if wanted(t) and (skip or {}).get(t["id"]) != t["updated_at"]]
        return {"listed": listed, "total_count": len(listed) if self.total is None else self.total,
                "threads": fetch, "skipped": [r["id"] for r in listed if r["id"] not in {t["id"] for t in fetch}],
                "gone": [], "errors": self.errors}


def inbox(now, bad_now=130, bad_before=80, per_week=150):
    """Two matured weeks of threads; `bad_*` of each get the hand-off line and no assignment."""
    out, tid = [], 0
    edge = now - 48 * HOUR
    for start, bad in ((edge - 7 * DAY, bad_now), (edge - 14 * DAY, bad_before)):
        for i in range(per_week):
            tid += 1
            created = start + 100 + i * 600
            reply = HANDOFF if i < bad else "You can add a credit from your profile page."
            t = thread(tid, created, ask="Any update on my credit request?",
                       parts=[part("comment", "admin", CAROLINE, created + 120, reply)])
            t["updated_at"] = created + 120
            out.append(t)
    return out


class Tick(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.posts = []
        log, cli.log = cli.log, lambda message: None
        self.addCleanup(setattr, cli, "log", log)

    def poster(self, channel, text):
        self.posts.append((channel, text))

    def broken_poster(self, channel, text):
        raise RuntimeError("slack said no")

    def args(self, now=NOW, dry_run=False):
        return types.SimpleNamespace(register=None, state_dir=self.tmp.name, baseline=None, corpus=None,
                                     now=now, dry_run=dry_run, backlog_out=self.backlog_path())

    def backlog_path(self):
        return os.path.join(self.tmp.name, "support-backlog.json")

    def tick(self, intercom, now=NOW, poster=None, dry_run=False):
        with open(os.devnull, "w") as sink:
            stdout, sys.stdout = sys.stdout, sink
            try:
                return cli.cmd_tick(self.args(now, dry_run), poster=poster or self.poster, collector=intercom, token="t")
            finally:
                sys.stdout = stdout

    def store(self):
        return Store.open_default(self.tmp.name)

    # NOW is a Friday 08:00Z: past the weekly line's Monday 08:00Z slot.
    def pages(self):
        return [text for _, text in self.posts if "rotating_light" in text]

    def test_a_regression_pages_once_and_is_not_repeated_while_unchanged(self):
        intercom = FakeIntercom(inbox(NOW))
        self.assertEqual(self.tick(intercom), 0)
        self.assertEqual(len(self.pages()), 1)
        self.assertIn("130 last matured week", self.pages()[0])
        self.assertIn("<@U7RP6HKUZ>", self.pages()[0])
        self.assertEqual(self.posts[0][0], "C0ADV2W76G4")
        self.assertEqual(self.tick(intercom, now=NOW + 6 * HOUR), 0)
        self.assertEqual(len(self.pages()), 1)

    def test_a_page_that_could_not_be_delivered_is_not_stamped_and_goes_again(self):
        intercom = FakeIntercom(inbox(NOW))
        self.assertEqual(self.tick(intercom, poster=self.broken_poster), 1)
        self.assertIsNone(self.store().last_page("headline:rise"))
        self.assertEqual(self.tick(intercom, now=NOW + 6 * HOUR), 0)
        self.assertEqual(len(self.pages()), 1)

    def test_a_healthy_inbox_does_not_page(self):
        self.assertEqual(self.tick(FakeIntercom(inbox(NOW, bad_now=20, bad_before=20))), 0)
        self.assertEqual(self.pages(), [])

    def test_a_finding_that_clears_pages_again_at_once_when_it_returns(self):
        self.tick(FakeIntercom(inbox(NOW)))
        self.tick(FakeIntercom(inbox(NOW + 6 * HOUR, bad_now=20, bad_before=20)), now=NOW + 6 * HOUR)
        self.assertIsNone(self.store().last_page("headline:rise"))
        self.tick(FakeIntercom(inbox(NOW + 12 * HOUR)), now=NOW + 12 * HOUR)
        self.assertEqual(len(self.pages()), 2)

    def test_the_second_tick_fetches_only_what_moved(self):
        intercom = FakeIntercom(inbox(NOW))
        self.tick(intercom)
        self.tick(intercom, now=NOW + 6 * HOUR)
        self.assertEqual(intercom.skips[0], {})
        self.assertEqual(len(intercom.skips[1]), 300)

    def test_one_blind_tick_is_recorded_and_not_paged(self):
        down = FakeIntercom([], fail="Intercom search failed: 503")
        self.assertEqual(self.tick(down), 0)
        self.assertEqual(self.pages(), [])
        self.assertEqual(self.store().readings("blind")[0][1]["consecutive"], 1)

    def test_the_second_blind_tick_in_a_row_pages_once(self):
        down = FakeIntercom([], fail="Intercom search failed: 503")
        self.tick(down)
        self.assertEqual(self.tick(down, now=NOW + 6 * HOUR), 0)
        self.assertEqual(len(self.pages()), 1)
        self.assertIn("BLIND", self.pages()[0])
        self.assertIn("503", self.pages()[0])
        self.assertEqual(self.store().readings("blind")[0][1]["consecutive"], 2)

    def test_a_blind_page_that_could_not_be_delivered_fails_the_run(self):
        def no_blind_page(channel, text):
            if "BLIND" in text:
                raise RuntimeError("slack said no")
            self.posts.append((channel, text))

        down = FakeIntercom([], fail="down")
        self.tick(down)
        self.assertEqual(self.tick(down, now=NOW + 6 * HOUR, poster=no_blind_page), 1)

    def test_a_register_that_will_not_load_fails_the_first_tick(self):
        args = self.args()
        args.register = os.path.join(self.tmp.name, "missing-register.json")
        with open(os.devnull, "w") as sink:
            stdout, sys.stdout = sys.stdout, sink
            try:
                rc = cli.cmd_tick(args, poster=self.poster, collector=FakeIntercom(inbox(NOW)), token="t")
            finally:
                sys.stdout = stdout
        self.assertEqual(rc, 2)

    def test_a_read_with_one_failed_detail_is_not_a_whole_inbox(self):
        intercom = FakeIntercom(inbox(NOW, 20, 20), errors={"1": "detail read failed"})
        self.assertEqual(self.tick(intercom), 0)
        doc = json.load(open(self.backlog_path()))
        self.assertFalse(doc["scope"]["whole_inbox"])
        self.assertEqual(doc["scope"]["read_errors"], 1)
        self.assertIsNone(doc["open"])

    def test_a_short_read_is_blind_not_a_smaller_inbox(self):
        self.assertEqual(self.tick(FakeIntercom(inbox(NOW), total=900)), 0)
        self.assertEqual(self.store().readings("tick"), [])
        self.assertEqual(self.store().readings("blind")[0][1]["consecutive"], 1)

    def test_a_good_tick_resets_the_blind_count(self):
        self.tick(FakeIntercom([], fail="down"))
        self.tick(FakeIntercom(inbox(NOW, 20, 20)), now=NOW + 6 * HOUR)
        self.assertEqual(self.tick(FakeIntercom([], fail="down"), now=NOW + 12 * HOUR), 0)
        self.assertEqual(self.posts and [p for p in self.posts if "BLIND" in p[1]], [])

    def test_the_weekly_line_goes_out_once_per_week(self):
        intercom = FakeIntercom(inbox(NOW, 20, 20))
        self.tick(intercom)
        self.tick(intercom, now=NOW + 6 * HOUR)
        weekly = [text for _, text in self.posts if "bar_chart" in text]
        self.assertEqual(len(weekly), 1)
        self.assertIn("20 last week", weekly[0])
        self.tick(intercom, now=NOW + 7 * DAY)
        self.assertEqual(len([text for _, text in self.posts if "bar_chart" in text]), 2)

    def health(self):
        return [text for _, text in self.posts if "stopwatch" in text]

    def test_every_run_posts_one_health_line_whether_or_not_it_pages(self):
        intercom = FakeIntercom(inbox(NOW, bad_now=20, bad_before=20))
        self.tick(intercom)
        self.tick(intercom, now=NOW + 2 * HOUR)
        self.assertEqual(len(self.health()), 2)
        line = self.health()[0]
        self.assertNotIn("\n", line)
        self.assertNotIn("<@", line)                      # the line never mentions anyone
        self.assertIn("read 300 conversations (300 re-read, 0 errors)", line)
        self.assertIn("hand-offs with nobody assigned 20 of", line)
        self.assertIn("nothing paging", line)
        self.assertIn("(0 re-read", self.health()[1])

    def test_the_health_line_says_what_is_open_and_whether_it_was_paged(self):
        intercom = FakeIntercom(inbox(NOW))
        self.tick(intercom)
        self.tick(intercom, now=NOW + 2 * HOUR)
        self.assertIn("paged just now", self.health()[0])
        self.assertIn("already paged", self.health()[1])
        self.assertIn("130 of", self.health()[0])

    def test_a_blind_run_says_not_measured_and_repeats_no_number(self):
        self.tick(FakeIntercom(inbox(NOW, 20, 20)))
        self.tick(FakeIntercom([], fail="Intercom search failed: 503"), now=NOW + 2 * HOUR)
        line = self.health()[-1]
        self.assertIn("NOT MEASURED (1 run(s) in a row): Intercom read failed: Intercom search failed: 503", line)
        self.assertNotIn("hand-offs", line)

    def test_a_health_line_nobody_received_fails_the_run(self):
        self.assertEqual(self.tick(FakeIntercom(inbox(NOW, 20, 20)), poster=self.broken_poster), 1)

    def test_the_health_line_can_be_switched_off_or_sent_elsewhere(self):
        cfg = {"slack": {"channel": "C1", "health_line": False}}
        self.assertEqual(cli.health_channel(cfg), "")
        self.assertEqual(cli.health_channel({"slack": {"channel": "C1"}}), "C1")
        self.assertEqual(cli.health_channel({"slack": {"channel": "C1", "health_channel": "C2"}}), "C2")

    def test_a_dry_run_posts_and_records_nothing(self):
        self.assertEqual(self.tick(FakeIntercom(inbox(NOW)), dry_run=True), 0)
        self.assertEqual(self.posts, [])
        self.assertEqual(self.store().readings("tick"), [])
        self.assertIsNone(self.store().last_page("headline:rise"))

    def test_the_store_keeps_no_text(self):
        self.tick(FakeIntercom(inbox(NOW)))
        db = sqlite3.connect(os.path.join(self.tmp.name, "monitor.sqlite"))
        columns = [r[1] for r in db.execute("PRAGMA table_info(facts)")]
        self.assertEqual(columns, ["id", "created_at", "updated_at", "open", "rules", "shape", "outbound", "events"])
        dump = "\n".join(str(r) for r in db.execute("SELECT * FROM facts"))
        self.assertNotIn("update on my credit", dump)
        self.assertNotIn("teammate", dump)

    def test_a_drill_goes_down_the_real_path_and_stamps_nothing(self):
        self.tick(FakeIntercom(inbox(NOW, 20, 20)))
        self.posts.clear()
        args = self.args()
        args.offline = True
        self.assertEqual(cli.cmd_drill(args, poster=self.poster), 0)
        self.assertEqual(len(self.posts), 1)
        self.assertIn("DRILL", self.posts[0][1])
        self.assertIsNone(self.store().last_page("drill"))
        self.assertEqual(cli.cmd_drill(args, poster=self.broken_poster), 1)


class Collector(unittest.TestCase):
    def page(self, ids, total, nxt=None):
        return {"total_count": total, "conversations": [{"id": i, "created_at": 100 + i, "updated_at": 500} for i in ids],
                "pages": {"next": {"starting_after": nxt}} if nxt else {}}

    def test_the_search_is_sorted_by_creation_so_live_updates_cannot_hide_a_thread(self):
        bodies = []

        def request(method, path, token, body=None):
            bodies.append(body)
            return self.page([1, 2], 2)
        rows, total = collect.search_created_between("t", 0, 10 ** 9, request=request)
        self.assertEqual(bodies[0]["sort"], {"field": "created_at", "order": "ascending"})
        self.assertEqual((len(rows), total, len(bodies)), (2, 2, 1))

    def test_a_short_pass_is_repeated_and_merged(self):
        passes = iter([self.page([1, 2], 3), self.page([2, 3], 3)])
        rows, total = collect.search_created_between("t", 0, 10 ** 9, request=lambda *a, **k: next(passes))
        self.assertEqual(sorted(r["id"] for r in rows), ["1", "2", "3"])

    def test_a_read_that_stays_short_reports_intercoms_own_count(self):
        rows, total = collect.search_created_between("t", 0, 10 ** 9, request=lambda *a, **k: self.page([1], 5))
        self.assertEqual((len(rows), total), (1, 5))
        with self.assertRaises(cli.Blind):
            cli.check_coverage(100, 200, 0, {})
        with self.assertRaises(cli.Blind):
            cli.check_coverage(100, 100, 10, {})
        cli.check_coverage(1000, 1003, 5, {})

    def test_emails_and_phone_numbers_never_leave_the_collector(self):
        masked = collect.mask("write me at jo@example.com or +1 (415) 555-0100 <b>now</b>")
        self.assertNotIn("example.com", masked)
        self.assertNotIn("555", masked)
        self.assertNotIn("<b>", masked)


class Calibration(unittest.TestCase):
    RECORD_PATH = os.path.join(REPO, "data", "caroline-monitor", "calibration.json")

    def test_wilson_interval(self):
        self.assertEqual(calibrate.wilson(0, 0), (None, None))
        lo, hi = calibrate.wilson(33, 40)
        self.assertTrue(0.67 < lo < 0.70 and 0.91 < hi < 0.93, (lo, hi))

    def test_the_corrected_size_projects_each_stratum_onto_its_population(self):
        key = [{"n": i, "predicted": "proof_sent"} for i in range(1, 11)] + \
              [{"n": i, "predicted": "other"} for i in range(11, 21)]
        labels = {i: "proof_sent" for i in range(1, 9)}
        labels.update({9: "request_status", 10: "request_status"})
        labels.update({i: "other" for i in range(11, 16)})
        labels.update({i: "proof_sent" for i in range(16, 21)})
        got = calibrate.score_shapes(key, labels, {"proof_sent": 1000, "other": 200})
        self.assertEqual(got["shapes"]["proof_sent"]["precision"], 0.8)
        self.assertEqual(got["shapes"]["proof_sent"]["mistaken_for"], {"request_status": 2})
        self.assertEqual(got["shapes"]["proof_sent"]["estimated_true_threads"], 900)
        self.assertEqual(got["shapes"]["request_status"]["estimated_true_threads"], 200)
        self.assertEqual(got["labelled"], 20)

    def test_the_sample_sheet_hides_the_predicted_shape(self):
        threads = [thread(i, ask="I want to cancel my subscription") for i in range(30)]
        sheet, key, populations = calibrate.sample_shapes(threads, seed=1)
        self.assertEqual(populations, {"cancel_subscription": 30})
        self.assertEqual(set(sheet[0]), {"n", "ask"})
        self.assertNotIn("cancel_subscription", json.dumps(sheet))
        self.assertEqual(sheet, calibrate.sample_shapes(threads, seed=1)[0])

    def test_the_recorded_calibration_is_for_the_current_rules_and_holds_no_text(self):
        with open(self.RECORD_PATH) as f:
            record = json.load(f)
        self.assertEqual(record["rules_version"], rules.RULES_VERSION,
                         "the rules changed after the last hand labels: re-label, or the precision on file is fiction")
        self.assertGreaterEqual(record["classifier"]["labelled"], 250)
        self.assertGreaterEqual(record["outcome_reader"]["headline"]["labelled"], 50)
        self.assertNotRegex(json.dumps(record), r"\b\d{13,}\b")


class Baseline(unittest.TestCase):
    def test_a_corpus_with_no_matured_week_is_refused_before_anything_is_written(self):
        now = 1_800_000_000
        with tempfile.TemporaryDirectory() as tmp:
            corpus = os.path.join(tmp, "corpus.jsonl")
            out = os.path.join(tmp, "baseline.json")
            with open(corpus, "w") as f:
                f.write(json.dumps({"_meta": {"start": now - DAY, "end": now, "listed": 1,
                                                "total_count": 1, "errors": 0}}) + "\n")
            with open(out, "w") as f:
                f.write("previous baseline\n")
            args = types.SimpleNamespace(register=None, corpus=corpus, now=None, out=out)
            with open(os.devnull, "w") as sink:
                stdout, sys.stdout = sys.stdout, sink
                try:
                    rc = cli.cmd_baseline(args)
                finally:
                    sys.stdout = stdout
            self.assertNotEqual(rc, 0)
            with open(out) as f:
                self.assertEqual(f.read(), "previous baseline\n")
    def test_a_separate_inbox_read_is_built_and_stamped_as_of_its_own_cut_off(self):
        register = fixloop.load_register(None)
        now = 1_800_000_000
        threads = [thread("1"), thread("2", created=now - 2 * DAY)]
        meta = {"start": now - 40 * DAY, "end": now, "listed": 2, "total_count": 2, "errors": 0}
        inbox_now = now + 3 * DAY
        inbox_meta = {"start": inbox_now - 37 * DAY, "end": inbox_now, "listed": 2, "total_count": 2,
                      "errors": 0, "backlog": True}
        inbox_threads = [thread("1", created=inbox_now - 20 * DAY), thread("3", created=inbox_now - DAY)]
        plain = cli.build_baseline(threads, meta, register, now)
        read = cli.build_baseline(threads, meta, register, now, inbox_read=(inbox_meta, inbox_threads))
        self.assertEqual(read["inbox"]["written_at"], inbox_now)
        self.assertEqual(read["inbox"]["scope"]["as_of"], inbox_now)
        self.assertEqual(read["inbox_read_at"], inbox_now)
        self.assertEqual(read["inbox_read_at_utc"], cli.utc(inbox_now))
        self.assertEqual(read["inbox"]["open"], 2)
        self.assertEqual(read["inbox_source"]["read"], len(inbox_threads))
        self.assertEqual(read["taken_at"], now)
        self.assertEqual(read["matured_weeks"], plain["matured_weeks"])
        self.assertEqual(read["last30_as_of_now"], plain["last30_as_of_now"])

    def test_without_a_separate_read_the_inbox_block_is_as_of_the_baseline_time(self):
        register = fixloop.load_register(None)
        now = 1_800_000_000
        threads = [thread("1")]
        meta = {"start": now - 40 * DAY, "end": now, "listed": 1, "total_count": 1, "errors": 0}
        read = cli.build_baseline(threads, meta, register, now)
        self.assertEqual(read["inbox_read_at"], now)
        self.assertEqual(read["inbox_read_at_utc"], read["taken_at_utc"])
        self.assertEqual(read["inbox"]["written_at"], now)

    def test_an_inbox_read_that_is_not_the_whole_inbox_is_refused_before_anything_is_written(self):
        now = 1_800_000_000
        with tempfile.TemporaryDirectory() as tmp:
            corpus = os.path.join(tmp, "corpus.jsonl")
            inbox = os.path.join(tmp, "inbox.jsonl")
            out = os.path.join(tmp, "baseline.json")
            with open(corpus, "w") as f:
                f.write(json.dumps({"_meta": {"start": now - 40 * DAY, "end": now, "listed": 1,
                                                "total_count": 1, "errors": 0}}) + "\n")
                f.write(json.dumps(thread("1")) + "\n")
            with open(inbox, "w") as f:
                f.write(json.dumps({"_meta": {"start": now - 40 * DAY, "end": now, "listed": 1,
                                                "total_count": 1, "errors": 0}}) + "\n")
                f.write(json.dumps(thread("1")) + "\n")
            with open(out, "w") as f:
                f.write("previous baseline\n")
            args = types.SimpleNamespace(register=None, corpus=corpus, now=now, out=out, inbox_corpus=inbox)
            with open(os.devnull, "w") as sink:
                stderr, sys.stderr = sys.stderr, sink
                try:
                    rc = cli.cmd_baseline(args)
                finally:
                    sys.stderr = stderr
            self.assertNotEqual(rc, 0)
            with open(out) as f:
                self.assertEqual(f.read(), "previous baseline\n")

    def test_the_record_on_file_stamps_the_inbox_block_with_its_own_read(self):
        with open(os.path.join(REPO, "data", "caroline-monitor", "baseline.json")) as f:
            record = json.load(f)
        self.assertEqual(record["inbox"]["written_at"], record["inbox_read_at"])
        self.assertEqual(record["inbox"]["scope"]["as_of"], record["inbox_read_at"])
        self.assertEqual(record["inbox_source"]["read"], record["inbox_source"]["listed"])


if __name__ == "__main__":
    unittest.main()
