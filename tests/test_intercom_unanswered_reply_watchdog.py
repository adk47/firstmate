"""Behavioral tests for scripts/intercom-unanswered-reply-watchdog.py (2026-11-11).

Conversation 215476618428402: a paying customer answered Caroline's question and asked a
status question; Caroline replied twice with "I'm pulling in a teammate"; no human wrote for
13 days and nothing paged. These tests lock:
  - the three classes are decided from the thread: customer_last, handoff_chased (that
    thread's shape: it ENDS on the bot), promise_open; a thanks-only ending is not owed;
  - only a HUMAN admin reply keeps a hand-off promise; Caroline's own later replies and
    internal notes never do, and they never restart the promise clock;
  - robot mail is not a customer message; a file with no words is one;
  - paid = the house paying list matched by contact id, sender email, or an email typed in
    the thread; a staff-domain email is never a paid key; no list = "unknown", never "free";
  - paid pages at 24 h and again every 72 h; free pages once and only while recent;
    promise_open and anything older than 30 d are counted, never listed;
  - every page carries the whole class count, paid first;
  - nothing listable but paid threads still owed: the count alone is posted, once a day;
  - a transient read failure is retried before a thread is called unreadable;
  - a thread closed while still unanswered is reported as closed-without-an-answer, once;
    one closed after a human answered is dropped quietly;
  - an unreadable thread keeps its verdict and makes the tick exit non-zero;
  - a failed Slack post records nothing, so everything retries;
  - --dry-run posts nothing and writes nothing; an unknown state shape is a hard error.
Stdlib unittest only, no network: Intercom, the replica and Slack are in-memory fakes.
"""
import argparse
import importlib.util
import io
import json
import os
import pathlib
import tempfile
import unittest
import urllib.error
from contextlib import redirect_stderr, redirect_stdout
from unittest import mock

_SCRIPT = pathlib.Path(__file__).resolve().parent.parent / "scripts" / "intercom-unanswered-reply-watchdog.py"
_spec = importlib.util.spec_from_file_location("intercom_unanswered_reply_watchdog", _SCRIPT)
wd = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(wd)

BOT = "5763097"
JAN = "5465657"
H = 3600
D = 24 * H
NOW = 2_000_000_000
HANDOFF = "I can't confirm that from here. I'm pulling in a teammate to take this from here."
ANSWER = "You can change that under Settings."
ASK = "Any update on my page claim?"


def part(pid, ts, author_type, author_id="u1", body="text", part_type="comment", **extra):
    return {"id": pid, "created_at": ts, "author": {"type": author_type, "id": author_id},
            "body": body, "part_type": part_type, **extra}


def cust(pid, ts, body=ASK, **extra):
    return part(pid, ts, "user", body=body, **extra)


def caroline(pid, ts, body=HANDOFF, **extra):
    return part(pid, ts, "admin", BOT, body=body, **extra)


def human(pid, ts, body="Hi, Jan here. Done.", part_type="comment", **extra):
    return part(pid, ts, "admin", JAN, body=body, part_type=part_type, **extra)


def detail(parts, opening=ASK, src_ts=NOW - 100 * H, state="open", email="fan@example.test"):
    return {"created_at": src_ts, "state": state,
            "source": {"id": "src", "subject": "Help", "body": opening, "delivered_as": "customer_initiated",
                       "author": {"type": "user", "id": "u1", "email": email}},
            "conversation_parts": {"conversation_parts": parts}}


def v(parts, **kw):
    return wd.verdict(detail(parts, **kw), BOT)


class Verdict(unittest.TestCase):
    def test_customer_wrote_last_and_nobody_replied(self):
        out = v([caroline("p1", NOW - 90 * H, ANSWER), cust("p2", NOW - 80 * H)])
        self.assertEqual((out["k"], out["s"], out["e"]), (wd.CUSTOMER_LAST, NOW - 80 * H, "p2"))

    def test_unanswered_opening_message(self):
        out = v([])
        self.assertEqual((out["k"], out["s"], out["e"]), (wd.CUSTOMER_LAST, NOW - 100 * H, "src"))

    def test_caroline_answer_without_a_promise_is_an_answer(self):
        self.assertIsNone(v([caroline("p1", NOW - 90 * H, ANSWER)])["k"])

    def test_thanks_only_ending_is_not_owed(self):
        out = v([caroline("p1", NOW - 90 * H, ANSWER), cust("p2", NOW - 80 * H, "thanks so much!")])
        self.assertEqual(out["k"], wd.NOT_OWED)

    def test_file_with_no_words_is_a_message_owed_a_reply(self):
        out = v([caroline("p1", NOW - 90 * H, ANSWER),
                 cust("p2", NOW - 80 * H, "", attachments=[{"name": "contract.pdf"}])])
        self.assertEqual((out["k"], out["e"]), (wd.CUSTOMER_LAST, "p2"))

    def test_the_thread_this_was_built_for_ends_on_the_bot_and_is_still_owed(self):
        # asked, told "a teammate"; asked again, told "a teammate" again; no human at all
        out = v([caroline("p1", NOW - 13 * D, "You'll hear back from the team on the credit."),
                 cust("p2", NOW - 20 * H),
                 caroline("p3", NOW - 20 * H + 30),
                 cust("p4", NOW - 19 * H, "I never received a code. It still says under review."),
                 caroline("p5", NOW - 19 * H + 30)])
        self.assertEqual(out["k"], wd.HANDOFF_CHASED)
        # the clock is the FIRST unkept promise, not the latest bot reply
        self.assertEqual((out["s"], out["e"]), (NOW - 13 * D, "promise:p1"))

    def test_promise_nobody_chased_is_promise_open(self):
        out = v([caroline("p1", NOW - 90 * H)])
        self.assertEqual((out["k"], out["s"], out["e"]), (wd.PROMISE_OPEN, NOW - 90 * H, "promise:p1"))

    def test_chased_but_caroline_then_said_something_else_is_promise_open(self):
        out = v([caroline("p1", NOW - 90 * H), cust("p2", NOW - 80 * H), caroline("p3", NOW - 79 * H, ANSWER)])
        self.assertEqual((out["k"], out["e"]), (wd.PROMISE_OPEN, "promise:p1"))

    def test_customer_chasing_an_unkept_promise_with_no_reply_is_customer_last(self):
        out = v([caroline("p1", NOW - 90 * H), cust("p2", NOW - 80 * H)])
        self.assertEqual((out["k"], out["e"]), (wd.CUSTOMER_LAST, "p2"))

    def test_only_a_human_reply_keeps_the_promise(self):
        self.assertIsNone(v([caroline("p1", NOW - 90 * H), human("p2", NOW - 80 * H)])["k"])

    def test_a_human_reply_that_is_only_an_attachment_is_still_a_reply(self):
        out = v([caroline("p1", NOW - 90 * H),
                 human("p2", NOW - 80 * H, body="", attachments=[{"name": "receipt.pdf"}])])
        self.assertIsNone(out["k"])

    def test_a_caroline_reply_that_is_only_an_attachment_never_repeats_her_promise(self):
        out = v([caroline("p1", NOW - 90 * H),
                 caroline("p2", NOW - 80 * H, body="", attachments=[{"name": "guide.pdf"}])])
        self.assertEqual((out["k"], out["e"]), (wd.PROMISE_OPEN, "promise:p1"))

    def test_internal_note_from_a_human_keeps_nothing(self):
        out = v([caroline("p1", NOW - 90 * H), human("p2", NOW - 80 * H, part_type="note")])
        self.assertEqual(out["k"], wd.PROMISE_OPEN)

    def test_a_new_promise_after_a_human_reply_starts_a_new_episode(self):
        out = v([caroline("p1", NOW - 90 * H), human("p2", NOW - 80 * H),
                 cust("p3", NOW - 70 * H), caroline("p4", NOW - 69 * H)])
        self.assertEqual((out["k"], out["s"], out["e"]), (wd.PROMISE_OPEN, NOW - 69 * H, "promise:p4"))

    def test_thanks_after_a_hand_off_does_not_hide_the_promise(self):
        out = v([caroline("p1", NOW - 90 * H), cust("p2", NOW - 80 * H, "ok thanks")])
        self.assertEqual((out["k"], out["e"]), (wd.PROMISE_OPEN, "promise:p1"))

    def test_robot_auto_reply_is_not_a_customer_message(self):
        out = v([caroline("p1", NOW - 90 * H, ANSWER), cust("p2", NOW - 80 * H, "I am out of office")])
        self.assertIsNone(out["k"])

    def test_outbound_message_nobody_answered_owes_nothing(self):
        d = {"created_at": NOW - 90 * H, "state": "open",
             "source": {"author": {"type": "admin", "id": BOT}, "body": "We'll be in touch about your plaque"},
             "conversation_parts": {"conversation_parts": []}}
        self.assertIsNone(wd.verdict(d, BOT)["k"])

    def test_emails_typed_in_the_thread_are_kept_as_hashes_only(self):
        out = v([cust("p1", NOW - 80 * H, "SOME LABEL - Team@SomeLabel.example and me@other.example")])
        self.assertEqual(sorted(out["m"]), sorted([wd.sha("team@somelabel.example"), wd.sha("me@other.example")]))
        self.assertNotIn("somelabel", json.dumps(out))

    def test_hand_off_wordings(self):
        for text in ("I'm pulling in a teammate to take this from here.",
                     "I'll make sure this gets to the team.",
                     "I've flagged this for our team to look at.",
                     "This has been escalated to the engineering team.",
                     "You\u2019ll hear back from us by email.",
                     "We'll be in touch.", "This needs a manual review."):
            self.assertTrue(wd.PROMISE_RE.search(text), text)
        for text in ("Claims are usually reviewed within 3 business days.",
                     "You can invite your team from the Business page.",
                     "I sent you a short code by email."):
            self.assertFalse(wd.PROMISE_RE.search(text), text)


class NeedsRead(unittest.TestCase):
    def test_outbound_with_no_customer_reply_is_never_read(self):
        c = {"statistics": {}, "source": {"delivered_as": "admin_initiated", "author": {"type": "admin"}}}
        self.assertFalse(wd.needs_read(c))

    def test_customer_initiated_or_replied_is_read(self):
        self.assertTrue(wd.needs_read({"statistics": {}, "source": {"delivered_as": "customer_initiated"}}))
        self.assertTrue(wd.needs_read({"statistics": {"last_contact_reply_at": 5},
                                       "source": {"delivered_as": "admin_initiated"}}))
        self.assertTrue(wd.needs_read({"statistics": {}, "source": {"author": {"type": "lead"}}}))


class Paid(unittest.TestCase):
    def setUp(self):
        self.idmap = {"7": ["pro-7", "auth0|abc", wd.sha("payer@label.example")]}
        self.index = wd.paid_index(self.idmap)

    def test_contact_id_then_sender_then_mentioned(self):
        self.assertEqual(wd.paid_of(["pro-7"], None, [], self.index), ("paid", "contact"))
        self.assertEqual(wd.paid_of(["auth0|abc"], None, [], self.index), ("paid", "contact"))
        self.assertEqual(wd.paid_of(["abc"], None, [], self.index), ("paid", "contact"))
        self.assertEqual(wd.paid_of([], wd.sha("PAYER@label.example"), [], self.index), ("paid", "sender_email"))
        self.assertEqual(wd.paid_of(["x"], wd.sha("a@b.example"), [wd.sha("payer@label.example")], self.index),
                         ("paid", "mentioned_email"))

    def test_no_match_is_free(self):
        self.assertEqual(wd.paid_of(["x"], wd.sha("a@b.example"), [], self.index), ("free", None))

    def test_a_partial_paying_index_never_labels_an_unmatched_thread_free(self):
        self.assertEqual(wd.paid_of(["x"], wd.sha("a@b.example"), [], self.index, partial=True),
                         ("unknown", None))
        self.assertEqual(wd.paid_of(["pro-7"], None, [], self.index, partial=True), ("paid", "contact"))

    def test_no_paying_list_is_unknown_never_free(self):
        self.assertEqual(wd.paid_of(["pro-7"], None, [], None), ("unknown", None))

    def test_idmap_refreshes_stale_accounts_and_forgets_lapsed_ones(self):
        asked = []

        def query(sql):
            asked.append(sql)
            return [["8", "pro-8", "", "new@label.example"]]
        idmap = {"7": ["pro-7", "", "", NOW - wd.IDMAP_TTL_S - 1],
                 "9": ["pro-9", "", "", NOW]}
        # 7 came back from no row, so its old keys are gone and it counts as unmapped
        self.assertEqual(wd.refresh_idmap(idmap, frozenset({7, 8}), query, now=NOW), 1)
        self.assertEqual(sorted(idmap), ["8"])
        self.assertEqual(len(asked), 1)
        self.assertIn("IN (7, 8)", asked[0])

    def test_a_stale_account_keeps_no_keys_when_the_refresh_fails(self):
        def query(sql):
            raise OSError("no trino pod")
        idmap = {"7": ["pro-7", "auth0|7", wd.sha("old@label.example"), NOW - wd.IDMAP_TTL_S - 1]}
        with redirect_stderr(io.StringIO()):
            self.assertEqual(wd.refresh_idmap(idmap, frozenset({7}), query, now=NOW), 1)
        self.assertEqual(idmap, {})
        self.assertEqual(wd.paid_of([], wd.sha("old@label.example"), [], wd.paid_index(idmap), partial=True),
                         ("unknown", None))

    def test_idmap_keeps_a_fresh_account_without_re_reading_it(self):
        asked = []

        def query(sql):
            asked.append(sql)
            return []
        idmap = {"7": ["pro-7", "", "", NOW - 60]}
        self.assertEqual(wd.refresh_idmap(idmap, frozenset({7}), query, now=NOW), 0)
        self.assertEqual(asked, [])

    def test_a_changed_email_is_picked_up_after_the_ttl(self):
        idmap = {}
        wd.refresh_idmap(idmap, frozenset({7}),
                         lambda sql: [["7", "pro-7", "", "old@label.example"]], now=NOW)
        self.assertEqual(wd.paid_of([], wd.sha("old@label.example"), [], wd.paid_index(idmap)),
                         ("paid", "sender_email"))
        wd.refresh_idmap(idmap, frozenset({7}),
                         lambda sql: [["7", "pro-7", "", "new@label.example"]],
                         now=NOW + wd.IDMAP_TTL_S)
        index = wd.paid_index(idmap)
        self.assertEqual(wd.paid_of([], wd.sha("new@label.example"), [], index), ("paid", "sender_email"))
        self.assertEqual(wd.paid_of([], wd.sha("old@label.example"), [], index), ("free", None))

    def test_staff_domain_email_is_never_a_paid_key(self):
        idmap = {}
        wd.refresh_idmap(idmap, frozenset({1}), lambda sql: [["1", "pro-1", "", "support@muso.ai"]])
        ext, mail = wd.paid_index(idmap)
        self.assertEqual(mail, {})
        self.assertIn("pro-1", ext)

    def test_replica_failure_leaves_accounts_unmapped_and_says_how_many(self):
        def query(sql):
            raise OSError("no trino pod")
        with redirect_stderr(io.StringIO()):
            self.assertEqual(wd.refresh_idmap({}, frozenset({1, 2}), query), 2)

    def test_csv_with_a_comma_in_a_field_is_parsed_whole(self):
        done = mock.Mock(returncode=0, stdout='WARNING: jline\n"5","pro,5","","a@b.example"\n', stderr="")
        with mock.patch.object(wd.subprocess, "run", return_value=done):
            self.assertEqual(wd.trino("select 1"), [["5", "pro,5", "", "a@b.example"]])


def row(cid="c1", k=None, wait_h=30, paid="paid", e="p1", basis="contact"):
    return {"id": cid, "k": k or wd.CUSTOMER_LAST, "s": NOW - wait_h * H, "e": e, "paid": paid,
            "basis": basis if paid == "paid" else None, "subj": "Help", "closed": False}


class Paging(unittest.TestCase):
    def page(self, r, paged=None, at=NOW):
        return wd.should_page(r, at, paged or {}, wd.THRESHOLD_H, wd.REPAGE_H)

    def test_n_is_24_hours(self):
        self.assertEqual(wd.THRESHOLD_H, 24)
        self.assertFalse(self.page(row(wait_h=23)))
        self.assertTrue(self.page(row(wait_h=24)))

    def test_paid_repeats_every_72_hours_while_the_same_episode_is_unanswered(self):
        paged = {"c1": {"episode": "p1", "last_paged": NOW}}
        r = row(wait_h=30)
        self.assertFalse(self.page(r, paged, NOW + 71 * H))
        self.assertTrue(self.page(r, paged, NOW + 72 * H))

    def test_a_new_customer_message_is_a_new_episode(self):
        self.assertTrue(self.page(row(e="p9"), {"c1": {"episode": "p1", "last_paged": NOW}}))

    def test_hand_off_chased_pages_for_paid_and_free(self):
        self.assertTrue(self.page(row(k=wd.HANDOFF_CHASED)))
        self.assertTrue(self.page(row(k=wd.HANDOFF_CHASED, paid="free")))
        paged = {"c1": {"episode": "p1", "last_paged": NOW}}
        self.assertFalse(self.page(row(k=wd.HANDOFF_CHASED, paid="free"), paged, NOW + 6 * 24 * H))
        self.assertTrue(self.page(row(k=wd.HANDOFF_CHASED, paid="free"), paged, NOW + 7 * 24 * H))

    def test_promise_open_is_counted_never_listed(self):
        self.assertFalse(self.page(row(k=wd.PROMISE_OPEN)))

    def test_free_pages_once_then_every_seven_days(self):
        self.assertTrue(self.page(row(paid="free", wait_h=30)))
        paged = {"c1": {"episode": "p1", "last_paged": NOW}}
        self.assertFalse(self.page(row(paid="free", wait_h=30), paged, NOW + 6 * 24 * H))
        self.assertTrue(self.page(row(paid="free", wait_h=30), paged, NOW + 7 * 24 * H))
        self.assertTrue(self.page(row(paid="free", wait_h=9 * 24)))

    def test_old_backlog_is_counted_never_listed(self):
        self.assertFalse(self.page(row(wait_h=31 * 24)))

    def test_unmeasured_paid_status_pages_like_paid(self):
        self.assertTrue(self.page(row(paid="unknown", k=wd.HANDOFF_CHASED)))


class Counting(unittest.TestCase):
    def test_counts_split_paid_free_and_class_and_skip_what_is_under_n(self):
        rows = [row("a"), row("b", k=wd.HANDOFF_CHASED, wait_h=13 * 24),
                row("c", k=wd.PROMISE_OPEN, wait_h=40 * 24, basis="mentioned_email"),
                row("d", paid="free"), row("e", paid="free", k=wd.PROMISE_OPEN),
                row("f", wait_h=5), row("g", k=wd.NOT_OWED, paid="free")]
        s = wd.summarize(rows, NOW, 24)
        self.assertEqual((s["total"], s["by_paid"]), (5, {"paid": 3, "free": 2, "unknown": 0}))
        self.assertEqual(s["by_class"]["paid"],
                         {wd.CUSTOMER_LAST: 1, wd.HANDOFF_CHASED: 1, wd.PROMISE_OPEN: 1})
        self.assertEqual(s["within_list_window"]["paid"], 2)
        self.assertEqual(s["paid_by_basis"], {"contact": 2, "mentioned_email": 1})
        self.assertEqual((s["not_owed"], s["oldest_days"]["paid"]), (1, 40))


class Rendering(unittest.TestCase):
    def test_one_message_with_the_whole_class_count_and_no_item_cut(self):
        rows = [row(f"c{i}", wait_h=30 + i) for i in range(40)]
        s = wd.summarize(rows, NOW, 24)
        text = wd.render(rows, 3, [], s, None, 0, NOW, ["U038BM16T7W"], "dwjzhcge")
        self.assertTrue(text.startswith("<@U038BM16T7W>"))
        self.assertIn("*40 paid*", text)
        self.assertIn("+3 more due", text)
        blocks = wd.blocks_for(text)
        self.assertTrue(all(len(b["text"]["text"]) <= 2900 for b in blocks))
        joined = "\n".join(b["text"]["text"] for b in blocks)
        for i in range(40):
            self.assertIn(f"/conversation/c{i}\n", joined)

    def test_subject_cannot_inject_a_mention(self):
        r = row()
        r["subj"] = "<!channel> urgent"
        self.assertNotIn("<!channel>", wd.render_line(r, NOW, "dwjzhcge"))

    def test_warnings_are_in_the_page(self):
        text = wd.render([row(paid="unknown")], 0, [], wd.summarize([row(paid="unknown")], NOW, 24),
                         "paying list unusable (stale)", 2, NOW, [], "w")
        self.assertIn("Paid split incomplete", text)
        self.assertIn("2 thread(s) could not be read", text)
        self.assertIn("paid status unverified", text)


class State(unittest.TestCase):
    def test_missing_file_is_a_fresh_start(self):
        self.assertEqual(wd.load_state("/nonexistent/state.json"), wd.empty_state())

    def test_unknown_shape_is_a_hard_error(self):
        with tempfile.TemporaryDirectory() as d:
            for bad in ('{"watch": {}}', '[]', '{"threads": []}'):
                p = os.path.join(d, "state.json")
                pathlib.Path(p).write_text(bad)
                with self.assertRaises(ValueError):
                    wd.load_state(p)


class Reads(unittest.TestCase):
    def get(self, outcomes):
        calls = []

        class Resp(io.BytesIO):
            def __enter__(self):
                return self

            def __exit__(self, *a):
                return False

        def urlopen(req, timeout=None):
            calls.append(req.full_url)
            o = outcomes[len(calls) - 1]
            if isinstance(o, Exception):
                raise o
            return Resp(json.dumps(o).encode())
        with mock.patch.object(wd.urllib.request, "urlopen", urlopen), mock.patch.object(wd.time, "sleep"):
            return wd.fetch_conversation("t", "c1"), calls

    def test_a_dns_blip_is_retried_not_reported_as_unreadable(self):
        out, calls = self.get([urllib.error.URLError("Temporary failure in name resolution"), {"id": "c1"}])
        self.assertEqual((out, len(calls)), ({"id": "c1"}, 2))
        self.assertIn("/conversations/c1?display_as=plaintext", calls[0])

    def test_an_outage_still_surfaces_after_the_last_attempt(self):
        with self.assertRaises(urllib.error.URLError):
            self.get([urllib.error.URLError("down")] * 4)

    def test_not_found_is_not_retried(self):
        with self.assertRaises(urllib.error.HTTPError):
            self.get([urllib.error.HTTPError("u", 404, "gone", None, None), {"id": "c1"}])


class FakeIntercom:
    def __init__(self):
        self.details, self.contacts, self.reads = {}, {}, []
        self.fail_reads, self.gone_reads, self.fail_search = set(), set(), None

    def add(self, cid, parts, updated=NOW, ext=None, **kw):
        d = detail(parts, **kw)
        d.update(id=cid, updated_at=updated)
        self.details[cid] = d
        self.contacts[cid] = [{"type": "contact", "id": "i-" + cid, "external_id": ext}] if ext else []

    def search(self, token):
        if self.fail_search:
            raise self.fail_search
        return [{"id": cid, "state": d["state"], "updated_at": d["updated_at"], "source": d["source"],
                 "statistics": {"last_contact_reply_at": d["created_at"]},
                 "contacts": {"contacts": self.contacts[cid]}}
                for cid, d in self.details.items() if d["state"] in wd.OPEN_STATES]

    def fetch(self, token, cid):
        self.reads.append(cid)
        if cid in self.fail_reads:
            raise urllib.error.URLError("read down")
        if cid in self.gone_reads:
            raise urllib.error.HTTPError("u", 404, "gone", None, None)
        if cid not in self.details:
            raise urllib.error.HTTPError("u", 404, "gone", None, None)
        return self.details[cid]


class Tick(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.ic = FakeIntercom()
        self.posts = []
        self.paying = (frozenset({7}), None)
        self.slack_error = None

        def post(token, channel, text, blocks=None):
            if self.slack_error:
                raise self.slack_error
            self.posts.append("\n".join(b["text"]["text"] for b in blocks))

        def query(sql):
            return [["7", "pro-7", "", "payer@label.example"]]
        for p in (mock.patch.dict(os.environ, {"MUSOAI_INTERCOM_TOKEN": "t",
                                               "UNANSWERED_REPLY_STATE_DIR": self.tmp.name}),
                  mock.patch.object(wd, "fetch_open", self.ic.search),
                  mock.patch.object(wd, "fetch_conversation", self.ic.fetch),
                  mock.patch.object(wd, "resolve_admin_id", lambda: BOT),
                  mock.patch.object(wd, "trino", query),
                  mock.patch.object(wd.decide, "paying_users", lambda path=None: self.paying),
                  mock.patch.object(wd.base, "resolve_slack_token", lambda: "xoxb-test"),
                  mock.patch.object(wd.base, "slack_post", post)):
            p.start()
            self.addCleanup(p.stop)

    def tick(self, at=NOW, dry_run=False):
        self.out, self.err = io.StringIO(), io.StringIO()
        with redirect_stdout(self.out), redirect_stderr(self.err):
            return wd.run(argparse.Namespace(dry_run=dry_run, at=str(at), threshold_hours=wd.THRESHOLD_H))

    def state(self):
        return json.loads(pathlib.Path(self.tmp.name, "state.json").read_text())

    def chased_handoff(self, cid="paid1", **kw):
        self.ic.add(cid, [caroline("p1", NOW - 13 * D, "You'll hear back."), cust("p2", NOW - 30 * H),
                          caroline("p3", NOW - 30 * H + 30), cust("p4", NOW - 29 * H),
                          caroline("p5", NOW - 29 * H + 30)], ext="pro-7", src_ts=NOW - 13 * D - H, **kw)

    def test_paid_first_one_message_with_the_count(self):
        self.ic.add("free1", [cust("p1", NOW - 40 * H)])
        self.chased_handoff()
        self.ic.add("answered", [caroline("p1", NOW - 40 * H, ANSWER)])
        self.ic.add("fresh", [cust("p1", NOW - 2 * H)], ext="pro-7")
        self.assertEqual(self.tick(), 0)
        self.assertEqual(len(self.posts), 1)
        text = self.posts[0]
        self.assertLess(text.index("/conversation/paid1"), text.index("/conversation/free1"))
        self.assertIn("asked again, told again that a teammate would follow up", text)
        self.assertIn("*13 d*", text)
        self.assertNotIn("/conversation/answered", text)
        self.assertNotIn("/conversation/fresh", text)
        self.assertIn("*1 paid*", text)
        self.assertIn("1 free", text)
        latest = json.loads(pathlib.Path(self.tmp.name, "latest.json").read_text())
        self.assertEqual((latest["by_paid"]["paid"], latest["by_paid"]["free"], latest["complete"]), (1, 1, True))
        self.assertNotIn("payer@", json.dumps(self.state()))

    def test_no_second_page_until_the_repeat_is_due_and_unchanged_threads_are_not_re_read(self):
        self.chased_handoff()
        self.tick()
        self.ic.reads.clear()
        self.assertEqual(self.tick(NOW + H), 0)
        self.assertEqual((len(self.posts), self.ic.reads), (1, []))
        self.tick(NOW + 72 * H)
        self.assertEqual(len(self.posts), 2)
        self.assertEqual(self.state()["paged"]["paid1"]["pages"], 2)

    def test_a_first_time_page_ranks_ahead_of_a_repeat(self):
        self.chased_handoff("old")
        self.tick()
        self.ic.add("new", [cust("p1", NOW + 40 * H)], ext="pro-7", src_ts=NOW + 39 * H)
        self.tick(NOW + 72 * H)
        text = self.posts[-1]
        self.assertLess(text.index("/conversation/new"), text.index("/conversation/old"))

    def test_caroline_replying_again_changes_nothing_and_a_human_reply_ends_it(self):
        self.chased_handoff()
        self.tick()
        d = self.ic.details["paid1"]
        d["conversation_parts"]["conversation_parts"] += [cust("p6", NOW + H), caroline("p7", NOW + H + 30)]
        d["updated_at"] = NOW + H + 30
        self.tick(NOW + 2 * H)
        self.assertEqual(len(self.posts), 1)  # same episode: the first unkept promise
        self.assertEqual(self.state()["threads"]["paid1"]["e"], "promise:p1")
        d["conversation_parts"]["conversation_parts"].append(human("p8", NOW + 3 * H))
        d["updated_at"] = NOW + 3 * H
        self.tick(NOW + 80 * H)
        self.assertEqual(len(self.posts), 1)
        self.assertIsNone(self.state()["threads"]["paid1"]["k"])

    def test_closed_without_an_answer_is_reported_once_not_dropped(self):
        self.chased_handoff()
        self.tick()
        self.ic.details["paid1"]["state"] = "closed"
        self.assertEqual(self.tick(NOW + H), 0)
        self.assertEqual(len(self.posts), 2)
        self.assertIn("CLOSED without an answer", self.posts[1])
        self.assertIn("/conversation/paid1", self.posts[1])
        self.tick(NOW + 2 * H)
        self.assertEqual(len(self.posts), 2)
        # the close is reported once, but the thread stays in the published count
        latest = json.loads(pathlib.Path(self.tmp.name, "latest.json").read_text())
        self.assertEqual((latest["total"], latest["closed_unanswered"]), (1, 1))
        self.tick(NOW + 100 * H)
        self.assertEqual(len(self.posts), 3)
        self.assertIn("1 thread(s) still have no answer", self.posts[2])
        latest = json.loads(pathlib.Path(self.tmp.name, "latest.json").read_text())
        self.assertEqual((latest["total"], latest["closed_unanswered"]), (1, 1))
        # past every retention window the close still cannot make the count fall
        self.tick(NOW + 100 * H + wd.PAGED_RETENTION_S + H)
        latest = json.loads(pathlib.Path(self.tmp.name, "latest.json").read_text())
        self.assertEqual((latest["total"], latest["closed_unanswered"]), (1, 1))

    def test_a_changed_paying_email_with_a_failed_refresh_is_unverified_not_free(self):
        self.chased_handoff()
        self.assertEqual(self.tick(), 0)
        st = self.state()
        st["idmap"]["7"][3] = NOW - wd.IDMAP_TTL_S - 1
        pathlib.Path(self.tmp.name, "state.json").write_text(json.dumps(st))
        self.ic.add("newmail", [cust("p1", NOW - 40 * H)], email="new@label.example")

        def broken(sql):
            raise OSError("no trino pod")
        with mock.patch.object(wd, "trino", broken):
            self.assertEqual(self.tick(NOW + wd.IDMAP_TTL_S), 2)
        latest = json.loads(pathlib.Path(self.tmp.name, "latest.json").read_text())
        # neither thread can be matched to a key we could re-verify, so neither is free
        self.assertEqual((latest["by_paid"]["paid"], latest["by_paid"]["unknown"], latest["by_paid"]["free"]),
                         (0, 2, 0))

    def test_a_changed_paying_email_is_picked_up_after_the_ttl(self):
        self.chased_handoff()
        self.tick()
        st = self.state()
        st["idmap"]["7"][3] = NOW - wd.IDMAP_TTL_S - 1
        pathlib.Path(self.tmp.name, "state.json").write_text(json.dumps(st))
        self.ic.add("newmail", [cust("p1", NOW - 40 * H)], email="new@label.example")
        with mock.patch.object(wd, "trino", lambda sql: [["7", "pro-7", "", "new@label.example"]]):
            self.tick(NOW + wd.IDMAP_TTL_S)
        latest = json.loads(pathlib.Path(self.tmp.name, "latest.json").read_text())
        self.assertEqual(latest["by_paid"]["paid"], 2)

    def test_closed_after_a_human_answer_is_dropped_quietly(self):
        self.chased_handoff()
        self.tick()
        d = self.ic.details["paid1"]
        d["conversation_parts"]["conversation_parts"].append(human("p8", NOW + H))
        d["state"] = "closed"
        self.tick(NOW + 2 * H)
        self.assertEqual(len(self.posts), 1)
        self.assertNotIn("paid1", self.state()["threads"])

    def test_closed_thread_that_cannot_be_re_read_is_neither_reported_nor_forgotten(self):
        self.chased_handoff()
        self.tick()
        self.ic.details["paid1"]["state"] = "closed"
        self.ic.fail_reads.add("paid1")
        self.assertEqual(self.tick(NOW + H), 2)
        self.assertEqual(len(self.posts), 1)
        self.assertIn("paid1", self.state()["threads"])
        # a failed re-read is not an answer: the cached owed verdict keeps its place in the
        # published count, and the tick says it is incomplete rather than reporting zero
        latest = json.loads(pathlib.Path(self.tmp.name, "latest.json").read_text())
        self.assertEqual((latest["total"], latest["unresolved_left"], latest["complete"]), (1, 1, False))
        self.assertEqual(latest["by_paid"]["paid"], 1)
        # the count still reaches a person on the daily cadence while it is not zero
        self.assertEqual(self.tick(NOW + 25 * H), 2)
        self.assertIn("still have no answer", self.posts[-1])
        self.assertIn("could not be read this tick", self.posts[-1])
        self.ic.fail_reads.clear()
        self.tick(NOW + 26 * H)
        self.assertIn("CLOSED without an answer", self.posts[-1])
        latest = json.loads(pathlib.Path(self.tmp.name, "latest.json").read_text())
        self.assertEqual((latest["total"], latest["unresolved_left"], latest["complete"]), (1, 0, True))

    def test_a_404_on_an_open_thread_keeps_its_owed_verdict(self):
        self.chased_handoff()
        self.tick()
        self.ic.details["paid1"]["updated_at"] = NOW + H
        self.ic.gone_reads.add("paid1")
        self.assertEqual(self.tick(NOW + H), 2)
        latest = json.loads(pathlib.Path(self.tmp.name, "latest.json").read_text())
        # a 404 is unreadability, not an answer: the cached owed verdict stays in the count
        self.assertEqual((latest["total"], latest["by_paid"]["paid"], latest["unread"], latest["complete"]),
                         (1, 1, 1, False))
        self.assertIn("paid1", self.state()["threads"])

    def test_a_404_on_a_closed_thread_keeps_it_unresolved(self):
        self.chased_handoff()
        self.tick()
        self.ic.details["paid1"]["state"] = "closed"
        self.ic.gone_reads.add("paid1")
        self.assertEqual(self.tick(NOW + H), 2)
        latest = json.loads(pathlib.Path(self.tmp.name, "latest.json").read_text())
        self.assertEqual((latest["total"], latest["unresolved_left"], latest["complete"]), (1, 1, False))
        self.assertIn("paid1", self.state()["threads"])
        self.ic.gone_reads.clear()
        self.tick(NOW + 2 * H)
        self.assertIn("CLOSED without an answer", self.posts[-1])
        latest = json.loads(pathlib.Path(self.tmp.name, "latest.json").read_text())
        self.assertEqual((latest["total"], latest["unresolved_left"], latest["complete"]), (1, 0, True))

    def test_unreadable_thread_keeps_its_verdict_and_fails_the_tick(self):
        self.chased_handoff()
        self.tick()
        self.ic.details["paid1"]["updated_at"] = NOW + H
        self.ic.fail_reads.add("paid1")
        self.assertEqual(self.tick(NOW + 72 * H), 2)
        self.assertEqual(len(self.posts), 2)  # still paged from the verdict it had
        self.assertIn("could not be read this tick", self.posts[1])
        self.assertEqual(json.loads(pathlib.Path(self.tmp.name, "latest.json").read_text())["complete"], False)

    def test_no_paying_list_means_unmeasured_never_free(self):
        self.paying = (None, "paying-users.json is 5.0 h old")
        self.chased_handoff()
        self.assertEqual(self.tick(), 2)
        self.assertIn("paid status unverified", self.posts[0])
        self.assertIn("Paid split incomplete", self.posts[0])
        self.assertIn("1 paid-status unverified", self.posts[0])

    def test_failed_slack_post_records_nothing_so_it_retries(self):
        self.chased_handoff()
        self.slack_error = RuntimeError("Slack chat.postMessage failed: channel_not_found")
        self.assertEqual(self.tick(), 2)
        self.assertEqual(self.state()["paged"], {})
        self.slack_error = None
        self.assertEqual(self.tick(NOW + H), 0)
        self.assertEqual(len(self.posts), 1)

    def test_search_failure_measures_nothing_and_pages_nothing(self):
        self.chased_handoff()
        self.ic.fail_search = urllib.error.URLError("search down")
        self.assertEqual(self.tick(), 2)
        self.assertEqual(self.posts, [])
        self.assertFalse(pathlib.Path(self.tmp.name, "state.json").exists())

    def test_dry_run_posts_nothing_and_writes_nothing(self):
        self.chased_handoff()
        self.assertEqual(self.tick(dry_run=True), 0)
        self.assertEqual(self.posts, [])
        self.assertEqual(os.listdir(self.tmp.name), [])
        snap = json.loads(self.out.getvalue())
        self.assertEqual((snap["by_class"]["paid"][wd.HANDOFF_CHASED], snap["due_now"]), (1, 1))
        self.assertIn("/conversation/paid1", self.err.getvalue())

    def test_nothing_listable_still_puts_the_paid_count_in_front_of_a_person_once_a_day(self):
        self.ic.add("open1", [caroline("p1", NOW - 90 * H)], ext="pro-7")  # promise_open: counted only
        self.assertEqual(self.tick(), 0)
        self.assertEqual(len(self.posts), 1)
        self.assertIn("Nothing new to list, and 1 thread(s) still have no answer", self.posts[0])
        self.assertIn("(*1 paid*)", self.posts[0])
        self.assertIn("*1 paid*", self.posts[0])
        self.assertNotIn("/conversation/", self.posts[0])
        latest = json.loads(pathlib.Path(self.tmp.name, "latest.json").read_text())
        self.assertEqual(latest["by_class"]["paid"][wd.PROMISE_OPEN], 1)
        self.tick(NOW + H)
        self.tick(NOW + 23 * H)
        self.assertEqual(len(self.posts), 1)
        self.tick(NOW + 24 * H)
        self.assertEqual(len(self.posts), 2)

    def test_a_failed_count_post_is_retried_next_tick(self):
        self.ic.add("open1", [caroline("p1", NOW - 90 * H)], ext="pro-7")
        self.slack_error = RuntimeError("Slack chat.postMessage failed: ratelimited")
        self.assertEqual(self.tick(), 2)
        self.slack_error = None
        self.assertEqual(self.tick(NOW + H), 0)
        self.assertEqual(len(self.posts), 1)

    def test_a_free_broken_promise_is_listed_ahead_of_free_silence(self):
        self.ic.add("silent", [cust("p1", NOW - 20 * D)], src_ts=NOW - 20 * D - H)
        self.ic.add("promised", [caroline("p1", NOW - 13 * D, "You'll hear back."),
                                 cust("p2", NOW - 30 * H), caroline("p3", NOW - 30 * H + 30),
                                 cust("p4", NOW - 29 * H), caroline("p5", NOW - 29 * H + 30)],
                    src_ts=NOW - 13 * D - H)
        self.assertEqual(self.tick(), 0)
        text = self.posts[0]
        self.assertIn("/conversation/promised", text)
        self.assertIn("/conversation/silent", text)
        self.assertLess(text.index("/conversation/promised"), text.index("/conversation/silent"))

    def test_free_only_backlog_still_reaches_a_person(self):
        self.ic.add("open1", [caroline("p1", NOW - 90 * H)])  # free promise_open
        self.ic.add("old", [cust("p1", NOW - 9 * D)], src_ts=NOW - 9 * D - H)  # free, past 7 days
        self.assertEqual(self.tick(), 0)
        self.assertEqual(len(self.posts), 1)
        self.assertIn("/conversation/old", self.posts[0])
        self.assertIn("2 free", self.posts[0])
        latest = json.loads(pathlib.Path(self.tmp.name, "latest.json").read_text())
        self.assertEqual(latest["by_paid"]["free"], 2)
        self.tick(NOW + H)
        self.assertEqual(len(self.posts), 1)
        self.tick(NOW + 7 * D)
        self.assertEqual(len(self.posts), 2)

    def test_an_unmapped_paying_account_makes_unmatched_threads_unverified_not_free(self):
        self.paying = (frozenset({7, 8}), None)  # the replica only answers for 7
        self.ic.add("free1", [cust("p1", NOW - 40 * H)])
        self.chased_handoff()
        self.assertEqual(self.tick(), 2)
        text = self.posts[0]
        self.assertIn("/conversation/free1", text)
        self.assertIn("paid status unverified", text)
        self.assertIn("1 of 2 paying accounts could not be matched", text)
        self.assertIn("0 free", text)
        latest = json.loads(pathlib.Path(self.tmp.name, "latest.json").read_text())
        self.assertEqual((latest["by_paid"]["paid"], latest["by_paid"]["free"],
                          latest["by_paid"]["unknown"]), (1, 0, 1))

    def test_unknown_state_shape_is_never_overwritten(self):
        p = pathlib.Path(self.tmp.name, "state.json")
        p.write_text('{"watch": {}}')
        self.chased_handoff()
        self.assertEqual(self.tick(), 1)
        self.assertEqual((p.read_text(), self.posts), ('{"watch": {}}', []))

class ReadOnly(unittest.TestCase):
    def test_a_full_tick_only_reads_intercom(self):
        calls = []
        conv = detail([cust("p1", NOW - 40 * H)])
        conv.update(id="c1", updated_at=NOW)
        before = json.loads(json.dumps(conv))

        class Resp(io.BytesIO):
            def __enter__(self):
                return self

            def __exit__(self, *a):
                return False

        def urlopen(req, timeout=None):
            calls.append((req.get_method(), req.full_url))
            return Resp(json.dumps(conv).encode())

        def search(token, body):
            calls.append(("POST", wd.base.INTERCOM_API + "/conversations/search"))
            return {"conversations": [{"id": "c1", "state": "open", "updated_at": NOW,
                                       "source": conv["source"],
                                       "statistics": {"last_contact_reply_at": conv["created_at"]},
                                       "contacts": {"contacts": []}}]}

        with tempfile.TemporaryDirectory() as tmp, \
                mock.patch.dict(os.environ, {"MUSOAI_INTERCOM_TOKEN": "t",
                                             "UNANSWERED_REPLY_STATE_DIR": tmp}), \
                mock.patch.object(wd.base, "_intercom_search", search), \
                mock.patch.object(wd.urllib.request, "urlopen", urlopen), \
                mock.patch.object(wd, "resolve_admin_id", lambda: BOT), \
                mock.patch.object(wd.decide, "paying_users", lambda path=None: (frozenset(), None)):
            rc = wd.run(argparse.Namespace(dry_run=True, at=str(NOW), threshold_hours=wd.THRESHOLD_H))
        self.assertEqual(rc, 0)
        self.assertEqual(calls[0], ("POST", wd.base.INTERCOM_API + "/conversations/search"))
        self.assertTrue(calls[1:])
        for method, url in calls[1:]:
            self.assertEqual(method, "GET", url)
            self.assertEqual(url, wd.base.INTERCOM_API + "/conversations/c1?display_as=plaintext")
        self.assertEqual(conv, before)


if __name__ == "__main__":
    unittest.main()
