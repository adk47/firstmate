"""resolve-notify's ClickUp scan carries one server-side tags[] filter.

The filter is lossless only because extract_candidate requires the same tag.
Stdlib unittest, no network.
"""
import importlib.util
import pathlib
import json
import unittest
from unittest import mock
import urllib.parse

_SCRIPT = pathlib.Path(__file__).resolve().parent.parent / "scripts" / "resolve-notify.py"
_spec = importlib.util.spec_from_file_location("resolve_notify", _SCRIPT)
rn = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(rn)

TAG = "customer-outcome:complete"


class _Resp:
    status = 200

    def __init__(self, payload):
        self._p = payload

    def read(self):
        return json.dumps(self._p).encode()

    def __enter__(self):
        return self

    def __exit__(self, *a):
        return False


class ResolveNotifyFilter(unittest.TestCase):
    def test_list_page_url_has_tag_filter_and_include_closed(self):
        # The fetch goes through the shared ClickUp client (429 handling), so
        # inject urlopen into it and read the URL it actually requested.
        seen = []

        def urlopen(req, timeout=None):
            seen.append(req.full_url)
            return _Resp({"tasks": []})

        client = rn.clickup_client.ClickUp("k", urlopen=urlopen, sleep=lambda s: None)
        with mock.patch.object(rn.clickup_client, "shared",
                               lambda key, base=None: client):
            rn.clickup_list_page("k", "L", 0)
        q = urllib.parse.parse_qs(urllib.parse.urlparse(seen[0]).query)
        self.assertEqual(q.get("tags[]"), [TAG])
        self.assertEqual(q.get("include_closed"), ["true"])

    def test_task_without_the_filter_tag_is_never_a_candidate(self):
        # Couples the URL filter to extract_candidate: a passing candidate minus
        # the filter tag must stop being one. If that gate is dropped, SERVER_TAG
        # (and this test) must change with it.
        link = "https://app.intercom.com/a/inbox/w/inbox/conversation/C1"
        task = {"id": "T", "status": {"type": "done", "status": "complete"},
                "tags": [{"name": "hydra-action-request"},
                         {"name": "action:credit-verify"}, {"name": TAG}],
                "custom_fields": [{"id": rn.INTERCOM_LINK_FIELD, "value": link}],
                "description": '---ACTION-REQUEST---\n{"customer_email": "a@b.com"}\n---END-ACTION-REQUEST---'}
        cand, _ = rn.extract_candidate(task, 1_800_000_000)
        self.assertIsNotNone(cand)
        task["tags"] = [t for t in task["tags"] if t["name"] != TAG]
        cand, reason = rn.extract_candidate(task, 1_800_000_000)
        self.assertIsNone(cand)
        self.assertEqual(reason, "customer-outcome")
        self.assertEqual(rn.SERVER_TAG, TAG)


if __name__ == "__main__":
    unittest.main()
