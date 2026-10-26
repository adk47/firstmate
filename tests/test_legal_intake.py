"""Behavioral tests for scripts/legal-intake.py (notices@ / legal@ intake -> #cs_priority page).

2026-10-23 (MUS-18475 / MUS-18508, Jan Delmo via Buzz): one DMCA notice sent from two
addresses (david@demandage.com and demandage@gmail.com, 36 s apart, same four Muso profiles)
paged #cs_priority twice, the page showed only "(@demandage.com)" instead of the sender's
address, and it tagged Nick although Jan owns legal intake. These tests lock:

  - the page shows the full sender address (angle brackets escaped), like the rights-holder page;
  - the page tags Jan only;
  - the same notice from a second address is collapsed to a threaded, un-mentioned reply under
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

    def run_intake(self, threads):
        li.svc = lambda subject, scope: FakeGmail(threads)
        argv, sys.argv = sys.argv, ["legal-intake.py", "--page"]
        try:
            with self.assertRaises(SystemExit) as cm:
                li.main()
        finally:
            sys.argv = argv
        self.assertEqual(cm.exception.code, 0)
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
        self.assertNotIn("<@", note["text"])
        self.assertIn("demandage@gmail.com", note["text"])
        self.assertIn("b2", note["text"])  # Gmail thread id
        self.assertIsNone(self.posts[0]["thread_ts"])

    def test_no_collapse_when_ids_empty(self):
        no_ids = "Please take down my song"
        led = self.run_intake({"a1": thread("a@x.com", body=no_ids),
                               "b2": thread("b@y.com", body=no_ids, internal=FIRST_MSG + 36000)})
        self.assertEqual(len(self.posts), 2)
        for k in ("legal@muso.ai:a1", "legal@muso.ai:b2"):
            self.assertFalse(str(led[k]["paged"]).startswith("dup-of"))
        self.assertTrue(all(p["thread_ts"] is None for p in self.posts))

    def test_failed_threaded_note_still_marks_dup_and_warns(self):
        calls = []

        def post(token, text_, thread_ts=None):
            calls.append(thread_ts)
            if thread_ts:
                raise RuntimeError("slack down")
            return "1761000001.000100"
        li.post_page = post
        import contextlib, io
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            led = self.run_intake(self.two_threads())
        self.assertEqual(led["legal@muso.ai:b2"]["paged"], "dup-of:1761000001.000100")
        self.assertIn("WARN:", out.getvalue())

    def test_ledger_row_carries_no_subject_text(self):
        led = self.run_intake(self.two_threads())
        for row in led.values():
            self.assertRegex(row["notice_key"], r"^[0-9a-f]{16}$")
            self.assertNotIn("DMCA Notice", json.dumps(row))


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
