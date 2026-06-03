"""Behavioral tests for scripts/intercom-intake-watchdog.py.

The watchdog is the *only* tripwire for the April-2026 intake-outage class
(see memory:project_intercom_webhook_outage_2026-04-28): inbound Intercom
conversations keep arriving but Caroline stops processing them, and nobody
notices for weeks. CI's py_compile proves the script parses; these tests prove
the *decisions* that make it a tripwire still hold:

  - is_processed recognises every "Caroline engaged it" signal (ai:* tag,
    admin reply, closed/snoozed) and ONLY those — a regression that widened
    or narrowed this predicate would silence the alarm or cry wolf;
  - fetch_created_between walks Intercom pagination and honours the
    [start, end) window boundary;
  - main() judges health correctly across below-min-volume (don't judge),
    unhealthy (alert), and healthy (no alert), only posts to Slack when
    genuinely unhealthy AND --alert, and degrades cleanly on an Intercom
    API error or bad input.

Stdlib unittest + stubs only — no pytest dependency, no network — so it runs
under the same bare `python3` the py_compile CI job already uses.
"""
import importlib.util
import io
import json
import os
import pathlib
import sys
import unittest
import urllib.error
from contextlib import redirect_stderr, redirect_stdout
from unittest import mock

# The script has a hyphenated filename, so it can't be imported by name;
# load it from its path as the module `wd`.
_SCRIPT = (
    pathlib.Path(__file__).resolve().parent.parent
    / "scripts"
    / "intercom-intake-watchdog.py"
)
_spec = importlib.util.spec_from_file_location("intercom_intake_watchdog", _SCRIPT)
wd = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(wd)

AT = 1_000_000  # fixed "now" so age/window math is deterministic


def make_conv(created_at=AT - 4000, state="open", last_admin_reply_at=0, tags=()):
    """Build a conversation dict shaped like Intercom's search response."""
    return {
        "created_at": created_at,
        "state": state,
        "statistics": {"last_admin_reply_at": last_admin_reply_at},
        "tags": {"tags": [{"name": n} for n in tags]},
    }


def made(n, processed):
    """n conversations created just inside any window, each processed or not."""
    out = []
    for i in range(n):
        c = make_conv(created_at=AT - 4000 - i)
        if processed:
            c["state"] = "closed"
        out.append(c)
    return out


class IsProcessed(unittest.TestCase):
    """The predicate that defines "Caroline handled it"."""

    def test_ai_tag_counts_as_processed(self):
        self.assertTrue(wd.is_processed(make_conv(tags=("ai:billing",))))

    def test_admin_reply_counts_as_processed(self):
        self.assertTrue(wd.is_processed(make_conv(last_admin_reply_at=12345)))

    def test_closed_counts_as_processed(self):
        self.assertTrue(wd.is_processed(make_conv(state="closed")))

    def test_snoozed_counts_as_processed(self):
        self.assertTrue(wd.is_processed(make_conv(state="snoozed")))

    def test_open_untouched_is_unprocessed(self):
        self.assertFalse(wd.is_processed(make_conv()))

    def test_non_ai_tag_does_not_count(self):
        # a human "vip"/"urgent" tag is not Caroline engaging the conversation
        self.assertFalse(wd.is_processed(make_conv(tags=("vip", "urgent"))))

    def test_tag_named_ai_without_colon_is_not_processed(self):
        # guards against a `.startswith("ai")` regression that would treat any
        # tag merely beginning with "ai" (e.g. "airline") as a topic tag and
        # mask an outage
        self.assertFalse(wd.is_processed(make_conv(tags=("ai", "airline"))))

    def test_zero_admin_reply_timestamp_is_unprocessed(self):
        # last_admin_reply_at present but 0 must NOT count (the `!= 0` guard)
        self.assertFalse(wd.is_processed(make_conv(last_admin_reply_at=0)))


class FetchPagination(unittest.TestCase):
    """fetch_created_between must walk every page and respect the window."""

    def test_walks_all_pages_then_stops(self):
        pages = [
            {
                "conversations": [make_conv(10), make_conv(20)],
                "pages": {"next": {"starting_after": "cursor1"}},
            },
            {"conversations": [make_conv(30)], "pages": {"next": None}},
        ]
        calls = []

        def fake_search(_token, body):
            calls.append(body)
            return pages[len(calls) - 1]

        with mock.patch.object(wd, "_intercom_search", side_effect=fake_search):
            out = wd.fetch_created_between("tok", start_ts=0, end_ts=100)

        self.assertEqual(len(out), 3)
        self.assertEqual(len(calls), 2)  # stopped once next was None
        # page 1 carries no cursor; page 2 carries the cursor page 1 returned
        self.assertNotIn("starting_after", calls[0]["pagination"])
        self.assertEqual(calls[1]["pagination"]["starting_after"], "cursor1")

    def test_filters_conversations_outside_window(self):
        page = {
            "conversations": [make_conv(5), make_conv(50), make_conv(150)],
            "pages": {"next": None},
        }
        with mock.patch.object(wd, "_intercom_search", return_value=page):
            out = wd.fetch_created_between("tok", start_ts=10, end_ts=100)
        # [start, end): 5 is before, 150 is at/after the end → only 50 kept
        self.assertEqual([c["created_at"] for c in out], [50])


class Assess(unittest.TestCase):
    """assess aggregates is_processed over the fetched window."""

    def test_fraction_and_oldest_unprocessed(self):
        convs = [
            make_conv(AT - 5000, state="closed"),   # processed
            make_conv(AT - 4000),                    # unprocessed, age ~1.1h
            make_conv(AT - 6000, tags=("ai:x",)),    # processed
        ]
        with mock.patch.object(wd, "fetch_created_between", return_value=convs):
            a = wd.assess("tok", at_ts=AT, window_hours=2, grace_hours=1)
        self.assertEqual(a["total_created"], 3)
        self.assertEqual(a["processed"], 2)
        self.assertEqual(a["unprocessed"], 1)
        self.assertEqual(a["processed_fraction"], round(2 / 3, 3))
        self.assertEqual(a["oldest_unprocessed_hours"], 1.1)

    def test_empty_window_reports_fraction_one(self):
        with mock.patch.object(wd, "fetch_created_between", return_value=[]):
            a = wd.assess("tok", at_ts=AT, window_hours=6, grace_hours=1)
        self.assertEqual(a["total_created"], 0)
        self.assertEqual(a["processed_fraction"], 1.0)
        self.assertIsNone(a["oldest_unprocessed_hours"])

    def test_window_spans_full_window_hours_ending_after_grace(self):
        # The analyzed window must be exactly window_hours long and end
        # grace_hours before `at`, and assess must fetch exactly that range.
        captured = {}

        def fake_fetch(_token, start_ts, end_ts):
            captured["start"], captured["end"] = start_ts, end_ts
            return []

        with mock.patch.object(wd, "fetch_created_between", side_effect=fake_fetch):
            a = wd.assess("tok", at_ts=AT, window_hours=6, grace_hours=1)
        self.assertEqual(AT - a["window_end"], 1 * 3600)                 # ends 1h ago
        self.assertEqual(a["window_end"] - a["window_start"], 6 * 3600)  # 6h span
        self.assertEqual((captured["start"], captured["end"]),
                         (a["window_start"], a["window_end"]))

    def test_large_grace_does_not_shrink_or_empty_the_window(self):
        # Regression guard: anchoring start at at_ts made the span
        # (window - grace), so grace >= window emptied the window and pinned
        # the fraction at 1.0 (watchdog blind). Span must stay == window_hours.
        with mock.patch.object(wd, "fetch_created_between", return_value=[]):
            a = wd.assess("tok", at_ts=AT, window_hours=6, grace_hours=10)
        self.assertEqual(a["window_end"] - a["window_start"], 6 * 3600)
        self.assertEqual(AT - a["window_end"], 10 * 3600)


class MainDecisions(unittest.TestCase):
    """End-to-end health verdicts and the single Slack side effect."""

    def _run(self, argv, *, convs=None, search_error=None, slack_token="xoxb-test"):
        """Invoke main() with stubbed network; return (rc, stdout, stderr, slack_mock)."""
        out, err = io.StringIO(), io.StringIO()
        env = {"MUSOAI_INTERCOM_TOKEN": "tok"}
        with mock.patch.dict(os.environ, env, clear=True), mock.patch.object(
            sys, "argv", ["intercom-intake-watchdog.py", *argv]
        ), mock.patch.object(
            wd, "resolve_slack_token", return_value=slack_token
        ), mock.patch.object(
            wd, "slack_post", return_value=True
        ) as slack, redirect_stdout(out), redirect_stderr(err):
            if search_error is not None:
                with mock.patch.object(wd, "_intercom_search", side_effect=search_error):
                    rc = wd.main()
            else:
                with mock.patch.object(wd, "fetch_created_between", return_value=convs or []):
                    rc = wd.main()
        return rc, out.getvalue(), err.getvalue(), slack

    @staticmethod
    def _payload(stdout):
        return json.loads(stdout.strip().splitlines()[0])

    def test_below_min_volume_is_not_judged_and_never_alerts(self):
        # 4 < min-volume 5: even all-unprocessed and --alert must not fire
        rc, out, err, slack = self._run(
            ["--alert", "--at", str(AT), "--min-volume", "5", "--min-processed", "0.4"],
            convs=made(4, processed=False),
        )
        self.assertEqual(rc, 0)
        slack.assert_not_called()
        payload = self._payload(out)
        self.assertFalse(payload["judged"])
        self.assertFalse(payload["unhealthy"])
        self.assertIn("below min-volume", err)

    def test_unhealthy_posts_one_slack_alert(self):
        rc, out, err, slack = self._run(
            ["--alert", "--at", str(AT), "--min-volume", "5", "--min-processed", "0.4"],
            convs=made(10, processed=False),
        )
        self.assertEqual(rc, 0)
        slack.assert_called_once()
        _token, channel, text = slack.call_args.args
        self.assertEqual(channel, wd.DEFAULT_SLACK_CHANNEL)
        self.assertIn(":rotating_light:", text)
        self.assertTrue(self._payload(out)["unhealthy"])

    def test_healthy_does_not_alert(self):
        rc, out, err, slack = self._run(
            ["--alert", "--at", str(AT), "--min-volume", "5", "--min-processed", "0.4"],
            convs=made(10, processed=True),
        )
        self.assertEqual(rc, 0)
        slack.assert_not_called()
        payload = self._payload(out)
        self.assertFalse(payload["unhealthy"])
        self.assertEqual(payload["processed_fraction"], 1.0)
        self.assertIn("healthy", err)

    def test_unhealthy_in_check_mode_reports_but_does_not_post(self):
        rc, out, err, slack = self._run(
            ["--check", "--at", str(AT), "--min-volume", "5", "--min-processed", "0.4"],
            convs=made(10, processed=False),
        )
        self.assertEqual(rc, 0)
        slack.assert_not_called()
        self.assertIn("UNHEALTHY (would alert", err)

    def test_unhealthy_alert_without_slack_token_exits_one(self):
        rc, out, err, slack = self._run(
            ["--alert", "--at", str(AT), "--min-volume", "5", "--min-processed", "0.4"],
            convs=made(10, processed=False),
            slack_token=None,
        )
        self.assertEqual(rc, 1)
        slack.assert_not_called()
        self.assertIn("no Slack bot token", err)

    def test_intercom_api_error_exits_two(self):
        rc, out, err, slack = self._run(
            ["--check", "--at", str(AT)],
            search_error=urllib.error.URLError("boom"),
        )
        self.assertEqual(rc, 2)
        self.assertIn("Intercom API failed", err)


class MainUsageErrors(unittest.TestCase):
    """Clean exits on bad environment / input — never a stack trace."""

    def test_missing_token_exits_one(self):
        err = io.StringIO()
        with mock.patch.dict(os.environ, {}, clear=True), mock.patch.object(
            sys, "argv", ["intercom-intake-watchdog.py", "--check"]
        ), redirect_stderr(err), redirect_stdout(io.StringIO()):
            rc = wd.main()
        self.assertEqual(rc, 1)
        self.assertIn("MUSOAI_INTERCOM_TOKEN", err.getvalue())

    def test_bad_at_value_exits_one(self):
        err = io.StringIO()
        with mock.patch.dict(
            os.environ, {"MUSOAI_INTERCOM_TOKEN": "tok"}, clear=True
        ), mock.patch.object(
            sys, "argv", ["intercom-intake-watchdog.py", "--check", "--at", "not-a-date"]
        ), redirect_stderr(err), redirect_stdout(io.StringIO()):
            rc = wd.main()
        self.assertEqual(rc, 1)
        self.assertIn("bad --at", err.getvalue())


if __name__ == "__main__":
    unittest.main()
