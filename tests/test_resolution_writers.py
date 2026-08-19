"""Outcome-contract tests for automated ClickUp status writers."""

import importlib.util
import pathlib
import sys
import unittest
from unittest import mock


ROOT = pathlib.Path(__file__).resolve().parent.parent
SCRIPTS = ROOT / "scripts"
sys.path.insert(0, str(SCRIPTS))


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


uvn = load("uvn_under30_cron", SCRIPTS / "uvn-under30-cron.py")
matcher = load("resolution_matcher", SCRIPTS / "resolution-matcher.py")
merged = load(
    "notify_merged_customers",
    SCRIPTS / "dedup" / "sweeps" / "notify-merged-customers.py",
)


class TestUvnOutcomeWriter(unittest.TestCase):
    def test_replaces_stale_outcome_and_requires_complete_readback(self):
        original = {"tags": [{"name": "customer-outcome:partial"}]}
        confirmed = {"tags": [{"name": "customer-outcome:complete"}]}
        calls = []

        def fake_clickup(method, path, body=None, query=None):
            calls.append((method, path, body))
            return {}

        with mock.patch.object(uvn, "clickup", side_effect=fake_clickup), \
             mock.patch.object(uvn, "get_task", return_value=confirmed), \
             mock.patch.object(uvn, "audit"):
            uvn.replace_customer_outcome_tag("run", "T1", original, "complete")

        self.assertEqual(calls, [
            ("DELETE", "/task/T1/tag/customer-outcome%3Apartial", None),
            ("POST", "/task/T1/tag/customer-outcome%3Acomplete", None),
        ])


class TestResolutionMatcherOutcomeWriter(unittest.TestCase):
    def test_entity_touch_waits_for_verification_instead_of_resolving(self):
        calls = []

        def fake_http(method, url, headers, body=None, **_kwargs):
            calls.append((method, url, body))
            return 200, {}

        puts = []
        task = {"tags": [{"name": "customer-outcome:partial"}]}
        with mock.patch.object(matcher, "http", side_effect=fake_http), \
             mock.patch.object(matcher, "clickup_get", return_value=task), \
             mock.patch.object(matcher, "clickup_put", side_effect=lambda url, key, body: puts.append(body)):
            matcher.mark_ticket_verification_required("T1", "key", "/route", "now")

        self.assertIn(
            ("POST", f"{matcher.CLICKUP_API}/task/T1/tag/customer-outcome%3Averification-required", None),
            calls,
        )
        self.assertEqual(puts, [{"status": "waiting"}])
        self.assertNotIn({"status": "resolved"}, puts)


class TestMergeOutcomeWriter(unittest.TestCase):
    def test_complete_tag_is_written_before_resolved_status(self):
        calls = []

        def fake_http(method, url, headers, body=None, **_kwargs):
            calls.append((method, url, body))
            return 200, {}

        ticket = {"id": "T1", "tags": [{"name": "customer-outcome:partial"}]}
        with mock.patch.object(merged, "http", side_effect=fake_http):
            merged.comment_and_close_ticket("T1", ticket, "C1", "key")

        tag_index = next(
            i for i, call in enumerate(calls)
            if call[0] == "POST" and call[1].endswith("customer-outcome%3Acomplete")
        )
        status_index = next(
            i for i, call in enumerate(calls)
            if call[0] == "PUT" and call[2] == {"status": "resolved"}
        )
        self.assertLess(tag_index, status_index)


class TestShellMergeOutcomeWriter(unittest.TestCase):
    def test_complete_tag_is_written_before_resolved_status(self):
        source = (
            SCRIPTS / "dedup" / "sweeps" / "close-merged-tickets.sh"
        ).read_text()
        tag_write = source.index(
            'clickup_curl POST "/task/$task_id/tag/customer-outcome%3Acomplete"'
        )
        status_write = source.index(
            'clickup_curl PUT "/task/$task_id"', tag_write
        )
        self.assertLess(tag_write, status_write)
        self.assertIn("refusing to resolve", source[tag_write:status_write])

    def test_stale_outcome_names_are_fully_url_encoded(self):
        source = (
            SCRIPTS / "dedup" / "sweeps" / "close-merged-tickets.sh"
        ).read_text()
        self.assertIn("'$tag | @uri'", source)


if __name__ == "__main__":
    unittest.main()
