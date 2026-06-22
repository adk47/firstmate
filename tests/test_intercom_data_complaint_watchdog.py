"""Behavioral tests for scripts/intercom-data-complaint-watchdog.py.

This is Lane B — the backstop that catches DATA complaints Caroline's inline
`[[PRIORITY]]` signal under-flagged or failed to page (Aaron's 2026-06-22 ask).
CI's py_compile proves the script parses; these tests prove the *decisions*
that make it a useful backstop without spamming Aaron:

  - complaint_match fires only when a data noun co-occurs with a complaint
    signal — a calm "how do I add credits?" must NOT page, "my credits are all
    wrong" must;
  - already_paged honours the ai:priority-paged cross-lane dedup tag that Lane A
    sets (this string must stay in sync with PRIORITY_PAGED_TAG in
    priority-signal.ts);
  - the cooldown ledger suppresses re-paging the same conversation within the
    window;
  - slack_escape neutralizes <!channel>/<@U> injection in untrusted customer
    text, while the trusted config mention still renders.

Stdlib unittest + stubs only — no pytest, no network — so it runs under the
same bare `python3` the py_compile CI job already uses.
"""
import importlib.util
import pathlib
import unittest

_SCRIPT = (
    pathlib.Path(__file__).resolve().parent.parent
    / "scripts"
    / "intercom-data-complaint-watchdog.py"
)
_spec = importlib.util.spec_from_file_location("intercom_data_complaint_watchdog", _SCRIPT)
wd = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(wd)

AT = 1_000_000


def make_conv(body="", created_at=AT - 1000, tags=(), email="user@example.com"):
    return {
        "id": "c1",
        "created_at": created_at,
        "tags": {"tags": [{"name": n} for n in tags]},
        "source": {"body": body, "author": {"email": email}},
    }


class ComplaintMatch(unittest.TestCase):
    def test_data_noun_plus_complaint_signal_fires(self):
        self.assertIsNotNone(wd.complaint_match("all my credits are wrong!"))
        self.assertIsNotNone(wd.complaint_match("my stream counts have been wrong for weeks"))
        self.assertIsNotNone(wd.complaint_match("my profile data is missing"))

    def test_calm_question_does_not_fire(self):
        # Data noun but no complaint signal — must not page Aaron.
        self.assertIsNone(wd.complaint_match("how do I add credits to my profile?"))
        self.assertIsNone(wd.complaint_match("where can I see my streams?"))

    def test_complaint_without_data_noun_does_not_fire(self):
        # Frustration but not about data — out of scope for this lane.
        self.assertIsNone(wd.complaint_match("this is broken and I am angry about billing"))

    def test_analytics_in_scope(self):
        # Scope per Nick: analytics/stream-counts ARE in scope for the page.
        self.assertIsNotNone(wd.complaint_match("the analytics are outdated and wrong"))


class AlreadyPaged(unittest.TestCase):
    def test_skips_conversation_lane_a_already_paged(self):
        self.assertTrue(wd.already_paged(make_conv(tags=("ai:priority-paged",))))

    def test_does_not_skip_untagged(self):
        self.assertFalse(wd.already_paged(make_conv(tags=("ai:credits",))))

    def test_tag_constant_matches_plugin(self):
        # The cross-lane dedup contract: must equal PRIORITY_PAGED_TAG in
        # plugins/intercom/src/priority-signal.ts.
        self.assertEqual(wd.PRIORITY_PAGED_TAG, "ai:priority-paged")


class FindCandidates(unittest.TestCase):
    def _patch_fetch(self, convs):
        wd.fetch_created_between = lambda *a, **k: convs

    def test_picks_complaints_and_skips_paged_and_calm(self):
        convs = [
            make_conv(body="my credits are all wrong", email="a@x.com"),
            make_conv(body="how do I claim a profile?", email="b@x.com"),  # calm
            make_conv(body="data is missing", tags=("ai:priority-paged",), email="c@x.com"),  # paged
        ]
        self._patch_fetch(convs)
        out = wd.find_candidates("tok", AT, 60, 3)
        emails = [c["email"] for c in out["candidates"]]
        self.assertEqual(emails, ["a@x.com"])


class Cooldown(unittest.TestCase):
    def test_prune_keeps_recent_drops_old(self):
        cooldown = 24 * 3600
        led = {"recent": AT - 100, "old": AT - 10 * 24 * 3600}
        pruned = wd.prune_ledger(led, AT, cooldown)
        self.assertIn("recent", pruned)
        self.assertNotIn("old", pruned)


class SlackEscape(unittest.TestCase):
    def test_escapes_ampersand_first(self):
        self.assertEqual(wd.slack_escape("a & b < c > d"), "a &amp; b &lt; c &gt; d")

    def test_neutralizes_channel_ping(self):
        self.assertEqual(wd.slack_escape("<!channel>"), "&lt;!channel&gt;")


class ResolveSlackToken(unittest.TestCase):
    # MY_BOT is set by test_var_name_is_overridable — include it so setUp/tearDown
    # save+restore it and it never leaks into the process env for later tests.
    KEYS = ("MUSO_SLACK_BOT_TOKEN_OPERATIONS", "SLACK_BOT_TOKEN",
            "PRIORITY_SLACK_BOT_TOKEN_VAR", "OPENCLAW_CONFIG", "MY_BOT")

    def setUp(self):
        import os
        self._saved = {k: os.environ.pop(k, None) for k in self.KEYS}

    def tearDown(self):
        import os
        for k, v in self._saved.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v

    def test_prefers_ops_bot_token(self):
        # Lane B unifies on the Ops bot identity with Lane A.
        import os
        os.environ["MUSO_SLACK_BOT_TOKEN_OPERATIONS"] = "xoxb-ops"
        os.environ["SLACK_BOT_TOKEN"] = "xoxb-other"
        self.assertEqual(wd.resolve_slack_token(), "xoxb-ops")

    def test_falls_back_to_slack_bot_token(self):
        import os
        os.environ["SLACK_BOT_TOKEN"] = "xoxb-fallback"
        self.assertEqual(wd.resolve_slack_token(), "xoxb-fallback")

    def test_var_name_is_overridable(self):
        import os
        os.environ["PRIORITY_SLACK_BOT_TOKEN_VAR"] = "MY_BOT"
        os.environ["MY_BOT"] = "xoxb-custom"
        self.assertEqual(wd.resolve_slack_token(), "xoxb-custom")


class BuildMessage(unittest.TestCase):
    def test_renders_trusted_mention_and_escapes_snippet(self):
        cands = [{"id": "9", "email": "u@x.com", "matched": "credits/wrong",
                  "snippet": "fix it <!channel>"}]
        msg = wd.build_message(cands, ["U7RP6HKUZ"], "ws_1")
        self.assertIn("<@U7RP6HKUZ>", msg)        # trusted mention renders
        self.assertIn("&lt;!channel&gt;", msg)    # untrusted snippet escaped
        self.assertNotIn("<!channel>", msg)
        self.assertIn("ws_1", msg)                 # deeplink present
        self.assertIn("/9", msg)

    def test_ignores_malformed_mention_id(self):
        msg = wd.build_message([{"id": "9", "email": "", "matched": "x/y", "snippet": "s"}],
                               ["not a real id <!channel>"], "ws_1")
        self.assertNotIn("<!channel>", msg)


if __name__ == "__main__":
    unittest.main()
