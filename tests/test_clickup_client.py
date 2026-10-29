"""scripts/lib/clickup_client.py: 429 handling, throttle, strict paging, and the
callers that must never act on a partial ClickUp scan. Stdlib unittest, no network:
urlopen, sleep and the clock are injected; nothing is sent anywhere."""
import email.message
import importlib.util
import json
import os
import pathlib
import sys
import tempfile
import unittest
import urllib.error
from unittest import mock

ROOT = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))
from lib import clickup_client as cc  # noqa: E402


def load(name, fname):
    spec = importlib.util.spec_from_file_location(name, ROOT / "scripts" / fname)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


class Resp:
    def __init__(self, payload, status=200):
        self.status, self._p = status, payload

    def read(self):
        return json.dumps(self._p).encode()

    def __enter__(self):
        return self

    def __exit__(self, *a):
        return False


def err429(**headers):
    h = email.message.Message()
    for k, v in headers.items():
        h[k.replace("_", "-")] = str(v)
    return urllib.error.HTTPError("https://api.clickup.com/x", 429, "Too Many Requests", h, None)


class Script:
    """urlopen stub: replays `steps` (exception -> raised, other -> Resp), then the last one forever."""

    def __init__(self, *steps):
        self.steps, self.calls = list(steps), []

    def __call__(self, req, timeout=None):
        self.calls.append(req.full_url)
        step = self.steps[min(len(self.calls), len(self.steps)) - 1]
        if isinstance(step, Exception):
            raise step
        return Resp(step)


def client(script, now=1000.0, **kw):
    sleeps = []
    c = cc.ClickUp("k", urlopen=script, sleep=sleeps.append, clock=lambda: now, **kw)
    return c, sleeps


class RateLimit(unittest.TestCase):
    def test_a_429_waits_until_the_reset_header_then_returns_the_body(self):
        c, sleeps = client(Script(err429(X_RateLimit_Reset=1007), {"ok": 1}))
        self.assertEqual(c.request("GET", "/list/1/task"), (200, {"ok": 1}))
        self.assertEqual(sleeps, [7])

    def test_b_429_on_every_attempt_raises_after_exactly_attempts_calls(self):
        s = Script(err429(X_RateLimit_Reset=999999))  # far future: must be clamped
        c, sleeps = client(s, attempts=5)
        with self.assertRaises(cc.ClickUpRateLimited) as cm:
            c.request("GET", "/list/1/task")
        self.assertEqual(len(s.calls), 5)
        self.assertEqual(len(sleeps), 4)  # no sleep after the final attempt
        self.assertTrue(all(1 <= x <= 65 for x in sleeps), sleeps)
        self.assertIn("GET /api/v2/list/1/task", str(cm.exception))
        self.assertIn("5 attempts", str(cm.exception))

    def test_c_retry_after_is_used_when_there_is_no_reset_header(self):
        c, sleeps = client(Script(err429(Retry_After=3), {}))
        c.request("GET", "/x")
        self.assertEqual(sleeps, [3])

    def test_no_header_waits_60_and_a_past_reset_waits_the_minimum(self):
        c, sleeps = client(Script(err429(), err429(X_RateLimit_Reset=900), {}))
        c.request("GET", "/x")
        self.assertEqual(sleeps, [60, 1])

    def test_post_and_delete_429s_are_retried_too(self):
        for method in ("POST", "DELETE"):
            s = Script(err429(Retry_After=1), {})
            c, _ = client(s)
            self.assertEqual(c.request(method, "/task/1/tag/x", body={} if method == "POST" else None)[0], 200)
            self.assertEqual(len(s.calls), 2)

    def test_other_http_errors_are_not_retried(self):
        e = urllib.error.HTTPError("u", 500, "boom", email.message.Message(), None)
        s = Script(e, {})
        c, sleeps = client(s)
        with self.assertRaises(urllib.error.HTTPError):
            c.request("GET", "/x")
        self.assertEqual((len(s.calls), sleeps), (1, []))

    def test_url_errors_keep_the_linear_backoff(self):
        s = Script(urllib.error.URLError("down"), urllib.error.URLError("down"), {})
        c, sleeps = client(s)
        c.request("GET", "/x")
        self.assertEqual(sleeps, [2, 4])


class Throttle(unittest.TestCase):
    def test_d_the_81st_call_in_a_window_sleeps_and_the_first_80_do_not(self):
        s = Script({})
        c, sleeps = client(s, max_per_min=80)
        for i in range(80):
            c.request("GET", "/x")
        self.assertEqual(sleeps, [])
        c.request("GET", "/x")
        self.assertEqual(sleeps, [60])
        self.assertEqual(len(s.calls), 81)

    def test_calls_older_than_the_window_do_not_count(self):
        t = [1000.0]
        sleeps = []
        c = cc.ClickUp("k", urlopen=Script({}), sleep=sleeps.append, clock=lambda: t[0], max_per_min=2)
        c.request("GET", "/x")
        c.request("GET", "/x")
        t[0] += 61
        c.request("GET", "/x")
        self.assertEqual(sleeps, [])

    def test_shared_returns_one_client_per_key_so_the_window_spans_a_run(self):
        self.assertIs(cc.shared("kk"), cc.shared("kk"))
        self.assertIsNot(cc.shared("kk"), cc.shared("other"))


class ListTasks(unittest.TestCase):
    def test_e_a_200_without_a_tasks_list_raises_and_nothing_partial_returns(self):
        c, _ = client(Script({"tasks": [{"id": "a"}], "last_page": False}, {"err": "Oauth 017"}))
        with self.assertRaisesRegex(RuntimeError, "page 1"):
            c.list_tasks("L", [("a", "b")], 10)

    def test_f_exceeding_max_pages_raises(self):
        c, _ = client(Script({"tasks": [{"id": "a"}], "last_page": False}))
        with self.assertRaisesRegex(RuntimeError, "partial scan"):
            c.list_tasks("L", [], 2)

    def test_pages_dedupe_and_repeat_params_survive(self):
        s = Script({"tasks": [{"id": "a"}, {"id": "b"}], "last_page": False},
                   {"tasks": [{"id": "b"}, {"id": "c"}], "last_page": True})
        c, _ = client(s)
        out = c.list_tasks("L", [("tags[]", "x"), ("tags[]", "y")], 5)
        self.assertEqual([t["id"] for t in out], ["a", "b", "c"])
        self.assertIn("tags%5B%5D=x&tags%5B%5D=y&page=1", s.calls[1])

    def test_an_empty_batch_ends_the_scan(self):
        c, _ = client(Script({"tasks": [{"id": "a"}]}, {"tasks": []}))
        self.assertEqual(len(c.list_tasks("L", [], 5)), 1)


def clickup_down_after_page0(task_page):
    """urlopen stub: page 0 is a valid candidate page, every later page is a 429."""
    calls = []

    def urlopen(req, timeout=None):
        calls.append(req.full_url)
        if "page=0" in req.full_url:
            return Resp({"tasks": [task_page], "last_page": False})
        raise err429(Retry_After=1)
    return urlopen, calls


class PartialScanNeverSends(unittest.TestCase):
    def setUp(self):
        self.dir = pathlib.Path(tempfile.mkdtemp(prefix="cu-client-"))
        self._env = dict(os.environ)
        self.addCleanup(lambda: (os.environ.clear(), os.environ.update(self._env)))

    def _patch_client(self, mod, urlopen):
        c = cc.ClickUp("k", urlopen=urlopen, sleep=lambda s: None)
        p = mock.patch.object(mod.clickup_client, "shared", lambda key, base=None: c)
        p.start()
        self.addCleanup(p.stop)

    def test_g1_resolve_notify_sends_nothing_when_a_later_page_keeps_429ing(self):
        rn = load("rn_g1", "resolve-notify.py")
        state = self.dir / "notified.json"
        rn.write_state(str(state), {rn.SEED_SENTINEL: 1781000000})
        before = state.read_bytes()
        task = {"id": "T9", "status": {"type": "done"},
                "tags": [{"name": "hydra-action-request"}, {"name": "action:profile-claim"},
                         {"name": "customer-outcome:complete"}],
                "custom_fields": [{"id": rn.INTERCOM_LINK_FIELD, "value": "/conversation/C9"}],
                "description": "---ACTION-REQUEST---\n{\"customer_email\": \"a@b.com\"}\n---END-ACTION-REQUEST---"}
        urlopen, calls = clickup_down_after_page0(task)
        self._patch_client(rn, urlopen)
        sent = []
        rn.post_intercom_reply = lambda *a, **k: sent.append(a)
        rn.get_conversation = lambda cid, tok: sent.append(("GET", cid)) or {}
        rn.resolve_admin_id = lambda: "1"
        os.environ.update({"CLICKUP_API_KEY": "k", "MUSOAI_INTERCOM_TOKEN": "t", "RESOLVE_NOTIFY_STATE": str(state),
                           "RESOLVE_NOTIFY_SKIP_HOST_GUARD": "1"})
        with mock.patch.object(sys, "argv", ["rn", "--apply"]):
            with self.assertRaises(cc.ClickUpRateLimited):
                rn.main()
        self.assertEqual(sent, [])
        self.assertEqual(state.read_bytes(), before)
        self.assertEqual(len([c for c in calls if "page=1" in c]), 5)

    def test_g2_merge_outcome_sends_nothing_when_a_later_page_keeps_429ing(self):
        mon = load("mon_g2", "merge-outcome-notify.py")
        state = self.dir / "state.json"
        state.write_text(json.dumps({"tickets": {}}))
        before = state.read_bytes()
        task = {"id": "t1", "tags": [{"name": "hydra-action-request"}, {"name": "action:profile-merge"},
                                     {"name": "merge-outcome:merged"}], "date_created": "1000",
                "description": "x"}
        urlopen, _calls = clickup_down_after_page0(task)
        self._patch_client(mon, urlopen)
        sent = []
        mon.rn.http = lambda *a, **k: sent.append(a) or (200, {})
        mon.rn.get_conversation = lambda cid, tok: sent.append(("GET", cid)) or {}
        mon.rn.post_slack = lambda *a, **k: sent.append(("slack",)) or True
        os.environ.update({"CLICKUP_API_KEY": "k", "MUSOAI_INTERCOM_TOKEN": "t", "MERGE_OUTCOME_STATE": str(state),
                           "MERGE_KEEP_CONFLICT_SPOOL": str(self.dir / "spool")})
        try:
            rc = mon.main(["--apply"])
        except cc.ClickUpRateLimited:
            rc = "raised"
        self.assertNotEqual(rc, 0)
        self.assertEqual(sent, [])
        self.assertEqual(state.read_bytes(), before)

    def test_h_dedupe_exits_non_zero_and_never_runs_the_batch_helper(self):
        m = load("dedupe_h", "clickup-todo-dedupe.py")
        urlopen, _ = clickup_down_after_page0({"id": "a", "tags": []})
        self._patch_client(m, urlopen)
        with mock.patch.object(m.subprocess, "run") as run:
            with self.assertRaises(SystemExit) as cm:
                m.fetch_status("tok", "list", "to do")
        self.assertIn("partial scan", str(cm.exception))
        run.assert_not_called()

    def test_closer_index_raises_instead_of_returning_a_partial_index(self):
        cr = load("cr_closer", "close-resolved-conversations.py")
        urlopen, _ = clickup_down_after_page0({"id": "a", "custom_fields": [], "tags": []})
        self._patch_client(cr, urlopen)
        with self.assertRaises(cc.ClickUpRateLimited):
            cr.build_ticket_index("k", "list")

    def test_i_clickup_list_page_survives_a_429_where_main_raised_http_error(self):
        rn = load("rn_i", "resolve-notify.py")
        s = Script(err429(Retry_After=2), {"tasks": [], "last_page": True})
        self._patch_client(rn, s)
        self.assertEqual(rn.clickup_list_page("k", "L", 0), {"tasks": [], "last_page": True})
        self.assertEqual(len(s.calls), 2)


if __name__ == "__main__":
    unittest.main()
