"""scripts/paid-status/support7d.py fails closed (QA on #1384 @5ed61733): a gog answer counts only from a
successful exit with the expected shape; a nonzero exit printing a JSON error, malformed JSON, or a search
answer without messages[] is UNREADABLE, never "no human reply in 7 days" (that would put a support@ user who
a person just answered back into the send candidates). Stdlib only; gog and Trino are faked."""
import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
os.environ.setdefault("PWR_DIR", tempfile.mkdtemp())
spec = importlib.util.spec_from_file_location("support7d", os.path.join(HERE, "..", "paid-status", "support7d.py"))
s7 = importlib.util.module_from_spec(spec)
spec.loader.exec_module(s7)
NOSLEEP = {"sleep": lambda s: None}


def runner(answers):
    """A fake subprocess.run answering each gog call from `answers` (rc, stdout) in order; the last repeats."""
    seq = list(answers)

    def run(argv, **kw):
        rc, out = seq.pop(0) if len(seq) > 1 else seq[0]
        return subprocess.CompletedProcess(argv, rc, out, "gog: boom" if rc else "")
    return run


class ShTest(unittest.TestCase):
    def test_a_nonzero_exit_with_a_json_error_is_unreadable(self):
        with self.assertRaises(s7.Unreadable) as cm:
            s7.sh("gog x", run=runner([(1, '{"error": "token expired"}')]), **NOSLEEP)
        self.assertIn("rc=1", str(cm.exception))

    def test_malformed_or_non_object_output_is_unreadable(self):
        for out in ("not json", "[]", '"x"'):
            with self.assertRaises(s7.Unreadable):
                s7.sh("gog x", run=runner([(0, out)]), **NOSLEEP)

    def test_a_retry_that_succeeds_is_an_answer(self):
        self.assertEqual(s7.sh("gog x", run=runner([(1, ""), (0, '{"messages": []}')]), **NOSLEEP), {"messages": []})


class SearchJudgeTest(unittest.TestCase):
    def test_a_search_without_a_messages_list_is_unreadable_not_an_empty_inbox(self):
        for out in ('{}', '{"messages": null}', '{"messages": "x"}', '{"messages": [{"no_id": 1}]}'):
            with self.assertRaises(s7.Unreadable, msg=out):
                s7.search("a@x.com", run=runner([(0, out)]), **NOSLEEP)

    def test_an_empty_inbox_is_zero_and_a_person_s_reply_counts(self):
        self.assertEqual(s7.judge("a@x.com", run=runner([(0, '{"messages": [], "nextPageToken": ""}')]), **NOSLEEP),
                         {"human_7d": 0, "auto_7d": 0, "last_human": ""})
        got = s7.judge("a@x.com", run=runner([(0, '{"messages": [{"id": "m1", "date": "2026-10-26"}]}'),
                                              (0, '{"payload": "Hi, I checked your credits myself"}')]), **NOSLEEP)
        self.assertEqual(got, {"human_7d": 1, "auto_7d": 0, "last_human": "2026-10-26"})

    def test_a_message_that_cannot_be_read_is_unreadable(self):
        with self.assertRaises(s7.Unreadable):
            s7.judge("a@x.com", run=runner([(0, '{"messages": [{"id": "m1"}]}'), (2, '{"error": "x"}')]), **NOSLEEP)


class MainTest(unittest.TestCase):
    def test_an_unreadable_mailbox_holds_the_user_and_fails_the_segment(self):
        d = tempfile.mkdtemp()
        json.dump([{"user_id": 7, "support90": True}, {"user_id": 8, "support90": False}],
                  open(os.path.join(d, "segments.json"), "w"))
        s7.D = d

        def run(argv, **kw):
            if argv[0].endswith("trino-query.sh"):
                return subprocess.CompletedProcess(argv, 0, '"7","a@x.com"\n', "")
            return subprocess.CompletedProcess(argv, 1, '{"error": "token expired"}', "boom")
        orig_run, orig_sleep = s7.subprocess.run, s7.time.sleep
        s7.subprocess.run, s7.time.sleep = run, (lambda s: None)
        try:
            rc = s7.main()
        finally:
            s7.subprocess.run, s7.time.sleep = orig_run, orig_sleep
        self.assertEqual(rc, 3)
        rows = json.load(open(os.path.join(d, "support7d.json")))
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["user_id"], 7)
        self.assertTrue(rows[0]["error"].startswith("support@ mailbox unreadable"))
        self.assertNotIn("human_7d", rows[0])

    def test_a_failed_trino_read_exits_nonzero(self):
        d = tempfile.mkdtemp()
        json.dump([{"user_id": 7, "support90": True}], open(os.path.join(d, "segments.json"), "w"))
        s7.D = d
        orig = s7.subprocess.run
        s7.subprocess.run = lambda argv, **kw: subprocess.CompletedProcess(argv, 1, "", "trino down")
        try:
            with self.assertRaises(SystemExit) as cm:
                s7.main()
        finally:
            s7.subprocess.run = orig
        self.assertIn("trino failed", str(cm.exception.code))


if __name__ == "__main__":
    unittest.main()
