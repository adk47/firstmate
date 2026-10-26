"""Behavioral tests for scripts/legal-intake.py (notices@ / legal@ intake -> #cs_priority page).

2026-10-23 (MUS-18475 / MUS-18508, Jan Delmo via Buzz): one DMCA notice sent from two
addresses (david@demandage.com and demandage@gmail.com, 36 s apart, same four Muso profiles)
paged #cs_priority twice, the page showed only "(@demandage.com)" instead of the sender's
address, and it tagged Nick although Jan owns legal intake. These tests lock:

  - the page shows the full sender address (angle brackets escaped), like the rights-holder page;
  - the page tags Jan only;
  - the same notice from a second address is collapsed to a threaded reply (tagging Jan to confirm, MUS-20040) under
    the first page, ONLY when Muso ids link the two (no ids = two unrelated takedowns);
  - the ledger stores a hash of the subject, never the subject.

Hermetic: google client libraries are stubbed in sys.modules before the module loads, Gmail and
Slack are fakes, the ledger lives in a temp dir. Never skipped.
"""
import base64
import importlib.util
import json
import os
import pathlib
import sys
import tempfile
import types
import unittest

for _name in ("google", "google.oauth2", "google.oauth2.service_account",
              "googleapiclient", "googleapiclient.discovery"):
    sys.modules.setdefault(_name, types.ModuleType(_name))
sys.modules["google.oauth2"].service_account = sys.modules["google.oauth2.service_account"]
sys.modules["googleapiclient.discovery"].build = lambda *a, **k: None

_SCRIPT = pathlib.Path(__file__).resolve().parent.parent / "scripts" / "legal-intake.py"
_spec = importlib.util.spec_from_file_location("legal_intake", _SCRIPT)
li = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(li)

# Real fixtures from the live ledger (legal@:1a16724626a9c50f / :1a16724ec8f18019).
PROFILES = ("7ea2bc87", "a9126433", "c0f0a65e", "e42f2131")
BODY = "Please remove: " + " ".join(f"https://muso.ai/profile/{p}-aaaa" for p in PROFILES)
SUBJECT = "DMCA Notice"
FIRST_MSG = 1761000000000


def thread(frm, subject=SUBJECT, body=BODY, internal=FIRST_MSG):
    data = base64.urlsafe_b64encode(body.encode()).decode()
    return {"messages": [{"internalDate": str(internal), "payload": {
        "mimeType": "text/plain", "body": {"data": data},
        "headers": [{"name": "From", "value": frm}, {"name": "Subject", "value": subject}]}}]}


class FakeGmail:
    def __init__(self, threads):
        self.data = threads

    def users(self):
        return self

    def messages(self):
        return self

    def threads(self):
        return self

    def labels(self):
        return self

    def list(self, **kw):
        self._r = {"messages": [{"threadId": t} for t in self.data]}
        return self

    def get(self, userId, id, format):
        self._r = self.data[id]
        return self

    def execute(self):
        return self._r


class Harness(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        home = self.tmp.name
        self.saved = {k: getattr(li, k) for k in
                      ("HOME", "LEDGER", "REGISTER_IDS", "ACK_START", "PAGE_START", "BOXES",
                       "svc", "slack_token", "post_page")}
        li.HOME, li.LEDGER = home, f"{home}/ledger.json"
        li.REGISTER_IDS, li.ACK_START = f"{home}/register-ids.txt", f"{home}/ack-start.txt"
        li.PAGE_START = f"{home}/page-start.txt"
        pathlib.Path(li.PAGE_START).write_text("1")
        li.BOXES = [("kyran@muso.ai", "legal@muso.ai")]
        li.slack_token = lambda: "xoxb-test"
        self.posts = []

        def fake_post(token, text_, thread_ts=None):
            self.posts.append({"text": text_, "thread_ts": thread_ts})
            return f"1761000{len(self.posts):03d}.000100"
        li.post_page = fake_post
        self.addCleanup(lambda: [setattr(li, k, v) for k, v in self.saved.items()])

    def run_intake(self, threads, args=("--page",), code=0):
        li.svc = lambda subject, scope: FakeGmail(threads)
        argv, sys.argv = sys.argv, ["legal-intake.py", *args]
        try:
            with self.assertRaises(SystemExit) as cm:
                li.main()
        finally:
            sys.argv = argv
        self.assertEqual(cm.exception.code, code)
        return json.load(open(li.LEDGER))


class Page(unittest.TestCase):
    def render(self, frm):
        h0 = {"from": frm, "subject": SUBJECT}
        return li.page_text("legal@muso.ai", "dmca_takedown", h0, ["profile:7ea2bc87"], {"thread": "t1"})

    def test_page_shows_full_sender_address(self):
        t = self.render("David E Sarabia <david@demandage.com>")
        self.assertIn("David E Sarabia &lt;david@demandage.com&gt;", t)
        self.assertNotIn("(@demandage.com)", t)

    def test_page_shows_bare_address_when_no_display_name(self):
        self.assertIn("From: demandage@gmail.com\n", self.render("demandage@gmail.com"))

    def test_long_display_name_never_pushes_address_off_the_page(self):
        t = self.render("X" * 300 + " <david@demandage.com>")
        self.assertIn("&lt;david@demandage.com&gt;", t)

    def test_page_mentions_jan_only(self):
        t = self.render("David E Sarabia <david@demandage.com>")
        self.assertIn("<@U038BM16T7W>", t)
        self.assertNotIn("<@U0AL36NADEY>", t)


class NoticeKey(unittest.TestCase):
    def test_subject_normalisation(self):
        ids = ["profile:7ea2bc87"]
        base = li.notice_key("dmca_takedown", "DMCA Notice", ids)
        self.assertEqual(base, li.notice_key("dmca_takedown", "Re: Fwd: DMCA Notice", ids))
        self.assertEqual(base, li.notice_key("dmca_takedown", "  RE: re:  dmca   notice ", ids))
        self.assertNotEqual(base, li.notice_key("privacy_erasure", "DMCA Notice", ids))
        self.assertNotEqual(base, li.notice_key("dmca_takedown", "DMCA Notice", ["profile:00000000"]))


class Collapse(Harness):
    def two_threads(self, body2=BODY):
        return {"a1": thread("David E Sarabia <david@demandage.com>"),
                "b2": thread("demandage@gmail.com", body=body2, internal=FIRST_MSG + 36000)}

    def test_collapse_same_notice_two_addresses(self):
        led = self.run_intake(self.two_threads())
        self.assertEqual(len(self.posts), 2)  # one real page + one threaded note
        first_ts = led["legal@muso.ai:a1"]["paged"]
        self.assertEqual(led["legal@muso.ai:b2"]["paged"], "dup-of:" + first_ts)
        note = self.posts[1]
        self.assertEqual(note["thread_ts"], first_ts)
        self.assertIn("<@U038BM16T7W>", note["text"])  # MUS-20040: the note is actionable, Jan is told
        self.assertNotIn("<@U0AL36NADEY>", note["text"])
        self.assertIn("demandage@gmail.com", note["text"])
        self.assertIn("david@demandage.com", note["text"])
        self.assertIn("b2", note["text"])  # Gmail thread id
        self.assertIn("a1", note["text"])
        self.assertIsNone(self.posts[0]["thread_ts"])

    def test_collapse_note_is_actionable_for_a_different_rights_holder(self):
        """MUS-20040 / hydra#1361 bot round 2: same class + subject + ids can still be two rights
        holders. The collapse stays (no second top-level page) but the threaded note must tell Jan
        to confirm, name both senders and both Gmail threads, and never say nothing is needed
        ("or keep the second page actionable when identity is uncertain")."""
        led = self.run_intake({
            "a1": thread("Rights Holder A <claims@labela.com>"),
            "b2": thread("Other Owner <legal@labelb.org>", body=BODY + "\nWe are a different company.",
                         internal=FIRST_MSG + 36000)})
        first_ts = led["legal@muso.ai:a1"]["paged"]
        self.assertEqual(led["legal@muso.ai:b2"]["paged"], "dup-of:" + first_ts)
        notes = [p for p in self.posts if p["thread_ts"]]
        self.assertEqual(len(notes), 1)
        self.assertEqual(notes[0]["thread_ts"], first_ts)
        text = notes[0]["text"]
        self.assertIn("<@U038BM16T7W>", text)
        self.assertNotIn("<@U0AL36NADEY>", text)
        self.assertIn("claims@labela.com", text)
        self.assertIn("legal@labelb.org", text)
        self.assertIn("a1", text)
        self.assertIn("b2", text)
        self.assertNotIn("no new action needed", text)

    def test_no_collapse_when_ids_empty(self):
        no_ids = "Please take down my song"
        led = self.run_intake({"a1": thread("a@x.com", body=no_ids),
                               "b2": thread("b@y.com", body=no_ids, internal=FIRST_MSG + 36000)})
        self.assertEqual(len(self.posts), 2)
        for k in ("legal@muso.ai:a1", "legal@muso.ai:b2"):
            self.assertFalse(str(led[k]["paged"]).startswith("dup-of"))
        self.assertTrue(all(p["thread_ts"] is None for p in self.posts))

    def _post_failing_threads(self, top_level_ok=True):
        """Slack fake: every threaded post raises; top-level posts succeed only if top_level_ok."""
        def post(token, text_, thread_ts=None):
            self.posts.append({"text": text_, "thread_ts": thread_ts})
            if thread_ts or not top_level_ok:
                raise RuntimeError("slack down")
            return f"1761000{len(self.posts):03d}.000100"
        li.post_page = post

    def test_failed_threaded_note_falls_back_to_a_full_page(self):
        """MUS-20075 / hydra#1361 bot round 3: a failed note must never be ledgered as paged
        (the note is the only actionable signal for a possibly-different rights holder), so the
        thread gets a full top-level page instead of going permanently silent."""
        self._post_failing_threads()
        import contextlib, io
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            led = self.run_intake(self.two_threads())
        paged = led["legal@muso.ai:b2"]["paged"]
        self.assertFalse(str(paged).startswith("dup-of"))
        self.assertRegex(paged, r"^\d+\.\d+$")
        top = [p for p in self.posts if p["thread_ts"] is None]
        self.assertEqual(len(top), 2)  # first page + the fallback page for b2
        self.assertIn("demandage@gmail.com", top[1]["text"])
        self.assertIn("<@U038BM16T7W>", top[1]["text"])
        self.assertIn("PAGE NOTE FAILED", out.getvalue())

    def test_all_posts_failing_leaves_paged_unset_and_retries_next_run(self):
        """Nothing confirmed => exit 2, no `paged`; the next healthy run posts the note."""
        self.run_intake({"a1": thread("David E Sarabia <david@demandage.com>")})
        first_ts = json.load(open(li.LEDGER))["legal@muso.ai:a1"]["paged"]
        self._post_failing_threads(top_level_ok=False)
        import contextlib, io
        with contextlib.redirect_stdout(io.StringIO()):
            led = self.run_intake(self.two_threads(), code=2)
        self.assertNotIn("paged", led["legal@muso.ai:b2"])
        li.post_page = lambda token, text_, thread_ts=None: (
            self.posts.append({"text": text_, "thread_ts": thread_ts}) or "1761999999.000100")
        self.posts.clear()
        led = self.run_intake(self.two_threads())
        self.assertEqual(led["legal@muso.ai:b2"]["paged"], "dup-of:" + first_ts)
        self.assertEqual([p["thread_ts"] for p in self.posts], [first_ts])

    def test_run_without_page_flag_does_not_poison_the_ledger(self):
        """The dup-of marker may only be written from a confirmed note: a run with no --page
        used to write it anyway, so every later paging run skipped the note."""
        self.run_intake({"a1": thread("David E Sarabia <david@demandage.com>")})
        first_ts = json.load(open(li.LEDGER))["legal@muso.ai:a1"]["paged"]
        led = self.run_intake(self.two_threads(), args=())
        self.assertNotIn("paged", led["legal@muso.ai:b2"])
        led = self.run_intake(self.two_threads())
        self.assertEqual(led["legal@muso.ai:b2"]["paged"], "dup-of:" + first_ts)

    def test_ledger_row_carries_no_subject_text(self):
        led = self.run_intake(self.two_threads())
        for row in led.values():
            self.assertRegex(row["notice_key"], r"^[0-9a-f]{16}$")
            self.assertNotIn("DMCA Notice", json.dumps(row))


class SameSenderDistinctClaims(Harness):
    """hydra#1361 bot round 4 / MUS-20138: the same-sender req_key arm let a second, DIFFERENT claim
    from one sender inherit the first claim's acked/paged markers (no ack, no page). Two rows that
    BOTH carry ids with different notice_key are distinct claims. MUS-20285: identity is strict
    notice_key equality, so id-less notices with different subjects and legacy rows (no notice_key)
    never suppress a new claim; the same notice (same key, ids or not) still collapses."""

    def setUp(self):
        super().setUp()
        pathlib.Path(li.ACK_START).write_text("1")
        self.acks = []

        def fake_ack(to, subj, body):
            self.acks.append(to)
            return f"ack{len(self.acks)}"
        saved_ack = li.send_ack
        li.send_ack = fake_ack
        self.addCleanup(lambda: setattr(li, "send_ack", saved_ack))

    def body(self, *profiles):
        return "Please remove: " + " ".join(f"https://muso.ai/profile/{p}-aaaa" for p in profiles)

    def go(self, threads):
        return self.run_intake(threads, args=("--page", "--ack"))

    def test_distinct_same_sender_claims_each_get_ack_and_page(self):
        day = 86400000
        led = self.go({
            "a1": thread("Rights Holder <claims@labela.com>", subject="DMCA Notice song one",
                         body=self.body("11111111")),
            "b2": thread("Rights Holder <claims@labela.com>", subject="DMCA Notice song two",
                         body=self.body("22222222"), internal=FIRST_MSG + day)})
        self.assertEqual(len(self.acks), 2)
        self.assertEqual(len([p for p in self.posts if p["thread_ts"] is None]), 2)
        for k in ("legal@muso.ai:a1", "legal@muso.ai:b2"):
            self.assertFalse(str(led[k]["paged"]).startswith("dup-of"))
            self.assertFalse(str(led[k]["ack_ref"]).startswith("dup-of"))

    def test_same_sender_two_mailboxes_same_notice_still_one_ack_one_page(self):
        led = self.go({"a1": thread("claims@labela.com"),
                       "b2": thread("claims@labela.com", internal=FIRST_MSG + 36000)})
        self.assertEqual(len(self.acks), 1)
        self.assertEqual(len(self.posts), 1)
        self.assertTrue(led["legal@muso.ai:b2"]["ack_ref"].startswith("dup-of:"))
        self.assertTrue(led["legal@muso.ai:b2"]["paged"].startswith("dup-of:"))

    def test_same_sender_no_ids_same_subject_still_one_ack_one_page(self):
        led = self.go({
            "a1": thread("claims@labela.com", subject="DMCA Notice", body="Please take down my song"),
            "b2": thread("claims@labela.com", subject="Re: DMCA Notice", body="Please take down my song",
                         internal=FIRST_MSG + 36000)})
        self.assertEqual(len(self.acks), 1)
        self.assertEqual(len(self.posts), 1)
        self.assertTrue(led["legal@muso.ai:b2"]["ack_ref"].startswith("dup-of:"))
        self.assertTrue(led["legal@muso.ai:b2"]["paged"].startswith("dup-of:"))

    def test_same_sender_no_ids_different_subjects_each_get_ack_and_page(self):
        led = self.go({
            "a1": thread("claims@labela.com", subject="DMCA Notice one", body="Please take down my song"),
            "b2": thread("claims@labela.com", subject="DMCA Notice two", body="Please take down my track",
                         internal=FIRST_MSG + 36000)})
        self.assertEqual(len(self.acks), 2)
        self.assertEqual(len([p for p in self.posts if p["thread_ts"] is None]), 2)
        for k in ("legal@muso.ai:a1", "legal@muso.ai:b2"):
            self.assertFalse(str(led[k]["paged"]).startswith("dup-of"))
            self.assertFalse(str(led[k]["ack_ref"]).startswith("dup-of"))

    def test_legacy_sibling_without_notice_key_does_not_suppress_a_new_claim(self):
        """MUS-20285: a row written before notice_key existed cannot prove identity, so the new
        thread is acked and paged rather than silently collapsed."""
        first = self.go({"a1": thread("claims@labela.com")})
        row = first["legal@muso.ai:a1"]
        del row["notice_key"]
        json.dump(first, open(li.LEDGER, "w"))
        self.acks.clear(); self.posts.clear()
        # List only b2: main() re-stamps notice_key on every row it visits, so a1 must stay
        # unlisted (outside the run window, inside the 3-day dedupe window) to remain legacy.
        led = self.go({"b2": thread("claims@labela.com", subject="Re: DMCA Notice", internal=FIRST_MSG + 36000)})
        self.assertNotIn("notice_key", led["legal@muso.ai:a1"])
        self.assertEqual(len(self.acks), 1)
        self.assertEqual(len([p for p in self.posts if p["thread_ts"] is None]), 1)
        self.assertFalse(led["legal@muso.ai:b2"]["ack_ref"].startswith("dup-of:"))
        self.assertFalse(str(led["legal@muso.ai:b2"]["paged"]).startswith("dup-of:"))


class SendAckExecution(unittest.TestCase):
    """MUS-18508 QA-bot Critical: send_ack built a bash -c string, so a crafted inbound
    subject/sender (`$(...)`, backticks, quotes) could run host commands. It must pass an
    argument vector: no shell string, attacker text only ever as separate argv elements."""

    def _run(self, to, subject):
        import subprocess
        from unittest import mock
        seen = {}

        def fake_run(argv, **kw):
            seen["argv"], seen["kw"] = argv, kw
            return types.SimpleNamespace(stdout='{"messageId": "m1"}')

        with tempfile.TemporaryDirectory() as home, \
                mock.patch.object(li, "HOME", home), \
                mock.patch.object(subprocess, "run", fake_run):
            self.assertEqual(li.send_ack(to, subject, "body"), "m1")
        return seen

    def test_hostile_subject_and_address_are_argv_elements_not_shell_text(self):
        subject = 'Re: $(touch /tmp/pwn) `id` "; rm -rf / #'
        to = 'x@y.com" ; $(id) #'
        seen = self._run(to, subject)
        argv = seen["argv"]
        self.assertIn(subject, argv)
        self.assertIn(to, argv)
        # the only shell text is a fixed constant: no attacker byte may appear in it
        shell_text = [a for a in argv if a.startswith("set -a")]
        self.assertEqual(len(shell_text), 1)
        self.assertNotIn("touch", shell_text[0])
        self.assertNotIn("$(id)", shell_text[0])
        self.assertFalse(seen["kw"].get("shell"))


if __name__ == "__main__":
    unittest.main()
