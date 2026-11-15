#!/usr/bin/env python3
"""caroline_coach: the struggle signals, the reading and the line that reports it.

The signals are tested on threads shaped like the ones Intercom returns (the reduced record of
`caroline_monitor.collect.reduce_thread`). The one real sentence here is Caroline's reply of 2026-11-14 15:37Z to a
mastering engineer who had written for weeks; nothing else is a customer's words.
"""
from __future__ import annotations

import io
import json
import os
import sqlite3
import sys
import tempfile
import unittest
import urllib.error
from contextlib import redirect_stdout
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))

import caroline_coach as coach  # noqa: E402
from caroline_monitor import rules  # noqa: E402

NOW = 1_794_700_000
CAROLINE = rules.CAROLINE_ADMIN_ID
PERSON = "7654321"
CANT_SAY_WHEN = "I haven't received a human response about your request, and I can't tell you when one will come."
ASK = "My mastering credit on the album still shows as pending and I uploaded the proof two weeks ago"


def part(ago_min, who, body, kind="comment", asg=None):
    author = {"c": ("user", ""), "a": ("admin", CAROLINE), "h": ("admin", PERSON), "bot": ("bot", "4359478")}[who]
    return {"t": kind, "at": author[0], "aid": author[1], "ts": NOW - ago_min * 60, "body": body, "att": 0, "asg": asg}


def thread(parts, cid="100", first=ASK, first_ago=600, tags=(), tag_at=None, admin_assignee=""):
    return {"id": cid, "created_at": NOW - first_ago * 60, "updated_at": NOW - 60, "state": "open", "open": True,
            "admin_assignee_id": admin_assignee, "team_assignee_id": "", "tags": list(tags), "tag_at": tag_at or {},
            "source": {"type": "conversation", "delivered_as": "customer_initiated", "at": "user", "aid": "",
                       "subject": "", "body": first, "att": 0},
            "parts": parts, "parts_total": len(parts), "contact": "h", "contact_id": "c1", "first_admin_reply_at": 0}


def found(t, now=NOW):
    return coach.signals_of(t, rules.read_events(t), now)


class SignalTests(unittest.TestCase):
    def test_every_signal_has_a_description_and_the_unmeasured_ones_are_named(self):
        self.assertEqual(sorted(coach.SIGNALS), sorted([
            "repeat_ask", "frustration", "asks_human", "caroline_loop", "caroline_cannot", "promise_unbacked",
            "guard_fallback", "customer_unanswered"]))
        self.assertEqual(sorted(coach.NOT_MEASURED), ["account_mismatch", "tool_error"])
        self.assertFalse(set(coach.SIGNALS) & set(coach.NOT_MEASURED))

    def test_the_reply_of_2026_11_14_is_read_as_caroline_saying_she_cannot(self):
        t = thread([part(30, "a", CANT_SAY_WHEN)])
        self.assertIn("caroline_cannot", found(t))
        self.assertNotIn("caroline_cannot", found(thread([part(30, "a", "Your credit was approved today.")])))

    def test_what_she_cannot_do_is_sorted_into_kinds_from_her_own_sentences(self):
        # Caroline's own lines from the first reading (2026-11-15T02:40Z); no customer's words.
        said = {
            CANT_SAY_WHEN: "when",
            "I can't give you a date for when the credit will appear.": "when",
            "I can't speed it up from here, and I don't want to promise a faster outcome.": "when",
            "I can't tell whether the photos are enough to confirm the credit.": "proof_enough",
            "A document is on file for your requests; I can't say whether it's sufficient.": "proof_enough",
            "I can't see the claim review, so I can't tell you why it's taking longer.": "status",
            "I can't confirm that the page has been hidden or the credit removed.": "status",
            "I can't help with delivery failures for emails sent to other organizations.": "mail_bounce",
            "I can see that you sent a GIF, but I can't see what it shows.": "other",
        }
        for sentence, kind in said.items():
            self.assertEqual(coach.cannot_kinds(thread([part(10, "a", sentence)])), [kind], sentence)
        both = thread([part(20, "a", "I can't give you a response time. I can't say whether it's sufficient."),
                       part(10, "a", "Your credit is approved.")])
        self.assertEqual(coach.cannot_kinds(both), ["proof_enough", "when"])
        self.assertEqual(coach.cannot_kinds(both, since=NOW - 15 * 60), [])       # only replies at or after `since`
        self.assertEqual(coach.cannot_kinds(thread([part(10, "c", "I can't tell you when I sent it")])), [])

    def test_a_repeat_counts_only_after_we_answered_the_first_one(self):
        again = "My mastering credit on the album still shows pending, I uploaded the proof two weeks ago already"
        answered = thread([part(500, "a", "Thanks, we are checking your request."), part(20, "c", again)])
        self.assertEqual(found(answered)["repeat_ask"], NOW - 20 * 60)
        # two messages in a row with no reply between them are one ask sent twice, not a repeat after an answer
        self.assertNotIn("repeat_ask", found(thread([part(590, "c", again)])))
        # a different ask is not a repeat
        other = thread([part(500, "a", "Thanks."), part(20, "c", "How do I change the email address on my account please")])
        self.assertNotIn("repeat_ask", found(other))
        # short messages are never compared
        short = thread([part(500, "a", "Thanks."), part(20, "c", "any update?"), part(15, "a", "Not yet."),
                        part(5, "c", "any update?")], first="any update?")
        self.assertNotIn("repeat_ask", found(short))

    def test_quoted_mail_history_does_not_make_a_reply_a_repeat(self):
        quoted = "Thanks!\n\nOn Mon, 3 Nov 2026 at 10:00, Muso Support wrote:\n> " + ASK
        t = thread([part(500, "a", "Thanks, we are checking your request."), part(20, "c", quoted)])
        self.assertNotIn("repeat_ask", found(t))

    def test_frustration_and_asking_for_a_person_are_read_from_the_customer_only(self):
        t = thread([part(400, "a", "We are checking."), part(10, "c", "This is the third time I am asking. Can I talk to a human?")])
        got = found(t)
        self.assertIn("frustration", got)
        self.assertIn("asks_human", got)
        ours = thread([part(10, "a", "I know it has been weeks. A human is not needed for this: your credit is approved.")],
                      first="Hello, question about my profile")
        self.assertNotIn("frustration", found(ours))
        self.assertNotIn("asks_human", found(ours))

    def test_the_same_reply_twice_is_a_loop_and_two_different_replies_are_not(self):
        line = "To verify this credit, please send a link to the release page that lists you in that role."
        loop = thread([part(300, "a", line), part(200, "c", "I did send it"), part(100, "a", line)])
        self.assertEqual(found(loop)["caroline_loop"], NOW - 100 * 60)
        fine = thread([part(300, "a", line), part(200, "c", "I did send it"),
                       part(100, "a", "Got it, thank you. Your credit is approved and shows on your profile now.")])
        self.assertNotIn("caroline_loop", found(fine))

    def test_a_promise_is_unbacked_until_a_person_is_assigned_after_it(self):
        promise = "I've flagged your request for our team and they will follow up here."
        self.assertIn("promise_unbacked", found(thread([part(60, "a", promise)])))
        backed = thread([part(60, "a", promise),
                         part(50, "bot", "", kind="assignment", asg={"type": "admin", "id": PERSON})])
        self.assertNotIn("promise_unbacked", found(backed))
        # an assignment to Caroline herself is not a person
        own = thread([part(60, "a", promise), part(50, "bot", "", kind="assignment", asg={"type": "admin", "id": CAROLINE})])
        self.assertIn("promise_unbacked", found(own))

    def test_a_promise_made_while_a_person_already_holds_the_thread_is_backed(self):
        promise = "I've flagged your request for our team and they will follow up here."
        before = [part(90, "bot", "", kind="assignment", asg={"type": "admin", "id": PERSON}), part(60, "a", promise)]
        # assigned BEFORE she said it and still holding it: a person is on the thread
        self.assertNotIn("promise_unbacked", found(thread(before, admin_assignee=PERSON)))
        # assigned before, and the thread is Caroline's again by the time she says it: nobody is
        back = before[:1] + [part(80, "bot", "", kind="assignment", asg={"type": "admin", "id": CAROLINE})] + before[1:]
        self.assertIn("promise_unbacked", found(thread(back, admin_assignee=CAROLINE)))
        self.assertIn("promise_unbacked", found(thread(back)))
        # a team counts only when the register lists it as staffed
        team = thread([part(60, "a", promise)])
        team["team_assignee_id"] = "777"
        ev = rules.read_events(team)
        self.assertIn("promise_unbacked", coach.signals_of(team, ev, NOW))
        staffed = rules.read_events(team, rules.DEFAULT_NON_HUMAN_ADMINS, ("777",))
        self.assertNotIn("promise_unbacked",
                         coach.signals_of(team, staffed, NOW, rules.DEFAULT_NON_HUMAN_ADMINS, ("777",)))
        for holder, is_person in ((PERSON, True), (CAROLINE, False), (rules.OPERATOR_BOT_ID, False), ("", False),
                                  ("0", False), ("None", False), (None, False)):
            self.assertEqual(coach.held_by_a_person(thread([], admin_assignee=holder)), is_person, holder)
        # a customer source, tags or parts on the thread never read as a holder
        busy = thread([part(5, "c", ASK), part(4, "a", promise)], tags=[rules.GUARD_TAG])
        self.assertFalse(coach.held_by_a_person(busy))

    def test_the_guard_tag_is_a_signal_dated_when_it_was_applied(self):
        t = thread([part(60, "a", "Thanks for your message.")], tags=[rules.GUARD_TAG], tag_at={rules.GUARD_TAG: NOW - 3000})
        self.assertEqual(found(t)["guard_fallback"], NOW - 3000)

    def test_customer_unanswered_needs_the_customer_last_and_the_wait(self):
        waiting = thread([part(400, "a", "We are checking."), part(40, "c", "Is there any news on this one please")])
        self.assertEqual(found(waiting)["customer_unanswered"], NOW - 40 * 60)
        fresh = thread([part(400, "a", "We are checking."), part(5, "c", "Is there any news on this one please")])
        self.assertNotIn("customer_unanswered", found(fresh))
        answered = thread([part(40, "c", "Is there any news"), part(39, "a", "Yes: it was approved.")])
        self.assertNotIn("customer_unanswered", found(answered))

    def test_the_message_walk_agrees_with_the_monitors_own_reading_of_what_a_message_is(self):
        t = thread([part(500, "a", "One"), part(400, "c", "Two"), part(300, "h", "Three"),
                    part(250, "h", "an internal note", kind="note"), part(240, "bot", "Typically replies in a day"),
                    part(200, "c", "", kind="comment"), part(150, "a", "", kind="close"), part(100, "a", "Four", kind="open")])
        mine = sorted((ts, who) for ts, who, _ in coach.messages(t))
        theirs = sorted((ts, code) for ts, code in rules.read_events(t)
                        if code in (rules.EV_CUSTOMER, rules.EV_CAROLINE, rules.EV_HUMAN_REPLY))
        self.assertEqual(mine, theirs)
        self.assertEqual([w for _, w in mine], ["c", "a", "c", "h", "a"])


class Intercom:
    """A fake Intercom: one search page, then one GET per id. Records every call it was asked to make."""

    def __init__(self, threads, total=None, fail=()):
        self.threads, self.total, self.fail, self.calls = {t["id"]: t for t in threads}, total, set(fail), []

    def __call__(self, method, path, token, body=None, **_):
        self.calls.append((method, path))
        if method == "POST" and path == "/conversations/search":
            return {"total_count": len(self.threads) if self.total is None else self.total, "pages": {},
                    "conversations": [{"id": t["id"], "created_at": t["created_at"], "updated_at": t["updated_at"],
                                       "open": True} for t in self.threads.values()]}
        cid = path.split("/")[2].split("?")[0]
        if cid in self.fail:
            raise urllib.error.HTTPError(path, 500, "boom", {}, None)
        return {"__reduced__": self.threads[cid]}


def facts_db(tmp, rows, taken=NOW - 1800):
    path = os.path.join(tmp, "monitor.sqlite")
    db = sqlite3.connect(path)
    db.execute("CREATE TABLE facts (id TEXT PRIMARY KEY, created_at INTEGER, updated_at INTEGER, open INTEGER, "
               "rules TEXT, shape TEXT, outbound INTEGER, events TEXT)")
    db.execute("CREATE TABLE readings (taken_at INTEGER, kind TEXT, payload TEXT)")
    for cid, events, is_open, *shape in rows:
        db.execute("INSERT INTO facts VALUES (?,?,?,?,?,?,?,?)",
                   (cid, 0, 0, is_open, "r", shape[0] if shape else "other", 0, json.dumps(events)))
    if taken:
        db.execute("INSERT INTO readings VALUES (?,?,?)", (taken, "week", "{}"))
    db.commit()
    db.close()
    return path


class TickTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        # the fake returns reduced records directly: reduce_thread is the collector's, tested there
        patch = mock.patch.object(coach.collect, "reduce_thread", lambda detail: detail["__reduced__"])
        patch.start()
        self.addCleanup(patch.stop)

    def tick(self, threads, rows=(), **kw):
        api = Intercom(threads, **{k: kw.pop(k) for k in ("total", "fail") if k in kw})
        db = kw.pop("db", None) or facts_db(self.tmp, rows)
        return coach.tick("tok", NOW, 30, db, request=api), api

    def test_a_tick_reads_every_touched_thread_and_counts_each_signal_once_per_thread(self):
        cannot = thread([part(10, "a", CANT_SAY_WHEN),
                         part(8, "a", "I don't have access to billing records from here.")], cid="1")
        fine = thread([part(10, "a", "Your credit is approved.")], cid="2")
        doc, api = self.tick([cannot, fine])
        w = doc["window"]
        self.assertEqual((w["listed"], w["read"], w["read_errors"], w["short_read"], w["struggling"]), (2, 2, 0, False, 1))
        self.assertEqual(w["by_signal"]["caroline_cannot"], 1)
        self.assertEqual([c["signals"] for c in w["conversations"]], [["caroline_cannot"], []])
        self.assertEqual(sorted(m for m, _ in api.calls), ["GET", "GET", "POST"])     # read-only verbs, one GET each

    def test_a_signal_older_than_the_window_is_not_counted_for_a_touched_thread(self):
        old = thread([part(600, "a", CANT_SAY_WHEN), part(5, "a", "Your credit is approved.")], cid="1")
        doc, _ = self.tick([old])
        self.assertEqual(doc["window"]["by_signal"]["caroline_cannot"], 0)
        self.assertEqual(doc["window"]["struggling"], 0)

    def test_the_output_carries_ids_and_signal_names_and_no_message_text(self):
        t = thread([part(10, "c", "This is ridiculous, nobody is replying to my requests at all"),
                    part(5, "a", CANT_SAY_WHEN)], cid="1")
        doc, _ = self.tick([t])
        text = json.dumps(doc)
        for words in ("ridiculous", "human response", "mastering credit"):
            self.assertNotIn(words, text)
        self.assertEqual(set(doc["window"]["conversations"][0]), {"id", "shape", "last", "signals", "cannot", "outbound"})
        self.assertEqual(doc["window"]["conversations"][0]["cannot"], ["when"])
        self.assertEqual(doc["window"]["by_cannot"], {"when": 1})

    def test_a_failed_read_and_a_short_listing_are_reported_and_never_counted_as_quiet(self):
        a, b = thread([part(5, "a", "Approved.")], cid="1"), thread([part(5, "a", "Approved.")], cid="2")
        doc, _ = self.tick([a, b], fail={"2"}, total=5)
        self.assertEqual((doc["window"]["read"], doc["window"]["read_errors"], doc["window"]["short_read"]), (1, 1, True))
        self.assertIn("SHORT READ", coach.line(doc))
        self.assertIn("1 read errors", coach.line(doc))

    def test_aging_is_counted_from_the_monitors_facts_and_the_young_ones_are_read(self):
        c = rules.EV_CUSTOMER
        rows = [("old", [[NOW - 200 * 86400, c]], 1),                      # waiting 200 days: counted, not read
                ("week", [[NOW - 3 * 86400, c]], 1),                       # waiting 3 days: counted and read
                ("fresh", [[NOW - 3600, c]], 1),                           # waiting 1 hour: not aging
                ("ours", [[NOW - 9 * 86400, c], [NOW - 8 * 86400, rules.EV_CAROLINE]], 1),   # we spoke last
                ("bounce", [[NOW - 3 * 86400, c]], 1, coach.ROBOT_MAIL),   # a bounce: counted apart, never read
                ("closed", [[NOW - 9 * 86400, c]], 0)]
        aged = thread([part(10, "a", "x")], cid="week", first="Nobody is replying to my support requests, still waiting",
                      first_ago=3 * 1440)
        aged["parts"] = []
        doc, api = self.tick([aged], rows)
        a = doc["aging"]
        self.assertEqual((a["count"], a["robot_mail"], a["by_wait"], a["facts_age_min"]),
                         (2, 1, {"over_90d": 1, "2d_to_7d": 1}, 30))
        self.assertEqual((a["read"], a["answered_since"]), (1, 0))    # "week" was touched too: fetched once, read in both
        self.assertEqual(len([1 for m, p in api.calls if m == "GET"]), 1)
        self.assertIn("customer last over 24h: 2 plus 1 robot mail (monitor's reading, 30 min old)", coach.line(doc))

    def test_an_aging_thread_outside_the_window_is_fetched_and_its_whole_history_is_read(self):
        c = rules.EV_CUSTOMER
        aged = thread([], cid="week", first="Nobody is replying to my support requests, I am still waiting",
                      first_ago=3 * 1440)
        api = Intercom([aged])
        search = api.__call__

        def request(method, path, token, body=None, **kw):
            if method == "POST":
                api.calls.append((method, path))
                return {"total_count": 0, "pages": {}, "conversations": []}
            return search(method, path, token, body, **kw)

        doc = coach.tick("tok", NOW, 30, facts_db(self.tmp, [("week", [[NOW - 3 * 86400, c]], 1)]), request=request)
        self.assertEqual(doc["window"]["listed"], 0)
        self.assertEqual(doc["aging"]["read"], 1)
        self.assertEqual(doc["aging"]["conversations"][0]["signals"], ["customer_unanswered", "frustration"])

    def test_a_thread_in_both_sets_is_fetched_once_and_read_whole_for_the_wait(self):
        """The customer wrote two days ago and something touched the thread five minutes ago. The window counts
        only what happened in the window; the waiting set still reads the whole history."""
        c = rules.EV_CUSTOMER
        both = thread([part(5, "bot", "", kind="assignment", asg={"type": "admin", "id": CAROLINE})], cid="both",
                      first="Nobody is replying to my support requests, I am still waiting", first_ago=2 * 1440)
        doc, api = self.tick([both], [("both", [[NOW - 2 * 86400, c]], 1)])
        w, a = doc["window"], doc["aging"]
        self.assertEqual(len([1 for m, p in api.calls if m == "GET"]), 1)
        self.assertEqual([r["signals"] for r in w["conversations"]], [["customer_unanswered"]])
        self.assertEqual(w["by_signal"]["frustration"], 0)
        self.assertEqual((a["under_read_days"], a["read"], a["answered_since"]), (1, 1, 0))
        self.assertEqual([r["signals"] for r in a["conversations"]], [["customer_unanswered", "frustration"]])
        self.assertEqual((a["by_signal"]["frustration"], a["by_signal"]["customer_unanswered"]), (1, 1))
        # one thread, so one per signal in the cross-table, though it sits in both sets
        self.assertEqual({k: sum(v.values()) for k, v in doc["by_signal_shape"].items()},
                         {"customer_unanswered": 1, "frustration": 1})
        self.assertEqual(set(w["conversations"][0]), set(a["conversations"][0]))
        self.assertNotIn("waiting", a["conversations"][0])

    def test_a_listed_wait_that_was_answered_since_the_monitors_reading_is_counted_apart(self):
        c = rules.EV_CUSTOMER
        answered = thread([part(5, "a", "Your credit was approved today.")], cid="done",
                          first="Nobody is replying to my support requests, I am still waiting", first_ago=2 * 1440)
        doc, _ = self.tick([answered], [("done", [[NOW - 2 * 86400, c]], 1)])
        a = doc["aging"]
        self.assertEqual((a["under_read_days"], a["read"], a["answered_since"], a["conversations"]), (1, 1, 1, []))
        self.assertEqual(sum(a["by_signal"].values()), 0)
        self.assertIn("1 of them under 7 days read, 1 answered since that reading: none", coach.line(doc))
        self.assertEqual(doc["by_signal_shape"], {})

    def test_past_the_read_limit_the_reading_says_it_is_partial_and_how_many_it_left(self):
        c = rules.EV_CUSTOMER
        n = coach.AGING_READ_CAP + 2
        # waits of 2 days plus i minutes: the two shortest waits are the ones left unread
        rows = [(str(1000 + i), [[NOW - 2 * 86400 - i * 60, c]], 1) for i in range(n)]
        threads = [thread([], cid=str(1000 + i), first="Is there an update on my claim please", first_ago=2 * 1440 + i)
                   for i in range(n)]
        api = Intercom(threads)

        def request(method, path, token, body=None, **kw):
            if method == "POST":
                return {"total_count": 0, "pages": {}, "conversations": []}
            return api(method, path, token, body, **kw)

        doc = coach.tick("tok", NOW, 30, facts_db(self.tmp, rows), request=request)
        a = doc["aging"]
        self.assertEqual((a["count"], a["under_read_days"], a["read"], a["read_limit"], a["not_read_over_limit"]),
                         (n, n, coach.AGING_READ_CAP, coach.AGING_READ_CAP, 2))
        self.assertEqual(sorted(set(str(1000 + i) for i in range(n)) - {r["id"] for r in a["conversations"]}),
                         ["1000", "1001"])
        self.assertIn(f"{coach.AGING_READ_CAP} of them under 7 days read (PARTIAL: 2 more under 7 days not read, "
                      f"limit {coach.AGING_READ_CAP} a tick):", coach.line(doc))
        self.assertNotIn("read_ids", a)
        # at the limit exactly, nothing is left and the line does not say partial
        full = coach.tick("tok", NOW, 30, facts_db(tempfile.mkdtemp(), rows[2:]), request=request)
        self.assertEqual((full["aging"]["read"], full["aging"]["not_read_over_limit"]), (coach.AGING_READ_CAP, 0))
        self.assertNotIn("PARTIAL", coach.line(full))

    def test_facts_that_cannot_be_read_are_not_measured_and_never_zero(self):
        doc, _ = self.tick([], db=os.path.join(self.tmp, "absent.sqlite"))
        self.assertIn("not_measured", doc["aging"])
        self.assertNotIn("count", doc["aging"])
        self.assertIn("aging over 24h: NOT MEASURED", coach.line(doc))
        empty, _ = self.tick([], db=facts_db(tempfile.mkdtemp(), [], taken=0))
        self.assertEqual(empty["aging"], {"not_measured": "the monitor has recorded no reading"})

    def test_a_reading_that_could_not_run_prints_not_measured_and_exits_2(self):
        out = io.StringIO()
        with mock.patch.object(coach.collect, "resolve_token", lambda: "tok"), \
                mock.patch.object(coach, "tick", side_effect=coach.collect.CollectError("search failed")), \
                mock.patch.object(coach.fixloop, "load_register", lambda: {}), redirect_stdout(out):
            rc = coach.main(["tick"])
        doc = json.loads(out.getvalue())
        self.assertEqual(rc, 2)
        self.assertNotIn("window", doc)
        self.assertEqual(coach.line(doc), "NOT MEASURED: CollectError: search failed")
        with mock.patch.object(coach.collect, "resolve_token", lambda: ""), redirect_stdout(io.StringIO()) as out2:
            self.assertEqual(coach.main(["tick"]), 2)
        self.assertIn("no Intercom token", out2.getvalue())

    def test_a_search_intercom_did_not_answer_is_a_read_failure(self):
        def request(method, path, token, body=None, **kw):
            raise urllib.error.HTTPError(path, 503, "unavailable", {}, None)

        with self.assertRaises(coach.collect.CollectError) as caught:
            coach.tick("tok", NOW, 30, facts_db(self.tmp, []), request=request)
        self.assertIn("Intercom search failed", str(caught.exception))

    def test_a_fault_in_the_reader_is_not_a_reading_it_fails_the_run_and_leaves_no_older_count(self):
        """Exit 2 is a success for the unit, so only "could not read Intercom" may use it. A record the code did
        not expect, or a bug, must fail the run: otherwise every tick can be broken and nothing pages."""
        out_dir = os.path.join(self.tmp, "out")
        good = {"schema": coach.SCHEMA, "window": {"read": 7}}
        with mock.patch.object(coach.collect, "resolve_token", lambda: "tok"), \
                mock.patch.object(coach.fixloop, "load_register", lambda: {}), redirect_stdout(io.StringIO()):
            with mock.patch.object(coach, "tick", return_value=good):
                self.assertEqual(coach.main(["tick", "--out", out_dir]), 0)
            for fault in (TypeError("unhashable type: 'list'"), ValueError("bad part"), KeyError("parts"),
                          OSError("disk")):
                with mock.patch.object(coach, "tick", side_effect=fault), self.assertRaises(type(fault)):
                    coach.main(["tick", "--out", out_dir])
                latest = json.loads(Path(out_dir, "latest.json").read_text())
                self.assertNotIn("window", latest)
                self.assertTrue(latest["not_measured_reason"].startswith(f"reader fault: {type(fault).__name__}"))
        # a thread whose parts are not what the rules expect reaches main as a fault, not as "not measured"
        broken = thread([part(5, "c", ASK)], cid="9")
        broken["parts"][0]["ts"] = "not-a-number"
        broken["updated_at"] = int(coach.time.time())            # main reads the real clock: inside its window
        api, real = Intercom([broken]), coach.tick
        with mock.patch.object(coach.collect, "resolve_token", lambda: "tok"), \
                mock.patch.object(coach.fixloop, "load_register", lambda: {}), \
                mock.patch.object(coach, "tick", lambda token, now, minutes, db, register=None:
                                  real(token, now, minutes, db, request=api, register=register)), \
                redirect_stdout(io.StringIO()):
            with self.assertRaises(ValueError):
                coach.main(["tick", "--db", facts_db(tempfile.mkdtemp(), [])])

    def test_out_keeps_the_reading_prunes_old_ones_and_never_leaves_an_older_count_as_the_newest(self):
        out_dir = os.path.join(self.tmp, "out")
        os.makedirs(os.path.join(out_dir, "ticks"))
        old = os.path.join(out_dir, "ticks", f"{int(coach.time.time()) - 15 * 86400}.json")
        kept = os.path.join(out_dir, "ticks", f"{int(coach.time.time()) - 13 * 86400}.json")
        for path in (old, kept):
            Path(path).write_text("{}\n")
        good = {"schema": coach.SCHEMA, "window": {"read": 7}}
        with mock.patch.object(coach.collect, "resolve_token", lambda: "tok"), \
                mock.patch.object(coach.fixloop, "load_register", lambda: {}), \
                mock.patch.object(coach, "tick", return_value=good), redirect_stdout(io.StringIO()):
            self.assertEqual(coach.main(["tick", "--out", out_dir]), 0)
        latest = os.path.join(out_dir, "latest.json")
        self.assertEqual(json.loads(Path(latest).read_text()), good)
        self.assertFalse(os.path.exists(old))
        self.assertTrue(os.path.exists(kept))
        self.assertEqual(len(os.listdir(os.path.join(out_dir, "ticks"))), 2)
        with mock.patch.object(coach.collect, "resolve_token", lambda: "tok"), \
                mock.patch.object(coach.fixloop, "load_register", lambda: {}), \
                mock.patch.object(coach, "tick", side_effect=coach.collect.CollectError("down")), \
                redirect_stdout(io.StringIO()):
            self.assertEqual(coach.main(["tick", "--out", out_dir]), 2)
        now_latest = json.loads(Path(latest).read_text())
        self.assertNotIn("window", now_latest)                       # the 7 is gone: the newest file is "not measured"
        self.assertEqual(now_latest["not_measured_reason"], "CollectError: down")

    def test_the_reader_has_no_way_to_write_to_intercom(self):
        code = Path(coach.__file__).read_text().split('"""', 2)[2]
        # No HTTP of its own (every call is the collector's search or GET), no shell, no writer.
        for banned in ('"POST"', '"PUT"', '"DELETE"', '"PATCH"', "/reply", "/parts", "urllib", "subprocess",
                       "os.system", "intercom-ops-write", "_request("):
            self.assertFalse(banned in code, banned)
        self.assertEqual(code.count("collect._search("), 1)
        self.assertEqual(code.count("collect.fetch_thread("), 2)


if __name__ == "__main__":
    unittest.main()
