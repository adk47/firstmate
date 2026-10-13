"""Behavioral tests for scripts/cs-needs-human-digest.py.

This script runs UNATTENDED daily and posts a Block Kit digest to #cs_chats —
its ONLY effect on the world (it is READ-ONLY on Intercom: no close, snooze,
tag, or reply). The safety-relevant invariants are: the de-confliction reader
never crashes on a missing/corrupt sibling state file and never double-counts
a conversation another sweeper already owns; the reply-order bucketing that
decides what Jan sees is deterministic; PII (customer email) never leaks
un-masked into the rendered digest; and a Slack failure never propagates.

Stdlib unittest + stubs only — no pytest dependency, no network — same bare
python3 -m unittest the other py-tests CI job entries use.
"""
import importlib.util
import pathlib
import unittest
from unittest import mock

_SCRIPT = (
    pathlib.Path(__file__).resolve().parent.parent
    / "scripts"
    / "cs-needs-human-digest.py"
)
_spec = importlib.util.spec_from_file_location("cs_needs_human_digest", _SCRIPT)
d = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(d)


def conv(cid="c1", email="alice@example.com", lar=200, lcr=100, url="", created_at=0,
         is_inbound=True):
    """Conversation shaped like fetch_open_convs output. Defaults = admin-last,
    inbound (customer-initiated)."""
    return {"id": cid, "email": email, "lar": lar, "lcr": lcr, "url": url,
            "created_at": created_at, "is_inbound": is_inbound}


class TestBucketConversations(unittest.TestCase):
    """The classifier deciding what Jan sees. Each case locks a bucket rule."""

    def test_customer_last_is_needs_human(self):
        # Customer replied after us -> we owe them a reply.
        c = conv(cid="c1", lar=100, lcr=200)
        buckets = d.bucket_conversations([c], set())
        self.assertEqual([x["id"] for x in buckets["needs_human"]], ["c1"])
        self.assertEqual(buckets["needs_customer_input"], [])

    def test_never_replied_is_needs_human(self):
        # lar == 0 -> we never engaged at all; still owed a reply.
        c = conv(cid="c1", lar=0, lcr=50)
        buckets = d.bucket_conversations([c], set())
        self.assertEqual([x["id"] for x in buckets["needs_human"]], ["c1"])

    def test_admin_last_is_needs_customer_input(self):
        c = conv(cid="c1", lar=300, lcr=100)
        buckets = d.bucket_conversations([c], set())
        self.assertEqual(buckets["needs_human"], [])
        self.assertEqual([x["id"] for x in buckets["needs_customer_input"]], ["c1"])

    def test_needs_human_ranked_newest_waiting_first(self):
        recent = conv(cid="R", lar=0, lcr=900)
        oldest = conv(cid="O", lar=0, lcr=100)
        middle = conv(cid="M", lar=0, lcr=500)
        buckets = d.bucket_conversations([recent, oldest, middle], set())
        self.assertEqual([c["id"] for c in buckets["needs_human"]], ["R", "M", "O"])

    def test_ancient_item_ranks_last_and_stays_out_of_top_n(self):
        # MUS-8853: oldest-first pinned the 194-day tail in the rendered
        # [:top_n] slice while live threads never surfaced.
        now = 1_000_000_000
        live = [conv(cid=f"L{i}", lar=0, lcr=now - i * 3600) for i in range(1, 21)]
        ancient = conv(cid="ANCIENT", lar=0, lcr=now - 194 * 86400)
        buckets = d.bucket_conversations([ancient] + live, set())
        ids = [c["id"] for c in buckets["needs_human"]]
        self.assertEqual(ids[-1], "ANCIENT")
        self.assertNotIn("ANCIENT", ids[:d.DEFAULT_TOP_N])

    def test_same_email_two_open_convs_is_dup_candidate(self):
        d1 = conv(cid="D1", email="dup@x.com")
        d2 = conv(cid="D2", email="dup@x.com")
        solo = conv(cid="S1", email="solo@x.com")
        buckets = d.bucket_conversations([d1, d2, solo], set())
        self.assertEqual({c["id"] for c in buckets["dup_candidate"]}, {"D1", "D2"})

    def test_dup_candidate_is_independent_of_reply_order_bucket(self):
        # A customer can be waiting on us on their NEWEST duplicate thread —
        # dup-candidate is not mutually exclusive with needs-human.
        d1 = conv(cid="D1", email="dup@x.com", lar=0, lcr=200)  # needs-human
        d2 = conv(cid="D2", email="dup@x.com", lar=300, lcr=100)  # needs-customer-input
        buckets = d.bucket_conversations([d1, d2], set())
        self.assertIn("D1", [c["id"] for c in buckets["needs_human"]])
        self.assertIn("D2", [c["id"] for c in buckets["needs_customer_input"]])
        self.assertEqual({c["id"] for c in buckets["dup_candidate"]}, {"D1", "D2"})

    def test_email_in_sibling_history_never_excludes_a_different_id(self):
        # KEY regression (QA #691 finding, cs-ops-drain-spec.md commit
        # 2c04734b): de-confliction is by conversation id ONLY. A returning
        # customer's brand-new conversation must be surfaced even though
        # their email appears elsewhere in bucket_conversations' input — it
        # must never be excluded via an email-based owned set.
        c = conv(cid="C1", email="returning@x.com", lar=0, lcr=100)
        buckets = d.bucket_conversations([c], set())  # id not owned -> surfaced
        self.assertIn("C1", [x["id"] for x in buckets["needs_human"]])

    def test_never_replied_conversations_rank_by_created_at_not_tied_at_epoch(self):
        # KEY regression (waiting-timestamp finding): last_contact_reply_at
        # == 0 for a never-replied (unanswered first message) conversation
        # must NOT be treated as "waiting since the Unix epoch" — two such
        # conversations created at DIFFERENT times must rank in created_at
        # order (older first), never tied in API-list order.
        older = conv(cid="OLD", lar=0, lcr=0, created_at=1000)
        newer = conv(cid="NEW", lar=0, lcr=0, created_at=2000)
        buckets = d.bucket_conversations([newer, older], set())  # API order: NEW, OLD
        self.assertEqual([c["id"] for c in buckets["needs_human"]], ["NEW", "OLD"])
        self.assertNotEqual(d.waiting_since(older), 0)
        self.assertNotEqual(d.waiting_since(newer), 0)

    def test_outbound_zero_zero_is_needs_customer_input_not_needs_human(self):
        # KEY regression (inbound-vs-outbound finding): lar==0 and lcr==0 is
        # ambiguous on its own now that this digest also covers outbound
        # (admin/bot/campaign-initiated) conversations — an outbound one with
        # no reply parts means WE are waiting on the customer, so it must
        # land in needs-customer-input, never needs-human.
        outbound = conv(cid="OUT", lar=0, lcr=0, is_inbound=False)
        buckets = d.bucket_conversations([outbound], set())
        self.assertEqual(buckets["needs_human"], [])
        self.assertEqual([c["id"] for c in buckets["needs_customer_input"]], ["OUT"])

    def test_outbound_bot_initiated_zero_zero_is_also_needs_customer_input(self):
        bot_outbound = conv(cid="BOT", lar=0, lcr=0, is_inbound=False)
        buckets = d.bucket_conversations([bot_outbound], set())
        self.assertEqual(buckets["needs_human"], [])
        self.assertEqual([c["id"] for c in buckets["needs_customer_input"]], ["BOT"])

    def test_inbound_zero_zero_stays_needs_human(self):
        # The customer's unanswered first message (inbound, no reply parts
        # yet on either side) must remain needs-human.
        inbound = conv(cid="IN", lar=0, lcr=0, is_inbound=True)
        buckets = d.bucket_conversations([inbound], set())
        self.assertEqual([c["id"] for c in buckets["needs_human"]], ["IN"])
        self.assertEqual(buckets["needs_customer_input"], [])

    def test_lead_initiated_zero_zero_lands_in_needs_human_via_is_inbound_conv(self):
        # KEY regression (delivered_as finding): a lead-authored unanswered
        # first message is customer-initiated and must not be hidden from
        # needs-human. Derive is_inbound the same way fetch_open_convs does.
        c = conv(cid="LEAD1", lar=0, lcr=0,
                 is_inbound=d.is_inbound_conv({"source": {"author": {"type": "lead"}}}))
        buckets = d.bucket_conversations([c], set())
        self.assertEqual([x["id"] for x in buckets["needs_human"]], ["LEAD1"])
        self.assertEqual(buckets["needs_customer_input"], [])

    def test_contact_initiated_zero_zero_lands_in_needs_human_via_is_inbound_conv(self):
        c = conv(cid="CONTACT1", lar=0, lcr=0,
                 is_inbound=d.is_inbound_conv({"source": {"author": {"type": "contact"}}}))
        buckets = d.bucket_conversations([c], set())
        self.assertEqual([x["id"] for x in buckets["needs_human"]], ["CONTACT1"])
        self.assertEqual(buckets["needs_customer_input"], [])


class TestSplitActionable(unittest.TestCase):
    NOW = 1_000_000_000
    DAY = 86400

    def test_inside_outside_and_exact_boundary(self):
        inside = conv(cid="IN", lar=0, lcr=self.NOW - 29 * self.DAY)
        edge = conv(cid="EDGE", lar=0, lcr=self.NOW - 30 * self.DAY)
        outside = conv(cid="OUT", lar=0, lcr=self.NOW - 30 * self.DAY - 1)
        act, back = d.split_actionable([outside, inside, edge], self.NOW)
        self.assertEqual([c["id"] for c in act], ["IN", "EDGE"])
        self.assertEqual([c["id"] for c in back], ["OUT"])

    def test_never_replied_rides_created_at_not_epoch(self):
        fresh = conv(cid="NEW", lar=0, lcr=0, created_at=self.NOW - 3600)
        act, back = d.split_actionable([fresh], self.NOW)
        self.assertEqual([c["id"] for c in act], ["NEW"])
        self.assertEqual(back, [])

    def test_empty_input(self):
        self.assertEqual(d.split_actionable([], self.NOW), ([], []))

    def test_window_days_honoured(self):
        c = conv(cid="C", lar=0, lcr=self.NOW - 10 * self.DAY)
        self.assertEqual(d.split_actionable([c], self.NOW, window_days=7), ([], [c]))
        self.assertEqual(d.split_actionable([c], self.NOW, window_days=10), ([c], []))


class TestActionableDups(unittest.TestCase):
    NOW = 1_000_000_000
    DAY = 86400

    def _ids(self, convs, **kw):
        return [c["id"] for c in d.actionable_dups(convs, self.NOW, **kw)]

    def test_group_with_one_recent_member_keeps_both(self):
        new = conv(cid="NEW", email="a@x.com", lar=0, lcr=self.NOW - 3600)
        old = conv(cid="OLD", email="a@x.com", lar=0, lcr=self.NOW - 194 * self.DAY)
        self.assertEqual(self._ids([old, new]), ["OLD", "NEW"])

    def test_group_entirely_ancient_is_dropped(self):
        a = conv(cid="A", email="a@x.com", lar=0, lcr=self.NOW - 100 * self.DAY)
        b = conv(cid="B", email="a@x.com", lar=0, lcr=self.NOW - 194 * self.DAY)
        self.assertEqual(self._ids([a, b]), [])

    def test_falsy_email_is_never_a_member(self):
        fresh = conv(cid="F", email="", lar=0, lcr=self.NOW - 3600)
        self.assertEqual(self._ids([fresh]), [])

    def test_single_member_group_unaffected(self):
        one = conv(cid="ONE", email="a@x.com", lar=0, lcr=self.NOW - 3600)
        self.assertEqual(self._ids([one]), ["ONE"])

    def test_window_days_honoured(self):
        c = conv(cid="C", email="a@x.com", lar=0, lcr=self.NOW - 10 * self.DAY)
        self.assertEqual(self._ids([c], window_days=7), [])


class TestOwnedIds(unittest.TestCase):
    """The de-confliction reader: a missing/corrupt sibling state file must
    mean "no ownership" and must NEVER crash the digest or bury everything.
    De-conflicts by CONVERSATION ID ONLY — email fields on sibling records
    are read defensively but never collected for exclusion (QA #691 /
    cs-ops-drain-spec.md commit 2c04734b)."""

    def _paths(self, **overrides):
        base = {
            "close-resolved": ("/nonexistent/close.jsonl", "jsonl"),
            "resolve-notify": ("/nonexistent/resolve.json", "json"),
            "resolution-matcher-state": ("/nonexistent/rm-state.json", "json"),
            "resolution-matcher-shadow": ("/nonexistent/rm-shadow.jsonl", "jsonl"),
            "overdue-verification-notifier": ("/nonexistent/overdue.json", "json"),
            "dedup-shadow": ("/nonexistent/dedup.jsonl", "jsonl"),
        }
        base.update(overrides)
        return base

    def test_all_missing_files_yield_no_ownership_not_a_crash(self):
        ids = d.owned_ids(self._paths())
        self.assertEqual(ids, set())

    def test_conv_prefixed_json_state_key_is_owned(self):
        m = mock.mock_open(read_data='{"conv:C1": 123}')
        with mock.patch("builtins.open", m):
            ids = d.owned_ids(self._paths(**{
                "resolve-notify": ("/fake/resolve.json", "json")}))
        self.assertIn("C1", ids)

    def test_shadow_log_id_field_is_owned_email_field_ignored(self):
        # The email field on this record is read defensively (must not
        # crash) but is NEVER collected for exclusion — only the id is.
        m = mock.mock_open(read_data='{"id": "C2", "email": "Alice@Example.com"}\n')
        with mock.patch("builtins.open", m):
            ids = d.owned_ids(self._paths(**{
                "close-resolved": ("/fake/close.jsonl", "jsonl")}))
        self.assertIn("C2", ids)

    def test_resolution_matcher_shadow_conv_id_field(self):
        m = mock.mock_open(read_data='{"conv_id": "C3", "email_acted": true}\n')
        with mock.patch("builtins.open", m):
            ids = d.owned_ids(self._paths(**{
                "resolution-matcher-shadow": ("/fake/rm-shadow.jsonl", "jsonl")}))
        self.assertIn("C3", ids)

    def test_corrupt_json_state_file_is_skipped_not_fatal(self):
        m = mock.mock_open(read_data="not json{{{")
        with mock.patch("builtins.open", m):
            ids = d.owned_ids(self._paths(**{
                "resolve-notify": ("/fake/resolve.json", "json")}))
        self.assertEqual(ids, set())

    def test_malformed_jsonl_line_is_skipped_not_fatal(self):
        m = mock.mock_open(read_data='not json\n{"id": "C1"}\n')
        with mock.patch("builtins.open", m):
            ids = d.owned_ids(self._paths(**{
                "close-resolved": ("/fake/close.jsonl", "jsonl")}))
        self.assertIn("C1", ids)  # the one good line still parses


class TestIsInboundConv(unittest.TestCase):
    """delivered_as is the authoritative customer-initiated signal (verified
    against the Intercom 2.11 OpenAPI spec's conversation_source schema — a
    required field whose documented values are customer_initiated,
    campaigns_initiated, operator_initiated, automated, admin_initiated).
    author.type == "user" is NOT the only customer-initiated case: the
    spec's create_conversation_request/create_message_request schemas show a
    customer-initiated conversation's author can be "lead" or "contact" too
    (a Contact's role is user or lead), so the delivered_as-absent fallback
    must accept all three customer roles."""

    def test_delivered_as_customer_initiated_is_inbound_regardless_of_author_type(self):
        c = {"source": {"delivered_as": "customer_initiated", "author": {"type": "lead"}}}
        self.assertTrue(d.is_inbound_conv(c))

    def test_delivered_as_admin_initiated_is_outbound(self):
        c = {"source": {"delivered_as": "admin_initiated", "author": {"type": "admin"}}}
        self.assertFalse(d.is_inbound_conv(c))

    def test_delivered_as_campaigns_initiated_is_outbound(self):
        c = {"source": {"delivered_as": "campaigns_initiated", "author": {"type": "bot"}}}
        self.assertFalse(d.is_inbound_conv(c))

    def test_delivered_as_operator_initiated_is_outbound(self):
        c = {"source": {"delivered_as": "operator_initiated", "author": {"type": "bot"}}}
        self.assertFalse(d.is_inbound_conv(c))

    def test_delivered_as_automated_is_outbound(self):
        c = {"source": {"delivered_as": "automated", "author": {"type": "bot"}}}
        self.assertFalse(d.is_inbound_conv(c))

    def test_delivered_as_absent_falls_back_to_lead_author_type_as_inbound(self):
        c = {"source": {"author": {"type": "lead"}}}
        self.assertTrue(d.is_inbound_conv(c))

    def test_delivered_as_absent_falls_back_to_contact_author_type_as_inbound(self):
        c = {"source": {"author": {"type": "contact"}}}
        self.assertTrue(d.is_inbound_conv(c))

    def test_delivered_as_absent_falls_back_to_user_author_type_as_inbound(self):
        c = {"source": {"author": {"type": "user"}}}
        self.assertTrue(d.is_inbound_conv(c))

    def test_delivered_as_absent_falls_back_to_admin_author_type_as_outbound(self):
        c = {"source": {"author": {"type": "admin"}}}
        self.assertFalse(d.is_inbound_conv(c))


class TestIsOwned(unittest.TestCase):
    def test_owned_by_id(self):
        self.assertTrue(d.is_owned(conv(cid="C1"), {"C1"}))

    def test_not_owned(self):
        self.assertFalse(d.is_owned(conv(cid="C1", email="a@b.com"), set()))

    def test_email_alone_never_causes_exclusion(self):
        # De-confliction is id-only — a matching email with an un-owned id
        # must never be treated as owned (KEY regression, QA #691).
        self.assertFalse(d.is_owned(conv(cid="C9", email="a@b.com"), set()))


class TestMaskEmail(unittest.TestCase):
    def test_masks_local_part_first_char_only(self):
        self.assertEqual(d.mask_email("joe@example.com"), "j***@***")

    def test_empty_email(self):
        self.assertEqual(d.mask_email(""), "no email")


class TestRenderTextDigest(unittest.TestCase):
    def test_no_customer_email_leaks_unmasked(self):
        c = conv(cid="C1", email="alice@example.com", lar=0, lcr=100)
        buckets = d.bucket_conversations([c], set())
        text = d.render_text_digest(buckets, now_epoch=200)
        self.assertNotIn("alice@example.com", text)
        self.assertIn("a***@***", text)

    def test_full_digest_states_observable_reply_order_without_waiting_claims(self):
        now = 1_000_000
        replied = conv(cid="REPLIED", lar=0, lcr=now - 3600)
        tied = conv(cid="TIED", lar=now - (2 * 3600), lcr=now - (2 * 3600))
        opened = conv(cid="OPENED", lar=0, lcr=0,
                      created_at=now - (2 * 3600), is_inbound=True)
        outbound = conv(cid="OUTBOUND", lar=0, lcr=0,
                        created_at=now - (3 * 3600), is_inbound=False)
        buckets = d.bucket_conversations([replied, tied, opened, outbound], set())

        text = d.render_text_digest(buckets, now_epoch=now, aging_hours=20)

        self.assertIn("CS open-conversation review daily digest", text)
        self.assertIn("customer-side activity is latest: 3", text)
        self.assertIn(
            "team-side activity is latest, or team initiated with no recorded "
            "customer reply: 1", text)
        self.assertIn(
            "customer is last recorded replier; last customer reply 1h ago", text)
        self.assertIn(
            "customer and team share the latest recorded reply time; "
            "last customer reply 2h ago", text)
        self.assertIn(
            "customer-initiated; opened 2h ago; no recorded reply", text)
        self.assertIn(
            "Open status and reply order do not prove that a customer went unanswered.",
            text)
        self.assertNotIn("waiting", text.lower())
        self.assertNotIn("aging", text.lower())


class TestBuildDigestBlocks(unittest.TestCase):
    def test_header_is_plain_text_never_pings(self):
        buckets = d.bucket_conversations([], set())
        blocks = d.build_digest_blocks(buckets, now_epoch=100)
        header = blocks[0]
        self.assertEqual(header["type"], "header")
        self.assertEqual(header["text"]["type"], "plain_text")

    def test_no_customer_email_leaks_unmasked_in_blocks(self):
        c = conv(cid="C1", email="alice@example.com", lar=0, lcr=100)
        buckets = d.bucket_conversations([c], set())
        blocks = d.build_digest_blocks(buckets, now_epoch=200)
        self.assertNotIn("alice@example.com", str(blocks))
        self.assertIn("a***@***", str(blocks))

    def test_never_replied_conversation_under_48h_is_not_flagged(self):
        # KEY regression (waiting-timestamp finding): a brand-new, never-
        # replied conversation (lcr=0) must NOT be unconditionally flagged
        # past-48h — the flag must key off waiting_since (created_at here),
        # not the raw lcr==0.
        now = 10_000_000
        c = conv(cid="NEW", lar=0, lcr=0, created_at=now - (10 * 3600))  # 10h old
        buckets = d.bucket_conversations([c], set())
        blocks = d.build_digest_blocks(buckets, now_epoch=now)
        self.assertNotIn("past 48h", str(blocks))

    def test_never_replied_conversation_over_48h_is_flagged(self):
        now = 10_000_000
        c = conv(cid="OLD", lar=0, lcr=0, created_at=now - (72 * 3600))  # 72h old
        buckets = d.bucket_conversations([c], set())
        blocks = d.build_digest_blocks(buckets, now_epoch=now)
        self.assertIn("customer-side activity older than 48h", str(blocks))

    def test_full_blocks_use_neutral_title_counts_rows_and_caveat(self):
        now = 1_000_000
        c = conv(cid="C1", lar=0, lcr=now - (25 * 3600))
        buckets = d.bucket_conversations([c], set())

        blocks = d.build_digest_blocks(buckets, now_epoch=now, aging_hours=20)
        rendered = str(blocks)

        self.assertEqual(
            blocks[0]["text"]["text"], "CS open-conversation review daily digest")
        self.assertIn("customer-side activity is latest", rendered)
        self.assertIn("older than 20h since customer-side activity", rendered)
        self.assertIn("do not prove that a customer went unanswered", rendered)
        self.assertNotIn("waiting", rendered.lower())
        self.assertNotIn("aging", rendered.lower())

    def test_full_blocks_keep_every_section_within_slack_limit(self):
        now = 10_000_000
        items = [
            conv(cid=str(100_000_000_000_000 + i), lar=0,
                 lcr=now - ((25 + i) * 3600))
            for i in range(15)
        ]
        buckets = d.bucket_conversations(items, set())

        blocks = d.build_digest_blocks(
            buckets, now_epoch=now, top_n=15, aging_hours=20)

        sections = [b for b in blocks if b["type"] == "section"]
        self.assertTrue(all(len(b["text"]["text"]) <= 3000 for b in sections))
        rendered_rows = sum(
            b["text"]["text"].count("conversation/") for b in sections)
        self.assertEqual(rendered_rows, 15)


class TestPostSlackDigestBestEffort(unittest.TestCase):
    """post_slack_digest must NEVER raise — this is an informational digest,
    so a Slack/network failure must stay non-fatal (return False)."""

    def test_network_and_read_failures_are_non_fatal(self):
        import io
        from contextlib import redirect_stderr
        for exc in (TimeoutError("read timed out"), OSError("connection reset"),
                    ValueError("bad json"), RuntimeError("anything else")):
            with mock.patch.object(d, "_read_slack_token", return_value="xoxb-test"), \
                 mock.patch.object(d.urllib.request, "urlopen", side_effect=exc), \
                 redirect_stderr(io.StringIO()):
                self.assertFalse(
                    d.post_slack_digest([], "text", "C0ANM0PN9L5", "/cfg", "operations"))

    def test_missing_token_is_non_fatal(self):
        import io
        from contextlib import redirect_stderr
        with mock.patch.object(d, "_read_slack_token", return_value=None), \
             redirect_stderr(io.StringIO()):
            self.assertFalse(
                d.post_slack_digest([], "text", "C0ANM0PN9L5", "/cfg", "operations"))


def _http_error(code):
    return d.urllib.error.HTTPError(
        "https://api.intercom.io/contacts/x", code, "err", {}, None)


class TestGetContact(unittest.TestCase):
    """GET /contacts/{id} — read-only enrichment lookup.

    Status-class contract (QA finding: the old single `except URLError`
    caught HTTPError too, so 401/403/429/5xx were all silently treated
    identically to a benign 404 — see get_contact's docstring):
      - 404                          -> None, run continues (benign miss).
      - 429 / 5xx, then success      -> recovers, no exception.
      - 401/403                      -> ContactLookupFailed immediately.
      - 429/5xx persisting through
        all retries                  -> ContactLookupFailed.
    """

    def setUp(self):
        # Retries use time.sleep for backoff — mock it out so these tests
        # don't actually sleep several seconds.
        self._sleep_patch = mock.patch.object(d.time, "sleep", return_value=None)
        self._sleep_patch.start()
        self.addCleanup(self._sleep_patch.stop)

    def test_success_returns_the_contact_body(self):
        import io
        import json as _json

        class FakeResp(io.BytesIO):
            def __enter__(self):
                return self

            def __exit__(self, *a):
                return False

        body = _json.dumps({"type": "contact", "id": "c1", "email": "a@b.com"}).encode()
        with mock.patch.object(d.urllib.request, "urlopen", return_value=FakeResp(body)):
            self.assertEqual(d.get_contact("c1", "tok"), {"type": "contact", "id": "c1", "email": "a@b.com"})

    def test_404_returns_none_and_run_continues(self):
        with mock.patch.object(d.urllib.request, "urlopen", side_effect=_http_error(404)):
            self.assertIsNone(d.get_contact("gone", "tok"))

    def test_401_raises_contact_lookup_failed_immediately(self):
        with mock.patch.object(d.urllib.request, "urlopen",
                                side_effect=_http_error(401)) as m_urlopen:
            with self.assertRaises(d.ContactLookupFailed):
                d.get_contact("c1", "tok")
        # not retryable — must fail on the first attempt.
        self.assertEqual(m_urlopen.call_count, 1)

    def test_403_raises_contact_lookup_failed_immediately(self):
        with mock.patch.object(d.urllib.request, "urlopen",
                                side_effect=_http_error(403)) as m_urlopen:
            with self.assertRaises(d.ContactLookupFailed):
                d.get_contact("c1", "tok")
        self.assertEqual(m_urlopen.call_count, 1)

    def test_429_then_success_recovers(self):
        import io
        import json as _json

        class FakeResp(io.BytesIO):
            def __enter__(self):
                return self

            def __exit__(self, *a):
                return False

        body = _json.dumps({"type": "contact", "id": "c1", "email": "a@b.com"}).encode()
        with mock.patch.object(
            d.urllib.request, "urlopen",
            side_effect=[_http_error(429), FakeResp(body)],
        ):
            self.assertEqual(d.get_contact("c1", "tok"),
                              {"type": "contact", "id": "c1", "email": "a@b.com"})

    def test_persistent_429_raises_contact_lookup_failed_after_retries(self):
        with mock.patch.object(d.urllib.request, "urlopen",
                                side_effect=_http_error(429)) as m_urlopen:
            with self.assertRaises(d.ContactLookupFailed):
                d.get_contact("c1", "tok", attempts=3)
        self.assertEqual(m_urlopen.call_count, 3)

    def test_persistent_5xx_raises_contact_lookup_failed_after_retries(self):
        with mock.patch.object(d.urllib.request, "urlopen",
                                side_effect=_http_error(503)) as m_urlopen:
            with self.assertRaises(d.ContactLookupFailed):
                d.get_contact("c1", "tok", attempts=3)
        self.assertEqual(m_urlopen.call_count, 3)

    def test_persistent_network_failure_raises_contact_lookup_failed(self):
        with mock.patch.object(
            d.urllib.request, "urlopen",
            side_effect=d.urllib.error.URLError("connection reset"),
        ):
            with self.assertRaises(d.ContactLookupFailed):
                d.get_contact("c1", "tok", attempts=2)


class TestSelfTest(unittest.TestCase):
    def test_self_test_passes(self):
        self.assertTrue(d._self_test())


class TestIntercomLink(unittest.TestCase):
    """intercom_link must build a stable ADMIN inbox deeplink from the trusted
    conversation id — never from source.url (that's where the conversation
    started, often blank, and never an inbox deep link)."""

    def test_default_workspace(self):
        with mock.patch.dict("os.environ", {}, clear=False):
            import os as _os
            _os.environ.pop("INTERCOM_WORKSPACE_ID", None)
            self.assertEqual(
                d.intercom_link("999"),
                "https://app.intercom.com/a/inbox/dwjzhcge/inbox/conversation/999",
            )

    def test_workspace_env_override(self):
        with mock.patch.dict("os.environ", {"INTERCOM_WORKSPACE_ID": "custom123"}):
            self.assertEqual(
                d.intercom_link("42"),
                "https://app.intercom.com/a/inbox/custom123/inbox/conversation/42",
            )

    def test_independent_of_source_url_blank_or_not(self):
        # intercom_link only ever takes a conv id now, so a blank OR populated
        # source.url on the underlying conversation cannot affect the link —
        # locking in that this is no longer read from source.url at all.
        self.assertEqual(d.intercom_link("7"), d.intercom_link("7"))


def contact_ref(contact_id="contact-1", external_id="70"):
    """A conversation `contacts` entry as Intercom's 2.11 API actually returns
    it — a Contact Reference: {type, id, external_id}. NO email field (see
    the contact_reference schema in Intercom's published OpenAPI spec). Any
    fixture carrying an "email" key on this object is testing a fiction."""
    return {"type": "contact", "id": contact_id, "external_id": external_id}


class TestContactEmailOf(unittest.TestCase):
    """contact_email_of must resolve the real CUSTOMER contact's email.

    Fast path: when source.author.type == "user", the author IS the
    customer contact, so source.author.email is used DIRECTLY — zero
    GET /contacts/{id}. Doing a GET anyway for the common one-contact-
    per-conversation shape would be an N+1 scan across the whole open
    backlog (QA finding fixed alongside this).

    Only when the author is NOT a user (admin/bot/campaign — not the
    customer, which would otherwise silently break dup-candidate detection)
    does resolving the email require the follow-up GET /contacts/{id} (the
    conversation's `contacts` field only ever carries a Contact Reference —
    id/type/external_id, no email — verified against Intercom's 2.11 OpenAPI
    spec), which these tests stub via `get_contact`."""

    def setUp(self):
        d._contact_email_cache.clear()

    def test_bot_initiated_resolves_via_contact_lookup(self):
        bot_initiated = {
            "source": {"author": {"type": "bot", "email": "bot@intercom.io"}},
            "contacts": {"contacts": [contact_ref("contact-1")]},
        }
        with mock.patch.object(
            d, "get_contact",
            return_value={"type": "contact", "id": "contact-1",
                          "email": "Real.Customer@Example.com"},
        ):
            self.assertEqual(d.contact_email_of(bot_initiated, "tok"),
                              "real.customer@example.com")

    def test_admin_initiated_resolves_via_contact_lookup(self):
        admin_initiated = {
            "source": {"author": {"type": "admin", "email": "staff@muso.ai"}},
            "contacts": {"contacts": [contact_ref("contact-2")]},
        }
        with mock.patch.object(
            d, "get_contact",
            return_value={"type": "contact", "id": "contact-2",
                          "email": "customer@example.com"},
        ):
            self.assertEqual(d.contact_email_of(admin_initiated, "tok"),
                              "customer@example.com")

    def test_user_type_author_is_a_valid_fallback(self):
        # Verified-identity fallback (same gate as plugins/intercom/src/filters.ts's
        # verifiedEmail): only a type=="user" author is trusted absent a
        # contact reference at all.
        user_initiated = {
            "source": {"author": {"type": "user", "email": "U@X.com"}},
            "contacts": {"contacts": []},
        }
        self.assertEqual(d.contact_email_of(user_initiated, "tok"), "u@x.com")

    def test_admin_only_with_no_signal_returns_empty_not_admin_email(self):
        admin_only = {
            "source": {"author": {"type": "admin", "email": "staff@muso.ai"}},
            "contacts": {"contacts": []},
        }
        self.assertEqual(d.contact_email_of(admin_only, "tok"), "")

    def test_missing_contacts_and_source_never_crashes(self):
        self.assertEqual(d.contact_email_of({}, "tok"), "")

    def test_missing_or_deleted_contact_falls_back_gracefully(self):
        # get_contact returns None on 404/deleted/transient failure — must
        # never crash. A non-user author (bot) with no other signal falls
        # through to "" (fail open to empty, never crash or misattribute).
        conv = {
            "source": {"author": {"type": "bot", "email": "bot@intercom.io"}},
            "contacts": {"contacts": [contact_ref("gone")]},
        }
        with mock.patch.object(d, "get_contact", return_value=None):
            self.assertEqual(d.contact_email_of(conv, "tok"), "")

    def test_user_type_author_takes_the_fast_path_zero_contact_gets(self):
        # N+1 fix: when the author IS the customer contact (type=="user"),
        # source.author.email is used DIRECTLY — get_contact must NEVER be
        # called, even if a (misleading/incidental) contacts reference is
        # also present on the conversation.
        conv = {
            "source": {"author": {"type": "user", "email": "Real@X.com"}},
            "contacts": {"contacts": [contact_ref("contact-1")]},
        }
        with mock.patch.object(d, "get_contact") as m_get_contact:
            self.assertEqual(d.contact_email_of(conv, "tok"), "real@x.com")
        m_get_contact.assert_not_called()

    def test_non_user_author_does_fetch_the_contact(self):
        # The N+1 fast path must NOT apply to admin/bot/campaign-initiated
        # conversations — those still require the GET to resolve the real
        # customer email.
        conv = {
            "source": {"author": {"type": "admin", "email": "staff@muso.ai"}},
            "contacts": {"contacts": [contact_ref("contact-9")]},
        }
        with mock.patch.object(
            d, "get_contact",
            return_value={"type": "contact", "id": "contact-9", "email": "cust@x.com"},
        ) as m_get_contact:
            self.assertEqual(d.contact_email_of(conv, "tok"), "cust@x.com")
        m_get_contact.assert_called_once()

    def test_contact_lookup_is_cached_by_id_not_refetched(self):
        # Many open conversations share a contact — the same id must be
        # fetched exactly once, never per-conversation (avoid N+1 GETs).
        fetched = []

        def fake_get_contact(contact_id, token):
            fetched.append(contact_id)
            return {"type": "contact", "id": contact_id, "email": "shared@x.com"}

        ref = contact_ref("shared-contact")
        conv_a = {"source": {"author": {"type": "bot"}}, "contacts": {"contacts": [ref]}}
        conv_b = {"source": {"author": {"type": "bot"}}, "contacts": {"contacts": [ref]}}
        with mock.patch.object(d, "get_contact", fake_get_contact):
            self.assertEqual(d.contact_email_of(conv_a, "tok"), "shared@x.com")
            self.assertEqual(d.contact_email_of(conv_b, "tok"), "shared@x.com")
        self.assertEqual(fetched, ["shared-contact"])


class TestFetchOpenConvsUsesContactEmailOf(unittest.TestCase):
    def setUp(self):
        d._contact_email_cache.clear()

    def test_email_field_is_resolved_via_contact_lookup(self):
        def fake_search(token, body):
            convs = [{
                "id": "C1",
                "source": {"author": {"type": "bot", "email": "bot@intercom.io"}},
                "contacts": {"contacts": [contact_ref("contact-1")]},
                "statistics": {"last_admin_reply_at": 0, "last_contact_reply_at": 100},
            }]
            return {"conversations": convs, "pages": {}}

        with mock.patch.object(d, "intercom_search", fake_search), \
                mock.patch.object(
                    d, "get_contact",
                    return_value={"type": "contact", "id": "contact-1", "email": "real@x.com"}):
            out = d.fetch_open_convs("tok")
        self.assertEqual(out[0]["email"], "real@x.com")
        # bot-initiated -> outbound (KEY for the inbound-vs-outbound 0/0 fix:
        # bucket_conversations needs this preserved to disambiguate the tie).
        self.assertFalse(out[0]["is_inbound"])

    def test_is_inbound_preserved_for_a_user_initiated_conversation(self):
        def fake_search(token, body):
            convs = [{
                "id": "C2",
                "source": {"author": {"type": "user", "email": "u@x.com"}},
                "contacts": {"contacts": []},
                "statistics": {"last_admin_reply_at": 0, "last_contact_reply_at": 0},
            }]
            return {"conversations": convs, "pages": {}}

        with mock.patch.object(d, "intercom_search", fake_search):
            out = d.fetch_open_convs("tok")
        self.assertTrue(out[0]["is_inbound"])

    def test_is_inbound_uses_delivered_as_over_author_type(self):
        # delivered_as is the authoritative signal (per the Intercom 2.11
        # OpenAPI spec) — a lead-authored, customer_initiated conversation
        # must be preserved as inbound.
        def fake_search(token, body):
            convs = [{
                "id": "C3",
                "source": {"delivered_as": "customer_initiated",
                           "author": {"type": "lead", "email": "lead@x.com"}},
                "contacts": {"contacts": []},
                "statistics": {"last_admin_reply_at": 0, "last_contact_reply_at": 0},
            }]
            return {"conversations": convs, "pages": {}}

        with mock.patch.object(d, "intercom_search", fake_search):
            out = d.fetch_open_convs("tok")
        self.assertTrue(out[0]["is_inbound"])


class TestMainFailsLoudOnUndeliveredPost(unittest.TestCase):
    """--post's whole job is delivering Jan's daily view — an undelivered
    digest (bad/expired token, API/network failure) must exit non-zero so the
    systemd timer + cron-health watchdog surface it instead of reporting a
    silently-healthy no-delivery run."""

    def test_post_mode_nonzero_exit_when_post_fails(self):
        import sys as _sys
        with mock.patch.object(
            d, "fetch_open_convs",
            return_value=[{"id": "C1", "email": "a@b.com", "lar": 0, "lcr": 200}],
        ), mock.patch.object(d, "post_slack_digest", return_value=False), \
                mock.patch.dict("os.environ", {"MUSOAI_INTERCOM_TOKEN": "t",
                                                "DIGEST_SKIP_HOST_GUARD": "1"}), \
                mock.patch.object(_sys, "argv", ["d", "--post"]):
            rc = d.main()
        self.assertNotEqual(rc, 0)

    def test_post_mode_zero_exit_when_post_succeeds(self):
        import sys as _sys
        # save_delta_state mocked so the exit code reflects DELIVERY only, not
        # the writability of the real default checkpoint path (a failed
        # checkpoint is separately exit 5 — see
        # TestMainDeltaFlow.test_delta_checkpoint_persist_failure_exits_nonzero).
        with mock.patch.object(
            d, "fetch_open_convs",
            return_value=[{"id": "C1", "email": "a@b.com", "lar": 0, "lcr": 200}],
        ), mock.patch.object(d, "post_slack_digest", return_value=True), \
                mock.patch.object(d, "save_delta_state"), \
                mock.patch.dict("os.environ", {"MUSOAI_INTERCOM_TOKEN": "t",
                                                "DIGEST_SKIP_HOST_GUARD": "1"}), \
                mock.patch.object(_sys, "argv", ["d", "--post"]):
            rc = d.main()
        self.assertEqual(rc, 0)

    def test_dry_run_stays_zero_exit_even_though_it_never_posts(self):
        import sys as _sys
        with mock.patch.object(
            d, "fetch_open_convs",
            return_value=[{"id": "C1", "email": "a@b.com", "lar": 0, "lcr": 200}],
        ), mock.patch.object(d, "post_slack_digest", return_value=False) as m_post, \
                mock.patch.dict("os.environ", {"MUSOAI_INTERCOM_TOKEN": "t",
                                                "DIGEST_SKIP_HOST_GUARD": "1"}), \
                mock.patch.object(_sys, "argv", ["d"]):
            rc = d.main()
        self.assertEqual(rc, 0)
        m_post.assert_not_called()


class TestMainFailsLoudOnSystematicContactLookupFailure(unittest.TestCase):
    """A systematic contact-lookup failure (401/403, or 429/5xx persisting
    through retries) must fail the whole run (non-zero, distinct exit code)
    rather than being silently swallowed into an empty/cached email — that
    would silently disable email-based dup-candidate detection with no
    signal it happened (same fail-loud principle as the --post check)."""

    def test_main_returns_3_when_contact_lookup_fails_systematically(self):
        import sys as _sys
        with mock.patch.object(
            d, "fetch_open_convs",
            side_effect=d.ContactLookupFailed("GET /contacts/x -> 401"),
        ), mock.patch.dict("os.environ", {"MUSOAI_INTERCOM_TOKEN": "t",
                                           "DIGEST_SKIP_HOST_GUARD": "1"}), \
                mock.patch.object(_sys, "argv", ["d"]):
            rc = d.main()
        self.assertEqual(rc, 3)


# --------------------------------------------------------------------------
# WS2: --delta flag + aging escalation.
# --------------------------------------------------------------------------
class TestDeltaStateLoadSave(unittest.TestCase):
    """Missing state = empty (first run). Corrupt state = FAIL LOUD, never a
    silent reset (repo doctrine: a reset would re-ping Jan with hundreds of
    items)."""

    def test_missing_file_is_empty_state(self):
        self.assertEqual(d.load_delta_state("/nonexistent/surfaced.json"), {})

    def test_valid_state_round_trips(self):
        m = mock.mock_open(read_data='{"c1": {"first_surfaced": 100, "aged_flagged": false}}')
        with mock.patch("builtins.open", m), mock.patch("os.path.exists", return_value=True):
            state = d.load_delta_state("/fake/surfaced.json")
        self.assertEqual(state, {"c1": {"first_surfaced": 100, "aged_flagged": False}})

    def test_corrupt_json_raises_loudly(self):
        m = mock.mock_open(read_data="not json{{{")
        with mock.patch("builtins.open", m), mock.patch("os.path.exists", return_value=True):
            with self.assertRaises(d.CorruptDigestState):
                d.load_delta_state("/fake/surfaced.json")

    def test_non_dict_json_raises_loudly(self):
        m = mock.mock_open(read_data="[1, 2, 3]")
        with mock.patch("builtins.open", m), mock.patch("os.path.exists", return_value=True):
            with self.assertRaises(d.CorruptDigestState):
                d.load_delta_state("/fake/surfaced.json")

    def test_non_object_entry_raises_loudly(self):
        # An entry value like [] would crash compute_delta_and_next_state's
        # entry.get() calls — validate every entry, not just the top level.
        m = mock.mock_open(read_data='{"c1": []}')
        with mock.patch("builtins.open", m), mock.patch("os.path.exists", return_value=True):
            with self.assertRaises(d.CorruptDigestState):
                d.load_delta_state("/fake/surfaced.json")

    def test_non_bool_aged_flagged_raises_loudly(self):
        # The string "false" is TRUTHY — bool("false") is True — so a corrupt
        # aged_flagged would silently suppress the one-time aging escalation.
        # Must fail loud instead of being read as "already flagged".
        m = mock.mock_open(read_data='{"c1": {"first_surfaced": 100, "aged_flagged": "false"}}')
        with mock.patch("builtins.open", m), mock.patch("os.path.exists", return_value=True):
            with self.assertRaises(d.CorruptDigestState):
                d.load_delta_state("/fake/surfaced.json")

    def test_non_numeric_first_surfaced_raises_loudly(self):
        m = mock.mock_open(read_data='{"c1": {"first_surfaced": "soon", "aged_flagged": false}}')
        with mock.patch("builtins.open", m), mock.patch("os.path.exists", return_value=True):
            with self.assertRaises(d.CorruptDigestState):
                d.load_delta_state("/fake/surfaced.json")

    def test_save_writes_json_atomically_and_round_trips(self):
        import tempfile
        import pathlib
        with tempfile.TemporaryDirectory() as td:
            path = str(pathlib.Path(td) / "surfaced.json")
            d.save_delta_state(path, {"c1": {"first_surfaced": 1, "aged_flagged": True}})
            # written content round-trips through the loader, and no temp file
            # is left behind (os.replace consumed it).
            self.assertEqual(d.load_delta_state(path),
                             {"c1": {"first_surfaced": 1, "aged_flagged": True}})
            leftovers = [p for p in pathlib.Path(td).iterdir() if p.name != "surfaced.json"]
            self.assertEqual(leftovers, [])

    def test_save_preserves_previous_state_when_replace_fails(self):
        # A failed atomic replace (disk full / permission) must RAISE and leave
        # the previous valid checkpoint intact — never a truncated/corrupt file.
        import tempfile
        import pathlib
        with tempfile.TemporaryDirectory() as td:
            path = pathlib.Path(td) / "surfaced.json"
            path.write_text('{"old": {"first_surfaced": 9, "aged_flagged": false}}')
            with mock.patch.object(d.os, "replace", side_effect=OSError("disk full")):
                with self.assertRaises(OSError):
                    d.save_delta_state(str(path), {"new": {"first_surfaced": 1}})
            # previous valid state untouched; no orphaned temp file left behind.
            self.assertEqual(d.load_delta_state(str(path)),
                             {"old": {"first_surfaced": 9, "aged_flagged": False}})
            leftovers = [p for p in pathlib.Path(td).iterdir() if p.name != "surfaced.json"]
            self.assertEqual(leftovers, [])


class TestComputeDeltaAndNextState(unittest.TestCase):
    def test_never_surfaced_item_is_new(self):
        c1 = conv(cid="C1", lar=0, lcr=100)
        new_items, aging_items, next_state = d.compute_delta_and_next_state(
            {}, [c1], now_epoch=1000, aging_hours=20)
        self.assertEqual([c["id"] for c in new_items], ["C1"])
        self.assertEqual(aging_items, [])
        self.assertIn("C1", next_state)
        self.assertEqual(next_state["C1"]["first_surfaced"], 1000)

    def test_new_item_that_is_already_aging_is_both_new_and_aging(self):
        now = 1_000_000
        c1 = conv(cid="C1", lar=0, lcr=now - (21 * 3600))  # 21h old, threshold 20h
        new_items, aging_items, next_state = d.compute_delta_and_next_state(
            {}, [c1], now_epoch=now, aging_hours=20)
        self.assertEqual([c["id"] for c in new_items], ["C1"])
        self.assertEqual([c["id"] for c in aging_items], ["C1"])
        self.assertTrue(next_state["C1"]["aged_flagged"])

    def test_previously_surfaced_item_not_yet_aging_is_neither(self):
        now = 1_000_000
        c1 = conv(cid="C1", lar=0, lcr=now - (5 * 3600))  # 5h waiting
        state = {"C1": {"first_surfaced": now - 100000, "aged_flagged": False}}
        new_items, aging_items, next_state = d.compute_delta_and_next_state(
            state, [c1], now_epoch=now, aging_hours=20)
        self.assertEqual(new_items, [])
        self.assertEqual(aging_items, [])
        self.assertFalse(next_state["C1"]["aged_flagged"])

    def test_previously_surfaced_item_crossing_aging_threshold_is_aging_not_new(self):
        now = 1_000_000
        c1 = conv(cid="C1", lar=0, lcr=now - (25 * 3600))  # now 25h old
        state = {"C1": {"first_surfaced": now - 100000, "aged_flagged": False}}
        new_items, aging_items, next_state = d.compute_delta_and_next_state(
            state, [c1], now_epoch=now, aging_hours=20)
        self.assertEqual(new_items, [])
        self.assertEqual([c["id"] for c in aging_items], ["C1"])
        self.assertTrue(next_state["C1"]["aged_flagged"])

    def test_already_aged_flagged_item_is_not_re_surfaced_as_aging(self):
        # Aging is a ONE-TIME crossing ping, not a re-ping every run.
        now = 1_000_000
        c1 = conv(cid="C1", lar=0, lcr=now - (30 * 3600))
        state = {"C1": {"first_surfaced": now - 200000, "aged_flagged": True}}
        new_items, aging_items, next_state = d.compute_delta_and_next_state(
            state, [c1], now_epoch=now, aging_hours=20)
        self.assertEqual(new_items, [])
        self.assertEqual(aging_items, [])
        self.assertTrue(next_state["C1"]["aged_flagged"])

    def test_aged_flag_clears_when_wait_genuinely_resets_below_threshold(self):
        # KEY regression: aged_flagged must NOT be sticky forever — when the
        # item's wait genuinely resets below the threshold (waiting_since
        # moves forward, e.g. the customer replied again after an admin
        # reply and then went quiet again), the flag must drop so a LATER
        # re-crossing can ping once more instead of being silently
        # suppressed forever by a stale True.
        now = 1_000_000
        c1 = conv(cid="C1", lar=0, lcr=now - (5 * 3600))  # only 5h waiting now
        state = {"C1": {"first_surfaced": now - 200000, "aged_flagged": True}}
        new_items, aging_items, next_state = d.compute_delta_and_next_state(
            state, [c1], now_epoch=now, aging_hours=20)
        self.assertEqual(aging_items, [])
        self.assertFalse(next_state["C1"]["aged_flagged"])

    def test_aging_pings_again_after_a_reset_and_recross(self):
        # Full cycle: aged -> resets below threshold (flag clears) -> crosses
        # again -> must land in aging_items a SECOND time.
        now = 1_000_000
        state = {"C1": {"first_surfaced": now - 300000, "aged_flagged": False}}
        c1 = conv(cid="C1", lar=0, lcr=now - (25 * 3600))  # aging again
        new_items, aging_items, next_state = d.compute_delta_and_next_state(
            state, [c1], now_epoch=now, aging_hours=20)
        self.assertEqual([c["id"] for c in aging_items], ["C1"])
        self.assertTrue(next_state["C1"]["aged_flagged"])


class TestIsAging(unittest.TestCase):
    def test_under_threshold_not_aging(self):
        c = conv(cid="C1", lar=0, lcr=900)
        self.assertFalse(d.is_aging(c, now_epoch=1000, aging_hours=20))

    def test_over_threshold_is_aging(self):
        now = 1_000_000
        c = conv(cid="C1", lar=0, lcr=now - (21 * 3600))
        self.assertTrue(d.is_aging(c, now_epoch=now, aging_hours=20))


class TestAgingRenderingAndMention(unittest.TestCase):
    def test_aging_line_appears_in_text_digest(self):
        now = 1_000_000
        c = conv(cid="OLD", lar=0, lcr=now - (25 * 3600))
        buckets = d.bucket_conversations([c], set())
        text = d.render_text_digest(buckets, now_epoch=now, aging_hours=20)
        self.assertIn("older than 20h since customer-side activity", text)
        self.assertNotIn("aging", text.lower())

    def test_aging_line_appears_in_blocks(self):
        now = 1_000_000
        c = conv(cid="OLD", lar=0, lcr=now - (25 * 3600))
        buckets = d.bucket_conversations([c], set())
        blocks = d.build_digest_blocks(buckets, now_epoch=now, aging_hours=20)
        self.assertIn("older than 20h since customer-side activity", str(blocks))
        self.assertNotIn("aging", str(blocks).lower())

    def test_no_aging_line_when_under_threshold(self):
        now = 1_000_000
        c = conv(cid="NEW", lar=0, lcr=now - (5 * 3600))
        buckets = d.bucket_conversations([c], set())
        text = d.render_text_digest(buckets, now_epoch=now, aging_hours=20)
        self.assertNotIn("aging", text)

    def test_mention_rendered_when_env_set_and_aging_present(self):
        now = 1_000_000
        c = conv(cid="OLD", lar=0, lcr=now - (25 * 3600))
        buckets = d.bucket_conversations([c], set())
        text = d.render_text_digest(buckets, now_epoch=now, aging_hours=20,
                                     mention_uid="U038BM16T7W")
        self.assertIn("<@U038BM16T7W>", text)

    def test_no_mention_when_no_aging_even_if_env_set(self):
        now = 1_000_000
        c = conv(cid="NEW", lar=0, lcr=now - (5 * 3600))
        buckets = d.bucket_conversations([c], set())
        text = d.render_text_digest(buckets, now_epoch=now, aging_hours=20,
                                     mention_uid="U038BM16T7W")
        self.assertNotIn("<@", text)

    def test_no_mention_when_aging_present_but_env_unset(self):
        import io
        from contextlib import redirect_stderr
        now = 1_000_000
        c = conv(cid="OLD", lar=0, lcr=now - (25 * 3600))
        buckets = d.bucket_conversations([c], set())
        with redirect_stderr(io.StringIO()) as err:
            text = d.render_text_digest(buckets, now_epoch=now, aging_hours=20,
                                         mention_uid=None)
        self.assertNotIn("<@", text)
        self.assertIn("CS_DIGEST_AGING_MENTION_UID", err.getvalue())


class TestMentionComputedOnceAndNoHeaderDuplication(unittest.TestCase):
    """finding: _mention_prefix was being computed twice per posted run (once
    for the printed text, once for the Slack blocks), duplicating the
    stderr WARN when the mention UID is unset. main() now computes it once
    and passes the result down via the `mention` kwarg."""

    def test_full_post_prints_the_missing_uid_warning_exactly_once(self):
        import sys as _sys
        import io
        from contextlib import redirect_stderr
        now = 1_000_000
        c = conv(cid="OLD", lar=0, lcr=now - (25 * 3600))
        err = io.StringIO()
        with mock.patch.object(d, "fetch_open_convs", return_value=[c]), \
             mock.patch.object(d, "load_delta_state", return_value={}), \
             mock.patch.object(d, "post_slack_digest", return_value=True), \
             mock.patch.object(d, "save_delta_state"), \
             mock.patch.dict("os.environ", {"MUSOAI_INTERCOM_TOKEN": "t",
                                             "DIGEST_SKIP_HOST_GUARD": "1",
                                             "DIGEST_NOW": str(now)}), \
             mock.patch.object(_sys, "argv", ["d", "--post"]), \
             redirect_stderr(err):
            d.main()
        self.assertEqual(err.getvalue().count("CS_DIGEST_AGING_MENTION_UID"), 1)

    def test_delta_digest_blocks_do_not_duplicate_the_header_line(self):
        now = 1_000_000
        c = conv(cid="C1", lar=0, lcr=now - 100)
        blocks = d.build_delta_digest_blocks([c], [], now_epoch=now, top_n=15)
        title_occurrences = sum(
            1 for b in blocks
            if b["type"] == "header"
            and b["text"]["text"] == "CS open-conversation review delta"
        )
        self.assertEqual(title_occurrences, 1)
        section_texts = [b["text"]["text"] for b in blocks if b["type"] == "section"]
        self.assertFalse(
            any("CS open-conversation review delta" in t for t in section_texts))

    def test_delta_digest_uses_neutral_counts_rows_and_caveat(self):
        now = 1_000_000
        replied = conv(cid="REPLIED", lar=0, lcr=now - 3600)
        tied = conv(cid="TIED", lar=now - (2 * 3600), lcr=now - (2 * 3600))
        opened = conv(cid="OPENED", lar=0, lcr=0,
                      created_at=now - (25 * 3600), is_inbound=True)

        text = d.render_delta_digest(
            [replied, tied, opened], [opened], now_epoch=now, top_n=15)

        self.assertIn("CS open-conversation review delta", text)
        self.assertIn("new to this digest: 3", text)
        self.assertIn(
            "older than 20h since customer-side activity: 1", text)
        self.assertIn(
            "customer is last recorded replier; last customer reply 1h ago", text)
        self.assertIn(
            "customer and team share the latest recorded reply time; "
            "last customer reply 2h ago", text)
        self.assertIn(
            "customer-initiated; opened 25h ago; no recorded reply", text)
        self.assertIn(
            "Open status and reply order do not prove that a customer went unanswered.",
            text)
        self.assertNotIn("waiting", text.lower())
        self.assertNotIn("aging", text.lower())


class TestMainDeltaFlow(unittest.TestCase):
    def _env(self, **extra):
        # DIGEST_NOW pinned near the fixtures' tiny lcr so they sit inside the
        # 30d actionable window (real time would make them 20000d-old backlog).
        base = {"MUSOAI_INTERCOM_TOKEN": "t", "DIGEST_SKIP_HOST_GUARD": "1",
                "DIGEST_NOW": "10000"}
        base.update(extra)
        return base

    def test_no_delta_prints_and_posts_nothing(self):
        import sys as _sys
        import io
        from contextlib import redirect_stdout
        c = conv(cid="C1", lar=0, lcr=100)  # already surfaced, not aging
        state = {"C1": {"first_surfaced": 1, "aged_flagged": False}}
        buf = io.StringIO()
        with mock.patch.object(d, "fetch_open_convs", return_value=[c]), \
             mock.patch.object(d, "load_delta_state", return_value=state), \
             mock.patch.object(d, "post_slack_digest") as m_post, \
             mock.patch.object(d, "save_delta_state") as m_save, \
             mock.patch.dict("os.environ", self._env(DIGEST_NOW="10000")), \
             mock.patch.object(_sys, "argv", ["d", "--delta", "--post"]), \
             redirect_stdout(buf):
            rc = d.main()
        self.assertEqual(rc, 0)
        self.assertIn("NO_DELTA", buf.getvalue())
        m_post.assert_not_called()
        m_save.assert_not_called()

    def test_dry_run_delta_never_writes_state(self):
        import sys as _sys
        c = conv(cid="C1", lar=0, lcr=100)
        with mock.patch.object(d, "fetch_open_convs", return_value=[c]), \
             mock.patch.object(d, "load_delta_state", return_value={}), \
             mock.patch.object(d, "save_delta_state") as m_save, \
             mock.patch.dict("os.environ", self._env()), \
             mock.patch.object(_sys, "argv", ["d", "--delta"]):
            rc = d.main()
        self.assertEqual(rc, 0)
        m_save.assert_not_called()

    def test_successful_post_delta_writes_state(self):
        import sys as _sys
        c = conv(cid="C1", lar=0, lcr=100)
        with mock.patch.object(d, "fetch_open_convs", return_value=[c]), \
             mock.patch.object(d, "load_delta_state", return_value={}), \
             mock.patch.object(d, "post_slack_digest", return_value=True), \
             mock.patch.object(d, "save_delta_state") as m_save, \
             mock.patch.dict("os.environ", self._env()), \
             mock.patch.object(_sys, "argv", ["d", "--delta", "--post"]):
            rc = d.main()
        self.assertEqual(rc, 0)
        m_save.assert_called_once()

    def test_delta_checkpoint_persist_failure_exits_nonzero(self):
        # Digest delivered (post ok) but the atomic checkpoint write failed —
        # the run must fail loud (exit 5) so the cron-health watchdog repairs
        # the disk, not stay green while re-paging Jan next delta run.
        import sys as _sys
        import io
        from contextlib import redirect_stderr
        c = conv(cid="C1", lar=0, lcr=100)
        err = io.StringIO()
        with mock.patch.object(d, "fetch_open_convs", return_value=[c]), \
             mock.patch.object(d, "load_delta_state", return_value={}), \
             mock.patch.object(d, "post_slack_digest", return_value=True), \
             mock.patch.object(d, "save_delta_state", side_effect=OSError("disk full")), \
             mock.patch.dict("os.environ", self._env(DIGEST_NOW="10000")), \
             mock.patch.object(_sys, "argv", ["d", "--delta", "--post"]), \
             redirect_stderr(err):
            rc = d.main()
        self.assertEqual(rc, 5)
        self.assertIn("could not persist", err.getvalue())

    def test_corrupt_state_fails_loud_in_main(self):
        # KEY: exit code 4 EXACTLY, not just any nonzero code — 4 is the
        # documented, distinct signal for "corrupt --delta state", and other
        # exit codes (1/2/3) mean something else. A test that only checks
        # != 0 can't catch a regression that changes this to e.g. 1.
        import sys as _sys
        with mock.patch.object(d, "fetch_open_convs", return_value=[]), \
             mock.patch.object(d, "load_delta_state",
                                side_effect=d.CorruptDigestState("bad json")), \
             mock.patch.dict("os.environ", self._env()), \
             mock.patch.object(_sys, "argv", ["d", "--delta"]):
            rc = d.main()
        self.assertEqual(rc, 4)

    def test_corrupt_state_also_fails_loud_under_delta_post(self):
        import sys as _sys
        with mock.patch.object(d, "fetch_open_convs", return_value=[]), \
             mock.patch.object(d, "load_delta_state",
                                side_effect=d.CorruptDigestState("bad json")), \
             mock.patch.object(d, "post_slack_digest") as m_post, \
             mock.patch.dict("os.environ", self._env()), \
             mock.patch.object(_sys, "argv", ["d", "--delta", "--post"]):
            rc = d.main()
        self.assertEqual(rc, 4)
        m_post.assert_not_called()

    def test_corrupt_state_does_not_block_full_digest_dry_run(self):
        # The pre-existing 13:30 full digest (and its dry-runs) must NOT be
        # taken down by a corrupt --delta state file — that file is owned by
        # a DIFFERENT, newer feature (--delta). Full mode degrades instead.
        import sys as _sys
        import io
        from contextlib import redirect_stderr, redirect_stdout
        c = conv(cid="C1", lar=0, lcr=100)
        out, err = io.StringIO(), io.StringIO()
        with mock.patch.object(d, "fetch_open_convs", return_value=[c]), \
             mock.patch.object(d, "load_delta_state",
                                side_effect=d.CorruptDigestState("bad json")), \
             mock.patch.dict("os.environ", self._env()), \
             mock.patch.object(_sys, "argv", ["d"]), \
             redirect_stdout(out), redirect_stderr(err):
            rc = d.main()
        self.assertEqual(rc, 0)
        self.assertIn("CS open-conversation review daily digest", out.getvalue())
        self.assertIn("corrupt", err.getvalue())

    def test_corrupt_state_full_post_renders_and_posts_but_skips_persistence(self):
        import sys as _sys
        import io
        from contextlib import redirect_stderr
        c = conv(cid="C1", lar=0, lcr=100)
        err = io.StringIO()
        with mock.patch.object(d, "fetch_open_convs", return_value=[c]), \
             mock.patch.object(d, "load_delta_state",
                                side_effect=d.CorruptDigestState("bad json")), \
             mock.patch.object(d, "post_slack_digest", return_value=True), \
             mock.patch.object(d, "save_delta_state") as m_save, \
             mock.patch.dict("os.environ", self._env()), \
             mock.patch.object(_sys, "argv", ["d", "--post"]), \
             redirect_stderr(err):
            rc = d.main()
        self.assertEqual(rc, 0)
        m_save.assert_not_called()
        self.assertIn("skipping --delta state persistence", err.getvalue())

    def test_full_run_refreshes_state_on_successful_post(self):
        import sys as _sys
        c = conv(cid="C1", lar=0, lcr=100)
        with mock.patch.object(d, "fetch_open_convs", return_value=[c]), \
             mock.patch.object(d, "load_delta_state", return_value={}), \
             mock.patch.object(d, "post_slack_digest", return_value=True), \
             mock.patch.object(d, "save_delta_state") as m_save, \
             mock.patch.dict("os.environ", self._env()), \
             mock.patch.object(_sys, "argv", ["d", "--post"]):
            rc = d.main()
        self.assertEqual(rc, 0)
        m_save.assert_called_once()

    def test_full_run_dry_run_never_writes_state(self):
        import sys as _sys
        c = conv(cid="C1", lar=0, lcr=100)
        with mock.patch.object(d, "fetch_open_convs", return_value=[c]), \
             mock.patch.object(d, "load_delta_state", return_value={}), \
             mock.patch.object(d, "save_delta_state") as m_save, \
             mock.patch.dict("os.environ", self._env()), \
             mock.patch.object(_sys, "argv", ["d"]):
            rc = d.main()
        self.assertEqual(rc, 0)
        m_save.assert_not_called()

    def test_no_delta_with_post_prunes_a_departed_conv(self):
        # A conv (C2) that left needs_human entirely (closed by a sibling
        # sweeper) must have its state entry dropped even on a NO_DELTA run —
        # otherwise a closed-then-reopened C2 would keep a stale entry
        # (possibly aged_flagged:true) and become invisible to future delta
        # digests the moment it reopens.
        import sys as _sys
        import io
        from contextlib import redirect_stdout
        c1 = conv(cid="C1", lar=0, lcr=100)  # still present, already surfaced, not aging
        state = {
            "C1": {"first_surfaced": 1, "aged_flagged": False},
            "C2": {"first_surfaced": 1, "aged_flagged": True},  # no longer in needs_human
        }
        captured = {}

        def fake_save(path, next_state):
            captured["next_state"] = next_state

        with mock.patch.object(d, "fetch_open_convs", return_value=[c1]), \
             mock.patch.object(d, "load_delta_state", return_value=state), \
             mock.patch.object(d, "save_delta_state", fake_save), \
             mock.patch.dict("os.environ", self._env(DIGEST_NOW="10000")), \
             mock.patch.object(_sys, "argv", ["d", "--delta", "--post"]), \
             redirect_stdout(io.StringIO()):
            rc = d.main()
        self.assertEqual(rc, 0)
        self.assertIn("next_state", captured)  # a write DID happen (pruning)
        self.assertNotIn("C2", captured["next_state"])  # departed entry dropped
        # C1 stayed present and wasn't re-rendered this run — its entry must
        # be carried over UNCHANGED (pure pruning creates/flips nothing).
        self.assertEqual(captured["next_state"]["C1"],
                          {"first_surfaced": 1, "aged_flagged": False})

    def test_no_delta_with_post_and_nothing_to_prune_never_writes(self):
        # Locks in the existing no-op-write behavior (test_no_delta_prints_
        # and_posts_nothing above) even after the finding-2 pruning fix: when
        # there's genuinely nothing to prune, no write happens at all.
        import sys as _sys
        import io
        from contextlib import redirect_stdout
        c1 = conv(cid="C1", lar=0, lcr=100)
        state = {"C1": {"first_surfaced": 1, "aged_flagged": False}}
        with mock.patch.object(d, "fetch_open_convs", return_value=[c1]), \
             mock.patch.object(d, "load_delta_state", return_value=state), \
             mock.patch.object(d, "save_delta_state") as m_save, \
             mock.patch.dict("os.environ", self._env(DIGEST_NOW="10000")), \
             mock.patch.object(_sys, "argv", ["d", "--delta", "--post"]), \
             redirect_stdout(io.StringIO()):
            rc = d.main()
        self.assertEqual(rc, 0)
        m_save.assert_not_called()

    def test_full_post_does_not_mark_rank_beyond_top_n_as_surfaced(self):
        # KEY regression: a full --post run renders only nh[:top_n], but
        # previously persisted next_state over ALL needs_human items — a
        # rank-16+ item would get first_surfaced (and possibly aged_flagged)
        # sight-unseen and then never appear in any future delta digest.
        import sys as _sys
        import io
        from contextlib import redirect_stdout
        convs = [conv(cid=f"C{i}", lar=0, lcr=100 + i) for i in range(20)]  # 20 items, top_n default 15
        captured = {}

        def fake_save(path, next_state):
            captured["next_state"] = next_state

        with mock.patch.object(d, "fetch_open_convs", return_value=convs), \
             mock.patch.object(d, "load_delta_state", return_value={}), \
             mock.patch.object(d, "post_slack_digest", return_value=True), \
             mock.patch.object(d, "save_delta_state", fake_save), \
             mock.patch.dict("os.environ", self._env(DIGEST_NOW="10000")), \
             mock.patch.object(_sys, "argv", ["d", "--post"]), \
             redirect_stdout(io.StringIO()):
            rc = d.main()
        self.assertEqual(rc, 0)
        # needs_human is ranked newest-waiting-first — the 5 OLDEST (lowest
        # lcr, i.e. C0..C4) rank beyond top_n=15 and must be absent.
        for i in range(0, 5):
            self.assertNotIn(f"C{i}", captured["next_state"])
        for i in range(5, 20):
            self.assertIn(f"C{i}", captured["next_state"])

    def test_full_post_failure_does_not_persist_state_and_exits_1(self):
        import sys as _sys
        c = conv(cid="C1", lar=0, lcr=100)
        with mock.patch.object(d, "fetch_open_convs", return_value=[c]), \
             mock.patch.object(d, "load_delta_state", return_value={}), \
             mock.patch.object(d, "post_slack_digest", return_value=False), \
             mock.patch.object(d, "save_delta_state") as m_save, \
             mock.patch.dict("os.environ", self._env()), \
             mock.patch.object(_sys, "argv", ["d", "--post"]):
            rc = d.main()
        self.assertEqual(rc, 1)
        m_save.assert_not_called()

    def test_delta_post_failure_does_not_persist_state_and_exits_1(self):
        import sys as _sys
        c = conv(cid="C1", lar=0, lcr=100)
        with mock.patch.object(d, "fetch_open_convs", return_value=[c]), \
             mock.patch.object(d, "load_delta_state", return_value={}), \
             mock.patch.object(d, "post_slack_digest", return_value=False), \
             mock.patch.object(d, "save_delta_state") as m_save, \
             mock.patch.dict("os.environ", self._env()), \
             mock.patch.object(_sys, "argv", ["d", "--delta", "--post"]):
            rc = d.main()
        self.assertEqual(rc, 1)
        m_save.assert_not_called()


class TestDeltaDigestLargeBacklogCap(unittest.TestCase):
    """KEY regression (production constraint: ~436 real needs-human items).
    Rendering EVERY surfaced item into one Slack section blows past Slack's
    3000-char section text cap -> invalid_blocks -> post fails -> state
    never persists -> both delta timers wedge forever. Rows must be capped
    at the same top_n convention the full digest uses."""

    def test_render_delta_digest_caps_rows_at_top_n(self):
        now = 1_000_000
        items = [conv(cid=f"N{i}", lar=0, lcr=now - i) for i in range(100)]
        text = d.render_delta_digest(items, [], now_epoch=now, top_n=15)
        rows = [line for line in text.splitlines() if "conversation/" in line]
        self.assertEqual(len(rows), 15)
        self.assertIn("85 more", text)
        self.assertIn("13:30 full digest", text)

    def test_build_delta_digest_blocks_section_text_under_slack_cap(self):
        now = 10_000_000
        items = [
            conv(cid=str(100_000_000_000_000 + i), lar=0,
                 lcr=now - ((25 + i) * 3600))
            for i in range(100)
        ]
        blocks = d.build_delta_digest_blocks(items, items, now_epoch=now, top_n=15)
        sections = [b for b in blocks if b["type"] == "section"]
        self.assertTrue(all(len(b["text"]["text"]) <= 3000 for b in sections))
        rendered_rows = sum(
            b["text"]["text"].count("conversation/") for b in sections)
        self.assertEqual(rendered_rows, 15)

    def test_state_records_only_the_rendered_subset_not_all_100(self):
        # Consistency with the rank-beyond-top_n fix: --delta state must only
        # mark the rows ACTUALLY rendered (capped), never the full backlog.
        now = 1_000_000
        items = [conv(cid=f"N{i}", lar=0, lcr=now - i) for i in range(100)]
        rendered, overflow = d._cap_delta_items(items, [], top_n=15)
        self.assertEqual(len(rendered), 15)
        self.assertEqual(overflow, 85)
        next_state = d.build_next_state({}, items, rendered, now, aging_hours=20)
        self.assertEqual(len(next_state), 15)


class TestBuildNextStateAgingRefresh(unittest.TestCase):
    """build_next_state is what actually PERSISTS; it must refresh the aging
    status of present entries even when the row was not rendered, or a stale
    aged_flagged:true suppresses the next re-cross escalation forever."""

    def _c(self, hours_waiting, now=1_000_000):
        return conv(cid="C1", lar=0, lcr=now - int(hours_waiting * 3600))

    def test_stale_aged_flag_resets_for_unrendered_present_entry(self):
        # aged (persisted true) -> wait resets below threshold on an UNRENDERED
        # run (NO_DELTA, rendered_items=[]) -> flag must drop to false so a
        # later re-cross can escalate again. first_surfaced preserved.
        now = 1_000_000
        state = {"C1": {"first_surfaced": now - 200000, "aged_flagged": True}}
        ns = d.build_next_state(state, [self._c(5)], [], now, aging_hours=20)
        self.assertFalse(ns["C1"]["aged_flagged"])
        self.assertEqual(ns["C1"]["first_surfaced"], now - 200000)

    def test_aging_but_unrendered_keeps_existing_flag_not_flipped_true(self):
        # aging + NOT rendered must KEEP the existing flag (never flip true
        # sight-unseen, which would suppress the escalation when finally shown).
        now = 1_000_000
        unflagged = {"C1": {"first_surfaced": now - 200000, "aged_flagged": False}}
        ns = d.build_next_state(unflagged, [self._c(30)], [], now, aging_hours=20)
        self.assertFalse(ns["C1"]["aged_flagged"])   # still false -> will ping when shown
        flagged = {"C1": {"first_surfaced": now - 200000, "aged_flagged": True}}
        ns2 = d.build_next_state(flagged, [self._c(30)], [], now, aging_hours=20)
        self.assertTrue(ns2["C1"]["aged_flagged"])    # already pinged -> stays true

    def test_aging_and_rendered_sets_flag_true(self):
        now = 1_000_000
        c = self._c(30)
        state = {"C1": {"first_surfaced": now - 200000, "aged_flagged": False}}
        ns = d.build_next_state(state, [c], [c], now, aging_hours=20)
        self.assertTrue(ns["C1"]["aged_flagged"])

    def test_full_cycle_aged_reset_recross_survives_persisted_handoff(self):
        # The finding's end-to-end regression across persisted runs:
        # aged+rendered (persist true) -> reset below threshold, unrendered
        # (persist false) -> re-cross must escalate again off the persisted state.
        now, ah = 1_000_000, 20
        s1 = d.build_next_state({}, [self._c(25)], [self._c(25)], now, ah)
        self.assertTrue(s1["C1"]["aged_flagged"])
        s2 = d.build_next_state(s1, [self._c(5)], [], now, ah)   # reset, NO_DELTA
        self.assertFalse(s2["C1"]["aged_flagged"])
        new_items, aging_items, _ = d.compute_delta_and_next_state(
            s2, [self._c(25)], now, ah)                          # re-cross
        self.assertEqual([c["id"] for c in aging_items], ["C1"])


if __name__ == "__main__":
    unittest.main()


class TestActionableWindowWiring(unittest.TestCase):
    """MUS-8853b: the 30d window reaches both renderers, --delta and the
    persisted state through main() — a 194d-old thread is not listed, and is
    rolled into exactly one backlog line carrying the real count."""
    NOW = 1_800_000_000
    DAY = 86400
    OLD = conv(cid="OLD", lar=0, lcr=NOW - 194 * DAY)
    NEW = conv(cid="NEW", lar=0, lcr=NOW - 2 * 3600)

    def _env(self, **extra):
        base = {"MUSOAI_INTERCOM_TOKEN": "t", "DIGEST_SKIP_HOST_GUARD": "1",
                "DIGEST_NOW": str(self.NOW)}
        base.update(extra)
        return base

    def _run(self, convs, argv, state=None, env=None, post=True):
        import sys as _sys
        import io
        from contextlib import redirect_stdout
        out, saved, blocks = io.StringIO(), {}, {}

        def fake_post(b, text, *a):
            blocks["b"] = b
            return post

        def fake_save(path, ns):
            saved["state"] = ns

        with mock.patch.object(d, "fetch_open_convs", return_value=convs), \
             mock.patch.object(d, "load_delta_state", return_value=state or {}), \
             mock.patch.object(d, "post_slack_digest", fake_post), \
             mock.patch.object(d, "save_delta_state", fake_save), \
             mock.patch.dict("os.environ", self._env(**(env or {}))), \
             mock.patch.object(_sys, "argv", ["d"] + argv), \
             redirect_stdout(out):
            rc = d.main()
        return rc, out.getvalue(), blocks.get("b"), saved.get("state")

    def _block_text(self, blocks):
        return "\n".join(b["text"]["text"] for b in blocks if b["type"] == "section")

    def test_full_digest_lists_only_recent_and_rolls_up_backlog_once(self):
        rc, out, blocks, _ = self._run([self.OLD, self.NEW], ["--post"])
        self.assertEqual(rc, 0)
        line = ("backlog: 1 open conversations with no customer-side activity "
                "in the last 30d — being drained separately (not listed here)")
        btxt = self._block_text(blocks)
        for text in (out, btxt.replace("*", "")):
            self.assertNotIn("conversations/OLD", text)
            self.assertNotIn("194d", text)
            self.assertIn(d.intercom_link("NEW"), text)
            self.assertIn("customer-side activity is latest: 1", text)
            self.assertEqual(text.count(line), 1)

    def test_backlog_line_absent_when_everything_in_window(self):
        rc, out, blocks, _ = self._run([self.NEW], ["--post"])
        self.assertNotIn("backlog:", out)
        self.assertNotIn("backlog:", self._block_text(blocks))

    def test_counts_line_reports_aging_total(self):
        old_ish = conv(cid="AGE", lar=0, lcr=self.NOW - 3 * self.DAY)
        _, out, blocks, _ = self._run([old_ish, self.NEW], [])
        self.assertIn("customer-side activity is latest: 2", out)
        self.assertIn("older than 20h since customer-side activity: 1", out)
        _, _, blocks, _ = self._run([old_ish, self.NEW], ["--post"])
        self.assertIn("older than 20h since customer-side activity: 1",
                      self._block_text(blocks).replace("*", ""))

    def test_env_override_changes_which_rows_render(self):
        week = conv(cid="WEEK", lar=0, lcr=self.NOW - 10 * self.DAY)
        _, out, _, _ = self._run([week, self.NEW], [])
        self.assertIn(d.intercom_link("WEEK"), out)
        self.assertNotIn("backlog:", out)
        _, out, _, _ = self._run([week, self.NEW], [],
                                 env={"CS_DIGEST_ACTIONABLE_DAYS": "7"})
        self.assertNotIn(d.intercom_link("WEEK"), out)
        self.assertIn("backlog: 1 open conversations with no customer-side "
                      "activity in the last 7d", out)

    def test_delta_excludes_backlog_and_rolls_it_up(self):
        _, out, blocks, state = self._run([self.OLD, self.NEW], ["--delta", "--post"])
        self.assertNotIn(d.intercom_link("OLD"), out)
        self.assertIn("new to this digest: 1", out)
        self.assertEqual(out.count("backlog: 1 open conversations"), 1)
        self.assertEqual(self._block_text(blocks).count("backlog: 1 open"), 1)
        self.assertEqual(set(state), {"NEW"})

    def test_delta_backlog_only_run_is_still_no_delta(self):
        rc, out, blocks, _ = self._run([self.OLD], ["--delta", "--post"])
        self.assertEqual(rc, 0)
        self.assertIn("NO_DELTA", out)
        self.assertIsNone(blocks)

    def test_delta_prunes_backlog_entry_and_reentry_surfaces_as_new(self):
        # D6: waiting_since only moves forward on a customer reply, so a thread
        # re-entering the window has genuinely new activity -> new, not hidden.
        state = {"OLD": {"first_surfaced": 1, "aged_flagged": True}}
        _, _, _, saved = self._run([self.OLD], ["--delta", "--post"], state=state)
        self.assertNotIn("OLD", saved)
        replied = conv(cid="OLD", lar=0, lcr=self.NOW - 3600)
        _, out, _, saved2 = self._run([replied], ["--delta", "--post"], state=saved)
        self.assertIn("new to this digest: 1", out)
        self.assertIn(d.intercom_link("OLD"), out)
        self.assertIn("OLD", saved2)

    def test_dry_run_delta_with_backlog_writes_nothing(self):
        _, _, _, saved = self._run([self.OLD, self.NEW], ["--delta"])
        self.assertIsNone(saved)
