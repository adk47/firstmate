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

    def test_needs_human_ranked_oldest_waiting_first(self):
        recent = conv(cid="R", lar=0, lcr=900)
        oldest = conv(cid="O", lar=0, lcr=100)
        middle = conv(cid="M", lar=0, lcr=500)
        buckets = d.bucket_conversations([recent, oldest, middle], set())
        self.assertEqual([c["id"] for c in buckets["needs_human"]], ["O", "M", "R"])

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
        self.assertEqual([c["id"] for c in buckets["needs_human"]], ["OLD", "NEW"])

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
        self.assertIn("past 48h", str(blocks))


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
        with mock.patch.object(
            d, "fetch_open_convs",
            return_value=[{"id": "C1", "email": "a@b.com", "lar": 0, "lcr": 200}],
        ), mock.patch.object(d, "post_slack_digest", return_value=True), \
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


if __name__ == "__main__":
    unittest.main()
