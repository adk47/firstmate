"""Tests for scripts/godmode-weekly-report.py (Fable item 10: god-mode actions are
logged and reported to Aaron weekly). Stdlib unittest only, no network."""
import importlib.util
import json
import os
import pathlib
import tempfile
import unittest

_SCRIPT = pathlib.Path(__file__).resolve().parent.parent / "scripts" / "godmode-weekly-report.py"
_spec = importlib.util.spec_from_file_location("godmode_weekly_report", _SCRIPT)
g = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(g)

NOW = "2026-10-12T14:00:00Z"


class GodmodeReportTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = self.tmp.name

    def tearDown(self):
        self.tmp.cleanup()

    def log(self, agent, name, records, jsonl=True):
        d = os.path.join(self.root, agent, "api-logs")
        os.makedirs(d, exist_ok=True)
        p = os.path.join(d, name)
        with open(p, "w") as fh:
            if jsonl:
                fh.write("\n".join(json.dumps(r) for r in records) + "\n")
            else:
                json.dump(records[0], fh)
        return p

    def run_report(self, **kw):
        until = g._parse_ts(NOW)
        since = until - g.dt.timedelta(days=7)
        dirs, events, automated, problems = g.collect(self.root, since, until)
        self.problems = problems
        return g.render(dirs, events, since, until, automated, problems), events, automated

    def test_nick_actions_are_itemized_and_listed_first(self):
        self.log("cto", "cto-2026-10-10.jsonl", [
            {"agent": "cto", "action": "git_push", "target": "Muso-AI/hydra#1", "requester": "U0AL36NADEY",
             "timestamp": "2026-10-10T10:00:00Z", "authorization": "self_authorized"},
            {"agent": "cto", "action": "prod_db_write", "target": "x", "requester": "Nick (U0AL36NADEY)",
             "timestamp": "2026-10-11T10:00:00Z", "authorization": "Nick self-authorized the repair"},
        ])
        self.log("operations", "a.jsonl", [
            {"agent": "operations", "action": "claiming_approve", "target": "claim:1", "requester": "U038BM16T7W",
             "timestamp": "2026-10-11T09:00:00Z", "authorization": "god_mode_self_approve"},
        ] * 1)
        out, events, _ = self.run_report()
        self.assertEqual(len(events), 3)
        self.assertLess(out.index("*Nick*: 2 action(s)"), out.index("*Jan*: 1 action(s)"))
        self.assertIn("prod_db_write", out)
        self.assertIn("git_push", out)

    def test_outside_window_and_non_godmode_are_ignored(self):
        self.log("cto", "old.jsonl", [
            {"agent": "cto", "action": "git_push", "requester": "U0AL36NADEY", "timestamp": "2026-09-01T00:00:00Z"},
            {"agent": "cto", "action": "read", "requester": "U02N2NP3H7F", "timestamp": "2026-10-11T00:00:00Z",
             "authorization": "normal queue"},
        ])
        out, events, _ = self.run_report()
        self.assertEqual(events, [])
        self.assertIn("No god-mode actions were logged", out)

    def test_automation_on_nicks_behalf_is_counted_not_itemized(self):
        self.log("qa", "github.jsonl", [
            {"agent": "qa", "action": "github_pr_review", "target": "Muso-AI/hydra#9", "requester": "U0AL36NADEY",
             "timestamp": "2026-10-11T00:00:00Z", "authorization": "auto-review-dispatch"},
        ])
        out, events, automated = self.run_report()
        self.assertEqual(events, [])
        self.assertEqual(automated["Nick"], 1)
        self.assertIn("Not counted (automation", out)
        self.assertNotIn("github_pr_review", out)

    def test_pre_and_result_phases_count_once_and_operator_form_is_read(self):
        rec = {"agent": "operations", "correlation_id": "c-1", "operation": "remove_credit",
               "operator": {"slack_id": "U0AL36NADEY", "authorization": "god_mode"},
               "endpoint": "DELETE /admin/track/t/profile/p/credits", "timestamp": "2026-10-11T01:00:00Z"}
        self.log("operations", "admin.jsonl", [dict(rec, phase="pre"), dict(rec, phase="result")])
        _, events, _ = self.run_report()
        self.assertEqual(len(events), 1)
        self.assertEqual(events[0]["who"], "U0AL36NADEY")

    def test_single_object_json_file_is_read(self):
        self.log("cto", "one.json", [{"agent": "cto", "action": "merge", "requester": "U0AL36NADEY",
                                      "timestamp": "2026-10-11T02:00:00Z"}], jsonl=False)
        _, events, _ = self.run_report()
        self.assertEqual(len(events), 1)

    def test_aaron_is_counted_but_not_itemized(self):
        self.log("cto", "a.jsonl", [{"agent": "cto", "action": "git_push", "target": "secret-target",
                                     "requester": "U7RP6HKUZ", "timestamp": "2026-10-11T02:00:00Z"}])
        out, events, _ = self.run_report()
        self.assertIn("*Aaron*: 1 action(s)", out)
        self.assertNotIn("secret-target", out)

    def test_targets_are_masked_and_escaped(self):
        self.log("cto", "a.jsonl", [{"agent": "cto", "action": "x", "requester": "U0AL36NADEY",
                                     "target": "send to jane.doe@example.com <@U123> token=abc123",
                                     "timestamp": "2026-10-11T02:00:00Z"}])
        out, _, _ = self.run_report()
        self.assertIn("j***@example.com", out)
        self.assertNotIn("jane.doe", out)
        self.assertNotIn("abc123", out)
        self.assertIn("token=[redacted]", out)
        self.assertNotIn("<@U123>", out)

    def test_malformed_record_makes_the_report_incomplete_not_zero(self):
        # QA on hydra#1143: one malformed JSONL line used to yield "No god-mode actions".
        d = os.path.join(self.root, "cto", "api-logs")
        os.makedirs(d)
        with open(os.path.join(d, "bad.jsonl"), "w") as fh:
            fh.write('{"agent": "cto", "requester": "U0AL36NADEY", "timestamp": "2026-10-11T0\n')
        out, events, _ = self.run_report()
        self.assertEqual(events, [])
        self.assertIn("INCOMPLETE", out)
        self.assertEqual(self.problems["malformed_records"], 1)
        self.assertEqual(g.main(["--root", self.root, "--now", NOW]), 3)

    def test_undated_godmode_record_makes_the_report_incomplete(self):
        # QA on hydra#1143: an invalid or missing timestamp used to be skipped silently.
        self.log("cto", "a.jsonl", [
            {"requester": "U0AL36NADEY", "action": "git_push", "timestamp": "not-a-date"},
            {"requester": "U0AL36NADEY", "action": "git_push"},
        ])
        out, events, _ = self.run_report()
        self.assertEqual(events, [])
        self.assertEqual(self.problems["undated_records"], 2)
        self.assertIn("INCOMPLETE", out)
        self.assertIn("2 god-mode record(s) had no valid timestamp", out)
        self.assertEqual(g.main(["--root", self.root, "--now", NOW]), 3)

    def test_undated_non_godmode_or_automated_records_are_not_problems(self):
        self.log("qa", "a.jsonl", [
            {"requester": "U0AL36NADEY", "action": "github_pr_review", "authorization": "auto-review-dispatch"},
            {"requester": "U02N2NP3H7F", "action": "read", "timestamp": "bad"},
        ])
        out, _, _ = self.run_report()
        self.assertNotIn("INCOMPLETE", out)
        self.assertEqual(g.main(["--root", self.root, "--now", NOW]), 0)

    def test_valid_json_that_is_not_a_record_makes_the_report_incomplete(self):
        # QA on hydra#1143: a log containing `null` used to give a clean zero.
        d = os.path.join(self.root, "cto", "api-logs")
        os.makedirs(d)
        with open(os.path.join(d, "a.jsonl"), "w") as fh:
            fh.write('null\n42\n"text"\n[{"agent": "cto", "requester": "U02N2NP3H7F"}, null]\n')
        out, events, _ = self.run_report()
        self.assertEqual(events, [])
        self.assertEqual(self.problems["malformed_records"], 4)
        self.assertIn("INCOMPLETE", out)
        self.assertEqual(g.main(["--root", self.root, "--now", NOW]), 3)

    def test_log_files_are_read_and_body_files_are_not(self):
        rec = {"agent": "operations", "action": "x", "requester": "U0AL36NADEY",
               "timestamp": "2026-10-11T00:00:00Z"}
        self.log("operations", "2026-10-11.log", [rec])
        d = os.path.join(self.root, "operations", "api-logs", "intercom")
        os.makedirs(d)
        with open(os.path.join(d, "customer-reply-1.txt"), "w") as fh:
            fh.write("Hi, this is a message body, not a record.\n")
        out, events, _ = self.run_report()
        self.assertEqual(len(events), 1)
        self.assertNotIn("INCOMPLETE", out)

    @unittest.skipIf(hasattr(os, "geteuid") and os.geteuid() == 0, "root can list any directory")
    def test_unlistable_subdirectory_makes_the_report_incomplete(self):
        self.log("cto", "a.jsonl", [{"agent": "cto", "action": "x", "requester": "U0AL36NADEY",
                                     "timestamp": "2026-10-11T00:00:00Z"}])
        locked = os.path.join(self.root, "cto", "api-logs", "locked")
        os.makedirs(locked)
        os.chmod(locked, 0)
        try:
            out, _, _ = self.run_report()
        finally:
            os.chmod(locked, 0o700)
        self.assertIn("INCOMPLETE", out)
        self.assertGreaterEqual(self.problems["unreadable_files"], 1)

    def test_unreadable_file_makes_the_report_incomplete(self):
        p = self.log("cto", "a.jsonl", [{"agent": "cto", "requester": "U0AL36NADEY",
                                         "timestamp": "2026-10-11T00:00:00Z"}])
        with open(p, "wb") as fh:
            fh.write(b"\xff\xfe\x00not utf8")
        out, _, _ = self.run_report()
        self.assertIn("INCOMPLETE", out)
        self.assertEqual(self.problems["unreadable_files"], 1)

    def test_pretty_printed_objects_appended_to_jsonl_are_read(self):
        # node-8 qa/api-logs/github/2026-10-09.jsonl has multi-line objects appended.
        d = os.path.join(self.root, "qa", "api-logs")
        os.makedirs(d)
        rec = {"agent": "qa", "action": "x", "requester": "U0AL36NADEY",
               "timestamp": "2026-10-11T00:00:00Z", "authorization": "self_authorized"}
        with open(os.path.join(d, "mix.jsonl"), "w") as fh:
            fh.write(json.dumps(rec) + "\n" + json.dumps(dict(rec, action="y"), indent=2) + "\n")
        out, events, _ = self.run_report()
        self.assertEqual(sorted(e["action"] for e in events), ["x", "y"])
        self.assertNotIn("INCOMPLETE", out)
        self.assertEqual(g.main(["--root", self.root, "--now", NOW]), 0)

    def test_operator_godmode_counts_even_when_requester_is_someone_else(self):
        # QA on hydra#1143: requester='customer', operator.slack_id=Nick, no auth marker.
        self.log("operations", "admin.jsonl", [{
            "agent": "operations", "requester": "customer", "operation": "remove_credit",
            "operator": {"slack_id": "U0AL36NADEY"}, "endpoint": "DELETE /admin/x",
            "timestamp": "2026-10-11T03:00:00Z"}])
        out, events, _ = self.run_report()
        self.assertEqual(len(events), 1)
        self.assertEqual(events[0]["who"], "U0AL36NADEY")
        self.assertIn("*Nick*: 1 action(s)", out)

    def test_credentials_are_masked_whatever_the_separator(self):
        cases = {
            "Authorization: Bearer DEMO_VALUE": "Authorization=[redacted]",
            "Bearer DEMO_VALUE": "Bearer=[redacted]",
            "token=abc123 next": "token=[redacted] next",
            "api_key: k-123": "api_key=[redacted]",
            "access_token \"zzz\"": "access_token=[redacted]",
            "slack xoxb-1234567890-abcdef": "slack [redacted]",
        }
        for raw, want in cases.items():
            got = g.safe(raw)
            self.assertEqual(got, want, raw)
            self.assertNotIn("DEMO_VALUE", got)

    def test_unreadable_logs_fail_loud_not_zero(self):
        rc = g.main(["--root", os.path.join(self.root, "nope"), "--now", NOW])
        self.assertEqual(rc, 1)
        until = g._parse_ts(NOW)
        out = g.render([], [], until - g.dt.timedelta(days=7), until)
        self.assertIn("could NOT be counted", out)


if __name__ == "__main__":
    unittest.main()
