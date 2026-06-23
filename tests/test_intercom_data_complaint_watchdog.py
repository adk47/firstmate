"""Behavioral tests for scripts/intercom-data-complaint-watchdog.py.

This watchdog is the SYSTEMIC cluster detector (Aaron 2026-06-23): it pages the
priority channel only when the same data category crosses MANY distinct users,
not per individual complaint. CI's py_compile proves the script parses; these
tests prove the *decisions* that make it a useful systemic detector:

  - detect_complaint fires on a keyword match (data noun + complaint signal) OR
    Caroline's `ai:data-complaint` tag, and maps the match to a coarse category;
  - find_clusters counts DISTINCT users per category and only surfaces a
    category at/above the threshold (a single loud user is NOT systemic);
  - DATA_COMPLAINT_TAG stays in sync with the plugin's tag;
  - the cooldown ledger is per-CATEGORY;
  - slack_escape / the copy-block fence neutralize injection in untrusted text.

Stdlib unittest + stubs only — no pytest, no network.
"""
import importlib.util
import pathlib
import re
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


def make_conv(body="", created_at=AT - 1000, tags=(), email="user@example.com", cid="c1"):
    return {
        "id": cid,
        "created_at": created_at,
        "tags": {"tags": [{"name": n} for n in tags]},
        "source": {"body": body, "author": {"email": email}},
    }


class Categorize(unittest.TestCase):
    def test_coarse_buckets(self):
        self.assertEqual(wd.categorize("credit"), "credits")
        self.assertEqual(wd.categorize("credits"), "credits")
        self.assertEqual(wd.categorize("streams"), "analytics")
        self.assertEqual(wd.categorize("plays"), "analytics")
        self.assertEqual(wd.categorize("analytics"), "analytics")
        self.assertEqual(wd.categorize("profile"), "profile")
        self.assertEqual(wd.categorize("metadata"), "profile")
        self.assertEqual(wd.categorize("anything-else"), "data")


class DetectComplaint(unittest.TestCase):
    def test_keyword_complaint_fires_with_category(self):
        ev = wd.detect_complaint(make_conv(body="all my credits are wrong", email="a@x.com"))
        self.assertIsNotNone(ev)
        self.assertEqual(ev["category"], "credits")
        self.assertEqual(ev["email"], "a@x.com")
        self.assertEqual(ev["user"], "a@x.com")

    def test_tag_only_fires_as_data(self):
        # Keywords miss it, but Caroline tagged it — still counted (generic bucket).
        ev = wd.detect_complaint(make_conv(body="something is off here", tags=("ai:data-complaint",)))
        self.assertIsNotNone(ev)
        self.assertEqual(ev["category"], "data")

    def test_calm_question_does_not_fire(self):
        self.assertIsNone(wd.detect_complaint(make_conv(body="how do I add credits?")))

    def test_anonymous_user_keyed_by_conversation(self):
        ev = wd.detect_complaint(make_conv(body="my streams are wrong", email="", cid="cZ"))
        self.assertEqual(ev["user"], "anon:cZ")


class FindClusters(unittest.TestCase):
    def test_three_distinct_users_form_a_cluster(self):
        convs = [
            make_conv(body="my credits are wrong", email="a@x.com", cid="1"),
            make_conv(body="credits missing", email="b@x.com", cid="2"),
            make_conv(body="credits incorrect", email="c@x.com", cid="3"),
        ]
        clusters, groups = wd.find_clusters(convs, threshold=3)
        self.assertIn("credits", clusters)
        self.assertEqual(len(clusters["credits"]), 3)

    def test_two_users_is_not_systemic(self):
        convs = [
            make_conv(body="my credits are wrong", email="a@x.com", cid="1"),
            make_conv(body="credits missing", email="b@x.com", cid="2"),
        ]
        clusters, _ = wd.find_clusters(convs, threshold=3)
        self.assertNotIn("credits", clusters)

    def test_same_user_counts_once(self):
        # One loud user reporting three times is not three users.
        convs = [
            make_conv(body="my credits are wrong", email="a@x.com", cid="1"),
            make_conv(body="credits still missing", email="a@x.com", cid="2"),
            make_conv(body="credits incorrect again", email="a@x.com", cid="3"),
        ]
        clusters, groups = wd.find_clusters(convs, threshold=3)
        self.assertEqual(len(groups["credits"]), 1)
        self.assertNotIn("credits", clusters)

    def test_tag_only_hits_bucket_as_data_not_the_keyword_category(self):
        convs = [
            make_conv(body="my credits are wrong", email="a@x.com", cid="1"),
            make_conv(body="credits missing", email="b@x.com", cid="2"),
            # keyword miss, tagged — counts under "data", not "credits"
            make_conv(body="subtle complaint keywords miss", tags=("ai:data-complaint",), email="c@x.com", cid="3"),
        ]
        clusters, groups = wd.find_clusters(convs, threshold=3)
        self.assertEqual(len(groups["credits"]), 2)
        self.assertEqual(len(groups["data"]), 1)
        self.assertNotIn("credits", clusters)

    def test_email_casing_counts_as_one_user(self):
        # Case-insensitive email: "A@x"/"a@x" is one human, not two — must NOT
        # let a single user falsely cross the threshold.
        convs = [
            make_conv(body="my credits are wrong", email="Alice@X.com", cid="1"),
            make_conv(body="credits still missing", email="alice@x.com", cid="2"),
            make_conv(body="credits incorrect", email="ALICE@x.COM", cid="3"),
        ]
        clusters, groups = wd.find_clusters(convs, threshold=3)
        self.assertEqual(len(groups["credits"]), 1)
        self.assertNotIn("credits", clusters)

    def test_analytics_nouns_cluster_together(self):
        convs = [
            make_conv(body="my streams are wrong", email="a@x.com", cid="1"),
            make_conv(body="plays not updating", email="b@x.com", cid="2"),
            make_conv(body="analytics outdated", email="c@x.com", cid="3"),
        ]
        clusters, _ = wd.find_clusters(convs, threshold=3)
        self.assertIn("analytics", clusters)
        self.assertEqual(len(clusters["analytics"]), 3)


class Cooldown(unittest.TestCase):
    def test_prune_is_per_category(self):
        cooldown = 24 * 3600
        led = {"credits": AT - 100, "analytics": AT - 10 * 24 * 3600}
        pruned = wd.prune_ledger(led, AT, cooldown)
        self.assertIn("credits", pruned)
        self.assertNotIn("analytics", pruned)


class Escaping(unittest.TestCase):
    def test_slack_escape_ampersand_first(self):
        self.assertEqual(wd.slack_escape("a & b < c > d"), "a &amp; b &lt; c &gt; d")

    def test_slack_escape_neutralizes_channel_ping(self):
        self.assertEqual(wd.slack_escape("<!channel>"), "&lt;!channel&gt;")


class SystemicMessage(unittest.TestCase):
    def _cluster(self, snippet="credits gone", email="luis@x.com"):
        ev = {"category": "credits", "user": email, "email": email,
              "conv_id": "9", "snippet": snippet, "ts": AT, "matched": "credits/wrong"}
        return {"credits": {email: ev}}

    def test_renders_mention_count_and_deeplink(self):
        msg = wd.build_systemic_message(self._cluster(), ["U7RP6HKUZ"], "ws_1", 24, 8)
        self.assertIn("<@U7RP6HKUZ>", msg)
        self.assertIn("1 users reporting credits problems", msg)
        self.assertIn("ws_1", msg)
        self.assertIn("/9", msg)

    def test_escapes_injection_in_snippet(self):
        msg = wd.build_systemic_message(self._cluster(snippet="fix it <!channel>"), ["U7RP6HKUZ"], "ws_1", 24, 8)
        # The mrkdwn body escapes it; only the trusted mention renders a ping.
        self.assertIn("&lt;!channel&gt;", msg)
        self.assertEqual(len(re.findall(r"<@U", msg)), 1)

    def test_copy_block_neutralizes_fence_breakout(self):
        ev = {"category": "credits", "user": "a@x.com", "email": "a@x.com",
              "conv_id": "9", "snippet": "see ``` <@U999>", "ts": AT, "matched": "credits/wrong"}
        block = wd.build_copy_block({"credits": {"a@x.com": ev}}, "ws_1", 24, 8)
        # Exactly the two wrapping fences — the customer's ``` was stripped.
        self.assertEqual(block.count("```"), 2)


class DataComplaintTag(unittest.TestCase):
    def test_tag_matches_plugin(self):
        # Must equal DATA_COMPLAINT_TAG in plugins/intercom/src/priority-signal.ts.
        self.assertEqual(wd.DATA_COMPLAINT_TAG, "ai:data-complaint")


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


if __name__ == "__main__":
    unittest.main()
