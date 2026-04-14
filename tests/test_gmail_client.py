"""Fixture-based tests for the gmail_client adapter.

These tests feed real `gog gmail ... --json` fixtures (captured from the
production server 2026-04-14) into the parser functions, so any drift
in the gog output shape would have been caught here instead of during
production deploy. This is the issue flagged as #98 in the code review
of PR #95.
"""
from __future__ import annotations

import json
from pathlib import Path
from unittest.mock import patch

import pytest

from scripts.lib.muso_outreach import gmail_client
from scripts.lib.muso_outreach.types import Draft, Message, Thread

FIXTURES = Path(__file__).parent / "fixtures" / "gog"


def _load(name: str) -> str:
    return (FIXTURES / f"{name}.json").read_text()


def _load_json(name: str) -> dict:
    return json.loads(_load(name))


@pytest.fixture(autouse=True)
def _reset_label_cache():
    """Each test starts with a clean label cache."""
    gmail_client._LABEL_CACHE.clear()
    yield
    gmail_client._LABEL_CACHE.clear()


# ---------- Low-level helpers ----------

def test_parse_email_bare_address():
    assert gmail_client._parse_email("a@muso.ai") == "a@muso.ai"


def test_parse_email_named_address():
    assert gmail_client._parse_email("Matt - HAULIX <matt@haulix.com>") == "matt@haulix.com"


def test_parse_email_empty_inputs():
    assert gmail_client._parse_email("") is None
    assert gmail_client._parse_email(None) is None


def test_parse_email_lowercases_and_trims():
    assert gmail_client._parse_email("  Ole <OW@LarsenStrings.COM>  ") == "ow@larsenstrings.com"


def test_parse_address_list_multiple():
    raw = "Alice <a@x.com>, bob@y.com, Charlie <c@z.com>"
    assert gmail_client._parse_address_list(raw) == ("a@x.com", "bob@y.com", "c@z.com")


def test_parse_address_list_empty():
    assert gmail_client._parse_address_list("") == ()
    assert gmail_client._parse_address_list(None) == ()


def test_header_case_insensitive():
    headers = [{"name": "To", "value": "a@b.com"}, {"name": "FROM", "value": "c@d.com"}]
    assert gmail_client._header(headers, "to") == "a@b.com"
    assert gmail_client._header(headers, "FROM") == "c@d.com"
    assert gmail_client._header(headers, "cc") is None


def test_b64url_decode_handles_missing_padding():
    # "test" → "dGVzdA==" in standard b64; unpadded "dGVzdA"
    assert gmail_client._b64url_decode("dGVzdA") == "test"


# ---------- Real fixtures: gog gmail drafts get --json ----------

def test_fetch_draft_parses_real_gog_output_shape():
    """drafts-get.json was captured from `gog gmail drafts get` on
    2026-04-14. The draft was created with To: smoke@example.invalid,
    From: a@muso.ai, HTML body '<p>test</p>'."""
    fixture = _load("drafts-get")
    with patch.object(gmail_client, "run_gog") as rg:
        # First call = drafts get, second = labels list (cache warm)
        rg.side_effect = [fixture, _load("labels-list")]
        draft = gmail_client.fetch_draft("r6470161099068266598", "a@muso.ai")

    assert isinstance(draft, Draft)
    assert draft.draft_id == "r6470161099068266598"
    assert draft.account == "a@muso.ai"
    assert draft.to_addrs == ("smoke@example.invalid",)
    assert draft.cc_addrs == ()
    assert draft.bcc_addrs == ()
    # Body was base64url-encoded "<p>test</p>\r\n"
    assert "<p>test</p>" in draft.body_html
    # System labels pass through as-is.
    assert "DRAFT" in draft.labels
    # reply_to_message_id not present on this draft.
    assert draft.reply_to_message_id is None


def test_fetch_draft_resolves_user_label_ids_to_names():
    """When a draft has a user-label ID like Label_7746877054870722633,
    the adapter must resolve it to the human-readable name from the
    labels-list fixture (B2B - Ads)."""
    # Synthesize a draft with a user-label ID so we can test resolution.
    # Find a real user label id from the fixture.
    labels = _load_json("labels-list")["labels"]
    user_labels = [l for l in labels if l["type"] == "user"]
    assert user_labels, "fixture has no user labels to test resolution"
    user_label = user_labels[0]
    user_id = user_label["id"]
    user_name = user_label["name"]

    draft_js = {
        "draft": {
            "id": "r-synthetic",
            "message": {
                "id": "msg-synthetic",
                "threadId": "thread-synthetic",
                "internalDate": "1776000000000",
                "labelIds": ["DRAFT", user_id],
                "payload": {
                    "mimeType": "text/plain",
                    "body": {"data": "aGVsbG8"},  # "hello" b64
                    "headers": [
                        {"name": "From", "value": "a@muso.ai"},
                        {"name": "To", "value": "x@example.com"},
                    ],
                },
            },
        }
    }

    with patch.object(gmail_client, "run_gog") as rg:
        rg.side_effect = [json.dumps(draft_js), _load("labels-list")]
        draft = gmail_client.fetch_draft("r-synthetic", "a@muso.ai")

    assert user_name in draft.labels
    assert "DRAFT" in draft.labels


# ---------- Real fixtures: gog gmail threads get --json ----------

def test_fetch_thread_parses_real_gog_output_shape():
    """threads-get.json was captured from `gog gmail threads get` on
    2026-04-14 for thread 19d779406d27bd56 (Matt Brown / Haulix outreach
    thread)."""
    fixture = _load("threads-get")
    with patch.object(gmail_client, "run_gog") as rg:
        rg.side_effect = [fixture, _load("labels-list")]
        thread = gmail_client.fetch_thread("19d779406d27bd56", "a@muso.ai")

    assert isinstance(thread, Thread)
    assert thread.thread_id == "19d779406d27bd56"
    # The thread has at least one outgoing muso message.
    assert len(thread.messages) >= 1
    first = thread.messages[0]
    assert isinstance(first, Message)
    # The first outgoing message was from a@muso.ai to matt@haulix.com.
    assert first.from_addr == "a@muso.ai"
    assert first.to_addrs == ("matt@haulix.com",)
    assert first.date_epoch > 0


def test_fetch_thread_empty_messages():
    """If the thread has no messages, parser returns empty Thread, not error."""
    js = {"downloaded": None, "thread": {"id": "t-empty", "messages": []}}
    with patch.object(gmail_client, "run_gog") as rg:
        rg.side_effect = [json.dumps(js), _load("labels-list")]
        thread = gmail_client.fetch_thread("t-empty", "a@muso.ai")
    assert thread.thread_id == "t-empty"
    assert thread.messages == ()


# ---------- drafts list ----------

def test_list_drafts_with_label_empty():
    """drafts-list.json from the fixture happens to be empty."""
    fixture = _load("drafts-list")
    with patch.object(gmail_client, "run_gog") as rg:
        rg.return_value = fixture
        ids = gmail_client.list_drafts_with_label("B2B - Ads", "a@muso.ai")
    assert ids == []


def test_list_drafts_with_label_multiple():
    js = {
        "drafts": [{"id": "r1"}, {"id": "r2"}, {"id": "r3"}],
        "nextPageToken": "",
    }
    with patch.object(gmail_client, "run_gog") as rg:
        rg.return_value = json.dumps(js)
        ids = gmail_client.list_drafts_with_label("B2B - Ads", "a@muso.ai")
    assert ids == ["r1", "r2", "r3"]


# ---------- drafts send ----------

def test_send_draft_extracts_message_id_from_nested_response():
    """Real gog `drafts send` response: {draftId, message: {id, threadId}, threadId}."""
    js = {
        "draftId": "r-sent",
        "message": {"id": "m-123", "threadId": "t-456", "labelIds": ["SENT"]},
        "threadId": "t-456",
    }
    with patch.object(gmail_client, "run_gog") as rg:
        rg.return_value = json.dumps(js)
        mid = gmail_client.send_draft("r-sent", "a@muso.ai")
    assert mid == "m-123"


# ---------- search_inbound_from ----------

def test_search_inbound_from_parses_simplified_shape():
    """messages-search.json uses a SIMPLIFIED shape (no payload, no
    internalDate); the `from` field is RFC-5322 form like
    'Matt - HAULIX <matt@haulix.com>'."""
    fixture = _load("messages-search")
    with patch.object(gmail_client, "run_gog") as rg:
        rg.return_value = fixture
        msgs = gmail_client.search_inbound_from(
            "x@example.com", days=60, accounts=("a@muso.ai",),
        )
    # Fixture captured 3 inbox messages; the RFC-5322 wrapped "From"
    # values must all parse to bare emails.
    assert len(msgs) == 3
    assert all(m.from_addr and "@" in m.from_addr for m in msgs)
    assert any(m.from_addr == "matt@haulix.com" for m in msgs)


def test_search_inbound_from_dedupes_by_message_id():
    """Same message_id appearing in multiple accounts' search output =
    one Message returned."""
    js = {"messages": [{"id": "dup-msg", "from": "x@y.com"}], "nextPageToken": ""}
    with patch.object(gmail_client, "run_gog") as rg:
        rg.return_value = json.dumps(js)
        msgs = gmail_client.search_inbound_from(
            "x@y.com", days=60, accounts=("a@muso.ai", "ak@muso.ai", "f@muso.ai"),
        )
    assert len(msgs) == 1
    # Three accounts queried → three gog calls.
    assert rg.call_count == 3


# ---------- Body decoding ----------

def test_decode_body_html_single_part():
    # "<p>test</p>\r\n" base64url = "PHA-dGVzdDwvcD4NCg=="
    payload = {
        "mimeType": "text/html",
        "body": {"data": "PHA-dGVzdDwvcD4NCg==", "size": 13},
    }
    assert gmail_client._decode_body_html(payload).startswith("<p>test</p>")


def test_decode_body_html_prefers_html_over_plain_in_multipart():
    payload = {
        "mimeType": "multipart/alternative",
        "body": {},
        "parts": [
            {
                "mimeType": "text/plain",
                "body": {"data": "cGxhaW4"},  # "plain"
            },
            {
                "mimeType": "text/html",
                "body": {"data": "PGI-aHRtbDwvYj4"},  # "<b>html</b>"
            },
        ],
    }
    result = gmail_client._decode_body_html(payload)
    assert "<b>html</b>" in result
    assert "plain" not in result


def test_decode_body_html_falls_back_to_plain_if_no_html():
    payload = {
        "mimeType": "text/plain",
        "body": {"data": "aGVsbG8"},  # "hello"
    }
    assert gmail_client._decode_body_html(payload) == "hello"


def test_decode_body_html_empty_payload():
    assert gmail_client._decode_body_html(None) == ""
    assert gmail_client._decode_body_html({}) == ""
