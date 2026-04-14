"""Tests for metadata.parse_from_draft.

Metadata lives redundantly in Gmail labels (primary) and a JSON HTML
comment in the draft body (fallback). See the design spec §1 for the
reconciliation rules this test suite locks in.
"""
import pytest

from scripts.lib.muso_outreach.metadata import (
    METADATA_LABEL_DISAGREE,
    METADATA_MISSING,
    parse_from_draft,
)
from scripts.lib.muso_outreach.types import Draft, Kind


def _draft(labels=(), body_html="") -> Draft:
    return Draft(
        draft_id="r1",
        account="a@muso.ai",
        to_addrs=("ow@larsenstrings.com",),
        cc_addrs=(),
        bcc_addrs=(),
        body_html=body_html,
        labels=labels,
        reply_to_message_id=None,
    )


def _labels_full(thread_id: str = "1812f") -> tuple[str, ...]:
    return (
        "B2B - Ads",
        "muso-meta/kind-followup",
        "muso-meta/row-1234",
        "muso-meta/opp-abc",
        "muso-meta/template-FU-01",
        "muso-meta/sender-a_at_muso.ai",
        f"muso-meta/thread-{thread_id}",
    )


def _json_comment(overrides: dict | None = None) -> str:
    import json
    payload = {
        "kind": "followup",
        "sheet_row_id": 1234,
        "opp_id": "abc",
        "template": "FU-01",
        "sender": "a@muso.ai",
        "original_thread_id": "1812f",
    }
    if overrides:
        payload.update(overrides)
    return f"<!-- muso-outreach:v1 {json.dumps(payload)} -->"


def test_labels_and_json_agree_uses_labels():
    draft = _draft(labels=_labels_full(), body_html=_json_comment())
    meta, warnings = parse_from_draft(draft)
    assert meta.kind is Kind.FOLLOWUP
    assert meta.sheet_row_id == 1234
    assert meta.opp_id == "abc"
    assert meta.sender == "a@muso.ai"
    assert meta.original_thread_id == "1812f"
    assert warnings == []


def test_labels_present_json_stripped_warns_but_proceeds():
    draft = _draft(labels=_labels_full(), body_html="<p>draft body without comment</p>")
    meta, warnings = parse_from_draft(draft)
    assert meta.sheet_row_id == 1234
    assert warnings and "json metadata missing" in warnings[0].lower()


def test_labels_missing_json_present_raises():
    draft = _draft(labels=("B2B - Ads",), body_html=_json_comment())
    with pytest.raises(ValueError) as exc:
        parse_from_draft(draft)
    assert exc.value.args[0] == METADATA_MISSING


def test_both_missing_raises():
    draft = _draft(labels=("B2B - Ads",), body_html="<p>nothing here</p>")
    with pytest.raises(ValueError) as exc:
        parse_from_draft(draft)
    assert exc.value.args[0] == METADATA_MISSING


def test_labels_and_json_disagree_raises():
    bad_labels = list(_labels_full())
    bad_labels[2] = "muso-meta/row-9999"  # disagrees with JSON sheet_row_id=1234
    draft = _draft(labels=tuple(bad_labels), body_html=_json_comment())
    with pytest.raises(ValueError) as exc:
        parse_from_draft(draft)
    assert exc.value.args[0] == METADATA_LABEL_DISAGREE


def test_new_kind_has_no_thread():
    labels = (
        "B2B - Ads",
        "muso-meta/kind-new",
        "muso-meta/row-55",
        "muso-meta/opp-xyz",
        "muso-meta/template-PrivateInvite",
        "muso-meta/sender-a_at_muso.ai",
    )
    body = _json_comment({"kind": "new", "sheet_row_id": 55, "opp_id": "xyz",
                          "template": "PrivateInvite", "sender": "a@muso.ai",
                          "original_thread_id": None})
    meta, _ = parse_from_draft(_draft(labels=labels, body_html=body))
    assert meta.kind is Kind.NEW
    assert meta.original_thread_id is None
