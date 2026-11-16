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


class GuardReasonTests(unittest.TestCase):
    """Why the guard refused, from the guard's own ledger.

    A `guard_fallback` signal says a reply was replaced with the fallback line; the conversation cannot say which
    rule fired, because the customer only ever saw the fallback. The ledger can, and the rows below are the shapes
    it actually writes (plugins/intercom/src/safety-ledger.ts): an `output_guard` row carrying flags, an
    `unbacked_handoff` row whose action is `fallback`, and an `output_guard_retry` row carrying `why`.
    """

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.path = os.path.join(self.tmp, "ledger.jsonl")

    def write(self, *rows, path=None):
        with open(path or self.path, "w", encoding="utf-8") as fh:
            for r in rows:
                fh.write(json.dumps(r) + "\n")

    def test_the_guard_row_names_the_rule_that_refused_the_reply(self):
        self.write({"ts": "2026-11-12T03:52:42.683Z", "kind": "output_guard", "ref": "100", "enforced": True,
                    "flags": [{"family": "contradict", "rule": "fact_unverified:status_chase", "excerpt": "x"}]})
        self.assertEqual(coach.guard_reasons(["100"], path=self.path, now=NOW), {"100": ["guard:contradict:fact_unverified:status_chase"]})

    def test_a_handoff_that_was_replaced_and_a_retry_that_failed_are_both_reasons(self):
        self.write({"ts": "2026-11-15T11:00:14.139Z", "kind": "unbacked_handoff", "ref": "100", "action": "fallback"},
                   {"ts": "2026-11-15T11:00:14.140Z", "kind": "output_guard_retry", "ref": "100", "outcome": "unusable",
                    "why": "only_person_promise"})
        self.assertEqual(coach.guard_reasons(["100"], path=self.path, now=NOW),
                         {"100": ["retry:only_person_promise", "unbacked_handoff"]})

    def test_a_retry_that_passed_is_not_a_reason_and_another_conversation_is_not_read(self):
        self.write({"ts": "2026-11-15T11:00:38.357Z", "kind": "output_guard_retry", "ref": "100", "outcome": "passed"},
                   {"ts": "2026-11-15T11:00:38.357Z", "kind": "output_guard", "ref": "999", "enforced": True,
                    "flags": [{"family": "promise", "rule": "timeframe_within"}]})
        self.assertEqual(coach.guard_reasons(["100"], path=self.path, now=NOW), {})

    def test_the_same_reason_twice_is_named_once_and_at_most_three_are_kept(self):
        self.write(*[{"ts": f"2026-11-15T11:00:0{i}.000Z", "kind": "output_guard", "ref": "100", "enforced": True,
                      "flags": [{"family": "contradict", "rule": "fact_unverified:status_chase"}]} for i in range(3)],
                   {"ts": "2026-11-15T11:00:09.000Z", "kind": "output_guard", "ref": "100", "enforced": True,
                    "flags": [{"family": "promise", "rule": "timeframe_within"}]},
                   {"ts": "2026-11-15T11:00:10.000Z", "kind": "output_guard", "ref": "100", "enforced": True,
                    "flags": [{"family": "reveal", "rule": "staff_name"}]},
                   {"ts": "2026-11-15T11:00:11.000Z", "kind": "output_guard", "ref": "100", "enforced": True,
                    "flags": [{"family": "off_topic", "rule": "code_fence"}]})
        got = coach.guard_reasons(["100"], path=self.path, now=NOW)["100"]
        self.assertEqual(len(got), coach.GUARD_WHY_MAX)
        self.assertEqual(got[0], "guard:off_topic:code_fence")          # newest first
        self.assertEqual(len(set(got)), len(got))

    def test_a_row_that_refused_nothing_is_not_a_reason(self):
        """A note is a passing answer, a shadow-mode guard row stopped nothing, and a pending retry may still pass.
        Counting any of them would name a cause that did not fire for a conversation refused earlier (QA 2026-11-15)."""
        self.write({"ts": "2026-11-15T11:00:00.000Z", "kind": "output_note", "ref": "100",
                    "flags": [{"family": "note", "rule": "altered_approved_line:status_chase"}]},
                   {"ts": "2026-11-15T11:00:01.000Z", "kind": "output_guard", "ref": "100", "mode": "shadow",
                    "enforced": False, "flags": [{"family": "contradict", "rule": "fact_unverified:status_chase"}]},
                   {"ts": "2026-11-15T11:00:02.000Z", "kind": "output_guard_retry", "ref": "100", "outcome": "pending"},
                   {"ts": "2026-11-15T11:00:03.000Z", "kind": "unbacked_handoff", "ref": "100", "action": "stripped"})
        self.assertEqual(coach.guard_reasons(["100"], path=self.path, now=NOW), {})

    def test_a_later_answer_that_passed_does_not_replace_the_reason_of_the_earlier_refusal(self):
        """The case QA named: refused once (the customer saw the fallback), then answered properly. The later rows
        are newer, so a reader that took them would report the note's rule as why the fallback was sent."""
        self.write({"ts": "2026-11-15T10:00:00.000Z", "kind": "output_guard", "ref": "100", "mode": "enforce",
                    "enforced": True, "attempt": 2,
                    "flags": [{"family": "contradict", "rule": "fact_unverified:status_chase"}]},
                   # the next turn: refused, retried, and the corrected retry passed with a note
                   {"ts": "2026-11-15T11:00:00.000Z", "kind": "output_guard_retry", "ref": "100", "outcome": "pending",
                    "flags": [{"family": "promise", "rule": "timeframe_within"}]},
                   {"ts": "2026-11-15T11:00:05.000Z", "kind": "output_note", "ref": "100",
                    "flags": [{"family": "note", "rule": "altered_approved_line:status_chase"}]},
                   {"ts": "2026-11-15T11:00:05.001Z", "kind": "output_guard_retry", "ref": "100", "outcome": "passed"})
        self.assertEqual(coach.guard_reasons(["100"], path=self.path, now=NOW),
                         {"100": ["guard:contradict:fact_unverified:status_chase"]})

    def test_only_the_guards_own_enforced_flag_makes_a_guard_row_a_refusal(self):
        """`enforced` is the guard's word for "this row replaced the reply". A row that says `enforced: false` refused
        nothing even when its `mode` says enforce, and a row that does not say is not a known refusal."""
        flags = [{"family": "contradict", "rule": "fact_unverified:status_chase"}]
        self.write({"ts": "2026-11-15T11:00:00.000Z", "kind": "output_guard", "ref": "100", "mode": "enforce",
                    "enforced": False, "flags": flags},
                   {"ts": "2026-11-15T11:00:01.000Z", "kind": "output_guard", "ref": "100", "mode": "enforce",
                    "flags": flags},
                   {"ts": "2026-11-15T11:00:02.000Z", "kind": "output_guard", "ref": "100", "mode": "enforce",
                    "enforced": "true", "flags": flags})
        self.assertEqual(coach.guard_reasons(["100"], path=self.path, now=NOW), {})

    def test_a_sealed_ledger_is_read_and_one_that_cannot_be_read_is_not_measured(self):
        sealed = self.path + ".sealed-20261112T061131Z"
        self.write({"ts": "2026-11-12T03:52:42.683Z", "kind": "output_guard", "ref": "100", "enforced": True,
                    "flags": [{"family": "contradict", "rule": "fact_unverified:status_chase"}]}, path=sealed)
        self.write()                                                    # the current file is empty
        self.assertEqual(coach.guard_reasons(["100"], path=self.path, now=NOW),
                         {"100": ["guard:contradict:fact_unverified:status_chase"]})
        missing = coach.guard_reasons(["100"], path=os.path.join(self.tmp, "nope.jsonl"), now=NOW)
        self.assertIn("not_measured", missing)

    def test_a_reading_says_why_the_guard_refused_and_never_reads_as_no_reason(self):
        self.write({"ts": "2026-11-15T11:00:14.140Z", "kind": "output_guard_retry", "ref": "1", "outcome": "unusable",
                    "why": "only_person_promise"})
        guarded = thread([part(60, "a", "Thanks for your message.")], cid="1", tags=[rules.GUARD_TAG],
                         tag_at={rules.GUARD_TAG: NOW - 600})
        patch = mock.patch.object(coach.collect, "reduce_thread", lambda detail: detail["__reduced__"])
        patch.start()
        self.addCleanup(patch.stop)
        db = facts_db(self.tmp, ())
        doc = coach.tick("tok", NOW, 30, db, request=Intercom([guarded]), ledger_path=self.path)
        self.assertEqual(doc["window"]["by_guard_why"], {"retry:only_person_promise": 1})
        self.assertEqual(doc["window"]["conversations"][0]["guard_why"], "retry:only_person_promise")
        # the same reading with a ledger that cannot be read: the cause is unknown, and it says so
        doc = coach.tick("tok", NOW, 30, db, request=Intercom([guarded]),
                         ledger_path=os.path.join(self.tmp, "nope.jsonl"))
        self.assertTrue(doc["window"]["conversations"][0]["guard_why"].startswith("not measured: "))
        self.assertEqual(list(doc["window"]["by_guard_why"]), [doc["window"]["conversations"][0]["guard_why"]])

class CensusTests(unittest.TestCase):
    """Item D: every open conversation in one terminal state, or none.

    Every Caroline line below is a real one, read from node-8's open conversations on 2026-11-15 (the ids are
    dropped). They are the shapes that decide the number: the drain's holding line and the hand-off line look
    like answers and are not, and a line no rule matches is `none`, never `answered`.
    """

    HOLDING = ("Sorry, we did not reply to this message when you sent it. If you still need help, reply here and "
               "tell us what you need, and you will get an answer in this conversation.")
    HANDOFF = ("I'm pulling in a teammate to take this from here. You'll hear from us in this conversation and by "
               "email. Reference: 1amvh5572qg.")
    DECIDED = ("Sorry for the slow reply. Every credit request on your account has been reviewed. The approved "
               "credits are on your Muso profile. The others were denied for now. You can resubmit for those "
               "credits again later. If you need help with anything else, reply here and tell us what you need.")
    WHICH_ONE = ("Just to be sure, which one did you mean: withdraw the credit-removal request, or stop receiving "
                 "profile owner notices?")
    STATUS = ("I'm sorry this has taken longer than it should. I understand. Your request is in the verification "
              "queue and the outcome comes to this conversation and to your email; if the team needs anything "
              "from you they will ask here.")
    GDPR_ACK = ("Thank you, we have your request to remove your personal data from Muso, received November 15, "
                "2026. Here is how it works. **1. Confirm it's you.** The quickest way: open the page in the Muso "
                "app and claim it, that proves it on the spot. Or reply from the email address on your Muso "
                "account, if you have one.")

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        patch = mock.patch.object(coach.collect, "reduce_thread", lambda detail: detail["__reduced__"])
        patch.start()
        self.addCleanup(patch.stop)

    def census(self, threads, rows=(), **kw):
        api = Intercom(threads, **{k: kw.pop(k) for k in ("total", "fail") if k in kw})
        db = kw.pop("db", None) or facts_db(self.tmp, rows or [(t["id"], [], True) for t in threads])
        cache = kw.pop("cache", os.path.join(self.tmp, "census.sqlite"))
        return coach.census("tok", NOW, db, cache, request=api), api

    def facts(self, threads, taken=NOW - 1800):
        """A monitor facts file carrying each thread's own `updated_at`, which is the census cache's key.

        `facts.updated_at` is Intercom's thread timestamp, not the row's write time: the monitor keeps it so a
        thread whose `updated_at` has not moved is not fetched again. The events are the monitor's own shape -
        `[[ts, code], ...]` with c/a/h for who spoke.
        """
        path = os.path.join(tempfile.mkdtemp(), "monitor.sqlite")
        db = sqlite3.connect(path)
        db.execute("CREATE TABLE facts (id TEXT PRIMARY KEY, created_at INTEGER, updated_at INTEGER, open INTEGER, "
                   "rules TEXT, shape TEXT, outbound INTEGER, events TEXT)")
        db.execute("CREATE TABLE readings (taken_at INTEGER, kind TEXT, payload TEXT)")
        for t in threads:
            events = [[int(p["ts"]), {"user": "c", "admin": "a"}.get(p["at"], "h")] for p in t["parts"]]
            db.execute("INSERT INTO facts VALUES (?,?,?,?,?,?,?,?)",
                       (t["id"], t["created_at"], t["updated_at"], 1, "r", "other", 0, json.dumps(events)))
        db.execute("INSERT INTO readings VALUES (?,?,?)", (taken, "week", "{}"))
        db.commit()
        db.close()
        return path

    def state(self, last, who="a", ago=60, **kw):
        t = thread([part(ago, who, last)], cid="1", **kw)
        doc, _ = self.census([t])
        return doc["by_state"], doc["by_reason"]

    def test_the_drains_holding_line_is_none_and_never_waiting_on_the_customer(self):
        # It asks the customer to restate a question we already have. Counting it as waiting-on-customer would
        # make the lingering number fall while nothing was answered.
        states, reasons = self.state(self.HOLDING)
        self.assertEqual(states["none"], 1)
        self.assertEqual(states["waiting_on_customer"], 0)
        self.assertEqual(reasons, {"holding_line": 1})

    def test_the_handoff_line_is_none_because_the_person_it_promises_does_not_exist(self):
        states, reasons = self.state(self.HANDOFF)
        self.assertEqual(states["none"], 1)
        self.assertEqual(reasons, {"promise_no_person": 1})

    def test_a_refuse_with_its_reason_and_what_would_change_it_is_decided(self):
        states, reasons = self.state(self.DECIDED)
        self.assertEqual(states["decided"], 1)
        self.assertEqual(reasons, {"decision": 1})

    def test_a_question_naming_one_item_is_waiting_on_the_customer(self):
        states, _ = self.state(self.WHICH_ONE)
        self.assertEqual(states["waiting_on_customer"], 1)

    def test_a_gdpr_acknowledgement_that_asks_for_the_identity_step_waits_on_the_customer(self):
        states, _ = self.state(self.GDPR_ACK)
        self.assertEqual(states["waiting_on_customer"], 1)

    def test_a_status_answer_owes_nothing_and_is_answered(self):
        states, reasons = self.state(self.STATUS)
        self.assertEqual(states["answered"], 1)
        self.assertEqual(reasons, {"fact_given": 1})

    def test_a_closing_line_is_answered(self):
        states, _ = self.state("Anytime, Ricardo!")
        self.assertEqual(states["answered"], 1)

    def test_a_line_in_a_language_these_rules_cannot_read_is_none_and_named(self):
        # Caroline answers in the customer's language, so a third of her outbound lines are not English. The
        # fail-closed direction: an unread line counted as answered is a conversation nobody looks at again.
        states, reasons = self.state("Здравствуйте, Руслан! В Muso нельзя загрузить аудиотрек для публикации.")
        self.assertEqual(states["none"], 1)
        self.assertEqual(reasons, {"not_english": 1})

    def test_a_spanish_reply_is_not_read_as_an_english_answer(self):
        states, reasons = self.state("Tienes razón, Dao. He añadido a tu solicitud una petición concreta: que te "
                                     "indiquen si falta algún paso de tu parte o que resuelvan el acceso al perfil.")
        self.assertEqual(reasons, {"not_english": 1})

    def test_a_short_english_closing_line_is_still_an_answer(self):
        states, _ = self.state("You got it, Gadzu.")
        self.assertEqual(states["answered"], 1)

    def test_a_cannot_with_no_next_step_behind_it_is_none(self):
        # The Joel Ward shape: a dead end is not an answer.
        states, reasons = self.state("I haven't received a human response about your request, and I can't tell "
                                     "you when one will come.")
        self.assertEqual(states["none"], 1)
        self.assertEqual(reasons, {"only_cannot": 1})

    def test_a_cannot_that_names_where_the_outcome_comes_from_is_an_answer(self):
        states, _ = self.state("I can't promise the songs will be removed. Any outcome on the original request "
                               "will appear here and by email.")
        self.assertEqual(states["answered"], 1)

    def test_the_customer_speaking_last_is_none(self):
        states, reasons = self.state(ASK, who="c")
        self.assertEqual(states["none"], 1)
        self.assertEqual(reasons, {"customer_last": 1})

    def test_we_spoke_last_and_the_customer_has_been_silent_ninety_days_is_closed_stale(self):
        states, reasons = self.state("Anytime, Ricardo!", ago=coach.STALE_DAYS * 24 * 60 + 60,
                                      first_ago=coach.STALE_DAYS * 24 * 60 + 200)
        self.assertEqual(states["closed_stale"], 1)
        self.assertEqual(reasons, {"silent_90d": 1})

    def test_a_person_holding_a_thread_the_customer_spoke_last_on_is_counted_apart(self):
        t = thread([part(60, "c", ASK)], cid="1", admin_assignee=PERSON)
        doc, _ = self.census([t])
        self.assertEqual(doc["humans_assigned"], 1)
        self.assertEqual(doc["by_reason"], {"held_by_person": 1})

    def test_the_line_puts_none_first_and_carries_humans_assigned_and_the_hours_frustration(self):
        threads = [thread([part(60, "c", ASK)], cid="1"),
                   thread([part(60, "a", "Anytime, Ricardo!")], cid="2"),
                   thread([part(5, "c", "This is ridiculous, I have been waiting for weeks")], cid="3")]
        doc, _ = self.census(threads)
        text = coach.census_line(doc)
        self.assertLess(text.index("none "), text.index("answered "))
        self.assertIn("humans-assigned 0", text)
        self.assertIn("frustrated this hour 1", text)
        self.assertTrue(doc["frustrated_top"] and doc["frustrated_top"][0]["count"] == 1)

    def test_the_output_carries_no_message_text(self):
        doc, _ = self.census([thread([part(60, "a", self.DECIDED)], cid="1")])
        blob = json.dumps(doc)
        self.assertNotIn("resubmit", blob)
        self.assertNotIn("Muso profile", blob)

    def test_a_second_run_reads_only_the_threads_that_changed(self):
        t1 = thread([part(60, "a", "Anytime, Ricardo!")], cid="1")
        t2 = thread([part(60, "a", "Anytime, Ricardo!")], cid="2")
        db = self.facts([t1, t2])
        first, api1 = self.census([t1, t2], db=db)
        self.assertEqual(first["read"], 2)
        self.assertEqual(first["cached"], 0)
        second, api2 = self.census([t1, t2], db=db)
        self.assertEqual(second["read"], 0)
        self.assertEqual(second["cached"], 2)
        self.assertEqual(second["by_state"], first["by_state"])
        self.assertEqual([c for c in api2.calls if c[0] == "GET"], [])

    def test_the_hours_frustration_is_read_against_now_and_never_frozen_by_the_cache(self):
        # The row is cached until the thread changes, so a boolean decided at read time would carry last hour's
        # answer into every hour after it: the window is applied when the reading is put together.
        t = thread([part(30, "c", "This is ridiculous, I have been waiting for weeks"), part(20, "a", "Anytime!")],
                   cid="1", first_ago=90)
        db = self.facts([t])
        cache = os.path.join(self.tmp, "census.sqlite")
        api = Intercom([t])
        first = coach.census("tok", NOW, db, cache, request=api)
        self.assertEqual(first["frustrated_this_hour"], 1)
        later = coach.census("tok", NOW + 2 * coach.HOUR, db, cache, request=api)
        self.assertEqual(later["cached"], 1)
        self.assertEqual(later["frustrated_this_hour"], 0)

    def test_a_reassignment_with_no_new_message_invalidates_the_cache(self):
        # A thread handed from a person to automation writes an assignment part and no message, so the last
        # event timestamp does not move while `held` does. The key is the thread's own `updated_at`, which
        # Intercom moves on the reassignment - the monitor's own rule for "this thread changed".
        t = thread([part(60, "a", "Anytime, Ricardo!")], cid="1")
        db = self.facts([t])
        cache = os.path.join(self.tmp, "census.sqlite")
        api = Intercom([t])
        first = coach.census("tok", NOW, db, cache, request=api)
        self.assertEqual(first["humans_assigned"], 0)
        conn = sqlite3.connect(db)
        conn.execute("UPDATE facts SET updated_at = updated_at + 30 WHERE id = '1'")
        conn.commit()
        conn.close()
        again = coach.census("tok", NOW, db, cache, request=api)
        self.assertEqual(again["read"], 1)
        self.assertEqual(again["cached"], 0)

    def test_a_thread_that_changed_is_read_again_and_its_new_state_wins(self):
        t = thread([part(60, "a", "Anytime, Ricardo!")], cid="1")
        db = self.facts([t])
        self.census([t], db=db)
        moved = dict(t, updated_at=t["updated_at"] + 60,
                     parts=[part(60, "a", "Anytime, Ricardo!"), part(1, "c", ASK)])
        db2 = self.facts([moved])
        doc, _ = self.census([moved], db=db2)
        self.assertEqual(doc["read"], 1)
        self.assertEqual(doc["by_reason"], {"customer_last": 1})

    def test_facts_that_cannot_be_read_are_not_measured_and_never_zero(self):
        doc, _ = self.census([], db=os.path.join(self.tmp, "nope.sqlite"))
        self.assertIn("not_measured_reason", doc)
        self.assertNotIn("by_state", doc)
        self.assertTrue(coach.census_line(doc).startswith("NOT MEASURED"))

    def test_a_cache_that_cannot_be_written_still_gives_a_reading(self):
        t = thread([part(60, "a", "Anytime, Ricardo!")], cid="1")
        doc, _ = self.census([t], cache=os.path.join(self.tmp, "nope", "deep", "census.sqlite"))
        self.assertEqual(doc["by_state"]["answered"], 1)

    def test_a_line_no_rule_matches_is_none_and_never_answered(self):
        # "We are looking into this." gives no fact and names no next step. Counting it as answered would lower
        # the lingering number while nothing was answered, which is the one thing this census must not do.
        states, reasons = self.state("We are looking into this.")
        self.assertEqual(states["none"], 1)
        self.assertEqual(states["answered"], 0)
        self.assertEqual(reasons, {"unclassified": 1})

    def test_a_real_answer_shape_is_answered(self):
        states, reasons = self.state("You're right to call it out. I offered one month free on the subscription "
                                     "and I can see it is still active on your account.")
        self.assertEqual(states["answered"], 1)
        self.assertEqual(reasons, {"fact_given": 1})

    def test_a_question_in_another_language_is_not_read_as_a_named_ask(self):
        # It carries a question mark, and the question-mark rule must not read it as a named ask in a language
        # these English rules cannot parse.
        states, reasons = self.state("\u00bfPuedes ayudarme?")
        self.assertEqual(states["waiting_on_customer"], 0)
        self.assertEqual(reasons, {"not_english": 1})

    def test_a_cached_answer_becomes_closed_stale_when_the_ninety_days_pass(self):
        # The boundary is time, not a change to the thread: a row cached as answered on day 89 would otherwise
        # be served unchanged on day 90 forever.
        t = thread([part(89 * 24 * 60, "a", "Anytime, Ricardo!")], cid="1", first_ago=90 * 24 * 60)
        db = self.facts([t])
        cache = os.path.join(self.tmp, "census.sqlite")
        api = Intercom([t])
        first = coach.census("tok", NOW, db, cache, request=api)
        self.assertEqual(first["by_state"]["answered"], 1)
        later = coach.census("tok", NOW + 2 * coach.DAY, db, cache, request=api)
        self.assertEqual(later["cached"], 1)
        self.assertEqual(later["by_state"]["closed_stale"], 1)
        self.assertEqual(later["by_state"]["answered"], 0)

    def test_a_thread_that_could_not_be_read_is_counted_apart_and_never_a_zero(self):
        # A partial reading must never be readable as a complete one with a lower `none`.
        t1 = thread([part(60, "a", "Anytime, Ricardo!")], cid="1")
        t2 = thread([part(60, "a", "Anytime, Ricardo!")], cid="2")
        doc, _ = self.census([t1, t2], fail=("2",))
        self.assertEqual(doc["unread"], 1)
        self.assertFalse(doc["complete"])
        self.assertEqual(doc["classified"], 1)
        self.assertIn("PARTIAL: 1 unread, in no state", coach.census_line(doc))

    def test_the_line_says_how_old_the_facts_it_read_are(self):
        # The census reads the monitor's facts, so it is only as fresh as the monitor's last pass. A reading
        # served from an hour-old facts file is not a reading of the last hour, and the line has to say so.
        doc, _ = self.census([thread([part(60, "a", "Anytime, Ricardo!")], cid="1")])
        self.assertEqual(doc["facts_age_min"], 30)
        self.assertIn("| facts 30m old", coach.census_line(doc))

    def test_a_bare_refusal_is_none_and_never_a_decision(self):
        # "Your request was denied." gives no way forward: a dead end, not a decision. The approved decline
        # paragraph carries what would change it, and that is what makes it one. A reason is never required:
        # the doctrine forbids explaining why a request failed.
        self.assertEqual(coach.classify_last("Your request was denied."), ("none", "refusal_no_way_forward"))
        self.assertEqual(
            coach.classify_last("A request is closed when the supporting information we received wasn't "
                                "enough to confirm the credit. You can resubmit for the credit again later."),
            ("decided", "decision"))

    def test_the_approved_decline_copy_is_a_decision(self):
        # The one refusal copy the answer bank approves: a process reason and a way forward, no judgement
        # about their document. If this is not `decided`, the most common refusal in the inbox reads as a
        # dead end.
        states, reasons = self.state(
            "A request is closed when the supporting information we received wasn't enough to confirm the "
            "credit. You can submit it again with your supporting documents and a fresh review starts from "
            "the beginning. I can't see the review itself, so I can't tell you more than that.")
        self.assertEqual(states["decided"], 1)
        self.assertEqual(reasons, {"decision": 1})

    def test_a_refusal_that_names_an_item_to_send_is_waiting_on_the_customer(self):
        # QA round 3 on #2049: the refusal guard ran before the ask rules, so a refusal that names exactly
        # what to send was counted as a dead end. The customer has one named item, which is the definition
        # of waiting_on_customer, and counting it as `none` inflated the lingering number.
        self.assertEqual(
            coach.classify_last("We cannot approve this without proof. Could you send us your agreement?"),
            ("waiting_on_customer", "asks_customer"))
        states, reasons = self.state("We cannot approve this without proof. Could you send us your agreement?")
        self.assertEqual(states["waiting_on_customer"], 1)
        self.assertEqual(reasons, {"asks_customer": 1})

    def test_a_refusal_ending_on_a_courtesy_question_is_still_a_dead_end(self):
        # The bare question mark is deliberately not a named ask: "Any other questions?" is politeness, not
        # an item the customer owes us, and reading it as one would hide the dead end.
        self.assertEqual(coach.classify_last("Your request was denied. Any other questions?"),
                         ("none", "refusal_no_way_forward"))

    def test_a_refusal_with_no_way_forward_is_not_a_decision(self):
        # "Your request was denied." alone leaves the customer with nothing to do, so it is a dead end and
        # not a decision. A refusal is never required to carry a REASON: the doctrine forbids explaining why
        # a request failed ("Never explain the JUDGEMENT"), so a way forward is the whole of what it can say.
        states, reasons = self.state("Your request was denied.")
        self.assertEqual(states["decided"], 0)
        self.assertEqual(reasons, {"refusal_no_way_forward": 1})

    def test_the_approved_mixed_outcome_line_is_a_decision_without_a_reason(self):
        # The answer bank's own batch-decision copy: a way forward and no reason, because a reason is
        # forbidden. If this reads as `none`, the most common refusal in the inbox reads as a dead end.
        states, reasons = self.state(
            "Every credit request on your account has been reviewed. The approved credits are on your Muso "
            "profile. The others were denied for now. You can resubmit for those credits again later.")
        self.assertEqual(states["decided"], 1)
        self.assertEqual(reasons, {"decision": 1})

    def test_a_dead_end_cannot_is_not_answered_by_the_courtesy_line_after_it(self):
        # "Thanks for the details" is a courtesy, not a fact given. The dead-end check runs before the
        # generic answer patterns, or this lowers the lingering count with nothing answered.
        states, reasons = self.state("I cannot remove this. Thanks for the details.")
        self.assertEqual(states["answered"], 0)
        self.assertEqual(reasons, {"only_cannot": 1})

    def test_a_courtesy_invitation_never_settles_a_thread_that_said_nothing(self):
        # QA round 6 on #2049. "We are looking into this." is neither a fact nor a task, and the courtesy
        # sentence after it must not make it one: the question mark would read as a named ask and "let me
        # know" as a fact given. Both settle a thread nobody resolved, which is the number this census exists
        # to report. The courtesy sentence is removed before any rule reads the line.
        self.assertEqual(coach.classify_last("We are looking into this. Any other questions?"),
                         ("none", "unclassified"))
        self.assertEqual(coach.classify_last("We are looking into this. Let me know if you need anything else."),
                         ("none", "unclassified"))
        # A real answer in front of the same courtesy sentence is still an answer.
        self.assertEqual(coach.classify_last("Your profile is now verified. Let me know if you need anything else."),
                         ("answered", "fact_given"))
        # QA round 7 on #2049: a comma is as much a clause boundary as a full stop. The match starts at the
        # nearest CLAUSE, so an answer joined to the courtesy by a comma keeps its first clause. Starting at the
        # previous full stop erased the answer with the courtesy.
        for joined in ("Your profile is now verified, let me know if you need anything else.",
                       "Your profile is now verified, let me know if you need anything else"):
            self.assertEqual(coach.classify_last(joined), ("answered", "fact_given"), joined)
        self.assertEqual(coach.classify_last("Your profile is now verified! Any other questions?"),
                         ("answered", "fact_given"))
        # A refusal keeps its verdict on the comma form too.
        self.assertEqual(coach.classify_last("Your request was denied, let me know if you need anything else."),
                         ("none", "refusal_no_way_forward"))

    def test_a_courtesy_invitation_never_turns_a_cannot_into_an_answer_or_a_wait(self):
        # QA round 4 on #2049, both variants. "Let me know if you have any other questions" is not a place the
        # outcome comes from, and "Reply here if you need anything else" is not an item the customer owes us.
        # Either reading hides a request nobody resolved, which is the number this census exists to report.
        self.assertEqual(
            coach.classify_last("I cannot tell you when the review will finish. Let me know if you have any "
                                "other questions."),
            ("none", "only_cannot"))
        self.assertEqual(
            coach.classify_last("I cannot remove this. Reply here if you need anything else."),
            ("none", "only_cannot"))

    def test_a_bare_could_you_is_not_a_named_ask(self):
        # QA round 5 on #2049. The verb after "could you" decides everything: "Could you send us your
        # agreement?" asks for an item, and "Could you let us know if you have any other questions?" asks
        # for nothing. A bare "could you" read as an ask turns a dead end into a wait.
        self.assertEqual(
            coach.classify_last("I cannot remove this. Could you let me know if you need anything else?"),
            ("none", "only_cannot"))
        self.assertEqual(
            coach.classify_last("Your request was denied. Could you let us know if you have any other "
                                "questions?"),
            ("none", "refusal_no_way_forward"))
        # The concrete asks still count, including one that names a choice rather than a document.
        self.assertEqual(coach.classify_last("Could you tell us which track you meant?"),
                         ("waiting_on_customer", "asks_customer"))

    def test_a_name_or_a_title_inside_an_english_reply_does_not_make_it_unreadable(self):
        # QA round 4 on #2049. "de" and "la" are ordinary Spanish words and also ordinary name and title
        # tokens, so a vocabulary check that runs on every line counts resolved music-profile threads as
        # lingering. A long line is decided by its English function words; only a line too short for a ratio
        # is judged by its vocabulary.
        self.assertEqual(coach.classify_last("Your profile for De La Cruz is now verified."),
                         ("answered", "fact_given"))
        self.assertEqual(coach.classify_last("The track La Vida is now on your profile."),
                         ("answered", "fact_given"))
        # The short-line path still refuses a line that is only foreign words.
        self.assertEqual(coach.classify_last("Merci beaucoup!"), ("none", "not_english"))
        self.assertEqual(coach.classify_last("Gern, Franz!"), ("none", "not_english"))

    def test_every_state_and_reason_is_named(self):
        self.assertEqual(coach.CENSUS_STATES, ("none", "answered", "decided", "waiting_on_customer", "closed_stale"))
        for state, reason, pattern in coach.CENSUS_RULES:
            self.assertIn(state, coach.CENSUS_STATES)
            self.assertTrue(reason and pattern.pattern)


if __name__ == "__main__":
    unittest.main()
