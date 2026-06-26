"""Behavioral tests for scripts/intercom-data-complaint-watchdog.py.

This watchdog is the SYSTEMIC, AI-clustered data-issue detector (Aaron): an
operations-agent turn does the semantic "same issue" clustering; this script is
the deterministic edge — it GATHERS candidate conversations for the AI to read,
and RENDERS + pages from the agent's clusters.json. CI's py_compile proves the
script parses; these tests prove the *decisions* that keep it safe and useful:

  - --gather shapes each conversation as an AI candidate (opening message,
    who/age/state/tags/deeplink), skips conversations with nothing to classify,
    surfaces Caroline's `ai:data-complaint` tag, and caps with a LOUD drop;
  - --report validation FAILS LOUD on malformed clusters.json (never a silent
    skip), drops sub-threshold clusters, dedupes distinct users, and the
    per-issue cooldown suppresses a re-page;
  - slack_escape + Block Kit rendering keep untrusted text inert: customer/agent
    angle-brackets are escaped, the only live ping is the trusted Aaron mention,
    cite URLs are compacted only for allow-listed hosts, and the volume caps drop
    LOUDLY (never a silent "+N more");
  - DATA_COMPLAINT_TAG stays in sync with the plugin.

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

NOW = 1_000_000


def make_conv(body="", created_at=NOW - 3600, tags=(), email="user@example.com",
              cid="c1", state="open"):
    return {
        "id": cid,
        "created_at": created_at,
        "updated_at": created_at,
        "state": state,
        "tags": {"tags": [{"name": n} for n in tags]},
        "source": {"body": body, "author": {"email": email}},
    }


def cluster(slug="iss-1", title="Credits misattribution",
            symptom="Artists say muso credits them on tracks they didn't make.",
            users=None):
    return {
        "issue_slug": slug,
        "title": title,
        "symptom": symptom,
        "users": users if users is not None else [
            {"who": "a@x.com", "conv_id": "1", "email": "a@x.com", "detail": "x", "cites": []},
            {"who": "b@x.com", "conv_id": "2", "email": "b@x.com", "detail": "y", "cites": []},
        ],
    }


def block_texts(blocks):
    """Every mrkdwn/plain_text string carried by a Block Kit block, in order
    (section .text, context/elements, section .fields)."""
    out = []
    for b in blocks:
        t = b.get("text")
        if isinstance(t, dict) and isinstance(t.get("text"), str):
            out.append(t["text"])
        for el in b.get("elements", []) or []:
            if isinstance(el, dict) and isinstance(el.get("text"), str):
                out.append(el["text"])
        for fld in b.get("fields", []) or []:
            if isinstance(fld, dict) and isinstance(fld.get("text"), str):
                out.append(fld["text"])
    return out


def all_text(blocks):
    return "\n".join(block_texts(blocks))


# ── --gather ─────────────────────────────────────────────────────────────────
class Candidate(unittest.TestCase):
    def test_shapes_an_ai_candidate(self):
        c = wd.candidate(make_conv(body="<p>my credits are wrong</p>", email="A@X.com",
                                   cid="42", created_at=NOW - 7200), NOW)
        self.assertEqual(c["conv_id"], "42")
        self.assertEqual(c["who"], "a@x.com")          # normalized lower-case
        self.assertEqual(c["opening_message"], "my credits are wrong")  # HTML stripped
        self.assertEqual(c["age_hours"], 2.0)
        self.assertEqual(c["state"], "open")
        self.assertIn("/42", c["deeplink"])

    def test_anonymous_when_no_email(self):
        c = wd.candidate(make_conv(body="streams gone", email="", cid="z"), NOW)
        self.assertEqual(c["who"], "anonymous")
        self.assertEqual(c["email"], "")               # the distinct-user key carries empty

    def test_email_emitted_for_distinct_user_keying(self):
        c = wd.candidate(make_conv(body="x", email="A@X.com", cid="9"), NOW)
        self.assertEqual(c["email"], "a@x.com")        # normalized; keys distinct users

    def test_surfaces_caroline_tag(self):
        c = wd.candidate(make_conv(body="x", tags=("ai:data-complaint",)), NOW)
        self.assertIn("ai:data-complaint", c["tags"])

    def test_skips_conversation_with_nothing_to_classify(self):
        # No customer text and not tagged → nothing for the AI to read.
        self.assertIsNone(wd.candidate(make_conv(body="", tags=()), NOW))

    def test_tagged_but_empty_is_still_a_candidate(self):
        self.assertIsNotNone(wd.candidate(make_conv(body="", tags=("ai:data-complaint",)), NOW))

    def test_snippet_is_capped(self):
        c = wd.candidate(make_conv(body="x" * 5000), NOW)
        self.assertEqual(len(c["opening_message"]), wd.SNIPPET_CAP)


class Gather(unittest.TestCase):
    def test_newest_first_and_loud_cap(self):
        convs = [make_conv(body="b", cid=str(i), created_at=NOW - i * 3600) for i in range(1, 6)]
        cands, dropped = wd.gather_candidates(convs, NOW, max_n=3)
        self.assertEqual(len(cands), 3)
        self.assertEqual(dropped, 2)                     # 5 → 3, 2 dropped, surfaced by caller
        self.assertEqual([c["conv_id"] for c in cands], ["1", "2", "3"])  # newest (smallest age)

    def test_no_drop_when_under_cap(self):
        convs = [make_conv(body="b", cid=str(i)) for i in range(3)]
        _, dropped = wd.gather_candidates(convs, NOW, max_n=300)
        self.assertEqual(dropped, 0)


# ── --report: validation fails loud ──────────────────────────────────────────
class Validate(unittest.TestCase):
    def test_happy_path(self):
        clusters, excluded, win = wd.validate_clusters(
            {"window_hours": 24, "clusters": [cluster()],
             "excluded": [{"who": "e@x.com", "reason": "onboarding"}]})
        self.assertEqual(len(clusters), 1)
        self.assertEqual(excluded[0]["who"], "e@x.com")
        self.assertEqual(win, 24)

    def test_top_level_must_be_object(self):
        with self.assertRaises(wd.ClustersError):
            wd.validate_clusters([cluster()])

    def test_clusters_must_be_list(self):
        with self.assertRaises(wd.ClustersError):
            wd.validate_clusters({"clusters": "nope"})

    def test_missing_symptom_fails_loud(self):
        bad = cluster()
        del bad["symptom"]
        with self.assertRaises(wd.ClustersError):
            wd.validate_clusters({"clusters": [bad]})

    def test_user_without_conv_id_fails_loud(self):
        bad = cluster(users=[{"who": "a@x.com", "detail": "x", "cites": []}])
        with self.assertRaises(wd.ClustersError):
            wd.validate_clusters({"clusters": [bad]})

    def test_empty_users_fails_loud(self):
        with self.assertRaises(wd.ClustersError):
            wd.validate_clusters({"clusters": [cluster(users=[])]})

    def test_cites_must_be_string_list(self):
        bad = cluster(users=[{"who": "a@x.com", "conv_id": "1", "cites": [{"u": "x"}]}])
        with self.assertRaises(wd.ClustersError):
            wd.validate_clusters({"clusters": [bad]})

    def test_conv_id_must_be_numeric_blocks_link_injection(self):
        # SECURITY: a non-numeric conv_id could break out of the trusted
        # <…/{conv_id}|conversation> Slack link and inject a live <!channel>/<@U…>
        # ping. Intercom ids are digit strings — anything else must fail loud.
        for evil in ("1|x> <!channel> <@U7RP6HKUZ", "1 2", "abc", "1<b>", ""):
            with self.assertRaises(wd.ClustersError):
                wd.validate_clusters({"clusters": [cluster(
                    users=[{"who": "a@x.com", "conv_id": evil, "cites": []}])]})
        # a real numeric id validates fine
        ok, _, _ = wd.validate_clusters({"clusters": [cluster(
            users=[{"who": "a@x.com", "conv_id": "215474812001295", "cites": []}])]})
        self.assertEqual(ok[0]["users"][0]["conv_id"], "215474812001295")

    def test_excluded_malformed_fails_loud(self):
        with self.assertRaises(wd.ClustersError):   # missing reason
            wd.validate_clusters({"clusters": [cluster()], "excluded": [{"who": "a@x.com"}]})
        with self.assertRaises(wd.ClustersError):   # not an object
            wd.validate_clusters({"clusters": [cluster()], "excluded": ["nope"]})


# ── --report: threshold + cooldown ───────────────────────────────────────────
class DistinctUsers(unittest.TestCase):
    def test_same_email_across_conversations_counts_once(self):
        # One customer who opened two conversations is ONE user (keyed by email,
        # case-insensitive) — must not falsely cross the threshold on their own.
        c = cluster(users=[
            {"who": "Alice", "conv_id": "1", "email": "A@x.com", "cites": []},
            {"who": "Alice again", "conv_id": "2", "email": "a@x.com", "cites": []},
        ])
        self.assertEqual(wd.distinct_users(c), 1)

    def test_two_anonymous_conversations_count_as_two(self):
        # REGRESSION (QA #584): two DIFFERENT anonymous customers reporting the
        # same issue are two users — keyed by conv_id, not collapsed by the shared
        # "anonymous" who label. Without this they'd fall below >=2 and never page.
        c = cluster(users=[
            {"who": "anonymous", "conv_id": "111", "email": "", "cites": []},
            {"who": "anonymous", "conv_id": "222", "email": "", "cites": []},
        ])
        self.assertEqual(wd.distinct_users(c), 2)

    def test_two_distinct_emails(self):
        self.assertEqual(wd.distinct_users(cluster()), 2)


class Cooldown(unittest.TestCase):
    def test_prune_is_per_issue(self):
        cd = 24 * 3600
        led = {"iss-fresh": NOW - 100, "iss-stale": NOW - 10 * 24 * 3600}
        pruned = wd.prune_ledger(led, NOW, cd)
        self.assertIn("iss-fresh", pruned)
        self.assertNotIn("iss-stale", pruned)


class ReportDecision(unittest.TestCase):
    """run_report's threshold + per-issue cooldown decision, end to end, via
    --check (no Slack, no network). Proves the things the report exists to do."""
    import os as _os

    def _args(self, clusters_path, **over):
        import types
        base = dict(report=True, gather=False, clusters=clusters_path, check=True,
                    threshold=2, cooldown_hours=24, window_hours=24.0,
                    grace_minutes=2, max=300, at=None)
        base.update(over)
        return types.SimpleNamespace(**base)

    def _write(self, obj):
        import json
        import tempfile
        fd, path = tempfile.mkstemp(suffix=".json")
        with self._os.fdopen(fd, "w") as f:
            json.dump(obj, f)
        self.addCleanup(lambda: self._os.path.exists(path) and self._os.remove(path))
        return path

    def setUp(self):
        import tempfile
        self._led = tempfile.mktemp(suffix=".json")
        self._saved = self._os.environ.get("LEDGER_PATH")
        self._os.environ["LEDGER_PATH"] = self._led

    def tearDown(self):
        if self._saved is None:
            self._os.environ.pop("LEDGER_PATH", None)
        else:
            self._os.environ["LEDGER_PATH"] = self._saved
        if self._os.path.exists(self._led):
            self._os.remove(self._led)

    def _run(self, args):
        import contextlib
        import io
        err, out = io.StringIO(), io.StringIO()
        with contextlib.redirect_stderr(err), contextlib.redirect_stdout(out):
            rc = wd.run_report(args)
        return rc, err.getvalue(), out.getvalue()

    def _decision(self, out):
        # The decision record is the one stdout line that parses as a dict.
        import json
        for ln in out.splitlines():
            try:
                d = json.loads(ln)
            except ValueError:
                continue
            if isinstance(d, dict) and "to_page" in d:
                return d
        self.fail("no decision JSON on stdout")

    def test_fresh_cluster_would_page(self):
        path = self._write({"clusters": [cluster(slug="iss-fresh")]})
        rc, err, out = self._run(self._args(path))
        self.assertEqual(rc, 0)
        self.assertIn("would page", err)
        self.assertEqual(self._decision(out)["to_page"], ["iss-fresh"])

    def test_cooldown_suppresses_repage(self):
        import json
        path = self._write({"clusters": [cluster(slug="iss-hot")]})
        with open(self._led, "w") as f:                  # paged "just now"
            json.dump({"iss-hot": wd._epoch(None)}, f)
        rc, err, out = self._run(self._args(path))
        self.assertEqual(rc, 0)
        self.assertIn("nothing fresh to page", err)
        self.assertNotIn("would page", err)
        d = self._decision(out)
        self.assertEqual(d["in_cooldown"], ["iss-hot"])
        self.assertEqual(d["to_page"], [])

    def test_below_threshold_does_not_page(self):
        one_user = cluster(slug="iss-lonely",
                           users=[{"who": "solo@x.com", "conv_id": "1", "cites": []}])
        path = self._write({"clusters": [one_user]})
        rc, err, out = self._run(self._args(path))
        self.assertEqual(rc, 0)
        # Tie the test to the threshold DECISION, not just the terminal string.
        d = self._decision(out)
        self.assertEqual(d["below_threshold"], ["iss-lonely"])
        self.assertNotIn("iss-lonely", d["systemic"])
        self.assertEqual(d["to_page"], [])

    def test_window_label_comes_from_run_arg_not_the_file(self):
        # The "last Nh" label is derived from the run's --window-hours (the
        # deterministic edge), NOT from the agent's clusters.json — so a wrong /
        # adversarial file value can never make the header lie ("last [99]h").
        # --check dumps the rendered blocks to stderr.
        path = self._write({"window_hours": [99], "clusters": [cluster(slug="iss-w")]})
        rc, err, out = self._run(self._args(path, check=True))
        self.assertEqual(rc, 0)
        self.assertIn("last 24h", err)
        self.assertNotIn("[99]", err)


# ── render: Block Kit + escaping ──────────────────────────────────────────────
class Render(unittest.TestCase):
    """build_report_blocks returns (fallback_text, blocks). The blocks are the
    Aaron-facing report; these tests pin the structure, the single trusted ping,
    the injection-escaping, the compact-link allow-list, and the LOUD volume caps."""

    def _blocks(self, clusters, excluded=None, mentions=None, ws="ws_1", label="last 24h"):
        return wd.build_report_blocks(clusters, excluded or [], mentions or ["U7RP6HKUZ"], ws, label)

    def _cluster_section_text(self, blocks):
        # the first section AFTER the mention section (index 1) is the first cluster
        sections = [b for b in blocks if b["type"] == "section"]
        return sections[1]["text"]["text"]

    def test_returns_text_and_blocks_with_header_first(self):
        text, blocks = self._blocks([cluster()])
        self.assertIsInstance(text, str)
        self.assertTrue(text)
        self.assertEqual(blocks[0]["type"], "header")
        self.assertEqual(blocks[0]["text"]["type"], "plain_text")

    def test_block_sequence_and_excluded_is_trailing_context(self):
        text, blocks = self._blocks(
            [cluster()], excluded=[{"who": "e@x.com", "reason": "profile-creation request"}])
        self.assertEqual([b["type"] for b in blocks[:5]],
                         ["header", "section", "context", "divider", "section"])
        self.assertEqual(blocks[-1]["type"], "context")
        excl = blocks[-1]["elements"][0]["text"]
        self.assertIn("Judged non-systemic", excl)
        self.assertIn("profile-creation request", excl)

    def test_mention_only_in_a_section_never_header_or_context(self):
        # A mention in a plain_text header does NOT ping; the ping must live in an
        # mrkdwn section. Pin: header has no mention, block 1 section does, no
        # context block does.
        text, blocks = self._blocks(
            [cluster()], excluded=[{"who": "e@x.com", "reason": "x"}])
        self.assertNotIn("<@", blocks[0]["text"]["text"])
        self.assertEqual(blocks[1]["type"], "section")
        self.assertIn("<@U7RP6HKUZ>", blocks[1]["text"]["text"])
        for b in blocks:
            if b["type"] == "context":
                for el in b["elements"]:
                    self.assertNotIn("<@", el["text"])

    def test_symptom_title_and_link_render(self):
        text, blocks = self._blocks([cluster()])
        txt = all_text(blocks)
        self.assertIn("Credits misattribution", txt)
        self.assertIn("tracks they didn't make", txt)     # the symptom line
        self.assertIn("ws_1", txt)
        self.assertIn("/1|conversation>", txt)             # deeplink from conv_id

    def test_link_is_rebuilt_from_conv_id_not_agent_url(self):
        # An agent-supplied 'deeplink' URL must be ignored — the conversation link
        # is reconstructed from the numeric conv_id, never from agent text.
        c = cluster(users=[{"who": "a@x.com", "conv_id": "777",
                            "deeplink": "https://evil.example/x", "cites": []}])
        txt = all_text(self._blocks([c])[1])
        self.assertIn("/777|conversation>", txt)
        self.assertNotIn("evil.example", txt)

    def test_escapes_injection_in_agent_text(self):
        c = cluster(symptom="fix it <!channel>",
                    users=[{"who": "<@U999>", "conv_id": "1", "detail": "& <bad>", "cites": []},
                           {"who": "b@x.com", "conv_id": "2", "email": "b@x.com", "cites": []}])
        txt = all_text(self._blocks([c])[1])
        self.assertIn("&lt;!channel&gt;", txt)
        self.assertIn("&amp; &lt;bad&gt;", txt)
        self.assertIn("&lt;@U999&gt;", txt)
        # exactly ONE real ping across the whole message — the trusted Aaron mention
        self.assertEqual(len(re.findall(r"<@U", txt)), 1)

    def test_user_cap_is_fail_loud(self):
        users = [{"who": f"u{i}@x.com", "conv_id": str(i), "email": f"u{i}@x.com", "cites": []}
                 for i in range(9)]
        sect = self._cluster_section_text(self._blocks([cluster(users=users)])[1])
        self.assertIn("u0@x.com", sect)
        self.assertIn("u4@x.com", sect)                    # 5 shown (0..4)
        self.assertNotIn("u5@x.com", sect)
        self.assertIn("+4 more", sect)                     # the rest are LOUD, not silent

    def test_every_section_within_3000_chars(self):
        users = [{"who": f"u{i}@x.com", "conv_id": str(i), "email": f"u{i}@x.com",
                  "detail": "d" * 800, "cites": ["c" * 300]} for i in range(9)]
        text, blocks = self._blocks([cluster(users=users)])
        for b in blocks:
            if b["type"] == "section":
                self.assertLessEqual(len(b["text"]["text"]), 3000)

    def test_cluster_cap_keeps_message_under_50_blocks(self):
        many = [cluster(slug=f"s{i}", title=f"T{i}") for i in range(30)]
        text, blocks = self._blocks(many)
        self.assertLessEqual(len(blocks), 50)
        self.assertIn("more cluster(s) not shown", all_text(blocks))

    def test_url_cite_to_allowed_host_becomes_compact_link(self):
        c = cluster(users=[{"who": "a@x.com", "conv_id": "1", "email": "a@x.com",
                            "cites": ["https://credits.muso.ai/track/78d7dcd3-3b1c"]}])
        txt = all_text(self._blocks([c])[1])
        self.assertIn("<https://credits.muso.ai/track/78d7dcd3-3b1c|track 78d7dcd3>", txt)

    def test_non_url_cite_is_plain_escaped_text(self):
        c = cluster(users=[{"who": "a@x.com", "conv_id": "1", "email": "a@x.com",
                            "cites": ["track 78d7dcd3"]}])
        txt = all_text(self._blocks([c])[1])
        self.assertIn("track 78d7dcd3", txt)
        self.assertNotIn("<track", txt)                    # not wrapped as a link

    def test_hostile_cite_urls_are_not_live_links_or_pings(self):
        # A cite URL is LLM/customer-supplied — the one new injection surface when
        # placed in <url|label>. A `|`/`<`/`>`/space breaks the link; a well-formed
        # but non-allow-listed host must not be a disguised link either.
        hostile = ["https://x/a|<!channel>", "https://evil/<@U999>",
                   "https://has space.com/x", "https://evil.example/legit"]
        c = cluster(users=[{"who": "a@x.com", "conv_id": "1", "email": "a@x.com",
                            "cites": hostile}])
        txt = all_text(self._blocks([c])[1])
        self.assertEqual(len(re.findall(r"<@U", txt)), 1)  # only the trusted mention
        self.assertIn("&lt;@U999&gt;", txt)                # angle brackets escaped
        self.assertNotIn("evil.example/legit|", txt)       # not a disguised <url|label>

    def test_excluded_context_is_bounded_under_3000(self):
        # A single pathological excluded reason must NOT blow the context element
        # past Slack's text limit (which would make chat.postMessage reject the
        # whole report — a garbled footnote suppressing the entire page).
        excluded = [{"who": "z@x.com", "reason": "r" * 9000}]
        text, blocks = self._blocks([cluster()], excluded=excluded)
        ctx = [b for b in blocks if b["type"] == "context"][-1]
        self.assertLessEqual(len(ctx["elements"][0]["text"]), 3000)

    def test_fallback_text_is_nonempty_and_escaped(self):
        text, _ = self._blocks([cluster(title="<bad> & title")])
        self.assertTrue(text)
        self.assertIn("&lt;bad&gt; &amp; title", text)
        self.assertNotIn("<bad>", text)


class SlackEscape(unittest.TestCase):
    def test_ampersand_first(self):
        self.assertEqual(wd.slack_escape("a & b < c > d"), "a &amp; b &lt; c &gt; d")

    def test_neutralizes_channel_ping(self):
        self.assertEqual(wd.slack_escape("<!channel>"), "&lt;!channel&gt;")


class DataComplaintTag(unittest.TestCase):
    def test_tag_matches_plugin(self):
        # Must equal DATA_COMPLAINT_TAG in plugins/intercom/src/priority-signal.ts.
        self.assertEqual(wd.DATA_COMPLAINT_TAG, "ai:data-complaint")


class ResolveSlackToken(unittest.TestCase):
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
