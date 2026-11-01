"""uvn_status daily caps: ONE source, the policy file's shared credit cap, read in code; no environment variable moves
it ([key=uvn-daily-cap-400], r5 626 / p1; [key=unattended]). An unreadable policy fails closed to 0."""
import credit_test_env  # noqa: F401,E402 - first: test logs + the signed-head harness never reach production
import importlib
import json
import os
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
from credit_review import uvn_status  # noqa: E402

REPO_POLICY = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "policies", "credit-verify-outbound.json")


def caps(env):
    with mock.patch.dict(os.environ, env, clear=False):
        m = importlib.reload(uvn_status)
        return m.STATUS_DAILY_MAX, m.DAILY_MAX


class CapsTest(unittest.TestCase):
    def tearDown(self):
        importlib.reload(uvn_status)

    def test_the_cap_is_the_policy_files_shared_credit_cap(self):
        want = json.load(open(REPO_POLICY))["shared_daily_cap"]["credit"]
        self.assertEqual(caps({}), (want, want))

    def test_no_environment_value_moves_it_up_or_down(self):
        want = json.load(open(REPO_POLICY))["shared_daily_cap"]["credit"]
        for v in ("5000", "1", "0", "abc", "100000"):
            with self.subTest(v=v):
                self.assertEqual(caps({"CREDIT_STATUS_DAILY_MAX": v, "CREDIT_UVN_DAILY_MAX": v}), (want, want))

    def test_a_credit_group_missing_a_credit_campaign_is_malformed(self):
        # QA #1617: an empty group, or one omitting proof-need-ask, would let that campaign spend outside the shared cap
        import tempfile
        for group in ([], ["uvn-status", "status-doc-received"], ["uvn-status", "proof-need-ask"]):
            with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as fh:
                json.dump({"shared_daily_cap": {"credit": 2500}, "groups": {"credit": group}}, fh)
            self.assertIsNone(uvn_status.read_policy(fh.name), group)
            self.assertEqual(uvn_status.policy_credit_cap(fh.name), 0)
            os.unlink(fh.name)
        self.assertEqual(uvn_status.read_policy()[0], 2500)         # the shipped policy is complete
        self.assertTrue(uvn_status.REQUIRED_CREDIT_GROUP <= set(uvn_status.CREDIT_GROUP))

    def test_an_unreadable_or_malformed_policy_is_zero(self):
        # (a policy with no credit group is malformed too: the shared budget's campaigns must be named)
        d = tempfile.mkdtemp()
        bad = os.path.join(d, "p.json")
        self.assertEqual(uvn_status.policy_credit_cap(os.path.join(d, "missing.json")), 0)
        for doc in ("not json", json.dumps({"shared_daily_cap": {}}), json.dumps({"shared_daily_cap": {"credit": "400"}}),
                    json.dumps({"shared_daily_cap": {"credit": -1}})):
            with open(bad, "w") as fh:
                fh.write(doc)
            self.assertEqual(uvn_status.policy_credit_cap(bad), 0, doc)
        with open(bad, "w") as fh:
            json.dump({"shared_daily_cap": {"credit": 400}, "groups": {"credit": ["uvn-status", "status-doc-received", "proof-need-ask"]}}, fh)
        self.assertEqual(uvn_status.policy_credit_cap(bad), 400)


    def test_the_cli_exits_2_on_an_unreadable_policy(self):
        import argparse, importlib.util
        spec = importlib.util.spec_from_file_location("cr_cli_cap2", os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                                                               "..", "credit-review.py"))
        cli = importlib.util.module_from_spec(spec); spec.loader.exec_module(cli)
        rep = uvn_status.UvnReport(); rep.policy_error = True; rep.halted = "cap_policy_unreadable"
        ns = argparse.Namespace(preview=None, wording="", campaign="uvn-status", from_stage2=False, list="x", exclude_users=None,
                                mode="apply", segment="paid", max_users=5, ledger=None, proof_on_file=None, proof_store=None,
                                check_recipients=False, segment_daily_cap=None, gmail_fallback_o=False, no_correction=False,
                                max_entries=None, start_entry=0, outcomes_json=None)
        with mock.patch.object(cli.uvn_status, "run", lambda **kw: rep), mock.patch.object(cli, "preflight_outcomes", lambda a: ""):
            self.assertEqual(cli._uvn_status(ns), 2)

    def test_the_cli_exits_3_when_a_signed_apply_is_refused_short_of_cap_room(self):
        import argparse, importlib.util
        spec = importlib.util.spec_from_file_location("cr_cli_cap", os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                                                              "..", "credit-review.py"))
        cli = importlib.util.module_from_spec(spec); spec.loader.exec_module(cli)
        rep = uvn_status.UvnReport(); rep.cap_short = True; rep.halted = "daily_cap_short: 3 left"
        ns = argparse.Namespace(preview=None, wording="", campaign="uvn-status", from_stage2=False, list="x", exclude_users=None,
                                mode="apply", segment="paid", max_users=5, ledger=None, proof_on_file=None, proof_store=None,
                                check_recipients=False, segment_daily_cap=None, gmail_fallback_o=False, no_correction=False,
                                max_entries=None, start_entry=0, outcomes_json=None)
        with mock.patch.object(cli.uvn_status, "run", lambda **kw: rep), mock.patch.object(cli, "preflight_outcomes", lambda a: ""):
            self.assertEqual(cli._uvn_status(ns), 3)


if __name__ == "__main__":
    unittest.main()
