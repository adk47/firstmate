#!/usr/bin/env python3
"""credit_review/account_gate.py: the client of the shared node-8 account gate (fail closed)."""
import credit_test_env  # noqa: F401
import json
import subprocess
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from credit_review import account_gate as g  # noqa: E402


def runner(rc, body=None, raw=None, boom=None):
    def run(argv):
        if boom:
            raise boom
        run.argv = argv
        return subprocess.CompletedProcess(argv, rc, raw if raw is not None else json.dumps(body), "")
    return run


class Gate(unittest.TestCase):
    def test_exit_0_allow_is_the_only_allow(self):
        r = runner(0, {"decision": "allow", "reasons": []})
        self.assertTrue(g.check(42, r).allowed)
        self.assertEqual(r.argv[-2:], ["check", "42"])

    def test_hold_unknown_and_every_failure_are_not_an_allow(self):
        cases = {
            "hold exit 3": (runner(3, {"decision": "hold", "reasons": ["count_90d 300 >= 250"]}), g.HOLD),
            "unknown exit 2": (runner(2, {"decision": "unknown", "reasons": ["q.sh missing"]}), g.UNKNOWN),
            "allow body but exit 2": (runner(2, {"decision": "allow"}), g.UNKNOWN),
            "exit 0 but hold body": (runner(0, {"decision": "hold"}), g.HOLD),
            "garbage": (runner(0, raw="not json"), g.UNKNOWN),
            "empty": (runner(0, raw=""), g.UNKNOWN),
            "timeout": (runner(0, boom=subprocess.TimeoutExpired("x", 60)), g.UNKNOWN),
            "missing binary": (runner(0, boom=FileNotFoundError("python3")), g.UNKNOWN),
        }
        for name, (r, want) in cases.items():
            with self.subTest(name):
                res = g.check(7, r)
                self.assertEqual(res.decision, want)
                self.assertFalse(res.allowed)
        held = g.check(7, runner(3, {"decision": "hold", "reasons": ["count_90d 300 >= 250"]}))
        self.assertEqual(held.why(), "account gate hold (count_90d 300 >= 250)")

    def test_no_user_id_is_unknown_without_calling(self):
        for uid in (None, "42", True):
            r = runner(0, {"decision": "allow"})
            self.assertEqual(g.check(uid, r).decision, g.UNKNOWN)
            self.assertFalse(hasattr(r, "argv"))

    def test_the_run_cache_calls_once_per_account(self):
        calls = []
        c = g.Cached(lambda uid: calls.append(uid) or g.GateResult(g.ALLOW))
        for uid in (1, 1, 2, 1):
            c(uid)
        self.assertEqual(calls, [1, 2])


if __name__ == "__main__":
    unittest.main()
