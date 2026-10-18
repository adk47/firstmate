"""Behavioral tests for scripts/intercom-legal-unanswered-watchdog.py (firstmate 766, 2026-10-17).

Two GDPR erasure requests (received 6 and 7 Oct) sat 9-10 days: Caroline answered, no human
did, nothing noticed. These tests lock:
  - only a HUMAN admin reply after the customer's latest message counts as answered;
    Caroline's replies and internal notes never do;
  - a new customer message starts a new episode; re-pages are spaced REPAGE hours;
  - keywords are word-anchored data, not code ("my legal name" does not page);
  - a backlog is ONE Slack message, split into sections without cutting any item;
  - a request made in a LATER customer message is caught (not only the opening one);
  - the persistent watch set keeps re-paging a request nobody touches, long after it left
    the search window, and drops it once a human answers or it is closed;
  - the discovery cursor advances whenever the search completed: a candidate that cannot be
    read goes to a retry set, is re-read first, and after 3 failed ticks is paged as
    "could not read"; a fetch cap that leaves work undone exits non-zero and resumes;
  - a search, read, or Slack post that dies mid-body (timeout, IncompleteRead) is an error,
    not a crash, and the ledger is still saved;
  - an unreadable spell never resets a customer message's 48 h re-page clock;
  - a watched conversation that cannot be read never holds back discovery, is never dropped,
    and after 3 failed ticks in a row is paged as unreadable (48 h spacing);
  - discovery and the watch set have separate read caps, so neither starves the other;
  - a ledger of unrecognised shape is a hard error and is never overwritten;
  - --dry-run honours the ledger unless --at is also given.
Stdlib unittest only, no network: Intercom and Slack are in-memory fakes.
"""
import argparse
import http.client
import importlib.util
import json
import os
import pathlib
import tempfile
import unittest
import urllib.error
from unittest import mock

_SCRIPT = pathlib.Path(__file__).resolve().parent.parent / "scripts" / "intercom-legal-unanswered-watchdog.py"
_spec = importlib.util.spec_from_file_location("intercom_legal_unanswered_watchdog", _SCRIPT)
wd = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(wd)
REAL_SLACK_POST = wd.base.slack_post

BOT = "5763097"
H = 3600
NOW = 2_000_000_000


def part(pid, ts, author_type, author_id="u1", body="text", part_type="comment"):
    return {"id": pid, "created_at": ts, "author": {"type": author_type, "id": author_id},
            "body": body, "part_type": part_type}


def detail(parts, src_ts=NOW - 100 * H):
    return {"created_at": src_ts, "source": {"id": "src", "author": {"type": "lead", "id": "u1"}, "body": "GDPR erasure"},
            "conversation_parts": {"conversation_parts": parts}}


class Episode(unittest.TestCase):
    def test_caroline_reply_does_not_count(self):
        d = detail([part("p1", NOW - 90 * H, "admin", BOT)])
        self.assertEqual(wd.unanswered_episode(d, BOT), (NOW - 100 * H, "src"))

    def test_note_does_not_count(self):
        d = detail([part("p1", NOW - 90 * H, "admin", "999", part_type="note")])
        self.assertIsNotNone(wd.unanswered_episode(d, BOT))

    def test_human_reply_after_customer_clears_it(self):
        d = detail([part("p1", NOW - 90 * H, "admin", "999")])
        self.assertIsNone(wd.unanswered_episode(d, BOT))

    def test_customer_follow_up_after_human_reopens_it(self):
        # the Soggy shape: Jan replied, the customer asked again, nobody answered
        d = detail([part("p1", NOW - 90 * H, "admin", "999"), part("p2", NOW - 80 * H, "user")])
        self.assertEqual(wd.unanswered_episode(d, BOT), (NOW - 80 * H, "p2"))

    def test_no_customer_message(self):
        d = {"created_at": NOW, "source": {"author": {"type": "admin", "id": "999"}, "body": "hi"},
             "conversation_parts": {"conversation_parts": []}}
        self.assertIsNone(wd.unanswered_episode(d, BOT))


class Paging(unittest.TestCase):
    def test_threshold(self):
        self.assertFalse(wd.should_page("c", (NOW - 23 * H, "p"), NOW, {}))
        self.assertTrue(wd.should_page("c", (NOW - 25 * H, "p"), NOW, {}))

    def test_repage_spacing_and_new_episode(self):
        ledger = {"c": {"episode": "p", "last_paged": NOW - 10 * H}}
        self.assertFalse(wd.should_page("c", (NOW - 30 * H, "p"), NOW, ledger))
        ledger["c"]["last_paged"] = NOW - 49 * H
        self.assertTrue(wd.should_page("c", (NOW - 80 * H, "p"), NOW, ledger))
        ledger["c"]["last_paged"] = NOW - 1 * H
        self.assertTrue(wd.should_page("c", (NOW - 25 * H, "p-new"), NOW, ledger))


class Keywords(unittest.TestCase):
    def setUp(self):
        self.kw = wd.load_keywords()

    def conv(self, subject="", body="", author="lead"):
        return {"source": {"subject": subject, "body": body, "author": {"type": author}}}

    def test_hits(self):
        for text in ("GDPR Request for Complete Erasure", "Please delete my personal data",
                     "data deletion request", "Cease and desist", "Right to be forgotten",
                     "Article 17 request", "DMCA notice", "our legal team"):
            self.assertIsNotNone(wd.matches(self.conv(body=text), self.kw), text)

    def test_misses(self):
        for text in ("my legal name is shown", "please delete this track credit", "I need my data to update"):
            self.assertIsNone(wd.matches(self.conv(body=text), self.kw), text)

    def test_outbound_never_matches(self):
        self.assertIsNone(wd.matches(self.conv(body="GDPR", author="admin"), self.kw))

    def test_request_in_a_later_customer_message_matches(self):
        d = {"source": {"subject": "", "body": "hi", "author": {"type": "user"}},
             "conversation_parts": {"conversation_parts": [
                 part("p1", NOW - 5 * H, "admin", BOT, body="How can I help?"),
                 part("p2", NOW - 4 * H, "user", body="please delete my account and all my data")]}}
        self.assertIsNotNone(wd.matches(d, self.kw))

    def test_our_own_later_message_never_matches(self):
        d = {"source": {"subject": "", "body": "hi", "author": {"type": "user"}},
             "conversation_parts": {"conversation_parts": [
                 part("p1", NOW - 5 * H, "admin", BOT, body="See our GDPR policy")]}}
        self.assertIsNone(wd.matches(d, self.kw))


class Rendering(unittest.TestCase):
    def test_one_message_oldest_first_and_no_item_cut(self):
        due = []
        for i in range(30):
            c = {"id": f"c{i}", "created_at": NOW - 500 * H, "source": {"subject": f"GDPR erasure {i}" + "x" * 80}}
            due.append((c, "GDPR", (NOW - (30 + i) * H, f"p{i}")))
        text = wd.render(due, NOW, ["U038BM16T7W"], "dwjzhcge")
        self.assertTrue(text.startswith("<@U038BM16T7W>"))
        self.assertLess(text.index("59 h"), text.index("30 h"))
        blocks = wd.blocks_for(text)
        self.assertTrue(all(len(b["text"]["text"]) <= 2900 for b in blocks))
        joined = "\n".join(b["text"]["text"] for b in blocks)
        for i in range(30):
            self.assertIn(f"/conversation/c{i}", joined)


def conv(cid, updated, parts, opening="hi", subject="", state="open", created=None):
    return {"id": cid, "state": state, "updated_at": updated,
            "created_at": created if created is not None else updated,
            "source": {"id": "src", "subject": subject, "body": opening,
                       "author": {"type": "user", "id": "u1"}},
            "conversation_parts": {"conversation_parts": parts}}


class FakeIntercom:
    def __init__(self):
        self.convs = {}
        self.searches = []
        self.reads = []
        self.fail_reads = set()
        self.read_error = urllib.error.URLError("read down")
        self.fail_search = None

    def add(self, c):
        self.convs[c["id"]] = c

    def search(self, token, start, end):
        self.searches.append((start, end))
        if self.fail_search:
            raise self.fail_search
        return [json.loads(json.dumps(c)) for c in self.convs.values()
                if start < c["updated_at"] < end]

    def fetch(self, token, cid):
        self.reads.append(cid)
        if cid in self.fail_reads:
            raise self.read_error
        if cid not in self.convs:
            raise urllib.error.HTTPError("u", 404, "not found", None, None)
        return json.loads(json.dumps(self.convs[cid]))


class Tick(unittest.TestCase):
    """Drives run() end to end against fake Intercom + Slack and a real ledger file."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.ledger = os.path.join(self.tmp.name, "seen.json")
        self.ic = FakeIntercom()
        self.posts = []
        self.slack_fail = False

        def post(token, channel, text, blocks=None):
            if self.slack_fail:
                raise RuntimeError("slack down")
            self.posts.append("\n".join(b["text"]["text"] for b in blocks))

        for p in (mock.patch.dict(os.environ, {"MUSOAI_INTERCOM_TOKEN": "t",
                                               "LEGAL_UNANSWERED_LEDGER_PATH": self.ledger}),
                  mock.patch.object(wd.base, "fetch_updated_between", self.ic.search),
                  mock.patch.object(wd, "fetch_conversation", self.ic.fetch),
                  mock.patch.object(wd, "resolve_admin_id", lambda: BOT),
                  mock.patch.object(wd.base, "resolve_slack_token", lambda: "xoxb-test"),
                  mock.patch.object(wd.base, "slack_post", post)):
            p.start()
            self.addCleanup(p.stop)
        self.addCleanup(self.tmp.cleanup)

    def tick(self, at):
        return wd.run(argparse.Namespace(dry_run=False, at=str(at)))

    def _dry_now(self, at):
        """--dry-run with NO --at, with the clock pinned to `at`."""
        with mock.patch.object(wd.base, "_epoch", lambda v: at):
            return wd.run(argparse.Namespace(dry_run=True, at=None))

    def state(self):
        with open(self.ledger) as f:
            return json.load(f)

    def test_later_message_request_pages_after_24h(self):
        self.ic.add(conv("c1", NOW - 30 * H, [
            part("p1", NOW - 31 * H, "admin", BOT, body="Hi! How can I help?"),
            part("p2", NOW - 30 * H, "user", body="this is a GDPR request, erase everything")],
            created=NOW - 32 * H))
        self.assertEqual(self.tick(NOW), 0)
        self.assertEqual(len(self.posts), 1)
        self.assertIn("/conversation/c1", self.posts[0])
        self.assertIn("c1", self.state()["watch"])

    def test_watch_set_repages_after_the_search_window_forgets_it(self):
        self.ic.add(conv("c1", NOW - 30 * H, [], opening="GDPR erasure please"))
        self.assertEqual(self.tick(NOW), 0)
        self.assertEqual(len(self.posts), 1)
        # 46 days of silence: no search can return it any more, it must still page
        for hours in (10, 49, 46 * 24):
            self.tick(NOW + hours * H)
        self.assertEqual(len(self.posts), 3)
        self.assertNotIn("c1", [c["id"] for c in self.ic.search("t", *self.ic.searches[-1])])
        self.assertEqual(self.state()["paged"]["c1"]["pages"], 3)

    def test_human_reply_or_close_drops_it_and_a_customer_follow_up_re_adds_it(self):
        self.ic.add(conv("c1", NOW - 30 * H, [], opening="delete my personal data"))
        self.ic.add(conv("c2", NOW - 30 * H, [], opening="cease and desist"))
        self.tick(NOW)
        c1 = self.ic.convs["c1"]
        c1["conversation_parts"]["conversation_parts"].append(part("h1", NOW + 1 * H, "admin", "999"))
        c1["updated_at"] = NOW + 1 * H
        self.ic.convs["c2"]["state"] = "closed"
        self.tick(NOW + 2 * H)
        self.assertEqual(self.state()["watch"], {})
        c1["conversation_parts"]["conversation_parts"].append(part("p9", NOW + 3 * H, "user", body="still waiting"))
        c1["updated_at"] = NOW + 3 * H
        self.tick(NOW + 4 * H)
        self.assertIn("c1", self.state()["watch"])
        self.tick(NOW + 28 * H)
        self.assertEqual(len(self.posts), 2)
        self.assertIn("/conversation/c1", self.posts[1])

    def test_cursor_starts_at_the_lookback_then_follows_each_tick(self):
        self.ic.add(conv("c1", NOW - 30 * H, [], opening="credit question"))
        self.assertEqual(self.tick(NOW), 0)
        self.assertEqual(self.ic.searches[0][0], NOW - wd.LOOKBACK_DAYS * 86400)
        self.assertEqual(self.state()["scan_from"], NOW - 2 * H)
        self.assertEqual(self.tick(NOW + 2 * H), 0)
        self.assertEqual(self.ic.searches[1][0], NOW - 2 * H)
        self.assertEqual(self.state()["scan_from"], NOW)

    def test_cursor_advances_past_an_unreadable_candidate_which_is_retried_first(self):
        self.tick(NOW)
        self.ic.add(conv("x", NOW + 30 * 60, [], opening="please delete my personal data"))
        self.ic.fail_reads.add("x")
        self.assertEqual(self.tick(NOW + H), 2)
        s = self.state()
        self.assertEqual(s["scan_from"], NOW - H)
        self.assertEqual(s["retry"]["x"], {"failures": 1, "first_failed": NOW + H})
        self.assertEqual(self.tick(NOW + 6 * H), 2)
        self.assertEqual(self.state()["scan_from"], NOW + 4 * H)
        self.ic.fail_reads.clear()
        self.ic.reads.clear()
        self.assertEqual(self.tick(NOW + 7 * H), 0)
        self.assertNotIn("x", [c["id"] for c in self.ic.search("t", *self.ic.searches[-1])])
        self.assertEqual(self.ic.reads, ["x"])
        s = self.state()
        self.assertEqual(s["retry"], {})
        self.assertIn("x", s["watch"])

    def test_unreadable_candidate_is_paged_after_3_failed_ticks_every_48h(self):
        self.ic.add(conv("x", NOW - 30 * 60, [], opening="hello"))
        self.ic.fail_reads.add("x")
        for hours in (0, 1):
            self.assertEqual(self.tick(NOW + hours * H), 2)
        self.assertEqual(self.posts, [])
        self.assertEqual(self.tick(NOW + 2 * H), 2)
        self.assertEqual(len(self.posts), 1)
        self.assertIn("could not read to check for a legal request* (3 ticks)", self.posts[0])
        self.assertIn("/conversation/x", self.posts[0])
        self.assertEqual(self.tick(NOW + 3 * H), 2)
        self.assertEqual(len(self.posts), 1)
        self.tick(NOW + 50 * H)
        self.assertEqual(len(self.posts), 2)
        self.assertIn("(5 ticks)", self.posts[1])

    def test_search_failure_still_pages_the_watch_set_but_keeps_the_cursor(self):
        self.ic.add(conv("c1", NOW - 30 * H, [], opening="GDPR"))
        self.tick(NOW)
        for n, exc in enumerate((urllib.error.URLError("down"), TimeoutError("timed out"),
                                 ConnectionResetError("reset"), http.client.IncompleteRead(b"")), 1):
            self.ic.fail_search = exc
            self.assertEqual(self.tick(NOW + n * 49 * H), 2, exc)
            self.assertEqual(len(self.posts), n + 1, exc)
            self.assertEqual(self.state()["scan_from"], NOW - 2 * H, exc)

    def test_unreadable_spell_keeps_the_episode_repage_clock(self):
        self.ic.add(conv("c1", NOW - 30 * H, [], opening="GDPR"))
        self.tick(NOW)
        self.ic.read_error = http.client.IncompleteRead(b"")
        self.ic.fail_reads.add("c1")
        for hours in (1, 2, 3):
            self.assertEqual(self.tick(NOW + hours * H), 2)
        self.assertEqual(len(self.posts), 2)
        self.assertIn("unreadable for 3 ticks", self.posts[1])
        self.ic.fail_reads.clear()
        self.assertEqual(self.tick(NOW + 4 * H), 0)
        self.assertEqual(len(self.posts), 2)
        self.assertEqual(self.state()["paged"]["c1"]["last_paged"], NOW)
        self.assertEqual(self.state()["paged"]["c1"]["pages"], 1)
        self.tick(NOW + 47 * H)
        self.assertEqual(len(self.posts), 2)
        self.tick(NOW + 48 * H)
        self.assertEqual(len(self.posts), 3)
        self.assertEqual(self.state()["paged"]["c1"]["pages"], 2)

    def test_fetch_cap_exits_non_zero_and_resumes_where_it_stopped(self):
        for i in range(5):
            self.ic.add(conv(f"c{i}", NOW - (40 - i) * H, [], opening="GDPR" if i == 4 else "hi"))
        with mock.patch.object(wd, "MAX_SCAN_FETCHES", 3):
            self.assertEqual(self.tick(NOW), 2)
            self.assertEqual(self.state()["scan_from"], NOW - 37 * H - 1)
            self.assertEqual(self.posts, [])
            self.assertEqual(self.tick(NOW + H), 0)
        self.assertEqual(sorted(self.ic.reads), ["c0", "c1", "c2", "c3", "c4"])
        self.assertEqual(len(self.posts), 1)
        self.assertIn("/conversation/c4", self.posts[0])

    def test_slack_failure_keeps_the_watch_set_and_retries_the_page(self):
        self.ic.add(conv("c1", NOW - 30 * H, [], opening="GDPR"))
        self.slack_fail = True
        self.assertEqual(self.tick(NOW), 2)
        self.assertIn("c1", self.state()["watch"])
        self.assertEqual(self.state()["paged"], {})
        self.slack_fail = False
        self.assertEqual(self.tick(NOW + H), 0)
        self.assertEqual(len(self.posts), 1)

    def test_slack_response_cut_mid_body_still_saves_the_ledger(self):
        self.ic.add(conv("c1", NOW - 30 * H, [], opening="GDPR"))
        resp = mock.MagicMock()
        resp.__enter__.return_value.read.side_effect = http.client.IncompleteRead(b'{"ok":')
        with mock.patch.object(wd.base, "slack_post", REAL_SLACK_POST), \
                mock.patch.object(wd.base.urllib.request, "urlopen", return_value=resp):
            self.assertEqual(self.tick(NOW), 2)
        s = self.state()
        self.assertIn("c1", s["watch"])
        self.assertEqual(s["paged"], {})
        self.assertEqual(s["scan_from"], NOW - 2 * H)

    def test_watch_read_error_does_not_hold_back_discovery(self):
        self.ic.add(conv("c1", NOW - 30 * H, [], opening="GDPR"))
        self.tick(NOW)
        self.ic.fail_reads.add("c1")
        self.ic.add(conv("c2", NOW + 30 * 60, [], opening="DMCA notice"))
        self.assertEqual(self.tick(NOW + H), 2)
        s = self.state()
        self.assertEqual(s["scan_from"], NOW - H)
        self.assertEqual(s["watch"]["c1"]["failures"], 1)
        self.assertIn("c2", s["watch"])

    def test_unreadable_watched_conversation_pages_after_3_failed_ticks(self):
        self.ic.add(conv("c1", NOW - 30 * H, [], opening="GDPR"))
        self.tick(NOW)
        self.ic.fail_reads.add("c1")
        for hours in (1, 2):
            self.assertEqual(self.tick(NOW + hours * H), 2)
        self.assertEqual(len(self.posts), 1)
        self.assertEqual(self.tick(NOW + 3 * H), 2)
        self.assertEqual(len(self.posts), 2)
        self.assertIn("unreadable for 3 ticks", self.posts[1])
        self.assertIn("/conversation/c1", self.posts[1])
        self.tick(NOW + 4 * H)
        self.assertEqual(len(self.posts), 2)
        self.tick(NOW + 51 * H)
        self.assertEqual(len(self.posts), 3)
        self.assertIn("unreadable for 5 ticks", self.posts[2])
        self.ic.fail_reads.clear()
        self.assertEqual(self.tick(NOW + 52 * H), 0)
        self.assertNotIn("failures", self.state()["watch"]["c1"])
        self.assertNotIn("unreadable", self.posts[-1])

    def test_watch_set_cannot_starve_discovery(self):
        self.ic.add(conv("c0", NOW - 30 * H, [], opening="GDPR"))
        self.ic.add(conv("c1", NOW - 30 * H, [], opening="erasure"))
        self.tick(NOW)
        self.ic.add(conv("d0", NOW + 20 * 60, [], opening="hi"))
        self.ic.add(conv("d1", NOW + 40 * 60, [], opening="DMCA notice"))
        self.ic.reads.clear()
        with mock.patch.object(wd, "MAX_SCAN_FETCHES", 2), mock.patch.object(wd, "MAX_WATCH_FETCHES", 1):
            self.assertEqual(self.tick(NOW + H), 2)
            self.assertEqual(self.ic.reads[:2], ["d0", "d1"])
            self.assertEqual(len(self.ic.reads), 3)
            first = self.ic.reads[2]
            self.assertEqual(self.state()["scan_from"], NOW - H)
            self.assertIn("d1", self.state()["watch"])
            self.ic.reads.clear()
            self.tick(NOW + 2 * H)
        self.assertEqual(self.ic.reads, ["d0", ({"c0", "c1"} - {first}).pop()])

    def test_unrecognised_ledger_is_a_hard_error_and_left_untouched(self):
        self.ic.add(conv("c1", NOW - 30 * H, [], opening="GDPR"))
        flat = '{"c1": {"episode": "src", "last_paged": 1, "matched": "GDPR"}}'
        for bad in (flat, "not json", '{"watch": []}'):
            with open(self.ledger, "w") as f:
                f.write(bad)
            self.assertEqual(self.tick(NOW), 1)
            with open(self.ledger) as f:
                self.assertEqual(f.read(), bad)
        self.assertEqual(self.ic.searches, [])
        self.assertEqual(self.posts, [])

    def test_dry_run_honours_the_ledger_unless_at_is_given(self):
        self.ic.add(conv("c1", NOW - 30 * H, [], opening="GDPR"))
        self.tick(NOW)
        before = self.state()
        with mock.patch("sys.stdout") as out:
            self.assertEqual(self._dry_now(NOW + H), 0)
        self.assertEqual("".join(c.args[0] for c in out.write.call_args_list).strip(), "")
        with mock.patch("sys.stdout") as out:
            self.assertEqual(wd.run(argparse.Namespace(dry_run=True, at=str(NOW + H))), 0)
        self.assertIn('"conv_id": "c1"', "".join(c.args[0] for c in out.write.call_args_list))
        self.assertEqual(self.state(), before)
        self.assertEqual(len(self.posts), 1)


if __name__ == "__main__":
    unittest.main()
