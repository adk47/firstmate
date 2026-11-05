"""scripts/scan-unanswered.py predicate (MUS-29979).

Run by the watchdog every tick, so it must not page on in-flight work (grace),
must count in-thread replies as answers, and must page each mention once.
"""

import contextlib
import importlib.util
import io
import json
import pathlib
import sys
import tempfile
import time
import unittest
from unittest import mock

ROOT = pathlib.Path(__file__).resolve().parent.parent
SCRIPTS = ROOT / "scripts"
sys.path.insert(0, str(SCRIPTS))

spec = importlib.util.spec_from_file_location("scan_unanswered", SCRIPTS / "scan-unanswered.py")
scan = importlib.util.module_from_spec(spec)
spec.loader.exec_module(scan)

BOT = "UBOT"
CONFIG = {"channels": {"slack": {"accounts": {"scout": {"botToken": "xoxb-test"}}}}}


def run_scan(history, state_path, now, argv=(), config=CONFIG, bot_by_token=None):
    """One main() pass against a fake Slack; returns the printed lines."""

    def fake_api(token, method, params=""):
        if method == "auth.test":
            return {"user_id": (bot_by_token or {}).get(token, BOT)}
        if method == "users.conversations":
            return {"channels": [{"id": "C1", "name": "general"}]} if "public_channel" in params else {"channels": []}
        if method == "conversations.history":
            return {"messages": history}
        if method == "users.info":
            return {"user": {"real_name": "McLaren"}}
        raise AssertionError(method)

    out = io.StringIO()
    with mock.patch.object(scan, "slack_api", fake_api), \
         mock.patch.object(scan, "load_config", return_value=config), \
         mock.patch.object(scan, "STATE_PATH", str(state_path)), \
         mock.patch.object(scan.time, "time", return_value=now), \
         mock.patch.object(scan.sys, "argv", ["scan-unanswered.py", *argv]), \
         contextlib.redirect_stdout(out):
        scan.main()
    return [ln for ln in out.getvalue().splitlines() if ln.startswith("•")]


def mention(now, age_min, **extra):
    m = {"user": "UHUMAN", "text": "<@%s> please look" % BOT, "ts": "%.6f" % (now - age_min * 60)}
    m.update(extra)
    return m


class ScanUnanswered(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.state = pathlib.Path(self.tmp.name) / "sub" / "unanswered-paged.json"
        self.now = time.time()

    def test_mention_inside_grace_is_not_reported(self):
        self.assertEqual(run_scan([mention(self.now, 3)], self.state, self.now), [])

    def test_thread_reply_by_the_bot_counts_as_answered(self):
        h = [mention(self.now, 20, reply_users=[BOT], reply_count=1)]
        self.assertEqual(run_scan(h, self.state, self.now), [])

    def test_another_bots_thread_reply_does_not_answer_this_bots_mention(self):
        """One parent mentions @scout and @qa; only qa replied in thread -> scout is still unanswered."""
        config = {"channels": {"slack": {"accounts": {
            "scout": {"botToken": "xoxb-scout"}, "qa": {"botToken": "xoxb-qa"}}}}}
        ids = {"xoxb-scout": "USCOUT", "xoxb-qa": "UQA"}
        m = mention(self.now, 20, reply_users=["UQA"], reply_count=1)
        m["text"] = "<@USCOUT> <@UQA> please look"
        lines = run_scan([m], self.state, self.now, config=config, bot_by_token=ids)
        self.assertEqual(len(lines), 1)
        self.assertIn("@scout in #general", lines[0])

    def test_old_unanswered_mention_is_reported_once(self):
        h = [mention(self.now, 20)]
        first = run_scan(h, self.state, self.now)
        self.assertEqual(len(first), 1)
        self.assertIn("@scout in #general", first[0])
        # No commit yet (the page may not have been delivered): still reported.
        self.assertEqual(len(run_scan(h, self.state, self.now + 120)), 1)
        # Delivery confirmed -> commit -> never reported again.
        with mock.patch.object(scan, "STATE_PATH", str(self.state)), \
             mock.patch.object(scan.time, "time", return_value=self.now + 120):
            scan.commit()
        self.assertEqual(run_scan(h, self.state, self.now + 240), [])

    def test_no_dedup_still_lists_a_committed_mention_and_writes_no_state(self):
        """Retrigger/outage report must see a mention even after it was paged."""
        h = [mention(self.now, 20)]
        run_scan(h, self.state, self.now)
        with mock.patch.object(scan, "STATE_PATH", str(self.state)), \
             mock.patch.object(scan.time, "time", return_value=self.now + 60):
            scan.commit()
        self.assertEqual(run_scan(h, self.state, self.now + 120), [])
        before = self.state.read_text()
        self.assertEqual(len(run_scan(h, self.state, self.now + 120, argv=["--no-dedup"])), 1)
        self.assertEqual(self.state.read_text(), before)
        self.assertFalse(pathlib.Path(str(self.state) + ".pending").exists())

    def test_scan_alone_never_writes_the_dedup_state(self):
        """A failed send must not lose the mention: only commit() advances the state."""
        run_scan([mention(self.now, 20)], self.state, self.now)
        self.assertFalse(self.state.exists())

    def test_commit_without_pending_is_a_noop(self):
        with mock.patch.object(scan, "STATE_PATH", str(self.state)):
            scan.commit()
        self.assertFalse(self.state.exists())

    def test_corrupt_state_file_starts_empty_and_does_not_crash(self):
        self.state.parent.mkdir(parents=True)
        self.state.write_text("{not json")
        self.assertEqual(len(run_scan([mention(self.now, 20)], self.state, self.now)), 1)

    def test_state_keys_older_than_lookback_are_pruned(self):
        self.state.parent.mkdir(parents=True)
        old = "C1:%.6f" % (self.now - 3 * 3600)
        self.state.write_text(json.dumps({old: self.now - 3 * 3600}))
        run_scan([mention(self.now, 20)], self.state, self.now)
        with mock.patch.object(scan, "STATE_PATH", str(self.state)), \
             mock.patch.object(scan.time, "time", return_value=self.now):
            scan.commit()
        self.assertNotIn(old, json.loads(self.state.read_text()))


if __name__ == "__main__":
    unittest.main()
