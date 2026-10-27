"""uvn_status daily caps are env-overridable, fail closed to the reviewed defaults (firstmate 014, [key=p2-caps])."""
import importlib
import os
import sys
import unittest
from unittest import mock

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
from credit_review import uvn_status  # noqa: E402


def caps(env):
    with mock.patch.dict(os.environ, env, clear=False):
        for k in ("CREDIT_STATUS_DAILY_MAX", "CREDIT_UVN_DAILY_MAX"):
            if k not in env:
                os.environ.pop(k, None)
        m = importlib.reload(uvn_status)
        return m.STATUS_DAILY_MAX, m.DAILY_MAX


class CapsTest(unittest.TestCase):
    def tearDown(self):
        with mock.patch.dict(os.environ, {}, clear=False):
            os.environ.pop("CREDIT_STATUS_DAILY_MAX", None)
            os.environ.pop("CREDIT_UVN_DAILY_MAX", None)
            importlib.reload(uvn_status)

    def test_defaults_are_the_reviewed_bounds(self):
        self.assertEqual(caps({}), (1000, 400))

    def test_a_positive_whole_number_overrides(self):
        self.assertEqual(caps({"CREDIT_STATUS_DAILY_MAX": "5000", "CREDIT_UVN_DAILY_MAX": "2500"}), (5000, 2500))

    def test_anything_else_keeps_the_default(self):
        for bad in ("", " ", "abc", "0", "-5", "1e4", "12.5", "100001", "５０００"):
            with self.subTest(bad=bad):
                self.assertEqual(caps({"CREDIT_STATUS_DAILY_MAX": bad, "CREDIT_UVN_DAILY_MAX": bad}), (1000, 400))

    def test_the_upper_limit_is_accepted(self):
        self.assertEqual(caps({"CREDIT_STATUS_DAILY_MAX": "100000"})[0], 100000)


if __name__ == "__main__":
    unittest.main()
