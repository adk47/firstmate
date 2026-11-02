"""QA #1601 (2): the reply-ref classifier's pick, recorded per conversation + part, read back latest-first by the gate."""
from __future__ import annotations

import credit_test_env  # noqa: F401,E402 - first: test logs never reach production
import json
import sqlite3
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
from credit_review import verify_ledger as vl  # noqa: E402

CLI = ROOT / "scripts" / "credit_review" / "verify_ledger.py"


class ReplyRefPickTest(unittest.TestCase):
    def setUp(self):
        self.path = str(Path(tempfile.mkdtemp()) / "l.sqlite3")
        self.db = vl.connect(self.path)

    def test_the_latest_pick_for_this_part_is_read_and_bad_ids_are_refused(self):
        self.assertIsNone(vl.pick_for(self.db, conversation="777", part="1"))
        vl.record_pick(self.db, conversation="777", part="1", ref="fable-copy-1031-r5/q", reason="mapped", llm_call_id="9")
        vl.record_pick(self.db, conversation="777", part="1", ref="fable-copy-1031-r5/r", reason="mapped", llm_call_id="10")
        vl.record_pick(self.db, conversation="777", part="2", ref="fable-copy-1031-r5/s", reason="mapped", llm_call_id="11")
        got = vl.pick_for(self.db, conversation="777", part="1")
        self.assertEqual((got["ref"], got["llm_call_id"]), ("fable-copy-1031-r5/r", "10"))
        for kw in ({"conversation": "7x"}, {"part": ""}, {"ref": ""}, {"reason": ""}):
            with self.assertRaises(ValueError):
                vl.record_pick(self.db, **{"conversation": "777", "part": "1", "ref": "r", "reason": "mapped", **kw})

    def test_a_ledger_without_the_table_reads_as_no_pick_and_the_cli_round_trips(self):
        old = sqlite3.connect(str(Path(self.path).with_name("old.sqlite3")))
        self.assertIsNone(vl.pick_for(old, conversation="777", part="1"))
        run = lambda *a: json.loads(subprocess.run([sys.executable, str(CLI), "--db", self.path, *a], capture_output=True,
                                                   text=True, check=True).stdout)
        self.assertEqual(run("--readonly", "pick-for", "--conversation", "777", "--part", "1"), {})
        run("record-pick", "--conversation", "777", "--part", "1", "--ref", "fable-copy-1031-r5/u", "--reason", "mapped",
            "--llm-call-id", "5")
        self.assertEqual(run("--readonly", "pick-for", "--conversation", "777", "--part", "1")["ref"], "fable-copy-1031-r5/u")

    def test_a_failing_read_raises_never_no_pick(self):
        # QA #1615: only "no such table" is no pick; a locked / broken read surfaces (the gate: pick_unreadable)
        class Broken:
            def execute(self, *a, **k):
                raise sqlite3.OperationalError("database is locked")
        with self.assertRaises(sqlite3.OperationalError):
            vl.pick_for(Broken(), conversation="777", part="1")


    def test_the_pick_is_serialized_with_the_claim_and_a_claimed_part_takes_no_newer_pick(self):
        # QA #1615: two overlapping runs - run A matched pick 1; run B's classifier records pick 2 before A claims:
        # A's claim answers pick_changed (nothing claimed); and once a claim exists, no newer pick may be recorded
        p1 = vl.record_pick(self.db, conversation="777", part="1", ref="fable-copy-1031-r5/r", reason="mapped", llm_call_id="9")
        p2 = vl.record_pick(self.db, conversation="777", part="1", ref="fable-copy-1031-r5/u", reason="mapped", llm_call_id="10")
        kw = dict(user_key="a@x.com", day="2026-11-01", request_ids=["reply-1"], message_type="comment", approved_by="U",
                  approval_ref="fable-copy-1031-r5/u", campaign="reply-ref", user_id="7", reply_due="1", conversation="777")
        self.assertEqual(vl.claim(self.db, pick_id=str(p1), **kw)["result"], "pick_changed")
        self.assertIsNone(self.db.execute("SELECT 1 FROM verify_messages WHERE campaign='reply-ref'").fetchone())
        self.assertEqual(vl.claim(self.db, pick_id=str(p2), **kw)["result"], "claimed")
        with self.assertRaises(vl.PickLocked):
            vl.record_pick(self.db, conversation="777", part="1", ref="fable-copy-1031-r5/q", reason="mapped", llm_call_id="11")
        r = subprocess.run([sys.executable, str(CLI), "--db", self.path, "record-pick", "--conversation", "777", "--part", "1",
                            "--ref", "x", "--reason", "mapped"], capture_output=True, text=True)
        self.assertEqual((r.returncode, json.loads(r.stdout)["result"]), (3, "pick_locked"))
        # another part of the thread is not locked
        vl.record_pick(self.db, conversation="777", part="2", ref="fable-copy-1031-r5/q", reason="mapped", llm_call_id="12")
        # QA #1615: a conversation id that PREFIXES (or extends) the claimed one is another thread - never locked, and
        # never under the claimed thread's 48 h window
        for conv in ("77", "7777"):
            vl.record_pick(self.db, conversation=conv, part="1", ref="fable-copy-1031-r5/u", reason="mapped",
                           llm_call_id="13")                                      # part 1 there: not locked
            part = f"5{conv}"                                                     # (part ids are global in Intercom)
            pid = vl.record_pick(self.db, conversation=conv, part=part, ref="fable-copy-1031-r5/u", reason="mapped",
                                 llm_call_id="14")
            other = {**kw, "conversation": conv, "reply_due": part, "request_ids": [f"reply-{part}"], "user_key": f"b{conv}@x.com", "user_id": f"8{conv}"}
            self.assertEqual(vl.claim(self.db, pick_id=str(pid), **other)["result"], "claimed", conv)


if __name__ == "__main__":
    unittest.main()
